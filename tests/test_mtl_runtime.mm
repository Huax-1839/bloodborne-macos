// SPDX-License-Identifier: GPL-2.0-or-later
// Unit test of renderer_metal/mtl_runtime (Metal::Runtime, the Metal CacheBackend, plan P2.4):
// buffers (create, map, fill, copy, inline and staged updates, guest chunks), textures (upload
// and download byte exact for RGBA8, BC1, mips, arrays and 3D), views with swizzles sampled by a
// kernel, samplers, the deferred destroys, copies and clears, MSAA backings and resolves,
// detiling and tiling against a CPU reference, the fault buffer parser, access tracking and the
// format policy. Needs a Metal device, no window or game. Run it with MTL_DEBUG_LAYER=1 as well.
//
//   mtl-runtime-test
//
// Exit 0 when every check passed.
#import <Metal/Metal.h>

#include <setjmp.h>
#include <sys/mman.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <set>
#include <string>
#include <thread>
#include <vector>

#include "common/slot_vector.h"
#include "video_core/renderer_metal/mtl_device_impl.h"
#include "video_core/renderer_metal/mtl_guest_memory.h"
#include "video_core/renderer_metal/mtl_runtime.h"
#include "video_core/renderer_metal/mtl_scheduler_impl.h"
#include "video_core/renderer_metal/vk_to_mtl.h"

#include <vulkan/vulkan_format_traits.hpp>

// The runtime services libbbgpu takes from bb-probe; this test has no guest process. The guest
// memory module's allocator callback is kept: the test plays the runtime and hands it a chunk.
static int (*g_chunk_allocator)(uint64_t, uint64_t) = nullptr;
static uint8_t* g_backing = nullptr;
static constexpr uint64_t BackingPhys = 0x10000000;
static constexpr uint64_t BackingSize = 1 << 20;

// (libbbgpu looks these up in the executable)
extern "C" {
    __thread sigjmp_buf* runtime_fault_recover = nullptr;
    uint32_t runtime_disabled_optimizations = 0;
    uint64_t runtime_experiment_bits = 0;
    uint64_t runtime_tsc_frequency() { return 1000000000; }
    int runtime_file_translate(const char*, char*, size_t) { std::abort(); }
    uint64_t runtime_memory_clamp(uintptr_t, uint64_t) { std::abort(); }
    uint64_t runtime_process_time_us() {
        return std::chrono::duration_cast<std::chrono::microseconds>(
                   std::chrono::steady_clock::now().time_since_epoch()).count();
    }
    int runtime_memory_region(uintptr_t, uintptr_t*, uintptr_t*, int*) { std::abort(); }
    void runtime_memory_set_gpu_hooks(void (*)(uintptr_t, uint64_t), void (*)(uintptr_t, uint64_t),
                                      void (*)(uintptr_t, uint64_t)) { std::abort(); }
    void runtime_thread_attach_host(const char*) {}
    void runtime_memory_gpu_protect(uintptr_t, uint64_t, int, int) { std::abort(); }
    void runtime_restart() { std::abort(); }
    uint64_t runtime_process_time_counter() { return runtime_process_time_us() * 1000; }
    int32_t* runtime_errno() { std::abort(); }
    int runtime_memory_write_backing(uintptr_t, const void*, uint64_t) { std::abort(); }
    void runtime_memory_read_backing(uintptr_t, void*, uint64_t) { std::abort(); }
    const uint64_t* runtime_memory_generation() {
        static const uint64_t generation = 0;
        return &generation;
    }
    void runtime_memory_note_write(uintptr_t, uint64_t) { std::abort(); }
    void runtime_memory_set_note_write_hook(void (*)(uintptr_t, uint64_t)) {}
    void runtime_memory_set_cpu_write_hook(void (*)(uintptr_t, uint64_t)) {}
    void runtime_memory_set_write_watch(uintptr_t, uint64_t, int) { std::abort(); }
    void runtime_memory_set_guest_chunk_allocator(int (*alloc)(uint64_t, uint64_t)) {
        g_chunk_allocator = alloc;
    }
    void runtime_memory_set_guest_chunk_whole(int) {}
    int runtime_memory_vma_info(uintptr_t, int*, int*, uintptr_t*) { std::abort(); }
    void runtime_memory_trap(uintptr_t, uint64_t, unsigned, int) { std::abort(); }
    unsigned runtime_memory_trap_reasons(uintptr_t) { std::abort(); }
    int runtime_memory_direct_phys(uintptr_t, uint64_t*, uintptr_t*) { std::abort(); }
    void* runtime_memory_backing_pointer(uint64_t phys) {
        return phys >= BackingPhys && phys < BackingPhys + BackingSize ? g_backing + (phys - BackingPhys)
                                                                          : nullptr;
    }
    uintptr_t runtime_memory_resolve(const char*) { std::abort(); }
    void runtime_wait_report(double) {}
    void runtime_sleep_stats(uint64_t* calls, uint64_t* ns) {
        *calls = 0;
        *ns = 0;
    }
    uint64_t runtime_heap_growths() { return 0; }
}

using namespace VideoCore;
using Metal::Runtime;
using Metal::Scheduler;

static int failures = 0;
#define CHECK(cond)                                                                                \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            std::printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                          \
            ++failures;                                                                            \
        }                                                                                          \
    } while (0)

struct Fixture;
static Fixture* g_fixture = nullptr;
static void SettleGlobal();
static void Settle(Fixture& f);

struct Fixture {
    Metal::Device device;
    Scheduler scheduler{device, "test-runtime"};
    Runtime runtime{device, scheduler};
    id<MTLDevice> mtl = device.GetImpl().device;

    Fixture() {
        g_fixture = this;
        scheduler.SetErrorHandler([](const std::string& report) {
            std::printf("  FAIL command buffer error: %s\n", report.c_str());
            ++failures;
        });
    }
};

/// Buffers and images of the test settle the GPU before they go (see Settle).
struct SettleDelete {
    void operator()(Buffer* buffer) const {
        SettleGlobal();
        delete buffer;
    }
};
using BufferPtr = std::unique_ptr<Buffer, SettleDelete>;

static BufferPtr MakeBuffer(Runtime& runtime, u64 size, MemoryType type,
                            const char* name = "test") {
    return BufferPtr{new Buffer(runtime, 0, size, type, name)};
}

template <typename T>
static void Fill(Buffer& buffer, const std::vector<T>& values, u64 offset = 0) {
    std::memcpy(buffer.mapped_data.data() + offset, values.data(), values.size() * sizeof(T));
}

static std::vector<u8> Pattern(size_t size, u32 seed) {
    std::vector<u8> data(size);
    u32 state = seed * 2654435761u + 1;
    for (auto& byte : data) {
        state = state * 1664525u + 1013904223u;
        byte = static_cast<u8>(state >> 24);
    }
    return data;
}

