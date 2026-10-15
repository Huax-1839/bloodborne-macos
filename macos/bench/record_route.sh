#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# record_route.sh <route name> [ENV=VAL ...]: records a route played by hand from the bench save,
# for scripted replays (m1_run.sh with ROUTE=<name>). Restores the bench save like bench.sh, starts
# the game with BB_PAD_RECORD and the m4air profile on Metal (override with ENV=VAL), and leaves
# the controls to the player:
#   1. continue into the game (Cross twice, as bench.sh does);
#   2. as soon as the character can move, click into the game window and press F9 (recording on);
#   3. play the route; press F9 again at its end (recording off); quit the game.
# The recording goes to $BB_BENCH_DIR/routes/<name>.pad (lines: ms buttons lx ly rx ry l2 r2) and
# the camera positions of the run to routes/<name>-frames.csv (BB_FRAME_LOG), from which
# route_check.py checkpoints can be taken.
set -uo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
repo=${BB_REPO:-$(cd -- "$here/../.." && pwd)}
bench=${BB_BENCH_DIR:-$HOME/Games/Bloodborne/bench}
[[ $# -ge 1 ]] || { sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
name=$1; shift
save=$bench/${BENCH_SAVE:-pristine-savedata}
[[ -d $save ]] || { echo "No $save (set BB_BENCH_DIR or BENCH_SAVE)." >&2; exit 2; }
mkdir -p "$bench/routes" "$bench/testuser"
pkill -f bb-probe; sleep 2
rm -rf "$bench/testuser/savedata" && cp -R "$save" "$bench/testuser/savedata"
echo "Recording to $bench/routes/$name.pad: continue into the game, F9 when you can move, F9 at the end."
cd "$repo"
env BB_RENDERER=metal BB_PROFILE=m4air "$@" BB_FRAME_STATS=1 BB_USER_DIR="$bench/testuser" \
    BB_PAD_RECORD="$bench/routes/$name.pad" BB_FRAME_LOG="$bench/routes/$name-frames.csv" \
    bash macos/run.sh > "$bench/routes/$name.log" 2>&1 < /dev/null
lines=$(wc -l < "$bench/routes/$name.pad" 2>/dev/null || echo 0)
echo "Recorded ${lines// /} samples; last $(tail -1 "$bench/routes/$name.pad" 2>/dev/null | cut -d' ' -f1) ms."
