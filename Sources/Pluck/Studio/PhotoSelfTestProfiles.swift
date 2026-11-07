import CoreImage

/// Version 3's colour profiles (ColourProfiles.swift): Accurate keeps a colour chart, hues hold through exposure, near-whites
/// go to white, colourful colours have density, Classic's greens and teal against Lightroom on a real RAW, and versions 1
/// and 2 exactly as before.
extension PhotoSelfTest {
    nonisolated(unsafe) private static let profileSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    /// A row of colours (linear sRGB), each `cell` pixels wide and 8 high.
    private static func swatches(_ colours: [SIMD3<Float>], cell: Int = 4) -> CIImage {
        let w = colours.count * cell, h = 8
        var pixels = [Float](repeating: 1, count: w * h * 4)
        for y in 0..<h { for x in 0..<w { let c = colours[x / cell], i = (y * w + x) * 4; pixels[i] = c.x; pixels[i + 1] = c.y; pixels[i + 2] = c.z } }
        return CIImage(bitmapData: pixels.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: w * 16, size: CGSize(width: w, height: h),
                       format: .RGBAf, colorSpace: profileSpace)
    }

    private static func pixels(_ image: CIImage) -> [Float] {
        let e = image.extent.integral
        var px = [Float](repeating: 0, count: Int(e.width) * Int(e.height) * 4)
        px.withUnsafeMutableBytes { PhotoEngine.context.render(image, toBitmap: $0.baseAddress!, rowBytes: Int(e.width) * 16, bounds: e, format: .RGBAf, colorSpace: profileSpace) }
        return px
    }

    static func profiles() async {
        oldProfilesUnchanged()
        chartKept()
        huesHold()
        nearWhitesWhite()
        sharedMidGrey()
        colourHasDensity()
        profilesTravel()
        lightroomColours()
    }

    /// The version 3 profiles, as a RAW shows them.
    private static let newProfiles: [PhotoEngine.Profile] = PhotoEngine.Profile.choices(raw: true, process: 3, chosen: nil)

    /// The ColorChecker 24's published CIELAB (D50; X-Rite's values for charts made after November 2014), dark skin first.
    private static let chart: [SIMD3<Double>] = [
        SIMD3(37.54, 14.37, 14.92), SIMD3(64.66, 19.27, 17.5), SIMD3(49.32, -3.82, -22.54), SIMD3(43.46, -12.74, 22.72), SIMD3(54.94, 9.61, -24.79),
        SIMD3(70.48, -32.26, -0.37), SIMD3(62.73, 35.83, 56.5), SIMD3(39.43, 10.75, -45.17), SIMD3(50.57, 48.64, 16.67), SIMD3(30.1, 22.54, -20.87),
        SIMD3(71.77, -24.13, 58.19), SIMD3(71.51, 18.24, 67.37), SIMD3(28.37, 15.42, -49.8), SIMD3(54.38, -39.72, 32.27), SIMD3(42.43, 51.05, 28.62),
        SIMD3(81.8, 2.67, 80.41), SIMD3(50.63, 51.28, -14.12), SIMD3(49.57, -29.71, -28.32), SIMD3(95.19, -1.03, 2.93), SIMD3(81.29, -0.57, 0.44),
        SIMD3(66.89, -0.75, -0.06), SIMD3(50.76, -0.13, 0.14), SIMD3(35.63, -0.46, -0.48), SIMD3(20.64, 0.07, -0.46),
    ]

    /// The chart as Apple's decoder gives it from a RAW (its yellows and greens more colourful: see ColourProfiles.appleBoost),
    /// in the engine's numbers, at the exposure that puts the middle grey (patch 22) at 0.18.
    private static func decodedChart() -> [SIMD3<Float>] {
        let apple = ColourProfiles.lab { _, C, h in (C * (1 + ColourProfiles.appleBoost * ColourProfiles.plateau(h, 70, 150, taper: 25)), h) }
        let k = 0.18 / ColourProfiles.mul(ColourProfiles.proToXYZ, ColourProfiles.fromLab(chart[21].x, chart[21].y, chart[21].z)).y
        return chart.map { lab in
            let pro = apple(ColourProfiles.fromLab(lab.x, lab.y, lab.z) * k), s = ColourProfiles.mul(PhotoEngine.fromProPhoto, pro)
            return SIMD3(Float(s.x), Float(s.y), Float(s.z))
        }
    }

