import Foundation

@main
enum NativeScreenshotSettingsCompatibilityRegression {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fatalError("Pass the path to ScreenshotSettingsView.swift")
        }

        let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let expression = try NSRegularExpression(pattern: #"L\("([^"]+)"\)"#)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let labels = Set(expression.matches(in: source, range: range).compactMap { match -> String? in
            guard let capture = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[capture])
        })

        precondition(!labels.isEmpty)
        precondition(labels == Set(NativeScreenshotSettingsCompatibility.chinese.keys),
                     "Every L(\"…\") label in settings must have exactly one Chinese translation")
        for label in labels {
            let chinese = NativeScreenshotSettingsCompatibility.localized(label, languageCode: "zh")
            precondition(!chinese.isEmpty && chinese != label, "Missing Chinese translation: \(label)")
            precondition(NativeScreenshotSettingsCompatibility.localized(label, languageCode: "en") == label)
        }

        let height = NativeScreenshotSettingsCompatibility.localized("Max Height: %d px", languageCode: "zh")
        precondition(String(format: height, 12_000).contains("12000"))
        precondition(NativeScreenshotSettingsCompatibility.localized("Unknown", languageCode: "zh") == "Unknown")

        let saved = UserDefaults.standard.object(forKey: "appLanguage")
        defer { UserDefaults.standard.set(saved, forKey: "appLanguage") }
        UserDefaults.standard.set("zh", forKey: "appLanguage")
        precondition(L("Recording") == "录屏")
        UserDefaults.standard.set("en", forKey: "appLanguage")
        precondition(L("Recording") == "Recording")

        // Compile-time API checks only: testing must not prompt for Input Monitoring.
        let _: () -> Bool = { KeystrokeOverlay.hasInputMonitoringPermission }
        let _: () -> Void = KeystrokeOverlay.requestInputMonitoringPermission

        print("Native screenshot settings compatibility regression passed (\(labels.count) labels)")
    }
}
