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

    private let player = AVPlayer()
    private let playerLayer = AVPlayerLayer()
    /// Where photographs are shown: a desk, with the prints piling up on it.
    ///
    /// A separate surface from the player's, rather than reusing one, because the
    /// two are handed their content in completely different ways and swapping
    /// between them is then just a matter of which one is hidden.
    private let desk = PhotoDesk()
    /// Drives the desk. Owned here because a display link needs a view, and
    /// because the desk must not be able to go on drawing once the stage has
    /// finished with it.
    private var deskLink: CADisplayLink?
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
        // Keeps every picture layer inside this display's window edge.
        layer?.masksToBounds = true
        playerLayer.player = player
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
        desk.metalLayer.isHidden = true
        layer?.addSublayer(desk.metalLayer)
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
        if desk.metalLayer.superlayer === layer { layer.insertSublayer(desk.metalLayer, at: 1) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        deskLink?.invalidate()
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
        // Loading the depth model costs about a second, once per launch. Doing it now,
        // off the main thread, means the first photograph doesn't wait for it — and if
        // this activation turns out to be all films, nothing has been lost but the read.
        if VideoLibrary.photosEnabled {
            Task.detached(priority: .utility) { _ = PhotoDepth.shared.isAvailable }
        }
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
        // The offset is applied by `orderedPlaylist`, in runs rather than in files: a
        // display that began partway through a directory of stills would break the run
        // that keeps that directory together. A mirrored list is taken exactly as
        // handed over — every display is meant to be showing the same thing, and its
        // offset is zero for that reason.
        let all = sharedPlaylist ?? VideoLibrary.orderedPlaylist(order, startingAtRun: startOffset)
        candidatesInSource = all.count
        queue = all
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

    /// Bounds for a stored photo duration, in seconds. Same instinct as the
    /// clamp on `titleRepeatMinutes`: a value that arrived from disk shouldn't
    /// be able to freeze the playlist on one image or flicker through it.
    private static let photoSecondsRange: ClosedRange<Double> = 2...600

    /// Put one photograph onto the desk, or skip to the next candidate.
    ///
    /// A run of photographs is one continuous desk: each print lands on the pile the
    /// one before it left, and the desk is only cleared when a film comes up. That is
    /// what makes a folder of images read as a collection rather than a slideshow.
    @MainActor
    private func presentStill(_ url: URL) async {
        guard desk.isUsable else {
            skip(url, because: "this display has no Metal device for the desk")
            return
        }
        let scale = window?.backingScaleFactor ?? window?.screen?.backingScaleFactor ?? 1
        let points = bounds.size
        let seed = desk.nextSeed()
        // Read, measured and built into a print all on one background pass. Vision's
        // subject mask, the depth model and the print's focus stack together cost a
        // couple of hundred milliseconds, and none of it belongs on the main thread.
        let prepared = await Task.detached(priority: .userInitiated) {
            Self.prepare(url, points: points, scale: scale, seed: seed)
        }.value
        // The saver may have been dismissed while the photograph was being read.
        guard running else { return }
        guard let prepared = prepared else {
            skip(url, because: "could not be decoded")
            return
        }

        hideNotice()
        // The desk and a film are never up at once, and the player is emptied rather
        // than paused so a photo interlude doesn't hold a decoder open.
        detachItem()
        player.replaceCurrentItem(with: nil)
        playerLayer.isHidden = true
        currentStill = (url, prepared.image)
        currentFocus = prepared.focus
        currentPixelSize = CGSize(width: prepared.image.width, height: prepared.image.height)
        if desk.isEmpty { desk.begin() }
        desk.metalLayer.isHidden = false
        desk.drop(prepared.print)
        startDeskLink()
        // It decoded, so the source is alive — the same thing `readyToPlay` proves for
        // a video.
        failuresSinceLastSuccess = 0
        scLog("desk: \(url.lastPathComponent) (\(prepared.image.width)×\(prepared.image.height)) for \(photoSeconds)s"
              + (prepared.print.hasSubject ? ", subject held sharp" : ", no subject")
              + (prepared.print.hasDepth ? "" : ", no depth"))
        currentCaption = (prepared.title, prepared.copyright)
        showCaption()
        startTitleTimer()
        startStillTimer()
    }

    /// Start, or keep, the clock that draws the desk. One display link per stage,
    /// running only while there is a desk to draw.
    private func startDeskLink() {
        guard deskLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(drawDesk))
        link.add(to: .main, forMode: .common)
        deskLink = link
    }

    private func stopDeskLink() {
        deskLink?.invalidate()
        deskLink = nil
    }

    @objc private func drawDesk() {
        let scale = window?.backingScaleFactor ?? window?.screen?.backingScaleFactor ?? 1
        desk.render(points: bounds.size, scale: scale)
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

    /// Hand the display back to the player, and give the desk back with it — a run of
    /// photographs is over the moment a film starts, and nothing it was holding should
    /// survive the hours a film plays.
    private func clearStill() {
        stopDeskLink()
        desk.end()
        desk.metalLayer.isHidden = true
        currentStill = nil
        currentFocus = nil
        playerLayer.isHidden = false
    }

    /// One photograph, read, measured and built into a print, ready to be dropped.
    ///
    /// `@unchecked Sendable` for the same reason `DecodedStill` is: it crosses back
    /// from a background pass, and neither `CGImage` nor a print's Metal textures are
    /// marked sendable although both are only ever touched from one thread at a time.
    private struct PreparedPhoto: @unchecked Sendable {
        let image: CGImage
        let title: String
        let copyright: String?
        let focus: PhotoFocus?
        let print: PhotoPrint
    }

    /// Everything a photograph needs before it can land, on one background pass.
    ///
    /// Reading it, measuring its subject and its depth, and building its focus stack
    /// are all expensive — a couple of hundred milliseconds together — and all of it
    /// can be done away from the main thread, so all of it is.
    nonisolated private static func prepare(_ url: URL, points: CGSize, scale: CGFloat,
                                            seed: UInt32) -> PreparedPhoto? {
        // Decode no larger than this display can use. A 60 megapixel photograph at full
        // size costs hundreds of megabytes per display and buys nothing — the screen
        // cannot show it, and a print shows less of the screen than that.
        let target = CGSize(width: max(1, points.width * scale),
                            height: max(1, points.height * scale))
        guard let decoded = decode(url, covering: target) else { return nil }
        let analysis = PhotoAnalysis.measure(decoded.image, attention: decoded.focus)
        let placement = DeskGPU.place(
            imageSize: CGSize(width: decoded.image.width, height: decoded.image.height),
            seed: seed, in: target)
        guard let gpu = DeskGPU.shared,
              let print = gpu.makePrint(image: decoded.image, analysis: analysis,
                                        seed: seed, placement: placement)
        else { return nil }
        return PreparedPhoto(image: decoded.image, title: decoded.title,
                             copyright: decoded.copyright, focus: decoded.focus,
                             print: print)
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
    }

    /// Read one photo at no more resolution than `covering` needs, with its EXIF
    /// orientation already applied.
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` rather than `CreateImageAtIndex`:
    /// it is the one of the two that applies the orientation tag
    /// (`WithTransform`), and it takes a size cap. A phone photo decoded without
    /// that transform is displayed on its side — the still-image version of the
    /// `preferredTransform` problem `pixelSize(of:)` solves for video.
    nonisolated private static func decode(_ url: URL, covering target: CGSize) -> DecodedStill? {
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
                            focus: PhotoFocus.detect(in: image))
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
        desk.metalLayer.frame = bounds
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
