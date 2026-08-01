import AppKit
import CoreGraphics

enum ScrollingImageStitcher {
    struct StitchResult {
        let image: NSImage
        let addedHeight: CGFloat
        let duplicate: Bool
        let reachedLimit: Bool
        let weakMatch: Bool
    }

    private static let minStripHeight = 32
    private static let preferredStripHeight = 72
    /// Reject matches below this NCC score (avoid false joins that duplicate content).
    private static let minAcceptScore = 0.55
    /// Near-identical frames (almost no scroll).
    private static let duplicateScore = 0.97
    private static let minAppendPixels = 4

    /// Append `incoming` below `base` for a downward scroll.
    /// Matches the **visual bottom** strip of `base` inside the **upper portion** of `incoming`.
    static func append(
        base: NSImage,
        incoming: NSImage,
        maxPixelHeight: CGFloat = ScreenshotChrome.scrollingMaxPixelHeight
    ) -> StitchResult? {
        guard let baseCG = ScreenshotImageProcessor.bestCGImage(from: base),
              let incomingCG = ScreenshotImageProcessor.bestCGImage(from: incoming) else {
            return nil
        }

        let width = min(baseCG.width, incomingCG.width)
        let baseH = baseCG.height
        let incomingH = incomingCG.height
        guard width > 16, baseH > 16, incomingH > 16 else { return nil }

        let stripHeight = min(preferredStripHeight, max(minStripHeight, min(baseH, incomingH) / 5))
        guard stripHeight > 8 else { return nil }

        // Work in top-left row order for matching clarity.
        let baseGray = grayscaleTopLeft(baseCG, width: width, height: baseH)
        let incomingGray = grayscaleTopLeft(incomingCG, width: width, height: incomingH)
        guard baseGray.count == width * baseH, incomingGray.count == width * incomingH else {
            return nil
        }

        // Template = visual bottom strip of the accumulated image.
        let templateRow = baseH - stripHeight
        // Search only the upper ~80% of the new frame (where the old bottom should land after scrolling down).
        let maxSearchRow = max(0, Int(Double(incomingH) * 0.82) - stripHeight)

        let match = bestMatchNCC(
            template: baseGray,
            templateRow: templateRow,
            templateHeight: stripHeight,
            width: width,
            search: incomingGray,
            searchHeight: incomingH,
            maxStartRow: maxSearchRow
        )

        // Little or no scroll: bottom of base still sits near the bottom of incoming.
        let nearBottom = match.row >= incomingH - stripHeight - max(8, stripHeight / 4)
        if match.score >= duplicateScore && nearBottom {
            return StitchResult(image: base, addedHeight: 0, duplicate: true, reachedLimit: false, weakMatch: false)
        }

        // Also treat as duplicate when almost the entire frame overlaps.
        let overlap = match.row + stripHeight
        let appendHeight = incomingH - overlap
        if appendHeight < minAppendPixels {
            return StitchResult(image: base, addedHeight: 0, duplicate: true, reachedLimit: false, weakMatch: false)
        }

        // Weak match → skip this frame rather than invent a bad seam.
        if match.score < minAcceptScore {
            return StitchResult(image: base, addedHeight: 0, duplicate: false, reachedLimit: false, weakMatch: true)
        }

        // Sanity: after a real scroll, overlap should be meaningful but not tiny.
        // If we "matched" near the very top with a mediocre score, prefer skip.
        if match.row < stripHeight / 3 && match.score < 0.72 {
            return StitchResult(image: base, addedHeight: 0, duplicate: false, reachedLimit: false, weakMatch: true)
        }

        let newHeight = baseH + appendHeight
        if CGFloat(newHeight) > maxPixelHeight {
            return StitchResult(image: base, addedHeight: 0, duplicate: false, reachedLimit: true, weakMatch: false)
        }

        guard let composed = compose(
            base: baseCG,
            incoming: incomingCG,
            width: width,
            baseHeight: baseH,
            appendHeight: appendHeight
        ) else {
            return nil
        }

        let logicalHeight = base.size.height
            + (base.size.height / max(CGFloat(baseH), 1)) * CGFloat(appendHeight)
        let logicalSize = NSSize(width: base.size.width, height: logicalHeight)
        let image = ScreenshotImageProcessor.wrapWithBitmapRep(composed, logicalSize: logicalSize)
        return StitchResult(
            image: image,
            addedHeight: CGFloat(appendHeight),
            duplicate: false,
            reachedLimit: false,
            weakMatch: false
        )
    }

