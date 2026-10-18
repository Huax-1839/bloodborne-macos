// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import LanternCore
import SwiftUI

/// The overview (docs/LAUNCHER_DESIGN.md): the game's own artwork as a plate (sce_sys/pic1.png,
/// read at run time, D17), the profile and the main action under it, and two short lists at the
/// bottom: the hunters of the save and the last hunts.
struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    let facts: LibraryFacts
    @State private var artwork: NSImage?
    @State private var power = PowerConditions.current()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            plate
            band
                .padding(.horizontal, Print.inset)
                .padding(.top, 32)
            line
                .padding(.horizontal, Print.inset)
                .padding(.top, 12)
            Spacer(minLength: 0)
            lists
                .padding([.horizontal, .bottom], Print.inset)
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

    private var locked: Bool { model.isBusy }

    // MARK: The plate

    /// The artwork carries the game's name; without it (no game, no pic1) the name is set in type.
    private var plate: some View {
        ZStack(alignment: .bottomLeading) {
            Print.bgSunken
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .accessibilityLabel(Text(verbatim: "Bloodborne"))
            } else {
                Text(verbatim: model.activeGame == nil ? "Hunter's Lantern" : "Bloodborne")
                    .font(Print.display(64))
                    .padding(Print.inset)
            }
        }
        .frame(height: 280)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(alignment: .bottom) { Rectangle().fill(Print.line).frame(height: 1) }
    }

    private func loadArtwork() async {
        guard let game = model.activeGame else {
            artwork = nil
            return
        }
        artwork = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: game.backgroundImage) }.value
    }

    // MARK: The band: game, profile, main action

    private var band: some View {
        HStack(alignment: .bottom, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                meta
                    .font(Print.smallCaps())
                    .tracking(14 * 0.12)
                    .foregroundStyle(Print.textSecondary)
                if model.activeGame != nil { profileMenu }
            }
            Spacer(minLength: 0)
            Button(action: model.play) { mainLabel }
                .buttonStyle(MainActionStyle())
                .frame(width: 240)
                .disabled(!canPlay)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var meta: Text {
        guard let game = model.activeGame else { return Text("No game set up yet") }
        return Text("\(game.check.title) · version \(game.check.version)")
    }

    private var profileMenu: some View {
        Menu {
            Picker(selection: $model.state.activeProfile) {
                ForEach(model.profiles.all.filter(\.builtin) + model.profiles.custom) { profile in
                    Text(verbatim: profile.name).tag(profile.id)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            Divider()
            Button("Manage profiles…") { model.page = .profiles }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: model.activeProfile.name)
                Text(verbatim: "▾").foregroundStyle(Print.brass)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(TextActionStyle(size: 16))
        .fixedSize()
        .disabled(locked)
        .help(Text("Profile"))
    }

    private var canPlay: Bool {
        guard model.activeGame != nil, !model.isBusy, case .success = model.runtime else { return false }
        return true
    }

    @ViewBuilder
    private var mainLabel: some View {
        switch model.phase {
        case .running: Text("The hunt is on…")
        case .some: Text("Preparing…")
        case nil: Text("Begin the Hunt")
        }
    }

    // MARK: The line under the band

    /// An error in the danger colour, else a hint in the secondary colour; mostly nothing.
    @ViewBuilder
    private var line: some View {
        if case .failure(let error) = model.runtime {
            Line(text: Text("The game runtime is missing, so the game cannot start."), color: Print.danger)
                .help(Text(verbatim: error.localizedDescription))
        } else if let game = model.activeGame, !game.check.ok {
            Line(text: Text(verbatim: GameCheckText.problem(game.check)), color: Print.danger) {
                Button("check again") { model.page = .game }
            }
            .help(Text(verbatim: GameCheckText.problem(game.check)))
        } else if let result = model.lastResult, let text = Self.failure(result.outcome) {
            Line(text: text, color: Print.danger) {
                if let log = result.log {
                    Button("log") { NSWorkspace.shared.open(log) }
                }
                Button("close") { model.lastResult = nil }
            }
        } else if let phase = model.phase {
            Line(text: Self.phaseText(phase), color: Print.textSecondary) {
                Button("stop") { model.stop() }
            }
        } else if model.activeGame == nil {
            Line(text: Text("Choose your copy under “Game folder” in the sidebar."), color: Print.textSecondary)
        } else if power.onBattery {
            Line(text: Text("On battery power the game runs slower. Plug in the charger."), color: Print.textSecondary)
        } else if power.lowPowerMode {
            Line(text: Text("Low Power Mode is on and lowers the frame rate."), color: Print.textSecondary)
        } else if power.hot {
            Line(text: Text("The Mac is hot and slows the game down. Let it cool down first."), color: Print.textSecondary)
        }
    }

    static func failure(_ outcome: GameOutcome) -> Text? {
        switch outcome {
        case .crashed(let signal): Text("The game crashed (\(signalName(signal))).")
        case .failed(let status): Text("The game failed (exit status \(Int(status))).")
        case .finished, .restartRequested, .cancelled: nil
        }
    }

    private static func phaseText(_ phase: LaunchPhase) -> Text {
        switch phase {
        case .checking: Text("Checking the game")
        case .backingUp: Text("Backing up saves")
        case .preparing(let script): Text("Preparing (\(script))")
        case .running: Text("The launcher waits in the background until the game ends.")
        case .restarting: Text("Restarting")
        }
    }

    // MARK: The lists

    private var lists: some View {
        HStack(alignment: .top, spacing: Print.inset) {
            ListSection(title: "Hunters") {
                if facts.characters.isEmpty {
                    EmptyRow()
                } else {
                    ForEach(facts.characters.prefix(2)) { character in
                        Button { model.page = .saves } label: {
                            ListRow(lead: "\(character.slot + 1)",
                                    label: Text("Level \(character.level)"),
                                    trail: Self.clock(TimeInterval(character.playtime)))
                        }
                    }
                }
            }
            ListSection(title: "Last hunts") {
                if facts.sessions.isEmpty {
                    EmptyRow()
                } else {
                    ForEach(facts.sessions, id: \.log) { session in
                        Button { model.page = .diagnostics } label: {
                            ListRow(lead: nil, label: Text(verbatim: Self.day(session.start)),
                                    note: crashed(session) ? Text("crashed") : nil,
                                    trail: Self.clock(session.duration))
                        }
                    }
                }
            }
        }
        .buttonStyle(RowLinkStyle())
    }

    /// The last run of this launcher session crashed or failed, and this is its log.
    private func crashed(_ session: GameProcess.Session) -> Bool {
        guard let result = model.lastResult, Self.failure(result.outcome) != nil else { return false }
        return result.log?.standardizedFileURL == session.log.standardizedFileURL
    }

    /// "2:14" (hours and minutes).
    private static func clock(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    /// "Today", "Yesterday" or the date.
    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }
}

// MARK: - Parts

/// One line under the band: its text (one line, the colour given) and text actions at its end.
private struct Line<Actions: View>: View {
    let text: Text
    let color: Color
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            text
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            actions
                .buttonStyle(TextActionStyle())
        }
        .font(Print.text(14))
    }
}

