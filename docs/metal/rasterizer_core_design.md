# RasterizerCore: sharing the rasterizer's neutral logic (plan P4.1, D2)

Status: design 2026-10-14, after `docs/metal/rasterizer_coupling.md`. Steps R1–R6 below, each its
own commit, each verified on Vulkan (bench and title screenshot against the previous commit).

## Shape

- `VideoCore::RasterizerCore : public RasterizerApi` (`video_core/rasterizer_core.h/.cpp`, may be
  split into several `.cpp` by topic) holds the backend-neutral logic and its state: the stage A/B
  protocol (draw pipe, ordered tasks, `PostDraw`, prepared draws, bind helper), signals, labels and
  fences (signal queue and thread, watchdog), host copies and memory notes, page-fault handling,
  draw filtering and scene-resolution decisions, resource selection from `Shader::Info` (buffer,
  image and sampler lookups in the shared caches), occlusion and timestamp bookkeeping. It owns the
  shared caches (`BufferCache`, `TextureCache`), the `PageManager`, `DrawPreparation` and the
  `DrawPipe`.
- The backend's rasterizer derives from it (`Vulkan::Rasterizer final : public RasterizerCore`,
  later `Metal::Rasterizer final : public RasterizerCore`) and implements protected pure virtual
  **recording hooks** (the DrawRecorder method groups of the study, §6): begin/end pass and pass
  queries, pipeline binding, dynamic state, vertex/index binding, resource binding, draws,
  dispatches, memory barriers, hoisting, queries, markers, buffer markers. Template method instead
  of a separate recorder object: the neutral code reads and writes rasterizer state in hundreds of
  places; a class split keeps that access, a second object would need it passed around.
- The core reaches the GPU only through the hooks, `CacheBackend` (the caches' seam, already used
  by the core for barriers, transits, clears, resolves) and a small **queue interface** for what the
  scheduler gives the neutral logic (ticks, waits, deferred operations, host copies, the signal
  wait, submission/flush/finish, recording kicks and syncs). On Vulkan both the queue interface and
  `CacheBackend` are `Vulkan::Runtime`/`Scheduler`; the Metal backend implements them in
  `mtl_runtime`/`mtl_scheduler` (P4.2).
- Shared structs that carry Vulkan handles today get neutral references: vertex/index binds hold
  `const VideoCore::Buffer*` + offset instead of `vk::Buffer`; render attachments hold the
  `VideoCore::ImageView*` (+ layout as vocabulary); descriptor infos stay in the Vulkan rasterizer
  (the core hands the hook a list of (binding, resource, range) and the hook writes descriptors or
  sets Metal slots). Vulkan enums and plain structs (`vk::Format`, `vk::Viewport`, `vk::Rect2D`,
  `vk::CompareOp`, …) stay vocabulary, as in the caches.
- The pipeline cache is split the same way: `PipelineCacheCore` (shared: key building
  `RefreshGraphicsKey`/`RefreshComputeKey`, stage selection, recompiler programs and
  permutations, prepared pipelines, async/skippable decisions, the disk cache of keys) and backend
  hooks for module and pipeline creation (Vulkan: `vk::ShaderModule` + `GraphicsPipeline`; Metal:
  `mtl_shader` + `mtl_pipeline_cache`). Pipelines are opaque to the core
  (`const PipelineHandle*` with the shader infos and the key it needs).
- Hot path: the hooks are a handful of virtual calls per draw (the study estimates 15–25), accepted
  as for the caches; per-draw state bundles are passed by reference, not rebuilt per hook.

## Steps (each: build, unit tests, Vulkan bench 3+ interleaved pairs, title screenshot)

- R1 Class split without moving logic out of the file: introduce `RasterizerCore` with the members
  and the N functions (pure moves into `rasterizer_core.*`), `Vulkan::Rasterizer` derives from it;
  friends (`BufferCache` etc.) and the HLE/occlusion helpers take the core.
- R2 M-easy functions: neutral part into the core, the Vulkan tail into hooks
  (`WriteLabelOnGpu`, `GpuSignalLoop` wait, `DrawIndirectRecord`, `DispatchRecord`,
  `DispatchIndirectRecord`, `ResolveIndexBuffer`, `ResetBindings`, `BindSamplers`,
  `BindTexturesFromSet`, `UpdateDepthStencilState`, `UpdatePrimitiveState`, `MarkPass`).
- R3 M-medium: `DrawRecord`, `HoistDispatch`, `ResolveVertexBuffers` (neutral buffer references
  first), `BindBuffers`, `UpdateViewportScissorState` (viewport math shared, the setter a hook).
- R4 M-hard: `BindTextures`, `BeginRenderingFull` (decide per attachment in the core, produce a
  neutral attachment list; the hook does layouts and the begin).
- R5 Pipeline cache split (`PipelineCacheCore` + backend hooks).
- R6 The queue interface: the scheduler features the core uses go through it; after R6
  `rasterizer_core.*` includes no `renderer_vulkan/` header except vocabulary (`vk_common.h`,
  `liverpool_to_vk.h`, `vk_draw_pipe.h`, `vk_draw_prep.h` until they move to `video_core/`).

Then P4.2–P4.5 build the Metal side on the same core.
