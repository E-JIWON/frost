// Draws AppIcon.icns: a fogged-up window wiped clear in the middle, framed by focus corners.
// Run from this folder: swift icon.swift
import AppKit
import CoreImage

func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func canvas() -> CGContext {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
// Coordinates below are top-down, like the design file; CG draws bottom-up.
func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: CGFloat(size) - y) }
func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: CGFloat(size) - y - h, width: w, height: h) }
let full = CGRect(x: 0, y: 0, width: size, height: size)
let ci = CIContext()
func blur(_ image: CGImage, _ sigma: Double, gray: Bool = false) -> CGImage {
    let out = CIImage(cgImage: image).clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: full)
    return gray ? ci.createCGImage(out, from: full, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())!
                : ci.createCGImage(out, from: full)!
}

// The view outside: blue sky, a big sun, one hill
let scene = canvas()
scene.drawLinearGradient(CGGradient(colorsSpace: space, colors: [rgb(0x2457E6), rgb(0x8EC5FF)] as CFArray, locations: nil)!,
                         start: p(0, 100), end: p(0, 924), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
scene.setFillColor(rgb(0xFFD86B))
scene.fillEllipse(in: rect(580 - 108, 450 - 108, 216, 216))
let hill = CGMutablePath()
hill.move(to: p(0, 660))
hill.addLine(to: p(100, 640))
hill.addCurve(to: p(580, 640), control1: p(280, 560), control2: p(440, 590))
hill.addCurve(to: p(924, 600), control1: p(720, 690), control2: p(830, 620))
hill.addLine(to: p(1024, 590))
hill.addLine(to: p(1024, 1024))
hill.addLine(to: p(0, 1024))
hill.closeSubpath()
scene.addPath(hill)
scene.setFillColor(rgb(0x2E9468))
scene.fillPath()
let sharp = scene.makeImage()!
let fogged = blur(sharp, 42)

// The wiped patch, soft at the edges
let wipe = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
wipe.setFillColor(gray: 0, alpha: 1)
wipe.fill(full)
wipe.addPath(CGPath(roundedRect: rect(300, 300, 424, 424), cornerWidth: 104, cornerHeight: 104, transform: nil))
wipe.setFillColor(gray: 1, alpha: 1)
wipe.fillPath()
let wiped = blur(wipe.makeImage()!, 9, gray: true)

let ctx = canvas()
let body = rect(100, 100, 824, 824)  // macOS icon grid
let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// drop shadow under the tile
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(squircle)
ctx.setFillColor(rgb(0x2457E6))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
// fog: the view blurred and paled
ctx.draw(fogged, in: full)
ctx.setFillColor(rgb(0xDCE6F7, 0.4))
ctx.fill(full)

// grain, a little coarser than a pixel so it survives downscaling
let grainSide = size / 2
let px = (0..<grainSide * grainSide).map { _ in UInt8.random(in: 0...255) }
let grain = CGImage(width: grainSide, height: grainSide, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: grainSide,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                    provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
ctx.saveGState()
ctx.interpolationQuality = .none
ctx.setAlpha(0.18)
ctx.setBlendMode(.softLight)
ctx.draw(grain, in: full)
ctx.restoreGState()

// the wiped patch shows the view sharp
ctx.saveGState()
ctx.clip(to: full, mask: wiped)
ctx.draw(sharp, in: full)
ctx.restoreGState()

// glass sheen across the top
ctx.drawLinearGradient(CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)] as CFArray, locations: nil)!,
                       start: p(0, 100), end: p(0, 480), options: [])

// focus corners
let corners = CGMutablePath()
for (a, b, c, d, e) in [((236, 372), (236, 292), (236, 236), (292, 236), (372, 236)),
                        ((652, 236), (732, 236), (788, 236), (788, 292), (788, 372)),
                        ((788, 652), (788, 732), (788, 788), (732, 788), (652, 788)),
                        ((372, 788), (292, 788), (236, 788), (236, 732), (236, 652))] as [((CGFloat, CGFloat), (CGFloat, CGFloat), (CGFloat, CGFloat), (CGFloat, CGFloat), (CGFloat, CGFloat))] {
    corners.move(to: p(a.0, a.1))
    corners.addLine(to: p(b.0, b.1))
    corners.addQuadCurve(to: p(d.0, d.1), control: p(c.0, c.1))
    corners.addLine(to: p(e.0, e.1))
}
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: rgb(0x06143A, 0.4))
ctx.addPath(corners)
ctx.setStrokeColor(rgb(0xFFFFFF))
ctx.setLineWidth(50)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.strokePath()
ctx.restoreGState()

// hairline edge so the tile reads on dark backgrounds
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
ctx.setStrokeColor(rgb(0xFFFFFF, 0.4))
ctx.setLineWidth(3)
ctx.strokePath()

// iconset -> icns
let fm = FileManager.default
let set = URL(fileURLWithPath: "AppIcon.iconset")
try? fm.removeItem(at: set)
try! fm.createDirectory(at: set, withIntermediateDirectories: true)
let master = NSBitmapImageRep(cgImage: ctx.makeImage()!)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let side = points * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current!.imageInterpolation = .high
        master.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", set.path, "-o", "AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
try? fm.removeItem(at: set)
print(iconutil.terminationStatus == 0 ? "AppIcon.icns written" : "iconutil failed")
