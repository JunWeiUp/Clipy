import AppKit
import Combine
import CoreImage
import SwiftUI

struct TextAnnotationStyle: Equatable {
    var fontSize: CGFloat
    var isBold: Bool
    var isItalic: Bool
    var isUnderline: Bool
    var backgroundColor: NSColor?

    static let `default` = TextAnnotationStyle(
        fontSize: 18,
        isBold: false,
        isItalic: false,
        isUnderline: false,
        backgroundColor: nil
    )

    var clampedFontSize: CGFloat {
        min(96, max(12, fontSize))
    }

    func makeFont(scale: CGFloat = 1) -> NSFont {
        let size = clampedFontSize * scale
        var font: NSFont
        if isBold && isItalic {
            font = NSFont.systemFont(ofSize: size, weight: .bold)
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        } else if isBold {
            font = NSFont.systemFont(ofSize: size, weight: .bold)
        } else if isItalic {
            font = NSFont.systemFont(ofSize: size)
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        } else {
            font = NSFont.systemFont(ofSize: size)
        }
        return font
    }

    func attributes(color: NSColor, scale: CGFloat = 1) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: makeFont(scale: scale),
            .foregroundColor: color
        ]
        if isUnderline {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if let backgroundColor {
            attrs[.backgroundColor] = backgroundColor
        }
        return attrs
    }
}

enum MosaicBrushSize: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var radius: CGFloat {
        switch self {
        case .small: return 8
        case .medium: return 16
        case .large: return 28
        }
    }
}

enum MosaicAnnotationMode: String, CaseIterable {
    case rect
    case brush
}

struct AnnotationRecord: Equatable {
    enum Kind: Equatable {
        case rectangle(NSRect)
        case ellipse(NSRect)
        case arrow(start: NSPoint, end: NSPoint, control: NSPoint?, dashed: Bool)
        case text(NSPoint, String, TextAnnotationStyle)
        case mosaic(NSRect)
        case mosaicStroke([NSPoint], brushRadius: CGFloat)
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
    @Published var fontSize: CGFloat = 18
    @Published var textBold = false
    @Published var textItalic = false
    @Published var textUnderline = false
    @Published var textBackgroundEnabled = false
    @Published var textBackgroundColor: NSColor = NSColor.systemYellow.withAlphaComponent(0.45)
    @Published var arrowDashed = false
    @Published var mosaicMode: MosaicAnnotationMode = .rect
    @Published var mosaicBrushSize: MosaicBrushSize = .medium
    @Published private(set) var annotations: [AnnotationRecord] = []

    private var undoStack: [[AnnotationRecord]] = []
    private var redoStack: [[AnnotationRecord]] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var currentTextStyle: TextAnnotationStyle {
        TextAnnotationStyle(
            fontSize: fontSize,
            isBold: textBold,
            isItalic: textItalic,
            isUnderline: textUnderline,
            backgroundColor: textBackgroundEnabled ? textBackgroundColor : nil
        )
    }

    init() {
        loadPersistedTextStyle()
    }

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

    func persistTextStyle() {
        PreferencesManager.shared.screenshotTextFontSize = fontSize
        PreferencesManager.shared.screenshotTextBold = textBold
        PreferencesManager.shared.screenshotTextItalic = textItalic
        PreferencesManager.shared.screenshotTextUnderline = textUnderline
        PreferencesManager.shared.screenshotTextBackgroundEnabled = textBackgroundEnabled
    }

