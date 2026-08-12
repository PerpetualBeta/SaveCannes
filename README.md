# Save Cannes

Plays your own videos as a macOS screensaver. Point it at a film, or at a folder of them, and it takes over every display when your Mac goes quiet.

A tribute to [Save Hollywood](http://s.sudre.free.fr/Software/SaveHollywood/about.html) by WhiteBox — the much-loved saver that did exactly this, until macOS broke it. Same idea, rebuilt from scratch on the modern Jorvik screensaver pattern.

## Requirements

- macOS 14 (Sonoma) or later
- Universal binary (Apple Silicon and Intel)

## Installation

Two formats on every release — both signed and notarised, pick whichever suits:

- **[Installer (`.pkg`)](https://github.com/PerpetualBeta/SaveCannes/releases/latest/download/SaveCannes.pkg)** — recommended for first-time installs. Double-click to run; macOS Installer places `Save Cannes.app` in `/Applications/` without quarantine or App Translocation.
- **[Download (`.zip`)](https://github.com/PerpetualBeta/SaveCannes/releases/latest)** — unzip and drag `Save Cannes.app` to your `/Applications/` folder.

Or install it with [Homebrew](https://brew.sh):

```sh
brew install --cask perpetualbeta/jorvik/savecannes
```

Either way, the first launch happens immediately. Save Cannes registers itself for launch at user login on first run; toggle that off in Settings → General if you'd rather start it manually.

After first launch you'll see a small **film-strip** icon in your menu bar. That's your only touchpoint with the app — everything else lives in its menu and its **Settings…** window. Open Settings and choose a video source before anything will play.

To uninstall: `pkill -f "Save Cannes"` then drag `Save Cannes.app` to the Trash.

## Why an app, not a `.saver`

Save Cannes is a screensaver-style product, but it ships as a regular `.app` rather than as a `.saver` bundle.

The deciding reason is file access. A `.saver` runs inside Apple's `legacyScreenSaver` host process, which owns the permission identity — a hosted saver can never hold a file-access grant of its own, so it could never reliably read the video folder you chose. There's a longer list of reasons besides (process suspension, multi-instance preview lifecycle, removed SPIs) that the rest of the Jorvik saver family ran into first.

Save Hollywood hit this wall first, and its author's own account is worth reading, because it's the same wall: *"In macOS Catalina, Apple completely broke the standard open panel APIs when invoked from a screen saver."* Choosing a file **is** the entire interface for a saver like this, and from inside the host process there was no longer a supported way to offer it — the note goes on to say that working around it would need APIs Apple keeps private for its own screensavers. Save Cannes puts the picker, and the file access it grants, in an ordinary app where both still work.

As a regular app it gets out of its own way: it asks for your folder, plays from it, and gives full control over the configurator, hotkeys, and lock-screen integration a saver bundle can't reach.

## What it does

When you've been idle past your configured threshold, Save Cannes covers every display with black and starts playing. Move the mouse or press any key to dismiss.

- **One file** plays on loop.
- **A folder** plays through everything in it, including subfolders — so a library organised one-folder-per-film needs no flattening. When the last video finishes, it starts again.
- **Bad files are skipped**, silently and immediately. Anything that isn't a video is filtered out by file type before playback; anything that *is* a video but can't actually be decoded — a truncated download, an unsupported codec, an audio-only file in a movie container — is skipped as it comes up, and the next one starts. If nothing in the folder can be played, the saver says so on screen rather than sitting there black.
- **Multiple displays** each get their own window and their own playback. In sequential order they all play the same video, in step; in random order each gets its own film by default, or you can have them match.

## Configuration

Click the menu bar icon → **Settings…** for:

- **Permissions** — accessibility status (required only if you enable Lock Screen on dismiss)
- **Video** — the source (a file or a folder, with a count of what was found), playback order, and sound
- **Display** — how each video is fitted to the screen, and whether every display shows the same one
- **Titles** — whether the title of what's playing appears on screen, and how often
- **Activation** — idle timeout in minutes, and a global "Play now" hotkey
- **On dismiss** — toggle to lock the screen automatically when the saver dismisses
- **Capture** — global hotkey to save the current frame to `~/Pictures/Save Cannes/`
- **Show icon in menu bar** — hide the film-strip status icon while Save Cannes keeps running (playback is unaffected). Your choice persists across launches, including login auto-start. *Shown only on macOS 14–15 — on macOS 26 (Tahoe) and later, use System Settings → Menu Bar, which provides this natively.*
- **General** — Launch at Login

All settings persist immediately, no Save/OK button. Changes apply the next time the saver comes up, which is always — using Settings dismisses it.

### Playback order

- **Random** — shuffled, and reshuffled every time it works through the folder, so you don't get the same running order twice.
- **Sequential** — alphabetical, by path. In a flat folder that's plain filename order; where there are subfolders, each folder's videos stay together and play in order. Every display plays the same video, in step — see **Multiple displays** below.

### Size on screen

- **Full screen, cropped to fit** — fills the display; whatever overflows the long edge is cropped away. The default, and what you want for most footage.
- **Fit to screen, no cropping** — the whole frame is visible, letterboxed or pillarboxed on black.
- **Original size** — one video pixel to one screen pixel, centred on black. Anything larger than the display is scaled down to fit, since at a literal 1:1 it would spill off every edge and show you an arbitrary crop of the middle.

### Multiple displays

Every display gets its own fullscreen window and its own playback. What they show follows from the playback order:

- **Sequential order always plays the same video on every display**, in step. Playing a folder in order means the same order everywhere — starting each display at a different file would make the ordering meaningless. There's nothing to decide, so the **Different video on each display** toggle is switched off and greyed out.
- **Random order lets you choose.** Leave **Different video on each display** on (the default) and each display gets its own shuffle — a three-monitor desk plays three different films at once. Turn it off and every display plays the same video from one shared shuffle, all started together.

Your choice is remembered while the control is locked: switch to sequential order and back to random, and the toggle is where you left it.

Displays showing the same video are started together but aren't frame-locked: separate players drift by a frame or two over a long clip. Side by side you're unlikely to notice; if it ever matters, the fix is `AVPlayer.setRate(_:time:atHostTime:)` against a common clock.

### Sound

Off by default — a screensaver that starts talking to an empty room is nobody's friend. Turn it on in Settings → Video.

With more than one display, sound plays on the main display only. Each display runs its own playback, so sound on all of them would mean the same soundtrack two or three times over, a few frames apart.

### Titles

A caption low in the corner tells you what's playing. It fades in, holds for a few seconds, and fades out.

- **Never** — no caption.
- **As each video starts** — once, as each new video begins. The default.
- **Repeatedly, while it plays** — as it begins, and again every few minutes (1–60, your choice) for as long as that video runs. For a screen people wander past rather than sit in front of.

The text is the video's **own embedded title** when the file carries one, and its filename without the extension when it doesn't — which for most people's own footage is the only title there is. Never the full path; nobody wants their folder structure projected on a wall. If the file carries a copyright line, that's shown underneath in smaller type.

Captions are drawn with a soft shadow, because a video screensaver can't know what it's drawing over and white-on-white is otherwise a real possibility on the wrong shot.

### Screenshots

Set a hotkey under Settings → Capture and press it while the saver is playing. The frame is written to `~/Pictures/Save Cannes/` as a PNG.

The frame is pulled from the video file rather than grabbed off the screen, so you get the whole frame at the video's own resolution — a screenshot taken in "full screen" mode isn't cropped to the shape of whichever display it happened to be playing on.

## Auto-update

Save Cannes uses [Sparkle 2.x](https://sparkle-project.org/) for auto-update. Updates check daily against `https://jorviksoftware.cc/appcasts/savecannes.xml`. Trigger a manual check via the menu's **Check for Updates…** item.

Updates are EdDSA-signed; your copy will only install genuine Jorvik Software releases.

## Privacy

- **No telemetry.** No usage reporting, no log file at all unless you explicitly turn one on (`defaults write cc.jorviksoftware.SaveCannes debugLogging -bool YES` writes timestamped lifecycle lines to `~/Library/Logs/Save Cannes/savecannes.log`; off by default), no network requests beyond Sparkle's appcast fetch.
- **No camera, microphone, or screen recording.** Your videos are read from the folder you chose and played locally. Nothing is copied, indexed, or uploaded.
- **Permissions:** if the folder you choose lives in Desktop, Documents, Downloads, or on an external drive, macOS will ask you to allow access the first time. Save Cannes triggers that prompt at the moment you pick the folder — while you're looking at Settings — rather than later from behind a fullscreen saver where you couldn't see it. Accessibility is requested only if you enable "Lock screen when dismissed".

## Architecture

- **App** (`App/`) — the lifecycle (`AppDelegate`), the fullscreen window per display (`ScreensaverWindow`), the playback surface (`VideoStage`), source resolution (`VideoLibrary`), the title caption (`TitleOverlay`), status menu, settings window, Carbon hotkeys, lock-screen and screenshot integration.
- **JorvikKit** (`App/JorvikKit/`) — vendored shared components from the Jorvik suite (About modal, Settings frame, shortcut recorder, Sparkle focus guard, localisation shim, window helper).
- **Sparkle** (`Sparkle.framework`) — vendored 2.9.1 binary, embedded under `Contents/Frameworks/`.

Playback is `AVPlayer` into an `AVPlayerLayer`, one per display, walking a playlist read fresh from disk on every activation. Whether displays match is a matter of which list they walk: one shared array, ordered once at activation, or one array per display. (Sharing a single `AVPlayer` across layers isn't an option — only the most recently created `AVPlayerLayer` renders.) Whether the per-display option is available at all is one property, `PlaybackOrder.allowsDifferentVideoPerDisplay`, read by both the engine and the Settings toggle so they can't disagree. The three size options are two `videoGravity` values plus, for original size, a layer frame computed from the video's pixel dimensions divided by the display's backing scale.

"Screensaver delivered as a regular `.app`" is the default shape for Jorvik screensavers, established by [Rainy Day](https://jorviksoftware.cc/screensavers/rainyday) and followed by [ASCII Saver](https://jorviksoftware.cc/screensavers/asciisaver).

## Building from source

Save Cannes builds via the shared Jorvik `release.mk`. With the `jorvik-release` sibling repo cloned alongside it and [GNU Make](https://formulae.brew.sh/formula/make) 4 installed:

- Clone the repo: `git clone https://github.com/PerpetualBeta/SaveCannes.git`
- Local build (signed with the Jorvik Developer ID): `gmake dev-build`
- Run the freshly-built copy: `gmake run`
- Regenerate the app icon: `gmake icon`
- Signed, notarised, stapled `.zip` and `.pkg` ready to ship: `gmake release`

## The other Jorvik screensavers

- **[Rainy Day](https://jorviksoftware.cc/screensavers/rainyday)** — raindrops gather on a pane of glass and slip down it, refracting the photograph behind them. The app that established this shape.
- **[ASCII Saver](https://jorviksoftware.cc/screensavers/asciisaver)** — your live camera feed rendered as ASCII art, in classic, Matrix, amber, raw and silhouette modes.
- **[Reverie](https://jorviksoftware.cc/screensavers/reverie)** — roulette curves drawn progressively in dark ink over an animated wavescape. Still a `.saver` bundle, and rightly so: it needs no permission for anything, so it has no reason to be an app.

## Troubleshooting

**Nothing plays, and the screen says "No video source chosen".** Open Settings → Video and choose a file or folder.

**The folder is right but it says no videos were found.** Save Cannes lists files by type, not by extension. If the files aren't recognised as movies by macOS — check one in Finder's Get Info — they won't be listed. An external drive that isn't mounted looks the same as an empty folder.

**It skips a file I know plays in QuickTime.** Then it isn't skipping it for the reason you think. Turn logging on (`defaults write cc.jorviksoftware.SaveCannes debugLogging -bool YES`), let the saver run, and read `~/Library/Logs/Save Cannes/savecannes.log` — every skip is logged with the reason AVFoundation gave.

**The saver comes up the moment I log in.** It shouldn't: activation is suppressed for 30 seconds after any wake or unlock, because system idle time keeps counting while the Mac is asleep. If you see it anyway, the log will show the wake event that was — or wasn't — received.

**No sound.** Check Settings → Video, and note that with multiple displays the soundtrack plays on the main display's copy only.

---

Save Cannes is provided by [Jorvik Software](https://jorviksoftware.cc/). If you find it useful, consider [buying me a coffee](https://jorviksoftware.cc/donate).
