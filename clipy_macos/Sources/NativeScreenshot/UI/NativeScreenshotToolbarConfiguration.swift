import AppKit
import Foundation

/// Persisted choices for the temporary screenshot toolbars. Identifiers stay
/// independent of button order so a later layout change preserves preferences.
struct NativeScreenshotToolbarConfiguration: Codable, Equatable {
    struct Item: Identifiable {
        let id: String
        let chinese: String
        let english: String

        var title: String { NativeScreenshotUserText.string(chinese, english) }
    }

    enum ColorRole { case accent, icon, background }

    enum ShortcutError: Error, Equatable {
        case unknownTool
        case invalidKey
        case reservedKey
        case duplicateKey(existingToolID: String)
    }

    static let tools: [Item] = [
        .init(id: "select", chinese: "选择", english: "Select"),
        .init(id: "pencil", chinese: "画笔", english: "Pencil"),
        .init(id: "line", chinese: "直线", english: "Line"),
        .init(id: "arrow", chinese: "箭头", english: "Arrow"),
        .init(id: "rectangle", chinese: "矩形", english: "Rectangle"),
        .init(id: "filledRectangle", chinese: "实心矩形", english: "Filled rectangle"),
        .init(id: "ellipse", chinese: "椭圆", english: "Ellipse"),
        .init(id: "highlighter", chinese: "荧光笔", english: "Highlighter"),
        .init(id: "richText", chinese: "文字", english: "Text"),
        .init(id: "number", chinese: "编号", english: "Number"),
        .init(id: "stamp", chinese: "图章", english: "Stamp"),
        .init(id: "pixelate", chinese: "马赛克", english: "Pixelate"),
        .init(id: "blur", chinese: "模糊", english: "Blur"),
        .init(id: "solidCensor", chinese: "纯色遮挡", english: "Solid censor"),
        .init(id: "eraseCensor", chinese: "擦除", english: "Erase"),
        .init(id: "magnifier", chinese: "放大镜", english: "Magnifier"),
        .init(id: "ruler", chinese: "测距", english: "Ruler"),
        .init(id: "colorSampler", chinese: "取色", english: "Color picker"),
        .init(id: "spotlight", chinese: "聚光灯", english: "Spotlight")
    ]

    static let rightActions: [Item] = [
        .init(id: "cancel", chinese: "取消", english: "Cancel"),
        .init(id: "move", chinese: "移动选区", english: "Move selection"),
        .init(id: "editor", chinese: "打开编辑器", english: "Open editor"),
        .init(id: "copy", chinese: "复制", english: "Copy"),
        .init(id: "save", chinese: "保存", english: "Save"),
        .init(id: "share", chinese: "分享", english: "Share"),
        .init(id: "pin", chinese: "贴图", english: "Pin"),
        .init(id: "ocr", chinese: "文字识别", english: "Recognize text"),
        .init(id: "translate", chinese: "翻译", english: "Translate"),
        .init(id: "qrCode", chinese: "识别二维码", english: "Scan QR code"),
        .init(id: "autoRedact", chinese: "遮挡敏感信息", english: "Redact sensitive text"),
        .init(id: "scroll", chinese: "滚动截图", english: "Scrolling capture"),
        .init(id: "record", chinese: "录屏", english: "Record")
    ]

    static let effectActions: [Item] = [
        .init(id: "invertColors", chinese: "反色", english: "Invert colors"),
        .init(id: "imageEffects", chinese: "调整特效", english: "Image effects"),
        .init(id: "beautify", chinese: "美化", english: "Beautify"),
        .init(id: "removeBackground", chinese: "移除背景", english: "Remove background")
    ]

    static let actions = rightActions + effectActions

