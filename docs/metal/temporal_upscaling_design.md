# P5.4 design: MetalFX temporal upscaling

Status: design (2026-10-14), orchestrator. Implements plan task P5.4 (D10).

## Scope

The scaled session (`BB_RENDER_RES`, the m4air profile) on Metal gets the `Temporal` background
of the UI composition (`docs/metal/ui_composition_design.md`): the game's finished, tonemapped
frame (render size, the last RGBA8 target before the UI) is upscaled by a MetalFX temporal scaler
into the output-size UI color texture, with the scene depth, camera motion vectors and sub-pixel
jitter, exactly where the Vulkan backend runs FSR 3 (`TemporalUpscaler::RunScaled`). The live
path (no `BB_RENDER_RES`: HDR reconstruction before post, scene proxies) stays Vulkan-only until
P7.5 (moved from P5.6); without `BB_RENDER_RES` Metal keeps no temporal provider (no jitter, no mip bias).

Not ported (D10): FSR 3/4, DLSS, TAA, the reactive mask (off by default on Vulkan too), object
motion vectors (off by default on Apple GPUs; P6.7), the camera-motion debug overlay
(`BB_DEBUG_MOTION`, Vulkan only).

## P0 spike, repeated for the game's formats (2026-10-14, x86-64 under Rosetta, M4)

