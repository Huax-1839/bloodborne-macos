// SPDX-License-Identifier: GPL-2.0-or-later

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>

#include "bbport_toggles.h"
#include "bbport_flush_reason.h"
#include "common/assert.h"
#include "common/logging/log.h"
#include "common/thread.h"
#include "video_core/renderer_metal/mtl_scheduler_impl.h"

namespace Metal {
namespace {
using EncoderKind = Scheduler::EncoderKind;

constexpr u64 WaitSliceMs = 100;     ///< one bounded wait of Wait()
constexpr u64 StuckWarningMs = 10000; ///< Wait() warns once after this long

/// A fence wait before everything the encoder does from here on. Render encoders take stages:
/// vertex is the first one every draw goes through.
/// BB_MTL_FENCES=0 or experiment bit MtlNoFences (diagnostics only, unsafe): no fence waits or
/// updates, to measure their cost.
bool FencesEnabled() {
    static const bool enabled = [] {
        const char* env = std::getenv("BB_MTL_FENCES");
        return !(env && env[0] == '0');
    }();
    return enabled && !BbToggle::Experiment(BbToggle::MtlNoFences);
}

void WaitFence(Scheduler::Impl& impl, EncoderKind kind, u32 slot) {
    if (!FencesEnabled()) {
        impl.outstanding_fences &= ~(1u << slot);
        return;
    }
    id<MTLFence> fence = impl.fences[slot];
    switch (kind) {
    case EncoderKind::Render:
        [impl.render waitForFence:fence beforeStages:MTLRenderStageVertex];
        break;
    case EncoderKind::Compute:
        [impl.compute waitForFence:fence];
        break;
    case EncoderKind::Blit:
        [impl.blit waitForFence:fence];
        break;
    case EncoderKind::None:
        break;
    }
    impl.outstanding_fences &= ~(1u << slot);
}

void WaitOutstandingFences(Scheduler::Impl& impl, EncoderKind kind) {
    for (u32 slot = 0; slot < Scheduler::Impl::FenceCount; ++slot) {
        if (impl.outstanding_fences & (1u << slot)) {
            WaitFence(impl, kind, slot);
        }
    }
}

/// Every encoder declares the guest chunks used, as MoltenVK does for every device-address
/// buffer: this is what makes them resident (they are not in the residency set, P8.5; device
/// addresses read and write nothing without residency, D6). BB_MTL_USE_GUEST=0 turns it off
/// (only with BB_MTL_GUEST_IN_SET=1).
void UseGuestChunks(Scheduler::Impl& impl, EncoderKind kind) {
    static const bool enabled = [] {
        const char* env = std::getenv("BB_MTL_USE_GUEST");
        return !(env && env[0] == '0');
    }();
    if (!enabled) {
        return;
    }
    const std::size_t count = impl.dev.guest_count.load(std::memory_order_acquire);
    if (count == 0) {
        return;
    }
    const id<MTLResource> __unsafe_unretained* list = impl.dev.guest_buffers.data();
    const MTLResourceUsage usage = MTLResourceUsageRead | MTLResourceUsageWrite;
    switch (kind) {
    case EncoderKind::Render:
        [impl.render useResources:list
                            count:count
                            usage:usage
                           stages:MTLRenderStageVertex | MTLRenderStageFragment];
        break;
    case EncoderKind::Compute:
        [impl.compute useResources:list count:count usage:usage];
        break;
    default:
        break;
    }
}

/// Everything the NSError says: domain, code, text and what each encoder was doing.
std::string DescribeError(NSError* error) {
    if (!error) {
        return "no NSError";
    }
    NSMutableString* text = [NSMutableString
        stringWithFormat:@"%@ code %ld: %@", error.domain, static_cast<long>(error.code),
                         error.localizedDescription];
    NSArray* infos = error.userInfo[MTLCommandBufferEncoderInfoErrorKey];
    for (id<MTLCommandBufferEncoderInfo> info in infos) {
        NSString* state = @"unknown";
        switch (info.errorState) {
        case MTLCommandEncoderErrorStateCompleted:
            state = @"completed";
            break;
        case MTLCommandEncoderErrorStateAffected:
            state = @"affected";
            break;
        case MTLCommandEncoderErrorStatePending:
            state = @"pending";
            break;
        case MTLCommandEncoderErrorStateFaulted:
            state = @"FAULTED";
            break;
        default:
            break;
        }
        [text appendFormat:@"\n  encoder '%@': %@", info.label ?: @"", state];
        for (NSString* signpost in info.debugSignposts) {
            [text appendFormat:@"\n    signpost: %@", signpost];
        }
    }
    return text.UTF8String;
}
} // namespace

id<MTLCommandBuffer> Scheduler::Impl::EnsureCommandBuffer() {
    if (!cmdbuf) {
        MTLCommandBufferDescriptor* descriptor = [MTLCommandBufferDescriptor new];
        // D6: nothing is retained for the GPU; the caches defer every destroy past the tick.
        descriptor.retainedReferences = NO;
        static const bool encoder_status = [] {
            const char* env = std::getenv("BB_MTL_ENCODER_STATUS");
            return !env || env[0] != '0';
        }();
        if (encoder_status) {
            descriptor.errorOptions = MTLCommandBufferErrorOptionEncoderExecutionStatus;
        }
        // The recording threads have no autorelease pool of their own that drains: without this
        // one every command buffer (and what it references) stayed alive for good (P7.3 soak:
        // footprint +45 MB/min, +7 GB/min with the validation layer).
        @autoreleasepool {
            cmdbuf = [dev.queue commandBufferWithDescriptor:descriptor];
            cmdbuf.label = [NSString stringWithFormat:@"%@ #%llu", name,
                                                      static_cast<unsigned long long>(tick.load())];
        }
    }
    return cmdbuf;
}

Scheduler::Scheduler(Device& device_, const char* name_)
    : device{device_}, impl{std::make_unique<Impl>(device_.GetImpl(), @(name_), current_tick)},
      name{name_} {
    impl->event = [impl->dev.device newSharedEvent];
    ASSERT_MSG(impl->event, "Could not create the Metal shared event");
    for (auto& fence : impl->fences) {
        fence = [impl->dev.device newFence];
        ASSERT_MSG(fence, "Could not create a Metal fence");
    }
    const char* labels = std::getenv("BB_MTL_LABELS");
    labels_enabled = labels && labels[0] == '1';
    const char* pass = std::getenv("BB_PASS_LABELS");
    pass_labels = pass && pass[0] == '1';
    const char* hold = std::getenv("BB_MTL_HOLD");
    hold_env = !(hold && hold[0] == '0');
    hold_passes = hold_env;
    const char* replay = std::getenv("BB_MTL_REPLAY_THREAD");
    replay_enabled = hold_env && !(replay && replay[0] == '0');
    if (replay_enabled) {
        replay_thread = std::jthread(std::bind_front(&Scheduler::ReplayThread, this));
    }
}

Scheduler::~Scheduler() {
    // The callback belongs to the rasterizer, which is gone by now.
    on_submit = VideoCore::SubmitFunc{};
    JoinReplay();
    if (replay_thread.joinable()) {
        replay_thread.request_stop();
        replay_posted.fetch_add(1, std::memory_order_acq_rel); // wakes it (no job)
        replay_posted.notify_all();
        replay_thread.join();
        replay_done.store(replay_posted.load(std::memory_order_acquire), std::memory_order_release);
    }
    priority_thread.request_stop();
    priority_cv.notify_all();
    if (priority_thread.joinable()) {
        priority_thread.join();
    }
    // The completed handlers hold `this`: wait for every committed command buffer first.
    if (open_encoder != EncoderKind::None || impl->cmdbuf) {
        Flush();
    }
    Wait(CurrentTick() - 1);
    // The event is signaled before the command buffer is retired: its handler (and Metal's own
    // bookkeeping of what it used) comes a moment later.
    while (handlers_in_flight.load(std::memory_order_acquire) != 0 && !HasFailed()) {
        std::this_thread::yield();
    }
    PopPendingOperations();
    std::queue<PendingOp> priority_rest;
    {
        std::scoped_lock lock{priority_mutex};
        priority_rest.swap(priority_pending_ops);
    }
    while (!priority_rest.empty()) {
        priority_rest.front().callback();
        priority_rest.pop();
    }
}

bool Scheduler::HasOpenCommandBuffer() const noexcept {
    return impl->cmdbuf != nil;
}

void Scheduler::BeginEncoder(EncoderKind kind, const void* pass_descriptor) {
    EndEncoder();
    if (kind == EncoderKind::None) {
        return;
    }
    OpenPhysical(kind, pass_descriptor, std::exchange(need_fence_wait, false));
    open_encoder = kind;
}

void Scheduler::OpenPhysical(EncoderKind kind, const void* pass_descriptor, bool wait_all) {
    id<MTLCommandBuffer> cmdbuf = impl->EnsureCommandBuffer();
    // Encoders are autoreleased: the pool drains them once the scheduler holds its reference.
    @autoreleasepool {
    switch (kind) {
    case EncoderKind::Render:
        impl->render = [cmdbuf renderCommandEncoderWithDescriptor:(__bridge MTLRenderPassDescriptor*)
                                                                        pass_descriptor];
        ASSERT_MSG(impl->render, "Could not create a Metal render encoder");
        break;
    case EncoderKind::Compute:
        impl->compute = [cmdbuf computeCommandEncoder];
        break;
    case EncoderKind::Blit:
        impl->blit = [cmdbuf blitCommandEncoder];
        break;
    case EncoderKind::None:
        return;
    }
    }
    UseGuestChunks(*impl, kind);
    // The slot this encoder updates at its end may still wait for a waiter (more encoders than
    // slots without a barrier): that one waits now, which keeps the chain.
    const u32 slot = impl->next_fence;
    if (impl->outstanding_fences & (1u << slot)) {
        WaitFence(*impl, kind, slot);
    }
    if (wait_all) {
        WaitOutstandingFences(*impl, kind);
    }
    if (labels_enabled) {
        for (const std::string& group : debug_groups) {
            NSString* label = @(group.c_str());
            switch (kind) {
            case EncoderKind::Render:
                [impl->render pushDebugGroup:label];
                break;
            case EncoderKind::Compute:
                [impl->compute pushDebugGroup:label];
                break;
            case EncoderKind::Blit:
                [impl->blit pushDebugGroup:label];
                break;
            case EncoderKind::None:
                break;
            }
        }
    }
}

void Scheduler::RenderEncoder(const void* pass_descriptor) {
    ASSERT_MSG(pass_descriptor, "RenderEncoder without a pass descriptor");
    BeginEncoder(EncoderKind::Render, pass_descriptor);
    render_state.reset();
}

void Scheduler::RenderEncoder(const void* pass_descriptor, const VideoCore::RenderState& state) {
    ASSERT_MSG(pass_descriptor, "RenderEncoder without a pass descriptor");
    // Experiment bit MtlNoHold switches holding off while the game runs (taken at a pass begin).
    hold_passes = hold_env && !BbToggle::Experiment(BbToggle::MtlNoHold);
    if (!hold_passes) {
        RenderEncoder(pass_descriptor);
        render_state = state;
        commands.BeginDirect((__bridge void*)impl->render);
        commands_active = true;
        return;
    }
    if (holding && replay_enabled && open_encoder == EncoderKind::Render &&
        !BbToggle::Experiment(BbToggle::MtlNoReplayThread)) {
        PostReplay(); // the held pass is encoded on the replay thread while this one is recorded
    } else {
        EndEncoder();
    }
    impl->EnsureCommandBuffer(); // (open already after a PostReplay: no Metal call)
    // Held: the descriptor is kept (the caller's is autoreleased) until the pass is released.
    impl->held_pass = (__bridge MTLRenderPassDescriptor*)pass_descriptor;
    open_encoder = EncoderKind::Render;
    render_state = state;
    holding = true;
    ++held_serial;
    hoisting = false;
    hoisted = false;
    held_label.clear();
    commands.BeginRecording();
    commands_active = true;
}

void Scheduler::ReleaseHeldPass() {
    JoinReplay();
    if (!holding) {
        return;
    }
    holding = false;
    hoisting = false;
    // What goes before the pass first: the hoisted compute encoder, whose writes the pass waits
    // for (as it waits for earlier encoders when a barrier was recorded in it).
    if (impl->compute) {
        ClosePhysical(EncoderKind::Compute);
    }
    if (hoisted || commands.HasBarrier()) {
        need_fence_wait = true;
    }
    hoisted = false;
    OpenPhysical(EncoderKind::Render, (__bridge const void*)impl->held_pass,
                 std::exchange(need_fence_wait, false));
    impl->held_pass = nil;
    if (pass_labels && !held_label.empty()) {
        impl->render.label = @(held_label.c_str());
    }
    commands.Replay((__bridge void*)impl->render);
    commands.BeginDirect((__bridge void*)impl->render);
}

void Scheduler::PostReplay() {
    const u32 posted = replay_posted.load(std::memory_order_relaxed); // (only this thread posts)
    WaitReplay(posted + 1 - ReplayDepth); // a free slot
    const u32 slot = posted % ReplayDepth;
    ReplayJob& job = replay_ring[slot];
    // What ReleaseHeldPass and EndEncoder do on this thread, but the encoding goes to the job.
    // The hoisted compute encoder is the only one open while a pass is held.
    job.close_compute = hoisted;
    job.wait_all = std::exchange(need_fence_wait, false) || hoisted || commands.HasBarrier();
    job.label = pass_labels ? held_label : std::string{};
    holding = false;
    hoisting = false;
    hoisted = false;
    impl->replay_passes[slot] = impl->held_pass;
    impl->held_pass = nil;
    commands.TakeRecording(job.list);
    commands.End();
    commands_active = false;
    open_encoder = EncoderKind::None;
    render_state.reset();
    ++replay_jobs;
    replay_posted.store(posted + 1, std::memory_order_release);
    replay_posted.notify_one();
}

void Scheduler::JoinReplay() {
    WaitReplay(replay_posted.load(std::memory_order_acquire));
}

void Scheduler::WaitReplay(u32 target) {
    // Jobs done reaches `target` (wrapping counters).
    const auto reached = [target](u32 done) { return static_cast<s32>(done - target) >= 0; };
    u32 done = replay_done.load(std::memory_order_acquire);
    if (reached(done)) {
        return;
    }
    const auto start = std::chrono::steady_clock::now();
    for (int spin = 0; !reached(done) && spin < 4096; ++spin) {
        __builtin_ia32_pause();
        done = replay_done.load(std::memory_order_acquire);
    }
    while (!reached(done)) {
        replay_done.wait(done, std::memory_order_acquire);
        done = replay_done.load(std::memory_order_acquire);
    }
    const auto now = std::chrono::steady_clock::now();
    const u64 waited = std::chrono::duration_cast<std::chrono::nanoseconds>(now - start).count();
    BbStats::rec_replay_wait_ns.fetch_add(waited, std::memory_order_relaxed);
    if (BbStats::enabled) {
        ++replay_joins;
        replay_wait_ns += waited;
        if (now - replay_window >= std::chrono::seconds(5)) {
            if (replay_window != std::chrono::steady_clock::time_point{}) {
                const double seconds = std::chrono::duration<double>(now - replay_window).count();
                std::printf("Metal replay thread: %.0f passes/s, the recording thread waited for "
                            "it %.0f/s (%.2f ms/s)\n",
                            replay_jobs / seconds, replay_joins / seconds,
                            replay_wait_ns / 1e6 / seconds);
            }
            replay_window = now;
            replay_jobs = replay_joins = replay_wait_ns = 0;
        }
    }
}

void Scheduler::RunReplayJob(u32 slot) {
    ReplayJob& job = replay_ring[slot];
    @autoreleasepool {
        if (job.close_compute) {
            CloseNative(EncoderKind::Compute);
        }
        OpenPhysical(EncoderKind::Render, (__bridge const void*)impl->replay_passes[slot],
                     job.wait_all);
        impl->replay_passes[slot] = nil;
        if (!job.label.empty()) {
            impl->render.label = @(job.label.c_str());
        }
        job.list.Replay((__bridge void*)impl->render);
        job.list.End();
        CloseNative(EncoderKind::Render);
    }
}

void Scheduler::ReplayThread(std::stop_token stoken) {
    Common::SetCurrentThreadName("bb:MtlReplay");
    u32 done = 0;
    while (true) {
        u32 posted = replay_posted.load(std::memory_order_acquire);
        // Passes come every few hundred microseconds: a short spin before sleeping.
        for (int spin = 0; posted == done && spin < 2048; ++spin) {
            __builtin_ia32_pause();
            posted = replay_posted.load(std::memory_order_acquire);
        }
        if (posted == done) {
            replay_posted.wait(done, std::memory_order_acquire);
            continue;
        }
        if (stoken.stop_requested()) {
            return;
        }
        for (; done != posted; ++done) {
            RunReplayJob(done % ReplayDepth);
            replay_done.store(done + 1, std::memory_order_release);
            replay_done.notify_one();
        }
    }
}

void Scheduler::ComputeEncoder(const char* label) {
    JoinReplay();
    if (holding && hoisting) {
        // Before the held pass: one compute encoder for everything hoisted into this pass, after
        // every encoder before it (the barrier Vulkan records before a hoisted dispatch).
        if (!impl->compute) {
            need_fence_wait = false; // (it waits for everything before it anyway)
            OpenPhysical(EncoderKind::Compute, nullptr, true);
            hoisted = true;
            if (label) {
                LabelEncoder(label);
            }
        }
        return;
    }
    if (open_encoder != EncoderKind::Compute) {
        BeginEncoder(EncoderKind::Compute, nullptr);
        if (label) {
            LabelEncoder(label);
        }
    }
}

void Scheduler::BlitEncoder(const char* label) {
    JoinReplay();
    if (open_encoder != EncoderKind::Blit) {
        BeginEncoder(EncoderKind::Blit, nullptr);
        if (label) {
            LabelEncoder(label);
        }
    }
}

void Scheduler::EndEncoder() {
    JoinReplay();
    if (open_encoder == EncoderKind::None) {
        return;
    }
    ReleaseHeldPass();
    ClosePhysical(open_encoder);
    open_encoder = EncoderKind::None;
    render_state.reset();
}

void Scheduler::ClosePhysical(EncoderKind kind) {
    if (kind == EncoderKind::Render && commands_active) {
        commands.End();
        commands_active = false;
    }
    CloseNative(kind);
}

void Scheduler::CloseNative(EncoderKind kind) {
    // Every encoder updates the next fence of the ring at its end (see MemoryBarrier).
    const u32 slot = impl->next_fence;
    id<MTLFence> fence = impl->fences[slot];
    switch (kind) {
    case EncoderKind::Render:
        for (size_t i = 0; labels_enabled && i < debug_groups.size(); ++i) {
            [impl->render popDebugGroup];
        }
        if (FencesEnabled()) {
            [impl->render updateFence:fence afterStages:MTLRenderStageFragment];
        }
        [impl->render endEncoding];
        impl->render = nil;
        break;
    case EncoderKind::Compute:
        for (size_t i = 0; labels_enabled && i < debug_groups.size(); ++i) {
            [impl->compute popDebugGroup];
        }
        if (FencesEnabled()) {
            [impl->compute updateFence:fence];
        }
        [impl->compute endEncoding];
        impl->compute = nil;
        break;
    case EncoderKind::Blit:
        for (size_t i = 0; labels_enabled && i < debug_groups.size(); ++i) {
            [impl->blit popDebugGroup];
        }
        if (FencesEnabled()) {
            [impl->blit updateFence:fence];
        }
        [impl->blit endEncoding];
        impl->blit = nil;
        break;
    case EncoderKind::None:
        return;
    }
    impl->outstanding_fences |= 1u << slot;
    impl->next_fence = (slot + 1) % Impl::FenceCount;
}

void Scheduler::EndRendering() {
    if (open_encoder == EncoderKind::Render) {
        EndEncoder();
    }
}

void Scheduler::MemoryBarrier() {
    if (holding) {
        if (hoisting) {
            JoinReplay(); // (the job may still end the previous pass's hoisted encoder)
            if (impl->compute) {
                [impl->compute memoryBarrierWithScope:MTLBarrierScopeBuffers | MTLBarrierScopeTextures];
                WaitOutstandingFences(*impl, EncoderKind::Compute);
            }
            // (else the hoisted encoder, when it comes, waits for everything before it)
            return;
        }
        // In the pass: recorded; the render encoder waits for the earlier encoders' fences when
        // it is made (HasBarrier).
        commands.MemoryBarrier();
        return;
    }
    JoinReplay();
    switch (open_encoder) {
    case EncoderKind::Compute:
        [impl->compute memoryBarrierWithScope:MTLBarrierScopeBuffers | MTLBarrierScopeTextures];
        WaitOutstandingFences(*impl, EncoderKind::Compute);
        break;
    case EncoderKind::Render:
        [impl->render memoryBarrierWithScope:MTLBarrierScopeBuffers | MTLBarrierScopeTextures
                                 afterStages:MTLRenderStageVertex | MTLRenderStageFragment
                                beforeStages:MTLRenderStageVertex | MTLRenderStageFragment];
        WaitOutstandingFences(*impl, EncoderKind::Render);
        break;
    case EncoderKind::Blit:
        // Blit encoders have no memory barrier: the next encoder starts after this one.
        EndEncoder();
        need_fence_wait = true;
        break;
    case EncoderKind::None:
        need_fence_wait = true;
        break;
    }
}

void Scheduler::PushDebugGroup(const char* group) {
    if (!labels_enabled) {
        return;
    }
    ReleaseHeldPass(); // BB_MTL_LABELS (diagnostics): groups apply to physical encoders only
    debug_groups.emplace_back(group);
    NSString* label = @(group);
    switch (open_encoder) {
    case EncoderKind::Render:
        [impl->render pushDebugGroup:label];
        break;
    case EncoderKind::Compute:
        [impl->compute pushDebugGroup:label];
        break;
    case EncoderKind::Blit:
        [impl->blit pushDebugGroup:label];
        break;
    case EncoderKind::None:
        break;
    }
}

void Scheduler::PopDebugGroup() {
    if (!labels_enabled || debug_groups.empty()) {
        return;
    }
    ReleaseHeldPass();
    debug_groups.pop_back();
    switch (open_encoder) {
    case EncoderKind::Render:
        [impl->render popDebugGroup];
        break;
    case EncoderKind::Compute:
        [impl->compute popDebugGroup];
        break;
    case EncoderKind::Blit:
        [impl->blit popDebugGroup];
        break;
    case EncoderKind::None:
        break;
    }
}

void Scheduler::InsertDebugSignpost(const char* text) {
    if (!labels_enabled) {
        return;
    }
    if (holding && !hoisting) {
        commands.InsertDebugSignpost(text);
        return;
    }
    JoinReplay();
    NSString* label = @(text);
    switch (open_encoder) {
    case EncoderKind::Render:
        [impl->render insertDebugSignpost:label];
        break;
    case EncoderKind::Compute:
        [impl->compute insertDebugSignpost:label];
        break;
    case EncoderKind::Blit:
        [impl->blit insertDebugSignpost:label];
        break;
    case EncoderKind::None:
        if (impl->cmdbuf) {
            [impl->cmdbuf pushDebugGroup:label];
            [impl->cmdbuf popDebugGroup];
        }
        break;
    }
}

void Scheduler::LabelEncoder(const char* text) {
    if (!pass_labels) {
        return;
    }
    if (holding && !hoisting) {
        held_label = text;
        return;
    }
    JoinReplay();
    if (holding) {
        if (impl->compute) {
            impl->compute.label = @(text); // the hoisted encoder
        }
        return;
    }
    NSString* label = @(text);
    switch (open_encoder) {
    case EncoderKind::Render:
        impl->render.label = label;
        break;
    case EncoderKind::Compute:
        impl->compute.label = label;
        break;
    case EncoderKind::Blit:
        impl->blit.label = label;
        break;
    case EncoderKind::None:
        break;
    }
}

namespace {
/// Raises an atomic tick to `value` (never lowers it).
void AdvanceTo(std::atomic<u64>& counter, u64 value) {
    u64 current = counter.load(std::memory_order_acquire);
    while (current < value && !counter.compare_exchange_weak(current, value)) {
    }
}
} // namespace

void Scheduler::SetSubmitCallback(VideoCore::SubmitFunc&& callback) {
    on_submit = std::move(callback);
}

void Scheduler::WaitSubmitted(u64 tick) {
    u64 current = CurrentTick();
    while (current <= tick) {
        current_tick.wait(current, std::memory_order_acquire);
        current = CurrentTick();
    }
}

void Scheduler::ReportStuck(const char* where) {
    LOG_WARNING(Render, "Metal scheduler '{}' ({}): open tick {}, GPU known tick {}, retired {}, {} "
                        "command buffers in flight, {} deferred operations",
                name, where, CurrentTick(), known_tick.load(), retired_tick.load(),
                handlers_in_flight.load(), num_pending_ops.load());
}

void Scheduler::Flush() {
    JoinReplay();
    if (on_submit && !in_submit_callback) {
        // The rasterizer flushes its barriers and hands the queue operations that go out with the
        // submission (none on Metal, but the buffer cache's arena binds ride here on Vulkan).
        in_submit_callback = true;
        VideoCore::SubmitInfo info;
        on_submit(info);
        for (const auto& operation : info.before_submit) {
            operation();
        }
        in_submit_callback = false;
    }
    EndEncoder();
    const u64 tick = CurrentTick();
    if (!impl->cmdbuf && retired_tick.load(std::memory_order_acquire) >= tick - 1) {
        // Nothing recorded and every earlier command buffer retired: the tick is done as soon as
        // it is signaled, no empty command buffer needed.
        impl->event.signaledValue = tick;
        AdvanceTo(known_tick, tick);
        AdvanceTo(retired_tick, tick);
        BbFlushReason::Skipped();
    } else @autoreleasepool {
        BbFlushReason::Commit();
        if (!impl->cmdbuf) {
            BbFlushReason::SignalOnly(); // nothing encoded: the command buffer only signals
        }
        id<MTLCommandBuffer> cmdbuf = impl->EnsureCommandBuffer();
        [cmdbuf encodeSignalEvent:impl->event value:tick];
        NSString* label = cmdbuf.label;
        handlers_in_flight.fetch_add(1, std::memory_order_acq_rel);
        [cmdbuf addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            if (completed.status == MTLCommandBufferStatusError) {
                ReportFailure(tick, label.UTF8String, DescribeError(completed.error));
            }
            BbStats::NoteGpuInterval(completed.GPUStartTime, completed.GPUEndTime);
            AdvanceTo(retired_tick, tick);
            handlers_in_flight.fetch_sub(1, std::memory_order_acq_rel);
        }];
        [cmdbuf commit];
        impl->cmdbuf = nil;
    }
    current_tick.store(tick + 1, std::memory_order_release);
    current_tick.notify_all(); // WaitSubmitted
    RefreshTicks();
    PopPendingOperations();
}

