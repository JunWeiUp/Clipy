import CoreGraphics
import Foundation

@main
enum NativeScreenshotCaptureRegression {
    static func main() throws {
        try nativeDisplayPixelsAndLimits()
        try mixedScaleWindowPixels()
        try rejectUnexpectedFirstFrameSize()
        localizedCaptureResolutionErrors()
        try geometryAcrossMixedScaleDisplays()
        try composeAcrossDisplays()
        print("NativeScreenshotCaptureRegression passed")
    }

    private static func nativeDisplayPixelsAndLimits() throws {
        let retinaFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let native = NativeScreenshotPixelSize(width: 3024, height: 1964)
        precondition(NativeScreenshotCaptureResolution.displayPixels(
            frame: retinaFrame, modePixels: native, backingScaleFactor: 1) == native,
            "the display mode's physical pixels must win over a nominal fallback")
        precondition(NativeScreenshotCaptureResolution.displayPixels(
            frame: retinaFrame, modePixels: nil, backingScaleFactor: 2) == native,
            "a missing display mode must use the matched screen's 2× backing scale")
        precondition(NativeScreenshotCaptureResolution.displayPixels(
            frame: retinaFrame,
            modePixels: NativeScreenshotPixelSize(width: 0, height: 0),
            backingScaleFactor: 2) == native,
            "an unusable display mode must use the matched screen's backing scale")
        precondition(NativeScreenshotCaptureResolution.displayPixels(
            frame: retinaFrame, modePixels: nil, backingScaleFactor: nil) == nil,
            "unknown resolution must not silently fall back to a blurry 1× frame")
        precondition(NativeScreenshotCaptureResolution.fitsOutputLimit(
            native, maxPixels: 5_939_136))
        precondition(!NativeScreenshotCaptureResolution.fitsOutputLimit(
            native, maxPixels: 5_939_135),
            "native capture must still obey the configured pixel cap")
    }

    private static func mixedScaleWindowPixels() throws {
        let displays = [
            NativeScreenshotDisplayResolution(
                frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                pixels: NativeScreenshotPixelSize(width: 3024, height: 1964)),
            NativeScreenshotDisplayResolution(
                frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
                pixels: NativeScreenshotPixelSize(width: 1920, height: 1080))
        ]
        let crossing = CGRect(x: 1400, y: 100, width: 400, height: 300)
        precondition(NativeScreenshotCaptureResolution.windowPixels(
            frame: crossing, displays: displays, maxPixels: 480_000)
            == NativeScreenshotPixelSize(width: 800, height: 600),
            "a window crossing 1× and 2× displays needs the higher pixel density")
        precondition(NativeScreenshotCaptureResolution.windowPixels(
            frame: crossing, displays: displays, maxPixels: 479_999) == nil,
            "a high-density window must not evade the pixel cap")
        precondition(NativeScreenshotCaptureResolution.windowPixels(
            frame: CGRect(x: 2000, y: 100, width: 400, height: 300),
            displays: displays, maxPixels: 480_000)
            == NativeScreenshotPixelSize(width: 400, height: 300),
            "a window wholly on the 1× display must remain 1×")
    }

    private static func rejectUnexpectedFirstFrameSize() throws {
        let native = NativeScreenshotPixelSize(width: 3024, height: 1964)
        try NativeScreenshotCaptureResolution.validateFrame(actual: native, expected: native)
        do {
            try NativeScreenshotCaptureResolution.validateFrame(
                actual: NativeScreenshotPixelSize(width: 1512, height: 982), expected: native)
            preconditionFailure("a 1× first frame was silently accepted")
        } catch let error as NativeScreenshotCaptureError {
            guard case let .frameSizeMismatch(expected, actual) = error else { throw error }
            precondition(expected == native && actual == NativeScreenshotPixelSize(
                width: 1512, height: 982),
                "the mismatch must preserve both dimensions for diagnosis")
        }
    }

    private static func localizedCaptureResolutionErrors() {
        let previousLanguage = UserDefaults.standard.object(forKey: "appLanguage")
        defer {
            if let previousLanguage {
                UserDefaults.standard.set(previousLanguage, forKey: "appLanguage")
            } else {
                UserDefaults.standard.removeObject(forKey: "appLanguage")
            }
        }
        let actual = NativeScreenshotPixelSize(width: 1512, height: 982)
        let expected = NativeScreenshotPixelSize(width: 3024, height: 1964)
        let mismatch = NativeScreenshotCaptureError.frameSizeMismatch(
            expected: expected, actual: actual)
        UserDefaults.standard.set("zh", forKey: "appLanguage")
        precondition(NativeScreenshotCaptureError.nativeResolutionUnavailable.localizedDescription
            == "无法确定显示器的原生像素分辨率，请重试。")
        precondition(mismatch.localizedDescription
            == "截图帧分辨率异常：实际 1512×982，预期 3024×1964。请重试。")
        UserDefaults.standard.set("en", forKey: "appLanguage")
        precondition(NativeScreenshotCaptureError.nativeResolutionUnavailable.localizedDescription
            == "The display's native pixel resolution is unavailable. Please retry.")
        precondition(mismatch.localizedDescription
            == "Screen Capture returned 1512×982 pixels instead of the requested 3024×1964. Please retry.")
    }

