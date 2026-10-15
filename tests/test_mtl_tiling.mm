// SPDX-License-Identifier: GPL-2.0-or-later
// Unit test of the GCN tiling and detiling kernel (host_shaders/tiling.comp, its MSL by SPIRV-Cross;
// docs/METAL_BACKEND_PLAN.md P8.4): runs the shipped kernel and the reference (the kernel as it was
// before P8.4, tests/tiling_reference.comp, one thread per element) on random data and requires
// bit-identical buffers, as tiler and as detiler, for the game's tile modes (macro tiled 2D thin
// 14, depth 0, micro tiled 13 and 9), mip chains, thick and 3D modes, every bits per pixel, block
// formats, bank swizzles. The dispatch (constants and group count) is the one of
// TileManager::MakeDispatch; the reference gets the same constants and one thread per element.
// The tiled buffer is compared whole, with a guard area behind the image, so a write the new
// kernel makes that the reference does not make fails the test. Prints the GPU time of both
// (MTLCommandBuffer GPUStartTime/GPUEndTime, median). Needs a Metal device only.
//
//   mtl-tiling-test [name part of the cases to run]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <span>
#include <string>
#include <thread>
#include <vector>

#include "video_core/renderer_metal/msl_host_shader.h"
#include "video_core/texture_cache/image_info.h"
#include "video_core/texture_cache/tile_manager.h"

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
#include "video_core/host_shaders_msl/tiling_ref_macro_128_comp_msl.h"
#include "video_core/host_shaders_msl/tiling_ref_macro_16_comp_msl.h"
#include "video_core/host_shaders_msl/tiling_ref_macro_32_comp_msl.h"
#include "video_core/host_shaders_msl/tiling_ref_macro_64_comp_msl.h"
#include "video_core/host_shaders_msl/tiling_ref_macro_8_comp_msl.h"
#include "video_core/host_shaders_msl/tiling_ref_macro_96_comp_msl.h"
#include "video_core/host_shaders_msl/tiling_ref_micro_128_comp_msl.h"
#include "video_core/host_shaders_msl/tiling_ref_micro_16_comp_msl.h"
#include "video_core/host_shaders_msl/tiling_ref_micro_32_comp_msl.h"
#include "video_core/host_shaders_msl/tiling_ref_micro_64_comp_msl.h"
#include "video_core/host_shaders_msl/tiling_ref_micro_8_comp_msl.h"
#include "video_core/host_shaders_msl/tiling_ref_micro_96_comp_msl.h"

namespace H = Metal::HostShaders;
using AmdGpu::TileMode;

