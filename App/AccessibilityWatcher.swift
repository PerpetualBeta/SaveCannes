import AppKit
import ApplicationServices
import SwiftUI

/// Whether this build is trusted for Accessibility, kept current while the Settings
/// window is open.
///
/// `AXIsProcessTrusted()` reports the live state, but nothing hands SwiftUI a change
/// notification for it, so the row used to be read once as the view appeared. Granting
/// the permission and still seeing "Grant Access" reads as a failure, which is what this
/// exists to stop.
///
/// Three ways of finding out, and the interesting part is why it takes three.
///
/// **The system's own notification.** macOS posts `com.apple.accessibility.api` on the
/// *distributed* centre when the trust state changes. Watching for it with a plain
/// Combine publisher was tried first and appeared not to work at all: the grant was
/// recorded at 11:43:26 and the row only caught up at 11:43:47, twenty-one seconds later,
/// when the app was brought back to the front. But that is not evidence the notification
/// never arrived — a distributed observer defaults to
/// `NSNotificationSuspensionBehavior.coalesce`, which *holds* notifications while the
/// app is inactive and delivers them when it next becomes active. Save Cannes is a
/// background app and System Settings is necessarily frontmost at the moment the switch
/// is flipped, so "posted but suspended" and "never posted" produce precisely the same
/// twenty-one-second gap. Hence `.deliverImmediately` here, which is the whole reason
/// this is a target/selector registration rather than a publisher — the publisher API
/// cannot express suspension behaviour.
///
/// With `.deliverImmediately` in place the notification does arrive, promptly, and it is
/// what notices nearly every change. But it arrives *before* the change is committed: the
/// grant was written to TCC at 11:58:48 while a read taken at 11:58:48.345, in response to
/// the announcement, still came back with the old answer. Read it synchronously and the
/// row shows the state *before* the toggle — which, flipping the switch back and forth,
/// looks exactly like the logic being the wrong way round. So the announcement is treated
/// as "something changed, look again shortly", not as a value.
///
/// **Coming back to the app.** Free, instant, and on the path of every real grant, since
/// flipping the switch means going to System Settings and returning.
///
/// **A one-second re-read.** The guarantee. Whatever the other two miss or mistime, this
/// converges on the truth within a second, and it is the reason the row cannot sit there
/// disagreeing with System Settings. `AXIsProcessTrusted` is a cheap lookup and none of
/// this runs unless a Settings window is open.
///
/// Each route says so in the log when it is the one that noticed, so which of them is
/// doing the work is a matter of record rather than of inference.
final class AccessibilityWatcher: NSObject, ObservableObject {

    @Published private(set) var trusted: Bool = AXIsProcessTrusted()

    /// How often the state is re-read while a Settings window is open.
    private static let pollSeconds: TimeInterval = 1

    /// How long to stop reading for after the system announces a change.
    ///
    /// This is the whole trick, and it is not obvious. `AXIsProcessTrusted()` is cached
    /// inside the process, and the announcement *invalidates* that cache — so the first
    /// read afterwards is the one that refetches, and every read after it gets whatever
    /// that one found. The announcement arrives before `tccd` has committed the new
    /// value, so a read taken on the spot refetches the OLD answer and pins it there
    /// until the next announcement. Measured: the switch went on at 12:23:43, a read at
    /// 12:23:43.716 came back false, and ninety-six further reads over the next seventy
    /// seconds all came back false while the system's own record said allowed.
    ///
    /// So the fix is not to read more often — more reads make it worse, because any one of
    /// them can be the one that pins the stale answer. It is to read *later*, exactly
    /// once, and to hold everything else off until then.
    private static let commitSeconds: TimeInterval = 1.5

    private static let apiChanged = Notification.Name("com.apple.accessibility.api")

    private var poll: Timer?
    /// Reads before this moment are skipped, so nothing races the commit and pins a stale
    /// answer into the process's cache.
    private var quietUntil: Date = .distantPast

    override init() {
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(announced),
            name: Self.apiChanged, object: nil,
            suspensionBehavior: .deliverImmediately)
        NotificationCenter.default.addObserver(
            self, selector: #selector(reactivated),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        // Scheduled in the common modes so tracking a menu or dragging the window
        // cannot stall the one mechanism that guarantees the row is right.
        let poll = Timer(timeInterval: Self.pollSeconds, repeats: true) { [weak self] _ in
            self?.reread(how: "a re-read")
        }
        RunLoop.main.add(poll, forMode: .common)
        self.poll = poll
    }

    deinit {
        poll?.invalidate()
        DistributedNotificationCenter.default().removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func announced() {
        // Deliberately no read here. The announcement means the cached answer is about to
        // become wrong, not that the new one is available yet.
        quietUntil = Date().addingTimeInterval(Self.commitSeconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.commitSeconds) { [weak self] in
            guard let self = self else { return }
            self.quietUntil = .distantPast
            self.reread(how: "the system's notification")
        }
    }
    @objc private func reactivated() { reread(how: "coming back to the app") }

    /// Re-read the trust state.
    ///
    /// Only publishes on a change, so the poll doesn't invalidate the view every second
    /// for nothing. Logged because the answer depends on the *binary*: a rebuild is a
    /// different signature at the same path, and whether an existing grant still covers
    /// it is worth being able to look up rather than guess at.
    func reread(how: String, evenIfUnchanged: Bool = false) {
        // Do not read while a change is settling: the first read after the announcement is
        // the one whose answer sticks, and it must not be a read that got in too early.
        if Date() < quietUntil { return }
        let now = AXIsProcessTrusted()
        if now == trusted {
            if evenIfUnchanged {
                scLog("accessibility \(now ? "granted" : "NOT granted") for this build")
            }
            return
        }
        trusted = now
        scLog("accessibility \(now ? "granted" : "revoked") — noticed by \(how)")
    }
}
