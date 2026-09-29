import Foundation

@main
enum NativeScreenshotRememberedToolRegression {
    static func main() {
        let name = "clipy.remembered-tool.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            preconditionFailure("could not make isolated preferences")
        }
        defer { defaults.removePersistentDomain(forName: name) }

        typealias Tool = NativeScreenshotRememberedTool
        precondition(Tool.initial(remember: true, defaults: defaults) == .arrow)

        defaults.set(3, forKey: "lastUsedTool")
        precondition(Tool.initial(remember: true, defaults: defaults) == .rectangle,
                     "the original rectangle preference should migrate")
        defaults.set("line", forKey: "nativeScreenshot.lastTool")
        precondition(Tool.initial(remember: true, defaults: defaults) == .rectangle,
                     "an earlier test build must not override the installed app's tool")
        precondition(Tool.initial(remember: false, defaults: defaults) == .arrow,
                     "disabling remembered tools should use the original arrow default")

        Tool.store(.highlighter, remember: true, defaults: defaults)
        precondition(Tool.initial(remember: true, defaults: defaults) == .highlighter,
                     "a new choice should supersede the historical preference")
        Tool.store(nil, remember: true, defaults: defaults)
        Tool.store(.magnifier, remember: true, defaults: defaults)
        precondition(Tool.initial(remember: true, defaults: defaults) == .highlighter,
                     "selection mode and magnifier must not erase the last drawing tool")
        Tool.store(.line, remember: false, defaults: defaults)
        precondition(Tool.initial(remember: true, defaults: defaults) == .highlighter)

        defaults.set("unknown", forKey: "nativeScreenshot.lastTool")
        precondition(Tool.initial(remember: true, defaults: defaults) == .rectangle,
                     "invalid native values should fall back to the historical tool")
        defaults.set(13, forKey: "lastUsedTool")
        precondition(Tool.initial(remember: true, defaults: defaults) == .arrow,
                     "the historical selection mode should not be restored as a drawing tool")

        print("NativeScreenshotRememberedToolRegression passed")
    }
}
