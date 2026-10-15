#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# m1_run.sh <name> <renderer> <minutes> [ENV=VAL...]: bench boot into the clinic (kept running),
# character menu screenshot, then <minutes> of scripted walking/looking; reports hangs.
# Also writes the per-flip log bench-<name>-frames.csv (BB_FRAME_LOG) and the power log
# bench-<name>-power.txt (power source, charge, Low Power Mode and thermal notes once a minute),
# which m3stats.py needs for its verdict. IDLE_MIN=<minutes>: wait that long first (the M3 rule's
# cool-down), recorded in the power log. ROUTE=<name>: first replay the route recorded with
# record_route.sh ($BB_BENCH_DIR/routes/<name>.pad, BB_PAD_REPLAY) until the game reports its end,
# screenshot bench-<name>-route.png, then the <minutes> of walking (0: none); check the result
# with route_check.py (checkpoints in routes/<name>.checkpoints).
name=$1; renderer=$2; minutes=$3; shift 3
runs=~/Games/Bloodborne/bench/runs; pad=$runs/pad.txt; log=$runs/bench-$name.log
winid=~/Games/Bloodborne/bench/tools/winid
power=$runs/bench-$name-power.txt
power_sample() {
    local batt src pct
    batt=$(pmset -g batt)
    src=$(sed -nE "1s/.*'(.*)'.*/\1/p" <<< "$batt")
    pct=$(grep -Eo '[0-9]+%' <<< "$batt" | head -1)
    echo "power $(date +%s) source=${src// /_} charge=${pct%\%} lowpower=$(pmset -g | awk '/lowpowermode/ {print $2}')" \
         "therm=$(pmset -g therm | grep -v '^Note' | tr -s ' \n' ' ' | sed 's/ *$//' | tr ' ' '_')"
}
: > "$power"
if [[ -n ${IDLE_MIN:-} ]]; then
    power_sample >> "$power"; sleep $(( IDLE_MIN * 60 )); echo "idle $(( IDLE_MIN * 60 ))" >> "$power"
fi
( while :; do power_sample >> "$power"; sleep 60; done ) &
sampler=$!
trap 'kill $sampler 2>/dev/null' EXIT
# Two windows (10 s) after a 20-s wait: bench.sh only has to see the game; the walk is measured
# from the logs.
route_env=()
if [[ -n ${ROUTE:-} ]]; then
    route=~/Games/Bloodborne/bench/routes/$ROUTE.pad
    [[ -s $route ]] || { echo "$name: no recorded route $route (record_route.sh)"; exit 1; }
    route_env=(BB_PAD_REPLAY="$route")
fi
KEEP=1 BENCH_WAIT=${BENCH_WAIT:-20} BENCH_WINDOWS=${BENCH_WINDOWS:-2} BB_RENDERER=$renderer \
    "$(dirname -- "$0")/bench.sh" "$name" BB_FRAME_LOG="$runs/bench-$name-frames.csv" \
    ${route_env[@]+"${route_env[@]}"} "$@" 2>&1 | tail -1
pgrep -f bb-probe >/dev/null || { echo "$name: game not running"; exit 1; }
shot() { W=$("$winid" bb-probe | awk '{print $1}' | head -1); [[ -n $W ]] && screencapture -x -o -l "$W" "$runs/bench-$name-$1.png"; }
press() { echo "$1" > "$pad"; sleep 0.4; : > "$pad"; sleep "${2:-1}"; }
if [[ -n ${ROUTE:-} ]]; then
    # The recording's length plus a minute for loading screens on the way.
    limit=$(( $(tail -1 "$route" | cut -d' ' -f1) / 1000 + 60 ))
    echo replay > "$pad"; sleep 1; : > "$pad"
    for _ in $(seq 1 "$limit"); do grep -q 'pad replay finished' "$log" && break; sleep 1; done
    grep -q 'pad replay finished' "$log" || echo "$name: route replay did not finish in $limit s"
    shot route
else
    press options 4; shot menu; press circle 2
fi
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
power_sample >> "$power"
pkill -f bb-probe; sleep 1
