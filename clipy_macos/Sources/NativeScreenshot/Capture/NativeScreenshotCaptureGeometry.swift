import CoreGraphics

/// Geometry shared by still capture and its caller. Rectangles are in the
/// global, point-based coordinate space reported by `SCDisplay.frame`.
enum NativeScreenshotCaptureGeometry {
    static func intersection(_ region: CGRect, displayFrame: CGRect) -> CGRect? {
        guard isUsable(region), isUsable(displayFrame) else { return nil }
        let overlap = region.intersection(displayFrame)
        return overlap.isNull || overlap.isEmpty ? nil : overlap
    }

    static func pixelCrop(
        intersection: CGRect,
        displayFrame: CGRect,
        imageWidth: Int,
        imageHeight: Int
    ) -> CGRect? {
        guard isUsable(intersection), isUsable(displayFrame),
              imageWidth > 0, imageHeight > 0 else { return nil }

        let scaleX = CGFloat(imageWidth) / displayFrame.width
        let scaleY = CGFloat(imageHeight) / displayFrame.height
        let x0 = max(0, min(CGFloat(imageWidth), floor((intersection.minX - displayFrame.minX) * scaleX)))
        let y0 = max(0, min(CGFloat(imageHeight), floor((intersection.minY - displayFrame.minY) * scaleY)))
        let x1 = max(0, min(CGFloat(imageWidth), ceil((intersection.maxX - displayFrame.minX) * scaleX)))
        let y1 = max(0, min(CGFloat(imageHeight), ceil((intersection.maxY - displayFrame.minY) * scaleY)))
        guard x1 > x0, y1 > y0 else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    static func outputRect(intersection: CGRect, region: CGRect, scale: CGFloat) -> CGRect? {
        guard isUsable(intersection), isUsable(region), scale.isFinite, scale > 0 else { return nil }
        let x0 = floor((intersection.minX - region.minX) * scale)
        let y0 = floor((intersection.minY - region.minY) * scale)
        let x1 = ceil((intersection.maxX - region.minX) * scale)
        let y1 = ceil((intersection.maxY - region.minY) * scale)
        guard x1 > x0, y1 > y0 else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    static func outputSize(region: CGRect, scale: CGFloat, maxPixels: Int) -> (width: Int, height: Int)? {
        guard isUsable(region), scale.isFinite, scale > 0, maxPixels > 0 else { return nil }
        let width = ceil(region.width * scale)
        let height = ceil(region.height * scale)
        guard width.isFinite, height.isFinite,
              width >= 1, height >= 1,
              width <= 32_768, height <= 32_768,
              width * height <= CGFloat(maxPixels) else { return nil }
        return (Int(width), Int(height))
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite &&
            rect.width.isFinite && rect.height.isFinite &&
            rect.width > 0 && rect.height > 0
    }
}
