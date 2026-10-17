// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The Bloodborne save layout (spike L0.6, docs/LAUNCHER_PLAN.md D11): plain files, no encryption
/// and no checksums. A save root is <userRoot>/savedata/<user id>/<title id>/SPRJ0005 with the
/// ten character slots userdata0000-0009 (1,310,720 bytes each, zero-filled when empty) and
/// userdata0010 (262,144 bytes, global: the options and ten 402-byte summary records).
public enum SaveFormat {
    public static let directoryName = "SPRJ0005"
    public static let slotCount = 10
    public static let slotSize = 1_310_720
    public static let globalSize = 262_144
    /// Summary record n of userdata0010 starts at recordOffset + recordSize * n.
    public static let recordOffset = 0x108c
    public static let recordSize = 402
    /// The Bloodborne title ids the port knows (src/runtime_savedata.c): their saves are
    /// interchangeable, so an archive from one is placed under whichever the target uses.
    public static let titleIDs = ["CUSA00207", "CUSA00208", "CUSA00299", "CUSA00900", "CUSA01363",
                                  "CUSA03014", "CUSA03023", "CUSA03173", "CUSA03179"]

    static func recordRange(_ slot: Int) -> Range<Int> {
        let start = recordOffset + recordSize * slot
        return start..<(start + recordSize)
    }

    static var recordsEnd: Int { recordRange(slotCount - 1).upperBound }

    static func slotName(_ slot: Int) -> String { String(format: "userdata%04d", slot) }
    static func backupName(_ slot: Int) -> String { String(format: "backup%04d", slot) }
    static let globalName = "userdata0010"
}

public enum SaveError: Error, LocalizedError, Equatable {
    case notAnArchive(String)
    case unsupportedFormat(Int)
    case wrongKind(expected: SaveManifest.Kind, found: SaveManifest.Kind)
    case unknownTitle(String)
    case unsafeEntry(String)
    case badLayout(String)
    case noSave
    case emptySlot(Int)
    case badSlot(Int)
    case noGlobalFile
    case sameFolder
    case toolFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAnArchive(let reason):
            return String(localized: "This is not a Hunter's Lantern save file: \(reason)", table: "Saves", bundle: .module)
        case .unsupportedFormat(let version):
            return String(localized: "This save file has format \(version), which this version of the launcher does not know. Update the launcher.", table: "Saves", bundle: .module)
        case .wrongKind(let expected, let found):
            switch (expected, found) {
            case (.save, .character):
                return String(localized: "This file holds a single character, not a whole save. Use “Import character into slot…” instead.", table: "Saves", bundle: .module)
            default:
                return String(localized: "This file holds a whole save, not a single character. Use “Import save…” instead.", table: "Saves", bundle: .module)
            }
        case .unknownTitle(let title):
            return String(localized: "The file is for “\(title)”, which is not a Bloodborne version this launcher knows.", table: "Saves", bundle: .module)
        case .unsafeEntry(let name):
            return String(localized: "The file contains an unsafe entry (\(name)) and was not imported.", table: "Saves", bundle: .module)
        case .badLayout(let what):
            return String(localized: "The file is not laid out like a Hunter's Lantern save: \(what)", table: "Saves", bundle: .module)
        case .noSave:
            return String(localized: "There is no save to export yet. Start the game once first.", table: "Saves", bundle: .module)
        case .emptySlot(let slot):
            return String(localized: "Slot \(slot + 1) holds no character.", table: "Saves", bundle: .module)
        case .badSlot(let slot):
            return String(localized: "Slot \(slot + 1) does not exist: the game has ten slots.", table: "Saves", bundle: .module)
        case .noGlobalFile:
            return String(localized: "The current save has no global file (userdata0010) yet, so a character cannot be placed into it. Start the game once and let it save, then try again.", table: "Saves", bundle: .module)
        case .sameFolder:
            return String(localized: "The folder you chose is the launcher's own save folder.", table: "Saves", bundle: .module)
        case .toolFailed(let message):
            return String(localized: "A system tool failed: \(message)", table: "Saves", bundle: .module)
        }
    }
}

