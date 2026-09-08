#!/usr/bin/env bash
set -euo pipefail

CONTAINER="3x-ui"
DOCKER_DB="/root/3x-ui/db/x-ui.db"
LOCAL_DB="/etc/x-ui/x-ui.db"
LOCAL_SNAPSHOT="/tmp/x-ui.snapshot.db"
SSH_CONFIG="${SSH_CONFIG:-$HOME/.ssh/config}"
SOURCE_HOST=""
TARGET_HOST=""
NON_INTERACTIVE="no"
APPLY_NOW="no"
OVERWRITE_SNAPSHOT="ask"
ROLLBACK_PROMPT="yes"
ROLLBACK_PROMPT_SET="no"

usage() {
    cat <<USAGE
Copy a 3X-UI SQLite database from an SSH source to a local or remote target.

Usage:
  $0 [options]
  $0 --source <host> --target <host|local> [options]

Modes:
  Interactive: choose hosts from ~/.ssh/config or enter them manually, then
  confirm before applying. Requires a terminal. The source is always an SSH
  host; the target may also be this machine (local).

  CLI: --source and --target must be used together. Applies WITHOUT confirmation,
  overwrites an existing snapshot by default, and skips the rollback prompt.
  Hosts may be SSH aliases or destinations such as root@server.example.com.

Options:
  --source <host>        SSH source host to copy the database from.
  --target <host|local>  Target host to apply the database to.
  --snapshot <path>      Local snapshot path. Default: /tmp/x-ui.snapshot.db.
  --yes                 Skip apply confirmation; other interactive prompts remain.
                        Implied when --source and --target are set.
  --force-snapshot       Overwrite an existing local snapshot.
  --keep-snapshot        Reuse an existing snapshot after an integrity check.
                        Download a fresh snapshot if none exists.
  --rollback-prompt      Ask about rollback after apply. Default in interactive mode.
  --no-rollback-prompt   Skip the rollback prompt. Default in CLI mode.
  -h, --help             Show this help and exit.

Database handling:
  Replaces the entire target database; records are not merged. Preserves these
  target settings: webPort, webBasePath, webCertFile, webKeyFile, subCertFile,
  subKeyFile, xrayTemplateConfig. Certificate files themselves are not copied.
  Database schemas must match. The target is stopped during replacement.
  A backup is saved beside the target database and its path is printed.

Supported installations (Docker is checked first):
  Docker:  container 3x-ui, host database /root/3x-ui/db/x-ui.db.
  System:  systemd service x-ui, database /etc/x-ui/x-ui.db.

Requirements:
  On this machine: bash, awk, ssh, scp, sqlite3, and standard Unix utilities.
  On source/target hosts: bash, sqlite3, and standard Unix utilities.
  On the target: sha256sum or shasum, plus Docker or systemctl.
  The source user must be able to read the database and create a snapshot.
  The target user must be able to replace the database and control the service.
  The script does not invoke sudo. For unattended runs, configure SSH access
  without password or host-key prompts.

Environment:
  SSH_CONFIG            File used to populate the interactive host menu.
                        Default: \$HOME/.ssh/config. Does not change SSH's own
                        connection configuration.

Examples:
  # Interactive migration
  $0

  # Apply immediately from one SSH host to another
  $0 --source ams --target spb

  # Apply to the machine running this script
  $0 --source root@source.example.com --target local

  # Reuse a saved snapshot, or download it if missing
  $0 --source ams --target spb --snapshot /tmp/ams.db --keep-snapshot

  # Apply immediately, then offer an interactive rollback
  $0 --source ams --target spb --rollback-prompt
USAGE
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --source)
                [ "${2:-}" ] || {
                    echo "ERROR: --source requires a value" >&2
                    exit 1
                }
                SOURCE_HOST="$2"
                shift 2
                ;;
            --target)
                [ "${2:-}" ] || {
                    echo "ERROR: --target requires a value" >&2
                    exit 1
                }
                TARGET_HOST="$2"
                shift 2
                ;;
            --snapshot)
                [ "${2:-}" ] || {
                    echo "ERROR: --snapshot requires a value" >&2
                    exit 1
                }
                LOCAL_SNAPSHOT="$2"
                shift 2
                ;;
            --yes)
                APPLY_NOW="yes"
                shift
                ;;
            --force-snapshot)
                OVERWRITE_SNAPSHOT="yes"
                shift
                ;;
            --keep-snapshot)
                OVERWRITE_SNAPSHOT="no"
                shift
                ;;
            --rollback-prompt)
                ROLLBACK_PROMPT="yes"
                ROLLBACK_PROMPT_SET="yes"
                shift
                ;;
            --no-rollback-prompt)
                ROLLBACK_PROMPT="no"
                ROLLBACK_PROMPT_SET="yes"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "ERROR: unknown argument: $1" >&2
                usage >&2
                exit 1
                ;;
        esac
    done

    if [ -n "$SOURCE_HOST" ] || [ -n "$TARGET_HOST" ]; then
        [ -n "$SOURCE_HOST" ] && [ -n "$TARGET_HOST" ] || {
            echo "ERROR: --source and --target must be used together" >&2
            exit 1
        }

        NON_INTERACTIVE="yes"
        APPLY_NOW="yes"

        if [ "$OVERWRITE_SNAPSHOT" = "ask" ]; then
            OVERWRITE_SNAPSHOT="yes"
        fi

        if [ "$ROLLBACK_PROMPT_SET" = "no" ]; then
            ROLLBACK_PROMPT="no"
        fi
    fi
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: required command not found: $1"
        exit 1
    }
}

