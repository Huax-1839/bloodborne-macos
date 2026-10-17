// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Why a mod could not be added or used (D10). `errorDescription` is localised and meant for the user.
public enum ModError: Error, LocalizedError, Equatable {
    case notAMod(name: String, found: [String])
    case symlink(String)
    case systemFile(String)
    case notRegularFile(String)
    case notAFolder(String)
    case unsupportedArchive(String)
    case notAnArchive(String)
    case unpackFailed(name: String, details: String)
    case invalidName(String)
    case nameTaken(String)
    case copyFailed(String)
    case trashFailed(name: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .notAMod(let name, let found):
            let list = found.isEmpty
                ? String(localized: "nothing (it is empty)", table: "Mods", bundle: .module)
                : found.joined(separator: ", ")
            return String(localized: "“\(name)” does not hold a mod. A mod has the game's files in a folder called dvdroot_ps4, or the game's own folders (chr, parts, msg, …) directly. Found: \(list).", table: "Mods", bundle: .module)
        case .symlink(let path):
            return String(localized: "Mods must not contain links (symlinks): \(path)", table: "Mods", bundle: .module)
        case .systemFile(let path):
            return String(localized: "Replacing eboot.bin or the system files is not supported: \(path)", table: "Mods", bundle: .module)
        case .notRegularFile(let path):
            return String(localized: "This is not a regular file: \(path)", table: "Mods", bundle: .module)
        case .notAFolder(let name):
            return String(localized: "“\(name)” is not a folder.", table: "Mods", bundle: .module)
        case .unsupportedArchive(let ext):
            return String(localized: "The launcher can only unpack ZIP files, not .\(ext) archives. Unpack it with an app like The Unarchiver, then add the unpacked folder.", table: "Mods", bundle: .module)
        case .notAnArchive(let name):
            return String(localized: "“\(name)” is neither a folder nor a ZIP file.", table: "Mods", bundle: .module)
        case .unpackFailed(let name, let details):
            return String(localized: "“\(name)” could not be unpacked: \(details)", table: "Mods", bundle: .module)
        case .invalidName(let name):
            return String(localized: "“\(name)” is not a usable name. Use a name without “/” or “:” that does not start with a dot.", table: "Mods", bundle: .module)
        case .nameTaken(let name):
            return String(localized: "There is already a mod called “\(name)”.", table: "Mods", bundle: .module)
        case .copyFailed(let reason):
            return String(localized: "The mod could not be copied: \(reason)", table: "Mods", bundle: .module)
        case .trashFailed(let name, let reason):
            return String(localized: "“\(name)” could not be moved to the Trash: \(reason)", table: "Mods", bundle: .module)
        }
    }
}

/// One folder of the mods directory. `files` are the game paths under dvdroot_ps4 the mod
/// replaces or adds, as mods.py's mod_files yields them ("dvdroot_ps4/chr/c2240.dcx", spelled as
/// in the mod; match them through `ModLibrary.key`). A folder that is not a usable mod has a
/// `problem` and no files.
public struct Mod: Identifiable, Equatable, Sendable {
    public var name: String
    public var url: URL
    /// Where the files sit in the folder ("dvdroot_ps4", "Archive v1.2/dvdroot_ps4", "game folders: chr").
    public var layout: String
    public var files: [String]
    public var problem: String?

    public var id: String { name }
    public var isValid: Bool { problem == nil }
}

/// Two or more enabled mods providing the same game file.
public struct ModConflict: Identifiable, Equatable, Sendable {
    /// The game path, spelled as the winner has it.
    public var path: String
    /// The mods in load order.
    public var mods: [String]
    /// The mod whose file is used: the last one.
    public var winner: String
    public var id: String { ModLibrary.key(path) }
}

/// The mod library (D10): the folders in DataDirs.modsDir, with mods.py's layout rules (content_root,
/// mod_files), import of folders and ZIPs, rename, delete and the per-file conflict view.
public struct ModLibrary: Sendable {
    public let dir: URL

    public init(dir: URL) { self.dir = dir }

