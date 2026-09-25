# Save Cannes

Plays your own videos and photos as a macOS screensaver. Point it at films, folders of them, a folder of photographs, or a live stream, and it takes over every display when your Mac goes quiet.

A tribute to [Save Hollywood](http://s.sudre.free.fr/Software/SaveHollywood/about.html) by WhiteBox — the much-loved saver that did exactly this, until macOS broke it. Same idea, rebuilt from scratch on the modern Jorvik screensaver pattern.

## Features

- **Films, folders and streams**, as many as you like, mixed freely. Folders are walked recursively, and each source can be switched off without being removed. See [Sources](#sources).
- **Photos become a desk of prints**, not a slideshow: each one is thrown down onto the pile, and the picture inside the newest print won't keep still. See [The photo desk](#the-photo-desk).
- **Every display at once**, each with its own film or all showing the same one, and each display can have its own sources and fitting. See [Multiple displays](#multiple-displays).
- **Play on one display** while you keep working on the rest: a spare monitor becomes a piece of art until you click it. See [Play on one display](#play-on-one-display).
- **Titles** tell you what's playing, from the file's own metadata or its name. See [Titles](#titles).
- **Stays out of the way.** It won't start during a video call or behind the lock screen, it can be suspended from the menu bar, and Settings warns you when one of macOS's own timers would beat it. See [Using Save Cannes](#using-save-cannes).
- **Stops when something covers it**, so nothing plays or sounds behind a locked screen, and it can lock the Mac when you dismiss it. See [When something covers it](#when-something-covers-it).
- **Bad files are skipped** and a video that wedges is moved on from, so you never come back to a frozen frame.
- **Screenshots** of the frame on screen, at the video's own resolution. See [Screenshots](#screenshots).

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

After first launch you'll see a small **film-strip** icon in your menu bar. That's your only touchpoint with the app — everything else lives in its menu and its **Settings…** window. Open Settings and add a source — a folder, a file or a stream — before anything will play.

### Uninstalling

Quit Save Cannes from its menu bar icon, then drag `Save Cannes.app` to the Trash. If you installed it with Homebrew, run this instead:

```sh
brew uninstall --cask perpetualbeta/jorvik/savecannes
```

## Using Save Cannes

### Starting and stopping

When you've been idle past your configured threshold, Save Cannes covers every display with black and starts playing. Move the mouse or press any key to dismiss. If you started it yourself, from the menu or a shortcut, it waits for the pointer to stop before it treats movement as a dismiss, so carrying on to move your hand away doesn't close what you just opened.

**Play Now**, from the menu bar icon or its keyboard shortcut (set in [Activation](#activation)), starts it immediately.

Left alone, every video plays from beginning to end; the only things that cut one short are your own input, waking or unlocking the Mac, and a display being added, removed or reconfigured (which rebuilds the windows and restarts playback).

To stop a single activation running unattended for hours, or to lock the Mac when the saver goes, see [Dismiss](#dismiss).

### During a call

It won't start while something else is deliberately keeping the display awake. A video call, a film, a presentation: all of them hold a power assertion that macOS honours, and Save Cannes honours it too. Sitting still through a call looks exactly like an empty desk if you only measure the keyboard. When the call ends, the idle countdown starts again from zero rather than firing the moment it finishes.

### Suspending it

You can also stop it activating yourself, for as long as you like: click the menu bar icon and choose **Suspend**. The icon changes to show it's off, so it can't quietly stay that way for days without you noticing, and the setting survives a relaunch. **Play Now** still triggers the saver immediately regardless; suspending only ever affects the automatic, idle-triggered activation. Choose **Resume** to turn it back on.

### Play on one display

With more than one display connected, the menu bar icon's menu also lists a **Play on \<display name\>** row for each one, between Play Now and Suspend/Resume, ordered by name. Choosing one turns just that display into a piece of art — a folder of photos, a film, a stream — while every other display and app carries on exactly as it was. It does not take keyboard focus, does not hide the cursor anywhere but over its own pixels, and does not respond to the idle timeout at all: it runs until you end it yourself, either from the same menu (now reading **Stop \<display name\>**) or with a single click anywhere on that display. Moving the pointer across it, typing, or clicking somewhere else has no effect.

If "Displays have separate Spaces" is off in System Settings → Desktop & Dock, your main display has no row. It then holds the only menu bar and the Dock, and a single-screen window would cover both for every app until you clicked it away. With that setting on, every display has its own menu bar, and any of them can play.

Ending it never locks the screen, regardless of the "Lock screen when dismissed" setting in Dismiss — that toggle means stepping away from the whole Mac, which isn't what clicking a spare monitor playing something ornamental means.

Anything that covers a single-screen window ends it, and nothing brings it back: start it again from the menu. The ordinary, all-displays saver — by idle, by Play Now, or by its own hotkey — stops every single-screen window first rather than leaving two independent players fighting over the same display.

Whether a single-screen window carries sound is part of the [Sound](#sound) setting.

### When something covers it

While Save Cannes is playing, it stops when something covers it: the lock screen (whether Save Cannes locked it, or you chose Lock Now, closed the lid or used a hot corner), macOS's own screen saver, or the display going to sleep. The picture and the sound stop, and nothing plays behind the lock screen. When you come back, Save Cannes is dismissed as usual, and if **Lock screen when dismissed** is on, the Mac locks first. A single-screen window is ended instead, and never locks the Mac.

### Screenshots

Set a hotkey under Settings → Capture and press it while the saver is playing. The frame is written to `~/Pictures/Save Cannes/` as a PNG.

The frame is pulled from the video file rather than grabbed off the screen, so you get the whole frame at the video's own resolution — a screenshot taken in "full screen" mode isn't cropped to the shape of whichever display it happened to be playing on.

That also means a **live stream can't be captured**: there's no file to seek into. On-demand streams are fine.

A **photo** is re-read from its own file at full size, so what lands in `~/Pictures/Save Cannes/` is the whole photograph rather than the display-sized, cropped, part-way-through-a-zoom version that was on screen.

## Settings

Click the menu bar icon → **Settings…**. The sections below are in the same order as the window. All settings persist immediately, no Save/OK button. Changes apply the next time the saver comes up, which is always — using Settings dismisses it.

### Menu Bar

**Show icon in menu bar** hides the film-strip status icon while Save Cannes keeps running (playback is unaffected). Your choice persists across launches, including login auto-start. Re-open Save Cannes from your Applications folder to bring the icon back. *Shown only on macOS 14–15 — on macOS 26 (Tahoe) and later, use System Settings → Menu Bar, which provides this natively.*

### Sources

Add as many as you like, of three kinds:

- **Folders** are walked recursively, so subfolders are included and a library organised one-folder-per-film needs no flattening. Hidden files are skipped, and bundles (a `.photoslibrary`, an `.app`) aren't opened up. When the last video finishes, it starts again.
- **Files** are single videos or photos, played on loop when they're the only source.
- **Streams** are URLs handed straight to the player. That means they have to be something it can open by itself — an **HLS `.m3u8`** or a **direct MP4** — not a web page it would have to scrape, which rules out YouTube and the like by design rather than by omission. Only `http` and `https` are accepted, because those are the schemes that actually play; offering others would mean offering something that silently never works.

Each source has a switch. Turning one off leaves it in the list, which is the point: the alternative is deleting a source to stop playing it and then having to find it again. A source that's off is dimmed and its videos are excluded from the playlist, though its count still shows so you know what you're switching back on.

The chevrons at the left of each row move a source up or down. That matters in sequential order, which plays the sources in the order they're listed — so this is how you say "this folder first" without removing and re-adding everything after it.

Each source on disk has a **magnifying-glass button** that shows it in Finder — a folder opens so you can see what's in it, a single file is revealed in its enclosing folder. Worth a click before you walk away, to be sure the saver is pointed where you think it is.

Removing a source is the minus button beside it. Nothing is ever moved or altered on disk — Save Cannes only ever reads.

Anything that isn't a video or a photo is filtered out by file type before playback. Anything that *is* a video but can't actually be decoded — a truncated download, an unsupported codec, an audio-only file in a movie container — is skipped as it comes up, and the next one starts. If nothing in the sources can be played, the saver says so on screen rather than sitting there black.

If a folder lives in Desktop, Documents, Downloads or on an external drive, macOS asks permission the first time. See [Privacy](#privacy).

#### Streams known to work

Verified working when this was written, and useful for different things:

| Stream | URL | Notes |
|---|---|---|
| **NASA+** | `…mediatailor.us-east-1.amazonaws.com/v1/channel/NASAPrime/NASAPlus.m3u8` | Live, 24/7, Earth and space footage. The best fit for a screensaver. |
| **DW English** | `https://dwamdstream102.akamaized.net/hls/live/2015525/dwstream102/index.m3u8` | Live, 24/7 news. |
| **Apple's sample** | `https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/bipbop_4x3_variant.m3u8` | On-demand, so it *ends* — which is what you want for testing hand-over to the next source. |

NASA+'s address is generated infrastructure and should be expected to rotate. When it stops working, ask NASA for the current one rather than assuming the service has gone:

```sh
curl -s https://plus.nasa.gov/wp-json/nasaplus/v1/live-streams | python3 -m json.tool
```

The same call sometimes lists extra channels (an eclipse feed, for instance) that turn out to be recordings rather than live.

> **A live stream never hands over.** It has no end, so once a display lands on one it stays there until you dismiss the saver — the playlist can't advance past something that never finishes. That's inherent rather than a fault, but it does mean a live stream mixed into a folder of films will eventually take that display for the rest of the session, unless "Auto dismiss after" is set, which ends the activation on a clock whatever is playing.

### Playback

**Order:**

- **Random** — shuffled across everything from every switched-on source, and reshuffled each time it works through them, so you don't get the same running order twice. A directory of photographs is shuffled as one unit and kept together — see [Every photo in a folder, before the next film](#every-photo-in-a-folder-before-the-next-film).
- **Sequential** — each source in turn, in the order they're listed, and each source's files in path order. So a folder's contents stay together rather than being interleaved with another library by filename, which is nobody's intent when they added two folders separately. Every display plays the same video, in step — see [Multiple displays](#multiple-displays).

#### Sound

Off by default — a screensaver that starts talking to an empty room is nobody's friend. "Play sound" has three choices:

- **Never** — silent, always.
- **All displays** — sound on the main display only, while the ordinary, synced saver plays (by idle, Play Now, or its hotkey). Every display runs its own playback, so sound on more than one would mean the same soundtrack two or three times over, a few frames apart.
- **All displays and one single screen** — everything the option above does, plus sound on the *first* [single-screen window](#play-on-one-display) you start, whichever display that turns out to be. Starting a second one while the first still has sound leaves the second silent, for the same overlap reason.

### Display

**Size on screen:**

- **Full screen, cropped to fit** — fills the display; whatever overflows the long edge is cropped away. The default, and what you want for most footage.
- **Fit to screen, no cropping** — the whole frame is visible, letterboxed or pillarboxed on black.
- **Original size** — one video pixel to one screen pixel, centred on black. Anything larger than the display is scaled down to fit, since at a literal 1:1 it would spill off every edge and show you an arbitrary crop of the middle.

#### Multiple displays

Every display gets its own fullscreen window and its own playback. What they show follows from the playback order:

- **Sequential order always plays the same video on every display**, in step. Playing a folder in order means the same order everywhere — starting each display at a different file would make the ordering meaningless. There's nothing to decide, so the **Different video on each display** toggle is switched off and greyed out.
- **Random order lets you choose.** Leave **Different video on each display** on (the default) and each display gets its own shuffle — a three-monitor desk plays three different films at once. Turn it off and every display plays the same video from one shared shuffle, all started together.

To play on just one display while you use the others, see [Play on one display](#play-on-one-display).

### Per-display playback

The **Per-display playback** section configures each currently connected physical display independently. Choose **Configure…** beside a display, then select the sources it may play and its size-on-screen mode. This is the useful setup when, for example, an ultrawide display has a library of 21:9 films and a MacBook display has a separate library of 16:10 footage.

Displays you leave unconfigured keep the global source and size settings. A configured external display remembers its choices when disconnected and reconnects, so a dock or cable change does not mean setting it up again. Choosing **Use global settings** beside a display removes just that display's profile.

A configured display plays exactly the sources you ticked for it, whether or not those sources are switched on in **Sources**. The include-in-playback switches there set what an *unconfigured* display plays; a display you have configured has already been told what it plays, and the per-display choice wins. Two consequences worth knowing: choosing **Configure…** starts that display with every source ticked, including any you had switched off globally, so untick what you do not want; and a display with no sources ticked plays nothing, showing a faint **No Source Configured** in the middle of the screen. What bounces around it, and what happens if you watch it long enough, is left for you to find.

### Photos

Photos in a source folder join the playlist alongside the videos, and each is held for a few seconds (8 by default) before the next lands. What a folder of them looks like is described in [The photo desk](#the-photo-desk).

- **Any image type macOS recognises** counts — JPEG, PNG, HEIC, TIFF, camera RAW. Rather than a list of extensions, the file's actual type is asked of the system, so a format added to macOS in future works without a change here. PDFs and SVGs aren't images by that test, and aren't played.
- **Orientation is honoured.** A phone photo with an EXIF rotation tag is shown upright rather than on its side.
- **The photo's own title** is used for the on-screen caption when its IPTC or TIFF fields carry one, and its copyright line likewise. Otherwise the filename, exactly as for a video.
- **Turn photos off** if your film folders have cover art or downloaded posters in them that you'd rather not see as slides. A file you picked by hand is always played whichever kind it is — you chose that exact file.

### Titles

A caption low in the corner tells you what's playing. It fades in, holds for a few seconds, and fades out.

- **Never** — no caption.
- **As each video starts** — once, as each new video begins. The default.
- **Repeatedly, while it plays** — as it begins, and again every few minutes (1–60, your choice) for as long as that video runs. For a screen people wander past rather than sit in front of.

The text is the video's **own embedded title** when the file carries one, and its filename without the extension when it doesn't — which for most people's own footage is the only title there is. Never the full path; nobody wants their folder structure projected on a wall. If the file carries a copyright line, that's shown underneath in smaller type.

Captions are drawn with a soft shadow, because a video screensaver can't know what it's drawing over and white-on-white is otherwise a real possibility on the wrong shot.

### Activation

The idle timeout in minutes (5 by default), a global **Play now** hotkey (a shortcut can be cleared as well as changed), and a **Suspended** toggle that mirrors the menu bar's Suspend/Resume item.

#### Idle timeout vs. macOS's own timers

Save Cannes waits for its own idle timeout. macOS keeps two idle clocks of its own in System Settings: **Start Screen Saver when inactive**, and **Turn display off when inactive** (on a laptop, one for battery and one for the power adapter). Whichever of those fires first wins. If it fires before Save Cannes' idle timeout, the screen is already showing macOS's screen saver or has gone dark, and Save Cannes does not start into either.

The display-off timer is the one people miss. On battery, a laptop often turns its display off after two minutes, which is sooner than Save Cannes' default of five. When a macOS timer is at or under the idle timeout, Settings says so in orange under the idle timeout and names the System Settings row to change. Set **Start Screen Saver when inactive** to **Never** (Save Cannes is your screen saver now), or give the display-off timer more time than the idle timeout.

### Dismiss

- **Auto dismiss after** — a timeout in minutes (0 = never), so a single activation can't run unattended for hours or days. When it fires, the saver dismisses itself — locking the screen first if that's turned on too — and won't start itself back up until you actually touch the Mac.
- **Lock screen when dismissed** — locks the Mac as the saver goes. It needs no permission.

### Capture

A global hotkey to save the current frame to `~/Pictures/Save Cannes/`. See [Screenshots](#screenshots).

### General

**Launch at Login.**

## The photo desk

A folder of photographs isn't shown as a slideshow. Each one arrives as a **paper print with a white border, thrown down onto a desk**, landing on top of whatever is already lying there — so what builds up over a few minutes is a pile, and the collection is the thing you're watching rather than any single picture in it.

And then the trick. **The paper is dead still, and the picture inside it is not.** A print that has landed never moves again — but the image in its window drifts in and out of focus, carries the shake of a hand that isn't there, and every so often comes apart into blocks, or static, or a mess of compression, and puts itself back together. Prints are not supposed to do that, which is the point.

- **Only the newest print is alive.** As each new one comes down, the one it buries stops moving and loses its colour, so the pile beneath is monochrome and the picture on top is the only thing in the frame doing anything.
- **Focus hunts rather than drifts** — it holds a distance, then racks quickly to another, the way a lens does when it can't make up its mind. Where the photo *has* a subject, the subject is held sharp and only the world behind it goes soft; where it hasn't, the whole picture drifts together.
- **The shake is a knock, not a sway.** Nothing happens for a second or two, then the frame is jolted and settles. It shakes inside the paper's window: the print does not move with it.
- **Reduce Motion** in System Settings → Accessibility is honoured. Prints still land and still pile up, because the collection is the point — but nothing shakes, hunts focus or comes apart, and they arrive without the fall.

None of this is configurable, deliberately. It's what a folder of images does here.

The subject is found on your Mac, with a depth model that ships inside the app; nothing is uploaded. On a Mac where the model can't be loaded, photographs still pile up on the desk and still shake and glitch; they just don't drift in and out of focus. How the subject is found is described in [ARCHITECTURE.md](ARCHITECTURE.md#how-the-desk-finds-a-subject).

### Every photo in a folder, before the next film

A folder of photographs is a **collection**, and it only reads as one if the whole folder goes past before something else starts. So the images in a directory are kept together as a run: once the first of them comes up, the rest follow, and only then does the next film play.

In **random** order the runs are shuffled and the images *within* each run are shuffled too — which gives full coverage without repeats, because a shuffle is a selection without replacement. Every image in the folder is shown exactly once before any of them comes round again. In **sequential** order it's the same grouping in path order.

Grouped by the directory each image actually sits in, rather than by the source you added, because a source pointed at a photo library is usually a tree of albums — and it's the album that's the collection.

## Privacy

- **No telemetry.** No usage reporting, no log file at all unless you explicitly turn one on (see below), no network requests beyond Sparkle's appcast fetch.
- **No camera, microphone, or screen recording.** Your videos are read from the folder you chose and played locally. Nothing is copied, indexed, or uploaded.
- **Photographs are examined on your Mac.** The desk effect asks Vision where a photograph's subject is and runs a Core ML depth model over it, both entirely locally, on the machine, against files you pointed the app at. The model ships inside the app; no photograph, and nothing derived from one, leaves the Mac or touches the network.
- **Permissions:** if the folder you choose lives in Desktop, Documents, Downloads, or on an external drive, macOS will ask you to allow access the first time. Save Cannes triggers that prompt at the moment you pick the folder — while you're looking at Settings — rather than later from behind a fullscreen saver where you couldn't see it. Nothing else is asked for: locking the screen needs no permission.
- **Logging** is off by default. To turn it on:

  ```sh
  defaults write cc.jorviksoftware.SaveCannes debugLogging -bool YES
  ```

  Timestamped lifecycle lines then go to `~/Library/Logs/Save Cannes/savecannes.log`, including every skipped file with the reason AVFoundation gave, and every time the stall watchdog moves on.

## Auto-update

Save Cannes uses [Sparkle 2.x](https://sparkle-project.org/) for auto-update. Updates check daily against `https://jorviksoftware.cc/appcasts/savecannes.xml`. Trigger a manual check via the menu's **Check for Updates…** item.

Updates are EdDSA-signed; your copy will only install genuine Jorvik Software releases.

## Troubleshooting

Several of these ask you to turn logging on; the command is under [Privacy](#privacy).

**Nothing plays, and the screen says "No video sources yet".** Open Settings → Sources and add a folder, a file or a stream.

**A stream won't play.** Paste the URL into Safari or QuickTime Player — if they can't play it either, it isn't a media URL, and Save Cannes hands URLs to the same underlying player. A page that *shows* a video is not the same as the video's own address.

**Everything is switched off.** The saver says so explicitly rather than claiming there are no videos, because those need different fixes.

**The folder is right but it says no videos were found.** Save Cannes lists files by type, not by extension. If the files aren't recognised as movies by macOS — check one in Finder's Get Info — they won't be listed. An external drive that isn't mounted looks the same as an empty folder.

**It skips a file I know plays in QuickTime.** Then it isn't skipping it for the reason you think. Turn logging on, let the saver run, and read `~/Library/Logs/Save Cannes/savecannes.log` — every skip is logged with the reason AVFoundation gave.

**It never comes on, even after sitting idle for ages.** Look under the idle timeout in Settings → Activation. An orange note there means one of macOS's own timers fires first every time. See [Idle timeout vs. macOS's own timers](#idle-timeout-vs-macoss-own-timers).

**The saver comes up the moment I log in.** It shouldn't: activation is suppressed for 30 seconds after any wake or unlock, because system idle time keeps counting while the Mac is asleep. If you see it anyway, the log will show the wake event that was — or wasn't — received.

**I don't want it to activate for a while.** Choose **Suspend** from the menu bar icon. See [Suspending it](#suspending-it).

**It's been running for hours and nobody's there.** Set Settings → Dismiss → "Auto dismiss after" to a number of minutes. With "Lock screen when dismissed" on, this stops decoding and playback immediately, which is most of what you're after — but the player itself isn't fully released until the Mac is actually unlocked, same as a manual dismiss with that toggle on.

**No sound.** Check Settings → Playback → "Play sound". With multiple displays the soundtrack plays on the main display's copy only, and a single-screen window has sound only with **All displays and one single screen**, and then only the first one you start.

**A video seems to end early.** A watchdog moves on from a video whose playhead has genuinely stopped, so a wedged file can't leave a frozen frame up all night. Turn logging on and look for `watchdog:` lines — it names the moment it acted. If there are no such lines, the file ended where it says it ends; check its duration in Finder's Get Info.

## How it works

Why Save Cannes is an app rather than a `.saver`, how the code is laid out, the playback engine, the stall watchdog and how the photo desk finds a subject are all in [ARCHITECTURE.md](ARCHITECTURE.md).

## Building from Source

The build is driven by the shared [`release.mk`](https://github.com/PerpetualBeta/jorvik-release) Make include, so `jorvik-release` has to be checked out **beside this repo** — the Makefile looks for it at `../jorvik-release/`. macOS ships GNU Make 3.81 as `make`, which is too old, so `gmake` comes from [Homebrew](https://brew.sh).

```bash
brew install make   # GNU Make 4+, if you do not already have gmake
git clone https://github.com/PerpetualBeta/jorvik-release.git
git clone https://github.com/PerpetualBeta/SaveCannes.git
cd SaveCannes
gmake build
open ".build/Save Cannes.app"
```

Other targets:

- `gmake dev-build` — local build signed with the Jorvik Developer ID
- `gmake run` — run the freshly-built copy
- `gmake icon` — regenerate the app icon from `generate_icon.swift`
- `gmake release` — signed, notarised, stapled `.zip` and `.pkg` ready to ship

## The other Jorvik screensavers

- **[Rainy Day](https://jorviksoftware.cc/screensavers/rainyday)** — raindrops gather on a pane of glass and slip down it, refracting the photograph behind them. The app that established this shape.
- **[ASCII Saver](https://jorviksoftware.cc/screensavers/asciisaver)** — your live camera feed rendered as ASCII art, in classic, Matrix, amber, raw and silhouette modes.
- **[Reverie](https://jorviksoftware.cc/screensavers/reverie)** — roulette curves drawn progressively in dark ink over an animated wavescape. Still a `.saver` bundle, and rightly so: it needs no permission for anything, so it has no reason to be an app.

---

Save Cannes is provided by [Jorvik Software](https://jorviksoftware.cc/). If you find it useful, consider [buying me a coffee](https://jorviksoftware.cc/donate).
