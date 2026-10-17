// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI

struct AboutView: View {
    @EnvironmentObject private var model: AppModel

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        PageContainer(title: "About", locked: false) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 16) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(Theme.amber)
                            .shadow(color: Theme.amber.opacity(0.6), radius: 12)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hunter's Lantern").font(.display(.title))
                            Text("Version \(version)").foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("The game is your own copy. This app contains no game files and downloads none.")
                        Text("Licence: GPL-2.0-or-later")
                            .foregroundStyle(.secondary)
                    }
                    .card()
                    VStack(alignment: .leading, spacing: 10) {
                        CardHeading("Data folder", symbol: "folder")
                        Text(verbatim: model.dirs.root.path)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([model.dirs.root])
                        }
                    }
                    .card()
                    VStack(alignment: .leading, spacing: 10) {
                        CardHeading("Source code", symbol: "chevron.left.forwardslash.chevron.right")
                        Link("github.com/Huax-1839/bloodborne-macos", destination: URL(string: "https://github.com/Huax-1839/bloodborne-macos")!)
                    }
                    .card()
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
                .frame(maxWidth: 640, alignment: .leading)
            }
        }
    }
}
