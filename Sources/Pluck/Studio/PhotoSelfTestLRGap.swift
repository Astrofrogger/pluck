import AppKit
import CoreImage
import UniformTypeIdentifiers

/// Measurement only (PluckScreenshotOnly "lrgap"): each RAW listed in <photos>/../lrgap/jobs.txt, full size, 16-bit sRGB TIFFs
/// into <photos>/../lrgap/dump: Pluck's default edit (process 4, Classic), the same with Sharpen 27 (Lightroom's 40 by the
/// import's 1/1.5), the default with Colour noise 0, and Apple's own decode with every CIRAWFilter default (no Pluck processing), on its default decoder and on decoder 9.
extension PhotoSelfTest {
    static func lrGapDump() async {
        let folder = URL(fileURLWithPath: photos).deletingLastPathComponent().appendingPathComponent("lrgap")
        guard let list = try? String(contentsOf: folder.appendingPathComponent("jobs.txt"), encoding: .utf8) else { skip("lr gap", "no jobs.txt"); return }
        let out = folder.appendingPathComponent("dump")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        func save(_ image: CIImage, _ name: String) {
            let e = image.extent.integral
            let placed = image.cropped(to: e).transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            guard let cg = PhotoEngine.context.createCGImage(placed, from: placed.extent, format: .RGBA16, colorSpace: srgb),
                  let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name + ".tif") as CFURL, UTType.tiff.identifier as CFString, 1, nil)
            else { check("lr gap \(name)", false, "no picture"); return }
            CGImageDestinationAddImage(dest, cg, nil)
            check("lr gap \(name)", CGImageDestinationFinalize(dest), "write")
        }
        // (tags.txt, when there: only those renders, e.g. "p4".)
        let tags = (try? String(contentsOf: folder.appendingPathComponent("tags.txt"), encoding: .utf8))
            .map { Set($0.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }) }
        for path in list.split(separator: "\n").map(String.init) where !path.isEmpty {
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            for (tag, sharpen, colour) in [("p4", 0.0, 25.0), ("p4s27", 40.0 / 1.5, 25.0), ("p4cnr0", 0.0, 0.0)] where tags?.contains(tag) ?? true {
                var record = PhotoRecord()
                record.adjust.profile = .adobe
                record.adjust.sharpen = sharpen
                record.adjust.colorNoise = colour
                BaseCache.shared.removeAll(); GuideCache.shared.removeAll()
                let started = Date()
                guard let decoded = PhotoRender.decoded(path, maxSize: 0, record: record) else { check("lr gap \(name) \(tag)", false, "not decoded"); continue }
                save(PhotoRender.output(PhotoRender.adjusted(decoded, record.adjust, path: path), record.adjust, p3: false), "\(name)-\(tag)")
                note("lr gap \(name) \(tag): process \(record.adjust.process), decoder \(PhotoRender.currentDecoder(path) ?? "?"), \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            }
            guard tags?.contains("apple") ?? true else { continue }
            guard let raw = CIRAWFilter(imageURL: URL(fileURLWithPath: path)), let apple = raw.outputImage else { check("lr gap \(name) apple", false, "no decode"); continue }
            note("lr gap \(name) apple: decoder \(raw.decoderVersion.rawValue), lens \(raw.isLensCorrectionEnabled), boost \(raw.boostAmount), nr \(raw.luminanceNoiseReductionAmount)/\(raw.colorNoiseReductionAmount), sharp \(raw.sharpnessAmount), ltm \(raw.localToneMapAmount)")
            save(apple, "\(name)-apple")
            // The same Apple defaults on decoder 9 (what process 4 decodes with): decoder 8 against 9 alone.
            if let nine = CIRAWFilter(imageURL: URL(fileURLWithPath: path)), let v9 = nine.supportedDecoderVersions.first(where: { $0.rawValue == "9" }) {
                nine.decoderVersion = v9
                if let image = nine.outputImage { save(image, "\(name)-apple9") }
            } else { note("lr gap \(name): no decoder 9") }
        }
    }
}

/// The Lightroom-gap fixes (process 4 only): Classic on Apple's colour, strong light keeping its light, Accurate and Neutral
/// as before, the camera's lens shading read and applied, the black lift by ISO, and the fine texture.
extension PhotoSelfTest {
    nonisolated(unsafe) private static let gapSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    private static func gapRow(_ colours: [SIMD3<Float>]) -> CIImage {
        let w = colours.count * 4, h = 8
        var px = [Float](repeating: 1, count: w * h * 4)
        for y in 0..<h { for x in 0..<w { let c = colours[x / 4], i = (y * w + x) * 4; px[i] = c.x; px[i + 1] = c.y; px[i + 2] = c.z } }
        return CIImage(bitmapData: px.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: w * 16, size: CGSize(width: w, height: h),
                       format: .RGBAf, colorSpace: gapSpace)
    }

