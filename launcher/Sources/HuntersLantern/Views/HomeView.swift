// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import LanternCore
import SwiftUI

/// The window (docs/LAUNCHER_DESIGN.md): on the left the game, a register of its last hunt,
/// hunter and backups, and the main action; on the right the pre-launch settings as register
/// entries; at the bottom the status bar. The other pages open as sheets (RootView).
struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var facts = HomeFacts()
    @State private var power = PowerConditions.current()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                main
                    .frame(width: 576)
                settings
            }
            statusBar
        }
        .frame(width: Print.window.width, height: Print.window.height)
        .background(Print.bgBase)
        .foregroundStyle(Print.textPrimary)
        .font(Print.text())
        .task(id: factsKey) { facts = await HomeFacts.read(model) }
        .task {
            // Battery, Low Power Mode and heat change while the launcher is open.
            while !Task.isCancelled {
                power = PowerConditions.current()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    /// What the register depends on: read again after a launch and when the profile changes.
    private var factsKey: String {
        "\(model.state.activeProfile)|\(model.activeGame?.id ?? "")|\(model.phase == nil)|\(model.page == .home)"
    }

    private var locked: Bool { model.isBusy }

    // MARK: Left: the game and the main action

    private var main: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Every title the game check accepts is Bloodborne (a retail ID with update 1.09).
            Text(verbatim: model.activeGame == nil ? "Hunter's Lantern" : "Bloodborne")
                .font(Print.display(64))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.top, 16)
            subtitle
                .font(Print.smallCaps())
                .tracking(14 * 0.12)
                .foregroundStyle(Print.textSecondary)
                .padding(.top, 8)
            OrnamentRule()
                .padding(.top, 24)
            if model.activeGame != nil {
                register
                    .padding(.top, 24)
            }
            Spacer(minLength: 0)
            errorLine
            Button(action: model.play) { mainLabel }
                .buttonStyle(MainActionStyle())
                .disabled(!canPlay)
                .keyboardShortcut(.defaultAction)
            hintLine
                .padding(.top, 12)
        }
        .padding(Print.inset)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var subtitle: Text {
        guard let game = model.activeGame else { return Text("No game set up yet") }
        return game.check.ok
            ? Text("\(game.check.title) · version \(game.check.version) · checked")
            : Text("\(game.check.title) · version \(game.check.version) · check failed")
    }

    private var register: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { model.page = .diagnostics } label: {
                RegisterLine(label: Text("Last hunt")) { lastHunt }
            }
            .help(Text("Logs and the last crash"))
            Button { model.page = .saves } label: {
                RegisterLine(label: Text("Hunter")) { hunter }
            }
            .help(Text("Saved data"))
            Button { model.page = .saves } label: {
                RegisterLine(label: Text("Backups")) { backups }
            }
            .help(Text("Saved data"))
        }
        .buttonStyle(RegisterLinkStyle())
    }

    private var lastHunt: Text {
        guard let session = facts.lastSession else { return Text("none yet") }
        let when = HomeFacts.relative(session.start)
        guard let duration = HomeFacts.duration(session.duration) else { return Text(verbatim: when) }
        return Text(verbatim: "\(when) — \(duration)")
    }

    private var hunter: Text {
        guard let character = facts.character else { return Text("none yet") }
        let played = HomeFacts.duration(TimeInterval(character.playtime)) ?? ""
        let others = facts.characterCount - 1
        let name = character.name.isEmpty ? Text("Level \(character.level)") : Text("\(character.name), level \(character.level)")
        let line = Text("\(name) · \(played)")
        return others > 0 ? Text("\(line) · +\(others)") : line
    }

    private var backups: Text {
        guard let newest = facts.newestBackup else { return Text("none yet") }
        return Text("last \(HomeFacts.relative(newest)) · \(facts.backupCount) kept")
    }

    private var canPlay: Bool {
        guard model.activeGame != nil, !model.isBusy, case .success = model.runtime else { return false }
        return true
    }

    @ViewBuilder
    private var mainLabel: some View {
        switch model.phase {
        case .running: Text("The hunt is on…")
        case .some: Text("Preparing the hunt…")
        case nil: Text("Begin the Hunt")
        }
    }

    /// One line in the danger colour above the main action, no modal (the most important first).
    @ViewBuilder
    private var errorLine: some View {
        if case .failure(let error) = model.runtime {
            ErrorLine(text: Text("The game runtime is missing, so the game cannot start."), detail: error.localizedDescription)
        } else if let game = model.activeGame, !game.check.ok {
            ErrorLine(text: Text(verbatim: GameCheckText.problem(game.check)), detail: GameCheckText.problem(game.check)) {
                Button("check again") { model.page = .game }
            }
        } else if let result = model.lastResult, let text = Self.failure(result.outcome) {
            ErrorLine(text: text, detail: result.logTail) {
                if let log = result.log {
                    Button("log") { NSWorkspace.shared.open(log) }
                }
                Button("close") { model.lastResult = nil }
            }
        } else if model.page == .home, let message = model.errorMessage {
            ErrorLine(text: Text(verbatim: message), detail: message) {
                Button("close") { model.errorMessage = nil }
            }
        }
    }

    private static func failure(_ outcome: GameOutcome) -> Text? {
        switch outcome {
        case .crashed(let signal): Text("The game crashed (\(signalName(signal))).")
        case .failed(let status): Text("The game failed (exit status \(Int(status))).")
        case .finished, .restartRequested, .cancelled: nil
        }
    }

    /// One line in the secondary colour under the main action.
    @ViewBuilder
    private var hintLine: some View {
        if let phase = model.phase {
            HintLine(text: Self.phaseText(phase)) {
                Button("stop") { model.stop() }
            }
        } else if let notice = model.notice {
            HintLine(text: Text(verbatim: notice)) {
                Button("close") { model.notice = nil }
            }
        } else if model.activeGame == nil {
            HintLine(text: Text("Choose the folder of your copy under “Game” on the right."))
        } else if power.onBattery {
            HintLine(text: Text("On battery power the game runs slower. Plug in the charger."))
        } else if power.lowPowerMode {
            HintLine(text: Text("Low Power Mode is on and lowers the frame rate."))
        } else if power.hot {
            HintLine(text: Text("The Mac is hot and slows the game down. Let it cool down first."))
        } else {
            HintLine(text: Text("Your saves are backed up before every start."))
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

    // MARK: Right: the settings column

    private var settings: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Print.groupGap) {
                profileGroup
                displayGroup
                gameGroup
            }
            .padding(.top, Print.inset)
            .padding(.leading, 32)
            .padding(.trailing, Print.inset)
            .padding(.bottom, Print.inset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Print.bgRaised)
        .overlay(alignment: .leading) { Rectangle().fill(Print.line).frame(width: 1) }
    }

    private var profileGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading("Profile") {
                Button("manage") { model.page = .profiles }
                    .buttonStyle(TextActionStyle())
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.profiles.all.filter(\.builtin) + model.profiles.custom) { profile in
                    Button {
                        model.state.activeProfile = profile.id
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: profile.name).lineLimit(1)
                            Leader()
                            profileNote(profile)
                                .font(Print.text(14))
                                .foregroundStyle(Print.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(ChoiceLineStyle(chosen: profile.id == model.activeProfile.id))
                    .accessibilityAddTraits(profile.id == model.activeProfile.id ? .isSelected : [])
                }
            }
            .disabled(locked)
        }
    }

    private func profileNote(_ profile: Profile) -> Text {
        if profile.id == model.hardware.suggestedProfile.id { return Text("recommended") }
        if profile.unmeasured { return Text("unmeasured") }
        return profile.builtin ? Text("built-in") : Text("own")
    }

    private var displayGroup: some View {
        let profile = model.activeProfile
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeading("Display") {
                Button("more") { model.page = .graphics }
                    .buttonStyle(TextActionStyle())
            }
            Group {
                RegisterLine(label: Text("Renderer"), labelSize: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        ForEach(RendererChoice.allCases, id: \.self) { choice in
                            Button { edit { $0.renderer = choice } } label: { Self.word(choice) }
                                .buttonStyle(ChoiceWordStyle(chosen: profile.renderer == choice))
                                .accessibilityAddTraits(profile.renderer == choice ? .isSelected : [])
                        }
                    }
                }
                RegisterLine(label: Text("Frame rate"), labelSize: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        ForEach(FrameRate.allCases, id: \.self) { rate in
                            Button { edit { $0.frameRate = rate } } label: { Self.word(rate) }
                                .buttonStyle(ChoiceWordStyle(chosen: profile.frameRate == rate))
                                .accessibilityAddTraits(profile.frameRate == rate ? .isSelected : [])
                        }
                    }
                }
            }
            .disabled(locked || profile.builtin)
            if profile.builtin && !locked {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Built-in profiles stay as they are.")
                        .font(Print.text(14))
                        .foregroundStyle(Print.textSecondary)
                    Button("copy to change") { model.duplicateProfile(profile) }
                        .buttonStyle(TextActionStyle())
                }
            }
        }
    }

    /// Changes the active profile (a built-in one is read-only, as on the Graphics page).
    private func edit(_ change: (inout Profile) -> Void) {
        var profile = model.activeProfile
        guard !profile.builtin, !locked else { return }
        change(&profile)
        model.saveProfile(profile)
    }

    private static func word(_ choice: RendererChoice) -> Text {
        switch choice {
        case .automatic: Text("auto")
        case .metal: Text(verbatim: "Metal")
        case .vulkan: Text(verbatim: "Vulkan")
        }
    }

    private static func word(_ rate: FrameRate) -> Text {
        switch rate {
        case .fps30: Text(verbatim: "30")
        case .fps60: Text(verbatim: "60")
        case .fps90: Text(verbatim: "90")
        case .uncapped: Text("free")
        }
    }

    private var gameGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading("Game")
            VStack(alignment: .leading, spacing: 4) {
                RegisterLine(label: Text("Game folder"), labelSize: 14) {
                    Button(model.activeGame == nil ? "choose" : "change") { model.page = .game }
                        .buttonStyle(TextActionStyle())
                        .disabled(locked)
                }
                if let game = model.activeGame {
                    let path = (game.path.path as NSString).abbreviatingWithTildeInPath
                    Text(verbatim: path)
                        .font(Print.mono())
                        .foregroundStyle(locked ? Print.textMuted : Print.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(Text(verbatim: path))
                } else {
                    Text("no folder chosen")
                        .font(Print.mono())
                        .foregroundStyle(Print.textMuted)
                }
            }
            RegisterLine(label: Text("Mods"), labelSize: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    modsValue
                        .font(Print.text(14))
                        .foregroundStyle(locked ? Print.textMuted : Print.textPrimary)
                    Button("manage") { model.page = .mods }
                        .buttonStyle(TextActionStyle())
                }
            }
            .padding(.top, 8)
            RegisterLine(label: Text("Patches"), labelSize: 14) {
                Button("manage") { model.page = .patches }
                    .buttonStyle(TextActionStyle())
            }
        }
    }

    private var modsValue: Text {
        let on = model.activeProfile.mods?.count ?? 0
        guard facts.modsTotal > 0 else { return Text("none") }
        return Text("\(on) of \(facts.modsTotal) on")
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text(verbatim: "●")
                .foregroundStyle(statusOK ? Print.ok : Print.danger)
                .accessibilityHidden(true)
            statusText
                .foregroundStyle(Print.textSecondary)
            Spacer()
            Button { model.page = .about } label: {
                Text(verbatim: "Hunter's Lantern \(Self.appVersion)")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Print.textMuted)
            .help(Text("About Hunter's Lantern"))
        }
        .font(Print.mono())
        .padding(.horizontal, 16)
        .frame(height: 32)
        .background(Print.bgSunken)
        .overlay(alignment: .top) { Rectangle().fill(Print.line).frame(height: 1) }
    }

    private var statusOK: Bool {
        guard case .success = model.runtime, let game = model.activeGame else { return false }
        if let result = model.lastResult, Self.failure(result.outcome) != nil, model.phase == nil { return false }
        return game.check.ok
    }

    private var statusText: Text {
        if case .failure = model.runtime { return Text("Game runtime missing") }
        guard let game = model.activeGame else { return Text("No game folder") }
        if model.phase == .running { return Text("Game running") }
        if model.phase != nil { return Text("Preparing") }
        if !game.check.ok { return Text("Check failed") }
        if let result = model.lastResult, Self.failure(result.outcome) != nil { return Text("Last run failed") }
        return Text("Ready · game checked")
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

// MARK: - Lines under and over the main action

/// The error line: danger colour, one line (the whole text as a tooltip), text actions at its end.
private struct ErrorLine<Actions: View>: View {
    let text: Text
    let detail: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("✦ \(text)")
                .foregroundStyle(Print.danger)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(Text(verbatim: detail))
            Spacer(minLength: 0)
            actions
                .buttonStyle(TextActionStyle())
        }
        .font(Print.text(14))
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
    }
}

