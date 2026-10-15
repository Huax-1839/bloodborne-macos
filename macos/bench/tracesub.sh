#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# tracesub.sh <name> [ENV=VAL ...]: bench boot into the clinic (kept running), a Metal System
# Trace (TRACE_SECONDS long, default 3; xctrace killed after 180 s if it hangs), then quits the game and prints the trace's
# frames/s, GPU busy, command buffers and encoders per frame and the CPU the Metal queue's
# submission threads spend per command buffer (kernel submit cost, independent of the FPS).
set -uo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
bench=${BB_BENCH_DIR:-$HOME/Games/Bloodborne/bench}
name=$1; shift
KEEP=1 BENCH_WAIT=${BENCH_WAIT:-30} BENCH_WINDOWS=2 "$here/bench.sh" "trace-$name" "$@" | tail -1
trace=$bench/traces/$name.trace
rm -rf "$trace"
xcrun xctrace record --template 'Metal System Trace' --attach "$(pgrep -f out/bb-probe)" \
    --time-limit "${TRACE_SECONDS:-3}s" --output "$trace" > /dev/null 2>&1 &
xp=$!
for _ in $(seq 1 180); do kill -0 $xp 2>/dev/null || break; sleep 1; done
kill $xp 2>/dev/null && echo "tracesub $name: xctrace killed"
pkill -f out/bb-probe
summary=$bench/traces/summary-$name.txt
LC_ALL=C python3 "$here/mtltrace.py" "$trace" --out "$bench/traces/export-$name" > "$summary" 2>&1
python3 - "$summary" "$name" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
def grab(p, d='?'):
    m = re.search(p, s); return m.group(1) if m else d
fps = grab(r'frames/s ([\d.]+)'); med = grab(r'1/median frame: ([\d.]+)')
busy = grab(r'typical frames.*busy [\d.]+ ms \(([\d.]+)%\)')
cbs = float(grab(r'command buffers\s+([\d.]+)', '0')); enc = grab(r'encoders total\s+([\d.]+)')
# CPU of the threads whose samples are mostly in the kernel submit.
sub = 0.0
for block in re.split(r'\n   -- ', s):
    m = re.match(r'(\S+) (0x[0-9a-f]+): \d+ samples \(([\d.]+) ms/s\)', block)
    if m and re.search(r'IOGPUCommandQueueSubmitCommandBuffers|io_connect_method', block.split('inclusive:')[0]):
        sub += float(m.group(3))
fpsf = float(fps) if fps != '?' else 0
per_cb = sub / (fpsf * cbs) if fpsf and cbs else 0
print(f"tracesub {sys.argv[2]}: {fps} FPS (median {med}), GPU busy {busy}% of typical frames, "
      f"{cbs:.1f} cbs and {enc} encoders a frame; submit threads {sub:.0f} ms/s = {per_cb:.2f} ms per cb")
PY
