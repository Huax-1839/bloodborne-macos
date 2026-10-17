// SPDX-License-Identifier: GPL-2.0-or-later
import CryptoKit
import Foundation

/// Where a launch is (for the home page's status).
public enum LaunchPhase: Equatable, Sendable {
    case checking
    case backingUp
    case preparing(String)
    case running
    case restarting
}

/// The end of a launch: the game's outcome, its log, and the pre-launch keys the game's menu
/// changed (taken into the profile by the caller, D7).
public struct LaunchResult: Sendable {
    public var outcome: GameOutcome
    public var log: URL?
    /// Pre-launch ini keys (effects, model_lod) whose value the game changed: key → new value.
    public var changedProfileKeys: [String: String]
    /// The game's crash or failure lines from the end of the log, for the outcome card.
    public var logTail: String
}

public struct LaunchError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public var check: GameCheck?
    public init(_ description: String, check: GameCheck? = nil) {
        self.description = description
        self.check = check
    }
}

/// One launch from the launcher (D5, D7, D8, D9): quick check, save backup, the profile's keys
/// into bbport.ini, the prepared image (cached per eboot), the game, restarts, and the in-game
/// changes back.
public final class Launcher: @unchecked Sendable {
    public let dirs: DataDirs
    public let runtime: Runtime
    public let pipeline: Pipeline
    /// Called before each launch (not before a restart): the automatic save backup (D11).
    public var backup: (@Sendable (_ userRoot: URL) throws -> Void)?
    private let lock = NSLock()
    private var current: GameProcess?
    private var cancelled = false

    public init(dirs: DataDirs, runtime: Runtime, pipeline: Pipeline? = nil) {
        self.dirs = dirs
        self.runtime = runtime
        self.pipeline = pipeline ?? PythonPipeline(runtime: runtime)
    }

    /// Ends the launch (the launcher's Stop button): the game when it runs, else the launch stops
    /// before the next step. Cancelling the launching task also ends the pipeline step that runs.
    public func cancel() {
        let process = lock.withLock {
            cancelled = true
            return current
        }
        process?.cancel()
    }

    /// A launch stopped by `cancel()` or by cancelling the task ends with `.cancelled`, not an
    /// error (a pipeline step killed by the cancellation fails).
    public func launch(game: Game, profile: Profile, settings: LauncherSettings,
                       onPhase: @escaping @Sendable (LaunchPhase) -> Void) async throws -> LaunchResult {
        lock.withLock { cancelled = false }
        do {
            return try await run(game: game, profile: profile, settings: settings, onPhase: onPhase)
        } catch where isCancelled {
            return Self.cancelledResult
        }
    }

    private static let cancelledResult = LaunchResult(outcome: .cancelled, log: nil, changedProfileKeys: [:], logTail: "")

    private func run(game: Game, profile: Profile, settings: LauncherSettings,
                     onPhase: @escaping @Sendable (LaunchPhase) -> Void) async throws -> LaunchResult {
        try dirs.create()
        // One game at a time, taken before anything is written (the ini, the prepared folder, the
        // backup) and held across restarts: a second launcher on the same data folder stops here (R6).
        let gameLock = try GameLock.acquire(dirs.lockFile)
        defer { gameLock.release() }
        onPhase(.checking)
        let check = try await pipeline.quickCheck(game: game.path)
        guard check.ok else { throw LaunchError(GameCheckText.problem(check), check: check) }

        let userRoot = profile.ownSaves ? dirs.profileUserDir(profile.id) : dirs.userDir
        try FileManager.default.createDirectory(at: userRoot, withIntermediateDirectories: true)
        if let backup {
            onPhase(.backingUp)
            try backup(userRoot)
        }

        // The profile's keys into bbport.ini (D7); what the game changes of them comes back.
        var ini = try IniFile.load(dirs.iniFile)
        let written = profile.iniKeys
        ini.set(written)
        try ini.write(to: dirs.iniFile)

        // The profile's patch choices (L3.5): external ones as patches.json, built-in ones as BB_PATCHES.
        let patchExtras = PatchStore.load(runtime: runtime, dirs: dirs).extraNames(for: profile)
        try PatchStore.patchesJSON(for: profile).write(to: dirs.patchesConfig, options: .atomic)

        let prepared = dirs.preparedFolder(for: check)
        let modGame = try await modOverlay(game: game, profile: profile, onPhase: onPhase)
        defer { if let modGame { try? FileManager.default.removeItem(at: modGame) } }
        var result: LaunchResult
        repeat {
            let scaled = profile.renderResolution == nil ? try await pipeline.scaledSizes(settings: dirs.iniFile) : nil
            let inputs = LaunchInputs(profile: profile, gameDir: game.path, preparedDir: prepared, dirs: dirs,
                                      runtime: runtime, settings: settings, scaled: scaled, modGame: modGame,
                                      patchExtras: patchExtras,
                                      appleSilicon: MacHost.appleSilicon, macOSMajor: MacHost.macOSMajor)
            let spec = LaunchSpec.make(inputs)
            try await prepare(spec, prepared: prepared, game: game, onPhase: onPhase)
            if isCancelled { return Self.cancelledResult }

            let process = GameProcess(spec: spec, logsDir: dirs.logsDir, lock: gameLock)
            let log = try process.start()
            // A Stop between start() and here found no process to end: it is done now.
            let stopNow = lock.withLock {
                current = process
                return cancelled || Task.isCancelled
            }
            if stopNow { process.cancel() }
            onPhase(.running)
            let outcome = await process.wait()
            lock.withLock { current = nil }
            result = LaunchResult(outcome: outcome, log: log, changedProfileKeys: [:], logTail: Self.tail(of: log))
            if outcome == .restartRequested { onPhase(.restarting) }
        } while result.outcome == .restartRequested && !isCancelled

        // Keys the game's menu changed ("after a restart" settings): into the profile.
        let after = try IniFile.load(dirs.iniFile)
        for (key, value) in written where after[key] != nil && after[key] != value {
            result.changedProfileKeys[key] = after[key]
        }
        return result
    }

