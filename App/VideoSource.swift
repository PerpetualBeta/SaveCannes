import Foundation
import UniformTypeIdentifiers

/// One place Save Cannes plays from: a folder, a single file, or a stream.
///
/// Sources are a list rather than a single path so a library can be assembled
/// from several places — a films folder, a folder of home video on an external
/// drive, a live stream — and each can be switched in or out of playback
/// without being forgotten. `isEnabled` is why the record exists at all: the
/// alternative is removing a source to stop playing it, and then having to find
/// it again.
struct VideoSource: Codable, Identifiable, Hashable {

    enum Kind: String, Codable {
        case folder
        case file
        /// Anything `AVPlayer` can open over the network: an HLS `.m3u8`, or a
        /// progressive MP4. Deliberately *not* a page to scrape — a URL here is
        /// handed to AVFoundation as-is.
        case stream
    }

    var id: UUID = UUID()
    var kind: Kind
    /// A filesystem path for `.folder` and `.file`; an absolute URL string for
    /// `.stream`.
    var location: String
    var isEnabled: Bool = true

    /// What the settings row calls it. A folder or file is named by its last
    /// component — nobody needs their folder structure spelled out in a list —
    /// and a stream by its host, which is the part that identifies it.
    var displayName: String {
        switch kind {
        case .folder, .file:
            return (location as NSString).lastPathComponent
        case .stream:
            return URL(string: location)?.host ?? location
        }
    }

    /// The second line: enough to tell two same-named sources apart.
    var subtitle: String {
        switch kind {
        case .folder, .file:
            return (location as NSString).deletingLastPathComponent
        case .stream:
            return location
        }
    }

    var url: URL? {
        switch kind {
        case .folder, .file: return URL(fileURLWithPath: location)
        case .stream:        return URL(string: location)
        }
    }

    var symbolName: String {
        switch kind {
        case .folder: return "folder"
        case .file:   return "film"
        case .stream: return "globe"
        }
    }

    /// Classify something the user picked. A directory is a folder, anything
    /// else a file — asked of the filesystem rather than guessed from the name,
    /// because a folder can be called `Holiday.mov` and a file can have no
    /// extension at all.
    static func forPickedFile(at url: URL) -> VideoSource {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        return VideoSource(kind: isDirectory ? .folder : .file, location: url.path)
    }

    /// A stream source from typed text, or nil when it isn't a URL this can play.
    ///
    /// Only `http`/`https` are accepted. `AVPlayer` speaks those (and `file:`,
    /// which belongs to the folder and file kinds instead); accepting `rtsp:` or
    /// a bare hostname would offer the user something that silently never plays.
    static func forTypedURL(_ text: String) -> VideoSource? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        return VideoSource(kind: .stream, location: url.absoluteString)
    }
}

/// Where the list of sources lives, and how it got there.
enum SourceStore {

    static let key = "sources"
    /// The single-source key Save Cannes shipped with, kept only for the
    /// migration below.
    static let legacyKey = "sourcePath"

    static func load() -> [VideoSource] {
        migrateLegacySourceIfNeeded()
        guard let data = UserDefaults.standard.data(forKey: key),
              let sources = try? JSONDecoder().decode([VideoSource].self, from: data)
        else { return [] }
        return sources
    }

    static func save(_ sources: [VideoSource]) {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Carry a pre-multi-source setting across, once.
    ///
    /// Without this, upgrading silently empties the playlist: the old key holds
    /// the only source the user ever chose, and the new code would never look
    /// at it. The legacy key is left on disk rather than deleted — it costs
    /// nothing and means a downgrade still finds its setting.
    private static func migrateLegacySourceIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.data(forKey: key) == nil else { return }
        let legacy = defaults.string(forKey: legacyKey) ?? ""
        guard !legacy.isEmpty else { return }
        let source = VideoSource.forPickedFile(at: URL(fileURLWithPath: legacy))
        save([source])
        scLog("migrated the single source \(legacy) into the sources list")
    }
}
