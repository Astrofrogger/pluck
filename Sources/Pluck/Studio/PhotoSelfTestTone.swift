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
        shadowBlotches()
        lightroomShadows()
        lightroomHighlights()
    }

    /// Version 3's Highlights −100 as Lightroom's (measured on a RAW against Lightroom's −100: Pluck's darkened the upper
    /// mid-tones 0.3 stop more and kept the brightest coloured, a flat shoulder), and a coloured ramp rolling into white
    /// smoothly: always brighter, no flat run, its colour fading towards white and its hue held.
    private static func lightroomHighlights() {
        // −1 to +6 stops from mid grey across 350 pixels.
        let n = 350
        func row(_ tint: SIMD3<Float>, _ highlights: Double) -> [(L: Double, C: Double, h: Double)] {
            let ramp = greyImage(n, 4) { x, _ in 0.18 * exp2(Float(x) / 50 - 1) }.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(tint.x), y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: CGFloat(tint.y), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(tint.z), w: 0)])
            var a = PhotoAdjustments(); a.process = 3; a.profile = .adobe; a.highlights = highlights
            var px = [Float](repeating: 0, count: n * 4)
            px.withUnsafeMutableBytes {
                PhotoEngine.context.render(PhotoRender.output(PhotoRender.adjusted(ramp, a, isRaw: true, kelvin: 6500), a, p3: false), toBitmap: $0.baseAddress!,
                                           rowBytes: n * 16, bounds: CGRect(x: 0, y: 0, width: n, height: 1), format: .RGBAf, colorSpace: linearSpace)
            }
            return (0..<n).map { i in
                let (L, x, y) = OkLab.from(Double(px[i * 4]), Double(px[i * 4 + 1]), Double(px[i * 4 + 2]))
                return (L, (x * x + y * y).squareRoot(), atan2(y, x) * 180 / .pi)
            }
        }
        let grey = SIMD3<Float>(1, 1, 1), plain = row(grey, 0), pulled = row(grey, -100), twice = row(grey, -200)
        // Where Highlights 0 is at Lightroom's upper mid-tones (OkLab L 0.85-0.92).
        let upper = (0..<n).filter { plain[$0].L > 0.85 && plain[$0].L < 0.92 }
        func ratio(_ r: [(L: Double, C: Double, h: Double)]) -> Double { upper.map { r[$0].L / plain[$0].L }.reduce(0, +) / Double(max(upper.count, 1)) }
        note("highlights −100: upper mid-tones \(ratio(pulled)) of Highlights 0 (twice as strong: \(ratio(twice)))")
        check("highlights −100 like lightroom's", !upper.isEmpty && ratio(pulled) > 0.95 && ratio(pulled) < 0.995,
              "the upper mid-tones at −100 within 5% of their brightness at 0 (OkLab L), yet darker; got \(ratio(pulled)) (twice as strong: \(ratio(twice)))")
        for (name, tint) in [("warm", SIMD3<Float>(1.0, 0.72, 0.42)), ("cool", SIMD3<Float>(0.55, 0.78, 1.0))] {
            let r = row(tint, -100)
            let flat = (10..<n).first { r[$0].L < 0.99 && r[$0].L <= r[$0 - 10].L + 1e-4 }
            let top = r.indices.filter { r[$0].C > 0.02 && r[$0].L > 0.6 }, peak = r.map(\.C).max() ?? 0
            let hues = top.map { r[$0].h }, spread = (hues.max() ?? 0) - (hues.min() ?? 0)
            note("\(name) highlights: flat at \(String(describing: flat)), last \(r[n - 1]), most chroma \(peak), hue spread \(spread)")
            check("\(name) highlights roll into white", flat == nil && r[n - 1].C < 0.3 * peak && spread < 8,
                  "always brighter until white, the colour fading (last under 0.3 of its most, \(peak)), its hue within 8°; got flat at \(String(describing: flat)), last \(r[n - 1]), hue spread \(spread)")
        }
    }

    /// Version 3's Shadows as Lightroom's: +100 lifts a lot, the lower mid-tones too, and what it lifts comes up less
    /// colourful (once 1 stop short of Lightroom on a real RAW, with the lifted warm floor deep orange-green). Version 2
    /// exactly as it was.
    private static func lightroomShadows() {
        // Stops from mid grey, −6 to +2 across 400 pixels.
        let ramp = greyImage(400, 4) { x, _ in 0.18 * exp2(Float(x) / 50 - 6) }
        func row(_ process: Int, _ change: (inout PhotoAdjustments) -> Void) -> [Float] {
            var a = PhotoAdjustments(); a.process = process; a.profile = .adobe; change(&a)
            return Array(lumas(PhotoRender.adjusted(ramp, a, isRaw: true, kelvin: 6500)).prefix(400))
        }
        let plain = row(3) { _ in }, lifted = row(3) { $0.shadows = 100 }
        func gain(_ x: Int) -> Float { log2(max(lifted[x], 1e-9) / max(plain[x], 1e-9)) }
        // (Neighbours may tie in half floats where it's flattest; over a fifth of a stop it must rise.)
        let turn = (10..<400).first { lifted[$0] < lifted[$0 - 1] || lifted[$0] <= lifted[$0 - 10] }.map { ($0, lifted[$0 - 10], lifted[$0]) }
        check("shadows lift like lightroom's", gain(100) > 2.4 && gain(200) > 2.0 && gain(300) < 0.6 && turn == nil,
              "+100 lifts −4 stops over 2.4 stops and −2 over 2, mid grey under 0.6, the ramp still rising; got \(gain(100)), \(gain(200)), \(gain(300)), turning at \(String(describing: turn))")

        // A dark, deep warm floor (as on the RAW), lifted: less colourful than the same light brought up with Exposure alone,
        // as Lightroom (blue to green 0.33 there on the RAW's floor, 0.08 when lifted with its colour kept whole).
        let warm = SIMD3<Float>(0.0062, 0.0026, 0.0004)
        var pixels = [Float](repeating: 1, count: 64 * 64 * 4)
        for i in 0..<(64 * 64) { pixels[i * 4] = warm.x; pixels[i * 4 + 1] = warm.y; pixels[i * 4 + 2] = warm.z }
        let floor = CIImage(bitmapData: pixels.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: 64 * 16, size: CGSize(width: 64, height: 64),
                            format: .RGBAf, colorSpace: linearSpace)
        func ratios(_ change: (inout PhotoAdjustments) -> Void) -> (r: Float, b: Float) {
            var a = PhotoAdjustments(); a.profile = .adobe; a.exposure = 2.25; change(&a)
            var px = [Float](repeating: 0, count: 4)
            let out = PhotoRender.output(PhotoRender.adjusted(floor, a, isRaw: true, kelvin: 6500), a, p3: false)
            px.withUnsafeMutableBytes {
                PhotoEngine.context.render(out, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: 32, y: 32, width: 1, height: 1), format: .RGBAf, colorSpace: linearSpace)
            }
            return (px[0] / max(px[1], 1e-9), px[2] / max(px[1], 1e-9))
        }
        let shadowed = ratios { $0.shadows = 100 }, exposed = ratios { $0.exposure += 2.3 }
        check("lifted dark colours less colourful", shadowed.b > exposed.b + 0.08 && shadowed.r < exposed.r - 0.2,
              "blue to green over 0.08 higher and red 0.2 lower than Exposure alone; got \(shadowed) against \(exposed)")

        // Version 2: the same numbers as before version 3's Shadows.
        let old = row(2) { $0.shadows = 100; $0.highlights = -100 }
        let was: [Float] = [0.028533937, 0.04269409, 0.09729004, 0.24643402, 0.45356137]
        let now = [50, 100, 200, 300, 380].map { old[$0] }
        check("process 2 shadows unchanged", zip(now, was).allSatisfy { abs($0 - $1) <= 1e-4 * $1 },
              "version 2's ramp at Shadows +100, Highlights −100 as before: \(was); got \(now)")

        // Auto on a photo mostly in the lower mid-tones with a deep corner (its 5% darkest 7 stops under): the same Shadows
        // number lifts what's under mid grey about as much in version 3 as in version 2 (version 3's lift follows a coarser
        // base, see liftBase), so Auto's numbers still hold.
        func stop(_ i: Int) -> Float {
            if i < 60 { return -8 + Float(i) / 30 }
            return i < 330 ? -2.5 + Float(i - 60) / 108 : Float(i - 330) / 135
        }
        let stops = (0..<600).map(stop)
        let light = stops.map { 0.18 * exp2($0) }
        let deep = greyImage(600, 4) { x, _ in light[x] }
        let auto2 = PhotoEngine.auto(luminance: light, width: 600, height: 1, faces: [])
        func lift(_ process: Int, _ shadows: Double) -> Float {
            func toned(_ s: Double) -> [Float] {
                var a = PhotoAdjustments(); a.process = process; a.profile = .neutral; a.exposure = auto2.exposure; a.shadows = s
                return Array(lumas(PhotoRender.adjusted(deep, a, isRaw: true, kelvin: 6500)).prefix(600))
            }
            let up = toned(shadows), plain = toned(0)
            let under = (0..<600).filter { Double(stops[$0]) + auto2.exposure < 0 && plain[$0] > 1e-5 }
            return under.map { log2(max(up[$0], 1e-9) / plain[$0]) }.reduce(0, +) / Float(max(under.count, 1))
        }
        let was2 = lift(2, auto2.shadows), now3 = lift(3, auto2.shadows)
        check("auto shadows as before", auto2.shadows > 20 && abs(now3 - was2) < 0.15 * was2,
              "Auto's Shadows (\(auto2.shadows)) lifts under mid grey in version 3 within 15% of version 2's \(was2) stops; got \(now3)")

        // Something bright with folds (plastic over a pot, on a RAW): Shadows +100 lifts the place, not the folds' shadows,
        // which keep most of their depth (lifted by their own darkness, they once all but went); and near-white stays
        // neutral through Highlights −100 and the gamut mapping.
        let folds = greyImage(512, 64) { x, _ in x % 32 < 4 ? 0.09 : 0.255 }
        func depth(_ shadows: Double) -> Float {
            var a = PhotoAdjustments(); a.profile = .adobe; a.shadows = shadows; a.highlights = -100
            let row = Array(lumas(PhotoRender.adjusted(folds, a, isRaw: true, kelvin: 6500)).prefix(512))
            let crease = (1..<15).map { row[$0 * 32 + 2] }, place = (1..<15).map { row[$0 * 32 + 18] }
            return log2(place.reduce(0, +) / max(crease.reduce(0, +), 1e-9))
        }
        let unlifted = depth(0), foldsLifted = depth(100)
        check("lifted folds keep their shadows", foldsLifted >= 0.6 * unlifted, "a fold's depth at Shadows +100 at least 60% of \(unlifted) stops; got \(foldsLifted)")
        var white = PhotoAdjustments(); white.profile = .adobe; white.exposure = 2.25; white.highlights = -100; white.shadows = 100
        let greys = greyImage(4, 4) { x, _ in [0.05, 0.3, 1, 3][x] }
        var px = [Float](repeating: 0, count: 16 * 4)
        px.withUnsafeMutableBytes {
            PhotoEngine.context.render(PhotoRender.output(PhotoRender.adjusted(greys, white, isRaw: true, kelvin: 6500), white, p3: false), toBitmap: $0.baseAddress!,
                                       rowBytes: 4 * 16, bounds: CGRect(x: 0, y: 0, width: 4, height: 4), format: .RGBAf, colorSpace: linearSpace)
        }
        let tints = (0..<4).map { x in (px[x * 4] - px[x * 4 + 1]) / max(px[x * 4 + 1], 1e-6) + (px[x * 4 + 2] - px[x * 4 + 1]) / max(px[x * 4 + 1], 1e-6) }
        check("near white stays neutral", tints.allSatisfy { abs($0) < 0.01 }, "greys up to past white neutral within 1%; got \(tints)")
        // A slightly lavender white (the plastic's), from bright to far past white: white once past it.
        let lavender = greyImage(4, 4) { x, _ in [8, 32, 128, 512][x] }.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1.02, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.97, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 1.06, w: 0)])
        px.withUnsafeMutableBytes {
            PhotoEngine.context.render(PhotoRender.output(PhotoRender.adjusted(lavender, white, isRaw: true, kelvin: 6500), white, p3: false), toBitmap: $0.baseAddress!,
                                       rowBytes: 4 * 16, bounds: CGRect(x: 0, y: 0, width: 4, height: 4), format: .RGBAf, colorSpace: linearSpace)
        }
        let spread = (0..<4).map { x in (max(px[x * 4], px[x * 4 + 1], px[x * 4 + 2]) - min(px[x * 4], px[x * 4 + 1], px[x * 4 + 2])) / max(px[x * 4 + 1], 1e-6) }
        check("tinted white past white is white", spread[2] < 0.01 && spread[3] < 0.01 && spread[1] <= spread[0] + 1e-3,
              "a lavender white fades to white past the curve's white; got \(spread)")
    }

    /// Lifting the shadows of a flat, noisy dark patch keeps its noise as it is, as in Lightroom: no colour cast and no
    /// more colour blotches than the same brightness reached with Exposure (the local tone's gain once followed each
    /// pixel's noise: the darker, mostly low-green specks were lifted more, which turned into magenta and green patches).
    /// And a sharp edge stays clean either side (no halo).
    private static func shadowBlotches() {
        let width = 1200, height = 800
        var seed: UInt64 = 12345
        func uniform() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(seed >> 40) / Float(1 << 24) + 1e-7 }
        func gauss() -> Float { (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform()) }
        // 6 stops under mid grey, each channel's noise about a third of it.
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for i in 0..<(width * height) { for c in 0..<3 { pixels[i * 4 + c] = 0.18 / 64 + 0.0009 * gauss() } }
        let image = CIImage(bitmapData: pixels.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: width * 16,
                            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: linearSpace)
        // In 16-pixel blocks of the middle: the mean brightness, red and blue against it, and how much those vary.
        func blotches(_ a: PhotoAdjustments) -> (y: Float, r: Float, b: Float, spread: Float) {
            let out = PhotoRender.adjusted(image, a, isRaw: true, kelvin: 6500)
            var px = [Float](repeating: 0, count: width * height * 4)
            px.withUnsafeMutableBytes {
                PhotoEngine.context.render(out, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: out.extent.integral, format: .RGBAf, colorSpace: linearSpace)
            }
            var ys: [Float] = [], rs: [Float] = [], bs: [Float] = []
            for by in 0..<30 { for bx in 0..<45 {
                var r: Float = 0, g: Float = 0, b: Float = 0
                for y in (by * 16 + 160)..<(by * 16 + 176) { for x in (bx * 16 + 240)..<(bx * 16 + 256) {
                    let i = (y * width + x) * 4; r += px[i]; g += px[i + 1]; b += px[i + 2]
                } }
                let Y = max(0.2126 * r + 0.7152 * g + 0.0722 * b, 1e-9)
                ys.append(Y / 256); rs.append(r / Y); bs.append(b / Y)
            } }
            func mean(_ v: [Float]) -> Float { v.reduce(0, +) / Float(v.count) }
            func sd(_ v: [Float]) -> Float { let m = mean(v); return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Float(v.count)).squareRoot() }
            return (mean(ys), mean(rs), mean(bs), (sd(rs) + sd(bs)) / 2)
        }
        var lift = PhotoAdjustments()
        lift.shadows = 100
        let lifted = blotches(lift)
        // Exposure to the same brightness (found by halving the gap).
        var low = 0.0, high = 8.0, exposed = blotches(PhotoAdjustments())
        for _ in 0..<12 {
            var a = PhotoAdjustments()
            a.exposure = (low + high) / 2
            exposed = blotches(a)
            if exposed.y < lifted.y { low = a.exposure } else { high = a.exposure }
        }
        check("lifted shadows keep their colour", abs(lifted.r - exposed.r) < 0.015 && abs(lifted.b - exposed.b) < 0.015 && lifted.spread < exposed.spread * 1.25,
              "red, blue within 0.015 and blotches under 1.25× of Exposure to the same brightness; got \(lifted) against \(exposed)")
        let step = greyImage(400, 4) { x, _ in x < 200 ? 0.18 / 64 : 0.36 }
        let row = Array(lumas(PhotoRender.adjusted(step, lift, isRaw: true, kelvin: 6500)).prefix(400)).map { log2(max($0, 1e-9)) }
        check("lifted shadows keep a clean edge", (190..<200).allSatisfy { abs(row[$0] - row[185]) < 0.05 } && (200..<210).allSatisfy { abs(row[$0] - row[215]) < 0.05 },
              "either side of the edge within 0.05 stop of 15 pixels away; got \(Array(row[185...215]))")
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
                // (Neutral: Classic's curve is nearly flat by white, under a half float's step per column.)
                a.profile = .neutral
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
        // (On Neutral's curve: Classic's own contrast differs from stop to stop.)
        var plainNeutral = PhotoAdjustments(), clearNeutral = clear
        plainNeutral.profile = .neutral; clearNeutral.profile = .neutral
        let toneGains = zip(band(PhotoRender.adjusted(bands, clearNeutral, isRaw: true, kelvin: 6500)),
                            band(PhotoRender.adjusted(bands, plainNeutral, isRaw: true, kelvin: 6500))).map { $0 / max($1, 1e-6) }
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
