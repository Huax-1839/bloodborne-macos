// SPDX-License-Identifier: GPL-2.0-or-later
import LanternCore
import SwiftUI

/// Readable names for LanternCore's settings values.
extension FrameRate {
    var label: LocalizedStringKey {
        switch self {
        case .fps30: "30 FPS"
        case .fps60: "60 FPS"
        case .fps90: "90 FPS"
        case .uncapped: "Uncapped"
        }
    }

    /// The short form for the segmented picker.
    var shortLabel: LocalizedStringKey {
        switch self {
        case .fps30: "30"
        case .fps60: "60"
        case .fps90: "90"
        case .uncapped: "Uncapped"
        }
    }
}

extension RendererChoice {
    var label: LocalizedStringKey {
        switch self {
        case .automatic: "Automatic"
        case .metal: "Metal"
        case .vulkan: "Vulkan (MoltenVK)"
        }
    }

    /// What "automatic" resolves to on this Mac (run.sh's rule).
    static var automaticResolved: RendererChoice {
        MacHost.appleSilicon && MacHost.macOSMajor >= 15 ? .metal : .vulkan
    }
}

extension Effect {
    var label: LocalizedStringKey {
        switch self {
        case .chromaticAberration: "Chromatic aberration"
        case .depthOfField: "Depth of field"
        case .motionBlur: "Motion blur"
        case .ambientOcclusion: "Ambient occlusion"
        case .gameAntiAliasing: "Anti-aliasing"
        case .dynamicShadows: "Dynamic shadows"
        case .reflections: "Reflections (experimental)"
        }
    }
}

/// The bbport.ini names of the upscalers the launcher offers (BbSettings::UpscalerName).
enum UpscalerOption {
    static let names = ["off", "fsr3", "metalfx"]

    static func label(_ name: String) -> Text {
        switch name {
        case "off": Text("Off")
        case "fsr3": Text("FSR 3.1")
        case "metalfx": Text("MetalFX")
        default: Text(verbatim: name)
        }
    }
}

extension Profile {
    /// The upscaler at start (iniValues["upscaler"]), as a key path for adjusted lines.
    var upscalerValue: String? {
        get { iniValues["upscaler"] }
        set { iniValues["upscaler"] = newValue }
    }

    /// An effect's stored state (nil: the game's default), as a key path for adjusted lines.
    var effectStates: [Effect: Bool] {
        get { effects }
        set { effects = newValue }
    }

    /// "960×540", or "Automatic" when the upscaler preset decides.
    var sceneSizeText: Text {
        guard let size = renderResolution else { return Text("Automatic") }
        return Text(verbatim: size.replacingOccurrences(of: "x", with: "×"))
    }

    var rendererText: Text {
        guard renderer == .automatic else { return Text(renderer.label) }
        return RendererChoice.automaticResolved == .metal ? Text("Automatic (Metal)") : Text("Automatic (Vulkan)")
    }
}

/// The signal names a crash card shows.
func signalName(_ signal: Int32) -> String {
    switch signal {
    case 4: "SIGILL"
    case 5: "SIGTRAP"
    case 6: "SIGABRT"
    case 7: "SIGBUS"
    case 9: "SIGKILL"
    case 11: "SIGSEGV"
    default: String(localized: "signal \(Int(signal))")
    }
}

/// The settings a preset's adjustment changed (ProfileStore.adjustments: Profile's JSON keys), as
/// words: "frame rate, mods".
enum AdjustmentLabels {
    static func list(_ keys: [String]) -> String {
        keys.map(label).formatted(.list(type: .and))
    }

    private static func label(_ key: String) -> String {
        switch key {
        case "frameRate": String(localized: "frame rate")
        case "renderer": String(localized: "renderer")
        case "renderResolution": String(localized: "scene size")
        case "effects": String(localized: "effects")
        case "modelLOD": String(localized: "model detail")
        case "iniValues": String(localized: "upscaler")
        case "patches": String(localized: "patches")
        case "mods": String(localized: "mods")
        case "ownSaves": String(localized: "own saves")
        case "environment": String(localized: "expert variables")
        default: key
        }
    }
}

