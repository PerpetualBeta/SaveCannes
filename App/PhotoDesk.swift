import AppKit
import Metal
import QuartzCore

// Photographs as paper prints, thrown onto a desk — and then, against every property
// of paper, the pictures inside them are alive.
//
// A folder of stills is not a slideshow here. The collection is the film: prints land
// one after another on top of whatever is already on the desk, and the paper, once it
// has landed, never moves again. The picture inside its window does — it hunts in and
// out of focus, it carries the shake of a hand that is not there, and it comes apart
// into blocks and static and back again.
//
// There are no settings for any of it. It is what a folder of images does, found
// rather than configured.
//
// Four things make it cheap enough to leave running for hours:
//
//   only the newest print is alive     everything under it is buried by something that
//                                     dominates the frame, so it is not animated
//   a print that has stopped is        it stops being a print, and the desk costs one
//   painted into the desk and freed    texture however many have been and gone
//   the focus stack                    defocus is low frequency, so a handful of
//                                     pre-blurred levels made once, at a fraction of
//                                     the print's resolution, is enough — the hunt is
//                                     then a lerp between two of them
//   the subject mask                   a print with someone in it holds them sharp and
//                                     lets only the world behind them drift

// MARK: - The look, named in the units of the things themselves

/// Settled 14 August 2026. Deliberately constants: this is a bonus behaviour for a
/// folder of images, not a panel of sliders.
enum DeskLook {
    /// How much of the frame a print takes, measured across its *rotated* bounding box
    /// so it dominates whatever it lands on without ever running off the edge. What is
    /// left over becomes the room it has to scatter in — so a print that fills the
    /// frame barely moves and a narrow one wanders.
    static let printCoverage: Float = 0.86
    /// The white border, against the print's short side. A 4 by 6 machine print carries
    /// about 4mm on a 102mm side.
    static let borderFraction: Float = 0.04
    /// How far off square a print can land.
    static let maxRotationDegrees: Float = 13
    /// How long a print takes to fall.
    static let fallSeconds: Double = 0.62

    /// Focus does not drift, it hunts: it sits somewhere, then racks quickly to
    /// somewhere else and sits again, the way a lens does when it cannot make up its
    /// mind. How long it holds, and how fast the rack is.
    static let focusHoldSeconds: Double = 1.4
    static let focusRackSeconds: Double = 0.2
    /// The widest the lens ever opens while hunting.
    static let widestAperture: Float = 1.4

    /// Shake is a hand being knocked, not a hand swaying: kicks arrive sporadically and
    /// each one is a damped ring, so the onset is sudden and it settles fast.
    static let shakeKicksPerSecond: Float = 1.7
    static let shakeSettleSeconds: Float = 0.38
    static let shakeRingHertz: Float = 8.5
    /// Of the image window, at full force. The summed total is held to this.
    static let shakeAmplitude: Float = 0.013
    static let shakeDegrees: Float = 0.5

    /// Glitches arrive as bursts, never as a constant state — a print that is always
    /// broken reads as broken; one that stumbles occasionally reads as alive.
    static let burstsPerMinute: Float = 34
    static let burstSeconds: Double = 0.22
    /// Static's share of the bursts. It is the effect that reads best, and with only
    /// the top print alive there is no second print glitching elsewhere to cover for
    /// it, so it takes the largest share.
    static let staticShare: Float = 0.5
    /// Static runs longer than the others. A flicker of it is nothing; held for the
    /// better part of a second it reads as a picture struggling, which is the point.
    static let staticBurstSeconds: Double = 0.75
    static let staticAmount: Float = 0.30
    /// The standard JPEG quality number at the peak of a burst. 1 is ruin.
    static let jpegQuality: Float = 7
    /// Image pixels across a block, at full strength.
    static let pixelBlock: Float = 14

    /// Where the light is, as a fraction of the view. The desk is lit from here and the
    /// shadows are derived from it, so the two cannot disagree.
    static let lamp = SIMD2<Float>(0.32, 0.12)
    /// How far a landed print's shadow reaches past its paper, and how much looser it
    /// is while the print is still in the air.
    static let shadowSpreadLanded: Float = 0.035
    static let shadowSpreadFalling: Float = 0.10
    /// A falling print's shadow offset, against the view's short side, closing to
    /// nothing as it lands — paper is a quarter of a millimetre thick, so a print lying
    /// flat throws no offset at all.
    static let shadowOffsetFalling: Float = 0.045
    /// A print in the air is nearer, so slightly bigger.
    static let liftFalling: Float = 1.06

