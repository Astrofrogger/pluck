import AppKit
import CoreImage
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Process 5's grading: the colour wheels in a log space (Midtones held at both ends, a warm push warm everywhere, Shadows
/// able to tint black, the brightness kept), Lift/Gamma/Gain/Offset, and the colour mixer on the picture as shown (the same
/// strength at any exposure, Luminance about a stop, bands that end at their neighbours). Each check measures process 4
/// (kept as it was) as the before.
extension PhotoSelfTest {
    private static func r2Y(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
    /// The grading space as the engine has it (a RAW's: white 14.2).
    private static func r2U(_ c: Double) -> Double { c > 0 ? log2(1 + c / 0.0075) / 10.88745 : c / (0.0075 * log(2) * 10.88745) }

    /// A grey ramp, 98 × 4: x = 0 pure black, then mid grey −8 … +4 stops in eighths (x = 1 + 8·(stops + 8)).
    private static func r2Ramp() -> CIImage {
        fsImage(98, 4) { x, _ in x == 0 ? SIMD3(repeating: 0) : SIMD3(repeating: Float(0.18 * exp2(Double(x - 1) / 8 - 8))) }
    }
    private static func r2At(_ stops: Double) -> Int { 1 + Int((stops + 8) * 8) }
    private static func r2Row(_ image: CIImage, _ a: PhotoAdjustments, scene: Bool = true) -> [SIMD3<Double>] {
        let px = fsDeveloped(image, a, scene: scene), w = Int(image.extent.width)
        return Array(px[(2 * w)..<(3 * w)])
    }
    /// The ramp's brightness through Accurate (its curve takes each pixel's brightness alone, whatever its colour), before
    /// the screen's gamut map: a push that keeps the light keeps this.
    private static func r2Light(_ image: CIImage, _ a: PhotoAdjustments) -> [Double] {
        var a = a; a.profile = .accurate
        let w = Int(image.extent.width)
        return Array(fsPixels(PhotoRender.adjusted(image, a, isRaw: true, kelvin: 5500), image.extent)[(2 * w)..<(3 * w)]).map(r2Y)
    }
    /// A wheel's push towards a hue (degrees, 0 red, 120 green, 240 blue), as the wheel's dot.
    private static func r2Push(_ hue: Double, _ reach: Double, master: Double = 0) -> ColorWheels.Wheel {
        .init(x: reach * cos(hue * .pi / 180), y: reach * sin(hue * .pi / 180), master: master)
    }

    static func revamp2() async {
        wheelsChecks()
        primariesChecks()
        mixerChecks()
        await revamp2Dump()
    }

    // MARK: T6 Colour Grading wheels

    private static func wheelsChecks() {
        let ramp = r2Ramp()
        func graded(_ process: Int, _ change: (inout ColorWheels) -> Void) -> (plain: [SIMD3<Double>], graded: [SIMD3<Double>]) {
            var a = PhotoAdjustments(); a.process = process
            let plain = r2Row(ramp, a)
            change(&a.wheels)
            return (plain, r2Row(ramp, a))
        }
        func stopsMoved(_ r: (plain: [SIMD3<Double>], graded: [SIMD3<Double>]), _ x: Int) -> Double {
            log2(max(r2Y(r.graded[x]), 1e-9) / max(r2Y(r.plain[x]), 1e-9))
        }
        // Midtones +0.25: highlights 3 stops over grey hardly move, black stays black, mid grey moves.
        var mids: [Int: (high: Double, black: Double, grey: Double)] = [:]
        for process in [4, 5] {
            let r = graded(process) { $0.gamma.master = 0.25 }
            mids[process] = (stopsMoved(r, r2At(3)), r2Y(r.graded[0]), stopsMoved(r, r2At(0)))
        }
        note(String(format: "wheels Midtones +0.25: 3 stops over grey moves %+.3f stop (p4 %+.3f), mid grey %+.3f (p4 %+.3f), black %.6f (p4 %.6f)",
                    mids[5]!.high, mids[4]!.high, mids[5]!.grey, mids[4]!.grey, mids[5]!.black, mids[4]!.black))
        check("wheels midtones keep the highlights", abs(mids[5]!.high) < 0.05 && mids[5]!.black < 1e-6 && mids[5]!.grey > 0.15,
              String(format: "3 stops over grey %+.3f stop (under 0.05), black %.6f (0), grey %+.3f (over 0.15); p4 %+.3f", mids[5]!.high, mids[5]!.black, mids[5]!.grey, mids[4]!.high))

        // A warm Midtones push: warmer (red over blue) at every level it reaches, never cooler.
        var coolest: [Int: Double] = [:], warmest: [Int: Double] = [:]
        for process in [4, 5] {
            let r = graded(process) { $0.gamma = r2Push(30, 0.3) }
            let warmth = stride(from: -4.0, through: 3.5, by: 0.5).map { s -> Double in
                let x = r2At(s), g = r.graded[x], p = r.plain[x]
                return log2(max(g.x, 1e-9) / max(g.z, 1e-9)) - log2(max(p.x, 1e-9) / max(p.z, 1e-9))
            }
            coolest[process] = warmth.min()!; warmest[process] = warmth.max()!
        }
        note(String(format: "wheels warm Midtones −4…+3.5 stops, red/blue change: p5 %+.3f…%+.3f, p4 %+.3f…%+.3f", coolest[5]!, warmest[5]!, coolest[4]!, warmest[4]!))
        check("wheels warm push is warm everywhere", coolest[5]! > -0.005 && warmest[5]! > 0.1,
              String(format: "least %+.3f (not under −0.005), most %+.3f (over 0.1); p4 %+.3f", coolest[5]!, warmest[5]!, coolest[4]!))

        // Shadows towards blue tints pure black (on screen).
        var black: [Int: SIMD3<Double>] = [:]
        for process in [4, 5] {
            var a = PhotoAdjustments(); a.process = process; a.wheels.lift = r2Push(240, 0.3)
            black[process] = r2Row(ramp, a, scene: false)[0]
        }
        note("wheels Shadows blue, pure black on screen: p5 \(black[5]!), p4 \(black[4]!)")
        // (The tone curve's toe keeps black's light very low: 0.0006 is about 3 of 255 in sRGB.)
        check("wheels shadows tint black", black[5]!.z > black[5]!.x + 0.0006, "blue over red by more than 0.0006; got \(black[5]!), p4 \(black[4]!)")

        // Any push leaves the grey ramp's brightness (−4 … +3.5 stops) within 0.03 stop. (Deeper, a tinted black needs a
        // little light.) Read twice, each with its own known side effect, and the smaller change taken: in scene light (for
        // the film, squeezed into sRGB, which lights strongly tinted shadows) and through Accurate (whose fade to white takes
        // some light from a strong tint near white).
        let sceneLight = { (a: PhotoAdjustments) in r2Row(ramp, a).map(r2Y) }
        var worst: [Int: (Double, String)] = [4: (0, ""), 5: (0, "")]
        let wheels: [(String, WritableKeyPath<ColorWheels, ColorWheels.Wheel>)] = [("Shadows", \.lift), ("Midtones", \.gamma), ("Highlights", \.gain), ("Global", \.offset)]
        for process in [4, 5] {
            for (name, path) in wheels {
                for hue in stride(from: 0.0, to: 360, by: 60) {
                    var a = PhotoAdjustments(); a.process = process
                    let plain = r2Light(ramp, a), plainScene = sceneLight(a)
                    a.wheels[keyPath: path] = r2Push(hue, 0.4)
                    let pushed = r2Light(ramp, a), pushedScene = sceneLight(a)
                    for s in stride(from: -4.0, through: 3.5, by: 0.5) {
                        let x = r2At(s)
                        let moved = min(abs(log2(max(pushed[x], 1e-9) / max(plain[x], 1e-9))), abs(log2(max(pushedScene[x], 1e-9) / max(plainScene[x], 1e-9))))
                        if moved > worst[process]!.0 { worst[process] = (moved, "\(name) \(Int(hue))° at \(s) stops") }
                    }
                }
            }
        }
        note(String(format: "wheels push brightness, worst on the grey ramp: p5 %.3f stop (%@), p4 %.3f stop (%@)", worst[5]!.0, worst[5]!.1, worst[4]!.0, worst[4]!.1))
        check("wheels push keeps the brightness", worst[5]!.0 < 0.03, String(format: "worst %.3f stop at %@ (under 0.03); p4 %.3f", worst[5]!.0, worst[5]!.1, worst[4]!.0))

        // A Lightroom teal-and-orange grade on process 5: shadows teal, highlights warm, mid grey nearly neutral, brightness kept.
        let (preset, _) = LightroomPresets.adjustments(["ColorGradeShadowHue": "200", "ColorGradeShadowSat": "40", "ColorGradeHighlightHue": "40",
                                                        "ColorGradeHighlightSat": "40", "ColorGradeBlending": "50"])
        var a = PhotoAdjustments(); a.wheels = preset.wheels
        let plain = r2Row(ramp, PhotoAdjustments()), lr = r2Row(ramp, a)
        func warm(_ x: Int) -> Double { log2(max(lr[x].x, 1e-9) / max(lr[x].z, 1e-9)) - log2(max(plain[x].x, 1e-9) / max(plain[x].z, 1e-9)) }
        let low = warm(r2At(-3.5)), high = warm(r2At(2.5)), grey = warm(r2At(0))
        let lightPlain = r2Light(ramp, PhotoAdjustments()), lightLR = r2Light(ramp, a)
        let moved = stride(from: -4.0, through: 3.5, by: 0.5).map { abs(log2(max(lightLR[r2At($0)], 1e-9) / max(lightPlain[r2At($0)], 1e-9))) }.max()!
        note(String(format: "Lightroom teal/orange preset on p5: red/blue at −3.5 stops %+.3f, grey %+.3f, +2.5 stops %+.3f; brightness moves at most %.3f stop", low, grey, high, moved))
        check("lightroom colour grading on the new wheels", low < -0.08 && high > 0.08 && abs(grey) < max(abs(low), abs(high)) * 0.5 && moved < 0.03,
              String(format: "shadows cooler (%+.3f), highlights warmer (%+.3f), grey in between (%+.3f), brightness %.3f stop", low, high, grey, moved))
    }

    // MARK: T10 Lift / Gamma / Gain / Offset

    private static func primariesChecks() {
        let ramp = r2Ramp()
        func run(_ process: Int = 5, _ change: (inout ColorWheels.Primaries) -> Void) -> (plain: [Double], graded: [Double]) {
            var a = PhotoAdjustments(); a.process = process
            let plain = r2Row(ramp, a).map { r2U(r2Y($0)) }
            change(&a.wheels.primaries)
            return (plain, r2Row(ramp, a).map { r2U(r2Y($0)) })
        }
        // The ramp's white: the tone curve's (14.2) is 5.98 stops over grey.
        let black = 0, grey = r2At(0), white = r2At(4) - 2
        let whiteU = run { _ in }.plain[white]
        func report(_ r: (plain: [Double], graded: [Double])) -> String {
            String(format: "u black %.4f→%.4f, grey %.4f→%.4f, top %.4f→%.4f", r.plain[black], r.graded[black], r.plain[grey], r.graded[grey], r.plain[white], r.graded[white])
        }
        // Gain (master): black held, the rest × G in the grading space.
        let gain = run { $0.gain.master = 0.3 }, G = exp2(0.3 * 0.5)
        let gainOK = abs(gain.graded[black]) < 1e-4 && abs(gain.graded[grey] / gain.plain[grey] - G) < 0.01 && abs(gain.graded[white] / gain.plain[white] - G) < 0.01
        note("primaries Gain +0.3: " + report(gain) + String(format: " (×%.3f)", G))
        let gain4 = run(4) { $0.gain.master = 0.3 }
        check("primaries gain holds black, scales white", gainOK, report(gain) + String(format: "; ×%.3f wanted; p4 grey unchanged %.4f→%.4f", G, gain4.plain[grey], gain4.graded[grey]))
        // Gamma: black and white (u = 1) held, grey moves.
        let gamma = run { $0.gamma.master = 0.3 }
        let P = exp2(-0.3 * 0.8), atOne = pow(1.0, P), greyWanted = pow(gamma.plain[grey], P)
        check("primaries gamma holds the ends, moves the middle", abs(gamma.graded[black]) < 1e-4 && abs(gamma.graded[grey] - greyWanted) < 0.005 && atOne == 1
              && (gamma.graded[grey] - gamma.plain[grey]) * 10.887 > 0.4, report(gamma) + String(format: "; grey wanted %.4f", greyWanted))
        // Lift: black moves, white (u = 1) held: what's under it moves less the brighter it is.
        let lift = run { $0.lift.master = 0.3 }
        let liftWanted = { (u: Double) in u + 0.06 * (1 - min(u, 1)) }
        check("primaries lift moves black, holds white", abs(lift.graded[black] - 0.06) < 0.002 && abs(lift.graded[white] - liftWanted(lift.plain[white])) < 0.003
              && lift.graded[white] - lift.plain[white] < 0.5 * (lift.graded[black] - lift.plain[black]), report(lift) + String(format: "; white of the curve at u %.3f", whiteU))
        // Offset: every stop over a deep shadow moves the same.
        let offset = run { $0.offset.master = 0.2 }
        let shifts = [-2.0, 0, 2].map { s -> Double in let x = r2At(s); return (offset.graded[x] - offset.plain[x]) * 10.88745 }
        check("primaries offset moves every stop evenly", shifts.allSatisfy { abs($0 - 0.03 * 10.88745) < 0.03 }, "log stops moved at −2, 0, +2: \(shifts) (each \(0.03 * 10.88745))")
        // A colour push keeps the brightness: Lift towards blue tints black blue, grey ramp's brightness within 0.03 stop.
        var a = PhotoAdjustments(); a.wheels.primaries.lift = r2Push(240, 0.3)
        let blue = r2Row(ramp, a, scene: false)[0]
        var plain = PhotoAdjustments()
        let base = r2Light(ramp, plain), pushed = r2Light(ramp, a)
        plain.wheels.primaries.gain = r2Push(40, 0.4)
        let warmGain = r2Light(ramp, plain)
        let worst = stride(from: -4.0, through: 3.5, by: 0.5).map { s -> Double in
            let x = r2At(s)
            return max(abs(log2(max(pushed[x], 1e-9) / max(base[x], 1e-9))), abs(log2(max(warmGain[x], 1e-9) / max(base[x], 1e-9))))
        }.max()!
        check("primaries colour keeps the brightness", blue.z > blue.x + 0.0006 && worst < 0.03,
              String(format: "lift blue: black %@; worst brightness change %.3f stop (under 0.03)", "\(blue)", worst))
    }

    // MARK: T7 Colour mixer

    private static func mixerChecks() {
        // The same red (a red patch; its picture without the mixer as the reference) at −2, 0 and +2 EV: the mixer's
        // Saturation and Luminance do the same at each.
        let red = fsImage(16, 16) { _, _ in SIMD3(0.40, 0.035, 0.03) }
        func shown(_ a: PhotoAdjustments) -> SIMD3<Double> {
            // (The picture before the screen's gamut map: what the mixer itself does.)
            let out = PhotoRender.adjusted(red, a, isRaw: true, kelvin: 5500)
            return fsPixels(out, red.extent)[8 * 16 + 8]
        }
        var rows: [String] = [], spread: [Int: (sat: Double, lum: Double)] = [:], lum0: [Int: Double] = [:]
        for process in [4, 5] {
            var sats: [Double] = [], lums: [Double] = []
            for ev in [-2.0, 0, 2] {
                var a = PhotoAdjustments(); a.process = process; a.exposure = ev
                let before = fsLab(shown(a))
                var s = a; s.mixer.saturation[0] = -60
                var l = a; l.mixer.luminance[0] = -100
                let sat = fsLab(shown(s)), dark = shown(l)
                let cl = { (o: SIMD3<Double>) in fsChroma(o) / max(o.x, 1e-6) }
                sats.append(cl(sat) / cl(before))
                lums.append(log2(max(r2Y(dark), 1e-9) / max(r2Y(shown(a)), 1e-9)))
            }
            rows.append(String(format: "p%d: C/L × %.2f %.2f %.2f, luminance −100 %+.2f %+.2f %+.2f stops", process, sats[0], sats[1], sats[2], lums[0], lums[1], lums[2]))
            spread[process] = (sats.max()! - sats.min()!, lums.max()! - lums.min()!)
            lum0[process] = lums[1]
        }
        note("mixer on the same red at −2/0/+2 EV: " + rows.joined(separator: "; "))
        check("mixer same strength at any exposure", spread[5]!.sat < 0.08 && spread[5]!.lum < 0.15,
              String(format: "C/L ratio spread %.3f (under 0.08), luminance spread %.3f stop (under 0.15); ", spread[5]!.sat, spread[5]!.lum) + rows.joined(separator: "; "))

        // Blue −100 luminance: about a stop darker, its colour (C/L) kept, inside ProPhoto (no negative light).
        let blue = fsImage(16, 16) { _, _ in SIMD3(0.04, 0.09, 0.55) }
        var blueRows: [String] = [], p5: (stops: Double, keep: Double, low: Double) = (0, 0, 0)
        for process in [4, 5] {
            var a = PhotoAdjustments(); a.process = process
            let before = fsPixels(PhotoRender.adjusted(blue, a, isRaw: true, kelvin: 5500), blue.extent)[136]
            a.mixer.luminance[5] = -100
            let after = fsPixels(PhotoRender.adjusted(blue, a, isRaw: true, kelvin: 5500), blue.extent)[136]
            let o0 = fsLab(before), o1 = fsLab(after)
            let stops = log2(max(r2Y(after), 1e-9) / max(r2Y(before), 1e-9)), keep = (fsChroma(o1) / o1.x) / (fsChroma(o0) / o0.x)
            let m = PhotoEngine.toProPhoto
            let pro = SIMD3(m[0] * after.x + m[1] * after.y + m[2] * after.z, m[3] * after.x + m[4] * after.y + m[5] * after.z,
                            m[6] * after.x + m[7] * after.y + m[8] * after.z)
            blueRows.append(String(format: "p%d: %+.2f stops, C/L × %.2f, lowest ProPhoto channel %.4f", process, stops, keep, min(pro.x, pro.y, pro.z)))
            if process == 5 { p5 = (stops, keep, min(pro.x, pro.y, pro.z)) }
        }
        note("mixer Blue luminance −100: " + blueRows.joined(separator: "; "))
        check("mixer luminance about a stop, colour kept", p5.stops < -0.75 && p5.stops > -1.25 && abs(p5.keep - 1) < 0.08 && p5.low > -1e-4,
              blueRows.joined(separator: "; "))

        // The bands: Red's Hue +100 turns red (25°) by 30°, orange (60°) and magenta (345°) not at all, and smoothly between.
        let n = 360
        let ring = fsImage(n, 4) { x, _ in
            let h = Double(x) * .pi / 180, (r, g, b) = OkLab.to(0.6, 0.06 * cos(h), 0.06 * sin(h))
            return SIMD3(Float(r), Float(g), Float(b))
        }
        var bandRows: [String] = [], turns: [Int: [Double]] = [:]
        for process in [4, 5] {
            var a = PhotoAdjustments(); a.process = process; a.profile = .asShot
            let base = fsPixels(PhotoRender.adjusted(ring, a, isRaw: false, kelvin: 5500), ring.extent)
            a.mixer.hue[0] = 100
            let moved = fsPixels(PhotoRender.adjusted(ring, a, isRaw: false, kelvin: 5500), ring.extent)
            let t = (0..<n).map { x -> Double in
                let d = fsHue(fsLab(moved[2 * n + x])) - fsHue(fsLab(base[2 * n + x]))
                return d > 180 ? d - 360 : d < -180 ? d + 360 : d
            }
            turns[process] = t
            let step = (1..<n).map { abs(t[$0] - t[$0 - 1]) }.max()!
            bandRows.append(String(format: "p%d: at 25° %+.1f°, 60° %+.1f°, 345° %+.1f°, 105° %+.1f°, largest step %.2f°", process, t[25], t[60], t[345], t[105], step))
        }
        note("mixer Red hue +100 around the hue circle: " + bandRows.joined(separator: "; "))
        let t5 = turns[5]!, step5 = (1..<n).map { abs(t5[$0] - t5[$0 - 1]) }.max()!
        check("mixer bands end at their neighbours", abs(t5[25] - 30) < 3 && abs(t5[60]) < 1 && abs(t5[345]) < 1 && abs(t5[105]) < 0.5 && step5 < 2.5,
              bandRows.joined(separator: "; "))
        // (The on-photo target spreads a drag by the same bands.)
        let w = ColorMixer.weights5(42.5)
        check("mixer target uses process 5's bands", abs(w[0] - 0.5) < 1e-6 && abs(w[1] - 0.5) < 1e-6 && ColorMixer.weights5(25)[0] == 1 && ColorMixer.weights5(350)[7] > 0.9,
              "\(w)")
    }

    // MARK: The sheet's renders

    /// Into <photos>/../revamp2/dump when that folder exists: 8-bit sRGB PNGs for the before/after sheet, and the
    /// Colour Wheels section drawn as the inspector draws it.
    private static func revamp2Dump() async {
        let base = URL(fileURLWithPath: photos).deletingLastPathComponent()
        let out = base.appendingPathComponent("revamp2/dump"), raws = base.appendingPathComponent("shootout/raws")
        guard FileManager.default.fileExists(atPath: out.path) else { return }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        func save(_ image: CIImage, _ name: String) {
            let e = image.extent.integral
            let placed = image.cropped(to: e).transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            guard let cg = PhotoEngine.context.createCGImage(placed, from: placed.extent, format: .RGBA8, colorSpace: srgb) else { return }
            write(cg, name)
        }
        func write(_ cg: CGImage, _ name: String) {
            guard let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, cg, nil); CGImageDestinationFinalize(dest)
        }
        func render(_ path: String, _ change: (inout PhotoAdjustments) -> Void) -> CIImage? {
            var record = PhotoRecord(); change(&record.adjust)
            BaseCache.shared.removeAll(); GuideCache.shared.removeAll()
            return PhotoRender.decoded(path, maxSize: 900, record: record).map { PhotoRender.output(PhotoRender.adjusted($0, record.adjust, path: path), record.adjust, p3: false) }
        }
        // The grey ramp, wide: −8 … +4 stops over 480 px.
        let ramp = fsImage(480, 40) { x, _ in SIMD3(repeating: Float(0.18 * exp2(Double(x) / 40 - 8))) }
        let wheelCases: [(String, (inout ColorWheels) -> Void)] = [
            ("plain", { _ in }),
            ("shadows-blue", { $0.lift = r2Push(240, 0.3) }),
            ("midtones-warm", { $0.gamma = r2Push(30, 0.3) }),
            ("highlights-warm", { $0.gain = r2Push(40, 0.3) }),
            ("midtones-lum", { $0.gamma.master = 0.25 }),
            ("teal-orange", { $0.lift = r2Push(200, 0.25); $0.gain = r2Push(40, 0.25) }),
        ]
        let primaryCases: [(String, (inout ColorWheels.Primaries) -> Void)] = [
            ("lift-up", { $0.lift.master = 0.3 }), ("gamma-up", { $0.gamma.master = 0.3 }), ("gain-up", { $0.gain.master = 0.3 }),
            ("offset-down", { $0.offset.master = -0.2 }), ("lift-blue-gain-warm", { $0.lift = r2Push(220, 0.25); $0.gain = r2Push(40, 0.25) }),
        ]
        for (name, change) in wheelCases {
            for process in [4, 5] where process == 5 || name != "plain" {
                var a = PhotoAdjustments(); a.process = process; change(&a.wheels)
                save(PhotoRender.output(PhotoRender.adjusted(ramp, a, isRaw: true, kelvin: 5500), a, p3: false), "ramp-p\(process)-\(name)")
            }
        }
        for (name, change) in primaryCases {
            var a = PhotoAdjustments(); change(&a.wheels.primaries)
            save(PhotoRender.output(PhotoRender.adjusted(ramp, a, isRaw: true, kelvin: 5500), a, p3: false), "ramp-p5-\(name)")
        }
        let photo = raws.appendingPathComponent("DSC02845.ARW").path
        if FileManager.default.fileExists(atPath: photo) {
            for (name, change) in wheelCases where name != "midtones-lum" {
                for process in [4, 5] where process == 5 || name != "plain" {
                    if let image = render(photo, { $0.process = process; $0.profile = .adobe; change(&$0.wheels) }) { save(image, "photo-p\(process)-\(name)") }
                }
            }
            for (name, change) in primaryCases {
                if let image = render(photo, { $0.profile = .adobe; change(&$0.wheels.primaries) }) { save(image, "photo-p5-\(name)") }
            }
        }
        // The same red at −2, 0 and +2 EV: as it is, and the mixer's Red Saturation −60 / Luminance −60 on 4 and 5.
        let red = fsImage(120, 80) { x, y in
            let shade = 0.75 + 0.25 * Float(x) / 120
            return SIMD3<Float>(0.40, 0.035, 0.03) * shade * (y < 40 ? 1 : 0.6)
        }
        for ev in [-2.0, 0, 2] {
            for (name, process, mixed) in [("plain", 5, false), ("p4", 4, true), ("p5", 5, true)] {
                var a = PhotoAdjustments(); a.process = process; a.exposure = ev; a.profile = .adobe
                if mixed { a.mixer.saturation[0] = -60; a.mixer.luminance[0] = -60 }
                save(PhotoRender.output(PhotoRender.adjusted(red, a, isRaw: true, kelvin: 5500), a, p3: false), "red-ev\(Int(ev))-\(name)")
            }
        }
        BaseCache.shared.removeAll(); GuideCache.shared.removeAll()
        // The Colour Wheels section as the inspector draws it, on both pages (dark, as the app is), its fold open (put back).
        let defaults = UserDefaults.standard, wasOpen = defaults.object(forKey: "fold-wheels")
        defaults.set(true, forKey: "fold-wheels")
        defer { defaults.set(wasOpen, forKey: "fold-wheels") }
        var wheels = ColorWheels()
        wheels.lift = r2Push(200, 0.2); wheels.gain = r2Push(40, 0.25, master: 0.1); wheels.blending = 60
        wheels.primaries.lift = r2Push(220, 0.15, master: 0.1); wheels.primaries.gain = r2Push(40, 0.2)
        for primaries in [false, true] {
            let path = "revamp2-shot-\(primaries)"
            PhotoEditing.shared.wheelsPrimaries[path] = primaries
            let view = VStack(alignment: .leading, spacing: 16) {
                AdjustFold(title: "Colour Wheels", section: .wheels, adjust: PhotoAdjustments(), open: true, reset: {}) {
                    ColorWheelsEditor(wheels: wheels, path: path) { _ in }
                }
            }
            .panelColumn()
            .frame(width: 280, height: primaries ? 330 : 400, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
            let hosting = NSHostingView(rootView: view)
            hosting.frame = CGRect(x: 0, y: 0, width: 280, height: primaries ? 330 : 400)
            let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(400))
            hosting.layoutSubtreeIfNeeded()
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                if let cg = rep.cgImage { write(cg, "ui-\(primaries ? "primaries" : "wheels")") }
            }
            window.close()
            PhotoEditing.shared.wheelsPrimaries[path] = nil
        }
    }
}