/// The same names as strings, for sentences that list values ("Bildrate 60 → 30").
enum ValueNames {
    static func frameRate(_ rate: FrameRate) -> String {
        switch rate {
        case .fps30: String(localized: "30 FPS")
        case .fps60: String(localized: "60 FPS")
        case .fps90: String(localized: "90 FPS")
        case .uncapped: String(localized: "Uncapped")
        }
    }

    static func renderer(_ choice: RendererChoice) -> String {
        switch choice {
        case .automatic: String(localized: "Automatic")
        case .metal: String(localized: "Metal")
        case .vulkan: String(localized: "Vulkan (MoltenVK)")
        }
    }

    static func sceneSize(_ size: String?) -> String {
        size.map { $0.replacingOccurrences(of: "x", with: "×") } ?? String(localized: "Automatic")
    }

    static func modelDetail(_ level: Int) -> String {
        switch level {
        case -2: String(localized: "Highest")
        case 1: String(localized: "Lower")
        case 2: String(localized: "Lowest")
        default: String(localized: "Default")
        }
    }

    static func upscaler(_ name: String?) -> String {
        switch name {
        case nil: String(localized: "Keep the game's setting")
        case "off": String(localized: "Off")
        case "fsr3": String(localized: "FSR 3.1")
        case "metalfx": String(localized: "MetalFX")
        case let other?: other
        }
    }

    static func effect(_ effect: Effect) -> String {
        switch effect {
        case .chromaticAberration: String(localized: "Chromatic aberration")
        case .depthOfField: String(localized: "Depth of field")
        case .motionBlur: String(localized: "Motion blur")
        case .ambientOcclusion: String(localized: "Ambient occlusion")
        case .gameAntiAliasing: String(localized: "Anti-aliasing")
        case .dynamicShadows: String(localized: "Dynamic shadows")
        case .reflections: String(localized: "Reflections (experimental)")
        }
    }

    static func onOff(_ on: Bool) -> String { on ? String(localized: "on") : String(localized: "off") }

    /// What going from `current` to `target` changes, setting by setting: "Bildrate 60 → 30,
    /// Tiefenschärfe aus → an, Mods".
    static func changes(from current: Profile, to target: Profile) -> String {
        var parts: [String] = []
        func step(_ name: String, _ from: String, _ to: String) { parts.append("\(name) \(from) → \(to)") }
        if current.frameRate != target.frameRate {
            step(String(localized: "frame rate"), frameRate(current.frameRate), frameRate(target.frameRate))
        }
        if current.modelLOD != target.modelLOD {
            step(String(localized: "model detail"), modelDetail(current.modelLOD), modelDetail(target.modelLOD))
        }
        if current.renderer != target.renderer {
            step(String(localized: "renderer"), renderer(current.renderer), renderer(target.renderer))
        }
        if current.renderResolution != target.renderResolution {
            step(String(localized: "scene size"), sceneSize(current.renderResolution), sceneSize(target.renderResolution))
        }
        if current.iniValues["upscaler"] != target.iniValues["upscaler"] {
            step(String(localized: "upscaler"), upscaler(current.iniValues["upscaler"]), upscaler(target.iniValues["upscaler"]))
        }
        for e in Effect.allCases where current.isOn(e) != target.isOn(e) {
            step(effect(e), onOff(current.isOn(e)), onOff(target.isOn(e)))
        }
        if current.ownSaves != target.ownSaves {
            step(String(localized: "own saves"), onOff(current.ownSaves), onOff(target.ownSaves))
        }
        if current.mods != target.mods { parts.append(String(localized: "mods")) }
        if current.patches != target.patches { parts.append(String(localized: "patches")) }
        if current.environment != target.environment { parts.append(String(localized: "expert variables")) }
        var rest = current.iniValues, other = target.iniValues
        rest["upscaler"] = nil
        other["upscaler"] = nil
        if rest != other { parts.append(String(localized: "display")) }
        return parts.joined(separator: ", ")
    }
}

