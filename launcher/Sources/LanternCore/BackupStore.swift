// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Save backups (D11): before each launch the save root is cloned (APFS clones cost no space
/// until the game rewrites a file) into backups/auto/<time>, the last 10 kept; named snapshots
/// in backups/named/<time> with a label; restore while the game is not running.
public struct BackupStore: Sendable {
    public let dir: URL
    public static let keptAutomatic = 10

    public init(dir: URL) { self.dir = dir }

    public struct Backup: Identifiable, Equatable, Sendable {
        public var id: String { url.path }
        public var url: URL
        public var date: Date
        public var automatic: Bool
        /// The snapshot's name (named snapshots).
        public var label: String?
        /// Bytes of the backup's files (logical size: clones share blocks with the save).
        public var size: Int64
    }

    /// The savedata folder of a --user root.
    public static func savedata(_ userRoot: URL) -> URL { userRoot.appendingPathComponent("savedata", isDirectory: true) }

    /// Clones the save root's savedata into a new automatic backup and drops the oldest beyond
    /// ten. Nothing to back up (no savedata yet) is not an error: returns nil. When the save is
    /// unchanged since the newest automatic backup (same paths, sizes and mtimes), no backup is
    /// made and that one is returned: quick relaunches do not push the last good states out.
    @discardableResult
    public func backUpBeforeLaunch(userRoot: URL, now: Date = Date()) throws -> Backup? {
        try backUp(userRoot: userRoot, now: now, keeping: nil)
    }

    @discardableResult
    private func backUp(userRoot: URL, now: Date, keeping kept: URL?) throws -> Backup? {
        let source = Self.savedata(userRoot)
        guard FileManager.default.fileExists(atPath: source.path), try !Self.isEmpty(source) else { return nil }
        if let newest = list().first(where: \.automatic),
           Self.fingerprint(newest.url.appendingPathComponent("savedata", isDirectory: true)) == Self.fingerprint(source) {
            return newest
        }
        let backup = try copy(source, into: dir.appendingPathComponent("auto", isDirectory: true), now: now, label: nil)
        try prune(keeping: kept)
        return backup
    }

    /// A named snapshot of the save root.
    public func snapshot(userRoot: URL, label: String, now: Date = Date()) throws -> Backup {
        try copy(Self.savedata(userRoot), into: dir.appendingPathComponent("named", isDirectory: true), now: now, label: label)
    }

    /// Replaces the save root's savedata with the backup's (an automatic backup of the current
    /// state is taken first, so a restore can be undone).
    public func restore(_ backup: Backup, userRoot: URL) throws {
        let target = Self.savedata(userRoot)
        let fm = FileManager.default
        // The backup is staged first and kept by the rotation: the safety backup must not drop
        // the one being restored (it may be the oldest of ten).
        let staging = userRoot.appendingPathComponent(".savedata-restore", isDirectory: true)
        try? fm.removeItem(at: staging)
        try Self.cloneTree(backup.url.appendingPathComponent("savedata", isDirectory: true), to: staging)
        do {
            try backUp(userRoot: userRoot, now: Date(), keeping: backup.url)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: target)
        }
    }

    public func delete(_ backup: Backup) throws { try FileManager.default.removeItem(at: backup.url) }

    /// All backups, newest first.
    public func list() -> [Backup] {
        var backups: [Backup] = []
        for (folder, automatic) in [("auto", true), ("named", false)] {
            let parent = dir.appendingPathComponent(folder, isDirectory: true)
            let entries = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
            for url in entries where FileManager.default.fileExists(atPath: url.appendingPathComponent("savedata").path) {
                let label = try? String(contentsOf: url.appendingPathComponent("label.txt"), encoding: .utf8)
                let date = Self.date(fromName: url.lastPathComponent)
                    ?? ((try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast)
                backups.append(Backup(url: url, date: date, automatic: automatic, label: label, size: Self.size(of: url)))
            }
        }
        return backups.sorted { $0.date > $1.date }
    }

    /// Bytes used by all backups (logical: an upper bound, clones share blocks).
    public func totalSize() -> Int64 { list().reduce(0) { $0 + $1.size } }

    /// Drops the automatic backups beyond the newest ten; `kept` is never dropped (nor counted).
    private func prune(keeping kept: URL?) throws {
        let automatic = list().filter { $0.automatic && $0.url.resolvingSymlinksInPath() != kept?.resolvingSymlinksInPath() }
        for backup in automatic.dropFirst(Self.keptAutomatic) { try FileManager.default.removeItem(at: backup.url) }
    }

    private func copy(_ source: URL, into parent: URL, now: Date, label: String?) throws -> Backup {
        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        var name = Self.name(for: now)
        var counter = 2
        while fm.fileExists(atPath: parent.appendingPathComponent(name).path) {
            name = Self.name(for: now) + "-\(counter)"
            counter += 1
        }
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try Self.cloneTree(source, to: folder.appendingPathComponent("savedata", isDirectory: true))
            if let label { try label.write(to: folder.appendingPathComponent("label.txt"), atomically: true, encoding: .utf8) }
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        return Backup(url: folder, date: now, automatic: label == nil, label: label, size: Self.size(of: folder))
    }

    /// Copies a tree with APFS clones where possible (copyfile falls back to a copy elsewhere).
    static func cloneTree(_ source: URL, to destination: URL) throws {
        let flags = copyfile_flags_t(COPYFILE_CLONE | COPYFILE_RECURSIVE)
        guard copyfile(source.path, destination.path, nil, flags) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func isEmpty(_ folder: URL) throws -> Bool {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { return false }
        }
        return true
    }

    /// What a save tree looks like without reading it: every entry's relative path, size and
    /// modification time (clones keep the mtimes).
    static func fingerprint(_ folder: URL) -> [String: [Double]] {
        var result: [String: [Double]] = [:]
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys)
        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            let relative = path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
            result[relative] = values?.isDirectory == true ? [-1, 0]
                : [Double(values?.fileSize ?? 0), values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0]
        }
        return result
    }

    static func size(of folder: URL) -> Int64 {
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        while let url = enumerator?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    static func name(for date: Date) -> String { formatter.string(from: date) }
    static func date(fromName name: String) -> Date? { formatter.date(from: String(name.prefix(15))) }
}
