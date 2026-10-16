#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# missab.sh <name>: within-run A/B of frame pacing at the 30-FPS cap. Boots the clinic with
# bench.sh (KEEP=1, BB_FRAME_LOG), then walks the m1_run.sh pattern through phases of two
# BB_TOGGLE_FILE settings and reports per phase and overall: missed 30-FPS slots (flips later
# than 41.7 ms, the m3stats.py rule), the tail (guest flip call -> end-of-pipe flip, the port's
# part: guest_age_ms - submit_age_ms) and the guest's call time after the previous flip
# (frame_ms - guest_age_ms). Missed slots depend on where the walk goes (a 60-s phase ranges
# 0.1-7%): compare whole runs and the tail, not single pairs.
#
#   BB_RENDERER=metal macos/bench/missab.sh replay A="0 0" B="0 35184372088832"
#
# A, B: toggle file contents (default "0 0" and "0 0"); ORDER (default "A B B A A B B A"); PHASE
# seconds (60); further ENV=VAL arguments go to bench.sh. The frames CSV is kept as
# bench-missab-<name>-frames.csv.
set -uo pipefail
export LC_ALL=C
here=$(cd -- "$(dirname -- "$0")" && pwd)
[[ $# -ge 1 ]] || { sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
name=$1; shift
A="0 0"; B="0 0"; extra=()
for arg in "$@"; do
    case $arg in A=*) A=${arg#A=} ;; B=*) B=${arg#B=} ;; *) extra+=("$arg") ;; esac
done
runs=${BB_BENCH_DIR:-$HOME/Games/Bloodborne/bench}/runs
toggle=$runs/missab-$name.toggle; csv=$runs/bench-missab-$name-frames.csv; pad=$runs/pad.txt
echo "$A" > "$toggle"
KEEP=1 BENCH_WAIT=20 BENCH_WINDOWS=2 BB_RENDERER=${BB_RENDERER:-metal} "$here/bench.sh" "missab-$name" \
    BB_PROFILE=m4air BB_TOGGLE_FILE="$toggle" BB_FRAME_LOG="$csv" ${extra[@]+"${extra[@]}"} | tail -1
pgrep -f out/bb-probe > /dev/null || { echo "missab $name: the game is not running" >&2; exit 1; }
press() { echo "$1" > "$pad"; sleep 0.4; : > "$pad"; sleep "$2"; }
press options 4; press circle 2
marks=(); step=0
for p in ${ORDER:-A B B A A B B A}; do
    [[ $p == A ]] && echo "$A" > "$toggle" || echo "$B" > "$toggle"
    marks+=("$p:$(wc -l < "$csv")")
    end=$(( $(date +%s) + ${PHASE:-60} ))
    while (( $(date +%s) < end )); do
        case $(( step % 6 )) in
            0) echo "ly=0" > "$pad"; sleep 3 ;;          # forward
            1) echo "rx=255" > "$pad"; sleep 1 ;;        # look right
            2) echo "ly=0 lx=255" > "$pad"; sleep 2 ;;   # forward right
            3) echo "ly=255" > "$pad"; sleep 3 ;;        # back
            4) echo "rx=0" > "$pad"; sleep 1.5 ;;        # look left
            5) echo "lx=0" > "$pad"; sleep 2 ;;          # left
        esac
        : > "$pad"; sleep 0.5; step=$((step + 1))
    done
done
marks+=("E:$(wc -l < "$csv")")
pkill -f out/bb-probe; sleep 1
python3 -I - "$csv" "${marks[@]}" <<'PY'
import sys
csv = sys.argv[1]
marks = [(m.split(':')[0], int(m.split(':')[1])) for m in sys.argv[2:]]
rows = open(csv).read().split('\n')
hdr = rows[0].split(',')
ti, fi, gi, si = (hdr.index(k) for k in ('t_s', 'frame_ms', 'guest_age_ms', 'submit_age_ms'))
SLOT = 1000 / 30 + 1000 / 120
def q(v, p):
    v = sorted(v)
    return v[int(p * (len(v) - 1))] if v else float('nan')
acc = {}
for (p, a), (_, b) in zip(marks, marks[1:]):
    seg = [r.split(',') for r in rows[a:b] if r.count(',') > 10]
    if not seg:
        continue
    t0 = float(seg[0][ti])
    seg = [r for r in seg if float(r[ti]) - t0 > 3]  # the first 3 s after a switch are dropped
    ms = [float(r[fi]) for r in seg]
    tail = [float(r[gi]) - float(r[si]) for r in seg if float(r[gi]) > 0 and float(r[si]) > 0]
    call = [float(r[fi]) - float(r[gi]) for r in seg if float(r[gi]) > 0]
    miss = sum(x > SLOT for x in ms)
    d = acc.setdefault(p, {'miss': 0, 'n': 0, 'tail': [], 'call': []})
    d['miss'] += miss; d['n'] += len(ms); d['tail'] += tail; d['call'] += call
    print(f"{p}: {len(ms)} flips, {miss} missed ({100 * miss / max(1, len(ms)):.2f}%); "
          f"tail med {q(tail, .5):.2f} p90 {q(tail, .9):.2f}; call med {q(call, .5):.2f} p90 {q(call, .9):.2f}")
for p, d in sorted(acc.items()):
    print(f"total {p}: {d['miss']}/{d['n']} missed = {100 * d['miss'] / max(1, d['n']):.2f}%; "
          f"tail med {q(d['tail'], .5):.2f} p90 {q(d['tail'], .9):.2f} p99 {q(d['tail'], .99):.2f}; "
          f"call med {q(d['call'], .5):.2f} p90 {q(d['call'], .9):.2f}")
PY
