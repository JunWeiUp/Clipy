import AppKit
import Carbon

class HotKeyManager {
    static let shared = HotKeyManager()

    /// The Carbon handler fires on the main run loop while register/unregister
    /// can be driven from a background save, so both maps are lock-guarded.
    private let lock = NSLock()
    private var hotkeys: [UInt32: () -> Void] = [:]
    private var hotkeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var registeredKeyCodes: [UInt32: Int] = [:]
    private var registeredModifiers: [UInt32: UInt32] = [:]
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
        // Carbon's registration APIs are tied to the application event loop.
        // Preference/snippet saves can arrive from a background queue, so never
        // call RegisterEventHotKey or UnregisterEventHotKey off the main thread.
        if !Thread.isMainThread {
            var result = false
            DispatchQueue.main.sync {
                result = self.register(keyCode: keyCode, modifiers: modifiers, id: id, action: action)
            }
            return result
        }

        var carbonModifiers: UInt32 = 0
        let modifierFlags = NSEvent.ModifierFlags(rawValue: modifiers)
        if modifierFlags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if modifierFlags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if modifierFlags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if modifierFlags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }

        // A notification can ask all shortcuts to be registered even when this
        // shortcut did not change. Keep the existing Carbon registration in that
        // case so there is no unregister/register gap in which a key press can be
        // lost. Updating the closure is enough to pick up the latest state.
        lock.lock()
        let alreadyRegistered = hotkeyRefs[id] != nil
            && registeredKeyCodes[id] == keyCode
            && registeredModifiers[id] == carbonModifiers
        if alreadyRegistered {
            hotkeys[id] = action
            lock.unlock()
            return true
        }
        let previous = hotkeyRefs[id].map {
            (ref: $0, keyCode: registeredKeyCodes[id] ?? keyCode,
             modifiers: registeredModifiers[id] ?? carbonModifiers,
             action: hotkeys[id])
        }
        lock.unlock()

        // An EventHotKeyID cannot be registered twice. Remove only a changed
        // registration before trying the replacement. The previous definition
        // is retained so it can be restored if Carbon rejects the new combo.
        if let previous { UnregisterEventHotKey(previous.ref) }

        let hotKeyID = EventHotKeyID(signature: OSType(0x434C5059), id: id) // 'CLPY'
        var hotKeyRef: EventHotKeyRef?

        // Claim the combo exclusively so apps launched later cannot register the
        // same shortcut. If another app already holds it, macOS splits key
        // presses between the two owners (the shortcut appears to need two
        // presses), so log the conflict and fall back to a shared registration.
        var status = RegisterEventHotKey(UInt32(keyCode),
                                        carbonModifiers,
                                        hotKeyID,
                                        GetApplicationEventTarget(),
                                        OptionBits(kEventHotKeyExclusive),
                                        &hotKeyRef)
        if status == OSStatus(eventHotKeyExistsErr) {
            appLog("HotKeyManager: shortcut for id \(id) (keyCode=\(keyCode) modifiers=\(carbonModifiers)) is already registered by another app; presses may be delivered to that app instead", level: .warning)
            status = RegisterEventHotKey(UInt32(keyCode),
                                         carbonModifiers,
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &hotKeyRef)
        }

        if status == noErr, let ref = hotKeyRef {
            lock.lock()
            hotkeys[id] = action
            hotkeyRefs[id] = ref
            registeredKeyCodes[id] = keyCode
            registeredModifiers[id] = carbonModifiers
            lock.unlock()
            return true
        } else {
            appLog("HotKeyManager: RegisterEventHotKey failed for id \(id) (\(status))", level: .warning)
            if let previous, let oldAction = previous.action {
                var restoredRef: EventHotKeyRef?
                let restoreStatus = RegisterEventHotKey(
                    UInt32(previous.keyCode), previous.modifiers, hotKeyID,
                    GetApplicationEventTarget(), 0, &restoredRef)
                if restoreStatus == noErr, let restoredRef {
                    lock.lock()
                    hotkeys[id] = oldAction
                    hotkeyRefs[id] = restoredRef
                    registeredKeyCodes[id] = previous.keyCode
                    registeredModifiers[id] = previous.modifiers
                    lock.unlock()
                }
            } else {
                lock.lock()
                hotkeys.removeValue(forKey: id)
                hotkeyRefs.removeValue(forKey: id)
                registeredKeyCodes.removeValue(forKey: id)
                registeredModifiers.removeValue(forKey: id)
                lock.unlock()
            }
            return false
        }
    }

    func unregister(id: UInt32) {
        if !Thread.isMainThread {
            DispatchQueue.main.sync { [weak self] in self?.unregister(id: id) }
            return
        }
        lock.lock()
        let ref = hotkeyRefs.removeValue(forKey: id)
        hotkeys.removeValue(forKey: id)
        registeredKeyCodes.removeValue(forKey: id)
        registeredModifiers.removeValue(forKey: id)
        lock.unlock()
        if let ref { UnregisterEventHotKey(ref) }
    }

    func unregisterAll() {
        if !Thread.isMainThread {
            DispatchQueue.main.sync { [weak self] in self?.unregisterAll() }
            return
        }
        lock.lock()
        let refs = Array(hotkeyRefs.values)
        hotkeyRefs.removeAll()
        hotkeys.removeAll()
        registeredKeyCodes.removeAll()
        registeredModifiers.removeAll()
        lock.unlock()
        for ref in refs {
            UnregisterEventHotKey(ref)
        }
    }
}
