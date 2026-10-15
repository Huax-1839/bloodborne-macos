# Sharing the buffer and texture caches between Vulkan and Metal

Scope: `gpu/shadps4/video_core/buffer_cache/*` and `gpu/shadps4/video_core/texture_cache/*`.
Method: grep sweep of every file and reading of the Vulkan-touching sites. Category counts come
from a regex classifier (first match wins: transfer > sync > compute > memory > format > create),
so they are approximate (about +/-20 %). Line numbers are exact. `runtime_memory_vma_info` and
`runtime_memory_direct_phys` are bbport mach-VM shim queries, not VMA; they are excluded.

Categories: a create/destroy · b transfer recorded · c compute/draw by the cache · d sync (barriers,
ticks, waits, deferred work) · e format/usage/limits · f host memory, guest import, sparse/residency,
staging · g other (type refs, includes, debug names, asserts, logs).

## 1. Per file

| File | Lines | Vk lines | a | b | c | d | e | f | g |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| buffer_cache/buffer_cache.cpp | 3650 | 219 | 8 | 32 | 5 | 65 | 8 | 61 | 40 |
| buffer_cache/buffer_cache_layer.cpp | 1590 | 30 | 0 | 11 | 0 | 7 | 0 | 9 | 3 |
| buffer_cache/buffer_cache.h | 627 | 20 | 0 | 1 | 0 | 5 | 0 | 9 | 5 |
| buffer_cache/buffer.cpp | 367 | 83 | 10 | 0 | 6 | 5 | 7 | 21 | 34 |
| buffer_cache/buffer.h | 232 | 32 | 0 | 0 | 1 | 0 | 5 | 5 | 21 |
| buffer_cache/fault_manager.cpp | 185 | 62 | 0 | 0 | 26 | 25 | 0 | 0 | 11 |
| buffer_cache/fault_manager.h | 42 | 5 | 0 | 0 | 1 | 2 | 0 | 0 | 2 |
| buffer_cache/memory_tracker.h, range_set.h, region_manager.h, region_definitions.h | 938 | 0 | | | | | | | |
| texture_cache/texture_cache.cpp | 1440 | 45 | 0 | 9 | 0 | 13 | 9 | 8 | 6 |
| texture_cache/texture_cache.h | 460 | 8 | 0 | 0 | 0 | 1 | 1 | 0 | 6 |
| texture_cache/image.cpp | 351 | 92 | 9 | 0 | 3 | 11 | 45 | 2 | 22 |
| texture_cache/image.h | 203 | 32 | 2 | 0 | 2 | 4 | 3 | 0 | 21 |
| texture_cache/image_view.cpp | 157 | 35 | 3 | 0 | 1 | 0 | 26 | 0 | 5 |
| texture_cache/image_view.h | 59 | 5 | 0 | 0 | 0 | 0 | 2 | 0 | 3 |
| texture_cache/sampler.cpp | 74 | 19 | 3 | 0 | 0 | 0 | 11 | 0 | 5 |
| texture_cache/sampler.h | 39 | 4 | 0 | 0 | 0 | 0 | 0 | 0 | 4 |
| texture_cache/image_info.cpp | 312 | 4 | 0 | 0 | 0 | 0 | 3 | 0 | 1 |
| texture_cache/image_info.h | 95 | 2 | 0 | 0 | 0 | 0 | 1 | 0 | 1 |
| texture_cache/tile_manager.cpp | 342 | 75 | 0 | 5 | 37 | 22 | 0 | 3 | 8 |
| texture_cache/tile_manager.h | 72 | 13 | 0 | 1 | 6 | 2 | 0 | 1 | 3 |
| texture_cache/blit_helper.cpp | 437 | 161 | 20 | 0 | 48 | 34 | 21 | 0 | 38 |
| texture_cache/blit_helper.h | 63 | 16 | 0 | 0 | 6 | 2 | 3 | 0 | 5 |
| texture_cache/host_compatibility.cpp | 220 | 155 | 0 | 0 | 0 | 0 | 155 | 0 | 0 |
| texture_cache/host_compatibility.h | 16 | 2 | 0 | 0 | 0 | 0 | 1 | 0 | 1 |
| texture_cache/tile.h, types.h | 448 | 0 | | | | | | | |

