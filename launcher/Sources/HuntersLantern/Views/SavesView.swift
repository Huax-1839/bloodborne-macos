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

    @State private var askingOwnSaves = false

    /// Switching own saves on hides the shared ones from this profile: asked first.
    private var ownSaves: Binding<Bool> {
        Binding(get: { model.activeProfile.ownSaves },
                set: { on in if on { askingOwnSaves = true } else { setOwnSaves(false) } })
    }

    private func setOwnSaves(_ on: Bool) {
        var profile = model.activeProfile
        profile.ownSaves = on
        model.saveProfile(profile)
    }

    var body: some View {
        PageContainer(title: "Saves") {
            if saves.working { PrintProgress(fraction: nil) }
            if let checkout = saves.checkout, saves.location == nil { checkoutOffer(checkout) }
            charactersSection
            backupsSection
            exchangeSection
            takeOverSection
        }
        .disabled(saves.working)
        .onAppear { saves.bind(model) }
        .onChange(of: model.state.activeProfile) { saves.reload() }
        .onChange(of: model.activeProfile.ownSaves) { saves.reload() }
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

    private var charactersSection: some View {
        PrintSection(s("Characters")) {
            // Saves are the launcher's, shared by the profiles, unless a profile has its own: the
            // choice is made here, where its effect shows.
            Toggle(isOn: ownSaves) { Text("Own saves for the profile “\(model.activeProfile.name)”") }
                .confirmationDialog(Text("Give this profile its own saves?"), isPresented: $askingOwnSaves, titleVisibility: .visible) {
                    Button { setOwnSaves(true) } label: { Text("Own saves") }
                    Button(role: .cancel) {} label: { Text("Cancel") }
                } message: {
                    Text("The profile then starts without saves of its own; your current saves stay with the other profiles. Switching it off brings them back.")
                }
            if model.activeProfile.ownSaves {
                PrintNote(s("The own saves of the profile “\(model.activeProfile.name)”."))
            } else {
                PrintNote(s("The saves all profiles share."))
            }
            if saves.characters.isEmpty {
                PrintNote(s(saves.location == nil
                            ? "No save yet. Start the game and create a character, or import a save below."
                            : "No character in this save yet."))
            } else {
                PrintRows {
                    ForEach(saves.characters) { characterRow($0) }
                }
            }
        }
    }

    private func characterRow(_ character: SaveLocation.Character) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(verbatim: String(character.slot + 1))
                .font(Print.mono())
                .foregroundStyle(Print.textSecondary)
                .frame(minWidth: 16, alignment: .leading)
            Text(verbatim: character.name.isEmpty ? "—" : character.name)
                .lineLimit(1)
            Spacer(minLength: 8)
            s("Level \(character.level)")
            Text(verbatim: Self.playtime(character.playtime))
                .font(Print.mono())
                .foregroundStyle(Print.textSecondary)
                .frame(minWidth: 48, alignment: .trailing)
                .fixedSize()
            Text(verbatim: character.echoes.formatted())
                .font(Print.mono())
                .foregroundStyle(Print.textSecondary)
                .frame(minWidth: 64, alignment: .trailing)
                .fixedSize()
                .help(s("\(character.echoes) Echoes"))
            Button { exportCharacter(character) } label: { s("export…") }
                .buttonStyle(TextActionStyle())
        }
        .printRow()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: character.name.isEmpty ? String(character.slot + 1) : character.name))
    }

    /// Hours and minutes, h:mm.
    static func playtime(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 3600, seconds % 3600 / 60)
    }

    // MARK: Backups

    private var backupsSection: some View {
        PrintSection(s("Backups")) {
            PrintNote(s("A backup is made automatically before each start; the last 10 are kept. Snapshots stay until you delete them. Backups share disk space with the saves until the game changes them."))
            if saves.backups.isEmpty {
                PrintNote(s("No backups yet."))
            } else {
                PrintRows {
                    ForEach(saves.backups) { backupRow($0) }
                }
            }
            PrintNote(s("Space used: \(ByteCountFormatter.string(fromByteCount: saves.totalSize, countStyle: .file))"))
        } trailing: {
            Button { sheet = .snapshot } label: { s("take snapshot…") }
                .disabled(saves.location == nil)
                .help(saves.location == nil ? s("There is no save yet.") : Text(verbatim: ""))
            Button { saves.showBackupsInFinder() } label: { s("show in Finder") }
        }
    }

    private func backupRow(_ backup: BackupStore.Backup) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            if let label = backup.label, !backup.automatic {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: label).lineLimit(1)
                    Text(verbatim: "✦").foregroundStyle(Print.brass).accessibilityHidden(true)
                }
                .help(s("Snapshot"))
                .accessibilityElement(children: .combine)
                .accessibilityValue(s("Snapshot"))
                Text(backup.date, format: .dateTime.year().month().day().hour().minute())
                    .font(Print.text(14))
                    .foregroundStyle(Print.textSecondary)
            } else {
                Text(backup.date, format: .dateTime.year().month().day().hour().minute())
            }
            Spacer(minLength: 8)
            Text(verbatim: ByteCountFormatter.string(fromByteCount: backup.size, countStyle: .file))
                .font(Print.mono())
                .foregroundStyle(Print.textSecondary)
            Button { pending = .restore(backup) } label: { s("restore…") }
                .buttonStyle(TextActionStyle())
            Button { deleting = backup } label: { s("delete") }
                .buttonStyle(TextActionStyle())
        }
        .printRow()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(backup.date, format: .dateTime.year().month().day().hour().minute()))
    }

    // MARK: Export and import

    private var exchangeSection: some View {
        PrintSection(s("Export and import")) {
            PrintNote(s("A .lanternsave file holds the whole save (all characters and options). Use it to move your save to another Mac or to keep a copy. The game may have stored your local network address (an IPv4 address) in the save, so do not share the file publicly if that matters to you."))
            HStack(spacing: 16) {
                Button { exportSave() } label: { s("Export save…") }
                    .disabled(saves.location == nil)
                    .help(saves.location == nil ? s("There is no save yet.") : Text(verbatim: ""))
                Button { chooseSaveToImport() } label: { s("Import save…") }
            }
            .buttonStyle(FrameActionStyle())
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                s("Single characters")
                PrintTag(s("Experimental"))
            }
            .padding(.top, 16)
            PrintNote(s("“Export” in the list above saves one character to a .lanternsave file. “Import character into slot…” puts it into a slot of this save, replacing what is in the slot. This works on the save files directly and has not been confirmed in the game yet: if the game does not like the result, restore the backup that is made first."))
            Button { chooseCharacterToImport() } label: { s("Import character into slot…") }
                .buttonStyle(FrameActionStyle())
                .disabled(saves.location == nil)
                .help(saves.location == nil ? s("There is no save yet.") : Text(verbatim: ""))
        }
    }

    // MARK: Take over

    private var takeOverSection: some View {
        PrintSection(s("Take over from a bbport checkout")) {
            PrintNote(s("Copy the saves, the settings (bbport.ini) and, if you like, the shader cache from a bbport folder (macos/user and macos/bbport.ini) into the launcher. Your current saves are backed up first."))
            HStack(spacing: 16) {
                Button { chooseCheckout() } label: { s("Choose folder…") }
                if let checkout = saves.checkout, saves.location != nil {
                    Button { sheet = .migrate(checkout) } label: { s("Use this checkout (\(checkout.folder.lastPathComponent))…") }
                }
            }
            .buttonStyle(FrameActionStyle())
        }
    }

    /// The first-start offer of a dev build whose checkout holds saves.
    private func checkoutOffer(_ checkout: RepositoryMigration) -> some View {
        PrintSection(s("Saves found")) {
            PrintNote(s("This checkout (\(checkout.folder.lastPathComponent)) holds saves and settings. Do you want to take them over into the launcher?"),
                      color: Print.textPrimary)
            Button { sheet = .migrate(checkout) } label: { s("Take over…") }
                .buttonStyle(FrameActionStyle())
        }
    }

    // MARK: Actions

    private func exportSave() {
        let name = "Bloodborne-\(Self.stamp()).\(SaveArchive.fileExtension)"
        let message = String(localized: "Export the whole save. The game may have stored your local network address (IPv4) in it: do not share the file publicly if that matters to you.", table: "Saves")
        guard let url = Panels.saveFile(message: message, name: name, type: .lanternSave) else { return }
        saves.exportSave(to: Self.withExtension(url))
    }

    private func exportCharacter(_ character: SaveLocation.Character) {
        let name = "\(character.name.isEmpty ? String(localized: "Character", table: "Saves") : character.name)-\(Self.stamp()).\(SaveArchive.fileExtension)"
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

// MARK: - Dialogs

/// Names a snapshot.
private struct SnapshotSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    let take: (String) -> Void

    var body: some View {
        PrintDialog(title: s("New snapshot"), width: 420) {
            PrintNote(s("A snapshot keeps the saves as they are now until you delete it."))
            TextField(text: $name, prompt: Text("Before the Orphan of Kos", tableName: "Saves")) { s("Name") }
                .onSubmit(commit)
        } actions: {
            Button(role: .cancel) { dismiss() } label: { s("Cancel") }
                .keyboardShortcut(.cancelAction)
            Button(action: commit) { s("Save snapshot") }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty)
        }
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
        PrintDialog(title: s("Import character"), width: 460) {
            PrintTag(s("Experimental"))
            if let character = manifest.character {
                s("\(character.name), level \(character.level), playtime \(SavesView.playtime(character.playtime)) h")
            }
            RegisterLine(s("Into slot")) {
                PrintMenu(selection: $slot, options: Array(0..<SaveFormat.slotCount)) { index in
                    if let occupant = current.first(where: { $0.slot == index }) {
                        return s("Slot \(index + 1): \(occupant.name) (level \(occupant.level))")
                    }
                    return s("Slot \(index + 1): empty")
                }
            }
            if let occupant = current.first(where: { $0.slot == slot }) {
                PrintNote(s("“\(occupant.name)” in this slot is replaced."), color: Print.danger)
            }
            PrintNote(s("Only this slot is changed. An automatic backup of the current saves is made first. Importing a single character has not been confirmed in the game yet."))
        } actions: {
            Button(role: .cancel) { dismiss() } label: { s("Cancel") }
                .keyboardShortcut(.cancelAction)
            Button { take(slot); dismiss() } label: { s("Import") }
                .keyboardShortcut(.defaultAction)
        }
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
        PrintDialog(title: s("Take over from a bbport checkout")) {
            Text(verbatim: source.folder.lastPathComponent)
                .font(Print.mono())
                .foregroundStyle(Print.textSecondary)
            PrintRows {
                if source.hasSaves {
                    Group {
                        if characters.isEmpty {
                            s("Saves (no characters yet)")
                        } else {
                            s("Saves: \(characters.map(\.name).joined(separator: ", "))")
                        }
                    }
                    .printRow()
                }
                if source.ini != nil {
                    s("Settings (bbport.ini)").printRow()
                }
            }
            if source.hasCache {
                Toggle(isOn: $includeCache) {
                    s("Also copy the shader cache (\(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))): saves the first start's shader compile")
                }
                .help(s("Also copy the shader cache (\(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))): saves the first start's shader compile"))
            }
            PrintNote(s("The saves in the launcher are replaced by these; they are backed up first (an automatic backup), so you can undo this. The settings file is kept aside as bbport.ini.before-migration. The folder you chose is not changed."))
        } actions: {
            Button(role: .cancel) { dismiss() } label: { s("Cancel") }
                .keyboardShortcut(.cancelAction)
            Button { take(includeCache && source.hasCache); dismiss() } label: { s("Take over now") }
                .keyboardShortcut(.defaultAction)
        }
        .task {
            characters = source.characters()
            cacheSize = source.cacheSize()
        }
    }
}
