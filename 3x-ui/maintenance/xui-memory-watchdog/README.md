# xui-memory-watchdog

A small systemd watchdog for memory-constrained 3x-ui hosts. It watches Linux
`MemAvailable` and restarts `x-ui.service` before the kernel's OOM killer takes
over.

Default policy:

- `MemAvailable <= 80 MiB` for three consecutive 5-second checks: restart x-ui.
- `MemAvailable <= 40 MiB`: restart x-ui immediately.
- After a restart, wait 10 minutes before another restart.

The watchdog logs the memory state, x-ui/Xray RSS, file descriptor and TCP
counts, cgroup memory categories, and the ten most common remote peers to
`/var/log/xui-memory-watchdog.log`. If `/usr/local/sbin/xui-memory-diagnostics`
is installed, it is invoked as an optional, time-bounded pre-restart hook.

## Install

Requirements: a systemd-based Linux host with `x-ui.service`, cgroup v2, Bash,
awk, procps (`pgrep`), iproute2 (`ss`), and standard GNU userland tools.

```bash
sudo ./install.sh
```

To choose other thresholds:

```bash
sudo ./install.sh --normal-mib 80 --critical-mib 40
```

The installer writes settings to `/etc/default/xui-memory-watchdog`. After a
manual settings change, validate and apply them with:

```bash
set -a
. /etc/default/xui-memory-watchdog
set +a
/usr/local/sbin/xui-memory-watchdog --check-config
systemctl restart xui-memory-watchdog
```

## Verify

```bash
systemctl status xui-memory-watchdog --no-pager
journalctl -u xui-memory-watchdog -n 50 --no-pager
tail -n 50 /var/log/xui-memory-watchdog.log
```
