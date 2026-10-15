#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# macos/test.sh [target...]: builds and runs the GPU library's unit tests (by default every
# target of gpu/CMakeLists.txt named *-test) as x86-64 under Rosetta, 3 minutes each at most, and
# prints one line per target. Needs a configured build (bash macos/build.sh). Exit 1 if any failed.
set -uo pipefail
cd -- "$(dirname -- "$0")/.."
out=macos/out/gpu
logs=macos/out/test-logs
mkdir -p "$logs"
if [[ $# -gt 0 ]]; then
    targets=("$@")
else
    read -r -a targets <<< "$(grep -o 'add_executable([a-z0-9_-]*' gpu/CMakeLists.txt |
        sed 's/add_executable(//' | grep -- '-test$' | tr '\n' ' ')"
fi
failed=0
for t in "${targets[@]}"; do
    if ! ninja -C "$out" "$t" > "$logs/$t.build.log" 2>&1; then
        echo "BUILD FAIL $t (see $logs/$t.build.log)"; failed=1; continue
    fi
    (cd "$out" && perl -e 'alarm 180; exec @ARGV' arch -x86_64 "./$t") > "$logs/$t.log" 2>&1
    rc=$?
    if [[ $rc -eq 0 ]]; then
        echo "ok   $t"
    else
        echo "FAIL $t (rc=$rc, see $logs/$t.log)"; failed=1
    fi
done
exit $failed
