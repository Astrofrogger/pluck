import CoreImage
import Foundation
import simd

/// AI Remove's fill made to sit in the photo at its own resolution. LaMa sees a square made 800 px across, so on a large photo
/// its fill is upscaled and smooth (no grain, soft edges). Here the fill keeps only its broad shapes (a blur the size of the
/// model's pixel), its light and colour are pulled to meet the photo at the hole's edge (a membrane, as Heal does), and the
/// fine layer (grain, texture, crisp edges) is quilted in from the photo around the hole: blocks of the photo's own fine
/// detail, each taken where the photo's broad shapes look most like the fill's there (so an edge's detail lands on the edge),
/// overlapped with windows that keep the grain's strength. Worked in √light so grain from a darker or brighter place fits.
enum PhotoRemoveDetail {
    nonisolated(unsafe) private static let toRoot = CIColorKernel(source: "kernel vec4 toRoot(__sample c) { return vec4(sign(c.rgb) * sqrt(abs(c.rgb)), 1.0); }")
    nonisolated(unsafe) private static let fromRoot = CIColorKernel(source: "kernel vec4 fromRoot(__sample c, vec3 lo, vec3 hi) { vec3 v = clamp(c.rgb, lo, hi); return vec4(sign(v) * v * v, 1.0); }")
    /// (fill + membrane numerator / denominator)
    nonisolated(unsafe) private static let membrane = CIColorKernel(source: """
        kernel vec4 membrane(__sample f, __sample num, __sample den) { return vec4(f.rgb + num.rgb / max(den.r, 0.0001), 1.0); }
        """)
    /// The photo on the band round the hole, `outside` elsewhere.
    nonisolated(unsafe) private static let ringed = CIColorKernel(source: """
        kernel vec4 ringed(__sample c, __sample outer, __sample hole, float outside) {
            return outer.r * (1.0 - hole.r) > 0.5 ? vec4(c.rgb, 1.0) : vec4(vec3(outside), 1.0);
        }
        """)
    /// The fine layer squared on the band round the hole (none elsewhere).
    nonisolated(unsafe) private static let squared = CIColorKernel(source: """
        kernel vec4 squared(__sample c, __sample outer, __sample hole) {
            return outer.r * (1.0 - hole.r) > 0.5 ? vec4(c.rgb * c.rgb, 1.0) : vec4(0.0);
        }
        """)
    /// (CISubtractBlendMode stops at zero: the fine layer's dark half was lost.)
    nonisolated(unsafe) private static let difference = CIColorKernel(source: "kernel vec4 difference(__sample a, __sample b) { return vec4(a.rgb - b.rgb, 1.0); }")
    nonisolated(unsafe) private static let banded = CIColorKernel(source: """
        kernel vec4 banded(__sample d, __sample outer, __sample hole) { float b = outer.r * (1.0 - hole.r); return vec4(d.rgb * b, b); }
        """)

