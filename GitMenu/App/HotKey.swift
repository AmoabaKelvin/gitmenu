import AppKit
import Carbon.HIToolbox

/// System-wide shortcut through Carbon hot keys, which need no accessibility permission.
final class HotKey {
    var onPress: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().onPress?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(_ combo: HotKeyCombo?) {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        guard let combo else { return }
        let flags = NSEvent.ModifierFlags(rawValue: combo.modifiers)
        var mods = 0
        if flags.contains(.command) { mods |= cmdKey }
        if flags.contains(.option) { mods |= optionKey }
        if flags.contains(.control) { mods |= controlKey }
        if flags.contains(.shift) { mods |= shiftKey }
        let id = EventHotKeyID(signature: OSType(0x474D_4E55), id: 1)
        let status = RegisterEventHotKey(UInt32(combo.keyCode), UInt32(mods), id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { logger.error("could not register shortcut \(combo.display): \(status)") }
    }
}
