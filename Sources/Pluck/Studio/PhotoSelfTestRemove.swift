import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import simd

/// AI Remove (-PluckScreenshotOnly remove; needs the model in Pluck's folder, else skipped): a painted object is filled in from
/// around it, nothing outside the painted area changes, the same fill isn't worked out twice, and old spots read and save as
/// they did.
extension PhotoSelfTest {
    /// Two values encode the same (sorted keys: JSONEncoder's own order isn't fixed, so plain bytes can differ for the same value).
    static func sameJSON<T: Encodable>(_ a: T, _ b: T) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(a)) == (try? encoder.encode(b))
    }

    static func removeTest() async {
        // Old spots: no stroke saved, and they read back the same.
        let old = PhotoSpot(kind: .heal, centre: CGPoint(x: 0.3, y: 0.3), source: CGPoint(x: 0.5, y: 0.3))
        let saved = (try? JSONEncoder().encode(old)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check("remove: old spots save no stroke", !saved.contains("stroke"), saved)
        check("remove: old spots read back", (try? JSONDecoder().decode(PhotoSpot.self, from: Data(saved.utf8))) == old)
        guard PhotoRemove.isReady else { skip("remove", "no model"); return }

        let context = PhotoEngine.context, square = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        // A green-to-blue ramp with a red block on it (the thing to remove), and brighter-than-white sky at the top.
        let ramp = CIFilter.linearGradient()
        ramp.point0 = CGPoint(x: 0, y: 0); ramp.point1 = CGPoint(x: 1200, y: 0)
        ramp.color0 = CIColor(red: 0.05, green: 0.25, blue: 0.08, alpha: 1, colorSpace: linear)!
        ramp.color1 = CIColor(red: 0.05, green: 0.12, blue: 0.3, alpha: 1, colorSpace: linear)!
        let block = CIImage(color: CIColor(red: 0.8, green: 0.05, blue: 0.05, alpha: 1, colorSpace: linear)!).cropped(to: CGRect(x: 560, y: 360, width: 80, height: 80))
        let sky = CIImage(color: CIColor(red: 2, green: 2.2, blue: 2.6, alpha: 1, colorSpace: linear)!).cropped(to: CGRect(x: 0, y: 700, width: 1200, height: 100))
        let picture = sky.composited(over: block.composited(over: ramp.outputImage!.cropped(to: square)))
        func mean(_ image: CIImage, _ r: CGRect) -> SIMD3<Float> {
            let avg = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: r)])
            var p = [Float](repeating: 0, count: 4)
            context.render(avg, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: linear)
            return SIMD3(p[0], p[1], p[2])
        }
        // Painted across the block (shares from the top left).
        let spot = PhotoSpot(kind: .remove, centre: CGPoint(x: 0.47, y: 0.5), source: CGPoint(x: 0.47, y: 0.5), radius: 0.045,
                             stroke: [CGPoint(x: 0.47, y: 0.5), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.53, y: 0.5)])
        let t0 = Date()
        let done = PhotoHeal.apply([spot], to: picture)
        let inside = mean(done, CGRect(x: 580, y: 380, width: 40, height: 40)), around = mean(picture, CGRect(x: 480, y: 380, width: 40, height: 40))
        let first = Date().timeIntervalSince(t0)
        check("remove: the block is gone", inside.x < 0.2, "red \(inside.x) (block 0.8)")
        check("remove: filled like around it", abs(inside.y - around.y) < 0.06 && abs(inside.z - around.z) < 0.08, "fill \(inside), around \(around)")
        let far = mean(done, CGRect(x: 40, y: 40, width: 200, height: 200)), farBefore = mean(picture, CGRect(x: 40, y: 40, width: 200, height: 200))
        check("remove: outside untouched", simd_length(far - farBefore) < 1e-4, "\(far) vs \(farBefore)")
        let skyAfter = mean(done, CGRect(x: 40, y: 720, width: 200, height: 60))
        check("remove: light above white kept outside", skyAfter.z > 2.5, "\(skyAfter)")
        let t1 = Date()
        _ = mean(PhotoHeal.apply([spot], to: picture), CGRect(x: 580, y: 380, width: 40, height: 40))
        let second = Date().timeIntervalSince(t1)
        check("remove: the same fill is kept", second < max(first * 0.5, 0.3), "first \(first)s, second \(second)s")
        // A spot at the photo's corner still works (the square kept inside the photo).
        let corner = PhotoSpot(kind: .remove, centre: CGPoint(x: 0.01, y: 0.99), source: .zero, radius: 0.03, stroke: [CGPoint(x: 0.01, y: 0.99)])
        let cornered = PhotoHeal.apply([corner], to: picture)
        check("remove: at the corner, same size", cornered.extent == picture.extent, "\(cornered.extent)")
        removeQuality()

        // A real RAW through the render, at two sizes and with two spots (Core ML hands its output buffers out again: a
        // fill drawn after the next one was made came out black).
        let folder = URL(fileURLWithPath: photos).deletingLastPathComponent()
        let raw = folder.appendingPathComponent("raws/DSC01962.ARW").path
        guard FileManager.default.fileExists(atPath: raw) else { skip("remove raw", "no RAW"); return }
        var record = PhotoRecord()
        // (The scissors on the chest of drawers, painted along, and the lamp, one click.)
        let a1 = PhotoSpot(kind: .remove, centre: CGPoint(x: 0.45, y: 0.47), source: .zero, radius: 0.018,
                           stroke: [CGPoint(x: 0.45, y: 0.468), CGPoint(x: 0.475, y: 0.478), CGPoint(x: 0.5, y: 0.488), CGPoint(x: 0.515, y: 0.49)])
        let a2 = PhotoSpot(kind: .remove, centre: CGPoint(x: 0.54, y: 0.38), source: .zero, radius: 0.055, stroke: [CGPoint(x: 0.54, y: 0.385)])
        record.adjust.spots = [a1, a2]
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        for size in [1400, 700, 1400] {
            guard let decoded = PhotoRender.decoded(raw, maxSize: size, record: record) else { check("remove raw decode", false); continue }
            let image = PhotoRender.output(PhotoRender.adjusted(decoded, record.adjust, path: raw), record.adjust, p3: false)
            let e = image.extent
            func at(_ share: CGPoint, _ r: CGFloat) -> SIMD3<Float> {
                mean(image, CGRect(x: e.minX + share.x * e.width - r, y: e.maxY - share.y * e.height - r, width: 2 * r, height: 2 * r))
            }
            let filled = at(CGPoint(x: 0.48, y: 0.48), 4), around = at(CGPoint(x: 0.44, y: 0.44), 4)
            let filled2 = at(CGPoint(x: 0.54, y: 0.38), 6)
            // The scissors and the lamp gone: their places differ clearly from before.
            let before = PhotoRender.output(PhotoRender.adjusted(decoded, PhotoAdjustments(), path: raw), PhotoAdjustments(), p3: false)
            func change(_ share: CGPoint, _ r: CGFloat) -> Float {
                let x = e.minX + share.x * e.width, y = e.maxY - share.y * e.height
                let d = before.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: image])
                return mean(d, CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)).sum()
            }
            check("remove raw \(Int(size)): scissors and lamp changed", change(CGPoint(x: 0.48, y: 0.48), 6) > 0.005 && change(CGPoint(x: 0.54, y: 0.38), 10) > 0.005,
                  "scissors \(change(CGPoint(x: 0.48, y: 0.48), 6)), lamp \(change(CGPoint(x: 0.54, y: 0.38), 10)); problem \(PhotoRemove.problem ?? "none")")
            check("remove raw \(Int(size)): not black", filled.sum() > around.sum() * 0.4 && filled2.sum() > 0.02,
                  "fill \(filled), second \(filled2), around \(around)")
            if let cg = context.createCGImage(image, from: e, format: .RGBA8, colorSpace: srgb),
               let dest = CGImageDestinationCreateWithURL(folder.appendingPathComponent("remove-\(Int(size)).jpg") as CFURL, "public.jpeg" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cg, nil); CGImageDestinationFinalize(dest)
            }
        }
        // (The depth map, tiles fused, saved to look at.)
        if let decoded = PhotoRender.decoded(raw, maxSize: 1400, record: PhotoRecord()),
           let near = PhotoDepth.nearness(raw + "#check", from: decoded, context: context),
           let cg = context.createCGImage(near, from: near.extent, format: .L8, colorSpace: CGColorSpace(name: CGColorSpace.linearGray)),
           let dest = CGImageDestinationCreateWithURL(folder.appendingPathComponent("depth-map.jpg") as CFURL, "public.jpeg" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cg, nil); CGImageDestinationFinalize(dest)
        }
    }
}
