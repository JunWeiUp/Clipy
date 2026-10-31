import AppKit
import SwiftUI

/// V3 (`UI/design-v3/screens/mac-history.html`) visual tokens and small
/// components used only by the clipboard-history window.
enum HistoryV3 {
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static func rgba(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    static let brand = Color(nsColor: rgba(0x0A6CFF))
    static let listBackground = dynamic(rgba(0xFFFFFF), rgba(0x1E1E21))
    static let previewBackground = dynamic(rgba(0xF7F7F9), rgba(0x1A1A1D))
    static let card = dynamic(rgba(0xFFFFFF), rgba(0x232326))
    static let sidebar = dynamic(rgba(0xF0F1F5, 0.82), rgba(0x28282E, 0.80))
    static let line = dynamic(rgba(0x000000, 0.08), rgba(0xFFFFFF, 0.09))
    static let text = dynamic(rgba(0x1D1D1F), rgba(0xF2F2F5))
    static let text2 = dynamic(rgba(0x1D1D1F, 0.66), rgba(0xF2F2F5, 0.66))
    static let text3 = dynamic(rgba(0x1D1D1F, 0.42), rgba(0xF2F2F5, 0.40))
    static let fill = dynamic(rgba(0x000000, 0.045), rgba(0xFFFFFF, 0.06))
    static let fill2 = dynamic(rgba(0x000000, 0.07), rgba(0xFFFFFF, 0.10))
    static let selection = dynamic(rgba(0x0A6CFF, 0.11), rgba(0x3D8BFF, 0.22))
    static let control = dynamic(rgba(0xFFFFFF), rgba(0xFFFFFF, 0.08))
    static let controlLine = dynamic(rgba(0x000000, 0.12), rgba(0xFFFFFF, 0.10))
    static let warn = dynamic(rgba(0xD97706), rgba(0xFBBF24))
    static let mark = Color(nsColor: rgba(0xFFCC00, 0.35))

    /// Bilingual strings that only this window uses (kept out of the shared
    /// localization table to avoid churn there).
    static func s(_ zh: String, _ en: String) -> String {
        PreferencesManager.shared.appLanguage == .zh ? zh : en
    }
}

/// Coloured content-type family (`.ticon` / `.tag` in the design).
enum HistoryKind {
    case text, link, code, rich, image, file

    var tint: Color {
        switch self {
        case .text: return HistoryV3.dynamic(HistoryV3.rgba(0x0A6CFF), HistoryV3.rgba(0x5EA1FF))
        case .link: return HistoryV3.dynamic(HistoryV3.rgba(0x0E9F8E), HistoryV3.rgba(0x3CCFBC))
        case .image: return HistoryV3.dynamic(HistoryV3.rgba(0xC2410C), HistoryV3.rgba(0xFB923C))
        case .file: return HistoryV3.dynamic(HistoryV3.rgba(0x7C3AED), HistoryV3.rgba(0xB794F6))
        case .code: return HistoryV3.dynamic(HistoryV3.rgba(0xBE185D), HistoryV3.rgba(0xF472B6))
        case .rich: return HistoryV3.dynamic(HistoryV3.rgba(0xA16207), HistoryV3.rgba(0xFACC15))
        }
    }

    var tintBackground: Color {
        switch self {
        case .text: return HistoryV3.dynamic(HistoryV3.rgba(0x0A6CFF, 0.12), HistoryV3.rgba(0x5EA1FF, 0.16))
        case .link: return HistoryV3.dynamic(HistoryV3.rgba(0x0E9F8E, 0.13), HistoryV3.rgba(0x3CCFBC, 0.15))
        case .image: return HistoryV3.dynamic(HistoryV3.rgba(0xEA580C, 0.13), HistoryV3.rgba(0xFB923C, 0.16))
        case .file: return HistoryV3.dynamic(HistoryV3.rgba(0x7C3AED, 0.12), HistoryV3.rgba(0xB794F6, 0.16))
        case .code: return HistoryV3.dynamic(HistoryV3.rgba(0xDB2777, 0.11), HistoryV3.rgba(0xF472B6, 0.15))
        case .rich: return HistoryV3.dynamic(HistoryV3.rgba(0xCA8A04, 0.14), HistoryV3.rgba(0xFACC15, 0.14))
        }
    }