void Scheduler::Finish() {
    BbFlushReason::Scope reason{BbFlushReason::Reason::SchedulerFinish, true};
    Flush();
    Wait(CurrentTick() - 1);
}

void Scheduler::RefreshTicks() {
    AdvanceTo(known_tick, impl->event.signaledValue);
}

bool Scheduler::IsFree(u64 tick) noexcept {
    if (IsFreeKnown(tick)) {
        return true;
    }
    RefreshTicks();
    return IsFreeKnown(tick);
}

bool Scheduler::WaitTick(u64 tick, u64 timeout_ns) {
    if (IsFreeKnown(tick)) {
        return true;
    }
    if (HasFailed()) {
        return false;
    }
    const u64 timeout_ms = (timeout_ns + 999999) / 1000000;
    [impl->event waitUntilSignaledValue:tick timeoutMS:timeout_ms];
    return IsFree(tick);
}

void Scheduler::Wait(u64 tick) {
    if (tick >= CurrentTick()) {
        BbFlushReason::Scope reason{BbFlushReason::Reason::SchedulerWait, true};
        Flush(); // the open tick: it only completes once submitted
    }
    const auto start = std::chrono::steady_clock::now();
    bool warned = false;
    while (!WaitTick(tick, WaitSliceMs * 1000000)) {
        if (HasFailed()) {
            return; // reported; the signal of a failed command buffer may never come
        }
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                                 std::chrono::steady_clock::now() - start)
                                 .count();
        if (!warned && static_cast<u64>(elapsed) >= StuckWarningMs) {
            warned = true;
            LOG_WARNING(Render, "Metal scheduler '{}': tick {} not signaled after {} ms", name,
                        tick, elapsed);
        }
    }
    BbStats::rec_gpu_wait_ns.fetch_add(
        std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - start)
            .count(),
        std::memory_order_relaxed);
}