    private static func gapPixels(_ image: CIImage) -> [Float] {
        let e = image.extent.integral
        var px = [Float](repeating: 0, count: Int(e.width) * Int(e.height) * 4)
        px.withUnsafeMutableBytes { PhotoEngine.context.render(image, toBitmap: $0.baseAddress!, rowBytes: Int(e.width) * 16, bounds: e, format: .RGBAf, colorSpace: gapSpace) }
        return px
    }

    /// Each colour developed (the middle of its cell), as OkLCh.
    private static func gapDeveloped(_ colours: [SIMD3<Float>], _ a: PhotoAdjustments) -> [(L: Double, C: Double, h: Double)] {
        let px = gapPixels(PhotoRender.adjusted(gapRow(colours), a, isRaw: true, kelvin: 5500)), w = colours.count * 4
        return colours.indices.map { i in
            let j = (4 * w + i * 4 + 2) * 4
            let (L, a, b) = OkLab.from(Double(px[j]), Double(px[j + 1]), Double(px[j + 2]))
            let h = atan2(b, a) * 180 / .pi
            return (L, (a * a + b * b).squareRoot(), h < 0 ? h + 360 : h)
        }
    }

    static func lrGapFixes() async {
        // A lawn green, a teal, a sky blue, skin, a stage magenta and red (strong light), linear sRGB.
        let colours: [SIMD3<Float>] = [SIMD3(0.06, 0.14, 0.03), SIMD3(0.03, 0.12, 0.11), SIMD3(0.10, 0.17, 0.32), SIMD3(0.40, 0.25, 0.17),
                                       SIMD3(0.55, 0.02, 0.60), SIMD3(0.70, 0.03, 0.04)]
        func run(_ process: Int, _ profile: PhotoEngine.Profile) -> [(L: Double, C: Double, h: Double)] {
            var a = PhotoAdjustments(); a.process = process; a.profile = profile; return gapDeveloped(colours, a)
        }
        let c3 = run(3, .adobe), c4 = run(4, .adobe)
        let text = zip(c3, c4).map { String(format: "C %.3f→%.3f h %.0f→%.0f L %.3f→%.3f", $0.C, $1.C, $0.h, $1.h, $0.L, $1.L) }.joined(separator: "; ")
        note("process 4 Classic against process 3 (green, teal, sky, skin, magenta, red): \(text)")
        // The tables (rendered, chroma also follows process 4's darker mid-tones): Apple's default against version 3's Classic on
        // five RAWs: greens 1.2–1.3×, teal and blues 1.1–1.3×, skin 1.03–1.08×.
        func table(_ change: (SIMD3<Double>) -> SIMD3<Double>, _ c: SIMD3<Float>) -> (C: Double, h: Double) {
            let s = ColourProfiles.mul(PhotoEngine.fromProPhoto, change(ColourProfiles.mul(PhotoEngine.toProPhoto, SIMD3<Double>(c))))
            let (_, a, b) = OkLab.from(s.x, s.y, s.z), h = atan2(b, a) * 180 / .pi
            return ((a * a + b * b).squareRoot(), h < 0 ? h + 360 : h)
        }
        let t3 = colours.map { table(ColourProfiles.change(.adobe), $0) }, t4 = colours.map { table(ColourProfiles.change4(.adobe), $0) }
        let ratio = zip(t3, t4).map { $1.C / $0.C }
        check("process 4 classic has apple's colour", ratio[0] >= 1.12 && ratio[1] >= 1.08 && ratio[2] >= 1.08 && ratio[3] >= 1.0 && ratio[3] <= 1.1
              && zip(t3, t4).prefix(4).allSatisfy { abs($0.h - $1.h) <= 6 },
              "table chroma green ≥1.12×, teal and sky ≥1.08×, skin 1–1.1× of process 3's, hue within 6°; got \(ratio.map { String(format: "%.3f", $0) })")
        // Strong light: before, Classic's density took up to 20% of its lightness (the stage light 8 OkLab L ×100 darker than Apple's).
        check("strong light keeps its light (process 4)", c4[4].L >= c3[4].L + 0.02 && c4[5].L >= c3[5].L + 0.02 && c4[4].C >= c3[4].C * 0.95,
              String(format: "magenta L %.3f→%.3f, red L %.3f→%.3f (at least +0.02), magenta C %.3f→%.3f", c3[4].L, c4[4].L, c3[5].L, c4[5].L, c3[4].C, c4[4].C))
        // Neutral: process 4 as process 3. Accurate: its colour as process 3's (hue); its brightness
        // follows Classic's (profiles share mid grey).
        let n3 = run(3, .neutral), n4 = run(4, .neutral)
        let worst = zip(n3, n4).map { max(abs($0.L - $1.L), abs($0.C - $1.C)) }.max() ?? 1
        check("process 4 neutral colour as process 3", worst < 0.002, String(format: "largest OkLab difference %.4f", worst))
        let a3 = run(3, .accurate), a4 = run(4, .accurate)
        // (Its chromaticity is kept through the curve, so only the hue is comparable at another lightness.)
        let drift = zip(a3, a4).map { abs($0.h - $1.h) }.max() ?? 99
        check("process 4 accurate colour as process 3", drift <= 2, String(format: "largest hue difference %.1f° (at most 2)", drift))

        // Lens shading: the Sony RAW's own table, read; applied as 2^(value/8192) by the share of the half diagonal.
        let raws = URL(fileURLWithPath: photos).deletingLastPathComponent().appendingPathComponent("shootout/raws")
        let arw = raws.appendingPathComponent("DSC02845.ARW").path
        if FileManager.default.fileExists(atPath: arw) {
            let knots = PhotoRender.readShading(arw)
            check("lens shading read from the raw", knots?.count == 11 && knots?.first == 0 && knots?.last == 7376,
                  "11 values, 0 at the centre, 7376 at the corner; got \(String(describing: knots))")
            let flat = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 200))
            let px = gapPixels(PhotoRender.shaded(flat, knots ?? [0, 0]))
            let centre = Double(px[(100 * 300 + 150) * 4]), corner = Double(px[(0 * 300 + 0) * 4])
            check("lens shading brightens the corners", abs(corner / centre / exp2(7376.0 / 8192) - 1) < 0.03,
                  String(format: "corner ×%.3f the centre (%.3f)", corner / centre, exp2(7376.0 / 8192)))
        } else { skip("lens shading read from the raw", "no shootout RAW") }
        check("no lens shading without the camera's data", PhotoRender.readShading(URL(fileURLWithPath: photos).appendingPathComponent("none.jpg").path) == nil
              && PhotoRender.lensShading("/nonexistent.ARW") == nil, "nil for other files")

        // Texture: a low-contrast ±2% fine pattern on grey comes out about twice as strong; a strong edge isn't changed.
        let w = 64, h = 64
        var tex = [Float](repeating: 1, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            let v: Float = x < 32 ? 0.2 * (1 + 0.02 * ((x + y) % 2 == 0 ? 1 : -1)) : (y < 32 ? 0.05 : 0.6)
            tex[i] = v; tex[i + 1] = v; tex[i + 2] = v
        } }
        let image = CIImage(bitmapData: tex.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: w * 16, size: CGSize(width: w, height: h),
                            format: .RGBAf, colorSpace: gapSpace)
        let out = gapPixels(PhotoRender.textured(image, iso: 100))
        func amp(_ p: [Float]) -> Double {
            var s = 0.0, n = 0.0
            for y in 16..<48 { for x in 8..<24 { s += abs(Double(p[(y * w + x) * 4]) - 0.2); n += 1 } }
            return s / n / 0.2
        }
        let before = amp(tex), after = amp(out)
        var edge = 0.0
        for y in 20..<44 { for x in 40..<60 { edge = max(edge, abs(Double(out[(y * w + x) * 4]) - Double(tex[(y * w + x) * 4]))) } }
        check("fine texture brought back up (process 4)", after >= before * 1.5 && after <= before * 2.6 && edge < 0.6 * 0.03,
              String(format: "pattern ±%.4f → ±%.4f (1.5–2.6×), strong edge changed at most %.4f (under 0.018)", before, after, edge))

        // Blacks: the lift by ISO; an ISO 125 RAW's darkest places nearer Lightroom's (before: darkest 0.5%% at OkLab L 0.081, LR 0.056).
        let low = raws.appendingPathComponent("DSC01980.ARW").path
        if FileManager.default.fileExists(atPath: low) {
            var record = PhotoRecord(); record.adjust.profile = .adobe
            BaseCache.shared.removeAll(); GuideCache.shared.removeAll()
            if let image = PhotoRender.image(low, record: record, maxSize: 1500), let picture = PhotoRender.picture(image, maxSize: 1500) {
                let shown = CIImage(cgImage: picture), px = gapPixels(shown)
                var ls: [Double] = []
                for i in stride(from: 0, to: px.count, by: 16) { ls.append(OkLab.from(Double(px[i]), Double(px[i + 1]), Double(px[i + 2])).0) }
                ls.sort()
                let dark = ls[ls.count / 200]
                check("darkest blacks by iso (process 4)", dark <= 0.07 && dark >= 0.035, String(format: "darkest 0.5%% OkLab L %.3f (0.035–0.07; before 0.081)", dark))
            } else { check("darkest blacks by iso (process 4)", false, "not rendered") }
        } else { skip("darkest blacks by iso (process 4)", "no shootout RAW") }
    }
}
