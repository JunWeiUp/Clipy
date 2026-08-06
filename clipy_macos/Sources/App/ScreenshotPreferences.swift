import AppKit
import CoreGraphics
import Foundation

/// Screenshot-related preference enums.
///
/// These describe user-facing screenshot settings (capture mode, post-capture
/// action, OCR language, resolution) consumed by `PreferencesManager` and the
/// screenshot settings UI. They were extracted from the legacy `ScreenshotTypes`
/// file (now deleted along with the old capture pipeline); the new screenshot
/// module under `Sources/Screenshot/` carries its own tool/coordinate types.

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
