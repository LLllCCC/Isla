import AppKit
import Carbon.HIToolbox

/// 全局快捷键 ⌥⌘Space。用 Carbon 的 RegisterEventHotKey，不需要辅助功能权限。
final class HotkeyService {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onTrigger: (() -> Void)?

    @discardableResult
    func register(_ action: @escaping () -> Void) -> Bool {
        onTrigger = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let svc = Unmanaged<HotkeyService>.fromOpaque(userData).takeUnretainedValue()
            svc.onTrigger?()
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)

        guard installStatus == noErr else { return false }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D49_534C), id: 1) // 'MISL'
        let registerStatus = RegisterEventHotKey(UInt32(kVK_Space),
                                                 UInt32(cmdKey | optionKey),
                                                 hotKeyID,
                                                 GetApplicationEventTarget(),
                                                 0,
                                                 &hotKeyRef)
        return registerStatus == noErr
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
}
