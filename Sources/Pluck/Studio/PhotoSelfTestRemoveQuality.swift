import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO

/// AI Remove's fill against its surroundings, on made textures (noise, grass, brick) with a thing painted out: as much fine
/// detail inside as around (Laplacian variance), no seam at its edge (gradient), the same grain (high-pass spread, light and
/// colour). Before/after crops go to remove-shots beside the test photos' folder; timings on a 24 MP and 45 MP photo.
extension PhotoSelfTest {
    static func removeQuality() {
        let context = PhotoEngine.context
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let shots = URL(fileURLWithPath: photos).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("remove-shots")
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let tag = FileManager.default.fileExists(atPath: shots.appendingPathComponent("noise-0-with-object.jpg").path) ? "after" : "before"

        /// Zero-mean noise (−0.5…0.5 per channel) at `seed`.
        func noise(_ seed: CGFloat) -> CIImage {
            CIFilter.randomGenerator().outputImage!.transformed(by: CGAffineTransform(translationX: seed * 137, y: seed * 71))
                .applyingFilter("CIColorMatrix", parameters: ["inputBiasVector": CIVector(x: -0.5, y: -0.5, z: -0.5, w: 0)])
        }
        func add(_ a: CIImage, _ b: CIImage) -> CIImage { a.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: b]) }
        func scaled(_ i: CIImage, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIImage {
            i.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: r, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                                                           "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0)])
        }
        func flat(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIImage { CIImage(color: CIColor(red: r, green: g, blue: b, alpha: 1, colorSpace: linear)!) }
        // Sensor-like grain: luma plus a little colour, about 3 % of the level.
        func grain(_ seed: CGFloat, _ level: CGFloat) -> CIImage {
            let luma = noise(seed).applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                                                                                "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0)])
            return add(scaled(luma, level * 0.1, level * 0.1, level * 0.1), scaled(noise(seed + 3), level * 0.04, level * 0.04, level * 0.04))
        }
        let brick = CIColorKernel(source: """
            kernel vec4 brick(__sample n, __sample g) {
                vec2 p = destCoord(); float row = floor(p.y / 44.0);
                float x = p.x + mod(row, 2.0) * 48.0;
                float mortar = (mod(p.y, 44.0) < 5.0 || mod(x, 96.0) < 5.0) ? 1.0 : 0.0;
                float id = fract(sin(dot(vec2(floor(x / 96.0), row), vec2(12.9898, 78.233))) * 43758.5453);
                vec3 b = vec3(0.30, 0.09, 0.05) * (0.75 + 0.5 * id) * (1.0 + 0.35 * n.r);
                return vec4(mix(b, vec3(0.32, 0.30, 0.27) * (1.0 + 0.2 * n.g), mortar) + g.rgb, 1.0);
            }
            """)!

        // Structure: a table's edge (5°), a horizon under a sky, a corner where two edges meet, text-like rows, a sky gradient.
        let edges = CIColorKernel(source: """
            kernel vec4 edges(__sample g, __sample n, float kind, vec2 c, float r) {
                vec2 p = destCoord() - c; vec3 v;
                float lineY = p.x * 0.0875;
                if (kind < 0.5) { v = p.y > lineY ? vec3(0.55, 0.52, 0.48) : vec3(0.12, 0.06, 0.03) * (1.0 + 0.3 * n.r); }
                else if (kind < 1.5) { v = p.y > 0.0 ? mix(vec3(0.35, 0.5, 0.9), vec3(0.15, 0.25, 0.7), clamp(p.y / (6.0 * r), 0.0, 1.0)) : vec3(0.08, 0.1, 0.04) * (1.0 + 0.5 * n.r); }
                else if (kind < 2.5) { v = (p.y > 0.0 && p.x > 0.3 * r) ? vec3(0.6, 0.6, 0.58) : vec3(0.1, 0.1, 0.12) * (1.0 + 0.3 * n.r); }
                else if (kind < 3.5) {
                    float row = floor(p.y / 30.0); float col = floor(p.x / 14.0);
                    float on = fract(sin(dot(vec2(col, row), vec2(12.9898, 78.233))) * 43758.5453) > 0.35 ? 1.0 : 0.0;
                    float ink = (mod(p.y, 30.0) > 8.0 && mod(p.x, 14.0) > 4.0) ? on : 0.0;
                    v = mix(vec3(0.8, 0.78, 0.72), vec3(0.03), ink);
                }
                else { v = mix(vec3(0.9, 0.6, 0.4), vec3(0.2, 0.35, 0.8), clamp(0.5 + p.y / (8.0 * r), 0.0, 1.0)); }
                return vec4(v + g.rgb * sqrt(max(v, vec3(0.0))) * 1.5, 1.0);
            }
            """)
        func texture(_ kind: String, _ size: CGRect) -> CIImage {
            switch kind {
            case "grass":
                let blades = noise(1).applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: 9, kCIInputAngleKey: Double.pi / 2])
                let fine = noise(5).applyingGaussianBlur(sigma: 0.7)
                let base = add(scaled(add(scaled(blades, 3, 3, 3), fine), 0.05, 0.12, 0.03), flat(0.04, 0.12, 0.03))
                return add(base, grain(7, 0.1)).cropped(to: size)
            case "brick":
                return brick.apply(extent: size, arguments: [noise(2).applyingGaussianBlur(sigma: 1.5), grain(8, 0.15)])!
            case "table", "horizon", "corner", "text", "sky":
                return edges!.apply(extent: size, arguments: [grain(10, 0.2), noise(4).applyingGaussianBlur(sigma: 2), ["table", "horizon", "corner", "text", "sky"].firstIndex(of: kind)!,
                                                                CIVector(x: size.width / 2, y: size.height / 2), max(size.width, size.height) * 0.04])!
            default:
                return add(flat(0.18, 0.18, 0.18), grain(9, 0.18)).cropped(to: size)
            }
        }

        /// v = √(linear luma), the crop's rows from the top.
        func luma(_ image: CIImage, _ r: CGRect) -> (w: Int, h: Int, rgb: [Float]) {
            let w = Int(r.width), h = Int(r.height)
            var p = [Float](repeating: 0, count: w * h * 4)
            context.render(image, toBitmap: &p, rowBytes: w * 16, bounds: r, format: .RGBAf, colorSpace: linear)
            return (w, h, p.map { max($0, 0).squareRoot() })
        }

        func measure(_ image: CIImage, crop: CGRect, centre c: CGPoint, r: CGFloat, line: CGFloat?, lineFrom: CGFloat?) -> (lap: (Float, Float), seam: (Float, Float), grain: (Float, Float), chroma: (Float, Float), level: (Float, Float), edge: (Float, Float)) {
            let (w, h, p) = luma(image, crop)
            func v(_ x: Int, _ y: Int, _ k: Int = -1) -> Float {
                let i = (y * w + x) * 4
                return k < 0 ? 0.2126 * p[i] + 0.7152 * p[i + 1] + 0.0722 * p[i + 2] : p[i + k]
            }
            var inside: [Float] = [], ring: [Float] = [], gIn: [Float] = [], gRing: [Float] = []
            var hIn: [Float] = [], hRing: [Float] = [], cIn: [Float] = [], cRing: [Float] = [], lIn: [Float] = [], lRing: [Float] = []
            for y in 2..<(h - 2) { for x in 2..<(w - 2) {
                // (Distance from the spot's centre, the crop's rows from the top.)
                let d = hypot(crop.minX + CGFloat(x) - c.x, crop.maxY - CGFloat(y) - c.y) / r
                let lap = 4 * v(x, y) - v(x - 1, y) - v(x + 1, y) - v(x, y - 1) - v(x, y + 1)
                let grad = hypot(v(x + 1, y) - v(x - 1, y), v(x, y + 1) - v(x, y - 1))
                // High-pass: the pixel minus its 3×3 mean (light), and of R−B (colour).
                func hp(_ f: (Int, Int) -> Float) -> Float {
                    var s: Float = 0; for dy in -1...1 { for dx in -1...1 { s += f(x + dx, y + dy) } }
                    return f(x, y) - s / 9
                }
                let hl = hp { v($0, $1) }, hc = hp { v($0, $1, 0) - v($0, $1, 2) }
                if d < 0.85 { inside.append(lap); hIn.append(hl); cIn.append(hc); lIn.append(v(x, y)) }
                if d > 1.6 && d < 2.4 { ring.append(lap); gRing.append(grad); hRing.append(hl); cRing.append(hc); lRing.append(v(x, y)) }
                if d > 0.95 && d < 1.35 { gIn.append(grad) }
            } }
            // The edge through the fill: per column, where the steepest vertical step is (near where it should be).
            var res: [Float] = [], peakIn: [Float] = [], peakOut: [Float] = []
            if let slope = line {
                for x in 2..<(w - 2) {
                    let px = crop.minX + CGFloat(x) - c.x
                    if let from = lineFrom, px < from { continue }
                    let want = c.y + px * slope
                    let d = hypot(px, want - c.y) / r
                    guard d < 0.85 || (d > 1.6 && d < 2.4) else { continue }
                    let yw = Int(crop.maxY - want)
                    var best: (g: Float, y: Int) = (0, yw)
                    for y in max(yw - Int(r * 0.5), 3)..<min(yw + Int(r * 0.5), h - 3) {
                        let g = abs(v(x, y + 1) - v(x, y - 1))
                        if g > best.g { best = (g, y) }
                    }
                    if d < 0.85 { res.append(Float(best.y - yw)); peakIn.append(best.g) } else { peakOut.append(best.g) }
                }
            }
            func variance(_ a: [Float]) -> Float { let m = a.reduce(0, +) / Float(max(a.count, 1)); return a.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Float(max(a.count, 1)) }
            func mean(_ a: [Float]) -> Float { a.reduce(0, +) / Float(max(a.count, 1)) }
            return ((variance(inside), variance(ring)), (mean(gIn), mean(gRing)), (variance(hIn).squareRoot(), variance(hRing).squareRoot()),
                    (variance(cIn).squareRoot(), variance(cRing).squareRoot()), (mean(lIn), mean(lRing)),
                    ((res.reduce(0) { $0 + $1 * $1 } / Float(max(res.count, 1))).squareRoot(), mean(peakIn) / max(mean(peakOut), 1e-9)))
        }

        func save(_ image: CIImage, _ r: CGRect, _ name: String) {
            guard let cg = context.createCGImage(image, from: r, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
                  let dest = CGImageDestinationCreateWithURL(shots.appendingPathComponent(name) as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }

        for (kind, size) in ["noise", "grass", "brick", "table", "horizon", "corner", "text", "sky"].map({ ($0, CGSize(width: 4000, height: 2667)) }) + [
                             ("noise", CGSize(width: 6000, height: 4000)), ("noise", CGSize(width: 8256, height: 5504))] {
            let frame = CGRect(origin: .zero, size: size)
            let background = texture(kind, frame)
            // The thing: a dark blue blob, painted over with one stroke (radius 4 % of the long side).
            let long = max(size.width, size.height), r = 0.04 * long
            let c = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
            let thing = flat(0.02, 0.03, 0.2).cropped(to: CGRect(x: c.x - r * 1.4, y: c.y - r * 0.7, width: r * 2.8, height: r * 1.4))
            let picture = thing.composited(over: background).cropped(to: frame)
            let spot = PhotoSpot(kind: .remove, centre: CGPoint(x: 0.5, y: 0.5), source: .zero, radius: 0.04,
                                 stroke: [CGPoint(x: 0.5 - 0.6 * r / size.width, y: 0.5), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.5 + 0.6 * r / size.width, y: 0.5)])
            let t0 = Date()
            let done = PhotoHeal.apply([spot], to: picture)
            let crop = CGRect(x: c.x - 2.6 * r, y: c.y - 2.6 * r, width: 5.2 * r, height: 5.2 * r).integral
            // (Forces the whole fill to be made: what an export does.)
            let line: CGFloat? = kind == "table" ? 0.0875 : kind == "horizon" || kind == "corner" ? 0 : nil
            let m = measure(done, crop: crop, centre: c, r: r * 1.3, line: line, lineFrom: kind == "corner" ? 0.3 * r + 6 : nil)
            let mp = Int((size.width * size.height / 1e6).rounded())
            let lapRatio = m.lap.0 / max(m.lap.1, 1e-9), seamRatio = m.seam.0 / max(m.seam.1, 1e-9), grainRatio = m.grain.0 / max(m.grain.1, 1e-9)
            let chromaRatio = m.chroma.0 / max(m.chroma.1, 1e-9)
            note(String(format: "remove quality %@ %d MP (%@): laplacian var inside/ring %.3f, seam grad %.3f, grain %.3f, colour grain %.3f, level %.4f/%.4f, edge residual %.1f px, edge sharpness %.3f, %.2f s",
                        kind, mp, tag, lapRatio, seamRatio, grainRatio, chromaRatio, m.level.0, m.level.1, m.edge.0, m.edge.1, Date().timeIntervalSince(t0)))
            if mp < 20 {
                if line != nil {
                    check("remove quality \(kind): edge straight through the fill", m.edge.0 < 2.5, "residual \(m.edge.0) px")
                    check("remove quality \(kind): edge as sharp as outside", m.edge.1 > 0.75, "sharpness \(m.edge.1)")
                }
                // (Plain areas, the sky and the edge pictures' flat sides, have little detail to match: a ratio there means little.)
                if ["noise", "grass", "brick"].contains(kind) { check("remove quality \(kind): detail inside like around", abs(lapRatio - 1) < 0.2, "ratio \(lapRatio)") }
                check("remove quality \(kind): no seam", seamRatio < 1.15, "ratio \(seamRatio)")
                check("remove quality \(kind): grain matches", abs(grainRatio - 1) < 0.2 && abs(chromaRatio - 1) < 0.25, "light \(grainRatio), colour \(chromaRatio)")
                // A crop of at most 1200 px, the middle of the fill, at 1:1.
                let view = CGRect(x: c.x - 450, y: c.y - 300, width: 900, height: 600)
                if tag == "before" { save(picture, view, "\(kind)-0-with-object.jpg") }
                save(done, view, "\(kind)-\(tag == "before" ? "1-before" : "2-after").jpg")
            }
        }
    }
}
