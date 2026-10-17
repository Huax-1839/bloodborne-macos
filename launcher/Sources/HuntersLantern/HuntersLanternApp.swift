// SPDX-License-Identifier: GPL-2.0-or-later
import LanternCore
import SwiftUI

@main
struct HuntersLanternApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var updater = Updater()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(Theme.amber)
                .task { await Snapshot.runIfRequested(model) }
        }
        .defaultSize(width: 1080, height: 680)
        .commands { UpdateCommands(updater: updater) }
    }
}
