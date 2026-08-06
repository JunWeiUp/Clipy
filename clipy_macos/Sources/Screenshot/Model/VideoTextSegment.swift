import Foundation
import CoreGraphics

/// A timeline region that overlays text on the video. Mirrors the temporal
/// model used by `VideoCensorSegment`: `startTime`/`endTime` are seconds on
/// the source-asset clock and `rect` is normalized to the natural-image
/// bounds (origin top-left).
///
/// Style is intentionally simpler than the screenshot text tool: one system
/// font, weight (regular/bold), italic toggle, color, optional background
/// fill, alignment, fade in/out. Per-character formatting is deliberately
/// not supported — video labels are visually consistent strings.
final class VideoTextSegment: Codable {

    static let minDuration: Double = 0.3
    static let defaultFade: Double = 0.25

    enum BackgroundStyle: String, Codable {
        case none      // text only (with optional shadow)
        case solid     // filled rectangle behind text
        case rounded   // pill — filled rounded rectangle behind text
    }

    enum Alignment: String, Codable {
        case left, center, right
    }

    /// RGBA in 0...1. Stored as four Doubles so encode/decode is plain JSON
    /// without NSColor secure-coding overhead. Same shape as the Codable
    /// pattern used for screenshot annotations (`AnnotationCodable`).
    struct RGBA: Codable, Hashable {
        var r: Double
        var g: Double
        var b: Double
        var a: Double

        static let white = RGBA(r: 1, g: 1, b: 1, a: 1)
        static let blackTransparent = RGBA(r: 0, g: 0, b: 0, a: 0.7)
    }

    var id: UUID
    var startTime: Double
    var endTime: Double
    var rect: CGRect

    var text: String

    /// Logical font size in *points at 1080p reference height*. The
    /// rasterizer scales it to the actual render-pixel height when drawing
    /// so 48pt looks the same on a 720p export and a 4K export.
    var fontSize: CGFloat
    var bold: Bool
    var italic: Bool

    var textColor: RGBA
    var bgStyle: BackgroundStyle
    var bgColor: RGBA

    var alignment: Alignment

    var fadeIn: Double
    var fadeOut: Double

    init(id: UUID = UUID(),
         startTime: Double,
         endTime: Double,
         rect: CGRect = CGRect(x: 0.1, y: 0.78, width: 0.8, height: 0.14),
         text: String = "Text",
         fontSize: CGFloat = 48,
         bold: Bool = true,
         italic: Bool = false,
         textColor: RGBA = .white,
         bgStyle: BackgroundStyle = .rounded,
         bgColor: RGBA = .blackTransparent,
         alignment: Alignment = .center,
         fadeIn: Double = defaultFade,
         fadeOut: Double = defaultFade) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.rect = VideoTextSegment.clampedRect(rect)
        self.text = text
        self.fontSize = fontSize
        self.bold = bold
        self.italic = italic
        self.textColor = textColor
        self.bgStyle = bgStyle
        self.bgColor = bgColor
        self.alignment = alignment
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }

    var duration: Double { max(0, endTime - startTime) }

    /// See `VideoCensorSegment.autoFade(for:)` — same formula for consistency.
    static func autoFade(for duration: Double) -> Double {
        let capByDuration = max(0.05, duration * 0.20)
        return min(defaultFade, capByDuration)
    }

    var effectiveFadeIn: Double {
        let cap = max(0, duration / 2 - 0.001)
        return min(max(fadeIn, 0), cap)
    }
    var effectiveFadeOut: Double {
        let cap = max(0, duration / 2 - 0.001)
        return min(max(fadeOut, 0), cap)
    }

    /// Opacity at time `t` (source-asset clock). Eased ramp on the fade
    /// edges, plateau at 1.0, zero outside the segment. Same curve as
    /// `VideoCensorSegment.opacity(at:)` so multiple fading effects share
    /// a consistent visual rhythm.
    func opacity(at t: Double) -> CGFloat {
        guard t >= startTime, t <= endTime, duration > 0 else { return 0 }
        let fIn = effectiveFadeIn
        let fOut = effectiveFadeOut
        let into = t - startTime
        let toEnd = endTime - t

        if into < fIn, fIn > 0 {
            return easeInOut(CGFloat(into / fIn))
        } else if toEnd < fOut, fOut > 0 {
            return easeInOut(CGFloat(toEnd / fOut))
        } else {
            return 1.0
        }
    }

    private func easeInOut(_ x: CGFloat) -> CGFloat {
        let c = max(0, min(1, x))
        return c * c * (3 - 2 * c)
    }

    /// Keep the rect fully inside the normalized video bounds and prevent
    /// degenerate sizes that would crash the rasterizer with a zero-pixel
    /// canvas.
    static func clampedRect(_ r: CGRect) -> CGRect {
        let minSize: CGFloat = 0.04
        var x = max(0, min(1 - minSize, r.origin.x))
        var y = max(0, min(1 - minSize, r.origin.y))
        var w = max(minSize, min(1 - x, r.size.width))
        var h = max(minSize, min(1 - y, r.size.height))
        if x + w > 1 { x = 1 - w }
        if y + h > 1 { y = 1 - h }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
