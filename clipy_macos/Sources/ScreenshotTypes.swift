import AppKit
import CoreGraphics
import Foundation

enum ScreenshotCaptureMode: String, Codable, CaseIterable, Identifiable {
    case region
    case window
    case fullscreen

    var id: String { rawValue }
}

enum ScreenshotResolution: String, CaseIterable, Identifiable, Codable {
    case auto
    case dpi72
    case dpi96
    case dpi144
    case dpi216
    case dpi300

    var id: String { rawValue }

    static var `default`: ScreenshotResolution { .auto }

    static func fromLegacyDPI(_ dpi: Int) -> ScreenshotResolution? {
        switch dpi {
        case 72: return .dpi72
        case 96: return .dpi96
        case 144: return .dpi144
        case 216: return .dpi216
        case 300: return .dpi300
        default: return nil
        }
    }

    func displayName() -> String {
        switch self {
        case .auto: return L10n.t(.screenshotResolutionAuto)
        case .dpi72: return L10n.format(.screenshotResolutionOption, 72)
        case .dpi96: return L10n.format(.screenshotResolutionOption, 96)
        case .dpi144: return L10n.format(.screenshotResolutionOption, 144)
        case .dpi216: return L10n.format(.screenshotResolutionOption, 216)
        case .dpi300: return L10n.format(.screenshotResolutionOption, 300)
        }
    }

    /// Pixel density relative to the default 72 DPI baseline.
    func pixelScale(for screen: NSScreen?, displayNativeScale: CGFloat? = nil) -> CGFloat {
        switch self {
        case .auto:
            return displayNativeScale ?? screen?.backingScaleFactor ?? 1
        case .dpi72: return 1
        case .dpi96: return 96.0 / 72.0
        case .dpi144: return 144.0 / 72.0
        case .dpi216: return 216.0 / 72.0
        case .dpi300: return 300.0 / 72.0
        }
    }

    var prefersNominalCapture: Bool { self == .dpi72 }
}

enum ScreenshotAnnotationTool: String, CaseIterable, Identifiable {
    case selection
    case rectangle
    case arrow
    case ellipse
    case text
    case pencil
    case highlighter
    case eraser
    case mosaic

    var id: String { rawValue }

    static var annotationTools: [ScreenshotAnnotationTool] {
        allCases.filter { $0 != .selection }
    }

    var isAnnotationTool: Bool { self != .selection }

    var systemImage: String {
        switch self {
        case .selection: return "arrow.up.left.and.arrow.down.right"
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
        case .selection: return 3
        case .highlighter: return 8
        case .eraser: return 12
        default: return 3
        }
    }
}

enum ScreenshotCoordinateConverter {
    static func cgPoint(from nsPoint: NSPoint) -> CGPoint {
        cgRect(from: NSRect(origin: nsPoint, size: .zero)).origin
    }

    static func cgRect(from nsRect: NSRect) -> CGRect {
        let reference = NSPoint(x: nsRect.midX, y: nsRect.midY)
        guard let screen = screen(containingCocoa: reference) ?? NSScreen.main,
              let displayID = displayID(for: screen) else {
            return legacyCgRect(from: nsRect)
        }

        let displayBounds = displayBoundsInPoints(for: screen, displayID: displayID)
        let localX = nsRect.origin.x - screen.frame.origin.x
        let localY = nsRect.origin.y - screen.frame.origin.y
        let localQuartzY = screen.frame.height - localY - nsRect.height

        return CGRect(
            x: displayBounds.origin.x + localX,
            y: displayBounds.origin.y + localQuartzY,
            width: nsRect.width,
            height: nsRect.height
        )
    }

    static func nsRect(from cgRect: CGRect) -> NSRect {
        let reference = CGPoint(x: cgRect.midX, y: cgRect.midY)
        guard let screen = screen(containingQuartz: reference) ?? NSScreen.main,
              let displayID = displayID(for: screen) else {
            return legacyNsRect(from: cgRect)
        }

        let displayBounds = displayBoundsInPoints(for: screen, displayID: displayID)
        let localQuartzX = cgRect.origin.x - displayBounds.origin.x
        let localQuartzY = cgRect.origin.y - displayBounds.origin.y
        let localCocoaY = screen.frame.height - localQuartzY - cgRect.height

        return NSRect(
            x: screen.frame.origin.x + localQuartzX,
            y: screen.frame.origin.y + localCocoaY,
            width: cgRect.width,
            height: cgRect.height
        )
    }

