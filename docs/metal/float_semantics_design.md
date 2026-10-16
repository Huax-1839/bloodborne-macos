# Float semantics of game shaders on Metal (proposed P9.1)

Status: planned as P9.1 (plan §5 P9), 2026-10-16 (the first lever of
`docs/PERFORMANCE_LEVERS_2026-10-16.md`); results in plan §8 and §9. Nothing below is measured in the game: the evidence is
the code and the bench user's shader cache. Owner of the design and the measurements: the
orchestrator; the implementation: a porter task.

## Goal

Lower the GPU time of the scene passes (83% of the frame: 23.5 of ~29 ms at 540p hot, 29.5 of
35 ms at 720p cool, plan §5 P8) without an image change beyond the plan's §6 thresholds, by
compiling the game's fragment and compute shaders with float rules no stricter than the PS4's
GPU. Metal only; the Vulkan backend stays bit for bit unchanged. If the gain is large, it is the
most likely route to 720p internal on a warm Air (needs ~25% less GPU time there).

## Evidence

1. **`NoContraction` on every float op.**
   `gpu/shadps4/shader_recompiler/backend/spirv/emit_spirv_floating_point.cpp:9-11`: `Decorate()`
   adds `spv::Decoration::NoContraction` to every result it gets, unconditionally; it is called
   by FPAdd32/64, FPSub32, FPFma32/64, FPMul32/64 and FPDiv32/64 (9 call sites).
2. **SPIRV-Cross makes each of them an unoptimisable call.** In the vendored SPIRV-Cross
   (`macos/deps/src/spirv-cross`, tag `vulkan-sdk-1.4.363.0`):
   - `spirv_glsl.cpp:21001-21003`: `NoContraction` clears the contract, transform and reassociate
     fast-math flags of the op; `has_legacy_nocontract` (`:21027`) is then true;
   - `spirv_msl.cpp:9779-9793` (and the matrix forms at `:10296`, `:10338`, `:19476`, `:19485`):
     such an FMul/FAdd/FSub is emitted as `spvFMul`/`spvFAdd`/`spvFSub` (also when
     `invariant_float_math` is on, which the backend does not set);
   - `spirv_msl.cpp:6424-6452`: the helpers are `[[clang::optnone]]` templates around `fma()`:
     `spvFAdd(l, r) = fma(T(1), l, r)`, `spvFSub(l, r) = fma(T(-1), r, l)`,
     `spvFMul(l, r) = fma(l, r, T(0))`.
   So the Metal compiler may not fuse a multiply and an add into one FMA, fold constants or share
   common subexpressions across these ops.
3. **How common.** Bench cache `~/Games/Bloodborne/bench/testuser/cache/CUSA03173/metal`
   (1066 MSL files: 624 vertex, 308 fragment, 84 compute, the rest tessellation and geometry):
   284 of 308 fragment shaders contain the helpers; calls a fragment shader: median 107, p90 676,
   max 1258; over all fragment shaders 45,790 `spvFMul`, 22,292 `spvFAdd`, 2,368 `spvFSub`, 280
   each of `spvFMulMatrixVector`, `spvFMulVectorMatrix`, `spvFMulMatrixMatrix`. Vertex shaders:
   median 57. Count again with `grep -o 'spvF[A-Za-z]*(' <file> | wc -l`.
4. **Safe math everywhere.** `renderer_metal/mtl_shader.mm:817-821` (`BuildLibrary`) and
   `renderer_metal/mtl_geometry.mm:476-480`: `MTLCompileOptions.mathMode = MTLMathModeSafe` on
   macOS 15+, else `fastMathEnabled = NO`: IEEE division and square root, no reassociation. Not
   set: `preserveInvariance`, `mathFloatingPointFunctions` (default Fast, `MTLLibrary.h`),
   `optimizationLevel`. Correction (orchestrator, 2026-10-16): the transcendentals are precise
   for another reason: SPIRV-Cross writes `precise::exp/log/rsqrt/sqrt/sin/cos/...` explicitly
   unless the op's `FPFastMathMode` drops NaN and Inf (`spirv_msl.cpp:11739-11750`; 2814 such
   calls in the bench cache's fragment shaders), so neither the math mode nor
   `mathFloatingPointFunctions` changes them. Both are more precise than GCN's `v_rcp_f32`,
   `v_rsq_f32`, `v_sqrt_f32`, `v_exp_f32`, `v_log_f32`, `v_sin_f32`, which are approximations.