    /// Each colour's developed value (the middle of its cell), in the engine's numbers.
    private static func developed(_ colours: [SIMD3<Float>], _ a: PhotoAdjustments, raw: Bool = true) -> [SIMD3<Double>] {
        let px = pixels(PhotoRender.adjusted(swatches(colours), a, isRaw: raw, kelvin: 5500)), w = colours.count * 4
        return colours.indices.map { i in let j = (4 * w + i * 4 + 2) * 4; return SIMD3(Double(px[j]), Double(px[j + 1]), Double(px[j + 2])) }
    }

    private static func okLCh(_ c: SIMD3<Double>) -> (L: Double, C: Double, h: Double) {
        let (L, a, b) = OkLab.from(c.x, c.y, c.z)
        let h = atan2(b, a) * 180 / .pi
        return (L, (a * a + b * b).squareRoot(), h < 0 ? h + 360 : h)
    }

    /// CIEDE2000 (CIE 142-2001).
    static func deltaE00(_ p: SIMD3<Double>, _ q: SIMD3<Double>) -> Double {
        let rad = Double.pi / 180
        let c1 = (p.y * p.y + p.z * p.z).squareRoot(), c2 = (q.y * q.y + q.z * q.z).squareRoot(), cb = (c1 + c2) / 2
        let g = 0.5 * (1 - (pow(cb, 7) / (pow(cb, 7) + pow(25, 7))).squareRoot())
        let a1 = (1 + g) * p.y, a2 = (1 + g) * q.y
        let C1 = (a1 * a1 + p.z * p.z).squareRoot(), C2 = (a2 * a2 + q.z * q.z).squareRoot()
        func hue(_ b: Double, _ a: Double) -> Double { a == 0 && b == 0 ? 0 : (atan2(b, a) / rad + 360).truncatingRemainder(dividingBy: 360) }
        let h1 = hue(p.z, a1), h2 = hue(q.z, a2)
        var dh = h2 - h1
        if C1 * C2 == 0 { dh = 0 } else if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
        let dL = q.x - p.x, dC = C2 - C1, dH = 2 * (C1 * C2).squareRoot() * sin(dh / 2 * rad)
        let Lb = (p.x + q.x) / 2, Cb = (C1 + C2) / 2
        var hb = h1 + h2
        if C1 * C2 != 0 { hb = abs(h1 - h2) > 180 ? (hb < 360 ? (hb + 360) / 2 : (hb - 360) / 2) : hb / 2 }
        let t = 1 - 0.17 * cos((hb - 30) * rad) + 0.24 * cos(2 * hb * rad) + 0.32 * cos((3 * hb + 6) * rad) - 0.2 * cos((4 * hb - 63) * rad)
        let rot = 30 * exp(-pow((hb - 275) / 25, 2)), rc = 2 * (pow(Cb, 7) / (pow(Cb, 7) + pow(25, 7))).squareRoot()
        let sl = 1 + 0.015 * pow(Lb - 50, 2) / (20 + pow(Lb - 50, 2)).squareRoot(), sc = 1 + 0.045 * Cb, sh = 1 + 0.015 * Cb * t
        let rt = -sin(2 * rot * rad) * rc
        return (pow(dL / sl, 2) + pow(dC / sc, 2) + pow(dH / sh, 2) + rt * (dC / sc) * (dH / sh)).squareRoot()
    }

