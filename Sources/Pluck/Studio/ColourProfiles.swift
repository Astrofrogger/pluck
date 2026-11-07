import Foundation
import simd

/// Version 3's profile colour: each profile's hue and saturation table, as a DNG camera profile's HueSatMap (2.5D: by hue
/// and saturation, the same at any exposure), in HSV of linear ProPhoto. The engine reads it between its points
/// (PhotoEngine's hueSatMap) before the tone curve.
///
/// Each table is made from a smooth change of colour (by hue and colourfulness; lightness only through `dense`) worked out
/// at every point: so a table fitted to a photographed colour chart (a later "Calibrated" profile) goes in the same way, as its own
/// `table(_:)` of the fitted change.
enum ColourProfiles {
    /// The table's points: hues around the circle, saturations from grey (0) to the most (1).
    static let hues = 60, saturations = 12

    /// The table for a profile (nil: none). Accurate's only for RAW, whose colour Apple's decoder makes; Neutral's too (a
    /// finished picture's colour already has its density).
    /// `v4`: process 4's (Classic and the profiles made from it on Apple's own colour; Accurate and Neutral as version 3's).
    /// `v5`: process 5's (its Standard, `standard5`; the rest as process 4's).
    static func table(_ profile: PhotoEngine.Profile, isRaw: Bool, v4: Bool = false, v5: Bool = false) -> Data? {
        if (profile == .accurate || profile == .neutral) && !isRaw { return nil }
        if v5, profile == .standard { return standardTable5 }
        return (v4 ? tables4[profile] : nil) ?? tables[profile]
    }

    private static let standardTable5 = table(standard5).withUnsafeBufferPointer { Data(buffer: $0) }

    /// Process 5's Standard: natural colour, Apple's default decode as the anchor (its hue per band, its colourfulness), no
    /// density (Apple's has none: strong colours keep their light), no hue twist of its own. Chroma scale and hue turn by OkLCh
    /// hue every 15° (periodic Catmull-Rom, so the table is smooth), measured against Apple's default on five Sony RAWs per
    /// hue band; strong colours (C/L 0.25–0.5) get half the scale, as Classic's, since the tone curve already makes them more so.
    static let standard5Chroma: [Double] = [1.25, 1.22, 1.217, 1.173, 1.030, 1.034, 1.060, 1.074, 1.090, 1.111, 1.133, 1.149,
                                            1.170, 1.204, 1.250, 1.339, 1.380, 1.229, 1.070, 1.072, 1.130, 1.192, 1.22, 1.28]
    static let standard5Turn: [Double] = [8.9, 2.6, -5.0, -6.4, -2.0, 0.1, 1.0, 1.5, 1.6, 1.0, -0.1, -1.8,
                                          -2.7, -0.3, 2.6, 3.6, 3.5, 2.2, 0.6, -0.2, -0.3, 0.8, 2.8, 6.8]

    static func standard5(_ pro: SIMD3<Double>) -> SIMD3<Double> {
        okLCh(density: 0) { L, C, h in
            let k = periodic(standard5Chroma, h), strong = smoothstep(0.25, 0.5, C / max(L, 1e-6))
            return (C * (1 + (k - 1) * (1 - 0.5 * strong)), h + periodic(standard5Turn, h))
        }(pro)
    }

    private static let tables: [PhotoEngine.Profile: Data] = {
        var made: [PhotoEngine.Profile: Data] = [:]
        for profile in [PhotoEngine.Profile.accurate, .adobe, .vivid, .landscape, .portrait, .neutral] {
            made[profile] = table(change(profile)).withUnsafeBufferPointer { Data(buffer: $0) }
        }
        return made
    }()

    private static let tables4: [PhotoEngine.Profile: Data] = {
        var made: [PhotoEngine.Profile: Data] = [:]
        for profile in [PhotoEngine.Profile.adobe, .vivid, .landscape, .portrait] {
            made[profile] = table(change4(profile)).withUnsafeBufferPointer { Data(buffer: $0) }
        }
        return made
    }()

    /// Each point (hue, then saturation): the hue turn in degrees, the saturation and value scales. `change` maps linear
    /// ProPhoto to linear ProPhoto; grey (saturation 0) is always left alone.
    static func table(_ change: (SIMD3<Double>) -> SIMD3<Double>) -> [SIMD4<Float>] {
        var entries: [SIMD4<Float>] = []
        for i in 0..<hues {
            for j in 0..<saturations {
                let h = Double(i) * 6 / Double(hues), s = Double(j) / Double(saturations - 1)
                guard j > 0 else { entries.append(SIMD4(0, 1, 1, 0)); continue }
                let (h2, s2, v2) = hsv(change(rgb(h, s, 0.5)))
                var turn = h2 - h
                if turn > 3 { turn -= 6 } else if turn < -3 { turn += 6 }
                entries.append(SIMD4(Float(turn * 60), Float(s2 / s), Float(v2 / 0.5), 0))
            }
        }
        return entries
    }

