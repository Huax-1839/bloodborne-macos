// SPDX-License-Identifier: GPL-2.0-or-later
import LanternCore
import SwiftUI
import UniformTypeIdentifiers

/// Patches (L3.5): the active profile's choice of built-in and external game patches. The frame
/// rate patches follow the profile's frame rate; effects and model detail are the Graphics page's.
/// A built-in profile is read-only. Strings are in the "Patches" table.
struct PatchesView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var page = PatchesModel()

    var body: some View {
        let profile = model.activeProfile
        let store = page.store
        PageContainer(title: "Patches") {
            Form {
                header(profile)
                Group {
                    frameRate(store, profile)
                    extras(store, profile)
                }
                .disabled(profile.builtin)
                external(store, profile)
                managed(store, profile)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .onAppear { page.reload(model: model) }
        .onChange(of: model.isBusy) { page.reload(model: model) }
    }

    // MARK: Sections

    private func header(_ profile: Profile) -> some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name).font(.headline)
                    if profile.builtin {
                        Text("This is a built-in profile and cannot be changed. Duplicate it to make your own.", tableName: "Patches")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Your choices are saved in this profile.", tableName: "Patches")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if profile.builtin {
                    Button { model.duplicateProfile(profile) } label: { Text("Duplicate to edit", tableName: "Patches") }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func frameRate(_ store: PatchStore, _ profile: Profile) -> some View {
        let patches = store.builtIn.filter { $0.category == .frameRate }
            .sorted { index(of: $0) < index(of: $1) }
        return Group {
            if !patches.isEmpty {
                Section {
                    ForEach(patches) { patch in
                        let on = PatchStore.frameRatePatchIsOn(patch, in: profile)
                        HStack {
                            Image(systemName: "lock.fill").foregroundStyle(.secondary).font(.caption)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: patch.name)
                                detail(patch)
                            }
                            Spacer()
                            if on {
                                Label { Text("On", tableName: "Patches") } icon: { Image(systemName: "checkmark.circle.fill") }
                                    .foregroundStyle(Theme.amber)
                            } else {
                                Text("Off", tableName: "Patches").foregroundStyle(.secondary)
                            }
                        }
                        .help(patch.note)
                    }
                } header: {
                    Text("Frame rate", tableName: "Patches")
                } footer: {
                    Text("These follow the profile's frame rate (\(rateName(profile.frameRate))). Change the frame rate on the Graphics page.", tableName: "Patches")
                }
            }
        }
    }

    private func extras(_ store: PatchStore, _ profile: Profile) -> some View {
        let patches = store.builtIn.filter { $0.category == .extra }
        return Group {
            if !patches.isEmpty {
                Section {
                    ForEach(patches) { patch in
                        toggle(patch, profile)
                    }
                    if let (first, second) = PatchStore.conflict(in: profile) {
                        Label {
                            Text("“\(first)” and “\(second)” cannot be used together: the game would not start. Switch one off.", tableName: "Patches")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(.orange)
                        .font(.callout)
                    }
                } header: {
                    Text("Built-in extras", tableName: "Patches")
                } footer: {
                    Text("Game patches that come with the launcher. Hover over a patch for its note. Some say in their note that they have side effects.", tableName: "Patches")
                }
            }
        }
    }

    private func managed(_ store: PatchStore, _ profile: Profile) -> some View {
        let patches = store.builtIn.filter { $0.category == .graphicsManaged || $0.category == .network }
        let resolution = patches.filter { $0.name.hasPrefix("Resolution Patch ") }
        let rest = patches.filter { !$0.name.hasPrefix("Resolution Patch ") }
        let settings = model.state.settings
        return Group {
            if !patches.isEmpty {
                Section {
                    ForEach(rest) { patch in
                        managedRow(Text(verbatim: patch.name), state: PatchStore.managedState(patch, profile: profile, settings: settings),
                                   page: patch.category == .network ? .advanced : .graphics)
                            .help(patch.note)
                    }
                    if !resolution.isEmpty {
                        managedRow(Text("Resolution patches (\(resolution.count))", tableName: "Patches"), state: nil, page: .graphics)
                    }
                } header: {
                    Text("Managed elsewhere", tableName: "Patches")
                } footer: {
                    Text("The launcher switches these itself from your settings.", tableName: "Patches")
                }
            }
        }
    }

    private func managedRow(_ title: Text, state: Bool?, page target: Page) -> some View {
        HStack {
            title.foregroundStyle(.secondary)
            Spacer()
            Group {
                switch state {
                case true?: Text("On", tableName: "Patches")
                case false?: Text("Off", tableName: "Patches")
                case nil: Text("Automatic", tableName: "Patches")
                }
            }
            .foregroundStyle(.tertiary)
            Button {
                model.page = target
            } label: {
                if target == .advanced {
                    Text("Set on the Advanced page", tableName: "Patches")
                } else {
                    Text("Set on the Graphics page", tableName: "Patches")
                }
            }
            .buttonStyle(.link)
            .font(.callout)
        }
    }

    private func external(_ store: PatchStore, _ profile: Profile) -> some View {
        Group {
            Section {
                if store.files.isEmpty {
                    Text("No patch files yet. Add a GoldHEN or shadPS4 XML file for Bloodborne 1.09.", tableName: "Patches")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button { chooseFile() } label: { Text("Add XML file…", tableName: "Patches") }
                    Button { page.showFolder(model: model) } label: { Text("Show patches folder", tableName: "Patches") }
                    Spacer()
                }
                if let problem = page.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            } header: {
                Text("External patches", tableName: "Patches")
            } footer: {
                Text("Patches other people made, applied after the built-in ones. The patch files stay in the patches folder; your choices are saved in the profile.", tableName: "Patches")
            }
            ForEach(store.files) { file in
                Section {
                    if let problem = file.problem {
                        problemText(problem).foregroundStyle(.secondary).font(.callout)
                    }
                    ForEach(file.patches) { patch in
                        toggle(patch, profile)
                            .disabled(profile.builtin)
                    }
                } header: {
                    HStack {
                        Text(verbatim: file.name)
                        Spacer()
                        Button {
                            page.remove(file, model: model)
                        } label: {
                            Label { Text("Move to Trash", tableName: "Patches") } icon: { Image(systemName: "trash") }
                        }
                        .buttonStyle(.borderless)
                        .textCase(nil)
                    }
                }
            }
        }
    }

    // MARK: Pieces

    private func toggle(_ patch: Patch, _ profile: Profile) -> some View {
        Toggle(isOn: binding(patch)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: patch.name)
                detail(patch)
            }
        }
        .help(patch.note)
    }

    /// Author and the start of the note, under the patch's name.
    @ViewBuilder private func detail(_ patch: Patch) -> some View {
        let author = patch.author.isEmpty ? nil : String(localized: "by \(patch.author)", table: "Patches")
        let note = patch.note.split(separator: "\n").first.map(String.init)
        let text = [author, note].compactMap { $0 }.joined(separator: " · ")
        if !text.isEmpty {
            Text(verbatim: text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func problemText(_ problem: PatchFile.Problem) -> Text {
        switch problem {
        case .unreadable: Text("This file cannot be read as a patch file and is skipped.", tableName: "Patches")
        case .otherGame: Text("This file is for another game and is skipped.", tableName: "Patches")
        case .noPatches: Text("This file has no patches for Bloodborne 1.09 and is skipped.", tableName: "Patches")
        }
    }

    private func rateName(_ rate: FrameRate) -> String {
        switch rate {
        case .fps30: "30 FPS"
        case .fps60: "60 FPS"
        case .fps90: "90 FPS"
        case .uncapped: String(localized: "uncapped", table: "Patches")
        }
    }

    private func binding(_ patch: Patch) -> Binding<Bool> {
        Binding(
            get: { PatchStore.isOn(patch, in: model.activeProfile) },
            set: { on in
                let profile = model.activeProfile
                guard !profile.builtin else { return }
                model.saveProfile(PatchStore.setting(patch, on: on, in: profile))
            })
    }

    private func index(of patch: Patch) -> Int {
        PatchStore.frameRateNames.firstIndex(of: patch.name) ?? 0
    }

    private func chooseFile() {
        guard let url = Panels.chooseFile(message: String(localized: "Choose a patch file (XML)", table: "Patches"),
                                          types: [.xml]) else { return }
        page.add(url, model: model)
    }
}
