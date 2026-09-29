import AppKit
import CoreGraphics
import Foundation

@main
struct NativeScreenshotAnnotationRegression {
    private static let width = 128
    private static let height = 96
    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue

    static func main() throws {
        try testDocumentEdits()
        try testSamplerAndCensors()
        try testAllExportedTools()
        try testArrowStyles()
        print("NativeScreenshotAnnotationRegression passed")
    }

    private static func testDocumentEdits() throws {
        var document = NativeScreenshotAnnotationDocument(
            canvasSize: CGSize(width: width, height: height), undoLimit: 2)
        let first = NativeScreenshotAnnotation(content: .rectangle(CGRect(x: 10, y: 10, width: 20, height: 20)))
        let second = NativeScreenshotAnnotation(content: .line(start: .init(x: 0, y: 0), end: .init(x: 10, y: 10)))
        assert(document.insert(first))
        assert(!document.insert(first), "duplicate IDs must be refused")
        assert(document.insert(second))
        assert(document.annotation(at: CGPoint(x: 25, y: 25))?.id == first.id)
        assert(document.move(id: first.id, by: CGSize(width: 30, height: 0)))
        assert(document.annotation(at: CGPoint(x: 55, y: 25))?.id == first.id)
        assert(document.undo())
        assert(document.annotation(at: CGPoint(x: 25, y: 25))?.id == first.id)
        assert(document.redo())
        assert(document.annotation(at: CGPoint(x: 55, y: 25))?.id == first.id)
        assert(document.remove(id: first.id))
        assert(document.undo())
        assert(document.undo())
        assert(!document.undo(), "undo history must be bounded")
        assert(!document.insert(.init(content: .colorSampler(CGPoint(x: 1, y: 1)))))
        assert(document.annotations.allSatisfy { $0.kind != .colorSampler })
        let numberOne = document.insertNextNumber(at: CGPoint(x: 60, y: 60))
        let numberTwo = document.insertNextNumber(at: CGPoint(x: 80, y: 60))
        if case let .number(_, value) = numberOne.content { assert(value == 1) }
        else { assertionFailure("expected a numbered annotation") }
        if case let .number(_, value) = numberTwo.content { assert(value == 2) }
        else { assertionFailure("expected a numbered annotation") }
        _ = try NativeScreenshotAnnotationRenderer.renderOverlay(document: document)
    }

    private static func testSamplerAndCensors() throws {
        let stripes = try stripeImage()
        let red = NativeScreenshotAnnotationRenderer.sampleColor(at: CGPoint(x: 5, y: 5), in: stripes)!
        let blue = NativeScreenshotAnnotationRenderer.sampleColor(at: CGPoint(x: 100, y: 5), in: stripes)!
        let green = NativeScreenshotAnnotationRenderer.sampleColor(at: CGPoint(x: 5, y: 90), in: stripes)!
        assert(red.red > 0.9 && red.blue < 0.1, "upper-left red pixel should sample as red")
        assert(blue.blue > 0.9 && blue.red < 0.1, "upper-right blue pixel should sample as blue")
        assert(green.green > 0.9 && green.red < 0.1, "lower-left green pixel verifies top-origin sampling")
        assert(NativeScreenshotAnnotationRenderer.sampleColor(at: CGPoint(x: -1, y: 0), in: stripes) == nil)

        var document = NativeScreenshotAnnotationDocument(canvasSize: CGSize(width: width, height: height))
        _ = document.insert(.init(content: .solidCensor(CGRect(x: 10, y: 10, width: 20, height: 20)),
                                  style: .init(strokeColor: .black, fillColor: .black)))
        let censored = try NativeScreenshotAnnotationRenderer.render(baseImage: stripes, document: document)
        let color = NativeScreenshotAnnotationRenderer.sampleColor(at: CGPoint(x: 15, y: 15), in: censored)!
        assert(color.red < 0.1 && color.green < 0.1 && color.blue < 0.1, "solid censor must overwrite source pixels")

        _ = document.insert(.init(content: .eraseCensor(CGRect(x: 40, y: 10, width: 20, height: 20))))
        let erased = try NativeScreenshotAnnotationRenderer.render(baseImage: stripes, document: document)
        let transparent = NativeScreenshotAnnotationRenderer.sampleColor(at: CGPoint(x: 45, y: 15), in: erased)!
        assert(transparent.alpha < 0.01, "erase censor must remove source pixels")
    }

