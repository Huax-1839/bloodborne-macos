// SPDX-License-Identifier: GPL-2.0-or-later
//
// metal_submit_probe: what makes Metal command buffer submission expensive in an x86-64 process
// under Rosetta 2 (plan P6.1). Submits N command buffers as fast as the GPU completes them
// (<= 3 in flight), each with E small encoders, and reports per variant: wall time per command
// buffer, process CPU time per command buffer (all threads: the submission runs on a Metal worker
// thread), the CPU of the four busiest threads, and the mean commit -> scheduled, GPU start, GPU end latency.
// Each variant starts from a fresh command queue and fresh residency sets; the memory is freed
// after it. Variants mirror the game's setup (mtl_device.mm, mtl_guest_memory.mm, mtl_scheduler.mm).
//
// Build (x86-64, the game's environment):
//   clang++ -arch x86_64 -std=c++20 -fobjc-arc -O1 -mmacosx-version-min=15.0 \
//     tools/metal_submit_probe.mm -framework Metal -framework Foundation \
//     -o <scratch>/metal_submit_probe
// Native comparison: -arch arm64, run without arch.
// Run: arch -x86_64 <scratch>/metal_submit_probe [reps=2] [command-buffers=2000] [name-filter]
//   (the filter is a substring of the variant names printed in the first column)

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <fcntl.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

std::atomic<uint64_t> g_handled{0};

enum class Kind { Compute, Render, Blit, Mix };
enum class Residency { None, Queue, PerCommandBuffer, RequestOnly, QueueAndRequest };
enum class Backing { Anon, Shm };
enum class CbMode { Descriptor, Unretained, Plain }; // commandBufferWithDescriptor / ...WithUnretainedReferences / commandBuffer
enum class Bytes { None, SetBytes, Ring };           // per-draw constants: setBytes or a ring buffer (needs `draws`)
enum class GuestUse { None, Bind, Address };         // guest buffers: setBuffer, or only by gpuAddress via setBytes

struct Config {
    const char* name;
    // Residency set content.
    Residency residency = Residency::None;
    unsigned guest_mib = 0;      // no-copy buffers over mapped memory (or regular, see below)
    bool regular = false;        // guest_mib as one regular newBufferWithLength buffer
    Backing backing = Backing::Anon;
    unsigned piece_mib = 256;    // 0: as large as maxBufferLength allows
    bool touch = false;
    unsigned small_buffers = 0;  // 64 KiB shared buffers in the set
    bool churn = false;          // per command buffer: add one buffer, remove an old one, commit
    unsigned churn_n = 1;        // buffers created (and freed after 6 command buffers) per command buffer
    unsigned churn_kib = 64;     // their size
    bool churn_in_set = true;    // add them to / remove them from the residency set
    bool churn_heap = false;     // allocate them from one MTLHeap that sits in the set (set never changes)
    bool churn_commit_each = false; // [set commit] after every add/remove (as AddResident does) instead of once per cb
    // Command buffers.
    unsigned encoders = 1;
    Kind kind = Kind::Compute;
    unsigned textures = 0;       // hazard-tracked textures bound per encoder
    bool fences = false;         // MTLFence ring between encoders
    bool signal = false;         // encodeSignalEvent on a shared event
    bool handler = false;        // addCompletedHandler
    bool encoder_status = false; // errorOptions = EncoderExecutionStatus
    unsigned bind_guest = 0;     // guest buffers bound per encoder
    bool guest_untracked = false;
    bool guest_access = false;   // the kernel reads the bound guest buffers (8)
    bool guest_write = false;    // and writes the first one
    unsigned guest_distinct = 8; // distinct guest buffers among the 8 bound
    unsigned tex_pool = 0;       // textures to rotate through (0: the first `textures` every time)
    unsigned draws = 0;          // draws per render encoder (one setFragmentBuffer each)
    unsigned idle_textures = 0;  // textures that stay alive but are not used
    unsigned idle_buffers = 0;   // 1 MiB buffers that stay alive but are not used
    unsigned inflight = 3;       // command buffers in flight
    CbMode cb_mode = CbMode::Descriptor;
    Bytes bytes = Bytes::None;
    GuestUse guest_use = GuestUse::None; // with `bind_guest` buffers (render: vertex stage)
    unsigned sleep_us = 0;       // sleep after every commit (GPU idle gaps)
    bool cb_pool = false;        // @autoreleasepool around encoding + commit of each command buffer
    unsigned queue_max = 0;      // newCommandQueueWithMaxCommandBufferCount (0: newCommandQueue)
    bool heap = false;           // textures from one MTLHeap
    bool spin = false;           // poll the status instead of waitUntilCompleted (keeps the core awake)
    unsigned heavy = 0;          // loop count of a busy compute dispatch per command buffer
};

struct Result {
    double wall_us, cpu_us, sys_us, commit_us, build_us, sched_ms, start_ms, end_ms, top_us;
    std::string top_name;
};

double Now() {
    static mach_timebase_info_data_t tb = [] {
        mach_timebase_info_data_t t;
        mach_timebase_info(&t);
        return t;
    }();
    return static_cast<double>(mach_absolute_time()) * tb.numer / tb.denom * 1e-9;
}

double Seconds(time_value_t t) {
    return t.seconds + t.microseconds * 1e-6;
}

struct ThreadTimes {
    std::vector<std::pair<mach_port_t, double>> cpu;
    std::vector<std::pair<mach_port_t, std::string>> names;
};

ThreadTimes SampleThreads() {
    ThreadTimes out;
    thread_act_array_t threads;
    mach_msg_type_number_t count;
    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) {
        return out;
    }
    for (mach_msg_type_number_t i = 0; i < count; ++i) {
        thread_basic_info_data_t info;
        mach_msg_type_number_t n = THREAD_BASIC_INFO_COUNT;
        if (thread_info(threads[i], THREAD_BASIC_INFO, reinterpret_cast<thread_info_t>(&info), &n) ==
            KERN_SUCCESS) {
            out.cpu.push_back({threads[i], Seconds(info.user_time) + Seconds(info.system_time)});
        }
        char name[64] = {};
        if (pthread_t p = pthread_from_mach_thread_np(threads[i])) {
            pthread_getname_np(p, name, sizeof(name));
        }
        out.names.push_back({threads[i], name[0] ? name : "?"});
        mach_port_deallocate(mach_task_self(), threads[i]);
    }
    vm_deallocate(mach_task_self(), reinterpret_cast<vm_address_t>(threads), count * sizeof(*threads));
    return out;
}

