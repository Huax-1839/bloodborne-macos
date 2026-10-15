// SPDX-License-Identifier: GPL-2.0-or-later
// Unit test of renderer_metal/mtl_scene_targets (Metal::SceneTargets, plan P7.5 L2): the proxies
// of the live-resolution path and the copies between a proxy and the guest-size ("native") image
// in both directions at 1920x1080 <-> 960x540, values checked texel by texel: a colour format
// (RGBA8, an sRGB view of it, RGBA16F, R32Uint), the levels of a half resolution mip chain, and
// depth with stencil (D32F_S8). Also the coherence steps through the Metal part (fill when a
// proxy is created, resolve on a native access, invalidation on a native write) and the
// eligibility of formats. Needs a Metal device, no window or game. Run it with MTL_DEBUG_LAYER=1
// as well.
//
//   mtl-scene-targets-test
//
// Exit 0 when every check passed.
#import <Metal/Metal.h>

#include <setjmp.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <thread>
#include <vector>

#include "common/slot_vector.h"
#include "video_core/renderer_metal/mtl_device_impl.h"
#include "video_core/renderer_metal/mtl_runtime.h"
#include "video_core/renderer_metal/mtl_scene_targets.h"
#include "video_core/renderer_metal/mtl_scheduler_impl.h"
#include "video_core/renderer_metal/vk_to_mtl.h"

#include <vulkan/vulkan_format_traits.hpp>

// The runtime services libbbgpu takes from bb-probe; this test has no guest process.
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
    void runtime_memory_set_guest_chunk_allocator(int (*)(uint64_t, uint64_t)) {}
    void runtime_memory_set_guest_chunk_whole(int) {}
    int runtime_memory_vma_info(uintptr_t, int*, int*, uintptr_t*) { std::abort(); }
    void runtime_memory_trap(uintptr_t, uint64_t, unsigned, int) { std::abort(); }
    unsigned runtime_memory_trap_reasons(uintptr_t) { std::abort(); }
    int runtime_memory_direct_phys(uintptr_t, uint64_t*, uintptr_t*) { std::abort(); }
    void* runtime_memory_backing_pointer(uint64_t) { return nullptr; }
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
using Metal::SceneTargets;

static int failures = 0;
#define CHECK(cond)                                                                                \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            std::printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                          \
            ++failures;                                                                            \
        }                                                                                          \
    } while (0)

struct Fixture {
    Metal::Device device;
    Scheduler scheduler{device, "test-scene-targets"};
    Runtime runtime{device, scheduler};
    id<MTLDevice> mtl = device.GetImpl().device;

    Fixture() {
        scheduler.SetErrorHandler([](const std::string& report) {
            std::printf("  FAIL command buffer error: %s\n", report.c_str());
            ++failures;
        });
    }
};

/// Finish and give Metal a moment to retire the command buffers (the scheduler frees a tick when
/// its event is signalled, earlier than Metal retires the command buffer; the debug layer reports
/// an object released in between).
static void Settle(Fixture& f) {
    f.runtime.Finish();
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
}

// ---- Texture access of the test (blits on a command buffer of its own) --------------------------

