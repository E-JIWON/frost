// Draws AppIcon.icns: one sharp window over frosted, grainy BDS colors.
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

// BDS comment colors as soft blobs, blurred into frost
let blobs = canvas()
for (hex, x, y, r) in [(0x5A8268, 300, 690, 300), (0x50AAC8, 740, 720, 270), (0xC8A050, 720, 300, 250), (0xC86E82, 290, 290, 230)] {
    blobs.setFillColor(rgb(hex))
    blobs.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}
let ci = CIContext()
let blurred = CIImage(cgImage: blobs.makeImage()!).clampedToExtent()
    .applyingGaussianBlur(sigma: 90).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
let frost = ci.createCGImage(blurred, from: blurred.extent)!

let ctx = canvas()
let body = CGRect(x: 100, y: 100, width: 824, height: 824)  // macOS icon grid
let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

// drop shadow under the tile
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(squircle)
ctx.setFillColor(rgb(0x141210))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
// BDS ink, warming toward the bottom
ctx.drawLinearGradient(CGGradient(colorsSpace: space, colors: [rgb(0x2B3436), rgb(0x141210)] as CFArray, locations: nil)!,
                       start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
ctx.setAlpha(0.9)
ctx.draw(frost, in: CGRect(x: 0, y: 0, width: size, height: size))
ctx.setAlpha(1)

// grain, a little coarser than a pixel so it survives downscaling
let grainSide = size / 2
let px = (0..<grainSide * grainSide).map { _ in UInt8.random(in: 0...255) }
let grain = CGImage(width: grainSide, height: grainSide, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: grainSide,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                    provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
ctx.interpolationQuality = .none
ctx.setAlpha(0.12)
ctx.setBlendMode(.overlay)
ctx.draw(grain, in: CGRect(x: 0, y: 0, width: size, height: size))
ctx.setBlendMode(.normal)
ctx.setAlpha(1)

// glass sheen across the top
ctx.drawLinearGradient(CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.16), rgb(0xFFFFFF, 0)] as CFArray, locations: nil)!,
                       start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 560), options: [])

// the one sharp window
let window = CGRect(x: 262, y: 300, width: 500, height: 380)
let windowPath = CGPath(roundedRect: window, cornerWidth: 46, cornerHeight: 46, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 50, color: rgb(0x000000, 0.45))
ctx.addPath(windowPath)
ctx.setFillColor(rgb(0xFAFAF8))
ctx.fillPath()
ctx.restoreGState()
for (i, hex) in [0xC86E82, 0xC8A050, 0x5A8268].enumerated() {
    ctx.setFillColor(rgb(hex))
    ctx.fillEllipse(in: CGRect(x: 302 + i * 44, y: 618, width: 28, height: 28))
}
ctx.setFillColor(rgb(0xC8C2B6))
for (i, width) in [330, 400, 250].enumerated() {
    ctx.addPath(CGPath(roundedRect: CGRect(x: 304, y: 530 - i * 62, width: width, height: 26), cornerWidth: 13, cornerHeight: 13, transform: nil))
    ctx.fillPath()
}
ctx.restoreGState()

// hairline edge so the tile reads on dark backgrounds
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 185, cornerHeight: 185, transform: nil))
ctx.setStrokeColor(rgb(0xFFFFFF, 0.14))
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
