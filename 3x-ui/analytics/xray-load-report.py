#!/usr/bin/env python3

import re
import json
import sqlite3
import subprocess
import os
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta

# ============================================================
# SETTINGS
# ============================================================

PORT = 443
WINDOW_MINUTES = 10
TOP_IPS = 20
TOP_USERS = 15
TOP_DESTINATIONS = 10

DB = "/etc/x-ui/x-ui.db"
LOG = "/usr/local/x-ui/access.log"

# Читаем только хвост access.log, чтобы не гонять весь огромный файл.
# 64 MiB обычно более чем достаточно для анализа последних минут
# и значительной части текущих соединений.
LOG_TAIL_MB = 64


# ============================================================
# HELPERS
# ============================================================

def run(cmd):
    try:
        return subprocess.check_output(
            cmd,
            text=True,
            stderr=subprocess.DEVNULL
        ).strip()
    except Exception:
        return ""


def normalize_ip(ip):
    if ip.startswith("::ffff:"):
        return ip[7:]
    return ip


def split_endpoint(value):
    """
    1.2.3.4:12345
    [::ffff:1.2.3.4]:12345
    [2001:db8::1]:12345
    """
    value = value.strip()

    if value.startswith("["):
        m = re.match(r'^\[(.+)\]:(\d+)$', value)
        if not m:
            return None
        return normalize_ip(m.group(1)), m.group(2)

    if ":" not in value:
        return None

    ip, port = value.rsplit(":", 1)

    if not port.isdigit():
        return None

    return normalize_ip(ip), port


def read_log_tail(path, max_mb):
    max_bytes = max_mb * 1024 * 1024

    try:
        size = os.path.getsize(path)

        with open(path, "rb") as f:
            if size > max_bytes:
                f.seek(size - max_bytes)
                # отбросить первую неполную строку
                f.readline()

            data = f.read()

        return data.decode("utf-8", errors="ignore").splitlines()

    except Exception as e:
        print(f"WARNING: cannot read {path}: {e}", file=sys.stderr)
        return []


# ============================================================
# 1. SERVER / XRAY SNAPSHOT
# ============================================================

now = datetime.now()
since = now - timedelta(minutes=WINDOW_MINUTES)

mem_available_kb = 0
mem_total_kb = 0

try:
    with open("/proc/meminfo") as f:
        for line in f:
            if line.startswith("MemTotal:"):
                mem_total_kb = int(line.split()[1])
            elif line.startswith("MemAvailable:"):
                mem_available_kb = int(line.split()[1])
except Exception:
    pass


xray_pid = run(["pgrep", "-fo", "[x]ray-linux-amd64"])

xray_rss_kb = 0
xray_fd = 0

if xray_pid:
    try:
        with open(f"/proc/{xray_pid}/status") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    xray_rss_kb = int(line.split()[1])
                    break
    except Exception:
        pass

    try:
        xray_fd = len(os.listdir(f"/proc/{xray_pid}/fd"))
    except Exception:
        pass


# cgroup memory of x-ui
cgroup_mem = None

cg = run([
    "systemctl",
    "show",
    "x-ui.service",
    "-p",
    "ControlGroup",
    "--value"
])

if cg:
    p = "/sys/fs/cgroup" + cg + "/memory.current"
    try:
        with open(p) as f:
            cgroup_mem = int(f.read().strip())
    except Exception:
        pass


# ============================================================
# 2. CURRENT INBOUND ESTABLISHED :443
# ============================================================

ss_output = run([
    "ss",
    "-Htn",
    "state",
    "established",
    f"( sport = :{PORT} )"
])

active = []
by_ip = Counter()

for line in ss_output.splitlines():

    parts = line.split()

    # ss:
    # Recv-Q Send-Q Local:Port Peer:Port
    if len(parts) < 4:
        continue

    peer = split_endpoint(parts[3])

    if not peer:
        continue

    ip, port = peer

    active.append((ip, port))
    by_ip[ip] += 1


active_set = set(active)
total_estab = len(active)


# ============================================================
# 3. SQLITE: saved IP -> client email
# ============================================================

db_by_ip = defaultdict(list)

