// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The built-in presets and the user's profiles (one JSON file each in DataDirs.profilesDir).
public struct ProfileStore: Sendable {
    public let dir: URL
    public private(set) var custom: [Profile] = []
    /// Profile files that could not be read, kept aside under a new name.
    public private(set) var setAside: [URL] = []

    public init(dir: URL) {
        self.dir = dir
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var setAside: [URL] = []
        custom = files.filter { $0.pathExtension == "json" }
            .compactMap { DataFile.load(Profile.self, from: $0, setAside: &setAside) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.setAside = setAside
    }

    public var all: [Profile] { Profile.builtins + custom }

    /// For lists: each preset followed by the copies made from it, then the other user profiles.
    public var grouped: [Profile] {
        let presetIDs = Set(Profile.builtins.map(\.id))
        let copies = Dictionary(grouping: custom.filter { $0.basedOn.map(presetIDs.contains) == true }) { $0.basedOn! }
        let rest = custom.filter { $0.basedOn.map(presetIDs.contains) != true }
        return Profile.builtins.flatMap { [$0] + (copies[$0.id] ?? []) } + rest
    }

    public func profile(_ id: String?) -> Profile? { all.first { $0.id == id } }

    /// Saves a user profile (a built-in one is never stored: save a `userCopy` of it).
    public mutating func save(_ profile: Profile) throws {
        precondition(!profile.builtin, "built-in profiles are not stored")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder.lantern.encode(profile).write(to: file(profile.id), options: .atomic)
        custom.removeAll { $0.id == profile.id }
        custom.append(profile)
        custom.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

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
