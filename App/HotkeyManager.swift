import AppKit
import Carbon.HIToolbox

/// Save Cannes's hotkey slots and storage, over the shared
/// `JorvikHotkeyManager`.
///
/// The Carbon plumbing used to live here, and in four other apps, as five
/// hand-maintained copies of the same file. It now lives in JorvikKit; what
/// stays here is the part that is genuinely this app's: which slots exist, the
/// four-character signature that keeps its registrations distinct from its
/// siblings', and the fact that this app stores a shortcut as a pair of
/// UserDefaults ints rather than a `HotkeyConfig`.
extension JorvikHotkeyManager {

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

    /// 'SCNS'.
    static let saveCannesSignature = OSType(0x53434E53)

    /// Registers from a stored binding. An unset binding removes the slot.
    func register(_ binding: HotkeyBinding, slot: Slot, handler: @escaping () -> Void) {
        guard !binding.isUnset else {
            unregister(slot: slot.rawValue)
            return
        }
        register(keyCode: binding.keyCode,
                 modifiers: binding.modifiers,
                 slot: slot.rawValue,
                 handler: handler)
    }
}

/// One slot's persisted shortcut: a key code and a modifier set, in two
/// UserDefaults ints.
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

    static func read(_ slot: JorvikHotkeyManager.Slot) -> HotkeyBinding {
        let defs = UserDefaults.standard
        return HotkeyBinding(
            keyCode: UInt16(truncatingIfNeeded: defs.integer(forKey: slot.keyCodeKey)),
            modifiers: NSEvent.ModifierFlags(
                rawValue: UInt(bitPattern: defs.integer(forKey: slot.modifiersKey)))
        )
    }
}
