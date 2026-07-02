import AppKit
import Carbon

class HotKeyManager {
    static let shared = HotKeyManager()
    
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
                if let action = manager.hotkeys[hotKeyID.id] {
                    action()
                    return OSStatus(noErr)
                }
            }
            
            return CallNextEventHandler(nextHandler, event)
        }, 1, &eventType, ptr, &eventHandler)
        
        if status != noErr {
            print("Failed to install event handler: \(status)")
        }
    }
    
    func register(keyCode: Int, modifiers: UInt, id: UInt32, action: @escaping () -> Void) {
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
            hotkeys[id] = action
            hotkeyRefs[id] = ref
        }
    }
    
    func unregister(id: UInt32) {
        if let ref = hotkeyRefs[id] {
            UnregisterEventHotKey(ref)
            hotkeyRefs.removeValue(forKey: id)
        }
        hotkeys.removeValue(forKey: id)
    }
    
    func unregisterAll() {
        for ref in hotkeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        hotkeyRefs.removeAll()
        hotkeys.removeAll()
    }
}
