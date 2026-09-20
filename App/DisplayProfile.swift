import AppKit
import CoreGraphics

/// A display-specific playback choice. The display UUID is supplied by
/// CoreGraphics, rather than using an `NSScreen` array position: positions and
/// display numbers change when a dock, adapter, or monitor is reconnected.
struct DisplayProfile: Codable, Identifiable, Equatable {
    var displayID: String
    var displayName: String
    /// The sources this display may play. An empty list is intentional: it
    /// lets a user leave one display black without removing its profile.
    var sourceIDs: Set<UUID>
    var scaling: VideoScaling

    var id: String { displayID }

    init(screen: NSScreen, sourceIDs: Set<UUID>, scaling: VideoScaling) {
        self.displayID = DisplayIdentity.id(for: screen)
        self.displayName = screen.localizedName
        self.sourceIDs = sourceIDs
        self.scaling = scaling
    }
}

/// Persistent display identities and profiles. Profiles for disconnected
/// displays are deliberately retained, so an external monitor remembers its
/// setup when it is plugged back in.
enum DisplayProfileStore {
    private static let key = "displayProfiles"

    static func load() -> [DisplayProfile] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let profiles = try? JSONDecoder().decode([DisplayProfile].self, from: data)
        else { return [] }
        return profiles
    }

    static func save(_ profiles: [DisplayProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func profile(for screen: NSScreen) -> DisplayProfile? {
        let id = DisplayIdentity.id(for: screen)
        return load().first(where: { $0.displayID == id })
    }
}

enum DisplayIdentity {
    /// `CGDisplayCreateUUIDFromDisplayID` is stable for the physical display,
    /// unlike `NSScreen.screens` ordering and unlike its transient numeric ID.
    static func id(for screen: NSScreen) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else {
            // A screen without a display number is exceptionally unusual. Its
            // name makes a useful, harmless fallback; playback still works.
            return "name:" + screen.localizedName
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID) {
            return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
        }
        return "display:" + String(displayID)
    }
}
