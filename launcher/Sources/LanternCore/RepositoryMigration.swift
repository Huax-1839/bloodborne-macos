// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Takes over what a bbport checkout holds (L5.3): macos/user/savedata, macos/bbport.ini and the
/// GPU shader cache macos/user/cache, cloned (APFS) into the launcher's data folder. The caller
/// asks first; the existing save root is backed up before anything is replaced.
public struct RepositoryMigration: Equatable, Sendable {
    /// The folder the user chose.
    public var folder: URL
    /// The --user root of the source: <checkout>/macos/user, or the folder itself when it holds
    /// savedata/ directly.
    public var userRoot: URL
    /// The source's bbport.ini, when there is one.
    public var ini: URL?

    public var savedata: URL { BackupStore.savedata(userRoot) }
    public var cache: URL { userRoot.appendingPathComponent("cache", isDirectory: true) }

    /// Whether the source holds any save file.
    public var hasSaves: Bool {
        FileManager.default.fileExists(atPath: savedata.path) && ((try? !BackupStore.isEmpty(savedata)) ?? false)
    }

    public var hasCache: Bool {
        FileManager.default.fileExists(atPath: cache.path) && ((try? !BackupStore.isEmpty(cache)) ?? false)
    }

    /// The characters the source's saves hold.
    public func characters() -> [SaveLocation.Character] {
        SaveRoot.find(userRoot: userRoot).flatMap { $0.characters() }
    }

    /// Bytes of the shader cache (logical).
    public func cacheSize() -> Int64 { hasCache ? BackupStore.size(of: cache) : 0 }

    /// Looks for a checkout (macos/user/savedata, macos/bbport.ini) or a folder that directly
    /// holds savedata/ (a --user root); nil when there is nothing to take over.
    public static func detect(folder: URL) -> RepositoryMigration? {
        let fm = FileManager.default
        func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
        let checkoutUser = folder.appendingPathComponent("macos/user", isDirectory: true)
        var found: RepositoryMigration?
        if exists(BackupStore.savedata(checkoutUser)) || exists(folder.appendingPathComponent("macos/bbport.ini")) {
            let ini = folder.appendingPathComponent("macos/bbport.ini")
            found = RepositoryMigration(folder: folder, userRoot: checkoutUser, ini: exists(ini) ? ini : nil)
        } else if exists(BackupStore.savedata(folder)) {
            // A --user root. Its bbport.ini lies next to it (macos/bbport.ini) or inside.
            let candidates = [folder.appendingPathComponent("bbport.ini"),
                              folder.deletingLastPathComponent().appendingPathComponent("bbport.ini")]
            found = RepositoryMigration(folder: folder, userRoot: folder, ini: candidates.first(where: exists))
        }
        guard let found, found.hasSaves || found.ini != nil else { return nil }
        return found
    }

    public struct Result: Sendable {
        /// The automatic backup of the previous save root (nil when it had no save).
        public var backup: BackupStore.Backup?
        public var savesTaken: Bool
        public var iniTaken: Bool
        /// Cache folders cloned (those the data folder did not have yet).
        public var cacheFoldersTaken: Int
    }

    /// Replaces the save root's savedata and bbport.ini (the previous bbport.ini is kept as
    /// bbport.ini.before-migration) and, with `includeCache`, adds cache folders the data folder
    /// lacks. `userRoot` is the active save root; the GPU cache always goes to dirs.userDir/cache
    /// (BB_GPU_USER_DIR).
    @discardableResult
    public func migrate(into dirs: DataDirs, userRoot target: URL, backups: BackupStore, includeCache: Bool) throws -> Result {
        let fm = FileManager.default
        func real(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
        if real(userRoot) == real(target) || real(userRoot) == real(dirs.userDir) { throw SaveError.sameFolder }

        var result = Result(backup: nil, savesTaken: false, iniTaken: false, cacheFoldersTaken: 0)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        result.backup = try backups.backUpBeforeLaunch(userRoot: target)

        if hasSaves {
            let staging = target.appendingPathComponent(".savedata-migrate", isDirectory: true)
            try? fm.removeItem(at: staging)
            defer { try? fm.removeItem(at: staging) }
            try BackupStore.cloneTree(savedata, to: staging)
            let destination = BackupStore.savedata(target)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: destination)
            }
            result.savesTaken = true
        }

        if let ini {
            try fm.createDirectory(at: dirs.iniFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staging = dirs.iniFile.deletingLastPathComponent().appendingPathComponent(".bbport.ini.migrate")
            try? fm.removeItem(at: staging)
            defer { try? fm.removeItem(at: staging) }
            try BackupStore.cloneTree(ini, to: staging)
            if fm.fileExists(atPath: dirs.iniFile.path) {
                let previous = dirs.iniFile.deletingLastPathComponent().appendingPathComponent("bbport.ini.before-migration")
                try? fm.removeItem(at: previous)
                try BackupStore.cloneTree(dirs.iniFile, to: previous)
                _ = try fm.replaceItemAt(dirs.iniFile, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: dirs.iniFile)
            }
            result.iniTaken = true
        }

        if includeCache, hasCache {
            let destination = dirs.userDir.appendingPathComponent("cache", isDirectory: true)
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            for entry in try fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
            where !fm.fileExists(atPath: destination.appendingPathComponent(entry.lastPathComponent).path) {
                try BackupStore.cloneTree(entry, to: destination.appendingPathComponent(entry.lastPathComponent))
                result.cacheFoldersTaken += 1
            }
        }
        return result
    }
}
