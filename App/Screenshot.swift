import AppKit
import AVFoundation

/// Save the frame currently on screen as a PNG in
/// `~/Pictures/Save Cannes/screenshot-TIMESTAMP.png`.
///
/// The frame is pulled from the asset with `AVAssetImageGenerator` rather than
/// captured off the view. ASCII Saver can use `cacheDisplay(in:to:)` because it
/// draws its picture itself; an `AVPlayerLayer` composites in the window server
/// and hands back nothing useful. Going to the asset also gives the full frame
/// at the video's own resolution, so a screenshot taken in "full screen" mode
/// isn't cropped to the shape of the display it happened to be playing on.
///
/// Called on the main thread from the hotkey handler while the saver is up.
enum Screenshot {

    static func capture(from stage: VideoStage) {
        guard let frame = stage.currentFrame else {
            scLog("screenshot: nothing playing")
            return
        }
        let generator = AVAssetImageGenerator(asset: frame.asset)
        generator.appliesPreferredTrackTransform = true
        // Exact frame. The default tolerance is "any convenient nearby
        // sample", which on long-GOP footage can land seconds away from what
        // the user was actually looking at when they pressed the key.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.generateCGImageAsynchronously(for: frame.time) { image, _, error in
            guard let image = image else {
                scLog("screenshot: frame extraction failed — \(error?.localizedDescription ?? "unknown")")
                return
            }
            guard let data = NSBitmapImageRep(cgImage: image)
                .representation(using: .png, properties: [:]) else {
                scLog("screenshot: PNG encode failed")
                return
            }
            saveToPicturesFolder(data)
        }
    }

    private static func saveToPicturesFolder(_ pngData: Data) {
        let fm = FileManager.default
        guard let pictures = fm.urls(for: .picturesDirectory, in: .userDomainMask).first else {
            scLog("screenshot: no Pictures dir")
            return
        }
        let dir = pictures.appendingPathComponent("Save Cannes", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let filename = "screenshot-\(formatter.string(from: Date())).png"
        let url = dir.appendingPathComponent(filename)

        do {
            try pngData.write(to: url)
            scLog("screenshot: saved \(url.path)")
        } catch {
            scLog("screenshot: write failed \(error.localizedDescription)")
        }
    }
}
