import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

/// Perspective (keystone) correction, after straightening and before the crop: the picture's corners pulled in or out as a
/// projective warp, then scaled so its frame stays filled (no empty corners: Lightroom's Constrain Crop), so the crop keeps
/// working on the corrected picture. Nil in PhotoAdjustments when untouched, so old edits save and render as before.
struct PhotoPerspective: Codable, Hashable {
    /// -100…100: + widens the top (tall things leaning in at the top stand up), + makes the left side taller.
    var vertical = 0.0, horizontal = 0.0
    /// -100…100: + wider, − taller.
    var aspect = 0.0
    /// Percent, 100…150 (100: just filled).
    var scale = 100.0

    var isDefault: Bool { self == PhotoPerspective() }

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys, _ fallback: Double) -> Double { ((try? c.decodeIfPresent(Double.self, forKey: key)) ?? nil) ?? fallback }
        vertical = value(.vertical, 0); horizontal = value(.horizontal, 0); aspect = value(.aspect, 0); scale = value(.scale, 100)
    }

    /// Where the picture's corners go, for a w × h frame: top left, top right, bottom right, bottom left, from its middle
    /// (y up, as Core Image counts). Scaled so the frame lies inside (plus a pixel's margin against soft edges).
    func corners(width w: Double, height h: Double) -> [SIMD2<Double>] {
        let t = min(max(vertical, -100), 100) / 250, u = min(max(horizontal, -100), 100) / 250
        let fx = pow(2, min(max(aspect, -100), 100) / 300), fy = 1 / fx
        let quad = [SIMD2(-(1 + t), 1 + u), SIMD2(1 + t, 1 - u), SIMD2(1 - t, -(1 - u)), SIMD2(-(1 - t), -(1 + u))]
            .map { SIMD2($0.x * w / 2 * fx, $0.y * h / 2 * fy) }
        let frame = [SIMD2(-w / 2, h / 2), SIMD2(w / 2, h / 2), SIMD2(w / 2, -h / 2), SIMD2(-w / 2, -h / 2)]
        // The smallest k with every frame corner inside k × quad (each edge's outward normal; the quad goes clockwise).
        var k = 0.0
        for i in 0..<4 {
            let a = quad[i], b = quad[(i + 1) % 4]
            let n = SIMD2(a.y - b.y, b.x - a.x), d = (n * a).sum()
            for c in frame { k = max(k, (n * c).sum() / d) }
        }
        k *= 1 + 2 / max(min(w, h), 1)
        return quad.map { $0 * k * min(max(scale, 100), 150) / 100 }
    }

    /// The picture with this perspective, the same size.
    func warped(_ image: CIImage) -> CIImage {
        let e = image.extent
        let q = corners(width: e.width, height: e.height).map { CGPoint(x: e.midX + $0.x, y: e.midY + $0.y) }
        let f = CIFilter.perspectiveTransform()
        f.inputImage = image
        f.topLeft = q[0]; f.topRight = q[1]; f.bottomRight = q[2]; f.bottomLeft = q[3]
        return (f.outputImage ?? image).cropped(to: e)
    }

    /// The same warp as a 3 × 3 homography on points from the frame's middle (y up), for measuring lines.
    func homography(width w: Double, height h: Double) -> [Double] {
        let from = [SIMD2(-w / 2, h / 2), SIMD2(w / 2, h / 2), SIMD2(w / 2, -h / 2), SIMD2(-w / 2, -h / 2)]
        return Self.homography(from, corners(width: w, height: h))
    }

    /// The homography taking four points to four others (h33 = 1), by Gaussian elimination.
    static func homography(_ from: [SIMD2<Double>], _ to: [SIMD2<Double>]) -> [Double] {
        var m = [[Double]]()
        for i in 0..<4 {
            let (x, y, X, Y) = (from[i].x, from[i].y, to[i].x, to[i].y)
            m.append([x, y, 1, 0, 0, 0, -x * X, -y * X, X])
            m.append([0, 0, 0, x, y, 1, -x * Y, -y * Y, Y])
        }
        for col in 0..<8 {
            let pivot = (col..<8).max { abs(m[$0][col]) < abs(m[$1][col]) }!
            m.swapAt(col, pivot)
            guard abs(m[col][col]) > 1e-12 else { return [1, 0, 0, 0, 1, 0, 0, 0, 1] }
            for row in 0..<8 where row != col {
                let f = m[row][col] / m[col][col]
                for k in col...8 { m[row][k] -= f * m[col][k] }
            }
        }
        return (0..<8).map { m[$0][8] / m[$0][$0] } + [1]
    }

    static func apply(_ h: [Double], _ p: SIMD2<Double>) -> SIMD2<Double> {
        let z = h[6] * p.x + h[7] * p.y + h[8]
        return SIMD2((h[0] * p.x + h[1] * p.y + h[2]) / z, (h[3] * p.x + h[4] * p.y + h[5]) / z)
    }
}

