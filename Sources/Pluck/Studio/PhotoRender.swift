import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import ImageIO
import Metal
import Vision
import UniformTypeIdentifiers

/// Develops a photo with Pluck's photo engine (PhotoEngine: neutral RAW, local tone, profiles,
/// on the GPU), then, when film is on, the film and paper through spektrafilm (about a second
/// for a preview, longer at full size).
enum PhotoRender {
    private static var context: CIContext { PhotoEngine.context }

    /// The big picture's size: the screen's pixels (sharp on Retina), at least 2048.
    @MainActor static var previewSize: Int {
        let screen = NSScreen.main.map { $0.frame.size.applying(CGAffineTransform(scaleX: $0.backingScaleFactor, y: $0.backingScaleFactor)) }
        return min(max(Int(max(screen?.width ?? 2048, screen?.height ?? 2048)), 2048), 4096)
    }

    /// Whether the photo stands upright (from its size and orientation, without decoding it).
    nonisolated(unsafe) private static var portraits: [String: Bool] = [:]

    static func isPortrait(_ path: String) -> Bool {
        kelvinLock.lock()
        if let known = portraits[path] { kelvinLock.unlock(); return known }
        kelvinLock.unlock()
        let upright = readPortrait(path)
        kelvinLock.lock(); portraits[path] = upright; kelvinLock.unlock()
        return upright
    }

    private static func readPortrait(_ path: String) -> Bool {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double, let h = props[kCGImagePropertyPixelHeight] as? Double else { return false }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? w > h : h > w
    }

