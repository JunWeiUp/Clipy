import AppKit
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import SwiftUI

@main
struct NativeScreenshotRecognitionRegression {
    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue

    static func main() throws {
        try testGeometryAndSuggestions()
        try testPreviewThenConfirm()
        try testVisionQRCode()
        try testVisionOCR()
        try testUIConstructionAndAvailability()
        print("NativeScreenshotRecognitionRegression passed")
    }

    private static func testGeometryAndSuggestions() throws {
        let box = NativeScreenshotRecognitionService.pixelRect(
            from: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            imageSize: CGSize(width: 200, height: 100))
        assert(abs(box.minX - 20) < 0.01 && abs(box.minY - 40) < 0.01)
        assert(abs(box.width - 60) < 0.01 && abs(box.height - 40) < 0.01)

        let strings = [
            "name@example.com",
            "4111 1111 1111 1111",
            "API key: abcdefgh",
            "+1 415 555 0123",
            "ordinary note"
        ]
        let lines = strings.enumerated().map { index, text in
            NativeScreenshotRecognizedText(
                text: text, confidence: 0.99,
                bounds: CGRect(x: 10, y: 10 + index * 20, width: 140, height: 14))
        }
        let suggestions = NativeScreenshotRedactionDetector.suggest(
            from: lines, imageSize: CGSize(width: 180, height: 120))
        assert(suggestions.count == 4)
        assert(suggestions.map(\.category) == [.email, .paymentCard, .credential, .phone])
        assert(suggestions[0].bounds.minX < lines[0].bounds.minX,
               "review box should pad the complete OCR line")
        assert(suggestions.allSatisfy { $0.bounds.minX >= 0 && $0.bounds.maxX <= 180 })
        assert(NativeScreenshotRedactionDetector.category(for: "1234 5678 9012 3456") == nil,
               "an invalid card checksum should not be suggested")
    }

    private static func testPreviewThenConfirm() throws {
        let source = try solidImage(width: 80, height: 60, red: 1, green: 1, blue: 1)
        let first = NativeScreenshotRedactionSuggestion(
            category: .email, bounds: CGRect(x: 10, y: 10, width: 25, height: 16), lineNumber: 1)
        let second = NativeScreenshotRedactionSuggestion(
            category: .phone, bounds: CGRect(x: 45, y: 10, width: 25, height: 16), lineNumber: 2)
        let review = NativeScreenshotRedactionReview(
            sourceImage: source, suggestions: [first, second])
        let before = sample(source, x: 15, y: 15)
        let preview = try review.previewImage(selectedIDs: [first.id])
        let previewPixel = sample(preview, x: 15, y: 15)
        assert(previewPixel[0] > 230 && previewPixel[1] > 40,
               "preview should be translucent, not a burned-in black mask")
        assert(sample(source, x: 15, y: 15) == before,
               "preview must not mutate the original image")

        let confirmed = try review.confirm(selectedIDs: [first.id])
        let hidden = sample(confirmed, x: 15, y: 15)
        let unselected = sample(confirmed, x: 50, y: 15)
        assert(hidden[0] < 3 && hidden[1] < 3 && hidden[2] < 3,
               "confirmation must permanently cover only the selected region")
        assert(unselected[0] > 252, "unselected suggestion must remain visible")
        assert(sample(source, x: 15, y: 15) == before,
               "confirmation must return a copy and leave the source unchanged")
        let untouched = try review.confirm(selectedIDs: [])
        assert(sample(untouched, x: 15, y: 15) == before)
    }

    private static func testVisionQRCode() throws {
        let payload = "clipy-recognition-qr-test"
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            throw TestError.unavailableQRCodeGenerator
        }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        guard let generated = filter.outputImage else {
            throw TestError.unavailableQRCodeGenerator
        }
        let enlarged = generated.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let image = CIContext(options: [.useSoftwareRenderer: true])
            .createCGImage(enlarged, from: enlarged.extent) else {
            throw TestError.unavailableQRCodeGenerator
        }
        let codes = try NativeScreenshotRecognitionService.recognizeQRCodesSynchronously(in: image)
        assert(codes.contains(where: { $0.payload == payload }))
        assert(codes.allSatisfy { $0.bounds.width > 0 && $0.bounds.height > 0 })
    }

    private static func testVisionOCR() throws {
        let image = try textImage("HELLO 123")
        let lines = try NativeScreenshotRecognitionService.recognizeTextSynchronously(
            in: image, language: .english)
        assert(lines.contains(where: { $0.text.uppercased().contains("HELLO") }),
               "Vision should recognize large synthetic English text")
        assert(lines.allSatisfy { $0.bounds.minX >= 0 && $0.bounds.minY >= 0 })
    }

    private static func testUIConstructionAndAvailability() throws {
        assert(NativeScreenshotTranslationAvailability.status(forMacOSMajorVersion: 13) == .requiresMacOS15)
        assert(NativeScreenshotTranslationAvailability.status(forMacOSMajorVersion: 14) == .requiresMacOS15)
        assert(NativeScreenshotTranslationAvailability.status(forMacOSMajorVersion: 15) == .available)
        let image = try solidImage(width: 40, height: 30, red: 1, green: 1, blue: 1)
        let review = NativeScreenshotRedactionReview(sourceImage: image, suggestions: [])
        let reviewHost = NSHostingView(rootView: NativeScreenshotRedactionReviewView(
            review: review, onConfirm: { _ in }, onCancel: {}))
        reviewHost.frame = NSRect(x: 0, y: 0, width: 640, height: 600)
        reviewHost.layoutSubtreeIfNeeded()
        let translationHost = NSHostingView(rootView: NativeScreenshotTranslationPanel(
            sourceText: "HELLO 123"))
        translationHost.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        translationHost.layoutSubtreeIfNeeded()
        let resultHost = NSHostingView(rootView: NativeScreenshotRecognitionPanel(
            image: image, language: .english, onRedactedImage: { _ in }))
        resultHost.frame = NSRect(x: 0, y: 0, width: 640, height: 600)
        resultHost.layoutSubtreeIfNeeded()
    }

    private static func solidImage(width: Int, height: Int, red: CGFloat,
                                   green: CGFloat, blue: CGFloat) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: bitmapInfo) else {
            throw TestError.bitmapUnavailable
        }
        context.setFillColor(CGColor(colorSpace: space, components: [red, green, blue, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = context.makeImage() else { throw TestError.bitmapUnavailable }
        return output
    }

    private static func textImage(_ value: String) throws -> CGImage {
        let width = 360
        let height = 90
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: bitmapInfo) else {
            throw TestError.bitmapUnavailable
        }
        context.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 40, nil)
        let text = NSAttributedString(string: value, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(colorSpace: space, components: [0, 0, 0, 1])!
        ])
        let line = CTLineCreateWithAttributedString(text)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: 16, y: 25)
        CTLineDraw(line, context)
        guard let output = context.makeImage() else { throw TestError.bitmapUnavailable }
        return output
    }

    private static func sample(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))!
        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                                    bitsPerComponent: 8, bytesPerRow: 4,
                                    space: space, bitmapInfo: bitmapInfo)!
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return rgba
    }

    private enum TestError: Error {
        case bitmapUnavailable
        case unavailableQRCodeGenerator
    }
}
