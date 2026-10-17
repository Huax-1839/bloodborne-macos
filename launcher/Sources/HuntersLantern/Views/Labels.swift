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
