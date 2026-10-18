// SPDX-License-Identifier: GPL-2.0-or-later
import LanternCore
import SwiftUI

/// Graphics: the active profile's pre-launch settings. Editing a built-in profile makes a user
/// copy of it (AppModel.saveProfile).
struct GraphicsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var customSize = false
    @State private var customText = ""

    private static let sizes = ["960x540", "1280x720", "1600x900"]

    var body: some View {
        let profile = model.activeProfile
        PageContainer(title: "Settings") {
            ProfileEditLine(profile: profile)
            performance
            display
            effects
            saves
        }
        .onAppear(perform: syncSize)
        .onChange(of: model.state.activeProfile) { syncSize() }
    }

    // MARK: Sections

    private var performance: some View {
        PrintSection(Text("Performance")) {
            RegisterLine(Text("Frame rate")) {
                ChoiceWords(selection: edit(\.frameRate), options: FrameRate.allCases) { Text($0.shortLabel) }
            }
            RegisterLine(Text("Model detail")) {
                PrintMenu(selection: edit(\.modelLOD), options: [-2, 0, 1, 2]) { Self.modelDetail($0) }
            }
        }
    }

    private static func modelDetail(_ level: Int) -> Text {
        switch level {
        case -2: Text("Highest")
        case 1: Text("Lower")
        case 2: Text("Lowest")
        default: Text("Default")
        }
    }

    private var display: some View {
        PrintSection(Text("Display")) {
            RegisterLine(Text("Renderer")) {
                ChoiceWords(selection: edit(\.renderer), options: RendererChoice.allCases) { Text($0.label) }
            }
            if MacHost.macOSMajor < 15 {
                PrintNote(Text("Metal needs macOS 15 or newer. On this Mac the game uses Vulkan."))
            }
            RegisterLine(Text("Scene size")) {
                PrintMenu(selection: sizeSelection, options: [""] + Self.sizes + ["custom"]) { size in
                    switch size {
                    case "": Text("Automatic")
                    case "custom": Text("Custom")
                    default: Text(verbatim: size.replacingOccurrences(of: "x", with: "×"))
                    }
                }
            }
            if showsCustom {
                RegisterLine(Text("Custom size")) {
                    TextField("Width×Height", text: $customText)
                        .textFieldStyle(PrintFieldStyle(font: Print.mono()))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 160)
                        .onSubmit(commitCustom)
                }
                if Self.parseSize(customText) == nil {
                    PrintNote(Text("Enter the size as width and height, for example 1280x720."), color: Print.danger)
                }
            }
            RegisterLine(Text("Upscaler at start")) {
                PrintMenu(selection: upscaler, options: [""] + upscalerChoices) { name in
                    name.isEmpty ? Text("Keep the game's setting") : UpscalerOption.label(name)
                }
            }
            PrintNote(Text("Automatic: the upscaler preset decides the scene size. The upscaler can also be changed in the game's menu."))
        }
    }

    private var effects: some View {
        PrintSection(Text("Effects")) {
            ForEach(Effect.allCases, id: \.self) { effect in
                Toggle(effect.label, isOn: effectBinding(effect))
            }
        }
    }

    private var saves: some View {
        PrintSection(Text("Saves")) {
            Toggle("Own saves for this profile", isOn: edit(\.ownSaves))
            PrintNote(Text("The profile keeps its own savegames, apart from the other profiles. The shader cache stays shared."))
        }
    }

    // MARK: Bindings

    /// A binding to one field of the active profile; a change saves it.
    private func edit<T>(_ keyPath: WritableKeyPath<Profile, T>) -> Binding<T> {
        Binding(
            get: { model.activeProfile[keyPath: keyPath] },
            set: { value in
                var profile = model.activeProfile
                        profile[keyPath: keyPath] = value
                model.saveProfile(profile)
            })
    }

    private func effectBinding(_ effect: Effect) -> Binding<Bool> {
        Binding(
            get: { model.activeProfile.isOn(effect) },
            set: { value in
                var profile = model.activeProfile
                        profile.effects[effect] = value == effect.defaultOn ? nil : value
                model.saveProfile(profile)
            })
    }

    private var upscaler: Binding<String> {
        Binding(
            get: { model.activeProfile.iniValues["upscaler"] ?? "" },
            set: { value in
                var profile = model.activeProfile
                        profile.iniValues["upscaler"] = value.isEmpty ? nil : value
                model.saveProfile(profile)
            })
    }

    /// The offered upscalers, and the profile's own value when it is another one.
    private var upscalerChoices: [String] {
        var names = UpscalerOption.names
        if let current = model.activeProfile.iniValues["upscaler"], !names.contains(current) { names.append(current) }
        return names
    }

    // MARK: Scene size

    private var showsCustom: Bool {
        customSize
    }

    private var sizeSelection: Binding<String> {
        Binding(
            get: {
                if customSize { return "custom" }
                return model.activeProfile.renderResolution ?? ""
            },
            set: { value in
                if value == "custom" {
                    customSize = true
                    if customText.isEmpty { customText = model.activeProfile.renderResolution ?? "" }
                    return
                }
                customSize = false
                var profile = model.activeProfile
                        profile.renderResolution = value.isEmpty ? nil : value
                model.saveProfile(profile)
            })
    }

    private func syncSize() {
        let size = model.activeProfile.renderResolution
        customText = size ?? ""
        customSize = size != nil && !Self.sizes.contains(size!)
    }

    private func commitCustom() {
        guard let size = Self.parseSize(customText) else { return }
        customText = size
        var profile = model.activeProfile
        profile.renderResolution = size
        model.saveProfile(profile)
    }

    /// "1280x720" (also "1280 × 720"): width and height in a sensible range, normalised to "WxH".
    static func parseSize(_ text: String) -> String? {
        let parts = text.lowercased()
            .replacingOccurrences(of: "×", with: "x")
            .replacingOccurrences(of: " ", with: "")
            .split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
              (160...8192).contains(width), (90...8192).contains(height) else { return nil }
        return "\(width)x\(height)"
    }
}

/// The line at the top of a profile's settings: the profile's name and what a change does. A
/// built-in profile is copied on the first change; a copy of one offers the way back to it.
/// (Belongs in the kit if other pages need it.)
struct ProfileEditLine: View {
    @EnvironmentObject private var model: AppModel
    let profile: Profile
    var showsName = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsName {
                Text(verbatim: profile.name)
                    .font(Print.text(16))
                    .foregroundStyle(Print.textPrimary)
            }
            if profile.builtin {
                PrintNote(Text("A built-in profile: your first change makes a copy of your own, and “\(profile.name)” stays as it is."))
            } else if let preset {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text("Changes are saved in this profile, a copy of “\(preset.name)”.")
                        .font(Print.text(14))
                        .foregroundStyle(Print.textSecondary)
                    Button { model.returnToPreset(of: profile) } label: { Text("back to “\(preset.name)”") }
                        .buttonStyle(TextActionStyle())
                }
            } else {
                PrintNote(Text("Changes are saved in this profile."))
            }
        }
    }

    /// The built-in preset this profile was copied from, when it still exists.
    private var preset: Profile? {
        profile.basedOn.flatMap { model.profiles.profile($0) }.flatMap { $0.builtin ? $0 : nil }
    }
}
