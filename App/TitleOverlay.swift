import AppKit

/// The "what am I watching" caption: the video's title, plus its copyright line
/// when the file carries one, low in the corner of the display.
///
/// Modelled on Save Hollywood's version of the same idea, which existed so a
/// room could tell what was playing without anyone having to ask. It fades in,
/// holds long enough to read, and fades out — a caption, not part of the
/// picture.
final class TitleOverlay: NSView {

    // MARK: - Proportions and timings
    //
    // Every value here is either derived from the display or from the system
    // font, so the caption looks the same on a laptop and a 5K panel rather
    // than being tuned for whichever screen it was written on.

    /// Inset from the bottom-left corner, as a fraction of the display's short
    /// edge.
    private static let insetRatio: CGFloat = 0.04
    /// Caption size relative to the system font size. 2× reads from across a
    /// room without becoming a title card.
    private static let titleScale: CGFloat = 2
    private static let copyrightScale: CGFloat = 1.15
    /// Gap between the two lines, as a fraction of the title's own size.
    private static let lineGapRatio: CGFloat = 0.3

    private static let fadeInSeconds: TimeInterval = 0.6
    /// Long enough to read a long film title twice.
    private static let holdSeconds: TimeInterval = 5
    private static let fadeOutSeconds: TimeInterval = 1.2

    // MARK: - State

    private let titleField = NSTextField(labelWithString: "")
    private let copyrightField = NSTextField(labelWithString: "")
    private var pendingHide: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        alphaValue = 0
        for field in [titleField, copyrightField] {
            field.drawsBackground = false
            field.isSelectable = false
            field.lineBreakMode = .byTruncatingTail
            addSubview(field)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The caption is decoration over someone else's picture, so it never takes
    /// a click — mouse events belong to the dismiss monitor.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - Showing

    /// Show the caption, then fade it out on its own. Calling again while it's
    /// visible restarts the cycle rather than stacking two fades.
    func show(title: String, copyright: String?) {
        pendingHide?.cancel()

        titleField.attributedStringValue = Self.styled(title, scale: Self.titleScale, weight: .semibold)
        if let copyright = copyright, !copyright.isEmpty {
            copyrightField.attributedStringValue = Self.styled(copyright, scale: Self.copyrightScale, weight: .regular)
            copyrightField.isHidden = false
        } else {
            copyrightField.stringValue = ""
            copyrightField.isHidden = true
        }
        needsLayout = true
        layoutSubtreeIfNeeded()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeInSeconds
            animator().alphaValue = 1
        }

        let hide = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeOutSeconds
                self.animator().alphaValue = 0
            }
        }
        pendingHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdSeconds, execute: hide)
    }

    /// Drop the caption immediately, with no fade — for teardown, where the
    /// window is about to disappear anyway.
    func cancel() {
        pendingHide?.cancel()
        pendingHide = nil
        alphaValue = 0
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let inset = min(bounds.width, bounds.height) * Self.insetRatio
        // Width is capped so a long path-like title wraps into truncation
        // rather than running the full width of a wide display.
        let maxWidth = bounds.width - inset * 2
        let titleSize = titleField.sizeThatFits(NSSize(width: maxWidth, height: .greatestFiniteMagnitude))
        let copyrightSize = copyrightField.isHidden
            ? .zero
            : copyrightField.sizeThatFits(NSSize(width: maxWidth, height: .greatestFiniteMagnitude))
        let gap = copyrightField.isHidden ? 0 : titleSize.height * Self.lineGapRatio

        copyrightField.frame = CGRect(x: inset, y: inset,
                                      width: min(copyrightSize.width, maxWidth),
                                      height: copyrightSize.height)
        titleField.frame = CGRect(x: inset,
                                  y: inset + copyrightSize.height + gap,
                                  width: min(titleSize.width, maxWidth),
                                  height: titleSize.height)
    }

    // MARK: - Styling

    /// White text with a soft dark shadow. The shadow is what makes a caption
    /// legible over a bright frame — white-on-white is otherwise a real
    /// possibility on the wrong shot, and a video screensaver can't know in
    /// advance what it's drawing over.
    private static func styled(_ text: String, scale: CGFloat, weight: NSFont.Weight) -> NSAttributedString {
        let size = NSFont.systemFontSize * scale
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = size / 4
        shadow.shadowOffset = NSSize(width: 0, height: -size / 12)
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.white,
            .shadow: shadow,
        ])
    }
}
