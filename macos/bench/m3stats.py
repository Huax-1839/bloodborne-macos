#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""m3stats.py [--milestone m3|m4] [--expect power|battery] <game log> [<log>...]: the M3 (default) or
M4 verdict of a long run (docs/METAL_BACKEND_PLAN.md §1, "M3 acceptance rule" and "M4") from the files m1_run.sh writes next to the
game log bench-<name>.log: bench-<name>-frames.csv (BB_FRAME_LOG, one line per flip) and
bench-<name>-power.txt (power source, charge, Low Power Mode once a minute, idle before the run).

In-game span: from the first to the last flip with 300+ draws (not the title, menus or loading
screens). Every rule is checked over that span; a run passes when all of them hold. Prints each
rule with its value and PASS/FAIL; exit status 0 when every log passes, 1 when one fails, 2 when
the files for a verdict are missing (the 5-s window numbers are still printed then).

M4 (uncapped play) keeps M3's duration, error, hitch and condition rules, judges the mean and the
60-s stretches against the M4 rates and drops the 30-FPS rules (5-s window share, missed slots,
p99.9); it reports p99 and p99.9 frame time, the slowest and median 60-s stretch and the share of
flips over 33.3 ms without judging them."""
import argparse
import re
import statistics
import sys
from pathlib import Path

# ---- The rule (keep in step with the plan's §1) ---------------------------------------------
IN_GAME_DRAWS = 300        # a flip with this many draws is a game frame
MIN_MINUTES = 20.0         # in-game span
MIN_IN_GAME_SHARE = 0.99   # of the span's flips (no drop to a menu or loading screen)
MIN_MEAN_FPS = 29.7        # over the span
MIN_MINUTE_FPS = 29.5      # every full 60-s stretch
WINDOW_S = 5.0             # windows as the game log's frame stats
MIN_WINDOW_FPS = 29.5
MIN_WINDOW_SHARE = 0.98    # of the 5-s windows at MIN_WINDOW_FPS or more
SLOT_MS = 1000 / 30 + 1000 / 120   # 41.7 ms: a flip later than this missed its 30-FPS slot
MAX_MISSED_SHARE = 0.02  # 1% until 2026-10-16 (plan §9)
P999_MAX_MS = 1000 / 30 + 1000 / 40  # 58.3 ms: 99.9% of flips at most one vblank late
HITCH_MS = 100.0
HITCHES_PER_5_MIN = 1
MAX_FRAME_MS = 250.0
MIN_IDLE_S = 600           # cool-down before the run
MIN_BATTERY_START = 50     # percent, battery runs
# M4 (uncapped play, BB_PROFILE=m4air BB_FPS=uncap, 540p): user's decision 2026-10-17 (plan §1, §9)
M4_MIN_MEAN_FPS = 45.0     # over the span
M4_MIN_MINUTE_FPS = 40.0   # every full 60-s stretch
M4_SLOW_MS = 1000 / 30     # reported only: share of flips slower than 30 FPS
DEVICE_ERROR = re.compile(r"command buffer .*failed|GPU lost|[Dd]evice lost|DEVICE_LOST")

STATS = re.compile(r"Frame stats: ([\d.]+) FPS, worst frame ([\d.]+) ms.*?([\d.]+) draws/frame")
MEMORY = re.compile(r"Memory \(macOS\): RSS (\d+) MiB, footprint (\d+) MiB, Metal allocated (\d+) MiB")
POWER = re.compile(r"power (\d+) source=(\S+) charge=(\d*) lowpower=(\d*)")


def percentile(sorted_values, p):
    if not sorted_values:
        return 0.0
    k = (len(sorted_values) - 1) * p
    lo = int(k)
    hi = min(lo + 1, len(sorted_values) - 1)
    return sorted_values[lo] + (sorted_values[hi] - sorted_values[lo]) * (k - lo)


def read_frames(path):
    """(t_s, frame_ms, draws) per flip."""
    frames = []
    with open(path, errors="replace") as f:
        header = f.readline().strip().split(",")
        t_i, ms_i, d_i = header.index("t_s"), header.index("frame_ms"), header.index("draws")
        for line in f:
            cols = line.strip().split(",")
            if len(cols) < len(header):
                continue  # the last line of a killed run
            frames.append((float(cols[t_i]), float(cols[ms_i]), int(cols[d_i])))
    return frames


def window_summary(log_path):
    windows, memory, errors = [], [], []
    with open(log_path, errors="replace") as log:
        for line in log:
            if m := STATS.search(line):
                fps, worst, draws = map(float, m.groups())
                if draws >= IN_GAME_DRAWS:
                    windows.append((fps, worst))
            elif m := MEMORY.search(line):
                memory.append(tuple(int(v) for v in m.groups()))
            if DEVICE_ERROR.search(line):
                errors.append(line.strip()[:160])
    if windows:
        fps = [w[0] for w in windows]
        worst = [w[1] for w in windows]
        print(f"  log windows: {len(windows) * 5 / 60:.1f} min in game; FPS mean {statistics.mean(fps):.1f}, "
              f"median {statistics.median(fps):.1f}, slowest {min(fps):.1f}; worst frame {max(worst):.1f} ms")
    else:
        print("  log windows: none in game")
    if len(memory) > 24:
        first, last = memory[12], memory[-1]
        print("  memory from minute 1 over %.0f min: RSS %+d, footprint %+d, Metal %+d MiB"
              % ((len(memory) - 12) / 12, last[0] - first[0], last[1] - first[1], last[2] - first[2]))
    return errors


def report(log_path: Path, expect: str | None, milestone: str = "m3") -> int:
    m4 = milestone == "m4"
    name = milestone.upper()
    print(log_path)
    if m4:
        print(f"  milestone {name} (uncapped play)")
    errors = window_summary(log_path)
    stem = log_path.with_suffix("")
    frames_path = Path(f"{stem}-frames.csv")
    power_path = Path(f"{stem}-power.txt")
    results = []

    def rule(name, ok, value):
        results.append(ok)
        print(f"  {'PASS' if ok else 'FAIL'}  {name}: {value}")

    rule("no device errors", not errors, f"{len(errors)}" + (f" (first: {errors[0]})" if errors else ""))
    if not frames_path.exists():
        print(f"  NO VERDICT: {frames_path.name} missing (run with m1_run.sh, which sets BB_FRAME_LOG)")
        return 2
    frames = read_frames(frames_path)
    in_game = [i for i, f in enumerate(frames) if f[2] >= IN_GAME_DRAWS]
    if not in_game:
        rule("in game", False, "no flip with 300+ draws")
        return 1
    span = frames[in_game[0]:in_game[-1] + 1]
    t0, t1 = span[0][0], span[-1][0]
    minutes = (t1 - t0) / 60
    rule(f"in-game span >= {MIN_MINUTES:.0f} min", minutes >= MIN_MINUTES, f"{minutes:.1f} min")
    share = len(in_game) / len(span)
    rule(f"in game for >= {MIN_IN_GAME_SHARE:.0%} of the span's flips", share >= MIN_IN_GAME_SHARE, f"{share:.2%}")

    mean_fps = (len(span) - 1) / (t1 - t0) if t1 > t0 else 0.0
    min_mean = M4_MIN_MEAN_FPS if m4 else MIN_MEAN_FPS
    rule(f"mean >= {min_mean} FPS", mean_fps >= min_mean, f"{mean_fps:.2f}")

    def stretches(seconds):
        counts = {}
        for t, _, _ in span[1:]:
            counts[int((t - t0) // seconds)] = counts.get(int((t - t0) // seconds), 0) + 1
        full = int((t1 - t0) // seconds)
        return [counts.get(i, 0) / seconds for i in range(full)]

    minutes_fps = stretches(60.0)
    slowest_minute = min(minutes_fps) if minutes_fps else 0.0
    min_minute = M4_MIN_MINUTE_FPS if m4 else MIN_MINUTE_FPS
    rule(f"every 60-s stretch >= {min_minute} FPS", slowest_minute >= min_minute,
         f"slowest {slowest_minute:.2f} (minute {minutes_fps.index(slowest_minute) if minutes_fps else '-'})")
    times = sorted(f[1] for f in span[1:])
    p99, p999 = percentile(times, 0.99), percentile(times, 0.999)
    if m4:
        slow = sum(t > M4_SLOW_MS for t in times) / len(times) if times else 0.0
        print(f"  info  frame time: p99 {p99:.1f}, p99.9 {p999:.1f} ms; "
              f"{slow:.2%} of flips over {M4_SLOW_MS:.1f} ms")
        if minutes_fps:
            print(f"  info  60-s stretches: slowest {slowest_minute:.2f}, "
                  f"median {statistics.median(minutes_fps):.2f} FPS")
    else:
        windows = stretches(WINDOW_S)
        good = sum(w >= MIN_WINDOW_FPS for w in windows) / len(windows) if windows else 0.0
        rule(f">= {MIN_WINDOW_SHARE:.0%} of 5-s windows at >= {MIN_WINDOW_FPS} FPS", good >= MIN_WINDOW_SHARE,
             f"{good:.1%} (slowest {min(windows) if windows else 0:.1f})")
        missed = sum(t > SLOT_MS for t in times) / len(times)
        rule(f"<= {MAX_MISSED_SHARE:.0%} of flips miss the 30-FPS slot (> {SLOT_MS:.1f} ms)",
             missed <= MAX_MISSED_SHARE, f"{missed:.2%}")
        rule(f"p99.9 frame time <= {P999_MAX_MS:.1f} ms", p999 <= P999_MAX_MS,
             f"p99 {p99:.1f}, p99.9 {p999:.1f} ms")
    hitches = [f for f in span[1:] if f[1] > HITCH_MS]
    allowed = int(minutes // 5) * HITCHES_PER_5_MIN
    rule(f"<= {HITCHES_PER_5_MIN} frame over {HITCH_MS:.0f} ms per 5 min", len(hitches) <= allowed,
         f"{len(hitches)} (allowed {allowed})" +
         (": " + ", ".join(f"{h[1]:.0f} ms at {(h[0] - t0) / 60:.1f} min" for h in hitches[:8]) if hitches else ""))
    worst = times[-1] if times else 0.0
    rule(f"no frame over {MAX_FRAME_MS:.0f} ms", worst <= MAX_FRAME_MS, f"worst {worst:.1f} ms")

    if not power_path.exists():
        print(f"  NO VERDICT: {power_path.name} missing (power source and idle not recorded)")
        return 2
    samples, idle = [], 0
    for line in power_path.read_text().splitlines():
        if m := POWER.match(line):
            samples.append((int(m[1]), m[2], int(m[3] or -1), m[4]))
        elif line.startswith("idle "):
            idle = int(line.split()[1])
    rule(f"idle >= {MIN_IDLE_S // 60} min before the run", idle >= MIN_IDLE_S, f"{idle // 60} min")
    sources = {s[1] for s in samples}
    rule("Low Power Mode off throughout", all(s[3] == "0" for s in samples) and bool(samples),
         f"{len(samples)} samples")
    if expect == "power":
        rule("on AC power throughout", sources == {"AC_Power"}, ", ".join(sorted(sources)) or "no samples")
    elif expect == "battery":
        rule("on battery throughout", sources == {"Battery_Power"}, ", ".join(sorted(sources)) or "no samples")
        start = samples[0][2] if samples else -1
        rule(f"battery >= {MIN_BATTERY_START}% at the start", start >= MIN_BATTERY_START, f"{start}%")
    else:
        rule("one power source throughout", len(sources) == 1, ", ".join(sorted(sources)) or "no samples")
    if samples:
        print(f"  charge {samples[0][2]}% -> {samples[-1][2]}% ({', '.join(sorted(sources))})")
    verdict = all(results)
    print(f"  {name} {'PASS' if verdict else 'FAIL'}")
    return 0 if verdict else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--milestone", choices=["m3", "m4"], default="m3")
    parser.add_argument("--expect", choices=["power", "battery"])
    parser.add_argument("logs", nargs="+", type=Path)
    args = parser.parse_args()
    status = 0
    for log in args.logs:
        status = max(status, report(log, args.expect, args.milestone))
    sys.exit(status)


if __name__ == "__main__":
    main()
