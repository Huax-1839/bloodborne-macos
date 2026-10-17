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

    public func profile(_ id: String?) -> Profile? { all.first { $0.id == id } }

    /// Saves a user profile (a built-in one cannot be changed: duplicate it).
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
        var copy = profile
        copy.id = UUID().uuidString.lowercased()
        copy.name = name
        copy.builtin = false
        try save(copy)
        return copy
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

    public mutating func importProfile(from url: URL) throws -> Profile {
        var profile = try JSONDecoder.lantern.decode(Profile.self, from: Data(contentsOf: url))
        profile.id = UUID().uuidString.lowercased()
        profile.builtin = false
        try save(profile)
        return profile
    }

    private func file(_ id: String) -> URL { dir.appendingPathComponent(id + ".json") }
}
