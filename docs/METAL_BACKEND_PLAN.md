# Metal backend: plan

Status: P0–P8 done except the M3 battery run under the acceptance rule: M1 met (2026-10-14), M2 met (2026-10-15, target changed, §9), Metal the default on Apple (2026-10-15); M3 at 540p (m4air; target moved from 720p by the user's decision, §9) passes the acceptance rule on power (2026-10-16, b0a3d62, after the missed-slot limit moved to 2%, §9), the battery run is pending. P9.1 (shader float semantics) done 2026-10-16: GPU time a frame −33%, V1 the Metal default (ea029d9). P10.1 (lossless texture compression) in progress since 2026-10-17. Progress is tracked in the checklist in §8;
the orchestrating session updates it after every step (see `CLAUDE.md`).

## 0. How binding this plan is

The plan was written before any Metal code existed: its goals are firm, its route is a best
guess. Findings during the work are expected to change the route.

**Fixed: change only after asking the user** (stop and ask; do not work around it):
- the goal of a direct Metal backend and the milestones M1–M3 (§1);
- the Vulkan backend keeps working, and it stays the default until M1 and M2 are met;
- new third-party dependencies other than SPIRV-Cross;
- dropping a feature the game shows (an effect, the HUD, the overlay), even temporarily as the
  default;
- giving up the approach (e.g. because Metal is not faster after P4/P6).

**Open: the orchestrator decides on evidence**: the decisions D1–D13, the phase order, how tasks
are split and who does them, the file mapping (§4), the verification thresholds (§6, once
calibrated), anything in §5 below the level of a milestone.

Rules for a deviation:
- It needs evidence: a measurement, a trace, a failed spike, a build/validation error or code
  that contradicts an assumption. Not a preference.
- The plan is edited where the change applies (it always describes the current route, not the
  original one plus contradicting notes), and the change gets an entry in the decision log (§9):
  date, what changed, the evidence, what it affects.
- Reasons to stop and re-plan before continuing: an exit criterion turns out to be unreachable,
  a measurement contradicts §2's assumptions, a spike in P0 fails, or a task needs ≥ 2× the
  effort its phase implies.
- Porters never deviate on their own: when a spec does not fit the code, they stop and report;
  the orchestrator decides and updates the spec.

## 1. Goal

A second renderer backend that drives the Apple GPU through **Metal directly**, replacing the
Vulkan → MoltenVK → Metal chain on macOS. It is selected at runtime (`BB_RENDERER=metal`) next to
the existing Vulkan backend, which stays untouched as the reference for image comparisons and
benchmarks.

Targets (MacBook Air M4, 10-core GPU, Iosefka's clinic, the bench save):

| Milestone | Target |
|---|---|
| M1 parity | Same image as Vulkan (within the diff threshold, §6) at the same settings |
| M2 faster | ≥ Vulkan FPS at the same settings in the M2 protocol (`macos/bench/m2.sh`: m4air uncapped and capped, native 1080p at 30 FPS) — met 2026-10-15 (+10% in each); the original 36 FPS at 540p uncapped was dropped (§9) |
| M3 goal | 540p internal (`BB_PROFILE=m4air`, MetalFX to 1080p) at a stable 30 FPS for 20 min on the Air, on power and battery; first 720p, changed 2026-10-15 (§9: at 720p the warm Air's GPU needs 42–45 ms a frame) |
| Stretch | 1080p internal at 30 FPS, or 60 FPS presented with MetalFX frame interpolation |

**M3 acceptance rule** (set 2026-10-16 after review finding 7, by the user's choice of the
recommended rule; §9). "Stable 30 FPS" is met when one run on AC power and one on battery each
pass every rule below; `macos/bench/m3stats.py --expect power|battery <log>` checks them and
exits 0 only then. The run: `IDLE_MIN=10 macos/bench/m1_run.sh <name> metal 20 BB_PROFILE=m4air`
(10 min idle, then 20 min of the scripted walk), which writes the per-flip log
(`bench-<name>-frames.csv`, `BB_FRAME_LOG`) and the power log (`bench-<name>-power.txt`).
In-game span: first to last flip with ≥ 300 draws.

| Rule | Threshold |
|---|---|
| duration | in-game span ≥ 20 min, ≥ 99% of its flips in game (no drop to a menu or loading screen) |
| rate | mean ≥ 29.7 FPS; every full 60-s stretch ≥ 29.5 FPS; ≥ 98% of 5-s windows ≥ 29.5 FPS |
| pacing | ≤ 2% of flips miss their 30-FPS slot (> 41.7 ms, i.e. a vblank late; 1% until 2026-10-16, §9); p99.9 ≤ 58.3 ms |
| hitches | ≤ 1 flip over 100 ms per 5 min (4 in 20 min); no flip over 250 ms |
| errors | no failed command buffer / lost device in the game log |
| conditions | power log present; idle ≥ 10 min before; Low Power Mode off throughout; one power source throughout (AC for the power run, battery for the battery run, battery ≥ 50% at its start) |

Why these numbers: at the 30 cap a flip is 33.3 ms on time or 50 ms one vblank late, so 41.7 ms
separates "on time" from "missed" independent of timer jitter; 2% missed slots is one 50-ms
frame every ~1.7 s at worst (in practice they cluster in heavy stretches of the walk), and runs
of one build vary by more than 1 point (P8.6), so a 1% line was decided by run-to-run noise; 100 ms is a hitch a player notices, 250 ms a freeze.

Non-goals: Linux/AMD changes (the Vulkan backend must keep working everywhere), FSR 4 / FSR 4.1.1
/ DLSS in the Metal path, removing Rosetta (the process stays x86-64; see §2), a native MSL
shader emitter (only if §5 P6 shows SPIRV-Cross is the limit).

## 2. Why Metal, and what it can and cannot fix

Measured on the Vulkan path (`macos/HANDOFF.md`): the frame time is dominated by **GPU work**
(object-motion vertex stores, ~21 M indices/frame, ~31 ms per megapixel of deferred shading), then
a **serial CPU chain** (PM4 decode → draw recording → Vulkan recording → MoltenVK's queue thread,
~270 Metal render encoders a frame, ~25% of the queue thread creating encoders). Rosetta only
slows the CPU chain.

What a direct Metal backend changes:
- **Pass structure and tile memory**: we decide when an encoder ends, its load/store actions,
  memoryless attachments and in-pass barriers (`memoryBarrierWithScope:afterStages:beforeStages:`)
  instead of MoltenVK ending encoders at every barrier, suspend or parallel-recording split.
- **CPU per draw**: no Vulkan recording, no MoltenVK state translation, no descriptor-set →
  argument-buffer conversion, no per-encoder `useResource` of every device-address buffer (the
  cause of the device-loss bug, fixed with deferred frees). Residency sets instead.
- **Parallel encoding in one pass**: `MTLParallelRenderCommandEncoder` (or Metal 4 command
  buffers) lets several threads encode one render pass without splitting it.
- **Apple features**: MetalFX temporal upscaling (instead of FSR 3) and frame interpolation.

What it does not change: the game's own CPU code under Rosetta, the GCN → IR shader translation,
the amount of geometry and pixels the game asks for.

## 3. Architecture decisions

- **D1 Runtime switch.** `BB_RENDERER=metal|vulkan` (default `vulkan` until M1+M2, then `metal`
  on Apple). `macos/run.sh` passes it through. Both backends are built into `libbbgpu`.
- **D2 Seams at the frontend boundary and under the caches.** Two abstract interfaces,
  `VideoCore::RasterizerApi` and `VideoCore::PresenterApi`, contain exactly the methods called
  from outside the backend (Liverpool, `shim/bbgpu.cpp`, the memory manager, GNM hooks,
  `videoout/driver.cpp`, the overlay). `Vulkan::Rasterizer`/`Vulkan::Presenter` implement them
  with no behaviour change (done in P1.2). The buffer and texture caches are shared by both
  backends through a thin backend interface under them (`VideoCore::CacheBackend`, ~25 methods:
  create/import/destroy buffers, images, views, samplers; record transfers; run the caches' own
  kernels (detiling, fault parsing, blits); ticks, waits, deferred frees and access tracking;
  format queries; staging). Evidence (`docs/metal/cache_coupling.md`): of the caches' 12.4k
  lines only 1.1k (9%) touch Vulkan; a copy would duplicate ~11k neutral lines. Vulkan enums and
  plain structs (`vk::Format`, `vk::ComponentMapping`, usage flags, …) stay the shared vocabulary
  (header-only, no Vulkan calls); the Metal backend maps them (`vk_to_mtl`). Vulkan-only features
  behind the interface (sparse arena, `FastReadback`'s own queue) stay in the Vulkan
  implementation; Metal uses the layer-memory path (`BB_LAYER_MEMORY=1`, the macOS default).
  The same holds for the rasterizer: its backend-neutral logic (draw pipe and the stage A/B
  threads, ordered tasks, signals and labels, host copies, faults and memory notes, resource
  selection, scene-resolution decisions; ~3.8k of `vk_rasterizer.cpp`'s 4.8k lines, plus draw
  pipe, draw preparation and bind helper) becomes a shared `RasterizerCore`; the recording goes
  through a `DrawRecorder` interface (passes, pipelines, dynamic state, vertex/index/resource
  binding, draws and dispatches, memory barriers, queries, markers). Evidence:
  `docs/metal/rasterizer_coupling.md` (a Metal copy would duplicate ~6.4k lines).
- **D3 Separate backend directory.** `gpu/shadps4/video_core/renderer_metal/` holds the Metal
  rasterizer, scheduler, cache backend, pipelines and presenter, ported from their Vulkan
  counterparts.
  Backend-neutral logic is **shared, not copied**: where a Vulkan file mixes logic with `vk::`
  calls, the neutral part is first extracted into a shared file (its own commit, Vulkan image
  and FPS verified unchanged).
- **D4 Objective-C++ with ARC** (`*.mm`, `-fobjc-arc`) inside `renderer_metal/` only. Its headers
  are plain C++ (pimpl / opaque handles): no Objective-C types leak into shared code. No
  metal-cpp (no new dependency needed).
- **D5 Shaders: IR → SPIR-V (existing backend) → SPIRV-Cross → MSL → `MTLLibrary`.**
  SPIRV-Cross (Apache-2.0) is vendored by `macos/build-deps.sh` at a pinned tag and built for
  x86-64 (tag `vulkan-sdk-1.4.363.0`). Resource bindings are remapped explicitly
  (`MSLResourceBinding`); the P0 spike's direct-slot layout fits every cached shader (push
  constants at buffer 0, then buffers from 1, textures and samplers from 0, vertex buffers from
  30 down; max 12 buffers, 15 textures, 8 samplers per stage), so P3 starts with direct slots and
  P3.4 only revisits it for CPU cost. Fragment inputs decorated `PerVertexKHR` (pull-model
  interpolation, 4 of 425 cached shaders) are not translatable by SPIRV-Cross and MSL has no
  per-vertex fragment inputs: P3.1 handles them (see the task). Compiled MSL and pipeline descriptors are cached on disk next to the Vulkan shader cache
  (key includes backend + SPIRV-Cross version); `MTLBinaryArchive` for PSOs. The Xbyak resource
  walker stays (the process is x86-64).
- **D6 Memory: zero copy.** Guest direct-memory chunks become `MTLBuffer`s with
  `newBufferWithBytesNoCopy` (storage mode shared, unified memory, hazard tracked); shaders use
  their `gpuAddress` for device-address accesses. Residency, as built (P6.1, P8.5):
  - one `MTLResidencySet` attached to the draw queue (macOS 15+) and `requestResidency`'d once,
    so it stays resident while the GPU idles; it holds every cache buffer and texture for its
    life (P6.1, `BB_MTL_RESIDENT_ALL=0`: only buffers with a device address, A/B), added at
    creation and removed at destruction;
  - the **guest memory chunks are not in the set**: every render and compute encoder declares
    them with `useResources` (`UseGuestChunks`, mtl_scheduler.mm), blits name their buffers, as
    MoltenVK does with imported host memory. In the set, the kernel unwired and rewired whole
    chunks (up to 2.3 GiB) around every idle GPU period under the 30-FPS cap, which was the
    83–233 ms hitches (P8.5); `BB_MTL_GUEST_IN_SET=1` restores the old policy for A/B only.
  Lifetime: command buffers are created with `retainedReferences = NO`; nothing is kept alive by
  Metal, so every destroy of GPU-visible memory (cache buffers, textures, samplers, guest chunks,
  staging) is deferred until the scheduler's `retired_tick` (advanced in the command buffers'
  completion handlers) has passed the last tick that could see it (the lesson of the
  device-loss bug). The present queue (D7) only reads the frame image, which the presenter
  keeps referenced until its own command buffer completes.
  P0 probe (Rosetta process): no-copy buffers accept 4 KiB-aligned host memory; a buffer is at
  most `maxBufferLength` = 8.88 GiB, so direct memory above that (`BB_DMEM_MB=9152`) needs more
  than one buffer; device-address accesses work with residency-set residency alone (no
  `useResource`), and silently read/write nothing without it.
- **D7 Command model.** Two queues, as built:
  - the **draw queue** (`mtl_device`): every command buffer of the scheduler (draws, dispatches,
    blits, the post-process pass), in tick order; each signals the scheduler's `MTLSharedEvent`
    with its tick when it completes on the GPU, and its completion handler advances
    `retired_tick` (D6) and reports a failed command buffer;
  - the **present queue** (`mtl_presenter`): one command buffer per presented (or interpolated)
    frame that `encodeWaitForEvent`s the frame's tick on that event before it reads the frame
    image, so the present overlaps later draw work on the GPU (P6: 96% of it) without a CPU
    wait. Nothing on the present queue writes memory the draw queue reads.
  Render passes are planned by the scheduler from what the frontend knows: a pass stays one
  render encoder across barriers that only need buffer/memory ordering (Metal in-pass memory
  barriers); compute work between draws is hoisted before the pass when its inputs allow
  (existing `HoistDispatch` logic), otherwise the pass ends. Load/store actions come from
  attachment lifetimes (`DontCare`/memoryless only when proven overwritten or never read again).
  Resources are **hazard tracked** (Metal orders encoders that share a resource); untracked heaps
  with explicit fences/barriers were planned for P6 but are **deferred**: making everything
  untracked broke the game, and P8.5 showed the hitches were residency, not tracking. It stays
  an option for the worst frames (§8 "Open", 3B) and is a precondition of the Metal 4 model
  below. Do not switch a resource class to untracked without the explicit barriers for it.
  **API level (decided in P0, see §8 "P0 results"): Metal 3 command model first.**
  `MTLCommandQueue` with unretained references, one `MTLResidencySet` attached to the draw queue, argument buffers tier 2 where P3.4 wants them. Metal 4 (`MTL4CommandQueue`,
  allocators, argument tables) works in the Rosetta process too, but it has no hazard tracking
  at all: it needs the explicit barrier model from the first image, which is what P4 avoids. It
  is re-evaluated in P6.5 as the way to cheaper encoding, once the explicit barriers of P6.4 exist.
  Deployment target: the process stays at macOS 14.0 (the Vulkan path); `renderer_metal/` uses
  macOS 15 APIs (residency sets) without per-call `@available` (`-Wno-unguarded-availability-new`
  for that directory) and the factory refuses `BB_RENDERER=metal` below macOS 15. macOS 26 APIs
  (MetalFX frame interpolation, Metal 4) stay behind `@available`.
- **D8 Ordering semantics stay the frontend's.** EOP/EOS labels, `WRITE_DATA`, DMA, fences and
  `SignalAfterGpu` keep the "honest labels" contract of the Vulkan path: GPU writes in
  command-stream order (blit/compute writes into the shared guest buffers), CPU signals from
  completion handlers / `MTLSharedEvent`.
- **D9 Presentation.** The `CAMetalLayer` already created by `shim/window.cpp`
  (`SDL_Metal_GetLayer`); ImGui overlay and game menu via the vendored
  `imgui_impl_metal.mm`.
- **D10 Upscaling.** MetalFX temporal scaler with the existing jitter, depth and camera-motion
  vectors (`vk_camera_motion` logic, shaders via D5); native UI composition at the output
  resolution as in the Vulkan upscaler path. MetalFX frame interpolation (macOS 26) as an
  option afterwards. FSR 3/4, FSR 4.1.1 and DLSS are not ported.
- **D11 Host shaders.** The GLSL in `video_core/host_shaders/` that the Metal path needs is
  compiled with glslang → SPIR-V → SPIRV-Cross → MSL **at build time** into generated headers;
  no hand-written duplicates.
- **D12 Feature gaps are correctness work, not optional.** Tessellation (Metal: compute-generated
  factors + post-tessellation vertex function), RectList/quad lists (index or vertex expansion),
  geometry-shader draws (today skipped with MoltenVK; Metal: compute or mesh-shader emulation).
- **D13 Keep the door to an ARM64 renderer process open.** No new x86-only assembly or
  `ucontext` use in `renderer_metal/`.

## 4. Mapping: what is reused, ported or dropped

| Vulkan backend (`renderer_vulkan/`, caches) | Metal backend | How |
|---|---|---|
| `amdgpu/*`, `gpu/cp/*`, recompiler frontend + IR, `games/*`, settings | — | Shared as is |
| `vk_draw_prep`, `vk_draw_pipe`, `motion_history.h`, `scene_resolution.h`, `ui_composition.h` | — | Shared; extract neutral parts if they hold `vk::` types |
| `vk_instance` | `mtl_device` | Port: device, features, queue, residency set |
| `vk_scheduler`, `vk_runtime`, `vk_barrier_tracker`, `vk_resource_pool`, `vk_staging_buffer_pool`, `vk_constant_ring` | `mtl_scheduler`, `mtl_runtime` | Port and redesign (D7); the scheduler's neutral parts (ticks, deferred operations, signal queue) shared where the core needs them |
| `vk_rasterizer` (5k lines) | `video_core/rasterizer_core` + `mtl_draw_recorder` | Neutral logic (~3.8k lines) shared as `RasterizerCore`; recording behind a `DrawRecorder` interface (D2) |
| `vk_pipeline_cache`, `vk_graphics_pipeline`, `vk_compute_pipeline`, `vk_pipeline_common`, `vk_pipeline_serialization`, `vk_shader_util` | `mtl_pipeline_cache`, `mtl_shader` | New PSO creation on D5; cache keys reused |
| `liverpool_to_vk` | `vk_to_mtl` | Shared (Liverpool → Vulkan enums); new tables Vulkan enums → Metal (formats, blend, compare, topology, sampler) + unit test |
| `texture_cache/*`, `buffer_cache/*` | `mtl_cache_backend` | Shared through `VideoCore::CacheBackend` (D2); Vulkan code moves to `vk_cache_backend`; kernels via D11 |
| `shim/bbport_guest_memory` | `mtl_guest_memory` | D6 |
| `vk_presenter`, `vk_swapchain` | `mtl_presenter` | D9 |
| `vk_temporal_upscaler`, `host_passes/*`, `vk_camera_motion`, `vk_object_motion` | `mtl_upscaler` | D10 |
| `vk_occlusion` | visibility result buffers | Port |
| `vk_indirect_guard`, `vk_shader_hle` | `mtl_*` | Port (shaders via D11) |
| `vk_gpu_profiler`, `vk_timestamps`, `vk_gpu_labels`, `vk_breadcrumbs`, `vk_frame_capture` | `mtl_debug` | Counter sample buffers, debug groups, `MTLCaptureManager`, texture readback |
| `shim/imgui/renderer` (Vulkan) | `imgui_impl_metal` | D9 |
| `vk_dlss`, `vk_fsr4`, `fsr411/` | — | Not ported |

## 5. Phases

Each task names its owner: **O** = orchestrator (Opus, high), **S** = `porter` subagent (Sonnet),
**H** = `scout` subagent (Haiku). Exit criteria are checked by the orchestrator before the phase
counts as done.

### P0: Baseline, tooling, spikes

1. (S) Move the bench tooling into the repo: `macos/bench/bench.sh` (from
   `~/Games/Bloodborne/bench/tools/bench2.sh`, paths as variables: `BB_BENCH_DIR` defaults to
   `~/Games/Bloodborne/bench`, holding `testuser/`, `pristine-savedata/`, `tools/winid`), plus
   `census.py`, `busy*.py`, `kids.py`. Add `BB_RENDERER` passthrough to it.
2. (S) `macos/bench/imgdiff.py`: compares two screenshots (PSNR and a per-tile max error map,
   threshold argument); stdlib + `sips`/PNG decoding without new Python packages.
3. (O) Baseline: Vulkan, `BB_PROFILE=m4air` and `BB_RENDER_RES=1280x720` uncapped, three
   interleaved runs each; record FPS, worst frame, draws/frame and reference screenshots in §8.
4. (S) Spike `tools/metal_probe.mm` (x86-64, run under Rosetta): device name/families,
   `MTL4CommandQueue` availability, residency sets, `newBufferWithBytesNoCopy` alignment
   requirement with a 4 KiB- and 16 KiB-aligned host allocation, `gpuAddress`, argument buffer
   tier, max buffer length, MetalFX temporal scaler and frame interpolator support.
5. (S) Spike SPIRV-Cross: vendor it in `macos/build-deps.sh` (pinned tag, x86-64), dump 50
   SPIR-V shaders from the Vulkan shader cache (H finds where), convert to MSL with the D7
   binding layout, compile with `newLibraryWithSource`. Report failures and compile times.
6. (O) Decide Metal 4 vs. Metal 3 and the deployment target; write the outcome into §3 D7
   (done: Metal 3 first, see D7).

Exit: baseline numbers and reference images in §8; probe and SPIRV-Cross spike results written
into this file; D7 decided.

### P1: Seam and stub backend

1. (H) Inventory every call from outside `renderer_vulkan/`, `texture_cache/`, `buffer_cache/`
   into `Vulkan::Rasterizer`, `Vulkan::Presenter`, `Vulkan::Instance` and `vk::` types (file:line,
   method). Output into `docs/metal/seam_inventory.md`.
2. (O) Define `RasterizerApi`/`PresenterApi` (`video_core/rasterizer_api.h`,
   `presenter_api.h`) from the inventory; switch callers to them; `Vulkan::*` implements them.
3. (O) Guest memory and window setup behind the switch (D1); `BB_RENDERER` read once at
   startup.
4. (S) `renderer_metal/` skeleton in CMake (`.mm`, ARC, `-framework Metal QuartzCore MetalFX`),
   `mtl_device`, stub rasterizer: drops draws, executes labels/fences/DMA on the CPU in order,
   presenter clears to a colour and presents.

Exit: with `BB_RENDERER=metal` the game boots to the title screen (black/clear frames, menus
react to input, no hang); with `vulkan` image and FPS equal to the baseline (bench, 3 runs).

### P2: Memory and resources

1. (O) `mtl_guest_memory` (D6) incl. residency set and deferred frees.
2. (S) `vk_to_mtl` + unit test target `vk-to-mtl-test`: every `vk::Format` that
   `liverpool_to_vk` can produce → `MTLPixelFormat` (+ swizzle where Metal needs one), blend
   factors/ops, compare ops, stencil ops, topologies, sampler filters/address modes/border
   colours, vertex formats; unmapped values reported by the test.
3. (O design, S implementation) Cache backend seam on the Vulkan side, no behaviour change:
   `video_core/cache_backend.h` (D2), `renderer_vulkan/vk_cache_backend.*` takes the Vulkan code
   out of `buffer_cache/` and `texture_cache/`; in reviewable steps (objects, transfers, sync,
   kernels, formats), each verified on Vulkan (bench + title screenshot).
4. (S) `mtl_cache_backend`: the Metal implementation (buffers over guest memory from P2.1,
   textures, views with swizzles, samplers, blits, transfers); the caches' kernels (detiling,
   fault parsing, blit helper) through D11 (P3.3 moves ahead for them). Formats without a Metal
   texture format (P2.2: `R32G32B32*`, `A2B10G10R10` snorm/sint) need a policy here (e.g. a
   raw 32-bit-per-texel view and unpacking in the shader); views always go through
   `VkToMtl::ComposeSwizzle` (BC1 RGB, BGRA8 int/snorm need a format swizzle).
5. (O) Review of 3–4 with focus on lifetime and synchronization.

Exit: unit tests pass; Vulkan unchanged (bench, 3 runs); title screen textures uploaded and
detiled correctly on Metal (dump a few images through `mtl_debug` and compare with the Vulkan
dump).

### P3: Shaders and pipelines

1. (S) `mtl_shader`: SPIR-V → MSL with the decided binding layout; disk cache; error reporting
   with the SPIR-V hash. `PerVertexKHR` fragment inputs (pull-model interpolation): rewrite on
   the SPIR-V side before SPIRV-Cross (e.g. reconstruct the three vertex values from the
   interpolated value, the barycentrics and their screen derivatives, or emit them per
   primitive from a mesh pass); first check what the Vulkan path does with them on MoltenVK
   (its SPIRV-Cross rejects them too).
2. (S) `mtl_pipeline_cache`: render/compute PSOs from the same keys as the Vulkan cache
   (vertex input, blend, formats, sample count, depth/stencil states as separate objects),
   `MTLBinaryArchive`.
3. (S) D11 build step for host shaders.
4. (O) Review; decide the argument-buffer layout per stage (bindless tables vs. direct slots).

Exit: from boot to the clinic, the Metal backend creates as many distinct pipelines as the Vulkan
backend, with zero compile failures (log counter).

### P4: Rendering

1. (O design, S implementation) `RasterizerCore` extraction on the Vulkan side, no behaviour
   change: neutral functions move to `video_core/rasterizer_core.*`, mixed functions are split
   (hardest first reviewed: `BeginRenderingFull`, `BindTextures`, `HoistDispatch`, `DrawRecord`,
   `ResolveVertexBuffers`), `Vulkan::DrawRecorder` implements the recording interface; in
   reviewable steps, each verified on Vulkan (bench + title screenshot).
2. (O) `mtl_scheduler`/`mtl_runtime`: command buffers, encoder lifetime, pass planning (D7,
   tracked resources first), completion ticks, label/fence semantics (D8), the scheduler features
   the core needs (ticks, deferred operations, host copies, signal queue).
3. (S) `mtl_draw_recorder`: draws (indexed/non-indexed, indirect, instancing, RectList and quad
   lists, primitive restart, viewport/scissor, depth bias, stencil, blend constants, MRT),
   dispatches (direct/indirect), occlusion queries, markers. Winding and clip-space Y: decide
   once (MoltenVK flips Y in the vertex stage and inverts the winding); `VkToMtl` flags fans,
   adjacency, patch lists, point fill mode, uint8 indices and front-and-back culling as needing
   emulation.
4. (S) Tessellation path (D12).
5. (O) Integration, first image; image diff against the P0 references (title, menu, clinic).

Exit (M1): title, character menu and clinic within the diff threshold; 10 min in the clinic and
walking to the first lamp with no Metal validation errors (`MTL_DEBUG_LAYER=1`) and no hang.

### P5: Presentation, overlay, resolution, upscaling

1. (S) `mtl_presenter` with frame pacing (`BB_FPS`/vblank emulation as today), HDR off.
2. (S) ImGui overlay and game menu on `imgui_impl_metal`.
3. (O design, S implementation) Scene resolution (`BB_RENDER_RES` patch path) and UI
   composition (design `docs/metal/ui_composition_design.md`): U1 the UI composition of the
   Vulkan upscaler becomes the shared `VideoCore::UiCompositor` behind a
   `UiCompositionBackend` (Vulkan verified unchanged); U2 `Metal::Upscaler` implements it with
   Metal textures (Copy background, no temporal provider until P5.4) and the presenter shows
   its output-size display buffer. The live-resolution path's scene proxies (`SceneTargets`,
   `BB_LIVE_RES=1`) are not needed for it and come later (P7.5).
