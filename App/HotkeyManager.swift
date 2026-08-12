import AppKit
import Carbon.HIToolbox

/// Registers global hotkeys via Carbon's `RegisterEventHotKey`. Carbon is
/// still the only documented path to a system-wide hotkey from an app that
/// isn't an accessibility client, so the Swift surface stays small and wraps
/// it cleanly.
///
/// Single instance owned by AppDelegate. Call `register(_:slot:handler:)` to
/// install a binding for a slot; calling again with the same slot replaces.
/// An unset binding removes.
final class HotkeyManager {

    /// Slot identifiers, stable so re-registrations supersede cleanly. Each
    /// slot also names its own pair of UserDefaults keys, which is what the
    /// recorders in Settings write to.
    enum Slot: UInt32, CaseIterable {
        case activate   = 1
        case screenshot = 2

        var name: String {
            switch self {
            case .activate:   return "activate"
            case .screenshot: return "screenshot"
            }
        }
        var keyCodeKey: String   { "\(name)KeyCode" }
        var modifiersKey: String { "\(name)Modifiers" }
    }

    private struct Registered {
        let ref: EventHotKeyRef
        let handler: () -> Void
    }
    private var slots: [Slot: Registered] = [:]
    private var eventHandler: EventHandlerRef?

    init() {
        installEventHandler()
    }

    deinit {
        if let h = eventHandler { RemoveEventHandler(h) }
        for (_, r) in slots { UnregisterEventHotKey(r.ref) }
    }

    func register(_ binding: HotkeyBinding, slot: Slot, handler: @escaping () -> Void) {
        // Remove any previous registration for this slot first.
        if let prev = slots.removeValue(forKey: slot) {
            UnregisterEventHotKey(prev.ref)
        }
        guard !binding.isUnset else { return }

        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x53434E53),  // 'SCNS'
                                     id: slot.rawValue)
        let status = RegisterEventHotKey(UInt32(binding.keyCode),
                                        carbonModifiers(from: binding.modifiers),
                                        hotKeyID,
                                        GetEventDispatcherTarget(),
                                        0,
                                        &hotKeyRef)
        guard status == noErr, let ref = hotKeyRef else {
            scLog("HotkeyManager: register failed status=\(status) slot=\(slot.name)")
            return
        }
        slots[slot] = Registered(ref: ref, handler: handler)
        scLog("HotkeyManager: registered \(slot.name) → \(binding.displayString)")
    }

    // MARK: - Carbon plumbing

    private func installEventHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(),
                            { (_: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?) in
                                guard let event = event, let userData = userData else { return noErr }
                                let me = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                                var hkID = EventHotKeyID()
                                GetEventParameter(event,
                                                  EventParamName(kEventParamDirectObject),
                                                  EventParamType(typeEventHotKeyID),
                                                  nil,
                                                  MemoryLayout<EventHotKeyID>.size,
                                                  nil,
                                                  &hkID)
                                if let slot = Slot(rawValue: hkID.id),
                                   let reg = me.slots[slot] {
                                    DispatchQueue.main.async { reg.handler() }
                                }
                                return noErr
                            },
                            1,
                            &spec,
                            context,
                            &eventHandler)
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        return m
    }
}

/// One slot's persisted shortcut.
///
/// Emptiness is tested on the modifier set, never on the key code: key code 0
/// is a real key ("A"), so a zero there means nothing. `JorvikShortcutRecorder`
/// refuses to record a shortcut without at least one modifier, which makes an
/// empty modifier set the reliable "no shortcut set" signal.
struct HotkeyBinding {
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags

    var isUnset: Bool { modifiers.isEmpty }

    var displayString: String {
        isUnset ? "" : JorvikShortcutPanel.displayString(keyCode: keyCode, modifiers: modifiers)
    }

    static func read(_ slot: HotkeyManager.Slot) -> HotkeyBinding {
        let defs = UserDefaults.standard
        return HotkeyBinding(
            keyCode: UInt16(truncatingIfNeeded: defs.integer(forKey: slot.keyCodeKey)),
            modifiers: NSEvent.ModifierFlags(
                rawValue: UInt(bitPattern: defs.integer(forKey: slot.modifiersKey)))
        )
    }
}
