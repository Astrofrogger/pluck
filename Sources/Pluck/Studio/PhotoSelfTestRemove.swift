import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import simd

/// AI Remove (-PluckScreenshotOnly remove; needs the model in Pluck's folder, else skipped): a painted object is filled in from
/// around it, nothing outside the painted area changes, the same fill isn't worked out twice, and old spots read and save as
/// they did.
extension PhotoSelfTest {
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
    }
}
