// SPDX-License-Identifier: GPL-2.0-or-later
// The caches' own GPU work on Metal (plan P2.4, docs/metal/cache_backend_design.md group C): the
// D11 host shaders for detiling/tiling and the fault buffer parser, and the fullscreen passes of
// the MSAA copies. Counterparts: vk_tile_kernels.cpp, vk_fault_parser.cpp, vk_blit_helper.cpp.

#include <string>

#include "common/assert.h"
#include "common/logging/log.h"
#include "video_core/renderer_metal/mtl_runtime_impl.h"

#include "video_core/host_shaders_msl/color_to_ms_depth_frag_msl.h"
#include "video_core/host_shaders_msl/fault_buffer_process_comp_msl.h"
#include "video_core/host_shaders_msl/fs_tri_vert_msl.h"
#include "video_core/host_shaders_msl/ms_image_blit_frag_msl.h"
#include "video_core/host_shaders_msl/ms_image_blit_msaa_frag_msl.h"
#include "video_core/host_shaders_msl/tiling_macro_128_comp_msl.h"
#include "video_core/host_shaders_msl/tiling_macro_16_comp_msl.h"
#include "video_core/host_shaders_msl/tiling_macro_32_comp_msl.h"
#include "video_core/host_shaders_msl/tiling_macro_64_comp_msl.h"
#include "video_core/host_shaders_msl/tiling_macro_8_comp_msl.h"
#include "video_core/host_shaders_msl/tiling_macro_96_comp_msl.h"
#include "video_core/host_shaders_msl/tiling_micro_128_comp_msl.h"
#include "video_core/host_shaders_msl/tiling_micro_16_comp_msl.h"
#include "video_core/host_shaders_msl/tiling_micro_32_comp_msl.h"
#include "video_core/host_shaders_msl/tiling_micro_64_comp_msl.h"
#include "video_core/host_shaders_msl/tiling_micro_8_comp_msl.h"
#include "video_core/host_shaders_msl/tiling_micro_96_comp_msl.h"

