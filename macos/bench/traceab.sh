#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# traceab.sh <name> <A> <B> [ENV=VAL ...]: GPU time A/B of two BB_TOGGLE_FILE settings within one
# game run (same camera, same thermal state): boots into the clinic (bench.sh, KEEP=1), records a
# 3-s Metal System Trace per phase A B B A ... (CYCLES pairs, default 2; SETTLE seconds after each
# switch, default 4), quits the game, summarises each trace (mtltrace.py) and prints per variant
# the GPU busy ms a typical frame (union of all channels: the number that has to fit in 33 ms) and
# the labels whose GPU ms a frame differ most between A and B.
#
#   BB_RENDERER=metal macos/bench/traceab.sh tiling "0 0" "0 1099511627776" BB_PROFILE=m4air \
#       BB_RENDER_RES=1280x720 BB_PASS_LABELS=1
#
# Traces and summaries: $BB_BENCH_DIR/traces/ab-<name>-<phase><n>.trace / summary-ab-<name>-*.txt.
set -uo pipefail
export LC_ALL=C
here=$(cd -- "$(dirname -- "$0")" && pwd)
[[ $# -ge 3 ]] || { sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
name=$1 a=$2 b=$3; shift 3
bench=${BB_BENCH_DIR:-$HOME/Games/Bloodborne/bench}
toggle=$bench/runs/traceab-$name.toggle
settle=${SETTLE:-4} cycles=${CYCLES:-2}
mkdir -p "$bench/runs" "$bench/traces"
echo "$a" > "$toggle"
KEEP=1 BENCH_WAIT=${BENCH_WAIT:-30} BENCH_WINDOWS=2 "$here/bench.sh" "traceab-$name" "$@" \
    BB_TOGGLE_FILE="$toggle" | tail -1
pid=$(pgrep -f out/bb-probe) || { echo "traceab $name: the game is not running" >&2; exit 1; }

order=(A B B A) traces=()
for ((i = 0; i < 2 * cycles; ++i)); do
    p=${order[i % 4]}
    [[ $p == A ]] && echo "$a" > "$toggle" || echo "$b" > "$toggle"
    sleep "$settle"
    t=ab-$name-$p$i
    rm -rf "$bench/traces/$t.trace" "$bench/traces/export-$t"
    xcrun xctrace record --template 'Metal System Trace' --attach "$pid" --time-limit 3s \
        --output "$bench/traces/$t.trace" > /dev/null 2>&1 &
    xp=$!
    for _ in $(seq 1 180); do kill -0 $xp 2>/dev/null || break; sleep 1; done
    kill $xp 2>/dev/null && echo "traceab $name: xctrace killed in phase $t"
    traces+=("$t")
done
pkill -f out/bb-probe

for t in "${traces[@]}"; do
    python3 "$here/mtltrace.py" "$bench/traces/$t.trace" --out "$bench/traces/export-$t" --top 400 \
        > "$bench/traces/summary-$t.txt" 2>&1
done
python3 - "$bench/traces" "$name" "$a" "$b" "${traces[@]}" <<'PY'
import collections, re, sys
d, name, a, b, traces = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:]
busy = collections.defaultdict(list); fps = collections.defaultdict(list)
labels = collections.defaultdict(lambda: collections.defaultdict(float))
for t in traces:
    v = re.search(r'-([AB])\d+$', t).group(1)
    s = open(f'{d}/summary-{t}.txt').read()
    m = re.search(r'typical frames.*busy ([\d.]+) ms', s)
    if not m:
        print(f'traceab {name}: no summary for {t}'); continue
    busy[v].append(float(m.group(1)))
    fps[v].append(float(re.search(r'frames/s ([\d.]+)', s).group(1)))
    sec = s.split('3. GPU TIME PER ENCODER LABEL')[1].split('\n4. ')[0]
    for line in sec.splitlines():
        m = re.match(r'\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+(.+)$', line)
        if m and 'TOTAL' not in m.group(4):
            labels[v][m.group(4).strip()] += float(m.group(1))
mean = lambda x: sum(x) / len(x) if x else 0
for v, setting in (('A', a), ('B', b)):
    print(f'traceab {name} {v} ({setting}): GPU busy {mean(busy[v]):.2f} ms a typical frame '
          f'({", ".join(f"{x:.2f}" for x in busy[v])}), {mean(fps[v]):.1f} FPS')
print(f'traceab {name}: B - A {mean(busy["B"]) - mean(busy["A"]):+.2f} ms busy')
n = {v: sum(1 for t in traces if t.split('-')[-1][0] == v) for v in 'AB'}
keys = set(labels['A']) | set(labels['B'])
diff = sorted(((labels['B'][k] / max(n['B'], 1) - labels['A'][k] / max(n['A'], 1), k) for k in keys),
              key=lambda x: -abs(x[0]))
print('largest label differences (GPU ms a frame, B - A; sums over channels, overlaps count twice):')
for dv, k in diff[:12]:
    print(f'  {dv:+7.3f}  A {labels["A"][k] / max(n["A"], 1):6.3f}  {k}')
PY
