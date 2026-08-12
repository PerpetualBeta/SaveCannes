import AppKit
import SwiftUI
import ApplicationServices
import UniformTypeIdentifiers

/// Settings window for Save Cannes. Hosted by the standard JorvikSettingsView
/// wrapper, which provides the title, the "General" section (Launch at Login),
/// and the Done button. App-specific sections live in
/// `SaveCannesSettingsContent`.
enum SettingsWindow {
    static func show() {
        JorvikSettingsView.showWindow(appName: "Save Cannes") {
            SaveCannesSettingsContent()
        }
    }
}

// MARK: - App-specific settings sections

/// Per the Jorvik convention, sections appear top-to-bottom in the order:
/// Permissions → app-specific → General (Launch at Login, auto-injected by
/// JorvikSettingsView).
struct SaveCannesSettingsContent: View {

    @AppStorage(VideoLibrary.sourcePathKey) private var sourcePath: String = ""
    @AppStorage("playbackOrder")  private var order: PlaybackOrder = .random
    @AppStorage("videoScaling")   private var scaling: VideoScaling = .fullScreen
    @AppStorage("soundEnabled")   private var soundEnabled: Bool = false
    @AppStorage("differentVideoPerDisplay") private var differentVideoPerDisplay: Bool = true
    @AppStorage("titleMode")          private var titleMode: TitleMode = .atStart
    @AppStorage("titleRepeatMinutes") private var titleRepeatMinutes: Int = 5
    @AppStorage("idleMinutes")    private var idleMinutes: Int = 5
    @AppStorage("lockOnDismiss")  private var lockOnDismiss: Bool = false

    /// How many playable-looking videos the current source holds. nil while
    /// the count is still being taken.
    @State private var videoCount: Int?

    /// AXIsProcessTrusted flips immediately after the user grants access in
    /// System Settings, but SwiftUI doesn't see the change without a redraw
    /// trigger. Re-poll when the view appears.
    @State private var accessibilityGranted: Bool = AXIsProcessTrusted()

