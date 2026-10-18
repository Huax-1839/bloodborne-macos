# bloodborne-macos

*Bloodborne* (PlayStation 4, game version 1.09) running natively on Apple silicon Macs.

The game's own x86-64 executable runs directly under Rosetta 2 inside a single process. A runtime
written for this one game replaces the PS4 system libraries, and the game's GPU command stream is
translated to **Metal**. There's no console emulation and no virtual machine, and no game code is
recompiled: it's the same idea as Wine + DXVK, for one game and one platform.

> **No game files are included.** You need your own decrypted dump of Bloodborne with update 1.09.
> This project is not affiliated with Sony Interactive Entertainment, FromSoftware or Apple.

**Status: experimental, playable.** The game boots and runs its intro movies, menus, character
creation and gameplay with sound, gamepad and saving. Most testing so far took place in the opening
areas.

## Highlights

- **Direct Metal renderer** (the default on macOS 15 or newer). The game's shaders are translated
  from GCN to SPIR-V and then to MSL, and its memory is shared with the GPU without copies
  (no-copy Metal buffers on unified memory). It produces the same image as the Vulkan renderer and
  is faster (see [Performance](#performance)).
- **MetalFX temporal upscaling** with live presets (Native AA to Ultra Performance), and optional
  **MetalFX frame interpolation** on macOS 26 or newer.
- **30 FPS on a fanless MacBook Air M4** with the `m4air` profile (720p scene upscaled to 1080p;
  about 52 FPS uncapped even in Central Yharnam). The earlier 540p scene (`BB_RENDER_RES=960x540`)
  passed the project's strict 20-minute 30-FPS rule on power and on battery.
- **Vulkan renderer through MoltenVK** as an alternative (`BB_RENDERER=vulkan`).
- The game's own settings menu gains *Display* and *Effects* pages (output resolution, upscaler,
  preset, FPS counter, model detail, effects), plus an overlay menu with advanced settings
  (L3+R3 on a gamepad, or Insert on an external keyboard).
- Gamepad through SDL3, plus keyboard and mouse. The 60 FPS mode and community game patches can be
  switched on in the settings.

## Requirements

- A Mac with Apple silicon and Rosetta 2 (`softwareupdate --install-rosetta`). Tested on a MacBook
  Air M4 (10-core GPU, 16 GB) running macOS 27.
- macOS 15 or newer for the Metal renderer. Older systems fall back to Vulkan through MoltenVK.
- Xcode Command Line Tools, and from Homebrew: `cmake ninja pkgconf glslang boost`.
- Your game dump: the `CUSA03173` folder (`eboot.bin`, `sce_sys`, `sce_module`, …) with the 1.09
  update copied over it, replacing files. The other retail releases (US `CUSA00900`, …) ship the
  same 1.09 executable. Use an unmodified `eboot.bin`: an executable with a 60 FPS patch baked in
  crashes later.

## Hunter's Lantern: the app

**Hunter's Lantern** is a native launcher that needs no Terminal, Xcode, Homebrew or Python: it
carries the game runtime and everything the game preparation needs. Its source is in
[`launcher/`](launcher) and its plan in [`docs/LAUNCHER_PLAN.md`](docs/LAUNCHER_PLAN.md).

1. **Install.** Download `HuntersLantern-<version>.dmg` from the
   [Releases](https://github.com/Huax-1839/bloodborne-macos/releases) page, open it and drag the app
   onto *Applications*. The app is signed ad hoc, not notarized: the first time, macOS refuses to
   open it. Click *Done*, open *System Settings › Privacy & Security*, click **Open Anyway** next to
   Hunter's Lantern and confirm. The first-run assistant then checks Rosetta 2, the macOS version
   and free space.
2. **Bring your game.** On the *Game* page, either
   - add a ready game folder (Bloodborne with update 1.09 applied; it stays where it is),
   - merge the base game and the 1.09 update from two folders (APFS clones: almost no extra space
     on the same disk), or
   - import the base game and update **PKG files**. The app has no PKG code of its own: install an
     external tool, [ps4-pkg-tools](https://github.com/xXJSONDeruloXx/ps4-pkg-tools) recommended
     (`pkgextract` and `orbis-pkg-util` are detected too; LibOrbisPkg PkgTool is refused because it
     damages files). Hunter's Lantern finds it in `PATH`, Homebrew or `~/Applications`, or you
     choose it. A delta update PKG does not work: use the full 1.09 update.

   Every import is checked (title, version 1.09, the executable, the shaders); a thorough check of
   all files can run in the background.
3. **Pick a profile.** Built-in presets: *MacBook Air* (measured: 720p scene, MetalFX to 1080p,
   30 FPS), *Pro* and *Max* (estimates, marked as unmeasured) and *Vanilla*. The launcher suggests
   one for your Mac. Duplicate a preset to change frame rate, renderer, scene size, effects, patches
   and mods; settings you change in the game's menu are taken back into the profile.
4. **Mods.** On the *Mods* page add mod folders or ZIP files (loose files for `dvdroot_ps4`), put
   them in order and switch them on per profile; files several mods replace are listed. The game's
   own files are never changed: mods are linked over them for each start.
5. **Saves.** Before every start the save is backed up (the last 10 are kept, APFS clones); you can
   take named snapshots, restore one, and export or import a save as a `.lanternsave` file.
6. **Play.** The launcher steps aside while the game runs and shows how it ended; the *Diagnostics*
   page has the logs and system information for bug reports. Updates arrive through the app itself
   (Sparkle).

Settings, saves, logs and prepared files live in `~/Library/Application Support/HuntersLantern/`.

### Deutsch

**Hunter's Lantern** ist ein eigenständiger Launcher ohne Terminal, Xcode, Homebrew oder Python.

1. **Installieren.** Lade `HuntersLantern-<Version>.dmg` von der
   [Releases](https://github.com/Huax-1839/bloodborne-macos/releases)-Seite, öffne es und ziehe die
   App in *Programme*. Die App ist nur ad hoc signiert (nicht notarisiert): Beim ersten Mal lehnt
   macOS das Öffnen ab. Klicke auf *Fertig*, öffne *Systemeinstellungen › Datenschutz & Sicherheit*,
   klicke neben Hunter's Lantern auf **Trotzdem öffnen** und bestätige. Danach prüft der
   Einrichtungsassistent Rosetta 2, die macOS-Version und den freien Speicher.
2. **Spiel hinzufügen** (Seite *Spiel*): ein fertiger Spielordner (Bloodborne mit Update 1.09),
   Basisspiel und 1.09-Update aus zwei Ordnern (werden mit APFS-Klonen zusammengeführt) oder die
   beiden **PKG-Dateien**. Für PKGs brauchst du ein externes Werkzeug, empfohlen
   [ps4-pkg-tools](https://github.com/xXJSONDeruloXx/ps4-pkg-tools); die App selbst enthält keinen
   PKG-Code. Ein Delta-Update-PKG funktioniert nicht, nötig ist das vollständige 1.09-Update.
3. **Profil wählen:** *MacBook Air* (gemessen: 720p, MetalFX auf 1080p, 30 FPS), *Pro* und *Max*
   (geschätzt, als ungemessen markiert) oder *Vanilla*. Zum Ändern ein Profil duplizieren.
4. **Mods** (Seite *Mods*): Ordner oder ZIP-Dateien hinzufügen, sortieren, pro Profil einschalten.
   Die Spieldateien bleiben unverändert.
5. **Spielstände:** Vor jedem Start wird gesichert (die letzten 10 bleiben); Schnappschüsse,
   Wiederherstellen sowie Export und Import als `.lanternsave`.
6. **Spielen.** Während das Spiel läuft, tritt der Launcher zur Seite und zeigt danach das Ergebnis;
   die Seite *Diagnose* enthält Protokolle und Systeminformationen für Fehlerberichte. Updates
   kommen über die App selbst (Sparkle).

## Build and run

```bash
git clone --recursive https://github.com/Huax-1839/bloodborne-macos.git
cd bloodborne-macos
bash macos/build-deps.sh                  # once: the x86-64 libraries (macos/deps)
bash macos/build.sh                       # macos/out: the loader and the renderer

BB_GAME_DIR=/path/to/CUSA03173 bash macos/run.sh
BB_PROFILE=m4air bash macos/run.sh        # MacBook Air: 720p scene, MetalFX to 1080p, 30 FPS cap
```

Without `BB_GAME_DIR`, the game is expected in `~/Games/Bloodborne/CUSA03173-1.09`. Settings are
stored in `macos/bbport.ini`, and saves and the shader cache in `macos/user/`.

Useful switches:

| Variable | Effect |
|---|---|
| `BB_RENDERER=metal\|vulkan` | Choose the renderer (default: Metal on macOS 15+) |
| `BB_PROFILE=m4air` | 30 FPS profile for fanless Macs: 1280×720 scene, costly effects off, one model detail level lower |
| `BB_RENDER_RES=1280x720` | Fixed internal resolution, upscaled to the output |
| `BB_FPS=30` | Frame rate cap |
| `BB_LIVE_RES=1` | Keep live resolution changes from the menu at outputs other than 1080p |
| `BB_FRAME_INTERPOLATION=1` | MetalFX frame interpolation (macOS 26+): twice the frames on screen at the cost of latency; only worth it when the game holds 30 FPS |
| `BB_SETTINGS=key=value,…` | Override `bbport.ini` entries for one run |
| `BB_GAMEPAD=<name or GUID>` | Pick a gamepad when several are connected |

## Performance

All numbers were measured on a MacBook Air M4 (10-core GPU, 16 GB, fanless) in Iosefka's clinic,
with the same save. "Uncapped" is the frame rate without the 30 FPS cap; "20 min" is a 20-minute
walk with the cap, the mean over the whole run.

How the frame rate developed:

| Date | Step | `m4air` uncapped (540p → 1080p) | 30 FPS cap, 20 min | 720p scene |
|---|---|---|---|---|
| 2026-10-14 | Starting point: Vulkan (MoltenVK) only | 31.2 FPS | — | 22.6 FPS uncapped |
| 2026-10-14 | First Metal renderer, same image, unoptimised (P4/P5) | 24.7 FPS (Vulkan 31.8) | — | — |
| 2026-10-15 | Metal optimised: kernel submission and residency (P6, milestone M2) | 32.2 FPS (Vulkan 29.2) | — | 24.9 FPS with the cap (P7) |
| 2026-10-16 | Hitches fixed: guest memory out of the residency set (P8.5) | — | 30.0 FPS, on power and battery | — |
| 2026-10-16 | Looser float rules in fragment and compute shaders (P9.1) | **43.6 FPS** (33.1 before, same session) | — | **30.0 FPS with the cap, 20 min** |

Values from different days differ by up to ~15% with the Air's temperature (Vulkan's own uncapped
rate ranged 29–33 FPS), so compare within a row.

The last step removed a compile setting that made every floating-point operation of the game's
shaders an unoptimisable function call: the GPU now needs 16.5 ms a frame at 540p (was 24.7) and
24.6 ms at 720p (was 37.3), with the same image. Positions and depth keep the strict rules, and no
flicker or z-fighting showed up in the checks. `BB_MTL_STRICT_FLOAT=1` restores the old behaviour.

The Metal vs Vulkan comparison of milestone M2 (three interleaved runs each, before P9.1):

| Profile | Metal | Vulkan (MoltenVK) |
|---|---|---|
| `m4air`, uncapped (540p → 1080p) | 32.2 FPS | 29.2 FPS |
| `m4air`, 30 FPS cap | 29.4 FPS | 26.8 FPS |
| native 1080p | 9.8 FPS | 8.9 FPS |

Since P9.1 Metal runs `m4air` uncapped at ~44 FPS against ~33 FPS for Vulkan on the same evening
(single runs, not the interleaved M2 protocol). Machines with more GPU cores or active cooling
have more headroom. The detailed measurements are in `docs/METAL_BACKEND_PLAN.md` §8.

Known limitations:
- **Hitches.** Metal's worst frames are longer than Vulkan's: in the latest 20-minute runs with
  the cap, 1.3–2.3% of frames miss their 30-FPS slot and the longest frame is 67–83 ms. What is
  left comes mostly from the kernel's command-buffer submission, which slows down when the
  machine is hot.
- **Measured in one place.** All numbers come from Iosefka's clinic; busier areas such as Central
  Yharnam haven't been benchmarked yet.
- **No online play or PSN.** The game starts offline.
- **No FSR 4 or DLSS.** On the Mac, MetalFX takes the place of the upscalers.

## How it works

1. **Loader** (`src/probe.c`): maps the game's executable and modules into the PS4 address range,
   rewrites thread-local storage access and links the game's imports to the runtime.
2. **Runtime** (`src/`, `gpu/shim/`): replaces the PS4 system libraries (kernel, threads, memory,
   files, audio, pad, savedata, video output) with host implementations.
3. **GPU front end** (`gpu/cp/`, `gpu/shadps4/video_core/amdgpu/`): decodes the PM4 command stream
   and the GCN register state.
4. **Shader recompiler** (`gpu/shadps4/shader_recompiler/`): GCN → IR → SPIR-V. On Metal, SPIRV-Cross
   then turns the SPIR-V into MSL.
5. **Metal backend** (`gpu/shadps4/video_core/renderer_metal/`): render passes, pipeline and
   texture caches, synchronisation, geometry shaders emulated with compute, MetalFX upscaling and
   UI composition. The Vulkan backend (`renderer_vulkan/`) sits beside it.

Design notes and measurements: [Metal backend plan and results](docs/METAL_BACKEND_PLAN.md),
[Metal design documents](docs/metal/), [port state and history](macos/HANDOFF.md).

## Development

- Unit tests: `bash macos/test.sh` (or `bash macos/test.sh <target>…`).
- Benchmarks: `macos/bench/bench.sh <name> [ENV=VAL…]`; image comparison with
  `macos/bench/imgdiff.py A.png B.png`.
- Metal validation: `MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=nslog`. GPU traces:
  `xcrun xctrace record --template 'Metal System Trace' --attach <pid>`.
- Run only one game instance at a time, and run benchmarks on an otherwise idle machine.

Report problems in this repository's [issues](https://github.com/Huax-1839/bloodborne-macos/issues).
Please include your Mac model, macOS version and renderer, plus the end of the log.

## Credits and licenses

Built on [bbport](https://github.com/deadinside28/bloodborne_pc) by **deadinside28**, which
contributed the loader, runtime and renderer this port starts from.

Licensed under the **GNU GPL v2 or later** ([LICENSE](LICENSE)). Third-party components keep their
licenses:
- [shadPS4](https://github.com/shadps4-emu/shadPS4): video core and shader recompiler (GPL-2.0+)
- [sirit](https://github.com/shadps4-emu/sirit)
- [SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross) (Apache-2.0)
- [MoltenVK](https://github.com/KhronosGroup/MoltenVK) (Apache-2.0)
- [half](https://half.sourceforge.net/) (MIT)
- [FSR-Vulkan](https://github.com/FireBurn/FSR-Vulkan) by FireBurn and the AMD FidelityFX SDK (MIT)
- [LibAtrac9](https://github.com/Thealexbarney/LibAtrac9) (MIT)
- [Dear ImGui](https://github.com/ocornut/imgui) (MIT)
- [cpp-httplib](https://github.com/yhirose/cpp-httplib) (MIT)
- DejaVu fonts
- the DLSS bridge and loader parts by [Supermedo](https://github.com/Supermedo/bloodborne_pc) and
  [IFreemz](https://github.com/IFreemz/shadPS4-Bloodborne-DLSS-FSR)

Game patches (`patches/Bloodborne.xml`) are by Kyo, Lance McDonald, auser1337, illusion, emoose
and other community members.
