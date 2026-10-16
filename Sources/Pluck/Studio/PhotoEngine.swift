import CoreImage
import Foundation
import Metal
import simd

/// Pluck's photo engine. RAW files are decoded neutral (no camera maker's look: no boost, no
/// tone mapping, the highlights' headroom kept), so every camera starts from the same place.
/// Then, on the GPU, in this order:
///  1. exposure and white balance (a chromatic adaptation, in Kelvin for RAW),
///  2. local tone: shadows, highlights, clarity and texture work on an edge-aware base layer (a
///     guided filter), so they recover a lot without halos,
///  3. the profile: how scene light becomes a picture (a filmic curve with contrast, whites and
///     blacks), the same for every camera,
///  4. then colour (curves, wheels, saturation; a lookup table), detail and geometry.
enum PhotoEngine {
    /// How the light becomes a picture: the starting point, as in Lightroom's profiles.
    enum Profile: String, Codable, CaseIterable, Identifiable {
        case neutral, standard, vivid, flat, monochrome, asShot
        var id: String { rawValue }
        var title: String {
            switch self {
            case .neutral: String(localized: "Neutral")
            case .standard: String(localized: "Standard")
            case .vivid: String(localized: "Vivid")
            case .flat: String(localized: "Flat")
            case .monochrome: String(localized: "Monochrome")
            case .asShot: String(localized: "As Shot")
            }
        }
    }

    // MARK: - The GPU

    /// The one context all photo work goes through, so what it keeps on the GPU is shared.
    static let device = MTLCreateSystemDefaultDevice()
    nonisolated(unsafe) static let context: CIContext = {
        let options: [CIContextOption: Any] = [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                               .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false, .name: "Pluck Photo"]
        return device.map { CIContext(mtlDevice: $0, options: options) } ?? CIContext(options: options)
    }()

    // MARK: - Developing

