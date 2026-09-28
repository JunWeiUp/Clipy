import AppKit
import ScreenCaptureKit

/// Screen Recording is optional. Capture only explicitly matched menu-item windows,
/// never a screen rectangle that might now contain another application's content.
final class MenuBarOverflowImages {
    private var busy = false

    func load(_ items: [MenuBarOverflowItem], cancellation: MenuBarOverflowCancellation,
              completion: @escaping ([MenuBarOverflowIdentity: NSImage]) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !busy, !cancellation.isCancelled, !items.isEmpty, CGPreflightScreenCaptureAccess() else { completion([:]); return }
        guard #available(macOS 14.0, *) else { completion([:]); return }
        busy = true
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { [weak self] content, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let content, !cancellation.isCancelled else { self.busy = false; completion([:]); return }
                let pairs = items.prefix(12).compactMap { item -> (MenuBarOverflowIdentity, SCWindow)? in
                    guard let id = item.id.windowID,
                          let window = content.windows.first(where: { $0.windowID == id }),
                          window.frame.width > 0, window.frame.width <= 512,
                          window.frame.height > 0, window.frame.height <= 64,
                          abs(window.frame.midX - item.frame.midX) <= 4,
                          abs(window.frame.midY - item.frame.midY) <= 4 else { return nil }
                    return (item.id, window)
                }
                self.capture(pairs, results: [:], cancellation: cancellation, completion: completion)
            }
        }
    }

    @available(macOS 14.0, *)
    private func capture(_ remaining: [(MenuBarOverflowIdentity, SCWindow)],
                         results: [MenuBarOverflowIdentity: NSImage],
                         cancellation: MenuBarOverflowCancellation,
                         completion: @escaping ([MenuBarOverflowIdentity: NSImage]) -> Void) {
        guard let pair = remaining.first, !cancellation.isCancelled, CGPreflightScreenCaptureAccess() else {
            busy = false; completion(results); return
        }
        let config = SCStreamConfiguration()
        config.width = min(512, max(1, Int(pair.1.frame.width * 2)))
        config.height = min(128, max(1, Int(pair.1.frame.height * 2)))
        config.showsCursor = false
        SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: pair.1), configuration: config) { [weak self] cgImage, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                var updated = results
                if let cgImage, Self.hasVisiblePixels(cgImage) {
                    updated[pair.0] = NSImage(cgImage: cgImage, size: pair.1.frame.size)
                }
                self.capture(Array(remaining.dropFirst()), results: updated, cancellation: cancellation, completion: completion)
            }
        }
    }

    /// Blank/transparent off-screen captures must not replace a recognizable app icon.
    static func hasVisiblePixels(_ image: CGImage) -> Bool {
        var bytes = [UInt8](repeating: 0, count: 16 * 16 * 4)
        let drew = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 16, height: 16, bitsPerComponent: 8,
                                          bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
            return true
        }
        guard drew, stride(from: 3, to: bytes.count, by: 4).contains(where: { bytes[$0] > 16 }) else { return false }
        // An opaque but solid background is also a failed icon preview.
        return (0..<4).contains { channel in
            let values = stride(from: channel, to: bytes.count, by: 4).map { Int(bytes[$0]) }
            return (values.max() ?? 0) - (values.min() ?? 0) > 12
        }
    }
}
