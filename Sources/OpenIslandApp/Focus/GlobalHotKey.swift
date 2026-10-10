import Carbon
import FocusCore
import Foundation

@MainActor
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: @MainActor () -> Void

    init(hotKey: BoardHotKey, action: @escaping @MainActor () -> Void) {
        self.action = action
        installHandler()
        update(hotKey)
    }

    func update(_ hotKey: BoardHotKey) {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        let modifiers: UInt32
        switch hotKey {
        case .optionCommandB: modifiers = UInt32(optionKey | cmdKey)
        case .controlOptionB: modifiers = UInt32(controlKey | optionKey)
        case .off: return
        }
        let id = EventHotKeyID(signature: OSType(0x46_4F_43_53), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_B), modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &spec, context, &handlerRef)
    }
}
