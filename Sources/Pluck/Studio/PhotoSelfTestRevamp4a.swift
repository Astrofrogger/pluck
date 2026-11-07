import AppKit
import CoreImage
import Foundation
import ImageIO
import simd
import SwiftUI
import UniformTypeIdentifiers

/// Process 5's colour curves (Hue vs Hue, Hue vs Saturation, Hue vs Luminance, Luminance vs Saturation, Saturation vs
/// Saturation) and colour points (Colour Mixer): flat changes nothing, a curve moves only its hues and goes round at red,
/// Hue vs Luminance is the same stops at any exposure, a point reaches only its range and fades smoothly, the slider stays quick.
extension PhotoSelfTest {
    private static func r4Y(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
    private static func r4CL(_ c: SIMD3<Double>) -> Double { let o = fsLab(c); return fsChroma(o) / max(o.x, 1e-6) }
    /// OkLab distance ×100 (about 1 is just visible).
    private static func r4DE(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { simd_length(fsLab(a) - fsLab(b)) * 100 }
    /// A finished picture (as shot) through the engine, before the screen's gamut map: what the colour tools do.
    private static func r4Picture(_ image: CIImage, _ a: PhotoAdjustments) -> [SIMD3<Double>] {
        var a = a; a.profile = .asShot
        return fsPixels(PhotoRender.adjusted(image, a, isRaw: false, kelvin: 5500), image.extent)
    }
    /// A hue ring, 360 × 4 (x = OkLCh hue in degrees), L 0.6, C 0.06.
    private static func r4Ring(_ L: Double = 0.6, _ C: Double = 0.06) -> CIImage {
        fsImage(360, 4) { x, _ in
            let h = Double(x) * .pi / 180, (r, g, b) = OkLab.to(L, C * cos(h), C * sin(h))
            return SIMD3(Float(r), Float(g), Float(b))
        }
    }
    /// The hue turn at each x of a ring's middle row, in degrees.
    private static func r4Turns(_ base: [SIMD3<Double>], _ moved: [SIMD3<Double>], width: Int = 360) -> [Double] {
        (0..<width).map { x in
            let d = fsHue(fsLab(moved[2 * width + x])) - fsHue(fsLab(base[2 * width + x]))
            return d > 180 ? d - 360 : d < -180 ? d + 360 : d
        }
    }
    /// A hue curve: flat (Resolve's six) with these hues (degrees) set to these heights.
    private static func r4Hue(_ set: [(Double, Double)]) -> [CurvePoint] {
        let start = HueCurves.Kind.hueHue.start.filter { p in !set.contains { abs($0.0 / 360 - p.x) < 25.0 / 360 } }
        return (start + set.map { CurvePoint(x: $0.0 / 360, y: $0.1) }).sorted { $0.x < $1.x }
    }

    static func revamp4a() async {
        colourToolsFlat()
        hueCurveChecks()
        hueLumExposure()
        lumSatEnds()
        pointChecks()
        colourToolsCodable()
        await colourToolsSpeed()
        await revamp4aDump()
    }

    // MARK: Off is off

    /// Flat curves (Resolve's six points, all in the middle) and points that change nothing render exactly as none.
    private static func colourToolsFlat() {
        let ring = r4Ring(), ramp = fsImage(64, 4) { x, _ in SIMD3(repeating: Float(0.18 * exp2(Double(x) / 6 - 7))) }
        var plain = PhotoAdjustments(), flat = PhotoAdjustments()
        var curves = HueCurves()
        for kind in HueCurves.Kind.allCases { curves[keyPath: kind.path] = kind.start }
        flat.curves.hue = curves
        flat.mixer.points = [ColourPoint(hue: 40, sat: 0.1, lum: 0.6)]
        var same = true, notes: [String] = []
        for image in [ring, ramp] {
            for raw in [true, false] {
                let a = fsPixels(PhotoRender.adjusted(image, plain, isRaw: raw, kelvin: 5500), image.extent)
                let b = fsPixels(PhotoRender.adjusted(image, flat, isRaw: raw, kelvin: 5500), image.extent)
                let differ = zip(a, b).filter { $0.0 != $0.1 }.count
                if differ > 0 { same = false; notes.append("\(raw ? "RAW" : "picture"): \(differ) pixels differ") }
            }
        }
        plain.mixer.points = []
        check("colour tools flat render as none", same && PhotoEngine.colourTools(flat) == nil && PhotoEngine.colourTools(plain) == nil
              && flat.curves.hue!.isDefault && !flat.mixer.isDefault, notes.joined(separator: "; "))
    }

    // MARK: Hue vs Hue

    /// Hue vs Hue +30° at red: red turns 30° (±2), green and blue under 1°; a point at 355° turns both sides of the seam
    /// alike, smoothly.
    private static func hueCurveChecks() {
        let ring = r4Ring()
        var a = PhotoAdjustments(); a.process = 5
        let base = r4Picture(ring, a)
        // (Height 0.75 is +30°: ±60° over the curve's half height.)
        a.curves.hue = HueCurves(hueHue: r4Hue([(29.2, 0.75)]))
        let t = r4Turns(base, r4Picture(ring, a))
        let step = (1..<360).map { abs(t[$0] - t[$0 - 1]) }.max()!
        note(String(format: "hue vs hue +30° at red: 29° %+.1f°, 110° %+.2f°, 142° %+.2f°, 264° %+.2f°, 328° %+.2f°, largest step %.2f°", t[29], t[110], t[142], t[264], t[328], step))
        check("hue vs hue moves only its hues", abs(t[29] - 30) < 2 && abs(t[142]) < 1 && abs(t[264]) < 1 && abs(t[194]) < 1 && step < 2.5,
              String(format: "29° %+.1f (30), 142° %+.2f, 194° %+.2f, 264° %+.2f (under 1), step %.2f", t[29], t[142], t[194], t[264], step))
        // Round the seam: a point at 355° (between magenta 328° and red 29°).
        a.curves.hue = HueCurves(hueHue: (HueCurves.Kind.hueHue.start + [CurvePoint(x: 355 / 360, y: 0.75)]).sorted { $0.x < $1.x })
        let w = r4Turns(base, r4Picture(ring, a))
        let seam = (1..<360).map { abs(w[$0] - w[$0 - 1]) }.max()!, across = abs(w[0] - w[359])
        note(String(format: "hue vs hue +30° at 355°: 340° %+.1f°, 355° %+.1f°, 359° %+.1f°, 0° %+.1f°, 10° %+.1f°, 142° %+.2f°; step %.2f°", w[340], w[355], w[359], w[0], w[10], w[142], seam))
        check("hue vs hue goes round at red", abs(w[355] - 30) < 2 && across < 1.5 && w[0] > 20 && seam < 2.5 && abs(w[142]) < 1,
              String(format: "355° %+.1f (30), 359°/0° %+.1f/%+.1f (alike), step %.2f, 142° %+.2f", w[355], w[359], w[0], seam, w[142]))
    }

    // MARK: Hue vs Luminance

    /// The same red at −2, 0 and +2 EV (RAW): Hue vs Lum at its lowest gives the same stops (about −1) and keeps C/L.
    private static func hueLumExposure() {
        let red = fsImage(16, 16) { _, _ in SIMD3(0.40, 0.035, 0.03) }
        func shown(_ a: PhotoAdjustments) -> SIMD3<Double> { fsPixels(PhotoRender.adjusted(red, a, isRaw: true, kelvin: 5500), red.extent)[8 * 16 + 8] }
        var hue = 0.0
        do { var a = PhotoAdjustments(); a.profile = .adobe; hue = fsHue(fsLab(shown(a))); if hue < 0 { hue += 360 } }
        var stops: [Double] = [], keeps: [Double] = []
        for ev in [-2.0, 0, 2] {
            var a = PhotoAdjustments(); a.exposure = ev; a.profile = .adobe
            let before = shown(a)
            a.curves.hue = HueCurves(hueLum: r4Hue([(hue - 12, 0), (hue, 0), (hue + 12, 0)]))
            let after = shown(a)
            stops.append(log2(max(r4Y(after), 1e-9) / max(r4Y(before), 1e-9)))
            keeps.append(r4CL(after) / r4CL(before))
        }
        let spread = stops.max()! - stops.min()!
        let row = String(format: "red (hue %.0f°) at −2/0/+2 EV: %+.3f %+.3f %+.3f stops, C/L × %.3f %.3f %.3f", hue, stops[0], stops[1], stops[2], keeps[0], keeps[1], keeps[2])
        note("hue vs lum −100: " + row)
        check("hue vs lum same stops at any exposure", spread < 0.05 && stops.allSatisfy { $0 < -0.85 && $0 > -1.1 } && keeps.allSatisfy { abs($0 - 1) < 0.05 }, row)
    }

    // MARK: Luminance vs Saturation

    /// An orange from black to white: Lum vs Sat at 0 on the left end greys the shadows, keeps the light end; at 0 on the right
    /// end the other way round.
    private static func lumSatEnds() {
        let ramp = fsImage(64, 4) { x, _ in
            let L = 0.05 + 0.9 * Double(x) / 63, (r, g, b) = OkLab.to(L, 0.1 * L * cos(0.9), 0.1 * L * sin(0.9))
            return SIMD3(Float(r), Float(g), Float(b))
        }
        var a = PhotoAdjustments()
        let base = r4Picture(ramp, a)
        func ratio(_ px: [SIMD3<Double>], _ x: Int) -> Double { r4CL(px[2 * 64 + x]) / max(r4CL(base[2 * 64 + x]), 1e-9) }
        a.curves.hue = HueCurves(lumSat: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.5), CurvePoint(x: 1, y: 0.5)])
        let dark = r4Picture(ramp, a)
        a.curves.hue = HueCurves(lumSat: [CurvePoint(x: 0, y: 0.5), CurvePoint(x: 0.5, y: 0.5), CurvePoint(x: 1, y: 0)])
        let light = r4Picture(ramp, a)
        let L = { (x: Int) in fsLab(base[2 * 64 + x]).x }
        let low = 1, high = 62, mid = (0..<64).min { abs(L($0) - 0.5) < abs(L($1) - 0.5) }!
        let row = String(format: "L %.2f / %.2f / %.2f: left end at 0 → C/L × %.2f / %.2f / %.2f; right end at 0 → × %.2f / %.2f / %.2f",
                         L(low), L(mid), L(high), ratio(dark, low), ratio(dark, mid), ratio(dark, high), ratio(light, low), ratio(light, mid), ratio(light, high))
        note("lum vs sat: " + row)
        check("lum vs sat at black and white", ratio(dark, low) < 0.2 && abs(ratio(dark, high) - 1) < 0.03 && abs(ratio(dark, mid) - 1) < 0.05
              && ratio(light, high) < 0.25 && abs(ratio(light, low) - 1) < 0.03, row)
    }