    var body: some View {
        Section(L10n.string("settings.permissions", defaultValue: "Permissions")) {
            HStack {
                Text(L10n.string("settings.accessibility", defaultValue: "Accessibility"))
                Spacer()
                if accessibilityGranted {
                    Label(L10n.string("settings.granted", defaultValue: "Granted"),
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else {
                    Button(L10n.string("settings.grant_access", defaultValue: "Grant Access")) {
                        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
                        AXIsProcessTrustedWithOptions(opts)
                    }
                    .font(.caption)
                }
            }
            Text(L10n.string("settings.accessibility_why",
                             defaultValue: "Accessibility is required to lock the screen when the saver dismisses."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        MenuBarVisibilitySettings()

        Section(L10n.string("settings.video", defaultValue: "Video")) {
            HStack {
                Text(L10n.string("settings.source", defaultValue: "Source:"))
                Text(sourceDisplayName)
                    .foregroundStyle(sourcePath.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(L10n.string("settings.choose", defaultValue: "Choose…")) {
                    chooseSource()
                }
                .font(.caption)
            }
            Text(sourceSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker(L10n.string("settings.order", defaultValue: "Order:"), selection: $order) {
                Text(L10n.string("settings.order_random", defaultValue: "Random"))
                    .tag(PlaybackOrder.random)
                Text(L10n.string("settings.order_sequential", defaultValue: "Sequential, by filename"))
                    .tag(PlaybackOrder.sequential)
            }
            // A single file has no order to play in.
            .disabled(!VideoLibrary.sourceIsDirectory)

            Toggle(L10n.string("settings.sound", defaultValue: "Play sound"), isOn: $soundEnabled)
            Text(L10n.string("settings.sound_note",
                             defaultValue: "With more than one display, sound plays on the main display only — each display runs its own playback, so sound on all of them would overlap."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section(L10n.string("settings.display", defaultValue: "Display")) {
            Picker(L10n.string("settings.size", defaultValue: "Size:"), selection: $scaling) {
                Text(L10n.string("settings.size_full", defaultValue: "Full screen, cropped to fit"))
                    .tag(VideoScaling.fullScreen)
                Text(L10n.string("settings.size_fit", defaultValue: "Fit to screen, no cropping"))
                    .tag(VideoScaling.fitToScreen)
                Text(L10n.string("settings.size_original", defaultValue: "Original size"))
                    .tag(VideoScaling.originalSize)
            }
            Text(L10n.string("settings.size_note",
                             defaultValue: "Original size plays one video pixel to one screen pixel, centred on black. Anything bigger than the display is scaled down to fit."))
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle(L10n.string("settings.different_per_display",
                               defaultValue: "Different video on each display"),
                   isOn: differentPerDisplayBinding)
                .disabled(!order.allowsDifferentVideoPerDisplay)
            Text(differentPerDisplayNote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section(L10n.string("settings.titles", defaultValue: "Titles")) {
            Picker(L10n.string("settings.show_title", defaultValue: "Show title:"), selection: $titleMode) {
                Text(L10n.string("settings.title_never", defaultValue: "Never"))
                    .tag(TitleMode.never)
                Text(L10n.string("settings.title_at_start", defaultValue: "As each video starts"))
                    .tag(TitleMode.atStart)
                Text(L10n.string("settings.title_repeatedly", defaultValue: "Repeatedly, while it plays"))
                    .tag(TitleMode.repeatedly)
            }
            HStack {
                Text(L10n.string("settings.title_repeat_every", defaultValue: "Repeat every:"))
                TextField("", value: $titleRepeatMinutes, formatter: Self.minutes(min: 1, max: 60))
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Text(L10n.string("settings.minutes", defaultValue: "minutes"))
                Spacer()
            }
            .disabled(titleMode != .repeatedly)
            Text(L10n.string("settings.title_note",
                             defaultValue: "The video's own title if it has one, otherwise its filename, low in the corner for a few seconds. A copyright line is shown underneath when the file carries one."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section(L10n.string("settings.activation", defaultValue: "Activation")) {
            HStack {
                Text(L10n.string("settings.idle_timeout", defaultValue: "Idle timeout:"))
                TextField("", value: $idleMinutes, formatter: Self.minutes(min: 1, max: 1440))
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Text(L10n.string("settings.minutes", defaultValue: "minutes"))
                Spacer()
            }
            ShortcutRow(label: L10n.string("settings.play_now", defaultValue: "Play now:"),
                        slot: .activate)
        }

        Section(L10n.string("settings.on_dismiss", defaultValue: "On dismiss")) {
            Toggle(L10n.string("settings.lock_on_dismiss", defaultValue: "Lock screen when dismissed"),
                   isOn: $lockOnDismiss)
        }

        Section(L10n.string("settings.capture", defaultValue: "Capture")) {
            ShortcutRow(label: L10n.string("settings.screenshot", defaultValue: "Screenshot:"),
                        slot: .screenshot)
            Text(L10n.string("settings.screenshot_note",
                             defaultValue: "Saves the current frame, at the video's own resolution, to ~/Pictures/Save Cannes/"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            accessibilityGranted = AXIsProcessTrusted()
            recount()
        }
    }

    // MARK: - Multi-display

    /// Reads as off in the orders that don't allow it, **without** overwriting
    /// the stored preference — switch back to random and the user's own choice
    /// is still there rather than a value we clobbered on their behalf.
    private var differentPerDisplayBinding: Binding<Bool> {
        Binding(get: { order.allowsDifferentVideoPerDisplay && differentVideoPerDisplay },
                set: { differentVideoPerDisplay = $0 })
    }

    /// A disabled control with no explanation is a mystery, so the caption
    /// changes to say why it's locked.
    private var differentPerDisplayNote: String {
        order.allowsDifferentVideoPerDisplay
            ? L10n.string("settings.different_per_display_note",
                          defaultValue: "Each display gets its own shuffle. Turned off, every display plays the same video, started together. Nothing to choose on a single-display Mac.")
            : L10n.string("settings.different_per_display_sequential",
                          defaultValue: "Sequential order plays the same video on every display — in order means in order, everywhere.")
    }

    // MARK: - Source

    private var sourceDisplayName: String {
        sourcePath.isEmpty
            ? L10n.string("settings.no_source", defaultValue: "None chosen")
            : URL(fileURLWithPath: sourcePath).lastPathComponent
    }

    /// What the saver will actually play, spelled out. A path alone doesn't
    /// tell you whether the folder still has anything in it.
    private var sourceSummary: String {
        guard !sourcePath.isEmpty else {
            return L10n.string("settings.source_hint",
                               defaultValue: "Choose a video file, or a folder of them — subfolders included.")
        }
        guard let count = videoCount else {
            return L10n.string("settings.counting", defaultValue: "Counting…")
        }
        switch count {
        case 0:  return L10n.string("settings.count_none", defaultValue: "No videos found here.")
        case 1:  return L10n.string("settings.count_one", defaultValue: "1 video.")
        default: return L10n.format("settings.count_many", defaultValue: "%d videos.", count)
        }
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie]
        panel.message = L10n.string("settings.panel_message",
                                    defaultValue: "Choose a video file, or a folder of video files")
        panel.prompt = L10n.string("settings.panel_prompt", defaultValue: "Choose")
        if !sourcePath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: sourcePath).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sourcePath = url.path
        scLog("source set to \(url.path)")
        // Counting straight away does two jobs. It tells the user what the saver
        // will play, and — for a folder inside Desktop, Documents or Downloads —
        // it triggers the macOS file-access prompt now, while they're in the
        // foreground looking at Settings, rather than later from behind a
        // fullscreen saver where the prompt is invisible.
        recount()
    }

    /// Count off the main thread: a large library is thousands of directory
    /// entries, and the count runs on every appearance of this view.
    private func recount() {
        guard !sourcePath.isEmpty else {
            videoCount = nil
            return
        }
        videoCount = nil
        Task.detached {
            let count = VideoLibrary.playlist().count
            await MainActor.run { videoCount = count }
        }
    }

    private static func minutes(min lo: Int, max hi: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = NSNumber(value: lo)
        f.maximum = NSNumber(value: hi)
        f.allowsFloats = false
        return f
    }
}

/// Bridges `JorvikShortcutRecorder` — which works in `UInt16` key codes and
/// `NSEvent.ModifierFlags` — onto the pair of Int UserDefaults keys that
/// `HotkeyManager` reads. `@AppStorage` can't hold either type directly.
private struct ShortcutRow: View {

    let label: String
    let slot: HotkeyManager.Slot

    @AppStorage private var keyCode: Int
    @AppStorage private var modifiers: Int

    init(label: String, slot: HotkeyManager.Slot) {
        self.label = label
        self.slot = slot
        _keyCode = AppStorage(wrappedValue: 0, slot.keyCodeKey)
        _modifiers = AppStorage(wrappedValue: 0, slot.modifiersKey)
    }

    var body: some View {
        JorvikShortcutRecorder(
            label: label,
            keyCode: Binding(get: { UInt16(truncatingIfNeeded: keyCode) },
                             set: { keyCode = Int($0) }),
            modifiers: Binding(get: { NSEvent.ModifierFlags(rawValue: UInt(bitPattern: modifiers)) },
                               set: { modifiers = Int(bitPattern: $0.rawValue) }),
            displayString: {
                let binding = HotkeyBinding.read(slot)
                return binding.isUnset
                    ? L10n.string("shortcut.not_set", defaultValue: "Not set")
                    : binding.displayString
            },
            onChanged: {
                // AppDelegate listens for this and re-registers the Carbon
                // hotkeys, so a new binding is live without a relaunch.
                NotificationCenter.default.post(name: .jorvikShortcutChanged, object: nil)
            }
        )
    }
}
