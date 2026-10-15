# Bloodborne on the MacBook Air M4: Performance Report

As of 13 October 2026. Basis: the working state of that day, including the macOS adjustments not yet committed then.

**Result:** The largest plausible lever is in the render flow: fewer interruptions of related render passes, less unnecessary synchronization and lower cost per draw. A lower resolution already helps, but according to the documented measurements it is not enough on its own for a stable 30 FPS. A fully native ARM64 port is a separate architecture project. For the existing port, I would first choose **a stable 30 FPS at 720p internal resolution as the development goal**. Whether this is achievable must first be shown by correct measurements and prototypes; 60 FPS cannot be promised credibly at present.

Only reading was done and this report was written. No implementation, configuration change, compilation or new game measurement was performed. The recommendations are prioritized by expected relevance, not by an FPS gain that has already been demonstrated.

**1. What "native" means here**

The current path is:

```text
Bloodborne game code (x86-64) + bbport runtime/renderer (x86-64)
                         ↓ Rosetta 2
                  Apple M4 CPU

PS4 graphics commands / GCN shaders
          ↓ bbport: Vulkan / SPIR-V
          ↓ MoltenVK: Metal / Metal Shading Language
                  Apple M4 GPU
```

This is a local macOS application with graphics computation on the Apple GPU. The game CPU side and the project's own renderer, however, are not ARM64 binaries. The build script explicitly sets `-arch x86_64` and `CMAKE_OSX_ARCHITECTURES=x86_64`; the existing CMake cache confirms this. [Build script](../macos/build.sh#L13), [Build configuration](../macos/out/gpu/CMakeCache.txt#L203).