    static let toolIDs = tools.map(\.id)
    static let legacyMainToolIDs = [
        "pencil", "line", "arrow", "rectangle", "ellipse", "highlighter",
        "richText", "number", "pixelate", "spotlight", "magnifier", "stamp",
        "colorSampler", "ruler"
    ]
    static let actionIDs = actions.map(\.id)
    static let rightActionIDs = rightActions.map(\.id)
    static let legacyVisibleRightActionIDs = rightActionIDs.filter { $0 != "qrCode" && $0 != "autoRedact" }
    static let effectActionIDs = effectActions.map(\.id)
    static let shortcutActionIDs = actionIDs + ["undo", "redo"]
    private static let shortcutIDs = toolIDs + shortcutActionIDs
    static let storageKey = "nativeScreenshot.toolbar.configuration.v1"
    private static let effectsMigrationKey = "nativeScreenshot.toolbar.effectActionsMigrated"
    private static let mainToolMigrationKey = "nativeScreenshot.toolbar.legacyMainToolsMigrated"
    private static let shortcutMigrationKey = "nativeScreenshot.toolbar.legacyShortcutsMigrated"
    private static let colorMigrationKey = "nativeScreenshot.toolbar.legacyColorsMigrated"
    private static let rightActionMigrationKey = "nativeScreenshot.toolbar.legacyRightActionsMigrated"
    private static let earlierBackgroundHex = "#20242CEB"

    // Defaults in the first independent screenshot build. A saved value that
    // differs from this table belongs to the user and takes precedence over
    // both historical settings and the restored v1.0.23 defaults.
    private static let previousIndependentShortcuts: [String: String] = [
        "select": "q", "pencil": "p", "line": "l", "arrow": "a",
        "rectangle": "r", "filledRectangle": "v", "ellipse": "e",
        "highlighter": "h", "richText": "t", "number": "n", "stamp": "s",
        "pixelate": "m", "blur": "b", "solidCensor": "x",
        "eraseCensor": "d", "magnifier": "g", "ruler": "u",
        "colorSampler": "c", "spotlight": "o"
    ]

    // ToolShortcutManager.Action raw values from the v1.0.23 overlay.
    private static let legacyShortcutIDs: [(old: String, current: String)] = [
        ("pencil", "pencil"), ("arrow", "arrow"), ("line", "line"),
        ("rectangle", "rectangle"), ("ellipse", "ellipse"),
        ("marker", "highlighter"), ("text", "richText"),
        ("number", "number"), ("censor", "pixelate"),
        ("highlight", "spotlight"), ("colorSampler", "colorSampler"),
        ("stamp", "stamp"), ("measure", "ruler"),
        ("loupe", "magnifier"), ("moveSelection", "move"),
        ("openInEditor", "editor"), ("pin", "pin"),
        ("copy", "copy"), ("save", "save"), ("ocr", "ocr"),
        ("scrollCapture", "scroll"), ("beautify", "beautify"),
        ("invertColors", "invertColors"),
        ("removeBackground", "removeBackground"),
        ("translate", "translate"), ("undo", "undo"), ("redo", "redo")
    ]

    var enabledToolIDs: [String]
    var enabledActionIDs: [String]
    var accentHex: String
    var iconHex: String
    var backgroundHex: String
    var shortcuts: [String: String]

    static let `default` = NativeScreenshotToolbarConfiguration(
        enabledToolIDs: toolIDs.filter { $0 == "select" || legacyMainToolIDs.contains($0) },
        enabledActionIDs: actionIDs.filter { legacyVisibleRightActionIDs.contains($0) || effectActionIDs.contains($0) },
        accentHex: "#0A84FFFF",
        iconHex: "#FFFFFFFF",
        backgroundHex: "#1F1F1FFF",
        shortcuts: [
            "pencil": "p", "arrow": "a", "line": "l", "rectangle": "r",
            "ellipse": "o", "highlighter": "m", "richText": "t",
            "number": "n", "pixelate": "b", "spotlight": "h",
            "colorSampler": "i", "stamp": "g", "move": " ",
            "editor": "e", "pin": "f"
        ]
    )

    func isToolEnabled(_ id: String) -> Bool { enabledToolIDs.contains(id) }
    func isActionEnabled(_ id: String) -> Bool { enabledActionIDs.contains(id) }

    mutating func setToolEnabled(_ enabled: Bool, id: String) {
        guard Self.toolIDs.contains(id), id != "select" else { return }
        var values = Set(enabledToolIDs)
        if enabled { values.insert(id) } else { values.remove(id) }
        enabledToolIDs = Self.toolIDs.filter(values.contains)
    }