    /// Accurate keeps a colour chart: each patch's reference chromaticity at the brightness the tone curve gives it (the
    /// curve is a choice, not an error), mean ΔE00 under 1 and the largest under 2.5, at −1, 0 and +1 stop, with Apple's
    /// extra yellow-green colour taken out (without that, over 2.5). Patches whose colour can't be shown that bright (past
    /// ProPhoto) don't count.
    private static func chartKept() {
        let input = decodedChart()
        let k = 0.18 / ColourProfiles.mul(ColourProfiles.proToXYZ, ColourProfiles.fromLab(chart[21].x, chart[21].y, chart[21].z)).y
        func errors(_ stops: Double, raw: Bool) -> (mean: Double, max: Double, worst: Int, counted: Int) {
            var a = PhotoAdjustments(); a.profile = .accurate; a.exposure = stops
            let out = developed(input, a, raw: raw)
            var all: [(Double, Int)] = []
            for (i, c) in out.enumerated() {
                let pro = ColourProfiles.mul(PhotoEngine.toProPhoto, c)
                let Y = ColourProfiles.mul(ColourProfiles.proToXYZ, pro).y
                let reference = ColourProfiles.fromLab(chart[i].x, chart[i].y, chart[i].z) * k
                let ideal = reference * (Y / ColourProfiles.mul(ColourProfiles.proToXYZ, reference).y)
                guard ideal.max() <= 1 else { continue }
                let (L1, a1, b1) = ColourProfiles.toLab(ideal), (L2, a2, b2) = ColourProfiles.toLab(pro)
                all.append((deltaE00(SIMD3(L1, a1, b1), SIMD3(L2, a2, b2)), i + 1))
            }
            let worst = all.max { $0.0 < $1.0 } ?? (0, 0)
            return (all.map(\.0).reduce(0, +) / Double(max(all.count, 1)), worst.0, worst.1, all.count)
        }
        let results = [-1.0, 0, 1].map { errors($0, raw: true) }, uncorrected = errors(0, raw: false)
        let text = results.map { String(format: "mean %.2f max %.2f (#%d, %d patches)", $0.mean, $0.max, $0.worst, $0.counted) }.joined(separator: "; ")
        note("accurate chart −1/0/+1 stop: \(text); uncorrected (no table) at 0: mean \(String(format: "%.2f", uncorrected.mean)) max \(String(format: "%.2f", uncorrected.max))")
        check("accurate keeps the chart", results.allSatisfy { $0.mean < 1 && $0.max < 2.5 && $0.counted >= 11 } && results[1].counted == 24 && uncorrected.max > 2.5,
              "ΔE00 mean < 1, max < 2.5 at −1/0/+1 stop; without the correction max > 2.5; got \(text); uncorrected mean \(uncorrected.mean) max \(uncorrected.max)")
    }

    /// Hues hold through exposure: the chart's 18 colours from 4 stops under to 3 over, each one's OkLab hue within 2° of its
    /// hue at 0 (Accurate) or 4° (Classic, Vivid, Landscape, Portrait) while it's under 90% of white's lightness; the blue
    /// (13) and red (15) patches in particular, which went purple and magenta.
    private static func huesHold() {
        let input = Array(decodedChart().prefix(18))
        var failures: [String] = []
        for profile in [PhotoEngine.Profile.accurate, .adobe, .vivid, .landscape, .portrait] {
            var a = PhotoAdjustments(); a.profile = profile
            a.exposure = 0
            let mid = developed(input, a).map(okLCh)
            var worst = (0.0, 0)
            for stops in stride(from: -4.0, through: 3, by: 0.5) {
                a.exposure = stops
                for (i, c) in developed(input, a).map(okLCh).enumerated() where c.L < 0.9 && c.C > 0.01 {
                    var d = abs(c.h - mid[i].h).truncatingRemainder(dividingBy: 360)
                    if d > 180 { d = 360 - d }
                    if d > worst.0 { worst = (d, i + 1) }
                }
            }
            note("hue drift \(profile.rawValue): \(String(format: "%.2f", worst.0))° (#\(worst.1))")
            if worst.0 >= (profile == .accurate ? 2 : 4) { failures.append("\(profile.rawValue) \(String(format: "%.1f", worst.0))° (#\(worst.1))") }
        }
        check("hues hold through exposure", failures.isEmpty, "within 2° (Accurate) or 4°; got \(failures)")
    }

