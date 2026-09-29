import AppKit
import CoreGraphics

/// Joins repeated captures of one fixed screen region. A frame is accepted
/// only when its overlap has a distinctive match; a doubtful frame leaves the
/// existing result untouched so the caller can slow down and try again.
final class NativeScreenshotScrollAssembler {
    enum AppendResult: Equatable {
        case appended(pixelRows: Int)
        case noMovement
        case uncertainOverlap
        case heightLimit
    }

    enum AssemblyError: Error {
        case mismatchedFrameSize
        case invalidFrame
        case renderingFailed
    }

    private let width: Int
    private let frameHeight: Int
    private let maximumHeight: Int
    private let maximumPixels: Int
    private let detectFrozenEdges: Bool
    private var segments: [CGImage]
    private var lastFrame: CGImage
    private var contentHeight: Int
    private var footerHeight = 0
    private var hasAppended = false

    init(
        firstFrame: CGImage,
        maximumHeight: Int,
        maximumPixels: Int = 100_000_000,
        detectFrozenEdges: Bool = true
    ) throws {
        guard firstFrame.width > 0, firstFrame.height > 0,
              maximumHeight >= firstFrame.height,
              maximumPixels / firstFrame.width >= firstFrame.height else {
            throw AssemblyError.invalidFrame
        }
        width = firstFrame.width
        frameHeight = firstFrame.height
        self.maximumHeight = maximumHeight
        self.maximumPixels = maximumPixels
        self.detectFrozenEdges = detectFrozenEdges
        segments = [firstFrame]
        lastFrame = firstFrame
        contentHeight = firstFrame.height
    }

    var outputHeight: Int { contentHeight + footerHeight }

    func append(_ frame: CGImage) throws -> AppendResult {
        guard frame.width == width, frame.height == frameHeight else {
            throw AssemblyError.mismatchedFrameSize
        }
        let oldSample = try Sample(frame: lastFrame)
        let newSample = try Sample(frame: frame)
        let frozenTop = detectFrozenEdges
            ? frozenEdgeHeight(oldSample, newSample, fromTop: true) : 0
        let frozenBottom = detectFrozenEdges
            ? frozenEdgeHeight(oldSample, newSample, fromTop: false) : 0
        let contentEnd = frameHeight - frozenBottom
        let activeHeight = contentEnd - frozenTop
        guard activeHeight >= 96 else { return .uncertainOverlap }

        if meanDifference(oldSample, newSample, oldStart: frozenTop,
                          newStart: frozenTop, count: activeHeight) < 2.0 {
            return .noMovement
        }

        let minimumOverlap = max(48, activeHeight / 8)
        let maximumShift = min(activeHeight - minimumOverlap, Int(Double(activeHeight) * 0.88))
        guard maximumShift >= 1 else { return .uncertainOverlap }

        var candidates: [(shift: Int, error: Double)] = []
        for shift in 1...maximumShift {
            let overlap = activeHeight - shift
            let error = meanDifference(
                oldSample, newSample,
                oldStart: frozenTop + shift,
                newStart: frozenTop,
                count: overlap,
                rowStride: max(2, overlap / 36),
                columnStride: 4
            )
            candidates.append((shift, error))
        }
        candidates.sort { $0.error < $1.error }
        let finalists = candidates.prefix(6).map { candidate in
            (
                shift: candidate.shift,
                error: meanDifference(
                    oldSample, newSample,
                    oldStart: frozenTop + candidate.shift,
                    newStart: frozenTop,
                    count: activeHeight - candidate.shift,
                    rowStride: 2,
                    columnStride: 1
                )
            )
        }.sorted { $0.error < $1.error }
        guard let best = finalists.first, best.error < 20 else {
            return .uncertainOverlap
        }
        // Repeated rows can give many plausible offsets. Require the winning
        // displacement to be meaningfully better than another distant offset.
        let competing = finalists.dropFirst().first {
            abs($0.shift - best.shift) > 3
        }
        if let competing, competing.error < max(best.error + 2.5, best.error * 1.18) {
            return .uncertainOverlap
        }

        let nextContentHeight = contentHeight - (hasAppended ? 0 : frozenBottom) + best.shift
        let nextOutputHeight = nextContentHeight + frozenBottom
        guard nextOutputHeight <= maximumHeight,
              nextOutputHeight <= maximumPixels / width else {
            return .heightLimit
        }

        if !hasAppended {
            // Retain the initial frozen header exactly once and postpone the
            // footer until the final frame, where it is most up to date.
            if frozenBottom > 0 {
                let cropped = try compactSlice(
                    of: lastFrame,
                    rect: CGRect(x: 0, y: 0, width: width,
                                 height: frameHeight - frozenBottom)
                )
                segments = [cropped]
                contentHeight = cropped.height
            }
            hasAppended = true
        }
        let newRows = CGRect(
            x: 0,
            y: contentEnd - best.shift,
            width: width,
            height: best.shift
        )
        let slice = try compactSlice(of: frame, rect: newRows)
        segments.append(slice)
        contentHeight += slice.height
        footerHeight = frozenBottom
        lastFrame = frame
        return .appended(pixelRows: best.shift)
    }

