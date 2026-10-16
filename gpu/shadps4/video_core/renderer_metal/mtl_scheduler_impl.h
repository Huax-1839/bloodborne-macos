// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#ifndef __OBJC__
#error "mtl_scheduler_impl.h is for Objective-C++ (.mm) files only"
#endif

#import <Metal/Metal.h>

#include <array>
#include "video_core/renderer_metal/mtl_device_impl.h"
#include "video_core/renderer_metal/mtl_scheduler.h"

namespace Metal {

struct Scheduler::Impl {
    /// Encoders update one of these at their end; a barrier waits for those not waited yet. More
    /// outstanding encoders than slots: the encoder that reuses a slot waits for it first.
    static constexpr u32 FenceCount = 8;

    Device::Impl& dev;
    id<MTLSharedEvent> event;
    id<MTLCommandBuffer> cmdbuf; ///< open command buffer, nil until something is recorded
    /// The open encoder (the one of Scheduler::OpenEncoder(), the others are nil).
    id<MTLRenderCommandEncoder> render;
    id<MTLComputeCommandEncoder> compute;
    id<MTLBlitCommandEncoder> blit;
    /// The held render pass's descriptor (nil when none is held, Scheduler::ReleaseHeldPass).
    MTLRenderPassDescriptor* held_pass;
    /// The descriptors of the passes the replay thread encodes (Scheduler::replay_ring's slots).
    std::array<MTLRenderPassDescriptor*, Scheduler::ReplayDepth> replay_passes;
    std::array<id<MTLFence>, FenceCount> fences;
    u32 outstanding_fences = 0; ///< bit i: fences[i] was updated and nobody waited for it
    u32 next_fence = 0;         ///< the slot the open (or next) encoder updates at its end

    NSString* name;
    const std::atomic<u64>& tick; ///< the scheduler's current tick (for the command buffer label)

    Impl(Device::Impl& dev_, NSString* name_, const std::atomic<u64>& tick_)
        : dev{dev_}, name{name_}, tick{tick_} {}

    /// The open command buffer; created on first use (the presenter, for one, needs it to
    /// present a drawable).
    id<MTLCommandBuffer> EnsureCommandBuffer();
};

} // namespace Metal
