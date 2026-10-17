// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import LanternCore
import SwiftUI

/// The Saves page's state: the active profile's save root (D11), its characters and backups, and
/// the actions on them. Copying runs off the main thread; errors go to AppModel.errorMessage and
/// successes to AppModel.notice.
@MainActor
final class SavesModel: ObservableObject {
    @Published private(set) var userRoot: URL?
    @Published private(set) var location: SaveLocation?
    @Published private(set) var characters: [SaveLocation.Character] = []
    @Published private(set) var backups: [BackupStore.Backup] = []
    @Published private(set) var totalSize: Int64 = 0
    @Published private(set) var working = false
    /// The repository checkout of a dev build, when it holds something to take over.
    @Published private(set) var checkout: RepositoryMigration?

    private weak var app: AppModel?

    func bind(_ app: AppModel) {
        self.app = app
        reload()
    }

    private var store: BackupStore? {
        guard let app, let userRoot else { return nil }
        // The history of this save root, as AppModel.play() keeps it.
        return BackupStore(dir: app.dirs.backupsDir.appendingPathComponent(userRoot.lastPathComponent))
    }

    var backupFolder: URL? { store?.dir }

    /// Reads the save root, its characters and backups again.
    func reload() {
        guard let app else { return }
        let profile = app.activeProfile
        let root = profile.ownSaves ? app.dirs.profileUserDir(profile.id) : app.dirs.userDir
        userRoot = root
        let locations = SaveRoot.find(userRoot: root)
        let title = app.activeGame?.check.title
        location = locations.first { $0.titleID == title } ?? locations.first
        characters = location?.characters() ?? []
        if let store {
            backups = store.list()
            totalSize = backups.reduce(0) { $0 + $1.size }
        }
        if case .success(let runtime) = app.runtime, let repository = runtime.repository {
            checkout = RepositoryMigration.detect(folder: repository)
        } else {
            checkout = nil
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private static func describe(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day().hour().minute())
    }

    /// Runs `work` in the background; its return value is the success notice.
    private func run(_ work: @escaping @Sendable () throws -> String?) {
        guard !working else { return }
        working = true
        Task {
            do {
                let notice = try await Task.detached { try work() }.value
                if let notice { app?.notice = notice }
            } catch {
                app?.errorMessage = error.localizedDescription
            }
            working = false
            reload()
        }
    }

    // MARK: Backups

    func restore(_ backup: BackupStore.Backup) {
        guard let store, let userRoot else { return }
        let date = Self.describe(backup.date)
        run {
            try store.restore(backup, userRoot: userRoot)
            return String(localized: "Restored the backup from \(date). The state before is in an automatic backup.", table: "Saves")
        }
    }

    func delete(_ backup: BackupStore.Backup) {
        guard let store else { return }
        run {
            try store.delete(backup)
            return nil
        }
    }

    func takeSnapshot(named name: String) {
        guard let store, let userRoot else { return }
        run {
            guard !SaveRoot.find(userRoot: userRoot).isEmpty else { throw SaveError.noSave }
            let snapshot = try store.snapshot(userRoot: userRoot, label: name)
            return String(localized: "Snapshot “\(snapshot.label ?? name)” taken.", table: "Saves")
        }
    }

    // MARK: Export and import

    func exportSave(to url: URL) {
        guard let location else { return }
        let version = appVersion
        run {
            try SaveArchive.exportSave(location, to: url, appVersion: version)
            return String(localized: "Save exported to \(url.lastPathComponent).", table: "Saves")
        }
    }

    func exportCharacter(slot: Int, to url: URL) {
        guard let location else { return }
        let version = appVersion
        run {
            try SaveArchive.exportCharacter(slot: slot, of: location, to: url, appVersion: version)
            return String(localized: "Character exported to \(url.lastPathComponent).", table: "Saves")
        }
    }

    func importSave(_ url: URL) {
        guard let store, let userRoot else { return }
        let title = app?.activeGame?.check.title
        run {
            try SaveArchive.importSave(url, userRoot: userRoot, backups: store, preferredTitle: title)
            return String(localized: "Save imported. The state before is in an automatic backup.", table: "Saves")
        }
    }

    func importCharacter(_ url: URL, intoSlot slot: Int) {
        guard let store, let location else { return }
        run {
            let result = try SaveArchive.importCharacter(url, intoSlot: slot, of: location, backups: store)
            let name = result.manifest.name ?? ""
            return String(localized: "Character “\(name)” imported into slot \(slot + 1). The state before is in an automatic backup.", table: "Saves")
        }
    }

    // MARK: Take over

    func migrate(_ source: RepositoryMigration, includeCache: Bool) {
        guard let app, let store, let userRoot else { return }
        let dirs = app.dirs
        run {
            let result = try source.migrate(into: dirs, userRoot: userRoot, backups: store, includeCache: includeCache)
            var parts: [String] = []
            if result.savesTaken { parts.append(String(localized: "saves", table: "Saves")) }
            if result.iniTaken { parts.append(String(localized: "settings", table: "Saves")) }
            if result.cacheFoldersTaken > 0 { parts.append(String(localized: "shader cache", table: "Saves")) }
            let list = parts.formatted(.list(type: .and))
            return String(localized: "Taken over: \(list). The previous saves are in an automatic backup.", table: "Saves")
        }
    }

    func showBackupsInFinder() {
        guard let folder = backupFolder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}
