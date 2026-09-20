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

    /// Width divided by height of the ink. Taken from the flattened curves,
    /// not from the control points: the control points sit outside the shape,
    /// which left the logo a little short of the right-hand edge.
    static let aspectRatio: CGFloat = 2.2719

    /// 0 = move(x,y) · 1 = line(x,y) · 2 = curve(c1,c2,end) · 3 = close.
    /// Coordinates are fractions of the unit box.
    private static let commands: [Double] = [
        0, 0.63375, 1, 2, 0.63375, 1, 0.57968, 0.85421, 0.56957, 0.8267,
        2, 0.51563, 0.67904, 0.50599, 0.63952, 0.50446, 0.62911, 2, 0.5047, 0.63952,
        0.5027, 0.67957, 0.47966, 0.82884, 2, 0.47355, 0.86862, 0.4538, 1, 0.4538,
        1, 1, 0.08604, 1, 1, 0.07311, 0.8761, 1, 0.16972, 0.87583,
        1, 0.1924, 0.87583, 2, 0.25458, 0.87583, 0.29243, 0.81923, 0.28197, 0.71829,
        2, 0.27045, 0.60854, 0.21615, 0.56075, 0.15844, 0.56075, 1, 0.13681, 0.56075,
        1, 0.1649, 0.83017, 1, 0.06829, 0.83017, 1, 0.02715, 0.43685, 1,
        0.16431, 0.43685, 2, 0.26727, 0.43685, 0.3653, 0.56048, 0.38246, 0.71829, 2,
        0.38563, 0.7474, 0.38528, 0.81976, 0.3774, 0.86302, 2, 0.37729, 0.86462, 0.37705,
        0.86595, 0.37635, 0.86943, 2, 0.37599, 0.87076, 0.37576, 0.87717, 0.3774, 0.8785,
        2, 0.37835, 0.87931, 0.37999, 0.8753, 0.38023, 0.87423, 2, 0.38093, 0.86943,
        0.38164, 0.86569, 0.38164, 0.86569, 1, 0.46885, 0.30654, 1, 0.69087, 0.87583,
        1, 0.7849, 0.87583, 1, 0.80758, 0.87583, 2, 0.86964, 0.87583, 0.90796,
        0.81923, 0.89738, 0.71829, 2, 0.88586, 0.60854, 0.83133, 0.56075, 0.77362, 0.56075,
        1, 0.75187, 0.56075, 1, 0.78008, 0.83017, 1, 0.68347, 0.83017, 1,
        0.64233, 0.43685, 1, 0.77937, 0.43685, 2, 0.88245, 0.43685, 0.98106, 0.55995,
        0.99764, 0.71829, 2, 1.01421, 0.87664, 0.94181, 1, 0.83826, 1, 1,
        0.63375, 1, 0, 0.47226, 0.30414, 2, 0.21145, 0.30414, 0, 0.23605,
        0, 0.15194, 2, 0, 0.06809, 0.21145, 0, 0.47226, 0, 2,
        0.73307, 0, 0.94451, 0.06809, 0.94451, 0.15194, 2, 0.94451, 0.23605, 0.73307,
        0.30414, 0.47226, 0.30414, 3, 0, 0.45521, 0.09826, 2, 0.39562, 0.09826,
        0.34732, 0.12096, 0.34732, 0.149, 2, 0.34732, 0.17704, 0.39562, 0.19973, 0.45521,
        0.19973, 2, 0.51469, 0.19973, 0.56299, 0.17704, 0.56299, 0.149, 2, 0.56299,
        0.12096, 0.51469, 0.09826, 0.45521, 0.09826,
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