/// Where the saves of one --user root are.
public enum SaveRoot {
    /// Every <uid>/<title>/SPRJ0005 below <userRoot>/savedata, sorted by user and title.
    public static func find(userRoot: URL) -> [SaveLocation] {
        let fm = FileManager.default
        var found: [SaveLocation] = []
        for uid in subfolders(BackupStore.savedata(userRoot)) {
            for title in subfolders(uid) {
                var isDirectory: ObjCBool = false
                let dir = title.appendingPathComponent(SaveFormat.directoryName)
                if fm.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    found.append(SaveLocation(userRoot: userRoot, userID: uid.lastPathComponent, titleID: title.lastPathComponent))
                }
            }
        }
        return found.sorted { ($0.userID, $0.titleID) < ($1.userID, $1.titleID) }
    }

    private static func subfolders(_ folder: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }
}

/// One save: savedata/<user id>/<title id>/SPRJ0005 in a --user root.
public struct SaveLocation: Identifiable, Equatable, Sendable {
    public var userRoot: URL
    public var userID: String
    public var titleID: String

    public init(userRoot: URL, userID: String, titleID: String) {
        self.userRoot = userRoot
        self.userID = userID
        self.titleID = titleID
    }

    public var id: String { directory.path }
    /// savedata/<uid>
    public var userFolder: URL { BackupStore.savedata(userRoot).appendingPathComponent(userID, isDirectory: true) }
    /// savedata/<uid>/<title>: holds SPRJ0005 and SPRJ0005.sce_sys.
    public var titleFolder: URL { userFolder.appendingPathComponent(titleID, isDirectory: true) }
    /// savedata/<uid>/<title>.memory (SaveDataMemory), when the game made one.
    public var memoryFolder: URL { userFolder.appendingPathComponent(titleID + ".memory", isDirectory: true) }
    /// The folder with the game's files.
    public var directory: URL { titleFolder.appendingPathComponent(SaveFormat.directoryName, isDirectory: true) }
    public var globalFile: URL { directory.appendingPathComponent(SaveFormat.globalName) }
    public func slotFile(_ slot: Int) -> URL { directory.appendingPathComponent(SaveFormat.slotName(slot)) }

    /// A character slot as the global file summarises it.
    public struct Character: Codable, Identifiable, Equatable, Sendable {
        public var id: Int { slot }
        /// 0-9 (the game shows 1-10).
        public var slot: Int
        public var name: String
        public var level: Int
        /// Seconds played.
        public var playtime: Int
        public var echoes: Int

        public init(slot: Int, name: String, level: Int, playtime: Int, echoes: Int) {
            self.slot = slot
            self.name = name
            self.level = level
            self.playtime = playtime
            self.echoes = echoes
        }
    }

    /// The occupied slots: the summary record's flag is set and the slot file is not all zeros.
    public func characters() -> [Character] {
        guard let global = try? Data(contentsOf: globalFile), global.count >= SaveFormat.recordsEnd else { return [] }
        return (0..<SaveFormat.slotCount).compactMap { slot in
            guard let character = Self.parseRecord(global, slot: slot), slotHasData(slot) else { return nil }
            return character
        }
    }

    /// The 402-byte record of a slot as stored in the global file.
    public func record(slot: Int) -> Data? {
        guard (0..<SaveFormat.slotCount).contains(slot),
              let global = try? Data(contentsOf: globalFile), global.count >= SaveFormat.recordsEnd else { return nil }
        return global.subdata(in: SaveFormat.recordRange(slot))
    }

    func slotHasData(_ slot: Int) -> Bool {
        guard let data = try? Data(contentsOf: slotFile(slot), options: .mappedIfSafe) else { return false }
        return data.contains { $0 != 0 }
    }

    /// +0 u32 occupied flag, +10 name (UTF-16LE, up to 17 units with terminator), +44 level,
    /// +48 playtime in seconds, +52 echoes; nil for an empty record.
    static func parseRecord(_ global: Data, slot: Int) -> Character? {
        let range = SaveFormat.recordRange(slot)
        guard global.count >= range.upperBound else { return nil }
        let record = global.subdata(in: range)
        guard u32(record, 0) != 0 else { return nil }
        var units: [UInt16] = []
        for index in 0..<17 {
            let unit = UInt16(record[10 + index * 2]) | UInt16(record[10 + index * 2 + 1]) << 8
            if unit == 0 { break }
            units.append(unit)
        }
        return Character(slot: slot, name: String(decoding: units, as: UTF16.self), level: Int(u32(record, 44)),
                         playtime: Int(u32(record, 48)), echoes: Int(u32(record, 52)))
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[data.startIndex + offset + $1]) << (8 * UInt32($1)) }
    }
}

