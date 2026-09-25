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
from itertools import zip_longest


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


def cell_width(value):
    return sum(
        0 if unicodedata.combining(char) else
        2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
        for char in value
    )


def column_lines(value, width):
    """Wrap long values instead of moving subsequent columns or losing text."""
    lines = []
    current = ""
    used = 0
    for char in value:
        size = cell_width(char)
        if used + size > width:
            lines.append(current)
            current, used = "", 0
        current += char
        used += size
    lines.append(current)
    return [line + " " * (width - cell_width(line)) for line in lines]


class Renderer:
    USER_COLORS = ("96", "94", "95", "93", "92", "36", "35")
    WIDTHS = (26, 32, 18, 24)

    def __init__(self, color, headers=False):
        self.color = color
        self.headers = headers
        self.header_printed = False

    def paint(self, value, style):
        return "\033[{}m{}\033[0m".format(style, value) if self.color else value

    def render(self, event):
        if self.headers and not self.header_printed:
            labels = [column_lines(label, width)[0] for label, width in zip(
                ("DATE / TIME", "USER", "ROUTE", "SOURCE"), self.WIDTHS
            )]
            print(self.paint("  ".join(labels) + "    DESTINATION", "1;2"), flush=True)
            self.header_printed = True
        user_color = self.USER_COLORS[zlib.crc32(event.user.encode("utf-8")) % len(self.USER_COLORS)]
        route_color = "92" if event.route.casefold() == "direct" else "95"
        if event.route.casefold() in ("block", "blocked", "blackhole"):
            route_color = "91"
        values = (event.date + " " + event.time, event.user, "[{}]".format(event.route), event.source)
        columns = [column_lines(value, width) for value, width in zip(values, self.WIDTHS)]
        rows = []
        for index, cells in enumerate(zip_longest(*columns, fillvalue="")):
            timestamp, user, route, source = [
                cell or " " * width for cell, width in zip(cells, self.WIDTHS)
            ]
            row = "  ".join((self.paint(timestamp, "2"), self.paint(user, "1;" + user_color),
                             self.paint(route, "1;" + route_color), self.paint(source, "36")))
            if index == 0:
                row += "  " + self.paint("→", "96") + " " + self.paint(event.destination, "1;97")
            rows.append(row)
        print("\n".join(rows), flush=True)


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
        description="Xray access.log колонками: дата, пользователь, route, источник → назначение.",
        epilog="Пример: tail -F /usr/local/x-ui/access.log | %(prog)s -",
    )
    parser.add_argument("file", nargs="?", default=DEFAULT_LOG, help="путь к логу; '-' — stdin (по умолчанию: %(default)s)")
    parser.add_argument("-n", "--lines", type=nonnegative, default=10, help="последние N строк перед наблюдением; 0 — только новые (по умолчанию: %(default)s)")
    parser.add_argument("--once", action="store_true", help="вывести последние N строк файла и завершиться")
    parser.add_argument("--user", metavar="TEXT", help="часть имени пользователя, без учёта регистра")
    parser.add_argument("--route", metavar="NAME", help="точное имя маршрута, например direct или lobasto-v6")
    # Retain the old flag for existing shell commands.
    parser.add_argument("--one-line", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--color", choices=("auto", "always", "never"), default="auto", help="цвет ANSI (по умолчанию: %(default)s; учитывает NO_COLOR)")
    parser.add_argument("--no-header", action="store_true", help="не выводить заголовки колонок")
    return parser.parse_args(argv)


def consume(stream, renderer, args):
    for line in stream:
        if not line.strip():
            continue
        event = parse_line(line)
        if event is None:
            # Only parsed access events belong in the output.
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
    renderer = Renderer(color, headers=sys.stdout.isatty() and not args.no_header)
    if args.file == "-":
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
