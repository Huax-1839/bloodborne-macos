#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# m1_run.sh <name> <renderer> <minutes> [ENV=VAL...]: bench boot into the clinic (kept running),
# character menu screenshot, then <minutes> of scripted walking/looking; reports hangs.
name=$1; renderer=$2; minutes=$3; shift 3
runs=~/Games/Bloodborne/bench/runs; pad=$runs/pad.txt; log=$runs/bench-$name.log
winid=~/Games/Bloodborne/bench/tools/winid
KEEP=1 BENCH_WAIT=${BENCH_WAIT:-20} BB_RENDERER=$renderer \
    "$(dirname -- "$0")/bench.sh" "$name" "$@" 2>&1 | tail -1
pgrep -f bb-probe >/dev/null || { echo "$name: game not running"; exit 1; }
shot() { W=$("$winid" bb-probe | awk '{print $1}' | head -1); [[ -n $W ]] && screencapture -x -o -l "$W" "$runs/bench-$name-$1.png"; }
press() { echo "$1" > "$pad"; sleep 0.4; : > "$pad"; sleep "${2:-1}"; }
press options 4; shot menu; press circle 2
end=$(( $(date +%s) + minutes * 60 )); step=0
while (( $(date +%s) < end )); do
    case $(( step % 6 )) in
        0) echo "ly=0" > "$pad"; sleep 3 ;;          # forward
        1) echo "rx=255" > "$pad"; sleep 1 ;;        # look right
        2) echo "ly=0 lx=255" > "$pad"; sleep 2 ;;   # forward right
        3) echo "ly=255" > "$pad"; sleep 3 ;;        # back
        4) echo "rx=0" > "$pad"; sleep 1.5 ;;        # look left
        5) echo "lx=0" > "$pad"; sleep 2 ;;          # left
    esac
    : > "$pad"; sleep 0.5; step=$((step+1))
    if ! pgrep -f bb-probe >/dev/null; then echo "$name: game exited after $step steps"; break; fi
done
shot end
n1=$(grep -c 'Frame stats' "$log"); sleep 12; n2=$(grep -c 'Frame stats' "$log")
echo "$name: $step steps; frame stats $n1 -> $n2 ($([[ $n2 -gt $n1 ]] && echo alive || echo HANG?))"
grep 'Frame stats' "$log" | tail -3 | cut -c1-90
pkill -f bb-probe; sleep 1