    /// `image` with `fill` (the model's, over `square`) put into `hole` (white: filled; the area the model filled), shown over
    /// `alpha` (white: the fill shows). `band` is a little wider than `hole` (where the photo is matched to). `pixel`: the
    /// model's pixel in the photo's pixels.
    static func blended(_ image: CIImage, fill: CIImage, hole: CIImage, band: CIImage, alpha: CIImage, holeBox: CGRect, square: CGRect,
                        pixel: CGFloat, context: CIContext) -> CIImage {
        let e = image.extent
        guard let toRoot, let fromRoot, let membrane, let banded, let difference, let ringed, let squared else { return fill.applyingFilter("CIBlendWithRedMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: alpha]) }
        let sigma = Double(max(1.2, pixel * 0.8))
        let o = toRoot.apply(extent: e, arguments: [image])!.clampedToExtent()
        let f = toRoot.apply(extent: square, arguments: [fill.cropped(to: square)])!.clampedToExtent()
        let lowO = o.applyingGaussianBlur(sigma: sigma)
        let ringBox = holeBox.insetBy(dx: -CGFloat(sigma) * 4 - 8, dy: -CGFloat(sigma) * 4 - 8).intersection(e)
        // (Made crisp before the blur, so its edge comes out as soft as the photo's own at that blur.)
        let lowF = sharpened(f.cropped(to: square), around: ringed.apply(extent: ringBox, arguments: [lowO, band, hole, -1])!, hole: hole, box: ringBox, context: context)
            .clampedToExtent().applyingGaussianBlur(sigma: sigma)
        func minus(_ a: CIImage, _ b: CIImage) -> CIImage { difference.apply(extent: e, arguments: [a, b])! }
        let fineO = minus(o, lowO)
        // The membrane: what the photo's broad light is minus the fill's, on the band just outside the hole, spread in.
        let reach = Double(max(holeBox.width, holeBox.height)) * 0.25
        let gap = banded.apply(extent: e, arguments: [minus(lowO, lowF), band, hole])!
        let spread = gap.clampedToExtent().applyingGaussianBlur(sigma: reach)
        let den = spread.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        // Kept within the light and colours round the hole (a bright line drew along some edges where the model's edge and the
        // photo's detail met slightly apart): the band's broad tones' range, widened by four times its grain (so grain isn't
        // cut). (Clamped in fromRoot: the sum's alpha is two, which CIColorClamp divides by.)
        func area(_ image: CIImage, _ filter: String) -> SIMD4<Float> {
            var p = [Float](repeating: 0, count: 4)
            context.render(image.applyingFilter(filter, parameters: [kCIInputExtentKey: CIVector(cgRect: ringBox)]), toBitmap: &p, rowBytes: 16,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            return SIMD4(p[0], p[1], p[2], p[3])
        }
        let squares = area(squared.apply(extent: ringBox, arguments: [fineO, band, hole])!, "CIAreaAverage")
        let grain = 4 * (SIMD3(squares.x, squares.y, squares.z) / max(squares.w, 1e-6)).squareRoot()
        func extreme(_ filter: String, _ outside: CGFloat) -> CIVector {
            let v = area(ringed.apply(extent: ringBox, arguments: [lowO, band, hole, outside])!, filter)
            let r = SIMD3(v.x, v.y, v.z) + (outside > 0 ? -grain : grain)
            return CIVector(x: CGFloat(r.x), y: CGFloat(r.y), z: CGFloat(r.z))
        }
        let low = membrane.apply(extent: e, arguments: [lowF, spread, den])!

        // The fine layer, quilted in on the CPU over the hole plus a ring round it to take from.
        let block = min(max(Int((sigma * 6).rounded()) / 2 * 2, 16), 48)
        let margin = min(max(max(holeBox.width, holeBox.height) * 0.6, CGFloat(block * 4)), 1024)
        let work = holeBox.insetBy(dx: -margin, dy: -margin).integral.intersection(e)
        let lo = extreme("CIAreaMinimum", 1000), hi = extreme("CIAreaMaximum", 0)
        var detail = CIImage.empty()
        if let fine = quilt(fine: fineO, low: lowO, target: low, hole: hole, work: work, holeBox: holeBox.integral.intersection(work), block: block, context: context) {
            detail = fine
        }
        let made = fromRoot.apply(extent: e, arguments: [detail.composited(over: CIImage(color: .clear).cropped(to: e))
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: low]), lo, hi])!
        return made.applyingFilter("CIBlendWithRedMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: alpha]).cropped(to: e)
    }

    /// Two regions meeting at an edge (a table and the wall behind it): where the photo round the hole is two clear tones,
    /// the fill's soft blend between them is made a crisp step (along the line between the two, at its middle, so the fill's
    /// own shading stays); textures that aren't two clear tones are left as they are.
    private static func sharpened(_ low: CIImage, around: CIImage, hole: CIImage, box: CGRect, context: CIContext) -> CIImage {
        guard let snap, !box.isEmpty else { return low }
        // The band's tones, on a copy at most 400 px across (nearest pixels: the band's edge isn't mixed with what's outside).
        let k = min(1, 400 / max(box.width, box.height))
        let small = around.samplingNearest().transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY).concatenating(CGAffineTransform(scaleX: k, y: k)))
        let w = max(Int(box.width * k), 1), h = max(Int(box.height * k), 1)
        var p = [Float](repeating: 0, count: w * h * 4)
        context.render(small, toBitmap: &p, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: nil)
        var points: [SIMD3<Float>] = []
        for i in stride(from: 0, to: w * h, by: 1) where p[i * 4] >= 0 && p[i * 4 + 1] >= 0 && p[i * 4 + 2] >= 0 { points.append(SIMD3(p[i * 4], p[i * 4 + 1], p[i * 4 + 2])) }
        guard points.count >= 32 else { return low }
        // Two groups (k-means from the darkest and the brightest).
        func luma(_ v: SIMD3<Float>) -> Float { 0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z }
        var a = points.min { luma($0) < luma($1) }!, b = points.max { luma($0) < luma($1) }!
        var spread: Float = 0
        for _ in 0..<8 {
            var sa = SIMD3<Float>(), sb = SIMD3<Float>(), na: Float = 0, nb: Float = 0, sq: Float = 0
            for v in points {
                let da = simd_length_squared(v - a), db = simd_length_squared(v - b)
                if da < db { sa += v; na += 1; sq += da } else { sb += v; nb += 1; sq += db }
            }
            guard na > 0, nb > 0 else { return low }
            a = sa / na; b = sb / nb; spread = (sq / Float(points.count)).squareRoot()
            // (Each a fair share of the band: a few odd pixels aren't a region.)
            if min(na, nb) < Float(points.count) * 0.1 { return low }
        }
        // How clearly two: their distance against the spread within them (texture and grain).
        let strength = Float(min(max((simd_length(b - a) / max(spread, 1e-4) - 6) / 4, 0), 1))
        guard strength > 0 else { return low }
        return snap.apply(extent: low.extent, arguments: [low, hole, CIVector(x: CGFloat(a.x), y: CGFloat(a.y), z: CGFloat(a.z)),
                                                          CIVector(x: CGFloat(b.x), y: CGFloat(b.y), z: CGFloat(b.z)), strength]) ?? low
    }
    nonisolated(unsafe) private static let snap = CIColorKernel(source: """
        kernel vec4 snap(__sample v, __sample hole, vec3 a, vec3 b, float strength) {
            vec3 axis = b - a;
            float t = clamp(dot(v.rgb - a, axis) / max(dot(axis, axis), 1e-8), 0.0, 1.0);
            float crisp = smoothstep(0.3, 0.7, t);
            return vec4(v.rgb + axis * (crisp - t) * strength * hole.r, 1.0);
        }
        """)

