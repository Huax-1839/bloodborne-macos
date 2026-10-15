# Seam inventory: outside code that touches the Vulkan backend (P1.1)

Scope: every use of `Vulkan::`, `vk::`, `renderer_vulkan/`, `texture_cache/`, `buffer_cache/`
outside `gpu/shadps4/video_core/{renderer_vulkan,texture_cache,buffer_cache}/`, in `.cpp/.h/.mm/.inc`,
skipping `gpu/third_party/`. Line numbers are at commit 0ad6c27 plus the working tree as of this scan.
"Hits" per file = lines matching the broad pattern `Vulkan::|renderer_vulkan|texture_cache|buffer_cache|vk::|Rasterizer|rasterizer|Presenter|presenter|PageManager` (501 lines in 22 files).

## Totals

- Distinct `Vulkan::Rasterizer` instance methods called from outside: **59** (liverpool.cpp, page_manager.cpp, bbgpu.cpp). Plus 2 statics: `Rasterizer::HonestLabels()` (10 sites), `Rasterizer::OcclusionTranslated()` (1 site).
- Distinct `Vulkan::Presenter` methods called from outside: **9** (`RegisterVideoOutSurface, SetHDR, Present, WaitRendered, PrepareBlankFrame, PrepareLastFrame, PrepareFrame, IsHDRSupported, GetPPSettingsRef`), plus its constructor.
- Other `Vulkan::` symbols used outside: 11 distinct (Instance, Scheduler, Frame, FrameCapture, VmaDeviceUsage, Breadcrumbs, DrawPipe, DrawPreparation, g_bb_* globals, and the Rasterizer/Presenter above).
- `vk::` uses outside: **144** (bbport_guest_memory.cpp 122, bbport_overlay.cpp 10, imgui headers 6, bbport_guest_memory.h 3, bbport_overlay.h 2, core/debug_state.h 1).
- Outside files that include a Vulkan backend header, a cache header, or a Vulkan SDK header: **19**.
- Outside files that call into `TextureCache` / `BufferCache` directly: **0**. Outside code calls `PageManager` once (static `ReportFaultSites`).

## Outside files by hits (top 22, all files with hits)

| file | hits |
|---|---|
| gpu/shadps4/video_core/amdgpu/liverpool.cpp | 228 |
| gpu/shim/bbport_guest_memory.cpp | 129 |
| gpu/shadps4/video_core/page_manager.cpp | 33 |
| gpu/shadps4/core/libraries/videoout/driver.cpp | 33 |
| gpu/shim/bbport_overlay.cpp | 13 |
| gpu/shim/bbgpu.cpp | 10 |
| gpu/shim/bbport_guest_memory.h | 7 |
| gpu/shadps4/core/libraries/gnmdriver/gnmdriver.cpp | 6 |
| gpu/shadps4/video_core/page_manager.h | 5 |
| gpu/shadps4/video_core/amdgpu/liverpool.h | 5 |
| gpu/shim/imgui/renderer/texture_manager.h | 4 |
| gpu/shim/imgui/renderer/imgui_core.h | 4 |
| gpu/shim/core/memory.h | 4 |
| gpu/shim/bbport_overlay.h | 4 |
| gpu/shadps4/core/libraries/videoout/video_out.cpp | 4 |
| gpu/shadps4/core/libraries/videoout/driver.h | 4 |
| gpu/shim/core/debug_state.h | 2 |
| gpu/shadps4/video_core/cache_storage.cpp | 2 |
| gpu/shim/bbport_toggles.h | 1 (comment only) |
| gpu/shadps4/video_core/renderdoc.h | 1 (comment only) |
| gpu/shadps4/shader_recompiler/ir/passes/shader_info_collection_pass.cpp | 1 (include only) |
| gpu/bbgpu.h | 1 (comment only) |

## 1. Rasterizer

Callers are `rasterizer->` / `rasterizer.` in liverpool.cpp (`Rasterizer*` member and `Rasterizer&` parameters of PM4 handlers), `r.` / `self.` inside `RunInOrder` lambdas, `rasterizer->` in page_manager.cpp, `r->` / `rasterizer->` in bbgpu.cpp.

