import AppKit
import AVFoundation

/// The video surface for one display: an `AVPlayerLayer` walking a playlist,
/// skipping anything it can't play, looping forever.
///
/// One instance per `ScreensaverWindow`, so each display owns its own player
/// and its own position in the playlist. Sharing one player across displays
/// would mean mirroring the same frame everywhere, which is a different
/// product; independent players cost one decode per display and let a
/// two-monitor setup show two different films.
///
/// Settings are pushed in before `start()` and read once per activation —
/// changing them in Settings applies the next time the saver comes up, which
/// is always, because using Settings dismisses the saver.
final class VideoStage: NSView {

    var order: PlaybackOrder = .random
    var scaling: VideoScaling = .fullScreen
    /// Only one display's stage gets audio — see `AppDelegate.showWindows()`.
    var soundEnabled = false

    /// The exact list this stage plays, shared with every other display so
    /// they mirror each other. Ordered once by `AppDelegate`, which is what
    /// keeps the displays in step: they're playing identical files, started
    /// together, so they advance together.
    ///
    /// nil means the stage builds and orders its own list — "different video
    /// on each display", where independent shuffles (or `startOffset`, in
    /// sequential order) keep them apart.
    var sharedPlaylist: [URL]?

    /// How far into the list this stage starts. Without it, "different video
    /// on each display" would be a lie in sequential order — every display
    /// would begin at the first file and play the same one.
    var startOffset = 0

    var titleMode: TitleMode = .atStart
    /// Gap between repeats in `.repeatedly` mode.
    var titleRepeatMinutes = 5

    /// How long each photo is held. A still has no duration of its own, so
    /// unlike a video the length has to come from somewhere — this is the only
    /// honest place for it to come from, which is why it's a setting rather than
    /// a constant picked in here.
    var photoSeconds = 8
    /// Whether a photo slowly pans and zooms while it's up.
    var kenBurnsEnabled = true
    /// How far a photo is zoomed by the end of its pan, which also sets how far
    /// the pan can travel — see `photoZoom`.
    var kenBurnsZoom = VideoStage.defaultKenBurnsZoom
    /// Whether the subject of a photo is lifted off its background and moved
    /// separately — see `PhotoParallax`. Off while it is being judged.
    var parallaxEnabled = false
    /// How much further the subject travels than the scene behind it.
    var parallaxStrength = VideoStage.defaultParallaxStrength

    private let player = AVPlayer()
    private let playerLayer = AVPlayerLayer()
    /// Where photos are drawn. A separate layer from the player's, rather than
    /// reusing one surface, because the two are handed their content in
    /// completely different ways and swapping between them is then just a
    /// matter of which one is hidden.
    private let stillLayer = CALayer()
    /// The subject of the photo, cut out and drawn over `stillLayer`, when the
    /// photo has one and the effect is on. Hidden otherwise, which is what
    /// `startKenBurns` reads to decide whether there is a near plane to move.
    private let subjectLayer = CALayer()
    /// Advances off a photo. The video path is driven by the player reaching the
    /// end of its item; a still would sit there forever, so it gets a clock.
    private var stillTimer: Timer?
    /// The photo on screen, for `Screenshot` — and the flag that says a still
    /// is what's showing, since the player is emptied while one is up.
    private(set) var currentStill: (url: URL, image: CGImage)?
    /// Where the eye goes in the photo on screen, if Vision could say. Both the
    /// crop and the pan are aimed at it; nil means neither is, which is how
    /// photos were framed before it was measured.
    private(set) var currentFocus: PhotoFocus?
    /// Where the photo's subject meets the world, when one was lifted — the point
    /// the subject grows about. See `PhotoLayers.anchor`.
    private var currentAnchor: CGPoint?
    private var notice: NSTextField?
    private let overlay = TitleOverlay(frame: .zero)
    /// What the caption should say for the item playing now, kept so the
    /// periodic repeat has something to re-show.
    private var currentCaption: (title: String, copyright: String?)?
    private var titleTimer: Timer?

    /// Watchdog state: the item's stated duration, the playhead at the last
    /// look, and how long it has read the same value.
    private var watchdog: Timer?
    private var currentDurationSeconds: Double?
    private var lastPlayhead: Double?
    private var frozenSeconds: TimeInterval = 0

    /// Remaining candidates for this pass. Refilled when it empties, so
    /// playback loops forever: reshuffled each pass in random order, same
    /// sequence every pass in sequential order.
    private var queue: [URL] = []
    /// How many candidates the source last offered, and how many have failed
    /// in a row. Once a whole pass has failed there is nothing playable in
    /// the source, and continuing would spin through the same dead files at
    /// full speed forever — so we stop and say so instead.
    private var candidatesInSource = 0
    private var failuresSinceLastSuccess = 0

    private var itemObservers: [NSObjectProtocol] = []
    private var statusObservation: NSKeyValueObservation?
    private var presentationObservation: NSKeyValueObservation?
    /// Pixel dimensions of the current item, rotation applied. Only
    /// `.originalSize` needs it; nil until an item is loaded.
    private var currentPixelSize: CGSize?
    private var running = false

