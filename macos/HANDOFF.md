# macOS port: state and history (2026-10-17)

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
reference). The repository is macOS only: the Linux build (top-level `build.sh`/`run.sh`,
`shell.nix`), the GTK launcher and the AppImage/Nix packaging were removed on 2026-10-17. A
native macOS launcher ("Hunter's Lantern", SwiftUI, DMG) is planned in `docs/LAUNCHER_PLAN.md`
(2026-10-17, no code yet).

## State

- Boots, intro movies, menus, character creation and gameplay with sound, gamepad and saving on an
  M4 Air (10-core GPU, 16 GB) under Rosetta 2. Tested mostly in the opening areas.
- **Metal backend** (`docs/METAL_BACKEND_PLAN.md`; its §8 is the current state and the open
  items): every milestone met.
  - M1, same image as Vulkan (2026-10-14).
  - M2, ≥ Vulkan FPS: +10% in each profile (m4air uncapped 32.2 vs 29.2, capped 29.4 vs 26.8,
    native 1080p 9.8 vs 8.9; 2026-10-15).
  - M3, 30 FPS for 20 min at 540p (m4air) on power and battery: 30.0 FPS mean in both, 97–98% of
    5-s windows at 30 (2026-10-16, by eye). 720p doesn't hold 30 on the Air: its GPU needs 35 ms
    a frame cool and 42–45 ms warm. Under the M3 acceptance rule (m3stats.py) the power run
    passes at b0a3d62 (1.27% missed 30-FPS slots; the limit moved from 1% to 2% on 2026-10-16,
    plan §9); **the battery run under the rule is still to do** (waiting for the user). What
    decides missed slots: plan §8, "P8.6 recording thread" (e)-(i).
  - P9.1 (2026-10-16): game fragment shaders without depth export and game compute shaders are
    emitted without `NoContraction` (SPIRV-Cross had made every float op an `optnone` helper
    call). GPU time a frame 24.7 → 16.5 ms at 540p, 37.3 → 24.6 ms at 720p; 540p uncapped 33.1 →
    43.6 FPS; images unchanged within the plan's §6. With it, 720p (`BB_RENDER_RES=1280x720`)
    held 30.0 FPS for 20 min on a warm Air (2.29% missed slots, the M3 rule allows 2%).
    `BB_MTL_STRICT_FLOAT=1` restores the old rules, `BB_MTL_RELAXED_MATH=1` adds Relaxed math
    (measured, no clear gain). Metal's pipeline cache for these rules is `<title>-metal-relaxed`
    (the strict one stays `<title>-metal`).
  - P10.1 (2026-10-17): texture-cache images are created without `ShaderWrite` and
    `PixelFormatView` (either one costs the Apple GPU's lossless compression of a colour target)
    and promoted on first need (a shader write, a view in another format): GPU time a frame 16.6
    → 14.9 ms at 540p, 21.5 → 18.2 ms at 720p, 43.4 → 38.1 ms at native 1080p; images unchanged.
    `BB_MTL_FULL_USAGE=1` restores the old usages; `BB_IMAGE_USAGE_LOG=<tsv>` (read with
    `macos/bench/image_usage.py`) records which usages each texture needs.
  - P11 (2026-10-17, power and heat on the Air, `docs/metal/power_budget_design.md`): at the 30 cap
    the CPU burned ~80% of the ~7-W package, almost all of it in the game's own 30-FPS limiter,
    which busy-waits on `gettimeofday`. `BB_CLOCK_SPIN_US` (default 100, `=0` off; both
    backends) sleeps a quantum inside the clock read once one call site spins: CPU −1.6 W
    (−35%) at 720p, missed slots not worse, 29.94 instead of 30.00 FPS. Uncapped
    (`BB_FPS=uncap`), 540p holds ~53 FPS (720p ~51) for 20 min with the Air at heavy thermal
    pressure and the P cores parked; milestone M4 (uncapped play as an option, the user's,
    mean ≥ 45, every minute ≥ 40) passes on AC, its gameplay check and battery run are open.
  - P12 (2026-10-17, asynchronous and parallel pipeline compiles): shader modules, the
    warm-up's cached pipelines and new pipeline states compile on a pool of threads
    (`BB_MTL_COMPILE_THREADS`, default cores − 2, 2–8); the recording thread waits for a
    pipeline in draw order while the GPU thread goes on to the next compiles, and new pipelines
    of passes drawn every frame go without their draws for a frame or two (the core's
    `BB_ASYNC_PIPELINES`, now on Metal too). First visit of Central Yharnam with empty caches:
    compile hitches of a 4-min walk 10.5–12.1 s → 4.1–4.3 s, worst frame 3.1 s → 0.6–0.9 s.
    Off switches: `BB_MTL_ASYNC_COMPILE=0` (no pool), `BB_MTL_DEFER_PSO=0` (no deferred
    builds), `BB_ASYNC_PIPELINES=0` (no skipped draws). Frame stats count the recording's waits
    as compile time; the periodic Metal stats print the deferred builds and the PSO time.
- Also on Metal: geometry-shader draws as a compute pre-pass, MetalFX temporal upscaling (scaled
  sessions and the live-resolution path with presets from the menu), MetalFX frame interpolation
  (`BB_FRAME_INTERPOLATION=1`, off by default), 30-min soaks without errors or memory growth, 10
  min with the validation layer clean.
- Measured mostly in Iosefka's clinic. Central Yharnam has a bench save; its only runs so far
  are P10.1's inventory boot (30.0 FPS at the cap, 1168 draws a frame).

## Next

First the runs that need the user at the Mac (P11): the M3 battery run under the acceptance rule
(with `POWERMETRICS=1 THREADCPU=10`; the bench cache was filled at 540p by the P10.1 runs), 720p
while charging and on battery, Low Power Mode at 540p/720p (P11.3: advice for players, into this
file and the README); M4's gameplay check (a route recorded by hand with `record_route.sh`,
replayed uncapped; sprint, a cutscene, falling objects by eye) and battery run. Then the user's call whether M3 goes back to 720p
(P9.1 made it nearly pass on a warm Air). Then the options,
in the plan's §8 "Resume here": heavier scenes (Central Yharnam first), the stretch
goals (60 FPS presented with frame interpolation, 1080p internal), Metal's worst frames (the
kernel's command buffer submission: Metal 4 command model, P6.4 untracked resources, fewer
command buffers a frame), small open checks. An ARM64 renderer is assessed in
`docs/ARM64_PORT_ASSESSMENT_2026-10-13.md` (not planned). Levers the plan does not cover yet,
ranked by estimated impact: `docs/PERFORMANCE_LEVERS_2026-10-16.md`; the first (shader float
semantics) is done (P9.1, `docs/metal/float_semantics_design.md`), the second (lossless texture
compression) too (P10.1, `docs/metal/texture_compression_design.md`), and the fourth
(pipeline compiles, P12); the rest need re-ranking against the faster frame.

