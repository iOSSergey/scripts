#!/usr/bin/env bash
set -euo pipefail

readonly DB_PATH="/etc/x-ui/x-ui.db"
readonly ANALYTICS_TZ="+0300"
readonly SECONDS_PER_DAY=86400

usage() {
  cat >&2 <<'USAGE'
Usage:
  ./last-online.sh YYYY-MM-DD
  ./last-online.sh FROM TO

Examples:
  ./last-online.sh 2026-08-06
  ./last-online.sh 2026-08-01 2026-08-06
USAGE
}

error() {
  echo "Error: $*" >&2
}

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    error "required command not found: $command_name"
    exit 1
  fi
}

validate_date() {
  local value="$1"
  local normalized

  if [[ ! "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    error "invalid date format: $value (expected YYYY-MM-DD)"
    exit 1
  fi

  if ! normalized="$(date -u -d "$value" '+%F' 2>/dev/null)"; then
    error "invalid calendar date: $value"
    exit 1
  fi

  if [[ "$normalized" != "$value" ]]; then
    error "invalid calendar date: $value"
    exit 1
  fi
}

date_to_utc_epoch_seconds() {
  local date_value="$1"

  date -u -d "${date_value} 00:00:00 ${ANALYTICS_TZ}" '+%s'
}

if (( $# < 1 || $# > 2 )); then
  usage
  exit 1
fi

require_command sqlite3
require_command date

if [[ ! -e "$DB_PATH" ]]; then
  error "SQLite database does not exist: $DB_PATH"
  exit 1
fi

if [[ ! -r "$DB_PATH" ]]; then
  error "SQLite database is not readable: $DB_PATH"
  exit 1
fi

from_date="$1"
to_date="${2:-$1}"

validate_date "$from_date"
validate_date "$to_date"

from_day_epoch="$(date -u -d "${from_date} 00:00:00" '+%s')"
to_day_epoch="$(date -u -d "${to_date} 00:00:00" '+%s')"

if (( from_day_epoch > to_day_epoch )); then
  error "FROM date must be earlier than or equal to TO date: $from_date > $to_date"
  exit 1
fi

range_start_ms="$(( $(date_to_utc_epoch_seconds "$from_date") * 1000 ))"
range_end_ms="$(( ( $(date_to_utc_epoch_seconds "$to_date") + SECONDS_PER_DAY ) * 1000 ))"

sqlite3 -readonly -header -column "$DB_PATH" <<SQL
SELECT
  email,
  datetime(last_online / 1000, 'unixepoch', '+3 hours') AS last_online
FROM client_traffics
WHERE last_online >= ${range_start_ms}
  AND last_online < ${range_end_ms}
ORDER BY client_traffics.last_online DESC;
SQL
