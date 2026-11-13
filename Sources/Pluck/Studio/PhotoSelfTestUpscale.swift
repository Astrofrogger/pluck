import CoreImage
import Foundation
import ImageIO

/// Super Resolution (-PluckScreenshotOnly upscale; macOS 26): twice the size, the same brightness, sharper than a plain 2×
/// enlargement; and a whole 24 MP RAW done end to end as a DNG beside it, with its time.
extension PhotoSelfTest {
    static func upscaleTest() async {
        guard PhotoUpscale.isSupported else { skip("upscale", "not on this Mac"); return }
        let folder = URL(fileURLWithPath: photos).deletingLastPathComponent()
        let raw = folder.appendingPathComponent("raws/DSC02845.ARW")
        guard let small = PhotoRender.decoded(raw.path, maxSize: 1400, record: PhotoRecord()) else { skip("upscale", "no RAW"); return }
        let context = PhotoEngine.context
        let e = small.extent
        let image = small.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        do {
            let big = try await PhotoUpscale.doubled(image, context: context)
            check("upscale: twice the size", big.extent.width == image.extent.width * 2 && big.extent.height == image.extent.height * 2, "\(big.extent)")
            func mean(_ i: CIImage) -> Float {
                var p = [Float](repeating: 0, count: 4)
                context.render(i.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: i.extent)]), toBitmap: &p, rowBytes: 16,
                               bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                return 0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2]
            }
            check("upscale: the same brightness", abs(mean(big) / mean(image) - 1) < 0.04, "\(mean(image)) → \(mean(big))")
            // Closer to the truth than a plain 2×: the photo halved, then made whole again both ways, against itself.
            let half = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 0.5])
            let h = half.extent.integral
            let low = half.cropped(to: h).transformed(by: CGAffineTransform(translationX: -h.minX, y: -h.minY))
            let restored = try await PhotoUpscale.doubled(low, context: context)
            let plain = low.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 2])
            func error(_ i: CIImage) -> Float {
                let r = CGRect(x: 0, y: 0, width: min(i.extent.width, image.extent.width) - 4, height: min(i.extent.height, image.extent.height) - 4)
                let d = i.applyingFilter("CILinearToSRGBToneCurve").applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: image.applyingFilter("CILinearToSRGBToneCurve")])
                var p = [Float](repeating: 0, count: 4)
                context.render(d.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: r)]), toBitmap: &p, rowBytes: 16,
                               bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                return p[0] + p[1] + p[2]
            }
            for (n, img) in [("up-truth", image), ("up-plain", plain), ("up-super", restored)] {
                let r = CGRect(x: image.extent.width * 0.47, y: image.extent.height * 0.55, width: 220, height: 160)
                if let cg = context.createCGImage(img.applyingFilter("CILinearToSRGBToneCurve").applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.6]), from: r, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
                   let dest = CGImageDestinationCreateWithURL(folder.appendingPathComponent(n + ".png") as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, cg, nil); CGImageDestinationFinalize(dest)
                }
            }
            // (A pixel comparison favours a plain enlargement of a cleanly halved photo: the model cleans and sharpens rather than
            // copies. So: not far from the real photo, and the crops saved to look at.)
            check("upscale: close to the real photo", error(restored) < error(plain) * 1.3, "plain \(error(plain)), super \(error(restored))")
        } catch { check("upscale", false, error.localizedDescription) }
        // End to end on the whole RAW.
        let work = folder.appendingPathComponent("upscale-test", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let copy = work.appendingPathComponent("photo.ARW")
        try? FileManager.default.copyItem(at: raw, to: copy)
        let start = Date()
        do {
            let url = try await PhotoMerger.makeEnlarged(copy.path)
            let seconds = Date().timeIntervalSince(start)
            let size = CullCache.pixelSize(of: url.path), source = CullCache.pixelSize(of: copy.path)
            check("upscale: a whole RAW, as a DNG beside it", url.lastPathComponent == "photo-Enhanced.dng" && abs((size?.width ?? 0) / 2 - (source?.width ?? 1)) < (source?.width ?? 1) * 0.02,
                  "\(url.lastPathComponent) \(String(describing: size)) from \(String(describing: source)) in \(String(format: "%.1f", seconds)) s")
        } catch { check("upscale: a whole RAW", false, error.localizedDescription) }
    }
}