namespace Metal {
namespace H = HostShaders;
namespace {

// A 32 bit pattern that is not four equal bytes (those use the blit encoder's fillBuffer).
NSString* const FillSource = @"#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void fill_u32(device uint* dst [[buffer(0)]], constant uint& value [[buffer(1)]],\n"
    "                     constant uint& count [[buffer(2)]], uint id [[thread_position_in_grid]]) {\n"
    "    if (id < count) {\n"
    "        dst[id] = value;\n"
    "    }\n"
    "}\n";

MTLCompileOptions* CompileOptions() {
    // The options of mtl_shader.mm: Metal 3.1, no fast math (the host shaders are SPIR-V ports).
    MTLCompileOptions* options = [MTLCompileOptions new];
    options.languageVersion = MTLLanguageVersion3_1;
    options.mathMode = MTLMathModeSafe;
    return options;
}

const H::Shader& TilingShader(u32 num_bits, bool is_macro) {
    switch (num_bits) {
    case 8:
        return is_macro ? H::TILING_MACRO_8_COMP : H::TILING_MICRO_8_COMP;
    case 16:
        return is_macro ? H::TILING_MACRO_16_COMP : H::TILING_MICRO_16_COMP;
    case 32:
        return is_macro ? H::TILING_MACRO_32_COMP : H::TILING_MICRO_32_COMP;
    case 64:
        return is_macro ? H::TILING_MACRO_64_COMP : H::TILING_MICRO_64_COMP;
    case 96:
        return is_macro ? H::TILING_MACRO_96_COMP : H::TILING_MICRO_96_COMP;
    case 128:
        return is_macro ? H::TILING_MACRO_128_COMP : H::TILING_MICRO_128_COMP;
    default:
        UNREACHABLE_MSG("Unsupported tiling pixel width {}", num_bits);
    }
}

std::string ErrorText(NSError* error) {
    return error ? error.localizedDescription.UTF8String : "unknown";
}
} // namespace

HostKernels::HostKernels(Device::Impl& dev_, Scheduler& scheduler_)
    : dev{dev_}, scheduler{scheduler_} {}

HostKernels::~HostKernels() = default;

u32 HostKernels::BufferSlot(const H::Shader& shader, u32 binding) {
    for (const H::Binding& b : shader.bindings) {
        if (b.kind == H::Binding::Kind::Buffer && b.set == 0 && b.binding == binding) {
            return b.msl_index;
        }
    }
    UNREACHABLE_MSG("Host shader without buffer binding {}", binding);
}

id<MTLLibrary> HostKernels::Library(const H::Shader& shader) {
    if (const auto it = libraries.find(&shader); it != libraries.end()) {
        return it->second;
    }
    NSString* source = [[NSString alloc] initWithBytes:shader.msl.data()
                                                length:shader.msl.size()
                                              encoding:NSUTF8StringEncoding];
    NSError* error = nil;
    id<MTLLibrary> library = [dev.device newLibraryWithSource:source
                                                      options:CompileOptions()
                                                        error:&error];
    ASSERT_MSG(library, "Host shader '{}' did not compile: {}", std::string(shader.entry),
               ErrorText(error));
    libraries.emplace(&shader, library);
    return library;
}

id<MTLFunction> HostKernels::Function(const H::Shader& shader, const u32* constants, u32 count) {
    id<MTLLibrary> library = Library(shader);
    NSString* entry = [[NSString alloc] initWithBytes:shader.entry.data()
                                               length:shader.entry.size()
                                             encoding:NSUTF8StringEncoding];
    id<MTLFunction> function = nil;
    if (shader.spec_constants.empty()) {
        function = [library newFunctionWithName:entry];
        ASSERT_MSG(function, "Host shader function '{}' not found", std::string(shader.entry));
        return function;
    }
    MTLFunctionConstantValues* values = [MTLFunctionConstantValues new];
    for (const H::SpecConstant& constant : shader.spec_constants) {
        if (constant.id >= count) {
            continue; // the default of the SPIR-V
        }
        u32 value = constants[constant.id];
        switch (constant.type) {
        case H::SpecConstant::Type::Bool: {
            bool flag = value != 0;
            [values setConstantValue:&flag type:MTLDataTypeBool atIndex:constant.id];
            break;
        }
        case H::SpecConstant::Type::U32:
            [values setConstantValue:&value type:MTLDataTypeUInt atIndex:constant.id];
            break;
        case H::SpecConstant::Type::I32:
            [values setConstantValue:&value type:MTLDataTypeInt atIndex:constant.id];
            break;
        case H::SpecConstant::Type::F32:
            [values setConstantValue:&value type:MTLDataTypeFloat atIndex:constant.id];
            break;
        }
    }
    NSError* error = nil;
    function = [library newFunctionWithName:entry constantValues:values error:&error];
    ASSERT_MSG(function, "Host shader function '{}' with constants failed: {}",
               std::string(shader.entry), ErrorText(error));
    return function;
}

id<MTLComputePipelineState> HostKernels::ComputePipeline(const H::Shader& shader,
                                                         const u32* constants, u32 count,
                                                         NSString* label) {
    id<MTLFunction> function = Function(shader, constants, count);
    NSError* error = nil;
    id<MTLComputePipelineState> pipeline =
        [dev.device newComputePipelineStateWithFunction:function error:&error];
    ASSERT_MSG(pipeline, "Compute pipeline '{}' failed: {}", label.UTF8String, ErrorText(error));
    return pipeline;
}

id<MTLComputePipelineState> HostKernels::Tiling(const VideoCore::TilingDispatch& dispatch,
                                                const H::Shader*& shader_out) {
    const H::Shader& shader = TilingShader(dispatch.key.num_bits, dispatch.is_macro);
    shader_out = &shader;
    TilingKey key{dispatch.key.num_bits, dispatch.is_macro, {}};
    std::get<2>(key) = dispatch.constants;
    for (u32 i = dispatch.num_constants; i < 12; ++i) {
        std::get<2>(key)[i] = 0; // unused entries must not split the cache
    }
    if (const auto it = tiling.find(key); it != tiling.end()) {
        return it->second;
    }
    NSString* label = [NSString stringWithFormat:@"tiling %@ %u %s",
                                                 dispatch.is_macro ? @"macro" : @"micro",
                                                 dispatch.key.num_bits,
                                                 dispatch.key.is_tiler ? "tiler" : "detiler"];
    LOG_INFO(Render, "Creating tiling pipeline {}", label.UTF8String);
    id<MTLComputePipelineState> pipeline =
        ComputePipeline(shader, dispatch.constants.data(), dispatch.num_constants, label);
    tiling.emplace(key, pipeline);
    return pipeline;
}

void HostKernels::CreateFaultParser(u32 page_bits, u32 max_faults) {
    const std::array<u32, 2> constants{page_bits, max_faults};
    fault_parser = ComputePipeline(H::FAULT_BUFFER_PROCESS_COMP, constants.data(),
                                   static_cast<u32>(constants.size()), @"Fault Buffer Parser");
}

id<MTLComputePipelineState> HostKernels::FillU32() {
    if (!fill_u32) {
        NSError* error = nil;
        id<MTLLibrary> library = [dev.device newLibraryWithSource:FillSource
                                                          options:CompileOptions()
                                                            error:&error];
        ASSERT_MSG(library, "fill_u32 did not compile: {}", ErrorText(error));
        fill_u32 = [dev.device newComputePipelineStateWithFunction:[library newFunctionWithName:@"fill_u32"]
                                                             error:&error];
        ASSERT_MSG(fill_u32, "fill_u32 pipeline failed: {}", ErrorText(error));
    }
    return fill_u32;
}

id<MTLRenderPipelineState> HostKernels::MsCopyPipeline(u32 samples, MTLPixelFormat format,
                                                       bool src_msaa) {
    const auto key = std::make_tuple(samples, static_cast<u32>(format), src_msaa);
    if (const auto it = ms_copy.find(key); it != ms_copy.end()) {
        return it->second;
    }
    MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.label = [NSString stringWithFormat:@"Image to MS image %u", samples];
    descriptor.vertexFunction = Function(H::FS_TRI_VERT, nullptr, 0);
    descriptor.fragmentFunction =
        Function(src_msaa ? H::MS_IMAGE_BLIT_MSAA_FRAG : H::MS_IMAGE_BLIT_FRAG, nullptr, 0);
    descriptor.rasterSampleCount = samples;
    descriptor.colorAttachments[0].pixelFormat = format;
    NSError* error = nil;
    id<MTLRenderPipelineState> pipeline =
        [dev.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    ASSERT_MSG(pipeline, "MS copy pipeline failed: {}", ErrorText(error));
    ms_copy.emplace(key, pipeline);
    return pipeline;
}

id<MTLRenderPipelineState> HostKernels::MsDepthPipeline(u32 samples, MTLPixelFormat format) {
    const auto key = std::make_pair(samples, static_cast<u32>(format));
    if (const auto it = ms_depth.find(key); it != ms_depth.end()) {
        return it->second;
    }
    MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.label = [NSString stringWithFormat:@"Color to MS depth %u", samples];
    descriptor.vertexFunction = Function(H::FS_TRI_VERT, nullptr, 0);
    descriptor.fragmentFunction = Function(H::COLOR_TO_MS_DEPTH_FRAG, nullptr, 0);
    descriptor.rasterSampleCount = samples;
    descriptor.depthAttachmentPixelFormat = format;
    NSError* error = nil;
    id<MTLRenderPipelineState> pipeline =
        [dev.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    ASSERT_MSG(pipeline, "Color to MS depth pipeline failed: {}", ErrorText(error));
    ms_depth.emplace(key, pipeline);
    return pipeline;
}

void HostKernels::CopyBetweenMsImages(id<MTLTexture> src, id<MTLTexture> dst, u32 samples,
                                      bool src_msaa) {
    id<MTLRenderPipelineState> pipeline = MsCopyPipeline(samples, dst.pixelFormat, src_msaa);
    // The triangle covers every sample of the target: nothing to load.
    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = dst;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    scheduler.RenderEncoder((__bridge const void*)pass);
    id<MTLRenderCommandEncoder> render = scheduler.GetImpl().render;
    [render setRenderPipelineState:pipeline];
    [render setFragmentTexture:src atIndex:0];
    [render setViewport:MTLViewport{0, 0, double(dst.width), double(dst.height), 0, 1}];
    [render drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    scheduler.EndRendering();
}

void HostKernels::ColorToMsDepth(id<MTLTexture> src, id<MTLTexture> dst) {
    id<MTLRenderPipelineState> pipeline = MsDepthPipeline(static_cast<u32>(dst.sampleCount),
                                                          dst.pixelFormat);
    if (!depth_always_write) {
        MTLDepthStencilDescriptor* descriptor = [MTLDepthStencilDescriptor new];
        descriptor.depthCompareFunction = MTLCompareFunctionAlways;
        descriptor.depthWriteEnabled = YES;
        depth_always_write = [dev.device newDepthStencilStateWithDescriptor:descriptor];
    }
    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.depthAttachment.texture = dst;
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.clearDepth = 1.0;
    pass.depthAttachment.storeAction = MTLStoreActionStore;
    scheduler.RenderEncoder((__bridge const void*)pass);
    id<MTLRenderCommandEncoder> render = scheduler.GetImpl().render;
    [render setRenderPipelineState:pipeline];
    [render setDepthStencilState:depth_always_write];
    [render setFragmentTexture:src atIndex:0];
    [render setViewport:MTLViewport{0, 0, double(dst.width), double(dst.height), 0, 1}];
    [render drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    scheduler.EndRendering();
}

// ---- Runtime: the kernels behind the CacheBackend ------------------------------------------

void Runtime::DispatchTiling(const VideoCore::TilingDispatch& dispatch) {
    if (dispatch.group_count_x == 0) {
        return;
    }
    const H::Shader* shader = nullptr;
    id<MTLComputePipelineState> pipeline = impl->kernels.Tiling(dispatch, shader);
    const u32 tiled_slot = HostKernels::BufferSlot(*shader, 0);
    const u32 linear_slot = HostKernels::BufferSlot(*shader, 1);
    const u32 params_slot = HostKernels::BufferSlot(*shader, 2);
    scheduler.ComputeEncoder(__func__);
    id<MTLComputeCommandEncoder> compute = impl->sched.compute;
    [compute setComputePipelineState:pipeline];
    [compute setBuffer:NativeBuffer(*dispatch.tiled.buffer)
                offset:dispatch.tiled.offset
               atIndex:tiled_slot];
    [compute setBuffer:NativeBuffer(*dispatch.linear.buffer)
                offset:dispatch.linear.offset
               atIndex:linear_slot];
    [compute setBuffer:NativeBuffer(*dispatch.params.buffer)
                offset:dispatch.params.offset
               atIndex:params_slot];
    [compute dispatchThreadgroups:MTLSizeMake(dispatch.group_count_x, 1, 1)
            threadsPerThreadgroup:MTLSizeMake(shader->local_size[0], 1, 1)];
}

void Runtime::CreateFaultParser(u32 page_bits, u32 max_faults) {
    impl->kernels.CreateFaultParser(page_bits, max_faults);
}

void Runtime::ParseFaultBuffer(const VideoCore::FaultParseDispatch& dispatch) {
    id<MTLComputePipelineState> pipeline = impl->kernels.FaultParser();
    ASSERT_MSG(pipeline, "ParseFaultBuffer before CreateFaultParser");
    if (dispatch.group_count_x == 0) {
        return;
    }
    const auto& shader = H::FAULT_BUFFER_PROCESS_COMP;
    scheduler.ComputeEncoder(__func__);
    // The game's shaders wrote the fault buffer through its device address, which Metal does not
    // track: order the parser after them (the barrier also waits for the earlier encoders).
    scheduler.MemoryBarrier();
    id<MTLComputeCommandEncoder> compute = impl->sched.compute;
    [compute setComputePipelineState:pipeline];
    [compute setBuffer:NativeBuffer(*dispatch.fault_buffer)
                offset:0
               atIndex:HostKernels::BufferSlot(shader, 0)];
    [compute setBuffer:NativeBuffer(*dispatch.download.buffer)
                offset:dispatch.download.offset
               atIndex:HostKernels::BufferSlot(shader, 1)];
    [compute dispatchThreadgroups:MTLSizeMake(dispatch.group_count_x, 1, 1)
            threadsPerThreadgroup:MTLSizeMake(shader.local_size[0], 1, 1)];
    // And everything after the parser (its zeroed bitmap, the list): the next encoder waits for
    // this one.
    scheduler.EndEncoder();
    scheduler.MemoryBarrier();
}

} // namespace Metal
