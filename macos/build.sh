#!/usr/bin/env bash
# macOS (Apple Silicon) build of bbport: an x86-64 process run by Rosetta 2, the renderer on
# MoltenVK. Dependencies: bash macos/build-deps.sh (once). Output: macos/out/.
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
deps=$PWD/macos/deps/x86_64
# The physical path, as pkg-config reports it (macos/deps may be a symlink, e.g. in a worktree).
[[ -d $deps ]] && deps=$(cd -- "$deps" && pwd -P)
out=$PWD/macos/out
[[ -f $deps/lib/libMoltenVK.dylib ]] || { echo 'Run bash macos/build-deps.sh first.' >&2; exit 1; }
mkdir -p "$out"
export PKG_CONFIG_LIBDIR=$deps/lib/pkgconfig:$deps/share/pkgconfig
export PKG_CONFIG_PATH=$PKG_CONFIG_LIBDIR
export MACOSX_DEPLOYMENT_TARGET=14.0
CC="clang -arch x86_64"

# Submodules.
if [[ ! -f gpu/third_party/fsr-vulkan/CMakeLists.txt ]]; then
    git submodule update --init --recursive
fi

cmake -S gpu -B "$out/gpu" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_PREFIX_PATH="$deps" -DCMAKE_FIND_ROOT_PATH="$deps" \
    -DBB_LTO="${BB_LTO:-OFF}" -DBB_NET=OFF >/dev/null
echo "GPU library: LTO ${BB_LTO:-OFF}"
if ! ninja -C "$out/gpu" bbgpu > "$out/gpu-build.log" 2>&1; then
    grep -E 'error|Error' "$out/gpu-build.log" | head -40 >&2
    echo "GPU library build failed (full log: $out/gpu-build.log)" >&2; exit 1
fi

# Only ../lib (SDL3, MoltenVK) on the library's search path: pkg-config's build-tree rpath
# would load a second MoltenVK.
if otool -l "$out/gpu/libbbgpu.dylib" | grep -q "path $deps/lib "; then
    install_name_tool -delete_rpath "$deps/lib" "$out/gpu/libbbgpu.dylib" 2>/dev/null
    codesign -f -s - "$out/gpu/libbbgpu.dylib" 2>/dev/null
fi

# Runtime and loader (C), linked against the GPU library.
read -r -a includes <<< "$(pkg-config --cflags sdl3) -I$deps/include"
read -r -a libraries <<< "$(pkg-config --libs sdl3)"
if [[ ! -f $out/libatrac9.a || -n $(find third_party/LibAtrac9/C/src -newer "$out/libatrac9.a" -name '*.c') ]]; then
    rm -rf "$out/atrac9" && mkdir -p "$out/atrac9"
    for source in third_party/LibAtrac9/C/src/*.c; do
        $CC -std=c99 -O2 -g -w -c "$source" -o "$out/atrac9/$(basename "${source%.c}").o"
    done
    ar rcs "$out/libatrac9.a" "$out/atrac9"/*.o
fi
$CC -std=c11 -O2 -g -Wall -Wextra -Werror -Wno-deprecated-declarations -pthread "${includes[@]}" -I. -Isrc \
    -include gpu/shim/bbport_platform.h \
    src/probe.c src/runtime*.c src/vulkan_smoke.c "$out/libatrac9.a" -lm \
    -L"$out/gpu" -lbbgpu -Wl,-rpath,@executable_path/gpu -Wl,-rpath,@executable_path/lib \
    -L"$deps/lib" -lvulkan "${libraries[@]}" -o "$out/bb-probe"
$CC -std=c11 -O2 -Wall -Wextra -Werror "${includes[@]}" tools/gpu_capabilities.c "${libraries[@]}" \
    -L"$deps/lib" -lvulkan -o "$out/bb-gpu-capabilities" 2>/dev/null || true
install_name_tool -delete_rpath "$deps/lib" "$out/bb-probe" 2>/dev/null && codesign -f -s - "$out/bb-probe" 2>/dev/null || true
# The process's libraries next to it: SDL3 and MoltenVK (the Vulkan "loader": libvulkan.1.dylib).
mkdir -p "$out/lib"
cp -f "$deps/lib/libSDL3.0.dylib" "$deps/lib/libMoltenVK.dylib" "$out/lib/"
ln -sf libMoltenVK.dylib "$out/lib/libvulkan.1.dylib"
ln -sf libMoltenVK.dylib "$out/lib/libvulkan.dylib"
echo "Built $out/bb-probe"
