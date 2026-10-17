// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The launcher's data folder (D1): ~/Library/Application Support/HuntersLantern, or
/// LANTERN_DATA_DIR (tests, a second data dir). No apostrophe or space in any path below, since
/// the pipeline scripts and the game see them.
public struct DataDirs: Sendable, Equatable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> DataDirs {
        if let dir = environment["LANTERN_DATA_DIR"], !dir.isEmpty {
            return DataDirs(root: URL(fileURLWithPath: dir, isDirectory: true))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return DataDirs(root: support.appendingPathComponent("HuntersLantern", isDirectory: true))
    }

    /// Registered games (GameLibrary).
    public var gamesFile: URL { root.appendingPathComponent("games.json") }
    /// The launcher's own settings (active game and profile, first-run state).
    public var stateFile: URL { root.appendingPathComponent("launcher.json") }
    /// One JSON file per user profile (built-in presets are not stored).
    public var profilesDir: URL { dir("profiles") }
    /// The game's --user root: savedata and, unless a profile has its own saves, the GPU cache.
    public var userDir: URL { dir("user") }
    /// Per-profile user roots for profiles with their own saves (D11).
    public func profileUserDir(_ profileID: String) -> URL { dir("profile-users").appendingPathComponent(profileID, isDirectory: true) }
    /// bbport.ini (BB_CONFIG), shared by every profile: the launcher writes a profile's keys before
    /// each launch (D7).
    public var iniFile: URL { root.appendingPathComponent("bbport.ini") }
    /// Prepared game images per game and eboot hash (D9).
    public var preparedDir: URL { dir("prepared") }
    public var logsDir: URL { dir("logs") }
    public var backupsDir: URL { dir("backups") }
    public var modsDir: URL { dir("mods") }
    /// mods.json (order/disabled, mods.py's format).
    public var modsConfig: URL { root.appendingPathComponent("mods.json") }
    /// External GoldHEN/shadPS4 patch XML files and patches.json (patches.py's format).
    public var patchesDir: URL { dir("patches") }
    public var patchesConfig: URL { root.appendingPathComponent("patches.json") }
    /// The game's working directory (its cwd-relative defaults land here, not in the bundle).
    public var runDir: URL { dir("run") }
    /// Merged and extracted games the launcher made (import paths b and c).
    public var gamesDir: URL { dir("games") }
    /// Lock file held while a game runs (one instance at a time, D8).
    public var lockFile: URL { root.appendingPathComponent("game.lock") }

    private func dir(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }

    /// The save roots: the shared one and the per-profile ones that exist.
    public var userRoots: [URL] {
        let profiles = (try? FileManager.default.contentsOfDirectory(at: dir("profile-users"), includingPropertiesForKeys: nil)) ?? []
        return [userDir] + profiles.filter { !$0.lastPathComponent.hasPrefix(".") }
    }

    /// Deletes the scratch folders an import, restore or migration that did not finish (a crash,
    /// a force-quit) left behind: games/.import-* (a whole extracted game), mods/.import-*, and
    /// .save-import-*, .savedata-restore and .savedata-migrate in every save root. Run at start,
    /// before anything new is begun. Returns what was deleted.
    @discardableResult
    public func removeLeftovers() -> [URL] {
        let fm = FileManager.default
        func entries(_ folder: URL, _ matches: (String) -> Bool) -> [URL] {
            ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { matches($0.lastPathComponent) }
        }
        var leftovers = entries(gamesDir) { $0.hasPrefix(".import-") } + entries(modsDir) { $0.hasPrefix(".import-") }
            + entries(root) { $0 == ".bbport.ini.migrate" }
        for userRoot in userRoots {
            leftovers += entries(userRoot) { $0.hasPrefix(".save-import-") || $0 == ".savedata-restore" || $0 == ".savedata-migrate" }
        }
        return leftovers.filter { (try? fm.removeItem(at: $0)) != nil }
    }

    /// The prepared image folder of a game (D9): per title and eboot hash.
    public func preparedFolder(for check: GameCheck) -> URL {
        preparedDir.appendingPathComponent("\(check.title)-\((check.imageSHA256 ?? "unknown").prefix(12))", isDirectory: true)
    }

    /// Creates the folders that must exist before a launch.
    public func create() throws {
        for url in [root, profilesDir, userDir, preparedDir, logsDir, backupsDir, modsDir, patchesDir, runDir] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
