// Renders Pluck Studio's app icon into an .iconset folder: swift scripts/make-studio-icon.swift <out.iconset>
// The icon picked 2026-11-14 (docs/superpowers/plans/logo-master/pluck-studio-icon-fan.svg): three guitar picks fanned out,
// "pluck" and everything Pluck brings together, in the brand's plum on a dark tile. Drawn here from the same shapes (the
// SVG's 130-unit square) on macOS's icon grid. Basic Pluck keeps its own (make-icon.swift).
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func colour(_ hex: Int) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func gradient(_ stops: [(Int, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map { colour($0.0) } as CFArray,
               locations: stops.map(\.1))!
}

/// One pick, centred on its box (top -44, tip 42, sides ±38), as in the SVG.
let pick: CGPath = {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 0, y: -44))
    p.addCurve(to: CGPoint(x: 38, y: -24), control1: CGPoint(x: 22, y: -44), control2: CGPoint(x: 38, y: -38))
    p.addCurve(to: CGPoint(x: 7, y: 37), control1: CGPoint(x: 38, y: -6), control2: CGPoint(x: 21, y: 21))
    p.addQuadCurve(to: CGPoint(x: -7, y: 37), control: CGPoint(x: 0, y: 45))
    p.addCurve(to: CGPoint(x: -38, y: -24), control1: CGPoint(x: -21, y: 21), control2: CGPoint(x: -38, y: -6))
    p.addCurve(to: CGPoint(x: 0, y: -44), control1: CGPoint(x: -38, y: -38), control2: CGPoint(x: -22, y: -44))
    p.closeSubpath()
    return p
}()

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let c = NSGraphicsContext.current!.cgContext
    let s = size / 1024
    // macOS icon grid: an 824-point square centred on the 1024 canvas; the SVG's 130 units map onto it, y running down.
    let k = 824 * s / 130
    c.translateBy(x: 100 * s, y: 924 * s)
    c.scaleBy(x: k, y: -k)
    let tile = CGPath(roundedRect: CGRect(x: 0, y: 0, width: 130, height: 130), cornerWidth: 30, cornerHeight: 30, transform: nil)

    // The tile, with the shadow macOS icons have (offset downwards on screen).
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: CGColor(gray: 0, alpha: 0.3))
    c.addPath(tile)
    c.setFillColor(colour(0x0E0C11))
    c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(tile)
    c.clip()
    c.drawLinearGradient(gradient([(0x1E1925, 0), (0x0E0C11, 1)]), start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 130), options: [])

    // A pick fanned by `angle` degrees around its tip, `scale` of the front one, filled from `from` to `to` (in its own box).
    func draw(angle: CGFloat, scale: CGFloat, stops: [(Int, CGFloat)], from: CGPoint, to: CGPoint, shadow: Bool) {
        c.saveGState()
        c.translateBy(x: 65, y: 63)
        c.scaleBy(x: 0.8, y: 0.8)
        c.translateBy(x: 0, y: 42)
        c.rotate(by: angle * .pi / 180)
        c.translateBy(x: 0, y: -42)
        c.scaleBy(x: scale, y: scale)
        if shadow {
            // (The soft shadow the front pick lays on the other two; in the flipped space "down" is +y on the base.)
            c.setShadow(offset: CGSize(width: 0, height: -1.5 * k), blur: 4.8 * k, color: colour(0x0A070E).copy(alpha: 0.45)!)
            c.addPath(pick)
            c.setFillColor(colour(0x7C5FC0))
            c.fillPath()
            c.setShadow(offset: .zero, blur: 0, color: nil)
        }
        c.addPath(pick)
        c.clip()
        c.drawLinearGradient(gradient(stops), start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        c.restoreGState()
    }
    // (Gradient ends in each pick's own box: x -38…38, y -44…43, as the SVG's objectBoundingBox ones.)
    draw(angle: -22, scale: 0.93, stops: [(0x9A5470, 0), (0x6E3F5A, 1)], from: CGPoint(x: -38, y: -44), to: CGPoint(x: -7.6, y: 43), shadow: false)
    draw(angle: 22, scale: 0.93, stops: [(0x6A4FA6, 0), (0x46327A, 1)], from: CGPoint(x: 38, y: -44), to: CGPoint(x: 7.6, y: 43), shadow: false)
    draw(angle: 0, scale: 1, stops: [(0xC27A96, 0), (0xA06AA6, 0.55), (0x7C5FC0, 1)], from: CGPoint(x: -38, y: -44), to: CGPoint(x: 7.6, y: 43), shadow: true)
    c.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (name, size) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                     ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let rep = render(size: CGFloat(size))
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("icon_\(name).png"))
}
