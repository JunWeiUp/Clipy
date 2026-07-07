import AppKit
import Combine
import CoreImage
import SwiftUI

struct AnnotationRecord: Equatable {
    enum Kind: Equatable {
        case rectangle(NSRect)
        case ellipse(NSRect)
        case arrow(NSPoint, NSPoint)
        case text(NSPoint, String)
        case mosaic(NSRect)
        case pencil([NSPoint])
        case highlighter([NSPoint])
    }

    let kind: Kind
    let color: NSColor
    let lineWidth: CGFloat
}

final class AnnotationCanvasModel: ObservableObject {
    @Published var selectedTool: ScreenshotAnnotationTool = .selection
    @Published var strokeColor: NSColor = .systemRed
    @Published var lineWidth: CGFloat = 3
    @Published private(set) var annotations: [AnnotationRecord] = []

    private var undoStack: [[AnnotationRecord]] = []
    private var redoStack: [[AnnotationRecord]] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func pushState() {
        undoStack.append(annotations)
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
    }

    func add(_ annotation: AnnotationRecord) {
        pushState()
        annotations.append(annotation)
    }

    func clearAnnotations() {
        guard !annotations.isEmpty else { return }
        pushState()
        annotations.removeAll()
    }

    func resetSession() {
        annotations.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
    }

    func beginStroke() {
        pushState()
    }

    func erase(at imagePoint: NSPoint, radius: CGFloat) {
        annotations.removeAll { annotation in
            annotationIntersects(annotation, point: imagePoint, radius: radius)
        }
    }

    private func annotationIntersects(_ annotation: AnnotationRecord, point: NSPoint, radius: CGFloat) -> Bool {
        switch annotation.kind {
        case .rectangle(let rect), .ellipse(let rect), .mosaic(let rect):
            return rect.insetBy(dx: -radius, dy: -radius).contains(point)
        case .arrow(let start, let end):
            return distanceFromPoint(point, toSegmentFrom: start, to: end) <= radius + annotation.lineWidth
        case .text(let anchor, _):
            return hypot(point.x - anchor.x, point.y - anchor.y) <= radius + 12
        case .pencil(let points), .highlighter(let points):
            guard points.count >= 2 else { return false }
            for index in 1..<points.count {
                if distanceFromPoint(point, toSegmentFrom: points[index - 1], to: points[index]) <= radius + annotation.lineWidth {
                    return true
                }
            }
            return false
        }
    }

    private func distanceFromPoint(_ point: NSPoint, toSegmentFrom start: NSPoint, to end: NSPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let projection = NSPoint(x: start.x + t * dx, y: start.y + t * dy)
        return hypot(point.x - projection.x, point.y - projection.y)
    }
}

final class AnnotationCanvasView: NSView {
    enum ContentMode {
        case fit
        case fill
    }

    let model: AnnotationCanvasModel
    var contentMode: ContentMode
    var composingMode = false
    var onTextEditingChanged: ((Bool) -> Void)?

    private var baseImage: NSImage

    private var dragStart: NSPoint?
    private var currentRect: NSRect = .zero
    private var currentEnd: NSPoint?
    private var pendingTextPoint: NSPoint?
    private var inlineTextField: NSTextField?
    private var strokePoints: [NSPoint] = []
    private var eraserStrokeActive = false

    init(baseImage: NSImage, model: AnnotationCanvasModel, contentMode: ContentMode = .fit) {
        self.baseImage = baseImage
        self.model = model
        self.contentMode = contentMode
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func replaceBaseImage(_ image: NSImage) {
        baseImage = image
        needsDisplay = true
    }

    var isTextEditing: Bool { inlineTextField != nil }

    func handlePointer(event: NSEvent, at point: NSPoint) {
        switch event.type {
        case .leftMouseDown:
            handleMouseDown(at: point)
        case .leftMouseDragged:
            handleMouseDragged(at: point)
        case .leftMouseUp:
            handleMouseUp(at: point)
        default:
            break
        }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        return bounds.contains(point) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let imageRect = imageRect(in: bounds)
        if !composingMode {
            baseImage.draw(in: imageRect)
        }

        let scaleX = imageRect.width / max(baseImage.size.width, 1)
        let scaleY = imageRect.height / max(baseImage.size.height, 1)

        for annotation in model.annotations {
            draw(annotation: annotation, in: imageRect, scaleX: scaleX, scaleY: scaleY)
        }

        if let start = dragStart {
            let preview = previewAnnotation(start: start, end: currentEnd ?? start, rect: currentRect)
            draw(annotation: preview, in: imageRect, scaleX: scaleX, scaleY: scaleY)
        }

        if !strokePoints.isEmpty {
            drawFreehandPreview(in: imageRect, scaleX: scaleX, scaleY: scaleY)
        }
    }

    private func imageRect(in container: NSRect) -> NSRect {
        switch contentMode {
        case .fill:
            return container
        case .fit:
            return aspectFitRect(for: baseImage.size, in: container)
        }
    }

    private func aspectFitRect(for imageSize: NSSize, in container: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return container }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return NSRect(
            x: container.midX - width / 2,
            y: container.midY - height / 2,
            width: width,
            height: height
        )
    }

