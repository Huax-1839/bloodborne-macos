# macOS port: state and performance work (2026-10-15)

Public repository `Huax-1839/bloodborne-macos`, branch `main`: one squashed commit as the public start (2026-10-16), the work since on top;
the earlier history is kept privately (bundle backup), not in this repository. Never commit or push to the upstream repository (deadinside28/bloodborne_pc, a
foreign project; its push URL is disabled here); `../bloodborne_pc` (next to this checkout) is the old, untouched
upstream clone. Build: `bash macos/build-deps.sh` (once), `bash macos/build.sh`;
run: `bash macos/run.sh` (game in `~/Games/Bloodborne/CUSA03173-1.09`).
30 FPS profile for the MacBook Air M4: `BB_PROFILE=m4air bash macos/run.sh` (960x540 + MetalFX).
Renderer: Metal by default on Apple silicon with macOS 15+ (`macos/run.sh`), `BB_RENDERER=vulkan`
for the Vulkan backend on MoltenVK (the reference and the Linux path). The numbers and notes below
the "Next steps" heading are mostly from the Vulkan path.

## Works

- Boots, menus, intro movies, character creation, in-game (Iosefka's clinic) on an M4
  (10-core GPU, 16 GB) under Rosetta 2 + MoltenVK 1.4.2.
- Intro hang fixed: `gpu/shim/core/libraries/kernel/threads.h` (concurrent joins of one
  AvPlayer thread never returned on macOS; joins now take turns, a thread's own join is a no-op).

## Performance (clinic, same save and camera; the Air throttles: ±15% between runs)

| Setting | FPS |
|---|---|
| start of the first session | ~4.5 |
| start of this session (1080p, FSR 3 with object motion) | 8.5–9.2 |
| 1080p, object motion off (now the default on Apple) | ~11 |
| profile settings with a 720p scene (`BB_RENDER_RES=1280x720`), uncapped | ~20.5 |
| `BB_PROFILE=m4air` (540p scene, FSR 3 to 1080p, effects off, model LOD 1), uncapped | 28.5–33 |
| the same with the profile's 30 FPS cap, 7 min | 29.6 average, 30.0 most of the time |

What the time went into (in order of size):
1. **Per-object motion vectors** for FSR 3 (`object_motion`): the G-buffer vertex shaders store
   ~3.5 million positions a frame. Vertex stores are expensive on Apple GPUs: ~25 ms of vertex
   time a frame, resolution independent. FSR 3 itself is cheap (~4 ms at 540p→1080p). Now off by
   default on Apple (`gpu/shim/bbport_settings.h`); FSR 3 uses camera motion only.
2. **Geometry**: ~9 million indices in the G-buffer and ~12 million in shadow passes a frame.
   `model_lod=1` (patch) and `effect_dynamic_shadows=0` cut it (profile).
3. **Pixels**: ~31 ms per megapixel at 1080p-class settings (deferred lighting, post effects).
4. **Serial CPU chain under Rosetta**: PM4 decode → draw recording (`bb:DrawRec`) → Vulkan
   recording → MoltenVK's queue thread (encodes into Metal; ~25% of it is creating Metal render
   encoders). At 360p the MoltenVK queue thread was ~98% busy.

Measured and **not** worth it (kept off or reverted): MoltenVK prefill
(`MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS`, moves the encoding to the recorders but no gain),
more recording threads, LTO, `BB_ANISO=0`, fewer draw-prep workers, `BB_REACTIVE=0`.
Load/store from broken G-buffer passes turned out small on the M4.

## Changes of this session (uncommitted, built)

- `vk_scheduler.cpp` `MaybeSplit`: a render pass is cut for parallel recording only after
  `BB_VK_PASS_SPLIT_KB` (2048 on Apple): every cut ended the Metal encoder (MoltenVK ends it even
  for suspended passes).
- Dispatch hoisting with images (`HoistDispatch`, `BB_HOIST_IMAGES=0` turns it off): images the
  held pass does not use, or only samples, are allowed; their layout changes go before the pass
  (`Runtime::FlushImageBarriers`). Host copies keep a held pass held (`RecordHostCopy`,
  `BB_HOLD_HOST_COPIES=0`). G-buffer: 20 → 7 Metal encoders a frame.
- `Rasterizer::DrawsNothing`: draws with no target, no pixel shader and no memory writes are
  skipped (depth decompress rectangles, ~10 a frame; `BB_SKIP_EMPTY_DRAWS=0`).
- `vk_gpu_profiler.h`: query pool within Metal's 32 KiB limit (real GPU timestamps on Apple).
- `macos/run.sh`: `BB_PROFILE=m4air`; `scripts/patches.py`: `BB_SETTINGS=key=value,...`
  overrides bbport.ini (effects, model LOD).
- Diagnostics (env-gated, off by default): `BB_PASS_CENSUS=<s>` (every render pass of 3 frames
  with who ended it, `BB_PASS_CENSUS_FILE`), `BB_PASS_LABELS=1` (Metal encoder labels with pass
  size and shaders, for Instruments), `BB_HOIST_DIAG=1`, `BB_HOLD_DIAG=1`, `BB_GEO_DIAG=1`
  (indices per frame), `BB_DRAW_DIAG=<vs hash>`, `BB_DEFER_MARGIN=<ticks>`. The old `BbDiagTag`
  is removed.

## Fixed: sporadic device loss (stability)

`[mvk-error] … Lost VkDevice after MTLCommandBuffer … Invalid Resource`, then the assertion in
`GpuSignalLoop`, after ~1–6 min in-game (3 of 5 long runs; also in the previous session).
Cause, found with `MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=nslog NSZombieEnabled=YES`:
`-[MTLDebugHeap lockPurgeableState]: message sent to deallocated instance`, i.e. a freed VMA block
(a Metal heap) still in use. MoltenVK marks *every* buffer with a device address as used by each
encoder whose shaders use device addresses (`MVKDevice::encodeGPUAddressableBuffers`), with
unretained command buffers: freeing a block at its own last tick is not enough.
Fix (`vk_instance.cpp`, Apple only): VMA's `vkFreeMemory` goes through `DeferredFreeMemory`,
which frees a block only after `BB_DEFER_FREE_FRAMES` (8) more frames. 3 + 1 long runs since then
(7 min in-game each): no device loss. `MVK_CONFIG_USE_MTLHEAP=0` is no alternative (MoltenVK
needs heaps for 2D-on-3D views; the game does not start). `BB_DEFER_MARGIN` (more ticks for
deferred operations) did not help.

## Next steps

The Metal backend (`docs/METAL_BACKEND_PLAN.md`, plan and results; its §8 is the state) is done
through P7 and the default since 2026-10-15:
- M1 (same image as Vulkan) and M2 (≥ Vulkan FPS: m4air uncapped 32.2 vs 29.2, capped 29.4 vs
  26.8, native 1080p 9.8 vs 8.9) met.
- P7: geometry-shader draws (the clinic's dust motes) as a compute pre-pass, also indirect;
  MetalFX frame interpolation (`BB_FRAME_INTERPOLATION=1`, off by default: 2× frames on screen,
  ~3× latency, a 30 → 15 step when a game frame misses 33 ms); the live-resolution path (scene
  proxies shared with Vulkan as `VideoCore::SceneTargetsCore`, MetalFX on the HDR scene before
  post: 1080p Native AA and the presets switch live from the menu); 10 min with the validation
  layer clean; 30-min soaks without errors; command buffers and encoders were leaking through
  autorelease pools that never drained (fixed: the footprint grew ~45 MB/min, ~7 GB/min with the
  validation layer).
- **M3 not met**: 720p internal (`BB_PROFILE=m4air BB_RENDER_RES=1280x720`), 20 min walking: 24.9
  FPS mean on power with a hot Air, 29.0 on battery after a pause (51% of 5-s windows at 30); no
  device errors. The limit is the kernel's command buffer submission, slower when the Air is hot
  (worst frames 100–370 ms vs Vulkan's 35–50); options in the plan's §8 (Metal 4 command model,
  P6.4 untracked resources, fewer command buffers a frame). P8 (2026-10-15) found the hot Air
  GPU-bound instead: 35 ms of GPU work a frame at 720p when cool, 42–45 when warm; Metal's scene
  passes match Vulkan's; the savings without an image change are ~2 ms. The user moved M3 to
  540p (m4air). **M3 met at 540p (2026-10-16)**: 30.0 FPS mean on power and on battery, 97–98%
  of 5-s windows at 30, after P8.5: the guest memory chunks out of the Metal residency set (in
  it, the kernel unwired and rewired gigabytes whenever the GPU idled under the cap: a 30–100 ms
  hitch in every 5-s window).
- Wired-memory churn check: `metal-wired-sysmem-level-interval` of a Metal System Trace
  (`xcrun xctrace export ... --xpath '.../table[@schema="metal-wired-sysmem-level-interval"]'`);
  a healthy run has ~100 events a second and a flat level.
Debug aids: `BB_FRAME_STATS=1` (Metal draw/drop, pipeline and GS counters), `BB_GS_DEBUG=1`
(geometry-shader primitives in magenta), `BB_PRESENT_DUMP_TRIGGER=<file> BB_DUMP_DIR=<dir>`
(display buffer dumps on both backends), `macos/bench/m3stats.py` and `memgrowth.py` (long runs).
The items below are the state of the Vulkan path.

1. Sustained load: 7 min with `BB_PROFILE=m4air` averaged 29.6 FPS (30.0 most of the time,
   ~40 s at 28.6, frames of 50 ms then); heavier areas need more headroom.
2. HUD: with `BB_UPSCALER=none` and a reduced `BB_RENDER_RES` the HUD is scaled with the scene
   (native UI composition only exists in the upscaler path). 540p without FSR 3 gains ~4 ms.
3. CPU chain: fewer Metal render encoders (merge passes, ~270 a frame), cheaper `BindResources`
   (the biggest part of `DrawRecord`).
4. Heavier scenes (Central Yharnam, bosses) are not measured; the clinic is the only benchmark.
5. Geometry shaders are unsupported by MoltenVK: those draws are skipped on Vulkan (log warning);
   Metal draws them.

## Tooling (`macos/bench/`)

Bench data in `~/Games/Bloodborne/bench/` (`BB_BENCH_DIR`): `testuser/` (user dir),
`pristine-savedata/` (the fixed bench save, the clinic), `pristine-savedata-yharnam/` (Central
Yharnam, the player's save of 2026-10-16; `BENCH_SAVE=pristine-savedata-yharnam`), `tools/winid` (built from `macos/bench/winid.swift`),
`runs/` (logs, screenshots, `results.tsv`), `reference-*.png`.
- `macos/bench/bench.sh <name> [ENV=…]` (`BENCH_WAIT`, `BENCH_WINDOWS`, `KEEP=1`, `BB_RENDERER`):
  restores the fixed save (the game saves on every load), continues into the clinic via
  `BB_PAD_FILE`, prints mean FPS / worst frame / draws per frame, takes a screenshot, quits the
  game and appends a line to `runs/results.tsv`.
- `census.py` (pass census with symbolized end reasons), `busy_win.py` (GPU busy per window),
  `kids.py`/`busy.py` (`sample` call trees).
- `traceab.sh <name> <A> <B> [ENV=…]`: GPU time A/B of two `BB_TOGGLE_FILE` settings in one game
  run (traces A B B A, GPU busy a typical frame per variant, labels that differ most). Compare the
  busy union, not the per-label sum (MetalFX's internal blit overlaps its compute passes), and
  mind that the busy rises ~20% within minutes as the Air warms.
- Metal trace: `xcrun xctrace record --template 'Metal System Trace' --attach <pid>`; with
  `BB_PASS_LABELS=1` the GPU intervals carry the pass labels.
