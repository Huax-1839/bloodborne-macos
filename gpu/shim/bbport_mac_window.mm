// SPDX-License-Identifier: GPL-2.0-or-later
// bbport (macOS): the Metal performance HUD and the text sheet (bbport_mac_window.h).

#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#include <SDL3/SDL.h>

#include <cstdlib>

#include "bbport_mac_window.h"

namespace {
bool managed = false; ///< PrepareMetalHud set MTL_HUD_ENABLED: the HUD follows show_fps
} // namespace

namespace BbMacWindow {

void PrepareMetalHud() {
    // Metal loads its HUD only in a process started with MTL_HUD_ENABLED=1; the layer's
    // developerHUDProperties then only show or hide it (without, they do nothing). Set here,
    // before the first Metal device exists. A value the user set (0 or 1) is left alone: the HUD
    // is theirs then, and SetPerformanceHud does not touch it.
    if (!std::getenv("MTL_HUD_ENABLED")) {
        setenv("MTL_HUD_ENABLED", "1", 1);
        managed = true;
    }
}

void SetPerformanceHud(void* metal_layer, bool on) {
    static void* applied_layer = nullptr;
    static bool applied = false;
    if (!managed || !metal_layer || (metal_layer == applied_layer && on == applied)) {
        return;
    }
    applied_layer = metal_layer;
    applied = on;
    if (@available(macOS 13.0, *)) {
        CAMetalLayer* layer = (__bridge CAMetalLayer*)metal_layer;
        layer.developerHUDProperties = on ? @{@"mode" : @"default"} : @{@"mode" : @"disabled"};
    }
}

bool BeginTextSheet(SDL_Window* window, const std::string& prompt, const std::string& initial,
                    std::function<void(int state, const std::string& text)> done) {
    NSWindow* parent = (__bridge NSWindow*)SDL_GetPointerProperty(
        SDL_GetWindowProperties(window), SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, nullptr);
    if (!parent) {
        return false;
    }
    @autoreleasepool {
        NSAlert* alert = [[NSAlert alloc] init];
        alert.messageText = [NSString stringWithUTF8String:prompt.c_str()] ?: @"";
        [alert addButtonWithTitle:@"OK"];
        [alert addButtonWithTitle:@"Cancel"]; // the second button answers Escape
        NSTextField* field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)];
        field.stringValue = [NSString stringWithUTF8String:initial.c_str()] ?: @"";
        alert.accessoryView = field;
        [alert layout];
        alert.window.initialFirstResponder = field;
        [alert beginSheetModalForWindow:parent
                      completionHandler:^(NSModalResponse response) {
                          const bool ok = response == NSAlertFirstButtonReturn;
                          const char* text = field.stringValue.UTF8String;
                          done(ok ? 1 : 2, ok && text ? std::string(text) : std::string());
                      }];
    }
    return true;
}

} // namespace BbMacWindow
