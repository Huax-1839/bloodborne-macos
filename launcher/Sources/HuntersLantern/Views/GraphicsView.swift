// SPDX-License-Identifier: GPL-2.0-or-later
import LanternCore
import SwiftUI

/// Graphics: the active profile's pre-launch settings. A built-in profile is read-only.
struct GraphicsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var customSize = false
    @State private var customText = ""

    private static let sizes = ["960x540", "1280x720", "1600x900"]

    var body: some View {
        let profile = model.activeProfile
        PageContainer(title: "Graphics") {
            Form {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name).font(.headline)
                            if profile.builtin {
                                Text("This is a built-in profile and cannot be changed. Duplicate it to make your own.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Changes are saved in this profile.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if profile.builtin {
                            Button("Duplicate to edit") { model.duplicateProfile(profile) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
                Group {
                    performance
                    display
                    effects
                    saves
                }
                .disabled(profile.builtin)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .onAppear(perform: syncSize)
        .onChange(of: model.state.activeProfile) { syncSize() }
    }

    // MARK: Sections

    private var performance: some View {
        Section("Performance") {
            Picker("Frame rate", selection: edit(\.frameRate)) {
                ForEach(FrameRate.allCases, id: \.self) { Text($0.shortLabel).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Model detail", selection: edit(\.modelLOD)) {
                Text("Highest").tag(-2)
                Text("Default").tag(0)
                Text("Lower").tag(1)
                Text("Lowest").tag(2)
            }
        }
    }

    private var display: some View {
        Section {
            Picker("Renderer", selection: edit(\.renderer)) {
                ForEach(RendererChoice.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            if MacHost.macOSMajor < 15 {
                Text("Metal needs macOS 15 or newer. On this Mac the game uses Vulkan.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Picker("Scene size", selection: sizeSelection) {
                Text("Automatic").tag("")
                ForEach(Self.sizes, id: \.self) { Text(verbatim: $0.replacingOccurrences(of: "x", with: "×")).tag($0) }
                Text("Custom").tag("custom")
            }
            if showsCustom {
                LabeledContent("Custom size") {
                    TextField("Width×Height", text: $customText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .multilineTextAlignment(.trailing)
                        .onSubmit(commitCustom)
                }
                if Self.parseSize(customText) == nil {
                    Text("Enter the size as width and height, for example 1280x720.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            Picker("Upscaler at start", selection: upscaler) {
                Text("Keep the game's setting").tag("")
                ForEach(upscalerChoices, id: \.self) { UpscalerOption.label($0).tag($0) }
            }
        } header: {
            Text("Display")
        } footer: {
            Text("Automatic: the upscaler preset decides the scene size. The upscaler can also be changed in the game's menu.")
        }
    }

    private var effects: some View {
        Section("Effects") {
            ForEach(Effect.allCases, id: \.self) { effect in
                Toggle(effect.label, isOn: effectBinding(effect))
            }
        }
    }

    private var saves: some View {
        Section {
            Toggle("Own saves for this profile", isOn: edit(\.ownSaves))
        } header: {
            Text("Saves")
        } footer: {
            Text("The profile keeps its own savegames, apart from the other profiles. The shader cache stays shared.")
        }
    }

    // MARK: Bindings

    /// A binding to one field of the active profile; a change saves it (nothing for a built-in profile).
    private func edit<T>(_ keyPath: WritableKeyPath<Profile, T>) -> Binding<T> {
        Binding(
            get: { model.activeProfile[keyPath: keyPath] },
            set: { value in
                var profile = model.activeProfile
                guard !profile.builtin else { return }
                profile[keyPath: keyPath] = value
                model.saveProfile(profile)
            })
    }

    private func effectBinding(_ effect: Effect) -> Binding<Bool> {
        Binding(
            get: { model.activeProfile.isOn(effect) },
            set: { value in
                var profile = model.activeProfile
                guard !profile.builtin else { return }
                profile.effects[effect] = value == effect.defaultOn ? nil : value
                model.saveProfile(profile)
            })
    }

    private var upscaler: Binding<String> {
        Binding(
            get: { model.activeProfile.iniValues["upscaler"] ?? "" },
            set: { value in
                var profile = model.activeProfile
                guard !profile.builtin else { return }
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
                guard !profile.builtin else { return }
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
        guard !profile.builtin else { return }
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