namespace {

const H::Shader& GetShader(bool reference, u32 bits, bool macro) {
#define PICK(BITS)                                                                                 \
    case BITS:                                                                                     \
        return reference ? (macro ? H::TILING_REF_MACRO_##BITS##_COMP                              \
                                  : H::TILING_REF_MICRO_##BITS##_COMP)                             \
                         : (macro ? H::TILING_MACRO_##BITS##_COMP : H::TILING_MICRO_##BITS##_COMP)
    switch (bits) {
        PICK(8);
        PICK(16);
        PICK(32);
        PICK(64);
        PICK(96);
        PICK(128);
    }
#undef PICK
    std::abort();
}

u32 BufferSlot(const H::Shader& shader, u32 binding) {
    for (const H::Binding& b : shader.bindings) {
        if (b.kind == H::Binding::Kind::Buffer && b.set == 0 && b.binding == binding) {
            return b.msl_index;
        }
    }
    std::abort();
}

/// The TilingInfo of the texture cache (tile_manager.cpp), uniform buffer of the kernel.
struct TilingInfoBlock {
    u32 bank_swizzle;
    u32 micro_tiled_mips;
    u32 num_mips;
    std::array<VideoCore::ImageInfo::MipInfo, 16> mips;
};

/// A level of a hand made layout: texels (size / bytes per texel), pitch and height.
struct CustomMip {
    u32 texels, pitch, height;
};

struct Case {
    const char* name;
    TileMode tile_mode;
    u32 bits;
    u32 width, height;
    u32 depth;           ///< depth slices of a volume
    u32 layers;
    u32 levels;
    bool render_target;  ///< one level the way ImageInfo(ColorBuffer) lays it out (unpadded height)
    u32 samples;
    bool block;          ///< block compressed (the kernel works on blocks)
    bool pow2;
    u32 bank_swizzle;
    bool timed;
    /// Hand made mips (layouts ImageInfo does not produce, to cover the kernel's fallback for
    /// mips that are not whole slices of whole micro tiles); levels is then their count.
    std::array<CustomMip, 4> custom{};
};

constexpr Case kCases[] = {
    // name                  mode                   bpp  w     h     d  l  lv rt     smp blk  pow2 swz timed
    {"rt 64bpp m14 1280x720", TileMode::Thin2DThin, 64, 1280, 720, 1, 1, 1, true, 1, false, false, 0, true},
    {"64bpp m14 1280x720 pad", TileMode::Thin2DThin, 64, 1280, 720, 1, 1, 1, false, 1, false, false, 0, false},
    {"rt 32bpp m14 1280x720", TileMode::Thin2DThin, 32, 1280, 720, 1, 1, 1, true, 1, false, false, 0, true},
    {"32bpp m14 1280x720 pad", TileMode::Thin2DThin, 32, 1280, 720, 1, 1, 1, false, 1, false, false, 0, false},
    {"rt 32bpp m0 1280x720", TileMode::Depth2DThin64, 32, 1280, 720, 1, 1, 1, true, 1, false, false, 0, true},
    {"32bpp m0 1280x720 pad", TileMode::Depth2DThin64, 32, 1280, 720, 1, 1, 1, false, 1, false, false, 0, false},
    {"rt 32bpp m14 640x360", TileMode::Thin2DThin, 32, 640, 360, 1, 1, 1, true, 1, false, false, 0, false},
    {"rt 32bpp m14 1920x1080", TileMode::Thin2DThin, 32, 1920, 1080, 1, 1, 1, true, 1, false, false, 0, false},
    {"rt 64bpp m14 1920x1080", TileMode::Thin2DThin, 64, 1920, 1080, 1, 1, 1, true, 1, false, false, 0, false},
    {"32bpp m14 256x256 mips", TileMode::Thin2DThin, 32, 256, 256, 1, 1, 9, false, 1, false, false, 0, false},
    {"32bpp m14 256x256 mips swz", TileMode::Thin2DThin, 32, 256, 256, 1, 1, 9, false, 1, false, false, 5, false},
    {"64bpp m14 512x512 mips", TileMode::Thin2DThin, 64, 512, 512, 1, 1, 10, false, 1, false, false, 0, false},
    {"32bpp m14 100x60 mips", TileMode::Thin2DThin, 32, 100, 60, 1, 1, 7, false, 1, false, false, 0, false},
    {"32bpp m14 300x200 pow2 mips", TileMode::Thin2DThin, 32, 300, 200, 1, 1, 9, false, 1, false, true, 0, false},
    {"32bpp m14 128x128 x6 layers", TileMode::Thin2DThin, 32, 128, 128, 1, 6, 8, false, 1, false, false, 0, false},
    {"32bpp m0 256x256 mips", TileMode::Depth2DThin64, 32, 256, 256, 1, 1, 9, false, 1, false, false, 0, false},
    {"32bpp m1 256x256 mips", TileMode::Depth2DThin128, 32, 256, 256, 1, 1, 9, false, 1, false, false, 0, false},
    {"32bpp m2 256x256 mips", TileMode::Depth2DThin256, 32, 256, 256, 1, 1, 9, false, 1, false, false, 0, false},
    {"32bpp m4 256x256 mips", TileMode::Depth2DThin1K, 32, 256, 256, 1, 1, 9, false, 1, false, false, 0, false},
    {"32bpp m5 256x256 mips", TileMode::Depth1DThin, 32, 256, 256, 1, 1, 9, false, 1, false, false, 0, false},
    {"32bpp m6 256x256 mips", TileMode::Depth2DThinPrt256, 32, 256, 256, 1, 1, 9, false, 1, false, false, 0, false},
    {"32bpp m10 256x256 mips", TileMode::Display2DThin, 32, 256, 256, 1, 1, 9, false, 1, false, false, 0, false},
    {"32bpp m11 256x256 mips", TileMode::DisplayThinPrt, 32, 256, 256, 1, 1, 9, false, 1, false, false, 0, false},
    {"32bpp m12 256x256 mips", TileMode::Display2DThinPrt, 32, 256, 256, 1, 1, 9, false, 1, false, false, 0, false},
    {"32bpp m13 512x512 mips", TileMode::Thin1DThin, 32, 512, 512, 1, 1, 10, false, 1, false, false, 0, true},
    {"rt 32bpp m13 1280x720", TileMode::Thin1DThin, 32, 1280, 720, 1, 1, 1, true, 1, false, false, 0, false},
    {"32bpp m9 512x512 mips", TileMode::Display1DThin, 32, 512, 512, 1, 1, 10, false, 1, false, false, 0, false},
    {"rt 32bpp m9 1280x720", TileMode::Display1DThin, 32, 1280, 720, 1, 1, 1, true, 1, false, false, 0, true},
    {"rt 64bpp m9 1280x720", TileMode::Display1DThin, 64, 1280, 720, 1, 1, 1, true, 1, false, false, 0, false},
    {"32bpp m15 64x64x8 vol", TileMode::Thin3DThin, 32, 64, 64, 8, 1, 4, false, 1, false, false, 0, false},
    {"32bpp m16 128x128 mips", TileMode::ThinThinPrt, 32, 128, 128, 1, 1, 8, false, 1, false, false, 0, false},
    {"32bpp m17 128x128 mips", TileMode::Thin2DThinPrt, 32, 128, 128, 1, 1, 8, false, 1, false, false, 0, false},
    {"32bpp m18 64x64x8 vol", TileMode::Thin3DThinPrt, 32, 64, 64, 8, 1, 4, false, 1, false, false, 0, false},
    {"32bpp m19 64x64x8 vol", TileMode::Thick1DThick, 32, 64, 64, 8, 1, 4, false, 1, false, false, 0, false},
    {"32bpp m20 128x128x8 vol", TileMode::Thick2DThick, 32, 128, 128, 8, 1, 6, false, 1, false, false, 0, false},
    {"64bpp m20 64x64x4 vol", TileMode::Thick2DThick, 64, 64, 64, 4, 1, 5, false, 1, false, false, 0, false},
    {"32bpp m21 64x64x8 vol", TileMode::Thick3DThick, 32, 64, 64, 8, 1, 4, false, 1, false, false, 0, false},
    {"32bpp m22 128x128x8 vol", TileMode::ThickThickPrt, 32, 128, 128, 8, 1, 6, false, 1, false, false, 0, false},
    {"32bpp m23 128x128x8 vol", TileMode::Thick2DThickPrt, 32, 128, 128, 8, 1, 6, false, 1, false, false, 0, false},
    {"32bpp m25 128x128x8 vol", TileMode::Thick2DXThick, 32, 128, 128, 8, 1, 6, false, 1, false, false, 0, false},
    {"32bpp m26 64x64x8 vol", TileMode::Thick3DXThick, 32, 64, 64, 8, 1, 4, false, 1, false, false, 0, false},
    {"8bpp m14 256x256 mips", TileMode::Thin2DThin, 8, 256, 256, 1, 1, 9, false, 1, false, false, 0, false},
    {"8bpp m13 256x256 mips", TileMode::Thin1DThin, 8, 256, 256, 1, 1, 9, false, 1, false, false, 0, false},
    {"16bpp m14 256x256 mips", TileMode::Thin2DThin, 16, 256, 256, 1, 1, 9, false, 1, false, false, 0, false},
    {"16bpp m13 256x256 mips", TileMode::Thin1DThin, 16, 256, 256, 1, 1, 9, false, 1, false, false, 0, false},
    {"16bpp m0 256x256 mips", TileMode::Depth2DThin64, 16, 256, 256, 1, 1, 9, false, 1, false, false, 0, false},
    {"96bpp m13 256x256 mips", TileMode::Thin1DThin, 96, 256, 256, 1, 1, 9, false, 1, false, false, 0, false},
    {"128bpp m14 256x256 mips", TileMode::Thin2DThin, 128, 256, 256, 1, 1, 9, false, 1, false, false, 0, false},
    {"128bpp m13 256x256 mips", TileMode::Thin1DThin, 128, 256, 256, 1, 1, 9, false, 1, false, false, 0, false},
    {"128bpp m10 256x256 mips", TileMode::Display2DThin, 128, 256, 256, 1, 1, 9, false, 1, false, false, 0, false},
    {"64bpp m14 BC 512x512 mips", TileMode::Thin2DThin, 64, 512, 512, 1, 1, 10, false, 1, true, false, 0, false},
    {"128bpp m14 BC 300x200 mips", TileMode::Thin2DThin, 128, 300, 200, 1, 1, 9, false, 1, true, false, 0, false},
    {"64bpp m13 BC 256x256 mips", TileMode::Thin1DThin, 64, 256, 256, 1, 1, 9, false, 1, true, false, 0, false},
    {"32bpp m0 2 samples 256x256", TileMode::Depth2DThin64, 32, 256, 256, 1, 1, 1, false, 2, false, false, 0, false},
};

constexpr Case kCustomCases[] = {
    // Render targets of the game: a surface padded to 768 rows with the height of 720 (the depth
    // buffer's), or the buffer's height padded as well.
    {"padded 64bpp m14 1280x768", TileMode::Thin2DThin, 64, 1280, 768, 1, 1, 1, false, 1, false, false, 0, true,
     {{{1280 * 768, 1280, 768}}}},
    {"padded 32bpp m14 1280x768", TileMode::Thin2DThin, 32, 1280, 768, 1, 1, 1, false, 1, false, false, 0, false,
     {{{1280 * 768, 1280, 768}}}},
    {"padded 32bpp m0 1280x768", TileMode::Depth2DThin64, 32, 1280, 768, 1, 1, 1, false, 1, false, false, 0, false,
     {{{1280 * 768, 1280, 768}}}},
    {"depth 64bpp m14 1280x720/768", TileMode::Thin2DThin, 64, 1280, 720, 1, 1, 1, false, 1, false, false, 0, false,
     {{{1280 * 768, 1280, 720}}}},
    {"depth 32bpp m14 1280x720/768", TileMode::Thin2DThin, 32, 1280, 720, 1, 1, 1, false, 1, false, false, 0, false,
     {{{1280 * 768, 1280, 720}}}},
    {"depth 32bpp m0 1280x720/768", TileMode::Depth2DThin64, 32, 1280, 720, 1, 1, 1, false, 1, false, false, 0, false,
     {{{1280 * 768, 1280, 720}}}},

    // Pitch or height not a multiple of 8, partial last slice, zero sized level; macro and micro
    // modes. (The tiler may collide on addresses there; a reference that does is not compared.)
    {"custom 64bpp m14 64x12", TileMode::Thin2DThin, 64, 64, 12, 1, 1, 1, false, 1, false, false, 0, false,
     {{{64 * 12, 64, 12}}}},
    {"custom 32bpp m14 64x48 1.5 slices", TileMode::Thin2DThin, 32, 64, 32, 1, 1, 1, false, 1, false, false, 0, false,
     {{{64 * 48, 64, 32}}}},
    {"custom 32bpp m13 64x32 1.5 slices", TileMode::Thin1DThin, 32, 64, 32, 1, 1, 1, false, 1, false, false, 0, false,
     {{{64 * 48, 64, 32}}}},
    {"custom 32bpp m14 12x16", TileMode::Thin2DThin, 32, 12, 16, 1, 1, 1, false, 1, false, false, 0, false,
     {{{12 * 16, 12, 16}}}},
    {"custom 64bpp m13 100x64", TileMode::Thin1DThin, 64, 100, 64, 1, 1, 1, false, 1, false, false, 0, false,
     {{{100 * 64, 100, 64}}}},
    {"custom 32bpp m13 irregular chain", TileMode::Thin1DThin, 32, 64, 64, 1, 1, 4, false, 1, false, false, 0, false,
     {{{64 * 64, 64, 64}, {32 * 24, 32, 24}, {0, 16, 16}, {16 * 16, 16, 16}}}},
    {"custom 32bpp m14 irregular chain", TileMode::Thin2DThin, 32, 64, 64, 1, 1, 4, false, 1, false, false, 3, false,
     {{{64 * 64, 64, 64}, {40 * 40, 40, 40}, {0, 16, 16}, {16 * 16, 16, 16}}}},
    {"custom 128bpp m14 chain", TileMode::Thin2DThin, 128, 64, 64, 1, 1, 3, false, 1, false, false, 0, false,
     {{{64 * 64, 64, 64}, {32 * 32, 32, 32}, {8 * 16, 8, 16}}}},
};

VideoCore::ImageInfo MakeInfo(const Case& c) {
    VideoCore::ImageInfo info{};
    info.props.is_tiled = true;
    info.props.is_block = c.block;
    info.props.is_pow2 = c.pow2;
    info.tile_mode = c.tile_mode;
    info.array_mode = AmdGpu::GetArrayMode(c.tile_mode);
    info.num_bits = c.bits;
    info.num_samples = c.samples;
    info.pitch = c.width;
    info.size = {c.width, c.height, c.depth};
    info.resources = {c.levels, c.layers};
    info.bank_swizzle = static_cast<u8>(c.bank_swizzle);
    if (c.custom[0].texels != 0 || c.custom[0].pitch != 0) {
        u32 offset = 0;
        for (u32 mip = 0; mip < c.levels; ++mip) {
            const u32 size = c.custom[mip].texels * (c.bits / 8);
            info.mips_layout[mip] = {size, c.custom[mip].pitch, c.custom[mip].height, offset};
            offset += size;
        }
        info.guest_size = offset;
    } else if (c.render_target) {
        // ImageInfo(ColorBuffer): the slice is the 8x8 tiles of the surface, the height the buffer's
        info.guest_size = c.width * c.height * (c.bits / 8);
        info.mips_layout[0] = {info.guest_size, c.width, c.height, 0};
    } else {
        info.UpdateSize();
    }
    return info;
}

struct Rng {
    u64 state;
    u32 Next() {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        return static_cast<u32>(state >> 16);
    }
};

struct Kernel {
    id<MTLComputePipelineState> pipeline;
    const H::Shader* shader;
};

/// The function of a host shader with the constants of the dispatch (renderer_metal's
/// HostKernels::Function) and its compute pipeline.
Kernel MakeKernel(id<MTLDevice> device, const H::Shader& shader, const std::array<u32, 12>& constants,
                  u32 count) {
    MTLCompileOptions* options = [MTLCompileOptions new];
    options.languageVersion = MTLLanguageVersion3_1;
    if (@available(macOS 15.0, *)) {
        options.mathMode = MTLMathModeSafe;
    } else {
        options.fastMathEnabled = NO;
    }
    NSError* error = nil;
    id<MTLLibrary> library = [device
        newLibraryWithSource:[[NSString alloc] initWithBytes:shader.msl.data()
                                                      length:shader.msl.size()
                                                    encoding:NSUTF8StringEncoding]
                     options:options
                       error:&error];
    if (!library) {
        std::fprintf(stderr, "library: %s\n", error.localizedDescription.UTF8String);
        std::exit(1);
    }
    MTLFunctionConstantValues* values = [MTLFunctionConstantValues new];
    for (const H::SpecConstant& constant : shader.spec_constants) {
        if (constant.id >= count) {
            continue;
        }
        u32 value = constants[constant.id];
        [values setConstantValue:&value type:MTLDataTypeUInt atIndex:constant.id];
    }
    id<MTLFunction> function =
        [library newFunctionWithName:@"main0" constantValues:values error:&error];
    if (!function) {
        std::fprintf(stderr, "function: %s\n", error.localizedDescription.UTF8String);
        std::exit(1);
    }
    id<MTLComputePipelineState> pipeline =
        [device newComputePipelineStateWithFunction:function error:&error];
    if (!pipeline) {
        std::fprintf(stderr, "pipeline: %s\n", error.localizedDescription.UTF8String);
        std::exit(1);
    }
    return {pipeline, &shader};
}

/// A plain copy of as many bytes as the image has, one element per thread: the least any kernel
/// that reads one buffer and writes the other has to spend on this GPU.
Kernel MakeCopyKernel(id<MTLDevice> device, u32 bits) {
    static const char* source = R"(
#include <metal_stdlib>
using namespace metal;
kernel void copy_u32(device const uint* a [[buffer(0)]], device uint* b [[buffer(1)]],
                     uint i [[thread_position_in_grid]]) { b[i] = a[i]; }
kernel void copy_u64(device const uint2* a [[buffer(0)]], device uint2* b [[buffer(1)]],
                     uint i [[thread_position_in_grid]]) { b[i] = a[i]; }
)";
    NSError* error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:[NSString stringWithUTF8String:source]
                                                  options:nil
                                                    error:&error];
    id<MTLFunction> function =
        [library newFunctionWithName:bits == 64 ? @"copy_u64" : @"copy_u32"];
    return {[device newComputePipelineStateWithFunction:function error:&error], nullptr};
}

struct Buffers {
    id<MTLBuffer> tiled;
    id<MTLBuffer> linear;
    id<MTLBuffer> params;
    size_t tiled_size, linear_size;
};

/// Runs the kernel `repeat` times in one command buffer (the dispatches run one after the other);
/// returns the GPU time of the command buffer per dispatch in milliseconds.
double Run(id<MTLCommandQueue> queue, const Kernel& kernel, const Buffers& b, u32 groups,
           u32 repeat = 1) {
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:kernel.pipeline];
    [enc setBuffer:b.tiled offset:0 atIndex:BufferSlot(*kernel.shader, 0)];
    [enc setBuffer:b.linear offset:0 atIndex:BufferSlot(*kernel.shader, 1)];
    [enc setBuffer:b.params offset:0 atIndex:BufferSlot(*kernel.shader, 2)];
    for (u32 i = 0; i < repeat; ++i) {
        [enc dispatchThreadgroups:MTLSizeMake(groups, 1, 1)
            threadsPerThreadgroup:MTLSizeMake(kernel.shader->local_size[0], 1, 1)];
    }
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.error) {
        std::fprintf(stderr, "command buffer: %s\n", cb.error.localizedDescription.UTF8String);
        std::exit(1);
    }
    return (cb.GPUEndTime - cb.GPUStartTime) * 1000.0 / repeat;
}

