import AppKit

/// Single user-visible touchpoint for the app — a small SF Symbol in the menu
/// bar. Click it for a menu of actions: start playing immediately, open
/// settings, check for updates, quit.
///
/// `NSObject` (rather than a plain Swift class, like the rest of this file
/// could otherwise be) purely so it can be `NSMenuDelegate` and receive
/// `menuWillOpen` — needed to keep the per-display rows' Play/Stop wording
/// current even when nothing about the screens themselves has changed.
final class StatusItem: NSObject, NSMenuDelegate {

    private var item: NSStatusItem?
    private weak var appDelegate: AppDelegate?
    /// The Suspend/Resume row, kept so its title can flip in place. Also the
    /// fixed point per-display rows are (re)inserted directly above —
    /// looked up by identity rather than a cached index, since
    /// inserting/removing rows shifts everything below it — so Suspend/Resume
    /// always stays the last row of the group, after Play Now and every
    /// display row.
    private var suspendResumeItem: NSMenuItem!
    /// The rows currently inserted for `rebuildDisplayRows()` to remove
    /// before rebuilding, so a rebuild never leaves a stale row behind for a
    /// display that's since disconnected.
    private var perDisplayItems: [NSMenuItem] = []

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init()
        configure()
    }

    /// Remove the status item from the menu bar. Called when the user hides the
    /// icon via Settings. Leaves the display-change observer in place (its
    /// `applyIcon` is a no-op once `item` is nil), so a later re-show via a
    /// fresh `StatusItem` rebuilds cleanly.
    func remove() {
        if let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    private func configure() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Persist the item's menu-bar slot across launches (and let a user
        // command-drag stick).
        item.autosaveName = "SaveCannesStatusItem"
        applyIcon(to: item)

        // Redraw the status icon when the display configuration changes — the
        // menu bar's effective thickness can shrink (e.g. moving from a notched
        // display to an external one) and leave the pre-rendered glyph cropped.
        // The same notification also drives the per-display rows below, the
        // same trigger Settings' own connected-displays list uses.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if let item = self.item { self.applyIcon(to: item) }
            self.rebuildDisplayRows()
        }

        // Covers both ways this can change: the menu item below, and the
        // Settings toggle, which writes the UserDefaults key directly rather
        // than going through `toggleActivationSuspended()`.
        NotificationCenter.default.addObserver(
            forName: .activationSuspendedChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshSuspendResumeState()
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: L10n.string("menu.about", defaultValue: "About Save Cannes"),
                     action: #selector(showAbout), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.string("menu.play_now", defaultValue: "Play Now"),
                     action: #selector(activateNow), keyEquivalent: "")
            .target = self
        let suspendResumeItem = menu.addItem(
            withTitle: "", action: #selector(toggleSuspendResume), keyEquivalent: "")
        suspendResumeItem.target = self
        self.suspendResumeItem = suspendResumeItem
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.string("menu.settings", defaultValue: "Settings…"),
                     action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(withTitle: L10n.string("menu.check_updates", defaultValue: "Check for Updates…"),
                     action: #selector(checkForUpdates), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.string("menu.quit", defaultValue: "Quit Save Cannes"),
                     action: #selector(quit), keyEquivalent: "q")
            .target = self
        item.menu = menu
        self.item = item
        refreshSuspendResumeState()
        rebuildDisplayRows()
    }

    /// Keeps the menu item's title and the status icon in step with
    /// `activationSuspended`, whichever of the two places changed it.
    private func refreshSuspendResumeState() {
        let suspended = appDelegate?.isActivationSuspended() ?? false
        suspendResumeItem?.title = suspended
            ? L10n.string("menu.resume", defaultValue: "Resume")
            : L10n.string("menu.suspend", defaultValue: "Suspend")
        if let item { applyIcon(to: item) }
    }

    /// One toggle row per connected display, letting a spare monitor be
    /// pressed into playing on its own — "temporarily allocate one screen"
    /// rather than the whole desktop. Only meaningful with more than one
    /// display; with exactly one, "play on it" is just Play Now again, so no
    /// rows are added at all rather than one that duplicates that item.
    /// Ordered by display name, between Play Now and Suspend/Resume — Play
    /// Now always comes first, Suspend/Resume always stays last in the
    /// group. Rebuilt (not diffed) on every screen connect/disconnect and
    /// every menu opening: cheap for the handful of rows involved, and the
    /// simplest way to keep both the row count and each row's Play/Stop
    /// wording honest — the latter can change from clicking the display
    /// itself, not just from this menu.
    private func rebuildDisplayRows() {
        guard let menu = item?.menu else { return }
        // Remove the old rows BEFORE reading suspendResumeItem's index, not
        // after — each removal shifts everything below it up by one, so an
        // index read beforehand is stale the moment there's anything to
        // remove. Reading it stale doesn't fail; it silently inserts the new
        // rows too low, past Suspend/Resume — which only ever showed up
        // correctly grouped on the very first build, when there was nothing
        // yet to remove.
        for row in perDisplayItems { menu.removeItem(row) }
        perDisplayItems.removeAll()

        let anchorIndex = menu.index(of: suspendResumeItem)
        guard anchorIndex >= 0 else { return }

        let screens = NSScreen.screens.sorted { $0.localizedName < $1.localizedName }
        guard screens.count > 1 else { return }

        // Inserted directly above Suspend/Resume, which is why it always
        // ends up last: every insertion here pushes it down by one.
        var insertAt = anchorIndex
        for screen in screens {
            let playing = appDelegate?.isPlayingSingleScreen(screen) ?? false
            let title = playing
                ? L10n.format("menu.stop_display_format", defaultValue: "Stop %@", screen.localizedName)
                : L10n.format("menu.play_display_format", defaultValue: "Play on %@", screen.localizedName)
            let row = NSMenuItem(title: title, action: #selector(toggleDisplay(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = screen
            menu.insertItem(row, at: insertAt)
            perDisplayItems.append(row)
            insertAt += 1
        }
    }

    /// Refreshes both of this menu's dynamic bits of state right before it's
    /// shown, alongside the notification-driven refresh each already has —
    /// belt-and-suspenders is cheap for two lookups on a menu open.
    func menuWillOpen(_ menu: NSMenu) {
        rebuildDisplayRows()
        refreshSuspendResumeState()
    }

    /// SF Symbol — a stack of film frames. Template image so the system tints
    /// it for the active appearance (light/dark).
    private func applyIcon(to item: NSStatusItem) {
        guard let button = item.button else { return }
        let suspended = appDelegate?.isActivationSuspended() ?? false
        button.image = suspended ? Self.suspendedIcon() : Self.normalIcon()
        button.image?.isTemplate = true
    }

    private static func normalIcon() -> NSImage? {
        NSImage(systemSymbolName: "film.stack", accessibilityDescription: "Save Cannes")
    }

    /// `popcorn` — a single, complete SF Symbol, not a composite.
    ///
    /// Two earlier attempts composited `film.stack` with a `nosign`
    /// circle-slash overlaid on top, to keep the base glyph recognisable
    /// while showing an "off" state. Both looked broken rather than
    /// deliberate: `lockFocus`-based compositing rendered visibly blurry on
    /// a Retina display, and fixing that only exposed the next problem —
    /// `film.stack`'s bounding box is wider than tall while `nosign` is a
    /// circle, and forcing both into one shared rect warped the circle into
    /// an oval and the slash along with it. Aspect-fitting each glyph into
    /// its own rect fixed the distortion but still read as illegible at
    /// actual menu-bar scale. Two rounds of hand-composited SF Symbols
    /// worth of evidence that this needed a different approach rather than
    /// a third attempt at the same one.
    ///
    /// `popcorn` sidesteps the whole problem: it's a single glyph Apple
    /// already drew, at the proportions it's meant to be shown at, so
    /// there's no compositing or aspect-fitting left to get wrong. It
    /// trades "still literally the Save Cannes glyph" for "something that
    /// actually reads cleanly" — chosen for the theme as much as the
    /// pragmatism: when a film pauses, that's when you get up for popcorn.
    ///
    /// **Falls back to the ordinary glyph if `popcorn` is ever unavailable.**
    /// `NSImage(systemSymbolName:)` returns nil for a symbol the running OS
    /// does not know, and a nil assigned to `button.image` draws nothing at
    /// all: the app would appear to have vanished from the menu bar while
    /// still running, and specifically while suspended, which is the one
    /// state this icon exists to advertise. `popcorn` resolves on macOS 27
    /// and is believed to have arrived with SF Symbols 5, alongside the 14.0
    /// floor this app builds against, but that was not confirmable here, and
    /// an unconfirmed symbol guarding a silent disappearance is not a trade
    /// worth making. Falling back loses the visual distinction on such a
    /// system, which is a far smaller loss than losing the icon.
    private static func suspendedIcon() -> NSImage? {
        NSImage(systemSymbolName: "popcorn", accessibilityDescription: "Save Cannes (suspended)")
            // Same accessibility text either way: the state is still suspended
            // even where the glyph cannot show it.
            ?? NSImage(systemSymbolName: "film.stack",
                       accessibilityDescription: "Save Cannes (suspended)")
    }

    @objc private func showAbout() {
        JorvikAboutView.showWindow(
            appName: "Save Cannes",
            repoName: "SaveCannes",
            productPage: "screensavers/savecannes"
        )
    }

    @objc private func toggleSuspendResume() {
        appDelegate?.toggleActivationSuspended()
        refreshSuspendResumeState()
    }

    @objc private func activateNow() {
        appDelegate?.activateNow(source: "status menu")
    }

    @objc private func toggleDisplay(_ sender: NSMenuItem) {
        guard let screen = sender.representedObject as? NSScreen else { return }
        appDelegate?.toggleSingleScreen(screen)
    }

    @objc private func openSettings() {
        appDelegate?.openSettings()
    }

    @objc private func checkForUpdates() {
        // Foreground the app so Sparkle's first dialog isn't hidden behind
        // whatever was previously frontmost.
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        appDelegate?.sparkleUpdater.checkForUpdates(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