| method/symbol | callers (file:line) | note |
|---|---|---|
| CopyBuffer | liverpool.cpp:533,543,549,596,686,2406,2416,2432,2642 | DMA copy, GDS copy |
| FillBuffer | liverpool.cpp:528,538,591,2401,2411 | DMA fill |
| Draw | liverpool.cpp:1669,1688,1705 | PM4 draw (indexed/auto) |
| DrawIndirect | liverpool.cpp:1724,1746,1770,1792,1815 | PM4 indirect draw |
| DispatchDirect | liverpool.cpp:1844,2503 | compute dispatch |
| DispatchIndirect | liverpool.cpp:1866,2485,2522 | compute dispatch indirect |
| ScopeMarker | liverpool.cpp:1668,1686,1704,1722,1744,1768,1790,1813,1843,1864,2501,2520 | debug marker wrapper around draw/dispatch |
| ScopeMarkerBegin | liverpool.cpp:1515 | debug marker |
| ScopedMarkerInsertColor | liverpool.cpp:1526 | debug marker (name is misspelled in the API) |
| ScopeMarkerEnd | liverpool.cpp:1532 | debug marker |
| GetDrawPreparation | liverpool.cpp:1377,2721 | returns `Vulkan::DrawPreparation*` (see Other symbols) |
| DrainDrawPipe | liverpool.cpp:111,276,1316,1485,2106,2143,2169,2332,2775 | draw pipe drain, takes `Vulkan::DrawPipe` reason |
| DrawPipeHead | liverpool.cpp:702,728 | position in the draw pipe |
| DrawPipeIdle | liverpool.cpp:139,2105,2168 | query |
| DrawPipeReached | liverpool.cpp:703,733 | query by position |
| SignalsPublished | liverpool.cpp:704,733 | fence/signal ordering |
| PipeSignals | liverpool.cpp:150,247,274,2762 | decides whether pipe-ordered signal path is used |
| PendingSignalValue | liverpool.cpp:746,750 | label read-back before GPU writes |
| RequestSignalFlush | liverpool.cpp:153 | submit request |
| Flush | liverpool.cpp:155,259,2110,2175,2561,2576,2777; lambda 254 (`r.Flush`) and 2770 (`self.Flush`) | submit current command buffer |
| HasUnsubmittedSignals | liverpool.cpp:139,2109,2174,2560,2575 | gate for Flush |
| OnSubmit | liverpool.cpp:258; lambda 253 (`r.OnSubmit`) | submission hook |
| SubmitForSignals | liverpool.cpp:2294; lambda 316 (`r.SubmitForSignals`) | submit signal work |
| RetireSubmission | liverpool.cpp:2288 | frees prepared draws after recording thread passes |
| RunInOrder | liverpool.cpp:251,310,1503,1894,1920,1936,1964,1986,2034,2061,2084,2095,2763 | runs a `void(Rasterizer&, const u8*)` callback in GPU-pipe order (the central sync hook) |
| WaitDeferredSignals | liverpool.cpp:277,314 (`r.`),490,525,587,600,635,678,1487,2530,2624 | wait for deferred signals |
| WaitHostCopies | liverpool.cpp:489,677,2529,2623 | wait for host-side copies |
| WaitHostCopiesFor | liverpool.cpp:524,586,633 | wait for copies over a range |
| WaitForPendingReads | liverpool.cpp:792 | dump-const read sync |
| SignalAfterGpu | liverpool.cpp:321,469,509,672,2554,2608,2776; lambdas 315 (`r.`), 2768 (`self.`) | callback when GPU work retires |
| SignalAfterHostCopies | liverpool.cpp:486 | callback when host copies finish |
| WriteLabelOnGpu | liverpool.cpp:464,667,2598 | EOP label write |
| WriteTimestampOnGpu | liverpool.cpp:451,609,2591 | EOP timestamp |
| WriteDataOnGpu | liverpool.cpp:613,625 | WRITE_DATA on GPU |
| ProcessDownloadImages | liverpool.cpp:445,666,679,2588,2635 | image readback before CPU read |
| DmaMayWriteOnCpu | liverpool.cpp:523,585 | query before DMA |
| NoteCommandWrite | liverpool.cpp:642,2540 | record CPU-visible command write |
| NoteCommandWriteInOrder | liverpool.cpp:802 | same, in pipe order |
| NoteLateCommandWrite | liverpool.cpp:425,656,1904; page_manager.cpp none | late write notify |
| NotePendingGpuWrite | liverpool.cpp:712,1968,1989,2036,2065,2087 | mark range as GPU-written pending |
| NotePendingRead | liverpool.cpp:1961,2081 | mark range as read pending |
| OcclusionEvent | liverpool.cpp:567 | ZPASS_DONE |
| OcclusionEvents | liverpool.cpp:1407 | occlusion counter read in a lambda |
| ReadDataFromGds | liverpool.cpp:691 | GDS read |
| ReadMemory | liverpool.cpp:1320; page_manager.cpp:344 | CPU read of GPU-owned memory (also called from the fault path) |
| Finish | liverpool.cpp:690,1318 | wait for all GPU work |
| CurrentTick | liverpool.cpp:2767 (`self.CurrentTick`) | timeline value for trace |
| IsGpuSideThread | page_manager.cpp:313 | fault-handler classification |
| IsGpuSideThreadId | page_manager.cpp:678 | same, by thread id |
| IsMapped | page_manager.cpp:379 | page-table query |
| OnVramDataAccess | page_manager.cpp:319 | fault handler: VRAM page access |
| OnOcclusionPageAccess | page_manager.cpp:322 | fault handler: occlusion page |
| OnWriteFault | page_manager.cpp:336,678 | fault handler: CPU write to watched page |
| RegisterMemory | bbgpu.cpp:100 | guest memory map hook |
| MapMemory | bbgpu.cpp:101 | guest memory map hook |
| UnmapMemory | bbgpu.cpp:103 | guest memory unmap hook |
| InvalidateMemory | bbgpu.cpp:105,118 | CPU-side invalidate |
| NoteAssetWrite | bbgpu.cpp:110 | asset write hook |
| OnCpuWrite | bbgpu.cpp:114 | libc memcpy/memset hook |
| HonestLabels (static) | gnmdriver.cpp:99; liverpool.cpp:138,287,449,455,504,664,744,2032,2586 | policy flag for label semantics (10 sites) |
| OcclusionTranslated (static) | liverpool.cpp:1892 | policy flag |

