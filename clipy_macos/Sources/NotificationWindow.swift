import AppKit

final class NotificationWindow {
    private let session = WindowSession<NotificationView>()
    private var viewModel: NotificationViewModel?

    func showWindow() {
        session.present(
            create: { [self] in
                let viewModel = NotificationViewModel()
                self.viewModel = viewModel
                return HostingWindow(
                    title: L10n.t(.notificationSync),
                    size: AppWindowSize.list,
                    minSize: AppWindowSize.notificationMin,
                    frameAutosaveName: "NotificationWindow"
                ) {
                    NotificationView(viewModel: viewModel)
                }
            },
            onPrepareForClose: { [weak self] in
                self?.viewModel?.prepareForClose()
            },
            onTeardown: { [weak self] in
                self?.viewModel = nil
            },
            update: { window in
                window.title = L10n.t(.notificationSync)
            }
        )
    }

    func closeWindow() {
        session.close()
    }
}
