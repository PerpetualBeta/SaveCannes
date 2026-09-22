import AppKit
import CoreGraphics
import ServiceManagement
import Sparkle

extension Notification.Name {
    /// Posted whenever `activationSuspended` changes, from either the status
    /// menu or the Settings toggle, so the status icon stays honest about
    /// which one is true regardless of which one changed it.
    static let activationSuspendedChanged = Notification.Name("SaveCannesActivationSuspendedChanged")
}

/// App lifecycle + idle-driven screensaver window controller. Also owns the
/// status item, settings window, and hotkey infrastructure.
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - State

    private var idleTimer: Timer?
    private var windows: [ScreensaverWindow] = []

    /// Named once rather than spelled at each use — it is matched against a
    /// notification name as well as observed, and two spellings of the same
    /// string is how that kind of check silently stops matching.
    static let screenIsUnlockedNotification = "com.apple.screenIsUnlocked"

    /// Whether waking should LOCK the screen rather than merely dismiss.
    ///
    /// Pure, because it decides a security behaviour and that should be
    /// checkable without a machine to put to sleep. All four must hold: it is a
    /// wake and not an unlock; the user asked for lock-on-dismiss; the saver is
    /// actually up, so waking a Mac we were not covering never locks it; and
    /// the screen is not already locked.
    static func shouldLockOnWake(notification: String,
                                 lockOnDismiss: Bool,
                                 saverIsUp: Bool,
                                 screenAlreadyLocked: Bool) -> Bool {
        notification != screenIsUnlockedNotification
            && lockOnDismiss
            && saverIsUp
            && !screenAlreadyLocked
    }

    /// Set while activation is being held back by a locked screen, so the
    /// reason is logged once per lock rather than on every tick.
    private var activationHeldByLock = false
    /// Mirrors `activationHeldByLock`, for the case where another app is
    /// deliberately keeping the display awake. See `DisplayWake`.
    private var activationHeldByAssertion = false
    private var screenChangeObserver: NSObjectProtocol?
    /// Signature of the display layout the live windows were built for.
    /// `nil` when no windows exist. See `handleScreenChange`.
    private var builtForLayout: String?
    private var shortcutObserver: NSObjectProtocol?
    private var recordingObserver: NSObjectProtocol?
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
    private var hotkeyManager = JorvikHotkeyManager(signature: JorvikHotkeyManager.saveCannesSignature)

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
        "activationSuspended":       false,
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
    /// User-requested "don't activate on idle right now" — distinct from
    /// every other reason activation might be held back (a lock, a call):
    /// those are the app noticing something about the world, this is someone
    /// explicitly asking. Play Now still works regardless; only the idle
    /// tick checks this.
    private var activationSuspended: Bool {
        UserDefaults.standard.bool(forKey: "activationSuspended")
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
        scLog("applicationDidFinishLaunching — idle threshold \(Int(idleThresholdSeconds))s"
              + (activationSuspended ? ", activation SUSPENDED from a previous session" : ""))
        // Whether this process is trusted, recorded at launch. Worth having: the answer
        // is per *process*, not just per app, and a process that has had the permission
        // revoked under it cannot regain it — so "the switch is on but the app disagrees"
        // is answered by comparing this line against when the app was started.
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
        // While a recorder is listening the hotkeys come down, or Carbon fires
        // the action on the shortcut being recorded and the recorder never sees
        // the keystroke at all.
        recordingObserver = NotificationCenter.default.addObserver(
            forName: .jorvikShortcutRecordingChanged, object: nil, queue: .main
        ) { [weak self] note in
            let recording = note.userInfo?["recording"] as? Bool ?? false
            self?.hotkeyManager.setRecordingSuspended(recording)
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

        // Named in the log, because three different notifications share this
        // closure and one message for three causes is what made the original
        // diagnosis a fortnight of log-reading.
        let onWake: (Notification) -> Void = { [weak self] note in
            guard let self = self else { return }
            self.activationAllowedAfter = Date().addingTimeInterval(Self.wakeGraceSeconds)
            scLog("wake/unlock event (\(note.name.rawValue)) — activation suppressed for \(Int(Self.wakeGraceSeconds))s")
            // The three notifications do NOT mean the same thing. An unlock
            // means the user has just authenticated. A wake means the machine
            // came back with the saver still up — and if lock-on-dismiss is on,
            // the screen must not be handed back unlocked. macOS usually has it
            // covered, but only because the screen-lock delay happens to be
            // immediate, which is a System Settings value this app does not own.
            let mustLock = Self.shouldLockOnWake(
                notification: note.name.rawValue,
                lockOnDismiss: self.lockOnDismiss,
                saverIsUp: !self.windows.isEmpty,
                screenAlreadyLocked: LockScreen.screenIsLocked)
            if mustLock {
                scLog("woke with the saver up and the screen UNLOCKED — locking, not just dismissing")
            }
            self.dismissWindows(triggerLock: mustLock)
        }

        wakeObservers.append(ws.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main,
            using: onWake))
        wakeObservers.append(ws.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main,
            using: onWake))
        wakeObservers.append(dn.addObserver(
            forName: Notification.Name(Self.screenIsUnlockedNotification),
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
        for slot in JorvikHotkeyManager.Slot.allCases {
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
            // Checked first and unconditionally: unlike the lock/display-wake
            // checks below, this isn't the app noticing something about the
            // world, it's someone having explicitly asked not to be
            // interrupted. No log line here — the toggle itself already logs
            // the transition, and this would otherwise repeat every second
            // for as long as it's set.
            guard !activationSuspended else { return }
            if idle >= idleThresholdSeconds && Date() >= activationAllowedAfter {
                // Never start behind a lock screen. loginwindow sits above the
                // saver level, so nothing would be visible: the app would decode
                // video for an audience of nobody until someone came back.
                // There was no guard here at all.
                if LockScreen.screenIsLocked {
                    if !activationHeldByLock {
                        scLog("idle threshold reached but the screen is locked — not activating")
                        activationHeldByLock = true
                    }
                    return
                }
                activationHeldByLock = false

                // Something else is asking macOS to keep the display on: a
                // video call, a film, a presentation. Idle time says nobody has
                // touched the keyboard, and that is exactly what watching
                // something looks like.
                if DisplayWake.somethingIsHoldingTheDisplayAwake {
                    if !activationHeldByAssertion {
                        scLog("idle threshold reached but something is holding the display awake — not activating")
                        activationHeldByAssertion = true
                    }
                    // Restart the countdown rather than merely skipping this
                    // tick. Idle has been climbing all through the call, so
                    // without this the saver would appear the instant the call
                    // ended, which is the moment it is least wanted.
                    activationAllowedAfter = Date().addingTimeInterval(idleThresholdSeconds)
                    return
                }
                if activationHeldByAssertion {
                    scLog("display assertion released — idle countdown restarted")
                    activationHeldByAssertion = false
                }

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
        let screens = NSScreen.screens
        let audioScreen = screens.first
        let profiles = screens.map { DisplayProfileStore.profile(for: $0) }
        // With no display profiles, preserve the original global playback
        // rules: mirroring builds one playlist here and hands it to every
        // stage, while "Different video on each display" lets every stage
        // build its own random playlist.
        //
        // A per-display profile can choose both a different source set and a
        // different scaling mode, so it cannot share that playlist with an
        // arbitrary other display. Once any display is configured, every
        // stage builds its own list: configured displays use their selected
        // sources; unconfigured ones fall back to the global source list.
        // This also keeps a newly connected display useful without requiring
        // a profile before the saver can appear on it.
        let hasProfiles = profiles.contains(where: { $0 != nil })
        let mirrored = !hasProfiles && !differentVideoPerDisplay
        let shared = mirrored ? VideoLibrary.orderedPlaylist(playbackOrder) : nil
        for (index, screen) in screens.enumerated() {
            let profile = profiles[index]
            let configuredSources = profile.map { profile in
                let ids = profile.sourceIDs
                return VideoLibrary.sources.filter { ids.contains($0.id) }
            }
            let scaling = profile?.scaling
                ?? VideoScaling(rawValue: UserDefaults.standard.integer(forKey: "videoScaling"))
                ?? .fullScreen
            let win = ScreensaverWindow(
                screen: screen,
                audioEnabled: soundEnabled && screen == audioScreen,
                sharedPlaylist: shared,
                sourcesOverride: configuredSources,
                scaling: scaling,
                startOffset: mirrored || playbackOrder == .sequential ? 0 : index
            ) { [weak self] in
                self?.dismissWindows(triggerLock: self?.lockOnDismiss ?? false)
            }
            windows.append(win)
            win.activate()
        }
        builtForLayout = Self.screenLayoutSignature()
        scLog("showed \(windows.count) screensaver window(s) for layout \(builtForLayout ?? "?")")
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
        // Nothing to wait for if the screen is already locked. macOS locks the
        // session itself when the display sleeps, so a saver dismissed after
        // that is dismissed onto an already-locked session: the lock call
        // succeeds at doing nothing, and no transition means no notification
        // will ever arrive. Waiting the full timeout and then declaring failure
        // is what the log did for four months.
        if LockScreen.screenIsLocked {
            scLog("screen already locked before the request — pausing, no handshake needed")
            for win in windows { win.pauseAnimation() }
            return
        }
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
            self.cleanupLockObserver()
            // Ask, do not assume. The old line read "lock likely failed", which
            // the app had no way of knowing: all it had observed was a
            // notification that did not arrive. Those are different facts, and
            // conflating them sent three investigations down the wrong road.
            if LockScreen.screenIsLocked {
                scLog("no screenIsLocked in time, but the screen IS locked — pausing")
                for win in self.windows { win.pauseAnimation() }
            } else {
                scLog("no screenIsLocked in time and the screen is NOT locked — tearing down")
                self.tearDownWindows()
            }
        }
    }

    private func cleanupLockObserver() {
        if let obs = lockObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
            lockObserver = nil
        }
    }

    private func tearDownWindows() {
        // A teardown ends the dismiss this handshake belonged to, so the
        // observer has nothing left to hear. Leaving it armed let a wake
        // arriving mid-handshake orphan it rather than cancel it.
        cleanupLockObserver()
        for win in windows { win.deactivate() }
        windows.removeAll()
        // Clear the re-entry guard so the next dismiss cycle can lock again.
        lockDismissInProgress = false
        builtForLayout = nil
        scLog("dismissed screensaver windows")
    }

    /// Fingerprint of the physical display layout — the only thing a
    /// screensaver window is actually built from.
    ///
    /// Deliberately excludes `visibleFrame`. `visibleFrame` shrinks and
    /// grows as the menu bar and Dock come and go, and a fullscreen window
    /// at `.screenSaver` level covers the menu bar — so a signature that
    /// included it would change as a *result* of showing our own window.
    ///
    /// Sorted by display ID so a reordering of `NSScreen.screens` with
    /// unchanged geometry reads as no change. Frames are rounded to whole
    /// points: display frames are integral in practice, and rounding
    /// removes floating-point jitter from the comparison.
    private static func screenLayoutSignature() -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.map { screen -> String in
            let id = (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
            let f = screen.frame
            return String(
                format: "%u:%d,%d,%dx%d@%.1f",
                id,
                Int(f.origin.x.rounded()), Int(f.origin.y.rounded()),
                Int(f.size.width.rounded()), Int(f.size.height.rounded()),
                screen.backingScaleFactor)
        }
        .sorted()
        .joined(separator: "|")
    }

    /// `NSApplication.didChangeScreenParametersNotification` does not mean
    /// "a display was connected or disconnected". It fires for any change to
    /// the screen configuration, and on macOS 27 it fires when nothing about
    /// the display layout has changed at all.
    ///
    /// Measured on Rainy Day (26,611 show-to-rebuild samples, 2026-09-16) it
    /// has two distinct phases, and conflating them sends you looking in the
    /// wrong place:
    ///
    /// - **What starts it:** the first notification after a quiet activation
    ///   arrives a median of **15.6s** after the window is shown (610
    ///   samples). The cause is not identified. It did not reproduce in a
    ///   hotkey-triggered session with the user present, so it may need a
    ///   genuine idle activation.
    /// - **What sustains it:** rebuilding re-posts the notification within a
    ///   median of **5ms** (26,001 samples), because showing a window at
    ///   `.screenSaver` level is itself a screen-configuration change. That
    ///   runs away at ~30 rebuilds a second, 13,119 events in one day against
    ///   a 4-300 baseline.
    ///
    /// The guard below handles both, because it refuses every notification
    /// whose layout is unchanged regardless of what posted it. Here each
    /// rebuild
    /// rebuilds the playlist from the top, so the first video restarts
    /// forever and the saver never advances to the second one.
    ///
    /// So rebuild only when the thing the windows depend on actually
    /// differs. Showing a window does not move a display, so the signature
    /// is unchanged and the loop stops at the first hop. A debounce would
    /// not fix it: the self-posted notification just arrives later.
    private func handleScreenChange() {
        guard !windows.isEmpty else { return }
        let current = Self.screenLayoutSignature()
        guard current != builtForLayout else {
            scLog("screen parameters changed but display layout is unchanged (\(current)) — not rebuilding")
            return
        }
        scLog("display layout changed: \(builtForLayout ?? "none") → \(current) — recreating screensaver windows")
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

    /// For the status menu's label/icon and the Settings toggle to read
    /// without either owning the storage key directly.
    func isActivationSuspended() -> Bool {
        activationSuspended
    }

    /// Flips `activationSuspended`. The Settings toggle writes the same
    /// UserDefaults key directly (via `@AppStorage`) rather than calling
    /// this, but both paths post `.activationSuspendedChanged` so the status
    /// icon stays correct regardless of which one changed it.
    func toggleActivationSuspended() {
        let suspended = !activationSuspended
        UserDefaults.standard.set(suspended, forKey: "activationSuspended")
        scLog(suspended ? "activation suspended from status menu" : "activation resumed from status menu")
        NotificationCenter.default.post(name: .activationSuspendedChanged, object: nil)
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
