import AppKit
import SwiftUI

/// Hosts explicit, on-device recognition and the redaction review sheet.
@MainActor
final class NativeScreenshotRecognitionWindowController: NSObject, NSWindowDelegate {
    private static var active: [UUID: NativeScreenshotRecognitionWindowController] = [:]
    private let id = UUID()
    private let window: NSWindow

    static func open(
        image: CGImage,
        language: ScreenshotOCRLanguage,
        onRedactedImage: @escaping (CGImage) -> Void
    ) {
        let controller = NativeScreenshotRecognitionWindowController(
            image: image, language: language, onRedactedImage: onRedactedImage
        )
        active[controller.id] = controller
        controller.show()
    }

    private init(
        image: CGImage,
        language: ScreenshotOCRLanguage,
        onRedactedImage: @escaping (CGImage) -> Void
    ) {
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 680, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        let panel = NativeScreenshotRecognitionPanel(
            image: image,
            language: language,
            mappedBy: { chosen in
                switch chosen {
                case .english: return .english
                case .chineseEnglish: return .chineseAndEnglish
                case .auto: return .automatic
                }
            },
            onRedactedImage: { [weak self] output in
                onRedactedImage(output)
                self?.window.close()
            }
        )
        window.contentView = NSHostingView(rootView: panel)
        window.title = NativeScreenshotUserText.string("截图识别", "Screenshot Recognition")
        window.minSize = NSSize(width: 540, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
    }

    private func show() {
        NativeScreenshotWindowActivation.opened(id)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window.contentView = nil
        Self.active.removeValue(forKey: id)
        NativeScreenshotWindowActivation.closed(id)
    }
}