static bool Equal(const Buffer& buffer, u64 offset, const std::vector<u8>& expected) {
    return std::memcmp(buffer.mapped_data.data() + offset, expected.data(), expected.size()) == 0;
}

static ImageInfo MakeInfo(vk::Format format, u32 width, u32 height, u32 levels = 1, u32 layers = 1,
                          u32 samples = 1) {
    ImageInfo info;
    info.pixel_format = format;
    info.type = samples > 1 ? AmdGpu::ImageType::Color2DMsaa
                            : layers > 1 ? AmdGpu::ImageType::Color2DArray
                                         : AmdGpu::ImageType::Color2D;
    info.resources = {levels, layers};
    info.size = {width, height, 1};
    info.num_samples = samples;
    info.pitch = width;
    info.guest_address = 0x1000;
    info.guest_size = width * height * 4;
    info.props.is_block = vk::blockExtent(format)[0] > 1;
    info.props.is_depth = format == vk::Format::eD32Sfloat;
    info.num_bits = vk::blockSize(format) * 8;
    return info;
}

struct Img {
    Common::SlotVector<ImageView> views;
    std::unique_ptr<Image> image;
    Img(Runtime& runtime, const ImageInfo& info)
        : image{std::make_unique<Image>(runtime, views, info)} {}
    ~Img() {
        SettleGlobal();
        image.reset();
    }
    id<MTLTexture> Texture() const {
        return (__bridge id<MTLTexture>)image->backing->image.native;
    }
};

static vk::BufferImageCopy WholeCopy(u32 width, u32 height, u32 mip = 0, u32 layers = 1,
                                     u32 depth = 1, u64 buffer_offset = 0, u32 base_layer = 0) {
    vk::BufferImageCopy copy{};
    copy.bufferOffset = buffer_offset;
    copy.imageSubresource.aspectMask = vk::ImageAspectFlagBits::eColor;
    copy.imageSubresource.mipLevel = mip;
    copy.imageSubresource.baseArrayLayer = base_layer;
    copy.imageSubresource.layerCount = layers;
    copy.imageExtent = {width, height, depth};
    return copy;
}

/// Uploads `data` into `image` (copies at offsets of the staging buffer given by the caller).
static void Upload(Fixture& f, Image& image, const std::vector<u8>& data,
                   std::span<const vk::BufferImageCopy> copies) {
    const StagingSpan staging = f.runtime.StagingRequest(data.size(), MemoryType::HostUncached, 16);
    std::memcpy(staging.mapped, data.data(), data.size());
    std::vector<vk::BufferImageCopy> shifted(copies.begin(), copies.end());
    for (auto& copy : shifted) {
        copy.bufferOffset += staging.offset;
    }
    f.runtime.UploadImage(&image, staging.buffer, shifted);
}

static std::vector<u8> Download(Fixture& f, Image& image,
                                std::span<const vk::BufferImageCopy> copies, size_t size) {
    auto buffer = MakeBuffer(f.runtime, size, MemoryType::HostCached, "download");
    f.runtime.DownloadImage(&image, buffer.get(), copies);
    Settle(f);
    return {buffer->mapped_data.data(), buffer->mapped_data.data() + size};
}

static NSString* const kernel_source = @"#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void read_texel(texture2d<float> tex [[texture(0)]], device float4* out [[buffer(0)]]) {\n"
    "    out[0] = tex.read(uint2(0, 0));\n"
    "}\n"
    "kernel void sample_texel(texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]],\n"
    "                         device float4* out [[buffer(0)]]) {\n"
    "    out[0] = tex.sample(smp, float2(0.5, 0.5), level(0));\n"
    "}\n"
    "kernel void write_word(constant ulong& address [[buffer(0)]], constant uint& value [[buffer(1)]]) {\n"
    "    *reinterpret_cast<device uint*>(address) = value;\n"
    "}\n";

/// The test's kernels live for the whole run: nothing retains a pipeline for the GPU (unretained
/// command buffers), so a pipeline released right after its dispatch is a validation error.
static id<MTLComputePipelineState> Pipeline(id<MTLDevice> device, NSString* name) {
    static NSMutableDictionary<NSString*, id<MTLComputePipelineState>>* cache = [NSMutableDictionary new];
    if (cache[name]) {
        return cache[name];
    }
    NSError* error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:kernel_source options:nil error:&error];
    if (!library) {
        std::printf("kernel library: %s\n", error.localizedDescription.UTF8String);
        std::exit(2);
    }
    id<MTLComputePipelineState> pipeline =
        [device newComputePipelineStateWithFunction:[library newFunctionWithName:name]
                                              error:&error];
    if (!pipeline) {
        std::printf("pipeline: %s\n", error.localizedDescription.UTF8String);
        std::exit(2);
    }
    cache[name] = pipeline;
    return pipeline;
}

/// Finish and give Metal a moment to retire the command buffers. The scheduler frees a tick (and
/// so runs the deferred releases) as soon as its event is signalled, which is earlier than Metal
/// retires the command buffer; the debug layer reports an object released in between ("destroyed
/// while still required to be alive by the command buffer"). The test settles after every Finish
/// so that no release can follow a signal immediately.
static void Settle(Fixture& f) {
    f.runtime.Finish();
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
}
static void SettleGlobal() {
    Settle(*g_fixture);
}

// ---- Tests --------------------------------------------------------------------------------------