Binding sites (inside the backend, listed for context): `vk_rasterizer.cpp:77` `liverpool->BindRasterizer(this)`, `vk_rasterizer.cpp:80` `memory->SetRasterizer(this)`, `vk_presenter.h:133` owns `unique_ptr<Rasterizer>`, `vk_presenter.cpp:134` constructs it.

Declarations outside the backend: `amdgpu/liverpool.h:29,157-158,329` (`BindRasterizer`, member `Vulkan::Rasterizer* rasterizer`), `core/memory.h` (shim): `shim/core/memory.h:8,13,27,31` (`SetRasterizer`, `GetRasterizer`, member), `video_core/page_manager.h:13,32` (ctor takes `Rasterizer*`), `page_manager.cpp:294` (static member `inline static Vulkan::Rasterizer* rasterizer`), `page_manager.cpp:559,691,719` (ctors of the two fault impls and PageManager).

## 2. Presenter

| method/symbol | callers (file:line) | note |
|---|---|---|
| ctor `Presenter(window, liverpool)` | gnmdriver.cpp:3107 | created by gnmdriver init, owns the Rasterizer |
| global `std::unique_ptr<Vulkan::Presenter> presenter` | defined gnmdriver.cpp:33; `extern` at videoout/driver.cpp:38, videoout/video_out.cpp:16 | process-wide global, used by videoout |
| RegisterVideoOutSurface | videoout/driver.cpp:238 | buffer registration on flip port |
| SetHDR | videoout/driver.cpp:373 | HDR toggle, inside RunPresenter lambda |
| Present | videoout/driver.cpp:374,778,786 | present a `Frame` |
| WaitRendered | videoout/driver.cpp:735 | wait for frame render |
| PrepareBlankFrame | videoout/driver.cpp:777,820 | blank frame |
| PrepareLastFrame | videoout/driver.cpp:784 | repeat last frame |
| PrepareFrame | videoout/driver.cpp:825 | frame for a flip buffer address |
| IsHDRSupported | videoout/video_out.cpp:365 | HDR capability query |
| GetPPSettingsRef | videoout/video_out.cpp:404 | post-process gamma setting |

Note: `Vulkan::Frame` is the return type of `PrepareFrame` and is stored in the videoout request (see section 3).

## 3. Instance, Scheduler and other Vulkan:: symbols

