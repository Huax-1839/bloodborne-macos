// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Why an import failed (D6). `errorDescription` is localised and meant for the user.
public enum ImportError: Error, LocalizedError, Equatable {
    case notEnoughSpace(needed: Int64, available: Int64)
    case destinationExists(URL)
    case notAGameFolder(URL)
    case copyFailed(path: String, reason: String)
    case extractionFailed(tool: String, details: String)
    case nothingExtracted(URL)
    case cannotStart(tool: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let needed, let available):
            return String(localized: "Not enough free disk space: \(Self.bytes(needed)) needed, \(Self.bytes(available)) available. Free some space or move the launcher's games folder to a bigger disk.", bundle: .module)
        case .destinationExists(let url):
            return String(localized: "The folder \(url.lastPathComponent) already exists.", bundle: .module)
        case .notAGameFolder(let url):
            return String(localized: "\(url.lastPathComponent) is not a PS4 game folder: it has no eboot.bin and sce_sys/param.sfo.", bundle: .module)
        case .copyFailed(let path, let reason):
            return String(localized: "Copying \(path) failed: \(reason)", bundle: .module)
        case .extractionFailed(let tool, let details):
            if details.isEmpty {
                return String(localized: "\(tool) could not extract the PKG.", bundle: .module)
            }
            return String(localized: "\(tool) could not extract the PKG: \(details)", bundle: .module)
        case .nothingExtracted(let url):
            return String(localized: "The extracted PKG in \(url.lastPathComponent) holds no PS4 game (no eboot.bin and sce_sys/param.sfo). Is it a game or update PKG?", bundle: .module)
        case .cannotStart(let tool, let reason):
            return String(localized: "\(tool) could not be started: \(reason)", bundle: .module)
        }
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

/// Finding the app folder (the one with eboot.bin and sce_sys/param.sfo) in what the user chose.
public enum GameFolder {
    /// The folder itself when it is a game folder, else its only child that is one (an extracted
    /// PKG is `CUSA03173/`), else nil.
    public static func locate(_ url: URL) -> URL? {
        if isGame(url) { return url }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let games = children.filter { isGame($0) }
        return games.count == 1 ? games[0] : nil
    }

