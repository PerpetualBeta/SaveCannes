import Foundation
import UniformTypeIdentifiers

/// The order a folder of videos is played in.
enum PlaybackOrder: Int {
    case random = 0
    case sequential = 1

    /// Whether "different video on each display" is available in this order.
    ///
    /// It isn't, in sequential order. Playing a folder in order means the same
    /// order everywhere — starting each display at a different file would make
    /// the ordering meaningless, which is why the setting is forced off and
    /// disabled there rather than quietly ignored. Both the engine
    /// (`AppDelegate.showWindows`) and the Settings toggle read this, so they
    /// can't disagree about it.
    var allowsDifferentVideoPerDisplay: Bool { self == .random }
}

/// When the title caption appears.
enum TitleMode: Int {
    case never = 0
    /// Once, as each video begins.
    case atStart = 1
    /// As each video begins, and again every few minutes while it plays — for
    /// a screen an audience wanders past rather than sits in front of.
    case repeatedly = 2
}

/// How each video is fitted to the display it plays on.
enum VideoScaling: Int {
    /// Fill the display; overflow on the long axis is cropped away.
    case fullScreen = 0
    /// Whole frame visible, letterboxed or pillarboxed to fit.
    case fitToScreen = 1
    /// One video pixel per screen pixel, centred.
    case originalSize = 2
}

/// The user's chosen sources — folders, files, streams — and the playlist they
/// resolve to.
///
/// Locations are stored as plain paths and URL strings rather than
/// security-scoped bookmarks: Save Cannes isn't sandboxed, so a path is all it
/// needs, and a path survives the user reorganising their library in ways a
/// bookmark would silently follow (a bookmark tracks the file, which is the
/// wrong behaviour when the setting means "whatever is in this folder now").
enum VideoLibrary {

    /// Every source the user has registered, in their order, enabled or not.
    static var sources: [VideoSource] { SourceStore.load() }

    /// Just the ones switched on for playback.
    static var enabledSources: [VideoSource] { sources.filter(\.isEnabled) }

    /// Everything the enabled sources offer, in the order they will be played
    /// in sequential mode.
    ///
    /// Sorted **within** each source, with the sources kept in the user's own
    /// order — so "sequential" means the first source's videos in path order,
    /// then the second's. Sorting the combined list instead would interleave
    /// two libraries by filename, which is nobody's intent when they added them
    /// separately.
    ///
    /// Read fresh on every activation rather than cached, so adding or removing
    /// files takes effect the next time the saver comes up.
    static func playlist() -> [URL] {
        enabledSources.flatMap(items(in:))
    }

    /// Whether photos join the playlist, read fresh so the setting applies to
    /// the next activation.
    ///
    /// A toggle rather than always-on because a folder of films very often has
    /// stray images in it — cover art, a poster, a downloaded thumbnail — and
    /// turning those into slides is not what someone who pointed the saver at
    /// their films folder asked for. Default on, so a folder of holiday photos
    /// works with no setup.
    static var photosEnabled: Bool {
        UserDefaults.standard.bool(forKey: "photosEnabled")
    }

    /// What one source resolves to, whether or not it's enabled — the settings
    /// list needs a count for sources that are switched off too.
    ///
    /// "Items" rather than "videos" since 2026-08-13: a source can offer stills
    /// as well, and the stage plays whichever kind each one turns out to be.
    static func items(in source: VideoSource) -> [URL] {
        guard let url = source.url else { return [] }
        switch source.kind {
        case .stream:
            // Handed to AVFoundation as-is. There is nothing to inspect: a
            // remote URL has no file type to read, and whether it plays is a
            // question only the player can answer — which it does, by failing
            // the same way a corrupt file does and being skipped.
            return [url]
        case .file:
            // A single file the user picked by hand is honoured whichever kind
            // it is — they chose that exact file, so the photos toggle (which
            // exists to keep incidental images out of a folder of films) has no
            // business overruling them.
            return isVideo(url) || isImage(url) ? [url] : []
        case .folder:
            guard let walker = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.contentTypeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return [] }
            let playable = photosEnabled ? { isVideo($0) || isImage($0) } : isVideo
            return walker.compactMap { $0 as? URL }
                .filter(playable)
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
    }

