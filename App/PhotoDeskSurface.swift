import AppKit
import Metal
import QuartzCore

/// The desk itself: a wooden surface, a pile of prints already lying on it, and the one
/// print that is still alive.
///
/// The pile is not a list of prints. A print that has stopped moving is painted into a
/// single desk-sized canvas and let go of — it stops being a print — so the desk costs
/// one texture however many photographs have been and gone, and nothing ever has to be
/// removed for being old. Measured at 0.9–1.2ms a frame and 34MB, flat across three
/// hundred prints.
final class PhotoDesk {

    /// Where it draws. A layer rather than a view, so the stage can order it against the
    /// player's layer exactly as it ordered the still layer this replaced.
    let metalLayer = CAMetalLayer()
    private let gpu: DeskGPU?

    /// Only ever one or two: the newest print, and — while the newest is still in the
    /// air — the one it is burying.
    private var prints: [PhotoPrint] = []

    /// The desk and everything already lying on it.
    private var canvas: MTLTexture?
    private var canvasSize = CGSize.zero

    private var startedAt: Double = 0
    private var counter: UInt32 = 0

    /// With Reduce Motion asked for, prints still land and still pile up — the
    /// collection is the point — but nothing shakes, hunts focus or comes apart, and
    /// they arrive without the fall.
    private(set) var reduceMotion = false

    init() {
        gpu = DeskGPU.shared
        metalLayer.device = gpu?.device
        metalLayer.pixelFormat = DeskGPU.colourFormat
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = NSColor.black.cgColor
    }

    /// Whether a desk can be shown at all. Without Metal, or without the shaders, the
    /// stage falls back to skipping photographs rather than showing nothing.
    var isUsable: Bool { gpu != nil }

    var isEmpty: Bool { prints.isEmpty && canvas == nil }

    /// A print's own clock. Shared by every print on the desk so their motion is out of
    /// step with each other only by their seeds, not by when they happened to arrive.
    private var now: Double { CACurrentMediaTime() - startedAt }

    // MARK: - Lifecycle

    func begin() {
        guard gpu != nil else { return }
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        startedAt = CACurrentMediaTime()
    }

    /// Clear the desk and give everything back. Called when a film comes up, so nothing
    /// is held for the hours a video plays.
    func end() {
        prints.removeAll()
        canvas = nil
        canvasSize = .zero
    }

    /// Put a print on the desk. Whatever was on top stops moving from this moment,
    /// though its colour goes on draining until the new one is down.
    func drop(_ print: PhotoPrint) {
        print.droppedAt = now
        prints.last?.supersededAt = now
        prints.append(print)
        counter &+= 1
    }

    /// A seed for the next print, so its scatter and its stumbles are its own.
    func nextSeed() -> UInt32 { deskSeed(counter &+ 1) }

    // MARK: - The frame

    /// One frame. Driven by the stage's display link — the desk has no clock of its own,
    /// so it cannot go on drawing after the stage has finished with it.
    func render(points: CGSize, scale: CGFloat) {
        guard let gpu = gpu, !prints.isEmpty || canvas != nil,
              points.width > 1, points.height > 1 else { return }
        let size = CGSize(width: max(1, (points.width * scale).rounded()),
                          height: max(1, (points.height * scale).rounded()))
        metalLayer.contentsScale = scale
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
        prepareCanvas(size, gpu: gpu)
        guard let canvas = canvas, let drawable = metalLayer.nextDrawable(),
              let buffer = gpu.commandBuffer()
        else { return }

        let time = now
        compose(into: buffer, gpu: gpu, time: time)
        bakeFinished(into: buffer, gpu: gpu, canvas: canvas, time: time, size: size)

        // The desk with the whole pile already on it, in one blit, and then only the
        // prints that are still moving.
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        if let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) {
            encoder.setRenderPipelineState(gpu.canvasPipeline)
            encoder.setFragmentTexture(canvas, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            for print in prints where !print.baked {
                draw(print, with: encoder, gpu: gpu,
                     shadow: gpu.shadowPipeline, paper: gpu.cardPipeline,
                     time: time, size: size)
            }
            encoder.endEncoding()
        }
        buffer.present(drawable)
        buffer.commit()
    }

