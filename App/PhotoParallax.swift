import CoreGraphics
import CoreImage
import CoreVideo
import Vision

/// A photo split into its subject and the scene behind it, so the two can be
/// moved at different rates.
///
/// This is the flat-photo version of parallax, and it is worth being plain about
/// what it is and isn't. A true 2.5D move needs a depth value per pixel. macOS
/// hands one over only for photos that were taken with one — an iPhone portrait
/// carries a disparity map in its file — and Vision has no request that estimates
/// depth from an ordinary photograph. What it does have is subject lifting: the
/// same machinery as dragging a cut-out out of a photo in Preview. That gives two
/// planes rather than a continuum, which is enough for the effect that reads as
/// depth: the subject drifting across the scene behind it, at a different rate.
struct PhotoLayers: @unchecked Sendable {
    /// The photo with the subject smeared out of it, so that when the subject
    /// slides the thing revealed behind is scenery rather than a second copy of
    /// the subject.
    let scene: CGImage
    /// The subject alone, everything else transparent.
    let subject: CGImage
    /// How much of the frame the subject covers, 0–1. Kept because it decides
    /// whether the effect is worth applying at all.
    let subjectShare: CGFloat
    /// Where the subject meets the world, normalised to the photo with the origin
    /// at the bottom left: across, the middle of it; up, the foot of it.
    ///
    /// The point the subject grows about, and the reason the effect can be strong
    /// at all. Growing a subject about its middle slides its feet down through
    /// whatever it is standing on. Growing it about its foot keeps the feet where
    /// they are and moves the head, which is what somebody walking towards you
    /// does. It also means the grown subject contains the hole it was cut from, so
    /// there is never anything behind it to come into view — which is what capped
    /// the sliding version at a strength too small to see.
    let anchor: CGPoint
}

enum PhotoParallax {

    /// When splitting a photo is worth doing.
    ///
    /// Under the bottom of this the subject is a speck and moving it differently
    /// achieves nothing anyone would see. Over the top there is hardly any scene
    /// left for it to move against, so the effect stops reading as depth and
    /// starts reading as the whole picture wobbling.
    static let workableSubjectShare: ClosedRange<CGFloat> = 0.02...0.80

    /// One context for the process. Creating one per photo is the expensive way
    /// to do this, and `CIContext` is documented as safe to share.
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Split a photo, or nil if it has no liftable subject — which is most
    /// landscapes, and is not a failure.
    static func layers(for image: CGImage) -> PhotoLayers? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first,
              !observation.allInstances.isEmpty,
              let maskBuffer = try? observation.generateScaledMaskForImage(
                  forInstances: observation.allInstances, from: handler)
        else { return nil }

        let photo = CIImage(cgImage: image)
        var mask = CIImage(cvPixelBuffer: maskBuffer)
        // Documented as scaled to the image, but the arithmetic below is only
        // right if that holds, so it is made to hold rather than assumed.
        if mask.extent.width != photo.extent.width || mask.extent.height != photo.extent.height {
            guard mask.extent.width > 0, mask.extent.height > 0 else { return nil }
            mask = mask.transformed(by: CGAffineTransform(
                scaleX: photo.extent.width / mask.extent.width,
                y: photo.extent.height / mask.extent.height))
        }

        guard let share = averageBrightness(of: mask), workableSubjectShare.contains(share)
        else { return nil }

