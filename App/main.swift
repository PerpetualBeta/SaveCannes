import AppKit

// Save Cannes — plays your own video files as a screensaver.
//
// A tribute to Save Hollywood, the much-loved saver that did exactly this
// and stopped working somewhere along the way. Same idea, rebuilt on the
// Jorvik screensaver-as-app pattern: point it at a video file or a folder
// of them and it plays them full screen when the Mac goes quiet.
//
// Why an app, not a .saver: hosting AVFoundation playback inside
// legacyScreenSaver means fighting process suspension and per-preview
// lifecycle thrash for nothing in return, and a hosted saver cannot hold
// a file-access grant of its own — the TCC identity belongs to Apple's
// host binary. A regular app opens the user's folder and plays from it.
// See kb/conventions/screensaver-as-app.md.

let app = NSApplication.shared
// .accessory == LSUIElement: no Dock icon, no menu bar, no app switcher
// entry. The user never sees the app itself; only the video when idle,
// and the status item.
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
