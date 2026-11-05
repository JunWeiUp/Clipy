import Cocoa

/// Handles the unified censor tool (pixelate, blur, solid).
/// Mode is read from UserDefaults "censorMode". Shift-constrains to square.
/// Captures composited image source for pixelate/blur baking.
final class PixelateToolHandler: AnnotationToolHandler {

    let tool: AnnotationTool = .pixelate
    private let recognition = ScreenshotOCRGestureTasks()

    struct TextRedaction {
        let screenshot: NSImage
        let selectionRect: NSRect
        let captureDrawRect: NSRect
        let color: NSColor
        let sourceImage: NSImage?
        let sourceImageBounds: NSRect
    }
    typealias RedactText = (TextRedaction, @escaping (String) -> Void, @escaping ([Annotation]) -> Void) -> OCRTask?
    private let redactText: RedactText

    init(redactText: @escaping RedactText = { request, onError, completion in
        AutoRedactor.redactAllText(screenshot: request.screenshot, selectionRect: request.selectionRect,
            captureDrawRect: request.captureDrawRect, redactTool: .pixelate, color: request.color,
            sourceImage: request.sourceImage, sourceImageBounds: request.sourceImageBounds,
            onError: onError, completion: completion)
    }) { self.redactText = redactText }

    func reset() { recognition.cancel() }

    func start(at point: NSPoint, canvas: AnnotationCanvas) -> Annotation? {
        let mode = CensorMode(rawValue: UserDefaults.standard.integer(forKey: "censorMode")) ?? .pixelate
        let annotation = Annotation(
            tool: .pixelate,
            startPoint: point,
            endPoint: point,
            color: canvas.opacityAppliedColor(for: .pixelate),
            strokeWidth: canvas.currentStrokeWidth
        )
        annotation.censorMode = mode
        // Solid mode doesn't need a source image; all others do
        if mode != .solid {
            annotation.sourceImage = canvas.screenshotImage
            annotation.sourceImageBounds = canvas.captureDrawRect
        }
        return annotation
    }

    func update(to point: NSPoint, shiftHeld: Bool, canvas: AnnotationCanvas) {
        guard let annotation = canvas.activeAnnotation else { return }
        var clampedPoint = point

        if shiftHeld {
            clampedPoint = snapSquare(point, from: annotation.startPoint)
            canvas.snapGuideX = nil
            canvas.snapGuideY = nil
        } else {
            clampedPoint = canvas.snapPoint(point, excluding: annotation)
        }

        annotation.endPoint = clampedPoint
    }

    func finish(canvas: AnnotationCanvas) {
        guard let annotation = canvas.activeAnnotation else { return }
        let dx = abs(annotation.endPoint.x - annotation.startPoint.x)
        let dy = abs(annotation.endPoint.y - annotation.startPoint.y)
        guard dx > 2 || dy > 2 else {
            canvas.activeAnnotation = nil
            canvas.setNeedsDisplay()
            return
        }

        if UserDefaults.standard.bool(forKey: "censorTextOnly") {
            let drawnRect = annotation.boundingRect
            let sourceImg = annotation.sourceImage
            let sourceImgBounds = annotation.sourceImageBounds
            canvas.activeAnnotation = nil
            canvas.setNeedsDisplay()
            guard let screenshot = canvas.screenshotImage else { return }
            guard let gestureID = recognition.reserve() else {
                canvas.showOverlayError("Text redaction is busy. Please wait for the current strokes to finish and try again.")
                return
            }
            let request = TextRedaction(screenshot: screenshot, selectionRect: drawnRect,
                captureDrawRect: canvas.captureDrawRect, color: canvas.currentColor,
                sourceImage: sourceImg, sourceImageBounds: sourceImgBounds)
            let task = redactText(request, { [weak self, weak canvas] message in
                guard let self, self.recognition.finish(gestureID) else { return }
                canvas?.showOverlayError(message)
            }, { [weak self, weak canvas] anns in
                guard let self, let canvas, self.recognition.finish(gestureID) else { return }
                guard !anns.isEmpty else { return }
                canvas.annotations.append(contentsOf: anns)
                canvas.undoStack.append(contentsOf: anns.map { .added($0) })
                canvas.redoStack.removeAll()
                canvas.setNeedsDisplay()
            })
            recognition.attach(task, to: gestureID)
        } else {
            commitAnnotation(annotation, canvas: canvas)
        }
    }
}
