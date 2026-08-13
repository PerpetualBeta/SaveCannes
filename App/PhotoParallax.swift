import CoreGraphics
import CoreImage
import CoreVideo
import Vision

/// A photograph cut into slabs of depth, so the near ones can be moved further
/// than the far ones and the picture reads as having depth in it.
///
/// It is worth being plain about what this is and isn't. A true depth move needs a
/// depth value per pixel. macOS hands one over only for photos that were taken
/// with one — an iPhone portrait carries a disparity map in its file — and Vision
/// has no request that estimates depth from an ordinary photograph. What it does
/// have is subject lifting: the same machinery as dragging a cut-out out of a
/// photo in Preview. That gives a subject and a background, and smoothing the
/// boundary between them into a gradient gives a usable stand-in for depth.
///
/// ## Why slabs, and not a cut-out
///
/// Cutting the subject out and moving it is the obvious implementation, and it is
/// the one that cannot be made to work. Moving a cut-out uncovers the ground it
/// was standing on, and no photograph of that ground exists — so something has to
/// be invented, and on a real photograph the eye finds it. Worse, the geometry
/// guarantees the original stays visible beside the moved copy wherever the
/// subject is not star-shaped about the point it grows from: a hand held away from
/// the body ends up further out, and the place it came from is only covered if the
/// point a sixth of the way back towards the feet is also subject. Beside a waist
/// it is background. That is a photograph of a woman with four arms, and no
/// quality of inpainting fixes it — measured, on a photo with no invented fill
/// anywhere in it, the second arm is still there.
///
/// So nothing is cut and nothing is invented. The photograph is divided into many
/// slabs by depth, each slab is a piece of the original, and each is drawn with
/// its own scale. Neighbouring slabs overlap by one step of movement, so no gap
/// can open between them. What is left is a step in the content across each
/// boundary, and that step is the total differential movement divided by the
/// number of slabs — which is why the number of slabs is derived from the step we
/// are willing to see rather than picked.
struct PhotoBand: @unchecked Sendable {
    /// This slab's pixels. Cropped to what it covers, so a slab near the subject
    /// costs a small image rather than a full-frame one.
    let image: CGImage
    /// Where it sits in the photo, in photo pixels, y measured down from the top
    /// as `CGImage` does.
    let origin: CGPoint
    /// Depth at the middle of the slab: 0 is the far distance, 1 the subject.
    let depth: CGFloat
}

struct PhotoLayers: @unchecked Sendable {
    /// Far to near. Drawn in this order.
    let bands: [PhotoBand]
    /// The point everything expands about, normalised to the photo with the origin
    /// at the bottom left. The subject's own centre of area: expansion about
    /// anything else drags the subject sideways as well as forward.
    let anchor: CGPoint
    /// How much of the frame the subject covers, 0–1. Kept for the log line, and
    /// because it decides whether the effect is worth applying at all.
    let subjectShare: CGFloat
}

enum PhotoParallax {

    /// When the effect is worth applying.
    ///
    /// Under the bottom of this the subject is a speck and moving it differently
    /// achieves nothing anyone would see. Over the top there is hardly any
    /// background left for it to move against, so it stops reading as depth and
    /// starts reading as the whole picture being zoomed.
    static let workableSubjectShare: ClosedRange<CGFloat> = 0.02...0.80

    /// How wide the transition from subject depth to background depth is, as a
    /// multiple of the subject's own radius.
    ///
    /// This is the one genuinely aesthetic number here — it decides how much of
    /// the subject's surroundings comes forward with it. Small, and the subject
    /// moves alone, like a cut-out that happens not to have a seam; large, and the
    /// ground it stands on comes part of the way with it, which is what depth
    /// actually looks like. Checked by eye at 0.35 and 1.0, both clean.
    static let defaultDepthSpread: CGFloat = 1.0
    static let depthSpreadRange: ClosedRange<CGFloat> = 0.1...3

    /// A ceiling on the number of slabs, so a very large display cannot ask for a
    /// number of layers that costs more to build than the effect is worth. Reached
    /// only on displays where the step it implies is still under half a point.
    static let maximumBands = 256