    static func isRaw(_ path: String) -> Bool {
        UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension)?.conforms(to: .rawImage) == true
    }

    nonisolated(unsafe) private static var kelvins: [String: Double] = [:]
    private static let kelvinLock = NSLock()

    /// The light the camera balanced for (RAW), in Kelvin; 6500 for other photos.
    static func asShotKelvin(_ path: String) -> Double {
        guard isRaw(path) else { return 6500 }
        kelvinLock.lock()
        if let known = kelvins[path] { kelvinLock.unlock(); return known }
        kelvinLock.unlock()
        let value = CIRAWFilter(imageURL: URL(fileURLWithPath: path)).map { Double($0.neutralTemperature) } ?? 5500
        kelvinLock.lock(); kelvins[path] = value; kelvinLock.unlock()
        return value
    }

    /// The photo, at most this many pixels on its long side (0: full size), in linear light. RAW
    /// is decoded neutral: none of the camera maker's look, so every camera starts the same.
    /// The denoised photo when there is one for this strength.
    static func source(_ path: String, maxSize: Int, denoise: Int = 0, noise: Double = 0, raw settings: RawSettings = RawSettings()) -> CIImage? {
        if denoise > 0, let clean = denoised(path, strength: denoise), FileManager.default.fileExists(atPath: clean.path),
           var image = CIImage(contentsOf: clean) {
            let long = max(image.extent.width, image.extent.height)
            if maxSize > 0, long > Double(maxSize) {
                let filter = CIFilter.lanczosScaleTransform()
                filter.inputImage = image
                filter.scale = Float(Double(maxSize) / long)
                image = filter.outputImage ?? image
            }
            return image
        }
        let url = URL(fileURLWithPath: path)
        if isRaw(path), let raw = CIRAWFilter(imageURL: url) {
            if maxSize > 0 {
                let long = max(raw.nativeSize.width, raw.nativeSize.height)
                if long > 0 { raw.scaleFactor = Float(min(1, Double(maxSize) / long)) }
            }
            neutral(raw, noise: noise, moire: settings.moire, decoder: settings.decoder)
            // Lens correction leaves an unfilled edge: a sliver (0.4%) goes.
            guard let image = raw.outputImage else { return nil }
            let edge = max(2, (max(image.extent.width, image.extent.height) * 0.004).rounded(.up))
            let inner = image.extent.insetBy(dx: edge, dy: edge).integral
            return image.cropped(to: inner).transformed(by: CGAffineTransform(translationX: -inner.minX, y: -inner.minY))
        }
        if maxSize > 0, let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxSize,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { return CIImage(cgImage: image) }
        }
        return CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }

    /// Apple's RAW engine without its look: no boost or tone mapping, the highlights' headroom
    /// kept, no sharpening or extra detail and contrast (Pluck does those), lens corrections on.
    /// Every switch is set, so nothing depends on Apple's defaults; the decoder's version is the
    /// one the photo was edited with.
    static func neutral(_ raw: CIRAWFilter, noise: Double, moire: Double = 0, decoder: String? = nil) {
        raw.boostAmount = 0
        raw.boostShadowAmount = 0
        raw.localToneMapAmount = 0
        raw.extendedDynamicRangeAmount = 2
        raw.sharpnessAmount = 0
        raw.detailAmount = 0
        raw.contrastAmount = 0
        if #available(macOS 26, *) { raw.isHighlightRecoveryEnabled = true }
        // Apple's gamut mapping stays on: without it, near-black noise comes out in strong,
        // impossible blues (measured: nearly three times as many) that Shadows then lifts. What
        // it leaves outside sRGB, version 2 keeps and compresses itself.
        raw.isGamutMappingEnabled = true
        raw.isLensCorrectionEnabled = true
        raw.moireReductionAmount = Float(moire / 100)
        if let decoder, let version = raw.supportedDecoderVersions.first(where: { $0.rawValue == decoder }) {
            raw.decoderVersion = version
        }
        raw.luminanceNoiseReductionAmount = Float(noise / 100)
        raw.colorNoiseReductionAmount = Float(max(0.5, noise / 100))
    }

    /// The RAW decoder a new edit is pinned to (the newest this Mac has).
    static func currentDecoder(_ path: String) -> String? {
        guard isRaw(path) else { return nil }
        kelvinLock.lock()
        if let known = decoders[path] { kelvinLock.unlock(); return known }
        kelvinLock.unlock()
        guard let version = CIRAWFilter(imageURL: URL(fileURLWithPath: path))?.decoderVersion.rawValue else { return nil }
        kelvinLock.lock(); decoders[path] = version; kelvinLock.unlock()
        return version
    }

    nonisolated(unsafe) private static var decoders: [String: String] = [:]

    /// What the RAW decoder is given besides noise.
    struct RawSettings: Hashable {
        var moire = 0.0
        var decoder: String?
        init() {}
        init(_ a: PhotoAdjustments) { moire = a.moire; decoder = a.rawDecoder }
        var key: String { "\(Int(moire))|\(decoder ?? "")" }
    }

    /// The adjustments, in the order a photo editor applies them: light and white balance, local
    /// tone and the profile (the photo engine), colour (a lookup table), noise, sharpening,
    /// straightening and crop, vignette. `scene`: light only, for the film engine.
    /// `cacheKey`: the decoded photo is a kept one (see `base`), so its local-tone layers can be.
    static func adjusted(_ image: CIImage, _ a: PhotoAdjustments, isRaw: Bool, kelvin: Double, scene: Bool = false, crop: Bool = true,
                         path: String? = nil, cacheKey: String? = nil) -> CIImage {
        let base = image
        var image = PhotoEngine.develop(image, a, isRaw: isRaw, asShotKelvin: kelvin, scene: scene, cacheKey: cacheKey)
        let long = max(image.extent.width, image.extent.height)
        if !scene, a.needsLUT {
            let filter = CIFilter.colorCubeWithColorSpace()
            filter.inputImage = image
            filter.cubeDimension = Float(lutSize)
            filter.cubeData = lut(for: a)
            filter.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            image = filter.outputImage ?? image
        }
        if !scene, !a.masks.isEmpty, let path {
            image = PhotoMasks.apply(a.masks, to: image, base: base, path: path, context: context)
        }
        if a.noise > 0, !isRaw {
            let filter = CIFilter.noiseReduction()
            filter.inputImage = image
            filter.noiseLevel = Float(a.noise / 100 * 0.05)
            filter.sharpness = 0.4
            image = filter.outputImage ?? image
        }
        if a.sharpen > 0 {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = image
            filter.sharpness = Float(a.sharpen / 100 * 0.9)
            filter.radius = Float(max(1.5, long / 2400))
            image = filter.outputImage ?? image
        }
        image = geometry(image, a, crop: crop)
        if a.vignette != 0 {
            let filter = CIFilter.vignetteEffect()
            filter.inputImage = image
            filter.center = CGPoint(x: image.extent.midX, y: image.extent.midY)
            filter.radius = Float(max(image.extent.width, image.extent.height) * 0.62)
            filter.intensity = Float(-a.vignette / 100)
            filter.falloff = 0.6
            image = filter.outputImage ?? image
        }
        return image.cropped(to: image.extent)
    }

    /// The adjustments for this photo (whether it's RAW, and its as-shot light).
    static func adjusted(_ image: CIImage, _ a: PhotoAdjustments, path: String, scene: Bool = false, crop: Bool = true,
                         cacheKey: String? = nil) -> CIImage {
        adjusted(image, a, isRaw: isRaw(path), kelvin: asShotKelvin(path), scene: scene, crop: crop, path: path, cacheKey: cacheKey)
    }

    /// Straightening and the crop. The crop is kept as shares from the top left of the
    /// straightened picture; Core Image counts from the bottom left.
    static func geometry(_ image: CIImage, _ a: PhotoAdjustments, crop: Bool = true) -> CIImage {
        var image = image
        let extent = image.extent
        if a.straighten != 0 {
            let filter = CIFilter.straighten()
            filter.inputImage = image
            filter.angle = Float(a.straighten * .pi / 180)
            image = (filter.outputImage ?? image).cropped(to: extent)
        }
        guard crop else { return image }
        if let rect = a.cropRect {
            let r = CGRect(x: extent.minX + rect.x * extent.width, y: extent.minY + (1 - rect.y - rect.height) * extent.height,
                           width: rect.width * extent.width, height: rect.height * extent.height).integral.intersection(extent)
            if r.width > 4, r.height > 4 { image = image.cropped(to: r) }
        } else if let ratio = a.cropRatio(pictureRatio: extent.width / max(extent.height, 1)) {
            var size = extent.size
            if size.width / size.height > ratio { size.width = size.height * ratio } else { size.height = size.width / ratio }
            image = image.cropped(to: CGRect(x: extent.midX - size.width / 2, y: extent.midY - size.height / 2, width: size.width, height: size.height))
        }
        return image
    }

    // MARK: - Lookup tables

    static let lutSize = 48
    nonisolated(unsafe) private static var luts: [PhotoAdjustments: Data] = [:]
    nonisolated(unsafe) private static var lutOrder: [PhotoAdjustments] = []
    private static let lutLock = NSLock()

    /// The table for these settings, from the last few made (a slider drag reuses none, but
    /// going back and forth between photos does).
    static func lut(for a: PhotoAdjustments) -> Data {
        var key = PhotoAdjustments()
        key.vibrance = a.vibrance; key.saturation = a.saturation
        key.curves = a.curves; key.wheels = a.wheels; key.mixer = a.mixer
        lutLock.lock()
        if let data = luts[key] { lutLock.unlock(); return data }
        lutLock.unlock()
        let data = DevelopLUT.build(key, size: lutSize)
        lutLock.lock()
        luts[key] = data
        lutOrder.append(key)
        if lutOrder.count > 24 { luts[lutOrder.removeFirst()] = nil }
        lutLock.unlock()
        return data
    }

    // MARK: - Developing

    /// The developed photo as a picture to show or save. `maxSize` 0 is full size (slow with film).
    /// A preview is developed from the kept decode; full size (for saving) from the file.
    static func develop(_ path: String, record: PhotoRecord, maxSize: Int, worker: Int = 0) async throws -> CGImage? {
        let noise = isRaw(path) ? record.adjust.noise : 0
        let kept = maxSize > 0 ? base(path, maxSize: maxSize, record: record) : nil
        guard let source = kept?.image ?? source(path, maxSize: 0, denoise: record.denoiseKey, noise: noise, raw: RawSettings(record.adjust))
        else { return nil }
        guard record.filmOn else {
            let image = adjusted(source, record.adjust, path: path, cacheKey: kept?.key)
            return context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        // The film makes the picture from scene light: the light and local tone go in, the film's
        // own curve and colour do the rest.
        let image = adjusted(source, record.adjust, path: path, scene: true, cacheKey: kept?.key)
        // Through the film: raw linear floats in and out (pluck-spektra, darktable's port).
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        var pixels = Data(count: width * height * 16)
        pixels.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 16, bounds: extent, format: .RGBAf, colorSpace: linear)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-film", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = folder.appendingPathComponent("\(UUID().uuidString)-in.raw"), output = folder.appendingPathComponent("\(UUID().uuidString)-out.raw")
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
        }
        try pixels.write(to: input)
        // Grain and halation keep their size on the film however small the preview is.
        let full = maxSize > 0 ? max(fullLongEdge(path), width, height) : max(width, height)
        try await FilmEngine.shared.render(input, to: output, width: width, height: height, film: record.film, fullLongEdge: full, worker: worker)
        let developed = try Data(contentsOf: output)
        guard developed.count == width * height * 16 else { return nil }
        let picture = CIImage(bitmapData: developed, bytesPerRow: width * 16, size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: linear)
        return context.createCGImage(picture, from: picture.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    nonisolated(unsafe) private static var longEdges: [String: Int] = [:]

    /// The photo's own long side in pixels (without decoding it).
    static func fullLongEdge(_ path: String) -> Int {
        kelvinLock.lock()
        if let known = longEdges[path] { kelvinLock.unlock(); return known }
        kelvinLock.unlock()
        var long = 0
        if isRaw(path), let raw = CIRAWFilter(imageURL: URL(fileURLWithPath: path)) {
            long = Int(max(raw.nativeSize.width, raw.nativeSize.height))
        } else if let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            long = max(props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0)
        }
        kelvinLock.lock(); longEdges[path] = long; kelvinLock.unlock()
        return long
    }

    // MARK: - Decoded photos kept on the GPU

    /// The photo decoded once (RAW included) and kept on the GPU, so a slider only redoes the
    /// adjustments: that is what makes editing follow the mouse. `maxSize` 0: full size. The key
    /// names this decode (for the layers worked out from it).
    static func base(_ path: String, maxSize: Int, record: PhotoRecord) -> (image: CIImage, key: String)? {
        let noise = isRaw(path) ? record.adjust.noise : 0
        let denoise = record.denoiseKey
        let ready = denoise > 0 && denoised(path, strength: denoise).map { FileManager.default.fileExists(atPath: $0.path) } == true
        let settings = RawSettings(record.adjust)
        let key = "\(maxSize)|\(ready ? denoise : 0)|\(ready ? 0 : Int(noise))|\(settings.key)|\(path)"
        if let known = BaseCache.shared.image(key) { return (known, key) }
        guard let source = source(path, maxSize: maxSize, denoise: ready ? denoise : 0, noise: ready ? 0 : noise, raw: settings),
              let kept = BaseCache.shared.keep(source, key: key) else { return nil }
        return (kept, key)
    }

    /// The developed photo (the adjustments, no film), still to be drawn: for the screen.
    /// `maxSize` 0: full size, for looking closely (only the part on screen is worked out).
    static func image(_ path: String, record: PhotoRecord, maxSize: Int) -> CIImage? {
        guard let kept = base(path, maxSize: maxSize, record: record) else { return nil }
        return adjusted(kept.image, record.adjust, path: path, cacheKey: kept.key)
    }

    /// The adjustments only (no film), straight away, as a picture.
    static func quick(_ path: String, record: PhotoRecord, maxSize: Int) async -> CGImage? {
        guard let image = image(path, record: record, maxSize: maxSize) else { return nil }
        return picture(image)
    }

    /// The photo's light at its white balance (no exposure), small: brightness per pixel, and
    /// where macOS finds faces (shares of the photo, from the bottom left).
    static func measure(_ path: String, record: PhotoRecord) -> (luminance: [Float], width: Int, height: Int, faces: [CGRect])? {
        var plain = PhotoRecord()
        plain.adjust.temperature = record.adjust.temperature
        plain.adjust.tint = record.adjust.tint
        plain.adjust.rawDecoder = record.adjust.rawDecoder
        guard let kept = base(path, maxSize: 384, record: plain) else { return nil }
        let light = PhotoEngine.balanced(kept.image, plain.adjust, kelvin: asShotKelvin(path))
        let extent = light.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        context.render(light, toBitmap: &pixels, rowBytes: width * 16, bounds: extent, format: .RGBAf,
                       colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let luminance = (0..<(width * height)).map { i in 0.2126 * pixels[i * 4] + 0.7152 * pixels[i * 4 + 1] + 0.0722 * pixels[i * 4 + 2] }
        var faces: [CGRect] = []
        if let shown = picture(PhotoEngine.develop(kept.image, plain.adjust, isRaw: isRaw(path), asShotKelvin: asShotKelvin(path))) {
            let request = VNDetectFaceRectanglesRequest()
            try? VNImageRequestHandler(cgImage: shown).perform([request])
            faces = request.results?.map(\.boundingBox) ?? []
        }
        return (luminance, width, height, faces)
    }

    /// Auto for this photo (version 2): measured in scene light at its white balance, with the
    /// faces macOS finds weighed most.
    static func auto(_ path: String, record: PhotoRecord) -> PhotoAdjustments? {
        measure(path, record: record).map { PhotoEngine.auto(luminance: $0.luminance, width: $0.width, height: $0.height, faces: $0.faces) }
    }

    /// The photo's middle brightness before exposure, in stops from mid grey (faces weighed most).
    static func middle(_ path: String, record: PhotoRecord) -> Double? {
        measure(path, record: record).flatMap { PhotoEngine.middle(luminance: $0.luminance, width: $0.width, height: $0.height, faces: $0.faces) }
    }

    /// A developed image as a picture (sRGB), at most this long (0: as it is).
    static func picture(_ image: CIImage, maxSize: Int = 0) -> CGImage? {
        var image = image
        let long = max(image.extent.width, image.extent.height)
        if maxSize > 0, long > Double(maxSize) {
            let scale = Double(maxSize) / long
            image = image.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": scale, "inputAspectRatio": 1])
        }
        return context.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    // MARK: - Denoising

    /// Where the denoised photo is kept (by the photo, when it was changed, and the strength).
    static func denoised(_ path: String, strength: Int) -> URL? {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
        let key = "\(path)|\(modified.timeIntervalSince1970)|\(strength)"
        let name = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck/Denoised/\(name).exr")
    }

    /// Takes the noise out of the photo at full size, through the photo engine (about 15 s for
    /// 24 megapixels). The result is kept, and used from then on to develop it.
    /// `strength` over 1000 is the AI denoiser's (1000 + strength): kept apart from the other.
    static func denoise(_ path: String, strength: Int, worker: Int = 1) async throws {
        guard let output = denoised(path, strength: strength) else { throw NSError(domain: "Pluck", code: 1) }
        let ai = strength > 1000, amount = strength % 1000
        if FileManager.default.fileExists(atPath: output.path) { return }
        guard let image = source(path, maxSize: 0) else {
            throw NSError(domain: "Pluck", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "The photo couldn’t be read.")])
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-film/\(UUID().uuidString)-noisy.tif")
        try FileManager.default.createDirectory(at: input.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: input) }
        try context.writeTIFFRepresentation(of: image, to: input, format: .RGBAh, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        let partial = output.deletingPathExtension().appendingPathExtension("part.exr")
        try await FilmEngine.shared.denoise(input, to: partial, strength: Double(amount) / 100, ai: ai, worker: worker)
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: partial, to: output)
    }

    // MARK: - Previews kept on disk

    /// A developed preview, kept by the photo and its settings so the grid can show edits.
    static func cachedPreview(_ path: String, record: PhotoRecord) -> URL {
        var key = path
        if let data = try? JSONEncoder().encode(record.adjust) { key += String(decoding: data, as: UTF8.self) }
        if record.filmOn, let data = try? JSONEncoder().encode(record.film) { key += String(decoding: data, as: UTF8.self) }
        if record.denoise > 0 { key += "|denoise \(record.denoiseKey)" }
        let name = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/Photo Previews/\(name).jpg")
    }

    /// Keeps the previews (and denoised photos) under a size: the oldest go first. Run now and then.
    static func trimCaches() {
        Task.detached(priority: .background) {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            for (folder, limit) in [("Pluck/Photo Previews", 600_000_000), ("Pluck/Denoised", 6_000_000_000)] {
                let url = caches.appendingPathComponent(folder)
                let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
                guard let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys) else { continue }
                let sized = files.compactMap { file -> (URL, Date, Int)? in
                    guard let values = try? file.resourceValues(forKeys: Set(keys)) else { return nil }
                    return (file, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
                }
                var total = sized.reduce(0) { $0 + $1.2 }
                for (file, _, size) in sized.sorted(by: { $0.1 < $1.1 }) where total > limit {
                    try? FileManager.default.removeItem(at: file)
                    total -= size
                }
            }
        }
    }

    static func savePreview(_ image: CGImage, to url: URL) {
        // The grid's copy: small is enough there.
        var image = image
        if max(image.width, image.height) > 1200, let small = picture(CIImage(cgImage: image), maxSize: 1200) { image = small }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    // MARK: - Export

    enum Format: String, CaseIterable, Identifiable {
        case jpeg, heic, tiff, png
        var id: String { rawValue }
        var title: String { rawValue == "jpeg" ? "JPEG" : rawValue.uppercased() }
        var type: UTType {
            switch self {
            case .jpeg: .jpeg
            case .heic: .heic
            case .tiff: .tiff
            case .png: .png
            }
        }
        var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    }

    /// Writes the developed photo: full size (or this long side), in this format.
    static func export(_ path: String, record: PhotoRecord, to folder: URL, format: Format, quality: Double, longSide: Int,
                       worker: Int = 1) async throws -> URL {
        guard var image = try await develop(path, record: record, maxSize: 0, worker: worker) else {
            throw NSError(domain: "Pluck", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "The photo couldn’t be read.")])
        }
        if longSide > 0, max(image.width, image.height) > longSide {
            let scale = Double(longSide) / Double(max(image.width, image.height))
            let resized = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            if let smaller = context.createCGImage(resized, from: resized.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) {
                image = smaller
            }
        }
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let output = Converting.outputURL(folder: folder.path, name: name, fileExtension: format.fileExtension)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Pluck", code: 2)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "Pluck", code: 3) }
        return output
    }
}

