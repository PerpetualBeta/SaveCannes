import Foundation
import CoreGraphics

/// Locks the screen by calling `SACLockScreenImmediate` in
/// `/System/Library/PrivateFrameworks/login.framework`.
///
/// This is the IPC path Apple uses internally (loginwindow's own private
/// framework), and the canonical approach used by Hammerspoon, Bear, and most
/// other menu-bar lock apps. It doesn't require Accessibility because nothing
/// is being synthesised — loginwindow is being told directly to lock.
///
/// The paths not taken, and why: `CGSession -suspend` was removed in macOS 26,
/// and a synthesised ⌃⌘Q posted at the session event tap is consumed under
/// Tahoe's tightened policy on system shortcuts without ever reaching
/// loginwindow — the saver dismisses, silently, without locking.
///
/// Private API caveat: Apple could remove or rename the symbol in a future
/// macOS. The fall-through here logs and returns; the dismiss flow then
/// proceeds without locking, via the timeout path in `observeLockThenPause`.
enum LockScreen {
    private typealias SACLockFn = @convention(c) () -> Int32

    /// Resolved once at first access and cached for the process lifetime — the
    /// framework and symbol don't change while we're running.
    private static let sacLockScreenImmediate: SACLockFn? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY),
              let sym = dlsym(handle, "SACLockScreenImmediate")
        else {
            return nil
        }
        return unsafeBitCast(sym, to: SACLockFn.self)
    }()

    static func lock() {
        guard let fn = sacLockScreenImmediate else {
            scLog("LockScreen: SACLockScreenImmediate unavailable — lock skipped")
            return
        }
        let result = fn()
        scLog("LockScreen: SACLockScreenImmediate → result=\(result)")
    }

    /// Whether the login session is locked **right now**.
    ///
    /// `SACLockScreenImmediate` returns 0 whether it locked the screen or found
    /// it already locked, and `com.apple.screenIsLocked` is posted only on a
    /// *transition*. When the display has already slept — and a Mac set to
    /// require a password immediately locks the session at that moment — the
    /// call succeeds, nothing changes, no notification is posted, and a listener
    /// waiting to be told concludes the lock failed. It did not.
    ///
    /// This is where that was first noticed, from this app's own logs: every
    /// lock request made after the saver had been up longer than the
    /// display-sleep timeout failed to confirm, 19 of 19 across three savers,
    /// going back to May. Under that threshold, 19 in 1,135.
    ///
    /// `CGSSessionScreenIsLocked` is absent when unlocked rather than
    /// present-and-false, so a missing key means unlocked.
    static var screenIsLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return info["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
