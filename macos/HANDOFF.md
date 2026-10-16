# macOS port: state and history (2026-10-16)

Public repository `Huax-1839/bloodborne-macos`, branch `main`: one squashed commit as the public
start (2026-10-16), the work since on top; the earlier history is kept privately (bundle backup),
not in this repository, so commit hashes in the docs from before that date don't resolve here.
Never commit or push to the upstream repository (deadinside28/bloodborne_pc, a foreign project;
its push URL is disabled here); `../bloodborne_pc` (next to this checkout) is the old, untouched
upstream clone.

Build: `bash macos/build-deps.sh` (once), `bash macos/build.sh`; run: `bash macos/run.sh` (game in
`~/Games/Bloodborne/CUSA03173-1.09`). 30 FPS profile for the MacBook Air M4:
`BB_PROFILE=m4air bash macos/run.sh` (960x540 scene, MetalFX to 1080p). Renderer: Metal by default
on Apple silicon with macOS 15+, `BB_RENDERER=vulkan` for the Vulkan backend on MoltenVK (the
reference and the Linux path).

## State

- Boots, intro movies, menus, character creation and gameplay with sound, gamepad and saving on an
  M4 Air (10-core GPU, 16 GB) under Rosetta 2. Tested mostly in the opening areas.
- **Metal backend** (`docs/METAL_BACKEND_PLAN.md`; its §8 is the current state and the open
  items): every milestone met.
  - M1, same image as Vulkan (2026-10-14).
  - M2, ≥ Vulkan FPS: +10% in each profile (m4air uncapped 32.2 vs 29.2, capped 29.4 vs 26.8,
    native 1080p 9.8 vs 8.9; 2026-10-15).
  - M3, 30 FPS for 20 min at 540p (m4air) on power and battery: 30.0 FPS mean in both, 97–98% of
    5-s windows at 30 (2026-10-16). 720p doesn't hold 30 on the Air: its GPU needs 35 ms a frame
    cool and 42–45 ms warm. Under the stricter M3 rule (m3stats.py) only missed 30-FPS slots
    fail: 2.03% at d9619bc (<= 1% allowed); what decides them and the work on it: plan §8,
    "P8.6 recording thread" (e)-(h).
- Also on Metal: geometry-shader draws as a compute pre-pass, MetalFX temporal upscaling (scaled
  sessions and the live-resolution path with presets from the menu), MetalFX frame interpolation
  (`BB_FRAME_INTERPOLATION=1`, off by default), 30-min soaks without errors or memory growth, 10
  min with the validation layer clean.
- Measured only in Iosefka's clinic. Central Yharnam has a bench save and no runs yet.

## Next

The options, in the plan's §8 "Resume here": heavier scenes (Central Yharnam first), the stretch
goals (60 FPS presented with frame interpolation, 1080p internal), Metal's worst frames (the
kernel's command buffer submission: Metal 4 command model, P6.4 untracked resources, fewer
command buffers a frame), small open checks. An ARM64 renderer is assessed in
`docs/ARM64_PORT_ASSESSMENT_2026-10-13.md` (not planned).

## Debug aids

- Metal: `BB_FRAME_STATS=1` (draw/drop, pipeline, geometry-shader and command buffer counters),
  `BB_GS_DEBUG=1` (geometry-shader primitives in magenta), `BB_PASS_LABELS=1` (encoder labels with
  pass size and shaders, for Instruments), `BB_MTL_GUEST_IN_SET=1` (guest memory back in the
  residency set, the pre-P8.5 behaviour).
- Both backends: `BB_PRESENT_DUMP_TRIGGER=<file> BB_DUMP_DIR=<dir>` (display buffer dumps),
  `BB_TOGGLE_FILE` (experiment bits at runtime, `gpu/shim/bbport_toggles.h`).
- Validation: `MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=nslog NSZombieEnabled=YES`.
- Wired-memory churn: the `metal-wired-sysmem-level-interval` table of a Metal System Trace
  (`xcrun xctrace export ... --xpath '.../table[@schema="metal-wired-sysmem-level-interval"]'`,
  or `macos/bench/churn.sh`); a healthy run has ~100 events a second and a flat level.

## Vulkan path (MoltenVK)

The reference for image comparisons and the Linux path; the numbers in this section predate the
Metal backend.

Performance in the clinic (same save and camera; the Air throttles ±15% between runs):

| Setting | FPS |
|---|---|
| first session | ~4.5 |
| 1080p, FSR 3 with object motion | 8.5–9.2 |
| 1080p, object motion off (the default on Apple) | ~11 |
| 720p scene (`BB_RENDER_RES=1280x720`), uncapped | ~20.5 |
| `BB_PROFILE=m4air` (540p scene, FSR 3 to 1080p, effects off, model LOD 1), uncapped | 28.5–33 |
| the same with the 30 FPS cap, 7 min | 29.6 mean, 30.0 most of the time |

Where the time went (by size):
1. **Per-object motion vectors** for FSR 3 (`object_motion`): the G-buffer vertex shaders store
   ~3.5 million positions a frame, ~25 ms of vertex time, resolution independent (vertex stores
   are expensive on Apple GPUs). Off by default on Apple (`gpu/shim/bbport_settings.h`); FSR 3
   uses camera motion only. Not implemented on Metal.
