// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// launcher.json: the active game and profile and the launcher-wide settings.
public struct LauncherState: Codable, Equatable, Sendable {
    public var activeGame: String?
    public var activeProfile: String = Profile.air.id
    public var settings = LauncherSettings()
    public var firstRunDone = false
    /// The PKG tool the user chose (when it is not found on its own).
    public var pkgToolPath: String?
    /// The launcher's own text a size larger (its fonts are fixed sizes, not the system's).
    public var largeText = false

    public init() {}

    /// Every field has a default: a missing or unreadable one keeps it (another version's file).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activeGame = c.decodeLenient(.activeGame)
        activeProfile = c.decode(.activeProfile, or: Profile.air.id)
        settings = c.decode(.settings, or: LauncherSettings())
        firstRunDone = c.decode(.firstRunDone, or: false)
        pkgToolPath = c.decodeLenient(.pkgToolPath)
        largeText = c.decode(.largeText, or: false)
    }

    /// The saved state, else the defaults; a file that cannot be read is kept aside
    /// (appended to `setAside`) instead of being overwritten by the next save.
    public static func load(_ url: URL, setAside: inout [URL]) -> LauncherState {
        DataFile.load(LauncherState.self, from: url, setAside: &setAside) ?? LauncherState()
    }

    public func save(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.lantern.encode(self).write(to: url, options: .atomic)
    }
}
