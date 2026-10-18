// SPDX-License-Identifier: GPL-2.0-or-later
import LanternCore
import SwiftUI
import UniformTypeIdentifiers

/// A literal from this page's string table (Patches.xcstrings).
private func p(_ key: LocalizedStringKey) -> Text { Text(key, tableName: "Patches") }

/// Patches (L3.5): the active profile's choice of built-in and external game patches. The frame
/// rate patches follow the profile's frame rate; effects and model detail are the Settings page's.
/// A built-in profile is read-only. Strings are in the "Patches" table.
struct PatchesView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var page = PatchesModel()

    var body: some View {
        let profile = model.activeProfile
        let store = page.store
        PageContainer(title: "Patches") {
            header(profile)
            Group {
                frameRate(store, profile)
                extras(store, profile)
            }
            .disabled(profile.builtin)
            external(store, profile)
            managed(store, profile)
        }
        .onAppear { page.reload(model: model) }
        .onChange(of: model.isBusy) { page.reload(model: model) }
    }

    // MARK: Sections

    @ViewBuilder
    private func header(_ profile: Profile) -> some View {
        if profile.builtin {
            PrintSection(Text(verbatim: profile.name)) {
                PrintNote(p("This is a built-in profile and cannot be changed. Duplicate it to make your own."))
                Button { model.duplicateProfile(profile) } label: { p("Duplicate to edit") }
                    .buttonStyle(FrameActionStyle())
            }
        } else {
            PrintSection(Text(verbatim: profile.name)) {
                PrintNote(p("Your choices are saved in this profile."))
            }
        }
    }

    @ViewBuilder
    private func frameRate(_ store: PatchStore, _ profile: Profile) -> some View {
        let patches = store.builtIn.filter { $0.category == .frameRate }
            .sorted { index(of: $0) < index(of: $1) }
        if !patches.isEmpty {
            PrintSection(p("Frame rate")) {
                PrintNote(p("These follow the profile's frame rate (\(rateName(profile.frameRate))). Change the frame rate on the Settings page."))
                PrintRows {
                    ForEach(patches) { patch in
                        let on = PatchStore.frameRatePatchIsOn(patch, in: profile)
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            nameAndDetail(patch)
                            Spacer(minLength: 8)
                            state(on)
                        }
                        .printRow()
                        .help(patch.note)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func extras(_ store: PatchStore, _ profile: Profile) -> some View {
        let patches = store.builtIn.filter { $0.category == .extra }
        if !patches.isEmpty {
            PrintSection(p("Built-in extras")) {
                PrintNote(p("Game patches that come with the launcher. Hover over a patch for its note. Some say in their note that they have side effects."))
                if let (first, second) = PatchStore.conflict(in: profile) {
                    PrintNote(p("“\(first)” and “\(second)” cannot be used together: the game would not start. Switch one off."),
                              color: Print.danger)
                }
                PrintRows {
                    ForEach(patches) { toggle($0, profile).printRow() }
                }
            }
        }
    }

    @ViewBuilder
    private func managed(_ store: PatchStore, _ profile: Profile) -> some View {
        let patches = store.builtIn.filter { $0.category == .graphicsManaged || $0.category == .network }
        let resolution = patches.filter { $0.name.hasPrefix("Resolution Patch ") }
        let rest = patches.filter { !$0.name.hasPrefix("Resolution Patch ") }
        let settings = model.state.settings
        if !patches.isEmpty {
            PrintSection(p("Managed elsewhere")) {
                PrintNote(p("The launcher switches these itself from your settings."))
                PrintRows {
                    ForEach(rest) { patch in
                        managedRow(Text(verbatim: patch.name), state: PatchStore.managedState(patch, profile: profile, settings: settings),
                                   page: patch.category == .network ? .advanced : .graphics)
                            .help(patch.note)
                    }
                    if !resolution.isEmpty {
                        managedRow(p("Resolution patches (\(resolution.count))"), state: nil, page: .graphics)
                    }
                }
            }
        }
    }

    private func managedRow(_ title: Text, state: Bool?, page target: Page) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            title
            Spacer(minLength: 8)
            Group {
                switch state {
                case true?: p("on")
                case false?: p("off")
                case nil: p("Automatic")
                }
            }
            .foregroundStyle(Print.textSecondary)
            .frame(width: 96, alignment: .trailing)
            Button {
                model.page = target
            } label: {
                if target == .advanced {
                    p("Set on the Advanced page")
                } else {
                    p("Set on the Settings page")
                }
            }
            .buttonStyle(TextActionStyle())
        }
        .printRow()
    }

    @ViewBuilder
    private func external(_ store: PatchStore, _ profile: Profile) -> some View {
        PrintSection(p("External patches")) {
            PrintNote(p("Patches other people made, applied after the built-in ones. The patch files stay in the patches folder; your choices are saved in the profile."))
            if store.files.isEmpty {
                PrintNote(p("No patch files yet. Add a GoldHEN or shadPS4 XML file for Bloodborne 1.09."))
            }
            Button { chooseFile() } label: { p("Add XML file…") }
                .buttonStyle(FrameActionStyle())
            if let problem = page.problem {
                PrintNote(Text(verbatim: problem), color: Print.danger)
            }
        } trailing: {
            Button { page.showFolder(model: model) } label: { p("Show patches folder") }
        }
        ForEach(store.files) { file in
            PrintSection(Text(verbatim: file.name)) {
                if let problem = file.problem {
                    PrintNote(problemText(problem))
                }
                PrintRows {
                    ForEach(file.patches) { patch in
                        toggle(patch, profile)
                            .printRow()
                            .disabled(profile.builtin)
                    }
                }
            } trailing: {
                Button {
                    page.remove(file, model: model)
                } label: {
                    p("move to Trash")
                }
            }
        }
    }

    // MARK: Pieces

    private func toggle(_ patch: Patch, _ profile: Profile) -> some View {
        Toggle(isOn: binding(patch)) {
            nameAndDetail(patch)
        }
        .help(patch.note)
    }

    /// The patch's name, with author and the start of the note after it.
    private func nameAndDetail(_ patch: Patch) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(verbatim: patch.name)
                .foregroundStyle(Print.textPrimary)
                .lineLimit(1)
                .layoutPriority(1)
            detail(patch)
        }
    }

    /// Author and the start of the note.
    @ViewBuilder private func detail(_ patch: Patch) -> some View {
        let author = patch.author.isEmpty ? nil : String(localized: "by \(patch.author)", table: "Patches")
        let note = patch.note.split(separator: "\n").first.map(String.init)
        let text = [author, note].compactMap { $0 }.joined(separator: " · ")
        if !text.isEmpty {
            Text(verbatim: text)
                .font(Print.text(14))
                .foregroundStyle(Print.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// A read-only state: ✦ and "an" when on, "aus" when off.
    private func state(_ on: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if on {
                Text(verbatim: "✦").foregroundStyle(Print.brass).accessibilityHidden(true)
                p("on").foregroundStyle(Print.textPrimary)
            } else {
                p("off").foregroundStyle(Print.textSecondary)
            }
        }
    }

    private func problemText(_ problem: PatchFile.Problem) -> Text {
        switch problem {
        case .unreadable: p("This file cannot be read as a patch file and is skipped.")
        case .otherGame: p("This file is for another game and is skipped.")
        case .noPatches: p("This file has no patches for Bloodborne 1.09 and is skipped.")
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
