#!/usr/bin/env bash
set -Eeuo pipefail

DB="/etc/x-ui/x-ui.db"
MODE="${1:-show}"

show_targets() {
    sqlite3 -readonly "$DB" <<'SQL'
.headers on
.mode column

WITH clients AS (
    SELECT
        json_extract(c.value, '$.email') AS email,
        MAX(
            CAST(
                COALESCE(json_extract(c.value, '$.limitIp'), 0)
                AS INTEGER
            )
        ) AS limit_ip
    FROM inbounds AS i
    JOIN json_each(i.settings, '$.clients') AS c
    GROUP BY json_extract(c.value, '$.email')
)
SELECT
    c.email,
    c.limit_ip,
    json_array_length(ip.ips) AS saved_ips
FROM clients AS c
JOIN inbound_client_ips AS ip
     ON ip.client_email = c.email
WHERE c.limit_ip > 0
  AND json_valid(ip.ips)
  AND json_type(ip.ips) = 'array'
  AND json_array_length(ip.ips) = 1
ORDER BY c.limit_ip DESC, c.email;

WITH clients AS (
    SELECT
        json_extract(c.value, '$.email') AS email,
        MAX(
            CAST(
                COALESCE(json_extract(c.value, '$.limitIp'), 0)
                AS INTEGER
            )
        ) AS limit_ip
    FROM inbounds AS i
    JOIN json_each(i.settings, '$.clients') AS c
    GROUP BY json_extract(c.value, '$.email')
)
SELECT
    COUNT(*) AS target_clients
FROM clients AS c
JOIN inbound_client_ips AS ip
     ON ip.client_email = c.email
WHERE c.limit_ip > 0
  AND json_valid(ip.ips)
  AND json_type(ip.ips) = 'array'
  AND json_array_length(ip.ips) = 1;
SQL
}

if [[ "$MODE" != "--apply" ]]; then
    echo "Клиенты, которым будет установлен limitIp=0:"
    show_targets
    echo
    echo "Для применения запустите:"
    echo "$0 --apply"
    exit 0
fi

backup_file="/root/x-ui.db.before-one-ip-limit-disable-$(date +%F-%H%M%S)"

echo "Создание резервной копии: $backup_file"
sqlite3 "$DB" ".backup '$backup_file'"

xui_stopped=0

restart_xui() {
    if [[ "$xui_stopped" -eq 1 ]]; then
        systemctl start x-ui
    fi
}

trap restart_xui EXIT

echo "Остановка x-ui..."
systemctl stop x-ui
xui_stopped=1

echo "Изменение базы..."
sqlite3 "$DB" <<'SQL'
.bail on
.headers on
.mode column

BEGIN IMMEDIATE;

CREATE TEMP TABLE targets (
    email TEXT PRIMARY KEY
);

INSERT INTO targets(email)
SELECT ip.client_email
FROM inbound_client_ips AS ip
WHERE json_valid(ip.ips)
  AND json_type(ip.ips) = 'array'
  AND json_array_length(ip.ips) = 1
  AND EXISTS (
      SELECT 1
      FROM inbounds AS i
      JOIN json_each(i.settings, '$.clients') AS c
      WHERE json_extract(c.value, '$.email') = ip.client_email
        AND CAST(
            COALESCE(json_extract(c.value, '$.limitIp'), 0)
            AS INTEGER
        ) > 0
  );

SELECT COUNT(*) AS target_clients
FROM targets;

UPDATE inbounds
SET settings = json_set(
    settings,
    '$.clients',
    json(
        (
            SELECT json_group_array(
                json(
                    CASE
                        WHEN EXISTS (
                            SELECT 1
                            FROM targets AS t
                            WHERE t.email = json_extract(c.value, '$.email')
                        )
                        THEN json_set(c.value, '$.limitIp', 0)
                        ELSE c.value
                    END
                )
            )
            FROM json_each(inbounds.settings, '$.clients') AS c
        )
    )
)
WHERE json_valid(settings)
  AND json_type(settings, '$.clients') = 'array'
  AND EXISTS (
      SELECT 1
      FROM json_each(inbounds.settings, '$.clients') AS c
      JOIN targets AS t
        ON t.email = json_extract(c.value, '$.email')
  );

SELECT changes() AS inbounds_updated;

DELETE FROM inbound_client_ips
WHERE client_email IN (
    SELECT email
    FROM targets
);

SELECT changes() AS ip_rows_deleted;

COMMIT;

PRAGMA integrity_check;
SQL

echo "Запуск x-ui..."
systemctl start x-ui
xui_stopped=0
trap - EXIT

echo
echo "Проверка сервиса:"
systemctl is-active x-ui

echo
echo "Распределение оставшихся лимитов:"
sqlite3 -readonly "$DB" <<'SQL'
.headers on
.mode column

WITH clients AS (
    SELECT
        CAST(
            COALESCE(json_extract(c.value, '$.limitIp'), 0)
            AS INTEGER
        ) AS limit_ip
    FROM inbounds AS i
    JOIN json_each(i.settings, '$.clients') AS c
)
SELECT
    limit_ip,
    COUNT(*) AS clients
FROM clients
GROUP BY limit_ip
ORDER BY limit_ip;

SELECT
    COUNT(*) AS ip_table_rows,
    SUM(
        json_array_length(
            CASE WHEN json_valid(ips) THEN ips ELSE '[]' END
        )
    ) AS saved_ip_entries
FROM inbound_client_ips;
SQL

echo
echo "Готово. Резервная копия: $backup_file"
