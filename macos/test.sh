#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# macos/test.sh [target...]: builds and runs the GPU library's unit tests (by default every
# target of gpu/CMakeLists.txt named *-test) as x86-64 under Rosetta, 3 minutes each at most, and
# prints one line per target. Needs a configured build (bash macos/build.sh). Exit 1 if any failed.
# Without arguments it also builds and runs the runtime's C tests (tests/test_*.c, into
# macos/out/*-test), the launcher's tests (launcher/test.sh, swift test) and the Python tests in
# tests/ (test_game_check, test_patches, test_prepare, test_content, test_link_libc, test_mods,
# test_probe, test_runtime, test_sema); with targets only those GPU targets run.
# BB_TEST_SKIP=<regex> skips the GPU targets it matches (CI: '^mtl-', a virtual machine's
# paravirtual GPU cannot run the Metal tests).
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
    if [[ -n ${BB_TEST_SKIP:-} && $t =~ $BB_TEST_SKIP ]]; then
        echo "skip $t (BB_TEST_SKIP)"; continue
    fi
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

if [[ $# -eq 0 ]]; then
    # The runtime's C tests (src/): each links what it exercises, as macos/build.sh builds bb-probe.
    deps=$(cd macos/deps/x86_64 && pwd -P)
    export PKG_CONFIG_LIBDIR=$deps/lib/pkgconfig:$deps/share/pkgconfig PKG_CONFIG_PATH=$deps/lib/pkgconfig:$deps/share/pkgconfig
    read -r -a includes <<< "$(pkg-config --cflags sdl3) -I$deps/include"
    read -r -a libraries <<< "$(pkg-config --libs sdl3)"
    cflags=(-arch x86_64 -mmacosx-version-min=14.0 -std=c11 -O2 -g -Wall -Wextra -Werror
        -Wno-deprecated-declarations -pthread -include gpu/shim/bbport_platform.h -I. -Isrc)
    runtime=(src/runtime*.c macos/out/libatrac9.a -lm -Lmacos/out/gpu -lbbgpu
        -Wl,-rpath,"$PWD/macos/out/gpu" -Wl,-rpath,"$PWD/macos/out/lib" -L"$deps/lib" -lvulkan)
    for t in pad file-mods content runtime sema online; do
        case $t in
            pad) sources=("${includes[@]}" tests/test_pad.c src/runtime_low_heap.c "${libraries[@]}") ;;
            file-mods) sources=(tests/test_file_mods.c src/runtime_low_heap.c) ;;
            content) sources=(-D_GNU_SOURCE tests/test_content.c src/runtime_content.c) ;;
            *) sources=("${includes[@]}" "tests/test_$t.c" "${runtime[@]}" "${libraries[@]}") ;;
        esac
        if ! clang "${cflags[@]}" "${sources[@]}" -o "macos/out/$t-test" > "$logs/$t-test.build.log" 2>&1; then
            echo "BUILD FAIL $t-test (see $logs/$t-test.build.log)"; failed=1; continue
        fi
        if perl -e 'alarm 60; exec @ARGV' "macos/out/$t-test" > "$logs/$t-test.log" 2>&1; then
            echo "ok   $t-test"
        else
            echo "FAIL $t-test (see $logs/$t-test.log)"; failed=1
        fi
    done
    if bash launcher/test.sh > "$logs/launcher.log" 2>&1; then
        echo "ok   launcher (swift test)"
    else
        echo "FAIL launcher (swift test, see $logs/launcher.log)"; failed=1
    fi
    if (cd tests && python3 -m unittest -q test_game_check test_patches test_prepare test_content \
            test_link_libc test_mods test_probe test_runtime test_sema) > "$logs/python.log" 2>&1; then
        echo "ok   python (tests/test_*.py)"
    else
        echo "FAIL python (tests/test_*.py, see $logs/python.log)"; failed=1
    fi
fi
exit $failed
