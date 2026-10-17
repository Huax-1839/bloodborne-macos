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

    public init() {}

    public static func load(_ url: URL) -> LauncherState {
        (try? JSONDecoder.lantern.decode(LauncherState.self, from: Data(contentsOf: url))) ?? LauncherState()
    }

    public func save(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.lantern.encode(self).write(to: url, options: .atomic)
    }
}
