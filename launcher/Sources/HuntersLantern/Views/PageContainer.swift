// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI

/// The frame every page shares in the main area: a Cormorant title over a faint band of the
/// game's own artwork (D17), the lock note while the game runs (D7), and the sections below it,
/// scrolled, inset 48 and 32 apart; a page that goes on under the status bar fades out there. The
/// content is disabled while the launcher is busy when `locked` is set. Switches and fields take
/// the print styles.
struct PageContainer<Content: View, Trailing: View>: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.gameArtwork) private var artwork
    let title: LocalizedStringKey
    var locked = true
    /// Text actions at the title's end ("hinzufügen …").
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Print.groupGap) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(title)
                            .font(Print.display(44))
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 16)
                        trailing
                            .buttonStyle(TextActionStyle())
                    }
                    if locked && model.isBusy {
                        PrintNote(Text("Settings are locked while the game runs or is being prepared."))
                    }
                }
                content
                    .disabled(locked && model.isBusy)
            }
            .padding(Print.inset)
            // The last line scrolls clear of the fade.
            .padding(.bottom, Self.fade - Print.inset / 2)
            // A large window gets margins, not longer lines.
            .frame(maxWidth: Print.column + 2 * Print.inset, alignment: .topLeading)
            .frame(maxWidth: .infinity)
            .background(alignment: .top) { HeaderArt(image: artwork) }
        }
        .scrollIndicators(.automatic)
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [Print.bgBase.opacity(0), Print.bgBase], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.fade)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Print.bgBase)
        .toggleStyle(PrintToggleStyle())
        .textFieldStyle(PrintFieldStyle())
    }
}

extension PageContainer {
    /// The fade at the page's bottom edge: a cut line reads as "more below".
    static var fade: CGFloat { 48 }
}

/// The band behind a page title: the overview's plate, dimmed to a texture and fading into the
/// page, so every page is printed on the same game. Its lower edge (street and coat, not the
/// logo, which would fight the title). Nothing without artwork.
private struct HeaderArt: View {
    let image: NSImage?

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, minHeight: 176, maxHeight: 176, alignment: .bottom)
                .clipped()
                .saturation(0.5)
                .opacity(0.22)
                .mask(LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

extension PageContainer where Trailing == EmptyView {
    init(title: LocalizedStringKey, locked: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.locked = locked
        trailing = EmptyView()
        self.content = content()
    }
}

extension PageContainer {
    init(title: LocalizedStringKey, locked: Bool = true, @ViewBuilder content: () -> Content,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.locked = locked
        self.trailing = trailing()
        self.content = content()
    }
}
