import CoreGraphics
import CoreVideo
import Vision

/// Where the eye goes in a photo.
///
/// One point, normalised to the photo's own dimensions with the origin at the
/// bottom left. That is Vision's convention, and it is also an unflipped
/// `CALayer`'s, so the point becomes a position on screen without a coordinate
/// flip in between — the flip a photo module gets wrong once and then shows
/// upside down forever.
struct PhotoFocus: Sendable, Equatable {
    let point: CGPoint

    /// Ask Vision what part of the photo a person would look at.
    ///
    /// Attention-based saliency rather than objectness-based: the question is
    /// "what draws the eye", which is what the attention model answers, and it
    /// answers it for every photo — a beach at sunset with nothing in it
    /// included. Objectness returns boxes round things it recognises, so a
    /// photo it recognises nothing in gets no answer at all, and a photo module
    /// that only works on pictures of dogs is worse than one that works the
    /// same way on everything.
    ///
    /// Run on the decoded, display-sized copy rather than the original file:
    /// Vision downsamples to its own working size regardless, and the decoded
    /// copy has already had its EXIF orientation applied, so the answer comes
    /// back in the same orientation the photo is shown in.
    static func detect(in image: CGImage) -> PhotoFocus? {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            // No answer is a supported answer: the caller falls back to framing
            // the photo the way it did before there was a focus point at all.
            return nil
        }
        guard let heatMap = request.results?.first?.pixelBuffer else { return nil }
        return centreOfAttention(in: heatMap)
    }

    /// The centre of mass of the bright half of an attention map, split from the
    /// dim half by the map's own histogram.
    ///
    /// The split matters more than it sounds. Weighting by raw heat drags every
    /// answer toward the middle, because the middle is where a mostly-uniform
    /// map has most of its mass; weighting by the excess over the mean does the
    /// same thing more slowly — measured against cards with a known answer, a
    /// subject at 0.25 came back as 0.36, and photographs of a landscape all
    /// came back within a couple of percent of dead centre whatever was in them.
    /// A damped answer is a crop that doesn't move and a pan aimed at nothing.
    ///
    /// So the background is cut away first, at the threshold that best separates
    /// the two — Otsu's method, which reads the split off the histogram instead
    /// of taking a number someone liked the look of. What is left is the salient
    /// region, and its centre of mass is the answer. A photo with nothing in
    /// particular in it still answers with something near its middle, because a
    /// map with no structure has no off-centre bright region to find, which is
    /// the honest answer and produces a straight push-in rather than a pan to
    /// nowhere.
    ///
    /// Internal rather than private so it can be measured directly: the row
    /// order of the map is the one thing here that can't be reasoned out from
    /// the documentation.
    static func centreOfAttention(in heatMap: CVPixelBuffer) -> PhotoFocus? {
        // The map is documented as a single-channel float heat map. Reading it
        // as anything else would be reading whatever a future revision put
        // there, so an unexpected format means no answer rather than a wrong one.
        guard CVPixelBufferGetPixelFormatType(heatMap) == kCVPixelFormatType_OneComponent32Float
        else { return nil }
        let width = CVPixelBufferGetWidth(heatMap)
        let height = CVPixelBufferGetHeight(heatMap)
        guard width > 0, height > 0 else { return nil }

        CVPixelBufferLockBaseAddress(heatMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(heatMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(heatMap) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(heatMap)

        func row(_ index: Int) -> UnsafePointer<Float> {
            UnsafePointer(base.advanced(by: index * bytesPerRow).assumingMemoryBound(to: Float.self))
        }

        var heat = [Double]()
        heat.reserveCapacity(width * height)
        for y in 0..<height {
            let values = row(y)
            for x in 0..<width {
                // A map that came back with holes in it is still usable; the
                // holes just aren't the subject.
                heat.append(values[x].isFinite ? Double(values[x]) : 0)
            }
        }
        guard let cut = separationThreshold(heat) else { return nil }

        var mass = 0.0
        var sum = CGPoint.zero
        for y in 0..<height {
            for x in 0..<width {
                let weight = heat[y * width + x] - cut
                guard weight > 0 else { continue }
                mass += weight
                // Pixel centres, so a 1×1 map answers with the middle of the
                // photo rather than its corner.
                sum.x += weight * (Double(x) + 0.5) / Double(width)
                sum.y += weight * (Double(y) + 0.5) / Double(height)
            }
        }
        // Nothing above the threshold means nothing to aim at.
        guard mass > 0 else { return nil }
        // Row 0 is the top of the photo, and this point is measured from the
        // bottom — see `centreOfAttention`'s note about measuring that rather
        // than assuming it.
        return PhotoFocus(point: CGPoint(x: sum.x / mass, y: 1 - sum.y / mass))
    }

    /// The brightness that best separates a heat map's subject from its
    /// background: Otsu's method, which picks the split that leaves the two
    /// sides as unlike each other as possible.
    ///
    /// It is used here because it has nothing to tune. Any fixed threshold —
    /// half the peak, the mean, the mean plus a bit — is a number that suits the
    /// photographs it was chosen on, and a photo module that only frames a
    /// certain kind of picture well is the thing this is trying not to be.
    ///
    /// Returns nil for a map with no range at all, where every split is the same
    /// split and there is nothing to separate.
    private static func separationThreshold(_ heat: [Double]) -> Double? {
        guard let low = heat.min(), let high = heat.max(), high > low else { return nil }
        // Finer than a 68×68 map has distinguishable levels, so the bin width
        // never decides the answer.
        let bins = 256
        var histogram = [Double](repeating: 0, count: bins)
        for value in heat {
            let bin = Int((value - low) / (high - low) * Double(bins - 1))
            histogram[bin] += 1
        }
        let count = Double(heat.count)
        var weightedTotal = 0.0
        for (bin, hits) in histogram.enumerated() { weightedTotal += Double(bin) * hits }

        var bestBin = 0
        var bestVariance = -1.0
        var belowCount = 0.0
        var belowWeighted = 0.0
        for (bin, hits) in histogram.enumerated() {
            belowCount += hits
            let aboveCount = count - belowCount
            guard belowCount > 0, aboveCount > 0 else { continue }
            belowWeighted += Double(bin) * hits
            let belowMean = belowWeighted / belowCount
            let aboveMean = (weightedTotal - belowWeighted) / aboveCount
            // Between-class variance: how far apart the two halves' averages
            // are, weighted by how much of the map each holds.
            let variance = belowCount * aboveCount * (belowMean - aboveMean) * (belowMean - aboveMean)
            if variance > bestVariance {
                bestVariance = variance
                bestBin = bin
            }
        }
        return low + Double(bestBin) / Double(bins - 1) * (high - low)
    }
}

/// The geometry of putting one photo on one display: which part of it is on
/// screen, and where its pan is aimed.
///
/// Pure arithmetic on purpose. Every rule in here has to hold for a photo of
/// any shape on a display of any shape, and the only way to know that it does
/// is to be able to work it out — and test it — with no screen involved.
enum PhotoFraming {

    /// The frame for a photo layer that fills the display.
    ///
    /// The layer is handed the whole photo at the scale that covers the
    /// display, which makes it *larger* than the display in one axis. The part
    /// hanging over the edge is what the enclosing view clips away, and it is
    /// also the slack this uses: where there is slack, the layer slides so the
    /// focus point sits at the middle of the display.
    ///
    /// That is what stops a portrait photo on a landscape display being cropped
    /// to a band across its middle irrespective of where the subject is. A
    /// photo the same shape as the display has no slack, so it is framed
    /// exactly as it was before any of this existed.
    static func fillFrame(imageSize: CGSize, in bounds: CGRect, focus: PhotoFocus?) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              bounds.width > 0, bounds.height > 0
        else { return bounds }

        let scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        // `scale` covers both axes, so neither of these can be negative other
        // than by rounding.
        let slack = CGSize(width: max(0, (size.width - bounds.width) / 2),
                           height: max(0, (size.height - bounds.height) / 2))

        var centre = CGPoint(x: bounds.midX, y: bounds.midY)
        if let focus = focus {
            let wanted = CGPoint(x: bounds.midX - (focus.point.x - 0.5) * size.width,
                                 y: bounds.midY - (focus.point.y - 0.5) * size.height)
            centre = CGPoint(x: min(max(wanted.x, centre.x - slack.width), centre.x + slack.width),
                             y: min(max(wanted.y, centre.y - slack.height), centre.y + slack.height))
        }
        return CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// The translation at the zoomed end of a pan, in display points.
    ///
    /// Aimed at the focus point: the translation returned is the one that would
    /// bring it to the middle of the display at the zoomed end, cut back to the
    /// motion budget. So the *direction* comes from the photo and the
    /// *distance* is the same for every photo — a pan whose speed depended on
    /// where the subject happened to be would read as a fault rather than as a
    /// composition. A photo with no focus point, or one whose subject is
    /// already dead centre, pans in a random direction instead, which is what
    /// every photo did before.
    ///
    /// Then clamped to what keeps the photo covering the display. That clamp,
    /// not the budget, is what guarantees an edge of the photo is never in
    /// shot; the budget is only about how the movement looks.
    static func panTranslation(layerFrame: CGRect, in bounds: CGRect,
                               zoom: CGFloat, budgetFraction: CGFloat,
                               focus: PhotoFocus?, fallbackAngle: CGFloat) -> CGPoint {
        // Half the overscan the zoom creates is the furthest a pan could go
        // before an edge showed; the fraction spends part of that.
        let budget = CGSize(width: (zoom - 1) / 2 * budgetFraction * bounds.width,
                            height: (zoom - 1) / 2 * budgetFraction * bounds.height)
        guard budget.width > 0, budget.height > 0 else { return .zero }

        let centre = CGPoint(x: layerFrame.midX, y: layerFrame.midY)
        var direction = CGPoint(x: cos(fallbackAngle), y: sin(fallbackAngle))
        if let focus = focus {
            let subject = CGPoint(x: layerFrame.minX + focus.point.x * layerFrame.width,
                                  y: layerFrame.minY + focus.point.y * layerFrame.height)
            // The layer is scaled about its own centre and then translated, so
            // a point at `subject` ends up at `centre + zoom * (subject -
            // centre) + t`. This is that solved for the `t` that lands it in
            // the middle of the display.
            let aim = CGPoint(x: bounds.midX - centre.x - zoom * (subject.x - centre.x),
                              y: bounds.midY - centre.y - zoom * (subject.y - centre.y))
            // Measured in budgets rather than in points, so "diagonal" means
            // diagonal on the screen instead of diagonal in some space that
            // depends on the display's aspect ratio.
            let scaled = CGPoint(x: aim.x / budget.width, y: aim.y / budget.height)
            let length = (scaled.x * scaled.x + scaled.y * scaled.y).squareRoot()
            if length > 0 {
                direction = CGPoint(x: scaled.x / length, y: scaled.y / length)
            }
        }
        let wanted = CGPoint(x: direction.x * budget.width, y: direction.y * budget.height)

        let zoomed = CGRect(x: centre.x - layerFrame.width * zoom / 2,
                            y: centre.y - layerFrame.height * zoom / 2,
                            width: layerFrame.width * zoom,
                            height: layerFrame.height * zoom)
        let lower = CGPoint(x: bounds.maxX - zoomed.maxX, y: bounds.maxY - zoomed.maxY)
        let upper = CGPoint(x: bounds.minX - zoomed.minX, y: bounds.minY - zoomed.minY)
        // A layer that covers the display gives `lower <= 0 <= upper`. The
        // guard is for the case that can't happen, where standing still is the
        // safe answer.
        guard lower.x <= upper.x, lower.y <= upper.y else { return .zero }
        return CGPoint(x: min(max(wanted.x, lower.x), upper.x),
                       y: min(max(wanted.y, lower.y), upper.y))
    }
}
