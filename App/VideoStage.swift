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

    private let player = AVPlayer()
    private let playerLayer = AVPlayerLayer()
    private var notice: NSTextField?
    private let overlay = TitleOverlay(frame: .zero)
    /// What the caption should say for the item playing now, kept so the
    /// periodic repeat has something to re-show.
    private var currentCaption: (title: String, copyright: String?)?
    private var titleTimer: Timer?

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
    /// Pixel dimensions of the current item, rotation applied. Only
    /// `.originalSize` needs it; nil until an item is loaded.
    private var currentPixelSize: CGSize?
    private var running = false

    // MARK: - Construction

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.player = player
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
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
        guard let layer = layer, playerLayer.superlayer === layer else { return }
        layer.insertSublayer(playerLayer, at: 0)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        detachItem()
        titleTimer?.invalidate()
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
        stopTitleTimer()
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
        currentCaption = nil
        player.replaceCurrentItem(with: nil)
        queue.removeAll()
        currentPixelSize = nil
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
            showNotice(L10n.format(
                "stage.none_playable",
                defaultValue: "None of the %d files in %@ could be played.",
                candidatesInSource,
                VideoLibrary.sourceURL?.lastPathComponent ?? "the chosen folder"))
            return
        }
        let url = queue.removeFirst()
        Task { await present(url) }
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
        let size: CGSize
        do {
            guard try await asset.load(.isPlayable) else {
                throw StageError.notPlayable
            }
            guard let pixels = try await Self.pixelSize(of: asset) else {
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
        currentPixelSize = size
        let item = AVPlayerItem(asset: asset)
        attach(item)
        player.replaceCurrentItem(with: item)
        layoutPlayerLayer()
        player.play()
        scLog("playing \(url.lastPathComponent) (\(Int(size.width))×\(Int(size.height)))")

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
        statusObservation?.invalidate()
        statusObservation = nil
        for obs in itemObservers { NotificationCenter.default.removeObserver(obs) }
        itemObservers.removeAll()
    }

    // MARK: - Geometry

    override func layout() {
        super.layout()
        layoutPlayerLayer()
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

    private func emptySourceMessage() -> String {
        guard let source = VideoLibrary.sourceURL else {
            return L10n.string(
                "stage.no_source",
                defaultValue: "No video source chosen.\nPick a video file or a folder in Save Cannes ▸ Settings…")
        }
        return L10n.format(
            "stage.no_videos",
            defaultValue: "No videos found in %@.",
            source.lastPathComponent)
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