    /// Draw base on top, then the non-overlapping bottom of incoming underneath.
    /// `CGImage.cropping` uses bottom-left origin: visual bottom == y = 0.
    private static func compose(
        base: CGImage,
        incoming: CGImage,
        width: Int,
        baseHeight: Int,
        appendHeight: Int
    ) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: baseHeight + appendHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        // Canvas BL origin: base sits above the new strip.
        context.draw(base, in: CGRect(x: 0, y: appendHeight, width: width, height: baseHeight))
        // Visual bottom `appendHeight` rows of incoming == BL crop at y = 0.
        if let crop = incoming.cropping(to: CGRect(x: 0, y: 0, width: width, height: appendHeight)) {
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: appendHeight))
        }
        return context.makeImage()
    }

    /// Normalized cross-correlation of the template strip against each candidate start row.
    /// Uses the center 78% of width to reduce scrollbar / edge chrome noise.
    private static func bestMatchNCC(
        template: [UInt8],
        templateRow: Int,
        templateHeight: Int,
        width: Int,
        search: [UInt8],
        searchHeight: Int,
        maxStartRow: Int
    ) -> (row: Int, score: Double) {
        let x0 = max(0, Int(Double(width) * 0.11))
        let x1 = min(width, Int(Double(width) * 0.89))
        let usableWidth = max(8, x1 - x0)
        let stepX = max(1, usableWidth / 120)
        let stepY = max(1, templateHeight / 36)

        // Precompute template mean/variance over sampled pixels.
        var tSum = 0.0
        var tCount = 0.0
        var ty = 0
        while ty < templateHeight {
            let row = templateRow + ty
            var x = x0
            while x < x1 {
                tSum += Double(template[row * width + x])
                tCount += 1
                x += stepX
            }
            ty += stepY
        }
        guard tCount > 8 else { return (0, 0) }
        let tMean = tSum / tCount

        var tVar = 0.0
        ty = 0
        while ty < templateHeight {
            let row = templateRow + ty
            var x = x0
            while x < x1 {
                let d = Double(template[row * width + x]) - tMean
                tVar += d * d
                x += stepX
            }
            ty += stepY
        }
        // Flat / low-contrast strip (solid color sidebar chunk) → unreliable.
        if tVar < 80 * tCount {
            return (0, 0)
        }
        let tStd = sqrt(tVar)

        var bestRow = 0
        var bestScore = -1.0
        let limit = max(0, min(maxStartRow, searchHeight - templateHeight))

        // Coarse search then refine ±2 around peak.
        let coarseStep = 2
        var coarseBestRow = 0
        var coarseBest = -1.0

        for start in stride(from: 0, through: limit, by: coarseStep) {
            let score = nccScore(
                template: template,
                templateRow: templateRow,
                templateHeight: templateHeight,
                width: width,
                search: search,
                startRow: start,
                x0: x0,
                x1: x1,
                stepX: stepX,
                stepY: stepY,
                tMean: tMean,
                tStd: tStd
            )
            if score > coarseBest {
                coarseBest = score
                coarseBestRow = start
            }
        }

        let refineLo = max(0, coarseBestRow - coarseStep)
        let refineHi = min(limit, coarseBestRow + coarseStep)
        for start in refineLo...refineHi {
            let score = nccScore(
                template: template,
                templateRow: templateRow,
                templateHeight: templateHeight,
                width: width,
                search: search,
                startRow: start,
                x0: x0,
                x1: x1,
                stepX: max(1, stepX / 2),
                stepY: max(1, stepY / 2),
                tMean: tMean,
                tStd: tStd
            )
            if score > bestScore {
                bestScore = score
                bestRow = start
            }
        }

        return (bestRow, bestScore)
    }

    private static func nccScore(
        template: [UInt8],
        templateRow: Int,
        templateHeight: Int,
        width: Int,
        search: [UInt8],
        startRow: Int,
        x0: Int,
        x1: Int,
        stepX: Int,
        stepY: Int,
        tMean: Double,
        tStd: Double
    ) -> Double {
        var sSum = 0.0
        var count = 0.0
        var ty = 0
        while ty < templateHeight {
            let sRow = startRow + ty
            var x = x0
            while x < x1 {
                sSum += Double(search[sRow * width + x])
                count += 1
                x += stepX
            }
            ty += stepY
        }
        guard count > 8 else { return -1 }
        let sMean = sSum / count

        var sVar = 0.0
        var cross = 0.0
        ty = 0
        while ty < templateHeight {
            let tRow = templateRow + ty
            let sRow = startRow + ty
            var x = x0
            while x < x1 {
                let tv = Double(template[tRow * width + x]) - tMean
                let sv = Double(search[sRow * width + x]) - sMean
                cross += tv * sv
                sVar += sv * sv
                x += stepX
            }
            ty += stepY
        }
        if sVar < 80 * count { return -1 }
        let denom = tStd * sqrt(sVar)
        guard denom > 1e-6 else { return -1 }
        return cross / denom
    }

    /// Grayscale bytes with row 0 = visual top of the image.
    private static func grayscaleTopLeft(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return []
        }
        // Flip so row 0 in our buffer is the visual top.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var gray = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let o = i * 4
            let r = Int(pixels[o])
            let g = Int(pixels[o + 1])
            let b = Int(pixels[o + 2])
            gray[i] = UInt8((r * 30 + g * 59 + b * 11) / 100)
        }
        return gray
    }
}