MetalFX temporal scaler with color `RGBA8Unorm` (and `_sRGB`), depth `Depth32Float_Stencil8`
(the game's depth, no copy needed) or `Depth32Float`, motion `RG16Float`, output `RGBA8Unorm`;
descriptor 960x540 → 1920x1080 with 960x544 input textures and `inputContentWidth/Height`
960x540: creates and encodes, validation layer clean. Required usages: color, depth, motion
`ShaderRead`; output `ShaderRead | ShaderWrite | RenderTarget`. First creation 2.9 s (later ones
in the same process ~0.1 s), ~4 ms GPU a frame. The ANE prints "doCompileModel … Bad argument"
errors during the first creation (harmless).

## Split

1. **Shared camera tracker** `video_core/camera_tracker.{h,cpp}` (`VideoCore::CameraTracker`):
   everything of `Vulkan::CameraMotion` that is not Vulkan: the scene-constant signature
   (`OnConstants`), `OnGBufferPass`, the per-pass camera committed once per frame
   (`CommitFrameCamera`), `OnDisplayPass` bookkeeping, `InvalidateHistory`, `SetJitter`,
   `Ready`, `Depth`, `RenderSize`, `VerticalFov`, `Near`, `TaaDepthParameters`, `PrintState`, the
   3x4 matrix helpers, and `MotionConstants(width, height, mode)`: the push constants of
   `camera_motion.comp` (108 bytes, std430 push layout). `Vulkan::CameraMotion` keeps its
   interface and pipelines and delegates (its debug overlay reads the tracker's state).
2. **`Metal::CameraMotion`** (`renderer_metal/mtl_camera_motion.{h,mm}`): a
   `VideoCore::CameraMotionApi` over the tracker plus the motion-vector compute pass from the
   D11 header `camera_motion_comp_msl.h` (depth bound to both of its texture slots, mode 0: no
   object motion). The Metal rasterizer passes it to `SetSceneServices`.
3. **Frame bookkeeping in `Metal::Upscaler`** (not extracted from `TemporalUpscaler`, whose
   `OnFrameStart`/`OnDraw` are entangled with FSR 4, DLSS, the live presets and the menu's
   provider switching): jitter (Halton 2/3 over `Motion::JitterPhases(render, output)`; `Halton`
   moves next to `JitterPhases` in `motion_history.h`, Vulkan uses the shared one), `reset`,
   `done_this_frame`, `ldr_target` (`OnColorTarget`, same rule as Vulkan), `SceneMipBias`
   (log2(render / output) while active, as Vulkan's FSR path).
4. **MetalFX scaler in `Metal::Upscaler`**: created at startup on a worker thread when the
   session is scaled and the upscaler is enabled (descriptor: color `RGBA8Unorm`, depth
   `Depth32Float_Stencil8`, motion `RG16Float`, output `RGBA8Unorm`, input = `BB_RENDER_RES`,
   output = `BB_OUTPUT_RES`); `Temporal` is offered once it is ready. A frame whose formats or
   sizes do not match the scaler recreates it on the recording thread (logged). `RunScaled`:
   transit inputs, end the encoder, motion pass into a render-size `RG16Float` texture, end the
   encoder, set the scaler's textures/content size/jitter/reset, `encodeToCommandBuffer:` on the
   scheduler's open command buffer, `ui.Begin`. All inputs are hazard-tracked textures, so
   Metal orders MetalFX's own encoders against ours; the scheduler's fences only order guest
   buffer writes, which MetalFX does not touch.
5. **Menu**: a new provider `UpscalerMetalFx` ("metalfx", label "MetalFX"). Metal offers Off and
   MetalFX; an ini or `BB_UPSCALER` asking for FSR 3/4/4.1.1/TAA/DLSS maps to MetalFX at start
   (printed). Vulkan treats "metalfx" as FSR 3.1. `BB_PROFILE=m4air` therefore needs no change.

## Conventions (measured 2026-10-14)

Both signs are +1: MetalFX takes the jitter as our viewport shift in render pixels (x right,
y down) and the motion vectors as ours (previous minus current, render pixels, y down), as FSR 3
does. `BB_METALFX_JITTER=sx,sy` and `BB_METALFX_MV=sx,sy` override them; the experiment bits of
`BB_TOGGLE_FILE` (second number) flip them while the game runs: 1/2 jitter x/y, 4/8 motion x/y,
16/32 tell MetalFX no jitter on x/y, 64 no motion vectors.

Measured in one run on one view (clinic, m4air), 4 consecutive display dumps per setting:
- Still camera, PSNR between consecutive frames (Vulkan FSR 3: 56–58 dB): signs +1,+1 52–55 dB;
  x flipped 43–46 dB with the frames oscillating ±0.16 px in x (global least-squares shift);
  y flipped 51–53 dB, y or x zeroed within noise; jitter off 61–63 dB (no sub-pixel detail).
- Camera turning (right then back left, same view per setting): +1,+1 keeps the wall lamp
  crisp; x motion flipped or motion vectors off double it.
- y could not be told apart on these views (no vertical motion; the vertical jitter's effect is
  below the noise); +1 was taken as the convention consistent with x and with the FSR 3 path.
- y measured 2026-10-16 (`macos/bench/temporal_check.sh`, run `temporal-t2`): a vertical pan of
  ~23 px a frame, 12 consecutive frames per setting, settings A/B/C/A/B/C in one run. Sharpness
  (mean luma gradient, central crop): +1,+1 1.495; jitter y flipped 1.330; motion y flipped
  1.360; repetitions agree within 0.033. Both flips blur by 9–11%: **y is +1 for both**.

## Verification

Vulkan after the tracker extraction: m4air bench pairs within spread, display dumps of the clinic
(same camera) against the previous build. Metal: `BB_PROFILE=m4air` display dumps against
Vulkan m4air (FSR 3), validation layer clean, 10 min `m1_run.sh` with `MTL_DEBUG_LAYER=1`.

Temporal behaviour (2026-10-16, review finding 8; `temporal_check.sh` scripts the pad and dumps
bursts of consecutive display frames, `temporal_metrics.py` measures them: global motion,
residual after motion compensation, sharpness, per-tile decay; contact sheets per sequence):
- vertical pans: the y convention above;
- diagonal pan and strafe past the furniture (disocclusion around the character): no trails or
  doubling on the contact sheets; residual after compensation 39 dB (pan) and 28 dB (strafe,
  the character moves against the background);
- camera cut (options menu open 2 s, closed): no tile decays over the 12 frames after the close
  (no ghost of the menu): the copied menu frames reset the history (`OnDraw`);
- preset changes on the live path (Quality ↔ Performance during a pan, 80 frames each): no
  black or garbage frame (luma outliers, PSNR to both neighbours < 15 dB), the switch shows as
  one sharpness step. In a scaled session (`BB_RENDER_RES`, the m4air profile) the preset is
  fixed at start, so this needs `BB_AUTO_RENDER_RES=1`.
There is no camera-cut detector: a cut inside the game's 3D (a cutscene camera change) keeps the
history until the game loses its camera for a frame; not observed in the clinic.
