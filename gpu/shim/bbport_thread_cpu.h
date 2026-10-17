// SPDX-License-Identifier: GPL-2.0-or-later
// bbport: where the CPU time goes, per thread and per group, plus the thermal pressure level and
// counters for the polling loops (P11.1, docs/metal/power_budget_design.md). Everything is off
// by default; the counters are relaxed atomics on slow paths only and count unconditionally.
//
// Environment switches (game log = stdout):
//   BB_THREAD_CPU_LOG=<seconds>   a bb:ThreadCpu thread walks task_threads() every <seconds>
//                                 (float ok, e.g. 10) and prints
//                                   Thread CPU (10.0 s): guest 152.3% port 88.1% metal 12.0%
//                                     other 9.4% total 261.8%; top: <name> 60.1%, ... (8 threads)
//                                   Poll counters (10.0 s): spinlock <n> contended, <ms> ms spun;
//                                     smalltimer <calls> waits, <yields> yields, <ms> ms; once <n>
//                                     yields; copy idle <n> / run <n> yields; guest sched_yield <n>,
//                                     short sleeps <n> (<ms> ms requested)
//                                 (100% = one core; every figure is the delta over the interval;
//                                 the first sample only primes the deltas). Also reads the thermal
//                                 pressure level once a second.
//   BB_THREAD_CPU_CSV=<path>      with BB_THREAD_CPU_LOG: one row per thread per interval,
//                                   epoch_s,interval_s,tid,name,group,user_ms,sys_ms,priority
//                                 (user_ms and sys_ms are the interval's deltas, priority is the
//                                 thread's current scheduling priority; commas in names become ';').
//   BB_THERMAL_LOG=1              only the thermal pressure level, without the CPU sampling:
//                                   Thermal pressure: <old> -> <new> at epoch <s.ms>
//                                 for the first reading (old = unknown) and every change; levels
//                                 nominal, moderate, heavy, trapping, sleeping (other numbers as is).
// Epochs are wall-clock seconds, the same time base as the frame log line
// `Frame log: t_s=0 at epoch <s.ms>` (BB_FRAME_LOG).
#pragma once

#include <atomic>
#include <cstdint>
#include <string_view>

namespace BbThreadCpu {

/// Cumulative polling and contention counters (the thread log prints their deltas).
struct PollCounters {
    // Common::SpinLock::lock acquisitions whose first attempt failed, and the ns spent spinning.
    std::atomic<std::uint64_t> spin_contended{0};
    std::atomic<std::uint64_t> spin_ns{0};
    // EqueueInternal::WaitForSmallTimer: calls, loop yields, ns inside the function.
    std::atomic<std::uint64_t> small_timer_calls{0};
    std::atomic<std::uint64_t> small_timer_yields{0};
    std::atomic<std::uint64_t> small_timer_ns{0};
    // bbport_copy.cpp: yields of a thread waiting for the pool to drain (WaitAll, "idle") and of
    // Run waiting for its job's indices to finish.
    std::atomic<std::uint64_t> copy_idle_yields{0};
    std::atomic<std::uint64_t> copy_run_yields{0};
};
inline PollCounters poll;

enum class Group { Guest, Port, Metal, Other };

inline constexpr const char* GroupName(Group group) {
    switch (group) {
    case Group::Guest:
        return "guest";
    case Group::Port:
        return "port";
    case Group::Metal:
        return "metal";
    default:
        return "other";
    }
}

// Thread-name prefixes (case-sensitive). A first guess, to be corrected from the first logs.
inline constexpr std::string_view PortPrefixes[] = {"bb:", "shadPS4"};
inline constexpr std::string_view MetalPrefixes[] = {
    "com.Metal",       "com.apple.Metal", "com.apple.CoreAnimation", "CVDisplayLink",
    "caulk",           "com.apple.coreanimation", "AMCP", "com.apple.audio"};

/// `guest`: the C runtime registered the thread as a game thread (it wins over the name).
inline constexpr Group Classify(std::string_view name, bool guest) {
    if (guest) {
        return Group::Guest;
    }
    for (const std::string_view prefix : PortPrefixes) {
        if (name.substr(0, prefix.size()) == prefix) {
            return Group::Port;
        }
    }
    for (const std::string_view prefix : MetalPrefixes) {
        if (name.substr(0, prefix.size()) == prefix) {
            return Group::Metal;
        }
    }
    return Group::Other;
}

/// Starts the sampling thread when BB_THREAD_CPU_LOG or BB_THERMAL_LOG asks for it (bbgpu_init).
void Start();

} // namespace BbThreadCpu
