import AppKit

/// The DVD Video logo, as its own outline rather than an impression of it.
///
/// The path data is the public SVG from Wikimedia Commons
/// (`File:Dvd_logo.svg`), with its two `<g>` translations applied, normalised
/// into a unit box and flipped so y runs up the way AppKit does. Normalising
/// means the ink fills the view's frame exactly, which matters for more than
/// tidiness: `NoticeDrift` bounces the frame, so any ink outside it would hang
/// over the edge of the display with nothing to turn it round. An earlier
/// hand-drawn version did exactly that along the top.
///
/// Encoded as numbers rather than as a picture so the bundle carries no asset
/// and the shape tints cleanly for the colour change on each bounce.
enum DVDLogoPath {

    /// Width divided by height of the ink, from the SVG's own bounding box.
    static let aspectRatio: CGFloat = 2.3041

    /// 0 = move(x,y) · 1 = line(x,y) · 2 = curve(c1,c2,end) · 3 = close.
    /// Coordinates are fractions of the unit box.
    private static let commands: [Double] = [
        0, 0.62487, 1, 2, 0.62487, 1, 0.57156, 0.85421, 0.56159, 0.8267,
        2, 0.5084, 0.67904, 0.4989, 0.63952, 0.49739, 0.62911, 2, 0.49762, 0.63952,
        0.49565, 0.67957, 0.47294, 0.82884, 2, 0.46691, 0.86862, 0.44744, 1, 0.44744,
        1, 1, 0.08483, 1, 1, 0.07208, 0.8761, 1, 0.16734, 0.87583,
        1, 0.18971, 0.87583, 2, 0.25101, 0.87583, 0.28833, 0.81923, 0.27802, 0.71829,
        2, 0.26666, 0.60854, 0.21312, 0.56075, 0.15622, 0.56075, 1, 0.13489, 0.56075,
        1, 0.16259, 0.83017, 1, 0.06733, 0.83017, 1, 0.02677, 0.43685, 1,
        0.16201, 0.43685, 2, 0.26353, 0.43685, 0.36018, 0.56048, 0.3771, 0.71829, 2,
        0.38023, 0.7474, 0.37988, 0.81976, 0.37212, 0.86302, 2, 0.372, 0.86462, 0.37177,
        0.86595, 0.37107, 0.86943, 2, 0.37073, 0.87076, 0.37049, 0.87717, 0.37212, 0.8785,
        2, 0.37304, 0.87931, 0.37467, 0.8753, 0.3749, 0.87423, 2, 0.37559, 0.86943,
        0.37629, 0.86569, 0.37629, 0.86569, 1, 0.46228, 0.30654, 1, 0.68119, 0.87583,
        1, 0.7739, 0.87583, 1, 0.79627, 0.87583, 2, 0.85746, 0.87583, 0.89524,
        0.81923, 0.88481, 0.71829, 2, 0.87345, 0.60854, 0.81968, 0.56075, 0.76278, 0.56075,
        1, 0.74134, 0.56075, 1, 0.76915, 0.83017, 1, 0.67389, 0.83017, 1,
        0.63333, 0.43685, 1, 0.76846, 0.43685, 2, 0.87009, 0.43685, 0.96732, 0.55995,
        0.98366, 0.71829, 2, 1, 0.87664, 0.92861, 1, 0.82652, 1, 1,
        0.62487, 1, 0, 0.46564, 0.30414, 2, 0.20848, 0.30414, 0, 0.23605,
        0, 0.15194, 2, 0, 0.06809, 0.20848, 0, 0.46564, 0, 2,
        0.7228, 0, 0.93128, 0.06809, 0.93128, 0.15194, 2, 0.93128, 0.23605, 0.7228,
        0.30414, 0.46564, 0.30414, 3, 0, 0.44884, 0.09826, 2, 0.39008, 0.09826,
        0.34245, 0.12096, 0.34245, 0.149, 2, 0.34245, 0.17704, 0.39008, 0.19973, 0.44884,
        0.19973, 2, 0.50747, 0.19973, 0.5551, 0.17704, 0.5551, 0.149, 2, 0.5551,
        0.12096, 0.50747, 0.09826, 0.44884, 0.09826,
    ]

    /// The outline scaled into `rect`. Non-zero winding, which is the SVG's own
    /// fill rule and what leaves the counters of the letters open.
    static func path(in rect: CGRect) -> NSBezierPath {
        let path = NSBezierPath()
        path.windingRule = .nonZero
        func point(_ i: Int) -> CGPoint {
            CGPoint(x: rect.minX + CGFloat(commands[i]) * rect.width,
                    y: rect.minY + CGFloat(commands[i + 1]) * rect.height)
        }
        var i = 0
        while i < commands.count {
            switch Int(commands[i]) {
            case 0: path.move(to: point(i + 1)); i += 3
            case 1: path.line(to: point(i + 1)); i += 3
            case 2:
                path.curve(to: point(i + 5), controlPoint1: point(i + 1), controlPoint2: point(i + 3))
                i += 7
            default: path.close(); i += 1
            }
        }
        return path
    }
}
