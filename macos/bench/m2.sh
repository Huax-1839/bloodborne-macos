#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# m2.sh [profile...]: the M2 measurement of docs/METAL_BACKEND_PLAN.md (§1): Metal against Vulkan
# at identical settings, three runs each, interleaved in both orders (V M M V V M, or M V V M M V
# for every second profile), with bench.sh; prints each run and the means per profile. Profiles:
#   uncap   BB_PROFILE=m4air BB_FPS=uncap   (540p scene, MetalFX/FSR 3 to 1080p)
#   cap30   BB_PROFILE=m4air                (the profile's 30 FPS cap)
#   native  BB_FPS=30                       (1080p, no profile)
# Default: all three. The results also go to $BB_BENCH_DIR/runs/results.tsv (names m2-<profile>-*).
# M2_ENV="ENV=VAL ...": added to every run of both backends (e.g. the BB_TOGGLE_FILE that turns the
# scene mip bias off: Metal applies it, MoltenVK does not, so M2 compares with it off, §9).
# Exit status 0 only when every profile has exactly three valid runs per backend (bench.sh exit 0
# and a parsed result line); otherwise the failed runs are listed and the means are not printed
# for the incomplete profiles.
set -uo pipefail
export LC_ALL=C
here=$(cd -- "$(dirname -- "$0")" && pwd)
profiles=("$@")
[[ ${#profiles[@]} -gt 0 ]] || profiles=(uncap cap30 native)
summary=$(mktemp)
n=0
failed=()
for profile in "${profiles[@]}"; do
    case $profile in
    uncap) env_args=(BB_PROFILE=m4air BB_FPS=uncap) ;;
    cap30) env_args=(BB_PROFILE=m4air) ;;
    native) env_args=(BB_FPS=30) ;;
    *) echo "unknown profile $profile" >&2; exit 2 ;;
    esac
    read -r -a extra <<< "${M2_ENV:-}"
    env_args+=(${extra[@]+"${extra[@]}"})
    if (( n++ % 2 == 0 )); then order=(vulkan metal metal vulkan vulkan metal)
    else order=(metal vulkan vulkan metal metal vulkan); fi
    i=0
    for renderer in "${order[@]}"; do
        i=$((i + 1))
        run=m2-$profile-$i-$renderer
        out=$(BB_RENDERER=$renderer "$here/bench.sh" "$run" "${env_args[@]}" 2>&1)
        status=$?
        echo "$out" | grep -E 'NOT IN GAME|FAILED' >&2
        line=$(grep -E '^m2-.*: [0-9.]+ FPS' <<< "$out" | tail -1)
        echo "$line"
        fps=$(sed -nE 's/.*: ([0-9.]+) FPS, worst ([0-9.]+) ms.*/\1 \2/p' <<< "$line")
        if [[ $status -eq 0 && -n $fps ]]; then
            echo "$profile $renderer $fps" >> "$summary"
        else
            echo "$run: invalid (bench.sh exit $status), not counted" >&2
            failed+=("$run")
        fi
    done
done
echo "== M2 means (FPS, worst frame the largest of the runs); 3 valid runs per backend required"
awk '{ k = $1 " " $2; f[k] += $3; n[k]++; if ($4 > w[k]) w[k] = $4; v[k] = v[k] " " $3 }
     END { for (k in f) printf "%-14s %5.1f FPS (runs:%s), worst %.1f ms%s\n", k, f[k] / n[k], v[k], w[k],
                               (n[k] == 3 ? "" : "  INCOMPLETE (" n[k] " of 3)") }' \
    "$summary" | sort
complete=true
for profile in "${profiles[@]}"; do
    for renderer in vulkan metal; do
        count=$(awk -v p="$profile" -v r="$renderer" '$1 == p && $2 == r' "$summary" | wc -l | tr -d ' ')
        (( count == 3 )) || { echo "M2 $profile $renderer: $count of 3 valid runs" >&2; complete=false; }
    done
done
rm -f "$summary"
[[ ${#failed[@]} -eq 0 ]] || echo "Failed runs: ${failed[*]}" >&2
$complete || { echo "M2 INCOMPLETE: no result" >&2; exit 1; }
