#!/usr/bin/env swift

import AppKit
import CoreGraphics

// The Jorvik brand blue, carrying a strip of film in Palme d'Or gold, tilted
// off the horizontal so it reads as film running rather than a gold bar.
//
// The background is the estate's standard icon plate: the #004080-family
// gradient, corner radius 0.22, full bleed — the same plate Ballast,
// QuitProtect and the Web Editor sit on. The first version of this icon
// borrowed Rainy Day's dark grey instead, on the theory that the two
// screensavers should look like siblings. Wrong axis: what makes a Jorvik icon
// set a set is the brand plate, and one app opting out of it doesn't read as a
// sibling, it reads as a stranger.
//
// Everything is derived from `s`, the icon's edge length, so the 16pt and
// 1024pt renders are the same drawing rather than two drawings that happen to
// resemble each other.

/// The brand plate, top to bottom. The same pair every Jorvik icon uses.
let brandTop    = NSColor(srgbRed: 0.05, green: 0.32, blue: 0.58, alpha: 1.0)
let brandBottom = NSColor(srgbRed: 0.00, green: 0.20, blue: 0.42, alpha: 1.0)
/// A cool highlight rather than the warm projector glow of the first version.
/// Amber over blue turns to mud.
let sheen       = NSColor(srgbRed: 0.45, green: 0.70, blue: 0.95, alpha: 1.0)
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

    // The brand plate: full bleed, radius 0.22, as every other Jorvik icon.
    let bgRect = NSRect(x: 0, y: 0, width: s, height: s)
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: s * 0.22, yRadius: s * 0.22)
    ctx.saveGState()
    ctx.addPath(bgPath.cgPath)
    ctx.clip()

    if let bg = CGGradient(colorsSpace: space,
                           colors: [brandTop.cgColor, brandBottom.cgColor] as CFArray,
                           locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(bg,
                               start: CGPoint(x: s / 2, y: s),
                               end: CGPoint(x: s / 2, y: 0),
                               options: [])
    }

    // A soft highlight where the light falls, top left. Keeps the plate from
    // reading as flat without introducing a second hue.
    if let halo = CGGradient(colorsSpace: space,
                             colors: [sheen.withAlphaComponent(0.30).cgColor,
                                      sheen.withAlphaComponent(0.0).cgColor] as CFArray,
                             locations: [0.0, 1.0]) {
        let centre = CGPoint(x: s * 0.30, y: s * 0.74)
        ctx.drawRadialGradient(halo,
                               startCenter: centre, startRadius: 0,
                               endCenter: centre, endRadius: s * 0.62,
                               options: [])
    }

    // The film strip, tilted. Drawn in its own rotated space so the frames and
    // sprocket holes come along with it.
    ctx.saveGState()
    ctx.translateBy(x: s / 2, y: s / 2)
    ctx.rotate(by: -14 * .pi / 180)

    let stripW = s * 0.78
    let stripH = s * 0.40
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

    // Frames — three windows punched out of the gold, showing the plate
    // through, and the sprocket holes above and below them.
    let frameCount = 3
    let margin = stripH * 0.22          // depth of the sprocket rails
    let gutter = stripW * 0.035
    let frameH = stripH - margin * 2
    let frameW = (stripW - gutter * CGFloat(frameCount + 1)) / CGFloat(frameCount)

    for i in 0..<frameCount {
        let x = strip.minX + gutter + (frameW + gutter) * CGFloat(i)
        let window = CGRect(x: x, y: strip.minY + margin, width: frameW, height: frameH)
        ctx.setFillColor(brandBottom.withAlphaComponent(0.94).cgColor)
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
            ctx.setFillColor(brandBottom.withAlphaComponent(0.88).cgColor)
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
