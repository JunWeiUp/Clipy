import AppKit
import SwiftUI

enum AppSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24
    static let section: CGFloat = 28
}

enum AppFont {
    static let captionSize: CGFloat = 11
    static let bodySize: CGFloat = 13
    static let secondarySize: CGFloat = 12
    static let emptyStateSize: CGFloat = 16

    static var caption: Font { .system(size: captionSize) }
    static var body: Font { .system(size: bodySize) }
    static var secondary: Font { .system(size: secondarySize) }
    static var emptyState: Font { .system(size: emptyStateSize) }
    static var title: Font { .system(size: 20, weight: .semibold) }
    static var section: Font { .system(size: 13, weight: .semibold) }
}

// MARK: - Crash-safe AppKit text attributes

extension AppFont {
    /// AppKit's font factories are imported as non-optional but can still hand back nil —
    /// `monospacedSystemFont` resolves the hidden `.AppleSystemUIFontMonospaced` asset and
    /// fails on some machines. Swift lets that nil into an attribute dictionary and CoreText
    /// aborts the process while laying out the string, so route every dictionary through here.
    static func textAttributes(
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        monospaced: Bool = false,
        color: NSColor?
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let font = resolveFont(size: size, weight: weight, monospaced: monospaced) {
            attributes[.font] = font
        }
        if let color {
            attributes[.foregroundColor] = color
        }
        return attributes
    }

    /// Adds `.font`/`.foregroundColor` only when they actually resolved.
    static func attributes(font: NSFont?, color: NSColor?) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let font { attributes[.font] = font }
        if let color { attributes[.foregroundColor] = color }
        return attributes
    }

    static func resolveFont(size: CGFloat, weight: NSFont.Weight = .regular, monospaced: Bool = false) -> NSFont? {
        if monospaced {
            return firstResolved(
                // Proportional metrics with tabular digits — same alignment benefit for
                // numeric readouts without depending on the monospaced font asset.
                NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
                NSFont.monospacedSystemFont(ofSize: size, weight: weight),
                NSFont(name: "Menlo", size: size),
                NSFont.systemFont(ofSize: size)
            )
        }
        return firstResolved(
            NSFont.systemFont(ofSize: size, weight: weight),
            NSFont.systemFont(ofSize: size),
            NSFont(name: "Helvetica", size: size)
        )
    }

    private static func firstResolved(_ candidates: NSFont?...) -> NSFont? {
        candidates.first { $0 != nil } ?? nil
    }
}

enum AppRowHeight {
    static let compact: CGFloat = 30
    static let standard: CGFloat = 40
    static let group: CGFloat = 44
}

enum AppCornerRadius {
    static let small: CGFloat = 6
    static let medium: CGFloat = 8
    static let large: CGFloat = 12
    static let badge: CGFloat = 10
}

enum ScreenshotChrome {
    static let toolbarHeight: CGFloat = 44
    static let barHeight: CGFloat = 40
    static let secondaryBarHeight: CGFloat = 32
    static let floatingRadius: CGFloat = 12
    static let magnifierSize: CGFloat = 120
    static let snapThreshold: CGFloat = 8
    static let presetColors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue]
}

enum AppWindowSize {
    static let settings = CGSize(width: 760, height: 620)
    static let settingsMin = CGSize(width: 660, height: 480)
    static let screenshotSettings = CGSize(width: 800, height: 680)
    static let list = CGSize(width: 720, height: 500)
    static let search = CGSize(width: 1080, height: 720)
    static let editor = CGSize(width: 1120, height: 720)
    static let log = CGSize(width: 800, height: 500)
    static let passwordGenerator = CGSize(width: 460, height: 520)
    static let passwordGeneratorMin = CGSize(width: 420, height: 470)
    static let listMin = CGSize(width: 480, height: 320)
    static let searchMin = CGSize(width: 800, height: 520)
    static let notificationMin = CGSize(width: 560, height: 360)
    static let editorMin = CGSize(width: 920, height: 540)
}