extension ErrorLine where Actions == EmptyView {
    init(text: Text, detail: String) {
        self.init(text: text, detail: detail) { EmptyView() }
    }
}

/// The hint line: secondary colour, one line, text actions at its end.
private struct HintLine<Actions: View>: View {
    let text: Text
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            text
                .foregroundStyle(Print.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            actions
                .buttonStyle(TextActionStyle())
        }
        .font(Print.text(14))
    }
}

extension HintLine where Actions == EmptyView {
    init(text: Text) {
        self.init(text: text) { EmptyView() }
    }
}

// MARK: - The register's facts

/// What the home page reads from disk: the last run (its log), the characters of the active save
/// root, its backups, the mod library's size. Read off the main thread.
struct HomeFacts: Equatable, Sendable {
    var lastSession: GameProcess.Session?
    /// The character played longest.
    var character: SaveLocation.Character?
    var characterCount = 0
    var newestBackup: Date?
    var backupCount = 0
    var modsTotal = 0

    @MainActor
    static func read(_ model: AppModel) async -> HomeFacts {
        let dirs = model.dirs
        let profile = model.activeProfile
        let title = model.activeGame?.check.title
        return await Task.detached(priority: .userInitiated) {
            var facts = HomeFacts()
            facts.lastSession = GameProcess.lastSession(logsDir: dirs.logsDir)
            // The save root and its backup history, as SavesModel and AppModel.play() use them.
            let root = profile.ownSaves ? dirs.profileUserDir(profile.id) : dirs.userDir
            let locations = SaveRoot.find(userRoot: root)
            let characters = (locations.first { $0.titleID == title } ?? locations.first)?.characters() ?? []
            facts.character = characters.max { $0.playtime < $1.playtime }
            facts.characterCount = characters.count
            let store = BackupStore(dir: dirs.backupsDir.appendingPathComponent(root.lastPathComponent))
            let backups = store.list()
            facts.newestBackup = backups.map(\.date).max()
            facts.backupCount = backups.count
            facts.modsTotal = ModLibrary(dir: dirs.modsDir).mods().count
            return facts
        }.value
    }

    /// "Today, 17:18" (relative day names where the locale has them).
    static func relative(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }

    /// "2 hr, 14 min"; nil under a minute.
    static func duration(_ seconds: TimeInterval) -> String? {
        guard seconds >= 60 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        if seconds >= 36000 { formatter.allowedUnits = [.hour] }
        return formatter.string(from: seconds)
    }
}
