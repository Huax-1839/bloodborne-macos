// SPDX-License-Identifier: GPL-2.0-or-later
// bbport_thread_cpu.h: thread name to group classification for BB_THREAD_CPU_LOG.
#include <cassert>
#include <cstring>
#include "bbport_thread_cpu.h"

using BbThreadCpu::Classify;
using BbThreadCpu::Group;

int main() {
    // Registered game threads are guests whatever their name.
    assert(Classify("", true) == Group::Guest);
    assert(Classify("bb:hle", true) == Group::Guest);
    assert(Classify("com.Metal.CompletionQueueDispatch", true) == Group::Guest);
    // The port's own threads.
    assert(Classify("bb:ThreadCpu", false) == Group::Port);
    assert(Classify("bb:hle", false) == Group::Port);
    assert(Classify("shadPS4:GpuCommandProcessor", false) == Group::Port);
    assert(Classify("shadPS4", false) == Group::Port);
    // Metal, Core Animation, display link, audio.
    assert(Classify("com.Metal.CompletionQueueDispatch", false) == Group::Metal);
    assert(Classify("com.apple.Metal.gpu", false) == Group::Metal);
    assert(Classify("com.apple.CoreAnimation.render-server", false) == Group::Metal);
    assert(Classify("com.apple.coreanimation.x", false) == Group::Metal);
    assert(Classify("CVDisplayLink", false) == Group::Metal);
    assert(Classify("caulk.messenger.shared:17", false) == Group::Metal);
    assert(Classify("AMCP-IO", false) == Group::Metal);
    assert(Classify("com.apple.audio.IOThread.client", false) == Group::Metal);
    // Everything else, unnamed included; matching is case-sensitive and anchored at the start.
    assert(Classify("", false) == Group::Other);
    assert(Classify("BB:upper", false) == Group::Other);
    assert(Classify("xbb:late", false) == Group::Other);
    assert(Classify("com.apple.NSEventThread", false) == Group::Other);
    assert(Classify("com.metal", false) == Group::Other);
    assert(std::strcmp(BbThreadCpu::GroupName(Group::Metal), "metal") == 0);
    return 0;
}
