import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import ImageIO
import Metal
import simd
import Vision
import UniformTypeIdentifiers

/// Develops a photo with Pluck's photo engine (PhotoEngine: neutral RAW, local tone, profiles,
/// on the GPU), then, when film is on, the film and paper: on the GPU in the same chain from the
/// shipped tables (FilmLook, FilmRoute's `instant`), or through spektrafilm's helper for settings
/// those can't do (about a second for a preview, longer at full size).
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
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: PhotoCatalog.file(of: path)) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double, let h = props[kCGImagePropertyPixelHeight] as? Double else { return false }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? w > h : h > w
    }

    static func isRaw(_ path: String) -> Bool {
        UTType(filenameExtension: URL(fileURLWithPath: PhotoCatalog.file(of: path)).pathExtension)?.conforms(to: .rawImage) == true
    }

    nonisolated(unsafe) private static var kelvins: [String: Double] = [:]
    private static let kelvinLock = NSLock()

    /// The light the camera balanced for (RAW), in Kelvin; 6500 for other photos.
    static func asShotKelvin(_ path: String) -> Double {
        guard isRaw(path) else { return 6500 }
        kelvinLock.lock()
        if let known = kelvins[path] { kelvinLock.unlock(); return known }
        kelvinLock.unlock()
        let value = CIRAWFilter(imageURL: URL(fileURLWithPath: PhotoCatalog.file(of: path))).map { Double($0.neutralTemperature) } ?? 5500
        kelvinLock.lock(); kelvins[path] = value; kelvinLock.unlock()
        return value
    }

    nonisolated(unsafe) private static var baselines: [String: Double] = [:]

    /// The camera's baseline exposure (RAW; 0 for other photos), in stops: version 3 adds it (PhotoEngine.develop).
    static func baselineExposure(_ path: String) -> Double {
        guard isRaw(path) else { return 0 }
        kelvinLock.lock()
        if let known = baselines[path] { kelvinLock.unlock(); return known }
        kelvinLock.unlock()
        let value = CIRAWFilter(imageURL: URL(fileURLWithPath: PhotoCatalog.file(of: path))).map { Double($0.baselineExposure) } ?? 0
        kelvinLock.lock(); baselines[path] = value.isFinite ? value : 0; kelvinLock.unlock()
        return value.isFinite ? value : 0
    }

    nonisolated(unsafe) private static var isos: [String: Double] = [:]

    /// The photo's ISO from its metadata (0 when it has none; Canon's CR3 has only the recommended exposure index).
    static func iso(_ file: String) -> Double {
        kelvinLock.lock()
        if let known = isos[file] { kelvinLock.unlock(); return known }
        kelvinLock.unlock()
        var value = 0.0
        if let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: file) as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            value = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Double])?.first ?? exif[kCGImagePropertyExifRecommendedExposureIndex] as? Double ?? 0
        }
        kelvinLock.lock(); isos[file] = value; kelvinLock.unlock()
        return value
    }

    /// How much of version 3's luminance noise reduction process 4 keeps at Luminance 0: none up to ISO 1600, all of it at
    /// 6400, in between by stops (half at 3200). Measured with it off: ISO 1600's lifted shadows 1.2× version 3's noise
    /// (texture mostly), ISO 6400's 2.7× (visible speckle).
    static func lumaShare(iso: Double) -> Double { iso > 0 ? min(max(log2(iso / 1600) / 2, 0), 1) : 0 }

    /// The photo, at most this many pixels on its long side (0: full size), in linear light. RAW
    /// is decoded neutral: none of the camera maker's look, so every camera starts the same.
    /// `noise`: Apple's luminance noise reduction, `color`: Pluck's colour noise reduction (RAW), 0…100.
    /// `file`: a DNG standing in for the RAW (the raw denoiser's), decoded the same way.
    /// `luma`: version 3's own luminance noise reduction too (lumaNoiseReduced), the Luminance slider making it stronger;
    /// off for what the denoisers are given, which must keep the noise as it is.
    static func source(_ path: String, maxSize: Int, noise: Double = 0, color: Double = 50, raw settings: RawSettings = RawSettings(), file: URL? = nil,
                       luma: Bool = false) -> CIImage? {
        let url = file ?? URL(fileURLWithPath: PhotoCatalog.file(of: path))
        if isRaw(path) || file != nil, let raw = CIRAWFilter(imageURL: url) {
            if maxSize > 0 {
                let long = max(raw.nativeSize.width, raw.nativeSize.height)
                // Not under half: Apple's smaller decodes lose the deepest shadows' red and blue (measured at a quarter:
                // red to green 0.24 against 0.42 at full size), which lifted shadows show as a green cast. Scaled after.
                if long > 0 { raw.scaleFactor = Float(min(1, max(0.5, Double(maxSize) / long))) }
            }
            // (The raw denoiser's DNGs keep the pinned decoder: decoder 9 left a few dark spots in its clean one, measured.)
            neutral(raw, noise: noise, color: 0, moire: settings.moire, decoder: settings.decoder, modern: settings.wideColourNoise && file == nil)
            // Lens correction leaves an unfilled edge: a sliver (0.4%) goes.
            guard var image = raw.outputImage else { return nil }
            // Process 4: the lens's fall-off put back from the camera's own shading data (Apple's lens correction leaves it).
            if settings.lighter, let knots = lensShading(PhotoCatalog.file(of: path)) { image = shaded(image, knots) }
            // Decoder 9 sharpens as it decodes (measured against 8 on bright detail: 1.5 times the contrast at 1–2 px, 1.23 at
            // 2–4, 1.09 at 4–8, at its own pixels), which looked crunchy beside Lightroom: taken back to about decoder 8's, as
            // 0.65 of the pixel, 0.3 of its blur over 1.5 px and 0.05 over 4 (bright detail within 8–19% of 8's at 1–1.5 px,
            // 2–5% coarser, full and half size).
            let nine = Double(raw.decoderVersion.rawValue.prefix { $0 != "." }) ?? 0 >= 9 && settings.wideColourNoise
            // Process 4 takes back half of that on the brightness (the owner's pick beside version 3, 2026-11-06).
            if nine, let soften = lumaKernels[settings.lighter ? "soften4" : "soften"] {
                func blur(_ r: Double) -> CIImage { image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: r]) }
                image = soften.apply(extent: image.extent, arguments: [image, blur(1.5), blur(4)]) ?? image
            }
            if nine, settings.lighter { image = textured(image, iso: iso(PhotoCatalog.file(of: path))) }
            let edge = max(2, (max(image.extent.width, image.extent.height) * 0.004).rounded(.up))
            let inner = image.extent.insetBy(dx: edge, dy: edge).integral
            var placed = image.cropped(to: inner).transformed(by: CGAffineTransform(translationX: -inner.minX, y: -inner.minY))
            let key = "\(url.path)|\(settings.key)|\(Int(placed.extent.width))"
            // Decoder 9's darkest shadows sit under 8's and Lightroom's, whose noise holds them up (measured: block means
            // 0.75 of 8's at 2⁻¹⁰, 0.94 at 2⁻⁹), so lifted they came out black and hard: put back as √(Y² + c²) (a neutral
            // lift, c 0.0011 of white, about 10 stops under it: 8's levels within 8% at every stop here, and its contrast on
            // the plastic's folds). Process 4: c² with the ISO (the noise's variance; ISO 250's at the least), all of it from ISO 1600: at ISO 100–500 the
            // full lift left the darkest 0.5% at OkLab L 0.081–0.089 against Lightroom's 0.056–0.067 and no black at all.
            if nine, let lift = lumaKernels["lift"] {
                let iso = settings.lighter ? iso(PhotoCatalog.file(of: path)) : 0
                let c2 = iso > 0 ? 1.2e-6 * min(max(iso, 250) / 1600, 1) : 1.2e-6
                placed = lift.apply(extent: placed.extent, arguments: [placed, c2]) ?? placed
            }
            if luma, settings.wideColourNoise {
                // Process 4: none at Luminance 0 up to ISO 1600 (decoder 9's own is enough there), then more with the ISO (all
                // of version 3's at 6400: see `lumaShare`); the Luminance slider adds it back as it's raised.
                let share = settings.lighter ? min(1, lumaShare(iso: iso(PhotoCatalog.file(of: path))) + noise / 25) : 1
                if share > 0 {
                    let reduced = lumaNoiseReduced(placed, amount: noise, scale: placed.extent.width / max(raw.nativeSize.width, 1), key: key)
                    placed = share < 1 ? reduced.applyingFilter("CIMix", parameters: [kCIInputBackgroundImageKey: placed, "inputAmount": share]) : reduced
                }
            }
            placed = colourNoiseReduced(placed, amount: color, fullLongEdge: max(raw.nativeSize.width, raw.nativeSize.height),
                                        wide: settings.wideColourNoise, lighter: settings.lighter)
            let long = max(placed.extent.width, placed.extent.height)
            guard maxSize > 0, long > Double(maxSize) else { return placed }
            let scale = Double(maxSize) / long
            return placed.clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": scale, "inputAspectRatio": 1])
                .cropped(to: CGRect(x: 0, y: 0, width: (placed.extent.width * scale).rounded(.down), height: (placed.extent.height * scale).rounded(.down)))
        }
        if maxSize > 0, let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxSize,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { return CIImage(cgImage: image) }
        }
        return CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }

    /// Process 4: decoder 9's fine, low-contrast texture brought back up (it keeps 31–61% of Lightroom's finest detail on
    /// ordinary texture, measured on five RAWs; noise in flat places 0.34–0.47 of Lightroom's). The brightness's detail under
    /// 1.5 px raised 2.15× where the local contrast is low (mean |detail| / brightness under 0.03, none over 0.09), so strong edges
    /// get none and keep their halos as they were; more with the ISO (decoder 9 smooths more): ×2.25 at ISO 400, ×2.3 from 500, fading out from ISO 800 to 3200.
    /// (Each pixel scaled, keeping its colour: added as grey instead, the stage light kept only 0.7 of Lightroom's texture.)
    static func textured(_ image: CIImage, iso: Double) -> CIImage {
        guard let detail = lumaKernels["detail4"], let raise = lumaKernels["texture4"] else { return image }
        // (None by ISO 3200, half at 1600: from there the luminance noise reduction comes in, and this would raise the grain.)
        let gain = (1.15 + 0.15 * min(max(log2(max(iso, 1) / 250), 0), 1)) * (1 - lumaShare(iso: 2 * iso))
        guard gain > 0 else { return image }
        func blur(_ i: CIImage, _ r: Double) -> CIImage { i.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: r]).cropped(to: image.extent) }
        let base = blur(image, 1.5)
        guard let d = detail.apply(extent: image.extent, arguments: [image, base]) else { return image }
        return raise.apply(extent: image.extent, arguments: [image, base, blur(d, 3), gain, 0.03, 0.09]) ?? image
    }

    nonisolated(unsafe) private static var shadings: [String: [Double]?] = [:]

    /// The lens's shading correction the camera wrote (Sony ARW: tag 0x7032 in the raw's sub-IFD, a count then that many
    /// values, centre to corner): each the brightening at that share of the half diagonal, in 1/8192 stop. Nil when the file
    /// has none (every other camera, or all zero). Read once per file.
    static func lensShading(_ file: String) -> [Double]? {
        kelvinLock.lock()
        if let known = shadings[file] { kelvinLock.unlock(); return known }
        kelvinLock.unlock()
        let value = readShading(file)
        kelvinLock.lock(); shadings[file] = value; kelvinLock.unlock()
        return value
    }

    static func readShading(_ file: String) -> [Double]? {
        guard URL(fileURLWithPath: file).pathExtension.lowercased() == "arw",
              let d = try? Data(contentsOf: URL(fileURLWithPath: file), options: .alwaysMapped), d.count > 16 else { return nil }
        let little = d[d.startIndex] == 0x49
        func u16(_ o: Int) -> Int? {
            guard o >= 0, o + 2 <= d.count else { return nil }
            let a = Int(d[d.startIndex + o]), b = Int(d[d.startIndex + o + 1])
            return little ? a | b << 8 : a << 8 | b
        }
        func u32(_ o: Int) -> Int? {
            guard let a = u16(o), let b = u16(o + 2) else { return nil }
            return little ? a | b << 16 : a << 16 | b
        }
        /// The IFD at `o`: tag → (type, count, value or offset).
        func entries(_ o: Int) -> [Int: (Int, Int, Int)] {
            guard let n = u16(o), n < 512 else { return [:] }
            var out: [Int: (Int, Int, Int)] = [:]
            for i in 0..<n {
                let e = o + 2 + 12 * i
                if let tag = u16(e), let type = u16(e + 2), let count = u32(e + 4), let value = u32(e + 8) { out[tag] = (type, count, value) }
            }
            return out
        }
        guard let first = u32(4), let (_, count, value) = entries(first)[0x14a] else { return nil }
        let subs = count == 1 ? [value] : (0..<min(count, 8)).compactMap { u32(value + 4 * $0) }
        for sub in subs {
            // SSHORT, the count first (at most 16).
            guard let (type, n, at) = entries(sub)[0x7032], type == 8, n >= 3, n <= 17,
                  let k = u16(at), k >= 2, k < n else { continue }
            let values = (1...k).compactMap { u16(at + 2 * $0).map { Double(Int16(truncatingIfNeeded: $0)) } }
            return values.count == k && values.contains { $0 != 0 } && values.allSatisfy({ abs($0) < 16384 }) ? values : nil
        }
        return nil
    }

    /// `knots` (lensShading) as a gain in linear light: 2^(value / 8192) by the share of the half diagonal from the centre,
    /// read linearly between the knots (evenly spaced, centre to corner).
    static func shaded(_ image: CIImage, _ knots: [Double]) -> CIImage {
        guard let kernel = shadeKernel else { return image }
        let e = image.extent, k = (knots + Array(repeating: knots.last ?? 0, count: 16)).prefix(16).map { $0 / 8192 }
        func v(_ i: Int) -> CIVector { CIVector(x: k[i], y: k[i + 1], z: k[i + 2], w: k[i + 3]) }
        return kernel.apply(extent: e, arguments: [image, v(0), v(4), v(8), v(12), CIVector(x: e.midX, y: e.midY),
                                                   hypot(e.width, e.height) / 2, Double(knots.count - 1)]) ?? image
    }

    private static let shadeKernel = CIColorKernel(source: """
        float pick(vec4 a, vec4 b, vec4 c, vec4 d, float j) {
            vec4 i = vec4(0.0, 1.0, 2.0, 3.0), h = vec4(0.5);
            return dot(a, step(abs(i - j), h)) + dot(b, step(abs(i + 4.0 - j), h)) + dot(c, step(abs(i + 8.0 - j), h)) + dot(d, step(abs(i + 12.0 - j), h));
        }
        kernel vec4 shade(__sample s, vec4 a, vec4 b, vec4 c, vec4 d, vec2 centre, float reach, float last) {
            float x = clamp(length(destCoord() - centre) / reach, 0.0, 1.0) * last, i = min(floor(x), last - 1.0);
            float stops = mix(pick(a, b, c, d, i), pick(a, b, c, d, i + 1.0), x - i);
            return vec4(s.rgb * exp2(stops), s.a);
        }
        """)

    /// Colour noise taken out (0…100), Lightroom's way: the colour of a small copy (the photo an eighth of its full
    /// size at 25, a twentieth at 100), brought back up along the photo's own edges, under each pixel's own brightness.
    /// Averaged in linear light, so the shadows keep their colour: Apple's colour noise reduction takes red and blue
    /// out of the deepest shadows (measured: red to green 0.42 → 0.17), which Shadows and Exposure then lift into a
    /// green cast, and it leaves the noise as blotches a few pixels wide.
    /// `wide` (version 3): as Lightroom's, the colour noise gone at every scale up to a few dozen pixels, without crossing
    /// edges: a guided filter (each place's colour a line in its brightness, worked out on the small copy) with the
    /// colour as a share of each pixel's own brightness (chromaKernels). Added instead, a noisy dark pixel came out far
    /// more colourful than its neighbours: coloured speckle once Shadows lifted it.
    /// `lighter` (process 4): each pixel's colour kept between its own and the area's (`finish4`): the line through a window
    /// of very bright and dark pixels, read at a dark one beside bright fur, came out a strong red (measured: 0.03, 0.022,
    /// 0.012 → 0.115, 0.006, −0.012), a coloured fringe along bright hairs.
    static func colourNoiseReduced(_ image: CIImage, amount: Double, fullLongEdge: Double, wide: Bool = false, lighter: Bool = false) -> CIImage {
        guard amount > 0 else { return image }
        if wide, let products = chromaKernels["products"], let squares = chromaKernels["squares"], let slopes = chromaKernels["slopes"],
           let offsets = chromaKernels["offsets"], let finish = chromaKernels["finish"] {
            let extent = image.extent, long = max(extent.width, extent.height)
            let scale = fullLongEdge / (4 + amount / 100 * 16) / max(long, 1)
            guard scale < 1, long * scale >= 4 else { return image }
            let small = image.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": scale, "inputAspectRatio": 1])
            let se = small.extent
            // Means over 9 small pixels each way, twice: about 70 full-size pixels at 25.
            func mean(_ i: CIImage) -> CIImage { i.clampedToExtent().applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: 9]).cropped(to: se) }
            let p = mean(small), ip = mean(products.apply(extent: se, arguments: [small]) ?? small), ii = mean(squares.apply(extent: se, arguments: [small]) ?? small)
            guard let a = slopes.apply(extent: se, arguments: [p, ip, ii, 0.05, 0.01]), let b = offsets.apply(extent: se, arguments: [p, ii, a]) else { return image }
            let up = CGAffineTransform(scaleX: extent.width / se.width, y: extent.height / se.height)
            func spread(_ i: CIImage) -> CIImage { mean(i).clampedToExtent().transformed(by: up).cropped(to: extent) }
            if lighter, let held = chromaKernels["finish4"] {
                return held.apply(extent: extent, arguments: [image, spread(a), spread(b), spread(p), min(amount / 25, 1)]) ?? image
            }
            return finish.apply(extent: extent, arguments: [image, spread(a), spread(b), min(amount / 25, 1)]) ?? image
        }
        let extent = image.extent, long = max(extent.width, extent.height)
        let scale = fullLongEdge / (4 + amount / 100 * 16) / max(long, 1)
        guard scale < 1, long > 0 else { return image }
        let small = image.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": scale, "inputAspectRatio": 1])
        // (Edges are found in sRGB steps, so the shadows' are too.)
        let up = image.applyingFilter("CILinearToSRGBToneCurve")
            .applyingFilter("CIEdgePreserveUpsampleFilter", parameters: ["inputSmallImage": small, "inputSpatialSigma": 3, "inputLumaSigma": 0.05])
            .cropped(to: extent)
        // own brightness + k·(small's colour) + (1 − k)·(own colour), colour being what's left after the brightness
        let k = min(amount / 25, 1), w = [0.2126, 0.7152, 0.0722]
        // (Each half comes out at alpha ½, premultiplied, so twice the colour; added, they're whole again.)
        func rows(_ f: (Int, Int) -> Double) -> [String: Any] {
            let v = (0..<3).map { r in CIVector(x: 2 * f(r, 0), y: 2 * f(r, 1), z: 2 * f(r, 2), w: 0) }
            return ["inputRVector": v[0], "inputGVector": v[1], "inputBVector": v[2], "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.5),
                    "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)]
        }
        let own = image.applyingFilter("CIColorMatrix", parameters: rows { r, c in w[c] + (1 - k) * ((r == c ? 1 : 0) - w[c]) })
        let colour = up.applyingFilter("CIColorMatrix", parameters: rows { r, c in k * ((r == c ? 1 : 0) - w[c]) })
        return colour.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: own]).cropped(to: extent)
    }

    /// Version 3's colour noise reduction (colourNoiseReduced): a guided filter on a small copy, Core Image colour kernels
    /// (one pixel in, one out, so Core Image tiles them as it likes; a Metal pass reading two inputs came out shifted at
    /// full size). `products`/`squares`: what the local means are taken of (colour × brightness; brightness and its
    /// square); `slopes`/`offsets`: each place's colour as a line in its brightness, steadied by `eps` (relative, with a
    /// floor `f` for the deepest shadows' noise); `finish`: that line at the pixel's own brightness, its colour as a share
    /// of its brightness put on the pixel's (so a noisy dark pixel is never more colourful than its neighbours), `k` of it.
    private static let chromaKernels: [String: CIColorKernel] = {
        let w = "vec3(0.2126, 0.7152, 0.0722)"
        let sources = [
            "products": "kernel vec4 products(__sample c) { float Y = dot(c.rgb, \(w)); return vec4(c.rgb * Y, 1.0); }",
            "squares": "kernel vec4 squares(__sample c) { float Y = dot(c.rgb, \(w)); return vec4(Y, Y * Y, 0.0, 1.0); }",
            "slopes": """
                kernel vec4 slopes(__sample p, __sample ip, __sample ii, float eps, float f) {
                    return vec4((ip.rgb - ii.r * p.rgb) / (max(ii.g - ii.r * ii.r, 0.0) + eps * eps * (ii.r * ii.r + f * f) + 1e-14), 1.0); }
                """,
            "offsets": "kernel vec4 offsets(__sample p, __sample ii, __sample a) { return vec4(p.rgb - a.rgb * ii.r, 1.0); }",
            "finish": """
                kernel vec4 finish(__sample c, __sample a, __sample b, float k) {
                    float Y = dot(c.rgb, \(w)); vec3 q = a.rgb * Y + b.rgb; float Yq = dot(q, \(w));
                    vec3 share = Yq > 1e-7 ? clamp(q / Yq, -0.5, 8.0) : vec3(1.0);
                    return vec4(mix(c.rgb, Y * share, k), c.a); }
                """,
            "finish4": """
                kernel vec4 finish4(__sample c, __sample a, __sample b, __sample m, float k) {
                    float Y = dot(c.rgb, \(w)); vec3 q = a.rgb * Y + b.rgb; float Yq = dot(q, \(w)), Ym = dot(m.rgb, \(w));
                    vec3 share = Yq > 1e-7 ? clamp(q / Yq, -0.5, 8.0) : vec3(1.0);
                    vec3 own = Y > 1e-7 ? c.rgb / Y : share, area = Ym > 1e-7 ? m.rgb / Ym : share;
                    share = clamp(share, min(own, area), max(own, area));
                    return vec4(mix(c.rgb, Y * share, k), c.a); }
                """,
        ]
        return sources.compactMapValues { CIColorKernel(source: $0) }
    }()

    /// Version 3's luminance noise reduction, as Lightroom's raw engine does some even at Luminance 0 (Apple's barely
    /// touches this noise: 18.0 → 17.1 at its strongest, measured): a guided filter on the brightness, steadied by the
    /// photo's own noise at each brightness (noiseModel): each pixel keeps the share of the variance around it (7 full-size
    /// pixels) that is above the noise, so only what is statistically noise goes and texture, lines and edges stay (a
    /// Wiener filter, per pixel). The earlier form (a guided filter at 8 and then 1.5 times the noise, over 7 and 17
    /// pixels) took half of texture 3 times the noise and smeared fine lines. `amount`: the Luminance slider (0…100),
    /// raising the threshold up to 5 times the noise; `scale`: the decode's size against the full size; `key`: the
    /// decode's, so its noise is measured once (the slider decodes again).
    static func lumaNoiseReduced(_ image: CIImage, amount: Double, scale: Double, key: String? = nil) -> CIImage {
        noiseLock.lock(); let known = key.flatMap { noiseModels[$0] }; noiseLock.unlock()
        guard let model = known ?? noiseModel(image), let luma = lumaKernels["luma"], let spread = lumaKernels["spread"],
              let coef = lumaKernels["coef"], let settle = lumaKernels["settle"] else { return image }
        if known == nil, let key { noiseLock.lock(); noiseModels[key] = model; noiseLock.unlock() }
        let extent = image.extent
        // (Core Image's box is the odd width at or under its radius.)
        func mean(_ i: CIImage) -> CIImage {
            i.clampedToExtent().applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: max(1, 7 * scale)]).cropped(to: extent)
        }
        let m = mean(luma.apply(extent: extent, arguments: [image]) ?? image)
        guard let v = spread.apply(extent: extent, arguments: [image, m, model.a, model.b]),
              let ab = coef.apply(extent: extent, arguments: [m, mean(v), 1 + amount / 25]) else { return image }
        return settle.apply(extent: extent, arguments: [image, ab]) ?? image
    }

    nonisolated(unsafe) private static var noiseModels: [String: (a: Double, b: Double)] = [:]
    private static let noiseLock = NSLock()

    /// The photo's noise as variance = a·Y + b (linear brightness), measured on nine patches across it, up to an eighth of
    /// white: each pixel against the mean of its 3×3, the lowest quarter per stop of brightness, so texture hardly counts.
    /// Nil when there's too little to tell (then nothing is smoothed).
    static func noiseModel(_ image: CIImage) -> (a: Double, b: Double)? {
        let e = image.extent.integral, t = min(256, Int(min(e.width, e.height)) / 3)
        guard t >= 16 else { return nil }
        var mosaic = CIImage.empty()
        for i in 0..<3 {
            for j in 0..<3 {
                let x = (e.minX + e.width * (CGFloat(j) + 0.5) / 3).rounded() - CGFloat(t / 2)
                let y = (e.minY + e.height * (CGFloat(i) + 0.5) / 3).rounded() - CGFloat(t / 2)
                mosaic = image.cropped(to: CGRect(x: x, y: y, width: CGFloat(t), height: CGFloat(t)))
                    .transformed(by: CGAffineTransform(translationX: CGFloat(j * t) - x, y: CGFloat(i * t) - y)).composited(over: mosaic)
            }
        }
        let side = 3 * t
        var px = [Float](repeating: 0, count: side * side * 4)
        context.render(mosaic, toBitmap: &px, rowBytes: side * 16, bounds: CGRect(x: 0, y: 0, width: side, height: side), format: .RGBAf, colorSpace: nil)
        let Y = stride(from: 0, to: px.count, by: 4).map { 0.2126 * px[$0] + 0.7152 * px[$0 + 1] + 0.0722 * px[$0 + 2] }
        var bins = [[Float]](repeating: [], count: 10), means = [Double](repeating: 0, count: 10)
        for ty in 0..<3 {
            for tx in 0..<3 {
                for y in ty * t + 1 ..< ty * t + t - 1 {
                    for x in tx * t + 1 ..< tx * t + t - 1 {
                        var m: Float = 0
                        for dy in -1...1 { for dx in -1...1 { m += Y[(y + dy) * side + x + dx] } }
                        m /= 9
                        guard m >= exp2(-13), m < exp2(-3) else { continue }
                        let k = min(Int(log2(m).rounded(.down)) + 13, 9), d = Y[y * side + x] - m
                        bins[k].append(d * d); means[k] += Double(m)
                    }
                }
            }
        }
        // Per stop: the mean brightness and the variance from the lower quartile of the squares (a quarter of χ²(1) is
        // under 0.1015σ²; and a pixel against its 3×3 mean has 8/9 of the variance).
        var points: [(m: Double, s: Double)] = []
        for k in 0..<10 where bins[k].count >= 400 {
            let sorted = bins[k].sorted()
            points.append((means[k] / Double(bins[k].count), Double(sorted[sorted.count / 4]) / 0.1015 * 9 / 8))
        }
        guard points.count >= 2 else { return nil }
        // Least squares, each stop weighed by 1/variance (the shadows' small variances count as much as the rest).
        var sww = 0.0, swm = 0.0, smm = 0.0, sws = 0.0, sms = 0.0
        for p in points where p.s > 0 {
            let w = 1 / (p.s * p.s)
            sww += w; swm += w * p.m; smm += w * p.m * p.m; sws += w * p.s; sms += w * p.m * p.s
        }
        let det = sww * smm - swm * swm
        guard det > 0 else { return nil }
        let a = (sww * sms - swm * sws) / det, b = (smm * sws - swm * sms) / det
        return (max(a, 0), max(b, 1e-12))
    }

    /// lumaNoiseReduced's steps, as Core Image colour kernels: `luma` the brightness; `spread` how far each pixel is from
    /// the mean around it, against the noise there (about 1 where it's only noise; kept small, as Core Image keeps
    /// half floats); `coef` how much of the pixel's difference from the mean to keep (the share of the variance above
    /// `t` times the noise), and the rest from the mean; `settle` that at the pixel's brightness, the change added to all three channels (the colour noise reduction after it
    /// puts the colour back as a share of the new brightness).
    private static let lumaKernels: [String: CIColorKernel] = {
        let w = "vec3(0.2126, 0.7152, 0.0722)"
        let sources = [
            "luma": "kernel vec4 luma(__sample c) { return vec4(dot(c.rgb, \(w)), 0.0, 0.0, 1.0); }",
            "spread": """
                kernel vec4 spread(__sample c, __sample m, float a, float b) {
                    float d = dot(c.rgb, \(w)) - m.r; return vec4(min(d * d / (a * max(m.r, 0.0) + b), 60000.0), 0.0, 0.0, 1.0); }
                """,
            "lift": "kernel vec4 lift(__sample c, float c2) { float Y = max(dot(c.rgb, \(w)), 0.0); return vec4(c.rgb + (sqrt(Y * Y + c2) - Y), c.a); }",
            "soften": "kernel vec4 soften(__sample c, __sample a, __sample b) { return vec4(0.65 * c.rgb + 0.3 * a.rgb + 0.05 * b.rgb, c.a); }",
            // (Process 4: half of it on the brightness; the colour as softened as version 3's, so edges carry no more false colour:
            // with half on all three the whiskers' edge colour was 11% over version 3's.)
            "soften4": """
                kernel vec4 soften4(__sample c, __sample a, __sample b) {
                    vec3 f = 0.65 * c.rgb + 0.3 * a.rgb + 0.05 * b.rgb, h = 0.825 * c.rgb + 0.15 * a.rgb + 0.025 * b.rgb;
                    return vec4(f + dot(h - f, \(w)), c.a); }
                """,
            "detail4": "kernel vec4 detail4(__sample c, __sample b) { float Y = dot(c.rgb, \(w)); return vec4(abs(Y - dot(b.rgb, \(w))), Y, 0.0, 1.0); }",
            "texture4": """
                kernel vec4 texture4(__sample c, __sample b, __sample e, float gain, float e0, float e1) {
                    float Y = dot(c.rgb, \(w)), F = Y - dot(b.rgb, \(w));
                    float g = gain * (1.0 - smoothstep(e0, e1, e.r / (max(e.g, 0.0) + 0.002)));
                    return vec4(c.rgb * clamp(max(Y + g * F, 0.0) / max(Y, 1e-6), 0.0, 4.0), c.a); }
                """,
            "difference": "kernel vec4 difference(__sample o, __sample c) { return vec4(clamp(o.rgb - c.rgb, -0.004, 0.004), 1.0); }",
            "level": """
                kernel vec4 level(__sample c, __sample d, __sample s) {
                    return vec4(c.rgb + d.rgb * (1.0 - smoothstep(0.00390625, 0.015625, dot(s.rgb, \(w)))), c.a); }
                """,
            "coef": "kernel vec4 coef(__sample m, __sample v, float t) { float A = max(v.r - t, 0.0) / max(v.r, 1e-6); return vec4(A, m.r * (1.0 - A), 0.0, 1.0); }",
            "settle": """
                kernel vec4 settle(__sample c, __sample ab) { float Y = dot(c.rgb, \(w)); return vec4(c.rgb + (ab.r * Y + ab.g - Y), c.a); }
                """,
        ]
        return sources.compactMapValues { CIColorKernel(source: $0) }
    }()

    /// Apple's RAW engine without its look: no boost or tone mapping, the highlights' headroom
    /// kept, no sharpening or extra detail and contrast (Pluck does those), lens corrections on.
    /// Every switch is set, so nothing depends on Apple's defaults; the decoder's version is the
    /// one the photo was edited with.
    /// `modern` (version 3): Apple's decoder 9 at least, where the Mac has it. Decoder 8 leaves coarse noise a few pixels
    /// across (measured on an ISO 400 RAW lifted 4.5 stops: 19 times decoder 9's variance at 1–2 px, 7 at 4–8 px) that
    /// buries fine lines at any size; 9 keeps them and its noise is near Lightroom's (it ignores the sharpness, detail and
    /// noise settings below; it takes about a second longer at full size, decoding only).
    static func neutral(_ raw: CIRAWFilter, noise: Double, color: Double = 50, moire: Double = 0, decoder: String? = nil, modern: Bool = false) {
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
        if modern, Double(raw.decoderVersion.rawValue.prefix { $0 != "." }) ?? 0 < 9,
           let nine = raw.supportedDecoderVersions.first(where: { $0.rawValue == "9" }) {
            raw.decoderVersion = nine
        }
        raw.luminanceNoiseReductionAmount = Float(noise / 100)
        raw.colorNoiseReductionAmount = Float(color / 100)
    }

    /// The RAW decoder a new edit is pinned to (the newest this Mac has).
    static func currentDecoder(_ path: String) -> String? {
        guard isRaw(path) else { return nil }
        kelvinLock.lock()
        if let known = decoders[path] { kelvinLock.unlock(); return known }
        kelvinLock.unlock()
        guard let version = CIRAWFilter(imageURL: URL(fileURLWithPath: PhotoCatalog.file(of: path)))?.decoderVersion.rawValue else { return nil }
        kelvinLock.lock(); decoders[path] = version; kelvinLock.unlock()
        return version
    }

    nonisolated(unsafe) private static var decoders: [String: String] = [:]

    /// What the RAW decoder is given besides noise.
    struct RawSettings: Hashable {
        var moire = 0.0
        var decoder: String?
        /// Version 3's colour noise reduction (wider, as a share of each pixel's brightness: see colourNoiseReduced).
        var wideColourNoise = false
        /// Process 4: decoder 9 with half of version 3's soften and no luminance noise reduction up to ISO 1600 (`source`).
        var lighter = false
        init() {}
        init(_ a: PhotoAdjustments) { moire = a.moire; decoder = a.rawDecoder; wideColourNoise = a.process >= 3; lighter = a.process >= 4 }
        var key: String { "\(Int(moire))|\(pin)" + (wideColourNoise ? "|w" : "") }
        /// The decoder, as caches name it (version 3's has decoder 9 at least: see `neutral`; process 4's decode is its own, so
        /// are its denoised files).
        var pin: String { (decoder ?? "") + (wideColourNoise ? "+9" : "") + (lighter ? "+4" : "") }
    }

    /// The adjustments, in the order a photo editor applies them: light and white balance, local
    /// tone and the profile (the photo engine), colour (a lookup table), noise, sharpening,
    /// straightening and crop, vignette. `scene`: light only, for the film engine.
    /// `cacheKey`: the decoded photo is a kept one (see `base`), so its local-tone layers can be.
    /// `overlay`: the mask shown in red (version 2), while it's edited.
    static func adjusted(_ image: CIImage, _ a: PhotoAdjustments, isRaw: Bool, kelvin: Double, scene: Bool = false, crop: Bool = true,
                         path: String? = nil, cacheKey: String? = nil, overlay: Int? = nil, peak: Double = 1, baseline: Double = 0) -> CIImage {
        let base = image
        // Version 2 develops the masks in the same pass (their shapes as one small layer).
        let modern = a.process >= 2
        let shapes = modern && !a.masks.isEmpty ? path.flatMap { PhotoMasks.layer(a.masks, path: $0, base: base, context: context) } : nil
        var image = PhotoEngine.develop(image, a, isRaw: isRaw, asShotKelvin: kelvin, scene: scene, cacheKey: cacheKey,
                                        masks: shapes, overlay: overlay, peak: peak, baseline: baseline)
        let long = max(image.extent.width, image.extent.height)
        // A creative profile's own colours, on the picture as Adobe's renderer puts them (after the tone curve).
        let wide = a.process >= 3
        if !scene, wide, let digest = a.lookTable, a.lookAmount > 0, let cube = LookTable.cube(digest, amount: min(a.lookAmount, 200) / 100, wide: true) {
            // Version 3: the cube is on ProPhoto (1.8 steps), so the picture's wide colours go in as they are.
            image = LookTable.throughWide(image, cube: cube)
        } else if !scene, let digest = a.lookTable, a.lookAmount > 0, let cube = LookTable.cube(digest, amount: min(a.lookAmount, 200) / 100) {
            let filter = CIFilter.colorCubeWithColorSpace()
            filter.inputImage = image
            filter.cubeDimension = Float(LookTable.cubeSize)
            filter.cubeData = cube
            filter.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            image = filter.outputImage ?? image
        }
        if !scene, a.needsLUT {
            let filter = CIFilter.colorCubeWithColorSpace()
            filter.inputImage = image
            filter.cubeDimension = Float(lutSize)
            filter.cubeData = lut(for: a)
            filter.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            image = filter.outputImage ?? image
        }
        if !scene, !modern, !a.masks.isEmpty, let path {
            image = PhotoMasks.apply(a.masks, to: image, base: base, path: path, context: context)
        }
        if a.noise > 0, !isRaw {
            let filter = CIFilter.noiseReduction()
            filter.inputImage = image
            filter.noiseLevel = Float(a.noise / 100 * 0.05)
            filter.sharpness = 0.4
            image = filter.outputImage ?? image
        }
        // With film, the sharpening goes on the film's picture (`filmed`): on scene light it would be
        // sharpened again by the film's grain and scan, and its halos would grow with the film's contrast.
        let full = Double(max(path.map(decodedLongEdge) ?? 0, Int(long)))
        if !scene {
            image = sharpened(image, a.sharpen, scale: Double(long) / max(full, 1), fullLongEdge: full, fine: a.process >= 3)
        }
        let origin = image.extent.origin
        image = geometry(image, a, crop: crop)
        // (With film, its own grain.)
        image = effects(image, a, grain: !scene, scale: Double(long) / max(full, 1), origin: origin)
        return image.cropped(to: image.extent)
    }

    /// The vignette (as it always was until its shape is changed) and, without film, grain. The grain is
    /// sized in full-size pixels and placed by where it falls on the photo (`origin`: the decoded photo's
    /// corner, `scale`: the render's size over the full size), so a preview and the export match.
    static func effects(_ image: CIImage, _ a: PhotoAdjustments, grain: Bool, scale: Double, origin: CGPoint) -> CIImage {
        let grain = grain && a.grain > 0
        guard a.vignette != 0 || grain else { return image }
        let extent = image.extent, long = max(extent.width, extent.height)
        func vignette(_ input: CIImage) -> CIImage {
            let filter = CIFilter.vignetteEffect()
            filter.inputImage = input
            filter.center = CGPoint(x: extent.midX, y: extent.midY)
            // Midpoint moves its edge out or in (0.6× … 1.4×), Feather softens it; at 50 and 50 as before.
            filter.radius = Float(long * 0.62 * (0.6 + a.vignetteMidpoint / 125))
            filter.intensity = Float(-a.vignette / 100)
            let feather = a.vignetteFeather
            filter.falloff = Float(feather <= 50 ? 0.05 + feather / 50 * 0.55 : 0.6 + (feather - 50) / 50 * 0.4)
            return filter.outputImage ?? input
        }
        let shaped = a.vignetteMidpoint != 50 || a.vignetteFeather != 50 || a.vignetteRoundness != 100 || a.vignetteHighlights != 0
            || a.vignetteStyle == 3
        if !shaped, !grain { return vignette(image) }
        // The vignette as a multiplier of the light (Core Image's multiplies, so on white it is the vignette itself),
        // squeezed across the short side by Roundness: 100 a circle, 0 the frame's shape.
        let white = CIImage(color: .white)
        var mask = a.vignette != 0 ? vignette(white) : white
        let squeeze = pow(min(extent.width, extent.height) / max(long, 1), 1 - min(max(a.vignetteRoundness, 0), 100) / 100)
        if squeeze < 1 {
            let wide = extent.width >= extent.height
            mask = mask.transformed(by: CGAffineTransform(translationX: extent.midX, y: extent.midY)
                .scaledBy(x: wide ? 1 : squeeze, y: wide ? squeeze : 1).translatedBy(x: -extent.midX, y: -extent.midY))
        }
        var e = PhotoEngine.Effects()
        e.highlights = Float(a.vignetteHighlights / 100)
        e.paint = a.vignetteStyle == 3 ? 1 : 0
        if grain {
            // Lightroom's Amount 100 is heavy; Size 25 is grain about 2.5 full-size pixels across.
            e.grain = Float(a.grain / 100 * 0.8)
            e.size = Float(1 + a.grainSize * 0.06)
            e.rough = Float(a.grainRoughness / 100)
            e.scale = Float(min(max(scale, 0.01), 1))
            e.ox = Float(origin.x); e.oy = Float(origin.y)
        }
        let data = withUnsafeBytes(of: e) { Data($0) }
        return (try? PhotoEngine.apply(EffectsPass.self, extent: extent, inputs: [image, mask.cropped(to: extent)], arguments: ["effects": data]))
            ?? vignette(image)
    }

    /// The adjustments for this photo (whether it's RAW, and its as-shot light).
    static func adjusted(_ image: CIImage, _ a: PhotoAdjustments, path: String, scene: Bool = false, crop: Bool = true,
                         cacheKey: String? = nil, overlay: Int? = nil, peak: Double = 1) -> CIImage {
        adjusted(image, a, isRaw: isRaw(path), kelvin: asShotKelvin(path), scene: scene, crop: crop, path: path, cacheKey: cacheKey,
                 overlay: overlay, peak: peak, baseline: baselineExposure(path))
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

    /// The developed photo as a picture to show or save. `maxSize` 0 is full size (slow with the helper's film).
    /// A preview is developed from the kept decode; full size (for saving) from the file.
    static func develop(_ path: String, record: PhotoRecord, maxSize: Int, worker: Int = 0) async throws -> CGImage? {
        // The film on the GPU (an advanced setting's tables are made first: a moment); nil: through the helper.
        let gpu = record.filmOn ? await FilmRoute.stockWaiting(record.film) : nil
        if maxSize == 0, let stock = gpu {
            let picture = try await filmPicture(path, record: record, stock: stock)
            return context.createCGImage(picture, from: picture.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        let kept = maxSize > 0 ? base(path, maxSize: maxSize, record: record) : nil
        guard let source = kept?.image ?? decoded(path, maxSize: 0, record: record) else { return nil }
        guard record.filmOn else {
            let image = output(adjusted(source, record.adjust, path: path, cacheKey: kept?.key), record.adjust, p3: false)
            return context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        // The film makes the picture from scene light: the light and local tone go in, the film's
        // own curve and colour do the rest.
        let image = adjusted(source, record.adjust, path: path, scene: true, cacheKey: kept?.key)
        if let stock = gpu {
            guard let light = BaseCache.texture(image) else { return nil }
            let picture = filmed(light, stock: stock, film: record.film, geometry: filmGeometry(path, source: source.extent, picture: image.extent, full: false),
                                 display: true, curves: record.adjust.curves, sharpen: record.adjust.sharpen)
            return context.createCGImage(picture, from: picture.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
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
        let picture = sharpened(curved(CIImage(bitmapData: developed, bytesPerRow: width * 16, size: CGSize(width: width, height: height), format: .RGBAf,
                                               colorSpace: linear), record.adjust.curves),
                                record.adjust.sharpen, scale: Double(max(width, height)) / Double(max(full, 1)), fullLongEdge: Double(full))
        return context.createCGImage(picture, from: picture.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    // MARK: - Film in the develop chain

    /// The film (instant: from the shipped tables) on a developed scene (`adjusted(…, scene: true)`), as more of
    /// the same chain. Its picture is SDR, as the helper's is: 0…1. `display`: for the screen (half floats in between).
    /// `curves`: the photo's curves, on the film's picture (as on any picture: in sRGB steps).
    static func filmed(_ scene: CIImage, stock: FilmStock, film: FilmSettings, geometry: FilmGeometry, display: Bool = false,
                       curves: PhotoCurves = PhotoCurves(), sharpen: Double = 0) -> CIImage {
        sharpened(curved(FilmLook.apply(scene, stock: stock, settings: film, geometry: geometry, display: display).applyingFilter("CIColorClamp"), curves),
                  sharpen, scale: geometry.scale, fullLongEdge: Double(geometry.fullLongEdge))
    }

    /// The Sharpen slider. Its radius is set in full-size pixels, so a preview, 100 % and the export
    /// look alike (`scale`: the render's size over the full size). `fine` (version 3): Lightroom's radius, a pixel of a
    /// 24-megapixel photo; the wider one sharpened a lifted shadow's noise into coarse grain.
    static func sharpened(_ image: CIImage, _ amount: Double, scale: Double, fullLongEdge: Double, fine: Bool = false) -> CIImage {
        guard amount > 0 else { return image }
        let filter = CIFilter.sharpenLuminance()
        filter.inputImage = image
        filter.sharpness = Float(amount / 100 * 0.9)
        filter.radius = Float((fine ? max(1, fullLongEdge / 6000) : max(1.5, fullLongEdge / 2400)) * min(max(scale, 0.05), 1))
        let sharp = (filter.outputImage ?? image).cropped(to: image.extent)
        guard fine else { return sharp }
        // Version 3: never past the light around it (3×3), so edges get steeper without a bright or dark rim (Lightroom's
        // Detail 25 holds its halos back too); a step overshot by 11% at 40 before.
        let around = image.clampedToExtent()
        return sharp.applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: around.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 1])])
            .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: around.applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 1])])
            .cropped(to: image.extent)
    }

    /// The curves on a finished picture (the film's: its scene light had none of them).
    static func curved(_ picture: CIImage, _ curves: PhotoCurves) -> CIImage {
        guard !curves.isDefault else { return picture }
        var only = PhotoAdjustments()
        only.curves = curves
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = picture
        filter.cubeDimension = Float(lutSize)
        filter.cubeData = lut(for: only)
        filter.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        return (filter.outputImage ?? picture).cropped(to: picture.extent)
    }

    /// Where a developed picture sits on its photo at full size, so the film's grain and halation keep their
    /// size and place in a preview or a crop. `source`: the decoded photo's extent (before straightening and
    /// the crop); `picture`: the developed one's; `full`: decoded at full size (an export, or looking closely).
    static func filmGeometry(_ path: String, source: CGRect, picture: CGRect, full: Bool) -> FilmGeometry {
        let long = Double(max(source.width, source.height))
        let whole = full ? long : max(Double(decodedLongEdge(path)), long)
        let s = min(long / max(whole, 1), 1)
        return FilmGeometry(fullLongEdge: Int(whole.rounded()), renderScale: s,
                            fullOrigin: CGPoint(x: (picture.minX - source.minX) / s, y: (source.maxY - picture.maxY) / s))
    }

    /// The photo's long side as it's decoded at full size (a RAW loses a sliver at its edges, see `source`).
    static func decodedLongEdge(_ path: String) -> Int {
        let long = fullLongEdge(path)
        guard long > 0, isRaw(path) else { return long }
        return long - 2 * max(2, Int((Double(long) * 0.004).rounded(.up)))
    }

    /// A photo's instant film at full size, held in memory (half floats, linear sRGB). The scene is worked out
    /// once; then the film a band of rows at a time (each band reads its spatial stages' reach around it), so the
    /// GPU memory it takes stays bounded. A few at a time (`FilmGate`).
    static func filmPicture(_ path: String, record: PhotoRecord, stock: FilmStock) async throws -> CIImage {
        await FilmGate.shared.enter()
        defer { Task { await FilmGate.shared.leave() } }
        return try filmBands(path, record: record, stock: stock)
    }

    /// Thrown when the GPU couldn't work out the film (an export then reports a problem instead of saving black).
    static var filmFailed: NSError {
        NSError(domain: "Pluck", code: 11, userInfo: [NSLocalizedDescriptionKey: String(localized: "The film engine stopped.")])
    }

    private static func filmBands(_ path: String, record: PhotoRecord, stock: FilmStock) throws -> CIImage {
        guard let decoded = PhotoRender.decoded(path, maxSize: 0, record: record) else { throw unreadable }
        let scene = adjusted(decoded, record.adjust, path: path, scene: true)
        let extent = scene.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0 else { throw unreadable }
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let rowBytes = width * 8
        /// `image` over `bounds` into memory at `at`; a failed render throws (the plain render would only log it).
        func render(_ image: CIImage, _ bounds: CGRect, into at: UnsafeMutableRawPointer) throws {
            let destination = CIRenderDestination(bitmapData: at, width: Int(bounds.width), height: Int(bounds.height), bytesPerRow: rowBytes, format: .RGBAh)
            destination.colorSpace = linear
            try context.startTask(toRender: image, from: bounds, to: destination, at: .zero).waitUntilCompleted()
        }
        // The scene once (its local tone is worked out over the whole photo), in memory for the bands to read.
        var light = Data(count: rowBytes * height)
        try light.withUnsafeMutableBytes { try render(scene, extent, into: $0.baseAddress!) }
        let kept = CIImage(bitmapData: light, bytesPerRow: rowBytes, size: extent.size, format: .RGBAh, colorSpace: linear)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        let film = filmed(kept, stock: stock, film: record.film, geometry: filmGeometry(path, source: decoded.extent, picture: extent, full: true), curves: record.adjust.curves,
                          sharpen: record.adjust.sharpen)
        guard !film.extent.isEmpty else { throw filmFailed }
        let failures = FilmHalation.failures
        var pixels = Data(count: rowBytes * height)
        let rows = max(256, min(height, filmBandPixels / width))
        try pixels.withUnsafeMutableBytes { buffer in
            for top in stride(from: 0, to: height, by: rows) {
                let count = min(rows, height - top)
                let band = CGRect(x: extent.minX, y: extent.maxY - CGFloat(top + count), width: CGFloat(width), height: CGFloat(count))
                try render(film, band, into: buffer.baseAddress! + top * rowBytes)
            }
        }
        // (Core Image may only log a pass that failed: the film's passes count theirs.)
        guard FilmHalation.failures == failures else { throw filmFailed }
        return CIImage(bitmapData: pixels, bytesPerRow: rowBytes, size: CGSize(width: width, height: height), format: .RGBAh, colorSpace: linear)
    }

    /// Posted (on the main thread) when the Mac is short of memory: let go of big pictures.
    static let memoryPressure = Notification.Name("PluckPhotoMemoryPressure")

    /// How many pixels of film a band of an export works out at once (its stages' reach comes on top): fewer on a Mac
    /// with less memory.
    static let filmBandPixels = ProcessInfo.processInfo.physicalMemory < 16 << 30 ? 2_000_000
        : ProcessInfo.processInfo.physicalMemory < 24 << 30 ? 4_000_000 : 8_000_000
    /// The same for the film at 100 % on screen: smaller, so looking closely holds less (the stages' reach weighs more).
    /// Measured on a 24 MP photo: 8 Mpx bands add 3.5 GB at the peak (0.42 s), 4 Mpx 1.7 GB (0.49 s), 2 Mpx 1.0 GB (0.82 s).
    static let lookBandPixels = ProcessInfo.processInfo.physicalMemory >= 24 << 30 ? 4_000_000 : 2_000_000

    nonisolated(unsafe) private static var longEdges: [String: Int] = [:]

    /// The photo's own long side in pixels (without decoding it).
    static func fullLongEdge(_ path: String) -> Int {
        kelvinLock.lock()
        if let known = longEdges[path] { kelvinLock.unlock(); return known }
        kelvinLock.unlock()
        var long = 0
        if isRaw(path), let raw = CIRAWFilter(imageURL: URL(fileURLWithPath: PhotoCatalog.file(of: path))) {
            long = Int(max(raw.nativeSize.width, raw.nativeSize.height))
        } else if let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: PhotoCatalog.file(of: path)) as CFURL, nil),
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
    /// Denoised, the decode without noise reduction and the clean one are both kept (by the model, not the
    /// Amount): the Amount mixes them as the picture is drawn, so its slider is as quick as any other.
    static func base(_ path: String, maxSize: Int, record: PhotoRecord) -> (image: CIImage, key: String)? {
        let settings = RawSettings(record.adjust)
        if let file = cleanFile(path, record: record) {
            let key = "\(maxSize)|denoise \(record.denoiseAI ? "ai" : "standard")|\(file.lastPathComponent)|\(settings.key)|\(path)"
            // (A clean file that can't be read shows the photo without it, as saving does, rather than nothing.)
            if let orig = BaseCache.shared.image(key + "|orig")
                    ?? denoiseSide(path, file, noisy: true, maxSize: maxSize, raw: settings).flatMap({ BaseCache.shared.keep($0, key: key + "|orig") }),
               let clean = BaseCache.shared.image(key + "|clean")
                    ?? denoiseSide(path, file, noisy: false, maxSize: maxSize, raw: settings).flatMap({ BaseCache.shared.keep(settled($0, within: orig), key: key + "|clean") }) {
                // (The key names the mix: the local tone's layers and the film's scene are worked out from it.)
                return (mixDenoise(orig, clean, amount: record.denoise), key + "|\(record.denoise)")
            }
        }
        let raw = isRaw(path)
        let noise = raw ? record.adjust.noise : 0, color = raw ? record.adjust.colorNoise : 0
        let key = "\(maxSize)|0|\(Int(noise))|\(Int(color))|\(settings.key)|\(path)"
        if let known = BaseCache.shared.image(key) { return (known, key) }
        guard let source = source(path, maxSize: maxSize, noise: noise, color: color, raw: settings, luma: true),
              let kept = BaseCache.shared.keep(source, key: key) else { return nil }
        return (kept, key)
    }

    /// The developed photo, still to be drawn: for the screen. With film on, the film too when it's
    /// instant (FilmRoute), in the same chain; else only the adjustments (the helper's film follows).
    /// `maxSize` 0: full size, for looking closely (only the part on screen is worked out).
    /// `drag`: smaller (`dragScale`), and so quicker, while a slider is dragged on a photo with film; the film's
    /// grain and halation keep their size on the photo, so it's the same picture, a little softer.
    /// `cancelled`: asked between the bands of a full-size film; true gives up (nil).
    static func image(_ path: String, record: PhotoRecord, maxSize: Int, overlay: Int? = nil, peak: Double = 1, drag: Bool = false,
                      cancelled: @escaping () -> Bool = { false }) -> CIImage? {
        guard var kept = base(path, maxSize: maxSize, record: record) else { return nil }
        if drag, maxSize > 0, let small = smaller(kept) { kept = small }
        if record.filmOn, let stock = FilmRoute.stock(record.film) {
            func scene() -> CIImage { adjusted(kept.image, record.adjust, path: path, scene: true, cacheKey: kept.key, overlay: overlay) }
            // The scene is kept while only the film changes (a film slider moves): a preview's few, the full size's last one.
            let depth = !record.adjust.masks.isEmpty && SceneCache.depthReady
            let key = SceneCache.Key(base: kept.key, adjust: record.adjust, overlay: overlay, depth: depth)
            // The film always reads a scene worked out beforehand: fed the scene's own passes straight, a film split into
            // tiles can get another tile's scene (Core Image, macOS 27; the self-test "film on screen" shows it). If that
            // can't be made (no memory for it), this once the scene's passes are read straight.
            guard maxSize == 0 else {
                let light = SceneCache.shared.scene(key, make: scene) ?? scene()
                return filmed(light, stock: stock, film: record.film,
                              geometry: filmGeometry(path, source: kept.image.extent, picture: light.extent, full: false), display: true, curves: record.adjust.curves, sharpen: record.adjust.sharpen)
            }
            // At full size (looking closely) the scene and then the film are worked out once, a band at a time, so moving
            // around is only drawing; a newer request stops this one between bands.
            guard let light = SceneCache.shared.full(key, cancelled: cancelled, make: { BaseCache.texture(scene(), bands: filmBandPixels, cancelled: cancelled) })
                    ?? (cancelled() ? nil : scene())
            else { return nil }
            let film = filmed(light, stock: stock, film: record.film,
                              geometry: filmGeometry(path, source: kept.image.extent, picture: light.extent, full: true), display: true, curves: record.adjust.curves, sharpen: record.adjust.sharpen)
            if cancelled() { return nil }
            // (Nothing when it fails: the loupe keeps what it shows.)
            return BaseCache.texture(film, bands: lookBandPixels, cancelled: cancelled)
        }
        // Film wanted on the GPU whose stock isn't there now: nothing, never the photo without its film as if it were it.
        if record.filmOn, FilmRoute.of(record.film) == .instant { return nil }
        return output(adjusted(kept.image, record.adjust, path: path, cacheKey: kept.key, overlay: overlay, peak: peak), record.adjust,
                      p3: screenIsP3, peak: peak)
    }

    /// How much smaller the picture is while a slider is dragged on film (each side; about a third of the pixels).
    static let dragScale = 0.6

    /// The kept decode at `dragScale`, made from it on the GPU once and kept too.
    private static func smaller(_ kept: (image: CIImage, key: String)) -> (image: CIImage, key: String)? {
        let key = "drag|" + kept.key
        if let known = BaseCache.shared.image(key) { return (known, key) }
        // Whole pixels each way, so no part-pixel row or column at an edge.
        let e = kept.image.extent.integral
        let width = max((e.width * dragScale).rounded(), 1), height = max((e.height * dragScale).rounded(), 1)
        let scaled = kept.image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": height / e.height, "inputAspectRatio": (width / e.width) / (height / e.height)])
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        return BaseCache.shared.keep(scaled, key: key).map { ($0, key) }
    }

    /// The adjustments (and an instant film), straight away, as a picture.
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
        // (Version 3's light has the camera's baseline exposure in it.)
        let k = Float(record.adjust.process >= 3 ? exp2(baselineExposure(path)) : 1)
        let luminance = (0..<(width * height)).map { i in k * (0.2126 * pixels[i * 4] + 0.7152 * pixels[i * 4 + 1] + 0.0722 * pixels[i * 4 + 2]) }
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

    /// The developed photo's colour around a point (shares of the photo, from the top left), as
    /// the screen shows it (linear sRGB), without its masks: for picking a range or a colour.
    static func sample(_ path: String, record: PhotoRecord, at point: CGPoint) -> SIMD3<Double>? {
        var plain = record
        plain.filmOn = false
        plain.adjust.masks = []
        plain.adjust.cropRect = nil
        plain.adjust.crop = .original
        plain.adjust.straighten = 0
        guard let image = image(path, record: plain, maxSize: 640) else { return nil }
        let e = image.extent
        let x = e.minX + point.x * e.width, y = e.maxY - point.y * e.height
        let spot = CGRect(x: x - 2, y: y - 2, width: 5, height: 5).intersection(e)
        guard !spot.isEmpty else { return nil }
        let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: spot)])
        var pixel = [Float](repeating: 0, count: 4)
        context.render(average, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf,
                       colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        return SIMD3(Double(pixel[0]), Double(pixel[1]), Double(pixel[2]))
    }

    /// The colour's brightness as the masks' brightness range measures it (0 black … 1 white),
    /// and its hue in OkLCh (degrees) with how colourful it is.
    static func describe(_ colour: SIMD3<Double>) -> (brightness: Double, hue: Double, chroma: Double) {
        let c = simd_clamp(colour, SIMD3(repeating: 0), SIMD3(repeating: 1))
        let luma = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
        let (_, a, b) = OkLab.from(c.x, c.y, c.z)
        var hue = atan2(b, a) * 180 / .pi
        if hue < 0 { hue += 360 }
        return (pow(max(luma, 0), 1 / 2.2), hue, (a * a + b * b).squareRoot())
    }

    /// The developed picture brought inside the colours it's shown or saved in (version 3, which keeps ProPhoto's colours
    /// until here; earlier versions are inside sRGB already): Display P3 (`p3`) or sRGB, up to `peak`.
    static func output(_ image: CIImage, _ a: PhotoAdjustments, p3: Bool, peak: Double = 1) -> CIImage {
        a.process >= 3 ? PhotoEngine.gamutMapped(image, p3: p3, peak: peak) : image
    }

    /// Whether the main screen shows Display P3's colours (its own green well past sRGB's), for the screen's gamut mapping.
    static let screenIsP3: Bool = {
        guard let space = CGDisplayCopyColorSpace(CGMainDisplayID()) as CGColorSpace?,
              let green = CGColor(colorSpace: space, components: [0, 1, 0, 1])?
                .converted(to: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, intent: .relativeColorimetric, options: nil),
              let parts = green.components, parts.count >= 3 else { return true }
        return parts[0] < -0.12
    }()

    /// A developed image as a picture (sRGB, or `space`), at most this long (0: as it is).
    static func picture(_ image: CIImage, maxSize: Int = 0, space: CGColorSpace? = nil) -> CGImage? {
        var image = image
        let long = max(image.extent.width, image.extent.height)
        if maxSize > 0, long > Double(maxSize) {
            let scale = Double(maxSize) / long
            image = image.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": scale, "inputAspectRatio": 1])
        }
        return context.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: space ?? CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// The colours the screen's pictures are in (image()): a picture of one in sRGB would clip what it maps into P3.
    static var screenSpace: CGColorSpace? { screenIsP3 ? CGColorSpace(name: CGColorSpace.displayP3) : nil }

    // MARK: - Denoising

    /// The denoiser's version: a clean file made by an earlier one is made again (once).
    // 3: version 2's clean files could hold highlights tens of times too bright and black blotches around them.
    // 4: a plain gain and sRGB steps (highlights in darker passes), no mean-restoring blur: crisper, no halos.
    //    (Also when source() trimmed its lens-correction edge: a clean file from before was stretched over the
    //    trimmed photo and showed as a ghost. Bump it again whenever the full-size decode's frame changes.)
    // 5: AI on a Bayer RAW cleans its mosaic (`rawDenoised`); the decode's clean files (pluck_denoise.py 4) are
    //    unchanged, so they keep their name (`decodeDenoiseVersion`).
    static let denoiseVersion = 5
    static let decodeDenoiseVersion = 4
    /// pluck_denoise_raw.py's VERSION: its DNG pairs are made again when it changes.
    static let rawDenoiseVersion = 1

    /// Where the photo's clean decode is kept: one per file (and when it was changed), model, decoder and moiré
    /// setting. Not the Amount: that's mixed in live (`mixDenoise`), so a photo is worked out once.
    static func denoised(_ key: String, ai: Bool, raw settings: RawSettings) -> URL? {
        // A copy shares its file's (denoising is of the file, not of an edit).
        let path = PhotoCatalog.file(of: key)
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
        let key = "\(path)|\(modified.timeIntervalSince1970)|\(ai ? "ai" : "standard")|\(settings.pin)|\(Int(settings.moire))|v\(decodeDenoiseVersion)"
        return denoiseFolder.appendingPathComponent("\(hashed(key)).exr")
    }

    static func denoised(_ path: String, record: PhotoRecord) -> URL? {
        if let raw = rawRoute(path, record: record) { return raw.colour }
        return denoised(path, ai: record.denoiseAI, raw: RawSettings(record.adjust))
    }

    private static var denoiseFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck/Denoised")
    }

    private static func hashed(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// The raw denoiser's files for a photo: its mosaic cleaned and untouched (DNGs, about 48 MB each), the colour
    /// matrix that takes their decode to the RAW's own (written last: the pair is complete), and the mark that
    /// the file isn't a Bayer RAW (so the decode's denoiser is used, without asking again).
    struct RawDenoised { let clean: URL, noisy: URL, colour: URL, unsupported: URL }

    /// Kept by file (and when it was changed), version, decoder and the full-size decode's frame (both DNGs are
    /// cut as the RAW is, so a change of frame makes them again). The moiré setting is the decode's, live.
    static func rawDenoised(_ key: String, raw settings: RawSettings) -> RawDenoised? {
        let path = PhotoCatalog.file(of: key)
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
              let frame = fullFrame(key) else { return nil }
        let name = hashed("\(path)|\(modified.timeIntervalSince1970)|ai raw|\(settings.pin)|\(Int(frame.width))x\(Int(frame.height))|r\(rawDenoiseVersion)")
        let base = denoiseFolder.appendingPathComponent(name).path
        return RawDenoised(clean: URL(fileURLWithPath: base + ".clean.dng"), noisy: URL(fileURLWithPath: base + ".noisy.dng"),
                           colour: URL(fileURLWithPath: base + ".colour.json"), unsupported: URL(fileURLWithPath: base + ".unsupported"))
    }

    nonisolated(unsafe) private static var frames: [String: CGSize] = [:]

    /// The full-size decode's size (lens-correction edge trimmed).
    private static func fullFrame(_ path: String) -> CGSize? {
        kelvinLock.lock()
        if let known = frames[path] { kelvinLock.unlock(); return known }
        kelvinLock.unlock()
        guard let size = source(path, maxSize: 0, color: 0)?.extent.size else { return nil }
        kelvinLock.lock(); frames[path] = size; kelvinLock.unlock()
        return size
    }

    /// Stands in for the raw denoiser (tests): RAW, clean DNG, noisy DNG; false: unsupported.
    nonisolated(unsafe) static var rawDenoiseEngineForTests: ((URL, URL, URL) async throws -> Bool)?

    /// The raw denoiser's files when the photo goes through it: AI on a RAW, the denoiser's RAW part installed, and
    /// the file not found unsupported (X-Trans, …). Everything else (and Standard) is denoised from its decode.
    static func rawRoute(_ path: String, record: PhotoRecord) -> RawDenoised? {
        // (A test standing in for the decode's denoiser alone keeps that route.)
        let installed = rawDenoiseEngineForTests != nil || (denoiseEngineForTests == nil && FilmEngine.rawDenoiseInstalled)
        guard record.denoiseAI, installed, isRaw(path), let files = rawDenoised(path, raw: RawSettings(record.adjust)),
              !FileManager.default.fileExists(atPath: files.unsupported.path) else { return nil }
        return files
    }

    /// Whether the clean decode for the record's model and settings is made (Denoise on or not).
    static func hasClean(_ path: String, record: PhotoRecord) -> Bool {
        denoised(path, record: record).map(isMade) == true
    }

    /// A clean file is there (the raw denoiser's: its matrix and both DNGs, which the cache's trim may part).
    private static func isMade(_ url: URL) -> Bool {
        let base = url.deletingPathExtension().deletingPathExtension().path
        return ([url.path] + (url.pathExtension == "json" ? [base + ".clean.dng", base + ".noisy.dng"] : []))
            .allSatisfy(FileManager.default.fileExists(atPath:))
    }

    /// The clean decode to develop from: Denoise is on and it's made (the raw denoiser's colour matrix stands for its pair).
    static func cleanFile(_ path: String, record: PhotoRecord) -> URL? {
        guard record.denoise > 0, let url = denoised(path, record: record), isMade(url) else { return nil }
        return url
    }

    /// One side of a denoised photo at a size: the photo without noise reduction (`noisy`) or its clean decode.
    /// The raw denoiser's are its two DNGs decoded alike (so they line up pixel for pixel), in the RAW's colours.
    static func denoiseSide(_ path: String, _ file: URL, noisy: Bool, maxSize: Int, raw settings: RawSettings) -> CIImage? {
        // The noisy side is the photo's own decode, so Amount 0 is the photo. Version 3 does so for the raw denoiser's pair
        // too (its DNGs keep the pinned decoder, 2% unlike decoder 9's RAW, measured), the clean one's colour fitted to the
        // RAW's (colourFit); before, the noisy DNG.
        let pair = file.pathExtension == "json"
        if noisy, !pair || settings.wideColourNoise { return source(path, maxSize: maxSize, noise: 0, color: 0, raw: settings) }
        guard pair else { return CIImage(contentsOf: file) }
        let base = file.deletingPathExtension().deletingPathExtension().path
        guard let data = try? Data(contentsOf: file), let m = try? JSONDecoder().decode([Double].self, from: data), m.count == 9,
              let image = source(path, maxSize: maxSize, noise: 0, color: 0, raw: settings,
                                 file: URL(fileURLWithPath: base + (noisy ? ".noisy.dng" : ".clean.dng"))) else { return nil }
        return coloured(image, m)
    }

    /// A 3×3 matrix (row by row: what each output channel takes of the input's) on linear light.
    static func coloured(_ image: CIImage, _ m: [Double]) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: m[0], y: m[1], z: m[2], w: 0), "inputGVector": CIVector(x: m[3], y: m[4], z: m[5], w: 0),
            "inputBVector": CIVector(x: m[6], y: m[7], z: m[8], w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)]).cropped(to: image.extent)
    }

    /// The matrix that takes one decode's colours to another's (same size), least squares in linear light: dark and
    /// bright count alike, what's near clipping in either doesn't count. Nil when they don't line up in size.
    static func colourFit(_ from: CIImage, to: CIImage) -> [Double]? {
        guard from.extent.size == to.extent.size else { return nil }
        let a = linearPixels(from), b = linearPixels(to)
        let n = a.count / 4
        var topA: Float = 0, topB: Float = 0
        for i in 0..<n { topA = max(topA, a[i * 4], a[i * 4 + 1], a[i * 4 + 2]); topB = max(topB, b[i * 4], b[i * 4 + 1], b[i * 4 + 2]) }
        var ata = simd_double3x3(), atb = simd_double3x3()
        for i in 0..<n {
            let p = SIMD3<Double>(Double(a[i * 4]), Double(a[i * 4 + 1]), Double(a[i * 4 + 2]))
            let q = SIMD3<Double>(Double(b[i * 4]), Double(b[i * 4 + 1]), Double(b[i * 4 + 2]))
            let luma = 0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z
            guard luma > 1e-4, p.max() < 0.8 * Double(topA), q.max() < 0.8 * Double(topB), p.min() > -0.01, q.min() > -0.01 else { continue }
            let w = 1 / max(luma, 2e-3)
            ata += w * simd_double3x3(rows: [p * p.x, p * p.y, p * p.z])
            atb += w * simd_double3x3(rows: [q * p.x, q * p.y, q * p.z])
        }
        guard abs(ata.determinant) > 1e-12 else { return nil }
        // Rows of atb are (q · p_i): solving gives X with columns per output; its transpose is row by row.
        let x = (ata.inverse * atb).transpose
        let m = (0..<3).flatMap { r in (0..<3).map { c in x[c][r] } }
        return m.allSatisfy(\.isFinite) ? m : nil
    }

    static func linearPixels(_ image: CIImage) -> [Float] {
        let e = image.extent.integral
        var pixels = [Float](repeating: 0, count: Int(e.width) * Int(e.height) * 4)
        pixels.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: Int(e.width) * 16, bounds: e, format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        }
        return pixels
    }

    /// How much of the clean decode an Amount (0…100) mixes in, as Lightroom's: quick at first, so 50 leaves a
    /// quarter of the noise (a natural grain) and 100 none.
    static func denoiseWeight(_ amount: Int) -> Double {
        let a = min(max(Double(amount) / 100, 0), 1)
        return 1 - (1 - a) * (1 - a)
    }

    /// The photo and its clean decode mixed at the Amount: one step on the GPU.
    static func mixDenoise(_ orig: CIImage, _ clean: CIImage, amount: Int) -> CIImage {
        let filter = CIFilter.dissolveTransition()
        filter.inputImage = orig
        filter.targetImage = clean
        filter.time = Float(denoiseWeight(amount))
        return (filter.outputImage ?? orig).cropped(to: orig.extent)
    }

    /// The clean decode at the photo's size, kept within what the photo has around each pixel (3 px): a bad
    /// clean file (an engine's mistake) can then never show black, or brighter, blotches.
    /// Also its deepest shadows' level put back to the photo's (`unbiased`): the raw denoiser's clean DNG came out up to
    /// 0.0009 darker there in red, 0.0003 in blue (measured on an ISO 400 RAW, the noisy DNG matching the RAW within
    /// 0.0001), a colour that Shadows and Exposure lift into a teal cast.
    static func settled(_ clean: CIImage, within orig: CIImage) -> CIImage {
        let fit = unbiased(fitted(clean, to: orig.extent), orig)
        let low = orig.applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 3]).cropped(to: orig.extent)
        let high = orig.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 3]).cropped(to: orig.extent)
        return fit.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: low])
            .applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: high]).cropped(to: orig.extent)
    }

    /// The clean decode with the photo's own level in its deepest shadows (under 2⁻⁸ of white, easing out by 2⁻⁶): the
    /// difference from the photo, at most 0.004 each way (so nothing bright reaches a dark place), averaged over 0.4% of
    /// the long edge (24 px of a 24 MP photo: the noise averages out, a level stays).
    private static func unbiased(_ clean: CIImage, _ orig: CIImage) -> CIImage {
        guard let difference = lumaKernels["difference"], let level = lumaKernels["level"] else { return clean }
        let e = orig.extent, r = max(1, 0.004 * max(e.width, e.height))
        func blur(_ i: CIImage) -> CIImage { i.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: r]).cropped(to: e) }
        guard let d = difference.apply(extent: e, arguments: [orig, clean]) else { return clean }
        return level.apply(extent: e, arguments: [clean, blur(d), blur(clean)]) ?? clean
    }

    /// The clean decode (full size) at a smaller decode's size, pixel for pixel.
    private static func fitted(_ clean: CIImage, to extent: CGRect) -> CIImage {
        let e = clean.extent
        guard e.size != extent.size, e.width > 0, e.height > 0 else { return clean }
        let scale = extent.height / e.height
        return clean.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": scale, "inputAspectRatio": (extent.width / e.width) / scale])
            .cropped(to: CGRect(origin: .zero, size: extent.size))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    /// The decode a photo is developed from (full size for saving): denoised, its decode without noise
    /// reduction and the clean one mixed at the Amount, as on screen; else with the Luminance and Colour sliders'.
    static func decoded(_ path: String, maxSize: Int, record: PhotoRecord) -> CIImage? {
        let settings = RawSettings(record.adjust)
        if let file = cleanFile(path, record: record), let clean = denoiseSide(path, file, noisy: false, maxSize: maxSize, raw: settings),
           let orig = denoiseSide(path, file, noisy: true, maxSize: maxSize, raw: settings) {
            return mixDenoise(orig, settled(clean, within: orig), amount: record.denoise)
        }
        let raw = isRaw(path)
        return source(path, maxSize: maxSize, noise: raw ? record.adjust.noise : 0, color: raw ? record.adjust.colorNoise : 0, raw: settings, luma: true)
    }

    /// Stands in for the Python engine (tests): input, output, AI.
    nonisolated(unsafe) static var denoiseEngineForTests: ((URL, URL, Bool) async throws -> Void)?

    /// Takes all the noise out of the photo at full size, once, for the record's model and decoder settings
    /// (Apple's noise reduction off, so the denoiser sees the noise as it is). Kept, and mixed in from then on.
    static func denoise(_ path: String, record: PhotoRecord, worker: Int = 1) async throws {
        if let files = rawRoute(path, record: record) {
            if isMade(files.colour) { return }
            if try await denoiseRaw(path, files, raw: RawSettings(record.adjust), worker: worker) { return }
        }
        guard let output = denoised(path, record: record) else { throw NSError(domain: "Pluck", code: 1) }
        if FileManager.default.fileExists(atPath: output.path) { return }
        guard let image = source(path, maxSize: 0, noise: 0, color: 0, raw: RawSettings(record.adjust)) else {
            throw NSError(domain: "Pluck", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "The photo couldn’t be read.")])
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-film/\(UUID().uuidString)-noisy.tif")
        try FileManager.default.createDirectory(at: input.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: input) }
        try context.writeTIFFRepresentation(of: image, to: input, format: .RGBAh, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        let partial = output.deletingPathExtension().appendingPathExtension("part.exr")
        if let stand = denoiseEngineForTests {
            try await stand(input, partial, record.denoiseAI)
        } else {
            try await FilmEngine.shared.denoise(input, to: partial, ai: record.denoiseAI, worker: worker)
        }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: partial, to: output)
    }

    /// The raw denoiser: Apple's lens correction measured (the RAW's half-size decodes without and with it), the
    /// mosaic cleaned into a DNG pair, then the matrix from their decode to the RAW's (half size). False: not a Bayer
    /// RAW, marked so, for the decode's denoiser.
    private static func denoiseRaw(_ path: String, _ files: RawDenoised, raw settings: RawSettings, worker: Int) async throws -> Bool {
        let url = URL(fileURLWithPath: PhotoCatalog.file(of: path))
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-film/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: files.clean.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let lens = [temp.appendingPathComponent("lens-off.tif"), temp.appendingPathComponent("lens-on.tif")]
        for (on, out) in zip([false, true], lens) {
            guard let raw = CIRAWFilter(imageURL: url) else { break }
            neutral(raw, noise: 0, color: 0, decoder: settings.decoder, modern: settings.wideColourNoise)
            raw.isLensCorrectionEnabled = on
            raw.scaleFactor = 0.5
            guard let image = raw.outputImage else { break }
            try context.writeTIFFRepresentation(of: image, to: out, format: .RGBA16, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        let clean = temp.appendingPathComponent("clean.dng"), noisy = temp.appendingPathComponent("noisy.dng")
        let made: Bool
        if let stand = rawDenoiseEngineForTests {
            made = try await stand(url, clean, noisy)
        } else {
            made = try await FilmEngine.shared.denoiseRaw(url, clean: clean, noisy: noisy,
                                                          lens: lens.filter { FileManager.default.fileExists(atPath: $0.path) }, worker: worker)
        }
        guard made else {
            FileManager.default.createFile(atPath: files.unsupported.path, contents: Data())
            return false
        }
        let half = Int((fullFrame(path).map { max($0.width, $0.height) } ?? 0) / 2)
        // (Both DNGs must decode, alike, or the photo would show without its denoise every time.)
        guard let decoded = source(path, maxSize: half, noise: 0, color: 0, raw: settings, file: noisy),
              source(path, maxSize: half, noise: 0, color: 0, raw: settings, file: clean)?.extent == decoded.extent,
              let own = source(path, maxSize: half, noise: 0, color: 0, raw: settings),
              let m = colourFit(decoded, to: own) else {
            throw NSError(domain: "Pluck", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "The photo couldn’t be read.")])
        }
        for (from, to) in [(clean, files.clean), (noisy, files.noisy)] {
            try? FileManager.default.removeItem(at: to)
            try FileManager.default.moveItem(at: from, to: to)
        }
        try JSONEncoder().encode(m).write(to: files.colour, options: .atomic)
        return true
    }

    // MARK: - Previews kept on disk

    /// A developed preview, kept by the photo and its settings so the grid can show edits.
    static func cachedPreview(_ path: String, record: PhotoRecord) -> URL {
        var key = path
        if let data = try? JSONEncoder().encode(record.adjust) { key += String(decoding: data, as: UTF8.self) }
        if record.filmOn, let data = try? JSONEncoder().encode(record.film) { key += String(decoding: data, as: UTF8.self) }
        // Denoised: by the Amount and model, once the clean decode is made (until then it shows without).
        if record.denoise > 0, cleanFile(path, record: record) != nil { key += "|denoise v\(denoiseVersion) \(record.denoiseAI ? "ai" : "") \(record.denoise)" }
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
        if max(image.width, image.height) > 1200, let small = picture(CIImage(cgImage: image), maxSize: 1200, space: image.colorSpace) { image = small }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    // MARK: - Export

    enum Format: String, CaseIterable, Identifiable, Codable {
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

    /// Writes the developed photo with these settings (`number`: its place in the export, for
    /// numbered names). HDR (JPEG and HEIC, macOS 15): the picture as on any screen, with a gain map
    /// that lets an HDR screen show its highlights up to two stops brighter.
    static func export(_ path: String, record: PhotoRecord, to folder: URL, settings: PhotoExportSettings, number: Int = 0,
                       worker: Int = 1) async throws -> URL {
        var picture: CIImage
        var hdr: CIImage?
        if record.filmOn, let stock = await FilmRoute.stockWaiting(record.film) {
            // The film makes its own (SDR) picture, on the GPU (an advanced setting's tables made first, if they must be).
            picture = try await filmPicture(path, record: record, stock: stock)
        } else if record.filmOn {
            // Settings the shipped tables can't do need the film data (the helper, or tables made for this photo).
            if await MainActor.run(body: { FilmEngine.shared.state != .ready }) {
                throw NSError(domain: "Pluck", code: 11, userInfo: [NSLocalizedDescriptionKey: String(localized: "This photo’s film settings need the film data. Download it in the Film panel.")])
            }
            // The film makes its own (SDR) picture, through the helper.
            guard let made = try await develop(path, record: record, maxSize: 0, worker: worker) else { throw unreadable }
            picture = CIImage(cgImage: made)
        } else {
            guard let decoded = PhotoRender.decoded(path, maxSize: 0, record: record) else { throw unreadable }
            picture = output(adjusted(decoded, record.adjust, path: path), record.adjust, p3: settings.space == .p3)
            if settings.savesHDR(record) {
                hdr = output(adjusted(decoded, record.adjust, path: path, peak: PhotoExportSettings.hdrPeak), record.adjust, p3: settings.space == .p3,
                             peak: PhotoExportSettings.hdrPeak)
            }
        }
        func finish(_ image: CIImage) -> CIImage {
            var image = image
            let long = max(image.extent.width, image.extent.height)
            if settings.longSide > 0, long > Double(settings.longSide) {
                image = image.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": Double(settings.longSide) / long, "inputAspectRatio": 1])
            }
            if let (amount, radius) = settings.sharpen.strength {
                image = image.applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": amount, "inputRadius": radius])
            }
            // The mark goes on last, so it isn't sharpened.
            if let mark = settings.watermark { image = PhotoWatermark.apply(image, mark) }
            let e = image.extent.integral
            return image.cropped(to: e).transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        }
        picture = finish(picture)
        hdr = hdr.map(finish)
        var properties = metadata(of: path, keeping: settings.metadata)
        // Who made it goes along, unless no metadata does.
        if settings.metadata != .none, let meta = record.meta { properties = meta.iptc(over: properties) }
        let name = settings.fileName(for: path, number: number)
        let target = settings.outputFolder(in: folder)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let output = Converting.outputURL(folder: target.path, name: name, fileExtension: settings.format.fileExtension)
        let space = CGColorSpace(name: settings.space == .p3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!
        if let hdr, #available(macOS 15, *) {
            var options: [CIImageRepresentationOption: Any] = [.hdrImage: hdr]
            options[CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)] = settings.quality
            let tagged = picture.settingProperties(properties)
            if settings.format == .heic {
                try context.writeHEIFRepresentation(of: tagged, to: output, format: .RGBA8, colorSpace: space, options: options)
            } else {
                try context.writeJPEGRepresentation(of: tagged, to: output, colorSpace: space, options: options)
            }
            return output
        }
        let deep = settings.format == .tiff
        guard let image = context.createCGImage(picture, from: picture.extent, format: deep ? .RGBA16 : .RGBA8, colorSpace: space),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, settings.format.type.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Pluck", code: 2)
        }
        var options = properties
        options[kCGImageDestinationLossyCompressionQuality as String] = settings.quality
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "Pluck", code: 3) }
        return output
    }

    private static var unreadable: NSError {
        NSError(domain: "Pluck", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "The photo couldn’t be read.")])
    }

    /// The camera's metadata for the exported file (upright: the turn is in the pixels now).
    private static func metadata(of path: String, keeping: PhotoExportSettings.Metadata) -> [String: Any] {
        guard keeping != .none, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: PhotoCatalog.file(of: path)) as CFURL, nil),
              var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return [:] }
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth, kCGImagePropertyColorModel,
                    kCGImagePropertyProfileName, kCGImagePropertyOrientation] {
            properties[key as String] = nil
        }
        properties[kCGImagePropertyOrientation as String] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if keeping == .noLocation { properties[kCGImagePropertyGPSDictionary as String] = nil }
        return properties
    }
}

