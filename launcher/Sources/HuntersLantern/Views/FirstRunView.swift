// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import LanternCore
import SwiftUI

/// The first-run assistant (L6.2, D16): Rosetta 2, the macOS version, the app's location
/// (updates need it in /Applications), free space, and the way to the game import.
struct FirstRunView: View {
    @EnvironmentObject private var model: AppModel
    @State private var check = SystemCheck.current(dataDir: DataDirs.standard().root)
    @State private var moveError: String?

    var body: some View {
        PrintDialog(title: Text("Welcome to Hunter's Lantern"), width: 560) {
            PrintNote(Text("A few checks before the first hunt."))
            PrintRows {
                row(ok: check.rosetta, title: "Rosetta 2",
                    detail: check.rosetta ? "Installed: the game runs under Rosetta 2."
                        : "Missing: the game is an Intel program and needs Rosetta 2. macOS offers to install it when you continue, or run “softwareupdate --install-rosetta” in Terminal.") {
                    if !check.rosetta {
                        Button { installRosetta() } label: { Text("Install Rosetta…") }
                    }
                }
                row(ok: true, title: "macOS \(check.macOSMajor)",
                    detail: check.metalAvailable ? "The game runs on Metal, the faster renderer."
                        : "The game runs on Vulkan (MoltenVK). macOS 15 or newer adds the faster Metal renderer.")
                row(ok: !Updater.needsMove, title: "Location",
                    detail: Updater.needsMove ? "The app runs from the disk image or a temporary location. Move it to the Applications folder so it can update itself."
                        : "The app can update itself here.") {
                    if Updater.needsMove {
                        Button { moveToApplications() } label: { Text("Move to Applications") }
                    }
                }
                row(ok: check.enoughSpaceForImport, title: "Free space",
                    detail: check.enoughSpaceForImport ? "Enough space to import the game (about 30 GB when merging or extracting)."
                        : "Less than 35 GB free: importing from PKG files or merging onto another disk needs about 30 GB. A ready game folder needs no extra space.")
            }
            if let moveError {
                PrintNote(Text(moveError), color: Print.danger)
            }
            PrintNote(Text("Next: add your own copy of the game on the Game page. The app contains no game files."))
        } actions: {
            Button { finish(goToGame: false) } label: { Text("Later") }
            Button { finish(goToGame: true) } label: { Text("Add the game") }
                .keyboardShortcut(.defaultAction)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            check = SystemCheck.current(dataDir: model.dirs.root)
        }
    }

    /// One check: its name, "Ready" in the ok colour when it is fine (otherwise the explanation is
    /// in the danger colour), an optional action, and what it means below.
    private func row(ok: Bool, title: LocalizedStringKey, detail: LocalizedStringKey,
                     @ViewBuilder action: () -> some View = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(title)
                Spacer(minLength: 8)
                action()
                    .buttonStyle(TextActionStyle())
                if ok {
                    Text("Ready")
                        .font(Print.text(14))
                        .foregroundStyle(Print.ok)
                }
            }
            PrintNote(Text(detail), color: ok ? Print.textSecondary : Print.danger)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Print.line).frame(height: 1) }
    }

    private func finish(goToGame: Bool) {
        model.state.firstRunDone = true
        if goToGame { model.page = .game }
    }

    /// Opening an Intel program makes macOS offer the Rosetta install: the bundled game app.
    private func installRosetta() {
        let gameApp = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Hunter's Lantern Game.app")
        if FileManager.default.fileExists(atPath: gameApp.path) {
            NSWorkspace.shared.openApplication(at: gameApp, configuration: NSWorkspace.OpenConfiguration())
        } else if let url = URL(string: "https://support.apple.com/102527") {
            NSWorkspace.shared.open(url)
        }
    }

    private func moveToApplications() {
        do {
            try Updater.moveToApplications()
        } catch {
            moveError = error.localizedDescription
        }
    }
}
