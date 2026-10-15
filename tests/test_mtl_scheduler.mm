// SPDX-License-Identifier: GPL-2.0-or-later
// Unit test of renderer_metal/mtl_scheduler: ticks, waits, deferred and priority operations,
// the fence chain across encoders, memory barriers on device-address accesses and the error
// path. Needs a Metal device, no window or game.
//
//   mtl-scheduler-test
//
// Exit 0 when every check passed. The error path is tested with a synthetic failure: a kernel
// that never ends was not stopped by any GPU timeout on the M4 (5+ minutes), so no real
// command buffer error can be provoked reliably.
#import <Metal/Metal.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>

#include "video_core/renderer_metal/mtl_scheduler_impl.h"

// The runtime's toggle bits the scheduler reads (bbport_toggles.h); this test has no guest process.
extern "C" {
uint64_t runtime_experiment_bits = 0;
uint64_t runtime_disabled_optimizations = 0;
}

// common/assert.cpp pulls in the emulator; a failed ASSERT here just aborts.
void assert_fail_impl() {
    std::abort();
}
[[noreturn]] void unreachable_impl() {
    std::abort();
}

using Clock = std::chrono::steady_clock;
using Metal::Scheduler;

static int failures = 0;
#define CHECK(cond)                                                                                \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            std::printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                          \
            ++failures;                                                                            \
        }                                                                                          \
    } while (0)

static double MsSince(Clock::time_point t) {
    return std::chrono::duration<double, std::milli>(Clock::now() - t).count();
}

static NSString* const kernel_source = @"#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void spin(device float* out [[buffer(0)]], constant uint& n [[buffer(1)]]) {\n"
    "    float x = 1.0f;\n"
    "    for (uint i = 0; i < n; ++i) { x = x * 0.999f + sin(x); }\n"
    "    out[0] = x;\n"
    "}\n"
    "kernel void write_word(constant ulong& address [[buffer(0)]], constant uint& value [[buffer(1)]]) {\n"
    "    *reinterpret_cast<device uint*>(address) = value;\n"
    "}\n"
    "kernel void read_word(constant ulong& address [[buffer(0)]], constant ulong& index [[buffer(1)]],\n"
    "                      device uint* out [[buffer(2)]]) {\n"
    "    out[0] = reinterpret_cast<device const uint*>(address)[index];\n"
    "}\n";

struct Kernels {
    id<MTLComputePipelineState> spin, write_word, read_word;
};

static id<MTLComputePipelineState> Pipeline(id<MTLDevice> device, id<MTLLibrary> library,
                                            NSString* name) {
    NSError* error = nil;
    id<MTLComputePipelineState> pipeline = [device
        newComputePipelineStateWithFunction:[library newFunctionWithName:name]
                                      error:&error];
    if (!pipeline) {
        std::printf("pipeline %s: %s\n", name.UTF8String,
                    error ? error.localizedDescription.UTF8String : "?");
        std::exit(2);
    }
    return pipeline;
}

