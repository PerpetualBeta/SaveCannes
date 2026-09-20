import AppKit

/// The bouncing logo, drawn rather than shipped as an asset.
///
/// It is the mark every DVD player put on an idle television: the letters on a
/// squashed ellipse with a small VIDEO bar beneath. Drawn with Bezier paths and
/// text so it is one colour at any size and costs no file in the bundle, which
/// also means it tints cleanly for the colour change on each bounce.
///
/// The proportions below were set by rendering it and looking, not calculated.
/// They are fractions of the view's own box so the logo is the same shape on a
/// laptop and a 5K panel.
final class DVDLogo: NSView {

    /// Width divided by height. The caller sizes the view from this so the
    /// drawing is never stretched.
    static let aspectRatio: CGFloat = 2.35

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

    // Fractions of the view's box. Named rather than inlined because the shape
    // was arrived at by eye and these are the numbers to move when adjusting it.
    private static let ellipseTop: CGFloat = 0.66
    private static let ellipseBottom: CGFloat = 0.36
    private static let letterHeight: CGFloat = 0.92
    private static let letterBaseline: CGFloat = 0.26
    private static let slant: CGFloat = 0.36
    private static let barWidth: CGFloat = 0.52
    private static let barHeight: CGFloat = 0.20
    private static let barBottom: CGFloat = 0.015

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0 else { return }
        tint.setFill()

        // The ellipse sits behind the letters and runs the full width. In the
        // original it is a flattened oval the letters sit across rather than
        // inside, which is why it is this shallow.
        let oval = NSBezierPath(ovalIn: NSRect(x: 0,
                                               y: h * Self.ellipseBottom,
                                               width: w,
                                               height: h * (Self.ellipseTop - Self.ellipseBottom)))
        oval.fill()

        // "DVD", slanted, in the same colour as the oval so the two merge into
        // one shape. That merging is what the original does — the letters are
        // not laid on top of the oval, they are part of it. An earlier version
        // cut the glyphs out and refilled them to leave a halo, which only
        // produced visible seams where the two fills met.
        //
        // A shear rather than an italic face: the original's slant is far
        // steeper than any system italic, and a shear is the only way to get it
        // from a font that is actually installed.
        drawSlanted("DVD",
                    size: h * Self.letterHeight,
                    weight: .black,
                    baseline: h * Self.letterBaseline,
                    colour: tint)

        // The VIDEO bar under the letters, with the word knocked out of it.
        let bar = NSRect(x: (w - w * Self.barWidth) / 2,
                         y: h * Self.barBottom,
                         width: w * Self.barWidth,
                         height: h * Self.barHeight)
        tint.setFill()
        NSBezierPath(roundedRect: bar, xRadius: bar.height * 0.18, yRadius: bar.height * 0.18).fill()
        drawWord("VIDEO",
                 in: bar,
                 size: bar.height * 0.62,
                 tracking: bar.height * 0.22)
    }

    /// Draws the wordmark sheared to the right.
    private func drawSlanted(_ text: String, size: CGFloat, weight: NSFont.Weight,
                             baseline: CGFloat, colour: NSColor) {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
        let string = NSAttributedString(string: text, attributes: attrs)
        let measured = string.size()

        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()

        // Shear and translate in one matrix rather than composing two, because
        // the composition order is the easy thing to get backwards here:
        // x' = x + slant·y + offset, y' = y + baseline.
        let sheared = measured.width + measured.height * Self.slant
        let transform = NSAffineTransform()
        transform.transformStruct = NSAffineTransformStruct(
            m11: 1, m12: 0,
            m21: Self.slant, m22: 1,
            tX: (bounds.width - sheared) / 2, tY: baseline)
        transform.concat()

        string.draw(at: .zero)
        context.restoreGraphicsState()
    }

    /// The word inside the VIDEO bar. Painted black rather than punched out of
    /// the bar with `destinationOut`: the punch-through worked on paper and came
    /// out white when rendered, because a layer-backed view composites against
    /// its own backing store rather than against the black behind it. Black ink
    /// on the tinted bar is the same picture with none of that to go wrong.
    private func drawWord(_ text: String, in rect: NSRect, size: CGFloat, tracking: CGFloat) {
        let font = NSFont.systemFont(ofSize: size, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
            .kern: tracking,
        ]
        let string = NSAttributedString(string: text, attributes: attrs)
        let measured = string.size()
        // The kern is added after the last character too, so take it back off
        // to keep the word centred in the bar.
        string.draw(at: NSPoint(x: rect.midX - (measured.width - tracking) / 2,
                                y: rect.midY - measured.height / 2))
    }
}
