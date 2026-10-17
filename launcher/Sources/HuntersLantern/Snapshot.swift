// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

/// LANTERN_SNAPSHOT=<folder> (development): renders each page of the window into
/// <folder>/<page>.png in-process and quits, so the UI can be checked without screen capture.
/// LANTERN_AUTOPLAY=1 (integration tests): presses Play at start; with LANTERN_SNAPSHOT the pages
/// are rendered once the launch has ended (the outcome card).
@MainActor
enum Snapshot {
    static func runIfRequested(_ model: AppModel) async {
        let environment = ProcessInfo.processInfo.environment
        if environment["LANTERN_AUTOPLAY"] == "1" {
            try? await Task.sleep(for: .seconds(1))
            model.play()
            while model.isBusy || (model.lastResult == nil && model.errorMessage == nil) {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        guard let folder = environment["LANTERN_SNAPSHOT"], !folder.isEmpty else { return }
        let pages = ProcessInfo.processInfo.environment["LANTERN_SNAPSHOT_PAGES"]?
            .split(separator: ",").compactMap { Page(rawValue: String($0)) } ?? Page.allCases
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(2))
        for page in pages {
            model.page = page
            try? await Task.sleep(for: .seconds(1.5))
            guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(page.rawValue).png"))
        }
        NSApp.terminate(nil)
    }
}
