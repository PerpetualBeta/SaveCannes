import Accelerate
import CoreML
import CoreVideo
import Foundation
import Vision

/// What a photograph is made of, as far as the desk needs to know: how far away
/// everything in it is, where its subject is if it has one, and whether to believe
/// that answer.
///
/// Measured once, on the same background task that decodes the photo, because both
/// of the expensive parts — Vision's subject mask and a Core ML depth pass — cost
/// tens of milliseconds and that is the one moment in a photo's life already off
/// the main thread.
struct PhotoAnalysis: @unchecked Sendable {

    /// Subject coverage, 0…1, at the resolution Vision returned it.
    let mask: [Float]
    let maskWidth: Int
    let maskHeight: Int

    /// Relative disparity, 0…1 with 1 nearest, at the depth model's resolution.
    /// Empty when no depth could be had, which the desk treats as "hold the focus
    /// still" rather than as a reason not to show the photograph.
    let disparity: [Float]
    let disparityWidth: Int
    let disparityHeight: Int

    /// The plane the lens holds sharp: the subject's own distance if there is a
    /// subject, otherwise the middle of the scene, so a landscape drifts as a whole
    /// instead of pivoting about nothing.
    let focusDisparity: Float

    /// Whether there is a subject worth holding sharp.
    ///
    /// Vision's mask alone cannot answer this — it will hand over a mask for very
    /// nearly any photograph, and the confidence on the observation is documented as
    /// possibly meaningless. So the answer is built from signals that are independent
    /// of the mask and of each other: is the masked region actually nearer than the
    /// rest of the picture, does the mask's outline sit on a step in the depth rather
    /// than run through flat ground, does the place a person would look fall inside
    /// it, and is it one compact thing rather than several scraps of scenery.
    let hasSubject: Bool

    var hasDepth: Bool { !disparity.isEmpty }
}

extension PhotoAnalysis {

    /// The grid the signals are compared on. Small deliberately: every one of them
    /// is a broad statement about the picture, and comparing them at full resolution
    /// would cost far more to answer the same question.
    private static let grid = 192

    /// Above this, believe the mask.
    ///
    /// Chosen from measurement rather than taste: across four photographs with a
    /// subject and ten without, the ones with a subject scored 0.89 to 1.00 and
    /// everything else scored nothing at all. The one photograph this rejects that
    /// does contain a person is a figure occupying 0.4% of the frame, which no effect
    /// keyed to it would be visible on anyway.
    private static let believable: Float = 0.35

