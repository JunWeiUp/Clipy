import AppKit
import CoreGraphics

// The standalone test compiles the editor without the capture/coordinator
// modules. Production builds do not define this flag or compile Tests/.
#if EDITOR_STANDALONE_TEST
struct NativeScreenshotCapturedImage {
    let image: CGImage
    let sourceRect: CGRect
    let pixelsPerPoint: CGFloat
}

enum NativeScreenshotDeliveryAction {
    case confirm, ocr, qrCode, autoRedact, pin, save
}

enum NativeScreenshotImageProcessor {
    struct Adjustments {
        var brightness: Float = 0
        var contrast: Float = 1
        var saturation: Float = 1
        var sharpness: Float = 0
    }

    static func adjust(_ image: CGImage, using values: Adjustments) throws -> CGImage { image }
}

enum NativeScreenshotWindowActivation {
    static func opened(_ id: UUID) {}
    static func closed(_ id: UUID) {}
}

@MainActor
final class PreferencesManager {
    static let shared = PreferencesManager()
    var beautifyEnabled = false
    var beautifyMode = 0
    var beautifyPadding = 48.0
    var beautifyCornerRadius = 10.0
    var beautifyShadowRadius = 20.0
    var effectsBrightness = 0.0
    var effectsContrast = 1.0
    var effectsSaturation = 1.0
    var effectsSharpness = 0.0
    var screenshotTextFontSize: CGFloat = 18
    var screenshotTextBold = false
    var screenshotTextItalic = false
    var screenshotTextBackgroundEnabled = false
    var pencilPressureEnabled = false
    var pencilSmoothMode = 1
    var smartMarkerEnabled = false
    var rememberLastTool = true
    var showToolShortcutsInTooltips = false
}
#endif

