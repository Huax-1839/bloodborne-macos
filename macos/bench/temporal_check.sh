#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# temporal_check.sh <name> [ENV=VAL ...]: temporal behaviour of the upscaler on the Metal backend
# (MetalFX temporal, BB_PROFILE=m4air: 720p scene to 1080p), which still images cannot show.
# Boots the bench save into the clinic (bench.sh, KEEP=1, BB_RENDERER=metal and BB_PROFILE=m4air
# unless given), scripts the pad (BB_PAD_FILE) and dumps bursts of consecutive display frames
# (BB_PRESENT_DUMP_TRIGGER/_COUNT) into $BB_BENCH_DIR/runs/temporal-<name>/<sequence>/, then
# runs temporal_metrics.py on them (report in temporal-<name>/metrics.txt, contact sheets in
# <sequence>/sheet.png). Sequences (SEQS, default all):
#   vpan    slow vertical pan with BB_TOGGLE_FILE experiment 0 (base), 8 (motion y flipped),
#           2 (jitter y flipped), 0, 8, 2 again (A/B/C/A/B/C against drift): vpan-e<exp>-r<rep>
#   dpan    diagonal pan, base setting
#   strafe  strafe sideways with the camera still (disocclusion around the character)
#   cut     options menu open 2 s, closed with circle, BURST frames right after the close, then
#           BURST steady frames 3 s later (cut, cut-steady)
#   preset  a second game run on the live-resolution path (no BB_RENDER_RES: in a scaled session
#           the preset does nothing, BB_PRESET_FILE changes only the live path): a slow pan while
#           BB_PRESET_FILE goes Quality -> Performance (preset-q2p) and back (preset-p2q),
#           PRESET_FRAMES consecutive frames each; the file is polled every 64 frames
# Every pan: the stick is held from before the burst until it is dumped, released, and the same
# time pushed the other way (back to the same view), then SETTLE seconds of rest.
# Variables (defaults): SEQS BURST=12 SETTLE=2 PAN_LEAD=0.5 VPAN_DEV=100 (ry=128+-100; 40 is inside the dead zone)
#   DPAN_DX=40 DPAN_DY=30 STRAFE_DEV=60 STRAFE_LEAD=0.4 CUT_MENU_WAIT=2 CUT_HOLD=0.15
#   CUT_STEADY_WAIT=3 PRESET_FRAMES=80 PRESET_DEV=40 PRESET_FROM=1 PRESET_TO=3 PRESET_ENV="BB_AUTO_RENDER_RES=1
#   BB_UPSCALER=metalfx BB_UPSCALE_PRESET=1" BENCH_WAIT=30 KEEP_RAW=1 (keep the preset raws, 8 MB
#   a frame; RM_RAW=1 deletes all raws) METRICS_ARGS (e.g. "--jobs 2").
#
#   macos/bench/temporal_check.sh m4air-1
#   SEQS="vpan" VPAN_DEV=80 macos/bench/temporal_check.sh vpan-slow BB_FPS=30
#   python3 macos/bench/temporal_metrics.py ~/Games/Bloodborne/bench/runs/temporal-m4air-1
# Each dumped frame costs a GPU wait and an 8 MB write on the presenter thread (the game runs
# slower during a burst), and the presenter's dump code leaks about 8 MB a frame (no autorelease
# pool there): keep PRESET_FRAMES and BURST modest on a machine low on memory.
set -uo pipefail
export LC_ALL=C
here=$(cd -- "$(dirname -- "$0")" && pwd)
[[ $# -ge 1 ]] || { sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
name=$1; shift
bench=${BB_BENCH_DIR:-$HOME/Games/Bloodborne/bench}
runs=$bench/runs
pad=$runs/pad.txt
out=$runs/temporal-$name
dumpdir=$out/_dump trigger=$out/_trigger toggle=$out/_toggle presetfile=$out/_preset

SEQS=${SEQS:-vpan dpan strafe cut preset}
BURST=${BURST:-12}
SETTLE=${SETTLE:-2}
PAN_LEAD=${PAN_LEAD:-0.5}
VPAN_DEV=${VPAN_DEV:-100}
DPAN_DX=${DPAN_DX:-40} DPAN_DY=${DPAN_DY:-30}
STRAFE_DEV=${STRAFE_DEV:-60} STRAFE_LEAD=${STRAFE_LEAD:-0.4}
CUT_MENU_WAIT=${CUT_MENU_WAIT:-2} CUT_HOLD=${CUT_HOLD:-0.15} CUT_STEADY_WAIT=${CUT_STEADY_WAIT:-3}
PRESET_FRAMES=${PRESET_FRAMES:-80} PRESET_DEV=${PRESET_DEV:-40}
PRESET_FROM=${PRESET_FROM:-1} PRESET_TO=${PRESET_TO:-3}
PRESET_ENV=${PRESET_ENV:-"BB_AUTO_RENDER_RES=1 BB_UPSCALER=metalfx BB_UPSCALE_PRESET=1"}
export BB_RENDERER=${BB_RENDERER:-metal}

# BB_PROFILE=m4air unless the arguments set a profile.
profile=(BB_PROFILE=m4air)
for a in "$@"; do [[ $a == BB_PROFILE=* ]] && profile=(); done
args=("$@") # the ENV=VAL arguments, for every game run (start_game has its own "$@")

want() { [[ " $SEQS " == *" $1 "* ]]; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
alive() { pgrep -f bb-probe > /dev/null; }
cleanup() { : > "$pad" 2> /dev/null; pkill -f bb-probe 2> /dev/null; }
trap cleanup EXIT
fail() { echo "temporal_check: $*" >&2; exit 1; }

rm -rf "$out" && mkdir -p "$out" "$dumpdir"

# start_game <suffix> <dump frames per trigger> [ENV=VAL ...]: the clinic with the game kept
# running (the count is read once, at the first dump).
start_game() {
    local suffix=$1 count=$2; shift 2
    rm -f "$trigger" "$dumpdir"/*.raw
    KEEP=1 BENCH_WAIT=${BENCH_WAIT:-30} BENCH_WINDOWS=2 "$here/bench.sh" "temporal-$name$suffix" \
        ${profile[@]+"${profile[@]}"} ${args[@]+"${args[@]}"} "$@" BB_PRESENT_DUMP_TRIGGER="$trigger" BB_PRESENT_DUMP_COUNT="$count" \
        BB_DUMP_DIR="$dumpdir" | tail -1
    alive || fail "the game is not running ($suffix)"
}

# dump <sequence> <frames>: triggers a burst and moves its frames to <sequence>/f000_..., sets
# DUMP_FRAMES to the number of frames that arrived.
dump() {
    local seq=$1 n=$2 d=$out/$1 i=0 f c size want_size
    alive || fail "the game exited before $seq"
    mkdir -p "$d"; rm -f "$dumpdir"/*.raw
    : > "$trigger"
    for _ in $(seq 1 200); do [[ -e $trigger ]] || break; sleep 0.05; done
    if [[ -e $trigger ]]; then
        rm -f "$trigger"; echo "temporal_check: $seq: the game did not take the trigger (10 s)" >&2
        DUMP_FRAMES=0; return 1
    fi
    for _ in $(seq 1 $((n * 6 + 100))); do
        c=$(ls "$dumpdir" | grep -c '\.raw$')
        (( c >= n )) && break
        sleep 0.1
    done
    for _ in $(seq 1 50); do # the last file is still being written
        sleep 0.1
        f=$(ls "$dumpdir" | grep '\.raw$' | sort -t_ -k1.2,1n | tail -1)
        [[ -n $f ]] || continue
        size=$(stat -f %z "$dumpdir/$f")
        want_size=$(grep -o '[0-9]*x[0-9]*' <<< "$f" | head -1 | awk -Fx '{print $1 * $2 * 4}')
        [[ $size == "$want_size" ]] && break
    done
    while read -r f; do
        [[ -n $f ]] || continue
        mv "$dumpdir/$f" "$d/$(printf 'f%03d' $i)_${f#*_present_}"
        i=$((i + 1))
    done < <(ls "$dumpdir" | grep '\.raw$' | sort -t_ -k1.2,1n)
    DUMP_FRAMES=$i
    (( i == n )) || echo "temporal_check: $seq: $i of $n frames" >&2
    echo "temporal_check: $seq: $i frames"
}

# pan_dump <sequence> <frames> <forward sticks> <back sticks> <lead s>: hold the stick, dump
# while it is held, release, push the other way for the same time, rest.
pan_dump() {
    local seq=$1 n=$2 fwd=$3 back=$4 lead=$5 t0 t1 hold
    t0=$(now)
    echo "$fwd" > "$pad"; sleep "$lead"
    dump "$seq" "$n"
    t1=$(now)
    : > "$pad"
    hold=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.2f", b - a }')
    sleep 0.3
    echo "$back" > "$pad"; sleep "$hold"
    : > "$pad"; sleep "$SETTLE"
}

press() { echo "$1" > "$pad"; sleep "${3:-0.4}"; : > "$pad"; sleep "${2:-1}"; }

if want vpan || want dpan || want strafe || want cut; then
    echo "0 0" > "$toggle"
    start_game "" "$BURST" BB_TOGGLE_FILE="$toggle"
    sleep "$SETTLE"
    if want vpan; then
        exps=(0 8 2 0 8 2); reps=(1 1 1 2 2 2)
        for k in 0 1 2 3 4 5; do
            echo "0 ${exps[k]}" > "$toggle"; sleep "$SETTLE"
            pan_dump "vpan-e${exps[k]}-r${reps[k]}" "$BURST" "ry=$((128 + VPAN_DEV))" \
                "ry=$((128 - VPAN_DEV))" "$PAN_LEAD"
        done
        echo "0 0" > "$toggle"; sleep "$SETTLE"
    fi
    if want dpan; then
        pan_dump dpan "$BURST" "rx=$((128 + DPAN_DX)) ry=$((128 + DPAN_DY))" \
            "rx=$((128 - DPAN_DX)) ry=$((128 - DPAN_DY))" "$PAN_LEAD"
    fi
    if want strafe; then
        pan_dump strafe "$BURST" "lx=$((128 + STRAFE_DEV))" "lx=$((128 - STRAFE_DEV))" "$STRAFE_LEAD"
    fi
    if want cut; then
        press options "$CUT_MENU_WAIT"
        echo circle > "$pad"; sleep "$CUT_HOLD"; : > "$pad" # the dump starts right after the close
        dump cut "$BURST"
        sleep "$CUT_STEADY_WAIT"
        dump cut-steady "$BURST"
    fi
    pkill -f bb-probe; sleep 2
fi

if want preset; then
    echo "$PRESET_FROM" > "$presetfile"
    # shellcheck disable=SC2086
    start_game "-preset" "$PRESET_FRAMES" $PRESET_ENV BB_PRESET_FILE="$presetfile"
    sleep "$SETTLE"
    switch_delay=$(awk -v l="$PAN_LEAD" 'BEGIN { print l + 0.3 }')
    # The preset file is written just after the trigger: the switch (polled every 64 frames)
    # falls inside the burst.
    ( sleep "$switch_delay"; echo "$PRESET_TO" > "$presetfile" ) &
    pan_dump preset-q2p "$PRESET_FRAMES" "rx=$((128 + PRESET_DEV))" "rx=$((128 - PRESET_DEV))" "$PAN_LEAD"
    wait
    ( sleep "$switch_delay"; echo "$PRESET_FROM" > "$presetfile" ) &
    pan_dump preset-p2q "$PRESET_FRAMES" "rx=$((128 + PRESET_DEV))" "rx=$((128 - PRESET_DEV))" "$PAN_LEAD"
    wait
    pkill -f bb-probe; sleep 2
fi
rm -rf "$dumpdir"

echo "temporal_check: frames in $out; metrics:"
# shellcheck disable=SC2086
python3 "$here/temporal_metrics.py" "$out" ${METRICS_ARGS:-} | tee "$out/metrics.txt"
if [[ -n ${RM_RAW:-} ]]; then
    find "$out" -name '*.raw' -delete
elif [[ -z ${KEEP_RAW:-} ]]; then
    find "$out"/preset-* -name '*.raw' -delete 2> /dev/null
fi
echo "temporal_check: report $out/metrics.txt, contact sheets $out/*/sheet.png"
exit 0