    static func measure(_ image: CGImage, attention: PhotoFocus?) -> PhotoAnalysis {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let subject = VNGenerateForegroundInstanceMaskRequest()
        try? handler.perform([subject])

        var mask = [Float](repeating: 0, count: 1)
        var maskWidth = 1, maskHeight = 1
        if let observation = subject.results?.first, !observation.allInstances.isEmpty,
           let buffer = try? observation.generateScaledMaskForImage(
               forInstances: observation.allInstances, from: handler) {
            let read = channel(buffer)
            mask = read.values; maskWidth = read.width; maskHeight = read.height
        }

        let depth = PhotoDepth.shared.disparity(of: image)
        guard let depth = depth else {
            // No depth means no focus effect, but the photograph still goes on the
            // desk and still shakes and glitches.
            return PhotoAnalysis(mask: mask, maskWidth: maskWidth, maskHeight: maskHeight,
                                 disparity: [], disparityWidth: 0, disparityHeight: 0,
                                 focusDisparity: 0.5, hasSubject: false)
        }

        let maskGrid = resample(mask, maskWidth, maskHeight, to: grid)
        let depthGrid = resample(depth.values, depth.width, depth.height, to: grid)

        var insideCount = 0, outsideCount = 0
        var depthIn: Float = 0, depthOut: Float = 0
        for index in 0..<(grid * grid) {
            if maskGrid[index] >= 0.5 { insideCount += 1; depthIn += depthGrid[index] }
            else { outsideCount += 1; depthOut += depthGrid[index] }
        }
        let median = depthGrid.sorted()[depthGrid.count / 2]
        let focusDisparity = insideCount > 0 ? depthIn / Float(insideCount) : median
        let depthOutside = outsideCount > 0 ? depthOut / Float(outsideCount) : 0

        // Does the mask's outline stand on a cliff in the depth, or run through flat
        // ground? A mask that corresponds to a real object does the former; one
        // invented out of nothing does the latter. This is the strongest of the
        // signals — on real subjects the boundary gradient runs twelve to twenty-three
        // times the average.
        var boundarySum: Float = 0, boundaryCount = 0, flatSum: Float = 0, flatCount = 0
        for y in 1..<(grid - 1) {
            for x in 1..<(grid - 1) {
                let index = y * grid + x
                let dx = abs(depthGrid[index + 1] - depthGrid[index - 1])
                let dy = abs(depthGrid[index + grid] - depthGrid[index - grid])
                let gradient = max(dx, dy)
                let inside = maskGrid[index] >= 0.5
                if inside != (maskGrid[index + 1] >= 0.5) || inside != (maskGrid[index + grid] >= 0.5) {
                    boundarySum += gradient; boundaryCount += 1
                } else { flatSum += gradient; flatCount += 1 }
            }
        }
        let boundaryStep = boundaryCount > 0 ? boundarySum / Float(boundaryCount) : 0
        let flatStep = flatCount > 0 ? flatSum / Float(flatCount) : 0

        // Does the eye land on it? The attention map was already measured during the
        // decode, so this costs a lookup.
        var attentionInside = false
        if let attention = attention {
            let x = min(grid - 1, max(0, Int(attention.point.x * CGFloat(grid))))
            // The focus point is measured from the *bottom* — Vision's convention, and
            // an unflipped layer's — while row zero of the mask is the top. Without this
            // flip the test asks whether the eye lands on the subject's mirror image.
            let y = min(grid - 1, max(0, Int((1 - attention.point.y) * CGFloat(grid))))
            attentionInside = maskGrid[y * grid + x] >= 0.5
        }

        // One thing, or scraps of scenery? The largest connected piece, against the
        // whole mask.
        var seen = [Bool](repeating: false, count: grid * grid)
        var largest = 0
        for start in 0..<(grid * grid) where maskGrid[start] >= 0.5 && !seen[start] {
            var stack = [start], size = 0
            seen[start] = true
            while let index = stack.popLast() {
                size += 1
                let x = index % grid, y = index / grid
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < grid, ny >= 0, ny < grid else { continue }
                    let next = ny * grid + nx
                    if maskGrid[next] >= 0.5 && !seen[next] { seen[next] = true; stack.append(next) }
                }
            }
            largest = max(largest, size)
        }
        let masked = maskGrid.filter { $0 >= 0.5 }.count
        let largestPiece = masked > 0 ? Float(largest) / Float(masked) : 0

        // Multiplied, not averaged: any one of them failing is reason enough to doubt
        // the whole thing. Sharpness inside against outside was measured too and
        // thrown away — it came back between 0.88 and 9.0 with no pattern, because a
        // subject is often *less* detailed than a busy background.
        let nearer = max(0, min(1, (focusDisparity - depthOutside) / 0.25))
        let cliff = flatStep > 0 ? max(0, min(1, (boundaryStep / flatStep - 1) / 3)) : 0
        let looksAtIt: Float = attentionInside ? 1 : 0.35
        let compact = max(0, min(1, largestPiece))
        let certainty = nearer * cliff * looksAtIt * compact

        return PhotoAnalysis(mask: mask, maskWidth: maskWidth, maskHeight: maskHeight,
                             disparity: depth.values,
                             disparityWidth: depth.width, disparityHeight: depth.height,
                             focusDisparity: focusDisparity,
                             hasSubject: certainty > believable)
    }

    /// A single-channel float read of whatever pixel layout Vision or Core ML hands
    /// back, since neither promises which one it will be.
    static func channel(_ buffer: CVPixelBuffer) -> (values: [Float], width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        var values = [Float](repeating: 0, count: width * height)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return (values, width, height) }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
                for x in 0..<width { values[y * width + x] = row[x] }
            }
        case kCVPixelFormatType_OneComponent16Half:
            // A plane at a time, through vImage. `Float16` is unavailable when building
            // for Intel, so the type cannot be named here even though the data is that.
            var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: base),
                                       height: vImagePixelCount(height),
                                       width: vImagePixelCount(width),
                                       rowBytes: rowBytes)
            values.withUnsafeMutableBufferPointer { out in
                var destination = vImage_Buffer(data: out.baseAddress,
                                               height: vImagePixelCount(height),
                                               width: vImagePixelCount(width),
                                               rowBytes: width * 4)
                vImageConvert_Planar16FtoPlanarF(&source, &destination, 0)
            }
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width { values[y * width + x] = Float(row[x]) / 255 }
            }
        default:
            break
        }
        return (values, width, height)
    }

    private static func resample(_ field: [Float], _ width: Int, _ height: Int,
                                 to size: Int) -> [Float] {
        var out = [Float](repeating: 0, count: size * size)
        guard width > 0, height > 0, field.count >= width * height else { return out }
        for y in 0..<size {
            let sourceY = min(height - 1, y * height / size)
            for x in 0..<size {
                let sourceX = min(width - 1, x * width / size)
                out[y * size + x] = field[sourceY * width + sourceX]
            }
        }
        return out
    }
}

