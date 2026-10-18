// SPDX-License-Identifier: GPL-2.0-or-later
// bbport: user settings changed at run time from the game's System menu (bbport_game_menu.h) and kept
// in bbport.ini (BB_CONFIG overrides the path). Environment variables override the file at
// start. Readers load the atomics every frame; writers are the menu and Load().

#pragma once

#include <atomic>

namespace BbSettings {

enum Upscaler : int { UpscalerOff = 0, UpscalerFsr3 = 1, UpscalerTaa = 2, UpscalerMetalFx = 3,
                      UpscalerCount };
enum Preset : int { NativeAA = 0, Quality, Balanced, Performance, UltraPerformance, PresetCount };
enum DebugView : int { DebugNone = 0, DebugReactive = 1, DebugMotion = 2, DebugViewCount };
enum class MenuLanguage { English, Russian };

/// Game effects switched by the community patches at start (patches.py EFFECTS): ini key,
/// menu label, default (the game's own behaviour).
struct Effect {
    const char* key;
    const char* label;
    const char* label_ru;
    bool default_on;
};
inline constexpr Effect Effects[] = {
    {"effect_chromatic_aberration", "Chromatic aberration", "Хроматическая аберрация", true},
    {"effect_dof", "Depth of field (DoF)", "Глубина резкости (DoF)", true},
    {"effect_motion_blur", "Motion blur", "Размытие в движении", true},
    {"effect_ssao", "Ambient occlusion (SSAO)", "Затенение SSAO", true},
    {"effect_game_aa", "Game's own anti-aliasing", "Собственное сглаживание игры", true},
    {"effect_dynamic_shadows", "Shadows from dynamic lights", "Тени от динамических источников", true},
    {"effect_ssr", "Screen-space reflections (not in original game)", "Отражения SSR (не было в игре)", false},
    {"skip_intro", "Skip startup intros", "Пропуск заставок при запуске", false},
    {"debug_camera", "Free camera (Cross + L3)", "Свободная камера (Cross + L3)", false},
    {"debug_menu", "Debug menu (requires font files)", "Debug menu (нужны файлы шрифтов)", false},
};
inline constexpr int EffectCount = int(sizeof(Effects) / sizeof(Effects[0]));
/// Live output resolutions: the upscaler's output and the UI host targets.
inline constexpr int OutputWidths[] = {1280, 1920, 2560, 3840};
inline constexpr int OutputHeights[] = {720, 1080, 1440, 2160};
inline constexpr int OutputCount = 4;
inline constexpr int OutputDefault = 1; ///< 1920x1080, the game's own size

struct Values {
    std::atomic<MenuLanguage> menu_language{MenuLanguage::Russian};
    std::atomic<int> upscaler{UpscalerFsr3};
    std::atomic<int> preset{NativeAA};
    std::atomic<bool> sharpen{true};
    std::atomic<float> sharpness{0.3f};
    std::atomic<bool> jitter{true};
    std::atomic<bool> reactive{false};
    // bbport: off by default on Apple GPUs: the vertex shaders' position stores for per-object
    // motion vectors (~3.5 million vertices a frame in Bloodborne) cost about a quarter of the
    // frame time on an M4; FSR 3 then works from camera motion alone.
#ifdef __APPLE__
    std::atomic<bool> object_motion{false};
#else
    std::atomic<bool> object_motion{true};
#endif
    std::atomic<float> reactive_scale{1.0f};
    std::atomic<float> reactive_threshold{0.2f};
    std::atomic<float> reactive_max{0.9f};
    std::atomic<int> debug_view{DebugNone};
    std::atomic<bool> show_fps{false}; ///< the Metal performance HUD (bbport_mac_window.h)
    std::atomic<int> active_render_width{1920}, active_render_height{1080};
    /// Applied at start (patches.py); the menu shows when a restart is needed.
    std::atomic<bool> effects[EffectCount]{};
    std::atomic<int> model_lod{0}; ///< -2 highest .. 2 lowest, 0 the game's
    std::atomic<int> output_res{OutputDefault}; ///< index into OutputWidths
    /// Live resolution and preset changes (run.sh): 0 off by default (startup patch, fastest
    /// on the Steam Deck and older GPUs), -1 auto (strong discrete GPUs), 1 on. On restart.
    std::atomic<int> live_resolution{0};
    /// The providers each backend offers (the menus list a provider only when set): the Vulkan
    /// backend has FSR 3.1 and TAA, the Metal backend only MetalFX (ConfigureMetalUpscalers).
    std::atomic<bool> fsr3_supported{true}, taa_supported{true}, metalfx_supported{false};

    /// Startup settings for the explicit BB_RENDER_RES compatibility patch only.
    int startup_preset = NativeAA;
    int startup_upscaler = UpscalerFsr3;
#ifdef __APPLE__
    bool startup_object_motion = false;
#else
    bool startup_object_motion = true;
#endif
    bool startup_effects[EffectCount]{};
    int startup_model_lod = 0;
    int startup_output_res = OutputDefault;
    int startup_live_resolution = 0;
};

Values& Get();
/// Reads the file, then the environment overrides. Called once at start.
void Load();
/// Checks the loaded choice before the first frame (Vulkan): MetalFX only exists on Metal, so
/// it becomes FSR 3.1.
void ConfigureUpscalerSupport();
/// The Metal backend, before the first frame: FSR 3.1 and TAA do not exist there,
/// MetalFX (`metalfx`: the device supports MTLFXTemporalScaler) is the only provider besides
/// Off. A loaded choice of an absent provider becomes MetalFX (Off without it) and is printed.
void ConfigureMetalUpscalers(bool metalfx);
/// Startup-patched scene dimensions cannot change until run.sh prepares a new image.
bool FixedRenderSession();
int RenderPreset();
bool ResolutionNeedsRestart();
/// Writes the file (menu changes).
void Save();

/// Render resolution divisor of a preset (1.0 native, 1.5 quality, ...).
float PresetScale(int preset);
const char* PresetName(int preset);
const char* UpscalerName(int upscaler);

/// Scripted live changes (tests): BB_PRESET_FILE=<file> holds "preset [output [upscaler]]".
/// Called once per frame with the caller's own frame counter; reads the file every 64th call and
/// stores the fields that are in range into the settings, like the menu does.
void PollPresetFile(unsigned& frame_counter);

} // namespace BbSettings