    /// Classifies an entry from data already in memory (never reads disk).
    static func of(_ entry: HistoryEntry) -> (kind: HistoryKind, symbol: String, label: String) {
        switch entry.item {
        case .text(let value):
            let sample = String(value.prefix(4_000))
            let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = L10n.t(.historyTypeText)
            if trimmed.range(of: #"^https?://\S+$"#, options: .regularExpression) != nil {
                return (.link, "link", "\(text) · \(L10n.t(.historyCategoryURL))")
            }
            if HistoryPreviewSupport.resolvedTextKind(for: sample) == .json {
                return (.code, "curlybraces", "\(text) · \(L10n.t(.historyCategoryJSON))")
            }
            if HistoryContentCategory.code.matches(HistoryEntry(item: .text(sample), date: entry.date, sourceApp: nil, contentHash: nil)) {
                return (.code, "chevron.left.forwardslash.chevron.right", "\(text) · \(L10n.t(.historyCategoryCode))")
            }
            if trimmed.range(of: #"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                return (.text, "envelope", "\(text) · \(L10n.t(.historyCategoryEmail))")
            }
            return (.text, HistorySymbol.type, text)
        case .rtf:
            return (.rich, "doc.richtext", L10n.t(.historyFilterRichText))
        case .html:
            return (.rich, "doc.richtext", L10n.t(.historyFilterRichText))
        case .pdf:
            return (.rich, "doc.richtext", L10n.t(.historyTypePDF))
        case .image:
            return (.image, "photo", L10n.t(.historyTypeImage))
        case .files(let urls):
            let archive = ["zip", "rar", "7z", "gz", "tar", "tgz", "xz", "bz2"]
            let isArchive = urls.count == 1 && archive.contains(urls[0].pathExtension.lowercased())
            return (.file, isArchive ? "doc.zipper" : (urls.count > 1 ? "doc.on.doc" : "doc"), L10n.t(.historyTypeFile))
        }
    }
}

/// SF Symbol, except the Lucide "type" / "remove-formatting" glyphs which
/// have no stable SF equivalent (`textformat` renders localised text, e.g. 格式).
struct HistorySymbol: View {
    let name: String
    var size: CGFloat = 13
    var weight: Font.Weight = .regular

    static let type = "clipy.type"
    static let removeFormatting = "clipy.remove-formatting"

    var body: some View {
        switch name {
        case Self.type:
            Text("T").font(.system(size: size * 1.12, weight: weight == .regular ? .medium : weight))
                .frame(width: size * 1.15, height: size * 1.15)
        case Self.removeFormatting:
            Text("T").font(.system(size: size * 1.05, weight: .medium))
                .overlay(Rectangle().frame(width: size * 1.2, height: max(1, size * 0.11)).rotationEffect(.degrees(-45)))
                .frame(width: size * 1.15, height: size * 1.15)
        default:
            Image(systemName: name).font(.system(size: size, weight: weight))
        }
    }
}

/// 30×30 rounded type tile (`.ticon`).
struct HistoryTypeTile: View {
    let kind: HistoryKind
    let symbol: String
    var size: CGFloat = 30

    var body: some View {
        HistorySymbol(name: symbol, size: size * 0.45, weight: .medium)
            .foregroundStyle(kind.tint)
            .frame(width: size, height: size)
            .background(kind.tintBackground, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

/// Small coloured type badge (`.tag`).
struct HistoryTypeTag: View {
    let kind: HistoryKind
    let symbol: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            HistorySymbol(name: symbol, size: 10, weight: .semibold)
            Text(label).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(kind.tint)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(kind.tintBackground, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// Capsule filter chip (`.chip`).
struct HistoryChipStyle: ButtonStyle {
    var isOn: Bool
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isOn ? Color.white : HistoryV3.text2)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                Capsule().fill(isOn ? HistoryV3.brand : (hovered || configuration.isPressed ? HistoryV3.fill2 : HistoryV3.fill))
            )
            .contentShape(Capsule())
            .onHover { hovered = $0 }
    }
}

/// 28pt toolbar icon button (`.tbtn`); `isOn` keeps the filled state.
struct HistoryToolButtonStyle: ButtonStyle {
    var isOn = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14))
            .foregroundStyle(isOn ? HistoryV3.text : HistoryV3.text2)
            .opacity(isEnabled ? 1 : 0.4)
            .frame(minWidth: 28, minHeight: 28)
            .padding(.horizontal, 0)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isOn || (hovered && isEnabled) || configuration.isPressed ? HistoryV3.fill2 : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { hovered = $0 }
    }
}