    /// The bare desk, painted once. Everything that lands is painted on top of it and
    /// then forgotten, so this is never redone unless the view changes size — at which
    /// point whatever was lying on it is gone, which only a resize can cause and a
    /// screensaver never does.
    private func prepareCanvas(_ size: CGSize, gpu: DeskGPU) {
        if canvas != nil, canvasSize == size { return }
        canvasSize = size
        canvas = gpu.target(Int(size.width), Int(size.height), DeskGPU.colourFormat)
        guard let canvas = canvas, let buffer = gpu.commandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = canvas
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store
        if let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) {
            var desk = DeskUniforms()
            desk.size = SIMD2(Float(size.width), Float(size.height))
            encoder.setRenderPipelineState(gpu.deskPipeline)
            encoder.setFragmentBytes(&desk, length: MemoryLayout<DeskUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }
        buffer.commit()
    }

    /// Compose the living picture of each print that is still alive.
    ///
    /// The newest print is alive. The one under it stays alive — and in colour — until
    /// the new one has actually come down, because otherwise it would drain while the
    /// new one was still in the air, in full view.
    private func compose(into buffer: MTLCommandBuffer, gpu: DeskGPU, time: Double) {
        let last = prints.count - 1
        guard last >= 0 else { return }
        let newestLanding = prints[last].landing(at: time, instantly: reduceMotion)

        for (index, print) in prints.enumerated() {
            guard let sharp = print.sharp, let stack = print.stack,
                  let depth = print.depth, let mask = print.mask else { continue }
            let onTop = index == last || (index == last - 1 && newestLanding < 1)
            // A superseded print stops moving at the moment it was superseded, but goes
            // on losing its colour until the print above it is down.
            let held = print.supersededAt ?? time

            var compose = ComposeUniforms()
            compose.imageSize = SIMD2(Float(print.composed.width), Float(print.composed.height))
            let shake = reduceMotion
                ? (offset: SIMD2<Float>(0, 0), angle: Float(0))
                : print.life.shake(at: held)
            compose.shake = shake.offset
            compose.shakeCos = cos(shake.angle)
            compose.shakeSin = sin(shake.angle)
            compose.overscan = DeskLook.overscan

            // Without a depth map there is nothing to hunt through, so the focus is left
            // where it is and the picture simply stays sharp.
            let hunt = (reduceMotion || !print.hasDepth) ? 0 : print.life.focus(at: held)
            compose.focus = print.focusDisparity
            compose.maxCoc = Lens.maximumBlurFraction(aperture: DeskLook.widestAperture)
                * hunt * Float(stack.height)
            compose.gatherScale = print.gatherScale
            compose.level = hunt * Float(Lens.focusLevels) - 1
            compose.seed = Float(print.seed % 4096)
            compose.time = Float(time)
            // A print with nobody in it has nothing to pin, so the whole picture drifts
            // together. One with somebody in it holds them and lets the world behind
            // them go.
            compose.maskStrength = print.hasSubject ? 1 : 0
            // Its last frame is the one that takes the colour out of it.
            compose.saturation = onTop ? 1 : max(0, 1 - newestLanding)

            // A print being buried takes its last frame clean, so nothing is left frozen
            // mid-stumble for as long as it stays on the desk.
            let burst = (onTop && !reduceMotion) ? print.life.burst(at: held)
                                                 : (strength: Float(0), kind: 0)
            if burst.strength > 0 {
                if burst.kind == 0 { compose.pixelBlock = 1 + burst.strength * DeskLook.pixelBlock }
                if burst.kind == 1 { compose.staticAmount = burst.strength * DeskLook.staticAmount }
            }

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = print.composed
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { continue }
            encoder.setRenderPipelineState(gpu.composePipeline)
            encoder.setFragmentTexture(sharp, index: 0)
            encoder.setFragmentTexture(stack, index: 1)
            encoder.setFragmentTexture(depth, index: 2)
            encoder.setFragmentTexture(mask, index: 3)
            encoder.setFragmentBytes(&compose, length: MemoryLayout<ComposeUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            print.composedOnce = true

            print.showingGlitched = false
            let wantsJpeg = burst.kind == 2 && burst.strength > 0
            if !wantsJpeg { gpu.closeGlitchBuffers(print) }
            if wantsJpeg, gpu.openGlitchBuffers(print) {
                // Quality falls as the burst rises: 50 is respectable, 1 is ruin.
                var jpeg = JpegUniforms()
                jpeg.quality = max(1, 50 - burst.strength * (50 - DeskLook.jpegQuality))
                let groups = MTLSize(width: (print.composed.width + 7) / 8,
                                     height: (print.composed.height + 7) / 8, depth: 1)
                let threads = MTLSize(width: 8, height: 8, depth: 1)
                if let forward = buffer.makeComputeCommandEncoder() {
                    forward.setComputePipelineState(gpu.jpegForwardPipeline)
                    forward.setTexture(print.composedStored, index: 0)
                    forward.setTexture(print.coefficients, index: 1)
                    forward.setBytes(&jpeg, length: MemoryLayout<JpegUniforms>.stride, index: 0)
                    forward.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
                    forward.endEncoding()
                }
                if let inverse = buffer.makeComputeCommandEncoder() {
                    inverse.setComputePipelineState(gpu.jpegInversePipeline)
                    inverse.setTexture(print.coefficients, index: 0)
                    inverse.setTexture(print.glitchedStored, index: 1)
                    inverse.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
                    inverse.endEncoding()
                }
                print.showingGlitched = true
            }
        }
    }

    /// Paint every print the newest one has buried into the desk for good, and let go of
    /// them. After this they cost nothing at all, and can never need removing.
    private func bakeFinished(into buffer: MTLCommandBuffer, gpu: DeskGPU,
                              canvas: MTLTexture, time: Double, size: CGSize) {
        guard prints.count > 1, let newest = prints.last,
              newest.landing(at: time, instantly: reduceMotion) >= 1 else { return }
        let finished = prints.dropLast().filter { $0.composedOnce && !$0.baked }
        guard !finished.isEmpty else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = canvas
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        if let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) {
            for print in finished {
                draw(print, with: encoder, gpu: gpu,
                     shadow: gpu.bakeShadowPipeline, paper: gpu.bakeCardPipeline,
                     time: time, size: size)
                print.baked = true
                // Its working set goes now; its picture goes with the print itself as
                // soon as the desk lets go of it, below.
                print.settle()
            }
            encoder.endEncoding()
        }
        prints.removeAll { $0.baked }
        if prints.isEmpty { prints = [newest] }
    }

