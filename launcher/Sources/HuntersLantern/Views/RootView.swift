// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import LanternCore
import SwiftUI

private struct GameArtworkKey: EnvironmentKey {
    static let defaultValue: NSImage? = nil
}

extension EnvironmentValues {
    /// The active game's artwork, read once by the window (nil: no game or no pic1).
    var gameArtwork: NSImage? {
        get { self[GameArtworkKey.self] }
        set { self[GameArtworkKey.self] = newValue }
    }
}

enum Page: String, CaseIterable, Identifiable {
    case home, game, profiles, graphics, mods, patches, saves, advanced, diagnostics, about

    var id: String { rawValue }
}

/// The window, at least 960 × 600 (docs/LAUNCHER_DESIGN.md): the sidebar of pages, the page, and
/// the status bar under both. The content reaches under the transparent title bar.
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var facts = LibraryFacts()
    @State private var appeared = false
    /// The active game's sce_sys/pic1.png (D17), for the overview's plate and the page headers.
    @State private var artwork: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Sidebar(facts: facts)
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            StatusBar()
        }
        // Fonts read Print.scale when built: a new text size builds the window anew.
        .id(model.state.textSize)
        .frame(minWidth: Print.window.width, maxWidth: .infinity, minHeight: Print.window.height, maxHeight: .infinity)
        .background(Print.bgBase)
        .foregroundStyle(Print.textPrimary)
        .font(Print.text())
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowConfigurator())
        .background {
            // The first-run assistant, a sheet on a view of its own.
            Color.clear.sheet(isPresented: firstRunShown) { FirstRunView().environmentObject(model) }
        }
        .task(id: factsKey) { facts = await LibraryFacts.read(model) }
        .task(id: model.activeGame?.id) { await loadArtwork() }
        .environment(\.gameArtwork, artwork)
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(Print.appear) { appeared = true } }
    }

    @ViewBuilder
    private var page: some View {
        switch model.page {
        case .home: HomeView(facts: facts)
        case .game: GameView()
        case .profiles: ProfilesView()
        case .graphics: GraphicsView()
        case .mods: ModsView()
        case .patches: PatchesView()
        case .saves: SavesView()
        case .advanced: AdvancedView()
        case .diagnostics: DiagnosticsView()
        case .about: AboutView()
        }
    }

    private func loadArtwork() async {
        guard let game = model.activeGame else {
            artwork = nil
            return
        }
        artwork = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: game.backgroundImage) }.value
    }

    /// What the facts depend on: read again after a launch, on another page or profile.
    private var factsKey: String {
        "\(model.state.activeProfile)|\(model.activeGame?.id ?? "")|\(model.phase == nil)|\(model.page.rawValue)"
    }

    /// The first-run assistant until it was finished once (not during snapshots and tests).
    private var firstRunShown: Binding<Bool> {
        Binding(get: { !model.state.firstRunDone && ProcessInfo.processInfo.environment["LANTERN_SNAPSHOT"] == nil
                       && ProcessInfo.processInfo.environment["LANTERN_AUTOPLAY"] == nil },
                set: { if !$0 { model.state.firstRunDone = true } })
    }
}

// MARK: - Sidebar

/// The pages, as a native list (arrow keys, Tab, VoiceOver's "3 of 9") set in the print style:
/// the game's overview and its folder; the active profile, named, as the frame of the pages that
/// belong to it (graphics, mods, patches); the launcher's own pages (saves, shared by the
/// profiles; settings; diagnostics). Positions never move. The current page is marked with ✦.
private struct Sidebar: View {
    @EnvironmentObject private var model: AppModel
    let facts: LibraryFacts

