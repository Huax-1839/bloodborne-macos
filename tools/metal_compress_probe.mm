// SPDX-License-Identifier: GPL-2.0-or-later
//
// metal_compress_probe: standalone ground truth for plan P10.1 (lossless texture compression,
// docs/metal/texture_compression_design.md, "Steps" 1). Two modes:
//
//   bench (default)  Do MTLTextureUsageShaderWrite and/or MTLTextureUsagePixelFormatView cost the
//                    GPU's lossless compression, and how much GPU time is that? A large Private
//                    target (default 4096x4096; RGBA8Unorm, RGBA16Float, RGB10A2Unorm,
//                    Depth32Float_Stencil8, Depth32Float) is created with usage RT|Read (base),
//                    +ShaderWrite, +PixelFormatView and both, written by a full-screen render pass
//                    and read by a compute kernel. Content "tiles" (constant per 64x64 tile, and
//                    for depth "plane" = planar depth from the vertex z) is compressible, "noise"
//                    (per-pixel hash) is the control. Measured per (format, usage, content), each
//                    pass in its own command buffer, time = GPUEndTime - GPUStartTime:
//                      W   the write render pass (full-screen triangle)
//                      R   a compute read pass touching every texel once (read() reduced with
//                          simd_sum and one atomic per threadgroup into a 256-word buffer, so the
//                          read is not dominated by its own output writes, unlike a fragment pass
//                          that would have to write a render target of its own)
//                      WR  write pass then read pass in one command buffer (G-buffer -> lighting)
//                    Extra variants on textures that have ShaderWrite (colour formats only, MSL
//                    cannot write depth textures from a kernel):
//                      CW      content written by a compute kernel instead of a render pass
//                      CW_R    read after CW
//                      CW_OPT  blit optimizeContentsForGPUAccess: after CW (cost of the optimize)
//                      CW_OPT_R read after CW + optimize (does the optimize restore compression?)
//                      RP_OPT / RP_OPT_R  the same after the render-pass write
//
//   views            Which texture views need MTLTextureUsagePixelFormatView? Each case creates a
//                    64x64 base without PixelFormatView (and, as control, with), writes known
//                    content with a render pass, creates the view, reads through it with a compute
//                    kernel and compares with the expected values computed on the CPU. A case is
//                    ok when the view is non-nil, nothing aborts or is reported by the debug layer
//                    and the values match.
//
// Build (x86-64, the game's environment; -Wall -Wextra is clean):
//   clang++ -arch x86_64 -std=c++20 -fobjc-arc -O1 -Wall -Wextra -mmacosx-version-min=14.0 \
//     tools/metal_compress_probe.mm -framework Metal -framework Foundation \
//     -o <scratch>/metal_compress_probe_x86
// Native comparison: the same line with -arch arm64 (-o <scratch>/metal_compress_probe_arm64).
//
// Run:
//   <scratch>/metal_compress_probe_arm64 [bench] [--size N] [--reps N] [--warmup N]
//                                        [--load dontcare|clear] [--formats rgba8,rgba16f,rgb10a2,d32s8,d32]
//   arch -x86_64 <scratch>/metal_compress_probe_x86 bench --reps 5
//   <scratch>/metal_compress_probe_arm64 views list            (case names)
//   <scratch>/metal_compress_probe_arm64 views <case> [--pfv 0|1]   (one case, both variants by default)
//   MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=assert <scratch>/metal_compress_probe_arm64 views all
//   <scratch>/metal_compress_probe_arm64 views all             (without the validation layer)
// `views all` re-executes itself once per (case, variant) so an abort only kills that child.
// bench prints `DATA<TAB>format<TAB>usage<TAB>content<TAB>pass<TAB>median_ms<TAB>p10_ms<TAB>p90_ms<TAB>n`
// lines (parseable) and a summary table; every other line is `key: value`.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <mach-o/dyld.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <cmath>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <map>
#include <string>
#include <vector>

static id<MTLDevice> g_dev;
static id<MTLCommandQueue> g_queue;
static id<MTLLibrary> g_lib;

static void out(const char* key, const char* fmt, ...) __attribute__((format(printf, 2, 3)));
static void out(const char* key, const char* fmt, ...) {
    char buf[2048];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    printf("%s: %s\n", key, buf);
    fflush(stdout);
}

static std::string errstr(NSError* e) {
    return e ? std::string([[e localizedDescription] UTF8String] ?: "?") : std::string("none");
}

static double now_ms() {
    return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1e6;
}

static const char* kSource = R"MSL(
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; };
struct DOut { float depth [[depth(any)]]; };

vertex VOut vs(uint v [[vertex_id]]) {
    float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
    VOut o;
    o.pos = float4(p[v], 0.5, 1);
    return o;
}
// Planar depth through the vertex z (z = 0.5 + 0.1 x + 0.05 y in clip space).
vertex VOut vs_plane(uint v [[vertex_id]]) {
    float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
    VOut o;
    o.pos = float4(p[v], 0.5 + 0.1 * p[v].x + 0.05 * p[v].y, 1);
    return o;
}

static uint hash32(uint x) {
    x ^= x >> 16; x *= 0x7feb352dU; x ^= x >> 15; x *= 0x846ca68bU; x ^= x >> 16;
    return x;
}
static float4 hash4(uint2 p, uint seed) {
    uint h0 = hash32((p.x * 0x9E3779B1u) ^ hash32(p.y + seed));
    uint h1 = hash32(h0 ^ 0x1234567u);
    uint h2 = hash32(h1 ^ 0x89abcdefu);
    uint h3 = hash32(h2 ^ 0x2468ace0u);
    return float4(float(h0), float(h1), float(h2), float(h3)) * (1.0 / 4294967296.0);
}

fragment float4 fs_tiles(VOut in [[stage_in]]) { return hash4(uint2(in.pos.xy) >> 6, 1); }
fragment float4 fs_noise(VOut in [[stage_in]]) { return hash4(uint2(in.pos.xy), 7); }
fragment DOut fs_tiles_d(VOut in [[stage_in]]) {
    DOut o; o.depth = 0.1 + 0.8 * hash4(uint2(in.pos.xy) >> 6, 1).x; return o;
}
fragment DOut fs_noise_d(VOut in [[stage_in]]) {
    DOut o; o.depth = 0.1 + 0.8 * hash4(uint2(in.pos.xy), 7).x; return o;
}
fragment void fs_none() {}

kernel void cw_tiles(texture2d<float, access::write> t [[texture(0)]], uint2 g [[thread_position_in_grid]]) {
    if (g.x >= t.get_width() || g.y >= t.get_height()) return;
    t.write(hash4(g >> 6, 1), g);
}
kernel void cw_noise(texture2d<float, access::write> t [[texture(0)]], uint2 g [[thread_position_in_grid]]) {
    if (g.x >= t.get_width() || g.y >= t.get_height()) return;
    t.write(hash4(g, 7), g);
}