    /// One context for the process. `CIContext` is documented as safe to share,
    /// and creating one per photo is the expensive way to do this.
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Cut a photo into slabs, or nil if it has no subject to build a depth field
    /// around — which is most landscapes, and is not a failure.
    ///
    /// - Parameters:
    ///   - zoom: the scene's own zoom over the move.
    ///   - strength: how much further the nearest slab travels than the scene.
    ///   - step: the largest content step, in photo pixels, that may show at a
    ///     slab boundary. The caller knows how many photo pixels a screen pixel
    ///     is worth, so it owns this number.
    ///   - spread: `defaultDepthSpread`, or whatever the user has dialled.
    static func layers(for image: CGImage, zoom: CGFloat, strength: CGFloat,
                       step: CGFloat, spread: CGFloat) -> PhotoLayers? {
        guard let depth = depthField(of: image, spread: spread),
              workableSubjectShare.contains(depth.share),
              step > 0, zoom > 1, strength > 0
        else { return nil }

        // How many slabs, from the step we are willing to see.
        //
        // A step in the content can only happen at a boundary between slabs, and
        // boundaries only exist where the depth actually changes: out in the flat
        // distance every pixel is in the same slab and there is nothing to step
        // across. So the distance that matters is not the corner of the photo but
        // the furthest point where depth is still in transition — for a subject in
        // the middle of a wide landscape that is a small fraction of the frame,
        // and sizing from the corner would ask for several times more slabs than
        // the picture has any use for.
        //
        // At that distance the nearest slab outruns the scene by (Z − z) of it,
        // and the slabs share that movement out between them.
        let far = depth.transitionRadius
        let differential = (zoom - 1) * strength * far
        let count = min(maximumBands, max(2, Int((differential / step).rounded(.up))))

        let bands = cut(image, by: depth, into: count, step: step)
        guard bands.count >= 2 else { return nil }
        return PhotoLayers(
            bands: bands,
            // Back to the bottom-left origin every other part of the photo path
            // uses, from the top-left origin the field is measured in.
            anchor: CGPoint(x: depth.anchor.x / CGFloat(image.width),
                            y: 1 - depth.anchor.y / CGFloat(image.height)),
            subjectShare: depth.share)
    }

    // MARK: - The depth field

    private struct DepthField {
        /// Depth per pixel, photo resolution, row 0 at the top.
        let values: [Float]
        /// How fast depth changes per pixel, same layout. Used to work out how far
        /// a slab has to be grown to keep touching its neighbour.
        let gradient: [Float]
        let width: Int
        let height: Int
        let share: CGFloat
        /// The subject's centre of area, in photo pixels, y down from the top.
        let anchor: CGPoint
        /// How far from the anchor the depth is still in transition. Past this
        /// every pixel belongs to the same slab, so no boundary — and no step in
        /// the content — can occur out there.
        let transitionRadius: CGFloat
    }

    private static func depthField(of image: CGImage, spread: CGFloat) -> DepthField? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first,
              !observation.allInstances.isEmpty,
              let buffer = try? observation.generateScaledMaskForImage(
                  forInstances: observation.allInstances, from: handler)
        else { return nil }

        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var mask = CIImage(cvPixelBuffer: buffer)
        // Documented as scaled to the image, but everything below is only right if
        // that holds, so it is made to hold rather than assumed.
        if Int(mask.extent.width) != width || Int(mask.extent.height) != height {
            guard mask.extent.width > 0, mask.extent.height > 0 else { return nil }
            mask = mask.transformed(by: CGAffineTransform(
                scaleX: CGFloat(width) / mask.extent.width,
                y: CGFloat(height) / mask.extent.height))
        }

        let raw = read(mask, width: width, height: height)
        var area = 0.0, sumX = 0.0, sumY = 0.0
        for index in 0..<(width * height) {
            let value = Double(raw[index])
            guard value.isFinite, value > 0 else { continue }
            area += value
            sumX += value * Double(index % width)
            sumY += value * Double(index / width)
        }
        guard area > 0 else { return nil }

