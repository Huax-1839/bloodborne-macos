// SPDX-License-Identifier: GPL-2.0-or-later
// Counterpart: renderer_vulkan/vk_scene_resolution.cpp (the Metal part of the reduced scene
// targets: proxy textures, the copies between a proxy and the native image, views). The
// bookkeeping is VideoCore::SceneTargetsCore's. Design: docs/metal/live_resolution_design.md.

#import <Metal/Metal.h>

#include <cstdio>
#include <unordered_map>
#include <vector>

#include "common/assert.h"
#include "video_core/renderer_metal/mtl_runtime_impl.h"
#include "video_core/renderer_metal/mtl_scene_targets.h"
#include "video_core/renderer_metal/vk_to_mtl.h"
#include "video_core/texture_cache/texture_cache.h"

namespace Metal {
namespace {

/// How a copy reads and writes a format.
enum class Class : u8 { None, Float, Uint, Sint, Depth, DepthStencil };

/// The class of a texture's pixel format; None for the formats the copy passes do not handle.
Class ClassOf(MTLPixelFormat format) {
    switch (format) {
    case MTLPixelFormatR8Unorm:
    case MTLPixelFormatR8Unorm_sRGB:
    case MTLPixelFormatR8Snorm:
    case MTLPixelFormatRG8Unorm:
    case MTLPixelFormatRG8Unorm_sRGB:
    case MTLPixelFormatRG8Snorm:
    case MTLPixelFormatRGBA8Unorm:
    case MTLPixelFormatRGBA8Unorm_sRGB:
    case MTLPixelFormatRGBA8Snorm:
    case MTLPixelFormatBGRA8Unorm:
    case MTLPixelFormatBGRA8Unorm_sRGB:
    case MTLPixelFormatR16Unorm:
    case MTLPixelFormatR16Snorm:
    case MTLPixelFormatR16Float:
    case MTLPixelFormatRG16Unorm:
    case MTLPixelFormatRG16Snorm:
    case MTLPixelFormatRG16Float:
    case MTLPixelFormatRGBA16Unorm:
    case MTLPixelFormatRGBA16Snorm:
    case MTLPixelFormatRGBA16Float:
    case MTLPixelFormatR32Float:
    case MTLPixelFormatRG32Float:
    case MTLPixelFormatRGBA32Float:
    case MTLPixelFormatRG11B10Float:
    case MTLPixelFormatRGB10A2Unorm:
    case MTLPixelFormatBGR10A2Unorm:
        return Class::Float;
    case MTLPixelFormatR8Uint:
    case MTLPixelFormatR16Uint:
    case MTLPixelFormatR32Uint:
    case MTLPixelFormatRG8Uint:
    case MTLPixelFormatRG16Uint:
    case MTLPixelFormatRG32Uint:
    case MTLPixelFormatRGBA8Uint:
    case MTLPixelFormatRGBA16Uint:
    case MTLPixelFormatRGBA32Uint:
    case MTLPixelFormatRGB10A2Uint:
        return Class::Uint;
    case MTLPixelFormatR8Sint:
    case MTLPixelFormatR16Sint:
    case MTLPixelFormatR32Sint:
    case MTLPixelFormatRG8Sint:
    case MTLPixelFormatRG16Sint:
    case MTLPixelFormatRG32Sint:
    case MTLPixelFormatRGBA8Sint:
    case MTLPixelFormatRGBA16Sint:
    case MTLPixelFormatRGBA32Sint:
        return Class::Sint;
    case MTLPixelFormatDepth16Unorm:
    case MTLPixelFormatDepth32Float:
        return Class::Depth;
    case MTLPixelFormatDepth32Float_Stencil8:
        return Class::DepthStencil;
    default:
        return Class::None;
    }
}

bool IsDepth(Class cls) {
    return cls == Class::Depth || cls == Class::DepthStencil;
}

/// What the copy passes draw with: a fullscreen triangle (vertex 0, 1, 2 cover the clip space) and
/// per format class a fragment shader that reads the source texel under the destination pixel,
/// scaled: `scale` is source size / destination size, `position.xy` the pixel centre, so a
/// pixel of a half size target reads the second texel of its 2x2 block, and a pixel of a double
/// size one the texel it lies in (nearest, as the Vulkan backend's blit).
NSString* const CopySource = @"#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct TriOut { float4 position [[position]]; };\n"
    "vertex TriOut scene_tri(uint vertex_id [[vertex_id]]) {\n"
    "    float2 p = float2(float((vertex_id << 1) & 2), float(vertex_id & 2));\n"
    "    TriOut out;\n"
    "    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);\n"
    "    return out;\n"
    "}\n"
    "uint2 SourceTexel(float4 position, float2 scale, uint2 size) {\n"
    "    return min(uint2(position.xy * scale), size - 1);\n"
    "}\n"
    "fragment float4 scene_copy_float(TriOut in [[stage_in]],\n"
    "                                 texture2d<float> source [[texture(0)]],\n"
    "                                 constant float2& scale [[buffer(0)]]) {\n"
    "    return source.read(SourceTexel(in.position, scale,\n"
    "                                   uint2(source.get_width(), source.get_height())));\n"
    "}\n"
    "fragment uint4 scene_copy_uint(TriOut in [[stage_in]],\n"
    "                               texture2d<uint> source [[texture(0)]],\n"
    "                               constant float2& scale [[buffer(0)]]) {\n"
    "    return source.read(SourceTexel(in.position, scale,\n"
    "                                   uint2(source.get_width(), source.get_height())));\n"
    "}\n"
    "fragment int4 scene_copy_sint(TriOut in [[stage_in]],\n"
    "                              texture2d<int> source [[texture(0)]],\n"
    "                              constant float2& scale [[buffer(0)]]) {\n"
    "    return source.read(SourceTexel(in.position, scale,\n"
    "                                   uint2(source.get_width(), source.get_height())));\n"
    "}\n"
    "struct DepthOut { float depth [[depth(any)]]; };\n"
    "fragment DepthOut scene_copy_depth(TriOut in [[stage_in]],\n"
    "                                   depth2d<float> source [[texture(0)]],\n"
    "                                   constant float2& scale [[buffer(0)]]) {\n"
    "    DepthOut out;\n"
    "    out.depth = source.read(SourceTexel(in.position, scale,\n"
    "                                        uint2(source.get_width(), source.get_height())));\n"
    "    return out;\n"
    "}\n"
    "struct DepthStencilOut { float depth [[depth(any)]]; uint stencil [[stencil]]; };\n"
    "fragment DepthStencilOut scene_copy_depth_stencil(TriOut in [[stage_in]],\n"
    "                                                  depth2d<float> source [[texture(0)]],\n"
    "                                                  texture2d<uint> stencil [[texture(1)]],\n"
    "                                                  constant float2& scale [[buffer(0)]]) {\n"
    "    const uint2 texel = SourceTexel(in.position, scale,\n"
    "                                    uint2(source.get_width(), source.get_height()));\n"
    "    DepthStencilOut out;\n"
    "    out.depth = source.read(texel);\n"
    "    out.stencil = stencil.read(texel).x;\n"
    "    return out;\n"
    "}\n";

id<MTLTexture> TextureOf(const VideoCore::UniqueImage& image) {
    return (__bridge id<MTLTexture>)image.native;
}

VideoCore::NativeView NativeViewOf(id<MTLTexture> texture) {
    return reinterpret_cast<VideoCore::NativeView>((__bridge void*)texture);
}

std::string ErrorText(NSError* error) {
    return error ? error.localizedDescription.UTF8String : "unknown";
}

} // namespace

/// The pipelines of the copy passes (made on first use, on the recording thread).
struct SceneTargets::Impl {
    Device::Impl& dev;
    id<MTLLibrary> library = nil;
    id<MTLDepthStencilState> depth_always = nil;   ///< writes every fragment's depth
    id<MTLDepthStencilState> stencil_replace = nil; ///< ... and the exported stencil
    std::unordered_map<u32, id<MTLRenderPipelineState>> pipelines; ///< by the target's pixel format