    /// How much larger than its window the image is drawn, so the shake can never pull
    /// an edge of the paper into view. Derived from the limits above, and constant, so
    /// it cannot read as a zoom of its own.
    static var overscan: Float {
        let sway = shakeDegrees * .pi / 180
        let corner = abs(sin(sway)) + abs(cos(sway)) - 1
        return 1 + 2 * shakeAmplitude + 2 * max(0, corner) + 0.004
    }
}

/// The reference lens the blur is anchored to.
///
/// The thin-lens circle of confusion is `c = (f²/N)·|D−S|/(D·(S−f))`, which with
/// distance written as disparity `u = 1/D` collapses to `c ≈ (f²/N)·|u − u_focus|` —
/// **linear in the depth map's own units**, so a relative depth map drives it directly
/// with no fitting and no scale to recover. The one number left over is the aperture,
/// and it is anchored to a lens anyone can picture: a 50mm at 2m on full frame throws a
/// background at infinity to `f²/(N·S·h)` of the frame height.
enum Lens {
    static let focalLength: Float = 50        // mm
    static let subjectDistance: Float = 2000  // mm
    static let sensorHeight: Float = 24       // mm, full frame

    static func maximumBlurFraction(aperture: Float) -> Float {
        focalLength * focalLength / (aperture * subjectDistance * sensorHeight)
    }

    /// The blur circle in gather pixels — which is to say the sample budget. Holding it
    /// constant and deriving the gather *resolution* from the aperture is what makes the
    /// cost of a gather independent of how big the print is. Twelve forms the disc from
    /// some four hundred and fifty taps.
    static let gatherRadius = 12
    /// Levels in a print's focus stack, evenly spaced *in blur*, so the hunt maps onto
    /// the stack linearly and a lerp between neighbours is a real focus drift.
    static let focusLevels = 4
}

// MARK: - Deterministic randomness

/// So a desk is the same desk every time the same seed comes round, and so none of the
/// motion needs any state carried between frames.
private func deskHash(_ value: UInt32) -> UInt32 {
    var x = value &+ 0x9E37_79B9
    x = (x ^ (x >> 16)) &* 0x85EB_CA6B
    x = (x ^ (x >> 13)) &* 0xC2B2_AE35
    return x ^ (x >> 16)
}

private func deskRandom(_ seed: UInt32, _ index: UInt32) -> Float {
    Float(deskHash(seed &* 0x0001_0001 &+ index) >> 8) / Float(1 << 24)
}

// MARK: - What moves in a print

/// Everything that moves, as a function of the clock and a seed. No textures, no GPU,
/// no state between frames — which is what lets a print's motion be frozen simply by
/// reading it at an earlier moment.
struct DeskLife {
    let seed: UInt32

    /// A hand being knocked. Kicks land on a coarse grid and most, but not all, of the
    /// slots fire; each kick is a damped oscillation, which is what a struck spring does
    /// and what makes the onset sudden and the recovery quick. Summing the last few
    /// makes the whole thing evaluable from the clock alone.
    ///
    /// Measured: quiet for 45% of the time, with jolts of 61% of full amplitude inside a
    /// single frame at 60Hz.
    func shake(at time: Double) -> (offset: SIMD2<Float>, angle: Float) {
        let slot = 1.0 / Double(max(DeskLook.shakeKicksPerSecond, 0.001))
        var offset = SIMD2<Float>(0, 0)
        var angle: Float = 0
        let current = Int(floor(time / slot))
        // Four slots back is far more than enough: by then the decay has taken it.
        for back in 0..<4 {
            let index = current - back
            let key = UInt32(truncatingIfNeeded: index)
            guard deskRandom(seed &+ 4241, key) < 0.78 else { continue }
            let began = (Double(index) + Double(deskRandom(seed &+ 5171, key))) * slot
            let since = Float(time - began)
            guard since >= 0 else { continue }
            let decay = exp(-since / max(DeskLook.shakeSettleSeconds, 0.001))
            guard decay > 0.01 else { continue }
            let ring = sin(since * 2 * .pi * DeskLook.shakeRingHertz)
            let heading = deskRandom(seed &+ 6301, key) * 2 * .pi
            let force = (0.35 + 0.65 * deskRandom(seed &+ 7013, key)) * decay * ring
            offset += SIMD2(cos(heading), sin(heading)) * force
            angle += force * (deskRandom(seed &+ 8117, key) - 0.5) * 2
        }
        // Kicks can land on top of each other, so the total is held to the stated
        // amplitude — otherwise the overscan that keeps the paper from showing through
        // would have to be sized for a coincidence.
        let reach = (offset.x * offset.x + offset.y * offset.y).squareRoot()
        if reach > 1 { offset /= reach }
        return (offset * DeskLook.shakeAmplitude,
                max(-1, min(1, angle)) * DeskLook.shakeDegrees * .pi / 180)
    }

