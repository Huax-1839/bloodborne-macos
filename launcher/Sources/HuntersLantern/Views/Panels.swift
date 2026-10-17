// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import UniformTypeIdentifiers

/// The system's open and save panels, as plain calls.
@MainActor
enum Panels {
    static func chooseFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseFile(message: String, types: [UTType]) -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if !types.isEmpty { panel.allowedContentTypes = types }
        panel.prompt = String(localized: "Choose")
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func saveFile(message: String, name: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.message = message
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}

extension UTType {
    /// A PS4 package.
    static let ps4Package = UTType(filenameExtension: "pkg") ?? .data
}