    func loadPersistedTextStyle() {
        let prefs = PreferencesManager.shared
        fontSize = prefs.screenshotTextFontSize
        textBold = prefs.screenshotTextBold
        textItalic = prefs.screenshotTextItalic
        textUnderline = prefs.screenshotTextUnderline
        textBackgroundEnabled = prefs.screenshotTextBackgroundEnabled
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
        case .arrow(let start, let end, let control, _):
            return distanceToArrow(point, start: start, end: end, control: control) <= radius + annotation.lineWidth
        case .text(let anchor, _, let style):
            return hypot(point.x - anchor.x, point.y - anchor.y) <= radius + style.clampedFontSize
        case .mosaicStroke(let points, let brushRadius):
            guard !points.isEmpty else { return false }
            if points.count == 1 {
                return hypot(point.x - points[0].x, point.y - points[0].y) <= radius + brushRadius
            }
            for index in 1..<points.count {
                if distanceFromPoint(point, toSegmentFrom: points[index - 1], to: points[index]) <= radius + brushRadius {
                    return true
                }
            }
            return false
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

    private func distanceToArrow(_ point: NSPoint, start: NSPoint, end: NSPoint, control: NSPoint?) -> CGFloat {
        guard let control else {
            return distanceFromPoint(point, toSegmentFrom: start, to: end)
        }
        var minDistance = CGFloat.greatestFiniteMagnitude
        let samples = 24
        var previous = start
        for i in 1...samples {
            let t = CGFloat(i) / CGFloat(samples)
            let sample = quadraticPoint(t: t, start: start, control: control, end: end)
            minDistance = min(minDistance, distanceFromPoint(point, toSegmentFrom: previous, to: sample))
            previous = sample
        }
        return minDistance
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

func quadraticPoint(t: CGFloat, start: NSPoint, control: NSPoint, end: NSPoint) -> NSPoint {
    let u = 1 - t
    return NSPoint(
        x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
        y: u * u * start.y + 2 * u * t * control.y + t * t * end.y
    )
}

func arrowControlPoint(from path: [NSPoint], shiftHeld: Bool) -> NSPoint? {
    guard !shiftHeld, path.count >= 3 else { return nil }
    let start = path[0]
    let end = path[path.count - 1]
    let dx = end.x - start.x
    let dy = end.y - start.y
    let length = hypot(dx, dy)
    guard length > 4 else { return nil }

    var farthest: NSPoint?
    var farthestDistance: CGFloat = 0
    for point in path.dropFirst().dropLast() {
        let distance = abs((point.x - start.x) * dy - (point.y - start.y) * dx) / length
        if distance > farthestDistance {
            farthestDistance = distance
            farthest = point
        }
    }
    guard let farthest, farthestDistance > 6 else { return nil }
    return farthest
}

func shiftConstrainedPoint(from start: NSPoint, to end: NSPoint) -> NSPoint {
    let dx = abs(end.x - start.x)
    let dy = abs(end.y - start.y)
    if dx >= dy {
        return NSPoint(x: end.x, y: start.y)
    }
    return NSPoint(x: start.x, y: end.y)
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
    private var arrowPathPoints: [NSPoint] = []
    private var pendingTextPoint: NSPoint?
    private var inlineTextField: NSTextField?
    private var strokePoints: [NSPoint] = []
    private var eraserStrokeActive = false
    private var shiftHeldDuringStroke = false

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
        shiftHeldDuringStroke = event.modifierFlags.contains(.shift)
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

        if let start = dragStart, model.selectedTool != .pencil, model.selectedTool != .highlighter {
            let preview = previewAnnotation(start: start, end: currentEnd ?? start, rect: currentRect)
            draw(annotation: preview, in: imageRect, scaleX: scaleX, scaleY: scaleY)
        }

        if !strokePoints.isEmpty {
            if model.selectedTool == .mosaic, model.mosaicMode == .brush {
                drawMosaicStrokePreview(strokePoints, brushRadius: model.mosaicBrushSize.radius, in: imageRect, scaleX: scaleX, scaleY: scaleY)
            } else {
                drawFreehandPreview(in: imageRect, scaleX: scaleX, scaleY: scaleY)
            }
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
        case .arrow(let start, let end, let control, let dashed):
            let viewStart = NSPoint(x: imageRect.origin.x + start.x * scaleX, y: imageRect.origin.y + start.y * scaleY)
            let viewEnd = NSPoint(x: imageRect.origin.x + end.x * scaleX, y: imageRect.origin.y + end.y * scaleY)
            let viewControl = control.map {
                NSPoint(x: imageRect.origin.x + $0.x * scaleX, y: imageRect.origin.y + $0.y * scaleY)
            }
            drawArrow(
                from: viewStart,
                to: viewEnd,
                control: viewControl,
                lineWidth: annotation.lineWidth,
                color: annotation.color,
                dashed: dashed
            )
        case .text(let point, let text, let style):
            let viewPoint = NSPoint(x: imageRect.origin.x + point.x * scaleX, y: imageRect.origin.y + point.y * scaleY)
            let attrs = style.attributes(color: annotation.color, scale: max(scaleX, scaleY))
            (text as NSString).draw(at: viewPoint, withAttributes: attrs)
        case .mosaic(let rect):
            drawMosaic(in: viewRect(from: rect, in: imageRect, scaleX: scaleX, scaleY: scaleY))
        case .mosaicStroke(let points, let brushRadius):
            drawMosaicStroke(points, brushRadius: brushRadius, in: imageRect, scaleX: scaleX, scaleY: scaleY)
        case .pencil(let points):
            drawFreehand(
                points,
                in: imageRect,
                scaleX: scaleX,
                scaleY: scaleY,
                color: annotation.color,
                lineWidth: annotation.lineWidth,
                multiply: false
            )
        case .highlighter(let points):
            drawFreehand(
                points,
                in: imageRect,
                scaleX: scaleX,
                scaleY: scaleY,
                color: annotation.color,
                lineWidth: annotation.lineWidth,
                multiply: true
            )
        }
    }

    private func drawFreehand(
        _ points: [NSPoint],
        in imageRect: NSRect,
        scaleX: CGFloat,
        scaleY: CGFloat,
        color: NSColor,
        lineWidth: CGFloat,
        multiply: Bool
    ) {
        guard points.count >= 2 else { return }
        let path = NSBezierPath()
        path.move(to: NSPoint(x: imageRect.origin.x + points[0].x * scaleX, y: imageRect.origin.y + points[0].y * scaleY))
        for point in points.dropFirst() {
            path.line(to: NSPoint(x: imageRect.origin.x + point.x * scaleX, y: imageRect.origin.y + point.y * scaleY))
        }
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        let cgContext = NSGraphicsContext.current?.cgContext
        if multiply {
            cgContext?.saveGState()
            cgContext?.setBlendMode(.multiply)
            color.withAlphaComponent(0.85).setStroke()
            path.stroke()
            cgContext?.restoreGState()
        } else {
            color.setStroke()
            path.stroke()
        }
    }

    private func drawFreehandPreview(in imageRect: NSRect, scaleX: CGFloat, scaleY: CGFloat) {
        let multiply = model.selectedTool == .highlighter
        drawFreehand(
            strokePoints,
            in: imageRect,
            scaleX: scaleX,
            scaleY: scaleY,
            color: model.strokeColor,
            lineWidth: model.lineWidth,
            multiply: multiply
        )
    }

    private func drawArrow(
        from start: NSPoint,
        to end: NSPoint,
        control: NSPoint?,
        lineWidth: CGFloat,
        color: NSColor,
        dashed: Bool
    ) {
        let path = NSBezierPath()
        path.move(to: start)
        if let control {
            path.curve(to: end, controlPoint1: control, controlPoint2: control)
        } else {
            path.line(to: end)
        }
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        if dashed {
            path.setLineDash([max(4, lineWidth * 2), max(3, lineWidth * 1.5)], count: 2, phase: 0)
        }
        color.setStroke()
        path.stroke()

        let angle: CGFloat
        if let control {
            // Tangent at end of quadratic Bezier: 2(1-t)(C-P0)+2t(P1-C) at t=1 → P1-C
            angle = atan2(end.y - control.y, end.x - control.x)
        } else {
            angle = atan2(end.y - start.y, end.x - start.x)
        }
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

    private func drawMosaicStroke(
        _ points: [NSPoint],
        brushRadius: CGFloat,
        in imageRect: NSRect,
        scaleX: CGFloat,
        scaleY: CGFloat
    ) {
        guard !points.isEmpty else { return }
        if composingMode {
            drawMosaicStrokePreview(points, brushRadius: brushRadius, in: imageRect, scaleX: scaleX, scaleY: scaleY)
            return
        }

        let sampled = densifyPoints(points, spacing: max(2, brushRadius * 0.45))
        for point in sampled {
            let viewCenter = NSPoint(
                x: imageRect.origin.x + point.x * scaleX,
                y: imageRect.origin.y + point.y * scaleY
            )
            let viewRadius = brushRadius * max(scaleX, scaleY)
            let rect = NSRect(
                x: viewCenter.x - viewRadius,
                y: viewCenter.y - viewRadius,
                width: viewRadius * 2,
                height: viewRadius * 2
            )
            drawCircularMosaic(in: rect)
        }
    }

    private func drawMosaicStrokePreview(
        _ points: [NSPoint],
        brushRadius: CGFloat,
        in imageRect: NSRect,
        scaleX: CGFloat,
        scaleY: CGFloat
    ) {
        let sampled = densifyPoints(points, spacing: max(2, brushRadius * 0.6))
        for point in sampled {
            let viewCenter = NSPoint(
                x: imageRect.origin.x + point.x * scaleX,
                y: imageRect.origin.y + point.y * scaleY
            )
            let viewRadius = brushRadius * max(scaleX, scaleY)
            let rect = NSRect(
                x: viewCenter.x - viewRadius,
                y: viewCenter.y - viewRadius,
                width: viewRadius * 2,
                height: viewRadius * 2
            )
            drawComposingMosaicPlaceholder(in: rect, circular: true)
        }
    }

    private func drawCircularMosaic(in rect: NSRect) {
        guard rect.width > 1, rect.height > 1 else { return }
        let path = NSBezierPath(ovalIn: rect)
        NSGraphicsContext.current?.saveGraphicsState()
        path.setClip()
        drawMosaic(in: rect)
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private func densifyPoints(_ points: [NSPoint], spacing: CGFloat) -> [NSPoint] {
        guard points.count >= 2 else { return points }
        var result: [NSPoint] = [points[0]]
        for index in 1..<points.count {
            let start = points[index - 1]
            let end = points[index]
            let distance = hypot(end.x - start.x, end.y - start.y)
            guard distance > spacing else {
                result.append(end)
                continue
            }
            let steps = Int(distance / spacing)
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                result.append(NSPoint(
                    x: start.x + (end.x - start.x) * t,
                    y: start.y + (end.y - start.y) * t
                ))
            }
        }
        return result
    }

    private func drawComposingMosaicPlaceholder(in rect: NSRect, circular: Bool = false) {
        guard rect.width > 1, rect.height > 1 else { return }

        NSGraphicsContext.current?.saveGraphicsState()
        if circular {
            NSBezierPath(ovalIn: rect).setClip()
        }

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
        let border = circular ? NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)) : NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        shiftHeldDuringStroke = event.modifierFlags.contains(.shift)
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

        if model.selectedTool == .mosaic, model.mosaicMode == .brush {
            strokePoints = [imagePoint(from: point, imageRect: imageRect)]
            needsDisplay = true
            return
        }

        if model.selectedTool == .arrow {
            let imagePt = imagePoint(from: point, imageRect: imageRect)
            arrowPathPoints = [imagePt]
            dragStart = point
            currentEnd = point
            currentRect = NSRect(origin: point, size: .zero)
            needsDisplay = true
            return
        }

        dragStart = point
        currentRect = NSRect(origin: point, size: .zero)
        currentEnd = point
    }

    override func mouseDragged(with event: NSEvent) {
        shiftHeldDuringStroke = event.modifierFlags.contains(.shift)
        handleMouseDragged(at: convert(event.locationInWindow, from: nil))
    }

    private func handleMouseDragged(at point: NSPoint) {
        let imageRect = imageRect(in: bounds)

        if model.selectedTool == .eraser, eraserStrokeActive {
            erase(at: point, imageRect: imageRect)
            return
        }

        if model.selectedTool == .pencil || model.selectedTool == .highlighter {
            guard imageRect.contains(point), let first = strokePoints.first else { return }
            var imagePt = imagePoint(from: point, imageRect: imageRect)
            if shiftHeldDuringStroke {
                imagePt = shiftConstrainedPoint(from: first, to: imagePt)
                strokePoints = [first, imagePt]
            } else {
                strokePoints.append(imagePt)
            }
            needsDisplay = true
            return
        }

        if model.selectedTool == .mosaic, model.mosaicMode == .brush {
            guard imageRect.contains(point) else { return }
            strokePoints.append(imagePoint(from: point, imageRect: imageRect))
            needsDisplay = true
            return
        }

        if model.selectedTool == .arrow {
            guard let start = dragStart else { return }
            currentEnd = point
            let imagePt = imagePoint(from: point, imageRect: imageRect)
            if shiftHeldDuringStroke, let first = arrowPathPoints.first {
                let constrained = shiftConstrainedPoint(from: first, to: imagePt)
                arrowPathPoints = [first, constrained]
                currentEnd = NSPoint(
                    x: imageRect.origin.x + constrained.x * (imageRect.width / max(baseImage.size.width, 1)),
                    y: imageRect.origin.y + constrained.y * (imageRect.height / max(baseImage.size.height, 1))
                )
            } else {
                arrowPathPoints.append(imagePt)
            }
            currentRect = NSRect(
                x: min(start.x, point.x),
                y: min(start.y, point.y),
                width: abs(point.x - start.x),
                height: abs(point.y - start.y)
            )
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
        shiftHeldDuringStroke = event.modifierFlags.contains(.shift)
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
                var points = strokePoints
                if shiftHeldDuringStroke, let first = points.first, let last = points.last {
                    points = [first, shiftConstrainedPoint(from: first, to: last)]
                }
                let kind: AnnotationRecord.Kind = model.selectedTool == .pencil
                    ? .pencil(points)
                    : .highlighter(points)
                model.add(AnnotationRecord(kind: kind, color: model.strokeColor, lineWidth: model.lineWidth))
            }
            strokePoints = []
            needsDisplay = true
            return
        }

        if model.selectedTool == .mosaic, model.mosaicMode == .brush {
            if strokePoints.count >= 1 {
                model.add(AnnotationRecord(
                    kind: .mosaicStroke(strokePoints, brushRadius: model.mosaicBrushSize.radius),
                    color: model.strokeColor,
                    lineWidth: model.lineWidth
                ))
            }
            strokePoints = []
            needsDisplay = true
            return
        }

        if model.selectedTool == .arrow {
            defer {
                dragStart = nil
                currentRect = .zero
                currentEnd = nil
                arrowPathPoints = []
                needsDisplay = true
            }
            guard let first = arrowPathPoints.first else { return }
            let last = arrowPathPoints.last ?? imagePoint(from: point, imageRect: imageRect)
            let end = shiftHeldDuringStroke ? shiftConstrainedPoint(from: first, to: last) : last
            guard distance(from: first, to: end) > 4 else { return }
            let control = arrowControlPoint(from: arrowPathPoints + [end], shiftHeld: shiftHeldDuringStroke)
            model.add(AnnotationRecord(
                kind: .arrow(start: first, end: end, control: control, dashed: model.arrowDashed),
                color: model.strokeColor,
                lineWidth: model.lineWidth
            ))
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
            annotation = nil
        case .mosaic:
            let rect = normalizedImageRect(from: imageStart, to: imageEnd)
            annotation = rect.width > 4 && rect.height > 4
                ? AnnotationRecord(kind: .mosaic(rect), color: model.strokeColor, lineWidth: model.lineWidth)
                : nil
        case .text, .pencil, .highlighter, .eraser:
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
        var imageEnd = imagePoint(from: end, imageRect: imageRect)

        switch model.selectedTool {
        case .selection:
            return AnnotationRecord(kind: .rectangle(.zero), color: model.strokeColor, lineWidth: model.lineWidth)
        case .rectangle:
            return AnnotationRecord(kind: .rectangle(normalizedImageRect(from: imageStart, to: imageEnd)), color: model.strokeColor, lineWidth: model.lineWidth)
        case .ellipse:
            return AnnotationRecord(kind: .ellipse(normalizedImageRect(from: imageStart, to: imageEnd)), color: model.strokeColor, lineWidth: model.lineWidth)
        case .arrow:
            if shiftHeldDuringStroke {
                imageEnd = shiftConstrainedPoint(from: imageStart, to: imageEnd)
            }
            let path = arrowPathPoints.isEmpty ? [imageStart, imageEnd] : arrowPathPoints
            let control = arrowControlPoint(from: path, shiftHeld: shiftHeldDuringStroke)
            return AnnotationRecord(
                kind: .arrow(start: imageStart, end: imageEnd, control: control, dashed: model.arrowDashed),
                color: model.strokeColor,
                lineWidth: model.lineWidth
            )
        case .mosaic:
            return AnnotationRecord(kind: .mosaic(normalizedImageRect(from: imageStart, to: imageEnd)), color: model.strokeColor, lineWidth: model.lineWidth)
        case .text:
            return AnnotationRecord(kind: .text(imageStart, "", model.currentTextStyle), color: model.strokeColor, lineWidth: model.lineWidth)
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

        let style = model.currentTextStyle
        let fieldHeight = max(28, style.clampedFontSize + 10)
        let field = NSTextField(frame: NSRect(x: viewPoint.x, y: viewPoint.y, width: 220, height: fieldHeight))
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = style.makeFont()
        field.textColor = model.strokeColor
        field.backgroundColor = style.backgroundColor ?? NSColor.windowBackgroundColor.withAlphaComponent(0.9)
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
            let style = model.currentTextStyle
            model.add(AnnotationRecord(kind: .text(point, text, style), color: model.strokeColor, lineWidth: model.lineWidth))
            model.persistTextStyle()
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
        return ScreenshotImageProcessor.wrapWithBitmapRep(output, logicalSize: baseImage.size)
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
        case .arrow(let start, let end, let control, let dashed):
            let flippedStart = flippedPoint(scaledPoint(start, scaleX: scaleX, scaleY: scaleY), imageHeight: imageHeight)
            let flippedEnd = flippedPoint(scaledPoint(end, scaleX: scaleX, scaleY: scaleY), imageHeight: imageHeight)
            let flippedControl = control.map {
                flippedPoint(scaledPoint($0, scaleX: scaleX, scaleY: scaleY), imageHeight: imageHeight)
            }
            drawArrow(
                from: flippedStart,
                to: flippedEnd,
                control: flippedControl,
                lineWidth: annotation.lineWidth * max(scaleX, scaleY),
                color: annotation.color,
                dashed: dashed
            )
        case .text(let point, let text, let style):
            let lineScale = max(scaleX, scaleY)
            let attrs = style.attributes(color: annotation.color, scale: lineScale)
            (text as NSString).draw(
                at: flippedPoint(scaledPoint(point, scaleX: scaleX, scaleY: scaleY), imageHeight: imageHeight),
                withAttributes: attrs
            )
        case .mosaic(let rect):
            drawFlattenedMosaic(
                in: scaledRect(rect, scaleX: scaleX, scaleY: scaleY),
                imageHeight: imageHeight
            )
        case .mosaicStroke(let points, let brushRadius):
            let scaledPoints = points.map { scaledPoint($0, scaleX: scaleX, scaleY: scaleY) }
            let radius = brushRadius * max(scaleX, scaleY)
            let sampled = densifyPoints(scaledPoints, spacing: max(2, radius * 0.45))
            for point in sampled {
                let flipped = flippedPoint(point, imageHeight: imageHeight)
                let rect = NSRect(
                    x: flipped.x - radius,
                    y: flipped.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                drawFlattenedCircularMosaic(in: rect, imageHeight: imageHeight)
            }
        case .pencil(let points):
            drawFlattenedFreehand(
                points,
                imageHeight: imageHeight,
                scaleX: scaleX,
                scaleY: scaleY,
                color: annotation.color,
                lineWidth: annotation.lineWidth * max(scaleX, scaleY),
                multiply: false
            )
        case .highlighter(let points):
            drawFlattenedFreehand(
                points,
                imageHeight: imageHeight,
                scaleX: scaleX,
                scaleY: scaleY,
                color: annotation.color,
                lineWidth: annotation.lineWidth * max(scaleX, scaleY),
                multiply: true
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
        multiply: Bool
    ) {
        guard points.count >= 2 else { return }
        let path = NSBezierPath()
        path.move(to: flippedPoint(scaledPoint(points[0], scaleX: scaleX, scaleY: scaleY), imageHeight: imageHeight))
        for point in points.dropFirst() {
            path.line(to: flippedPoint(scaledPoint(point, scaleX: scaleX, scaleY: scaleY), imageHeight: imageHeight))
        }
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        let cgContext = NSGraphicsContext.current?.cgContext
        if multiply {
            cgContext?.saveGState()
            cgContext?.setBlendMode(.multiply)
            color.withAlphaComponent(0.85).setStroke()
            path.stroke()
            cgContext?.restoreGState()
        } else {
            color.setStroke()
            path.stroke()
        }
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

    private func drawFlattenedCircularMosaic(in rect: NSRect, imageHeight: CGFloat) {
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(ovalIn: rect).setClip()
        // `rect` is already in flipped pixel space; reuse mosaic crop using identity flip.
        guard let cgImage = ScreenshotImageProcessor.bestCGImage(from: baseImage) else {
            NSGraphicsContext.current?.restoreGraphicsState()
            return
        }
        let sourceRect = CGRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height).integral
        guard sourceRect.width > 1, sourceRect.height > 1,
              let cropped = cgImage.cropping(to: sourceRect) else {
            NSGraphicsContext.current?.restoreGraphicsState()
            return
        }
        let ciImage = CIImage(cgImage: cropped)
        let scale = Float(max(8, min(sourceRect.width, sourceRect.height) / 12))
        if let output = applyPixellate(to: ciImage, scale: scale),
           let result = ScreenshotImageProcessor.sharedCIContext.createCGImage(output, from: output.extent) {
            let mosaicImage = NSImage(cgImage: result, size: rect.size)
            mosaicImage.draw(in: rect)
        }
        NSGraphicsContext.current?.restoreGraphicsState()
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