    /// A frozen set of compact slices. No capture task mutates it, so final
    /// rendering can run on a worker without retaining full source frames.
    struct RenderPlan: @unchecked Sendable {
        let width: Int
        let height: Int
        let slices: [CGImage]

        func render(maximumWidth: Int? = nil) throws -> CGImage {
            let scale = maximumWidth.map { min(1, CGFloat($0) / CGFloat(width)) } ?? 1
            let renderedWidth = max(1, Int((CGFloat(width) * scale).rounded()))
            let renderedHeight = max(1, Int((CGFloat(height) * scale).rounded()))
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let canvas = CGContext(
                    data: nil, width: renderedWidth, height: renderedHeight,
                    bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { throw AssemblyError.renderingFailed }
            canvas.interpolationQuality = scale < 1 ? .medium : .none
            var top = 0
            for slice in slices {
                canvas.draw(slice, in: CGRect(
                    x: 0,
                    y: CGFloat(height - top - slice.height) * scale,
                    width: CGFloat(width) * scale,
                    height: CGFloat(slice.height) * scale
                ))
                top += slice.height
            }
            guard let image = canvas.makeImage() else {
                throw AssemblyError.renderingFailed
            }
            return image
        }
    }

    func renderPlan() throws -> RenderPlan {
        var slices = segments
        if footerHeight > 0 {
            slices.append(try compactSlice(
                of: lastFrame,
                rect: CGRect(x: 0, y: frameHeight - footerHeight,
                             width: width, height: footerHeight)
            ))
        }
        return RenderPlan(width: width, height: outputHeight, slices: slices)
    }

    func render(maximumWidth: Int? = nil) throws -> CGImage {
        try renderPlan().render(maximumWidth: maximumWidth)
    }

    private struct Sample {
        let bytes: [UInt8]
        let width = 48
        let height: Int

        init(frame: CGImage) throws {
            let sampleWidth = 48
            let sampleHeight = frame.height
            var data = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
                throw AssemblyError.renderingFailed
            }
            let drawn = data.withUnsafeMutableBytes { rawBytes -> Bool in
                guard let canvas = CGContext(
                    data: rawBytes.baseAddress,
                    width: sampleWidth,
                    height: sampleHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: sampleWidth * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                canvas.interpolationQuality = .medium
                canvas.draw(frame, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
                return true
            }
            guard drawn else { throw AssemblyError.renderingFailed }
            height = sampleHeight
            bytes = data
        }

        func luma(row: Int, column: Int) -> Int {
            // Bitmap data is top-to-bottom on macOS for a newly created
            // context. Both frames use the same orientation for comparison.
            let offset = (row * width + column) * 4
            return (Int(bytes[offset]) * 54
                  + Int(bytes[offset + 1]) * 183
                  + Int(bytes[offset + 2]) * 19) / 256
        }
    }

    private func frozenEdgeHeight(_ a: Sample, _ b: Sample, fromTop: Bool) -> Int {
        let maximum = frameHeight / 5
        guard maximum > 0 else { return 0 }
        var stable = 0
        for index in 0..<maximum {
            let row = fromTop ? index : frameHeight - 1 - index
            let difference = meanDifference(a, b, oldStart: row, newStart: row,
                                            count: 1, columnStride: 2)
            if difference > 2.5 { break }
            stable += 1
        }
        return stable >= 6 ? stable : 0
    }

    private func meanDifference(
        _ a: Sample, _ b: Sample,
        oldStart: Int, newStart: Int, count: Int,
        rowStride: Int = 3, columnStride: Int = 2
    ) -> Double {
        guard count > 0 else { return .infinity }
        var total = 0
        var compared = 0
        for row in stride(from: 0, to: count, by: rowStride) {
            for column in stride(from: 0, to: a.width, by: columnStride) {
                total += abs(a.luma(row: oldStart + row, column: column)
                           - b.luma(row: newStart + row, column: column))
                compared += 1
            }
        }
        return Double(total) / Double(max(1, compared))
    }

    /// `CGImage.cropping(to:)` may retain the entire source pixel buffer.
    /// Copy the accepted rows into their own bitmap before dropping the frame.
    private func compactSlice(of image: CGImage, rect: CGRect) throws -> CGImage {
        guard let cropped = image.cropping(to: rect),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let canvas = CGContext(
                data: nil,
                width: cropped.width,
                height: cropped.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw AssemblyError.renderingFailed }
        canvas.draw(cropped, in: CGRect(x: 0, y: 0,
                                       width: cropped.width,
                                       height: cropped.height))
        guard let result = canvas.makeImage() else { throw AssemblyError.renderingFailed }
        return result
    }
}
