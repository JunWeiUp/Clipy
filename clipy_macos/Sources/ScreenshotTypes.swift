import AppKit
import CoreGraphics
import Foundation

enum ScreenshotCaptureMode: String, Codable, CaseIterable, Identifiable {
    case region
    case window
    case fullscreen

    var id: String { rawValue }
}

/// Action performed automatically after a capture completes.
enum ScreenshotPostCaptureAction: String, CaseIterable, Identifiable, Codable {
    /// Copy to clipboard (and auto-save if enabled). Default behavior.
    case copy
    /// Pin the capture on top of the screen.
    case pin
    /// Run OCR and copy recognized text to the clipboard.
    case ocr
    /// Prompt the user for a save location.
    case saveAs

    var id: String { rawValue }

    static var `default`: ScreenshotPostCaptureAction { .copy }

    func displayName() -> String {
        switch self {
        case .copy: return L10n.t(.screenshotPostActionCopy)
        case .pin: return L10n.t(.screenshotPostActionPin)
        case .ocr: return L10n.t(.screenshotPostActionOCR)
        case .saveAs: return L10n.t(.screenshotPostActionSaveAs)
        }
    }
}

/// Languages used for OCR recognition.
enum ScreenshotOCRLanguage: String, CaseIterable, Identifiable, Codable {
    /// English only (legacy behavior, fastest).
    case english
    /// Simplified Chinese + English (recommended for Chinese users).
    case chineseEnglish
    /// Let the system auto-detect using all supported languages.
    case auto

    var id: String { rawValue }

    static var `default`: ScreenshotOCRLanguage { .chineseEnglish }

    /// BCP-47 language tags passed to `VNRecognizeTextRequest.recognitionLanguages`.
    var recognitionLanguages: [String] {
        switch self {
        case .english: return ["en-US"]
        case .chineseEnglish: return ["zh-Hans", "zh-Hans-CN", "en-US"]
        case .auto: return []
        }
    }

    func displayName() -> String {
        switch self {
        case .english: return L10n.t(.screenshotOCRLanguageEnglish)
        case .chineseEnglish: return L10n.t(.screenshotOCRLanguageChineseEnglish)
        case .auto: return L10n.t(.screenshotOCRLanguageAuto)
        }
    }
}

enum ScreenshotResolution: String, CaseIterable, Identifiable, Codable {
    /// Match the current screen's native backing scale (Retina-aware).
    case auto
    /// Always capture at native display pixels. Identical to `.auto` in practice, but
    /// exposed so users can explicitly lock to "no resampling ever".
    case native

    var id: String { rawValue }

    static var `default`: ScreenshotResolution { .auto }

    /// Legacy builds stored an integer DPI (72/96/144/216/300). All of them migrate to
    /// `.native` so users never get silently downsampled screenshots.
    static func fromLegacyDPI(_ dpi: Int) -> ScreenshotResolution? {
        switch dpi {
        case 72, 96, 144, 216, 300: return .native
        default: return nil
        }
    }

    func displayName() -> String {
        switch self {
        case .auto: return L10n.t(.screenshotResolutionAuto)
        case .native: return L10n.t(.screenshotResolutionNative)
        }
    }

    /// Both modes resolve to the display's native backing scale, so captures are never
    /// downsampled below real pixels or artificially upsampled above them.
    func pixelScale(for screen: NSScreen?, displayNativeScale: CGFloat? = nil) -> CGFloat {
        displayNativeScale ?? screen?.backingScaleFactor ?? 1
    }

    var prefersNominalCapture: Bool { false }
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

    /// Convert a CG-global rect into the display-local coordinate space used by
    /// ScreenCaptureKit (origin at the display's top-left, y pointing down).
    /// Both inputs must already be in the same CoreGraphics global space; the caller is
    /// responsible for turning an AppKit selection into CG space first (use `cgRect(from:)`).
    static func displayLocalTopDownRect(of cgRect: CGRect, displayFrame: CGRect) -> CGRect {
        CGRect(
            x: cgRect.minX - displayFrame.minX,
            y: cgRect.minY - displayFrame.minY,
            width: cgRect.width,
            height: cgRect.height
        )
    }

    /// Map a display-local top-down rect to pixel coordinates inside a captured display image.
    /// `localRect` must be relative to the display's top-left corner (CG convention),
    /// NOT AppKit global coords — convert first with `cgRect(from:)` then
    /// `displayLocalTopDownRect(of:displayFrame:)`.
    static func pixelCropRect(
        fromLocalRect localRect: CGRect,
        displayFrame: CGRect,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> CGRect {
        let scaleX = CGFloat(pixelWidth) / max(displayFrame.width, 1)
        let scaleY = CGFloat(pixelHeight) / max(displayFrame.height, 1)
        let cropX = localRect.minX * scaleX
        let cropY = localRect.minY * scaleY
        let cropW = localRect.width * scaleX
        let cropH = localRect.height * scaleY

        var crop = CGRect(x: cropX, y: cropY, width: cropW, height: cropH).integral
        crop.origin.x = max(0, crop.origin.x)
        crop.origin.y = max(0, crop.origin.y)
        crop.size.width = min(CGFloat(pixelWidth) - crop.origin.x, crop.width)
        crop.size.height = min(CGFloat(pixelHeight) - crop.origin.y, crop.height)
        return crop
    }

    /// Display-relative capture rect in ScreenCaptureKit coordinates (top-left origin, y-down).
    /// `localRect` must be relative to the display's top-left corner (CG convention).
    static func displayRelativeRect(fromLocalRect localRect: CGRect) -> CGRect {
        localRect
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
