// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// A fast stat walk over a folder tree (fts, no Foundation objects per file).
enum FileWalk {
    /// Calls `visit` with the path and stat of every regular file below `root`.
    static func files(under root: URL, _ visit: (String, stat) -> Void) {
        var roots: [UnsafeMutablePointer<CChar>?] = [strdup(root.path), nil]
        defer { free(roots[0]) }
        guard let stream = fts_open(&roots, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return }
        defer { fts_close(stream) }
        while let entry = fts_read(stream) {
            guard entry.pointee.fts_info == UInt16(FTS_F), let info = entry.pointee.fts_statp else { continue }
            visit(String(cString: entry.pointee.fts_path), info.pointee)
        }
    }

    /// Bytes in the regular files below `root`.
    static func size(of root: URL) -> Int64 {
        var total: Int64 = 0
        files(under: root) { _, info in total += Int64(info.st_size) }
        return total
    }
}

extension Game.ThoroughCheck {
    /// What the thorough check looked at: the shader archives. A stat walk, no hashing: when a
    /// file is added, removed, resized or touched, the result no longer applies (cached like
    /// upstream's, D6).
    public struct Fingerprint: Equatable, Sendable {
        public var fileCount: Int
        public var totalSize: Int64
        /// Whole seconds: games.json stores ISO 8601 dates without fractions.
        public var newestModification: Date
    }

    /// The folder the thorough check walks (game_check.py).
    static let checkedFolder = "dvdroot_ps4"

    public static func fingerprint(of gameFolder: URL) -> Fingerprint {
        var count = 0
        var size: Int64 = 0
        var newest: Int = 0
        FileWalk.files(under: gameFolder.appendingPathComponent(checkedFolder, isDirectory: true)) { path, info in
            guard path.hasSuffix(".dcx") else { return }
            count += 1
            size += Int64(info.st_size)
            newest = max(newest, Int(info.st_mtimespec.tv_sec))
        }
        return Fingerprint(fileCount: count, totalSize: size, newestModification: Date(timeIntervalSince1970: TimeInterval(newest)))
    }

    /// The cached result still applies to the folder as it is now.
    public func isCurrent(for folder: URL) -> Bool {
        let now = Self.fingerprint(of: folder)
        return now.fileCount == fileCount && now.totalSize == totalSize
            && Int(now.newestModification.timeIntervalSince1970) == Int(newestModification.timeIntervalSince1970)
    }

    /// Runs the thorough check (minutes) and returns the game with `thorough` filled. The
    /// fingerprint is taken before the run, so files changed during it invalidate the result.
    public static func runThorough(game: Game, pipeline: Pipeline,
                                   progress: @escaping @Sendable (Int, Int) -> Void) async throws -> Game {
        let fingerprint = fingerprint(of: game.path)
        let broken = try await pipeline.thoroughCheck(game: game.path, progress: progress)
        var updated = game
        updated.thorough = Game.ThoroughCheck(fileCount: fingerprint.fileCount, totalSize: fingerprint.totalSize,
                                              newestModification: fingerprint.newestModification,
                                              broken: broken, date: Date())
        return updated
    }
}