    // MARK: Rules of scripts/mods.py

    /// Top-level folders of the game's dvdroot_ps4 (mods.py GAME_FOLDERS).
    static let gameFolders: Set<String> = [
        "action", "adhoc", "chr", "event", "facegen", "font", "map", "menu", "movie", "msg", "mtd",
        "obj", "other", "param", "paramdef", "parts", "remo", "script", "sfx", "shader", "sound",
    ]
    /// The retail releases' folder names (mods.py SERIALS).
    static let serials = ["CUSA03173", "CUSA00900", "CUSA00207", "CUSA00208", "CUSA00299", "CUSA01363",
                          "CUSA03179", "CUSA03014", "CUSA03023"]
    /// Files next to a wrapper folder that do not make it more than a wrapper.
    static let metadataExtensions: Set<String> = [".txt", ".md", ".jpg", ".png", ".ini"]
    /// Top-level names whose replacement mods.py refuses.
    static let systemNames: Set<String> = ["eboot.bin", "sce_module", "sce_sys"]

    /// The key two spellings of a game path are matched by (mods.py casefolds).
    public static func key(_ path: String) -> String { path.lowercased() }

    /// Where a mod's files are: `root` holds `dvdroot_ps4` (prefix empty) or is itself its content
    /// (prefix "dvdroot_ps4"); `via` are the folders between the mod folder and `root`.
    struct ContentRoot {
        var root: URL
        var prefix: String
        var via: [String]
        var bare: [String]
    }

    /// `name` inside `folder`, matching an existing entry case-insensitively (mods.py child()).
    static func child(_ folder: URL, _ name: String) -> URL {
        let fm = FileManager.default
        if let entries = try? fm.contentsOfDirectory(atPath: folder.path) {
            for entry in entries where entry.lowercased() == name.lowercased() {
                return folder.appendingPathComponent(entry)
            }
        }
        return folder.appendingPathComponent(name)
    }

    static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    static func isFile(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue
    }

