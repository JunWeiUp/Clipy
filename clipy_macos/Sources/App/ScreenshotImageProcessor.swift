import AppKit
import CoreGraphics
import CoreImage

enum ScreenshotImageProcessor {
    /// Lazily-created CIContext used only for pixellate/mosaic annotations and
    /// resampling. A CIContext retains an IOSurface/texture pool sized by the
    /// largest image it has processed, and that pool never shrinks for the life
    /// of the context. To keep the post-screenshot footprint low we hold the
    /// context only while it is in use and drop it once a capture finishes, so
    /// the pool is released back to the system instead of lingering at the peak
    /// (e.g. ~30-80MB for a 4K screenshot). Re-creation costs only tens of ms.
    private static var _sharedCIContext: CIContext?
    static var sharedCIContext: CIContext {
        if let context = _sharedCIContext { return context }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        _sharedCIContext = context
        return context
    }

    /// Releases the cached CIContext so its GPU/IOSurface pool is reclaimed.
    /// Called after a screenshot flow completes; the next consumer recreates it.
    static func releaseCIContext() {
        _sharedCIContext = nil
    }

    static func pixelSize(
        forLogicalSize logicalSize: NSSize,
        in rect: NSRect? = nil,
        resolution: ScreenshotResolution = PreferencesManager.shared.screenshotResolution,
        displayNativeScale: CGFloat? = nil
    ) -> NSSize {
        let screen = screen(for: rect) ?? NSScreen.main
        let scale = resolution.pixelScale(for: screen, displayNativeScale: displayNativeScale)
        return pixelSize(forLogicalSize: logicalSize, scale: scale)
    }

    static func pixelSize(forLogicalSize logicalSize: NSSize, scale: CGFloat) -> NSSize {
        NSSize(
            width: max(1, ceil(logicalSize.width * scale)),
            height: max(1, ceil(logicalSize.height * scale))
        )
    }

    static func pixelDimensions(of image: NSImage) -> NSSize? {
        guard let cgImage = bestCGImage(from: image) else { return nil }
        return NSSize(width: cgImage.width, height: cgImage.height)
    }

    /// Wrap a freshly captured CGImage without downscaling native pixels.
    static func fromCapture(
        _ cgImage: CGImage,
        logicalSize: NSSize,
        resolution: ScreenshotResolution = PreferencesManager.shared.screenshotResolution,
        displayNativeScale: CGFloat? = nil
    ) -> NSImage {
        // All resolution modes now resolve to native pixels, so simply wrap the capture
        // without resampling. Avoids both downsampling blur and upsampling softness.
        _ = resolution
        _ = displayNativeScale
        // wrapWithBitmapRep attaches an explicit NSBitmapImageRep so downstream
        // bestCGImage / cgImage(forProposedRect:) get the native pixels instead
        // of re-rasterizing at the logical point size (which dropped Retina 2x).
        return wrapWithBitmapRep(cgImage, logicalSize: logicalSize)
    }

    /// Wrap a CGImage in an NSImage that carries an explicit NSBitmapImageRep at
    /// the CGImage's native pixel size. This keeps `bestCGImage` /
    /// `cgImage(forProposedRect:)` from re-rasterizing at the logical point size
    /// (which would drop Retina 2x pixels). Used for capture results and
    /// flattened (annotated) exports alike.
    static func wrapWithBitmapRep(_ cgImage: CGImage, logicalSize: NSSize) -> NSImage {
        let image = NSImage(cgImage: cgImage, size: logicalSize)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = logicalSize
        image.addRepresentation(rep)
        return image
    }

    static func normalized(
        from cgImage: CGImage,
        logicalSize: NSSize,
        in rect: NSRect? = nil,
        displayNativeScale: CGFloat? = nil,
        allowDownscale: Bool = false
    ) -> NSImage {
        let target = pixelSize(
            forLogicalSize: logicalSize,
            in: rect,
            displayNativeScale: displayNativeScale
        )
        if dimensionsMatch(cgImage: cgImage, target: target) {
            return NSImage(cgImage: cgImage, size: logicalSize)
        }
        if !allowDownscale,
           (cgImage.width > Int(target.width) || cgImage.height > Int(target.height)) {
            return NSImage(cgImage: cgImage, size: logicalSize)
        }
        // Never upscale: inventing pixels makes screenshots soft and inflates file size
        // without adding real detail. Only resample down (when explicitly allowed).
        if allowDownscale,
           (cgImage.width > Int(target.width) || cgImage.height > Int(target.height)) {
            return resample(cgImage: cgImage, to: target, logicalSize: logicalSize)
        }
        return NSImage(cgImage: cgImage, size: logicalSize)
    }

