#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copies the license texts of everything the app ships into <dest> (Contents/Resources/Licenses,
# also on the DMG; docs/LAUNCHER_REVIEW.md R8), with a README.txt naming each component and its
# license. Fails when a license file is missing, so a release cannot ship without them.
#   collect-licenses.sh <dest> <sparkle-license>                   the launcher (dev build)
#   collect-licenses.sh <dest> <sparkle-license> <python-root>     the self-contained app:
#       also the game runtime (macos/deps sources, submodules) and the embedded Python
# Python's linked libraries: packaging/licenses/python/, taken from python-build-standalone's
# "full" archive of the release fetch-python.sh pins (python/licenses/; the stripped archive has
# none). Refresh them when PBS_TAG changes.
set -euo pipefail
[[ $# -eq 2 || $# -eq 3 ]] || { sed -n '3,11p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
here=$(cd -- "$(dirname -- "$0")" && pwd -P)
repo=$(cd -- "$here/../.." && pwd -P)
dest=$1
sparkle=$2
python=${3:-}
deps=$repo/macos/deps/src
gpu=$repo/gpu/third_party

rm -rf -- "$dest"
mkdir -p -- "$dest"
readme=$dest/README.txt
cat > "$readme" <<'EOF'
Hunter's Lantern: licenses

Hunter's Lantern and the game runtime (bbport) are free software under the GNU General Public
License, version 2 or later; the source code is at https://github.com/Huax-1839/bloodborne-macos.
The app also contains the following components. Each folder holds its license texts.

EOF

add() { # <folder> <component: license> <file...>
    local folder=$1 what=$2 file
    shift 2
    mkdir -p -- "$dest/$folder"
    for file in "$@"; do
        [[ -f $file ]] || { echo "Missing license file: $file" >&2; exit 1; }
        cp -- "$file" "$dest/$folder/"
    done
    printf '%-24s %s\n' "$folder/" "$what" >> "$readme"
}

add HuntersLantern "Hunter's Lantern and bbport: GPL-2.0-or-later" "$repo/LICENSE"
add Sparkle "Sparkle (updates): MIT" "$sparkle"

if [[ -n $python ]]; then
    add MoltenVK "MoltenVK: Apache-2.0" "$deps/MoltenVK/LICENSE"
    add SDL3 "SDL 3: Zlib" "$deps/sdl3/LICENSE.txt"
    add FFmpeg "FFmpeg (built without GPL parts): LGPL-2.1-or-later" "$deps/ffmpeg/LICENSE.md" "$deps/ffmpeg/COPYING.LGPLv2.1"
    add SPIRV-Cross "SPIRV-Cross: Apache-2.0" "$deps/spirv-cross/LICENSE"
    add Vulkan-Headers "Vulkan-Headers: Apache-2.0 or MIT" "$deps/vulkan-headers/LICENSE.md" \
        "$deps/vulkan-headers/LICENSES/Apache-2.0.txt" "$deps/vulkan-headers/LICENSES/MIT.txt"
    add VulkanMemoryAllocator "Vulkan Memory Allocator: MIT" "$deps/vma/LICENSE.txt"
    add fmt "{fmt}: MIT" "$deps/fmt/LICENSE"
    add magic_enum "magic_enum: MIT" "$deps/magic_enum/LICENSE"
    add miniz "miniz: MIT" "$deps/miniz/LICENSE"
    add robin-map "robin-map: MIT" "$deps/robin-map/LICENSE"
    add xbyak "Xbyak: BSD-3-Clause" "$deps/xbyak/COPYRIGHT"
    add xxHash "xxHash: BSD-2-Clause" "$deps/xxhash/LICENSE"
    add Zydis "Zydis: MIT" "$deps/zydis/LICENSE"
    add Zycore "Zycore: MIT" "$deps/zycore/LICENSE"
    add LibAtrac9 "LibAtrac9: MIT" "$repo/third_party/LibAtrac9/LICENSE"
    add sirit "sirit: BSD-3-Clause" "$gpu/sirit/LICENSE.txt"
    add fsr-vulkan "FidelityFX FSR (Vulkan port): MIT" "$gpu/fsr-vulkan/LICENSE.txt" "$gpu/fsr-vulkan/NOTICE.md"
    add half "half: MIT" "$gpu/half/LICENSE.txt"
    # The AMD register headers carry their MIT license in the header comment.
    gcn=$(find "$gpu/gcn/include" -name '*.h' | sort | head -1)
    [[ -n $gcn ]] || { echo "Missing $gpu/gcn/include" >&2; exit 1; }
    mkdir -p -- "$dest/gcn"
    sed -n '1,/\*\//p' "$gcn" > "$dest/gcn/LICENSE.txt"
    grep -q 'Permission is hereby granted' "$dest/gcn/LICENSE.txt" || { echo "No license comment in $gcn" >&2; exit 1; }
    printf '%-24s %s\n' "gcn/" "AMD GCN register headers: MIT" >> "$readme"
    add Python "Python 3.13 (python-build-standalone): PSF-2.0 and the libraries linked into it" \
        "$python/lib/python3.13/LICENSE.txt" "$here"/licenses/python/*.txt
fi

cat >> "$readme" <<'EOF'

Boost (header-only, BSL-1.0) is used at build time; BSL-1.0 does not ask for its text with
compiled programs.
EOF
echo "Collected $(find "$dest" -type f | wc -l | tr -d ' ') license files in $dest"
