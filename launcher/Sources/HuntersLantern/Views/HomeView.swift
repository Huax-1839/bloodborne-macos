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
    @Environment(\.gameArtwork) private var artwork
    @State private var power = PowerConditions.current()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            plate
            VStack(alignment: .leading, spacing: 0) {
                band
                    .padding(.top, 32)
                line
                    .padding(.top, 12)
                Spacer(minLength: 16)
                    .frame(maxHeight: 64)
                if let result = model.lastResult, Self.failure(result.outcome) != nil {
                    // The plate gives way (down to 180) so the card fits the smallest window.
                    OutcomeCard(result: result, minutes: minutes(of: result))
                        .padding(.bottom, 24)
                } else {
                    lists
                        .padding(.bottom, Print.inset)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Print.inset)
            // A large window gets margins, not a band stretched across it.
            .frame(maxWidth: Print.column + 2 * Print.inset)
            .frame(maxWidth: .infinity)
        }
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
                Text(verbatim: model.activeGame == nil ? "Hunter’s Lantern" : "Bloodborne")
                    .font(Print.display(64))
                    .padding(Print.inset)
            }
        }
        .frame(minHeight: 180, idealHeight: 280, maxHeight: 400)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(alignment: .bottom) { Rectangle().fill(Print.line).frame(height: 1) }
    }

    // MARK: The band: game, profile, main action

    private var band: some View {
        HStack(alignment: .bottom, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                meta
                    .font(Print.smallCaps())
                    .tracking(14 * 0.12 * Print.scale)
                    .foregroundStyle(Print.textSecondary)
                if model.activeGame != nil { profileMenu }
            }
            Spacer(minLength: 0)
            Group {
                // Without a game the main action is getting one: the step that can be taken now.
                if model.activeGame == nil {
                    Button { model.page = .game } label: { Text("Add the game") }
                } else {
                    Button(action: model.play) { mainLabel }
                        .disabled(!canPlay)
                }
            }
            .buttonStyle(MainActionStyle())
            .frame(width: 240)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var meta: Text {
        guard let game = model.activeGame else { return Text("No game set up yet") }
        return Text("\(game.check.title) · version \(game.check.version)")
    }

    private var profileMenu: some View {
        Menu {
            // The resolved profile, so the check mark is right when the saved one is gone.
            Picker(selection: Binding(get: { model.activeProfile.id }, set: { model.state.activeProfile = $0 })) {
                ForEach(model.profiles.grouped) { profile in
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
                // What starts is not the shipped preset: said where the game is started.
                if model.profiles.isAdjusted(model.activeProfile.id) {
                    Text("adjusted").font(Print.text(14)).foregroundStyle(Print.brass)
                }
                Text(verbatim: "▾").foregroundStyle(Print.brass).accessibilityHidden(true)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(TextActionStyle(size: 16, marked: false))
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
        } else if let error = model.errorMessage {
            Line(text: Text(verbatim: error), color: Print.danger) {
                Button("close") { model.errorMessage = nil }
            }
            .help(Text(verbatim: error))
        } else if let phase = model.phase {
            Line(text: Self.phaseText(phase), color: Print.textSecondary) {
                Button("stop") { model.stop() }
            }
        } else if model.activeGame == nil {
            Line(text: Text("The launcher never downloads a game. Use your own copy, dumped from your console."),
                 color: Print.textSecondary)
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

    /// How long the failed run lasted, from its session in the logs.
    private func minutes(of result: LaunchResult) -> Int? {
        guard let log = result.log?.standardizedFileURL,
              let session = facts.sessions.first(where: { $0.log.standardizedFileURL == log }) else { return nil }
        return Int(session.duration) / 60
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

/// After a crash or a failed start, in the lists' place until it is closed: what happened, that
/// the saves are safe (the launch backs them up first or does not start), the game's last lines,
/// and the ways on: a report to copy, the log, the diagnostics, and Vulkan as the thing to try.
private struct OutcomeCard: View {
    @EnvironmentObject private var model: AppModel
    let result: LaunchResult
    let minutes: Int?
    @State private var copied = false

    var body: some View {
        let crashed = if case .crashed = result.outcome { true } else { false }
        PrintSection(Text(crashed ? "The hunt ended in a crash" : "The game stopped with an error").foregroundStyle(Print.danger)) {
            PrintNote(summary, color: Print.textPrimary)
            if !result.logTail.isEmpty {
                Text(verbatim: tail)
                    .font(Print.mono())
                    .foregroundStyle(Print.textSecondary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                // The thing to try, as an action: the profile's renderer becomes Vulkan, then it starts.
                if canTryVulkan {
                    Button { tryVulkan() } label: { Text("Try again with Vulkan") }
                        .buttonStyle(FrameActionStyle())
                }
                Button { copyReport() } label: { Text(copied ? "Copied" : "Copy for a bug report") }
                    .buttonStyle(FrameActionStyle())
                Group {
                    if let log = result.log {
                        Button("log") { NSWorkspace.shared.open(log) }
                    }
                    Button("diagnostics") { model.page = .diagnostics }
                    Spacer(minLength: 0)
                    Button("close") { model.lastResult = nil }
                }
                .buttonStyle(TextActionStyle())
            }
            .padding(.top, 4)
        }
        .accessibilityElement(children: .contain)
    }

    private var canTryVulkan: Bool {
        model.activeProfile.renderer != .vulkan && RendererChoice.automaticResolved == .metal
    }

    private func tryVulkan() {
        var profile = model.activeProfile
        profile.renderer = .vulkan
        model.saveProfile(profile)
        model.lastResult = nil
        model.play()
    }

    /// Plain words first; the signal is in the log lines and the report.
    private var summary: Text {
        let what: Text = if case .crashed = result.outcome { Text("The game crashed.") } else {
            HomeView.failure(result.outcome) ?? Text(verbatim: "")
        }
        let when = minutes.map { $0 < 1 ? Text("It ran for less than a minute.") : Text("It ran for \($0) min.") }
        let safe = Text("Your saves were backed up before the start.")
        return [what, when, safe].compactMap { $0 }.reduce(Text(verbatim: "")) { $0 + $1 + Text(verbatim: " ") }
    }

    /// The last lines, at most three.
    private var tail: String {
        result.logTail.split(separator: "\n").suffix(3).joined(separator: "\n")
    }

    private func copyReport() {
        let info = SystemInfo.text(appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
                                   hardware: model.hardware, game: model.activeGame, profile: model.activeProfile)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info + "\n\nLast lines:\n" + result.logTail, forType: .string)
        copied = true
        AccessibilityNotification.Announcement(String(localized: "Copied")).post()
        Task { try? await Task.sleep(for: .seconds(2.5)); copied = false }
    }
}

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
                .tracking(14 * 0.12 * Print.scale)
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
                    .foregroundStyle(Print.textSecondary)
                    .frame(minWidth: 16, alignment: .leading)
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
            .foregroundStyle(Print.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Print.line).frame(height: 1) }
    }
}
