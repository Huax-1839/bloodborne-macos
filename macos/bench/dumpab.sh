#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# dumpab.sh <name> <A> <B> [ENV=VAL ...]: image A/B of two BB_TOGGLE_FILE settings within one game
# run (same camera): boots into the clinic (bench.sh, KEEP=1), dumps the display buffer
# (BB_PRESENT_DUMP_TRIGGER) with A, B, A, B, and compares A1-A2 (the noise: animated flames, the
# idle character) with A1-B1 and A2-B2 (macos/bench/rawdiff.py), then quits the game.
#
#   BB_RENDERER=metal macos/bench/dumpab.sh hold "0 0" "0 2199023255552" BB_PROFILE=m4air
# DUMPAB_VAR=BB_PRESET_FILE switches live presets instead ("0" Native AA ... "3" Performance;
# read about every 64 frames, so DUMPAB_SETTLE defaults to 6 s then, else 3 s).
set -uo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
[[ $# -ge 3 ]] || { sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
name=$1 a=$2 b=$3; shift 3
bench=${BB_BENCH_DIR:-$HOME/Games/Bloodborne/bench}
dir=$bench/runs/dumpab-$name
toggle=$dir/toggle trigger=$dir/trigger var=${DUMPAB_VAR:-BB_TOGGLE_FILE}
settle=${DUMPAB_SETTLE:-$([[ $var == BB_PRESET_FILE ]] && echo 6 || echo 3)}
rm -rf "$dir" && mkdir -p "$dir"
echo "$a" > "$toggle"
KEEP=1 BENCH_WAIT=${BENCH_WAIT:-30} BENCH_WINDOWS=2 "$here/bench.sh" "dumpab-$name" "$@" \
    "$var=$toggle" BB_PRESENT_DUMP_TRIGGER="$trigger" BB_DUMP_DIR="$dir" | tail -1
pgrep -f out/bb-probe > /dev/null || { echo "dumpab $name: the game is not running" >&2; exit 1; }
dump() { # <setting> <label>
    echo "$1" > "$toggle"; sleep "$settle" # a few frames with the setting
    : > "$trigger"
    for _ in $(seq 1 50); do [[ -e $trigger ]] || break; sleep 0.1; done
    sleep 1
    local f; f=$(ls -t "$dir"/*.raw 2>/dev/null | head -1)
    [[ -n $f ]] || { echo "dumpab: no dump for $2" >&2; return; }
    grep -o '[0-9]*x[0-9]*' <<< "${f##*_present_}" | head -1 > "$dir/size"
    mv "$f" "$dir/$2.raw"
}
dump "$a" A1; dump "$b" B1; dump "$a" A2; dump "$b" B2
pkill -f out/bb-probe
read -r w h < <(tr x ' ' < "$dir/size")
for pair in "A1 A2" "A1 B1" "A2 B2" "B1 B2"; do
    set -- $pair
    printf 'dumpab %s %s-%s: ' "$name" "$1" "$2"
    python3 "$here/rawdiff.py" "$dir/$1.raw" "$dir/$2.raw" "$w" "$h" 2>&1 | grep -m1 psnr
done