/// The manifest.json of a .lanternsave: a whole save or one character.
public struct SaveManifest: Codable, Equatable, Sendable {
    public static let formatVersion = 1

    public enum Kind: String, Codable, Sendable { case save, character }

    public var format: Int
    public var kind: Kind
    /// The Bloodborne title id the files came from.
    public var title: String
    public var created: Date
    public var appVersion: String
    /// kind save: the occupied slots.
    public var characters: [SaveLocation.Character]?
    /// kind character: the exported slot and what its record says.
    public var slot: Int?
    public var name: String?
    public var level: Int?
    public var playtime: Int?
    public var echoes: Int?

    /// kind character: the exported character.
    public var character: SaveLocation.Character? {
        guard kind == .character, let slot, let name, let level, let playtime, let echoes else { return nil }
        return SaveLocation.Character(slot: slot, name: name, level: level, playtime: playtime, echoes: echoes)
    }
}

/// What an import did.
public struct SaveImport: Sendable {
    /// The automatic backup of the previous state (nil when there was no save yet).
    public var backup: BackupStore.Backup?
    public var location: SaveLocation
    public var manifest: SaveManifest
}

/// .lanternsave archives: a ZIP (made with ditto) of one folder holding manifest.json and the
/// files. Kind save: <title>/ (SPRJ0005 and SPRJ0005.sce_sys) and <title>.memory/ when present.
/// Kind character: userdata (the slot file) and record.bin (its 402-byte summary record).
/// Imports back up the save root first and never write outside it.
public enum SaveArchive {
    public static let fileExtension = "lanternsave"
    static let saveFolderName = "LanternSave"
    static let characterFolderName = "LanternCharacter"

    // MARK: Export

    /// Exports the whole save (all ten slots, options, icon, memory).
    @discardableResult
    public static func exportSave(_ location: SaveLocation, to destination: URL, appVersion: String,
                                  now: Date = Date()) throws -> SaveManifest {
        let fm = FileManager.default
        guard fm.fileExists(atPath: location.directory.path) else { throw SaveError.noSave }
        let manifest = SaveManifest(format: SaveManifest.formatVersion, kind: .save, title: location.titleID, created: now,
                                    appVersion: appVersion, characters: location.characters())
        return try makeArchive(folderName: saveFolderName, manifest: manifest, to: destination) { folder in
            try BackupStore.cloneTree(location.titleFolder, to: folder.appendingPathComponent(location.titleID, isDirectory: true))
            if fm.fileExists(atPath: location.memoryFolder.path) {
                try BackupStore.cloneTree(location.memoryFolder, to: folder.appendingPathComponent(location.titleID + ".memory", isDirectory: true))
            }
        }
    }

    /// Exports one character: its slot file and summary record. EXPERIMENTAL (D11): not yet
    /// confirmed to load in the game.
    @discardableResult
    public static func exportCharacter(slot: Int, of location: SaveLocation, to destination: URL, appVersion: String,
                                       now: Date = Date()) throws -> SaveManifest {
        guard (0..<SaveFormat.slotCount).contains(slot) else { throw SaveError.badSlot(slot) }
        guard let character = location.characters().first(where: { $0.slot == slot }),
              let record = location.record(slot: slot) else { throw SaveError.emptySlot(slot) }
        let manifest = SaveManifest(format: SaveManifest.formatVersion, kind: .character, title: location.titleID, created: now,
                                    appVersion: appVersion, slot: slot, name: character.name, level: character.level,
                                    playtime: character.playtime, echoes: character.echoes)
        return try makeArchive(folderName: characterFolderName, manifest: manifest, to: destination) { folder in
            try FileManager.default.copyItem(at: location.slotFile(slot), to: folder.appendingPathComponent("userdata"))
            try record.write(to: folder.appendingPathComponent("record.bin"))
        }
    }

