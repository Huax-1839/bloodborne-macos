# Central Yharnam benchmark (2026-10-18)

Status: measured, 2026-10-18, MacBook Air M4 (10-core GPU, 16 GB) **on AC power only** (battery
full, not charging), `main` at b8fa02a; P13.1 (§4) was built during the session as a switch and made the default at
the end (`BB_MTL_RELAX_VERTEX=0` off).
Save: `BENCH_SAVE=pristine-savedata-yharnam` (the lamp-side street of Central Yharnam, 1168 draws
a frame at 540p against ~750 in the clinic). Metal unless named, `BB_PROFILE=m4air` (540p scene,
MetalFX to 1080p) unless named. Runs: `macos/bench/bench.sh` boots (6 five-second windows after
90 s in game, per-flip log `BB_FRAME_LOG`, `BB_THREAD_CPU_LOG=10`), interleaved A/B with 150-180 s
cool-down between runs (60 s was not enough: the Air reached heavy thermal pressure within two
runs), Metal System Traces (`tracesub.sh`, `BB_PASS_LABELS=1`), 10-min walks (`m1_run.sh` with
powermetrics). Data: `~/Games/Bloodborne/bench/runs/bench-yh-*` and `.../traces/*yh-*`.

## Summary

1. **Yharnam is GPU-bound, and the GPU time is vertex work.** At 540p uncapped the GPU needs
   20.8-21.2 ms a frame (clinic ~15), recording only 8.7-9 ms. The G-buffer passes alone take
   ~14 ms, of which **12.6 ms on the vertex channel and 1.7 ms on the fragment channel**; going
   from 540p to 720p (1.78x the pixels) adds only 3.6 ms. Resolution is not the lever.
2. **Relaxed vertex shaders with an invariant position (plan P13.1, now the default;
   `BB_MTL_RELAX_VERTEX=0` off): GPU 21.2 -> 14.6 ms, 41.8 -> 57.7 FPS at 540p (+38%), 38.1 -> 52.0 FPS at 720p
   (+36%).** The game's vertex shaders still run every float op through `[[clang::optnone]]`
   helpers (P9.1 left them strict for depth-equal passes); `[[position, invariant]]` with
   `MTLCompileOptions.preserveInvariance` gives that guarantee instead. G-buffer vertex time
   12.6 -> 4.6 ms. Images, temporal residuals, the validation layer and Vulkan unchanged (§4,
   §7). By far the largest lever found.
3. **MetalFX temporal costs ~3 ms a frame** (21.1 -> 18.1 ms without upscaler, +5 FPS); a
   1280x720 output saves only 1 ms of it. After (2) it is the largest single item (~20% of the
   frame).
4. **At the 30 cap the Air holds 720p in Yharnam on AC** (10-min walk: 29.93 FPS, 1.29% missed
   slots, the M3 rule allows 2%), and the **CPU draws more than the GPU** (3.7 W vs 2.9 W, P
   cores at ~4 GHz, 57% active).
5. **Uncapped on a warm Air the limit moves to the CPU**: from minute 2 of a walk the P cores
   drop to ~1 GHz under heavy thermal pressure, recording goes 7 -> 22 ms a frame and the frame
   rate settles at 43-47 FPS (540p) while the GPU is not the limit.
6. Game settings: `model_lod=2` saves 1.8 ms (visible: lower detail); SSAO + dynamic shadows cost
   only ~1 ms here; game AA and chromatic aberration ~0; the "1080p Light Grid" patch is 1 ms
   **slower**. Relaxed math -0.3 ms. `BB_FRAMES_AHEAD=2` does not reduce missed slots.
7. Missed slots at the cap (1-3% in boots) come with ~15 ms longer `gpu_ms` but no more GPU work
   in the traces: open (§6).

## 1. Baseline (540p/720p, uncapped and capped)

| run (Metal unless noted) | FPS | GPU ms med / p90 | recording ms med | thermal at end |
|---|---|---|---|---|
| 540p uncapped #1 / #2 | 42.6 / 41.6 | 20.8 / 21.1, 20.9 / 23.2 | 8.7 / 9.1 | nominal / heavy |
| 720p uncapped #1 / #2 | 39.1 / 36.3 | 24.4 / 24.7, 24.7 / 28.1 | 9.1 / **23.6** | nominal / heavy |
| Vulkan 540p uncapped #1 / #2 | 26.3 / 24.7 | - | 6.3 / 8.8 | nominal / heavy |
| 540p capped #1 / #2 | 29.9 / 29.9 | 23.0 / 27.3, 23.0 / 24.9 | 8.3 / 8.4 | |
| 720p capped #1 / #2 | 29.9 / 29.8 | 25.1 / 26.8, 25.2 / 28.5 | 8.4 / 8.5 | |

