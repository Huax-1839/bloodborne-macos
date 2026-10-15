#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# bench.sh <name> [ENV=VAL ...]: boots the bench save, continues into Iosefka's clinic, measures
# the in-game frame rate, takes a screenshot and quits the game. The machine should be otherwise
# idle; compare variants with interleaved runs (the Air throttles by up to 15%).
#
#   macos/bench/bench.sh vk-m4air BB_PROFILE=m4air BB_FPS=uncap
#   BB_RENDERER=metal macos/bench/bench.sh mtl-m4air BB_PROFILE=m4air
#
# BB_BENCH_DIR (default ~/Games/Bloodborne/bench) holds testuser/ (the user dir the game runs
# with), pristine-savedata/ (the fixed save, restored before every run since the game saves on
# every load) and tools/winid (built from winid.swift when missing). Logs, screenshots and
# results.tsv go to $BB_BENCH_DIR/runs (bench-<name>.png in the clinic, bench-<name>-title.png
# before the first input).
# BENCH_WAIT: seconds in the clinic before the result (75); BENCH_WINDOWS: 5-s frame-stats windows
# averaged (6); KEEP=1 leaves the game running; BB_RENDERER is passed through (default vulkan).
# BENCH_SAVE: the save restored, a folder in $BB_BENCH_DIR (default pristine-savedata, the clinic;
# pristine-savedata-yharnam: Central Yharnam).
set -uo pipefail
export LC_ALL=C
here=$(cd -- "$(dirname -- "$0")" && pwd)
repo=${BB_REPO:-$(cd -- "$here/../.." && pwd)}
bench=${BB_BENCH_DIR:-$HOME/Games/Bloodborne/bench}
runs=$bench/runs
[[ $# -ge 1 ]] || { sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
name=$1; shift
save=$bench/${BENCH_SAVE:-pristine-savedata}
[[ -d $save ]] || { echo "No $save (set BB_BENCH_DIR or BENCH_SAVE)." >&2; exit 2; }
mkdir -p "$runs" "$bench/tools" "$bench/testuser"
winid=$bench/tools/winid
[[ -x $winid ]] || swiftc -O "$here/winid.swift" -o "$winid" || exit 2
renderer=${BB_RENDERER:-vulkan}

pkill -f bb-probe; sleep 2
pad=$runs/pad.txt
: > "$pad"
rm -rf "$bench/testuser/savedata" && cp -R "$save" "$bench/testuser/savedata"
log=$runs/bench-$name.log
cd "$repo"
env BB_RENDERER="$renderer" "$@" BB_FRAME_STATS=1 BB_USER_DIR="$bench/testuser" BB_PAD_FILE="$pad" BB_PAD_FILE_ONLY=1 \
    bash macos/run.sh > "$log" 2>&1 < /dev/null &
for _ in $(seq 1 60); do grep -q 'Frame stats' "$log" && break; sleep 2; done
grep -q 'Frame stats' "$log" || { echo "$name: no frame stats after 120 s (log: $log)" >&2; pkill -f bb-probe; exit 1; }
sleep 30
# The title screen before any input: a static image for comparing backends (the clinic's camera
# differs a little between runs).
W=$("$winid" bb-probe | awk '{print $1}' | head -1)
[[ -n $W ]] && screencapture -x -o -l "$W" "$runs/bench-$name-title.png"
press() { echo cross > "$pad"; sleep 0.8; : > "$pad"; sleep 3; }
press; press
sleep "${BENCH_WAIT:-75}"

# Mean over the last BENCH_WINDOWS frame-stats windows, the worst frame among them.
summary=$(grep 'Frame stats' "$log" | tail -"${BENCH_WINDOWS:-6}" | sed -E \
    's/^Frame stats: ([0-9.]+) FPS, worst frame ([0-9.]+) ms.*, ([0-9]+) draws\/frame.*/\1 \2 \3/' |
    awk '{ f += $1; d += $3; if ($2 > w) w = $2; n++ }
         END { if (n) printf "%.1f %.1f %.0f %d", f / n, w, d / n, n }')
read -r fps worst draws windows <<< "$summary"
shot=$runs/bench-$name.png
W=$("$winid" bb-probe | awk '{print $1}' | head -1)
[[ -n $W ]] && screencapture -x -o -l "$W" "$shot" || shot=-
[[ -n ${KEEP:-} ]] || { pkill -f bb-probe; sleep 1; }

echo "$name ($renderer): ${fps:-?} FPS, worst ${worst:-?} ms, ${draws:-?} draws/frame (${windows:-0} windows); $shot"
# The clinic draws ~750 a frame; far fewer means the game never got there (a press missed while
# loading, or a hang).
if [[ ${draws:-0} -lt 100 ]]; then
    echo "$name: NOT IN GAME (${draws:-0} draws/frame): input missed or hang; see $log" >&2
    # A Cross press the game missed while loading: the whole run once more (not recorded).
    [[ -z ${BENCH_RETRIED:-} ]] && exec env BENCH_RETRIED=1 "$0" "$name" "$@"
fi
[[ -f $runs/results.tsv ]] || printf 'date\tname\trenderer\tfps\tworst_ms\tdraws\twindows\tcommit\tenv\n' > "$runs/results.tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date '+%F %T')" "$name" "$renderer" "${fps:-}" \
    "${worst:-}" "${draws:-}" "${windows:-0}" "$(git -C "$repo" rev-parse --short HEAD)" "$*" >> "$runs/results.tsv"
exit 0
