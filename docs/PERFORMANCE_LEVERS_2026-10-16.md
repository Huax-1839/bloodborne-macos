# Performance levers not in the plan (evaluation 2026-10-16)

Status: evaluation, 2026-10-16, on `main` at 22c78c5. Basis: a code review of the Metal backend,
the shared recompiler and caches, the runtime and the scripts; the bench user's Metal shader cache
(`~/Games/Bloodborne/bench/testuser/cache/CUSA03173/metal`, 1066 MSL files); the plan
(`docs/METAL_BACKEND_PLAN.md`), `macos/HANDOFF.md` and the other docs in `docs/`. **Nothing here
was measured in the game**: the impacts are estimates from the code evidence, to be confirmed by
traces and runs before anything is kept. Levers that the plan or the older docs already cover are
listed at the end and not repeated.

## Where the time goes today (from the plan)

- GPU at 540p (m4air, clinic): ~29 ms a frame on a hot Air, of which the scene render passes are
  23.5 ms (83%), MetalFX ~2 ms of its own, the tiling chain ~0.5–1.2 ms, UI ~1 ms (§5 P8, §8).
- GPU at 720p: 35 ms busy a frame on a cool Air, 42 within ~4 minutes of play, 45 hot. 30 FPS
  needs < 33 ms, so 720p needs a cut of ~25% when warm (§5 P8 step 2).
- Metal's scene passes cost the same as MoltenVK's at the same settings: "their cost is the
  shaders'" (§5 P8 step 2).
- Heat: the GPU slows 20–25% within minutes; on power the Air charges at the same time and lost
  3.5 FPS by minute 14 in the 2026-10-15 M3 run (§5 P8).
- Pacing: 1.27% missed 30-FPS slots on power at b0a3d62; the misses come from the game's own CPU
  time plus the recording tail (§8 "P8.6").

## Ranking

| # | Lever | Helps with | Estimated impact | Effort |
|---|---|---|---|---|
| 1 | Float semantics of game fragment/compute shaders | GPU time of every scene pass (both backends) | high: plausibly several ms a frame at 540p, more at 720p | small |
| 2 | Lossless compression of render targets and depth | bandwidth, DRAM power | **measured (P10.1): −1.7 ms at 540p, −3.3 ms at 720p, −5.3 ms at 1080p**; power not measured | medium |
| 3 | CPU vs GPU power split, then less CPU power | sustained GPU clock on the fanless Air | potentially large (heat costs 20–25%); unknown until measured | small to measure |
| 4 | Asynchronous / parallel pipeline compilation | 100–500 ms hitches on first visits | high for smoothness, none on mean FPS | medium |
| 5 | Game settings the m4air profile leaves at full quality | GPU time | ~0.5–3 ms each; visible changes need the user's consent | small |
| 6 | GPU-time driven dynamic resolution | holding 30 FPS in heavy scenes and with heat | medium–high | high |
| 7 | Fullscreen and macOS Game Mode (app bundle) | missed slots, background load, compositor | small–medium | small |
| 8 | Batched residency-set commits | slow frames with new resources | small | small |
| 9 | PGO (and compiler flags) on macOS | recording tail (missed slots) | small (~5% of recording) | medium |
| 10 | G-buffer in tile memory; variable rasterization rate | bandwidth, pixel work | possibly large | very high (long term) |

Suggested order: 1 (one afternoon to prove or drop; design in
`docs/metal/float_semantics_design.md`), the frame capture of 2, the power measurement of 3, then
4 before the heavier scenes (Central Yharnam), 5 alongside as trace A/Bs.

## 1. Float semantics stricter than the PS4 GPU

Evidence:
- `gpu/shadps4/shader_recompiler/backend/spirv/emit_spirv_floating_point.cpp:9-11`: `Decorate()`
  puts `NoContraction` on every FPAdd/FSub/FMul/FFma/FDiv (32 and 64 bit), unconditionally.
- SPIRV-Cross (vendored, tag `vulkan-sdk-1.4.363.0`) emits every such op through a helper the
  Metal compiler must not optimise: `spirv_msl.cpp:6424-6452` (`[[clang::optnone]]`
  `spvFAdd`/`spvFSub`/`spvFMul`, built on `fma()`), selected at `spirv_msl.cpp:9779-9793` by
  `has_legacy_nocontract` (`spirv_glsl.cpp:21001-21003`, `21027`).
