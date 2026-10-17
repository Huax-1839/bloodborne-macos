// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Combine
import Sparkle
import SwiftUI

/// Sparkle updates (D13): only in a release build, whose Info.plist has SUFeedURL and
/// SUPublicEDKey (launcher/build.sh --bundle); a dev build has no updater. Sparkle refuses to
/// update a translocated or read-only app: the launcher offers to move itself to /Applications
/// first. While a game runs, no scheduled check and no relaunch (R7).
@MainActor
final class Updater: ObservableObject {
    private let controller: SPUStandardUpdaterController?
    private let delegate: UpdaterDelegate
    @Published private(set) var canCheck = false

    init(model: AppModel) {
        delegate = UpdaterDelegate(model: model)
        let info = Bundle.main.infoDictionary ?? [:]
        guard info["SUFeedURL"] != nil, info["SUPublicEDKey"] != nil, !Self.isTranslocated else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
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

/// Keeps Sparkle out of a running game (R7): a scheduled check is refused (the next one comes
/// later), and "Install and Relaunch" waits until the launch has ended. An update installed on
/// quit needs no rule: quitting stops the game first (AppDelegate).
@MainActor
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    private weak var model: AppModel?
    private var pendingRelaunch: (() -> Void)?
    private var idle: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        super.init()
        idle = model.$phase.sink { [weak self] phase in
            guard phase == nil, let relaunch = self?.pendingRelaunch else { return }
            self?.pendingRelaunch = nil
            // After the didSet: the launch's end is fully handled first.
            DispatchQueue.main.async { relaunch() }
        }
    }

    private var gameRuns: Bool { model?.isBusy ?? false }

    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        let refuse = MainActor.assumeIsolated { updateCheck == .updatesInBackground && gameRuns }
        if refuse {
            throw NSError(domain: "HuntersLantern", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No update check while the game runs."])
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                             untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated {
            guard gameRuns else { return false }
            pendingRelaunch = installHandler
            return true
        }
    }
}

extension Updater {
    /// Copies the app to /Applications (replacing an older copy there), opens the copy and quits.
    static func moveToApplications() throws {
        let fm = FileManager.default
        let source = Bundle.main.bundleURL
        let target = URL(fileURLWithPath: "/Applications").appendingPathComponent(source.lastPathComponent)
        if fm.fileExists(atPath: target.path) { try fm.trashItem(at: target, resultingItemURL: nil) }
        try fm.copyItem(at: source, to: target)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: target, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
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