    /// Near-whites go to white: faintly coloured whites (OkLab chroma 0.02, six hues including lavender and green) from half
    /// to 16× white, every version 3 profile: no more colourful (for their lightness) than they came in, less and less
    /// colourful (for their lightness) once over 80% lightness, white (chroma under 0.002) past the curve's white; and grey stays exactly grey.
    private static func nearWhitesWhite() {
        let levels: [Float] = [0.5, 1, 2, 4, 8, 16]
        let tints = [30.0, 90, 140, 200, 260, 300].map { h -> SIMD3<Float> in
            let (r, g, b) = OkLab.to(1, 0.02 * cos(h * .pi / 180), 0.02 * sin(h * .pi / 180))
            return SIMD3(Float(r), Float(g), Float(b))
        }
        let inChroma = okLCh(SIMD3<Double>(tints[0])).C / okLCh(SIMD3<Double>(tints[0])).L
        var failures: [String] = []
        for profile in newProfiles {
            var a = PhotoAdjustments(); a.profile = profile
            let colours = tints.flatMap { t in levels.map { t * $0 } } + levels.map { SIMD3(repeating: 0.9 * $0) }
            let out = developed(colours, a).map(okLCh)
            for (n, _) in tints.enumerated() {
                let run = Array(out[(n * levels.count)..<((n + 1) * levels.count)])
                for (i, c) in run.enumerated() {
                    if profile != .monochrome, c.C / max(c.L, 1e-6) > inChroma * 1.2 + 1e-4 { failures.append("\(profile.rawValue) hue \(n) ×\(levels[i]): more colourful \(c.C)") }
                    // (Colourfulness for its lightness: Accurate keeps chromaticity, so chroma alone grows with lightness.)
                    let was = run[max(i - 1, 0)].C / max(run[max(i - 1, 0)].L, 1e-6)
                    if i > 0, c.L >= 0.8, c.C / max(c.L, 1e-6) > was * 1.01 + 2e-4 { failures.append("\(profile.rawValue) hue \(n) ×\(levels[i]): colourfulness rose \(was) → \(c.C / c.L)") }
                }
                if run.last!.C >= 0.002 { failures.append("\(profile.rawValue) hue \(n) ×16: \(run.last!.C)") }
            }
            let greys = out.suffix(levels.count)
            if let off = greys.first(where: { $0.C >= 1e-4 }) { failures.append("\(profile.rawValue) grey: \(off.C)") }
        }
        check("near-whites go to white", failures.isEmpty, "got \(failures.prefix(6))")
    }

    /// Switching profile doesn't jump in brightness: mid grey (the chart's patch 22) as light in every version 3 profile but
    /// Neutral (flatter, for grading) as in Classic, within 0.01 of OkLab lightness; and every table leaves grey alone.
    private static func sharedMidGrey() {
        func grey(_ profile: PhotoEngine.Profile) -> Double {
            var a = PhotoAdjustments(); a.profile = profile
            return okLCh(developed([SIMD3(repeating: 0.18)], a)[0]).L
        }
        let classic = grey(.adobe)
        let off = newProfiles.filter { $0 != .neutral }.map { ($0, grey($0) - classic) }.filter { abs($0.1) > 0.01 }
        check("profiles share mid grey", off.isEmpty, "within 0.01 of Classic's \(classic); got \(off)")
        let tables = PhotoEngine.Profile.allCases.compactMap { ColourProfiles.table($0, isRaw: true) }
        let greyKept = tables.allSatisfy { data in
            data.withUnsafeBytes { raw in
                let e = raw.bindMemory(to: SIMD4<Float>.self)
                return (0..<ColourProfiles.hues).allSatisfy { e[$0 * ColourProfiles.saturations] == SIMD4(0, 1, 1, 0) }
            }
        }
        check("tables keep grey", tables.count == 6 && greyKept, "6 tables, each the same at saturation 0; got \(tables.count)")
    }