/// Large push button (`.btn.lg`, optionally `.primary`).
struct HistoryActionButtonStyle: ButtonStyle {
    var primary = false
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: small ? 12 : 13.5, weight: .medium))
            .foregroundStyle(primary ? Color.white : HistoryV3.text)
            .padding(.horizontal, small ? 9 : 16)
            .frame(height: small ? 24 : 34)
            .background(
                RoundedRectangle(cornerRadius: small ? 6 : 9, style: .continuous)
                    .fill(primary ? HistoryV3.brand : HistoryV3.control)
                    .shadow(color: primary ? HistoryV3.brand.opacity(0.35) : .black.opacity(0.06), radius: 1, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: small ? 6 : 9, style: .continuous)
                    .strokeBorder(primary ? Color.clear : HistoryV3.controlLine, lineWidth: 0.5)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: small ? 6 : 9))
    }
}

/// Pops a native NSMenu at the mouse location; actions are retained closures.
final class HistoryPopupMenu: NSObject {
    struct Item {
        var title: String
        var isOn = false
        var isSeparator = false
        var action: () -> Void = {}
        static let separator = Item(title: "", isSeparator: true)
    }

    private var actions: [() -> Void] = []

    static func show(_ items: [Item]) {
        let target = HistoryPopupMenu()
        let menu = NSMenu()
        for item in items {
            if item.isSeparator { menu.addItem(.separator()); continue }
            let menuItem = NSMenuItem(title: item.title, action: #selector(run(_:)), keyEquivalent: "")
            menuItem.target = target
            menuItem.tag = target.actions.count
            menuItem.state = item.isOn ? .on : .off
            target.actions.append(item.action)
            menu.addItem(menuItem)
        }
        withExtendedLifetime(target) {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }
}

enum HistoryRowText {
    /// Builds a single-line-per-paragraph preview of `title` keeping the
    /// search highlight ranges (which index into `title`) aligned.
    static func highlighted(title: String, ranges: [Range<String.Index>], limit: Int = 160) -> AttributedString {
        let characters = Array(title)
        var leading = 0
        while leading < characters.count, characters[leading].isWhitespace { leading += 1 }
        let end = min(characters.count, leading + limit)
        let visible = characters[leading..<end].map { $0.isNewline ? " " : $0 }
        var attributed = AttributedString(String(visible) + (end < characters.count ? "…" : ""))
        for range in ranges {
            guard range.lowerBound >= title.startIndex, range.upperBound <= title.endIndex else { continue }
            let lower = title.distance(from: title.startIndex, to: range.lowerBound) - leading
            let upper = title.distance(from: title.startIndex, to: range.upperBound) - leading
            let clampedLower = max(0, lower), clampedUpper = min(visible.count, upper)
            guard clampedLower < clampedUpper else { continue }
            let start = attributed.index(attributed.startIndex, offsetByCharacters: clampedLower)
            let stop = attributed.index(attributed.startIndex, offsetByCharacters: clampedUpper)
            attributed[start..<stop].backgroundColor = HistoryV3.mark
        }
        return attributed
    }

    /// "今天 15:41" / "昨天 21:08" / "周二 10:12" / "10月12日 09:30".
    static func absolute(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = DateFormatter()
        time.locale = Locale(identifier: PreferencesManager.shared.appLanguage == .zh ? "zh_CN" : "en_US")
        time.dateFormat = "HH:mm"
        let clock = time.string(from: date)
        if calendar.isDateInToday(date) { return HistoryV3.s("今天 ", "Today ") + clock }
        if calendar.isDateInYesterday(date) { return HistoryV3.s("昨天 ", "Yesterday ") + clock }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day, days < 7 {
            time.dateFormat = PreferencesManager.shared.appLanguage == .zh ? "EEE HH:mm" : "EEE HH:mm"
            return time.string(from: date)
        }
        time.dateFormat = PreferencesManager.shared.appLanguage == .zh ? "M月d日 HH:mm" : "MMM d, HH:mm"
        return time.string(from: date)
    }
}
