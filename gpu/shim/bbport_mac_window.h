// SPDX-License-Identifier: GPL-2.0-or-later
// bbport (macOS): what the game window shows besides the game frame, with AppKit and Core
// Animation: Apple's Metal performance HUD as the FPS counter (show_fps), and the game's text
// dialog (ImeDialog) as a sheet on the window. Both run on the window thread, which is the main
// thread on macOS (bbgpu_window_loop). Plain C++ interface; the implementation is ARC Objective-C++.
#pragma once

#include <functional>
#include <string>

struct SDL_Window;

namespace BbMacWindow {

/// Before the window and the first Metal device: lets Metal load its HUD (hidden until
/// SetPerformanceHud shows it).
void PrepareMetalHud();

/// Shows or hides the Metal performance HUD on the window's CAMetalLayer (both renderers present
/// through it; MoltenVK too). Cheap to call every poll: only a change reaches the layer.
void SetPerformanceHud(void* metal_layer, bool on);

/// Opens a sheet with a text field on `window`: `prompt` as its message, `initial` as the text.
/// `done` runs once on the main thread, with 1 and the text for OK (Return), 2 for Cancel (Escape).
/// Returns false when there is no Cocoa window (the caller falls back to SDL text input).
bool BeginTextSheet(SDL_Window* window, const std::string& prompt, const std::string& initial,
                    std::function<void(int state, const std::string& text)> done);

} // namespace BbMacWindow
