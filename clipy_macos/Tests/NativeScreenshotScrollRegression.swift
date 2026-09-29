import AppKit
import CoreGraphics

private func makeNativeScrollFixture(offset: Int, width: Int = 100) -> CGImage {
    let height = 200
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    for row in 0..<height {
        let source = row < 10 ? 5 : (row >= 190 ? 11 : row - 10 + 100 + offset)
        let value = CGFloat((source * 73 + source * source * 29) % 256) / 255
        context.setFillColor(CGColor(
            srgbRed: value,
            green: 1 - value,
            blue: value / 2,
            alpha: 1
        ))
        context.fill(CGRect(x: 0, y: row, width: width, height: 1))
    }
    return context.makeImage()!
}

func runNativeScreenshotScrollRegressionTests() {
    do {
        let first = makeNativeScrollFixture(offset: 0)
        let assembler = try NativeScreenshotScrollAssembler(
            firstFrame: first,
            maximumHeight: 1000
        )
        let still = try assembler.append(first)
        precondition(still == .noMovement,
                     "static scroll frame changed the result")
        let firstShift = try assembler.append(makeNativeScrollFixture(offset: -40))
        precondition(firstShift == .appended(pixelRows: 40),
                     "first scroll offset was not found")
        let secondShift = try assembler.append(makeNativeScrollFixture(offset: -80))
        precondition(secondShift == .appended(pixelRows: 40),
                     "second scroll offset was not found")
        let result = try assembler.render()
        precondition(result.width == 100 && result.height == 280,
                     "stitched output has incorrect dimensions")
        let preview = try assembler.render(maximumWidth: 50)
        precondition(preview.width == 50 && preview.height == 140,
                     "preview did not maintain aspect ratio")

        let limited = try NativeScreenshotScrollAssembler(
            firstFrame: first, maximumHeight: 220
        )
        let limitResult = try limited.append(makeNativeScrollFixture(offset: -40))
        precondition(limitResult == .heightLimit, "height limit was bypassed")
        do {
            _ = try assembler.append(makeNativeScrollFixture(offset: -120, width: 101))
            preconditionFailure("mismatched frame dimensions were accepted")
        } catch NativeScreenshotScrollAssembler.AssemblyError.mismatchedFrameSize {
            // Expected.
        }
        print("Native screenshot scroll regressions passed.")
    } catch {
        preconditionFailure("Native screenshot scroll regression failed: \(error)")
    }
}