## Debug aids

- Metal: `BB_FRAME_STATS=1` (draw/drop, pipeline, geometry-shader and command buffer counters),
  `BB_GS_DEBUG=1` (geometry-shader primitives in magenta), `BB_PASS_LABELS=1` (encoder labels with
  pass size and shaders, for Instruments), `BB_MTL_GUEST_IN_SET=1` (guest memory back in the
  residency set, the pre-P8.5 behaviour), `BB_MTL_STRICT_FLOAT=1` (pre-P9.1 float rules), `BB_MTL_FULL_USAGE=1` (pre-P10.1 texture
  usages), `BB_IMAGE_USAGE_LOG=<tsv>` (per-texture usage inventory, `macos/bench/image_usage.py`).
- Power and CPU (P11): `BB_THREAD_CPU_LOG=<s>` (per-thread CPU time grouped game / port / Metal /
  other, thermal pressure changes, poll and spin counters; `BB_THREAD_CPU_CSV=<path>` per thread),
  `BB_THERMAL_LOG=1` (thermal pressure only), `BB_GUEST_PROFILE=<s>` (guest-PC sampler of the
  game's main thread, `BB_GUEST_PROFILE_ALL=1` all game threads; Mach suspension, no signals),
  `BB_CLOCK_SPIN_US=0` (the limiter's spin back on).
- Both backends: `BB_PRESENT_DUMP_TRIGGER=<file> BB_DUMP_DIR=<dir>` (display buffer dumps),
  `BB_TOGGLE_FILE` (experiment bits at runtime, `gpu/shim/bbport_toggles.h`).
- Validation: `MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=nslog NSZombieEnabled=YES`.
- Wired-memory churn: the `metal-wired-sysmem-level-interval` table of a Metal System Trace
  (`xcrun xctrace export ... --xpath '.../table[@schema="metal-wired-sysmem-level-interval"]'`,
  or `macos/bench/churn.sh`); a healthy run has ~100 events a second and a flat level.

## Vulkan path (MoltenVK)

The reference for image comparisons and the fallback renderer; the numbers in this section predate the
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
- `m2.sh` (the M2 protocol), `m1_run.sh` (scripted walk for long runs; `POWERMETRICS=1`,
  `THREADCPU=<s>`), `m3stats.py` (the M3 rule; `--milestone m4` the M4 rule),
  `power.sh` (powermetrics next to a run: the user allowed exactly
  `sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,thermal[,tasks] -i 1000 -f plist`,
  stopped with SIGINT under job control), `powerstats.py` (watts, clocks, pressure per minute,
  joined with the flip and thread logs),
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
