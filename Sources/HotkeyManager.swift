import Cocoa
import Carbon

@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var store: DataStore?
    private var eventHandler: EventHandlerRef?

    func setup(store: DataStore) {
        self.store = store
        installCarbonHandler()
        rebindHotkeys()
    }

    func rebindHotkeys() {
        unregisterAll()
        guard let store else { return }
        let count = min(store.departments.count, 9)
        let keyCodes: [UInt32] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19]
        let modifiers: UInt32 = store.currentCarbonFlags
        for i in 0..<count {
            let hotKeyID = EventHotKeyID(signature: OSType(0x5453_5448), id: UInt32(i))
            var hotKeyRef: EventHotKeyRef?
            let status = RegisterEventHotKey(keyCodes[i], modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
            if status == noErr, let ref = hotKeyRef {
                hotKeyRefs.append(ref)
            }
        }
    }

    private func installCarbonHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            mgr.handleHotkey(index: Int(hotKeyID.id))
            return noErr
        }, 1, &eventType, selfPtr, &eventHandler)
    }

    private func handleHotkey(index: Int) {
        guard let store, index < store.departments.count else { return }
        store.increment(store.departments[index])
    }

    private func unregisterAll() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

}