/// The decoded photos, kept on the GPU (as half floats) within a share of the Mac's memory; the
/// least recently used go first, and all of them when the Mac runs short.
final class BaseCache: @unchecked Sendable {
    static let shared = BaseCache()
    private var images: [String: (image: CIImage, bytes: Int)] = [:]
    private var order: [String] = []
    private var total = 0
    private let budget = Int(min(ProcessInfo.processInfo.physicalMemory / 5, 4 << 30))
    private let lock = NSLock()
    private let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))

    private init() {
        pressure.setEventHandler { [weak self] in
            self?.removeAll()
            GuideCache.shared.removeAll()
        }
        pressure.activate()
    }

    func image(_ key: String) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        guard let known = images[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return known.image
    }

    /// Decodes the photo into a texture now and keeps it.
    func keep(_ source: CIImage, key: String) -> CIImage? {
        let extent = source.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0, let device = PhotoEngine.device, let queue = Self.queue,
              let buffer = queue.makeCommandBuffer() else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: buffer)
        destination.colorSpace = linear
        guard (try? PhotoEngine.context.startTask(toRender: source.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)),
                                                  to: destination)) != nil else { return nil }
        buffer.commit()
        buffer.waitUntilCompleted()
        guard let image = CIImage(mtlTexture: texture, options: [.colorSpace: linear]) else { return nil }
        let bytes = width * height * 8
        lock.lock()
        if let old = images[key] { total -= old.bytes; order.removeAll { $0 == key } }
        images[key] = (image, bytes)
        order.append(key)
        total += bytes
        while total > budget, order.count > 1 {
            let oldest = order.removeFirst()
            total -= images[oldest]?.bytes ?? 0
            images[oldest] = nil
        }
        lock.unlock()
        return image
    }

    func removeAll() {
        lock.lock(); images = [:]; order = []; total = 0; lock.unlock()
    }

    private static let queue = PhotoEngine.device?.makeCommandQueue()
}