- The bench cache: 284 of 308 fragment shaders contain the helpers, median 107 calls a shader,
  p90 676, max 1258 (45,790 `spvFMul`, 22,292 `spvFAdd`, 2,368 `spvFSub`, 280 each of the matrix
  helpers over all fragment shaders); vertex shaders median 57. No mul+add fusion, no constant
  folding, no common-subexpression elimination across these ops.
- `renderer_metal/mtl_shader.mm:817-821` and `mtl_geometry.mm:476-480`: every library is compiled
  with `MTLMathModeSafe` (below macOS 15 `fastMathEnabled = NO`): IEEE division and square root,
  precise transcendentals, no reassociation, more precise than GCN's own approximate
  `v_rcp`/`v_rsq`/`v_exp`/`v_log`/`v_sin`.
- MoltenVK translates with SPIRV-Cross too, which fits the finding that both backends spend the
  same time in the scene passes.

Proposal: keep `NoContraction` and Safe math wherever positions are computed (vertex,
tessellation, the geometry-shader emulation kernels, the port's own kernels, fragment shaders
that write depth), so passes that recompute a position in different shaders still match bit for
bit; relax the game's fragment and compute shaders: V1 without `NoContraction`, V2 additionally
with `MTLMathModeRelaxed` (keeps Inf/NaN) and fast built-in functions. Metal profile only, with an
off switch; Vulkan unchanged. Not the blanket fast-math that
`PERFORMANCE_REPORT_M4_AIR_2026-10-13.md:115` rejects: staged, per stage, measured per pass.

Impact: unmeasured. If the scene passes are bound by ALU work, a cut of 10–25% of their time is
plausible (2–6 ms at 540p); this is the most likely route to 720p internal. Risk: depth-equal
passes that rely on identical positions (kept strict), NaN-dependent emulation (Relaxed keeps
NaN; Fast only as a separate step). Design, measurement and decision rules:
`docs/metal/float_semantics_design.md`.

## 2. Lossless compression switched off on every render target

Evidence:
- `gpu/shadps4/video_core/texture_cache/image.cpp:18-43`: every non-block colour image gets
  `eStorage` ("This sacrifices a bit of performance but is less work"), every image
  `eSampled`, colour or depth attachment usage as fits.
- `image.cpp:111-112`: every cache image gets `eMutableFormat | eExtendedUsage`.
- `renderer_metal/mtl_runtime.mm:1001-1013`: Private storage; `eStorage` becomes
  `MTLTextureUsageShaderWrite` (colour, single sample), `eMutableFormat` becomes
  `MTLTextureUsagePixelFormatView` (all, depth included).
- `mtl_scene_targets.mm:319-326` drops storage for the live path's proxies so that "a texture
  that is only a render target keeps the GPU's lossless compression", but still sets
  `eMutableFormat`. MetalFX's output (the UI colour) also has `PixelFormatView`
  (`mtl_upscaler.mm:1096-1097`).
- Apple GPUs compress private textures losslessly; Apple's guidance is that `ShaderWrite` and
  `PixelFormatView` (other than sRGB-only view changes) can keep a texture from being compressed.
  Nothing in the backend sets `allowGPUOptimizedContents`, `compressionType` or calls
  `optimizeContentsForGPUAccess`.