ensure_interactive_input() {
    if [ ! -t 0 ]; then
        echo "ERROR: interactive mode needs a terminal." >&2
        echo "Use CLI mode instead, for example:" >&2
        echo "  $0 --source ams --target spb" >&2
        exit 1
    fi
}

list_ssh_hosts() {
    [ -f "$SSH_CONFIG" ] || return 0

    awk '
        tolower($1) == "host" {
            for (i = 2; i <= NF; i++) {
                if ($i !~ /^[#*?[]/ && $i !~ /[*?]/) {
                    print $i
                }
            }
        }
    ' "$SSH_CONFIG"
}

detect_local_db() {
    if command -v docker >/dev/null 2>&1 \
        && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER" \
        && [ -f "$DOCKER_DB" ]; then
        echo "docker:$DOCKER_DB"
    elif [ -f "$LOCAL_DB" ]; then
        echo "local:$LOCAL_DB"
    else
        echo "ERROR: local 3X-UI database not found" >&2
        return 1
    fi
}

select_ssh_host() {
    local title="$1"
    local allow_local="${2:-no}"
    local hosts=()
    local item choice idx

    while IFS= read -r item; do
        [ -n "$item" ] && hosts+=("$item")
    done < <(list_ssh_hosts)

    echo >&2
    echo "$title" >&2

    if [ ! -f "$SSH_CONFIG" ]; then
        echo "SSH config not found: $SSH_CONFIG" >&2
        echo "Use m to enter a host manually." >&2
        echo >&2
    elif [ "${#hosts[@]}" -eq 0 ]; then
        echo "No concrete hosts found in: $SSH_CONFIG" >&2
        echo "Use m to enter a host manually." >&2
        echo >&2
    fi

    idx=1
    if [ "$allow_local" = "yes" ]; then
        echo "  $idx) local (this machine)" >&2
        idx=$((idx + 1))
    fi

    for item in "${hosts[@]}"; do
        echo "  $idx) $item" >&2
        idx=$((idx + 1))
    done

    echo "  m) enter host manually" >&2
    echo "  q) quit" >&2
    echo >&2

    while true; do
        read -rp "Select: " choice

        case "$choice" in
            q|Q)
                echo "Cancelled" >&2
                printf '%s\n' "__QUIT__"
                return 0
                ;;
            m|M)
                read -rp "Enter SSH host alias: " item
                [ -n "$item" ] || {
                    echo "ERROR: host is empty" >&2
                    continue
                }
                printf '%s\n' "$item"
                return 0
                ;;
        esac

        case "$choice" in
            ''|*[!0-9]*)
                echo "ERROR: enter a number, m, or q" >&2
                ;;
            *)
                idx="$choice"
                if [ "$allow_local" = "yes" ]; then
                    if [ "$idx" -eq 1 ]; then
                        printf '%s\n' "local"
                        return 0
                    fi
                    idx=$((idx - 1))
                fi

                if [ "$idx" -ge 1 ] && [ "$idx" -le "${#hosts[@]}" ]; then
                    printf '%s\n' "${hosts[$((idx - 1))]}"
                    return 0
                fi

                echo "ERROR: selection out of range" >&2
                ;;
        esac
    done
}

