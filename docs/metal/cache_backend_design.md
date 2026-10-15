# CacheBackend: the seam under the buffer and texture caches (plan P2.3, D2)

Status: design 2026-10-14; steps A–D below, each its own commit, each verified on Vulkan (bench
and title screenshot against the previous commit).

## Principles

- The caches (`video_core/buffer_cache/`, `video_core/texture_cache/`) stay one shared copy. They
  talk to the GPU only through `VideoCore::CacheBackend` (`video_core/cache_backend.h`), an
  abstract class. `Vulkan::Runtime` implements it (it already is the caches' transfer and barrier
  layer); the Metal backend implements it in `renderer_metal/mtl_cache_backend.*` (P2.4).
- Vulkan enums and plain structs are the shared vocabulary (`vk::Format`, `vk::BufferCopy`,
  `vk::BufferImageCopy`, `vk::ImageLayout`, `vk::PipelineStageFlags2`, `vk::AccessFlags2`,
  `vk::ClearValue`, `vk::ComponentMapping`, usage flags, `vk::ImageCreateInfo` as a description).
  Vulkan *handles and calls* (`vk::Device`, `vk::CommandBuffer`, VMA, `vk::Buffer` creation) are
  not used by shared code once step D is done.
- The shared GPU-object structs (`UniqueBuffer`, `UniqueImage`, `ImageView`, `Sampler`) keep their
  Vulkan handle members for the Vulkan backend and get one backend-neutral slot,
  `void* native` (a retained Metal object for the Metal backend, null for Vulkan). Creation and
  destruction go through the backend, which fills either.
- Semantics are the Vulkan backend's: ticks are monotonically increasing submission counters,
  `IsFree(tick)` means the GPU finished everything up to it, deferred operations run when a tick's
  work is done or at `PopPendingOperations`. The Metal backend reproduces them (completion
  handlers and an `MTLSharedEvent`; D6/D7).
- No behaviour change on Vulkan in any step: methods move, their bodies do not change.
- Hot paths: virtual calls are fine (a few per draw); per-byte or per-page work stays in the
  caches.

## Method groups

A. Transfers, synchronization, limits (from `Vulkan::Runtime`, the `Scheduler` subset the caches
   use, and `Instance` queries):
   - transfers: `CopyBuffer`, `FillBuffer`, `InlineData`, `UpdateBuffer`, `CopyFromGuestChunk`
     (source named by the chunk's physical address, the backend finds its own chunk buffer),
     `UploadImage`, `DownloadImage`, `CopyImage`, `CopyImageWithBuffer`, `CopyMip`,
     `CopyColorAndDepth`, `CopyDepthStencil`, `ResolveImage`, `ClearImage`, `SetBackingSamples`;
   - access tracking: `AccessBuffer`, `IsBufferAccessed`, `AccessGlobal`, `Transit`,
     `FlushBarriers`, `FlushImageBarriers`, `BeforeImageAccess`;
   - staging: `StagingRequest` / `StagingFreeDeferred` (what the caches use of
     `StagingBufferPool`), returning a `Buffer*`, offset and mapped pointer;
   - ticks and ordering: `CurrentTick`, `IsFree(tick)`, `RefreshTicks` (today
     `GetWorkSemaphore()->Refresh()`), `Wait(tick)`, `Finish`, `DeferOperation`,
     `DeferPriorityOperation`, `PopPendingOperations`, `EndRendering`, `IsRendering`,
     `IsRecordingDeferred`, `NoteHostCopySource`, `RecordHostCopy`, debug crumbs (no-op
     allowed);
   - limits and queries: one `BackendLimits` struct filled once (alignments, non-coherent atom,
     sampler LOD bias/anisotropy limits, max sampler count, integrated, feature booleans the caches
     test), `SupportedFormat(format, features)`, memory budget/usage queries.
B. Objects: `CreateBuffer` / `ImportBuffer` (over a guest chunk) / `DestroyBuffer`,
   `FlushBuffer` / `InvalidateBuffer`, device address; `CreateImage` / `DestroyImage`, supported
   sample counts and format features for an image description; `CreateImageView` /
   `DestroyImageView`; `CreateSampler` / `DestroySampler`; debug names. Done: the shared
   objects keep their Vulkan members and gain `owner` + `native`. `UniqueImage` keeps a direct
   Vulkan path (`owner == nullptr`, `Vulkan::CreateVmaImage`) for the Vulkan-only host passes
   (upscalers, scene resolution, object motion; D10 gives Metal its own MetalFX path).
C. The caches' own GPU work: detiling and tiling (`TileManager`), fault-buffer parsing
   (`FaultManager`), blits and MSAA depth copies (`BlitHelper`) become backend-provided services
   behind the interface (Vulkan keeps today's SPIR-V pipelines in `renderer_vulkan/`; Metal uses
   the D11-generated MSL). The tiling pipeline keys and dispatch sizes stay shared.
D. Vulkan-only memory paths move into the Vulkan backend behind an optional interface (null on
   Metal): the sparse arena and residency allocator (`buffer_cache.cpp` sparse binds, 64 MiB
   residency blocks, `VkDeviceMemory`-keyed maps), `FastReadback` (its own queue and fence).
   Metal uses the layer-memory path (`BB_LAYER_MEMORY=1`, the macOS default); where the caches
   branch on these paths they ask the backend. The layer's memory module
   (`layer/bblayer_gpu_memory.h`, `BbLayer::GpuMemory`: guest sources and VRAM mirrors, the
   lookups behind the `bda_pagetable` that 364 of the game's 425 cached shaders read through)
   is shared logic with Vulkan handles in its structs: its sources become a neutral reference
   (`const VideoCore::Buffer*` or an opaque handle) plus the device address (Vulkan buffer device
   address, Metal `gpuAddress`), and the guest chunks register through the backend (Vulkan:
   `BbGuestMemory`, Metal: `Metal::GuestMemory`).

After D the caches hold `VideoCore::CacheBackend&` only (no `Vulkan::Instance&`,
`Vulkan::Scheduler&`, `Vulkan::Runtime&`), and `grep -n "vk::Device\|vma\|cmdbuf\|GetDevice"`
over the caches is empty.
