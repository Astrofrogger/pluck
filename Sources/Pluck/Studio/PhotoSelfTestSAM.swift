import CoreImage
import Foundation

/// Click masks before macOS 27 (-PluckScreenshotOnly clickmask; needs the SAM model in Pluck's folder, else skipped): a click
/// on the lamp in a test RAW gives a mask on the lamp and not on the wall beside it; a second click on the same photo reuses
/// its encoding.
extension PhotoSelfTest {
    static func clickMask() async {
        guard PhotoSAM.isReady else { skip("click mask", "no model"); return }
        let folder = URL(fileURLWithPath: photos).deletingLastPathComponent()
        let raw = folder.appendingPathComponent("raws/DSC01962.ARW").path
        guard FileManager.default.fileExists(atPath: raw), let kept = PhotoRender.base(raw, maxSize: 1536, record: PhotoRecord()) else {
            skip("click mask", "no RAW"); return
        }
        let picture = PhotoEngine.develop(kept.image, PhotoAdjustments(), isRaw: true)
        let context = PhotoEngine.context, e = picture.extent
        func mean(_ m: CIImage, _ share: CGPoint, _ r: CGFloat) -> Float {
            let x = e.minX + share.x * e.width, y = e.maxY - share.y * e.height
            let avg = m.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))])
            var p = [Float](repeating: 0, count: 4)
            context.render(avg, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            return p[0]
        }
        let lamp = CGPoint(x: 0.535, y: 0.40)
        let t0 = Date()
        guard let mask = PhotoSAM.object(raw, points: [(lamp, true)], in: picture, context: context) else { check("click mask: found", false); return }
        let first = Date().timeIntervalSince(t0)
        check("click mask: the size of the photo", mask.extent == e, "\(mask.extent) against \(e)")
        check("click mask: on the lamp", mean(mask, lamp, 6) > 0.8, "\(mean(mask, lamp, 6))")
        check("click mask: not on the curtain beside it", mean(mask, CGPoint(x: 0.62, y: 0.3), 8) < 0.1, "\(mean(mask, CGPoint(x: 0.62, y: 0.3), 8))")
        let t1 = Date()
        _ = PhotoSAM.object(raw, points: [(lamp, true), (CGPoint(x: 0.53, y: 0.46), false)], in: picture, context: context)
        let second = Date().timeIntervalSince(t1)
        check("click mask: a second click reuses the photo's encoding", second < first * 0.6, "first \(first)s, second \(second)s")
    }
}

extension PhotoSelfTest {
    /// Describe masks (-PluckScreenshotOnly describe): "cat" finds the cat in a test RAW (and the mask is on it), "car" finds
    /// nothing there, and an edit without one saves no words.
    static func describe() async {
        let plain = MaskPart(kind: .linear)
        let saved = (try? JSONEncoder().encode(plain)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check("describe: other parts save no words", !saved.contains("words"), saved)
        let folder = URL(fileURLWithPath: photos).deletingLastPathComponent()
        let raw = folder.appendingPathComponent("raws/DSC02845.ARW").path
        guard FileManager.default.fileExists(atPath: raw), let kept = PhotoRender.base(raw, maxSize: 1536, record: PhotoRecord()) else {
            skip("describe", "no RAW"); return
        }
        let context = PhotoEngine.context
        let cat = PhotoMasks.described(raw, "cat", from: kept.image, context: context)
        check("describe: the cat is found", (cat?.count ?? 0) >= 1 && cat?.mask != nil, "count \(cat?.count ?? -1)")
        if let mask = cat?.mask {
            let e = mask.extent
            func at(_ x: CGFloat, _ y: CGFloat) -> Float {
                let avg = mask.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: CGRect(x: e.minX + x * e.width - 4, y: e.maxY - y * e.height - 4, width: 8, height: 8))])
                var p = [Float](repeating: 0, count: 4)
                context.render(avg, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                return p[0]
            }
            // (The cat sits in the middle, a little right of centre; the top left is trees.)
            check("describe: on the cat, not the trees", at(0.5, 0.65) > 0.7 && at(0.1, 0.15) < 0.1, "cat \(at(0.5, 0.65)), trees \(at(0.1, 0.15))")
        }
        let car = PhotoMasks.described(raw, "car", from: kept.image, context: context)
        check("describe: no car there", car?.count == 0 && car?.mask == nil, "count \(car?.count ?? -1)")
    }
}

extension PhotoSelfTest {
    /// Match Brush (-PluckScreenshotOnly matchbrush): a stroke on the lawn in a test RAW picks the rest of the lawn, not the
    /// chest of drawers; a wider Range picks more.
    static func matchBrush() async {
        let folder = URL(fileURLWithPath: photos).deletingLastPathComponent()
        let raw = folder.appendingPathComponent("raws/DSC01962.ARW").path
        guard FileManager.default.fileExists(atPath: raw), let kept = PhotoRender.base(raw, maxSize: 1536, record: PhotoRecord()) else {
            skip("match brush", "no RAW"); return
        }
        let context = PhotoEngine.context
        var part = MaskPart(kind: .match)
        part.strokes = [BrushStroke(points: [CGPoint(x: 0.72, y: 0.52), CGPoint(x: 0.75, y: 0.53)], size: 0.02)]
        guard let mask = PhotoMasks.matched(part, path: raw + "#match", from: kept.image, context: context) else { check("match brush: made", false); return }
        let e = mask.extent
        func at(_ x: CGFloat, _ y: CGFloat) -> Float {
            let avg = mask.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: CGRect(x: e.minX + x * e.width - 5, y: e.maxY - y * e.height - 5, width: 10, height: 10))])
            var p = [Float](repeating: 0, count: 4)
            context.render(avg, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            return p[0]
        }
        check("match brush: picks more of the lawn", at(0.8, 0.58) > 0.5, "\(at(0.8, 0.58))")
        check("match brush: not the chest of drawers", at(0.3, 0.6) < 0.15, "\(at(0.3, 0.6))")
        func coverage(_ m: CIImage) -> Float {
            let avg = m.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: m.extent)])
            var p = [Float](repeating: 0, count: 4)
            context.render(avg, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            return p[0]
        }
        var wide = part; wide.smooth = 0.9
        let narrow = coverage(mask), broad = PhotoMasks.matched(wide, path: raw + "#match", from: kept.image, context: context).map(coverage) ?? 0
        check("match brush: a wider Range picks more", broad > narrow * 1.2, "\(narrow) → \(broad)")
    }
}
