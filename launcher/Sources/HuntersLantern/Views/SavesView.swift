// SPDX-License-Identifier: GPL-2.0-or-later
import LanternCore
import SwiftUI
import UniformTypeIdentifiers

/// A literal from this page's string table (Saves.xcstrings).
private func s(_ key: LocalizedStringKey) -> Text { Text(key, tableName: "Saves") }

private extension UTType {
    /// .lanternsave is a ZIP; no exported type declaration (that needs an Info.plist entry).
    static let lanternSave = UTType(filenameExtension: SaveArchive.fileExtension) ?? .zip
}

/// Saves (D11): the characters of the active profile's save, backups, export and import, and
/// taking over from a bbport checkout.
struct SavesView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var saves = SavesModel()
    @State private var pending: Pending?
    @State private var sheet: Sheet?
    @State private var deleting: BackupStore.Backup?

    /// What waits for the user's confirmation.
    enum Pending: Identifiable {
        case restore(BackupStore.Backup)
        case importSave(URL, SaveManifest)
        var id: String {
            switch self {
            case .restore(let backup): "restore-" + backup.id
            case .importSave(let url, _): "import-" + url.path
            }
        }
    }

    /// A sheet that takes some input first.
    enum Sheet: Identifiable {
        case snapshot
        case character(URL, SaveManifest)
        case migrate(RepositoryMigration)
        var id: String {
            switch self {
            case .snapshot: "snapshot"
            case .character(let url, _): "character-" + url.path
            case .migrate(let source): "migrate-" + source.folder.path
            }
        }
    }

    var body: some View {
        PageContainer(title: "Saves") {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let checkout = saves.checkout, saves.location == nil { checkoutOffer(checkout) }
                    charactersCard
                    backupsCard
                    exchangeCard
                    takeOverCard
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
                .disabled(saves.working)
            }
            .overlay(alignment: .top) {
                if saves.working {
                    ProgressView()
                        .controlSize(.small)
                        .padding(10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 6)
                }
            }
        }
        .onAppear { saves.bind(model) }
        .onChange(of: model.state.activeProfile) { saves.reload() }
        .onChange(of: model.isBusy) { saves.reload() }
        .confirmationDialog(confirmationTitle, isPresented: pendingShown, titleVisibility: .visible, presenting: pending) { item in
            switch item {
            case .restore(let backup):
                Button(role: .destructive) { saves.restore(backup) } label: { s("Restore the backup") }
            case .importSave(let url, _):
                Button(role: .destructive) { saves.importSave(url) } label: { s("Import") }
            }
            Button(role: .cancel) {} label: { s("Cancel") }
        } message: { item in
            switch item {
            case .restore:
                s("The saves as they are now are backed up first (an automatic backup), so you can undo this.")
            case .importSave(_, let manifest):
                importMessage(manifest)
            }
        }
        .confirmationDialog(deleteTitle, isPresented: deleteShown, titleVisibility: .visible, presenting: deleting) { backup in
            Button(role: .destructive) { saves.delete(backup) } label: { s("Delete") }
            Button(role: .cancel) {} label: { s("Cancel") }
        } message: { _ in
            s("This cannot be undone.")
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .snapshot:
                SnapshotSheet { saves.takeSnapshot(named: $0) }
            case .character(let url, let manifest):
                CharacterImportSheet(manifest: manifest, current: saves.characters) { saves.importCharacter(url, intoSlot: $0) }
            case .migrate(let source):
                MigrationSheet(source: source) { saves.migrate(source, includeCache: $0) }
            }
        }
    }

    // MARK: Characters

    private var charactersCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SavesHeading("Characters", symbol: "person.2")
            if model.activeProfile.ownSaves {
                s("The own saves of the profile “\(model.activeProfile.name)”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                s("The saves all profiles share.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if saves.characters.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "moon.zzz").foregroundStyle(.secondary)
                    s(saves.location == nil
                      ? "No save yet. Start the game and create a character, or import a save below."
                      : "No character in this save yet.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(saves.characters) { character in
                        if character.id != saves.characters.first?.id { Divider() }
                        characterRow(character)
                    }
                }
            }
        }
        .card()
    }

    private func characterRow(_ character: SaveLocation.Character) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: String(character.slot + 1))
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(Theme.amber)
                .frame(width: 26, height: 26)
                .background(Theme.amber.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: character.name.isEmpty ? "—" : character.name).font(.headline)
                HStack(spacing: 14) {
                    s("Level \(character.level)")
                    s("Playtime \(Self.playtime(character.playtime)) h")
                    s("\(character.echoes) Echoes")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button { exportCharacter(character) } label: { s("Export…") }
        }
        .padding(.vertical, 8)
    }

    /// Hours and minutes, h:mm.
    static func playtime(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 3600, seconds % 3600 / 60)
    }

    // MARK: Backups

    private var backupsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SavesHeading("Backups", symbol: "clock.arrow.circlepath")
            s("A backup is made automatically before each start; the last 10 are kept. Snapshots stay until you delete them. Backups share disk space with the saves until the game changes them.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if saves.backups.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "tray").foregroundStyle(.secondary)
                    s("No backups yet.").foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(saves.backups) { backup in
                        if backup.id != saves.backups.first?.id { Divider() }
                        backupRow(backup)
                    }
                }
            }
            HStack {
                Button { sheet = .snapshot } label: { s("Take snapshot…") }
                    .disabled(saves.location == nil)
                Button { saves.showBackupsInFinder() } label: { s("Show in Finder") }
                Spacer()
                s("Space used: \(ByteCountFormatter.string(fromByteCount: saves.totalSize, countStyle: .file))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private func backupRow(_ backup: BackupStore.Backup) -> some View {
        HStack(spacing: 12) {
            Image(systemName: backup.automatic ? "clock.arrow.circlepath" : "bookmark.fill")
                .foregroundStyle(backup.automatic ? Color.secondary : Theme.amber)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                if let label = backup.label, !backup.automatic {
                    Text(verbatim: label).font(.headline)
                } else {
                    s("Automatic backup").font(.headline)
                }
                HStack(spacing: 8) {
                    Text(backup.date, format: .dateTime.year().month().day().hour().minute())
                    Text(verbatim: "·")
                    Text(verbatim: ByteCountFormatter.string(fromByteCount: backup.size, countStyle: .file))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button { pending = .restore(backup) } label: { s("Restore…") }
            Button(role: .destructive) { deleting = backup } label: { s("Delete") }
        }
        .padding(.vertical, 8)
    }

    // MARK: Export and import

    private var exchangeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SavesHeading("Export and import", symbol: "square.and.arrow.up.on.square")
            s("A .lanternsave file holds the whole save (all characters and options). Use it to move your save to another Mac or to keep a copy. The game may have stored your local network address (an IPv4 address) in the save, so do not share the file publicly if that matters to you.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button { exportSave() } label: { s("Export save…") }
                    .disabled(saves.location == nil)
                Button { chooseSaveToImport() } label: { s("Import save…") }
                Spacer()
            }
            Divider()
            HStack(spacing: 8) {
                s("Single characters").font(.headline)
                SavesBadge("Experimental", tint: Theme.amber)
            }
            s("“Export” in the list above saves one character to a .lanternsave file. “Import character into slot…” puts it into a slot of this save, replacing what is in the slot. This works on the save files directly and has not been confirmed in the game yet: if the game does not like the result, restore the backup that is made first.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button { chooseCharacterToImport() } label: { s("Import character into slot…") }
                    .disabled(saves.location == nil)
                Spacer()
            }
        }
        .card()
    }

    // MARK: Take over

    private var takeOverCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SavesHeading("Take over from a bbport checkout", symbol: "arrow.down.doc")
            s("Copy the saves, the settings (bbport.ini) and, if you like, the shader cache from a bbport folder (macos/user and macos/bbport.ini) into the launcher. Your current saves are backed up first.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button { chooseCheckout() } label: { s("Choose folder…") }
                if let checkout = saves.checkout, saves.location != nil {
                    Button { sheet = .migrate(checkout) } label: { s("Use this checkout (\(checkout.folder.lastPathComponent))…") }
                }
                Spacer()
            }
        }
        .card()
    }

    /// The first-start offer of a dev build whose checkout holds saves.
    private func checkoutOffer(_ checkout: RepositoryMigration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SavesHeading("Saves found", symbol: "sparkles")
            s("This checkout (\(checkout.folder.lastPathComponent)) holds saves and settings. Do you want to take them over into the launcher?")
            HStack {
                Button { sheet = .migrate(checkout) } label: { s("Take over…") }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.ember)
                Spacer()
            }
        }
        .card()
    }

    // MARK: Actions

    private func exportSave() {
        let name = "Bloodborne-\(Self.stamp()).\(SaveArchive.fileExtension)"
        let message = String(localized: "Export the whole save. The game may have stored your local network address (IPv4) in it: do not share the file publicly if that matters to you.", table: "Saves")
        guard let url = Panels.saveFile(message: message, name: name, type: .lanternSave) else { return }
        saves.exportSave(to: Self.withExtension(url))
    }

    private func exportCharacter(_ character: SaveLocation.Character) {
        let name = "\(character.name.isEmpty ? "Character" : character.name)-\(Self.stamp()).\(SaveArchive.fileExtension)"
        let message = String(localized: "Export this character. It may carry your local network address (IPv4): do not share the file publicly if that matters to you. Importing characters is experimental.", table: "Saves")
        guard let url = Panels.saveFile(message: message, name: name, type: .lanternSave) else { return }
        saves.exportCharacter(slot: character.slot, to: Self.withExtension(url))
    }

    private func chooseSaveToImport() {
        let message = String(localized: "Choose a .lanternsave file with a whole save.", table: "Saves")
        guard let url = Panels.chooseFile(message: message, types: [.lanternSave]) else { return }
        do {
            let manifest = try SaveArchive.readManifest(url)
            guard manifest.kind == .save else { throw SaveError.wrongKind(expected: .save, found: manifest.kind) }
            pending = .importSave(url, manifest)
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func chooseCharacterToImport() {
        let message = String(localized: "Choose a .lanternsave file with a single character.", table: "Saves")
        guard let url = Panels.chooseFile(message: message, types: [.lanternSave]) else { return }
        do {
            let manifest = try SaveArchive.readManifest(url)
            guard manifest.kind == .character else { throw SaveError.wrongKind(expected: .character, found: manifest.kind) }
            sheet = .character(url, manifest)
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func chooseCheckout() {
        let message = String(localized: "Choose the bbport folder (the one with macos/user inside), or a folder that holds savedata.", table: "Saves")
        guard let folder = Panels.chooseFolder(message: message) else { return }
        if let source = RepositoryMigration.detect(folder: folder) {
            sheet = .migrate(source)
        } else {
            model.errorMessage = String(localized: "Nothing to take over in “\(folder.lastPathComponent)”: no saves (macos/user/savedata) and no macos/bbport.ini.", table: "Saves")
        }
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func withExtension(_ url: URL) -> URL {
        url.pathExtension.isEmpty ? url.appendingPathExtension(SaveArchive.fileExtension) : url
    }

    // MARK: Dialog texts

    private var pendingShown: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }

    private var deleteShown: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private var confirmationTitle: Text {
        switch pending {
        case .restore(let backup)?:
            return s("Restore the backup from \(backup.date.formatted(.dateTime.year().month().day().hour().minute()))?")
        case .importSave?:
            return s("Import this save and replace the current one?")
        case nil:
            return Text(verbatim: "")
        }
    }

    private var deleteTitle: Text {
        guard let backup = deleting else { return Text(verbatim: "") }
        if let label = backup.label, !backup.automatic { return s("Delete the snapshot “\(label)”?") }
        return s("Delete the backup from \(backup.date.formatted(.dateTime.year().month().day().hour().minute()))?")
    }

    private func importMessage(_ manifest: SaveManifest) -> Text {
        let names = (manifest.characters ?? []).map { $0.name }.joined(separator: ", ")
        let created = manifest.created.formatted(.dateTime.year().month().day())
        if names.isEmpty {
            return s("The file was made on \(created) and holds no characters. The current save is replaced, after an automatic backup of it.")
        }
        return s("The file was made on \(created) and holds: \(names). The current save is replaced, after an automatic backup of it.")
    }
}

// MARK: - Small views

/// A card's heading, from the Saves table.
private struct SavesHeading: View {
    let title: LocalizedStringKey
    let symbol: String

    init(_ title: LocalizedStringKey, symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        Label { Text(title, tableName: "Saves") } icon: { Image(systemName: symbol) }
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }
}

private struct SavesBadge: View {
    let text: LocalizedStringKey
    var tint: Color

    init(_ text: LocalizedStringKey, tint: Color) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text, tableName: "Saves")
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// Names a snapshot.
private struct SnapshotSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    let take: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            s("New snapshot").font(.display(.title2))
            s("A snapshot keeps the saves as they are now until you delete it.")
                .foregroundStyle(.secondary)
            TextField(text: $name, prompt: Text("Before the Orphan of Kos", tableName: "Saves")) { s("Name") }
                .onSubmit(commit)
            HStack {
                Spacer()
                Button(role: .cancel) { dismiss() } label: { s("Cancel") }
                    .keyboardShortcut(.cancelAction)
                Button(action: commit) { s("Save snapshot") }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        take(trimmed)
        dismiss()
    }
}

/// Chooses the slot an exported character goes into (experimental).
private struct CharacterImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let manifest: SaveManifest
    let current: [SaveLocation.Character]
    let take: (Int) -> Void
    @State private var slot = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                s("Import character").font(.display(.title2))
                SavesBadge("Experimental", tint: Theme.amber)
            }
            if let character = manifest.character {
                s("\(character.name), level \(character.level), playtime \(SavesView.playtime(character.playtime)) h")
                    .font(.headline)
            }
            Picker(selection: $slot) {
                ForEach(0..<SaveFormat.slotCount, id: \.self) { index in
                    if let occupant = current.first(where: { $0.slot == index }) {
                        s("Slot \(index + 1): \(occupant.name) (level \(occupant.level))").tag(index)
                    } else {
                        s("Slot \(index + 1): empty").tag(index)
                    }
                }
            } label: { s("Into slot") }
            if let occupant = current.first(where: { $0.slot == slot }) {
                Label { s("“\(occupant.name)” in this slot is replaced.") } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .foregroundStyle(Theme.amber)
            }
            s("Only this slot is changed. An automatic backup of the current saves is made first. Importing a single character has not been confirmed in the game yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(role: .cancel) { dismiss() } label: { s("Cancel") }
                    .keyboardShortcut(.cancelAction)
                Button { take(slot); dismiss() } label: { s("Import") }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

/// Asks before a checkout's saves, settings and cache are taken over.
private struct MigrationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let source: RepositoryMigration
    let take: (Bool) -> Void
    @State private var includeCache = true
    @State private var characters: [SaveLocation.Character] = []
    @State private var cacheSize: Int64 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            s("Take over from a bbport checkout").font(.display(.title2))
            Text(verbatim: source.folder.lastPathComponent)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                if source.hasSaves {
                    Label {
                        if characters.isEmpty {
                            s("Saves (no characters yet)")
                        } else {
                            s("Saves: \(characters.map(\.name).joined(separator: ", "))")
                        }
                    } icon: { Image(systemName: "checkmark.circle") }
                }
                if source.ini != nil {
                    Label { s("Settings (bbport.ini)") } icon: { Image(systemName: "checkmark.circle") }
                }
            }
            if source.hasCache {
                Toggle(isOn: $includeCache) {
                    s("Also copy the shader cache (\(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))): saves the first start's shader compile")
                }
            }
            s("The saves in the launcher are replaced by these; they are backed up first (an automatic backup), so you can undo this. The settings file is kept aside as bbport.ini.before-migration. The folder you chose is not changed.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(role: .cancel) { dismiss() } label: { s("Cancel") }
                    .keyboardShortcut(.cancelAction)
                Button { take(includeCache && source.hasCache); dismiss() } label: { s("Take over now") }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .task {
            characters = source.characters()
            cacheSize = source.cacheSize()
        }
    }
}
