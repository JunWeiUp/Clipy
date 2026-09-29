import CoreGraphics
import Foundation

enum NativeScreenshotEditorError: Error {
    case invalidSize
    case invalidCrop
    case invalidOptions
    case bitmapContextUnavailable
    case imageCreationFailed
    case gradientUnavailable
}

struct NativeScreenshotEditorColor {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    static let white = NativeScreenshotEditorColor(red: 1, green: 1, blue: 1)

    fileprivate var cgColor: CGColor {
        CGColor(colorSpace: NativeScreenshotImageEditor.sRGB,
                components: [clamp(red), clamp(green), clamp(blue), clamp(alpha)])!
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        Swift.min(1, Swift.max(0, value.isFinite ? value : 0))
    }
}

enum NativeScreenshotBeautifyMode {
    case window
    case rounded
}

struct NativeScreenshotBeautifyOptions {
    var mode: NativeScreenshotBeautifyMode = .rounded
    var gradientTop = NativeScreenshotEditorColor(red: 0.89, green: 0.92, blue: 1)
    var gradientBottom = NativeScreenshotEditorColor(red: 0.68, green: 0.75, blue: 0.96)
    /// Distance from the content card to the outer gradient border, in pixels.
    var margin: CGFloat = 32
    var cornerRadius: CGFloat = 16
    var shadowRadius: CGFloat = 18
    var windowHeaderHeight: CGFloat = 34

    init(
        mode: NativeScreenshotBeautifyMode = .rounded,
        gradientTop: NativeScreenshotEditorColor = .init(red: 0.89, green: 0.92, blue: 1),
        gradientBottom: NativeScreenshotEditorColor = .init(red: 0.68, green: 0.75, blue: 0.96),
        margin: CGFloat = 32,
        cornerRadius: CGFloat = 16,
        shadowRadius: CGFloat = 18,
        windowHeaderHeight: CGFloat = 34
    ) {
        self.mode = mode
        self.gradientTop = gradientTop
        self.gradientBottom = gradientBottom
        self.margin = margin
        self.cornerRadius = cornerRadius
        self.shadowRadius = shadowRadius
        self.windowHeaderHeight = windowHeaderHeight
    }
}

/// Pure image operations. Rectangles and output sizes are native image pixels.
/// Crop rectangles use an upper-left origin; all returned images are upright.
enum NativeScreenshotImageEditor {
    fileprivate static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    private static let maximumDimension = 40_000
    private static let maximumPixels = 160_000_000

    static func crop(_ image: CGImage, to topLeftRect: CGRect) throws -> CGImage {
        guard topLeftRect.origin.x.isFinite, topLeftRect.origin.y.isFinite,
              topLeftRect.size.width.isFinite, topLeftRect.size.height.isFinite else {
            throw NativeScreenshotEditorError.invalidCrop
        }
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let selected = topLeftRect.standardized.intersection(imageBounds)
        guard !selected.isNull, !selected.isEmpty else {
            throw NativeScreenshotEditorError.invalidCrop
        }
        let pixels = selected.integral.intersection(imageBounds)
        guard let result = image.cropping(to: pixels) else {
            throw NativeScreenshotEditorError.imageCreationFailed
        }
        return result
    }

    static func flip(_ image: CGImage, horizontal: Bool, vertical: Bool) throws -> CGImage {
        if !horizontal && !vertical { return image }
        let context = try makeContext(width: image.width, height: image.height, source: image)
        context.translateBy(x: horizontal ? CGFloat(image.width) : 0,
                            y: vertical ? CGFloat(image.height) : 0)
        context.scaleBy(x: horizontal ? -1 : 1, y: vertical ? -1 : 1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try makeImage(context)
    }

    static func resize(
        _ image: CGImage,
        to pixelSize: CGSize,
        interpolation: CGInterpolationQuality = .high
    ) throws -> CGImage {
        let width = try pixelDimension(pixelSize.width)
        let height = try pixelDimension(pixelSize.height)
        let context = try makeContext(width: width, height: height, source: image)
        context.interpolationQuality = interpolation
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return try makeImage(context)
    }

    static func scale(
        _ image: CGImage,
        by factor: CGFloat,
        interpolation: CGInterpolationQuality = .high
    ) throws -> CGImage {
        guard factor.isFinite, factor > 0 else { throw NativeScreenshotEditorError.invalidSize }
        return try resize(image,
                          to: CGSize(width: CGFloat(image.width) * factor,
                                     height: CGFloat(image.height) * factor),
                          interpolation: interpolation)
    }

    /// Positive degrees rotate clockwise as viewed in the exported image.
    static func rotate(
        _ image: CGImage,
        clockwiseDegrees degrees: CGFloat,
        expandCanvas: Bool = true,
        background: NativeScreenshotEditorColor? = nil
    ) throws -> CGImage {
        guard degrees.isFinite else { throw NativeScreenshotEditorError.invalidOptions }
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        if abs(normalized) < 0.000_001 { return image }
        let radians = -normalized * .pi / 180
        let cosine = abs(cos(radians))
        let sine = abs(sin(radians))
        let width = try pixelDimension(expandCanvas
            ? enclosingPixelExtent(CGFloat(image.width) * cosine + CGFloat(image.height) * sine)
            : CGFloat(image.width))
        let height = try pixelDimension(expandCanvas
            ? enclosingPixelExtent(CGFloat(image.width) * sine + CGFloat(image.height) * cosine)
            : CGFloat(image.height))
        let context = try makeContext(width: width, height: height, source: image)
        let output = CGRect(x: 0, y: 0, width: width, height: height)
        if let background {
            context.setFillColor(background.cgColor)
            context.fill(output)
        } else {
            context.clear(output)
        }
        context.interpolationQuality = .high
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: radians)
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2,
                                       y: -CGFloat(image.height) / 2,
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        return try makeImage(context)
    }

