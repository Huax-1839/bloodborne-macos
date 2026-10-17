// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Sparkle
import SwiftUI

/// Sparkle updates (D13): only in a release build, whose Info.plist has SUFeedURL and
/// SUPublicEDKey (launcher/build.sh --bundle); a dev build has no updater. Sparkle refuses to
/// update a translocated or read-only app: the launcher offers to move itself to /Applications
/// first.
@MainActor
final class Updater: ObservableObject {
    private let controller: SPUStandardUpdaterController?
    @Published private(set) var canCheck = false

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        guard info["SUFeedURL"] != nil, info["SUPublicEDKey"] != nil, !Self.isTranslocated else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }

    var available: Bool { controller != nil }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    /// App Translocation: a downloaded app opened where it lies runs from a random read-only path.
    static var isTranslocated: Bool { Bundle.main.bundlePath.contains("/AppTranslocation/") }

    /// The app runs from a translocated path or from a folder it cannot write (the DMG): updates
    /// need it in /Applications (or another writable folder).
    static var needsMove: Bool {
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return false }
        return isTranslocated || !FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path)
    }
}

/// The app menu's "Check for Updates…".
struct UpdateCommands: Commands {
    @ObservedObject var updater: Updater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if updater.available {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
            }
        }
    }
}
