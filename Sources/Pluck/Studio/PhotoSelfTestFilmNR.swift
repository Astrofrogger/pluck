import CoreImage
import Foundation
import UniformTypeIdentifiers

/// Film sharpness with Halation off (process 5), the high-ISO noise reduction's control, and the favourite film.
extension PhotoSelfTest {
    static func filmNR() async {
        halationSharpness()
        await luminanceControl()
        await favouriteFilm()
        await filmNRDump()
    }

    private static var highISO: String {
        URL(fileURLWithPath: photos).deletingLastPathComponent().appendingPathComponent("shootout/raws/R6LO7461.CR3").path
    }

    /// The finest detail in the middle 512 px of a full-size decode: the RMS of a 4-neighbour Laplacian over the mean (green).
    private static func fineEnergy(_ image: CIImage?) -> Double {
        guard let image else { return 0 }
        let n = 512, e = image.extent, r = CGRect(x: (e.midX - 256).rounded(), y: (e.midY - 256).rounded(), width: 512, height: 512)
        var px = [Float](repeating: 0, count: n * n * 4)
        PhotoEngine.context.render(image, toBitmap: &px, rowBytes: n * 16, bounds: r, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        var sum = 0.0, mean = 0.0
        for y in 1..<(n - 1) { for x in 1..<(n - 1) {
            func g(_ x: Int, _ y: Int) -> Double { Double(px[(y * n + x) * 4 + 1]) }
            let l = 4 * g(x, y) - g(x - 1, y) - g(x + 1, y) - g(x, y - 1) - g(x, y + 1)
            sum += l * l; mean += g(x, y)
        } }
        return (sum / Double((n - 2) * (n - 2))).squareRoot() / max(mean / Double((n - 2) * (n - 2)), 1e-9)
    }

    /// Process 5's Luminance: it starts at the ISO's amount, 0 is none (the decoder's too), and what the denoisers are given
    /// has none either. Process 4 is as it was.
    private static func luminanceControl() async {
        let path = highISO
        guard FileManager.default.fileExists(atPath: path) else { skip("luminance 0 keeps fine detail", "no shootout/raws/R6LO7461.CR3"); return }
        var p5 = PhotoRecord(), p4 = PhotoRecord(), zero = PhotoRecord()
        p4.adjust.process = 4
        zero.adjust.noise = 0; zero.adjust.noiseSet = true
        let auto = PhotoRender.luminance(p5.adjust, path: path)
        check("luminance starts by iso", auto == PhotoRender.autoLumaTop && PhotoRender.luminance(zero.adjust, path: path) == 0
              && PhotoRender.luminance(p4.adjust, path: path) == 0 && PhotoRender.autoLuminance(iso: 400) == 0,
              "ISO 6400 \(auto), set to 0: \(PhotoRender.luminance(zero.adjust, path: path)), process 4: \(PhotoRender.luminance(p4.adjust, path: path))")
        BaseCache.shared.removeAll(); GuideCache.shared.removeAll()
        let old = fineEnergy(PhotoRender.decoded(path, maxSize: 0, record: p4))
        let new = fineEnergy(PhotoRender.decoded(path, maxSize: 0, record: p5))
        let none = fineEnergy(PhotoRender.decoded(path, maxSize: 0, record: zero))
        note(String(format: "luminance fine energy, R6LO7461 (ISO 6400): process 4 default %.3f, process 5 default (%.0f) %.3f, 0 %.3f", old, auto, new, none))
        check("luminance 0 keeps fine detail", none > 1.08 * old && new > old && none > new, String(format: "old %.3f, new %.3f, none %.3f", old, new, none))
        // What AI Denoise is given (and the mix's photo side): the decode without luminance noise reduction.
        p5.denoise = 50; p5.denoiseAI = true
        func given(_ r: PhotoRecord) -> Double { fineEnergy(PhotoRender.source(path, maxSize: 0, noise: 0, color: 0, raw: PhotoRender.RawSettings(r.adjust))) }
        var zeroNoColour = zero; zeroNoColour.adjust.colorNoise = 0
        let ai = given(p5), aiOld = given(p4), off = fineEnergy(PhotoRender.decoded(path, maxSize: 0, record: zeroNoColour))
        check("ai denoise gets no luminance noise reduction", abs(ai / max(off, 1e-9) - 1) < 0.03 && ai > 1.08 * old,
              String(format: "given %.3f, Luminance 0 %.3f, process 4 given %.3f, process 4 default %.3f", ai, off, aiOld, old))
    }

    /// Film turned on for a photo without film settings starts on the favourite; with none, on today's default; a photo's own
    /// film is kept.
    private static func favouriteFilm() async {
        await FilmEngine.shared.loadProfiles()
        let engine = FilmEngine.shared
        guard let favourite = engine.films.first(where: { $0.id != FilmSettings().film && $0.type == "negative" })?.id,
              let defaults = UserDefaults(suiteName: "pluck-selftest-favourite") else { check("film on starts on the favourite", false, "no films"); return }
        defaults.removeObject(forKey: Prefs.favouriteFilm)
        var plain = PhotoRecord()
        plain.turnFilm(true, engine: engine, defaults: defaults)
        defaults.set(favourite, forKey: Prefs.favouriteFilm)
        var fresh = PhotoRecord(), own = PhotoRecord()
        fresh.turnFilm(true, engine: engine, defaults: defaults)
        own.film.film = "kodak_gold_200"
        own.turnFilm(true, engine: engine, defaults: defaults)
        defaults.removeObject(forKey: Prefs.favouriteFilm)
        check("film on starts on the favourite", plain.filmOn && plain.film == FilmSettings() && fresh.filmOn && fresh.film.film == favourite
              && own.filmOn && own.film.film == "kodak_gold_200",
              "none: \(plain.film.film), favourite \(favourite): \(fresh.film.film), own: \(own.film.film)")
    }

    /// For the report's sheet only, when <photos>/../fnr/dump exists: full-size renders of R6LO7461 (process 4's default, 5's,
    /// Luminance 0, AI Denoise) and DSC02868 on Portra 400 (halation on; off on process 4 and 5).
    private static func filmNRDump() async {
        let base = URL(fileURLWithPath: photos).deletingLastPathComponent(), out = base.appendingPathComponent("fnr/dump")
        guard FileManager.default.fileExists(atPath: out.path) else { return }
        func save(_ path: String, _ record: PhotoRecord, _ name: String) async {
            BaseCache.shared.removeAll(); GuideCache.shared.removeAll()
            guard let cg = try? await PhotoRender.develop(path, record: record, maxSize: 0),
                  let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { return note("dump \(name): no picture") }
            CGImageDestinationAddImage(dest, cg, nil)
            _ = CGImageDestinationFinalize(dest)
        }
        let cr3 = highISO
        if FileManager.default.fileExists(atPath: cr3) {
            var p4 = PhotoRecord(); p4.adjust.process = 4
            var zero = PhotoRecord(); zero.adjust.noiseSet = true
            await save(cr3, p4, "iso-p4"); await save(cr3, PhotoRecord(), "iso-p5"); await save(cr3, zero, "iso-zero")
            var ai = PhotoRecord(); ai.denoise = 50; ai.denoiseAI = true
            if FilmEngine.shared.denoiser == .ready, (try? await PhotoRender.denoise(cr3, record: ai)) != nil { await save(cr3, ai, "iso-ai") } else { note("dump: no AI denoiser") }
        }
        let arw = base.appendingPathComponent("shootout/raws/DSC02868.ARW").path
        if FileManager.default.fileExists(atPath: arw) {
            for (name, process, on) in [("hal-on-p4", 4, true), ("hal-on", 5, true), ("hal-off-p4", 4, false), ("hal-off-p5", 5, false)] {
                var r = PhotoRecord(); r.adjust.process = process; r.filmOn = true
                r.film.changed["grain_on"] = .number(0)
                if !on { r.film.changed["halation_on"] = .number(0) }
                await save(arw, r, name)
            }
        }
    }

    /// Process 5: Halation off keeps the film's softness (only the glow goes); process 4 stays as it was (crisper).
    static func halationSharpness() {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let width = 400, height = 8
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4, v: Float = x < width / 2 ? 0.03 : 0.3
            pixels[i] = v; pixels[i + 1] = v * 0.9; pixels[i + 2] = v * 0.7
        } }
        let scene = CIImage(bitmapData: pixels.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: width * 16,
                            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: space)
        for name in ["kodak_portra_400", "kodak_gold_200"] {
            guard let stock = FilmTables.shared.stock(film: name, paper: "kodak_portra_endura") else {
                check("halation off keeps film sharpness", false, "no stock \(name)"); continue
            }
            // Overshoot beside the edge (over the step) and the 10–90 % rise in pixels, green, a 35 mm frame 6000 px wide.
            func edge(halation: Bool, process: Int) -> (over: Double, slope: Double) {
                var film = FilmSettings()
                film.film = name; film.paper = "kodak_portra_endura"
                film.changed = ["grain_on": .number(0)]
                if !halation { film.changed["halation_on"] = .number(0) }
                let picture = PhotoRender.filmed(scene, stock: stock, film: FilmHalation.rendered(film, process: process), geometry: FilmGeometry(fullLongEdge: 6000))
                var out = [Float](repeating: 0, count: width * height * 4)
                out.withUnsafeMutableBytes {
                    PhotoEngine.context.render(picture, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: scene.extent, format: .RGBAf, colorSpace: space)
                }
                let r = (0..<width).map { Double(out[(height / 2 * width + $0) * 4 + 1]) }
                let c = width / 2, low = r[c - 40], high = r[c + 40], step = max(high - low, 1e-6)
                let over = ((r[c...(c + 12)].max() ?? 0) - high + low - (r[(c - 12)..<c].min() ?? 0)) / step
                // Acutance: the steepest step between neighbours, over the edge's height.
                let slope = ((c - 12)..<(c + 12)).map { r[$0 + 1] - r[$0] }.max() ?? 0
                return (over, slope / step)
            }
            let on = edge(halation: true, process: 5), off = edge(halation: false, process: 5), old = edge(halation: false, process: 4)
            note(String(format: "halation %@: overshoot / acutance, on %.4f / %.3f; off, process 5 %.4f / %.3f; off, process 4 %.4f / %.3f",
                        name, on.over, on.slope, off.over, off.slope, old.over, old.slope))
            check("halation off keeps film sharpness \(name)",
                  abs(off.over - on.over) <= 0.02 && abs(off.slope / max(on.slope, 1e-9) - 1) <= 0.1,
                  "on \(on), off \(off)")
        }
    }
}