    /// Builds <temp>/<folderName>/{manifest.json, files…} and zips it next to the destination
    /// (then renames: a failed export leaves no half file).
    private static func makeArchive(folderName: String, manifest: SaveManifest, to destination: URL,
                                    fill: (URL) throws -> Void) throws -> SaveManifest {
        let fm = FileManager.default
        // ISO 8601 keeps whole seconds: the returned manifest equals the stored one.
        var manifest = manifest
        manifest.created = Date(timeIntervalSince1970: manifest.created.timeIntervalSince1970.rounded(.down))
        let work = fm.temporaryDirectory.appendingPathComponent("lantern-export-\(UUID().uuidString)", isDirectory: true)
        let folder = work.appendingPathComponent(folderName, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        try fill(folder)
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
        let partial = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).partial")
        try? fm.removeItem(at: partial)
        do {
            try Tool.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, partial.path])
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: partial)
            } else {
                try fm.moveItem(at: partial, to: destination)
            }
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        return manifest
    }

    // MARK: Read

    /// The manifest of an archive without extracting the rest (to describe what an import would do).
    public static func readManifest(_ archive: URL) throws -> SaveManifest {
        let entries = try listEntries(archive)
        guard let entry = manifestEntry(in: entries) else { throw SaveError.notAnArchive(missingManifestText) }
        return try decodeManifest(try Tool.run("/usr/bin/unzip", ["-p", archive.path, entry]))
    }

    private static var missingManifestText: String {
        String(localized: "manifest.json is missing", table: "Saves", bundle: .module)
    }

    /// The names in the ZIP; refuses absolute paths and ".." (an archive must not write outside
    /// the folder it is extracted into).
    static func listEntries(_ archive: URL) throws -> [String] {
        let output: Data
        do {
            output = try Tool.run("/usr/bin/unzip", ["-Z1", archive.path])
        } catch SaveError.toolFailed(let message) {
            throw SaveError.notAnArchive(message)
        }
        let names = String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init)
        for name in names {
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            if name.hasPrefix("/") || parts.contains("..") || name.contains("\\") { throw SaveError.unsafeEntry(name) }
        }
        return names
    }

    /// "<folder>/manifest.json" (one folder deep; macOS's __MACOSX companions are ignored).
    private static func manifestEntry(in entries: [String]) -> String? {
        entries.first { entry in
            let parts = entry.split(separator: "/")
            return parts.count == 2 && parts[1] == "manifest.json" && parts[0] != "__MACOSX"
        }
    }

    private static func decodeManifest(_ data: Data) throws -> SaveManifest {
        let manifest: SaveManifest
        do {
            manifest = try decoder.decode(SaveManifest.self, from: data)
        } catch {
            throw SaveError.notAnArchive(String(localized: "manifest.json is unreadable", table: "Saves", bundle: .module))
        }
        guard manifest.format == SaveManifest.formatVersion else { throw SaveError.unsupportedFormat(manifest.format) }
        guard SaveFormat.titleIDs.contains(manifest.title) else { throw SaveError.unknownTitle(manifest.title) }
        return manifest
    }

    /// Extracts into `staging` (a new folder inside the target's user root) and returns the
    /// archive's folder and manifest, after the layout checks.
    private static func extract(_ archive: URL, expecting kind: SaveManifest.Kind,
                                into staging: URL) throws -> (folder: URL, manifest: SaveManifest) {
        let fm = FileManager.default
        let entries = try listEntries(archive)
        guard let manifestPath = manifestEntry(in: entries) else { throw SaveError.notAnArchive(missingManifestText) }
        let manifest = try decodeManifest(try Tool.run("/usr/bin/unzip", ["-p", archive.path, manifestPath]))
        guard manifest.kind == kind else { throw SaveError.wrongKind(expected: kind, found: manifest.kind) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try Tool.run("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path])
        } catch SaveError.toolFailed(let message) {
            throw SaveError.notAnArchive(message)
        }
        // No links: a symlink in the archive could point outside the save root.
        let enumerator = fm.enumerator(at: staging, includingPropertiesForKeys: [.isSymbolicLinkKey])
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                throw SaveError.unsafeEntry(url.lastPathComponent)
            }
        }
        let folder = staging.appendingPathComponent(String(manifestPath.split(separator: "/")[0]), isDirectory: true)
        return (folder, manifest)
    }

    // MARK: Import

    /// Replaces the save of the user root with the archive's. The current state is backed up
    /// first (an automatic backup); it goes under the user and title folder the target already
    /// uses, else user "1" and the archive's title. Memory data is replaced when the archive has
    /// some. Nothing outside <userRoot>/savedata (and a staging folder in the user root) is written.
    @discardableResult
    public static func importSave(_ archive: URL, userRoot: URL, backups: BackupStore,
                                  preferredTitle: String? = nil) throws -> SaveImport {
        let fm = FileManager.default
        try fm.createDirectory(at: userRoot, withIntermediateDirectories: true)
        let staging = userRoot.appendingPathComponent(".save-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        let (folder, manifest) = try extract(archive, expecting: .save, into: staging)

        let title = folder.appendingPathComponent(manifest.title, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: title.appendingPathComponent(SaveFormat.directoryName).path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SaveError.badLayout("\(manifest.title)/\(SaveFormat.directoryName)")
        }
        let memory = folder.appendingPathComponent(manifest.title + ".memory", isDirectory: true)
        let hasMemory = fm.fileExists(atPath: memory.path)

        let existing = SaveRoot.find(userRoot: userRoot)
        let target = existing.first { $0.titleID == preferredTitle } ?? existing.first
            ?? SaveLocation(userRoot: userRoot, userID: "1", titleID: manifest.title)

        let backup = try backups.backUpBeforeLaunch(userRoot: userRoot)
        try fm.createDirectory(at: target.userFolder, withIntermediateDirectories: true)
        try place(title, at: target.titleFolder)
        if hasMemory { try place(memory, at: target.memoryFolder) }
        return SaveImport(backup: backup, location: target, manifest: manifest)
    }

    /// Imports a character into slot `slot` of the save: backs up first, copies the slot file to
    /// userdata000m, writes the record at 0x108c + 402·m of userdata0010 and removes backup000m;
    /// everything else stays. Refuses when the save has no userdata0010. EXPERIMENTAL (D11).
    @discardableResult
    public static func importCharacter(_ archive: URL, intoSlot slot: Int, of location: SaveLocation,
                                       backups: BackupStore) throws -> SaveImport {
        let fm = FileManager.default
        guard (0..<SaveFormat.slotCount).contains(slot) else { throw SaveError.badSlot(slot) }
        guard let global = try? Data(contentsOf: location.globalFile), global.count >= SaveFormat.recordsEnd else {
            throw SaveError.noGlobalFile
        }
        let staging = location.userRoot.appendingPathComponent(".save-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        let (folder, manifest) = try extract(archive, expecting: .character, into: staging)

        guard let slotData = try? Data(contentsOf: folder.appendingPathComponent("userdata")),
              slotData.count == SaveFormat.slotSize, slotData.contains(where: { $0 != 0 }) else {
            throw SaveError.badLayout("userdata")
        }
        guard let record = try? Data(contentsOf: folder.appendingPathComponent("record.bin")),
              record.count == SaveFormat.recordSize else {
            throw SaveError.badLayout("record.bin")
        }

        let backup = try backups.backUpBeforeLaunch(userRoot: location.userRoot)
        try slotData.write(to: location.slotFile(slot), options: .atomic)
        var updated = global
        updated.replaceSubrange(SaveFormat.recordRange(slot), with: record)
        try updated.write(to: location.globalFile, options: .atomic)
        let stale = location.directory.appendingPathComponent(SaveFormat.backupName(slot))
        if fm.fileExists(atPath: stale.path) { try fm.removeItem(at: stale) }
        return SaveImport(backup: backup, location: location, manifest: manifest)
    }

    /// Moves a staged folder to `destination`, replacing what is there in one swap.
    private static func place(_ staged: URL, at destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: destination)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Runs a system tool and returns its standard output.
enum Tool {
    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        let errorFile = FileManager.default.temporaryDirectory.appendingPathComponent("lantern-tool-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: errorFile.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errorFile) }
        let errorHandle = try FileHandle(forWritingTo: errorFile)
        process.standardError = errorHandle
        do {
            try process.run()
        } catch {
            try? errorHandle.close()
            throw SaveError.toolFailed(error.localizedDescription)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try? errorHandle.close()
        guard process.terminationStatus == 0 else {
            let text = (try? String(contentsOf: errorFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw SaveError.toolFailed(text.isEmpty ? "\((executable as NSString).lastPathComponent) (\(process.terminationStatus))" : text)
        }
        return data
    }
}