/// How photos are exported: format, size, colour, sharpening for where they're going, HDR,
/// what metadata goes along, and their names. Saved as presets.
struct PhotoExportSettings: Codable, Hashable {
    enum Space: String, Codable, CaseIterable { case srgb, p3 }
    enum Sharpen: String, Codable, CaseIterable {
        case none, screen, print
        /// CISharpenLuminance's amount and radius.
        var strength: (Double, Double)? {
            switch self {
            case .none: nil
            case .screen: (0.4, 1.0)
            case .print: (0.7, 1.6)
            }
        }
    }
    enum Metadata: String, Codable, CaseIterable { case all, noLocation, none }
    enum Naming: String, Codable, CaseIterable { case original, custom }

    static let hdrPeak = 4.0

    var format = PhotoRender.Format.jpeg
    var quality = 0.9
    var longSide = 0
    var space = Space.srgb
    var sharpen = Sharpen.none
    var hdr = false
    var metadata = Metadata.all
    var naming = Naming.original
    var name = ""
    /// Added to every file's name, before the extension ("-web").
    var suffix = ""
    /// A folder inside the export folder for these files.
    var subfolder = ""
    var watermark: PhotoWatermark?

    /// Whether this photo is saved with HDR: when asked here, or when it was edited in HDR (so its
    /// bright highlights aren't lost), in a format that carries it. Photos on film are saved in SDR.
    func savesHDR(_ record: PhotoRecord) -> Bool {
        (hdr || record.hdr == true) && format.canBeHDR && !record.filmOn && record.adjust.process >= 2
    }

