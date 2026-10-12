import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Develops a photo: the adjustments with Core Image (instant), then, when film is on, the film
/// and paper through spektrafilm (about a second for a preview, longer at full size). RAW files
/// are read with Apple's RAW engine.
enum PhotoRender {
    nonisolated(unsafe) private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                                                         .cacheIntermediates: false])

    /// The photo, at most this many pixels on its long side (0: full size): the denoised one
    /// when there is one for this strength.
    static func source(_ path: String, maxSize: Int, denoise: Int = 0) -> CIImage? {
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
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .rawImage), let raw = CIRAWFilter(imageURL: url) {
            if maxSize > 0 {
                let long = max(raw.nativeSize.width, raw.nativeSize.height)
                if long > 0 { raw.scaleFactor = Float(min(1, Double(maxSize) / long)) }
            }
            return raw.outputImage
        }
        if maxSize > 0, let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxSize,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { return CIImage(cgImage: image) }
        }
        return CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }

    /// The adjustments, in the order a photo editor applies them. Light and colour go through one
    /// lookup table (no halos, and fast enough to follow a slider); clarity and sharpening are the
    /// only local passes.
    static func adjusted(_ image: CIImage, _ a: PhotoAdjustments) -> CIImage {
        var image = image
        let long = max(image.extent.width, image.extent.height)
        if a.exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = image
            filter.ev = Float(a.exposure)
            image = filter.outputImage ?? image
        }
        if a.noise > 0 {
            let filter = CIFilter.noiseReduction()
            filter.inputImage = image
            filter.noiseLevel = Float(a.noise / 100 * 0.06)
            filter.sharpness = 0.4
            image = filter.outputImage ?? image
        }
        if a.needsLUT {
            let headroom = DevelopLUT.headroom(a)
            if headroom > 1 {
                let filter = CIFilter.exposureAdjust()
                filter.inputImage = image
                filter.ev = Float(-log2(headroom))
                image = filter.outputImage ?? image
            }
            let filter = CIFilter.colorCubeWithColorSpace()
            filter.inputImage = image
            filter.cubeDimension = Float(lutSize)
            filter.cubeData = lut(for: a)
            filter.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            image = filter.outputImage ?? image
        }
        if a.clarity > 0 {
            // Local contrast in the midtones: a wide, gentle unsharp mask.
            let filter = CIFilter.unsharpMask()
            filter.inputImage = image
            filter.radius = Float(long / 60)
            filter.intensity = Float(a.clarity / 100 * 0.45)
            image = filter.outputImage ?? image
        } else if a.clarity < 0 {
            // Softer: blend towards a wide blur, which lowers local contrast (a glow, not a smear).
            let blur = image.clampedToExtent().applyingGaussianBlur(sigma: Double(long / 120)).cropped(to: image.extent)
            let filter = CIFilter.dissolveTransition()
            filter.inputImage = image
            filter.targetImage = blur
            filter.time = Float(-a.clarity / 100 * 0.55)
            image = filter.outputImage ?? image
        }
        if a.sharpen > 0 {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = image
            filter.sharpness = Float(a.sharpen / 100 * 0.9)
            filter.radius = Float(max(1.5, long / 2400))
            image = filter.outputImage ?? image
        }
        image = geometry(image, a)
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
        } else if let ratio = a.crop.ratio {
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
        key.contrast = a.contrast; key.highlights = a.highlights; key.shadows = a.shadows; key.whites = a.whites; key.blacks = a.blacks
        key.temperature = a.temperature; key.tint = a.tint; key.vibrance = a.vibrance; key.saturation = a.saturation
        key.curves = a.curves; key.wheels = a.wheels
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
        guard let source = maxSize > 0 ? previewBase(path, maxSize: maxSize, denoise: record.denoise)
            : source(path, maxSize: 0, denoise: record.denoise) else { return nil }
        let image = adjusted(source, record.adjust)
        guard record.filmOn else {
            return context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        // Through the film: a linear float TIFF in, spektrafilm, a 16-bit TIFF out.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-film", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = folder.appendingPathComponent("\(UUID().uuidString)-in.tif"), output = folder.appendingPathComponent("\(UUID().uuidString)-out.tif")
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
        }
        try context.writeTIFFRepresentation(of: image, to: input, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        try await FilmEngine.shared.render(input, to: output, film: record.film, preview: maxSize > 0, maxSize: max(maxSize, 640), worker: worker)
        // Read into memory now: the file is removed when this returns, and an image read from a
        // file is only decoded when it's drawn.
        let data = try Data(contentsOf: output)
        guard let rendered = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(rendered, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    // MARK: - Decoded photos kept in memory

    nonisolated(unsafe) private static var bases: [String: CIImage] = [:]
    nonisolated(unsafe) private static var baseOrder: [String] = []
    private static let baseLock = NSLock()

    /// The photo decoded once at preview size (RAW included) and kept, so a slider only redoes
    /// the adjustments: that is what makes editing follow the mouse.
    static func previewBase(_ path: String, maxSize: Int, denoise: Int = 0) -> CIImage? {
        let ready = denoise > 0 && denoised(path, strength: denoise).map { FileManager.default.fileExists(atPath: $0.path) } == true
        let key = "\(maxSize)|\(ready ? denoise : 0)|\(path)"
        baseLock.lock()
        if let base = bases[key] { baseLock.unlock(); return base }
        baseLock.unlock()
        guard let source = source(path, maxSize: maxSize, denoise: ready ? denoise : 0) else { return nil }
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        guard let decoded = context.createCGImage(source, from: source.extent, format: .RGBAh, colorSpace: linear) else { return source }
        let base = CIImage(cgImage: decoded)
        baseLock.lock()
        bases[key] = base
        baseOrder.append(key)
        if baseOrder.count > 6 { bases[baseOrder.removeFirst()] = nil }
        baseLock.unlock()
        return base
    }

    /// The adjustments only (no film), straight away: for following a slider.
    static func quick(_ path: String, record: PhotoRecord, maxSize: Int) async -> CGImage? {
        guard let base = previewBase(path, maxSize: maxSize, denoise: record.denoise) else { return nil }
        let image = adjusted(base, record.adjust)
        return context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    // MARK: - Denoising

    /// Where the denoised photo is kept (by the photo, when it was changed, and the strength).
    static func denoised(_ path: String, strength: Int) -> URL? {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
        let key = "\(path)|\(modified.timeIntervalSince1970)|\(strength)"
        let name = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck/Denoised/\(name).tif")
    }

    /// Takes the noise out of the photo at full size, through the photo engine (about 15 s for
    /// 24 megapixels). The result is kept, and used from then on to develop it.
    static func denoise(_ path: String, strength: Int, worker: Int = 1) async throws {
        guard let output = denoised(path, strength: strength) else { throw NSError(domain: "Pluck", code: 1) }
        if FileManager.default.fileExists(atPath: output.path) { return }
        guard let image = source(path, maxSize: 0) else {
            throw NSError(domain: "Pluck", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "The photo couldn’t be read.")])
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-film/\(UUID().uuidString)-noisy.tif")
        try FileManager.default.createDirectory(at: input.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: input) }
        try context.writeTIFFRepresentation(of: image, to: input, format: .RGBAh, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        let partial = output.deletingPathExtension().appendingPathExtension("part.tif")
        try await FilmEngine.shared.denoise(input, to: partial, strength: Double(strength) / 100, worker: worker)
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: partial, to: output)
    }

    // MARK: - Previews kept on disk

    /// A developed preview, kept by the photo and its settings so the grid can show edits.
    static func cachedPreview(_ path: String, record: PhotoRecord) -> URL {
        var key = path
        if let data = try? JSONEncoder().encode(record.adjust) { key += String(decoding: data, as: UTF8.self) }
        if record.filmOn, let data = try? JSONEncoder().encode(record.film) { key += String(decoding: data, as: UTF8.self) }
        if record.denoise > 0 { key += "|denoise \(record.denoise)" }
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