struct Env {
    id<MTLDevice> device;
    id<MTLComputePipelineState> pipeline;
    id<MTLComputePipelineState> heavy_pipeline;
    id<MTLComputePipelineState> guest_pipeline;
    id<MTLComputePipelineState> guest_write_pipeline;
    id<MTLRenderPipelineState> render_pipeline;
    id<MTLRenderPipelineState> render_pipeline_bind;
    id<MTLRenderPipelineState> render_pipeline_addr;
    id<MTLComputePipelineState> bind4_pipeline;
    id<MTLComputePipelineState> addr_pipeline;
    NSUInteger max_buffer;
};

/// Memory the variant keeps alive.
struct Resources {
    std::vector<void*> maps;
    std::vector<size_t> map_sizes;
    NSMutableArray<id<MTLBuffer>>* guest = [NSMutableArray new];
    NSMutableArray<id<MTLBuffer>>* small = [NSMutableArray new];
    NSMutableArray<id<MTLTexture>>* textures = [NSMutableArray new];
    NSMutableArray* idle = [NSMutableArray new];
    id<MTLHeap> heap;
    id<MTLBuffer> ring;
    id<MTLResidencySet> set;
    id<MTLTexture> target;
    id<MTLBuffer> out;
    ~Resources() {
        for (size_t i = 0; i < maps.size(); ++i) {
            munmap(maps[i], map_sizes[i]);
        }
    }
};