    /// The file's name (no extension): as the photo, or the name given and its number, then the suffix.
    func fileName(for path: String, number: Int) -> String {
        // A copy: the file's name and "-copy2".
        let original = URL(fileURLWithPath: PhotoCatalog.file(of: path)).deletingPathExtension().lastPathComponent
            + (PhotoCatalog.copyNumber(path).map { "-copy\($0)" } ?? "")
        let base = name.trimmingCharacters(in: .whitespaces)
        let tail = Self.safe(suffix)
        guard naming == .custom, !base.isEmpty else { return original + tail }
        return base + "-" + String(format: "%03d", number + 1) + tail
    }

    /// Where the files go: the export folder, or its subfolder.
    func outputFolder(in folder: URL) -> URL {
        let sub = Self.safe(subfolder).trimmingCharacters(in: .whitespaces)
        return sub.isEmpty ? folder : folder.appendingPathComponent(sub, isDirectory: true)
    }

    /// Nothing that would climb out of a folder or end a name early.
    private static func safe(_ text: String) -> String {
        text.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "..", with: ".")
    }
}

extension PhotoExportSettings {
    private enum CodingKeys: String, CodingKey {
        case format, quality, longSide, space, sharpen, hdr, metadata, naming, name, suffix, subfolder, watermark
    }