5. **Other float state** (unchanged by this task): no `Invariant` decoration on positions; float
   controls: `SignedZeroInfNanPreserve` for fp32 is emitted on Metal
   (`mtl_pipeline_cache.mm:85`, `emit_spirv.cpp:586-634`), no denorm or rounding modes
   (`mtl_pipeline_cache.mm:70-82`); no FP16 arithmetic (half-precision GCN ops run in fp32).
6. **Fits the measurements.** MoltenVK translates with SPIRV-Cross too, and the plan found the
   scene passes cost the same on both backends ("their cost is the shaders'", §5 P8 step 2).
7. **Not what was rejected before.** `docs/PERFORMANCE_REPORT_M4_AIR_2026-10-13.md:115` rejects
   *unchecked global* fast-math. This proposal relaxes only stages that compute no positions,
   keeps Inf/NaN, comes in two measured steps and has an off switch.

Open before building: why `NoContraction` was added. Likely for bit-identical results between
shaders that recompute the same value (positions for depth-equal passes), as GCN does not
contract on its own. Check read-only: `git -C ../bloodborne_pc log -S NoContraction` and the
comments around it (never push to, comment on or open issues upstream).

## Design

Stages and their rules:

| Stage | `NoContraction` | Math mode |
|---|---|---|
| vertex, tessellation control and evaluation | kept | Safe |
| geometry-shader emulation kernels (ES, GS), the port's own kernels | kept | Safe |
| fragment shaders that export depth (`DepthReplacing`) | kept | Safe |
| other game fragment shaders | dropped (V1, V2) | Relaxed (V2) |
| game compute shaders | dropped (V1, V2) | Relaxed (V2) |

Why positions stay strict: two different vertex shaders that compute the same position (a depth
pre-pass and the colour pass, decals) must produce identical bits, or depth-equal tests flicker
(z-fighting). A compute shader that writes positions for later passes computes them once, so it
can be relaxed.

Variants:
- **V0** (today, and the off switch): every op decorated, Safe math.
- **V1**: no `NoContraction` in game fragment (without depth export) and compute shaders; Safe
  math stays.
- **V2**: V1 plus `mathMode = MTLMathModeRelaxed` for the same shaders
  (`mathFloatingPointFunctions` is Fast already by default; the SDK's `MTLLibrary.h`: Relaxed
  "allows aggressive, unsafe floating-point optimizations but preserves infs and nans"). Relaxed has to keep Inf
  and NaN, since the recompiler's emulation of GCN's legacy multiply and min/max may depend on
  them. `MTLMathModeFast` (assumes no NaN or Inf) is out of scope unless V2 is clean and it is
  measured as a separate step.

Gating:
- A new field in `Shader::Profile` (`shader_recompiler/profile.h`), default = today's behaviour,
  set only by the Metal pipeline cache next to the float-control fields
  (`renderer_metal/mtl_pipeline_cache.mm:66-90`); the Vulkan profile never sets it.
  `Decorate()` checks it together with `ctx.stage` and whether the fragment shader exports depth.
- The math mode follows the same decision: `BuildLibrary` (`mtl_shader.mm:812`) learns the
  shader's stage or variant; `mtl_geometry.mm` stays Safe.
- `BB_MTL_STRICT_FLOAT=1` restores V0 (read once at startup), as every tuning has an off switch
  (e.g. `BB_MTL_REPLAY_THREAD=0`). During the A/B a second value can select V1 or V2.

Caches:
- MSL files are named `{hash}_{stage}{tag}_{spirv_hash}.metal` (`mtl_shader.mm:1034`): V1's
  changed SPIR-V gets new files, so the variants can live side by side.
- The math mode is not part of the MSL text. Check that a library or a binary-archive entry
  compiled with other options cannot be reused for another variant; if it can, key the files on
  the variant or bump `kMslCacheVersion` (`renderer_metal/mtl_shader.h:68`).