// MARK: - Finding lines

extension PhotoPerspective {
    /// A straight edge in the picture: two points on it from the middle (y up, pixels of the measured copy), and how strong.
    struct Line { var a: SIMD2<Double>, b: SIMD2<Double>, weight: Double }

    /// What the auto buttons measure, on the photo with no straightening or perspective.
    struct Reading {
        var width: Double, height: Double
        var vertical: [Line], horizontal: [Line]
        /// Vision's horizon: the turn (degrees, + anticlockwise) that levels it.
        var horizon: Double?
    }

    nonisolated static func read(_ image: CGImage) -> Reading? {
        let scale = min(1, 1024 / Double(max(image.width, image.height)))
        let w = max(Int(Double(image.width) * scale), 8), h = max(Int(Double(image.height) * scale), 8)
        var gray = [UInt8](repeating: 0, count: w * h)
        let drawn = gray.withUnsafeMutableBytes { buffer -> Bool in
            guard let c = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            c.interpolationQuality = .medium
            c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        let request = VNDetectHorizonRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        // (Vision's angle, measured: a horizon rising 3° to the right reads −3°, the turn that levels it.)
        let horizon = request.results?.first.flatMap { $0.confidence > 0.3 ? Double($0.angle) * 180 / .pi : nil }
        return Reading(width: Double(w), height: Double(h), vertical: lines(gray, w, h, transposed: false),
                       horizontal: lines(gray, w, h, transposed: true), horizon: horizon)
    }

    /// Long, near-vertical edges (within 15°; `transposed`: near-horizontal ones), by a Hough transform over the
    /// Sobel edges, each edge pixel voting only near its own direction. Lines shorter than an eighth of the side are left out.
    nonisolated static func lines(_ gray: [UInt8], _ width: Int, _ height: Int, transposed: Bool) -> [Line] {
        let span = 15.0, step = 0.25
        let bins = Int(2 * span / step) + 1
        // In the transposed picture x and y swap, so horizontal lines are found as vertical ones.
        let w = transposed ? height : width, h = transposed ? width : height
        func g(_ x: Int, _ y: Int) -> Double { Double(transposed ? gray[x * width + y] : gray[y * width + x]) }
        let rhoCount = w + 2 * h, rhoOffset = h
        var votes = [Float](repeating: 0, count: bins * rhoCount)
        let cosines = (0..<bins).map { cos((-span + Double($0) * step) * .pi / 180) }
        let sines = (0..<bins).map { sin((-span + Double($0) * step) * .pi / 180) }
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let gx = g(x + 1, y - 1) + 2 * g(x + 1, y) + g(x + 1, y + 1) - g(x - 1, y - 1) - 2 * g(x - 1, y) - g(x - 1, y + 1)
                let gy = g(x - 1, y + 1) + 2 * g(x, y + 1) + g(x + 1, y + 1) - g(x - 1, y - 1) - 2 * g(x, y - 1) - g(x + 1, y - 1)
                guard gx * gx + gy * gy > 60 * 60 else { continue }
                // The edge's normal, folded to −90…90° (light to dark or dark to light is the same line).
                var angle = atan2(gy, gx) * 180 / .pi
                if angle > 90 { angle -= 180 } else if angle < -90 { angle += 180 }
                guard abs(angle) <= span + 2 else { continue }
                let centre = Int(((angle + span) / step).rounded())
                for b in max(centre - 8, 0)...min(centre + 8, bins - 1) {
                    let rho = Int((Double(x) * cosines[b] + Double(y) * sines[b]).rounded()) + rhoOffset
                    if rho >= 0, rho < rhoCount { votes[b * rhoCount + rho] += 1 }
                }
            }
        }
        // The strongest lines, each clearing its neighbourhood.
        var found: [Line] = []
        let least = Float(Double(h) / 8)
        while found.count < 40 {
            guard let best = votes.indices.max(by: { votes[$0] < votes[$1] }), votes[best] >= least else { break }
            let b = best / rhoCount, rho = Double(best % rhoCount - rhoOffset)
            let c = cosines[b], s = sines[b]
            // Where the line x·cos + y·sin = rho crosses the top and the bottom of the picture (bitmap rows from the top).
            var top = SIMD2(rho / c, 0.0), bottom = SIMD2((rho - Double(h) * s) / c, Double(h))
            if transposed { top = SIMD2(top.y, top.x); bottom = SIMD2(bottom.y, bottom.x) }
            func centred(_ p: SIMD2<Double>) -> SIMD2<Double> { SIMD2(p.x - Double(width) / 2, Double(height) / 2 - p.y) }
            found.append(Line(a: centred(top), b: centred(bottom), weight: Double(votes[best])))
            for bb in max(b - 16, 0)...min(b + 16, bins - 1) {
                for r in max(Int(rho) + rhoOffset - 10, 0)...min(Int(rho) + rhoOffset + 10, rhoCount - 1) { votes[bb * rhoCount + r] = 0 }
            }
        }
        return found
    }

    /// A line's lean from upright (degrees, + leaning right at the top).
    nonisolated static func lean(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let d = a.y >= b.y ? a - b : b - a
        return atan2(d.x, d.y) * 180 / .pi
    }

    /// Level: the turn (degrees, + anticlockwise, as Straighten) that levels the photo: Vision's horizon, else the
    /// strongest near-horizontal lines (their weighted median), else the near-vertical ones.
    nonisolated static func level(_ r: Reading) -> Double? {
        if let horizon = r.horizon { return horizon }
        let lines = r.horizontal.isEmpty ? r.vertical : r.horizontal
        guard !lines.isEmpty else { return nil }
        // A horizontal line's lean from level (+ rising to the right) is its transposed lean, mirrored; an upright's is its lean.
        let leans = lines.map { line -> (Double, Double) in
            let d = line.b - line.a
            let tilt = r.horizontal.isEmpty ? -lean(line.a, line.b) : atan(d.y / (abs(d.x) > 1e-9 ? d.x : 1e-9)) * 180 / .pi
            return (tilt, line.weight)
        }.sorted { $0.0 < $1.0 }
        let half = leans.reduce(0) { $0 + $1.1 } / 2
        var sum = 0.0
        for (tilt, weight) in leans { sum += weight; if sum >= half { return -tilt } }
        return nil
    }

    /// Vertical: the turn (degrees) and the vertical keystone that make the near-vertical lines upright and parallel,
    /// keeping the other perspective settings. Nil with fewer than two lines, or when it would turn more than 10°.
    nonisolated static func upright(_ r: Reading, keeping p: PhotoPerspective) -> (turn: Double, vertical: Double)? {
        guard r.vertical.count >= 2 else { return nil }
        let w = r.width, h = r.height
        func cost(_ turn: Double, _ v: Double) -> Double {
            var q = p
            q.vertical = v
            let hm = q.homography(width: w, height: h)
            let a = turn * .pi / 180
            // Straighten turns about the middle and scales up to fill (as Core Image's, measured).
            let fill = cos(abs(a)) + max(w / h, h / w) * sin(abs(a))
            func moved(_ p: SIMD2<Double>) -> SIMD2<Double> {
                apply(hm, SIMD2(p.x * cos(a) - p.y * sin(a), p.x * sin(a) + p.y * cos(a)) * fill)
            }
            return r.vertical.reduce(0) { total, line in
                let e = lean(moved(line.a), moved(line.b))
                return total + line.weight * min(e * e, 16)
            }
        }
        var best = (turn: 0.0, vertical: 0.0, cost: cost(0, 0))
        for turn in stride(from: -10.0, through: 10, by: 0.5) {
            for v in stride(from: -100.0, through: 100, by: 2) {
                let c = cost(turn, v)
                if c < best.cost { best = (turn, v, c) }
            }
        }
        // Finer, around the best.
        let coarse = best
        for turn in stride(from: coarse.turn - 0.5, through: coarse.turn + 0.5, by: 0.05) {
            for v in stride(from: max(coarse.vertical - 2, -100), through: min(coarse.vertical + 2, 100), by: 0.1) {
                let c = cost(turn, v)
                if c < best.cost { best = (turn, v, c) }
            }
        }
        guard abs(best.turn) <= 10 else { return nil }
        return ((best.turn * 10).rounded() / 10, best.vertical.rounded())
    }
}
