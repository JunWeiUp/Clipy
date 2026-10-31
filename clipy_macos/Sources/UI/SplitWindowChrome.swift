import AppKit
import SwiftUI

/// V3 (V1 visual) chrome shared by the snippet library and phone notification
/// windows: full-height translucent-looking sidebar holding the traffic lights,
/// a 52pt unified toolbar and the `UI/design-v3/mac.css` control styles.
enum SplitV3Color {
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    private static func white(_ value: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(calibratedWhite: value, alpha: alpha)
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    /// --m-side
    static let sidebar = dynamic(light: rgb(240, 241, 245), dark: rgb(40, 40, 46))
    /// --m-bg
    static let content = dynamic(light: .white, dark: rgb(30, 30, 33))
    /// --m-bg-2
    static let inspector = dynamic(light: rgb(247, 247, 249), dark: rgb(26, 26, 29))
    /// Detail card on the inspector background.
    static let card = dynamic(light: .white, dark: rgb(35, 35, 38))
    /// --m-tool
    static let toolbar = dynamic(light: white(1, 0.86), dark: rgb(34, 34, 38, 0.88))
    /// --m-line
    static let line = dynamic(light: white(0, 0.08), dark: white(1, 0.09))
    /// --m-text-2 / --m-text-3
    static let text2 = dynamic(light: rgb(29, 29, 31, 0.66), dark: rgb(242, 242, 245, 0.66))
    static let text3 = dynamic(light: rgb(29, 29, 31, 0.42), dark: rgb(242, 242, 245, 0.40))
    /// --m-fill / --m-fill-2
    static let fill = dynamic(light: white(0, 0.045), dark: white(1, 0.06))
    static let fill2 = dynamic(light: white(0, 0.07), dark: white(1, 0.10))
    /// --m-ctrl / --m-ctrl-line
    static let control = dynamic(light: .white, dark: white(1, 0.08))
    static let controlLine = dynamic(light: white(0, 0.12), dark: white(1, 0.10))
    /// --m-sel (soft accent selection)
    static var selection: Color { AppColor.accent.opacity(0.13) }
    static let danger = Color(nsColor: .systemRed)

    /// Avatar tints cycled per app (light / dark pairs from the design).
    private static let tints: [(NSColor, NSColor)] = [
        (rgb(227, 244, 234), rgb(31, 58, 42)), (rgb(230, 238, 255), rgb(31, 43, 71)),
        (rgb(255, 240, 224), rgb(61, 46, 28)), (rgb(243, 232, 255), rgb(51, 36, 74)),
        (rgb(255, 232, 236), rgb(63, 34, 41)),
    ]

    /// Stable tint for a key (package name) so an app keeps its colour across reloads.
    static func avatarTint(for key: String) -> Color {
        var hash: UInt32 = 5381
        for byte in key.utf8 { hash = (hash &* 33) &+ UInt32(byte) }
        let pair = tints[Int(hash % UInt32(tints.count))]
        return dynamic(light: pair.0, dark: pair.1)
    }
}

enum SplitV3Metrics {
    static let toolbarHeight: CGFloat = 52
    /// Space the window's traffic lights occupy at the top of the sidebar.
    static let trafficLightInset: CGFloat = 52
}

/// Unified toolbar strip (`.tbar`): 52pt high with a hairline below.
struct SplitV3Toolbar<Content: View>: View {
    var leading: CGFloat = 18
    var trailing: CGFloat = 14
    var transparent = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 10) { content() }
            .padding(.leading, leading)
            .padding(.trailing, trailing)
            .frame(maxWidth: .infinity, minHeight: SplitV3Metrics.toolbarHeight,
                   maxHeight: SplitV3Metrics.toolbarHeight, alignment: .leading)
            .background(transparent ? Color.clear : SplitV3Color.toolbar)
            .overlay(alignment: .bottom) {
                if !transparent { SplitV3Hairline() }
            }
    }
}

/// Vertical / horizontal hairline matching `--m-line`.
struct SplitV3Hairline: View {
    var vertical = false
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        let width = 1 / max(displayScale, 1)
        SplitV3Color.line.frame(width: vertical ? width : nil, height: vertical ? nil : width)
    }
}

/// `.sw`: 32×19 accent switch that stays blue in inactive windows like the design.
struct SplitV3SwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? AppColor.accent : SplitV3Color.fill2)
                    .overlay(Capsule().strokeBorder(SplitV3Color.controlLine, lineWidth: 0.5))
                Circle().fill(Color.white).frame(width: 15, height: 15)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                    .padding(2)
            }
            .frame(width: 32, height: 19)
            .animation(.easeOut(duration: 0.15), value: configuration.isOn)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// `.tbtn`: 28pt square-ish borderless icon button with hover fill.
struct SplitV3IconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14))
            .foregroundStyle(SplitV3Color.text2)
            .padding(.horizontal, 7)
            .frame(minWidth: 28, minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(
                configuration.isPressed ? SplitV3Color.fill2 : (hovered && isEnabled ? SplitV3Color.fill : .clear)))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovered = $0 }
    }
}

/// `.btn` / `.btn.primary` / `.btn.danger`.
struct SplitV3ButtonStyle: ButtonStyle {
    enum Kind { case normal, primary, danger }
    var kind: Kind = .normal
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .labelStyle(SplitV3ButtonLabelStyle())
            .foregroundStyle(kind == .primary ? Color.white : (kind == .danger ? SplitV3Color.danger : Color.primary))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(kind == .primary ? AppColor.accent : SplitV3Color.control)
                    .shadow(color: kind == .primary ? AppColor.accent.opacity(0.35) : .black.opacity(0.06),
                            radius: kind == .primary ? 1 : 0.75, y: kind == .primary ? 1 : 0.5)
            }
            .overlay {
                if kind != .primary {
                    RoundedRectangle(cornerRadius: 7).strokeBorder(SplitV3Color.controlLine, lineWidth: 0.5)
                }
            }
            .brightness(configuration.isPressed ? -0.06 : 0)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

private struct SplitV3ButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 12, weight: .medium))
            configuration.title
        }
    }
}

/// `.search`: filled 30pt field with a magnifier and clear button.
struct SplitV3SearchField: View {
    let placeholder: String
    @Binding var text: String
    var onChange: (() -> Void)? = nil
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium))
                .foregroundStyle(SplitV3Color.text3)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onChange(of: text) { _ in onChange?() }
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(SplitV3Color.text3)
                    .help(L10n.t(.clear)).accessibilityLabel(L10n.t(.clear))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(focused ? SplitV3Color.content : SplitV3Color.fill))
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: 8).strokeBorder(AppColor.accent, lineWidth: 1)
                    .shadow(color: AppColor.accent.opacity(0.25), radius: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }
}

/// Count pill (`.cbadge` / `.cnt.nb`).
struct SplitV3CountPill: View {
    let count: Int
    var body: some View {
        Text("\(count)")
            .font(.system(size: 11, weight: .medium)).monospacedDigit()
            .foregroundStyle(SplitV3Color.text2)
            .padding(.horizontal, 7).padding(.vertical, 1)
            .background(Capsule().fill(SplitV3Color.fill))
    }
}
