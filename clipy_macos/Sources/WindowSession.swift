import AppKit
import SwiftUI

private enum WindowSessionTiming {
    static let teardownDelay: TimeInterval = 5 * 60
}

final class WindowSession<Content: View> {
    private var window: HostingWindow<Content>?
    private var teardownWorkItem: DispatchWorkItem?
    private var onTeardown: (() -> Void)?

    func present(
        create: () -> HostingWindow<Content>,
        onPrepareForClose: @escaping () -> Void,
        onTeardown: @escaping () -> Void = {},
        update: ((HostingWindow<Content>) -> Void)? = nil
    ) {
        cancelTeardown()
        self.onTeardown = onTeardown

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
            window.show()
        }
    }

    func close() {
        window?.close()
    }

    private func scheduleTeardown() {
        teardownWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.teardownIfStillClosed()
        }
        teardownWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + WindowSessionTiming.teardownDelay, execute: work)
    }

    private func cancelTeardown() {
        teardownWorkItem?.cancel()
        teardownWorkItem = nil
    }

    private func teardownIfStillClosed() {
        guard let window, !window.isVisible else { return }
        window.contentViewController = nil
        self.window = nil
        onTeardown?()
        onTeardown = nil
        teardownWorkItem = nil
    }
}
