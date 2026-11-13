import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO

/// Liquify (-PluckScreenshotOnly liquify): no strokes is the same image and saves nothing; Push moves a dot along the drag;
/// Bloat makes a disc bigger and Pinch smaller; far from the brush nothing moves; a preview and the export move alike.
extension PhotoSelfTest {
    static func liquifyTest() async {
        var plain = PhotoAdjustments(); plain.liquify = []
        check("liquify: none saves nothing", plain.liquify == nil && !((try? JSONEncoder().encode(plain)).map { String(decoding: $0, as: UTF8.self) } ?? "").contains("liquify"))
        let context = PhotoEngine.context, frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        func dot(_ c: CGPoint, _ r: CGFloat, over i: CIImage) -> CIImage {
            let g = CIFilter.radialGradient(); g.center = c; g.radius0 = Float(r); g.radius1 = Float(r + 1)
            g.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1, colorSpace: linear)!; g.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            return g.outputImage!.cropped(to: frame).composited(over: i)
        }
        let black = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1, colorSpace: linear)!).cropped(to: frame)
        // A dot at (400, 300) (share 0.5, 0.5) and one far off at (80, 80).
        let picture = dot(CGPoint(x: 80, y: 80), 10, over: dot(CGPoint(x: 400, y: 300), 20, over: black))
        check("liquify: no strokes, the same image", PhotoLiquify.apply(nil, to: picture) === picture && PhotoLiquify.apply([], to: picture) === picture)
        func centre(_ i: CIImage, in box: CGRect) -> (CGPoint, Double) {
            var px = [Float](repeating: 0, count: Int(box.width * box.height) * 4)
            context.render(i, toBitmap: &px, rowBytes: Int(box.width) * 16, bounds: box, format: .RGBAf, colorSpace: linear)
            var sx = 0.0, sy = 0.0, n = 0.0
            for y in 0..<Int(box.height) { for x in 0..<Int(box.width) where px[(y * Int(box.width) + x) * 4] > 0.5 {
                // (Rows from the top in the bitmap.)
                sx += Double(x); sy += Double(Int(box.height) - 1 - y); n += 1
            } }
            return (CGPoint(x: box.minX + sx / max(n, 1), y: box.minY + sy / max(n, 1)), n)
        }
        let (c0, area0) = centre(picture, in: frame)
        // Push: a drag from the dot 60 px to the right (shares; y from the top).
        let push = LiquifyStroke(tool: .push, points: (0...12).map { CGPoint(x: 0.5 + Double($0) * 0.075 / 12, y: 0.5) }, radius: 0.08, strength: 1)
        let pushed = PhotoLiquify.apply([push], to: picture)
        let (c1, _) = centre(pushed, in: CGRect(x: 200, y: 150, width: 400, height: 300))
        check("liquify: push moves the dot along the drag", c1.x > 400 + 15 && abs(c1.y - 300) < 4, "from \(c0) to \(c1)")
        let (far, _) = centre(pushed, in: CGRect(x: 40, y: 40, width: 80, height: 80))
        check("liquify: far off nothing moves", abs(far.x - 80) < 1 && abs(far.y - 80) < 1, "\(far)")
        let bloat = LiquifyStroke(tool: .bloat, points: Array(repeating: CGPoint(x: 0.5, y: 0.5), count: 10), radius: 0.08, strength: 1)
        let pinch = LiquifyStroke(tool: .pinch, points: Array(repeating: CGPoint(x: 0.5, y: 0.5), count: 10), radius: 0.08, strength: 1)
        let (_, small) = centre(PhotoLiquify.apply([pinch], to: picture), in: CGRect(x: 200, y: 150, width: 400, height: 300))
        let (_, big) = centre(PhotoLiquify.apply([bloat], to: picture), in: CGRect(x: 200, y: 150, width: 400, height: 300))
        let (_, area) = centre(picture, in: CGRect(x: 200, y: 150, width: 400, height: 300))
        let out = URL(fileURLWithPath: photos).deletingLastPathComponent()
        for (n, i) in [("liq-bloat", PhotoLiquify.apply([bloat], to: picture)), ("liq-pinch", PhotoLiquify.apply([pinch], to: picture)), ("liq-push", pushed)] {
            if let cg = context.createCGImage(i, from: frame, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
               let d = CGImageDestinationCreateWithURL(out.appendingPathComponent(n + ".png") as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d)
            }
        }
        check("liquify: bloat grows the dot, pinch shrinks it", big > area * 1.3 && small < area * 0.8, "area \(area): bloat \(big), pinch \(small)")
        // A half-size preview moves by the same share.
        let half = picture.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        let (ch, _) = centre(PhotoLiquify.apply([push], to: half), in: CGRect(x: 100, y: 75, width: 200, height: 150))
        check("liquify: a preview moves as the export", abs(ch.x * 2 - c1.x) < 3, "export \(c1.x), preview ×2 \(ch.x * 2)")
        _ = area0
    }
}
