import AppKit
import SwiftUI

enum AppSpacing {
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
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
}

enum AppRowHeight {
    static let compact: CGFloat = 28
    static let standard: CGFloat = 36
    static let group: CGFloat = 40
}

enum AppCornerRadius {
    static let small: CGFloat = 4
    static let badge: CGFloat = 10
}

enum ScreenshotChrome {
    static let toolbarHeight: CGFloat = 44
    static let barHeight: CGFloat = 40
    static let floatingRadius: CGFloat = 12
    static let magnifierSize: CGFloat = 120
    static let snapThreshold: CGFloat = 8
    static let presetColors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue]
}

enum AppWindowSize {
    static let settings = CGSize(width: 420, height: 720)
    static let list = CGSize(width: 720, height: 500)
    static let search = CGSize(width: 1200, height: 800)
    static let editor = CGSize(width: 800, height: 600)
    static let log = CGSize(width: 800, height: 500)
    static let listMin = CGSize(width: 480, height: 320)
    static let searchMin = CGSize(width: 800, height: 680)
    static let notificationMin = CGSize(width: 560, height: 360)
    static let editorMin = CGSize(width: 640, height: 480)
}
