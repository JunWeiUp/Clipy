import AppKit
import CoreGraphics

/// Short-lived preview of a completed capture. The presenter retains only
/// reduced images and at most four cards, even during rapid consecutive shots.
@MainActor
final class NativeScreenshotThumbnailPresenter {
    struct Actions {
        var copy: () -> Void
        var save: () -> Void
        var pin: () -> Void
        var edit: () -> Void
    }

    static let shared = NativeScreenshotThumbnailPresenter()
    private var cards: [Card] = []
    private let maximumCards = 4
    private let maximumRetainedBytes = 128 * 1024 * 1024
    private init() {}

    func present(
        image: CGImage,
        actions: Actions,
        force: Bool = false,
        estimatedBytes: Int = 0
    ) {
        guard (force || PreferencesManager.shared.showFloatingThumbnail),
              let preview = makePreview(image) else { return }
        let card = Card(preview: preview, actions: actions,
                        retainedBytes: estimatedBytes) { [weak self] card in
            self?.remove(card)
        }
        if !PreferencesManager.shared.thumbnailStacking {
            for card in cards { card.close() }
            cards.removeAll()
        }
        cards.append(card)
        while cards.count > maximumCards
            || (cards.count > 1
                && cards.reduce(0, { $0 + $1.retainedBytes }) > maximumRetainedBytes) {
            cards.removeFirst().close()
        }
        reposition()
        card.show()
    }

    func dismissAll() {
        for card in cards { card.close() }
        cards.removeAll()
    }

    private func remove(_ card: Card) {
        cards.removeAll { $0 === card }
        card.close()
        reposition()
    }

    private func reposition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let corner = PreferencesManager.shared.thumbnailCorner
        let left = corner == "bottomLeft" || corner == "topLeft"
        let top = corner == "topLeft" || corner == "topRight"
        var offset: CGFloat = 18
        for card in cards.reversed() {
            let size = card.window.frame.size
            let x = left ? visible.minX + 18 : visible.maxX - size.width - 18
            let y = top ? visible.maxY - size.height - offset : visible.minY + offset
            card.window.setFrameOrigin(NSPoint(x: x, y: y))
            offset += size.height + 10
        }
    }

    private func makePreview(_ image: CGImage) -> NSImage? {
        let scale = min(2, max(0.5, PreferencesManager.shared.thumbnailScale))
        let targetWidth = max(1, Int(240 * scale))
        let targetHeight = max(1, Int(160 * scale))
        let ratio = min(CGFloat(targetWidth) / CGFloat(image.width),
                        CGFloat(targetHeight) / CGFloat(image.height), 1)
        let width = max(1, Int((CGFloat(image.width) * ratio).rounded()))
        let height = max(1, Int((CGFloat(image.height) * ratio).rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let canvas = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        canvas.interpolationQuality = .high
        canvas.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = canvas.makeImage() else { return nil }
        return NSImage(cgImage: small, size: NSSize(width: width, height: height))
    }

    @MainActor
    private final class Card: NSObject {
        let window: NSPanel
        let retainedBytes: Int
        private let actions: Actions
        private let onClose: (Card) -> Void
        private var expiry: DispatchWorkItem?
        private var isClosed = false

        init(preview: NSImage, actions: Actions,
             retainedBytes: Int, onClose: @escaping (Card) -> Void) {
            self.actions = actions
            self.onClose = onClose
            self.retainedBytes = max(0, retainedBytes)
            let width = max(180, preview.size.width + 24)
            let height = preview.size.height + 57
            window = NSPanel(
                contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            super.init()
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.hasShadow = true
            window.isOpaque = false
            window.backgroundColor = .clear

            let background = NSVisualEffectView(frame: CGRect(origin: .zero,
                                                               size: window.frame.size))
            background.material = .hudWindow
            background.state = .active
            background.wantsLayer = true
            background.layer?.cornerRadius = 12
            background.layer?.masksToBounds = true

            let imageView = NSImageView(frame: CGRect(
                x: 12, y: 45, width: preview.size.width, height: preview.size.height
            ))
            imageView.image = preview
            imageView.imageScaling = .scaleProportionallyUpOrDown
            background.addSubview(imageView)

            let symbols = ["doc.on.doc", "square.and.arrow.down", "pin", "pencil"]
            let tips = [
                NativeScreenshotUserText.string("复制", "Copy"),
                NativeScreenshotUserText.string("保存", "Save"),
                NativeScreenshotUserText.string("贴图", "Pin"),
                NativeScreenshotUserText.string("编辑", "Edit")
            ]
            let itemWidth = (width - 24) / CGFloat(symbols.count)
            for index in symbols.indices {
                let button = NSButton(
                    image: NSImage(systemSymbolName: symbols[index],
                                   accessibilityDescription: tips[index]) ?? NSImage(),
                    target: self,
                    action: #selector(performAction(_:))
                )
                button.tag = index
                button.isBordered = false
                button.toolTip = tips[index]
                button.frame = CGRect(x: 12 + CGFloat(index) * itemWidth,
                                      y: 8, width: itemWidth, height: 30)
                background.addSubview(button)
            }
            window.contentView = background
        }

        func show() {
            window.orderFrontRegardless()
            let task = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.onClose(self)
            }
            expiry = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: task)
        }

        func close() {
            guard !isClosed else { return }
            isClosed = true
            expiry?.cancel()
            expiry = nil
            window.orderOut(nil)
            window.contentView = nil
        }

        @objc private func performAction(_ sender: NSButton) {
            switch sender.tag {
            case 0: actions.copy()
            case 1: actions.save()
            case 2: actions.pin()
            default: actions.edit()
            }
            onClose(self)
        }
    }
}
