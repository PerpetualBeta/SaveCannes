import Foundation
import IOKit.ps

/// Reads the macOS idle timers that determine when the screen first stops
/// showing anything on its own — the native screen saver's start delay, and
/// the display-sleep timer for every power-source profile the Mac actually
/// has — so Settings can warn when Save Cannes' own idle timeout is set at
/// or past the smallest of them.
///
/// The screen-saver timer lives in the `com.apple.screensaver` ByHost
/// preferences (`defaults -currentHost read com.apple.screensaver` shows
/// it). Display sleep is a separate set of timers, one per power-source
/// profile, in `/Library/Preferences/com.apple.PowerManagement.plist` —
/// confirmed against `pmset -g custom` and against System Settings → Lock
/// Screen's own "Turn display off on battery/power adapter when inactive"
/// rows, which read from exactly this file. Both are read with CFPreferences
/// rather than shelling out.
///
/// Each of the three timers, independently, can be "Never" — and when it
/// is, it simply isn't part of the comparison at all, the same as if it
/// couldn't be read. There is no minimum across the three that has to
/// exist: if every one of them is "Never" (or unreadable), `minimumTrigger` below
/// is `nil` and Settings shows nothing, because there is genuinely nothing
/// for Save Cannes' own idle timeout to lose a race against.
///
/// Two power-source profiles are read, "AC Power" and "Battery Power"
/// (`kIOPMACPowerKey`/`kIOPMBatteryPowerKey`), and the battery one only when
/// the Mac has an internal battery. A Mac mini or Studio can still carry a
/// "Battery Power" entry, and its timer never applies there. Any other
/// profile, such as "UPS Power", is ignored: it only applies during a power
/// cut, and a warning about that would be noise.
///
/// ## Why a lock delay is not part of this
///
/// `AppDelegate` pauses its own playback (`observeMacScreenState()`) the
/// moment macOS's own screen saver starts **or** the display sleeps,
/// whichever happens first. So the number Save Cannes' idle timeout has to
/// beat is the soonest of *those*. A lock that follows later changes
/// nothing, because Save Cannes has already stopped playing by then.
enum SystemScreenLockSettings {

    private static let screensaverDomain = "com.apple.screensaver"
    private static let powerManagementDomain = "com.apple.PowerManagement"

    /// How long macOS waits, idle, before starting its own screen saver.
    /// `nil` when unset, 0, or "Never" — all three read as "not part of the
    /// comparison" rather than "definitely never fires": a Mac that has
    /// never had the screen saver pane touched has no key here at all, and
    /// this can't tell that apart from a deliberate "Never" without knowing
    /// which one it is, which doesn't matter for what this is used for.
    static var screensaverIdleSeconds: TimeInterval? {
        guard let seconds = readInt(screensaverDomain, "idleTime"), seconds > 0 else { return nil }
        return TimeInterval(seconds)
    }

    /// The display-sleep timer of each profile that applies to this Mac
    /// (see the type doc above), `nil` where that profile is set to "Never".
    static var displaySleepProfiles: [(cause: Cause, seconds: TimeInterval?)] {
        guard let profiles = CFPreferencesCopyMultiple(
            nil, powerManagementDomain as CFString, kCFPreferencesAnyUser, kCFPreferencesCurrentHost
        ) as? [String: Any] else { return [] }
        func timer(_ key: String) -> TimeInterval?? {
            guard let settings = profiles[key] as? [String: Any],
                  let minutes = (settings["Display Sleep Timer"] as? NSNumber)?.intValue
            else { return nil }
            return .some(minutes > 0 ? TimeInterval(minutes * 60) : nil)
        }
        let battery = hasInternalBattery
        var result: [(cause: Cause, seconds: TimeInterval?)] = []
        if let ac = timer(kIOPMACPowerKey) {
            result.append((battery ? .displaySleepACPower : .displaySleep, ac))
        }
        if battery, let onBattery = timer(kIOPMBatteryPowerKey) {
            result.append((.displaySleepBattery, onBattery))
        }
        return result
    }

    /// Whether the Mac has a battery of its own. A UPS also reports as a
    /// power source, but with a different type, so it does not count.
    private static var hasInternalBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        return list.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }

    /// The single number that actually matters: the soonest of the screen
    /// saver's own start delay and every power-source profile's
    /// display-sleep delay, tagged with which one it was so Settings can
    /// name it and suggest the fix that actually applies — telling someone
    /// to disable the screen saver when display sleep is the real cause
    /// would send them nowhere. `nil` when every one of them is "Never" (or
    /// unreadable) — nothing for Save Cannes' own idle timeout to lose a
    /// race against at all.
    static var minimumTrigger: (seconds: TimeInterval, cause: Cause)? {
        var candidates: [(TimeInterval, Cause)] = displaySleepProfiles.compactMap { profile in
            profile.seconds.map { ($0, profile.cause) }
        }
        if let screensaver = screensaverIdleSeconds {
            candidates.append((screensaver, .screensaver))
        }
        return candidates.min { $0.0 < $1.0 }
    }

    enum Cause {
        case screensaver
        /// A Mac with no battery has one display-off timer, not two.
        case displaySleep
        case displaySleepBattery
        case displaySleepACPower

        /// Plain-English label for the debug log — not `L10n`-wrapped, since
        /// this is developer-facing text, not UI copy.
        var logLabel: String {
            switch self {
            case .screensaver: return "screen saver"
            case .displaySleep: return "display sleep"
            case .displaySleepBattery: return "display sleep (battery)"
            case .displaySleepACPower: return "display sleep (AC power)"
            }
        }
    }

    /// A one-line summary of every timer read above and the resulting
    /// minimum, for logging whenever it changes — so a mismatch (or one
    /// developing later, from a macOS setting changed after the fact) is
    /// visible in the log, not just inferred from the Settings UI.
    static var summaryForLogging: String {
        func describe(_ seconds: TimeInterval?) -> String {
            guard let seconds else { return "Never" }
            return "\(Int((seconds / 60).rounded()))min"
        }
        var parts = ["screen saver=\(describe(screensaverIdleSeconds))"]
        for profile in displaySleepProfiles {
            parts.append("\(profile.cause.logLabel)=\(describe(profile.seconds))")
        }
        if let minimumTrigger {
            parts.append("min=\(describe(minimumTrigger.seconds)) (\(minimumTrigger.cause.logLabel))")
        } else {
            parts.append("min=none (nothing macOS would do on its own)")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Reading

    private static func readInt(_ domain: String, _ key: String) -> Int? {
        (CFPreferencesCopyValue(key as CFString, domain as CFString,
                                 kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? NSNumber)?.intValue
    }
}