    /// Colourful colours sit deeper than grey, as in Lightroom (ColourProfiles.dense): the chart's red, blue, green and orange
    /// in Classic each 0.04…0.16 below Accurate's OkLab lightness (Accurate's is a grey's of the same light: its luminance
    /// within 2% of that grey's), light skin within 0.02 and grey 0.005; Vivid and Landscape at least 0.04 deeper, Portrait and
    /// Neutral (half the density) at least 0.01.
    /// (Process 3: process 4's Classic has half the density, fading out on strong colour, as Apple's default has none.)
    private static func colourHasDensity() {
        let chart = decodedChart(), picked = [14, 12, 13, 6, 1], names = ["red", "blue", "green", "orange", "light skin"]
        func luminance(_ c: SIMD3<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
        let colours = picked.map { chart[$0] }, greys = colours.map { SIMD3(repeating: luminance($0)) }
        func run(_ profile: PhotoEngine.Profile) -> [SIMD3<Double>] {
            var a = PhotoAdjustments(); a.process = 3; a.profile = profile; return developed(colours + greys, a)
        }
        let accurate = run(.accurate), n = colours.count
        let unchanged = (0..<n).map { i -> Double in
            let y = { (c: SIMD3<Double>) in 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
            return y(accurate[i]) / y(accurate[n + i]) - 1
        }
        func deeper(_ profile: PhotoEngine.Profile) -> [Double] { zip(run(profile), accurate).prefix(n).map { okLCh($0).L - okLCh($1).L } }
        let classic = deeper(.adobe), grey = okLCh(run(.adobe)[n + 3]).L - okLCh(accurate[n + 3]).L
        let others = [PhotoEngine.Profile.vivid, .landscape, .portrait, .neutral].map { ($0, deeper($0)) }
        let text = zip(names, classic).map { "\($0) \(String(format: "%+.3f", $1))" }.joined(separator: ", ")
            + "; grey \(String(format: "%+.3f", grey)); accurate luminance against grey \(unchanged.map { String(format: "%+.3f", $0) })"
            + others.map { "; \($0.0.rawValue) \($0.1.prefix(4).map { String(format: "%+.3f", $0) })" }.joined()
        note("density (OkLab L against Accurate): \(text)")
        let strong = classic.prefix(4).allSatisfy { $0 <= -0.04 && $0 >= -0.16 }
        let quiet = abs(classic[4]) <= 0.02 && abs(grey) <= 0.005 && unchanged.allSatisfy { abs($0) < 0.02 }
        let rest = others.allSatisfy { profile, d in d.prefix(4).allSatisfy { $0 <= ([.portrait, .neutral].contains(profile) ? -0.01 : -0.04) } }
        check("colour has density", strong && quiet && rest,
              "Classic's red, blue, green, orange 0.04…0.16 below Accurate, skin within 0.02, grey 0.005, Accurate a grey's luminance; got \(text)")
    }

    /// The new profiles go through copy and paste, reset, saved settings and Lightroom's presets: Adobe's profiles start from
    /// Classic, except Monochrome, Vivid, Landscape and Portrait, which have their own. An older Pluck reading a profile it
    /// doesn't know keeps the rest of the edit (the profile then the starting one).
    private static func profilesTravel() {
        let from = "/tmp/pluck-selftest/profile-from.jpg", to = "/tmp/pluck-selftest/profile-to.jpg"
        let catalog = PhotoCatalog.shared
        catalog.update([from]) { $0.adjust.profile = .portrait; $0.adjust.exposure = 0.4 }
        PhotoPasteboard.copy(from)
        PhotoPasteboard.paste([.profile], to: [to])
        let pasted = catalog.record(to).adjust.profile
        let reset = PhotoAdjustments()  // (the inspector's Reset)
        let saved = (try? JSONEncoder().encode(catalog.record(from).adjust)).flatMap { try? JSONDecoder().decode(PhotoAdjustments.self, from: $0) }
        let unknown = try? JSONDecoder().decode(PhotoAdjustments.self, from: Data(#"{"exposure":0.4,"profile":"calibrated","process":3}"#.utf8))
        check("new profiles copy, paste and reset", pasted == .portrait && PhotoEngine.Profile.starting(reset, isRaw: true) == .standard
              && saved?.profile == .portrait && unknown?.profile == nil && unknown?.exposure == 0.4,
              "pasted Portrait, reset to Standard (process 5's start), saved and read back, an unknown one read as none; got \(String(describing: pasted)), \(String(describing: saved?.profile)), \(String(describing: unknown))")
        let names = ["Adobe Color": PhotoEngine.Profile.adobe, "Adobe Standard": .adobe, "Adobe Neutral": .adobe, "Adobe Monochrome": .monochrome,
                     "Adobe Vivid": .vivid, "Adobe Landscape": .landscape, "Adobe Portrait": .portrait]
        let wrong = names.filter { LightroomPresets.adjustments(["CameraProfile": $0.key]).0.profile != $0.value }.map(\.key)
        check("lightroom profiles map to pluck's", wrong.isEmpty, "each Adobe profile to its own; wrong for \(wrong)")
    }

    /// Classic against Lightroom (Adobe Color) on the real RAW kept outside the repo, at Lightroom's settings: the lawn
    /// through the window (OkLab a −4.6 in Lightroom; −5.6 before) and the teal pot in the shade (red to green 0.16 in
    /// Lightroom; 0.44 before).
    private static func lightroomColours() {
        let raw = URL(fileURLWithPath: photos).deletingLastPathComponent().appendingPathComponent("greencast/DSC01962.ARW").path
        guard FileManager.default.fileExists(atPath: raw) else { skip("classic's lawn and pot like lightroom's", "no DSC01962.ARW"); return }
        var record = PhotoRecord()
        record.adjust.process = 3  // (Lightroom-tuned Classic: process 4's follows Apple's default colour instead, see lrGapFixes.)
        record.adjust.profile = .adobe; record.adjust.exposure = 2.25; record.adjust.highlights = -100; record.adjust.shadows = 100
        record.adjust.colorNoise = 25; record.adjust.sharpen = 40
        BaseCache.shared.removeAll(); GuideCache.shared.removeAll()
        guard let image = PhotoRender.image(raw, record: record, maxSize: 1500), let picture = PhotoRender.picture(image, maxSize: 1500) else {
            check("classic's lawn and pot like lightroom's", false, "not rendered"); return
        }
        let shown = CIImage(cgImage: picture), e = shown.extent
        // Shares of the frame from the top left.
        func mean(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> SIMD3<Double> {
            let r = CGRect(x: e.minX + x0 * e.width, y: e.maxY - y1 * e.height, width: (x1 - x0) * e.width, height: (y1 - y0) * e.height)
            let px = pixels(shown.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: r)]).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1)))
            return SIMD3(Double(px[0]), Double(px[1]), Double(px[2]))
        }
        let lawn = OkLab.from(mean(0.73, 0.42, 0.83, 0.52).x, mean(0.73, 0.42, 0.83, 0.52).y, mean(0.73, 0.42, 0.83, 0.52).z).1 * 100
        let pot = mean(0.1437, 0.7588, 0.1791, 0.8054)
        note(String(format: "classic lawn OkLab a %.2f, pot r/g %.2f b/g %.2f (1500 px, area mean)", lawn, pot.x / pot.y, pot.z / pot.y))
        check("classic's lawn and pot like lightroom's", abs(lawn + 4.6) <= 0.6 && pot.x / pot.y <= 0.3,
              "lawn OkLab a −4.6 ± 0.6, pot red to green at most 0.3 (Lightroom 0.16); got \(String(format: "%.2f", lawn)), \(String(format: "%.2f", pot.x / pot.y))")
    }