    mutating func setActionEnabled(_ enabled: Bool, id: String) {
        guard Self.actionIDs.contains(id), id != "cancel" else { return }
        var values = Set(enabledActionIDs)
        if enabled { values.insert(id) } else { values.remove(id) }
        enabledActionIDs = Self.actionIDs.filter(values.contains)
    }

    func shortcut(forToolID id: String) -> String? { shortcuts[id] }

    func shortcut(forActionID id: String) -> String? {
        Self.shortcutActionIDs.contains(id) ? shortcuts[id] : nil
    }

    /// Returns the configured tool for a plain, unmodified key press. Hiding a
    /// toolbar button does not disable its keyboard shortcut in v1.0.23.
    func toolID(forShortcut key: String) -> String? {
        let normalized = Self.canonicalStoredShortcut(key)
        guard let normalized else { return nil }
        return Self.toolIDs.first { shortcuts[$0] == normalized }
    }

    /// The old overlay also assigned plain keys to actions such as Space for
    /// moving a selection, E for the editor and F for pinning. These shortcuts
    /// remain active when their toolbar button is hidden, as in v1.0.23.
    func actionID(forShortcut key: String) -> String? {
        guard let normalized = Self.canonicalStoredShortcut(key) else { return nil }
        return Self.shortcutActionIDs.first { shortcuts[$0] == normalized }
    }

    mutating func setShortcut(_ rawKey: String?, forToolID id: String) throws {
        guard Self.toolIDs.contains(id) else { throw ShortcutError.unknownTool }
        let key = rawKey?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if key.isEmpty {
            shortcuts.removeValue(forKey: id)
            return
        }
        guard Self.isValidShortcutKey(key) else { throw ShortcutError.invalidKey }
        if let owner = Self.shortcutIDs.first(where: { $0 != id && shortcuts[$0] == key }) {
            throw ShortcutError.duplicateKey(existingToolID: owner)
        }
        shortcuts[id] = key
    }

    mutating func setShortcut(_ rawKey: String?, forActionID id: String) throws {
        guard Self.shortcutActionIDs.contains(id) else { throw ShortcutError.unknownTool }
        let key = rawKey == " " ? " "
            : rawKey?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if key.isEmpty {
            shortcuts.removeValue(forKey: id)
            return
        }
        guard key == " " || Self.isValidShortcutKey(key) else {
            throw ShortcutError.invalidKey
        }
        if let owner = Self.shortcutIDs.first(where: { $0 != id && shortcuts[$0] == key }) {
            throw ShortcutError.duplicateKey(existingToolID: owner)
        }
        shortcuts[id] = key
    }

    var accentColor: NSColor { Self.color(from: accentHex) ?? Self.color(from: Self.default.accentHex)! }
    var iconColor: NSColor { Self.color(from: iconHex) ?? Self.color(from: Self.default.iconHex)! }
    var backgroundColor: NSColor {
        Self.color(from: backgroundHex) ?? Self.color(from: Self.default.backgroundHex)!
    }

    mutating func setColor(_ color: NSColor, for role: ColorRole) {
        guard let hex = Self.hexString(for: color) else { return }
        switch role {
        case .accent: accentHex = hex
        case .icon: iconHex = hex
        case .background: backgroundHex = hex
        }
    }

    func normalized() -> Self {
        var copy = self
        let enabledTools = Set(enabledToolIDs).union(["select"])
        let enabledActions = Set(enabledActionIDs).union(["cancel"])
        copy.enabledToolIDs = Self.toolIDs.filter(enabledTools.contains)
        copy.enabledActionIDs = Self.actionIDs.filter(enabledActions.contains)
        copy.accentHex = Self.canonicalHex(accentHex) ?? Self.default.accentHex
        copy.iconHex = Self.canonicalHex(iconHex) ?? Self.default.iconHex
        copy.backgroundHex = Self.canonicalHex(backgroundHex) ?? Self.default.backgroundHex
        copy.shortcuts = [:]
        var claimedKeys = Set<String>()
        for id in Self.shortcutIDs {
            guard let raw = shortcuts[id],
                  let key = Self.canonicalStoredShortcut(raw),
                  !claimedKeys.contains(key) else { continue }
            copy.shortcuts[id] = key
            claimedKeys.insert(key)
        }
        return copy
    }