    /// Settings saved before a key existed read with its default (a 3.6.2 preset has no suffix, subfolder or watermark).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PhotoExportSettings()
        format = try c.decodeIfPresent(PhotoRender.Format.self, forKey: .format) ?? d.format
        quality = try c.decodeIfPresent(Double.self, forKey: .quality) ?? d.quality
        longSide = try c.decodeIfPresent(Int.self, forKey: .longSide) ?? d.longSide
        space = try c.decodeIfPresent(Space.self, forKey: .space) ?? d.space
        sharpen = try c.decodeIfPresent(Sharpen.self, forKey: .sharpen) ?? d.sharpen
        hdr = try c.decodeIfPresent(Bool.self, forKey: .hdr) ?? d.hdr
        metadata = try c.decodeIfPresent(Metadata.self, forKey: .metadata) ?? d.metadata
        naming = try c.decodeIfPresent(Naming.self, forKey: .naming) ?? d.naming
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        suffix = try c.decodeIfPresent(String.self, forKey: .suffix) ?? d.suffix
        subfolder = try c.decodeIfPresent(String.self, forKey: .subfolder) ?? d.subfolder
        watermark = try c.decodeIfPresent(PhotoWatermark.self, forKey: .watermark)
    }
}

extension PhotoRender.Format {
    /// Holds a gain map for HDR screens.
    var canBeHDR: Bool { self == .jpeg || self == .heic }
}

