import CoreImage
import Foundation

/// Depth effects (-PluckScreenshotOnly depth): untouched changes nothing (render, saved settings, preview key); with a
/// made-up depth (near left half, far right half) and the focus near, the near half stays sharp and the far half blurs;
/// a sharp near edge keeps its contrast (no bleed from a bright background); fog lightens the far half more than the near;
/// without the depth finder nothing changes.
extension PhotoSelfTest {
    static func depth() async {
        let context = PhotoEngine.context
        let w = 800, h = 400
        let frame = CGRect(x: 0, y: 0, width: w, height: h)
        func floats(_ image: CIImage) -> [Float] {
            var p = [Float](repeating: 0, count: w * h * 4)
            context.render(image, toBitmap: &p, rowBytes: w * 16, bounds: frame, format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
            return p
        }
        // (Rows from the top; green channel.)
        func at(_ p: [Float], _ x: Int, _ y: Int) -> Float { p[(y * w + x) * 4 + 1] }
        /// Mean |difference| between neighbours across the columns, over the middle rows: fine detail kept.
        func detail(_ p: [Float], _ xs: Range<Int>) -> Float {
            var sum: Float = 0, n: Float = 0
            for y in 100..<300 { for x in xs { sum += abs(at(p, x + 1, y) - at(p, x, y)); n += 1 } }
            return sum / max(n, 1)
        }

        // A 2-pixel checker, dark on the near half, bright (highlights) on the far half.
        let checker = CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputCenter": CIVector(x: 0, y: 0), "inputColor0": CIColor(red: 1, green: 1, blue: 1), "inputColor1": CIColor(red: 0, green: 0, blue: 0),
            "inputWidth": 2, "inputSharpness": 1,
        ])!.outputImage!
        let near = checker.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.1, w: 0), "inputBiasVector": CIVector(x: 0.02, y: 0.02, z: 0.02, w: 0),
        ]).cropped(to: CGRect(x: 0, y: 0, width: w / 2, height: h))
        let far = checker.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1.5, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1.5, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1.5, w: 0), "inputBiasVector": CIVector(x: 0.3, y: 0.3, z: 0.3, w: 0),
        ]).cropped(to: CGRect(x: w / 2, y: 0, width: w / 2, height: h))
        let photo = near.composited(over: far).cropped(to: frame)
        // The made-up depth, at the map's own small size: 1 (nearest) on the left half, 0 on the right.
        let map = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
            .composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 200)))
            .cropped(to: CGRect(x: 0, y: 0, width: 400, height: 200))

        // Untouched: none, the same render, nothing saved, the same preview key; old settings read.
        var plain = PhotoAdjustments()
        plain.exposure = 0.3
        var zeroed = plain
        zeroed.depth = PhotoDepthEffects()
        check("depth: untouched is none", zeroed.depth == nil && zeroed == plain, "\(String(describing: zeroed.depth))")
        let original = floats(photo)
        check("depth: untouched, the same render", floats(PhotoRender.adjusted(photo, plain, isRaw: false, kelvin: 6500))
              == floats(PhotoRender.adjusted(photo, zeroed, isRaw: false, kelvin: 6500)))
        let saved = (try? JSONEncoder().encode(plain)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check("depth: untouched, nothing saved", !saved.contains("depth") && (try? JSONEncoder().encode(zeroed)) == (try? JSONEncoder().encode(plain)), saved)
        var record = PhotoRecord(), recordZeroed = PhotoRecord()
        record.adjust = plain; recordZeroed.adjust = zeroed
        check("depth: untouched, the same preview key",
              PhotoRender.cachedPreview("/tmp/pluck-selftest/depth.jpg", record: record) == PhotoRender.cachedPreview("/tmp/pluck-selftest/depth.jpg", record: recordZeroed))
        let old = try? JSONDecoder().decode(PhotoAdjustments.self, from: Data(#"{"exposure":0.5,"process":6,"masks":[]}"#.utf8))
        check("depth: old settings read", old?.exposure == 0.5 && old?.depth == nil, "\(String(describing: old))")
        var set = plain
        set.depth = PhotoDepthEffects(blur: 40, focus: 0.2, fog: 10, fogColour: .warm)
        let back = (try? JSONEncoder().encode(set)).flatMap { try? JSONDecoder().decode(PhotoAdjustments.self, from: $0) }
        check("depth: settings saved and read", back == set, "\(String(describing: back?.depth))")

        // Lens Blur, focus near: the near half keeps its detail, the far half loses it.
        var lens = PhotoDepthEffects()
        lens.blur = 100; lens.focus = 0; lens.range = 10
        let blurred = floats(lens.applied(to: photo, near: map))
        let nearKept = detail(blurred, 20..<380) / max(detail(original, 20..<380), 1e-6)
        let farKept = detail(blurred, 420..<780) / max(detail(original, 420..<780), 1e-6)
        check("depth: near half stays sharp", nearKept > 0.9, "kept \(nearKept) of the detail")
        check("depth: far half is blurred", farKept < 0.15, "kept \(farKept) of the detail")

        // No bleed: just inside the near half by the edge, the bright far half doesn't spill over; the edge keeps its step.
        var nearEdge: Float = 0, nearEdgeBefore: Float = 0, farEdge: Float = 0
        for y in 100..<300 {
            for x in (w / 2 - 8)..<(w / 2 - 2) { nearEdge += at(blurred, x, y); nearEdgeBefore += at(original, x, y) }
            for x in (w / 2 + 2)..<(w / 2 + 8) { farEdge += at(blurred, x, y) }
        }
        check("depth: no bleed over a sharp near edge", nearEdge <= nearEdgeBefore * 1.15,
              "near side by the edge \(nearEdge / 1200) (was \(nearEdgeBefore / 1200))")
        check("depth: the edge keeps its contrast", farEdge / max(nearEdge, 1e-6) > 8, "far \(farEdge / 1200) against near \(nearEdge / 1200)")
        // The same share of the picture blurred at half the size (a preview against the export).
        let half = photo.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: w / 2, height: h / 2))
        let small = lens.applied(to: half, near: map)
        var smallP = [Float](repeating: 0, count: (w / 2) * (h / 2) * 4)
        context.render(small, toBitmap: &smallP, rowBytes: (w / 2) * 16, bounds: CGRect(x: 0, y: 0, width: w / 2, height: h / 2), format: .RGBAf,
                       colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        var bigMean: Float = 0, smallMean: Float = 0
        for y in 50..<150 { for x in 210..<390 { smallMean += smallP[(y * (w / 2) + x) * 4 + 1]; bigMean += at(blurred, x * 2, y * 2) } }
        check("depth: a preview blurs as the export", abs(bigMean - smallMean) / max(bigMean, 1e-6) < 0.05, "\(smallMean / 18000) against \(bigMean / 18000)")

        // Fog: the far half lightens more than the near.
        let grey = CIImage(color: CIColor(red: 0.18, green: 0.18, blue: 0.18)).cropped(to: frame)
        var fog = PhotoDepthEffects()
        fog.fog = 60; fog.fogStart = 0
        let fogged = floats(fog.applied(to: grey, near: map)), unfogged = floats(grey)
        let nearLift = at(fogged, 100, 200) - at(unfogged, 100, 200), farLift = at(fogged, 700, 200) - at(unfogged, 700, 200)
        check("depth: fog lightens far more than near", farLift > 0.2 && abs(nearLift) < 0.01, "near +\(nearLift), far +\(farLift)")

        // Without the depth finder (no map): the same photo and key, through the whole develop too.
        let without = PhotoDepthEffects.applied(lens, to: photo, key: "k", path: nil, base: photo, context: context)
        check("depth: without the model, no change", without.image === photo && without.key == "k")
        var withLens = plain
        withLens.depth = lens
        check("depth: without the model, the same render", floats(PhotoRender.adjusted(photo, withLens, isRaw: false, kelvin: 6500))
              == floats(PhotoRender.adjusted(photo, plain, isRaw: false, kelvin: 6500)))

        // Reset and paste: the section's reset clears it; Presence pastes it.
        var reset = withLens
        AdjustSection.depth.reset(&reset)
        check("depth: the section resets", reset.depth == nil && AdjustSection.depth.isEdited(withLens) && !AdjustSection.depth.isEdited(reset))
        var from = PhotoRecord(), to = PhotoRecord()
        from.adjust = withLens
        PasteGroup.presence.apply(from, to: &to)
        check("depth: pasted with Presence", to.adjust.depth == lens)
    }
}