/// Copies one aspect of one level of a (private) texture to the host (`bytes` per texel) or back.
static std::vector<u8> ReadTexture(Fixture& f, id<MTLTexture> texture, u32 bytes, u32 level = 0,
                                   MTLBlitOption option = MTLBlitOptionNone) {
    Settle(f);
    const NSUInteger width = std::max<NSUInteger>(texture.width >> level, 1);
    const NSUInteger height = std::max<NSUInteger>(texture.height >> level, 1);
    id<MTLBuffer> buffer = [f.mtl newBufferWithLength:width * height * bytes
                                              options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> commands = [f.device.GetImpl().queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
    [blit copyFromTexture:texture
              sourceSlice:0
              sourceLevel:level
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(width, height, 1)
                 toBuffer:buffer
        destinationOffset:0
   destinationBytesPerRow:width * bytes
 destinationBytesPerImage:width * height * bytes
                  options:option];
    [blit endEncoding];
    [commands commit];
    [commands waitUntilCompleted];
    CHECK(commands.error == nil);
    const u8* contents = static_cast<const u8*>(buffer.contents);
    return {contents, contents + width * height * bytes};
}

static void WriteTexture(Fixture& f, id<MTLTexture> texture, u32 bytes, const std::vector<u8>& data,
                         u32 level = 0, MTLBlitOption option = MTLBlitOptionNone) {
    Settle(f);
    const NSUInteger width = std::max<NSUInteger>(texture.width >> level, 1);
    const NSUInteger height = std::max<NSUInteger>(texture.height >> level, 1);
    CHECK(data.size() == width * height * bytes);
    id<MTLBuffer> buffer = [f.mtl newBufferWithBytes:data.data()
                                              length:data.size()
                                             options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> commands = [f.device.GetImpl().queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
    [blit copyFromBuffer:buffer
            sourceOffset:0
       sourceBytesPerRow:width * bytes
     sourceBytesPerImage:width * height * bytes
              sourceSize:MTLSizeMake(width, height, 1)
               toTexture:texture
        destinationSlice:0
        destinationLevel:level
       destinationOrigin:MTLOriginMake(0, 0, 0)
                 options:option];
    [blit endEncoding];
    [commands commit];
    [commands waitUntilCompleted];
    CHECK(commands.error == nil);
}

// ---- Images --------------------------------------------------------------------------------------

static ImageInfo MakeInfo(vk::Format format, u32 width, u32 height, u32 levels = 1) {
    ImageInfo info;
    info.pixel_format = format;
    info.type = AmdGpu::ImageType::Color2D;
    info.resources = {levels, 1};
    info.size = {width, height, 1};
    info.num_samples = 1;
    info.pitch = width;
    info.guest_address = 0x1000;
    info.guest_size = width * height * 4;
    info.props.is_block = vk::blockExtent(format)[0] > 1;
    info.props.is_depth = format == vk::Format::eD32Sfloat || format == vk::Format::eD32SfloatS8Uint;
    info.props.has_stencil = format == vk::Format::eD32SfloatS8Uint;
    info.num_bits = vk::blockSize(format) * 8;
    return info;
}

struct World {
    Common::SlotVector<ImageView> views;
    std::vector<std::unique_ptr<Image>> images;
    Fixture& f;

    explicit World(Fixture& f_) : f{f_} {}
    ~World() {
        Settle(f);
        images.clear();
    }
    ImageId Add(const ImageInfo& info) {
        images.push_back(std::make_unique<Image>(f.runtime, views, info));
        return ImageId{u32(images.size() - 1)};
    }
    Image& Get(ImageId id) {
        return *images[id.index];
    }
    SceneTargets::Lookup Lookup() {
        return [this](ImageId id, u64) -> Image* {
            return id.index < images.size() ? images[id.index].get() : nullptr;
        };
    }
};

static id<MTLTexture> NativeOf(Image& image) {
    return (__bridge id<MTLTexture>)image.backing->image.native;
}

static id<MTLTexture> TextureOf(NativeView view) {
    return (__bridge id<MTLTexture>)reinterpret_cast<void*>(view);
}

/// A pattern of `count` texels of `bytes` bytes where texel i depends on (x, y) and `seed`.
static std::vector<u8> Pattern(u32 width, u32 height, u32 bytes, u32 seed) {
    std::vector<u8> data(size_t(width) * height * bytes);
    for (u32 y = 0; y < height; ++y) {
        for (u32 x = 0; x < width; ++x) {
            for (u32 b = 0; b < bytes; ++b) {
                data[(size_t(y) * width + x) * bytes + b] =
                    u8((x * 7 + y * 13 + b * 31 + seed * 59 + (x >> 8) * 101 + (y >> 7) * 17) & 255);
            }
        }
    }
    return data;
}

/// The same for four half floats per texel: finite, normal values only (a copy through a float
/// shader canonicalizes NaNs and flushes denormals).
static std::vector<u8> HalfPattern(u32 width, u32 height, u32 seed) {
    const auto bytes = Pattern(width, height, 8, seed);
    std::vector<u8> data(bytes.size());
    for (size_t i = 0; i < bytes.size(); i += 2) {
        const u16 bits = u16((bytes[i + 1] & 0x80) << 8 | 0x3c00 | (bytes[i + 1] & 3) << 8 | bytes[i]);
        std::memcpy(&data[i], &bits, 2);
    }
    return data;
}

/// The texel (x, y) of `data` (`width` wide, `bytes` per texel) as a vector.
static std::vector<u8> Texel(const std::vector<u8>& data, u32 width, u32 bytes, u32 x, u32 y) {
    const u8* texel = data.data() + (size_t(y) * width + x) * bytes;
    return {texel, texel + bytes};
}

/// Every texel of `proxy` (width x height) equals the texel of `native` (nw x nh) the nearest copy
/// reads for it: for a smaller proxy the second texel of each block (the pixel centre scaled
/// lands on the border: floor((x + 0.5) * nw / width)), for a larger one the texel it lies in.
static bool ProxyMatches(const std::vector<u8>& proxy, u32 width, u32 height,
                         const std::vector<u8>& native, u32 nw, u32 nh, u32 bytes) {
    u32 bad = 0;
    for (u32 y = 0; y < height; ++y) {
        const u32 sy = std::min(u32(double(y + 0.5) * nh / height), nh - 1);
        for (u32 x = 0; x < width; ++x) {
            const u32 sx = std::min(u32(double(x + 0.5) * nw / width), nw - 1);
            if (std::memcmp(proxy.data() + (size_t(y) * width + x) * bytes,
                            native.data() + (size_t(sy) * nw + sx) * bytes, bytes) != 0) {
                if (bad++ < 3) {
                    std::printf("  texel (%u,%u) differs from the source (%u,%u)\n", x, y, sx, sy);
                }
            }
        }
    }
    return bad == 0;
}

// ---- Tests ----------------------------------------------------------------------------------------

/// A colour image of `format` (`bytes` per texel) at 1920x1080 with a proxy at 960x540: the fill
/// when the proxy is created, the resolve into the native image on a native access, the
/// invalidation by a native write and the fill after it.
static void TestColor(Fixture& f, vk::Format format, u32 bytes, vk::Format view_format) {
    std::printf("colour %s (views as %s)\n", vk::to_string(format).c_str(),
                vk::to_string(view_format).c_str());
    World world{f};
    SceneTargets targets{f.device, f.scheduler, f.runtime, world.Lookup()};
    const auto pattern = [&](u32 width, u32 height, u32 seed) {
        return bytes == 8 ? HalfPattern(width, height, seed) : Pattern(width, height, bytes, seed);
    };
    const ImageId image_id = world.Add(MakeInfo(format, 1920, 1080));
    Image& image = world.Get(image_id);
    id<MTLTexture> native = NativeOf(image);
    CHECK(native.width == 1920 && native.height == 1080);

    CHECK(targets.SetSize({960, 540}));
    CHECK(targets.Reduced());
    CHECK(targets.Eligible(image) && targets.EligibleScene(image));
    CHECK(targets.ProxySize(image, 0).width == 960 && targets.ProxySize(image, 0).height == 540);

    const auto first = pattern(1920, 1080, 1);
    WriteTexture(f, native, bytes, first);
    CHECK(!targets.Tracks(image.image_uid));
    CHECK(!targets.ProxyCurrent(image));

    ImageViewInfo info;
    info.format = view_format;
    const auto target = targets.Attachment(image_id, info);
    CHECK(target.view != 0);
    CHECK(targets.Tracks(image.image_uid));
    id<MTLTexture> proxy = TextureOf(target.view);
    CHECK(proxy.width == 960 && proxy.height == 540 && proxy.mipmapLevelCount == 1);
    CHECK(proxy.sampleCount == 1 && proxy.storageMode == MTLStorageModePrivate);
    CHECK(proxy.usage & MTLTextureUsageRenderTarget);
    CHECK(proxy.usage & MTLTextureUsageShaderRead);
    CHECK(!(proxy.usage & MTLTextureUsageShaderWrite));
    // The view is in the format the pass was asked for; the proxy itself in the image's.
    CHECK(proxy.pixelFormat ==
          MTLPixelFormat(Metal::VkToMtl::PixelFormat(f.runtime.SupportedFormat(view_format, {}))));
    // The proxy was filled from the native image (down: the second texel of each 2x2 block).
    const auto filled = ReadTexture(f, proxy, bytes);
    CHECK(ProxyMatches(filled, 960, 540, first, 1920, 1080, bytes));
    // It was handed out for drawing: ahead of the native image, valid.
    CHECK(targets.ProxyCurrent(image));

    // The pass drew something: the proxy has other contents than the native image.
    const auto drawn = pattern(960, 540, 2);
    WriteTexture(f, proxy, bytes, drawn);
    // A native read resolves the proxy into the native image (up: the texel each pixel lies in)
    // and leaves the proxy valid.
    f.runtime.Transit(&image, vk::ImageLayout::eShaderReadOnlyOptimal,
                      vk::PipelineStageFlagBits2::eFragmentShader,
                      vk::AccessFlagBits2::eShaderRead);
    CHECK(targets.ProxyCurrent(image));
    const auto resolved = ReadTexture(f, native, bytes);
    CHECK(ProxyMatches(resolved, 1920, 1080, drawn, 960, 540, bytes));
    // (Nothing is dirty now: a second read does not copy again, the contents are the same.)
    f.runtime.Transit(&image, vk::ImageLayout::eShaderReadOnlyOptimal,
                      vk::PipelineStageFlagBits2::eFragmentShader,
                      vk::AccessFlagBits2::eShaderRead);
    CHECK(ReadTexture(f, native, bytes) == resolved);

    // A native write invalidates the proxy; the next attachment fills it again.
    f.runtime.Transit(&image, vk::ImageLayout::eGeneral,
                      vk::PipelineStageFlagBits2::eComputeShader,
                      vk::AccessFlagBits2::eShaderWrite);
    CHECK(!targets.ProxyCurrent(image));
    const auto second = pattern(1920, 1080, 3);
    WriteTexture(f, native, bytes, second);
    const auto again = targets.Attachment(image_id, info);
    CHECK(again.view == target.view); // the same texture and view
    CHECK(ProxyMatches(ReadTexture(f, TextureOf(again.view), bytes), 960, 540, second, 1920, 1080,
                       bytes));

    // Sampling: the proxy of a current image comes back as a view with the view's format.
    const auto sampled = targets.SampleProxy(image, info);
    CHECK(sampled && sampled->view == again.view);

    // SetSize drops the proxies (after resolving the dirty ones: here the attachment is dirty).
    WriteTexture(f, TextureOf(again.view), bytes, drawn);
    const u64 generation = targets.Generation();
    CHECK(targets.SetSize({1280, 720}));
    CHECK(targets.Generation() != generation);
    CHECK(!targets.Tracks(image.image_uid));
    CHECK(ProxyMatches(ReadTexture(f, native, bytes), 1920, 1080, drawn, 960, 540, bytes));
    Settle(f);
}

/// The level of a half resolution mip chain has a proxy of its own: 480x270 native level 1 into a
/// 240x135 proxy (scene 960x540: the half resolution targets are 480x270).
static void TestMipChain(Fixture& f) {
    std::printf("half resolution mip chain\n");
    World world{f};
    SceneTargets targets{f.device, f.scheduler, f.runtime, world.Lookup()};
    const ImageId image_id = world.Add(MakeInfo(vk::Format::eR16G16B16A16Sfloat, 960, 540, 3));
    Image& image = world.Get(image_id);
    id<MTLTexture> native = NativeOf(image);
    CHECK(native.mipmapLevelCount == 3);
    CHECK(targets.SetSize({960, 540}));
    CHECK(targets.Eligible(image) && !targets.EligibleScene(image));
    CHECK(targets.ProxySize(image, 0).width == 480);
    CHECK(targets.ProxySize(image, 1).width == 240 && targets.ProxySize(image, 1).height == 135);

    const auto level1 = HalfPattern(480, 270, 5);
    WriteTexture(f, native, 8, level1, 1);
    ImageViewInfo info;
    info.format = vk::Format::eR16G16B16A16Sfloat;
    info.range = {{1, 0}, {1, 1}};
    const auto target = targets.Attachment(image_id, info);
    id<MTLTexture> proxy = TextureOf(target.view);
    CHECK(proxy.width == 240 && proxy.height == 135);
    CHECK(ProxyMatches(ReadTexture(f, proxy, 8), 240, 135, level1, 480, 270, 8));
    CHECK(targets.ProxyCurrent(image, 1, 1) && !targets.ProxyCurrent(image, 0, 1));
    const auto drawn = HalfPattern(240, 135, 6);
    WriteTexture(f, proxy, 8, drawn);
    f.runtime.Transit(&image, vk::ImageLayout::eShaderReadOnlyOptimal,
                      vk::PipelineStageFlagBits2::eFragmentShader,
                      vk::AccessFlagBits2::eShaderRead);
    CHECK(ProxyMatches(ReadTexture(f, native, 8, 1), 480, 270, drawn, 240, 135, 8));
    Settle(f);
}

/// Depth with stencil: both aspects through the shader copy, [[stencil]] exported.
static void TestDepthStencil(Fixture& f) {
    std::printf("depth with stencil (D32F_S8)\n");
    World world{f};
    SceneTargets targets{f.device, f.scheduler, f.runtime, world.Lookup()};
    const ImageId image_id = world.Add(MakeInfo(vk::Format::eD32SfloatS8Uint, 1920, 1080));
    Image& image = world.Get(image_id);
    id<MTLTexture> native = NativeOf(image);
    CHECK(native.pixelFormat == MTLPixelFormatDepth32Float_Stencil8);
    CHECK(targets.SetSize({960, 540}));
    CHECK(targets.Eligible(image) && targets.EligibleScene(image));

    const auto depth_of = [](u32 width, u32 height, u32 seed) {
        std::vector<u8> data(size_t(width) * height * 4);
        for (u32 y = 0; y < height; ++y) {
            for (u32 x = 0; x < width; ++x) {
                const float value = float((x * 3 + y * 5 + seed * 11) % 4096) / 4096.0f;
                std::memcpy(&data[(size_t(y) * width + x) * 4], &value, 4);
            }
        }
        return data;
    };
    const auto first_depth = depth_of(1920, 1080, 1);
    const auto first_stencil = Pattern(1920, 1080, 1, 7);
    WriteTexture(f, native, 4, first_depth, 0, MTLBlitOptionDepthFromDepthStencil);
    WriteTexture(f, native, 1, first_stencil, 0, MTLBlitOptionStencilFromDepthStencil);

    ImageViewInfo info;
    info.format = vk::Format::eD32SfloatS8Uint;
    info.is_storage = true;
    const auto target = targets.Attachment(image_id, info);
    id<MTLTexture> proxy = TextureOf(target.view);
    CHECK(proxy.width == 960 && proxy.height == 540);
    CHECK(proxy.pixelFormat == MTLPixelFormatDepth32Float_Stencil8);
    CHECK(proxy.usage & MTLTextureUsageRenderTarget);
    CHECK(ProxyMatches(ReadTexture(f, proxy, 4, 0, MTLBlitOptionDepthFromDepthStencil), 960, 540,
                       first_depth, 1920, 1080, 4));
    CHECK(ProxyMatches(ReadTexture(f, proxy, 1, 0, MTLBlitOptionStencilFromDepthStencil), 960, 540,
                       first_stencil, 1920, 1080, 1));
    // A depth proxy is never sampled in place of the native image (the core's rule).
    CHECK(!targets.SampleProxy(image, info));

    const auto drawn_depth = depth_of(960, 540, 2);
    const auto drawn_stencil = Pattern(960, 540, 1, 8);
    WriteTexture(f, proxy, 4, drawn_depth, 0, MTLBlitOptionDepthFromDepthStencil);
    WriteTexture(f, proxy, 1, drawn_stencil, 0, MTLBlitOptionStencilFromDepthStencil);
    f.runtime.Transit(&image, vk::ImageLayout::eDepthStencilReadOnlyOptimal,
                      vk::PipelineStageFlagBits2::eFragmentShader,
                      vk::AccessFlagBits2::eShaderRead);
    CHECK(ProxyMatches(ReadTexture(f, native, 4, 0, MTLBlitOptionDepthFromDepthStencil), 1920, 1080,
                       drawn_depth, 960, 540, 4));
    CHECK(ProxyMatches(ReadTexture(f, native, 1, 0, MTLBlitOptionStencilFromDepthStencil), 1920,
                       1080, drawn_stencil, 960, 540, 1));
    Settle(f);
}

static void TestEligibility(Fixture& f) {
    std::printf("eligibility\n");
    World world{f};
    SceneTargets targets{f.device, f.scheduler, f.runtime, world.Lookup()};
    CHECK(targets.SetSize({960, 540}));
    using F = vk::Format;
    const auto eligible = [&](F format, u32 w = 1920, u32 h = 1080, u32 levels = 1) {
        const ImageId image_id = world.Add(MakeInfo(format, w, h, levels));
        return targets.Eligible(world.Get(image_id));
    };
    CHECK(eligible(F::eR8G8B8A8Unorm) && eligible(F::eR8G8B8A8Srgb) && eligible(F::eB8G8R8A8Unorm));
    CHECK(eligible(F::eR16G16B16A16Sfloat) && eligible(F::eR32Sfloat) &&
          eligible(F::eB10G11R11UfloatPack32) && eligible(F::eA2B10G10R10UnormPack32));
    CHECK(eligible(F::eR8Uint) && eligible(F::eR32Uint) && eligible(F::eR16G16B16A16Uint));
    CHECK(eligible(F::eR8Sint) && eligible(F::eR32Sint));
    CHECK(eligible(F::eD32Sfloat) && eligible(F::eD32SfloatS8Uint));
    CHECK(!eligible(F::eBc1RgbaUnormBlock)); // block compressed
    CHECK(!eligible(F::eE5B9G9R9UfloatPack32)); // not renderable on every GPU: left native
    CHECK(!eligible(F::eR8G8B8A8Unorm, 1280, 720));
    // Mip chains: half resolution colour only.
    CHECK(eligible(F::eR16G16B16A16Sfloat, 960, 540, 4));
    CHECK(!eligible(F::eR16G16B16A16Sfloat, 1920, 1080, 4));
    CHECK(!eligible(F::eD32Sfloat, 960, 540, 4));
    Settle(f);
}

/// The proxies and their views go through the deferred operations: nothing is released before
/// the command buffers that use them completed (the debug layer reports otherwise), also when
/// the size changes while copies are pending.
static void TestLifetime(Fixture& f) {
    std::printf("lifetime\n");
    World world{f};
    {
        SceneTargets targets{f.device, f.scheduler, f.runtime, world.Lookup()};
        const ImageId image_id = world.Add(MakeInfo(vk::Format::eR8G8B8A8Unorm, 1920, 1080));
        ImageViewInfo info;
        info.format = vk::Format::eR8G8B8A8Srgb; // a view of its own
        for (int i = 0; i < 4; ++i) {
            targets.SetSize(i % 2 ? SceneResolution::Size{960, 540} : SceneResolution::Size{1280, 720});
            const auto target = targets.Attachment(image_id, info);
            CHECK(target.view != 0);
            // The next SetSize resolves the dirty proxy and drops it with commands in flight.
        }
        CHECK(f.runtime.scene_targets == &targets);
    }
    CHECK(f.runtime.scene_targets == nullptr);
    Settle(f);
}

int main() {
    @autoreleasepool {
        Fixture f;
        TestColor(f, vk::Format::eR8G8B8A8Unorm, 4, vk::Format::eR8G8B8A8Unorm);
        TestColor(f, vk::Format::eR8G8B8A8Unorm, 4, vk::Format::eR8G8B8A8Srgb);
        TestColor(f, vk::Format::eR16G16B16A16Sfloat, 8, vk::Format::eR16G16B16A16Sfloat);
        TestColor(f, vk::Format::eR32Uint, 4, vk::Format::eR32Uint);
        TestMipChain(f);
        TestDepthStencil(f);
        TestEligibility(f);
        TestLifetime(f);
        Settle(f);
        CHECK(!f.scheduler.HasFailed());
    }
    std::printf(failures ? "%d check(s) FAILED\n" : "all checks passed\n", failures);
    return failures ? 1 : 0;
}
