#!/usr/bin/env bash
# 3X-UI 2.9.3: disable IP Limit for every client, preserving IP Log.
set -Eeuo pipefail
umask 077

DB=/etc/x-ui/x-ui.db
APPLY=0
OFFLINE=0
BACKUP_DIR=

usage() {
    cat <<'HELP'
Использование:
  disable-ip-limit-all.sh [--db FILE] [--apply] [--offline] [--backup-dir DIR]

Без --apply: только показать количество клиентов и распределение лимитов.
--apply       Установить числовой limitIp=0 всем клиентам; IP Log сохранить.
--db FILE     База SQLite (по умолчанию /etc/x-ui/x-ui.db).
--offline     Работа с отдельной копией базы без управления службой x-ui.
--backup-dir  Существующий каталог резервных копий (по умолчанию каталог базы).

Примеры:
  sudo bash disable-ip-limit-all.sh
  sudo bash disable-ip-limit-all.sh --apply
  bash disable-ip-limit-all.sh --db /tmp/x-ui-test.db --offline --apply
HELP
}

fail() { echo "Ошибка: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --offline) OFFLINE=1; shift ;;
        --db|--backup-dir)
            [[ $# -ge 2 && -n "$2" ]] || fail "Для $1 требуется значение"
            if [[ "$1" == --db ]]; then DB=$2; else BACKUP_DIR=$2; fi
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Неизвестный аргумент: $1" ;;
    esac
done

command -v sqlite3 >/dev/null || fail 'Не найден sqlite3'
[[ -f "$DB" && -r "$DB" ]] || fail "База не существует или недоступна: $DB"
DB="$(cd -- "$(dirname -- "$DB")" && pwd -P)/$(basename -- "$DB")"

show_summary() {
    sqlite3 -readonly -bail -header -column "$DB" <<'SQL'
.timeout 5000
SELECT COUNT(*) AS clients,
       COALESCE(SUM(CAST(COALESCE(json_extract(c.value, '$.limitIp'), 0) AS INTEGER) != 0), 0)
           AS nonzero_limits
FROM inbounds AS i, json_each(i.settings, '$.clients') AS c;
SELECT COALESCE(json_extract(c.value, '$.limitIp'), 0) AS limit_ip,
       COUNT(*) AS clients
FROM inbounds AS i, json_each(i.settings, '$.clients') AS c
GROUP BY limit_ip ORDER BY limit_ip;
SQL
}

# Check schema/JSON and SQLite JSON support before stopping the service.
echo "База: $DB"
show_summary
if [[ "$APPLY" -eq 0 ]]; then
    echo 'Предварительный просмотр. Для изменения добавьте --apply.'
    exit 0
fi

[[ -w "$DB" ]] || fail "Нет доступа на запись к базе: $DB"
BACKUP_DIR=${BACKUP_DIR:-$(dirname -- "$DB")}
[[ -d "$BACKUP_DIR" && -w "$BACKUP_DIR" ]] || fail "Недоступен каталог копий: $BACKUP_DIR"
BACKUP_DIR=$(cd -- "$BACKUP_DIR" && pwd -P)
restart_needed=0

cleanup() {
    local status=$?
    trap - EXIT
    if [[ "$restart_needed" -eq 1 ]]; then
        echo 'Запуск x-ui...'
        if ! systemctl start x-ui || ! systemctl is-active --quiet x-ui; then
            echo 'Ошибка запуска x-ui. Проверьте systemctl status x-ui.' >&2
            status=1
        fi
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "$OFFLINE" -eq 0 ]]; then
    [[ "$EUID" -eq 0 ]] || fail 'Для управления x-ui запустите скрипт от root'
    command -v systemctl >/dev/null || fail 'Не найден systemctl; для отдельной копии используйте --offline'
    state=$(systemctl show x-ui -p ActiveState --value)
    case "$state" in
        active)
            echo 'Остановка x-ui (подключения временно прервутся)...'
            restart_needed=1
            systemctl stop x-ui ;;
        inactive|failed)
            echo 'x-ui уже остановлен; скрипт не будет запускать его.' ;;
        *) fail "Неожиданное состояние x-ui: $state" ;;
    esac
else
    echo 'Режим --offline: используйте только отдельную базу, которую никто не изменяет.'
fi

# Generate a safe basename for SQLite's .backup command; DB remains absolute.
backup_name=$(cd -- "$BACKUP_DIR" && mktemp x-ui.before-disable-all-limits.XXXXXXXX)
backup_file="$BACKUP_DIR/$backup_name"
echo "Резервная копия: $backup_file"
(cd -- "$BACKUP_DIR" && sqlite3 -readonly -bail "$DB" ".backup '$backup_name'")
[[ $(sqlite3 -readonly -bail "$backup_file" 'PRAGMA quick_check;') == ok ]] \
    || fail 'Резервная копия не прошла quick_check; изменение отменено'

# Keep a small separate snapshot for selective restoration of original limits.
limits_file="$backup_file.limits.json"
sqlite3 -readonly -bail -json "$backup_file" "
SELECT i.id AS inbound_id, c.key AS client_index,
       json_extract(c.value, '$.email') AS email,
       json_extract(c.value, '$.limitIp') AS limit_ip,
       json_type(c.value, '$.limitIp') AS limit_ip_type
FROM inbounds AS i, json_each(i.settings, '$.clients') AS c;
" > "$limits_file"

sqlite3 -bail "$DB" <<'SQL'
.timeout 5000
BEGIN IMMEDIATE;
UPDATE inbounds
SET settings = json_set(settings, '$.clients', json((
    SELECT json_group_array(json_set(c.value, '$.limitIp', 0))
    FROM json_each(inbounds.settings, '$.clients') AS c
)))
WHERE json_type(settings, '$.clients') = 'array';

-- Fail before COMMIT if any client did not receive an integer zero.
CREATE TEMP TABLE assert_zero (remaining INTEGER CHECK (remaining = 0));
INSERT INTO assert_zero
SELECT COUNT(*)
FROM inbounds AS i, json_each(i.settings, '$.clients') AS c
WHERE json_type(c.value, '$.limitIp') IS NOT 'integer'
   OR json_extract(c.value, '$.limitIp') != 0;
COMMIT;
SQL

echo 'Готово: всем клиентам установлен limitIp=0. IP Log сохранён.'
echo "Прежние лимиты: $limits_file"
echo 'Для возврата лимитов используйте выборочное восстановление; вся старая база перезапишет новые данные.'
show_summary
# EXIT trap restores the service only if it was active before this run.