2. **Geometry**: ~9 million indices in the G-buffer and ~12 million in shadow passes a frame;
   `model_lod=1` and `effect_dynamic_shadows=0` (m4air profile) cut it.
3. **Pixels**: ~31 ms per megapixel at 1080p-class settings (deferred lighting, post effects).
4. **Serial CPU chain under Rosetta**: PM4 decode → draw recording → Vulkan recording →
   MoltenVK's queue thread (~25% of it creating Metal render encoders; ~98% busy at 360p).

Tuning in the Vulkan backend (all on by default, each with an off switch):
- `vk_scheduler.cpp` `MaybeSplit`: a render pass is cut for parallel recording only after
  `BB_VK_PASS_SPLIT_KB` (2048 on Apple); MoltenVK ends the Metal encoder at every cut.
- Dispatch hoisting with images (`HoistDispatch`, `BB_HOIST_IMAGES=0`): images the held pass
  doesn't use or only samples are allowed, their layout changes go before the pass. Host copies
  keep a held pass held (`BB_HOLD_HOST_COPIES=0`). G-buffer: 20 → 7 Metal encoders a frame.
- `Rasterizer::DrawsNothing`: draws without target, pixel shader or memory writes are skipped
  (depth decompress rectangles, ~10 a frame; `BB_SKIP_EMPTY_DRAWS=0`).
- `vk_gpu_profiler.h`: query pool within Metal's 32 KiB limit (real GPU timestamps on Apple).
- Diagnostics (off by default): `BB_PASS_CENSUS=<s>` (every render pass of 3 frames with who
  ended it, `BB_PASS_CENSUS_FILE`), `BB_HOIST_DIAG=1`, `BB_HOLD_DIAG=1`, `BB_GEO_DIAG=1` (indices
  per frame), `BB_DRAW_DIAG=<vs hash>`, `BB_DEFER_MARGIN=<ticks>`.

Measured and **not** worth it: MoltenVK prefill (`MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS`),
more recording threads, LTO, `BB_ANISO=0`, fewer draw-prep workers, `BB_REACTIVE=0`. Load/store
from broken G-buffer passes is small on the M4.

Fixed, sporadic device loss: `[mvk-error] … Lost VkDevice … Invalid Resource` after 1–6 min
in-game. The validation layer with zombies showed a freed VMA block (a Metal heap) still in use:
MoltenVK marks *every* buffer with a device address as used by each encoder whose shaders use
device addresses, with unretained command buffers. Fix (`vk_instance.cpp`, Apple only): VMA's
`vkFreeMemory` goes through `DeferredFreeMemory`, which frees a block only after
`BB_DEFER_FREE_FRAMES` (8) more frames. `MVK_CONFIG_USE_MTLHEAP=0` is no alternative (the game
doesn't start).

Open on Vulkan:
1. HUD: with `BB_UPSCALER=none` and a reduced `BB_RENDER_RES` the HUD is scaled with the scene
   (native UI composition exists only in the upscaler path). 540p without FSR 3 gains ~4 ms.
2. CPU chain: fewer Metal render encoders (~270 a frame), cheaper `BindResources` (the biggest
   part of draw recording).
3. Geometry-shader draws are skipped (MoltenVK has no geometry shaders; log warning).

## Intro hang (fixed)

`gpu/shim/core/libraries/kernel/threads.h`: concurrent joins of one AvPlayer thread never
returned on macOS; joins now take turns, and a thread's own join is a no-op.

## Tooling (`macos/bench/`)

Bench data in `~/Games/Bloodborne/bench/` (`BB_BENCH_DIR`): `testuser/` (user dir),
`pristine-savedata/` (the fixed bench save, the clinic), `pristine-savedata-yharnam/` (Central
Yharnam, the player's save of 2026-10-16; `BENCH_SAVE=pristine-savedata-yharnam`),
`tools/winid` (built from `macos/bench/winid.swift`), `runs/` (logs, screenshots,
`results.tsv`), `reference-*.png`.
- `bench.sh <name> [ENV=…]` (`BENCH_WAIT`, `BENCH_WINDOWS`, `KEEP=1`, `BB_RENDERER`, default
  vulkan): restores the fixed save (the game saves on every load), continues into the clinic via
  `BB_PAD_FILE`, prints mean FPS / worst frame / draws per frame, takes a screenshot, quits the
  game and appends a line to `runs/results.tsv`.
- `m2.sh` (the M2 protocol), `m1_run.sh` (scripted walk for long runs), `m3stats.py` (5-s windows),
  `memgrowth.py` (footprint per minute).
- Within one run: `ab.sh` (FPS A/B of two `BB_TOGGLE_FILE` settings), `traceab.sh` (GPU time A/B;
  compare the busy union, not the per-label sum, and mind the ~20% rise as the Air warms),
  `dumpab.sh` (display dumps).
- Traces: `tracesub.sh` (kernel submit cost per command buffer), `mtltrace.py` (summary),
  `churn.sh` (wiring events), `busy_win.py` (GPU busy per window).
- `census.py` (pass census with symbolized end reasons), `kids.py`/`busy.py` (`sample` call trees),
  `imgdiff.py` / `rawdiff.py` (screenshots / raw dumps).
- Metal trace: `xcrun xctrace record --template 'Metal System Trace' --attach <pid>`; with
  `BB_PASS_LABELS=1` the GPU intervals carry the pass labels.
