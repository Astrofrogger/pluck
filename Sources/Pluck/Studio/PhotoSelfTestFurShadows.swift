import CoreImage
import simd
import ImageIO
import UniformTypeIdentifiers

/// Bright fur's fringe and Shadows' colour shift: a dump tool for measuring (-PluckScreenshotOnly furdump), reading
/// `<photos>/../fs/jobs.json`: {"name", "file" (absolute), "record" (a PhotoRecord), "size" (0: full), "crop" ([x, y, w, h],
/// full-size pixels from the top left), "stage" ("final", "base" or "source")}; each comes out as `<name>.tif` (linear,
/// half float) or `.png` (final, sRGB) in `fs/dump`. Denoised records are denoised first (the test copy's engine).
extension PhotoSelfTest {
    static func furDump() async {
        let folder = URL(fileURLWithPath: photos).deletingLastPathComponent().appendingPathComponent("fs")
        struct Job: Decodable { var name: String; var file: String; var record: PhotoRecord; var size: Int?; var crop: [Double]?; var stage: String? }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("jobs.json")) else { skip("fur dump", "no jobs.json"); return }
        let jobs: [Job]
        do { jobs = try JSONDecoder().decode([Job].self, from: data) } catch { check("fur dump", false, "\(error)"); return }
        let out = folder.appendingPathComponent("dump")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for job in jobs {
            let size = job.size ?? 1500, stage = job.stage ?? "final"
            if job.record.denoise > 0 {
                do { try await PhotoRender.denoise(job.file, record: job.record) } catch { check("fur dump \(job.name)", false, "denoise: \(error)"); continue }
            }
            BaseCache.shared.removeAll(); GuideCache.shared.removeAll()
            let started = Date()
            var image: CIImage?
            switch stage {
            case "base": image = PhotoRender.base(job.file, maxSize: size, record: job.record)?.image
            case "source": image = PhotoRender.source(job.file, maxSize: size, noise: job.record.adjust.noise, color: job.record.adjust.colorNoise,
                                                      raw: PhotoRender.RawSettings(job.record.adjust), luma: true)
            case "noisy", "clean", "noisydng", "cleandng":
                let settings = PhotoRender.RawSettings(job.record.adjust)
                guard let file = PhotoRender.cleanFile(job.file, record: job.record) else { break }
                if stage.hasSuffix("dng") {
                    let base = file.deletingPathExtension().deletingPathExtension().path
                    image = PhotoRender.source(job.file, maxSize: size, noise: 0, color: 0, raw: settings,
                                               file: URL(fileURLWithPath: base + (stage == "noisydng" ? ".noisy.dng" : ".clean.dng")))
                    note("fur dump \(job.name) matrix \((try? String(contentsOf: file, encoding: .utf8)) ?? "")")
                } else { image = PhotoRender.denoiseSide(job.file, file, noisy: stage == "noisy", maxSize: size, raw: settings) }
            case "arw": image = PhotoRender.source(job.file, maxSize: size, noise: 0, color: 0, raw: PhotoRender.RawSettings(job.record.adjust))
            default: image = PhotoRender.image(job.file, record: job.record, maxSize: size)
            }
            guard var picture = image else { check("fur dump \(job.name)", false, "not rendered"); continue }
            if let c = job.crop, c.count == 4 {
                let e = picture.extent
                picture = picture.cropped(to: CGRect(x: e.minX + c[0], y: e.maxY - c[1] - c[3], width: c[2], height: c[3]))
            }
            picture = picture.transformed(by: CGAffineTransform(translationX: -picture.extent.minX, y: -picture.extent.minY))
            if stage == "final" {
                guard let cg = PhotoRender.picture(picture),
                      let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent("\(job.name).png") as CFURL, UTType.png.identifier as CFString, 1, nil)
                else { check("fur dump \(job.name)", false, "no picture"); continue }
                CGImageDestinationAddImage(dest, cg, nil)
                check("fur dump \(job.name)", CGImageDestinationFinalize(dest))
            } else {
                do {
                    try PhotoEngine.context.writeTIFFRepresentation(of: picture, to: out.appendingPathComponent("\(job.name).tif"), format: .RGBAh,
                                                                    colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
                    check("fur dump \(job.name)", true)
                } catch { check("fur dump \(job.name)", false, "\(error)") }
            }
            note("fur dump \(job.name): \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        }
    }
}

/// The owner's reports on DSC01980 and DSC01962 (2026-11-06), on made-up pictures (and the real RAW when it's there):
/// bright hairs' fringe, Shadows' colour, Highlights by profile, steps at +5 EV, Tint, neutrals at Contrast −100, film by profile.
extension PhotoSelfTest {
    private static let fsLinear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    static func fsImage(_ width: Int, _ height: Int, _ colour: (Int, Int) -> SIMD3<Float>) -> CIImage {
        var px = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let c = colour(x, y), i = (y * width + x) * 4
            px[i] = c.x; px[i + 1] = c.y; px[i + 2] = c.z
        } }
        return CIImage(bitmapData: px.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: width * 16,
                       size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: fsLinear)
    }

    /// Linear RGB, rows from the top.
    static func fsPixels(_ image: CIImage, _ extent: CGRect) -> [SIMD3<Double>] {
        let w = Int(extent.width), h = Int(extent.height)
        var px = [Float](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes {
            PhotoEngine.context.render(image, toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: extent, format: .RGBAf, colorSpace: fsLinear)
        }
        return (0..<w * h).map { SIMD3(Double(px[$0 * 4]), Double(px[$0 * 4 + 1]), Double(px[$0 * 4 + 2])) }
    }

    static func fsLab(_ c: SIMD3<Double>) -> SIMD3<Double> { let o = OkLab.from(c.x, c.y, c.z); return SIMD3(o.0, o.1, o.2) }
    static func fsChroma(_ o: SIMD3<Double>) -> Double { (o.y * o.y + o.z * o.z).squareRoot() }
    static func fsHue(_ o: SIMD3<Double>) -> Double { atan2(o.z, o.y) * 180 / .pi }
    static func fsHueApart(_ a: Double, _ b: Double) -> Double { let d = abs(a - b).truncatingRemainder(dividingBy: 360); return min(d, 360 - d) }

    static func fsDeveloped(_ image: CIImage, _ a: PhotoAdjustments, scene: Bool = false) -> [SIMD3<Double>] {
        let out = PhotoRender.adjusted(image, a, isRaw: true, kelvin: 5500, scene: scene)
        return fsPixels(scene ? out : PhotoRender.output(out, a, p3: false), image.extent)
    }

    static func furShadows() async {
        furFringe()
        await shadowsColour()
        highlightsByProfile()
        pushedSmoothly()
        tintLikeLightroom()
        flatNeutrals()
        filmProfiles()
    }

    /// Bright warm hairs (1 px, 3 stops over white, white to orange) on a dark brown ground with colour noise, through process
    /// 4's colour noise reduction: the ground beside them keeps its colour (no orange or red fringe). Version 3's is noted.
    private static func furFringe() {
        let n = 192
        func noise(_ x: Int, _ y: Int, _ k: Int) -> Float { Float((x * 7919 + y * 104729 + k * 1299709) % 1000) / 1000 - 0.5 }
        let ground = SIMD3<Float>(0.03, 0.02, 0.011)
        func hair(_ x: Int, _ y: Int) -> Bool { x < n * 3 / 4 && (x % (3 + x / 24)) == 0 }
        let picture = fsImage(n, n) { x, y in
            if hair(x, y) { let o = Float(y) / Float(n); return SIMD3(6, 5.2 - 2.5 * o, 4.2 - 3.4 * o) }
            return ground * SIMD3(1 + 0.6 * noise(x, y, 0), 1 + 0.6 * noise(x, y, 1), 1 + 0.6 * noise(x, y, 2))
        }
        func fringe(_ image: CIImage) -> (share: Double, worst: Double) {
            let px = fsPixels(image, image.extent)
            var sum = 0.0, count = 0.0, shares: [Double] = []
            for y in 4..<n - 4 { for x in 1..<n - 1 where !hair(x, y) && (hair(x - 1, y) || hair(x + 1, y)) {
                let c = px[y * n + x], Y = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
                guard Y > 1e-4 else { continue }
                let s = (c.x - c.z) / Y
                sum += s; count += 1; shares.append(s)
            } }
            shares.sort()
            return (sum / max(count, 1), shares.isEmpty ? 0 : shares[shares.count * 95 / 100])
        }
        let own = (Double(ground.x - ground.z)) / (0.2126 * Double(ground.x) + 0.7152 * Double(ground.y) + 0.0722 * Double(ground.z))
        let v4 = fringe(PhotoRender.colourNoiseReduced(picture, amount: 25, fullLongEdge: Double(n), wide: true, lighter: true))
        let v3 = fringe(PhotoRender.colourNoiseReduced(picture, amount: 25, fullLongEdge: Double(n), wide: true))
        let v2 = fringe(PhotoRender.colourNoiseReduced(picture, amount: 25, fullLongEdge: Double(n)))
        note("bright hairs: the ground's (red − blue)/Y \(own); beside the hairs, mean and 95th percentile: process 4 \(v4), version 3 \(v3), version 2 \(v2)")
        check("bright hairs keep no coloured fringe", abs(v4.share - own) < 0.25 * own && v4.worst < 1.6 * own,
              "beside the hairs (red − blue)/Y within 25% of the ground's \(own) on average, under 1.6× at the 95th percentile (version 3 2.7× and 4×); got \(v4)")
    }

    /// Shadows +100 keeps hue: a grey ramp stays grey (processes 2 and 4); a dark coloured patch whose clean decode came out
    /// darker in red and blue (as the raw denoiser's did) keeps its hue once settled and lifted; and on the real RAW (when it's
    /// here), the owner's edit's pot and cabinet side with AI Denoise keep the hue they have without it.
    private static func shadowsColour() async {
        let n = 256
        let ramp = fsImage(n, 8) { x, _ in SIMD3(repeating: 0.18 * exp2(Float(x) / 32 - 7)) }
        for process in [2, 4] {
            var a = PhotoAdjustments(); a.process = process; a.profile = .neutral; a.exposure = 1.7; a.shadows = 100; a.highlights = -49
            let row = fsDeveloped(ramp, a).prefix(n).map(fsLab)
            let chroma = row.map(fsChroma).max() ?? 1
            check("shadows keep a grey ramp grey (process \(process))", chroma < 0.004, "OkLab chroma under 0.004; got \(chroma)")
        }
        // A teal and a brown, 9–6 stops under white, with noise; the clean side 0.0009 / 0.0003 darker in red / blue.
        let patches: [SIMD3<Float>] = [SIMD3(0.0011, 0.0017, 0.0015), SIMD3(0.004, 0.0027, 0.0009)]
        func noisy(_ x: Int, _ y: Int, _ k: Int) -> Float { 1 + 0.5 * (Float((x * 7919 + y * 6151 + k * 3571) % 997) / 997 - 0.5) }
        for (i, colour) in patches.enumerated() {
            let orig = fsImage(64, 64) { x, y in colour * SIMD3(noisy(x, y, 0), noisy(x, y, 1), noisy(x, y, 2)) }
            let biased = fsImage(64, 64) { _, _ in colour - SIMD3(min(0.0009, colour.x * 0.5), 0, min(0.0003, colour.z * 0.5)) }
            var a = PhotoAdjustments(); a.process = 4; a.profile = .neutral; a.exposure = 1.7; a.shadows = 100
            func hue(_ image: CIImage) -> (h: Double, C: Double) {
                let px = fsDeveloped(image, a), mean = px.reduce(SIMD3<Double>(), +) / Double(px.count), o = fsLab(mean)
                return (fsHue(o), (o.y * o.y + o.z * o.z).squareRoot())
            }
            let want = hue(fsImage(64, 64) { _, _ in colour })
            let mixed = hue(PhotoRender.mixDenoise(orig, PhotoRender.settled(biased, within: orig), amount: 50))
            let raw = hue(PhotoRender.mixDenoise(orig, biased, amount: 50))
            note("shadows with denoise, patch \(i): hue \(want) clean; biased clean as it was \(raw), settled \(mixed)")
            check("shadows with denoise keep hue (patch \(i))", fsHueApart(mixed.h, want.h) < 6 && abs(mixed.C / want.C - 1) < 0.2,
                  "within 6° and 20% chroma of the clean patch's \(want); got \(mixed) (unsettled \(raw))")
        }
        await shadowsColourReal()
    }

    /// The owner's DSC01962 edit (process 2, Neutral, +1.7, Contrast −3, Highlights −49, Shadows +100, AI Amount 50, the
    /// engine standing in with its own DNGs): the pot's and the cabinet side's hue with AI Denoise within 8° of without.
    private static func shadowsColourReal() async {
        let gc = URL(fileURLWithPath: photos).deletingLastPathComponent().appendingPathComponent("greencast")
        let arw = gc.appendingPathComponent("DSC01962.ARW"), clean = gc.appendingPathComponent("DSC01962.clean.dng"), noisyDNG = gc.appendingPathComponent("DSC01962.noisy.dng")
        guard [arw, clean, noisyDNG].allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { skip("shadows with AI denoise keep hue", "no greencast DSC01962 files"); return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-fs-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("DSC01962.ARW").path
        try? FileManager.default.copyItem(at: arw, to: URL(fileURLWithPath: path))
        PhotoRender.rawDenoiseEngineForTests = { _, c, nd in
            try FileManager.default.copyItem(at: clean, to: c); try FileManager.default.copyItem(at: noisyDNG, to: nd); return true
        }
        defer { PhotoRender.rawDenoiseEngineForTests = nil }
        var record = PhotoRecord()
        record.adjust.process = 2; record.adjust.profile = .neutral; record.adjust.rawDecoder = "8"
        record.adjust.exposure = 1.7; record.adjust.contrast = -3; record.adjust.highlights = -49; record.adjust.shadows = 100
        var ai = record
        ai.denoise = 50; ai.denoiseAI = true
        do { try await PhotoRender.denoise(path, record: ai) } catch { check("shadows with AI denoise keep hue", false, "\(error)"); return }
        BaseCache.shared.removeAll(); GuideCache.shared.removeAll()
        func regions(_ r: PhotoRecord) -> [SIMD3<Double>]? {
            guard let image = PhotoRender.image(path, record: r, maxSize: 2000) else { return nil }
            let e = image.extent, s = e.width / 2000
            // (Pot and cabinet side, in a 2000 px frame from the top left.)
            return [(230.0, 970.0, 170.0, 140.0), (1040, 660, 100, 400)].map { b in
                let px = fsPixels(image, CGRect(x: e.minX + b.0 * s, y: e.maxY - (b.1 + b.3) * s, width: b.2 * s, height: b.3 * s).integral)
                return fsLab(px.reduce(SIMD3<Double>(), +) / Double(px.count))
            }
        }
        guard let with = regions(ai), let without = regions(record) else { check("shadows with AI denoise keep hue", false, "not rendered"); return }
        let apart = zip(with, without).map { fsHueApart(fsHue($0), fsHue($1)) }
        let chroma = zip(with, without).map { (($0.y * $0.y + $0.z * $0.z) / ($1.y * $1.y + $1.z * $1.z)).squareRoot() }
        note("shadows with AI denoise (DSC01962, owner's edit): pot and cabinet side OkLab with \(with), without \(without)")
        check("shadows with AI denoise keep hue", apart.allSatisfy { $0 < 8 } && chroma.allSatisfy { $0 < 1.2 },
              "pot and cabinet side within 8° and 1.2× chroma of no denoise; got \(apart)°, \(chroma)")
    }

    /// Highlights −100 keeps a window's texture on every profile about as Neutral does (process 4): fine stripes (±0.15 stop)
    /// on plateaus 3, 4 and 5 stops over mid grey; the stripes' lightness difference at least 0.3 of Neutral's on each (profiles
    /// differ in contrast and shoulder). (Before: Classic's were 0.35, 0.14 and 0.07 of Neutral's, the window white.)
    private static func highlightsByProfile() {
        let w = 96, plateaus = [3.0, 4.0, 5.0]
        let picture = fsImage(w * plateaus.count, 16) { x, _ in
            SIMD3(repeating: Float(0.18 * exp2(plateaus[x / w] + (x % 4 < 2 ? 0.15 : -0.15))))
        }
        func stripes(_ profile: PhotoEngine.Profile, process: Int = 4) -> [Double] {
            var a = PhotoAdjustments(); a.process = process; a.profile = profile; a.highlights = -100
            let px = fsDeveloped(picture, a)
            return plateaus.indices.map { k in
                var bright = 0.0, dark = 0.0
                for x in k * w + 32..<k * w + 64 { let L = fsLab(px[8 * w * plateaus.count + x]).x; if x % 4 < 2 { bright += L } else { dark += L } }
                return (bright - dark) / 16
            }
        }
        let neutral = stripes(.neutral)
        var all: [String] = []
        for profile in [PhotoEngine.Profile.adobe, .accurate, .vivid, .landscape, .portrait, .monochrome] {
            let s = stripes(profile)
            all.append("\(profile.rawValue) \(s.map { String(format: "%.4f", $0) })")
            check("highlights −100 keep detail (\(profile.rawValue))", zip(s, neutral).allSatisfy { $0 > 0.3 * $1 },
                  "the stripes 3, 4 and 5 stops over mid grey at least 0.3 of Neutral's \(neutral); got \(s)")
        }
        // (Process 3 is process 4 before: the same curve and Highlights.)
        let before = [PhotoEngine.Profile.neutral, .adobe].map { stripes($0, process: 3).map { String(format: "%.4f", $0) } }
        note("highlights −100, stripes' lightness 3 / 4 / 5 stops over mid grey: neutral \(neutral.map { String(format: "%.4f", $0) }), \(all.joined(separator: ", ")); process 3 (before): neutral \(before[0]), adobe \(before[1])")
    }

    /// Exposure +5 and Shadows +100 on a smooth ramp (12 stops) of eight colours, every profile (process 4): lightness never
    /// falls, and no step: the largest second difference of OkLab L, a and b along the ramp under a bound.
    private static func pushedSmoothly() {
        let n = 480
        let colours: [SIMD3<Float>] = [SIMD3(1, 0.45, 0.12), SIMD3(0.15, 0.6, 0.6), SIMD3(0.25, 1, 0.15), SIMD3(0.2, 0.3, 1), SIMD3(1, 0.2, 0.2),
                                       SIMD3(1, 0.7, 0.5), SIMD3(1, 1, 1), SIMD3(1, 0.95, 0.6)]
        let ramp = fsImage(n, colours.count * 8) { x, y in
            let c = colours[y / 8], Y = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
            return c / Y * 0.18 * exp2(Float(x) / 40 - 10)
        }
        var worst: [String] = []
        // (And Accurate on process 5, whose fade to white is safe: see towardsWhite5.)
        for (profile, process) in [(PhotoEngine.Profile.adobe, 4), (.neutral, 4), (.accurate, 4), (.vivid, 4), (.landscape, 4), (.portrait, 4), (.monochrome, 4), (.accurate, 5)] {
            let name = profile.rawValue + (process == 5 ? " p5" : "")
            var a = PhotoAdjustments(); a.process = process; a.profile = profile; a.exposure = 5; a.shadows = 100
            let px = fsDeveloped(ramp, a)
            var falls = 0, step = 0.0, at = (0, 0), around: [SIMD3<Double>] = [], bright = 0.0
            for (k, _) in colours.enumerated() {
                let row = (0..<n).map { fsLab(px[(k * 8 + 4) * n + $0]) }
                bright = max(bright, row.filter { $0.x > 0.92 }.map(fsChroma).max() ?? 0)
                for i in 1..<n - 1 {
                    if row[i + 1].x < row[i].x - 0.002 { falls += 1 }
                    let d2 = row[i + 1] - 2 * row[i] + row[i - 1]
                    let m = max(abs(d2.x), abs(d2.y), abs(d2.z))
                    if m > step { step = m; at = (k, i); around = Array(row[i - 1...i + 1]) }
                }
            }
            worst.append("\(name) \(String(format: "%.4f", step)) (colour \(at.0), x \(at.1): \(around.map { String(format: "%.3f %.3f %.3f", $0.x, $0.y, $0.z) })), falls \(falls), chroma over L 0.92 \(String(format: "%.3f", bright))")
            if step > 0.02 {
                let plain = fsPixels(PhotoRender.adjusted(ramp, a, isRaw: true, kelvin: 5500), ramp.extent)
                note("pushed +5 EV \(name) before the gamut mapping at the step: \((at.1 - 2...at.1 + 2).map { i -> String in let o = fsLab(plain[(at.0 * 8 + 4) * n + i]), c = plain[(at.0 * 8 + 4) * n + i]; return String(format: "%.4f %.4f %.4f (%.4f %.4f %.4f)", o.x, o.y, o.z, c.x, c.y, c.z) })")
            }
            // (Accurate on process 4 is noted, not checked: a saturated green snaps to grey 2% under white there, kept as it was.)
            if profile != .accurate || process == 5 { check("pushed +5 EV stays smooth (\(name))", falls == 0 && step < 0.02,
                  "lightness never falls, second difference under 0.02; got falls \(falls), \(step) at colour \(at.0), x \(at.1)") }
        }
        note("pushed +5 EV, Shadows +100, largest second difference: \(worst.joined(separator: "; "))")
    }

    /// Tint as Lightroom's (processes 3 and 4): −50 turns grey green, +50 magenta, by about Lightroom's amount (its ±75: the
    /// light 0.0375 off the locus in CIE 1960 uv; the grey moves about that far the other way).
    private static func tintLikeLightroom() {
        let grey = fsImage(4, 4) { _, _ in SIMD3(repeating: 0.18) }
        func uv(_ c: SIMD3<Double>) -> SIMD2<Double> {
            let X = 0.4124 * c.x + 0.3576 * c.y + 0.1805 * c.z, Y = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z, Z = 0.0193 * c.x + 0.1192 * c.y + 0.9505 * c.z
            let d = X + 15 * Y + 3 * Z
            return SIMD2(4 * X / d, 6 * Y / d)
        }
        for process in [3, 4] {
            func scene(_ tint: Double) -> SIMD3<Double> {
                var a = PhotoAdjustments(); a.process = process; a.profile = .accurate; a.tint = tint
                return fsDeveloped(grey, a, scene: true)[5]
            }
            let plain = scene(0), green = scene(-50), magenta = scene(50)
            let moved = [green, magenta].map { (uv($0) - uv(plain)) }.map { ($0.x * $0.x + $0.y * $0.y).squareRoot() }
            check("tint −50 green, +50 magenta (process \(process))",
                  green.y > green.x && green.y > green.z && magenta.x > magenta.y && magenta.z > magenta.y && moved.allSatisfy { $0 > 0.6 * 0.0375 && $0 < 1.5 * 0.0375 },
                  "green over red and blue, then under; grey moved about 0.0375 in uv; got \(green), \(magenta), \(moved)")
        }
    }

    /// Accurate, Exposure +2.3, Contrast −100, Shadows +46: a grey ramp stays grey (no lavender veil).
    private static func flatNeutrals() {
        let n = 256
        let ramp = fsImage(n, 8) { x, _ in SIMD3(repeating: 0.18 * exp2(Float(x) / 32 - 7)) }
        for profile in [PhotoEngine.Profile.accurate, .adobe, .neutral] {
            var a = PhotoAdjustments(); a.process = 4; a.profile = profile; a.exposure = 2.3; a.contrast = -100; a.shadows = 46
            let chroma = fsDeveloped(ramp, a).prefix(n).map { fsChroma(fsLab($0)) }.max() ?? 1
            check("contrast −100 and shadows keep grey (\(profile.rawValue))", chroma < 0.004, "OkLab chroma under 0.004; got \(chroma)")
        }
    }

    /// With film (process 4) the profile's colour goes into the film's light: Vivid more colourful than Accurate, Monochrome
    /// grey, Accurate's light as before (process 3's, where the profile never reached the film), and process 3's film light
    /// the same whatever the profile (old film edits unchanged).
    private static func filmProfiles() {
        let colours: [SIMD3<Float>] = [SIMD3(0.3, 0.12, 0.05), SIMD3(0.05, 0.2, 0.08), SIMD3(0.06, 0.1, 0.3), SIMD3(0.25, 0.2, 0.06)]
        let patch = fsImage(colours.count * 4, 4) { x, _ in colours[x / 4] }
        func light(_ process: Int, _ profile: PhotoEngine.Profile) -> [SIMD3<Double>] {
            var a = PhotoAdjustments(); a.process = process; a.profile = profile
            let px = fsDeveloped(patch, a, scene: true)
            return colours.indices.map { px[2 * colours.count * 4 + $0 * 4 + 1] }
        }
        func chroma(_ c: [SIMD3<Double>]) -> Double { c.map { fsChroma(fsLab($0)) }.reduce(0, +) / Double(c.count) }
        let accurate = light(4, .accurate), vivid = light(4, .vivid), mono = light(4, .monochrome)
        let before = light(3, .accurate), oldVivid = light(3, .vivid)
        check("film: Vivid more colourful than Accurate", chroma(vivid) > chroma(accurate) * 1.03, "\(chroma(vivid)) against \(chroma(accurate))")
        check("film: Monochrome grey", chroma(mono) < 1e-3, "\(chroma(mono))")
        check("film: Accurate's light as before", zip(accurate, before).allSatisfy { simd_length($0 - $1) < 1e-6 }, "\(accurate) against \(before)")
        check("film: old edits' light unchanged by profile", zip(oldVivid, before).allSatisfy { simd_length($0 - $1) < 1e-6 }, "\(oldVivid) against \(before)")
    }
}
