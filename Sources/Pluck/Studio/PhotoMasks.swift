import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// Masks for local adjustments: the subject (people, animals, things in front), found by
/// Vision on this Mac, and the rest. Worked out once per photo, small, and scaled to fit.
enum PhotoMasks {
    nonisolated(unsafe) private static var subjects: [String: CIImage] = [:]
    private static let lock = NSLock()

    /// The subject's mask for this photo (white where the subject is), at its own small size
    /// (scale it to the picture).
    static func subject(_ path: String, from image: CIImage, context: CIContext) -> CIImage? {
        lock.lock()
        if let known = subjects[path] { lock.unlock(); return known }
        lock.unlock()
        let scale = min(1, 1024 / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg)
        try? handler.perform([request])
        var mask: CIImage
        if let result = request.results?.first, let buffer = try? result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler) {
            // Vision's mask is one float per pixel, which Core Image can't read: made a grey picture.
            mask = grey(buffer) ?? CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        } else {
            mask = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        // Soft edges.
        let e = mask.extent
        mask = mask.clampedToExtent().applyingGaussianBlur(sigma: 2).cropped(to: e)
        lock.lock(); subjects[path] = mask; if subjects.count > 24 { subjects.removeValue(forKey: subjects.keys.first!) }; lock.unlock()
        return mask
    }

    private static func grey(_ buffer: CVPixelBuffer) -> CIImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let line = base.advanced(by: y * row).assumingMemoryBound(to: Float32.self)
            for x in 0..<width { bytes[y * width + x] = UInt8(min(max(line[x], 0), 1) * 255) }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                                  decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return CIImage(cgImage: image)
    }

    /// The masks' changes on a developed picture (display light, before crop and detail).
    static func apply(_ masks: [PhotoMask], to image: CIImage, base: CIImage, path: String, context: CIContext) -> CIImage {
        guard !masks.isEmpty, let small = subject(path, from: base, context: context) else { return image }
        let e = image.extent, m = small.extent
        let subject = small.transformed(by: CGAffineTransform(translationX: -m.minX, y: -m.minY)
            .concatenating(CGAffineTransform(scaleX: e.width / m.width, y: e.height / m.height))
            .concatenating(CGAffineTransform(translationX: e.minX, y: e.minY)))
        var result = image
        for mask in masks {
            var area = subject
            if mask.kind == .background { area = subject.applyingFilter("CIColorInvert") }
            var changed = result
            if mask.exposure != 0 { changed = changed.applyingFilter("CIExposureAdjust", parameters: ["inputEV": mask.exposure]) }
            if mask.contrast != 0 || mask.saturation != 0 {
                changed = changed.applyingFilter("CIColorControls", parameters: ["inputContrast": 1 + mask.contrast / 100 * 0.5,
                                                                                  "inputSaturation": 1 + mask.saturation / 100,
                                                                                  "inputBrightness": 0])
            }
            if mask.warmth != 0 {
                changed = changed.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0),
                                                                                       "inputTargetNeutral": CIVector(x: 6500 + mask.warmth * 25, y: 0)])
            }
            if mask.clarity != 0 {
                let radius = max(e.width, e.height) / 70
                changed = mask.clarity > 0
                    ? changed.applyingFilter("CIUnsharpMask", parameters: ["inputRadius": radius, "inputIntensity": mask.clarity / 100 * 0.6])
                    : changed.applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": changed.clampedToExtent().applyingGaussianBlur(sigma: radius / 2).cropped(to: e),
                                                                                  "inputTime": -mask.clarity / 100 * 0.5])
            }
            result = changed.cropped(to: e).applyingFilter("CIBlendWithMask", parameters: ["inputBackgroundImage": result, "inputMaskImage": area])
                .cropped(to: e)
        }
        return result
    }
}