@MainActor
@main
struct NativeScreenshotEditorUIRegression {
    static func main() throws {
        let base = try whiteImage(width: 100, height: 80)
        let canvas = NativeScreenshotAnnotationCanvasView(image: base)
        let initialImage = try canvas.renderedImage()
        assert(initialImage.width == 100)
        assert(!canvas.hasUnsavedEdits)
        var escapeCount = 0
        canvas.onEscape = { escapeCount += 1 }
        let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        canvas.keyDown(with: escape)
        assert(escapeCount == 1, "Escape must route through the editor cancellation policy")
        let start = CGPoint(x: 10, y: 10)
        let end = CGPoint(x: 30, y: 25)
        canvas.arrowStyle = .curvedDashed
        if case let .arrow(_, _, arrowStyle)? = canvas.annotationContent(
            kind: .arrow, start: start, end: end) {
            assert(arrowStyle == .curvedDashed)
        } else { assertionFailure("arrow option was not applied") }
        canvas.pencilSmoothing = .refined
        if case let .pencil(_, smoothing)? = canvas.annotationContent(
            kind: .pencil, start: start, end: end) {
            assert(smoothing == .refined)
        } else { assertionFailure("pencil smoothing was not applied") }
        canvas.textOverride = "Rich text"
        canvas.textFontSize = 32
        canvas.textBold = true
        canvas.textItalic = true
        canvas.textBackgroundEnabled = true
        if case let .richText(_, runs)? = canvas.annotationContent(
            kind: .richText, start: start, end: end) {
            assert(runs.count == 1 && runs[0].fontSize == 32 && runs[0].bold
                   && runs[0].italic && runs[0].backgroundColor != nil)
        } else { assertionFailure("rich text options were not applied") }
        canvas.stampImage = base
        if case let .stamp(_, content)? = canvas.annotationContent(
            kind: .stamp, start: start, end: end) {
            if case .image = content {} else { assertionFailure("image stamp not selected") }
        } else { assertionFailure("image stamp was not created") }
        canvas.pixelBlockSize = 28
        if case let .pixelate(_, blockSize)? = canvas.annotationContent(
            kind: .pixelate, start: start, end: end) {
            assert(blockSize == 28)
        } else { assertionFailure("mosaic strength was not applied") }
        canvas.blurRadius = 21
        if case let .blur(_, radius)? = canvas.annotationContent(
            kind: .blur, start: start, end: end) {
            assert(radius == 21)
        } else { assertionFailure("blur strength was not applied") }
        canvas.magnifierScale = 3
        if case let .magnifier(source, destination)? = canvas.annotationContent(
            kind: .magnifier, start: start, end: end) {
            assert(destination.width >= source.width * 2.9)
        } else { assertionFailure("magnifier scale was not applied") }
        try canvas.applyImageTransform {
            try NativeScreenshotImageEditor.crop($0, to: CGRect(x: 10, y: 10, width: 50, height: 40))
        }
        assert(canvas.image.width == 50 && canvas.image.height == 40)
        canvas.undo()
        assert(canvas.image.width == 100 && canvas.image.height == 80)
        canvas.redo()
        assert(canvas.image.width == 50 && canvas.image.height == 40)

        let annotatedCanvas = NativeScreenshotAnnotationCanvasView(image: base)
        assert(!annotatedCanvas.hasUnsavedEdits)
        let redFill = NativeScreenshotAnnotation(
            content: .filledRectangle(CGRect(x: 20, y: 20, width: 10, height: 10)),
            style: .init(strokeColor: .red, fillColor: .red))
        assert(annotatedCanvas.insertAnnotation(redFill))
        assert(annotatedCanvas.hasUnsavedEdits)
        let beforeFlip = try annotatedCanvas.renderedImage()
        assert(NativeScreenshotAnnotationRenderer.sampleColor(
            at: CGPoint(x: 25, y: 25), in: beforeFlip)!.green < 0.1)
        try annotatedCanvas.applyImageTransform {
            try NativeScreenshotImageEditor.flip($0, horizontal: true, vertical: false)
        }
        let afterFlip = try annotatedCanvas.renderedImage()
        assert(NativeScreenshotAnnotationRenderer.sampleColor(
            at: CGPoint(x: 75, y: 25), in: afterFlip)!.green < 0.1,
            "flattened annotation must move with the transformed image")
        annotatedCanvas.undo()
        assert(annotatedCanvas.hasUnsavedEdits,
               "undoing an image transform must retain the preexisting annotation")
        annotatedCanvas.selectAnnotation(at: CGPoint(x: 25, y: 25))
        annotatedCanvas.scaleSelection(by: 2)
        let enlarged = try annotatedCanvas.renderedImage()
        assert(NativeScreenshotAnnotationRenderer.sampleColor(
            at: CGPoint(x: 16, y: 25), in: enlarged)!.green < 0.1,
            "selection scaling must change exported geometry")

        let cleanCanvas = NativeScreenshotAnnotationCanvasView(image: base)
        let cleanSnapshot = cleanCanvas.renderSnapshot()
        assert(cleanCanvas.insertAnnotation(redFill))
        assert(cleanCanvas.contentGeneration != cleanSnapshot.generation,
               "background render results must be rejected after an edit")
        cleanCanvas.undo()
        assert(!cleanCanvas.hasUnsavedEdits,
               "undoing the only annotation restores the clean close state")
        let flipped = try NativeScreenshotImageEditor.flip(
            base, horizontal: true, vertical: false)
        cleanCanvas.commitImageTransform(flipped)
        assert(cleanCanvas.hasUnsavedEdits,
               "a committed full-resolution transform requires discard confirmation")
        cleanCanvas.undo()
        assert(!cleanCanvas.hasUnsavedEdits,
               "undoing a transform restores the clean close state")

        let rectangle = NativeScreenshotAnnotationContent.rectangle(
            CGRect(x: 10, y: 20, width: 20, height: 10))
        let scaledRectangle = rectangle.scaled(by: 2, around: CGPoint(x: 20, y: 25))
        guard case let .rectangle(rect) = scaledRectangle else { fatalError("rectangle lost its kind") }
        assert(rect.width == 40 && rect.height == 20 && rect.minX == 0 && rect.minY == 15)

        let richText = NativeScreenshotAnnotationContent.richText(
            rect: CGRect(x: 5, y: 5, width: 80, height: 30),
            runs: [.init(text: "Hello", fontSize: 20, bold: true)])
        let scaledText = richText.scaled(by: 1.5, around: CGPoint(x: 45, y: 20))
        guard case let .richText(_, runs) = scaledText else { fatalError("text lost its kind") }
        assert(runs[0].fontSize == 30 && runs[0].bold)

        let mixedCanvas = NativeScreenshotAnnotationCanvasView(image: base)
        let textRect = CGRect(x: 5, y: 5, width: 90, height: 60)
        let mixed = NativeScreenshotAnnotation(content: .richText(rect: textRect, runs: [
            .init(text: "Hello ", color: .black, fontSize: 16, bold: true),
            .init(text: "中文", color: .red, fontSize: 20, italic: true,
                  underline: true, outlineWidth: 1, backgroundColor: .yellow)
        ]))
        assert(mixedCanvas.insertAnnotation(mixed))
        let attributed = NativeScreenshotRichText.attributedString(from: mixedCanvas.selectedRichTextRuns!)
        let restored = NativeScreenshotRichText.runs(from: attributed)
        assert(restored.count == 2 && restored[0].bold && restored[1].italic
               && restored[1].underline && restored[1].outlineWidth > 0
               && restored[1].backgroundColor != nil,
               "per-range rich text formatting must survive an edit round trip")
        var edited = restored
        edited[1].text = "世界"
        assert(mixedCanvas.replaceSelectedRichText(edited))
        assert(mixedCanvas.selectedRichText == "Hello 世界")
        assert(mixedCanvas.selectedRichTextRuns?.count == 2)
        mixedCanvas.undo()
        assert(mixedCanvas.selectedRichText == "Hello 中文",
               "editing text in place must preserve undo history")
        assert(mixedCanvas.replaceSelectedRichText([
            .init(text: "第一行\nSecond line\n第三行", fontSize: 14)]))
        let multiline = mixedCanvas.previewDocument.annotations.first {
            $0.id == mixed.id
        }!
        if case let .richText(resized, _) = multiline.content {
            assert(resized.height >= NativeScreenshotRichText.requiredHeight(
                for: [.init(text: "第一行\nSecond line\n第三行", fontSize: 14)], width: resized.width),
                "editing mixed-language multiline text must grow the annotation box")
        } else { assertionFailure("text annotation was replaced with another kind") }

        let plain = NativeScreenshotRichText.attributedString(from: [
            .init(text: "A", fontSize: 30)])
        let decorated = NativeScreenshotRichText.attributedString(from: [
            .init(text: "A", fontSize: 30, underline: true,
                  outlineWidth: 1, backgroundColor: .yellow)])
        var plainDocument = NativeScreenshotAnnotationDocument(canvasSize: CGSize(width: 100, height: 80))
        var decoratedDocument = plainDocument
        _ = plainDocument.insert(.init(content: .richText(rect: textRect,
            runs: NativeScreenshotRichText.runs(from: plain))))
        _ = decoratedDocument.insert(.init(content: .richText(rect: textRect,
            runs: NativeScreenshotRichText.runs(from: decorated))))
        let plainPixels = try NativeScreenshotAnnotationRenderer.render(baseImage: base,
                                                                       document: plainDocument)
        let decoratedPixels = try NativeScreenshotAnnotationRenderer.render(baseImage: base,
                                                                           document: decoratedDocument)
        assert(plainPixels.dataProvider?.data != decoratedPixels.dataProvider?.data,
               "rich text decoration must change exported pixels")

        let largeBase = try whiteImage(width: 1800, height: 900)
        var largeDocument = NativeScreenshotAnnotationDocument(
            canvasSize: CGSize(width: largeBase.width, height: largeBase.height))
        _ = largeDocument.insert(.init(content: .filledRectangle(
            CGRect(x: 100, y: 100, width: 300, height: 300)),
            style: .init(strokeColor: .red, fillColor: .red)))
        let preview = NativeScreenshotEditorController.boundedPreviewSource(
            baseImage: largeBase, document: largeDocument, maximumDimension: 480)!
        assert(preview.width == 480 && preview.height == 240,
               "live effects preview must allocate only thumbnail-sized bitmaps")
        assert(NativeScreenshotAnnotationRenderer.sampleColor(
            at: CGPoint(x: 60, y: 60), in: preview)!.green < 0.1,
            "live preview must retain annotations after downsampling")

        let loupe = NativeScreenshotAnnotationContent.magnifier(
            source: CGRect(x: 0, y: 0, width: 10, height: 10),
            destination: CGRect(x: 20, y: 20, width: 30, height: 30))
        let scaledLoupe = loupe.scaled(by: 2, around: CGPoint(x: 35, y: 35))
        guard case let .magnifier(source, destination) = scaledLoupe else {
            fatalError("loupe lost its kind")
        }
        assert(source.width == 10 && destination.width == 60)
        print("NativeScreenshotEditorUIRegression passed")
    }

    private static func whiteImage(width: Int, height: Int) throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: info) else {
            throw NativeScreenshotEditorError.bitmapContextUnavailable
        }
        context.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw NativeScreenshotEditorError.imageCreationFailed
        }
        return image
    }
}
