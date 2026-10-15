#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# ab.sh <name> <A> <B> [ENV=VAL ...]: A/B of two BB_TOGGLE_FILE settings within one game run, so
# both see the same thermal state and camera (the Air throttles by up to 30% over a series of
# runs). <A> and <B> are toggle file contents, "<disabled mask> <experiment bits>", e.g. "0 0"
# and "0 1099511627776". Boots into the clinic with bench.sh (KEEP=1), then alternates the
# phases A B B A A B ... (PHASE seconds each, the first 5-s frame-stats window after a switch is
# dropped) for CYCLES pairs, prints per phase and overall mean FPS and worst frame, quits the game.
#
#   BB_RENDERER=metal macos/bench/ab.sh fences "0 0" "0 1099511627776" BB_PROFILE=m4air BB_FPS=uncap
#
# PHASE (default 20), CYCLES (6); the environment of bench.sh applies (BB_RENDERER, BB_BENCH_DIR).
set -uo pipefail
export LC_ALL=C
here=$(cd -- "$(dirname -- "$0")" && pwd)
[[ $# -ge 3 ]] || { sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
name=$1 a=$2 b=$3; shift 3
bench=${BB_BENCH_DIR:-$HOME/Games/Bloodborne/bench}
toggle=$bench/runs/ab-$name.toggle
log=$bench/runs/bench-ab-$name.log
phase=${PHASE:-20} cycles=${CYCLES:-6}
mkdir -p "$bench/runs"
echo "$a" > "$toggle"
KEEP=1 BENCH_WAIT=${BENCH_WAIT:-20} "$here/bench.sh" "ab-$name" "$@" BB_TOGGLE_FILE="$toggle" |
    tail -1
pgrep -f out/bb-probe > /dev/null || { echo "ab $name: the game is not running" >&2; exit 1; }

stats() { grep 'Frame stats' "$log" | sed -E 's/^Frame stats: ([0-9.]+) FPS, worst frame ([0-9.]+) ms.*/\1 \2/'; }
results=$(mktemp)
order=(A B B A)
for ((i = 0; i < 2 * cycles; ++i)); do
    p=${order[i % 4]}
    [[ $p == A ]] && echo "$a" > "$toggle" || echo "$b" > "$toggle"
    sleep 5.5
    n0=$(stats | wc -l)
    sleep "$phase"
    stats | sed -n "$((n0 + 1)),\$p" | sed "s/^/$p /" >> "$results"
done
pkill -f out/bb-probe

awk -v name="$name" -v a="$a" -v b="$b" '
    { n[$1]++; f[$1] += $2; if ($3 > w[$1]) w[$1] = $3 }
    END {
        fa = n["A"] ? f["A"] / n["A"] : 0; fb = n["B"] ? f["B"] / n["B"] : 0
        printf "ab %s: A (%s) %.1f FPS worst %.1f ms (%d windows) | B (%s) %.1f FPS worst %.1f ms (%d windows) | B/A %+.1f%%\n",
               name, a, fa, w["A"], n["A"], b, fb, w["B"], n["B"], fa ? (fb / fa - 1) * 100 : 0
    }' "$results"
# Per phase, to see drift: the phase letter and its windows' FPS.
awk '{ if ($1 != p) { if (p != "") printf "\n"; printf "%s:", $1; p = $1 } printf " %s", $2 } END { printf "\n" }' "$results"
rm -f "$results"