| symbol | callers (file:line) | note |
|---|---|---|
| Vulkan::Instance (type, by reference) | shim/bbport_guest_memory.cpp:315,352,506,563,670,707; shim/bbport_guest_memory.h:32,36,49; shim/bbport_overlay.cpp:698; shim/bbport_overlay.h:22; shim/imgui/renderer/imgui_core.h:7; shim/imgui/renderer/texture_manager.h:7 | device handle source for shim code |
| Vulkan::Scheduler::submit_mutex (static) | shim/bbport_overlay.cpp:932 | overlay submit lock shared with the scheduler |
| Vulkan::Scheduler::direct_recordings | videoout/driver.cpp:580 | debug counter exchange |
| Vulkan::Scheduler::recorded_submissions | videoout/driver.cpp:695 | debug counter |
| Vulkan::Scheduler::recorded_segments | videoout/driver.cpp:696 | debug counter |
| Vulkan::Frame (type) | videoout/driver.h:17-18 (fwd decl), driver.h:100 (`Frame* frame` in request), driver.cpp:818 | presenter frame handle |
| Vulkan::FrameCapture::AddDisplayBuffer | videoout/driver.cpp:232 | RenderDoc-like capture of display buffers |
| Vulkan::FrameCapture::OnFlip | videoout/driver.cpp:376 | capture hook on flip |
| Vulkan::VmaDeviceUsage | videoout/driver.cpp:344 | memory stats print |
| Vulkan::g_bb_compiles (extern) | videoout/driver.cpp:43,521,578 | pipeline compile counter |
| Vulkan::g_bb_compile_ns (extern) | videoout/driver.cpp:42,579 | compile time counter |
| Vulkan::g_bb_flip_count | videoout/driver.cpp:575 | flip counter |
| Vulkan::Breadcrumbs::PrintProgress | videoout/driver.cpp:622 | GPU crash breadcrumbs print (include driver.cpp:33) |
| Vulkan::DrawPipe (enum reasons, `OnStageB()`) | liverpool.cpp:111,276,483,2332,2775 | reason argument for DrainDrawPipe, static gate at 483 |
| Vulkan::DrawPreparation* | liverpool.cpp:1376 | pointer type returned by GetDrawPreparation |
| Vulkan::Rasterizer (type) | see section 1 | |

## 4. vk:: types and functions outside the backend

| file | uses | note |
|---|---|---|
| shim/bbport_guest_memory.cpp | 122 | dma-buf and host-pointer import, device memory, device addresses, `vk::Buffer`, `vk::DeviceMemory` |
| shim/bbport_overlay.cpp | 10 | ImGui Vulkan backend, `vk::CommandBuffer`, `vk::ImageView`, `vk::Extent2D`, `vk::Format`, `vk::Instance` |
| shim/bbport_guest_memory.h | 3 | struct fields `vk::Buffer buffer`, `vk::DeviceMemory memory` (lines 22-23); `vk::ExternalMemoryHandleTypeFlagBits HandleType()` (line 47) |
| shim/bbport_overlay.h | 2 | `Init(... vk::Format ...)`, `Render(vk::CommandBuffer, vk::ImageView, vk::Extent2D)` (lines 22, 33) |
| shim/imgui/renderer/imgui_core.h | 3 | inline no-op stubs taking `vk::Format`, `vk::Device` |
| shim/imgui/renderer/texture_manager.h | 3 | inline no-op stubs, same signatures |
| shim/core/debug_state.h | 1 | `CollectShader(..., vk::ShaderModule, ...)` (line 34) |

Raw Vulkan C API (not `vk::`):
- layer/bblayer_gpu_memory.h:23 `#include <vulkan/vulkan_core.h>`; uses `VkBuffer`, `VkDeviceAddress` at lines 36-37, 78-79, 100-101.
- dlss_bridge/bbport_dlss_bridge.h:12 `#include <vulkan/vulkan.h>`; ABI structs and function pointers with `VkImage`, `VkImageView`, `VkFormat`, `VkInstance`, `VkDevice`, `VkCommandBuffer` at lines 23-68.
- tools/fsr4_bench.cpp:24 `#include <vulkan/vulkan.h>`.
- bbnet/CMakeLists.txt:36 links `Vulkan::Headers` (build only).

## 5. Includes of backend or cache headers from outside