try:
    con = sqlite3.connect(
        f"file:{DB}?mode=ro",
        uri=True
    )

    cur = con.cursor()

    rows = cur.execute("""
        SELECT client_email, ips
        FROM inbound_client_ips
        WHERE ips IS NOT NULL
          AND ips != ''
    """)

    for client_email, ips_json in rows:

        try:
            entries = json.loads(ips_json)
        except Exception:
            continue

        for entry in entries:

            ip = entry.get("ip")
            timestamp = entry.get("timestamp")

            if ip:
                db_by_ip[normalize_ip(ip)].append(
                    (client_email, timestamp)
                )

    con.close()

except Exception as e:
    print(f"WARNING: SQLite: {e}", file=sys.stderr)


# ============================================================
# 4. ACCESS.LOG
# ============================================================

lines = read_log_tail(LOG, LOG_TAIL_MB)

# exact current mapping:
# (source IP, source port) -> email
live_mapping = {}

# activity during last N minutes
activity = defaultdict(lambda: {
    "total": 0,
    "tcp": 0,
    "udp": 0,
    "ips": Counter(),
    "dst": Counter(),
})

# Supported examples:
#
# from 1.2.3.4:123 accepted tcp:example.com:443 ...
# from tcp:1.2.3.4:123 accepted udp:8.8.8.8:53 ...
#
rx = re.compile(
    r'^(\d{4}/\d{2}/\d{2}) '
    r'(\d{2}:\d{2}:\d{2})\.\d+ '
    r'from (?:tcp:)?'
    r'(\[[^\]]+\]|[^:\s]+):(\d+) '
    r'accepted (tcp|udp):([^ ]+)'
    r'.* email: (.+)$'
)

for line in lines:

    m = rx.match(line)

    if not m:
        continue

    date_s, time_s, src_ip, src_port, proto, dst, email = m.groups()

    if src_ip.startswith("[") and src_ip.endswith("]"):
        src_ip = src_ip[1:-1]

    src_ip = normalize_ip(src_ip)
    email = email.strip()

    # --------------------------------------------------------
    # Exact mapping of current active TCP session
    # --------------------------------------------------------

    key = (src_ip, src_port)

    if key in active_set:
        live_mapping[key] = email

    # --------------------------------------------------------
    # Recent activity window
    # --------------------------------------------------------

    try:
        ts = datetime.strptime(
            f"{date_s} {time_s}",
            "%Y/%m/%d %H:%M:%S"
        )
    except ValueError:
        continue

    if ts < since:
        continue

    a = activity[email]

    a["total"] += 1
    a[proto] += 1
    a["ips"][src_ip] += 1
    a["dst"][dst] += 1


# ============================================================
# 5. CURRENT LIVE MAPPING
# ============================================================

live_by_ip = defaultdict(Counter)
live_by_email = Counter()
live_email_ips = defaultdict(Counter)

for ip, port in active:

    email = live_mapping.get((ip, port))

    if not email:
        continue

    live_by_ip[ip][email] += 1
    live_by_email[email] += 1
    live_email_ips[email][ip] += 1


mapped_total = sum(live_by_email.values())
unknown_total = total_estab - mapped_total

coverage_total = (
    mapped_total / total_estab * 100
    if total_estab else 0
)


# ============================================================
# OUTPUT
# ============================================================

print()
print("=" * 110)
print("XRAY LOAD REPORT")
print("=" * 110)

print(
    f"Time:              {now:%Y-%m-%d %H:%M:%S}"
)

print(
    f"Activity window:   last {WINDOW_MINUTES} minutes"
)

print(
    f"Access log scan:   last {LOG_TAIL_MB} MiB"
)

print()


# ------------------------------------------------------------
# SERVER
# ------------------------------------------------------------

print("SERVER")
print("-" * 110)

if mem_total_kb:
    print(
        f"RAM:               "
        f"{mem_available_kb / 1024:.0f} MiB available / "
        f"{mem_total_kb / 1024:.0f} MiB total"
    )

if xray_pid:
    print(
        f"Xray:              "
        f"PID {xray_pid}, "
        f"RSS {xray_rss_kb / 1024:.1f} MiB, "
        f"FD {xray_fd}"
    )

if cgroup_mem is not None:
    print(
        f"x-ui cgroup:        "
        f"{cgroup_mem / 1024 / 1024:.1f} MiB"
    )

print(
    f"Inbound ESTAB :{PORT}: "
    f"{total_estab}"
)

print(
    f"Mapped to email:   "
    f"{mapped_total} "
    f"({coverage_total:.1f}%)"
)

