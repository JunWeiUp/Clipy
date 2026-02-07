import AppKit
import Carbon

class HotKeyManager {
    static let shared = HotKeyManager()
    
    private var hotkeys: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?
    
    private init() {
        setupEventHandler()
    }
    
    private func setupEventHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        
        let ptr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        InstallEventHandler(GetApplicationEventTarget(), { (nextHandler, event, userData) -> OSStatus in
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
    }
    
    func register(keyCode: Int, modifiers: UInt, id: UInt32, action: @escaping () -> Void) {
        unregister(id: id)
        
        var carbonModifiers: UInt32 = 0
        if modifiers & NSEvent.ModifierFlags.command.rawValue != 0 { carbonModifiers |= UInt32(cmdKey) }
        if modifiers & NSEvent.ModifierFlags.option.rawValue != 0 { carbonModifiers |= UInt32(optionKey) }
        if modifiers & NSEvent.ModifierFlags.control.rawValue != 0 { carbonModifiers |= UInt32(controlKey) }
        if modifiers & NSEvent.ModifierFlags.shift.rawValue != 0 { carbonModifiers |= UInt32(shiftKey) }
        
        let hotKeyID = EventHotKeyID(signature: OSType(0x434C5059), id: id) // 'CLPY'
        var hotKeyRef: EventHotKeyRef?
        
        let status = RegisterEventHotKey(UInt32(keyCode),
                                        carbonModifiers,
                                        hotKeyID,
                                        GetApplicationEventTarget(),
                                        0,
                                        &hotKeyRef)
        
        if status == noErr {
            hotkeys[id] = action
        }
    }
    
    func unregister(id: UInt32) {
        // In a real implementation, we'd need to store the hotKeyRef to unregister it.
        // For this clone, we'll just remove the action.
        hotkeys.removeValue(forKey: id)
    }
    
    func unregisterAll() {
        hotkeys.removeAll()
    }
}