Proposal: first a GPU frame capture of a clinic frame (Xcode's Metal debugger shows each
texture's compression) to confirm which targets are uncompressed and why (~1 hour). Then an
upper-bound experiment (both usages off for render targets; count broken views and validation
errors; trace GPU ms), then the real change: add `ShaderWrite` / `PixelFormatView` only when a
storage write or a view in another (non-sRGB-variant) format is actually requested, recreating
the image on first need (shared texture cache code: Vulkan keeps its flags).

Impact: bandwidth estimate for 540p (G-buffer, lighting, post chain, 1080p output and UI):
~150–250 MB of render-target traffic a frame, of which compression typically saves a third to a
half: ~0.5–2 ms, more at 720p/1080p, plus less DRAM power on unified memory (thermal headroom,
see 3).

**Measured: done as P10.1 (2026-10-17), kept as the Metal default.** Either usage costs the
compression of a colour target on the M4 (RGBA16F write + read ×2.2 in a microbenchmark); depth
keeps it. 80–84% of the cache images need neither usage; the rest is promoted on first need
(`docs/metal/texture_compression_design.md`). GPU busy a typical frame: 16.6 → 14.9 ms at 540p
(−10%), 21.5 → 18.2 ms at 720p (−15%), 43.4 → 38.1 ms at native 1080p (−12%), mostly in the
fullscreen post and lighting passes; the G-buffer gains 5–10%. Images unchanged. GPU power not
measured (needs `sudo powermetrics`).

## 3. Thermal budget: CPU vs GPU power never measured

Status (2026-10-17): in the plan as P11 (plan §5 P11), design in
`docs/metal/power_budget_design.md`; results in plan §8 "P11 results" as measured.

Evidence:
- The Air is fanless; CPU and GPU share one thermal budget. The GPU's frame time rises 20–25%
  with heat (§5 P8 step 2), and charging during a run cost 3.5 FPS by minute 14.
- `macos/bench/m1_run.sh:16-28`: the power log holds `pmset` data only (source, charge, Low
  Power Mode); no watts, frequencies or thermal pressure.
- CPU work that could be cut once measured:
  - `gpu/shadps4/video_core/page_manager.cpp:535-539` and
    `gpu/shadps4/video_core/buffer_cache/region_manager.h:28-30`: macOS lacks
    `PTHREAD_ADAPTIVE_MUTEX_INITIALIZER_NP`, so both use `Common::SpinLock`
    (`gpu/shadps4/common/spin_lock.cpp:36-40`: unbounded `pause`, no yield). It also has no
    priority donation: a default-QoS guest thread holding it on an efficiency core keeps a
    user-interactive host thread spinning (a possible part of the slow-thread long tails, §8
    "P8.6 (h)"). `os_unfair_lock` spins adaptively and donates priority.
  - `gpu/shadps4/core/libraries/kernel/equeue.cpp:282-310`: yields in a loop while a
    high-resolution timer under 1.2 ms (`:31`) is pending, indefinitely at timeout 0
    (guest-driven).
  - `src/runtime_kernel.c:228-245` (`pthread_once` waiters yield),
    `gpu/shim/bbport_copy.cpp:94,112` (yield while copies finish).
  - `renderer_metal/mtl_scheduler.mm:381,433`: bounded spins (4096/2048 pauses), then a futex:
    fine.

Proposal: record `sudo powermetrics --samplers cpu_power,gpu_power,thermal -i 1000` next to an
`m1_run.sh` walk (CPU/GPU watts, GPU frequency, thermal pressure per second) and add it to the
power log; then cut the CPU share where it is large (locks above, polling, thread count) and
check the GPU frequency over a 20-min run. Outside the code: play on battery or with charging
paused (charging heats the Air), and on a hard, open surface.

Impact: unknown until measured; the ceiling is the 20–25% the GPU loses to heat, scaled by the
CPU's share of the power.

## 4. Pipeline compiles block the game

Evidence:
- `renderer_metal/mtl_pso_cache.mm:549` (render), `:635`, `:700` (compute): synchronous
  `newRenderPipelineStateWithDescriptor:options:reflection:error:` on the calling (GPU) thread.
- `mtl_pipeline_cache.mm:124`: `vertex_input_dynamic_state = false`, so `AsyncSkippable`
  (`pipeline_cache_core.cpp:598`) returns false: the asynchronous path (`BB_ASYNC_PIPELINES`)
  never runs on Metal.
- `mtl_pipeline_cache.mm:185`: the boot warm-up (`WarmUp` over `ForEachBlob`) runs on one thread.
- The first M3 rule run's 549-ms frame was two compiles (537 ms; plan §8 results). P0: MSL library
  compile 17.7 ms mean (p95 55, max 198), render PSO ~100 ms, cold compute PSO up to 680 ms.

Proposal: (a) warm-up on several threads (Metal compiles are thread-safe); (b) compile new
pipelines in the background and skip their draws for the few frames until ready (a brief visible
gap on first appearance: the user's decision, plan §0); (c) compile the MSL library as soon as a
new shader is seen, separate from the PSO. Measure with the logged slow compiles (aeb81ac) on a
first visit of Central Yharnam with an empty cache.

Impact: none on mean FPS with a warm cache; removes 100–500 ms hitches on every first visit of an
area, and shortens the boot of a fresh cache.

## 5. Game settings left at full quality in m4air

Evidence (`gpu/shim/bbport_settings.h:30-40`, `scripts/patches.py:31-42,72`, `macos/run.sh:42-45`,
`patches/Bloodborne.xml`):
- `effect_game_aa` 1 in m4air: the game's own anti-aliasing runs before MetalFX, which does its
  own; temporal upscalers generally want an un-antialiased input, so turning it off may also be
  neutral or better for the image.
- `effect_chromatic_aberration` 1 in m4air.
- `model_lod` 1 in m4air; 2 (lowest) unused.
- Not applied by any profile (reachable through `BB_PATCHES`, `patches.py:351`): "Light Grid"
  patches (`Bloodborne.xml:1402-1420`, "lowering light grid draw calls"; their note says to use
  the version matching the window resolution; the lighting pass is the largest single GPU item,
  2.9 ms at 540p), "Performance Patch (perf increase)" (`:20`, debug parameters, "will probably
  affect some visuals"), "Optimal 1080p" (`:1426`).

Proposal: one trace A/B per setting (GPU ms per pass label) with an image comparison; visible
changes go to the user for a decision (plan §0, dropping an effect the game shows).

Impact: ~0.5–3 ms each, cheap to test.

## 6. GPU-time driven dynamic resolution

Evidence:
- The menu offers "Auto (based on GPU)" for the live resolution
  (`gpu/shim/bbport_overlay.cpp:501-508`), but nothing reads it except the menu and a restart
  check; the comment at `bbport_settings.h:80-81` is stale.
- MetalFX already gets `inputContentWidth/Height` every frame (`mtl_upscaler.mm:853-854`), but the
  scaler is created for one input size (`:179-180`) and keyed by size (`:762`, `:775`);
  `inputContentPropertiesEnabled` and `inputContentMinScale/MaxScale` are not set, which would let
  one scaler cover a range of input sizes.
- The scaled session (`BB_RENDER_RES`, m4air) fixes the game's render-target sizes at boot; the
  live-resolution path switches presets at run time but costs more (post and UI at 1080p: live
  Performance 14.2 FPS vs m4air 31.0, plan §8 P7.5).

Proposal: a controller that picks the scale from the GPU time of recent frames, on one MetalFX
scaler with input content properties. Either make the live path as cheap as the scaled session
first, or let the scaled session allocate its targets at the largest size and render a variable
sub-rectangle (needs the game's viewports and screen-space shaders to follow).

Impact: turns heat and heavy scenes into a lower resolution instead of missed frames, and allows
more than 540p while the Air is cool.

## 7. Fullscreen and Game Mode

Evidence:
- No app bundle, no `Info.plist`, no `LSApplicationCategoryType` anywhere; `macos/run.sh:90-91`
  execs the plain `macos/out/bb-probe`. macOS Game Mode (macOS 14+) only starts for an app whose
  bundle declares a games category, in fullscreen: highest CPU and GPU priority for the game,
  background work lowered, doubled Bluetooth sampling rate for controllers.
- `gpu/shim/window.cpp:81-82`: `BB_FULLSCREEN=1` is honoured at creation; `run.sh` never sets
  it. Windowed default 1920x1080 points (`src/probe.c:601`), a 2940x1732 drawable that the window
  server composites every refresh.
- Presenter: BGRA8, `framebufferOnly` YES, three drawables, opaque (SDL); nothing that rules out
  direct-to-display presentation in fullscreen.

Proposal: a minimal `.app` wrapper (generated by `macos/build.sh` into `macos/out/`) with a games
category that execs `bb-probe` with the same arguments, and `BB_FULLSCREEN=1` in the m4air
profile. Check Game Mode in the menu bar and direct presentation with the Metal Performance HUD
(`MTL_HUD_ENABLED=1`); measure missed slots (`m3stats.py`) and power (3).

Impact: small to medium: less variance from other apps and the window server, a little GPU time
and power.

## 8. Residency-set commits per resource

Evidence: `renderer_metal/mtl_device_impl.h:61-76` calls `[residency commit]` after every
`addAllocation`/`removeAllocation`, under `residency_mutex`, on the GPU thread (creation
`mtl_runtime.mm:918-920`, `1023-1025`; removal through deferred operations, `:970`, `:1052`). The
slowest 5% of frames create 0.47 new images a frame against 0.02 (plan §8 "P8.6 (h)"); streaming
scenes create more.

Proposal: mark the set dirty and commit once before the next command buffer is committed (every
new resource must be in a committed set before a command buffer that uses it is committed;
removals already wait for retirement). Measure the per-flip recording columns (`rec_busy_ms`) of
the slow frames, best in Central Yharnam.

Impact: small; cheap.

## 9. PGO and compiler flags on macOS

Evidence: `macos/build.sh:28` builds with LTO off and PGO off (RelWithDebInfo, `-O2`, baseline
x86-64; no `-march`); `gpu/CMakeLists.txt:24-46` already has PGO generate/use. On Linux PGO cut
recording time per draw by 4.8% (`docs/parallel_gpu.md:244-252`). LTO on macOS was measured and
not worth it (`macos/HANDOFF.md`). Under Rosetta, fewer and better-placed x86 instructions mean
less translated code on the recording thread, whose tail decides missed slots.

Proposal: a PGO build trained on the m4air bench walk, compared by the recording tail
(`missab.sh`-style whole runs) and FPS. Separately, `-march=x86-64-v3` for the host code
(`run.sh:87` sets `ROSETTA_ADVERTISE_AVX=1`); whether translated AVX2 beats SSE is open.

Impact: small (~5% of recording time).

## 10. Long term: tile memory and variable rasterization rate

- Keeping the G-buffer in tile memory (merge the G-buffer and lighting passes, read the G-buffer
  by framebuffer fetch, memoryless attachments) would remove most of the G-buffer's memory
  traffic, but needs rewriting the game's passes and proof that nothing else reads the G-buffer
  (SSAO, SSR and post effects do on most deferred renderers). The plan's load/store work (P6.3)
  measured only the upper bound of dropping depth stores (+5.9%).
- Variable rasterization rate (`MTLRasterizationRateMap`) would shade the screen's edges at a
  lower rate; it changes the image and every pass of the frame would have to use the same map.

Impact: possibly large on bandwidth; effort very high. Only after 1–6.

## Checked and ruled out

- Page-table address translation in shaders (`bda_pagetable`): 1060 of the 1066 cached MSL files
  do not reference it; it serves only the DMA path (off by default,
  `gpu/shim/core/emulator_settings.h:57`) and paged buffers of sharps ≥ 64 MiB
  (`shader_recompiler/resource.h:109-115`).
- Write-fault traps: in guest-in-place mode GPU tracking uses a software write watch
  (`page_manager.cpp:700-712`); the remaining traps are rare (`bench-m3-pipeqos-power.log`: 32
  windows with faults, median 1, max 58).
- The TLS rewrite: a plain gs-relative load at ~17,000 sites (`src/probe.c:636-652`), no trap or
  call.
- Fragment discards: 42 of 308 cached fragment shaders contain `discard_fragment` (genuine alpha
  tests), so the GPU's hidden-surface removal works for the rest.
- Invariance: no `Invariant` decoration emitted, `preserveInvariance` not set.
- MetalFX's texture usage: compared with the scaler's required usages in code
  (`mtl_upscaler.mm:804-824`, `984-1015`).

## Already in the plan or the older docs (not repeated here)

Metal 4 command model, untracked resources with explicit hazards (P6.4), fewer command buffers
(P8.2), load/store and memoryless attachments (P6.3), MetalFX options and reactive mask, present
at output size, the tiling kernel (P8.4), the ARM64 renderer process
(`docs/ARM64_PORT_ASSESSMENT_2026-10-13.md`), frame interpolation (P7.2), QoS and the replay
thread (P8.6). One of them deserves a second look: parallel encoding (P6.5) was set aside because
the recording thread was not the bottleneck at the time (~38% of a core), but P8.6 later showed
that the recording tail decides the missed 30-FPS slots.