- Back up the bench cache directory before the first boot of a variant. The M3 runs depend on a
  fully warm cache (plan §8: `m3-rule-power` failed on two compiles, `m3-freshcache-power` was
  measured after a 20-min fill run).

Unit test (new or in an existing `*-test` target of `gpu/CMakeLists.txt`): a fragment shader
emitted with the Metal profile has no `NoContraction`, a vertex shader and a depth-exporting
fragment shader keep it, and the SPIR-V emitted with the Vulkan profile is byte-identical to
before.

## Measurement

Shader variants are fixed at boot, so this is an A/B by boots, not by experiment bits.

- Idle machine, one game instance (`pkill -f bb-probe`), a 15-min cool-down, interleaved boots
  A B B A (A = V0 by the off switch, B = V1 or V2), the clinic bench save.
- The first boot of each variant fills its caches; measure only when the log shows no shader or
  pipeline compiles in game (slow compiles are logged since aeb81ac).
- Primary metric: GPU ms a typical frame (the busy union, not the per-label sum) and per pass
  label from traces (`BB_PASS_LABELS=1`, `macos/bench/tracesub.sh` + `mtltrace.py`). Labels
  carry guest shader hashes, so they line up across variants. Report the large passes on their
  own: G-buffer `b10c4f55` (+ `3deaa573`, `6a833138`), lighting `8747a367`/`d92266b9`, C1
  `637500e0`, MetalFX. A/A traces of one session scatter by ±3 ms; use per-label numbers for
  smaller effects.
- At 540p (`BB_PROFILE=m4air`) and 720p (`BB_PROFILE=m4air BB_RENDER_RES=1280x720`).
- Secondary: FPS by the M2 protocol (`macos/bench/m2.sh`).
- Images (§6): title and clinic screenshots (`imgdiff.py`) and display dumps (`rawdiff.py`)
  against the Vulkan reference and against V0. Look for z-fighting, shimmering decals and holes
  along edges in the clinic. A 5-min walk (`m1_run.sh <name> metal 5 BB_PROFILE=m4air`) with
  `MTL_DEBUG_LAYER=1`: no validation errors.
- Vulkan unchanged: bench and screenshot on Vulkan (the recompiler file is shared code).

## Decision rules

- Keep V1 and/or V2 when GPU time falls by more than the A/A spread (or clearly per label) and the
  images pass §6; then it becomes the default, with `BB_MTL_STRICT_FLOAT=1` as the off switch.
- If the images break: bisect by stage (fragment vs compute) and by V1 vs V2 before giving up.
- If the gain is below the noise: record it as measured and not kept, with the numbers, and
  revert.
- Record the result in plan §8 (GPU ms per variant at 540p and 720p, FPS, dB), §9 (decision and
  evidence) and `macos/HANDOFF.md`, and state whether 720p at 30 FPS on a warm Air is in reach.
- Later, separately: the same rules for MoltenVK (Vulkan path) only with the user's agreement,
  since Vulkan is the reference.

## Session prompt

For a new orchestrating session in the repository root:

```text
Task: P9.1 "Float semantics of game shaders on Metal". Read docs/metal/float_semantics_design.md
(evidence, design, measurement, decision rules) and follow CLAUDE.md's working model: you are the
orchestrator. First add the task to docs/METAL_BACKEND_PLAN.md (§5 a new phase P9 "GPU time:
shader float semantics", §8 checklist, §9 decision-log entry); no milestone changes; Vulkan stays
bit for bit unchanged. Re-verify the evidence (counts in the bench shader cache, the SPIRV-Cross
lines) and find out why NoContraction was added (read-only in ../bloodborne_pc) before building.
Spec the implementation for a porter (effort high: shader semantics): Profile field, Decorate()
change, Metal-only gating with BB_MTL_STRICT_FLOAT=1 as the off switch, per-stage compile
options, cache keying, the unit test; acceptance bash macos/build.sh and macos/test.sh. Review the
diff, then measure V1 and V2 against V0 by interleaved boots and traces at 540p and 720p as the
design says, check images and Vulkan, commit after each verified step, push at the end of the
phase. Report: GPU ms per variant (busy and the main passes), FPS, image dB, z-fighting or not,
what was kept, the commits.
```
