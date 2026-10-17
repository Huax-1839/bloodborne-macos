# Power and heat on the fanless Air (P11)

Status: 2026-10-17, P11.1 tooling and the AC baseline done (results below); P11.2 diagnosing the game's main thread (plan §5 P11). Lever 3 of
`docs/PERFORMANCE_LEVERS_2026-10-16.md` ("Thermal budget: CPU vs GPU power, then less CPU
power"). Owner of the design, the runs and the analysis: the orchestrator; the measurement tools,
the in-game thread log and the cuts' implementation: porter tasks; log digests: scout tasks.

## Goal

Find out where the MacBook Air's power goes while the game holds its 30-FPS cap, and whether heat
still decides anything after P9.1 and P10.1; then cut the CPU's share where the numbers say it
matters, and give players measured advice (Low Power Mode, charging). The Air has no fan: CPU and
GPU share one thermal budget, so every watt the CPU does not burn is headroom the GPU's clock can
keep (and battery life).

What heat can still decide (plan §8 after P10.1: GPU busy a typical frame ~14.9 ms at 540p,
~18.2 ms at 720p, ~38 ms at native 1080p, all on a cool Air):
- the recording tail behind missed 30-FPS slots: the recording thread ran 2.5–3× slower when it
  lost the performance cores (§8 "P8.6"); 720p at the 30 cap had 2.29% missed slots after P9.1;
- native 1080p at 30 FPS (the stretch goal): 38 ms cool against a 33-ms budget;
- battery life.

Before P9.1/P10.1 the GPU's frame time rose 20–25% within minutes of play (plan §5 P8 step 2),
and charging during a run cost 3.5 FPS by minute 14. Nobody has measured the watts: the power log
of `macos/bench/m1_run.sh` (`power_sample`) holds `pmset` data only (source, charge, Low Power
Mode, `pmset -g therm`).

## Questions P11.1 answers, with numbers

1. How the power splits between CPU (P and E clusters) and GPU at 540p, 720p and native 1080p,
   all at the 30 cap.
2. Whether the GPU clock falls over 20 minutes, and whether `gpu_ms` per flip follows it.
3. Whether the CPU clocks fall, and whether `rec_busy_ms` and the missed slots per minute follow
   them.
4. Which threads burn the CPU at the 30 cap: the game's own (guest) threads, the port's host
   threads (`bb:*`, `shadPS4:*`), Metal's, or the rest of the system.
5. What charging adds (AC with the battery full vs AC while charging vs battery).

P11.2 starts only where the answers show that the CPU's share matters (a large CPU W next to a
falling GPU clock, or missed slots that follow the CPU clock); otherwise it is recorded as not
needed.

## Measurement

### Power, clocks and thermal pressure: `powermetrics`

`powermetrics --samplers cpu_power,gpu_power,thermal -i 1000 -f plist` gives once a second: CPU
power (combined, mW) and per-cluster frequency and idle residency (E and P clusters), GPU power,
GPU frequency and active residency, and the thermal pressure level. The `tasks` sampler adds
per-process wakeups and CPU ms (`--show-process-energy`); it is optional (larger output) and
only for the question whether something outside the game wakes the CPU.

It needs root. The port never works around `sudo`: the user either runs the command printed by
`power.sh` in their own terminal, or allows `sudo -n /usr/bin/powermetrics` for themselves
(a `sudoers` rule they write). Fallback only if they decline: a bench-only tool that reads Apple's
IOReport energy and frequency channels without root (private API, never linked into the game);
it gives energy per cluster and GPU, and the clocks' residency, but no thermal pressure (that
comes from the game log, below).

Tools (porter, bench only):
- `macos/bench/power.sh start <name> | stop <name> | cmd <name>`: starts and stops
  `powermetrics` next to a run, writing `bench-<name>-powermetrics.plist` (NUL-separated plists,
  powermetrics' own `-f plist` stream) and `bench-<name>-powermetrics.start` (wall-clock epoch of
  the start, for samples without a timestamp). With `sudo -n` allowed it starts it itself; else
  it prints the exact command for the user's terminal and waits for the file to grow.
- `macos/bench/powerstats.py` (stdlib `plistlib`): parses the stream; per second: CPU W, E and P
  cluster MHz (residency-weighted active frequency) and active residency, GPU W, GPU MHz and
  active residency, thermal pressure; joins by wall time with the per-flip log
  (`bench-<name>-frames.csv`: `t_s`, `gpu_ms`, `rec_busy_ms`, `frame_ms`, `draws`; its `t_s = 0`
  epoch comes from the game log, below) and the power log (source, charge); reports per minute:
  W (CPU, GPU, package where reported), clocks, residencies, pressure, FPS, mean and p95
  `gpu_ms`, mean and p95 `rec_busy_ms`, missed 30-FPS slots (`frame_ms > 41.7`, as `m3stats.py`),
  charge; plus a summary over the in-game span (flips with 300+ draws) and minutes 0–5 vs 15–20.
  Optional TSV output for the plan's tables.
