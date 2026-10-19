// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import LanternCore
import SwiftUI

/// Minimal diagnostics (L6.6): the game's logs with a viewer, the last crash, the logs folder,
/// and system information to copy into a bug report (no paths, no user or host names).
struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var logs: [URL] = []
    @State private var selected: URL?
    @State private var text = ""
    @State private var copied = false

    var body: some View {
        PageContainer(title: "Diagnostics", locked: false) {
            systemInfo
            lastCrash
            logViewer
        }
        .onAppear(perform: reload)
    }

    private var info: String {
        SystemInfo.text(appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
                        hardware: model.hardware, game: model.activeGame, profile: model.activeProfile)
    }

    private var systemInfo: some View {
        PrintSection(Text("System information")) {
            LogBlock(text: info)
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info, forType: .string)
                    copied = true
                    // "Copied" for a moment, then the action again.
                    Task { try? await Task.sleep(for: .seconds(2.5)); copied = false }
                } label: { Text(copied ? "Copied" : "Copy for a bug report") }
                    .buttonStyle(FrameActionStyle())
                PrintNote(Text("Contains no paths and no user names."))
            }
        }
    }

    @ViewBuilder
    private var lastCrash: some View {
        if let result = model.lastResult, result.outcome != .finished, result.outcome != .cancelled {
            PrintSection(Text("Last crash")) {
                if let failure = HomeView.failure(result.outcome) {
                    PrintNote(failure, color: Print.danger)
                }
                LogBlock(text: result.logTail)
            } trailing: {
                if let log = result.log {
                    Button { select(log) } label: { Text("show this log") }
                }
            }
        }
    }

    private var logViewer: some View {
        PrintSection(Text("Game logs")) {
            if logs.isEmpty {
                PrintNote(Text("No logs yet: each game start writes one (the last 10 are kept)."))
            } else {
                PrintRows {
                    ForEach(logs, id: \.self) { url in
                        Button { select(url) } label: { LogRow(name: url.lastPathComponent, chosen: url == selected) }
                            .buttonStyle(RowLinkStyle())
                    }
                }
                LogBlock(text: text, scrolls: true)
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    PrintNote(Text("The last 400 lines."))
                    if let selected {
                        Button { NSWorkspace.shared.open(selected) } label: { Text("open in Console") }
                            .buttonStyle(TextActionStyle())
                    }
                }
            }
        } trailing: {
            Button { NSWorkspace.shared.open(model.dirs.logsDir) } label: { Text("open logs folder") }
            Button(action: reload) { Text("reload") }
        }
    }

    private func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: model.dirs.logsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        logs = files.filter { $0.lastPathComponent.hasPrefix("run-") || $0.lastPathComponent == "prepare.log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        if let first = selected.flatMap({ logs.contains($0) ? $0 : nil }) ?? logs.first { select(first) }
    }

    private func select(_ url: URL) {
        selected = url
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        let content = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        text = content.split(separator: "\n", omittingEmptySubsequences: false).suffix(400).joined(separator: "\n")
    }
}

/// A log or system information: mono 12 on the sunken background, a 1 px rule round it, square
/// corners, selectable. `scrolls` gives it a fixed height with both scroll directions (a long log).
private struct LogBlock: View {
    let text: String
    var scrolls = false

    var body: some View {
        Group {
            if scrolls {
                ScrollView([.vertical, .horizontal]) { content }
                    .frame(minHeight: 256, maxHeight: 416)
            } else {
                content
            }
        }
        .background(Print.bgSunken)
        .overlay(Rectangle().strokeBorder(Print.line, lineWidth: 1))
    }

    private var content: some View {
        Text(verbatim: text)
            .font(Print.mono())
            .foregroundStyle(Print.textSecondary)
            .textSelection(.enabled)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A log file in the list: ✦ in brass before the chosen one, brass while under the pointer.
private struct LogRow: View {
    let name: String
    let chosen: Bool
    @Environment(\.rowHighlight) private var highlight

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: chosen ? "✦" : "")
                .font(Print.text(16))
                .foregroundStyle(Print.brass)
                .frame(width: 16, alignment: .leading)
                .accessibilityHidden(true)
            Text(verbatim: name)
                .font(Print.mono())
                .foregroundStyle(highlight ? Print.brass : chosen ? Print.textPrimary : Print.textSecondary)
            Spacer(minLength: 0)
        }
        .printRow()
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}