    /// Keep existing pixel data; only upscale when the configured target is larger.
    static func preservePixels(
        _ image: NSImage,
        logicalSize: NSSize? = nil,
        in rect: NSRect? = nil,
        displayNativeScale: CGFloat? = nil
    ) -> NSImage {
        let logical = logicalSize ?? image.size
        guard let cgImage = bestCGImage(from: image) else { return image }
        return normalized(
            from: cgImage,
            logicalSize: logical,
            in: rect,
            displayNativeScale: displayNativeScale,
            allowDownscale: false
        )
    }

    static func resampleIfNeeded(
        _ image: NSImage,
        logicalSize: NSSize? = nil,
        in rect: NSRect? = nil,
        displayNativeScale: CGFloat? = nil
    ) -> NSImage {
        preservePixels(image, logicalSize: logicalSize, in: rect, displayNativeScale: displayNativeScale)
    }

    static func pngData(
        from image: NSImage,
        logicalSize: NSSize? = nil,
        in rect: NSRect? = nil,
        displayNativeScale: CGFloat? = nil
    ) -> Data? {
        let logical = logicalSize ?? image.size
        let preserved = preservePixels(
            image,
            logicalSize: logical,
            in: rect,
            displayNativeScale: displayNativeScale
        )
        guard let cgImage = bestCGImage(from: preserved) else { return nil }
        return pngData(from: cgImage, logicalSize: logical)
    }