/// An export's settings with a name: the built-in ones and yours.
struct PhotoExportPreset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var settings: PhotoExportSettings

    static let builtIn: [PhotoExportPreset] = [
        PhotoExportPreset(name: String(localized: "Full Size"), settings: PhotoExportSettings()),
        PhotoExportPreset(name: String(localized: "Web"), settings: PhotoExportSettings(quality: 0.85, longSide: 2048, sharpen: .screen, metadata: .noLocation)),
        PhotoExportPreset(name: String(localized: "Social"), settings: PhotoExportSettings(quality: 0.9, longSide: 1080, sharpen: .screen, metadata: .noLocation)),
        PhotoExportPreset(name: String(localized: "HDR"), settings: PhotoExportSettings(format: .heic, quality: 0.9, space: .p3, hdr: true)),
        PhotoExportPreset(name: String(localized: "Print"), settings: PhotoExportSettings(format: .tiff, space: .p3, sharpen: .print)),
    ]

    private static let key = "photoExportPresets"

    static var saved: [PhotoExportPreset] {
        get { (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode([PhotoExportPreset].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
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
            // First, so work under way sees it before what it made is let go.
            BaseCache.pressures.withLock { $0 += 1 }
            SceneCache.shared.removeAll()
            FilmTables.shared.purge()
            FilmAdvanced.dropMemory()
            // The loupe lets go of its full-size picture too.
            DispatchQueue.main.async { NotificationCenter.default.post(name: PhotoRender.memoryPressure, object: nil) }
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
        guard let image = Self.texture(source)?.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)) else { return nil }
        let bytes = Int(extent.width) * Int(extent.height) * 8
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

    /// A picture worked out now into a texture (half floats, linear), at the same place. Drawn the way the screen
    /// is drawn (rows from the top, then turned upright): a texture given straight to Core Image as its destination
    /// comes out one row off for the scene's own passes (measured against memory: the self-test "film on screen").
    /// `bands`: at most about this many pixels worked out at once (rows from the top), for a picture whose passes
    /// hold a lot of memory per pixel (the film).
    /// `cancelled`: asked before each band; true gives up (nil).
    static func texture(_ image: CIImage, bands: Int = 0, cancelled: () -> Bool = { false }) -> CIImage? {
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0, let device = PhotoEngine.device, let queue else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let placed = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let rows = bands > 0 ? max(256, min(height, bands / width)) : height
        // Each band into a texture of its own size (rows from the top), then copied into its place.
        let bandDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: rows, mipmapped: false)
        bandDescriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        bandDescriptor.storageMode = .private
        guard let strip = rows < height ? device.makeTexture(descriptor: bandDescriptor) : texture else { return nil }
        let failures = FilmHalation.failures
        for top in stride(from: 0, to: height, by: rows) {
            if cancelled() { return nil }
            let count = min(rows, height - top)
            let band = CGRect(x: 0, y: height - top - count, width: width, height: count)
            guard let buffer = queue.makeCommandBuffer() else { return nil }
            let destination = CIRenderDestination(width: width, height: count, pixelFormat: .rgba16Float, commandBuffer: buffer) { strip }
            destination.colorSpace = linear
            guard let task = try? PhotoEngine.context.startTask(toRender: placed.cropped(to: band).transformed(by: CGAffineTransform(translationX: 0, y: -band.minY)),
                                                                to: destination) else { return nil }
            if strip !== texture, let blit = buffer.makeBlitCommandEncoder() {
                blit.copy(from: strip, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: width, height: count, depth: 1),
                          to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: top, z: 0))
                blit.endEncoding()
            }
            buffer.commit()
            buffer.waitUntilCompleted()
            // A pass that failed gives nothing (the caller keeps what it had), never a black picture.
            guard buffer.status == .completed, (try? task.waitUntilCompleted()) != nil, FilmHalation.failures == failures else { return nil }
        }
        // The texture's first row is the top; Core Image reads a texture's first row as the bottom.
        let upright = CGAffineTransform(scaleX: 1, y: -1).concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY + CGFloat(height)))
        return CIImage(mtlTexture: texture, options: [.colorSpace: linear])?.transformed(by: upright)
    }

    private static let queue = PhotoEngine.device?.makeCommandQueue()

    /// How many times memory ran short: work that started before the last time isn't kept (it would hold on to memory
    /// the Mac asked back).
    static let pressures = FilmLocked(0)
}