    /// Draws a gradient around the image. Window mode adds a title strip and
    /// traffic-light decoration; rounded mode shows only the clipped image card.
    static func wrap(
        _ image: CGImage,
        options: NativeScreenshotBeautifyOptions
    ) throws -> CGImage {
        guard options.margin.isFinite, options.cornerRadius.isFinite,
              options.shadowRadius.isFinite, options.windowHeaderHeight.isFinite,
              options.margin >= 0, options.cornerRadius >= 0,
              options.shadowRadius >= 0, options.windowHeaderHeight >= 0 else {
            throw NativeScreenshotEditorError.invalidOptions
        }
        let margin = ceil(options.margin)
        // Keep the entire blur inside the resulting bitmap even at zero margin.
        let shadowInset = ceil(options.shadowRadius * 2)
        let inset = margin + shadowInset
        let header = options.mode == .window ? max(22, ceil(options.windowHeaderHeight)) : 0
        let width = try pixelDimension(CGFloat(image.width) + inset * 2)
        let height = try pixelDimension(CGFloat(image.height) + header + inset * 2)
        let context = try makeContext(width: width, height: height, source: image)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        guard let gradient = CGGradient(
            colorsSpace: sRGB,
            colors: [options.gradientTop.cgColor, options.gradientBottom.cgColor] as CFArray,
            locations: [0, 1]
        ) else { throw NativeScreenshotEditorError.gradientUnavailable }
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: bounds.midX, y: bounds.maxY),
            end: CGPoint(x: bounds.midX, y: bounds.minY),
            options: []
        )

        let card = CGRect(x: inset, y: inset,
                          width: CGFloat(image.width), height: CGFloat(image.height) + header)
        let radius = min(options.cornerRadius, card.width / 2, card.height / 2)
        let cardPath = CGPath(roundedRect: card, cornerWidth: radius,
                              cornerHeight: radius, transform: nil)
        context.saveGState()
        if options.shadowRadius > 0 {
            context.setShadow(
                offset: CGSize(width: 0, height: -max(1, options.shadowRadius / 3)),
                blur: options.shadowRadius,
                color: CGColor(colorSpace: sRGB, components: [0, 0, 0, 0.30])
            )
        }
        context.addPath(cardPath)
        context.setFillColor(NativeScreenshotEditorColor.white.cgColor)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(cardPath)
        context.clip()
        context.draw(image, in: CGRect(x: inset, y: inset,
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        if options.mode == .window {
            drawWindowHeader(in: context, card: card, height: header)
        }
        context.restoreGState()
        return try makeImage(context)
    }

    private static func drawWindowHeader(in context: CGContext, card: CGRect, height: CGFloat) {
        let header = CGRect(x: card.minX, y: card.maxY - height,
                            width: card.width, height: height)
        context.setFillColor(CGColor(colorSpace: sRGB,
                                     components: [0.95, 0.96, 0.98, 1])!)
        context.fill(header)
        context.setStrokeColor(CGColor(colorSpace: sRGB,
                                       components: [0.73, 0.75, 0.79, 1])!)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: header.minX, y: header.minY + 0.5))
        context.addLine(to: CGPoint(x: header.maxX, y: header.minY + 0.5))
        context.strokePath()
        guard card.width >= 72 else { return }
        let centers = [card.minX + 15, card.minX + 34, card.minX + 53]
        let colors = [
            NativeScreenshotEditorColor(red: 1, green: 0.37, blue: 0.34),
            NativeScreenshotEditorColor(red: 1, green: 0.74, blue: 0.29),
            NativeScreenshotEditorColor(red: 0.36, green: 0.78, blue: 0.38)
        ]
        for (x, color) in zip(centers, colors) {
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: CGRect(x: x - 5, y: header.midY - 5,
                                           width: 10, height: 10))
        }
    }

    private static func makeContext(width: Int, height: Int,
                                    source: CGImage?) throws -> CGContext {
        guard width > 0, height > 0,
              width <= maximumDimension, height <= maximumDimension,
              width <= maximumPixels / height else {
            throw NativeScreenshotEditorError.invalidSize
        }
        let colorSpace = source?.colorSpace?.model == .rgb ? source!.colorSpace! : sRGB
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { throw NativeScreenshotEditorError.bitmapContextUnavailable }
        return context
    }

    private static func makeImage(_ context: CGContext) throws -> CGImage {
        guard let image = context.makeImage() else {
            throw NativeScreenshotEditorError.imageCreationFailed
        }
        return image
    }

    private static func pixelDimension(_ value: CGFloat) throws -> Int {
        guard value.isFinite, value > 0,
              value <= CGFloat(maximumDimension) else {
            throw NativeScreenshotEditorError.invalidSize
        }
        return max(1, Int(value.rounded()))
    }

    private static func enclosingPixelExtent(_ value: CGFloat) -> CGFloat {
        let rounded = value.rounded()
        return abs(value - rounded) < 0.000_001 ? rounded : ceil(value)
    }
}