    // MARK: - The profiles

    /// A profile's change of colour, on linear ProPhoto.
    static func change(_ profile: PhotoEngine.Profile) -> (SIMD3<Double>) -> SIMD3<Double> {
        switch profile {
        case .accurate:
            // Apple's decoder makes yellows and greens more colourful than the camera's colorimetric matrix (measured on a
            // Sony RAW against Adobe's matrix in a separate decoder: CIELAB chroma +7.5 in yellows, +7.9 in greens, 1.27× over those
            // 583 places; blues +1.0, hue within 2°). Accurate takes that back out, keeping hue and lightness.
            return lab { _, C, h in (C / (1 + appleBoost * plateau(h, 70, 150, taper: 25)), h) }
        case .adobe:
            return okLCh(density: 1, classic)
        case .neutral:
            // (Version 3 only: tables are read only there.) Colour as it is, with half Classic's density.
            return okLCh(density: 0.5) { _, C, h in (C, h) }
        case .vivid:
            // Classic's colour, then the quieter colours brought up most (as Vibrance), skin less; its stronger colour a little
            // less dense (it would go past the edge of ProPhoto).
            return okLCh(density: 0.8) { L, C, h in
                let (c, hue) = classic(L, C, h)
                let quiet = 1 - smoothstep(0, 0.35, c / max(L, 1e-6))
                return (c * (1 + (0.05 + 0.15 * quiet) * (1 - 0.7 * band(hue, 55, 18))), hue)
            }
        case .landscape:
            // Deeper greens (a little warmer) and blues, yellows a touch; as dense as Vivid.
            return okLCh(density: 0.8) { _, C, h in
                let green = band(h, 135, 25), blue = band(h, 250, 25), yellow = band(h, 100, 20)
                return (C * (1 + 0.12 * green + 0.12 * blue + 0.05 * yellow), h - 2 * green)
            }
        case .portrait:
            // Skin's hues drawn together (a quarter of the way to 55°), a little less colourful; reds calmer; half the density.
            return okLCh(density: 0.5) { _, C, h in
                let skin = band(h, 55, 18), red = band(h, 25, 10)
                return (C * (1 - 0.08 * skin) * (1 - 0.08 * red), h + (55 - h) * 0.25 * skin)
            }
        default:
            return { $0 }
        }
    }

    /// Process 4's profiles: Classic on Apple's own default colour (the owner's pick over Lightroom's, 2026-11-07), the others
    /// keeping their change on top of it (Vivid, Landscape, Portrait as version 3 has them on its Classic), with `dense4`.
    static func change4(_ profile: PhotoEngine.Profile) -> (SIMD3<Double>) -> SIMD3<Double> {
        switch profile {
        case .adobe:
            return okLCh(density: 1, dense: dense4, classic4)
        case .vivid:
            return okLCh(density: 0.8, dense: dense4) { L, C, h in
                let (c, hue) = classic4(L, C, h)
                let quiet = 1 - smoothstep(0, 0.35, c / max(L, 1e-6))
                return (c * (1 + (0.05 + 0.15 * quiet) * (1 - 0.7 * band(hue, 55, 18))), hue)
            }
        case .landscape:
            return okLCh(density: 0.8, dense: dense4) { L, C, h in
                let (c, hue) = classic4(L, C, h)
                let green = band(hue, 135, 25), blue = band(hue, 250, 25), yellow = band(hue, 100, 20)
                return (c * (1 + 0.12 * green + 0.12 * blue + 0.05 * yellow), hue - 2 * green)
            }
        case .portrait:
            return okLCh(density: 0.5, dense: dense4) { L, C, h in
                let (c, hue) = classic4(L, C, h)
                let skin = band(hue, 55, 18), red = band(hue, 25, 10)
                return (c * (1 - 0.08 * skin) * (1 - 0.08 * red), hue + (55 - hue) * 0.25 * skin)
            }
        default:
            return change(profile)
        }
    }

