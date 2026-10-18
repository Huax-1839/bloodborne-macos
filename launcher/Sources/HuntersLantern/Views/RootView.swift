// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case home, game, profiles, graphics, mods, patches, saves, advanced, diagnostics, about

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .home: "Home"
        case .game: "Game"
        case .profiles: "Profiles"
        case .graphics: "Graphics"
        case .mods: "Mods"
        case .patches: "Patches"
        case .saves: "Saves"
        case .advanced: "Advanced"
        case .diagnostics: "Diagnostics"
        case .about: "About"
        }
    }
}

/// The window: the home page, fixed at 960 × 600 (docs/LAUNCHER_DESIGN.md); every other page is
/// a sheet over it, opened from the home page's text actions or the Go menu.
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var appeared = false
    /// The transparent title bar's height: SwiftUI adds it to the window around the content, so
    /// the content asks for that much less and reaches under the title bar (the window stays
    /// 960 × 600 in all).
    @State private var titleBar: CGFloat = 0

    var body: some View {
        HomeView()
            .frame(width: Print.window.width, height: Print.window.height - titleBar, alignment: .bottom)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { titleBar = proxy.safeAreaInsets.top }
                        .onChange(of: proxy.safeAreaInsets.top) { titleBar = proxy.safeAreaInsets.top }
                }
            }
            .sheet(item: sheetPage) { page in
                PageSheet(page: page)
                    .environmentObject(model)
            }
            .background(WindowConfigurator())
            .background {
                // A second sheet modifier on its own view: the first-run assistant.
                Color.clear.sheet(isPresented: firstRunShown) { FirstRunView().environmentObject(model) }
            }
            .opacity(appeared ? 1 : 0)
            .onAppear { withAnimation(Print.appear) { appeared = true } }
    }

    /// Every page but home is a sheet.
    private var sheetPage: Binding<Page?> {
        Binding(get: { model.page == .home ? nil : model.page },
                set: { model.page = $0 ?? .home })
    }

    /// The first-run assistant until it was finished once (not during snapshots and tests).
    private var firstRunShown: Binding<Bool> {
        Binding(get: { !model.state.firstRunDone && ProcessInfo.processInfo.environment["LANTERN_SNAPSHOT"] == nil
                       && ProcessInfo.processInfo.environment["LANTERN_AUTOPLAY"] == nil },
                set: { if !$0 { model.state.firstRunDone = true } })
    }
}

/// A page as a sheet over the home page, with its errors as an alert (the home page shows them
/// inline, but it is covered here).
private struct PageSheet: View {
    @EnvironmentObject private var model: AppModel
    let page: Page

    var body: some View {
        content
            .frame(width: 880, height: 520)
            .environment(\.closePage) { model.page = .home }
            .alert("Something went wrong", isPresented: errorShown) {
                Button("OK") { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .home: EmptyView()
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

    private var errorShown: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}

private struct ClosePageKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    /// Closes the page sheet (PageContainer's "close" action); nil outside a sheet.
    var closePage: (() -> Void)? {
        get { self[ClosePageKey.self] }
        set { self[ClosePageKey.self] = newValue }
    }
}

/// The Go menu: every page, with shortcuts; About replaces the app menu's standard item.
struct GoCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Hunter's Lantern") { model.page = .about }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Graphics…") { model.page = .graphics }
                .keyboardShortcut(",")
        }
        CommandMenu("Go") {
            Button("Game") { model.page = .game }.keyboardShortcut("1")
            Button("Profiles") { model.page = .profiles }.keyboardShortcut("2")
            Button("Mods") { model.page = .mods }.keyboardShortcut("3")
            Button("Patches") { model.page = .patches }.keyboardShortcut("4")
            Button("Saves") { model.page = .saves }.keyboardShortcut("5")
            Divider()
            Button("Advanced") { model.page = .advanced }.keyboardShortcut("6")
            Button("Diagnostics") { model.page = .diagnostics }.keyboardShortcut("7")
        }
    }
}

/// The window's AppKit side: moved by its background, no full screen and no zoom (the layout is
/// fixed at 960 × 600).
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
            window.collectionBehavior.insert(.fullScreenNone)
            window.standardWindowButton(.zoomButton)?.isEnabled = false
        }
    }
}
