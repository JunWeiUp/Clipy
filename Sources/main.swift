import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var menuController: MenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuController = MenuController()
        SyncManager.shared.start()
        print("Clipy clone started!")
    }
}

app.run()
