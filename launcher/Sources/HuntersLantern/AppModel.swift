// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import LanternCore
import SwiftUI

/// The app's state and actions: the views bind to this, the work is LanternCore's.
@MainActor
final class AppModel: ObservableObject {
    let dirs = DataDirs.standard()
    /// This Mac's chip and GPU (read once): the profile suggestion.
    let hardware = Hardware.current()
    /// The runtime, or why it is missing (a broken bundle, a dev build without macos/out).
    let runtime: Result<Runtime, Error>

    @Published private(set) var library: GameLibrary
    @Published private(set) var profiles: ProfileStore
    @Published var state: LauncherState { didSet { try? state.save(dirs.stateFile) } }

    /// The page shown (the sidebar's selection).
    @Published var page: Page = .home
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

    /// Import path (b): base game and update folders merged with APFS clones (D6). Filled in
    /// with GameImporter (L2.2).
    func importBaseAndUpdate(base: URL, update: URL) async {
        errorMessage = "Not implemented yet (L2.2)"
    }

    /// Import path (c): base and update PKG through the external PKG tool, then (b) (L2.3).
    func importPKGs(base: URL, update: URL) async {
        errorMessage = "Not implemented yet (L2.3)"
    }

    /// The PKG tool found on this Mac (nil: none; the Game page explains how to get one).
    var pkgToolDescription: String? { nil }

    /// Lets the user pick the PKG tool's executable (L2.3).
    func choosePKGTool(_ url: URL) {}

    /// The thorough check (every .dcx) in the background; the result goes into the game's entry
    /// (L2.4). `thoroughProgress` while it runs.
    func runThoroughCheck(_ game: Game) async {}
    @Published private(set) var thoroughProgress: Double?

    func cancelImport() {}

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

    func renameProfile(_ profile: Profile, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !profile.builtin, !name.isEmpty else { return }
        var renamed = profile
        renamed.name = name
        saveProfile(renamed)
    }

    func exportProfile(_ profile: Profile, to url: URL) {
        do {
            try profiles.export(profile, to: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Imports a profile file as a new user profile and makes it the active one.
    func importProfile(from url: URL) {
        do {
            state.activeProfile = try profiles.importProfile(from: url).id
        } catch {
            errorMessage = error.localizedDescription
        }
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
