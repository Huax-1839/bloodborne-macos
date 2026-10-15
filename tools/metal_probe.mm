// SPDX-License-Identifier: GPL-2.0-or-later
//
// metal_probe: reports what Metal offers inside an x86-64 process under Rosetta 2 (plan P0.4).
// Every item prints `key: value` lines on stdout and is independent (@try per item).
//
// Build (x86-64, the game's environment):
//   clang++ -arch x86_64 -std=c++20 -fobjc-arc -O1 -mmacosx-version-min=14.0 tools/metal_probe.mm \
//     -framework Metal -framework MetalFX -framework QuartzCore -framework Foundation \
//     -o <scratch>/metal_probe
// Native comparison: the same line with -arch arm64.
// Run: arch -x86_64 <scratch>/metal_probe [scratch-dir]   (scratch-dir: where the binary archive goes)

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <QuartzCore/QuartzCore.h>

#include <mach/mach.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <unistd.h>

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>
#include <thread>

static id<MTLDevice> g_dev;
static id<MTLCommandQueue> g_queue;     // classic queue, carries the residency set
static id g_resSet;                     // id<MTLResidencySet>, macOS 15+ (type erased for the 14.0 target)
static NSString* g_scratch;

static double now_ms() {
    using namespace std::chrono;
    return duration<double, std::milli>(steady_clock::now().time_since_epoch()).count();
}

static void out(const char* key, const char* fmt, ...) __attribute__((format(printf, 2, 3)));
static void out(const char* key, const char* fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    printf("%s: %s\n", key, buf);
    fflush(stdout);
}

static const char* yn(bool b) { return b ? "yes" : "no"; }

static std::string errstr(NSError* e) {
    return e ? std::string([[e localizedDescription] UTF8String] ?: "?") : std::string("none");
}


// Adds/removes `b` to the global residency set and commits it (no-op before macOS 15).
static void res_update(id<MTLBuffer> b, bool add) {
    if (@available(macOS 15.0, *)) {
        id<MTLResidencySet> rs = g_resSet;
        if (add) {
            [rs addAllocation:b];
        } else {
            [rs removeAllocation:b];
        }
        [rs commit];
    }
}

static const char* kKernels = R"MSL(
#include <metal_stdlib>
using namespace metal;
// Reads b[0] (CPU wrote it), writes b[256] (byte offset 1024).
kernel void rw(device uint* b [[buffer(0)]], uint t [[thread_position_in_grid]]) {
    if (t == 0) b[256] = b[0] * 2u + 1u;
}
// Writes through a raw 64-bit address passed in a constant buffer (SPIRV-Cross PhysicalStorageBuffer).
kernel void addr_write(constant ulong& a [[buffer(0)]], uint t [[thread_position_in_grid]]) {
    device uint* p = (device uint*)a;
    if (t == 0) p[1] = p[0] + 0xBEEF0000u;
}
)MSL";

static id<MTLLibrary> g_kernLib;
static id<MTLComputePipelineState> g_psoRW;
static id<MTLComputePipelineState> g_psoAddr;

// Runs `pso` once on a classic command buffer of `q` with the buffer at slot 0 (or bytes when
// `bytes` is set). Returns false and fills `err` when the command buffer fails.
static bool run_classic(id<MTLCommandQueue> q, id<MTLComputePipelineState> pso, id<MTLBuffer> buf,
                        const void* bytes, size_t byteLen, std::string& err) {
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:pso];
    if (buf) {
        [enc setBuffer:buf offset:0 atIndex:0];
    } else {
        [enc setBytes:bytes length:byteLen atIndex:0];
    }
    [enc dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) {
        err = "status=" + std::to_string((int)cb.status) + " " + errstr(cb.error);
        return false;
    }
    return true;
}

#define ITEM(item_key, ...)                                                                           \
    do {                                                                                           \
        @try {                                                                                     \
            @autoreleasepool {                                                                     \
                __VA_ARGS__                                                                        \
            }                                                                                      \
        } @catch (NSException * ex) {                                                              \
            out(item_key ".exception", "%s: %s", [[ex name] UTF8String], [[ex reason] UTF8String]);    \
        }                                                                                          \
    } while (0)

// ---------------------------------------------------------------------------------------------

