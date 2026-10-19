// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

private final class BundleFinder {}

extension Bundle {
    /// This module's resource bundle. Not SwiftPM's generated Bundle.module: the one from Xcode 26's
    /// swift build (the release runner) only looks next to the .app and in the build machine's
    /// .build folder, and stops the app when neither exists. launcher/build.sh puts the bundles in
    /// Contents/Resources. Falls back to the main bundle (English text) instead of crashing.
    static let resources: Bundle = {
        let name = "HuntersLantern_LanternCore.bundle"
        let code = Bundle(for: BundleFinder.self)
        let places = [
            Bundle.main.resourceURL,                    // the app: Contents/Resources
            Bundle.main.bundleURL,                      // swift run: next to the executable
            code.resourceURL,
            code.bundleURL.deletingLastPathComponent(), // swift test: next to the .xctest
        ]
        for case let place? in places {
            if let bundle = Bundle(url: place.appendingPathComponent(name)) { return bundle }
        }
        return Bundle.main
    }()
}
