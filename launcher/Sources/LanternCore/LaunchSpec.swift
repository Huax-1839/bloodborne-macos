// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Settings that are the launcher's, not a profile's (Advanced page): the same for every profile.
public struct LauncherSettings: Codable, Equatable, Sendable {
    /// BB_FULLSCREEN.
    public var fullscreen: Bool = false
    /// BB_DISPLAY: the display index; nil the main display.
    public var display: Int?
    /// BB_GAMEPAD: a controller name or index; nil the first one found.
    public var gamepad: String?
    /// BB_LANGUAGE: the game's system language; nil the system's (runtime default).
    public var gameLanguage: String?
    /// BB_SKIP_NETWORK_CHOICE (default on: the port has no PSN).
    public var skipNetworkChoice: Bool = true

    public init() {}
}

/// One launch: the pipeline steps that prepare the game image, then the game process (D5). Built
/// by the launcher itself and tested against `macos/run.sh --print-env`.
public struct LaunchSpec: Equatable, Sendable {
    /// A pipeline script run with the pipeline's Python before the game starts.
    public struct Step: Equatable, Sendable {
        /// The script's file name in Runtime.scripts ("prepare.py").
        public var script: String
        public var arguments: [String]
        public init(script: String, arguments: [String]) {
            self.script = script
            self.arguments = arguments
        }
    }

    public var steps: [Step]
    public var executable: URL
    public var arguments: [String]
    /// The variables the launch sets (BB_*, MVK_*, ROSETTA_*), on top of the launcher's own
    /// environment.
    public var environment: [String: String]
    public var workingDirectory: URL

    public init(steps: [Step], executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL) {
        self.steps = steps
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

/// What a launch is made from.
public struct LaunchInputs: Sendable {
    public var profile: Profile
    public var gameDir: URL
    /// The prepared image folder (run.sh's out/game; DataDirs.preparedDir/<title>-<hash>, D9).
    public var preparedDir: URL
    public var dirs: DataDirs
    public var runtime: Runtime
    public var settings: LauncherSettings
    /// The scene and output size patches.py --print-scaled derives from bbport.ini (after the
    /// profile's keys were written): used when the profile has no render size, as in run.sh.
    public var scaled: ScaledSizes?
    /// The mod overlay (mods.py's linked tree over the game) the game runs from; nil without mods.
    public var modGame: URL?
    /// The host: Apple silicon and the macOS major version (the automatic renderer).
    public var appleSilicon: Bool
    public var macOSMajor: Int

    public init(profile: Profile, gameDir: URL, preparedDir: URL, dirs: DataDirs, runtime: Runtime,
                settings: LauncherSettings, scaled: ScaledSizes?, modGame: URL? = nil, appleSilicon: Bool, macOSMajor: Int) {
        self.profile = profile
        self.gameDir = gameDir
        self.preparedDir = preparedDir
        self.dirs = dirs
        self.runtime = runtime
        self.settings = settings
        self.scaled = scaled
        self.modGame = modGame
        self.appleSilicon = appleSilicon
        self.macOSMajor = macOSMajor
    }
}

/// patches.py --print-scaled: "960x540 2560x1440" for a non-1080p output.
public struct ScaledSizes: Equatable, Sendable {
    public var render: String
    public var output: String
    public init(render: String, output: String) {
        self.render = render
        self.output = output
    }
}