    var body: some View {
        List(selection: selection) {
            // The game's name once there is one; before that the plate carries the app's.
            row(.home) { model.activeGame == nil ? Text("Overview") : Text(verbatim: "Bloodborne") }
            row(.game) { Text("Game folder") }
            Section {
                row(.profiles) { Text(verbatim: model.activeProfile.name) }
                    .help(Text("Profile: \(model.activeProfile.name)"))
                    .accessibilityLabel(Text("Profile: \(model.activeProfile.name)"))
                row(.graphics) { Text("Graphics") }
                row(.mods, count: facts.modsTotal > 0 ? "\(model.activeProfile.mods?.count ?? 0)/\(facts.modsTotal)" : nil) {
                    Text("Mods")
                }
                row(.patches) { Text("Patches") }
            } header: {
                header(Text("Profile"))
            }
            Section {
                row(.saves, count: facts.characters.isEmpty ? nil : "\(facts.characters.count)") { Text("Saves") }
                row(.advanced) { Text("Settings") }
                row(.diagnostics) { Text("Diagnostics") }
            } header: {
                header(Text("Launcher"))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        // The ✦ marks the current page; the list's own selection fill would be a second mark.
        .background(SelectionFillRemover())
        .environment(\.defaultMinListRowHeight, 32)
        .padding(.top, 56)
        .padding(.horizontal, 16)
        .frame(width: Print.sidebar)
        .frame(maxHeight: .infinity)
        .background(Print.bgRaised)
        .overlay(alignment: .trailing) { Rectangle().fill(Print.line).frame(width: 1) }
    }

    private var selection: Binding<Page?> {
        Binding(get: { model.page }, set: { if let page = $0 { model.page = page } })
    }

    /// A group's name: small caps over a brass hairline, like a section of the page.
    private func header(_ title: Text) -> some View {
        title
            .font(Print.smallCaps(12))
            .tracking(12 * 0.12 * Print.scale)
            .foregroundStyle(Print.textSecondary)
            .padding(.leading, 24)
            .padding(.top, 16)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Print.brass).opacity(0.4).frame(height: 1).padding(.top, 4) }
    }

    private func row(_ page: Page, count: String? = nil, @ViewBuilder label: () -> Text) -> some View {
        SidebarRow(current: model.page == page, label: label(), count: count)
            .tag(page)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

/// A sidebar entry: Garamond 16; the current page in the text colour with ✦ in brass before it,
/// the others secondary, brass on hover.
private struct SidebarRow: View {
    let current: Bool
    let label: Text
    let count: String?
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: current ? "✦" : "")
                .font(Print.text(16))
                .foregroundStyle(Print.brass)
                .frame(width: 16, alignment: .leading)
                .accessibilityHidden(true)
            // The list sets its own font on its rows: each text names its face itself.
            label
                .font(Print.text(16))
                .lineLimit(1)
                .foregroundStyle(hovering ? Print.brass : current ? Print.textPrimary : Print.textSecondary)
            Spacer(minLength: 0)
            if let count {
                Text(verbatim: count)
                    .font(Print.mono())
                    .foregroundStyle(Print.textSecondary)
            }
        }
        .frame(minHeight: 32)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Print.hover, value: hovering)
    }
}

/// Turns off the selection fill of the sidebar's list (its NSTableView), keeping the selection,
/// the arrow keys and VoiceOver. SwiftUI has no modifier for it; the table is found by walking the
/// window's views for the one inside the sidebar's width.
private struct SelectionFillRemover: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Finder() }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { (nsView as? Finder)?.apply() }
    }

    private final class Finder: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { self.apply() }
        }

        func apply() {
            guard let root = window?.contentView else { return }
            for table in Self.tables(in: root) where table.convert(table.bounds, to: nil).minX < Print.sidebar {
                table.selectionHighlightStyle = .none
            }
        }

        private static func tables(in view: NSView) -> [NSTableView] {
            (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
        }
    }
}

// MARK: - Status bar