    /// Process 4's Classic: chroma scale and hue turn (degrees) by OkLCh hue, every 30° from 0°, read between with a
    /// periodic Catmull-Rom. Measured on five Sony RAWs against Apple's default decode (CIRAWFilter, all defaults: decoder 8,
    /// boost 1), pixel by pixel on the same grid: Apple's chroma over version 3's Classic by hue, times Classic's own (blues
    /// 10% under that, purples and reds 4%: the sea-and-sky RAW's sky came out a third over Apple's, the stage light 7%).
    static let classic4Chroma: [Double] = [1.18, 1.129, 1.06, 1.05, 1.061, 1.133, 1.17, 1.21, 1.25, 1.07, 1.13, 1.15]
    static let classic4Turn: [Double] = [8.9, 2.4, 0.1, -1.0, 0.6, -0.1, -2.7, 2.6, 5.4, 0.9, 0.6, 1.8]

    static func classic4(_ L: Double, _ C: Double, _ h: Double) -> (Double, Double) {
        // (Half as much over C/L 0.25–0.5: the tone curve already makes strong colour more so; there Apple's was 8% under.)
        let k = periodic(classic4Chroma, h), strong = smoothstep(0.25, 0.5, C / max(L, 1e-6))
        return (C * (1 + (k - 1) * (1 - 0.5 * strong)), h + periodic(classic4Turn, h))
    }

    /// Values every 360/n degrees from 0°, read at `h` (degrees) with a periodic Catmull-Rom.
    static func periodic(_ v: [Double], _ h: Double) -> Double {
        let n = v.count, x = ((h / 360 * Double(n)).truncatingRemainder(dividingBy: Double(n)) + Double(n)).truncatingRemainder(dividingBy: Double(n))
        let i = Int(x), t = x - Double(i)
        let p0 = v[(i + n - 1) % n], p1 = v[i % n], p2 = v[(i + 1) % n], p3 = v[(i + 2) % n]
        return 0.5 * (2 * p1 + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t + (3 * (p1 - p2) + p3 - p0) * t * t * t)
    }

    /// Process 4's density: half Classic's, fading out from C/L 0.25 to 0.45, so light sources and strong colours keep
    /// their light (Apple's default has none: against version 3's Classic its strong colours sat 6–11 OkLab L ×100 lighter).
    static func dense4(_ L: Double, _ C: Double, _ h: Double) -> Double {
        1 - 0.5 * (1 - dense(L, C, h)) * (1 - smoothstep(0.25, 0.45, C / max(L, 1e-6)))
    }

    /// Apple's extra yellow-green colour, as a share (see Accurate).
    static let appleBoost = 0.25

    /// Classic (Lightroom's Adobe Color-like), in OkLCh: greens calmer and a little warmer (Lightroom's lawn on a RAW:
    /// OkLab a −4.6 against −5.6 before), oranges and reds a touch richer.
    static func classic(_ L: Double, _ C: Double, _ h: Double) -> (Double, Double) {
        let green = band(h, 135, 25), warm = band(h, 45, 15)
        return (C * (1 - 0.14 * green) * (1 + 0.05 * warm), h - 3 * green + 1.5 * warm)
    }

    // MARK: - Colour

    /// A Gaussian band of hues (degrees), 1 at its centre.
    static func band(_ h: Double, _ centre: Double, _ width: Double) -> Double {
        var d = abs(h - centre).truncatingRemainder(dividingBy: 360)
        if d > 180 { d = 360 - d }
        return exp(-d * d / (2 * width * width))
    }