    /// The profile's mod set as an overlay (D10): mods.json with the set's order and every other
    /// mod disabled. Overlays a killed run left behind are removed first.
    func modOverlay(game: Game, profile: Profile, onPhase: @escaping @Sendable (LaunchPhase) -> Void) async throws -> URL? {
        let fm = FileManager.default
        for stale in (try? fm.contentsOfDirectory(at: dirs.runDir, includingPropertiesForKeys: nil)) ?? []
        where stale.lastPathComponent.hasPrefix("mod-game-") {
            try? fm.removeItem(at: stale)
        }
        guard let mods = profile.mods, !mods.isEmpty else { return nil }
        onPhase(.preparing("mods.py"))
        // Every folder not in the set is disabled, hidden ones too (a half-finished import must not
        // be enabled by mods.py's "new folders are on" rule).
        let installed = (try? fm.contentsOfDirectory(atPath: dirs.modsDir.path)) ?? []
        let config = dirs.runDir.appendingPathComponent("mods.json")
        let object: [String: [String]] = ["order": mods, "disabled": installed.filter { !mods.contains($0) }]
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: config, options: .atomic)
        let overlay = try await pipeline.buildModOverlay(game: game.path, out: dirs.runDir, modsDir: dirs.modsDir, config: config)
        return overlay.lastPathComponent.hasPrefix("mod-game-") ? overlay : nil
    }

    private var isCancelled: Bool { Task.isCancelled || lock.withLock { cancelled } }

    /// Runs the launch steps. prepare/link/content_profile depend only on the eboot and the
    /// scripts (D9): skipped when the prepared folder's stamp matches; patches.py runs each time.
    func prepare(_ spec: LaunchSpec, prepared: URL, game: Game, onPhase: @escaping @Sendable (LaunchPhase) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: prepared, withIntermediateDirectories: true)
        let stampFile = prepared.appendingPathComponent("prepared.stamp")
        let stamp = try preparedStamp(game: game, spec: spec)
        let cached = (try? String(contentsOf: stampFile, encoding: .utf8)) == stamp
        let logURL = dirs.logsDir.appendingPathComponent("prepare.log")
        fm.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        var environment = ProcessInfo.processInfo.environment
        environment.merge(spec.environment) { $1 }
        for step in spec.steps {
            if isCancelled { throw CancellationError() }
            let imageStep = step.script != "patches.py"
            if imageStep && cached { continue }
            if imageStep { try? fm.removeItem(at: stampFile) }
            onPhase(.preparing(step.script))
            try log.write(contentsOf: Data("$ \(step.script) \(step.arguments.joined(separator: " "))\n".utf8))
            try await pipeline.run(step, environment: environment, log: log)
        }
        if !cached { try stamp.write(to: stampFile, atomically: true, encoding: .utf8) }
    }

    /// The eboot (size, mtime) and the image steps' arguments and scripts.
    func preparedStamp(game: Game, spec: LaunchSpec) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: game.eboot.path)
        var hasher = SHA256()
        hasher.update(data: Data("\(attributes[.size] ?? 0) \((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)".utf8))
        for step in spec.steps where step.script != "patches.py" {
            hasher.update(data: Data((step.script + " " + step.arguments.joined(separator: " ") + "\n").utf8))
            if let script = try? Data(contentsOf: runtime.scripts.appendingPathComponent(step.script)) {
                hasher.update(data: script)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The last lines of a log (the crash card).
    static func tail(of log: URL, lines: Int = 40) -> String {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 16384 ? size - 16384 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}

/// The host the launcher runs on.
public enum MacHost {
    public static var appleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    public static var macOSMajor: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }
}
