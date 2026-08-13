import CoreGraphics
import CoreImage
import CoreVideo
import Vision

/// A photo's subject, lifted off it so the two can be moved at different rates.
///
/// It is worth being plain about what this is and isn't. A true 2.5D move needs a
/// depth value per pixel. macOS hands one over only for photos that were taken
/// with one — an iPhone portrait carries a disparity map in its file — and Vision
/// has no request that estimates depth from an ordinary photograph. What it does
/// have is subject lifting: the same machinery as dragging a cut-out out of a
/// photo in Preview. That gives two planes rather than a continuum, which is
/// enough for the thing that reads as depth — the subject coming towards you
/// faster than the scene it stands in.
///
/// Growing the subject about its contact point covers most of the shape it was
/// cut from, but not all of it, and the exception is worth stating because it
/// decides the design. Growing moves a point away from the anchor, so a hand at
/// the end of an outstretched arm ends up further out — and the place it came
/// from is only covered if the point a sixth of the way back towards the feet is
/// also part of the subject. For a hand held away from the body it isn't; it is
/// beside the waist, in the background. So the original arm stays visible next to
/// the grown one, and a woman crossing a road has four of them.
///
/// The scene therefore does need the subject taken out of it. What it must not do
/// is take it out all the way to the edge: the mask has a soft edge, and a
/// half-transparent pixel of subject sitting over invented scenery is a blurred
/// halo all the way round. So the patch stops short of the edge by the width of
/// that soft edge, and the last couple of pixels of the scene are the photo's own.
/// The subject's soft edge lands on the pixels it was made of, and what is left
/// exposed beside a grown arm is a hairline of the original rather than the arm.
struct PhotoLayers: @unchecked Sendable {
    /// The photo with the subject taken out of it, stopping short of the subject's
    /// own edge. What is behind the subject when it grows past where it was.
    let scene: CGImage
    /// The subject alone, everything else transparent. Same size as the photo, so
    /// it lines up with it without any arithmetic.
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
    /// does. It also means the subject contains the shape it was cut from at every
    /// point in the move, which is what makes the patch unnecessary.
    let anchor: CGPoint
}

enum PhotoParallax {

    /// When lifting a subject is worth doing.
    ///
    /// Under the bottom of this the subject is a speck and moving it differently
    /// achieves nothing anyone would see. Over the top there is hardly any scene
    /// left for it to move against, so the effect stops reading as depth and
    /// starts reading as the whole picture wobbling.
    static let workableSubjectShare: ClosedRange<CGFloat> = 0.02...0.80

    /// One context for the process. Creating one per photo is the expensive way to
    /// do this, and `CIContext` is documented as safe to share.
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Lift a photo's subject, or nil if it hasn't got one — which is most
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
        // Documented as scaled to the image, but the arithmetic here is only right
        // if that holds, so it is made to hold rather than assumed.
        if mask.extent.width != photo.extent.width || mask.extent.height != photo.extent.height {
            guard mask.extent.width > 0, mask.extent.height > 0 else { return nil }
            mask = mask.transformed(by: CGAffineTransform(
                scaleX: photo.extent.width / mask.extent.width,
                y: photo.extent.height / mask.extent.height))
        }

        guard let share = averageBrightness(of: mask), workableSubjectShare.contains(share),
              let anchor = contactPoint(of: mask)
        else { return nil }

        // Three masks, because the three jobs want different edges, and using one
        // for all of them is what produced first a halo and then four arms.
        //
        // How far apart they are is not a matter of taste: the mask is only as
        // precise as the resolution it was computed at, which the unscaled
        // `instanceMask` states, and its soft edge is about two of those pixels
        // wide once scaled up to the photo. That is the distance.
        let maskWidth = CGFloat(CVPixelBufferGetWidth(observation.instanceMask))
        let ramp = maskWidth > 0 ? 2 * photo.extent.width / maskWidth : 2
        // Grown, to work out what the scenery behind the subject looks like: the
        // bleed should pull in scenery, not the subject's own edge colours.
        let outside = mask.applyingFilter("CIMorphologyMaximum",
                                         parameters: [kCIInputRadiusKey: ramp])
        // Shrunk, to decide where that goes: stopping short of the edge is what
        // keeps the subject's soft pixels off it.
        let inside = mask.applyingFilter("CIMorphologyMinimum",
                                        parameters: [kCIInputRadiusKey: ramp])

        guard let fill = sceneBehindSubject(photo: photo, hole: outside, share: share)
        else { return nil }
        let scene = fill.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: photo,
            kCIInputMaskImageKey: inside,
        ])
        // And the mask exactly as Vision drew it for the subject itself.
        let clear = CIImage(color: .clear).cropped(to: photo.extent)
        let subject = photo.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: clear,
            kCIInputMaskImageKey: mask,
        ])

        guard let sceneImage = context.createCGImage(scene, from: photo.extent),
              let subjectImage = context.createCGImage(subject, from: photo.extent)
        else { return nil }
        return PhotoLayers(scene: sceneImage, subject: subjectImage,
                           subjectShare: share, anchor: anchor)
    }

    /// What to put where the subject was.
    ///
    /// The subject is cut out, leaving a transparent hole, and the result is
    /// blurred: a blur works on premultiplied colour, so the scenery around the
    /// hole bleeds into it, and undoing the premultiplication turns that back into
    /// colour. Far enough into a large hole the bleed runs out of alpha to divide
    /// by, so the whole thing sits on top of a heavily smeared copy of the photo,
    /// which has no holes in it and so always has something to say.
    ///
    /// Computed at a fraction of the photo's size. A fill defined as "no detail"
    /// does not need the photo's resolution, and the blur that produces it is the
    /// one expensive step here.
    private static func sceneBehindSubject(photo: CIImage, hole: CIImage,
                                          share: CGFloat) -> CIImage? {
        let extent = photo.extent
        // Enough reach to get from the edge of the subject to the middle of it,
        // taken as the radius of a disc of the same area — no bounding box needed,
        // and it scales with the subject rather than being picked.
        let reach = (share * extent.width * extent.height / .pi).squareRoot()
        let working = min(1, fillWorkingEdge / max(extent.width, extent.height))
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
        // The floor under the bleed: the photo reduced until nothing of the subject
        // survives as shape, only as colour.
        let floor = smallPhoto
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur",
                            parameters: [kCIInputRadiusKey: smallPhoto.extent.width / 8])
            .cropped(to: smallPhoto.extent)
        return bled.composited(over: floor)
            .transformed(by: CGAffineTransform(scaleX: 1 / working, y: 1 / working))
    }

    /// The long edge, in pixels, the fill is computed at. See `sceneBehindSubject`
    /// for why this is small.
    private static let fillWorkingEdge: CGFloat = 320

    /// The middle of the subject across, and the foot of it up.
    ///
    /// Measured on a small raster of the mask. Where a subject's foot is, is a
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
                // Half way up the mask's own ramp is the edge of the subject; it is
                // an alpha, so that is where inside stops being inside.
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