        let clear = CIImage(color: .clear).cropped(to: photo.extent)
        // The mask is grown slightly before it is used to cut the hole, so the
        // fill starts outside the subject's own edge pixels rather than at them.
        // Without this, the halo of the subject stays behind in the scene and
        // reappears as an outline the moment the subject moves off it.
        //
        // How much to grow by is not a matter of taste: the mask is only as
        // precise as the resolution it was computed at, which the unscaled
        // `instanceMask` states. Two of its pixels, in the photo's pixels.
        let maskWidth = CGFloat(CVPixelBufferGetWidth(observation.instanceMask))
        let edge = maskWidth > 0 ? 2 * photo.extent.width / maskWidth : 2
        let grown = mask.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: edge])

        guard let fill = sceneBehindSubject(photo: photo, hole: grown, share: share) else { return nil }
        let scene = fill.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: photo,
            kCIInputMaskImageKey: grown,
        ])
        // Cut with the *same* grown mask the hole was cut with, not the original.
        // Cutting the subject smaller than the patch behind it leaves a ring of
        // smear around it that never goes away, and on a photograph of a woman in
        // a green field it reads as a halo of light around her — which is what it
        // did before this line matched the one above. The subject carries a couple
        // of mask-pixels of real background with it instead, which travels with it
        // and reads as its edge.
        let subject = photo.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: clear,
            kCIInputMaskImageKey: grown,
        ])

        guard let anchor = contactPoint(of: grown),
              let sceneImage = context.createCGImage(scene, from: photo.extent),
              let subjectImage = context.createCGImage(subject, from: photo.extent)
        else { return nil }
        return PhotoLayers(scene: sceneImage, subject: subjectImage, subjectShare: share,
                           anchor: anchor)
    }

    /// The middle of the subject across, and the foot of it up.
    ///
    /// Measured on a small raster of the mask. Where the subject's foot is, is a
    /// property of its shape rather than of the photo's resolution, and reducing
    /// the mask first averages away the stray pixel that would otherwise decide
    /// the answer on its own.
    private static func contactPoint(of mask: CIImage) -> CGPoint? {
        let extent = mask.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = min(1, contactRasterEdge / max(extent.width, extent.height))
        let small = mask.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let width = max(1, Int(small.extent.width))
        let height = max(1, Int(small.extent.height))
        var pixels = [Float](repeating: 0, count: width * height * 4)
        context.render(small, toBitmap: &pixels, rowBytes: width * 16,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       format: .RGBAf, colorSpace: nil)

        var mass = 0.0
        var weightedX = 0.0
        var lowest: Int?
        for row in 0..<height {
            for column in 0..<width {
                let value = Double(pixels[(row * width + column) * 4])
                guard value.isFinite, value > 0 else { continue }
                mass += value
                weightedX += value * (Double(column) + 0.5) / Double(width)
                // Half way up the mask's own ramp is the edge of the subject; it
                // is an alpha, so that is where inside stops being inside.
                if value >= 0.5 { lowest = max(lowest ?? row, row) }
            }
        }
        guard mass > 0, let bottomRow = lowest else { return nil }
        // Row 0 is the top of the photo — measured, in the same way and for the
        // same reason as in `PhotoFocus.centreOfAttention`.
        return CGPoint(x: weightedX / mass,
                       y: 1 - (Double(bottomRow) + 0.5) / Double(height))
    }

    /// The long edge, in pixels, the contact point is measured at.
    private static let contactRasterEdge: CGFloat = 192

    /// What to put where the subject was.
    ///
    /// The subject is cut out, leaving a transparent hole, and the result is
    /// blurred: a blur works on premultiplied colour, so the scenery around the
    /// hole bleeds into it, and undoing the premultiplication turns that back
    /// into colour. Far enough into a large hole the bleed runs out of alpha to
    /// divide by, so the whole thing sits on top of a heavily smeared copy of the
    /// photo, which has no holes in it and so always has something to say.
    ///
    /// Computed at a fraction of the photo's size. A fill defined as "no detail"
    /// does not need the photo's resolution, and the blur that produces it is the
    /// one expensive step here.
    private static func sceneBehindSubject(photo: CIImage, hole: CIImage,
                                          share: CGFloat) -> CIImage? {
        let extent = photo.extent
        // Enough reach to get from the edge of the subject to the middle of it,
        // taken as the radius of a disc of the same area — no bounding box
        // needed, and it scales with the subject rather than being picked.
        let reach = (share * extent.width * extent.height / .pi).squareRoot()
        // Work at the size where the fill's own smoothness, not the raster,
        // is the limit: a few hundred pixels across the frame.
        let working = min(1, fillWorkingWidth / max(extent.width, extent.height))
        let shrink = CGAffineTransform(scaleX: working, y: working)

        let smallPhoto = photo.transformed(by: shrink)
        let smallHole = hole.transformed(by: shrink)
        let clear = CIImage(color: .clear).cropped(to: smallPhoto.extent)
        let holed = clear.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: smallPhoto,
            kCIInputMaskImageKey: smallHole,
        ])
        let bled = holed.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: reach * working])
            .cropped(to: smallPhoto.extent)
            .unpremultiplyingAlpha()
        // The floor under the bleed: the photo reduced until nothing of the
        // subject survives as shape, only as colour.
        let floor = smallPhoto
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur",
                            parameters: [kCIInputRadiusKey: smallPhoto.extent.width / 8])
            .cropped(to: smallPhoto.extent)
        let filled = bled.composited(over: floor)
        // Back up to the photo's size, where it is composited into the scene.
        return filled.transformed(by: CGAffineTransform(scaleX: 1 / working, y: 1 / working))
    }

    /// The long edge, in pixels, the fill is computed at. See
    /// `sceneBehindSubject` for why this is small.
    private static let fillWorkingWidth: CGFloat = 320

    /// The mask's average value, which for a mask is the share of the frame it
    /// covers.
    private static func averageBrightness(of mask: CIImage) -> CGFloat? {
        let average = mask.applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: mask.extent),
        ])
        var pixel = [Float](repeating: 0, count: 4)
        context.render(average,
                       toBitmap: &pixel,
                       rowBytes: 16,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf,
                       colorSpace: nil)
        guard pixel[0].isFinite else { return nil }
        return CGFloat(pixel[0])
    }
}