    /// The picture from a decoded photo (linear light, white at 1, brighter kept above 1).
    /// `isRaw`: a neutral RAW decode (the profile makes the picture); otherwise a finished
    /// picture (JPEG, HEIC), where As Shot leaves its look alone.
    /// `scene`: stop before the profile and give scene light (for the film engine, which makes
    /// its own picture from it).
    /// `cacheKey`: the decoded photo is one that's kept (a preview's or the full size); its
    /// local-tone layers are then worked out once per white balance and reused while the other
    /// sliders move. Exposure needs no new layers: it moves the log brightness, and the layers
    /// with it.
    /// `masks`: the masks' shapes (one per channel, see PhotoMasks.layer) for version 2;
    /// `overlay`: the mask shown in red.
    static func develop(_ image: CIImage, _ a: PhotoAdjustments, isRaw: Bool, asShotKelvin: Double = 5500, scene: Bool = false,
                        cacheKey: String? = nil, masks: CIImage? = nil, overlay: Int? = nil) -> CIImage {
        let extent = image.extent
        let modern = a.process >= 2
        // 1. Exposure and white balance: one matrix in linear light.
        let gain = pow(2, a.exposure)
        let balance = whiteBalance(a, kelvin: asShotKelvin)
        let exposed = linear(image, balance.map { $0 * gain }, wide: modern)
        // 2–3. Local tone and the profile, in one pass, from two base layers (and the haze, when
        // it's taken out).
        let long = max(extent.width, extent.height)
        let local = modern && masks != nil ? Array(a.masks.prefix(PhotoMasks.limit)) : []
        let hazy = modern && (a.dehaze != 0 || local.contains { $0.dehaze != 0 })
        let layers: Layers
        var shift: Float = 0
        func make(_ source: CIImage) -> Layers {
            Layers(large: guide(source, scale: 640 / long, radius: 16, eps: 0.03), small: guide(source, scale: 1600 / long, radius: 6, eps: 0.02),
                   haze: hazy ? haze(source, long: long) : nil)
        }
        if let cacheKey {
            let key = cacheKey + "|\(a.process)|\(hazy)|" + balance.map { String(format: "%.4f", $0) }.joined(separator: ",")
            layers = GuideCache.shared.layers(key) { make(linear(image, balance, wide: modern)) }
            shift = Float(a.exposure)
        } else {
            layers = make(exposed)
        }
        let profile = a.profile ?? (isRaw ? .neutral : .asShot)
        let shown = profile == .asShot && isRaw ? .standard : profile
        func params(_ a: PhotoAdjustments, shift: Float) -> Params {
            var p = Params()
            p.shadows = Float(a.shadows / 100)
            p.highlights = Float(a.highlights / 100)
            p.whites = Float(a.whites / 100)
            p.blacks = Float(a.blacks / 100)
            p.contrast = Float(a.contrast / 100)
            p.clarity = Float(a.clarity / 100)
            p.texture = Float(a.texture / 100)
            p.dehaze = Float(a.dehaze / 100)
            p.profile = Int32(PhotoEngine.Profile.allCases.firstIndex(of: shown) ?? 0)
            p.isRaw = isRaw ? 1 : 0
            p.scene = scene ? 1 : 0
            p.shift = shift
            p.process = Int32(min(a.process, 2))
            if modern {
                tone(a, profile: shown, into: &p)
                p.curves = a.curves.isDefault ? 0 : 1
                if let airlight = layers.haze?.airlight {
                    // The haze's colour, at this exposure.
                    let k = Float(cacheKey == nil ? 1 : gain)
                    p.hazeR = airlight.x * k; p.hazeG = airlight.y * k; p.hazeB = airlight.z * k
                }
            }
            return p
        }
        var p = params(a, shift: shift)
        p.masks = Int32(local.count)
        p.overlay = Float(overlay.map { $0 < local.count ? $0 : -1 } ?? -1)
        var all = [p], grades = [Grade(a)], infos: [MaskInfo] = []
        // Each mask: the photo's settings with the mask's changes, and its own white balance
        // and exposure as a matrix on top of the photo's.
        for mask in local {
            var m = a
            let k = mask.amount
            func add(_ path: WritableKeyPath<PhotoAdjustments, Double>, _ amount: Double) { m[keyPath: path] = min(max(m[keyPath: path] + amount * k, -100), 100) }
            add(\.contrast, mask.contrast); add(\.highlights, mask.highlights); add(\.shadows, mask.shadows)
            add(\.saturation, mask.saturation); add(\.clarity, mask.clarity); add(\.texture, mask.texture); add(\.dehaze, mask.dehaze)
            add(\.temperature, mask.warmth); add(\.tint, mask.tint)
            let change = multiply(whiteBalance(m, kelvin: asShotKelvin), inverse(balance)).map { $0 * pow(2, mask.exposure * k) }
            var own = params(m, shift: shift + Float(mask.exposure * k))
            // The haze's colour as the mask sees it (its exposure and white balance too).
            let h = [Double(own.hazeR), Double(own.hazeG), Double(own.hazeB)]
            own.hazeR = Float(change[0] * h[0] + change[1] * h[1] + change[2] * h[2])
            own.hazeG = Float(change[3] * h[0] + change[4] * h[1] + change[5] * h[2])
            own.hazeB = Float(change[6] * h[0] + change[7] * h[1] + change[8] * h[2])
            all.append(own)
            grades.append(Grade(m))
            var info = MaskInfo()
            info.m0 = SIMD4(Float(change[0]), Float(change[3]), Float(change[6]), 0)
            info.m1 = SIMD4(Float(change[1]), Float(change[4]), Float(change[7]), 0)
            info.m2 = SIMD4(Float(change[2]), Float(change[5]), Float(change[8]), 0)
            if let range = mask.shape.first(where: { $0.kind == .luminance }) {
                info.lum = SIMD4(Float(range.low), Float(range.high), Float(max(range.smooth, 0.01)), 1)
            }
            if let range = mask.shape.first(where: { $0.kind == .colour }) {
                info.col = SIMD4(Float(range.hue), Float(range.hueRange), 1, 0)
            }
            info.col.w = mask.invert ? 1 : 0
            infos.append(info)
        }
        if infos.isEmpty { infos = [MaskInfo()] }
        // The layers go in small and are read smoothly where each pixel falls (scaling them up
        // to the photo's size first would cost more than all the rest).
        let dot = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let hazeLayer = layers.haze?.through ?? dot
        let maskLayer = local.isEmpty ? dot : masks ?? dot
        let inputs = [exposed.clampedToExtent(), layers.large, layers.small, hazeLayer, maskLayer]
        let data = all.withUnsafeBytes { Data($0) }
        let grade = grades.withUnsafeBytes { Data($0) }
        let info = infos.withUnsafeBytes { Data($0) }
        let curves = modern && !a.curves.isDefault ? curveTable(a.curves) : Data(count: 16)
        guard let developed = try? apply(DevelopPass.self, extent: extent, inputs: inputs, arguments: [
            "params": data, "grade": grade, "curves": curves, "masks": info,
            "layers": [layers.large.extent, layers.small.extent, hazeLayer.extent, maskLayer.extent, extent]
                .flatMap { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] },
        ]) else { return exposed }
        return developed
    }

    /// A mask's limits besides its shape, for the GPU (see MaskInfo in the shaders).
    struct MaskInfo {
        var m0 = SIMD4<Float>(1, 0, 0, 0), m1 = SIMD4<Float>(0, 1, 0, 0), m2 = SIMD4<Float>(0, 0, 1, 0)
        var lum = SIMD4<Float>(), col = SIMD4<Float>()
    }

    /// What's worked out small from the photo once per white balance: the two local-tone layers,
    /// and the haze (how much light gets through, and its colour) when dehaze is on.
    struct Layers {
        var large: CIImage
        var small: CIImage
        var haze: (through: CIImage, airlight: SIMD3<Float>)?
    }

    /// A 3×3 matrix in linear light, then within range (and a step Core Image always runs on
    /// the GPU: a photo straight from memory isn't handed to the passes otherwise). `wide`:
    /// colours past sRGB (negative values) are kept, for the gamut compression later.
    private static func linear(_ image: CIImage, _ m: [Double], wide: Bool = false) -> CIImage {
        let low: CGFloat = wide ? -64 : 0
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: m[0], y: m[1], z: m[2], w: 0),
            "inputGVector": CIVector(x: m[3], y: m[4], z: m[5], w: 0),
            "inputBVector": CIVector(x: m[6], y: m[7], z: m[8], w: 0),
        ]).applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: low, y: low, z: low, w: 1),
                                                       "inputMaxComponents": CIVector(x: 64, y: 64, z: 64, w: 1)])
        // (An alpha of at least 1 reaches past the photo: kept to its size.)
        .cropped(to: image.extent)
    }

    /// The haze, worked out small (He et al.'s dark channel prior): its colour is the brightest
    /// of the softened photo; how much light gets through is one minus the darkest channel
    /// around each place (relative to that colour), smoothed along the photo's edges.
    private static func haze(_ image: CIImage, long: Double) -> (through: CIImage, airlight: SIMD3<Float>) {
        let s = min(640 / long, 1)
        // The edges carried on before it's made small, so the edge pixels aren't mixed with
        // nothing (which reads as haze there).
        let frame = image.extent.applying(CGAffineTransform(scaleX: s, y: s)).integral
        let carried = image.clampedToExtent().cropped(to: image.extent.insetBy(dx: -16 / s, dy: -16 / s))
        let small = (s < 0.5 ? carried.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": s, "inputAspectRatio": 1])
                             : carried.transformed(by: CGAffineTransform(scaleX: s, y: s))).cropped(to: frame)
        let extent = small.extent
        // The haze's colour: the average of the haziest 0.1% (where the darkest channel is
        // brightest), from a softened copy so single bright lights don't count.
        let soft = small.clampedToExtent().applyingGaussianBlur(sigma: 3).cropped(to: extent)
        let w = Int(extent.width), h = Int(extent.height)
        var pixels = [Float](repeating: 0, count: max(w * h * 4, 4))
        context.render(soft, toBitmap: &pixels, rowBytes: w * 16, bounds: extent, format: .RGBAf, colorSpace: nil)
        // The cut-off for the haziest share from a histogram of the darkest channel (no sorting).
        let n = w * h
        var darkest = [Float](repeating: 0, count: n)
        var top: Float = 1e-6
        for i in 0..<n { darkest[i] = min(pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2]); top = max(top, darkest[i]) }
        var bins = [Int](repeating: 0, count: 1024)
        for v in darkest { bins[min(max(Int(v / top * 1023), 0), 1023)] += 1 }
        let wanted = max(n / 1000, 1)
        var cut = 1023, seen = 0
        while cut > 0, seen + bins[cut] < wanted { seen += bins[cut]; cut -= 1 }
        let threshold = Float(cut) / 1023 * top
        var sum = SIMD3<Float>(), count: Float = 0
        for i in 0..<n where darkest[i] >= threshold {
            sum += SIMD3(pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2])
            count += 1
        }
        let airlight = simd_max(sum / max(count, 1), SIMD3(repeating: 0.05))
        let dark = small.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(1 / airlight.x), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(1 / airlight.y), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(1 / airlight.z), w: 0),
        ]).applyingFilter("CIMinimumComponent").clampedToExtent().applyingFilter("CIMorphologyMinimum", parameters: ["inputRadius": 4]).cropped(to: extent)
        let through = dark.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: -0.95, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: -0.95, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: -0.95, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
        ])
        // Both carried on a little past the edges, or the filter reads nothing there (not
        // endlessly: the passes before it can't be asked for an endless picture).
        let margin = extent.insetBy(dx: -24, dy: -24)
        let guideImage = small.applyingFilter("CIMaximumComponent").clampedToExtent().cropped(to: margin)
        let refined = through.clampedToExtent().cropped(to: margin)
            .applyingFilter("CIGuidedFilter", parameters: ["inputGuideImage": guideImage, "inputRadius": 10, "inputEpsilon": 0.001])
            .cropped(to: extent)
        return (refined, airlight)
    }

    /// The guided filter's coefficients (a, b) for the log brightness, worked out small: the
    /// base layer is a·L + b, which follows edges instead of blurring over them.
    private static func guide(_ image: CIImage, scale: Double, radius: Double, eps: Float) -> CIImage {
        let s = min(scale, 1)
        // Properly filtered: a sampled one would be noisy on a full-size photo. The edges are
        // carried on first, so the edge pixels aren't mixed with nothing.
        let extent = image.extent.applying(CGAffineTransform(scaleX: s, y: s)).integral
        let carried = image.clampedToExtent().cropped(to: image.extent.insetBy(dx: -16 / s, dy: -16 / s))
        let small = (s < 0.5 ? carried.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": s, "inputAspectRatio": 1])
                             : carried.transformed(by: CGAffineTransform(scaleX: s, y: s))).cropped(to: extent)
        guard let prepared = try? apply(GuidePrep.self, extent: extent, inputs: [small.clampedToExtent()], arguments: [:]) else { return small }
        let means = prepared.clampedToExtent().applyingFilter("CIBoxBlur", parameters: ["inputRadius": radius]).cropped(to: extent)
        let epsData = withUnsafeBytes(of: eps) { Data($0) }
        guard let coef = try? apply(GuideCoef.self, extent: extent, inputs: [means.clampedToExtent()], arguments: ["eps": epsData]) else { return small }
        return coef.clampedToExtent().applyingFilter("CIBoxBlur", parameters: ["inputRadius": radius]).cropped(to: extent)
    }

    // MARK: - White balance

    /// A chromatic adaptation in linear sRGB that makes what's white under the chosen light
    /// white: for RAW the light is in Kelvin (from the camera's as-shot value), otherwise
    /// relative. Version 2 adapts with CAT16 (as darktable does: fewer impossible colours under
    /// difficult light), version 1 with Bradford.
    static func whiteBalance(_ a: PhotoAdjustments, kelvin asShot: Double) -> [Double] {
        guard a.temperature != 0 || a.tint != 0 else { return [1, 0, 0, 0, 1, 0, 0, 0, 1] }
        let cone = a.process >= 2 ? cat16 : bradford
        let from = asShot, to = kelvin(a, asShot: asShot)
        let s = lms(chromaticity(kelvin: from, tint: 0), cone), t = lms(chromaticity(kelvin: to, tint: a.tint), cone)
        let d = [s[0] / t[0], s[1] / t[1], s[2] / t[2]]
        // XYZ → sRGB · cone⁻¹ · diag · cone · sRGB → XYZ
        let toXYZ = [0.4124, 0.3576, 0.1805, 0.2126, 0.7152, 0.0722, 0.0193, 0.1192, 0.9505]
        let fromXYZ = [3.2406, -1.5372, -0.4986, -0.9689, 1.8758, 0.0415, 0.0557, -0.2040, 1.0570]
        let diag = [d[0], 0, 0, 0, d[1], 0, 0, 0, d[2]]
        return multiply(fromXYZ, multiply(inverse(cone), multiply(diag, multiply(cone, toXYZ))))
    }

    private static let bradford = [0.8951, 0.2664, -0.1614, -0.7502, 1.7135, 0.0367, 0.0389, -0.0685, 1.0296]
    private static let cat16 = [0.401288, 0.650173, -0.051461, -0.250268, 1.204414, 0.045854, -0.002079, 0.048952, 0.953127]

    static func inverse(_ m: [Double]) -> [Double] {
        let a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8]
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        return [(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det,
                (f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det,
                (d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]
    }

    /// The light the photo is balanced for (higher is warmer, as in Lightroom): up to about 2.5×
    /// either way from as shot.
    static func kelvin(_ a: PhotoAdjustments, asShot: Double) -> Double {
        min(max(asShot * pow(2, a.temperature / 100 * 1.3), 2000), 50000)
    }

    /// A light's chromaticity (Kim et al.'s fit of the Planckian locus), moved green or magenta.
    private static func chromaticity(kelvin t: Double, tint: Double) -> (Double, Double) {
        let t = min(max(t, 1667), 25000)
        let x: Double = t <= 4000
            ? -0.2661239e9 / (t * t * t) - 0.2343589e6 / (t * t) + 0.8776956e3 / t + 0.179910
            : -3.0258469e9 / (t * t * t) + 2.1070379e6 / (t * t) + 0.2226347e3 / t + 0.240390
        let y: Double
        if t <= 2222 { y = -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683 }
        else if t <= 4000 { y = -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867 }
        else { y = 3.0817580 * x * x * x - 5.87338670 * x * x + 3.75112997 * x - 0.37001483 }
        // Tint: magenta is positive (less green), about as in Lightroom.
        return (x + tint / 100 * 0.006, y - tint / 100 * 0.02)
    }

    private static func lms(_ xy: (Double, Double), _ m: [Double]) -> [Double] {
        let (x, y) = xy
        let X = x / y, Y = 1.0, Z = (1 - x - y) / y
        return [m[0] * X + m[1] * Y + m[2] * Z, m[3] * X + m[4] * Y + m[5] * Z, m[6] * X + m[7] * Y + m[8] * Z]
    }

    static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        var r = [Double](repeating: 0, count: 9)
        for i in 0..<3 { for j in 0..<3 { r[i * 3 + j] = (0..<3).reduce(0) { $0 + a[i * 3 + $1] * b[$1 * 3 + j] } } }
        return r
    }

    // MARK: - The GPU passes

    struct Params {
        var shadows: Float = 0, highlights: Float = 0, whites: Float = 0, blacks: Float = 0
        var contrast: Float = 0, clarity: Float = 0, texture: Float = 0, dehaze: Float = 0
        var profile: Int32 = 0, isRaw: Int32 = 0, scene: Int32 = 0
        /// Stops of exposure the layers were made without.
        var shift: Float = 0
        /// `masks`: how many masks follow this in the list; `overlay`: the one shown red (-1: none).
        var process: Int32 = 1, curves: Int32 = 0, mono: Int32 = 0, masks: Int32 = 0
        var hazeR: Float = 0, hazeG: Float = 0, hazeB: Float = 0, sat: Float = 1
        var toneLo: Float = 0, toneHi: Float = 1, toneGrey: Float = 0.5, toneY: Float = 0.5
        var toneSlope: Float = 1, tonePt: Float = 3, tonePb: Float = 3, toneFloor: Float = 0
        var toneCeiling: Float = 1, overlay: Float = -1, pad2: Float = 0, pad3: Float = 0
    }

    /// The colour wheels and the mixer, for the GPU.
    struct Grade {
        typealias Eight = (Float, Float, Float, Float, Float, Float, Float, Float)
        var lift = SIMD4<Float>(), gamma = SIMD4<Float>(), gain = SIMD4<Float>(), offset = SIMD4<Float>()
        var hue: Eight = (0, 0, 0, 0, 0, 0, 0, 0)
        var sat: Eight = (0, 0, 0, 0, 0, 0, 0, 0)
        var lum: Eight = (0, 0, 0, 0, 0, 0, 0, 0)
        var vibrance: Float = 0, saturation: Float = 0
        var wheels: Int32 = 0, mixer: Int32 = 0

        init(_ a: PhotoAdjustments) {
            func wheel(_ w: ColorWheels.Wheel) -> SIMD4<Float> {
                let (r, g, b) = w.rgb
                return SIMD4(Float(r), Float(g), Float(b), Float(w.master))
            }
            let w = a.wheels
            lift = wheel(w.lift); gamma = wheel(w.gamma); gain = wheel(w.gain); offset = wheel(w.offset)
            wheels = w.isDefault ? 0 : 1
            func eight(_ v: [Double]) -> Eight {
                let f = (v + [Double](repeating: 0, count: 8)).prefix(8).map(Float.init)
                return (f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7])
            }
            hue = eight(a.mixer.hue); sat = eight(a.mixer.saturation); lum = eight(a.mixer.luminance)
            mixer = a.mixer.isDefault ? 0 : 1
            vibrance = Float(a.vibrance / 100); saturation = Float(a.saturation / 100)
        }
    }

    /// The tone curve for these settings (version 2): AgX's shape (fitted to Blender's), with the
    /// slope at mid grey from Contrast and the profile, and the black and white points (in stops)
    /// from Blacks and Whites.
    static func tone(_ a: PhotoAdjustments, profile: Profile, into p: inout Params) {
        let lo = -12.47393 - a.blacks / 100 * 2.5, hi = 4.026069 - a.whites / 100 * 2.5
        let grey = (log2(0.18 * 1.15) - lo) / (hi - lo)
        let y0 = 0.5219
        let look: Double = switch profile {
        case .standard: 1.2
        case .vivid: 1.25
        case .flat: 0.8
        case .monochrome: 1.06
        default: 1
        }
        let contrast = 1 + a.contrast / 100 * (a.contrast > 0 ? 0.6 : 0.4)
        let slope = 0.12505 * look * contrast * (hi - lo)
        // Blacks also shape the toe: softer lifts the darkest tones, harder deepens them.
        let pt = 3.2 * pow(2, -a.blacks / 100 * 1.2), pb = 3.55
        // Asymptotes that make black black and white white at the ends of the range.
        func shoulder(_ top: Double) -> Double {
            let d = slope * (1 - grey)
            return y0 + d / pow(1 + pow(d / (top - y0), pb), 1 / pb)
        }
        func toe(_ bottom: Double) -> Double {
            let d = slope * grey
            return y0 - d / pow(1 + pow(d / (y0 - bottom), pt), 1 / pt)
        }
        var top = 1.0001, high = 50.0
        for _ in 0..<40 { let mid = (top + high) / 2; if shoulder(mid) < 1 { top = mid } else { high = mid } }
        var bottom = -50.0, low = -0.0001
        for _ in 0..<40 { let mid = (bottom + low) / 2; if toe(mid) > 0 { low = mid } else { bottom = mid } }
        p.toneLo = Float(lo); p.toneHi = Float(hi); p.toneGrey = Float(grey); p.toneY = Float(y0)
        p.toneSlope = Float(slope); p.tonePt = Float(pt); p.tonePb = Float(pb)
        p.toneFloor = Float((bottom + low) / 2); p.toneCeiling = Float((top + high) / 2)
        p.sat = Float(profile == .vivid ? 1.35 : profile == .standard ? 1.15 : profile == .flat ? 0.95 : 1)
        p.mono = profile == .monochrome ? 1 : 0
    }

    /// The curves as a table of 128 steps per channel (the master after each).
    static func curveTable(_ curves: PhotoCurves) -> Data {
        let master = Curve(curves.master), red = Curve(curves.red), green = Curve(curves.green), blue = Curve(curves.blue)
        var values = [Float](repeating: 0, count: 128 * 4)
        for i in 0..<128 {
            let x = Double(i) / 127
            values[i * 4] = Float(master.value(red.value(x)))
            values[i * 4 + 1] = Float(master.value(green.value(x)))
            values[i * 4 + 2] = Float(master.value(blue.value(x)))
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static let shaders = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct Params {
        float shadows, highlights, whites, blacks;
        float contrast, clarity, texture, dehaze;
        int profile, isRaw, scene;
        float shift;
        int process, curves, mono, masks;
        float hazeR, hazeG, hazeB, sat;
        float toneLo, toneHi, toneGrey, toneY;
        float toneSlope, tonePt, tonePb, toneFloor;
        float toneCeiling, overlay, pad2, pad3;
    };

    // Colour wheels and the mixer (scene light).
    struct Grade {
        float4 lift, gamma, gain, offset;
        float hue[8]; float sat[8]; float lum[8];
        float vibrance, saturation;
        int wheels, mixer;
    };

    constant float3x3 toRec2020 = float3x3(float3(0.6274039, 0.0690973, 0.0163914),
                                           float3(0.3292830, 0.9195404, 0.0880133),
                                           float3(0.0433131, 0.0113623, 0.8955953));
    constant float3x3 fromRec2020 = float3x3(float3(1.6604910, -0.1245505, -0.0181508),
                                             float3(-0.5876411, 1.1328999, -0.1005789),
                                             float3(-0.0728499, -0.0083494, 1.1187297));
    inline float luma2020(float3 c) { return dot(c, float3(0.2627, 0.6780, 0.0593)); }

    inline float scbrt(float x) { return sign(x) * pow(abs(x), 1.0 / 3.0); }

    // OkLab from and to linear sRGB (negative values allowed: colours past sRGB).
    inline float3 oklab(float3 c) {
        float l = scbrt(0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b);
        float m = scbrt(0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b);
        float s = scbrt(0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b);
        return float3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                      1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                      0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s);
    }
    inline float3 fromOklab(float3 o) {
        float l = o.x + 0.3963377774 * o.y + 0.2158037573 * o.z;
        float m = o.x - 0.1055613458 * o.y - 0.0638541728 * o.z;
        float s = o.x - 0.0894841775 * o.y - 1.2914855480 * o.z;
        l = l * l * l; m = m * m * m; s = s * s * s;
        return float3(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                      -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                      -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s);
    }

    // Colours past the screen's (sRGB) brought inside, each channel's distance from the
    // brightest compressed smoothly (the ACES reference gamut compression): hue and gradation
    // kept, nothing clipped flat.
    inline float3 compressGamut(float3 c) {
        float ach = max(c.r, max(c.g, c.b));
        if (ach <= 1e-6) return max(c, 0.0);
        const float3 thr = float3(0.815, 0.803, 0.880), lim = float3(1.147, 1.264, 1.312);
        const float pw = 1.2;
        float3 scale = (lim - thr) / pow(pow((1.0 - thr) / (lim - thr), -pw) - 1.0, 1.0 / pw);
        float3 d = (ach - c) / ach;
        float3 over = max(d - thr, 0.0);
        float3 dc = select(d, thr + over / pow(1.0 + pow(over / scale, pw), 1.0 / pw), d > thr);
        return max(ach - dc * ach, 0.0);
    }

    // The tone curve (AgX's shape): log exposure in, picture out, through mid grey at the slope.
    inline float toneCurve(float x, constant Params &p) {
        if (x >= p.toneGrey) {
            float d = p.toneSlope * (x - p.toneGrey);
            return p.toneY + d / pow(1.0 + pow(d / (p.toneCeiling - p.toneY), p.tonePb), 1.0 / p.tonePb);
        }
        float d = p.toneSlope * (p.toneGrey - x);
        return p.toneY - d / pow(1.0 + pow(d / (p.toneY - p.toneFloor), p.tonePt), 1.0 / p.tonePt);
    }

    inline float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

    // log brightness and its square, for the guided filter's means
    // Where an input's pixel is: Core Image may hand over a bigger piece than the output's.
    inline uint2 at(uint2 gid, int2 offset, uint2 size) {
        int2 p = clamp(int2(gid) + offset, int2(0), int2(size) - 1);
        return uint2(p);
    }

    kernel void guidePrep(texture2d<float, access::read> src [[texture(0)]],
                          texture2d<float, access::write> dst [[texture(1)]],
                          constant int2 *offsets [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float L = log2(max(luma(src.read(at(gid, offsets[0], uint2(src.get_width(), src.get_height()))).rgb), 1e-5));
        dst.write(float4(L, L * L, 0, 1), gid);
    }

    // a = var / (var + eps), b = mean − a·mean
    kernel void guideCoef(texture2d<float, access::read> src [[texture(0)]],
                          texture2d<float, access::write> dst [[texture(1)]],
                          constant float &eps [[buffer(0)]],
                          constant int2 *offsets [[buffer(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 m = src.read(at(gid, offsets[0], uint2(src.get_width(), src.get_height()))).rg;
        float v = max(m.y - m.x * m.x, 0.0);
        float a = v / (v + eps);
        dst.write(float4(a, m.x - a * m.x, 0, 1), gid);
    }

    // The ACES-like curve (Standard, Vivid): punchy, with a long shoulder.
    inline float3 filmic(float3 x) {
        float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
        x *= 0.6;
        return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
    }

    // AgX (Neutral, Flat, Monochrome): the gentlest way from scene light to a picture; very
    // bright colours fade to white instead of turning to flat, garish patches.
    inline float3 agx(float3 v) {
        const float3x3 inset = float3x3(float3(0.842479062253094, 0.0423282422610123, 0.0423756549057051),
                                        float3(0.0784335999999992, 0.878468636469772, 0.0784336),
                                        float3(0.0792237451477643, 0.0791661274605434, 0.879142973793104));
        const float3x3 outset = float3x3(float3(1.19687900512017, -0.0528968517574562, -0.0529716355144438),
                                         float3(-0.0980208811401368, 1.15190312990417, -0.0980434501171241),
                                         float3(-0.0990297440797205, -0.0989611768448433, 1.15107367264116));
        const float minEv = -12.47393, maxEv = 4.026069;
        v = inset * v;
        v = clamp(log2(max(v, 1e-10)), minEv, maxEv);
        v = (v - minEv) / (maxEv - minEv);
        float3 x2 = v * v, x4 = x2 * x2;
        v = 15.5 * x4 * x2 - 40.14 * x4 * v + 31.96 * x4 - 6.868 * x2 * v + 0.4298 * x2 + 0.1191 * v - 0.00232;
        v = outset * v;
        return pow(clamp(v, 0.0, 1.0), 2.2);
    }

    // Version 2, after the local tone: grading in scene light (Rec.2020), the mixer, vibrance and
    // saturation (OkLCh), the gamut compression, the tone curve and profile, then the curves.
    inline float3 finish(float3 c, constant Params &p, constant Grade &g, constant float4 *curve) {
        c = toRec2020 * c;
        if (g.wheels != 0) {
            float e = log2(max(luma2020(c), 1e-6) / 0.18);
            float shadow = 1.0 - smoothstep(-4.5, 0.5, e), light = smoothstep(-0.5, 3.5, e);
            float3 ev = g.offset.rgb * 0.5 + g.offset.w + shadow * (g.lift.rgb * 0.7 + g.lift.w * 1.5)
                      + light * (g.gain.rgb * 0.7 + g.gain.w * 1.5);
            c *= exp2(ev);
            // Midtones: a power around mid grey, per channel.
            float3 power = exp2(-0.8 * (g.gamma.w + g.gamma.rgb * 0.75));
            c = select(c, 0.18 * pow(max(c, 0.0) / 0.18, power), c > 0.0);
        }
        c = fromRec2020 * c;
        if (g.mixer != 0 || g.vibrance != 0 || g.saturation != 0) {
            float3 o = oklab(c);
            float C = length(o.yz), h = atan2(o.z, o.y) * 57.29578;
            if (h < 0) h += 360.0;
            if (g.mixer != 0 && C > 0.002) {
                const float centres[8] = {25, 60, 105, 145, 195, 255, 300, 345};
                float w[8], sum = 0;
                for (int i = 0; i < 8; i++) {
                    float d = abs(h - centres[i]);
                    d = fmod(d, 360.0);
                    if (d > 180) d = 360 - d;
                    w[i] = exp(-(d * d) / (2.0 * 22.0 * 22.0));
                    sum += w[i];
                }
                float dh = 0, ds = 0, dl = 0;
                for (int i = 0; i < 8; i++) { float k = w[i] / max(sum, 1e-6); dh += k * g.hue[i]; ds += k * g.sat[i]; dl += k * g.lum[i]; }
                // Grey stays grey: the mixer works in proportion to how colourful it is.
                float colourful = min(C / 0.08, 1.0);
                h += dh * 0.3 * colourful;
                C *= max(0.0, 1.0 + ds * 0.01 * colourful);
                o.x *= 1.0 + dl * 0.0035 * colourful;
            }
            float amount = 1.0 + g.saturation;
            if (g.vibrance != 0) {
                float skin = abs(h - 55.0);
                if (skin > 180) skin = 360 - skin;
                float protect = exp(-(skin * skin) / (2.0 * 18.0 * 18.0)) * 0.7;
                amount *= 1.0 + g.vibrance * (1.0 - min(C / 0.22, 1.0)) * (1.0 - protect);
            }
            C *= max(amount, 0.0);
            float r = h * 0.01745329;
            c = fromOklab(float3(o.x, C * cos(r), C * sin(r)));
        }
        // A finished picture shown as shot keeps its colours; everything else is brought inside.
        bool asShot = p.profile == 5 && p.isRaw == 0;
        c = asShot ? max(c, 0.0) : compressGamut(c);
        if (p.scene == 1) return min(c, 64.0);

        float3 outc;
        if (asShot) {
            outc = clamp(c, 0.0, 1.0);
        } else {
            const float3x3 inset = float3x3(float3(0.842479062253094, 0.0423282422610123, 0.0423756549057051),
                                            float3(0.0784335999999992, 0.878468636469772, 0.0784336),
                                            float3(0.0792237451477643, 0.0791661274605434, 0.879142973793104));
            const float3x3 outset = float3x3(float3(1.19687900512017, -0.0528968517574562, -0.0529716355144438),
                                             float3(-0.0980208811401368, 1.15190312990417, -0.0980434501171241),
                                             float3(-0.0990297440797205, -0.0989611768448433, 1.15107367264116));
            float3 v = p.mono != 0 ? float3(luma(c)) : c;
            v = inset * (v * 1.15);
            float3 x = clamp((log2(max(v, 1e-10)) - p.toneLo) / (p.toneHi - p.toneLo), 0.0, 1.0);
            v = float3(toneCurve(x.r, p), toneCurve(x.g, p), toneCurve(x.b, p));
            v = outset * v;
            outc = pow(clamp(v, 0.0, 1.0), 2.2);
            float Y2 = luma(outc);
            outc = p.mono != 0 ? float3(Y2) : max(Y2 + (outc - Y2) * p.sat, 0.0);
        }
        // The curves, on the picture (sRGB steps), as in Lightroom.
        if (p.curves != 0) {
            float3 e = select(1.055 * pow(clamp(outc, 0.0, 1.0), 1.0 / 2.4) - 0.055, outc * 12.92, outc <= 0.0031308);
            float3 at = clamp(e, 0.0, 1.0) * 127.0;
            int3 i0 = int3(floor(at)), i1 = min(i0 + 1, 127);
            float3 f = at - float3(i0);
            float3 lo = float3(curve[i0.r].r, curve[i0.g].g, curve[i0.b].b), hi = float3(curve[i1.r].r, curve[i1.g].g, curve[i1.b].b);
            e = mix(lo, hi, f);
            outc = select(pow((e + 0.055) / 1.055, 2.4), e / 12.92, e <= 0.04045);
        }
        return clamp(outc, 0.0, 1.0);
    }

    // A mask's place in the mask layer and what limits it besides its shape.
    struct MaskInfo {
        float4 m0, m1, m2;      // its white balance and exposure, as matrix columns
        float4 lum;             // brightness range: low, high, smooth, on
        float4 col;             // colour range: hue, width, on, invert the whole mask
    };

    // The local tone (shadows, highlights, clarity, texture) as the new log brightness.
    inline float tonedLog(float L, float2 al, float2 as, constant Params &p) {
        // b moves with the exposure the layers were made without: (1 − a)·shift.
        float baseL = al.x * L + al.y + (1.0 - al.x) * p.shift;
        float baseS = as.x * L + as.y + (1.0 - as.x) * p.shift;
        float detail = L - baseS, mid = baseS - baseL;
        // Local tone, on the large base, in stops from mid grey. Highlights compress (or stretch)
        // what's above mid grey, shadows what's below: the curve always keeps rising, so nothing
        // turns over into halos or grey skies, however far it goes.
        float t = baseL - log2(0.18);
        float kh = p.highlights < 0 ? 1.0 + p.highlights * 0.62 : 1.0 + p.highlights * 0.45;
        float ks = p.shadows > 0 ? 1.0 - p.shadows * 0.6 : 1.0 - p.shadows * 0.5;
        float above = t - 0.6, below = t + 0.4;
        float softAbove = above > 8.0 ? above : log(1.0 + exp(above));
        float softBelow = below < -8.0 ? below : -log(1.0 + exp(-below));
        float base = baseL + (kh - 1.0) * softAbove + (ks - 1.0) * softBelow;
        float midWeight = 1.0 - abs(smoothstep(-6.0, 3.0, base - log2(0.18)) * 2.0 - 1.0);
        float clarity = 1.0 + p.clarity * (p.clarity > 0 ? 0.9 : 0.85) * (0.35 + 0.65 * midWeight);
        return base + mid * (clarity + (p.process < 2 ? p.dehaze * 0.6 : 0.0)) + detail * (1.0 + p.texture * 0.9);
    }

    // Version 2, one pixel: dehaze, local tone, then the rest (finish). `t`: how much light gets
    // through the haze there.
    inline float3 developModern(float3 c, float2 al, float2 as, float t, constant Params &p, constant Grade &g, constant float4 *curve) {
        float L = log2(max(luma(c), 1e-5));
        // Dehaze: the haze taken out (or added) in scene light, from how much of the light got
        // through (the dark channel prior); the layers then work on what's left.
        if (p.dehaze != 0) {
            float3 A = float3(p.hazeR, p.hazeG, p.hazeB);
            if (p.dehaze > 0) {
                float through = mix(1.0, max(t, 0.2), p.dehaze * 0.8);
                c = (c - A) / through + A;
            } else {
                // More haze where there's already some (far away), less up close.
                float through = 1.0 + 0.22 * p.dehaze * (1.0 - 0.5 * t);
                c = c * through + A * (1.0 - through);
            }
            float Ld = log2(max(luma(c), 1e-5));
            // The layers' base follows the change, so it isn't undone as detail.
            al.y += (Ld - L) * (1.0 - al.x);
            as.y += (Ld - L) * (1.0 - as.x);
            L = Ld;
        }
        c *= exp2(tonedLog(L, al, as, p) - L);
        return finish(c, p, g, curve);
    }

    kernel void develop(texture2d<float, access::read> image [[texture(0)]],
                        texture2d<float, access::sample> large [[texture(1)]],
                        texture2d<float, access::sample> small [[texture(2)]],
                        texture2d<float, access::sample> haze [[texture(3)]],
                        texture2d<float, access::sample> masks [[texture(4)]],
                        texture2d<float, access::write> dst [[texture(5)]],
                        constant Params *ps [[buffer(0)]],
                        constant int2 *offsets [[buffer(1)]],
                        constant float4 *map [[buffer(2)]],
                        constant Grade *gs [[buffer(3)]],
                        constant float4 *curve [[buffer(4)]],
                        constant MaskInfo *info [[buffer(5)]],
                        uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        constant Params &p = ps[0];
        constexpr sampler smooth(coord::normalized, address::clamp_to_edge, filter::linear);
        float3 c = image.read(at(gid, offsets[0], uint2(image.get_width(), image.get_height()))).rgb;
        // Version 1 had no colours past sRGB; version 2 keeps them until the gamut compression.
        if (p.process < 2) c = max(c, 0.0);
        float Y = max(luma(c), 1e-5);
        float L = log2(Y);
        // Where this pixel is in the photo, then in each small layer's texture.
        float2 pos = float2(map[0].x + float(gid.x) + 0.5, map[0].y - float(gid.y) - 0.5);
        float2 t1 = float2(map[1].x * pos.x + map[1].y, map[1].z * pos.y + map[1].w);
        float2 t2 = float2(map[2].x * pos.x + map[2].y, map[2].z * pos.y + map[2].w);
        float2 uv1 = t1 / float2(large.get_width(), large.get_height()), uv2 = t2 / float2(small.get_width(), small.get_height());
        float2 al = large.sample(smooth, uv1).rg, as = small.sample(smooth, uv2).rg;
        if (p.process >= 2) {
            float2 t3 = float2(map[3].x * pos.x + map[3].y, map[3].z * pos.y + map[3].w);
            float through = haze.sample(smooth, t3 / float2(haze.get_width(), haze.get_height())).r;
            float3 out = developModern(c, al, as, through, p, gs[0], curve);
            // The masks: each one's own settings developed here too, mixed in where it is.
            int count = p.masks;
            if (count > 0) {
                float2 t4 = float2(map[4].x * pos.x + map[4].y, map[4].z * pos.y + map[4].w);
                float4 shape = masks.sample(smooth, t4 / float2(masks.get_width(), masks.get_height()));
                // The ranges look at the photo as developed (its brightness and colour).
                float3 seen = clamp(out, 0.0, 1.0);
                float bright = pow(max(luma(seen), 0.0), 1.0 / 2.2);
                float3 o = oklab(seen);
                float chroma = length(o.yz), hue = atan2(o.z, o.y) * 57.29578;
                if (hue < 0) hue += 360.0;
                float marked = 0;
                for (int k = 0; k < count && k < 4; k++) {
                    constant MaskInfo &m = info[k];
                    float w = shape[k];
                    if (m.lum.w > 0) {
                        w *= smoothstep(m.lum.x - m.lum.z, m.lum.x + 0.001, bright) * (1.0 - smoothstep(m.lum.y - 0.001, m.lum.y + m.lum.z, bright));
                    }
                    if (m.col.z > 0) {
                        float d = abs(hue - m.col.x);
                        if (d > 180) d = 360 - d;
                        w *= (1.0 - smoothstep(m.col.y * 0.5, m.col.y * 0.5 + 18.0, d)) * smoothstep(0.015, 0.05, chroma);
                    }
                    if (m.col.w > 0) w = 1.0 - w;
                    if (k == int(p.overlay)) marked = w;
                    if (w < 0.002) continue;
                    float3 ck = float3x3(m.m0.xyz, m.m1.xyz, m.m2.xyz) * c;
                    out = mix(out, developModern(ck, al, as, through, ps[k + 1], gs[k + 1], curve), w);
                }
                // The mask being edited, shown in red.
                if (p.overlay >= 0) out = mix(out, float3(1.0, 0.12, 0.1), 0.5 * marked);
            }
            dst.write(float4(out, 1.0), gid);
            return;
        }
        float Lp = tonedLog(L, al, as, p);
        c *= exp2(Lp - L);
        if (p.dehaze != 0) {
            float haze = 0.03 * p.dehaze;
            c = max((c - haze * 0.18) / (1.0 - haze), 0.0);
        }

        if (p.scene == 1) { dst.write(float4(min(c, 64.0), 1.0), gid); return; }

        // Contrast (around mid grey) and whites (the brightest stops), in scene light.
        float flat = p.profile == 3 ? 0.78 : 1.0;
        float contrast = flat * (1.0 + p.contrast * (p.contrast > 0 ? 0.55 : 0.45));
        float Yc = max(luma(c), 1e-6);
        float stops = log2(Yc / 0.18);
        float shaped = stops * contrast + p.whites * 1.2 * smoothstep(0.5, 3.5, stops);
        c *= exp2(shaped - stops);

        // The profile: as shot (a finished picture), or the same curve for every camera.
        float3 outc;
        if (p.profile == 5 && p.isRaw == 0) {
            outc = c;
        } else if (p.profile == 1 || p.profile == 2) {
            outc = filmic(c);
        } else {
            outc = agx(c * 1.15);
        }
        // Blacks: lift or deepen the darkest part of the picture.
        float Yo = luma(outc);
        outc += p.blacks * 0.045 * (1.0 - smoothstep(0.0, 0.25, Yo));
        float sat = p.profile == 2 ? 1.2 : p.profile == 3 ? 0.92 : p.profile == 1 ? 1.06 : 1.0;
        float Y2 = luma(outc);
        outc = p.profile == 4 ? float3(Y2) : Y2 + (outc - Y2) * sat;
        dst.write(float4(clamp(outc, 0.0, 1.0), 1.0), gid);
    }
    """#

    /// The compiled passes (once per GPU).
    final class Library: @unchecked Sendable {
        static let shared = Library()
        private var pipelines: [String: MTLComputePipelineState] = [:]
        private var library: MTLLibrary?
        private let lock = NSLock()

        func pipeline(_ name: String, device: MTLDevice) -> MTLComputePipelineState? {
            lock.lock(); defer { lock.unlock() }
            let key = "\(device.registryID)-\(name)"
            if let known = pipelines[key] { return known }
            if library == nil || library?.device.registryID != device.registryID {
                library = try? device.makeLibrary(source: PhotoEngine.shaders, options: nil)
            }
            guard let function = library?.makeFunction(name: name),
                  let state = try? device.makeComputePipelineState(function: function) else { return nil }
            pipelines[key] = state
            return state
        }
    }

    /// One of the passes over `extent`. Core Image is given an extent a hair larger and the result
    /// is cut back: with a whole-pixel extent it asks for a pixel more than it needs at the edges,
    /// and when two such passes end up in one render (two developed photos side by side) it then
    /// reads one pass's result where the other's belongs (macOS 27: the first photo came out
    /// black or smeared). Asked for exactly what's needed, it keeps them apart.
    static func apply(_ kernel: CIImageProcessorKernel.Type, extent: CGRect, inputs: [CIImage]?,
                      arguments: [String: Any]?) throws -> CIImage {
        let padded = CGRect(x: extent.minX, y: extent.minY, width: extent.width + 1 / 256, height: extent.height + 1 / 256)
        return try kernel.apply(withExtent: padded, inputs: inputs, arguments: arguments).cropped(to: extent)
    }

    /// Runs one compute function over the output, with the inputs at the same place.
    /// `offsetsIndex`: where the inputs' offsets go among the buffers (after all the bytes when nil).
    static func run(_ name: String, inputs: [CIImageProcessorInput]?, output: CIImageProcessorOutput, bytes: [Data] = [],
                    offsetsIndex: Int? = nil) throws {
        guard let buffer = output.metalCommandBuffer, let target = output.metalTexture,
              let state = Library.shared.pipeline(name, device: buffer.device),
              let encoder = buffer.makeComputeCommandEncoder() else {
            throw NSError(domain: "Pluck", code: 10, userInfo: [NSLocalizedDescriptionKey: "The GPU isn't available."])
        }
        encoder.setComputePipelineState(state)
        var index = 0
        var uploads: [MTLTexture] = []
        for input in inputs ?? [] {
            if let texture = input.metalTexture {
                encoder.setTexture(texture, index: index)
            } else if let texture = upload(input, device: buffer.device) {
                // Core Image handed this one over in memory (a photo straight from its file).
                uploads.append(texture)
                encoder.setTexture(texture, index: index)
            }
            index += 1
        }
        encoder.setTexture(target, index: index)
        let offsetsAt = offsetsIndex ?? bytes.count
        for (i, data) in bytes.enumerated() {
            data.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: data.count, index: i < offsetsAt ? i : i + 1) }
        }
        // Each input's offset from the output (in the textures' top-down rows).
        var offsets: [SIMD2<Int32>] = (inputs ?? []).map { input in
            SIMD2(Int32(output.region.minX.rounded(.down) - input.region.minX.rounded(.down)),
                  Int32(input.region.maxY.rounded(.up) - output.region.maxY.rounded(.up)))
        }
        if offsets.isEmpty { offsets = [.zero] }
        encoder.setBytes(&offsets, length: MemoryLayout<SIMD2<Int32>>.stride * offsets.count, index: offsetsAt)
        let width = state.threadExecutionWidth, height = max(state.maxTotalThreadsPerThreadgroup / width, 1)
        encoder.dispatchThreads(MTLSize(width: target.width, height: target.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
        encoder.endEncoding()
        _ = uploads
    }

    private static func upload(_ input: CIImageProcessorInput, device: MTLDevice) -> MTLTexture? {
        let format: MTLPixelFormat
        switch input.format {
        case .RGBAh: format = .rgba16Float
        case .RGBAf: format = .rgba32Float
        default: return nil
        }
        let width = Int(input.region.width), height = Int(input.region.height)
        guard width > 0, height > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: input.baseAddress, bytesPerRow: input.bytesPerRow)
        return texture
    }
}

/// The local-tone layers of the photos being edited, worked out once (a few megabytes each).
final class GuideCache: @unchecked Sendable {
    static let shared = GuideCache()
    private var layers: [String: PhotoEngine.Layers] = [:]
    private var order: [String] = []
    private let lock = NSLock()

    func layers(_ key: String, make: () -> PhotoEngine.Layers) -> PhotoEngine.Layers {
        lock.lock()
        if let known = layers[key] {
            order.removeAll { $0 == key }
            order.append(key)
            lock.unlock()
            return known
        }
        lock.unlock()
        let made = make()
        let kept = PhotoEngine.Layers(large: render(made.large), small: render(made.small),
                                      haze: made.haze.map { (render($0.through), $0.airlight) })
        lock.lock()
        layers[key] = kept
        order.append(key)
        if order.count > 12 { layers[order.removeFirst()] = nil }
        lock.unlock()
        return kept
    }

    func removeAll() {
        lock.lock(); layers = [:]; order = []; lock.unlock()
    }

    /// Rendered now and kept as floats (the same place and size).
    private func render(_ image: CIImage) -> CIImage {
        let extent = image.extent.integral
        guard let made = PhotoEngine.context.createCGImage(image, from: extent, format: .RGBAf,
                                                           colorSpace: nil) else { return image }
        return CIImage(cgImage: made, options: [.colorSpace: NSNull()]).transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }
}

/// log brightness and its square.
final class GuidePrep: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAf }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect { outputRect }
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        try PhotoEngine.run("guidePrep", inputs: inputs, output: output)
    }
}

/// The guided filter's coefficients.
final class GuideCoef: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAf }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect { outputRect }
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        try PhotoEngine.run("guideCoef", inputs: inputs, output: output, bytes: [(arguments?["eps"] as? Data) ?? Data()])
    }
}

/// Local tone and the profile.
final class DevelopPass: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAh }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }
    /// The photo where the output is; the two small layers whole.
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        // (As numbers: Core Image moves rectangles it finds among the arguments.)
        guard input > 0, let sizes = arguments?["layers"] as? [Double], sizes.count == 20 else { return outputRect }
        let i = Int(input - 1) * 4
        return CGRect(x: sizes[i], y: sizes[i + 1], width: sizes[i + 2], height: sizes[i + 3])
    }
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        // Where each pixel falls in the two layers' textures: texel = (sx·x + bx, sy·y + by) from
        // the photo's coordinates (y up) to the textures' (y down, from the piece handed over).
        guard let inputs, inputs.count == 5, let sizes = arguments?["layers"] as? [Double], sizes.count == 20 else {
            throw NSError(domain: "Pluck", code: 11)
        }
        let photo = CGRect(x: sizes[16], y: sizes[17], width: sizes[18], height: sizes[19])
        var map = [SIMD4<Float>(Float(output.region.minX), Float(output.region.maxY), 0, 0)]
        for layer in 0..<4 {
            let extent = CGRect(x: sizes[layer * 4], y: sizes[layer * 4 + 1], width: sizes[layer * 4 + 2], height: sizes[layer * 4 + 3])
            let region = inputs[layer + 1].region
            let sx = extent.width / photo.width, sy = extent.height / photo.height
            map.append(SIMD4(Float(sx), Float(extent.minX - photo.minX * sx - region.minX),
                             Float(-sy), Float(region.maxY - extent.minY + photo.minY * sy)))
        }
        let bytes = map.withUnsafeBytes { Data($0) }
        try PhotoEngine.run("develop", inputs: inputs, output: output,
                            bytes: [(arguments?["params"] as? Data) ?? Data(), bytes, (arguments?["grade"] as? Data) ?? Data(),
                                    (arguments?["curves"] as? Data) ?? Data(count: 16), (arguments?["masks"] as? Data) ?? Data(count: 96)],
                            offsetsIndex: 1)
    }
}

// MARK: - Histogram and Auto

extension PhotoEngine {
    /// Red, green and blue counts in 64 steps, from a developed image, on the GPU (as the
    /// screen shows it: in sRGB steps, from a small copy).
    static func histogram(_ image: CIImage) -> [[Float]] {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, !extent.isInfinite else { return [] }
        let scale = min(1, 512 / max(extent.width, extent.height))
        let small = image.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": scale, "inputAspectRatio": 1])
            .applyingFilter("CILinearToSRGBToneCurve")
        let counted = small.applyingFilter("CIAreaHistogram", parameters: [kCIInputExtentKey: CIVector(cgRect: small.extent.integral),
                                                                          "inputCount": 64, "inputScale": 1])
        var values = [Float](repeating: 0, count: 64 * 4)
        context.render(counted, toBitmap: &values, rowBytes: 64 * 16, bounds: CGRect(x: 0, y: 0, width: 64, height: 1),
                       format: .RGBAf, colorSpace: nil)
        var bins = [[Float]](repeating: [Float](repeating: 0, count: 64), count: 3)
        for i in 0..<64 { for c in 0..<3 { bins[c][i] = values[i * 4 + c] } }
        let top = max(bins.flatMap { $0.dropFirst().dropLast() }.max() ?? 1, 1e-9)
        return bins.map { $0.map { min($0 / top, 1) } }
    }

    /// The developed picture with what's clipped marked, as Lightroom's J: highlights at white in
    /// any channel red, shadows at black in all of them blue.
    static func clipping(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let brightest = image.applyingFilter("CIMaximumComponent")
        let highlights = brightest.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.997])
        let shadows = brightest.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.0004]).applyingFilter("CIColorInvert")
        let red = CIImage(color: CIColor(red: 1, green: 0.1, blue: 0.1)).cropped(to: extent)
        let blue = CIImage(color: CIColor(red: 0.15, green: 0.35, blue: 1)).cropped(to: extent)
        return blue.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: red.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: highlights]),
            kCIInputMaskImageKey: shadows,
        ]).cropped(to: extent)
    }

    /// The photo in scene light at this white balance (no exposure): for measuring it.
    static func balanced(_ image: CIImage, _ a: PhotoAdjustments, kelvin: Double) -> CIImage {
        linear(image, whiteBalance(a, kelvin: kelvin), wide: a.process >= 2)
    }

    /// Auto (version 2), from the photo's light itself (scene-linear brightness, not a finished
    /// picture): exposure puts the middle at mid grey, faces counting most; Highlights and
    /// Whites follow the brightest stops, Shadows and Blacks the darkest.
    /// `faces`: where faces are, as shares of the photo (from the bottom left).
    static func auto(luminance: [Float], width: Int, height: Int, faces: [CGRect]) -> PhotoAdjustments {
        var a = PhotoAdjustments()
        guard let middle = middle(luminance: luminance, width: width, height: height, faces: faces) else { return a }
        var plain = luminance.filter { $0 > 1e-6 && $0.isFinite }.map { log2($0 / 0.18) }
        plain.sort()
        func at(_ share: Double) -> Double { Double(plain[min(Int(Double(plain.count - 1) * share), plain.count - 1)]) }
        a.exposure = (min(max(-middle, -3), 3) * 20).rounded() / 20
        let top = at(0.995) + a.exposure, shade = at(0.05) + a.exposure, floor = at(0.005) + a.exposure
        if top > 3 { a.highlights = -min((top - 3) * 35, 100).rounded() }
        if top < 1.5 { a.whites = min((1.5 - top) * 30, 60).rounded() }
        if shade < -4 { a.shadows = min((-4 - shade) * 22, 80).rounded() }
        if floor > -5 { a.blacks = -min((floor + 5) * 15, 40).rounded() }
        a.vibrance = 10
        return a
    }

    /// The middle of the photo's light (stops from mid grey), each face's pixels counting eight
    /// times; nil for a black photo.
    static func middle(luminance: [Float], width: Int, height: Int, faces: [CGRect]) -> Double? {
        var weighted: [(Float, Float)] = []
        weighted.reserveCapacity(luminance.count)
        for y in 0..<height {
            for x in 0..<width {
                let v = luminance[y * width + x]
                guard v > 1e-6, v.isFinite else { continue }
                let point = CGPoint(x: (Double(x) + 0.5) / Double(width), y: 1 - (Double(y) + 0.5) / Double(height))
                weighted.append((log2(v / 0.18), faces.contains { $0.contains(point) } ? 8 : 1))
            }
        }
        guard !weighted.isEmpty else { return nil }
        weighted.sort { $0.0 < $1.0 }
        let total = weighted.reduce(0) { $0 + $1.1 }
        var running: Float = 0
        for (ev, w) in weighted { running += w; if running >= total / 2 { return Double(ev) } }
        return Double(weighted.last!.0)
    }

    /// Lightroom's Auto: exposure for a pleasing middle, highlights and whites to keep the
    /// brightest parts, shadows and blacks for the darkest, from the photo as developed plain.
    static func auto(_ image: CGImage) -> PhotoAdjustments {
        let width = 128, height = max(1, Int(Double(image.height) * 128 / Double(max(image.width, 1))))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return PhotoAdjustments() }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var lumas: [Double] = []
        lumas.reserveCapacity(width * height)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            lumas.append((0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])) / 255)
        }
        lumas.sort()
        func at(_ share: Double) -> Double { lumas[min(Int(Double(lumas.count - 1) * share), lumas.count - 1)] }
        let median = at(0.5), bright = at(0.98), dark = at(0.02)
        var a = PhotoAdjustments()
        // A middle near 0.45 (encoded), in stops.
        a.exposure = (min(max(log2(DevelopLUT.decode(0.45) / max(DevelopLUT.decode(median), 0.002)), -2.5), 2.5) * 20).rounded() / 20
        let brightAfter = min(bright * pow(2, a.exposure / 2.2), 1.2)
        if brightAfter > 0.93 { a.highlights = -min((brightAfter - 0.85) * 500, 80).rounded() }
        if dark < 0.08 { a.shadows = min((0.08 - dark) * 600, 60).rounded() }
        if brightAfter < 0.85 { a.whites = min((0.9 - brightAfter) * 150, 40).rounded() }
        if dark > 0.12 { a.blacks = -min((dark - 0.1) * 200, 40).rounded() }
        a.vibrance = 12
        return a
    }
}
