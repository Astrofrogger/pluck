// Renders Pluck Studio's app icon into an .iconset folder: swift scripts/make-studio-icon.swift <out.iconset>
// The icon picked 2026-11-09 (docs/superpowers/plans/logo-master/pluck-studio-icon-final.svg): a before/after split line and
// its handle forming a lowercase p, plum (#8E4C64 to #533C88), on a two-tone tile (#121016, left panel #27212F). Drawn here
// from the same shapes (the SVG's 130-unit square) on macOS's icon grid. Basic Pluck keeps its own (make-icon.swift).
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func colour(_ hex: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    // macOS icon grid: an 824-point square centred on the 1024 canvas; the SVG's 130 units map onto it (y turned up).
    let k = 824 * s / 130, ox = 100 * s, oy = 100 * s
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * k, y: oy + (130 - y) * k) }
    let tileRect = NSRect(x: ox, y: oy, width: 130 * k, height: 130 * k)
    let tile = NSBezierPath(roundedRect: tileRect, xRadius: 30 * k, yRadius: 30 * k)

    // The tile's shadow, as macOS icons have.
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    colour(0x121016).setFill()
    tile.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGraphicsContext.current?.saveGraphicsState()
    tile.addClip()
    // The left panel (x 0…47), lighter.
    colour(0x27212F).setFill()
    NSBezierPath(rect: NSRect(x: ox, y: oy, width: 47 * k, height: 130 * k)).fill()
    // The plum: the split line (x 42.5…51.5, top to bottom) and the handle's ring (centre 68, 50, radius 21, 9 wide).
    let plum = NSGradient(starting: colour(0x8E4C64), ending: colour(0x533C88))!
    let line = NSBezierPath(rect: NSRect(x: ox + 42.5 * k, y: oy, width: 9 * k, height: 130 * k))
    let centre = p(68, 50)
    let ring = NSBezierPath(ovalIn: NSRect(x: centre.x - 25.5 * k, y: centre.y - 25.5 * k, width: 51 * k, height: 51 * k))
    ring.append(NSBezierPath(ovalIn: NSRect(x: centre.x - 16.5 * k, y: centre.y - 16.5 * k, width: 33 * k, height: 33 * k)).reversed)
    let mark = NSBezierPath()
    mark.append(line)
    mark.append(ring)
    // (The SVG's gradient runs from (20, 10) to (110, 120): top left to bottom right.)
    let start = p(20, 10), end = p(110, 120)
    NSGraphicsContext.current?.saveGraphicsState()
    mark.addClip()
    plum.draw(from: start, to: end, options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
    NSGraphicsContext.current?.restoreGraphicsState()
    // The ring's middle stays the tile's dark (it sits over the split line).
    colour(0x121016).setFill()
    NSBezierPath(ovalIn: NSRect(x: centre.x - 16.5 * k, y: centre.y - 16.5 * k, width: 33 * k, height: 33 * k)).fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (name, size) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                     ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let rep = render(size: CGFloat(size))
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("icon_\(name).png"))
}
