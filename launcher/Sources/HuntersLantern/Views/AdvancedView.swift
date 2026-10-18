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
            PrintSection(Text("Window")) {
                Toggle("Start in fullscreen", isOn: $model.state.settings.fullscreen)
                Toggle("Use a specific display", isOn: useDisplay)
                if model.state.settings.display != nil {
                    RegisterLine(Text("Display number")) {
                        ChoiceWords(selection: displayValue, options: Array(1...8)) { Text(verbatim: String($0)) }
                    }
                }
            }
            PrintSection(Text("Controller")) {
                RegisterLine(Text("Controller")) {
                    TextField("Controller", text: gamepad, prompt: Text("First controller found"))
                        .labelsHidden()
                        .frame(width: 240)
                }
                PrintNote(Text("A controller's name (or part of it) or its number. Leave empty to use the first one found."))
            }
            PrintSection(Text("Language")) {
                RegisterLine(Text("Game language")) {
                    PrintMenu(selection: language, options: [""] + Self.languages.map(\.id)) { id in
                        id.isEmpty ? Text("Default (English)") : Text(verbatim: Self.languages.first { $0.id == id }?.name ?? id)
                    }
                }
                PrintNote(Text("The language the game uses for its texts. Languages the game does not contain fall back to English."))
            }
            PrintSection(Text("Network")) {
                Toggle("Skip the online/offline choice at start", isOn: $model.state.settings.skipNetworkChoice)
                PrintNote(Text("The port has no PlayStation Network. With this on, the game starts offline without asking."))
            }
            ExpertVariablesSection()
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
private struct ExpertVariablesSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var newName = ""
    @State private var newValue = ""

    var body: some View {
        let profile = model.activeProfile
        PrintSection(Text("Expert variables (profile “\(profile.name)”)")) {
            PrintNote(Text("Environment variables for the game, set after everything else. Only for experts: a wrong value can stop the game from starting."))
            if profile.builtin {
                ProfileEditLine(profile: profile, showsName: false)
            }
            if !profile.environment.isEmpty {
                PrintRows {
                    ForEach(profile.environment.keys.sorted(), id: \.self) { name in
                        VariableRow(name: name, value: profile.environment[name] ?? "", editable: !profile.builtin) { value in
                            set(name, value)
                        }
                    }
                }
            }
            if !profile.builtin {
                HStack(spacing: 16) {
                    TextField("Name", text: $newName, prompt: Text(verbatim: "BB_…"))
                        .textFieldStyle(PrintFieldStyle(font: Print.mono()))
                        .frame(width: 200)
                    TextField("Value", text: $newValue)
                        .textFieldStyle(PrintFieldStyle(font: Print.mono()))
                    Button("Add", action: add)
                        .buttonStyle(FrameActionStyle())
                        .disabled(!validName)
                }
                .padding(.top, 8)
                if !newName.isEmpty && !validName {
                    PrintNote(Text("Names start with BB_, MVK_ or ROSETTA_ and use capital letters, digits and underscores."),
                              color: Print.danger)
                }
            }
        }
    }

    private var validName: Bool { ExpertVariables.isValidName(newName) }

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

/// One variable: `NAME ········ value`, the value edited in place (Return or leaving the field
/// saves it), and a text action to remove it.
private struct VariableRow: View {
    let name: String
    let value: String
    let editable: Bool
    let onChange: (String?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        RegisterLine {
            Text(verbatim: name)
                .font(Print.mono())
                .foregroundStyle(Print.textPrimary)
        } value: {
            if editable {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    TextField("Value", text: $text)
                        .textFieldStyle(PrintFieldStyle(font: Print.mono()))
                        .frame(width: 240)
                        .focused($focused)
                        .onSubmit { onChange(text) }
                    Button { onChange(nil) } label: { Text("remove") }
                        .buttonStyle(TextActionStyle())
                }
            } else {
                Text(verbatim: value)
                    .font(Print.mono())
                    .foregroundStyle(Print.textSecondary)
            }
        }
        .printRow()
        .onAppear { text = value }
        .onChange(of: value) { text = value }
        .onChange(of: focused) { if !focused && text != value { onChange(text) } }
    }
}