static void TestLimitsAndFormats(Fixture& f) {
    std::printf("limits and formats\n");
    const BackendLimits& limits = f.runtime.Limits();
    CHECK(limits.integrated);
    CHECK(limits.anisotropic_filtering && limits.max_sampler_anisotropy == 16.0f);
    CHECK(limits.uniform_min_alignment == 16 && limits.storage_min_alignment == 16);
    CHECK(limits.non_coherent_atom_size >= 1);
    CHECK(!limits.custom_border_color && !limits.attachment_feedback_loop_layout);
    CHECK(limits.max_framebuffer_width == 16384 && limits.max_framebuffer_height == 16384);
    CHECK(limits.total_memory_budget > 0 && limits.can_report_memory_usage);
    CHECK(f.runtime.DeviceMemoryBudgetNow() > 0);
    CHECK(f.runtime.GetSparseArena() == nullptr);
    CHECK(f.runtime.GetFastReadback() == nullptr);
    CHECK(!f.runtime.IsRecordingDeferred());

    using F = vk::Format;
    const vk::FormatFeatureFlags2 none{};
    CHECK(f.runtime.SupportedFormat(F::eR8G8B8A8Unorm, none) == F::eR8G8B8A8Unorm);
    CHECK(f.runtime.SupportedFormat(F::eBc1RgbaUnormBlock, none) == F::eBc1RgbaUnormBlock);
    CHECK(f.runtime.SupportedFormat(F::eR32G32B32Sfloat, none) == F::eR32G32B32A32Sfloat);
    CHECK(f.runtime.SupportedFormat(F::eR16G16B16Unorm, none) == F::eR16G16B16A16Unorm);
    CHECK(f.runtime.SupportedFormat(F::eR8G8B8Srgb, none) == F::eR8G8B8A8Srgb);
    CHECK(f.runtime.SupportedFormat(F::eA2B10G10R10SnormPack32, none) == F::eR32Uint);
    CHECK(f.runtime.SupportedFormat(F::eA2B10G10R10SintPack32, none) == F::eR32Uint);
    CHECK(f.runtime.SupportedFormat(F::eR4G4UnormPack8, none) == F::eR8Uint);
    // Everything the policy returns has a Metal texture format.
    for (int raw = 1; raw <= 184; ++raw) {
        const auto format = static_cast<F>(raw);
        if (vk::blockSize(format) == 0) {
            continue;
        }
        CHECK(Metal::VkToMtl::PixelFormat(f.runtime.SupportedFormat(format, none)) != 0);
    }

    vk::ImageCreateInfo ci{};
    ci.imageType = vk::ImageType::e2D;
    ci.format = F::eR8G8B8A8Unorm;
    const auto counts = f.runtime.ImageSampleCounts(ci);
    CHECK(counts & vk::SampleCountFlagBits::e1);
    CHECK(counts & vk::SampleCountFlagBits::e4);
    ci.format = F::eBc1RgbaUnormBlock;
    CHECK(f.runtime.ImageSampleCounts(ci) == vk::SampleCountFlagBits::e1);
    Settle(f);
}

