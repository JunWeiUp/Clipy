import AppKit
import Combine

/// NSImage.size alone does not release its full-resolution representations.
/// Render a single bounded bitmap instead; callers account for width×height×4.
enum UIIconRasterizer {
    static func rasterize(_ image: NSImage, pointSize: CGFloat, scale: CGFloat) -> NSImage? {
        let pixels = max(1, Int(ceil(pointSize * scale)))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                          isPlanar: false, colorSpaceName: .deviceRGB,
                                          bytesPerRow: pixels * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                   from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = NSSize(width: pointSize, height: pointSize)
        let output = NSImage(size: bitmap.size)
        output.addRepresentation(bitmap)
        return output
    }
}

struct HistoryRowThumbnailKey: Hashable {
    let path: String
    let width: CGFloat
    let height: CGFloat
    var size: NSSize { NSSize(width: width, height: height) }
}

/// Visible rows subscribe on main. At most two disk decodes and 128 pending keys;
/// duplicate path+size requests share a decode. No process-lifetime bitmap cache.
final class HistoryRowThumbnailLoader {
    static let shared = HistoryRowThumbnailLoader()
    struct Subscription {
        let key: HistoryRowThumbnailKey
        let id: UUID
    }
    private var policy = UIKeyedWorkPolicy<HistoryRowThumbnailKey>(concurrency: 2, pendingLimit: 128)
    private var callbacks: [HistoryRowThumbnailKey: [UUID: (NSImage?) -> Void]] = [:]
    private let decode: (HistoryRowThumbnailKey) -> NSImage?
    private let queue = DispatchQueue(label: "clipy.history-row-thumbnails", qos: .utility, attributes: .concurrent)

    init(decode: @escaping (HistoryRowThumbnailKey) -> NSImage? = {
        HistoryThumbnailCache.thumbnail(for: $0.path, size: $0.size)
    }) { self.decode = decode }

    @discardableResult
    func request(_ key: HistoryRowThumbnailKey, completion: @escaping (NSImage?) -> Void) -> Subscription? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard callbacks.values.reduce(0, { $0 + $1.count }) < 256, policy.request(key) else { return nil }
        let subscription = Subscription(key: key, id: UUID())
        callbacks[key, default: [:]][subscription.id] = completion
        pump()
        return subscription
    }

    func cancel(_ subscription: Subscription) {
        dispatchPrecondition(condition: .onQueue(.main))
        callbacks[subscription.key]?.removeValue(forKey: subscription.id)
        if callbacks[subscription.key]?.isEmpty == true {
            callbacks.removeValue(forKey: subscription.key)
            policy.cancelPending(subscription.key)
        }
    }

    private func pump() {
        while let key = policy.takeNext() {
            queue.async { [weak self, decode] in
                let image = autoreleasepool { decode(key) }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.policy.finish(key)
                    let listeners = self.callbacks.removeValue(forKey: key)
                    listeners?.values.forEach { $0(image) }
                    self.pump()
                }
            }
        }
    }
}

/// Path/size and visibility generation are checked even if a worker ignores
/// cancellation. Clearing a row never permits a late image to refill its State.
final class HistoryRowThumbnailState: ObservableObject {
    @Published private(set) var image: NSImage?
    private let loader: HistoryRowThumbnailLoader
    private var subscription: HistoryRowThumbnailLoader.Subscription?
    private var generation: UInt64 = 0
    private var visible = false
    private var key: HistoryRowThumbnailKey?

    init(loader: HistoryRowThumbnailLoader = .shared) { self.loader = loader }
    func show(_ key: HistoryRowThumbnailKey) { visible = true; load(key) }
    func update(_ key: HistoryRowThumbnailKey) { if visible { load(key) } }
    func hide() {
        visible = false
        generation &+= 1
        if let subscription { loader.cancel(subscription) }
        subscription = nil
        key = nil
        image = nil
    }
    private func load(_ key: HistoryRowThumbnailKey) {
        if self.key == key, subscription != nil || image != nil { return }
        if let subscription { loader.cancel(subscription) }
        generation &+= 1
        let capturedGeneration = generation
        self.key = key
        image = nil
        subscription = loader.request(key) { [weak self] image in
            guard let self, self.visible, self.key == key, self.generation == capturedGeneration else { return }
            self.subscription = nil
            self.image = image
        }
    }
    deinit {
        if let subscription {
            let loader = loader
            DispatchQueue.main.async { loader.cancel(subscription) }
        }
    }
}
