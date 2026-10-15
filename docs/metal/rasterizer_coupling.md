# Sharing the rasterizer between Vulkan and Metal (plan D2/D3/D7/D8, P4)

Scope: `gpu/shadps4/video_core/renderer_vulkan/` rasterizer, draw pipe, draw prep, scheduler,
runtime (rasterizer use only), barrier tracker, bind helper, constant ring, occlusion, timestamps,
indirect guard, HLE shaders, pipeline cache (key building), graphics pipeline and common.
Method: line counts with `wc -l`; Vulkan-touching lines with a strict regex
(`vk::|cmdbuf|Vulkan::|instance\.|scheduler\.|VMA|vkCmd`); functions from `Rasterizer::` definitions
in `vk_rasterizer.cpp` (117 functions, body length = next definition minus start); each function
read at its Vulkan-touching lines. Function line counts are exact; the neutral share of mixed
functions is an estimate (about +/-15 %).

Classes: N backend-neutral (a Metal rasterizer needs the same code; calls to `runtime.` count as
neutral, since they become the cache backend of `cache_backend_design.md`); V Vulkan recording;
M mixed, split easy (recording at the end of the function) or hard (interleaved).

## 1. Per file

| File | Lines | Vk lines | Verdict |
|---|---:|---:|---|
| vk_rasterizer.cpp | 5062 | 229 | N 2502 / M 2235 / V 113 lines of function bodies |
| vk_rasterizer.h | 734 | 23 | mixed: state members use vk types (see 3) |
| vk_draw_pipe.h | 264 | 0 | N (stage A/B ring, no Vulkan) |
| vk_draw_prep.h / .cpp | 169 / 506 | 2 / 6 | N (worker threads, sharp reads) |
| vk_scheduler.h | 1297 | 68 | mixed: ticks/host copies/ordering N; Record templates, DynamicState, RenderState V |
| vk_scheduler.cpp | 1330 | 106 | about 600 N (ticks, host copies, deferred ops, ordering, census), about 600 V (BeginRendering, submit, recorder threads, segments) |
| vk_runtime.h / .cpp | 177 / 1040 | 17 / 245 | the rasterizer uses ~25 methods; they are the CacheBackend (see cache docs) |
| vk_barrier_tracker.h / .cpp | 137 / 368 | 0 / 0 | N (no Vulkan; only needed if Metal copies Vulkan's buffer barrier model) |
| vk_bind_helper.h | 122 | 0 | N (bind-helper thread); .cpp absent (header-only or elsewhere) |
| vk_constant_ring.h | 117 | 6 | V (`vk::Buffer Handle()`, stamp entries); .cpp absent |
| vk_occlusion.h / .cpp | 132 / 439 | 8 / 59 | M: segment bookkeeping N, query pool calls V (Resolve, ResetAhead, Event) |
| vk_timestamps.h / .cpp | 76 / 182 | 7 / 47 | V (query pool, calibrated timestamps) |
| vk_indirect_guard.h / .cpp | 61 / 166 | 7 / 38 | V (compute check of indirect args) |
| vk_shader_hle.h / .cpp | 23 / 301 | 0 / 33 | M-easy: copy-shader HLE selects buffers, calls runtime copies |
| vk_pipeline_cache.cpp | 1251 | 57 | key building N (RefreshGraphicsKey/Stages/ComputeKey, GetGraphicsPipeline ~ 650 lines); GetProgram/CompileModule/ReplaceShader V; BuildRuntimeInfo reads instance caps |
| vk_graphics_pipeline.h / .cpp | 145 / 553 | 14 / 159 | V (VkPipeline creation, layouts, dynamic states) |
| vk_pipeline_common.h / .cpp | 82 / 146 | 15 / 35 | V (BindResources writes WriteDescriptorSet / push descriptors) |

Scope total: 14880 lines in the files above; about 1,300 of them are Vulkan-only recording or
creation (V); the rest is neutral or mixed.

## 2. Functions of vk_rasterizer.cpp (117)

| Class | Functions | Lines |
|---|---:|---:|
| N | 89 | 2502 |
| M-easy | 12 | 694 |
| M-medium | 5 | 928 |
| M-hard | 2 | 612 |
| V | 9 | 113 |
| Total | 117 | 4849 |

Neutral (N) examples with line numbers: signals and labels (`PublishSignals` 97, `SignalAfterGpu` 130,
`SubmitForSignals` 338, `GpuWatchdog` 462); guest-memory writes and page faults (`WriteGuestMemory` 187,
`NoteCommandWriteInOrder` 877, `InvalidateMemory` 4515, `OnWriteFault` 4568, `MapMemory` 4607);
draw filtering and scene decisions (`FilterDraw` 520, `FindTargetMemoized` 568, `PrepareRenderState` 622,
`BeginRendering` 3990, `DrawsNothing` 1862); stage A/B and RunInOrder (`FindPreparedStage` 2414,
`RunInOrder` 1247, `RunDrawPacket` 1272, `PostDraw` 993-1234, 242 lines, zero Vulkan lines);
the bind-helper join (`BindHelperWanted` 2431 to `JoinBindHelper` 2521, 4 functions, 230 lines);
resource selection (`BindResources` 2618, `CachedImageDescEntry` 3493, `ForceAnisotropy` 3820,
`IsComputeImageClear` 3203, `NoteCopyShaderAccesses` 2121, `FillBuffer` 4422, `CopyBuffer` 4465).

V functions: `EmitVertexBuffers` 2788, `EmitIndexBuffer` 2996, `UpdateDynamicState` 4632,
`UpdateRasterizationState` 4913, `UpdateColorBlendingState` 4919, `ScopeMarkerBegin` 4927,
`ScopeMarkerEnd` 4939, `ScopedMarkerInsert` 4949, `ScopedMarkerInsertColor` 4961.

M-easy (12, 694 lines): `WriteLabelOnGpu` 267-329 (V 304-316, `writeBufferMarkerAMD`); `GpuSignalLoop`
405-461 (V 407-434, `waitSemaphores`); `DrawIndirectRecord` 1925-2025 (V 1986-2023); `DispatchRecord`
2045-2120 (V 2092-2118); `DispatchIndirectRecord` 2329-2383 (V 2349-2381, with `Breadcrumbs::CopyArgs`);
`ResolveIndexBuffer` 3003-3025; `ResetBindings` 3026-3094 (barriers via `runtime.AccessBuffer`); `BindSamplers`
3855-3874 (V 3864-3871); `BindTexturesFromSet` 3904-3989 (V 3965-3983); `UpdateDepthStencilState` 4792-4875
(setters); `UpdatePrimitiveState` 4876-4912 (setters); `MarkPass` 4990-5024 (pass label).

M-medium (5, 928 lines): `DrawRecord` 1576-1861 (V tail 1766-1856, interleaved with `needs_barrier` flushes);
`HoistDispatch` 2153-2309; `ResolveVertexBuffers` 2825-2990; `BindBuffers` 3314-3492 (descriptor write
3480-3492); `UpdateViewportScissorState` 4647-4791 (math on registers, `vk::Viewport` construction, setters).

M-hard (2, 612 lines): `BindTextures` 3533-3819; `BeginRenderingFull` 4052-4378.

## 3. Shared data structures (neutral logic touches Vulkan types)

- `RenderState` (vk_scheduler.h:59) holds `RenderAttachment` (vk::ImageView, vk::ImageLayout,
  clear value); `BeginSignature` (vk_rasterizer.h:289) holds `VideoCore::ImageViewInfo` with vk::Format and
  vk::ComponentMapping. `BeginMemo` compares them; the decision is neutral, the type is not.
- `PreparedDraw` (vk_draw_prep.h:79) is neutral, but `PreparedVertexInputs` (vk_draw_prep.h:65) holds
  `vk::VertexInputAttributeDescription2EXT` and `...BindingDescription2EXT` pointers.
- `VertexBinds` (vk_rasterizer.h:571) and `IndexBind` (580): vk attribute/binding descriptions, `vk::Buffer`,
  `vk::DeviceSize`, `vk::IndexType`.
- `image_infos` / `buffer_infos` (vk_rasterizer.h:463-464) are `vk::DescriptorImageInfo` /
  `DescriptorBufferInfo`; `TextureSetEntry` holds a `vk::ImageView`.
- `GraphicsPipelineKey` (vk_graphics_pipeline.h:34, 39) holds `vk::Format` and `vk::ColorComponentFlags`:
  hashed, neutral, vocabulary (as in the cache design).
- `DynamicState` (vk_scheduler.h, `CommitWith`) takes `vk::Viewport`, `vk::Rect2D`, cull and stencil enums.

These are plain enums and structs (vocabulary). Only `set_writes`, `vk::Buffer` handles from
`Handle()`, and `vk::DescriptorImageInfo` are Vulkan-specific in use.

## 4. Scheduler features the neutral logic uses

Ticks and waits: `CurrentTick`, `IsFree`, `Wait`, `WaitSubmitted`, `GetWorkSemaphore()->KnownGpuTick`,
`PopPendingOperations`, `DeferOperation`, `DeferPriorityOperation`, `Finish`.
Ordering and recording: `RecordOrdered`, `RecordCrumb`, `Record` (Vulkan lambda), `RecordData` /
`ReserveRecordData` (arena for recorder threads), `KickRecording`, `SyncRecording`, `OrderedReady`.
Passes: `HoldingPass`, `HeldPassSerial`, `BeginHoist`/`EndHoist`, `ReleaseHeldPass`, `IsRenderingWith`,
`pass_label_shaders`, `CensusPass`.
Host copies and signals: `NoteHostCopySource`, `RecordHostCopy`, `WaitHostCopies`, `WaitHostCopiesFor`,
`SignalAfterHostCopies`, `WaitDeferredSignals`.
Segments: `EnterDirectMode`, `LeaveDirectSegment`, `MaybeSplit`, `HandOver`, `AcquireChunk`.

## 5. Threading model

1. Game submit thread: copies and scans a top-level submission for draw prep (`DrawPreparation::BeginSubmission`/`Enqueue`), hands it to the workers under the queue lock.
2. Draw-prep workers (`WorkerLoop`, SCHED_IDLE): build `PreparedDraw` pipeline keys and sharps; no Vulkan calls (vk_draw_prep.cpp has 6 Vulkan lines, none of them recording).
3. GPU command thread (stage A): PM4 decode, register file, pipeline selection (`GetGraphicsPipeline`), writes draw packets into `DrawPipe`; `Flush`, `Finish`, `OnSubmit`.
4. Draw recording thread (stage B, `DrawPipe::OnStageB`, `RunDrawPacket`): owns caches, barriers and `DrawRecord`, `DispatchRecord`, `BindResources`, `BeginRenderingFull`.
5. Bind-helper workers: `RunTextureTask` computes texture descriptors in parallel for eligible draws (`HelperEligible`), joined by `JoinBindHelper`.
6. Recorder threads (`Scheduler::RecorderThread`, threaded recording): record the command buffers of `Record()` lambdas in direct or deferred segments.
7. Submit: `SubmitExecution` / `SubmitAsync` on the queue (scheduler, Vulkan only in form).
8. Priority ops thread (`PriorityPendingOpsThread`): runs `DeferPriorityOperation` work.
9. Signal thread: `Rasterizer::GpuSignalLoop` (own thread) waits on the work semaphore tick and runs the signal queue; `GpuWatchdog` checks for stalls.

## 6. DrawRecorder interface (the backend's recording side)

Methods the neutral core would call (Vulkan: `vk_draw_recorder`; Metal: its encoder version):
1. `BeginPass(const RenderState&)`, `EndPass()`, `IsPassOpen()`, `PassSerial()`.
2. `BindGraphicsPipeline(handle)`, `BindComputePipeline(handle)`.
3. `SetDynamicState(snapshot)` (viewports, scissors, depth, stencil, cull, front face, blend, colour write, line width, primitive restart, rasterizer discard, feedback loop).
4. `SetVertexInput(bindings, attributes)`, `BindVertexBuffers(buffers, offsets, sizes, strides)`, `BindIndexBuffer(handle, offset, type)`.
5. `BindResources(descriptor writes or argument data, push data, image and buffer infos)`, `BindSamplers(...)`.
6. `Draw(indexed, count, instances, first_vertex, first_instance, index_offset)`.
7. `DrawIndirect(indexed, args, offset, count buffer, count offset, max count, stride)`.
8. `Dispatch(x, y, z)`, `DispatchIndirect(args, offset)`.
9. `Barrier(src stage, src access, dst stage, dst access)` (memory-level; the image/buffer barriers stay in the cache backend).
10. `BeginHoist()`, `EndHoist()` (a dispatch placed before the open pass).
11. `Crumb(id, record function)` (breadcrumbs, optional).
12. `PushLabel(name, colour)`, `PopLabel()`, `InsertLabel(name, colour)` (markers).
13. `WriteBufferMarker(buffer, offset, value, portable)` (`WriteLabelOnGpu`).
14. Queries: `ResetQueries(pool, range)`, `BeginOcclusion(segment)`, `EndOcclusion(segment)`, `CopyQueryResults`, `WriteTimestamp(pool, index)`.
15. `SetPassLabel(vs hash, ps hash)`.

Non-recorder calls the core also needs (cache backend or frame sync): `FlushBarriers`, `Transit`,
`AccessBuffer`, `ClearImage`, `ResolveImage`, `CopyDepthStencil`, `KickRecording`, `Flush`, `Finish`,
`PopPendingOperations`, `DeferOperation`, host-copy notes.

## 7. Options and duplication

Neutral lines (N plus estimated neutral parts of M), by file:
- rasterizer: N 2,502 + M neutral about 1,320 (M-easy about 520, M-medium about 555, M-hard about 245) = about 3,820 of 4,849;
- draw pipe, draw prep, bind helper: 264 + 675 + 122 = 1,061 (no Vulkan);
- scheduler neutral: about 600 of 1,330;
- pipeline cache key building and stage selection: about 650 of 1,251 (`RefreshGraphicsKey`, `RefreshGraphicsStages`, `RefreshComputeKey`, `GetGraphicsPipeline`, `TryPreparedPipeline`, `AsyncSkippable`);
- HLE copy selection: about 250 of 301.
Total: about 6,400 lines (±500). Barrier tracker (505 lines) adds about 500 if Metal copies the Vulkan barrier model; the D7 hazard-tracked plan does not need it.

Option 1 (shared `RasterizerCore` + backend `DrawRecorder`): the about 6,400 lines move once into a
shared core (a commit per step, Vulkan image and bench verified). Vulkan keeps about 1,000 lines of
rasterizer recording (`vk_draw_recorder.cpp`, the V and M-V parts) and about 700 lines of scheduler
recording; Metal writes its own recorder (estimate 1,000 + 700 lines). Shared state (`RenderState`, `PreparedDraw`,
`VertexBinds`) needs the vocabulary types or neutral equivalents (`vk::Format` stays; `vk::Buffer`
handles become a backend handle). Virtual calls: about 15 to 25 per draw, acceptable (the cache design already accepts a few virtual calls per draw).
Risks: `Rasterizer` is a friend of `BufferCache`, and the HLE and occlusion helpers take `Rasterizer&`;
the core has to own the stage A/B state (`vk_rasterizer.h:616` on), so the split is a class split, not a file move.

Option 2 (Metal rasterizer copies the neutral logic): duplicates about 6,400 neutral lines in
`renderer_metal/`, plus the same Vulkan-only recording of about 1,700 lines re-written in Metal
(plus the scheduler about 700). Every later fix in the stage A/B protocol, label semantics or memory notes
must land twice. This contradicts D3 ("shared, not copied"), so it is listed only for the comparison.

## 8. The five hardest mixed functions

1. `BeginRenderingFull` (4052-4378, 326 lines, 32 Vulkan lines): per-attachment loop mixes
   scene-target and proxy decisions (reduced pass, MRT mask, colour samples) with `runtime.Transit` barriers,
   `vk::ImageLayout` choice (feedback loop), `RenderAttachment` and clear value construction, and
   framebuffer limits from `instance`. No clean cut between the decision and its barrier.
2. `BindTextures` (3533-3819, 287 lines, 21 Vulkan lines): one loop per image does the descriptor array
   sizing (mip-array emulation), proxy eligibility, the `Transit` with a layout chosen per usage, and the
   `vk::WriteDescriptorSet`; a second pass re-binds updated images; the texture-set memo stores `vk::ImageView`.
3. `HoistDispatch` (2153-2309, 156 lines, 29 Vulkan lines): the decision (held pass, image and buffer
   overlap, pending image barriers, `HasPendingImageBarriers`) reads layouts and then records the
   before/after `pipelineBarrier2` pair around the dispatch inside `BeginHoist`/`EndHoist`; the diagnostics
   print `vk::to_string` of formats and layouts.
4. `DrawRecord` (1576-1861, 286 lines, 12 Vulkan lines): the neutral prep (motion, upscaler, `BindResources`,
   draw inputs) and the recording tail (`bindPipeline`, `drawIndexed`, `RecordCrumb`) share `needs_barrier`,
   `bind_prepared` and the pass state; the tail must stay in the same call to keep the stage B ordering.
5. `ResolveVertexBuffers` (2825-2990, 165 lines, 5 Vulkan lines plus Vulkan-typed `VertexBinds`):
   stream range merging and mapping is neutral; the output arrays are `vk::Buffer`, `vk::DeviceSize`, and
   vertex-input descriptions, and the object-motion research hook reads them. It needs a neutral host
   buffer reference before it can be shared.

Next in line: `BindBuffers` (3314-3492, descriptor write block 3480-3492) and `UpdateViewportScissorState`
(4647-4791, `vk::Viewport` math), both medium.

## 9. Not found

- `vk_bind_helper.cpp` and `vk_constant_ring.cpp` do not exist (the classes are header-only or implemented
  elsewhere); the counts for these two headers are header counts only.
- No Vulkan call is made from `vk_draw_pipe.h`, `vk_draw_prep.*`, `vk_barrier_tracker.*` or `vk_bind_helper.h`.
- Line counts in section 2 are body lengths from function definition to the next definition; they include
  blank lines and comments between functions, so the totals may be a few lines high.
