import CoreGraphics
import Foundation

@main
struct NativeScreenshotImageEditorRegression {
    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue

    static func main() throws {
        try testCropAndFlips()
        try testAppendAlignment()
        try testResizeAndRotation()
        try testBeautifyWrap()
        try testInvalidInputs()
        print("NativeScreenshotImageEditorRegression passed")
    }

    private static func testCropAndFlips() throws {
        let base = try quadrantImage(width: 12, height: 8)
        expectColor(sample(base, x: 1, y: 1), red: 1, green: 0, blue: 0)
        expectColor(sample(base, x: 10, y: 1), red: 0, green: 0, blue: 1)
        expectColor(sample(base, x: 1, y: 6), red: 0, green: 1, blue: 0)
        expectColor(sample(base, x: 10, y: 6), red: 1, green: 1, blue: 0)

        let cropped = try NativeScreenshotImageEditor.crop(
            base, to: CGRect(x: 0, y: 0, width: 6, height: 4))
        assert(cropped.width == 6 && cropped.height == 4)
        expectColor(sample(cropped, x: 3, y: 2), red: 1, green: 0, blue: 0)
        let clipped = try NativeScreenshotImageEditor.crop(
            base, to: CGRect(x: -2, y: -2, width: 8, height: 6))
        assert(clipped.width == 6 && clipped.height == 4)

        let horizontal = try NativeScreenshotImageEditor.flip(base, horizontal: true, vertical: false)
        expectColor(sample(horizontal, x: 1, y: 1), red: 0, green: 0, blue: 1)
        expectColor(sample(horizontal, x: 10, y: 1), red: 1, green: 0, blue: 0)
        let vertical = try NativeScreenshotImageEditor.flip(base, horizontal: false, vertical: true)
        expectColor(sample(vertical, x: 1, y: 1), red: 0, green: 1, blue: 0)
        let both = try NativeScreenshotImageEditor.flip(base, horizontal: true, vertical: true)
        expectColor(sample(both, x: 1, y: 1), red: 1, green: 1, blue: 0)
    }

    private static func testResizeAndRotation() throws {
        let base = try quadrantImage(width: 12, height: 8)
        let resized = try NativeScreenshotImageEditor.resize(
            base, to: CGSize(width: 24, height: 16), interpolation: .none)
        assert(resized.width == 24 && resized.height == 16)
        expectColor(sample(resized, x: 2, y: 2), red: 1, green: 0, blue: 0)
        expectColor(sample(resized, x: 22, y: 14), red: 1, green: 1, blue: 0)
        let scaled = try NativeScreenshotImageEditor.scale(base, by: 0.5, interpolation: .none)
        assert(scaled.width == 6 && scaled.height == 4)

        let clockwise = try NativeScreenshotImageEditor.rotate(base, clockwiseDegrees: 90)
        assert(clockwise.width == 8 && clockwise.height == 12)
        expectColor(sample(clockwise, x: 1, y: 1), red: 0, green: 1, blue: 0)
        expectColor(sample(clockwise, x: 6, y: 1), red: 1, green: 0, blue: 0)
        let halfTurn = try NativeScreenshotImageEditor.rotate(base, clockwiseDegrees: 180)
        expectColor(sample(halfTurn, x: 1, y: 1), red: 1, green: 1, blue: 0)
        let diagonal = try NativeScreenshotImageEditor.rotate(
            base, clockwiseDegrees: 45,
            background: NativeScreenshotEditorColor(red: 0.2, green: 0.3, blue: 0.4))
        assert(diagonal.width == 15 && diagonal.height == 15)
        let corner = sample(diagonal, x: 0, y: 0)
        assert(abs(corner[0] - 0.2) < 0.03 && abs(corner[1] - 0.3) < 0.03)
    }

    private static func testAppendAlignment() throws {
        let first = try quadrantImage(width: 12, height: 8)
        let second = try quadrantImage(width: 6, height: 4)
        let below = try NativeScreenshotImageEditor.append(first, image: second, direction: .below)
        assert(below.width == 12 && below.height == 12)
        expectColor(sample(below, x: 1, y: 1), red: 1, green: 0, blue: 0)
        expectColor(sample(below, x: 1, y: 9), red: 1, green: 0, blue: 0)
        let right = try NativeScreenshotImageEditor.append(first, image: second, direction: .right)
        assert(right.width == 18 && right.height == 8)
        expectColor(sample(right, x: 1, y: 1), red: 1, green: 0, blue: 0)
        expectColor(sample(right, x: 13, y: 1), red: 1, green: 0, blue: 0)
    }

