#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# power.sh start <name> [seconds] | stop <name> | cmd <name>: record Apple's powermetrics (CPU and
# GPU power, cluster and GPU clocks and residency, thermal pressure, once a second) next to a game
# run; powerstats.py joins it with the run's per-flip log. Files in ~/Games/Bloodborne/bench/runs
# (BB_BENCH_DIR changes the base):
#   bench-<name>-powermetrics.plist   powermetrics' own `-f plist` stream (NUL-separated plists)
#   bench-<name>-powermetrics.start   wall epoch (date +%s) of the start
#   bench-<name>-powermetrics.stop    wall epoch of the (first) stop
#   bench-<name>-powermetrics.pid     pid of the sudo process (only when started by this script)
#   bench-<name>-powermetrics.err     its stderr; .wd: pid of the watchdog
# powermetrics needs root and this script never works around that. The user allowed exactly
#   sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,thermal -i 1000 -f plist
# (PM_TASKS=1: samplers cpu_power,gpu_power,thermal,tasks; also allowed, nothing else is: no -n,
# no -o, no --show-process-energy), stdout redirected to the plist. `start` launches that line in
# the background; if sudo exits within 3 s (a password is required), it prints the command for
# your own terminal (Ctrl-C ends it) and waits up to POWER_WAIT seconds (default 300) for the
# plist to appear and grow (exit status 1 if it never does). `stop` interrupts the sudo process
# (SIGINT, SIGTERM after 5 s) or, in the terminal case, only records the stop epoch.
# `seconds` (start): a watchdog stops the recording after that long (powermetrics cannot end
# itself with the allowed command line); a normal `stop` cancels it. `cmd` prints the command.
#
#   macos/bench/power.sh start 720p-a 1900      # then run m1_run.sh, or let POWERMETRICS=1 do it
#   macos/bench/power.sh stop 720p-a
#   python3 -I macos/bench/powerstats.py 720p-a
set -uo pipefail
export LC_ALL=C
runs=${BB_BENCH_DIR:-$HOME/Games/Bloodborne/bench}/runs
pm=/usr/bin/powermetrics
usage() { sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[[ $# -ge 2 ]] || usage
mode=$1; name=$2; seconds=${3:-}
[[ $mode == start || $mode == stop || $mode == cmd ]] || usage
[[ -z $seconds || $seconds =~ ^[0-9]+$ ]] || { echo "power.sh: seconds must be a number" >&2; exit 2; }
base=$runs/bench-$name-powermetrics
plist=$base.plist; startf=$base.start; stopf=$base.stop; pidf=$base.pid; errf=$base.err; wdf=$base.wd

samplers=cpu_power,gpu_power,thermal
[[ ${PM_TASKS:-} == 1 ]] && samplers+=,tasks
alive() { [[ -n ${1:-} ]] && kill -0 "$1" 2>/dev/null; }
terminal_cmd() { echo "  sudo $pm --samplers $samplers -i 1000 -f plist > $plist"; }

case $mode in
cmd)
    terminal_cmd | sed 's/^ *//'
    ;;
start)
    mkdir -p "$runs"
    rm -f "$plist" "$startf" "$stopf" "$pidf" "$errf" "$wdf" 2>/dev/null
    date +%s > "$startf"
    # set -m: a background job of a non-interactive shell would inherit SIGINT as ignored, and
    # stop's SIGINT would do nothing; in its own job it keeps the default.
    ( set -m
      nohup sudo -n "$pm" --samplers "$samplers" -i 1000 -f plist > "$plist" 2> "$errf" < /dev/null &
      echo $! > "$pidf" )
    sleep 3
    if alive "$(cat "$pidf" 2>/dev/null)"; then
        echo "power: powermetrics started (sudo pid $(cat "$pidf")), writing $plist"
        if [[ -n $seconds ]]; then
            ( set -m
              nohup bash -c 'sleep "$1"; exec "$2" stop "$3"' _ "$seconds" "$0" "$name" > /dev/null 2>&1 < /dev/null &
              echo $! > "$wdf" )
        fi
    else
        rm -f "$pidf" "$plist" "$startf"
        echo "power: sudo -n powermetrics did not run ($(head -c 200 "$errf" | tr '\n' ' ')); run this in your own terminal:"
        terminal_cmd
        wait_s=${POWER_WAIT:-300}; size=-1
        for (( i = 0; i < wait_s * 2; i++ )); do
            if [[ -f $plist ]]; then
                now=$(stat -f %z "$plist" 2>/dev/null || echo 0)
                (( now > 0 && size >= 0 && now > size )) && break
                size=$now
            fi
            sleep 0.5
        done
        if [[ -f $plist ]] && (( $(stat -f %z "$plist" 2>/dev/null || echo 0) > 0 )); then
            # The file's creation time is when the shell opened it, i.e. the start.
            stat -f %B "$plist" > "$startf"
            echo "power: $plist is growing (start epoch $(cat "$startf"))"
        else
            echo "power: no $plist after ${wait_s} s" >&2; exit 1
        fi
    fi
    ;;
stop)
    if [[ -f $wdf ]]; then
        wd=$(cat "$wdf"); rm -f "$wdf"
        if [[ $wd != $$ ]]; then pkill -P "$wd" 2>/dev/null; kill "$wd" 2>/dev/null; fi
    fi
    if [[ -f $pidf ]]; then
        pid=$(cat "$pidf")
        if alive "$pid"; then
            kill -INT "$pid" 2>/dev/null
            for _ in $(seq 10); do alive "$pid" || break; sleep 0.5; done
            alive "$pid" && { kill -TERM "$pid" 2>/dev/null; for _ in $(seq 10); do alive "$pid" || break; sleep 0.5; done; }
            alive "$pid" && echo "power: sudo pid $pid still running after SIGINT and SIGTERM" >&2
        fi
        rm -f "$pidf"
    fi
    [[ -f $stopf ]] || date +%s > "$stopf"
    [[ -f $plist ]] && echo "power: stopped; $(stat -f %z "$plist") bytes in $plist"
    ;;
esac
