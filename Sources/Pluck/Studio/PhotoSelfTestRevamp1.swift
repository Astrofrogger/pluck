import CoreImage
import Foundation
import ImageIO
import simd
import UniformTypeIdentifiers

/// Process 5's visible fixes: Dehaze on brightness (no crush, no tint, no lamp as the haze, no skyline band), a finished
/// picture's profiles (no second tone curve), Neutral's hue and mid grey, the Classic family's shadow colour. Each check also
/// measures process 4 (kept as it was) as the before.
extension PhotoSelfTest {
    private static func r1Luma(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    /// A hazy scene (linear sRGB, 1500×1000): J·t + A(1 − t), A bluish. Rows 0–449: sky (t 0.3); 450–699 on the left two
    /// thirds: far hills, textured, with a grey patch (t 0.45); below, and from row 450 on the right third (straight under the
    /// sky: the skyline), near dark trees (t 0.9), textured.
    private static func hazyScene() -> (image: CIImage, width: Int) {
        let A = SIMD3<Float>(0.8, 0.9, 1.1), w = 1500
        let image = fsImage(w, 1000) { x, y in
            let n = Float(0.5 + 0.5 * sin(Double(x) * 0.9) * cos(Double(y) * 0.7))
            var J: SIMD3<Float>, t: Float
            if y < 450 { J = SIMD3(0.55, 0.7, 0.95); t = 0.3 }
            else if y < 700 && x < 1000 {
                t = 0.45
                J = x >= 400 && x < 480 && y >= 520 && y < 600 ? SIMD3(repeating: 0.18) : SIMD3(0.08, 0.12, 0.05) * (0.4 + 1.2 * n)
            } else { J = SIMD3(0.03, 0.05, 0.02) * (0.6 + 0.8 * n); t = 0.9 }
            return J * t + A * (1 - t)
        }
        return (image, w)
    }

    static func revamp1() async {
        dehazeChecks()
        pictureProfiles()
        neutralAndClassic()
        await revamp1Dump()
    }

    // MARK: T2 Dehaze

    private static func dehazeChecks() {
        let (scene, w) = hazyScene()
        let input = fsPixels(scene, scene.extent)
        func light(_ process: Int, _ amount: Double) -> [SIMD3<Double>] {
            var a = PhotoAdjustments(); a.process = process; a.dehaze = amount
            return fsDeveloped(scene, a, scene: true)
        }
        func at(_ px: [SIMD3<Double>], _ x: Int, _ y: Int) -> SIMD3<Double> { px[y * w + x] }
        var rows: [String] = []
        var p5: (floor: Double, drift: Double, band: Int, gain: Double) = (0, 0, 0, 0)
        for process in [4, 5] {
            let out = light(process, 100)
            // Near trees under the sky: the lowest share of their light kept, and how far down (rows) they're more than 0.15
            // stop off the trees further down (the band along the skyline).
            var floor = 9.0
            for y in 452..<1000 { for x in stride(from: 1010, to: 1490, by: 3) { floor = min(floor, max(r1Luma(at(out, x, y)), 0) / max(r1Luma(at(input, x, y)), 1e-6)) } }
            func rowMean(_ px: [SIMD3<Double>], _ y: Int) -> Double { stride(from: 1010, to: 1490, by: 2).map { r1Luma(at(px, $0, y)) }.reduce(0, +) / 240 }
            let far = (850..<900).map { rowMean(out, $0) / rowMean(input, $0) }.reduce(0, +) / 50
            var band = 0
            for y in 450..<850 where abs(log2(max(rowMean(out, y) / rowMean(input, y), 1e-6) / far)) > 0.15 { band = y - 449 }
            // The grey patch's hue (OkLab) before and after: the haze is taken out of its brightness only.
            func mean(_ px: [SIMD3<Double>], _ xs: Range<Int>, _ ys: Range<Int>) -> SIMD3<Double> {
                var s = SIMD3<Double>(); for y in ys { for x in xs { s += at(px, x, y) } }; return s / Double(xs.count * ys.count)
            }
            let gi = fsLab(mean(input, 410..<470, 530..<590)), go = fsLab(mean(out, 410..<470, 530..<590))
            let drift = fsHueApart(fsHue(gi), fsHue(go))
            // The far hills' texture (log brightness spread) is raised.
            func spread(_ px: [SIMD3<Double>]) -> Double {
                let v = (600..<690).flatMap { y in stride(from: 20, to: 380, by: 2).map { log2(max(r1Luma(at(px, $0, y)), 1e-6)) } }
                let m = v.reduce(0, +) / Double(v.count); return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)).squareRoot()
            }
            let gain = spread(out) / spread(input)
            rows.append(String(format: "p%d: darkest share kept %.2f, skyline band %d rows (%.1f%% of width), grey hue drift %.1f°, hills contrast ×%.2f",
                               process, floor, band, Double(band) / Double(w) * 100, drift, gain))
            if process == 5 { p5 = (floor, drift, band, gain) }
        }
        note("dehaze +100 on a hazy scene: " + rows.joined(separator: "; "))
        check("dehaze keeps shadows (no crush)", p5.floor >= 0.29, String(format: "near trees keep at least %.2f of their light (0.29 or more); %@", p5.floor, rows.joined(separator: "; ")))
        check("dehaze keeps grey's hue", p5.drift < 2, String(format: "grey patch hue moved %.1f° (under 2)", p5.drift))
        check("dehaze no skyline band", Double(p5.band) < 0.005 * Double(w), "band \(p5.band) rows (under 0.5% of the width)")
        check("dehaze raises haze contrast", p5.gain > 1.3, String(format: "far hills' spread ×%.2f (over 1.3)", p5.gain))

