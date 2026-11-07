import CoreImage
import Foundation
import UniformTypeIdentifiers

/// Process 5: Standard (natural colour on Apple's default) as the RAW starting profile, and Saturation and Vibrance as
/// DaVinci Resolve's HSV saturation (PhotoEngine `hsvSaturation`).
extension PhotoSelfTest {
    nonisolated(unsafe) private static let gradeSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    private static func gradePixels(_ image: CIImage) -> [Float] {
        let e = image.extent.integral
        var px = [Float](repeating: 0, count: Int(e.width) * Int(e.height) * 4)
        px.withUnsafeMutableBytes { PhotoEngine.context.render(image, toBitmap: $0.baseAddress!, rowBytes: Int(e.width) * 16, bounds: e, format: .RGBAf, colorSpace: gradeSpace) }
        return px
    }

    /// Colours (linear sRGB) developed as a RAW, each as Rec.2020 with a 2.4 gamma (hsvSaturation's space).
    private static func graded(_ colours: [SIMD3<Float>], _ a: PhotoAdjustments) -> [SIMD3<Double>] {
        let w = colours.count * 4, h = 8
        var px = [Float](repeating: 1, count: w * h * 4)
        for y in 0..<h { for x in 0..<w { let c = colours[x / 4], i = (y * w + x) * 4; px[i] = c.x; px[i + 1] = c.y; px[i + 2] = c.z } }
        let row = CIImage(bitmapData: px.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: w * 16, size: CGSize(width: w, height: h),
                          format: .RGBAf, colorSpace: gradeSpace)
        let out = gradePixels(PhotoRender.adjusted(row, a, isRaw: true, kelvin: 5500))
        return colours.indices.map { i in
            let j = (4 * w + i * 4 + 2) * 4
            let s = SIMD3(Double(out[j]), Double(out[j + 1]), Double(out[j + 2]))
            let r = SIMD3(0.6274039 * s.x + 0.3292830 * s.y + 0.0433131 * s.z, 0.0690973 * s.x + 0.9195404 * s.y + 0.0113623 * s.z,
                          0.0163914 * s.x + 0.0880133 * s.y + 0.8955953 * s.z)
            return SIMD3(r.x.sign == .minus ? -pow(-r.x, 1 / 2.4) : pow(r.x, 1 / 2.4), r.y.sign == .minus ? -pow(-r.y, 1 / 2.4) : pow(r.y, 1 / 2.4),
                         r.z.sign == .minus ? -pow(-r.z, 1 / 2.4) : pow(r.z, 1 / 2.4))
        }
    }

    private static func hsvS(_ e: SIMD3<Double>) -> Double { e.max() > 0 ? (e.max() - e.min()) / e.max() : 0 }

