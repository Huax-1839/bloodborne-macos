// SPDX-License-Identifier: GPL-2.0-or-later
import LanternCore
import SwiftUI
import UniformTypeIdentifiers

/// Profiles: pick the active one, duplicate, rename, delete, export and import.
struct ProfilesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var deleting: Profile?
    @State private var renaming: Profile?
    @State private var resetting: Profile?

    var body: some View {
        PageContainer(title: "Profiles") {
            PrintNote(Text("A profile is a complete set of settings for one start: frame rate, renderer, sizes, effects, mods and patches. “Begin the Hunt” uses the selected one; the pages under it in the sidebar change it."))
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(Print.line).frame(height: 1)
                PrintRows {
                    ForEach(model.profiles.grouped) { row($0) }
                }
            }
        } trailing: {
            Button(action: chooseImport) { Text("import…") }
                .disabled(model.isBusy)
        }
        .confirmationDialog("Delete the profile “\(deleting?.name ?? "")”?", isPresented: deleteShown,
                            titleVisibility: .visible, presenting: deleting) { profile in
            if model.ownSaveFolders(profile).isEmpty {
                Button("Delete", role: .destructive) { model.deleteProfile(profile) }
            } else {
                Button("Delete and Keep Its Saves") { model.deleteProfile(profile) }
                Button("Delete and Move Its Saves to the Trash", role: .destructive) {
                    model.deleteProfile(profile, trashingSaves: true)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { profile in
            if let saves = model.ownSaveFolders(profile).first {
                Text("This profile has its own saves. If you keep them, they stay in the data folder (\(saves.path)), but no profile shows them any more.")
            } else {
                Text("This cannot be undone.")
            }
        }
        .confirmationDialog("Import the profile “\(model.pendingImport?.profile.name ?? "")”?", isPresented: importing,
                            titleVisibility: .visible, presenting: model.pendingImport) { pending in
            if pending.profile.environment.isEmpty {
                Button("Import") { model.confirmImport(keepingVariables: false) }
            } else {
                Button("Import with These Variables") { model.confirmImport(keepingVariables: true) }
                Button("Import without Them") { model.confirmImport(keepingVariables: false) }
            }
            Button("Cancel", role: .cancel) { model.pendingImport = nil }
        } message: { pending in
            Text(importMessage(pending))
        }
        .sheet(item: $renaming) { profile in
            RenameSheet(name: profile.name) { model.renameProfile(profile, to: $0) }
        }
    }

    private var deleteShown: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private var importing: Binding<Bool> {
        Binding(get: { model.pendingImport != nil }, set: { if !$0 { model.pendingImport = nil } })
    }

    /// The imported file's expert variables (R4): they change how the game runs, so the user sees
    /// them before they are taken.
    private func importMessage(_ pending: ProfileImport) -> String {
        var parts: [String] = []
        if !pending.profile.environment.isEmpty {
            let list = pending.profile.environment.keys.sorted()
                .map { "\($0)=\(pending.profile.environment[$0] ?? "")" }.joined(separator: "\n")
            parts.append(String(localized: "This profile sets expert variables for the game. Only keep them when you trust the file:\n\(list)"))
        }
        if !pending.dropped.isEmpty {
            parts.append(String(localized: "Left out (not allowed in a profile file): \(pending.dropped.joined(separator: ", "))"))
        }
        return parts.joined(separator: "\n\n")
    }

    private func chooseImport() {
        if let url = Panels.chooseFile(message: String(localized: "Choose a profile file"), types: [.json]) {
            model.importProfile(from: url)
        }
    }

    private func export(_ profile: Profile) {
        if let url = Panels.saveFile(message: String(localized: "Export the profile"), name: profile.name + ".json", type: .json) {
            model.exportProfile(profile, to: url)
        }
    }

    /// One profile: ✦ before the active one, its name (a click makes it active), tags, the
    /// settings in a line, and the actions that apply to it.
    private func row(_ profile: Profile) -> some View {
        let active = profile.id == model.activeProfile.id
        return HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(verbatim: active ? "✦" : "")
                .foregroundStyle(Print.brass)
                .frame(width: 16, alignment: .leading)
                .accessibilityHidden(true)
            Button { model.state.activeProfile = profile.id } label: {
                ProfileLabel(profile: profile, recommended: profile.id == model.hardware.suggestedProfile.id,
                             adjusted: model.profiles.isAdjusted(profile.id))
            }
            .buttonStyle(RowLinkStyle())
            .accessibilityAddTraits(active ? .isSelected : [])
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                if !active {
                    Button { model.state.activeProfile = profile.id } label: { Text("use") }
                }
                Button { model.duplicateProfile(profile) } label: { Text("duplicate") }
                if model.profiles.isAdjusted(profile.id) {
                    Button { resetting = profile } label: { Text("reset…") }
                }
                if !profile.builtin {
                    Button { renaming = profile } label: { Text("rename…") }
                }
                Button { export(profile) } label: { Text("export…") }
                if !profile.builtin {
                    Button { deleting = profile } label: { Text("delete…") }
                }
            }
            .buttonStyle(TextActionStyle())
            .fixedSize()
        }
        .padding(.vertical, 8)
        .printRow()
        // VoiceOver: the row's actions ("use", "export…") belong to this profile.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: profile.name))
        .resetConfirmation(for: profile, adjusted: model.profiles.adjustments[profile.id] ?? [],
                           isPresented: Binding(get: { resetting?.id == profile.id }, set: { if !$0 { resetting = nil } }))
    }
}

/// A profile's name with its tags and, under it, its main settings.
private struct ProfileLabel: View {
    let profile: Profile
    let recommended: Bool
    let adjusted: Bool
    @Environment(\.rowHighlight) private var highlight

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: profile.name)
                    .font(Print.text(16))
                    .foregroundStyle(highlight ? Print.brass : Print.textPrimary)
                    .lineLimit(1)
                if profile.builtin { PrintTag(Text("Built-in"), color: Print.textSecondary) }
                if adjusted { PrintTag(Text("Adjusted")) }
                if profile.unmeasured { PrintTag(Text("Unmeasured"), color: Print.textSecondary) }
                if recommended { PrintTag(Text("Recommended")) }
            }
            summary
                .font(Print.text(14))
                .foregroundStyle(Print.textSecondary)
                .lineLimit(1)
        }
    }

    private var summary: Text {
        Text(profile.frameRate.label) + Text(verbatim: " · ") + profile.sceneSizeText + Text(verbatim: " · ") + profile.rendererText
    }
}

/// A name field in a sheet.
struct RenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var name: String
    let onSave: (String) -> Void

    var body: some View {
        PrintDialog(title: Text("Rename the profile"), width: 420) {
            TextField("Name", text: $name)
                .onSubmit(save)
        } actions: {
            Button(role: .cancel) { dismiss() } label: { Text("Cancel") }
                .keyboardShortcut(.cancelAction)
            Button(action: save) { Text("Rename") }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onSave(name)
        dismiss()
    }
}