| includer (file:line) | included header |
|---|---|
| core/libraries/gnmdriver/gnmdriver.cpp:29,30 | renderer_vulkan/vk_presenter.h, vk_rasterizer.h |
| core/libraries/videoout/driver.cpp:18,33,34,35,36 | renderer_vulkan/vk_frame_capture.h, vk_breadcrumbs.h, vk_instance.h, vk_presenter.h, vk_scheduler.h |
| core/libraries/videoout/video_out.cpp:14 | renderer_vulkan/vk_presenter.h |
| video_core/amdgpu/liverpool.cpp:40 | renderer_vulkan/vk_rasterizer.h |
| video_core/amdgpu/liverpool.h | forward decl `class Rasterizer` (line 29), no include |
| video_core/cache_storage.cpp:11,12 | renderer_vulkan/vk_instance.h, vk_pipeline_cache.h |
| video_core/page_manager.cpp:15 | buffer_cache/buffer.h |
| video_core/page_manager.cpp:28 | renderer_vulkan/vk_rasterizer.h |
| video_core/page_manager.h:10 | buffer_cache/region_definitions.h |
| shader_recompiler/ir/passes/shader_info_collection_pass.cpp:7 | buffer_cache/buffer_cache.h (no symbol from it is used in the file) |
| shim/bbgpu.cpp:35 | renderer_vulkan/vk_rasterizer.h |
| shim/bbport_guest_memory.cpp:13 | renderer_vulkan/vk_instance.h |
| shim/bbport_guest_memory.h:12 | renderer_vulkan/vk_common.h |
| shim/bbport_overlay.cpp:19,20 | renderer_vulkan/vk_instance.h, vk_scheduler.h |
| shim/bbport_overlay.h:10 | renderer_vulkan/vk_common.h |
| shim/core/debug_state.h:8 | renderer_vulkan/vk_common.h |
| shim/imgui/renderer/imgui_core.h:3, texture_manager.h:3 | renderer_vulkan/vk_common.h |

The shim `core/memory.h:8` uses a forward declaration only.

## 6. Caches (TextureCache, BufferCache, PageManager)

- TextureCache: no outside symbol or include.
- BufferCache: no outside call. Include only at `shader_info_collection_pass.cpp:7`. Comments naming `BufferCache::DownloadMemory`, `BufferCache::VramPromotionsPaused`, `BufferCache::LayerBind`, `BufferCache FixedArena` at `shim/bbport_toggles.h:76,199`, `shim/bbport_sections.h:37`, `shim/bbport_guest_memory.h:38`.
- PageManager (`video_core/page_manager.h`, not inside the three dirs): the only outside call is `VideoCore::PageManager::ReportFaultSites()` at `videoout/driver.cpp:616`. Owned by the Vulkan rasterizer at `vk_rasterizer.h:443`, constructed at `vk_rasterizer.cpp:60`. The `OnGpuMap` call is inside the backend (`vk_rasterizer.cpp:4641`). The fault impls (`page_manager.cpp:313-344`, `:559-690`) are outside code that calls back into `Rasterizer` from signal and userfault threads.
- Found no outside call to `TextureCache` or `BufferCache` methods. All outside cache access goes through the rasterizer.

## 7. Observations

