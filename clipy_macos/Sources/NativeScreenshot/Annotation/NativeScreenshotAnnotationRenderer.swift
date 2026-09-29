import AppKit
import CoreGraphics
import CoreText
import Foundation

enum NativeScreenshotAnnotationRenderError: Error {
    case invalidCanvasSize
    case imageSizeMismatch
    case bitmapContextUnavailable
    case imageCreationFailed
    case imageFilterFailed
    case requiresBaseImage
}

/// Offscreen Core Graphics renderer. Image and annotation coordinates are pixels,
/// with (0, 0) at the upper-left. No window, display, or global state is needed.
enum NativeScreenshotAnnotationRenderer {
    static func render(
        baseImage: CGImage,
        document: NativeScreenshotAnnotationDocument
    ) throws -> CGImage {
        guard document.canvasSize.width.isFinite,
              document.canvasSize.height.isFinite,
              document.canvasSize.width > 0,
              document.canvasSize.height > 0,
              document.canvasSize.width <= 40_000,
              document.canvasSize.height <= 40_000 else {
            throw NativeScreenshotAnnotationRenderError.invalidCanvasSize
        }
        guard Int(document.canvasSize.width) == baseImage.width,
              Int(document.canvasSize.height) == baseImage.height else {
            throw NativeScreenshotAnnotationRenderError.imageSizeMismatch
        }
        return try render(document: document, baseImage: baseImage)
    }

    /// Exports vector annotations on transparent pixels. Tools that transform
    /// existing pixels require `render(baseImage:document:)` instead.
    static func renderOverlay(document: NativeScreenshotAnnotationDocument) throws -> CGImage {
        for annotation in document.annotations {
            switch annotation.content {
            case .pixelate, .blur, .eraseCensor, .magnifier:
                throw NativeScreenshotAnnotationRenderError.requiresBaseImage
            default:
                break
            }
        }
        return try render(document: document, baseImage: nil)
    }

    /// Samples an existing image without adding an annotation to the document.
    static func sampleColor(at point: CGPoint, in image: CGImage) -> NativeScreenshotColor? {
        guard point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.y >= 0,
              point.x < CGFloat(image.width), point.y < CGFloat(image.height),
              let pixel = image.cropping(to: CGRect(x: floor(point.x), y: floor(point.y), width: 1, height: 1)) else {
            return nil
        }
        var rgba = [UInt8](repeating: 0, count: 4)
        let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: workingColorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard rendered else { return nil }
        let alpha = CGFloat(rgba[3]) / 255
        guard alpha > 0 else { return NativeScreenshotColor(red: 0, green: 0, blue: 0, alpha: 0) }
        return NativeScreenshotColor(
            red: min(1, CGFloat(rgba[0]) / 255 / alpha),
            green: min(1, CGFloat(rgba[1]) / 255 / alpha),
            blue: min(1, CGFloat(rgba[2]) / 255 / alpha),
            alpha: alpha
        )
    }

