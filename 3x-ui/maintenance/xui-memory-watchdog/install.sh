#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
NORMAL_MIB=80
CRITICAL_MIB=40

usage() {
    cat <<'EOF'
Usage: sudo ./install.sh [--normal-mib N] [--critical-mib N]

Installs and starts xui-memory-watchdog. Thresholds refer to MemAvailable.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --normal-mib)
            NORMAL_MIB=${2:?missing value for --normal-mib}
            shift 2
            ;;
        --critical-mib)
            CRITICAL_MIB=${2:?missing value for --critical-mib}
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

for value in "$NORMAL_MIB" "$CRITICAL_MIB"; do
    if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
        printf 'Thresholds must be positive integers\n' >&2
        exit 2
    fi
done

if (( CRITICAL_MIB > NORMAL_MIB )); then
    printf 'Critical threshold must not exceed normal threshold\n' >&2
    exit 2
fi

if [[ $EUID -ne 0 ]]; then
    printf 'Run this installer as root\n' >&2
    exit 1
fi

if ! systemctl cat x-ui.service >/dev/null 2>&1; then
    printf 'x-ui.service is not installed\n' >&2
    exit 1
fi

install -Dm0755 "$SCRIPT_DIR/xui-memory-watchdog" /usr/local/sbin/xui-memory-watchdog
install -Dm0644 "$SCRIPT_DIR/xui-memory-watchdog.service" /etc/systemd/system/xui-memory-watchdog.service

config_tmp=$(mktemp)
trap 'rm -f "$config_tmp"' EXIT
sed \
    -e "s/^NORMAL_AVAILABLE_MIB=.*/NORMAL_AVAILABLE_MIB=$NORMAL_MIB/" \
    -e "s/^CRITICAL_AVAILABLE_MIB=.*/CRITICAL_AVAILABLE_MIB=$CRITICAL_MIB/" \
    "$SCRIPT_DIR/xui-memory-watchdog.conf" > "$config_tmp"
install -Dm0644 "$config_tmp" /etc/default/xui-memory-watchdog

NORMAL_AVAILABLE_MIB=$NORMAL_MIB CRITICAL_AVAILABLE_MIB=$CRITICAL_MIB \
    /usr/local/sbin/xui-memory-watchdog --check-config

systemctl daemon-reload
systemctl enable xui-memory-watchdog.service
systemctl restart xui-memory-watchdog.service
systemctl --no-pager --full status xui-memory-watchdog.service
