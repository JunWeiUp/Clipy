import AppKit
import SwiftUI

protocol WindowSessionPresenting: AnyObject {
    var onWillClose: (() -> Void)? { get set }
    func show()
}

final class WindowSession<Content: View> {
    private var window: (NSWindow & WindowSessionPresenting)?
    private var teardownWorkItem: DispatchWorkItem?
    private var onTeardown: (() -> Void)?
    private var reusePolicy: WindowSessionReusePolicy

    init(teardownDelay: TimeInterval = WindowSessionReusePolicy.defaultDelay) {
        reusePolicy = WindowSessionReusePolicy(delay: teardownDelay)
    }

    deinit { teardownWorkItem?.cancel() }

    func present(
        create: () -> (NSWindow & WindowSessionPresenting),
        onPrepareForClose: @escaping () -> Void,
        onTeardown: @escaping () -> Void = {},
        update: ((NSWindow) -> Void)? = nil,
        onShow: (() -> Void)? = nil
    ) {
        cancelTeardown()
        self.onTeardown = onTeardown

        // Track whether this call is reusing an already-cached window so callers
        // can run "reactivate" logic (reload data, re-register observers) that
        // SwiftUI's .onAppear would otherwise miss on a reused NSHostingController.
        let isReusingExistingWindow = window != nil

        if window == nil {
            let created = create()
            created.onWillClose = { [weak self] in
                onPrepareForClose()
                self?.scheduleTeardown()
            }
            window = created
        }

        if let window {
            update?(window)
            if isReusingExistingWindow {
                // First-open relies on SwiftUI .onAppear (which fires once when
                // the view tree is first inserted); subsequent reopens only call
                // show(), so the view never re-appears — give callers a hook to
                // refresh state that was cleared on close.
                onShow?()
            }
            window.show()
        }
    }

    func close() {
        window?.close()
    }

    func revealExistingWindow() {
        cancelTeardown()
        window?.show()
    }

    var keyWindow: NSWindow? { window?.isKeyWindow == true ? window : nil }

    /// Release keyboard focus while keeping the draft available if handoff fails.
    func hideForHandoff() {
        cancelTeardown()
        window?.orderOut(nil)
    }

    private func scheduleTeardown() {
        teardownWorkItem?.cancel()
        let generation = reusePolicy.didClose()
        let work = DispatchWorkItem { [weak self] in
            self?.teardownIfStillClosed(generation: generation)
        }
        teardownWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + reusePolicy.delay, execute: work)
    }

    private func cancelTeardown() {
        reusePolicy.keepAlive()
        teardownWorkItem?.cancel()
        teardownWorkItem = nil
    }

    private func teardownIfStillClosed(generation: UInt64) {
        guard let window, reusePolicy.shouldTeardown(generation: generation, isVisible: window.isVisible) else { return }
        window.contentViewController = nil
        self.window = nil
        onTeardown?()
        onTeardown = nil
        teardownWorkItem = nil
    }
}
