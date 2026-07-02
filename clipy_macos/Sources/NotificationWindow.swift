import AppKit

final class NotificationWindow {
    private var window: HostingWindow<NotificationView>?

    func showWindow() {
        if window == nil {
            window = HostingWindow(
                title: L10n.t(.notificationSync),
                size: AppWindowSize.list,
                minSize: AppWindowSize.notificationMin,
                frameAutosaveName: "NotificationWindow"
            ) {
                NotificationView()
            }
        }
        window?.title = L10n.t(.notificationSync)
        window?.show()
    }

    func closeWindow() {
        window?.close()
    }
}