// Read pass: every texel once, reduced to one atomic add per threadgroup.
kernel void rd_color(texture2d<float, access::read> t [[texture(0)]], device atomic_uint* acc [[buffer(0)]],
                     uint2 g [[thread_position_in_grid]], uint2 tg [[threadgroup_position_in_grid]],
                     uint2 tgs [[threadgroups_per_grid]], uint sg [[simdgroup_index_in_threadgroup]],
                     uint sgn [[simdgroups_per_threadgroup]], uint lane [[thread_index_in_simdgroup]],
                     uint tid [[thread_index_in_threadgroup]]) {
    threadgroup uint part[32];
    uint v = 0;
    if (g.x < t.get_width() && g.y < t.get_height()) {
        float4 c = t.read(g);
        v = as_type<uint>(c.x) + as_type<uint>(c.y) + as_type<uint>(c.z) + as_type<uint>(c.w);
    }
    uint s = simd_sum(v);
    if (lane == 0) part[sg] = s;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid == 0) {
        uint total = 0;
        for (uint i = 0; i < sgn; ++i) total += part[i];
        atomic_fetch_add_explicit(&acc[(tg.y * tgs.x + tg.x) & 255], total, memory_order_relaxed);
    }
}
kernel void rd_depth(depth2d<float, access::read> t [[texture(0)]], device atomic_uint* acc [[buffer(0)]],
                     uint2 g [[thread_position_in_grid]], uint2 tg [[threadgroup_position_in_grid]],
                     uint2 tgs [[threadgroups_per_grid]], uint sg [[simdgroup_index_in_threadgroup]],
                     uint sgn [[simdgroups_per_threadgroup]], uint lane [[thread_index_in_simdgroup]],
                     uint tid [[thread_index_in_threadgroup]]) {
    threadgroup uint part[32];
    uint v = 0;
    if (g.x < t.get_width() && g.y < t.get_height()) v = as_type<uint>(t.read(g));
    uint s = simd_sum(v);
    if (lane == 0) part[sg] = s;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid == 0) {
        uint total = 0;
        for (uint i = 0; i < sgn; ++i) total += part[i];
        atomic_fetch_add_explicit(&acc[(tg.y * tgs.x + tg.x) & 255], total, memory_order_relaxed);
    }
}

// ---- views mode: pattern writers and readers --------------------------------------------------
fragment float4 fs_pat(VOut in [[stage_in]], constant uint& seed [[buffer(0)]]) {
    uint2 p = uint2(in.pos.xy);
    return float4(float((p.x * 4 + seed * 5) & 255), float((p.y * 4 + seed * 3) & 255),
                  float(((p.x ^ p.y) * 3 + seed) & 255), float((p.x * 2 + p.y * 2 + seed * 11) & 255)) / 255.0;
}
fragment DOut fs_pat_d(VOut in [[stage_in]], constant uint& seed [[buffer(0)]]) {
    uint2 p = uint2(in.pos.xy);
    DOut o;
    o.depth = float((p.x + p.y * 64 + seed) & 4095) / 4096.0;
    return o;
}
kernel void kf2d(texture2d<float, access::read> t [[texture(0)]], device uint4* o [[buffer(0)]],
                 constant uint2& p [[buffer(1)]], uint2 g [[thread_position_in_grid]]) {
    uint w = t.get_width(p.x), h = t.get_height(p.x);
    if (g.x >= w || g.y >= h) return;
    o[g.y * w + g.x] = as_type<uint4>(t.read(g, p.x));
}
kernel void ku2d(texture2d<uint, access::read> t [[texture(0)]], device uint4* o [[buffer(0)]],
                 constant uint2& p [[buffer(1)]], uint2 g [[thread_position_in_grid]]) {
    uint w = t.get_width(p.x), h = t.get_height(p.x);
    if (g.x >= w || g.y >= h) return;
    o[g.y * w + g.x] = t.read(g, p.x);
}
kernel void kf2da(texture2d_array<float, access::read> t [[texture(0)]], device uint4* o [[buffer(0)]],
                  constant uint2& p [[buffer(1)]], uint2 g [[thread_position_in_grid]]) {
    uint w = t.get_width(p.x), h = t.get_height(p.x);
    if (g.x >= w || g.y >= h) return;
    o[g.y * w + g.x] = as_type<uint4>(t.read(g, p.y, p.x));
}
)MSL";

static bool setup() {
    g_dev = MTLCreateSystemDefaultDevice();
    if (!g_dev) {
        out("error", "MTLCreateSystemDefaultDevice returned nil");
        return false;
    }
    g_queue = [g_dev newCommandQueue];
    NSError* err = nil;
    g_lib = [g_dev newLibraryWithSource:[NSString stringWithUTF8String:kSource] options:nil error:&err];
    if (!g_lib) {
        out("error", "library: %s", errstr(err).c_str());
        return false;
    }
    return true;
}

static id<MTLFunction> fn(const char* name) {
    return [g_lib newFunctionWithName:[NSString stringWithUTF8String:name]];
}

static id<MTLComputePipelineState> compute_pso(const char* name) {
    NSError* err = nil;
    id<MTLComputePipelineState> p = [g_dev newComputePipelineStateWithFunction:fn(name) error:&err];
    if (!p) out("error", "compute pipeline %s: %s", name, errstr(err).c_str());
    return p;
}

static void print_header() {
    int translated = -1;
    size_t sz = sizeof(translated);
    if (sysctlbyname("sysctl.proc_translated", &translated, &sz, nullptr, 0) != 0) translated = -1;
    out("device.name", "%s", [[g_dev name] UTF8String]);
    out("process.macos", "%s", [[[NSProcessInfo processInfo] operatingSystemVersionString] UTF8String]);
    out("process.proc_translated", "%d", translated);
#if defined(__x86_64__)
    out("process.compiled_arch", "x86_64");
#else
    out("process.compiled_arch", "arm64");
#endif
    const char* dl = getenv("MTL_DEBUG_LAYER");
    const char* dm = getenv("MTL_DEBUG_LAYER_ERROR_MODE");
    out("env.MTL_DEBUG_LAYER", "%s (error mode %s)", dl ? dl : "unset", dm ? dm : "unset");
}

// =============================================================================================
// bench
// =============================================================================================

