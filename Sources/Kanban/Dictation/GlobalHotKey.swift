import Carbon.HIToolbox
import Foundation

/// A system-wide hotkey through Carbon's `RegisterEventHotKey`.
///
/// Carbon is still the only permission-free way to register a global shortcut:
/// no Accessibility grant, unlike an event tap. The trade-off is press-only —
/// there is no key-up — so dictation toggles rather than holding to talk.
final class GlobalHotKey {

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var action: (() -> Void)?

    deinit { unregister() }

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32,
                  action: @escaping () -> Void) -> Bool {
        unregister()
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { hotKey.action?() }
                return noErr
            },
            1, &eventType, context, &handlerRef)
        guard installed == noErr else { return false }

        let identifier = EventHotKeyID(signature: OSType(0x4B42_444B), id: 1)   // 'KBDK'
        let registered = RegisterEventHotKey(
            keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registered == noErr else {
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        action = nil
    }
}
