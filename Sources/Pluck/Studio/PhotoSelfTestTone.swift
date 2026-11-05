import CoreImage

/// Contrast and Clarity on made-up pictures (no photo files needed).
extension PhotoSelfTest {
    private static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    /// A grey picture in linear light, `value` per pixel (x from the left, y from the top).
    private static func greyImage(_ width: Int, _ height: Int, _ value: (Int, Int) -> Float) -> CIImage {
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = value(x, y), i = (y * width + x) * 4
                pixels[i] = v; pixels[i + 1] = v; pixels[i + 2] = v
            }
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 16, size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: linearSpace)
    }

    /// The picture's brightness (luma, linear), rows from the top.
    private static func lumas(_ image: CIImage) -> [Float] {
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes {
            PhotoEngine.context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: extent, format: .RGBAf, colorSpace: linearSpace)
        }
        return (0..<(width * height)).map { 0.2126 * pixels[$0 * 4] + 0.7152 * pixels[$0 * 4 + 1] + 0.0722 * pixels[$0 * 4 + 2] }
    }

    static func tone() {
        contrast()
        filmLight()
        clarity()
        sharpening()
    }

    /// The Sharpen slider isn't on the film's scene light (the film sharpens what it gets again), and its radius is in
    /// full-size pixels: a half-size render's edge is as wide, in full-size pixels, as the full-size render's.
    private static func sharpening() {
        let step = greyImage(400, 4) { x, _ in x < 200 ? 0.05 : 0.5 }
        var a = PhotoAdjustments()
        let plain = lumas(PhotoRender.adjusted(step, a, isRaw: true, kelvin: 6500, scene: true))
        a.sharpen = 100
        let scene = lumas(PhotoRender.adjusted(step, a, isRaw: true, kelvin: 6500, scene: true))
        check("sharpen not on the film's scene", zip(plain, scene).allSatisfy { abs($0 - $1) < 1e-4 }, "the scene light is the same with Sharpen at 100")
        // How far either side of the step the sharpening reaches, in full-size pixels.
        func reach(_ width: Int, scale: Double) -> Double {
            let image = greyImage(width, 4) { x, _ in x < width / 2 ? 0.05 : 0.5 }
            let row = Array(lumas(PhotoRender.sharpened(image, 100, scale: scale, fullLongEdge: 6000)).prefix(width))
            let changed = row.indices.filter { x in abs(row[x] - (x < width / 2 ? 0.05 : 0.5)) > 0.002 }
            return Double((changed.max() ?? 0) - (changed.min() ?? 0) + 1) / scale
        }
        let full = reach(400, scale: 1), half = reach(200, scale: 0.5)
        check("sharpen the same at any size", full > 0 && abs(half - full) <= max(4, full * 0.5),
              "edge halo \(full) full-size pixels at full size, \(half) at half size")
    }

    /// With the film on, every light control still reaches the scene light the film is made from: each moves its end
    /// of a ramp (5 stops under mid grey to 3 over) the right way; the curves change the film's picture.
    private static func filmLight() {
        let width = 321
        let ramp = greyImage(width, 4) { x, _ in 0.18 * pow(2, Float(x - 200) / 40) }
        func row(_ change: (inout PhotoAdjustments) -> Void) -> [Float] {
            var a = PhotoAdjustments()
            change(&a)
            return Array(lumas(PhotoRender.adjusted(ramp, a, isRaw: true, kelvin: 6500, scene: true)).prefix(width))
        }
        let plain = row { _ in }
        // (column, which way +50 moves it): 0 the dark end, 320 the bright end.
        let sliders: [(String, WritableKeyPath<PhotoAdjustments, Double>, Int)] = [
            ("whites", \.whites, 320), ("blacks", \.blacks, 0), ("highlights", \.highlights, 320), ("shadows", \.shadows, 0),
        ]
        for (name, path, column) in sliders {
            let up = row { $0[keyPath: path] = 50 }, down = row { $0[keyPath: path] = -50 }
            func stops(_ r: [Float]) -> Float { log2(max(r[column], 1e-9) / max(plain[column], 1e-9)) }
            check("\(name) with film", stops(up) > 0.1 && stops(down) < -0.1 && (1..<width).allSatisfy { up[$0] > up[$0 - 1] && down[$0] > down[$0 - 1] },
                  "+50 brighter, −50 darker by over 0.1 stop at its end, still rising; got \(stops(up)), \(stops(down))")
        }
        let brighter = row { $0.exposure = 1 }
        check("exposure with film", abs(log2(max(brighter[200], 1e-9) / max(plain[200], 1e-9)) - 1) < 0.1, "+1 stop at mid grey; got \(brighter[200]) from \(plain[200])")

        // The curves on the film's picture: the middle lifted.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-filmcurve-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("grey.jpg")
        guard (try? PhotoEngine.context.writeJPEGRepresentation(of: greyImage(600, 400) { _, _ in 0.18 }, to: url,
                                                              colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])) != nil
        else { return check("curves with film", false, "a test photo written") }
        var record = PhotoRecord()
        record.filmOn = true
        record.film.film = "kodak_portra_400"; record.film.paper = "kodak_portra_endura"
        record.film.changed = ["scan_film": .number(0)]
        var lifted = record
        lifted.adjust.curves.master = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.7), CurvePoint(x: 1, y: 1)]
        func mean(_ r: PhotoRecord) -> Float? {
            guard let image = PhotoRender.image(url.path, record: r, maxSize: 600) else { return nil }
            let values = lumas(image)
            return values.reduce(0, +) / Float(max(values.count, 1))
        }
        let before = mean(record), after = mean(lifted)
        check("curves with film", (after ?? 0) > (before ?? 1) * 1.15, "the middle lifted on the film's picture; got \(String(describing: before)) → \(String(describing: after))")
    }

    /// Contrast is an S-curve around mid grey, as in Lightroom: plus steepens the middle, minus flattens it, mid grey
    /// stays, the ramp keeps rising (nothing clips flat); with the film on as well (the film's scene light).
    private static func contrast() {
        // A ramp from 5 stops under mid grey to 3 over, 40 columns a stop (column 200: mid grey).
        let width = 321
        let ramp = greyImage(width, 4) { x, _ in 0.18 * pow(2, Float(x - 200) / 40) }
        for film in [false, true] {
            func row(_ amount: Double) -> [Float] {
                var a = PhotoAdjustments()
                a.contrast = amount
                return Array(lumas(PhotoRender.adjusted(ramp, a, isRaw: true, kelvin: 6500, scene: film)).prefix(width))
            }
            let plain = row(0), more = row(50), less = row(-50)
            // The slope around mid grey (half a stop either way), in stops out per stop in.
            func slope(_ r: [Float]) -> Float { (log2(max(r[220], 1e-6)) - log2(max(r[180], 1e-6))) }
            let name = film ? "contrast with film" : "contrast"
            check("\(name) steepens and flattens the middle", slope(more) > slope(plain) * 1.15 && slope(less) < slope(plain) * 0.88,
                  "slope +50 > 1.15×, −50 < 0.88× the plain \(slope(plain)); got \(slope(more)), \(slope(less))")
            check("\(name) keeps mid grey", [more, less].allSatisfy { abs(log2(max($0[200], 1e-6) / max(plain[200], 1e-6))) < 0.1 },
                  "within 0.1 stop of \(plain[200]); got \(more[200]), \(less[200])")
            let rising = [plain, more, less].allSatisfy { r in (1..<r.count).allSatisfy { r[$0] > r[$0 - 1] } }
            check("\(name) keeps the ramp rising", rising, "every step brighter than the one before, no flat (clipped) run")
        }
    }

    /// Clarity changes the local contrast the same everywhere: the four corners and the middle, small and large
    /// (a preview with its layers kept, a full-size render without), and as the Photo page shows a photo (preview and
    /// 100 %, film off and on).
    private static func clarity() {
        // The log brightness's spread in five patches of a picture: the corners and the middle.
        func spread(_ image: CIImage) -> [Float] {
            let out = lumas(image)
            let width = Int(image.extent.integral.width), height = Int(image.extent.integral.height), side = 48
            let patches = [(0, 0), (width - side, 0), (0, height - side), (width - side, height - side), ((width - side) / 2, (height - side) / 2)]
            return patches.map { x0, y0 in
                var values: [Float] = []
                for y in y0..<(y0 + side) { for x in x0..<(x0 + side) { values.append(log2(max(out[y * width + x], 1e-6))) } }
                let mean = values.reduce(0, +) / Float(values.count)
                return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(values.count)).squareRoot()
            }
        }
        func even(_ name: String, _ plain: CIImage?, _ more: CIImage?) {
            guard let plain, let more else { return check("clarity reaches the whole picture (\(name))", false, "the pictures to render") }
            let gains = zip(spread(more), spread(plain)).map { $0 / max($1, 1e-6) }
            let low = gains.min() ?? 0, high = gains.max() ?? 0
            check("clarity reaches the whole picture (\(name))", low > 1.1 && high / max(low, 1e-6) < 1.15,
                  "the same gain over 1.1 in the corners and the middle; got \(gains)")
        }
        // A fine texture around mid grey, the same all over.
        func texture(_ x: Int, _ y: Int) -> Float { ((x / 3 + y / 3) % 2 == 0) ? 0.12 : 0.27 }
        var clear = PhotoAdjustments()
        clear.clarity = 100
        for (width, height, key) in [(900, 600, "selftest-clarity-preview"), (4800, 3200, nil)] as [(Int, Int, String?)] {
            let image = greyImage(width, height, texture)
            func render(_ a: PhotoAdjustments) -> CIImage {
                PhotoRender.adjusted(image, a, isRaw: true, kelvin: 6500, cacheKey: key.map { $0 + "-\(width)" })
            }
            even("\(width) wide", render(PhotoAdjustments()), render(clear))
        }
        // The bright and dark parts too, not only the middle tones: the same texture 3 stops under mid grey, at it, and
        // 3 over (a sky), side by side.
        let bands = greyImage(900, 300) { x, y in texture(x, y) * pow(2, Float(x / 300 * 3 - 3)) }
        func band(_ image: CIImage) -> [Float] {
            let out = lumas(image)
            return [0, 1, 2].map { i in
                var values: [Float] = []
                for y in 126..<174 { for x in (i * 300 + 126)..<(i * 300 + 174) { values.append(log2(max(out[y * 900 + x], 1e-6))) } }
                let mean = values.reduce(0, +) / Float(values.count)
                return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(values.count)).squareRoot()
            }
        }
        let toneGains = zip(band(PhotoRender.adjusted(bands, clear, isRaw: true, kelvin: 6500)),
                            band(PhotoRender.adjusted(bands, PhotoAdjustments(), isRaw: true, kelvin: 6500))).map { $0 / max($1, 1e-6) }
        check("clarity reaches the shadows and highlights", toneGains.allSatisfy { $0 > 1.1 } && (toneGains.min() ?? 0) > 0.9 * (toneGains.max() ?? 1),
              "gains over 1.1, within 10% of each other (−3, 0, +3 stops); got \(toneGains)")
        // A photo on the page: a preview and 100 % (only what's on screen worked out), without film and with it.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-clarity-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("texture.jpg")
        guard (try? PhotoEngine.context.writeJPEGRepresentation(of: greyImage(3000, 2000, texture), to: url, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                              options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.95])) != nil
        else { return check("clarity reaches the whole picture (photo)", false, "a test photo written") }
        for film in [false, true] {
            var plain = PhotoRecord()
            if film {
                plain.filmOn = true
                plain.film.film = "kodak_portra_400"; plain.film.paper = "kodak_portra_endura"
                plain.film.changed = ["scan_film": .number(0)]
            }
            var more = plain
            more.adjust = clear
            for size in [PhotoRender.previewSize, 0] {
                even("\(film ? "film, " : "")\(size == 0 ? "100 %" : "preview")",
                     PhotoRender.image(url.path, record: plain, maxSize: size), PhotoRender.image(url.path, record: more, maxSize: size))
            }
        }
    }
}