    /// Versions 1 and 2 with every profile they had, plain and edited: the same pixels as before version 3's profiles (each a
    /// fingerprint of a row of colours: per channel the sum and the sum weighted by place).
    private static func oldProfilesUnchanged() {
        let colours: [SIMD3<Float>] = [
            SIMD3(0.18, 0.18, 0.18), SIMD3(0.02, 0.02, 0.02), SIMD3(0.9, 0.9, 0.9), SIMD3(3, 3, 3), SIMD3(0.17, 0.08, 0.05), SIMD3(0.5, 0.3, 0.22),
            SIMD3(0.1, 0.18, 0.33), SIMD3(0.08, 0.14, 0.04), SIMD3(0.2, 0.2, 0.42), SIMD3(0.05, 0.4, 0.4), SIMD3(0.75, 0.38, 0.02), SIMD3(0.04, 0.06, 0.3),
            SIMD3(0.6, 0.06, 0.08), SIMD3(0.07, 0.03, 0.12), SIMD3(0.35, 0.5, 0.03), SIMD3(0.9, 0.55, 0.01), SIMD3(0.02, 0.03, 0.2), SIMD3(0.06, 0.3, 0.06),
            SIMD3(0.4, 0.02, 0.02), SIMD3(0.95, 0.8, 0.02), SIMD3(0.6, 0.1, 0.4), SIMD3(-0.03, 0.2, 0.3), SIMD3(1.6, 1.2, 1.7), SIMD3(0.004, 0.006, 0.003),
        ]
        let row = swatches(colours)
        func edited(_ a: inout PhotoAdjustments) {
            a.exposure = 0.5; a.contrast = 20; a.highlights = -40; a.shadows = 30; a.whites = 10; a.blacks = -10
            a.saturation = 10; a.vibrance = 15; a.mixer.hue[3] = 20
        }
        var got: [Double] = []
        for process in [1, 2] {
            for profile in [PhotoEngine.Profile.neutral, .standard, .vivid, .flat, .monochrome, .asShot, .adobe] {
                for edit in [false, true] {
                    var a = PhotoAdjustments(); a.process = process; a.profile = profile
                    if edit { edited(&a) }
                    let px = pixels(PhotoRender.adjusted(row, a, isRaw: profile != .asShot, kelvin: 5500))
                    var sum = SIMD3<Double>(), placed = SIMD3<Double>()
                    for i in 0..<(px.count / 4) {
                        let c = SIMD3(Double(px[i * 4]), Double(px[i * 4 + 1]), Double(px[i * 4 + 2]))
                        sum += c; placed += c * Double(i % (colours.count * 4) + 1) / 100
                    }
                    got += [sum.x, sum.y, sum.z, placed.x, placed.y, placed.z]
                }
            }
        }
        let was = processTwoFingerprints
        let worst = zip(got, was).map { abs($0 - $1) / max(abs($1), 1e-3) }.max() ?? 1
        check("old profiles render as before", was.count == got.count && worst < 2e-4,
              "versions 1 and 2, every profile, plain and edited, within 0.02%; worst \(worst), got [\(got.map { String(format: "%.5f", $0) }.joined(separator: ", "))]")
    }