static void item1_process() {
    int translated = -1;
    size_t sz = sizeof(translated);
    if (sysctlbyname("sysctl.proc_translated", &translated, &sz, nullptr, 0) != 0) {
        out("process.proc_translated", "unavailable (errno %d)", errno);
    } else {
        out("process.proc_translated", "%d", translated);
    }
#if defined(__x86_64__)
    out("process.compiled_arch", "x86_64");
#elif defined(__arm64__)
    out("process.compiled_arch", "arm64");
#endif
    out("process.macos", "%s", [[[NSProcessInfo processInfo] operatingSystemVersionString] UTF8String]);
    out("process.getpagesize", "%d", getpagesize());
    out("process.vm_page_size", "%llu", (unsigned long long)vm_page_size);
    out("process.vm_kernel_page_size", "%llu", (unsigned long long)vm_kernel_page_size);
    int hwpage = 0;
    sz = sizeof(hwpage);
    sysctlbyname("hw.pagesize", &hwpage, &sz, nullptr, 0);
    out("process.hw.pagesize", "%d", hwpage);
}

static void item2_device() {
    out("device.name", "%s", [[g_dev name] UTF8String]);
    struct F { const char* n; NSInteger v; } fams[] = {
        {"Apple7", 1007}, {"Apple8", 1008}, {"Apple9", 1009}, {"Apple10", 1010}, {"Apple11", 1011},
        {"Mac2", 2002},   {"Metal3", 5001}, {"Metal4", 5002},
    };
    for (auto& f : fams) {
        char key[64];
        snprintf(key, sizeof(key), "device.family.%s", f.n);
        @try {
            out(key, "%s", yn([g_dev supportsFamily:(MTLGPUFamily)f.v]));
        } @catch (NSException* ex) {
            out(key, "exception %s", [[ex reason] UTF8String]);
        }
    }
    out("device.argumentBuffersSupport", "tier%d", (int)g_dev.argumentBuffersSupport + 1);
    out("device.maxBufferLength", "%llu (%.2f GiB)", (unsigned long long)g_dev.maxBufferLength,
        g_dev.maxBufferLength / 1073741824.0);
    out("device.recommendedMaxWorkingSetSize", "%llu (%.2f GiB)",
        (unsigned long long)g_dev.recommendedMaxWorkingSetSize,
        g_dev.recommendedMaxWorkingSetSize / 1073741824.0);
    out("device.hasUnifiedMemory", "%s", yn(g_dev.hasUnifiedMemory));
    out("device.maxThreadgroupMemoryLength", "%llu", (unsigned long long)g_dev.maxThreadgroupMemoryLength);
    out("device.supportsRaytracing", "%s", yn(g_dev.supportsRaytracing));
    out("device.maxArgumentBufferSamplerCount", "%llu", (unsigned long long)g_dev.maxArgumentBufferSamplerCount);
    out("device.supportsShaderBarycentricCoordinates", "%s", yn(g_dev.supportsShaderBarycentricCoordinates));
    out("device.supports32BitFloatFiltering", "%s", yn(g_dev.supports32BitFloatFiltering));
    out("device.supportsBCTextureCompression", "%s", yn(g_dev.supportsBCTextureCompression));
    out("device.readWriteTextureSupport", "tier%d", (int)g_dev.readWriteTextureSupport + 1);
    out("device.sparseTileSizeInBytes", "%llu", (unsigned long long)g_dev.sparseTileSizeInBytes);
    out("device.supportsQueryTextureLOD", "%s", yn(g_dev.supportsQueryTextureLOD));
    out("device.supportsFunctionPointers", "%s", yn(g_dev.supportsFunctionPointers));
    out("device.supportsFunctionPointersFromRender", "%s", yn(g_dev.supportsFunctionPointersFromRender));
    out("device.supportsRaytracingFromRender", "%s", yn(g_dev.supportsRaytracingFromRender));
}

