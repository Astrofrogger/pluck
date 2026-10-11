import CoreGraphics
import Foundation
import Vision

/// The logo as a vector file, traced colour by colour: every colour of the logo becomes one
/// path of smooth curves (corners kept sharp, holes left open), traced over the whole logo at
/// once so small text is as sharp as the rest.
extension LogoAnimation {
    func svg() -> String {
        let w = logo.width, h = logo.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "" }
        context.draw(logo, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Row 0 of the memory is the top of the picture, as in SVG.
        func colour(_ i: Int) -> SIMD3<Double> {
            let a = max(Double(pixels[i * 4 + 3]) / 255, 0.01)
            return SIMD3(Double(pixels[i * 4]), Double(pixels[i * 4 + 1]), Double(pixels[i * 4 + 2])) / a
        }
        let inked = (0..<(w * h)).map { pixels[$0 * 4 + 3] > 127 }
        // The logo's colours, from inside areas of one colour (where two colours meet, the edge
        // pixels are blends, not colours of their own).
        func distance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { ((a - b) * (a - b)).sum().squareRoot() }
        func solid(_ x: Int, _ y: Int, like c: SIMD3<Double>) -> Bool {
            x >= 0 && y >= 0 && x < w && y < h && pixels[(y * w + x) * 4 + 3] > 230 && distance(colour(y * w + x), c) < 24
        }
        var bins: [SIMD3<Int>: (count: Int, sum: SIMD3<Double>)] = [:]
        var total = 0
        for y in stride(from: 0, to: h, by: 2) {
            for x in stride(from: 0, to: w, by: 2) where pixels[(y * w + x) * 4 + 3] > 230 {
                let c = colour(y * w + x)
                guard solid(x - 2, y, like: c), solid(x + 2, y, like: c), solid(x, y - 2, like: c), solid(x, y + 2, like: c) else { continue }
                let key = SIMD3(Int(c.x) / 24, Int(c.y) / 24, Int(c.z) / 24)
                let bin = bins[key] ?? (0, .zero)
                bins[key] = (bin.count + 1, bin.sum + c)
                total += 1
            }
        }
        var centres: [SIMD3<Double>] = []
        for bin in bins.values.sorted(by: { $0.count > $1.count }) where bin.count >= max(total / 400, 8) {
            let mean = bin.sum / Double(bin.count)
            if centres.allSatisfy({ distance($0, mean) > 60 }) { centres.append(mean) }
            if centres.count == 10 { break }
        }
        guard !centres.isEmpty else { return "" }
        // Every inked pixel to its nearest colour.
        var owner = [Int](repeating: -1, count: w * h)
        var area = [Int](repeating: 0, count: centres.count)
        for i in 0..<(w * h) where inked[i] {
            let c = colour(i)
            let n = centres.indices.min { distance(centres[$0], c) < distance(centres[$1], c) }!
            owner[i] = n
            area[n] += 1
        }
        // Biggest colour first; each one after it grows a pixel into what's under it (never into
        // the transparent outside), so no hairline seams show between colours.
        let order = centres.indices.sorted { area[$0] > area[$1] }
        var paths: [String] = []
        for (rank, n) in order.enumerated() {
            var mask = [UInt8](repeating: 0, count: w * h)
            for i in 0..<(w * h) where owner[i] == n { mask[i] = 255 }
            if rank > 0 {
                let grown = mask
                for y in 0..<h {
                    for x in 0..<w where grown[y * w + x] == 0 && inked[y * w + x] {
                        if (x > 0 && grown[y * w + x - 1] > 0) || (x < w - 1 && grown[y * w + x + 1] > 0)
                            || (y > 0 && grown[(y - 1) * w + x] > 0) || (y < h - 1 && grown[(y + 1) * w + x] > 0) {
                            mask[y * w + x] = 255
                        }
                    }
                }
            }
            let d = Self.trace(mask, width: w, height: h).map(Self.pathData).joined(separator: " ")
            guard !d.isEmpty else { continue }
            let c = centres[n] / 255
            paths.append("  <path fill=\"\(Self.hex(CGColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: 1)))\" fill-rule=\"evenodd\" d=\"\(d)\"/>")
        }
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <svg xmlns="http://www.w3.org/2000/svg" width="\(w)" height="\(h)" viewBox="0 0 \(w) \(h)">
            \(paths.joined(separator: "\n"))
            </svg>

            """
    }

    /// The outlines (outer edges and holes) of a mask's white areas, in its pixels (origin top left).
    static func trace(_ mask: [UInt8], width w: Int, height h: Int) -> [[CGPoint]] {
        // A margin so outlines never touch the picture's edge.
        let margin = 4, fw = w + margin * 2, fh = h + margin * 2
        var padded = [UInt8](repeating: 0, count: fw * fh)
        for y in 0..<h { for x in 0..<w { padded[(y + margin) * fw + x + margin] = mask[y * w + x] } }
        guard let provider = CGDataProvider(data: Data(padded) as CFData),
              let image = CGImage(width: fw, height: fh, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: fw,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return [] }
        let request = VNDetectContoursRequest()
        request.detectsDarkOnLight = false
        request.contrastAdjustment = 1
        request.maximumImageDimension = min(max(fw, fh), 4096)
        try? VNImageRequestHandler(cgImage: image).perform([request])
        guard let observation = request.results?.first else { return [] }
        var result: [[CGPoint]] = []
        func add(_ contour: VNContour) {
            let points = contour.normalizedPoints.map {
                CGPoint(x: Double($0.x) * Double(fw) - Double(margin), y: (1 - Double($0.y)) * Double(fh) - Double(margin))
            }
            if points.count > 3 { result.append(points) }
            for child in contour.childContours { add(child) }
        }
        for contour in observation.topLevelContours { add(contour) }
        return result
    }

    private static func hex(_ colour: CGColor) -> String {
        let c = colour.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(c[0]), byte(c[min(1, c.count - 1)]), byte(c[min(2, c.count - 1)]))
    }

    /// A closed outline as SVG path data: straight between corners, smooth curves elsewhere.
    static func pathData(_ outline: [CGPoint]) -> String {
        let points = simplified(outline, tolerance: 0.7)
        let n = points.count
        guard n >= 3 else { return "" }
        // A corner where the outline turns sharply; the curve keeps its direction elsewhere.
        func turn(_ i: Int) -> Double {
            let a = points[(i - 1 + n) % n], b = points[i], c = points[(i + 1) % n]
            let u = CGPoint(x: b.x - a.x, y: b.y - a.y), v = CGPoint(x: c.x - b.x, y: c.y - b.y)
            let cross = u.x * v.y - u.y * v.x, dot = u.x * v.x + u.y * v.y
            return abs(atan2(cross, dot))
        }
        let corner = (0..<n).map { turn($0) > 0.7 }
        func f(_ v: CGFloat) -> String { String(format: "%.1f", v) }
        var d = "M\(f(points[0].x)) \(f(points[0].y))"
        for i in 0..<n {
            let p0 = points[(i - 1 + n) % n], p1 = points[i], p2 = points[(i + 1) % n], p3 = points[(i + 2) % n]
            if corner[i] && corner[(i + 1) % n] {
                d += " L\(f(p2.x)) \(f(p2.y))"
                continue
            }
            // Catmull–Rom tangents, flattened at a corner so it stays sharp.
            let t1 = corner[i] ? CGPoint(x: p2.x - p1.x, y: p2.y - p1.y) : CGPoint(x: (p2.x - p0.x) / 2, y: (p2.y - p0.y) / 2)
            let t2 = corner[(i + 1) % n] ? CGPoint(x: p2.x - p1.x, y: p2.y - p1.y) : CGPoint(x: (p3.x - p1.x) / 2, y: (p3.y - p1.y) / 2)
            let c1 = CGPoint(x: p1.x + t1.x / 3, y: p1.y + t1.y / 3), c2 = CGPoint(x: p2.x - t2.x / 3, y: p2.y - t2.y / 3)
            d += " C\(f(c1.x)) \(f(c1.y)) \(f(c2.x)) \(f(c2.y)) \(f(p2.x)) \(f(p2.y))"
        }
        return d + " Z"
    }

    /// Fewer points along the same outline (Ramer–Douglas–Peucker, closed).
    static func simplified(_ points: [CGPoint], tolerance: Double) -> [CGPoint] {
        guard points.count > 4 else { return points }
        func reduce(_ part: ArraySlice<CGPoint>) -> [CGPoint] {
            guard let first = part.first, let last = part.last, part.count > 2 else { return Array(part) }
            let dx = last.x - first.x, dy = last.y - first.y
            let length = max(hypot(dx, dy), 0.0001)
            var worst = part.startIndex, distance = 0.0
            for i in part.indices.dropFirst().dropLast() {
                let d = abs(dy * (part[i].x - first.x) - dx * (part[i].y - first.y)) / length
                if d > distance { distance = d; worst = i }
            }
            guard distance > tolerance else { return [first, last] }
            return reduce(part[part.startIndex...worst]).dropLast() + reduce(part[worst...part.endIndex - 1])
        }
        // Split at the point farthest from the start, so the closed loop has two open halves.
        let far = points.indices.max { hypot(points[$0].x - points[0].x, points[$0].y - points[0].y)
            < hypot(points[$1].x - points[0].x, points[$1].y - points[0].y) } ?? points.count / 2
        let loop = points + [points[0]]
        let a = reduce(loop[0...far]), b = reduce(loop[far...])
        return Array((a.dropLast() + b).dropLast())
    }
}
