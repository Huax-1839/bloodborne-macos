#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""memgrowth.py <game log>: memory once a minute from the "Memory (macOS)" lines (one per 5-s
stats window) and the growth over the run (P7.3 soak).

Prints minute, RSS, footprint and Metal allocated (MiB), then the growth from the first full
minute to the end and per hour."""
import re
import sys

PAT = re.compile(r"Memory \(macOS\): RSS (\d+) MiB, footprint (\d+) MiB, Metal allocated (\d+) MiB")


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    rows = []
    with open(sys.argv[1], errors="replace") as log:
        for line in log:
            m = PAT.search(line)
            if m:
                rows.append(tuple(int(v) for v in m.groups()))
    if not rows:
        print("no memory lines")
        return 1
    per_minute = rows[::12]  # 12 windows of 5 s
    print("min    RSS  footprint  Metal")
    for i, (rss, fp, mtl) in enumerate(per_minute):
        print(f"{i:3d} {rss:6d} {fp:10d} {mtl:6d}")
    if len(per_minute) >= 3:
        base, last = per_minute[1], rows[-1]
        minutes = (len(rows) - 12) / 12
        names = ("RSS", "footprint", "Metal")
        growth = ", ".join(
            f"{n} {l - b:+d} MiB ({(l - b) / minutes * 60:+.0f}/h)"
            for n, b, l in zip(names, base, last))
        print(f"growth from minute 1 over {minutes:.1f} min: {growth}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
