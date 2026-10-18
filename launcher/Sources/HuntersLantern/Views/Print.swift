// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import CoreText
import SwiftUI

/// The launcher's look (docs/LAUNCHER_DESIGN.md): a typeset print in Victorian gothic. Every
/// colour, size and spacing value of the design comes from here; no other values.
enum Print {
    // MARK: Colours

    static let bgBase = Color(hex: 0x0e0c0b)
    static let bgRaised = Color(hex: 0x161311)
    static let bgSunken = Color(hex: 0x0a0908)
    static let line = Color(hex: 0x2a2420)
    static let lineStrong = Color(hex: 0x4a3f36)
    static let textPrimary = Color(hex: 0xd8cfbf)
    static let textSecondary = Color(hex: 0x8f8577)
    static let textMuted = Color(hex: 0x5c544a)
    /// Only the main action.
    static let accent = Color(hex: 0x7a1f1a)
    static let accentHover = Color(hex: 0x93261f)
    static let accentPressed = Color(hex: 0x5e1713)
    static let brass = Color(hex: 0x9c8455)
    static let danger = Color(hex: 0xa83a2c)
    static let ok = Color(hex: 0x6b7a4f)

    // MARK: Spacing (4 px grid)

    static let window = CGSize(width: 960, height: 600)
    static let inset: CGFloat = 48
    static let groupGap: CGFloat = 32

    // MARK: Motion

    static let hover = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.18)
    static let appear = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.6)

    // MARK: Type

    /// Cormorant Garamond 600: the title (64) and the main button (28).
    static func display(_ size: CGFloat) -> Font { .custom("CormorantGaramond-SemiBold", fixedSize: size) }
    /// IM FELL English SC: section headings and the version line (14, tracking 0.12em).
    static func smallCaps(_ size: CGFloat = 14) -> Font { .custom("IM_FELL_English_SC", fixedSize: size) }
    /// EB Garamond 400: text (16) and labels (14).
    static func text(_ size: CGFloat = 16) -> Font { .custom("EBGaramond-Regular", fixedSize: size) }
    /// JetBrains Mono 400 (12): paths, versions, logs, the status bar.
    static func mono(_ size: CGFloat = 12) -> Font { .custom("JetBrainsMono-Regular", fixedSize: size) }

    /// Line spacing for text at line height 1.5.
    static func leading(_ size: CGFloat) -> CGFloat { size * 0.5 }

    /// Registers the bundled fonts (Resources/Fonts, OFL) for this process; once, at start.
    static func registerFonts() {
        let bundle = Bundle.module
        let urls = (bundle.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
            + (bundle.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [])
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }
}

// MARK: - Focus

/// The keyboard focus mark: a 1 px brass outline, 4 px out, only while focused.
private struct FocusOutline: ViewModifier {
    @Environment(\.isFocused) private var focused

    func body(content: Content) -> some View {
        content.overlay {
            if focused {
                Rectangle().strokeBorder(Print.brass, lineWidth: 1).padding(-4)
            }
        }
    }
}

extension View {
    func printFocus() -> some View { modifier(FocusOutline()) }
}

// MARK: - Buttons

/// A text action ("ändern", "verwalten"): Garamond 14 in the text colour, brass on hover.
struct TextActionStyle: ButtonStyle {
    var size: CGFloat = 14
    /// Another face (the status bar's mono).
    var font: Font?
    var color = Print.textPrimary

    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration, font: font ?? Print.text(size), color: color)
    }

    private struct Label: View {
        let configuration: ButtonStyleConfiguration
        let font: Font
        let color: Color
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(font)
                .foregroundStyle(!enabled ? Print.textMuted : hovering || configuration.isPressed ? Print.brass : color)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(Print.hover, value: hovering)
                .printFocus()
        }
    }
}

/// A list row that is also a link (to the page behind it): its first text turns brass on hover.
struct RowLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }

    private struct Styled: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .environment(\.rowHighlight, hovering || configuration.isPressed)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(Print.hover, value: hovering)
                .printFocus()
        }
    }
}

private struct RowHighlightKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// A linked list row under the pointer: its label turns brass.
    var rowHighlight: Bool {
        get { self[RowHighlightKey.self] }
        set { self[RowHighlightKey.self] = newValue }
    }
}

/// The main action: an accent rectangle, full width, 72 high, Cormorant 28. On hover it flickers
/// like a gas lamp (irregular brightness, at most ±4 %), not with Reduce Motion.
struct MainActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }

    private struct Styled: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            let flicker = enabled && hovering && !configuration.isPressed && !reduceMotion
            TimelineView(.animation(paused: !flicker)) { timeline in
                configuration.label
                    .font(Print.display(28))
                    .foregroundStyle(enabled ? Print.textPrimary : Print.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 72, maxHeight: 72)
                    .background(fill.brightness(flicker ? Self.gaslight(timeline.date) : 0))
                    .overlay(Rectangle().strokeBorder(enabled ? Color.clear : Print.line, lineWidth: 1))
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(Print.hover, value: hovering)
            .animation(Print.hover, value: configuration.isPressed)
            .printFocus()
        }

        private var fill: Color {
            guard enabled else { return Print.bgRaised }
            if configuration.isPressed { return Print.accentPressed }
            return hovering ? Print.accentHover : Print.accent
        }

        /// Three unrelated slow waves: no visible period, within ±0.04.
        private static func gaslight(_ date: Date) -> Double {
            let t = date.timeIntervalSinceReferenceDate
            let wave = 0.5 * sin(t * 2.3) + 0.3 * sin(t * 5.9 + 1.7) + 0.2 * sin(t * 13.1 + 0.4)
            return 0.04 * wave
        }
    }
}

/// A sidebar entry: Garamond 16, 32 high; the current page in the text colour with ✦ in brass
/// before it, the others secondary, brass on hover.
struct SidebarItemStyle: ButtonStyle {
    let current: Bool

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, current: current)
    }

    private struct Styled: View {
        let configuration: ButtonStyleConfiguration
        let current: Bool
        @State private var hovering = false

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: current ? "✦" : "")
                    .foregroundStyle(Print.brass)
                    .frame(width: 16, alignment: .leading)
                    .accessibilityHidden(true)
                configuration.label
                    .foregroundStyle(hovering || configuration.isPressed ? Print.brass
                                     : current ? Print.textPrimary : Print.textSecondary)
            }
            .font(Print.text(16))
            .frame(height: 32)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(Print.hover, value: hovering)
            .printFocus()
        }
    }
}
