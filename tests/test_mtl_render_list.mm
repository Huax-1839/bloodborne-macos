// SPDX-License-Identifier: GPL-2.0-or-later
// Unit test of renderer_metal/mtl_render_list: the same command sequence, with redundant calls
// the filter drops and calls it must keep (a buffer slot overwritten by bytes, an offset-only
// change), is issued once directly and once recorded then replayed; both must draw the same
// pixels. Needs a Metal device, no window or game.
//
//   mtl-render-list-test
//
// Exit 0 when every check passed.
#import <Metal/Metal.h>

#include <array>
#include <cstdio>
#include <cstring>

#include "video_core/renderer_metal/mtl_render_list.h"

using Metal::RenderList;

static int failures = 0;
#define CHECK(cond)                                                                                \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            std::printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                          \
            ++failures;                                                                            \
        }                                                                                          \
    } while (0)

static NSString* const shader_source = @"#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "vertex float4 vs(uint id [[vertex_id]]) {\n"
    "    float2 p = float2((id << 1) & 2, id & 2);\n"
    "    return float4(p * 2.0 - 1.0, 0.0, 1.0);\n"
    "}\n"
    "fragment float4 fs(constant float4* color [[buffer(0)]]) { return color[0]; }\n";

constexpr uint32_t kWidth = 8;

static void* Raw(id object) {
    return (__bridge void*)object;
}

struct Fixture {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLRenderPipelineState> pipeline;
    id<MTLBuffer> green;  ///< one float4: green
    id<MTLBuffer> pair;   ///< two float4: blue, then white
    id<MTLTexture> target;
};

/// The commands of the scenario, one pixel column per draw.
static void Scenario(RenderList& list, const Fixture& f) {
    using Stage = RenderList::Stage;
    const RenderList::Viewport viewport{0, 0, double(kWidth), 1, 0, 1};
    const float red[4] = {1, 0, 0, 1};
    list.PushDebugGroup("scenario");
    list.SetRenderPipelineState(Raw(f.pipeline));
    list.SetCullMode(MTLCullModeNone);
    list.SetViewports(&viewport, 1);
    for (uint32_t i = 0; i < 6; ++i) {
        // Redundant after the first draw: pipeline, cull mode, viewport.
        list.SetRenderPipelineState(Raw(f.pipeline));
        list.SetCullMode(MTLCullModeNone);
        list.SetViewports(&viewport, 1);
        const RenderList::Scissor scissor{i, 0, 1, 1};
        list.SetScissorRects(&scissor, 1);
        switch (i) {
        case 0: // set
        case 1: // the same: dropped
            list.SetBuffer(Stage::Fragment, Raw(f.green), 0, 0);
            break;
        case 2: // bytes
            list.SetBytes(Stage::Fragment, red, sizeof(red), 0);
            break;
        case 3: // the same buffer again, after bytes took the slot: must not be dropped
            list.SetBuffer(Stage::Fragment, Raw(f.green), 0, 0);
            break;
        case 4: // a new buffer
            list.SetBuffer(Stage::Fragment, Raw(f.pair), 0, 0);
            break;
        case 5: // the same buffer at another offset: must not be dropped
            list.SetBuffer(Stage::Fragment, Raw(f.pair), 16, 0);
            break;
        }
        list.DrawPrimitives(MTLPrimitiveTypeTriangle, 0, 3, 1, 0);
    }
    list.InsertDebugSignpost("done");
    list.PopDebugGroup();
    list.MemoryBarrier();
}

static MTLRenderPassDescriptor* Pass(const Fixture& f) {
    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = f.target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    return pass;
}

static std::array<uint32_t, kWidth> Read(const Fixture& f) {
    std::array<uint32_t, kWidth> pixels{};
    [f.target getBytes:pixels.data()
           bytesPerRow:sizeof(pixels)
            fromRegion:MTLRegionMake2D(0, 0, kWidth, 1)
           mipmapLevel:0];
    return pixels;
}

static std::array<uint32_t, kWidth> Run(const Fixture& f, RenderList& list, bool recorded) {
    id<MTLCommandBuffer> cmd = [f.queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [cmd renderCommandEncoderWithDescriptor:Pass(f)];
    if (recorded) {
        list.BeginRecording();
        CHECK(list.Recording() && list.Empty() && !list.HasBarrier());
        Scenario(list, f);
        CHECK(!list.Empty() && list.HasBarrier());
        list.Replay(Raw(encoder));
        CHECK(list.Empty());
    } else {
        list.BeginDirect(Raw(encoder));
        CHECK(!list.Recording() && list.Empty());
        Scenario(list, f);
        CHECK(list.Empty() && list.HasBarrier());
    }
    list.End();
    [encoder endEncoding];
    [cmd commit];
    [cmd waitUntilCompleted];
    CHECK(cmd.status == MTLCommandBufferStatusCompleted);
    return Read(f);
}

int main() {
    @autoreleasepool {
        Fixture f;
        f.device = MTLCreateSystemDefaultDevice();
        if (!f.device) {
            std::printf("no Metal device\n");
            return 2;
        }
        f.queue = [f.device newCommandQueue];
        NSError* error = nil;
        id<MTLLibrary> library = [f.device newLibraryWithSource:shader_source
                                                        options:nil
                                                          error:&error];
        if (!library) {
            std::printf("shaders: %s\n", error.localizedDescription.UTF8String);
            return 2;
        }
        MTLRenderPipelineDescriptor* desc = [MTLRenderPipelineDescriptor new];
        desc.vertexFunction = [library newFunctionWithName:@"vs"];
        desc.fragmentFunction = [library newFunctionWithName:@"fs"];
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        f.pipeline = [f.device newRenderPipelineStateWithDescriptor:desc error:&error];
        if (!f.pipeline) {
            std::printf("pipeline: %s\n", error.localizedDescription.UTF8String);
            return 2;
        }
        const float green[4] = {0, 1, 0, 1};
        const float pair[8] = {0, 0, 1, 1, 1, 1, 1, 1};
        f.green = [f.device newBufferWithBytes:green length:sizeof(green) options:0];
        f.pair = [f.device newBufferWithBytes:pair length:sizeof(pair) options:0];
        MTLTextureDescriptor* td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                               width:kWidth
                                                              height:1
                                                           mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModeShared;
        f.target = [f.device newTextureWithDescriptor:td];

        // RGBA8 little endian: 0xAABBGGRR.
        constexpr uint32_t kGreen = 0xff00ff00, kRed = 0xff0000ff, kBlue = 0xffff0000,
                           kWhite = 0xffffffff;
        const std::array<uint32_t, kWidth> expected{kGreen, kGreen, kRed,  kGreen,
                                                    kBlue,  kWhite, 0,     0};
        RenderList list;
        const auto direct = Run(f, list, false);
        CHECK(direct == expected);
        const auto recorded = Run(f, list, true);
        CHECK(recorded == expected);
        // The list is reusable: the filter and the arena start empty again.
        const auto again = Run(f, list, true);
        CHECK(again == expected);
        if (failures) {
            for (uint32_t i = 0; i < kWidth; ++i) {
                std::printf("  pixel %u: direct %08x recorded %08x expected %08x\n", i, direct[i],
                            recorded[i], expected[i]);
            }
        }
    }
    std::printf(failures ? "FAILED: %d check(s)\n" : "all checks passed\n", failures);
    return failures ? 1 : 0;
}