4. (O design, S implementation) MetalFX temporal upscaling with jitter, depth, camera motion
   (D10; design `docs/metal/temporal_upscaling_design.md`): the camera tracking shared
   (`VideoCore::CameraTracker`), `Metal::CameraMotion` with the D11 motion pass, the MetalFX
   scaler as the `Temporal` background of the scaled session's UI composition, MetalFX as the
   Metal backend's upscaler choice in the menus.
5. (O) `BB_PROFILE=m4air` works unchanged on Metal.

Exit: m4air profile on Metal with correct HUD and upscaled scene; bench numbers in §8.

### P6: Performance

1. (O) Metal System Trace of the clinic (`xcrun xctrace record --template 'Metal System Trace'`);
   (H) summarises the exported trace: encoders/frame, GPU time per encoder label, CPU time per
   thread.
2. (O/S) Encoder count: keep passes open across buffer-only barriers, hoist compute, merge
   adjacent passes with identical attachments.
3. (S) Load/store from attachment lifetimes; memoryless depth/MSAA where never read back.
4. (O) Untracked heaps + explicit fences/barriers from the barrier tracker.
5. (S) Parallel encoding of large passes (`MTLParallelRenderCommandEncoder` or Metal 4).
6. (S) Cheaper binding: per-draw argument data written into a ring, no per-draw allocations.
7. (O) Re-evaluate object motion vectors on Metal (vertex stores; maybe compute-based instead).