/// Times the copy kernel over `bytes` bytes of the buffers (`repeat` dispatches).
double RunCopy(id<MTLCommandQueue> queue, const Kernel& kernel, const Buffers& b, u32 bits,
               size_t bytes, u32 repeat = 1) {
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:kernel.pipeline];
    [enc setBuffer:b.tiled offset:0 atIndex:0];
    [enc setBuffer:b.linear offset:0 atIndex:1];
    for (u32 i = 0; i < repeat; ++i) {
        [enc dispatchThreads:MTLSizeMake(bytes / (bits == 64 ? 8 : 4), 1, 1)
            threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    }
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    return (cb.GPUEndTime - cb.GPUStartTime) * 1000.0 / repeat;
}

double Median(std::vector<double> v) {
    std::sort(v.begin(), v.end());
    return v[v.size() / 2];
}

int g_failures = 0;

void RunCase(id<MTLDevice> device, id<MTLCommandQueue> queue, const Case& c, u32 index) {
    const VideoCore::ImageInfo info = MakeInfo(c);
    const u32 num_mips = info.resources.levels;
    TilingInfoBlock params{};
    params.bank_swizzle = info.bank_swizzle;
    params.micro_tiled_mips = info.micro_tiled_mips;
    params.num_mips = num_mips;
    for (u32 mip = 0; mip < num_mips; ++mip) {
        auto& mip_info = params.mips[mip];
        mip_info = info.mips_layout[mip];
        if (info.props.is_block) {
            mip_info.pitch = std::max((mip_info.pitch + 3) / 4, 1U);
            mip_info.height = std::max((mip_info.height + 3) / 4, 1U);
        }
    }

    const size_t image_bytes = info.guest_size;
    // Room for the guest size plus the macro tile rows the unpadded height reaches, then a guard.
    const size_t tiled_size = image_bytes * 2 + (1u << 16);
    const size_t linear_size = image_bytes + (1u << 16);
    Buffers b;
    b.tiled_size = tiled_size;
    b.linear_size = linear_size;
    b.tiled = [device newBufferWithLength:tiled_size options:MTLResourceStorageModeShared];
    b.linear = [device newBufferWithLength:linear_size options:MTLResourceStorageModeShared];
    b.params = [device newBufferWithBytes:&params
                                   length:sizeof(params)
                                  options:MTLResourceStorageModeShared];
    Buffers r;
    r.tiled_size = tiled_size;
    r.linear_size = linear_size;
    r.tiled = [device newBufferWithLength:tiled_size options:MTLResourceStorageModeShared];
    r.linear = [device newBufferWithLength:linear_size options:MTLResourceStorageModeShared];
    r.params = b.params;

    std::vector<u32> tiled_init(tiled_size / 4), linear_init(linear_size / 4);
    Rng rng{0x9E3779B97F4A7C15ull * (index + 1)};
    for (u32& v : tiled_init) {
        v = rng.Next();
    }
    for (u32& v : linear_init) {
        v = rng.Next();
    }

    double timing[2][2]{}; // [tiler][reference], warm
    double cold[2][2]{};   // the same, one dispatch after an idle GPU
    double floor_warm = 0, floor_cold = 0; // a plain copy of the image
    bool ok = true;
    std::string note;
    for (const bool is_tiler : {false, true}) {
        const auto dispatch = VideoCore::TileManager::MakeDispatch(info, is_tiler, {}, {}, {});
        const bool macro = dispatch.is_macro;
        const Kernel fresh =
            MakeKernel(device, GetShader(false, c.bits, macro), dispatch.constants,
                       dispatch.num_constants);
        const Kernel ref = MakeKernel(device, GetShader(true, c.bits, macro), dispatch.constants,
                                      dispatch.num_constants);
        const u32 ref_groups = static_cast<u32>((info.guest_size / (info.num_bits / 8)) / 64);
        const u32 new_groups = dispatch.group_count_x;

        auto reset = [&](const Buffers& buffers) {
            std::memcpy(buffers.tiled.contents, tiled_init.data(), tiled_size);
            std::memcpy(buffers.linear.contents, linear_init.data(), linear_size);
        };
        reset(r);
        Run(queue, ref, r, ref_groups);
        // The reference must be deterministic itself (colliding addresses would race).
        std::vector<u8> ref_tiled(static_cast<const u8*>(r.tiled.contents),
                                  static_cast<const u8*>(r.tiled.contents) + tiled_size);
        std::vector<u8> ref_linear(static_cast<const u8*>(r.linear.contents),
                                   static_cast<const u8*>(r.linear.contents) + linear_size);
        reset(r);
        Run(queue, ref, r, ref_groups);
        const bool deterministic =
            std::memcmp(ref_tiled.data(), r.tiled.contents, tiled_size) == 0 &&
            std::memcmp(ref_linear.data(), r.linear.contents, linear_size) == 0;

        reset(b);
        Run(queue, fresh, b, new_groups);
        const u8* got_tiled = static_cast<const u8*>(b.tiled.contents);
        const u8* got_linear = static_cast<const u8*>(b.linear.contents);
        size_t diff_tiled = 0, diff_linear = 0, first_tiled = ~size_t(0), first_linear = ~size_t(0);
        for (size_t i = 0; i < tiled_size; ++i) {
            if (got_tiled[i] != ref_tiled[i]) {
                if (!diff_tiled) {
                    first_tiled = i;
                }
                ++diff_tiled;
            }
        }
        for (size_t i = 0; i < linear_size; ++i) {
            if (got_linear[i] != ref_linear[i]) {
                if (!diff_linear) {
                    first_linear = i;
                }
                ++diff_linear;
            }
        }
        if (!deterministic) {
            note += is_tiler ? " [tiler: reference not deterministic, not compared]"
                             : " [detiler: reference not deterministic, not compared]";
        } else if (diff_tiled || diff_linear) {
            ok = false;
            char text[200];
            std::snprintf(text, sizeof(text),
                          " [%s: %zu tiled bytes differ (first %zu), %zu linear bytes (first %zu)]",
                          is_tiler ? "tiler" : "detiler", diff_tiled,
                          diff_tiled ? first_tiled : 0, diff_linear, diff_linear ? first_linear : 0);
            note += text;
        }

        // GPU time: runs alternate between the two kernels, ten dispatches per command buffer,
        // median of the command buffers.
        const u32 runs = c.timed ? 21 : 5;
        std::vector<double> t_ref, t_new;
        for (u32 i = 0; i < runs + 2; ++i) {
            const double tr = Run(queue, ref, r, ref_groups, 10);
            const double tn = Run(queue, fresh, b, new_groups, 10);
            if (i >= 2) {
                t_ref.push_back(tr);
                t_new.push_back(tn);
            }
        }
        timing[is_tiler][0] = Median(t_ref);
        timing[is_tiler][1] = Median(t_new);
        if (c.timed) {
            // The game runs the kernel on a GPU that has little else to do and is clocked down:
            // single dispatches after 30 ms of idle time.
            t_ref.clear();
            t_new.clear();
            for (u32 i = 0; i < 21; ++i) {
                std::this_thread::sleep_for(std::chrono::milliseconds(30));
                t_ref.push_back(Run(queue, ref, r, ref_groups));
                std::this_thread::sleep_for(std::chrono::milliseconds(30));
                t_new.push_back(Run(queue, fresh, b, new_groups));
            }
            cold[is_tiler][0] = Median(t_ref);
            cold[is_tiler][1] = Median(t_new);
            if (is_tiler) {
                const Kernel copy = MakeCopyKernel(device, c.bits);
                std::vector<double> warm_floor, cold_floor;
                for (u32 i = 0; i < 15; ++i) {
                    warm_floor.push_back(RunCopy(queue, copy, b, c.bits, image_bytes, 10));
                    std::this_thread::sleep_for(std::chrono::milliseconds(30));
                    cold_floor.push_back(RunCopy(queue, copy, b, c.bits, image_bytes));
                }
                floor_warm = Median(warm_floor);
                floor_cold = Median(cold_floor);
            }
        }
    }
    std::printf("%-4s %-30s tile %6.3f -> %6.3f ms (x%.2f)  detile %6.3f -> %6.3f ms (x%.2f)%s\n",
                ok ? "ok" : "FAIL", c.name, timing[1][0], timing[1][1], timing[1][0] / timing[1][1],
                timing[0][0], timing[0][1], timing[0][0] / timing[0][1], note.c_str());
    if (c.timed) {
        std::printf("     %-30s cold: tile %6.3f -> %6.3f ms (x%.2f)  detile %6.3f -> %6.3f ms (x%.2f)"
                    "   plain copy of the image: warm %.3f ms, cold %.3f ms\n",
                    "", cold[1][0], cold[1][1], cold[1][0] / cold[1][1], cold[0][0], cold[0][1],
                    cold[0][0] / cold[0][1], floor_warm, floor_cold);
    }
    if (!ok) {
        ++g_failures;
    }
}

} // namespace

int main(int argc, char** argv) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            std::fprintf(stderr, "no Metal device\n");
            return 1;
        }
        id<MTLCommandQueue> queue = [device newCommandQueue];
        std::printf("GPU: %s; times are reference -> new (median GPU time)\n",
                    device.name.UTF8String);
        u32 index = 0;
        // an argument selects the cases whose name contains it
        u32 run = 0;
        for (const auto& list : {std::span<const Case>(kCases), std::span<const Case>(kCustomCases)}) {
            for (const Case& c : list) {
                @autoreleasepool {
                    if (argc < 2 || std::strstr(c.name, argv[1])) {
                        RunCase(device, queue, c, index);
                        ++run;
                    }
                    ++index;
                }
            }
        }
        if (run == 0) {
            std::printf("no case matches\n");
            return 1;
        }
        std::printf("%u cases, %d failed\n", run, g_failures);
        return g_failures ? 1 : 0;
    }
}
