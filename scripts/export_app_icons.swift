#!/usr/bin/env swift
// Deterministic platform exports of the approved artwork; macOS system SDKs only.
import AppKit
import CoreGraphics
import Foundation
import ImageIO

enum IconError: Error { case invalid(String) }

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let android = "clipy_android/android/app/src/main/res"
let ios = "clipy_android/ios/Runner/Assets.xcassets/AppIcon.appiconset"

func canvas(_ width: Int, _ height: Int? = nil, opaque: Bool = false) throws -> CGContext {
    let alpha = opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast
    guard let context = CGContext(
        data: nil, width: width, height: height ?? width, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: alpha.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    ) else { throw IconError.invalid("Cannot allocate image context") }
    context.interpolationQuality = .high
    return context
}

func loadImage(_ path: String) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(root.appendingPathComponent(path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw IconError.invalid("Cannot read \(path)") }
    return image
}

func save(_ image: CGImage, _ path: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { throw IconError.invalid("Cannot write \(path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw IconError.invalid("PNG export failed: \(path)") }
}

func resized(_ image: CGImage, to size: Int, opaque: Bool = false) throws -> CGImage {
    let context = try canvas(size, opaque: opaque)
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return context.makeImage()!
}

func roundedTile(_ image: CGImage) throws -> CGImage {
    // macOS does not apply the iOS launcher mask. Leave a clean 64 px outer margin.
    let context = try canvas(1024)
    let rect = CGRect(x: 64, y: 64, width: 896, height: 896)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: 200, cornerHeight: 200, transform: nil))
    context.clip()
    context.draw(image, in: rect)
    return context.makeImage()!
}

func adaptiveMark(_ image: CGImage) throws -> CGImage {
    // This key is specific to icon-master.png: background red <= 8, ceramic red > 20.
    // Remove the saturated blue background and its contact shadow, not the bevels.
    let context = try canvas(image.width, image.height)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    var minX = image.width, minY = image.height, maxX = 0, maxY = 0
    for y in 0..<image.height {
        for x in 0..<image.width {
            let i = (y * image.width + x) * 4
            let red = Double(pixels[i])
            let t = min(1, max(0, (red - 8) / 56))
            let alpha = t * t * (3 - 2 * t)
            // Store premultiplied RGBA; subtract the blue spill on partially covered edges.
            let background = [0.0, 105.0, 248.0]
            for channel in 0..<3 {
                let value = Double(pixels[i + channel]) - (1 - alpha) * background[channel]
                pixels[i + channel] = UInt8(min(255 * alpha, max(0, value)).rounded())
            }
            pixels[i + 3] = UInt8((alpha * 255).rounded())
            if alpha > 0.05 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    guard maxX > minX, maxY > minY else { throw IconError.invalid("No foreground found") }
    // CoreGraphics image cropping uses the same top-left row convention as the pixel buffer.
    let bounds = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    guard let mark = context.makeImage()?.cropping(to: bounds) else {
        throw IconError.invalid("Cannot crop foreground")
    }
    // 108 dp canvas at xxxhdpi. A 54 dp tall mark fits the centered 66 dp safe circle.
    let target = try canvas(432)
    let height = 216.0
    let width = height * Double(mark.width) / Double(mark.height)
    target.draw(mark, in: CGRect(x: (432 - width) / 2, y: (432 - height) / 2, width: width, height: height))
    let output = target.makeImage()!
    let data = target.data!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<432 {
        for x in 0..<432 where data[(y * 432 + x) * 4 + 3] > 12 {
            guard hypot(Double(x) - 215.5, Double(y) - 215.5) <= 132 else {
                throw IconError.invalid("Foreground exceeds Android's 66 dp safe circle")
            }
        }
    }
    return output
}

func monochrome(_ image: CGImage) throws -> CGImage {
    let context = try canvas(image.width, image.height)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    for i in stride(from: 0, to: image.width * image.height * 4, by: 4) {
        pixels[i] = pixels[i + 3]; pixels[i + 1] = pixels[i + 3]; pixels[i + 2] = pixels[i + 3]
    }
    return context.makeImage()!
}

func adaptivePreview(_ mark: CGImage, circle: Bool, themed: Bool = false) throws -> CGImage {
    let context = try canvas(288)
    let rect = CGRect(x: 0, y: 0, width: 288, height: 288)
    context.addPath(circle ? CGPath(ellipseIn: rect, transform: nil)
                          : CGPath(roundedRect: rect, cornerWidth: 64, cornerHeight: 64, transform: nil))
    context.clip()
    if themed {
        context.setFillColor(CGColor(srgbRed: 0.80, green: 0.87, blue: 0.98, alpha: 1))
        context.fill(rect)
        context.clip(to: CGRect(x: -72, y: -72, width: 432, height: 432), mask: mark)
        context.setFillColor(CGColor(srgbRed: 0.12, green: 0.23, blue: 0.39, alpha: 1))
        context.fill(rect)
    } else {
        // Matches ic_launcher_background.xml; show the central 72 dp mask, not all 108 dp.
        let colors = [CGColor(srgbRed: 0.02, green: 0.56, blue: 0.98, alpha: 1),
                      CGColor(srgbRed: 0.01, green: 0.38, blue: 0.96, alpha: 1)]
        let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: -72, y: 360), end: CGPoint(x: 360, y: -72), options: [])
        context.draw(mark, in: CGRect(x: -72, y: -72, width: 432, height: 432))
    }
    return context.makeImage()!
}

