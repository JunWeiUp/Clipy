import AppKit
import CoreGraphics
import Foundation

extension NativeScreenshotRecognitionRegression {
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue

    static func testTranslatedAnnotations() throws {
        let image = makeImage()
        let lines = [
            NativeScreenshotRecognizedText(
                text: "Original", confidence: 0.99,
                bounds: CGRect(x: 20, y: 18, width: 84, height: 20)),
            NativeScreenshotRecognizedText(
                text: "原文", confidence: 0.99,
                bounds: CGRect(x: 184, y: 106, width: 85, height: 22))
        ]
        let translations = ["A translated sentence", "Short"]
        let annotations = try NativeScreenshotTranslatedAnnotationFactory.makeAnnotations(
            in: image, recognizedLines: lines, translatedLines: translations)
        assert(annotations.count == 2, "each line must be one movable text block")
        guard case let .richText(firstText, firstRuns) = annotations[0].content,
              case let .richText(secondText, secondRuns) = annotations[1].content else {
            fatalError("translation must be modeled as editable rich text with its own cover")
        }
        assert(annotations.allSatisfy(\.style.fillsTextBox))
        assert(firstText.minX <= 20 && firstText.minY <= 18)
        assert(firstText.minY < 40, "Vision top-left pixels must not be flipped")
        assert(firstRuns.count == 1 && firstRuns[0].text == translations[0])
        assert(firstRuns[0].color == .white, "dark sampled background needs light text")
        assert(secondText.maxX <= 240 && secondText.maxY <= 140)
        assert(secondRuns[0].color == .black, "light sampled background needs dark text")
        assert(NativeScreenshotTranslatedAnnotationFactory.placement(
            for: CGRect(x: CGFloat.infinity, y: 0, width: 20, height: 10),
            canvas: CGRect(x: 0, y: 0, width: 240, height: 140)) == nil)

        var document = NativeScreenshotAnnotationDocument(
            canvasSize: CGSize(width: image.width, height: image.height))
        assert(document.insertBatch(annotations) == 2)
        let rendered = try NativeScreenshotAnnotationRenderer.render(
            baseImage: image, document: document)
        let original = pixel(image, x: 19, y: 18)
        let covered = pixel(rendered, x: 19, y: 18)
        assert(covered[3] == 255 && original[3] == 255)
        assert(document.annotation(at: CGPoint(x: firstText.midX, y: firstText.midY))?.kind == .richText,
               "translated text and its cover should select as one block")
        assert(document.move(id: annotations[0].id, by: CGSize(width: 10, height: 0)))
        assert(document.undo(), "move should undo independently of the translation batch")
        assert(document.undo() && document.annotations.isEmpty,
               "one undo should remove all translated lines")

        let empty = try NativeScreenshotTranslatedAnnotationFactory.makeAnnotations(
            in: image, recognizedLines: lines, translatedLines: ["", " "])
        assert(empty.isEmpty, "empty translations must not hide source pixels")
        do {
            _ = try NativeScreenshotTranslatedAnnotationFactory.makeAnnotations(
                in: image, recognizedLines: lines, translatedLines: ["only one"])
            fatalError("misaligned OCR and translation arrays must fail")
        } catch NativeScreenshotTranslatedAnnotationError.mismatchedLineCount {
            // Expected: never paint a translation onto the wrong source line.
        }
        print("NativeScreenshotTranslatedAnnotationRegression passed")
    }

    private static func makeImage() -> CGImage {
        let context = CGContext(data: nil, width: 240, height: 140,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: colorSpace, bitmapInfo: bitmapInfo)!
        context.setFillColor(CGColor(colorSpace: colorSpace,
                                     components: [0.04, 0.08, 0.16, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 140))
        // Quartz contexts have a bottom-left origin; this is the image's lower half.
        context.setFillColor(CGColor(colorSpace: colorSpace,
                                     components: [0.95, 0.95, 0.95, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 68))
        return context.makeImage()!
    }

    private static func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let one = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))!
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: 1, height: 1,
                                    bitsPerComponent: 8, bytesPerRow: 4,
                                    space: colorSpace, bitmapInfo: bitmapInfo)!
            context.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
}