    // MARK: Colour points

    /// Six patches (skin, sky, foliage, red, yellow, violet): a point picked on skin (Saturation −100) and one on the sky
    /// (Luminance −60) each change their patch and leave the others (OkLab ΔE under 1); a point's weight round the hue circle
    /// is smooth and ends where its Range says; Range 0 → 100 widens it a little at a time; the red overlay only when asked.
    private static func pointChecks() {
        let colours: [SIMD3<Float>] = [SIMD3(0.55, 0.33, 0.24), SIMD3(0.20, 0.38, 0.75), SIMD3(0.10, 0.24, 0.05),
                                       SIMD3(0.55, 0.04, 0.04), SIMD3(0.75, 0.62, 0.05), SIMD3(0.25, 0.08, 0.45)]
        let chart = fsImage(96, 16) { x, _ in colours[x / 16] }
        let names = ["skin", "sky", "foliage", "red", "yellow", "violet"]
        var a = PhotoAdjustments()
        let base = r4Picture(chart, a)
        func patch(_ px: [SIMD3<Double>], _ i: Int) -> SIMD3<Double> { px[8 * 96 + i * 16 + 8] }
        var rows: [String] = [], ok = true
        for (target, change) in [(0, { (p: inout ColourPoint) in p.saturation = -100 }), (1, { (p: inout ColourPoint) in p.luminance = -60 })] {
            var point = ColourPoint.picked(patch(base, target))
            change(&point)
            a.mixer.points = [point]
            let px = r4Picture(chart, a)
            let moved = (0..<6).map { r4DE(patch(px, $0), patch(base, $0)) }
            let others = moved.enumerated().filter { $0.offset != target }.map(\.element).max()!
            rows.append(String(format: "%@ point: its patch ΔE %.1f, others at most %.2f (%@)", names[target], moved[target], others,
                               moved.map { String(format: "%.2f", $0) }.joined(separator: " ")))
            ok = ok && moved[target] > 5 && others < 1
        }
        note("point colour on six patches: " + rows.joined(separator: "; "))
        check("point colour changes only its colour", ok, rows.joined(separator: "; "))

        // The weight round the hue circle (Saturation −100: weight = 1 − C/L kept) for Range 0 … 100.
        let ring = r4Ring()
        a = PhotoAdjustments()
        let plain = r4Picture(ring, a)
        let centre = 60, seen = patchRow(plain, centre)
        var weights: [Int: [Double]] = [:]
        for range in stride(from: 0, through: 100, by: 5) {
            var p = ColourPoint.picked(seen); p.saturation = -100; p.range = Double(range)
            a.mixer.points = [p]
            let px = r4Picture(ring, a)
            weights[range] = (0..<360).map { 1 - r4CL(px[2 * 360 + $0]) / max(r4CL(plain[2 * 360 + $0]), 1e-9) }
        }
        var smooth = 0.0, outside = 0.0, inner = 1.0, widen = 0.0, shrinks = 0.0
        for (range, w) in weights {
            smooth = max(smooth, (1..<360).map { abs(w[$0] - w[$0 - 1]) }.max()!)
            let reach = 15 + 45 * Double(range) / 100
            for x in 0..<360 {
                var d = abs(Double(x - centre)).truncatingRemainder(dividingBy: 360); if d > 180 { d = 360 - d }
                if d > reach + 3 { outside = max(outside, abs(w[x])) }
            }
            inner = min(inner, w[centre])
            if range >= 5, let before = weights[range - 5] {
                widen = max(widen, abs(w[centre + 20] - before[centre + 20]), abs(w[centre - 20] - before[centre - 20]))
                shrinks = max(shrinks, before[centre + 20] - w[centre + 20])
            }
        }
        let row = String(format: "largest step between neighbouring degrees %.3f, outside the range %.4f, at the point ≥ %.3f, Range +5 moves the weight 20° away by ≤ %.3f (shrinks %.3f); at 20°: %@",
                          smooth, outside, inner, widen, shrinks, stride(from: 0, through: 100, by: 20).map { String(format: "%.2f", weights[$0]![centre + 20]) }.joined(separator: " "))
        note("point colour falloff: " + row)
        check("point colour falloff smooth", smooth < 0.15 && outside < 0.01 && inner > 0.97 && widen < 0.25 && shrinks < 1e-3, row)

        // The overlay: only with the point asked for, red where it reaches.
        var p = ColourPoint.picked(patch(base, 0)); p.saturation = -50
        a = PhotoAdjustments(); a.profile = .asShot; a.mixer.points = [p]
        let off = fsPixels(PhotoRender.adjusted(chart, a, isRaw: false, kelvin: 5500), chart.extent)
        let on = fsPixels(PhotoRender.adjusted(chart, a, isRaw: false, kelvin: 5500, overlay: -2), chart.extent)
        let reddened = patch(on, 0).x - patch(on, 0).y > patch(off, 0).x - patch(off, 0).y + 0.1, sky = r4DE(patch(on, 1), patch(off, 1))
        check("point colour overlay only when asked", reddened && sky < 0.5 && PhotoEngine.colourTools(a).map { $0.withUnsafeBytes { $0.load(fromByteOffset: 8, as: Float.self) } } == -1,
              "skin redder \(reddened), sky ΔE \(sky)")
    }

