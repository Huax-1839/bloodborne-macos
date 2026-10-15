#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# churn.sh <name> [ENV=VAL ...]: bench boot into the clinic (kept running), FPS every 20 s for
# WAIT seconds (default 100), then a 3-s Metal System Trace: wired system memory events per second
# and level (the GPU driver wiring/unwiring memory per submit, P6.1), then quits the game. Each FPS
# value comes with the pages decompressed and swapped in per second; TRACE=0 skips the trace.
set -uo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
bench=${BB_BENCH_DIR:-$HOME/Games/Bloodborne/bench}
name=$1; shift
KEEP=1 BENCH_WAIT=20 BENCH_WINDOWS=2 "$here/bench.sh" "churn-$name" "$@" | tail -1
log=$bench/runs/bench-churn-$name.log
# vm_stat counters: pages decompressed and swapped in (memory pressure on the guest memory).
vmc() { vm_stat | awk -F: '/Decompressions|Swapins/ { gsub(/[ .]/, "", $2); printf "%s ", $2 }'; }
series=""
read -r d0 s0 <<< "$(vmc)"
for ((t = 0; t < ${WAIT:-100}; t += 20)); do
    sleep 20
    read -r d1 s1 <<< "$(vmc)"
    series+=" $(grep 'Frame stats' "$log" | tail -1 | sed -E 's/^Frame stats: ([0-9.]+) FPS.*/\1/')"
    series+="[dec $(((d1 - d0) / 20))/s swin $(((s1 - s0) / 20))/s]"
    d0=$d1 s0=$s1
done
[[ ${TRACE:-1} == 0 ]] && { pkill -f out/bb-probe; echo "churn $name: FPS every 20 s:$series"; exit 0; }
trace=$bench/traces/churn-$name.trace
rm -rf "$trace" "$trace.xml"
xcrun xctrace record --template 'Metal System Trace' --attach "$(pgrep -f out/bb-probe)" \
    --time-limit 3s --output "$trace" > /dev/null 2>&1
pkill -f out/bb-probe
xcrun xctrace export --input "$trace" \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="metal-wired-sysmem-level-interval"]' \
    --output "$trace.xml" > /dev/null 2>&1
python3 - "$trace.xml" "$name" "$series" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
starts = [int(x) for x in re.findall(r'<start-time[^>]*>(\d+)</start-time>', s)]
levels = [int(x) for x in re.findall(r'<size-in-bytes[^>]*>(\d+)</size-in-bytes>', s)]
span = (max(starts) - min(starts)) / 1e9 if starts else 0
lv = [l for l in levels if l]
print("churn %s: FPS every 20 s:%s | wired events %.0f/s, level %.2f..%.2f GiB" % (
    sys.argv[2], sys.argv[3], len(starts) / span if span else 0,
    min(lv) / 2**30 if lv else 0, max(lv) / 2**30 if lv else 0))
PY
rm -rf "$trace.xml"
