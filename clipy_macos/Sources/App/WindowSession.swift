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
        // HostingWindow 把 SwiftUI 树挂在 contentView 容器里（不是 contentViewController），
        // 只清 contentViewController 等于没清：窗口外壳若被 AppKit/KVO 继续持有，整棵界面
        // （历史列表、缩略图、图层与 IOSurface）会随之常驻，每开关一次累积一份。
        window.contentViewController = nil
        window.contentView = nil
        window.delegate = nil
        // 关闭的窗口对象可能被 AppKit 继续持有，连同按窗口尺寸分配的绘制缓冲。
        // 先停掉位置自动保存（避免把 1×1 记下来），再缩成 1×1 提交一帧，残留只剩极小一块。
        window.setFrameAutosaveName("")
        window.minSize = NSSize(width: 1, height: 1)
        window.contentMinSize = NSSize(width: 1, height: 1)
        window.setFrame(NSRect(x: window.frame.minX, y: window.frame.minY, width: 1, height: 1), display: true)
        CATransaction.flush()
        self.window = nil
        onTeardown?()
        onTeardown = nil
        teardownWorkItem = nil
    }
}
