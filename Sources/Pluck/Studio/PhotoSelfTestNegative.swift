import CoreImage
import Foundation

/// Film negatives (-PluckScreenshotOnly negative): none changes nothing (render, saved settings, preview key); a made-up
/// colour negative (a chart of greys and colours, each channel's density from the scene's log light with its own contrast,
/// on an orange base, inside an unexposed rebate) comes back with neutral greys in order; Auto and Pick Base find the base;
/// black-and-white gives equal channels; saved, one undo step, pasted with the light.
extension PhotoSelfTest {
    static func negative() async {
        let context = PhotoEngine.context
        let w = 600, h = 400
        let frame = CGRect(x: 0, y: 0, width: w, height: h)
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        func floats(_ image: CIImage) -> [Float] {
            var p = [Float](repeating: 0, count: w * h * 4)
            context.render(image, toBitmap: &p, rowBytes: w * 16, bounds: frame, format: .RGBAf, colorSpace: linear)
            return p
        }
        // The chart: greys on the top row, colours below, inside a rebate 4% wide.
        let greys: [Double] = [0, 0.02, 0.05, 0.1, 0.18, 0.35, 0.6, 1.0]
        let colours: [SIMD3<Double>] = [SIMD3(0.7, 0.08, 0.06), SIMD3(0.1, 0.5, 0.12), SIMD3(0.06, 0.1, 0.6), SIMD3(0.8, 0.7, 0.1),
                                        SIMD3(0.5, 0.32, 0.22), SIMD3(0.08, 0.45, 0.6), SIMD3(repeating: 0.18), SIMD3(repeating: 0.5)]
        let bx = 24, by = 16, cols = 8
        let pw = (w - 2 * bx) / cols, ph = (h - 2 * by) / 2
        let base = SIMD3<Double>(0.85, 0.55, 0.35), gamma = SIMD3<Double>(0.55, 0.62, 0.7)
        func scene(_ x: Int, _ y: Int) -> SIMD3<Double>? {
            guard x >= bx, x < bx + cols * pw, y >= by, y < by + 2 * ph else { return nil }
            let c = (x - bx) / pw
            return y - by < ph ? SIMD3(repeating: greys[c]) : colours[c]
        }
        var film = [Float](repeating: 1, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            // (Unexposed: the base. Exposed: denser with more light, each layer with its own contrast.)
            let d = scene(x, y).map { l in gamma * SIMD3(log10((l.x + 0.01) / 0.01), log10((l.y + 0.01) / 0.01), log10((l.z + 0.01) / 0.01)) }
                ?? SIMD3<Double>()
            for c in 0..<3 { film[(y * w + x) * 4 + c] = Float(base[c] * pow(10, -d[c])) }
        } }
        let negativeImage = CIImage(bitmapData: film.withUnsafeBytes { Data($0) }, bytesPerRow: w * 16, size: CGSize(width: w, height: h),
                                    format: .RGBAf, colorSpace: linear)
        func patch(_ p: [Float], col: Int, row: Int) -> SIMD3<Double> {
            let cx = bx + col * pw + pw / 2, cy = by + row * ph + ph / 2
            var s = SIMD3<Double>()
            for y in (cy - 2)...(cy + 2) { for x in (cx - 2)...(cx + 2) {
                let i = (y * w + x) * 4
                s += SIMD3(Double(p[i]), Double(p[i + 1]), Double(p[i + 2]))
            } }
            return s / 25
        }
        func chroma(_ c: SIMD3<Double>) -> Double { let o = OkLab.from(c.x, c.y, c.z); return (o.1 * o.1 + o.2 * o.2).squareRoot() }
        func near(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Bool { (0..<3).allSatisfy { abs(a[$0] - b[$0]) <= 0.05 * b[$0] } }

        // None: nothing saved, the same render and preview key; old settings read.
        var plain = PhotoAdjustments()
        plain.exposure = 0.3
        var none = plain
        none.negative = nil
        let saved = (try? JSONEncoder().encode(plain)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check("negative: none, nothing saved", !saved.contains("negative") && PhotoSelfTest.sameJSON(none, plain), saved)
        let fresh = try? JSONEncoder().encode(PhotoAdjustments())
        let again = fresh.flatMap { try? JSONDecoder().decode(PhotoAdjustments.self, from: $0) }.flatMap { try? JSONEncoder().encode($0) }
        check("negative: none, defaults unchanged", PhotoAdjustments().isDefault && fresh != nil && fresh == again
              && !String(decoding: fresh ?? Data(), as: UTF8.self).contains("negative"))
        check("negative: none, the same image and key", PhotoNegative.apply(nil, to: negativeImage) === negativeImage
              && PhotoNegative.key("k", nil) == "k" && PhotoNegative.key("k", PhotoNegative()) != "k")
        check("negative: none, the same render", floats(PhotoRender.adjusted(negativeImage, plain, isRaw: false, kelvin: 6500))
              == floats(PhotoRender.adjusted(negativeImage, none, isRaw: false, kelvin: 6500)))
        var record = PhotoRecord(), recordNone = PhotoRecord()
        record.adjust = plain; recordNone.adjust = none
        check("negative: none, the same preview key",
              PhotoRender.cachedPreview("/tmp/pluck-selftest/neg.jpg", record: record) == PhotoRender.cachedPreview("/tmp/pluck-selftest/neg.jpg", record: recordNone))
        let old = try? JSONDecoder().decode(PhotoAdjustments.self, from: Data(#"{"exposure":0.5,"process":6,"masks":[]}"#.utf8))
        check("negative: old settings read", old?.exposure == 0.5 && old?.negative == nil, "\(String(describing: old))")

        // Auto finds the base; Pick Base on the rebate too.
        let auto = PhotoNegative().auto(negativeImage)
        check("negative: Auto finds the base", near(auto.base, base), "\(base); got \(auto.base)")
        let picked = PhotoNegative().picked(negativeImage, at: CGPoint(x: 0.015, y: 0.5))
        check("negative: Pick Base finds the base", near(picked.base, base), "\(base); got \(picked.base)")

        // The positive: neutral greys, lighter stays lighter, red stays red.
        let positive = floats(PhotoNegative.apply(auto, to: negativeImage))
        let shown = greys.indices.map { patch(positive, col: $0, row: 0) }
        let worst = shown.map(chroma).max() ?? 1
        check("negative: greys come back neutral", worst < 0.02, "OkLab chroma under 0.02; got \(worst) (\(shown))")
        let lightness = shown.map { OkLab.from($0.x, $0.y, $0.z).0 }
        check("negative: greys stay in order", zip(lightness, lightness.dropFirst()).allSatisfy { $0 < $1 }, "\(lightness)")
        let red = patch(positive, col: 0, row: 1)
        check("negative: red stays red", red.x > red.y * 2 && red.x > red.z * 2, "\(red)")
        // The print: more Density darker, filtration towards red redder (on mid grey).
        var denser = auto, redder = auto
        denser.density = 50; redder.cyanRed = 50
        let mid = shown[4], darker = patch(floats(PhotoNegative.apply(denser, to: negativeImage)), col: 4, row: 0)
        let warmer = patch(floats(PhotoNegative.apply(redder, to: negativeImage)), col: 4, row: 0)
        check("negative: Density darkens the print", darker.y < mid.y * 0.9, "\(mid) → \(darker)")
        check("negative: Cyan–Red towards red", warmer.x > mid.x * 1.05 && abs(warmer.y - mid.y) < 1e-4, "\(mid) → \(warmer)")
        // Through the whole edit: still in order.
        var a = plain
        a.negative = auto
        let developed = floats(PhotoRender.adjusted(negativeImage, a, isRaw: false, kelvin: 6500))
        let developedL = greys.indices.map { i in let c = patch(developed, col: i, row: 0); return OkLab.from(c.x, c.y, c.z).0 }
        check("negative: in order through the whole edit", zip(developedL, developedL.dropFirst()).allSatisfy { $0 <= $1 } && developedL.last! > developedL.first! + 0.5,
              "\(developedL)")

        // Black and white: one channel.
        var mono = PhotoNegative()
        mono.kind = .blackAndWhite
        mono = mono.auto(negativeImage)
        let bw = floats(PhotoNegative.apply(mono, to: negativeImage))
        let spread = (0..<(w * h)).reduce(Float(0)) { max($0, abs(bw[$1 * 4] - bw[$1 * 4 + 1]), abs(bw[$1 * 4 + 1] - bw[$1 * 4 + 2])) }
        check("negative: black and white has equal channels", spread < 1e-4, "largest difference \(spread)")

        // Saved and read back, one undo step, pasted with the light (not without it), the section resets.
        let path = "/tmp/pluck-selftest/neg-\(UUID().uuidString).jpg"
        let catalog = PhotoCatalog.shared
        var set = auto
        set.density = 12; set.contrast = -20; set.yellowBlue = 8
        catalog.endStep()
        catalog.update([path]) { $0.adjust.exposure = 0.25 }
        catalog.endStep()
        catalog.update([path]) { $0.adjust.negative = set }
        catalog.endStep()
        catalog.saveNow()
        let back = PhotoCatalog.readFile()?[path]
        check("negative: saved and read back", back?.adjust.negative == set, "\(String(describing: back?.adjust.negative))")
        catalog.undo()
        check("negative: one undo step", catalog.record(path).adjust.negative == nil && catalog.record(path).adjust.exposure == 0.25)
        catalog.redo()
        let target = "/tmp/pluck-selftest/neg-other-\(UUID().uuidString).jpg"
        PhotoPasteboard.copy(path)
        PhotoPasteboard.paste(PasteGroup.chosen.subtracting([.light]), to: [target])
        check("negative: left out of a paste without the light", catalog.record(target).adjust.negative == nil)
        PhotoPasteboard.paste([.light], to: [target])
        check("negative: pasted with the light", catalog.record(target).adjust.negative == set)
        var reset = catalog.record(path).adjust
        check("negative: the section is edited", AdjustSection.negative.isEdited(reset))
        AdjustSection.negative.reset(&reset)
        check("negative: the section resets", reset.negative == nil && !AdjustSection.negative.isEdited(reset))
    }
}
