import CoreGraphics

/// Screen-space frames for the two independent long-capture windows.
/// The selection and visible rects use AppKit's bottom-left coordinate space.
enum NativeScreenshotSessionHUDGeometry {
    static let previewWidth: CGFloat = 200
    private static let previewGap: CGFloat = 12
    private static let controlHeight: CGFloat = 36
    private static let minimumPreviewWidth: CGFloat = 96
    private static let minimumPreviewHeight: CGFloat = 100

    static func scrollPreviewFrame(
        selection: CGRect, visible: CGRect, imagePixels: CGSize,
        controls: CGRect? = nil
    ) -> CGRect? {
        guard selection.width > 0, selection.height > 0,
              visible.width >= minimumPreviewWidth + 16,
              visible.height >= minimumPreviewHeight + 24 else { return nil }

        func height(for width: CGFloat, maximum: CGFloat) -> CGFloat {
            let aspect = max(0, imagePixels.height) / max(1, imagePixels.width)
            let desired = max(minimumPreviewHeight, (width - 8) * aspect + 8)
            return min(desired, maximum)
        }
        func avoidsControls(_ frame: CGRect) -> Bool {
            guard let controls else { return true }
            return !frame.intersects(controls.insetBy(dx: -4, dy: -4))
        }

        // Keep the original side placement when possible. A narrower side
        // preview still leaves the selection entirely unobstructed.
        let ceiling = visible.maxY - 20
        let bottom = max(visible.minY + 4,
                         min(selection.minY - 1.25, ceiling - minimumPreviewHeight))
        let sideHeight = ceiling - bottom
        let sideSpaces: [(width: CGFloat, x: CGFloat)] = [
            (min(previewWidth, visible.maxX - selection.maxX - previewGap * 2),
             selection.maxX + previewGap),
            (min(previewWidth, selection.minX - visible.minX - previewGap * 2),
             selection.minX - previewGap)
        ]
        for side in sideSpaces.sorted(by: { $0.width > $1.width })
        where side.width >= minimumPreviewWidth {
            let x = side.x > selection.maxX
                ? side.x : side.x - side.width
            let frame = CGRect(x: x, y: bottom, width: side.width,
                               height: height(for: side.width, maximum: sideHeight))
            if avoidsControls(frame) { return frame }
        }

        // A wide selection may leave no side column. Use the free band above
        // or below it, moving horizontally if the control bar occupies that band.
        let bandWidth = min(previewWidth, visible.width - 16)
        let bands: [(space: CGFloat, y: CGFloat, above: Bool)] = [
            (visible.maxY - 8 - selection.maxY - previewGap,
             selection.maxY + previewGap, true),
            (selection.minY - previewGap - (visible.minY + 8),
             selection.minY - previewGap, false)
        ]
        for band in bands.sorted(by: { $0.space > $1.space })
        where band.space >= minimumPreviewHeight {
            let bandHeight = height(for: bandWidth, maximum: band.space)
            let y = band.above ? band.y : band.y - bandHeight
            let centered = min(max(selection.midX - bandWidth / 2,
                                   visible.minX + 8), visible.maxX - bandWidth - 8)
            for x in [centered, visible.maxX - bandWidth - 8, visible.minX + 8] {
                let frame = CGRect(x: x, y: y, width: bandWidth, height: bandHeight)
                if avoidsControls(frame) { return frame }
            }
        }

        // A nearly full-screen selection has no external space. A compact
        // preview in a safe screen corner avoids the selection's central area
        // and the control bar, while remaining visible as the long image grows.
        let compactWidth = min(160, visible.width - 16)
        let compactMaximumHeight = min(320, max(minimumPreviewHeight,
                                                visible.height * 0.42))
        let compactHeight = height(for: compactWidth, maximum: compactMaximumHeight)
        let leftX = visible.minX + 8
        let rightX = visible.maxX - compactWidth - 8
        let bottomY = visible.minY + 8
        let topY = visible.maxY - compactHeight - 8
        let corners = [
            CGRect(x: rightX, y: topY, width: compactWidth, height: compactHeight),
            CGRect(x: rightX, y: bottomY, width: compactWidth, height: compactHeight),
            CGRect(x: leftX, y: topY, width: compactWidth, height: compactHeight),
            CGRect(x: leftX, y: bottomY, width: compactWidth, height: compactHeight)
        ]
        let centralSelection = selection.insetBy(dx: selection.width * 0.25,
                                                 dy: selection.height * 0.25)
        func area(_ rect: CGRect) -> CGFloat {
            rect.isNull ? 0 : max(0, rect.width) * max(0, rect.height)
        }
        func obstruction(_ frame: CGRect) -> CGFloat {
            let controlArea = controls.map {
                area(frame.intersection($0.insetBy(dx: -4, dy: -4)))
            } ?? 0
            return controlArea * 1_000
                + area(frame.intersection(centralSelection)) * 100
                + area(frame.intersection(selection))
        }
        return corners.min(by: { obstruction($0) < obstruction($1) })
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