    static func load(from defaults: UserDefaults) -> Self {
        let decoded = defaults.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
        var migrated = decoded ?? Self.default
        migrateLegacyShortcuts(&migrated, defaults: defaults, hadSavedConfiguration: decoded != nil)
        migrateLegacyRightActions(&migrated, defaults: defaults)
        migrateLegacyEffects(&migrated, defaults: defaults)
        migrateLegacyColors(&migrated, defaults: defaults)
        return migrated.normalized()
    }

    private static func migrateLegacyShortcuts(
        _ value: inout Self, defaults: UserDefaults, hadSavedConfiguration: Bool
    ) {
        guard !defaults.bool(forKey: shortcutMigrationKey) else { return }
        let prior = value.shortcuts
        let legacy = defaults.dictionary(forKey: "overlayToolShortcuts") as? [String: String] ?? [:]
        var customized = Set<String>()
        var disabled = Set<String>()
        var preferred: [(id: String, key: String)] = []
        var historical: [(id: String, key: String)] = []

        // A missing key from a saved configuration is an explicit disable.
        // That choice must survive even if the old overlay has a shortcut.
        if hadSavedConfiguration {
            for id in shortcutIDs where prior[id] != previousIndependentShortcuts[id] {
                customized.insert(id)
                if let key = prior[id] { preferred.append((id, key)) }
                else { disabled.insert(id) }
            }
        }
        for mapping in legacyShortcutIDs where !customized.contains(mapping.current) {
            guard let key = legacy[mapping.old] else { continue }
            if key.isEmpty { disabled.insert(mapping.current) }
            else { historical.append((mapping.current, key)) }
        }

        var result: [String: String] = [:]
        var claimedKeys = Set<String>()
        func claim(_ id: String, _ rawKey: String) {
            guard result[id] == nil, !disabled.contains(id),
                  let key = canonicalStoredShortcut(rawKey),
                  claimedKeys.insert(key).inserted else { return }
            result[id] = key
        }
        // New customizations win, then old saved choices, then old defaults.
        // A conflicting old choice falls back to its default when possible.
        for entry in preferred { claim(entry.id, entry.key) }
        for entry in historical { claim(entry.id, entry.key) }
        for id in shortcutIDs {
            if let key = Self.default.shortcuts[id] { claim(id, key) }
        }
        value.shortcuts = result
        defaults.set(true, forKey: shortcutMigrationKey)
        value.save(to: defaults)
    }

    private static func migrateLegacyEffects(_ value: inout Self, defaults: UserDefaults) {
        if !defaults.bool(forKey: effectsMigrationKey) {
            // Preserve older toolbar action choices when adding the four
            // original in-selection image controls to the independent UI.
            let legacyEnabled = defaults.array(forKey: "enabledActions") as? [Int]
            let legacyTags: [(String, Int)] = [
                ("invertColors", 1011), ("imageEffects", 1013),
                ("beautify", 1004), ("removeBackground", 1005)
            ]
            for (id, tag) in legacyTags {
                if legacyEnabled == nil || legacyEnabled!.contains(tag) {
                    if !value.enabledActionIDs.contains(id) { value.enabledActionIDs.append(id) }
                } else {
                    value.enabledActionIDs.removeAll { $0 == id }
                }
            }
            defaults.set(true, forKey: effectsMigrationKey)
            value.save(to: defaults)
        }
        if !defaults.bool(forKey: mainToolMigrationKey) {
            // Earlier independent builds showed every submode in the main bar.
            // Keep explicit custom selections, while restoring the historical
            // compact main bar for the default all-tools configuration.
            let isUncustomized = Set(value.enabledToolIDs) == Set(toolIDs)
                || Set(value.enabledToolIDs) == Set(Self.default.enabledToolIDs)
            let legacyToolMap: [(String, Int)] = [
                ("pencil", 0), ("line", 1), ("arrow", 2),
                ("rectangle", 3), ("ellipse", 5), ("highlighter", 6),
                ("richText", 7), ("number", 8), ("pixelate", 9),
                ("spotlight", 18), ("magnifier", 12), ("stamp", 17),
                ("colorSampler", 16), ("ruler", 11)
            ]
            if isUncustomized,
               let oldEnabled = defaults.array(forKey: "enabledTools") as? [Int] {
                value.enabledToolIDs = ["select"] + legacyToolMap.compactMap { id, raw in
                    oldEnabled.contains(raw) ? id : nil
                }
            } else if Set(value.enabledToolIDs) == Set(toolIDs) {
                value.enabledToolIDs = ["select"] + legacyMainToolIDs
            }
            defaults.set(true, forKey: mainToolMigrationKey)
            value.save(to: defaults)
        }
    }

