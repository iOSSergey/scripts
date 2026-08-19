#!/usr/bin/env bash
set -euo pipefail

readonly DB_PATH="${XUI_DB_PATH:-/etc/x-ui/x-ui.db}"
readonly DEFAULT_MIN_IPS=2
readonly DEFAULT_THRESHOLD_SECONDS=120
readonly ANALYTICS_TZ_OFFSET="+3 hours"

usage() {
  cat >&2 <<'USAGE'
Usage:
  ./two-ip.sh
  ./two-ip.sh --min-ips N
  ./two-ip.sh --threshold SECONDS
  ./two-ip.sh --clear
  ./two-ip.sh --sample SECONDS [--min-ips N] [--threshold SECONDS]

Examples:
  ./two-ip.sh
  XUI_DB_PATH=~/Downloads/x-ui.db ./two-ip.sh
  ./two-ip.sh --min-ips 3
  ./two-ip.sh --threshold 60
  ./two-ip.sh --clear
  ./two-ip.sh --sample 120
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

validate_positive_integer() {
  local name="$1"
  local value="$2"

  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    error "$name must be a positive integer: $value"
    exit 1
  fi
}

require_table() {
  local exists

  exists="$(sqlite3 -readonly "$DB_PATH" \
    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'inbound_client_ips';")"

  if [[ "$exists" != "1" ]]; then
    error "required table not found: inbound_client_ips"
    exit 1
  fi
}

require_json_functions() {
  local ok

  if ! ok="$(sqlite3 -readonly "$DB_PATH" "SELECT json_valid('[]');" 2>/dev/null)"; then
    error "SQLite JSON functions are not available"
    exit 1
  fi

  if [[ "$ok" != "1" ]]; then
    error "SQLite JSON functions returned an unexpected result"
    exit 1
  fi
}

print_report() {
  local min_ips="$1"
  local threshold_seconds="$2"

  sqlite3 -readonly -header -column "$DB_PATH" <<SQL
WITH raw_ips AS (
  SELECT
    inbound_client_ips.client_email AS email,
    CASE
      WHEN json_each.type = 'object' THEN json_extract(json_each.value, '$.ip')
      ELSE json_each.value
    END AS ip,
    CASE
      WHEN json_each.type = 'object' THEN json_extract(json_each.value, '$.timestamp')
      ELSE NULL
    END AS seen_at_epoch,
    CAST(json_each.key AS INTEGER) AS source_order
  FROM inbound_client_ips,
       json_each(
         CASE
           WHEN json_valid(inbound_client_ips.ips) THEN inbound_client_ips.ips
           ELSE '[]'
         END
       )
  WHERE inbound_client_ips.ips IS NOT NULL
    AND inbound_client_ips.ips != ''
),
valid_ips AS (
  SELECT
    email,
    ip,
    CAST(seen_at_epoch AS INTEGER) AS seen_at_epoch,
    source_order
  FROM raw_ips
  WHERE ip IS NOT NULL
    AND ip != ''
    AND seen_at_epoch IS NOT NULL
),
distinct_ip_counts AS (
  SELECT
    email,
    COUNT(DISTINCT ip) AS ip_count
  FROM valid_ips
  GROUP BY email
),
ordered_ips AS (
  SELECT
    email,
    ip,
    seen_at_epoch,
    LAG(ip) OVER (
      PARTITION BY email
      ORDER BY seen_at_epoch, source_order
    ) AS previous_ip,
    LAG(seen_at_epoch) OVER (
      PARTITION BY email
      ORDER BY seen_at_epoch, source_order
    ) AS previous_seen_at_epoch
  FROM valid_ips
),
suspicious_pairs AS (
  SELECT
    ordered_ips.email,
    distinct_ip_counts.ip_count,
    ordered_ips.previous_ip,
    ordered_ips.previous_seen_at_epoch,
    ordered_ips.ip,
    ordered_ips.seen_at_epoch,
    ordered_ips.seen_at_epoch - ordered_ips.previous_seen_at_epoch AS gap_seconds
  FROM ordered_ips
  JOIN distinct_ip_counts ON distinct_ip_counts.email = ordered_ips.email
  WHERE ordered_ips.previous_ip IS NOT NULL
    AND ordered_ips.previous_ip != ordered_ips.ip
    AND ordered_ips.seen_at_epoch - ordered_ips.previous_seen_at_epoch BETWEEN 0 AND ${threshold_seconds}
    AND distinct_ip_counts.ip_count >= ${min_ips}
)
SELECT
  email,
  ip_count,
  previous_ip,
  datetime(previous_seen_at_epoch, 'unixepoch', '${ANALYTICS_TZ_OFFSET}') AS previous_seen_at,
  ip AS next_ip,
  datetime(seen_at_epoch, 'unixepoch', '${ANALYTICS_TZ_OFFSET}') AS next_seen_at,
  gap_seconds
FROM suspicious_pairs
ORDER BY gap_seconds, next_seen_at DESC, email;
SQL
}

clear_ip_log() {
  local changed

  changed="$(sqlite3 "$DB_PATH" "UPDATE inbound_client_ips SET ips = ''; SELECT changes();")"
  echo "Cleared inbound_client_ips.ips for ${changed} row(s)."
}

mode="report"
min_ips="$DEFAULT_MIN_IPS"
threshold_seconds="$DEFAULT_THRESHOLD_SECONDS"
sample_seconds=""

while (( $# > 0 )); do
  case "$1" in
    --min-ips)
      if (( $# < 2 )); then
        error "missing value for --min-ips"
        usage
        exit 1
      fi
      min_ips="$2"
      shift 2
      ;;
    --clear)
      if [[ "$mode" != "report" ]]; then
        error "--clear cannot be combined with --sample"
        usage
        exit 1
      fi
      mode="clear"
      shift
      ;;
    --threshold)
      if (( $# < 2 )); then
        error "missing value for --threshold"
        usage
        exit 1
      fi
      threshold_seconds="$2"
      shift 2
      ;;
    --sample)
      if [[ "$mode" != "report" ]]; then
        error "--sample cannot be combined with --clear"
        usage
        exit 1
      fi
      if (( $# < 2 )); then
        error "missing value for --sample"
        usage
        exit 1
      fi
      mode="sample"
      sample_seconds="$2"
      shift 2
      ;;
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
done

validate_positive_integer "--min-ips" "$min_ips"
validate_positive_integer "--threshold" "$threshold_seconds"

if [[ "$mode" == "sample" ]]; then
  validate_positive_integer "--sample" "$sample_seconds"
fi

require_command sqlite3
require_command sleep
require_sqlite_db
require_table
require_json_functions

case "$mode" in
  report)
    print_report "$min_ips" "$threshold_seconds"
    ;;
  clear)
    clear_ip_log
    ;;
  sample)
    clear_ip_log
    echo "Waiting ${sample_seconds} second(s) before reading fresh IP Log data..."
    sleep "$sample_seconds"
    print_report "$min_ips" "$threshold_seconds"
    ;;
  *)
    error "internal error: unsupported mode: $mode"
    exit 1
    ;;
esac
