import AppKit
import Foundation

@main
enum NativeScreenshotToolbarConfigurationRegression {
    static func main() throws {
        typealias Configuration = NativeScreenshotToolbarConfiguration
        let suiteName = "ClipyToolbarTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = Configuration.load(from: defaults)
        precondition(Set(initial.enabledToolIDs) == Set(["select"] + Configuration.legacyMainToolIDs))
        precondition(initial.enabledActionIDs
            == Configuration.actionIDs.filter {
                Configuration.legacyVisibleRightActionIDs.contains($0)
                    || Configuration.effectActionIDs.contains($0)
            })
        precondition(!initial.isActionEnabled("qrCode"))
        precondition(!initial.isActionEnabled("autoRedact"))
        precondition(Set(initial.shortcuts.values).count == initial.shortcuts.count)
        precondition(initial.toolID(forShortcut: "P") == "pencil")
        precondition(initial.toolID(forShortcut: "o") == "ellipse")
        precondition(initial.toolID(forShortcut: "m") == "highlighter")
        precondition(initial.toolID(forShortcut: "b") == "pixelate")
        precondition(initial.toolID(forShortcut: "h") == "spotlight")
        precondition(initial.toolID(forShortcut: "i") == "colorSampler")
        precondition(initial.toolID(forShortcut: "g") == "stamp")
        precondition(initial.shortcut(forToolID: "ruler") == nil)
        precondition(initial.shortcut(forToolID: "magnifier") == nil)
        precondition(initial.actionID(forShortcut: " ") == "move")
        precondition(initial.actionID(forShortcut: "e") == "editor")
        precondition(initial.actionID(forShortcut: "f") == "pin")
        precondition(initial.isToolEnabled("select"))
        precondition(initial.isActionEnabled("cancel"))
        precondition(initial.backgroundHex == "#1F1F1FFF")

        var changed = initial
        changed.setToolEnabled(false, id: "pencil")
        changed.setToolEnabled(false, id: "select")
        changed.setActionEnabled(false, id: "record")
        changed.setActionEnabled(false, id: "cancel")
        precondition(!changed.isToolEnabled("pencil"))
        precondition(changed.toolID(forShortcut: "p") == "pencil")
        precondition(changed.isToolEnabled("select"))
        precondition(!changed.isActionEnabled("record"))
        precondition(changed.isActionEnabled("cancel"))

        do {
            try changed.setShortcut("P", forToolID: "line")
            fatalError("Duplicate shortcut was accepted")
        } catch Configuration.ShortcutError.duplicateKey(existingToolID: "pencil") {}
        do {
            try changed.setShortcut("f", forToolID: "line")
            fatalError("Duplicate pin shortcut was accepted")
        } catch Configuration.ShortcutError.duplicateKey(existingToolID: "pin") {}
        do {
            try changed.setShortcut("ab", forToolID: "line")
            fatalError("Multi-character shortcut was accepted")
        } catch Configuration.ShortcutError.invalidKey {}

        try changed.setShortcut("8", forToolID: "line")
        try changed.setShortcut(nil, forToolID: "spotlight")
        changed.setColor(NSColor(deviceRed: 0.3, green: 0.4, blue: 0.5, alpha: 0.75),
                         for: .accent)
        changed.save(to: defaults)
        let restored = Configuration.load(from: UserDefaults(suiteName: suiteName)!)
        precondition(restored == changed.normalized())
        precondition(restored.shortcut(forToolID: "line") == "8")
        precondition(restored.shortcut(forToolID: "spotlight") == nil)
        precondition(restored.accentColor.alphaComponent > 0.70)

        // Malformed storage cannot enable unknown controls, duplicate keys or
        // remove the two controls needed to escape a screenshot.
        var malformed = restored
        malformed.enabledToolIDs = ["unknown"]
        malformed.enabledActionIDs = ["unknown"]
        malformed.shortcuts["line"] = "p"
        malformed.backgroundHex = "not-a-color"
        malformed.save(to: defaults)
        let recovered = Configuration.load(from: defaults)
        precondition(recovered.enabledToolIDs == ["select"])
        precondition(recovered.enabledActionIDs == ["cancel"])
        precondition(recovered.shortcuts["line"] == nil)
        precondition(recovered.backgroundHex == Configuration.default.backgroundHex)
        let legacySuite = "ClipyToolbarLegacyTest.\(UUID().uuidString)"
        let legacyDefaults = UserDefaults(suiteName: legacySuite)!
        defer { legacyDefaults.removePersistentDomain(forName: legacySuite) }
        Configuration.default.save(to: legacyDefaults)
        legacyDefaults.set([1011, 1013, 1005], forKey: "enabledActions")
        var expanded = Configuration.default
        expanded.enabledToolIDs = Configuration.toolIDs
        expanded.save(to: legacyDefaults)
        let migrated = Configuration.load(from: legacyDefaults)
        precondition(Set(migrated.enabledToolIDs) == Set(["select"] + Configuration.legacyMainToolIDs))
        precondition(!migrated.isActionEnabled("beautify"))
        precondition(migrated.isActionEnabled("invertColors"))
        var customized = migrated
        customized.setActionEnabled(false, id: "invertColors")
        customized.save(to: legacyDefaults)
        precondition(!Configuration.load(from: legacyDefaults).isActionEnabled("invertColors"))
        let legacyToolsSuite = "ClipyToolbarLegacyTools.\(UUID().uuidString)"
        let legacyToolsDefaults = UserDefaults(suiteName: legacyToolsSuite)!
        defer { legacyToolsDefaults.removePersistentDomain(forName: legacyToolsSuite) }
        legacyToolsDefaults.set([0, 2, 9], forKey: "enabledTools")
        let migratedTools = Configuration.load(from: legacyToolsDefaults)
        precondition(Set(migratedTools.enabledToolIDs) == Set(["select", "pencil", "arrow", "pixelate"]))

        let oldSuite = "ClipyToolbarOldShortcuts.\(UUID().uuidString)"
        let oldDefaults = UserDefaults(suiteName: oldSuite)!
        defer { oldDefaults.removePersistentDomain(forName: oldSuite) }
        oldDefaults.set([
            "marker": "z", "censor": "", "measure": "2",
            "moveSelection": "6", "openInEditor": "j", "pin": "k",
            "copy": "y", "beautify": "3"
        ], forKey: "overlayToolShortcuts")
        let imported = Configuration.load(from: oldDefaults)
        precondition(imported.toolID(forShortcut: "z") == "highlighter")
        precondition(imported.shortcut(forToolID: "pixelate") == nil)
        precondition(imported.toolID(forShortcut: "2") == "ruler")
        precondition(imported.actionID(forShortcut: "6") == "move")
        precondition(imported.actionID(forShortcut: "j") == "editor")
        precondition(imported.actionID(forShortcut: "k") == "pin")
        precondition(imported.actionID(forShortcut: "y") == "copy")
        precondition(imported.actionID(forShortcut: "3") == "beautify")
        precondition(imported.actionID(forShortcut: "f") == nil)
        var editedImport = imported
        try editedImport.setShortcut("8", forToolID: "line")
        do {
            try editedImport.setShortcut("k", forActionID: "copy")
            fatalError("Duplicate action shortcut was accepted")
        } catch Configuration.ShortcutError.duplicateKey(existingToolID: "pin") {}
        try editedImport.setShortcut(" ", forActionID: "copy")
        precondition(editedImport.actionID(forShortcut: " ") == "copy")
        try editedImport.setShortcut(nil, forActionID: "copy")
        precondition(editedImport.shortcut(forActionID: "copy") == nil)
        do {
            try editedImport.setShortcut("!", forActionID: "copy")
            fatalError("Invalid action shortcut was accepted")
        } catch Configuration.ShortcutError.invalidKey {}
        editedImport.save(to: oldDefaults)
        precondition(Configuration.load(from: oldDefaults) == editedImport.normalized())

        // Existing independent-build customizations outrank old saved keys.
        let mixedSuite = "ClipyToolbarMixedShortcuts.\(UUID().uuidString)"
        let mixedDefaults = UserDefaults(suiteName: mixedSuite)!
        defer { mixedDefaults.removePersistentDomain(forName: mixedSuite) }
        var independentlyEdited = Configuration.default
        independentlyEdited.shortcuts = [
            "select": "q", "pencil": "p", "line": "z", "arrow": "a",
            "rectangle": "r", "filledRectangle": "v", "ellipse": "e",
            "highlighter": "h", "richText": "t", "number": "n",
            "stamp": "s", "pixelate": "m", "blur": "b",
            "solidCensor": "x", "eraseCensor": "d", "magnifier": "g",
            "ruler": "u", "colorSampler": "c", "spotlight": "o"
        ]
        independentlyEdited.shortcuts.removeValue(forKey: "number")
        independentlyEdited.save(to: mixedDefaults)
        mixedDefaults.set(["pencil": "z", "number": "4", "marker": "v"],
                          forKey: "overlayToolShortcuts")
        let mixed = Configuration.load(from: mixedDefaults)
        precondition(mixed.toolID(forShortcut: "z") == "line")
        precondition(mixed.toolID(forShortcut: "p") == "pencil")
        precondition(mixed.shortcut(forToolID: "number") == nil)
        precondition(mixed.toolID(forShortcut: "v") == "highlighter")
        let rightSuite = "ClipyToolbarLegacyRightActions.\(UUID().uuidString)"
        let rightDefaults = UserDefaults(suiteName: rightSuite)!
        defer { rightDefaults.removePersistentDomain(forName: rightSuite) }
        var previousAllActions = Configuration.default
        previousAllActions.enabledActionIDs = Configuration.actionIDs
        previousAllActions.save(to: rightDefaults)
        let compactActions = Configuration.load(from: rightDefaults)
        precondition(!compactActions.isActionEnabled("qrCode"))
        precondition(!compactActions.isActionEnabled("autoRedact"))
        var optedIn = compactActions
        optedIn.setActionEnabled(true, id: "qrCode")
        optedIn.save(to: rightDefaults)
        precondition(Configuration.load(from: rightDefaults).isActionEnabled("qrCode"))

        let colorSuite = "ClipyToolbarLegacyColors.\(UUID().uuidString)"
        let colorDefaults = UserDefaults(suiteName: colorSuite)!
        defer { colorDefaults.removePersistentDomain(forName: colorSuite) }
        var earlier = Configuration.default
        earlier.backgroundHex = "#20242CEB"
        earlier.save(to: colorDefaults)
        func archive(_ color: NSColor) -> Data {
            try! NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false)
        }
        colorDefaults.set(archive(NSColor(deviceRed: 0.2, green: 0.3, blue: 0.4, alpha: 1)),
                          forKey: "toolbarBgColor")
        colorDefaults.set(archive(NSColor(deviceRed: 0.9, green: 0.8, blue: 0.7, alpha: 1)),
                          forKey: "toolbarIconColor")
        colorDefaults.set(archive(NSColor(deviceRed: 0.1, green: 0.6, blue: 0.9, alpha: 1)),
                          forKey: "toolbarAccentColor")
        let legacyColors = Configuration.load(from: colorDefaults)
        precondition(legacyColors.backgroundHex == "#334D66FF")
        precondition(legacyColors.iconHex == "#E6CCB3FF")
        precondition(legacyColors.accentHex == "#1A99E6FF")
        var customColors = legacyColors
        customColors.backgroundHex = "#112233FF"
        customColors.save(to: colorDefaults)
        precondition(Configuration.load(from: colorDefaults).backgroundHex == "#112233FF")

        defaults.set(Data("invalid JSON".utf8), forKey: Configuration.storageKey)
        precondition(Configuration.load(from: defaults) == .default)

        print("NativeScreenshotToolbarConfigurationRegression passed")
    }
}
