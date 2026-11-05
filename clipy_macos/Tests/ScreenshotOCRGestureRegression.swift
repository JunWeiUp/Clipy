import Cocoa

private func gestureCheck(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("Screenshot OCR gesture regression: \(message)") }
}

/// Deterministic caller tests: injected recognizers deliberately deliver even after
/// cancellation, so generation/membership guards are exercised without Vision or UI windows.
func runScreenshotOCRGestureRegressionTests() {
    MainActor.assumeIsolated {
        let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
                                bytesPerRow: 400, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = NSImage(cgImage: context.makeImage()!, size: NSSize(width: 100, height: 100))
        let observations = [
            OCRTextObservation(text: "first", boundingBox: CGRect(x: 0.1, y: 0.35, width: 0.8, height: 0.1)),
            OCRTextObservation(text: "second", boundingBox: CGRect(x: 0.1, y: 0.55, width: 0.8, height: 0.1))
        ]
        var markerCallbacks: [([OCRTextObservation], Error?) -> Void] = []
        var markerTasks: [OCRTask] = []
        let marker = MarkerToolHandler { _, completion in
            markerCallbacks.append(completion)
            let task = OCRTask(); markerTasks.append(task); return task
        }
        let canvas = GestureCanvas(image: image)
        drawGesture(marker, y: 40, canvas: canvas)
        drawGesture(marker, y: 60, canvas: canvas)
        gestureCheck(canvas.annotations.count == 2 && canvas.undoStack.count == 2,
                     "two rapid marker gestures must commit before OCR returns")
        gestureCheck(canvas.drawingCursorPoint == NSPoint(x: 90, y: 60),
                     "committing a smart stroke must advance the cursor immediately")
        gestureCheck(markerCallbacks.count == 1 && !markerTasks[0].isCancelled,
                     "marker strokes must share prefetch instead of cancelling each other")
        let first = canvas.annotations[0], second = canvas.annotations[1]
        canvas.activeAnnotation = marker.start(at: NSPoint(x: 10, y: 80), canvas: canvas)
        let active = canvas.activeAnnotation
        canvas.drawingCursorPoint = NSPoint(x: 77, y: 88)
        markerCallbacks[0](observations, nil)
        gestureCheck(canvas.annotations.count == 2 && canvas.undoStack.count == 2,
                     "late marker snap recommitted an existing stroke")
        gestureCheck(abs(first.startPoint.y - 40.5) < 0.001 && abs(second.startPoint.y - 60.5) < 0.001,
                     "shared recognition did not refine both committed strokes: \(first.startPoint.y), \(second.startPoint.y)")
        gestureCheck(canvas.activeAnnotation === active && canvas.drawingCursorPoint == NSPoint(x: 77, y: 88),
                     "old marker callback cleared or moved the new active gesture")
        gestureCheck(canvas.invalidations == 2, "late geometry changes did not invalidate rendering caches")

        // Even without a reset, a deleted/undone annotation may never be reinserted.
        marker.reset(); canvas.activeAnnotation = nil
        drawGesture(marker, y: 40, canvas: canvas)
        canvas.annotations.removeLast(); canvas.undoStack.removeLast()
        markerCallbacks[1](observations, nil)
        gestureCheck(canvas.annotations.count == 2, "marker OCR resurrected an undone annotation")
        marker.reset()
        drawGesture(marker, y: 40, canvas: canvas)
        let raw = canvas.annotations.last!
        marker.reset() // close, image/selection change, or undo calls this hook
        markerCallbacks[2](observations, nil)
        gestureCheck(raw.startPoint.y == 40 && markerTasks[2].isCancelled,
                     "invalidated marker request still modified a committed stroke")

        let defaults = UserDefaults.standard
        let oldTextOnly = defaults.object(forKey: "censorTextOnly")
        let oldMode = defaults.object(forKey: "censorMode")
        defer {
            if let oldTextOnly { defaults.set(oldTextOnly, forKey: "censorTextOnly") }
            else { defaults.removeObject(forKey: "censorTextOnly") }
            if let oldMode { defaults.set(oldMode, forKey: "censorMode") }
            else { defaults.removeObject(forKey: "censorMode") }
        }
        defaults.set(true, forKey: "censorTextOnly")
        defaults.set(CensorMode.solid.rawValue, forKey: "censorMode")
        var censorCallbacks: [([Annotation]) -> Void] = []
        var censorTasks: [OCRTask] = []
        let censor = PixelateToolHandler { _, _, completion in
            censorCallbacks.append(completion)
            let task = OCRTask(); censorTasks.append(task); return task
        }
        let censorCanvas = GestureCanvas(image: image)
        drawGesture(censor, y: 20, canvas: censorCanvas)
        drawGesture(censor, y: 40, canvas: censorCanvas)
        gestureCheck(censorCallbacks.count == 2 && censorTasks.allSatisfy { !$0.isCancelled },
                     "a second censor gesture cancelled the first")
        censorCanvas.activeAnnotation = censor.start(at: NSPoint(x: 10, y: 80), canvas: censorCanvas)
        let activeCensor = censorCanvas.activeAnnotation
        let redaction1 = makeRedaction(y: 20), redaction2 = makeRedaction(y: 40)
        censorCallbacks[1]([redaction2]); censorCallbacks[0]([redaction1])
        gestureCheck(censorCanvas.annotations.count == 2 && censorCanvas.undoStack.count == 2,
                     "independent censor completions dropped one of the two gestures")
        gestureCheck(censorCanvas.activeAnnotation === activeCensor,
                     "old censor completion cleared a newer active gesture")

        // Four independent gestures are admitted; the fifth is explicitly rejected,
        // never by cancelling one that the user already drew.
        for y in [10.0, 20, 30, 40, 50] { drawGesture(censor, y: y, canvas: censorCanvas) }
        gestureCheck(censorCallbacks.count == 6 && censorCanvas.errors.count == 1,
                     "censor gesture limit must report saturation without silently dropping earlier work")
        gestureCheck(censorTasks.allSatisfy { !$0.isCancelled }, "capacity handling cancelled an earlier gesture")
        censor.reset()
        censorCanvas.annotations.removeAll(); censorCanvas.undoStack.removeAll()
        for callback in censorCallbacks.suffix(4) { callback([makeRedaction(y: 20)]) }
        gestureCheck(censorCanvas.annotations.isEmpty && censorTasks.suffix(4).allSatisfy(\.isCancelled),
                     "close/undo cancellation allowed pending censor strokes to reappear")
        print("Screenshot OCR gesture regression tests passed")
    }
}

