// SPDX-License-Identifier: GPL-2.0-or-later
import LanternCore
import SwiftUI

/// Graphics: the active profile's pre-launch settings. Editing a built-in profile makes a user
/// copy of it (AppModel.saveProfile).
struct GraphicsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var customSize = false
    @State private var customText = ""
    @FocusState private var customFocused: Bool

    private static let sizes = ["960x540", "1280x720", "1600x900"]

    var body: some View {
        let profile = model.activeProfile
        PageContainer(title: "Graphics") {
            PrintSection(Text(verbatim: profile.name)) {
                ProfileEditLine(profile: profile, showsName: false)
            }
            performance
            display
            effects
            ExpertVariablesSection()
        }
        .onAppear(perform: syncSize)
        .onChange(of: model.state.activeProfile) { syncSize() }
    }

    // MARK: Sections

    private var performance: some View {
        PrintSection(Text("Performance")) {
            RegisterLine(adjusted(Text("Frame rate"), \.frameRate, ValueNames.frameRate)) {
                ChoiceWords(selection: edit(\.frameRate), options: FrameRate.allCases) { Text($0.shortLabel) }
            }
            .resettable(\.frameRate, ValueNames.frameRate, in: self)
            RegisterLine(adjusted(Text("Model detail"), \.modelLOD, ValueNames.modelDetail)) {
                PrintMenu(selection: edit(\.modelLOD), options: [-2, 0, 1, 2]) { Self.modelDetail($0) }
            }
            .resettable(\.modelLOD, ValueNames.modelDetail, in: self)
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
            RegisterLine(adjusted(Text("Renderer"), \.renderer, ValueNames.renderer)) {
                ChoiceWords(selection: edit(\.renderer), options: RendererChoice.allCases) { Text($0.label) }
            }
            .resettable(\.renderer, ValueNames.renderer, in: self)
            if MacHost.macOSMajor < 15 {
                PrintNote(Text("Metal needs macOS 15 or newer. On this Mac the game uses Vulkan."))
            }
            RegisterLine(adjusted(Text("Scene size"), \.renderResolution, ValueNames.sceneSize)) {
                PrintMenu(selection: sizeSelection, options: [""] + Self.sizes + ["custom"]) { size in
                    switch size {
                    case "": Text("Automatic")
                    case "custom": Text("Custom")
                    default: Text(verbatim: size.replacingOccurrences(of: "x", with: "×"))
                    }
                }
            }
            .resettable(\.renderResolution, ValueNames.sceneSize, in: self)
            if showsCustom {
                RegisterLine(Text("Custom size")) {
                    TextField("Width×Height", text: $customText)
                        .textFieldStyle(PrintFieldStyle(font: Print.mono()))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 160)
                        .focused($customFocused)
                        .onSubmit(commitCustom)
                        // Leaving the field keeps a valid size, as Return does.
                        .onChange(of: customFocused) { if !customFocused { commitCustom() } }
                }
                if Self.parseSize(customText) == nil {
                    PrintNote(Text("Enter the size as width and height, for example 1280x720."), color: Print.danger)
                }
            }
            RegisterLine(adjusted(Text("Upscaler at start"), \.upscalerValue, ValueNames.upscaler)) {
                PrintMenu(selection: upscaler, options: [""] + upscalerChoices) { name in
                    name.isEmpty ? Text("Keep the game's setting") : UpscalerOption.label(name)
                }
            }
            .resettable(\.upscalerValue, ValueNames.upscaler, in: self)
            if model.activeProfile.renderResolution == nil && !customSize {
                PrintNote(Text("Automatic: the upscaler preset decides the scene size. The upscaler can also be changed in the game's menu."))
            }
        }
    }

    private var effects: some View {
        PrintSection(Text("Effects")) {
            ForEach(Effect.allCases, id: \.self) { effect in
                Toggle(isOn: effectBinding(effect)) {
                    adjusted(Text(effect.label), \.effectStates[effect], { ValueNames.onOff($0 ?? effect.defaultOn) })
                }
                .resettable(\.effectStates[effect], { ValueNames.onOff($0 ?? effect.defaultOn) }, in: self)
            }
        }
    }

    // MARK: Adjusted lines

    /// The shipped preset under the active profile, when it is a preset.
    fileprivate var shipped: Profile? {
        model.activeProfile.builtin ? ProfileStore.shipped(model.activeProfile.id) : nil
    }

    /// A line's label, with "war 30" in brass after it when the preset is adjusted there.
    private func adjusted<T: Equatable>(_ title: Text, _ keyPath: WritableKeyPath<Profile, T>, _ name: (T) -> String) -> Text {
        guard let shipped, model.activeProfile[keyPath: keyPath] != shipped[keyPath: keyPath] else { return title }
        return title + Text(verbatim: "   ") + Text("was \(name(shipped[keyPath: keyPath]))").font(Print.text(14)).foregroundStyle(Print.brass)
    }

    /// Back to the preset's own value for one line.
    fileprivate func reset<T>(_ keyPath: WritableKeyPath<Profile, T>) {
        guard let shipped else { return }
        var profile = model.activeProfile
        profile[keyPath: keyPath] = shipped[keyPath: keyPath]
        model.saveProfile(profile)
    }

    fileprivate func isAdjusted<T: Equatable>(_ keyPath: WritableKeyPath<Profile, T>) -> Bool {
        guard let shipped else { return false }
        return model.activeProfile[keyPath: keyPath] != shipped[keyPath: keyPath]
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
/// preset keeps changes as its adjustment, names what is adjusted and can be reset (asked first);
/// an older copy of a preset offers the way back to it. (Belongs in the kit if other pages need it.)
struct ProfileEditLine: View {
    @EnvironmentObject private var model: AppModel
    let profile: Profile
    var showsName = true
    @State private var confirmingReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsName {
                Text(verbatim: profile.name)
                    .font(Print.text(16))
                    .foregroundStyle(Print.textPrimary)
            }
            if profile.builtin, let adjusted = model.profiles.adjustments[profile.id], !adjusted.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text("Adjusted: \(AdjustmentLabels.list(adjusted)).")
                        .font(Print.text(14))
                        .foregroundStyle(Print.brass)
                    Button { confirmingReset = true } label: { Text("reset…") }
                        .buttonStyle(TextActionStyle())
                }
                .resetConfirmation(for: profile, adjusted: adjusted, isPresented: $confirmingReset)
            } else if profile.builtin {
                PrintNote(Text("A built-in profile: your changes are kept as adjustments, and “reset” brings back its own settings."))
            } else if let preset {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text("Changes are saved in this profile, a copy of “\(preset.name)”.")
                        .font(Print.text(14))
                        .foregroundStyle(Print.textSecondary)
                    Button { model.returnToPreset(of: profile) } label: { Text("use “\(preset.name)”") }
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

extension View {
    /// A line of an adjusted preset: its context menu sets it back to the preset's value.
    fileprivate func resettable<T: Equatable>(_ keyPath: WritableKeyPath<Profile, T>, _ name: @escaping (T) -> String,
                                              in page: GraphicsView) -> some View {
        contextMenu {
            if page.isAdjusted(keyPath), let shipped = page.shipped {
                Button { page.reset(keyPath) } label: { Text("Reset to “\(name(shipped[keyPath: keyPath]))”") }
            }
        }
    }

    /// Asks before a preset loses its adjustments, naming them.
    func resetConfirmation(for profile: Profile, adjusted: [String], isPresented: Binding<Bool>) -> some View {
        modifier(ResetConfirmation(profile: profile, adjusted: adjusted, isPresented: isPresented))
    }
}

private struct ResetConfirmation: ViewModifier {
    @EnvironmentObject private var model: AppModel
    let profile: Profile
    let adjusted: [String]
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.confirmationDialog(Text("Reset “\(profile.name)”?"), isPresented: $isPresented, titleVisibility: .visible) {
            Button(role: .destructive) { model.resetPreset(profile) } label: { Text("Reset") }
            Button(role: .cancel) {} label: { Text("Cancel") }
        } message: {
            Text("Back to the profile's own settings: \(ProfileStore.shipped(profile.id).map { ValueNames.changes(from: profile, to: $0) } ?? AdjustmentLabels.list(adjusted)).")
        }
    }
}
