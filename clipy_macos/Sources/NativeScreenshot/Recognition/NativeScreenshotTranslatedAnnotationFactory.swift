import AppKit
import CoreGraphics
import Foundation

enum NativeScreenshotTranslatedAnnotationError: Error {
    case mismatchedLineCount
}

/// Converts Vision's top-left image-pixel boxes directly into editable
/// annotations. Each text box paints its own opaque sampled background, so
/// selecting or moving a translation carries the cover with its editable text.
enum NativeScreenshotTranslatedAnnotationFactory {
    static func makeAnnotations(
        in image: CGImage,
        recognizedLines: [NativeScreenshotRecognizedText],
        translatedLines: [String]
    ) throws -> [NativeScreenshotAnnotation] {
        guard recognizedLines.count == translatedLines.count else {
            throw NativeScreenshotTranslatedAnnotationError.mismatchedLineCount
        }
        let canvas = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var result: [NativeScreenshotAnnotation] = []
        result.reserveCapacity(recognizedLines.count)
        for (line, translation) in zip(recognizedLines, translatedLines) {
            guard !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let region = placement(for: line.bounds, canvas: canvas) else { continue }
            let background = sampledBackground(in: image, around: region.sourceBounds)
            let foreground = readableForeground(over: background)
            let (fontSize, requiredHeight) = fittedText(
                translation, width: region.textWidth,
                sourceHeight: region.sourceBounds.height)
            let expandedHeight = min(canvas.maxY - region.backgroundRect.minY,
                                     max(region.backgroundRect.height, requiredHeight + 4))
            guard expandedHeight > 0 else { continue }
            let backgroundRect = CGRect(
                x: region.backgroundRect.minX, y: region.backgroundRect.minY,
                width: region.backgroundRect.width, height: expandedHeight)
            guard backgroundRect.width > 0, backgroundRect.height > 0 else { continue }
            result.append(NativeScreenshotAnnotation(
                content: .richText(rect: backgroundRect, runs: [NativeScreenshotTextRun(
                    text: translation, color: foreground, fontSize: fontSize)]),
                style: NativeScreenshotAnnotationStyle(
                    strokeColor: foreground, fillColor: background,
                    lineWidth: 0, opacity: 1, fillsTextBox: true)))
        }
        return result
    }

    struct Placement {
        let sourceBounds: CGRect
        let backgroundRect: CGRect
        let textWidth: CGFloat
        let padding: CGFloat
    }

    /// Both OCR boxes and annotation documents use top-left image pixels, so
    /// only clipping and a small text margin are needed, not a Y-axis flip.
    static func placement(for recognizedBounds: CGRect, canvas: CGRect) -> Placement? {
        guard recognizedBounds.origin.x.isFinite, recognizedBounds.origin.y.isFinite,
              recognizedBounds.width.isFinite, recognizedBounds.height.isFinite,
              canvas.width > 0, canvas.height > 0 else { return nil }
        let source = recognizedBounds.standardized.intersection(canvas)
        guard !source.isNull, source.width >= 2, source.height >= 2 else { return nil }
        let padding = min(5, max(2, source.height * 0.12))
        let x = max(canvas.minX, source.minX - padding)
        let y = max(canvas.minY, source.minY - padding)
        let availableWidth = canvas.maxX - x
        let width = min(availableWidth, max(source.width + padding * 2,
                                            source.width * 1.35 + padding * 2))
        let height = min(canvas.maxY - y, source.height + padding * 2)
        let backgroundRect = CGRect(x: x, y: y, width: width, height: height)
        guard backgroundRect.width > padding * 2,
              backgroundRect.height > 4 else { return nil }
        return Placement(sourceBounds: source, backgroundRect: backgroundRect,
                         textWidth: backgroundRect.width - padding * 2,
                         padding: padding)
    }

    static func readableForeground(over background: NativeScreenshotColor) -> NativeScreenshotColor {
        // WCAG's black/white crossover gives >= 4.5:1 contrast for either side.
        let luminance = [background.red, background.green, background.blue]
            .map { component -> CGFloat in
                let value = max(0, min(1, component))
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
        let relative = 0.2126 * luminance[0] + 0.7152 * luminance[1] + 0.0722 * luminance[2]
        return relative > 0.179 ? .black : .white
    }

    private static func sampledBackground(in image: CGImage, around bounds: CGRect) -> NativeScreenshotColor {
        let points = [
            CGPoint(x: bounds.minX - 2, y: bounds.midY),
            CGPoint(x: bounds.maxX + 2, y: bounds.midY),
            CGPoint(x: bounds.midX, y: bounds.minY - 2),
            CGPoint(x: bounds.midX, y: bounds.maxY + 2),
            CGPoint(x: bounds.minX - 2, y: bounds.minY - 2),
            CGPoint(x: bounds.maxX + 2, y: bounds.minY - 2),
            CGPoint(x: bounds.minX - 2, y: bounds.maxY + 2),
            CGPoint(x: bounds.maxX + 2, y: bounds.maxY + 2)
        ]
        let sampled = points.compactMap {
            NativeScreenshotAnnotationRenderer.sampleColor(at: $0, in: image)
        }.filter { $0.alpha > 0.9 }
        guard !sampled.isEmpty else { return .white }
        // A median perimeter sample resists an adjacent glyph or icon better
        // than taking the center of the recognized (text-covered) rectangle.
        let ranked = sampled.sorted {
            $0.red * 0.2126 + $0.green * 0.7152 + $0.blue * 0.0722
                < $1.red * 0.2126 + $1.green * 0.7152 + $1.blue * 0.0722
        }
        let color = ranked[ranked.count / 2]
        return NativeScreenshotColor(red: color.red, green: color.green, blue: color.blue)
    }

    private static func fittedText(
        _ text: String, width: CGFloat, sourceHeight: CGFloat
    ) -> (fontSize: CGFloat, requiredHeight: CGFloat) {
        let targetHeight = max(14, sourceHeight * 1.8)
        let initial = min(32, max(11, sourceHeight * 0.82))
        var size = initial
        var required = measuredHeight(text, width: width, fontSize: size)
        while required > targetHeight && size > 9 {
            size = max(9, size - 1)
            required = measuredHeight(text, width: width, fontSize: size)
        }
        return (size, required)
    }

    private static func measuredHeight(_ text: String, width: CGFloat, fontSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize)
        let box = (text as NSString).boundingRect(
            with: CGSize(width: max(1, width), height: 100_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        return max(fontSize * 1.25, ceil(box.height))
    }
}
