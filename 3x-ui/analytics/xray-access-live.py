#!/usr/bin/env python3
"""Readable, streaming Xray access logs; Python 3.8+, no pip dependencies."""

import argparse
import os
import re
import shutil
import subprocess
import sys
import unicodedata
import zlib
from dataclasses import dataclass


DEFAULT_LOG = "/usr/local/x-ui/access.log"
ACCESS = re.compile(
    r"^(?P<date>\d{4}/\d{2}/\d{2})\s+"
    r"(?P<time>\d{2}:\d{2}:\d{2}(?:\.\d+)?)\s+from\s+"
    r"(?P<source>\S+)\s+(?P<status>accepted|rejected)\s+"
    r"(?P<protocol>tcp|udp):(?P<destination>\S+)\s+"
    r"\[(?P<inbound>[^\]]+?)\s*(?:->|>>)\s*(?P<route>[^\]]+?)\]"
    r"(?:\s+email:\s*(?P<user>.*))?\s*$"
)


@dataclass(frozen=True)
class Event:
    date: str
    time: str
    source: str
    status: str
    protocol: str
    destination: str
    inbound: str
    route: str
    user: str


def safe_text(value):
    """Log data must never inject terminal control or bidi sequences."""
    return "".join(
        char if not unicodedata.category(char).startswith("C") else "?"
        for char in value
    )


def parse_line(line):
    match = ACCESS.match(line.rstrip("\r\n"))
    if not match:
        return None
    fields = match.groupdict()
    fields["source"] = re.sub(r"^(?:tcp|udp):", "", fields["source"])
    fields["user"] = (fields["user"] or "—").strip() or "—"
    return Event(**{key: safe_text(value.strip()) for key, value in fields.items()})


class Renderer:
    USER_COLORS = ("96", "94", "95", "93", "92", "36", "35")

    def __init__(self, color, one_line=False, headers=True):
        self.color = color
        self.one_line = one_line
        self.headers = headers
        self.date = None

    def paint(self, value, style):
        return "\033[{}m{}\033[0m".format(style, value) if self.color else value

    def banner(self, source):
        if self.headers:
            print(self.paint("XRAY / ACCESS LIVE", "1;96"), flush=True)
            print(self.paint("  {}  ·  Ctrl+C to stop".format(safe_text(source)), "2"), flush=True)

    def render(self, event):
        if self.headers and self.date != event.date:
            print(self.paint("── {} ──".format(event.date), "2"), flush=True)
            self.date = event.date

        # Keep full timestamp precision and endpoint/user text; never truncate.
        timestamp = event.time if self.headers else event.date + " " + event.time
        user_color = self.USER_COLORS[zlib.crc32(event.user.encode("utf-8")) % len(self.USER_COLORS)]
        route_color = "92" if event.route.casefold() == "direct" else "95"
        if event.route.casefold() in ("block", "blocked", "blackhole"):
            route_color = "91"
        user = self.paint(event.user, "1;" + user_color)
        route = self.paint("[{}]".format(event.route), "1;" + route_color)
        protocol = self.paint(event.protocol.upper(), "93" if event.protocol == "udp" else "96")
        source = self.paint(event.source, "37")
        destination = self.paint(event.destination, "1;97")
        status = self.paint("REJECTED", "1;91") if event.status == "rejected" else ""
        inbound = self.paint("in: " + event.inbound, "2")
        headline = "{}  {}  {}{}".format(
            self.paint(timestamp, "2"), user, route, "  " + status if status else ""
        )
        connection = "{}  {} → {}  ·  {}".format(protocol, source, destination, inbound)
        separator = "  │  " if self.one_line else "\n    "
        print(headline + separator + connection, flush=True)

    def unknown(self, line):
        print(self.paint("UNPARSED", "93") + "  " + safe_text(line.rstrip("\r\n")), flush=True)


def nonnegative(value):
    try:
        number = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError("expected a non-negative integer")
    if number < 0:
        raise argparse.ArgumentTypeError("expected a non-negative integer")
    return number


def arguments(argv=None):
    parser = argparse.ArgumentParser(
        description="Цветной просмотр Xray access.log в реальном времени.",
        epilog="Пример: tail -F /usr/local/x-ui/access.log | %(prog)s -",
    )
    parser.add_argument("file", nargs="?", default=DEFAULT_LOG, help="путь к логу; '-' — stdin (по умолчанию: %(default)s)")
    parser.add_argument("-n", "--lines", type=nonnegative, default=10, help="последние N строк перед наблюдением; 0 — только новые (по умолчанию: %(default)s)")
    parser.add_argument("--once", action="store_true", help="вывести последние N строк файла и завершиться")
    parser.add_argument("--user", metavar="TEXT", help="часть имени пользователя, без учёта регистра")
    parser.add_argument("--route", metavar="NAME", help="точное имя маршрута, например direct или lobasto-v6")
    parser.add_argument("--one-line", action="store_true", help="одно подключение на строку для широкого терминала")
    parser.add_argument("--color", choices=("auto", "always", "never"), default="auto", help="цвет ANSI (по умолчанию: %(default)s; учитывает NO_COLOR)")
    parser.add_argument("--no-header", action="store_true", help="без заголовков, дата в каждой записи")
    return parser.parse_args(argv)


def consume(stream, renderer, args):
    for line in stream:
        if not line.strip():
            continue
        event = parse_line(line)
        if event is None:
            # Unknown formats remain visible, including rejected/error records.
            renderer.unknown(line)
            continue
        if args.user and args.user.casefold() not in event.user.casefold():
            continue
        if args.route and args.route != event.route:
            continue
        renderer.render(event)


def run(args):
    color = args.color == "always" or (
        args.color == "auto" and sys.stdout.isatty()
        and "NO_COLOR" not in os.environ and os.environ.get("TERM") != "dumb"
    )
    renderer = Renderer(color, args.one_line, sys.stdout.isatty() and not args.no_header)
    if args.file == "-":
        renderer.banner("stdin")
        consume(sys.stdin, renderer, args)
        return 0

    tail = shutil.which("tail")
    if tail is None:
        raise OSError("команда tail не найдена; установите coreutils или передайте лог через stdin ('-')")
    # Fail clearly on a bad initial path; tail -F handles subsequent rotations.
    with open(args.file, "rb"):
        pass
    command = [tail, "-n", str(args.lines)]
    if not args.once:
        command.append("-F")
    command.extend(["--", args.file])
    renderer.banner(args.file)
    process = subprocess.Popen(
        command, stdout=subprocess.PIPE, encoding="utf-8", errors="replace",
        # Only the parent handles Ctrl+C and reaps the follower.
        start_new_session=True,
    )
    try:
        consume(process.stdout, renderer, args)
        return process.wait()
    finally:
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        process.stdout.close()


def main():
    args = arguments()
    # Match file-mode decoding when reading a pipe containing damaged bytes.
    sys.stdin.reconfigure(encoding="utf-8", errors="replace")
    try:
        return run(args)
    except KeyboardInterrupt:
        return 130
    except BrokenPipeError:
        # Avoid a second exception during interpreter shutdown with '| head'.
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        return 0
    except OSError as error:
        print("Ошибка: {}".format(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
