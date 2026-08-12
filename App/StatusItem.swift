import AppKit

/// Single user-visible touchpoint for the app — a small SF Symbol in the menu
/// bar. Click it for a menu of actions: start playing immediately, open
/// settings, check for updates, quit.
final class StatusItem {

    private var item: NSStatusItem?
    private weak var appDelegate: AppDelegate?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
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
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let item = self.item else { return }
            self.applyIcon(to: item)
        }

        let menu = NSMenu()
        menu.addItem(withTitle: L10n.string("menu.about", defaultValue: "About Save Cannes"),
                     action: #selector(showAbout), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.string("menu.play_now", defaultValue: "Play Now"),
                     action: #selector(activateNow), keyEquivalent: "")
            .target = self
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
    }

    /// SF Symbol — a stack of film frames. Template image so the system tints
    /// it for the active appearance (light/dark).
    private func applyIcon(to item: NSStatusItem) {
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "film.stack",
                               accessibilityDescription: "Save Cannes")
        button.image?.isTemplate = true
    }

    @objc private func showAbout() {
        JorvikAboutView.showWindow(
            appName: "Save Cannes",
            repoName: "SaveCannes",
            productPage: "screensavers/savecannes"
        )
    }

    @objc private func activateNow() {
        appDelegate?.activateNow(source: "status menu")
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