namespace {

struct Fmt {
    const char* name;
    const char* key;
    MTLPixelFormat pf;
    bool depth;
    bool stencil;
    uint32_t bpp;
};

const Fmt kFmts[] = {
    {"RGBA8Unorm", "rgba8", MTLPixelFormatRGBA8Unorm, false, false, 4},
    {"RGBA16Float", "rgba16f", MTLPixelFormatRGBA16Float, false, false, 8},
    {"RGB10A2Unorm", "rgb10a2", MTLPixelFormatRGB10A2Unorm, false, false, 4},
    {"Depth32Float_Stencil8", "d32s8", MTLPixelFormatDepth32Float_Stencil8, true, true, 5},
    {"Depth32Float", "d32", MTLPixelFormatDepth32Float, true, false, 4},
};

struct UsageVar {
    const char* name;
    MTLTextureUsage extra;
};

const UsageVar kUsages[] = {
    {"base", 0},
    {"+SW", MTLTextureUsageShaderWrite},
    {"+PFV", MTLTextureUsagePixelFormatView},
    {"+both", MTLTextureUsageShaderWrite | MTLTextureUsagePixelFormatView},
};

struct Stat {
    double median = 0, p10 = 0, p90 = 0;
    int n = 0;
};

struct BenchCtx {
    uint32_t size = 4096;
    int reps = 40;
    int warmup = 3;
    bool clearLoad = false;
    id<MTLBuffer> acc;                                   // 256 words, read pass output
    id<MTLComputePipelineState> rdColor, rdDepth, cwTiles, cwNoise;
    id<MTLDepthStencilState> dsDepth, dsDepthStencil;
    NSMutableDictionary<NSString*, id<MTLRenderPipelineState>>* psos;
    std::map<std::string, Stat> stats;                   // "fmt|content|pass|usage"
    std::vector<std::string> rows;                       // "fmt|content|pass" in first-seen order
};

typedef void (^EncodeFn)(id<MTLCommandBuffer>);

// Commits one command buffer built by `enc`, waits, returns the GPU time in ms (-1 on failure).
double time_cb(EncodeFn enc) {
    @autoreleasepool {
        id<MTLCommandBuffer> cb = [g_queue commandBuffer];
        enc(cb);
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.status != MTLCommandBufferStatusCompleted) {
            out("error", "command buffer failed: status=%d %s", (int)cb.status, errstr(cb.error).c_str());
            return -1;
        }
        return (cb.GPUEndTime - cb.GPUStartTime) * 1000.0;
    }
}

Stat make_stat(std::vector<double> v) {
    Stat s;
    s.n = (int)v.size();
    if (v.empty()) return s;
    std::sort(v.begin(), v.end());
    auto pick = [&](double p) { return v[(size_t)std::lround(p * (double)(v.size() - 1))]; };
    s.median = v.size() % 2 ? v[v.size() / 2] : 0.5 * (v[v.size() / 2 - 1] + v[v.size() / 2]);
    s.p10 = pick(0.1);
    s.p90 = pick(0.9);
    return s;
}

typedef std::function<EncodeFn(int)> VarFn;  // block for usage variant i (nil: none)

// Measures the active usage variants interleaved: every round times one command buffer per
// variant (alternating the order between rounds), so clock/thermal drift hits all variants alike.
// `prep` (optional) runs untimed in its own command buffer before each timed one.
std::vector<Stat> measure_all(BenchCtx& c, const bool* active, VarFn prep, VarFn timed) {
    const int nu = (int)(sizeof(kUsages) / sizeof(kUsages[0]));
    std::vector<std::vector<double>> v(nu);
    for (int r = 0; r < c.warmup + c.reps; ++r) {
        for (int k = 0; k < nu; ++k) {
            int i = r % 2 ? nu - 1 - k : k;
            if (!active[i]) continue;
            if (prep) time_cb(prep(i));
            double t = time_cb(timed(i));
            if (t >= 0 && r >= c.warmup) v[i].push_back(t);
        }
    }
    std::vector<Stat> s;
    for (int i = 0; i < nu; ++i) s.push_back(make_stat(v[i]));
    return s;
}

void record(BenchCtx& c, const Fmt& f, const char* usage, const char* content, const char* pass, const Stat& s) {
    printf("DATA\t%s\t%s\t%s\t%s\t%.4f\t%.4f\t%.4f\t%d\n", f.key, usage, content, pass, s.median, s.p10, s.p90, s.n);
    fflush(stdout);
    std::string row = std::string(f.key) + "|" + content + "|" + pass;
    if (std::find(c.rows.begin(), c.rows.end(), row) == c.rows.end()) c.rows.push_back(row);
    c.stats[row + "|" + usage] = s;
}

id<MTLRenderPipelineState> render_pso(BenchCtx& c, const Fmt& f, const char* content) {
    NSString* key = [NSString stringWithFormat:@"%s|%s", f.key, content];
    id<MTLRenderPipelineState> p = c.psos[key];
    if (p) return p;
    MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
    bool plane = strcmp(content, "plane") == 0;
    d.vertexFunction = fn(plane ? "vs_plane" : "vs");
    if (f.depth) {
        d.fragmentFunction = fn(plane ? "fs_none" : strcmp(content, "tiles") == 0 ? "fs_tiles_d" : "fs_noise_d");
        d.depthAttachmentPixelFormat = f.pf;
        if (f.stencil) d.stencilAttachmentPixelFormat = f.pf;
    } else {
        d.fragmentFunction = fn(strcmp(content, "tiles") == 0 ? "fs_tiles" : "fs_noise");
        d.colorAttachments[0].pixelFormat = f.pf;
    }
    NSError* err = nil;
    p = [g_dev newRenderPipelineStateWithDescriptor:d error:&err];
    if (!p) {
        out("error", "render pipeline %s: %s", [key UTF8String], errstr(err).c_str());
        return nil;
    }
    c.psos[key] = p;
    return p;
}

void encode_write(BenchCtx& c, id<MTLCommandBuffer> cb, id<MTLTexture> tex, const Fmt& f, const char* content) {
    MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    MTLLoadAction load = c.clearLoad ? MTLLoadActionClear : MTLLoadActionDontCare;
    if (!f.depth) {
        auto* ca = rpd.colorAttachments[0];
        ca.texture = tex;
        ca.loadAction = load;
        ca.storeAction = MTLStoreActionStore;
        ca.clearColor = MTLClearColorMake(0, 0, 0, 0);
    } else {
        rpd.depthAttachment.texture = tex;
        rpd.depthAttachment.loadAction = load;
        rpd.depthAttachment.storeAction = MTLStoreActionStore;
        rpd.depthAttachment.clearDepth = 1.0;
        if (f.stencil) {
            rpd.stencilAttachment.texture = tex;
            rpd.stencilAttachment.loadAction = load;
            rpd.stencilAttachment.storeAction = MTLStoreActionStore;
            rpd.stencilAttachment.clearStencil = 0;
        }
    }
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rpd];
    [e setRenderPipelineState:render_pso(c, f, content)];
    if (f.depth) {
        [e setDepthStencilState:f.stencil ? c.dsDepthStencil : c.dsDepth];
        if (f.stencil) [e setStencilReferenceValue:0x5A];
    }
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
}

