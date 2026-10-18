// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// The frame every page shares in the main area: a Cormorant title, the lock note while the game
/// runs (D7), and the sections below it, scrolled, inset 48 and 32 apart. The content is disabled
/// while the launcher is busy when `locked` is set. Switches and fields take the print styles.
struct PageContainer<Content: View, Trailing: View>: View {
    @EnvironmentObject private var model: AppModel
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
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Print.bgBase)
        .toggleStyle(PrintToggleStyle())
        .textFieldStyle(PrintFieldStyle())
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
