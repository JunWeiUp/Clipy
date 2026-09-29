import Foundation

/// Reads the previous screenshot tool preference without depending on the
/// removed screenshot engine. The integer key is a persisted user preference,
/// so its historical values must keep their original meaning.
enum NativeScreenshotRememberedTool {
    private static let key = "nativeScreenshot.lastTool"
    private static let legacyKey = "lastUsedTool"
    private static let migrationKey = "nativeScreenshot.lastToolMigrated"

    static func initial(remember: Bool, defaults: UserDefaults = .standard) -> NativeScreenshotAnnotationKind {
        guard remember else { return .arrow }
        // Earlier independent test builds may already have written `key` while
        // the installed app was still updating the old preference. On the first
        // launch of this compatibility version, honor the installed app's tool.
        if !defaults.bool(forKey: migrationKey),
           let raw = defaults.object(forKey: legacyKey) as? Int,
           let tool = legacyTool(raw) {
            return tool
        }
        if let raw = defaults.string(forKey: key),
           let tool = NativeScreenshotAnnotationKind(rawValue: raw),
           tool != .magnifier {
            return tool
        }
        if let raw = defaults.object(forKey: legacyKey) as? Int,
           let tool = legacyTool(raw) {
            return tool
        }
        return .arrow
    }

    static func store(_ tool: NativeScreenshotAnnotationKind?, remember: Bool,
                      defaults: UserDefaults = .standard) {
        guard remember, let tool, tool != .magnifier else { return }
        defaults.set(tool.rawValue, forKey: key)
        defaults.set(true, forKey: migrationKey)
    }

    private static func legacyTool(_ raw: Int) -> NativeScreenshotAnnotationKind? {
        switch raw {
        case 0: return .pencil
        case 1: return .line
        case 2: return .arrow
        case 3: return .rectangle
        case 4: return .filledRectangle
        case 5: return .ellipse
        case 6: return .highlighter
        case 7: return .richText
        case 8: return .number
        case 9: return .pixelate
        case 10: return .blur
        case 11: return .ruler
        case 16: return .colorSampler
        case 17: return .stamp
        case 18: return .spotlight
        default: return nil // select, loupe, translate and crop were transient tools
        }
    }
}
