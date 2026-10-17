# bbport for macOS — notes for AI coding agents

macOS port of bbport (Bloodborne's x86-64 eboot run natively, PS4 libraries replaced, GPU
translated): one x86-64 process under Rosetta 2, renderer on Metal (default on Apple silicon with
macOS 15+) or Vulkan via MoltenVK. State, measured numbers and history: `macos/HANDOFF.md`. The
Metal backend's plan, decisions and results: `docs/METAL_BACKEND_PLAN.md` (its §8 says where it
stands and what is open). The native launcher "Hunter's Lantern" (SwiftUI app, DMG, `launcher/`):
`docs/LAUNCHER_PLAN.md`, same working model (its §8 "Start here" says where to begin).

## Repository rules (hard)

- This is the public repo `Huax-1839/bloodborne-macos` (`origin`, over SSH). Commits are authored
  as `Huax-1839` (the git identity): never put real names, `/Users/...` paths or host names into
  commits or tracked files. **Never push to, open issues
  or comment on the upstream project** (`deadinside28/bloodborne_pc`, remote `upstream`, push
  disabled) or `../bloodborne_pc` (untouched reference clone next to this checkout).
- Commit to `main` after each verified step (message style: imperative subject, body says why);
  push to `origin` at the end of each plan phase. Run `git status` before every commit.
- Never commit game data or user data: `macos/deps/`, `macos/out/`, `macos/user/`, eboot/game
  files, savedata, shader caches, screenshots, logs. The game lives in
  `~/Games/Bloodborne/CUSA03173-1.09`, bench data in `~/Games/Bloodborne/bench/`.
- New source files start with `// SPDX-License-Identifier: GPL-2.0-or-later`.
- The Vulkan backend must keep working (it is the reference for the Metal backend and the
  fallback renderer): changes to shared code are verified on Vulkan too (bench + screenshot).
- macOS only: the Linux build, launcher and packaging were removed (2026-10-17); Linux users use
  the upstream project. Linux branches in shared code (`#ifdef __linux__`) stay, to keep the
  shared files close to upstream for hand-ported fixes.

## Commands

- `bash macos/build-deps.sh` (once; x86-64 deps into `macos/deps/x86_64`), `bash macos/build.sh`
  (writes `macos/out/`, GPU library log in `macos/out/gpu-build.log`).
- `bash macos/run.sh` starts the game (`BB_PROFILE=m4air` for the Air's 30 FPS profile;
  `BB_RENDERER=metal|vulkan`, default metal on Apple silicon with macOS 15+; `bench.sh` keeps
  `BB_RENDERER` explicit, default vulkan).
- Unit tests: `macos/test.sh` (builds and runs every `*-test` target of `gpu/CMakeLists.txt`,
  logs in `macos/out/test-logs/`), or `macos/test.sh <target>...`.
- Launcher: `launcher/build.sh [--dev|--bundle]` (app in `launcher/build/`), `launcher/test.sh`
  (swift test, also run by `macos/test.sh`), `launcher/package.sh` (DMG). UI checks without
  screen capture: `LANTERN_DATA_DIR=<scratch> LANTERN_SNAPSHOT=<dir> <app>/Contents/MacOS/HuntersLantern`
  renders every page to PNG; never use the real data dir (`~/Library/Application Support/HuntersLantern`).
- Bench: `macos/bench/bench.sh <name> [ENV=VAL…]` (data in `~/Games/Bloodborne/bench`, results in
  its `runs/results.tsv`); image comparison `macos/bench/imgdiff.py A.png B.png`.
- Only **one game instance at a time** (`pkill -f bb-probe` before starting); benchmarks need an
  otherwise idle machine and interleaved A/B runs (the Air throttles ±15%).
- Debug env: `MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=nslog`, `NSZombieEnabled=YES`; Metal
  traces: `xcrun xctrace record --template 'Metal System Trace' --attach <pid>`.

## Working model: Opus orchestrates, Sonnet and Haiku do the volume

The main session runs **Opus with high effort** and is the orchestrator. Subagents are defined in
`.claude/agents/`: `porter` (Sonnet) and `scout` (Haiku). The goal is to keep the orchestrator's
context for design, integration and review, and to push reading, searching, log digging and
well-specified implementation to cheaper models.

