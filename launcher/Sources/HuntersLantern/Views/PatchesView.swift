// SPDX-License-Identifier: GPL-2.0-or-later
import LanternCore
import SwiftUI
import UniformTypeIdentifiers

/// A literal from this page's string table (Patches.xcstrings).
private func p(_ key: LocalizedStringKey) -> Text { Text(key, tableName: "Patches") }

/// Patches (L3.5): the active profile's choice of built-in and external game patches. The frame
/// rate patches follow the profile's frame rate; effects and model detail are the Graphics page's.
/// Editing a built-in profile copies it. Strings are in the "Patches" table.
struct PatchesView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var page = PatchesModel()
    /// Patches whose whole note is open.
    @State private var openNotes: Set<String> = []

    var body: some View {
        let profile = model.activeProfile
        let store = page.store
        PageContainer(title: "Patches") {
            PrintSection(Text(verbatim: profile.name)) {
                ProfileEditLine(profile: profile, showsName: false)
            }
            frameRate(store, profile)
            extras(store, profile)
            external(store, profile)
            managed(store, profile)
        }
        .onAppear { page.reload(model: model) }
        .onChange(of: model.isBusy) { page.reload(model: model) }
    }

    // MARK: Sections

    @ViewBuilder
    private func frameRate(_ store: PatchStore, _ profile: Profile) -> some View {
        let patches = store.builtIn.filter { $0.category == .frameRate }
            .sorted { index(of: $0) < index(of: $1) }
        if !patches.isEmpty {
            PrintSection(p("Frame rate")) {
                PrintNote(p("These follow the profile's frame rate (\(rateName(profile.frameRate))). Change the frame rate on the Graphics page."))
                PrintRows {
                    ForEach(patches) { patch in
                        let on = PatchStore.frameRatePatchIsOn(patch, in: profile)
                        patchRow(patch) {
                            HStack(alignment: .firstTextBaseline, spacing: 16) {
                                nameAndDetail(patch)
                                Spacer(minLength: 8)
                                state(on)
                            }
                        }
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
                PrintNote(p("Game patches that come with the launcher. “note” opens a patch's note; some say there that they have side effects."))
                if let (first, second) = PatchStore.conflict(in: profile) {
                    PrintNote(p("“\(first)” and “\(second)” cannot be used together: the game would not start. Switch one off."),
                              color: Print.danger)
                }
                PrintRows {
                    ForEach(patches) { patch in patchRow(patch) { toggle(patch, profile) } }
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
                    p("Set on the Graphics page")
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
                        patchRow(patch) { toggle(patch, profile) }
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

    /// A patch's row: its line, "note" at the end when it has one, and the whole note under it
    /// once opened (side effects are said there, so they must not need the pointer).
    private func patchRow<Line: View>(_ patch: Patch, @ViewBuilder line: () -> Line) -> some View {
        let open = openNotes.contains(patch.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                line()
                if !patch.note.isEmpty {
                    Button {
                        if open { openNotes.remove(patch.id) } else { openNotes.insert(patch.id) }
                    } label: { p(open ? "hide note" : "note") }
                        .buttonStyle(TextActionStyle())
                        .accessibilityLabel(p(open ? "Hide the note on “\(patch.name)”" : "Note on “\(patch.name)”"))
                } else {
                    // Keeps the state column of all rows in line.
                    p("note").font(Print.text(14)).hidden().accessibilityHidden(true)
                }
            }
            if open {
                PrintNote(Text(verbatim: patch.note))
                    .textSelection(.enabled)
                    .padding(.bottom, 8)
            }
        }
        .printRow()
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
                model.saveProfile(PatchStore.setting(patch, on: on, in: model.activeProfile))
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