/// Monocular depth, from the one model Apple publishes that can be shipped.
///
/// Vision has no depth request: it can only read depth a *file* already carries, and
/// almost no photograph does. So this is Core ML — Depth Anything V2 Small, from
/// Apple's own model library, Apache-2.0 licensed. (The Base, Large and Giant sizes
/// are CC-BY-NC and could not be shipped in anything.)
///
/// Compiled form is what ships, so first use costs nothing: compiling an `.mlpackage`
/// takes seconds, and a screensaver has no moment to spare for it.
///
/// One instance for the whole app rather than one per display. Predictions are
/// serialised through a lock because `MLModel` makes no thread-safety promise, and
/// two displays measuring at once would otherwise be a race for the sake of twenty
/// milliseconds.
final class PhotoDepth {

    static let shared = PhotoDepth()

    private let model: MLModel?
    private let inputName: String
    private let outputName: String
    private let inputWidth: Int
    private let inputHeight: Int
    private let lock = NSLock()

    private init() {
        guard let url = Bundle.main.url(forResource: "DepthAnythingV2Small",
                                        withExtension: "mlmodelc") else {
            scLog("depth model not in the bundle — photographs will not drift in and out of focus")
            model = nil; inputName = ""; outputName = ""; inputWidth = 0; inputHeight = 0
            return
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        guard let loaded = try? MLModel(contentsOf: url, configuration: configuration),
              let input = loaded.modelDescription.inputDescriptionsByName.keys.sorted().first,
              let output = loaded.modelDescription.outputDescriptionsByName.keys.sorted().first,
              let constraint = loaded.modelDescription.inputDescriptionsByName[input]?.imageConstraint
        else {
            scLog("depth model could not be loaded — photographs will not drift in and out of focus")
            model = nil; inputName = ""; outputName = ""; inputWidth = 0; inputHeight = 0
            return
        }
        model = loaded
        inputName = input
        outputName = output
        inputWidth = constraint.pixelsWide
        inputHeight = constraint.pixelsHigh
        scLog("depth model ready (\(constraint.pixelsWide)×\(constraint.pixelsHigh))")
    }

    var isAvailable: Bool { model != nil }

    /// Relative disparity, normalised to 0…1 with 1 nearest.
    ///
    /// Relative is all that is needed: the blur the desk applies is linear in
    /// disparity, so the scale cancels — see `PhotoDesk.Lens`.
    func disparity(of image: CGImage) -> (values: [Float], width: Int, height: Int)? {
        guard let model = model else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, inputWidth, inputHeight, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let pixels = buffer else { return nil }
        CVPixelBufferLockBaseAddress(pixels, [])
        if let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels),
                                   width: inputWidth, height: inputHeight, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                       | CGBitmapInfo.byteOrder32Little.rawValue) {
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: inputWidth, height: inputHeight))
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])

        lock.lock()
        defer { lock.unlock() }
        guard let provider = try? MLDictionaryFeatureProvider(
                  dictionary: [inputName: MLFeatureValue(pixelBuffer: pixels)]),
              let result = try? model.prediction(from: provider),
              let map = result.featureValue(for: outputName)?.imageBufferValue
        else { return nil }
        var (values, width, height) = PhotoAnalysis.channel(map)
        guard !values.isEmpty else { return nil }
        let low = values.min() ?? 0, high = values.max() ?? 1
        if high > low {
            for index in values.indices { values[index] = (values[index] - low) / (high - low) }
        }
        return (values, width, height)
    }
}