    /// What a source offers, split by kind, for the settings list.
    ///
    /// One walk of the directory rather than one per kind: a source can be
    /// thousands of entries on a spinning disk, and this runs on every
    /// appearance of the Settings window.
    struct Tally {
        var videos = 0
        var photos = 0
        var total: Int { videos + photos }
    }

    static func tally(in source: VideoSource) -> Tally {
        var tally = Tally()
        for url in items(in: source) {
            if isVideo(url) { tally.videos += 1 } else { tally.photos += 1 }
        }
        return tally
    }

    /// The playlist in the order it should be played: shuffled for random, path order
    /// for sequential.
    ///
    /// Not a plain shuffle of the files. A directory of stills is a *collection*, and
    /// the desk it is shown on only reads as one if the whole directory goes past
    /// before the next film — so the images from one directory are held together as a
    /// run, and it is the runs that get shuffled rather than the individual files.
    ///
    /// Inside a run the images are shuffled too, which is what gives full coverage
    /// without repeats: a shuffle is a selection without replacement, so every image
    /// in the directory is shown exactly once before any of them comes round again.
    /// There is no pool to remove from because the shuffle *is* the removal.
    ///
    /// Separate from `playlist()` because the two callers need it at different
    /// moments. A stage playing its own list orders it per pass; when every display
    /// mirrors one list, `AppDelegate` orders it once and hands the same array to all
    /// of them.
    ///
    /// - Parameter startingAtRun: which run this display begins at, for "different
    ///   video on each display". Counted in runs rather than in files, because
    ///   starting a display halfway through a directory would break the very thing
    ///   the grouping exists to guarantee.
    static func orderedPlaylist(_ order: PlaybackOrder, startingAtRun offset: Int = 0) -> [URL] {
        var runs = runs(in: playlist())
        if order == .random {
            runs = runs.shuffled().map { $0.count > 1 ? $0.shuffled() : $0 }
        }
        guard !runs.isEmpty else { return [] }
        // Rotating rather than slicing means a display that starts at run 3 still plays
        // runs 1 and 2 afterwards — every display sees the whole library, just from a
        // different point in it.
        let from = ((offset % runs.count) + runs.count) % runs.count
        return (Array(runs[from...]) + Array(runs[..<from])).flatMap { $0 }
    }

    /// The playlist split into the runs that have to stay together: one run per film,
    /// and one run per directory of stills.
    ///
    /// Grouped by the directory each image actually sits in rather than by the source
    /// it came from, because a source pointed at a photo library is usually a tree of
    /// albums, and it is the album that is the collection.
    static func runs(in items: [URL]) -> [[URL]] {
        var runs: [[URL]] = []
        var whereFrom: [URL: Int] = [:]
        for item in items {
            guard isImage(item) else {
                runs.append([item])
                continue
            }
            let directory = item.deletingLastPathComponent()
            if let at = whereFrom[directory] {
                runs[at].append(item)
            } else {
                whereFrom[directory] = runs.count
                runs.append([item])
            }
        }
        return runs
    }

    /// True when macOS recognises the file as something with a moving
    /// picture in it.
    ///
    /// Type-based rather than an extension whitelist: anything the system
    /// knows as a movie counts, and everything else — a README, a stray
    /// subtitle file, an album of MP3s sitting in the same folder — is
    /// skipped without ever being handed to a player.
    ///
    /// Passing this test still doesn't guarantee playback. A truncated
    /// download or a codec AVFoundation can't decode looks fine here and
    /// fails later; `VideoStage` handles that by moving to the next
    /// candidate.
    static func isVideo(_ url: URL) -> Bool {
        contentType(of: url)?.conforms(to: .movie) ?? false
    }

    /// True when macOS recognises the file as a still image.
    ///
    /// Same type-based test as `isVideo`, and it inherits the same property:
    /// anything the system knows as an image counts — JPEG, PNG, HEIC, TIFF, a
    /// RAW file from a camera — without this code carrying a list of extensions
    /// that would be out of date the moment a new format appears.
    ///
    /// Deliberately excludes PDFs and SVGs, which conform to neither
    /// `UTType.image` nor `.movie`, and which nobody means by "the photos in
    /// this folder".
    static func isImage(_ url: URL) -> Bool {
        contentType(of: url)?.conforms(to: .image) ?? false
    }

    private static func contentType(of url: URL) -> UTType? {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
    }
}
