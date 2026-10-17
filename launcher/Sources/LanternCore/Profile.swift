// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The game's frame-rate patch set (patches.py FPS_PRESETS).
public enum FrameRate: String, Codable, CaseIterable, Sendable {
    case fps30 = "30", fps60 = "60", fps90 = "90", uncapped = "uncap"
}

/// BB_RENDERER; automatic is run.sh's rule (Metal on Apple silicon with macOS 15+).
public enum RendererChoice: String, Codable, CaseIterable, Sendable {
    case automatic, metal, vulkan
}

/// The effects the game menu offers (bbport_settings.h Effects, all patches applied at start).
public enum Effect: String, Codable, CaseIterable, Sendable {
    case chromaticAberration = "effect_chromatic_aberration"
    case depthOfField = "effect_dof"
    case motionBlur = "effect_motion_blur"
    case ambientOcclusion = "effect_ssao"
    case gameAntiAliasing = "effect_game_aa"
    case dynamicShadows = "effect_dynamic_shadows"
    case reflections = "effect_ssr"

    /// The game's default (bbport_settings.h): SSR was not in the original game.
    public var defaultOn: Bool { self != .reflections }
}

/// Encodes [Effect: Bool] as a JSON object keyed by the ini key.
extension Effect: CodingKeyRepresentable {}

/// A profile is a complete package of pre-launch settings (D7): what the in-game menu cannot
/// change live. Built-in presets are values of this type with `builtin` set; the user's copies are
/// JSON files in DataDirs.profilesDir.
public struct Profile: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// A built-in preset (not stored, not editable: duplicate it to change it).
    public var builtin: Bool = false
    /// Values not measured on that hardware (presets for chips we did not have).
    public var unmeasured: Bool = false
    public var frameRate: FrameRate = .fps30
    public var renderer: RendererChoice = .automatic
    /// The scene size ("960x540"); nil: the upscaler preset and output size in bbport.ini decide.
    public var renderResolution: String?
    /// Effects switched off (or SSR on); missing keys keep the game's default.
    public var effects: [Effect: Bool] = [:]
    /// Model detail (patches.py MODEL_LOD: -2 highest, 0 default, 1 lower, 2 lowest).
    public var modelLOD: Int = 0
    /// Starting values for bbport.ini keys the game menu also changes live (upscaler, preset,
    /// sharpness, output_res, show_fps, ...): written before each launch.
    public var iniValues: [String: String] = [:]
    /// External patches switched against their XML default (patches.json semantics, L3.5): name → on.
    public var patches: [String: Bool] = [:]
    /// The mod set: mod folder names in load order (later wins); nil keeps mods off.
    public var mods: [String]?
    /// Own savedata (a separate --user root, the GPU cache shared; D11).
    public var ownSaves: Bool = false
    /// Expert BB_* variables, applied last (Advanced page).
    public var environment: [String: String] = [:]

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public func isOn(_ effect: Effect) -> Bool { effects[effect] ?? effect.defaultOn }

    /// The bbport.ini keys this profile writes before a launch (D7).
    public var iniKeys: [(String, String)] {
        var keys = Effect.allCases.map { ($0.rawValue, isOn($0) ? "1" : "0") }
        keys.append(("model_lod", String(modelLOD)))
        keys += iniValues.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        return keys
    }
}

extension Profile {
    /// "MacBook Air": run.sh's BB_PROFILE=m4air (measured on an M4 Air, 10-core GPU): the scene at
    /// 960x540, upscaled to 1080p, 30 FPS, the four costliest effects off, one model LOD lower.
    public static let air: Profile = {
        var p = Profile(id: "builtin-air", name: "MacBook Air")
        p.builtin = true
        p.frameRate = .fps30
        p.renderResolution = "960x540"
        p.effects = [.dynamicShadows: false, .motionBlur: false, .depthOfField: false, .ambientOcclusion: false]
        p.modelLOD = 1
        p.iniValues = ["upscaler": "metalfx"]
        return p
    }()

    /// Pro chips (16–20 GPU cores): estimated from the Air's GPU times (720p 18 ms a frame on 10
    /// cores), not measured.
    public static let pro: Profile = {
        var p = Profile(id: "builtin-pro", name: "Pro")
        p.builtin = true
        p.unmeasured = true
        p.frameRate = .fps60
        p.renderResolution = "1280x720"
        p.effects = [.motionBlur: false]
        p.iniValues = ["upscaler": "metalfx"]
        return p
    }()

    /// Max and Ultra chips (30+ GPU cores): native 1080p (38 ms a frame on the Air's 10 cores),
    /// not measured.
    public static let max: Profile = {
        var p = Profile(id: "builtin-max", name: "Max")
        p.builtin = true
        p.unmeasured = true
        p.frameRate = .fps60
        p.iniValues = ["upscaler": "metalfx", "preset": "0"]
        return p
    }()

    /// The game as released: 30 FPS, default effects, no mods, no patches beyond the FPS set.
    public static let vanilla: Profile = {
        var p = Profile(id: "builtin-vanilla", name: "Vanilla")
        p.builtin = true
        p.frameRate = .fps30
        return p
    }()

    public static let builtins: [Profile] = [air, pro, max, vanilla]
}
