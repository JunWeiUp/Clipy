import Foundation

enum NativeScreenshotUserText {
    static func string(_ chinese: String, _ english: String) -> String {
        let raw = UserDefaults.standard.string(forKey: "appLanguage")
        let prefersChinese = raw == "zh"
            || (raw != "en" && Locale.preferredLanguages.first?.hasPrefix("zh") == true)
        return prefersChinese ? chinese : english
    }
}
