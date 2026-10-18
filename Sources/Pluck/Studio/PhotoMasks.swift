import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// Masks for local adjustments: the subject (people, animals, things in front), found by
/// Vision on this Mac, and the rest. Worked out once per photo, small, and scaled to fit.
enum PhotoMasks {
    nonisolated(unsafe) private static var subjects: [String: CIImage] = [:]
    private static let lock = NSLock()
    /// How many masks a photo can have (they share one layer, a channel each).
    static let limit = 4

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

    // MARK: - Version 2: shapes

    nonisolated(unsafe) private static var people: [String: CIImage] = [:]
    nonisolated(unsafe) private static var objects: [String: CIImage] = [:]
    nonisolated(unsafe) private static var layers: [String: CIImage] = [:]
    nonisolated(unsafe) private static var layerOrder: [String] = []

    /// The masks' shapes as one layer, small (at most 1536 on the long side): mask k in channel
    /// k (white where it applies). The ranges and turning the whole mask round are done in the
    /// develop pass. Kept per photo and shape, so a slider never remakes it.
    static func layer(_ masks: [PhotoMask], path: String, base: CIImage, context: CIContext) -> CIImage? {
        let masks = Array(masks.prefix(limit))
        guard !masks.isEmpty else { return nil }
        let e = base.extent
        let scale = min(1, 1536 / max(e.width, e.height))
        let width = max(Int((e.width * scale).rounded()), 1), height = max(Int((e.height * scale).rounded()), 1)
        let shapes = masks.map { $0.shape.filter { !$0.kind.isRange } }
        // (The depth finder arriving makes Sky and Depth Range parts something.)
        let depth = shapes.joined().contains { $0.kind.needsDepth } && PhotoDepth.isReady
        let key = path + "|\(width)x\(height)|\(depth)|" + ((try? String(decoding: JSONEncoder().encode(shapes), as: UTF8.self)) ?? "")
        lock.lock()
        if let known = layers[key] { lock.unlock(); return known.transformed(by: CGAffineTransform(scaleX: e.width / CGFloat(width), y: e.height / CGFloat(height))) }
        lock.unlock()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let size = CGSize(width: width, height: height)
        for (k, parts) in shapes.enumerated() {
            let grey = combine(parts, path: path, base: base, size: size, context: context)
            var plane = [UInt8](repeating: 0, count: width * height)
            context.render(grey, toBitmap: &plane, rowBytes: width, bounds: CGRect(origin: .zero, size: size), format: .L8,
                           colorSpace: nil)
            for i in 0..<(width * height) { bytes[i * 4 + k] = plane[i] }
        }
        let made = CIImage(bitmapData: Data(bytes), bytesPerRow: width * 4, size: size, format: .RGBA8, colorSpace: nil)
        lock.lock()
        layers[key] = made
        layerOrder.append(key)
        if layerOrder.count > 16 { layers[layerOrder.removeFirst()] = nil }
        lock.unlock()
        return made.transformed(by: CGAffineTransform(scaleX: e.width / CGFloat(width), y: e.height / CGFloat(height)))
    }