void encode_read(BenchCtx& c, id<MTLCommandBuffer> cb, id<MTLTexture> tex, const Fmt& f) {
    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:f.depth ? c.rdDepth : c.rdColor];
    [e setTexture:tex atIndex:0];
    [e setBuffer:c.acc offset:0 atIndex:0];
    NSUInteger n = (c.size + 15) / 16;
    [e dispatchThreadgroups:MTLSizeMake(n, n, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    [e endEncoding];
}

void encode_compute_write(BenchCtx& c, id<MTLCommandBuffer> cb, id<MTLTexture> tex, const char* content) {
    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:strcmp(content, "tiles") == 0 ? c.cwTiles : c.cwNoise];
    [e setTexture:tex atIndex:0];
    NSUInteger n = (c.size + 15) / 16;
    [e dispatchThreadgroups:MTLSizeMake(n, n, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    [e endEncoding];
}

void encode_optimize(id<MTLCommandBuffer> cb, id<MTLTexture> tex) {
    id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
    [e optimizeContentsForGPUAccess:tex];
    [e endEncoding];
}

const char* compression_name(id<MTLTexture> t) {
    return t.compressionType == MTLTextureCompressionTypeLossless ? "lossless" : "lossy";
}

// Measures one pass on every active variant and records it.
void run_pass(BenchCtx& c, const Fmt& f, const bool* active, const char* content, const char* pass, VarFn prep,
              VarFn timed) {
    std::vector<Stat> s = measure_all(c, active, prep, timed);
    for (size_t i = 0; i < s.size(); ++i)
        if (active[i]) record(c, f, kUsages[i].name, content, pass, s[i]);
}

void bench_format(BenchCtx& c, const Fmt& f, id<MTLTexture> __strong* tex) {
    const int nu = (int)(sizeof(kUsages) / sizeof(kUsages[0]));
    bool all[4], swv[4];
    for (int i = 0; i < nu; ++i) {
        all[i] = tex[i] != nil;
        swv[i] = all[i] && (kUsages[i].extra & MTLTextureUsageShaderWrite);
    }
    std::vector<const char*> contents = {"tiles", "noise"};
    if (f.depth) contents.insert(contents.begin() + 1, "plane");

    for (const char* content : contents) {
        VarFn write = [&](int i) -> EncodeFn {
            id<MTLTexture> t = tex[i];
            return ^(id<MTLCommandBuffer> cb) { encode_write(c, cb, t, f, content); };
        };
        VarFn read = [&](int i) -> EncodeFn {
            id<MTLTexture> t = tex[i];
            return ^(id<MTLCommandBuffer> cb) { encode_read(c, cb, t, f); };
        };
        VarFn writeRead = [&](int i) -> EncodeFn {
            id<MTLTexture> t = tex[i];
            return ^(id<MTLCommandBuffer> cb) {
                encode_write(c, cb, t, f, content);
                encode_read(c, cb, t, f);
            };
        };
        VarFn cw = [&](int i) -> EncodeFn {
            id<MTLTexture> t = tex[i];
            return ^(id<MTLCommandBuffer> cb) { encode_compute_write(c, cb, t, content); };
        };
        VarFn opt = [&](int i) -> EncodeFn {
            id<MTLTexture> t = tex[i];
            return ^(id<MTLCommandBuffer> cb) { encode_optimize(cb, t); };
        };
        // Brings every active texture to a known state: written by `w`, then optionally optimized.
        auto settle = [&](VarFn w, bool optimize) {
            for (int i = 0; i < nu; ++i) {
                if (!all[i]) continue;
                time_cb(w(i));
                if (optimize) time_cb(opt(i));
            }
        };

        run_pass(c, f, all, content, "W", nullptr, write);
        run_pass(c, f, all, content, "R", nullptr, read);
        run_pass(c, f, all, content, "WR", nullptr, writeRead);

        // Optimize after the render-pass write: its own cost, then the read after it.
        run_pass(c, f, swv, content, "RP_OPT", write, opt);
        settle(write, true);
        run_pass(c, f, swv, content, "RP_OPT_R", nullptr, read);

        if (f.depth) continue;  // MSL cannot write depth textures from a kernel
        run_pass(c, f, swv, content, "CW", nullptr, cw);
        run_pass(c, f, swv, content, "CW_R", nullptr, read);
        run_pass(c, f, swv, content, "CW_OPT", cw, opt);
        settle(cw, true);
        run_pass(c, f, swv, content, "CW_OPT_R", nullptr, read);
        settle(write, false);  // leave the textures in the render-pass state
    }
}

void print_summary(BenchCtx& c) {
    printf("\nsummary (median ms per pass; ratio = variant / base; size %u, reps %d)\n", c.size, c.reps);
    printf("%-8s %-6s %-9s | %8s %8s %8s %8s | %6s %6s %6s\n", "format", "cont", "pass", "base", "+SW", "+PFV", "+both",
           "SW/b", "PFV/b", "both/b");
    for (const std::string& row : c.rows) {
        size_t a = row.find('|'), b = row.find('|', a + 1);
        std::string fmt = row.substr(0, a), cont = row.substr(a + 1, b - a - 1), pass = row.substr(b + 1);
        double v[4];
        char cell[4][16];
        for (int i = 0; i < 4; ++i) {
            auto it = c.stats.find(row + "|" + kUsages[i].name);
            v[i] = it == c.stats.end() ? -1 : it->second.median;
            if (v[i] < 0) {
                snprintf(cell[i], sizeof(cell[i]), "-");
            } else {
                snprintf(cell[i], sizeof(cell[i]), "%.3f", v[i]);
            }
        }
        char rat[3][16];
        for (int i = 1; i < 4; ++i) {
            if (v[0] > 0 && v[i] > 0) {
                snprintf(rat[i - 1], sizeof(rat[i - 1]), "%.2f", v[i] / v[0]);
            } else {
                snprintf(rat[i - 1], sizeof(rat[i - 1]), "-");
            }
        }
        printf("%-8s %-6s %-9s | %8s %8s %8s %8s | %6s %6s %6s\n", fmt.c_str(), cont.c_str(), pass.c_str(), cell[0],
               cell[1], cell[2], cell[3], rat[0], rat[1], rat[2]);
    }
    fflush(stdout);
}

int run_bench(int argc, char** argv) {
    BenchCtx c;
    std::string only;
    for (int i = 0; i < argc; ++i) {
        std::string a = argv[i];
        auto next = [&]() -> const char* { return i + 1 < argc ? argv[++i] : ""; };
        if (a == "--size") {
            c.size = (uint32_t)atoi(next());
        } else if (a == "--reps") {
            c.reps = atoi(next());
        } else if (a == "--warmup") {
            c.warmup = atoi(next());
        } else if (a == "--load") {
            c.clearLoad = std::string(next()) == "clear";
        } else if (a == "--formats") {
            only = std::string(",") + next() + ",";
        }
    }
    if (!setup()) return 1;
    print_header();
    out("bench.size", "%u", c.size);
    out("bench.reps", "%d (warmup %d)", c.reps, c.warmup);
    out("bench.write_load_action", "%s", c.clearLoad ? "Clear" : "DontCare");
    out("bench.read_pass", "compute read() of every texel, simd_sum + 1 atomic per 16x16 threadgroup");

    c.psos = [NSMutableDictionary new];
    c.acc = [g_dev newBufferWithLength:256 * 4 options:MTLResourceStorageModePrivate];
    c.rdColor = compute_pso("rd_color");
    c.rdDepth = compute_pso("rd_depth");
    c.cwTiles = compute_pso("cw_tiles");
    c.cwNoise = compute_pso("cw_noise");
    if (!c.rdColor || !c.rdDepth || !c.cwTiles || !c.cwNoise) return 1;
    MTLDepthStencilDescriptor* dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionAlways;
    dd.depthWriteEnabled = YES;
    c.dsDepth = [g_dev newDepthStencilStateWithDescriptor:dd];
    MTLStencilDescriptor* sd = [MTLStencilDescriptor new];
    sd.stencilCompareFunction = MTLCompareFunctionAlways;
    sd.depthStencilPassOperation = MTLStencilOperationReplace;
    dd.frontFaceStencil = sd;
    dd.backFaceStencil = sd;
    c.dsDepthStencil = [g_dev newDepthStencilStateWithDescriptor:dd];

    printf("DATA\tformat\tusage\tcontent\tpass\tmedian_ms\tp10_ms\tp90_ms\tn\n");
    for (const Fmt& f : kFmts) {
        if (!only.empty() && only.find(std::string(",") + f.key + ",") == std::string::npos) continue;
        @autoreleasepool {
            const int nu = (int)(sizeof(kUsages) / sizeof(kUsages[0]));
            id<MTLTexture> __strong tex[4] = {nil, nil, nil, nil};
            for (int i = 0; i < nu; ++i) {
                const UsageVar& u = kUsages[i];
                MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f.pf
                                                                                              width:c.size
                                                                                             height:c.size
                                                                                          mipmapped:NO];
                td.storageMode = MTLStorageModePrivate;
                td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | u.extra;
                @try {
                    tex[i] = [g_dev newTextureWithDescriptor:td];
                } @catch (NSException* ex) {
                    out("skip", "%s %s: exception %s", f.key, u.name, [[ex reason] UTF8String]);
                    continue;
                }
                if (!tex[i]) {
                    out("skip", "%s %s: newTextureWithDescriptor returned nil (usage 0x%lx not supported)", f.key,
                        u.name, (unsigned long)td.usage);
                    continue;
                }
                MTLSizeAndAlign sa = [g_dev heapTextureSizeAndAlignWithDescriptor:td];
                out("texture", "%s %s usage=0x%lx rawBytes=%llu allocatedSize=%lu heapSize=%lu compressionType=%s "
                    "allowGPUOptimizedContents=%d",
                    f.key, u.name, (unsigned long)tex[i].usage, (unsigned long long)c.size * c.size * f.bpp,
                    (unsigned long)tex[i].allocatedSize, (unsigned long)sa.size, compression_name(tex[i]),
                    (int)tex[i].allowGPUOptimizedContents);
            }
            // Wake the GPU up (clock ramp, lazy pipeline setup): ~300 ms of write+read passes.
            double t0 = now_ms();
            for (const char* content : {"tiles", "plane", "noise"}) {  // build every pipeline first
                if (!f.depth && strcmp(content, "plane") == 0) continue;
                render_pso(c, f, content);
            }
            while (now_ms() - t0 < 300) {
                for (int i = 0; i < nu; ++i) {
                    if (!tex[i]) continue;
                    id<MTLTexture> t = tex[i];
                    BenchCtx* cp = &c;
                    time_cb(^(id<MTLCommandBuffer> cb) {
                        for (const char* content : {"tiles", "plane", "noise"}) {
                            if (!f.depth && strcmp(content, "plane") == 0) continue;
                            encode_write(*cp, cb, t, f, content);
                            encode_read(*cp, cb, t, f);
                        }
                    });
                }
            }
            bench_format(c, f, tex);
        }
    }
    print_summary(c);
    return 0;
}

// =============================================================================================
// views
// =============================================================================================

enum class ReadKind { F2D, U2D, F2DA };
enum class Form { Short, Range, Swizzle };

struct Exp {
    uint32_t u[4] = {0, 0, 0, 0};
    float f[4] = {0, 0, 0, 0};
};
typedef void (*ExpFn)(const uint8_t* texel, Exp& e);

struct ViewCase {
    const char* name;
    MTLPixelFormat baseFmt;
    MTLTextureType baseType = MTLTextureType2D;
    uint32_t baseLevels = 1, baseSlices = 1;
    MTLPixelFormat viewFmt;
    MTLTextureType viewType = MTLTextureType2D;
    NSRange levels = {0, 1}, slices = {0, 1};
    Form form = Form::Short;
    MTLTextureSwizzleChannels swz = {MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue,
                                     MTLTextureSwizzleAlpha};
    ReadKind kind = ReadKind::F2D;
    ExpFn expect = nullptr;
    int ncomp = 4;
    float tol = 1e-4f;
    uint32_t gtBpp = 4;                       // bytes per texel of the ground-truth copy
    uint32_t gtLevel = 0, gtSlice = 0;        // base mip/slice the view's (readLevel, readSlice) maps to
    uint32_t readLevel = 0, readSlice = 0;    // lod / array index passed to read() on the view
};

float srgb_to_linear(float c) { return c <= 0.04045f ? c / 12.92f : std::pow((c + 0.055f) / 1.055f, 2.4f); }
float b2f(uint8_t b) { return (float)b / 255.0f; }
uint32_t rd32(const uint8_t* p) {
    uint32_t v;
    memcpy(&v, p, 4);
    return v;
}

void e_rgba8_to_srgb(const uint8_t* t, Exp& e) {
    for (int i = 0; i < 3; ++i) e.f[i] = srgb_to_linear(b2f(t[i]));
    e.f[3] = b2f(t[3]);
}
void e_same(const uint8_t* t, Exp& e) {
    for (int i = 0; i < 4; ++i) e.f[i] = b2f(t[i]);
}
void e_rgba8_uint(const uint8_t* t, Exp& e) {
    for (int i = 0; i < 4; ++i) e.u[i] = t[i];
}
void e_word(const uint8_t* t, Exp& e) { e.u[0] = rd32(t); }
void e_bgra(const uint8_t* t, Exp& e) {
    e.f[0] = b2f(t[2]);
    e.f[1] = b2f(t[1]);
    e.f[2] = b2f(t[0]);
    e.f[3] = b2f(t[3]);
}
void e_rrrr(const uint8_t* t, Exp& e) {
    for (int i = 0; i < 4; ++i) e.f[i] = b2f(t[0]);
}
void e_rgba16_uint(const uint8_t* t, Exp& e) {
    for (int i = 0; i < 4; ++i) {
        uint16_t h;
        memcpy(&h, t + 2 * i, 2);
        e.u[i] = h;
    }
}
void e_rg32(const uint8_t* t, Exp& e) {
    e.u[0] = rd32(t);
    e.u[1] = rd32(t + 4);
}
void e_stencil(const uint8_t* t, Exp& e) { e.u[0] = t[0]; }
void e_depth_f(const uint8_t* t, Exp& e) { memcpy(&e.f[0], t, 4); }

ViewCase mk(const char* name, MTLPixelFormat bf, MTLPixelFormat vf, ExpFn ex) {
    ViewCase c;
    c.name = name;
    c.baseFmt = bf;
    c.viewFmt = vf;
    c.expect = ex;
    return c;
}

std::vector<ViewCase> make_cases() {
    std::vector<ViewCase> v;
    const MTLPixelFormat R8 = MTLPixelFormatRGBA8Unorm, R8S = MTLPixelFormatRGBA8Unorm_sRGB;
    {
        ViewCase c = mk("rgba8_to_srgb", R8, R8S, e_rgba8_to_srgb);
        c.tol = 2e-3f;
        v.push_back(c);
        c.name = "rgba8_to_srgb_rangeform";
        c.form = Form::Range;
        v.push_back(c);
        c.name = "rgba8_to_srgb_swizzleform";
        c.form = Form::Swizzle;
        v.push_back(c);
    }
    v.push_back(mk("srgb_to_rgba8", R8S, R8, e_same));
    {
        ViewCase c = mk("rgba8_to_rgba8uint", R8, MTLPixelFormatRGBA8Uint, e_rgba8_uint);
        c.kind = ReadKind::U2D;
        v.push_back(c);
    }
    {
        ViewCase c = mk("rgba8_to_r32uint", R8, MTLPixelFormatR32Uint, e_word);
        c.kind = ReadKind::U2D;
        c.ncomp = 1;
        v.push_back(c);
        c.name = "rgba8_to_r32uint_rangeform";
        c.form = Form::Range;
        v.push_back(c);
    }
    v.push_back(mk("rgba8_to_bgra8", R8, MTLPixelFormatBGRA8Unorm, e_bgra));
    v.push_back(mk("rgba8_same_short", R8, R8, e_same));
    {
        ViewCase c = mk("rgba8_swizzle_bgra", R8, R8, e_bgra);
        c.form = Form::Swizzle;
        c.swz = {MTLTextureSwizzleBlue, MTLTextureSwizzleGreen, MTLTextureSwizzleRed, MTLTextureSwizzleAlpha};
        v.push_back(c);
        c.name = "rgba8_swizzle_rrrr";
        c.expect = e_rrrr;
        c.swz = {MTLTextureSwizzleRed, MTLTextureSwizzleRed, MTLTextureSwizzleRed, MTLTextureSwizzleRed};
        v.push_back(c);
    }
    {
        ViewCase c = mk("rgba8_2d_to_2darray", R8, R8, e_same);
        c.viewType = MTLTextureType2DArray;
        c.form = Form::Range;
        c.kind = ReadKind::F2DA;
        v.push_back(c);
    }
    {
        // 2D-array base with 3 mips and 3 slices; the view is slice 2 / mip 1 as a plain 2D texture.
        ViewCase c = mk("rgba8_subrange_2d", R8, R8, e_same);
        c.baseType = MTLTextureType2DArray;
        c.baseLevels = 3;
        c.baseSlices = 3;
        c.levels = {1, 1};
        c.slices = {2, 1};
        c.form = Form::Range;
        c.gtLevel = 1;
        c.gtSlice = 2;
        v.push_back(c);
        // Array view over mips 1..2 and slices 1..2; read view mip 1 / slice 1 = base mip 2 / slice 2.
        c.name = "rgba8_subrange_2darray";
        c.viewType = MTLTextureType2DArray;
        c.levels = {1, 2};
        c.slices = {1, 2};
        c.kind = ReadKind::F2DA;
        c.readLevel = 1;
        c.readSlice = 1;
        c.gtLevel = 2;
        c.gtSlice = 2;
        v.push_back(c);
    }
    {
        ViewCase c = mk("rgba16f_to_rgba16uint", MTLPixelFormatRGBA16Float, MTLPixelFormatRGBA16Uint, e_rgba16_uint);
        c.kind = ReadKind::U2D;
        c.gtBpp = 8;
        v.push_back(c);
        c = mk("rgba16f_to_rg32uint", MTLPixelFormatRGBA16Float, MTLPixelFormatRG32Uint, e_rg32);
        c.kind = ReadKind::U2D;
        c.ncomp = 2;
        c.gtBpp = 8;
        v.push_back(c);
    }
    {
        ViewCase c = mk("rgb10a2_to_r32uint", MTLPixelFormatRGB10A2Unorm, MTLPixelFormatR32Uint, e_word);
        c.kind = ReadKind::U2D;
        c.ncomp = 1;
        v.push_back(c);
    }
    {
        ViewCase c = mk("d32s8_to_x32_stencil8", MTLPixelFormatDepth32Float_Stencil8, MTLPixelFormatX32_Stencil8, e_stencil);
        c.kind = ReadKind::U2D;
        c.ncomp = 1;
        c.gtBpp = 1;
        v.push_back(c);
    }
    {
        ViewCase c = mk("d32_to_r32float", MTLPixelFormatDepth32Float, MTLPixelFormatR32Float, e_depth_f);
        c.ncomp = 1;
        c.tol = 0;
        v.push_back(c);
    }
    return v;
}

bool is_depth(MTLPixelFormat pf) { return pf == MTLPixelFormatDepth32Float || pf == MTLPixelFormatDepth32Float_Stencil8; }

// Result of one (case, variant): status is ok / nil / error.
struct CaseResult {
    std::string status = "ok", detail;
};

CaseResult fail(const char* status, const std::string& detail) {
    CaseResult r;
    r.status = status;
    r.detail = detail;
    return r;
}

bool run_cb(void (^enc)(id<MTLCommandBuffer>), std::string& err) {
    @autoreleasepool {
        id<MTLCommandBuffer> cb = [g_queue commandBuffer];
        enc(cb);
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.status != MTLCommandBufferStatusCompleted) {
            err = "command buffer status=" + std::to_string((int)cb.status) + " " + errstr(cb.error);
            return false;
        }
        return true;
    }
}

