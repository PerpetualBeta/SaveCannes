import AppKit
import CoreGraphics
import ServiceManagement
import Sparkle

/// App lifecycle + idle-driven screensaver window controller. Also owns the
/// status item, settings window, and hotkey infrastructure.
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - State

    private var idleTimer: Timer?
    private var windows: [ScreensaverWindow] = []
    private var screenChangeObserver: NSObjectProtocol?
    private var shortcutObserver: NSObjectProtocol?
    /// Earliest moment the idle-tick is allowed to dismiss after an
    /// activation. Activating via hotkey (or status-menu click) is itself
    /// recent user input, so the immediate next idle reading would be ~0
    /// seconds and we'd auto-dismiss the saver we just opened. Suppress the
    /// dismiss until past this timestamp.
    private var dismissAllowedAfter: Date = .distantPast
    /// Earliest moment the idle-tick is allowed to ACTIVATE. Pushed forward
    /// when the system wakes from sleep or the screen unlocks — without this,
    /// a Mac that's been asleep would trigger the saver the instant you log
    /// back in (system idle accumulates during sleep, and would already be
    /// well past our threshold).
    private var activationAllowedAfter: Date = .distantPast
    private var wakeObservers: [NSObjectProtocol] = []

    private var statusItem: StatusItem?
    private var statusItemVisibilityObserver: NSObjectProtocol?
    private var hotkeyManager = HotkeyManager()

    // Sparkle update controller. Owns the SPUStandardUpdaterController —
    // created lazily so initial-launch performance isn't affected.
    let userDriverDelegate = JorvikUserDriverDelegate()
    lazy var sparkleUpdater = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: userDriverDelegate
    )

    // MARK: - Defaults

    /// Values `integer(forKey:)`/`bool(forKey:)` should return before the user
    /// has touched Settings.
    ///
    /// `@AppStorage`'s declared default is UI-only — it displays a value but
    /// doesn't write one, so an unread key reads as 0 in native code. For
    /// `videoScaling` and `playbackOrder` a 0 happens to be the intended
    /// default, which is exactly the kind of accident that turns into a bug
    /// the day the enum order changes. Registered explicitly so both sides
    /// agree on purpose rather than by coincidence.
    private static let registeredDefaults: [String: Any] = [
        "idleMinutes":               5,
        "playbackOrder":             PlaybackOrder.random.rawValue,
        "videoScaling":              VideoScaling.fullScreen.rawValue,
        "soundEnabled":              false,
        "differentVideoPerDisplay":  true,
        "titleMode":                 TitleMode.atStart.rawValue,
        "titleRepeatMinutes":        5,
        "photosEnabled":             true,
        "photoSeconds":              8,
        // Not in Settings: how far a photo zooms over its time on screen, and
        // with it how far it pans. A knob rather than a control because the
        // right amount is a matter of taste on one's own photos, and the default
        // is the one that reads as a camera move rather than as drift.
    ]

    private var idleThresholdSeconds: Double {
        Double(UserDefaults.standard.integer(forKey: "idleMinutes")) * 60
    }
    private var lockOnDismiss: Bool {
        UserDefaults.standard.bool(forKey: "lockOnDismiss")
    }
    private var soundEnabled: Bool {
        UserDefaults.standard.bool(forKey: "soundEnabled")
    }
    private var playbackOrder: PlaybackOrder {
        PlaybackOrder(rawValue: UserDefaults.standard.integer(forKey: "playbackOrder")) ?? .random
    }
    /// The user's preference, gated by what the current order allows.
    private var differentVideoPerDisplay: Bool {
        playbackOrder.allowsDifferentVideoPerDisplay
            && UserDefaults.standard.bool(forKey: "differentVideoPerDisplay")
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: Self.registeredDefaults)
        installEditMenu()
        scLog("applicationDidFinishLaunching — idle threshold \(Int(idleThresholdSeconds))s")
        // Whether this process is trusted, recorded at launch. Worth having: the answer
        // is per *process*, not just per app, and a process that has had the permission
        // revoked under it cannot regain it — so "the switch is on but the app disagrees"
        // is answered by comparing this line against when the app was started.
        scLog("accessibility at launch: " + (AXIsProcessTrusted() ? "granted" : "NOT granted"))
        registerAtLoginIfNeeded()
        // Touch the lazy property so the updater starts and begins its
        // scheduled-check timer.
        _ = sparkleUpdater
        createStatusItem()
        // Create or remove the menu-bar item when the user toggles its
        // visibility in Settings. Playback is wholly independent of the status
        // item, so this only affects menu access.
        statusItemVisibilityObserver = NotificationCenter.default.addObserver(
            forName: JorvikStatusItemVisibility.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyStatusItemVisibility()
        }
        registerStoredHotkeys()
        // The recorders in Settings post this after writing a new binding.
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: .jorvikShortcutChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.registerStoredHotkeys()
        }
        startIdlePolling()
        // Re-evaluate windows when displays connect/disconnect/reconfigure
        // (new monitor plugged in mid-screensaver, etc.).
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.handleScreenChange()
        }
        observeWakeAndUnlock()
    }

    /// An `LSUIElement` app is given **no main menu**, and the standard editing
    /// commands are dispatched through one: `NSMenu` matches the key equivalent
    /// and sends `paste:` down the responder chain. With no menu there is nothing
    /// to match, so ⌘V in any window the app opens does nothing at all — which is
    /// how the stream field in Settings ended up refusing a pasted URL, the one
    /// field in the app where typing by hand is genuinely unreasonable.
    ///
    /// The menu is never seen: an accessory app shows no menu bar. It exists
    /// purely so the key equivalents resolve. Same fix, and the same reason, as
    /// Lookout's setup sheet.
    private func installEditMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: L10n.format("menu.quit_format", defaultValue: "Quit %@", "Save Cannes"),
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L10n.string("menu.edit", defaultValue: "Edit"))
        // Undo/Redo by string selector: NSText declares neither, and the
        // responder that implements them (the field editor) is found at runtime.
        editMenu.addItem(NSMenuItem(title: L10n.string("menu.undo", defaultValue: "Undo"),
                                    action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: L10n.string("menu.redo", defaultValue: "Redo"),
                                    action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: L10n.string("menu.cut", defaultValue: "Cut"),
                                    action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: L10n.string("menu.copy", defaultValue: "Copy"),
                                    action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: L10n.string("menu.paste", defaultValue: "Paste"),
                                    action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: L10n.string("menu.select_all", defaultValue: "Select All"),
                                    action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    /// Relaunching from /Applications is the user's only way back to a hidden
    /// menu-bar icon, so restore visibility here.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        JorvikStatusItemVisibility.handleReopen()
        return true
    }

    /// After waking from sleep or unlocking the screen, suppress saver
    /// activation for a grace period. System idle time keeps counting during
    /// sleep/lock, so without this the user would fight the saver immediately
    /// on every wake/unlock.
    private func observeWakeAndUnlock() {
        let ws = NSWorkspace.shared.notificationCenter
        let dn = DistributedNotificationCenter.default()

        let onWake: (Notification) -> Void = { [weak self] _ in
            guard let self = self else { return }
            self.activationAllowedAfter = Date().addingTimeInterval(Self.wakeGraceSeconds)
            scLog("wake/unlock event — activation suppressed for \(Int(Self.wakeGraceSeconds))s")
            // Also dismiss any saver windows that may already be up (e.g. the
            // system displayed the lock screen above an active session).
            self.dismissWindows(triggerLock: false)
        }

        wakeObservers.append(ws.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main,
            using: onWake))
        wakeObservers.append(ws.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main,
            using: onWake))
        wakeObservers.append(dn.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main, using: onWake))
    }

    func applicationWillTerminate(_ notification: Notification) {
        idleTimer?.invalidate()
        for obs in [screenChangeObserver, statusItemVisibilityObserver, shortcutObserver] {
            if let obs = obs { NotificationCenter.default.removeObserver(obs) }
        }
        let ws = NSWorkspace.shared.notificationCenter
        let dn = DistributedNotificationCenter.default()
        for obs in wakeObservers {
            ws.removeObserver(obs)
            dn.removeObserver(obs)
        }
        wakeObservers.removeAll()
        cleanupLockObserver()
        dismissWindows(triggerLock: false)
        scLog("applicationWillTerminate")
    }

    // MARK: - Timing constants

    /// How long after a wake or unlock the saver stays out of the way.
    private static let wakeGraceSeconds: TimeInterval = 30
    /// How long after an activation (or a screenshot) the idle-tick is barred
    /// from dismissing. Both are triggered by user input, which resets system
    /// idle to zero — without the bar, the next tick would undo them.
    private static let selfInflictedInputGraceSeconds: TimeInterval = 2
    /// How long to wait for the lock screen to confirm before giving up and
    /// tearing the saver down anyway.
    private static let lockConfirmTimeoutSeconds: TimeInterval = 4

    // MARK: - Login auto-launch

    /// Auto-register for launch-at-login on the very first run only. Running
    /// the installer (or first-launching the .app) is the consent gesture; the
    /// README documents the auto-launch behaviour. Every subsequent launch
    /// leaves the system state alone — if the user disables Save Cannes in
    /// System Settings → Login Items, we don't fight them back. The
    /// Settings → General → "Launch at Login" toggle is the only thing that
    /// toggles the state after first run.
    private func registerAtLoginIfNeeded() {
        let firstRunKey = "didAttemptInitialLoginRegistration"
        let alreadyAttempted = UserDefaults.standard.bool(forKey: firstRunKey)
        let service = SMAppService.mainApp
        guard !alreadyAttempted else {
            scLog("login item: status=\(service.status.rawValue), respecting user choice")
            return
        }
        UserDefaults.standard.set(true, forKey: firstRunKey)
        guard service.status == .notRegistered || service.status == .notFound else {
            scLog("login item: first run, status already \(service.status.rawValue) — no action")
            return
        }
        do {
            try service.register()
            scLog("login item: first-run registration done")
        } catch {
            scLog("login item: first-run registration failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Hotkeys

    private func registerStoredHotkeys() {
        for slot in HotkeyManager.Slot.allCases {
            let binding = HotkeyBinding.read(slot)
            hotkeyManager.register(binding, slot: slot) { [weak self] in
                switch slot {
                case .activate:   self?.activateNow(source: "hotkey")
                case .screenshot: self?.captureScreenshot()
                }
            }
        }
    }

    // MARK: - Idle polling

    private func startIdlePolling() {
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        let idle = systemIdleSeconds()
        if windows.isEmpty {
            if idle >= idleThresholdSeconds && Date() >= activationAllowedAfter {
                scLog("idle=\(Int(idle))s ≥ threshold — activating")
                showWindows()
            }
        } else if idle < 1.0 && Date() >= dismissAllowedAfter {
            scLog("system idle dropped — dismissing")
            dismissWindows(triggerLock: lockOnDismiss)
        }
    }

    private func systemIdleSeconds() -> Double {
        let anyEvent = CGEventType(rawValue: ~UInt32(0)) ?? .null
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
    }

    // MARK: - Window management

    private func showWindows() {
        // Suppress idle-driven auto-dismiss briefly after activation. Without
        // this, hotkey/menu activations would be killed by their own user
        // input — the keypress that triggered activation also resets system
        // idle to 0, and the next idle-tick would dismiss.
        dismissAllowedAfter = Date().addingTimeInterval(Self.selfInflictedInputGraceSeconds)
        // Sound, when the user has asked for it, plays on the primary display
        // only. Every display runs its own player, so giving them all audio
        // would play the same soundtrack two or three times over, a few frames
        // apart — which sounds broken rather than loud.
        let audioScreen = NSScreen.screens.first
        // Mirroring is the default: one list, ordered once here, handed to every
        // stage, so they walk the identical sequence together. "Different video
        // on each display" instead lets each stage build and shuffle its own —
        // available in random order only, per
        // `PlaybackOrder.allowsDifferentVideoPerDisplay`.
        let mirrored = !differentVideoPerDisplay
        let shared = mirrored ? VideoLibrary.orderedPlaylist(playbackOrder) : nil
        for (index, screen) in NSScreen.screens.enumerated() {
            let win = ScreensaverWindow(
                screen: screen,
                audioEnabled: soundEnabled && screen == audioScreen,
                sharedPlaylist: shared,
                startOffset: mirrored ? 0 : index
            ) { [weak self] in
                self?.dismissWindows(triggerLock: self?.lockOnDismiss ?? false)
            }
            windows.append(win)
            win.activate()
        }
        scLog("showed \(windows.count) screensaver window(s)")
    }

    /// True between the first `dismissWindows(triggerLock:true)` call and the
    /// eventual teardown. Guards against re-entry — even though each
    /// ScreensaverWindow removes its eventMonitor on first fire, the mouse can
    /// cross a display boundary and trigger two windows' monitors almost
    /// simultaneously. Without this flag we'd call LockScreen.lock() twice and
    /// arm two observe-lock-then-pause cycles.
    private var lockDismissInProgress = false

    private func dismissWindows(triggerLock: Bool) {
        guard !windows.isEmpty else { return }
        if triggerLock {
            guard !lockDismissInProgress else {
                scLog("dismiss with lock — already in progress, ignoring re-entry")
                return
            }
            lockDismissInProgress = true
            // Don't tear down on lock at all. Tearing down as the lock-screen
            // animation completes reliably flashes a frame or two of desktop
            // between the saver disappearing and loginwindow's UI covering the
            // display, and timing the teardown off `com.apple.screenIsLocked`
            // can't close that gap deterministically — the notification can
            // lead the visual lock by a frame.
            //
            // Instead: lock, pause playback when the lock confirms, and let the
            // wake/unlock observer tear down on `screenIsUnlocked`. The lock
            // screen sits above `.screenSaver` level, so it provably covers our
            // windows the moment it's up.
            scLog("dismiss with lock — pausing on screenIsLocked, teardown deferred to unlock")
            observeLockThenPause()
            LockScreen.lock()
        } else {
            tearDownWindows()
        }
    }

    private var lockObserver: NSObjectProtocol?
    private func observeLockThenPause() {
        let center = DistributedNotificationCenter.default()
        // Idempotent — clear any stale observer from a previous cycle.
        if let prev = lockObserver { center.removeObserver(prev); lockObserver = nil }

        lockObserver = center.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            scLog("screenIsLocked received — pausing playback, windows stay until unlock")
            self.cleanupLockObserver()
            for win in self.windows { win.pauseAnimation() }
        }
        // Safety net: if no lock notification arrives (SACLockScreenImmediate
        // failed, loginwindow hung, symbol removed in a future macOS — whatever
        // the cause) the saver would otherwise stay up indefinitely with no
        // lock UI over it. Fall back to a normal teardown.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lockConfirmTimeoutSeconds) { [weak self] in
            guard let self = self, self.lockObserver != nil else { return }
            scLog("screenIsLocked timeout — lock likely failed, tearing down")
            self.cleanupLockObserver()
            self.tearDownWindows()
        }
    }

    private func cleanupLockObserver() {
        if let obs = lockObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
            lockObserver = nil
        }
    }

    private func tearDownWindows() {
        for win in windows { win.deactivate() }
        windows.removeAll()
        // Clear the re-entry guard so the next dismiss cycle can lock again.
        lockDismissInProgress = false
        scLog("dismissed screensaver windows")
    }

    private func handleScreenChange() {
        guard !windows.isEmpty else { return }
        scLog("screen layout changed — recreating screensaver windows")
        dismissWindows(triggerLock: false)
        showWindows()
    }

    // MARK: - Status item visibility

    /// Build the menu-bar item, unless the user has hidden it. Safe to call
    /// again after a hide (the item is rebuilt fresh).
    private func createStatusItem() {
        guard JorvikStatusItemVisibility.isVisible else { return }
        statusItem = StatusItem(appDelegate: self)
    }

    /// Bring the menu-bar item into line with the persisted visibility flag.
    /// Creates it when shown, removes it when hidden. Playback is untouched
    /// either way.
    func applyStatusItemVisibility() {
        if JorvikStatusItemVisibility.isVisible {
            if statusItem == nil { createStatusItem() }
        } else if let item = statusItem {
            item.remove()
            statusItem = nil
        }
    }

    // MARK: - Status menu actions

    func activateNow(source: String) {
        guard windows.isEmpty else { return }
        scLog("activate-now from \(source)")
        showWindows()
    }

    func openSettings() {
        SettingsWindow.show()
    }

    // MARK: - Screenshot

    private func captureScreenshot() {
        guard let target = currentScreensaverWindow() else {
            scLog("screenshot: no active screensaver window — ignoring hotkey")
            return
        }
        // Pressing the screenshot hotkey is itself recent user input (idle
        // drops to 0). Without extending the dismiss window, the next idle-tick
        // would close the saver a second after the screenshot finishes.
        dismissAllowedAfter = Date().addingTimeInterval(Self.selfInflictedInputGraceSeconds)
        Screenshot.capture(from: target.stage)
    }

    private func currentScreensaverWindow() -> ScreensaverWindow? {
        let mouse = NSEvent.mouseLocation
        return windows.first(where: { NSPointInRect(mouse, $0.screen.frame) })
            ?? windows.first
    }
}
