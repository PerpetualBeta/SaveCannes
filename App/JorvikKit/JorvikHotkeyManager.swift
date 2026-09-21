import AppKit
import Carbon.HIToolbox

/// Registers global hotkeys through Carbon's `RegisterEventHotKey`.
///
/// Carbon is the only way to install a system-wide hotkey from an app that is
/// neither a login item nor an accessibility client. That last part is the
/// point: a CGEvent tap does the same job but needs Accessibility, which is the
/// right to read every keystroke on the machine. An app whose only reason to
/// ask for that would be a hotkey should use this instead.
///
/// Not every app can. ScreenLock taps deliberately, matching modifiers with
/// `contains` rather than `==` so a HyperCaps hyper-key press still triggers
/// it, which Carbon's exact matching cannot express. Apps doing window work
/// hold Accessibility anyway, so a tap costs them nothing extra. The estate
/// runs both mechanisms on purpose; what it should not run is five copies of
/// this one, which is what it had until 2026-09-21.
///
/// Deliberately knows nothing about storage. Apps keep a `HotkeyConfig` in
/// `HotkeyStore`, or a pair of `AppStorage` ints, or anything else, and hand
/// over a key code and modifiers.
final class JorvikHotkeyManager {

    /// Four-character code identifying this app's hotkeys to Carbon. Distinct
    /// per app so two Jorvik apps registering the same slot id cannot collide.
    private let signature: OSType

    private struct Registered {
        let ref: EventHotKeyRef
        let handler: () -> Void
        /// Kept so a suspended hotkey can be registered again unchanged.
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags
    }

    /// Keyed by the caller's slot id. Apps usually back this with an enum;
    /// this type only needs the raw value to be stable across registrations.
    private var slots: [UInt32: Registered] = [:]
    /// What was registered before recording suspended it.
    private var suspendedSlots: [UInt32: Registered] = [:]
    private var eventHandler: EventHandlerRef?

    init(signature: OSType) {
        self.signature = signature
        installEventHandler()
    }

    deinit {
        if let h = eventHandler { RemoveEventHandler(h) }
        for (_, r) in slots { UnregisterEventHotKey(r.ref) }
        for (_, r) in suspendedSlots { UnregisterEventHotKey(r.ref) }
    }

    // MARK: - Registration

    /// Installs a hotkey for a slot, replacing whatever that slot held.
    ///
    /// An empty key code and no modifiers removes the slot, which is how an
    /// unset shortcut is expressed.
    func register(keyCode: UInt16,
                  modifiers: NSEvent.ModifierFlags,
                  slot: UInt32,
                  handler: @escaping () -> Void) {
        if let prev = slots.removeValue(forKey: slot) {
            UnregisterEventHotKey(prev.ref)
        }
        let clean = modifiers.intersection(.deviceIndependentFlagsMask)
        guard keyCode != 0 || !clean.isEmpty else { return }

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: slot)
        let status = RegisterEventHotKey(UInt32(keyCode),
                                         carbonModifiers(from: clean),
                                         id,
                                         GetEventDispatcherTarget(),
                                         0,
                                         &ref)
        guard status == noErr, let ref else { return }
        slots[slot] = Registered(ref: ref, handler: handler,
                                 keyCode: keyCode, modifiers: clean)
    }

    func unregister(slot: UInt32) {
        if let prev = slots.removeValue(forKey: slot) {
            UnregisterEventHotKey(prev.ref)
        }
    }

    /// Unregisters every hotkey while a shortcut recorder is listening, and
    /// puts them back afterwards.
    ///
    /// Carbon hands a registered hotkey to its handler before the keystroke
    /// reaches the app, so without this the shortcut already set fires the
    /// action instead of being recorded, and can never be changed because the
    /// recorder never sees the keys. Driven by `JorvikShortcutRecorder`'s
    /// `onRecordingChanged`.
    func setRecordingSuspended(_ suspended: Bool) {
        if suspended {
            guard suspendedSlots.isEmpty else { return }
            for (_, r) in slots { UnregisterEventHotKey(r.ref) }
            suspendedSlots = slots
            slots = [:]
        } else {
            let restore = suspendedSlots
            suspendedSlots = [:]
            for (slot, r) in restore {
                register(keyCode: r.keyCode, modifiers: r.modifiers,
                         slot: slot, handler: r.handler)
            }
        }
    }

    // MARK: - Carbon plumbing

    private func installEventHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(),
                            { (_: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?) in
                                guard let event, let userData else { return noErr }
                                let me = Unmanaged<JorvikHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                                var hkID = EventHotKeyID()
                                GetEventParameter(event,
                                                  EventParamName(kEventParamDirectObject),
                                                  EventParamType(typeEventHotKeyID),
                                                  nil,
                                                  MemoryLayout<EventHotKeyID>.size,
                                                  nil,
                                                  &hkID)
                                if let reg = me.slots[hkID.id] {
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
