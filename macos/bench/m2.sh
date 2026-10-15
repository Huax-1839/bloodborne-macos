#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# m2.sh [profile...]: the M2 measurement of docs/METAL_BACKEND_PLAN.md (§1): Metal against Vulkan
# at identical settings, three runs each, interleaved in both orders (V M M V V M, or M V V M M V
# for every second profile), with bench.sh; prints each run and the means per profile. Profiles:
#   uncap   BB_PROFILE=m4air BB_FPS=uncap   (540p scene, MetalFX/FSR 3 to 1080p)
#   cap30   BB_PROFILE=m4air                (the profile's 30 FPS cap)
#   native  BB_FPS=30                       (1080p, no profile)
# Default: all three. The results also go to $BB_BENCH_DIR/runs/results.tsv (names m2-<profile>-*).
set -uo pipefail
export LC_ALL=C
here=$(cd -- "$(dirname -- "$0")" && pwd)
profiles=("$@")
[[ ${#profiles[@]} -gt 0 ]] || profiles=(uncap cap30 native)
summary=$(mktemp)
n=0
for profile in "${profiles[@]}"; do
    case $profile in
    uncap) env_args=(BB_PROFILE=m4air BB_FPS=uncap) ;;
    cap30) env_args=(BB_PROFILE=m4air) ;;
    native) env_args=(BB_FPS=30) ;;
    *) echo "unknown profile $profile" >&2; exit 2 ;;
    esac
    if (( n++ % 2 == 0 )); then order=(vulkan metal metal vulkan vulkan metal)
    else order=(metal vulkan vulkan metal metal vulkan); fi
    i=0
    for renderer in "${order[@]}"; do
        i=$((i + 1))
        line=$(BB_RENDERER=$renderer "$here/bench.sh" "m2-$profile-$i-$renderer" "${env_args[@]}" 2>&1 |
               grep -v 'NOT IN GAME' | tail -1)
        echo "$line"
        fps=$(sed -nE 's/.*: ([0-9.]+) FPS, worst ([0-9.]+) ms.*/\1 \2/p' <<< "$line")
        [[ -n $fps ]] && echo "$profile $renderer $fps" >> "$summary"
    done
done
echo "== M2 means (FPS, worst frame the largest of the runs)"
awk '{ k = $1 " " $2; f[k] += $3; n[k]++; if ($4 > w[k]) w[k] = $4; v[k] = v[k] " " $3 }
     END { for (k in f) printf "%-14s %5.1f FPS (runs:%s), worst %.1f ms\n", k, f[k] / n[k], v[k], w[k] }' \
    "$summary" | sort
rm -f "$summary"
