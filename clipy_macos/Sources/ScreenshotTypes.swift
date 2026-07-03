import AppKit
import Foundation

enum ScreenshotCaptureMode: String, Codable, CaseIterable, Identifiable {
    case region
    case window
    case fullscreen

    var id: String { rawValue }
}

enum ScreenshotAnnotationTool: String, CaseIterable, Identifiable {
    case rectangle
    case arrow
    case ellipse
    case text
    case pencil
    case highlighter
    case eraser
    case mosaic

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .rectangle: return "rectangle"
        case .arrow: return "arrow.up.right"
        case .ellipse: return "oval"
        case .text: return "textformat"
        case .pencil: return "pencil"
        case .highlighter: return "highlighter"
        case .eraser: return "eraser"
        case .mosaic: return "square.grid.3x3.fill"
        }
    }

    var defaultLineWidth: CGFloat {
        switch self {
        case .highlighter: return 8
        case .eraser: return 12
        default: return 3
        }
    }
}

enum ScreenshotCoordinateConverter {
    static func cgRect(from nsRect: NSRect) -> CGRect {
        let maxY = NSScreen.screens.map(\.frame.maxY).max() ?? nsRect.maxY
        return CGRect(
            x: nsRect.origin.x,
            y: maxY - nsRect.origin.y - nsRect.height,
            width: nsRect.width,
            height: nsRect.height
        )
    }

    static func nsRect(from cgRect: CGRect) -> NSRect {
        let maxY = NSScreen.screens.map(\.frame.maxY).max() ?? cgRect.maxY
        return NSRect(
            x: cgRect.origin.x,
            y: maxY - cgRect.origin.y - cgRect.height,
            width: cgRect.width,
            height: cgRect.height
        )
    }
}
