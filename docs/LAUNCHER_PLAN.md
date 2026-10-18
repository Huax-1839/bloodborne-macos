# Launcher "Hunter's Lantern": plan

Status: planned 2026-10-17 together with the user (decisions in §9); L0 done and L1 under way
(2026-10-17, see §8). Progress is
tracked in the checklist in §8; the orchestrating session updates it after every step (see
`CLAUDE.md`, the same working model as `docs/METAL_BACKEND_PLAN.md`).

## 0. How binding this plan is

The goals and the user's decisions are firm; the route is a best guess, written before any
launcher code existed, and is expected to change with the spikes of L0.

**Fixed: change only after asking the user** (stop and ask; do not work around it):
- the milestones L-M1–L-M3 (§1) and what v1 contains (§1 table);
- the decisions the user made on 2026-10-17 (§9): public `.app` in a DMG built by GitHub Actions,
  SwiftUI, Apple silicon with macOS 14+, the three import paths, the settings split with the
  in-game menu, profiles as complete packages, local mods only, the name; and the visual design
  of 2026-10-19 (`docs/LAUNCHER_DESIGN.md`: one fixed 960 × 600 window in Victorian gothic,
  its tokens and states), which replaced the home page + sidebar layout;
- **no PKG decryption code and no keys in this repository or in the app**: PKGs go through an
  external tool the user installs (D6);
- **no Sony/FromSoftware artwork, logos or game files in the repository or the app**: artwork
  comes from the user's own game (`sce_sys`), and "Bloodborne" is not part of the app's name;
- new third-party dependencies other than Sparkle, python-build-standalone (the latter only
  until the Swift port, L7, removes it) and the four OFL fonts of `docs/LAUNCHER_DESIGN.md`
  (Cormorant Garamond, IM Fell English SC, EB Garamond, JetBrains Mono; approved 2026-10-19);
- `macos/run.sh` and `macos/bench/*` keep working as the developer path: the launcher is an
  additional front end, not a replacement for them;
- the renderer and runtime stay launcher-agnostic: shared-code changes needed for the launcher
  (L0.1, L2.5, L4.1) are verified on Metal and Vulkan (bench + screenshot) as `CLAUDE.md`
  requires.

**Open: the orchestrator decides on evidence**: the decisions D1–D17 below, the phase order, how
tasks are split, the bundle layout, file and type names, the verification details.

Rules for a deviation: as in `docs/METAL_BACKEND_PLAN.md` §0 (evidence, edit the plan where the
change applies, log it in §9; porters never deviate on their own).

## 1. Goal

A native macOS app, **Hunter's Lantern**, that lets a player without developer tools play the
port: download a DMG, bring their own copy of the game (a folder, base game + update, or PKG
files), pick a profile that suits their Mac, add mods, play, and get updates, without Terminal,
Xcode, Homebrew or Python.

