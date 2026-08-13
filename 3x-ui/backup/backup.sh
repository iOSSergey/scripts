#!/usr/bin/env bash
set -euo pipefail

readonly BACKUP_ROOT="/root/backup"
readonly NATIVE_DB_PATH="/etc/x-ui/x-ui.db"

# Docker mode expects this exact running container name and bind mount:
#   /root/3x-ui/db/ on the Docker host -> /etc/x-ui/ in the container
readonly DOCKER_CONTAINER_NAME="3x-ui"
readonly DOCKER_HOST_DB_PATH="/root/3x-ui/db/x-ui.db"
readonly DOCKER_CONTAINER_DB_PATH="/etc/x-ui/x-ui.db"

usage() {
  cat >&2 <<'USAGE'
Usage:
  ./backup.sh <host> <native|docker>

Examples:
  ./backup.sh solaro native
  ./backup.sh lobasto docker
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

validate_host() {
  local value="$1"

  if [[ ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    error "invalid host: $value"
    exit 1
  fi

  if [[ "$value" == "." || "$value" == ".." ]]; then
    error "invalid host path segment: $value"
    exit 1
  fi
}

validate_deployment() {
  local value="$1"

  case "$value" in
    native | docker)
      ;;
    *)
      error "invalid deployment type: $value (expected native or docker)"
      exit 1
      ;;
  esac
}

safe_remote_snapshot_path() {
  local path="$1"

  [[ "$path" == /tmp/x-ui-backup.*.db ]]
}

safe_local_path() {
  local path="$1"

  [[ "$path" == "$backup_dir"/x-ui_*.db || "$path" == "$backup_dir"/.x-ui_*.db.tmp.* ]]
}

cleanup() {
  local cleanup_status=$?

  if [[ -n "${remote_snapshot:-}" ]]; then
    if safe_remote_snapshot_path "$remote_snapshot"; then
      ssh "$host" "rm -f -- '$remote_snapshot'" >/dev/null 2>&1 || true
    else
      error "refusing to remove unsafe remote temporary path during cleanup: $remote_snapshot"
    fi
  fi

  if [[ -n "${local_tmp:-}" && -e "$local_tmp" ]]; then
    if safe_local_path "$local_tmp"; then
      rm -f -- "$local_tmp"
    else
      error "refusing to remove unsafe local temporary path during cleanup: $local_tmp"
    fi
  fi

  if [[ "${backup_verified:-0}" != "1" && -n "${backup_path:-}" && -e "$backup_path" ]]; then
    if safe_local_path "$backup_path"; then
      rm -f -- "$backup_path"
    else
      error "refusing to remove unsafe backup path during cleanup: $backup_path"
    fi
  fi

  exit "$cleanup_status"
}

create_remote_snapshot() {
  ssh "$host" bash -s -- "$deployment" "$NATIVE_DB_PATH" "$DOCKER_CONTAINER_NAME" "$DOCKER_HOST_DB_PATH" "$DOCKER_CONTAINER_DB_PATH" <<'REMOTE_SCRIPT'
set -euo pipefail

deployment="$1"
native_db_path="$2"
docker_container_name="$3"
docker_host_db_path="$4"
docker_container_db_path="$5"

remote_snapshot=""
container_name=""
keep_remote_snapshot=0

error() {
  echo "Error: $*" >&2
}

require_remote_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    error "required remote command not found: $command_name"
    exit 1
  fi
}

safe_remote_snapshot_path() {
  local path="$1"

  [[ "$path" == /tmp/x-ui-backup.*.db ]]
}

cleanup_remote() {
  if [[ "$keep_remote_snapshot" != "1" && -n "$remote_snapshot" ]]; then
    if safe_remote_snapshot_path "$remote_snapshot"; then
      rm -f -- "$remote_snapshot" || true
    else
      error "refusing to remove unsafe remote temporary path: $remote_snapshot"
    fi
  fi
}

trap cleanup_remote EXIT
trap 'cleanup_remote; exit 130' INT
trap 'cleanup_remote; exit 143' TERM

case "$deployment" in
  native)
    require_remote_command sqlite3
    require_remote_command mktemp
    require_remote_command rm

    if [[ ! -r "$native_db_path" ]]; then
      error "remote SQLite database is not readable: $native_db_path"
      exit 1
    fi

    remote_snapshot="$(mktemp /tmp/x-ui-backup.XXXXXX.db)"

    sqlite3 -readonly "$native_db_path" ".backup $remote_snapshot"
    integrity="$(sqlite3 -readonly "$remote_snapshot" "PRAGMA integrity_check;")"

    if [[ "$integrity" != "ok" ]]; then
      error "remote snapshot integrity check failed: $integrity"
      exit 1
    fi

    keep_remote_snapshot=1
    echo "REMOTE_SNAPSHOT=$remote_snapshot"
    echo "SOURCE=$native_db_path"
    ;;

  docker)
    require_remote_command docker
    require_remote_command sqlite3
    require_remote_command mktemp
    require_remote_command rm

    container_id="$(docker ps --quiet --filter "name=^/${docker_container_name}$")"
    if [[ -z "$container_id" || "$container_id" == *$'\n'* ]]; then
      error "cannot uniquely identify running 3x-ui container by exact name: $docker_container_name"
      error "set DOCKER_CONTAINER_NAME at the top of backup.sh to the stable running container name"
      exit 1
    fi

    container_name="$(docker inspect --format '{{.Name}}' "$container_id")"
    container_name="${container_name#/}"

    if [[ ! -r "$docker_host_db_path" ]]; then
      error "remote SQLite database is not readable for Docker deployment: $docker_host_db_path"
      exit 1
    fi

    remote_snapshot="$(mktemp /tmp/x-ui-backup.XXXXXX.db)"

    sqlite3 -readonly "$docker_host_db_path" ".backup $remote_snapshot"
    integrity="$(sqlite3 -readonly "$remote_snapshot" "PRAGMA integrity_check;")"

    if [[ "$integrity" != "ok" ]]; then
      error "remote snapshot integrity check failed: $integrity"
      exit 1
    fi

    keep_remote_snapshot=1
    echo "REMOTE_SNAPSHOT=$remote_snapshot"
    echo "SOURCE=container:${container_name}:${docker_container_db_path} host-path:${docker_host_db_path}"
    ;;

  *)
    error "invalid deployment type received by remote script: $deployment"
    exit 1
    ;;
