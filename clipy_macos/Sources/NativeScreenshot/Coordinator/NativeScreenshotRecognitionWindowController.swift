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
        initialIntent: NativeScreenshotRecognitionIntent = .none,
        onRedactedImage: @escaping (CGImage) -> Void,
        onCopyOriginal: (() -> Void)? = nil,
        onSaveOriginal: (() -> Void)? = nil,
        onContinueEditing: (() -> Void)? = nil
    ) {
        let controller = NativeScreenshotRecognitionWindowController(
            image: image, language: language, initialIntent: initialIntent,
            onRedactedImage: onRedactedImage,
            onCopyOriginal: onCopyOriginal,
            onSaveOriginal: onSaveOriginal,
            onContinueEditing: onContinueEditing
        )
        active[controller.id] = controller
        controller.show()
    }

    private init(
        image: CGImage,
        language: ScreenshotOCRLanguage,
        initialIntent: NativeScreenshotRecognitionIntent,
        onRedactedImage: @escaping (CGImage) -> Void,
        onCopyOriginal: (() -> Void)?,
        onSaveOriginal: (() -> Void)?,
        onContinueEditing: (() -> Void)?
    ) {
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 720, height: 460),
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
            initialIntent: initialIntent,
            onRedactedImage: { [weak self] output in
                onRedactedImage(output)
                self?.window.close()
            },
            onCopyOriginal: { [weak self] in
                if let onCopyOriginal { onCopyOriginal() }
                else { self?.copyOriginal(image) }
            },
            onSaveOriginal: { [weak self] in
                if let onSaveOriginal { onSaveOriginal() }
                else { self?.saveOriginal(image) }
            },
            onContinueEditing: { [weak self] in
                self?.window.close()
                if let onContinueEditing { onContinueEditing() }
                else {
                    NativeScreenshotCoordinator.shared.openEditor(image: NSImage(
                        cgImage: image,
                        size: NSSize(width: image.width, height: image.height)))
                }
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

    private func copyOriginal(_ image: CGImage) {
        Task { @MainActor [weak self] in
            do {
                let png = try await Task.detached(priority: .userInitiated) {
                    try NativeScreenshotImageProcessor.encode(image, as: .png)
                }.value
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setData(png, forType: .png)
            } catch {
                if let window = self?.window {
                    NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil)
                }
            }
        }
    }

    private func saveOriginal(_ image: CGImage) {
        Task { @MainActor [weak self] in
            do {
                _ = try await NativeScreenshotDeliveryService.saveOnly(image)
            } catch NativeScreenshotDeliveryService.DeliveryError.saveCancelled {
                return
            } catch {
                if let window = self?.window {
                    NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil)
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        window.contentView = nil
        Self.active.removeValue(forKey: id)
        NativeScreenshotWindowActivation.closed(id)
    }
}
