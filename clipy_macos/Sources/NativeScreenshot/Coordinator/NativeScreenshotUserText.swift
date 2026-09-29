import Foundation

enum NativeScreenshotUserText {
    static var usesChinese: Bool {
        let raw = UserDefaults.standard.string(forKey: "appLanguage")
        return raw == "zh"
            || (raw != "en" && Locale.preferredLanguages.first?.hasPrefix("zh") == true)
    }

    static func string(_ chinese: String, _ english: String) -> String {
        usesChinese ? chinese : english
    }
}
