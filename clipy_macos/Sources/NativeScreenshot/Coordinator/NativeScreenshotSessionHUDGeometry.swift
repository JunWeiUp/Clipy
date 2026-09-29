import CoreGraphics

/// Screen-space frames for the two independent long-capture windows.
/// The selection and visible rects use AppKit's bottom-left coordinate space.
enum NativeScreenshotSessionHUDGeometry {
    static let previewWidth: CGFloat = 200
    private static let previewGap: CGFloat = 12
    private static let controlHeight: CGFloat = 36

    static func scrollPreviewFrame(
        selection: CGRect, visible: CGRect, imagePixels: CGSize
    ) -> CGRect? {
        guard selection.width > 0, selection.height > 0,
              visible.width >= previewWidth, visible.height >= 124 else { return nil }
        let required = previewWidth + previewGap * 2
        let right = visible.maxX - selection.maxX
        let left = selection.minX - visible.minX
        let x: CGFloat
        if right >= required {
            x = selection.maxX + previewGap
        } else if left >= required {
            x = selection.minX - previewGap - previewWidth
        } else {
            return nil
        }
        let ceiling = visible.maxY - 20
        let bottom = max(visible.minY + 4,
                         min(selection.minY - 1.25, ceiling - 100))
        let availableHeight = max(100, ceiling - bottom)
        let aspect = imagePixels.height / max(1, imagePixels.width)
        let desiredHeight = max(100, (previewWidth - 8) * aspect + 8)
        let height = min(desiredHeight, availableHeight)
        return CGRect(x: x, y: bottom, width: previewWidth, height: height)
    }

    static func scrollControlFrame(
        selection: CGRect, visible: CGRect, width: CGFloat = 350
    ) -> CGRect {
        let height = controlHeight
        let x = max(visible.minX + 4,
                    min(selection.midX - width / 2, visible.maxX - width - 4))
        let below = selection.minY - height - 6
        let above = selection.maxY + 6
        let preferredY = below >= visible.minY + 4 ? below : above
        let y = max(visible.minY + 4,
                    min(preferredY, visible.maxY - height - 4))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
