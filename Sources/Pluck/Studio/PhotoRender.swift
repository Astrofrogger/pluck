import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Develops a photo with Pluck's photo engine (PhotoEngine: neutral RAW, local tone, profiles,
/// on the GPU), then, when film is on, the film and paper through spektrafilm (about a second
/// for a preview, longer at full size).
enum PhotoRender {
    nonisolated(unsafe) private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                                                         .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])

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
    static func source(_ path: String, maxSize: Int, denoise: Int = 0, noise: Double = 0) -> CIImage? {
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
            neutral(raw, noise: noise)
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
    /// kept, no sharpening (Pluck sharpens last), lens corrections on.
    static func neutral(_ raw: CIRAWFilter, noise: Double) {
        raw.boostAmount = 0
        raw.boostShadowAmount = 0
        raw.localToneMapAmount = 0
        raw.extendedDynamicRangeAmount = 2
        raw.sharpnessAmount = 0
        raw.isLensCorrectionEnabled = true
        if noise > 0 {
            raw.luminanceNoiseReductionAmount = Float(noise / 100)
            raw.colorNoiseReductionAmount = Float(max(Double(raw.colorNoiseReductionAmount), noise / 100))
        }
    }

    /// The adjustments, in the order a photo editor applies them: light and white balance, local
    /// tone and the profile (the photo engine), colour (a lookup table), noise, sharpening,
    /// straightening and crop, vignette. `scene`: light only, for the film engine.
    static func adjusted(_ image: CIImage, _ a: PhotoAdjustments, isRaw: Bool, kelvin: Double, scene: Bool = false, crop: Bool = true,
                         path: String? = nil) -> CIImage {
        let base = image
        var image = PhotoEngine.develop(image, a, isRaw: isRaw, asShotKelvin: kelvin, scene: scene)
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
    static func adjusted(_ image: CIImage, _ a: PhotoAdjustments, path: String, scene: Bool = false, crop: Bool = true) -> CIImage {
        adjusted(image, a, isRaw: isRaw(path), kelvin: asShotKelvin(path), scene: scene, crop: crop, path: path)
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
    static func develop(_ path: String, record: PhotoRecord, maxSize: Int, worker: Int = 0) async throws -> CGImage? {
        let noise = isRaw(path) ? record.adjust.noise : 0
        guard let source = maxSize > 0 ? previewBase(path, maxSize: maxSize, denoise: record.denoiseKey, noise: noise)
            : source(path, maxSize: 0, denoise: record.denoiseKey, noise: noise) else { return nil }
        guard record.filmOn else {
            let image = adjusted(source, record.adjust, path: path)
            return context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        // The film makes the picture from scene light: the light and local tone go in, the film's
        // own curve and colour do the rest.
        let image = adjusted(source, record.adjust, path: path, scene: true)
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

    // MARK: - Decoded photos kept in memory

    nonisolated(unsafe) private static var bases: [String: CIImage] = [:]
    nonisolated(unsafe) private static var baseOrder: [String] = []
    private static let baseLock = NSLock()

    /// The photo decoded once at preview size (RAW included) and kept, so a slider only redoes
    /// the adjustments: that is what makes editing follow the mouse.
    static func previewBase(_ path: String, maxSize: Int, denoise: Int = 0, noise: Double = 0) -> CIImage? {
        let ready = denoise > 0 && denoised(path, strength: denoise).map { FileManager.default.fileExists(atPath: $0.path) } == true
        let key = "\(maxSize)|\(ready ? denoise : 0)|\(Int(noise))|\(path)"
        baseLock.lock()
        if let base = bases[key] { baseLock.unlock(); return base }
        baseLock.unlock()
        guard let source = source(path, maxSize: maxSize, denoise: ready ? denoise : 0, noise: ready ? 0 : noise) else { return nil }
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        guard let decoded = context.createCGImage(source, from: source.extent, format: .RGBAh, colorSpace: linear) else { return source }
        let base = CIImage(cgImage: decoded)
        baseLock.lock()
        bases[key] = base
        baseOrder.append(key)
        if baseOrder.count > 5 { bases[baseOrder.removeFirst()] = nil }
        baseLock.unlock()
        return base
    }

    nonisolated(unsafe) private static var full: (key: String, image: CIImage)?

    /// The photo decoded at full size (one kept, for looking closely).
    static func fullBase(_ path: String, denoise: Int, noise: Double) -> CIImage? {
        let ready = denoise > 0 && denoised(path, strength: denoise).map { FileManager.default.fileExists(atPath: $0.path) } == true
        let key = "\(ready ? denoise : 0)|\(Int(noise))|\(path)"
        baseLock.lock()
        if let full, full.key == key { baseLock.unlock(); return full.image }
        baseLock.unlock()
        guard let source = source(path, maxSize: 0, denoise: ready ? denoise : 0, noise: ready ? 0 : noise),
              let decoded = context.createCGImage(source, from: source.extent, format: .RGBAh,
                                                  colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!) else { return nil }
        let image = CIImage(cgImage: decoded)
        baseLock.lock(); full = (key, image); baseLock.unlock()
        return image
    }

    /// Part of the developed photo at a zoom (1: one photo pixel per screen pixel): `size` screen
    /// pixels around `center` (shares of the picture, from the top left). Only that part is worked
    /// out. Also the picture's full size.
    static func region(_ path: String, record: PhotoRecord, center: CGPoint, size: CGSize, zoom: Double) async -> (image: CGImage, full: CGSize)? {
        guard let base = fullBase(path, denoise: record.denoiseKey, noise: isRaw(path) ? record.adjust.noise : 0) else { return nil }
        let image = adjusted(base, record.adjust, path: path)
        let e = image.extent
        // The part of the photo that fills the view, in photo pixels.
        let w = min(size.width / zoom, e.width), h = min(size.height / zoom, e.height)
        let x = min(max(e.minX + center.x * e.width - w / 2, e.minX), e.maxX - w)
        let y = min(max(e.maxY - center.y * e.height - h / 2, e.minY), e.maxY - h)
        let part = image.cropped(to: CGRect(x: x, y: y, width: w, height: h))
            .transformed(by: CGAffineTransform(translationX: -x, y: -y).concatenating(CGAffineTransform(scaleX: zoom, y: zoom)))
        let out = CGRect(x: 0, y: 0, width: (w * zoom).rounded(), height: (h * zoom).rounded())
        guard let cg = context.createCGImage(zoom >= 1.5 ? part.samplingNearest() : part, from: out, format: .RGBA8,
                                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        return (cg, e.size)
    }

    /// The adjustments only (no film), straight away: for following a slider.
    static func quick(_ path: String, record: PhotoRecord, maxSize: Int) async -> CGImage? {
        guard let base = previewBase(path, maxSize: maxSize, denoise: record.denoiseKey, noise: isRaw(path) ? record.adjust.noise : 0) else { return nil }
        let image = adjusted(base, record.adjust, path: path)
        return context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
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
        let long = max(image.width, image.height)
        if long > 1200 {
            let scale = 1200 / Double(long)
            let small = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            if let made = context.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) {
                image = made
            }
        }
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