    private static func testAllExportedTools() throws {
        let base = try checkerboardImage()
        let red = NativeScreenshotAnnotationStyle(strokeColor: .red, fillColor: .red, lineWidth: 4)
        let tools: [NativeScreenshotAnnotationContent] = [
            .pencil(samples: [.init(CGPoint(x: 15, y: 20)), .init(CGPoint(x: 50, y: 35), pressure: 0.5),
                              .init(CGPoint(x: 90, y: 22))], smoothing: .refined),
            .line(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 90, y: 70)),
            .arrow(start: CGPoint(x: 10, y: 80), end: CGPoint(x: 100, y: 15), style: .solid),
            .rectangle(CGRect(x: 20, y: 20, width: 50, height: 30)),
            .filledRectangle(CGRect(x: 20, y: 20, width: 50, height: 30)),
            .ellipse(CGRect(x: 20, y: 20, width: 50, height: 30)),
            .highlighter(points: [CGPoint(x: 10, y: 50), CGPoint(x: 80, y: 50)]),
            .richText(rect: CGRect(x: 10, y: 10, width: 110, height: 70),
                      runs: [.init(text: "Bold ", bold: true, backgroundColor: .yellow),
                             .init(text: "斜体", italic: true, outlineWidth: 1)]),
            .number(center: CGPoint(x: 50, y: 40), value: 12),
            .stamp(rect: CGRect(x: 30, y: 15, width: 45, height: 45), content: .emoji("📌")),
            .pixelate(rect: CGRect(x: 15, y: 15, width: 60, height: 60), blockSize: 12),
            .blur(rect: CGRect(x: 15, y: 15, width: 60, height: 60), radius: 6),
            .solidCensor(CGRect(x: 15, y: 15, width: 60, height: 40)),
            .eraseCensor(CGRect(x: 15, y: 15, width: 60, height: 40)),
            .magnifier(source: CGRect(x: 5, y: 5, width: 16, height: 16),
                       destination: CGRect(x: 60, y: 20, width: 50, height: 50)),
            .ruler(start: CGPoint(x: 10, y: 20), end: CGPoint(x: 100, y: 60)),
            .spotlight(CGRect(x: 25, y: 20, width: 60, height: 50))
        ]
        assert(tools.count == NativeScreenshotAnnotationKind.allCases.count - 1)
        for content in tools {
            var document = NativeScreenshotAnnotationDocument(canvasSize: CGSize(width: width, height: height))
            assert(document.insert(.init(content: content, style: red)))
            let output = try NativeScreenshotAnnotationRenderer.render(baseImage: base, document: document)
            assert(rgba(output) != rgba(base), "\(content.kind) failed to alter the exported pixels")
            if content.kind == .pixelate {
                let a = NativeScreenshotAnnotationRenderer.sampleColor(at: CGPoint(x: 17, y: 17), in: output)!
                let b = NativeScreenshotAnnotationRenderer.sampleColor(at: CGPoint(x: 20, y: 20), in: output)!
                assert(abs(a.red - b.red) < 0.01, "pixels in one mosaic block should match")
            }
            if content.kind == .blur {
                let softened = NativeScreenshotAnnotationRenderer.sampleColor(at: CGPoint(x: 40, y: 40), in: output)!
                assert(softened.red > 0.1 && softened.red < 0.9,
                       "blur should soften a black-and-white checkerboard")
            }
        }
        var imageStamp = NativeScreenshotAnnotationDocument(canvasSize: CGSize(width: width, height: height))
        _ = imageStamp.insert(.init(content: .stamp(
            rect: CGRect(x: 20, y: 20, width: 50, height: 50),
            content: .image(try stripeImage()))))
        let stampOutput = try NativeScreenshotAnnotationRenderer.render(baseImage: base, document: imageStamp)
        assert(rgba(stampOutput) != rgba(base), "image stamp must render")
    }

    private static func testArrowStyles() throws {
        let base = try stripeImage()
        var unique = Set<[UInt8]>()
        for arrowStyle in NativeScreenshotArrowStyle.allCases {
            var document = NativeScreenshotAnnotationDocument(canvasSize: CGSize(width: width, height: height))
            _ = document.insert(.init(content: .arrow(
                start: CGPoint(x: 10, y: 80), end: CGPoint(x: 115, y: 12), style: arrowStyle)))
            let output = try NativeScreenshotAnnotationRenderer.render(baseImage: base, document: document)
            unique.insert(rgba(output))
        }
        assert(unique.count == 6, "all six arrow styles must be visually distinct")
    }

    private static func stripeImage() throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: bitmapInfo) else {
            throw NativeScreenshotAnnotationRenderError.bitmapContextUnavailable
        }
        context.setFillColor(NativeScreenshotColor(red: 0, green: 1, blue: 0).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        context.setFillColor(NativeScreenshotColor.yellow.cgColor)
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height / 2))
        context.setFillColor(NativeScreenshotColor.red.cgColor)
        context.fill(CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2))
        context.setFillColor(NativeScreenshotColor(red: 0, green: 0, blue: 1).cgColor)
        context.fill(CGRect(x: width / 2, y: height / 2, width: width / 2, height: height / 2))
        guard let image = context.makeImage() else {
            throw NativeScreenshotAnnotationRenderError.imageCreationFailed
        }
        return image
    }

    private static func checkerboardImage() throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: bitmapInfo) else {
            throw NativeScreenshotAnnotationRenderError.bitmapContextUnavailable
        }
        context.setFillColor(NativeScreenshotColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(NativeScreenshotColor.black.cgColor)
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) where (x / 4 + y / 4).isMultiple(of: 2) {
                context.fill(CGRect(x: x, y: y, width: 4, height: 4))
            }
        }
        guard let image = context.makeImage() else {
            throw NativeScreenshotAnnotationRenderError.imageCreationFailed
        }
        return image
    }

    private static func rgba(_ image: CGImage) -> [UInt8] {
        let count = image.width * image.height * 4
        var data = [UInt8](repeating: 0, count: count)
        data.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: space, bitmapInfo: bitmapInfo)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }
}
