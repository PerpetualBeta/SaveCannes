import AppKit

/// The bouncing logo: the DVD Video outline filled in one colour.
///
/// The shape itself lives in `DVDLogoPath`, which carries the real outline
/// rather than an impression of it. This view exists only to fill that outline
/// and to be something `VideoStage` can move around.
final class DVDLogo: NSView {

    /// Width divided by height of the artwork, so the caller can size the view
    /// without stretching it.
    static let aspectRatio: CGFloat = DVDLogoPath.aspectRatio

    var tint: NSColor = .white {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        tint.setFill()
        DVDLogoPath.path(in: bounds).fill()
    }
}