CaseResult run_view_case(const ViewCase& c, bool pfv) {
    const uint32_t kDim = 64;
    NSError* err = nil;
    MTLTextureDescriptor* td = [MTLTextureDescriptor new];
    td.textureType = c.baseType;
    td.pixelFormat = c.baseFmt;
    td.width = kDim;
    td.height = kDim;
    td.mipmapLevelCount = c.baseLevels;
    td.arrayLength = c.baseSlices;
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | (pfv ? MTLTextureUsagePixelFormatView : 0);
    id<MTLTexture> base = [g_dev newTextureWithDescriptor:td];
    if (!base) return fail("error", "base texture creation returned nil");

    // Write the known pattern into every (mip, slice).
    bool depth = is_depth(c.baseFmt), stencil = c.baseFmt == MTLPixelFormatDepth32Float_Stencil8;
    MTLRenderPipelineDescriptor* rpd = [MTLRenderPipelineDescriptor new];
    rpd.vertexFunction = fn("vs");
    if (depth) {
        rpd.fragmentFunction = fn("fs_pat_d");
        rpd.depthAttachmentPixelFormat = c.baseFmt;
        if (stencil) rpd.stencilAttachmentPixelFormat = c.baseFmt;
    } else {
        rpd.fragmentFunction = fn("fs_pat");
        rpd.colorAttachments[0].pixelFormat = c.baseFmt;
    }
    id<MTLRenderPipelineState> pso = [g_dev newRenderPipelineStateWithDescriptor:rpd error:&err];
    if (!pso) return fail("error", "pattern pipeline: " + errstr(err));
    MTLDepthStencilDescriptor* dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionAlways;
    dd.depthWriteEnabled = YES;
    if (stencil) {
        MTLStencilDescriptor* sd = [MTLStencilDescriptor new];
        sd.stencilCompareFunction = MTLCompareFunctionAlways;
        sd.depthStencilPassOperation = MTLStencilOperationReplace;
        dd.frontFaceStencil = sd;
        dd.backFaceStencil = sd;
    }
    id<MTLDepthStencilState> ds = [g_dev newDepthStencilStateWithDescriptor:dd];

    std::string e;
    bool ok = run_cb(^(id<MTLCommandBuffer> cb) {
        for (uint32_t l = 0; l < c.baseLevels; ++l) {
            for (uint32_t s = 0; s < c.baseSlices; ++s) {
                MTLRenderPassDescriptor* pd = [MTLRenderPassDescriptor renderPassDescriptor];
                if (depth) {
                    pd.depthAttachment.texture = base;
                    pd.depthAttachment.level = l;
                    pd.depthAttachment.slice = s;
                    pd.depthAttachment.loadAction = MTLLoadActionDontCare;
                    pd.depthAttachment.storeAction = MTLStoreActionStore;
                    if (stencil) {
                        pd.stencilAttachment.texture = base;
                        pd.stencilAttachment.level = l;
                        pd.stencilAttachment.slice = s;
                        pd.stencilAttachment.loadAction = MTLLoadActionDontCare;
                        pd.stencilAttachment.storeAction = MTLStoreActionStore;
                    }
                } else {
                    pd.colorAttachments[0].texture = base;
                    pd.colorAttachments[0].level = l;
                    pd.colorAttachments[0].slice = s;
                    pd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
                    pd.colorAttachments[0].storeAction = MTLStoreActionStore;
                }
                id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pd];
                [re setRenderPipelineState:pso];
                if (depth) [re setDepthStencilState:ds];
                uint32_t seed = l * 16 + s + 1;
                [re setFragmentBytes:&seed length:4 atIndex:0];
                uint32_t dim = std::max(1u, kDim >> l);
                if (stencil) {
                    // left half stencil 0x11, right half 0x5A
                    MTLScissorRect left = {0, 0, dim / 2, dim}, right = {dim / 2, 0, dim - dim / 2, dim};
                    [re setScissorRect:left];
                    [re setStencilReferenceValue:0x11];
                    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                    [re setScissorRect:right];
                    [re setStencilReferenceValue:0x5A];
                    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                } else {
                    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                }
                [re endEncoding];
            }
        }
    }, e);
    if (!ok) return fail("error", "pattern write: " + e);

    // Ground truth: raw bytes of the base's (gtLevel, gtSlice), copied by a blit (no view involved).
    uint32_t gw = std::max(1u, kDim >> c.gtLevel);
    id<MTLBuffer> gt = [g_dev newBufferWithLength:gw * gw * c.gtBpp options:MTLResourceStorageModeShared];
    MTLBlitOption opt = MTLBlitOptionNone;
    if (stencil) opt = c.gtBpp == 1 ? MTLBlitOptionStencilFromDepthStencil : MTLBlitOptionDepthFromDepthStencil;
    ok = run_cb(^(id<MTLCommandBuffer> cb) {
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be copyFromTexture:base
                    sourceSlice:c.gtSlice
                    sourceLevel:c.gtLevel
                   sourceOrigin:MTLOriginMake(0, 0, 0)
                     sourceSize:MTLSizeMake(gw, gw, 1)
                       toBuffer:gt
              destinationOffset:0
         destinationBytesPerRow:gw * c.gtBpp
       destinationBytesPerImage:gw * gw * c.gtBpp
                        options:opt];
        [be endEncoding];
    }, e);
    if (!ok) return fail("error", "ground-truth copy: " + e);

    // The view under test.
    id<MTLTexture> view = nil;
    @try {
        switch (c.form) {
            case Form::Short:
                view = [base newTextureViewWithPixelFormat:c.viewFmt];
                break;
            case Form::Range:
                view = [base newTextureViewWithPixelFormat:c.viewFmt
                                               textureType:c.viewType
                                                    levels:c.levels
                                                    slices:c.slices];
                break;
            case Form::Swizzle:
                view = [base newTextureViewWithPixelFormat:c.viewFmt
                                               textureType:c.viewType
                                                    levels:c.levels
                                                    slices:c.slices
                                                   swizzle:c.swz];
                break;
        }
    } @catch (NSException* ex) {
        return fail("error", std::string("exception: ") + [[ex reason] UTF8String]);
    }
    if (!view) return fail("nil", "view creation returned nil");

    // Read through the view.
    const char* kname = c.kind == ReadKind::F2D ? "kf2d" : c.kind == ReadKind::U2D ? "ku2d" : "kf2da";
    id<MTLComputePipelineState> cps = compute_pso(kname);
    if (!cps) return fail("error", "reader pipeline");
    id<MTLBuffer> ob = [g_dev newBufferWithLength:gw * gw * 16 options:MTLResourceStorageModeShared];
    memset(ob.contents, 0xCD, ob.length);
    const uint32_t pLevel = c.readLevel, pSlice = c.readSlice;
    ok = run_cb(^(id<MTLCommandBuffer> cb) {
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:cps];
        [ce setTexture:view atIndex:0];
        [ce setBuffer:ob offset:0 atIndex:0];
        uint32_t params[2] = {pLevel, pSlice};
        [ce setBytes:params length:sizeof(params) atIndex:1];
        [ce dispatchThreads:MTLSizeMake(gw, gw, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [ce endEncoding];
    }, e);
    if (!ok) return fail("error", "view read: " + e);

    // Compare with the CPU expectation.
    const uint8_t* g = (const uint8_t*)gt.contents;
    const uint32_t* o = (const uint32_t*)ob.contents;
    for (uint32_t y = 0; y < gw; ++y) {
        for (uint32_t x = 0; x < gw; ++x) {
            Exp ex;
            c.expect(g + ((size_t)y * gw + x) * c.gtBpp, ex);
            const uint32_t* got = o + ((size_t)y * gw + x) * 4;
            for (int i = 0; i < c.ncomp; ++i) {
                bool bad;
                char buf[160];
                if (c.kind == ReadKind::U2D) {
                    bad = got[i] != ex.u[i];
                    snprintf(buf, sizeof(buf), "texel (%u,%u) comp %d: got %u expected %u", x, y, i, got[i], ex.u[i]);
                } else {
                    float gf;
                    memcpy(&gf, &got[i], 4);
                    bad = !(std::fabs(gf - ex.f[i]) <= c.tol);
                    snprintf(buf, sizeof(buf), "texel (%u,%u) comp %d: got %.6f expected %.6f", x, y, i, gf, ex.f[i]);
                }
                if (bad) return fail("error", std::string("value mismatch, ") + buf);
            }
        }
    }
    return CaseResult();
}