        // A night scene with one small orange lamp: the lamp isn't the haze. Minus: no bright orange fog; plus: no blue cast.
        let night = fsImage(1500, 1000) { x, y in
            let lamp = hypot(Double(x - 1200), Double(y - 200)) < 18
            let n = Float(0.6 + 0.4 * sin(Double(x) * 0.3) * sin(Double(y) * 0.2))
            return lamp ? SIMD3(12, 6, 1.5) : SIMD3(0.03, 0.028, 0.026) * n
        }
        let ni = fsPixels(night, night.extent)
        var nightRows: [String] = [], fog5 = (lift: 0.0, colour: 0.0), cast5 = 0.0
        for process in [4, 5] {
            var minus = PhotoAdjustments(); minus.process = process; minus.dehaze = -100
            var plus = minus; plus.dehaze = 100
            let m = fsDeveloped(night, minus, scene: true), p = fsDeveloped(night, plus, scene: true)
            var sm = SIMD3<Double>(), sp = SIMD3<Double>(), si = SIMD3<Double>()
            for y in 600..<900 { for x in 100..<700 { let i = y * 1500 + x; sm += m[i]; sp += p[i]; si += ni[i] } }
            let lm = fsLab(sm / 180000), lp = fsLab(sp / 180000), li = fsLab(si / 180000)
            let lift = r1Luma(sm / 180000) / r1Luma(si / 180000), colour = fsChroma(lm) / max(lm.x, 1e-6)
            let cast = fsChroma(lp - li) / max(li.x, 1e-6)
            nightRows.append(String(format: "p%d: −100 lifts the dark ×%.1f, its colour C/L %.3f (input %.3f); +100 moves its colour by %.3f C/L", process, lift, colour, fsChroma(li) / li.x, cast))
            if process == 5 { fog5 = (lift, colour); cast5 = cast }
        }
        note("dehaze on a night scene with a lamp: " + nightRows.joined(separator: "; "))
        check("dehaze minus is no lamp-coloured fog", fog5.lift < 4 && fog5.colour < 0.12, nightRows.joined(separator: "; "))
        check("dehaze plus keeps a night scene's colour", cast5 < 0.03, nightRows.joined(separator: "; "))
    }

    // MARK: T4 A finished picture through each profile

    private static func pictureProfiles() {
        // A grey ramp (0 … 1, 64 steps, linear) and six colours, as a JPEG's decode.
        let colours: [SIMD3<Float>] = [SIMD3(0.5, 0.1, 0.08), SIMD3(0.1, 0.4, 0.1), SIMD3(0.08, 0.15, 0.6), SIMD3(0.6, 0.35, 0.05), SIMD3(0.1, 0.4, 0.45), SIMD3(0.45, 0.3, 0.25)]
        let w = 64
        let image = fsImage(w, 16) { x, y in y < 8 ? SIMD3(repeating: Float(x) / Float(w - 1)) : x < 60 ? colours[x / 10] : SIMD3(repeating: 0.18) }
        func run(_ process: Int, _ profile: PhotoEngine.Profile) -> [SIMD3<Double>] {
            var a = PhotoAdjustments(); a.process = process; a.profile = profile
            return fsPixels(PhotoRender.output(PhotoRender.adjusted(image, a, isRaw: false, kelvin: 5500), a, p3: false), image.extent)
        }
        func enc(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(max(v, 0), 1 / 2.4) - 0.055 }
        let shot = run(5, .asShot)
        var rows: [String] = [], fails: [String] = []
        for profile in [PhotoEngine.Profile.standard, .vivid, .landscape, .portrait, .neutral, .accurate, .monochrome] {
            for process in [4, 5] {
                let px = run(process, profile)
                let white = enc(r1Luma(px[4 * w + 63])), black = enc(r1Luma(px[4 * w])), grey = enc(r1Luma(px[12 * w + 62]))
                var ratio = 0.0
                for k in 0..<6 {
                    let i = 12 * w + k * 10 + 5
                    ratio = max(ratio, fsChroma(fsLab(px[i])) / max(fsChroma(fsLab(shot[i])), 1e-6))
                }
                rows.append(String(format: "%@ p%d: white %.3f, black %.3f, mid grey %.3f (as shot %.3f), colour ×%.2f", profile.rawValue, process, white, black, grey, enc(0.18), ratio))
                if process == 5 && !(white >= 0.99 && black < 0.01 && abs(grey - enc(0.18)) < 0.02 && (profile == .monochrome || ratio <= 1.3)) {
                    fails.append(profile.rawValue)
                }
            }
        }
        note("a JPEG through each profile (sRGB): " + rows.joined(separator: "; "))
        check("jpeg profiles keep white, black and mid grey", fails.isEmpty, "process 5 out of bounds: \(fails); " + rows.joined(separator: "; "))
        // Contrast still works on a JPEG (it went through the second curve before).
        var a = PhotoAdjustments(); a.contrast = 60
        let px = fsPixels(PhotoRender.output(PhotoRender.adjusted(image, a, isRaw: false, kelvin: 5500), a, p3: false), image.extent)
        let low = enc(r1Luma(px[4 * w + 4])), high = enc(r1Luma(px[4 * w + 40])), was = (enc(r1Luma(shot[4 * w + 4])), enc(r1Luma(shot[4 * w + 40])))
        check("jpeg contrast works", low < was.0 - 0.01 && high > was.1 + 0.01, String(format: "Contrast 60: %.3f / %.3f against %.3f / %.3f", low, high, was.0, was.1))
    }

    // MARK: T5 Neutral and the Classic family

    private static func neutralAndClassic() {
        // Mid grey: Neutral against Classic, in stops.
        let grey = fsImage(8, 8) { _, _ in SIMD3(repeating: 0.18) }
        func Y(_ process: Int, _ profile: PhotoEngine.Profile) -> Double {
            var a = PhotoAdjustments(); a.process = process; a.profile = profile
            return r1Luma(fsDeveloped(grey, a)[27])
        }
        let gap4 = log2(Y(4, .neutral) / Y(4, .adobe)), gap5 = log2(Y(5, .neutral) / Y(5, .adobe))
        note(String(format: "neutral − classic mid grey: process 4 %+.3f stop, process 5 %+.3f", gap4, gap5))
        check("neutral mid grey on classic's", abs(gap5) < 0.05, String(format: "Neutral − Classic: %+.3f stop (under 0.05); process 4 %+.3f", gap5, gap4))

        // Bright blue and red going up to white on Neutral: the OkLab hue stays the scene's.
        let n = 160
        let ramps: [SIMD3<Float>] = [SIMD3(0.06, 0.12, 0.9), SIMD3(0.8, 0.05, 0.12)]
        let ramp = fsImage(n, 16) { x, y in ramps[y / 8] * exp2(Float(x) / 20 - 4) }
        let scene = fsPixels(ramp, ramp.extent)
        var drifts: [Int: Double] = [:]
        for process in [4, 5] {
            var a = PhotoAdjustments(); a.process = process; a.profile = .neutral
            let px = fsDeveloped(ramp, a)
            var worst = 0.0
            for row in [4, 12] { for x in 0..<n {
                let o = fsLab(px[row * n + x]), s = fsLab(scene[row * n + x])
                if fsChroma(o) > 0.04 { worst = max(worst, fsHueApart(fsHue(o), fsHue(s))) }
            } }
            drifts[process] = worst
        }
        note(String(format: "neutral's largest hue turn on blue and red ramps: process 4 %.1f°, process 5 %.1f°", drifts[4]!, drifts[5]!))
        check("neutral keeps blue and red hues", drifts[5]! < 3, String(format: "largest hue turn %.1f° (under 3); process 4 %.1f°", drifts[5]!, drifts[4]!))

        // The Classic family's shadow colour: a red ramp from deep shadow to mid grey; its colourfulness (C/L) shouldn't go
        // up, down and up again. Counted: how often it changes direction (by more than 0.002).
        let red = fsImage(n, 8) { x, _ in SIMD3<Float>(0.8, 0.12, 0.08) * exp2(Float(x) / 20 - 10) }
        var turns: [Int: Int] = [:], text: [String] = []
        for process in [4, 5] {
            var a = PhotoAdjustments(); a.process = process; a.profile = .adobe
            let px = fsDeveloped(red, a)
            let s = (0..<n).map { x -> Double in let o = fsLab(px[4 * n + x]); return fsChroma(o) / max(o.x, 1e-4) }
            var count = 0, dir = 0, last = s[0]
            for v in s.dropFirst() where abs(v - last) > 0.002 { let d = v > last ? 1 : -1; if dir != 0 && d != dir { count += 1 }; dir = d; last = v }
            turns[process] = count
            text.append("p\(process): " + stride(from: 0, to: n, by: 16).map { String(format: "%.2f", s[$0]) }.joined(separator: " "))
        }
        note("classic red ramp, colourfulness direction changes: process 4 \(turns[4]!), process 5 \(turns[5]!); " + text.joined(separator: "; "))
        check("classic shadow colour without a dip", turns[5]! <= 1, "direction changes \(turns[5]!) (at most 1); process 4 \(turns[4]!); C/L along the ramp " + text.joined(separator: "; "))

        // Orange at +1 EV into white (Classic): colour keeps changing until it fades (no flat plateau of one colour).
        let orange = fsImage(n, 8) { x, _ in SIMD3<Float>(1, 0.45, 0.12) * exp2(Float(x) / 20 - 5) }
        var plateaus: [Int: Int] = [:]
        for process in [4, 5] {
            var a = PhotoAdjustments(); a.process = process; a.profile = .adobe; a.exposure = 1
            let px = fsDeveloped(orange, a)
            var run = 0, longest = 0
            for x in 1..<n {
                let o = fsLab(px[4 * n + x]), p = fsLab(px[4 * n + x - 1])
                if fsChroma(o) > 0.03 && simd_length(o - p) < 0.0005 { run += 1; longest = max(longest, run) } else { run = 0 }
            }
            plateaus[process] = longest
        }
        note("classic orange +1 EV, longest flat run: process 4 \(plateaus[4]!), process 5 \(plateaus[5]!)")
        check("classic orange fades without a plateau", plateaus[5]! < 8, "longest run of the same colour \(plateaus[5]!) steps of 1/20 stop (under 8); process 4 \(plateaus[4]!)")
    }

    // MARK: The sheet's renders

    /// Into <photos>/../revamp1/dump when that folder exists: 8-bit sRGB PNGs for the before/after sheet.
    private static func revamp1Dump() async {
        let base = URL(fileURLWithPath: photos).deletingLastPathComponent()
        let out = base.appendingPathComponent("revamp1/dump"), raws = base.appendingPathComponent("shootout/raws")
        guard FileManager.default.fileExists(atPath: out.path) else { return }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        func save(_ image: CIImage, _ name: String) {
            let e = image.extent.integral
            let placed = image.cropped(to: e).transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            guard let cg = PhotoEngine.context.createCGImage(placed, from: placed.extent, format: .RGBA8, colorSpace: srgb),
                  let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, cg, nil); CGImageDestinationFinalize(dest)
        }
        func render(_ path: String, _ change: (inout PhotoAdjustments) -> Void) -> CIImage? {
            var record = PhotoRecord(); change(&record.adjust)
            BaseCache.shared.removeAll(); GuideCache.shared.removeAll()
            return PhotoRender.decoded(path, maxSize: 900, record: record).map { PhotoRender.output(PhotoRender.adjusted($0, record.adjust, path: path), record.adjust, p3: false) }
        }
        for name in ["R6LO8181.CR3", "DSC02845.ARW", "DSC02868.ARW", "DSC02817.ARW"] {
            let path = raws.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            for process in [4, 5] { for amount in [-100.0, -50, 0, 50, 100] {
                if let image = render(path, { $0.process = process; $0.profile = .adobe; $0.dehaze = amount }) {
                    save(image, "\(name.prefix(8))-p\(process)-dh\(Int(amount))")
                }
            } }
        }
        for name in ["DSC02868.ARW", "DSC02881.ARW"] {
            let path = raws.appendingPathComponent(name).path
            for process in [4, 5] { if let image = render(path, { $0.process = process; $0.profile = .neutral }) { save(image, "\(name.prefix(8))-p\(process)-neutral") } }
            if let image = render(path, { $0.profile = .adobe }) { save(image, "\(name.prefix(8))-p5-classic") }
        }
        let jpeg = URL(fileURLWithPath: photos).appendingPathComponent("one.jpg").path
        for profile in [PhotoEngine.Profile.asShot, .standard, .vivid, .landscape, .portrait, .monochrome] {
            for process in [4, 5] { if let image = render(jpeg, { $0.process = process; $0.profile = profile }) { save(image, "jpeg-p\(process)-\(profile.rawValue)") } }
        }
        // Accurate: saturated green and blue pushed into white (the snap was on the green).
        let n = 480
        let ramp = fsImage(n, 40) { x, y in (y < 20 ? SIMD3<Float>(0.25, 1, 0.15) : SIMD3(0.2, 0.3, 1)) / 0.7 * 0.18 * exp2(Float(x) / 40 - 10) }
        for process in [4, 5] {
            var a = PhotoAdjustments(); a.process = process; a.profile = .accurate; a.exposure = 5; a.shadows = 100
            save(PhotoRender.output(PhotoRender.adjusted(ramp, a, isRaw: true, kelvin: 5500), a, p3: false), "accurate-p\(process)")
        }
        // Neutral's blue and red ramps.
        let blues = fsImage(320, 40) { x, y in (y < 20 ? SIMD3<Float>(0.06, 0.12, 0.9) : SIMD3(0.8, 0.05, 0.12)) * exp2(Float(x) / 40 - 4) }
        for process in [4, 5] {
            var a = PhotoAdjustments(); a.process = process; a.profile = .neutral
            save(PhotoRender.output(PhotoRender.adjusted(blues, a, isRaw: true, kelvin: 5500), a, p3: false), "neutral-ramp-p\(process)")
        }
        let (hazy, _) = hazyScene()
        for process in [4, 5] { for amount in [0.0, 100] where process == 5 || amount != 0 {
            var a = PhotoAdjustments(); a.process = process; a.dehaze = amount
            save(PhotoRender.output(PhotoRender.adjusted(hazy, a, isRaw: true, kelvin: 5500), a, p3: false), "synthetic-p\(process)-dh\(Int(amount))")
        } }
        BaseCache.shared.removeAll(); GuideCache.shared.removeAll()
    }
}
