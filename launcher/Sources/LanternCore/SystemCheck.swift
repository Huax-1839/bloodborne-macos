// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The first-run assistant's checks (D16): Rosetta 2, the macOS version, free space.
public struct SystemCheck: Equatable, Sendable {
    /// Rosetta 2 is installed (macOS 27 does not restore it after an upgrade).
    public var rosetta: Bool
    public var macOSMajor: Int
    /// Bytes free on the data folder's volume (for important use).
    public var freeBytes: Int64?

    public static func current(dataDir: URL) -> SystemCheck {
        SystemCheck(rosetta: rosettaInstalled, macOSMajor: MacHost.macOSMajor, freeBytes: freeSpace(near: dataDir))
    }

    public static var rosettaInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
    }

    /// Metal needs macOS 15; macOS 14 plays on Vulkan.
    public var metalAvailable: Bool { macOSMajor >= 15 }
    /// A game folder needs ~30 GB when the launcher merges or extracts it.
    public var enoughSpaceForImport: Bool { (freeBytes ?? .max) >= 35_000_000_000 }

    /// The free space of the nearest existing folder's volume.
    public static func freeSpace(near url: URL) -> Int64? {
        var folder = url
        while !FileManager.default.fileExists(atPath: folder.path), folder.path != "/" { folder.deleteLastPathComponent() }
        return (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
}

/// System information for bug reports (L6.6): no paths, no user or host names.
public enum SystemInfo {
    public static func text(appVersion: String, hardware: Hardware, game: Game?, profile: Profile?) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var lines = [
            "Hunter's Lantern \(appVersion)",
            "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "\(hardware.chip), \(hardware.gpuCores.map { "\($0)-core GPU" } ?? "GPU cores unknown"), \(hardware.memoryGB) GB",
            "Rosetta 2: \(SystemCheck.rosettaInstalled ? "installed" : "missing")",
        ]
        if let game { lines.append("Game: \(game.check.title) \(game.check.version)\(game.check.ok ? "" : " (\(game.check.problem?.rawValue ?? "?"))")") }
        if let profile {
            lines.append("Profile: \(profile.builtin ? profile.name : "custom"), \(profile.frameRate.rawValue) FPS, renderer \(profile.renderer.rawValue), scene \(profile.renderResolution ?? "auto"), mods \(profile.mods?.count ?? 0)")
        }
        let power = PowerConditions.current()
        lines.append("Power: \(power.onBattery ? "battery" : "AC")\(power.lowPowerMode ? ", Low Power Mode" : "")\(power.hot ? ", hot" : "")")
        return lines.joined(separator: "\n")
    }
}
