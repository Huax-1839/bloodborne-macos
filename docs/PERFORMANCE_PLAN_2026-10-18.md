# Performance plan after the Yharnam benchmark (2026-10-18)

The levers the Central Yharnam benchmark left (`docs/PERFORMANCE_YHARNAM_2026-10-18.md`, its §8),
as four phases for the next sessions. They continue `docs/METAL_BACKEND_PLAN.md` as **P14–P17**:
that plan's §0 (how binding), §6 (verification) and the working model in `CLAUDE.md` (Opus
orchestrates and decides **O** tasks, `porter` takes **S** tasks, `scout` reads logs and traces)
apply unchanged. Each phase ends with its results in the plan's §8, its decisions in §9, the
state in `macos/HANDOFF.md`, a commit per verified step and a push at the end of the phase.

## Start here

- State at the start: `main` at 258ec4f. P13.1 (the game's vertex shaders without
  `NoContraction`, invariant position) is the Metal default since 77a4bf4: Central Yharnam at
  540p uncapped 57.7 FPS (GPU 14.6 ms a frame), 720p 52.0 FPS, on AC.
- Read first: this file; the report's §1–§8 (numbers, traces, what was ruled out); the plan's §8
  "Resume here" and §5 P9/P11/P13 (float rules, power, Yharnam).
- Order: **1 → 2 → 3 → 4**. Phase 3 (the profile) needs the outcomes of 1 (which upscaler) and 2
  (pacing at the cap); phase 4 is independent and can move forward if the user wants uncapped
  play first.
- Decisions that belong to the user (plan §0): anything visible in the image (upscaler, effects,
  model detail), milestone targets (M3 at 720p), battery runs (unplugging the Air). When the
  user is away and has said so, take the recommended option, mark it in §9 as decided in their
  absence, and keep an off switch.

## Measurement protocol (all phases)

- Machine idle, no builds or other sessions' runs during a measurement; one game instance.
- **AC** unless the phase says battery (battery runs need the user). `pmset -g batt` before each
  run; stop the series if the source changes.
- Interleave A B B A (two rounds for small effects) with **150–180 s cool-down** between boots:
  60 s let the Air reach heavy thermal pressure within two runs, which parks the P cores and
  triples the recording time (that run measures heat, not the variant).
- Saves: `BENCH_SAVE=pristine-savedata-yharnam` (Central Yharnam, the heavy scene) and the default
  clinic save; `BB_PROFILE=m4air`, `BB_RENDERER=metal`; uncapped (`BB_FPS=uncap`) for GPU-time
  effects, capped for pacing and power.
- Tools (`macos/bench/`):
  - `bench.sh` (boot, 6 five-second windows; add `BB_FRAME_LOG=... BB_THREAD_CPU_LOG=10
    BB_THREAD_CPU_CSV=...` as `m1_run.sh` does);
  - `framestats.py <runs>` (FPS, `gpu_ms`, `rec_busy_ms`, waits, CPU per thread group, missed
    slots, thermal state per run);
  - `tracesub.sh` with `BB_PASS_LABELS=1`, then `chansplit.py <export>` (GPU ms by
    Vertex/Fragment/Compute per pass group) and `chansplit.py <export> --frames` (slow frames:
    more work or a longer span);
  - `m1_run.sh` with `POWERMETRICS=1 THREADCPU=10 IDLE_MIN=3` and `powerstats.py` (power,
    clocks, thermal per minute; powermetrics runs unattended through the allowed sudo line);
  - `m3stats.py` (M3/M4 verdicts);
  - `imgdiff.py` (same-build pairs give ~34 dB in Yharnam and 38–46 dB in the clinic, so compare
    against that spread, not against "PASS");
  - `temporal_check.sh` (`BENCH_SAVE=... SEQS="dpan strafe"`; residuals within the default's own
    A/A spread).
- Pitfalls: `bench.sh` runs `pkill -f bb-probe`, which also kills any shell command whose text
  contains that string (watchers, greps): use `bb-pro[b]e` in such commands. A run that reports
  "NOT IN GAME" is repeated once by `bench.sh` (a press missed while loading). A new shader cache
  tag compiles everything on its first boot: one warm-up boot, not measured.

## Phase 1 (P14): cheaper upscaling

Evidence (report §2, §5): MetalFX temporal costs ~3.0 ms a frame at 540p→1080p (A/B 21.1 →
18.1 ms without upscaler, +5 FPS); by trace 1.9 ms in its labelled Pre/Mid/Post encoders plus
2.3 ms in one unlabelled Compute encoder right after `MetalFX_Temporal_MidProcessing` (MetalFX's
own; no app blit there). A 1280x720 output saves only 1.0 ms, so most of the cost is fixed or
input-side. After P13.1 it is ~20% of the GPU frame.