    private func imagePoint(from viewPoint: NSPoint, imageRect: NSRect) -> NSPoint {
        let scaleX = baseImage.size.width / imageRect.width
        let scaleY = baseImage.size.height / imageRect.height
        return NSPoint(
            x: (viewPoint.x - imageRect.origin.x) * scaleX,
            y: (viewPoint.y - imageRect.origin.y) * scaleY
        )
    }

    private func viewRect(from rect: NSRect, in container: NSRect, scaleX: CGFloat, scaleY: CGFloat) -> NSRect {
        NSRect(
            x: container.origin.x + rect.origin.x * scaleX,
            y: container.origin.y + rect.origin.y * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
    }

    private func draw(annotation: AnnotationRecord, in imageRect: NSRect, scaleX: CGFloat, scaleY: CGFloat) {
        annotation.color.setStroke()
        annotation.color.setFill()

        switch annotation.kind {
        case .rectangle(let rect):
            let viewRect = viewRect(from: rect, in: imageRect, scaleX: scaleX, scaleY: scaleY)
            let path = NSBezierPath(rect: viewRect)
            path.lineWidth = annotation.lineWidth
            path.stroke()
        case .ellipse(let rect):
            let viewRect = viewRect(from: rect, in: imageRect, scaleX: scaleX, scaleY: scaleY)
            let path = NSBezierPath(ovalIn: viewRect)
            path.lineWidth = annotation.lineWidth
            path.stroke()
        case .arrow(let start, let end):
            let viewStart = NSPoint(x: imageRect.origin.x + start.x * scaleX, y: imageRect.origin.y + start.y * scaleY)
            let viewEnd = NSPoint(x: imageRect.origin.x + end.x * scaleX, y: imageRect.origin.y + end.y * scaleY)
            drawArrow(from: viewStart, to: viewEnd, lineWidth: annotation.lineWidth, color: annotation.color)
        case .text(let point, let text):
            let viewPoint = NSPoint(x: imageRect.origin.x + point.x * scaleX, y: imageRect.origin.y + point.y * scaleY)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: max(14, annotation.lineWidth * 5)),
                .foregroundColor: annotation.color
            ]
            (text as NSString).draw(at: viewPoint, withAttributes: attributes)
        case .mosaic(let rect):
            drawMosaic(in: viewRect(from: rect, in: imageRect, scaleX: scaleX, scaleY: scaleY))
        case .pencil(let points):
            drawFreehand(points, in: imageRect, scaleX: scaleX, scaleY: scaleY, color: annotation.color, lineWidth: annotation.lineWidth, alpha: 1)
        case .highlighter(let points):
            drawFreehand(points, in: imageRect, scaleX: scaleX, scaleY: scaleY, color: annotation.color, lineWidth: annotation.lineWidth, alpha: 0.35)
        }
    }

    private func drawFreehand(_ points: [NSPoint], in imageRect: NSRect, scaleX: CGFloat, scaleY: CGFloat, color: NSColor, lineWidth: CGFloat, alpha: CGFloat) {
        guard points.count >= 2 else { return }
        let path = NSBezierPath()
        path.move(to: NSPoint(x: imageRect.origin.x + points[0].x * scaleX, y: imageRect.origin.y + points[0].y * scaleY))
        for point in points.dropFirst() {
            path.line(to: NSPoint(x: imageRect.origin.x + point.x * scaleX, y: imageRect.origin.y + point.y * scaleY))
        }
        path.lineWidth = lineWidth
        color.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }

    private func drawFreehandPreview(in imageRect: NSRect, scaleX: CGFloat, scaleY: CGFloat) {
        let alpha: CGFloat = model.selectedTool == .highlighter ? 0.35 : 1
        drawFreehand(strokePoints, in: imageRect, scaleX: scaleX, scaleY: scaleY, color: model.strokeColor, lineWidth: model.lineWidth, alpha: alpha)
    }

    private func drawArrow(from start: NSPoint, to end: NSPoint, lineWidth: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.lineWidth = lineWidth
        color.setStroke()
        path.stroke()

        let angle = atan2(end.y - start.y, end.x - start.x)
        let arrowLength: CGFloat = max(10, lineWidth * 4)
        let arrowAngle: CGFloat = .pi / 6

        let p1 = NSPoint(
            x: end.x - arrowLength * cos(angle - arrowAngle),
            y: end.y - arrowLength * sin(angle - arrowAngle)
        )
        let p2 = NSPoint(
            x: end.x - arrowLength * cos(angle + arrowAngle),
            y: end.y - arrowLength * sin(angle + arrowAngle)
        )

        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: p1)
        head.line(to: p2)
        head.close()
        color.setFill()
        head.fill()
    }

    private func applyPixellate(to ciImage: CIImage, scale: Float) -> CIImage? {
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        return filter.outputImage
    }

    private func drawMosaic(in rect: NSRect) {
        if composingMode {
            drawComposingMosaicPlaceholder(in: rect)
            return
        }

        guard let cgImage = ScreenshotImageProcessor.bestCGImage(from: baseImage) else { return }
        let imageRect = imageRect(in: bounds)
        let scaleX = baseImage.size.width / imageRect.width
        let scaleY = baseImage.size.height / imageRect.height

        let sourceRect = CGRect(
            x: (rect.origin.x - imageRect.origin.x) * scaleX,
            y: (rect.origin.y - imageRect.origin.y) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        ).integral

        guard sourceRect.width > 1, sourceRect.height > 1,
              let cropped = cgImage.cropping(to: sourceRect) else { return }

        let ciImage = CIImage(cgImage: cropped)
        let scale = Float(max(8, min(sourceRect.width, sourceRect.height) / 12))
        guard let output = applyPixellate(to: ciImage, scale: scale) else { return }

        let context = ScreenshotImageProcessor.sharedCIContext
        guard let result = context.createCGImage(output, from: output.extent) else { return }
        let mosaicImage = NSImage(cgImage: result, size: rect.size)
        mosaicImage.draw(in: rect)
    }

    private func drawComposingMosaicPlaceholder(in rect: NSRect) {
        guard rect.width > 1, rect.height > 1 else { return }

        NSColor.black.withAlphaComponent(0.12).setFill()
        rect.fill()

        let blockSize: CGFloat = 8
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX
            var column = Int((y - rect.minY) / blockSize)
            while x < rect.maxX {
                let block = NSRect(
                    x: x,
                    y: y,
                    width: min(blockSize, rect.maxX - x),
                    height: min(blockSize, rect.maxY - y)
                )
                let row = Int((x - rect.minX) / blockSize)
                let shaded = (row + column) % 2 == 0
                (shaded ? NSColor.white.withAlphaComponent(0.35) : NSColor.black.withAlphaComponent(0.2)).setFill()
                block.fill()
                x += blockSize
            }
            y += blockSize
            column += 1
        }

        NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        handleMouseDown(at: convert(event.locationInWindow, from: nil))
    }

    private func handleMouseDown(at point: NSPoint) {
        let imageRect = imageRect(in: bounds)
        guard imageRect.contains(point) else { return }

        if model.selectedTool == .text {
            pendingTextPoint = imagePoint(from: point, imageRect: imageRect)
            showInlineTextField(at: point)
            return
        }

        if model.selectedTool == .eraser {
            eraserStrokeActive = true
            model.beginStroke()
            erase(at: point, imageRect: imageRect)
            return
        }

        if model.selectedTool == .pencil || model.selectedTool == .highlighter {
            strokePoints = [imagePoint(from: point, imageRect: imageRect)]
            needsDisplay = true
            return
        }

        dragStart = point
        currentRect = NSRect(origin: point, size: .zero)
        currentEnd = point
    }

    override func mouseDragged(with event: NSEvent) {
        handleMouseDragged(at: convert(event.locationInWindow, from: nil))
    }

    private func handleMouseDragged(at point: NSPoint) {
        let imageRect = imageRect(in: bounds)

        if model.selectedTool == .eraser, eraserStrokeActive {
            erase(at: point, imageRect: imageRect)
            return
        }

        if model.selectedTool == .pencil || model.selectedTool == .highlighter {
            guard imageRect.contains(point) else { return }
            strokePoints.append(imagePoint(from: point, imageRect: imageRect))
            needsDisplay = true
            return
        }

        guard let start = dragStart else { return }
        currentEnd = point
        currentRect = NSRect(
            x: min(start.x, point.x),
            y: min(start.y, point.y),
            width: abs(point.x - start.x),
            height: abs(point.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        handleMouseUp(at: convert(event.locationInWindow, from: nil))
    }

    private func handleMouseUp(at point: NSPoint) {
        let imageRect = imageRect(in: bounds)

        if model.selectedTool == .eraser {
            eraserStrokeActive = false
            needsDisplay = true
            return
        }

        if model.selectedTool == .pencil || model.selectedTool == .highlighter {
            if strokePoints.count >= 2 {
                let kind: AnnotationRecord.Kind = model.selectedTool == .pencil
                    ? .pencil(strokePoints)
                    : .highlighter(strokePoints)
                model.add(AnnotationRecord(kind: kind, color: model.strokeColor, lineWidth: model.lineWidth))
            }
            strokePoints = []
            needsDisplay = true
            return
        }

        guard let start = dragStart else { return }
        let imageStart = imagePoint(from: start, imageRect: imageRect)
        let imageEnd = imagePoint(from: point, imageRect: imageRect)

        let annotation: AnnotationRecord?
        switch model.selectedTool {
        case .selection:
            annotation = nil
        case .rectangle:
            let rect = normalizedImageRect(from: imageStart, to: imageEnd)
            annotation = rect.width > 2 && rect.height > 2
                ? AnnotationRecord(kind: .rectangle(rect), color: model.strokeColor, lineWidth: model.lineWidth)
                : nil
        case .ellipse:
            let rect = normalizedImageRect(from: imageStart, to: imageEnd)
            annotation = rect.width > 2 && rect.height > 2
                ? AnnotationRecord(kind: .ellipse(rect), color: model.strokeColor, lineWidth: model.lineWidth)
                : nil
        case .arrow:
            annotation = distance(from: imageStart, to: imageEnd) > 4
                ? AnnotationRecord(kind: .arrow(imageStart, imageEnd), color: model.strokeColor, lineWidth: model.lineWidth)
                : nil
        case .mosaic:
            let rect = normalizedImageRect(from: imageStart, to: imageEnd)
            annotation = rect.width > 4 && rect.height > 4
                ? AnnotationRecord(kind: .mosaic(rect), color: model.strokeColor, lineWidth: model.lineWidth)
                : nil
        case .text:
            annotation = nil
        case .pencil, .highlighter, .eraser:
            annotation = nil
        }

        if let annotation {
            model.add(annotation)
        }

        dragStart = nil
        currentRect = .zero
        currentEnd = nil
        needsDisplay = true
    }

    private func normalizedImageRect(from start: NSPoint, to end: NSPoint) -> NSRect {
        NSRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func distance(from a: NSPoint, to b: NSPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func previewAnnotation(start: NSPoint, end: NSPoint, rect: NSRect) -> AnnotationRecord {
        let imageRect = imageRect(in: bounds)
        let imageStart = imagePoint(from: start, imageRect: imageRect)
        let imageEnd = imagePoint(from: end, imageRect: imageRect)

        switch model.selectedTool {
        case .selection:
            return AnnotationRecord(kind: .rectangle(.zero), color: model.strokeColor, lineWidth: model.lineWidth)
        case .rectangle:
            return AnnotationRecord(kind: .rectangle(normalizedImageRect(from: imageStart, to: imageEnd)), color: model.strokeColor, lineWidth: model.lineWidth)
        case .ellipse:
            return AnnotationRecord(kind: .ellipse(normalizedImageRect(from: imageStart, to: imageEnd)), color: model.strokeColor, lineWidth: model.lineWidth)
        case .arrow:
            return AnnotationRecord(kind: .arrow(imageStart, imageEnd), color: model.strokeColor, lineWidth: model.lineWidth)
        case .mosaic:
            return AnnotationRecord(kind: .mosaic(normalizedImageRect(from: imageStart, to: imageEnd)), color: model.strokeColor, lineWidth: model.lineWidth)
        case .text:
            return AnnotationRecord(kind: .text(imageStart, ""), color: model.strokeColor, lineWidth: model.lineWidth)
        case .pencil, .highlighter, .eraser:
            return AnnotationRecord(kind: .rectangle(.zero), color: model.strokeColor, lineWidth: model.lineWidth)
        }
    }

    private func erase(at viewPoint: NSPoint, imageRect: NSRect) {
        let imagePoint = imagePoint(from: viewPoint, imageRect: imageRect)
        model.erase(at: imagePoint, radius: model.lineWidth)
        needsDisplay = true
    }

    private func showInlineTextField(at viewPoint: NSPoint) {
        inlineTextField?.removeFromSuperview()

        let field = NSTextField(frame: NSRect(x: viewPoint.x, y: viewPoint.y, width: 200, height: 24))
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = NSFont.systemFont(ofSize: max(14, model.lineWidth * 5))
        field.textColor = model.strokeColor
        field.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9)
        field.delegate = self
        field.target = self
        field.action = #selector(commitInlineText(_:))
        addSubview(field)
        inlineTextField = field
        onTextEditingChanged?(true)
        (window as? CaptureAnnotationPanel)?.activateForTextInput()
        window?.makeFirstResponder(field)
    }

    @objc private func commitInlineText(_ sender: NSTextField) {
        guard let point = pendingTextPoint else {
            dismissInlineTextField()
            return
        }
        let text = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            model.add(AnnotationRecord(kind: .text(point, text), color: model.strokeColor, lineWidth: model.lineWidth))
            needsDisplay = true
        }
        dismissInlineTextField()
    }

    private func dismissInlineTextField() {
        inlineTextField?.removeFromSuperview()
        inlineTextField = nil
        pendingTextPoint = nil
        onTextEditingChanged?(false)
    }

    static func flatten(
        baseImage: NSImage,
        model: AnnotationCanvasModel,
        composeSize: NSSize? = nil
    ) -> NSImage? {
        let view = AnnotationCanvasView(baseImage: baseImage, model: model, contentMode: .fill)
        let referenceSize = composeSize ?? baseImage.size
        return view.renderFlattenedImage(composeSize: referenceSize)
    }

    func renderFlattenedImage(composeSize: NSSize? = nil) -> NSImage? {
        guard baseImage.size.width > 0, baseImage.size.height > 0 else { return nil }
        guard let cgImage = ScreenshotImageProcessor.bestCGImage(from: baseImage) else { return nil }

        let pixelW = cgImage.width
        let pixelH = cgImage.height
        guard pixelW > 0, pixelH > 0,
              let context = CGContext(
                  data: nil,
                  width: pixelW,
                  height: pixelH,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixelW, height: pixelH))

        let referenceSize = composeSize ?? baseImage.size
        let scaleX = CGFloat(pixelW) / max(referenceSize.width, 1)
        let scaleY = CGFloat(pixelH) / max(referenceSize.height, 1)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for annotation in model.annotations {
            drawFlattened(
                annotation: annotation,
                imageHeight: CGFloat(pixelH),
                scaleX: scaleX,
                scaleY: scaleY
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: baseImage.size)
    }

    static func flatten(baseImage: NSImage, model: AnnotationCanvasModel) -> NSImage? {
        flatten(baseImage: baseImage, model: model, composeSize: nil)
    }

    private func drawFlattened(
        annotation: AnnotationRecord,
        imageHeight: CGFloat,
        scaleX: CGFloat = 1,
        scaleY: CGFloat = 1
    ) {
        annotation.color.setStroke()
        annotation.color.setFill()

        switch annotation.kind {
        case .rectangle(let rect):
            let path = NSBezierPath(rect: flippedRect(scaledRect(rect, scaleX: scaleX, scaleY: scaleY), imageHeight: imageHeight))
            path.lineWidth = annotation.lineWidth * max(scaleX, scaleY)
            path.stroke()
        case .ellipse(let rect):
            let path = NSBezierPath(ovalIn: flippedRect(scaledRect(rect, scaleX: scaleX, scaleY: scaleY), imageHeight: imageHeight))
            path.lineWidth = annotation.lineWidth * max(scaleX, scaleY)
            path.stroke()
        case .arrow(let start, let end):
            let flippedStart = flippedPoint(scaledPoint(start, scaleX: scaleX, scaleY: scaleY), imageHeight: imageHeight)
            let flippedEnd = flippedPoint(scaledPoint(end, scaleX: scaleX, scaleY: scaleY), imageHeight: imageHeight)
            drawArrow(from: flippedStart, to: flippedEnd, lineWidth: annotation.lineWidth * max(scaleX, scaleY), color: annotation.color)
        case .text(let point, let text):
            let lineScale = max(scaleX, scaleY)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: max(14, annotation.lineWidth * 5 * lineScale)),
                .foregroundColor: annotation.color
            ]
            (text as NSString).draw(
                at: flippedPoint(scaledPoint(point, scaleX: scaleX, scaleY: scaleY), imageHeight: imageHeight),
                withAttributes: attributes
            )
        case .mosaic(let rect):
            drawFlattenedMosaic(
                in: scaledRect(rect, scaleX: scaleX, scaleY: scaleY),
                imageHeight: imageHeight
            )
        case .pencil(let points):
            drawFlattenedFreehand(
                points,
                imageHeight: imageHeight,
                scaleX: scaleX,
                scaleY: scaleY,
                color: annotation.color,
                lineWidth: annotation.lineWidth * max(scaleX, scaleY),
                alpha: 1
            )
        case .highlighter(let points):
            drawFlattenedFreehand(
                points,
                imageHeight: imageHeight,
                scaleX: scaleX,
                scaleY: scaleY,
                color: annotation.color,
                lineWidth: annotation.lineWidth * max(scaleX, scaleY),
                alpha: 0.35
            )
        }
    }

    private func scaledRect(_ rect: NSRect, scaleX: CGFloat, scaleY: CGFloat) -> NSRect {
        NSRect(
            x: rect.origin.x * scaleX,
            y: rect.origin.y * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
    }

    private func scaledPoint(_ point: NSPoint, scaleX: CGFloat, scaleY: CGFloat) -> NSPoint {
        NSPoint(x: point.x * scaleX, y: point.y * scaleY)
    }

    private func drawFlattenedFreehand(
        _ points: [NSPoint],
        imageHeight: CGFloat,
        scaleX: CGFloat = 1,
        scaleY: CGFloat = 1,
        color: NSColor,
        lineWidth: CGFloat,
        alpha: CGFloat
    ) {
        guard points.count >= 2 else { return }
        let path = NSBezierPath()
        path.move(to: flippedPoint(scaledPoint(points[0], scaleX: scaleX, scaleY: scaleY), imageHeight: imageHeight))
        for point in points.dropFirst() {
            path.line(to: flippedPoint(scaledPoint(point, scaleX: scaleX, scaleY: scaleY), imageHeight: imageHeight))
        }
        path.lineWidth = lineWidth
        color.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }

    private func flippedRect(_ rect: NSRect, imageHeight: CGFloat) -> NSRect {
        NSRect(
            x: rect.origin.x,
            y: imageHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    private func flippedPoint(_ point: NSPoint, imageHeight: CGFloat) -> NSPoint {
        NSPoint(x: point.x, y: imageHeight - point.y)
    }

    private func drawFlattenedMosaic(in rect: NSRect, imageHeight: CGFloat) {
        guard let cgImage = ScreenshotImageProcessor.bestCGImage(from: baseImage) else { return }
        let flipped = flippedRect(rect, imageHeight: imageHeight)
        let sourceRect = CGRect(
            x: flipped.origin.x,
            y: flipped.origin.y,
            width: flipped.width,
            height: flipped.height
        ).integral

        guard sourceRect.width > 1, sourceRect.height > 1,
              let cropped = cgImage.cropping(to: sourceRect) else { return }

        let ciImage = CIImage(cgImage: cropped)
        let scale = Float(max(8, min(sourceRect.width, sourceRect.height) / 12))
        guard let output = applyPixellate(to: ciImage, scale: scale) else { return }

        let context = ScreenshotImageProcessor.sharedCIContext
        guard let result = context.createCGImage(output, from: output.extent) else { return }
        let mosaicImage = NSImage(cgImage: result, size: flipped.size)
        mosaicImage.draw(in: flipped)
    }
}

struct AnnotationCanvasRepresentable: NSViewRepresentable {
    let baseImage: NSImage
    @ObservedObject var model: AnnotationCanvasModel
    var contentMode: AnnotationCanvasView.ContentMode = .fit
    var canvasRef: Binding<AnnotationCanvasView?>

    func makeNSView(context: Context) -> AnnotationCanvasView {
        let view = AnnotationCanvasView(baseImage: baseImage, model: model, contentMode: contentMode)
        DispatchQueue.main.async {
            canvasRef.wrappedValue = view
        }
        return view
    }

    func updateNSView(_ nsView: AnnotationCanvasView, context: Context) {
        nsView.contentMode = contentMode
        nsView.needsDisplay = true
    }
}

extension AnnotationCanvasView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismissInlineTextField()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if let field = control as? NSTextField {
                commitInlineText(field)
            }
            return true
        }
        return false
    }
}
