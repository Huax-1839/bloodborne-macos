// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import LanternCore
import SwiftUI

/// Home: the game's own artwork (read at run time, D17), Play, the profile and the status cards.
struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var page: Page
    @State private var background: NSImage?
    @State private var cover: NSImage?
    @State private var power = PowerConditions.current()

    var body: some View {
        ZStack {
            backdrop
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Spacer(minLength: 0)
                        header
                        if model.activeGame != nil { actions }
                        if model.phase == nil { powerHints }
                        cards
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .bottomLeading)
                }
            }
        }
        .task(id: model.activeGame?.id) { await loadArtwork() }
        .task {
            // Battery, Low Power Mode and heat change while the launcher is open.
            while !Task.isCancelled {
                power = PowerConditions.current()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    // MARK: Artwork

    @ViewBuilder
    private var backdrop: some View {
        if let background {
            GeometryReader { geometry in
                Image(nsImage: background)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            }
            .overlay {
                // Dark enough for text at the bottom and on the left, open at the top right.
                LinearGradient(stops: [.init(color: .black.opacity(0.25), location: 0),
                                       .init(color: .black.opacity(0.55), location: 0.5),
                                       .init(color: .black.opacity(0.9), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .leading, endPoint: .trailing)
            }
            .ignoresSafeArea()
        } else {
            LanternBackdrop()
        }
    }

    private func loadArtwork() async {
        guard let game = model.activeGame else {
            background = nil
            cover = nil
            return
        }
        let images = await Task.detached(priority: .userInitiated) {
            (NSImage(contentsOf: game.backgroundImage), NSImage(contentsOf: game.coverImage))
        }.value
        background = images.0
        cover = images.1
    }

    // MARK: Header and actions

    private var header: some View {
        HStack(alignment: .bottom, spacing: 20) {
            if let game = model.activeGame {
                if let cover {
                    Image(nsImage: cover)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 104, height: 104)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.15)))
                        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(game.check.title)
                        .font(.system(size: 40, weight: .semibold, design: .serif))
                        .shadow(color: .black.opacity(0.6), radius: 8)
                    Text("Version \(game.check.version)")
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hunter's Lantern")
                        .font(.system(size: 40, weight: .semibold, design: .serif))
                    Text("Bring your own copy of the game to begin. The app contains no game files.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let phase = model.phase {
            HStack(spacing: 14) {
                ProgressView().controlSize(.small)
                phaseText(phase)
                    .font(.headline)
                Spacer()
                Button("Stop") { model.stop() }
                    .controlSize(.large)
            }
            .card()
        } else {
            HStack(spacing: 16) {
                Button {
                    model.play()
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.title2.weight(.semibold))
                        .padding(.horizontal, 28)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .keyboardShortcut(.defaultAction)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Profile").font(.caption).foregroundStyle(.secondary)
                    profilePicker
                }
            }
        }
    }

    @ViewBuilder
    private var powerHints: some View {
        if power.onBattery || power.lowPowerMode || power.hot {
            VStack(alignment: .leading, spacing: 6) {
                if power.onBattery {
                    Label("On battery power the game runs slower. Plug in the charger.", systemImage: "battery.50")
                }
                if power.lowPowerMode {
                    Label("Low Power Mode is on and lowers the frame rate. Turn it off in System Settings under Battery.", systemImage: "leaf")
                }
                if power.hot {
                    Label("The Mac is hot and slows the game down. Let it cool down first.", systemImage: "thermometer.high")
                }
            }
            .font(.callout)
            .foregroundStyle(Theme.amber)
            .card()
        }
    }

    private var profilePicker: some View {
        Picker("Profile", selection: $model.state.activeProfile) {
            ForEach(model.profiles.all.filter(\.builtin)) { profileItem($0) }
            if !model.profiles.custom.isEmpty {
                Divider()
                ForEach(model.profiles.custom) { profileItem($0) }
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 240)
    }

    @ViewBuilder
    private func profileItem(_ profile: Profile) -> some View {
        let recommended = profile.id == model.hardware.suggestedProfile.id
        if profile.unmeasured && recommended {
            Text("\(profile.name) (unmeasured, recommended for this Mac)").tag(profile.id)
        } else if profile.unmeasured {
            Text("\(profile.name) (unmeasured)").tag(profile.id)
        } else if recommended {
            Text("\(profile.name) (recommended for this Mac)").tag(profile.id)
        } else {
            Text(profile.name).tag(profile.id)
        }
    }

    private func phaseText(_ phase: LaunchPhase) -> Text {
        switch phase {
        case .checking: Text("Checking the game")
        case .backingUp: Text("Backing up saves")
        case .preparing(let script): Text("Preparing (\(script))")
        case .running: Text("Running")
        case .restarting: Text("Restarting")
        }
    }

    // MARK: Cards

    private var cards: some View {
        VStack(alignment: .leading, spacing: 14) {
            if case .failure(let error) = model.runtime {
                runtimeCard(String(describing: error))
            }
            if model.activeGame == nil {
                noGameCard
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                    gameCard
                    profileCard
                }
            }
            if let result = model.lastResult {
                OutcomeCard(result: result, logsDir: model.dirs.logsDir)
            }
        }
    }

    private var noGameCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeading("Game", symbol: "opticaldisc")
            Text("No game yet")
                .font(.display(.title2))
            Text("Add your copy of the game: a ready game folder, the base game with its update, or PKG files.")
                .foregroundStyle(.secondary)
            Button("Add a game…") { page = .game }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .card()
    }

    private var gameCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeading("Game", symbol: "opticaldisc")
            if let game = model.activeGame {
                InfoRow("Title", Text(verbatim: game.check.title))
                InfoRow("Version", Text(verbatim: game.check.version))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: game.check.ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(game.check.ok ? Color.green : Color.orange)
                    Text(GameCheckText.problem(game.check))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
        }
        .card()
    }

    private var profileCard: some View {
        let profile = model.activeProfile
        return VStack(alignment: .leading, spacing: 8) {
            CardHeading("Profile", symbol: "square.stack")
            HStack {
                Text(profile.name).font(.headline)
                if profile.unmeasured { Badge("Unmeasured", tint: Theme.amber) }
            }
            InfoRow("Frame rate", Text(profile.frameRate.label))
            InfoRow("Scene size", profile.sceneSizeText)
            InfoRow("Renderer", profile.rendererText)
            if let upscaler = profile.iniValues["upscaler"] {
                InfoRow("Upscaler", UpscalerOption.label(upscaler))
            }
        }
        .card()
    }

    private func runtimeCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeading("Game runtime", symbol: "exclamationmark.triangle")
            Text("The game runtime was not found, so the game cannot start.")
            Text(message)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .card()
    }
}