1. (O) P14.1 What the unlabelled 2.3 ms is. Candidates: a format conversion or copy MetalFX adds
   for our textures (colour/depth/motion/output formats and usages in `CreateScaler`,
   `renderer_metal/mtl_upscaler.mm:170`; the output texture's usage and storage), the
   descriptor's optional inputs (`inputContentPropertiesEnabled`, auto-exposure, reactive mask).
   Method: a Metal frame capture (`MTL_CAPTURE_ENABLED=1`, Xcode GPU capture) or a microbenchmark
   of the scaler with the game's formats against RGBA16F/BGRA8 variants. Exit: the internal pass
   explained, and removed if it is ours.
2. (S) P14.2 a MetalFX **spatial** upscaler (`MTLFXSpatialScaler`) as a choice next to the
   temporal one: settings enum (`gpu/shim/bbport_settings.h` `Upscaler`, names, `BB_UPSCALER`),
   the Metal upscaler (`mtl_upscaler.mm`), the in-game menu and the launcher's choice; the game's
   own AA stays on with spatial (no temporal accumulation then). Porter spec from the temporal
   path; acceptance `macos/test.sh upscaler-support-test` plus a build.
3. (O) P14.3 measure: GPU ms (A B B A, Yharnam 540p and 720p uncapped), stills and
   `temporal_check.sh` against temporal MetalFX and against no upscaler; present to the user with
   screenshots. Optional: temporal only in the Quality preset, spatial below.

Exit: the cost of each choice measured and shown; the default per profile is **the user's
decision** (visible change). Vulkan untouched (Metal only).

## Phase 2 (P15): pacing and CPU power at the 30 cap

Evidence (report §6): at the cap 1–3% of the flips take 50 ms (boots), 1.29% in a 10-min 720p
walk. In those flips `gpu_ms` (the union of the command buffers' GPU intervals) is ~15 ms
higher, recording, compiles, allocations and the guest are unchanged, the frame was ready
~16 ms (one 60-Hz vblank) earlier relative to its flip, and 10-s traces at the cap show no frame
with more GPU work. The only GPU-side waits are the present queue's on the draw queue's event
(`mtl_presenter.mm:678`). `BB_FRAMES_AHEAD=2` changed nothing. At the cap the CPU draws more
than the GPU (3.7 W vs 2.9 W; P cores ~4 GHz, 57% active; the game's threads ~0.66 cores, the
port's ~0.67).

1. (O) P15.1 instrument the present path: per flip the draw queue's last GPU end, the present
   command buffer's GPU start/end, the drawable's acquisition time and its presented time
   (`addPresentedHandler`, `presentedTime`) into `BB_FRAME_LOG`; then 60-s labelled traces at the
   cap correlated with the flip log by timestamp. Tell apart: (a) the GPU shared with
   WindowServer's composition (windowed; test fullscreen and macOS Game Mode, lever 7 of
   `docs/PERFORMANCE_LEVERS_2026-10-16.md`), (b) a GPU clock step while it idles under the cap,
   (c) the drawable not available in time (`maximumDrawableCount`, `displaySyncEnabled`,
   `presentDrawable:afterMinimumDuration:`), (d) the vblank/flip timing in the video-out driver
   (`gpu/shadps4/core/libraries/videoout/driver.cpp`, `submit_ns`/`ready_ns`).
2. (O) P15.2 the fix the finding points to, measured on the 720p cap: boots A B B A and one 20-min
   walk under the M3 rule.
3. (O/S) P15.3 CPU power at the cap: which port threads run how much (`BB_THREAD_CPU_CSV`,
   `xctrace` time profile of `bb:DrawRec`, `shadPS4:GpuCommandProcessor`, `bb:window`), and cuts
   where they wait actively or redo work per frame; the P11 guest limiter fix stays.

Exit: missed slots at the 720p cap below 0.5% over a 20-min walk, or the cause documented as
outside the port; CPU power at the cap measured before/after (target −20%).

## Phase 3 (P16): the m4air profile after P13.1

Evidence: with P13.1, 720p runs uncapped at 52 FPS in Yharnam (540p before it: 42); the 720p cap
already passed the M3 rule over 10 min before P13.1 (1.29% missed slots, CPU 3.7 W, GPU 2.9 W,
nominal to moderate pressure). SSAO and dynamic shadows cost ~1 ms together (m4air turns them
off); `model_lod=2` saves 1.8 ms with visibly lower detail; game AA, chromatic aberration, the
light-grid patch and Relaxed math are no levers.

1. (O) P16.1 20-min runs under the M3 rule (`m1_run.sh` + `m3stats.py`, `IDLE_MIN=10
   POWERMETRICS=1 THREADCPU=10`) on AC: 720p; 720p with SSAO and dynamic shadows on; 540p with
   them on; the phase-1 upscaler choice applied. The same on **battery** with the user
   (Low Power Mode off and on, P11.3's open advice).
2. (O) P16.2 coverage for P13.1 beyond Yharnam and the clinic: Cathedral Ward, Old Yharnam and a
   DLC area (saves from the user), by eye for depth-equal artefacts (decals, z-fighting) plus
   `temporal_check.sh`; `BB_MTL_RELAX_VERTEX=0` stays the off switch.
3. (O, user) P16.3 the new profile: scene size, effects, upscaler; whether M3 moves back to 720p
   (milestone target: **the user's decision**, plan §0). Then `macos/run.sh` (`BB_PROFILE=m4air`),
   the launcher's preset (`launcher/Sources/LanternCore/Profile.swift`, "MacBook Air", kept in
   sync with run.sh), README/HANDOFF advice. `model_lod=2` only as an optional "performance"
   choice if the user wants one.

Decided early (2026-10-18, the user): the m4air profile's scene is 1280x720 (run.sh and the
launcher's "MacBook Air" preset); effects, model LOD and upscaler unchanged. P16.1 still measures
it under the M3 rule; `BB_RENDER_RES=960x540` restores 540p.

Measured 2026-10-18/19 (P16.1 prep, short boots, m4air 720p uncapped, AC, labelled 5-s traces,
`chansplit.py`; the 20-min runs not yet made):

| Variant | Yharnam FPS / GPU ms | Clinic FPS / GPU ms / draws / encoders a frame |
|---|---|---|
| SSAO and dynamic shadows off (the profile) | 50.3, 49.8 / 20.0 | 60.7 / 17.5 / 776 / 195 |
| SSAO only | — | 60.1 / 17.6 / 779 / 197 |
| dynamic shadows only | — | 38.7 / 21.2 / 1199 / 354 |
| both | 46.9, 47.4 / 20.8 | 40.3 / 21.4 / 1202 / 357 |

- SSAO is free (+0.2 ms GPU, FPS within noise) and visible: darker crevices behind and under
  objects (clinic shelves, Yharnam door recess and gate).
- Dynamic shadows cost 36% FPS in the clinic but only +3.7 ms GPU: the wall lamp adds ~420 draws
  and ~160 encoders a frame in tiny shadow-map passes (32x32, 64x64 depth targets, ~1 ms vertex
  each group), GPU busy falls from 80% to 63% and the kernel submit cost appears (0.27–0.34 ms
  per command buffer): the frame becomes recording/encoder-bound. In Yharnam they cost little
  (+32 draws). A lever if shadows are wanted: fewer encoders for the small shadow passes.
- Recommendation for P16.3 (the user's call): SSAO on in the m4air profile, dynamic shadows off;
  then the 20-min M3 run with `effect_ssao=1`.

Exit: the profile changed by the user's choice and passing the M3 rule on AC and battery.

## Phase 4 (P17): recording cost under heat (uncapped play, M4)

Evidence (report §6): uncapped, the Air reaches heavy pressure within two minutes, macOS parks
the P cores (~1 GHz) and the recording thread goes from 7–8 to 21–23 ms a frame; FPS settles at
43–47 at 540p while the GPU is not the limit. After P13.1 the GPU needs ~15 ms, so recording is
the limit sooner. `bb:DrawRec` in the 540p trace (inclusive): `DrawRecord` 59%,
`BindResources` 26%, `EndEncoder` 22%, `ReleaseHeldPass` 20%, `RecordDraw` 20%, `Flush` 16%,
`OpenPhysical` 14%; leaves `BindResources`, `SetupDraw`, `BindTextures`,
`setRenderPipelineState`, `setFragmentTexture`.

1. (O) P17.1 profile recording on the E cores: a hot uncapped run (or the recording thread pinned
   to background QoS to emulate it) with a time profile; cost per draw and per encoder, split into
   the core (`RasterizerCore`, shared with Vulkan) and the Metal hooks.
2. (S) P17.2 cuts the profile names, each with its own porter spec and A/B, e.g. redundant
   state sets (pipeline, textures, buffers unchanged since the last draw), a fast path in
   `BindResources` for unchanged bindings, fewer encoders per pass (`ReleaseHeldPass`,
   `OpenPhysical`). Shared-core changes are verified on Vulkan too (bench and screenshot).
3. (O) P17.3 measure: `rec_busy_ms` under heavy pressure, and M4 under its rule
   (`m3stats.py --milestone m4`, 20 min uncapped, Yharnam and the clinic).

Exit: recording under heavy pressure ≤ 15 ms a frame in Yharnam, M4 passing there on AC.

## Not planned (measured, no gain)

Game AA off and chromatic aberration off (0 ms), the "1080p Light Grid" patch (+1 ms), Relaxed
math (−0.3 ms, inside the noise), `BB_FRAMES_AHEAD=2` (missed slots unchanged), a smaller
MetalFX output (−1 ms; superseded by phase 1).