extension Line where Actions == EmptyView {
    init(text: Text, color: Color) {
        self.init(text: text, color: color) { EmptyView() }
    }
}

/// A short list: a small-caps heading over rows between rules.
private struct ListSection<Rows: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(Print.smallCaps())
                .tracking(14 * 0.12)
                .foregroundStyle(Print.textSecondary)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            rows
            Rectangle().fill(Print.line).frame(height: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A list row: an optional number, the label (brass when the row is under the pointer), an
/// optional note in the danger colour, and a figure at the end.
private struct ListRow: View {
    let lead: String?
    let label: Text
    var note: Text?
    let trail: String
    @Environment(\.rowHighlight) private var highlight

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let lead {
                Text(verbatim: lead)
                    .font(Print.mono())
                    .foregroundStyle(Print.textMuted)
                    .frame(width: 16, alignment: .leading)
            }
            label
                .foregroundStyle(highlight ? Print.brass : Print.textPrimary)
            if let note {
                Text("· \(note)")
                    .font(Print.text(14))
                    .foregroundStyle(Print.danger)
            }
            Spacer(minLength: 0)
            Text(verbatim: trail)
                .font(Print.mono())
                .foregroundStyle(Print.textSecondary)
        }
        .frame(height: 32)
        .overlay(alignment: .top) { Rectangle().fill(Print.line).frame(height: 1) }
    }
}

/// The row of an empty list.
private struct EmptyRow: View {
    var body: some View {
        Text("none yet")
            .foregroundStyle(Print.textMuted)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Print.line).frame(height: 1) }
    }
}
