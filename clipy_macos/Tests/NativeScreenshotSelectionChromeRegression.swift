import AppKit
import CoreGraphics

@main
enum NativeScreenshotSelectionChromeRegression {
    private static let red = NSColor(deviceRed: 0.95, green: 0.06, blue: 0.06, alpha: 1)

    static func main() {
        typealias Chrome = NativeScreenshotSelectionChrome
        let selecting = Chrome.style(for: .selecting, accent: red)
        let selected = Chrome.style(for: .selected, accent: red)
        let hover = Chrome.style(for: .hoveringWindow, accent: red)
        let scroll = Chrome.style(for: .scrolling, accent: red)
        let recording = Chrome.style(for: .recording, accent: red)

        precondition(selecting.lineWidth == 2 && selecting.cornerRadius == 0
                     && !selecting.showsHandles && selecting.fill == nil)
        precondition(selected.lineWidth == 2 && selected.cornerRadius == 0
                     && selected.handleDiameter == 10 && selected.fill == nil)
        precondition(hover.lineWidth == 2 && hover.cornerRadius == 4
                     && hover.fill != nil && !hover.showsHandles)
        precondition(scroll.lineWidth == 2.5 && !scroll.showsHandles
                     && scroll.cornerRadius == 0)
        precondition(recording.lineWidth == 1.5 && recording.strokeOutside
                     && !recording.showsHandles)
        precondition(Chrome.style(for: .idle, accent: red).lineWidth == 0)

        for scale in [1, 2] {
            let draggingPixels = render(style: selecting, scale: scale)
            let selectedPixels = render(style: selected, scale: scale)
            let hoverPixels = render(style: hover, scale: scale)
            let scrollPixels = render(style: scroll, scale: scale)
            let redInDragging = countColor(draggingPixels, red: true)
            let redInSelected = countColor(selectedPixels, red: true)
            precondition(redInSelected > redInDragging + 80 * scale * scale,
                         "committed selection lost its eight solid accent handles")
            precondition(countWhite(selectedPixels) == 0,
                         "committed selection handles gained a white outline")
            precondition(countColor(hoverPixels, red: false) > 0,
                         "window hover lost its blue frame/fill")
            precondition(countColor(scrollPixels, red: true) > 0,
                         "scroll capture lost its red frame")
            let recordingPixels = render(style: recording, scale: scale)
            precondition(countColor(recordingPixels, red: true) > 0,
                         "recording lost its accent frame")
            precondition(pixel(recordingPixels, x: 21 * scale, y: 21 * scale,
                               width: 100 * scale) == [0, 0, 0],
                         "recording border painted inside the captured region")
        }
        print("NativeScreenshotSelectionChromeRegression passed")
    }

    private static func render(style: NativeScreenshotSelectionChrome.Style,
                               scale: Int) -> [UInt8] {
        let width = 100 * scale
        let height = 80 * scale
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                            | CGBitmapInfo.byteOrder32Big.rawValue) else {
                preconditionFailure("could not create offscreen chrome context")
            }
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
            NativeScreenshotSelectionChrome.draw(
                in: context, rect: CGRect(x: 20, y: 20, width: 60, height: 40), style: style)
        }
        return pixels
    }

    private static func countColor(_ pixels: [UInt8], red: Bool) -> Int {
        stride(from: 0, to: pixels.count, by: 4).reduce(0) { count, offset in
            let r = Int(pixels[offset])
            let g = Int(pixels[offset + 1])
            let b = Int(pixels[offset + 2])
            return count + (red ? (r > 150 && r > g * 2 && r > b * 2 ? 1 : 0)
                                : (b > 90 && b > r * 2 ? 1 : 0))
        }
    }

    private static func countWhite(_ pixels: [UInt8]) -> Int {
        stride(from: 0, to: pixels.count, by: 4).reduce(0) { count, offset in
            let r = Int(pixels[offset])
            let g = Int(pixels[offset + 1])
            let b = Int(pixels[offset + 2])
            return count + (r > 190 && g > 190 && b > 190 ? 1 : 0)
        }
    }

    private static func pixel(_ pixels: [UInt8], x: Int, y: Int, width: Int) -> [UInt8] {
        let offset = (y * width + x) * 4
        return Array(pixels[offset..<(offset + 3)])
    }
}
