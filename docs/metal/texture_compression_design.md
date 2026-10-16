# Lossless texture compression on Metal (P10.1)

Status: design, 2026-10-17; steps 1–2 (ground truth, inventory) in progress, the policy (step 4)
is chosen from their data. Lever 2 of `docs/PERFORMANCE_LEVERS_2026-10-16.md`. Owner of the
design and the measurements: the orchestrator; the microbenchmark, the inventory switch and the
policy's implementation: porter tasks.

## Goal

Lower the memory traffic of the render passes (and the GPU's DRAM power on the fanless Air) by
letting the Apple GPU keep the texture cache's render targets, depth buffers and sampled images
losslessly compressed. Lossless compression never changes a pixel, so the images must come out
identical within the game's own animation noise. Metal only: the texture-cache code is shared,
so every change is gated by a `BackendLimits` field that only the Metal runtime sets; the
Vulkan backend keeps today's flags bit for bit.

After P9.1 the GPU needs 16.5 ms a typical frame at 540p and 24.6 ms at 720p (cool Air); the
ALU-heavy fullscreen passes fell by 80–87%, and what is left (G-buffer C6 ~5.5 ms at 540p,
MetalFX ~1.8 ms) is more likely bound by memory traffic, which grows with the resolution. The
main targets are 720p and native 1080p (the stretch goal), plus GPU power.

## Evidence (code review 2026-10-16, re-verified 2026-10-17)

1. `texture_cache/image.cpp:18-43` (`ImageUsageFlags`): every non-block colour image gets
   `eStorage` ("Always create images with storage flag to avoid needing re-creation in case of
   e.g compute clears. This sacrifices a bit of performance but is less work"); block images
   too. `image.cpp:111-112`: every image gets `eMutableFormat | eExtendedUsage`.
2. `renderer_metal/mtl_runtime.mm` `Runtime::CreateImage` (:980-1040): Private storage;
   `eStorage` becomes `ShaderRead | ShaderWrite` (colour, single sample), `eMutableFormat`
   becomes `MTLTextureUsagePixelFormatView` (every image, depth included). Nothing sets
   `allowGPUOptimizedContents` (default YES), `compressionType` or calls
   `optimizeContentsForGPUAccess`.
3. `Runtime::CreateImageView` (:1090-1200) makes a view for another format (when
   `ViewCompatible`), a swizzle, a sub-range, or `X32_Stencil8` for the stencil of a combined
   depth format. `texture_cache/image_view.cpp:95-98` drops `eStorage` from non-storage views
   (Vulkan semantics; Metal views inherit the base's usage).
4. `mtl_scene_targets.mm:319-326`: the live path's proxies already drop storage ("a texture that
   is only a render target keeps the GPU's lossless compression") but keep `eMutableFormat`;
   their format views (:466-478) are made only when the base has `PixelFormatView`. The
   upscaler's own textures (`mtl_upscaler.mm:1097`, `:1232`) and the frame interpolator's
   (`mtl_frame_interpolator.mm:209`) also carry `PixelFormatView` and/or `ShaderWrite`.
5. Apple: Private textures on Apple GPUs are compressed losslessly where possible;
   `ShaderWrite` and `PixelFormatView` are the usages that can prevent it (views that change
   only sRGB-ness may be exempt). Not verified on this M4 / macOS 27: step 1 settles it.
6. Which session uses which images: the m4air profile (540p) and `BB_RENDER_RES=1280x720` are
   *scaled sessions*: the game renders small into ordinary cache images (lever applies fully);
   the live path's proxies exist only at 1080p output with a preset or `BB_LIVE_RES=1`
   (`docs/metal/live_resolution_design.md`).

## Steps

1. **Ground truth** (porter, `tools/metal_compress_probe.mm`, standalone, native and x86-64):
   full-screen passes write and then sample a large target (4096², RGBA8Unorm, RGBA16Float,
   RGB10A2Unorm, Depth32Float_Stencil8; content with constant tiles, i.e. compressible, and
   noise as control) created with usages {RT|Read}, +ShaderWrite, +PixelFormatView, and both;
   GPU time from `GPUStartTime`/`GPUEndTime`, median of many runs. With the validation layer:
   which views need `PixelFormatView` (another format of the same size class, the sRGB variant,
   a swizzle, the `X32_Stencil8` view, a sub-range or type change). Result: which usages cost
   compression here and how much.
2. **Inventory in game** (porter; a scout digests the log): `BB_IMAGE_USAGE_LOG=1` records per
   cache image its format, size, render target or depth, every view format and swizzle made
   from it, and whether a shader ever wrote it (storage binding, compute clear, port kernels).
   Runs: clinic bench, a 5-min walk, Central Yharnam (`BENCH_SAVE=pristine-savedata-yharnam`).
   Answer: how many images need `ShaderWrite` / `PixelFormatView`, the format pairs, and their
   sizes.
3. **Upper bound** (O): an env switch creates images without the two usages where step 2 says
   they are never needed; traces of GPU ms per pass (and bytes per frame if the "Metal GPU
   Counters" instrument records them) at 540p, 720p, native 1080p. If the gain is below the
   noise (~±3 ms busy; per pass for smaller effects), record it as measured and stop.
4. **Policy** (O design, porter at effort high: memory lifetime). Images get `ShaderWrite` and
   `PixelFormatView` only when needed, chosen from step 2's data among:
   - (a) rules by format and use, known at creation;
   - (b) promotion: on the first view in another format or the first shader write, recreate
     the texture with the extra usage, copy the contents, swap it in, retire the old texture
     through the deferred destroy (plan D6) and rebuild its views (precedent: the backing switch,
     `Image::backing_images`, `SetBackingSamples`);
   - (c) a learned set of images, persisted next to the pipeline cache.
   Off switch: `BB_MTL_FULL_USAGE=1` restores today's usages.
5. **Verify**: interleaved boots A B B A with traces (`tracesub.sh` + `mtltrace.py`,
   `BB_PASS_LABELS=1`) at 540p, 720p, 1080p; FPS by `m2.sh`; display dumps A vs B within
   same-build noise (`rawdiff.py`) and screenshots per plan §6; a 5-min walk with
   `MTL_DEBUG_LAYER=1`; a 20-min walk with `memgrowth.py` (promotion allocates); Vulkan bench
   and screenshot (shared code); optionally GPU power A vs B (`sudo powermetrics --samplers
   gpu_power`, run by the user).

## Results

(Filled in per step.)