/// Lets only a few full-size films work out at once: each holds a lot of GPU memory while it does, and they
/// share one GPU anyway (two on a Mac with 24 GB or more, else one).
actor FilmGate {
    static let shared = FilmGate(slots: ProcessInfo.processInfo.physicalMemory >= 24 << 30 ? 2 : 1)
    private var free: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(slots: Int) { free = slots }

    func enter() async {
        if free > 0 { free -= 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty { free += 1 } else { waiting.removeFirst().resume() }
    }
}

/// The scene light under a film preview, worked out into a texture and kept for the next few redraws: while only the
/// film's settings change (a film slider), the adjustments and local tone aren't done again. Four: Compare's two
/// photos, each while dragged and at rest.
final class SceneCache: @unchecked Sendable {
    static let shared = SceneCache()
    struct Key: Hashable {
        let base: String
        let adjust: PhotoAdjustments
        let overlay: Int?
        /// Whether depth-based masks can be made yet (they appear once the depth model is ready).
        let depth: Bool
    }
    private var kept: [(key: Key, image: CIImage)] = []
    private let lock = NSLock()
    func scene(_ key: Key, make: () -> CIImage) -> CIImage? {
        if let known = lock.withLock({ kept.first { $0.key == key }?.image }) { return known }
        guard let image = BaseCache.texture(make()) else { return nil }
        lock.withLock {
            kept.removeAll { $0.key == key }
            kept.append((key, image))
            if kept.count > 4 { kept.removeFirst() }
        }
        return image
    }

    /// The full size's scene (one: 24 MP is 190 MB), kept while only the film changes. `make` nil: not kept.
    /// The full size's scenes (24 MP is 190 MB each), kept while only the film changes: two, one per photo (Compare).
    private var whole: [(key: Key, image: CIImage)] = []

    /// `cancelled`: a build that gave up (or one memory ran short during) isn't kept.
    func full(_ key: Key, cancelled: () -> Bool = { false }, make: () -> CIImage?) -> CIImage? {
        if let known = lock.withLock({ whole.first { $0.key == key }?.image }) { return known }
        let pressures = BaseCache.pressures.withLock { $0 }
        // This photo's old one goes before the new one is made; so does the oldest past two.
        lock.withLock {
            whole.removeAll { $0.key.base == key.base }
            if whole.count >= 2 { whole.removeFirst() }
        }
        guard let image = make(), !cancelled(), BaseCache.pressures.withLock({ $0 }) == pressures else { return nil }
        lock.withLock { whole.append((key, image)) }
        return image
    }

    /// Lets go of a photo's full-size scene (zoomed out, or another photo shown).
    func dropFull(_ path: String) { lock.withLock { whole.removeAll { $0.key.base.hasSuffix("|" + path) } } }

    func removeAll() { lock.withLock { kept = []; whole = [] } }

    /// Whether depth masks can be made (the depth model is there), looked at no more than once a second.
    static var depthReady: Bool {
        depthLock.withLock {
            if !depthKnown, Date.now.timeIntervalSince(depthChecked) > 1 {
                depthChecked = .now
                depthKnown = PhotoDepth.isReady
            }
            return depthKnown
        }
    }
    nonisolated(unsafe) private static var depthKnown = false
    nonisolated(unsafe) private static var depthChecked = Date.distantPast
    private static let depthLock = NSLock()
}

/// Full-size pictures for looking closely: worked out one at a time, on one serial queue (nothing waits on a thread).
/// Each loupe asks on its own `channel` (Compare has two, and "before" its own): there the newest request wins (an older
/// one still queued is dropped, one being worked out stops at its next band). Channels don't make each other stale.
final class FullBuilds: @unchecked Sendable {
    static let shared = FullBuilds()
    private var current: [UUID: Int] = [:]
    private var counter = 0
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "Pluck full-size pictures", qos: .userInitiated)
    private var done = 0, running = 0, most = 0
    /// How many builds ran to the end, and the most at once (tests).
    var finished: Int { lock.withLock { done } }
    var mostAtOnce: Int { lock.withLock { most } }
    func resetMost() { lock.withLock { most = 0 } }

    /// A new request on this channel: its older ones are now stale.
    func ticket(_ channel: UUID) -> Int { lock.withLock { counter += 1; current[channel] = counter; return counter } }
    /// This request isn't wanted any more.
    func cancel(_ channel: UUID, _ ticket: Int) { lock.withLock { if current[channel] == ticket { current[channel] = nil } } }
    func isCurrent(_ channel: UUID, _ ticket: Int) -> Bool { lock.withLock { current[channel] == ticket } }

    /// Works out `make` on the queue when it's this request's turn and it's still its channel's newest; nil if it gave up.
    /// `film`: it works out film, so it waits for a `FilmGate` slot first (never at once with an export on a small Mac).
    func build(_ channel: UUID, _ ticket: Int, film: Bool = false, _ make: @escaping (_ cancelled: @escaping () -> Bool) -> CIImage?) async -> CIImage? {
        if film { await FilmGate.shared.enter() }
        defer { if film { Task { await FilmGate.shared.leave() } } }
        guard isCurrent(channel, ticket) else { return nil }
        return await withCheckedContinuation { (done: CheckedContinuation<CIImage?, Never>) in
            queue.async { [self] in
                let stale = { [self] in !isCurrent(channel, ticket) }
                guard !stale() else { done.resume(returning: nil); return }
                lock.withLock { running += 1; most = max(most, running) }
                let made = make(stale)
                lock.withLock { running -= 1; if made != nil, current[channel] == ticket { self.done += 1 } }
                done.resume(returning: stale() ? nil : made)
            }
        }
    }
}
