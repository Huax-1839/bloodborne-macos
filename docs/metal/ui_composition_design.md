# P5.3 design: scene resolution and UI composition on Metal

Status: design (2026-10-14), orchestrator. Implements plan task P5.3.

## What the BB_RENDER_RES path is

`BB_RENDER_RES=WxH` (the m4air profile: 960x540) patches the game at start to allocate and draw
its scene and post targets at WxH (`scripts/patches.py --render-res`). The game's UI target and
display buffers are then WxH too. Without the port's help the HUD is drawn at WxH and scaled with
the scene. The Vulkan backend gets a full-resolution HUD from the UI composition of
`TemporalUpscaler` (`vk_temporal_upscaler.cpp`, "scaled session"):

1. `OnDraw`: the first UI draw of a frame (a Scaleform movie shader, or a native-size viewport,
   into a render-size RGBA8 target that is not a display buffer) starts the UI phase.
   `UiComposition::Choose` picks the background: `Temporal` (FSR/TAA/DLSS upscale of the
   finished frame, `RunScaled`) when an upscaler is active and the camera is ready, else `Copy`
   (`RunUiOnly`: linear blit of the game's frame into the output-size UI image).
2. Both create the output-size (`BB_OUTPUT_RES`, default 1920x1080) UI color image in the
   game's format and a UI depth/stencil image (`EnsureUiResources`), and prepare the UI depth
   (`PrepareUiDepth`: clear depth 1 / stencil 0, then a nearest blit of the game's depth aspect
   when the format supports blits).
3. During the UI phase the core redirects passes into the game's UI target / its depth to these
   images (`RedirectColor`, `RedirectDepth`; `native_ui`: the core scales viewports and scissors
   by `UiComposition::Scale`). A stencil-only UI mask pass into a same-size depth switches the UI
   depth (issue #67).
4. The next frame's display pass (`OnFrameStart`: `display_redirect = ui_phase`) is redirected
   into an output-size host display image per guest display buffer address, and its sampled UI
   target is replaced by the UI image (`RedirectSampled`).
5. The presenter asks `DisplayOverride(address)` and shows the host display image instead of the
   guest one (`vk_presenter.cpp` PrepareFrame); `BB_PRESENT_DUMP_TRIGGER` dumps it.

`SceneTargets` (scene proxies) belong to the live-resolution path only: in a scaled session
`OnFrameStart` never sizes them (`scaled_session` skips `SetSize`), so they stay unreduced and
every `ScenePasses` query answers as `NullScenePasses` does. P5.3 therefore does not port them;
the live path (`BB_LIVE_RES=1`, 1080p output with a scaled preset) is recorded as a later task.

## Split

The UI composition's decisions and state move to a shared class; the images and their GPU work
stay in the backends behind a small interface. FSR/FSR 4/DLSS/TAA stay in the Vulkan
`TemporalUpscaler` (D10: not ported); P5.4 adds MetalFX as Metal's `Temporal` background.

`video_core/ui_compositor.{h,cpp}` (namespace `VideoCore`):

- `class UiCompositionBackend` (implemented by `Vulkan::TemporalUpscaler` and
  `Metal::Upscaler`):
  - `EnsureUiImages(w, h, color_format, depth_format, new_color, new_depth)`: (re)create the
    output-size UI color image (sampled, render target, transfer src/dst; storage on Vulkan) and
    UI depth image; may wait for the GPU.
  - `CopyBackground(ImageId color, u32 width, u32 height)`: the game's frame (top-left
    width x height of `color`; on Vulkan's live path a scene proxy instead) scaled with linear
    filtering into the whole UI color image, ready as a color attachment after.
  - `PrepareUiDepth(ImageId depth, bool copy)`: clear depth 1 / stencil 0; with `copy`, the
    game depth's depth aspect scaled (nearest) into it.
  - `bool CanCopyDepth(vk::Format)`: whether PrepareUiDepth can copy this format.
  - `ReplacementView UiColorView(vk::Format, vk::ComponentMapping)`,
    `ReplacementView UiDepthView()`: views (mirroring the game's view format/swizzle) and layout.
  - `void UiReadBarrier()`: after the UI phase, before the display pass samples the UI image.
  - `ReplacementView DisplayTarget(VAddr address, vk::Format image_format, vk::Format
    view_format, u32 w, u32 h)`: the output-size host display image of that guest buffer
    (created/recreated when format or size changed), prepared as a color attachment.
- `class UiCompositor`: the state now in `TemporalUpscaler` that only the UI composition uses
  (output and render size, `scaled_session`, the UI trigger shader, `ui_phase`, `ui_color`,
  `ui_depth`, UI size/formats, `display_redirect`, `ui_read_barrier`, the per-address display
  validity under its mutex, `BB_UI_TRACE`), with `Scaled()`, `RenderTarget()`, `OnFrameStart()`,
  `OnDraw(..., temporal_ready, temporal_active, run_temporal)`, `Begin(color, depth)` (the
  common end of RunScaled/RunUiOnly), `RedirectColor/Depth/Sampled`, `RedirectsSampled`,
  `RedirectState` bits, `DisplayOverride(address, use)` (calls `use` with format and size under
  its lock; the backend reads its own image there).
- `PresentDumpDue()` (free function, the `BB_PRESENT_DUMP_TRIGGER`/`_COUNT` logic) shared by both
  presenters.

Core: the display-pass detection in `rasterizer_core_pipe.cpp` runs when
`camera_enabled || upscaler_enabled` (Metal has an upscaler without camera motion until P5.4; on
Vulkan `upscaler_enabled` implies `camera_enabled`, so nothing changes there).

## Metal side

`renderer_metal/mtl_upscaler.{h,mm}`: `Metal::Upscaler` implements `VideoCore::UpscalerApi`
(Enabled unless `BB_UPSCALER=none`; no temporal provider until P5.4: no jitter, no raster
scaling, mip bias 0, `Choose` always gets `temporal_active = false`) and
`VideoCore::UiCompositionBackend` with Metal textures:
- UI color `MTLTexture` (private, render target | shader read | pixel format view), views by
  `newTextureViewWithPixelFormat:` (+ swizzle) for the game's view formats; UI depth
  `Depth32Float_Stencil8`.
- CopyBackground: a full-screen draw sampling the game texture with a linear sampler
  (Metal blits cannot scale), as fs_tri + a sample fragment shader.
- PrepareUiDepth: a render pass clearing depth/stencil; `copy` draws the depth (nearest) with a
  fragment shader writing `[[depth(any)]]` (only if Vulkan copies on this machine: the Vulkan
  log line `UI: native composition` says which).
- Barriers are no-ops (hazard-tracked resources, D7); textures are freed through the
  scheduler's deferred operations.
- The presenter's PrepareFrame takes the host display image from `DisplayOverride` like the
  Vulkan presenter; the rasterizer passes the upscaler to `SetSceneServices`.

## Verification

Vulkan after the extraction: bench with `BB_PROFILE=m4air` (exercises the scaled session) in
interleaved pairs, title screenshot, and display-buffer dumps of the HUD in the clinic before/after
(`BB_PRESENT_DUMP_TRIGGER`, `macos/bench/rawdiff.py`). Metal: `BB_RENDER_RES=960x540` (no
upscaler, `Copy` background) against Vulkan at the same settings with FSR off in the menu
(`BB_SETTINGS=upscaler=…` or toggle 1<<24) so both take the `Copy` background: display dumps
(1920x1080, HUD sharp), rawdiff.