Totals: 12419 lines (buffer_cache 7631, texture_cache 4788); 1119 Vulkan-touching lines (9 %;
buffer_cache 451, texture_cache 668). By category: a 55, b 59, c 142, d 198, e 301 (146 without
host_compatibility.cpp), f 119, g 245.

## 2. Operations per category

Vulkan surface: `vk::` types and enums (about 1000 tokens), `Vulkan::Instance` (29), `Scheduler` (18), `Runtime` (12), `Check` (14), `SetObjectName` (13), `CompileSPV` (6), raw VMA (about 40 sites).

Backend calls in the cache .cpp files (about 257 lines): `instance.` queries (GetDevice 34, alignments,
budget, readback queue, Is*Supported), `scheduler.` (CurrentTick 33, GetWorkSemaphore 9, IsFree 6, Wait 5,
EndRendering 5, DeferOperation 5, host-copy notes 4, Finish 3, crumbs 4), `runtime.` (CopyBuffer 11,
DownloadImage 4, GetStagingPool 4, AccessBuffer 3, UpdateBuffer 2, FillBuffer 2, FlushBarriers 2,
CopyFromGuestChunk 2, UploadImage, CopyMip, CopyImage, CopyColorAndDepth, BeforeImageAccess).

(a) Create and destroy
- VMA: vmaCreateBuffer / vmaDestroyBuffer (buffer.cpp:76,103; buffer_cache.cpp:190,246,263);
  vmaCreateImage / vmaDestroyImage (image.cpp:91,98,133); usage-to-flags mapping (buffer.cpp:35-65;
  image.cpp:110-127, dedicated-allocation threshold).
- Raw Vulkan: device.createBuffer, destroyBuffer, bindBufferMemory, getBufferAddress (buffer.cpp:117-193);
  createImageViewUnique (image_view.cpp:139); createSamplerUnique (sampler.cpp:66); image views in
  blit_helper.cpp.
- Pipelines and layouts: createDescriptorSetLayoutUnique, createPipelineLayoutUnique,
  createComputePipelineUnique (tile_manager.cpp:68,81,186; fault_manager.cpp:48,75,81); graphics
  pipelines in blit_helper.cpp (about 300-435); shader modules from CompileSPV, destroyed after use
  (tile_manager.cpp:153,192; fault_manager.cpp:61,84).
- Device memory: device.allocateMemory and freeMemory for residency blocks (buffer_cache.cpp:1609,
  1616, 1632, 1667, 1909).
- FastReadback owns a command pool, command buffer, fence and VMA buffer (buffer_cache.cpp:171-287).
- Debug names: Vulkan::SetObjectName, 13 sites (buffer.cpp:195,222,261; image.cpp:216;
  image_view.cpp:147; blit_helper.cpp:287,353,431; tile_manager.cpp:173; fault_manager.cpp:26,62,82).

(b) Transfers recorded
- Buffer to buffer: runtime.CopyBuffer (buffer_cache.cpp:936,1567,3163,3173; buffer_cache_layer.cpp:576,
  658,866,1052,1275); cmdbuf.copyBuffer in FastReadback (buffer_cache.cpp:207).
- Fill and inline update: runtime.FillBuffer (buffer_cache.cpp:640,3271); runtime.UpdateBuffer
  (buffer_cache.cpp:2461,2546); runtime.CopyFromGuestChunk (buffer_cache.cpp:2480,3177).
- Buffer and image: runtime.DownloadImage (texture_cache.cpp:135,157; tile_manager.cpp:291,319);
  runtime.UploadImage (texture_cache.cpp:1001).
- Image to image: runtime.CopyImage (texture_cache.cpp:589), CopyMip (571), CopyColorAndDepth (340).
- Copy structs: vk::BufferCopy (about 20 sites, e.g. buffer_cache.h:369; buffer_cache.cpp:807,1538,3091),
  vk::BufferImageCopy (texture_cache.cpp:110,142; buffer_cache.cpp:3296).

(c) Compute and draw issued by the cache
- Detiler: TileManager::GetTilingPipeline (tile_manager.cpp:89-194; 12 tiling SPIR-V kernels, specialization
  constants at 155-163, pipelines keyed by TilingKey in tile_manager.h:69); RecordTilingDispatch
  (tile_manager.cpp:196-223: bindPipeline, pushDescriptorSetKHR, dispatch).
