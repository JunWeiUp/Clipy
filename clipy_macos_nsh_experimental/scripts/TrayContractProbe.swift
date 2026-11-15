// Standalone diagnostic. Run only under the coordinator's control: creates one
// temporary status item for eight seconds, then removes it. No clipboard/data use.
import AppKit
import Foundation
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    let item = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
    if let button = item.button {
        let text = NSAttributedString(string:"Tray Contract Probe",attributes:[.font:NSFont.menuBarFont(ofSize:0),.foregroundColor:NSColor.labelColor])
        button.attributedTitle = text
        button.imagePosition = .imageLeft
        button.toolTip = "Temporary status contract probe"
        button.setAccessibilityLabel("Temporary status contract probe")
    }
    func report() {
        var info:[String:Any] = ["pid":ProcessInfo.processInfo.processIdentifier,"visible":item.isVisible,"autosaveName":item.autosaveName ?? "nil","length":item.length,"bundleId":Bundle.main.bundleIdentifier ?? "unbundled"]
        if let button = item.button {
            info["title"] = button.title
            info["buttonFrame"] = NSStringFromRect(button.frame)
            info["windowFrame"] = button.window.map { NSStringFromRect($0.frame) } ?? "nil"
            info["windowNumber"] = button.window?.windowNumber ?? -1
        }
        let keys = ["NSStatusItem Visible Item-0","NSStatusItem Preferred Position Item-0"]
        info["exactPreferences"] = Dictionary(uniqueKeysWithValues:keys.map { ($0,UserDefaults.standard.object(forKey:$0) ?? NSNull()) })
        if let data = try? JSONSerialization.data(withJSONObject:info,options:.sortedKeys) { FileHandle.standardOutput.write(data+Data([10])) }
    }
    DispatchQueue.main.asyncAfter(deadline:.now()+1) { report() }
    DispatchQueue.main.asyncAfter(deadline:.now()+8) { NSStatusBar.system.removeStatusItem(item);app.stop(nil) }
    app.run()
}