detect_remote_db() {
    local host="$1"

    # shellcheck disable=SC2029
    ssh "$host" "CONTAINER='$CONTAINER' DOCKER_DB='$DOCKER_DB' LOCAL_DB='$LOCAL_DB' bash -s" <<'REMOTE'
set -euo pipefail

if command -v docker >/dev/null 2>&1 \
    && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER" \
    && [ -f "$DOCKER_DB" ]; then
    echo "docker:$DOCKER_DB"
elif [ -f "$LOCAL_DB" ]; then
    echo "local:$LOCAL_DB"
else
    echo "ERROR: 3X-UI database not found" >&2
    exit 1
fi
REMOTE
}

fetch_snapshot() {
    local source_host="$1"
    local location mode db_path remote_snapshot check

    location="$(detect_remote_db "$source_host")"
    mode="${location%%:*}"
    db_path="${location#*:}"
    remote_snapshot="/tmp/x-ui.snapshot.$(date +%F-%H%M%S).$$.db"

    echo "Source: $source_host"
    echo "Source mode: $mode"
    echo "Source DB: $db_path"

    # shellcheck disable=SC2029
    ssh "$source_host" "SOURCE_DB='$db_path' REMOTE_SNAPSHOT='$remote_snapshot' bash -s" <<'REMOTE'
set -euo pipefail

sqlite3 "$SOURCE_DB" ".backup '$REMOTE_SNAPSHOT'"

CHECK=$(sqlite3 "$REMOTE_SNAPSHOT" "PRAGMA integrity_check;")
[ "$CHECK" = "ok" ] || {
    echo "ERROR: remote snapshot integrity check failed: $CHECK" >&2
    exit 1
}
REMOTE

    scp "$source_host:$remote_snapshot" "$LOCAL_SNAPSHOT"
    # shellcheck disable=SC2029
    ssh "$source_host" "rm -f '$remote_snapshot'"

    check=$(sqlite3 "$LOCAL_SNAPSHOT" "PRAGMA integrity_check;")
    [ "$check" = "ok" ] || {
        echo "ERROR: downloaded snapshot integrity check failed: $check"
        exit 1
    }

    echo "Snapshot downloaded: $LOCAL_SNAPSHOT"
}

describe_target() {
    local target_host="$1"
    local location mode db_path

    if [ "$target_host" = "local" ]; then
        location="$(detect_local_db)"
    else
        location="$(detect_remote_db "$target_host")"
    fi

    mode="${location%%:*}"
    db_path="${location#*:}"

    printf '%s:%s:%s\n' "$mode" "$db_path" "$(dirname "$db_path")"
}