    /// 1 between `low` and `high` (degrees), easing to 0 over `taper` either side.
    static func plateau(_ h: Double, _ low: Double, _ high: Double, taper: Double) -> Double {
        let d = h < low ? low - h : h > high ? h - high : 0
        return d < taper ? 0.5 + 0.5 * cos(.pi * d / taper) : 0
    }

    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Density, as Lightroom's profiles have it (a film's dyes): colourful colours sit darker than a grey of the same light, at
    /// the same chroma, so they look deep rather than loud. Measured on a RAW against Accurate (whose lightness is a grey's):
    /// Lightroom's Adobe Color puts OkLab L 0.075 lower at chroma 0.14 than at grey, 0.03 lower at 0.09, nothing under 0.05,
    /// oranges and yellows most, greens less. By colourfulness (C/L, the same at any exposure; none up to skin's) and hue,
    /// the lightness scale; at most 20% darker.
    static func dense(_ L: Double, _ C: Double, _ h: Double) -> Double {
        let x = max(C / max(L, 1e-6) - 0.07, 0), q = 9 * x * x * (0.75 + 0.45 * plateau(h, 30, 110, taper: 30))
        return 1 - 0.2 * tanh(q / 0.2)
    }

    /// A change in OkLCh (lightness kept, but for `density`: a share of `dense`), on linear ProPhoto.
    static func okLCh(density: Double = 0, dense: @escaping (Double, Double, Double) -> Double = ColourProfiles.dense,
                      _ f: @escaping (_ L: Double, _ C: Double, _ h: Double) -> (Double, Double)) -> (SIMD3<Double>) -> SIMD3<Double> {
        { pro in
            let s = mul(PhotoEngine.fromProPhoto, pro)
            let (L, a, b) = OkLab.from(s.x, s.y, s.z)
            let (C, h) = ((a * a + b * b).squareRoot(), atan2(b, a) * 180 / .pi)
            let (C2, h2) = f(L, C, h < 0 ? h + 360 : h)
            let L2 = L * (1 - density * (1 - dense(L, C2, h2)))
            let (r, g, bl) = OkLab.to(L2, C2 * cos(h2 * .pi / 180), C2 * sin(h2 * .pi / 180))
            return mul(PhotoEngine.toProPhoto, SIMD3(r, g, bl))
        }
    }

    /// A change in CIELAB (D50, lightness kept), on linear ProPhoto.
    static func lab(_ f: @escaping (_ L: Double, _ C: Double, _ h: Double) -> (Double, Double)) -> (SIMD3<Double>) -> SIMD3<Double> {
        { pro in
            let (L, a, b) = toLab(pro)
            let (C, h) = ((a * a + b * b).squareRoot(), atan2(b, a) * 180 / .pi)
            let (C2, h2) = f(L, C, h < 0 ? h + 360 : h)
            return fromLab(L, C2 * cos(h2 * .pi / 180), C2 * sin(h2 * .pi / 180))
        }
    }

    /// Linear ProPhoto (ROMM, D50) to XYZ, row by row.
    static let proToXYZ = [0.7976749, 0.1351917, 0.0313534, 0.2880402, 0.7118741, 0.0000857, 0, 0, 0.8252100]
    static let xyzToPro = PhotoEngine.inverse(proToXYZ)
    private static let d50 = SIMD3(0.9642, 1.0, 0.8251)

    static func toLab(_ pro: SIMD3<Double>) -> (Double, Double, Double) {
        let t = mul(proToXYZ, pro) / d50
        func f(_ v: Double) -> Double { v > 216.0 / 24389 ? cbrt(v) : v * 24389 / 27 / 116 + 16.0 / 116 }
        let (fx, fy, fz) = (f(t.x), f(t.y), f(t.z))
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    static func fromLab(_ L: Double, _ a: Double, _ b: Double) -> SIMD3<Double> {
        let fy = (L + 16) / 116, fx = fy + a / 500, fz = fy - b / 200
        func g(_ v: Double) -> Double { v > 6.0 / 29 ? v * v * v : 3 * 36.0 / 841 * (v - 4.0 / 29) }
        return mul(xyzToPro, SIMD3(g(fx), g(fy), g(fz)) * d50)
    }

    static func mul(_ m: [Double], _ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(m[0] * v.x + m[1] * v.y + m[2] * v.z, m[3] * v.x + m[4] * v.y + m[5] * v.z, m[6] * v.x + m[7] * v.y + m[8] * v.z)
    }

    /// HSV as the DNG SDK has it: hue 0…6.
    static func hsv(_ c: SIMD3<Double>) -> (Double, Double, Double) {
        let mx = c.max(), mn = c.min(), d = mx - mn
        guard mx > 0, d > 0 else { return (0, 0, max(mx, 0)) }
        var h = c.x == mx ? (c.y - c.z) / d : c.y == mx ? 2 + (c.z - c.x) / d : 4 + (c.x - c.y) / d
        if h < 0 { h += 6 }
        return (h, d / mx, mx)
    }

    static func rgb(_ h: Double, _ s: Double, _ v: Double) -> SIMD3<Double> {
        let h = (h.truncatingRemainder(dividingBy: 6) + 6).truncatingRemainder(dividingBy: 6)
        let i = Int(h), f = h - Double(i), p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: return SIMD3(v, t, p)
        case 1: return SIMD3(q, v, p)
        case 2: return SIMD3(p, v, t)
        case 3: return SIMD3(p, q, v)
        case 4: return SIMD3(t, p, v)
        default: return SIMD3(v, p, q)
        }
    }
}
