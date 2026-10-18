// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

// The parts the pages are set from (docs/LAUNCHER_DESIGN.md): sections under small-caps headings,
// register lines, rows between rules, choices as words, menus as text, fields, framed actions and
// dialogs. Values only from Print.

// MARK: - Sections and text

/// A page section: a small-caps heading over a rule (with optional text actions at its end), and
/// its content below.
struct PrintSection<Content: View, Trailing: View>: View {
    let title: Text
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                title
                    .font(Print.smallCaps())
                    .tracking(14 * 0.12)
                    .foregroundStyle(Print.textSecondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                trailing
                    .buttonStyle(TextActionStyle())
            }
            .padding(.bottom, 4)
            .overlay(alignment: .bottom) { Rectangle().fill(Print.line).frame(height: 1) }
            .padding(.bottom, 4)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension PrintSection where Trailing == EmptyView {
    init(_ title: Text, @ViewBuilder content: () -> Content) {
        self.title = title
        trailing = EmptyView()
        self.content = content()
    }
}

extension PrintSection {
    init(_ title: Text, @ViewBuilder content: () -> Content, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
    }
}

/// An explanation under a heading: Garamond 14, secondary, wrapped.
struct PrintNote: View {
    let text: Text
    var color = Print.textSecondary

    init(_ text: Text, color: Color = Print.textSecondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        text
            .font(Print.text(14))
            .foregroundStyle(color)
            .lineSpacing(Print.leading(14))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small brass tag in small caps ("experimentell", "eingebaut").
struct PrintTag: View {
    let text: Text

    init(_ text: Text) { self.text = text }

    var body: some View {
        text
            .font(Print.smallCaps(12))
            .tracking(12 * 0.12)
            .foregroundStyle(Print.brass)
    }
}

// MARK: - Register lines and rows

/// A dotted leader between a register line's label and its value, at the text's baseline.
struct Leader: View {
    var body: some View {
        DottedLine()
            .stroke(Print.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
            .frame(height: 1)
            .frame(minWidth: 16)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
            .accessibilityHidden(true)
    }

    private struct DottedLine: Shape {
        func path(in rect: CGRect) -> Path {
            Path { $0.move(to: CGPoint(x: rect.minX, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) }
        }
    }
}

/// `label ········ value`: the label secondary, the value in the text colour, at least 32 high.
struct RegisterLine<Label: View, Value: View>: View {
    @ViewBuilder var label: Label
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            label
                .font(Print.text(16))
                .foregroundStyle(Print.textSecondary)
                .lineLimit(1)
                .layoutPriority(1)
            Leader()
            value
                .lineLimit(1)
                .layoutPriority(2)
        }
        .frame(minHeight: 32)
    }
}

extension RegisterLine where Label == Text {
    init(_ label: Text, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }
}

/// Rows between rules (each `printRow()` has its rule under it; the section heading's rule is the
/// first one).
struct PrintRows<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
    }
}

extension View {
    /// A row of `PrintRows`: at least 40 high, a 1 px rule under it.
    func printRow() -> some View {
        frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Print.line).frame(height: 1) }
    }
}

// MARK: - Choices

/// A switch as a register line: `label ········ an  aus`, both words shown and the current one
/// chosen like `ChoiceWords`, so the line reads as a choice, not as a stray word. A click on a
/// word sets it, a click on the label toggles; VoiceOver gets a plain switch.
struct PrintToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        RegisterLine {
            Button { configuration.isOn.toggle() } label: { configuration.label }
                .buttonStyle(.plain)
                .focusable(false)
        } value: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Button { configuration.isOn = true } label: { Text("on") }
                    .buttonStyle(ChoiceWordStyle(chosen: configuration.isOn))
                Button { configuration.isOn = false } label: { Text("off") }
                    .buttonStyle(ChoiceWordStyle(chosen: !configuration.isOn))
            }
        }
        .contentShape(Rectangle())
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// A few alternatives as words (30 · 60 · 90): the chosen one in the text colour with a brass
/// underline, the others secondary, brass on hover; muted when disabled.
struct ChoiceWords<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> Text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: { label(option) }
                    .buttonStyle(ChoiceWordStyle(chosen: option == selection))
                    .accessibilityAddTraits(option == selection ? .isSelected : [])
            }
        }
    }
}