/// Readiness, or the last error or notice (one line, no modal), and the version.
private struct StatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: "●")
                // No game yet is the first step, not a fault: a neutral dot.
                .foregroundStyle(model.activeGame == nil && model.errorMessage == nil ? Print.textSecondary
                                 : dotOK ? Print.ok : Print.danger)
                .accessibilityHidden(true)
            message
                .foregroundStyle(model.errorMessage != nil ? Print.danger : Print.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if model.errorMessage != nil || model.notice != nil {
                Button("close") {
                    if model.errorMessage != nil { model.errorMessage = nil } else { model.notice = nil }
                }
                .buttonStyle(TextActionStyle(font: Print.mono()))
            }
            Spacer(minLength: 16)
            Button { model.page = .about } label: { Text(verbatim: Self.appVersion) }
                .buttonStyle(TextActionStyle(font: Print.mono(), color: Print.textSecondary))
                .help(Text("About Hunter's Lantern"))
        }
        .font(Print.mono())
        .padding(.horizontal, 16)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .background(Print.bgSunken)
        .overlay(alignment: .top) { Rectangle().fill(Print.line).frame(height: 1) }
    }

    @ViewBuilder
    private var message: some View {
        if let error = model.errorMessage {
            Text(verbatim: error).help(Text(verbatim: error))
        } else if let notice = model.notice {
            Text(verbatim: notice).help(Text(verbatim: notice))
        } else {
            readiness
        }
    }

    private var dotOK: Bool {
        if model.errorMessage != nil { return false }
        if model.notice != nil { return true }
        guard case .success = model.runtime, let game = model.activeGame else { return false }
        if let result = model.lastResult, HomeView.failure(result.outcome) != nil, model.phase == nil { return false }
        return game.check.ok
    }

    private var readiness: Text {
        if case .failure = model.runtime { return Text("Game runtime missing") }
        guard let game = model.activeGame else { return Text("No game folder") }
        if model.phase == .running { return Text("Game running") }
        if model.phase != nil { return Text("Preparing") }
        if !game.check.ok { return Text("Check failed") }
        if let result = model.lastResult, case .crashed = result.outcome { return Text("Last hunt crashed") }
        if let result = model.lastResult, HomeView.failure(result.outcome) != nil { return Text("Last run failed") }
        return Text("Ready")
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

// MARK: - The facts

/// What the sidebar and the overview read from disk: the last runs (their logs), the characters
/// of the active save root, the mod library's size. Read off the main thread.
struct LibraryFacts: Equatable, Sendable {
    var sessions: [GameProcess.Session] = []
    /// Played longest first.
    var characters: [SaveLocation.Character] = []
    var modsTotal = 0

    @MainActor
    static func read(_ model: AppModel) async -> LibraryFacts {
        let dirs = model.dirs
        let profile = model.activeProfile
        let title = model.activeGame?.check.title
        return await Task.detached(priority: .userInitiated) {
            var facts = LibraryFacts()
            facts.sessions = GameProcess.sessions(logsDir: dirs.logsDir, limit: 2)
            // The save root, as SavesModel and AppModel.play() use it.
            let root = profile.ownSaves ? dirs.profileUserDir(profile.id) : dirs.userDir
            let locations = SaveRoot.find(userRoot: root)
            let characters = (locations.first { $0.titleID == title } ?? locations.first)?.characters() ?? []
            facts.characters = characters.sorted { $0.playtime > $1.playtime }
            facts.modsTotal = ModLibrary(dir: dirs.modsDir).mods().count
            return facts
        }.value
    }
}

// MARK: - Menu and window

/// The Go menu: every page, with shortcuts; About replaces the app menu's standard item.
struct GoCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Hunter's Lantern") { model.page = .about }
        }
        // The launcher-wide settings (window, controller, language, network) are Advanced; the
        // profile's own are Graphics.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.page = .advanced }
                .keyboardShortcut(",")
        }
        CommandMenu("Go") {
            Button("Overview") { model.page = .home }.keyboardShortcut("0")
            Divider()
            Button("Game folder") { model.page = .game }.keyboardShortcut("1")
            Divider()
            Button("Profiles") { model.page = .profiles }.keyboardShortcut("2")
            Button("Graphics") { model.page = .graphics }.keyboardShortcut("3")
            Button("Mods") { model.page = .mods }.keyboardShortcut("4")
            Button("Patches") { model.page = .patches }.keyboardShortcut("5")
            Divider()
            Button("Saves") { model.page = .saves }.keyboardShortcut("6")
            Button("Settings") { model.page = .advanced }.keyboardShortcut("7")
            Button("Diagnostics") { model.page = .diagnostics }.keyboardShortcut("8")
            Divider()
            Button("Begin the Hunt") { model.play() }
                .keyboardShortcut("r")
                .disabled(!model.canPlay)
        }
    }
}

/// The window's AppKit side: a transparent title bar, moved by its background.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ConfiguringView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ConfiguringView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = NSColor(Print.bgBase)
        }
    }
}
