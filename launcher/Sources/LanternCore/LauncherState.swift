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

    private enum CodingKeys: String, CodingKey {
        case activeGame, activeProfile, settings, firstRunDone, pkgToolPath, textSize, largeText
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(activeGame, forKey: .activeGame)
        try c.encode(activeProfile, forKey: .activeProfile)
        try c.encode(settings, forKey: .settings)
        try c.encode(firstRunDone, forKey: .firstRunDone)
        try c.encodeIfPresent(pkgToolPath, forKey: .pkgToolPath)
        try c.encode(textSize, forKey: .textSize)
    }
    /// The launcher's own text size: 0 normal, 1 larger, 2 large (its fonts are fixed sizes, not
    /// the system's).
    public var textSize = 0

    public init() {}

    /// Every field has a default: a missing or unreadable one keeps it (another version's file).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activeGame = c.decodeLenient(.activeGame)
        activeProfile = c.decode(.activeProfile, or: Profile.air.id)
        settings = c.decode(.settings, or: LauncherSettings())
        firstRunDone = c.decode(.firstRunDone, or: false)
        pkgToolPath = c.decodeLenient(.pkgToolPath)
        // An earlier version wrote largeText: true for "larger".
        textSize = c.decode(.textSize, or: c.decode(.largeText, or: false) ? 1 : 0)
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