bool MapGuest(const Env& env, const Config& cfg, Resources& res) {
    if (cfg.guest_mib == 0) {
        return true;
    }
    const size_t total = static_cast<size_t>(cfg.guest_mib) << 20;
    if (cfg.regular) {
        const size_t piece = static_cast<size_t>(cfg.piece_mib) << 20;
        for (size_t at = 0; at < total; at += piece) {
            id<MTLBuffer> b = [env.device newBufferWithLength:std::min(piece, total - at)
                                                      options:MTLResourceStorageModeShared];
            if (!b) {
                return false;
            }
            [res.guest addObject:b];
        }
        return true;
    }
    void* base;
    if (cfg.backing == Backing::Shm) {
        char path[64];
        snprintf(path, sizeof(path), "/bbsp-%d", static_cast<int>(getpid()));
        int fd = shm_open(path, O_RDWR | O_CREAT | O_EXCL, 0600);
        if (fd < 0) {
            perror("shm_open");
            return false;
        }
        shm_unlink(path);
        if (ftruncate(fd, static_cast<off_t>(total))) {
            perror("ftruncate");
            close(fd);
            return false;
        }
        base = mmap(nullptr, total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        close(fd);
    } else {
        base = mmap(nullptr, total, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    }
    if (base == MAP_FAILED) {
        perror("mmap");
        return false;
    }
    res.maps.push_back(base);
    res.map_sizes.push_back(total);
    if (cfg.touch) {
        auto* p = static_cast<volatile uint8_t*>(base);
        for (size_t i = 0; i < total; i += 16384) {
            p[i] = 1;
        }
    }
    size_t piece = cfg.piece_mib ? static_cast<size_t>(cfg.piece_mib) << 20
                                 : static_cast<size_t>(env.max_buffer) & ~size_t{16383};
    piece = std::min(piece, static_cast<size_t>(env.max_buffer) & ~size_t{16383});
    MTLResourceOptions options = MTLResourceStorageModeShared;
    if (!cfg.guest_untracked) {
        options |= MTLResourceHazardTrackingModeTracked;
    } else {
        options |= MTLResourceHazardTrackingModeUntracked;
    }
    for (size_t at = 0; at < total; at += piece) {
        const size_t n = std::min(piece, total - at);
        id<MTLBuffer> b = [env.device newBufferWithBytesNoCopy:static_cast<uint8_t*>(base) + at
                                                        length:n
                                                       options:options
                                                   deallocator:nil];
        if (!b) {
            fprintf(stderr, "no-copy buffer %zu MiB at %zu failed\n", n >> 20, at >> 20);
            return false;
        }
        [res.guest addObject:b];
    }
    return true;
}

Result RunVariant(const Env& env, const Config& cfg, unsigned ncb) {
    Result r{};
    @autoreleasepool {
        Resources res;
        if (!MapGuest(env, cfg, res)) {
            r.wall_us = -1;
            return r;
        }
        id<MTLDevice> device = env.device;
        res.out = [device newBufferWithLength:4096 options:MTLResourceStorageModeShared];
        MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                      width:64
                                                                                     height:64
                                                                                  mipmapped:NO];
        td.storageMode = MTLStorageModePrivate;
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        res.target = [device newTextureWithDescriptor:td];
        MTLTextureDescriptor* sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                      width:32
                                                                                     height:32
                                                                                  mipmapped:NO];
        sd.storageMode = MTLStorageModePrivate;
        sd.usage = MTLTextureUsageShaderRead;
        const unsigned pool = cfg.tex_pool ? cfg.tex_pool : cfg.textures;
        if (cfg.heap && pool) {
            MTLSizeAndAlign sa = [device heapTextureSizeAndAlignWithDescriptor:sd];
            MTLHeapDescriptor* hd = [MTLHeapDescriptor new];
            hd.storageMode = MTLStorageModePrivate;
            hd.hazardTrackingMode = MTLHazardTrackingModeTracked;
            const NSUInteger stride = (sa.size + sa.align - 1) / sa.align * sa.align;
            hd.size = stride * pool;
            res.heap = [device newHeapWithDescriptor:hd];
        }
        for (unsigned i = 0; i < pool; ++i) {
            [res.textures addObject:res.heap ? [res.heap newTextureWithDescriptor:sd]
                                             : [device newTextureWithDescriptor:sd]];
        }
        res.ring = [device newBufferWithLength:1 << 20 options:MTLResourceStorageModeShared];
        for (unsigned i = 0; i < cfg.idle_textures; ++i) {
            [res.idle addObject:[device newTextureWithDescriptor:sd]];
        }
        for (unsigned i = 0; i < cfg.idle_buffers; ++i) {
            [res.idle addObject:[device newBufferWithLength:1 << 20 options:MTLResourceStorageModeShared]];
        }
        for (unsigned i = 0; i < cfg.small_buffers; ++i) {
            [res.small addObject:[device newBufferWithLength:65536 options:MTLResourceStorageModeShared]];
        }

        // Fresh queue per variant.
        id<MTLCommandQueue> queue = cfg.queue_max ? [device newCommandQueueWithMaxCommandBufferCount:cfg.queue_max]
                                                  : [device newCommandQueue];
        id<MTLSharedEvent> event = [device newSharedEvent];
        std::vector<id<MTLFence>> fences;
        for (int i = 0; i < 16; ++i) {
            fences.push_back([device newFence]);
        }

        id<MTLHeap> churn_heap;
        if (cfg.churn && cfg.churn_heap) {
            MTLHeapDescriptor* hd = [MTLHeapDescriptor new];
            hd.storageMode = MTLStorageModeShared;
            hd.hazardTrackingMode = MTLHazardTrackingModeUntracked;
            hd.size = static_cast<NSUInteger>(cfg.churn_n) * 8 * cfg.churn_kib * 1024;
            churn_heap = [device newHeapWithDescriptor:hd];
        }
        const bool uses_set = cfg.residency != Residency::None;
        if (uses_set) {
            MTLResidencySetDescriptor* d = [MTLResidencySetDescriptor new];
            d.label = @"probe";
            d.initialCapacity = res.guest.count + res.small.count + 64;
            NSError* error = nil;
            res.set = [device newResidencySetWithDescriptor:d error:&error];
            if (!res.set) {
                fprintf(stderr, "residency set: %s\n", error.localizedDescription.UTF8String);
                r.wall_us = -1;
                return r;
            }
            for (id<MTLBuffer> b in res.guest) {
                [res.set addAllocation:b];
            }
            for (id<MTLBuffer> b in res.small) {
                [res.set addAllocation:b];
            }
            if (cfg.churn && cfg.churn_heap) {
                [res.set addAllocation:churn_heap];
            }
            [res.set commit];
            if (cfg.residency == Residency::Queue || cfg.residency == Residency::QueueAndRequest) {
                [queue addResidencySet:res.set];
            }
            if (cfg.residency == Residency::RequestOnly || cfg.residency == Residency::QueueAndRequest) {
                [res.set requestResidency];
            }
        }

        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = res.target;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.2, 0.3, 1.0);

        unsigned fence_counter = 0;
        unsigned tex_cursor = 0;
        NSMutableArray<id<MTLBuffer>>* draw_buffers = [NSMutableArray new];
        for (int i = 0; i < 32; ++i) {
            [draw_buffers addObject:[device newBufferWithLength:4096 options:MTLResourceStorageModeShared]];
        }
        NSMutableArray<id<MTLBuffer>>* churned = [NSMutableArray new];
        std::vector<id<MTLCommandBuffer>> cbs(ncb);
        const unsigned warmup = 50;
        std::vector<double> commit_time(ncb + warmup);
        std::vector<double> sched_time(ncb + warmup);
        double* sched = sched_time.data();
        uint64_t signal_value = 0;
        uint64_t guest_addrs[4] = {};
        for (unsigned g = 0; g < 4 && g < res.guest.count; ++g) {
            guest_addrs[g] = res.guest[g].gpuAddress;
        }
        alignas(16) uint8_t const_data[128] = {};
        NSUInteger ring_offset = 0;

        auto submit = [&](unsigned i) {
            id<MTLCommandBuffer> cb;
            if (cfg.cb_mode == CbMode::Descriptor) {
                MTLCommandBufferDescriptor* cd = [MTLCommandBufferDescriptor new];
                cd.retainedReferences = NO;
                if (cfg.encoder_status) {
                    cd.errorOptions = MTLCommandBufferErrorOptionEncoderExecutionStatus;
                }
                cb = [queue commandBufferWithDescriptor:cd];
            } else if (cfg.cb_mode == CbMode::Unretained) {
                cb = [queue commandBufferWithUnretainedReferences];
            } else {
                cb = [queue commandBuffer];
            }
            if (cfg.residency == Residency::PerCommandBuffer) {
                [cb useResidencySet:res.set];
            }
            if (cfg.heavy) {
                id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
                [enc setComputePipelineState:env.heavy_pipeline];
                [enc setBuffer:res.out offset:0 atIndex:0];
                const uint32_t iters = cfg.heavy;
                [enc setBytes:&iters length:4 atIndex:1];
                [enc dispatchThreads:MTLSizeMake(1 << 18, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
                [enc endEncoding];
            }
            for (unsigned e = 0; e < cfg.encoders; ++e) {
                Kind kind = cfg.kind;
                if (kind == Kind::Mix) {
                    kind = (e % 3 == 0) ? Kind::Render : (e % 3 == 1) ? Kind::Compute : Kind::Blit;
                }
                const bool wait_fence = cfg.fences && fence_counter > 0;
                id<MTLFence> wait = wait_fence ? fences[(fence_counter - 1) % 16] : nil;
                id<MTLFence> update = cfg.fences ? fences[fence_counter % 16] : nil;
                ++fence_counter;
                switch (kind) {
                case Kind::Compute: {
                    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
                    if (wait) {
                        [enc waitForFence:wait];
                    }
                    id<MTLComputePipelineState> ps = cfg.guest_write ? env.guest_write_pipeline
                                                     : cfg.guest_access ? env.guest_pipeline : env.pipeline;
                    if (cfg.guest_use == GuestUse::Bind) {
                        ps = env.bind4_pipeline;
                    } else if (cfg.guest_use == GuestUse::Address) {
                        ps = env.addr_pipeline;
                    }
                    [enc setComputePipelineState:ps];
                    [enc setBuffer:res.out offset:0 atIndex:0];
                    for (unsigned g = 0; g < cfg.bind_guest && g < res.guest.count; ++g) {
                        if (cfg.guest_use == GuestUse::Address) {
                            break;
                        }
                        [enc setBuffer:res.guest[g % std::min<unsigned>(cfg.guest_distinct, res.guest.count)] offset:0 atIndex:1 + g];
                    }
                    if (cfg.guest_use == GuestUse::Address) {
                        [enc setBytes:guest_addrs length:sizeof(guest_addrs) atIndex:1];
                    }
                    for (unsigned t = 0; t < cfg.textures; ++t) {
                        [enc setTexture:res.textures[(tex_cursor + t) % res.textures.count] atIndex:t];
                    }
                    tex_cursor += cfg.textures;
                    for (unsigned d = 0; d < std::max(cfg.draws, 1u); ++d) {
                        if (cfg.bytes == Bytes::SetBytes) {
                            [enc setBytes:const_data length:64 atIndex:5];
                        } else if (cfg.bytes == Bytes::Ring) {
                            [enc setBuffer:res.ring offset:(ring_offset += 256) % (1 << 20) atIndex:5];
                        }
                        [enc dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                    }
                    if (update) {
                        [enc updateFence:update];
                    }
                    [enc endEncoding];
                    break;
                }
                case Kind::Render: {
                    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
                    if (wait) {
                        [enc waitForFence:wait beforeStages:MTLRenderStageVertex];
                    }
                    for (unsigned g = 0; g < cfg.bind_guest && g < res.guest.count; ++g) {
                        if (cfg.guest_use == GuestUse::Bind) {
                            [enc setVertexBuffer:res.guest[g] offset:0 atIndex:1 + g];
                        } else if (cfg.guest_use == GuestUse::None) {
                            [enc setFragmentBuffer:res.guest[g] offset:0 atIndex:g];
                        }
                    }
                    if (cfg.guest_use == GuestUse::Address) {
                        [enc setVertexBytes:guest_addrs length:sizeof(guest_addrs) atIndex:1];
                    }
                    for (unsigned t = 0; t < cfg.textures; ++t) {
                        [enc setFragmentTexture:res.textures[(tex_cursor + t) % res.textures.count] atIndex:t];
                    }
                    tex_cursor += cfg.textures;
                    if (cfg.draws) {
                        [enc setRenderPipelineState:cfg.guest_use == GuestUse::Bind ? env.render_pipeline_bind
                                                    : cfg.guest_use == GuestUse::Address ? env.render_pipeline_addr
                                                                                         : env.render_pipeline];
                        for (unsigned d = 0; d < cfg.draws; ++d) {
                            if (cfg.bytes == Bytes::SetBytes) {
                                [enc setVertexBytes:const_data length:128 atIndex:5];
                                [enc setFragmentBytes:const_data length:64 atIndex:30];
                            } else if (cfg.bytes == Bytes::Ring) {
                                const NSUInteger off = (ring_offset += 256) % (1 << 20);
                                [enc setVertexBuffer:res.ring offset:off atIndex:5];
                                [enc setFragmentBuffer:res.ring offset:off atIndex:30];
                            } else {
                                [enc setFragmentBuffer:draw_buffers[d % 32] offset:0 atIndex:30];
                            }
                            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                        }
                    }
                    if (update) {
                        [enc updateFence:update afterStages:MTLRenderStageFragment];
                    }
                    [enc endEncoding];
                    break;
                }
                case Kind::Blit:
                case Kind::Mix: {
                    id<MTLBlitCommandEncoder> enc = [cb blitCommandEncoder];
                    if (wait) {
                        [enc waitForFence:wait];
                    }
                    [enc fillBuffer:res.out range:NSMakeRange(0, 256) value:7];
                    if (update) {
                        [enc updateFence:update];
                    }
                    [enc endEncoding];
                    break;
                }
                }
            }
            if (cfg.churn) {
                const bool in_set = cfg.churn_in_set && res.set && !cfg.churn_heap;
                for (unsigned c = 0; c < cfg.churn_n; ++c) {
                    id<MTLBuffer> b = cfg.churn_heap
                        ? [churn_heap newBufferWithLength:cfg.churn_kib * 1024
                                                  options:MTLResourceStorageModeShared |
                                                          MTLResourceHazardTrackingModeUntracked]
                        : [device newBufferWithLength:cfg.churn_kib * 1024 options:MTLResourceStorageModeShared];
                    if (in_set) {
                        [res.set addAllocation:b];
                        if (cfg.churn_commit_each) {
                            [res.set commit];
                        }
                    }
                    [churned addObject:b];
                }
                while (churned.count > 6 * cfg.churn_n) {
                    if (in_set) {
                        [res.set removeAllocation:churned[0]];
                        if (cfg.churn_commit_each) {
                            [res.set commit];
                        }
                    }
                    [churned removeObjectAtIndex:0];
                }
                if (in_set && !cfg.churn_commit_each) {
                    [res.set commit];
                }
            }
            [cb addScheduledHandler:^(id<MTLCommandBuffer>) {
                sched[i] = Now();
            }];
            if (cfg.signal) {
                [cb encodeSignalEvent:event value:++signal_value];
            }
            if (cfg.handler) {
                [cb addCompletedHandler:^(id<MTLCommandBuffer>) {
                    g_handled.fetch_add(1, std::memory_order_relaxed);
                }];
            }
            return cb;
        };

        double commit_total = 0, build_total = 0;
        rusage ru0{}, ru1{};
        ThreadTimes t0, t1;
        double wall0 = 0, wall1 = 0;
        for (unsigned i = 0; i < ncb + warmup; ++i) {
            if (i == warmup) {
                [cbs[(i - 1) % ncb] waitUntilCompleted];
                t0 = SampleThreads();
                getrusage(RUSAGE_SELF, &ru0);
                wall0 = Now();
            }
            const unsigned slot = i % ncb;
            // <= cfg.inflight in flight.
            if (i >= cfg.inflight) {
                id<MTLCommandBuffer> old = cbs[(i - cfg.inflight) % ncb];
                if (cfg.spin) {
                    while (old.status < MTLCommandBufferStatusCompleted) {
                    }
                } else {
                    [old waitUntilCompleted];
                }
            }
            double b0, b1, b2;
            id<MTLCommandBuffer> cb;
            auto record_and_commit = [&] {
                b0 = Now();
                cb = submit(i);
                b1 = Now();
                commit_time[i] = b1;
                [cb commit];
                b2 = Now();
            };
            if (cfg.cb_pool) {
                @autoreleasepool {
                    record_and_commit();
                }
            } else {
                record_and_commit();
            }
            if (cfg.sleep_us) {
                usleep(cfg.sleep_us);
            }
            if (i >= warmup) {
                build_total += b1 - b0;
                commit_total += b2 - b1;
            }
            cbs[slot] = cb;
        }
        for (unsigned i = ncb + warmup - cfg.inflight; i < ncb + warmup; ++i) {
            [cbs[i % ncb] waitUntilCompleted];
        }
        wall1 = Now();
        getrusage(RUSAGE_SELF, &ru1);
        t1 = SampleThreads();

        double start_lat = 0, end_lat = 0, sched_lat = 0;
        unsigned lat_n = 0;
        // Only the last `ncb` command buffers are still in the ring: all of the measured ones when
        // warmup < ncb (the first `warmup` slots were overwritten by the last ones).
        for (unsigned i = warmup; i < ncb + warmup; ++i) {
            id<MTLCommandBuffer> cb = cbs[i % ncb];
            const double c = commit_time[i];
            sched_lat += sched[i] - c;
            const double s = cb.GPUStartTime, e = cb.GPUEndTime;
            if (s > 0 && e > 0) {
                start_lat += s - c;
                end_lat += e - c;
                ++lat_n;
            }
        }

        auto tv = [](const timeval& t) { return t.tv_sec + t.tv_usec * 1e-6; };
        const double cpu = (tv(ru1.ru_utime) + tv(ru1.ru_stime)) - (tv(ru0.ru_utime) + tv(ru0.ru_stime));
        const double sys = tv(ru1.ru_stime) - tv(ru0.ru_stime);
        r.wall_us = (wall1 - wall0) / ncb * 1e6;
        r.cpu_us = cpu / ncb * 1e6;
        r.sys_us = sys / ncb * 1e6;
        r.commit_us = commit_total / ncb * 1e6;
        r.build_us = build_total / ncb * 1e6;
        r.sched_ms = lat_n ? sched_lat / lat_n * 1e3 : 0;
        r.start_ms = lat_n ? start_lat / lat_n * 1e3 : 0;
        r.end_ms = lat_n ? end_lat / lat_n * 1e3 : 0;
        // CPU of the busiest threads of the interval (the main thread encodes, a Metal worker
        // submits), in us per command buffer.
        std::vector<double> deltas;
        for (auto& [port, after] : t1.cpu) {
            double before = 0;
            for (auto& [p0, c0] : t0.cpu) {
                if (p0 == port) {
                    before = c0;
                }
            }
            deltas.push_back(after - before);
        }
        std::sort(deltas.rbegin(), deltas.rend());
        for (size_t i = 0; i < 4 && i < deltas.size(); ++i) {
            char buf[32];
            snprintf(buf, sizeof(buf), "%s%.0f", i ? "/" : "", deltas[i] / ncb * 1e6);
            r.top_name += buf;
        }
        r.top_us = 0;
    }
    return r;
}

const char* kKernel = R"(
#include <metal_stdlib>
using namespace metal;
kernel void k(device uint* out [[buffer(0)]], uint id [[thread_position_in_grid]]) { out[id & 63] = id; }
#define G8 device uint* g0 [[buffer(1)]], device uint* g1 [[buffer(2)]], device uint* g2 [[buffer(3)]], \
           device uint* g3 [[buffer(4)]], device uint* g4 [[buffer(5)]], device uint* g5 [[buffer(6)]], \
           device uint* g6 [[buffer(7)]], device uint* g7 [[buffer(8)]]
kernel void kg(device uint* out [[buffer(0)]], G8) {
    out[0] = g0[0] + g1[0] + g2[0] + g3[0] + g4[0] + g5[0] + g6[0] + g7[0];
}
kernel void kgw(device uint* out [[buffer(0)]], G8) {
    g0[1] = g1[0] + g2[0] + g3[0] + g4[0] + g5[0] + g6[0] + g7[0];
}
kernel void heavy(device uint* out [[buffer(0)]], constant uint& n [[buffer(1)]],
                  uint id [[thread_position_in_grid]]) {
    uint a = id;
    for (uint i = 0; i < n; ++i) a = a * 1664525u + 1013904223u;
    if (a == 12345u) out[0] = a;
}
kernel void kg4(device uint* out [[buffer(0)]], device uint* g0 [[buffer(1)]], device uint* g1 [[buffer(2)]],
                device uint* g2 [[buffer(3)]], device uint* g3 [[buffer(4)]]) {
    out[0] = g0[0] + g1[0] + g2[0] + g3[0];
}
kernel void kga(device uint* out [[buffer(0)]], constant ulong* a [[buffer(1)]]) {
    out[0] = *reinterpret_cast<device uint*>(a[0]) + *reinterpret_cast<device uint*>(a[1]) +
             *reinterpret_cast<device uint*>(a[2]) + *reinterpret_cast<device uint*>(a[3]);
}
vertex float4 vs_bind(uint v [[vertex_id]], device const uint* g0 [[buffer(1)]], device const uint* g1 [[buffer(2)]],
                      device const uint* g2 [[buffer(3)]], device const uint* g3 [[buffer(4)]]) {
    float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
    return float4(p[v], 0, 1) + float4(g0[0] + g1[0] + g2[0] + g3[0]) * 0.0;
}
vertex float4 vs_addr(uint v [[vertex_id]], constant ulong* a [[buffer(1)]]) {
    float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
    uint s = *reinterpret_cast<device uint*>(a[0]) + *reinterpret_cast<device uint*>(a[1]) +
             *reinterpret_cast<device uint*>(a[2]) + *reinterpret_cast<device uint*>(a[3]);
    return float4(p[v], 0, 1) + float4(s) * 0.0;
}
vertex float4 vs(uint v [[vertex_id]]) {
    float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
    return float4(p[v], 0, 1);
}
fragment float4 fs(constant float4* c [[buffer(30)]]) { return c[0] + 0.5; }
)";

} // namespace

