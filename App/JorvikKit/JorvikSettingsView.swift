import SwiftUI
import ServiceManagement

struct JorvikSettingsView<AppSettings: View>: View {
    let appName: String
    @ViewBuilder let appSettings: () -> AppSettings

    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 0) {
            Text(L10n.format("settings.title_format", defaultValue: "%@ Settings", appName))
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 8)

            Form {
                // App-specific settings first (if any)
                appSettings()

                Section(L10n.string("settings.general", defaultValue: "General")) {
                    Toggle(
                        L10n.string("settings.launch_at_login", defaultValue: "Launch at Login"),
                        isOn: $launchAtLogin
                    )
                        .onChange(of: launchAtLogin) { _, newValue in
                            do {
                                if newValue {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                            } catch {
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                            }
                        }
                }

            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button(L10n.string("settings.done", defaultValue: "Done")) {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            // Matching the bottom inset. Without a top inset the button row sits
            // flush against the form, and a form long enough to scroll ends its
            // visible area on a half-clipped row right against the button.
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        // A floor, not a fixed size — `showWindow` sizes the window from this
        // view's `fittingSize`, so a fixed size there made the measurement a
        // constant and every settings window came out the same small pane with a
        // scroller however much room the display had.
        .frame(minWidth: JorvikSettingsMetrics.minContentSize.width,
               minHeight: JorvikSettingsMetrics.minContentSize.height)
    }

    static func showWindow(appName: String, @ViewBuilder appSettings: @escaping () -> AppSettings) {
        if let window = JorvikSettingsWindowCache.existingWindow {
            // If the cached window is hidden, bring it to the active space so
            // the user isn't yanked to wherever it was last shown. If it's
            // still visible on another space, leave default behavior — macOS
            // will switch to that space, which is what the user expects when
            // a window of theirs is already open elsewhere.
            if !window.isVisible {
                window.collectionBehavior.insert(.moveToActiveSpace)
                window.makeKeyAndOrderFront(nil)
                DispatchQueue.main.async {
                    window.collectionBehavior.remove(.moveToActiveSpace)
                }
            } else {
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = JorvikSettingsView(
            appName: appName,
            appSettings: appSettings
        )
        let controller = NSHostingController(rootView: view)
        // Let the hosting controller compute its preferred size
        controller.view.layoutSubtreeIfNeeded()
        let fittingSize = controller.view.fittingSize

        // Shrink or grow to the content on both axes, floored at the minimum
        // above and capped at a fraction of the display the window will open on.
        // A form larger than the cap keeps its scroller, so the window never runs
        // off the screen; a form smaller than the floor still gets a window worth
        // looking at.
        //
        // Measured against the screen under the pointer, which is where
        // `centreOnActiveDisplay` is about to put it. The height budget pays for
        // the title bar too: `setContentSize` takes a *content* height and the
        // chrome is added on top, so the title bar comes out of the budget or it
        // is spent twice. (A titled window adds no width, hence height only.)
        let style: NSWindow.StyleMask = [.titled, .closable]
        let chromeHeight = NSWindow.frameRect(forContentRect: .zero, styleMask: style).height
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame.size ?? JorvikSettingsMetrics.assumedScreenSize
        let floor = JorvikSettingsMetrics.minContentSize
        let fraction = JorvikSettingsMetrics.maxDisplayFraction
        // `max(..., floor)` on each ceiling so a display too small for the floor
        // yields the floor rather than an inverted range.
        let ceilingWidth = max(visible.width * fraction, floor.width)
        let ceilingHeight = max(visible.height * fraction - chromeHeight, floor.height)
        let size = NSSize(width: min(max(fittingSize.width, floor.width), ceilingWidth),
                          height: min(max(fittingSize.height, floor.height), ceilingHeight))

        let window = NSWindow(contentViewController: controller)
        window.title = L10n.format("settings.title_format", defaultValue: "%@ Settings", appName)
        window.styleMask = style
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        JorvikWindowHelper.centreOnActiveDisplay(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        JorvikSettingsWindowCache.existingWindow = window
    }
}

/// Non-generic cache for the settings window instance. `JorvikSettingsView`
/// is generic over the app-specific settings type, and Swift doesn't allow
/// static stored properties inside generic types — so the cache sits here.
private enum JorvikSettingsWindowCache {
    static var existingWindow: NSWindow?
}

/// Sizing metrics for the settings window. A separate enum for the same reason
/// the cache is one: a generic type can't hold static stored properties.
private enum JorvikSettingsMetrics {
    /// The smallest a settings window gets, however little it contains. The view
    /// and the window sizing both read this so they can't drift apart.
    static let minContentSize = NSSize(width: 420, height: 400)

    /// The most of a display's visible area a settings window may take.
    ///
    /// A fraction rather than a fixed inset: a settings window that fills the
    /// screen reads as a document window, and one fixed inset can't suit both a
    /// laptop panel and a 27-inch display.
    static let maxDisplayFraction: CGFloat = 0.80

    /// Fallback when there is no screen to measure — vanishingly unlikely, and a
    /// plausible small display beats a zero-size window.
    static let assumedScreenSize = NSSize(width: 1200, height: 900)
}