struct ChoiceWordStyle: ButtonStyle {
    let chosen: Bool

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, chosen: chosen)
    }

    private struct Styled: View {
        let configuration: ButtonStyleConfiguration
        let chosen: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(Print.text(16))
                .foregroundStyle(color)
                .padding(.bottom, 1)
                .overlay(alignment: .bottom) {
                    if chosen {
                        Rectangle().fill(enabled ? Print.brass : Print.lineStrong).frame(height: 1)
                    }
                }
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(Print.hover, value: hovering)
                .printFocus()
        }

        private var color: Color {
            if chosen { return enabled ? Print.textPrimary : Print.textSecondary }
            if !enabled { return Print.textMuted }
            return hovering || configuration.isPressed ? Print.brass : Print.textSecondary
        }
    }
}

/// Many alternatives as a text with ▾ that opens a menu of them (the macOS menu).
struct PrintMenu<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> Text

    var body: some View {
        Menu {
            Picker(selection: $selection) {
                ForEach(options, id: \.self) { label($0).tag($0) }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                label(selection)
                Text(verbatim: "▾").foregroundStyle(Print.brass).accessibilityHidden(true)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(TextActionStyle(size: 16, marked: false))
        .fixedSize()
    }
}

// MARK: - Fields and actions

/// A text field: `bg-base`, 1 px `lineInput`, radius 2, the inner shadow, Garamond 16 (or the font
/// given, mono for paths and variables).
struct PrintFieldStyle: TextFieldStyle {
    var font: Font = Print.text(16)

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(Print.textPrimary)
            .padding(.horizontal, 8)
            .frame(minHeight: 32)
            .background(Print.bgBase, in: RoundedRectangle(cornerRadius: 2))
            .overlay(alignment: .top) {
                Rectangle().fill(Color.black.opacity(0.4)).frame(height: 1).padding(.horizontal, 1).padding(.top, 1)
            }
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Print.lineInput, lineWidth: 1))
    }
}

/// A page's own action ("Spiel hinzufügen …", "Importieren"): a 1 px framed rectangle, Garamond
/// 16, brass on hover. A destructive one is set in the danger colour. The accent stays the main
/// action's alone.
struct FrameActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }

    private struct Styled: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(Print.text(16))
                .foregroundStyle(textColor)
                .padding(.horizontal, 16)
                .frame(minHeight: 32)
                .background(configuration.isPressed ? Print.bgSunken : Color.clear)
                .overlay(Rectangle().strokeBorder(borderColor, lineWidth: 1))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(Print.hover, value: hovering)
                .printFocus()
        }

        private var textColor: Color {
            if !enabled { return Print.textMuted }
            if configuration.role == .destructive { return Print.danger }
            return hovering ? Print.brass : Print.textPrimary
        }

        private var borderColor: Color {
            if !enabled { return Print.line }
            return hovering ? Print.brass : Print.lineStrong
        }
    }
}

/// Progress as a 1 px brass rule over a `line` track; without a fraction a short segment runs
/// along it (still with Reduce Motion).
struct PrintProgress: View {
    let fraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Print.line)
                if let fraction {
                    Rectangle().fill(Print.brass)
                        .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                } else if reduceMotion {
                    Rectangle().fill(Print.brass).opacity(0.4)
                } else {
                    TimelineView(.animation) { timeline in
                        let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                        Rectangle().fill(Print.brass)
                            .frame(width: proxy.size.width * 0.2)
                            .offset(x: proxy.size.width * (phase * 1.2 - 0.2))
                    }
                }
            }
        }
        .frame(height: 1)
        .clipped()
        .accessibilityElement()
        .accessibilityValue(fraction.map { Text("\(Int($0 * 100)) %") } ?? Text("…"))
    }
}

// MARK: - Dialogs

/// A dialog (a sheet over the window) in the print style: `bg-base`, inset 32, a Cormorant 28
/// title, the content, and the actions at the bottom right.
struct PrintDialog<Content: View, Actions: View>: View {
    let title: Text
    var width: CGFloat = 480
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            title
                .font(Print.display(28))
            content
            HStack(spacing: 16) {
                Spacer()
                actions
            }
            .buttonStyle(FrameActionStyle())
            .padding(.top, 8)
        }
        .padding(32)
        .frame(width: width, alignment: .leading)
        .background(Print.bgBase)
        .foregroundStyle(Print.textPrimary)
        .font(Print.text())
        .toggleStyle(PrintToggleStyle())
        .textFieldStyle(PrintFieldStyle())
    }
}
