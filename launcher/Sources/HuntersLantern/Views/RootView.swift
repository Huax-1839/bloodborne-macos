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
        .id(model.state.largeText)
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

/// The pages: the game first (its overview, and the game folder while there is no game); then
/// the active profile, named, as the frame of the pages that belong to it (graphics, mods,
/// patches); the launcher's own pages at the bottom (saves are shared by the profiles). The
/// current page is marked with ✦; the arrow keys move between pages.
private struct Sidebar: View {
    @EnvironmentObject private var model: AppModel
    let facts: LibraryFacts

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The game's name once there is one; before that the plate carries the app's.
            item(.home) {
                model.activeGame == nil ? Text("Overview") : Text(verbatim: "Bloodborne")
            }
            Rectangle()
                .fill(Print.brass)
                .opacity(0.4)
                .frame(height: 1)
                .padding(.vertical, 16)
                .accessibilityHidden(true)
            // Without a game the way to one comes first.
            if noGame {
                item(.game) { Text("Game folder") }
                    .padding(.bottom, 16)
            }
            Text("Profile")
                .font(Print.smallCaps(12))
                .tracking(1.2)
                .foregroundStyle(Print.textSecondary)
                .padding(.leading, 24)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            item(.profiles) { Text(verbatim: model.activeProfile.name) }
                .help(Text("All profiles"))
                .accessibilityLabel(Text("Profile: \(model.activeProfile.name)"))
            item(.graphics) { Text("Graphics") }
            item(.mods, count: facts.modsTotal > 0 ? "\(model.activeProfile.mods?.count ?? 0)/\(facts.modsTotal)" : nil) {
                Text("Mods")
            }
            item(.patches) { Text("Patches") }
            Spacer(minLength: 0)
            if !noGame { item(.game) { Text("Game folder") } }
            item(.saves, count: facts.characters.isEmpty ? nil : "\(facts.characters.count)") { Text("Saves") }
            item(.advanced) { Text("Advanced") }
            item(.diagnostics) { Text("Diagnostics") }
        }
        .onMoveCommand { direction in
            let order = pages
            guard let index = order.firstIndex(of: model.page) else { return }
            switch direction {
            case .up: model.page = order[max(index - 1, 0)]
            case .down: model.page = order[min(index + 1, order.count - 1)]
            default: break
            }
        }
        .padding(.top, 64)
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .frame(width: Print.sidebar)
        .frame(maxHeight: .infinity)
        .background(Print.bgRaised)
        .overlay(alignment: .trailing) { Rectangle().fill(Print.line).frame(width: 1) }
    }

    private var noGame: Bool { model.library.games.isEmpty }

    /// The sidebar's pages in their order, for the arrow keys.
    private var pages: [Page] {
        noGame ? [.home, .game, .profiles, .graphics, .mods, .patches, .saves, .advanced, .diagnostics]
               : [.home, .profiles, .graphics, .mods, .patches, .game, .saves, .advanced, .diagnostics]
    }

    private func item(_ page: Page, count: String? = nil, @ViewBuilder label: () -> Text) -> some View {
        Button { model.page = page } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                label()
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let count {
                    Text(verbatim: count)
                        .font(Print.mono())
                        .foregroundStyle(Print.textSecondary)
                }
            }
        }
        .buttonStyle(SidebarItemStyle(current: model.page == page))
        .accessibilityAddTraits(model.page == page ? .isSelected : [])
    }
}

// MARK: - Status bar

/// Readiness, or the last error or notice (one line, no modal), and the version.
private struct StatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: "●")
                .foregroundStyle(dotOK ? Print.ok : Print.danger)
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
            Button("Profiles") { model.page = .profiles }.keyboardShortcut("1")
            Button("Graphics") { model.page = .graphics }.keyboardShortcut("2")
            Button("Mods") { model.page = .mods }.keyboardShortcut("3")
            Button("Patches") { model.page = .patches }.keyboardShortcut("4")
            Divider()
            Button("Game folder") { model.page = .game }.keyboardShortcut("5")
            Button("Saves") { model.page = .saves }.keyboardShortcut("6")
            Button("Advanced") { model.page = .advanced }.keyboardShortcut("7")
            Button("Diagnostics") { model.page = .diagnostics }.keyboardShortcut("8")
            Divider()
            Button("Begin the Hunt") { model.play() }
                .keyboardShortcut("r")
                .disabled(model.isBusy || model.activeGame == nil)
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