        // The subject's own size, as the radius of a disc of the same area. Every
        // length here is a multiple of it, so none of them is a chosen distance.
        let radius = (area / .pi).squareRoot()
        let sigma = max(1, spread * CGFloat(radius))
        let blurred = mask.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma])
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        var values = read(blurred, width: width, height: height)

        // Normalised so the deepest point of the subject is 1. Without this a thin
        // subject would only ever get a fraction of the movement, because blurring
        // a sliver never reaches full value anywhere in it.
        let peak = values.max() ?? 0
        guard peak > 0 else { return nil }
        for index in values.indices { values[index] = min(1, values[index] / peak) }

        // How fast depth changes, by central difference. A slab has to be grown by
        // one step of movement to keep touching its neighbour, and a step of
        // movement is worth `gradient * step` of depth — which is nearly nothing
        // out in the flat distance, and is what stops the far slabs being grown
        // into each other across half the picture.
        var gradient = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * width
            let above = max(0, y - 1) * width, below = min(height - 1, y + 1) * width
            for x in 0..<width {
                let left = max(0, x - 1), right = min(width - 1, x + 1)
                let dx = (values[row + right] - values[row + left]) / Float(right - left == 0 ? 1 : right - left)
                let dy = (values[below + x] - values[above + x]) / Float(2)
                gradient[row + x] = (dx * dx + dy * dy).squareRoot()
            }
        }

        // The furthest point that is neither wholly subject nor wholly background:
        // one 8-bit level in from each end, which is the smallest difference that
        // can change a pixel.
        let level = Float(1.0 / 255.0)
        let anchor = CGPoint(x: sumX / area, y: sumY / area)
        var transition: CGFloat = 0
        for index in values.indices {
            let value = values[index]
            guard value > level, value < 1 - level else { continue }
            let distance = hypot(CGFloat(index % width) - anchor.x,
                                 CGFloat(index / width) - anchor.y)
            if distance > transition { transition = distance }
        }
        return DepthField(values: values, gradient: gradient, width: width, height: height,
                          share: CGFloat(area) / CGFloat(width * height),
                          anchor: anchor,
                          transitionRadius: max(1, transition))
    }

    private static func read(_ image: CIImage, width: Int, height: Int) -> [Float] {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &pixels, rowBytes: width * 16,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       format: .RGBAf, colorSpace: nil)
        var channel = [Float](repeating: 0, count: width * height)
        for index in 0..<(width * height) { channel[index] = pixels[index * 4] }
        return channel
    }

    // MARK: - Cutting

    /// Divide the photo into `count` slabs by depth.
    ///
    /// Two passes over the pixels rather than one pass per slab: the first works
    /// out how big each slab's image needs to be, the second fills them. A pixel
    /// belongs to every slab within `gradient * step` of its own depth, which is
    /// the overlap that stops a gap opening when the nearer slab moves further.
    private static func cut(_ image: CGImage, by depth: DepthField,
                            into count: Int, step: CGFloat) -> [PhotoBand] {
        guard let data = image.dataProvider?.data,
              let source = CFDataGetBytePtr(data)
        else { return [] }
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = image.bitsPerPixel / 8
        guard bytesPerPixel >= 3 else { return [] }
        // Where the red channel sits in whatever layout the decoder gave us.
        let alphaFirst = image.alphaInfo == .premultipliedFirst
            || image.alphaInfo == .first || image.alphaInfo == .noneSkipFirst
        let red = alphaFirst ? 1 : 0
        let width = depth.width, height = depth.height

        func span(_ index: Int) -> ClosedRange<Int> {
            let value = CGFloat(depth.values[index])
            let reach = CGFloat(depth.gradient[index]) * step
            let low = Int(((value - reach) * CGFloat(count)).rounded(.down))
            let high = Int(((value + reach) * CGFloat(count)).rounded(.down))
            return max(0, min(count - 1, low))...max(0, min(count - 1, high))
        }

        var minX = [Int](repeating: width, count: count)
        var maxX = [Int](repeating: -1, count: count)
        var minY = [Int](repeating: height, count: count)
        var maxY = [Int](repeating: -1, count: count)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                for band in span(row + x) {
                    if x < minX[band] { minX[band] = x }
                    if x > maxX[band] { maxX[band] = x }
                    if y < minY[band] { minY[band] = y }
                    if y > maxY[band] { maxY[band] = y }
                }
            }
        }

        var buffers: [Int: [UInt8]] = [:]
        for band in 0..<count where maxX[band] >= minX[band] {
            let w = maxX[band] - minX[band] + 1, h = maxY[band] - minY[band] + 1
            buffers[band] = [UInt8](repeating: 0, count: w * h * 4)
        }
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let from = y * bytesPerRow + x * bytesPerPixel
                for band in span(row + x) {
                    guard maxX[band] >= minX[band] else { continue }
                    let w = maxX[band] - minX[band] + 1
                    let to = ((y - minY[band]) * w + (x - minX[band])) * 4
                    buffers[band]?[to] = source[from + red]
                    buffers[band]?[to + 1] = source[from + red + 1]
                    buffers[band]?[to + 2] = source[from + red + 2]
                    buffers[band]?[to + 3] = 255
                }
            }
        }

        var bands: [PhotoBand] = []
        for band in 0..<count {
            guard maxX[band] >= minX[band], let pixels = buffers[band] else { continue }
            let w = maxX[band] - minX[band] + 1, h = maxY[band] - minY[band] + 1
            guard let provider = CGDataProvider(data: Data(pixels) as CFData),
                  let cropped = CGImage(
                      width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                      provider: provider, decode: nil, shouldInterpolate: true,
                      intent: .defaultIntent)
            else { continue }
            bands.append(PhotoBand(image: cropped,
                                   origin: CGPoint(x: minX[band], y: minY[band]),
                                   depth: (CGFloat(band) + 0.5) / CGFloat(count)))
        }
        return bands
    }
}
