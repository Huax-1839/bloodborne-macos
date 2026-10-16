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

### Step 1: microbenchmark (2026-10-17, `tools/metal_compress_probe.mm`)

M4 Air, macOS 27.0.1, arm64 build (x86-64 under Rosetta shows the same pattern), idle machine,
4096², Private, 40 interleaved reps per variant, median GPU ms (two runs agree within ~5%):

| format, content | pass | RT+Read | +ShaderWrite | +PixelFormatView | +both |
|---|---|---|---|---|---|
| RGBA16F, 64² constant tiles | write | 0.573 | 1.16 | 1.16 | 1.16 |
| | read (compute, every texel) | 0.51 | 1.16 | 1.16 | 1.16 |
| | write + read | 1.09 | 2.36 | 2.35 | 2.35 |
| RGBA16F, noise (control) | write + read | 2.05–2.12 | ×1.13–1.17 | ×1.14–1.15 | ×1.14 |
| RGBA8, tiles | write + read | 1.07–1.09 | ×1.14 | ×1.13–1.15 | ×1.16–1.17 |
| RGB10A2, tiles | read / write + read | 0.51 / 1.13 | ×1.18 / ×1.12 | ×1.18 / ×1.13 | ×1.18 / ×1.13 |
| Depth32Float(_Stencil8), tiles/plane/noise | all | — | ×0.96–1.06 | ×0.97–1.04 | ×0.97–1.06 |

- On colour formats **either** usage costs the compression, both together no more. RGBA8 and
  RGB10A2 writes sit at a ~0.6 ms fill floor for 64 MiB here, so their write cost is understated.
- A compressed texture's `allocatedSize` is ~0.5 MiB (per 4096² target) larger than
  `width × height × bpp`: the metadata. Textures with `ShaderWrite` or `PixelFormatView` lose it.
  `compressionType` reads `lossless` and `allowGPUOptimizedContents` YES for every variant
  (they say what is allowed, not what happened).
- **Depth keeps its compression** with either usage: the lever is colour only; depth may keep
  `PixelFormatView` (needed for the `X32_Stencil8` view) at no cost.
- `optimizeContentsForGPUAccess:` does not bring compression back: a no-op on colour (the read
  after it stays at the uncompressed speed, after a render-pass or a compute write), 0.4–1.6 ms of
  work on depth for nothing. A texture has to be created without the usages.
- Views (validation layer; a base without `PixelFormatView`): allowed and correct: sRGB ↔
  linear twin, same-format swizzles (BGRA, RRRR), 2D → 2DArray, mip/slice sub-ranges. Need
  `PixelFormatView`: any other format (RGBA8 → RGBA8Uint, R32Uint, BGRA8; RGBA16F → RGBA16Uint,
  RG32Uint; RGB10A2 → R32Uint) and Depth32Float_Stencil8 → X32_Stencil8. Without the layer the
  32-bit reinterpretations are created anyway and **silently read 0xFFFFFFFF**, so the policy
  must never rely on the driver refusing them. Depth32Float → R32Float is refused even with
  `PixelFormatView`.

### Step 2: inventory in game (2026-10-17, `BB_IMAGE_USAGE_LOG`, `macos/bench/image_usage.py`)

m4air (540p), Metal, three runs: clinic bench, a 5-min walk, Central Yharnam:

| | clinic | 5-min walk | Yharnam |
|---|---|---|---|
| cache images (incl. destroyed) | 1205, 404 MiB | 1327, 436 MiB | 1810, 528 MiB |
| colour render targets (attached at least once) | 87, 81 MiB | 87, 81 MiB | 84, 79 MiB |
| depth / stencil | 15, 80 MiB | 15, 80 MiB | 15, 80 MiB |
| block compressed | 736, 178 MiB | 858, 209 MiB | 1347, 305 MiB |
| written by a shader (storage binding the shader writes) | 331, 78 MiB | 331, 78 MiB | 330, 78 MiB |
| … of them colour render targets too | 33, 19 MiB | 33, 19 MiB | 33, 19 MiB |
| view in another format (needs `PixelFormatView`) | 5, 6.8 MiB | 5, 6.8 MiB | 4, 6.6 MiB |
| needs neither usage | 871, 320 MiB (79%) | 993, 351 MiB (81%) | 1477, 443 MiB (84%) |
| created with `ShaderWrite` / `PixelFormatView` today | 1190 / 1205 | 1312 / 1327 | 1795 / 1810 |

- The busiest render targets are never written by a shader: 6× RGBA16F, 7× RGBA8 and 3× RG11B10F
  at 960×540 (the G-buffer and lighting targets: 43k, 34k, 16k attachment binds in the clinic run)
  and 4× RGBA8 at 480×270. Shader-written are compute-only images (298, 59 MiB), the bloom chain
  (RG11B10F/RGBA16F mips from 157×132 down, render target *and* storage) and 4 RGBA16F 960×540
  targets. The same format and size occur on both sides, so no rule by format and use (option a)
  separates them at creation.
- Format views: the three display buffers (RGBA8_sRGB → BGRA8_sRGB with an `rgb1` swizzle, the
  presenter) and 1–2 small RGBA8Uint → RGBA8_sRGB images. Everything else is whole-texture views,
  swizzles (`r001`, `rgb1`, `bgra`, `000r`: 225–359 images), sRGB twins (4) and sub-ranges (48),
  none of which need `PixelFormatView` (step 1). No stencil views of depth images were made.
- The set is stable: the images that need a usage (keyed by guest address and size) agree between
  the three runs except a few 1×1 RG32Float images; the same ~330 shader-written images appear in
  every scene.