    private static func testBeautifyWrap() throws {
        let base = try quadrantImage(width: 12, height: 8)
        let options = NativeScreenshotBeautifyOptions(
            mode: .rounded,
            gradientTop: .init(red: 1, green: 1, blue: 1),
            gradientBottom: .init(red: 0, green: 0, blue: 0),
            margin: 4, cornerRadius: 3, shadowRadius: 0)
        let rounded = try NativeScreenshotImageEditor.wrap(base, options: options)
        assert(rounded.width == 20 && rounded.height == 16)
        expectColor(sample(rounded, x: 6, y: 6), red: 1, green: 0, blue: 0)
        let clippedCorner = sample(rounded, x: 4, y: 4)
        assert(clippedCorner[1] > 0.5, "rounded card corner should reveal the gradient")
        let top = sample(rounded, x: 0, y: 0)
        let bottom = sample(rounded, x: 0, y: 15)
        assert(top[0] > bottom[0] + 0.5, "gradient should darken toward bottom")

        let wide = try quadrantImage(width: 100, height: 60)
        let window = try NativeScreenshotImageEditor.wrap(
            wide,
            options: .init(mode: .window, margin: 10,
                           cornerRadius: 10, shadowRadius: 0,
                           windowHeaderHeight: 34))
        assert(window.width == 120 && window.height == 114)
        let closeDot = sample(window, x: 25, y: 27)
        assert(closeDot[0] > 0.9 && closeDot[1] < 0.6,
               "window mode should show the first traffic-light dot")
        expectColor(sample(window, x: 20, y: 50), red: 1, green: 0, blue: 0)

        let shadowed = try NativeScreenshotImageEditor.wrap(
            base, options: .init(mode: .rounded,
                                 gradientTop: .white, gradientBottom: .white, margin: 4,
                                 cornerRadius: 3, shadowRadius: 5))
        assert(shadowed.width == 40 && shadowed.height == 36,
               "shadow padding must keep the full shadow inside the bitmap")
        assert(sample(shadowed, x: 12, y: 18)[0] < sample(shadowed, x: 0, y: 18)[0],
               "shadow should visibly darken the gradient near the card")
    }

    private static func testInvalidInputs() throws {
        let base = try quadrantImage(width: 12, height: 8)
        assertThrows { _ = try NativeScreenshotImageEditor.crop(
            base, to: CGRect(x: 30, y: 30, width: 2, height: 2)) }
        assertThrows { _ = try NativeScreenshotImageEditor.resize(
            base, to: CGSize(width: 0, height: 8)) }
        assertThrows { _ = try NativeScreenshotImageEditor.scale(base, by: -.infinity) }
        assertThrows { _ = try NativeScreenshotImageEditor.rotate(base, clockwiseDegrees: .nan) }
        assertThrows { _ = try NativeScreenshotImageEditor.wrap(
            base, options: .init(margin: -1)) }
    }

    private static func quadrantImage(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: bitmapInfo) else {
            throw NativeScreenshotEditorError.bitmapContextUnavailable
        }
        let colors: [NativeScreenshotEditorColor] = [
            .init(red: 0, green: 1, blue: 0), // lower left
            .init(red: 1, green: 1, blue: 0), // lower right
            .init(red: 1, green: 0, blue: 0), // upper left
            .init(red: 0, green: 0, blue: 1)  // upper right
        ]
        let boxes = [
            CGRect(x: 0, y: 0, width: width / 2, height: height / 2),
            CGRect(x: width / 2, y: 0, width: width / 2, height: height / 2),
            CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2),
            CGRect(x: width / 2, y: height / 2, width: width / 2, height: height / 2)
        ]
        for (color, box) in zip(colors, boxes) {
            context.setFillColor(CGColor(colorSpace: space, components: [
                color.red, color.green, color.blue, 1])!)
            context.fill(box)
        }
        guard let output = context.makeImage() else {
            throw NativeScreenshotEditorError.imageCreationFailed
        }
        return output
    }

    /// One-pixel crop checks the same top-origin convention a caller uses.
    private static func sample(_ image: CGImage, x: Int, y: Int) -> [CGFloat] {
        let crop = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))!
        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                                    bitsPerComponent: 8, bytesPerRow: 4,
                                    space: space, bitmapInfo: bitmapInfo)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return rgba.map { CGFloat($0) / 255 }
    }

    private static func expectColor(_ pixel: [CGFloat], red: CGFloat,
                                    green: CGFloat, blue: CGFloat) {
        assert(abs(pixel[0] - red) < 0.03 && abs(pixel[1] - green) < 0.03
               && abs(pixel[2] - blue) < 0.03,
               "unexpected RGB pixel: \(pixel)")
    }

    private static func assertThrows(_ operation: () throws -> Void) {
        do {
            try operation()
            assertionFailure("expected an error")
        } catch {
            // Expected.
        }
    }
}
