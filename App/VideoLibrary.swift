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

/// The user's chosen video source — one file, or a folder of them — and the
/// playlist it resolves to.
///
/// The source is stored as a plain path rather than a security-scoped
/// bookmark: Save Cannes isn't sandboxed, so a path is all it needs, and a
/// path survives the user reorganising their library in ways a bookmark
/// would silently follow (a bookmark tracks the file, which is the wrong
/// behaviour when the setting means "whatever is in this folder now").
enum VideoLibrary {

    static let sourcePathKey = "sourcePath"

    /// The configured source, or nil when the user hasn't picked one yet.
    /// Nothing here checks the path still exists — callers get an empty
    /// playlist for a source that's been moved or unmounted, which is the
    /// same outcome as an empty folder and needs no separate handling.
    static var sourceURL: URL? {
        let path = UserDefaults.standard.string(forKey: sourcePathKey) ?? ""
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    static var sourceIsDirectory: Bool {
        guard let url = sourceURL else { return false }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// The videos to play, alphabetically by path. A file source yields
    /// itself; a folder yields every video beneath it, recursively, so a
    /// library organised one-folder-per-film works without the user having
    /// to flatten it.
    ///
    /// Read fresh on every activation rather than cached, so adding or
    /// removing files takes effect the next time the saver comes up.
    static func playlist() -> [URL] {
        guard let url = sourceURL else { return [] }
        guard sourceIsDirectory else { return isVideo(url) ? [url] : [] }
        guard let walker = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.contentTypeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter(isVideo)
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// The playlist in the order it should be played: shuffled for random,
    /// path order for sequential.
    ///
    /// Separate from `playlist()` because the two callers need it at
    /// different moments. A stage playing its own list orders it per pass;
    /// when every display mirrors one list, `AppDelegate` orders it once and
    /// hands the same array to all of them.
    static func orderedPlaylist(_ order: PlaybackOrder) -> [URL] {
        let all = playlist()
        return order == .random ? all.shuffled() : all
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
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        else { return false }
        return type.conforms(to: .movie)
    }
}
