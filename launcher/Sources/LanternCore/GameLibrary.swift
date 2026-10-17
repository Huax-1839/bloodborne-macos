// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// A registered game folder (D6): where it is and what the last check found.
public struct Game: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var path: URL
    public var check: GameCheck
    /// The folder was made by the launcher (merged or extracted, in DataDirs.gamesDir): removing
    /// the game may delete it.
    public var managed: Bool = false
    public var added: Date
    /// The thorough check (every .dcx), when it ran: the folder's size and newest mtime then, and
    /// the broken files found (D6, cached like upstream).
    public var thorough: ThoroughCheck?

    public struct ThoroughCheck: Codable, Equatable, Sendable {
        public var fileCount: Int
        public var totalSize: Int64
        public var newestModification: Date
        public var broken: [String]
        public var date: Date
        public init(fileCount: Int, totalSize: Int64, newestModification: Date, broken: [String], date: Date) {
            self.fileCount = fileCount
            self.totalSize = totalSize
            self.newestModification = newestModification
            self.broken = broken
            self.date = date
        }
    }

    public init(id: String = UUID().uuidString, path: URL, check: GameCheck, managed: Bool = false, added: Date = Date()) {
        self.id = id
        self.path = path
        self.check = check
        self.managed = managed
        self.added = added
    }

    /// The folder and its check are required; `managed`, `added` and the thorough check keep
    /// their defaults when another version did not write them.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), path: try c.decode(URL.self, forKey: .path),
                  check: try c.decode(GameCheck.self, forKey: .check), managed: c.decode(.managed, or: false),
                  added: c.decode(.added, or: Date.distantPast))
        thorough = c.decodeLenient(.thorough)
    }

    /// sce_sys/pic1.png (background) and icon0.png (cover): the user's own artwork, read at run
    /// time, never copied (D17).
    public var backgroundImage: URL { path.appendingPathComponent("sce_sys/pic1.png") }
    public var coverImage: URL { path.appendingPathComponent("sce_sys/icon0.png") }
    public var eboot: URL { path.appendingPathComponent("eboot.bin") }
}

/// games.json: the registered games.
public struct GameLibrary: Sendable {
    public let file: URL
    public private(set) var games: [Game] = []
    /// games.json could not be read as a whole: where it was kept aside (the readable entries
    /// were taken from it).
    public private(set) var setAside: URL?

    public init(file: URL) {
        self.file = file
        var setAside: [URL] = []
        if let games = DataFile.load([Game].self, from: file, setAside: &setAside) {
            self.games = games
        } else if let moved = setAside.first {
            self.setAside = moved
            let entries = (try? Data(contentsOf: moved)).flatMap { try? JSONDecoder.lantern.decode([Lossy<Game>].self, from: $0) }
            games = entries?.compactMap(\.value) ?? []
        }
    }

    public func game(_ id: String?) -> Game? { games.first { $0.id == id } }

    /// Adds the game, or replaces the entry with the same folder.
    public mutating func add(_ game: Game) throws {
        games.removeAll { $0.path.standardizedFileURL == game.path.standardizedFileURL || $0.id == game.id }
        games.append(game)
        try save()
    }

    public mutating func update(_ game: Game) throws {
        guard let index = games.firstIndex(where: { $0.id == game.id }) else { return try add(game) }
        games[index] = game
        try save()
    }

    public mutating func remove(_ id: String) throws {
        games.removeAll { $0.id == id }
        try save()
    }

    /// The game's prepared image folder (DataDirs.preparedFolder), unless another registered game
    /// uses the same one (same title and eboot hash): what removing the game may delete.
    public func preparedFolderOnlyFor(_ game: Game, dirs: DataDirs) -> URL? {
        let folder = dirs.preparedFolder(for: game.check)
        let shared = games.contains { $0.id != game.id && dirs.preparedFolder(for: $0.check) == folder }
        return shared ? nil : folder
    }

    func save() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.lantern.encode(games).write(to: file, options: .atomic)
    }
}

extension JSONEncoder {
    /// Readable JSON with stable key order (files people may look at or diff).
    public static var lantern: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    public static var lantern: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
