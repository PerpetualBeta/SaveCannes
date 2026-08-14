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
