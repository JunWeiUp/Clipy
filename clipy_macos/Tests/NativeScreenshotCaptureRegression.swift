import CoreGraphics
import Foundation

@main
enum NativeScreenshotCaptureRegression {
    static func main() throws {
        try geometryAcrossMixedScaleDisplays()
        try composeAcrossDisplays()
        print("NativeScreenshotCaptureRegression passed")
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
