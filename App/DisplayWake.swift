import Foundation
import IOKit.pwr_mgt

/// Whether anything on the machine is deliberately keeping the display awake.
///
/// A video call, a full-screen film, a presentation: all of them hold a power
/// assertion saying "do not idle the display", and macOS honours it. Save Cannes
/// decided whether to activate from two things only, how long since the last
/// input event and whether the screen was locked, so a call with nobody touching
/// the keyboard looked exactly like an empty desk. Reported by @christobaldo as
/// issue #12, and he was right to call it a bug rather than a missing feature:
/// a screensaver covering a video call is not behaviour anyone chose.
///
/// ## Test the display assertion, and only that one
///
/// `PreventUserIdleSystemSleep` sits next to it in the same dictionary and looks
/// like it belongs. It does not. **Any audio playback raises it**, measured on
/// 2026-09-22 with `coreaudiod` taking one the moment a file started playing, so
/// testing that one would mean a music player in the background stopped the
/// screensaver working for the rest of the day. A video call raises the display
/// assertion; background music raises only the system one. That difference is
/// the whole distinction worth drawing.
///
/// ## Measured, not assumed
///
/// `IOPMCopyAssertionsStatus` read 0 with nothing asserting, 1 while a display
/// assertion was held, and 0 again once it dropped, with `pmset -g assertions`
/// agreeing at each step. It needs no entitlement and no permission.
///
/// Save Cannes holds no display assertion of its own, so there is nothing here
/// that could see its own reflection: `preventsDisplaySleepDuringVideoPlayback`
/// is never set on any of the per-display players, and its default is `false`.
enum DisplayWake {

    /// True when some other process is asking macOS to keep the display on.
    ///
    /// Errs toward `false` if the read fails. A failure that returned `true`
    /// would silently disable the screensaver altogether, which is a far worse
    /// outcome than activating during a call.
    static var somethingIsHoldingTheDisplayAwake: Bool {
        var assertions: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&assertions) == kIOReturnSuccess,
              let counts = assertions?.takeRetainedValue() as? [String: Int]
        else { return false }
        let key = kIOPMAssertionTypePreventUserIdleDisplaySleep as String
        return (counts[key] ?? 0) > 0
    }
}