Simply switching to ARM64 does not work: the loaded game remains x86-64, and the runtime assumes x86 register state, among other things. Under Rosetta, Apple does not support a mix of ARM64 and x86-64 modules within the same process. A native Metal renderer would also not automatically remove the CPU translation. [Platform adjustments](../gpu/shim/bbport_platform.h#L40), [Apple documentation on the process architecture](https://developer.apple.com/documentation/apple-silicon/about-the-rosetta-translation-environment?changes=_7).

According to the handoff document, the existing Clinic measurements refer to an M4 with **10 GPU cores and 16 GB of unified memory**. The values are not directly transferable to a variant with 8 GPU cores. For the 13-inch model, Apple lists both GPU variants and 120 GB/s memory bandwidth. CPU and GPU share memory and bandwidth; the log line "16384 MiB VRAM" does not mean additional dedicated graphics memory here. The Air is fanless, so sustained performance has to be considered separately. [Local hardware reference](../macos/HANDOFF.md#L8), [Apple: technical specifications](https://support.apple.com/en-us/122209), [Apple: fanless design](https://www.apple.com/newsroom/2025/03/apple-introduces-the-new-macbook-air-with-the-m4-chip-and-a-sky-blue-color/).

**2. What the existing numbers actually say**

The following table takes the values from the local handoff document. They were not re-measured for this report; complete raw data, identical start conditions and thermal comparability are therefore not verified. [Measurement notes](../macos/HANDOFF.md#L13).

| Documented configuration in the Clinic | FPS, approximately | Derived time per frame |
|---|---:|---:|
| Original state, 1080p | 4.5 | 222 ms |
| Argument buffers off and GPU labels off, 1080p | 7.7–8.5 | 118–130 ms |
| Additionally 1280 × 720 internal | 11 | 91 ms |
| Additionally shadows, motion blur, DoF and SSAO off | 14 | 71 ms |
| Separate trial with 320 × 180 internal; other settings not fully documented | 18 | 56 ms |

30 FPS requires at most 33.3 ms per frame, 60 FPS at most 16.7 ms. Starting from 14 FPS, about **53% less frame time** would still be required for 30 FPS. The 320 × 180 trial is also clearly above the 30 FPS budget. This points to considerable cost that does not disappear with the pixel count alone.

The document also mentions about 27 render interruptions per frame caused by `FlushBarriers`, about 62 hoisted compute dispatches without any FPS gain so far, and a test without draws at about 40 FPS. These statements are useful hints, but not new measurements. The test without draws in particular is not a reliable CPU upper bound of the complete game. [Further measurement notes](../macos/HANDOFF.md#L23).

The existing `run7.log` to `run10.log` contain only about 5–18 draws per frame in their FPS samples. No representative Clinic or combat benchmark can be derived from them. The values of up to about 95 FPS in `run10.log` therefore do not automatically contradict the Clinic values.

**3. Priorities**

| Priority | Measure | Expected benefit | Effort / uncertainty |
|---|---|---|---|
| P0 | Correct the GPU measurement and define reference runs | Prevents optimizing against the wrong bottlenecks | Small to medium; measurement problem is proven |
| P1 | Avoid unnecessary render interruptions caused by barriers | Largest plausible lever for GPU time and bandwidth | Medium to high; synchronization correctness is decisive |
| P1 | Tune command buffer segmentation for Apple GPUs | Fewer artificial pass boundaries | Small A/B trials, medium implementation effort |
| P1 | Check the 16× filter raise and effect costs | Lower texture and pixel costs | Small trials; quality trade-off |
| P2 | Adapt memory duplicates and thread count to unified memory/M4 | Fewer copies, less CPU work and lower energy use | Medium; actual run-time costs are missing |
| P2 | Check release/LTO, pipeline cache and shader hotspots | CPU efficiency and fewer stutters | Small to medium; rather supplementary |
| P3 | MetalFX, own Metal path or ARM64 renderer process | Strategic potential | High to very high; gain is open |

**4. P0: The GPU profiler is currently not a reliable reference**

There is a concrete error in the measurement basis: `GpuProfiler` creates four ranges of 4096 queries each in **one** query pool. This gives 16384 timestamps. In the existing log, Metal rejects the resulting 131072-byte buffer and names 32768 bytes as the upper limit. MoltenVK then explicitly falls back to emulated behavior. [Pool size](../gpu/shadps4/video_core/renderer_vulkan/vk_gpu_profiler.h#L64), [Pool creation](../gpu/shadps4/video_core/renderer_vulkan/vk_gpu_profiler.cpp#L22), error message.

The subsequent outputs fit this: almost the entire time is attributed to "between submissions: GPU idle", while the actual passes appear with 0 ms. One must not conclude from this that the graphics chip is largely idle. The current Apple-specific shift of the timestamp assignment does not solve the oversized pool creation. Profiler output, [Apple assignment](../gpu/shadps4/video_core/renderer_vulkan/vk_gpu_profiler.cpp#L84).

In addition, `WriteTimestamp()` itself calls `EndRendering()`. The pass marking already tries to measure only at pass changes; nevertheless, additional interruptions caused by other markers and transfers have to be checked. The profiler can therefore influence exactly the pass structure under investigation. [Timestamp recording](../gpu/shadps4/video_core/renderer_vulkan/vk_gpu_profiler.cpp#L35), [Pass marking](../gpu/shadps4/video_core/renderer_vulkan/vk_rasterizer.cpp#L4848).

Recommendation for later work: limit or split the query pools appropriately, make overflows visible and record the hardware fallback explicitly. Then compare profiling on/off. Until then, a Metal System Trace should cross-check GPU utilization and encoder times. The 86% GPU utilization and 105 ms GPU time named in the handoff document also remain historical figures here, whose underlying trace was not checked. [Apple: GPU timeline](https://developer.apple.com/documentation/xcode/analyzing-apple-gpu-performance-using-a-visual-timeline).

**5. P1: Keep related render work in one pass for longer**

The code confirms the essential mechanism: `Runtime::FlushBarriers()` ends the current render pass when barriers are present. The draw path calls this function on `needs_barrier` and reopens the pass before the draw. At the same time, all color, depth and stencil attachments in the scheduler use `storeOp = Store`; when the pass is resumed, the contents are loaded again. [Barriers](../gpu/shadps4/video_core/renderer_vulkan/vk_runtime.cpp#L884), [Draw path](../gpu/shadps4/video_core/renderer_vulkan/vk_rasterizer.cpp#L1695), [Renewed pass begin](../gpu/shadps4/video_core/renderer_vulkan/vk_rasterizer.cpp#L1800), [Load/Store](../gpu/shadps4/video_core/renderer_vulkan/vk_scheduler.cpp#L214).

For a G-buffer with several color outputs and depth, this can cause additional transfer between fast internal tile memory and shared main memory. The exact amount depends, among other things, on formats, compression and the actual Metal pass boundaries. Apple's recommendations confirm that as little load/store traffic as possible is important for this architecture. [Apple: Metal optimization](https://developer.apple.com/videos/play/wwdc2020/10632/).

I would investigate the causes in this order:

1. **Wrong or too coarse dependencies:** `AccessBuffer()` rounds pure read accesses up to 4 KiB ranges. The comment confirms that this can create additional barriers. A later write to other bytes of the same page can thus end a pass unnecessarily. The existing switch `CoarseReadTracking` allows a targeted comparison between less CPU bookkeeping effort and fewer GPU interruptions. [Range tracking](../gpu/shadps4/video_core/renderer_vulkan/vk_runtime.cpp#L840).
2. **Global accesses:** Large buffers addressed through page tables unconditionally set `needs_barrier = true` when bound; global writes make subsequent buffer checks dependent across the board. Narrower, provably complete access ranges could help. This direct assignment path is not captured by the existing `BbDiagTag` and has to be taken into account additionally in the evaluation. [Paged buffer](../gpu/shadps4/video_core/renderer_vulkan/vk_rasterizer.cpp#L3269), [Global dependency](../gpu/shadps4/video_core/renderer_vulkan/vk_runtime.cpp#L810).
3. **Prepare image transitions:** Move texture uploads and layout changes before the shared pass where possible, as far as data dependencies, aliasing and lifetime allow. This is particularly interesting for textures bound late that are independent of earlier draws of the pass. [Texture transitions](../gpu/shadps4/video_core/renderer_vulkan/vk_rasterizer.cpp#L3594).
4. **Improve the existing dispatch hoisting:** The function already checks read and written guest ranges. It does, however, insert wide barriers around every hoisted dispatch. Dependent compute groups and barriers could possibly be planned together. Image accesses and unknown ranges must stay conservative. The trial documented so far does not yet bring an FPS gain. [Hoisting](../gpu/shadps4/video_core/renderer_vulkan/vk_rasterizer.cpp#L2107).

An important caveat on the idea in the handoff document: a Metal `memoryBarrierWithScope` cannot simply be used as a general Vulkan barrier inside the current dynamic render pass. Feature, stage, access and layout restrictions apply to it. The wide compute/buffer dependencies in use do not fit arbitrarily into such a pass. First avoid unnecessary dependencies or hoist them validly; design a special backend path separately. [Vulkan synchronization rules](https://docs.vulkan.org/spec/latest/chapters/synchronization.html).

Likewise, a blanket `DontCare` for all attachments would be wrong: G-buffer and depth are used again later. Load/Store may only be dropped if complete overwriting or the end of use is proven. A later Metal path could exploit more of this lifetime information. [Apple: Load/store actions](https://developer.apple.com/documentation/Metal/customizing-render-pass-setup).

**6. P1: Parallelization causes pass boundaries of its own**

By default, the scheduler uses 64 KiB per segment and splits inside a render pass from twice that, that is, around 128 KiB of recorded command data. For this, `MaybeSplit()` explicitly ends the pass. With two or more recording threads, CPU parallelization can therefore create additional GPU work. This byte count describes internal recording data, not the size of the textures. [Defaults](../gpu/shadps4/video_core/renderer_vulkan/vk_scheduler.cpp#L125), [Splitting](../gpu/shadps4/video_core/renderer_vulkan/vk_scheduler.cpp#L533).

Sensible later A/B trials are `BB_VK_RECORD_THREADS=1` as well as larger `BB_VK_SEGMENT_KB` values with several threads. The value `100000` suggested in the notes is suitable as a diagnostic to suppress these splits in practice; it is not a justified permanent default. The better design would be to split preferably at pass boundaries that are needed anyway, with a bounded queue and measured CPU utilization.

More Vulkan recording threads also do not automatically remove the MoltenVK effort of translating a queue to Metal. The project already uses asynchronous queue submits and disabled argument buffers. These settings are already part of the documented improvement from 4.5 to about 8 FPS and must not be booked again as a new gain. The MoltenVK documentation normally describes argument buffers as beneficial; the local deviation must therefore be verified for this game and this driver version. [Active defaults](../macos/run.sh#L55), [MoltenVK configuration](https://github.com/KhronosGroup/MoltenVK/blob/v1.4.2/Docs/MoltenVK_Configuration_Parameters.md).

**7. P1/P2: Weigh graphics quality against cost in a targeted way**

A candidate that has been little visible so far is `ForceAnisotropy()`: without an explicit setting, the renderer raises suitable samplers to **16× anisotropic filtering**. This is additional quality with possible texture costs. `BB_ANISO=0` disables this raise and keeps the original values of the game. `BB_ANISO=4` is a lower minimum raise, not a hard upper limit for game samplers that are already stronger. These variants should be compared before costly architecture changes. A concrete FPS gain is not yet proven. [Filtering](../gpu/shadps4/video_core/renderer_vulkan/vk_rasterizer.cpp#L3674).

As a starting point for later measurements I recommend 1280 × 720 internal, initially without temporal upscaling, then a separate comparison with FSR 3.1 at the same internal resolution and a higher output resolution. This makes the saving from fewer pixels and the additional cost of the upscaler visible separately. The existing startup patch for the render resolution is particularly interesting on this device; the macOS startup path already prefers it over running scaling through proxy render targets. [Resolution selection](../macos/run.sh#L26), [Upscaler paths](../gpu/shadps4/video_core/renderer_vulkan/vk_temporal_upscaler.cpp#L199).

Afterwards, compare shadows, SSAO, depth of field and motion blur individually. The documented 11 to 14 FPS show only the combined effect of switching them off; they do not say which option has the largest share. For a later game profile, the visual impact should also be assessed, in particular for shadows. Tessellation and RectList are for now given lower priority according to the existing switch-off trials.

FSR 4 is not an obvious immediate solution: the current code requires, among other things, compute derivatives, which appear as unavailable in the existing MoltenVK log. FSR 3.1 already has an integrated path. A later MetalFX comparison is technically interesting because color, depth and motion data are already produced in the project; GPU interop, synchronization and additional copies have to be measured as well. Faster MetalFX execution is unproven here. [FSR check](../gpu/shadps4/video_core/renderer_vulkan/vk_instance.h#L313), device log, [Apple: MetalFX](https://developer.apple.com/documentation/metalfx?changes=_10&language=objc).

**8. P2: Adapt memory, threads and build to the M4**

The port already uses imported host memory and `BB_GUEST_IN_PLACE=1`. A blanket recommendation to "enable zero-copy" would therefore come too late. What is interesting instead is which additional mirrors, uploads and write monitoring remain active anyway. `LayerWatchEnabled()` is active by default as long as write traps are available, and was developed, among other things, against the cost of imported memory on discrete GPUs. On unified memory, the benefit of these additional copies has to be re-evaluated. Texture conversions and synchronization remain necessary despite shared memory. [macOS memory model](../macos/run.sh#L44), [Mirroring strategy](../gpu/shadps4/video_core/buffer_cache/buffer_cache_layer.cpp#L410).

To be measured: copy bytes per frame, actual physical memory demand, GPU allocations, compression/swap and the number of pass interruptions triggered by them. Particularly relevant on 16 GB: the automatic resolution path sets `BB_DMEM_MB` to 9152 MiB, while the runtime default is 5056 MiB. This is a pool limit and not automatically fully occupied RAM. Nevertheless, it should be checked whether low resolutions need this larger pool. [Pool selection](../macos/run.sh#L35), [Runtime limit](../src/runtime_memory.c#L21).

For ten available CPU threads, draw preparation by default creates five workers plus a scanner, in addition to recording, game and other helper threads. The M4 has four performance and six efficiency cores. The macOS adjustment already sets utility QoS for background work; the Linux affinity functions, however, do not set any real core bindings on the Mac. Comparisons with `BB_PREP_WORKERS=2`, `3` and `5` as well as one or two recording threads make sense. Fewer threads could reduce energy use or contention, but could also feed the GPU worse. [Worker count](../gpu/shadps4/video_core/renderer_vulkan/vk_draw_prep.cpp#L50), [macOS scheduling](../gpu/shim/bbport_platform.h#L57).

The existing build is already optimized (`RelWithDebInfo`, runtime `-O2`), so it is not a simple debug build. LTO, however, is off in the macOS script and the CMake cache; a comparison with LTO would be a manageable later step. PGO is explicitly disabled, and the general PGO configuration would have to be checked for the Apple Clang toolchain in use. These changes mainly concern CPU work and do not fix GPU load/store problems. [Build options](../macos/build.sh#L24), [General optimization options](../gpu/CMakeLists.txt#L13).

Shader/pipeline warm-up and cache reuse mainly improve stutter on the first appearance of a material or effect. Shader caching already exists in the project. Only when a correct GPU trace shows individual shaders as expensive would I investigate their SPIR-V/MSL output, register pressure, memory accesses and suitable reduced precision in a targeted way. Unchecked global fast-math or blanket precision reduction is not a justified optimization.

**9. What a native ARM64/Metal expansion would cost**

| Architecture | What it improves | Main effort | Assessment |
|---|---|---|---|
| Existing Rosetta/MoltenVK path with better pass planning | GPU memory traffic and recording effort | Scheduler, resource dependencies, measurement | Pursue first |
| Own Metal renderer in the existing process | Direct control over encoders, attachments and bindings | New graphics backend, shader path and feature parity | Long-term candidate; CPU stays translated |
| Separate ARM64 renderer process | Own renderer and driver control run without x86 translation | Process protocol, shared memory, resource lifetime, fences and feedback | Prototype only once a CPU translation bottleneck is proven |
| Complete ARM64 game path | The game also needs no Rosetta execution | Translation/reimplementation of the original game code and runtime adjustments | Standalone, very large project |

A separate ARM64 process would have to receive commands in bundles; a synchronous process call per draw would probably create a new bottleneck. Currently, the renderer reads guest addresses directly, for example when evaluating the copy-shader control list. These pointers cannot serve unchanged as a cross-process protocol. GPU labels, CPU writes and resource recycling would also have to work correctly across the process boundary. [Direct guest accesses](../gpu/shadps4/video_core/renderer_vulkan/vk_rasterizer.cpp#L2075).

A Metal rebuild should only be evaluated against a cleaned-up MoltenVK path. It can reduce unnecessary translation work, but guarantees neither 30 nor 60 FPS and does not automatically remove expensive shaders or a bad pass structure.

Complete rendering is also part of the goal definition: the current pipeline code skips draws with an unsupported geometry shader stage. Higher FPS through missing objects or effects would not be a successful port. The affected draws and visible consequences would have to be recorded and, where needed, replaced correctly. [Skipped shader stage](../gpu/shadps4/video_core/renderer_vulkan/vk_pipeline_cache.cpp#L947).

**10. Concrete test procedure for a later implementation**

1. **Fix the reference:** Commit plus local changes, binary version, MoltenVK version, macOS version, GPU core count, RAM, all settings and an identical save state/camera position. Test the Clinic, an outdoor area with many enemies and an effects/boss scene separately.
2. **Validate the measurement:** Hardware timestamps without fallback; Metal trace as a cross-check. Evaluate diagnostic output and instrumentation separately. Do not take over CPU statistics such as `0.00 us/draw` unchecked: some thread CPU time functions are explicitly not implemented in the macOS shim. [Statistics limit](../gpu/shim/bbport_platform.h#L84).
3. **Isolated comparisons first:** Segmentation/recording threads, filter raise, precise versus coarse range tracking, then effects and resolution. At least three comparable runs per variant; warm up the shader cache for sustained FPS, measure first-run stutter separately.
4. **Then targeted changes:** Remove the most frequent unnecessary pass interruptions. For each change, compare encoder count, load/store traffic, GPU frame time, CPU time on the critical path as well as the average and p95/p99 of the frame times. Do not add up time savings of different measures unchecked.
5. **Assess sustained load:** Identical conditions on mains power, documented power mode, then 20–30 minutes of load on the Air. Record memory, thermal state and frame time history. Short-term peak FPS is not a sufficient success criterion.
6. **Secure image and game behavior:** Check the same camera views, movements, fights, particles, shadows, UI, loading and saving. Barriers, hoisting and memory changes in particular can produce delayed or scene-dependent errors.

The first reliable intermediate goal would be a correct, clearly shortened GPU frame time for an unchanged scene. Only when the complete flow falls below the 33.3 ms budget is a permanent 30 FPS profile with clean frame pacing worthwhile. For a stable 60 FPS, the same scene would have to stay below 16.7 ms. The state examined so far provides no evidence for this.