    /// mods.py content_root: <mod>/dvdroot_ps4, <mod>/app0/dvdroot_ps4, <mod>/<serial>/dvdroot_ps4,
    /// one wrapper folder around any of these, and the game's folders without dvdroot_ps4.
    static func contentRoot(_ folder: URL, via: [String] = []) -> ContentRoot? {
        guard isDirectory(folder) else { return nil }
        for wrapper in ["", "app0"] + serials {
            let base = wrapper.isEmpty ? folder : child(folder, wrapper)
            if isDirectory(child(base, "dvdroot_ps4")) {
                return ContentRoot(root: base, prefix: "", via: via + (wrapper.isEmpty ? [] : [base.lastPathComponent]), bare: [])
            }
        }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }
        let entries = names.map { folder.appendingPathComponent($0) }
        let folders = entries.filter(isDirectory)
        if !folders.isEmpty, folders.allSatisfy({ gameFolders.contains($0.lastPathComponent.lowercased()) }) {
            return ContentRoot(root: folder, prefix: "dvdroot_ps4", via: via, bare: folders.map(\.lastPathComponent).sorted())
        }
        if folders.count == 1, !entries.contains(where: { isFile($0) && !metadataExtensions.contains(suffix($0)) }) {
            return contentRoot(folders[0], via: via + [folders[0].lastPathComponent])
        }
        return nil
    }

    /// Python's Path.suffix, lowercased: ".txt", or "" without one.
    private static func suffix(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? "" : "." + ext
    }

    /// mods.py mod_files: every file under dvdroot_ps4 (or the game's folders) with its game path.
    /// Throws for what mods.py refuses: links, eboot.bin/sce_module/sce_sys, not regular files.
    static func files(of content: ContentRoot) throws -> [String] {
        var result: [String] = []
        let prefix = content.prefix.isEmpty ? [] : [content.prefix]
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
        func walk(_ directory: URL, _ relative: [String]) throws {
            let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [])
            for entry in entries {
                let values = try entry.resourceValues(forKeys: Set(keys))
                if values.isSymbolicLink == true { throw ModError.symlink((relative + [entry.lastPathComponent]).joined(separator: "/")) }
            }
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let values = try entry.resourceValues(forKeys: Set(keys))
                let path = relative + [entry.lastPathComponent]
                if values.isDirectory == true {
                    try walk(entry, path)
                    continue
                }
                let game = prefix + path
                if game[0].lowercased() != "dvdroot_ps4" {
                    if systemNames.contains(game[0].lowercased()) { throw ModError.systemFile(path.joined(separator: "/")) }
                    continue
                }
                if values.isRegularFile != true { throw ModError.notRegularFile(path.joined(separator: "/")) }
                result.append(game.joined(separator: "/"))
            }
        }
        try walk(content.root.resolvingSymlinksInPath(), [])
        return result
    }

    /// Top-level names of a folder for the "found" part of an error; a lone wrapper folder is
    /// looked into (a ZIP of one folder).
    static func describeFound(_ folder: URL) -> [String] {
        let fm = FileManager.default
        var folder = folder
        var lead = ""
        for _ in 0..<3 {
            let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") && $0 != "__MACOSX" }.sorted()
            let folders = names.filter { isDirectory(folder.appendingPathComponent($0)) }
            if names.count == 1, folders.count == 1 {
                lead += names[0] + "/"
                folder = folder.appendingPathComponent(names[0])
                continue
            }
            let shown = names.prefix(8).map { lead + $0 + (folders.contains($0) ? "/" : "") }
            return shown + (names.count > 8 ? ["…"] : [])
        }
        return [lead]
    }

    /// The layout and files of a folder, or why it is not a mod.
    static func scan(_ folder: URL, displayName: String? = nil) throws -> (layout: String, files: [String]) {
        guard let content = contentRoot(folder) else {
            throw ModError.notAMod(name: displayName ?? folder.lastPathComponent, found: describeFound(folder))
        }
        return (describe(content), try files(of: content))
    }

    static func describe(_ content: ContentRoot) -> String {
        if content.prefix.isEmpty { return (content.via + ["dvdroot_ps4"]).joined(separator: "/") }
        let names = content.bare.joined(separator: ", ")
        let inside = content.via.isEmpty ? "" : content.via.joined(separator: "/") + ": "
        return inside + String(localized: "game folders (\(names))", table: "Mods", bundle: .module)
    }

    // MARK: The library

    /// The mod at `url`: a mod with files, or a folder with the reason it is not usable.
    func inspect(_ url: URL) -> Mod {
        do {
            let scanned = try Self.scan(url)
            return Mod(name: url.lastPathComponent, url: url, layout: scanned.layout, files: scanned.files, problem: nil)
        } catch {
            return Mod(name: url.lastPathComponent, url: url, layout: "", files: [], problem: error.localizedDescription)
        }
    }

    /// Every subfolder of the mods directory (hidden ones are not mods), sorted like mods.py discover.
    public func mods() -> [Mod] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { !$0.hasPrefix(".") && Self.isDirectory(dir.appendingPathComponent($0)) }
            .sorted { ($0.lowercased(), $0) < ($1.lowercased(), $1) }
        return names.map { inspect(dir.appendingPathComponent($0, isDirectory: true)) }
    }

    /// Copies a folder into the library (APFS clones where possible), after checking it.
    @discardableResult
    public func importFolder(_ source: URL) throws -> Mod {
        let source = source.resolvingSymlinksInPath()
        guard Self.isDirectory(source) else { throw ModError.notAFolder(source.lastPathComponent) }
        _ = try Self.scan(source)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let temporary = dir.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let flags = copyfile_flags_t(COPYFILE_CLONE | COPYFILE_RECURSIVE)
        guard copyfile(source.path, temporary.path, nil, flags) == 0 else {
            throw ModError.copyFailed(String(cString: strerror(errno)))
        }
        return try place(temporary, as: source.lastPathComponent)
    }

    /// Unpacks a ZIP (the system's ditto) into the library. Other archive formats are refused with
    /// a hint.
    @discardableResult
    public func importArchive(_ archive: URL) throws -> Mod {
        let ext = archive.pathExtension.lowercased()
        let name = archive.deletingPathExtension().lastPathComponent
        guard ext == "zip" else {
            if ["7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "xz", "zst", "lzma", "cab"].contains(ext) { throw ModError.unsupportedArchive(ext) }
            throw ModError.notAnArchive(archive.lastPathComponent)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let temporary = dir.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, temporary.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch {
            throw ModError.unpackFailed(name: archive.lastPathComponent, details: error.localizedDescription)
        }
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ModError.unpackFailed(name: archive.lastPathComponent, details: text.isEmpty ? "ditto \(process.terminationStatus)" : text)
        }
        // macOS's own archives carry a __MACOSX folder next to the content; it would hide a wrapper folder.
        try? FileManager.default.removeItem(at: temporary.appendingPathComponent("__MACOSX"))
        _ = try Self.scan(temporary, displayName: archive.lastPathComponent)
        return try place(temporary, as: name)
    }

    /// Moves a checked folder into the library under a name no other mod has.
    private func place(_ temporary: URL, as name: String) throws -> Mod {
        let destination = dir.appendingPathComponent(uniqueName(Self.sanitized(name)), isDirectory: true)
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            throw ModError.copyFailed(error.localizedDescription)
        }
        return inspect(destination)
    }

    /// A name usable as a folder name: no "/" or ":", no leading dot.
    static func sanitized(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "Mod" : cleaned
    }

    private func existingNames() -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).map { $0.lowercased() })
    }

    /// `name`, or "name 2", "name 3", ... when a folder of that name (in any case) exists.
    func uniqueName(_ name: String) -> String {
        let taken = existingNames()
        var candidate = name
        var counter = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(name) \(counter)"
            counter += 1
        }
        return candidate
    }

    /// Renames a mod's folder. Profiles list mods by folder name: the caller updates them.
    @discardableResult
    public func rename(_ mod: Mod, to newName: String) throws -> Mod {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains(":") else { throw ModError.invalidName(newName) }
        if name == mod.name { return mod }
        let destination = dir.appendingPathComponent(name, isDirectory: true)
        let onlyCase = name.lowercased() == mod.name.lowercased()
        guard onlyCase || !existingNames().contains(name.lowercased()) else { throw ModError.nameTaken(name) }
        do {
            if onlyCase {
                // A case-insensitive volume has one entry for both spellings: go through another name.
                let hop = dir.appendingPathComponent(".rename-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.moveItem(at: mod.url, to: hop)
                try FileManager.default.moveItem(at: hop, to: destination)
            } else {
                try FileManager.default.moveItem(at: mod.url, to: destination)
            }
        } catch {
            throw ModError.copyFailed(error.localizedDescription)
        }
        return inspect(destination)
    }

    /// Moves a mod to the Trash.
    public func delete(_ mod: Mod) throws {
        do {
            try FileManager.default.trashItem(at: mod.url, resultingItemURL: nil)
        } catch {
            throw ModError.trashFailed(name: mod.name, reason: error.localizedDescription)
        }
    }

    // MARK: Conflicts

    /// Every game path more than one of the mods provides. `ordered` is the load order of the
    /// enabled mods; the last one wins. Sorted by path.
    public static func conflicts(_ ordered: [Mod]) -> [ModConflict] {
        var providers: [String: (path: String, mods: [String])] = [:]
        for mod in ordered {
            var seen = Set<String>()
            for file in mod.files {
                let key = key(file)
                guard seen.insert(key).inserted else { continue }
                providers[key, default: (file, [])].mods.append(mod.name)
                // The winner's spelling.
                providers[key]?.path = file
            }
        }
        return providers.values
            .filter { $0.mods.count > 1 }
            .map { ModConflict(path: $0.path, mods: $0.mods, winner: $0.mods[$0.mods.count - 1]) }
            .sorted { ($0.path.lowercased(), $0.path) < ($1.path.lowercased(), $1.path) }
    }
}
