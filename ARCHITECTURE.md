# Save Cannes architecture

How Save Cannes is built, and why. For what it does and how to use it, see the [README](README.md).

## Why an app, not a `.saver`

Save Cannes is a screensaver-style product, but it ships as a regular `.app` rather than as a `.saver` bundle.

The deciding reason is file access. A `.saver` runs inside Apple's `legacyScreenSaver` host process, which owns the permission identity — a hosted saver can never hold a file-access grant of its own, so it could never reliably read the video folder you chose. There's a longer list of reasons besides (process suspension, multi-instance preview lifecycle, removed SPIs) that the rest of the Jorvik saver family ran into first.

Save Hollywood hit this wall first, and its author's own account is worth reading, because it's the same wall: *"In macOS Catalina, Apple completely broke the standard open panel APIs when invoked from a screen saver."* Choosing a file **is** the entire interface for a saver like this, and from inside the host process there was no longer a supported way to offer it — the note goes on to say that working around it would need APIs Apple keeps private for its own screensavers. Save Cannes puts the picker, and the file access it grants, in an ordinary app where both still work.

As a regular app it gets out of its own way: it asks for your folder, plays from it, and gives full control over the configurator, hotkeys, and lock-screen integration a saver bundle can't reach.

"Screensaver delivered as a regular `.app`" is the default shape for Jorvik screensavers, established by [Rainy Day](https://jorviksoftware.cc/screensavers/rainyday) and followed by [ASCII Saver](https://jorviksoftware.cc/screensavers/asciisaver).

## Layout

- **App** (`App/`) — the lifecycle (`AppDelegate`), the fullscreen window per display (`ScreensaverWindow`), the playback surface (`VideoStage`), the source list and its storage (`VideoSource`), source resolution and run grouping (`VideoLibrary`), per-display profiles keyed by the display's hardware identity (`DisplayProfile`), the title caption (`TitleOverlay`), the status menu (`StatusItem`), the settings window (`SettingsWindow`), hotkey slots (`HotkeyManager`), the lock-screen call (`LockScreen`), screenshots (`Screenshot`), the check for another app holding the display awake (`DisplayWake`), the reading of macOS's own screen-saver and display-off timers (`SystemScreenLockSettings`), the empty-display screen (`DVDLogo`, `DVDLogoPath`, `NoticeDrift`) and the optional log (`Log`).
- **The desk** (`App/PhotoDesk*.swift`, `App/PhotoDepth.swift`, `App/PhotoFocus.swift`) — what a folder of photographs does: the look and the motion model, the Metal shaders, the desk surface and its canvas, monocular depth and the subject-certainty gate, and Vision's attention point. `Resources/DepthAnythingV2Small.mlmodelc` is the depth model, Apache 2.0, shipped compiled.
- **JorvikKit** (`App/JorvikKit/`) — vendored shared components from the Jorvik suite: About modal, Settings frame, hotkey manager and shortcut recorder, menu-bar icon visibility, permission watcher, Sparkle focus guard, localisation shim and window helper.
- **Sparkle** (`Sparkle.framework`) — vendored 2.9.1 binary, embedded under `Contents/Frameworks/`.

## Playback

Playback is `AVPlayer` into an `AVPlayerLayer`, one per display, walking a playlist read fresh on every activation — folders walked then, so adding files takes effect next time the saver comes up. A stream is the same `AVPlayerItem` with a remote URL, which is why streams cost almost no extra code: the skip-on-failure path, the watchdog and the ordering all treat them like anything else.

Whether displays match is a matter of which list they walk: one shared array, ordered once at activation, or one array per display. (Sharing a single `AVPlayer` across layers isn't an option — only the most recently created `AVPlayerLayer` renders.) Whether the per-display option is available at all is one property, `PlaybackOrder.allowsDifferentVideoPerDisplay`, read by both the engine and the Settings toggle so they can't disagree.

The three size options are two `videoGravity` values plus, for original size, a layer frame computed from the video's pixel dimensions divided by the display's backing scale.

Displays showing the same video are started together but aren't frame-locked: separate players drift by a frame or two over a long clip. Side by side you're unlikely to notice; if it ever matters, the fix is `AVPlayer.setRate(_:time:atHostTime:)` against a common clock.

## The stall watchdog

Behind normal playback there's a watchdog, for the one case that would otherwise leave you looking at a still frame indefinitely: a file that plays but never reports that it finished. Every two seconds the watchdog compares the playhead against where it was, and steps in only when the picture has genuinely stopped —

- **parked at the end** for four seconds with no end-of-play notification, or
- **frozen anywhere** for thirty seconds while the player still believes it's playing.

Both thresholds are deliberately unhurried. A file on a sleeping external drive or a network volume can legitimately stall for several seconds, and cutting a good film short would be a worse fault than the one being guarded against. A video we've paused ourselves — behind the lock screen — is never treated as stalled. In normal playback the watchdog never acts at all: it doesn't fire once across a full pass of a test folder, and no clip loses so much as a frame to it.

Interventions are logged as `watchdog:` lines when logging is on.

## How the desk finds a subject

macOS's Vision framework will hand over a subject mask for very nearly any photograph, so its word alone isn't worth much. Instead the answer is built from things that don't depend on each other: whether the masked region really is nearer than the rest of the picture, whether its outline sits on a *step* in the depth rather than running through flat ground, whether the place a person would look falls inside it, and whether it's one compact thing rather than several scraps of scenery. All four have to agree. Measured across fourteen photographs, that accepted every one with a subject and rejected every one without — the single case it turns down that does contain a person is a figure occupying 0.4% of the frame, where holding it sharp would make no visible difference anyway.

Depth comes from **Depth Anything V2 Small**, a Core ML model from Apple's own model library, used under the Apache 2.0 licence and shipped inside the app (about 18MB of it). Nothing is uploaded and nothing is asked of the network — the model runs on your Mac, on your photographs, and Save Cannes has no network access for anything but its own update check.
