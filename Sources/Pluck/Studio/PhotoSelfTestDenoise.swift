import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Denoise as Lightroom's (version 2): worked out once per photo, the Amount mixed in live. Made-up photos;
/// the Python engine stands in with the noise-free picture unless the test copy has it.
extension PhotoSelfTest {
    private static let denoiseSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    static func denoise() async {
        denoiseMix()
        denoiseMigration()
        await denoiseOnce()
        await denoiseEngine()
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

    /// With the Python engine in the test copy: its exposure curve goes there and back, and Standard takes most of the
    /// noise out of a made-up photo. (Without it, these are skipped: the engine is checked on its own then.)
    private static func denoiseEngine() async {
        guard FilmEngine.shared.denoiseEngine == .ready else {
            skip("denoise curve round trip", "the denoise engine isn't in the test copy")
            skip("denoise standard engine", "the denoise engine isn't in the test copy")
            return
        }
        let worst = (try? await FilmEngine.shared.denoiseRoundTrip()) ?? 1
        check("denoise curve round trip", worst < 1e-3, "under 1e-3 off; got \(worst)")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-denoise-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func gauss() -> Float {
            func u() -> Float { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return (Float(seed >> 40) + 0.5) / Float(1 << 24) }
            return (-2 * log(u())).squareRoot() * cos(2 * .pi * u())
        }
        let truth = floatImage(512, 512) { x, _ in x < 256 ? SIMD3(0.02, 0.02, 0.02) : SIMD3(0.05, 0.03, 0.02) }
        let noisy = floatImage(512, 512) { x, _ in (x < 256 ? SIMD3(0.02, 0.02, 0.02) : SIMD3(0.05, 0.03, 0.02)) + SIMD3(gauss(), gauss(), gauss()) * 0.006 }
        let input = folder.appendingPathComponent("in.tif"), output = folder.appendingPathComponent("out.exr")
        try? PhotoEngine.context.writeTIFFRepresentation(of: noisy, to: input, format: .RGBAh, colorSpace: denoiseSpace)
        do {
            try await FilmEngine.shared.denoise(input, to: output, worker: 1)
            let clean = CIImage(contentsOf: output).map(floats) ?? []
            let before = spread(floats(noisy), floats(truth)), after = spread(clean, floats(truth))
            check("denoise standard engine", after <= 0.35 * before, "at most 0.35 of the noise left; got \(after / before)")
        } catch {
            check("denoise standard engine", false, error.localizedDescription)
        }
    }
}
