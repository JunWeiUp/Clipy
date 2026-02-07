import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var menuController: MenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuController = MenuController()
        _ = SyncManager.shared
        print("Clipy clone started!")
    }
}

app.run()
