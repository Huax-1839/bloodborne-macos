// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import LanternCore
import SwiftUI

/// Game folder: the registered games and the three ways to add one.
struct GameView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showMerge = false
    @State private var showPKG = false
    @State private var removing: Game?
    @State private var thoroughGame: String?
    /// The games whose list of damaged files is open.
    @State private var showBroken: Set<String> = []

    var body: some View {
        PageContainer(title: "Game folder") {
            gamesSection
            importSection
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
            if removing?.managed == true {
                Text("The launcher made this folder (merged or extracted): it goes to the Trash.")
            } else {
                Text("The game's files stay where they are.")
            }
        }
    }

    private var removingShown: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    }

    private var removeTitle: Text {
        Text("Remove “\(removing?.check.title ?? "")” from the list?")
    }

    // MARK: Games

    private var gamesSection: some View {
        PrintSection(Text("Your games")) {
            if model.library.games.isEmpty {
                PrintNote(Text("No game added yet. Use one of the three ways below."))
            } else {
                PrintRows {
                    ForEach(model.library.games) { gameRow($0) }
                }
            }
        }
    }

    private func gameRow(_ game: Game) -> some View {
        let active = game.id == model.activeGame?.id
        let checking = thoroughGame == game.id && model.thoroughProgress != nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(verbatim: game.check.title).lineLimit(1)
                Text(verbatim: game.check.version)
                    .font(Print.mono())
                    .foregroundStyle(Print.textSecondary)
                // After the version, so the versions of all rows line up.
                if active {
                    Text(verbatim: "✦")
                        .foregroundStyle(Print.brass)
                        .help(Text("Active"))
                        .accessibilityLabel(Text("Active"))
                }
                Spacer(minLength: 8)
                if !active {
                    Button { model.state.activeGame = game.id } label: { Text("use") }
                        .buttonStyle(TextActionStyle())
                }
                Button { removing = game } label: { Text("remove…") }
                    .buttonStyle(TextActionStyle(color: Print.danger))
                    .disabled(checking)
            }
            Text(verbatim: (game.path.path as NSString).abbreviatingWithTildeInPath)
                .font(Print.mono())
                .foregroundStyle(Print.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            PrintNote(Text(GameCheckText.problem(game.check)), color: game.check.ok ? Print.ok : Print.danger)
            thoroughBlock(game, checking: checking)
                .padding(.top, 4)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Print.line).frame(height: 1) }
    }

    private func thoroughBlock(_ game: Game, checking: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                if checking, let fraction = model.thoroughProgress {
                    Text("Checking every file…")
                        .font(Print.text(14))
                        .foregroundStyle(Print.textSecondary)
                    PrintProgress(fraction: fraction)
                } else if let thorough = game.thorough {
                    let date = thorough.date.formatted(date: .abbreviated, time: .shortened)
                    if thorough.broken.isEmpty {
                        PrintNote(Text("Thorough check on \(date): all files are fine"), color: Print.ok)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            PrintNote(Text("Thorough check on \(date): damaged files found"), color: Print.danger)
                            Text("Damaged files: \(thorough.broken.count)")
                                .font(Print.text(14))
                                .foregroundStyle(Print.textSecondary)
                            Button {
                                if showBroken.contains(game.id) { showBroken.remove(game.id) } else { showBroken.insert(game.id) }
                            } label: { Text(showBroken.contains(game.id) ? "less" : "details") }
                                .buttonStyle(TextActionStyle())
                        }
                        if showBroken.contains(game.id) {
                            ScrollView {
                                Text(verbatim: thorough.broken.joined(separator: "\n"))
                                    .font(Print.mono())
                                    .foregroundStyle(Print.textPrimary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                            }
                            .frame(maxHeight: 160)
                            .background(Print.bgSunken)
                            .overlay(Rectangle().strokeBorder(Print.line, lineWidth: 1))
                        }
                    }
                } else {
                    PrintNote(Text("The thorough check reads every shader file and takes a few minutes."))
                }
            }
            Spacer(minLength: 8)
            Button {
                thoroughGame = game.id
                Task { await model.runThoroughCheck(game) }
            } label: { Text("Thorough check") }
                .buttonStyle(FrameActionStyle())
                .disabled(model.thoroughProgress != nil || model.importStatus != nil)
        }
    }

    // MARK: Import

    private var importSection: some View {
        PrintSection(Text("Add a game")) {
            PrintNote(Text("The launcher never downloads a game. Use your own copy, dumped from your console."))
            if let status = model.importStatus {
                importProgress(status)
            }
            let busy = model.importStatus != nil
            PrintRows {
                ImportOption(
                    title: "Add game folder…",
                    text: "Use this if you already have a ready game folder with update 1.09 applied (it contains eboot.bin and sce_sys). The folder stays where it is.",
                    disabled: busy
                ) {
                    if let url = Panels.chooseFolder(message: String(localized: "Choose the game folder (for example CUSA03173)")) {
                        Task { await model.importFolder(url) }
                    }
                }
                ImportOption(
                    title: "Merge base game and update…",
                    text: "Use this if the base game and the 1.09 update are in two folders. The launcher merges them into one game folder; on the same disk this takes almost no extra space.",
                    disabled: busy
                ) { showMerge = true }
                ImportOption(
                    title: "Import from PKG files…",
                    text: "Use this if you have the base game and the 1.09 update as .pkg files. An external PKG tool unpacks them; the launcher then merges the result.",
                    disabled: busy
                ) { showPKG = true }
            }
        }
    }

    private func importProgress(_ status: (text: String, fraction: Double?)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(verbatim: status.text)
                    .font(Print.text(14))
                    .foregroundStyle(Print.textSecondary)
                Spacer(minLength: 8)
                Button { model.cancelImport() } label: { Text("cancel") }
                    .buttonStyle(TextActionStyle())
            }
            PrintProgress(fraction: status.fraction)
        }
        .padding(.vertical, 8)
    }
}

