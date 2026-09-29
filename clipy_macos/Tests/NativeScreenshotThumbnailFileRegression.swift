import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The presenter is compiled with its UI excluded for this file I/O regression.
// The encoder stand-in fails on the second image to exercise batch rollback.
enum NativeScreenshotImageProcessor {
    enum FileFormat: String { case png, jpeg }
    enum ImageError: Error { case invalidImage, fixtureFailure }

    static func encode(_ image: CGImage, as format: FileFormat,
                       quality: CGFloat = 0.85) throws -> Data {
        if image.width == 2 { throw ImageError.fixtureFailure }
        return Data("encoded fixture".utf8)
    }
}

@main
struct NativeScreenshotThumbnailFileRegression {
    static func main() throws {
        for size in [CGSize(width: 180, height: 120),
                     CGSize(width: 240, height: 160),
                     CGSize(width: 480, height: 320)] {
            let layout = NativeScreenshotThumbnailHoverLayout.make(in: size)
            let corners = [layout.close, layout.pin, layout.edit, layout.share]
            let center = [layout.copy, layout.save]
            precondition(layout.close.minX < layout.pin.minX
                         && layout.edit.minX < layout.share.minX)
            precondition(layout.copy.minY > layout.save.maxY)
            precondition((corners + center).allSatisfy {
                CGRect(origin: .zero, size: size).contains($0)
            }, "Hover controls must remain inside every thumbnail size")
            precondition(corners.allSatisfy { corner in
                center.allSatisfy { !$0.intersects(corner) }
            }, "Corner actions must not cover Copy or Save")
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clipy-thumbnail-regression-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try png(width: 1)
        let second = try png(width: 2)

        let successFolder = root.appendingPathComponent("success", isDirectory: true)
        let urls = try NativeScreenshotThumbnailFileStore.saveAll(
            pngData: [first, second], in: successFolder,
            basename: "Screenshot", format: .png, quality: 0.85)
        precondition(urls.count == 2 && urls[0] != urls[1])
        let savedFirst = try Data(contentsOf: urls[0])
        let savedSecond = try Data(contentsOf: urls[1])
        precondition(savedFirst == first && savedSecond == second)

        let failureFolder = root.appendingPathComponent("failure", isDirectory: true)
        do {
            _ = try NativeScreenshotThumbnailFileStore.saveAll(
                pngData: [first, second], in: failureFolder,
                basename: "Screenshot", format: .jpeg, quality: 0.85)
            preconditionFailure("Second image was expected to fail encoding")
        } catch NativeScreenshotImageProcessor.ImageError.fixtureFailure {
            let leftovers = try FileManager.default.contentsOfDirectory(
                at: failureFolder, includingPropertiesForKeys: nil)
            precondition(leftovers.isEmpty, "Batch failure left a partial save")
        }
        print("Native screenshot thumbnail file regression passed")
    }

    private static func png(width: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: 1,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 1))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