@MainActor
private func drawGesture(_ handler: AnnotationToolHandler, y: CGFloat, canvas: GestureCanvas) {
    canvas.activeAnnotation = handler.start(at: NSPoint(x: 10, y: y), canvas: canvas)
    handler.update(to: NSPoint(x: 50, y: y), shiftHeld: false, canvas: canvas)
    handler.update(to: NSPoint(x: 90, y: y), shiftHeld: false, canvas: canvas)
    handler.finish(canvas: canvas)
}

private func makeRedaction(y: CGFloat) -> Annotation {
    Annotation(tool: .rectangle, startPoint: NSPoint(x: 10, y: y),
               endPoint: NSPoint(x: 90, y: y + 10), color: .black, strokeWidth: 0)
}

@MainActor
private final class GestureCanvas: AnnotationCanvas {
    let currentColor: NSColor = .yellow
    let currentStrokeWidth: CGFloat = 2
    let currentMarkerSize: CGFloat = 3
    let currentLineStyle: LineStyle = .solid
    let currentArrowStyle: ArrowStyle = .single
    let arrowReversed = false
    let currentRectFillStyle: RectFillStyle = .stroke
    let currentRectCornerRadius: CGFloat = 0
    let currentMeasureInPoints = false
    let currentMeasureClampToSelection = false
    let currentLoupeSize: CGFloat = 100
    let currentLoupeMagnification: CGFloat = 2
    let currentLoupeOutlineColor: NSColor = .black
    let currentLoupeOutlineEnabled = false
    let pencilSmoothMode = 0
    let pencilPressureEnabled = false
    let currentPressure: CGFloat = 1
    var smartMarkerEnabled = true
    let currentNumberSize: CGFloat = 20
    var numberCounter = 0
    let numberStartAt = 1
    let currentNumberFormat: NumberFormat = .decimal
    let nextNumberValue = 1
    var currentStampImage: NSImage?
    var currentStampEmoji: String?
    let currentStampSize: CGFloat = 20
    var annotations: [Annotation] = []
    var undoStack: [UndoEntry] = []
    var redoStack: [UndoEntry] = []
    var activeAnnotation: Annotation?
    let selectionRect = NSRect(x: 0, y: 0, width: 100, height: 100)
    let captureDrawRect = NSRect(x: 0, y: 0, width: 100, height: 100)
    let screenshotImage: NSImage?
    var snapGuideX: CGFloat?
    var snapGuideY: CGFloat?
    var drawingCursorPoint: NSPoint = .zero
    var annotationLayerCache: NSImage? { nil }
    var errors: [String] = []
    var invalidations = 0
    init(image: NSImage) { screenshotImage = image }
    func opacityAppliedColor(for tool: AnnotationTool) -> NSColor { currentColor }
    func compositedImage() -> NSImage? { screenshotImage }
    func setNeedsDisplay() {}
    func showOverlayError(_ message: String) { errors.append(message) }
    func invalidateAnnotationRendering() { invalidations += 1 }
    func snapPoint(_ point: NSPoint, excluding: Annotation?) -> NSPoint { point }
    func appendToAnnotationCache(_ annotation: Annotation, previousCache: NSImage) {}
}