/// How the last launch ended: finished, crashed, failed or stopped; the log's tail for the bad ends.
struct OutcomeCard: View {
    @EnvironmentObject private var model: AppModel
    let result: LaunchResult
    let logsDir: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CardHeading("Last run", symbol: "clock.arrow.circlepath")
                Spacer()
                Button {
                    model.lastResult = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint)
                title.font(.headline)
            }
            if showsLog, !result.logTail.isEmpty {
                ScrollView {
                    Text(result.logTail)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 170)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                if let log = result.log {
                    Button("Open log") { NSWorkspace.shared.open(log) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([log]) }
                } else {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([logsDir]) }
                }
            }
        }
        .card()
    }

    private var showsLog: Bool {
        switch result.outcome {
        case .crashed, .failed: true
        default: false
        }
    }

    private var symbol: String {
        switch result.outcome {
        case .finished, .restartRequested: "checkmark.circle.fill"
        case .crashed: "bolt.trianglebadge.exclamationmark.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "stop.circle.fill"
        }
    }

    private var tint: Color {
        switch result.outcome {
        case .finished, .restartRequested: .green
        case .crashed, .failed: .orange
        case .cancelled: .secondary
        }
    }

    private var title: Text {
        switch result.outcome {
        case .finished: Text("The game ended normally")
        case .restartRequested: Text("The game restarted")
        case .crashed(let signal): Text("The game crashed (\(signalName(signal)))")
        case .failed(let status): Text("The game failed (exit status \(Int(status)))")
        case .cancelled: Text("The game was stopped")
        }
    }
}
