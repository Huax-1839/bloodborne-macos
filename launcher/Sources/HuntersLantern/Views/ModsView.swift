// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import LanternCore
import SwiftUI
import UniformTypeIdentifiers

/// Mods: the library, and the active profile's mod set (on/off and load order, D10). A built-in
/// profile is read-only.
struct ModsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var library = ModsModel()
    @State private var renaming: Mod?
    @State private var deleting: Mod?
    @State private var dropTargeted = false

    private static let shownConflicts = 300

    var body: some View {
        let profile = model.activeProfile
        PageContainer(title: "Mods") {
            VStack(alignment: .leading, spacing: 14) {
                header(profile)
                if library.loaded && library.mods.isEmpty {
                    emptyState
                } else {
                    modList(profile)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.amber, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                        .background(Theme.amber.opacity(0.06))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !model.isBusy else { return false }
                Task { await add(urls) }
                return true
            } isTargeted: { dropTargeted = $0 }
        }
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
            Text("Move “\(deleting?.name ?? "")” to the Trash?", tableName: "Mods"),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible, presenting: deleting
        ) { mod in
            Button(role: .destructive) { delete(mod) } label: { Text("Move to the Trash", tableName: "Mods") }
            Button(role: .cancel) {} label: { Text("Cancel", tableName: "Mods") }
        } message: { _ in
            Text("The mod is switched off in every profile. You can put it back from the Trash.", tableName: "Mods")
        }
    }

    // MARK: Header

    private func header(_ profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if profile.builtin {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name).font(.headline)
                        Text("This is a built-in profile and has no mods. Duplicate it to switch mods on.", tableName: "Mods")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Duplicate to edit") { model.duplicateProfile(profile) }
                        .buttonStyle(.borderedProminent)
                }
                .card()
            } else {
                Text("Mods replace game files with your own: models, textures, texts. Switch on the mods you want in the profile “\(profile.name)”. They load from top to bottom; if two mods have the same file, the lower one wins. Drag the switched-on mods to change the order.", tableName: "Mods")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button { addFolder() } label: {
                    Label { Text("Add mod folder…", tableName: "Mods") } icon: { Image(systemName: "folder.badge.plus") }
                }
                Button { addZip() } label: {
                    Label { Text("Add ZIP…", tableName: "Mods") } icon: { Image(systemName: "doc.zipper") }
                }
                Button { NSWorkspace.shared.open(model.dirs.modsDir) } label: {
                    Label { Text("Show mods folder", tableName: "Mods") } icon: { Image(systemName: "folder") }
                }
                if let name = library.importing {
                    ProgressView().controlSize(.small)
                    Text("Adding “\(name)”…", tableName: "Mods").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .disabled(library.importing != nil)
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.amber.opacity(0.8))
            Text("No mods yet", tableName: "Mods").font(.display(.title2))
            VStack(spacing: 8) {
                Text("A mod is a set of loose files that replace or add to the game's own: models, textures, texts, sounds. They go into a folder called dvdroot_ps4. Add a mod folder or a ZIP file here, or drop it onto this page.", tableName: "Mods")
                Text("Not supported: mods that replace eboot.bin or system files, and mods that work by injecting a DLL. Archives other than ZIP (7z, RAR) have to be unpacked first, with an app like The Unarchiver.", tableName: "Mods")
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 480)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }

    // MARK: List

    private func modList(_ profile: Profile) -> some View {
        let known = Dictionary(library.mods.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let enabledNames = (profile.mods ?? []).filter { known[$0] != nil }
        let enabled = enabledNames.compactMap { known[$0] }
        let others = library.mods.filter { !enabledNames.contains($0.name) }
        return VStack(spacing: 12) {
            List {
            if !enabled.isEmpty {
                Section {
                    ForEach(enabled) { mod in
                        row(mod, enabled: true, readOnly: profile.builtin)
                    }
                    .onMove { from, to in move(from, to, in: enabled) }
                } header: {
                    Text("Switched on – load order", tableName: "Mods")
                } footer: {
                    Text("The mod at the bottom is loaded last and wins where files overlap.", tableName: "Mods")
                }
            }
            if !others.isEmpty {
                Section {
                    ForEach(others) { mod in
                        row(mod, enabled: false, readOnly: profile.builtin)
                    }
                } header: {
                    Text(enabled.isEmpty ? "Mods" : "Available", tableName: "Mods")
                }
            }
            }
            .scrollContentBackground(.hidden)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(minHeight: 170)
            if !library.conflicts.isEmpty {
                conflictCard
            }
        }
    }

    private func row(_ mod: Mod, enabled: Bool, readOnly: Bool) -> some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { enabled }, set: { setEnabled(mod, $0) })) {
                Text(mod.name)
            }
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(readOnly || (!mod.isValid && !enabled))
            VStack(alignment: .leading, spacing: 2) {
                Text(mod.name).font(.headline)
                if let problem = mod.problem {
                    Label { Text(problem) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else {
                    HStack(spacing: 6) {
                        Text("\(mod.files.count) files", tableName: "Mods")
                        Text(verbatim: "·")
                        Text(verbatim: mod.layout)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    if enabled, let lost = library.overridden[mod.name], lost > 0 {
                        Text("\(lost) of its files are replaced by mods further down", tableName: "Mods")
                            .font(.callout)
                            .foregroundStyle(Theme.amber)
                    }
                }
            }
            Spacer()
            Menu {
                actions(mod)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 3)
        .contextMenu { actions(mod) }
    }

    @ViewBuilder
    private func actions(_ mod: Mod) -> some View {
        Button { renaming = mod } label: { Text("Rename this mod…", tableName: "Mods") }
        Button { NSWorkspace.shared.activateFileViewerSelecting([mod.url]) } label: { Text("Show in Finder", tableName: "Mods") }
        Divider()
        Button(role: .destructive) { deleting = mod } label: { Text("Move this mod to the Trash…", tableName: "Mods") }
    }

    // MARK: Conflicts

    /// Below the list, so it is in view whatever the list's scroll position.
    private var conflictCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label { Text("Overlapping files (\(library.conflicts.count))", tableName: "Mods") } icon: { Image(systemName: "square.on.square") }
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text("Several switched-on mods replace these files. The highlighted mod is the one that wins; change the order to change that.", tableName: "Mods")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(library.conflicts.prefix(Self.shownConflicts)) { conflict in
                        conflictRow(conflict)
                    }
                    if library.conflicts.count > Self.shownConflicts {
                        Text("and \(library.conflicts.count - Self.shownConflicts) more files", tableName: "Mods")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
        }
        .card()
    }

    private func conflictRow(_ conflict: ModConflict) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: Self.displayPath(conflict.path))
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 5) {
                ForEach(Array(conflict.mods.enumerated()), id: \.offset) { index, name in
                    if index > 0 {
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    if name == conflict.winner {
                        Label { Text(name) } icon: { Image(systemName: "checkmark.circle.fill") }
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Theme.amber)
                    } else {
                        Text(name).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
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
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename the mod", tableName: "Mods").font(.display(.title2))
            TextField(text: $name) { Text("Name", tableName: "Mods") }
                .onSubmit { save() }
            if let failure {
                Text(failure).font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button(role: .cancel) { dismiss() } label: { Text("Cancel", tableName: "Mods") }
                    .keyboardShortcut(.cancelAction)
                Button { save() } label: { Text("Rename", tableName: "Mods") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
        }
        .padding(24)
        .frame(width: 400)
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
