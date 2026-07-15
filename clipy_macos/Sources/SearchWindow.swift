import AppKit

final class SearchWindow {
    static let shared = SearchWindow()

    private let session = WindowSession<SearchView>()
    private var viewModel: SearchViewModel?

    private init() {}

    func showWindow() {
        session.present(
            create: { [self] in
                let viewModel = SearchViewModel()
                self.viewModel = viewModel
                return HostingWindow(
                    title: L10n.t(.searchHistory),
                    size: AppWindowSize.search,
                    minSize: AppWindowSize.searchMin,
                    frameAutosaveName: "SearchWindow"
                ) {
                    SearchView(viewModel: viewModel)
                }
            },
            onPrepareForClose: { [weak self] in
                self?.viewModel?.prepareForClose()
            },
            onTeardown: { [weak self] in
                self?.viewModel = nil
                MemoryFootprintReclaimer.reclaimIfIdle()
            },
            update: { window in
                window.title = L10n.t(.searchHistory)
            }
        )
    }

    func closeWindow() {
        session.close()
    }
}