The orchestrator itself does:
- design decisions and anything the plan marks **O**: the API seams, scheduler/pass planning,
  synchronization (labels, fences, barriers), memory lifetime, integration;
- writing each subagent's task spec, reviewing every subagent diff (`git diff`) before it is
  committed, building, running the game, benchmarks and image comparisons, committing;
- keeping `docs/METAL_BACKEND_PLAN.md` §8 and `macos/HANDOFF.md` current after every step;
- deviating from the plan when the evidence says so, by its §0: goals and the listed fixed
  points only after asking the user; everything else decided here, edited into the plan and
  logged in its §9.

`porter` (Sonnet) gets tasks the plan marks **S**: one bounded unit of porting or tooling with a
clear interface. Each spec it receives contains:
1. the goal and the plan task id (e.g. "P2.2");
2. the files to read first (Vulkan counterpart, the interface header it must implement);
3. the files it may create or change (and that it must not touch anything else);
4. the acceptance check it runs itself (build target and/or unit test command);
5. what to report back: changed files, open questions, deviations from the spec.
Porters do not run the game, do not commit and do not change the plan. Spawn with
`effort: high` for tasks touching synchronization or memory lifetime; otherwise the default.

`scout` (Haiku) is read-only and cheap: call-site inventories, "where is X" sweeps across many
files, digesting large logs (game logs are ~1 MB: never read them in the orchestrator), summarising
exported Metal traces or `sample` output, checking a spec against the code. It returns short
findings with `file:line`, not file dumps.

Rules for spawning:
- Don't spawn for what one `grep`/`Read` answers; spawn when the output would be large or the work
  is long and self-contained.
- Run independent subagents in parallel (several Agent calls in one message). Parallel porters
  must have **disjoint file sets**; when two of them build at the same time, give each
  `isolation: "worktree"` and tell it to prepare the worktree first:
  `ln -s "$(git rev-parse --path-format=absolute --git-common-dir)/../macos/deps" macos/deps && git submodule update --init --recursive`
  (it then builds into its own `macos/out/`). The orchestrator merges the result into `main`.
- At most three porters at once; the orchestrator reviews and integrates between waves.
- A porter's failed or unclear result goes back to the same agent with `SendMessage` (it keeps
  its context) rather than a new spawn.
- Subagent reports are inputs, not facts: the orchestrator verifies builds, tests and images
  itself before marking a task done.

## Code map (renderer)

- Frontend (backend-neutral): `gpu/shadps4/video_core/amdgpu/` (Liverpool, registers, PM4),
  `gpu/cp/` (command decoder), `gpu/shadps4/shader_recompiler/` (GCN → IR → SPIR-V),
  `gpu/games/` (game profile), `gpu/shim/` (bbport glue, settings, overlay, guest memory, window).
- Vulkan backend: `gpu/shadps4/video_core/renderer_vulkan/` (`vk_rasterizer.cpp` is the heart,
  `vk_scheduler.cpp` the command/pass logic), `texture_cache/`, `buffer_cache/`.
- Metal backend (the default on Apple silicon): `gpu/shadps4/video_core/renderer_metal/`, Objective-C++ (`*.mm`,
  ARC) with plain C++ headers; no Objective-C types outside this directory.
- macOS specifics: `gpu/shim/bbport_platform.h` (force-included Linux API shims),
  `src/probe.c` (loader, TLS rewrite), `src/runtime_low_heap.c`, `macos/*.sh`.

## Known pitfalls

- PS4 user range lives at 0x7000000000 (Rosetta reserves 0xfc0000000–0x7000000000).
- MoltenVK marks every device-address buffer as used by every encoder: GPU memory may only be
  freed after later frames (`DeferredFreeMemory` in `vk_instance.cpp`); the Metal backend must
  free only after completion of the last command buffer that can see the memory.
- Concurrent joins of one thread deadlock on macOS (`gpu/shim/core/libraries/kernel/threads.h`).
- MoltenVK has no geometry shaders (those draws are skipped on Vulkan; Metal emulates them with
  a compute pre-pass, `docs/metal/geometry_shader_design.md`) and no sparse binding.
- Objective-C code on the renderer's own threads needs `@autoreleasepool` around anything that
  creates autoreleased objects (command buffers, encoders, descriptors, `stringWithFormat`): those
  threads never drain a pool, and every leaked command buffer keeps what it references alive.