func preview(tile: CGImage, master: CGImage, foreground: CGImage, mono: CGImage) throws {
    let context = try canvas(1440, 520, opaque: true)
    context.setFillColor(CGColor(srgbRed: 0.95, green: 0.96, blue: 0.98, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1440, height: 520))
    let samples = [tile, try adaptivePreview(foreground, circle: true),
                   try adaptivePreview(foreground, circle: false),
                   try adaptivePreview(mono, circle: true, themed: true),
                   try roundedTile(master)]
    let labels = ["macOS", "Android · circle", "Android · rounded", "Android · themed", "iOS · mask preview"]
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    for (index, image) in samples.enumerated() {
        let x = 40 + index * 280
        context.draw(image, in: CGRect(x: x, y: 180, width: 240, height: 240))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 17, weight: .medium), .foregroundColor: NSColor.darkGray
        ]
        let label = labels[index] as NSString
        let textWidth = label.size(withAttributes: attributes).width
        label.draw(at: CGPoint(x: Double(x) + (240 - textWidth) / 2, y: 140), withAttributes: attributes)
    }
    for (index, size) in [16, 32, 64].enumerated() {
        context.draw(try resized(tile, to: size), in: CGRect(x: 70 + index * 90, y: 40, width: size, height: size))
    }
    NSGraphicsContext.restoreGraphicsState()
    try save(context.makeImage()!, "assets/branding/icon-preview.png")
}

struct Catalogue: Decodable {
    struct Entry: Decodable { let size: String; let scale: String; let filename: String }
    let images: [Entry]
}

func export() throws {
    guard CommandLine.arguments.count == 1 else { throw IconError.invalid("Usage: swift scripts/export_app_icons.swift") }
    let master = try loadImage("assets/branding/icon-master.png")
    guard master.width == 1254, master.height == 1254 else {
        throw IconError.invalid("Artwork changed: review color key, framing and safe area before exporting")
    }
    let tile = try roundedTile(master)
    try save(tile, "Clipy/Resources/AppIcon.png")
    try save(try resized(tile, to: 512), "Logo.png")
    try save(try resized(tile, to: 192), "assets/logo/logo_placeholder.png")
    for (density, size) in [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)] {
        try save(try resized(tile, to: size), "\(android)/mipmap-\(density)/ic_launcher.png")
    }
    let foreground = try adaptiveMark(master)
    let mono = try monochrome(foreground)
    try save(foreground, "\(android)/drawable-xxxhdpi/ic_launcher_foreground.png")
    try save(mono, "\(android)/drawable-xxxhdpi/ic_launcher_monochrome.png")
    let catalogue = try JSONDecoder().decode(Catalogue.self, from: Data(contentsOf: root.appendingPathComponent("\(ios)/Contents.json")))
    var exported = Set<String>()
    for entry in catalogue.images where exported.insert(entry.filename).inserted {
        guard let points = Double(entry.size.split(separator: "x")[0]),
              let scale = Double(entry.scale.dropLast()),
              !entry.filename.contains("/"), entry.filename.hasSuffix(".png")
        else { throw IconError.invalid("Invalid iOS catalogue entry") }
        try save(try resized(master, to: Int((points * scale).rounded()), opaque: true), "\(ios)/\(entry.filename)")
    }
    try preview(tile: tile, master: master, foreground: foreground, mono: mono)
    print("Exported macOS, Android (legacy/adaptive/themed), iOS and README icons.")
    print("Preview: assets/branding/icon-preview.png")
}

do { try export() } catch {
    fputs("Icon export failed: \(error)\n", stderr)
    exit(1)
}