int main(int argc, char** argv) {
    const int reps = argc > 1 ? atoi(argv[1]) : 2;
    const unsigned ncb = argc > 2 ? static_cast<unsigned>(atoi(argv[2])) : 2000;
    const char* filter = argc > 3 ? argv[3] : nullptr;
    Env env;
    @autoreleasepool {
        env.device = MTLCreateSystemDefaultDevice();
        if (!env.device) {
            fprintf(stderr, "no Metal device\n");
            return 1;
        }
        env.max_buffer = env.device.maxBufferLength;
        NSError* error = nil;
        id<MTLLibrary> lib = [env.device newLibraryWithSource:[NSString stringWithUTF8String:kKernel]
                                                      options:nil
                                                        error:&error];
        if (!lib) {
            fprintf(stderr, "library: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        env.pipeline = [env.device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"]
                                                                  error:&error];
        env.heavy_pipeline = [env.device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"heavy"]
                                                                       error:&error];
        env.guest_pipeline = [env.device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"kg"]
                                                                       error:&error];
        env.guest_write_pipeline = [env.device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"kgw"]
                                                                             error:&error];
        MTLRenderPipelineDescriptor* rd = [MTLRenderPipelineDescriptor new];
        rd.vertexFunction = [lib newFunctionWithName:@"vs"];
        rd.fragmentFunction = [lib newFunctionWithName:@"fs"];
        rd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        env.render_pipeline = [env.device newRenderPipelineStateWithDescriptor:rd error:&error];
        rd.vertexFunction = [lib newFunctionWithName:@"vs_bind"];
        env.render_pipeline_bind = [env.device newRenderPipelineStateWithDescriptor:rd error:&error];
        rd.vertexFunction = [lib newFunctionWithName:@"vs_addr"];
        env.render_pipeline_addr = [env.device newRenderPipelineStateWithDescriptor:rd error:&error];
        env.bind4_pipeline = [env.device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"kg4"]
                                                                       error:&error];
        env.addr_pipeline = [env.device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"kga"]
                                                                      error:&error];
        if (!env.render_pipeline || !env.render_pipeline_bind || !env.render_pipeline_addr ||
            !env.bind4_pipeline || !env.addr_pipeline) {
            fprintf(stderr, "render pipeline: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        printf("device %s, maxBufferLength %llu MiB, %u command buffers per run, %d reps\n",
               env.device.name.UTF8String, static_cast<unsigned long long>(env.max_buffer >> 20), ncb,
               reps);
    }
    using R = Residency;
    using B = Backing;
    // "Game-like": mixed encoders, textures, fences, event + handler, status.
    auto game = [](Config c) {
        c.encoders = 20;
        c.kind = Kind::Mix;
        c.textures = 50;
        c.fences = true;
        c.signal = true;
        c.handler = true;
        c.encoder_status = true;
        return c;
    };
    std::vector<Config> variants;
    auto add = [&](Config c) { variants.push_back(c); };
    // 1
    add({.name = "1 baseline E=1"});
    // 2
    add({.name = "2 resid 64MiB regular", .residency = R::Queue, .guest_mib = 64, .regular = true});
    // 3
    for (unsigned g : {1024u, 4096u, 8192u}) {
        static std::vector<std::string> names;
        names.reserve(64);
        names.push_back("3 resid queue anon " + std::to_string(g >> 10) + "GiB untouched");
        add({.name = names.back().c_str(), .residency = R::Queue, .guest_mib = g});
        names.push_back("3 resid queue anon " + std::to_string(g >> 10) + "GiB touched");
        add({.name = names.back().c_str(), .residency = R::Queue, .guest_mib = g, .touch = true});
        names.push_back("3 resid queue shm  " + std::to_string(g >> 10) + "GiB touched");
        add({.name = names.back().c_str(), .residency = R::Queue, .guest_mib = g,
             .backing = B::Shm, .touch = true});
    }
    add({.name = "3 resid queue anon 4GiB touched 1 piece", .residency = R::Queue, .guest_mib = 4096,
         .piece_mib = 0, .touch = true});
    add({.name = "3 resid queue anon 4GiB touched 16MiB pieces", .residency = R::Queue,
         .guest_mib = 4096, .piece_mib = 16, .touch = true});
    // 4
    add({.name = "4 resid per-cb 4GiB touched", .residency = R::PerCommandBuffer, .guest_mib = 4096,
         .touch = true});
    add({.name = "4 resid request-only 4GiB touched", .residency = R::RequestOnly, .guest_mib = 4096,
         .touch = true});
    add({.name = "4 resid queue+request 4GiB touched", .residency = R::QueueAndRequest,
         .guest_mib = 4096, .touch = true});
    // 5
    add({.name = "5 resid 1000 small buffers", .residency = R::Queue, .small_buffers = 1000});
    add({.name = "5 resid 4000 small buffers", .residency = R::Queue, .small_buffers = 4000});
    add({.name = "5 resid 1000 small + per-cb", .residency = R::PerCommandBuffer, .small_buffers = 1000});
    // 6
    add({.name = "6 E=20 compute", .encoders = 20});
    add({.name = "6 E=20 render", .encoders = 20, .kind = Kind::Render});
    add({.name = "6 E=20 mix", .encoders = 20, .kind = Kind::Mix});
    add({.name = "6 E=20 compute + 50 tex", .encoders = 20, .textures = 50});
    add({.name = "6 E=20 render + 50 tex", .encoders = 20, .kind = Kind::Render, .textures = 50});
    add({.name = "6 E=20 compute + fences", .encoders = 20, .fences = true});
    // 7
    add({.name = "7 E=1 signal", .signal = true});
    add({.name = "7 E=1 handler", .handler = true});
    add({.name = "7 E=1 signal+handler", .signal = true, .handler = true});
    add({.name = "7 E=20 mix signal+handler", .encoders = 20, .kind = Kind::Mix, .signal = true,
         .handler = true});
    // Our own descriptor option and per-encoder guest bindings.
    add({.name = "8 E=20 mix encoder_status", .encoders = 20, .kind = Kind::Mix, .encoder_status = true});
    add({.name = "8 E=20 compute bind 8 guest (tracked) 4GiB", .residency = R::Queue, .guest_mib = 4096,
         .touch = true, .encoders = 20, .bind_guest = 8});
    add({.name = "8 E=20 compute bind 8 guest (untracked) 4GiB", .residency = R::Queue, .guest_mib = 4096,
         .touch = true, .encoders = 20, .bind_guest = 8, .guest_untracked = true});
    add({.name = "8 E=1 resid churn (add+remove+commit per cb)", .residency = R::Queue, .churn = true});
    add({.name = "8 E=1 resid churn 4GiB touched", .residency = R::Queue, .guest_mib = 4096,
         .touch = true, .churn = true});
    // Game-like combinations.
    add(game({.name = "9 game-like no residency"}));
    add(game({.name = "9 game-like resid 4GiB shm touched + 300 small", .residency = R::Queue,
              .guest_mib = 4096, .backing = B::Shm, .touch = true, .small_buffers = 300}));
    add(game({.name = "9 game-like resid 4GiB shm touched + 300 small, no status", .residency = R::Queue,
              .guest_mib = 4096, .backing = B::Shm, .touch = true, .small_buffers = 300}));
    variants.back().encoder_status = false;

    // 10: what could scale with the resources a command buffer references or the device holds.
    add({.name = "10 E=20 compute 50 tex, pool 1000 (1000/cb distinct)", .encoders = 20, .textures = 50,
         .tex_pool = 1000});
    add({.name = "10 E=20 compute 50 tex, pool 4000 (1000/cb distinct)", .encoders = 20, .textures = 50,
         .tex_pool = 4000});
    add({.name = "10 E=20 compute 200 tex per enc, pool 4000", .encoders = 20, .textures = 100,
         .tex_pool = 4000});
    add({.name = "10 E=1 + 5000 idle textures", .idle_textures = 5000});
    add({.name = "10 E=1 + 3000 idle 1MiB buffers", .idle_buffers = 3000});
    add({.name = "10 E=20 render 50 draws each", .encoders = 20, .kind = Kind::Render, .draws = 50});
    add({.name = "10 E=20 render 50 draws, 20 tex, pool 4000", .encoders = 20, .kind = Kind::Render,
         .textures = 20, .tex_pool = 4000, .draws = 50});
    add({.name = "10 E=1 render 1000 draws", .encoders = 1, .kind = Kind::Render, .draws = 1000});

    // 12: the GPU reads/writes the guest buffers (8 bound per encoder, 256 MiB each).
    add({.name = "12 E=20 GPU reads 8 guest (tracked) 4GiB shm", .residency = R::Queue, .guest_mib = 4096,
         .backing = B::Shm, .touch = true, .encoders = 20, .bind_guest = 8, .guest_access = true});
    add({.name = "12 E=20 GPU reads 8 guest (untracked) 4GiB shm", .residency = R::Queue, .guest_mib = 4096,
         .backing = B::Shm, .touch = true, .encoders = 20, .bind_guest = 8, .guest_untracked = true,
         .guest_access = true});
    add({.name = "12 E=20 GPU writes guest0 (tracked) 4GiB shm", .residency = R::Queue, .guest_mib = 4096,
         .backing = B::Shm, .touch = true, .encoders = 20, .bind_guest = 8, .guest_access = true,
         .guest_write = true});
    add({.name = "12 E=20 same, no guest (reference)", .encoders = 20});
    for (unsigned k : {1u, 2u, 4u}) {
        static std::vector<std::string> names;
        names.reserve(16);
        names.push_back("12 E=20 GPU reads " + std::to_string(k) + " distinct guest of 8 bound, 4GiB shm");
        add({.name = names.back().c_str(), .residency = R::Queue, .guest_mib = 4096, .backing = B::Shm,
             .touch = true, .encoders = 20, .bind_guest = 8, .guest_access = true, .guest_distinct = k});
    }
    add({.name = "12 E=20 GPU reads 8 REGULAR 256MiB buffers (set)", .residency = R::Queue,
         .guest_mib = 4096, .regular = true, .encoders = 20, .bind_guest = 8, .guest_access = true});
    add({.name = "12 E=20 GPU reads 8 guest, NO residency set", .guest_mib = 4096, .backing = B::Shm,
         .touch = true, .encoders = 20, .bind_guest = 8, .guest_access = true});
    add({.name = "12 E=20 GPU reads 8 guest, 1GiB anon untouched", .residency = R::Queue, .guest_mib = 2048,
         .encoders = 20, .bind_guest = 8, .guest_access = true});
    add({.name = "12 E=1 GPU reads 8 guest, 4GiB shm", .residency = R::Queue, .guest_mib = 4096,
         .backing = B::Shm, .touch = true, .bind_guest = 8, .guest_access = true});

    add({.name = "13 E=20 GPU reads 4 distinct, main thread spins", .residency = R::Queue, .guest_mib = 4096,
         .backing = B::Shm, .touch = true, .encoders = 20, .bind_guest = 8, .guest_access = true,
         .guest_distinct = 4, .spin = true});
    add({.name = "13 E=1 heavy=2000, main thread spins", .spin = true, .heavy = 2000});
    add({.name = "13 E=1 heavy=2000", .heavy = 2000});
    // 14: wired memory churn (compare with the Metal System Trace table metal-wired-sysmem-level-interval).
    // A game-like base and one change at a time. Run one variant per process under xctrace (name filter).
    {
        Config base{.name = "14 base"};
        base.residency = R::Queue;
        base.guest_mib = 4574;
        base.piece_mib = 2287;
        base.backing = B::Shm;
        base.touch = true;
        base.encoders = 20;
        base.kind = Kind::Mix;
        base.textures = 50;
        base.fences = true;
        base.signal = true;
        base.handler = true;
        base.encoder_status = true;
        base.draws = 5;
        base.bytes = Bytes::SetBytes;
        base.bind_guest = 4;
        base.guest_use = GuestUse::Bind;
        base.inflight = 3;
        static std::vector<Config> g14;
        g14.reserve(32);
        auto v = [&](const char* name, auto&& change) {
            Config c = base;
            c.name = name;
            change(c);
            g14.push_back(c);
            add(g14.back());
        };
        v("14 base", [](Config&) {});
        v("14 cb unretained", [](Config& c) { c.cb_mode = CbMode::Unretained; });
        v("14 cb plain", [](Config& c) { c.cb_mode = CbMode::Plain; });
        v("14 cb descriptor no status", [](Config& c) { c.encoder_status = false; });
        v("14 bytes ring", [](Config& c) { c.bytes = Bytes::Ring; });
        v("14 guest by address only", [](Config& c) { c.guest_use = GuestUse::Address; });
        v("14 guest not used", [](Config& c) { c.guest_use = GuestUse::None; c.bind_guest = 0; });
        v("14 inflight 1 cb", [](Config& c) { c.inflight = 1; });
        v("14 inflight 10 cb", [](Config& c) { c.inflight = 10; });
        v("14 sleep 2ms per cb", [](Config& c) { c.sleep_us = 2000; });
        v("14 pool per cb", [](Config& c) { c.cb_pool = true; });
        v("14 queue max 64", [](Config& c) { c.queue_max = 64; });
        v("14 textures from heap", [](Config& c) { c.heap = true; });
        v("14 churn 1x128K per cb, set commit", [](Config& c) { c.churn = true; c.churn_kib = 128; });
        v("14 churn 50x128K per cb, commit each", [](Config& c) {
            c.churn = true;
            c.churn_n = 50;
            c.churn_kib = 128;
            c.churn_commit_each = true;
        });
        v("14 churn 50x128K per cb, commit once", [](Config& c) {
            c.churn = true;
            c.churn_n = 50;
            c.churn_kib = 128;
        });
        v("14 churn 50x128K per cb, not in set", [](Config& c) {
            c.churn = true;
            c.churn_n = 50;
            c.churn_kib = 128;
            c.churn_in_set = false;
        });
        v("14 churn 50x128K per cb, no residency set", [](Config& c) {
            c.churn = true;
            c.churn_n = 50;
            c.churn_kib = 128;
            c.residency = R::None;
            c.churn_in_set = false;
        });
        v("14 churn 50x128K per cb, from heap in set", [](Config& c) {
            c.churn = true;
            c.churn_n = 50;
            c.churn_kib = 128;
            c.churn_heap = true;
        });
        v("14 churn 50x128K per cb, set without guest", [](Config& c) {
            c.churn = true;
            c.churn_n = 50;
            c.churn_kib = 128;
            c.guest_mib = 0;
            c.guest_use = GuestUse::None;
            c.bind_guest = 0;
        });
        v("14 churn 5x32K per cb, commit each", [](Config& c) {
            c.churn = true;
            c.churn_n = 5;
            c.churn_kib = 32;
            c.churn_commit_each = true;
        });
        v("14 no residency set", [](Config& c) { c.residency = R::None; });
        v("14 no guest memory at all", [](Config& c) {
            c.residency = R::None;
            c.guest_mib = 0;
            c.guest_use = GuestUse::None;
            c.bind_guest = 0;
        });
    }

    // 11: a deep queue and a busy GPU, as in the game (19 command buffers per frame, ~49 ms latency).
    for (unsigned heavy : {0u, 2000u}) {
        static std::vector<std::string> names;
        names.reserve(64);
        auto n = [&](const char* what) {
            names.push_back(std::string("11 ") + what + " heavy=" + std::to_string(heavy));
            return names.back().c_str();
        };
        add({.name = n("inflight 3  E=1"), .heavy = heavy});
        add({.name = n("inflight 20 E=1"), .inflight = 20, .heavy = heavy});
        add({.name = n("inflight 60 E=1"), .inflight = 60, .heavy = heavy});
        add({.name = n("inflight 20 E=1 resid 4GiB shm"), .residency = R::Queue, .guest_mib = 4096,
             .backing = B::Shm, .touch = true, .inflight = 20, .heavy = heavy});
        add({.name = n("inflight 20 E=20 mix"), .encoders = 20, .kind = Kind::Mix, .inflight = 20,
             .heavy = heavy});
    }

    printf("%-58s %9s %9s %8s %8s %8s %9s %9s %9s  %s\n", "variant", "wall/cb", "cpu/cb", "sys/cb",
           "build", "commit", "->sched", "->start", "->end", "top-4 thread cpu us/cb");
    for (int rep = 0; rep < reps; ++rep) {
        for (const Config& cfg : variants) {
            if (filter && !strstr(cfg.name, filter)) {
                continue;
            }
            Result r = RunVariant(env, cfg, ncb);
            if (r.wall_us < 0) {
                printf("%-58s FAILED\n", cfg.name);
                continue;
            }
            printf("%-58s %9.0f %9.0f %8.0f %8.0f %8.0f %7.2fms %7.2fms %7.2fms  %s\n", cfg.name, r.wall_us,
                   r.cpu_us, r.sys_us, r.build_us, r.commit_us, r.sched_ms, r.start_ms, r.end_ms,
                   r.top_name.c_str());
            fflush(stdout);
        }
        printf("--- rep %d done\n", rep + 1);
    }
    return 0;
}
