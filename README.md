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
  is about 10% faster.
- **MetalFX temporal upscaling** with live presets (Native AA to Ultra Performance), and optional
  **MetalFX frame interpolation** on macOS 26 or newer.
- **30 FPS on a fanless MacBook Air M4** with the `m4air` profile (540p scene upscaled to 1080p),
  on power and on battery.
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

## Build and run

```bash
git clone --recursive https://github.com/Huax-1839/bloodborne-macos.git
cd bloodborne-macos
bash macos/build-deps.sh                  # once: the x86-64 libraries (macos/deps)
bash macos/build.sh                       # macos/out: the loader and the renderer

BB_GAME_DIR=/path/to/CUSA03173 bash macos/run.sh
BB_PROFILE=m4air bash macos/run.sh        # MacBook Air: 540p scene, MetalFX to 1080p, 30 FPS cap
```

Without `BB_GAME_DIR`, the game is expected in `~/Games/Bloodborne/CUSA03173-1.09`. Settings are
stored in `macos/bbport.ini`, and saves and the shader cache in `macos/user/`.

Useful switches:

| Variable | Effect |
|---|---|
| `BB_RENDERER=metal\|vulkan` | Choose the renderer (default: Metal on macOS 15+) |
| `BB_PROFILE=m4air` | 30 FPS profile for fanless Macs: 960×540 scene, costly effects off, one model detail level lower |
| `BB_RENDER_RES=1280x720` | Fixed internal resolution, upscaled to the output |
| `BB_FPS=30` | Frame rate cap |
| `BB_LIVE_RES=1` | Keep live resolution changes from the menu at outputs other than 1080p |
| `BB_FRAME_INTERPOLATION=1` | MetalFX frame interpolation (macOS 26+): twice the frames on screen at the cost of latency; only worth it when the game holds 30 FPS |
| `BB_SETTINGS=key=value,…` | Override `bbport.ini` entries for one run |
| `BB_GAMEPAD=<name or GUID>` | Pick a gamepad when several are connected |

## Performance

The numbers below were measured on a MacBook Air M4 (10-core GPU, 16 GB) in Iosefka's clinic, with
the same save and camera; each value is the mean of three interleaved runs:

| Profile | Metal | Vulkan (MoltenVK) |
|---|---|---|
| `m4air`, uncapped (540p → 1080p) | 32.2 FPS | 29.2 FPS |
| `m4air`, 30 FPS cap | 29.4 FPS | 26.8 FPS |
| native 1080p | 9.8 FPS | 8.9 FPS |

After later fixes, the `m4air` profile held 30.0 FPS on average over 20 minutes, on power and on
battery. A 720p scene averages 25–29 FPS and doesn't hold 30 on the fanless Air. Machines with more GPU
cores or active cooling have more headroom.

Known limitations:
- **Hitches.** Metal's worst frames are longer than Vulkan's. They come from the kernel's
  command-buffer submission, which slows down when the machine is hot.
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
