import AppKit

final class CollectorWindow {
    private let session = WindowSession<CollectorView>()
    private var viewModel: CollectorViewModel?

    func showWindow() {
        session.present(
            create: { [self] in
                let viewModel = CollectorViewModel()
                self.viewModel = viewModel
                return HostingWindow(
                    title: L10n.t(.phoneCollector),
                    size: AppWindowSize.list,
                    minSize: AppWindowSize.notificationMin,
                    frameAutosaveName: "CollectorWindow"
                ) {
                    CollectorView(viewModel: viewModel)
                }
            },
            onPrepareForClose: { [weak self] in
                self?.viewModel?.prepareForClose()
            },
            onTeardown: { [weak self] in
                self?.viewModel = nil
            },
            update: { window in
                window.title = L10n.t(.phoneCollector)
            }
        )
    }

    func closeWindow() {
        session.close()
    }
}
