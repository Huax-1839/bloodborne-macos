// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import LanternCore
import SwiftUI

@main
struct HuntersLanternApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // One window (docs/LAUNCHER_DESIGN.md), at least 960 × 600; it opens a little larger and
        // can grow, so text is never squeezed into a fixed print.
        Window("Hunter's Lantern", id: "main") {
            RootView()
                .environmentObject(delegate.model)
                .preferredColorScheme(.dark)
                .tint(Print.brass)
                .task { await Snapshot.runIfRequested(delegate.model) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(Print.windowDefault)
        .commands {
            UpdateCommands(updater: delegate.updater)
            GoCommands(model: delegate.model)
        }
    }
}

/// Owns the model and the updater, and asks before quitting while a game runs (R7): the game
/// would go on without its launcher, the in-game setting changes and the outcome card would be
/// lost, and Sparkle could install an update into the bundle the game runs from.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    let updater: Updater

    override init() {
        Print.registerFonts()
        model = AppModel()
        updater = Updater(model: model)
        super.init()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isBusy else { return .terminateNow }
        NSApp.unhide(nil)
        NSApp.activate()
        let alert = NSAlert()
        if model.phase == .running {
            alert.messageText = String(localized: "The game is running")
            alert.informativeText = String(localized: "Hunter's Lantern stops the game before it quits. Progress since the game's last autosave may be lost.")
        } else {
            alert.messageText = String(localized: "The game is being prepared")
            alert.informativeText = String(localized: "Hunter's Lantern stops the launch before it quits.")
        }
        alert.addButton(withTitle: String(localized: "Stop the Game and Quit"))
        alert.addButton(withTitle: String(localized: "Keep Running"))
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

        model.stop()
        Task {
            // GameProcess sends SIGKILL after its grace period: the launch ends within seconds.
            for _ in 0..<300 where model.isBusy { try? await Task.sleep(nanoseconds: 50_000_000) }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