    private static func migrateLegacyRightActions(_ value: inout Self, defaults: UserDefaults) {
        guard !defaults.bool(forKey: rightActionMigrationKey) else { return }
        // The first independent build exposed two recognition subactions as
        // extra buttons. Preserve explicit action choices, but use the older
        // eleven-button side strip for an untouched configuration.
        if Set(value.enabledActionIDs) == Set(actionIDs) {
            value.enabledActionIDs = Self.default.enabledActionIDs
        }
        defaults.set(true, forKey: rightActionMigrationKey)
        value.save(to: defaults)
    }

    private static func migrateLegacyColors(_ value: inout Self, defaults: UserDefaults) {
        guard !defaults.bool(forKey: colorMigrationKey) else { return }

        func storedColor(_ key: String) -> String? {
            guard let data = defaults.data(forKey: key),
                  let color = try? NSKeyedUnarchiver.unarchivedObject(
                    ofClass: NSColor.self, from: data) else { return nil }
            return hexString(for: color)
        }

        // The prior independent build used a translucent blue-gray default.
        // Carry explicit new choices forward; otherwise restore the dark,
        // opaque toolbar and any colors the user chose in the older UI.
        if value.backgroundHex == earlierBackgroundHex {
            value.backgroundHex = storedColor("toolbarBgColor") ?? Self.default.backgroundHex
        }
        if value.iconHex == Self.default.iconHex,
           let icon = storedColor("toolbarIconColor") {
            value.iconHex = icon
        }
        if value.accentHex == Self.default.accentHex,
           let accent = storedColor("toolbarAccentColor") {
            value.accentHex = accent
        }
        defaults.set(true, forKey: colorMigrationKey)
        value.save(to: defaults)
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(normalized()) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    static func hexString(for color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return nil }
        func byte(_ component: CGFloat) -> Int {
            Int((max(0, min(1, component)) * 255).rounded())
        }
        return String(format: "#%02X%02X%02X%02X", byte(rgb.redComponent),
                      byte(rgb.greenComponent), byte(rgb.blueComponent), byte(rgb.alphaComponent))
    }

    private static func isValidShortcutKey(_ key: String) -> Bool {
        guard key.utf8.count == 1, let byte = key.utf8.first else { return false }
        return (97...122).contains(byte) || (48...57).contains(byte)
    }

    private static func canonicalStoredShortcut(_ raw: String) -> String? {
        let key = raw == " " ? raw : raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count == 1,
              !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return key.lowercased()
    }

    private static func canonicalHex(_ raw: String) -> String? {
        guard raw.hasPrefix("#") else { return nil }
        let digits = String(raw.dropFirst())
        guard digits.count == 6 || digits.count == 8,
              UInt64(digits, radix: 16) != nil else { return nil }
        return "#" + digits.uppercased() + (digits.count == 6 ? "FF" : "")
    }

    private static func color(from raw: String) -> NSColor? {
        guard let value = canonicalHex(raw),
              let number = UInt64(value.dropFirst(), radix: 16) else { return nil }
        return NSColor(deviceRed: CGFloat((number >> 24) & 0xFF) / 255,
                       green: CGFloat((number >> 16) & 0xFF) / 255,
                       blue: CGFloat((number >> 8) & 0xFF) / 255,
                       alpha: CGFloat(number & 0xFF) / 255)
    }
}
