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
            },
            // Fired only when reopening a cached window: SwiftUI .onAppear does
            // not re-run there, so the ViewModel must be told to reload (its
            // results were cleared on close and its change observer removed).
            onShow: { [weak self] in
                self?.viewModel?.reactivate()
            }
        )
    }

    func closeWindow() {
        session.close()
    }
}
