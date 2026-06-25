import AppKit

final class CollectorWindow {
    private var window: HostingWindow<CollectorView>?

    func showWindow() {
        if window == nil {
            window = HostingWindow(
                title: L10n.t(.phoneCollector),
                size: AppWindowSize.list,
                minSize: AppWindowSize.notificationMin,
                frameAutosaveName: "CollectorWindow"
            ) {
                CollectorView()
            }
        }
        window?.title = L10n.t(.phoneCollector)
        window?.show()
    }

    func closeWindow() {
        window?.close()
    }
}
