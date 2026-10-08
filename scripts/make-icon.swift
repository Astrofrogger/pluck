// Renders the app icon into an .iconset folder: swift scripts/make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // macOS icon grid: 824pt rounded square centred on a 1024 canvas.
    let rect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(srgbRed: 1.00, green: 0.36, blue: 0.42, alpha: 1),
        NSColor(srgbRed: 0.93, green: 0.13, blue: 0.36, alpha: 1),
        NSColor(srgbRed: 0.55, green: 0.10, blue: 0.55, alpha: 1),
    ])!.draw(in: shape, angle: -70)

    // Soft top sheen.
    NSGradient(colors: [.white.withAlphaComponent(0.28), .white.withAlphaComponent(0)])!
        .draw(in: shape, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: 470 * s, weight: .bold)
    if let symbol = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size, flipped: false) { r in
            symbol.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let origin = NSPoint(x: (size - symbol.size.width) / 2, y: (size - symbol.size.height) / 2 - 8 * s)
        tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    }

    // Baseline bar under the arrow.
    let bar = NSRect(x: 322 * s, y: 228 * s, width: 380 * s, height: 64 * s)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: bar, xRadius: 32 * s, yRadius: 32 * s).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = render(size: px).representation(using: .png, properties: [:])!
        try! data.write(to: out.appendingPathComponent(name))
    }
}
