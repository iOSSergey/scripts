if [ -n "${SSH_CONNECTION:-}" ] && [ -t 1 ] && [ -r /var/log/xui-memory-watchdog.log ]; then
    xui_watchdog_title="X-UI Memory Watchdog: last 10 lines"
    xui_watchdog_snapshot=$(tail -n 10 /var/log/xui-memory-watchdog.log)
    xui_watchdog_width=$(
        printf '%s\n%s\n' "$xui_watchdog_title" "$xui_watchdog_snapshot" |
            awk 'length > max { max = length } END { print max + 0 }'
    )

    printf '\n'
    printf '%*s\n' "$xui_watchdog_width" '' | tr ' ' '='
    printf '%s\n' "$xui_watchdog_title"
    printf '%*s\n' "$xui_watchdog_width" '' | tr ' ' '-'
    printf '%s\n' "$xui_watchdog_snapshot"
    printf '%*s\n\n' "$xui_watchdog_width" '' | tr ' ' '='

    unset xui_watchdog_title xui_watchdog_snapshot xui_watchdog_width
fi
