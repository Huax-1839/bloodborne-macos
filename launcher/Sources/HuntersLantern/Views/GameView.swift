// SPDX-License-Identifier: GPL-2.0-or-later
import LanternCore
import SwiftUI

/// Game: the registered games and the three ways to add one.
struct GameView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showMerge = false
    @State private var showPKG = false
    @State private var removing: Game?
    @State private var thoroughGame: String?

    var body: some View {
        PageContainer(title: "Game") {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    gamesSection
                    importSection
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
        .sheet(isPresented: $showMerge) {
            MergeSheet { base, update in
                Task { await model.importBaseAndUpdate(base: base, update: update) }
            }
        }
        .sheet(isPresented: $showPKG) {
            PKGSheet { base, update in
                Task { await model.importPKGs(base: base, update: update) }
            }
        }
        .confirmationDialog(removeTitle, isPresented: removingShown, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let game = removing { model.removeGame(game) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("The game's files stay where they are.")
        }
    }

    private var removingShown: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    }

    private var removeTitle: Text {
        Text("Remove “\(removing?.check.title ?? "")” from the list?")
    }

    // MARK: Games

    @ViewBuilder
    private var gamesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your games").font(.display(.title3))
            if model.library.games.isEmpty {
                Text("No game added yet. Use one of the three ways below.")
                    .foregroundStyle(.secondary)
                    .card()
            }
            ForEach(model.library.games) { game in gameCard(game) }
        }
    }

    private func gameCard(_ game: Game) -> some View {
        let active = game.id == model.activeGame?.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(game.check.title).font(.headline)
                Text("Version \(game.check.version)").foregroundStyle(.secondary)
                if active { Badge("Active", tint: Theme.amber) }
                Spacer()
                if !active {
                    Button("Set active") { model.state.activeGame = game.id }
                }
                Button("Remove…", role: .destructive) { removing = game }
            }
            Text(verbatim: game.path.path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: game.check.ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(game.check.ok ? Color.green : Color.orange)
                Text(GameCheckText.problem(game.check))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            thoroughRow(game)
        }
        .card()
    }

    @ViewBuilder
    private func thoroughRow(_ game: Game) -> some View {
        let running = thoroughGame == game.id && model.thoroughProgress != nil
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                if running, let fraction = model.thoroughProgress {
                    ProgressView(value: fraction) {
                        Text("Checking every file…").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 320)
                } else if let thorough = game.thorough {
                    let date = thorough.date.formatted(date: .abbreviated, time: .shortened)
                    if thorough.broken.isEmpty {
                        Label("Thorough check on \(date): all files are fine", systemImage: "checkmark.circle")
                            .font(.callout)
                    } else {
                        Label("Thorough check on \(date): damaged files found", systemImage: "xmark.circle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                        DisclosureGroup("Damaged files: \(thorough.broken.count)") {
                            ScrollView {
                                Text(verbatim: thorough.broken.joined(separator: "\n"))
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 140)
                        }
                        .font(.callout)
                    }
                } else {
                    Text("The thorough check reads every shader file and takes a few minutes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Thorough check") {
                thoroughGame = game.id
                Task { await model.runThoroughCheck(game) }
            }
            .disabled(model.thoroughProgress != nil || model.importStatus != nil)
        }
    }

    // MARK: Import

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a game").font(.display(.title3))
            Text("The launcher never downloads a game. Use your own copy, dumped from your console.")
                .foregroundStyle(.secondary)
            if let status = model.importStatus {
                importProgress(status)
            }
            let busy = model.importStatus != nil
            ImportOption(
                symbol: "folder.badge.plus", title: "Add game folder…",
                text: "Use this if you already have a ready game folder with update 1.09 applied (it contains eboot.bin and sce_sys). The folder stays where it is.",
                disabled: busy
            ) {
                if let url = Panels.chooseFolder(message: String(localized: "Choose the game folder (for example CUSA03173)")) {
                    Task { await model.importFolder(url) }
                }
            }
            ImportOption(
                symbol: "square.on.square", title: "Merge base game and update…",
                text: "Use this if the base game and the 1.09 update are in two folders. The launcher merges them into one game folder; on the same disk this takes almost no extra space.",
                disabled: busy
            ) { showMerge = true }
            ImportOption(
                symbol: "shippingbox", title: "Import from PKG files…",
                text: "Use this if you have the base game and the 1.09 update as .pkg files. An external PKG tool unpacks them; the launcher then merges the result.",
                disabled: busy
            ) { showPKG = true }
        }
    }

    private func importProgress(_ status: (text: String, fraction: Double?)) -> some View {
        HStack(spacing: 12) {
            if let fraction = status.fraction {
                ProgressView(value: fraction).frame(maxWidth: 260)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(verbatim: status.text)
            Spacer()
            Button("Cancel") { model.cancelImport() }
        }
        .card()
    }
}

