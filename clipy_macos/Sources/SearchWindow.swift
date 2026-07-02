import AppKit

final class SearchWindow {
    static let shared = SearchWindow()
    private var window: HostingWindow<SearchView>?

    private init() {}

    func showWindow() {
        if window == nil {
            window = HostingWindow(
                title: L10n.t(.searchHistory),
                size: AppWindowSize.search,
                minSize: AppWindowSize.searchMin,
                frameAutosaveName: "SearchWindow"
            ) {
                SearchView()
            }
        }
        window?.title = L10n.t(.searchHistory)
        window?.show()
    }

    func closeWindow() {
        window?.close()
    }
}