void Scheduler::DeferOperation(Common::UniqueFunction<void>&& func) {
    std::scoped_lock lock{pending_ops_mutex};
    pending_ops.push(PendingOp{std::move(func), CurrentTick()});
    num_pending_ops.fetch_add(1, std::memory_order_release);
}

void Scheduler::DeferPriorityOperation(Common::UniqueFunction<void>&& func) {
    {
        std::scoped_lock lock{priority_mutex};
        priority_pending_ops.push(PendingOp{std::move(func), CurrentTick()});
        if (!priority_thread.joinable()) {
            priority_thread = std::jthread(std::bind_front(&Scheduler::PriorityPendingOpsThread, this));
        }
    }
    priority_cv.notify_one();
}

void Scheduler::PopPendingOperations() {
    if (num_pending_ops.load(std::memory_order_acquire) == 0) {
        return; // every draw comes here
    }
    std::vector<PendingOp> ready;
    {
        std::scoped_lock lock{pending_ops_mutex};
        if (pending_ops.empty()) {
            return;
        }
        // Retired, not just signalled: a deferred destroy releases objects the command buffer
        // may still reference until Metal retires it (the completed handler advances this).
        const u64 retired = retired_tick.load(std::memory_order_acquire);
        while (!pending_ops.empty() && pending_ops.front().gpu_tick <= retired) {
            ready.push_back(std::move(pending_ops.front()));
            pending_ops.pop();
        }
        num_pending_ops.fetch_sub(static_cast<u32>(ready.size()), std::memory_order_release);
    }
    // Outside the lock: an operation may defer another.
    for (PendingOp& op : ready) {
        op.callback();
    }
}