- Metal is 1.6x Vulkan in Yharnam (the clinic: 1.1x at M2; P9.1 and P10.1 are Metal only).
- The second 720p run reached heavy pressure: the P cores were parked and recording tripled,
  which cost 3 FPS although the GPU time did not change. Uncapped A/Bs need long cool-downs.
- Capped missed slots (frames > 40 ms, after the first 20 s): 1.11 / 2.03% at 540p, 1.02 /
  2.98% at 720p; the slow frames have `gpu_ms` 38-42 ms against 23-25 typical (§6).

## 2. Where the GPU time goes (trace, 540p and 720p uncapped)

GPU ms a frame by channel (`BB_PASS_LABELS=1`, union of the process's GPU rows; the trace itself
slows the frame, the per-pass numbers are not affected):

| | 540p | 720p | 540p relaxed vertex |
|---|---|---|---|
| all channels, sum | 24.9 (V 13.5, F 5.8, C 5.6) | 26.3 (V 12.4, F 7.3, C 6.6) | 16.0 (V 5.3, F 5.3, C 5.4) |
| G-buffer passes (`C6 D`) | **14.3 (V 12.6, F 1.7)** | 13.5 (V 11.6, F 1.9) | **6.1 (V 4.6, F 1.5)** |
| MetalFX (Pre/Mid/Post + an unlabelled compute) | 1.9 + 2.3 | 2.2 + 2.5 | 2.0 + 2.2 |
| post passes (`C1`, `C1 D`), lighting (`C2 D`) | 1.9, 0.6 | 2.7, 0.8 | 1.6, 0.5 |
| tiling chain (`DispatchTiling`) | 0.5 | 0.8 | |
| shadow map 4096² (`C1 D`) | 0.4 | 0.4 | |

- The "(unlabelled blit)" of `mtltrace.py` is one Compute-channel encoder per frame between
  `MetalFX_Temporal_MidProcessing` and the 1080p post passes, in the app's own command buffer:
  MetalFX's internal encoding (no app call site opens a blit there). MetalFX in total ~4.1 ms by
  trace, ~3.0 ms by A/B (§5).
- The heaviest vertex shaders (`7620368b`, `9da6aacb`, `803b9d24`, `a7450683`, `b57af00c`;
  skinned or instanced geometry reading bone/instance matrices from buffers) had 104-189 `spvF*`
  helper calls each.

## 3. Game settings (720p uncapped, A/B x2, GPU ms med)

| variant (over m4air) | GPU ms | FPS | image vs base |
|---|---|---|---|
| base | 24.7, 24.5 | 37.8, 38.9 | same-build pair 34.3 dB |
| `effect_game_aa=0` | 24.1, 24.8 | 39.3, 38.0 | 27.0 dB (AA edges) |
| `effect_chromatic_aberration=0` | 24.2, 24.4 | 39.4, 39.1 | |
| `model_lod=2` | **22.7, 22.9** | **42.0, 41.8** | 26.2 dB, 698 tiles over: visibly lower detail (relief, statues) |
| `1080p Light Grid` patch | 25.6, 25.6 | 37.0, 37.3 | 130 fewer draws, slower |
| SSAO and dynamic shadows on | 25.8, 25.4 | 37.3, 37.7 | |
| `BB_MTL_RELAXED_MATH=1` (separate A/B) | 24.0, 24.2 vs 24.5, 24.4 | 39.7, 39.5 vs 39.0, 39.1 | |

## 4. Relaxed vertex shaders (`BB_MTL_RELAX_VERTEX=1`)

What it does (gpu/shadps4/...: `profile.h`, `emit_spirv_floating_point.cpp`,
`spirv_emit_context.cpp`, `mtl_shader.mm`, `mtl_pipeline_cache.mm`): hardware vertex shaders that
feed the rasterizer directly (sw Vertex on hw Vertex; ES/LS for geometry-shader emulation and
tessellation, tessellation evaluation and geometry stay strict) are emitted without
`NoContraction`; their Position output is decorated `Invariant` (SPIRV-Cross:
`[[position, invariant]]`) and their libraries are built with `preserveInvariance = YES`. Own
pipeline cache (`<title>-metal-relaxed-vs`) and binary archive (`relaxed-vs/`); MSL cache entries
are keyed by the SPIR-V hash. Default on since the checks below (`BB_MTL_RELAX_VERTEX=0` off);
Vulkan never sets the profile flag.

| interleaved A B B A (540p uncapped) | FPS | GPU ms med |
|---|---|---|
| default | 41.9, 41.6 | 21.2 |
| relaxed vertex | 57.9, 57.5 | 14.6 |
| 720p default / relaxed | 38.1 / 52.0 | |