static void item3_metal4() {
    if (@available(macOS 26.0, *)) {
        if (![g_dev respondsToSelector:@selector(newMTL4CommandQueue)]) {
            out("metal4.queue", "api missing on device object");
            return;
        }
        double t0 = now_ms();
        id<MTL4CommandQueue> q4 = [g_dev newMTL4CommandQueue];
        out("metal4.newMTL4CommandQueue", "%s", q4 ? "ok" : "nil");
        if (!q4) return;
        id<MTL4CommandAllocator> alloc = [g_dev newCommandAllocator];
        id<MTL4CommandBuffer> cb = [g_dev newCommandBuffer];
        out("metal4.allocator_and_commandbuffer", "%s", (alloc && cb) ? "ok" : "nil");
        if (!alloc || !cb) return;

        MTL4ArgumentTableDescriptor* atd = [MTL4ArgumentTableDescriptor new];
        atd.maxBufferBindCount = 4;
        NSError* err = nil;
        id<MTL4ArgumentTable> table = [g_dev newArgumentTableWithDescriptor:atd error:&err];
        if (!table) {
            out("metal4.dispatch", "fail: argument table: %s", errstr(err).c_str());
            return;
        }
        uint32_t* p = nullptr;
        id<MTLBuffer> buf = [g_dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
        p = (uint32_t*)buf.contents;
        memset(p, 0, 4096);
        p[0] = 21;
        MTLResidencySetDescriptor* rd = [MTLResidencySetDescriptor new];
        id<MTLResidencySet> rs = [g_dev newResidencySetWithDescriptor:rd error:&err];
        [rs addAllocation:buf];
        [rs commit];
        [rs requestResidency];
        [q4 addResidencySet:rs];

        [table setAddress:buf.gpuAddress atIndex:0];
        [cb beginCommandBufferWithAllocator:alloc];
        id<MTL4ComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:g_psoRW];
        [enc setArgumentTable:table];
        [enc dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [enc endEncoding];
        [cb endCommandBuffer];

        id<MTLSharedEvent> ev = [g_dev newSharedEvent];
        id<MTL4CommandBuffer> cbs[1] = {cb};
        [q4 commit:cbs count:1];
        [q4 signalEvent:ev value:1];
        BOOL signaled = [ev waitUntilSignaledValue:1 timeoutMS:5000];
        double t1 = now_ms();
        bool good = signaled && p[256] == 43;
        out("metal4.dispatch", "%s (signaled=%s result=%u expected=43) time=%.2f ms (incl. queue creation)",
            good ? "ok" : "fail", yn(signaled), p[256], t1 - t0);
        // second round trip, warm
        [alloc reset];
        p[0] = 5;
        double t2 = now_ms();
        [cb beginCommandBufferWithAllocator:alloc];
        enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:g_psoRW];
        [enc setArgumentTable:table];
        [enc dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [enc endEncoding];
        [cb endCommandBuffer];
        [q4 commit:cbs count:1];
        [q4 signalEvent:ev value:2];
        signaled = [ev waitUntilSignaledValue:2 timeoutMS:5000];
        out("metal4.dispatch_warm", "%s result=%u expected=11 time=%.2f ms",
            (signaled && p[256] == 11) ? "ok" : "fail", p[256], now_ms() - t2);
    } else {
        out("metal4.queue", "not available (macOS < 26)");
    }
}

static void item4_residency() {
    if (@available(macOS 15.0, *)) {
        NSError* err = nil;
        MTLResidencySetDescriptor* rd = [MTLResidencySetDescriptor new];
        rd.initialCapacity = 4;
        id<MTLResidencySet> rs = [g_dev newResidencySetWithDescriptor:rd error:&err];
        if (!rs) {
            out("residency.create", "fail: %s", errstr(err).c_str());
            return;
        }
        id<MTLBuffer> buf = [g_dev newBufferWithLength:65536 options:MTLResourceStorageModeShared];
        [rs addAllocation:buf];
        [rs commit];
        [rs requestResidency];
        id<MTLCommandQueue> q = [g_dev newCommandQueue];
        [q addResidencySet:rs];
        out("residency.create_add_commit_queue", "ok (allocations=%llu allocatedSize=%llu)",
            (unsigned long long)rs.allocationCount, (unsigned long long)rs.allocatedSize);
    } else {
        out("residency.create", "not available (macOS < 15)");
    }
}

// Runs the rw kernel on a no-copy buffer and checks coherence.
static void nocopy_case(const char* key, void* ptr, size_t len) {
    @try {
        @autoreleasepool {
            uint32_t* p = (uint32_t*)ptr;
            p[0] = 0x1234;
            p[256] = 0;
            id<MTLBuffer> b = [g_dev newBufferWithBytesNoCopy:ptr
                                                       length:len
                                                      options:MTLResourceStorageModeShared
                                                  deallocator:nil];
            if (!b) {
                out(key, "newBufferWithBytesNoCopy=nil (ptr=%p len=%zu ptr%%16K=%zu)", ptr, len,
                    (size_t)((uintptr_t)ptr % 16384));
                return;
            }
            std::string err;
            res_update(b, true);
            bool ran = run_classic(g_queue, g_psoRW, b, nullptr, 0, err);
            bool good = ran && p[256] == 0x1234 * 2 + 1;
            out(key, "buffer=ok gpuAddress=0x%llx length=%llu coherence=%s%s%s (ptr=%p ptr%%16K=%zu len=%zu)",
                (unsigned long long)b.gpuAddress, (unsigned long long)b.length, good ? "ok" : "fail",
                ran ? "" : " cb-error:", ran ? "" : err.c_str(), ptr, (size_t)((uintptr_t)ptr % 16384), len);
            res_update(b, false);
        }
    } @catch (NSException* ex) {
        out(key, "exception %s: %s", [[ex name] UTF8String], [[ex reason] UTF8String]);
    }
}

static void item5_nocopy() {
    void* base = nullptr;
    posix_memalign(&base, 16384, 65536);
    memset(base, 0, 65536);
    nocopy_case("nocopy.a_4K_not16K", (char*)base + 4096, 8192);

    void* base2 = nullptr;
    posix_memalign(&base2, 16384, 65536);
    memset(base2, 0, 65536);
    nocopy_case("nocopy.b_16K_len16K", base2, 32768);

    size_t mlen = 1 << 20;
    void* m = mmap(nullptr, mlen, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (m == MAP_FAILED) {
        out("nocopy.c_mmap", "mmap failed errno=%d", errno);
    } else {
        out("nocopy.c_mmap_alignment", "ptr=%p ptr%%16K=%zu ptr%%4K=%zu", m, (size_t)((uintptr_t)m % 16384),
            (size_t)((uintptr_t)m % 4096));
        nocopy_case("nocopy.c_mmap_1MiB", m, mlen);
        // a second one at a 4K-but-not-16K offset inside the mapping, if mmap gave 16K alignment
        nocopy_case("nocopy.c_mmap_plus4K", (char*)m + 4096, mlen - 16384);
    }

    void* base3 = nullptr;
    posix_memalign(&base3, 16384, 65536);
    memset(base3, 0, 65536);
    nocopy_case("nocopy.d_16K_len20K", base3, 16384 + 4096);
    // extra: what the requirement really is (len not a multiple of 4K, pointer not page aligned)
    nocopy_case("nocopy.e_16K_len_not_multiple_of_4K", base3, 20000);
    nocopy_case("nocopy.f_ptr_plus16_not_page_aligned", (char*)base3 + 16, 8192);
}

static void item6_maxsize() {
    size_t sizes[] = {(size_t)4 << 30, (size_t)8 << 30, (size_t)16 << 30};
    const char* names[] = {"4GiB", "8GiB", "16GiB"};
    for (int i = 0; i < 3; ++i) {
        char key[64];
        snprintf(key, sizeof(key), "maxsize.nocopy_%s", names[i]);
        @try {
            @autoreleasepool {
                void* m = mmap(nullptr, sizes[i], PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
                if (m == MAP_FAILED) {
                    out(key, "mmap failed errno=%d", errno);
                    continue;
                }
                double t0 = now_ms();
                id<MTLBuffer> b = [g_dev newBufferWithBytesNoCopy:m
                                                           length:sizes[i]
                                                          options:MTLResourceStorageModeShared
                                                      deallocator:nil];
                double t1 = now_ms();
                if (b) {
                    out(key, "buffer=ok gpuAddress=0x%llx length=%llu (ptr=%p) time=%.2f ms",
                        (unsigned long long)b.gpuAddress, (unsigned long long)b.length, m, t1 - t0);
                    // GPU access at the far end of the buffer
                    uint32_t* p = (uint32_t*)m;
                    p[0] = 7;
                    std::string err;
                    bool ran = run_classic(g_queue, g_psoRW, b, nullptr, 0, err);
                    out(key, "  gpu access: %s (result=%u expected=15%s%s)",
                        (ran && p[256] == 15) ? "ok" : "fail", p[256], ran ? "" : " cb-error:", err.c_str());
                    b = nil;
                } else {
                    out(key, "nil (ptr=%p) time=%.2f ms", m, t1 - t0);
                }
                munmap(m, sizes[i]);
            }
        } @catch (NSException* ex) {
            out(key, "exception %s", [[ex reason] UTF8String]);
        }
    }
}

static void item7_gpuaddress() {
    // Residency set only (queue g_queue carries g_resSet, buffer is in the set; no useResource,
    // the buffer is not bound to the encoder at all).
    NSError* err = nil;
    uint32_t* p = nullptr;
    id<MTLBuffer> buf = [g_dev newBufferWithLength:65536 options:MTLResourceStorageModeShared];
    p = (uint32_t*)buf.contents;
    memset(p, 0, 65536);
    p[0] = 0x55;
    res_update(buf, true);
    uint64_t addr = buf.gpuAddress;
    std::string e;
    bool ran = run_classic(g_queue, g_psoAddr, nil, &addr, sizeof(addr), e);
    out("gpuaddress.residency_set_only", "%s (cb=%s%s%s result=0x%x expected=0x%x gpuAddress=0x%llx)",
        (ran && p[1] == 0x55 + 0xBEEF0000u) ? "write landed" : "write did NOT land", ran ? "ok" : "error ",
        e.c_str(), "", p[1], 0x55 + 0xBEEF0000u, (unsigned long long)addr);
    res_update(buf, false);

    // Control: a queue with no residency set, buffer not bound, no useResource.
    id<MTLCommandQueue> q2 = [g_dev newCommandQueue];
    id<MTLBuffer> buf2 = [g_dev newBufferWithLength:65536 options:MTLResourceStorageModeShared];
    uint32_t* p2 = (uint32_t*)buf2.contents;
    memset(p2, 0, 65536);
    p2[0] = 0x66;
    uint64_t addr2 = buf2.gpuAddress;
    e.clear();
    ran = run_classic(q2, g_psoAddr, nil, &addr2, sizeof(addr2), e);
    out("gpuaddress.control_no_residency_no_useResource", "%s (cb=%s %s result=0x%x)",
        (ran && p2[1] == 0x66 + 0xBEEF0000u) ? "write landed" : "write did NOT land", ran ? "ok" : "error",
        e.c_str(), p2[1]);
    (void)err;
}

static void item8_metalfx() {
    bool tsupp = [MTLFXTemporalScalerDescriptor supportsDevice:g_dev];
    out("metalfx.temporal.supportsDevice", "%s", yn(tsupp));
    id<MTLFXTemporalScaler> scaler = nil;
    MTLPixelFormat depthFmts[] = {MTLPixelFormatDepth32Float, MTLPixelFormatR32Float};
    const char* depthNames[] = {"Depth32Float", "R32Float"};
    for (int i = 0; i < 2; ++i) {
        MTLFXTemporalScalerDescriptor* d = [MTLFXTemporalScalerDescriptor new];
        d.colorTextureFormat = MTLPixelFormatRGBA16Float;
        d.depthTextureFormat = depthFmts[i];
        d.motionTextureFormat = MTLPixelFormatRG16Float;
        d.outputTextureFormat = MTLPixelFormatRGBA16Float;
        d.inputWidth = 960;
        d.inputHeight = 540;
        d.outputWidth = 1920;
        d.outputHeight = 1080;
        double t0 = now_ms();
        id<MTLFXTemporalScaler> s = [d newTemporalScalerWithDevice:g_dev];
        char key[96];
        snprintf(key, sizeof(key), "metalfx.temporal.create_960x540_to_1920x1080_%s", depthNames[i]);
        out(key, "%s (%.1f ms)", s ? "ok" : "fail", now_ms() - t0);
        if (s && !scaler) scaler = s;
    }
    if (scaler) {
        out("metalfx.temporal.usage", "color=0x%lx depth=0x%lx motion=0x%lx output=0x%lx",
            (unsigned long)scaler.colorTextureUsage, (unsigned long)scaler.depthTextureUsage,
            (unsigned long)scaler.motionTextureUsage, (unsigned long)scaler.outputTextureUsage);
    }
    if (@available(macOS 14.0, *)) {
        out("metalfx.temporal.supportedInputContentScale", "min=%.3f max=%.3f",
            [MTLFXTemporalScalerDescriptor supportedInputContentMinScaleForDevice:g_dev],
            [MTLFXTemporalScalerDescriptor supportedInputContentMaxScaleForDevice:g_dev]);
    }
    if (@available(macOS 26.0, *)) {
        out("metalfx.temporal.supportsMetal4FX", "%s", yn([MTLFXTemporalScalerDescriptor supportsMetal4FX:g_dev]));
    }

    Class fiDesc = NSClassFromString(@"MTLFXFrameInterpolatorDescriptor");
    out("metalfx.frameinterpolator.class", "%s", fiDesc ? "present" : "absent");
    if (fiDesc) {
        if (@available(macOS 26.0, *)) {
            out("metalfx.frameinterpolator.supportsDevice", "%s",
                yn([MTLFXFrameInterpolatorDescriptor supportsDevice:g_dev]));
            out("metalfx.frameinterpolator.supportsMetal4FX", "%s",
                yn([MTLFXFrameInterpolatorDescriptor supportsMetal4FX:g_dev]));
            // The interpolator needs a frame-interpolatable scaler, created at the output size.
            MTLFXTemporalScalerDescriptor* sd = [MTLFXTemporalScalerDescriptor new];
            sd.colorTextureFormat = MTLPixelFormatRGBA16Float;
            sd.depthTextureFormat = MTLPixelFormatDepth32Float;
            sd.motionTextureFormat = MTLPixelFormatRG16Float;
            sd.outputTextureFormat = MTLPixelFormatRGBA16Float;
            sd.inputWidth = 1920;
            sd.inputHeight = 1080;
            sd.outputWidth = 1920;
            sd.outputHeight = 1080;
            id<MTLFXTemporalScaler> s2 = [sd newTemporalScalerWithDevice:g_dev];
            MTLFXFrameInterpolatorDescriptor* fd = [MTLFXFrameInterpolatorDescriptor new];
            fd.colorTextureFormat = MTLPixelFormatRGBA16Float;
            fd.outputTextureFormat = MTLPixelFormatRGBA16Float;
            fd.depthTextureFormat = MTLPixelFormatDepth32Float;
            fd.motionTextureFormat = MTLPixelFormatRG16Float;
            fd.uiTextureFormat = MTLPixelFormatRGBA8Unorm;
            fd.inputWidth = 1920;
            fd.inputHeight = 1080;
            fd.outputWidth = 1920;
            fd.outputHeight = 1080;
            fd.scaler = s2;
            double t0 = now_ms();
            id<MTLFXFrameInterpolator> fi = [fd newFrameInterpolatorWithDevice:g_dev];
            out("metalfx.frameinterpolator.create_1920x1080", "%s (%.1f ms, scaler=%s)", fi ? "ok" : "fail",
                now_ms() - t0, s2 ? "ok" : "nil");
        } else {
            out("metalfx.frameinterpolator.supportsDevice", "n/a (macOS < 26)");
        }
    }
    out("metalfx.temporaldenoisedscaler.class", "%s",
        NSClassFromString(@"MTLFXTemporalDenoisedScalerDescriptor") ? "present" : "absent");
}

static void item9_parallel() {
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:64
                                                                                 height:64
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> tex = [g_dev newTextureWithDescriptor:td];

    NSString* src = @"#include <metal_stdlib>\nusing namespace metal;\n"
                     "vertex float4 vs(uint v [[vertex_id]]) { float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};"
                     " return float4(p[v], 0, 1); }\n"
                     "fragment float4 fs(constant float4& c [[buffer(0)]]) { return c; }\n";
    NSError* err = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:src options:nil error:&err];
    if (!lib) {
        out("parallel_render.encoder", "fail: library: %s", errstr(err).c_str());
        return;
    }
    MTLRenderPipelineDescriptor* rpd = [MTLRenderPipelineDescriptor new];
    rpd.vertexFunction = [lib newFunctionWithName:@"vs"];
    rpd.fragmentFunction = [lib newFunctionWithName:@"fs"];
    rpd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> pso = [g_dev newRenderPipelineStateWithDescriptor:rpd error:&err];
    if (!pso) {
        out("parallel_render.encoder", "fail: pipeline: %s", errstr(err).c_str());
        return;
    }
    MTLRenderPassDescriptor* pd = [MTLRenderPassDescriptor renderPassDescriptor];
    pd.colorAttachments[0].texture = tex;
    pd.colorAttachments[0].loadAction = MTLLoadActionClear;
    pd.colorAttachments[0].storeAction = MTLStoreActionStore;
    pd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 1, 1);

    id<MTLCommandBuffer> cb = [g_queue commandBuffer];
    id<MTLParallelRenderCommandEncoder> pre = [cb parallelRenderCommandEncoderWithDescriptor:pd];
    if (!pre) {
        out("parallel_render.encoder", "fail: nil encoder");
        return;
    }
    id<MTLRenderCommandEncoder> sub[2];
    sub[0] = [pre renderCommandEncoder];
    sub[1] = [pre renderCommandEncoder];
    std::thread th[2];
    for (int i = 0; i < 2; ++i) {
        th[i] = std::thread([&, i]() {
            @autoreleasepool {
                id<MTLRenderCommandEncoder> e = sub[i];
                [e setRenderPipelineState:pso];
                MTLScissorRect sr = {(NSUInteger)(i * 32), 0, 32, 64};
                [e setScissorRect:sr];
                float c[4] = {i == 0 ? 1.f : 0.f, i == 0 ? 0.f : 1.f, 0.f, 1.f};
                [e setFragmentBytes:c length:sizeof(c) atIndex:0];
                [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [e endEncoding];
            }
        });
    }
    th[0].join();
    th[1].join();
    [pre endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    uint32_t l = 0, r = 0;
    [tex getBytes:&l bytesPerRow:256 fromRegion:MTLRegionMake2D(16, 32, 1, 1) mipmapLevel:0];
    [tex getBytes:&r bytesPerRow:256 fromRegion:MTLRegionMake2D(48, 32, 1, 1) mipmapLevel:0];
    bool good = cb.status == MTLCommandBufferStatusCompleted && l == 0xFF0000FFu && r == 0xFF00FF00u;
    out("parallel_render.encoder", "%s (cb status=%d, left=0x%08x expected 0xff0000ff, right=0x%08x expected 0xff00ff00)",
        good ? "ok" : "fail", (int)cb.status, l, r);
}

static NSString* gen_fragment_source(int seed) {
    NSMutableString* s = [NSMutableString string];
    [s appendString:@"#include <metal_stdlib>\nusing namespace metal;\n"
                     "struct V { float4 pos [[position]]; float2 uv; float4 col; };\n"
                     "vertex V vs(uint v [[vertex_id]]) { V o; float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};\n"
                     "  o.pos = float4(p[v], 0, 1); o.uv = p[v] * 0.5 + 0.5; o.col = float4(1); return o; }\n"
                     "fragment float4 fs(V in [[stage_in]], constant float4* cb [[buffer(0)]],\n"
                     "                   texture2d<float> t0 [[texture(0)]], texture2d<float> t1 [[texture(1)]],\n"
                     "                   sampler s0 [[sampler(0)]]) {\n"
                     "  float4 a = t0.sample(s0, in.uv);\n  float4 b = t1.sample(s0, in.uv * 2.0);\n  float4 acc = a * b;\n"];
    for (int i = 0; i < 190; ++i) {
        float k1 = 0.01f * (float)(seed * 7 + i) + 0.37f;
        float k2 = 0.003f * (float)(seed * 13 + i * 3) + 1.1f;
        switch (i % 5) {
            case 0:
                [s appendFormat:@"  acc = acc * %f + sin(acc.yzwx * %f) * cb[%d].xyzw;\n", k1, k2, i % 16];
                break;
            case 1:
                [s appendFormat:@"  if (acc.x > %f) { acc.xyz = normalize(acc.xyz + b.xyz * %f); } else { acc.w = fma(acc.w, %f, a.w); }\n",
                                k1, k2, k2];
                break;
            case 2:
                [s appendFormat:@"  acc = mix(acc, t0.sample(s0, in.uv + acc.xy * %f), clamp(acc.w, 0.0, 1.0));\n", k1 * 0.1f];
                break;
            case 3:
                [s appendFormat:@"  acc.xyz = pow(abs(acc.xyz) + %f, float3(%f)) + dot(acc.xyz, a.xyz) * %f;\n", k1, k2, k1];
                break;
            default:
                [s appendFormat:@"  for (int j = 0; j < 4; ++j) { acc += cb[(j + %d) & 15] * %f * float(j); }\n", i, k1];
                break;
        }
    }
    [s appendString:@"  return acc;\n}\n"];
    return s;
}

static void item10_compile() {
    double libMs[5], psoMs[5];
    for (int i = 0; i < 5; ++i) {
        @autoreleasepool {
            // Salted per run: Metal caches identical sources on disk (a rerun would measure the cache).
            NSString* src = gen_fragment_source(i + 1 + (int)(time(nullptr) % 100000) * 8);
            if (i == 0) {
                size_t lines = 0;
                for (NSUInteger c = 0; c < src.length; ++c)
                    if ([src characterAtIndex:c] == '\n') ++lines;
                out("compile.source_lines", "%zu", lines);
            }
            NSError* err = nil;
            double t0 = now_ms();
            id<MTLLibrary> lib = [g_dev newLibraryWithSource:src options:nil error:&err];
            double t1 = now_ms();
            libMs[i] = t1 - t0;
            if (!lib) {
                out("compile.library", "fail: %s", errstr(err).c_str());
                return;
            }
            MTLRenderPipelineDescriptor* rpd = [MTLRenderPipelineDescriptor new];
            rpd.vertexFunction = [lib newFunctionWithName:@"vs"];
            rpd.fragmentFunction = [lib newFunctionWithName:@"fs"];
            rpd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
            double t2 = now_ms();
            id<MTLRenderPipelineState> pso = [g_dev newRenderPipelineStateWithDescriptor:rpd error:&err];
            psoMs[i] = now_ms() - t2;
            if (!pso) {
                out("compile.pipeline", "fail: %s", errstr(err).c_str());
                return;
            }
        }
    }
    double sl = 0, sp = 0;
    for (int i = 0; i < 5; ++i) {
        sl += libMs[i];
        sp += psoMs[i];
    }
    out("compile.library_ms", "mean=%.1f first=%.1f (runs: %.1f %.1f %.1f %.1f %.1f)", sl / 5, libMs[0], libMs[0],
        libMs[1], libMs[2], libMs[3], libMs[4]);
    out("compile.render_pipeline_ms", "mean=%.1f first=%.1f (runs: %.1f %.1f %.1f %.1f %.1f)", sp / 5, psoMs[0],
        psoMs[0], psoMs[1], psoMs[2], psoMs[3], psoMs[4]);
}

static void item11_binaryarchive() {
    NSError* err = nil;
    MTLBinaryArchiveDescriptor* bd = [MTLBinaryArchiveDescriptor new];
    id<MTLBinaryArchive> ar = [g_dev newBinaryArchiveWithDescriptor:bd error:&err];
    if (!ar) {
        out("binaryarchive.create", "fail: %s", errstr(err).c_str());
        return;
    }
    MTLComputePipelineDescriptor* cd = [MTLComputePipelineDescriptor new];
    cd.computeFunction = [g_kernLib newFunctionWithName:@"rw"];
    BOOL added = [ar addComputePipelineFunctionsWithDescriptor:cd error:&err];
    out("binaryarchive.addComputePipelineFunctions", "%s%s%s", added ? "ok" : "fail: ",
        added ? "" : errstr(err).c_str(), "");
    NSURL* url = [NSURL fileURLWithPath:[g_scratch stringByAppendingPathComponent:@"probe.metalar"]];
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
    err = nil;
    BOOL ser = [ar serializeToURL:url error:&err];
    NSDictionary* attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:nil];
    out("binaryarchive.serializeToURL", "%s (size=%llu bytes)%s%s", ser ? "ok" : "fail: ",
        (unsigned long long)[attrs fileSize], ser ? "" : " ", ser ? "" : errstr(err).c_str());
}

static void item12_counters() {
    NSArray<id<MTLCounterSet>>* sets = g_dev.counterSets;
    std::string names;
    for (id<MTLCounterSet> cs in sets) {
        if (!names.empty()) names += ", ";
        names += [cs.name UTF8String];
        names += " [";
        bool first = true;
        for (id<MTLCounter> c in cs.counters) {
            if (!first) names += ",";
            names += [c.name UTF8String];
            first = false;
        }
        names += "]";
    }
    out("counters.counterSets", "%lu: %s", (unsigned long)sets.count, names.c_str());
    struct P { const char* n; MTLCounterSamplingPoint p; } pts[] = {
        {"AtStageBoundary", MTLCounterSamplingPointAtStageBoundary},
        {"AtDrawBoundary", MTLCounterSamplingPointAtDrawBoundary},
        {"AtDispatchBoundary", MTLCounterSamplingPointAtDispatchBoundary},
        {"AtBlitBoundary", MTLCounterSamplingPointAtBlitBoundary},
        {"AtTileDispatchBoundary", MTLCounterSamplingPointAtTileDispatchBoundary},
    };
    for (auto& p : pts) {
        char key[64];
        snprintf(key, sizeof(key), "counters.supportsCounterSampling.%s", p.n);
        out(key, "%s", yn([g_dev supportsCounterSampling:p.p]));
    }
}

int main(int argc, char** argv) {
    @autoreleasepool {
        double tStart = now_ms();
        g_scratch = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : NSTemporaryDirectory();

        ITEM("process", item1_process(););
        g_dev = MTLCreateSystemDefaultDevice();
        if (!g_dev) {
            out("device.name", "MTLCreateSystemDefaultDevice returned nil");
            return 1;
        }
        g_queue = [g_dev newCommandQueue];
        ITEM("setup", {
            NSError* err = nil;
            g_kernLib = [g_dev newLibraryWithSource:[NSString stringWithUTF8String:kKernels] options:nil error:&err];
            if (!g_kernLib) {
                out("setup.kernels", "fail: %s", errstr(err).c_str());
            } else {
                g_psoRW = [g_dev newComputePipelineStateWithFunction:[g_kernLib newFunctionWithName:@"rw"] error:&err];
                g_psoAddr = [g_dev newComputePipelineStateWithFunction:[g_kernLib newFunctionWithName:@"addr_write"]
                                                                 error:&err];
            }
            if (@available(macOS 15.0, *)) {
                MTLResidencySetDescriptor* rd = [MTLResidencySetDescriptor new];
                g_resSet = [g_dev newResidencySetWithDescriptor:rd error:&err];
                [g_queue addResidencySet:g_resSet];
            }
        });
        ITEM("device", item2_device(););
        ITEM("metal4", item3_metal4(););
        ITEM("residency", item4_residency(););
        ITEM("nocopy", item5_nocopy(););
        ITEM("maxsize", item6_maxsize(););
        ITEM("gpuaddress", item7_gpuaddress(););
        ITEM("metalfx", item8_metalfx(););
        ITEM("parallel_render", item9_parallel(););
        ITEM("compile", item10_compile(););
        ITEM("binaryarchive", item11_binaryarchive(););
        ITEM("counters", item12_counters(););
        out("total_runtime", "%.0f ms", now_ms() - tStart);
    }
    return 0;
}