    private static let workingColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func render(
        document: NativeScreenshotAnnotationDocument,
        baseImage: CGImage?
    ) throws -> CGImage {
        let width = document.canvasSize.width
        let height = document.canvasSize.height
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width.rounded() == width, height.rounded() == height,
              width <= 40_000, height <= 40_000 else {
            throw NativeScreenshotAnnotationRenderError.invalidCanvasSize
        }
        guard let context = CGContext(
            data: nil, width: Int(width), height: Int(height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: workingColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw NativeScreenshotAnnotationRenderError.bitmapContextUnavailable
        }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        context.clear(canvas)
        if let baseImage {
            context.draw(baseImage, in: canvas)
        }
        for annotation in document.annotations where annotation.isVisible {
            context.saveGState()
            context.setAlpha(clamp01(annotation.style.opacity))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setLineWidth(max(0.5, finite(annotation.style.lineWidth, fallback: 1)))
            context.setStrokeColor(annotation.style.strokeColor.cgColor)
            context.setFillColor(annotation.style.fillColor.cgColor)
            try draw(annotation, in: context, canvas: canvas)
            context.restoreGState()
        }
        guard let output = context.makeImage() else {
            throw NativeScreenshotAnnotationRenderError.imageCreationFailed
        }
        return output
    }

    private static func draw(
        _ annotation: NativeScreenshotAnnotation,
        in context: CGContext,
        canvas: CGRect
    ) throws {
        let height = canvas.height
        let style = annotation.style
        switch annotation.content {
        case let .pencil(samples, smoothing):
            drawPencil(samples, smoothing: smoothing, style: style, in: context, height: height)

        case let .line(start, end):
            strokeLine(from: start, to: end, in: context, height: height)

        case let .arrow(start, end, arrowStyle):
            drawArrow(from: start, to: end, arrowStyle: arrowStyle, style: style,
                      in: context, height: height)

        case let .rectangle(rect):
            if let box = cgRect(rect, height: height) { context.stroke(box) }

        case let .filledRectangle(rect):
            if let box = cgRect(rect, height: height) { context.fill(box) }

        case let .ellipse(rect):
            if let box = cgRect(rect, height: height) { context.strokeEllipse(in: box) }

        case let .highlighter(points):
            context.setBlendMode(.multiply)
            context.setAlpha(min(0.7, clamp01(style.opacity)))
            context.setLineWidth(max(10, finite(style.lineWidth, fallback: 14)))
            strokePolyline(points, in: context, height: height)

        case let .richText(rect, runs):
            drawRichText(runs, in: rect, context: context, height: height)

        case let .number(center, value):
            drawNumber(value, at: center, style: style, in: context, height: height)

        case let .stamp(rect, content):
            drawStamp(content, in: rect, context: context, height: height)

        case let .pixelate(rect, blockSize):
            context.setAlpha(1)
            try pixelate(rect, blockSize: blockSize, in: context, canvas: canvas)

        case let .blur(rect, radius):
            context.setAlpha(1)
            try blur(rect, radius: radius, in: context, canvas: canvas)

        case let .solidCensor(rect):
            context.setAlpha(1)
            context.setFillColor(NativeScreenshotColor(
                red: style.fillColor.red, green: style.fillColor.green,
                blue: style.fillColor.blue, alpha: 1).cgColor)
            if let box = cgRect(rect, height: height) { context.fill(box) }

        case let .eraseCensor(rect):
            context.setAlpha(1)
            if let box = cgRect(rect, height: height) { context.clear(box) }

        case let .magnifier(source, destination):
            try drawMagnifier(source: source, destination: destination,
                              style: style, in: context, canvas: canvas)

        case let .ruler(start, end):
            drawRuler(from: start, to: end, style: style, in: context, height: height)

        case .colorSampler:
            break // This is an editing operation, never painted into an export.

        case let .spotlight(rect):
            drawSpotlight(rect, style: style, in: context, canvas: canvas)
        }
    }

    private static func drawPencil(
        _ samples: [NativeScreenshotStrokeSample],
        smoothing: NativeScreenshotPencilSmoothing,
        style: NativeScreenshotAnnotationStyle,
        in context: CGContext,
        height: CGFloat
    ) {
        let valid = samples.filter { isFinite($0.point) }
        guard let first = valid.first else { return }
        if valid.count == 1 {
            let width = max(0.5, style.lineWidth * max(0.1, clamp01(first.pressure)))
            let center = cgPoint(first.point, height: height)
            context.fillEllipse(in: CGRect(x: center.x - width / 2, y: center.y - width / 2,
                                           width: width, height: width))
            return
        }
        if smoothing == .none {
            for (a, b) in zip(valid, valid.dropFirst()) {
                context.setLineWidth(max(0.5, style.lineWidth * max(0.1, clamp01((a.pressure + b.pressure) / 2))))
                strokeLine(from: a.point, to: b.point, in: context, height: height)
            }
            return
        }
        let iterations = smoothing == .refined ? 2 : 1
        var points = valid
        for _ in 0..<iterations {
            var smoothed = [NativeScreenshotStrokeSample]()
            smoothed.reserveCapacity(points.count * 2)
            smoothed.append(points[0])
            for (a, b) in zip(points, points.dropFirst()) {
                smoothed.append(.init(
                    CGPoint(x: a.point.x * 0.75 + b.point.x * 0.25,
                            y: a.point.y * 0.75 + b.point.y * 0.25),
                    pressure: a.pressure * 0.75 + b.pressure * 0.25
                ))
                smoothed.append(.init(
                    CGPoint(x: a.point.x * 0.25 + b.point.x * 0.75,
                            y: a.point.y * 0.25 + b.point.y * 0.75),
                    pressure: a.pressure * 0.25 + b.pressure * 0.75
                ))
            }
            smoothed.append(points[points.count - 1])
            points = smoothed
        }
        for (a, b) in zip(points, points.dropFirst()) {
            context.setLineWidth(max(0.5, style.lineWidth * max(0.1, clamp01((a.pressure + b.pressure) / 2))))
            strokeLine(from: a.point, to: b.point, in: context, height: height)
        }
    }

    private static func strokeLine(from start: CGPoint, to end: CGPoint,
                                   in context: CGContext, height: CGFloat) {
        guard isFinite(start), isFinite(end) else { return }
        context.beginPath()
        context.move(to: cgPoint(start, height: height))
        context.addLine(to: cgPoint(end, height: height))
        context.strokePath()
    }

    private static func strokePolyline(_ points: [CGPoint], in context: CGContext, height: CGFloat) {
        let points = points.filter(isFinite)
        guard let first = points.first else { return }
        context.beginPath()
        context.move(to: cgPoint(first, height: height))
        for point in points.dropFirst() { context.addLine(to: cgPoint(point, height: height)) }
        context.strokePath()
    }

    private static func drawArrow(
        from start: CGPoint, to end: CGPoint,
        arrowStyle: NativeScreenshotArrowStyle,
        style: NativeScreenshotAnnotationStyle,
        in context: CGContext, height: CGFloat
    ) {
        guard isFinite(start), isFinite(end) else { return }
        let a = cgPoint(start, height: height)
        let b = cgPoint(end, height: height)
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length >= 2 else { return }
        let head = min(28, max(8, style.lineWidth * 4))
        let isCurved = arrowStyle == .curved || arrowStyle == .curvedDashed
        let control = CGPoint(x: (a.x + b.x) / 2 - dy * 0.22,
                              y: (a.y + b.y) / 2 + dx * 0.22)
        if arrowStyle == .dashed || arrowStyle == .curvedDashed {
            context.setLineDash(phase: 0, lengths: [max(4, style.lineWidth * 3), max(3, style.lineWidth * 2)])
        }
        if arrowStyle == .sketch {
            for offset in [-1.5, 0, 1.5] as [CGFloat] {
                context.beginPath()
                context.move(to: CGPoint(x: a.x + offset, y: a.y - offset))
                context.addLine(to: CGPoint(x: (a.x + b.x) / 2 - offset, y: (a.y + b.y) / 2 + offset))
                context.addLine(to: CGPoint(x: b.x + offset, y: b.y - offset))
                context.strokePath()
            }
        } else {
            context.beginPath()
            context.move(to: a)
            if isCurved { context.addQuadCurve(to: b, control: control) }
            else { context.addLine(to: b) }
            context.strokePath()
        }
        context.setLineDash(phase: 0, lengths: [])
        drawArrowHead(at: b, direction: isCurved ? CGPoint(x: b.x - control.x, y: b.y - control.y)
                                              : CGPoint(x: dx, y: dy), size: head, in: context)
        if arrowStyle == .doubleHeaded {
            drawArrowHead(at: a, direction: CGPoint(x: -dx, y: -dy), size: head, in: context)
        }
    }

    private static func drawArrowHead(at tip: CGPoint, direction: CGPoint,
                                      size: CGFloat, in context: CGContext) {
        let length = max(0.001, hypot(direction.x, direction.y))
        let ux = direction.x / length
        let uy = direction.y / length
        let base = CGPoint(x: tip.x - ux * size, y: tip.y - uy * size)
        let wing = size * 0.42
        context.beginPath()
        context.move(to: tip)
        context.addLine(to: CGPoint(x: base.x - uy * wing, y: base.y + ux * wing))
        context.addLine(to: CGPoint(x: base.x + uy * wing, y: base.y - ux * wing))
        context.closePath()
        context.drawPath(using: .fillStroke)
    }

    private static func drawRichText(_ runs: [NativeScreenshotTextRun], in rect: CGRect,
                                     context: CGContext, height: CGFloat) {
        guard let box = cgRect(rect, height: height), !runs.isEmpty else { return }
        let text = NativeScreenshotRichText.attributedString(from: runs)
        guard text.length > 0 else { return }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: box, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, nil)
        context.saveGState()
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    private static func drawNumber(_ value: Int, at point: CGPoint,
                                   style: NativeScreenshotAnnotationStyle,
                                   in context: CGContext, height: CGFloat) {
        guard isFinite(point) else { return }
        let center = cgPoint(point, height: height)
        let diameter = max(24, style.lineWidth * 9)
        let circle = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                            width: diameter, height: diameter)
        context.fillEllipse(in: circle)
        context.strokeEllipse(in: circle)
        drawCenteredText(String(value), center: center,
                         size: diameter * 0.55, color: style.strokeColor,
                         in: context)
    }

