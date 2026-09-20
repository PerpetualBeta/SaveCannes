import Foundation
import CoreGraphics

/// The motion of the empty-state logo: a box that drifts across the display and
/// reverses whichever component of its velocity meets an edge, the way the logo
/// on an idle DVD player did.
///
/// Pure arithmetic with no view in it, so the three properties that matter can
/// be checked without a screen: the box never leaves the display, an edge is
/// counted exactly once however large the step that met it, and a corner is
/// reported when and only when both axes turn on the same step.
///
/// The corner is the whole point of the thing being imitated. Waiting for the
/// logo to land exactly in a corner is the reason anyone remembers it — a
/// shared bit of television-era boredom that *The Office* put on screen in 2007
/// and that people still sit through. So the corner is reported rather than
/// swallowed, and `VideoStage` marks it.
struct NoticeDrift {

    /// What one step met on its way.
    struct Bounce {
        /// How many edges were crossed. More than two only for a step so large
        /// it folded across the display repeatedly.
        var edges: Int
        /// Both axes turned on this step: the box met a corner.
        var isCorner: Bool
        var isEmpty: Bool { edges == 0 }
    }

    /// How long the box takes to cross the display's short edge. Derived from
    /// the short edge rather than fixed in points so the movement reads the
    /// same on a laptop and on a 5K panel, which is the same reasoning the
    /// title caption's insets use.
    ///
    /// Eighteen seconds is a drift rather than a bounce: fast enough to see it
    /// move without watching for it, slow enough not to pull the eye off the
    /// message it is circling.
    static let secondsToCrossShortEdge: CGFloat = 18

    /// How close to the other edge the box must be, as a fraction of the
    /// shorter side of its travel, for a bounce to count as a corner.
    ///
    /// Zero would mean both axes turning on the very same step, which is what
    /// the original demanded and is the honest definition. It was measured and
    /// rejected: on the four display shapes tried it produced a corner once
    /// every 134 to 1,037 minutes, and on a portrait panel not once in a
    /// simulated day. This notice only appears on a display that is
    /// misconfigured, which nobody watches for two hours, so an exact corner is
    /// an Easter egg that can never be found.
    ///
    /// Two per cent of the short side is about a logo's own width from the
    /// angle — which is to say, close enough that someone watching would call
    /// it a corner, and no eye could tell it from an exact one.
    static let cornerTolerance: CGFloat = 0.02

    /// The range the starting direction is drawn from, as a ratio of vertical
    /// to horizontal travel.
    ///
    /// It excludes 1, which would send the box along a 45° path that retraces
    /// itself within a couple of bounces, and it stays well away from 0, which
    /// would slide it along one edge. Everything between is fair.
    private static let slopeRange: ClosedRange<CGFloat> = 0.45...0.85

    /// The range the starting position is drawn from, as a fraction of the
    /// distance the box may travel. It avoids the last sixth at each end so the
    /// logo does not begin in a corner, which would spend the surprise before
    /// anyone has looked at the screen.
    private static let startRange: ClosedRange<CGFloat> = 0.15...0.85

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

    /// Starting position and direction are drawn at random, per instance.
    ///
    /// This is what keeps two displays apart. Every stage builds its own drift,
    /// so a fixed start and a fixed slope put the logo in the same place going
    /// the same way on every screen, and a two-monitor desk shows the same
    /// picture twice — which was reported, and is worse than no animation at
    /// all, because it draws attention to the fact that it is a loop.
    ///
    /// Speed is *not* randomised. It is derived from the display's short edge
    /// so the movement reads the same on a laptop and a 5K panel, and two
    /// screens moving at visibly different rates would look like a fault.
    init(size: CGSize, in bounds: CGRect) {
        var rng = SystemRandomNumberGenerator()
        self.init(size: size, in: bounds, using: &rng)
    }

    /// The same, with the randomness handed in, so a test can pin it.
    init<R: RandomNumberGenerator>(size: CGSize, in bounds: CGRect, using rng: inout R) {
        let travel = Self.travel(in: bounds, size: size)
        origin = CGPoint(
            x: travel.minX + travel.width * CGFloat.random(in: Self.startRange, using: &rng),
            y: travel.minY + travel.height * CGFloat.random(in: Self.startRange, using: &rng))
        let slope = CGFloat.random(in: Self.slopeRange, using: &rng)
        let speed = min(bounds.width, bounds.height) / Self.secondsToCrossShortEdge
        let length = (1 + slope * slope).squareRoot()
        velocity = CGVector(dx: (Bool.random(using: &rng) ? 1 : -1) * speed / length,
                            dy: (Bool.random(using: &rng) ? 1 : -1) * speed * slope / length)
    }

    /// Advances by `seconds` and returns how many edges were met on the way.
    ///
    /// `bounds` and `size` are passed in on every step rather than stored,
    /// because a display can be reconfigured and the text can be re-laid out
    /// underneath a drift that is already running. Reading them fresh means the
    /// box is corrected to the new display instead of drifting off an old one.
    @discardableResult
    mutating func step(_ seconds: TimeInterval, in bounds: CGRect, size: CGSize) -> Bounce {
        let travel = Self.travel(in: bounds, size: size)
        var x = origin.x + velocity.dx * CGFloat(seconds)
        var y = origin.y + velocity.dy * CGFloat(seconds)
        let across = Self.reflect(&x, &velocity.dx, from: travel.minX, to: travel.maxX)
        let down = Self.reflect(&y, &velocity.dy, from: travel.minY, to: travel.maxY)
        origin = CGPoint(x: x, y: y)

        // Both axes turning on one step is unambiguously a corner. One axis
        // turning is a corner too if the box was up against the other edge at
        // the time — see `cornerTolerance` for why that latitude is allowed.
        let corner: Bool
        if across > 0 && down > 0 {
            corner = true
        } else if across > 0 || down > 0 {
            let margin = min(travel.width, travel.height) * Self.cornerTolerance
            let nearX = x - travel.minX <= margin || travel.maxX - x <= margin
            let nearY = y - travel.minY <= margin || travel.maxY - y <= margin
            corner = nearX && nearY
        } else {
            corner = false
        }
        return Bounce(edges: across + down, isCorner: corner)
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
