#!/usr/bin/env swift
// Export the approved macOS tile into a multi-resolution Windows ICO.
import CoreGraphics
import Foundation
import ImageIO

enum ExportError: Error { case invalidImage, invalidContext, encodingFailed }

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let sourceURL = root.appendingPathComponent("Clipy/Resources/AppIcon.png")
let outputURL = root.appendingPathComponent("clipy_android/windows/runner/resources/app_icon.ico")
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    throw ExportError.invalidImage
}

func png(_ size: Int) throws -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                      CGBitmapInfo.byteOrder32Big.rawValue) else {
        throw ExportError.invalidContext
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let resized = context.makeImage() else { throw ExportError.invalidContext }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
        throw ExportError.encodingFailed
    }
    CGImageDestinationAddImage(destination, resized, nil)
    guard CGImageDestinationFinalize(destination) else { throw ExportError.encodingFailed }
    return data as Data
}

func append16(_ value: Int, to data: inout Data) {
    data.append(UInt8(value & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
}

func append32(_ value: Int, to data: inout Data) {
    for shift in stride(from: 0, through: 24, by: 8) {
        data.append(UInt8((value >> shift) & 0xff))
    }
}

let sizes = [16, 24, 32, 48, 64, 128, 256]
let images = try sizes.map(png)
var ico = Data()
append16(0, to: &ico)
append16(1, to: &ico)
append16(sizes.count, to: &ico)
var offset = 6 + sizes.count * 16
for (size, bytes) in zip(sizes, images) {
    ico.append(UInt8(size == 256 ? 0 : size))
    ico.append(UInt8(size == 256 ? 0 : size))
    ico.append(0)
    ico.append(0)
    append16(1, to: &ico)
    append16(32, to: &ico)
    append32(bytes.count, to: &ico)
    append32(offset, to: &ico)
    offset += bytes.count
}
for bytes in images { ico.append(bytes) }
try ico.write(to: outputURL, options: .atomic)
print("Exported \(outputURL.path)")
