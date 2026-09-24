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
/// Power-source profiles are read generically — every top-level key in the
/// `com.apple.PowerManagement` domain that has its own "Display Sleep
/// Timer" — rather than assuming which ones exist. A laptop has both "AC
/// Power" and "Battery Power" (`kIOPMACPowerKey`/`kIOPMBatteryPowerKey`,
/// the same public IOKit constants `IOPSGetProvidingPowerSourceType`
/// itself returns); a Mac with no battery — a Mac mini, Studio, or desktop
/// iMac — very plausibly has only the one, and rather than guess whether
/// or how that profile might be named differently there, this just reads
/// whatever profiles are actually present.
///
/// ## Why a lock delay is deliberately not part of this
///
/// `AppDelegate` tears its own windows down (`observeMacScreenState()`)
/// the moment macOS's own screen saver starts **or** the display sleeps,
/// whichever happens first — not only once the session actually locks. So
/// the number Save Cannes' idle timeout has to beat is the soonest of
/// *those*, full stop. Whether, or how much later, a password-required
/// lock might additionally follow doesn't change anything — Save Cannes
/// has already stopped by then regardless — so it isn't part of the
/// comparison. (An earlier version of this DID fold in a lock delay; that
/// was a mistake, corrected 2026-09-24.)
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

    /// Every power-source profile macOS has (see the type doc above for why
    /// this is read generically), with its display-sleep timer if one is
    /// actually set — `nil` there means "Never" for that one profile, not
    /// that the profile doesn't exist.
    static var displaySleepProfiles: [(cause: Cause, seconds: TimeInterval?)] {
        guard let profiles = CFPreferencesCopyMultiple(
            nil, powerManagementDomain as CFString, kCFPreferencesAnyUser, kCFPreferencesCurrentHost
        ) as? [String: Any] else { return [] }
        return profiles.compactMap { key, value -> (Cause, TimeInterval?)? in
            // Only a real power-source profile has this key at all —
            // "SystemPowerSettings", the domain's other top-level entry,
            // doesn't, so this is what tells the two apart.
            guard let settings = value as? [String: Any],
                  let minutes = (settings["Display Sleep Timer"] as? NSNumber)?.intValue
            else { return nil }
            let cause: Cause = key == kIOPMBatteryPowerKey ? .displaySleepBattery : .displaySleepACPower
            return (cause, minutes > 0 ? TimeInterval(minutes * 60) : nil)
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
        case displaySleepBattery
        case displaySleepACPower

        /// Plain-English label for the debug log — not `L10n`-wrapped, since
        /// this is developer-facing text, not UI copy.
        var logLabel: String {
            switch self {
            case .screensaver: return "screen saver"
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