### Step 3: upper bound (2026-10-17)

Experiment (`BB_P10_KEEP=<file>`, a temporary patch of `image.cpp`, not committed): images at
least 64×64 whose guest address and size are not in the list of images that step 2 saw needing a
usage are created without `eStorage` and `eMutableFormat` (depth keeps `eMutableFormat`). A sanity
boot with the usage log: one violation (a 256×256 RGBA8Uint image at an address not seen before
got an sRGB view; harmless), and the lean textures carry the compression metadata in game
(`allocatedSize` RGBA16F 960×540 4,177,920 → 4,210,688 bytes, RGBA8 2,211,840 → 2,244,608),
the full ones do not.

Interleaved boots A B B A with traces (`tracesub.sh`, `BB_PASS_LABELS=1`, `p10ub-*` in
`~/Games/Bloodborne/bench/traces`), A = today, B = the experiment; GPU ms a typical frame:

| | A1 | B2 | B3 | A4 | B − A (means) |
|---|---|---|---|---|---|
| 540p (m4air uncapped) busy union | 15.90 | 14.60 | 15.11 | 16.84 | −1.5 (−9%) |
| 540p C1 (all) / C2 (all) / unlabelled render | 2.43 / 0.63 / 1.08 | 2.12 / 0.43 / 0.65 | 2.08 / 0.43 / 0.67 | 2.47 / 0.65 / 1.04 | −0.35 / −0.21 / −0.40 |
| 540p C6 G-buffer / MetalFX | 6.90 / 1.77 | 6.66 / 1.82 | 6.95 / 1.75 | 7.50 / 1.78 | −0.4 / 0 |
| 720p busy union | 21.57 | 19.10 | 19.14 | 23.87 | −3.6 (−16%) |
| 720p C1 / C2 / unlabelled render | 4.04 / 1.10 / 1.39 | 3.24 / 0.75 / 0.76 | 3.15 / 0.79 / 0.74 | 4.60 / 1.16 / 1.56 | −1.1 / −0.36 / −0.73 |
| 720p C6 G-buffer / MetalFX | 8.28 / 2.13 | 7.97 / 2.15 | 8.06 / 2.21 | 9.50 / 2.22 | −0.9 / 0 |
| 1080p native (`BB_FPS=30`) busy union | 47.05 | (xctrace hang) | 33.73* | 45.77 | * |
| 1080p C1 / C2 / C6 | 12.13 / 2.83 / 12.54 | | 9.32 / 1.84 / 11.44 | 12.01 / 2.76 / 12.52 | −2.7 / −1.0 / −1.1 |
| boot FPS (bench.sh) 540p / 720p / 1080p | 54.1 / 44.8 / 19.9 | 58.0 / 49.1 / — | 58.1 / 43.8 / 26.1* | 54.9 / 39.0 / 20.1 | |

\* Native 1080p runs the live path's Native AA (the temporal upscaler at 1:1); in B its scene
colour (1920×1080 RGBA16F, not in the 540p inventory) lacked `ShaderWrite`, so `RunLive` returned
early (MetalFX 3.4 ms and its blit 3.6 ms missing): the busy union and FPS of B at 1080p are not
comparable; the per-pass numbers are. This is the silent failure the policy must exclude: the
upscaler has to promote the scene colour, not skip.

Reading: the gain is beyond the A/A spread at 720p (−3.6 ms against an A/A spread of 2.3) and
consistent per pass at 540p; it lands in the fullscreen passes that read and write whole targets
(C1 post-processing −15–25%, C2 lighting −32%, the unlabelled render passes −40–50%), less in
the G-buffer (−4 to −10%; the C6 split also varies between traces). Worth the real policy.

### Step 4: policy (decision 2026-10-17)

Option (a), rules by format and use at creation, cannot work: the same format and size occur as
shader-written and as never-written targets (step 2). Option (c), a learned set, needs (b) as the
fallback anyway (new scenes, new addresses). So **(b) promotion**:

- **Creation** (shared `image.cpp`, gated by `BackendLimits::lean_image_usage`, set only by the
  Metal runtime and cleared by `BB_MTL_FULL_USAGE=1`): colour and block images get no `eStorage`
  and no `eMutableFormat`; depth keeps `eMutableFormat` (no compression cost, step 1; the
  `X32_Stencil8` view needs it). Vulkan: the field is false, the flags are unchanged.
- **Promotion** (`CacheBackend::PromoteImageUsage(Image*, usage)`, default no-op; Metal
  implements): a new `BackingImage` with the same sample count and the extra usage, the contents
  copied (skipped while the old backing was never written), `image->backing` switched, the old
  backing retired: its views and texture destroyed through the deferred destroy (D6, after the
  last command buffer that can see them), its view lists emptied, and it is never matched again
  (the sample-count lookup of `SetBackingSamples` skips retired backings). Because the backing
  pointer changes, the texture cache's view memo and the rasterizer's bind-set memo miss by
  themselves, as they do for a sample-count switch.
- **Triggers**: `Image::FindView` (every view of a cache image goes through it, also the
  presenter's) asks the backend what the view needs: `ShaderWrite` for a storage view of a
  colour image, `PixelFormatView` for a view in another format that is not the sRGB twin (and
  that the Metal runtime would actually make); `TextureCache::FindTexture` for a storage binding
  before its memo; the upscaler's `RunLive` for the scene colour before it checks `ShaderWrite`;
  `CopyImage` for a source viewed in another format (`CopySource`).
- **Safety nets** (Metal, logged once, never silent): a storage binding of a texture without
  `ShaderWrite`, a view that needs `PixelFormatView` of a texture without it.