esac
REMOTE_SCRIPT
}

if (( $# != 2 )); then
  usage
  exit 1
fi

host="$1"
deployment="$2"

validate_host "$host"
validate_deployment "$deployment"

require_command ssh
require_command scp
require_command sqlite3
require_command date
require_command mkdir
require_command mktemp
require_command rm
require_command ln
require_command du
require_command cut

week="$(date '+%G-W%V')"
timestamp="$(date '+%Y%m%d_%H%M%S')"
backup_dir="${BACKUP_ROOT}/${host}/x-ui/${week}"
backup_name="x-ui_${timestamp}.db"
backup_path="${backup_dir}/${backup_name}"
local_tmp=""
remote_snapshot=""
source_description=""
backup_verified=0

trap cleanup EXIT INT TERM

mkdir -p "$backup_dir"

suffix=2
while [[ -e "$backup_path" ]]; do
  backup_name="x-ui_${timestamp}_${suffix}.db"
  backup_path="${backup_dir}/${backup_name}"
  suffix=$((suffix + 1))
done

local_tmp="${backup_dir}/.${backup_name}.tmp.$$"

if [[ -e "$local_tmp" ]]; then
  error "local temporary file already exists: $local_tmp"
  exit 1
fi

if ! ssh "$host" true; then
  error "cannot connect to host over SSH: $host"
  exit 1
fi

remote_output="$(create_remote_snapshot)"

while IFS='=' read -r key value; do
  case "$key" in
    REMOTE_SNAPSHOT)
      remote_snapshot="$value"
      ;;
    SOURCE)
      source_description="$value"
      ;;
  esac
done <<< "$remote_output"

if [[ -z "$remote_snapshot" ]]; then
  error "remote script did not return snapshot path"
  exit 1
fi

if ! safe_remote_snapshot_path "$remote_snapshot"; then
  error "remote script returned unsafe snapshot path: $remote_snapshot"
  exit 1
fi

if [[ -z "$source_description" ]]; then
  error "remote script did not return source description"
  exit 1
fi

scp "${host}:${remote_snapshot}" "$local_tmp"

local_integrity="$(sqlite3 -readonly "$local_tmp" "PRAGMA integrity_check;")"

if [[ "$local_integrity" != "ok" ]]; then
  error "local backup integrity check failed: $local_integrity"
  exit 1
fi

if ! ln "$local_tmp" "$backup_path"; then
  error "backup file already exists or cannot be created: $backup_path"
  exit 1
fi

backup_verified=1
rm -f -- "$local_tmp"
local_tmp=""

ssh "$host" "rm -f -- '$remote_snapshot'"
remote_snapshot=""

size="$(du -h "$backup_path" | cut -f1)"

cat <<RESULT
Backup completed successfully

Host:       $host
Deployment: $deployment
Source:     $source_description
Week:       $week
Backup:     $backup_path
Integrity:  $local_integrity
Size:       $size
RESULT