    private static func screen(containingCocoa point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    private static func screen(containingQuartz point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let displayID = displayID(for: screen) else { return false }
            return displayBoundsInPoints(for: screen, displayID: displayID).contains(point)
        }
    }

    private static func displayBoundsInPoints(for screen: NSScreen, displayID: CGDirectDisplayID) -> CGRect {
        let bounds = CGDisplayBounds(displayID)
        let scale = max(screen.backingScaleFactor, 1)
        return CGRect(
            x: bounds.origin.x / scale,
            y: bounds.origin.y / scale,
            width: bounds.width / scale,
            height: bounds.height / scale
        )
    }

    /// Map a Cocoa selection rect to pixel coordinates inside a captured display image.
    static func pixelCropRect(
        from selection: NSRect,
        displayFrame: CGRect,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> CGRect {
        let scaleX = CGFloat(pixelWidth) / max(displayFrame.width, 1)
        let scaleY = CGFloat(pixelHeight) / max(displayFrame.height, 1)
        let localX = selection.minX - displayFrame.minX
        let localY = selection.minY - displayFrame.minY
        let cropX = localX * scaleX
        let cropY = CGFloat(pixelHeight) - (localY + selection.height) * scaleY
        let cropW = selection.width * scaleX
        let cropH = selection.height * scaleY

        var crop = CGRect(x: cropX, y: cropY, width: cropW, height: cropH).integral
        crop.origin.x = max(0, crop.origin.x)
        crop.origin.y = max(0, crop.origin.y)
        crop.size.width = min(CGFloat(pixelWidth) - crop.origin.x, crop.width)
        crop.size.height = min(CGFloat(pixelHeight) - crop.origin.y, crop.height)
        return crop
    }

    /// Display-relative capture rect in ScreenCaptureKit coordinates.
    static func displayRelativeRect(from selection: NSRect, displayFrame: CGRect) -> CGRect {
        CGRect(
            x: selection.minX - displayFrame.minX,
            y: selection.minY - displayFrame.minY,
            width: selection.width,
            height: selection.height
        )
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    private static func legacyCgRect(from nsRect: NSRect) -> CGRect {
        let maxY = NSScreen.screens.map(\.frame.maxY).max() ?? nsRect.maxY
        return CGRect(
            x: nsRect.origin.x,
            y: maxY - nsRect.origin.y - nsRect.height,
            width: nsRect.width,
            height: nsRect.height
        )
    }

    private static func legacyNsRect(from cgRect: CGRect) -> NSRect {
        let maxY = NSScreen.screens.map(\.frame.maxY).max() ?? cgRect.maxY
        return NSRect(
            x: cgRect.origin.x,
            y: maxY - cgRect.origin.y - cgRect.height,
            width: cgRect.width,
            height: cgRect.height
        )
    }
}

struct ScreenshotToolbarPlacement {
    let toolbarFrame: NSRect
    let toolbarOnTop: Bool

    static func compute(
        screenRect: NSRect,
        barHeight: CGFloat,
        minPanelWidth: CGFloat
    ) -> ScreenshotToolbarPlacement {
        let panelWidth = max(screenRect.width, minPanelWidth)
        let screen = NSScreen.screens.first { $0.frame.intersects(screenRect) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? screenRect

        var originX = screenRect.midX - panelWidth / 2
        originX = max(visible.minX, min(originX, visible.maxX - panelWidth))

        let belowY = screenRect.origin.y - barHeight
        if belowY >= visible.minY {
            return ScreenshotToolbarPlacement(
                toolbarFrame: NSRect(x: originX, y: belowY, width: panelWidth, height: barHeight),
                toolbarOnTop: false
            )
        }

        return ScreenshotToolbarPlacement(
            toolbarFrame: NSRect(x: originX, y: screenRect.maxY, width: panelWidth, height: barHeight),
            toolbarOnTop: true
        )
    }
}