void Scheduler::PriorityPendingOpsThread(std::stop_token stoken) {
    Common::SetCurrentThreadName("bbport:MtlSchedPriorityOps");

    while (!stoken.stop_requested()) {
        PendingOp op;
        {
            std::unique_lock lock{priority_mutex};
            priority_cv.wait(lock, stoken, [this] { return !priority_pending_ops.empty(); });
            if (stoken.stop_requested()) {
                break;
            }
            op = std::move(priority_pending_ops.front());
            priority_pending_ops.pop();
        }
        // Bounded waits, so a stop request is seen (the tick may never be flushed).
        while (!WaitTick(op.gpu_tick, WaitSliceMs * 1000000)) {
            if (stoken.stop_requested() || HasFailed()) {
                break;
            }
        }
        if (stoken.stop_requested() || HasFailed()) {
            // The destructor runs what is left (the operation goes back for it).
            std::scoped_lock lock{priority_mutex};
            priority_pending_ops.push(std::move(op));
            break;
        }
        op.callback();
    }
}

void Scheduler::SetErrorHandler(ErrorHandler handler) {
    std::scoped_lock lock{error_mutex};
    error_handler = std::move(handler);
}

void Scheduler::ReportFailure(u64 tick, const std::string& label, const std::string& what) {
    failed.store(true, std::memory_order_release);
    const std::string report =
        "Metal command buffer '" + label + "' (tick " + std::to_string(tick) + ") failed: " + what;
    ErrorHandler handler;
    {
        std::scoped_lock lock{error_mutex};
        handler = error_handler;
    }
    if (handler) {
        handler(report);
        return;
    }
    // As a lost Vulkan device: say what, then stop.
    std::fprintf(stderr, "%s\n", report.c_str());
    ASSERT_MSG(false, "GPU lost during submit: {}", report);
}

} // namespace Metal