    /// Where the focus is: held, then racked quickly somewhere else.
    ///
    /// Measured: 8 racks in 12 seconds, each completing in a fifth of a second, with
    /// flat holds between.
    func focus(at time: Double) -> Float {
        let hold = max(DeskLook.focusHoldSeconds, 0.05)
        let index = Int(floor(time / hold))
        func target(_ step: Int) -> Float {
            deskRandom(seed &+ 9241, UInt32(truncatingIfNeeded: step))
        }
        let from = target(index - 1), to = target(index)
        let into = time - Double(index) * hold
        let rack = min(DeskLook.focusRackSeconds, hold)
        let through = Float(min(1, max(0, into / rack)))
        return from + (to - from) * (through * through * (3 - 2 * through))
    }

    /// Glitch bursts. Each slot of time either holds one or does not; inside a burst the
    /// envelope snaps up and decays, which is what reads as a stumble.
    ///
    /// Measured on the live print: static on screen 17.5% of the time and past half
    /// strength 6.6%; pixels 2.3%; jpeg 1.8%.
    func burst(at time: Double) -> (strength: Float, kind: Int) {
        let period = 60.0 / Double(max(DeskLook.burstsPerMinute, 0.001))
        let slot = UInt32(truncatingIfNeeded: Int(floor(time / period)))
        guard deskRandom(seed &+ 977, slot) < 0.72 else { return (0, 0) }
        // Which kind comes first, because static runs longer than the other two.
        let draw = deskRandom(seed &+ 613, slot)
        let kind = draw < DeskLook.staticShare ? 1
            : draw < DeskLook.staticShare + (1 - DeskLook.staticShare) / 2 ? 0 : 2
        let length = min(kind == 1 ? DeskLook.staticBurstSeconds : DeskLook.burstSeconds, period)
        let start = Double(deskRandom(seed &+ 331, slot)) * (period - length)
        let into = time - floor(time / period) * period - start
        guard into >= 0, into < length else { return (0, 0) }
        let through = Float(into / length)
        let envelope = through < 0.18 ? through / 0.18 : pow(1 - (through - 0.18) / 0.82, 1.6)
        return (max(0, envelope), kind)
    }
}

// MARK: - Uniforms, matched to the shader

struct CardUniforms {
    var centre = SIMD2<Float>(0, 0)
    var halfSize = SIMD2<Float>(0, 0)
    var viewportHalf = SIMD2<Float>(1, 1)
    var apertureHalf = SIMD2<Float>(1, 1)
    var cosR: Float = 1
    var sinR: Float = 0
    var spread: Float = 0.05
    var landing: Float = 1
    var shadowOffset = SIMD2<Float>(0, 0)
    var lamp = SIMD2<Float>(0, 0)
}

struct DeskUniforms {
    var size = SIMD2<Float>(1, 1)
    var pad0: Float = 0
    var pad1: Float = 0
}

struct ComposeUniforms {
    var imageSize = SIMD2<Float>(1, 1)
    var shake = SIMD2<Float>(0, 0)
    var overscan: Float = 1
    var shakeCos: Float = 1
    var shakeSin: Float = 0
    var focus: Float = 0.5
    var maxCoc: Float = 0
    var gatherScale: Float = 1
    var level: Float = 0
    var pixelBlock: Float = 0
    var staticAmount: Float = 0
    var seed: Float = 0
    var time: Float = 0
    var maskStrength: Float = 0
    var saturation: Float = 1
    var pad0: Float = 0
    var pad1: Float = 0
    var pad2: Float = 0
}

