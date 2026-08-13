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
/// Nothing is invented here, and that is the whole design. The subject grows
/// about the point where it meets the world, so it always covers the shape it was
/// cut from: the photo behind it never needs a patch, because no part of the hole
/// is ever on screen. An earlier version filled that hole with a smeared copy of
/// the photo, and every soft pixel at the edge of the subject then blended with
/// the smear instead of with the scenery — which is a blurred halo round the
/// subject, put there by the fix for a problem that doesn't exist.
struct PhotoLayers: @unchecked Sendable {
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

        // The mask exactly as Vision drew it, soft edge and all. Neither grown nor
        // shrunk: the subject is going to be drawn over the photo it came out of,
        // so a half-transparent pixel at its edge lands on the pixel it was
        // half-made of, and the join cannot be seen.
        let clear = CIImage(color: .clear).cropped(to: photo.extent)
        let subject = photo.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: clear,
            kCIInputMaskImageKey: mask,
        ])
        guard let subjectImage = context.createCGImage(subject, from: photo.extent) else { return nil }
        return PhotoLayers(subject: subjectImage, subjectShare: share, anchor: anchor)
    }

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