    private static func drawStamp(_ content: NativeScreenshotStamp, in rect: CGRect,
                                  context: CGContext, height: CGFloat) {
        guard let box = cgRect(rect, height: height) else { return }
        switch content {
        case let .emoji(value):
            drawCenteredText(value, center: CGPoint(x: box.midX, y: box.midY),
                             size: min(box.width, box.height) * 0.85,
                             color: .black, in: context)
        case let .image(image):
            context.draw(image, in: box)
        }
    }

    private static func pixelate(_ rect: CGRect, blockSize: CGFloat,
                                 in context: CGContext, canvas: CGRect) throws {
        guard let source = croppedSnapshot(rect, from: context, canvas: canvas) else { return }
        let (crop, topRect) = source
        let block = max(2, min(128, finite(blockSize, fallback: 12)))
        let smallWidth = max(1, Int(ceil(CGFloat(crop.width) / block)))
        let smallHeight = max(1, Int(ceil(CGFloat(crop.height) / block)))
        guard let small = CGContext(
            data: nil, width: smallWidth, height: smallHeight,
            bitsPerComponent: 8, bytesPerRow: 0, space: workingColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { throw NativeScreenshotAnnotationRenderError.bitmapContextUnavailable }
        small.interpolationQuality = .high
        small.draw(crop, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))
        guard let reduced = small.makeImage() else {
            throw NativeScreenshotAnnotationRenderError.imageCreationFailed
        }
        context.saveGState()
        context.interpolationQuality = .none
        context.draw(reduced, in: cgRect(topRect, height: canvas.height)!)
        context.restoreGState()
    }