- `m1_run.sh`: `POWERMETRICS=1` runs `power.sh start` before the boot and `stop` after the walk
  (after the `IDLE_MIN` cool-down, so the idle minutes are recorded too).

### In the game: per-thread CPU time and thermal state (porter, shared code)

- `BB_THREAD_CPU_LOG=<seconds>`: a `bb:ThreadCpu` thread wakes every `<seconds>`, walks
  `task_threads(mach_task_self())`, reads `THREAD_EXTENDED_INFO` (user and system time, name) and
  `THREAD_IDENTIFIER_INFO` (thread id), and prints one game-log line per interval with the CPU %
  (100% = one core) per group and the top threads:
  - `guest`: threads the C runtime created for the game (`runtime_thread.c` keeps their thread
    ids; the game names them);
  - `port`: `bb:*` and `shadPS4:*` host threads (and `bb:hle` attached host threads);
  - `metal`: threads whose names point at Metal, Core Animation or the display link
    (`com.Metal*`, `com.apple.CoreAnimation*`, `CVDisplayLink`, `caulk*`, `AMCP*` …; the list is
    an educated guess and gets corrected from the first logs);
  - `other`: everything else, unnamed threads included.
  With `BB_THREAD_CPU_CSV=<path>` it also writes one row per thread per interval (wall epoch,
  thread id, name, group, user ms, system ms, QoS class) for `powerstats.py` and the scouts.
  Exiting threads drop out between samples (their last interval's time is lost: recorded as a
  known gap, the game's threads live for the whole run).
- Thermal state without root: the thread also reads the system's thermal pressure level
  (`notify_get_state` on `kOSThermalNotificationPressureLevelName`, `<libkern/OSThermalNotification.h>`;
  public C API, the signal `ProcessInfo.thermalState` is derived from) and logs every change with
  the time (`Thermal pressure: nominal -> moderate at t=…`). Chosen over `ProcessInfo` because it
  is C (no Objective-C outside `renderer_metal/`, CLAUDE.md), works on both backends and has the
  same levels powermetrics reports. Logged whenever `BB_THREAD_CPU_LOG` is set, or alone with
  `BB_THERMAL_LOG=1`.
- The frame log's time base: the game log gets one line when `BB_FRAME_LOG` opens
  (`Frame log: t_s=0 at epoch <s.ms>`), so `powerstats.py` can join the per-flip rows by wall time.
- Contention and polling counters for P11.2 (cheap: relaxed atomics on the slow paths only),
  printed with the thread log: `Common::SpinLock` acquisitions that had to spin and the time
  spun; `EqueueInternal::WaitForSmallTimer` loop yields and time in the loop; `thread_once`
  waiter yields; `bbport_copy` yields; the guest's own `sched_yield` calls. These say whether a
  P11.2 candidate burns measurable CPU before anything is changed.

All of it is off by default; the shared files get one-line hooks only. Vulkan is verified with
the switches on (bench + screenshot), since the thread and counters live in shared code.

### Baseline runs (orchestrator; the user for battery, charging, Low Power Mode)

20-min walks (`m1_run.sh … 20`, Metal, `IDLE_MIN=10`), all at the 30 cap, `POWERMETRICS=1`,
`BB_THREAD_CPU_LOG=10`, `BB_THREAD_CPU_CSV`:
1. on AC with the battery full (no charging): `BB_PROFILE=m4air` (540p);
2. the same: `BB_PROFILE=m4air BB_RENDER_RES=1280x720` (720p);
3. the same: native 1080p with `BB_FPS=30`;
4. 720p on AC while charging (the user unplugs beforehand so the battery is below ~80%, or turns
   off optimized charging; macOS holds full batteries at 80–100% without charging);
5. 720p on battery (the user). One battery run at 540p can be the pending M3 battery run under
   the acceptance rule (`IDLE_MIN=10 m1_run.sh m3-<name>-battery metal 20 BB_PROFILE=m4air`, then
   `m3stats.py --expect battery`) with `POWERMETRICS=1` added: the extra sampler costs well under
   1% of a core (to be checked in run 1's thread log), and the rule does not depend on it.

Before every run: `pgrep -fl bb-probe` (one game instance), an otherwise idle machine. Logs stay
in `~/Games/Bloodborne/bench/runs`; a scout digests each game log and thread CSV; the
orchestrator reads only `powerstats.py`'s summaries.

## P11.2 CPU power cuts (only where P11.1 points)

Candidates (re-verified 2026-10-17 against `main` at 1199219):

| # | Site | Today | Cut |
|---|---|---|---|
| C1 | `video_core/page_manager.cpp:535-539`, `buffer_cache/region_manager.h:27-31` | macOS lacks `PTHREAD_ADAPTIVE_MUTEX_INITIALIZER_NP`, so both use `Common::SpinLock` (`common/spin_lock.cpp:36-40`: unbounded `pause`, no yield, no priority donation) | a lock that parks and donates priority: `os_unfair_lock` if every unlock happens on the owning thread (it aborts otherwise), else a `pthread_mutex` (macOS mutexes spin briefly, then park; `PTHREAD_PRIO_INHERIT` for donation). Measure the contention first (counter above) |
| C2 | `core/libraries/kernel/equeue.cpp:282-310` (`WaitForSmallTimer`, threshold `:31`, 1.2 ms) | `yield` in a loop while a high-resolution timer under 1.2 ms is pending; at timeout 0 until it fires | sleep until shortly before the earliest deadline (≈ 200 µs early, `nanosleep`), then yield-spin the rest; still bounded by the caller's timeout |
| C3 | `src/runtime_kernel.c:228-243` (`thread_once`) | waiters `sched_yield` while another thread runs the routine | block on a condition (a global mutex + condition broadcast on completion; once routines are rare) |
| C4 | `gpu/shim/bbport_copy.cpp:94` (idle worker), `:112` (`Run` waiting for its job) | `yield` while copies finish / while idle | the waiter blocks on a condition or a futex-style wait on `done`; idle workers already have a condition (check why `:94` yields) |
| C5 | `src/runtime_kernel.c:162` (the game's `sched_yield`) and its short sleeps | passed through | only if the thread log shows guest threads spinning; a change to game timing, measured with care |

Trade-offs to measure, not change blindly:
- T1: the frame's host threads at user-interactive QoS (b0a3d62; `BB_PIPELINE_QOS=0` turns it
  off): fewer missed slots, but possibly more watts (P cores, higher clocks);
- T2: the bounded spins in `renderer_metal/mtl_scheduler.mm` (~381, ~433: 4096/2048 pauses, then a
  futex);
- T3: the number of `bb:Copy` threads.

Implementation (porter at effort high: these are synchronization changes). Each kept cut gets an
off switch (`BB_CUT_<NAME>=0`, read once). Shared code (page manager, region manager, kernel
emulation) is verified on Vulkan too (bench + screenshot).

Measurement of each cut: interleaved boots A B B A on the 720p walk at the 30 cap (20 min each,
`IDLE_MIN=10`, `POWERMETRICS=1`). Metrics: CPU W at the same FPS, missed slots and the tail
(`m3stats.py`, whole runs as in `missab.sh`), GPU MHz in minutes 15–20. **Keep** a cut when CPU W
falls by more than the A/A spread and missed slots do not get worse; otherwise record it as
measured and revert. Cuts that can be switched within one run (the toggle file) may use a
within-run A/B first to decide whether the boots are worth it.

## P11.3 Advice for players (the user's runs)

- Low Power Mode on vs off at 540p and 720p (30 cap): does it still hold 30? Missed slots, W,
  battery % per 20 min.
- AC while charging vs AC with the battery full vs battery: GPU MHz and W over 20 minutes.

The result goes as short advice into `macos/HANDOFF.md` and the README's macOS section (e.g.
"play at 540p on battery with Low Power Mode if …", "charging costs N FPS at 720p: pause
charging or …").

## Risks

- `powermetrics`' plist keys differ between macOS versions and chips (per-cluster power is not
  reported on every Apple silicon generation): the parser reads what is there and says what is
  missing; the first real sample fixes the key list.
- Under Rosetta the thread times include translation; the groups still compare.
- The sampler itself costs CPU: measured by the thread log of run 1 (`powermetrics` shows in the
  `tasks` sampler, if enabled).
- Heat and charging state vary between runs more than many cuts move: hence A B B A, the A/A
  spread as the bar, and the same cool-down for every run.

## Results

Full tables in plan §8 "P11 results". AC baseline (2026-10-17, battery full, 30 cap):
- 540p / 720p: CPU 5.7–5.8 W, GPU 1.2–1.4 W, package 7.1–7.4 W (CPU ~80%). The P cluster is
  100% active at ~4 GHz. The GPU clock falls ~20% over 20 min and `gpu_ms` follows it, at no FPS
  cost (missed slots 0.5–0.8%).
- Native 1080p: 13 W in minute 1, then heavy pressure and a ~7 W package. The CPU is cut first
  (P cluster 3.9 → 1.45 GHz, `rec_busy_ms` ×2, missed slots 20%), then the GPU (−11% clock).
- The candidates C1–C4 never fire in play (all counters 0). The CPU's power is the game's `main`
  thread, at ~98% of a P core. Whether it spins or computes: guest-PC sampler, next.