| Milestone | Target |
|---|---|
| L-M1 dev launcher | The SwiftUI app, built from the repo, registers a ready 1.09 game folder, writes the settings of the chosen profile and starts the game on Metal and on Vulkan, hides itself while the game runs and shows the outcome afterwards. `run.sh` and the bench are unchanged in behaviour. |
| L-M2 self-contained | The app bundle carries the runtime (`bb-probe`, `libbbgpu`, SDL3, MoltenVK), the pipeline and its own Python; it starts the game from `/Applications` on a Mac account with no Xcode, no Command Line Tools Python, no Homebrew and no repository checkout. |
| L-M3 v1.0 | **Acceptance (the user's criterion):** on a fresh Mac account, open the DMG, import a game folder or base + update, choose a profile, enable a mod, play, find a save backup made, and receive an update through Sparkle. In addition v1 contains the PKG import through an external tool, save export/import and minimal diagnostics. Online/co-op is not part of v1 (backlog, L7). |
| After v1 | Online/co-op (network module on macOS + launcher page), pipeline fully ported to Swift (Python removed, `run.sh` calls the same Swift CLI), controller mapping, bug-report bundle, Developer ID signing and notarization (the user decides later), more languages, playtime/library extras. |

v1 feature set (decided with the user):

| Area | v1 |
|---|---|
| Game import | ready 1.09 folder; base + update folders merged; PKG via an external tool; quick check at import, thorough check in the background |
| Profiles | complete packages (graphics, FPS, renderer, patches, mod set, optionally own saves); built-in presets suggested from the hardware |
| Settings | pre-launch settings in the launcher, live settings in the in-game menu, one `bbport.ini`; the launcher locks its settings while the game runs |
| Mods | local folders and ZIPs, order, enable/disable, conflict view, mod set per profile |
| Patches | built-in and external GoldHEN XML, FPS patches coupled to the profile |
| Saves | automatic backup before each start with rotation, named snapshots, restore, export/import |
| Updates | Sparkle 2 with EdDSA, appcast from GitHub Releases |
| Diagnostics | log viewer, last crash, open logs folder, copy system info |
| UI | German and English; one fixed window in the design of `docs/LAUNCHER_DESIGN.md` (main action, register, settings column), further pages as sheets |

## 2. Starting point (inventory 2026-10-17)

- **Launch path today**: `macos/run.sh` (cd to the repo root) runs `scripts/prepare.py`,
  `link_libc.py`, `link_modules.py`, `content_profile.py` and `patches.py` (twice), sets ~30
  environment variables, and execs `macos/out/bb-probe` with `out/game/boot-linked.bin`,
  `content.bin`, `patches.bin`, `--app0 GAME --user USER`.
  - All scripts are stdlib-only Python ≥ 3.9 (~1,600 lines). They import each other, so they must
    stay in one directory. Each launch reads `eboot.bin` three times and writes ~390 MB to
    `out/game`. `boot-libc.bin` from `link_libc.py` is read by nothing in the run path.
  - `mods.py` and `online.py` are **not wired into `macos/run.sh`**. `docs/MODS.md` documents
    `BB_MODS_DIR`/`BB_MODS_ENABLED` for run.sh, but run.sh does not implement them.
- **Online does not work on macOS**: `macos/build.sh` builds with `BB_NET=OFF`, so
  `libbbnet` does not exist. `src/runtime_net.c` finds the module through `/proc/self/exe`, which
  macOS lacks. `BB_ONLINE=1` therefore plays offline.
- **Settings**: everything is in `bbport.ini` (`BB_CONFIG`), including `key.*`/`pad.*` bindings and
  `mouse_*`.
  - The game loads the file once at start. `BbSettings::Save` merges it (keeps foreign lines) and
    writes `.tmp`, then renames. Callers: the overlay on close, the game menu on every change.
  - Live in-game: upscaler, preset, sharpness, show_fps, jitter/reactive.
  - At launch only: `output_res` (non-1080p fixes the scene size), `model_lod`, the ten effects
    (patches), `object_motion`.
  - Env-only settings: `BB_FPS`, `BB_RENDERER`, `BB_RENDER_RES`, `BB_PROFILE`, `BB_DMEM_MB`,
    `BB_GAMEPAD`, `BB_DISPLAY`, `BB_LANGUAGE`, … (full list in the L1.3 spec).
  - The in-game menu cannot edit bindings.
- **Restart from the overlay** (`src/probe.c:349`) execs `bash macos/run.sh` relative to the cwd. A
  bundled app has neither.
- **User dir** (`--user`, `BB_GPU_USER_DIR`):
  - `savedata/<user id>/<title id>/SPRJ0005{,.sce_sys}` and `savedata/<uid>/<title>.memory/`;
  - shader caches in `cache/<serial>[-metal…]` (~1,300 files);
  - plus empty shadPS4 folders.
- **Runtime binaries** (`macos/out`):
  - `bb-probe` (x86-64 PIE, rpaths `@executable_path/gpu` and `/lib`), `gpu/libbbgpu.dylib`
    (40 MB), `lib/libSDL3.0.dylib`, `lib/libMoltenVK.dylib`; no absolute paths into
    deps/Homebrew.
  - Shaders are compiled at run time and the font is embedded, so nothing else is read from the
    repo except `scripts/` and `patches/Bloodborne.xml`.
  - Defaults relative to the cwd: `out/dump`.
  - Signing is ad hoc, without the hardened runtime. The code uses RWX pages
    (`bbport_guest_hooks.cpp`, `bbport_free_check.cpp`), so notarization would need
    `allow-unsigned-executable-memory`.
- **Game check** (`game_check.py`): TITLE_ID among nine retail IDs, APP_VER 01.09, SHA-256 of
  the loaded eboot image, and the 8 shader `.dcx` files must unpack. A standalone run checks all
  26,913 `.dcx` files (17.7 GB, minutes). No merging of an update exists anywhere.
- **Upstream launcher** (`../bloodborne_pc/launcher`, GTK, read-only reference): `game_environment()`
  (env for run.sh), the mods page (`mods.json` with `order`/`disabled`), the patch profile
  (`patches.json` stores only differences from each patch's `isEnabled`), the online page with its
  connection test, i18n (ru as key language, en/pt_BR/zh_CN).

## 3. Architecture decisions

**D1 Name and identifiers.**
- App: `Hunter's Lantern.app`, bundle id `io.github.huax-1839.hunters-lantern`.
- Data: `~/Library/Application Support/HuntersLantern/` (no apostrophe or space in paths the
  shell scripts see).
- Source: `launcher/` in this repository.

**D2 Technology and targets.**
- SwiftUI, macOS 14+, the launcher arm64 only; the game runtime stays x86-64 under Rosetta 2.
- Logic lives in a Swift package `LanternCore` (no UI, unit-tested with `swift test`).
- The app is an executable target of the same package (`launcher/Package.swift`), a thin UI over
  it; `launcher/build.sh` builds it with `swift build` and assembles the `.app` (Info.plist, icon,
  resource bundles, signing). No Xcode project (decided 2026-10-17, §9: reviewable files only,
  and `swift build` compiles String Catalogs into `.lproj`).
- Localisation: String Catalogs; German and English.

**D3 Bundle layout** (confirmed or changed by spike L0.2).
- The runtime goes in as a nested app, `Contents/Helpers/Hunter's Lantern Game.app`. Its
  executable is `bb-probe`; `libbbgpu`, SDL3 and MoltenVK sit in its `Contents/Frameworks` (rpaths
  adjusted when packaging).
- Why a nested app: an Info.plist gives the game process its own name and icon in the Dock and
  Cmd-Tab, `LSApplicationCategoryType` (games) for macOS Game Mode, and a correct signing
  structure.
- Pipeline scripts and `patches/Bloodborne.xml` go in `Contents/Resources/pipeline/`, Python in
  `Contents/Resources/python/` (D4).
- Every cwd-relative default is replaced by an explicit env var or argument. The launcher sets
  the cwd to a data-dir folder.
- Confirmed by L0.2 (`launcher/packaging/make-game-app.sh`): the game runs from the nested app
  outside the repository on Metal and Vulkan. `Contents/Frameworks` needs no `libvulkan*`
  symlinks (vulkan.hpp's loader falls back to the already loaded `libMoltenVK.dylib`). Category
  `public.app-category.games`, `GCSupportsGameMode`. Remaining cwd-relative defaults are only
  for features that are off by default (`out/dump`: `BB_DUMP_DIR`; the FSR 4 assets went with
  FSR 4 on 2026-10-18).

**D4 Pipeline: Python embedded in v1, Swift afterwards.**
- `LanternCore` defines a `Pipeline` protocol: check game, prepare image, compile patches, build
  the mod overlay, write online overrides.
- In v1, `PythonPipeline` runs the unchanged scripts with an embedded python-build-standalone
  (aarch64, `install_only_stripped`; the scripts are pure Python, so no x86-64 Python is needed).
- The launcher never calls `/usr/bin/python3`: on a Mac without Command Line Tools that is a stub
  that opens an install dialog.
- L0.3 (measured): CPython 3.13.16 (python-build-standalone 20261013, pinned with its SHA-256 in
  `launcher/packaging/fetch-python.sh`), pruned to 27 MB (9.8 MB as tar.gz); outputs
  byte-identical to Homebrew's Python; the pipeline takes ~1.6 s warm. Flags `-E -s -B`, **not
  `-I`** (it drops the script folder from `sys.path`, and the scripts import each other). A
  quarantined, unapproved bundle gets the interpreter killed by Gatekeeper (SIGKILL): the
  launcher says so in plain words.
- After v1 (L7), `SwiftPipeline` replaces the scripts one by one, each with golden tests
  (byte-identical `content.bin`, `patches.bin`, `boot-linked.bin`; equal overlay trees). The same
  Swift code also builds a CLI `lantern` that `run.sh` then calls, so there is again one
  implementation.

**D5 One launch contract, tested against run.sh.**
- The launcher does not call `run.sh`. It builds a `LaunchSpec` (environment, arguments, cwd)
  itself.
- To stop the two paths from drifting, `run.sh` gets a `--print-env` dry run (L0.1). A test runs
  both for a matrix of profiles and compares the result.
- A change to run.sh's env logic must update `LaunchSpec`, and that test enforces it.

**D6 Game import.** Three paths, all ending in one verified game folder:
- (a) **Ready folder**: registered where it is (no copy). Moving it to another disk is offered.
- (b) **Base + update**: the update's files replace the base's; dumps are whole-file updates with
  no deletions (shadPS4 overlays per file the same way). The merged folder is built with APFS
  clones (`clonefile`), which costs no space on the same volume; on another volume it copies.
  The free space is checked first.
- (c) **PKG**: an external tool the user installs; the launcher never downloads or bundles one.
  - Recommended: `ps4-pkg-tools` (GPL-2.0, macOS releases, actively maintained). L0.5 with the
    user's PKGs (commit `45baeda`, built from source): base 31 GB in 157 s, update in 1 s; the
    merged folder equals the known-good one byte for byte (except a padded `npbind.dat` the port
    does not read) and passes the check. It has no `--version`: identified by name and usage
    text. It writes into `<out>/<TITLE_ID>/`, prints `Progress: N / M files` (block-buffered when
    piped: the launcher polls the output folder), exits 1 on errors and leaves an empty folder
    behind, and does not detect corrupted content (the game check does).
  - Also detected: `pkgextract`/`orbis-pkg-util`.
  - LibOrbisPkg PkgTool on .NET 6+ is detected and refused or warned about (the stale-sector
    bug; fixes are open PRs #89/#91).
  - Base PKG and update PKG are extracted, then path (b) runs.
  - Delta update PKGs are not supported. The game check catches them (hash mismatch) and the
    error text says a full update is needed.
- **Check**:
  - Quick check at import: title, version, eboot image hash, shader `.dcx`.
  - Thorough check (all `.dcx`) in the background, cached by size and mtime like upstream.
  - Every error has a plain-language explanation and a next step.

**D7 Settings ownership.**
- A profile holds the pre-launch settings: FPS, renderer, render/output size, model LOD, effects,
  patch selection, mod set, the own-saves flag, plus overrides of the live keys as starting values.
- Before each launch the launcher writes the profile's ini keys into `bbport.ini` with the same
  merge semantics as `BbSettings::Save` (unknown lines kept, `.tmp` + rename) and puts the
  env-only settings into the `LaunchSpec`.
- While the game runs, the launcher's settings are read-only.
- After the game exits, the launcher reads `bbport.ini`. Pre-launch keys changed in the game (the
  game menu offers effects and model LOD "after a restart") are taken into the active profile,
  with a notice. Live keys are taken in silently.

**D8 Restart and process control.**
- The overlay's "Apply and restart" no longer execs `bash macos/run.sh`: `bb-probe` exits with a
  dedicated restart code (L0.1). (The overlay is gone since 2026-10-18; the exit code and the
  loops stay for `runtime_restart`, which nothing in the game calls now.) The launcher, and `run.sh` through a small loop, start it again.
- The launcher starts the game with `Process` and writes stdout/stderr to
  `logs/run-<time>.log` (keeps 10).
- Outcomes: exit 0 is a normal end, the restart code relaunches, a signal or an error code shows
  a crash card with the log.
- One instance at a time: a lock file plus a running-process check, because two games at once
  break things (`CLAUDE.md`).

**D9 Prepared-image cache.**
- `out/game` is derived from the eboot only, apart from `patches.bin` and the mod overlay. The
  launcher keeps it per game under `prepared/<title>-<hash>/` and re-runs prepare/link only when
  `eboot.bin` changed.
- `patches.bin` is rebuilt per launch (milliseconds).
- `link_libc.py` leaves the run path once it is confirmed unused (L2.5). Launches then write
  ~0 MB instead of ~390 MB.

**D10 Mods.**
- The semantics are `mods.py`'s:
  - a symlink overlay over the untouched game;
  - `mods.json` with `order`/`disabled`, later wins;
  - only `dvdroot_ps4` content;
  - case-insensitive matching.
- The launcher adds:
  - import of folders and ZIPs (unpacked with the system's `ditto`; 7z/RAR: the user unpacks
    them, with a hint);
  - structure detection with a clear error when a ZIP is not a mod;
  - a per-file conflict view;
  - the mod set as part of the profile.
- `run.sh` gets the documented `BB_MODS_*` wiring too (L4.1), so `docs/MODS.md` is true again.

**D11 Saves.**
- **Backup**: before each launch, the active save root (`savedata/<uid>/<title>` and
  `<title>.memory`) is copied (APFS clones) into `backups/auto/<time>/`, keeping the last 10.
  The user can take named snapshots, restore one (only while the game is not running), and see
  the space used.
- **Export/import**:
  - A whole save is a `.lanternsave` archive (save dir + `sce_sys` + manifest with title, time,
    app version).
  - Single characters only if spike L0.6 shows the slots can be separated safely; otherwise v1
    exports whole saves, and the profile/save view makes clear which characters a save holds.
  - L0.6: no encryption and no checksums. `userdata0000`–`0009` are the ten character slots
    (1.25 MB each, zero-filled when empty), `userdata0010` the global file: options plus ten
    402-byte summary records at `0x108c + 402·n` (u32 occupied flag, UTF-16LE name at +10, u32
    level +44, playtime s +48, echoes +52). Per-character export is the slot file plus its
    record; import into slot m replaces both and removes `backup<m>`. Seen with one occupied
    slot only: it must be confirmed in the game before it ships (L5.2), else whole saves. The
    save view lists name, level, playtime and echoes per slot. `param.bin` holds no account or
    title id (the binding is the path `savedata/1/<title>/SPRJ0005`).
- **Own saves per profile**:
  - a separate `--user` root for savedata, with the GPU cache shared through `BB_GPU_USER_DIR`;
  - checked in L4.4.

**D12 Online (backlog, not in v1; user decision 2026-10-17).**
- v1 ships without online: the launcher never sets `BB_ONLINE` and shows no online page.
- When it is picked up (L7), it first needs the network module ported:
  - build `libbbnet` with `BB_NET=ON` as a dylib;
  - find it via `_NSGetExecutablePath` or an explicit `BB_NET_MODULE`.
- Then the launcher page:
  - on/off;
  - the community server and the shadNet server/WebAPI, with the defaults from `online.py`;
  - NPID and password in the Keychain;
  - a connection test (`online.py check`);
  - `host_overrides.json` written per launch.
- The L7 entry starts with a spike: build `libbbnet` on macOS (`BB_NET=ON`), list what fails,
  estimate the port.

**D13 Updates.**
- Sparkle 2 with an EdDSA key. The private key lives only in a GitHub Actions secret and the
  maintainer's Keychain, never in the repository.
- The appcast is a release asset (or on GitHub Pages).
- Each update replaces the whole bundle (runtime + launcher); Sparkle deltas keep downloads small.
- The launcher detects App Translocation or a read-only location and offers to move itself to
  `/Applications` first; Sparkle cannot update otherwise.
- L0.4 (measured): Sparkle 2.10.0 through SwiftPM (`.package(url: …Sparkle, exact: "2.10.0")`,
  a binary target) updated an ad-hoc signed test app 0.0.1 → 0.0.2 without clicks
  (`SUAutomaticallyUpdate`, installed on quit). Ad hoc to ad hoc is accepted: Sparkle logs a
  cdhash mismatch as "Error" but goes on when the old app has no signing identity; the EdDSA
  signature is the real gate (a flipped signature is refused, 4005/3002). The key is made with
  OpenSSL as a base64 Ed25519 seed and read with `--ed-key-file` (`generate_keys` only works
  through the Keychain, so it is not used): a CI secret, backed up by the maintainer. The XPC
  services can be dropped (non-sandboxed app). The 2.10 archive has no `sparkle-cli`.
  Translocation is detected by the path (`/AppTranslocation/`).

**D14 Signing.**
- v1 is signed ad hoc, inside-out, **without** the hardened runtime. Then no JIT entitlements are
  needed and Sparkle.framework loads without disabling library validation (confirmed in L0.4;
  Sparkle's framework is re-signed with `--options=0`, the app after its Info.plist is final).
- First start: since macOS 15 the user has to use System Settings › Privacy & Security › Open
  Anyway. The DMG has a short illustrated note, and the README explains it.
- Developer ID and notarization come later and are the user's decision. The certificate shows
  the account holder's name, which affects the pseudonymity. Entitlements then needed:
  `allow-unsigned-executable-memory` and `disable-library-validation`, checked under Rosetta in a
  spike before that step.

**D15 CI and releases.**
- GitHub Actions on `macos-26` (arm64; changed from `macos-15` on 2026-10-17: its Xcode 26.3
  rejected code that Xcode 27 builds). The runner is a VM whose paravirtual GPU cannot create a
  Metal residency set: CI skips the `mtl-*` device tests (`BB_TEST_SKIP`), they run on real Macs.
  Its Xcode 26 `swift build` does not compile String Catalogs; `build.sh` compiles them with
  `xcstringstool`. First green run 2026-10-17. The x86-64 runtime is cross-compiled, as `build.sh`
  already does (`clang -arch x86_64`).
- Rosetta is installed on the runner for the x86-64 unit tests.
- `macos/deps` is cached, keyed by the hash of `build-deps.sh` (~200 MB, well under the 10 GB
  limit).
- Not `macos-14`: that image retires on 2026-11-02.
- A tag `vX.Y.Z` builds deps (from the cache), runtime, launcher and tests (`macos/test.sh`, the
  Python tests, `swift test`), then the DMG, signs the appcast and publishes a GitHub Release.

**D16 System checks and hardware presets.**
- **First-run assistant** checks:
  - Rosetta 2 (macOS 27 does not restore it after an upgrade; offer
    `softwareupdate --install-rosetta`);
  - the macOS version: Metal from 15, Vulkan on 14;
  - App Translocation;
  - free disk space.
- **Hardware detection**: chip and GPU core count (IORegistry), RAM.
- **Built-in presets**:
  - "MacBook Air" = today's `m4air` (540p, MetalFX to 1080p, 30 FPS, four effects off,
    model_lod 1).
  - "Pro" and "Max" are conservative estimates, marked as unmeasured until someone with that
    hardware confirms them. Only an M4 Air is available here.
  - "Vanilla" = defaults without mods or patches beyond the FPS patch.
- **Warnings**: battery power, Low Power Mode, a high thermal state.

**D17 Artwork.**
- Since 2026-10-19 (§9) the home page shows no game artwork (`docs/LAUNCHER_DESIGN.md` forbids
  pictures); the points below describe the layout before that and stay for the library code.
- The home page shows `sce_sys/pic1.png` (background) and `icon0.png` (cover) from the user's
  imported game, read at run time and never copied into the repository or the app.
- Before a game is imported, a neutral placeholder is shown.
- The app icon is our own design (a lantern), with no game artwork.

## 4. Mapping: what is reused, ported or new

| Source | Launcher |
|---|---|
| `macos/run.sh` env logic | `LaunchSpec` (Swift), checked against `run.sh --print-env` (D5) |
| `scripts/*.py` | embedded and called in v1 (D4); Swift port in L7 |
| upstream `game_environment()` | reference for `LaunchSpec` fields (fullscreen, gamepad, display, language) |
| upstream mods page, `mods.json` | `ModStore` + mods page, same file format |
| upstream patch profile, `patches.json` | `PatchStore` + patches page, same semantics (store differences only) |
| upstream online page, `online.py check` | online page (backlog, L7) |
| upstream i18n (en, pt_BR, zh_CN, ru) | wording source for the String Catalogs; v1 ships de + en |
| `BbSettings::Save` merge rules | `IniFile` in Swift, tests with the same cases |
| `game_check.py` texts | error texts in the import UI |
| new | import (merge, PKG tool), prepared-image cache, profiles, backups, Sparkle, assistant, packaging, CI |

## 5. Phases

Task marks: **O** orchestrator, **S** `porter` (Sonnet), **H** `scout` (Haiku), as in `CLAUDE.md`.

### L0: Spikes and shared groundwork

| Task | | What | Done when |
|---|---|---|---|
| L0.1 | O | `run.sh --print-env` (dry run: prints env, args and cwd, starts nothing); `bb-probe` exits with a restart code instead of exec'ing `bash macos/run.sh`; `run.sh` loops on it | Restart from the overlay works from run.sh on Metal and Vulkan; bench unchanged |
| L0.2 | S | Spike: package `macos/out` as `Hunter's Lantern Game.app` per D3 (Frameworks, rpaths, Info.plist, ad-hoc signing), start it from outside the repo with the env from `--print-env`; list every cwd/repo dependency that breaks | The game runs from the bundle in `/Applications`; layout confirmed or D3 updated |
| L0.3 | S | Spike: python-build-standalone aarch64 inside a bundle runs the pipeline; measure size and time; no `/usr/bin/python3` used | Numbers in §8; D4 confirmed |
| L0.4 | S | Spike: Sparkle 2 updates an ad-hoc signed test app v0.0.1 → v0.0.2 from a local appcast; behaviour under quarantine and App Translocation | Update works, or D13/D14 updated |
| L0.5 | O | Spike (with the user's PKGs, if available): `ps4-pkg-tools` and `pkgextract` on base + update PKG; merge; game check; time | Recommended tool and its version fixed in D6 |
| L0.6 | S, high | Spike: Bloodborne save layout in `SPRJ0005` (slot files, a global file, checksums); can one character be exported and imported into another save? On copies only | D11 decided: per-character export or whole saves |

Exit: every spike reported in §8, D3/D4/D6/D11/D13 updated, decisions logged in §9.

### L1: Skeleton and dev launcher (→ L-M1)

| Task | | What | Done when |
|---|---|---|---|
| L1.1 | O | `launcher/`: Swift package `LanternCore` + app target, `launcher/build.sh`, `launcher/test.sh` (called from `macos/test.sh`); interfaces `GameLibrary`, `ProfileStore`, `IniFile`, `Pipeline`, `LaunchSpec`, `GameProcess`, `BackupStore`, `ModStore`, `PatchStore` | Builds; empty app opens |
| L1.2 | S | `IniFile`: parse/merge/write with `BbSettings::Save` semantics, atomic | Unit tests incl. foreign lines, `key.*`/`pad.*`, missing file |
| L1.3 | S | `LaunchSpec` from a profile + game + data dirs; test against `run.sh --print-env` for a matrix (m4air, default, uncap, vulkan, non-1080p output) | Test green |
| L1.4 | S, high | `GameProcess`: spawn, log capture, exit and restart codes, single instance, cancel | Unit tests with a fake executable |
| L1.5 | S | UI skeleton: home (artwork, Play, profile picker, status cards), sidebar pages (Game, Profiles, Graphics, Mods, Patches, Saves, Advanced, About) as stubs; import path (a) | Starts the game from the dev build |
| L1.6 | O | Integration: launch on Metal and Vulkan from the launcher, hide while the game runs, show the outcome afterwards; run.sh and bench unchanged | **L-M1** |

### L2: Game import

| Task | | What | Done when |
|---|---|---|---|
| L2.1 | S | Import (a) with the quick check through `Pipeline`; error texts with next steps | All `game_check` failure kinds shown correctly (test folders: wrong version, broken `.dcx`, foreign title) |
| L2.2 | S | Import (b): merge via `clonefile`, copy fallback across volumes, space check, progress, cancel | Merged folder passes the check; no extra space on the same APFS volume |
| L2.3 | S | Import (c): PKG tool detection (PATH, `~/Applications`, chosen path), version, run, progress, refusal of broken tools; then (b) | Works with the tool chosen in L0.5 |
| L2.4 | S | Thorough check in the background, cached by size and mtime | Result shown on the game page |
| L2.5 | O | Prepared-image cache (D9); confirm and drop `link_libc.py` from the run path (run.sh too) | Second launch skips prepare/link; image and bench unchanged |

### L3: Profiles and settings

| Task | | What | Done when |
|---|---|---|---|
| L3.1 | O | Profile model (JSON), built-in presets (D16), editing, duplicate, import/export of a profile | Unit tests; presets give the same env as `BB_PROFILE=m4air` |
| L3.2 | S | Hardware detection and preset suggestion; battery, Low Power Mode and thermal warnings | Suggestion right on the Air |
| L3.3 | S | Pages Graphics/Performance/Advanced (renderer, free `BB_*` variables for experts) | Values reach `bbport.ini`/env (tests) |
| L3.4 | S | Lock while running, take in-game changes into the profile after exit (D7) | Test: an effect changed in the game ends up in the profile |
| L3.5 | S | Patches page: built-in and external XML, `patches.json` semantics, FPS patches locked to the profile's FPS | Same `patches.bin` as run.sh for the same selection |

### L4: Mods

| Task | | What | Done when |
|---|---|---|---|
| L4.1 | O | Wire `mods.py` into `run.sh` (`BB_MODS_*` as `docs/MODS.md` says) and into `Pipeline`; overlay cleanup after the game | A test mod loads from run.sh and from the launcher |
| L4.2 | S | Mod library: import folders and ZIPs (drag & drop), structure detection, rename, delete | Unit tests with mod layouts from `tests/test_mods.py` |
| L4.3 | S | Order, enable/disable, per-file conflict view | UI shows conflicts for two overlapping mods |
| L4.4 | S | Mod set per profile; own saves per profile (separate `--user` root, shared GPU cache), verified in the game | Two profiles with different saves, one shader cache |

### L5: Saves

| Task | | What | Done when |
|---|---|---|---|
| L5.1 | S | Automatic backup before launch (rotation 10), named snapshots, restore, space used | Restore brings back an older state in the game |
| L5.2 | S | Export/import as `.lanternsave` (whole save; per character if L0.6 allows) | Round trip on another data dir loads in the game |
| L5.3 | S | First-start migration of `macos/user` and `macos/bbport.ini` from a repo checkout (optional, asks) | Saves and settings taken over |

### L6: Packaging, release, first run (→ L-M2, L-M3)

| Task | | What | Done when |
|---|---|---|---|
| L6.1 | S | `launcher/package.sh`: app + nested game app + Python + pipeline + patches XML, ad-hoc signing inside-out, DMG | **L-M2** on a clean account (L6.5's setup) |
| L6.2 | S | First-run assistant (D16): Rosetta, macOS, translocation/move, data dir, import | All branches tested by hand |
| L6.3 | S | Sparkle integration, appcast generation, EdDSA key handling | Update v0.9 → v0.9.1 from GitHub Releases works |
| L6.4 | S | GitHub Actions: deps cache, runtime, launcher, all tests, DMG, release on tag | A tag produces a release with DMG and appcast |
| L6.5 | O | Acceptance on a fresh macOS user account (no Homebrew in PATH, no CLT Python): the L-M3 run | **L-M3** |
| L6.6 | S | Minimal diagnostics: log viewer, last crash, open logs, copy system info (no paths, no user names) | Shown after a forced crash |
| L6.7 | S | README sections (DE/EN): install, Open Anyway, import, PKG tool, mods, saves | Reviewed |

### L7: After v1 (backlog, not part of L-M3)

- Online/co-op (D12): spike first (build `libbbnet` on macOS, estimate), then the network module
  (found via `_NSGetExecutablePath`/`BB_NET_MODULE`), then the online page (servers,
  NPID/password in the Keychain, connection test, `host_overrides.json` per launch). Done when
  messages and bloodstains from the community server appear in the game.
- Pipeline in Swift, one module at a time with golden tests (content_profile → patches →
  mods → game_check → prepare/link_modules); `lantern` CLI for `run.sh`; Python removed.
- Controller and keyboard mapping (`key.*`/`pad.*` in the ini; the in-game menu cannot edit
  them, so the launcher is the only place).
- Bug-report bundle (log, settings, system info, anonymised).
- Developer ID and notarization (user decision, D14).
- More languages from upstream's i18n; library extras (playtime, last played).

## 6. Verification

- `LanternCore` unit tests (`swift test`) run in `launcher/test.sh` and from `macos/test.sh`; the
  Python tests in `tests/` are added to `macos/test.sh` too (today they are not run).
- `LaunchSpec` vs `run.sh --print-env` (D5) and `patches.bin` equality (L3.5) are tests, not
  manual checks.
- Every phase ends with a launch from the launcher on Metal and on Vulkan, and run.sh still works.
  Shared-code changes (L0.1, L2.5, L4.1) also get a bench run and screenshot comparison.
- L-M2/L-M3 are checked on a separate macOS user account without developer tools in PATH. A test
  in the bundle fails when anything resolves `python3`, `brew` or the repository.

## 7. Risks and fallbacks

| Risk | Effect | Fallback |
|---|---|---|
| **Rosetta 2 ends**: macOS 27 is the last release with general Rosetta; from macOS 28 only "legacy games" keep a subset, and how a game qualifies is undefined | Affects the whole port, not only the launcher | Test with `game-test-tool` on macOS 27 betas; the Info.plist game category of the nested app (D3) may matter; the long-term answer is outside this plan (arm64 runtime) |
| Characters not separable in the save (L0.6) | Per-character export | Whole-save export, clear UI |
| Gatekeeper friction with ad-hoc signing | Users stuck at first start | Illustrated note in the DMG, README; Developer ID later (D14) |
| Sparkle with ad-hoc signing / translocation | Updates fail | Move-to-Applications check; manual DMG update as fallback |
| PKG tools are young, small projects | Import (c) breaks | Detect several tools; folder import always works |
| Presets for Pro/Max unmeasured | Bad first impression | Conservative values, marked, community feedback |
| Runner images and Rosetta on CI change | Release pipeline breaks | Pin images; `-intel` label as fallback; local `package.sh` keeps working |
| App size (runtime ~50 MB + Python) | Download size | Sparkle deltas; Python goes away in L7 |

## 8. Status and results

**Start here (next session).** State on 2026-10-17 (evening): L0–L2 done, L-M1 met; L3–L6
implemented except what needs the user (below). Read §0, §1 and the checklist below; the
decisions in §9 are fixed.
1. What is open and needs the user:
   - **L6.5 acceptance (L-M3)** on a fresh macOS user account (no Homebrew, no Command Line
     Tools in PATH): open the DMG, import, play, mod, backup, update. Creating that account is
     the user's.
   - **Sparkle's private key** as the GitHub Actions secret `SPARKLE_ED_KEY` (the base64 seed in
     the maintainer's `~/.config/hunters-lantern/sparkle-ed25519.key`; its public half is in
     `launcher/build.sh`), then a first tag `v0.9.0` for a release (the user decides when).
   - **Per-character save import** (L0.6, L5.2) is marked experimental until a character
     imported into another slot has been loaded in the game.
   - **Own saves per profile** (L4.4): two profiles with different saves, one shader cache — to
     be checked in the game.
2. Developer path: `launcher/build.sh --dev` (uses this checkout's `macos/out` and scripts),
   `launcher/test.sh`, `launcher/package.sh` (DMG). Dev hooks for checks without UI access:
   `LANTERN_DATA_DIR` (a scratch data dir), `LANTERN_SNAPSHOT=<dir>` (renders each page to PNG
   in-process and quits; `LANTERN_SNAPSHOT_PAGES=home,game`), `LANTERN_AUTOPLAY=1` (presses Play),
   `LANTERN_IMPORT_BASE/UPDATE` (runs an import). Screen capture does not work from the agent
   shell; the snapshots do.
3. Code review 2026-10-18: `docs/LAUNCHER_REVIEW.md` lists 20 findings (R1–R20) with fixes and
   tests, in batches. All are fixed (2026-10-18, commits ticked off there); open from them: a
   hand check of Cmd-Q during play (R7). Its "smaller improvements" are not done.

Results (2026-10-17):
- **L0.1** `run.sh --print-env`; the overlay's restart exits 75 and run.sh starts the game again
  (tested on Metal and Vulkan with `BB_MENU_KEYS_FILE` token `restart`; on Vulkan the scripted
  keys only work while the overlay is visible, e.g. `show_fps=1`: a pre-existing limit).
- **L0.2** nested game app (`launcher/packaging/make-game-app.sh`): runs from outside the repo on
  Metal and Vulkan (D3).
- **L0.3** embedded Python: see D4 (27 MB pruned, byte-identical outputs, `-E -s -B`).
- **L0.4** Sparkle: see D13 (2.10.0, ad hoc → ad hoc works, EdDSA is the gate).
- **L0.5** PKG: see D6 (ps4-pkg-tools `45baeda`, 157 s for the 31 GB base; merged folder equals
  the known-good one).
- **L0.6** saves: see D11 (plain files, per-slot records; per-character export feasible).
- **L1** LanternCore (data dirs, runtime locator, profiles with presets, IniFile with
  `BbSettings::Save` rules, LaunchSpec tested against `run.sh --print-env` for a matrix,
  GameProcess with lock and restart code, Launcher orchestration), SwiftUI app. **L-M1**: from
  the app the game started on Metal and on Vulkan, the app hid itself, the menu's restart
  started it again from the cached image, the outcome card showed the end.
- **L2** import: (a) folder; (b) merge with per-file `clonefile` (29 GB base in < 5 s, no extra
  space; base never written); (c) PKG via the external tool (the user's PKGs imported in 148 s,
  check passed); thorough check cached by .dcx count/size/mtime. **L2.5**: `link_libc.py` left
  the run path (boot-linked.bin byte-identical); the launcher's image steps are skipped while
  eboot and scripts are unchanged (only `patches.py` runs on later launches).
- **L3** profiles (JSON, presets, duplicate/import/export), hardware suggestion (GPU cores:
  ≤10 Air, ≤20 Pro, else Max), Graphics/Advanced pages, in-game changes back into the profile
  (`LauncherTests`), patches page (L3.5, see below).
- **L4.1** mods from run.sh (`BB_MODS_*` as docs/MODS.md says) and from the launcher (the
  profile's mod set); the overlay feeds only `/app0` and `patches.py`, the image steps read the
  game's eboot (keeps the cache). A mod's file was opened from the mod folder in the game
  (`BB_MOD_TRACE`).
- **L5.1** backups before each launch (APFS clones, 10 kept), snapshots, restore.
- **L6** `launcher/build.sh` (`--dev`, `--bundle`: nested game app, embedded Python, pipeline,
  Sparkle, ad-hoc signing inside-out; 94 MB), `package.sh` (DMG with a bilingual first-start
  note), `packaging/appcast.sh`, GitHub Actions (CI on push, release on tag), first-run
  assistant, Diagnostics page, README sections DE/EN. **L-M2 (partial)**: the bundle, started
  with an empty environment from outside the repo, prepared and ran the game with its own
  Python and runtime (no repo or Homebrew path in any log); the clean-account check is L6.5.
  Sparkle: a 0.9.0 bundle updated itself to 0.9.1 from a signed local appcast.

Sources from the 2026-10-17 research (checked that day, recheck before relying on them):
- PKG tools:
  - ps4-pkg-tools: https://github.com/xXJSONDeruloXx/ps4-pkg-tools
  - pkgextract: https://github.com/paulomanrique/ps4-pkg-extractor
  - orbis-pkg-util: https://github.com/videobitva/orbis
  - LibOrbisPkg stale-sector fixes, open PRs #89 and #91: https://github.com/maxton/LibOrbisPkg
  - why shadPS4 dropped its PKG installer: https://github.com/shadps4-emu/shadPS4/issues/2734
- How shadPS4 overlays an update per file (no deletions): `src/core/file_sys/fs.cpp` in
  shadPS4.
- Sparkle: https://sparkle-project.org/documentation/
  - ad-hoc signed apps and App Translocation:
    https://github.com/sparkle-project/Sparkle/discussions/2688
  - since macOS 15, "Open Anyway" is the only way past Gatekeeper:
    https://developer.apple.com/news/?id=saqachfa
- Python: https://github.com/astral-sh/python-build-standalone/releases (MPL-2.0, aarch64
  `install_only_stripped` ~26 MB compressed).
- Rosetta's end:
  https://developer.apple.com/documentation/apple-silicon/about-the-rosetta-translation-environment
  - https://developer.apple.com/news/?id=w5ngl9k2
  - macOS 27 release notes, Gaming (`game-test-tool`):
    https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes
- CI images: https://github.com/actions/runner-images
  - `macos-14` retires on 2026-11-02;
  - the cache limit is 10 GB per repository.

- [x] L0.1–L0.6 spikes and groundwork
- [x] L1 skeleton and dev launcher → L-M1 (met 2026-10-17)
- [x] L2 game import
- [x] L3 profiles and settings
- [x] L4 mods (L4.4 own saves: in-game check open)
- [x] L5 saves (per-character import experimental until checked in the game)
- [ ] L6 packaging, release, first run → L-M2 (partial: clean account open), L-M3 (L6.5, the
  user's acceptance run; the release secret and first tag are the user's)

Found during the inventory (fix when the task touching the file comes up):
- `live_resolution` has no runtime reader; the comment in `bbport_settings.cpp` (Save) says
  run.sh reads it, which is false (run.sh reads `BB_LIVE_RES`).
- `patches.py --output-res` is parsed but never used.
- ~~`docs/MODS.md` documents `BB_MODS_*` for run.sh, which does not implement them~~ (fixed in
  L4.1).
- ~~`macos/test.sh` does not run the Python tests in `tests/`~~ (it does now, with the
  launcher's).
- Env overrides read by `BbSettings::Load` are written into the ini by the next Save.
- `skip_intro`, `debug_camera` and `debug_menu` are bbport.ini keys (the game menu's) and also
  built-in extras on the Patches page (BB_PATCHES): either source turns the patch on. Decide
  whether the launcher owns those keys (found in L3.5).
- After an experimental per-character import, the game's `backup0010` is older than
  `userdata0010`: check in the game whether that matters (L5.2).

## 9. Decision log

- 2026-10-17 (user): new macOS launcher planned. Public `.app` in a DMG; SwiftUI; pipeline
  embedded as Python in v1 and ported to Swift step by step; import of a ready folder, base +
  update, and PKG through an external tool; settings split (launcher before launch, in-game menu
  live, one ini); profiles as complete packages; local mods only; home page + sidebar; releases
  by GitHub Actions; Apple silicon, macOS 14+; plan in this format; v1 also contains save backups
  with export/import, Sparkle updates (and online/co-op, moved to the backlog later the same day,
  see below); the launcher locks settings while the game
  runs; L-M3 acceptance as proposed; name "Hunter's Lantern"; signing decided later (ad hoc until
  then).
- 2026-10-17 (orchestrator, from the inventory): online needs the network module ported first
  (not built on macOS, D12); the launcher builds its own `LaunchSpec` checked against
  `run.sh --print-env` rather than calling run.sh (D5); restart through an exit code instead of
  exec'ing run.sh (D8); prepared-image cache (D9); nested game app for name, icon and Game Mode
  (D3); recommended PKG tool `ps4-pkg-tools`, LibOrbisPkg on .NET 6+ refused (D6).
- 2026-10-17 (user): online/co-op is not part of v1.0 and goes to the backlog (L7), after the
  inventory showed the network module is not built on macOS. Removed: phase "Online", spike
  L0.7, the online page in v1; phases after it renumbered (packaging is now L6, the backlog L7).
- 2026-10-17 (orchestrator, L0/L1 evidence): no Xcode project — the app is a SwiftPM executable
  assembled by `launcher/build.sh` (D2; reviewable files, String Catalogs compile with
  `swift build`). Python runs with `-E -s -B`, not `-I` (D4). ps4-pkg-tools is the recommended
  PKG tool, identified by name and usage text (no version flag) (D6). Per-character save export
  is feasible (no checksums), import experimental until confirmed in the game (D11). Sparkle
  2.10.0 via SwiftPM, the EdDSA key made with OpenSSL and read with `--ed-key-file`, no Keychain
  (D13). The mod overlay feeds only `/app0` and `patches.py`; the image steps read the game's
  own eboot so the prepared-image cache survives mods (D9, D10). `link_libc.py` left the run
  path (L2.5): boot-linked.bin is byte-identical without it.
- 2026-10-18 (user): the ImGui overlay (L3+R3 / Insert) is removed, with no replacement menu.
  Live settings are the game menu's pages, everything else is the launcher's (profile ini keys,
  `BB_*` variables on the Advanced page: jitter, reactive mask, character motion vectors,
  sharpness). No in-game restart or quit (the game's own quit is enough); FSR 4/4.1.1 and DLSS
  settings go with it (not available on macOS: MoltenVK lacks compute shader derivatives, the
  Metal path never had them). The FPS counter (`show_fps`) is Apple's Metal performance HUD on
  the window's `CAMetalLayer` (both renderers), the game's text dialog an AppKit sheet on the
  window (`gpu/shim/bbport_mac_window.mm`). Metal loads its HUD only with `MTL_HUD_ENABLED=1` at
  device creation, so the window sets it in-process (unless the user set it) and
  `developerHUDProperties` (`mode` default/disabled) show and hide it; Dear ImGui and the DejaVu
  fonts left the build and the repository.
- 2026-10-19 (user): new visual design, `docs/LAUNCHER_DESIGN.md`, after mock-ups of a
  console-style home, four launcher patterns and a reworked library page were rejected as too
  generic. One fixed 960 × 600 window in Victorian gothic replaces the home page + sidebar
  layout (a fixed point, changed by the user); choices are register entries, not pop-up menus;
  no game artwork on the home page (D17); the four fonts are bundled (OFL, approved as a new
  dependency); implementation stays SwiftUI (D2); pages that do not fit the window become sheets
  in the same style. The implementation phase is planned when it starts.
