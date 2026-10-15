# Live-resolution path on Metal (P7.5)

Status: design, 2026-10-15.

## What it is

Two ways the game's scene gets a render size below its output:

- **Scaled session** (`BB_RENDER_RES`, the m4air profile, outputs other than 1080p without
  `BB_LIVE_RES=1`): the guest's resolution patch makes the game itself render small; the UI
  composition puts the HUD on top at the output size; MetalFX runs in `RunScaled` on the LDR
  frame. Done on Metal in P5.3/P5.4.
- **Live path** (1080p output, or `BB_LIVE_RES=1`): the guest renders at 1920x1080 as on the PS4;
  the backend draws the scene passes into reduced **proxies** of the guest's 1920x1080 (and
  960x540) targets (`SceneTargets` behind the core's `ScenePasses` interface, raster scaling via
  `push_data.scene_size` and `target_scale`), keeps the guest-size images for everything else
  (compute, integer loads, copies, CPU reads: a dirty proxy is resolved into the native image on
  native access), and upscales the **HDR scene before post-processing**: the post-processing
  combine compute shader (`trigger_hash 0x9a9cf8a9`) triggers `TemporalUpscaler::Run`, whose
  output (output size, RGBA16F) is merged into the game's own scene colour in place
  (`upscale_merge.comp`: RGB replaced, alpha kept), so post, tonemap and UI run unchanged at
  1920x1080. The presets (Native AA 1.0, Quality 1.5, Balanced 1.7, Performance 2.0, Ultra
  Performance 3.0; `SceneResolution::ForPreset`) switch live from the menu or `BB_PRESET_FILE`:
  `OnFrameStart` sees the new preset, `SceneTargets::SetSize` resolves every dirty proxy, waits
  for the GPU, drops all proxies and bumps the generation; the upscaler's history resets.
  Native AA keeps the native targets (no proxies) and runs the temporal upscaler at 1:1 as
  anti-aliasing.

Metal today passes no `ScenePasses` (the core uses `NullScenePasses`), its `Upscaler::Active()`
requires a scaled session, and `OnSceneColor`/`OnDispatch` are empty: at 1080p output Metal
renders native without any AA, and the presets do nothing.

## Shared, not copied (D3)

Of `vk_scene_resolution.cpp`'s 489 lines about 120 are backend-neutral bookkeeping; the rest is
Vulkan (blits, resample pipelines, layouts). Of `TemporalUpscaler`'s live logic, the neutral part
is the per-frame decision in `OnFrameStart` and the trigger in `OnDispatch`; both are interleaved
with FSR 4 / DLSS state (the P5.4 decision applies: Metal keeps its own copy of the few lines of
frame bookkeeping instead of extracting them).

**L1 (shared, Vulkan unchanged)**: `VideoCore::SceneTargetsCore` (`video_core/scene_targets_core.{h,cpp}`),
the neutral part of `Vulkan::SceneTargets`:
- size, generation, `SizeDivisor`, `Eligible`, `EligibleScene`, `ProxySize`, `Tracks`,
  `ProxyCurrent`;
- the entries (by `Key(uid, level)`, the `recent` cache, `tracked`, `Coherence`) and the
  sequences of `SetSize` (resolve all, finish, drop, generation), `ResolveAll`, `NativeAccess`
  (resolve a dirty proxy, invalidate on a write), `Get` (create on demand, fill when invalid),
  and the coherence steps of `Attachment` / `SampleProxy` / `Read`;
- a backend part behind virtual functions: `ProxyFormatSupported(image)` (Vulkan: `Blittable ||
  ShaderResampled`), `CreateProxy(entry, image, size)`, `DestroyProxies()` after `Finish()`,
  `Copy(entry, image, to_native)`, `View(entry, image, view_info) -> NativeView`, and a
  `Prepare(entry, use)` hook for layouts (Vulkan: `Transition`; Metal: nothing).
`NativeAccess` takes a plain `bool writes` (Vulkan derives it from its access mask). The
`BB_PRESET_FILE` reader (scripted live preset switches) moves to a shared function both
upscalers call. Acceptance: Vulkan bench within spread, display dumps of a still view at
Performance and Native AA unchanged, a scripted live switch (`BB_PRESET_FILE`) works.

## Metal

**L2 `Metal::SceneTargets`** (`mtl_scene_targets.{h,mm}`), the backend part of L1:
- proxies are `MTLTexture`s of the native image's pixel format at the proxy size (render target
  + shader read; private storage), registered in the residency set like every cache texture;
  freed only after the GPU finished (`SetSize` waits, then retires them through the scheduler's
  deferred operations, the lifetime rule of D6);
- `Copy` cannot use a blit (Metal blits do not scale): a render pass with `fs_tri` and a
  nearest-sampling fragment shader per format class (float / uint / sint colour: `read()` at the
  scaled coordinate), depth (and stencil with `[[stencil]]` export) like the upscaler's depth
  copy pipeline. Pipelines cached by (pixel format, aspect);
- `View` returns the proxy texture or a texture view (format, swizzle) as a `NativeView`, the
  way `Upscaler::RedirectColor` does;
- the core gets it through `SetSceneServices(scene_targets, upscaler, camera_motion, nullptr)`;
  `Metal::Runtime::Transit` calls `NativeAccess` as `Vulkan::Runtime::Transit` does
  (vk_runtime.cpp:362), so every native use of a proxied image resolves it first;
- the rasterizer accepts `NativeView` attachments and sampled views from the core for proxies
  (the path the UI redirects already use).

**L3 `Metal::Upscaler` live path** (`mtl_upscaler.{h,mm}`):
- `Active()` also outside a scaled session (MetalFX provider selected, scaler available);
- `OnFrameStart`: in a non-scaled session the live branch of Vulkan's: output change, preset →
  `scene_targets.SetSize(ForPreset(active ? preset : 0, output))`, `ui.SetRenderSize`,
  `active_render_width/height`, reset and jitter phases from the scene size; the shared preset
  file poll;
- `RasterScaling()`: not scaled session, scene reduced, not done this frame;
- `OnSceneColor` keeps the colour; `OnDispatch(trigger_hash)` runs `RunLive` once a frame;
- `RunLive`: MetalFX temporal scaler with input = the colour and depth proxies (reduced) or the
  native images (Native AA), motion vectors from `CameraMotion` at the input size, jitter,
  reset; output an RGBA16F 1920x1080 texture; then `upscale_merge.comp` (D11 MSL) into the game's
  scene colour (a native write: the proxies of the colour become invalid, so post reads the
  merged native image). No reactive mask in the first version (the scaled path has none either;
  MetalFX supports one since macOS 14.4: a follow-up);
- scaler creation takes 1–2 s under Rosetta: a scaler per (input size, output size, formats) is
  created on a thread when the preset changes; until it is ready the frame is not upscaled (the
  proxy is resolved to the native image by the nearest copy: a blurry frame or two, no stall).

## Verification

- L1: Vulkan unchanged (bench pairs, display dumps at Native AA and Performance, live switch).
- L2+L3: Metal vs Vulkan display dumps of a still view at Native AA and at Performance
  (`BB_PRESET_FILE` to select the preset, `BB_PRESENT_DUMP_TRIGGER`), PSNR against the Vulkan
  dump with the same camera as in P5.4; a live switch Native AA → Performance → Quality from the
  menu without a restart; validation layer clean for a few minutes of switching; FPS at
  Performance reported against the scaled-session m4air numbers.
