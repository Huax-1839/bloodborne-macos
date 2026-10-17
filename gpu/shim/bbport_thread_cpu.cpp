// SPDX-License-Identifier: GPL-2.0-or-later
// bbport: per-thread CPU time, thermal pressure and polling counters (see bbport_thread_cpu.h).
#include "bbport_thread_cpu.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include <libkern/OSThermalNotification.h>
#include <mach/mach.h>
#include <notify.h>

#include "common/thread.h"

extern "C" {
// runtime_thread.c: OS thread ids of the live game threads.
size_t runtime_thread_guest_ids(uint64_t* out, size_t max);
// runtime_kernel.c: cumulative once yields, guest sched_yields, short sleeps, their requested ns.
void runtime_poll_counters(uint64_t out[4]);
}

namespace BbThreadCpu {
namespace {

using Clock = std::chrono::steady_clock;

double Epoch() {
    return std::chrono::duration<double>(std::chrono::system_clock::now().time_since_epoch())
        .count();
}

struct Entry {
    std::uint64_t tid;
    std::string name;
    Group group;
    std::uint64_t user_ns, sys_ns; // deltas
    int priority;
};

struct Totals {
    std::uint64_t user_ns{}, sys_ns{};
};

struct Counters {
    std::uint64_t v[11]{};
};

Counters ReadCounters() {
    Counters c;
    std::uint64_t runtime[4];
    runtime_poll_counters(runtime);
    c.v[0] = poll.spin_contended.load(std::memory_order_relaxed);
    c.v[1] = poll.spin_ns.load(std::memory_order_relaxed);
    c.v[2] = poll.small_timer_calls.load(std::memory_order_relaxed);
    c.v[3] = poll.small_timer_yields.load(std::memory_order_relaxed);
    c.v[4] = poll.small_timer_ns.load(std::memory_order_relaxed);
    c.v[5] = poll.copy_idle_yields.load(std::memory_order_relaxed);
    c.v[6] = poll.copy_run_yields.load(std::memory_order_relaxed);
    c.v[7] = runtime[0];
    c.v[8] = runtime[1];
    c.v[9] = runtime[2];
    c.v[10] = runtime[3];
    return c;
}

const char* ThermalName(std::uint64_t level, char* buffer, std::size_t size) {
    switch (level) {
    case kOSThermalPressureLevelNominal:
        return "nominal";
    case kOSThermalPressureLevelModerate:
        return "moderate";
    case kOSThermalPressureLevelHeavy:
        return "heavy";
    case kOSThermalPressureLevelTrapping:
        return "trapping";
    case kOSThermalPressureLevelSleeping:
        return "sleeping";
    default:
        std::snprintf(buffer, size, "%llu", static_cast<unsigned long long>(level));
        return buffer;
    }
}

class Sampler {
public:
    Sampler(double interval_s, bool cpu, FILE* csv) : interval_s_(interval_s), cpu_(cpu), csv_(csv) {}

    void Run() {
        int token = 0;
        bool thermal = notify_register_check(kOSThermalNotificationPressureLevelName, &token) ==
                       NOTIFY_STATUS_OK;
        if (!thermal) {
            std::printf("Thermal pressure: not available\n");
            std::fflush(stdout);
        }
        bool have_level = false;
        std::uint64_t level = 0;
        auto next_sample = Clock::now() + std::chrono::duration_cast<Clock::duration>(
                                              std::chrono::duration<double>(interval_s_));
        if (cpu_) {
            Sample(); // primes the deltas
        }
        for (;;) {
            if (thermal) {
                std::uint64_t state = 0;
                if (notify_get_state(token, &state) == NOTIFY_STATUS_OK &&
                    (!have_level || state != level)) {
                    char old_buffer[24], new_buffer[24];
                    std::printf("Thermal pressure: %s -> %s at epoch %.3f\n",
                                have_level ? ThermalName(level, old_buffer, sizeof(old_buffer))
                                           : "unknown",
                                ThermalName(state, new_buffer, sizeof(new_buffer)), Epoch());
                    std::fflush(stdout);
                    have_level = true;
                    level = state;
                }
            }
            const auto now = Clock::now();
            if (cpu_ && now >= next_sample) {
                Sample();
                next_sample = now + std::chrono::duration_cast<Clock::duration>(
                                        std::chrono::duration<double>(interval_s_));
            }
            Clock::duration step = std::chrono::seconds(1);
            if (cpu_) {
                step = std::min<Clock::duration>(step, std::max<Clock::duration>(
                                                           next_sample - Clock::now(),
                                                           std::chrono::milliseconds(10)));
            }
            std::this_thread::sleep_for(step);
        }
    }

private:
    void Sample() {
        const auto now = Clock::now();
        std::vector<Entry> entries;
        // Thread ids of the game threads, taken before the walk.
        std::vector<std::uint64_t> guests(1024);
        guests.resize(runtime_thread_guest_ids(guests.data(), guests.size()));

        thread_act_array_t threads = nullptr;
        mach_msg_type_number_t count = 0;
        if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) {
            return;
        }
        std::unordered_map<std::uint64_t, Totals> current;
        for (mach_msg_type_number_t i = 0; i < count; ++i) {
            thread_identifier_info_data_t ident{};
            mach_msg_type_number_t ident_count = THREAD_IDENTIFIER_INFO_COUNT;
            thread_extended_info_data_t info{};
            mach_msg_type_number_t info_count = THREAD_EXTENDED_INFO_COUNT;
            if (thread_info(threads[i], THREAD_IDENTIFIER_INFO,
                            reinterpret_cast<thread_info_t>(&ident), &ident_count) ==
                    KERN_SUCCESS &&
                thread_info(threads[i], THREAD_EXTENDED_INFO, reinterpret_cast<thread_info_t>(&info),
                            &info_count) == KERN_SUCCESS) {
                const std::uint64_t tid = ident.thread_id;
                info.pth_name[sizeof(info.pth_name) - 1] = 0;
                const Totals now_totals{info.pth_user_time, info.pth_system_time};
                Entry entry;
                entry.tid = tid;
                entry.name = info.pth_name;
                entry.group = Classify(entry.name, std::find(guests.begin(), guests.end(), tid) !=
                                                       guests.end());
                // A thread new since the last sample ran for its whole life inside the interval.
                const auto known = previous_.find(tid);
                const Totals base = known != previous_.end() ? known->second : Totals{};
                entry.user_ns = now_totals.user_ns - std::min(base.user_ns, now_totals.user_ns);
                entry.sys_ns = now_totals.sys_ns - std::min(base.sys_ns, now_totals.sys_ns);
                entry.priority = info.pth_curpri;
                entries.push_back(std::move(entry));
                current[tid] = now_totals;
            }
            mach_port_deallocate(mach_task_self(), threads[i]);
        }
        vm_deallocate(mach_task_self(), reinterpret_cast<vm_address_t>(threads),
                      count * sizeof(thread_act_t));

