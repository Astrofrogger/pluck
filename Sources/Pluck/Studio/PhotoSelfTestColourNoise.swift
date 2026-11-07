import CoreImage

/// Colour noise reduction (Pluck's own, not Apple's): it takes the blotches out, keeps the shadows' colour and the edges.
extension PhotoSelfTest {
    static func colourNoise() {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        func image(_ w: Int, _ h: Int, _ colour: (Int, Int) -> SIMD3<Float>) -> CIImage {
            var pixels = [Float](repeating: 1, count: w * h * 4)
            for y in 0..<h { for x in 0..<w { let c = colour(x, y), i = (y * w + x) * 4; pixels[i] = c.x; pixels[i + 1] = c.y; pixels[i + 2] = c.z } }
            return CIImage(bitmapData: pixels.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: w * 16, size: CGSize(width: w, height: h),
                           format: .RGBAf, colorSpace: space)
        }
        func floats(_ image: CIImage) -> [Float] {
            let e = image.extent.integral
            var pixels = [Float](repeating: 0, count: Int(e.width) * Int(e.height) * 4)
            pixels.withUnsafeMutableBytes { PhotoEngine.context.render(image, toBitmap: $0.baseAddress!, rowBytes: Int(e.width) * 16, bounds: e, format: .RGBAf, colorSpace: space) }
            return pixels
        }
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func gauss() -> Float {
            func u() -> Float { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return (Float(seed >> 40) + 0.5) / Float(1 << 24) }
            return (-2 * log(u())).squareRoot() * cos(2 * .pi * u())
        }
        // A deep shadow as the RAW decode gives it (the measured cabinet side): its noise as big as the light, in blotches 4 px wide.
        let n = 256, mean = SIMD3<Float>(0.0010, 0.00237, 0.00157)
        let blotches = (0..<(n / 4 * n / 4)).map { _ in SIMD3(gauss(), gauss(), gauss()) * 0.002 }
        let shadow = image(n, n) { x, y in mean + blotches[(y / 4) * (n / 4) + x / 4] + SIMD3(gauss(), gauss(), gauss()) * 0.001 }
        let before = floats(shadow), after = floats(PhotoRender.colourNoiseReduced(shadow, amount: 25, fullLongEdge: Double(n)))
        func average(_ p: [Float]) -> SIMD3<Double> {
            var s = SIMD3<Double>(); for i in stride(from: 0, to: p.count, by: 4) { s += SIMD3(Double(p[i]), Double(p[i + 1]), Double(p[i + 2])) }
            return s / Double(p.count / 4)
        }
        // How much the colour (each channel less the brightness) varies from one 4 px block to the next.
        func blotchiness(_ p: [Float]) -> Double {
            var sum = 0.0, count = 0.0
            for by in 0..<(n / 4) { for bx in 0..<(n / 4) {
                var c = SIMD3<Double>()
                for y in 0..<4 { for x in 0..<4 { let i = ((by * 4 + y) * n + bx * 4 + x) * 4; c += SIMD3(Double(p[i]), Double(p[i + 1]), Double(p[i + 2])) } }
                let y = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
                let d = c / 16 - SIMD3(repeating: y / 16) - (SIMD3<Double>(mean) - SIMD3(repeating: 0.2126 * Double(mean.x) + 0.7152 * Double(mean.y) + 0.0722 * Double(mean.z)))
                sum += (d * d).sum(); count += 1
            } }
            return (sum / count).squareRoot()
        }
        let m0 = average(before), m1 = average(after), b0 = blotchiness(before), b1 = blotchiness(after)
        let kept = abs(m1.x / m1.y - m0.x / m0.y) < 0.02 && abs(m1.z / m1.y - m0.z / m0.y) < 0.02 && abs(m1.y / m0.y - 1) < 0.01
        check("colour noise keeps the shadows' colour", kept, "red and blue to green as before, \(m0); got \(m1)")
        check("colour noise takes the blotches out", b1 < b0 / 3, "under a third of \(b0); got \(b1)")
        let off = floats(PhotoRender.colourNoiseReduced(shadow, amount: 0, fullLongEdge: Double(n)))
        check("colour noise 0 is off", zip(before, off).allSatisfy { abs($0 - $1) < 1e-6 }, "the photo as it is")

        // A red and a green field side by side: no colour crosses the edge.
        let edge = image(n, n) { x, _ in x < n / 2 ? SIMD3(0.4, 0.05, 0.05) : SIMD3(0.05, 0.4, 0.05) }
        let e = floats(PhotoRender.colourNoiseReduced(edge, amount: 25, fullLongEdge: Double(n) * 8))
        let row = n / 2 * n * 4, left = e[row + (n / 2 - 3) * 4 + 1], right = e[row + (n / 2 + 2) * 4]
        check("colour noise keeps edges", left < 0.06 && right < 0.06, "green 3 px left of the edge and red 2 px right under 0.06; got \(left), \(right)")

        // Version 3, as Lightroom's Colour 25: a flat patch's colour noise gone at every scale from 1 to 16 px (90% of its
        // variance), its colour kept; edges kept.
        let m = 512, flat = SIMD3<Float>(0.02, 0.03, 0.025)
        let grainy = image(m, m) { _, _ in flat + SIMD3(gauss(), gauss(), gauss()) * 0.006 }
        let g0 = floats(grainy), g1 = floats(PhotoRender.colourNoiseReduced(grainy, amount: 25, fullLongEdge: Double(m), wide: true))
        let fm = SIMD3<Double>(flat), fy = 0.2126 * fm.x + 0.7152 * fm.y + 0.0722 * fm.z
        // Block means' colour off the patch's own (at their brightness), squared.
        func chromaVariance(_ p: [Float], _ s: Int) -> Double {
            var sum = 0.0, count = 0.0
            for by in 0..<(m / s) { for bx in 0..<(m / s) {
                var c = SIMD3<Double>()
                for y in 0..<s { for x in 0..<s { let i = ((by * s + y) * m + bx * s + x) * 4; c += SIMD3(Double(p[i]), Double(p[i + 1]), Double(p[i + 2])) } }
                c /= Double(s * s)
                let d = c - fm * ((0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z) / fy)
                sum += (d * d).sum(); count += 1
            } }
            return sum / count
        }
        let scales = [1, 2, 4, 8, 16], cut = scales.map { 1 - chromaVariance(g1, $0) / chromaVariance(g0, $0) }
        let wm = average(g1), gm = average(g0)
        check("wide colour noise gone at every scale", cut.allSatisfy { $0 >= 0.9 } && abs(wm.x / wm.y - gm.x / gm.y) < 0.02 && abs(wm.z / wm.y - gm.z / gm.y) < 0.02,
              "at least 90% of the colour variance gone at 1, 2, 4, 8 and 16 px, the colour kept; got \(cut), \(gm) → \(wm)")
        let we = floats(PhotoRender.colourNoiseReduced(edge, amount: 25, fullLongEdge: Double(n) * 4, wide: true))
        let wl = we[row + (n / 2 - 3) * 4 + 1], wr = we[row + (n / 2 + 2) * 4]
        check("wide colour noise keeps edges", wl < 0.06 && wr < 0.06, "green 3 px left of the edge and red 2 px right under 0.06; got \(wl), \(wr)")

        // Version 3's luminance noise reduction: six bands a stop apart (2⁻⁹ to 2⁻⁴ of white), each with a RAW's noise
        // (variance 4e-5·Y + 1e-7, as measured on one): the noise found, the bands' grain mostly gone and their brightness
        // kept, and the step between two bands as sharp as it was.
        let bands = 6, bw = 128, noisy = image(bands * bw, 384) { x, _ in
            let y = exp2(Float(x / bw) - 9)
            return SIMD3(repeating: y + gauss() * (4e-5 * y + 1e-7).squareRoot())
        }
        let model = PhotoRender.noiseModel(noisy)
        let lumaBefore = floats(noisy), lumaAfter = floats(PhotoRender.lumaNoiseReduced(noisy, amount: 0, scale: 1))
        let lumaMore = floats(PhotoRender.lumaNoiseReduced(noisy, amount: 100, scale: 1))
        func band(_ p: [Float], _ k: Int) -> (mean: Double, sd: Double) {
            var s = 0.0, ss = 0.0, n = 0.0
            for y in 20..<364 { for x in (k * bw + 20)..<(k * bw + bw - 20) { let v = Double(p[(y * bands * bw + x) * 4 + 1]); s += v; ss += v * v; n += 1 } }
            return (s / n, (ss / n - s * s / n / n).squareRoot())
        }
        let grainLeft = (0..<bands).map { band(lumaAfter, $0).sd / band(lumaBefore, $0).sd }, more = (0..<bands).map { band(lumaMore, $0).sd / band(lumaBefore, $0).sd }
        let level = (0..<bands).map { band(lumaAfter, $0).mean / band(lumaBefore, $0).mean - 1 }
        // Columns either side of the step from band 2 to band 3, averaged down the band.
        func column(_ p: [Float], _ x: Int) -> Double { (20..<364).map { Double(p[($0 * bands * bw + x) * 4 + 1]) }.reduce(0, +) / 344 }
        let lo = band(lumaBefore, 2).mean, hi = band(lumaBefore, 3).mean, step = hi - lo
        let jump = (column(lumaAfter, 3 * bw) - column(lumaAfter, 3 * bw - 1)) / step
        let below = (column(lumaAfter, 3 * bw - 7) - lo) / step, above = (hi - column(lumaAfter, 3 * bw + 6)) / step
        note("luminance noise: model \(String(describing: model)); grain left \(grainLeft), at 100 \(more); level \(level); step jump \(jump), 6 px out \(below), \(above)")
        check("luminance noise found", model.map { abs($0.a / 4e-5 - 1) < 0.35 } ?? false, "variance 4e-5·Y + 1e-7; got \(String(describing: model))")
        check("luminance noise reduced, edges kept", grainLeft.allSatisfy { $0 < 0.5 } && more.indices.allSatisfy { more[$0] < grainLeft[$0] } && level.allSatisfy { abs($0) < 0.01 }
              && jump > 0.4 && abs(below) < 0.15 && abs(above) < 0.15,
              "each band's grain under half, more at Luminance 100, brightness within 1%, the step (12 times the noise) still a step: over 40% of it from one pixel to the next, under 15% of it 6 px out; got \(grainLeft), \(more), \(level), \(jump), \(below), \(above)")

        // Detail first: fine lines 3 to 6 times the noise (decoder 8's, the noisier) keep their contrast through version 3's
        // default RAW path (luminance and colour noise reduction, then the develop at +4.5 stops), against the same lines
        // without noise through the develop alone. Lines across the six bands; each line's depth in its band's noise.
        let lines: [(row: Int, width: Int, depth: Float)] = [(60, 1, 4), (120, 2, 4), (180, 1, 6), (240, 2, 6), (300, 2, 3)]
        func lined(_ noise: Bool) -> CIImage {
            image(bands * bw, 384) { x, row in
                let y = exp2(Float(x / bw) - 9), sd = (4e-5 * y + 1e-7).squareRoot()
                let dip = lines.first { row >= $0.row && row < $0.row + $0.width }.map { $0.depth * sd } ?? 0
                return SIMD3(repeating: y - dip + (noise ? gauss() * sd : 0))
            }
        }
        var v3RAW = PhotoAdjustments(); v3RAW.exposure = 4.5
        func developed(_ i: CIImage) -> [Float] { floats(PhotoRender.adjusted(i, v3RAW, isRaw: true, kelvin: 5500).cropped(to: i.extent)) }
        let linesClean = developed(lined(false))
        let linesNoisy = developed(PhotoRender.colourNoiseReduced(PhotoRender.lumaNoiseReduced(lined(true), amount: 0, scale: 1), amount: 25,
                                                                  fullLongEdge: Double(bands * bw), wide: true))
        // Each line's depth under the rows either side (6 to 12 px off), averaged along it in bands 1 to 4, green channel.
        func depth(_ p: [Float], _ l: (row: Int, width: Int, depth: Float)) -> Double {
            func rowMean(_ r: Int) -> Double {
                var sum = 0.0
                for k in 1..<5 { for x in (k * bw + 10)..<(k * bw + bw - 10) { sum += Double(p[(r * bands * bw + x) * 4 + 1]) } }
                return sum / 432
            }
            let rows: [Int] = Array(l.row - 12..<l.row - 6) + Array(l.row + l.width + 6..<l.row + l.width + 12)
            let side = rows.map(rowMean).reduce(0, +) / 12
            return side - (l.row..<l.row + l.width).map(rowMean).reduce(0, +) / Double(l.width)
        }
        let linesKept = lines.map { depth(linesNoisy, $0) / depth(linesClean, $0) }
        note("fine lines through version 3 (1 px 4σ, 2 px 4σ, 1 px 6σ, 2 px 6σ, 2 px 3σ): contrast kept \(linesKept.map { ($0 * 100).rounded() / 100 })")
        check("version 3 keeps fine lines", zip(linesKept, [0.55, 0.7, 0.7, 0.8, 0.6]).allSatisfy { $0 > $1 },
              "over 55%, 70%, 70%, 80% and 60% of each line's contrast (the earlier noise reduction kept 4–34%); got \(linesKept)")

        // No halo: a step through version 3's develop at Sharpen 40 (Lightroom's default) overshoots by under 3% of it,
        // and from 3 px out it's flat (within 2%). (11% before sharpening was held to the light around it.)
        var sharp40 = PhotoAdjustments(); sharp40.sharpen = 40
        let stepped = floats(PhotoRender.adjusted(image(64, 16) { x, _ in SIMD3(repeating: x < 32 ? 0.05 : 0.2) }, sharp40, isRaw: true, kelvin: 5500))
        let stepRow: [Double] = (0..<64).map { Double(stepped[(8 * 64 + $0) * 4 + 1]) }
        let stepLo: Double = stepRow[4..<12].reduce(0, +) / 8
        let stepHi: Double = stepRow[52..<60].reduce(0, +) / 8
        let stepSize = stepHi - stepLo
        let over: Double = stepRow[32..<40].max()! - stepHi, under: Double = stepLo - stepRow[24..<32].min()!
        let overshoot = max(over, under) / stepSize
        var halo = 0.0
        for x in 35..<52 { halo = max(halo, abs(stepRow[x] - stepHi) / stepSize) }
        for x in 12..<29 { halo = max(halo, abs(stepRow[x] - stepLo) / stepSize) }
        note("version 3 step at Sharpen 40: overshoot \(overshoot), 3 px out \(halo)")
        check("version 3 sharpens without halos", overshoot < 0.03 && halo < 0.02, "overshoot under 3% of the step, flat from 3 px out (2%); got \(overshoot), \(halo)")

        // Classic keeps a dark colour's ratios (as Adobe's curve does); Neutral is as it was.
        func developed(_ c: SIMD3<Float>, _ profile: PhotoEngine.Profile) -> SIMD3<Float> {
            var a = PhotoAdjustments()
            a.profile = profile
            a.exposure = 3
            let p = floats(PhotoEngine.develop(image(8, 8) { _, _ in c }, a, isRaw: true))
            return SIMD3(p[36], p[37], p[38])
        }
        func saturation(_ c: SIMD3<Float>) -> Float { (c.max() - c.min()) / max(c.max(), 1e-6) }
        let teal = SIMD3<Float>(0.0010, 0.00237, 0.00157)
        let classic = developed(teal, .adobe), neutral = developed(teal, .neutral)
        // (As colourful as the light after Classic's own colour table: ColourProfiles.)
        let s = ColourProfiles.mul(PhotoEngine.fromProPhoto, (PhotoAdjustments.currentProcess >= 4 ? ColourProfiles.change4(.adobe) : ColourProfiles.change(.adobe))(ColourProfiles.mul(PhotoEngine.toProPhoto, SIMD3<Double>(teal))))
        let tabled = SIMD3<Float>(Float(s.x), Float(s.y), Float(s.z))
        check("classic keeps dark colours", abs(saturation(classic) - saturation(tabled)) < 0.03 && saturation(neutral) > saturation(teal) + 0.05,
              "Classic as colourful as the light through its table, \(saturation(tabled)), Neutral more; got \(classic) (\(saturation(classic))), Neutral \(saturation(neutral))")

        // The real thing (a photo kept outside the repo, when it's there): Colour 25 leaves a deep shadow its colour.
        let raw = URL(fileURLWithPath: photos).deletingLastPathComponent().appendingPathComponent("greencast/DSC01962.ARW").path
        guard FileManager.default.fileExists(atPath: raw) else { skip("colour noise on a RAW keeps its shadows", "no test RAW"); return }
        func shadowColour(_ colour: Double, size: Int = 3000) -> SIMD3<Double>? {
            guard let image = PhotoRender.source(raw, maxSize: size, noise: 0, color: colour) else { return nil }
            let x = image.extent
            let spot = CGRect(x: x.width * 0.537, y: x.height * 0.24, width: x.width * 0.023, height: x.height * 0.16)
            var p = [Float](repeating: 0, count: 4)
            PhotoEngine.context.render(image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: spot)]), toBitmap: &p,
                                       rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: space)
            return SIMD3(Double(p[0]), Double(p[1]), Double(p[2]))
        }
        guard let none = shadowColour(0), let some = shadowColour(25) else { check("colour noise on a RAW keeps its shadows", false, "not decoded"); return }
        check("colour noise on a RAW keeps its shadows", abs(some.x / some.y - none.x / none.y) < 0.05 && abs(some.z / some.y - none.z / none.y) < 0.05,
              "red and blue to green as without, \(none); got \(some)")
        // A small picture (a preview) has the full size's shadows: Apple's quarter-size decode loses their red and blue.
        guard let full = shadowColour(0, size: 0), let small = shadowColour(0, size: 1500) else { check("raw preview keeps its shadows", false, "not decoded"); return }
        check("raw preview keeps its shadows", abs(small.x / small.y - full.x / full.y) < 0.06 && abs(small.z / small.y - full.z / full.y) < 0.06,
              "red and blue to green as at full size, \(full); got \(small)")
        // Only version 3 gets the luminance noise reduction: versions 1 and 2 decode as they did.
        var v2 = PhotoAdjustments(); v2.process = 2
        var v3 = PhotoAdjustments(); v3.process = 3
        func decode(_ a: PhotoAdjustments, luma: Bool) -> [Float]? {
            PhotoRender.source(raw, maxSize: 600, noise: 0, color: 25, raw: PhotoRender.RawSettings(a), luma: luma).map(floats)
        }
        guard let old = decode(v2, luma: false), let oldLuma = decode(v2, luma: true), let new = decode(v3, luma: false), let newLuma = decode(v3, luma: true)
        else { check("luminance noise reduction only in version 3", false, "not decoded"); return }
        check("luminance noise reduction only in version 3", old == oldLuma && new != newLuma, "version 2 the same with it asked for, version 3 not")
        // The real thing at full size, version 3's base: the fine thread lying on the floor by the pot (a dark line on a lifted
        // floor). Its depth under the floor beside it, averaged along 180 px of it, and against the floor's pixel noise.
        // Decoder 8 with the earlier noise reduction: depth 0.065, 0.34 of the noise; decoder 9, softened and lifted (as
        // Lightroom's levels), with this one: 0.23, 2.4.
        if let thread = PhotoRender.source(raw, maxSize: 0, noise: 0, color: 25, raw: PhotoRender.RawSettings(v3), luma: true) {
            // Decode rows 3080… and columns 1300… (6000 × 4000, before the 24 px edge goes), the bitmap's first row the top.
            let top = thread.extent.height - (3080 - 24)
            var p = [Float](repeating: 0, count: 200 * 100 * 4)
            PhotoEngine.context.render(thread, toBitmap: &p, rowBytes: 200 * 16, bounds: CGRect(x: 1300 - 24, y: top - 100, width: 200, height: 100),
                                       format: .RGBAf, colorSpace: space)
            func Y(_ r: Int, _ c: Int) -> Double { let i = (r * 200 + c) * 4; return 0.2126 * Double(p[i]) + 0.7152 * Double(p[i + 1]) + 0.0722 * Double(p[i + 2]) }
            var profile = [Double](repeating: 0, count: 29), sides: [[Double]] = []
            for c in 10..<190 {
                let r = Int((37.98 + 0.05439 * Double(c) + 0.000265 * Double(c * c)).rounded())
                let column: [Double] = (r - 14...r + 14).map { Y($0, c) }
                for k in 0..<29 { profile[k] += column[k] / 180 }
                sides.append(Array(column.prefix(6) + column.suffix(6)))
            }
            let level: Double = (profile.prefix(6).reduce(0, +) + profile.suffix(6).reduce(0, +)) / 12
            let lineDepth = (level - profile[12...16].min()!) / level
            // The floor's noise: each side pixel against its own position's mean along the thread.
            var squares = 0.0
            for k in 0..<12 {
                let at: [Double] = sides.map { $0[k] }, m = at.reduce(0, +) / Double(at.count)
                for v in at { squares += (v - m) * (v - m) }
            }
            let noise = (squares / Double(12 * sides.count)).squareRoot() / level
            note("floor thread at full size: depth \(lineDepth), floor noise \(noise), ratio \(lineDepth / noise)")
            check("version 3 keeps the floor thread", lineDepth > 0.18 && lineDepth / noise > 2,
                  "the thread over 18% under the floor and over twice its noise; got \(lineDepth), \(lineDepth / noise)")
        } else { check("version 3 keeps the floor thread", false, "not decoded") }
        // Not crunchy: version 3's decode (decoder 9, its own sharpening taken back) has decoder 8's contrast on bright
        // detail (where noise doesn't count) at 1.5 and 1.5–4 px, within 15% (decoder 9 as it comes: 1.5 and 1.23 times).
        if let crisp = PhotoRender.source(raw, maxSize: 3000, noise: 0, color: 0, raw: PhotoRender.RawSettings(v3)),
           let plain = PhotoRender.source(raw, maxSize: 3000, noise: 0, color: 0, raw: PhotoRender.RawSettings(v2)), crisp.extent == plain.extent {
            func bandEnergy(_ i: CIImage, mask: [Float]? = nil) -> (fine: Double, mid: Double, mask: [Float]) {
                let c = i.clampedToExtent()
                func blur(_ r: Double) -> CIImage { r == 0 ? c : c.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: r]) }
                let rect = i.extent.insetBy(dx: i.extent.width * 0.1, dy: i.extent.height * 0.1).integral
                func luma(_ r: Double) -> [Float] {
                    var p = [Float](repeating: 0, count: Int(rect.width) * Int(rect.height) * 4)
                    PhotoEngine.context.render(blur(r).cropped(to: rect), toBitmap: &p, rowBytes: Int(rect.width) * 16, bounds: rect, format: .RGBAf, colorSpace: space)
                    return stride(from: 0, to: p.count, by: 4).map { 0.2126 * p[$0] + 0.7152 * p[$0 + 1] + 0.0722 * p[$0 + 2] }
                }
                let y0 = luma(0), y1 = luma(1.5), y4 = luma(4), m = mask ?? y4.map { $0 > 0.02 ? 1 : 0 }
                var fine = 0.0, mid = 0.0
                for k in y0.indices where m[k] > 0 { fine += Double((y0[k] - y1[k]) * (y0[k] - y1[k])); mid += Double((y1[k] - y4[k]) * (y1[k] - y4[k])) }
                return (fine, mid, m)
            }
            let p = bandEnergy(plain), q = bandEnergy(crisp, mask: p.mask)
            let fine = (q.fine / p.fine).squareRoot(), mid = (q.mid / p.mid).squareRoot()
            note("version 3 decode against decoder 8 on bright detail: \(fine) at 1.5 px, \(mid) at 1.5–4 px")
            check("version 3 decode isn't crunchy", abs(fine - 1) < 0.15 && abs(mid - 1) < 0.15, "within 15% of decoder 8's contrast at both; got \(fine), \(mid)")
        } else { check("version 3 decode isn't crunchy", false, "not decoded") }
        // What it costs a preview's decode (rendered whole, as the kept base is): the first (the noise measured), then again.
        func decodeTime(_ luma: Bool) -> [Double] {
            (0..<3).map { _ in
                let start = Date()
                if let image = PhotoRender.source(raw, maxSize: 3000, noise: 0, color: 25, raw: PhotoRender.RawSettings(v3), luma: luma) { _ = BaseCache.texture(image) }
                return (Date().timeIntervalSince(start) * 1000).rounded()
            }
        }
        note("luminance noise reduction: a 3000 px decode \(decodeTime(false)) ms without, \(decodeTime(true)) ms with")
    }
}