const ViewCase* find_case(const std::vector<ViewCase>& cs, const std::string& n) {
    for (const ViewCase& c : cs)
        if (n == c.name) return &c;
    return nullptr;
}

std::string self_path() {
    char buf[4096];
    uint32_t n = sizeof(buf);
    if (_NSGetExecutablePath(buf, &n) != 0) return "";
    return buf;
}

std::string read_file(NSString* path) {
    NSData* d = [NSData dataWithContentsOfFile:path];
    return d ? std::string((const char*)d.bytes, d.length) : std::string();
}

// Runs this binary as `views <case> --pfv N` and classifies the outcome.
CaseResult run_child(const std::string& name, bool pfv, std::string& stderrTail) {
    @autoreleasepool {
        NSString* tmp = NSTemporaryDirectory();
        NSString* fo = [tmp stringByAppendingPathComponent:[NSString stringWithFormat:@"mcp_%d_o.txt", getpid()]];
        NSString* fe = [tmp stringByAppendingPathComponent:[NSString stringWithFormat:@"mcp_%d_e.txt", getpid()]];
        [[NSFileManager defaultManager] createFileAtPath:fo contents:nil attributes:nil];
        [[NSFileManager defaultManager] createFileAtPath:fe contents:nil attributes:nil];
        NSTask* t = [NSTask new];
        t.executableURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:self_path().c_str()]];
        t.arguments = @[ @"views", [NSString stringWithUTF8String:name.c_str()], @"--pfv", pfv ? @"1" : @"0" ];
        t.standardOutput = [NSFileHandle fileHandleForWritingAtPath:fo];
        t.standardError = [NSFileHandle fileHandleForWritingAtPath:fe];
        NSError* err = nil;
        if (![t launchAndReturnError:&err]) return fail("error", "spawn failed: " + errstr(err));
        [t waitUntilExit];
        std::string so = read_file(fo), se = read_file(fe);
        [[NSFileManager defaultManager] removeItemAtPath:fo error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:fe error:nil];

        // Last six stderr lines (the debug layer's assertion text is multi-line).
        std::vector<std::string> lines, hits;
        size_t pos = 0;
        while (pos < se.size()) {
            size_t nl = se.find('\n', pos);
            if (nl == std::string::npos) nl = se.size();
            std::string ln = se.substr(pos, nl - pos);
            pos = nl + 1;
            if (ln.empty() || ln.find("Validation Enabled") != std::string::npos) continue;
            lines.push_back(ln);
            std::string low = ln;
            for (char& ch : low) ch = (char)tolower(ch);
            if (low.find("assert") != std::string::npos || low.find("mtldebug") != std::string::npos ||
                low.find("validation") != std::string::npos || low.find("failed") != std::string::npos ||
                low.find("error") != std::string::npos || low.find("invalid") != std::string::npos)
                hits.push_back(ln);
        }
        auto tail = [](const std::vector<std::string>& v) {
            std::string s;
            for (size_t i = v.size() > 6 ? v.size() - 6 : 0; i < v.size(); ++i) s += (s.empty() ? "" : " // ") + v[i];
            return s.size() > 600 ? s.substr(0, 600) + "..." : s;
        };
        stderrTail = tail(lines);

        if (t.terminationReason == NSTaskTerminationReasonUncaughtSignal || t.terminationStatus != 0) {
            return fail("abort", "child " + std::string(t.terminationReason == NSTaskTerminationReasonUncaughtSignal ? "signal " : "exit ") +
                                     std::to_string(t.terminationStatus));
        }
        size_t rp = so.find("RESULT ");
        if (rp == std::string::npos) return fail("error", "no RESULT line");
        std::string line = so.substr(rp + 7, so.find('\n', rp) - rp - 7);
        size_t sp = line.find(' ');
        CaseResult r;
        r.status = line.substr(0, sp);
        r.detail = sp == std::string::npos ? "" : line.substr(sp + 1);
        if (r.status == "ok" && !hits.empty()) {
            r.status = "error";
            r.detail = "debug layer / stderr reported something";
        }
        return r;
    }
}