        // Exited threads drop out here; their last interval is lost.
        previous_ = std::move(current);

        const Counters counters = ReadCounters();
        const double elapsed_s = std::chrono::duration<double>(now - last_).count();
        const Counters before = last_counters_;
        last_ = now;
        last_counters_ = counters;
        if (!have_previous_) {
            have_previous_ = true;
            return;
        }
        Print(entries, elapsed_s, counters, before);
    }

    void Print(std::vector<Entry>& entries, double elapsed_s, const Counters& now,
               const Counters& before) {
        const double ns = elapsed_s * 1e9;
        double group[4] = {};
        for (Entry& entry : entries) {
            if (entry.name.empty()) {
                entry.name = "tid" + std::to_string(entry.tid);
            }
            group[static_cast<int>(entry.group)] += double(entry.user_ns + entry.sys_ns) * 100.0 / ns;
        }
        std::sort(entries.begin(), entries.end(), [](const Entry& a, const Entry& b) {
            return a.user_ns + a.sys_ns > b.user_ns + b.sys_ns;
        });
        std::string top;
        for (std::size_t i = 0; i < entries.size() && i < 6; ++i) {
            const double percent = double(entries[i].user_ns + entries[i].sys_ns) * 100.0 / ns;
            if (percent < 0.05) {
                break;
            }
            char item[96];
            std::snprintf(item, sizeof(item), "%s%s %.1f%%", i ? ", " : "", entries[i].name.c_str(),
                          percent);
            top += item;
        }
        std::printf("Thread CPU (%.1f s): guest %.1f%% port %.1f%% metal %.1f%% other %.1f%% "
                    "total %.1f%%; top: %s (%zu threads)\n",
                    elapsed_s, group[0], group[1], group[2], group[3],
                    group[0] + group[1] + group[2] + group[3], top.c_str(), entries.size());
        auto d = [&](int i) { return now.v[i] - before.v[i]; };
        std::printf("Poll counters (%.1f s): spinlock %llu contended, %.1f ms spun; "
                    "smalltimer %llu waits, %llu yields, %.1f ms; once %llu yields; "
                    "copy idle %llu / run %llu yields; guest sched_yield %llu, "
                    "short sleeps %llu (%.1f ms requested)\n",
                    elapsed_s, (unsigned long long)d(0), d(1) / 1e6, (unsigned long long)d(2),
                    (unsigned long long)d(3), d(4) / 1e6, (unsigned long long)d(7),
                    (unsigned long long)d(5), (unsigned long long)d(6), (unsigned long long)d(8),
                    (unsigned long long)d(9), d(10) / 1e6);
        std::fflush(stdout);
        if (csv_) {
            const double epoch = Epoch();
            for (const Entry& entry : entries) {
                std::string name = entry.name;
                std::replace(name.begin(), name.end(), ',', ';');
                std::fprintf(csv_, "%.3f,%.3f,%llu,%s,%s,%.3f,%.3f,%d\n", epoch, elapsed_s,
                             (unsigned long long)entry.tid, name.c_str(), GroupName(entry.group),
                             entry.user_ns / 1e6, entry.sys_ns / 1e6, entry.priority);
            }
            std::fflush(csv_);
        }
    }

    double interval_s_;
    bool cpu_;
    FILE* csv_;
    bool have_previous_ = false;
    Clock::time_point last_;
    Counters last_counters_;
    std::unordered_map<std::uint64_t, Totals> previous_;
};

} // namespace

void Start() {
    double interval_s = 0;
    if (const char* env = std::getenv("BB_THREAD_CPU_LOG")) {
        interval_s = std::atof(env);
    }
    const char* thermal_env = std::getenv("BB_THERMAL_LOG");
    const bool thermal = thermal_env && *thermal_env && *thermal_env != '0';
    const bool cpu = interval_s > 0;
    if (!cpu && !thermal) {
        return;
    }
    interval_s = std::max(interval_s, 0.1);
    FILE* csv = nullptr;
    if (cpu) {
        if (const char* path = std::getenv("BB_THREAD_CPU_CSV"); path && *path) {
            csv = std::fopen(path, "w");
            if (csv) {
                std::fprintf(csv, "epoch_s,interval_s,tid,name,group,user_ms,sys_ms,priority\n");
                std::fflush(csv);
            }
        }
    }
    std::thread([interval_s, cpu, csv] {
        Common::SetCurrentThreadName("bb:ThreadCpu");
        Sampler(interval_s, cpu, csv).Run();
    }).detach();
}

} // namespace BbThreadCpu
