import CoreImage
import Foundation
import ImageIO

/// Smooth Skin (-PluckScreenshotOnly retouch): on a portrait, the skin's fine texture drops clearly, places off the skin don't
/// change, and none saves nothing.
extension PhotoSelfTest {
    static func retouch() async {
        var plain = PhotoAdjustments(); plain.skin = 0
        check("retouch: none saves nothing", plain.skin == nil && !((try? JSONEncoder().encode(plain)).map { String(decoding: $0, as: UTF8.self) } ?? "").contains("skin"))
        let file = URL(fileURLWithPath: photos).deletingLastPathComponent().appendingPathComponent("faces/DSC02868-p6-standard.jpg")
        guard let source = CIImage(contentsOf: file) else { skip("retouch", "no portrait"); return }
        let context = PhotoEngine.context
        let e0 = source.extent, k = min(1, 1400 / max(e0.width, e0.height))
        let image = source.transformed(by: CGAffineTransform(translationX: -e0.minX, y: -e0.minY).concatenating(CGAffineTransform(scaleX: k, y: k)))
        let e = image.extent, path = file.path + "#retouch"
        guard let skin = PhotoMasks.facePart(.faceSkin, person: nil, path: path, from: image, context: context) else { skip("retouch", "no face"); return }
        let smooth = PhotoRetouch.smoothed(100, to: image, path: path, base: image, context: context)
        let m = skin.extent
        let mask = skin.transformed(by: CGAffineTransform(translationX: -m.minX, y: -m.minY).concatenating(CGAffineTransform(scaleX: e.width / m.width, y: e.height / m.height)))
        // Fine texture: the picture less a small blur of itself, its size, weighed by the skin (and by none of it, outside).
        func texture(_ i: CIImage, _ weight: CIImage) -> Float {
            let screen = i.applyingFilter("CILinearToSRGBToneCurve")
            let detail = screen.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: screen.clampedToExtent().applyingGaussianBlur(sigma: 2).cropped(to: e)])
            let weighed = detail.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: weight])
            let avg = weighed.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: e)])
            var p = [Float](repeating: 0, count: 4)
            context.render(avg, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            return p[0] + p[1] + p[2]
        }
        let out = URL(fileURLWithPath: photos).deletingLastPathComponent()
        for (name, img) in [("retouch-before", image), ("retouch-after", smooth), ("retouch-mask", mask)] {
            if let cg = context.createCGImage(img, from: e, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
               let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name + ".jpg") as CFURL, "public.jpeg" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cg, nil); CGImageDestinationFinalize(dest)
            }
        }
        let before = texture(image, mask), after = texture(smooth, mask)
        check("retouch: the skin's texture drops", after < before * 0.7, "\(before) → \(after)")
        let outside = mask.applyingFilter("CIColorInvert").applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0)])
            .applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.98])
        let changed = image.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: smooth])
            .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: outside])
            .applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: e)])
        var p = [Float](repeating: 0, count: 4)
        context.render(changed, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        check("retouch: off the skin unchanged", max(p[0], p[1], p[2]) < 0.01, "largest change \(max(p[0], p[1], p[2]))")
    }
}
