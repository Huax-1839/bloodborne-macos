// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// The look: dark, quiet, lantern light (a warm amber) as the only accent.
enum Theme {
    static let amber = Color(red: 0.95, green: 0.69, blue: 0.30)
    static let ember = Color(red: 0.78, green: 0.40, blue: 0.12)
    static let ink = Color(red: 0.055, green: 0.050, blue: 0.060)
    static let inkLifted = Color(red: 0.095, green: 0.085, blue: 0.095)
}

extension Font {
    /// Serif display type for titles.
    static func display(_ style: Font.TextStyle = .largeTitle) -> Font {
        .system(style, design: .serif).weight(.semibold)
    }
}

/// The dark gradient with a faint lantern glow: behind the pages, and the Home page's stand-in
/// until a game is imported (no game artwork, D17).
struct LanternBackdrop: View {
    var glow: Double = 0.16

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.inkLifted, Theme.ink], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.amber.opacity(glow), Theme.ember.opacity(glow * 0.35), .clear],
                           center: UnitPoint(x: 0.82, y: 0.12), startRadius: 4, endRadius: 520)
            RadialGradient(colors: [Theme.ember.opacity(glow * 0.5), .clear],
                           center: UnitPoint(x: 0.1, y: 1.0), startRadius: 4, endRadius: 420)
        }
        .ignoresSafeArea()
    }
}

/// A card over the artwork or the backdrop.
struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.07)))
    }
}

extension View {
    func card() -> some View { modifier(CardStyle()) }
}

/// A card's small heading.
struct CardHeading: View {
    let title: LocalizedStringKey
    let symbol: String

    init(_ title: LocalizedStringKey, symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }
}

/// A small label/value line.
struct InfoRow: View {
    let title: LocalizedStringKey
    let value: Text

    init(_ title: LocalizedStringKey, _ value: Text) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            value.multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}

/// A rounded badge ("built-in", "unmeasured").
struct Badge: View {
    let text: LocalizedStringKey
    var tint: Color = .secondary

    init(_ text: LocalizedStringKey, tint: Color = .secondary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
    }
}