/// One way to add a game: an explanation and its action.
private struct ImportOption: View {
    let title: LocalizedStringKey
    let text: LocalizedStringKey
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PrintNote(Text(text))
            Button(action: action) { Text(title) }
                .buttonStyle(FrameActionStyle())
                .disabled(disabled)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Print.line).frame(height: 1) }
    }
}

/// A row in a picker sheet: a label, the chosen path and a choose action.
struct PathRow: View {
    let title: LocalizedStringKey
    let url: URL?
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Print.text(14))
                .foregroundStyle(Print.textSecondary)
            HStack(spacing: 16) {
                Group {
                    if let url {
                        Text(verbatim: url.path)
                            .font(Print.mono())
                            .foregroundStyle(Print.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("Nothing chosen yet")
                            .font(Print.text(14))
                            .foregroundStyle(Print.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: action) { Text("choose…") }
                    .buttonStyle(TextActionStyle())
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .background(Print.bgSunken)
            .overlay(Rectangle().strokeBorder(Print.line, lineWidth: 1))
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
        PrintDialog(title: Text("Merge base game and update"), width: 560) {
            PrintNote(Text("Choose the folder of the base game and the folder of the 1.09 update. The update's files replace the base game's; both folders stay unchanged."))
            PathRow(title: "Base game folder", url: base) {
                if let url = Panels.chooseFolder(message: String(localized: "Choose the base game folder")) { base = url }
            }
            PathRow(title: "Update folder", url: update) {
                if let url = Panels.chooseFolder(message: String(localized: "Choose the update folder")) { update = url }
            }
        } actions: {
            Button(role: .cancel) { dismiss() } label: { Text("Cancel") }
                .keyboardShortcut(.cancelAction)
            Button {
                if let base, let update {
                    dismiss()
                    onMerge(base, update)
                }
            } label: { Text("Merge") }
                .keyboardShortcut(.defaultAction)
                .disabled(base == nil || update == nil)
        }
    }
}

/// Import path (c): the base and update PKG files and the external tool.
struct PKGSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    let onImport: (URL, URL) -> Void
    @State private var base: URL?
    @State private var update: URL?

    var body: some View {
        PrintDialog(title: Text("Import from PKG files"), width: 560) {
            PrintNote(Text("Choose the base game's .pkg and the full 1.09 update's .pkg. A delta update does not work."))
            PathRow(title: "Base game PKG", url: base) {
                if let url = Panels.chooseFile(message: String(localized: "Choose the base game PKG"), types: [.ps4Package]) { base = url }
            }
            PathRow(title: "Update PKG", url: update) {
                if let url = Panels.chooseFile(message: String(localized: "Choose the update PKG"), types: [.ps4Package]) { update = url }
            }
            toolSection
        } actions: {
            Button(role: .cancel) { dismiss() } label: { Text("Cancel") }
                .keyboardShortcut(.cancelAction)
            Button {
                if let base, let update {
                    dismiss()
                    onImport(base, update)
                }
            } label: { Text("Import") }
                .keyboardShortcut(.defaultAction)
                .disabled(base == nil || update == nil || model.pkgTool == nil || model.pkgToolSearching)
        }
        // Once per opening: finding the tool runs the chosen program.
        .task { await model.refreshPKGTool() }
    }

    private var tool: String? {
        model.pkgTool.map { "\($0.kind.displayName) – \($0.executable.path)" }
    }

    private var toolSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PKG tool")
                .font(Print.smallCaps())
                .tracking(14 * 0.12)
                .foregroundStyle(Print.textSecondary)
                .accessibilityAddTraits(.isHeader)
            if model.pkgToolSearching {
                PrintNote(Text("Looking for the PKG tool…"))
                PrintProgress(fraction: nil)
            } else if let tool {
                Text(verbatim: tool)
                    .font(Print.mono())
                    .foregroundStyle(Print.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } else {
                PrintNote(Text("No PKG tool was found on this Mac. The launcher does not bundle or download one: install ps4-pkg-tools (recommended), then choose its executable here."))
            }
            HStack(spacing: 16) {
                Button {
                    if let url = Panels.chooseFile(message: String(localized: "Choose the PKG tool's executable"), types: []) {
                        Task { await model.choosePKGTool(url) }
                    }
                } label: { Text(tool == nil ? "Choose the tool…" : "Choose another tool…") }
                    .buttonStyle(TextActionStyle())
                    .disabled(model.pkgToolSearching)
                Button {
                    if let url = URL(string: "https://github.com/xXJSONDeruloXx/ps4-pkg-tools") { NSWorkspace.shared.open(url) }
                } label: { Text("ps4-pkg-tools on GitHub") }
                    .buttonStyle(TextActionStyle())
            }
        }
    }
}