/// One way to add a game: an explanation and its button.
private struct ImportOption: View {
    let symbol: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.amber)
                .frame(width: 40)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button(title, action: action)
                .controlSize(.large)
                .disabled(disabled)
        }
        .card()
    }
}

/// A row in a picker sheet: a label, the chosen path and a Choose button.
struct PathRow: View {
    let title: LocalizedStringKey
    let url: URL?
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            HStack {
                Group {
                    if let url {
                        Text(verbatim: url.path)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("Nothing chosen yet").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose…", action: action)
            }
            .padding(8)
            .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// Import path (b): the base game and the update, two folders.
struct MergeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onMerge: (URL, URL) -> Void
    @State private var base: URL?
    @State private var update: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Merge base game and update").font(.display(.title2))
            Text("Choose the folder of the base game and the folder of the 1.09 update. The update's files replace the base game's; both folders stay unchanged.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            PathRow(title: "Base game folder", url: base) {
                if let url = Panels.chooseFolder(message: String(localized: "Choose the base game folder")) { base = url }
            }
            PathRow(title: "Update folder", url: update) {
                if let url = Panels.chooseFolder(message: String(localized: "Choose the update folder")) { update = url }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Merge") {
                    if let base, let update {
                        dismiss()
                        onMerge(base, update)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(base == nil || update == nil)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

/// Import path (c): the base and update PKG files and the external tool.
struct PKGSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    let onImport: (URL, URL) -> Void
    @State private var base: URL?
    @State private var update: URL?
    /// Bumped after choosing a tool so the description is read again.
    @State private var toolVersion = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import from PKG files").font(.display(.title2))
            Text("Choose the base game's .pkg and the full 1.09 update's .pkg. A delta update does not work.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            PathRow(title: "Base game PKG", url: base) {
                if let url = Panels.chooseFile(message: String(localized: "Choose the base game PKG"), types: [.ps4Package]) { base = url }
            }
            PathRow(title: "Update PKG", url: update) {
                if let url = Panels.chooseFile(message: String(localized: "Choose the update PKG"), types: [.ps4Package]) { update = url }
            }
            toolSection
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    if let base, let update {
                        dismiss()
                        onImport(base, update)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(base == nil || update == nil || tool == nil)
            }
        }
        .padding(24)
        .frame(width: 580)
    }

    private var tool: String? {
        _ = toolVersion
        return model.pkgToolDescription
    }

    private var toolSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PKG tool").font(.headline)
            if let tool {
                Label(title: { Text(verbatim: tool) }, icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) })
                    .font(.callout)
            } else {
                Text("No PKG tool was found on this Mac. The launcher does not bundle or download one: install ps4-pkg-tools (recommended), then choose its executable here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(tool == nil ? "Choose the tool…" : "Choose another tool…") {
                    if let url = Panels.chooseFile(message: String(localized: "Choose the PKG tool's executable"), types: []) {
                        model.choosePKGTool(url)
                        toolVersion += 1
                    }
                }
                Link("ps4-pkg-tools on GitHub", destination: URL(string: "https://github.com/xXJSONDeruloXx/ps4-pkg-tools")!)
            }
        }
    }
}
