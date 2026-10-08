import AppKit
import CoreGraphics

/// The volume and mute keys, and only those, recognised so that they do not
/// dismiss the saver.
///
/// **Why.** The saver came up with the sound too loud, and turning it down
/// ended it (discussion #20, from @christobaldo). macOS changes the volume
/// whichever app is in front, so the press did what was wanted and then cost
/// the saver as well. Measured 2026-10-08: one press of volume down, and the
/// log said "system idle dropped — dismissing" 4.8s after the saver came up.
///
/// **How the press got through.** The window's own monitor watches key-down,
/// and a media key is not a key-down: it arrives as a system-defined event.
/// But the idle tick asks how long it is since ANY input, and that clock is
/// reset by a system-defined event like any other. So the tick dismissed.
///
/// **What this does.** It watches system-defined events and notes when the
/// latest one was a volume or mute key. `AppDelegate.systemIdleSeconds()`
/// then leaves that one event out, but only when it is the most recent
/// system-defined event of all: brightness, play/pause, the Spotlight and
/// dictation keys and the rest still dismiss, as every other input does. Play
/// in particular has to, because it can start music in an app behind the saver.
///
/// **It fails safe.** If the monitor never sees a volume key, nothing is left
/// out and the press dismisses as it always did.
///
/// Not main-actor isolated, because the idle tick that reads it lives in
/// `AppDelegate`, which is not. The one shared value is behind a lock.
final class VolumeKeys: @unchecked Sendable {
    static let shared = VolumeKeys()

    private let lock = NSLock()
    /// When this app last saw a volume or mute key, down, repeat or up.
    private var lastSeen: Date = .distantPast
    /// A volume or mute key is down and its key-up has not arrived yet.
    private var held = false

    private var monitors: [Any] = []

    /// `NX_SUBTYPE_AUX_CONTROL_BUTTONS`: the system-defined subtype the media
    /// keys arrive as, from IOKit's `ev_keymap.h`.
    private static let mediaKeySubtype: Int16 = 8

    /// `NX_KEYTYPE_SOUND_UP`, `NX_KEYTYPE_SOUND_DOWN` and `NX_KEYTYPE_MUTE`,
    /// from the same header.
    private static let volumeKeyTypes: Set<Int> = [0, 1, 7]

    func start() {
        guard monitors.isEmpty else { return }
        // Local for while the saver is in front, which is when it matters.
        // Global as well, in case macOS hands the event to another app first;
        // a global monitor sees it without being able to change it.
        if let local = NSEvent.addLocalMonitorForEvents(matching: .systemDefined, handler: { event in
            VolumeKeys.shared.note(event)
            return event
        }) { monitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined, handler: { event in
            VolumeKeys.shared.note(event)
        }) { monitors.append(global) }
    }

    private func note(_ event: NSEvent) {
        guard event.subtype.rawValue == Self.mediaKeySubtype else { return }
        // data1 packs the key type in its top 16 bits.
        let keyType = (event.data1 & 0xFFFF_0000) >> 16
        guard Self.volumeKeyTypes.contains(keyType) else {
            // Any other media key ends a hold, so a key-up that never arrives
            // cannot leave this explaining keys it never saw.
            lock.withLock { held = false }
            return
        }
        // The middle byte is the key state: 0x0A down (and repeat), 0x0B up.
        let isUp = (event.data1 & 0xFF00) >> 8 == 0x0B
        lock.withLock {
            lastSeen = Date()
            held = !isUp
        }
    }

    /// Whether the most recent system-defined event, `secondsAgo` seconds
    /// ago, was a volume key this app saw. The monitor runs a moment after
    /// the event itself, so the event cannot be later than `lastSeen`; a
    /// different key pressed after it would be.
    ///
    /// **While a volume key is held, its key-up is assumed.** The key-up
    /// reaches the idle clock before it reaches this monitor, and the tick
    /// can land in between. Measured 2026-10-08: mute down was seen at
    /// 07.393, its key-up happened at about 07.470, the tick ran at 07.471
    /// and dismissed, and the monitor saw the key-up at 07.477. The volume
    /// presses before it had passed only because their key-ups won that race.
    func explainsSystemDefinedEvent(secondsAgo: Double) -> Bool {
        let happened = Date().addingTimeInterval(-secondsAgo)
        return lock.withLock { held || happened <= lastSeen }
    }
}
