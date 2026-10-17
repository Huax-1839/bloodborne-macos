// SPDX-License-Identifier: GPL-2.0-or-later
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

    var symbol: String {
        switch self {
        case .home: "house"
        case .game: "opticaldisc"
        case .profiles: "square.stack"
        case .graphics: "display"
        case .mods: "puzzlepiece.extension"
        case .patches: "wrench.and.screwdriver"
        case .saves: "externaldrive.badge.timemachine"
        case .advanced: "gearshape.2"
        case .diagnostics: "stethoscope"
        case .about: "info.circle"
        }
    }
}

/// The window: a sidebar of pages and the page.
struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $model.page) { page in
                Label(page.title, systemImage: page.symbol)
                    .tag(page)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .top) { sidebarHeader }
        } detail: {
            detail
                .safeAreaInset(edge: .top, spacing: 0) { noticeBanner }
        }
        .frame(minWidth: 960, minHeight: 600)
        .sheet(isPresented: firstRunShown) { FirstRunView() }
        .alert("Something went wrong", isPresented: errorShown) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// The first-run assistant until it was finished once (not during snapshots and tests).
    private var firstRunShown: Binding<Bool> {
        Binding(get: { !model.state.firstRunDone && ProcessInfo.processInfo.environment["LANTERN_SNAPSHOT"] == nil
                       && ProcessInfo.processInfo.environment["LANTERN_AUTOPLAY"] == nil },
                set: { if !$0 { model.state.firstRunDone = true } })
    }

    @ViewBuilder
    private var detail: some View {
        switch model.page {
        case .home: HomeView(page: $model.page)
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

    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "flame.fill")
                .foregroundStyle(Theme.amber)
                .shadow(color: Theme.amber.opacity(0.6), radius: 6)
            Text("Hunter's Lantern")
                .font(.display(.title3))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var noticeBanner: some View {
        if let notice = model.notice {
            HStack(spacing: 10) {
                Image(systemName: "info.circle.fill").foregroundStyle(Theme.amber)
                Text(notice)
                Spacer()
                Button {
                    model.notice = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}
