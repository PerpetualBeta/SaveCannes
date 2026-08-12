import AppKit
import Sparkle

/// Keeps Sparkle's UI in front for the whole update session.
///
/// Sparkle dialogs landing behind another app's windows is the single most
/// reported integration bug, and there is no one-line fix that works. This
/// delegate combines the three legs that do (KB
/// `conventions-sparkle-integration` §6, validated end-to-end on ClipMan):
///
/// 1. **Modern activation API.** `NSApp.activate(ignoringOtherApps:)` is
///    deprecated on macOS 14+ — the system asks the active app's permission
///    to yield focus and routinely refuses, especially for an `LSUIElement`
///    app interrupting a `.regular` one. We use
///    `NSRunningApplication.current.activate(options:)` instead.
/// 2. **Window-level elevation.** While an update session is in progress,
///    every visible window is promoted to `.floating` so Sparkle's sheets
///    stay above other apps' `.normal` windows even if the user switches
///    focus mid-download. Original levels are restored when the session ends.
/// 3. **A key-window observer for the un-hookable status sheet.** Sparkle
///    exposes delegate hooks for the modal alert and the "Update Available"
///    window, but the download/install status sheet has none — we catch its
///    `makeKeyAndOrderFront` transitions via `didBecomeKeyNotification`.
///
/// Wire-up (every Sparkle app, windowed or menu-bar):
///
///     let userDriverDelegate = JorvikUserDriverDelegate()
///     lazy var sparkleUpdater = SPUStandardUpdaterController(
///         startingUpdater: true,
///         updaterDelegate: nil,
///         userDriverDelegate: userDriverDelegate
///     )
///
/// The "Check for Updates…" menu handler should also foreground the app
/// before Sparkle's first network call:
///
///     NSRunningApplication.current.activate(options: [.activateAllWindows])
///     sparkleUpdater.checkForUpdates(sender)
final class JorvikUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    private var sessionObserver: NSObjectProtocol?
    private var elevatedWindows: [(window: NSWindow, originalLevel: NSWindow.Level)] = []

    func standardUserDriverWillShowModalAlert() {
        bringForward()
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        startFocusGuard()
        bringForward()
    }

    func standardUserDriverWillFinishUpdateSession() {
        stopFocusGuard()
    }

    private func bringForward() {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        elevateAllWindows()
    }

    private func startFocusGuard() {
        guard sessionObserver == nil else { return }
        sessionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.bringForward()
        }
    }

    private func stopFocusGuard() {
        if let obs = sessionObserver {
            NotificationCenter.default.removeObserver(obs)
            sessionObserver = nil
        }
        for entry in elevatedWindows {
            entry.window.level = entry.originalLevel
        }
        elevatedWindows.removeAll()
    }

    /// Promote every visible window in this process to `.floating`. Any
    /// new Sparkle window that opens during the session is caught by
    /// the key-notification observer above and elevated then.
    private func elevateAllWindows() {
        for window in NSApp.windows where window.isVisible && window.level == .normal {
            elevatedWindows.append((window, window.level))
            window.level = .floating
        }
    }
}
