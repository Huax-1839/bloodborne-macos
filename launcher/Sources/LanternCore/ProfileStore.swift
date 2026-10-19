// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The built-in presets and the user's profiles (one JSON file each in DataDirs.profilesDir).
/// A preset the user adjusted keeps only the changed settings, in presets/<id>.json: the shipped
/// values stay underneath, and resetting deletes the file.
public struct ProfileStore: Sendable {
    public let dir: URL
    public private(set) var custom: [Profile] = []
    /// The presets as the user has them: shipped values with their adjustments applied.
    public private(set) var presets: [Profile] = Profile.builtins
    /// Each adjusted preset's changed top-level settings (JSON keys), by preset id.
    public private(set) var adjustments: [String: [String]] = [:]
    /// Profile files that could not be read, kept aside under a new name.
    public private(set) var setAside: [URL] = []

    /// Never adjustable: what makes a preset that preset.
    static let fixedKeys: Set<String> = ["id", "name", "builtin", "unmeasured", "basedOn"]

    public init(dir: URL) {
        self.dir = dir
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var setAside: [URL] = []
        custom = files.filter { $0.pathExtension == "json" }
            .compactMap { DataFile.load(Profile.self, from: $0, setAside: &setAside) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.setAside = setAside
        loadPresets()
    }

    public var all: [Profile] { presets + custom }

    /// For lists: each preset followed by the copies made from it, then the other user profiles.
    public var grouped: [Profile] {
        let presetIDs = Set(Profile.builtins.map(\.id))
        let copies = Dictionary(grouping: custom.filter { $0.basedOn.map(presetIDs.contains) == true }) { $0.basedOn! }
        let rest = custom.filter { $0.basedOn.map(presetIDs.contains) != true }
        return presets.flatMap { [$0] + (copies[$0.id] ?? []) } + rest
    }

    public func profile(_ id: String?) -> Profile? { all.first { $0.id == id } }

    /// The shipped preset under an adjusted one.
    public static func shipped(_ id: String) -> Profile? { Profile.builtins.first { $0.id == id } }

    public func isAdjusted(_ id: String) -> Bool { adjustments[id]?.isEmpty == false }

    /// Saves a profile: a user profile whole, a preset as its adjustments (the settings that differ
    /// from the shipped preset; none left removes the file).
    public mutating func save(_ profile: Profile) throws {
        if profile.builtin {
            try saveAdjustment(profile)
            return
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder.lantern.encode(profile).write(to: file(profile.id), options: .atomic)
        custom.removeAll { $0.id == profile.id }
        custom.append(profile)
        custom.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Back to the shipped preset.
    public mutating func reset(_ id: String) throws {
        let url = presetFile(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        loadPresets()
    }

    private mutating func saveAdjustment(_ profile: Profile) throws {
        guard let shipped = Self.shipped(profile.id) else { return }
        let base = try Self.object(shipped), edited = try Self.object(profile)
        let changed = edited.filter { key, value in
            !Self.fixedKeys.contains(key) && !(base[key].map { ($0 as AnyObject).isEqual(value) } ?? false)
        }
        // Keys the edit no longer has at all (an optional set back to nil) are written as null.
        let cleared = base.keys.filter { edited[$0] == nil && !Self.fixedKeys.contains($0) }
        var delta = changed
        for key in cleared { delta[key] = NSNull() }
        let url = presetFile(profile.id)
        if delta.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: delta, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        }
        loadPresets()
    }

    /// The presets with their adjustments; an unreadable adjustment is kept aside, the preset shipped.
    private mutating func loadPresets() {
        var presets: [Profile] = [], adjustments: [String: [String]] = [:]
        for shipped in Profile.builtins {
            let url = presetFile(shipped.id)
            guard let data = try? Data(contentsOf: url) else { presets.append(shipped); continue }
            do {
                guard let delta = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.coderReadCorrupt) }
                var merged = try Self.object(shipped)
                for (key, value) in delta where !Self.fixedKeys.contains(key) {
                    if value is NSNull { merged.removeValue(forKey: key) } else { merged[key] = value }
                }
                var profile = try JSONDecoder.lantern.decode(Profile.self, from: JSONSerialization.data(withJSONObject: merged))
                profile.builtin = true
                presets.append(profile)
                adjustments[shipped.id] = delta.keys.filter { !Self.fixedKeys.contains($0) }.sorted()
            } catch {
                let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: url, to: aside)
                setAside.append(aside)
                presets.append(shipped)
            }
        }
        self.presets = presets
        self.adjustments = adjustments
    }

    private static func object(_ profile: Profile) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder.lantern.encode(profile)) as? [String: Any] ?? [:]
    }

    private func presetFile(_ id: String) -> URL { dir.appendingPathComponent("presets", isDirectory: true).appendingPathComponent(id + ".json") }

    /// A user copy of any profile.
    public mutating func duplicate(_ profile: Profile, name: String) throws -> Profile {
        let copy = profile.userCopy(name: uniqueName(name))
        try save(copy)
        return copy
    }

    /// `name`, or "name 2", "name 3", … when a profile already has it.
    public func uniqueName(_ name: String) -> String {
        let taken = Set(all.map { $0.name.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        var number = 2
        while taken.contains("\(name) \(number)".lowercased()) { number += 1 }
        return "\(name) \(number)"
    }

    public mutating func delete(_ id: String) throws {
        guard custom.contains(where: { $0.id == id }) else { return }
        try FileManager.default.removeItem(at: file(id))
        custom.removeAll { $0.id == id }
    }

    /// Profile export/import: the profile's JSON (a new id on import).
    public func export(_ profile: Profile, to url: URL) throws {
        try JSONEncoder.lantern.encode(profile).write(to: url, options: .atomic)
    }

    /// A profile file read for import, not saved yet: a new id, never built-in, and only the
    /// expert variables a shared file may set (R4). The caller shows `profile.environment` and
    /// asks before saving.
    public func readImport(from url: URL) throws -> ProfileImport {
        var profile = try JSONDecoder.lantern.decode(Profile.self, from: Data(contentsOf: url))
        profile.id = UUID().uuidString.lowercased()
        profile.builtin = false
        let kept = profile.environment.filter {
            ExpertVariables.isValidName($0.key) && !ExpertVariables.notImported.contains($0.key)
        }
        let dropped = Set(profile.environment.keys).subtracting(kept.keys).sorted()
        profile.environment = kept
        return ProfileImport(profile: profile, dropped: dropped)
    }

    public mutating func importProfile(from url: URL) throws -> Profile {
        let profile = try readImport(from: url).profile
        try save(profile)
        return profile
    }

    private func file(_ id: String) -> URL { dir.appendingPathComponent(id + ".json") }
}

/// A profile file read by `ProfileStore.readImport`.
public struct ProfileImport: Sendable {
    public var profile: Profile
    /// Expert variables the file set that were left out (invalid names, `ExpertVariables.notImported`).
    public var dropped: [String]
}