    private static func patchRow(_ px: [SIMD3<Double>], _ x: Int) -> SIMD3<Double> { px[2 * 360 + x] }

    // MARK: Saved

    /// The new settings save and read back; settings from before them read as none.
    private static func colourToolsCodable() {
        var a = PhotoAdjustments()
        a.curves.hue = HueCurves(hueSat: r4Hue([(200, 0.8)]), satSat: [CurvePoint(x: 0, y: 0.3), CurvePoint(x: 1, y: 0.5)])
        a.mixer.points = [ColourPoint(hue: 55, sat: 0.12, lum: 0.7, range: 30, hueShift: 10, saturation: -20, luminance: 5)]
        let back = (try? JSONEncoder().encode(a)).flatMap { try? JSONDecoder().decode(PhotoAdjustments.self, from: $0) }
        let old = try? JSONDecoder().decode(PhotoCurves.self, from: Data(#"{"master":[{"x":0,"y":0},{"x":1,"y":1}],"red":[{"x":0,"y":0},{"x":1,"y":1}],"green":[{"x":0,"y":0},{"x":1,"y":1}],"blue":[{"x":0,"y":0},{"x":1,"y":1}]}"#.utf8))
        let oldMixer = try? JSONDecoder().decode(ColorMixer.self, from: Data(#"{"hue":[0,0,0,0,0,0,0,0],"saturation":[0,0,0,0,0,0,0,0],"luminance":[0,0,0,0,0,0,0,0]}"#.utf8))
        check("colour tools saved and read back", back == a && old?.hue == nil && old?.isDefault == true && oldMixer?.points == nil && oldMixer?.isDefault == true,
              "round trip \(back == a), old curves \(String(describing: old?.hue)), old mixer \(String(describing: oldMixer?.points))")
    }

    // MARK: Speed

    /// A slider moved (DSC01994, 2048 px) with all five curves and eight points on, against none: as quick.
    private static func colourToolsSpeed() async {
        let arw = p4Raws.appendingPathComponent("DSC01994.ARW").path
        guard FileManager.default.fileExists(atPath: arw) else { skip("colour tools slider speed", "no DSC01994"); return }
        var tools = PhotoRecord()
        tools.adjust.curves.hue = HueCurves(hueHue: r4Hue([(30, 0.7)]), hueSat: r4Hue([(200, 0.8)]), hueLum: r4Hue([(140, 0.3)]),
                                            lumSat: [CurvePoint(x: 0, y: 0.2), CurvePoint(x: 1, y: 0.5)], satSat: [CurvePoint(x: 0, y: 0.5), CurvePoint(x: 1, y: 0.7)])
        tools.adjust.mixer.points = (0..<8).map { ColourPoint(hue: Double($0) * 45, sat: 0.15, lum: 0.6, hueShift: 20, saturation: -30, luminance: 10) }
        func ms(_ start: Date) -> Double { (Date().timeIntervalSince(start) * 1000).rounded() }
        var drag: [Bool: [Double]] = [:]
        for on in [false, true, false, true] {
            BaseCache.shared.removeAll(); GuideCache.shared.removeAll()
            let record = on ? tools : PhotoRecord()
            if let image = PhotoRender.image(arw, record: record, maxSize: 2048) { _ = PhotoRender.picture(image) }
            var times: [Double] = []
            for k in 0..<12 {
                var moved = record
                moved.adjust.exposure = Double(k) / 10
                let start = Date()
                if let image = PhotoRender.image(arw, record: moved, maxSize: 2048) { _ = PhotoRender.picture(image) }
                times.append(ms(start))
            }
            drag[on, default: []].append(times.sorted()[times.count / 2])
        }
        let off = drag[false]!.min()!, with = drag[true]!.min()!
        note("colour tools slider (DSC01994, 2048 px, median of 12, ms): none \(drag[false]!), five curves and eight points \(drag[true]!)")
        check("colour tools slider speed", with <= off * 1.3 + 5, "median \(with) ms against \(off)")
    }

    // MARK: The sheet's renders

    /// Into <photos>/../revamp4a/dump when that folder exists: 8-bit sRGB PNGs for the sheet, and the Curves and Colour
    /// Mixer sections as the inspector draws them.
    private static func revamp4aDump() async {
        let base = URL(fileURLWithPath: photos).deletingLastPathComponent()
        let out = base.appendingPathComponent("revamp4a/dump"), raws = base.appendingPathComponent("shootout/raws")
        guard FileManager.default.fileExists(atPath: out.path) else { return }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        func write(_ cg: CGImage, _ name: String) {
            guard let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, cg, nil); CGImageDestinationFinalize(dest)
        }
        func save(_ image: CIImage, _ name: String) {
            let e = image.extent.integral
            let placed = image.cropped(to: e).transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            if let cg = PhotoEngine.context.createCGImage(placed, from: placed.extent, format: .RGBA8, colorSpace: srgb) { write(cg, name) }
        }
        func decoded(_ file: String, _ a: PhotoAdjustments) -> CIImage? {
            let path = raws.appendingPathComponent(file).path
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            var record = PhotoRecord(); record.adjust = a
            BaseCache.shared.removeAll(); GuideCache.shared.removeAll()
            return PhotoRender.decoded(path, maxSize: 900, record: record).map { PhotoRender.output(PhotoRender.adjusted($0, a, path: path), a, p3: false) }
        }
        /// The colour at (x, y) (shares from the top left) of the photo as shown without the colour tools.
        func colour(_ image: CIImage, _ x: Double, _ y: Double) -> SIMD3<Double> {
            let e = image.extent
            let spot = CGRect(x: e.minX + x * e.width - 3, y: e.maxY - y * e.height - 3, width: 7, height: 7)
            let px = fsPixels(image.cropped(to: spot), spot.integral)
            return px.reduce(SIMD3(repeating: 0), +) / Double(max(px.count, 1))
        }
        // A wide hue ramp (hue across, colourfulness down) for the curves.
        let wide = fsImage(480, 120) { x, y in
            let h = Double(x) / 480 * 2 * .pi, C = 0.16 * (1 - Double(y) / 140), L = 0.72 - 0.25 * Double(y) / 120
            let (r, g, b) = OkLab.to(L, C * cos(h), C * sin(h))
            return SIMD3(Float(r), Float(g), Float(b))
        }
        let curveCases: [(String, HueCurves)] = [
            ("plain", HueCurves()),
            ("hue-hue", HueCurves(hueHue: r4Hue([(142.5, 0.8), (194.8, 0.35)]))),
            ("hue-sat", HueCurves(hueSat: r4Hue([(29.2, 0.0), (264.1, 0.9)]))),
            ("hue-lum", HueCurves(hueLum: r4Hue([(264.1, 0.0), (109.8, 0.8)]))),
            ("lum-sat", HueCurves(lumSat: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.45, y: 0.5), CurvePoint(x: 1, y: 0.5)])),
            ("sat-sat", HueCurves(satSat: [CurvePoint(x: 0, y: 0.5), CurvePoint(x: 0.25, y: 0.9), CurvePoint(x: 0.6, y: 0.5), CurvePoint(x: 1, y: 0.35)])),
        ]
        for (name, curves) in curveCases {
            var a = PhotoAdjustments(); a.profile = .asShot; a.curves.hue = curves.isDefault ? nil : curves
            save(PhotoRender.output(PhotoRender.adjusted(wide, a, isRaw: false, kelvin: 5500), a, p3: false), "ramp-\(name)")
            var b = PhotoAdjustments(); b.curves.hue = a.curves.hue
            if let image = decoded("DSC02845.ARW", b) { save(image, "photo-\(name)") }
        }
        // Points: on skin (R6LO7461) and on the sea (DSC02817, the bluest there is among the test RAWs).
        let pointCases: [(String, String, Double, Double, [(String, (inout ColourPoint) -> Void)])] = [
            ("skin", "R6LO7461.CR3", 0.545, 0.39, [("warmer", { $0.hueShift = -40; $0.saturation = 30 }), ("paler", { $0.saturation = -70; $0.luminance = 30 })]),
            ("sea", "DSC02817.ARW", 0.80, 0.25, [("teal", { $0.hueShift = -60; $0.saturation = 40 }), ("darker", { $0.luminance = -80; $0.saturation = 30 })]),
        ]
        for (name, file, x, y, changes) in pointCases {
            guard let plain = decoded(file, PhotoAdjustments()) else { continue }
            save(plain, "point-\(name)-plain")
            let point = ColourPoint.picked(colour(plain, x, y))
            note(String(format: "sheet point %@ at (%.2f, %.2f): hue %.0f°, C/L %.3f, L %.3f", name, x, y, point.hue, point.sat, point.lum))
            for (label, change) in changes {
                var p = point; change(&p)
                var a = PhotoAdjustments(); a.mixer.points = [p]
                if let image = decoded(file, a) { save(image, "point-\(name)-\(label)") }
            }
            var a = PhotoAdjustments(); var p = point; p.saturation = -1; a.mixer.points = [p]
            let path = raws.appendingPathComponent(file).path
            var record = PhotoRecord(); record.adjust = a
            BaseCache.shared.removeAll(); GuideCache.shared.removeAll()
            if let d = PhotoRender.decoded(path, maxSize: 900, record: record) {
                save(PhotoRender.output(PhotoRender.adjusted(d, a, path: path, overlay: -2), a, p3: false), "point-\(name)-overlay")
            }
        }
        BaseCache.shared.removeAll(); GuideCache.shared.removeAll()
        // The Curves section on two kinds, and the Colour Mixer with points, as the inspector draws them (dark), folds open.
        let defaults = UserDefaults.standard
        let was = ["fold-curves", "fold-mixer"].map { ($0, defaults.object(forKey: $0)) }
        for (key, _) in was { defaults.set(true, forKey: key) }
        defer { for (key, value) in was { defaults.set(value, forKey: key) } }
        var curves = PhotoCurves()
        curves.hue = HueCurves(hueHue: r4Hue([(142.5, 0.8), (194.8, 0.35)]), hueSat: r4Hue([(29.2, 0.3), (264.1, 0.85)]),
                               lumSat: [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 0.45, y: 0.5), CurvePoint(x: 1, y: 0.5)])
        var mixer = ColorMixer()
        mixer.points = [ColourPoint(hue: 55, sat: 0.16, lum: 0.72, range: 40, hueShift: -15, saturation: 20),
                        ColourPoint(hue: 230, sat: 0.22, lum: 0.55, range: 60, luminance: -40), ColourPoint(hue: 140, sat: 0.12, lum: 0.5)]
        let shots: [(String, CGFloat, AnyView)] = [
            ("ui-curves-hue-sat", 380, AnyView(AdjustFold(title: "Curves", section: .curves, adjust: PhotoAdjustments(), open: true, reset: {}) {
                CurvesEditor(curves: curves, colour: true, start: .hueSat) { _ in } })),
            ("ui-curves-lum-sat", 380, AnyView(AdjustFold(title: "Curves", section: .curves, adjust: PhotoAdjustments(), open: true, reset: {}) {
                CurvesEditor(curves: curves, colour: true, start: .lumSat) { _ in } })),
            ("ui-point-colour", 250, AnyView(AdjustFold(title: "Colour Mixer", section: .mixer, adjust: PhotoAdjustments(), open: true, reset: {}) {
                ColorMixerEditor(mixer: mixer, points: true) { _ in } })),
        ]
        let editing = PhotoEditing.shared
        for (name, height, content) in shots {
            editing.mixerPoint = name == "ui-point-colour" ? 0 : nil
            let view = VStack(alignment: .leading, spacing: 16) { content }
                .panelColumn()
                .frame(width: 280, height: height, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
            let hosting = NSHostingView(rootView: view)
            hosting.frame = CGRect(x: 0, y: 0, width: 280, height: height)
            let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(400))
            hosting.layoutSubtreeIfNeeded()
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                if let cg = rep.cgImage { write(cg, name) }
            }
            window.close()
        }
        editing.mixerPoint = nil
    }
}
