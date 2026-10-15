#!/usr/bin/env bash
# macOS (Apple Silicon): prepares the game image and starts bbport under Rosetta 2.
#   BB_GAME_DIR=/path/to/CUSA03173 bash macos/run.sh
# The game folder holds the base game with the 1.09 update copied over it (eboot.bin, sce_sys).
# Settings: macos/bbport.ini; saves and the shader cache: macos/user (BB_USER_DIR).
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
data=${BB_DATA_DIR:-$PWD/macos}
out=$data/out/game
mkdir -p "$out"
export BB_CONFIG=${BB_CONFIG:-$data/bbport.ini}
user=${BB_USER_DIR:-$data/user}
export BB_GPU_USER_DIR=${BB_GPU_USER_DIR:-$user}
mkdir -p "$user"
PYTHON=${PYTHON:-python3}
game=${BB_GAME_DIR:-$HOME/Games/Bloodborne/CUSA03173-1.09}
if [[ ! -f $game/eboot.bin ]]; then echo "No eboot.bin in $game (set BB_GAME_DIR)." >&2; exit 1; fi

[[ -x $data/out/bb-probe && -z ${BB_REBUILD:-} ]] || bash macos/build.sh

# Renderer: Metal on Apple silicon with macOS 15 or newer (docs/METAL_BACKEND_PLAN.md: same image
# as Vulkan, ~10% faster); BB_RENDERER=vulkan selects the Vulkan backend on MoltenVK.
if [[ -z ${BB_RENDERER:-} ]]; then
    if [[ $(sysctl -n hw.optional.arm64 2>/dev/null) == 1 && $(sw_vers -productVersion | cut -d. -f1) -ge 15 ]]; then
        export BB_RENDERER=metal
    else
        export BB_RENDERER=vulkan
    fi
fi
echo "Renderer: $BB_RENDERER"

"$PYTHON" scripts/prepare.py "$game" --out "$out"
"$PYTHON" scripts/link_libc.py "$game" --out "$out"
"$PYTHON" scripts/link_modules.py "$game" --out "$out"
"$PYTHON" scripts/content_profile.py "$game" --out "$out" --sku "${BB_CONTENT_SKU:-full}"

# BB_PROFILE=m4air: 30 FPS on a MacBook Air M4 (fanless, 10-core GPU). The scene at 960x540,
# FSR 3 to the 1080p output (the UI drawn at 1080p), frame rate capped at 30, the effects that
# cost most off and one model detail level lower (the clinic draws ~7 million triangles a frame).
# 1280x720 gives ~20 FPS there.
# Each value can still be given explicitly (BB_RENDER_RES, BB_FPS, BB_SETTINGS).
if [[ ${BB_PROFILE:-} == m4air ]]; then
    export BB_RENDER_RES=${BB_RENDER_RES:-960x540}
    export BB_FPS=${BB_FPS:-30}
    export BB_SETTINGS=${BB_SETTINGS:-effect_dynamic_shadows=0,effect_motion_blur=0,effect_dof=0,effect_ssao=0,model_lod=1}
fi
if [[ ${BB_AUTO_RENDER_RES:-} == 1 ]]; then
    unset BB_RENDER_RES BB_OUTPUT_RES BB_AUTO_RENDER_RES
fi
fps=${BB_FPS:-uncap}
# Outputs other than 1080p render the whole game at the preset's size (a patch at start), as on
# Linux; live resolution changes cost more than an M-series GPU has to spare, so they stay off.
if [[ -z ${BB_RENDER_RES:-} ]]; then
    read -r scaled_render scaled_output < <("$PYTHON" scripts/patches.py --print-scaled --settings "$BB_CONFIG") || true
fi
if [[ -n ${scaled_output:-} && ${BB_LIVE_RES:-0} != 1 ]]; then
    export BB_RENDER_RES=$scaled_render BB_OUTPUT_RES=$scaled_output BB_AUTO_RENDER_RES=1
    export BB_DMEM_MB=${BB_DMEM_MB:-9152}
    echo "Output ${scaled_output}: scene ${scaled_render}, direct memory ${BB_DMEM_MB} MiB"
fi
"$PYTHON" scripts/patches.py --out "$out" --fps "$fps" --extra "${BB_PATCHES:-}" --settings "$BB_CONFIG" \
    --game-dir "$game" --render-res "${BB_RENDER_RES:-}" --output-res "${BB_OUTPUT_RES:-}" \
    --patches-dir "${BB_PATCHES_DIR:-$data/patches}" --patches-config "${BB_PATCHES_CONFIG:-$data/patches.json}"

# Memory model: the new one through the layer's memory module. Metal has no sparse buffers (the
# 0.3 model's VRAM arena needs them); on Apple silicon's unified memory the GPU uses the game's
# memory where it is, imported without copies (VK_EXT_external_memory_host).
export BB_PC_MODEL=1 BB_GUEST_IN_PLACE=${BB_GUEST_IN_PLACE:-1} BB_LAYER_MEMORY=1 BB_GUEST_MEMORY=host
export BB_PREUPLOAD=${BB_PREUPLOAD:-1}
export BB_UFFD=0
export BB_COPY_GPU_BUFFERS=${BB_COPY_GPU_BUFFERS:-1}
export BB_GPU_WRITE_TWINS=${BB_GPU_WRITE_TWINS:-1} BB_GPU_WRITE_TWINS_MAX=${BB_GPU_WRITE_TWINS_MAX:-65536}
if [[ -z ${BB_VBLANK_HZ:-} ]]; then
    case $fps in uncap) export BB_VBLANK_HZ=480 ;; 90) export BB_VBLANK_HZ=90 ;; *) export BB_VBLANK_HZ=60 ;; esac
fi
# MoltenVK encodes every submission into Metal on one thread, translated by Rosetta like the
# rest of the process: that thread limits the frame rate. Without argument buffers it encodes
# the per-draw descriptors faster (~40% more FPS in the game).
export MVK_CONFIG_LOG_LEVEL=${MVK_CONFIG_LOG_LEVEL:-1}
export MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=${MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS:-0}
export MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=${MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS:-0}
# End-of-pipe labels written by a CPU thread after the GPU: written by the GPU (portable path,
# no AMD buffer markers) each ended the render pass and added barriers that MoltenVK checks
# against every resource.
export BB_GPU_LABELS=${BB_GPU_LABELS:-0}
# Rosetta 2 runs AVX; this makes CPUID say so too (libraries that pick code paths by CPUID).
export ROSETTA_ADVERTISE_AVX=${ROSETTA_ADVERTISE_AVX:-1}

probe=${BB_PROBE:-$data/out/bb-probe}
exec "$probe" "$out/boot-linked.bin" --content-profile "$out/content.bin" --patches "$out/patches.bin" \
    --app0 "$game" --user "$user" --timeout "${BB_TIMEOUT:-0}" "$@"