    /// One mask's drawn and found parts, combined in order, as grey at this size (white: in).
    private static func combine(_ parts: [MaskPart], path: String, base: CIImage, size: CGSize, context: CIContext) -> CIImage {
        let frame = CGRect(origin: .zero, size: size)
        let white = CIImage(color: .white).cropped(to: frame)
        guard !parts.isEmpty else { return white }
        var result: CIImage?
        for part in parts {
            var shape = draw(part, path: path, base: base, size: size, context: context).cropped(to: frame)
            if part.invert { shape = shape.applyingFilter("CIColorInvert") }
            guard let so = result else { result = part.mode == .subtract ? shape.applyingFilter("CIColorInvert") : shape; continue }
            switch part.mode {
            case .add: result = shape.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: so])
            case .subtract: result = shape.applyingFilter("CIColorInvert").applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: so])
            case .intersect: result = shape.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: so])
            }
        }
        return (result ?? white).cropped(to: frame)
    }

    /// One part, grey at this size. Points are shares from the top left; Core Image counts from
    /// the bottom left.
    private static func draw(_ part: MaskPart, path: String, base: CIImage, size: CGSize, context: CIContext) -> CIImage {
        let frame = CGRect(origin: .zero, size: size)
        let black = CIImage(color: .black).cropped(to: frame)
        func at(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height) }
        switch part.kind {
        case .linear:
            let gradient = CIFilter(name: "CISmoothLinearGradient", parameters: [
                "inputPoint0": CIVector(cgPoint: at(part.a)), "inputPoint1": CIVector(cgPoint: at(part.b)),
                "inputColor0": CIColor.white, "inputColor1": CIColor.black,
            ])?.outputImage
            return gradient?.cropped(to: frame) ?? black
        case .radial:
            // A circle of radius 1, made the ellipse's size and put at its centre.
            let inner = max(0.001, 1 - part.feather)
            let unit = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: 0, y: 0), "inputRadius0": inner * 100, "inputRadius1": 100,
                "inputColor0": CIColor.white, "inputColor1": CIColor.black,
            ])?.outputImage
            let centre = at(part.a)
            let shaped = unit?.transformed(by: CGAffineTransform(scaleX: part.radius.width * size.width / 100, y: part.radius.height * size.height / 100)
                .concatenating(CGAffineTransform(translationX: centre.x, y: centre.y)))
            return shaped?.cropped(to: frame) ?? black
        case .brush:
            return brush(part.strokes, size: size)
        case .subject:
            return scaled(subject(path, from: base, context: context), to: size, guide: base, context: context) ?? black
        case .people:
            return scaled(person(path, from: base, context: context), to: size, guide: base, context: context) ?? black
        case .object:
            lock.lock(); let found = objects[objectKey(path, part.a)]; lock.unlock()
            return scaled(found, to: size, guide: base, context: context) ?? black
        case .depth:
            guard let near = PhotoDepth.nearness(path, from: base, context: context) else { return black }
            // How far, in the window asked for (with soft edges).
            let far = near.applyingFilter("CIColorInvert")
            let windowed = far.applyingFilter("CIColorMap", parameters: ["inputGradientImage": window(low: part.low, high: part.high, soft: max(part.smooth, 0.02))])
            return scaled(windowed, to: size, guide: base, context: context) ?? black
        case .sky:
            guard let near = PhotoDepth.nearness(path, from: base, context: context) else { return black }
            // The farthest places that are bright: open sky, not far-off ground in shadow.
            let far = near.applyingFilter("CIColorInvert").applyingFilter("CIColorMap", parameters: ["inputGradientImage": window(low: 0.94, high: 1.2, soft: 0.04)])
            let m = near.extent, b = base.extent
            let light = base.transformed(by: CGAffineTransform(translationX: -b.minX, y: -b.minY).concatenating(CGAffineTransform(scaleX: m.width / b.width, y: m.height / b.height)))
                .applyingFilter("CILinearToSRGBToneCurve").applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
                .applyingFilter("CIColorMap", parameters: ["inputGradientImage": window(low: 0.32, high: 2, soft: 0.15)]).cropped(to: m)
            // A little wider than it's found, so no light fringe is left along what stands against it.
            let sky = far.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: light]).cropped(to: m)
                .clampedToExtent().applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": 6]).cropped(to: m)
            return scaled(sky, to: size, guide: base, context: context) ?? black
        case .luminance, .colour:
            return CIImage(color: .white).cropped(to: frame)
        }
    }

    /// A grey ramp (for CIColorMap): white from `low` to `high` (0…1), fading over `soft`.
    private static func window(low: Double, high: Double, soft: Double) -> CIImage {
        var bytes = [UInt8](repeating: 0, count: 256 * 4)
        for i in 0..<256 {
            let x = Double(i) / 255
            func step(_ a: Double, _ b: Double, _ v: Double) -> Double { let t = min(max((v - a) / max(b - a, 1e-4), 0), 1); return t * t * (3 - 2 * t) }
            let v = step(low - soft, low, x) * (1 - step(high, high + soft, x))
            let g = UInt8((v * 255).rounded())
            bytes[i * 4] = g; bytes[i * 4 + 1] = g; bytes[i * 4 + 2] = g; bytes[i * 4 + 3] = 255
        }
        return CIImage(bitmapData: Data(bytes), bytesPerRow: 256 * 4, size: CGSize(width: 256, height: 1), format: .RGBA8, colorSpace: nil)
    }

    /// A found mask made this size, its edges drawn to the photo's (a guided filter: hair and
    /// fine edges follow the picture instead of the small mask's blur).
    private static func scaled(_ mask: CIImage?, to size: CGSize, guide: CIImage, context: CIContext) -> CIImage? {
        guard let mask else { return nil }
        let m = mask.extent, g = guide.extent
        let fitted = mask.transformed(by: CGAffineTransform(translationX: -m.minX, y: -m.minY)
            .concatenating(CGAffineTransform(scaleX: size.width / m.width, y: size.height / m.height)))
        let picture = guide.transformed(by: CGAffineTransform(translationX: -g.minX, y: -g.minY)
            .concatenating(CGAffineTransform(scaleX: size.width / g.width, y: size.height / g.height)))
            .applyingFilter("CILinearToSRGBToneCurve").applyingFilter("CIMaximumComponent")
        let frame = CGRect(origin: .zero, size: size)
        let margin = frame.insetBy(dx: -24, dy: -24)
        return fitted.clampedToExtent().cropped(to: margin).applyingFilter("CIGuidedFilter", parameters: ["inputGuideImage": picture.clampedToExtent().cropped(to: margin),
                                                                                      "inputRadius": max(size.width, size.height) / 300,
                                                                                      "inputEpsilon": 0.0008]).cropped(to: frame)
    }

    /// Brush strokes painted (white; rubbing out paints black), softened by their softness.
    private static func brush(_ strokes: [BrushStroke], size: CGSize) -> CIImage {
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0, let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)) }
        canvas.setFillColor(gray: 0, alpha: 1)
        canvas.fill(CGRect(origin: .zero, size: size))
        canvas.setLineCap(.round)
        canvas.setLineJoin(.round)
        let long = max(size.width, size.height)
        var soft = 0.0
        for stroke in strokes where !stroke.points.isEmpty {
            canvas.setStrokeColor(gray: stroke.erase ? 0 : 1, alpha: 1)
            canvas.setLineWidth(stroke.size * long)
            let points = stroke.points.map { CGPoint(x: $0.x * size.width, y: (1 - $0.y) * size.height) }
            canvas.beginPath()
            canvas.move(to: points[0])
            for point in points.dropFirst() { canvas.addLine(to: point) }
            if points.count == 1 { canvas.addLine(to: CGPoint(x: points[0].x + 0.01, y: points[0].y)) }
            canvas.strokePath()
            soft = max(soft, stroke.size * long * stroke.softness * 0.4)
        }
        guard let painted = canvas.makeImage() else { return CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)) }
        let image = CIImage(cgImage: painted)
        let frame = CGRect(origin: .zero, size: size)
        return soft > 0.5 ? image.clampedToExtent().applyingGaussianBlur(sigma: soft).cropped(to: frame) : image
    }

    /// The people in the photo (macOS's person segmentation, at its best quality), small.
    static func person(_ path: String, from image: CIImage, context: CIContext) -> CIImage? {
        lock.lock()
        if let known = people[path] { lock.unlock(); return known }
        lock.unlock()
        let scale = min(1, 1024 / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try? VNImageRequestHandler(cgImage: cg).perform([request])
        let mask = request.results?.first.map { CIImage(cvPixelBuffer: $0.pixelBuffer) }
            ?? CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        lock.lock(); people[path] = mask; if people.count > 24 { people.removeValue(forKey: people.keys.first!) }; lock.unlock()
        return mask
    }

    private static func objectKey(_ path: String, _ point: CGPoint) -> String {
        "\(path)|\(Int(point.x * 1000))|\(Int(point.y * 1000))"
    }

    /// Whether the object at this point was found (and is kept).
    static func hasObject(_ path: String, at point: CGPoint) -> Bool {
        lock.withLock { objects[objectKey(path, point)] != nil }
    }

    /// Whether this Mac can find an object from a click (macOS 27).
    static var canFindObjects: Bool {
        if #available(macOS 27, *) { return true }
        return false
    }

    /// The object at this point (shares from the top left), found by macOS 27 and kept. Its model
    /// is downloaded by macOS the first time (`downloading` is told). False when none was found.
    static func findObject(_ path: String, at point: CGPoint, from image: CIImage, context: CIContext,
                           downloading: @Sendable @escaping () -> Void = {}) async -> Bool {
        guard #available(macOS 27, *) else { return false }
        let scale = min(1, 1024 / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        else { return false }
        let request = GenerateIterativeSegmentationRequest(seedPoint: NormalizedPoint(x: point.x, y: 1 - point.y))
        request.qualityLevel = .accurate
        if await request.assetStatus != .ready {
            downloading()
            do { try await request.downloadAssets() } catch { return false }
        }
        guard let observation = try? await request.perform(on: cg),
              let picture = try? observation.cgImage else { return false }
        keep(CIImage(cgImage: picture), as: objectKey(path, point))
        return true
    }

    private static func keep(_ mask: CIImage, as key: String) {
        lock.withLock { objects[key] = mask }
    }
}