    static func pngData(from cgImage: CGImage, logicalSize: NSSize) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        bitmap.size = logicalSize
        return bitmap.representation(using: .png, properties: [:])
    }

    /// A disk-bound encoded image paired with the file extension matching its format.
    /// Used so screenshots save as compact JPEG when opaque (5-10x smaller than PNG)
    /// while still falling back to PNG when transparency is present.
    struct EncodedImage {
        let data: Data
        let fileExtension: String   // "jpg" or "png"
    }

    /// Returns true if `cgImage` has any meaningful alpha (any pixel with alpha < 1).
    /// Screen captures are normally fully opaque, so this lets us switch to JPEG.
    /// Samples up to `maxSamples` pixels for speed on large images; alpha is usually
    /// uniform across the whole image so sampling is reliable.
    static func cgImageIsOpaque(_ cgImage: CGImage, maxSamples: Int = 200_000) -> Bool {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return true }
        let alphaInfo = cgImage.alphaInfo
        if alphaInfo == .none || alphaInfo == .noneSkipFirst || alphaInfo == .noneSkipLast {
            return true
        }
        // Has an alpha channel: scan it. Use a stride so we sample across the image.
        guard let dataProvider = cgImage.dataProvider else { return false }
        guard let data = dataProvider.data else { return false }
        let bytesPerRow = cgImage.bytesPerRow
        let bitsPerPixel = cgImage.bitsPerPixel
        let bytesPerPixel = bitsPerPixel / 8
        guard bytesPerPixel >= 1 else { return true }
        let totalPixels = width * height
        let sampleStride = max(1, totalPixels / maxSamples)

        // Locate the alpha byte for each pixel based on alphaInfo.
        let alphaOffset: Int
        switch alphaInfo {
        case .premultipliedLast, .last:        // alpha is last component (RGBA)
            alphaOffset = bytesPerPixel - 1
        case .premultipliedFirst, .first:       // alpha is first component (ARGB)
            alphaOffset = 0
        default:
            return false
        }

        let nsData = data as Data
        return nsData.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) -> Bool in
            guard let base = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return false }
            let length = rawBuf.count
            for i in stride(from: 0, to: totalPixels, by: sampleStride) {
                let px = i % width
                let py = i / width
                let offset = py * bytesPerRow + px * bytesPerPixel + alphaOffset
                if offset >= length { break }
                if base[offset] < 255 {
                    return false
                }
            }
            return true
        }
    }

    /// Encode for disk saving: opaque images become high-quality JPEG (visually
    /// lossless at 0.85, 5-10x smaller than PNG); images with transparency stay
    /// PNG to preserve the alpha channel. Pixel resolution is never changed.
    static func encodeForSave(from cgImage: CGImage, logicalSize: NSSize) -> EncodedImage? {
        if cgImageIsOpaque(cgImage), let jpg = jpegData(from: cgImage, logicalSize: logicalSize) {
            return EncodedImage(data: jpg, fileExtension: "jpg")
        }
        if let png = pngData(from: cgImage, logicalSize: logicalSize) {
            return EncodedImage(data: png, fileExtension: "png")
        }
        return nil
    }

    static func encodeForSave(from image: NSImage, logicalSize: NSSize? = nil) -> EncodedImage? {
        let logical = logicalSize ?? image.size
        guard let cgImage = bestCGImage(from: image) else { return nil }
        return encodeForSave(from: cgImage, logicalSize: logical)
    }

    /// JPEG cannot carry alpha. Flatten the CGImage onto white and re-encode at
    /// quality 0.85 (visually lossless for screen content, far smaller than PNG).
    private static func jpegData(from cgImage: CGImage, logicalSize: NSSize) -> Data? {
        let pixelW = cgImage.width
        let pixelH = cgImage.height
        // Draw onto an opaque RGB context to drop the alpha channel and composite
        // any (already-known-opaque) pixels onto white for safety.
        guard let context = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
        guard let flattened = context.makeImage() else { return nil }

        let bitmap = NSBitmapImageRep(cgImage: flattened)
        bitmap.size = logicalSize
        return bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.85]
        )
    }

    private static func dimensionsMatch(cgImage: CGImage, target: NSSize) -> Bool {
        abs(CGFloat(cgImage.width) - target.width) <= 1
            && abs(CGFloat(cgImage.height) - target.height) <= 1
    }

    private static func resample(
        cgImage: CGImage,
        to target: NSSize,
        logicalSize: NSSize
    ) -> NSImage {
        let pixelW = Int(target.width)
        let pixelH = Int(target.height)

        if let output = lanczosResample(cgImage: cgImage, width: pixelW, height: pixelH) {
            return NSImage(cgImage: output, size: logicalSize)
        }

        guard let context = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return NSImage(cgImage: cgImage, size: logicalSize)
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
        guard let output = context.makeImage() else {
            return NSImage(cgImage: cgImage, size: logicalSize)
        }
        return NSImage(cgImage: output, size: logicalSize)
    }

    private static func lanczosResample(cgImage: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }

        let input = CIImage(cgImage: cgImage)
        let scaleX = CGFloat(width) / CGFloat(max(cgImage.width, 1))
        let scaleY = CGFloat(height) / CGFloat(max(cgImage.height, 1))
        let scale = min(scaleX, scaleY)

        if let filter = CIFilter(name: "CILanczosScaleTransform") {
            filter.setValue(input, forKey: kCIInputImageKey)
            filter.setValue(scale, forKey: kCIInputScaleKey)
            filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
            if let output = filter.outputImage,
               let result = sharedCIContext.createCGImage(output, from: output.extent) {
                if result.width == width, result.height == height {
                    return result
                }
                return crop(cgImage: result, to: width, height: height) ?? result
            }
        }

        let scaled = input.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        return sharedCIContext.createCGImage(
            scaled,
            from: CGRect(x: 0, y: 0, width: width, height: height)
        )
    }

    private static func crop(cgImage: CGImage, to width: Int, height: Int) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let target = CGRect(
            x: max(0, CGFloat(cgImage.width - width) / 2),
            y: max(0, CGFloat(cgImage.height - height) / 2),
            width: min(CGFloat(width), bounds.width),
            height: min(CGFloat(height), bounds.height)
        ).integral
        return cgImage.cropping(to: target)
    }

    private static func screen(for rect: NSRect?) -> NSScreen? {
        guard let rect else { return NSScreen.main }
        return NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
    }

    static func bestCGImage(from image: NSImage) -> CGImage? {
        var best: CGImage?
        var bestPixels = 0

        // Prefer an attached NSBitmapImageRep: it carries the true pixel buffer,
        // so its cgImage is at native resolution (e.g. Retina 2x). This is why
        // `fromCapture` / `wrapWithBitmapRep` explicitly add a rep.
        for rep in image.representations {
            guard let bitmap = rep as? NSBitmapImageRep, let cgImage = bitmap.cgImage else { continue }
            let pixels = cgImage.width * cgImage.height
            if pixels > bestPixels {
                best = cgImage
                bestPixels = pixels
            }
        }

        if let best {
            return best
        }

        // Fallback: rasterize on demand. CAVEAT — passing a rect of `image.size`
        // (logical points) makes AppKit draw at point resolution, dropping Retina
        // pixels. Callers that need native pixels must attach a bitmap rep (see
        // `fromCapture`); this branch exists only for legacy/ad-hoc NSImages.
        var rect = NSRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return cgImage
        }

        rect.size = NSSize(
            width: max(image.size.width, 1),
            height: max(image.size.height, 1)
        )
        return image.cgImage(
            forProposedRect: &rect,
            context: nil,
            hints: [NSImageRep.HintKey.interpolation: NSNumber(value: NSImageInterpolation.none.rawValue)]
        )
    }
}
