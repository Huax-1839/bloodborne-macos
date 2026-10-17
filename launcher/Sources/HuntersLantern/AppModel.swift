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

    /// Import path (b): base game and update folders merged with APFS clones into the data
    /// folder's games/ (D6).
    func importBaseAndUpdate(base: URL, update: URL) async {
        await runImport { runtime in
            let pipeline = PythonPipeline(runtime: runtime)
            guard let baseFolder = GameFolder.locate(base) else { throw ImportError.notAGameFolder(base) }
            guard let updateFolder = GameFolder.locate(update) else { throw ImportError.notAGameFolder(update) }
            let title = try await pipeline.quickCheck(game: baseFolder).title
            try FileManager.default.createDirectory(at: self.dirs.gamesDir, withIntermediateDirectories: true)
            let destination = Self.uniqueFolder(self.dirs.gamesDir.appendingPathComponent("\(title)-1.09"))
            self.importStatus = (String(localized: "Merging the base game and the update…"), 0)
            try await GameImporter.merge(base: baseFolder, update: updateFolder, into: destination) { done, total in
                Task { @MainActor in self.importStatus = (String(localized: "Merging the base game and the update…"), total > 0 ? Double(done) / Double(total) : nil) }
            }
            self.importStatus = (String(localized: "Checking the game…"), nil)
            return (destination, try await pipeline.quickCheck(game: destination))
        }
    }

    /// Import path (c): base and update PKG through the external PKG tool, then (b).
    func importPKGs(base: URL, update: URL) async {
        guard let tool = pkgTool else {
            errorMessage = String(localized: "No PKG tool found. Install ps4-pkg-tools and choose its program on the Game page.")
            return
        }
        await runImport { runtime in
            let imported = try await GameImporter.importPKGs(base: base, update: update, tool: tool, dirs: self.dirs,
                                                             pipeline: PythonPipeline(runtime: runtime)) { phase, fraction in
                Task { @MainActor in self.importStatus = (Self.text(for: phase), fraction) }
            }
            return (imported.folder, imported.check)
        }
    }

    /// The PKG tool: the one the user chose, else one found on this Mac.
    var pkgTool: PkgTool? {
        if let path = state.pkgToolPath, case .success(let tool) = PkgTool.validate(URL(fileURLWithPath: path)) { return tool }
        return PkgTool.detect()
    }

    /// The PKG tool found on this Mac (nil: none; the Game page explains how to get one).
    var pkgToolDescription: String? {
        pkgTool.map { "\($0.kind.displayName) – \($0.executable.path)" }
    }

    /// Lets the user pick the PKG tool's executable.
    func choosePKGTool(_ url: URL) {
        switch PkgTool.validate(url) {
        case .success(let tool): state.pkgToolPath = tool.executable.path
        case .failure(let error): errorMessage = error.localizedDescription
        }
    }

    /// The thorough check (every .dcx) in the background; the result goes into the game's entry.
    func runThoroughCheck(_ game: Game) async {
        guard case .success(let runtime) = runtime, thoroughProgress == nil else { return }
        thoroughProgress = 0
        defer { thoroughProgress = nil }
        do {
            let updated = try await Game.ThoroughCheck.runThorough(game: game, pipeline: PythonPipeline(runtime: runtime)) { done, total in
                Task { @MainActor in if self.thoroughProgress != nil { self.thoroughProgress = total > 0 ? Double(done) / Double(total) : 0 } }
            }
            try library.update(updated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    @Published private(set) var thoroughProgress: Double?

    private var importTask: Task<Void, Never>?

    func cancelImport() { importTask?.cancel() }

    /// Runs an import (b or c) as a cancellable task and registers the folder it made.
    private func runImport(_ work: @escaping @MainActor (Runtime) async throws -> (URL, GameCheck)) async {
        guard case .success(let runtime) = runtime else { return showRuntimeError() }
        guard importTask == nil else { return }
        importStatus = (String(localized: "Preparing the import…"), nil)
        let task = Task { @MainActor in
            do {
                let (folder, check) = try await work(runtime)
                let game = Game(path: folder, check: check, managed: true)
                try library.add(game)
                state.activeGame = game.id
                if !check.ok { errorMessage = GameCheckText.problem(check) }
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        importTask = task
        await task.value
        importTask = nil
        importStatus = nil
    }

    private static func text(for phase: GameImporter.Phase) -> String {
        switch phase {
        case .extractingBase: String(localized: "Extracting the base game PKG…")
        case .extractingUpdate: String(localized: "Extracting the update PKG…")
        case .merging: String(localized: "Merging the base game and the update…")
        case .checking: String(localized: "Checking the game…")
        }
    }

    private static func uniqueFolder(_ url: URL) -> URL {
        var candidate = url
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent)-\(counter)")
            counter += 1
        }
        return candidate
    }

    /// Removes the game from the list; a folder the launcher made (merged or extracted) goes to
    /// the Trash, a folder the user registered stays where it is.
    func removeGame(_ game: Game) {
        if game.managed { try? FileManager.default.trashItem(at: game.path, resultingItemURL: nil) }
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
        // The save backup before each launch (D11), one history per save root.
        let backups = dirs.backupsDir
        launcher.backup = { userRoot in
            try BackupStore(dir: backups.appendingPathComponent(userRoot.lastPathComponent)).backUpBeforeLaunch(userRoot: userRoot)
        }
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
