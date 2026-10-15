# Metal scheduler and runtime (plan P4.2, D6–D8)

Status: design 2026-10-14. Implements what the shared core (`RasterizerCore`) and the shared
caches (`CacheBackend`) expect from a backend's scheduler, with the Vulkan scheduler's semantics.
Metal 3 command model (D7).

## Threads and recording

- Encoding is immediate, on the thread that calls the recording hooks and `CacheBackend` methods
  (the draw recording thread with the draw pipe, else the GPU command thread) — the same threads
  that record on Vulkan. No recorder threads, no deferred segments: `IsRecordingDeferred()` is
  false, so the caches run host copies at once (`RecordHostCopy` callers' immediate path), and
  `KickRecording`/`SyncRecording` are no-ops. (Parallel encoding is P6.5.)
- One open `MTLCommandBuffer` at a time (`commandBufferWithUnretainedReferences`), created
  lazily; at most one open encoder (render, compute or blit); asking for another kind ends the
  open one. `EndRendering` ends a render encoder.

## Ticks, submission, waits

- A tick is the sequence number of a command buffer; the open one has `CurrentTick()`
  (starting at 1). `Flush()`: end the open encoder, `encodeSignalEvent:tick` on one
  `MTLSharedEvent`, add a completed handler (records errors, see below), `commit`, advance the
  tick. `Finish()` = `Flush()` + `Wait(tick)`.
- `IsFree(tick)`: `tick <= known_tick`, refreshing `known_tick` from `event.signaledValue` when
  not. `IsFreeKnown` without the refresh. `RefreshTicks` reads the event.
- `Wait(tick)`: flushes first when `tick` is the open command buffer, then
  `waitUntilSignaledValue:timeoutMS:` in a loop (bounded waits, so stop requests and the
  watchdog work as with the Vulkan semaphore wait). `WaitGpuTick(tick, timeout)` (the core's
  signal loop hook) is one bounded wait.
- Errors: the completed handler checks `status`/`error` (with
  `MTLCommandBufferErrorOptionEncoderExecutionStatus` on the descriptor); a failed command buffer
  reports through the breadcrumb/device-lost path and asserts, as a lost Vulkan device does.

## Deferred operations and lifetime (D6)

- `DeferOperation(f)` queues `f` with the open tick; `PopPendingOperations` runs every queued
  operation whose tick is free (also called at each `Flush`). `DeferPriorityOperation` runs on a
  priority thread that waits on the event.
- Every destroy of a GPU object (buffer, texture, view, sampler, pipeline state the caches drop)
  is deferred to the open tick, and runs once the tick's command buffer has *completed* (its
  completed handler ran), not merely once the event is signalled — the signal is the command
  buffer's last command, but Metal retires the buffer slightly later and the debug layer reports
  objects released in between (P4.2a finding): with unretained references nothing else keeps an object alive
  while a committed command buffer may still use it. Residency-set removal happens in the same
  deferred operation.

## Hazards (D7: tracked resources first)

- Buffers and textures are created hazard-tracked; Metal orders encoders and command buffers for
  resources bound directly. Accesses through device addresses (`gpuAddress`, the
  `bda_pagetable` path most of the game's shaders use) are not tracked.
- The shared code already reports what needs ordering (`AccessBuffer`, `AccessGlobal`,
  `Transit`, then `FlushBarriers`). On `FlushBarriers` with pending accesses: inside a compute
  encoder `memoryBarrierWithScope:(Buffers|Textures)`; inside a render encoder
  `memoryBarrierWithScope:afterStages:beforeStages:`; across encoders a ring of 8 `MTLFence`s
  (implemented this way in P4.2a: every encoder updates the next slot at its end; a barrier
  inside an encoder also waits mid-encoder on the slots not yet waited; a barrier with no encoder
  open makes the next encoder wait on all outstanding slots first) — a conservative
  serialization that P6.4 replaces with precise fences. Image layouts are bookkeeping
  only (`Transit` records state, no Metal call).

## Labels and fences (D8)

- `SignalAfterGpu` stays the core's (signal queue + loop with the `WaitGpuTick` hook).
- `RecordBufferMarker` (GPU-written labels) is not implemented at first: `WriteLabelOnGpu`
  returns false and the label is written by the signal loop once the GPU is done (honest labels
  on the CPU). A GPU write (tiny compute kernel or blit from a constant buffer) is a P6 option.
- Occlusion queries: visibility result buffer per pass (P4.3), results copied where the Vulkan
  path copies query results.

## Pieces

- `renderer_metal/mtl_scheduler.{h,mm}`: command buffers, encoders, ticks, waits, deferred and
  priority operations, fence chain, error reporting.
- `renderer_metal/mtl_cache_backend.{h,mm}` (`Metal::Runtime : VideoCore::CacheBackend`, P2.4):
  objects (buffers incl. guest-chunk buffers from `Metal::GuestMemory`, textures, views with
  `VkToMtl::ComposeSwizzle`, samplers), transfers on blit encoders, staging ring, the caches'
  kernels from the D11 host shaders, limits, deferred destroys.
- `Metal::Rasterizer : VideoCore::RasterizerCore` with the recording hooks (P4.3), after R4–R6.