struct JpegUniforms {
    var quality: Float = 50
    var chroma: Float = 1
    var pad0: Float = 0
    var pad1: Float = 0
}

struct GatherUniforms {
    var focus: Float = 0.5
    var maxCoc: Float = 0
    var radius: Int32 = 0
    var slice: Int32 = 0
}

// MARK: - A print

/// One photograph on the desk.
final class PhotoPrint {

    let seed: UInt32
    let life: DeskLife
    let hasSubject: Bool
    let hasDepth: Bool
    let focusDisparity: Float
    var droppedAt: Double = 0

    /// Where it came to rest, and how far off square. Centre is a fraction of the view.
    var centre = SIMD2<Float>(0.5, 0.5)
    var rotation: Float = 0
    /// The paper, in pixels — the image window is this less the border.
    var halfSize = SIMD2<Float>(100, 100)
    var apertureHalf = SIMD2<Float>(0.9, 0.9)
    /// Where it fell from.
    var entryCentre = SIMD2<Float>(0.5, -0.62)
    var entryRotation: Float = 0

    /// The living picture. The compose pass renders it as sRGB; the JPEG pass has to
    /// read the values as they are *stored*, because that is what an encoder sees — so
    /// the same memory is also viewed without the transfer function.
    let composed: MTLTexture
    let composedStored: MTLTexture
    let gatherScale: Float

    /// Everything only a *living* print needs. Once it is buried it stops animating and
    /// all of this is dead weight, so it goes.
    var sharp: MTLTexture?
    var depth: MTLTexture?
    var mask: MTLTexture?
    var stack: MTLTexture?
    /// A compute kernel cannot write to an sRGB texture, so the broken copy is stored
    /// plainly and viewed as sRGB when it goes onto the paper. Both are made when a
    /// glitch burst starts and handed back when it ends — they are the fattest things a
    /// print can carry, wanted a couple of per cent of the time.
    var glitchedStored: MTLTexture?
    var glitched: MTLTexture?
    var coefficients: MTLTexture?

    var showingGlitched = false
    /// Whether its picture has been composed even once. Painting a print into the desk
    /// before then would paint whatever its texture happened to contain.
    var composedOnce = false
    /// Set once it has been painted into the desk, after which it is not a print.
    var baked = false
    /// When something newer arrived. From then on its shake and its focus are read at
    /// this moment rather than the present one, so it stops moving — while its colour
    /// goes on draining until the new print is down.
    var supersededAt: Double?

    init(seed: UInt32, hasSubject: Bool, hasDepth: Bool, focusDisparity: Float,
                     composed: MTLTexture, composedStored: MTLTexture,
                     sharp: MTLTexture, depth: MTLTexture, mask: MTLTexture,
                     stack: MTLTexture, gatherScale: Float) {
        self.seed = seed
        self.life = DeskLife(seed: seed)
        self.hasSubject = hasSubject
        self.hasDepth = hasDepth
        self.focusDisparity = focusDisparity
        self.composed = composed
        self.composedStored = composedStored
        self.sharp = sharp
        self.depth = depth
        self.mask = mask
        self.stack = stack
        self.gatherScale = gatherScale
    }

    /// 0 while falling, 1 once it is down.
    func landing(at time: Double, instantly: Bool) -> Float {
        guard !instantly else { return 1 }
        let progress = min(1, max(0, (time - droppedAt) / DeskLook.fallSeconds))
        // Eased out hard, so it drops and settles rather than gliding in.
        return Float(1 - pow(1 - progress, 3))
    }

    /// What a frozen print still costs: its composed picture, and nothing else.
    func settle() {
        sharp = nil; depth = nil; mask = nil; stack = nil
        glitchedStored = nil; glitched = nil; coefficients = nil
        showingGlitched = false
    }
}

/// Where and how big a print is. Solved for rather than chosen — see `place`.
struct PrintPlacement: Sendable {
    var halfSize = SIMD2<Float>(100, 100)
    var apertureHalf = SIMD2<Float>(0.9, 0.9)
    var centre = SIMD2<Float>(0.5, 0.5)
    var rotation: Float = 0
    var entryCentre = SIMD2<Float>(0.5, -0.62)
    var entryRotation: Float = 0
    /// The longest edge the print will ever be shown at, so nothing decodes or holds
    /// more pixels than it can display.
    var longSidePixels = 512
}