    private static func geometryAcrossMixedScaleDisplays() throws {
        let region = CGRect(x: 100, y: 50, width: 200, height: 150)
        let left = CGRect(x: 0, y: 0, width: 200, height: 200)
        let right = CGRect(x: 200, y: 0, width: 200, height: 200)
        let leftIntersection = try require(
            NativeScreenshotCaptureGeometry.intersection(region, displayFrame: left)
        )
        let rightIntersection = try require(
            NativeScreenshotCaptureGeometry.intersection(region, displayFrame: right)
        )
        precondition(leftIntersection == CGRect(x: 100, y: 50, width: 100, height: 150))
        precondition(rightIntersection == CGRect(x: 200, y: 50, width: 100, height: 150))
        precondition(NativeScreenshotCaptureGeometry.pixelCrop(
            intersection: leftIntersection, displayFrame: left, imageWidth: 400, imageHeight: 400
        ) == CGRect(x: 200, y: 100, width: 200, height: 300))
        precondition(NativeScreenshotCaptureGeometry.pixelCrop(
            intersection: rightIntersection, displayFrame: right, imageWidth: 200, imageHeight: 200
        ) == CGRect(x: 0, y: 50, width: 100, height: 150))
        precondition(NativeScreenshotCaptureGeometry.outputRect(
            intersection: rightIntersection, region: region, scale: 2
        ) == CGRect(x: 200, y: 0, width: 200, height: 300))
        precondition(NativeScreenshotCaptureGeometry.outputSize(
            region: region, scale: 2, maxPixels: 120_000
        )?.width == 400)
        precondition(NativeScreenshotCaptureGeometry.outputSize(
            region: region, scale: 2, maxPixels: 119_999
        ) == nil)

        let negativeDisplay = CGRect(x: -300, y: -100, width: 300, height: 200)
        let negativeRegion = CGRect(x: -150, y: -50, width: 250, height: 100)
        precondition(NativeScreenshotCaptureGeometry.intersection(
            negativeRegion, displayFrame: negativeDisplay
        ) == CGRect(x: -150, y: -50, width: 150, height: 100))
    }

    private static func composeAcrossDisplays() throws {
        let red = try solidImage(width: 400, height: 400, red: 1, blue: 0)
        let blue = try solidImage(width: 200, height: 200, red: 0, blue: 1)
        let (image, scale) = try NativeScreenshotCaptureComposer.compose(
            region: CGRect(x: 100, y: 50, width: 200, height: 150),
            pieces: [
                NativeScreenshotCapturePiece(
                    displayFrame: CGRect(x: 0, y: 0, width: 200, height: 200), image: red
                ),
                NativeScreenshotCapturePiece(
                    displayFrame: CGRect(x: 200, y: 0, width: 200, height: 200), image: blue
                )
            ],
            maxOutputPixels: 120_000
        )
        precondition(scale == 2 && image.width == 400 && image.height == 300)

        let context = try bitmap(width: 400, height: 300)
        context.draw(image, in: CGRect(x: 0, y: 0, width: 400, height: 300))
        let bytes = try require(context.data).assumingMemoryBound(to: UInt8.self)
        let left = 150 * context.bytesPerRow + 100 * 4
        let right = 150 * context.bytesPerRow + 300 * 4
        precondition(bytes[left + 2] > 240 && bytes[left] < 10)
        precondition(bytes[right] > 240 && bytes[right + 2] < 10)

        let (vertical, _) = try NativeScreenshotCaptureComposer.compose(
            region: CGRect(x: 0, y: 0, width: 100, height: 200),
            pieces: [
                NativeScreenshotCapturePiece(
                    displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100), image: red
                ),
                NativeScreenshotCapturePiece(
                    displayFrame: CGRect(x: 0, y: 100, width: 100, height: 100), image: blue
                )
            ],
            maxOutputPixels: 320_000
        )
        let top = try require(NativeScreenshotAnnotationRenderer.sampleColor(
            at: CGPoint(x: 50, y: 100), in: vertical
        ))
        let bottom = try require(NativeScreenshotAnnotationRenderer.sampleColor(
            at: CGPoint(x: 50, y: 700), in: vertical
        ))
        precondition(top.red > 0.9 && top.blue < 0.1)
        precondition(bottom.blue > 0.9 && bottom.red < 0.1)
    }

    private static func solidImage(width: Int, height: Int, red: CGFloat, blue: CGFloat) throws -> CGImage {
        let context = try bitmap(width: width, height: height)
        context.setFillColor(CGColor(red: red, green: 0, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try require(context.makeImage())
    }

    private static func bitmap(width: Int, height: Int) throws -> CGContext {
        try require(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                CGBitmapInfo.byteOrder32Little.rawValue
        ))
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw NativeScreenshotCaptureError.invalidRegion }
        return value
    }
}