    static func isGame(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: url.appendingPathComponent("eboot.bin").path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && fm.fileExists(atPath: url.appendingPathComponent("sce_sys/param.sfo").path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}

/// Builds the game folders of import paths (b) and (c) (D6).
public enum GameImporter {
    /// Kept free on the destination volume on top of what a merge needs.
    public static let spaceMargin: Int64 = 1 << 30

    /// Merges the update into a copy of the base: the update's files replace the base's, nothing
    /// is deleted (dumps are whole-file updates). `base` and `update` are app folders. `into`
    /// must not exist. On the destination's volume the copy is made of APFS clones, which costs
    /// no space; the destination's files never share writes with the base (an update file is
    /// unlinked before it is cloned). `progress` gets (entries done, entries total) a few times a
    /// second. Cancelling the task removes the partial destination.
    public static func merge(base: URL, update: URL, into destination: URL,
                             progress: @escaping @Sendable (Int, Int) -> Void) async throws {
        try await merge(base: base, update: update, into: destination, availableCapacity: nil, entryHook: nil, progress: progress)
    }

    /// The test hooks: `availableCapacity` replaces the volume's free space, `entryHook` runs
    /// before each entry (and may throw, like a cancellation would).
    static func merge(base: URL, update: URL, into destination: URL, availableCapacity: Int64?,
                      entryHook: (@Sendable (Int) throws -> Void)?,
                      progress: @escaping @Sendable (Int, Int) -> Void) async throws {
        let flag = CancelFlag()
        try await withTaskCancellationHandler {
            try await Task.detached {
                try MergeJob(base: base, update: update, destination: destination, flag: flag,
                             availableCapacity: availableCapacity, entryHook: entryHook, progress: progress).run()
            }.value
        } onCancel: {
            flag.cancel()
        }
    }

    /// The free space on the volume holding `url` (or its nearest existing parent).
    static func availableCapacity(at url: URL) -> Int64? {
        let values = try? existingAncestor(of: url).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func existingAncestor(of url: URL) -> URL {
        var current = url
        while !FileManager.default.fileExists(atPath: current.path), current.path != "/" {
            current = current.deletingLastPathComponent()
        }
        return current
    }

    /// The volume (st_dev) of `url`'s nearest existing parent, nil when it cannot be told.
    static func device(of url: URL) -> dev_t? {
        var info = stat()
        return stat(existingAncestor(of: url).path, &info) == 0 ? info.st_dev : nil
    }
}

/// Set from the task's cancellation handler, read by the blocking merge on its own thread.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// One merge, run synchronously on a detached thread.
private struct MergeJob {
    let base: URL, update: URL, destination: URL
    let flag: CancelFlag
    let availableCapacity: Int64?
    let entryHook: (@Sendable (Int) throws -> Void)?
    let progress: @Sendable (Int, Int) -> Void

    struct Entry {
        enum Kind { case directory, file, symlink }
        var path: String
        var kind: Kind
        var size: Int64
    }

    func run() throws {
        let fm = FileManager.default
        for folder in [base, update] where !GameFolder.isGame(folder) { throw ImportError.notAGameFolder(folder) }
        var existing = stat()
        if lstat(destination.path, &existing) == 0 { throw ImportError.destinationExists(destination) }
        let baseEntries = try scan(base), updateEntries = try scan(update)

        // The space check: the update is copied or cloned, the base is only cloned on the
        // destination's volume.
        let baseSize = baseEntries.reduce(Int64(0)) { $0 + $1.size }
        let updateSize = updateEntries.reduce(Int64(0)) { $0 + $1.size }
        let sameVolume = GameImporter.device(of: base).map { $0 == GameImporter.device(of: destination) } ?? false
        let needed = updateSize + (sameVolume ? 0 : baseSize) + GameImporter.spaceMargin
        if let available = availableCapacity ?? GameImporter.availableCapacity(at: destination), available < needed {
            throw ImportError.notEnoughSpace(needed: needed, available: available)
        }

        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        do {
            try copy(baseEntries, from: base, overwrite: false, offset: 0, total: baseEntries.count + updateEntries.count)
            try copy(updateEntries, from: update, overwrite: true, offset: baseEntries.count,
                     total: baseEntries.count + updateEntries.count)
            progress(baseEntries.count + updateEntries.count, baseEntries.count + updateEntries.count)
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    /// Every file, directory and symlink below `root` (parents before children).
    private func scan(_ root: URL) throws -> [Entry] {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { throw ImportError.notAGameFolder(root) }
        var entries: [Entry] = []
        while let path = enumerator.nextObject() as? String {
            if flag.isCancelled { throw CancellationError() }
            let attributes = enumerator.fileAttributes ?? [:]
            let type = attributes[.type] as? FileAttributeType
            let kind: Entry.Kind = type == .typeDirectory ? .directory : (type == .typeSymbolicLink ? .symlink : .file)
            entries.append(Entry(path: path, kind: kind, size: kind == .file ? (attributes[.size] as? NSNumber)?.int64Value ?? 0 : 0))
        }
        return entries
    }

    /// Clones, or copies where cloning is impossible (another volume), `entries` below `root`
    /// into the destination.
    private func copy(_ entries: [Entry], from root: URL, overwrite: Bool, offset: Int, total: Int) throws {
        let fm = FileManager.default
        var cloning = true
        var lastReport = Date.distantPast
        for (index, entry) in entries.enumerated() {
            if flag.isCancelled { throw CancellationError() }
            try entryHook?(offset + index)
            if Date().timeIntervalSince(lastReport) >= 0.1 {
                lastReport = Date()
                progress(offset + index, total)
            }
            let source = root.appendingPathComponent(entry.path).path
            let target = destination.appendingPathComponent(entry.path).path
            switch entry.kind {
            case .directory:
                var info = stat()
                if lstat(target, &info) == 0, (info.st_mode & S_IFMT) != S_IFDIR { unlink(target) }
                try fm.createDirectory(atPath: target, withIntermediateDirectories: true)
            case .file, .symlink:
                if overwrite {
                    var info = stat()
                    if lstat(target, &info) == 0 {
                        if (info.st_mode & S_IFMT) == S_IFDIR { try fm.removeItem(atPath: target) } else { unlink(target) }
                    }
                }
                if cloning {
                    if clonefile(source, target, UInt32(CLONE_NOFOLLOW)) == 0 { continue }
                    if errno != EXDEV && errno != ENOTSUP { throw failure(entry.path) }
                    cloning = false // another volume or a file system without clones: copy from now on
                }
                if copyfile(source, target, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_NOFOLLOW)) != 0 {
                    throw failure(entry.path)
                }
            }
        }
    }

    private func failure(_ path: String) -> ImportError {
        ImportError.copyFailed(path: path, reason: String(cString: strerror(errno)))
    }
}

extension GameImporter {
    /// Path (b) of D6: merges a base game folder and an update folder (or the folders holding
    /// them, GameFolder.locate) into dirs.gamesDir/<TITLE>-1.09 (a unique name) and runs the quick
    /// check. The caller registers the folder; a check problem is the caller's to show. A failed
    /// or cancelled merge or check removes the merged folder. `progress` gets the phase and its
    /// fraction.
    public static func importFolders(base: URL, update: URL, dirs: DataDirs, pipeline: Pipeline,
                                     progress: @escaping @Sendable (Phase, Double?) -> Void) async throws -> ImportedGame {
        guard let baseFolder = GameFolder.locate(base) else { throw ImportError.notAGameFolder(base) }
        guard let updateFolder = GameFolder.locate(update) else { throw ImportError.notAGameFolder(update) }
        let title = try await pipeline.quickCheck(game: baseFolder).title
        try FileManager.default.createDirectory(at: dirs.gamesDir, withIntermediateDirectories: true)
        let destination = uniqueFolder(in: dirs.gamesDir, name: folderName(title: title, version: nil,
                                                                          fallback: baseFolder.lastPathComponent))
        progress(.merging, 0)
        try await merge(base: baseFolder, update: updateFolder, into: destination) { done, total in
            progress(.merging, total > 0 ? Double(done) / Double(total) : nil)
        }
        do {
            progress(.checking, nil)
            let check = try await pipeline.quickCheck(game: destination)
            try Task.checkCancellation()
            return ImportedGame(folder: destination, check: check)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
