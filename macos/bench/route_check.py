#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Check a scripted route on any backend from the game log (BB_PROFILE=m4air BB_FRAME_STATS=1).

  route_check.py <game log> [--shaders <shader log>] [--checkpoints <file>]
                 [--frame-log <BB_FRAME_LOG csv>] [--compare <shader log A> <shader log B>]

Reads, from the game log (stdout of the game):
  "Camera: x y z"       once per 5 s stats window (the committed camera's world position)
  "Draw drops: ..."     per-window counts of draws that were not recorded (summed here)
  "GPU: Metal device"   marks a Metal run
and optionally the BB_FRAME_LOG csv (columns cam_x,cam_y,cam_z: one position per flip, a denser
camera path), BB_SHADER_LOG files ("<hw stage> <pgm hash>" per line), and a checkpoint file with
one "name x y z radius" per line ('#' starts a comment).

Exit status 1: a checkpoint was not reached, or, on a Metal log, any drop category is nonzero
(geometry drops are allowed on Vulkan only). Other drop categories on Vulkan are only reported.
"""

import argparse
import csv
import math
import re
import sys

FRAME_STATS = re.compile(r"^Frame stats:")
CAMERA = re.compile(r"^Camera: (-?\d+(?:\.\d+)?) (-?\d+(?:\.\d+)?) (-?\d+(?:\.\d+)?)\s*$")
DROPS = re.compile(
    r"^Draw drops: no pipeline (\d+), geometry (\d+), missing bindings (\d+), "
    r"null textures (\d+), other (\d+)")
DROP_NAMES = ["no pipeline", "geometry", "missing bindings", "null textures", "other"]
WINDOW_SECONDS = 5.0


def parse_game_log(path):
    """Returns (camera samples [(seconds, (x, y, z))], drops [5 ints], is_metal)."""
    samples = []
    drops = [0] * 5
    is_metal = False
    windows = 0
    first_window = None
    with open(path, errors="replace") as f:
        for line in f:
            if "GPU: Metal device" in line:
                is_metal = True
            if FRAME_STATS.match(line):
                windows += 1
                continue
            m = CAMERA.match(line)
            if m:
                # The Camera line follows the "Frame stats:" line of its window.
                if first_window is None:
                    first_window = windows
                samples.append(((windows - first_window) * WINDOW_SECONDS,
                                tuple(float(v) for v in m.groups())))
                continue
            m = DROPS.match(line)
            if m:
                for i, v in enumerate(m.groups()):
                    drops[i] += int(v)
    return samples, drops, is_metal


def parse_frame_log(path):
    """Camera samples from BB_FRAME_LOG: t_s relative to the first row with a camera."""
    samples = []
    first = None
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            try:
                pos = tuple(float(row[k]) for k in ("cam_x", "cam_y", "cam_z"))
                t = float(row["t_s"])
            except (KeyError, ValueError, TypeError):
                continue
            if any(math.isnan(v) for v in pos):
                continue
            if first is None:
                first = t
            samples.append((t - first, pos))
    return samples


def parse_checkpoints(path):
    result = []
    with open(path) as f:
        for number, line in enumerate(f, 1):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            try:
                if len(parts) < 5:
                    raise ValueError
                x, y, z, r = (float(v) for v in parts[-4:])
            except ValueError:
                sys.exit(f"{path}:{number}: expected 'name x y z radius'")
            result.append((" ".join(parts[:-4]), (x, y, z), r))
    return result


def read_shaders(path):
    shaders = set()
    with open(path) as f:
        for line in f:
            parts = line.split()
            if len(parts) == 2:
                shaders.add((parts[0], parts[1].lower()))
    return shaders


def by_stage(shaders):
    stages = {}
    for stage, h in shaders:
        stages.setdefault(stage, []).append(h)
    return {s: sorted(v) for s, v in sorted(stages.items())}


def summarize_path(samples):
    print(f"Camera path: {len(samples)} samples")
    if not samples:
        print("  no camera positions (the tracker runs in temporal-upscaled sessions: BB_PROFILE=m4air)")
        return
    fmt = lambda p: "(%.2f, %.2f, %.2f)" % p
    print(f"  first {fmt(samples[0][1])} at {samples[0][0] / 60:.1f} min")
    print(f"  last  {fmt(samples[-1][1])} at {samples[-1][0] / 60:.1f} min")
    distance = sum(math.dist(a[1], b[1]) for a, b in zip(samples, samples[1:]))
    print(f"  distance along the samples: {distance:.1f}")
    lo = tuple(min(s[1][i] for s in samples) for i in range(3))
    hi = tuple(max(s[1][i] for s in samples) for i in range(3))
    print(f"  bounding box {fmt(lo)} .. {fmt(hi)}")


def check_checkpoints(samples, checkpoints):
    missed = 0
    print("Checkpoints:")
    for name, pos, radius in checkpoints:
        hit = next((t for t, p in samples if math.dist(p, pos) <= radius), None)
        if hit is not None:
            print(f"  {name}: reached at {hit / 60:.1f} min")
        else:
            nearest = min((math.dist(p, pos) for _, p in samples), default=None)
            extra = f", nearest approach {nearest:.1f}" if nearest is not None else ", no camera samples"
            print(f"  {name}: MISSED (radius {radius:g}){extra}")
            missed += 1
    return missed


def print_list(label, stages, limit):
    total = sum(len(v) for v in stages.values())
    print(f"  {label}: {total}")
    shown = 0
    for stage, hashes in stages.items():
        for h in hashes:
            if shown >= limit:
                print(f"    ... {total - shown} more")
                return
            print(f"    {stage} {h}")
            shown += 1


def compare_shaders(path_a, path_b, limit):
    a, b = read_shaders(path_a), read_shaders(path_b)
    print(f"Shader comparison: A {path_a} ({len(a)}), B {path_b} ({len(b)})")
    print(f"  common: {len(a & b)}, only in A: {len(a - b)}, only in B: {len(b - a)}")
    print_list("only in A", by_stage(a - b), limit)
    print_list("only in B", by_stage(b - a), limit)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log", nargs="?", help="game log (stdout of a BB_FRAME_STATS=1 run)")
    ap.add_argument("--shaders", metavar="LOG", help="BB_SHADER_LOG file of this run")
    ap.add_argument("--checkpoints", metavar="FILE", help="lines 'name x y z radius'")
    ap.add_argument("--frame-log", metavar="CSV", help="BB_FRAME_LOG csv: per-flip camera path")
    ap.add_argument("--compare", nargs=2, metavar=("A", "B"), help="two shader logs")
    ap.add_argument("--max-list", type=int, default=200, help="most hashes listed per list")
    args = ap.parse_args()
    if not args.log and not args.compare:
        ap.error("a game log or --compare is required")

    failed = False
    if args.log:
        samples, drops, is_metal = parse_game_log(args.log)
        print(f"Log: {args.log} ({'Metal' if is_metal else 'Vulkan or unknown'} run)")
        if args.frame_log:
            dense = parse_frame_log(args.frame_log)
            if dense:
                samples = dense
        summarize_path(samples)
        if args.checkpoints:
            if check_checkpoints(samples, parse_checkpoints(args.checkpoints)):
                failed = True
        print("Draw drops (summed over the stats windows): " +
              ", ".join(f"{n} {v}" for n, v in zip(DROP_NAMES, drops)))
        if is_metal:
            if any(drops):
                print("  FAIL: a Metal run must not drop draws")
                failed = True
        elif any(drops[i] for i in (0, 2, 3, 4)):
            print("  note: drops other than geometry on a Vulkan run (not a failure by itself)")
        if args.shaders:
            stages = by_stage(read_shaders(args.shaders))
            print(f"Guest shaders: {sum(len(v) for v in stages.values())} (" +
                  ", ".join(f"{s} {len(v)}" for s, v in stages.items()) + ")")
    if args.compare:
        compare_shaders(args.compare[0], args.compare[1], args.max_list)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