emit_apply_script() {
    cat <<'APPLY'
set -euo pipefail

CONTAINER="3x-ui"
DOCKER_DB="/root/3x-ui/db/x-ui.db"
LOCAL_DB="/etc/x-ui/x-ui.db"
SERVICE="x-ui"
PRESERVE_KEYS="webPort webBasePath webCertFile webKeyFile subCertFile subKeyFile xrayTemplateConfig"

[ -n "${NEW_DB:-}" ] || {
    echo "ERROR: NEW_DB is not set"
    exit 1
}

[ -f "$NEW_DB" ] || {
    echo "ERROR: NEW_DB not found: $NEW_DB"
    exit 1
}

hash_schema() {
    if command -v sha256sum >/dev/null 2>&1; then
        sqlite3 "$1" ".schema" | sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        sqlite3 "$1" ".schema" | shasum -a 256 | awk '{print $1}'
    else
        echo "ERROR: sha256sum or shasum is required" >&2
        exit 1
    fi
}

detect_target() {
    if command -v docker >/dev/null 2>&1 \
        && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER" \
        && [ -f "$DOCKER_DB" ]; then
        DB="$DOCKER_DB"
        BACKUP_DIR=$(dirname "$DOCKER_DB")
        MODE="docker"
    elif [ -f "$LOCAL_DB" ]; then
        DB="$LOCAL_DB"
        BACKUP_DIR=$(dirname "$LOCAL_DB")
        MODE="local"
    else
        echo "ERROR: target 3X-UI database not found"
        exit 1
    fi

    BACKUP="$BACKUP_DIR/x-ui.backup.$(date +%F-%H%M%S).db"
    PRESERVE_SQL="/tmp/x-ui.preserve-settings.$$.sql"
}

stop_target() {
    if [ "$MODE" = "docker" ]; then
        docker stop "$CONTAINER"
    else
        systemctl stop "$SERVICE"
    fi
}

start_target() {
    if [ "$MODE" = "docker" ]; then
        docker start "$CONTAINER"
    else
        systemctl start "$SERVICE"
    fi
}

rollback_and_exit() {
    local message="$1"

    echo "ERROR: $message"
    cp -a "$BACKUP" "$DB"
    start_target
    exit 1
}

detect_target

echo "Target mode: $MODE"
echo "Target DB: $DB"

CHECK=$(sqlite3 "$NEW_DB" "PRAGMA integrity_check;")
[ "$CHECK" = "ok" ] || {
    echo "ERROR: NEW_DB integrity check failed: $CHECK"
    exit 1
}

LOCAL_SCHEMA=$(hash_schema "$DB")
NEW_SCHEMA=$(hash_schema "$NEW_DB")

[ "$LOCAL_SCHEMA" = "$NEW_SCHEMA" ] || {
    echo "ERROR: database schemas differ"
    echo "Local: $LOCAL_SCHEMA"
    echo "New:   $NEW_SCHEMA"
    exit 1
}

XRAY_FIRST_CHAR=$(sqlite3 "$DB" "SELECT substr(value,1,1) FROM settings WHERE key='xrayTemplateConfig';")
[ "$XRAY_FIRST_CHAR" = "{" ] || {
    echo "ERROR: local xrayTemplateConfig is not JSON"
    exit 1
}

{
    echo "BEGIN;"
    for key in $PRESERVE_KEYS; do
        value=$(sqlite3 "$DB" "SELECT quote(value) FROM settings WHERE key='$key';")
        if [ -n "$value" ]; then
            printf "UPDATE settings SET value = %s WHERE key='%s';\n" "$value" "$key"
        fi
    done
    echo "COMMIT;"
} > "$PRESERVE_SQL"

cp -a "$DB" "$BACKUP"

stop_target

mv "$NEW_DB" "$DB"
sqlite3 "$DB" < "$PRESERVE_SQL"
rm -f "$PRESERVE_SQL"

XRAY_FIRST_CHAR=$(sqlite3 "$DB" "SELECT substr(value,1,1) FROM settings WHERE key='xrayTemplateConfig';")
[ "$XRAY_FIRST_CHAR" = "{" ] || rollback_and_exit "final xrayTemplateConfig is not JSON"

CHECK=$(sqlite3 "$DB" "PRAGMA integrity_check;")
[ "$CHECK" = "ok" ] || rollback_and_exit "final DB integrity check failed: $CHECK"

start_target

echo "Done"
echo "Backup: $BACKUP"
APPLY
}

