// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import LanternCore
import SwiftUI

/// The Patches page's own state (L3.5): the patch lists read from the built-in file and the
/// patches folder, and the file actions. Profile edits go through AppModel.saveProfile.
@MainActor
final class PatchesModel: ObservableObject {
    @Published private(set) var store = PatchStore()
    /// The last import's or removal's error, shown on the page.
    @Published var problem: String?

    func reload(model: AppModel) {
        // Without a runtime only the user's files are listed.
        let xml = (try? model.runtime.get())?.patchesXML ?? URL(fileURLWithPath: "/nonexistent.xml")
        store = PatchStore.load(builtInXML: xml, patchesDir: model.dirs.patchesDir)
    }

    /// Copies an XML file into the patches folder (checked like patches.py reads it).
    func add(_ url: URL, model: AppModel) {
        do {
            try PatchStore.importXML(from: url, into: model.dirs)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        reload(model: model)
    }

    /// Moves a patch file to the Trash; the profile's choices for its patches stay (they apply
    /// again when the file returns).
    func remove(_ file: PatchFile, model: AppModel) {
        do {
            try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        reload(model: model)
    }

    func showFolder(model: AppModel) {
        try? FileManager.default.createDirectory(at: model.dirs.patchesDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(model.dirs.patchesDir)
    }
}