    explicit Impl(Device::Impl& dev_) : dev{dev_} {}

    id<MTLRenderPipelineState> Pipeline(MTLPixelFormat format) {
        auto& pipeline = pipelines[u32(format)];
        if (pipeline) {
            return pipeline;
        }
        if (!library) {
            NSError* error = nil;
            MTLCompileOptions* options = [MTLCompileOptions new];
            options.languageVersion = MTLLanguageVersion3_1;
            library = [dev.device newLibraryWithSource:CopySource options:options error:&error];
            ASSERT_MSG(library, "Scene proxy copy shaders did not compile: {}", ErrorText(error));
        }
        const Class cls = ClassOf(format);
        NSString* fragment = nil;
        switch (cls) {
        case Class::Float:
            fragment = @"scene_copy_float";
            break;
        case Class::Uint:
            fragment = @"scene_copy_uint";
            break;
        case Class::Sint:
            fragment = @"scene_copy_sint";
            break;
        case Class::Depth:
            fragment = @"scene_copy_depth";
            break;
        case Class::DepthStencil:
            fragment = @"scene_copy_depth_stencil";
            break;
        case Class::None:
            UNREACHABLE_MSG("Scene proxy copy of pixel format {}", u32(format));
        }
        MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.label = @"Scene proxy copy";
        descriptor.vertexFunction = [library newFunctionWithName:@"scene_tri"];
        descriptor.fragmentFunction = [library newFunctionWithName:fragment];
        if (IsDepth(cls)) {
            descriptor.depthAttachmentPixelFormat = format;
            if (cls == Class::DepthStencil) {
                descriptor.stencilAttachmentPixelFormat = format;
            }
        } else {
            descriptor.colorAttachments[0].pixelFormat = format;
        }
        NSError* error = nil;
        pipeline = [dev.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        ASSERT_MSG(pipeline, "Scene proxy copy pipeline failed (pixel format {}): {}", u32(format),
                   ErrorText(error));
        return pipeline;
    }

    id<MTLDepthStencilState> DepthState(bool stencil) {
        __strong id<MTLDepthStencilState>& state = stencil ? stencil_replace : depth_always;
        if (!state) {
            MTLDepthStencilDescriptor* descriptor = [MTLDepthStencilDescriptor new];
            descriptor.depthCompareFunction = MTLCompareFunctionAlways;
            descriptor.depthWriteEnabled = YES;
            if (stencil) {
                // The fragment's stencil output replaces the reference value; every outcome
                // writes it.
                MTLStencilDescriptor* replace = [MTLStencilDescriptor new];
                replace.stencilCompareFunction = MTLCompareFunctionAlways;
                replace.stencilFailureOperation = MTLStencilOperationReplace;
                replace.depthFailureOperation = MTLStencilOperationReplace;
                replace.depthStencilPassOperation = MTLStencilOperationReplace;
                replace.readMask = 0xff;
                replace.writeMask = 0xff;
                descriptor.frontFaceStencil = replace;
                descriptor.backFaceStencil = replace;
            }
            state = [dev.device newDepthStencilStateWithDescriptor:descriptor];
        }
        return state;
    }
};

/// A proxy: its texture (made by the runtime, so it is resident and released by the deferred
/// destroys) and the views of it handed out, by view format and swizzle.
struct SceneTargets::Proxy final : ProxyData {
    ~Proxy() override {
        // Command buffers do not retain what they use: the views go once the GPU is done with
        // the open tick, like the texture (Runtime::DestroyImage).
        if (!views.empty()) {
            scheduler->DeferOperation([views = std::move(views)] { (void)views; });
        }
    }

