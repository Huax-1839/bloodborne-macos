// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// What is wrong with a game folder (scripts/game_check.py problem() kinds, plus the launcher's
/// own for a folder that is no game at all).
public enum GameProblem: String, Codable, Sendable {
    case notAGame = "not_a_game"
    case missingUpdate = "missing_update"
    case wrongEboot = "wrong_eboot"
    case patchedEboot = "patched_eboot"
    case otherTitle = "other_title"
    case unreadable
    case damagedFiles = "damaged_files"
}

/// The quick check's result (D6): title, version, eboot image hash, the shader .dcx files.
public struct GameCheck: Codable, Equatable, Sendable {
    public var problem: GameProblem?
    public var title: String
    public var version: String
    /// SHA-256 of the loaded eboot image (game_check.image_sha256), when readable.
    public var imageSHA256: String?
    public var ok: Bool { problem == nil }

    public init(problem: GameProblem?, title: String, version: String, imageSHA256: String?) {
        self.problem = problem
        self.title = title
        self.version = version
        self.imageSHA256 = imageSHA256
    }
}

/// The game pipeline (D4): checks a game, prepares its image and compiles the patches. In v1 the
/// repository's Python scripts (PythonPipeline); a Swift port replaces them later (L7).
public protocol Pipeline: Sendable {
    /// The quick check at import and before each launch.
    func quickCheck(game: URL) async throws -> GameCheck
    /// Every .dcx file (minutes): the broken ones, relative to the game folder. `progress` gets
    /// (checked, total).
    func thoroughCheck(game: URL, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [String]
    /// The scene and output size run.sh derives from bbport.ini when no render size is given
    /// (patches.py --print-scaled): nil for a 1080p output.
    func scaledSizes(settings: URL) async throws -> ScaledSizes?
    /// Links the enabled mods over the game (mods.py, D10) into `out`/mod-game-*: that folder,
    /// or the game itself when no mod applies. `config` is a mods.json (order/disabled).
    func buildModOverlay(game: URL, out: URL, modsDir: URL, config: URL) async throws -> URL
    /// Runs one launch step with the launch's environment (patches.py reads BB_* variables),
    /// its output appended to `log`.
    func run(_ step: LaunchSpec.Step, environment: [String: String], log: FileHandle?) async throws
}

public struct PipelineError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ description: String) { self.description = description }
}