Images: Yharnam in game 33.1 dB against the default (same-build pairs 34.3 dB), title 51.7 dB
(animated tiles only); clinic 38.1 dB against the default, 35.2 dB against the Vulkan reference
(default 33.6); no z-fighting, holes or flicker seen in the screenshots. A 5-min Yharnam walk with
`MTL_DEBUG_LAYER=1`: no validation errors, 30 FPS. Vulkan after the change: 26.0 FPS (before
26.3 / 24.7), title 69.2 dB against the run before. Temporal residuals: §7.
Uncapped 720p with it (52 FPS) is faster than 540p without it (42).

## 5. Upscaler (540p uncapped, A/B x2)

| | GPU ms | FPS |
|---|---|---|
| MetalFX temporal to 1080p (default) | 21.1, 21.2 | 41.8, 41.4 |
| `BB_UPSCALER=none` | 18.1, 18.1 | 46.8, 46.7 |
| MetalFX to `BB_OUTPUT_RES=1280x720` | 20.2, 20.2 | 43.6, 43.6 |

## 6. Power, heat and pacing (10-min walks with powermetrics)

| | 720p capped | 540p uncapped |
|---|---|---|
| FPS | 29.93 (missed slots 1.29%) | 49-56 in minutes 0-1, 43-47 from minute 2 |
| CPU / GPU / package W | 3.7 / 2.9 / 6.8 | 5.7-6.1 / 7.7-8.6 / 13.5-14.8 -> 1.0-1.5 / 4.1-5.9 / 5.1-7.4 |
| P cores | 57% active, ~4.0 GHz | ~1.0 GHz from minute 2 |
| GPU MHz, active | 1269, 70% | 1440-1470, 98% |
| `gpu_ms` / `rec_busy_ms` | 19.9 / 6.3 | 14.7-17.4 / 7-8 -> 18-19 / 21-23 |
| thermal pressure | nominal-moderate | heavy from minute 2 |

Missed slots at the cap: the slow frames' `gpu_ms` (union of the command buffers' GPU intervals)
is ~15 ms higher, recording, compiles, allocations and the guest are unchanged, and the frame was
ready ~16 ms (one vblank) earlier relative to its flip. 10-s traces at the cap show no frame with
more GPU work than ~25 ms, and the only GPU-side waits are the present queue's on the draw
queue's event. So the GPU interval stretches without more work: not explained yet (candidates:
the GPU shared with WindowServer composition, a clock step down while the GPU idles at the cap,
a wait inside a command buffer). `BB_FRAMES_AHEAD=2` did not change the rate (0.89-0.98% vs
0.97-1.17%).

## 7. Temporal image check

`temporal_check.sh` in Yharnam (`SEQS="dpan strafe"`), A B A B, residual of each frame against
the previous one moved by the measured motion (higher = steadier):

| | dpan res4 | strafe res4 |
|---|---|---|
| default | 34.43, 34.70 dB | 26.63, 27.24 dB |
| relaxed vertex | 34.48, 34.56 dB | 26.82, 26.80 dB |

Within the default's own spread: no added shimmer or flicker in motion.

## 8. Levers, ranked for the Air

| # | Lever | Measured effect (Yharnam) | Image | Next step |
|---|---|---|---|---|
| 1 | Relaxed vertex shaders (P13.1) | GPU -6.6 ms (-31%), +38% FPS uncapped | same-build spread | **done, the default**; watch other areas (DLC, Cathedral Ward) for depth-equal artefacts |
| 2 | Cheaper upscaling (MetalFX spatial, or temporal only in the Quality preset) | up to -3 ms | spatial is less stable | measure spatial + game AA; the user's choice |
| 3 | Back to 720p for the m4air profile (with 1) | 52 FPS uncapped at 720p | sharper | 20-min M3 run at 720p capped, on battery too |
| 4 | Recording cost per draw (CPU), for uncapped play on a warm Air | recording 7 -> 22 ms when the P cores park | none | profile `bb:DrawRec` (BindResources, SetupDraw, ReleaseHeldPass) under heat |
| 5 | CPU power at the cap (3.7 W > GPU 2.9 W) | heat headroom for the GPU, battery | none | per-thread split of the 3.7 W (guest vs port) |
| 6 | Spend the gain on quality: SSAO + dynamic shadows (~1 ms) | +1 ms | better | the user's choice |
| 7 | `model_lod=2` | -1.8 ms | visibly worse | only as a "performance" option |
| - | game AA off, chromatic aberration off, light grid patch, relaxed math, `BB_FRAMES_AHEAD=2` | 0 to +1 ms | | drop |
