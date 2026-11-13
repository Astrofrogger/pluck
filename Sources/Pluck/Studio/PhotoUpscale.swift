import CoreImage
import VideoToolbox

/// Super Resolution for photos: twice the width and height, by Apple's on-device super-resolution model (macOS 26, the one
/// video Enhance uses, in its still-image mode). The model works 4× on squares of 1024 pixels: the photo goes through in
/// overlapping squares, each made 4× and brought straight down to 2× (sharper than a plain 2× and never holding a 4× photo),
/// and the squares are laid side by side in one picture. The light goes in at an everyday brightness and as the eye sees it
/// (the model was made on finished pictures), and comes back as scene light, so the result is written as a linear DNG that
/// edits like a RAW.
enum PhotoUpscale {
    static var isSupported: Bool {
        guard #available(macOS 26, *) else { return false }
        return VTSuperResolutionScalerConfiguration.isSupported && VTSuperResolutionScalerConfiguration.supportedScaleFactors.contains(4)
    }

    /// The square the model works on, and how much neighbours overlap (in the photo's pixels).
    static let tile = 1024, overlap = 48

    enum Failure: LocalizedError {
        case unavailable, failed
        var errorDescription: String? {
            switch self {
            case .unavailable: String(localized: "Super Resolution needs macOS 26 on a Mac with Apple silicon.")
            case .failed: String(localized: "The photo couldn’t be enlarged.")
            }
        }
    }

    /// The photo (scene light, any size) at twice its width and height.
    static func doubled(_ image: CIImage, context: CIContext, progress: (Double) -> Void = { _ in }) async throws -> CIImage {
        guard #available(macOS 26, *), isSupported else { throw Failure.unavailable }
        let e = image.extent.integral
        let width = Int(e.width), height = Int(e.height)
        guard width > 0, height > 0 else { throw Failure.failed }
        guard let config = VTSuperResolutionScalerConfiguration(frameWidth: tile, frameHeight: tile, scaleFactor: 4, inputType: .image,
                                                                 usePrecomputedFlow: false, qualityPrioritization: .normal,
                                                                 revision: VTSuperResolutionScalerConfiguration.defaultRevision)
        else { throw Failure.unavailable }
        if config.configurationModelStatus != .ready {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                config.downloadConfigurationModel { error in if let error { done.resume(throwing: error) } else { done.resume() } }
            }
        }
        let processor = VTFrameProcessor()
        try processor.startSession(configuration: config)
        defer { processor.endSession() }

        // Into the model's light: an everyday brightness (the photo's average to a mid grey), a soft roll above white, sRGB steps.
        var average = [Float](repeating: 0, count: 4)
        context.render(image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: e)]), toBitmap: &average, rowBytes: 16,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        let mean = max(0.2126 * average[0] + 0.7152 * average[1] + 0.0722 * average[2], 1e-5)
        let gain = CGFloat(min(max(0.18 / mean, 0.25), 32))
        guard let into = intoKernel, let back = backKernel else { throw Failure.failed }
        let placed = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)).clampedToExtent()
        guard let squeezed = into.apply(extent: .infinite, arguments: [placed, Float(gain)]) else { throw Failure.failed }

        // The doubled picture, rows from the top (as CIImage(bitmapData:) reads them), half floats.
        let outW = width * 2, outH = height * 2
        var output = [UInt16](repeating: 0, count: outW * outH * 4)
        let step = tile - 2 * overlap
        let across = max(Int(ceil(Double(width) / Double(step))), 1), down = max(Int(ceil(Double(height) / Double(step))), 1)
        var done = 0
        for ty in 0..<down {
            for tx in 0..<across {
                try Task.checkCancellation()
                // The square: its useful middle starts at (x0, y0) (from the top left), with `overlap` round it.
                let x0 = tx * step, y0 = ty * step
                let ox = x0 - overlap, oyTop = y0 - overlap
                // (Core Image counts from the bottom.)
                let source = squeezed.transformed(by: CGAffineTransform(translationX: CGFloat(-ox), y: CGFloat(-(height - oyTop - tile))))
                    .cropped(to: CGRect(x: 0, y: 0, width: tile, height: tile))
                let inBuffer = try buffer(tile, tile)
                context.render(source, to: inBuffer)
                let big = try buffer(tile * 4, tile * 4)
                guard let frame = VTFrameProcessorFrame(buffer: inBuffer, presentationTimeStamp: .zero),
                      let target = VTFrameProcessorFrame(buffer: big, presentationTimeStamp: .zero),
                      let parameters = VTSuperResolutionScalerParameters(sourceFrame: frame, previousFrame: nil, previousOutputFrame: nil, opticalFlow: nil,
                                                                         submissionMode: .random, destinationFrame: target) else { throw Failure.failed }
                _ = try await processor.process(parameters: parameters)
                // Down to 2×, back to scene light, and its useful middle copied into place.
                let halved = CIImage(cvPixelBuffer: big).applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 0.5])
                guard let light = back.apply(extent: halved.extent, arguments: [halved, Float(1 / gain)]) else { throw Failure.failed }
                let useW = min(step, width - x0) * 2, useH = min(step, height - y0) * 2
                guard useW > 0, useH > 0 else { continue }
                var block = [UInt16](repeating: 0, count: useW * useH * 4)
                // (The middle: `overlap` in from the square's left and top, at 2×; the bitmap's rows from the top.)
                let inner = CGRect(x: overlap * 2, y: tile * 2 - overlap * 2 - useH, width: useW, height: useH)
                context.render(light, toBitmap: &block, rowBytes: useW * 8, bounds: inner, format: .RGBAh, colorSpace: nil)
                block.withUnsafeBufferPointer { src in
                    output.withUnsafeMutableBufferPointer { dst in
                        for row in 0..<useH {
                            let to = ((y0 * 2 + row) * outW + x0 * 2) * 4
                            dst.baseAddress!.advanced(by: to).update(from: src.baseAddress!.advanced(by: row * useW * 4), count: useW * 4)
                        }
                    }
                }
                done += 1
                progress(Double(done) / Double(across * down))
            }
        }
        let data = output.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: outW * 8, size: CGSize(width: outW, height: outH), format: .RGBAh,
                       colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
    }

    private static func buffer(_ width: Int, _ height: Int) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_64RGBAHalf, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made)
        guard let made else { throw Failure.failed }
        return made
    }

    /// Scene light to the model's: times the gain, a soft roll from 0.8 up to (never past) white, sRGB steps.
    private static let intoKernel = CIColorKernel(source: """
        kernel vec4 into(__sample c, float gain) {
            vec3 v = max(c.rgb * gain, 0.0);
            v = mix(v, 0.8 + 0.2 * (v - 0.8) / (v - 0.8 + 0.2), step(0.8, v));
            vec3 e = mix(v * 12.92, 1.055 * pow(v, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, v));
            return vec4(e, 1.0);
        }
        """)
    /// And back.
    private static let backKernel = CIColorKernel(source: """
        kernel vec4 back(__sample c, float ungain) {
            vec3 e = clamp(c.rgb, 0.0, 0.998);
            vec3 v = mix(e / 12.92, pow((e + 0.055) / 1.055, vec3(2.4)), step(0.04045, e));
            vec3 over = 0.8 + 0.2 * (v - 0.8) / (1.0 - v);
            v = mix(v, over, step(0.8, v));
            return vec4(v * ungain, 1.0);
        }
        """)
}
