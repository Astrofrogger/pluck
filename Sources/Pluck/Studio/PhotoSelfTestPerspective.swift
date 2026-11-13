import CoreImage
import Foundation

/// Perspective (-PluckScreenshotOnly perspective): untouched changes nothing (render, saved settings, preview key), Vertical
/// makes converging uprights parallel, Level levels a tilted horizon, a strong keystone leaves no empty corners, and the
/// settings are saved, undone and pasted with the crop.
extension PhotoSelfTest {
    static func perspective() async {
        let context = PhotoEngine.context
        let w = 900.0, h = 600.0
        let frame = CGRect(x: 0, y: 0, width: w, height: h)
        func cg(_ image: CIImage) -> CGImage? { context.createCGImage(image, from: frame) }
        func floats(_ image: CIImage) -> [Float] {
            var p = [Float](repeating: 0, count: Int(w * h) * 4)
            context.render(image, toBitmap: &p, rowBytes: Int(w) * 16, bounds: frame, format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
            return p
        }

        // Untouched: the same render, the same saved settings, the same preview key.
        let ramp = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: w, y: h),
                                                                   "inputColor0": CIColor(red: 0.1, green: 0.2, blue: 0.3), "inputColor1": CIColor(red: 0.9, green: 0.8, blue: 0.5)])!
            .outputImage!.cropped(to: frame)
        var plain = PhotoAdjustments()
        plain.exposure = 0.3; plain.straighten = 2
        var zeroed = plain
        zeroed.perspective = PhotoPerspective()
        check("perspective: untouched is none", zeroed.perspective == nil && zeroed == plain, "\(String(describing: zeroed.perspective))")
        check("perspective: untouched, the same render",
              floats(PhotoRender.adjusted(ramp, plain, isRaw: false, kelvin: 6500)) == floats(PhotoRender.adjusted(ramp, zeroed, isRaw: false, kelvin: 6500)))
        let saved = (try? JSONEncoder().encode(plain)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check("perspective: untouched, nothing saved", !saved.contains("perspective") && PhotoSelfTest.sameJSON(zeroed, plain), saved)
        var record = PhotoRecord(), recordZeroed = PhotoRecord()
        record.adjust = plain; recordZeroed.adjust = zeroed
        check("perspective: untouched, the same preview key",
              PhotoRender.cachedPreview("/tmp/pluck-selftest/persp.jpg", record: record) == PhotoRender.cachedPreview("/tmp/pluck-selftest/persp.jpg", record: recordZeroed))
        let old = try? JSONDecoder().decode(PhotoAdjustments.self, from: Data(#"{"exposure":0.5,"straighten":1.5,"process":6,"masks":[]}"#.utf8))
        check("perspective: old settings read", old?.straighten == 1.5 && old?.perspective == nil, "\(String(describing: old))")

        // Vertical: uprights leaning in towards the top (a camera tilted up), turned 2° too, end up upright and parallel.
        let paper = CIImage(color: CIColor(red: 0.8, green: 0.8, blue: 0.78))
        var leaning = paper.cropped(to: frame)
        for i in 0..<7 {
            let bottom = 120 + Double(i) * 110, top = w / 2 + (bottom - w / 2) * 0.75
            let bar = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.12)).cropped(to: CGRect(x: -4, y: 0, width: 8, height: hypot(top - bottom, h)))
                .transformed(by: CGAffineTransform(translationX: bottom, y: 0).rotated(by: -atan2(top - bottom, h)))
            leaning = bar.composited(over: leaning)
        }
        leaning = leaning.cropped(to: frame).transformed(by: CGAffineTransform(translationX: w / 2, y: h / 2).rotated(by: 2 * .pi / 180)
            .translatedBy(x: -w / 2, y: -h / 2)).composited(over: paper).cropped(to: frame)
        func spread(_ image: CIImage) -> (count: Int, worst: Double) {
            guard let picture = cg(image), let r = PhotoPerspective.read(picture) else { return (0, 99) }
            // The bars' edges (the strongest lines; the rest are the Hough's echoes beside them).
            let strongest = r.vertical.map(\.weight).max() ?? 0
            let edges = r.vertical.filter { $0.weight >= strongest / 2 }
            return (edges.count, edges.map { abs(PhotoPerspective.lean($0.a, $0.b)) }.max() ?? 99)
        }
        let before = spread(leaning)
        if let picture = cg(leaning), let r = PhotoPerspective.read(picture),
           let found = PhotoPerspectiveAuto.found(.vertical, r, keeping: PhotoPerspective()) {
            var a = PhotoAdjustments()
            a.straighten = found.turn
            a.perspective = found.perspective
            let after = spread(PhotoRender.geometry(leaning, a))
            check("perspective: Vertical makes uprights parallel", before.worst > 5 && after.count >= 10 && after.worst <= 0.5,
                  "leaning up to \(before.worst)° → within 0.5° (\(after.count) edges); got \(after.worst)°, turn \(found.turn), vertical \(found.perspective.vertical)")
            check("perspective: Vertical turns back the 2°", abs(found.turn + 2) <= 0.5, "−2; got \(found.turn)")
        } else {
            check("perspective: Vertical finds the uprights", false, "nothing found")
        }

        // Level: a horizon rising 4° to the right is turned back within 0.5° (Vision, and the lines without it).
        let sky = CIImage(color: CIColor(red: 0.55, green: 0.7, blue: 0.95)).cropped(to: frame)
        let ground = CIImage(color: CIColor(red: 0.25, green: 0.3, blue: 0.15)).cropped(to: CGRect(x: -w, y: -2 * h, width: 3 * w, height: 2.5 * h))
            .transformed(by: CGAffineTransform(translationX: w / 2, y: h / 2).rotated(by: 4 * .pi / 180).translatedBy(x: -w / 2, y: -h / 2))
        if let picture = cg(ground.composited(over: sky).cropped(to: frame)), var r = PhotoPerspective.read(picture) {
            let found = PhotoPerspectiveAuto.found(.level, r, keeping: PhotoPerspective())?.turn
            check("perspective: Level levels the horizon", found.map { abs($0 + 4) <= 0.5 } ?? false, "−4°; got \(String(describing: found)) (Vision \(String(describing: r.horizon)))")
            r.horizon = nil
            let lines = PhotoPerspective.level(r)
            check("perspective: Level from the lines alone", lines.map { abs($0 + 4) <= 0.5 } ?? false, "−4°; got \(String(describing: lines))")
        } else {
            check("perspective: Level reads the picture", false)
        }

        // A strong keystone (both ways, and stretched): the corners are still picture.
        var strong = PhotoAdjustments()
        strong.straighten = 8
        var p = PhotoPerspective()
        p.vertical = 100; p.horizontal = -100; p.aspect = 60
        strong.perspective = p
        let warped = PhotoRender.geometry(CIImage(color: .white).cropped(to: frame), strong)
        let pixels = floats(warped)
        let corners = [0, Int(w) - 1, Int(w * (h - 1)), Int(w * h) - 1].map { pixels[$0 * 4 + 3] }
        check("perspective: no empty corners", warped.extent == frame && corners.allSatisfy { $0 > 0.99 }, "alpha 1 at \(frame); got \(corners) at \(warped.extent)")
        var both = p
        both.vertical = -100; both.horizontal = 100; both.aspect = -100
        let other = floats(both.warped(CIImage(color: .white).cropped(to: frame)))
        check("perspective: no empty corners the other way", [0, Int(w) - 1, Int(w * (h - 1)), Int(w * h) - 1].allSatisfy { other[$0 * 4 + 3] > 0.99 })

        // Saved and read back, one undo step, and pasted with the crop (not without it).
        let path = "/tmp/pluck-selftest/persp-\(UUID().uuidString).jpg"
        let catalog = PhotoCatalog.shared
        var set = PhotoPerspective()
        set.vertical = 22; set.horizontal = -7; set.aspect = 5; set.scale = 110
        catalog.endStep()
        catalog.update([path]) { $0.adjust.exposure = 0.25 }
        catalog.endStep()
        catalog.update([path]) { $0.adjust.perspective = set }
        catalog.endStep()
        catalog.saveNow()
        let back = PhotoCatalog.readFile()?[path]
        check("perspective: saved and read back", back?.adjust.perspective == set, "\(String(describing: back?.adjust.perspective))")
        catalog.undo()
        check("perspective: one undo step", catalog.record(path).adjust.perspective == nil && catalog.record(path).adjust.exposure == 0.25)
        catalog.redo()
        let target = "/tmp/pluck-selftest/persp-other-\(UUID().uuidString).jpg"
        PhotoPasteboard.copy(path)
        PhotoPasteboard.paste(PasteGroup.chosen.subtracting([.crop]), to: [target])
        check("perspective: left out of a paste without the crop", catalog.record(target).adjust.perspective == nil)
        PhotoPasteboard.paste([.crop], to: [target])
        check("perspective: pasted with the crop", catalog.record(target).adjust.perspective == set)
    }
}