    /// Quilted layers kept by what went in (a preview redrawn for a slider doesn't work them out again).
    nonisolated(unsafe) private static var kept: [Int: CIImage] = [:]
    nonisolated(unsafe) private static var keptOrder: [Int] = []
    private static let keptLock = NSLock()

    /// The photo's fine layer quilted over `holeBox` (nil when there's nothing round the hole to take from).
    private static func quilt(fine: CIImage, low: CIImage, target: CIImage, hole: CIImage, work: CGRect, holeBox: CGRect, block b: Int,
                              context: CIContext) -> CIImage? {
        let w = Int(work.width), h = Int(work.height)
        guard w > 2 * b, h > 2 * b, !holeBox.isEmpty else { return nil }
        let cell = b / 4
        // Broad shapes as cell averages (a box the size of a cell), to compare 4 × 4 points of a block.
        func boxed(_ i: CIImage) -> CIImage { i.applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: max(cell / 2, 1)]) }
        func read(_ i: CIImage) -> [Float16] {
            var p = [Float16](repeating: 0, count: w * h * 4)
            context.render(i, toBitmap: &p, rowBytes: w * 8, bounds: work, format: .RGBAh, colorSpace: nil)
            return p
        }
        var M = [UInt8](repeating: 0, count: w * h)
        context.render(hole, toBitmap: &M, rowBytes: w, bounds: work, format: .R8, colorSpace: nil)
        let F = read(fine), S = read(boxed(low)), T = read(boxed(target))
        var hasher = Hasher()
        for array in [F, S, T] { array.withUnsafeBytes { hasher.combine(bytes: $0) } }
        M.withUnsafeBytes { hasher.combine(bytes: $0) }
        hasher.combine(b); hasher.combine(holeBox.minX); hasher.combine(holeBox.minY); hasher.combine(holeBox.width); hasher.combine(holeBox.height)
        let key = hasher.finalize()
        if let known = keptLock.withLock({ kept[key] }) { return known }

        // Unknown: in the hole. A block can be taken from where none of it is.
        var sum = [Int32](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h { var row: Int32 = 0; for x in 0..<w {
            row += M[y * w + x] > 2 ? 1 : 0
            sum[(y + 1) * (w + 1) + x + 1] = sum[y * (w + 1) + x + 1] + row
        } }
        func clear(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x + b <= w && y + b <= h &&
                sum[(y + b) * (w + 1) + x + b] - sum[y * (w + 1) + x + b] - sum[(y + b) * (w + 1) + x] + sum[y * (w + 1) + x] == 0
        }
        // A block's 4 × 4 cell averages (48 numbers) and its largest step between neighbouring cells.
        func describe(_ P: [Float16], _ x: Int, _ y: Int, into d: inout [Float]) -> Float {
            for j in 0..<4 { for i in 0..<4 {
                let a = ((y + cell / 2 + j * cell) * w + x + cell / 2 + i * cell) * 4
                for k in 0..<3 { d[(j * 4 + i) * 3 + k] = Float(P[a + k]) }
            } }
            var most: Float = 0
            for j in 0..<4 { for i in 0..<4 { for k in 0..<3 {
                let v = d[(j * 4 + i) * 3 + k]
                if i < 3 { most = max(most, abs(v - d[(j * 4 + i + 1) * 3 + k])) }
                if j < 3 { most = max(most, abs(v - d[((j + 1) * 4 + i) * 3 + k])) }
            } } }
            return most
        }
        // (Rows from the top: the hole box in the buffer's places.)
        let hx0 = Int(holeBox.minX - work.minX), hx1 = Int(holeBox.maxX - work.minX)
        let hy0 = Int(work.maxY - holeBox.maxY), hy1 = Int(work.maxY - holeBox.minY)
        var rng = SplitMix(seed: UInt64(w * 7919 + h * 31 + hx0))
        var sources: [(Int, Int)] = [], descs: [Float] = [], steeps: [Float] = []
        var d = [Float](repeating: 0, count: 48)
        for _ in 0..<4000 {
            let x = Int(rng.next() % UInt64(w - b)), y = Int(rng.next() % UInt64(h - b))
            guard clear(x, y) else { continue }
            sources.append((x, y)); steeps.append(describe(S, x, y, into: &d)); descs += d
        }
        guard sources.count >= 16 else { return nil }
        let step = b / 2
        var acc = [Float](repeating: 0, count: w * h * 3), w1 = [Float](repeating: 0, count: w * h), w2 = w1
        var first = [Int32](repeating: -1, count: w * h), mixed = [Bool](repeating: false, count: w * h)
        // sin windows: overlapping halves' squares add to one (independent grain keeps its strength).
        let window = (0..<b).map { Float(sin(Double.pi * (Double($0) + 0.5) / Double(b))) }
        var td = [Float](repeating: 0, count: 48), cd = [Float](repeating: 0, count: 48)
        var prevRow: [Int: (Int, Int)] = [:]
        var y0 = hy0 - step
        while y0 < hy1 {
            var left: (Int, Int)?
            var x0 = hx0 - step
            while x0 < hx1 {
                let tx = min(max(x0, 0), w - b), ty = min(max(y0, 0), h - b)
                let tSteep = describe(T, tx, ty, into: &td)
                // Where the block lies over the photo itself (sampled every third pixel), its fine detail should go on as the photo's does.
                var known: [Int] = []
                for yy in stride(from: 0, to: b, by: 3) { for xx in stride(from: 0, to: b, by: 3) where M[(ty + yy) * w + tx + xx] <= 2 { known.append(yy * w + xx) } }
                func cost(_ desc: UnsafePointer<Float>, _ steep: Float, _ sx: Int, _ sy: Int, _ bound: Float) -> Float {
                    var c: Float = 0
                    for n in 0..<48 { let e = td[n] - desc[n]; c += e * e }
                    // As steep as the fill there: a real edge's detail isn't put on the model's soft smear (it made lines).
                    let st = steep - tSteep
                    c += 2 * st * st
                    guard c < bound, !known.isEmpty else { return c }
                    let t0 = (ty * w + tx) * 4, s0 = (sy * w + sx) * 4
                    for o in known { for k in 0..<3 { let e = Float(F[t0 + o * 4 + k]) - Float(F[s0 + o * 4 + k]); c += e * e * 0.5 } }
                    return c
                }
                var best = sources[0], bestCost = Float.infinity
                descs.withUnsafeBufferPointer { all in
                    for _ in 0..<160 {
                        let n = Int(rng.next() % UInt64(sources.count))
                        let c = cost(all.baseAddress! + n * 48, steeps[n], sources[n].0, sources[n].1, bestCost)
                        if c < bestCost { bestCost = c; best = sources[n] }
                    }
                }
                // The left and upper blocks' sources moved on (so a texture can carry on).
                for (cx, cy) in [left.map { ($0.0 + step, $0.1) }, prevRow[x0].map { ($0.0, $0.1 + step) }].compactMap({ $0 }) where clear(cx, cy) {
                    let st = describe(S, cx, cy, into: &cd)
                    let c = cd.withUnsafeBufferPointer { cost($0.baseAddress!, st, cx, cy, bestCost) }
                    if c < bestCost { bestCost = c; best = (cx, cy) }
                }
                // Then lined up to the pixel (an edge's detail a pixel off drew a second line beside it).
                if tSteep > 0.02 {
                    var fine = (best, Float.infinity)
                    for dy in -3...3 { for dx in -3...3 where clear(best.0 + dx, best.1 + dy) {
                        var c: Float = 0
                        for yy in stride(from: 0, to: b, by: 2) { for xx in stride(from: 0, to: b, by: 2) {
                            let t = ((ty + yy) * w + tx + xx) * 4, s = ((best.1 + dy + yy) * w + best.0 + dx + xx) * 4
                            for k in 0..<3 { let e = Float(T[t + k]) - Float(S[s + k]); c += e * e }
                        } }
                        if c < fine.1 { fine = ((best.0 + dx, best.1 + dy), c) }
                    } }
                    best = fine.0
                }
                for yy in 0..<b { for xx in 0..<b {
                    let t = (ty + yy) * w + tx + xx, s = (best.1 + yy) * w + best.0 + xx
                    let wt = window[xx] * window[yy]
                    for k in 0..<3 { acc[t * 3 + k] += wt * Float(F[s * 4 + k]) }
                    w1[t] += wt; w2[t] += wt * wt
                    if first[t] < 0 { first[t] = Int32(s) } else if first[t] != Int32(s) { mixed[t] = true }
                } }
                left = best; prevRow[x0] = best
                x0 += step
            }
            y0 += step
        }
        var out = [Float16](repeating: 0, count: w * h * 4)
        for t in 0..<(w * h) where w2[t] > 0 {
            // Independent pieces: by √Σw² (grain keeps its strength); one piece from all (a texture carried on): by Σw.
            let scale: Float = mixed[t] ? 1 / w2[t].squareRoot() : 1 / max(w1[t], 1e-6)
            for k in 0..<3 { out[t * 4 + k] = Float16(acc[t * 3 + k] * scale) }
            out[t * 4 + 3] = 1
        }
        let data = out.withUnsafeBufferPointer { Data(buffer: $0) }
        let made = CIImage(bitmapData: data, bytesPerRow: w * 8, size: CGSize(width: w, height: h), format: .RGBAh, colorSpace: nil)
            .transformed(by: CGAffineTransform(translationX: work.minX, y: work.minY))
        keptLock.withLock {
            kept[key] = made; keptOrder.append(key)
            if keptOrder.count > 8 { kept.removeValue(forKey: keptOrder.removeFirst()) }
        }
        return made
    }
}

/// A small seeded random source (the same fill every time for the same photo and hole).
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E9B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
