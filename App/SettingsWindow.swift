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

    @AppStorage("playbackOrder")  private var order: PlaybackOrder = .random
    @AppStorage("videoScaling")   private var scaling: VideoScaling = .fullScreen
    @AppStorage("soundEnabled")   private var soundEnabled: Bool = false
    @AppStorage("differentVideoPerDisplay") private var differentVideoPerDisplay: Bool = true
    @AppStorage("photosEnabled")   private var photosEnabled: Bool = true
    @AppStorage("photoSeconds")    private var photoSeconds: Int = 8
    @AppStorage("kenBurnsEnabled") private var kenBurnsEnabled: Bool = true
    @AppStorage("titleMode")          private var titleMode: TitleMode = .atStart
    @AppStorage("titleRepeatMinutes") private var titleRepeatMinutes: Int = 5
    @AppStorage("idleMinutes")    private var idleMinutes: Int = 5
    @AppStorage("lockOnDismiss")  private var lockOnDismiss: Bool = false

    /// The registered sources, held in view state so the list reorders and
    /// toggles without a round-trip through UserDefaults on every keystroke.
    /// Written back through `commit` on every change.
    @State private var sources: [VideoSource] = SourceStore.load()
    /// What was found per source, keyed by id. Absent while a count is in
    /// flight — a folder of thousands takes a moment and mustn't block the
    /// window.
    @State private var counts: [UUID: VideoLibrary.Tally] = [:]
    /// The stream field's contents, and whether what's in it can be played.
    @State private var newURL: String = ""

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

        Section(L10n.string("settings.sources", defaultValue: "Sources")) {
            if sources.isEmpty {
                Text(L10n.string("settings.no_sources",
                                 defaultValue: "Nothing to play yet. Add a folder of videos or photos, a single file, or the URL of a stream."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                HStack(spacing: 8) {
                    // Up/down rather than drag: a Form section's ForEach has no
                    // `onMove`, and nesting a List inside one to get it brings a
                    // second scroll view into a window that already scrolls.
                    // Buttons are also reachable from the keyboard, which a drag
                    // handle isn't.
                    VStack(spacing: 1) {
                        Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                            .help(L10n.string("settings.move_up", defaultValue: "Play this source earlier"))
                        Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == sources.count - 1)
                            .help(L10n.string("settings.move_down", defaultValue: "Play this source later"))
                    }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    Image(systemName: source.symbolName)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(source.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            // Dimmed when excluded: the toggle alone is a small
                            // target to read a whole row's state from.
                            .foregroundStyle(source.isEnabled ? .primary : .secondary)
                        Text(countLine(source))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    // Only for things on disk. A stream has nothing to reveal,
                    // and an enabled-looking button that did nothing would be
                    // worse than its absence.
                    if source.kind != .stream {
                        Button {
                            reveal(source)
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(source.kind == .folder
                              ? L10n.string("settings.reveal_folder",
                                            defaultValue: "Open this folder in Finder")
                              : L10n.string("settings.reveal_file",
                                            defaultValue: "Show this file in Finder"))
                    }
                    Button {
                        remove(source)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(L10n.string("settings.remove_source", defaultValue: "Remove this source"))
                    // The toggle is "include in playback" — it leaves the source
                    // registered so switching it back on doesn't mean finding it
                    // again.
                    Toggle("", isOn: Binding(
                        get: { sources[index].isEnabled },
                        set: { sources[index].isEnabled = $0; commit() }))
                        .labelsHidden()
                }
            }

            HStack {
                Button(L10n.string("settings.add_folder", defaultValue: "Add Folders…")) { add(folders: true) }
                Button(L10n.string("settings.add_files", defaultValue: "Add Files…")) { add(folders: false) }
                Spacer()
            }
            .font(.caption)

            HStack(spacing: 8) {
                Text(L10n.string("settings.stream_label", defaultValue: "Stream:"))
                TextField("", text: $newURL,
                          prompt: Text(L10n.string("settings.stream_placeholder",
                                                   defaultValue: "https://… .m3u8 or .mp4")))
                    // No `.roundedBorder`: that AppKit bezel is taller and heavier than
                    // the field style a Form gives its own rows, so it sat proud of the
                    // label and the button beside it. Four layouts were rendered and
                    // compared by eye; the Form's own style is the one that lines up.
                    //
                    // Claim the width between the label and the button. A Form row
                    // trailing-aligns its content, so without this the field asks for
                    // its ideal width — which for an empty field is almost nothing, and
                    // the wider the window the more of it goes to empty space.
                    .frame(maxWidth: .infinity)
                    .onSubmit { addStream() }
                Button(L10n.string("settings.add_stream", defaultValue: "Add")) { addStream() }
                    .disabled(VideoSource.forTypedURL(newURL) == nil)
            }
            Text(L10n.string("settings.stream_note",
                             defaultValue: "A stream is handed straight to the player, so it has to be something it can open: an HLS .m3u8 or a direct MP4, not a web page it would have to scrape. A live stream has no end, so it plays until you dismiss the saver, and a frame grab of one isn't possible."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section(L10n.string("settings.playback", defaultValue: "Playback")) {
            Picker(L10n.string("settings.order", defaultValue: "Order:"), selection: $order) {
                Text(L10n.string("settings.order_random", defaultValue: "Random"))
                    .tag(PlaybackOrder.random)
                Text(L10n.string("settings.order_sequential", defaultValue: "Sequential, by source"))
                    .tag(PlaybackOrder.sequential)
            }
            Text(L10n.string("settings.order_note",
                             defaultValue: "Sequential plays each source in turn, in the order listed above, and each source's files in path order — so a folder of folders stays together. Random shuffles everything from every switched-on source."))
                .font(.caption)
                .foregroundStyle(.secondary)

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

        Section(L10n.string("settings.photos", defaultValue: "Photos")) {
            Toggle(L10n.string("settings.photos_enabled",
                               defaultValue: "Play photos as well as videos"),
                   isOn: $photosEnabled)
            Text(L10n.string("settings.photos_note",
                             defaultValue: "Any image a folder holds — JPEG, PNG, HEIC, TIFF, camera RAW — joins the playlist alongside the videos. Turn this off if your video folders have cover art or posters in them that you would rather not see. A file you pick by hand is always played, whichever kind it is."))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text(L10n.string("settings.photo_seconds", defaultValue: "Hold each photo for:"))
                TextField("", value: $photoSeconds, formatter: Self.minutes(min: 2, max: 600))
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Text(L10n.string("settings.seconds", defaultValue: "seconds"))
                Spacer()
            }
            .disabled(!photosEnabled)

            Toggle(L10n.string("settings.ken_burns", defaultValue: "Pan and zoom (Ken Burns)"),
                   isOn: $kenBurnsEnabled)
                .disabled(!photosEnabled)
            Text(L10n.string("settings.ken_burns_note",
                             defaultValue: "A slow drift across each photo. Because a pan needs room to move into, a panning photo fills the display and ignores the Size setting above — switch this off to show photos at that size instead. Reduce Motion in System Settings turns the movement off too."))
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
                             defaultValue: "The file's own title if it has one, otherwise its filename, low in the corner for a few seconds. A copyright line is shown underneath when the file carries one — a photo's IPTC or TIFF fields count."))
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
                             defaultValue: "Saves what is on screen to ~/Pictures/Save Cannes/ — a video frame at the video's own resolution, or the photo at its full size."))
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

    // MARK: - Sources

    /// The count line under a source's name: what it will contribute to
    /// playback, or where it lives when there is nothing to count.
    private func countLine(_ source: VideoSource) -> String {
        if source.kind == .stream { return source.subtitle }
        guard let tally = counts[source.id] else {
            return L10n.string("settings.counting", defaultValue: "Counting…")
        }
        // Spelled out per kind rather than as one total: "147 items" hides the
        // thing the user most wants to know from this line, which is whether the
        // folder they just added holds what they thought it held.
        let parts = [phrase(tally.videos,
                            one: L10n.string("settings.count_one_video", defaultValue: "1 video"),
                            many: L10n.string("settings.count_videos", defaultValue: "%d videos")),
                     phrase(tally.photos,
                            one: L10n.string("settings.count_one_photo", defaultValue: "1 photo"),
                            many: L10n.string("settings.count_photos", defaultValue: "%d photos"))]
            .compactMap { $0 }
        guard !parts.isEmpty else {
            return L10n.string("settings.count_none", defaultValue: "Nothing playable found here")
        }
        return parts.joined(separator: L10n.string("settings.count_join", defaultValue: ", "))
    }

    private func phrase(_ count: Int, one: String, many: String) -> String? {
        switch count {
        case 0:  return nil
        case 1:  return one
        default: return String(format: many, count)
        }
    }

    /// Show a source in Finder so the user can see for themselves that it's the
    /// folder they meant.
    ///
    /// A folder is *opened* rather than selected in its parent — the question
    /// being answered is "is this the right folder", which is a question about
    /// what's inside it. A single file is selected in its parent instead, since
    /// opening it would launch a player over the top of Settings.
    private func reveal(_ source: VideoSource) {
        guard let url = source.url else { return }
        scLog("revealing \(url.path)")
        switch source.kind {
        case .folder: NSWorkspace.shared.open(url)
        case .file:   NSWorkspace.shared.activateFileViewerSelecting([url])
        case .stream: break
        }
    }

    /// Persist and re-read. Everything that mutates `sources` ends here, so the
    /// stored list and the list on screen can't drift apart.
    private func commit() {
        SourceStore.save(sources)
        recount()
    }

    private func add(folders: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !folders
        panel.canChooseDirectories = folders
        // Several at once: adding six folders one dialogue at a time is a chore
        // nobody should be put through.
        panel.allowsMultipleSelection = true
        if !folders { panel.allowedContentTypes = [.movie, .image] }
        panel.message = folders
            ? L10n.string("settings.panel_folders", defaultValue: "Choose folders of videos or photos")
            : L10n.string("settings.panel_files", defaultValue: "Choose videos or photos")
        panel.prompt = L10n.string("settings.panel_prompt", defaultValue: "Add")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let source = VideoSource.forPickedFile(at: url)
            // Adding the same folder twice would double every video in it.
            guard !sources.contains(where: { $0.location == source.location }) else { continue }
            sources.append(source)
            scLog("added source \(source.location)")
        }
        // Counting straight away does two jobs. It tells the user what the saver
        // will play, and — for a folder inside Desktop, Documents or Downloads —
        // it triggers the macOS file-access prompt now, while they're in the
        // foreground looking at Settings, rather than later from behind a
        // fullscreen saver where the prompt is invisible.
        commit()
    }

    private func addStream() {
        guard let source = VideoSource.forTypedURL(newURL) else { return }
        guard !sources.contains(where: { $0.location == source.location }) else { newURL = ""; return }
        sources.append(source)
        newURL = ""
        scLog("added stream \(source.location)")
        commit()
    }

    /// Swap a source with its neighbour. Order is what sequential playback
    /// follows, so this is the only way to say "this folder first" without
    /// removing and re-adding everything after it.
    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard sources.indices.contains(index), sources.indices.contains(target) else { return }
        sources.swapAt(index, target)
        scLog("moved \(sources[target].location) to position \(index + 1)")
        commit()
    }

    private func remove(_ source: VideoSource) {
        sources.removeAll { $0.id == source.id }
        scLog("removed source \(source.location)")
        commit()
    }

    /// Count each source off the main thread: a large library is thousands of
    /// directory entries, and this runs on every appearance of the view.
    private func recount() {
        let snapshot = sources
        counts = counts.filter { id, _ in snapshot.contains { $0.id == id } }
        Task.detached {
            var tally: [UUID: VideoLibrary.Tally] = [:]
            for source in snapshot where source.kind != .stream {
                tally[source.id] = VideoLibrary.tally(in: source)
            }
            // Handed over as a `let`: a captured `var` crossing into the main
            // actor is a warning today and an error in Swift 6.
            let found = tally
            await MainActor.run { counts.merge(found) { _, new in new } }
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