emit_rollback_script() {
    cat <<'ROLLBACK'
set -euo pipefail

CONTAINER="3x-ui"
DOCKER_DB="/root/3x-ui/db/x-ui.db"
LOCAL_DB="/etc/x-ui/x-ui.db"
SERVICE="x-ui"

[ -n "${BACKUP:-}" ] || {
    echo "ERROR: BACKUP is not set"
    exit 1
}

[ -f "$BACKUP" ] || {
    echo "ERROR: backup not found: $BACKUP"
    exit 1
}

if command -v docker >/dev/null 2>&1 \
    && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER" \
    && [ -f "$DOCKER_DB" ]; then
    DB="$DOCKER_DB"
    MODE="docker"
elif [ -f "$LOCAL_DB" ]; then
    DB="$LOCAL_DB"
    MODE="local"
else
    echo "ERROR: target 3X-UI database not found"
    exit 1
fi

CHECK=$(sqlite3 "$BACKUP" "PRAGMA integrity_check;")
[ "$CHECK" = "ok" ] || {
    echo "ERROR: backup integrity check failed: $CHECK"
    exit 1
}

echo "Rollback mode: $MODE"
echo "Rollback DB: $DB"
echo "Rollback backup: $BACKUP"

cp -a "$DB" "$DB.before-rollback.$(date +%F-%H%M%S)"

if [ "$MODE" = "docker" ]; then
    docker stop "$CONTAINER"
    cp -a "$BACKUP" "$DB"
    docker start "$CONTAINER"
else
    systemctl stop "$SERVICE"
    cp -a "$BACKUP" "$DB"
    systemctl start "$SERVICE"
fi

CHECK=$(sqlite3 "$DB" "PRAGMA integrity_check;")
[ "$CHECK" = "ok" ] || {
    echo "ERROR: DB integrity check after rollback failed: $CHECK"
    exit 1
}

echo "Rollback completed"
ROLLBACK
}

apply_to_local() {
    echo "Applying snapshot to local machine"
    NEW_DB="$LOCAL_SNAPSHOT" bash -s < <(emit_apply_script)
}

apply_to_remote() {
    local target_host="$1"
    local remote_snapshot

    remote_snapshot="/tmp/x-ui.snapshot.apply.$(date +%F-%H%M%S).$$.db"

    echo "Uploading snapshot to: $target_host"
    scp "$LOCAL_SNAPSHOT" "$target_host:$remote_snapshot" || return $?

    echo "Applying snapshot on: $target_host"
    # shellcheck disable=SC2029
    emit_apply_script | ssh "$target_host" "NEW_DB='$remote_snapshot' bash -s"
}

rollback_local() {
    local backup="$1"

    echo "Rolling back local target"
    BACKUP="$backup" bash -s < <(emit_rollback_script)
}

rollback_remote() {
    local target_host="$1"
    local backup="$2"

    echo "Rolling back target: $target_host"
    # shellcheck disable=SC2029
    emit_rollback_script | ssh "$target_host" "BACKUP='$backup' bash -s"
}