static void DispatchSpin(Scheduler& scheduler, const Kernels& k, id<MTLBuffer> out, uint32_t n) {
    scheduler.ComputeEncoder();
    auto& compute = scheduler.GetImpl().compute;
    [compute setComputePipelineState:k.spin];
    [compute setBuffer:out offset:0 atIndex:0];
    [compute setBytes:&n length:4 atIndex:1];
    [compute dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
}

static void TestTicks(Metal::Device& device, const Kernels& k) {
    std::printf("ticks\n");
    Scheduler scheduler{device, "test-ticks"};
    CHECK(scheduler.CurrentTick() == 1);
    CHECK(scheduler.IsFree(0));
    CHECK(!scheduler.IsFreeKnown(1));
    scheduler.Flush(); // nothing recorded: the tick still advances (and is done at once)
    CHECK(scheduler.CurrentTick() == 2);
    CHECK(scheduler.IsFree(1));

    id<MTLBuffer> out = [device.GetImpl().device newBufferWithLength:64
                                                             options:MTLResourceStorageModeShared];
    DispatchSpin(scheduler, k, out, 1000);
    CHECK(scheduler.HasOpenCommandBuffer());
    CHECK(scheduler.OpenEncoder() == Scheduler::EncoderKind::Compute);
    scheduler.Flush();
    CHECK(scheduler.CurrentTick() == 3);
    CHECK(!scheduler.HasOpenCommandBuffer());
    CHECK(scheduler.OpenEncoder() == Scheduler::EncoderKind::None);
    scheduler.Wait(2);
    CHECK(scheduler.IsFreeKnown(2));
    CHECK(scheduler.IsFree(2));
    CHECK(!scheduler.IsFree(3));

    // Wait on the open tick flushes it.
    const u64 open = scheduler.CurrentTick();
    DispatchSpin(scheduler, k, out, 1000);
    scheduler.Wait(open);
    CHECK(scheduler.CurrentTick() == open + 1);
    CHECK(scheduler.IsFree(open));

    scheduler.Finish();
    CHECK(scheduler.IsFree(scheduler.CurrentTick() - 1));
    CHECK(!scheduler.HasFailed());

    // Encoders of different kinds replace one another.
    scheduler.BlitEncoder();
    CHECK(scheduler.OpenEncoder() == Scheduler::EncoderKind::Blit);
    scheduler.ComputeEncoder();
    CHECK(scheduler.OpenEncoder() == Scheduler::EncoderKind::Compute);
    CHECK(!scheduler.IsRendering());
    scheduler.EndRendering(); // not rendering: leaves the compute encoder alone
    CHECK(scheduler.OpenEncoder() == Scheduler::EncoderKind::Compute);
    scheduler.EndEncoder();
    CHECK(scheduler.OpenEncoder() == Scheduler::EncoderKind::None);
    scheduler.Finish();
}

/// Iterations of the spin kernel that take about `ms`.
static uint32_t Calibrate(Metal::Device& device, const Kernels& k, double ms) {
    id<MTLBuffer> out = [device.GetImpl().device newBufferWithLength:64
                                                             options:MTLResourceStorageModeShared];
    Scheduler scheduler{device, "test-calibrate"}; // (after the buffer: its destructor retires)
    DispatchSpin(scheduler, k, out, 1000);
    scheduler.Finish(); // warm up
    uint32_t n = 200000;
    double elapsed = 0;
    for (int i = 0; i < 4; ++i) {
        const auto start = Clock::now();
        DispatchSpin(scheduler, k, out, n);
        scheduler.Finish();
        elapsed = MsSince(start);
        if (elapsed > 5.0) {
            break;
        }
        n *= 8;
    }
    const double scaled = n * (ms / std::max(elapsed, 0.1));
    n = static_cast<uint32_t>(std::min(scaled, 4.0e9));
    std::printf("  spin kernel: %u iterations for ~%.0f ms (calibration run %.1f ms)\n", n, ms,
                elapsed);
    return n;
}

static void TestDeferred(Metal::Device& device, const Kernels& k, uint32_t spin_n) {
    std::printf("deferred operations\n");
    Scheduler scheduler{device, "test-deferred"};
    id<MTLBuffer> out = [device.GetImpl().device newBufferWithLength:64
                                                             options:MTLResourceStorageModeShared];
    std::atomic<int> order{0};
    std::atomic<int> ran_first{0}, ran_second{0};
    const u64 tick = scheduler.CurrentTick();
    DispatchSpin(scheduler, k, out, spin_n);
    scheduler.DeferOperation([&] { ran_first = ++order; });
    // Before the flush the tick is open: nothing runs.
    for (int i = 0; i < 100; ++i) {
        scheduler.PopPendingOperations();
    }
    CHECK(ran_first == 0);
    scheduler.Flush();
    // The kernel runs ~20 ms; the checks below take microseconds.
    CHECK(!scheduler.IsFree(tick));
    for (int i = 0; i < 200; ++i) { // more than the poll interval
        scheduler.PopPendingOperations();
    }
    CHECK(ran_first == 0);
    // An operation deferred to the next open tick waits for that one too.
    scheduler.DeferOperation([&] { ran_second = ++order; });
    CHECK(!scheduler.WaitTick(tick, 1000000)); // 1 ms: the kernel is still running
    scheduler.Wait(tick);
    CHECK(scheduler.IsFree(tick));
    // Deferred operations wait for the command buffer to retire (its completed handler), which
    // comes a moment after the event signal Wait saw.
    for (int i = 0; i < 1000 && ran_first == 0; ++i) {
        scheduler.PopPendingOperations();
        std::this_thread::sleep_for(std::chrono::microseconds(100));
    }
    CHECK(ran_first == 1);
    CHECK(ran_second == 0); // its tick (open) was not flushed
    scheduler.Flush();      // submits the open tick and pops what is free
    scheduler.Finish();
    for (int i = 0; i < 1000 && ran_second == 0; ++i) {
        scheduler.PopPendingOperations();
        std::this_thread::sleep_for(std::chrono::microseconds(100));
    }
    CHECK(ran_second == 2);

    // Priority operation: runs on another thread once the GPU is done, no one calls Pop.
    std::atomic<bool> prio_ran{false};
    std::atomic<bool> prio_was_free{false};
    std::thread::id prio_thread;
    const u64 prio_tick = scheduler.CurrentTick();
    DispatchSpin(scheduler, k, out, spin_n);
    scheduler.DeferPriorityOperation([&] {
        prio_was_free = scheduler.IsFree(prio_tick);
        prio_thread = std::this_thread::get_id();
        prio_ran = true;
    });
    std::this_thread::sleep_for(std::chrono::milliseconds(30));
    CHECK(!prio_ran); // the tick is open, not even submitted
    scheduler.Flush();
    const auto start = Clock::now();
    while (!prio_ran && MsSince(start) < 3000) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    CHECK(prio_ran);
    CHECK(prio_was_free);
    CHECK(prio_thread != std::this_thread::get_id());

    // Destruction runs what is left (the priority thread is waiting on a tick that was never
    // flushed) and joins the priority thread.
    std::atomic<bool> rest_ran{false}, prio_rest_ran{false};
    {
        Scheduler last{device, "test-deferred-last"};
        DispatchSpin(last, k, out, spin_n);
        last.DeferOperation([&] { rest_ran = true; });
        last.DeferPriorityOperation([&] { prio_rest_ran = true; });
    }
    CHECK(rest_ran);
    CHECK(prio_rest_ran);
}

static id<MTLBuffer> UntrackedBuffer(Metal::Device& device, size_t size) {
    id<MTLBuffer> buffer = [device.GetImpl().device
        newBufferWithLength:size
                    options:MTLResourceStorageModeShared | MTLResourceHazardTrackingModeUntracked];
    // Device addresses read and write nothing for a buffer that is not in the residency set.
    device.GetImpl().AddResident(buffer);
    return buffer;
}

static void ReadWord(Scheduler& scheduler, const Kernels& k, id<MTLBuffer> source, uint64_t index,
                     id<MTLBuffer> out) {
    scheduler.ComputeEncoder();
    auto& compute = scheduler.GetImpl().compute;
    const uint64_t address = source.gpuAddress;
    [compute setComputePipelineState:k.read_word];
    [compute setBytes:&address length:8 atIndex:0];
    [compute setBytes:&index length:8 atIndex:1];
    [compute setBuffer:out offset:0 atIndex:2];
    [compute dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
}

static void TestFenceChain(Metal::Device& device, const Kernels& k) {
    std::printf("fence chain and barriers\n");
    Scheduler scheduler{device, "test-fences"};
    constexpr size_t Size = 64 << 20; // a long fill: an unordered reader would see it half done
    constexpr uint64_t Last = Size / 4 - 1;
    id<MTLBuffer> big = UntrackedBuffer(device, Size);
    id<MTLBuffer> out = [device.GetImpl().device newBufferWithLength:64
                                                             options:MTLResourceStorageModeShared];
    auto* words = static_cast<uint32_t*>(out.contents);

    // Blit fill, barrier, compute read in another encoder (same and later command buffers).
    for (int round = 1; round <= 24; ++round) {
        const uint8_t value = static_cast<uint8_t>(round * 7);
        scheduler.BlitEncoder();
        [scheduler.GetImpl().blit fillBuffer:big range:NSMakeRange(0, Size) value:value];
        scheduler.MemoryBarrier(); // blit: ends the encoder
        CHECK(scheduler.OpenEncoder() == Scheduler::EncoderKind::None);
        CHECK(scheduler.NeedFenceWait());
        words[0] = 0;
        ReadWord(scheduler, k, big, Last, out);
        CHECK(!scheduler.NeedFenceWait()); // the new encoder took the wait
        if (round % 3 == 0) {
            scheduler.Flush(); // the chain spans command buffers
        }
        scheduler.Finish();
        CHECK(words[0] == value * 0x01010101u);
    }

    // More encoders than fence slots between two barriers.
    for (int i = 0; i < 20; ++i) {
        scheduler.BlitEncoder();
        // (own region each: encoders without a barrier between them are unordered)
        [scheduler.GetImpl().blit fillBuffer:big
                                       range:NSMakeRange(Size - 65536 + i * 256, 256)
                                       value:static_cast<uint8_t>(i)];
        scheduler.EndEncoder();
    }
    scheduler.BlitEncoder();
    [scheduler.GetImpl().blit fillBuffer:big range:NSMakeRange(0, Size - 65536) value:0xC3];
    scheduler.MemoryBarrier();
    ReadWord(scheduler, k, big, 7, out);
    scheduler.Finish();
    CHECK(words[0] == 0xC3C3C3C3u);

    // A compute write through gpuAddress, MemoryBarrier, a second dispatch reading it, all in
    // the same encoder (the residency set, no useResource).
    id<MTLBuffer> cell = UntrackedBuffer(device, 4096);
    for (uint32_t round = 1; round <= 40; ++round) {
        scheduler.ComputeEncoder();
        auto& compute = scheduler.GetImpl().compute;
        const uint64_t address = cell.gpuAddress;
        const uint32_t value = 0xA5000000u + round;
        [compute setComputePipelineState:k.write_word];
        [compute setBytes:&address length:8 atIndex:0];
        [compute setBytes:&value length:4 atIndex:1];
        [compute dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        scheduler.MemoryBarrier();
        CHECK(scheduler.OpenEncoder() == Scheduler::EncoderKind::Compute);
        words[0] = 0;
        ReadWord(scheduler, k, cell, 0, out);
        scheduler.Finish();
        CHECK(words[0] == value);
    }

    // The same across a compute and a blit encoder (barrier with an open compute encoder, the
    // reader in the next encoder).
    for (uint32_t round = 1; round <= 10; ++round) {
        scheduler.ComputeEncoder();
        auto& compute = scheduler.GetImpl().compute;
        const uint64_t address = cell.gpuAddress;
        const uint32_t value = 0x5A000000u + round;
        [compute setComputePipelineState:k.write_word];
        [compute setBytes:&address length:8 atIndex:0];
        [compute setBytes:&value length:4 atIndex:1];
        [compute dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        scheduler.EndEncoder();
        scheduler.MemoryBarrier(); // no encoder open
        CHECK(scheduler.NeedFenceWait());
        scheduler.BlitEncoder();
        CHECK(!scheduler.NeedFenceWait());
        [scheduler.GetImpl().blit copyFromBuffer:cell sourceOffset:0 toBuffer:out destinationOffset:0 size:4];
        scheduler.Finish();
        CHECK(words[0] == value);
    }

    // A render encoder: barrier inside it, and an empty pass behind a compute encoder.
    MTLTextureDescriptor* texture_descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:8
                                                          height:8
                                                       mipmapped:NO];
    texture_descriptor.usage = MTLTextureUsageRenderTarget;
    texture_descriptor.storageMode = MTLStorageModePrivate;
    id<MTLTexture> target = [device.GetImpl().device newTextureWithDescriptor:texture_descriptor];
    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    scheduler.ComputeEncoder(); // an empty encoder in front of the pass
    scheduler.EndEncoder();
    scheduler.RenderEncoder((__bridge const void*)pass);
    CHECK(scheduler.IsRendering());
    scheduler.MemoryBarrier();
    CHECK(scheduler.IsRendering());
    scheduler.EndRendering();
    CHECK(!scheduler.IsRendering());
    scheduler.RenderEncoder((__bridge const void*)pass); // after another encoder kind
    scheduler.ComputeEncoder();                           // ends the pass
    CHECK(!scheduler.IsRendering());
    scheduler.Finish();
    CHECK(!scheduler.HasFailed());
}

/// P6.2: a held pass takes no encoder; hoisted compute goes before it, after what came before.
static void TestHeldPass(Metal::Device& device, const Kernels& k) {
    std::printf("held pass\n");
    Scheduler scheduler{device, "test-held"};
    VideoCore::GpuQueue& queue = scheduler;
    constexpr size_t Size = 64 << 20; // a long fill: a hoist that overtook it would be overwritten
    id<MTLBuffer> big = UntrackedBuffer(device, Size);
    id<MTLBuffer> out = [device.GetImpl().device newBufferWithLength:64
                                                             options:MTLResourceStorageModeShared];
    auto* words = static_cast<uint32_t*>(out.contents);
    MTLTextureDescriptor* texture_descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:64
                                                          height:64
                                                       mipmapped:NO];
    texture_descriptor.usage = MTLTextureUsageRenderTarget;
    texture_descriptor.storageMode = MTLStorageModePrivate;
    id<MTLTexture> target = [device.GetImpl().device newTextureWithDescriptor:texture_descriptor];
    const VideoCore::RenderState state{};

    for (int round = 1; round <= 12; ++round) {
        const uint8_t fill = static_cast<uint8_t>(round * 5);
        const uint32_t hoisted = 0xabc00000u + round;
        scheduler.BlitEncoder();
        [scheduler.GetImpl().blit fillBuffer:big range:NSMakeRange(0, Size) value:fill];
        scheduler.MemoryBarrier();

        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        const u64 serial = queue.HeldPassSerial();
        scheduler.RenderEncoder((__bridge const void*)pass, state);
        CHECK(queue.HoldingPass() && queue.HeldPassSerial() == serial + 1);
        CHECK(scheduler.IsRenderingWith(state));
        CHECK(scheduler.GetImpl().render == nil); // no encoder while held
        CHECK(scheduler.Commands().Recording());
        scheduler.MemoryBarrier(); // recorded in the pass
        CHECK(scheduler.Commands().HasBarrier());

        // Hoisted: before the pass, after the fill (it waits for the blit's fence).
        queue.BeginHoist();
        scheduler.ComputeEncoder();
        CHECK(scheduler.GetImpl().compute != nil && scheduler.IsRendering());
        {
            auto& compute = scheduler.GetImpl().compute;
            const uint64_t address = big.gpuAddress;
            [compute setComputePipelineState:k.write_word];
            [compute setBytes:&address length:8 atIndex:0];
            [compute setBytes:&hoisted length:4 atIndex:1];
            [compute dispatchThreadgroups:MTLSizeMake(1, 1, 1)
                    threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        }
        queue.EndHoist();
        CHECK(queue.HoldingPass());

        // Anything else releases the pass: it gets its encoder, then ends.
        words[0] = words[1] = 0;
        ReadWord(scheduler, k, big, 0, out);
        CHECK(!queue.HoldingPass() && !scheduler.IsRendering());
        if (round % 2 == 0) {
            scheduler.Flush();
        }
        scheduler.Finish();
        CHECK(words[0] == hoisted);
    }
    // A pass held and released by Flush with nothing in it.
    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    scheduler.RenderEncoder((__bridge const void*)pass, state);
    scheduler.Finish();
    CHECK(!queue.HoldingPass() && !scheduler.HasFailed());
}

static void TestGpuQueue(Metal::Device& device, const Kernels& k) {
    std::printf("gpu queue\n");
    Scheduler scheduler{device, "test-queue"};
    VideoCore::GpuQueue& queue = scheduler;
    CHECK(!queue.HoldingPass() && queue.HoistEnabled()); // held passes are the default (P6.2)

    // The submit callback runs before every submission, then what it put in the submit info.
    int callbacks = 0, before_submit = 0, tick_in_callback = 0;
    queue.SetSubmitCallback([&](VideoCore::SubmitInfo& info) {
        ++callbacks;
        tick_in_callback = static_cast<int>(scheduler.CurrentTick());
        info.before_submit.emplace_back([&] { ++before_submit; });
        scheduler.Flush(); // a callback that flushes again is not called back
    });
    const u64 first = scheduler.CurrentTick();
    queue.Flush();
    CHECK(callbacks == 1 && before_submit == 1);
    CHECK(tick_in_callback == static_cast<int>(first));
    CHECK(scheduler.CurrentTick() == first + 2); // the nested Flush took one tick too
    queue.WaitSubmitted(first); // already submitted
    scheduler.Wait(first + 1);
    CHECK(queue.KnownGpuTick() >= first + 1);

    // WaitSubmitted of the open tick blocks until another thread flushes it.
    std::atomic<bool> waited{false};
    const u64 open = scheduler.CurrentTick();
    std::thread waiter([&] {
        queue.WaitSubmitted(open);
        waited = true;
    });
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    CHECK(!waited);
    queue.Flush();
    waiter.join();
    CHECK(waited);
    queue.SetSubmitCallback({});

    // Recording order and host copies are immediate.
    queue.KickRecording(true);
    queue.SyncRecording();
    queue.WaitHostCopies();
    queue.WaitHostCopiesFor(0, 16);
    int signalled = 0;
    queue.SignalAfterHostCopies([&] { ++signalled; });
    CHECK(signalled == 1);
    queue.WaitDeferredSignals();
    queue.BeginHoist();
    queue.EndHoist();
    queue.ReleaseHeldPass();
    CHECK(!queue.HoldingPass());

    // The render pass is compared with the state it was begun with.
    MTLTextureDescriptor* texture_descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:8
                                                          height:8
                                                       mipmapped:NO];
    texture_descriptor.usage = MTLTextureUsageRenderTarget;
    texture_descriptor.storageMode = MTLStorageModePrivate;
    id<MTLTexture> target = [device.GetImpl().device newTextureWithDescriptor:texture_descriptor];
    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    VideoCore::RenderState state{};
    state.width = state.height = 8;
    state.num_layers = 1;
    state.num_color_attachments = 1;
    state.color_attachments[0].image_view = 0x1234;
    VideoCore::RenderState other = state;
    other.color_attachments[0].image_view = 0x5678;
    CHECK(!queue.IsRenderingWith(state));
    CHECK(queue.WillBeginRendering(state));
    scheduler.RenderEncoder((__bridge const void*)pass, state);
    CHECK(scheduler.IsRendering());
    CHECK(queue.IsRenderingWith(state));
    CHECK(!queue.WillBeginRendering(state));
    CHECK(!queue.IsRenderingWith(other));
    CHECK(queue.WillBeginRendering(other));
    scheduler.EndRendering();
    CHECK(!queue.IsRenderingWith(state));
    scheduler.RenderEncoder((__bridge const void*)pass); // without a state: never matches
    CHECK(!queue.IsRenderingWith(state));
    scheduler.ComputeEncoder();
    CHECK(!queue.IsRenderingWith(state));
    scheduler.Finish();
    CHECK(!scheduler.HasFailed());
}

static void TestLabels(Metal::Device& device, const Kernels& k) {
    std::printf("labels\n");
    setenv("BB_MTL_LABELS", "1", 1);
    {
        id<MTLBuffer> out = [device.GetImpl().device newBufferWithLength:64
                                                                 options:MTLResourceStorageModeShared];
        Scheduler scheduler{device, "test-labels"};
        scheduler.PushDebugGroup("outer"); // no encoder yet: applies to the next one
        DispatchSpin(scheduler, k, out, 100);
        scheduler.PushDebugGroup("inner");
        scheduler.InsertDebugSignpost("signpost");
        scheduler.PopDebugGroup();
        scheduler.EndEncoder(); // pops "outer" too
        scheduler.BlitEncoder(); // "outer" again
        scheduler.PopDebugGroup();
        scheduler.PopDebugGroup(); // more pops than pushes: ignored
        scheduler.Finish();
        CHECK(!scheduler.HasFailed());
    }
    unsetenv("BB_MTL_LABELS");
}

static void TestErrors(Metal::Device& device, const Kernels& k) {
    std::printf("errors\n");
    Scheduler scheduler{device, "test-errors"};
    std::string report;
    scheduler.SetErrorHandler([&](const std::string& text) { report = text; });
    CHECK(!scheduler.HasFailed());
    // What the completed handler does for a command buffer in error status.
    NSError* error = [NSError errorWithDomain:MTLCommandBufferErrorDomain
                                         code:MTLCommandBufferErrorTimeout
                                     userInfo:@{NSLocalizedDescriptionKey : @"synthetic"}];
    scheduler.ReportFailure(7, "test-errors #7", error.localizedDescription.UTF8String);
    CHECK(scheduler.HasFailed());
    CHECK(report.find("test-errors #7") != std::string::npos);
    CHECK(report.find("synthetic") != std::string::npos);
    // Waiting on a tick that can no longer be signaled must not hang.
    const auto start = Clock::now();
    scheduler.Wait(scheduler.CurrentTick() + 3);
    CHECK(MsSince(start) < 2000);
}

int main() {
    @autoreleasepool {
        Metal::Device device;
        NSError* error = nil;
        id<MTLLibrary> library = [device.GetImpl().device newLibraryWithSource:kernel_source
                                                                       options:nil
                                                                         error:&error];
        if (!library) {
            std::printf("kernels: %s\n", error.localizedDescription.UTF8String);
            return 2;
        }
        Kernels k;
        k.spin = Pipeline(device.GetImpl().device, library, @"spin");
        k.write_word = Pipeline(device.GetImpl().device, library, @"write_word");
        k.read_word = Pipeline(device.GetImpl().device, library, @"read_word");

        TestTicks(device, k);
        const uint32_t spin_n = Calibrate(device, k, 20.0);
        TestDeferred(device, k, spin_n);
        TestFenceChain(device, k);
        TestHeldPass(device, k);
        TestGpuQueue(device, k);
        TestLabels(device, k);
        TestErrors(device, k);
    }
    std::printf(failures ? "FAILED: %d check(s)\n" : "all checks passed\n", failures);
    return failures ? 1 : 0;
}
