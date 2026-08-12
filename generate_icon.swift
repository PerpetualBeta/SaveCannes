#!/usr/bin/env swift

import AppKit
import CoreGraphics

// Brand-consistent slate background — the same one Rainy Day uses, so the two
// savers look like siblings in the Applications folder — carrying a strip of
// film in Palme d'Or gold, tilted off the horizontal so it reads as film
// running rather than a gold bar. A warm projector glow sits behind it.
//
// Everything is derived from `s`, the icon's edge length, so the 16pt and
// 1024pt renders are the same drawing rather than two drawings that happen to
// resemble each other.

let slateTop    = NSColor(srgbRed: 0x1F/255, green: 0x27/255, blue: 0x33/255, alpha: 1.0)
let slateBottom = NSColor(srgbRed: 0x0E/255, green: 0x12/255, blue: 0x18/255, alpha: 1.0)
let glow        = NSColor(srgbRed: 0xE8/255, green: 0xA4/255, blue: 0x5A/255, alpha: 1.0)
let gold        = NSColor(srgbRed: 0xD9/255, green: 0xB0/255, blue: 0x4A/255, alpha: 1.0)
let goldDeep    = NSColor(srgbRed: 0xA8/255, green: 0x7C/255, blue: 0x24/255, alpha: 1.0)

func drawIcon(size s: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }
    let space = CGColorSpaceCreateDeviceRGB()

    // Rounded slate background.
    let bgRect = NSRect(x: s * 0.04, y: s * 0.04, width: s * 0.92, height: s * 0.92)
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: s * 0.18, yRadius: s * 0.18)
    ctx.saveGState()
    ctx.addPath(bgPath.cgPath)
    ctx.clip()

    if let bg = CGGradient(colorsSpace: space,
                           colors: [slateTop.cgColor, slateBottom.cgColor] as CFArray,
                           locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(bg,
                               start: CGPoint(x: s / 2, y: s),
                               end: CGPoint(x: s / 2, y: 0),
                               options: [])
    }

    // Projector glow, low-left, warm.
    if let halo = CGGradient(colorsSpace: space,
                             colors: [glow.withAlphaComponent(0.34).cgColor,
                                      glow.withAlphaComponent(0.0).cgColor] as CFArray,
                             locations: [0.0, 1.0]) {
        let centre = CGPoint(x: s * 0.32, y: s * 0.30)
        ctx.drawRadialGradient(halo,
                               startCenter: centre, startRadius: 0,
                               endCenter: centre, endRadius: s * 0.52,
                               options: [])
    }

    // The film strip, tilted. Drawn in its own rotated space so the frames and
    // sprocket holes come along with it.
    ctx.saveGState()
    ctx.translateBy(x: s / 2, y: s / 2)
    ctx.rotate(by: -14 * .pi / 180)

    let stripW = s * 0.86
    let stripH = s * 0.42
    let strip = CGRect(x: -stripW / 2, y: -stripH / 2, width: stripW, height: stripH)

    // Strip body, with a slight vertical gradient so the gold has some depth.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: strip,
                       cornerWidth: s * 0.03, cornerHeight: s * 0.03,
                       transform: nil))
    ctx.clip()
    if let body = CGGradient(colorsSpace: space,
                             colors: [gold.cgColor, goldDeep.cgColor] as CFArray,
                             locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(body,
                               start: CGPoint(x: 0, y: strip.maxY),
                               end: CGPoint(x: 0, y: strip.minY),
                               options: [])
    }
    ctx.restoreGState()

    // Frames — three windows of slate punched out of the gold, and the
    // sprocket holes above and below them.
    let frameCount = 3
    let margin = stripH * 0.22          // depth of the sprocket rails
    let gutter = stripW * 0.035
    let frameH = stripH - margin * 2
    let frameW = (stripW - gutter * CGFloat(frameCount + 1)) / CGFloat(frameCount)

    for i in 0..<frameCount {
        let x = strip.minX + gutter + (frameW + gutter) * CGFloat(i)
        let window = CGRect(x: x, y: strip.minY + margin, width: frameW, height: frameH)
        ctx.setFillColor(slateBottom.withAlphaComponent(0.92).cgColor)
        ctx.addPath(CGPath(roundedRect: window,
                           cornerWidth: s * 0.012, cornerHeight: s * 0.012,
                           transform: nil))
        ctx.fillPath()

        // Two sprocket holes per frame, one on each rail.
        let holeW = frameW * 0.30
        let holeH = margin * 0.44
        let holeX = window.midX - holeW / 2
        for holeY in [strip.minY + (margin - holeH) / 2,
                      strip.maxY - margin + (margin - holeH) / 2] {
            ctx.setFillColor(slateBottom.withAlphaComponent(0.85).cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: holeX, y: holeY, width: holeW, height: holeH),
                               cornerWidth: holeH / 2, cornerHeight: holeH / 2,
                               transform: nil))
            ctx.fillPath()
        }
    }

    ctx.restoreGState()   // un-rotate
    ctx.restoreGState()   // un-clip background

    image.unlockFocus()
    return image
}

extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        let points = UnsafeMutablePointer<NSPoint>.allocate(capacity: 3)
        defer { points.deallocate() }
        for i in 0..<elementCount {
            let element = self.element(at: i, associatedPoints: points)
            switch element {
            case .moveTo:           path.move(to: points[0])
            case .lineTo:           path.addLine(to: points[0])
            case .curveTo:          path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .cubicCurveTo:     path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo: path.addQuadCurve(to: points[1], control: points[0])
            case .closePath:        path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

let scriptDir = CommandLine.arguments[0].components(separatedBy: "/").dropLast().joined(separator: "/")
let iconsetDir = (scriptDir.isEmpty ? "." : scriptDir) + "/Resources/SaveCannes.iconset"
let fm = FileManager.default
try? fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

for (size, name) in sizes {
    let image = drawIcon(size: CGFloat(size))
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else { continue }
    try! png.write(to: URL(fileURLWithPath: iconsetDir + "/" + name))
    print("  \(name) (\(size)x\(size))")
}

let icnsPath = (scriptDir.isEmpty ? "." : scriptDir) + "/Resources/AppIcon.icns"
let result = Process()
result.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
result.arguments = ["-c", "icns", iconsetDir, "-o", icnsPath]
try! result.run()
result.waitUntilExit()
print("  AppIcon.icns")
print("Done.")