    /// Measured on the build before version 3's colour profiles (versions 1 and 2, 7 profiles, plain and edited, 6 numbers each).
    private static let processTwoFingerprints: [Double] = [
        255.12161, 227.61450, 202.99718, 124.40653, 107.00149, 92.49429, 291.06084, 260.42632, 237.69624, 141.86497, 122.45368, 109.23275,
        225.10559, 188.43410, 159.71949, 112.32773, 88.55841, 70.36323, 265.20570, 223.69895, 203.42517, 132.25616, 105.10376, 91.98455,
        231.11452, 188.03125, 163.36289, 116.07333, 88.32634, 72.65625, 273.04279, 223.41684, 209.21239, 137.16517, 104.94353, 95.40488,
        239.45581, 212.66406, 196.80090, 116.49148, 99.63102, 90.50732, 269.25164, 239.24751, 225.29096, 131.05274, 112.18456, 104.20785,
        231.71027, 231.71027, 231.71027, 109.67050, 109.67050, 109.67050, 264.99239, 265.10130, 265.15705, 125.44257, 125.53095, 125.53724,
        286.14746, 237.90283, 195.89722, 143.23814, 113.69950, 85.85189, 340.56854, 282.76903, 241.51446, 169.56849, 135.22967, 106.70703,
        255.12161, 227.61450, 202.99718, 124.40653, 107.00149, 92.49429, 291.06084, 260.42632, 237.69624, 141.86497, 122.45368, 109.23275,
        258.54932, 230.88135, 208.73587, 126.11047, 108.69108, 95.72966, 299.03796, 264.74420, 247.41687, 146.57612, 124.93348, 115.08264,
        282.87605, 243.52765, 211.71225, 140.11917, 115.29693, 96.13345, 331.19657, 283.19406, 260.06552, 164.70263, 134.23346, 120.49962,
        295.41151, 245.68990, 214.02997, 148.00000, 116.34256, 97.02449, 348.54615, 286.48674, 273.10681, 175.52634, 135.75682, 127.64795,
        237.56836, 217.43579, 201.30182, 114.54413, 101.88370, 92.71288, 270.00742, 244.97839, 231.54727, 130.94809, 115.15458, 107.80370,
        239.33539, 239.33539, 239.33539, 113.72009, 113.72009, 113.72009, 277.52213, 277.52213, 277.52213, 132.46034, 132.46034, 132.46034,
        286.12683, 237.84863, 195.88525, 143.22937, 113.66514, 85.84745, 327.06906, 260.95001, 234.84225, 165.06440, 124.58429, 105.88115,
        321.07086, 279.41943, 235.66199, 160.81380, 134.43439, 106.76325, 370.22038, 330.16861, 297.01335, 184.15854, 158.21033, 137.02112,
    ]
}
