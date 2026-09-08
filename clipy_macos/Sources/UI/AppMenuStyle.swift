import AppKit

/// Native menu rows preserve keyboard navigation, accessibility and selection.
/// Keep their metrics stable while thumbnails and devices arrive asynchronously.
enum AppMenuStyle {
    static func menu() -> NSMenu {
        let menu = NSMenu()
        configure(menu)
        return menu
    }

    static func configure(_ menu: NSMenu) {
        menu.font = NSFont.systemFont(ofSize: AppFont.bodySize)
        menu.minimumWidth = 280
        menu.autoenablesItems = false
    }

    static func icon(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        image?.size = NSSize(width: 16, height: 16)
        image?.isTemplate = true
        return image
    }

    static func compactTitle(_ text: String) -> String {
        let line = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let attributes = AppFont.textAttributes(size: AppFont.bodySize, color: nil)
        let candidate = String(line.prefix(80))
        if candidate == line, (candidate as NSString).size(withAttributes: attributes).width <= 280 { return line }
        var result = ""
        for character in candidate {
            let next = result + String(character)
            if ((next + "…") as NSString).size(withAttributes: attributes).width > 280 { break }
            result = next
        }
        return result + "…"
    }

    static func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return .sectionHeader(title: title) }
        let item = detail(title)
        item.attributedTitle = NSAttributedString(string: title, attributes: AppFont.textAttributes(size: 11, weight: .semibold, color: .secondaryLabelColor))
        return item
    }

    static func detail(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    static func applyShortcut(_ combo: ShortcutCombo?, to item: NSMenuItem) {
        guard let combo else { return }
        item.toolTip = "\(item.title) (\(combo.displayString))"
        let label = String(combo.displayString.suffix(1))
        let special = ["⏎": "\r", "⇥": "\t", "␣": " ", "⌫": "\u{8}", "⎋": "\u{1b}"]
        guard label != "?" else { return }
        item.keyEquivalent = special[label] ?? label.lowercased()
        item.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: combo.modifierFlags)
            .intersection([.command, .option, .control, .shift])
    }
}