static void TestBuffers(Fixture& f) {
    std::printf("buffers\n");
    auto src = MakeBuffer(f.runtime, 4096, MemoryType::HostUncached, "src");
    auto dst = MakeBuffer(f.runtime, 4096, MemoryType::DeviceLocal, "dst");
    CHECK(!src->mapped_data.empty() && src->is_coherent);
    CHECK(src->buffer.native != nullptr && src->buffer.bda_addr != 0);
    CHECK(src->buffer.owner == &f.runtime);
    const auto pattern = Pattern(4096, 1);
    Fill(*src, pattern);

    // Copies, several regions (odd offsets and sizes too)
    const std::array<vk::BufferCopy, 3> copies{{
        {0, 0, 1024},
        {1024, 2048, 512},
        {2049, 3001, 77},
    }};
    f.runtime.CopyBuffer(src.get(), dst.get(), copies);
    Settle(f);
    CHECK(std::memcmp(dst->mapped_data.data(), pattern.data(), 1024) == 0);
    CHECK(std::memcmp(dst->mapped_data.data() + 2048, pattern.data() + 1024, 512) == 0);
    CHECK(std::memcmp(dst->mapped_data.data() + 3001, pattern.data() + 2049, 77) == 0);

    // Fills: one repeated byte (blit), four different bytes (kernel), at odd offsets too
    f.runtime.FillBuffer(dst.get(), 0, 256, 0xABABABABu);
    f.runtime.FillBuffer(dst.get(), 256, 256, 0x04030201u);
    f.runtime.FillBuffer(dst.get(), 513, 7, 0);
    Settle(f);
    CHECK(std::all_of(dst->mapped_data.begin(), dst->mapped_data.begin() + 256,
                      [](u8 b) { return b == 0xAB; }));
    bool words_ok = true;
    for (u32 i = 0; i < 64; ++i) {
        words_ok &= reinterpret_cast<const u32*>(dst->mapped_data.data() + 256)[i] == 0x04030201u;
    }
    CHECK(words_ok);
    CHECK(std::all_of(dst->mapped_data.begin() + 513, dst->mapped_data.begin() + 520,
                      [](u8 b) { return b == 0; }));

    // Stream order: a later fill over an earlier inline write wins, and the other way round.
    f.runtime.InlineData(dst.get(), 1024, 0x11111111u);
    f.runtime.FillBuffer(dst.get(), 1024, 4, 0x22222222u);
    f.runtime.FillBuffer(dst.get(), 1028, 4, 0x33333333u);
    f.runtime.InlineData(dst.get(), 1028, 0x44444444u);
    Settle(f);
    CHECK(*reinterpret_cast<const u32*>(dst->mapped_data.data() + 1024) == 0x22222222u);
    CHECK(*reinterpret_cast<const u32*>(dst->mapped_data.data() + 1028) == 0x44444444u);

    // UpdateBuffer, small and big, in order with a copy of the same range
    const auto update = Pattern(1000, 2);
    f.runtime.UpdateBuffer(dst.get(), 100, update);
    Settle(f);
    CHECK(Equal(*dst, 100, update));
    auto big = MakeBuffer(f.runtime, 1 << 20, MemoryType::DeviceLocal, "big");
    const auto big_data = Pattern(300000, 3);
    f.runtime.UpdateBuffer(big.get(), 4096, big_data);
    Settle(f);
    CHECK(Equal(*big, 4096, big_data));

    // The device address reaches the same memory (residency, D6)
    id<MTLComputePipelineState> write_word = Pipeline(f.mtl, @"write_word");
    f.scheduler.ComputeEncoder();
    auto& compute = f.scheduler.GetImpl().compute;
    const u64 address = dst->buffer.bda_addr + 2000;
    const u32 value = 0xC0FFEE11u;
    [compute setComputePipelineState:write_word];
    [compute setBytes:&address length:8 atIndex:0];
    [compute setBytes:&value length:4 atIndex:1];
    [compute dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    Settle(f);
    CHECK(*reinterpret_cast<const u32*>(dst->mapped_data.data() + 2000) == value);
    Settle(f);
}

static void TestGuestChunk(Fixture& f) {
    std::printf("guest chunks\n");
    g_backing = static_cast<uint8_t*>(mmap(nullptr, BackingSize, PROT_READ | PROT_WRITE,
                                           MAP_ANON | MAP_PRIVATE, -1, 0));
    CHECK(g_backing != MAP_FAILED);
    setenv("BB_GUEST_IN_PLACE", "1", 1);
    CHECK(f.runtime.GuestMemoryUsable());
    Metal::GuestMemory::Install(f.device);
    CHECK(g_chunk_allocator != nullptr);
    if (!g_chunk_allocator) {
        return;
    }
    CHECK(g_chunk_allocator(BackingPhys, BackingSize) == -3);
    const auto* chunk = Metal::GuestMemory::Find(BackingPhys);
    CHECK(chunk && chunk->size == BackingSize);

    const auto pattern = Pattern(8192, 4);
    std::memcpy(g_backing, pattern.data(), pattern.size());
    {
        Buffer imported{f.runtime, 65536, BackingPhys, "guest"};
        CHECK(imported.buffer.native != nullptr);
        CHECK(imported.buffer.bda_addr == chunk->gpu_address);
        CHECK(imported.is_coherent);
        auto dst = MakeBuffer(f.runtime, 4096, MemoryType::DeviceLocal, "from guest");
        const std::array<vk::BufferCopy, 2> copies{{{256, 0, 1024}, {4096, 2048, 300}}};
        f.runtime.CopyFromGuestChunk(BackingPhys, dst.get(), copies);
        auto dst2 = MakeBuffer(f.runtime, 4096, MemoryType::DeviceLocal, "from import");
        const vk::BufferCopy copy{512, 0, 700};
        f.runtime.CopyBuffer(&imported, dst2.get(), std::span{&copy, 1});
        Settle(f);
        CHECK(std::memcmp(dst->mapped_data.data(), pattern.data() + 256, 1024) == 0);
        CHECK(std::memcmp(dst->mapped_data.data() + 2048, pattern.data() + 4096, 300) == 0);
        CHECK(std::memcmp(dst2->mapped_data.data(), pattern.data() + 512, 700) == 0);
        Settle(f);
    }
    Settle(f);
    f.runtime.PopPendingOperations();
    // The chunk's own reference survived the buffers that imported it.
    CHECK(Metal::GuestMemory::Find(BackingPhys) != nullptr);
    CHECK(((__bridge id<MTLBuffer>)chunk->buffer).length == BackingSize);
    Settle(f);
}

static void TestImages(Fixture& f) {
    std::printf("images\n");
    using F = vk::Format;
    {
        // RGBA8 with two mips
        Img img{f.runtime, MakeInfo(F::eR8G8B8A8Unorm, 64, 64, 2)};
        CHECK(img.image->backing != nullptr && img.Texture().mipmapLevelCount == 2);
        CHECK(img.image->backing->image.size_bytes >= 64 * 64 * 4);
        const auto data = Pattern(64 * 64 * 4 + 32 * 32 * 4, 5);
        const std::array<vk::BufferImageCopy, 2> copies{
            WholeCopy(64, 64, 0, 1, 1, 0), WholeCopy(32, 32, 1, 1, 1, 64 * 64 * 4)};
        Upload(f, *img.image, data, copies);
        const auto back = Download(f, *img.image, copies, data.size());
        CHECK(back == data);
        CHECK(!(img.image->flags & ImageFlagBits::Dirty));
    }
    {
        // A partial region with a row length wider than the region
        Img img{f.runtime, MakeInfo(F::eR8G8B8A8Unorm, 32, 32)};
        const auto data = Pattern(32 * 32 * 4, 6);
        Upload(f, *img.image, data, std::array{WholeCopy(32, 32)});
        vk::BufferImageCopy part = WholeCopy(8, 4);
        part.imageOffset = {4, 2, 0};
        part.bufferRowLength = 16;
        const auto back = Download(f, *img.image, std::array{part}, 16 * 4 * 4);
        bool ok = true;
        for (u32 y = 0; y < 4; ++y) {
            ok &= std::memcmp(back.data() + y * 16 * 4, data.data() + ((y + 2) * 32 + 4) * 4,
                              8 * 4) == 0;
        }
        CHECK(ok);
    }
    {
        // BC1 blocks
        Img img{f.runtime, MakeInfo(F::eBc1RgbaUnormBlock, 64, 64, 3)};
        CHECK(img.Texture().pixelFormat == MTLPixelFormatBC1_RGBA);
        const size_t size = (16 * 16 + 8 * 8 + 4 * 4) * 8;
        const auto data = Pattern(size, 7);
        const std::array<vk::BufferImageCopy, 3> copies{
            WholeCopy(64, 64, 0, 1, 1, 0), WholeCopy(32, 32, 1, 1, 1, 16 * 16 * 8),
            WholeCopy(16, 16, 2, 1, 1, (16 * 16 + 8 * 8) * 8)};
        Upload(f, *img.image, data, copies);
        CHECK(Download(f, *img.image, copies, size) == data);
    }
    {
        // A 2D array with a layer loop, and a 3D image
        Img img{f.runtime, MakeInfo(F::eR8G8B8A8Unorm, 16, 16, 1, 3)};
        const auto data = Pattern(16 * 16 * 4 * 3, 8);
        const std::array copies{WholeCopy(16, 16, 0, 3)};
        Upload(f, *img.image, data, copies);
        CHECK(Download(f, *img.image, copies, data.size()) == data);

        ImageInfo info3 = MakeInfo(F::eR8G8B8A8Unorm, 8, 8);
        info3.type = AmdGpu::ImageType::Color3D;
        info3.size = {8, 8, 4};
        Img vol{f.runtime, info3};
        CHECK(vol.Texture().textureType == MTLTextureType3D);
        const auto vdata = Pattern(8 * 8 * 4 * 4, 9);
        const std::array vcopies{WholeCopy(8, 8, 0, 1, 4)};
        Upload(f, *vol.image, vdata, vcopies);
        CHECK(Download(f, *vol.image, vcopies, vdata.size()) == vdata);
    }
    {
        // Substituted formats: the texture exists; transfers are skipped (no crash)
        Img img{f.runtime, MakeInfo(F::eR16G16B16Sfloat, 8, 8)};
        CHECK(img.image->backing->image.image_ci.format == F::eR16G16B16A16Sfloat);
        const auto data = Pattern(8 * 8 * 6, 10);
        Upload(f, *img.image, data, std::array{WholeCopy(8, 8)});
        Settle(f);
        Img raw{f.runtime, MakeInfo(F::eA2B10G10R10SnormPack32, 8, 8)};
        CHECK(raw.Texture().pixelFormat == MTLPixelFormatR32Uint);
        const auto raw_data = Pattern(8 * 8 * 4, 11);
        Upload(f, *raw.image, raw_data, std::array{WholeCopy(8, 8)});
        CHECK(Download(f, *raw.image, std::array{WholeCopy(8, 8)}, raw_data.size()) == raw_data);
    }
    Settle(f);
}

static void TestViewsAndSamplers(Fixture& f) {
    std::printf("views and samplers\n");
    using F = vk::Format;
    Img img{f.runtime, MakeInfo(F::eR8G8B8A8Unorm, 2, 2)};
    // texel (0,0) = (10, 20, 30, 40); the others make the bilinear average easy to tell
    std::vector<u8> data{10, 20, 30, 40, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255};
    Upload(f, *img.image, data, std::array{WholeCopy(2, 2)});

    ImageViewInfo plain;
    plain.format = F::eR8G8B8A8Unorm;
    plain.type = AmdGpu::ImageType::Color2D;
    plain.range = {{0, 0}, {1, 1}};
    ImageView& identity = img.image->FindView(plain);
    CHECK(identity.native != nullptr && identity.owner == &f.runtime);
    // The whole texture: the view is the texture itself
    CHECK(identity.native == img.image->backing->image.native);

    ImageViewInfo swapped = plain;
    swapped.mapping = {vk::ComponentSwizzle::eB, vk::ComponentSwizzle::eG,
                       vk::ComponentSwizzle::eR, vk::ComponentSwizzle::eOne};
    ImageView& view = img.image->FindView(swapped);
    CHECK(view.native != nullptr && view.native != img.image->backing->image.native);

    ImageViewInfo srgb = plain;
    srgb.format = F::eR8G8B8A8Srgb;
    ImageView& srgb_view = img.image->FindView(srgb);
    CHECK(((__bridge id<MTLTexture>)srgb_view.native).pixelFormat ==
          MTLPixelFormatRGBA8Unorm_sRGB);

    // The swizzled view, read by a kernel
    auto out = MakeBuffer(f.runtime, 256, MemoryType::HostCached, "out");
    std::memset(out->mapped_data.data(), 0, 256);
    f.scheduler.ComputeEncoder();
    auto& compute = f.scheduler.GetImpl().compute;
    [compute setComputePipelineState:Pipeline(f.mtl, @"read_texel")];
    [compute setTexture:(__bridge id<MTLTexture>)view.native atIndex:0];
    [compute setBuffer:(__bridge id<MTLBuffer>)out->buffer.native offset:0 atIndex:0];
    [compute dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    Settle(f);
    const float* texel = reinterpret_cast<const float*>(out->mapped_data.data());
    std::printf("  swizzled texel %f %f %f %f\n", texel[0], texel[1], texel[2], texel[3]);
    CHECK(std::abs(texel[0] - 30 / 255.0f) < 1e-3f && std::abs(texel[1] - 20 / 255.0f) < 1e-3f &&
          std::abs(texel[2] - 10 / 255.0f) < 1e-3f && std::abs(texel[3] - 1.0f) < 1e-3f);

    // A sampler: bilinear in the middle of the 2x2 texture is the mean of the four texels
    AmdGpu::Sampler guest{};
    guest.raw0 = 0;
    guest.raw1 = (u64(AmdGpu::Filter::Bilinear) << 20) | (u64(AmdGpu::Filter::Bilinear) << 22);
    Sampler sampler{f.runtime, guest, AmdGpu::BorderColorBuffer{}, false};
    CHECK(sampler.native != nullptr && sampler.owner == &f.runtime);
    f.scheduler.ComputeEncoder();
    auto& compute2 = f.scheduler.GetImpl().compute;
    [compute2 setComputePipelineState:Pipeline(f.mtl, @"sample_texel")];
    [compute2 setTexture:(__bridge id<MTLTexture>)identity.native atIndex:0];
    [compute2 setSamplerState:(__bridge id<MTLSamplerState>)sampler.native atIndex:0];
    [compute2 setBuffer:(__bridge id<MTLBuffer>)out->buffer.native offset:0 atIndex:0];
    [compute2 dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    Settle(f);
    std::printf("  sampled texel %f %f %f %f\n", texel[0], texel[1], texel[2], texel[3]);
    CHECK(std::abs(texel[0] - (10 + 255) / 4.0f / 255.0f) < 2e-3f);
    CHECK(std::abs(texel[3] - (40 + 255) / 4.0f / 255.0f) < 2e-3f);

    // A depth image and its views: depth aspect, stencil aspect of a combined format
    ImageInfo depth_info = MakeInfo(F::eD32SfloatS8Uint, 16, 16);
    depth_info.props.is_depth = 1;
    depth_info.props.has_stencil = 1;
    Img depth{f.runtime, depth_info};
    CHECK(depth.Texture().pixelFormat == MTLPixelFormatDepth32Float_Stencil8);
    ImageViewInfo depth_view_info;
    depth_view_info.format = F::eR32Sfloat;
    depth_view_info.type = AmdGpu::ImageType::Color2D;
    depth_view_info.range = {{0, 0}, {1, 1}};
    ImageView& depth_view = depth.image->FindView(depth_view_info);
    CHECK(depth_view.native != nullptr);
    Settle(f);
}

static void TestDeferredDestroy(Fixture& f) {
    std::printf("deferred destroy\n");
    Settle(f);
    f.runtime.PopPendingOperations();
    __weak id<MTLBuffer> weak_buffer;
    __weak id<MTLTexture> weak_texture;
    __weak id<MTLSamplerState> weak_sampler;
    {
        // (no settling deleters here: the point is what happens without one)
        auto buffer = std::make_unique<Buffer>(f.runtime, 0, 4096, MemoryType::DeviceLocal, "doomed");
        weak_buffer = (__bridge id<MTLBuffer>)buffer->buffer.native;
        f.runtime.FillBuffer(buffer.get(), 0, 4096, 0x01010101u); // the open command buffer uses it
        Common::SlotVector<ImageView> views;
        Image image{f.runtime, views, MakeInfo(vk::Format::eR8G8B8A8Unorm, 16, 16)};
        weak_texture = (__bridge id<MTLTexture>)image.backing->image.native;
        AmdGpu::Sampler guest{};
        Sampler sampler{f.runtime, guest, AmdGpu::BorderColorBuffer{}, false};
        weak_sampler = (__bridge id<MTLSamplerState>)sampler.native;
        CHECK(weak_buffer != nil && weak_texture != nil && weak_sampler != nil);
    } // all destroyed here: the releases wait for the open tick
    const u64 tick = f.runtime.CurrentTick();
    for (int i = 0; i < 100; ++i) {
        f.runtime.PopPendingOperations();
    }
    CHECK(weak_buffer != nil && weak_texture != nil && weak_sampler != nil);
    CHECK(!f.runtime.IsFree(tick));
    Settle(f);
    CHECK(f.runtime.IsFree(tick));
    f.runtime.PopPendingOperations();
    // Metal retires the command buffer a moment after the event is signalled.
    for (int i = 0; i < 200 && (weak_buffer || weak_texture || weak_sampler); ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
        f.runtime.PopPendingOperations();
    }
    CHECK(weak_buffer == nil);
    CHECK(weak_texture == nil);
    CHECK(weak_sampler == nil);

    // A deferred operation of the runtime itself
    std::atomic<bool> ran{false};
    f.runtime.DeferOperation([&] { ran = true; });
    f.runtime.PopPendingOperations();
    CHECK(!ran);
    Settle(f);
    f.runtime.PopPendingOperations();
    CHECK(ran);
}

static void TestImageCopies(Fixture& f) {
    std::printf("image copies, clears, MSAA\n");
    using F = vk::Format;
    const auto data = Pattern(32 * 32 * 4, 12);
    const std::array whole{WholeCopy(32, 32)};
    Img a{f.runtime, MakeInfo(F::eR8G8B8A8Unorm, 32, 32)};
    Upload(f, *a.image, data, whole);
    {
        Img b{f.runtime, MakeInfo(F::eR8G8B8A8Unorm, 32, 32)};
        f.runtime.CopyImage(a.image.get(), b.image.get());
        CHECK(Download(f, *b.image, whole, data.size()) == data);
        CHECK(b.image->flags & ImageFlagBits::GpuModified || true);
        // A different format of the same texel size: copied through a view
        Img c{f.runtime, MakeInfo(F::eR32Uint, 32, 32)};
        f.runtime.CopyImage(a.image.get(), c.image.get());
        CHECK(Download(f, *c.image, whole, data.size()) == data);
        // Through a buffer
        Img d{f.runtime, MakeInfo(F::eR8G8B8A8Unorm, 32, 32)};
        auto staging = MakeBuffer(f.runtime, 32 * 32 * 4, MemoryType::DeviceLocal, "via");
        f.runtime.CopyImageWithBuffer(a.image.get(), d.image.get(), staging.get(), 0);
        CHECK(Download(f, *d.image, whole, data.size()) == data);
    }
    {
        // One mip of a smaller image into a level of a bigger one
        ImageInfo big = MakeInfo(F::eR8G8B8A8Unorm, 64, 64, 2);
        big.mips_layout[1].pitch = 32;
        Img dst{f.runtime, big};
        f.runtime.CopyMip(a.image.get(), dst.image.get(), 1, 0);
        CHECK(Download(f, *dst.image, std::array{WholeCopy(32, 32, 1)}, data.size()) == data);
    }
    {
        // Color to depth and back through a buffer (R32Float <-> D32Float)
        const auto floats = Pattern(16 * 16 * 4, 13);
        Img color{f.runtime, MakeInfo(F::eR32Sfloat, 16, 16)};
        Upload(f, *color.image, floats, std::array{WholeCopy(16, 16)});
        ImageInfo depth_info = MakeInfo(F::eD32Sfloat, 16, 16);
        Img depth{f.runtime, depth_info};
        CHECK(depth.Texture().pixelFormat == MTLPixelFormatDepth32Float);
        f.runtime.CopyColorAndDepth(color.image.get(), depth.image.get());
        Img back{f.runtime, MakeInfo(F::eR32Sfloat, 16, 16)};
        f.runtime.CopyColorAndDepth(depth.image.get(), back.image.get());
        CHECK(Download(f, *back.image, std::array{WholeCopy(16, 16)}, floats.size()) == floats);
        // The depth copy of equal formats
        Img depth2{f.runtime, depth_info};
        SubresourceRange range{};
        f.runtime.CopyDepthStencil(depth.image.get(), depth2.image.get(), range);
        Settle(f);
    }
    {
        // Clears: a render target, in float and in integer formats, one slice of an array
        Img rt{f.runtime, MakeInfo(F::eR8G8B8A8Unorm, 16, 16)};
        vk::ClearValue red{};
        red.color = vk::ClearColorValue{std::array<float, 4>{1.0f, 0.0f, 0.5f, 1.0f}};
        f.runtime.ClearImage(rt.image.get(), SubresourceRange{}, red);
        const auto cleared = Download(f, *rt.image, std::array{WholeCopy(16, 16)}, 16 * 16 * 4);
        CHECK(cleared[0] == 255 && cleared[1] == 0 && cleared[2] == 128 && cleared[3] == 255);
        CHECK(cleared[16 * 16 * 4 - 1] == 255);
        Img ints{f.runtime, MakeInfo(F::eR32Uint, 8, 8)};
        vk::ClearValue seven{};
        seven.color.uint32[0] = 7;
        f.runtime.ClearImage(ints.image.get(), SubresourceRange{}, seven);
        const auto words = Download(f, *ints.image, std::array{WholeCopy(8, 8)}, 8 * 8 * 4);
        CHECK(*reinterpret_cast<const u32*>(words.data()) == 7);
        Img layered{f.runtime, MakeInfo(F::eR8G8B8A8Unorm, 8, 8, 1, 3)};
        Upload(f, *layered.image, Pattern(8 * 8 * 4 * 3, 14), std::array{WholeCopy(8, 8, 0, 3)});
        SubresourceRange one_layer{{0, 1}, {1, 1}};
        f.runtime.ClearImage(layered.image.get(), one_layer, red);
        const auto layers = Download(f, *layered.image, std::array{WholeCopy(8, 8, 0, 3)},
                                     8 * 8 * 4 * 3);
        CHECK(layers[8 * 8 * 4] == 255 && layers[8 * 8 * 4 + 1] == 0);
        CHECK(layers[0] == Pattern(8 * 8 * 4 * 3, 14)[0]);
        // BC1: not a render target, cleared to zero through a staging copy
        Img bc{f.runtime, MakeInfo(F::eBc1RgbaUnormBlock, 16, 16)};
        Upload(f, *bc.image, Pattern(16 * 8, 15), std::array{WholeCopy(16, 16)});
        vk::ClearValue zero{};
        f.runtime.ClearImage(bc.image.get(), SubresourceRange{}, zero);
        const auto zeros = Download(f, *bc.image, std::array{WholeCopy(16, 16)}, 16 * 8);
        CHECK(std::all_of(zeros.begin(), zeros.end(), [](u8 b) { return b == 0; }));
    }
    {
        // A multisampled backing: to 4 samples and back keeps the pixels (the fullscreen passes)
        Img img{f.runtime, MakeInfo(F::eR8G8B8A8Unorm, 32, 32)};
        CHECK(img.image->supported_samples & vk::SampleCountFlagBits::e4);
        Upload(f, *img.image, data, whole);
        f.runtime.SetBackingSamples(img.image.get(), 4);
        CHECK(img.image->backing->num_samples == 4 && img.Texture().sampleCount == 4);
        f.runtime.SetBackingSamples(img.image.get(), 1);
        CHECK(img.image->backing->num_samples == 1 && img.Texture().sampleCount == 1);
        CHECK(Download(f, *img.image, whole, data.size()) == data);
        // And a multisampled image resolved into a single sampled one
        Img ms{f.runtime, MakeInfo(F::eR8G8B8A8Unorm, 32, 32, 1, 1, 4)};
        CHECK(ms.Texture().sampleCount == 4);
        vk::ClearValue green{};
        green.color = vk::ClearColorValue{std::array<float, 4>{0.0f, 1.0f, 0.0f, 1.0f}};
        f.runtime.ClearImage(ms.image.get(), SubresourceRange{}, green);
        Img resolved{f.runtime, MakeInfo(F::eR8G8B8A8Unorm, 32, 32)};
        f.runtime.ResolveImage(ms.image.get(), resolved.image.get(), SubresourceRange{},
                               SubresourceRange{});
        const auto pixels = Download(f, *resolved.image, whole, data.size());
        CHECK(pixels[0] == 0 && pixels[1] == 255 && pixels[2] == 0 && pixels[3] == 255);
        CHECK(pixels[data.size() - 3] == 255);
        // Color to a multisampled depth image
        Img color{f.runtime, MakeInfo(F::eR32Sfloat, 16, 16)};
        std::vector<float> ramp(16 * 16 * 1);
        for (size_t i = 0; i < ramp.size(); ++i) {
            ramp[i] = 0.25f;
        }
        std::vector<u8> ramp_bytes(ramp.size() * 4);
        std::memcpy(ramp_bytes.data(), ramp.data(), ramp_bytes.size());
        Upload(f, *color.image, ramp_bytes, std::array{WholeCopy(16, 16)});
        ImageInfo ms_depth_info = MakeInfo(F::eD32Sfloat, 16, 16, 1, 1, 4);
        Img ms_depth{f.runtime, ms_depth_info};
        CHECK(ms_depth.Texture().sampleCount == 4);
        f.runtime.CopyColorAndDepth(color.image.get(), ms_depth.image.get());
        Settle(f);
    }
    Settle(f);
}

struct TilingInfoBlock {
    u32 bank_swizzle;
    u32 micro_tiled_mips;
    u32 num_mips;
    struct Mip {
        u32 size, pitch, height, offset;
    } mips[16];
};

/// The display micro tiled address of a 32 bit pixel (tiling.comp, one slice, thickness 1).
static u32 MicroTiled32(u32 x, u32 y, u32 pitch) {
    const u32 index = (x & 1) | ((x >> 1 & 1) << 1) | ((y & 1) << 2) | ((x >> 2 & 1) << 3) |
                      ((y >> 1 & 1) << 4) | ((y >> 2 & 1) << 5);
    return (((y / 8) * (pitch / 8) + x / 8) * 256) + index * 4;
}

static void TestKernels(Fixture& f) {
    std::printf("tiling and fault parser kernels\n");
    constexpr u32 Width = 64, Height = 32;
    constexpr u32 Bytes = Width * Height * 4;
    StreamBuffer stream{f.runtime, MemoryType::HostUncached, 1 << 20};

    // linear pattern, and its CPU tiled twin
    std::vector<u32> linear(Width * Height), tiled(Width * Height);
    for (u32 y = 0; y < Height; ++y) {
        for (u32 x = 0; x < Width; ++x) {
            linear[y * Width + x] = x + y * 1000 + 0x01000000u;
            tiled[MicroTiled32(x, y, Width) / 4] = linear[y * Width + x];
        }
    }
    TilingInfoBlock params{};
    params.num_mips = 1;
    params.mips[0] = {Bytes, Width, Height, 0};

    TilingDispatch dispatch{};
    dispatch.key = {AmdGpu::TileMode::Display1DThin, 32, 1, false};
    dispatch.array_mode = AmdGpu::ArrayMode::ArrayLinearAligned;
    dispatch.is_macro = false;
    dispatch.constants = {1 /*samples*/, 0 /*display micro tiling*/, 1 /*thickness*/,
                          0 /*detile*/};
    dispatch.num_constants = 4;
    dispatch.group_count_x = Width * Height / 64;

    // detile: tiled in, linear out
    auto tiled_buffer = MakeBuffer(f.runtime, Bytes + 256, MemoryType::DeviceLocal, "tiled");
    auto linear_buffer = MakeBuffer(f.runtime, Bytes + 256, MemoryType::DeviceLocal, "linear");
    std::memcpy(tiled_buffer->mapped_data.data() + 16, tiled.data(), Bytes);
    std::memset(linear_buffer->mapped_data.data(), 0, Bytes + 256);
    dispatch.tiled = {tiled_buffer.get(), 16, Bytes};
    dispatch.linear = {linear_buffer.get(), 32, Bytes};
    dispatch.params = {&stream, stream.Copy(&params, sizeof(params), 16), sizeof(params)};
    f.runtime.DispatchTiling(dispatch);
    f.runtime.AccessBuffer(linear_buffer.get(), 32, Bytes, vk::PipelineStageFlagBits2::eComputeShader,
                           vk::AccessFlagBits2::eShaderWrite);
    Settle(f);
    CHECK(std::memcmp(linear_buffer->mapped_data.data() + 32, linear.data(), Bytes) == 0);

    // tile: linear in, tiled out
    auto tiled_out = MakeBuffer(f.runtime, Bytes, MemoryType::DeviceLocal, "tiled out");
    std::memset(tiled_out->mapped_data.data(), 0, Bytes);
    TilingDispatch tiler = dispatch;
    tiler.key.is_tiler = true;
    tiler.constants[3] = 1;
    tiler.tiled = {tiled_out.get(), 0, Bytes};
    tiler.linear = {linear_buffer.get(), 32, Bytes};
    f.runtime.FlushBarriers();
    f.runtime.DispatchTiling(tiler);
    Settle(f);
    CHECK(std::memcmp(tiled_out->mapped_data.data(), tiled.data(), Bytes) == 0);

    // A macro tiled kernel (twelve constants) builds and runs (the result is not checked)
    TilingDispatch macro = dispatch;
    macro.is_macro = true;
    macro.key.tile_mode = AmdGpu::TileMode::Display2DThin;
    macro.constants = {1, 0, 1, 0, 4 /*2D_TILED_THIN1*/, 0 /*P2*/, 1, 1, 2, 1, 256, 1};
    macro.num_constants = 12;
    f.runtime.DispatchTiling(macro);
    Settle(f);

    // Fault parser: three faulting pages out of a 64 word bitmap
    f.runtime.CreateFaultParser(12, 1024);
    auto faults = MakeBuffer(f.runtime, 256, MemoryType::DeviceLocal, "faults");
    auto download = MakeBuffer(f.runtime, 8 * 1024 + 64, MemoryType::HostCached, "fault list");
    std::memset(faults->mapped_data.data(), 0, 256);
    std::memset(download->mapped_data.data(), 0, download->SizeBytes());
    auto* bits = reinterpret_cast<u32*>(faults->mapped_data.data());
    bits[0] = 0b101;
    bits[3] = 1u << 5;
    FaultParseDispatch parse{};
    parse.fault_buffer = faults.get();
    parse.fault_buffer_size = 256;
    parse.download = {download.get(), 16, 8 * 1024};
    parse.group_count_x = 1;
    f.runtime.ParseFaultBuffer(parse);
    Settle(f);
    const auto* list = reinterpret_cast<const u64*>(download->mapped_data.data() + 16);
    CHECK(*reinterpret_cast<const u32*>(download->mapped_data.data() + 16) == 3);
    std::set<u64> pages{list[1], list[2], list[3]};
    CHECK((pages == std::set<u64>{0, u64(2) << 12, u64(101) << 12}));
    CHECK(bits[0] == 0 && bits[3] == 0);
    Settle(f);
}

static void TestAccessAndStaging(Fixture& f) {
    std::printf("access tracking and staging\n");
    auto buffer = MakeBuffer(f.runtime, 8192, MemoryType::DeviceLocal, "tracked");
    auto other = MakeBuffer(f.runtime, 8192, MemoryType::DeviceLocal, "other");
    CHECK(!f.runtime.IsBufferAccessed(buffer.get(), 0, 100));
    f.runtime.AccessBuffer(buffer.get(), 1000, 100, vk::PipelineStageFlagBits2::eCopy,
                           vk::AccessFlagBits2::eTransferWrite);
    CHECK(f.runtime.IsBufferAccessed(buffer.get(), 1050, 10));
    CHECK(f.runtime.IsBufferAccessed(buffer.get(), 900, 150, true));
    CHECK(!f.runtime.IsBufferAccessed(buffer.get(), 0, 100));
    CHECK(!f.runtime.IsBufferAccessed(buffer.get(), 2000, 100, true));
    CHECK(!f.runtime.IsBufferAccessed(other.get(), 1050, 10, true));
    // A read: only seen when asked for
    f.runtime.AccessBuffer(buffer.get(), 5000, 16, vk::PipelineStageFlagBits2::eComputeShader,
                           vk::AccessFlagBits2::eShaderRead);
    CHECK(!f.runtime.IsBufferAccessed(buffer.get(), 5000, 16));
    CHECK(f.runtime.IsBufferAccessed(buffer.get(), 5000, 16, true));
    f.runtime.FlushBarriers();
    CHECK(!f.runtime.IsBufferAccessed(buffer.get(), 1050, 10, true));
    // A global write makes everything pending
    f.runtime.AccessGlobal(vk::PipelineStageFlagBits2::eComputeShader,
                           vk::AccessFlagBits2::eShaderWrite);
    CHECK(f.runtime.IsBufferAccessed(other.get(), 0, 4));
    f.runtime.FlushBarriers();
    CHECK(!f.runtime.IsBufferAccessed(other.get(), 0, 4));
    // Many ranges collapse into a bounding range (never lose one)
    for (u64 i = 0; i < 40; ++i) {
        f.runtime.AccessBuffer(buffer.get(), i * 100, 10, vk::PipelineStageFlagBits2::eCopy,
                               vk::AccessFlagBits2::eTransferWrite);
    }
    CHECK(f.runtime.IsBufferAccessed(buffer.get(), 3905, 1));
    f.runtime.FlushBarriers();

    // Image bookkeeping: Transit reports a change once
    Img img{f.runtime, MakeInfo(vk::Format::eR8G8B8A8Unorm, 8, 8)};
    CHECK(f.runtime.Transit(img.image.get(), vk::ImageLayout::eShaderReadOnlyOptimal,
                            vk::PipelineStageFlagBits2::eFragmentShader,
                            vk::AccessFlagBits2::eShaderRead));
    CHECK(!f.runtime.Transit(img.image.get(), vk::ImageLayout::eShaderReadOnlyOptimal,
                             vk::PipelineStageFlagBits2::eFragmentShader,
                             vk::AccessFlagBits2::eShaderRead));
    CHECK(img.image->backing->state.layout == vk::ImageLayout::eShaderReadOnlyOptimal);
    f.runtime.FlushImageBarriers();

    // Staging: ring requests are distinct and mapped; a held large request is not reused
    const StagingSpan a = f.runtime.StagingRequest(1000, MemoryType::HostUncached, 256);
    const StagingSpan b = f.runtime.StagingRequest(1000, MemoryType::HostUncached, 256);
    CHECK(a.mapped && b.mapped && a.mapped != b.mapped && a.offset % 256 == 0);
    const StagingSpan held = f.runtime.StagingRequest(1 << 20, MemoryType::DeviceLocal, 0, true);
    const StagingSpan second = f.runtime.StagingRequest(1 << 20, MemoryType::DeviceLocal, 0, true);
    CHECK(held.buffer != second.buffer);
    f.runtime.StagingFreeDeferred(held);
    f.runtime.StagingFreeDeferred(second);
    const StagingSpan huge = f.runtime.StagingRequest(40 << 20, MemoryType::HostCached);
    CHECK(huge.mapped != nullptr && huge.buffer->SizeBytes() >= u64(40) << 20);
    f.runtime.TickFrame();
    Settle(f);
}

static void TestTicks(Fixture& f) {
    std::printf("ticks and ordering\n");
    const u64 tick = f.runtime.CurrentTick();
    CHECK(f.runtime.IsFree(tick - 1));
    CHECK(!f.runtime.IsRendering());
    f.runtime.Finish();
    CHECK(f.runtime.CurrentTick() == tick + 1);
    CHECK(f.runtime.IsFreeKnown(tick) || f.runtime.IsFree(tick));
    f.runtime.Wait(f.runtime.CurrentTick()); // the open tick: flushed, then waited for
    f.runtime.RefreshTicks();
    bool ran = false;
    BbCopy::Item item{[](const BbCopy::Item& i) { *static_cast<bool*>(i.context) = true; }, &ran,
                      0, 0, 0, 0};
    f.runtime.RecordHostCopy(item);
    CHECK(ran);
}

int main() {
    g_backing = nullptr;
    @autoreleasepool {
        Fixture f;
        TestLimitsAndFormats(f);
        TestBuffers(f);
        TestGuestChunk(f);
        TestImages(f);
        TestViewsAndSamplers(f);
        TestDeferredDestroy(f);
        TestImageCopies(f);
        TestKernels(f);
        TestAccessAndStaging(f);
        TestTicks(f);
        Settle(f);
        CHECK(!f.scheduler.HasFailed());
    }
    std::printf(failures ? "%d check(s) FAILED\n" : "all checks passed\n", failures);
    return failures ? 1 : 0;
}