- Fault parser: fault_manager.cpp:61-157 (push descriptors at 152, dispatch at 157).
- Blit helper: fullscreen draw (blit_helper.cpp:88-250; cmdbuf.draw at 145, 247; dynamic viewport and
  scissor at 137-143, 239-245); four SPIR-V shaders (255-258); MSAA depth pipelines (300-435).
- Host compatibility: no GPU work (table only).

(d) Synchronization
- Ticks and waits: CurrentTick, GetWorkSemaphore IsFree and Refresh, Wait, Finish, IsFree across buffer_cache.cpp
  (733-1392, 1852-1914, 823, 842, 918, 937) and texture_cache.cpp:159, 1429; buffer_cache_layer.cpp:581, 697, 707.
- Deferred work: DeferOperation (fault_manager.cpp:165; blit_helper.cpp:88, 190; texture_cache.cpp:169, 1429).
- Host-copy notes: NoteHostCopySource and RecordHostCopy (buffer_cache.cpp:670-685, 1349, 3228).
- Pass boundaries: EndRendering (fault_manager.cpp:143; tile_manager.cpp:254; texture_cache.cpp:992; blit_helper.cpp:147, 249).
- Barriers: Image::GetBarriers (image.cpp:245-330; image.h:133-135, 181-183); AccessBuffer (tile_manager.cpp:273, 277, 337);
  FlushBarriers (tile_manager.cpp:255, 320); BeforeImageAccess (buffer_cache.cpp:3291); pipelineBarrier2 (fault_manager.cpp:146, 159).
- Readback fence: submit2, waitForFences, resetFences on the readback queue (buffer_cache.cpp:200-237, 286, 825-829, 915-923).
- Sparse binds: SubmitPendingArenaBinds with BindSparseInfo and timeline semaphore (buffer_cache.cpp:3498-3577; buffer_cache.h:172-173, 477).
- Crumbs: fault_manager.cpp:145; blit_helper.cpp:104.

(e) Format, usage, limits
- Format derivation: ConvertPixelFormat from VideoOut to vk::Format (image_info.cpp:19-33);
  LiverpoolToVK::SurfaceFormat, DepthFormat, PromoteFormatToDepth, ComponentMapping (image_info.cpp:60,
  89, 121, 123; image_view.cpp:57-84). Table file: renderer_vulkan/liverpool_to_vk.h (121 lines).
- Compatibility: IsVulkanFormatCompatible with a 155-line FORMAT_TABLE keyed by vk::Format
  (host_compatibility.cpp:55-211; used at texture_cache.cpp:401, 662; image_info.cpp:148-149).
- Support and caps: instance.GetSupportedFormat (image.cpp:175; image_view.cpp:124);
  getImageFormatProperties2 for sample counts (image.cpp:176-192).
- Usage and feature flags: ImageUsageFlags (image.cpp:22-47), FormatFeatureFlags (image.cpp:66-82),
  ImageCreateFlags (image.cpp:153-162), view usage (image_view.cpp:95-97).
- Sampler limits: anisotropy, LOD bias, custom border colour (sampler.cpp:14-55).
- Alignments: UniformMinAlignment (buffer_cache.cpp:1173; tile_manager.cpp:248, 310); StorageMinAlignment
  (buffer_cache.cpp:1188, 1331, 2517); NonCoherentAtomSize (buffer.cpp:258).
- Memory budget and integration: CanReportMemoryUsage and budget queries (buffer_cache.cpp:3613-3626;
  texture_cache.cpp:43-50, 1176-1213); IsIntegrated (buffer_cache.cpp:562; texture_cache.cpp:1188).

