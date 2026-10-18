// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import LanternCore
import SwiftUI
import UniformTypeIdentifiers

/// A literal from this page's string table (Mods.xcstrings).
private func m(_ key: LocalizedStringKey) -> Text { Text(key, tableName: "Mods") }

/// Mods: the library, and the active profile's mod set (on/off and load order, D10). A built-in
/// profile is read-only.
struct ModsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var library = ModsModel()
    @State private var renaming: Mod?
    @State private var deleting: Mod?
    @State private var dropTargeted = false

    private static let shownConflicts = 300
    /// A mod row's height (`printRow()`); the reorderable list is this many times the count high.
    private static let rowHeight: CGFloat = 40

    var body: some View {
        let profile = model.activeProfile
        PageContainer(title: "Mods") {
            if profile.builtin { builtinSection(profile) }
            addActions
            if library.loaded && library.mods.isEmpty {
                emptyState
            } else {
                modList(profile)
            }
        } trailing: {
            Button { NSWorkspace.shared.open(model.dirs.modsDir) } label: { m("Show mods folder") }
        }
        .overlay {
            if dropTargeted {
                Rectangle()
                    .strokeBorder(Print.brass, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isBusy else { return false }
            Task { await add(urls) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .task {
            library.configure(dir: model.dirs.modsDir) { model.errorMessage = $0 }
            await library.reload()
            library.updateConflicts(enabled: model.activeProfile.mods ?? [])
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await library.reload() }
        }
        .onChange(of: library.mods) { library.updateConflicts(enabled: model.activeProfile.mods ?? []) }
        .onChange(of: model.activeProfile.mods) { library.updateConflicts(enabled: model.activeProfile.mods ?? []) }
        .onChange(of: model.state.activeProfile) { library.updateConflicts(enabled: model.activeProfile.mods ?? []) }
        .sheet(item: $renaming) { mod in
            RenameModSheet(name: mod.name) { name in
                let failure = await library.rename(mod, to: name)
                if failure == nil { renameInProfiles(from: mod.name, to: name.trimmingCharacters(in: .whitespacesAndNewlines)) }
                return failure
            }
        }
        .confirmationDialog(
            m("Move “\(deleting?.name ?? "")” to the Trash?"),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible, presenting: deleting
        ) { mod in
            Button(role: .destructive) { delete(mod) } label: { m("Move to the Trash") }
            Button(role: .cancel) {} label: { m("Cancel") }
        } message: { _ in
            m("The mod is switched off in every profile. You can put it back from the Trash.")
        }
    }

    // MARK: Header

    private func builtinSection(_ profile: Profile) -> some View {
        PrintSection(Text(verbatim: profile.name)) {
            PrintNote(m("This is a built-in profile and has no mods. Duplicate it to switch mods on."))
            Button { model.duplicateProfile(profile) } label: { m("Duplicate to edit") }
                .buttonStyle(FrameActionStyle())
        }
    }

    private var addActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Button { addFolder() } label: { m("Add mod folder…") }
                Button { addZip() } label: { m("Add ZIP…") }
            }
            .buttonStyle(FrameActionStyle())
            .disabled(library.importing != nil)
            if let name = library.importing {
                PrintProgress(fraction: nil)
                PrintNote(m("Adding “\(name)”…"))
            }
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        PrintSection(m("No mods yet")) {
            PrintNote(m("A mod is a set of loose files that replace or add to the game's own: models, textures, texts, sounds. They go into a folder called dvdroot_ps4. Add a mod folder or a ZIP file here, or drop it onto this page."))
            PrintNote(m("Not supported: mods that replace eboot.bin or system files, and mods that work by injecting a DLL. Archives other than ZIP (7z, RAR) have to be unpacked first, with an app like The Unarchiver."))
        }
    }

    // MARK: List

    @ViewBuilder
    private func modList(_ profile: Profile) -> some View {
        let known = Dictionary(library.mods.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let enabledNames = (profile.mods ?? []).filter { known[$0] != nil }
        let enabled = enabledNames.compactMap { known[$0] }
        let others = library.mods.filter { !enabledNames.contains($0.name) }
        if !enabled.isEmpty {
            PrintSection(m("Switched on – load order")) {
                PrintNote(m("The mod at the bottom is loaded last and wins where files overlap. Drag a mod to change the order."))
                // A List only for the drag reordering; it looks like the rows below it and is as
                // high as its rows (the page scrolls, not the list).
                List {
                    ForEach(Array(enabled.enumerated()), id: \.element.id) { index, mod in
                        row(mod, enabled: true, readOnly: profile.builtin, order: index + 1)
                            .font(Print.text())
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    .onMove { from, to in move(from, to, in: enabled) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .alternatingRowBackgrounds(.disabled)
                .environment(\.defaultMinListRowHeight, Self.rowHeight)
                .frame(height: CGFloat(enabled.count) * Self.rowHeight)
                // The plain list keeps 8 px of its own at both sides.
                .padding(.horizontal, -8)
            }
        }
        if !others.isEmpty {
            PrintSection(m(enabled.isEmpty ? "Mods" : "Available")) {
                PrintRows {
                    ForEach(others) { row($0, enabled: false, readOnly: profile.builtin, order: nil) }
                }
            }
        }
        if !library.conflicts.isEmpty {
            conflictSection
        }
    }

    private func row(_ mod: Mod, enabled: Bool, readOnly: Bool, order: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            if let order {
                Text(verbatim: String(order))
                    .font(Print.mono())
                    .foregroundStyle(Print.textSecondary)
                    .frame(width: 24, alignment: .leading)
            }
            Text(verbatim: mod.name)
                .font(Print.text())
                .foregroundStyle(Print.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let problem = mod.problem {
                Text(verbatim: problem)
                    .font(Print.text(14))
                    .foregroundStyle(Print.danger)
                    .lineLimit(1)
                    .help(problem)
            } else {
                if enabled, let lost = library.overridden[mod.name], lost > 0 {
                    m("\(lost) replaced")
                        .font(Print.text(14))
                        .foregroundStyle(Print.danger)
                        .help(m("\(lost) of its files are replaced by mods further down"))
                }
                m("\(mod.files.count) files")
                    .font(Print.mono())
                    .foregroundStyle(Print.textSecondary)
                    .lineLimit(1)
                    .help(Text(verbatim: mod.layout))
            }
            Button { setEnabled(mod, !enabled) } label: { m(enabled ? "switch off" : "switch on") }
                .buttonStyle(TextActionStyle())
                .disabled(readOnly || (!mod.isValid && !enabled))
            Button { renaming = mod } label: { m("rename…") }
                .buttonStyle(TextActionStyle())
            Button { NSWorkspace.shared.activateFileViewerSelecting([mod.url]) } label: { m("show in Finder") }
                .buttonStyle(TextActionStyle())
            Button { deleting = mod } label: { m("remove") }
                .buttonStyle(TextActionStyle())
        }
        .printRow()
    }

    // MARK: Conflicts

    /// Below the list, so it is in view whatever the list's scroll position.
    private var conflictSection: some View {
        PrintSection(m("Overlapping files (\(library.conflicts.count))")) {
            PrintNote(m("Several switched-on mods replace these files. The mod marked ✦ is the one that wins; change the order to change that."))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(library.conflicts.prefix(Self.shownConflicts)) { conflict in
                        conflictRow(conflict)
                    }
                    if library.conflicts.count > Self.shownConflicts {
                        PrintNote(m("and \(library.conflicts.count - Self.shownConflicts) more files"))
                            .padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
        }
    }

    private func conflictRow(_ conflict: ModConflict) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: Self.displayPath(conflict.path))
                .font(Print.mono())
                .foregroundStyle(Print.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ForEach(Array(conflict.mods.enumerated()), id: \.offset) { index, name in
                    if index > 0 {
                        Text(verbatim: "·").foregroundStyle(Print.textMuted)
                    }
                    if name == conflict.winner {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(verbatim: "✦").foregroundStyle(Print.brass).accessibilityHidden(true)
                            Text(verbatim: name).foregroundStyle(Print.textPrimary)
                        }
                    } else {
                        Text(verbatim: name).foregroundStyle(Print.textSecondary)
                    }
                }
            }
            .font(Print.text(14))
            .lineLimit(1)
        }
        .padding(.vertical, 8)
        .printRow()
    }

    /// The game path without its dvdroot_ps4 root.
    static func displayPath(_ path: String) -> String {
        let root = "dvdroot_ps4/"
        return path.lowercased().hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    // MARK: Actions

    private func addFolder() {
        guard let url = Panels.chooseFolder(message: String(localized: "Choose the mod's folder", table: "Mods")) else { return }
        Task { await add([url]) }
    }

    private func addZip() {
        guard let url = Panels.chooseFile(message: String(localized: "Choose the mod's ZIP file", table: "Mods"), types: [.zip]) else { return }
        Task { await add([url]) }
    }

    /// Imports, then switches the new mods on in a custom profile (at the end: they load last).
    private func add(_ urls: [URL]) async {
        let added = await library.add(urls)
        let profile = model.activeProfile
        guard !profile.builtin, !added.isEmpty else { return }
        var edited = profile
        var names = edited.mods ?? []
        for mod in added where mod.isValid && !names.contains(mod.name) { names.append(mod.name) }
        edited.mods = names.isEmpty ? nil : names
        if edited != profile { model.saveProfile(edited) }
    }

    private func setEnabled(_ mod: Mod, _ on: Bool) {
        var profile = model.activeProfile
        guard !profile.builtin else { return }
        var names = profile.mods ?? []
        names.removeAll { $0 == mod.name }
        if on { names.append(mod.name) }
        profile.mods = names.isEmpty ? nil : names
        model.saveProfile(profile)
    }

    /// Reorders the switched-on mods; names in the profile without a folder keep their places.
    private func move(_ from: IndexSet, _ to: Int, in enabled: [Mod]) {
        var profile = model.activeProfile
        guard !profile.builtin else { return }
        var order = enabled.map(\.name)
        order.move(fromOffsets: from, toOffset: to)
        var next = order.makeIterator()
        let present = Set(enabled.map(\.name))
        profile.mods = (profile.mods ?? []).map { present.contains($0) ? (next.next() ?? $0) : $0 }
        model.saveProfile(profile)
    }

    /// Profiles list mods by folder name: a rename follows in all of them.
    private func renameInProfiles(from old: String, to new: String) {
        for var profile in model.profiles.custom where profile.mods?.contains(old) == true {
            profile.mods = profile.mods?.map { $0 == old ? new : $0 }
            model.saveProfile(profile)
        }
    }

    private func delete(_ mod: Mod) {
        Task {
            guard await library.delete(mod) else { return }
            for var profile in model.profiles.custom where profile.mods?.contains(mod.name) == true {
                let rest = profile.mods?.filter { $0 != mod.name } ?? []
                profile.mods = rest.isEmpty ? nil : rest
                model.saveProfile(profile)
            }
        }
    }
}

/// Asks for a mod's new name; `onSave` returns the reason it failed, if it did.
private struct RenameModSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var name: String
    @State private var failure: String?
    @State private var saving = false
    let onSave: (String) async -> String?

    var body: some View {
        PrintDialog(title: m("Rename the mod"), width: 420) {
            TextField(text: $name) { m("Name") }
                .onSubmit { save() }
            if let failure {
                PrintNote(Text(verbatim: failure), color: Print.danger)
            }
        } actions: {
            Button(role: .cancel) { dismiss() } label: { m("Cancel") }
                .keyboardShortcut(.cancelAction)
            Button { save() } label: { m("Rename") }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
        }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, !saving else { return }
        saving = true
        Task {
            failure = await onSave(name)
            saving = false
            if failure == nil { dismiss() }
        }
    }
}
