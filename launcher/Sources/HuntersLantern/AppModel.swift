// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import LanternCore
import SwiftUI

/// The app's state and actions: the views bind to this, the work is LanternCore's.
@MainActor
final class AppModel: ObservableObject {
    let dirs = DataDirs.standard()
    /// The runtime, or why it is missing (a broken bundle, a dev build without macos/out).
    let runtime: Result<Runtime, Error>

    @Published private(set) var library: GameLibrary
    @Published private(set) var profiles: ProfileStore
    @Published var state: LauncherState { didSet { try? state.save(dirs.stateFile) } }

    /// A launch in progress (nil when idle).
    @Published private(set) var phase: LaunchPhase?
    /// The last launch's end, for the outcome card.
    @Published var lastResult: LaunchResult?
    /// An error to show (import or launch).
    @Published var errorMessage: String?
    /// A notice to show (pre-launch settings the game changed, taken into the profile).
    @Published var notice: String?
    /// An import in progress: a description and a fraction (nil while unknown).
    @Published private(set) var importStatus: (text: String, fraction: Double?)?

    private var launcher: Launcher?

    init() {
        runtime = Result { try Runtime.locate() }
        library = GameLibrary(file: dirs.gamesFile)
        profiles = ProfileStore(dir: dirs.profilesDir)
        state = LauncherState.load(dirs.stateFile)
        try? dirs.create()
    }

    var activeGame: Game? { library.game(state.activeGame) ?? library.games.first }
    var activeProfile: Profile { profiles.profile(state.activeProfile) ?? .air }
    /// The game runs (or is being prepared): the launcher's settings are read-only (D7).
    var isBusy: Bool { phase != nil }

    // MARK: Games

    /// Import path (a): a ready 1.09 folder, registered where it is (D6).
    func importFolder(_ url: URL) async {
        guard case .success(let runtime) = runtime else { return showRuntimeError() }
        importStatus = (String(localized: "Checking the game…"), nil)
        defer { importStatus = nil }
        do {
            let check = try await PythonPipeline(runtime: runtime).quickCheck(game: url)
            guard check.ok else {
                errorMessage = GameCheckText.problem(check)
                return
            }
            let game = Game(path: url, check: check)
            try library.add(game)
            state.activeGame = game.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeGame(_ game: Game) {
        try? library.remove(game.id)
        if state.activeGame == game.id { state.activeGame = library.games.first?.id }
    }

    // MARK: Profiles

    func saveProfile(_ profile: Profile) {
        do {
            try profiles.save(profile)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func duplicateProfile(_ profile: Profile) {
        do {
            let copy = try profiles.duplicate(profile, name: String(localized: "\(profile.name) (copy)"))
            state.activeProfile = copy.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteProfile(_ profile: Profile) {
        try? profiles.delete(profile.id)
        if state.activeProfile == profile.id { state.activeProfile = Profile.air.id }
    }

    // MARK: Play

    func play() {
        guard !isBusy, let game = activeGame else { return }
        guard case .success(let runtime) = runtime else { return showRuntimeError() }
        let launcher = Launcher(dirs: dirs, runtime: runtime)
        self.launcher = launcher
        let profile = activeProfile
        let settings = state.settings
        lastResult = nil
        phase = .checking
        Task {
            do {
                let result = try await launcher.launch(game: game, profile: profile, settings: settings) { phase in
                    Task { @MainActor in self.update(phase) }
                }
                finish(result, profile: profile)
            } catch {
                phase = nil
                showApp()
                errorMessage = (error as? LaunchError)?.description ?? String(describing: error)
            }
            self.launcher = nil
        }
    }

    func stop() { launcher?.cancel() }

    private func update(_ newPhase: LaunchPhase) {
        guard phase != nil else { return }
        phase = newPhase
        // The launcher steps aside while the game runs and comes back afterwards (L1.6).
        if newPhase == .running { NSApp.hide(nil) }
    }

    private func finish(_ result: LaunchResult, profile: Profile) {
        phase = nil
        lastResult = result
        if !result.changedProfileKeys.isEmpty { takeIntoProfile(result.changedProfileKeys, profile: profile) }
        showApp()
    }

    /// Pre-launch keys changed in the game's menu go into the active profile (D7); a built-in
    /// preset gets a user copy.
    private func takeIntoProfile(_ keys: [String: String], profile: Profile) {
        var target = profile
        if target.builtin {
            target.id = UUID().uuidString.lowercased()
            target.name = String(localized: "\(profile.name) (changed in game)")
            target.builtin = false
            target.unmeasured = false
        }
        for (key, value) in keys {
            if let effect = Effect(rawValue: key) {
                target.effects[effect] = value == "1"
            } else if key == "model_lod" {
                target.modelLOD = Int(value) ?? target.modelLOD
            } else {
                target.iniValues[key] = value
            }
        }
        saveProfile(target)
        state.activeProfile = target.id
        notice = String(localized: "Settings you changed in the game were saved in the profile “\(target.name)”.")
    }

    private func showApp() {
        NSApp.unhide(nil)
        NSApp.activate()
    }

    private func showRuntimeError() {
        if case .failure(let error) = runtime { errorMessage = String(describing: error) }
    }
}