int run_views(int argc, char** argv) {
    if (argc < 1) {
        out("error", "views needs: list | all | <case> [--pfv 0|1]");
        return 2;
    }
    std::vector<ViewCase> cases = make_cases();
    std::string what = argv[0];
    if (what == "list") {
        for (const ViewCase& c : cases) printf("%s\n", c.name);
        return 0;
    }
    int pfvOnly = -1;
    for (int i = 1; i + 1 < argc; ++i)
        if (std::string(argv[i]) == "--pfv") pfvOnly = atoi(argv[i + 1]);

    if (what == "all") {
        if (!setup()) return 1;
        print_header();
        struct Row {
            std::string name, np, pf;
        };
        std::vector<Row> rows;
        for (const ViewCase& c : cases) {
            Row row;
            row.name = c.name;
            for (int pfv = 0; pfv < 2; ++pfv) {
                std::string tail;
                CaseResult r = run_child(c.name, pfv != 0, tail);
                std::string s = r.status;
                if (s != "ok") s += " (" + r.detail + ")";
                char key[128];
                snprintf(key, sizeof(key), "views.%s.%s", c.name, pfv ? "with_PFV" : "no_PFV");
                out(key, "%s", s.c_str());
                if (r.status != "ok" && !tail.empty()) out(key, "  stderr tail: %s", tail.c_str());
                (pfv ? row.pf : row.np) = r.status;
            }
            rows.push_back(row);
        }
        printf("\nsummary (view of a base created without / with PixelFormatView)\n");
        printf("%-30s %-8s %-8s %s\n", "case", "no_PFV", "with_PFV", "needs PixelFormatView");
        for (const Row& r : rows)
            printf("%-30s %-8s %-8s %s\n", r.name.c_str(), r.np.c_str(), r.pf.c_str(),
                   r.np == "ok" ? "no" : (r.pf == "ok" ? "YES" : "unsupported even with it"));
        fflush(stdout);
        return 0;
    }

    const ViewCase* c = find_case(cases, what);
    if (!c) {
        out("error", "unknown case '%s' (views list)", what.c_str());
        return 2;
    }
    if (!setup()) return 1;
    for (int pfv = 0; pfv < 2; ++pfv) {
        if (pfvOnly >= 0 && pfv != pfvOnly) continue;
        CaseResult r;
        @autoreleasepool {
            @try {
                r = run_view_case(*c, pfv != 0);
            } @catch (NSException* ex) {
                r = fail("error", std::string("exception: ") + [[ex reason] UTF8String]);
            }
        }
        printf("RESULT %s %s\n", r.status.c_str(), r.detail.c_str());
        fflush(stdout);
    }
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    @autoreleasepool {
        std::string mode = argc > 1 ? argv[1] : "bench";
        if (mode == "views") return run_views(argc - 2, argv + 2);
        if (mode == "bench") return run_bench(argc - 2, argv + 2);
        if (mode.rfind("--", 0) == 0) return run_bench(argc - 1, argv + 1);
        fprintf(stderr, "usage: %s [bench [--size N] [--reps N] ...] | views list|all|<case>\n", argv[0]);
        return 2;
    }
}