1. **Liverpool command processor is the largest seam (228 hits, 47+ rasterizer methods).** `amdgpu/liverpool.cpp` drives draw, dispatch, DMA, EOP, labels and signal ordering through `Rasterizer` (sections 1 and liverpool.cpp:111-2777). Every abstract interface must cover these, and the sync semantics (draw pipe head/reached, `RunInOrder`, `SignalAfterGpu`, `SignalAfterHostCopies`) are defined by the backend but are required by the frontend.
2. **`RunInOrder` leaks the concrete type into callbacks.** Lambdas and free functions are typed `void(Vulkan::Rasterizer&, const u8*)` (liverpool.cpp:252, 311, 438, 507, 512, 564, 582, 599, 606, 618, 661, 2764). Any abstract interface must keep this callback shape, or the frontend must stop passing the rasterizer into callbacks.
3. **`GetDrawPreparation()` returns `Vulkan::DrawPreparation*`** (liverpool.cpp:1376-1377, 2721), which holds the Vulkan `PipelineCache`. It is stored in draw state and used by the frontend. Hard to replace without a neutral prep type.
4. **`Vulkan::DrawPipe` reason enum and `OnStageB()`** are used by the frontend (liverpool.cpp:111, 276, 483, 2332, 2775). The reasons should move to a neutral header.
5. **Static policy functions in the Vulkan namespace:** `Rasterizer::HonestLabels()` (10 sites) and `OcclusionTranslated()` (1 site). They are backend capability flags used to choose frontend behaviour. Turn them into a backend-neutral capability query.
6. **Global state and globals.** `Presenter` is a global `unique_ptr` (gnmdriver.cpp:33, extern in driver.cpp:38 and video_out.cpp:16). `MemoryManager` keeps a `Rasterizer*` and installs C hooks that go through `Memory::Instance()->GetRasterizer()` (bbgpu.cpp:94-118, shim/core/memory.h:27). `PageManager` has a static `Vulkan::Rasterizer* rasterizer` (page_manager.cpp:294) used from signal and userfault threads (313-344, 678). Any abstraction needs thread-safe lookup and a lifetime that outlives the fault handlers.
7. **Ownership inversion.** `Presenter` owns the `Rasterizer` (vk_presenter.h:133, vk_presenter.cpp:134), and gnmdriver creates the presenter with the Liverpool (gnmdriver.cpp:3107). A Metal backend needs a Presenter-equivalent that owns its rasterizer, or the factory has to move out of the Presenter.
8. **`bbport_guest_memory.cpp` (129 hits, 122 `vk::`)** is the largest outside Vulkan dependency. dma-buf and host-pointer import, VMA-style memory selection, device addresses and `vk::Buffer`/`vk::DeviceMemory` appear in its public API (bbport_guest_memory.h:22-23, 32, 36, 49). It has no neutral seam today. A Metal path needs its own implementation behind the same entry points.
9. **Overlay.** `bbport_overlay.h:22,33` takes `Vulkan::Instance`, `vk::CommandBuffer`, `vk::ImageView`, `vk::Format`. Only the presenter calls it (vk_presenter.cpp:157, 668, 698). The overlay also takes `Vulkan::Scheduler::submit_mutex` (bbport_overlay.cpp:932), so it shares a lock with the backend scheduler. It also does a `const_cast` on the instance handle (bbport_overlay.cpp:723-730).
10. **Public ABI headers with raw Vulkan types.** `layer/bblayer_gpu_memory.h` (VkBuffer, VkDeviceAddress) and `dlss_bridge/bbport_dlss_bridge.h` (VkImage, VkCommandBuffer, VkInstance, VkDevice; function-pointer ABI, lines 23-68) are not neutral. Either they stay Vulkan-only or they need a backend-neutral handle type.
11. **Shader and pipeline-cache seams.** `debug_state.h:34` takes `vk::ShaderModule` in `CollectShader`. `cache_storage.cpp:11-12` includes the Vulkan pipeline cache and instance for the archive load and save. `shader_info_collection_pass.cpp:7` includes `buffer_cache.h` without using it, which pulls a Vulkan header into the shader frontend (drop the include).
12. **Debug and stats globals read by the videoout driver:** `g_bb_compiles`, `g_bb_compile_ns`, `g_bb_flip_count`, `Scheduler::direct_recordings`, `recorded_submissions`, `recorded_segments`, `VmaDeviceUsage`, `Breadcrumbs::PrintProgress` (videoout/driver.cpp:344, 521, 575-580, 616, 622, 695-696). These need one neutral stats hook per backend.
13. **Frame capture** (`Vulkan::FrameCapture::AddDisplayBuffer` / `OnFlip`, videoout/driver.cpp:232, 376) is Vulkan-specific and called from the flip path.
14. **Frame handle in the flip request.** `videoout/driver.h:100` holds `Vulkan::Frame*` in the request struct, and `PrepareFrame` returns it (driver.cpp:825). The videoout driver therefore names the presenter's frame type across its thread boundary.
15. **Good news:** no outside code calls `TextureCache` or `BufferCache` methods, and outside code calls `PageManager` once (driver.cpp:616). The rasterizer is the only path into the caches from outside, which makes the rasterizer interface the seam to abstract.

Not found: any outside use of `vk::Image`, `vk::ImageView` in cache-facing code, templates over Vulkan types, or `Vulkan::` names in `gpu/cp/`, `gpu/games/`, `gpu/bbnet/`, `gpu/shadps4/core/libraries/avplayer/`. `gpu/shim/imgui/` only has the inline stubs listed above.