Exit (M2): bench ≥ Vulkan at identical settings (`macos/bench/m2.sh`); numbers in §8.

### P7: Gaps, stability, default

1. (S) Geometry-shader draws (D12): find them (H), implement emulation, verify the affected
   effects visually.
2. (S) MetalFX frame interpolation option (`BB_FRAME_INTERPOLATION=1`).
3. (O) 30-min soak (walk route via `BB_PAD_FILE`) on Metal, validation layer off and on; memory
   growth check.
4. (O) M3 run: 720p internal, 20 min, Air on battery and on power.
5. (S) Live-resolution path on Metal: `SceneTargets` proxies behind `ScenePasses` (only used
   without `BB_RENDER_RES`, e.g. a 1080p output with a scaled preset or `BB_LIVE_RES=1`), with
   MetalFX on the HDR scene before post (Vulkan's `Run`) for Native AA at 1080p.
6. (O) Default `BB_RENDERER=metal` on Apple in `macos/run.sh`; update `macos/HANDOFF.md`,
   README section for macOS.

Exit (M3): stable 30 FPS at 720p internal for 20 min; no device errors; default switched.

### P8: GPU time at 720p (M3; first planned as submit cost, redirected 2026-10-15)

Planned first as the kernel submit cost (P8.1/P8.2 below); the measurements showed the hot Air
GPU-bound at 720p (GPU busy 95%), so P8 now lowers GPU time:

1. (O, H) GPU time per pass at 720p on a hot Air (`BB_PASS_LABELS=1`, `tracesub.sh`/`mtltrace.py`):
   the scene passes, MetalFX, the copy/blit work, the UI; compared with 540p (which pass scales
   with pixels, which does not).
2. (O/S) Cut the largest items without changing the image beyond the §6 thresholds (or with the
   user's consent where an effect changes): MetalFX settings (quality mode, the output size, its
   internal ~2 ms blit), passes Metal does worse than Vulkan, load/store and tile memory of the
   big scene passes, the profile's effects.
3. M3 again (20 min on power and battery) — at 540p (m4air) since 2026-10-15 (§9).
5. (O) P8.5: the hitches (a frame of 83–233 ms in every 5-s window of the M3 runs, growing with
   heat): find their cause (traces of the slow frames, `BB_FRAME_STATS=1` stall lines), fix, M3
   again on battery and power. Chosen by the user after the 540p M3 runs (§9).
   Done (b13e837): the hitches were the kernel rewiring guest memory. A 10-s trace at 540p
   with the cap (`TRACE_SECONDS=10 tracesub.sh`): the GPU idled 50–106 ms with work committed
   while Metal's submission thread sat ~50 ms in `IOGPUCommandQueueSubmitCommandBuffers`; the
   wired-memory table (`metal-wired-sysmem-level-interval`) showed ~36000 events a second and
   whole guest chunks (2287, 886, 524, 296, 276 MiB) unwired and rewired 110–170 times in 10 s,
   the wired level swinging 3.5 ↔ 7.2 GiB, in 9 of the 10 largest gaps. MoltenVK at the same
   settings: 140 events a second, flat at 7.6–7.9 GiB, 3 frames over 50 ms. Tried without effect:
   a command buffer kept in flight on a second queue with the set attached, `requestResidency`
   after every commit, no `requestResidency`, untracked chunks, no per-encoder declaration.
   The fix: the chunks out of the residency set, declared per render/compute encoder only (as
   MoltenVK does with imported host memory; blits name their buffers; `BB_MTL_GUEST_IN_SET=1`
   restores the set). Trace: 98 wiring events a second, flat 7.3–7.5 GiB, frames over 50 ms
   40 → 3, p90 57 → 35 ms, submit threads' kernel time ~0. Images: title 53.3 dB, clinic vs
   the Vulkan reference 33.6 dB (worst tile at the window edge; same view). 5-min walk with
   `MTL_DEBUG_LAYER=1`: no validation errors, 30.0 FPS mean, 100% of windows at ≥ 29.5.
   M3 at 540p after the fix, on power (charging 52 → 65%, 10 min idle first;
   `m1_run.sh m3-540-power-2 metal 20 BB_PROFILE=m4air`): **met**: 20.7 min in game, mean 30.0,
   median 30.0, slowest window 27.9, 98% of windows at ≥ 29.5, worst frame 117 ms (median of the
   windows' worst 33.3 ms, 2% of windows with a frame over 50 ms); 29.8–30.0 FPS in every 2-min
   stretch, so the earlier "slowdown with heat" was the hitches growing; no device errors;
   memory: RSS −49, footprint +252, Metal +110 MiB over 20 min. On battery (right after the
   user's 10-min pause, 77 → 69%; `m3-540-battery-2`): **met**: 20.6 min in game, mean 30.0,
   median 30.0, slowest window 27.6, 97% of windows at ≥ 29.5, worst frame 183 ms (median of the
   windows' worst 50 ms, 7% of windows with a frame over 50 ms); 29.5–30.0 FPS in every 2-min
   stretch; no device errors; memory: RSS −86, footprint +241, Metal +125 MiB.
4. (S) P8.4: a faster tiling kernel (`tiling.comp`, shared): bit-identical output, measured.
   Done: one thread per row of 8 texels of a micro tile (the tile-level address once per row),
   group count from the mips' units (`TileManager::MakeDispatch`); `mtl-tiling-test` compares it
   bit for bit with the old kernel (`tests/tiling_reference.comp`) on 68 layouts as tiler and
   detiler (that comparison skipped 7 tiler cases whose reference raced: see the review fix
   below). Isolated: 32 bpp 2.0–2.4x, the 64-bpp 1280x720 tile-back 1.1–1.6x (at the time of a
   plain copy: memory-bound on a cold GPU). In the game at 540p (m4air, trace `p84-tiling-540`):
   `DispatchTiling` 0.74 → 0.53 ms a frame. Images: Metal and Vulkan clinic screenshots against
   the Vulkan reference 34.4 / 35.2 dB, the same worst tile in both (the lamp-lit wall, animated).
   Review fix (2026-10-16, 3dfa946): the old mapping (and so the new kernel's) took the logical
   pitch/height as the tiled surface's layout: tile-split slices too close (floor 720/128), the
   rows past 720 of a 720-in-768 depth buffer tiled as a phantom slice 1 over rows 704–719,
   unaligned pitches overlapping, small mips leaving their mip; 7 of 68 tiler cases raced and
   were skipped as "not deterministic". `TileManager::MakeTilingInfo` now passes the logical
   size of the linear copy and the padded size of the surface; only logical texels are copied.
   `mtl-tiling-test` checks every case against an addrlib CPU reference (unique in-bounds
   addresses, both directions byte for byte) and fails on any race or skipped check: 74 cases,
   0 failed, 0 skipped. 1280x768 render targets keep identical addresses; the game's 1280x720
   depth buffer (Depth 2D thin, tile split) now lands where addrlib puts it. Images unchanged
   (title 60 dB on both backends, clinic 35.2 / 33.6 dB against the Vulkan reference).

M3 at 540p (2026-10-15, after P8.4, 7d0e468; `m1_run.sh m3-540-power metal 20 BB_PROFILE=m4air`,
30 FPS cap, 10 min idle first; `m3stats.py`): **on power not met**: 20.6 min in game, mean 28.0,
median 27.8, slowest 5-s window 22.1, 20% of windows at ≥ 29.5 FPS, worst frame 183 ms (median of
the windows' worst 133 ms, every window has a frame over 50 ms); no device errors; memory +143 MiB
RSS over 20 min. By time: 29.6 FPS in minutes 0–4, 28.3 at 6–8, 27.4–27.7 at 10–12, 26.1–26.8 from
minute 14 on: the Air heats up on power (it charges at the same time) and the GPU slows down, at
540p as at 720p. **On battery not met either, but close**: same run right after (10 min idle
first, battery 100 → 91%): mean 29.3, median 29.6, slowest window 24.4, 59% of windows at ≥ 29.5,
worst frame 233 ms (median of the windows' worst 100 ms, again a frame over 50 ms in every
window); FPS by time 29.6 → 28.5 over the 20 minutes; no device errors, memory +129 MiB RSS.
What is left: (1) the hitches: every 5-s window has a frame of ~83–233 ms, which alone costs ~2
of the 150 frames of a window, most of the 0.7 FPS missing on battery (Vulkan's worst frames
were 35–50 ms in M2); (2) the heat on power (charging): −3.5 FPS by minute 14.

GPU time per frame (`tracesub.sh p83-*` with `BB_PASS_LABELS=1`, m4air, hot Air; traces in
`~/Games/Bloodborne/bench/traces/p83-*`): **720p 40.0 ms vs 540p 29.1 ms** (GPU busy 93% vs 81%);
30 FPS needs < 33 ms, so ~7 ms plus margin have to go at 720p. Largest items (720p / 540p):
G-buffer pass C6 `b10c4f55` 4.9 / 2.5, lighting pass C2 `8747a367` 4.8 / 2.9, MetalFX's internal
blit 2.5 / 2.3, C1 `637500e0` 2.3 / 1.3 (+ its 640x360 pass 1.2 / 0.7), MetalFX itself 2.1 / 1.8,
the present pass 1.4 / 1.3 (into the Retina drawable, 2940x1732), `DispatchTiling` (5 a frame)
1.2 / 0.7, unlabelled render passes (10 a frame) 1.2 / 0.9. Candidates without an image change:
present into an output-size drawable (~1 ms), why 5 detiling dispatches a frame (~1.2 ms), the
MetalFX blit (scaler options); then the scene passes (load/store, tile memory) against Vulkan.
Tried: the drawable at the frame's size (compositor scaling, experiment bit) in `ab.sh` at 720p:
no difference above the thermal drift (27 → 20 FPS within one run), reverted. Method for the next
steps: compare GPU ms a frame from traces (`tracesub.sh` + `mtltrace.py`, A and B in one session
with the same camera), not FPS: items of 1–2 ms are below the Air's drift.

Exit: M3 (stable 30 FPS at 540p internal, m4air, for 20 min on the Air, on power and battery).

P8.1 result (`BbFlushReason` counters, `BB_FRAME_STATS=1` line "Command buffers", m4air at 720p,
per frame): Metal 8.7 scheduler command buffers (+1 present on its own queue): signals interval
(`BB_HONEST_FLUSH_US`, 2 ms) 4.5, signal request 1.1–1.3, frame end 1.0, submit done 1.0,
presenter prepare 1.0; 2.9 of them signal-only (nothing encoded). Vulkan 8.1 (interval 3.0,
present/flip 2.0, signal request 1.1, frame end 1.0, submit done 1.0; no signal-only). So Metal
submits about as many command buffers as Vulkan (the P6 trace's 13.5–18.7 counted more than the
scheduler's); each is costlier in the hot kernel. P8.2 candidates: the signal-only commits
(encode the signal into the next command buffer; needs `Wait`/`HasUnsubmittedSignals` to compare
against the last committed tick) and a longer flush interval, both measured within one run.

P8.2 measurements (2026-10-15, m4air at 720p, hot Air): the fair M3 rerun on power (10 min
cool-down first, leak fix in) gave mean 27.1, median 28.0, 19% of windows at ≥ 29.5 (not met); the
command buffers rose to 14.8 a frame late in the run (signal interval 10.8: slower frames get
more 2-ms interval flushes). `BB_HONEST_FLUSH_US` 2000 vs 8000, 3 interleaved pairs: 8 ms halves
the command buffers (11.6 → 5.8 a frame) but costs ~6% FPS (21.7 vs 20.3 mean): the GPU waits
longer for work. A Metal System Trace at 720p on the hot Air (`tracesub.sh p82-hot720`): GPU busy
94.9% of typical frames, 19 command buffers and 216 encoders a frame, kernel submit 0.84 ms per
command buffer on the submission threads. **At 720p the hot Air is GPU-bound: the submit cost is
not what misses M3.** The levers are GPU time (MetalFX ~4 ms, the scene passes, the profile's
effects) or the target (§1). Waiting for the user's decision before P8 continues.

P8 step 2 measurements (2026-10-15, seventh session, m4air at 720p on power; traces
`p84-*`, `ab-noise-*`, `ab-fxoff-*` in `~/Games/Bloodborne/bench/traces`; new tool
`macos/bench/traceab.sh`: traces A B B A of two toggle settings in one game run, GPU busy a typical
frame per variant and the labels that differ most):
- **The metric.** The 40 ms of the per-label table double-count overlaps: MetalFX's "internal
  blit" (2.5 ms) runs concurrently with MetalFX's own compute passes (it spans Pre- to
  PostProcessing on the GPU timeline) and adds nothing. The busy union is the number to fit in
  33 ms: **35.1–35.6 ms a typical frame on a cool Air, rising to 42 within ~4 minutes of play in
  the same session** (A/A traces: 34.8 → 41.4, 34.9 → 42.2), 45 on the hot Air of P8.2. The GPU's
  clock falls with heat: a sustained 30 FPS at 720p needs ~42–45 ms of today's GPU work in 33,
  a cut of ~25%. Between traces of one session the busy also scatters by ±3 ms (pass contents
  and the passes' first-draw labels vary), so 1-ms effects need per-label comparisons.
- **Scene render passes 29.5 ms (83%)**: lighting C2 `8747a367/d92266b9` 4.6 + 0.7, G-buffer C6
  `b10c4f55` 4.3 (+ `3deaa573` 2.6, `6a833138` 2.2), C1 `637500e0` 2.3 + 2× 0.6 at 640x360,
  `61fbbf6` 1.3, `dc609f83` 1.1, … **Vulkan at 720p (MoltenVK, same build): busy 37.5 ms vs
  Metal 35.1**, C6 `b10c4f55` 4.0 vs 4.3, `3deaa573` 2.5 vs 2.6: Metal does the scene passes as
  well as Vulkan; their cost is the shaders' at 720p. Every Metal attachment loads and stores
  (`MakePassDescriptor`); P6's upper bound for dropping every depth store was +5.9% FPS (§9), and
  DontCare/memoryless need knowing that nothing reads the target later.
- **MetalFX 2.0 ms** (Pre 0.53, Mid 0.82, Post 0.68); the A/B with the upscaler off drowned in the
  thermal rise (+0.95 ms busy with it off). Options without an image change (scaler descriptor
  flags, MTL4FX) can save fractions of these 2 ms at most; the spatial scaler would change the
  image.
- **Window-size passes ~1.9 ms**: post-process into the 2940x1732 frame texture ~0.6 (one of the
  "unlabelled" render passes) and the present pass's 1:1 copy into the drawable 1.3. Rendering
  both at the output size (compositor scaling) or fusing post into present: ~1 ms. Correction
  after a closer look: the present pass runs on its own queue and overlaps other GPU work 96% of
  its time (the next frame's passes), so its 1.3 ms is mostly shared time and its own cost is
  smaller; an output-size frame texture would also scale differently from Vulkan (§9, P4.5).
  Not pursued.
- **Tiling chain 1.7 ms** (`DispatchTiling` 1.1 in 5 dispatches, `DownloadImage` 0.3, `CopyImage`
  0.27), every frame, game data of that frame (`BB_IMAGE_SYNC_LOG`, `BB_TILE_BACK_LOG`): three
  render targets are tiled back into guest memory because texel buffers read them
  (0x704e310000 1280x720 fmt 130, 0x7066420000 1280x720 fmt 97 7.8 MB, 0x70680f8000 1280x720
  fmt 37), and three GPU-written buffers are detiled into images (0x7065f50000 1280x720 fmt 100
  3.9 MB, 0x70e3518000 and 0x70e3420000 640x360 fmt 37; flags GpuDirty). Not skippable by a
  hash; the two large tiling dispatches take ~0.44 ms for 4–8 MB (~35 GB/s), so a faster tiling
  kernel could save ~0.5 ms (shared code).
- Other unlabelled render passes ~0.6 ms, hoisted kernels/dispatches 0.5.
Sum of the realistic savings without an image change: ~2 ms (window-size passes ~1, tiling
kernel ~0.5, MetalFX options ≤ 0.5) against the ~4.5 ms needed on a cool Air and ~10–12 ms on a
warm one. **The candidates do not reach the target (§5 P8 step 5): the decision about M3 (540p
m4air or 720p with a changed effect/quality) is the user's.**

### P9: GPU time: shader float semantics (2026-10-16)

The scene passes are ~83% of the GPU time and cost the same on Metal as on MoltenVK (P8 step 2),
which both translate with SPIRV-Cross. The game's shaders are compiled with stricter float rules
than the PS4's GPU applies: every float add/sub/mul/fma/div carries `NoContraction`
(`emit_spirv_floating_point.cpp`, `Decorate()`, inherited from shadPS4 without a recorded reason),
which SPIRV-Cross emits as `[[clang::optnone]]` `spvFAdd`/`spvFSub`/`spvFMul` helpers (no fusion,
folding or CSE across them; 284 of 308 fragment shaders, median 107 calls), and every library is
built with `MTLMathModeSafe`. Design and evidence: `docs/metal/float_semantics_design.md`. No
milestone changes; the Vulkan backend's SPIR-V stays bit for bit the same.

1. (O, S) P9.1 looser float rules in game fragment and compute shaders on Metal, in measured
   variants (V0 = today, also the off switch `BB_MTL_STRICT_FLOAT=1`):
   - V1: no `NoContraction` in game fragment shaders that do not export depth and in game
     compute shaders (`Shader::Profile` field set only by the Metal pipeline cache). Vertex,
     tessellation, the geometry-shader emulation (ES and GS kernels), depth-exporting fragment
     shaders and the port's own kernels keep it, so positions recomputed by different shaders
     match bit for bit (depth-equal passes, decals).
   - V2: V1 plus `MTLMathModeRelaxed` for the same shaders (keeps Inf and NaN; the recompiler's
     legacy-multiply and min/max emulation may depend on them). `mathFloatingPointFunctions` is
     already Fast by default, and SPIRV-Cross writes `precise::exp/log/rsqrt/sqrt/sin/cos`
     explicitly unless the SPIR-V carries `FPFastMathMode` NotNaN|NotInf, so V2 does not touch
     transcendentals; fast ones (and `MTLMathModeFast`) are a separate step, only if V2 is clean.
   - Caches: the variant's pipeline cache has its own tag (strict keeps `metal`, the relaxed rules
     use `metal-relaxed`), the binary archive its own file per math mode; MSL files are keyed by
     the SPIR-V hash already. `Shader::Profile` grows by the new trailing field, and the shared
     cache check accepts a `profile.bin` written before it while the field holds its default, so
     the Vulkan and the strict Metal caches stay warm.
   - Measured by interleaved boots A B B A (A = V0) with traces (`BB_PASS_LABELS=1`,
     `tracesub.sh`) at 540p and 720p, the busy union and the large passes (G-buffer `b10c4f55`,
     lighting `8747a367`, C1 `637500e0`, MetalFX); FPS by `m2.sh`; images by §6 against Vulkan
     and V0 (z-fighting, decals, edges); a 5-min walk with `MTL_DEBUG_LAYER=1`; Vulkan bench and
     screenshot.

Exit: V1/V2 kept as the default if GPU busy falls by more than the A/A spread (~±3 ms; per label
for smaller effects) and the images pass §6, otherwise recorded as measured and reverted; the
results in §8, the decision in §9; whether 720p at 30 FPS on a warm Air is in reach.

Done 2026-10-16 (4da26e9, ea029d9): **V1 is the default** (GPU busy a typical frame 24.7 → 16.5 ms
at 540p, 37.3 → 24.6 ms at 720p; FPS at 540p uncapped 33.1 → 43.6); V2 measured and left opt-in
(`BB_MTL_RELAXED_MATH=1`, within the noise of V1); numbers in §8 "P9.1 results".

### P10: Memory bandwidth: lossless texture compression (2026-10-17)

Every texture-cache image is created with `MTLTextureUsageShaderWrite` (colour) and
`MTLTextureUsagePixelFormatView` (all), inherited from the shared code's Vulkan flags (`eStorage`
"to avoid needing re-creation", `eMutableFormat`); Apple GPUs keep Private textures losslessly
compressed only without those usages. After P9.1 the remaining large passes (G-buffer C6 ~5.5 ms
at 540p, MetalFX ~1.8 ms) are more likely bound by memory traffic, which grows with resolution.
Design and evidence: `docs/metal/texture_compression_design.md`; lever 2 of
`docs/PERFORMANCE_LEVERS_2026-10-16.md`. No milestone changes; the Vulkan backend keeps its flags
(every change gated by a `BackendLimits` field only Metal sets).

1. (O, S) P10.1 lossless compression of render targets, depth and sampled images on Metal:
   - step 1 (S): microbenchmark (`tools/metal_compress_probe.mm`): GPU ms of write+sample passes
     on 4096² targets per format with and without `ShaderWrite` / `PixelFormatView`, and which
     views need `PixelFormatView` (validation layer);
   - step 2 (S): in-game inventory (`BB_IMAGE_USAGE_LOG=1`): per image the view formats and
     swizzles and whether a shader writes it; clinic, 5-min walk, Central Yharnam;
   - step 3 (O): upper bound by an env switch that drops the two usages where never needed;
     traces at 540p, 720p, native 1080p; stop if within the noise;
   - step 4 (O design, S at effort high): the policy (rules at creation, promotion on first
     need, or a learned set), off switch `BB_MTL_FULL_USAGE=1`;
   - step 5: interleaved boots A B B A with traces at 540p/720p/1080p, FPS by `m2.sh`, display
     dumps within same-build noise, a 5-min validation walk, a 20-min `memgrowth.py` walk,
     Vulkan bench and screenshot.

Exit: kept as the default if GPU busy (or the targeted passes, per label) falls by more than
the A/A spread and the images are unchanged; otherwise recorded as measured and reverted; the
results in §8, the decision in §9.

## 6. Verification

- **Build**: `bash macos/build.sh` (both backends). Unit tests: `ninja -C macos/out/gpu <target>`
  and run the binary (existing: `cp-decoder-test`, `settings-test`, `ui-composition-test`, …;
  new ones added per phase).
- **Image equality**: same save, same input script, screenshots from both backends at fixed
  points; `macos/bench/imgdiff.py`. Calibrated in P0 (two Vulkan runs of the same build): the
  clinic's camera differs a little between runs (then 21–23 dB), with the same camera two runs
  give 41–48 dB and animated spots (flame, idle character) reach a tile max of ~150. So:
  static scenes (the title screen, `bench-<name>-title.png`, menus) must pass PSNR ≥ 35 dB with
  `--tile-max 64` except one animated tile on the title screen (tile 45,34 at 2940x1732: up to
  126 between two Vulkan runs); clinic screenshots PSNR ≥ 35 dB when the camera matches (else take another
  run), otherwise inspect visually.
- **Performance**: `macos/bench/bench.sh`, always interleaved A/B runs (the Air throttles ±15%),
  3 runs per variant, report mean and worst frame.
- **Stability**: `MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=nslog` for validation runs;
  `NSZombieEnabled=YES` when chasing lifetime bugs.
- **Vulkan unchanged**: every commit that touches shared code gets a Vulkan bench + screenshot.

## 7. Risks and fallbacks

| Risk | Fallback |
|---|---|
| Metal 4 unavailable or unstable in a Rosetta process | Metal 3 (argument buffers tier 2, residency sets, parallel render encoders) |
| `newBufferWithBytesNoCopy` needs 16 KiB alignment the runtime's chunks do not have | Align chunks in `runtime_memory.c` (Apple only), or one buffer per 16 KiB-aligned superset with offsets |
| SPIRV-Cross output for some shaders wrong or slow | Patch passes on the SPIR-V side; native MSL emitter only for the hot shaders |
| Semantics of labels/fences differ subtly → hangs | Stub backend from P1 keeps the CPU-ordered fallback selectable (`BB_MTL_CPU_LABELS=1`) |
| Not faster than Vulkan after P6 | Stop and analyse with traces before P7; the Vulkan path stays the default |
| Rosetta reduced to a game subset in macOS 28 (2027) | Out of scope here; D13 keeps an ARM64 renderer process possible |

## 8. Status and results

**Resume here (2026-10-16).** Every milestone is met, and Metal is the default on Apple silicon
with macOS 15+:
- M1 (same image as Vulkan): 2026-10-14, P4.
- M2 (≥ Vulkan FPS): 2026-10-15, +10% in each profile of the M2 protocol (table below); the
  original 36 FPS at 540p uncapped was dropped (§9).
- M3 (30 FPS for 20 min at 540p, m4air, on power and battery): by eye 2026-10-16 after P8.5
  (30.0 FPS mean in both runs, 97–98% of 5-s windows at 30). Under the acceptance rule (§1):
  **power passes** (b0a3d62, `m3-pipeqos-power`: 1.27% missed slots, 98.8% of windows, worst
  frame 66.7 ms) since the missed-slot limit moved from 1% to 2% (user's decision, §9);
  **the battery run is pending** (waiting for the user). The target moved from 720p, where the
  warm Air's GPU needs 42–45 ms a frame (§9).

After P9.1 (2026-10-16) the GPU needs ~16.5 ms a frame at 540p and ~24.6 ms at 720p (cool):
720p at 30 FPS held for 20 min on a warm Air (2.29% missed slots, the rule allows 2%). Whether M3
moves back to 720p is the user's decision (§1, §9); the M3 battery run at 540p is still pending,
and the bench cache of the new default (`CUSA03173-metal-relaxed`) was filled by the 720p walk
and the clinic boots only, so a 540p fill run comes first (0 compiles in game).

How it got there, in short: P6 found the kernel's command buffer submission and residency churn
as the main cost, not encoders; held passes and hoisting (P6.2) gave +17%; P7 closed the gaps
(geometry-shader draws, frame interpolation, live resolution) and an autorelease leak; P8 showed
720p GPU-bound and P8.5 removed the last hitches (guest memory chunks out of the residency set:
the kernel had been unwiring and rewiring gigabytes whenever the GPU idled under the cap).

Open, not planned (pick with the user):
1. **Heavier scenes.** Everything above is measured in the clinic. Central Yharnam has a bench
   save (`BENCH_SAVE=pristine-savedata-yharnam`, from 2026-10-16) and no runs yet; at 540p the
   clinic already needs ~29 of the 33 ms.
2. **Stretch goals (§1).** 60 FPS presented with frame interpolation exists
   (`BB_FRAME_INTERPOLATION=1`, P7.2) but costs ~3× latency and turns a missed 33-ms slot into
   a 30 → 15 step; 1080p internal at 30 FPS is far off (9.8 FPS native).
3. **Worst frames.** Metal's (83–183 ms in the M3 runs) stay above Vulkan's (35–50 ms). What is
   left of them is the kernel submit cost per command buffer (0.66 ms cool, 1.51 hot, 13.5–18.7
   command buffers a frame vs Vulkan's 11.3). Options: (A) the Metal 4 command model
   (`MTL4CommandQueue`, reused allocators, explicit residency, no hazard tracking; needs B's
   explicit hazards), (B) P6.4 untracked resources with explicit hazards on Metal 3 (making
   everything untracked broke the game), (C) fewer command buffers a frame (P8.2: halving them
   cost ~6% FPS).
4. **Small open checks:** no reactive mask for MetalFX yet (available since macOS 14.4); the
   pipeline key sets differ (25 Vulkan keys never seen on Metal, likely format-dependent key
   fields); the RectList vertex shaders' ClipPlanes binding is numbered for another pipeline
   (shared `specialization.h`, harmless while user clip planes are off); the tiler lets padded
   rows of depth-style layouts collide with slice 1 (P8.4); one boot stopped on "Unimplemented
   PM4 type 0" (P7.5, not reproduced); the M1 walk is scripted stick input around the clinic, not
   the route to the first lamp.
5. **Levers not in this plan** (evaluation 2026-10-16, code and shader cache only, nothing
   measured in game): `docs/PERFORMANCE_LEVERS_2026-10-16.md`, ten levers ranked by estimated
   impact. First: the game's fragment/compute shaders are compiled with stricter float rules than
   the PS4's GPU (every float op `NoContraction`, which SPIRV-Cross emits as `optnone` helpers,
   plus `MTLMathModeSafe`); done as P9.1 (§5 P9): GPU time −33%, V1 the default. The other nine levers
   are unmeasured; their GPU estimates predate P9.1 and need re-ranking against the new frame.

**P9.1 results** (2026-10-16, interleaved boots with traces `p9-540-*`, `p9-720-*` in
`~/Games/Bloodborne/bench/traces`, `BB_PASS_LABELS=1 BB_FPS=uncap BB_PROFILE=m4air`, after a 15-min
cool-down; 3 of 12 traces lost to xctrace hangs, every boot's own FPS reading valid):

| GPU ms a typical frame | V0 (strict) | V1 (default) | V2 (+ Relaxed math) |
|---|---|---|---|
| 540p busy union | 24.7, 24.7 | 16.0, 17.0 | 16.2 |
| 540p lighting C2 `8747a367/d92266b9` | 2.84 | 0.38 | 0.35 |
| 540p all `8747a367` passes | 3.60 | 0.97 | 0.99 |
| 540p C1 `637500e0` (both sizes) | 1.97 | 0.38 | 0.39 |
| 540p G-buffer C6 `b10c4f55`, `3deaa573`, `6a833138`, `adf9e624` | 8.1 | 5.5 | 4.5 (labels follow each pass's first draw, so the C6 split varies between traces) |
| 540p MetalFX (3 passes) | 1.74 | 1.80 | 1.80 |
| 720p busy union | 36.0, 38.6 | 24.6 | 23.6 |
| 720p lighting C2 `8747a367/d92266b9` | 5.01 | 0.74 | 0.62 |
| 720p C1 `637500e0` (both sizes) | 3.81 | 0.66 | 0.66 |
| 720p G-buffer C6 `b10c4f55/e21e283a` | 4.00 | 0.66 | 0.87 |
| 720p MetalFX | 2.08 | 2.24 | 2.23 |
| boot FPS (bench.sh, 2 windows) 540p / 720p | 38.2, 38.0 / 27.9, 27.9 | 54.3, 54.6 / 46.0, 37.6 | 54.7, 54.8 / 41.5, 45.9 |

The fullscreen ALU passes (lighting, C1 post-processing) fall by 80–87%: the `optnone` helpers
had blocked every fusion and folding there. Images (`imgdiff.py`): clinic V1 against V0 of the
same series 45.8–48.4 dB at 540p, 37.5–37.9 dB at 720p (tiles over 64 only on the idle
character, the arm pose differs); against the Vulkan reference 36.3 dB (V0: 37.3) at 540p, 39.7
(V0: 40.7) at 720p; title 48.9/49.6 dB, only the animated tiles 45–47,34. Temporal residuals
(`temporal_check.sh`, dpan/strafe): V1 39.20/28.35 dB within the three V0 runs' 39.21–39.60 /
28.26–28.71. 5-min walk with `MTL_DEBUG_LAYER=1` on V1: no validation errors (30.0 FPS with the
layer on; 14–15 before). No z-fighting, shimmering decals or edge holes seen. Vulkan: the old
cache was kept (no clear after the `Profile` change), 33.2 FPS, clinic 49.3 dB against the
reference; a fresh-cache Vulkan boot regenerated 248 modules, 247 byte-identical to the old cache,
the one other (`42f2a521`, written at 03:01 by an earlier build) with the same 3282
`NoContraction` on its 3319 float ops. MSL (scout): 186 relaxed fragment and 31 compute files,
none with `spvF` helpers; vertex, tessellation and geometry files unchanged; the two
depth-exporting fragment shaders keep their strict SPIR-V.

M2 measurement (`macos/bench/m2.sh`, 3 runs each, interleaved V M M V V M / M V V M M V, 18 runs in
a row after a 15-min cool-down):

| Profile | Metal | Vulkan | Metal/Vulkan |
|---|---|---|---|
| m4air uncapped (540p) | 32.2 (36.4, 30.6, 29.7), worst 177 ms | 29.2 (33.0, 27.5, 27.2), worst 45 ms | +10% |
| m4air, 30 FPS cap | 29.4 (28.9, 29.6, 29.6), worst 133 ms | 26.8 (27.4, 26.1, 26.8), worst 50 ms | +10% |
| native 1080p, `BB_FPS=30` | 9.8 (9.9, 9.8, 9.8), worst 167 ms | 8.9 (9.0, 8.9, 8.9), worst 133 ms | +10% |

Where the GPU time goes at 540p (trace `m2-final`, hot machine, before P8): ~29 ms a frame (scene
passes 23.5, MetalFX ~4.2 of which ~2.2 is an internal blit or wait, UI 1).

**Measuring.**
- Within one run: `macos/bench/ab.sh` (FPS A/B of two `BB_TOGGLE_FILE` settings, phases ABBA),
  `traceab.sh` (GPU time A/B), `dumpab.sh` (display dumps A1 B1 A2 B2); runtime switches are
  experiment bits in `gpu/shim/bbport_toggles.h` (1<<40–1<<43; 1<<24 upscaler off, 1<<25 jitter
  off). Prefer this over boot-to-boot comparisons: the same build gave 11–37 FPS between boots
  (heat, WindowServer, other apps), and the bench character sometimes walks or turns after loading.
- Across boots: only the M2 protocol (`m2.sh`, interleaved, after a cool-down).
- Long runs: `m1_run.sh <name> <renderer> <minutes> [ENV=…]`, then `m3stats.py` (5-s windows)
  and `memgrowth.py` (footprint per minute).
- Traces: `tracesub.sh` (with kernel submit cost per command buffer; kills a hung xctrace after
  180 s), `mtltrace.py` (summary), `churn.sh` (wiring events a second; healthy is ~100 and a flat
  level).
- Images: `BB_PRESENT_DUMP_TRIGGER=<file> BB_DUMP_DIR=<dir>` on both backends (raw RGBA/BGRA),
  `rawdiff.py`; a scaled session compares with Vulkan with `BB_RENDER_RES=960x540 BB_FPS=30` and a
  `BB_CONFIG` ini holding `upscaler=off` (Vulkan then takes the same Copy background as Metal).
  `BB_SETTINGS` feeds only the game patches; runtime settings come from the `BB_CONFIG` ini.
- Bench runs ignore live input (`BB_PAD_FILE_ONLY=1`).

**Working rules learned.** Porters in worktrees (`isolation: worktree`); worktrees start from
`origin/main`, so push before spawning them mid-phase, or merge their uncommitted diffs with
`git apply --3way`, or run a single porter in the main checkout. Integrate with
`git cherry-pick --no-commit` and check `git diff --cached --stat` before every commit (a
cherry-pick stages everything). Porters run `macos/test.sh` as part of acceptance. Benchmark only
when no porter compiles; A/B pairs in both orders.

Checklist (orchestrator keeps it current; one line per finished task with the commit). Commit
hashes up to 2026-10-16 refer to the development history before the public repository's first
commit (kept privately, not in this repository):

- [x] P0 baseline, tooling, spikes (be3de60 bench, 0ad6c27 imgdiff, 91e6683 probe, 9dc7490
  SPIRV-Cross spike; baseline and decisions below)
- [x] P1 seam and stub backend (exit: Metal stub boots, takes input, loads the clinic, no hang;
  Vulkan bench 32.0 vs 32.3 FPS, title screens 46–63 dB against the baseline)
  - [x] P1.1 inventory `docs/metal/seam_inventory.md` (785ec47)
  - [x] P1.2 `RasterizerApi`/`PresenterApi`, Vulkan behind them (03389a5)
  - [x] P1.3 folded into P1.2/P1.4 (see §9)
  - [x] P1.4 `renderer_metal/` skeleton and stub backend (82be8cb)
- [x] P2 memory and resources (exit: textures uploaded and detiled correctly on Metal, shown by
  the display buffer and screenshot parity of P4.5)
  - [x] P2.1 guest memory chunks as no-copy Metal buffers + residency, GPU self-test (7f8d63b)
  - [x] P2.2 `vk_to_mtl` + `vk-to-mtl-test` (152 formats, 0 failures; b7beeaf)
  - [x] P2.3 CacheBackend seam (design `docs/metal/cache_backend_design.md`)
    - [x] A transfers, sync, staging, limits (8dcd71f; Vulkan 6 pairs within spread)
    - [x] B objects (e2e0cbd; Vulkan 3 pairs within spread)
    - [x] C kernels (174113c; Vulkan with R2: within spread)
    - [x] D Vulkan-only memory paths + neutral layer memory module (ae99290); the caches take
      only `CacheBackend` now
- [x] P3 shaders and pipelines (exit: from fresh caches boot→clinic Metal 220 graphics + 37
  compute pipelines vs Vulkan 231 + 37, two Metal runs differ by 13/19 keys; 0 compile failures,
  0 draws without a pipeline except the geometry-shader ones both backends skip)
  - [x] P3.1 `mtl_shader`: SPIR-V → MSL, binding map, disk cache; 405/425 cached shaders compile,
    4 `PerVertexKHR` (P3.1b) and 16 tessellation stages (P4.4) open (4f1138a)
  - [x] P3.2 `mtl_pipeline_cache`: 297 render + 39 compute pipelines from the game's keys, 0 failures,
    binary archive (55c8ad4; blend state shared with Vulkan: 384c3f9)
  - [x] P3.3 host shaders → MSL at build time, 34 shaders (29c4489)
  - [x] P3.1b `PerVertexKHR` rewrite (ab64ab1): 409/425 compile, the rest tessellation (P4.4)
  - [x] P3.4 review: direct slots kept (no stage exceeds them); argument buffers are P6.6
- [x] P4 rendering (M1 met: title 51.5 dB, clinic 37.8 dB with the same camera, character
  menu inspected; 10 min clinic with walking and the menu, `MTL_DEBUG_LAYER=1`: no validation
  error, no hang, no dropped draw)
  - [x] P4.1 RasterizerCore (design `docs/metal/rasterizer_core_design.md`): R1 class split done
    (558ed85, vk_rasterizer.cpp 5062 → 2912 lines); R2 M-easy (5b18ce0, → 2555); R3 M-medium
    (29b338f, → 1392); R4 textures/render targets (106a082, → 760); R5 pipeline cache core
    (a247db7); R6 core free of Vulkan scaffolding (285be48: GpuQueue, BackendLimits, scene
    interfaces, PipelineBase) — P4.1 done, Vulkan within spread at every step
  - [x] P4.4 tessellation (f64ec36): VS capture kernel, TCS kernel, TES post-tessellation
    function; all 17 tessellated keys of the Vulkan bench cache build
  - [x] P4.5 integration (first image, diffs, M1 runs; fixes in cbfeccf, c7c3a6a, 29ea194)
  - [x] P4.2a Metal scheduler (3650530; design `docs/metal/mtl_scheduler_design.md`)
  - [x] P2.4 Metal cache backend `Metal::Runtime` (0c22208; retire fix 08b659f)
  - [x] P4.3 Metal rasterizer: a) pipeline cache core + GpuQueue (09c3cea; Vulkan 34.8 FPS,
    title 60.6 dB); skeleton on the core + neutral guest chunk lookups (13b17ce; Vulkan 32.3 FPS,
    747 draws, title 55 dB); b) recording hooks; c) presenter shows the video-out image;
    d) RectList by a vertex shader rewrite, index expansion for quad lists/fans/uint8 (f948170,
    c7c3a6a); presenter scales in the post-process pass like Vulkan. b) cbfeccf: viewport {x, y+h, w, -h}, depth-less pipeline variants
    for passes without a depth buffer (validation layer clean), viewport limits; c) 6220bf2
- [x] P5 presentation, overlay, upscaling (exit: m4air on Metal with HUD and MetalFX, bench below)
  - [x] P5.1 frame pacing (8778b55): shared `VideoCore::FramesAhead` (BB_FRAMES_AHEAD) in both
    presenters; Metal maps BB_PRESENT_MODE to the layer's display sync like MoltenVK (Mailbox /
    Immediate: off, Fifo: on); Vulkan m4air 33.0 FPS, title 50.8 dB
  - [x] P5.2 overlay and game menu (74baa8b): `bbport_overlay` backend neutral,
    `vk_overlay` / `mtl_overlay` (imgui_impl_metal, ARC); menu and FPS counter checked on both
    backends, Metal validation layer clean
  - [x] P5.3 scene resolution and UI composition (design `docs/metal/ui_composition_design.md`):
    U1 shared `UiCompositor` (bc60548; Vulkan pairs within spread, display dumps 59.6/46.1 dB
    before/after); U2 `Metal::Upscaler` (c68e8e0): `BB_RENDER_RES=960x540` display buffers
    1920x1080 on both backends, title 53.5 dB, clinic 43.2/45.8/57.1 dB against Vulkan with the
    same camera, validation layer clean
  - [x] P5.4 MetalFX temporal upscaling (design `docs/metal/temporal_upscaling_design.md`):
    MetalFX menu provider (04aea89); shared `CameraTracker` + `Metal::CameraMotion` (5eb2d33;
    Vulkan m4air still-camera frames 55.7–56.9 dB apart as before); scaler in `Metal::Upscaler`
    (9bd579f; created on a thread at start, 0.3–1.2 s; signs +1,+1 measured; still view matches
    Vulkan FSR 3, 36.8 dB with a slightly different camera vs 40.5 between two Vulkan runs)
  - [x] P5.5 `BB_PROFILE=m4air` unchanged on Metal (the ini's `fsr3` maps to MetalFX); title
    58.3 dB vs Vulkan; 10 min `m1_run.sh` with `MTL_DEBUG_LAYER=1`: 228 steps, no validation
    error, no hang, the only draws without a pipeline are the geometry-shader ones (P7.1)
  - P5.6 moved to P7.5 (§9)
- [x] P6 performance (M2 met 2026-10-15 with the changed target: Metal +10% over Vulkan in every
  profile; P6.4 left open, see the resume point)
  - [x] P6.1 traces and diagnosis (84d5b21 labels, 89db8a1 `mtltrace.py` + submit probe,
    f892cf1 `ab.sh`/`churn.sh`): Metal 335 encoders/frame (177 render, 100 compute, 54 blit),
    GPU busy 30.5 of 57 ms traced frames, idle with work committed; wiring churn ~55k/s.
    Targets, ranked: (1) kernel submit cost / residency churn, (2) encoders: tessellation ~100,
    copy shader ~64, bloom blits 54, HUD depth flips ~20, (3) MetalFX ~3.5 ms (+9.4% off),
    (4) CPU per draw (getenv in the binding path: aba6507)
  - [x] residency: every cache buffer/texture in the set for its life, requested resident,
    guest chunks declared per encoder (053c56f, 5ac3b3a): churn 55k → 27k/s, no whole-chunk
    swings; validation clean
  - [x] P6.2 held passes + hoisting (5ac3b3a, design `docs/metal/held_pass_design.md`):
    `RenderList` (42% redundant calls dropped), copy shader and all tessellation kernels before
    their pass; in one run 31.2 vs 26.7 FPS (+17%), dumps within noise, GPU 30.5 → 26.7 ms
    a frame, validation clean, Vulkan unchanged (32.7 FPS)
  - [x] P6.2 rest: draws without depth continue an open pass with a depth buffer (9c903bc; HUD
    passes, FPS neutral); the bloom chain's `CopyBuffer` blits (~38 a frame, between passes,
    uniform uploads) stay (hoisting them needs address checks of the copies in the core)
  - [x] P6.3 measured, not built: storing no depth at all (unsafe upper bound) gains only +5.9%
    in one run; a safe version would have to learn across frames which stored depth is read
    again (a wrong guess is a broken frame). HUD load/store is ~0.36 ms GPU in total (tile memory)
  - [x] P6.6 per-draw bytes from staging blocks instead of setBytes (6505e03): FPS neutral,
    validation clean; the render list drops ~44% of calls as redundant
  - [ ] P6.4 untracked resources + explicit hazards: open. Everything untracked (measurement
    only) broke the game (it never reached the clinic); needs a design of the explicit hazards
    (image transitions, render target → sampled, copies)
  - [x] P6.5 not done: the recording thread is at ~38% of a core (not the bottleneck)
  - [x] P6.7 not done: object motion is not implemented on Metal (the core's null object); on
    Vulkan it cost ~25 ms of vertex stores and is off on Apple; nothing to re-check for M2
  - MetalFX: ~4.2 ms GPU a frame (encoders 1.8 + an internal 2.0–2.4 ms blit, gone with MetalFX
    off, not its output copy nor the depth-stencil format; most likely the wait for its Neural
    Engine stage); off +11.5% in one run (FSR 3 on Vulkan costs ~4 ms too)
  - Where it stands (cool machine, P6.2): GPU busy 88% of typical frames, 212 encoders and 13.5
    command buffers a frame, kernel submit 0.66 ms per command buffer (from ~1.5), median frame
    35 FPS; the mean is pulled down by stalls after the present (the next frame's first command
    buffers wait in the kernel submit). Hot machine: Metal 24.0/24.2 vs Vulkan 26.4/25.9
- [x] P7 gaps, stability, default: every task done; M3 not met at 720p in P7.4, met at 540p after P8
  - [x] P7.1 geometry-shader draws (design `docs/metal/geometry_shader_design.md`): the clinic has
    two GS pipelines (points → triangle-strip sprites, 8 and 40 vertices), all their draws
    indirect. Pipelines as a compute pre-pass (94ecae6), indirect draws by a prep kernel
    (3f8eb74): "Geometry shader stage unsupported" warnings 0 (were ~4.3k a bench run), ~2 GS
    draws a frame, 4.5M primitives in 1682 draws, none truncated. The effect: the clinic's
    floating dust motes (debug view `BB_GS_DEBUG=1` paints GS primitives magenta: small sprites
    spread through the room's volume, positions read back in clip space; P7.1c). In the normal
    image they are faint (GS on/off A/B within one run at noise level)
  - [x] P7.2 MetalFX frame interpolation, `BB_FRAME_INTERPOLATION=1`, off by default (7bb7b60):
    display sync paces the two drawables (Mailbox with `afterMinimumDuration`/`atTime` blocked the
    present thread: 15/9 game FPS). m4air, 3 interleaved pairs on a warm Air: on 32–48 presented
    at 16–24 game FPS, latency 92–113 ms; off 23–29 game FPS, latency 21–36 ms (`Metal present`
    line every 5 s). At 60 Hz every game frame is shown for exactly two vblanks, so a game frame
    over 33 ms costs a whole 30 → 15 step: worth it only when the game holds 30
  - [x] P7.5 live-resolution path (design `docs/metal/live_resolution_design.md`): L1 shared
    `VideoCore::SceneTargetsCore` (b219603; Vulkan dumps vs the previous build 35.7–37.5 dB at
    Native AA and Performance, same-build noise 34–38; FPS within spread); L2 `Metal::SceneTargets`
    + L3 MetalFX on the HDR scene before post (9b99b0e): Metal vs Vulkan dumps 36.1–36.4 dB at
    Native AA, 35.0–39.2 dB at Performance; presets switched live (`BB_PRESET_FILE`, the setting
    the menu writes) without a restart; reduced-size draws 48–58 of ~155 a frame (Vulkan 47–60 of
    ~145); live Performance FPS Metal 14.2/12.6 vs Vulkan 14.4/13.7 (the live path draws post and
    UI at 1080p: the scaled session stays the fast one, m4air 31.0 uncapped after the change).
    No reactive mask on Metal yet (MetalFX has one since macOS 14.4). One boot of the first live
    run stopped on "Unimplemented PM4 type 0" before the clinic (not reproduced in 6 later boots)
  - [x] Validation walk after P7.1/P7.2/P7.5: 10 min `m1_run.sh` with `MTL_DEBUG_LAYER=1` on the live
    path at Performance (proxies, MetalFX before post, GS draws): 228 steps, alive, 0 validation
    errors, 0 GS warnings, 13.5k GS draws (48.8M primitives, none truncated), no PM4 error
  - [x] P7.4 M3 run at 720p (superseded: M3 moved to 540p and met after P8) (`m1_run.sh` 20 min, `BB_PROFILE=m4air BB_RENDER_RES=1280x720`, 30 FPS cap;
    `macos/bench/m3stats.py`): **M3 not met.** On power (right after 70 min of soaks, hot):
    mean 24.9, median 24.9, slowest 5-s window 19.1, 0% of windows at ≥ 29.5 FPS, worst frame
    367 ms (median of the windows' worst 200 ms). On battery (after a pause): mean 29.0, median
    29.5, slowest window 25.5, 51% of windows at ≥ 29.5, worst 167 ms (median 100); battery
    100 → 93% in ~22 min. No device errors, no hang in either; 455/457 walk steps
  - [x] P7.3 soaks (`m1_run.sh` 30 min, m4air at 720p; memory once a minute from the macOS memory
    line, 3f63654, and `macos/bench/memgrowth.py`, a3f744f): validation off 681 steps, no errors,
    but the footprint grew ~45 MB/min (Metal allocated only ~6 MB/min); validation on: 0
    validation errors, but the footprint reached ~200 GB (~7 GB/min) and the game hung at the
    end. Cause: command buffers, their labels and encoders created as autoreleased objects on the
    recording threads, whose autorelease pool never drains: every command buffer and what it
    referenced stayed alive. Fixed (e79ba87): 10-min walks +33 MB/min, flat from minute 7
    (Vulkan on the same walk: +17 MB/min, flat from minute 4: the game's own streaming) and
    +190 MB/min with the validation layer, no errors. 30-min soak with the fix: 679 steps, no
    errors, footprint flat from minute 5 to 30 (5.77 → 5.97 GB), Metal allocated +142 MiB (its FPS
    is no measurement: on battery with a porter compiling)
  - [x] P7.6 Metal is the default on Apple silicon with macOS 15+ in `macos/run.sh`,
    `BB_RENDERER=vulkan` still selects MoltenVK (both checked by booting); HANDOFF, README
    (new macOS section) and CLAUDE.md updated (8de039e)

- [x] P8 GPU time at 720p, then M3 at 540p (2026-10-15/16; §5 P8): 720p measured (35–45 ms GPU
  a frame, scene passes as on Vulkan, ~2 ms savable without an image change; M3 moved to 540p by
  the user); P8.4 tiling kernel (0.74 → 0.53 ms a frame); P8.5 hitches fixed (guest memory out
  of the residency set, b13e837); M3 by eye: on power 30.0 FPS mean, 98% of 5-s windows at 30;
  on battery 30.0, 97%; no device errors. P8.6 (recording thread: replay thread d9619bc, pipeline
  QoS b0a3d62) for the acceptance rule: power passes at 1.27% missed slots (limit 2% since
  2026-10-16, §9)
  - [ ] M3 battery run under the acceptance rule (`IDLE_MIN=10 macos/bench/m1_run.sh
    m3-<name>-battery metal 20 BB_PROFILE=m4air`, then `m3stats.py --expect battery`): waiting
    for the user

- [x] P9 GPU time: shader float semantics (§5 P9; 2026-10-16)
  - [x] P9.1 looser float rules in game fragment/compute shaders on Metal: implementation
    (4da26e9, porter; `spirv-float-rules-test`), V1 the default (ea029d9). GPU busy −33% at both
    resolutions, images within §6, no z-fighting seen, validation walk clean, Vulkan SPIR-V
    unchanged; 720p at 30 FPS for 20 min on a warm Air now misses the M3 rule only on 2.29%
    missed slots (and the cool-down it skipped on purpose). Results below ("P9.1 results")

- [ ] P10 Memory bandwidth: lossless texture compression (§5 P10; 2026-10-17)
  - [ ] P10.1 render targets, depth and sampled images without `ShaderWrite` /
    `PixelFormatView` unless needed (`docs/metal/texture_compression_design.md`): step 1
    microbenchmark, step 2 inventory, step 3 upper bound, step 4 policy, step 5 verification

Results (filled in as measured):

| Date | Backend | Settings | FPS mean | Worst frame | Notes |
|---|---|---|---|---|---|
| 2026-10-13 | Vulkan | `BB_PROFILE=m4air`, 30 cap, 7 min | 29.6 | ~50 ms | from `macos/HANDOFF.md` |
| 2026-10-13 | Vulkan | `BB_PROFILE=m4air`, uncapped | 28.5–33 | | from `macos/HANDOFF.md` |
| 2026-10-14 | Vulkan 9dc7490 | `BB_PROFILE=m4air BB_FPS=uncap` (540p) | 31.2 (30.0–33.0) | 38.9 ms | P0.3 baseline, 3 runs, 747 draws/frame |
| 2026-10-14 | Vulkan 9dc7490 | the same + `BB_RENDER_RES=1280x720` | 22.6 (22.0–23.6) | 49.3 ms | P0.3 baseline, 3 runs, 777 draws/frame |
| 2026-10-14 | Vulkan 03389a5 (P1.2) | 540p uncapped | 30.6 (29.3–32.9) | 38.2 ms | interleaved with the baseline |
| 2026-10-14 | Vulkan 03389a5 (P1.2) | 720p uncapped | 22.7 (21.1–24.6) | 52.7 ms | interleaved with the baseline |
| 2026-10-14 | Vulkan 82be8cb (P1.4) | 540p uncapped | 32.0 (31.1–33.1) | 38.3 ms | P1 exit, interleaved with the baseline (32.3) |
| 2026-10-14 | Metal stub 82be8cb | m4air, draws dropped | 60.0 (vsync) | 17.9 ms | boots, menus, loads the clinic; no rendering |
| 2026-10-14 | Vulkan 4c10d57 | native 1080p, `BB_FPS=30` | 10.5–10.8 | 100 ms | reference for P4 (1556 draws/frame) |
| 2026-10-14 | Metal f64ec36 | native 1080p, `BB_FPS=30` | 8.3–8.7 | 200 ms | P4 done, unoptimised; 1557 draws/frame |
| 2026-10-14 | Vulkan bc60548 | m4air uncapped (540p, FSR 3) | 27.0–28.0 | 45–64 ms | U1 pairs, throttled Air (first pair 32.7) |
| 2026-10-14 | Vulkan c68e8e0 | `BB_RENDER_RES=960x540 BB_FPS=30`, FSR off | 22.7 | 50–67 ms | reference for P5.3, 1316 draws/frame |
| 2026-10-14 | Metal c68e8e0 | `BB_RENDER_RES=960x540 BB_FPS=30` | 19.4 | 83–100 ms | P5.3, HUD at 1920x1080 (19.6 before U2) |
| 2026-10-14 | Metal c68e8e0 | native 1080p, `BB_FPS=30` | 8.8 | 167 ms | unchanged by P5.1–P5.3 |
| 2026-10-14 | Vulkan 9bd579f | m4air uncapped (540p, FSR 3) | 31.8 (31.2–32.8) | 35–122 ms | P5 exit, 3 runs interleaved VM, MV, VM |
| 2026-10-14 | Metal 9bd579f | m4air uncapped (540p, MetalFX) | 24.7 (23.5–26.7) | 109–131 ms | P5 exit, the same pairs |
| 2026-10-14 | Vulkan 9bd579f | m4air, `BB_FPS=30` | 29.8 (29.6–29.9) | 50–150 ms | P5 exit, 3 runs interleaved MV, VM, MV |
| 2026-10-14 | Metal 9bd579f | m4air, `BB_FPS=30` | 21.3 (21.1–21.4) | 117–150 ms | P5 exit, the same pairs |
| 2026-10-14 | Metal 9bd579f | m4air uncapped, `BB_UPSCALER=off` | 26.3 | 105 ms | vs 22.3/23.0 with MetalFX in between (one valid off run) |
| 2026-10-14 | Metal 9bd579f | m4air, `MTL_DEBUG_LAYER=1`, 10 min walk | 14–15 | 83–467 ms | validation layer on, `m1_run.sh` |
| 2026-10-15 | Vulkan 6505e03 | m4air uncapped (540p, FSR 3) | 29.2 (27.2–33.0) | 45 ms | M2 protocol, 3 runs interleaved |
| 2026-10-15 | Metal 6505e03 | m4air uncapped (540p, MetalFX) | 32.2 (29.7–36.4) | 177 ms | M2 protocol, the same pairs |
| 2026-10-15 | Vulkan 6505e03 | m4air, `BB_FPS=30` | 26.8 (26.1–27.4) | 50 ms | M2 protocol |
| 2026-10-15 | Metal 6505e03 | m4air, `BB_FPS=30` | 29.4 (28.9–29.6) | 133 ms | M2 protocol |
| 2026-10-15 | Vulkan 6505e03 | native 1080p, `BB_FPS=30` | 8.9 (8.9–9.0) | 133 ms | M2 protocol |
| 2026-10-15 | Metal 6505e03 | native 1080p, `BB_FPS=30` | 9.8 (9.8–9.9) | 167 ms | M2 protocol |
| 2026-10-15 | Metal (P7) | m4air + `BB_RENDER_RES=1280x720`, 30 cap, 20 min walk | 24.9 power / 29.0 battery | 367 / 167 ms | P7.4, M3 at 720p not met |
| 2026-10-15 | Metal 7d0e468 | m4air, 30 cap, 20 min walk | 28.0 power / 29.3 battery | ~100 ms in every 5-s window | after P8.4; M3 at 540p not met |
| 2026-10-16 | Metal 22396a0 / 3e1352c | m4air, 30 cap, 20 min walk (`m3-540-power-2`, `m3-540-battery-2`) | 30.0 power / 30.0 battery | 117 / 183 ms | P8.5; **M3 met**, 98% / 97% of 5-s windows at 30 |
| 2026-10-16 | Metal 1af7c98 | m4air, 30 cap, 20 min walk, power (`m3-rule-power`) | 29.6 | 549 ms | first run under the M3 rule: **fail** (mean 29.62, 77.8% of windows, 5.3% missed slots, 5 frames > 100 ms); the 549-ms frame was 2 compiles (537 ms): the bench cache mixed two generations (`fs_fbe7c4b6` permutation skipped at preload, 1 stale pipeline) |
| 2026-10-16 | Metal 1af7c98 + aeb81ac | as above, cache rebuilt by a 20-min fill run (`m3-freshcache-power`) | 30.0 | 167 ms | M3 rule **fail on two checks only**: 98.0% of windows at ≥ 29.5 (rounded; below the 98% line), 1.60% missed slots (≤ 1%); 0 compiles in game, 2 frames > 100 ms (133, 167 ms at 9.2 min), every other check passes |
| 2026-10-16 | Metal d9619bc (replay thread) | m4air, 30 cap, 20 min walk, power (`m3-replay-power`) | 30.0 | 100 ms | M3 rule **fail on one check**: 2.03% missed slots (<= 1%); 98.4% of windows (now passes), every other check passes; memory as before (footprint +265 MiB, earlier runs +229-273) |
| 2026-10-16 | Metal b0a3d62 (replay thread + pipeline QoS) | m4air, 30 cap, 20 min walk, power (`m3-pipeqos-power`) | 30.0 | 66.7 ms | M3 rule **fail on one check**: 1.27% missed slots (<= 1%; the closest so far: 5.31, 1.60, 2.25, 2.03%); 98.8% of windows, every other check passes; **passes** with the limit at 2% (§9) |
| 2026-10-16 | Metal 4da26e9, V0 / V1 (P9.1) | m4air uncapped (540p), 6 interleaved boots A V1 V1 A A V1, warm Air | 33.1 (33.7, 32.9, 32.6) / 43.6 (43.8, 45.3, 41.7) | 47–61 / 31–69 ms | float rules: V1 +32% FPS; GPU busy 24.7 → 16.5 ms a typical frame (traces) |
| 2026-10-16 | Metal ea029d9 (V1 default) | m4air + `BB_RENDER_RES=1280x720`, 30 cap, 20 min walk, power, warm Air, no cool-down (`m3-p9v1-720-power`) | 30.0 | 83.3 ms | M3 rule at 720p: **fails only** 2.29% missed slots (≤ 2%) and the 10-min idle (skipped on purpose); 99.2% of 5-s windows, slowest 60 s 29.83, p99.9 50 ms, 0 compiles; before P9.1 720p ran 24.9 FPS (P7.4) |

Missed 30-FPS slots (2026-10-16, db96663; `m3-gpums-power`, `pacing2-*`, `timeline-metal` with
`tl_frames.py`): a missed slot is a flip one vblank late (50 ms, then 17 ms), not lost throughput
(`m3-gpums-power`: 29.99 FPS, 100% of windows, but 2.25% missed slots). The GPU is not the limit
(busy 75% of a late flip). The end-of-pipe flip runs in order on the draw recording thread
(`liverpool.cpp` `SignalFlip` via `RunInOrder`); in late frames the guest calls SubmitAndFlip later
(24.1 vs 19.7 ms after the previous flip) and recording reaches the flip later (11.2 vs 5.3 ms after
the call; the decoder idles 8.3 ms of it: the recording thread encodes the frame's draws, ~550
draws, p90 1160). No VO-label or WAIT_REG_MEM waits, no guest waits on the previous frame. Vulkan
shows the same pattern (5.9-6.3% missed in the clinic bench).

P8.6 recording thread (2026-10-16; user's choice: faster recording rather than a flip grace window
or an earlier flip). `sample` of a 30-s walk (`sample-metal-walk.txt`): `bb:DrawRec` runs 99% of
the time at 30 FPS. Its time: encoder creation ~25% (`ReleaseHeldPass` → `OpenPhysical` →
`renderCommandEncoderWithDescriptor` 12%), `BindResources` ~25%, `RunWriteData` → `UpdateBuffer` →
blit encoder 9% (each WRITE_DATA in a held pass ends it), `ResetBindings` 7% (linear searches of
the pass's images). (a) WRITE_DATA written by a small kernel in the hoisted compute encoder when
the pass had not touched the range (70e7fdf): every in-game write hoisted, but **slower** (toggle
A/B in one run +4.4% with it off; interleaved 30.7 vs 33.5 FPS uncapped): reverted (63432a5); the
compute encoder and fence wait in front of each pass cost more GPU time than the churn saves.
(b) Pass image membership by stamps instead of searches (3ad06d5): uncapped 32.2 vs 31.5 FPS
interleaved against 1bc281e (+2.1%, ahead in each of 3 pairs); kept. Vulkan boots and images
unchanged (run-to-run differences of the animated clinic are larger than the change's).
(c) New `sample` after 3ad06d5 (`sample-metal-walk2.txt`, 30 FPS walk): `bb:DrawRec` 98% busy;
`BindResources` 27.6% (from draws and dispatches), but mostly real work rather than repeated
lookups: `ObtainBuffer` 12.4% (guest copies `RunGuestCopy`, `SynchronizeMemoryFromImage` →
`DownloadImage`, `LayerProcessTraps`, `IsRegionGpuModified`/`LayerMirrored`), the HLE clears and
copies open encoders (3.3%); the memoized parts are small (texture-set check 2.5%, samplers
1.0%, `Transit` 1.5%). Encoder work is still the largest block: `ReleaseHeldPass` 22.2%
(`renderCommandEncoderWithDescriptor` 12.9%, the replay ~7%), WRITE_DATA blits 8.5%.
(d) No ARC `objc_retainAutorelease` per buffer binding (`(__bridge void*)NativeBuffer(...)` in
`BindBufferSet` and the draw paths, 15 sites; ~1% of the thread): interleaved uncapped
38.1/33.2/32.2 base vs 35.7/33.5/30.9, behind in 2 of 3 pairs: not kept. What is left in
`BindResources` is below what a bench can show; the lever is the encoder block.
(e) Held passes encoded on a replay thread (user's choice of direction; d9619bc): a pass
released by the next pass's begin goes to `bb:MtlReplay` (4-deep job ring: hoisted encoder
ended, render encoder made, list replayed, ended) while `bb:DrawRec` records on; everything else
that needs an encoder joins the ring first (`bb:DrawRec` waits 8-9% of its time, 2/3 of it at the
next pass's hoisted compute encoder). Uncapped: 33.9 vs 34.1 FPS (within run). At the 30 cap
three within-run A/B walks (`missab.sh`, 8 interleaved 60-s phases each): missed slots 3.52 vs
3.56%, 1.90 vs 4.10%, 1.63 vs 4.24%, together **2.35% vs 3.97%**; the tail (guest flip call ->
end-of-pipe flip) p90 10.2 vs 13.7 and 12.1 vs 15.1 ms. Validation layer clean (5-min walk),
title and clinic images as without it (the title's 2 differing tiles are the animated menu
highlight: they differ between runs of one build too), Vulkan unchanged (32.5 FPS, clinic 44.8 dB
against the reference). Kept; `BB_MTL_REPLAY_THREAD=0` or experiment bit 45 turns it off.
(f) What decides a missed slot (BB_TIMELINE of a 30-cap walk, `sample` of the guest threads,
frames CSV). Correction first: "`bb:DrawRec` 99% busy at 30 FPS" came from samples at 1 ms,
which slow the game to ~10 FPS; unperturbed, the port idles most of the frame. A frame: the
game's render thread (`GXRenderThread`) submits the whole frame in a 1-2 ms burst (~60
submissions, then SubmitAndFlip) 14-28 ms after the previous flip, depending on the scene (its
own wait `WaitPreviousFrame` rarely blocks: the frame before is retired ~16 ms after its flip);
then the port decodes and records it, the **tail**: median 4.5-5 ms, p90 10-15 ms, p99 17-19 ms,
most of it the GPU command thread idle while `bb:DrawRec` reaches the EOP. A slot is missed when
call time + tail passes ~33 ms. So both halves count: the guest's call time (the game's CPU work
under Rosetta: not ours to shorten) and the tail (recording: what (e) shortens). Missed slots are
rare events whose rate depends on where the walk goes (a 60-s phase 0.1-7%): A/B by whole runs
and by the tail, not by single pairs (the "wins in every pair" rule cannot be met this way).
(h) The long tails (`m3-replay-power`, 37k flips): the slowest 5% (tail 15.8 vs median 4.4 ms)
are frames with 806 vs 507 draws, 28.8 vs 21.7 ms GPU time and new images (0.47 vs 0.02 a
frame): 3.5x the tail for 1.6x the draws, so the recording thread likely also waits there
(open: what for). Per-flip recording columns (58ea730: `rec_busy_ms`, `gpu_wait_ms`,
`replay_wait_ms`, `find_images`, `BB_SECTIONS=1` one column per section): in those frames the
recording thread is busy 15-26 vs 5-7 ms, with no GPU waits (0.00), replay joins 2-3 vs 0.7 ms,
FindImage calls only 66-123 vs 45-51 (the memos hold), and **every section** 2.5-3x slower,
render state and dynamic state included, for 1.25x the draws: not more work but a slower
thread, it loses the performance cores to the game's threads.
(i) The frame's host threads (GPU command processing, draw preparation and recording, Metal
replay, Vulkan recorders, signals, present) at user-interactive QoS (b0a3d62;
`BB_PIPELINE_QOS=0` off). Within-run A/B by QoS override of those threads only (two runs,
mirrored): missed slots 1.58 vs 1.36% and 0.92 vs 2.62%, together **1.24 vs 1.99%**; tail median
3.77 vs 4.32 and 2.76 vs 4.97 ms (the second run: all 4 pairs), p99 13.9 vs 19.3 and 13.6 vs
17.8 ms. Uncapped 34.0 vs 33.0 FPS (one pair). Vulkan 33.1 FPS, clinic 46.4 dB against the
reference (the 7 tiles over are the player's idle animation; 3 of them differ between earlier
runs too).
(g) QoS (guest threads, and guest plus host threads, at user-interactive by override,
experiment, not kept): guest threads run at `QOS_CLASS_DEFAULT`. Across runs 2.97 vs 2.06%
missed, but four runs of one setting ranged 1.36-3.34%; within run 2.91 vs 4.23% and 2.41 vs
2.25%, and the tail did not shorten (5.05 vs 4.45 ms median): no effect shown.
`ab.sh` measured 6 windows with `BENCH_WAIT=20`, i.e. reached back into the loading screen
when loading took a few seconds longer: the "NOT IN GAME" failures in ab.sh were this, not
hangs (fixed: 2 windows, as `m1_run.sh`).
Where P8.6 stops (2026-10-16, user's decision, §9): the power run at b0a3d62 misses 1.27% of
slots and passes the rule since its limit moved to 2%; the remaining misses are a known limit.
Below 1% would need encoder creation off the recording thread's path (`ReleaseHeldPass`, (c)).

Reference screenshots: `~/Games/Bloodborne/bench/reference-vulkan-m4air-{540p,720p}-uncapped.png`
(clinic); title-screen references come with the first runs of the updated `bench.sh`.

### P0 results

Metal probe (`tools/metal_probe.mm`, x86-64 under Rosetta, M4, macOS 27.0.1):
- Families Apple7–9, Mac2, Metal3, Metal4; argument buffers tier 2; read-write textures tier 3;
  `maxBufferLength` 8.88 GiB; working set 11.8 GiB; only stage-boundary timestamp counters (no
  per-draw/dispatch counters).
- Metal 4 works in the Rosetta process (`MTL4CommandQueue`, allocator, command buffer, dispatch
  signalled through `MTLSharedEvent`: 2.1 ms cold, 0.2 ms warm).
- Residency sets work; `gpuAddress` accesses land with residency-set residency only, and are
  silently lost without residency (no error, command buffer completes).
- `newBufferWithBytesNoCopy` accepted 4 KiB-aligned memory (even unaligned pointers and lengths;
  not relied on); 4 and 8 GiB no-copy buffers over untouched `mmap` memory in 0.1–0.3 ms; 16 GiB
  fails (above `maxBufferLength`). Rosetta reports 4 KiB pages (`vm_kernel_page_size` 16 KiB).
- MetalFX temporal scaler (960x540 → 1920x1080) and frame interpolator (macOS 26) work; the
  first scaler creation takes ~1.9 s under Rosetta (create at startup).
- Parallel render encoder with sub-encoders on 2 threads: correct.
- Runtime MSL compile: ~73 ms for a 200-line fragment library + ~100 ms render PSO (same as
  native); identical sources come from Metal's cache.

SPIRV-Cross spike (`tools/spirv_msl_spike.mm`, all 425 cached SPIR-V shaders of the clinic
run, tag `vulkan-sdk-1.4.363.0`, MSL 3.1, direct slots):
- 421 convert and compile (vertex 177/177, fragment 189/193, compute 39/39, tess control 7/7,
  tess eval 9/9); 4 fragment shaders fail in SPIRV-Cross: `PerVertexKHR` inputs (pull-model
  interpolation), no option avoids it (P3.1).
- Per stage at most 12 buffers (incl. push constants at 0), 15 textures, 8 samplers: direct
  slots fit Metal's limits everywhere.
- Convert 1.5 ms mean (p95 4.8); library compile 17.7 ms mean (vertex 6, fragment 27,
  compute 29; p95 55, max 198); cold compute PSO up to 680 ms. MSL 3.2 compiles ~50% slower.
- 3 shaders use `PhysicalStorageBufferAddresses`; 377 use the recompiler's `bda_pagetable`
  buffer (address translation in the shader), which D6's `gpuAddress` could replace later.
- 174 of 177 vertex shaders have stage inputs (vertex descriptors, buffers from 30 down).

## 9. Decision log

Every deviation from the plan as first written (§0), newest last.

| Date | Change | Evidence | Affects |
|---|---|---|---|
| 2026-10-14 | Plan written | `macos/HANDOFF.md` measurements | — |
| 2026-10-14 | D7: Metal 3 command model first, Metal 4 re-evaluated in P6.5; `renderer_metal/` needs macOS 15 | P0.4 probe: both work under Rosetta; Metal 4 has no hazard tracking, P4 wants tracked resources | D7, P4, P6 |
| 2026-10-14 | D5: direct binding slots as the starting layout; `PerVertexKHR` handling added to P3.1 | P0.5 spike: 421/425 compile, limits never exceeded, 4 fail on `PerVertexKHR` | D5, P3 |
| 2026-10-14 | D6: guest memory split into buffers ≤ `maxBufferLength`; residency is mandatory for device addresses | P0.4 probe: 16 GiB no-copy fails, address writes without residency are lost silently | D6, P2.1 |
| 2026-10-14 | P1.3 folded into P1.2/P1.4: no separate step | `shim/window.cpp` already creates the `CAMetalLayer`; `bbport_guest_memory` is only used inside the Vulkan backend; videoout's Vulkan stats calls are safe without a Vulkan device; `BB_RENDERER` is read once in `RendererBackend()` | P1 |
| 2026-10-14 | §6 image thresholds calibrated; `bench.sh` adds a title-screen screenshot | two Vulkan runs: camera differs between runs (21–23 dB), same camera 41–48 dB | §6 |
| 2026-10-14 | D2/D3/§4/P2: caches shared through a `CacheBackend` interface instead of ported; Vulkan enums as the shared vocabulary; `liverpool_to_mtl` becomes `vk_to_mtl` | `docs/metal/cache_coupling.md`: 1.1k of 12.4k cache lines touch Vulkan, ~25 interface methods, the biggest obstacle (`vk::Format` in hashed keys) disappears when Vulkan enums stay shared | P2, P3.3 order, later P4 |
| 2026-10-14 | D2/§4/P4: the rasterizer's neutral logic shared as `RasterizerCore` with a `DrawRecorder` interface instead of a Metal port; P4 reordered (extraction first) | `docs/metal/rasterizer_coupling.md`: 89 of 117 functions neutral, ~3.8k of 4.8k lines; a copy would duplicate ~6.4k lines | P4 |
| 2026-10-14 | P4 order: R1–R6 (Vulkan side) before the Metal rasterizer; P2.4 before P4.3 | the core and caches had to be backend-neutral before a second backend could plug in | P4 |
| 2026-10-14 | Bench method: interleaved pairs in both orders, whole-run retry on missed input | the Air throttles from 33 to 26 FPS within ~6 runs and penalises whichever variant runs then; ~1 in 10 runs misses a Cross press while loading | §6 |
| 2026-10-14 | Guest chunk lookups of the shared buffer cache go through `VideoCore::GuestChunks` (the backend installs its provider); Metal registers its chunks with the layer's memory module | first Metal run on the core: every in-place binding missed (`BbGuestMemory::Find` is Vulkan's) and fell into the sparse arena, which Metal lacks (assertion in `CreateBuffer`) | P2.4, P4.3 |
| 2026-10-14 | RectList by a SPIR-V rewrite of the vertex shader (it evaluates the rect's three vertices and emits two triangles) instead of the tessellation path; quad lists, fans, uint8 indices by CPU index expansion | the game's final copy into the video-out buffer is a RectList draw (black screen without it); its 4 RectList vertex shaders have no vertex inputs and only write outputs, so the rewrite applies; no compute pre-pass breaks the render pass | P4.3d, P4.4 |
| 2026-10-14 | P4.4 required for M1; Metal reports tessellation support so the core hands those draws to the backend | with tessellation reported unsupported the core skipped LS/HS draws silently: fresh caches boot→clinic gave Vulkan 231 graphics pipelines, Metal 214 (17 tessellation); with the capability on, 6 tessellation pipelines and ~5 draws a frame in the clinic | P4.4, M1 |
| 2026-10-14 | The Metal presenter scales to the window in the post-process pass and copies 1:1 into the drawable, as the Vulkan presenter does | a separate scaling draw made the bench screenshots differ at every edge (title 38 dB, 141 tiles over 64) while the display buffers matched (38.9 dB, max 22); after the change 50.5 dB | P4.5, §6 |
| 2026-10-14 | P3 exit read as "every draw gets a pipeline, 0 compile failures, count within run variation" instead of an exact count | pipeline key sets vary by 13–19 keys between two runs of the same backend; 25 Vulkan keys stay unseen on Metal (open check, likely format-dependent key fields) | P3 |
| 2026-10-14 | P5.3 split into U1 (shared `UiCompositor` extracted from `TemporalUpscaler`) and U2 (Metal backend of it); `SceneTargets` not ported for P5.3, new task P5.6 | in a scaled session (`BB_RENDER_RES`) `TemporalUpscaler::OnFrameStart` never sizes the scene targets, so every `ScenePasses` query answers as `NullScenePasses`; the HUD at output size comes only from the UI composition | P5.3, P5.6 |
| 2026-10-14 | P5.4: only the camera tracking is shared (`VideoCore::CameraTracker`); the frame bookkeeping of the temporal path (jitter, reset, LDR target) is Metal's own copy of Vulkan's scaled-session rules, not extracted from `TemporalUpscaler` | its `OnFrameStart`/`OnDraw` interleave FSR 4, DLSS, the live presets and provider switching with the ~40 lines Metal needs; `Halton` moved to `motion_history.h` | P5.4 |
| 2026-10-14 | MetalFX only in scaled sessions (`BB_RENDER_RES`, m4air, outputs other than 1080p); the live-resolution path with MetalFX on the HDR scene (Native AA at 1080p) moves from P5.6 to P7.5 | the P5 exit is the m4air profile, a scaled session; the live path needs the `SceneTargets` port first | P5, P7 |
| 2026-10-14 | MetalFX is a menu provider of its own (`UpscalerMetalFx`, ini "metalfx"); on Metal a loaded FSR/TAA/DLSS choice maps to it, on Vulkan "metalfx" maps to FSR 3.1 | one `bbport.ini` serves both backends, and the m4air profile (ini `fsr3`) needs no change on Metal (P5.5) | P5.4, P5.5 |
| 2026-10-14 | MetalFX signs +1,+1 (jitter and motion vectors as given to FSR 3) | live A/B in one run (temporal_upscaling_design.md, Conventions): a flipped x jitter makes still frames oscillate (−8 dB), flipped/no x motion doubles edges while turning; y not distinguishable | P5.4 |
| 2026-10-15 | P6 order: diagnosis first (P6.1 found kernel submit cost and residency churn, not encoders, as the main cost), residency fix before P6.2; P6.3 and P6.5/P6.7 measured and not built | traces (`mtltrace.py`), submit probe, within-run A/B (`ab.sh`): Metal not GPU-bound, ~55k wiring changes/s; depth-store upper bound +5.9%; recording thread at 38% of a core | P6 |
| 2026-10-15 | Measurement method: A/B within one run (experiment bits) and the wiring rate for boot-time switches; boot-to-boot comparisons only in the M2 protocol | the same build gave 11–37 FPS between boots (heat, other load) | §6, P6 |
| 2026-10-15 | M2 target: "≥ Vulkan at identical settings" in the M2 protocol; the 36 FPS at 540p uncapped dropped (user's decision) | M2 protocol: Metal +10% over Vulkan in all three profiles, 32.2 FPS uncapped (36.4 only in the coolest run); the rest is kernel submit cost that grows with the Air's heat | §1, P6 exit, P7 |
| 2026-10-15 | P7.1: geometry-shader draws as a compute pre-pass (ES as the tessellation vertex kernel, GS rewritten on the SPIR-V level into a compute kernel writing vertex records and strip indices, indexed strip draw with a generated pass-through vertex function), not mesh shaders (design `docs/metal/geometry_shader_design.md`) | diagnostic run: 2 GS pipelines in the clinic, both point → triangle-strip sprites (8 and 40 vertices, no loops); SPIRV-Cross translates no GS; the pre-pass reuses the tessellation kernels, scratch spans and P6.2 hoisting | P7.1, D12 |
| 2026-10-15 | M3 not met after P7 (720p: 24.9 FPS mean on power, 29.0 on battery); the user chose a new phase P8 on the submit cost before M3 is measured again | P7.4 runs; P6 traces (kernel submit 0.66 → 1.51 ms per command buffer with heat, 13.5–18.7 command buffers a frame) | P8, M3 |
| 2026-10-15 | P8 redirected from the submit cost to GPU time at 720p (user's decision) | P8.2: halving the command buffers costs ~6% FPS; at 720p the hot Air's GPU is busy 95% of typical frames | P8, M3 |
| 2026-10-15 | M3 moved from 720p to 540p internal (`BB_PROFILE=m4air`), with the GPU savings that need no image change (user's decision) | P8 step 2: at 720p the GPU needs 35 ms a frame cool and 42–45 ms warm; Metal's scene passes match Vulkan's; savings without an image change ~2 ms | §1, P8, M3 |
| 2026-10-15 | P8.5: the hitches before any target change or image change (user's decision) | M3 at 540p: 29.3 FPS on battery with a ~100-ms frame in every 5-s window (most of the missing 0.7 FPS), 28.0 on power falling with heat | P8, M3 |
| 2026-10-16 | Review of the finished backend (8 findings); all reopened and worked through: M1 and M3 count as met only after their re-checks below | external review; each finding verified in the code and logs before acting | §1, §8, P2.4, P4, P8.4 |
| 2026-10-16 | M3 gets a pass/fail rule (§1 "M3 acceptance rule"), checked by `m3stats.py` from per-flip and power logs (user's choice of the recommended rule) | the 2026-10-16 "met" accepted 97–98% of windows by eye, with no limit on hitches or tail latency and no record of the power state | §1, M3 |
| 2026-10-16 | Sampler LOD bias on Metal through `MTLSamplerDescriptor.lodBias` from macOS 26; below 26 it stays dropped (logged), no shader-side bias | macOS 26 SDK has the property; the Metal path is the default only on macOS 15+, and a shader-side bias would rewrite every implicit-LOD sample of the recompiler for a shrinking set of systems | P2.4, P5 |
| 2026-10-16 | M2 is compared at identical work: the scene mip bias off on both backends (`BB_TOGGLE_FILE` SceneMipBias); the bias's cost on Metal measured separately | MoltenVK 1.4.2 (x86_64) reports `samplerMipLodBias = 0` (probe), also with `MVK_CONFIG_USE_METAL_PRIVATE_API=1`, and a within-run A/B of the bias on Vulkan is below frame noise (43–48 vs 40.6 dB), on Metal it is not (38 vs 41 dB): Vulkan never applied the bias, Metal now does | M2 |
| 2026-10-16 | Missed 30-FPS slots are compared by within-run A/B of whole runs and the tail (`missab.sh`), not by pairs; the replay thread kept on that basis | missed slots of 60-s phases range 0.1-7% with the walk's content, so single pairs flip sign for any change; the tail is per frame and the port's own part | P8.6, M3 |
| 2026-10-16 | The frame's host threads run at user-interactive QoS (b0a3d62) | per-flip sections: long tails are the recording thread running 2.5-3x slower in every part, not more work; within-run A/B of a QoS override on those threads only: 1.24 vs 1.99% missed slots, tail p99 13.6-13.9 vs 17.8-19.3 ms; raising the guest threads too showed nothing | P8.6, M3 |
| 2026-10-16 | M3 rule: missed 30-FPS slots ≤ 2% instead of ≤ 1% (user's decision) | the best run (b0a3d62, power) misses 1.27% and passes every other check; runs of one build vary by more than 1 point (1.36-3.34%), 60-s stretches 0.1-7%, so 1% vs 1.27% is noise; a miss is a 50-ms frame, not a hitch; Vulkan misses ~6% in the clinic bench; part of the misses is the game's own CPU time under Rosetta | §1, M3, `m3stats.py` |
| 2026-10-16 | The P8.6 work on the recording thread stops here: the remaining misses are a known limit, not chased further | b0a3d62 passes the rule on power; below 1% would need deeper work on encoder creation (`ReleaseHeldPass`) for a difference a player hardly notices | P8.6, M3 |
| 2026-10-16 | New phase P9 (GPU time: shader float semantics), task P9.1: no `NoContraction` in game fragment (no depth export) and compute shaders (V1), plus `MTLMathModeRelaxed` for them (V2), measured against today's rules by interleaved boots; no milestone change | code review: every float op `NoContraction` → SPIRV-Cross `optnone` helpers in 284 of 308 fragment shaders (median 107, p90 676, max 1258 calls; re-counted in the bench cache), Safe math everywhere; P8 step 2: scene passes 83% of GPU time and as costly as on MoltenVK. Corrections to the review: transcendentals are `precise::` by SPIRV-Cross (no `FPFastMathMode` flags), not by the math mode, and `mathFloatingPointFunctions` is Fast by default, so V2 changes division, sqrt and reassociation only; a new `Shader::Profile` field would wipe every pipeline cache (the shared check compares `profile.bin` byte for byte), so the check accepts the shorter old profile while the field is at its default, and the relaxed variant gets its own cache tag. Why `NoContraction` was added: not recorded (vendored shadPS4; `inst` is unused in `Decorate()`, the per-op flag of its yuzu origin was dropped) | P9, `docs/metal/float_semantics_design.md` |
| 2026-10-16 | P9.1: V1 (no `NoContraction` in game fragment shaders without depth export and in game compute shaders) is the Metal default; V2 (Relaxed math) stays opt-in (`BB_MTL_RELAXED_MATH=1`); `BB_MTL_STRICT_FLOAT=1` restores V0 | interleaved boots with traces: GPU busy 24.7 → 16.5 ms at 540p, 37.3 → 24.6 at 720p (lighting −87%, C1 −80%); FPS 540p uncapped 33.1 → 43.6; images within §6, temporal residuals within V0's range, validation clean, Vulkan SPIR-V unchanged; V2 −0.3 to −0.9 ms more, inside the noise | P9, M3 (720p at 30 on a warm Air now misses the rule only on 2.29% missed slots), Vulkan untouched |
| 2026-10-17 | New phase P10 (memory bandwidth: lossless texture compression), task P10.1: texture-cache images on Metal get `ShaderWrite` and `PixelFormatView` only when needed, gated by a `BackendLimits` field only Metal sets; ground truth by a microbenchmark and an in-game inventory before the upper bound and the policy; no milestone change | code review: every colour image `eStorage` → `ShaderWrite`, every image `eMutableFormat` → `PixelFormatView` (`image.cpp`, `mtl_runtime.mm` `CreateImage`), nothing sets compression options; Apple names both usages as preventing lossless compression; P9.1 left the G-buffer passes (~5.5 ms at 540p) as the largest item, likely bandwidth-bound | P10, `docs/metal/texture_compression_design.md`, Vulkan untouched |
