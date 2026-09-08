import AppKit
import Carbon

class HotKeyManager {
    static let shared = HotKeyManager()

    /// The Carbon handler fires on the main run loop while register/unregister
    /// can be driven from a background save, so both maps are lock-guarded.
    private let lock = NSLock()
    private var hotkeys: [UInt32: () -> Void] = [:]
    private var hotkeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?

    private init() {
        setupEventHandler()
    }

    private func setupEventHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let ptr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        let status = InstallEventHandler(GetApplicationEventTarget(), { (nextHandler, event, userData) -> OSStatus in
            guard let event = event, let userData = userData else { return OSStatus(eventNotHandledErr) }

            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                         EventParamName(kEventParamDirectObject),
                                         EventParamType(typeEventHotKeyID),
                                         nil,
                                         MemoryLayout<EventHotKeyID>.size,
                                         nil,
                                         &hotKeyID)

            if status == noErr {
                // Copy the action out before invoking it: running user code while
                // holding the lock would deadlock any re-registration it triggers.
                if let action = manager.action(for: hotKeyID.id) {
                    action()
                    return OSStatus(noErr)
                }
            }

            return CallNextEventHandler(nextHandler, event)
        }, 1, &eventType, ptr, &eventHandler)

        if status != noErr {
            appLog("HotKeyManager: failed to install event handler (\(status))", level: .error)
        }
    }

    private func action(for id: UInt32) -> (() -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return hotkeys[id]
    }

    @discardableResult
    func register(keyCode: Int, modifiers: UInt, id: UInt32, action: @escaping () -> Void) -> Bool {
        unregister(id: id)

        var carbonModifiers: UInt32 = 0
        let modifierFlags = NSEvent.ModifierFlags(rawValue: modifiers)
        if modifierFlags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if modifierFlags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if modifierFlags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if modifierFlags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }

        let hotKeyID = EventHotKeyID(signature: OSType(0x434C5059), id: id) // 'CLPY'
        var hotKeyRef: EventHotKeyRef?

        let status = RegisterEventHotKey(UInt32(keyCode),
                                        carbonModifiers,
                                        hotKeyID,
                                        GetApplicationEventTarget(),
                                        0,
                                        &hotKeyRef)

        if status == noErr, let ref = hotKeyRef {
            lock.lock()
            hotkeys[id] = action
            hotkeyRefs[id] = ref
            lock.unlock()
            return true
        } else {
            appLog("HotKeyManager: RegisterEventHotKey failed for id \(id) (\(status))", level: .warning)
            return false
        }
    }

    func unregister(id: UInt32) {
        lock.lock()
        let ref = hotkeyRefs.removeValue(forKey: id)
        hotkeys.removeValue(forKey: id)
        lock.unlock()
        if let ref { UnregisterEventHotKey(ref) }
    }

    func unregisterAll() {
        lock.lock()
        let refs = Array(hotkeyRefs.values)
        hotkeyRefs.removeAll()
        hotkeys.removeAll()
        lock.unlock()
        for ref in refs {
            UnregisterEventHotKey(ref)
        }
    }
}
