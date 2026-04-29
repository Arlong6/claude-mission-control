import Foundation
import Carbon.HIToolbox
import AppKit

/// Registers a system-wide hotkey via Carbon Events.
/// macOS will trigger the handler regardless of which app is frontmost.
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    private var hotKeyRef: EventHotKeyRef?
    private var handler: (() -> Void)?
    private static let signature: OSType = 0x4D43544C // 'MCTL'

    /// Register ⌘⇧M (the only hotkey we use today).
    func registerCmdShiftM(handler: @escaping () -> Void) {
        unregister()
        self.handler = handler

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, userData) -> OSStatus in
            guard let userData, let event else { return noErr }
            let me = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
            var hkID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hkID)
            DispatchQueue.main.async { me.handler?() }
            return noErr
        }, 1, &spec, selfPtr, nil)

        let hkID = EventHotKeyID(signature: Self.signature, id: 1)
        var ref: EventHotKeyRef?
        let modifiers = UInt32(cmdKey | shiftKey)
        let keyCode = UInt32(kVK_ANSI_M)
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRef = ref
        } else {
            NSLog("MissionControl: failed to register ⌘⇧M hotkey, status=\(status)")
        }
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    deinit { unregister() }
}
