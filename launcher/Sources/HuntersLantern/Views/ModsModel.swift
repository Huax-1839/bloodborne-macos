// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import LanternCore

/// The Mods page's state: the library's mods and the conflicts among the switched-on ones. The
/// folder work runs off the main thread; the mod set itself belongs to the profile (ModsView).
@MainActor
final class ModsModel: ObservableObject {
    @Published private(set) var mods: [Mod] = []
    @Published private(set) var loaded = false
    /// What is being imported ("Name.zip"), nil when idle.
    @Published private(set) var importing: String?
    /// The files several switched-on mods provide, and per mod how many of its files a later mod replaces.
    @Published private(set) var conflicts: [ModConflict] = []
    @Published private(set) var overridden: [String: Int] = [:]

    private var library: ModLibrary?
    private var onError: (String) -> Void = { _ in }

    func configure(dir: URL, onError: @escaping (String) -> Void) {
        library = ModLibrary(dir: dir)
        self.onError = onError
    }

    func reload() async {
        guard let library else { return }
        let found = await Task.detached { library.mods() }.value
        if found != mods { mods = found }
        loaded = true
    }

    /// Recomputes the conflicts for the switched-on mods in load order (valid ones only).
    func updateConflicts(enabled: [String]) {
        let byName = Dictionary(mods.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = enabled.compactMap { byName[$0] }.filter(\.isValid)
        let found = ModLibrary.conflicts(ordered)
        var counts: [String: Int] = [:]
        for conflict in found { for loser in conflict.mods.dropLast() { counts[loser, default: 0] += 1 } }
        conflicts = found
        overridden = counts
    }

    /// Adds folders and ZIP files; returns the mods that were added (errors go to the error alert).
    func add(_ urls: [URL]) async -> [Mod] {
        guard let library else { return [] }
        var added: [Mod] = []
        var errors: [String] = []
        for url in urls {
            importing = url.lastPathComponent
            let result: Result<Mod, Error> = await Task.detached {
                var directory: ObjCBool = false
                let isFolder = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
                return Result { isFolder ? try library.importFolder(url) : try library.importArchive(url) }
            }.value
            switch result {
            case .success(let mod): added.append(mod)
            case .failure(let error): errors.append(error.localizedDescription)
            }
        }
        importing = nil
        if !errors.isEmpty { onError(errors.joined(separator: "\n\n")) }
        await reload()
        return added
    }

    /// Renames a mod; nil on success, else the reason.
    func rename(_ mod: Mod, to name: String) async -> String? {
        guard let library else { return nil }
        do {
            try library.rename(mod, to: name)
        } catch {
            return error.localizedDescription
        }
        await reload()
        return nil
    }

    func delete(_ mod: Mod) async -> Bool {
        guard let library else { return false }
        do {
            try library.delete(mod)
        } catch {
            onError(error.localizedDescription)
            return false
        }
        await reload()
        return true
    }
}
