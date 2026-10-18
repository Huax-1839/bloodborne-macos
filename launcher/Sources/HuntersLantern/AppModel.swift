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
        var setAside: [URL] = []
        state = LauncherState.load(dirs.stateFile, setAside: &setAside)
        setAside += profiles.setAside + (library.setAside.map { [$0] } ?? [])
        try? dirs.create()
        dirs.removeLeftovers()
        if !setAside.isEmpty {
            let names = setAside.map(\.lastPathComponent).joined(separator: "\n")
            errorMessage = String(localized: "These launcher files could not be read and were kept aside in the data folder (readable games were taken from them):\n\(names)")
        }
    }

    var activeGame: Game? { library.game(state.activeGame) ?? library.games.first }
    var activeProfile: Profile { profiles.profile(state.activeProfile) ?? .air }
    /// The game runs (or is being prepared): the launcher's settings are read-only (D7).
    var isBusy: Bool { phase != nil }

    // MARK: Games

    /// Import path (a): a ready 1.09 folder, registered where it is (D6). The folder holding the
    /// app folder (CUSA03173/) is taken as well, as in path (b).
    func importFolder(_ chosen: URL) async {
        guard case .success(let runtime) = runtime else { return showRuntimeError() }
        let url = GameFolder.locate(chosen) ?? chosen
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
        await runImport { runtime, progress in
            let imported = try await GameImporter.importFolders(base: base, update: update, dirs: self.dirs,
                                                                pipeline: PythonPipeline(runtime: runtime), progress: progress)
            return (imported.folder, imported.check)
        }
    }

    /// Import path (c): base and update PKG through the external PKG tool, then (b).
    func importPKGs(base: URL, update: URL) async {
        guard let tool = pkgTool else {
            errorMessage = String(localized: "No PKG tool found. Install ps4-pkg-tools and choose its program on the Game page.")
            return
        }
        await runImport { runtime, progress in
            let imported = try await GameImporter.importPKGs(base: base, update: update, tool: tool, dirs: self.dirs,
                                                             pipeline: PythonPipeline(runtime: runtime)) { progress($0, $1) }
            return (imported.folder, imported.check)
        }
    }

    /// The PKG tool: the one the user chose, else one found on this Mac (nil: none, or not looked
    /// for yet; the PKG sheet refreshes it when it opens). Finding it runs the chosen program
    /// (validate), so it is a stored value, never computed by a view.
    @Published private(set) var pkgTool: PkgTool?
    /// The PKG tool is being looked for.
    @Published private(set) var pkgToolSearching = false

    /// Looks for the PKG tool again, off the main actor.
    func refreshPKGTool() async {
        let path = state.pkgToolPath
        pkgToolSearching = true
        defer { pkgToolSearching = false }
        pkgTool = await Task.detached {
            if let path, case .success(let tool) = await PkgTool.validate(URL(fileURLWithPath: path)) { return tool }
            return PkgTool.detect()
        }.value
    }

    /// Lets the user pick the PKG tool's executable.
    func choosePKGTool(_ url: URL) async {
        pkgToolSearching = true
        defer { pkgToolSearching = false }
        switch await Task.detached(operation: { await PkgTool.validate(url) }).value {
        case .success(let tool):
            state.pkgToolPath = tool.executable.path
            pkgTool = tool
        case .failure(let error):
            errorMessage = error.localizedDescription
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
            try library.update(updated) // not again when the game was removed meanwhile
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    @Published private(set) var thoroughProgress: Double?

    private var importTask: Task<Void, Never>?
    /// The running import (b or c) and the number of its last progress update shown: updates
    /// arrive as separate main-actor tasks, in no fixed order, and may outlive the import.
    private var importGeneration = 0
    private var importProgressShown = 0

    func cancelImport() { importTask?.cancel() }

    /// Runs an import (b or c) as a cancellable task and registers the folder it made. `work`
    /// gets the progress callback for the importer.
    private func runImport(_ work: @escaping @MainActor (Runtime, @escaping @Sendable (GameImporter.Phase, Double?) -> Void) async throws -> (URL, GameCheck)) async {
        guard case .success(let runtime) = runtime else { return showRuntimeError() }
        guard importTask == nil else { return }
        importGeneration += 1
        importProgressShown = 0
        let generation = importGeneration
        let sequence = ProgressSequence()
        let progress: @Sendable (GameImporter.Phase, Double?) -> Void = { phase, fraction in
            let number = sequence.next()
            Task { @MainActor in
                // Only the newest update of the running import: never after it ended, never an
                // older phase over a newer one.
                guard self.importTask != nil, self.importGeneration == generation, number > self.importProgressShown else { return }
                self.importProgressShown = number
                self.importStatus = (Self.text(for: phase), fraction)
            }
        }
        importStatus = (String(localized: "Preparing the import…"), nil)
        let task = Task { @MainActor in
            do {
                let (folder, check) = try await work(runtime, progress)
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

    /// Removes the game from the list; a folder the launcher made (merged or extracted) goes to
    /// the Trash, a folder the user registered stays where it is. Its prepared image (made from
    /// the game, rebuilt on the next launch) is deleted when no other game uses it.
    func removeGame(_ game: Game) {
        if game.managed { try? FileManager.default.trashItem(at: game.path, resultingItemURL: nil) }
        if let prepared = library.preparedFolderOnlyFor(game, dirs: dirs) { try? FileManager.default.removeItem(at: prepared) }
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

    /// The profile's own saves and their backups (D11), when there are any on disk.
    func ownSaveFolders(_ profile: Profile) -> [URL] {
        [dirs.profileUserDir(profile.id), dirs.backupsDir.appendingPathComponent(profile.id, isDirectory: true)]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Deletes a user profile; its own saves and their backups stay in the data folder, or go to
    /// the Trash with `trashingSaves` (R17).
    func deleteProfile(_ profile: Profile, trashingSaves: Bool = false) {
        do {
            if trashingSaves {
                for folder in ownSaveFolders(profile) { try FileManager.default.trashItem(at: folder, resultingItemURL: nil) }
            }
            try profiles.delete(profile.id)
        } catch {
            errorMessage = error.localizedDescription
        }
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

    /// A profile file read for import that sets expert variables: the Profiles page asks before
    /// it is saved (R4).
    @Published var pendingImport: ProfileImport?

    /// Imports a profile file as a new user profile and makes it the active one; one with expert
    /// variables waits in `pendingImport` for the user's answer.
    func importProfile(from url: URL) {
        do {
            let read = try profiles.readImport(from: url)
            if read.profile.environment.isEmpty && read.dropped.isEmpty {
                finishImport(read.profile)
            } else {
                pendingImport = read
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Saves the pending import, with or without its expert variables.
    func confirmImport(keepingVariables: Bool) {
        guard var profile = pendingImport?.profile else { return }
        pendingImport = nil
        if !keepingVariables { profile.environment = [:] }
        finishImport(profile)
    }

    private func finishImport(_ profile: Profile) {
        do {
            try profiles.save(profile)
            state.activeProfile = profile.id
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
        launchTask = Task {
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
            launchTask = nil
        }
    }

    /// The launch in progress: Stop cancels it, which ends the pipeline step that runs (prepare
    /// can take minutes) as well as the game.
    private var launchTask: Task<Void, Never>?

    func stop() {
        launcher?.cancel()
        launchTask?.cancel()
    }

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

/// Numbers progress callbacks in the order the importer made them (they come from its threads).
private final class ProgressSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}
