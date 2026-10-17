// SPDX-License-Identifier: GPL-2.0-or-later
import LanternCore
import SwiftUI

/// Advanced: the launcher-wide settings and the active profile's expert variables.
struct AdvancedView: View {
    @EnvironmentObject private var model: AppModel

    /// The game's languages (SceSystemParam language ids; the game offers the ones it has texts for).
    private static let languages: [(id: String, name: String)] = [
        ("0", "日本語"), ("1", "English (US)"), ("2", "Français"), ("3", "Español"), ("4", "Deutsch"),
        ("5", "Italiano"), ("6", "Nederlands"), ("7", "Português (Portugal)"), ("8", "Русский"),
        ("9", "한국어"), ("10", "繁體中文"), ("11", "简体中文"), ("16", "Polski"), ("17", "Português (Brasil)"),
        ("18", "English (UK)"), ("19", "Türkçe"),
    ]

    var body: some View {
        PageContainer(title: "Advanced") {
            Form {
                Section("Window") {
                    Toggle("Start in fullscreen", isOn: $model.state.settings.fullscreen)
                    Toggle("Use a specific display", isOn: useDisplay)
                    if let display = model.state.settings.display {
                        Stepper(value: displayValue, in: 1...8) {
                            Text("Display number: \(display)")
                        }
                    }
                }
                Section {
                    TextField("Controller", text: gamepad, prompt: Text("First controller found"))
                } header: {
                    Text("Controller")
                } footer: {
                    Text("A controller's name (or part of it) or its number. Leave empty to use the first one found.")
                }
                Section {
                    Picker("Game language", selection: language) {
                        Text("Default (English)").tag("")
                        ForEach(Self.languages, id: \.id) { Text(verbatim: $0.name).tag($0.id) }
                    }
                } header: {
                    Text("Language")
                } footer: {
                    Text("The language the game uses for its texts. Languages the game does not contain fall back to English.")
                }
                Section {
                    Toggle("Skip the online/offline choice at start", isOn: $model.state.settings.skipNetworkChoice)
                } header: {
                    Text("Network")
                } footer: {
                    Text("The port has no PlayStation Network. With this on, the game starts offline without asking.")
                }
                ExpertVariables()
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    private var useDisplay: Binding<Bool> {
        Binding(get: { model.state.settings.display != nil }, set: { model.state.settings.display = $0 ? 1 : nil })
    }

    private var displayValue: Binding<Int> {
        Binding(get: { model.state.settings.display ?? 1 }, set: { model.state.settings.display = $0 })
    }

    private var gamepad: Binding<String> {
        Binding(
            get: { model.state.settings.gamepad ?? "" },
            set: {
                let text = $0.trimmingCharacters(in: .whitespaces)
                model.state.settings.gamepad = text.isEmpty ? nil : text
            })
    }

    private var language: Binding<String> {
        Binding(
            get: { model.state.settings.gameLanguage ?? "" },
            set: { model.state.settings.gameLanguage = $0.isEmpty ? nil : $0 })
    }
}

/// The active profile's BB_*, MVK_* and ROSETTA_* variables, applied last at launch.
private struct ExpertVariables: View {
    @EnvironmentObject private var model: AppModel
    @State private var newName = ""
    @State private var newValue = ""

    private static let prefixes = ["BB_", "MVK_", "ROSETTA_"]

    var body: some View {
        let profile = model.activeProfile
        Section {
            if profile.builtin {
                Text("Duplicate the profile to add variables. Built-in profiles cannot be changed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(profile.environment.keys.sorted(), id: \.self) { name in
                VariableRow(name: name, value: profile.environment[name] ?? "", editable: !profile.builtin) { value in
                    set(name, value)
                }
            }
            if !profile.builtin {
                HStack {
                    TextField("Name", text: $newName, prompt: Text(verbatim: "BB_…"))
                        .font(.system(.body, design: .monospaced))
                    TextField("Value", text: $newValue)
                        .font(.system(.body, design: .monospaced))
                    Button("Add", action: add)
                        .disabled(!validName)
                }
                if !newName.isEmpty && !validName {
                    Text("Names start with BB_, MVK_ or ROSETTA_ and use capital letters, digits and underscores.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Expert variables (profile “\(profile.name)”)")
        } footer: {
            Text("Environment variables for the game, set after everything else. Only for experts: a wrong value can stop the game from starting.")
        }
    }

    private var validName: Bool {
        Self.prefixes.contains { newName.hasPrefix($0) }
            && newName.count > 3
            && newName.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") }
    }

    private func add() {
        guard validName else { return }
        set(newName, newValue)
        newName = ""
        newValue = ""
    }

    /// nil removes the variable.
    private func set(_ name: String, _ value: String?) {
        var profile = model.activeProfile
        guard !profile.builtin else { return }
        profile.environment[name] = value
        model.saveProfile(profile)
    }
}

private struct VariableRow: View {
    let name: String
    let value: String
    let editable: Bool
    let onChange: (String?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Text(verbatim: name)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            TextField("Value", text: $text)
                .font(.system(.body, design: .monospaced))
                .focused($focused)
                .onSubmit { onChange(text) }
                .disabled(!editable)
            Button {
                onChange(nil)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove")
            .disabled(!editable)
        }
        .onAppear { text = value }
        .onChange(of: value) { text = value }
        .onChange(of: focused) { if !focused && text != value { onChange(text) } }
    }
}