    static func gradeChecks() async {
        // Standard is process 5's RAW start; process 3 and 4 edits without a profile keep Classic; it's in every list.
        var p5 = PhotoAdjustments(), p4 = PhotoAdjustments(), p3 = PhotoAdjustments()
        p4.process = 4; p3.process = 3
        check("process 5 raw starts on standard", PhotoAdjustments.currentProcess == 5 && PhotoEngine.Profile.starting(p5, isRaw: true) == .standard
              && PhotoEngine.Profile.starting(p4, isRaw: true) == .adobe && PhotoEngine.Profile.starting(p3, isRaw: true) == .adobe
              && PhotoEngine.Profile.starting(p5, isRaw: false) == .asShot && p4.updated(isRaw: true).profile == .adobe
              && (3...5).allSatisfy { PhotoEngine.Profile.choices(raw: true, process: $0, chosen: nil).contains(.standard) },
              "p5 Standard, p3/p4 Classic, JPEG As Shot, Update keeps Classic, Standard listed")

        // Saturation: HSV's S only. Red, green, blue, orange, teal (moderate colour), on Standard.
        let colours: [SIMD3<Float>] = [SIMD3(0.30, 0.08, 0.06), SIMD3(0.07, 0.22, 0.05), SIMD3(0.06, 0.09, 0.30), SIMD3(0.35, 0.16, 0.04), SIMD3(0.04, 0.18, 0.17)]
        func run(_ change: (inout PhotoAdjustments) -> Void) -> [SIMD3<Double>] { var a = PhotoAdjustments(); change(&a); return graded(colours, a) }
        let plain = run { _ in }, more = run { $0.saturation = 50 }, grey = run { $0.saturation = -100 }
        let keptMax = zip(plain, more).map { abs($1.max() - $0.max()) / $0.max() }.max() ?? 1
        let lowered = zip(plain, more).map { $0.min() - $1.min() }.min() ?? 0
        check("saturation keeps each colour's brightest channel", keptMax < 0.02 && lowered > 0.01,
              String(format: "brightest channel within %.4f (under 0.02, relative), the darkest lowered by at least %.3f (over 0.01)", keptMax, lowered))
        let spread = grey.map { $0.max() - $0.min() }.max() ?? 1, atV = zip(plain, grey).map { abs($1.max() - $0.max()) }.max() ?? 1
        check("saturation -100 is grey", spread < 0.004 && atV < 0.01, String(format: "channels within %.4f, at the colour's brightest within %.4f", spread, atV))
        let twice = zip(plain, run { $0.saturation = 100 }).map { hsvS($1) / hsvS($0) }
        check("saturation +100 is about twice", twice.allSatisfy { $0 > 1.4 && $0 < 2.05 }, "S ratio \(twice.map { String(format: "%.2f", $0) })")

        // Vibrance: quiet colours raised more than strong ones; skin less than another colour as quiet.
        let quiet: [SIMD3<Float>] = [SIMD3(0.20, 0.17, 0.14), SIMD3(0.30, 0.06, 0.04), SIMD3(0.14, 0.17, 0.20), SIMD3(0.24, 0.20, 0.17)]
        func vib(_ v: Double) -> [SIMD3<Double>] { var a = PhotoAdjustments(); a.vibrance = v; return graded(quiet, a) }
        let v0 = vib(0), v60 = vib(60), gain = zip(v0, v60).map { hsvS($1) / max(hsvS($0), 1e-6) }
        check("vibrance raises quiet colour more than strong", gain[0] > gain[1] + 0.15 && gain[2] > 1.3,
              "S ratio quiet warm \(String(format: "%.2f", gain[0])), strong red \(String(format: "%.2f", gain[1])), quiet blue \(String(format: "%.2f", gain[2]))")
        check("vibrance changes skin less", gain[3] < gain[2] - 0.1, String(format: "skin ×%.2f against a quiet blue ×%.2f", gain[3], gain[2]))

        // Standard's colour change is smooth: along the hue circle (1° steps, a mid-light colour), its hue turn and chroma scale
        // move little from one degree to the next (no seams); and its table is finite.
        var turn = 0.0, scale = 0.0, last: (Double, Double)?
        for step in 0...360 {
            let h = Double(step) * .pi / 180, (r, g, b) = OkLab.to(0.6, 0.1 * cos(h), 0.1 * sin(h))
            let s = ColourProfiles.mul(PhotoEngine.fromProPhoto, ColourProfiles.standard5(ColourProfiles.mul(PhotoEngine.toProPhoto, SIMD3(r, g, b))))
            let (_, a2, b2) = OkLab.from(s.x, s.y, s.z)
            var dh = atan2(b2, a2) - h; dh = atan2(sin(dh), cos(dh))
            let now = (dh * 180 / .pi, (a2 * a2 + b2 * b2).squareRoot() / 0.1)
            if let last { turn = max(turn, abs(now.0 - last.0)); scale = max(scale, abs(now.1 / last.1 - 1)) }
            last = now
        }
        let finite = ColourProfiles.table(ColourProfiles.standard5).allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.y > 0 }
        check("standard table smooth", turn < 0.6 && scale < 0.015 && finite,
              String(format: "per degree of hue: turn changes at most %.2f° (under 0.6), chroma scale %.2f%% (under 1.5%%); table finite", turn, scale * 100))

        // No snap to grey near white: saturated green and blue brightening into white lose their colour gradually.
        var snap = 0.0
        for base in [SIMD3<Float>(0.05, 0.4, 0.06), SIMD3<Float>(0.05, 0.1, 0.45)] {
            let steps = (0..<40).map { base * Float(pow(1.1, Double($0))) }
            var a = PhotoAdjustments(); a.profile = .standard
            let out = graded(steps, a).map { e -> (L: Double, C: Double) in
                let l = SIMD3(e.x.sign == .minus ? -pow(-e.x, 2.4) : pow(e.x, 2.4), pow(max(e.y, 0), 2.4), pow(max(e.z, 0), 2.4))
                let s = SIMD3(1.6604910 * l.x - 0.5876411 * l.y - 0.0728499 * l.z, -0.1245505 * l.x + 1.1328999 * l.y - 0.0083494 * l.z,
                              -0.0181508 * l.x - 0.1005789 * l.y + 1.1187297 * l.z)
                let (L, aa, bb) = OkLab.from(s.x, s.y, s.z)
                return (L, (aa * aa + bb * bb).squareRoot())
            }
            for k in 1..<out.count where out[k].L < 0.97 && out[k - 1].C > 0.02 { snap = max(snap, 1 - out[k].C / out[k - 1].C) }
        }
        check("standard no grey snap near white", snap < 0.25, String(format: "largest drop in colour between neighbouring steps %.0f%% (under 25%%)", snap * 100))