main() {
    local answer apply_output apply_status backup_path source_host target_dir target_host target_info
    local target_mode target_db target_staging

    parse_args "$@"

    require_cmd awk
    require_cmd scp
    require_cmd ssh
    require_cmd sqlite3

    if [ "$NON_INTERACTIVE" = "yes" ]; then
        source_host="$SOURCE_HOST"
    else
        ensure_interactive_input
        source_host="$(select_ssh_host "Select source host to copy 3X-UI database from:" "no")"
        [ "$source_host" != "__QUIT__" ] || exit 0
    fi

    if [ -f "$LOCAL_SNAPSHOT" ]; then
        echo
        echo "Existing local snapshot found: $LOCAL_SNAPSHOT"
        case "$OVERWRITE_SNAPSHOT" in
            ask)
                read -rp "Overwrite it with a fresh snapshot? [y/N] " answer
                ;;
            yes)
                answer="yes"
                echo "Overwriting existing snapshot"
                ;;
            no)
                answer="no"
                echo "Reusing existing snapshot"
                ;;
            *)
                echo "ERROR: invalid OVERWRITE_SNAPSHOT value: $OVERWRITE_SNAPSHOT"
                exit 1
                ;;
        esac

        case "$answer" in
            y|Y|yes|YES)
                rm -f "$LOCAL_SNAPSHOT"
                ;;
            *)
                CHECK=$(sqlite3 "$LOCAL_SNAPSHOT" "PRAGMA integrity_check;")
                [ "$CHECK" = "ok" ] || {
                    echo "ERROR: existing local snapshot integrity check failed: $CHECK"
                    exit 1
                }
                echo "Using existing snapshot"
                ;;
        esac
    fi

    if [ ! -f "$LOCAL_SNAPSHOT" ]; then
        fetch_snapshot "$source_host"
    fi

    if [ "$NON_INTERACTIVE" = "yes" ]; then
        target_host="$TARGET_HOST"
    else
        target_host="$(select_ssh_host "Select target host to apply 3X-UI database to:" "yes")"
        [ "$target_host" != "__QUIT__" ] || exit 0
    fi

    target_info="$(describe_target "$target_host")"
    target_mode="${target_info%%:*}"
    target_info="${target_info#*:}"
    target_db="${target_info%%:*}"
    target_dir="${target_info#*:}"
    if [ "$target_host" = "local" ]; then
        target_staging="$LOCAL_SNAPSHOT"
    else
        target_staging="$target_host:/tmp/x-ui.snapshot.apply.<timestamp>.<pid>.db"
    fi

    echo
    echo "Source host: $source_host"
    echo "Target host: $target_host"
    echo "Target mode: $target_mode"
    echo "Target DB: $target_db"
    echo "Target DB folder: $target_dir"
    echo "Target staging copy: $target_staging"
    echo "Snapshot: $LOCAL_SNAPSHOT"
    echo
    if [ "$APPLY_NOW" = "yes" ]; then
        answer="yes"
        echo "Apply snapshot now? yes"
    else
        read -rp "Apply snapshot now? [y/N] " answer
    fi

    case "$answer" in
        y|Y|yes|YES)
            if [ "$target_host" = "local" ]; then
                apply_output="$(apply_to_local)"
            else
                apply_output="$(apply_to_remote "$target_host")"
            fi || {
                apply_status=$?
                printf '%s\n' "$apply_output" >&2
                echo "ERROR: snapshot apply failed (exit code: $apply_status)" >&2
                return "$apply_status"
            }
            echo "$apply_output"

            backup_path="$(printf '%s\n' "$apply_output" | awk -F 'Backup: ' '/^Backup: / {print $2}' | tail -n 1)"
            [ -n "$backup_path" ] || {
                echo "ERROR: could not detect backup path from apply output"
                exit 1
            }

            echo
            echo "Step 3: rollback option"
            echo "Backup available on target: $backup_path"
            if [ "$ROLLBACK_PROMPT" = "yes" ]; then
                read -rp "Rollback target to this backup now? [y/N] " answer
            else
                answer="no"
                echo "Rollback prompt disabled"
            fi

            case "$answer" in
                y|Y|yes|YES)
                    if [ "$target_host" = "local" ]; then
                        rollback_local "$backup_path"
                    else
                        rollback_remote "$target_host" "$backup_path"
                    fi
                    ;;
                *)
                    echo "Rollback skipped"
                    ;;
            esac
            ;;
        *)
            echo "Skipped apply step"
            ;;
    esac
}

main "$@"