(f) Host memory, guest import, sparse and residency, staging
- Guest import: Buffer ctor from vk::DeviceMemory with VkExternalMemoryBufferCreateInfo (buffer.cpp:162-196; buffer_cache.cpp:2168, 2197).
- Sparse probe: eSparseBinding and eSparseResidency flags, memory requirements, block size (buffer_cache.cpp:592-640; buffer.cpp:110-113).
- Residency allocator: 64 MiB blocks, AllocateResidency (buffer_cache.cpp:1570-1690), ReleaseResidencySlot and compaction (1796-1914).
- VkDeviceMemory-keyed maps (buffer_cache.cpp:1679-1899; buffer_cache.h:538, 597-599); SparseMemoryBind arrays (buffer_cache.h:252; about 10 sites).
- Staging: GetStagingPool (buffer_cache.cpp:556; texture_cache.cpp:141; tile_manager.cpp:252); Request and FreeDeferred (texture_cache.cpp:179; buffer_cache.cpp:932, 1330, 3191).
- VMA flush and invalidate (buffer.cpp:242, 249; buffer_cache.cpp:236); StreamBuffer ring (buffer.h:173-220).
- Memory-type selection: FindMemoryType (buffer_cache.cpp:538-550, 617-628); MemoryType enum (buffer.h:66-70).
- Chunk mirrors and BDA page table: buffer_cache_layer.cpp:561-581, 857-873, 996-1052, 1175-1188; buffer_cache.cpp:639-640, 1538-1567.

(g) Other: Vulkan::Check (14), vk::to_string in asserts and logs (about 24), `<vk_mem_alloc.h>` includes (4 files), Runtime* back-pointer in Image (image.h:173; image.cpp:239).

## 3. Vulkan-typed members in shared data structures

- `Buffer` (buffer.h:112-116): vk::Buffer, vk::DeviceAddress, VmaAllocation, vk::Device; Handle() used by all callers.
- `Image` (image.h:79-84, 175-183): vk::Image, vk::ImageCreateInfo, Vma allocation, usage and format-feature flags,
  sample counts, barrier state (stage, access, layout); `operator vk::Image()` (image.h:70).
- `ImageInfo` (image_info.h:69): `vk::Format pixel_format`, hashed and matched in cache keys (texture_cache.cpp:606, 623-628, 662).
- `ImageViewInfo` (image_view.h:34-36): vk::Format and vk::ComponentMapping, both in the key.
- `TextureCache` lookup struct (texture_cache.h:437): vk::Format. `Sampler` (sampler.h:36): vk::UniqueSampler.
- `BlitHelper` (blit_helper.h:28-58), `TileManager` (tile_manager.h:56-69), `FaultManager` (fault_manager.h:37-39):
  pipelines, layouts, descriptor layouts; vk::Format in MsPipelineKey.
- `BufferCache` (buffer_cache.h:447-599): Vulkan::Instance&, Scheduler&, Runtime&, StagingBufferPool&,
  Vulkan::Semaphore memory_semaphore, vk::DeviceMemory residency, VkDeviceMemory-keyed chunk map, SparseMemoryBind vectors.

## 4. Backend-neutral parts

Zero Vulkan lines (1386): memory_tracker.h, range_set.h, region_manager.h, region_definitions.h, tile.h, types.h.
Near-zero: image_info.h/.cpp (2 and 4 lines), buffer_cache_layer.cpp (30 of 1590; chunk mirrors, retire and
write-trap logic is neutral), texture_cache.cpp (45 of 1440; overlap, merge, lookup), buffer_cache.h (20),
texture_cache.h (8), image_view.h (5), sampler.h (4). Tick bookkeeping in buffer_cache.cpp:68-130 is plain u64.

Vulkan-keyed but easy to re-key: host_compatibility.cpp (one table keyed by vk::Format) and
renderer_vulkan/liverpool_to_vk.h.

## 5. Interface estimate

Interface `CacheBackend` (or two: resource and command), 35 signatures before merging, about 25 after
merging the copy and blit overloads:

Create and destroy (a, f):
1. create buffer: size, MemoryType, usage class, sparse flag, debug name; returns handle and device address.
2. import buffer over backend memory: memory handle, size, offset.
3. create image: native format, extent, mips, layers, samples, usage flags.
4. create image view: image, view description.
5. create sampler: sampler description.
6. allocate memory block and free it (deferred): size, memory type.
7. release resource at tick: handle, tick (replaces every destroy and deferred free).
8. set debug name: handle, format string.
9. device address of buffer: handle.

Transfers (b):
10. copy buffer to buffer: source, destination, span of copies.
11. fill buffer: buffer, offset, size, value.
12. update buffer: buffer, offset, bytes.
13. copy between buffer and image: direction, buffer, image, span of buffer-image copies.
14. copy image to image: source, destination, optional mip and slice or regions.

Cache-issued compute and draw (c):
15. run compute kernel: kernel id (detiler variant or fault parser), bindings, group counts.
16. blit or resolve: source view, destination view, filter or MSAA mode.

