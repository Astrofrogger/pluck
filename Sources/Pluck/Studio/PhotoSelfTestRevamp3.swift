import AppKit
import CoreImage
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Process 5's detail tools: the wheels' colour at Lightroom's strength, Clarity against an edge-following base in log light
/// (no dark halo beside something bright, no mist), Glow in Effects (bright parts spread light, laid on by a blend mode),
/// Texture that leaves the photo's noise alone, and Sharpen's Masking. Each check measures process 4 too, as the before.
extension PhotoSelfTest {
    private static func r3Y(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
    private static func r3Enc(_ v: Double) -> Double { pow(max(v, 0), 1 / 2.2) }
    /// The same Gaussian numbers every run.
    private static func r3Noise(_ count: Int, seed: UInt64) -> [Double] {
        var state = seed
        func next() -> Double { state = state &* 6364136223846793005 &+ 1442695040888963407; return Double(state >> 11) / Double(1 << 53) }
        return (0..<count).map { _ in (-2 * log(max(next(), 1e-12))).squareRoot() * cos(2 * .pi * next()) }
    }

    static func revamp3() async {
        wheelStrength()
        clarityChecks()
        glowChecks()
        textureChecks()
        maskingChecks()
        await revamp3Photos()
    }

    // MARK: Colour Grading wheels' strength

    private static func wheelStrength() {
        let ramp = fsImage(98, 4) { x, _ in x == 0 ? SIMD3(repeating: 0) : SIMD3(repeating: Float(0.18 * exp2(Double(x - 1) / 8 - 8))) }
        func at(_ s: Double) -> Int { 1 + Int((s + 8) * 8) }
        var rows: [String] = [], warm03 = 0.0
        for reach in [0.12, 0.3, 0.4] {
            var a = PhotoAdjustments()
            let plainScene = fsDeveloped(ramp, a, scene: true), plainShown = fsDeveloped(ramp, a)
            a.wheels.gamma = .init(x: reach * cos(.pi / 6), y: reach * sin(.pi / 6), master: 0)
            let scene = fsDeveloped(ramp, a, scene: true), shown = fsDeveloped(ramp, a)
            let w = 98
            let warmth = stride(from: -4.0, through: 3.5, by: 0.5).map { s -> Double in
                let x = 2 * w + at(s), g = scene[x], p = plainScene[x]
                return log2(max(g.x, 1e-9) / max(g.z, 1e-9)) - log2(max(p.x, 1e-9) / max(p.z, 1e-9))
            }.max()!
            let grey = fsLab(shown[2 * w + at(0)]), greyPlain = fsLab(plainShown[2 * w + at(0)])
            rows.append(String(format: "Lightroom %.0f: red/blue up to %+.3f stop, mid grey on screen OkLab C %.4f (plain %.4f)", reach / 0.4 * 100, warmth, fsChroma(grey), fsChroma(greyPlain)))
            if reach == 0.3 { warm03 = warmth }
        }
        note("wheels warm Midtones (hue 30) on p5: " + rows.joined(separator: "; ") + " (before: Lightroom 75 gave +1.004)")
        check("wheels push about Lightroom's strength", warm03 > 0.3 && warm03 < 0.65, String(format: "Lightroom 75 moves red/blue %+.3f stop (0.3…0.65; was +1.004)", warm03))
    }

    // MARK: T12 Clarity

    private static func clarityChecks() {
        // A dark room (0.03) beside a bright window (2.0, 6 stops up), 800 px: each pixel's change, in scene light.
        let edge = fsImage(800, 24) { x, _ in SIMD3(repeating: x < 400 ? 0.03 : 2.0) }
        func change(_ process: Int, _ clarity: Double) -> [Double] {
            var a = PhotoAdjustments(); a.process = process
            let plain = fsDeveloped(edge, a, scene: true)
            a.clarity = clarity
            let out = fsDeveloped(edge, a, scene: true)
            return (0..<800).map { log2(max(r3Y(out[12 * 800 + $0]), 1e-9) / max(r3Y(plain[12 * 800 + $0]), 1e-9)) }
        }
        var halo: [Int: (dark: Double, darkMinus: Double, bright: Double)] = [:]
        for process in [4, 5] {
            let up = change(process, 100), down = change(process, -100)
            // (Beyond 0.5 % of the width from the edge.)
            let darkSide = 0..<396, brightSide = 404..<800
            halo[process] = (darkSide.map { up[$0] }.min()!, darkSide.map { down[$0] }.max()!, brightSide.map { max(up[$0], down[$0]) }.max()!)
        }
        note(String(format: "clarity at a window's edge, beyond 0.5%% of the width: +100 darkens the room by up to %.3f stop (p4 %.3f); −100 lifts it %.3f (p4 %.3f); the window brightens %.3f (p4 %.3f)",
                    -halo[5]!.dark, -halo[4]!.dark, halo[5]!.darkMinus, halo[4]!.darkMinus, halo[5]!.bright, halo[4]!.bright))
        check("clarity no dark halo beside something bright", -halo[5]!.dark < 0.1 && halo[5]!.darkMinus < 0.1,
              String(format: "+100 undershoot %.3f stop, −100 lift %.3f (both under 0.1); p4 %.3f / %.3f", -halo[5]!.dark, halo[5]!.darkMinus, -halo[4]!.dark, halo[4]!.darkMinus))
        check("clarity no white glow", halo[5]!.bright < 0.1, String(format: "window brightens %.3f stop (under 0.1); p4 %.3f", halo[5]!.bright, halo[4]!.bright))

        // Mid-sized shapes (blobs 5 % of the width, ±0.5 stop around grey): +50 raises their contrast, −50 lowers it.
        let blobs = fsImage(480, 480) { x, y in SIMD3(repeating: Float(0.18 * exp2(0.5 * sin(2 * .pi * Double(x) / 24) * sin(2 * .pi * Double(y) / 24)))) }
        func spread(_ process: Int, _ clarity: Double) -> Double {
            var a = PhotoAdjustments(); a.process = process; a.clarity = clarity
            let out = fsDeveloped(blobs, a, scene: true)
            var L: [Double] = []
            for y in stride(from: 120, to: 360, by: 2) { for x in stride(from: 120, to: 360, by: 2) { L.append(log2(max(r3Y(out[y * 480 + x]), 1e-9))) } }
            let m = L.reduce(0, +) / Double(L.count)
            return (L.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(L.count)).squareRoot()
        }
        var gains: [Int: (up: Double, down: Double)] = [:]
        for process in [4, 5] { let s0 = spread(process, 0); gains[process] = (spread(process, 50) / s0, spread(process, -50) / s0) }
        note(String(format: "clarity on mid-sized shapes: +50 ×%.2f (p4 ×%.2f), −50 ×%.2f (p4 ×%.2f)", gains[5]!.up, gains[4]!.up, gains[5]!.down, gains[4]!.down))
        check("clarity raises and lowers local contrast", gains[5]!.up > 1.15 && gains[5]!.down < 0.9 && gains[5]!.down > 0.4,
              String(format: "+50 ×%.2f (over 1.15), −50 ×%.2f (0.4…0.9)", gains[5]!.up, gains[5]!.down))

        // −100 keeps black where it is (on screen): a black square in grey and a black wall beside it.
        let blacks = fsImage(480, 240) { x, y in SIMD3(repeating: x < 140 || (x >= 300 && x < 340 && y >= 100 && y < 140) ? 0.0015 : 0.18) }
        var moved: [Int: Double] = [:]
        for process in [4, 5] {
            var a = PhotoAdjustments(); a.process = process
            let plain = fsDeveloped(blacks, a)
            a.clarity = -100
            let soft = fsDeveloped(blacks, a)
            moved[process] = [(60, 120), (130, 120), (320, 120), (303, 103)].map { r3Enc(r3Y(soft[$0.1 * 480 + $0.0])) - r3Enc(r3Y(plain[$0.1 * 480 + $0.0])) }.max()!
        }
        note(String(format: "clarity −100, black on screen (sRGB steps) rises by %.4f (p4 %.4f)", moved[5]!, moved[4]!))
        check("clarity minus keeps black", moved[5]! < 0.01, String(format: "rises %.4f (under 0.01); p4 %.4f", moved[5]!, moved[4]!))
    }

    // MARK: Glow

    private static func glowChecks() {
        // A dark room (0.02) with a lamp (12, about 6 stops up) and a few black pixels near it; 600 × 200.
        let lamp = SIMD2(150.0, 100.0)
        let image = fsImage(600, 200) { x, y in
            let d = ((Double(x) - lamp.x) * (Double(x) - lamp.x) + (Double(y) - lamp.y) * (Double(y) - lamp.y)).squareRoot()
            if d < 15 { return SIMD3(12, 10, 7) }
            if x >= 178 && x < 182 && y >= 98 && y < 102 { return SIMD3(repeating: 0) }
            return SIMD3(repeating: 0.02)
        }
        var a = PhotoAdjustments()
        let plain = fsDeveloped(image, a)
        let near = 100 * 600 + 186, black = 100 * 600 + 180, far = 100 * 600 + 560
        var rows: [String] = [], ok = true
        for mode in PhotoAdjustments.GlowMode.allCases {
            a.glow = 60; a.glowMode = mode
            let out = fsDeveloped(image, a)
            let lift = r3Y(out[near]) - r3Y(plain[near]), farLift = abs(r3Y(out[far]) - r3Y(plain[far])), blackLift = r3Y(out[black])
            let darkest = zip(out, plain).map { r3Y($0.0) - r3Y($0.1) }.min()!
            rows.append(String(format: "%@: near %.4f→%.4f, far moves %.5f, black %.5f, most darkened %.5f", mode.rawValue, r3Y(plain[near]), r3Y(out[near]), farLift, blackLift, -darkest))
            let lifts = [.add, .screen, .lighten].contains(mode)
            ok = ok && lift > (lifts ? 0.01 : r3Y(plain[near]) * 0.15) && farLift < 0.002 && darkest > -0.001 && (lifts ? blackLift > 0.003 : blackLift < 1e-4)
        }
        // The old mist (process 4, Clarity −60), for the before.
        var old = PhotoAdjustments(); old.process = 4
        let oldPlain = fsDeveloped(image, old)
        old.clarity = -60
        let oldMist = fsDeveloped(image, old)
        rows.append(String(format: "p4 mist (Clarity −60): near %.4f→%.4f, far %.4f→%.4f, black %.5f", r3Y(oldPlain[near]), r3Y(oldMist[near]), r3Y(oldPlain[far]), r3Y(oldMist[far]), r3Y(oldMist[black])))
        note("glow 60 beside a lamp (display light): " + rows.joined(separator: "; "))
        check("glow spreads light only near bright parts", ok, rows.joined(separator: "; "))

        // Updating an old edit: its negative Clarity (the mist) becomes Glow on Screen, Clarity 0; a positive one stays.
        var mist = PhotoAdjustments(); mist.process = 4; mist.clarity = -40
        let up = mist.updated(isRaw: true)
        var crisp = PhotoAdjustments(); crisp.process = 4; crisp.clarity = 30
        let upCrisp = crisp.updated(isRaw: true)
        check("update turns the mist into glow", up.process == 5 && up.clarity == 0 && abs(up.glow - 40 * PhotoAdjustments.mistToGlow) < 1e-9 && up.glowMode == .screen
              && upCrisp.clarity == 30 && upCrisp.glow == 0, "\(up.clarity) \(up.glow) \(up.glowMode); \(upCrisp.clarity) \(upCrisp.glow)")
        // Saved before Glow: decodes with none.
        let saved = try? JSONDecoder().decode(PhotoAdjustments.self, from: Data(#"{"process":4,"clarity":-20}"#.utf8))
        check("old settings decode without glow", saved?.glow == 0 && saved?.glowMode == .screen && saved?.sharpenMask == 0 && saved?.clarity == -20, "\(String(describing: saved))")
    }

    // MARK: T13 Texture

    private static func textureChecks() {
        // 480 × 300: brightness 0.03 … 0.12 across, noise σ² = 3e-5·Y + 1e-6 (about 0.04 stop); the bottom 100 rows also have
        // stripes 8 px apart, ±0.1 stop.
        let n = r3Noise(480 * 300, seed: 7)
        let image = fsImage(480, 300) { x, y in
            let xd = Double(x)
            var Y: Double = 0.03 * exp2(2 * xd / 480)
            if y >= 200 { let wave: Double = sin(2 * Double.pi * xd / 8); Y *= exp2(0.1 * wave) }
            let sigma: Double = (3e-5 * Y + 1e-6).squareRoot()
            return SIMD3<Float>(repeating: Float(Y + sigma * n[y * 480 + x]))
        }
        func L(_ process: Int, _ texture: Double) -> [Double] {
            var a = PhotoAdjustments(); a.process = process; a.texture = texture
            return fsDeveloped(image, a, scene: true).map { log2(max(r3Y($0), 1e-9)) }
        }
        func noise(_ l: [Double]) -> Double {
            var s = 0.0, c = 0.0
            for y in 20..<180 { for x in 10..<470 { let d = l[y * 480 + x] - l[(y + 1) * 480 + x]; s += d * d; c += 1 } }
            return (s / c / 2).squareRoot()
        }
        func stripes(_ l: [Double]) -> Double {
            var profile = [Double](repeating: 0, count: 480)
            for x in 0..<480 { var sum = 0.0; for y in 220..<280 { sum += l[y * 480 + x] }; profile[x] = sum / 60 }
            var s = 0.0, c = 0.0
            for x in 16..<464 {
                var trend = 0.0
                for k in (x - 4)..<(x + 4) { trend += profile[k] }
                let d = profile[x] - trend / 8
                s += d * d; c += 1
            }
            return (s / c).squareRoot()
        }
        let model = PhotoRender.noiseModel(image)
        note("texture test noise model: \(String(describing: model)) (made with a 3e-5, b 1e-6)")
        var ratios: [Int: (noise: Double, stripes: Double)] = [:]
        for process in [4, 5] {
            let plain = L(process, 0), raised = L(process, 100)
            ratios[process] = (noise(raised) / noise(plain), stripes(raised) / stripes(plain))
        }
        note(String(format: "texture +100: flat noise ×%.2f (p4 ×%.2f), fine stripes ×%.2f (p4 ×%.2f)", ratios[5]!.noise, ratios[4]!.noise, ratios[5]!.stripes, ratios[4]!.stripes))
        // (Stripes: at least 80 % of process 4's raise; 4 itself gets ×1.6 at most here, its small base following the stripes.)
        let wanted = 1 + 0.8 * (ratios[4]!.stripes - 1)
        check("texture leaves noise alone", ratios[5]!.noise <= 1.2 && ratios[5]!.stripes >= wanted,
              String(format: "noise ×%.2f (at most 1.2), stripes ×%.2f (at least ×%.2f); p4 ×%.2f / ×%.2f", ratios[5]!.noise, ratios[5]!.stripes, wanted, ratios[4]!.noise, ratios[4]!.stripes))
    }

    // MARK: Sharpen Masking

    private static func maskingChecks() {
        // 480 × 200, noisy (σ 0.006): the top half flat (0.1), the bottom a step 0.05 | 0.4.
        let n = r3Noise(480 * 200, seed: 11)
        let image = fsImage(480, 200) { x, y in SIMD3(repeating: Float((y < 100 ? 0.1 : x < 240 ? 0.05 : 0.4) + 0.006 * n[y * 480 + x])) }
        func shown(_ sharpen: Double, _ mask: Double) -> [Double] {
            var a = PhotoAdjustments(); a.sharpen = sharpen; a.sharpenMask = mask
            return fsDeveloped(image, a).map { r3Enc(r3Y($0)) }
        }
        func noise(_ e: [Double]) -> Double {
            var s = 0.0, c = 0.0
            for y in 10..<90 { for x in 10..<470 { let d = e[y * 480 + x] - e[y * 480 + x + 1]; s += d * d; c += 1 } }
            return (s / c / 2).squareRoot()
        }
        func edge(_ e: [Double]) -> Double { (130..<170).map { y in (236..<244).map { abs(e[y * 480 + $0 + 1] - e[y * 480 + $0]) }.max()! }.reduce(0, +) / 40 }
        let none = shown(0, 0)
        var rows: [String] = [], results: [Double: (noise: Double, edge: Double)] = [:]
        for mask in [0.0, 50, 80, 100] {
            let e = shown(70, mask)
            results[mask] = (noise(e) / noise(none), edge(e) / edge(none))
            rows.append(String(format: "Masking %.0f: flat noise ×%.2f, edge steepness ×%.2f", mask, results[mask]!.noise, results[mask]!.edge))
        }
        note("sharpen 70: " + rows.joined(separator: "; "))
        check("sharpen masking keeps flat areas, sharpens edges", results[80]!.noise < 1.02 && results[0]!.noise > 1.05 && results[80]!.edge > 1.03
              && results[80]!.edge > 0.9 * results[0]!.edge, rows.joined(separator: "; "))
    }

    // MARK: Real photos (notes) and the sheet's renders

    /// Mist → Glow (how much Glow on Screen gives about the old Clarity −50's added light), and, into <photos>/../revamp3/dump
    /// when that folder exists, 8-bit sRGB PNGs for the before/after sheet and the Effects section as the inspector draws it.
    private static func revamp3Photos() async {
        let base = URL(fileURLWithPath: photos).deletingLastPathComponent()
        let out = base.appendingPathComponent("revamp3/dump"), raws = base.appendingPathComponent("shootout/raws")
        let dump = FileManager.default.fileExists(atPath: out.path)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        func write(_ cg: CGImage, _ name: String) {
            guard dump, let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, cg, nil); CGImageDestinationFinalize(dest)
        }
        func save(_ image: CIImage, _ name: String) {
            guard dump else { return }
            let e = image.extent.integral
            let placed = image.cropped(to: e).transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            if let cg = PhotoEngine.context.createCGImage(placed, from: placed.extent, format: .RGBA8, colorSpace: srgb) { write(cg, name) }
        }
        func render(_ file: String, size: Int = 900, crop: CGRect? = nil, _ change: (inout PhotoAdjustments) -> Void) -> CIImage? {
            let path = raws.appendingPathComponent(file).path
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            var record = PhotoRecord(); change(&record.adjust)
            BaseCache.shared.removeAll(); GuideCache.shared.removeAll()
            guard let decoded = PhotoRender.decoded(path, maxSize: size, record: record) else { return nil }
            let shown = PhotoRender.output(PhotoRender.adjusted(decoded, record.adjust, path: path), record.adjust, p3: false)
            guard let crop else { return shown }
            let e = shown.extent
            return shown.cropped(to: CGRect(x: e.minX + crop.minX * e.width, y: e.minY + crop.minY * e.height, width: crop.width * e.width, height: crop.height * e.height))
        }
        func luma(_ image: CIImage) -> [Double] {
            let e = image.extent.integral, w = Int(e.width), h = Int(e.height)
            var px = [UInt8](repeating: 0, count: w * h * 4)
            PhotoEngine.context.render(image, toBitmap: &px, rowBytes: w * 4, bounds: e, format: .RGBA8, colorSpace: srgb)
            return stride(from: 0, to: px.count, by: 4).map { (0.2126 * Double(px[$0]) + 0.7152 * Double(px[$0 + 1]) + 0.0722 * Double(px[$0 + 2])) / 255 }
        }
        // Mist → Glow: the old −50's added light (sRGB, mean and 95th percentile) against Glow Screen at 25…100.
        for file in ["DSC02868.ARW", "DSC01980.ARW"] {
            guard let plain4 = render(file, size: 600, { $0.process = 4 }), let mist = render(file, size: 600, { $0.process = 4; $0.clarity = -50 }),
                  let plain5 = render(file, size: 600, { _ in }) else { continue }
            func lift(_ a: [Double], _ b: [Double]) -> (Double, Double) {
                let d = zip(a, b).map { $0.0 - $0.1 }.sorted()
                return (d.reduce(0, +) / Double(d.count), d[d.count * 95 / 100])
            }
            let old = lift(luma(mist), luma(plain4)), p5 = luma(plain5)
            var row = String(format: "%@ mist −50: mean %+.4f, 95%% %+.4f;", file, old.0, old.1)
            for g in [25.0, 50, 75, 100] {
                if let glow = render(file, size: 600, { $0.glow = g }) { let l = lift(luma(glow), p5); row += String(format: " glow %.0f: %+.4f / %+.4f;", g, l.0, l.1) }
            }
            note("mist to glow: " + row)
        }
        guard dump else { return }
        // Clarity ±100 by the windows (DSC01962), before and after.
        for (name, process, clarity) in [("plain", 5, 0.0), ("p4-up", 4, 100), ("p4-down", 4, -100), ("p5-up", 5, 100), ("p5-down", 5, -100)] {
            if let image = render("DSC01962.ARW", { $0.process = process; $0.clarity = clarity }) { save(image, "clarity-\(name)") }
        }
        // Glow: each mode on the stage photo and the backlit one, with the old mist beside.
        for file in ["DSC02868", "DSC01980"] {
            if let image = render(file + ".ARW", { _ in }) { save(image, "glow-\(file)-none") }
            if let image = render(file + ".ARW", { $0.process = 4; $0.clarity = -60 }) { save(image, "glow-\(file)-mist") }
            for mode in PhotoAdjustments.GlowMode.allCases {
                if let image = render(file + ".ARW", { $0.glow = 60; $0.glowMode = mode }) { save(image, "glow-\(file)-\(mode.rawValue)") }
            }
        }
        // Texture +100 at full size (a 600 × 400 piece of R6LO7461): none, before, after.
        let piece = CGRect(x: 0.42, y: 0.42, width: 0.1, height: 0.1)
        for (name, process, texture) in [("none", 5, 0.0), ("p4", 4, 100), ("p5", 5, 100)] {
            if let image = render("R6LO7461.CR3", size: 0, crop: piece, { $0.process = process; $0.texture = texture }) { save(image, "texture-\(name)") }
        }
        // Sharpen 80 with Masking 0 / 50 / 100, a small piece at full size (shown at 300 %).
        let small = CGRect(x: 0.45, y: 0.45, width: 0.04, height: 0.04)
        if let image = render("R6LO7461.CR3", size: 0, crop: small, { _ in }) { save(image, "sharpen-none") }
        for mask in [0.0, 50, 100] {
            if let image = render("R6LO7461.CR3", size: 0, crop: small, { $0.sharpen = 80; $0.sharpenMask = mask }) { save(image, "sharpen-mask\(Int(mask))") }
        }
        BaseCache.shared.removeAll(); GuideCache.shared.removeAll()
        // The Effects section with Glow, as the inspector draws it (dark), its fold open (put back).
        let defaults = UserDefaults.standard, wasOpen = defaults.object(forKey: "fold-effects")
        defaults.set(true, forKey: "fold-effects")
        defer { defaults.set(wasOpen, forKey: "fold-effects") }
        var adjust = PhotoAdjustments(); adjust.glow = 45; adjust.glowSize = 60; adjust.glowMode = .softLight
        let view = VStack(alignment: .leading, spacing: 16) {
            AdjustFold(title: "Effects", section: .effects, adjust: adjust, open: true, reset: {}) {
                GlowControls(adjust: adjust) { _ in }
                AdjustSlider(title: "Grain", value: 0, range: 0...100) { _ in }
            }
        }
        .panelColumn()
        .frame(width: 280, height: 190, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(x: 0, y: 0, width: 280, height: 190)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(400))
        hosting.layoutSubtreeIfNeeded()
        if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            if let cg = rep.cgImage { write(cg, "ui-effects") }
        }
        window.close()
    }
}
