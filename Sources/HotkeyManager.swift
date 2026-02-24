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
        DevLog.shared.info("Hotkey", "快捷键初始化，\(store.hotkeyBindings.count) 个绑定")
    }

    func rebindHotkeys() {
        unregisterAll()
        guard let store, store.hotkeyEnabled else { return }

        // Register per-project bindings
        for dept in store.departments {
            guard let binding = store.hotkeyBindings[dept],
                  let deptIndex = store.departments.firstIndex(of: dept) else { continue }
            let hotKeyID = EventHotKeyID(signature: OSType(0x5453_5448), id: UInt32(deptIndex))
            var hotKeyRef: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(binding.keyCode), binding.carbonModifiers,
                                             hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
            if status == noErr, let ref = hotKeyRef {
                hotKeyRefs.append(ref)
            }
        }

        // Quick note: first bound department's modifiers + 0, fallback ⌃⇧
        let noteModifiers: UInt32 = store.departments
            .compactMap { store.hotkeyBindings[$0]?.carbonModifiers }
            .first ?? (UInt32(controlKey) | UInt32(shiftKey))
        let noteID = EventHotKeyID(signature: OSType(0x5453_5448), id: 100)
        var noteRef: EventHotKeyRef?
        if RegisterEventHotKey(0x1D, noteModifiers, noteID, GetApplicationEventTarget(), 0, &noteRef) == noErr, let ref = noteRef {
            hotKeyRefs.append(ref)
        }
        DevLog.shared.info("Hotkey", "注册 \(store.hotkeyBindings.count) 个快捷键 + 快速日报")
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
        guard let store else { return }
        if index == 100 {
            guard store.dailyNoteEnabled else { return }
            QuickNotePanel.shared.toggle(store: store)
            DevLog.shared.info("Hotkey", "快速日报面板")
            return
        }
        guard index < store.departments.count else { return }
        let dept = store.departments[index]
        store.increment(dept)
        DevLog.shared.info("Hotkey", "\(dept) +1")
    }

    func unregisterAll() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

}