print(
    f"Unmapped ESTAB:    "
    f"{unknown_total}"
)

print()


# ------------------------------------------------------------
# TOP SOURCE IPs
# ------------------------------------------------------------

print("TOP SOURCE IPs BY CURRENT ESTABLISHED CONNECTIONS")
print("-" * 110)

print(
    f"{'ESTAB':>6} "
    f"{'LIVE':>6} "
    f"{'COV%':>6} "
    f"{'IP':<16} "
    f"LIVE email(s) / DB client(s)"
)

for ip, estab in by_ip.most_common(TOP_IPS):

    live = live_by_ip[ip]
    live_count = sum(live.values())

    coverage = (
        live_count / estab * 100
        if estab else 0
    )

    live_desc = ", ".join(
        f"{email} ({count})"
        for email, count in live.most_common()
    )

    if not live_desc:
        live_desc = "-"

    db_names = []

    for email, timestamp in db_by_ip.get(ip, []):
        if email not in db_names:
            db_names.append(email)

    db_desc = ", ".join(db_names)

    if not db_desc:
        db_desc = "-"

    print(
        f"{estab:6d} "
        f"{live_count:6d} "
        f"{coverage:5.1f}% "
        f"{ip:<16} "
        f"{live_desc}  | DB: {db_desc}"
    )

print()


# ------------------------------------------------------------
# TOP CONFIRMED USERS BY LIVE ESTAB
# ------------------------------------------------------------

print("TOP PROFILES BY CONFIRMED CURRENT ESTABLISHED CONNECTIONS")
print("-" * 110)

print(
    f"{'LIVE':>6} "
    f"{'IPs':>4} "
    f"{'FLOW':>7} "
    f"{'/MIN':>7} "
    f"{'TCP':>7} "
    f"{'UDP':>7} "
    f"EMAIL"
)

for email, live_estab in live_by_email.most_common(TOP_USERS):

    a = activity[email]

    print(
        f"{live_estab:6d} "
        f"{len(live_email_ips[email]):4d} "
        f"{a['total']:7d} "
        f"{a['total'] / WINDOW_MINUTES:7.1f} "
        f"{a['tcp']:7d} "
        f"{a['udp']:7d} "
        f"{email}"
    )

print()


# ------------------------------------------------------------
# TOP FLOW CHURN
# ------------------------------------------------------------

print(
    f"TOP PROFILES BY NEW FLOW ACTIVITY — LAST {WINDOW_MINUTES} MIN"
)

print("-" * 110)

print(
    f"{'FLOW':>7} "
    f"{'/MIN':>7} "
    f"{'TCP':>7} "
    f"{'UDP':>7} "
    f"{'IPs':>4} "
    f"{'LIVE':>6} "
    f"EMAIL"
)

top_activity = sorted(
    activity.items(),
    key=lambda x: x[1]["total"],
    reverse=True
)

for email, a in top_activity[:TOP_USERS]:

    print(
        f"{a['total']:7d} "
        f"{a['total'] / WINDOW_MINUTES:7.1f} "
        f"{a['tcp']:7d} "
        f"{a['udp']:7d} "
        f"{len(a['ips']):4d} "
        f"{live_by_email[email]:6d} "
        f"{email}"
    )

print()


# ------------------------------------------------------------
# DETAILS FOR TOP 5 CURRENT PROFILES
# ------------------------------------------------------------

print("DETAILS — TOP 5 CONFIRMED CURRENT PROFILES")
print("=" * 110)

for email, live_estab in live_by_email.most_common(5):

    a = activity[email]

    print()
    print(
        f"{email}"
    )
    print("-" * 110)

    print(
        f"Current confirmed ESTAB: {live_estab}"
    )

    print(
        f"Flows last {WINDOW_MINUTES}m: "
        f"{a['total']} "
        f"({a['total'] / WINDOW_MINUTES:.1f}/min), "
        f"TCP {a['tcp']}, UDP {a['udp']}"
    )

    if a["ips"]:
        print(
            "Source IPs: "
            + ", ".join(
                f"{ip} ({count})"
                for ip, count in a["ips"].most_common()
            )
        )

    print("Top destinations:")

    for dst, count in a["dst"].most_common(TOP_DESTINATIONS):
        print(
            f"  {count:6d}  {dst}"
        )

print()
print("=" * 110)
print("END")
print("=" * 110)
