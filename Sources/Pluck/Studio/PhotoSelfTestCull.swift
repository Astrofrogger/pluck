import CoreImage
import Foundation
import ImageIO

/// Culling (-PluckScreenshotOnly cull): 100 % reads the photo at its full size; focus peaking finds the sharp cat, not the
/// blurred trees behind it, and marks the cat as the sharpest spot.
extension PhotoSelfTest {
    static func cullTest() async {
        let raw = URL(fileURLWithPath: photos).deletingLastPathComponent().appendingPathComponent("raws/DSC02845.ARW").path
        guard FileManager.default.fileExists(atPath: raw) else { skip("cull", "no RAW"); return }
        guard let size = CullCache.pixelSize(of: raw), let full = await CullCache.shared.full(raw) else { check("cull: full size", false); return }
        check("cull: 100 % is the photo's full size", abs(Double(full.width) - size.width) <= 2 && abs(Double(full.height) - size.height) <= 2,
              "\(full.width)×\(full.height) against \(size)")
        guard let preview = await CullCache.shared.load(raw)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let peaks = CullPeaking.find(preview) else { check("cull: peaking", false); return }
        // (The cat sits in the middle, a little low; the trees fill the top.)
        check("cull: the sharpest spot is on the cat", abs(peaks.sharpest.x - 0.5) < 0.15 && peaks.sharpest.y > 0.25 && peaks.sharpest.y < 0.95, "\(peaks.sharpest)")
        func coverage(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Double {
            let o = peaks.overlay, r = CGRect(x: x * Double(o.width), y: y * Double(o.height), width: w * Double(o.width), height: h * Double(o.height)).integral
            guard let crop = o.cropping(to: r) else { return 0 }
            var px = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
            px.withUnsafeMutableBytes {
                CGContext(data: $0.baseAddress, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    .draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            }
            var on = 0
            for i in stride(from: 3, to: px.count, by: 4) where px[i] > 100 { on += 1 }
            return Double(on) / Double(max(crop.width * crop.height, 1))
        }
        let cat = coverage(0.42, 0.3, 0.16, 0.3), trees = coverage(0.05, 0.05, 0.3, 0.25)
        check("cull: peaking marks the cat, not the trees", cat > 0.03 && cat > trees * 3, "cat \(cat), trees \(trees)")

        // The subject's box (no faces): round the cat.
        if let box = PhotoChecks.subjectBox(preview) {
            check("cull: the subject is the cat", box.midX > 0.35 && box.midX < 0.65 && box.width < 0.5, "\(box)")
        } else { check("cull: the subject is the cat", false, "none found") }

        // A face through a moment: open eyes found, and a blurred copy measures softer.
        let portrait = URL(fileURLWithPath: photos).deletingLastPathComponent().appendingPathComponent("raws/DSC02868.ARW").path
        if let look = PhotoChecks.look(at: portrait), let face = look.faces.max(by: { $0.width < $1.width }),
           let picture = await CullCache.shared.load(portrait)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let sharp = CullFaceStrip.measure(picture, box: face) {
            let soft = CIImage(cgImage: picture).applyingGaussianBlur(sigma: 4).cropped(to: CGRect(x: 0, y: 0, width: picture.width, height: picture.height))
            let blurred = CullPeaking.plain.createCGImage(soft, from: soft.extent).flatMap { CullFaceStrip.measure($0, box: face) }
            check("cull: the face's eyes are open", sharp.open == true, "\(String(describing: sharp.open))")
            check("cull: a blurred face measures softer", (blurred?.sharpness ?? 1) < sharp.sharpness * 0.5, "\(sharp.sharpness) → \(blurred?.sharpness ?? -1)")
        } else { skip("cull: faces", "no face found") }

        // Auto Cull: a moment of four (two on top), and a photo on its own; nothing decided yet.
        let a = "/tmp/pluck-cull/a.jpg", b = "/tmp/pluck-cull/b.jpg", c = "/tmp/pluck-cull/c.jpg", d = "/tmp/pluck-cull/d.jpg", e = "/tmp/pluck-cull/e.jpg"
        let moments = [CullMoment(id: a, members: [a, b, c, d], top: a, onTop: [a, b]), CullMoment(id: e, members: [e], top: e, onTop: [e])]
        let strict = autoCull(moments, strictness: .strict, checks: PhotoChecks.shared, catalog: PhotoCatalog.shared)
        let balanced = autoCull(moments, strictness: .balanced, checks: PhotoChecks.shared, catalog: PhotoCatalog.shared)
        let gentle = autoCull(moments, strictness: .gentle, checks: PhotoChecks.shared, catalog: PhotoCatalog.shared)
        check("cull: strict keeps only the top pick", Set(strict.keep) == [a, e] && Set(strict.reject) == [b, c, d], "\(strict)")
        check("cull: balanced keeps the top quarter", Set(balanced.keep) == [a, b, e] && Set(balanced.reject) == [c, d], "\(balanced)")
        check("cull: gentle rejects nothing that looks fine", Set(gentle.keep) == [a, b, e] && gentle.reject.isEmpty, "\(gentle)")
    }
}