// MARK: - The shared GPU

/// One device, one queue, one set of pipelines for the whole app. A print's textures are
/// its own, but nothing else needs to be built twice — and on a two-display setup the
/// shaders would otherwise be compiled twice for no reason.
final class DeskGPU {

    static let shared: DeskGPU? = DeskGPU()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let deskPipeline: MTLRenderPipelineState
    let canvasPipeline: MTLRenderPipelineState
    let shadowPipeline: MTLRenderPipelineState
    let cardPipeline: MTLRenderPipelineState
    let bakeShadowPipeline: MTLRenderPipelineState
    let bakeCardPipeline: MTLRenderPipelineState
    let composePipeline: MTLRenderPipelineState
    let downsamplePipeline: MTLRenderPipelineState
    let defocusPipeline: MTLComputePipelineState
    let jpegForwardPipeline: MTLComputePipelineState
    let jpegInversePipeline: MTLComputePipelineState

    /// What a print's picture and the desk are stored as.
    static let colourFormat = MTLPixelFormat.rgba8Unorm_srgb

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            scLog("no Metal device — a folder of photographs cannot be shown")
            return nil
        }
        self.device = device
        self.queue = queue

        // Compiled at runtime from source rather than built into a .metallib: it costs
        // milliseconds once, and it keeps the build a single swiftc invocation with no
        // Metal toolchain to install.
        let source = deskShaderSource.replacingOccurrences(
            of: "%LEVELS%", with: "\(Lens.focusLevels)")
        guard let library = try? device.makeLibrary(source: source, options: nil) else {
            scLog("desk shaders would not compile — a folder of photographs cannot be shown")
            return nil
        }

        func render(_ vertex: String, _ fragment: String, _ format: MTLPixelFormat,
                    blending: Bool) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = format
            if blending {
                let attachment = descriptor.colorAttachments[0]!
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .sourceAlpha
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        let colour = Self.colourFormat
        guard let desk = render("fullQuad", "deskFragment", colour, blending: false),
              let canvas = render("fullQuad", "canvasFragment", colour, blending: false),
              let shadow = render("shadowVertex", "shadowFragment", colour, blending: true),
              let card = render("cardVertex", "cardFragment", colour, blending: true),
              let bakeShadow = render("shadowVertex", "shadowFragment", colour, blending: true),
              let bakeCard = render("cardVertex", "cardFragment", colour, blending: true),
              let compose = render("fullQuad", "composeFragment", colour, blending: false),
              let downsample = render("fullQuad", "downsampleFragment", .rgba16Float, blending: false),
              let defocusFunction = library.makeFunction(name: "defocus"),
              let forwardFunction = library.makeFunction(name: "jpegForward"),
              let inverseFunction = library.makeFunction(name: "jpegInverse"),
              let defocus = try? device.makeComputePipelineState(function: defocusFunction),
              let forward = try? device.makeComputePipelineState(function: forwardFunction),
              let inverse = try? device.makeComputePipelineState(function: inverseFunction)
        else {
            scLog("desk pipelines would not build — a folder of photographs cannot be shown")
            return nil
        }
        deskPipeline = desk
        canvasPipeline = canvas
        shadowPipeline = shadow
        cardPipeline = card
        bakeShadowPipeline = bakeShadow
        bakeCardPipeline = bakeCard
        composePipeline = compose
        downsamplePipeline = downsample
        defocusPipeline = defocus
        jpegForwardPipeline = forward
        jpegInversePipeline = inverse
    }

    // MARK: geometry

    /// Where and how big a print is.
    ///
    /// A print has to dominate whatever it lands on, so it is grown until its *rotated*
    /// bounding box fills `printCoverage` of the frame — which is the largest it can be
    /// while still fitting at whatever angle it came down at, since a rotated rectangle
    /// spans `w·|cosθ| + h·|sinθ|` by `w·|sinθ| + h·|cosθ|`. Whatever slack is left over
    /// is exactly the room it has to scatter in. Nothing here is chosen but the share.
    static func place(imageSize: CGSize, seed: UInt32, in size: CGSize) -> PrintPlacement {
        var placement = PrintPlacement()
        let width = Float(size.width), height = Float(size.height)
        guard width > 0, height > 0, imageSize.width > 0, imageSize.height > 0 else {
            return placement
        }
        placement.rotation =
            (deskRandom(seed, 5) - 0.5) * 2 * DeskLook.maxRotationDegrees * .pi / 180

        let aspect = Float(imageSize.width / imageSize.height)
        let unit = aspect >= 1 ? SIMD2<Float>(1, 1 / aspect) : SIMD2<Float>(aspect, 1)
        let turn = abs(cos(placement.rotation)), lean = abs(sin(placement.rotation))
        let box = SIMD2(unit.x * turn + unit.y * lean, unit.x * lean + unit.y * turn)
        let scale = min(width * DeskLook.printCoverage / box.x,
                        height * DeskLook.printCoverage / box.y)
        let paper = unit * scale
        placement.halfSize = paper / 2
        placement.longSidePixels = max(256, Int(max(paper.x, paper.y).rounded()))

        // The white border is a fraction of the print's short side, so it is even.
        let border = DeskLook.borderFraction * min(paper.x, paper.y)
        placement.apertureHalf = SIMD2(max(0.01, (paper.x / 2 - border) / (paper.x / 2)),
                                       max(0.01, (paper.y / 2 - border) / (paper.y / 2)))

        let slack = SIMD2(max(0, width - box.x * scale) / width,
                          max(0, height - box.y * scale) / height)
        placement.centre = SIMD2(0.5 + (deskRandom(seed, 20) - 0.5) * slack.x,
                                 0.5 + (deskRandom(seed, 21) - 0.5) * slack.y)
        // In from above, off to one side, turning more than it will end up.
        placement.entryCentre = SIMD2(placement.centre.x + (deskRandom(seed, 6) - 0.5) * 0.3,
                                      -0.62)
        placement.entryRotation = placement.rotation + (deskRandom(seed, 7) - 0.5) * 1.4
        return placement
    }

    // MARK: textures

    private func picture(from image: CGImage, longSide: Int) -> MTLTexture? {
        let scale = CGFloat(longSide) / CGFloat(max(image.width, image.height))
        let width = max(8, Int((CGFloat(image.width) * min(1, scale)).rounded()))
        let height = max(8, Int((CGFloat(image.height) * min(1, scale)).rounded()))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &bytes, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.colourFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: bytes, bytesPerRow: width * 4)
        return texture
    }

    /// Coverage at a byte a pixel: a mask is a fraction between nought and one, and
    /// thirty-two bits of it is thirty-two bits wasted.
    private func coverage(_ values: [Float], _ width: Int, _ height: Int) -> MTLTexture? {
        guard width > 0, height > 0, values.count >= width * height else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            bytes[index] = UInt8(max(0, min(255, values[index] * 255)))
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: bytes, bytesPerRow: width)
        return texture
    }

    private func field(_ values: [Float], _ width: Int, _ height: Int) -> MTLTexture? {
        guard width > 0, height > 0, values.count >= width * height else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        values.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: base, bytesPerRow: width * 4)
        }
        return texture
    }

    func target(_ width: Int, _ height: Int, _ format: MTLPixelFormat,
                            compute: Bool = false, viewable: Bool = false) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: max(1, width), height: max(1, height), mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        if compute { descriptor.usage.insert(.shaderWrite) }
        if viewable { descriptor.usage.insert(.pixelFormatView) }
        return device.makeTexture(descriptor: descriptor)
    }

    /// Everything a print needs, built once as it is dropped — including its focus
    /// stack, which is why the hunt costs nothing per frame afterwards.
    ///
    /// Safe to call away from the main thread: it touches textures and a command queue
    /// and nothing else.
    func makePrint(image: CGImage, analysis: PhotoAnalysis, seed: UInt32,
                   placement: PrintPlacement) -> PhotoPrint? {
        guard let sharp = picture(from: image, longSide: placement.longSidePixels) else {
            return nil
        }
        // With no depth there is nothing to hunt through, so a flat field stands in and
        // the focus is simply never moved off it.
        let depthValues = analysis.hasDepth ? analysis.disparity : [Float](repeating: 0.5, count: 4)
        let depthWidth = analysis.hasDepth ? analysis.disparityWidth : 2
        let depthHeight = analysis.hasDepth ? analysis.disparityHeight : 2
        guard let depth = field(depthValues, depthWidth, depthHeight),
              let mask = coverage(analysis.mask, analysis.maskWidth, analysis.maskHeight)
        else { return nil }

        // The gather runs where the blur circle is about two radii across, which is what
        // keeps its cost the same whatever size the print is.
        let widest = Lens.maximumBlurFraction(aperture: DeskLook.widestAperture)
        let wantedRows = max(64, Int((Float(2 * Lens.gatherRadius) / widest).rounded()))
        let divisor = max(1, Int((Float(sharp.height) / Float(wantedRows)).rounded()))
        let gatherWidth = max(8, sharp.width / divisor)
        let gatherRows = max(8, sharp.height / divisor)

        let stackDescriptor = MTLTextureDescriptor()
        stackDescriptor.textureType = .type2DArray
        stackDescriptor.pixelFormat = .rgba16Float
        stackDescriptor.width = gatherWidth
        stackDescriptor.height = gatherRows
        stackDescriptor.arrayLength = Lens.focusLevels
        stackDescriptor.usage = [.shaderRead, .shaderWrite]

        guard let stack = device.makeTexture(descriptor: stackDescriptor),
              let small = target(gatherWidth, gatherRows, .rgba16Float, compute: true),
              let composed = target(sharp.width, sharp.height, Self.colourFormat, viewable: true),
              let composedStored = composed.makeTextureView(pixelFormat: .rgba8Unorm),
              let buffer = queue.makeCommandBuffer()
        else { return nil }

        let shrink = MTLRenderPassDescriptor()
        shrink.colorAttachments[0].texture = small
        shrink.colorAttachments[0].loadAction = .dontCare
        shrink.colorAttachments[0].storeAction = .store
        if let encoder = buffer.makeRenderCommandEncoder(descriptor: shrink) {
            encoder.setRenderPipelineState(downsamplePipeline)
            encoder.setFragmentTexture(sharp, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }

        for level in 0..<Lens.focusLevels {
            let fraction = Float(level + 1) / Float(Lens.focusLevels)
            var gather = GatherUniforms()
            gather.focus = analysis.focusDisparity
            gather.maxCoc = widest * fraction * Float(gatherRows)
            gather.radius = Int32(ceil(gather.maxCoc * 0.5))
            gather.slice = Int32(level)
            guard let compute = buffer.makeComputeCommandEncoder() else { continue }
            compute.setComputePipelineState(defocusPipeline)
            compute.setTexture(small, index: 0)
            compute.setTexture(depth, index: 1)
            compute.setTexture(mask, index: 2)
            compute.setTexture(stack, index: 3)
            compute.setBytes(&gather, length: MemoryLayout<GatherUniforms>.stride, index: 0)
            compute.dispatchThreadgroups(
                MTLSize(width: (gatherWidth + 15) / 16, height: (gatherRows + 15) / 16, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            compute.endEncoding()
        }
        buffer.commit()
        buffer.waitUntilCompleted()

        let print = PhotoPrint(seed: seed, hasSubject: analysis.hasSubject,
                               hasDepth: analysis.hasDepth,
                               focusDisparity: analysis.focusDisparity,
                               composed: composed, composedStored: composedStored,
                               sharp: sharp, depth: depth, mask: mask, stack: stack,
                               gatherScale: Float(sharp.height) / Float(gatherRows))
        print.halfSize = placement.halfSize
        print.apertureHalf = placement.apertureHalf
        print.centre = placement.centre
        print.rotation = placement.rotation
        print.entryCentre = placement.entryCentre
        print.entryRotation = placement.entryRotation
        return print
    }

    func openGlitchBuffers(_ print: PhotoPrint) -> Bool {
        if print.coefficients != nil, print.glitchedStored != nil, print.glitched != nil {
            return true
        }
        guard let coefficients = target(print.composed.width, print.composed.height,
                                        .rgba16Float, compute: true),
              let stored = target(print.composed.width, print.composed.height,
                                  .rgba8Unorm, compute: true, viewable: true),
              let view = stored.makeTextureView(pixelFormat: Self.colourFormat)
        else { return false }
        print.coefficients = coefficients
        print.glitchedStored = stored
        print.glitched = view
        return true
    }

    func closeGlitchBuffers(_ print: PhotoPrint) {
        print.coefficients = nil
        print.glitchedStored = nil
        print.glitched = nil
    }

    func commandBuffer() -> MTLCommandBuffer? { queue.makeCommandBuffer() }
}