    struct View {
        vk::Format format;
        vk::ComponentMapping mapping;
        id<MTLTexture> texture;
    };
    VideoCore::UniqueImage image;
    vk::Format base_format{}; ///< the Vulkan format the texture was made in
    std::vector<View> views;
    Scheduler* scheduler = nullptr;
};

SceneTargets::Proxy& SceneTargets::Of(Entry& entry) {
    return static_cast<Proxy&>(*entry.proxy);
}

SceneTargets::SceneTargets(Device& device_, Scheduler& scheduler_, Runtime& runtime_,
                           VideoCore::TextureCache& texture_cache)
    : SceneTargets(device_, scheduler_, runtime_,
                   [&texture_cache](VideoCore::ImageId id, u64 uid) {
                       return texture_cache.TryGetImage(id, uid);
                   }) {}

SceneTargets::SceneTargets(Device& device_, Scheduler& scheduler_, Runtime& runtime_, Lookup get)
    : SceneTargetsCore{std::move(get)}, device{device_}, scheduler{scheduler_},
      runtime{runtime_}, impl{std::make_unique<Impl>(device_.GetImpl())} {
    runtime.scene_targets = this;
}

SceneTargets::~SceneTargets() {
    runtime.scene_targets = nullptr;
    // The pipelines may be in a command buffer in flight; the proxies and their views follow
    // (the entries' destructors) through the runtime's and the scheduler's deferred operations.
    scheduler.DeferOperation([impl = std::move(impl)] { (void)impl; });
}

bool SceneTargets::ProxyFormatSupported(const VideoCore::Image& image) const {
    // From the creation info of the texture (no message to the texture): Eligible asks this for
    // every attachment of every draw.
    const auto& ci = image.backing->image.image_ci;
    return image.backing->image.native && ci.imageType == vk::ImageType::e2D &&
           ci.samples == vk::SampleCountFlagBits::e1 &&
           ClassOf(MTLPixelFormat(VkToMtl::PixelFormat(ci.format))) != Class::None;
}

bool SceneTargets::MipChainFormatSupported(const VideoCore::Image& image) const {
    const auto& ci = image.backing->image.image_ci;
    const Class cls = ClassOf(MTLPixelFormat(VkToMtl::PixelFormat(ci.format)));
    return image.backing->image.native && ci.imageType == vk::ImageType::e2D && cls != Class::None &&
           !IsDepth(cls);
}

std::unique_ptr<VideoCore::SceneTargetsCore::ProxyData> SceneTargets::CreateProxy(
    const VideoCore::Image& original, VideoCore::SceneResolution::Size size) {
    auto data = std::make_unique<Proxy>();
    data->scheduler = &scheduler;
    auto ci = original.backing->image.image_ci;
    ci.pNext = nullptr;
    ci.extent = vk::Extent3D{size.width, size.height, 1};
    ci.mipLevels = 1;
    ci.arrayLayers = 1;
    ci.samples = vk::SampleCountFlagBits::e1;
    // Sampled by the passes and the upscaler, drawn into; never written by a shader (no storage:
    // a texture that is only a render target keeps the GPU's lossless compression).
    const bool depth = IsDepth(ClassOf(MTLPixelFormat(VkToMtl::PixelFormat(ci.format))));
    ci.usage = vk::ImageUsageFlagBits::eSampled |
               (depth ? vk::ImageUsageFlagBits::eDepthStencilAttachment
                      : vk::ImageUsageFlagBits::eColorAttachment);
    // (Views: the formats of the passes' pipelines, the stencil of a combined depth format.)
    ci.flags = vk::ImageCreateFlagBits::eMutableFormat;
    runtime.CreateImage(data->image, ci);
    data->base_format = ci.format;
    runtime.SetImageName(data->image, fmt::format("Scene proxy {}x{} {}", size.width, size.height,
                                                  vk::to_string(original.info.pixel_format)));
    return data;
}

void SceneTargets::Finish() {
    scheduler.Finish();
}

vk::ImageLayout SceneTargets::Prepare(Entry&, const VideoCore::Image& original, Use use) {
    // Metal has no layouts; the values are the ones the Vulkan targets would hand out.
    if (use == Use::Sample) {
        return vk::ImageLayout::eShaderReadOnlyOptimal;
    }
    return original.info.props.is_depth ? vk::ImageLayout::eDepthStencilAttachmentOptimal
                                        : vk::ImageLayout::eColorAttachmentOptimal;
}

void SceneTargets::NativeAccess(VideoCore::Image& image, vk::AccessFlags2 access) {
    constexpr auto writes = vk::AccessFlagBits2::eShaderWrite | vk::AccessFlagBits2::eTransferWrite |
                            vk::AccessFlagBits2::eColorAttachmentWrite |
                            vk::AccessFlagBits2::eDepthStencilAttachmentWrite |
                            vk::AccessFlagBits2::eMemoryWrite;
    SceneTargetsCore::NativeAccess(image, bool(access & writes));
}

void SceneTargets::CopyProxy(Entry& e, VideoCore::Image& original, bool to_native) {
    auto& data = Of(e);
    // The copy is a render pass of its own: the open one ends (a held pass is released), and the
    // draw that follows begins its pass again (the core decides that by IsRenderingWith).
    scheduler.EndRendering();
    if (debug) {
        std::printf("Scene %s: %s %ux%u level %u\n", to_native ? "resolve" : "fill",
                    vk::to_string(original.info.pixel_format).c_str(), original.info.size.width,
                    original.info.size.height, e.level);
    }
    id<MTLTexture> proxy = TextureOf(data.image);
    id<MTLTexture> native = NativeTexture(original);
    const Class cls = ClassOf(proxy.pixelFormat);
    const bool depth = IsDepth(cls);
    // The shared image state's bookkeeping, as Vulkan's copies keep it (Metal tracks the hazards
    // of the textures itself).
    const VideoCore::SubresourceRange level_range{.base = {e.level, 0}, .extent = {1, 1}};
    if (to_native) {
        runtime.Transit(&original,
                        depth ? vk::ImageLayout::eDepthStencilAttachmentOptimal
                              : vk::ImageLayout::eColorAttachmentOptimal,
                        depth ? vk::PipelineStageFlagBits2::eEarlyFragmentTests |
                                    vk::PipelineStageFlagBits2::eLateFragmentTests
                              : vk::PipelineStageFlags2(
                                    vk::PipelineStageFlagBits2::eColorAttachmentOutput),
                        depth ? vk::AccessFlagBits2::eDepthStencilAttachmentWrite
                              : vk::AccessFlagBits2::eColorAttachmentWrite,
                        level_range);
    } else {
        runtime.Transit(&original,
                        depth ? vk::ImageLayout::eDepthStencilReadOnlyOptimal
                              : vk::ImageLayout::eShaderReadOnlyOptimal,
                        vk::PipelineStageFlagBits2::eFragmentShader,
                        vk::AccessFlagBits2::eShaderRead, level_range);
    }
    runtime.FlushBarriers();

    @autoreleasepool {
        // The native side of one mip level: the texture itself, or a view of that level.
        id<MTLTexture> level = native;
        if (e.level != 0 || native.mipmapLevelCount > 1) {
            level = [native newTextureViewWithPixelFormat:native.pixelFormat
                                              textureType:MTLTextureType2D
                                                   levels:NSMakeRange(e.level, 1)
                                                   slices:NSMakeRange(0, 1)];
            ASSERT_MSG(level, "Failed to view level {} of a scene image", e.level);
        }
        id<MTLTexture> source = to_native ? proxy : level;
        id<MTLTexture> target = to_native ? level : proxy;
        // The stencil of a combined format is read through a view of its own.
        id<MTLTexture> stencil = nil;
        if (cls == Class::DepthStencil) {
            stencil = [source newTextureViewWithPixelFormat:MTLPixelFormatX32_Stencil8];
            ASSERT_MSG(stencil, "Failed to view the stencil of a scene image");
        }
        // What the command buffer uses but does not retain stays alive until it is done.
        if (level != native || stencil) {
            scheduler.DeferOperation([level, stencil] {
                (void)level;
                (void)stencil;
            });
        }

        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        if (depth) {
            pass.depthAttachment.texture = target;
            pass.depthAttachment.loadAction = MTLLoadActionDontCare; // the triangle covers it
            pass.depthAttachment.storeAction = MTLStoreActionStore;
            if (cls == Class::DepthStencil) {
                pass.stencilAttachment.texture = target;
                pass.stencilAttachment.loadAction = MTLLoadActionDontCare;
                pass.stencilAttachment.storeAction = MTLStoreActionStore;
            }
        } else {
            pass.colorAttachments[0].texture = target;
            pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        }
        scheduler.RenderEncoder((__bridge const void*)pass);
        scheduler.LabelEncoder(to_native ? "Scene proxy resolve" : "Scene proxy fill");
        id<MTLRenderCommandEncoder> render = scheduler.GetImpl().render;
        [render setRenderPipelineState:impl->Pipeline(target.pixelFormat)];
        if (depth) {
            [render setDepthStencilState:impl->DepthState(cls == Class::DepthStencil)];
        }
        [render setViewport:MTLViewport{0, 0, double(target.width), double(target.height), 0, 1}];
        const float scale[2] = {float(source.width) / float(target.width),
                                float(source.height) / float(target.height)};
        [render setFragmentBytes:scale length:sizeof(scale) atIndex:0];
        [render setFragmentTexture:source atIndex:0];
        if (stencil) {
            [render setFragmentTexture:stencil atIndex:1];
        }
        [render drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        scheduler.EndRendering();
    }
}

VideoCore::NativeView SceneTargets::View(Entry& e, const VideoCore::Image&,
                                         const VideoCore::ImageViewInfo& info, bool) {
    auto& proxy = Of(e);
    id<MTLTexture> base = TextureOf(proxy.image);
    if (IsDepth(ClassOf(base.pixelFormat))) {
        return NativeViewOf(base); // the whole texture: depth is read and attached as it is
    }
    for (const auto& view : proxy.views) {
        if (view.format == info.format && view.mapping == info.mapping) {
            return NativeViewOf(view.texture);
        }
    }
    // The view's pixel format and swizzle as Runtime::CreateImageView derives them for the
    // native image, so that a pass finds the format its pipeline was made for.
    MTLPixelFormat pixel_format = base.pixelFormat;
    const vk::Format format = runtime.SupportedFormat(info.format, {});
    const u32 view_format = VkToMtl::PixelFormat(format);
    if (view_format != 0 && view_format != u32(base.pixelFormat) &&
        (base.usage & MTLTextureUsagePixelFormatView) &&
        runtime.ViewFormatCompatible(proxy.base_format, info.format)) {
        pixel_format = MTLPixelFormat(view_format);
    }
    const VkToMtl::TextureSwizzle swizzle = VkToMtl::ComposeSwizzle(info.mapping, format);
    id<MTLTexture> texture = base;
    if (pixel_format != base.pixelFormat || swizzle != VkToMtl::IdentitySwizzle) {
        texture = [base newTextureViewWithPixelFormat:pixel_format
                                          textureType:MTLTextureType2D
                                               levels:NSMakeRange(0, 1)
                                               slices:NSMakeRange(0, 1)
                                              swizzle:MTLTextureSwizzleChannelsMake(
                                                          MTLTextureSwizzle(swizzle.r),
                                                          MTLTextureSwizzle(swizzle.g),
                                                          MTLTextureSwizzle(swizzle.b),
                                                          MTLTextureSwizzle(swizzle.a))];
        ASSERT_MSG(texture, "Failed to create a view (format {}) of a scene proxy",
                   vk::to_string(info.format));
    }
    proxy.views.push_back({info.format, info.mapping, texture});
    return NativeViewOf(texture);
}

SceneTargets::Target SceneTargets::Attachment(VideoCore::ImageId id,
                                              const VideoCore::ImageViewInfo& info) {
    auto& original = Original(id);
    vk::ImageLayout layout;
    auto& entry = BeginAttachment(id, info, layout);
    return {View(entry, original, info, true), layout};
}

std::optional<SceneTargets::Target> SceneTargets::SampleProxy(
    const VideoCore::Image& image, const VideoCore::ImageViewInfo& info) {
    vk::ImageLayout layout;
    Entry* entry = BeginSample(image, info, layout);
    if (!entry) {
        return std::nullopt;
    }
    return Target{View(*entry, image, info, false), layout};
}

SceneTargets::Target SceneTargets::Read(VideoCore::ImageId id,
                                        const VideoCore::ImageViewInfo& info) {
    auto& original = Original(id);
    auto& entry = Get(id);
    return {View(entry, original, info, false), vk::ImageLayout::eGeneral};
}

} // namespace Metal
