// SPDX-License-Identifier: GPL-2.0-or-later
// Draws Hunter's Lantern's app icon (a lantern in a night-blue Big Sur squircle; our own design,
// no game artwork, docs/LAUNCHER_PLAN.md D17) at every iconset size:
//   swift launcher/packaging/make-icon.swift <out.iconset>
//   iconutil -c icns <out.iconset> -o AppIcon.icns       (launcher/build.sh does both)
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Everything below is drawn on a 1024x1024 canvas (y up) and scaled to the target size.

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
}

func radial(_ ctx: CGContext, _ g: CGGradient, center: CGPoint, radius: CGFloat) {
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

/// A polygon path from points.
func poly(_ pts: [CGPoint]) -> CGPath {
    let p = CGMutablePath()
    p.move(to: pts[0])
    for pt in pts.dropFirst() { p.addLine(to: pt) }
    p.closeSubpath()
    return p
}

func draw(_ ctx: CGContext, px: Int) {
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Big Sur template: an 824 px shape inset 100 px in the 1024 canvas, corner radius 22.5%.
    let shape = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: shape, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow below the shape.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: rgb(0, 0, 0, 0.5))
    ctx.addPath(squircle)
    ctx.setFillColor(rgb(8, 10, 20))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    // Night sky: deep blue at the top, near black at the bottom.
    ctx.drawLinearGradient(
        gradient([(0, rgb(4, 6, 14)), (0.45, rgb(10, 18, 42)), (1, rgb(34, 58, 112))]),
        start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

    // Soft halo around the lantern.
    radial(ctx,
           gradient([(0, rgb(255, 170, 60, 0.85)), (0.3, rgb(240, 130, 40, 0.48)),
                     (0.65, rgb(170, 80, 30, 0.16)), (1, rgb(120, 50, 20, 0))]),
           center: CGPoint(x: 512, y: 470), radius: 500)

    // --- Lantern geometry (canvas coordinates, centred on x = 512) ---
    let cx: CGFloat = 512
    let glassBottom: CGFloat = 318, glassTop: CGFloat = 618
    let halfBottom: CGFloat = 124, halfTop: CGFloat = 146
    func halfWidth(at y: CGFloat) -> CGFloat {
        halfBottom + (halfTop - halfBottom) * (y - glassBottom) / (glassTop - glassBottom)
    }
    let glass = poly([
        CGPoint(x: cx - halfBottom, y: glassBottom), CGPoint(x: cx + halfBottom, y: glassBottom),
        CGPoint(x: cx + halfTop, y: glassTop), CGPoint(x: cx - halfTop, y: glassTop),
    ])

    let metal = rgb(20, 18, 24)
    let rim = rgb(150, 120, 90, 0.28) // faint warm edge light on the metal
    func fillMetal(_ path: CGPath) {
        ctx.addPath(path)
        ctx.setFillColor(metal)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(rim)
        ctx.setLineWidth(3)
        ctx.strokePath()
    }

    // Glass: amber glow, brightest in the middle.
    ctx.saveGState()
    ctx.addPath(glass)
    ctx.clip()
    ctx.setFillColor(rgb(120, 50, 12))
    ctx.fill(CGRect(x: 300, y: 300, width: 424, height: 340))
    radial(ctx,
           gradient([(0, rgb(255, 238, 170)), (0.25, rgb(255, 196, 88)), (0.6, rgb(240, 130, 36)),
                     (1, rgb(150, 60, 14))]),
           center: CGPoint(x: cx, y: 455), radius: 190)
    // The flame: a small teardrop with a white-hot core.
    let flame = CGMutablePath()
    flame.move(to: CGPoint(x: cx, y: 540))
    flame.addCurve(to: CGPoint(x: cx + 34, y: 424), control1: CGPoint(x: cx + 10, y: 500), control2: CGPoint(x: cx + 34, y: 470))
    flame.addCurve(to: CGPoint(x: cx, y: 382), control1: CGPoint(x: cx + 34, y: 400), control2: CGPoint(x: cx + 18, y: 382))
    flame.addCurve(to: CGPoint(x: cx - 34, y: 424), control1: CGPoint(x: cx - 18, y: 382), control2: CGPoint(x: cx - 34, y: 400))
    flame.addCurve(to: CGPoint(x: cx, y: 540), control1: CGPoint(x: cx - 34, y: 470), control2: CGPoint(x: cx - 10, y: 500))
    flame.closeSubpath()
    ctx.addPath(flame)
    ctx.setFillColor(rgb(255, 248, 215, 0.95))
    ctx.fillPath()
    ctx.restoreGState()

    // Base: foot and plate.
    fillMetal(CGPath(roundedRect: CGRect(x: cx - 120, y: 250, width: 240, height: 34), cornerWidth: 10, cornerHeight: 10, transform: nil))
    fillMetal(CGPath(roundedRect: CGRect(x: cx - 152, y: 280, width: 304, height: 40), cornerWidth: 12, cornerHeight: 12, transform: nil))

    // Four slim bars: two posts at the edges, two inside the glass.
    for frac: CGFloat in [-1, -0.36, 0.36, 1] {
        let outer = abs(frac) == 1
        let w: CGFloat = outer ? 20 : 12
        let bx = { (y: CGFloat) -> CGFloat in cx + frac * halfWidth(at: y) }
        fillMetal(poly([
            CGPoint(x: bx(glassBottom) - w / 2, y: glassBottom - 2), CGPoint(x: bx(glassBottom) + w / 2, y: glassBottom - 2),
            CGPoint(x: bx(glassTop) + w / 2, y: glassTop + 2), CGPoint(x: bx(glassTop) - w / 2, y: glassTop + 2),
        ]))
    }

    // Cap: rim plate, dome, chimney and the ring handle.
    fillMetal(CGPath(roundedRect: CGRect(x: cx - 168, y: 612, width: 336, height: 36), cornerWidth: 12, cornerHeight: 12, transform: nil))
    let dome = CGMutablePath()
    dome.move(to: CGPoint(x: cx - 146, y: 646))
    dome.addCurve(to: CGPoint(x: cx, y: 724), control1: CGPoint(x: cx - 140, y: 690), control2: CGPoint(x: cx - 60, y: 722))
    dome.addCurve(to: CGPoint(x: cx + 146, y: 646), control1: CGPoint(x: cx + 60, y: 722), control2: CGPoint(x: cx + 140, y: 690))
    dome.closeSubpath()
    fillMetal(dome)
    fillMetal(CGPath(roundedRect: CGRect(x: cx - 30, y: 716, width: 60, height: 30), cornerWidth: 8, cornerHeight: 8, transform: nil))
    // Ring handle: a stroked circle, drawn as a dark ring with a faint rim on both edges.
    let ringCenter = CGPoint(x: cx, y: 780), ringRadius: CGFloat = 46
    ctx.setLineWidth(22)
    ctx.setStrokeColor(rim)
    ctx.addArc(center: ringCenter, radius: ringRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()
    ctx.setLineWidth(17)
    ctx.setStrokeColor(metal)
    ctx.addArc(center: ringCenter, radius: ringRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

    // Warm light spilling on the cap and the ground.
    radial(ctx, gradient([(0, rgb(255, 180, 70, 0.22)), (1, rgb(255, 180, 70, 0))]),
           center: CGPoint(x: cx, y: 250), radius: 230)

    ctx.restoreGState() // clip to the shape

    // A thin light edge along the top of the shape.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    ctx.addPath(squircle)
    ctx.setStrokeColor(rgb(255, 255, 255, 0.10))
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()
}

func writePNG(px: Int, to url: URL) {
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          true else { fatalError("CGContext") }
    draw(ctx, px: px)
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("PNG destination") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("PNG write \(url.path)") }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <out.iconset>\n".utf8))
    exit(2)
}
let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    writePNG(px: base, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(px: base * 2, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
