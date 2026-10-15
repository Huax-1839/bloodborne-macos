#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""m3stats.py <game log> [<log>...]: the M3 numbers of a long run (docs/METAL_BACKEND_PLAN.md
P7.4) from its 5-s "Frame stats" windows in the game (300+ draws a frame: not the title, menus or
loading screens).

Prints per log: in-game minutes, mean and median FPS, the slowest window, the share of windows at
29.5 FPS or more ("stable 30" holds when that share is ~100%), the worst frame and the median of
the windows' worst frames, and the memory growth (memgrowth.py's line) when present."""
import re
import statistics
import sys

STATS = re.compile(r"Frame stats: ([\d.]+) FPS, worst frame ([\d.]+) ms.*?([\d.]+) draws/frame")
MEMORY = re.compile(r"Memory \(macOS\): RSS (\d+) MiB, footprint (\d+) MiB, Metal allocated (\d+) MiB")


def report(path: str) -> None:
    windows, memory = [], []
    with open(path, errors="replace") as log:
        for line in log:
            if m := STATS.search(line):
                fps, worst, draws = map(float, m.groups())
                if draws >= 300:
                    windows.append((fps, worst))
            elif m := MEMORY.search(line):
                memory.append(tuple(int(v) for v in m.groups()))
    print(path)
    if not windows:
        print("  no in-game windows")
        return
    fps = [w[0] for w in windows]
    worst = [w[1] for w in windows]
    stable = sum(f >= 29.5 for f in fps) / len(fps)
    print(f"  {len(windows) * 5 / 60:.1f} min in game; FPS mean {statistics.mean(fps):.1f}, "
          f"median {statistics.median(fps):.1f}, slowest window {min(fps):.1f}; "
          f"windows >= 29.5 FPS: {stable:.0%}")
    print(f"  worst frame {max(worst):.1f} ms, median of the windows' worst {statistics.median(worst):.1f} ms; "
          f"windows with a frame over 50 ms: {sum(w > 50 for w in worst) / len(worst):.0%}")
    if len(memory) > 24:
        first, last = memory[12], memory[-1]
        minutes = (len(memory) - 12) / 12
        print("  memory from minute 1 over %.0f min: RSS %+d, footprint %+d, Metal %+d MiB"
              % (minutes, last[0] - first[0], last[1] - first[1], last[2] - first[2]))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    for arg in sys.argv[1:]:
        report(arg)