    // MARK: - Construction

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        // A photo zoomed past 1.0 is a layer larger than this view; without this
        // it would paint over the neighbouring display's window edge.
        layer?.masksToBounds = true
        playerLayer.player = player
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
        stillLayer.backgroundColor = NSColor.black.cgColor
        // Nearest-neighbour on a photo being slowly zoomed would crawl; the
        // filters cost nothing on one static image per several seconds.
        stillLayer.minificationFilter = .trilinear
        stillLayer.magnificationFilter = .trilinear
        stillLayer.isHidden = true
        layer?.addSublayer(stillLayer)
        subjectLayer.minificationFilter = .trilinear
        subjectLayer.magnificationFilter = .trilinear
        subjectLayer.isHidden = true
        layer?.addSublayer(subjectLayer)
        // Sized here, and again in `layout()`. An autoresizing mask alone
        // isn't enough: it only fires when the superview *changes* size, and
        // this view is created at its final size, so a subview added at
        // .zero would stay at .zero and the caption would never be drawn.
        // Cost me a caption that logged perfectly and rendered nothing.
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        keepVideoBehind()
    }

    /// Force the video layer to the back of the layer tree.
    ///
    /// `playerLayer` is added directly to this view's layer, while the caption
    /// and the notice are ordinary subviews whose layers AppKit inserts into
    /// the same tree. Relying on the order AppKit happens to choose between the
    /// two would be relying on an implementation detail — and losing that bet
    /// means the caption renders *under* the picture, i.e. invisibly. Pinning
    /// the video at index 0 settles it.
    private func keepVideoBehind() {
        guard let layer = layer else { return }
        if playerLayer.superlayer === layer { layer.insertSublayer(playerLayer, at: 0) }
        // Above the video, still behind the caption: the two picture layers are
        // never visible at once, so their order relative to each other is only
        // about keeping both of them under the text.
        if stillLayer.superlayer === layer { layer.insertSublayer(stillLayer, at: 1) }
        // Directly over the photo it was cut out of, and still under the caption.
        if subjectLayer.superlayer === layer { layer.insertSublayer(subjectLayer, at: 2) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        detachItem()
        titleTimer?.invalidate()
        watchdog?.invalidate()
        stillTimer?.invalidate()
    }

    // MARK: - Lifecycle

    /// Build the playlist and start playing. Safe to call once per activation.
    /// The playlist is filled by `playNext()`, which refills whenever the
    /// queue runs dry — including the first time, when it's empty.
    func start() {
        running = true
        player.isMuted = !soundEnabled
        playNext()
    }

    /// Halt playback but leave the window mounted, for while the system lock
    /// screen covers us. There is no paired resume — the windows are torn
    /// down on unlock.
    func pause() {
        player.pause()
        // A photo's clock has to stop too, or the lock screen spends its time
        // silently walking the playlist and we come back somewhere else.
        stopStillTimer()
        stopTitleTimer()
        // A paused playhead is motionless by definition; leaving the watchdog
        // armed here would have it "rescue" us from our own lock screen.
        stopWatchdog()
    }

    /// Tear playback down. The player is emptied rather than just paused so
    /// the decoder and any open file handles go away with the saver, instead
    /// of being held for the hours between activations.
    func stop() {
        running = false
        player.pause()
        detachItem()
        stopTitleTimer()
        overlay.cancel()
        currentDurationSeconds = nil
        currentCaption = nil
        player.replaceCurrentItem(with: nil)
        queue.removeAll()
        currentPixelSize = nil
        stopStillTimer()
        clearStill()
    }

    /// The asset and playhead position for `Screenshot`, or nil when nothing
    /// is playing.
    var currentFrame: (asset: AVAsset, time: CMTime)? {
        guard let item = player.currentItem else { return nil }
        return (item.asset, item.currentTime())
    }

    // MARK: - Playlist walk

    private func refill() {
        let all = sharedPlaylist ?? VideoLibrary.orderedPlaylist(order)
        candidatesInSource = all.count
        // Rotating rather than slicing means a stage that starts at file 3
        // still plays 1 and 2 afterwards — every display sees the whole
        // library, just from a different point in it.
        queue = all.isEmpty ? [] : Array(all[(startOffset % all.count)...]
                                       + all[..<(startOffset % all.count)])
        scLog("playlist: \(all.count) video(s), order=\(order == .random ? "random" : "sequential")"
              + (sharedPlaylist == nil ? "" : ", shared")
              + (startOffset == 0 ? "" : ", from #\(startOffset + 1)"))
    }

    private func playNext() {
        guard running else { return }
        detachItem()
        if queue.isEmpty { refill() }

        guard !queue.isEmpty else {
            showNotice(emptySourceMessage())
            return
        }
        // A whole pass has failed — every file in the source has been tried
        // since the last one that played. Stop rather than loop.
        guard failuresSinceLastSuccess < candidatesInSource else {
            showNotice(candidatesInSource == 1
                ? L10n.string("stage.none_playable_one",
                              defaultValue: "The one video your sources offer could not be played.")
                : L10n.format("stage.none_playable",
                              defaultValue: "None of the %d videos from your sources could be played.",
                              candidatesInSource))
            return
        }
        let url = queue.removeFirst()
        // Decided per item rather than per source: one folder can hold both,
        // which is the whole point of playing photos at all.
        if VideoLibrary.isImage(url) {
            Task { await presentStill(url) }
        } else {
            Task { await present(url) }
        }
    }

    /// Load one candidate and put it on screen, or skip to the next.
    ///
    /// `isPlayable` plus the video-track check catches the two cheap cases —
    /// a file AVFoundation can't open at all, and an audio-only container
    /// that the type filter in `VideoLibrary` can't tell from a movie. What
    /// they don't catch (a file that decodes its header and then fails
    /// mid-stream) is handled by the observers in `attach`.
    @MainActor
    private func present(_ url: URL) async {
        let asset = AVURLAsset(url: url)
        let size: CGSize?
        do {
            guard try await asset.load(.isPlayable) else {
                throw StageError.notPlayable
            }
            let pixels = try await Self.pixelSize(of: asset)
            // **An HLS asset has no tracks to load until it is playing**, so
            // `loadTracks` legitimately comes back empty for a stream. Treating
            // that as "no video track" rejected every stream before it played —
            // the guard was written for an audio-only *file* and is only
            // meaningful there. For a remote asset the size arrives later, from
            // the player item's `presentationSize`.
            if pixels == nil, url.isFileURL {
                throw StageError.noVideoTrack
            }
            size = pixels
        } catch {
            skip(url, because: error.localizedDescription)
            return
        }
        // The saver may have been dismissed while the asset was loading.
        guard running else { return }

        hideNotice()
        clearStill()
        currentPixelSize = size
        // Stated duration, for the watchdog. `.indefinite` (a stream) and a
        // missing value both leave it nil, which turns off the reached-the-end
        // half of the watchdog and leaves the frozen-playhead half doing the
        // work — the right way round, since a duration you can't trust
        // shouldn't be used to cut a film off.
        let stated = try? await asset.load(.duration)
        currentDurationSeconds = (stated?.isNumeric ?? false) ? CMTimeGetSeconds(stated!) : nil
        let item = AVPlayerItem(asset: asset)
        attach(item)
        player.replaceCurrentItem(with: item)
        layoutPlayerLayer()
        player.play()
        startWatchdog()
        scLog("playing \(url.lastPathComponent)"
              + (size.map { " (\(Int($0.width))×\(Int($0.height)))" } ?? " (size not yet known — stream)"))

        // Metadata is read after playback starts rather than before it: the
        // picture is the point, and a caption arriving a moment into the film
        // is better than holding the film back to look up its title.
        currentCaption = await Self.caption(for: asset, url: url)
        showCaption()
        startTitleTimer()
    }

    private func skip(_ url: URL, because reason: String) {
        scLog("skipping \(url.lastPathComponent) — \(reason)")
        failuresSinceLastSuccess += 1
        playNext()
    }

    /// Pixel dimensions with rotation metadata applied. `naturalSize` alone
    /// reports a portrait phone clip as landscape — the orientation lives in
    /// the track's preferred transform.
    private static func pixelSize(of asset: AVURLAsset) async throws -> CGSize? {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let oriented = natural.applying(transform)
        return CGSize(width: abs(oriented.width), height: abs(oriented.height))
    }

    // MARK: - Stills

    /// How far a photo is zoomed by the end of its pan, unless the user says
    /// otherwise.
    ///
    /// This also sets the pan budget. At 1.08 there is 4% of overscan on each
    /// side, and `panBudgetFraction` spends part of that — so the pan can never
    /// drag an edge of the photo into frame. Every Ken Burns bug is a pan that
    /// outran its zoom, so the two are derived from one number rather than
    /// chosen independently.
    static let defaultKenBurnsZoom: CGFloat = 1.08
    /// What a stored zoom is allowed to be.
    ///
    /// Below 1 there is no overscan to pan into and the photo would come away
    /// from the edges of the display; the top of the range is where the decode
    /// starts costing more than twice the pixels the display can show, and where
    /// a photo that only just covered the screen begins to look soft.
    static let kenBurnsZoomRange: ClosedRange<CGFloat> = 1...1.5

    /// How much faster a lifted subject grows than the scene behind it, as a
    /// multiple of the scene's own zoom.
    ///
    /// It can be this large because the subject grows about the point where it
    /// meets the world rather than sliding across it: growing keeps the subject
    /// over the hole it was cut from, so the invented scenery behind it never
    /// comes into view. The first version of this slid the subject instead, and
    /// had to be kept so small to hide the seam that the effect was barely there.
    static let defaultParallaxStrength: CGFloat = 2.5
    /// What a stored strength is allowed to be. Zero is the effect off; past the
    /// top the subject stops looking like it is coming closer and starts looking
    /// like a cut-out being scaled up on top of a photograph.
    static let parallaxStrengthRange: ClosedRange<CGFloat> = 0...6
    /// How much of the available overscan a pan may spend. Short of all of it so
    /// rounding can't put an edge exactly on the boundary.
    private static let panBudgetFraction: CGFloat = 0.75
    /// Bounds for a stored photo duration, in seconds. Same instinct as the
    /// clamp on `titleRepeatMinutes`: a value that arrived from disk shouldn't
    /// be able to freeze the playlist on one image or flicker through it.
    private static let photoSecondsRange: ClosedRange<Double> = 2...600

    /// Whether photos are being panned right now.
    ///
    /// Not simply the setting: Reduce Motion turns the movement off, and the
    /// answer decides how a photo is *laid out* as well as whether it animates.
    /// A panning photo fills the display, because a pan needs overscan to move
    /// into — so with the effect on, photos ignore the Size setting above, which
    /// is about fitting a film to the screen. With it off they obey it.
    private var panningPhotos: Bool {
        kenBurnsEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The zoom actually used, clamped once here so every reader of it — the
    /// decode size and the animation both — is working from a value that can't
    /// pull the photo away from the edges of the display.
    private var photoZoom: CGFloat {
        min(max(kenBurnsZoom, Self.kenBurnsZoomRange.lowerBound),
            Self.kenBurnsZoomRange.upperBound)
    }

    /// Clamped for the same reason as `photoZoom`: a value that arrived from disk
    /// shouldn't be able to fling the subject off the scene it belongs to.
    private var photoParallaxStrength: CGFloat {
        min(max(parallaxStrength, Self.parallaxStrengthRange.lowerBound),
            Self.parallaxStrengthRange.upperBound)
    }

    /// Whether a photo's subject is being lifted right now. Tied to the pan: with
    /// no movement there is no difference in movement to see, and the split would
    /// cost a Vision request for nothing.
    private var liftingSubjects: Bool {
        parallaxEnabled && panningPhotos
    }

    /// Put one photo on screen, or skip to the next candidate.
    @MainActor
    private func presentStill(_ url: URL) async {
        let scale = window?.backingScaleFactor ?? window?.screen?.backingScaleFactor ?? 1
        // Decode no larger than this display can use, zoom included. A 60
        // megapixel photo at full size costs hundreds of megabytes per display
        // and buys nothing — the screen cannot show it.
        let target = CGSize(width: bounds.width * scale * photoZoom,
                            height: bounds.height * scale * photoZoom)
        let splitting = liftingSubjects
        let decoded = await Task.detached(priority: .userInitiated) {
            Self.decode(url, covering: target, splittingSubject: splitting)
        }.value
        // The saver may have been dismissed while the photo was being read.
        guard running else { return }
        guard let decoded = decoded else {
            skip(url, because: "could not be decoded")
            return
        }

        hideNotice()
        // A still and a film are never up at once, and the player is emptied
        // rather than paused so a photo interlude doesn't hold a decoder open.
        detachItem()
        player.replaceCurrentItem(with: nil)
        playerLayer.isHidden = true
        currentStill = (url, decoded.image)
        currentFocus = decoded.focus
        currentAnchor = decoded.layers?.anchor
        currentPixelSize = CGSize(width: decoded.image.width, height: decoded.image.height)
        stillLayer.isHidden = false
        // No implicit animation on the swap. CALayer cross-fades a `contents`
        // change by default, and a fade fighting the Ken Burns transform of the
        // photo underneath reads as a glitch rather than a transition.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The photo underneath is the photo, untouched, whether or not a subject
        // was lifted off it: the lifted copy on top always covers the part of it
        // that it came from. See `PhotoLayers`.
        stillLayer.contents = decoded.image
        subjectLayer.contents = decoded.layers?.subject
        subjectLayer.isHidden = decoded.layers == nil
        layoutStillLayer()
        CATransaction.commit()
        startKenBurns()
        // It decoded, so the source is alive — the same thing `readyToPlay`
        // proves for a video.
        failuresSinceLastSuccess = 0
        scLog("showing \(url.lastPathComponent) (\(decoded.image.width)×\(decoded.image.height)) for \(photoSeconds)s"
              + (panningPhotos ? ", panning" : "")
              + (decoded.focus.map {
                  String(format: ", focus %.2f,%.2f", $0.point.x, $0.point.y)
              } ?? ", no focus found")
              + (decoded.layers.map {
                  String(format: ", subject lifted (%.0f%% of frame)", $0.subjectShare * 100)
              } ?? (liftingSubjects ? ", no subject to lift" : "")))
        currentCaption = (decoded.title, decoded.copyright)
        showCaption()
        startTitleTimer()
        startStillTimer()
    }

    /// A photo has no end of its own to play to, so it gets a clock. One-shot,
    /// re-armed by the next photo.
    private func startStillTimer() {
        stopStillTimer()
        let seconds = min(max(Double(photoSeconds), Self.photoSecondsRange.lowerBound),
                          Self.photoSecondsRange.upperBound)
        stillTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.playNext()
        }
    }

    private func stopStillTimer() {
        stillTimer?.invalidate()
        stillTimer = nil
    }

    /// Hand the display back to the player.
    private func clearStill() {
        stillLayer.removeAnimation(forKey: Self.kenBurnsKey)
        stillLayer.transform = CATransform3DIdentity
        stillLayer.contents = nil
        stillLayer.isHidden = true
        subjectLayer.removeAnimation(forKey: Self.kenBurnsKey)
        subjectLayer.transform = CATransform3DIdentity
        subjectLayer.contents = nil
        subjectLayer.isHidden = true
        currentStill = nil
        currentFocus = nil
        currentAnchor = nil
        playerLayer.isHidden = false
    }

    private static let kenBurnsKey = "kenBurns"

    /// The slow pan and zoom, for as long as the photo is up.
    ///
    /// Held at its end state (`fillMode`, `isRemovedOnCompletion`) rather than
    /// snapping back: the photo is still on screen when the animation ends if
    /// the duration and the timer ever disagree by a frame.
    private func startKenBurns() {
        for layer in [stillLayer, subjectLayer] {
            layer.removeAnimation(forKey: Self.kenBurnsKey)
            layer.transform = CATransform3DIdentity
        }
        guard panningPhotos else { return }

        let zoom = photoZoom
        // Where the zoomed end of the move sits: aimed at what Vision found, or
        // in a random direction when it found nothing — which also keeps the
        // same photo coming round again from moving identically every time.
        let offset = PhotoFraming.panTranslation(
            layerFrame: stillLayer.frame, in: bounds, zoom: zoom,
            budgetFraction: Self.panBudgetFraction, focus: currentFocus,
            fallbackAngle: .random(in: 0..<(2 * .pi)))
        // Half of them zoom out rather than in, so a run of photos doesn't feel
        // like one repeated camera move.
        let inward = Bool.random()
        animate(stillLayer, to: zoom, offset: offset, inward: inward)

        // The subject, when there is one, grows faster than the scene — nearer
        // things do, in a real camera move, and that difference is the whole of
        // the effect. It grows about the point where it meets the world, and the
        // translation below is the one that keeps that point exactly where the
        // scene puts it: not only at the two ends of the move but at every frame
        // between them, since Core Animation interpolates both transforms
        // element by element and the two expressions stay equal under that.
        //
        // So the feet stay planted, and the subject always covers the hole it
        // came out of. Both of those are why this can be worth seeing where the
        // sliding version wasn't.
        guard !subjectLayer.isHidden, let anchor = currentAnchor else { return }
        let frame = stillLayer.frame
        let middle = CGPoint(x: frame.width / 2, y: frame.height / 2)
        let contact = CGPoint(x: anchor.x * frame.width, y: anchor.y * frame.height)
        animate(subjectLayer, to: zoom + (zoom - 1) * photoParallaxStrength,
                offset: CGPoint(x: (middle.x - contact.x) * (1 - zoom) + offset.x,
                                y: (middle.y - contact.y) * (1 - zoom) + offset.y),
                inward: inward)
    }

    /// The move itself, applied to one layer.
    ///
    /// Held at its end state (`fillMode`, `isRemovedOnCompletion`) rather than
    /// snapping back: the photo is still on screen when the animation ends if
    /// the duration and the timer ever disagree by a frame.
    private func animate(_ layer: CALayer, to zoom: CGFloat, offset: CGPoint, inward: Bool) {
        let zoomed = CATransform3DConcat(
            CATransform3DMakeScale(zoom, zoom, 1),
            CATransform3DMakeTranslation(offset.x, offset.y, 0))
        let move = CABasicAnimation(keyPath: "transform")
        // The pan starts from the unzoomed state, where there is no overscan and
        // therefore no offset — the offset only exists in the zoomed state, so
        // the photo covers the display throughout either direction of travel.
        move.fromValue = inward ? CATransform3DIdentity : zoomed
        move.toValue = inward ? zoomed : CATransform3DIdentity
        move.duration = min(max(Double(photoSeconds), Self.photoSecondsRange.lowerBound),
                            Self.photoSecondsRange.upperBound)
        // Linear: a steady drift. Easing makes the move look like it stalls at
        // each end, which on a screensaver reads as a stutter.
        move.timingFunction = CAMediaTimingFunction(name: .linear)
        move.fillMode = .forwards
        move.isRemovedOnCompletion = false
        layer.add(move, forKey: Self.kenBurnsKey)
    }

    /// One photo, decoded and captioned. `@unchecked Sendable` because it
    /// crosses back from the decode task: `CGImage` is immutable once created
    /// and safe to hand between threads, but isn't marked as such.
    private struct DecodedStill: @unchecked Sendable {
        let image: CGImage
        let title: String
        let copyright: String?
        /// Where the eye goes, or nil if Vision had no answer.
        let focus: PhotoFocus?
        /// The subject and the scene behind it, when the photo has a subject
        /// worth lifting and the effect is on.
        let layers: PhotoLayers?
    }

    /// Read one photo at no more resolution than `covering` needs, with its EXIF
    /// orientation already applied.
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` rather than `CreateImageAtIndex`:
    /// it is the one of the two that applies the orientation tag
    /// (`WithTransform`), and it takes a size cap. A phone photo decoded without
    /// that transform is displayed on its side — the still-image version of the
    /// `preferredTransform` problem `pixelSize(of:)` solves for video.
    nonisolated private static func decode(_ url: URL, covering target: CGSize,
                                           splittingSubject: Bool) -> DecodedStill? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: cap(for: properties, covering: target),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let filename = url.deletingPathExtension().lastPathComponent
        // Measured here, on the decode's own thread, because Vision takes tens
        // of milliseconds and this is the one place in a photo's life that is
        // already off the main thread. A photo shown on two displays is measured
        // twice, for the same reason it is decoded twice: each display's stage
        // is independent, and a shared cache would be the only thing in the
        // stage that wasn't.
        return DecodedStill(image: image,
                            title: embeddedTitle(properties) ?? filename,
                            copyright: embeddedCopyright(properties),
                            focus: PhotoFocus.detect(in: image),
                            layers: splittingSubject ? PhotoParallax.layers(for: image) : nil)
    }

    /// The largest edge worth decoding.
    ///
    /// Derived from what covering the frame actually needs rather than from the
    /// longest edge alone: a 12000×900 panorama filling a 16:9 display needs far
    /// more of its width than of its height, and capping the long edge would
    /// starve it. Never asks for more than the file holds.
    nonisolated private static func cap(for properties: [CFString: Any], covering target: CGSize) -> CGFloat {
        let width = (properties[kCGImagePropertyPixelWidth] as? CGFloat) ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? CGFloat) ?? 0
        let fallback = max(target.width, target.height, 1)
        guard width > 0, height > 0, target.width > 0, target.height > 0 else { return fallback }
        // Orientations 5–8 are the rotated ones, where the stored pixel
        // dimensions are the other way round from what will be displayed.
        let rotated = ((properties[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
        let shown = CGSize(width: rotated ? height : width, height: rotated ? width : height)
        let needed = max(target.width / shown.width, target.height / shown.height)
        return max(width, height) * min(1, needed)
    }

    /// A photo's own title, from the fields that actually carry one.
    ///
    /// IPTC first — `ObjectName` is the field photo software writes a title into
    /// — then TIFF's `ImageDescription`, which is where a caption more often
    /// ends up. Neither is common in a phone photo, which is why the filename
    /// fallback matters more here than it does for video.
    nonisolated private static func embeddedTitle(_ properties: [CFString: Any]) -> String? {
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let candidates = [iptc?[kCGImagePropertyIPTCObjectName] as? String,
                          tiff?[kCGImagePropertyTIFFImageDescription] as? String]
        return candidates.compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    nonisolated private static func embeddedCopyright(_ properties: [CFString: Any]) -> String? {
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let candidates = [iptc?[kCGImagePropertyIPTCCopyrightNotice] as? String,
                          tiff?[kCGImagePropertyTIFFCopyright] as? String]
        return candidates.compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: - Stall watchdog

    /// What the watchdog thinks of the current state of play.
    enum StallVerdict: Equatable {
        case keepPlaying
        /// The playhead is sitting at the end but no end-of-play notification
        /// ever arrived. Advance now.
        case finishedSilently
        /// The playhead hasn't moved for a long time although the player
        /// believes it is playing. Advance and log it.
        case frozen
    }

    /// How often the watchdog looks.
    private static let watchdogTickSeconds: TimeInterval = 2
    /// How close to the stated end counts as "at the end".
    private static let endEpsilonSeconds: Double = 0.5
    /// How long the playhead must sit at the end before the watchdog decides
    /// no notification is coming.
    ///
    /// Load-bearing. Every video's playhead passes through the last half-second
    /// legitimately, and `didPlayToEndTime` arrives within milliseconds of it —
    /// so without this grace the watchdog would race the notification and
    /// advance early on a good fraction of perfectly healthy videos, clipping
    /// their final moments. A safety net that participates in normal operation
    /// isn't a safety net. Two ticks is far longer than the notification ever
    /// takes, and on a healthy item the watchdog is disarmed by `detachItem()`
    /// long before it could count that high.
    private static let endGraceSeconds: TimeInterval = 4
    /// How long a motionless playhead is tolerated before the video is written
    /// off. Deliberately generous: a file on a sleeping external drive or a
    /// network volume can legitimately stall for several seconds, and cutting
    /// a good film short would be a worse bug than the one being guarded
    /// against. Half a minute of a frozen picture is broken by any standard.
    private static let stallLimitSeconds: TimeInterval = 30

    /// The whole policy, as a pure function — no player, no timer, no clock.
    /// Separated out so each branch can be tested directly rather than by
    /// trying to manufacture a wedged decoder.
    ///
    /// - Parameters:
    ///   - playheadSeconds: where the playhead is now.
    ///   - durationSeconds: the item's stated duration, or nil when it can't
    ///     be trusted.
    ///   - frozenSeconds: how long the playhead has read the same value.
    ///   - shouldBePlaying: whether the player intends to be moving. False
    ///     while we've deliberately paused, which must never count as a stall.
    static func stallVerdict(playheadSeconds: Double,
                             durationSeconds: Double?,
                             frozenSeconds: TimeInterval,
                             shouldBePlaying: Bool) -> StallVerdict {
        guard shouldBePlaying else { return .keepPlaying }
        if let duration = durationSeconds, duration > 0,
           playheadSeconds >= duration - endEpsilonSeconds,
           frozenSeconds >= endGraceSeconds {
            return .finishedSilently
        }
        if frozenSeconds >= stallLimitSeconds { return .frozen }
        return .keepPlaying
    }

    private func startWatchdog() {
        stopWatchdog()
        lastPlayhead = nil
        frozenSeconds = 0
        watchdog = Timer.scheduledTimer(withTimeInterval: Self.watchdogTickSeconds,
                                        repeats: true) { [weak self] _ in
            self?.watchdogTick()
        }
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    /// The plumbing: measure, ask `stallVerdict`, act.
    private func watchdogTick() {
        guard running, player.currentItem != nil else { return }
        let playhead = CMTimeGetSeconds(player.currentTime())
        // A paused player is us, not a fault — see `pause()`, which stops the
        // watchdog outright. This is the belt to that braces.
        let shouldBePlaying = player.timeControlStatus != .paused

        if let last = lastPlayhead, last == playhead, shouldBePlaying {
            frozenSeconds += Self.watchdogTickSeconds
        } else {
            frozenSeconds = 0
        }
        lastPlayhead = playhead

        switch Self.stallVerdict(playheadSeconds: playhead,
                                 durationSeconds: currentDurationSeconds,
                                 frozenSeconds: frozenSeconds,
                                 shouldBePlaying: shouldBePlaying) {
        case .keepPlaying:
            return
        case .finishedSilently:
            scLog("watchdog: playhead reached the end with no end-of-play notification — advancing")
            playNext()
        case .frozen:
            scLog("watchdog: playhead frozen at \(String(format: "%.1f", playhead))s for \(Int(frozenSeconds))s — advancing")
            // A file that wedges the decoder has failed, whatever its header
            // claimed, so it counts against the all-dead-source guard.
            failuresSinceLastSuccess += 1
            playNext()
        }
    }

    // MARK: - Title caption

    /// The title to show, and the copyright line if the file carries one.
    ///
    /// A file's embedded title is used when it has one; otherwise the filename
    /// without its extension, which for most people's own videos is the only
    /// title there is. Never the full path — nobody wants their folder
    /// structure projected on a wall.
    private static func caption(for asset: AVURLAsset, url: URL) async -> (title: String, copyright: String?) {
        let filename = url.deletingPathExtension().lastPathComponent
        guard let metadata = try? await asset.load(.commonMetadata) else {
            return (filename, nil)
        }
        let title = await string(metadata, .commonIdentifierTitle)
        let copyright = await string(metadata, .commonIdentifierCopyrights)
        return (title?.isEmpty == false ? title! : filename, copyright)
    }

    private static func string(_ items: [AVMetadataItem], _ identifier: AVMetadataIdentifier) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: items,
                                                      filteredByIdentifier: identifier).first,
              let value = try? await item.load(.stringValue)
        else { return nil }
        return value
    }

    private func showCaption() {
        guard titleMode != .never, let caption = currentCaption else { return }
        scLog("caption: \(caption.title)" + (caption.copyright.map { " · \($0)" } ?? ""))
        overlay.show(title: caption.title, copyright: caption.copyright)
    }

    /// Re-show the caption every few minutes in `.repeatedly` mode. Restarted
    /// for each item, so the gap is measured from the moment that item began
    /// rather than from some earlier one.
    private func startTitleTimer() {
        stopTitleTimer()
        guard titleMode == .repeatedly else { return }
        let minutes = max(1, min(60, titleRepeatMinutes))
        titleTimer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60, repeats: true) { [weak self] _ in
            self?.showCaption()
        }
    }

    private func stopTitleTimer() {
        titleTimer?.invalidate()
        titleTimer = nil
    }

    private enum StageError: LocalizedError {
        case notPlayable
        case noVideoTrack

        var errorDescription: String? {
            switch self {
            case .notPlayable:  return "not playable"
            case .noVideoTrack: return "no video track"
            }
        }
    }

    // MARK: - Item observers

    private func attach(_ item: AVPlayerItem) {
        // A stream reports no track dimensions up front. `presentationSize`
        // becomes non-zero once the first frames are decoded, which is the only
        // way "original size" can mean anything for a stream.
        presentationObservation = item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
            let size = item.presentationSize
            guard size.width > 0, size.height > 0 else { return }
            DispatchQueue.main.async {
                guard let self = self, self.currentPixelSize != size else { return }
                let first = self.currentPixelSize == nil
                self.currentPixelSize = size
                self.layoutPlayerLayer()
                // Logged on the first report and on any change: an adaptive
                // stream opens on a low variant and steps up, and "original
                // size" has to follow it rather than pin the opening frame.
                scLog(first ? "stream reported its size: \(Int(size.width))×\(Int(size.height))"
                            : "stream changed variant: \(Int(size.width))×\(Int(size.height))")
            }
        }

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            // KVO can arrive off the main thread; everything here touches
            // AppKit and the playlist.
            DispatchQueue.main.async { self?.handle(item) }
        }
        let nc = NotificationCenter.default
        itemObservers.append(nc.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            self?.playNext()
        })
        itemObservers.append(nc.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            scLog("playback failed mid-file — \(error?.localizedDescription ?? "unknown")")
            self?.failuresSinceLastSuccess += 1
            self?.playNext()
        })
    }

    private func handle(_ item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            // Proof the file genuinely decoded, so the run of failures that
            // guards against an all-dead source starts again from here.
            failuresSinceLastSuccess = 0
        case .failed:
            scLog("item failed to load — \(item.error?.localizedDescription ?? "unknown")")
            failuresSinceLastSuccess += 1
            playNext()
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func detachItem() {
        // Armed again by `present()` for the next item.
        stopWatchdog()
        statusObservation?.invalidate()
        statusObservation = nil
        presentationObservation?.invalidate()
        presentationObservation = nil
        for obs in itemObservers { NotificationCenter.default.removeObserver(obs) }
        itemObservers.removeAll()
    }

    // MARK: - Geometry

    override func layout() {
        super.layout()
        layoutPlayerLayer()
        layoutStillLayer()
        layoutNotice()
        overlay.frame = bounds
    }

    private func layoutPlayerLayer() {
        switch scaling {
        case .fullScreen:
            playerLayer.videoGravity = .resizeAspectFill
            playerLayer.frame = bounds
        case .fitToScreen:
            playerLayer.videoGravity = .resizeAspect
            playerLayer.frame = bounds
        case .originalSize:
            playerLayer.videoGravity = .resizeAspect
            playerLayer.frame = originalSizeFrame()
        }
    }

    /// Where the photo sits. A panning photo fills the display whatever the
    /// Size setting says — see `panningPhotos` — because a pan has to have
    /// overscan to move into. Otherwise a photo is fitted exactly like a film.
    private func layoutStillLayer() {
        guard let still = currentStill else { return }
        guard !panningPhotos else {
            fillWithPhoto(still.image)
            return
        }
        switch scaling {
        case .fullScreen:
            fillWithPhoto(still.image)
        case .fitToScreen:
            stillLayer.contentsGravity = .resizeAspect
            stillLayer.frame = bounds
            matchSubjectToPhoto()
        case .originalSize:
            stillLayer.contentsGravity = .resizeAspect
            stillLayer.frame = originalSizeFrame()
            matchSubjectToPhoto()
        }
    }

    /// Fill the display with the photo, aimed at its focus point.
    ///
    /// The layer is given the whole photo at covering scale rather than being
    /// pinned to `bounds` with aspect-fill doing the cropping: the crop is then
    /// this code's decision rather than a side effect of where the middle of the
    /// photo happens to be, which is what lets it be aimed. The overhang is
    /// clipped by the view — see `masksToBounds` in `init`.
    ///
    /// `resizeAspectFill` rather than `resizeAspect` inside that frame even
    /// though the frame is built from the photo's own aspect ratio: the two are
    /// identical to within rounding, and this is the one of them that answers a
    /// half-pixel disagreement by overfilling instead of by showing a hairline
    /// of black.
    private func fillWithPhoto(_ image: CGImage) {
        stillLayer.contentsGravity = .resizeAspectFill
        stillLayer.frame = PhotoFraming.fillFrame(
            imageSize: CGSize(width: image.width, height: image.height),
            in: bounds, focus: currentFocus)
        matchSubjectToPhoto()
    }

    /// The subject sits in exactly the frame the photo does — it was cut out of
    /// it at the same size, so anything else would put it somewhere it wasn't.
    /// Its transform is what differs, not its geometry.
    ///
    /// Except for the anchor point, which is moved to where the subject meets the
    /// world so that its transform grows it about that point. Set before the
    /// frame: changing an anchor point on its own moves the layer, and setting the
    /// frame afterwards is what puts it back.
    private func matchSubjectToPhoto() {
        subjectLayer.contentsGravity = stillLayer.contentsGravity
        subjectLayer.anchorPoint = currentAnchor ?? CGPoint(x: 0.5, y: 0.5)
        subjectLayer.frame = stillLayer.frame
    }

    /// One video pixel per screen pixel, centred on black.
    ///
    /// The point/pixel conversion matters: a 1080p film on a Retina display
    /// laid out at 1920×1080 *points* would be drawn at double size and look
    /// soft. Dividing by the backing scale is what makes "original size"
    /// mean unscaled. Where no scale is available the fallback is 1 — the
    /// identity, not a guess about the hardware.
    ///
    /// A video larger than the display is scaled down to fit. At a literal
    /// 1:1 it would spill past every edge and show whatever happened to be
    /// in the middle, which isn't original size, it's an arbitrary crop.
    private func originalSizeFrame() -> CGRect {
        guard let pixels = currentPixelSize, pixels.width > 0, pixels.height > 0 else { return bounds }
        let scale = window?.backingScaleFactor ?? window?.screen?.backingScaleFactor ?? 1
        let points = CGSize(width: pixels.width / scale, height: pixels.height / scale)
        let shrink = min(1, min(bounds.width / points.width, bounds.height / points.height))
        let size = CGSize(width: points.width * shrink, height: points.height * shrink)
        return CGRect(x: bounds.midX - size.width / 2,
                      y: bounds.midY - size.height / 2,
                      width: size.width,
                      height: size.height)
    }

    // MARK: - Empty state

    /// Horizontal breathing room for the notice, as a fraction of the
    /// display width per side, so the text wraps well on a laptop and a
    /// 5K panel alike.
    private static let noticeInsetRatio: CGFloat = 8

    /// Three different situations, because "nothing is playing" has three
    /// different fixes and a single message would send the user to the wrong
    /// one. The switched-off case especially: a saver that says "no videos
    /// found" when the videos are right there, merely unticked, is actively
    /// misleading.
    private func emptySourceMessage() -> String {
        let all = VideoLibrary.sources
        guard !all.isEmpty else {
            return L10n.string(
                "stage.no_source",
                defaultValue: "No video sources yet.\nAdd a folder, a file or a stream in Save Cannes ▸ Settings…")
        }
        guard all.contains(where: \.isEnabled) else {
            return L10n.format(
                "stage.all_sources_off",
                defaultValue: "All %d sources are switched off.\nTurn one on in Save Cannes ▸ Settings…",
                all.count)
        }
        return L10n.string(
            "stage.no_videos",
            defaultValue: "No videos found in the sources that are switched on.")
    }

    /// Centred white text on the black window — the same instinct as Rainy
    /// Day's empty-backgrounds notice. A saver that comes up black and
    /// silent looks broken; one that says why doesn't.
    private func showNotice(_ text: String) {
        scLog("notice: \(text.replacingOccurrences(of: "\n", with: " "))")
        if notice == nil {
            let field = NSTextField(wrappingLabelWithString: text)
            field.alignment = .center
            field.font = NSFont.preferredFont(forTextStyle: .title1)
            field.textColor = .white
            field.drawsBackground = false
            field.isSelectable = false
            addSubview(field)
            keepVideoBehind()
            notice = field
        }
        notice?.stringValue = text
        notice?.isHidden = false
        needsLayout = true
    }

    private func hideNotice() {
        notice?.isHidden = true
    }

    /// A wrapping label lays its text out from the top of its frame, so the
    /// frame has to be sized to the text and then centred — inset alone
    /// would pin the message to the top of the display.
    private func layoutNotice() {
        guard let notice = notice else { return }
        let width = bounds.width - 2 * (bounds.width / Self.noticeInsetRatio)
        let height = notice.sizeThatFits(
            NSSize(width: width, height: .greatestFiniteMagnitude)).height
        notice.frame = CGRect(x: bounds.midX - width / 2,
                              y: bounds.midY - height / 2,
                              width: width,
                              height: height)
    }
}
