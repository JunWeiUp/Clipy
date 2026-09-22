import AppKit
import Carbon

protocol SmartSwitchInputSources {
    var currentID: String? { get }
    func select(_ id: String) -> Bool
}

private struct SmartSwitchSystemInputSources: SmartSwitchInputSources {
    var currentID: String? {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    func select(_ id: String) -> Bool {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        let sources = TISCreateInputSourceList(filter, false).takeRetainedValue() as! [TISInputSource]
        guard let source = sources.first else { return false }
        return TISSelectInputSource(source) == noErr
    }
}

/// A scoped input-source change. Never overwrite a subsequent manual choice.
final class SmartSwitchInputSourceSession {
    static let doubaoID = "com.bytedance.inputmethod.doubaoime.pinyin"
    private let sources: SmartSwitchInputSources
    private var previous: String?
    private var didChange = false

    init(sources: SmartSwitchInputSources? = nil) {
        self.sources = sources ?? SmartSwitchSystemInputSources()
    }

    func selectDoubao() -> Bool {
        let current = sources.currentID
        if current == Self.doubaoID { return true }
        guard sources.select(Self.doubaoID) else { return false }
        if !didChange { previous = current }
        didChange = true
        return true
    }

    func restore() {
        defer { previous = nil; didChange = false }
        guard didChange, let previous,
              sources.currentID == Self.doubaoID else { return }
        _ = sources.select(previous)
    }
}

@MainActor
protocol SmartSwitchLaunching {
    /// Launch in the background first. The caller checks its generation before activation.
    func prepare(_ target: SmartSwitchTarget) async throws -> () -> Bool
}

@MainActor
struct SmartSwitchApplicationLauncher: SmartSwitchLaunching {
    static func applicationURL(for target: SmartSwitchTarget,
                               lookup: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) throws -> URL {
        let saved = URL(fileURLWithPath: target.applicationPath)
        for url in [saved, lookup(target.bundleIdentifier)].compactMap({ $0 }) {
            guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url),
                  bundle.bundleIdentifier == target.bundleIdentifier,
                  let executable = bundle.executableURL,
                  FileManager.default.fileExists(atPath: executable.path) else { continue }
            return url
        }
        throw SmartSwitchError.applicationMissing
    }

    func prepare(_ target: SmartSwitchTarget) async throws -> () -> Bool {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleIdentifier)
            .first(where: { !$0.isTerminated }) {
            return { running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) }
        }
        let url = try Self.applicationURL(for: target)
        let options = NSWorkspace.OpenConfiguration()
        options.activates = false
        let running: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: options) { app, error in
                if let app { continuation.resume(returning: app) }
                else { continuation.resume(throwing: SmartSwitchError.activationFailed) }
            }
        }
        return { running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) }
    }
}

enum SmartSwitchGlobalHotKeyManager {
    private static let id: UInt32 = 0x5357_4954 // 'SWIT'
    private(set) static var registrationFailed = false

    @discardableResult
    static func register() -> Bool {
        let config = SmartSwitchStore.shared.configuration
        guard config.shortcutEnabled, let combo = config.shortcut else {
            HotKeyManager.shared.unregister(id: id)
            registrationFailed = false
            return true
        }
        let result = HotKeyManager.shared.register(keyCode: combo.keyCode, modifiers: combo.modifierFlags, id: id) {
            DispatchQueue.main.async { SmartSwitchWindow.shared.show() }
        }
        registrationFailed = !result
        NotificationCenter.default.post(name: .smartSwitchShortcutChanged, object: nil)
        return result
    }
}

extension Notification.Name {
    static let smartSwitchShortcutChanged = Notification.Name("smartSwitchShortcutChanged")
}
