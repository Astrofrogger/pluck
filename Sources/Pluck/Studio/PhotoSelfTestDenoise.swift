import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Denoise as Lightroom's (version 4): worked out once per photo, the Amount mixed in live. Made-up photos;
/// the Python engine stands in with the noise-free picture unless the test copy has it.
extension PhotoSelfTest {
    private static let denoiseSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    static func denoise() async {
        denoiseMix()
        denoiseSettled()
        denoiseMigration()
        await denoiseOnce()
        await denoiseEngine()
        await denoiseRawRouting()
        await denoiseRawEngine()
    }

    /// A picture in linear light from a colour per pixel (x from the left, y from the top).
    private static func floatImage(_ width: Int, _ height: Int, _ colour: (Int, Int) -> SIMD3<Float>) -> CIImage {
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = colour(x, y), i = (y * width + x) * 4
                pixels[i] = c.x; pixels[i + 1] = c.y; pixels[i + 2] = c.z
            }
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 16, size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: denoiseSpace)
    }

    private static func floats(_ image: CIImage) -> [Float] {
        let e = image.extent.integral
        var pixels = [Float](repeating: 0, count: Int(e.width) * Int(e.height) * 4)
        pixels.withUnsafeMutableBytes {
            PhotoEngine.context.render(image, toBitmap: $0.baseAddress!, rowBytes: Int(e.width) * 16, bounds: e, format: .RGBAf, colorSpace: denoiseSpace)
        }
        return pixels
    }

    /// How far a picture is from another, as the spread of the difference (colour channels).
    private static func spread(_ a: [Float], _ b: [Float]) -> Double {
        var sum = 0.0, squares = 0.0, n = 0.0
        for i in stride(from: 0, to: min(a.count, b.count), by: 4) {
            for c in 0..<3 {
                let d = Double(a[i + c] - b[i + c])
                sum += d; squares += d * d; n += 1
            }
        }
        let mean = sum / max(n, 1)
        return (squares / max(n, 1) - mean * mean).squareRoot()
    }

    /// The mix's ends are the photo and the clean picture exactly (highlights over 1 and below 0 too); 50 is 0.75 clean.
    private static func denoiseMix() {
        let orig = floatImage(4, 4) { _, _ in SIMD3(-0.02, 0.3, 2.5) }
        let clean = floatImage(4, 4) { _, _ in SIMD3(0.1, 0.2, 0.4) }
        func worst(_ amount: Int, _ expected: SIMD3<Float>) -> Float {
            let p = floats(PhotoRender.mixDenoise(orig, clean, amount: amount))
            return (0..<16).map { i in max(abs(p[i * 4] - expected.x), abs(p[i * 4 + 1] - expected.y), abs(p[i * 4 + 2] - expected.z)) }.max() ?? 1
        }
        let half = SIMD3<Float>(-0.02, 0.3, 2.5) + (SIMD3<Float>(0.1, 0.2, 0.4) - SIMD3<Float>(-0.02, 0.3, 2.5)) * 0.75
        let at0 = worst(0, SIMD3(-0.02, 0.3, 2.5)), at100 = worst(100, SIMD3(0.1, 0.2, 0.4)), at50 = worst(50, half)
        check("denoise mix ends", at0 < 1e-3 && at100 < 1e-3 && at50 < 1e-3 && PhotoRender.denoiseWeight(50) == 0.75,
              "0 the photo, 100 the clean one, 50 three quarters clean; off by \(at0), \(at100), \(at50)")
    }

    /// A clean file gone wrong in the highlights (version 2's engine: a window at 16 came back at 80, with black
    /// blotches of -40 around it, and NaN or infinity at worst) never shows: pushed +4.77 stops, nothing is darker
    /// than the photo around it or brighter; and a good clean picture goes through as it is.
    private static func denoiseSettled() {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func u() -> Float { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return Float(seed >> 40) / Float(1 << 24) }
        func scene(_ x: Int, _ y: Int) -> SIMD3<Float> { (20..<44).contains(x) && (20..<44).contains(y) ? SIMD3(16, 18, 20) : SIMD3(0.02, 0.025, 0.03) }
        let orig = floatImage(64, 64) { x, y in scene(x, y) * (0.8 + 0.4 * u()) }
        let wild = floatImage(64, 64) { x, y in
            if (20..<44).contains(x) && (20..<44).contains(y) { return x == 30 ? SIMD3(.nan, .infinity, 80) : SIMD3(80, 80, 80) }
            return (14..<50).contains(x) && (14..<50).contains(y) ? SIMD3(-40, -40, -.infinity) : scene(x, y)
        }
        let lo = floats(orig.applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 3]).cropped(to: orig.extent))
        let pushed = floats(PhotoRender.mixDenoise(orig, PhotoRender.settled(wild, within: orig), amount: 50).applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 4.77]))
        var bad = 0
        for i in stride(from: 0, to: pushed.count, by: 4) {
            for c in 0..<3 where !pushed[i + c].isFinite || pushed[i + c] < lo[i + c] * 0.5 * 27 || pushed[i + c] > 20 * 1.2 * 27.3 { bad += 1 }
        }
        let good = floatImage(64, 64) { x, y in scene(x, y) }
        let kept = spread(floats(PhotoRender.settled(good, within: orig)), floats(good))
        check("denoise never shows black", bad == 0 && kept < 1e-3, "no pixel off, a good clean picture as it is; got \(bad) off, \(kept)")
    }

    /// An edit from before version 2 reads as on at its strength, with the model it had; nothing is off; edits from
    /// before the Colour slider keep the colour noise reduction they had (the Noise slider's, at least 50).
    private static func denoiseMigration() {
        func record(_ json: String) -> PhotoRecord? { try? JSONDecoder().decode(PhotoRecord.self, from: Data(json.utf8)) }
        let old = record(#"{"denoise":40,"denoiseAI":true}"#), none = record("{}")
        check("denoise old edit migrates", old?.denoise == 40 && old?.denoiseAI == true && none?.denoise == 0 && none?.denoiseAI == false,
              "on at 40 with AI, and off; got \(String(describing: old?.denoise)) \(String(describing: old?.denoiseAI)), \(String(describing: none?.denoise))")
        let lifted = record(#"{"adjust":{"exposure":1,"noise":70}}"#)?.adjust.colorNoise
        let edited = record(#"{"adjust":{"exposure":1}}"#)?.adjust.colorNoise
        let untouched = record(#"{"adjust":{}}"#)?.adjust
        let newer = record(#"{"adjust":{"exposure":1,"colorNoise":10}}"#)?.adjust.colorNoise
        var fresh = PhotoAdjustments()
        fresh.colorNoise = 60
        let back = (try? JSONEncoder().encode(fresh)).flatMap { try? JSONDecoder().decode(PhotoAdjustments.self, from: $0) }?.colorNoise
        check("colour noise of old edits", lifted == 70 && edited == 50 && untouched?.colorNoise == 25 && untouched?.isDefault == true && newer == 10 && back == 60,
              "70, 50, 25 (and unedited), 10, 60; got \(String(describing: lifted)), \(String(describing: edited)), \(String(describing: untouched?.colorNoise)), \(String(describing: newer)), \(String(describing: back))")
    }

    /// Three noisy photos are denoised: the engine works each out once, however often the Amount moves (on one photo
    /// or all three) and whatever is drawn or saved; the clean file's key ignores the Amount but not the model or the
    /// decoder's settings; Amount 50 leaves a quarter of the noise, 100 none; the export is what the screen shows.
    private static func denoiseOnce() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-denoise-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let width = 240, height = 160
        func scene(_ x: Int, _ y: Int) -> SIMD3<Float> {
            x > width / 2 ? SIMD3(0.18, 0.18, 0.18) : SIMD3(0.05 + 0.3 * Float(x) / Float(width), 0.1, 0.25 - 0.1 * Float(y) / Float(height))
        }
        let truth = floatImage(width, height, scene)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func uniform() -> Float {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return (Float(seed >> 40) + 0.5) / Float(1 << 24)
        }
        func gauss() -> Float { (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform()) }
        var paths: [String] = []
        for i in 0..<3 {
            let noisy = floatImage(width, height) { x, y in scene(x, y) + SIMD3(gauss(), gauss(), gauss()) * 0.03 }
            let url = folder.appendingPathComponent("noisy\(i).tif")
            try? PhotoEngine.context.writeTIFFRepresentation(of: noisy, to: url, format: .RGBA16, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            paths.append(url.path)
        }
        var calls = 0
        PhotoRender.denoiseEngineForTests = { _, output, _ in
            calls += 1
            try PhotoEngine.context.writeOpenEXRRepresentation(of: truth, to: output)
        }
        defer { PhotoRender.denoiseEngineForTests = nil }
        let editing = PhotoEditing.shared, catalog = PhotoCatalog.shared
        func settle() async {
            for _ in 0..<400 where paths.contains(where: editing.denoising.contains) { try? await Task.sleep(for: .milliseconds(25)) }
        }
        editing.denoise(paths, ai: false)
        await settle()
        let on = paths.allSatisfy { catalog.record($0).denoise == 50 && PhotoRender.cleanFile($0, record: catalog.record($0)) != nil }
        var files: Set<URL> = []
        var previews: Set<URL> = []
        for amount in [10, 50, 90, 100] {
            catalog.update(paths) { $0.denoise = amount }
            for path in paths {
                let record = catalog.record(path)
                _ = PhotoRender.image(path, record: record, maxSize: 128).map { PhotoRender.picture($0) }
                _ = PhotoRender.image(path, record: record, maxSize: 128, drag: true).map { PhotoRender.picture($0) }
                if let url = PhotoRender.denoised(path, record: record) { files.insert(url) }
            }
            previews.insert(PhotoRender.cachedPreview(paths[0], record: catalog.record(paths[0])))
        }
        editing.analyse(paths)
        editing.denoise(paths, ai: false)
        await settle()
        check("denoise worked out once", on && calls == 3 && files.count == 3 && previews.count == 4,
              "on at 50, 3 engine runs for 3 photos and 4 Amounts each, 3 clean files, 4 previews; got on \(on), \(calls) runs, \(files.count) files, \(previews.count) previews")

        let path = paths[0]
        var record = catalog.record(path)
        let plain = PhotoRender.denoised(path, record: record)
        var ai = record; ai.denoiseAI = true
        var decoder = record; decoder.adjust.rawDecoder = "8"
        var moire = record; moire.adjust.moire = 30
        let keys = [ai, decoder, moire].map { PhotoRender.denoised(path, record: $0) }
        check("denoise key by model and decoder", plain != nil && keys.allSatisfy { $0 != nil && $0 != plain },
              "AI, another decoder and moiré each their own clean file")

        // The model switched while the photo is being worked out: the new one is worked out after it.
        let other = paths[1]
        var switched = false
        PhotoRender.denoiseEngineForTests = { _, output, _ in
            if !switched { switched = true; await MainActor.run { catalog.update([other]) { $0.denoiseAI = true } } }
            try PhotoEngine.context.writeOpenEXRRepresentation(of: truth, to: output)
        }
        catalog.update([other]) { $0.adjust.moire = 20 }
        editing.analyse([other])
        await settle()
        check("denoise follows a switch made while it runs", switched && catalog.record(other).denoiseAI
              && PhotoRender.hasClean(other, record: catalog.record(other)),
              "the AI's clean decode made too; got switched \(switched), clean \(PhotoRender.hasClean(other, record: catalog.record(other)))")

        // The noise left: Amount 100 none, 50 a quarter (Lightroom's curve), off all of it.
        let clean = floats(truth)
        func left(_ amount: Int) -> Double {
            record.denoise = amount
            guard let decoded = PhotoRender.decoded(path, maxSize: 0, record: record) else { return -1 }
            return spread(floats(decoded), clean)
        }
        let all = left(0), quarter = left(50), none = left(100)
        check("denoise takes the noise out", all > 0.02 && abs(quarter / all - 0.25) < 0.04 && none < 0.1 * all,
              "about 0.03 off, a quarter of it at 50, none at 100; got \(all), \(quarter), \(none)")

        // Saved at Amount 60 as the screen shows it at full size.
        record.denoise = 60
        catalog.update([path]) { $0.denoise = 60 }
        var settings = PhotoExportSettings()
        settings.format = .png
        let saved = try? await PhotoRender.export(path, record: record, to: folder.appendingPathComponent("out", isDirectory: true), settings: settings)
        func bytes(_ image: CGImage?) -> [UInt8] {
            guard let image else { return [] }
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return data
        }
        let file = bytes(saved.flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let shown = bytes(PhotoRender.image(path, record: record, maxSize: 0).flatMap { PhotoRender.picture($0) })
        let apart = file.count == shown.count && !file.isEmpty
            ? zip(file, shown).enumerated().filter { $0.offset % 4 != 3 }.reduce(0.0) { $0 + abs(Double($1.element.0) - Double($1.element.1)) } / Double(file.count / 4 * 3) : -1
        check("denoised export matches the screen", apart >= 0 && apart < 0.5, "under 0.5/255 apart on average; got \(apart)")
    }

    /// With the Python engine in the test copy: its steps go there and back exactly, and both denoisers clean a made-up
    /// photo as Lightroom's would: a dark flat part loses at least 70% of its noise and keeps its mean, a radiator's
    /// stripes keep their edges, and a window far past white (6, with a dark leaf across it) comes back as it was, no
    /// blotch darker than half or brighter than twice it. (Without the engine, these are skipped.)
    private static func denoiseEngine() async {
        guard FilmEngine.shared.denoiseEngine == .ready else {
            skip("denoise curve round trip", "the denoise engine isn't in the test copy")
            skip("denoise standard engine", "the denoise engine isn't in the test copy")
            return
        }
        let worst = (try? await FilmEngine.shared.denoiseRoundTrip()) ?? 1
        check("denoise curve round trip", worst < 1e-3, "under 1e-3 off, and a cleaner gone wild kept within the photo; got \(worst)")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-denoise-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func gauss() -> Float {
            func u() -> Float { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return (Float(seed >> 40) + 0.5) / Float(1 << 24) }
            return (-2 * log(u())).squareRoot() * cos(2 * .pi * u())
        }
        let n = 512
        func scene(_ x: Int, _ y: Int) -> SIMD3<Float> {
            if x < 256 { return SIMD3(0.02, 0.018, 0.015) }
            if y < 256 { return abs(x - y - 216) < 6 ? SIMD3(0.03, 0.05, 0.02) : SIMD3(6, 6.2, 6.6) }
            return (x / 8) % 2 == 0 ? SIMD3(0.06, 0.055, 0.05) : SIMD3(0.03, 0.028, 0.025)
        }
        let truth = floats(floatImage(n, n, scene))
        let noisy = floatImage(n, n) { x, y in
            let s = scene(x, y)
            return s + SIMD3(gauss(), gauss(), gauss()) * (SIMD3<Float>(repeating: 0.006 * 0.006) + 0.0002 * s).squareRoot()
        }
        let input = folder.appendingPathComponent("in.tif")
        try? PhotoEngine.context.writeTIFFRepresentation(of: noisy, to: input, format: .RGBAh, colorSpace: denoiseSpace)
        let before = floats(noisy)
        func at(_ p: [Float], _ x: Int, _ y: Int, _ c: Int) -> Float { p[(y * n + x) * 4 + c] }
        func luma(_ p: [Float], _ x: Int, _ y: Int) -> Float { 0.2126 * at(p, x, y, 0) + 0.7152 * at(p, x, y, 1) + 0.0722 * at(p, x, y, 2) }
        func flatError(_ p: [Float]) -> (spread: Double, mean: Double) {
            var sum = 0.0, squares = 0.0, count = 0.0, level = 0.0
            for y in 32..<480 { for x in 32..<224 { for c in 0..<3 {
                let d = Double(at(p, x, y, c) - at(truth, x, y, c))
                sum += d; squares += d * d; count += 1; level += Double(at(truth, x, y, c))
            } } }
            return ((squares / count - (sum / count) * (sum / count)).squareRoot(), abs(sum / level))
        }
        // The stripes' edges, averaged down their length (which takes the noise out of the photo's too).
        func edges(_ p: [Float]) -> Double {
            let profile = (256..<512).map { x in (288..<480).reduce(0.0) { $0 + Double(luma(p, x, $1)) } / 192 }
            return zip(profile.dropFirst(), profile).reduce(0.0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
        }
        var models = [false]
        if FilmEngine.shared.denoiser == .ready { models.append(true) } else { skip("denoise AI engine", "the AI denoiser isn't in the test copy") }
        for ai in models {
            let name = ai ? "denoise AI engine" : "denoise standard engine"
            let output = folder.appendingPathComponent(ai ? "ai.exr" : "standard.exr")
            do {
                try await FilmEngine.shared.denoise(input, to: output, ai: ai, worker: 1)
                guard let clean = CIImage(contentsOf: output).map(floats), clean.count == truth.count else { throw NSError(domain: "Pluck", code: 1) }
                let cut = 1 - flatError(clean).spread / flatError(before).spread, drift = flatError(clean).mean
                let kept = edges(clean) / edges(before)
                var blotches = 0, window = 0.0, shown = 0.0
                for y in 0..<256 { for x in 256..<512 {
                    let l = luma(clean, x, y), t = luma(truth, x, y)
                    if !l.isFinite || l < 0.5 * t || l > 2 * t { blotches += 1 }
                    if y >= 16, y < 96, x >= 420, x < 500 { window += Double(t); shown += Double(l) }
                } }
                let light = abs(shown / window - 1)
                // NL-means softens a step over about 2 px; the network keeps it.
                check(name, cut >= 0.7 && drift < 0.02 && kept >= (ai ? 0.9 : 0.4) && blotches == 0 && light < 0.01,
                      "flat noise down 70%+, its mean within 2%, edges \(ai ? "90" : "40")%+ kept, no blotch, the window within 1%; got \(cut), \(drift), \(kept), \(blotches), \(light)")
            } catch {
                check(name, false, error.localizedDescription)
            }
        }
    }

    // MARK: - The raw denoiser (AI on a Bayer RAW)

    private static var greencastRaw: URL {
        URL(fileURLWithPath: photos).deletingLastPathComponent().appendingPathComponent("greencast/DSC01962.ARW")
    }

    /// A temporary copy of the test RAW (its own clean files), or nil without it.
    private static func rawCopy(_ folder: URL, _ name: String) -> String? {
        let url = folder.appendingPathComponent(name)
        guard (try? FileManager.default.copyItem(at: greencastRaw, to: url)) != nil else { return nil }
        return url.path
    }

    /// AI on a Bayer RAW goes to the raw denoiser, and once only, however the Amount moves and whatever is drawn; one it
    /// answers unsupported (X-Trans, …) goes to the decode's denoiser and isn't asked again; Standard, and a photo that
    /// isn't RAW, go to the decode's denoiser; all in one mixed batch. (The engines stand in, with the engine's DNGs for it.)
    private static func denoiseRawRouting() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-rawroute-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let bayer = rawCopy(folder, "bayer.ARW"), let other = rawCopy(folder, "xtrans.ARW"), let standard = rawCopy(folder, "standard.ARW") else {
            skip("denoise raw routing", "no greencast/DSC01962.ARW"); return
        }
        // The engine's DNGs for the test RAW, made once (the RAW itself doesn't decode as a DNG).
        let pair = (clean: greencastRaw.deletingPathExtension().appendingPathExtension("clean.dng"),
                    noisy: greencastRaw.deletingPathExtension().appendingPathExtension("noisy.dng"))
        guard FileManager.default.fileExists(atPath: pair.clean.path), FileManager.default.fileExists(atPath: pair.noisy.path) else {
            skip("denoise raw routing", "no greencast/DSC01962.clean.dng and .noisy.dng"); return
        }
        let tiff = folder.appendingPathComponent("photo.tif")
        try? PhotoEngine.context.writeTIFFRepresentation(of: floatImage(64, 48) { x, _ in SIMD3(0.1, 0.2, Float(x) / 64) }, to: tiff,
                                                         format: .RGBA16, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var rawCalls: [String: Int] = [:], decodeCalls = 0
        PhotoRender.rawDenoiseEngineForTests = { input, clean, noisy in
            rawCalls[input.lastPathComponent, default: 0] += 1
            guard input.lastPathComponent != "xtrans.ARW" else { return false }
            // (A clean DNG that doesn't decode, as a crashed or full-disk run could leave.)
            if input.lastPathComponent == "broken.ARW" { try Data(repeating: 7, count: 4096).write(to: clean) } else {
                try FileManager.default.copyItem(at: pair.clean, to: clean)
            }
            try FileManager.default.copyItem(at: pair.noisy, to: noisy)
            return true
        }
        PhotoRender.denoiseEngineForTests = { input, output, _ in
            decodeCalls += 1
            guard let image = CIImage(contentsOf: input) else { throw NSError(domain: "Pluck", code: 1) }
            try PhotoEngine.context.writeOpenEXRRepresentation(of: image, to: output)
        }
        defer { PhotoRender.rawDenoiseEngineForTests = nil; PhotoRender.denoiseEngineForTests = nil }
        let editing = PhotoEditing.shared, catalog = PhotoCatalog.shared
        func settle(_ paths: [String]) async {
            for _ in 0..<1200 where paths.contains(where: editing.denoising.contains) { try? await Task.sleep(for: .milliseconds(25)) }
        }
        let ai = [bayer, other, tiff.path]
        editing.denoise(ai, ai: true)
        editing.denoise([standard], ai: false)
        await settle(ai + [standard])
        let routed = PhotoRender.rawRoute(bayer, record: catalog.record(bayer)) != nil
            && PhotoRender.cleanFile(bayer, record: catalog.record(bayer))?.pathExtension == "json"
            && PhotoRender.rawRoute(other, record: catalog.record(other)) == nil
            && PhotoRender.cleanFile(other, record: catalog.record(other))?.pathExtension == "exr"
            && PhotoRender.cleanFile(tiff.path, record: catalog.record(tiff.path))?.pathExtension == "exr"
            && PhotoRender.cleanFile(standard, record: catalog.record(standard))?.pathExtension == "exr"
        check("denoise raw routing", routed && rawCalls == ["bayer.ARW": 1, "xtrans.ARW": 1] && decodeCalls == 3,
              "Bayer to the raw denoiser; unsupported, a TIFF and Standard to the decode's (3); got routed \(routed), raw \(rawCalls), decode \(decodeCalls)")

        // The Amount is live: drawn, saved and asked again at four Amounts, the engines aren't run again.
        var drawn = true
        for amount in [1, 30, 50, 100] {
            catalog.update(ai) { $0.denoise = amount }
            for path in ai {
                drawn = drawn && PhotoRender.image(path, record: catalog.record(path), maxSize: 256).flatMap { PhotoRender.picture($0) } != nil
            }
            editing.analyse(ai + [standard])
            await settle(ai + [standard])
        }
        let full = PhotoRender.decoded(bayer, maxSize: 0, record: catalog.record(bayer))?.extent.size
        check("denoise raw analysed once", drawn && rawCalls == ["bayer.ARW": 1, "xtrans.ARW": 1] && decodeCalls == 3
              && full == PhotoRender.source(bayer, maxSize: 0, color: 0)?.extent.size,
              "drawn at every Amount, still one run each, saved at the RAW's own size; got drawn \(drawn), raw \(rawCalls), decode \(decodeCalls), \(String(describing: full))")

        // A clean DNG that doesn't decode is never kept; one that stops decoding later shows the photo, not nothing.
        if let broken = rawCopy(folder, "broken.ARW") {
            editing.denoise([broken], ai: true)
            await settle([broken])
            let refused = !PhotoRender.hasClean(broken, record: catalog.record(broken)) && editing.denoiseProblem != nil
            if let files = PhotoRender.rawRoute(bayer, record: catalog.record(bayer)) { try? Data(repeating: 7, count: 4096).write(to: files.clean) }
            let shown = PhotoRender.image(bayer, record: catalog.record(bayer), maxSize: 200) != nil
            check("denoise raw broken file", refused && shown, "a clean DNG that doesn't decode isn't kept, and one broken later still shows the photo; got kept \(!refused), shown \(shown)")
        }
    }

    /// Phase correlation of two square grey patches (n a power of two not needed: a plain DFT): how far `b` sits from `a`, in pixels.
    private static func phaseShift(_ a: [Double], _ b: [Double], _ n: Int) -> (dx: Double, dy: Double) {
        let cosines = (0..<n * n).map { cos(2 * Double.pi * Double($0 % n) * Double($0 / n) / Double(n)) }
        let sines = (0..<n * n).map { sin(2 * Double.pi * Double($0 % n) * Double($0 / n) / Double(n)) }
        // Rows, then columns; `sign` -1 forward, +1 back.
        func dft(_ re: [Double], _ im: [Double], _ sign: Double) -> ([Double], [Double]) {
            var r1 = [Double](repeating: 0, count: n * n), i1 = r1
            for y in 0..<n { for k in 0..<n {
                var sr = 0.0, si = 0.0
                for x in 0..<n {
                    let c = cosines[k * n + x], s = sign * sines[k * n + x], pr = re[y * n + x], pi = im[y * n + x]
                    sr += pr * c - pi * s; si += pr * s + pi * c
                }
                r1[y * n + k] = sr; i1[y * n + k] = si
            } }
            var r2 = r1, i2 = i1
            for x in 0..<n { for k in 0..<n {
                var sr = 0.0, si = 0.0
                for y in 0..<n {
                    let c = cosines[k * n + y], s = sign * sines[k * n + y], pr = r1[y * n + x], pi = i1[y * n + x]
                    sr += pr * c - pi * s; si += pr * s + pi * c
                }
                r2[k * n + x] = sr; i2[k * n + x] = si
            } }
            return (r2, i2)
        }
        let zero = [Double](repeating: 0, count: n * n)
        let ma = a.reduce(0, +) / Double(n * n), mb = b.reduce(0, +) / Double(n * n)
        let (ar, ai) = dft(a.map { $0 - ma }, zero, -1), (br, bi) = dft(b.map { $0 - mb }, zero, -1)
        var cr = zero, ci = zero
        for i in 0..<n * n {
            // B · conj(A), normalised
            let r = br[i] * ar[i] + bi[i] * ai[i], im = bi[i] * ar[i] - br[i] * ai[i], m = max((r * r + im * im).squareRoot(), 1e-12)
            cr[i] = r / m; ci[i] = im / m
        }
        let (surface, _) = dft(cr, ci, 1)
        let peak = surface.indices.max { surface[$0] < surface[$1] } ?? 0
        let px = peak % n, py = peak / n
        func fine(_ m: Double, _ z: Double, _ p: Double) -> Double { abs(m - 2 * z + p) < 1e-12 ? 0 : 0.5 * (m - p) / (m - 2 * z + p) }
        let dx = Double(px) + fine(surface[py * n + (px + n - 1) % n], surface[peak], surface[py * n + (px + 1) % n])
        let dy = Double(py) + fine(surface[((py + n - 1) % n) * n + px], surface[peak], surface[((py + 1) % n) * n + px])
        return (dx > Double(n) / 2 ? dx - Double(n) : dx, dy > Double(n) / 2 ? dy - Double(n) : dy)
    }

    /// A patch's brightness (square root, so the shadows count), at full size, from the top left. Softened (3 px):
    /// the picture's lining up is measured, not the demosaicing's pixel pattern (whose noise correlates a pixel or
    /// more off between two decoders, measured).
    private static func patch(_ image: CIImage, x: Int, y: Int, n: Int) -> [Double] {
        let e = image.extent
        let p = floats(image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 3]).cropped(to: CGRect(x: e.minX + CGFloat(x), y: e.maxY - CGFloat(y + n), width: CGFloat(n), height: CGFloat(n))))
        return (0..<n * n).map { i in max(0, Double(0.2126 * p[i * 4] + 0.7152 * p[i * 4 + 1] + 0.0722 * p[i * 4 + 2])).squareRoot() }
    }

    /// With the raw denoiser in the test copy, on the real RAW: its own check holds; the clean and noisy DNGs decode at
    /// the RAW's size and line up (under half a pixel apart at the centre and the four corners, and the noisy one
    /// against the RAW too); Amount 0 looks as the RAW does (patches within 2%); the clean decode has no blob (darker
    /// than half, or brighter than twice, the photo's own light around it); and the photo at the owner's settings is
    /// saved (`greencast/denoise-raw-app.jpg`), with its time.
    private static func denoiseRawEngine() async {
        guard FilmEngine.shared.denoiseEngine == .ready, FilmEngine.rawDenoiseInstalled else {
            skip("denoise raw engine", "the AI denoiser's RAW part isn't in the test copy"); return
        }
        let own = (try? await FilmEngine.shared.rawDenoiseSelfTest()) ?? false
        check("denoise raw engine self-check", own, "the transform's round trip, its unbiased inverse and the noise fit")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-rawdn-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let path = rawCopy(folder, "DSC01962.ARW") else { skip("denoise raw alignment", "no greencast/DSC01962.ARW"); return }
        var record = PhotoRecord()
        record.denoise = 50
        record.denoiseAI = true
        let started = Date()
        do { try await PhotoRender.denoise(path, record: record) } catch { check("denoise raw engine", false, error.localizedDescription); return }
        let seconds = Date().timeIntervalSince(started)
        let settings = PhotoRender.RawSettings(record.adjust)
        guard let file = PhotoRender.cleanFile(path, record: record), file.pathExtension == "json",
              let noisy = PhotoRender.denoiseSide(path, file, noisy: true, maxSize: 0, raw: settings),
              let clean = PhotoRender.denoiseSide(path, file, noisy: false, maxSize: 0, raw: settings),
              let arw = PhotoRender.source(path, maxSize: 0, noise: 0, color: 0, raw: settings) else {
            check("denoise raw engine", false, "no DNG pair made"); return
        }
        check("denoise raw engine", seconds < 60, "a 24 MP RAW in under a minute; got \(seconds) s")
        // (Its time, beside the render.)
        try? "\(seconds) s\n".write(to: greencastRaw.deletingLastPathComponent().appendingPathComponent("denoise-raw-app.txt"), atomically: true, encoding: .utf8)

        // Lined up: the same size, and phase correlation at the centre and in each corner (of a 3×3 choice of patches
        // stepping in from it, the one with the most detail: a dark, featureless corner has nothing to measure).
        let e = noisy.extent, n = 256, W = Int(e.width), H = Int(e.height)
        func spread(_ p: [Double]) -> Double { let m = p.reduce(0, +) / Double(p.count); return (p.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(p.count)).squareRoot() }
        var worstClean = 0.0, worstRaw = 0.0
        for (cx, cy) in [(W / 2 - n / 2, H / 2 - n / 2), (64, 64), (W - n - 64, 64), (64, H - n - 64), (W - n - 64, H - n - 64)] {
            let sx = cx < W / 3 ? 1 : (cx > W / 2 ? -1 : 0), sy = cy < H / 3 ? 1 : (cy > H / 2 ? -1 : 0)
            var best = (x: cx, y: cy, detail: -1.0, patch: [Double]())
            for i in 0..<3 { for j in 0..<3 {
                let x = cx + sx * i * 192, y = cy + sy * j * 192, p = patch(noisy, x: x, y: y, n: n)
                if spread(p) > best.detail { best = (x, y, spread(p), p) }
            } }
            let c = phaseShift(best.patch, patch(clean, x: best.x, y: best.y, n: n), n)
            let r = phaseShift(best.patch, patch(arw, x: best.x, y: best.y, n: n), n)
            worstClean = max(worstClean, abs(c.dx), abs(c.dy)); worstRaw = max(worstRaw, abs(r.dx), abs(r.dy))
        }
        check("denoise raw alignment", clean.extent.size == e.size && e.size == arw.extent.size && worstClean < 0.5 && worstRaw < 0.5,
              "clean, noisy and RAW decodes one size; clean and the RAW each under 0.5 px from noisy; got \(clean.extent.size), \(e.size), \(arw.extent.size), \(worstClean), \(worstRaw)")

        // Amount 0 as the RAW: 64 px patches with light in them, per channel (half size).
        let half = Int(max(e.width, e.height) / 2)
        let small = PhotoRender.denoiseSide(path, file, noisy: true, maxSize: half, raw: settings).map(floats) ?? []
        let ref = PhotoRender.source(path, maxSize: half, noise: 0, color: 0, raw: settings).map(floats) ?? []
        let w = half, h = small.count / 4 / max(w, 1)
        var apart: [Double] = []
        if small.count == ref.count, h > 64 {
            for y0 in stride(from: 0, to: h - 64, by: 64) { for x0 in stride(from: 0, to: w - 64, by: 64) {
                var p = SIMD3<Double>(), q = SIMD3<Double>()
                for y in y0..<y0 + 64 { for x in x0..<x0 + 64 {
                    let i = (y * w + x) * 4
                    p += SIMD3(Double(small[i]), Double(small[i + 1]), Double(small[i + 2])); q += SIMD3(Double(ref[i]), Double(ref[i + 1]), Double(ref[i + 2]))
                } }
                let d = p - q
                if q.sum() / 4096 > 6e-3 { apart.append((abs(d.x) + abs(d.y) + abs(d.z)) / q.sum()) }
            } }
        }
        let meanApart = apart.isEmpty ? 1 : apart.reduce(0, +) / Double(apart.count)
        check("denoise raw Amount 0 is the RAW", meanApart < 0.02, "patches within 2% on average; got \(meanApart) over \(apart.count)")

        // No blobs: no 3×3 spot of the clean decode (its brightest pixel) darker than half the photo's own light around
        // it (softened 1 px, then its 5 px min), nor (its darkest) brighter than twice (the 5 px max). A thin line the
        // clean decode draws sharper isn't a spot. A spot put in on purpose is found (the measure works).
        // (Against the denoiser's own input, the noisy DNG decoded alike: version 3 shows the RAW's decode, by decoder 9, as
        // the noisy side, and the shown clean side is held within it: settled.)
        let input = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Double].self, from: $0) }.flatMap { m in
            PhotoRender.source(path, maxSize: 0, noise: 0, color: 0, raw: settings,
                               file: URL(fileURLWithPath: file.deletingPathExtension().deletingPathExtension().path + ".noisy.dng"))
                .map { PhotoRender.coloured($0, m) }
        } ?? noisy
        let soft = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1])
        let low = floats(soft.applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 2]).cropped(to: e))
        let high = floats(soft.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 2]).cropped(to: e))
        func blobs(_ image: CIImage) -> Int {
            let spotMax = floats(image.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 1]).cropped(to: e))
            let spotMin = floats(image.applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 1]).cropped(to: e))
            var count = 0
            for i in stride(from: 0, to: min(spotMax.count, spotMin.count, low.count, high.count), by: 4) {
                func luma(_ p: [Float]) -> Float { 0.2126 * p[i] + 0.7152 * p[i + 1] + 0.0722 * p[i + 2] }
                let lo = luma(low), hi = luma(high), dark = luma(spotMax), bright = luma(spotMin)
                if !dark.isFinite || !bright.isFinite || (lo > 0.01 && dark < 0.5 * lo) || (hi > 0.01 && bright > 2 * hi) { count += 1 }
            }
            return count
        }
        let spot = CGRect(x: e.midX, y: e.midY, width: 6, height: 6)
        let planted = clean.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0.3, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.3, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 0.3, w: 0)]).cropped(to: spot).composited(over: clean)
        let found = blobs(clean), seen = blobs(planted)
        check("denoise raw no blobs", found == 0 && seen > 0, "no spot darker than half, or brighter than twice, the photo's light around it, and a planted one found; got \(found), planted \(seen)")

        // The owner's settings, saved through the app's own path.
        record.adjust.process = PhotoAdjustments.currentProcess
        record.adjust.profile = .adobe
        record.adjust.exposure = 2.25
        record.adjust.highlights = -100
        record.adjust.shadows = 100
        let out = greencastRaw.deletingLastPathComponent().appendingPathComponent("denoise-raw-app.jpg")
        BaseCache.shared.removeAll(); GuideCache.shared.removeAll()
        guard let image = PhotoRender.image(path, record: record, maxSize: 0), let picture = PhotoRender.picture(image, maxSize: 0),
              let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            check("denoise raw render", false, "not rendered"); return
        }
        CGImageDestinationAddImage(dest, picture, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        check("denoise raw render", CGImageDestinationFinalize(dest), "\(picture.width)×\(picture.height)")
    }
}
