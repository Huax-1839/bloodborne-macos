// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// The frame every page shares: a serif title, the lock note while the game runs (D7) and the
/// backdrop. The content is disabled while the launcher is busy when `locked` is set.
struct PageContainer<Content: View>: View {
    @EnvironmentObject private var model: AppModel
    let title: LocalizedStringKey
    var locked = true
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(Print.display(44))
                if locked && model.isBusy {
                    Label("Settings are locked while the game runs or is being prepared.", systemImage: "lock.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 12)
            content
                .disabled(locked && model.isBusy)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Print.bgBase)
    }
}

/// A page that is not built yet.
struct PlaceholderPage: View {
    let title: LocalizedStringKey
    let symbol: String
    let summary: LocalizedStringKey

    var body: some View {
        PageContainer(title: title, locked: false) {
            VStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Theme.amber.opacity(0.8))
                Text("Coming in this version")
                    .font(.display(.title2))
                Text(summary)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 440)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 60)
        }
    }
}
