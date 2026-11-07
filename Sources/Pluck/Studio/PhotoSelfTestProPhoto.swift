import CoreImage
import simd

/// Version 3: linear ProPhoto as the working space, gamut mapping only at the screen or file, Classic the RAW default,
/// Adobe's mid grey, and old edits as they were.
extension PhotoSelfTest {
    nonisolated(unsafe) private static let linearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    /// An 8×8 patch of one colour, given in `space`.
    private static func patch(_ c: SIMD3<Float>, space: CGColorSpace = linearSRGB) -> CIImage {
        var pixels = [Float](repeating: 1, count: 64 * 4)
        for i in 0..<64 { pixels[i * 4] = c.x; pixels[i * 4 + 1] = c.y; pixels[i * 4 + 2] = c.z }
        return CIImage(bitmapData: pixels.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: 8 * 16, size: CGSize(width: 8, height: 8),
                       format: .RGBAf, colorSpace: space)
    }

    /// The middle pixel, in `space`.
    private static func middle(_ image: CIImage, space: CGColorSpace = linearSRGB) -> SIMD3<Float> {
        var px = [Float](repeating: 0, count: 4)
        px.withUnsafeMutableBytes {
            PhotoEngine.context.render(image, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: image.extent.midX, y: image.extent.midY, width: 1, height: 1),
                                       format: .RGBAf, colorSpace: space)
        }
        return SIMD3(px[0], px[1], px[2])
    }

    private static func lch(_ c: SIMD3<Float>) -> (L: Double, C: Double, h: Double) {
        let (L, a, b) = OkLab.from(Double(c.x), Double(c.y), Double(c.z))
        var h = atan2(b, a) * 180 / .pi
        if h < 0 { h += 360 }
        return (L, (a * a + b * b).squareRoot(), h)
    }

    static func proPhoto() async {
        let p3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        func version(_ n: Int, _ change: (inout PhotoAdjustments) -> Void = { _ in }) -> PhotoAdjustments {
            var a = PhotoAdjustments(); a.process = n; change(&a); return a
        }

        // A green well inside Display P3 but past sRGB (a phone's photo): version 3 keeps it to the P3 file; version 2's sRGB
        // working space clips it.
        let green = SIMD3<Float>(0.05, 0.5, 0.05)
        func shown(_ a: PhotoAdjustments) -> SIMD3<Float> {
            middle(PhotoRender.output(PhotoRender.adjusted(patch(green, space: p3), a, isRaw: false, kelvin: 6500), a, p3: true), space: p3)
        }
        let wide = shown(version(3)), old = shown(version(2))
        let off = { (c: SIMD3<Float>) in max(abs(c.x - green.x), abs(c.y - green.y), abs(c.z - green.z)) }
        check("prophoto keeps a colour past srgb", off(wide) < 0.004 && off(old) > 0.02,
              "version 3 within 0.004 of \(green) in P3, version 2 clipped (over 0.02); got \(wide), \(old)")
        // The grid's copy and the looks' pictures of a P3 screen's picture keep that colour (in sRGB they clipped it).
        let onScreen = PhotoRender.output(PhotoRender.adjusted(patch(green, space: p3), version(3), isRaw: false, kelvin: 6500), version(3), p3: true)
        let pictured = PhotoRender.picture(onScreen, space: CGColorSpace(name: CGColorSpace.displayP3)).map { middle(CIImage(cgImage: $0), space: p3) }
        let inSRGB = PhotoRender.picture(onScreen).map { middle(CIImage(cgImage: $0), space: p3) }
        check("pictures keep p3 colours", pictured.map(off).map { $0 < 0.01 } == true && inSRGB.map(off).map { $0 > 0.02 } == true,
              "a P3 picture within 0.01 of \(green), an sRGB one clipped; got \(String(describing: pictured)), \(String(describing: inSRGB))")

        // Very saturated light (as far out as ProPhoto) mapped into sRGB: inside, its OkLCh hue and lightness kept; a colour
        // well inside sRGB passes untouched.
        let far = PhotoEngine.fromProPhoto, pro = SIMD3<Double>(0.04, 0.55, 0.03)
        let deep = SIMD3<Float>(Float(far[0] * pro.x + far[1] * pro.y + far[2] * pro.z), Float(far[3] * pro.x + far[4] * pro.y + far[5] * pro.z),
                                Float(far[6] * pro.x + far[7] * pro.y + far[8] * pro.z))
        let mapped = middle(PhotoEngine.gamutMapped(patch(deep), p3: false))
        let (before, after) = (lch(deep), lch(mapped))
        let dh = abs(before.h - after.h).truncatingRemainder(dividingBy: 360)
        let inside = mapped.min() >= -1e-3 && mapped.max() <= 1.001
        check("gamut mapping keeps hue", inside && min(dh, 360 - dh) < 2 && abs(before.L - after.L) < 0.01,
              "inside sRGB, hue within 2° of \(before.h), lightness within 0.01 of \(before.L); got \(mapped): \(after)")
        let plain = SIMD3<Float>(0.3, 0.2, 0.1), kept = middle(PhotoEngine.gamutMapped(patch(plain), p3: false))
        check("gamut mapping leaves what fits", max(abs(kept.x - plain.x), abs(kept.y - plain.y), abs(kept.z - plain.z)) < 1e-3, "\(plain); got \(kept)")
        // Clipped the hard way the hue moves; mapped it doesn't.
        let clipped = lch(simd_clamp(deep, .zero, .one)).h
        check("gamut mapping isn't a clip", abs(clipped - before.h) > 3 * min(dh, 360 - dh) + 1, "hard clip's hue \(clipped) further off than \(after.h)")

        // An edit saved by version 2 (no profile, so Neutral then) keeps its version, profile, mid grey and colours.
        let json = #"{"exposure":0.5,"shadows":20,"process":2}"#
        let saved = try? JSONDecoder().decode(PhotoAdjustments.self, from: Data(json.utf8))
        let colours: [SIMD3<Float>] = [SIMD3(0.18, 0.18, 0.18), SIMD3(0.4, 0.05, 0.03), SIMD3(-0.05, 0.3, 0.02), SIMD3(0.02, 0.03, 0.005)]
        if let saved {
            var neutral = saved
            neutral.profile = .neutral
            let same = colours.allSatisfy { c in
                let image = PhotoRender.adjusted(patch(c), saved, isRaw: true, kelvin: 5500)
                // (No gamut mapping for it: the very image goes out.)
                return PhotoRender.output(image, saved, p3: true) === image
                    && middle(image) == middle(PhotoRender.adjusted(patch(c), neutral, isRaw: true, kelvin: 5500))
            }
            var now = saved
            now.process = 3
            let moved = middle(PhotoRender.adjusted(patch(colours[0]), now, isRaw: true, kelvin: 5500)) != middle(PhotoRender.adjusted(patch(colours[0]), saved, isRaw: true, kelvin: 5500))
            check("old record keeps its look", saved.process == 2 && PhotoEngine.Profile.starting(saved, isRaw: true) == .neutral && same && moved,
                  "version 2, Neutral, its own pixels and no gamut mapping (and version 3 differs); got \(saved.process)")
            // Update moves it to the current engine but keeps Neutral (it would start at Classic, a stop brighter); a JPEG's stays none.
            let raw = saved.updated(isRaw: true), jpeg = saved.updated(isRaw: false)
            check("update keeps the profile", raw.process == PhotoAdjustments.currentProcess && PhotoEngine.Profile.starting(raw, isRaw: true) == .neutral
                  && jpeg.process == PhotoAdjustments.currentProcess && jpeg.profile == nil,
                  "current engine, RAW still Neutral, JPEG no profile; got \(raw.process) \(String(describing: raw.profile)), \(String(describing: jpeg.profile))")
        } else {
            check("old record keeps its look", false, "didn't decode")
        }

        // Standard starts a new RAW (process 5; a Lightroom preset or sidecar naming an Adobe profile starts Classic); a JPEG starts As Shot.
        let fresh = PhotoAdjustments(), untouched = try? JSONDecoder().decode(PhotoAdjustments.self, from: Data("{}".utf8))
        let preset = LightroomPresets.adjustments(["Exposure2012": "+1.00", "CameraProfile": "Adobe Standard"], base: saved ?? fresh).0
        let standard = version(PhotoAdjustments.currentProcess) { $0.profile = .standard }
        let sameAsStandard = colours.allSatisfy { middle(PhotoRender.adjusted(patch($0), fresh, isRaw: true, kelvin: 5500))
            == middle(PhotoRender.adjusted(patch($0), standard, isRaw: true, kelvin: 5500)) }
        check("standard is the default for new raws",
              PhotoEngine.Profile.starting(fresh, isRaw: true) == .standard && untouched.map { PhotoEngine.Profile.starting($0, isRaw: true) } == .standard
                && PhotoEngine.Profile.starting(fresh, isRaw: false) == .asShot && preset.process == PhotoAdjustments.currentProcess
                && PhotoEngine.Profile.starting(preset, isRaw: true) == .adobe && sameAsStandard,
              "Standard for a new or untouched RAW, rendered as Standard; Classic after a Lightroom preset naming Adobe's; As Shot for a JPEG")

        // Classic's mid grey is Adobe's (0.7 stop over Neutral's) only from version 3.
        func grey(_ a: PhotoAdjustments) -> Float { middle(PhotoRender.adjusted(patch(SIMD3(repeating: 0.18)), a, isRaw: true, kelvin: 5500)).y }
        let neutralGrey = grey(version(3) { $0.profile = .neutral }), oldClassic = grey(version(2) { $0.profile = .adobe }), newClassic = grey(version(3) { $0.profile = .adobe })
        check("classic has adobe's mid grey from version 3", abs(oldClassic / grey(version(2) { $0.profile = .neutral }) - 1) < 0.02 && newClassic > neutralGrey * 1.2,
              "version 2 Classic at Neutral's grey, version 3 brighter; got \(oldClassic), \(newClassic) against \(neutralGrey)")

        baselineOnlyNew()
        await lightroomMidGrey()
    }

    /// The real photo (kept outside the repo) at Lightroom's settings matches Lightroom's screenshot of it within 0.2 stop, in
    /// the upper midtones Shadows and Highlights touch least (the cabinet's top and the lawn through the window).
    private static func lightroomMidGrey() async {
        let folder = URL(fileURLWithPath: photos).deletingLastPathComponent().appendingPathComponent("greencast")
        let raw = folder.appendingPathComponent("DSC01962.ARW").path, shot = folder.appendingPathComponent("5.webp")
        guard FileManager.default.fileExists(atPath: raw), let screenshot = CIImage(contentsOf: shot) else {
            skip("lightroom numbers give lightroom's mid grey", "no DSC01962.ARW or 5.webp"); return
        }
        check("baseline exposure read", abs(PhotoRender.baselineExposure(raw) - 0.35) < 0.01, "0.35; got \(PhotoRender.baselineExposure(raw))")
        // The photo in the screenshot (Lightroom's window around it, 1350 × 900 from 320, 72), from the bottom left.
        let lightroom = screenshot.cropped(to: CGRect(x: 320, y: screenshot.extent.height - 972, width: 1350, height: 900))
        // Average brightness (log) of the patches, as shares from the top left.
        func level(_ image: CIImage) -> Double {
            let e = image.extent
            // (The lawn and the cabinet's top. Not the curtain: Lightroom darkens that large bright place on its own, 0.4 stop
            // under Pluck's even at Highlights 0, while the rest as bright matches; once it hid the lawn's −0.18.)
            let patches = [CGRect(x: 0.27, y: 0.41, width: 0.15, height: 0.03), CGRect(x: 0.73, y: 0.42, width: 0.10, height: 0.10)]
            return patches.map { p in
                let r = CGRect(x: e.minX + p.minX * e.width, y: e.maxY - p.maxY * e.height, width: p.width * e.width, height: p.height * e.height)
                let c = middle(image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: r)]).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1)))
                return log2(max(Double(0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z), 1e-6))
            }.reduce(0, +) / Double(patches.count)
        }
        let target = level(lightroom)
        var record = PhotoRecord()
        // (Process 3: process 4's Classic sits at Apple's default brightness instead, about half a stop under Lightroom's here.)
        record.adjust.process = 3
        record.adjust.highlights = -100; record.adjust.shadows = 100; record.adjust.sharpen = 40
        func at(_ exposure: Double) -> Double? {
            record.adjust.exposure = exposure
            BaseCache.shared.removeAll(); GuideCache.shared.removeAll()
            return PhotoRender.image(raw, record: record, maxSize: 1500).map(level)
        }
        guard let low = at(2.05), let mid = at(2.25), let high = at(2.45) else { check("lightroom numbers give lightroom's mid grey", false, "not rendered"); return }
        // (Stops on the picture per stop of Exposure, from the two either side.)
        let off = (target - mid) / max((high - low) / 0.4, 0.05)
        check("lightroom numbers give lightroom's mid grey", abs(off) <= 0.2,
              "Lightroom +2.25 within 0.2 stop of Pluck +2.25 (Classic, Highlights −100, Shadows +100); off by \(String(format: "%+.2f", off)) stop")
    }

    /// The camera's baseline exposure goes on top of the decoder's for version 3 RAW only.
    static func baselineOnlyNew() {
        func grey(_ process: Int, raw: Bool, baseline: Double) -> Float {
            var a = PhotoAdjustments(); a.process = process
            return middle(PhotoRender.adjusted(patch(SIMD3(repeating: 0.18)), a, isRaw: raw, kelvin: 5500, baseline: baseline)).y
        }
        let new = grey(3, raw: true, baseline: 0.35) / grey(3, raw: true, baseline: 0)
        let old = grey(2, raw: true, baseline: 0.35) / grey(2, raw: true, baseline: 0), jpeg = grey(3, raw: false, baseline: 0.35) / grey(3, raw: false, baseline: 0)
        check("baseline exposure for new raws only", new > 1.1 && old == 1 && jpeg == 1, "version 3 RAW brighter, version 2 and JPEG the same; got \(new), \(old), \(jpeg)")
    }
}
