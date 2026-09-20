import Foundation
import CoreGraphics

/// The motion of the empty-state notice: a box that drifts across the display
/// and reverses whichever component of its velocity meets an edge, the way the
/// logo on an idle DVD player did.
///
/// Pure arithmetic with no view in it, so the two properties that matter can be
/// checked without a screen: the box never leaves the display, and an edge is
/// counted exactly once however large the step that met it.
struct NoticeDrift {

    /// How long the box takes to cross the display's short edge. Derived from
    /// the short edge rather than fixed in points so the movement reads the
    /// same on a laptop and on a 5K panel, which is the same reasoning the
    /// title caption's insets use.
    ///
    /// Eighteen seconds is a drift rather than a bounce: fast enough to see it
    /// move without watching for it, slow enough not to pull the eye off the
    /// message it is circling.
    static let secondsToCrossShortEdge: CGFloat = 18

    /// The starting direction, as a ratio of vertical to horizontal travel.
    /// Deliberately not 1, which would send the box along a 45° path that
    /// retraces itself within a couple of bounces and finds corners often. The
    /// golden ratio's reciprocal is the least well approximated by a fraction,
    /// so the path takes the longest possible time to repeat.
    private static let slope: CGFloat = 0.618_033_988_75

    /// Top-left-free origin of the box, in the view's coordinates.
    private(set) var origin: CGPoint
    /// Points per second.
    private(set) var velocity: CGVector

    /// The rectangle the origin may occupy: the display inset by the box, so a
    /// clamped origin puts the whole box on screen. Degenerate on an axis where
    /// the box is larger than the display, which is why the reflection below
    /// has to cope with an empty range rather than assume one.
    private static func travel(in bounds: CGRect, size: CGSize) -> CGRect {
        CGRect(x: bounds.minX,
               y: bounds.minY,
               width: max(0, bounds.width - size.width),
               height: max(0, bounds.height - size.height))
    }

    /// Where the box starts, as a fraction of the distance it may travel.
    /// Deliberately not the middle: the message it drifts behind is centred,
    /// and a logo that begins on top of the words is unreadable for the first
    /// few seconds, which are the seconds someone is most likely to be looking.
    private static let start = CGPoint(x: 0.25, y: 0.72)

    init(size: CGSize, in bounds: CGRect) {
        let travel = Self.travel(in: bounds, size: size)
        origin = CGPoint(x: travel.minX + travel.width * Self.start.x,
                         y: travel.minY + travel.height * Self.start.y)
        let speed = min(bounds.width, bounds.height) / Self.secondsToCrossShortEdge
        let length = (1 + Self.slope * Self.slope).squareRoot()
        velocity = CGVector(dx: speed / length, dy: speed * Self.slope / length)
    }

    /// Advances by `seconds` and returns how many edges were met on the way.
    ///
    /// `bounds` and `size` are passed in on every step rather than stored,
    /// because a display can be reconfigured and the text can be re-laid out
    /// underneath a drift that is already running. Reading them fresh means the
    /// box is corrected to the new display instead of drifting off an old one.
    @discardableResult
    mutating func step(_ seconds: TimeInterval, in bounds: CGRect, size: CGSize) -> Int {
        let travel = Self.travel(in: bounds, size: size)
        var hits = 0
        var x = origin.x + velocity.dx * CGFloat(seconds)
        var y = origin.y + velocity.dy * CGFloat(seconds)
        hits += Self.reflect(&x, &velocity.dx, from: travel.minX, to: travel.maxX)
        hits += Self.reflect(&y, &velocity.dy, from: travel.minY, to: travel.maxY)
        origin = CGPoint(x: x, y: y)
        return hits
    }

    /// Folds a value back into `lo...hi`, flipping the velocity once per fold.
    ///
    /// A step large enough to cross the whole display — the first frame after a
    /// stall, or a display link that missed a beat — would otherwise leave the
    /// box outside and moving further out, because a single "if it went past,
    /// turn it round" both misses the overshoot and can turn it round twice.
    /// Looping fixes both.
    private static func reflect(_ p: inout CGFloat, _ v: inout CGFloat,
                                from lo: CGFloat, to hi: CGFloat) -> Int {
        guard hi > lo else {
            // The box does not fit on this axis. Park it and stop moving, which
            // is the honest answer: there is nowhere to travel.
            p = lo
            v = 0
            return 0
        }
        var hits = 0
        while p < lo || p > hi {
            if p < lo { p = 2 * lo - p } else { p = 2 * hi - p }
            v = -v
            hits += 1
        }
        return hits
    }
}