        // +5 EV and film: sane numbers.
        var bright = PhotoAdjustments(); bright.exposure = 5; bright.saturation = 60; bright.vibrance = 60
        let hot = graded(colours, bright)
        var filmLight = PhotoAdjustments(); filmLight.saturation = 40
        let scene = gradePixels(PhotoEngine.develop(CIImage(color: CIColor(red: 0.3, green: 0.1, blue: 0.05)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8)),
                                                    filmLight, isRaw: true, asShotKelvin: 5500, scene: true))
        check("process 5 at +5 EV and with film", hot.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.max() <= 1.001 && $0.min() >= -0.2 }
              && scene.allSatisfy(\.isFinite), "finite, white at most; film light finite")

        await standardAgainstApple()
    }

    /// Standard's colour against Apple's default decode on the five reference RAWs, by OkLCh hue band (30°, Apple's hue): the
    /// middle 60% of the frame, colours with C over 0.05 (tinted greys follow the white balance, not the profile) and L 0.15–0.92, bands with at least 2% of those pixels.
    private static func standardAgainstApple() async {
        let raws = URL(fileURLWithPath: photos).deletingLastPathComponent().appendingPathComponent("shootout/raws")
        let names = ["DSC01962", "DSC01980", "DSC02817", "DSC02845", "DSC02868"]
        var rows: [String] = [], pooled = [[(Double, Double, Double)]](repeating: [], count: 12)
        for name in names {
            let path = raws.appendingPathComponent(name + ".ARW").path
            guard FileManager.default.fileExists(atPath: path), let raw = CIRAWFilter(imageURL: URL(fileURLWithPath: path)) else { continue }
            raw.scaleFactor = 0.25
            BaseCache.shared.removeAll(); GuideCache.shared.removeAll()
            let record = PhotoRecord()
            guard let apple = raw.outputImage, let decoded = PhotoRender.decoded(path, maxSize: 1500, record: record) else { continue }
            let ours = PhotoRender.output(PhotoRender.adjusted(decoded, record.adjust, path: path), record.adjust, p3: false)
            let oe = ours.extent.integral, ae = apple.extent
            let edge = max(2, (max(ae.width, ae.height) * 0.004).rounded(.up)), inner = ae.insetBy(dx: edge, dy: edge)
            let fitted = apple.cropped(to: inner).transformed(by: CGAffineTransform(translationX: -inner.minX, y: -inner.minY))
                .applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": oe.height / inner.height, "inputAspectRatio": (oe.width / inner.width) / (oe.height / inner.height)])
                .cropped(to: CGRect(origin: .zero, size: oe.size)).transformed(by: CGAffineTransform(translationX: oe.minX, y: oe.minY))
            let a = gradePixels(fitted), b = gradePixels(ours.cropped(to: oe))
            let W = Int(oe.width), H = Int(oe.height)
            var bands = [[(Double, Double, Double)]](repeating: [], count: 12), total = 0
            for y in stride(from: 0, to: H, by: 2) { for x in stride(from: 0, to: W, by: 2) {
                let r = hypot(Double(x) - Double(W) / 2, Double(y) - Double(H) / 2) / hypot(Double(W) / 2, Double(H) / 2)
                guard r < 0.6 else { continue }
                let i = (y * W + x) * 4
                let (La, aa, ba) = OkLab.from(Double(a[i]), Double(a[i + 1]), Double(a[i + 2]))
                let (_, ab, bb) = OkLab.from(Double(b[i]), Double(b[i + 1]), Double(b[i + 2]))
                let Ca = (aa * aa + ba * ba).squareRoot()
                guard Ca > 0.05, La > 0.15, La < 0.92 else { continue }
                var ha = atan2(ba, aa) * 180 / .pi; if ha < 0 { ha += 360 }
                var dh = (atan2(bb, ab) - atan2(ba, aa)) * 180 / .pi
                if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
                bands[min(Int(ha / 30), 11)].append((Ca, (ab * ab + bb * bb).squareRoot(), dh)); total += 1
            } }
            func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
            var row = name
            for (k, band) in bands.enumerated() where band.count >= max(200, total / 50) {
                let ratio = median(band.map(\.1)) / max(median(band.map(\.0)), 1e-6), hue = median(band.map(\.2))
                row += String(format: " %d°: ×%.2f %+.1f°", k * 30, ratio, hue)
                pooled[k] += band
            }
            rows.append(row)
        }
        guard !rows.isEmpty else { skip("standard like apple's default", "no shootout RAWs"); return }
        note("standard against apple default, per photo (band: chroma, hue): " + rows.joined(separator: "; "))
        // (One table for every photo can't follow each photo's own difference from Apple: the bands are pooled over the five.)
        var worstHue = 0.0, worstChroma = 0.0, all = ""
        func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        for (k, band) in pooled.enumerated() where band.count >= 2000 {
            let ratio = median(band.map(\.1)) / max(median(band.map(\.0)), 1e-6), hue = median(band.map(\.2))
            worstHue = max(worstHue, abs(hue)); worstChroma = max(worstChroma, abs(ratio - 1))
            all += String(format: " %d°: ×%.2f %+.1f°", k * 30, ratio, hue)
        }
        check("standard like apple's default", worstHue <= 3.5 && worstChroma <= 0.10,
              String(format: "pooled per hue band, hue within %.1f° (at most 3.5), chroma within %.0f%% (at most 10%%):", worstHue, worstChroma * 100) + all)
    }

    /// Measurement only (PluckScreenshotOnly "grade"): into <photos>/../gf/dump, 16-bit sRGB TIFFs: process 5's Standard on the
    /// five reference RAWs (full size), Accurate and Classic on two, Apple's default on those two, and Saturation and Vibrance
    /// on process 4 (old) and 5 (new), Classic, at 1500 px.
    static func gradeDump() async {
        let base = URL(fileURLWithPath: photos).deletingLastPathComponent()
        let raws = base.appendingPathComponent("shootout/raws"), out = base.appendingPathComponent("gf/dump")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        func save(_ image: CIImage, _ name: String) {
            let e = image.extent.integral
            let placed = image.cropped(to: e).transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            guard let cg = PhotoEngine.context.createCGImage(placed, from: placed.extent, format: .RGBA16, colorSpace: srgb),
                  let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name + ".tif") as CFURL, UTType.tiff.identifier as CFString, 1, nil)
            else { check("grade dump \(name)", false, "no picture"); return }
            CGImageDestinationAddImage(dest, cg, nil)
            check("grade dump \(name)", CGImageDestinationFinalize(dest), "write")
        }
        func render(_ path: String, _ size: Int, _ change: (inout PhotoAdjustments) -> Void) -> CIImage? {
            var record = PhotoRecord(); change(&record.adjust)
            BaseCache.shared.removeAll(); GuideCache.shared.removeAll()
            return PhotoRender.decoded(path, maxSize: size, record: record).map { PhotoRender.output(PhotoRender.adjusted($0, record.adjust, path: path), record.adjust, p3: false) }
        }
        for name in ["DSC01962", "DSC01980", "DSC02817", "DSC02845", "DSC02868", "DSC01994"] {
            let path = raws.appendingPathComponent(name + ".ARW").path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if let image = render(path, 0, { _ in }) { save(image, "\(name)-std5") }
            guard ["DSC01962", "DSC02845"].contains(name) else { continue }
            for (tag, profile) in [("acc5", PhotoEngine.Profile.accurate), ("classic5", .adobe), ("std4", .standard)] {
                if let image = render(path, 1500, { $0.profile = profile; if tag == "std4" { $0.process = 4 } }) { save(image, "\(name)-\(tag)-1500") }
            }
            if let image = render(path, 1500, { _ in }) { save(image, "\(name)-std5-1500") }
            if let raw = CIRAWFilter(imageURL: URL(fileURLWithPath: path)) { raw.scaleFactor = 0.25; if let a = raw.outputImage { save(a, "\(name)-apple-1500") } }
            for process in [4, 5] {
                for (tag, sat, vib) in [("s-50", -50.0, 0.0), ("s0", 0, 0), ("s50", 50, 0), ("s100", 100, 0), ("v50", 0, 50), ("v100", 0, 100)] {
                    if let image = render(path, 1500, { $0.process = process; $0.profile = .adobe; $0.saturation = sat; $0.vibrance = vib }) {
                        save(image, "\(name)-p\(process)-\(tag)")
                    }
                }
            }
        }
    }
}