    // MARK: - Drawing one print

    /// Where a print is, and how it is lit, at a moment in its fall.
    private func card(for print: PhotoPrint, time: Double, size: CGSize) -> CardUniforms {
        let landing = print.landing(at: time, instantly: reduceMotion)
        var card = CardUniforms()
        card.viewportHalf = SIMD2(Float(size.width) / 2, Float(size.height) / 2)
        // It falls from off the top, turning as it goes, and stops dead.
        let centre = deskMix(print.entryCentre, print.centre, landing)
        card.centre = SIMD2(centre.x * Float(size.width), centre.y * Float(size.height))
        let rotation = deskMix(print.entryRotation, print.rotation, landing)
        card.cosR = cos(rotation)
        card.sinR = sin(rotation)
        // A print in the air is bigger, being nearer, and its shadow is looser.
        card.halfSize = print.halfSize * deskMix(DeskLook.liftFalling, 1, landing)
        card.apertureHalf = print.apertureHalf
        card.spread = deskMix(DeskLook.shadowSpreadFalling, DeskLook.shadowSpreadLanded, landing)
        card.landing = landing
        // Paper is a quarter of a millimetre thick, so a print lying flat throws no
        // offset at all — only one still in the air does, and it closes as it comes
        // down. The direction is away from the lamp, necessarily.
        var away = centre - DeskLook.lamp
        let reach = (away.x * away.x + away.y * away.y).squareRoot()
        if reach > 0 { away /= reach }
        card.lamp = -away
        card.shadowOffset = away * (1 - landing)
            * Float(min(size.width, size.height)) * DeskLook.shadowOffsetFalling
        return card
    }

    private func draw(_ print: PhotoPrint, with encoder: MTLRenderCommandEncoder, gpu: DeskGPU,
                      shadow: MTLRenderPipelineState, paper: MTLRenderPipelineState,
                      time: Double, size: CGSize) {
        var uniforms = card(for: print, time: time, size: size)
        encoder.setRenderPipelineState(shadow)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CardUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CardUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        encoder.setRenderPipelineState(paper)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CardUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CardUniforms>.stride, index: 0)
        encoder.setFragmentTexture(print.showingGlitched ? print.glitched : print.composed,
                                   index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}

private func deskMix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
private func deskMix(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ t: Float) -> SIMD2<Float> {
    a + (b - a) * t
}

/// A print's seed, from its position in the run. Deterministic so a desk replays.
func deskSeed(_ index: UInt32) -> UInt32 {
    var x = index &* 104_729 &+ 0x9E37_79B9
    x = (x ^ (x >> 16)) &* 0x85EB_CA6B
    x = (x ^ (x >> 13)) &* 0xC2B2_AE35
    return x ^ (x >> 16)
}