Synchronization (d):
17. current tick; 18. is tick done; 19. wait for tick; 20. finish submission.
21. defer until tick: callback.
22. record access on buffer range: buffer, offset, size, stage, access.
23. record access on image subresource: image, subresource, layout, stage, access.
24. flush recorded accesses.
25. end current pass (render encoder).
26. readback to host: buffer ranges, copies, tick; returns mapped pointer.
27. note host copy source: pointer, size.

Formats and limits (e):
28. native pixel format from neutral format id.
29. formats compatible: format a, format b.
30. supported format and sample counts: format, usage or features.
31. device limits: alignments, anisotropy, LOD bias, border colour, sampler count.
32. memory budget and integration: usage, budget, integrated flag.

Host memory (f):
33. staging request: size, memory type, alignment; returns buffer, offset, mapped pointer; deferred free.
34. flush and invalidate range: buffer, offset, size.
35. bind and unbind sparse range: buffer, offset, memory, memory offset, size (Metal may leave it unimplemented).

Call sites that change: about 257 backend-call lines (about 200 become interface calls); about 150 Vulkan
struct-construction lines (create infos, barriers, copy structs, descriptor writes) move into the backend;
about 200 format and usage lines change type; about 45 constructor and member sites take Vulkan classes.

## 6. Obstacles

1. Vulkan handles in keys and maps: ImageInfo.pixel_format (texture_cache.cpp:606-662) and residency maps
   keyed by VkDeviceMemory (buffer_cache.cpp:1679-1913). Fix: neutral PixelFormat and u64 handle ids first.
2. Sparse binding has no Metal buffer equivalent (buffer_cache.cpp:592-640, 3498-3577, about 10
   SparseMemoryBind sites). Residency bookkeeping is portable, the binding step is not. The non-sparse
   layer path exists (BB_LAYER_MEMORY=1, buffer_cache.cpp:583-588). Images do not use sparse binding.
3. FastReadback (buffer_cache.cpp:171-287) has its own queue, pool, fence and CPU wait, bypassing the
   scheduler. Metal needs its own queue or a blit plus completion wait (D7).
4. Image::GetBarriers (image.cpp:245-330) tracks VkImageLayout; Metal has no layouts, so keep only the
   access tracking. Tracked versus untracked hazard mode is a D7 decision, since untracked resources need fences.
5. Tick semantics: about 60 sites rely on a monotonic tick with IsFree and Wait. A Metal shared event or
   completion counter must provide the same contract.
6. VMA logic (buffer.cpp:35-150; image.cpp:110-137: usage mapping, dedicated threshold, budget flags,
   flush and invalidate) maps to Metal storage modes. One localised seam.
7. Shaders and descriptors: tiling (12 kernels plus micro variants), fault parser and blit shaders are SPIR-V
   via CompileSPV (tile_manager.cpp:153; fault_manager.cpp:61; blit_helper.cpp:255-258). Metal needs MSL from
   D11, function constants for specialization, and setBuffer or argument buffers for push descriptors.
8. Blits use dynamic-rendering attachments (blit_helper.cpp:88-148, 300-435): Metal render-pipeline descriptors
   per attachment format.
9. host_compatibility.cpp encodes Vulkan's format compatibility classes (155 entries). A Metal table must be
   written from MTLPixelFormat rules and checked against the Vulkan table.
10. Guest import (buffer.cpp:162-196; buffer_cache.cpp:567, 2161-2197) belongs to D6; the cache does not decide
    how host memory maps to Metal buffers.
11. Ownership: vk::Unique* members die with the device. Metal objects are Objective-C, so shared headers need
    opaque handles (CLAUDE.md rule), i.e. a pimpl or backend-owned object per type.
12. Dispatch: constructors take concrete Vulkan classes. Sharing needs a virtual interface (per-call cost)
    or a template over the backend (code duplicated). Backend-typed templates were not swept.
13. Plan discrepancy: D2 rejects a HAL under the caches with "~40k lines". These directories hold 12.4k lines,
    of which 1119 (9 %) touch Vulkan. Recheck D2 against these numbers.
14. Log and assert text (vk::to_string, Render_Vulkan class, about 40 sites) needs neutral names. Cosmetic.
