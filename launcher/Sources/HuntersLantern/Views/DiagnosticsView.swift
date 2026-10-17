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
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    systemInfo
                    lastCrash
                    logViewer
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
        .onAppear(perform: reload)
    }

    private var info: String {
        SystemInfo.text(appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
                        hardware: model.hardware, game: model.activeGame, profile: model.activeProfile)
    }

    private var systemInfo: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeading("System information", symbol: "cpu")
            Text(info).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            HStack {
                Button(copied ? "Copied" : "Copy for a bug report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info, forType: .string)
                    copied = true
                }
                Text("Contains no paths and no user names.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    @ViewBuilder
    private var lastCrash: some View {
        if let result = model.lastResult, result.outcome != .finished, result.outcome != .cancelled {
            VStack(alignment: .leading, spacing: 10) {
                CardHeading("Last crash", symbol: "exclamationmark.triangle")
                Text(result.logTail).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let log = result.log {
                    Button("Show this log") { select(log) }
                }
            }
            .card()
        }
    }

    private var logViewer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CardHeading("Game logs", symbol: "doc.text.magnifyingglass")
                Spacer()
                Button("Open logs folder") { NSWorkspace.shared.open(model.dirs.logsDir) }
                Button("Reload", action: reload)
            }
            if logs.isEmpty {
                Text("No logs yet: each game start writes one (the last 10 are kept).").foregroundStyle(.secondary)
            } else {
                Picker("Log", selection: Binding(get: { selected }, set: { if let url = $0 { select(url) } })) {
                    ForEach(logs, id: \.self) { url in Text(url.lastPathComponent).tag(Optional(url)) }
                }
                .labelsHidden()
                ScrollView([.vertical, .horizontal]) {
                    Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 260, maxHeight: 420)
                .background(Theme.ink.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Text("The last 400 lines.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let selected { Button("Open in Console") { NSWorkspace.shared.open(selected) } }
                }
            }
        }
        .card()
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
