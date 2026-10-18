// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI

struct AboutView: View {
    @EnvironmentObject private var model: AppModel

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// The license texts' folder (launcher/build.sh fills Contents/Resources/Licenses), opened in
    /// the Finder: README.txt says which folder is which component.
    private var licenses: URL? {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Licenses", isDirectory: true),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("README.txt").path) else { return nil }
        return folder
    }

    var body: some View {
        PageContainer(title: "About", locked: false) {
            PrintSection(Text("Hunter's Lantern")) {
                RegisterLine(Text("Version")) {
                    Text(verbatim: version)
                        .font(Print.mono())
                        .foregroundStyle(Print.textPrimary)
                }
                PrintNote(Text("The game is your own copy. This app contains no game files and downloads none."))
                PrintNote(Text("Licence: GPL-2.0-or-later"))
            } trailing: {
                if let licenses {
                    Button { NSWorkspace.shared.open(licenses) } label: { Text("licenses…") }
                        .help(Text("The license texts of Hunter's Lantern and the components it contains"))
                }
            }
            PrintSection(Text("Data folder")) {
                Text(verbatim: model.dirs.root.path)
                    .font(Print.mono())
                    .foregroundStyle(Print.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } trailing: {
                Button { NSWorkspace.shared.activateFileViewerSelecting([model.dirs.root]) } label: { Text("show in Finder") }
            }
            PrintSection(Text("Source code")) {
                Button {
                    if let url = URL(string: "https://github.com/Huax-1839/bloodborne-macos") { NSWorkspace.shared.open(url) }
                } label: { Text("github.com/Huax-1839/bloodborne-macos") }
                    .buttonStyle(TextActionStyle(font: Print.mono()))
            }
        }
    }
}
