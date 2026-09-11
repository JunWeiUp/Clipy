import AppKit

final class WordLookupWindow {
    static let shared = WordLookupWindow()
    private let session = WindowSession<WordLookupView>()
    private var viewModel: WordLookupViewModel?

    func showWindow(query: String? = nil) {
        let items = NSPasteboard.general.pasteboardItems ?? []
        let clipboardText = items.count == 1 && !items[0].types.contains(.fileURL)
            ? items[0].string(forType: .string) : nil
        session.present(create: { [self] in
            let model = WordLookupViewModel()
            viewModel = model
            return HostingWindow(title: L10n.t(.wordLookup), size: CGSize(width: 720, height: 720),
                                 minSize: CGSize(width: 480, height: 440), frameAutosaveName: "WordLookupWindow") {
                WordLookupView(viewModel: model)
            }
        }, onPrepareForClose: { [weak self] in
            self?.viewModel?.prepareForClose()
        }, onTeardown: { [weak self] in
            self?.viewModel = nil
            MemoryFootprintReclaimer.reclaimIfIdle()
        }, update: { [weak self] window in
            window.title = L10n.t(.wordLookup)
            // update runs for both first creation and cached-window reopening.
            if let query, let model = self?.viewModel {
                model.query = query
                model.search()
            } else {
                self?.viewModel?.prepareForPresentation(clipboardText: clipboardText)
            }
        })
    }
}

enum WordGlobalHotKeyManager {
    private static let hotKeyID: UInt32 = 0x574F_5244 // 'WORD'

    @discardableResult
    static func register() -> Bool {
        let prefs = PreferencesManager.shared
        guard prefs.isWordShortcutEnabled, let combo = prefs.wordLookupShortcut else {
            HotKeyManager.shared.unregister(id: hotKeyID)
            return true
        }
        return HotKeyManager.shared.register(keyCode: combo.keyCode, modifiers: combo.modifierFlags, id: hotKeyID) {
            DispatchQueue.main.async { WordLookupWindow.shared.showWindow() }
        }
    }
}