    private static func blur(_ rect: CGRect, radius: CGFloat,
                             in context: CGContext, canvas: CGRect) throws {
        guard let source = croppedSnapshot(rect, from: context, canvas: canvas) else { return }
        let (crop, topRect) = source
        let pixelCount = crop.width * crop.height
        // Two RGBA buffers are needed. Reject an extreme mask instead of letting
        // a whole-document blur exhaust memory during an export.
        guard pixelCount > 0, pixelCount <= 32_000_000 else {
            throw NativeScreenshotAnnotationRenderError.imageFilterFailed
        }
        var pixels = [UInt8](repeating: 0, count: pixelCount * 4)
        let didRead = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let bitmap = CGContext(
                data: bytes.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                space: workingColorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            bitmap.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            return true
        }
        guard didRead else {
            throw NativeScreenshotAnnotationRenderError.imageFilterFailed
        }
        var scratch = [UInt8](repeating: 0, count: pixels.count)
        let kernelRadius = max(1, min(64, Int(finite(radius, fallback: 8).rounded())))
        let kernelWidth = kernelRadius * 2 + 1
        let width = crop.width
        let height = crop.height
        // Separable box blur. Edge pixels are extended, so the mask has no dark halo.
        for y in 0..<height {
            for channel in 0..<4 {
                var sum = 0
                for offset in -kernelRadius...kernelRadius {
                    let x = max(0, min(width - 1, offset))
                    sum += Int(pixels[(y * width + x) * 4 + channel])
                }
                for x in 0..<width {
                    scratch[(y * width + x) * 4 + channel] = UInt8(sum / kernelWidth)
                    let leaving = max(0, min(width - 1, x - kernelRadius))
                    let entering = max(0, min(width - 1, x + kernelRadius + 1))
                    sum += Int(pixels[(y * width + entering) * 4 + channel])
                        - Int(pixels[(y * width + leaving) * 4 + channel])
                }
            }
        }
        for x in 0..<width {
            for channel in 0..<4 {
                var sum = 0
                for offset in -kernelRadius...kernelRadius {
                    let y = max(0, min(height - 1, offset))
                    sum += Int(scratch[(y * width + x) * 4 + channel])
                }
                for y in 0..<height {
                    pixels[(y * width + x) * 4 + channel] = UInt8(sum / kernelWidth)
                    let leaving = max(0, min(height - 1, y - kernelRadius))
                    let entering = max(0, min(height - 1, y + kernelRadius + 1))
                    sum += Int(scratch[(entering * width + x) * 4 + channel])
                        - Int(scratch[(leaving * width + x) * 4 + channel])
                }
            }
        }
        let blurred = pixels.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let bitmap = CGContext(
                data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: workingColorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return nil }
            return bitmap.makeImage()
        }
        guard let blurred else { throw NativeScreenshotAnnotationRenderError.imageFilterFailed }
        context.draw(blurred, in: cgRect(topRect, height: canvas.height)!)
    }

    private static func drawMagnifier(source: CGRect, destination: CGRect,
                                      style: NativeScreenshotAnnotationStyle,
                                      in context: CGContext, canvas: CGRect) throws {
        guard let source = croppedSnapshot(source, from: context, canvas: canvas),
              let destination = cgRect(destination, height: canvas.height) else { return }
        context.saveGState()
        context.addEllipse(in: destination)
        context.clip()
        context.interpolationQuality = .high
        context.draw(source.0, in: destination)
        context.restoreGState()
        context.strokeEllipse(in: destination)
    }

    private static func drawRuler(from start: CGPoint, to end: CGPoint,
                                  style: NativeScreenshotAnnotationStyle,
                                  in context: CGContext, height: CGFloat) {
        guard isFinite(start), isFinite(end) else { return }
        strokeLine(from: start, to: end, in: context, height: height)
        let a = cgPoint(start, height: height)
        let b = cgPoint(end, height: height)
        let distance = hypot(b.x - a.x, b.y - a.y)
        guard distance >= 1 else { return }
        let nx = -(b.y - a.y) / distance * 6
        let ny = (b.x - a.x) / distance * 6
        for endpoint in [a, b] {
            context.beginPath()
            context.move(to: CGPoint(x: endpoint.x - nx, y: endpoint.y - ny))
            context.addLine(to: CGPoint(x: endpoint.x + nx, y: endpoint.y + ny))
            context.strokePath()
        }
        let label = "\(Int(distance.rounded())) px"
        drawCenteredText(label,
                         center: CGPoint(x: (a.x + b.x) / 2 - nx * 2,
                                         y: (a.y + b.y) / 2 - ny * 2),
                         size: max(11, style.lineWidth * 4),
                         color: style.strokeColor, in: context)
    }

    private static func drawSpotlight(_ rect: CGRect,
                                      style: NativeScreenshotAnnotationStyle,
                                      in context: CGContext, canvas: CGRect) {
        guard let hole = cgRect(rect, height: canvas.height) else { return }
        let path = CGMutablePath()
        path.addRect(canvas)
        path.addRect(hole)
        context.setFillColor(NativeScreenshotColor(red: 0, green: 0, blue: 0,
                                                   alpha: 0.65).cgColor)
        context.addPath(path)
        context.drawPath(using: .eoFill)
        context.setStrokeColor(style.strokeColor.cgColor)
        context.stroke(hole)
    }

    private static func drawCenteredText(_ value: String, center: CGPoint,
                                         size: CGFloat, color: NativeScreenshotColor,
                                         in context: CGContext) {
        guard !value.isEmpty, size.isFinite, size > 0 else { return }
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        let text = NSAttributedString(string: value, attributes: [
            .font: font,
            .foregroundColor: NSColor(cgColor: color.cgColor) ?? .black
        ])
        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: center.x - width / 2,
                                       y: center.y - (ascent - descent) / 2)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// CGImage cropping rectangles use upper-left pixel coordinates.
    private static func croppedSnapshot(_ rect: CGRect, from context: CGContext,
                                        canvas: CGRect) -> (CGImage, CGRect)? {
        guard let topRect = boundedPixelRect(rect, canvas: canvas),
              let snapshot = context.makeImage(),
              let crop = snapshot.cropping(to: topRect) else { return nil }
        return (crop, topRect)
    }

    private static func boundedPixelRect(_ rect: CGRect, canvas: CGRect) -> CGRect? {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite else { return nil }
        let bounded = rect.standardized.intersection(canvas)
        guard !bounded.isNull, !bounded.isEmpty else { return nil }
        let pixels = bounded.integral.intersection(canvas)
        return pixels.isEmpty ? nil : pixels
    }

    private static func cgRect(_ rect: CGRect, height: CGFloat) -> CGRect? {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite else { return nil }
        let rect = rect.standardized
        guard rect.width > 0, rect.height > 0 else { return nil }
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func cgPoint(_ point: CGPoint, height: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: height - point.y)
    }

    private static func isFinite(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    private static func finite(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
        value.isFinite ? value : fallback
    }

    private static func clamp01(_ value: CGFloat) -> CGFloat {
        min(1, max(0, value.isFinite ? value : 0))
    }
}
