import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Process 4 (decoder 9 with lighter smoothing, the owner's pick, 2026-11-06): its keys, the luminance noise reduction by
/// ISO, fine detail, edge colour and speed against version 3; plus a tool for the comparison sheet. On the test RAWs kept outside the repo (`<photos>/../shootout/raws`); skipped without them.
extension PhotoSelfTest {
    static var p4Raws: URL { URL(fileURLWithPath: photos).deletingLastPathComponent().appendingPathComponent("shootout/raws") }

    nonisolated(unsafe) private static let p4Linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    /// A part of a picture as linear floats (RGBA), its rows from the top; `rect` from the picture's top left.
    static func p4Floats(_ image: CIImage, _ rect: CGRect) -> [Float] {
        let w = Int(rect.width), h = Int(rect.height)
        var px = [Float](repeating: 0, count: w * h * 4)
        PhotoEngine.context.render(image, toBitmap: &px, rowBytes: w * 16,
                                   bounds: CGRect(x: image.extent.minX + rect.minX, y: image.extent.maxY - rect.maxY, width: rect.width, height: rect.height),
                                   format: .RGBAf, colorSpace: p4Linear)
        return px
    }

    /// The colour left at strong edges: mean |high-pass chroma| (∛R − ∛G, ∛B − ∛G, pixel against its 5 × 5 mean) on the
    /// strongest tenth of luma gradients, over their gradient (so contrast doesn't count). Demosaic false colour and
    /// chroma noise at fine edges (the whisker fringes) show here; real colour edges are wide and mostly cancel.
    static func p4EdgeColour(_ p: [Float], _ w: Int, _ h: Int) -> Double {
        let n = w * h
        var L = [Float](repeating: 0, count: n), a = L, b = L
        for i in 0..<n {
            let r = cbrt(max(p[i * 4], 0)), g = cbrt(max(p[i * 4 + 1], 0)), bl = cbrt(max(p[i * 4 + 2], 0))
            L[i] = 0.2126 * r + 0.7152 * g + 0.0722 * bl; a[i] = r - g; b[i] = bl - g
        }
        func hp(_ x: [Float], _ i: Int, _ X: Int, _ Y: Int) -> Float {
            var s: Float = 0
            for dy in -2...2 { for dx in -2...2 { s += x[(Y + dy) * w + X + dx] } }
            return x[i] - s / 25
        }
        var items: [(g: Float, c: Float)] = []
        for y in 3..<h - 3 { for x in 3..<w - 3 {
            let i = y * w + x
            let g = hypot(L[i + 1] - L[i - 1], L[i + w] - L[i - w]) / 2
            items.append((g, hypot(hp(a, i, x, y), hp(b, i, x, y))))
        } }
        items.sort { $0.g > $1.g }
        let top = items.prefix(max(items.count / 10, 1))
        return Double(top.reduce(0) { $0 + $1.c } / max(top.reduce(0) { $0 + $1.g }, 1e-9))
    }

    /// Process 4 itself (in the photo suite): decoder 9
    /// with half of version 3's soften and its luminance noise reduction only with the ISO (`lumaShare`).
    static func process4() async {
        let folder = p4Raws
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("DSC01994.ARW").path) else { skip("process 4", "no test RAWs"); return }
        var v3 = PhotoAdjustments(); v3.process = 3
        var v4 = PhotoAdjustments(); v4.process = 4
        let s3 = PhotoRender.RawSettings(v3), s4 = PhotoRender.RawSettings(v4)

        // New edits are process 5 (process 4's decode); Update moves a version 3 edit there (a JPEG's look is version 3's, so it isn't offered it).
        check("p4 is current", PhotoAdjustments.currentProcess == 5 && PhotoAdjustments().process == 5 && v3.updated(isRaw: true).process == 5
              && PhotoRender.RawSettings(PhotoAdjustments()) == s4)

        // Keys: versions 1–3 name their decodes as before; process 4's are its own (and so are its denoised files).
        var a2 = PhotoAdjustments(); a2.process = 2
        let pinned = PhotoRender.RawSettings(a2), dec = s3.decoder ?? ""
        check("p4 old keys unchanged", s3.key == "0|\(dec)+9|w" && s3.pin == "\(dec)+9" && pinned.key == "0|\(dec)" && s4.pin == "\(dec)+9+4" && s4.key != s3.key,
              "v3 \(s3.key) / \(s3.pin), v2 \(pinned.key), v4 \(s4.key) / \(s4.pin)")

        // The luminance noise reduction's share by ISO.
        let shares = [100.0, 1600, 2400, 3200, 6400, 12800].map { PhotoRender.lumaShare(iso: $0) }
        check("p4 luminance share by iso", shares[0] == 0 && shares[1] == 0 && abs(shares[3] - 0.5) < 1e-9 && shares[4] == 1 && shares[5] == 1
              && shares[2] > 0 && shares[2] < 0.5, "\(shares)")

        // Decoder 9 for every RAW: version 3's frame; a lighter soften than version 3's; at ISO 125 no luminance
        // noise reduction at Luminance 0, and the slider still adds it.
        let arw = folder.appendingPathComponent("DSC01994.ARW").path
        func same(_ x: CIImage?, _ y: CIImage?) -> Bool {
            guard let x, let y, x.extent == y.extent else { return false }
            let r = CGRect(x: x.extent.width * 0.4, y: x.extent.height * 0.4, width: 256, height: 256)
            return p4Floats(x, r) == p4Floats(y, r)
        }
        if let a = PhotoRender.source(arw, maxSize: 0, raw: s3), let b = PhotoRender.source(arw, maxSize: 0, raw: s4),
           let p = PhotoRender.source(arw, maxSize: 2048, raw: s3), let q = PhotoRender.source(arw, maxSize: 2048, raw: s4) {
            check("p4 same frame as v3, lighter", a.extent == b.extent && p.extent == q.extent && !same(a, b), "full \(a.extent.size) / \(b.extent.size), preview \(p.extent.size) / \(q.extent.size)")
        } else { check("p4 same frame as v3, lighter", false, "not decoded") }
        check("p4 no luminance noise reduction at low iso", same(PhotoRender.source(arw, maxSize: 1500, color: 25, raw: s4, luma: true), PhotoRender.source(arw, maxSize: 1500, color: 25, raw: s4))
              && !same(PhotoRender.source(arw, maxSize: 1500, noise: 20, color: 25, raw: s4, luma: true), PhotoRender.source(arw, maxSize: 1500, noise: 20, color: 25, raw: s4)))

        // High ISO (R6LO7461, 6400): all of version 3's luminance noise reduction, so the noise in a flat patch is near v3's;
        // ISO 1600 (R6LO7634): none, noted.
        func flatNoise(_ path: String, _ s: PhotoRender.RawSettings, _ rect: CGRect) -> Double? {
            guard let image = PhotoRender.source(path, maxSize: 0, color: 25, raw: s, luma: true) else { return nil }
            let p = p4Floats(image, rect), w = Int(rect.width), h = Int(rect.height)
            var y = [Double](repeating: 0, count: w * h)
            for i in 0..<(w * h) { y[i] = cbrt(max(0.2126 * Double(p[i * 4]) + 0.7152 * Double(p[i * 4 + 1]) + 0.0722 * Double(p[i * 4 + 2]), 0)) }
            var sum = 0.0, n = 0.0
            for r in 2..<h - 2 { for c in 2..<w - 2 {
                var m = 0.0
                for dy in -2...2 { for dx in -2...2 { m += y[(r + dy) * w + c + dx] } }
                let d = y[r * w + c] - m / 25; sum += d * d; n += 1
            } }
            return (sum / n).squareRoot()
        }
        let high = folder.appendingPathComponent("R6LO7461.CR3").path, mid = folder.appendingPathComponent("R6LO7634.CR3").path
        if FileManager.default.fileExists(atPath: high), let n3 = flatNoise(high, s3, CGRect(x: 2600, y: 1000, width: 200, height: 150)),
           let n4 = flatNoise(high, s4, CGRect(x: 2600, y: 1000, width: 200, height: 150)) {
            check("p4 high iso noise like v3", n4 < n3 * 1.25, "ISO 6400 flat-patch grain \(n4) against version 3's \(n3)")
            note("p4 ISO 6400 grain \(n4), v3 \(n3)")
        }
        if FileManager.default.fileExists(atPath: mid), let n3 = flatNoise(mid, s3, CGRect(x: 2300, y: 1900, width: 200, height: 150)),
           let n4 = flatNoise(mid, s4, CGRect(x: 2300, y: 1900, width: 200, height: 150)) {
            note("p4 ISO 1600 grain \(n4), v3 \(n3) (ratio \(n4 / n3))")
        }

        // Synthetic fine lines (3–6 times decoder 8's noise) through process 4's path at both ends of the ISO range: no
        // luminance noise reduction (≤ 1600) and all of version 3's (≥ 6400), colour noise reduction 25, the develop at +4.5.
        let bw = 120, bands = 6
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func gauss() -> Float {
            func u() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(seed >> 40) / Float(1 << 24) + 1e-7 }
            return (-2 * log(u())).squareRoot() * cos(2 * .pi * u())
        }
        let lines: [(row: Int, width: Int, depth: Float)] = [(60, 1, 4), (120, 2, 4), (180, 1, 6), (240, 2, 6), (300, 2, 3)]
        func lined(_ noise: Bool) -> CIImage {
            var px = [Float](repeating: 1, count: bands * bw * 384 * 4)
            for row in 0..<384 { for x in 0..<(bands * bw) {
                let y = exp2(Float(x / bw) - 9), sd = (4e-5 * y + 1e-7).squareRoot()
                let dip = lines.first { row >= $0.row && row < $0.row + $0.width }.map { $0.depth * sd } ?? 0
                let v = y - dip + (noise ? gauss() * sd : 0)
                let i = (row * bands * bw + x) * 4
                px[i] = v; px[i + 1] = v; px[i + 2] = v
            } }
            return CIImage(bitmapData: px.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: bands * bw * 16,
                           size: CGSize(width: bands * bw, height: 384), format: .RGBAf, colorSpace: p4Linear)
        }
        var lift = PhotoAdjustments(); lift.exposure = 4.5
        func developed(_ i: CIImage) -> [Float] { p4Floats(PhotoRender.adjusted(i, lift, isRaw: true, kelvin: 5500).cropped(to: i.extent), CGRect(x: 0, y: 0, width: bands * bw, height: 384)) }
        func depth(_ p: [Float], _ l: (row: Int, width: Int, depth: Float)) -> Double {
            func rowMean(_ r: Int) -> Double {
                var sum = 0.0
                for k in 1..<5 { for x in (k * bw + 10)..<(k * bw + bw - 10) { sum += Double(p[(r * bands * bw + x) * 4 + 1]) } }
                return sum / Double(4 * (bw - 20))
            }
            let rows: [Int] = Array(l.row - 12..<l.row - 6) + Array(l.row + l.width + 6..<l.row + l.width + 12)
            return rows.map(rowMean).reduce(0, +) / 12 - (l.row..<l.row + l.width).map(rowMean).reduce(0, +) / Double(l.width)
        }
        let clean = developed(lined(false)), noisy = lined(true)
        for (name, luma) in [("low iso", false), ("high iso", true)] {
            let reduced = luma ? PhotoRender.lumaNoiseReduced(noisy, amount: 0, scale: 1) : noisy
            let out = developed(PhotoRender.colourNoiseReduced(reduced, amount: 25, fullLongEdge: Double(bands * bw), wide: true))
            let kept = lines.map { depth(out, $0) / depth(clean, $0) }
            let floors = luma ? [0.55, 0.7, 0.7, 0.8, 0.6] : [0.85, 0.9, 0.9, 0.9, 0.85]
            check("p4 keeps fine lines, \(name)", zip(kept, floors).allSatisfy { $0 > $1 }, "over \(floors); got \(kept.map { ($0 * 100).rounded() / 100 })")
            note("p4 fine lines kept, \(name): \(kept.map { ($0 * 100).rounded() })%")
        }

        // The floor thread by the pot (DSC01962, ISO 400) at full size: its depth under the floor and against the floor's noise.
        let pot = folder.appendingPathComponent("DSC01962.ARW").path
        func thread(_ settings: PhotoRender.RawSettings) -> (depth: Double, noise: Double)? {
            guard let thread = PhotoRender.source(pot, maxSize: 0, noise: 0, color: 25, raw: settings, luma: true) else { return nil }
            let p = p4Floats(thread, CGRect(x: 1300 - 24, y: 3080 - 24, width: 200, height: 100))
            func Y(_ r: Int, _ c: Int) -> Double { let i = (r * 200 + c) * 4; return 0.2126 * Double(p[i]) + 0.7152 * Double(p[i + 1]) + 0.0722 * Double(p[i + 2]) }
            var profile = [Double](repeating: 0, count: 29), sides: [[Double]] = []
            for c in 10..<190 {
                let r = Int((37.98 + 0.05439 * Double(c) + 0.000265 * Double(c * c)).rounded())
                let column: [Double] = (r - 14...r + 14).map { Y($0, c) }
                for k in 0..<29 { profile[k] += column[k] / 180 }
                sides.append(Array(column.prefix(6) + column.suffix(6)))
            }
            let level = (profile.prefix(6).reduce(0, +) + profile.suffix(6).reduce(0, +)) / 12
            var squares = 0.0
            for k in 0..<12 {
                let at = sides.map { $0[k] }, m = at.reduce(0, +) / Double(at.count)
                for v in at { squares += (v - m) * (v - m) }
            }
            return ((level - profile[12...16].min()!) / level, (squares / Double(12 * sides.count)).squareRoot() / level)
        }
        if let t4 = thread(s4), let t3 = thread(s3) {
            check("p4 keeps the floor thread", t4.depth > 0.2 && t4.depth / t4.noise > 1.5,
                  "deeper than 20% and 1.5 times the floor's grain; got \(t4.depth), \(t4.depth / t4.noise) (v3 \(t3.depth), \(t3.depth / t3.noise))")
            note("p4 floor thread: depth \(t4.depth), ratio \(t4.depth / t4.noise); v3 \(t3.depth), \(t3.depth / t3.noise)")
        } else { check("p4 keeps the floor thread", false, "not decoded") }

        // Not crunchy: bright detail at 1.5 and 1.5–4 px against decoder 8's (version 3: 1.07 / 0.98; decoder 9 as it
        // comes: about 1.44 / 1.08).
        func detailBands(_ i: CIImage, mask: [Float]? = nil) -> (fine: Double, mid: Double, mask: [Float]) {
            let c = i.clampedToExtent()
            func blur(_ r: Double) -> CIImage { r == 0 ? c : c.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: r]) }
            let rect = CGRect(x: i.extent.width * 0.1, y: i.extent.height * 0.1, width: (i.extent.width * 0.8).rounded(), height: (i.extent.height * 0.8).rounded())
            func luma(_ r: Double) -> [Float] {
                let p = p4Floats(blur(r).cropped(to: i.extent), rect)
                return stride(from: 0, to: p.count, by: 4).map { 0.2126 * p[$0] + 0.7152 * p[$0 + 1] + 0.0722 * p[$0 + 2] }
            }
            let y0 = luma(0), y1 = luma(1.5), y4 = luma(4)
            // (Strong detail only: process 4's texture step raises low-contrast detail on purpose and leaves edges alone.)
            let m = mask ?? y4.indices.map { y4[$0] > 0.02 && abs(y1[$0] - y4[$0]) > 0.12 * y4[$0] ? 1 : 0 }
            var fine = 0.0, mid = 0.0
            for k in y0.indices where m[k] > 0 { fine += Double((y0[k] - y1[k]) * (y0[k] - y1[k])); mid += Double((y1[k] - y4[k]) * (y1[k] - y4[k])) }
            return (fine, mid, m)
        }
        if let crisp = PhotoRender.source(pot, maxSize: 3000, noise: 0, color: 0, raw: s4), let plain = PhotoRender.source(pot, maxSize: 3000, noise: 0, color: 0, raw: pinned),
           crisp.extent == plain.extent {
            // (Process 4 also puts back the lens's fall-off from the camera's data: the same on decoder 8's, so only the detail differs.)
            let shadedPlain = PhotoRender.lensShading(PhotoCatalog.file(of: pot)).map { PhotoRender.shaded(plain, $0) } ?? plain
            let p = detailBands(shadedPlain), q = detailBands(crisp, mask: p.mask)
            let fine = (q.fine / p.fine).squareRoot(), midBand = (q.mid / p.mid).squareRoot()
            check("p4 decode isn't crunchy", fine < 1.35 && abs(midBand - 1) < 0.15, "under 1.35 times decoder 8's at 1.5 px, within 15% at 1.5–4 px; got \(fine), \(midBand)")
            note("p4 decode against decoder 8 on bright detail: \(fine) at 1.5 px, \(midBand) at 1.5–4 px")
        } else { check("p4 decode isn't crunchy", false, "not decoded") }

        // Edge colour (whiskers, DSC01980; the stand's legs, DSC01962) about version 3's. Process 4's colour is softened as
        // version 3's; what's left (whiskers +11%, legs +8%) comes with the crisper brightness at the same edges (version 3
        // without its luminance noise reduction measures as version 3), so the floor is 15% over it.
        for (file, rect) in [("DSC01980.ARW", CGRect(x: 3050, y: 1650, width: 700, height: 450)), ("DSC01962.ARW", CGRect(x: 4600, y: 3500, width: 300, height: 200))] {
            let path = folder.appendingPathComponent(file).path
            guard let old = PhotoRender.source(path, maxSize: 0, noise: 0, color: 25, raw: s3, luma: true),
                  let new = PhotoRender.source(path, maxSize: 0, noise: 0, color: 25, raw: s4, luma: true) else { check("p4 edge colour \(file)", false, "not decoded"); continue }
            let w = Int(rect.width), h = Int(rect.height)
            let e3 = p4EdgeColour(p4Floats(old, rect), w, h), e4 = p4EdgeColour(p4Floats(new, rect), w, h)
            check("p4 edge colour \(file)", e4 <= e3 * 1.15, "process 4 \(e4), version 3 \(e3)")
            let plainV3 = PhotoRender.source(path, maxSize: 0, noise: 0, color: 25, raw: s3).map { p4EdgeColour(p4Floats($0, rect), w, h) } ?? -1
            note("p4 edge colour \(file): \(e4) (version 3 \(e3); version 3 without its luminance noise reduction \(plainV3))")
        }

        await process4Speed()
    }

    /// Speed against version 3 (DSC01994, 24 MP ARW): the first display (decode kept + developed at the
    /// preview's size), a slider moved (the kept decode, developed again), saving at full size. And Shadows and Highlights
    /// at ±100 on DSC01962: no more clipping or colour in the shadows than version 3.
    static func process4Speed() async {
        let arw = p4Raws.appendingPathComponent("DSC01994.ARW").path
        var r3 = PhotoRecord(); r3.adjust.process = 3
        let r4 = PhotoRecord()
        func ms(_ start: Date) -> Double { (Date().timeIntervalSince(start) * 1000).rounded() }
        var first: [Int: [Double]] = [:], drag: [Int: Double] = [:], export: [Int: [Double]] = [:]
        for (process, record) in [(3, r3), (4, r4), (3, r3), (4, r4)] {
            BaseCache.shared.removeAll(); GuideCache.shared.removeAll()
            var start = Date()
            if let image = PhotoRender.image(arw, record: record, maxSize: 2048) { _ = PhotoRender.picture(image) }
            first[process, default: []].append(ms(start))
            var times: [Double] = []
            for k in 0..<12 {
                var moved = record
                moved.adjust.exposure = Double(k) / 10
                start = Date()
                if let image = PhotoRender.image(arw, record: moved, maxSize: 2048) { _ = PhotoRender.picture(image) }
                times.append(ms(start))
            }
            drag[process] = times.sorted()[times.count / 2]
            BaseCache.shared.removeAll()
            start = Date()
            _ = try? await PhotoRender.develop(arw, record: record, maxSize: 0)
            export[process, default: []].append(ms(start))
        }
        note("p4 speed (DSC01994, ms, v3 → v4): first display \(first[3] ?? []) → \(first[4] ?? []); slider (median of 12) \(drag[3] ?? 0) → \(drag[4] ?? 0); "
             + "save at full size \(export[3] ?? []) → \(export[4] ?? [])")
        check("p4 slider as quick as v3", (drag[4] ?? 999) <= (drag[3] ?? 0) * 1.3 + 5, "median \(drag[4] ?? -1) ms against \(drag[3] ?? -1)")
        check("p4 first display quick", (first[4]?.last ?? 9999) < 1500, "\(first[4] ?? [])")

        // Shadows and Highlights at ±100 (DSC01962): the share of clipped values and the shadows' mean colour against v3's.
        let pot = p4Raws.appendingPathComponent("DSC01962.ARW").path
        for (shadows, highlights) in [(100.0, -100.0), (-100.0, 100.0)] {
            var stats: [Int: (clip: Double, chroma: Double)] = [:]
            for process in [3, 4] {
                var record = PhotoRecord(); record.adjust.process = process
                record.adjust.shadows = shadows; record.adjust.highlights = highlights
                guard let picture = try? await PhotoRender.develop(pot, record: record, maxSize: 1500), let data = picture.dataProvider?.data as Data? else { continue }
                let bpr = picture.bytesPerRow
                var clipped = 0, n = 0, dark = 0
                var sa = 0.0, sb = 0.0
                for y in stride(from: 0, to: picture.height, by: 2) { for x in stride(from: 0, to: picture.width, by: 2) {
                    let i = y * bpr + x * 4, r = data[i], g = data[i + 1], b = data[i + 2]
                    n += 1
                    if max(r, g, b) >= 254 || min(r, g, b) <= 1 { clipped += 1 }
                    let lr = pow(Double(r) / 255, 2.2), lg = pow(Double(g) / 255, 2.2), lb = pow(Double(b) / 255, 2.2)
                    let lab = OkLab.from(lr, lg, lb)
                    if lab.0 < 0.35 { dark += 1; sa += lab.1; sb += lab.2 }
                } }
                stats[process] = (Double(clipped) / Double(n), hypot(sa, sb) / Double(max(dark, 1)))
            }
            guard let a = stats[3], let b = stats[4] else { check("p4 shadows \(Int(shadows)) highlights \(Int(highlights))", false, "not rendered"); continue }
            check("p4 shadows \(Int(shadows)) highlights \(Int(highlights))", b.clip <= a.clip + 0.01 && b.chroma <= a.chroma + 0.01,
                  "clipped \(b.clip) (v3 \(a.clip)), shadows' mean colour \(b.chroma) (v3 \(a.chroma))")
            note("p4 shadows \(Int(shadows)) highlights \(Int(highlights)): clipped \(b.clip) (v3 \(a.clip)), shadow tint \(b.chroma) (v3 \(a.chroma))")
        }
    }

    /// Full-size renders' crops as PNGs for the comparison sheet (into `<photos>/../p4/dump`):
    /// version 3 and 4 of the same edits.
    static func process4Dump() async {
        let out = URL(fileURLWithPath: photos).deletingLastPathComponent().appendingPathComponent("p4/dump")
        typealias Crop = (name: String, x: Int, y: Int, w: Int, h: Int)
        let lightroom: (inout PhotoAdjustments) -> Void = {
            $0.exposure = 2.25; $0.highlights = -100; $0.shadows = 100; $0.sharpen = 40; $0.profile = .adobe
        }
        let lifted: (inout PhotoAdjustments) -> Void = { $0.shadows = 60 }
        let cases: [(file: String, edit: (inout PhotoAdjustments) -> Void, crops: [Crop])] = [
            ("DSC01962.ARW", lightroom, [("pot", 736, 2876, 300, 200), ("plastic", 776, 2706, 300, 200), ("floor", 1226, 3016, 300, 200),
                                         ("legs", 4600, 3500, 300, 200)]),
            ("DSC01980.ARW", lifted, [("whiskers", 3050, 1650, 700, 450), ("sofa", 600, 700, 300, 200)]),
            ("R6LO8181.CR3", lifted, [("knit", 3050, 1950, 500, 400)]),
            ("R6LO7634.CR3", lifted, [("shadow", 2200, 1850, 400, 300), ("people", 2600, 2700, 500, 400)]),
            ("R6LO7461.CR3", lifted, [("knit", 4700, 2600, 500, 400), ("ceiling", 2400, 900, 500, 400)]),
        ]
        let folder = out
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for c in cases {
            let path = p4Raws.appendingPathComponent(c.file).path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            for process in [3, 4] {
                var record = PhotoRecord()
                record.adjust.process = process
                c.edit(&record.adjust)
                BaseCache.shared.removeAll()
                let start = Date()
                guard let picture = try? await PhotoRender.develop(path, record: record, maxSize: 0) else { note("dump \(c.file) p\(process) failed"); continue }
                note(String(format: "dump %@ p%d: %d×%d in %.2f s", c.file, process, picture.width, picture.height, Date().timeIntervalSince(start)))
                for crop in c.crops {
                    guard let part = picture.cropping(to: CGRect(x: crop.x, y: crop.y, width: crop.w, height: crop.h)),
                          let dest = CGImageDestinationCreateWithURL(folder.appendingPathComponent("\(c.file.prefix(8))-\(crop.name)-p\(process).png") as CFURL,
                                                                     UTType.png.identifier as CFString, 1, nil) else { continue }
                    CGImageDestinationAddImage(dest, part, nil)
                    CGImageDestinationFinalize(dest)
                }
            }
        }
    }
}
