// SPDX-License-Identifier: GPL-2.0-or-later
import LanternCore
import SwiftUI
import UniformTypeIdentifiers

/// Profiles: pick the active one, duplicate, rename, delete, export and import.
struct ProfilesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var deleting = false
    @State private var renaming = false

    var body: some View {
        PageContainer(title: "Profiles") {
            VStack(alignment: .leading, spacing: 14) {
                Text("A profile is a complete set of settings for one start: frame rate, renderer, sizes, effects and more. The selected profile is the one Play uses.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 28)
                List(selection: selection) {
                    ForEach(model.profiles.all) { profile in
                        row(profile).tag(profile.id)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 28)
                actionBar
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
            }
        }
        .confirmationDialog("Delete the profile “\(model.activeProfile.name)”?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.deleteProfile(model.activeProfile) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
        .sheet(isPresented: $renaming) {
            RenameSheet(name: model.activeProfile.name) { model.renameProfile(model.activeProfile, to: $0) }
        }
    }

    private var selection: Binding<String?> {
        Binding(get: { model.state.activeProfile }, set: { if let id = $0 { model.state.activeProfile = id } })
    }

    private func row(_ profile: Profile) -> some View {
        HStack(spacing: 10) {
            Image(systemName: profile.id == model.state.activeProfile ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(profile.id == model.state.activeProfile ? Theme.amber : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(profile.name).font(.headline)
                    if profile.builtin { Badge("Built-in") }
                    if profile.unmeasured { Badge("Unmeasured", tint: Theme.amber) }
                    if profile.id == model.hardware.suggestedProfile.id { Badge("Recommended for this Mac", tint: .green) }
                }
                summary(profile)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private func summary(_ profile: Profile) -> Text {
        Text(profile.frameRate.label) + Text(verbatim: " · ") + profile.sceneSizeText + Text(verbatim: " · ") + profile.rendererText
    }

    private var actionBar: some View {
        let profile = model.activeProfile
        return HStack {
            Button("Duplicate") { model.duplicateProfile(profile) }
            Button("Rename…") { renaming = true }
                .disabled(profile.builtin)
            Button("Delete…", role: .destructive) { deleting = true }
                .disabled(profile.builtin)
            Spacer()
            Button("Import…") {
                if let url = Panels.chooseFile(message: String(localized: "Choose a profile file"), types: [.json]) {
                    model.importProfile(from: url)
                }
            }
            Button("Export…") {
                if let url = Panels.saveFile(message: String(localized: "Export the profile"), name: profile.name + ".json", type: .json) {
                    model.exportProfile(profile, to: url)
                }
            }
        }
    }
}

/// A name field in a sheet.
struct RenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var name: String
    let onSave: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename the profile").font(.display(.title2))
            TextField("Name", text: $name)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onSave(name)
        dismiss()
    }
}
