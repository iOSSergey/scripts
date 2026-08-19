#!/usr/bin/env bash
set -euo pipefail

readonly DB_PATH="/etc/x-ui/x-ui.db"
readonly ANALYTICS_TZ_OFFSET="+3 hours"
readonly BYTES_PER_GIB=1073741824
readonly RECENT_WINDOW_SECONDS=604800

usage() {
  cat >&2 <<'USAGE'
Usage:
  ./high-usage.sh

Shows clients whose current usage traffic is above the median usage among
clients seen within the last 7 days.
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

require_sqlite_db() {
  if [[ ! -e "$DB_PATH" ]]; then
    error "SQLite database does not exist: $DB_PATH"
    exit 1
  fi

  if [[ ! -r "$DB_PATH" ]]; then
    error "SQLite database is not readable: $DB_PATH"
    exit 1
  fi
}

require_table() {
  local exists

  exists="$(sqlite3 -readonly "$DB_PATH" \
    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'client_traffics';")"

  if [[ "$exists" != "1" ]]; then
    error "required table not found: client_traffics"
    exit 1
  fi
}

print_report() {
  sqlite3 -readonly -header -column "$DB_PATH" <<SQL
WITH clients AS (
  SELECT
    email,
    up,
    down,
    up + down AS usage_bytes,
    last_online
  FROM client_traffics
  WHERE last_online > 0
    AND last_online >= (CAST(strftime('%s', 'now') AS INTEGER) - ${RECENT_WINDOW_SECONDS}) * 1000
),
ranked_clients AS (
  SELECT
    clients.*,
    ROW_NUMBER() OVER (ORDER BY usage_bytes) AS row_number,
    COUNT(*) OVER () AS total_rows
  FROM clients
),
median AS (
  SELECT COALESCE(AVG(usage_bytes), 0) AS median_usage_bytes
  FROM ranked_clients
  WHERE row_number IN ((total_rows + 1) / 2, (total_rows + 2) / 2)
)
SELECT
  COUNT(*) AS recent_user_count,
  COALESCE(SUM(usage_bytes > median_usage_bytes), 0) AS above_median_count,
  printf('%.2f GiB', median_usage_bytes / ${BYTES_PER_GIB}.0) AS median_usage,
  printf('%.2f GiB', COALESCE(MAX(usage_bytes), 0) / ${BYTES_PER_GIB}.0) AS max_usage,
  printf('%.2f GiB', COALESCE(AVG(usage_bytes), 0) / ${BYTES_PER_GIB}.0) AS avg_usage
FROM clients, median;

WITH clients AS (
  SELECT
    email,
    up,
    down,
    up + down AS usage_bytes,
    last_online
  FROM client_traffics
  WHERE last_online > 0
    AND last_online >= (CAST(strftime('%s', 'now') AS INTEGER) - ${RECENT_WINDOW_SECONDS}) * 1000
),
ranked_clients AS (
  SELECT
    clients.*,
    ROW_NUMBER() OVER (ORDER BY usage_bytes) AS row_number,
    COUNT(*) OVER () AS total_rows
  FROM clients
),
median AS (
  SELECT COALESCE(AVG(usage_bytes), 0) AS median_usage_bytes
  FROM ranked_clients
  WHERE row_number IN ((total_rows + 1) / 2, (total_rows + 2) / 2)
)
SELECT
  email,
  printf('%.2f GiB', usage_bytes / ${BYTES_PER_GIB}.0) AS usage,
  printf('%.2f GiB', up / ${BYTES_PER_GIB}.0) AS up,
  printf('%.2f GiB', down / ${BYTES_PER_GIB}.0) AS down,
  datetime(last_online / 1000, 'unixepoch', '${ANALYTICS_TZ_OFFSET}') AS last_online
FROM clients, median
WHERE usage_bytes > median_usage_bytes
ORDER BY usage_bytes DESC, email;
SQL
}

if (( $# > 1 )); then
  usage
  exit 1
fi

if (( $# == 1 )); then
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    *)
      error "unknown argument: $1"
      usage
      exit 1
      ;;
  esac
fi

require_command sqlite3
require_sqlite_db
require_table
print_report
