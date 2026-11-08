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
        /// `adobe` (shown as Classic): Neutral with Adobe's default tone curve on top (see adobeBase), for RAW photos whose
        /// Lightroom edit or preset starts from an Adobe profile; on other photos it's As Shot.
        /// Version 3's own (ColourProfiles): Accurate, Landscape and Portrait; earlier versions show them as Neutral.
        /// (New ones only ever at the end: the shaders know the others by their place.)
        case neutral, standard, vivid, flat, monochrome, asShot, adobe, accurate, landscape, portrait
        var id: String { rawValue }
        /// The profile a photo starts from (`a.profile` nil): Standard for RAW from process 5 (natural colour, Apple's default
        /// as the anchor); Classic for RAW in 3 and 4, as Lightroom starts from Adobe Color; Neutral for RAW before; As Shot
        /// for other photos. (A Lightroom edit naming an Adobe profile stores Classic, so it stays on Adobe's curve.)
        static func starting(_ a: PhotoAdjustments, isRaw: Bool) -> Profile {
            a.profile ?? (isRaw ? (a.process >= 5 ? .standard : a.process >= 3 ? .adobe : .neutral) : .asShot)
        }
        var title: String {
            switch self {
            case .neutral: String(localized: "Neutral")
            case .standard: String(localized: "Standard")
            case .vivid: String(localized: "Vivid")
            case .flat: String(localized: "Flat")
            case .monochrome: String(localized: "Monochrome")
            case .asShot: String(localized: "As Shot")
            case .adobe: String(localized: "Classic")
            case .accurate: String(localized: "Accurate")
            case .landscape: String(localized: "Landscape")
            case .portrait: String(localized: "Portrait")
            }
        }
        /// Version 3's own profiles (ColourProfiles).
        var isNew: Bool { [.accurate, .landscape, .portrait].contains(self) }
        /// The profiles to choose from: RAW has Classic, other photos As Shot; version 3 has its own instead of Flat (still
        /// shown while chosen); earlier versions don't have version 3's. Standard is in every version's list (process 5 has
        /// its own: `isStandard5`; before, the earlier one, unchanged).
        static func choices(raw: Bool, process: Int, chosen: Profile?) -> [Profile] {
            allCases.filter { p in
                (raw ? p != .asShot : p != .adobe)
                    && (process >= 3 ? p != .flat || p == chosen : !p.isNew || p == chosen)
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
    /// `baseline`: the camera's baseline exposure (RAW), added from version 3 on top of the decoder's, as Lightroom's
    /// brightness sits that much higher (measured: Lightroom's numbers then give about the same picture).
    static func develop(_ image: CIImage, _ a: PhotoAdjustments, isRaw: Bool, asShotKelvin: Double = 5500, scene: Bool = false,
                        cacheKey: String? = nil, masks: CIImage? = nil, overlay: Int? = nil, peak: Double = 1, baseline: Double = 0) -> CIImage {
        let extent = image.extent
        let modern = a.process >= 2
        let profile = Profile.starting(a, isRaw: isRaw)
        let shown = profile == .asShot && isRaw ? .standard : profile == .adobe && !isRaw ? .asShot : profile.isNew && a.process < 3 ? .neutral : profile
        // Process 5: a finished picture (JPEG, HEIC) keeps its own tone whatever the profile (`picture5`: only the profile's
        // colour and look, see pictureTone); RAW's Neutral sits at Classic's mid grey (`neutralLift5`).
        let v5 = a.process >= 5, picture5 = v5 && !isRaw
        // 1. Exposure and white balance: one matrix in linear light.
        let stops = a.exposure + (a.process >= 3 && isRaw ? baseline : 0) + (v5 && isRaw && !scene && shown == .neutral ? neutralLift5 : 0)
        let gain = pow(2, stops)
        // (Calibration first: it moves the camera's primaries, as Lightroom's does.)
        let ownBalance = whiteBalance(a, kelvin: asShotKelvin)
        let balance = a.calibration.isDefault ? ownBalance : multiply(ownBalance, calibration(a.calibration, proPhoto: a.process >= 3))
        let exposed = linear(image, balance.map { $0 * gain }, wide: modern)
        // 2–3. Local tone and the profile, in one pass, from two base layers (and the haze, when
        // it's taken out).
        let long = max(extent.width, extent.height)
        let local = modern && masks != nil ? Array(a.masks.prefix(PhotoMasks.limit)) : []
        let hazy = modern && (a.dehaze != 0 || local.contains { $0.dehaze != 0 })
        // (Process 5's Clarity works on the large layer; its soft layer is Glow's light instead, see glowLight.)
        let soft = modern && !v5 && (a.clarity != 0 || local.contains { $0.clarity != 0 })
        let glowOn = v5 && !scene && a.glow > 0
        let clear = v5 && (a.clarity != 0 || local.contains { $0.clarity != 0 })
        let layers: Layers
        var shift: Float = 0
        func make(_ source: CIImage) -> Layers {
            Layers(large: guide(source, scale: 640 / long, radius: 16, eps: 0.03), small: guide(source, scale: 1600 / long, radius: 6, eps: 0.02),
                   haze: hazy ? haze(source, long: long, v5: v5) : nil, glow: soft ? glow(source, long: long) : nil,
                   clarity: clear ? guide(source, scale: 640 / long, radius: 16, eps: 0.3) : nil)
        }
        if let cacheKey {
            let key = cacheKey + "|\(a.process)|\(hazy)|\(soft)|\(clear)|" + balance.map { String(format: "%.4f", $0) }.joined(separator: ",")
            layers = GuideCache.shared.layers(key) { make(linear(image, balance, wide: modern)) }
            shift = Float(stops)
        } else {
            layers = make(exposed)
        }
        // (Version 3: every profile but Neutral, Standard and Flat on Adobe's curve, at Classic's mid grey; process 5's Standard too.)
        let base = modern && !picture5 && (shown == .adobe || a.process >= 3 && [.accurate, .vivid, .landscape, .portrait, .monochrome].contains(shown)
                              || a.process >= 5 && shown == .standard)
        // Process 5's Texture keeps out the photo's noise: its noise at each brightness (PhotoRender.noiseModel).
        let noise = v5 && (a.texture > 0 || local.contains { $0.texture > 0 }) ? PhotoRender.noiseModel(image, key: cacheKey) : nil
        let table = a.process >= 3 ? ColourProfiles.table(shown, isRaw: isRaw, v4: a.process >= 4 && !picture5, v5: v5 && isRaw) : nil
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
            p.shadowTint = Float(a.calibration.shadowTint / 100)
            p.space = a.process >= 3 ? 1 : 0
            // (Process 4's Highlights window is for RAW: on 5 a finished picture doesn't get it.)
            p.v4 = a.process >= 4 && !picture5 ? 1 : 0
            p.v5 = v5 ? 1 : 0
            p.hueSat = table == nil ? 0 : 1
            // Process 4 with film: the profile's colour (its table, Monochrome's grey) goes into the film's light, its tone
            // doesn't (the film's own curves do that); Accurate's light is the film's as before (2: table, 3: grey).
            // (Not earlier processes: their film edits keep their look.)
            if scene, a.process >= 4 { p.hueSat = shown == .monochrome ? 3 : shown == .accurate || table == nil ? 0 : 2 }
            if modern {
                tone(a, profile: shown, into: &p, peak: peak)
                // (Accurate's own way through the tone curve is for RAW.)
                if picture5, p.tro == 1 { p.tro = 0 }
                let c = a.curves
                // (Version 3: one curve for all three goes through RGBTone, keeping the hue.)
                p.curves = c.tonesDefault && !base ? 0 : a.process >= 3 && [c.red, c.green, c.blue].allSatisfy { $0 == PhotoCurves.straight } ? 2 : 1
                if let airlight = layers.haze?.airlight {
                    // The haze's colour, at this exposure.
                    let k = Float(cacheKey == nil ? 1 : gain)
                    p.hazeR = airlight.x * k; p.hazeG = airlight.y * k; p.hazeB = airlight.z * k
                }
                p.glowGain = Float(cacheKey == nil || glowOn ? 1 : gain)
            }
            if glowOn { p.glow = Float(a.glow / 100); p.glowMode = Int32(PhotoAdjustments.GlowMode.allCases.firstIndex(of: a.glowMode) ?? 1) }
            if let noise { p.noiseA = Float(noise.a); p.noiseB = Float(noise.b); p.noiseGain = Float(gain) }
            return p
        }
        var p = params(a, shift: shift)
        p.masks = Int32(local.count)
        p.overlay = Float(overlay.map { $0 < local.count ? $0 : -1 } ?? -1)
        var all = [p], grades = [Grade(a, scene: scene, isRaw: isRaw)], infos: [MaskInfo] = []
        // Each mask: the photo's settings with the mask's changes, and its own white balance
        // and exposure as a matrix on top of the photo's.
        for mask in local {
            var m = a
            let k = mask.amount
            func add(_ path: WritableKeyPath<PhotoAdjustments, Double>, _ amount: Double) { m[keyPath: path] = min(max(m[keyPath: path] + amount * k, -100), 100) }
            add(\.contrast, mask.contrast); add(\.highlights, mask.highlights); add(\.shadows, mask.shadows)
            add(\.saturation, mask.saturation); add(\.clarity, mask.clarity); add(\.texture, mask.texture); add(\.dehaze, mask.dehaze)
            add(\.temperature, mask.warmth); add(\.tint, mask.tint)
            let change = multiply(whiteBalance(m, kelvin: asShotKelvin), inverse(ownBalance)).map { $0 * pow(2, mask.exposure * k) }
            var own = params(m, shift: shift + Float(mask.exposure * k))
            // The haze's colour as the mask sees it (its exposure and white balance too).
            let h = [Double(own.hazeR), Double(own.hazeG), Double(own.hazeB)]
            own.hazeR = Float(change[0] * h[0] + change[1] * h[1] + change[2] * h[2])
            own.hazeG = Float(change[3] * h[0] + change[4] * h[1] + change[5] * h[2])
            own.hazeB = Float(change[6] * h[0] + change[7] * h[1] + change[8] * h[2])
            all.append(own)
            grades.append(Grade(m, scene: scene, isRaw: isRaw))
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
        let glowLayer = glowOn ? glowLight(exposed, long: long, isRaw: isRaw && !picture5, size: a.glowSize, key: cacheKey.map { key in
            key + "|" + balance.map { String(format: "%.4f", $0) }.joined(separator: ",") + String(format: "|%.4f|%.1f", stops, a.glowSize) }) : layers.glow ?? dot
        let clarityLayer = layers.clarity ?? dot
        // (Process 5 has its own kernel, with Clarity's layer as one more input.)
        let inputs = [exposed.clampedToExtent(), layers.large, layers.small, hazeLayer, maskLayer, glowLayer] + (v5 ? [clarityLayer] : [])
        var rects: [CGRect] = [layers.large.extent, layers.small.extent, hazeLayer.extent, maskLayer.extent, glowLayer.extent]
        if v5 { rects.append(clarityLayer.extent) }
        rects.append(extent)
        let data = all.withUnsafeBytes { Data($0) }
        let grade = grades.withUnsafeBytes { Data($0) }
        let info = infos.withUnsafeBytes { Data($0) }
        let curves = modern && (!a.curves.tonesDefault || base)
            ? curveTable(a.curves, base: base ? (a.process >= 4 ? adobeBaseV4 : a.process >= 3 ? adobeBaseV3 : adobeBase) : nil) : Data(count: 16)
        // (Process 5's colour curves and points; an overlay under −1 is a point shown in red, see colourTools.)
        let tools = v5 && !scene ? colourTools(a, shown: overlay.map { -2 - $0 }) : nil
        guard let developed = try? apply(DevelopPass.self, extent: extent, inputs: inputs, arguments: [
            "params": data, "grade": grade, "curves": curves, "masks": info, "table": table ?? Data(count: 16),
            "layers": rects.flatMap { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] },
            "tools": tools ?? Data(count: 16),
        ]) else { return exposed }
        return developed
    }

    /// Process 5's colour curves and colour points for the GPU (`colourTools5`), nil when they change nothing: [0] what's on
    /// (curves, the number of points, the point shown in red or −1, 1); [1…256] by hue, Hue vs Hue (degrees), Hue vs Sat
    /// (×), Hue vs Lum (stops), and Lum vs Sat (×) by lightness; [257…512] Sat vs Sat (×) by C/L; then two per point
    /// (its hue, C/L, L and Range 0…1; its hue turn in degrees, saturation ×−1…+1, stops). `shown`: the point marked.
    /// With the Colour Warper ([0].w 2): from [529] its turn and saturation × by hue (every 5°) × C/L (0…satAxis, 16 steps).
    static func colourTools(_ a: PhotoAdjustments, shown: Int? = nil) -> Data? {
        let curves = a.curves.hue.flatMap { $0.isDefault ? nil : $0 }
        let warp = a.curves.warp.flatMap { $0.isDefault ? nil : $0 }
        let points = (a.mixer.points ?? []).prefix(ColourPoint.limit)
        let marked = shown.flatMap { $0 >= 0 && $0 < points.count ? $0 : nil }
        guard curves != nil || warp != nil || points.contains(where: \.changes) || marked != nil else { return nil }
        var t = [SIMD4<Float>](repeating: SIMD4(0, 0, 0, 0), count: 513)
        t[0] = SIMD4(curves == nil ? 0 : 1, Float(points.count), Float(marked ?? -1), warp == nil ? 1 : 2)
        if let curves {
            for i in 0..<256 {
                let x = Double(i) / 255
                t[1 + i] = SIMD4(Float((curves.value(.hueHue, at: x) - 0.5) * 2 * hueCurveTurn), Float(curves.value(.hueSat, at: x) * 2),
                                 Float((curves.value(.hueLum, at: x) - 0.5) * 2), Float(curves.value(.lumSat, at: x) * 2))
                t[257 + i] = SIMD4(Float(curves.value(.satSat, at: x) * 2), 0, 0, 0)
            }
        }
        for p in points {
            t.append(SIMD4(Float(p.hue), Float(p.sat), Float(p.lum), Float(min(max(p.range, 0), 100) / 100)))
            t.append(SIMD4(Float(p.hueShift / 100 * pointTurn), Float(p.saturation / 100), Float(p.luminance / 100), 0))
        }
        if let warp {
            t += [SIMD4<Float>](repeating: SIMD4(0, 0, 0, 0), count: 529 - t.count)
            t += warp.table(hueSteps: 72, satSteps: 16, top: satAxis).map { SIMD4(Float($0.turn), Float($0.scale), 0, 0) }
        }
        return t.withUnsafeBytes { Data($0) }
    }
    /// Hue vs Hue's turn at the top (and bottom) of its curve, and a colour point's at Hue ±100, in degrees.
    static let hueCurveTurn = 60.0, pointTurn = 30.0
    /// The colour tools' saturation axis: C/L from 0 to this (a pure sRGB red is about 0.41, its blue 0.69).
    static let satAxis = 0.6

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
        /// A soft copy of the photo (version 2's clarity and mist).
        var glow: CIImage?
        /// Process 5's Clarity base: the guided filter on log brightness with a wide eps (0.3 stop²), so only real edges stay.
        var clarity: CIImage? = nil
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

    /// A soft copy of the photo, small (blurred over about 2% of its size): clarity's reference and
    /// the mist's light. Its edges carried on, so they aren't mixed with nothing.
    private static func glow(_ image: CIImage, long: Double) -> CIImage {
        let s = min(480 / long, 1)
        let frame = image.extent.applying(CGAffineTransform(scaleX: s, y: s)).integral
        let carried = image.clampedToExtent().cropped(to: image.extent.insetBy(dx: -40 / s, dy: -40 / s))
        let small = s < 0.5 ? carried.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": s, "inputAspectRatio": 1])
                            : carried.transformed(by: CGAffineTransform(scaleX: s, y: s))
        return small.applyingGaussianBlur(sigma: 0.02 * max(frame.width, frame.height)).cropped(to: frame)
    }

    /// Process 5's Glow light: the light over a soft knee (from a stop over mid grey, all of it 2 stops further up; a finished
    /// picture's half a stop lower), with its own colour, spread smooth and wide (a blur and one 3 times wider, half each;
    /// `size` 50: 2 % of the photo, 0 a quarter of that, 100 four times). Small (480 px), kept for the last settings.
    static func glowLight(_ image: CIImage, long: Double, isRaw: Bool, size: Double, key: String?) -> CIImage {
        glowLock.lock()
        if let key, let last = lastGlow, last.key == key { glowLock.unlock(); return last.image }
        glowLock.unlock()
        let s = min(480 / long, 1)
        let frame = image.extent.applying(CGAffineTransform(scaleX: s, y: s)).integral
        let sigma = 0.02 * pow(2, (size - 50) / 25) * max(frame.width, frame.height)
        let carried = image.clampedToExtent().cropped(to: image.extent.insetBy(dx: -3 * sigma / s, dy: -3 * sigma / s))
        let small = s < 0.5 ? carried.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": s, "inputAspectRatio": 1])
                            : carried.transformed(by: CGAffineTransform(scaleX: s, y: s))
        guard let knee = glowKernels.knee.apply(extent: small.extent, arguments: [small, isRaw ? 0.72 : 0.5]) else { return image }
        let near = knee.clampedToExtent().applyingGaussianBlur(sigma: sigma), far = knee.clampedToExtent().applyingGaussianBlur(sigma: 3 * sigma)
        guard let light = glowKernels.half.apply(extent: frame, arguments: [near, far]) else { return image }
        let kept = GuideCache.shared.render(light)
        if let key { glowLock.lock(); lastGlow = (key, kept); glowLock.unlock() }
        return kept
    }
    nonisolated(unsafe) private static var lastGlow: (key: String, image: CIImage)?
    private static let glowLock = NSLock()
    private static let glowKernels = (
        knee: CIColorKernel(source: """
            kernel vec4 knee(__sample c, float thr) {
                float Y = dot(c.rgb, vec3(0.2126, 0.7152, 0.0722));
                float t = clamp((log2(max(Y, 1e-6) / thr) + 1.0) * 0.5, 0.0, 1.0);
                return vec4(max(c.rgb, 0.0) * t * t * (3.0 - 2.0 * t), 1.0);
            }
            """)!,
        half: CIColorKernel(source: "kernel vec4 halves(__sample a, __sample b) { return vec4(0.5 * (a.rgb + b.rgb), 1.0); }")!
    )

    /// The haze, worked out small (He et al.'s dark channel prior): its colour is the brightest
    /// of the softened photo; how much light gets through is one minus the darkest channel
    /// around each place (relative to that colour), smoothed along the photo's edges.
    /// Process 5 (`v5`): finer (1024 px, a smaller minimum), lamps left out of the haze's colour (anything over twice the
    /// 99th percentile of brightness), that colour half as colourful and at most C/L 0.1 (OkLab), and the map smoothed along
    /// edges in log brightness, so dark trees beside a bright sky keep their own (no dark band along the skyline).
    private static func haze(_ image: CIImage, long: Double, v5: Bool = false) -> (through: CIImage, airlight: SIMD3<Float>) {
        let s = min((v5 ? 1024 : 640) / long, 1)
        // The edges carried on before it's made small, so the edge pixels aren't mixed with
        // nothing (which reads as haze there).
        let frame = image.extent.applying(CGAffineTransform(scaleX: s, y: s)).integral
        let carried = image.clampedToExtent().cropped(to: image.extent.insetBy(dx: -16 / s, dy: -16 / s))
        let small = (s < 0.5 ? carried.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": s, "inputAspectRatio": 1])
                             : carried.transformed(by: CGAffineTransform(scaleX: s, y: s))).cropped(to: frame)
        let extent = small.extent
        // The haze's colour: the average of the haziest 0.1% (where the darkest channel is
        // brightest), from a softened copy so single bright lights don't count.
        let soft = small.clampedToExtent().applyingGaussianBlur(sigma: v5 ? 2 : 3).cropped(to: extent)
        let w = Int(extent.width), h = Int(extent.height)
        var pixels = [Float](repeating: 0, count: max(w * h * 4, 4))
        context.render(soft, toBitmap: &pixels, rowBytes: w * 16, bounds: extent, format: .RGBAf, colorSpace: nil)
        // The cut-off for the haziest share from a histogram of the darkest channel (no sorting).
        let n = w * h
        var darkest = [Float](repeating: 0, count: n)
        var top: Float = 1e-6
        for i in 0..<n { darkest[i] = min(pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2]); top = max(top, darkest[i]) }
        if v5 {
            // (Lamps out: what's brighter than twice the 99th percentile of brightness doesn't count.)
            let lumas = (0..<n).map { 0.2126 * pixels[$0 * 4] + 0.7152 * pixels[$0 * 4 + 1] + 0.0722 * pixels[$0 * 4 + 2] }
            let limit = 2 * lumas.sorted()[min(n * 99 / 100, n - 1)]
            top = 1e-6
            for i in 0..<n { if lumas[i] > limit { darkest[i] = -1 } else { top = max(top, darkest[i]) } }
        }
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
        var airlight = simd_max(sum / max(count, 1), SIMD3(repeating: 0.05))
        if v5 {
            // Neutral-ish: half its colour, at most C/L 0.1.
            let (L, a, b) = OkLab.from(Double(airlight.x), Double(airlight.y), Double(airlight.z))
            let C = (a * a + b * b).squareRoot(), k = 0.5 * min(1, 0.2 * L / max(C, 1e-9))
            let (r, g, bl) = OkLab.to(L, a * k, b * k)
            airlight = simd_max(SIMD3(Float(r), Float(g), Float(bl)), SIMD3(repeating: 0.02))
        }
        let dark = small.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(1 / airlight.x), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(1 / airlight.y), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(1 / airlight.z), w: 0),
        ]).applyingFilter("CIMinimumComponent").clampedToExtent().applyingFilter("CIMorphologyMinimum", parameters: ["inputRadius": v5 ? 2 : 4]).cropped(to: extent)
        let omega: CGFloat = v5 ? 0.9 : 0.95
        let through = dark.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: -omega, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: -omega, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: -omega, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
        ])
        // Both carried on a little past the edges, or the filter reads nothing there (not
        // endlessly: the passes before it can't be asked for an endless picture).
        let margin = extent.insetBy(dx: -24, dy: -24)
        if v5, let logs = try? apply(GuidePrep.self, extent: extent, inputs: [small.clampedToExtent()], arguments: [:]) {
            // (The guide: log2 brightness / 16 as a grey, so its edges count the same in the shade as in the sky.)
            let k: CGFloat = 1 / 16
            let guideImage = logs.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: k, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
            ]).clampedToExtent().cropped(to: margin)
            let refined = through.clampedToExtent().cropped(to: margin)
                .applyingFilter("CIGuidedFilter", parameters: ["inputGuideImage": guideImage, "inputRadius": 8, "inputEpsilon": 0.0001])
                .cropped(to: extent)
            return (refined, airlight)
        }
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
        let s = lms(chromaticity(kelvin: from, tint: 0), cone), t = lms(chromaticity(kelvin: to, tint: a.tint, lightroom: a.process >= 3), cone)
        let d = [s[0] / t[0], s[1] / t[1], s[2] / t[2]]
        // XYZ → sRGB · cone⁻¹ · diag · cone · sRGB → XYZ
        let toXYZ = [0.4124, 0.3576, 0.1805, 0.2126, 0.7152, 0.0722, 0.0193, 0.1192, 0.9505]
        let fromXYZ = [3.2406, -1.5372, -0.4986, -0.9689, 1.8758, 0.0415, 0.0557, -0.2040, 1.0570]
        let diag = [d[0], 0, 0, 0, d[1], 0, 0, 0, d[2]]
        return multiply(fromXYZ, multiply(inverse(cone), multiply(diag, multiply(cone, toXYZ))))
    }

    /// Calibration as a matrix in linear sRGB: each primary's chromaticity (xy) turned about white
    /// and moved nearer to or further from it, then the matrix made again from the new primaries
    /// so white stays white (as an RGB→XYZ matrix is made from its primaries and white point).
    // Hue ±100 turns a primary ±35° (+ towards the next primary: red to yellow, green to cyan, blue to purple); Saturation ±100 is 0.5×…1.5× its distance from white.
    /// `proPhoto` (version 3): ProPhoto's primaries about D50, as Adobe's calibration moves a wide space's primaries,
    /// given back for linear sRGB.
    static func calibration(_ c: Calibration, proPhoto: Bool = false) -> [Double] {
        let white = proPhoto ? (0.3457, 0.3585) : (0.3127, 0.3290)
        let primaries = proPhoto ? [(0.7347, 0.2653), (0.1596, 0.8404), (0.0366, 0.0001)] : [(0.64, 0.33), (0.30, 0.60), (0.15, 0.06)]
        let moves = [(c.redHue, c.redSaturation), (c.greenHue, c.greenSaturation), (c.blueHue, c.blueSaturation)]
        func toXYZ(_ xy: [(Double, Double)]) -> [Double] {
            // Columns: each primary's XYZ (Y 1), then scaled so the three add up to white.
            let p = [0, 1, 2].map { i in [xy[i].0 / xy[i].1, 1, (1 - xy[i].0 - xy[i].1) / xy[i].1] }
            let m = [p[0][0], p[1][0], p[2][0], p[0][1], p[1][1], p[2][1], p[0][2], p[1][2], p[2][2]]
            let w = [white.0 / white.1, 1, (1 - white.0 - white.1) / white.1], inv = inverse(m)
            let s = [0, 1, 2].map { r in inv[r * 3] * w[0] + inv[r * 3 + 1] * w[1] + inv[r * 3 + 2] * w[2] }
            return [0, 1, 2].flatMap { r in [0, 1, 2].map { col in m[r * 3 + col] * s[col] } }
        }
        let moved = zip(primaries, moves).map { xy, move -> (Double, Double) in
            let dx = xy.0 - white.0, dy = xy.1 - white.1
            let angle = atan2(dy, dx) + move.0 / 100 * 35 * .pi / 180, reach = hypot(dx, dy) * (1 + move.1 / 100 * 0.5)
            return (white.0 + reach * cos(angle), white.1 + reach * sin(angle))
        }
        let m = multiply(inverse(toXYZ(primaries)), toXYZ(moved))
        return proPhoto ? multiply(fromProPhoto, multiply(m, toProPhoto)) : m
    }

    /// Linear sRGB (D65) to linear ProPhoto (ROMM primaries, D50, Bradford-adapted as the DNG SDK's PCS: LookTable.toPCS)
    /// and back, row by row. Version 3's working space; grey stays grey.
    static let toProPhoto = [0.5292993, 0.3300508, 0.1406499, 0.0984129, 0.8734845, 0.0281026, 0.0168464, 0.1176827, 0.8654709]
    static let fromProPhoto = inverse(toProPhoto)

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
    /// `lightroom` (version 3): as Lightroom's Tint, the light moved off the locus (CIE 1960 uv, at right angles to it) by
    /// 1/2000 per step, so ±100 is Lightroom's ±150, and towards green for a positive Tint: the photo balanced against a
    /// greener light turns magenta. (Before, the light moved a third as far and the other way: the slider's green end
    /// turned the photo magenta. Versions 1 and 2 keep that, so their edits look as they did.)
    private static func chromaticity(kelvin t: Double, tint: Double, lightroom: Bool = false) -> (Double, Double) {
        if lightroom {
            let (x, y) = chromaticity(kelvin: t, tint: 0)
            guard tint != 0 else { return (x, y) }
            func uv(_ p: (Double, Double)) -> (Double, Double) { let d = -2 * p.0 + 12 * p.1 + 3; return (4 * p.0 / d, 6 * p.1 / d) }
            let (u, v) = uv((x, y)), warm = uv(chromaticity(kelvin: t / 1.01, tint: 0)), cool = uv(chromaticity(kelvin: t * 1.01, tint: 0))
            var n = (-(cool.1 - warm.1), cool.0 - warm.0)
            let length = (n.0 * n.0 + n.1 * n.1).squareRoot()
            n = n.1 < 0 ? (-n.0 / length, -n.1 / length) : (n.0 / length, n.1 / length)
            let u2 = u + n.0 * tint / 2000, v2 = v + n.1 * tint / 2000, d = 2 * u2 - 8 * v2 + 4
            return (3 * u2 / d, 2 * v2 / d)
        }
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
        /// `peak`: the brightest the picture goes (1: white; above for HDR, in display light).
        /// `glowGain`: the soft layer's exposure (it's made without the photo's own).
        var toneCeiling: Float = 1, overlay: Float = -1, peak: Float = 1, glowGain: Float = 1
        /// Calibration's shadows tint, -1 (green) … 1 (magenta).
        var shadowTint: Float = 0
        /// The working space for colour: 0 linear sRGB (versions 1–2), 1 linear ProPhoto (version 3).
        var space: Int32 = 0
        /// Version 3: how the tone curve meets colour (0 as before, 1 Accurate's: chromaticity kept, 2 RGBTone with each
        /// colour's hue kept) and whether the profile has a hue and saturation table (ColourProfiles).
        var tro: Int32 = 0, hueSat: Int32 = 0
        /// Process 4 (Highlights' top stops, see `tonedLog`).
        var v4: Int32 = 0
        /// Process 5 (Dehaze on brightness, Accurate's fade to white, a finished picture's profiles, Neutral's hue).
        var v5: Int32 = 0
        /// Process 5's Glow (`glowed`): its amount (0…1) and mode (GlowMode's order); Texture's noise as variance a·Y + b of
        /// the photo's light before the exposure (`noiseGain`), from PhotoRender.noiseModel (0: none known).
        var glow: Float = 0, glowMode: Int32 = 1, noiseA: Float = 0, noiseB: Float = 0, noiseGain: Float = 1
    }

    /// The vignette's highlights and style, and the grain, for the GPU (see PhotoRender.effects).
    struct Effects {
        var highlights: Float = 0, grain: Float = 0, size: Float = 1, rough: Float = 0, scale: Float = 1, ox: Float = 0, oy: Float = 0
        var paint: Int32 = 0
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
        /// Blending as a width (1: Lightroom's 50) and Balance as stops the split moves.
        var blend: Float = 1, balance: Float = 0
        /// Process 5 (not the film's light): Saturation and Vibrance on the picture, HSV (`hsvSaturation`), instead of the two
        /// above (zero then, so the earlier processes' code runs exactly as it was).
        var hsvSaturation: Float = 0, hsvVibrance: Float = 0
        /// Process 5: the colour wheels (`wheels5`), Lift/Gamma/Gain/Offset (`primaries5`, `pLift`…) and, not with the film's
        /// light, the mixer on the picture as shown (`mixer5`), in place of `wheels` and `mixer` (0 then, as above). `gradeR`:
        /// the grading space's white as log2(1 + white/k) (a RAW's tone curve's white, 14.2; a finished picture's 1).
        var wheels5: Int32 = 0, primaries5: Int32 = 0, mixer5: Int32 = 0, gradeR: Float = 10.88745
        var pLift = SIMD4<Float>(), pGamma = SIMD4<Float>(), pGain = SIMD4<Float>(), pOffset = SIMD4<Float>()

        init(_ a: PhotoAdjustments, scene: Bool = false, isRaw: Bool = true) {
            func wheel(_ w: ColorWheels.Wheel) -> SIMD4<Float> {
                let (r, g, b) = w.rgb
                return SIMD4(Float(r), Float(g), Float(b), Float(w.master))
            }
            let w = a.wheels
            lift = wheel(w.lift); gamma = wheel(w.gamma); gain = wheel(w.gain); offset = wheel(w.offset)
            wheels = w.tonesDefault ? 0 : 1
            blend = Float(max(w.blending, 5) / 50); balance = Float(w.balance / 100 * 2)
            func eight(_ v: [Double]) -> Eight {
                let f = (v + [Double](repeating: 0, count: 8)).prefix(8).map(Float.init)
                return (f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7])
            }
            hue = eight(a.mixer.hue); sat = eight(a.mixer.saturation); lum = eight(a.mixer.luminance)
            mixer = a.mixer.bandsDefault ? 0 : 1
            vibrance = Float(a.vibrance / 100); saturation = Float(a.saturation / 100)
            if a.process >= 5, !scene { (hsvSaturation, hsvVibrance, saturation, vibrance) = (saturation, vibrance, 0, 0) }
            if a.process >= 5 {
                (wheels5, wheels) = (wheels, 0)
                let p = w.primaries
                pLift = wheel(p.lift); pGamma = wheel(p.gamma); pGain = wheel(p.gain); pOffset = wheel(p.offset)
                primaries5 = p.isDefault ? 0 : 1
                if !isRaw { gradeR = Float(log2(1 + 1 / 0.0075)) }
                if !scene { (mixer5, mixer) = (mixer, 0) }
            }
        }
    }

    /// The tone curve for these settings (version 2): AgX's shape (fitted to Blender's), with the
    /// slope at mid grey from Contrast and the profile, and the black and white points (in stops)
    /// from Blacks and Whites.
    /// `peak` above 1: HDR, the brightest stops given that much more room (the white point moves
    /// up by as many stops, so the middle and the shadows stay as they are).
    static func tone(_ a: PhotoAdjustments, profile: Profile, into p: inout Params, peak: Double = 1) {
        let lo = -12.47393 - a.blacks / 100 * 2.5, hi = 4.026069 - a.whites / 100 * 2.5 + log2(max(peak, 1))
        let grey = (log2(0.18 * 1.15) - lo) / (hi - lo)
        let y0 = 0.5219
        let v3 = a.process >= 3
        // Process 5's Standard: Classic's curve as it is (Apple's brightness), its colour from its table.
        let standard5 = a.process >= 5 && profile == .standard
        let look: Double = switch profile {
        case .standard: standard5 ? 1 : 1.2
        case .vivid: v3 ? 1.15 : 1.25
        case .flat: 0.8
        case .monochrome: 1.06
        case .landscape: 1.1
        case .portrait: 0.92
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
        let white = pow(max(peak, 1), 1 / 2.2)
        var top = white + 0.0001, high = 50.0
        for _ in 0..<40 { let mid = (top + high) / 2; if shoulder(mid) < white { top = mid } else { high = mid } }
        var bottom = -50.0, low = -0.0001
        for _ in 0..<40 { let mid = (bottom + low) / 2; if toe(mid) > 0 { low = mid } else { bottom = mid } }
        p.toneLo = Float(lo); p.toneHi = Float(hi); p.toneGrey = Float(grey); p.toneY = Float(y0)
        p.toneSlope = Float(slope); p.tonePt = Float(pt); p.tonePb = Float(pb)
        p.toneFloor = Float((bottom + low) / 2); p.toneCeiling = Float((top + high) / 2)
        // (Version 3's Vivid has its colour from its table.)
        p.sat = Float(profile == .vivid ? (v3 ? 1 : 1.35) : profile == .standard && !standard5 ? 1.15 : profile == .flat ? 0.95 : 1)
        // (Process 5: Neutral and Flat keep each colour's hue through the curve too: bright blues went purple, reds magenta.)
        p.tro = !v3 ? 0 : profile == .accurate ? 1 : [.adobe, .vivid, .landscape, .portrait].contains(profile) || standard5
            || a.process >= 5 && [.neutral, .flat].contains(profile) ? 2 : 0
        p.mono = profile == .monochrome ? 1 : 0
        p.peak = Float(max(peak, 1))
    }

    /// The curves as a table of 128 steps per channel (the master after each). `base`: Adobe's tone curve
    /// first (the Classic profile).
    static func curveTable(_ curves: PhotoCurves, base: [Double]? = nil) -> Data {
        let master = Curve(curves.master), red = Curve(curves.red), green = Curve(curves.green), blue = Curve(curves.blue)
        var values = [Float](repeating: 0, count: 128 * 4)
        for i in 0..<128 {
            let x = base?[i] ?? Double(i) / 127
            values[i * 4] = Float(master.value(red.value(x)))
            values[i * 4 + 1] = Float(master.value(green.value(x)))
            values[i * 4 + 2] = Float(master.value(blue.value(x)))
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// The Classic profile (`adobe`), on the picture's sRGB steps (128): what Neutral makes of the light, as the
    /// DNG SDK's default tone curve (dng_tone_curve_acr3_default) would make it instead. The sliders still
    /// work on Neutral's curve underneath; at their defaults, the light's grey gets Adobe's curve exactly.
    static let adobeBase = adobeBase(matchingNeutral: true)
    /// Version 3: Adobe's curve on the light as it is, as Lightroom's Adobe Color (its mid grey 0.7 stop above Neutral's),
    /// so Lightroom's Exposure gives about the same brightness.
    static let adobeBaseV3 = adobeBase(matchingNeutral: false)
    /// Process 4: the same, its roll into white ending `0.3` stop sooner (Lightroom's whites clip more: 0.6–3% of
    /// the frame against 0.15–0.55%, its upper mid-tones 2–3 OkLab L ×100 brighter).
    /// Then its brightness put on Apple's default decode's (CIRAWFilter, all defaults; the owner's pick, 2026-11-07): Pluck's
    /// greys sat 3–7 OkLab L ×100 brighter through the mid-tones (the deep shadows and white alike), measured on the centres of
    /// four RAWs' low-colour pixels. `appleTone` maps that lightness back, the same for every photo.
    static let adobeBaseV4 = adobeBase(matchingNeutral: false, sooner: 0.6).map(appleTone)

    /// Pluck's OkLab lightness → Apple's (grey), read linearly between the measured points.
    static let appleTonePoints: [(pluck: Double, apple: Double)] = [
        (0, 0), (0.146, 0.153), (0.279, 0.25), (0.401, 0.35), (0.512, 0.45), (0.622, 0.55), (0.7235, 0.65), (0.815, 0.75), (0.899, 0.85), (1, 1),
    ]

    static func appleTone(_ v: Double) -> Double {
        let L = cbrt(max(LookTable.fromSRGB(v), 0))
        guard L < 1 else { return v }
        let i = appleTonePoints.lastIndex { $0.pluck <= L } ?? 0, a = appleTonePoints[i], b = appleTonePoints[min(i + 1, appleTonePoints.count - 1)]
        let out = b.pluck > a.pluck ? a.apple + (b.apple - a.apple) * (L - a.pluck) / (b.pluck - a.pluck) : a.apple
        return LookTable.toSRGB(out * out * out)
    }

    /// Neutral's grey at the defaults (the shader's tone curve: inset and outset keep grey grey), linear light in and out.
    private static func neutralGrey(_ s: Double) -> Double {
        var p = Params()
        tone(PhotoAdjustments(), profile: .neutral, into: &p)
        let x = min(max((log2(max(s * 1.15, 1e-10)) - Double(p.toneLo)) / Double(p.toneHi - p.toneLo), 0), 1)
        let grey = Double(p.toneGrey), y0 = Double(p.toneY), slope = Double(p.toneSlope)
        let y = x >= grey
            ? y0 + slope * (x - grey) / pow(1 + pow(slope * (x - grey) / (Double(p.toneCeiling) - y0), Double(p.tonePb)), 1 / Double(p.tonePb))
            : y0 - slope * (grey - x) / pow(1 + pow(slope * (grey - x) / (y0 - Double(p.toneFloor)), Double(p.tonePt)), 1 / Double(p.tonePt))
        return pow(min(max(y, 0), 1), 2.2)
    }

    /// Process 5's Neutral: the stops its light is raised by so its mid grey is Classic's (process 4/5: Neutral's curve, then
    /// adobeBaseV4), so the photo doesn't jump between them (it sat about ¼ stop darker).
    static let neutralLift5: Double = {
        let e = LookTable.toSRGB(neutralGrey(0.18)) * 127, i = min(Int(e), 126), f = e - Double(i)
        let classic = LookTable.fromSRGB(adobeBaseV4[i] * (1 - f) + adobeBaseV4[i + 1] * f)
        var low = -2.0, high = 2.0
        for _ in 0..<50 { let mid = (low + high) / 2; if neutralGrey(0.18 * exp2(mid)) < classic { low = mid } else { high = mid } }
        return (low + high) / 2
    }()

    private static func adobeBase(matchingNeutral: Bool, sooner: Double = 0) -> [Double] {
        var p = Params()
        tone(PhotoAdjustments(), profile: .neutral, into: &p)
        let neutral = neutralGrey
        func acr3(_ x: Double) -> Double {
            let y = min(max(x, 0), 1) * Double(adobeCurve.count - 1)
            let i = min(Int(y), adobeCurve.count - 2), f = y - Double(i)
            return adobeCurve[i] * (1 - f) + adobeCurve[i + 1] * f
        }
        // The SDK puts the camera's baseline exposure ahead of the curve; Pluck's decode has its own, so the light is
        // scaled to keep Neutral's mid grey (the curve alone puts it 0.7 stop brighter).
        var below = -8.0, above = 4.0
        for _ in 0..<50 { let mid = (below + above) / 2; if acr3(0.18 * exp2(mid)) < neutral(0.18) { below = mid } else { above = mid } }
        let gain = matchingNeutral ? exp2((below + above) / 2) : 1
        // Above `knee` the light rolls smoothly into white at Neutral's white, rather than clipping at the curve's end.
        let knee = 0.6, top = gain * exp2(Double(p.toneHi) - sooner) / 1.15
        func rolled(_ t: Double) -> Double {
            guard top > 1, t > knee else { return t }
            let m = (top - knee) / (1 - knee), u = min((t - knee) / (top - knee), 1)
            return knee + (1 - knee) * m * u / (1 + (m - 1) * u)
        }
        return (0..<128).map { i in
            let d = LookTable.fromSRGB(Double(i) / 127)
            guard d > neutral(1e-6) else { return 0 }
            // The light Neutral made this from (by halving, in stops).
            var low = -20.0, high = 6.0
            for _ in 0..<50 { let mid = (low + high) / 2; if neutral(exp2(mid)) < d { low = mid } else { high = mid } }
            return LookTable.toSRGB(acr3(rolled(gain * exp2((low + high) / 2))))
        }
    }

    /// dng_tone_curve_acr3_default (DNG SDK, dng_render.cpp): linear light in, linear light out, 1025 steps.
    static let adobeCurve: [Double] = [
        0.00000, 0.00078, 0.00160, 0.00242, 0.00314, 0.00385, 0.00460, 0.00539,
        0.00623, 0.00712, 0.00806, 0.00906, 0.01012, 0.01122, 0.01238, 0.01359,
        0.01485, 0.01616, 0.01751, 0.01890, 0.02033, 0.02180, 0.02331, 0.02485,
        0.02643, 0.02804, 0.02967, 0.03134, 0.03303, 0.03475, 0.03648, 0.03824,
        0.04002, 0.04181, 0.04362, 0.04545, 0.04730, 0.04916, 0.05103, 0.05292,
        0.05483, 0.05675, 0.05868, 0.06063, 0.06259, 0.06457, 0.06655, 0.06856,
        0.07057, 0.07259, 0.07463, 0.07668, 0.07874, 0.08081, 0.08290, 0.08499,
        0.08710, 0.08921, 0.09134, 0.09348, 0.09563, 0.09779, 0.09996, 0.10214,
        0.10433, 0.10652, 0.10873, 0.11095, 0.11318, 0.11541, 0.11766, 0.11991,
        0.12218, 0.12445, 0.12673, 0.12902, 0.13132, 0.13363, 0.13595, 0.13827,
        0.14061, 0.14295, 0.14530, 0.14765, 0.15002, 0.15239, 0.15477, 0.15716,
        0.15956, 0.16197, 0.16438, 0.16680, 0.16923, 0.17166, 0.17410, 0.17655,
        0.17901, 0.18148, 0.18395, 0.18643, 0.18891, 0.19141, 0.19391, 0.19641,
        0.19893, 0.20145, 0.20398, 0.20651, 0.20905, 0.21160, 0.21416, 0.21672,
        0.21929, 0.22185, 0.22440, 0.22696, 0.22950, 0.23204, 0.23458, 0.23711,
        0.23963, 0.24215, 0.24466, 0.24717, 0.24967, 0.25216, 0.25465, 0.25713,
        0.25961, 0.26208, 0.26454, 0.26700, 0.26945, 0.27189, 0.27433, 0.27676,
        0.27918, 0.28160, 0.28401, 0.28641, 0.28881, 0.29120, 0.29358, 0.29596,
        0.29833, 0.30069, 0.30305, 0.30540, 0.30774, 0.31008, 0.31241, 0.31473,
        0.31704, 0.31935, 0.32165, 0.32395, 0.32623, 0.32851, 0.33079, 0.33305,
        0.33531, 0.33756, 0.33981, 0.34205, 0.34428, 0.34650, 0.34872, 0.35093,
        0.35313, 0.35532, 0.35751, 0.35969, 0.36187, 0.36404, 0.36620, 0.36835,
        0.37050, 0.37264, 0.37477, 0.37689, 0.37901, 0.38112, 0.38323, 0.38533,
        0.38742, 0.38950, 0.39158, 0.39365, 0.39571, 0.39777, 0.39982, 0.40186,
        0.40389, 0.40592, 0.40794, 0.40996, 0.41197, 0.41397, 0.41596, 0.41795,
        0.41993, 0.42191, 0.42388, 0.42584, 0.42779, 0.42974, 0.43168, 0.43362,
        0.43554, 0.43747, 0.43938, 0.44129, 0.44319, 0.44509, 0.44698, 0.44886,
        0.45073, 0.45260, 0.45447, 0.45632, 0.45817, 0.46002, 0.46186, 0.46369,
        0.46551, 0.46733, 0.46914, 0.47095, 0.47275, 0.47454, 0.47633, 0.47811,
        0.47989, 0.48166, 0.48342, 0.48518, 0.48693, 0.48867, 0.49041, 0.49214,
        0.49387, 0.49559, 0.49730, 0.49901, 0.50072, 0.50241, 0.50410, 0.50579,
        0.50747, 0.50914, 0.51081, 0.51247, 0.51413, 0.51578, 0.51742, 0.51906,
        0.52069, 0.52232, 0.52394, 0.52556, 0.52717, 0.52878, 0.53038, 0.53197,
        0.53356, 0.53514, 0.53672, 0.53829, 0.53986, 0.54142, 0.54297, 0.54452,
        0.54607, 0.54761, 0.54914, 0.55067, 0.55220, 0.55371, 0.55523, 0.55673,
        0.55824, 0.55973, 0.56123, 0.56271, 0.56420, 0.56567, 0.56715, 0.56861,
        0.57007, 0.57153, 0.57298, 0.57443, 0.57587, 0.57731, 0.57874, 0.58017,
        0.58159, 0.58301, 0.58443, 0.58583, 0.58724, 0.58864, 0.59003, 0.59142,
        0.59281, 0.59419, 0.59556, 0.59694, 0.59830, 0.59966, 0.60102, 0.60238,
        0.60373, 0.60507, 0.60641, 0.60775, 0.60908, 0.61040, 0.61173, 0.61305,
        0.61436, 0.61567, 0.61698, 0.61828, 0.61957, 0.62087, 0.62216, 0.62344,
        0.62472, 0.62600, 0.62727, 0.62854, 0.62980, 0.63106, 0.63232, 0.63357,
        0.63482, 0.63606, 0.63730, 0.63854, 0.63977, 0.64100, 0.64222, 0.64344,
        0.64466, 0.64587, 0.64708, 0.64829, 0.64949, 0.65069, 0.65188, 0.65307,
        0.65426, 0.65544, 0.65662, 0.65779, 0.65897, 0.66013, 0.66130, 0.66246,
        0.66362, 0.66477, 0.66592, 0.66707, 0.66821, 0.66935, 0.67048, 0.67162,
        0.67275, 0.67387, 0.67499, 0.67611, 0.67723, 0.67834, 0.67945, 0.68055,
        0.68165, 0.68275, 0.68385, 0.68494, 0.68603, 0.68711, 0.68819, 0.68927,
        0.69035, 0.69142, 0.69249, 0.69355, 0.69461, 0.69567, 0.69673, 0.69778,
        0.69883, 0.69988, 0.70092, 0.70196, 0.70300, 0.70403, 0.70506, 0.70609,
        0.70711, 0.70813, 0.70915, 0.71017, 0.71118, 0.71219, 0.71319, 0.71420,
        0.71520, 0.71620, 0.71719, 0.71818, 0.71917, 0.72016, 0.72114, 0.72212,
        0.72309, 0.72407, 0.72504, 0.72601, 0.72697, 0.72794, 0.72890, 0.72985,
        0.73081, 0.73176, 0.73271, 0.73365, 0.73460, 0.73554, 0.73647, 0.73741,
        0.73834, 0.73927, 0.74020, 0.74112, 0.74204, 0.74296, 0.74388, 0.74479,
        0.74570, 0.74661, 0.74751, 0.74842, 0.74932, 0.75021, 0.75111, 0.75200,
        0.75289, 0.75378, 0.75466, 0.75555, 0.75643, 0.75730, 0.75818, 0.75905,
        0.75992, 0.76079, 0.76165, 0.76251, 0.76337, 0.76423, 0.76508, 0.76594,
        0.76679, 0.76763, 0.76848, 0.76932, 0.77016, 0.77100, 0.77183, 0.77267,
        0.77350, 0.77432, 0.77515, 0.77597, 0.77680, 0.77761, 0.77843, 0.77924,
        0.78006, 0.78087, 0.78167, 0.78248, 0.78328, 0.78408, 0.78488, 0.78568,
        0.78647, 0.78726, 0.78805, 0.78884, 0.78962, 0.79040, 0.79118, 0.79196,
        0.79274, 0.79351, 0.79428, 0.79505, 0.79582, 0.79658, 0.79735, 0.79811,
        0.79887, 0.79962, 0.80038, 0.80113, 0.80188, 0.80263, 0.80337, 0.80412,
        0.80486, 0.80560, 0.80634, 0.80707, 0.80780, 0.80854, 0.80926, 0.80999,
        0.81072, 0.81144, 0.81216, 0.81288, 0.81360, 0.81431, 0.81503, 0.81574,
        0.81645, 0.81715, 0.81786, 0.81856, 0.81926, 0.81996, 0.82066, 0.82135,
        0.82205, 0.82274, 0.82343, 0.82412, 0.82480, 0.82549, 0.82617, 0.82685,
        0.82753, 0.82820, 0.82888, 0.82955, 0.83022, 0.83089, 0.83155, 0.83222,
        0.83288, 0.83354, 0.83420, 0.83486, 0.83552, 0.83617, 0.83682, 0.83747,
        0.83812, 0.83877, 0.83941, 0.84005, 0.84069, 0.84133, 0.84197, 0.84261,
        0.84324, 0.84387, 0.84450, 0.84513, 0.84576, 0.84639, 0.84701, 0.84763,
        0.84825, 0.84887, 0.84949, 0.85010, 0.85071, 0.85132, 0.85193, 0.85254,
        0.85315, 0.85375, 0.85436, 0.85496, 0.85556, 0.85615, 0.85675, 0.85735,
        0.85794, 0.85853, 0.85912, 0.85971, 0.86029, 0.86088, 0.86146, 0.86204,
        0.86262, 0.86320, 0.86378, 0.86435, 0.86493, 0.86550, 0.86607, 0.86664,
        0.86720, 0.86777, 0.86833, 0.86889, 0.86945, 0.87001, 0.87057, 0.87113,
        0.87168, 0.87223, 0.87278, 0.87333, 0.87388, 0.87443, 0.87497, 0.87552,
        0.87606, 0.87660, 0.87714, 0.87768, 0.87821, 0.87875, 0.87928, 0.87981,
        0.88034, 0.88087, 0.88140, 0.88192, 0.88244, 0.88297, 0.88349, 0.88401,
        0.88453, 0.88504, 0.88556, 0.88607, 0.88658, 0.88709, 0.88760, 0.88811,
        0.88862, 0.88912, 0.88963, 0.89013, 0.89063, 0.89113, 0.89163, 0.89212,
        0.89262, 0.89311, 0.89360, 0.89409, 0.89458, 0.89507, 0.89556, 0.89604,
        0.89653, 0.89701, 0.89749, 0.89797, 0.89845, 0.89892, 0.89940, 0.89987,
        0.90035, 0.90082, 0.90129, 0.90176, 0.90222, 0.90269, 0.90316, 0.90362,
        0.90408, 0.90454, 0.90500, 0.90546, 0.90592, 0.90637, 0.90683, 0.90728,
        0.90773, 0.90818, 0.90863, 0.90908, 0.90952, 0.90997, 0.91041, 0.91085,
        0.91130, 0.91173, 0.91217, 0.91261, 0.91305, 0.91348, 0.91392, 0.91435,
        0.91478, 0.91521, 0.91564, 0.91606, 0.91649, 0.91691, 0.91734, 0.91776,
        0.91818, 0.91860, 0.91902, 0.91944, 0.91985, 0.92027, 0.92068, 0.92109,
        0.92150, 0.92191, 0.92232, 0.92273, 0.92314, 0.92354, 0.92395, 0.92435,
        0.92475, 0.92515, 0.92555, 0.92595, 0.92634, 0.92674, 0.92713, 0.92753,
        0.92792, 0.92831, 0.92870, 0.92909, 0.92947, 0.92986, 0.93025, 0.93063,
        0.93101, 0.93139, 0.93177, 0.93215, 0.93253, 0.93291, 0.93328, 0.93366,
        0.93403, 0.93440, 0.93478, 0.93515, 0.93551, 0.93588, 0.93625, 0.93661,
        0.93698, 0.93734, 0.93770, 0.93807, 0.93843, 0.93878, 0.93914, 0.93950,
        0.93986, 0.94021, 0.94056, 0.94092, 0.94127, 0.94162, 0.94197, 0.94231,
        0.94266, 0.94301, 0.94335, 0.94369, 0.94404, 0.94438, 0.94472, 0.94506,
        0.94540, 0.94573, 0.94607, 0.94641, 0.94674, 0.94707, 0.94740, 0.94774,
        0.94807, 0.94839, 0.94872, 0.94905, 0.94937, 0.94970, 0.95002, 0.95035,
        0.95067, 0.95099, 0.95131, 0.95163, 0.95194, 0.95226, 0.95257, 0.95289,
        0.95320, 0.95351, 0.95383, 0.95414, 0.95445, 0.95475, 0.95506, 0.95537,
        0.95567, 0.95598, 0.95628, 0.95658, 0.95688, 0.95718, 0.95748, 0.95778,
        0.95808, 0.95838, 0.95867, 0.95897, 0.95926, 0.95955, 0.95984, 0.96013,
        0.96042, 0.96071, 0.96100, 0.96129, 0.96157, 0.96186, 0.96214, 0.96242,
        0.96271, 0.96299, 0.96327, 0.96355, 0.96382, 0.96410, 0.96438, 0.96465,
        0.96493, 0.96520, 0.96547, 0.96574, 0.96602, 0.96629, 0.96655, 0.96682,
        0.96709, 0.96735, 0.96762, 0.96788, 0.96815, 0.96841, 0.96867, 0.96893,
        0.96919, 0.96945, 0.96971, 0.96996, 0.97022, 0.97047, 0.97073, 0.97098,
        0.97123, 0.97149, 0.97174, 0.97199, 0.97223, 0.97248, 0.97273, 0.97297,
        0.97322, 0.97346, 0.97371, 0.97395, 0.97419, 0.97443, 0.97467, 0.97491,
        0.97515, 0.97539, 0.97562, 0.97586, 0.97609, 0.97633, 0.97656, 0.97679,
        0.97702, 0.97725, 0.97748, 0.97771, 0.97794, 0.97817, 0.97839, 0.97862,
        0.97884, 0.97907, 0.97929, 0.97951, 0.97973, 0.97995, 0.98017, 0.98039,
        0.98061, 0.98082, 0.98104, 0.98125, 0.98147, 0.98168, 0.98189, 0.98211,
        0.98232, 0.98253, 0.98274, 0.98295, 0.98315, 0.98336, 0.98357, 0.98377,
        0.98398, 0.98418, 0.98438, 0.98458, 0.98478, 0.98498, 0.98518, 0.98538,
        0.98558, 0.98578, 0.98597, 0.98617, 0.98636, 0.98656, 0.98675, 0.98694,
        0.98714, 0.98733, 0.98752, 0.98771, 0.98789, 0.98808, 0.98827, 0.98845,
        0.98864, 0.98882, 0.98901, 0.98919, 0.98937, 0.98955, 0.98973, 0.98991,
        0.99009, 0.99027, 0.99045, 0.99063, 0.99080, 0.99098, 0.99115, 0.99133,
        0.99150, 0.99167, 0.99184, 0.99201, 0.99218, 0.99235, 0.99252, 0.99269,
        0.99285, 0.99302, 0.99319, 0.99335, 0.99351, 0.99368, 0.99384, 0.99400,
        0.99416, 0.99432, 0.99448, 0.99464, 0.99480, 0.99495, 0.99511, 0.99527,
        0.99542, 0.99558, 0.99573, 0.99588, 0.99603, 0.99619, 0.99634, 0.99649,
        0.99664, 0.99678, 0.99693, 0.99708, 0.99722, 0.99737, 0.99751, 0.99766,
        0.99780, 0.99794, 0.99809, 0.99823, 0.99837, 0.99851, 0.99865, 0.99879,
        0.99892, 0.99906, 0.99920, 0.99933, 0.99947, 0.99960, 0.99974, 0.99987,
        1.00000,
    ]

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
        float toneCeiling, overlay, peak, glowGain;
        float shadowTint;
        int space;
        int tro, hueSat;
        int v4;
        int v5;
        float glow;
        int glowMode;
        float noiseA, noiseB, noiseGain;
    };

    // Colour wheels and the mixer (scene light).
    struct Grade {
        float4 lift, gamma, gain, offset;
        float hue[8]; float sat[8]; float lum[8];
        float vibrance, saturation;
        int wheels, mixer;
        float blend, balance;
        float hsvSaturation, hsvVibrance;
        int wheels5, primaries5, mixer5;
        float gradeR;
        float4 pLift, pGamma, pGain, pOffset;
    };

    constant float3x3 toRec2020 = float3x3(float3(0.6274039, 0.0690973, 0.0163914),
                                           float3(0.3292830, 0.9195404, 0.0880133),
                                           float3(0.0433131, 0.0113623, 0.8955953));
    constant float3x3 fromRec2020 = float3x3(float3(1.6604910, -0.1245505, -0.0181508),
                                             float3(-0.5876411, 1.1328999, -0.1005789),
                                             float3(-0.0728499, -0.0083494, 1.1187297));
    inline float luma2020(float3 c) { return dot(c, float3(0.2627, 0.6780, 0.0593)); }

    // Linear sRGB (D65) to and from linear ProPhoto (D50, Bradford: see PhotoEngine.toProPhoto); version 3 works in ProPhoto.
    constant float3x3 toPro = float3x3(float3(0.5292993, 0.0984129, 0.0168464),
                                       float3(0.3300508, 0.8734845, 0.1176827),
                                       float3(0.1406499, 0.0281026, 0.8654709));
    constant float3x3 fromPro = float3x3(float3(2.0342895, -0.2289248, -0.0084694),
                                         float3(-0.7273081, 1.2317166, -0.1533260),
                                         float3(-0.3069813, -0.0027918, 1.1617954));
    inline float lumaPro(float3 c) { return dot(c, float3(0.2880, 0.7119, 0.0001)); }

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
    inline float3 compressGamut(float3 c, float3 thr = float3(0.815, 0.803, 0.880), float3 lim = float3(1.147, 1.264, 1.312)) {
        float ach = max(c.r, max(c.g, c.b));
        if (ach <= 1e-6) return max(c, 0.0);
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

    // Calibration's shadows tint (scene light): magenta (or green) strongest in the deep shadows,
    // gone by mid grey.
    inline float3 tintShadows(float3 c, float k, float Y) {
        float w = 1.0 - smoothstep(-6.0, 0.0, log2(max(Y, 1e-6) / 0.18));
        float a = 0.3 * k * w;
        return c * exp2(float3(a, -a, a));
    }

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
        // (And the plain mean, for version 3's Shadows: see liftBase.)
        dst.write(float4(a, m.x - a * m.x, m.x, 1), gid);
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

    // DNG SDK's RGBTone (dng_reference.cpp, RefBaselineRGBTone), as Adobe's renderer puts its curves on ProPhoto: the
    // brightest and darkest channels through the curve, the middle one kept where it was between them, so the hue holds.
    inline float3 rgbTone(float3 c, float hi, float lo) {
        float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
        if (mx - mn < 1e-9) return float3(hi);
        return lo + (hi - lo) * (c - mn) / (mx - mn);
    }

    // Accurate, near white: the colour fades to white at its brightness. How far towards the brightest a channel reaches, 1 at
    // the edge, eased from 0.8 so it never gets there; by taking colourfulness out in OkLab, lightness and hue kept (towards
    // white in RGB, blues went purple). Linear ProPhoto in and out.
    // Process 5: the same fade, found safely. The reach is eased with tanh held to a sane range (fast maths overflowed it for a
    // colour far past its headroom: every step then failed and a saturated green just under white turned grey from one pixel
    // to the next), and the search asks only "is the brightest channel within the goal", which grows steadily with the colour.
    inline float3 towardsWhite5(float3 outc, constant Params &p) {
        float Yo = lumaPro(outc), mx = max(outc.r, max(outc.g, outc.b)), head = p.peak - Yo;
        if (mx - Yo <= 0.8 * head) return outc;
        float r = (mx - Yo) / max(head, 1e-6);
        float goal = 0.8 + 0.2 * tanh(min((r - 0.8) / 0.2, 8.0));
        float top = head > 0.0 ? Yo + goal * head : Yo, lo = 0.0, hi = 1.0;
        float3 o = oklab(fromPro * outc);
        for (int i = 0; i < 12; i++) {
            float k = 0.5 * (lo + hi);
            float3 t = toPro * fromOklab(float3(o.x, o.yz * k));
            if (max(t.r, max(t.g, t.b)) <= top) lo = k; else hi = k;
        }
        return toPro * fromOklab(float3(o.x, o.yz * lo));
    }

    inline float3 towardsWhite(float3 outc, constant Params &p) {
        if (p.v5 == 1) return towardsWhite5(outc, p);
        float Yo = lumaPro(outc), mx = max(outc.r, max(outc.g, outc.b));
        float r = (mx - Yo) / max(p.peak - Yo, 1e-6);
        if (r <= 0.8) return outc;
        float goal = 0.8 + 0.2 * tanh((r - 0.8) / 0.2), lo = 0.0, hi = 1.0;
        float3 o = oklab(fromPro * outc);
        for (int i = 0; i < 12; i++) {
            float k = 0.5 * (lo + hi);
            float3 t = toPro * fromOklab(float3(o.x, o.yz * k));
            float Yt2 = lumaPro(t);
            if ((max(t.r, max(t.g, t.b)) - Yt2) / max(p.peak - Yt2, 1e-6) <= goal) lo = k; else hi = k;
        }
        return toPro * fromOklab(float3(o.x, o.yz * lo));
    }

    // One value through the tone curve (scene light in, picture light out).
    inline float toneLight(float v, constant Params &p) {
        float x = clamp((log2(max(v, 1e-10)) - p.toneLo) / (p.toneHi - p.toneLo), 0.0, 1.0);
        return pow(clamp(toneCurve(x, p), 0.0, pow(p.peak, 1.0 / 2.2)), 2.2);
    }

    // One linear value through the curves' channel `k` (sRGB steps).
    inline float curveLight(float v, int k, constant float4 *curve) {
        float e = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(clamp(v, 0.0, 1.0), 1.0 / 2.4) - 0.055;
        float at = clamp(e, 0.0, 1.0) * 127.0;
        int i0 = int(floor(at)), i1 = min(i0 + 1, 127);
        e = mix(curve[i0][k], curve[i1][k], at - float(i0));
        return e <= 0.04045 ? e / 12.92 : pow((e + 0.055) / 1.055, 2.4);
    }

    // Process 5, a finished picture (JPEG, HEIC): no second tone curve. The profile's look (its slope: Vivid 1.15, Portrait
    // 0.92, …) and Contrast as a gentle S around the picture's mid grey (0.18, kept), black and white pinned; Whites and Blacks
    // move the picture's ends. In gamma 2.2 steps; above white (HDR) as it is.
    inline float pictureTone(float v, constant Params &p) {
        if (v <= 0.0) return v;
        float e = pow(v, 1.0 / 2.2);
        if (e >= 1.0) return v;
        const float g = 0.4587;
        float s = p.toneSlope / (0.12505 * (p.toneHi - p.toneLo));
        e = e < g ? g * pow(e / g, s) : 1.0 - (1.0 - g) * pow((1.0 - e) / (1.0 - g), s);
        e *= 1.0 + 0.2 * p.whites * e * e;
        e += 0.1 * p.blacks * (1.0 - e) * (1.0 - e);
        return pow(clamp(e, 0.0, 1.0), 2.2);
    }

    // Version 3's profile table (ColourProfiles), as the DNG SDK's HueSatMap (dng_reference.cpp, RefBaselineHueSatMap): in HSV
    // of linear ProPhoto, each colour's hue turned and its saturation and value scaled, read between the table's 60 hues
    // and 12 saturations. The same at any exposure; grey untouched.
    constant int hsHues = 60, hsSats = 12;
    inline float3 hueSatMap(float3 c, constant float4 *t) {
        float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b)), d = mx - mn;
        if (mx <= 0.0 || d <= 0.0) return c;
        float h = c.r == mx ? (c.g - c.b) / d : c.g == mx ? 2.0 + (c.b - c.r) / d : 4.0 + (c.r - c.g) / d;
        if (h < 0.0) h += 6.0;
        float s = d / mx;
        float hf = h * float(hsHues) / 6.0, fh = hf - floor(hf);
        int h0 = int(floor(hf)) % hsHues, h1 = (h0 + 1) % hsHues;
        float sf = min(s, 1.0) * float(hsSats - 1);
        int s0 = min(int(floor(sf)), hsSats - 2);
        float fs = sf - float(s0);
        float4 e = mix(mix(t[h0 * hsSats + s0], t[h0 * hsSats + s0 + 1], fs), mix(t[h1 * hsSats + s0], t[h1 * hsSats + s0 + 1], fs), fh);
        h = fmod(h + e.x / 60.0 + 6.0, 6.0);
        s *= e.y;
        float v = mx * e.z, f = h - floor(h);
        float p = v * (1.0 - s), q = v * (1.0 - s * f), u = v * (1.0 - s * (1.0 - f));
        switch (int(floor(h)) % 6) {
            case 0: return float3(v, u, p);
            case 1: return float3(q, v, p);
            case 2: return float3(p, v, u);
            case 3: return float3(p, q, v);
            case 4: return float3(u, p, v);
            default: return float3(v, p, q);
        }
    }

    // Process 5's Saturation and Vibrance, as DaVinci Resolve's HSV saturation: on the picture as shown (after the tone curve
    // and the curves), in Rec.2020 with a 2.4 gamma (a display-referred grading space, as Resolve's timeline; Rec.2020 so the
    // camera's real colours are all positive there), only HSV's S changes: each colour's brightest channel (V) is kept and the
    // others move away from it (richer, denser colour, no glow) or towards it (lower: down to a grey at V at -100). +100 is
    // twice the S, as Resolve's Sat 100. Raised S eases into the space's edge (from 0.85, never past 1); near white (every
    // channel over 0.9) is left as it is when raised; colours already outside Rec.2020 (a channel under 0) scale as they are.
    // Vibrance: the same, most on quiet colours ((1 - S)²) and a little over half as much on skin's hues (OkLCh 55°).
    inline float3 hsvSaturation(float3 c, constant Grade &g, bool pro) {
        float3 lin = pro ? fromPro * c : c;
        float3 r = toRec2020 * lin;
        float3 e = sign(r) * pow(abs(r), float3(1.0 / 2.4));
        float V = max(e.r, max(e.g, e.b)), m = min(e.r, min(e.g, e.b));
        if (V <= 1e-6 || V - m <= 1e-7) return c;
        float S = (V - m) / V, k = 1.0 + g.hsvSaturation;
        if (g.hsvVibrance != 0) {
            float3 o = oklab(lin);
            float h = atan2(o.z, o.y) * 57.29578, d = abs(h - 55.0);
            d = fmod(d + 360.0, 360.0); if (d > 180.0) d = 360.0 - d;
            float skin = exp(-(d * d) / (2.0 * 18.0 * 18.0)), quiet = (1.0 - min(S, 1.0)) * (1.0 - min(S, 1.0));
            k *= max(0.0, 1.0 + (g.hsvVibrance > 0 ? 1.6 * quiet * (1.0 - 0.45 * skin) : 1.0 - 0.45 * skin) * g.hsvVibrance);
        }
        float target = S * max(k, 0.0), S2 = target;
        if (target > S) {
            if (target > 0.85) S2 = max(S, 0.85 + 0.15 * tanh((target - 0.85) / 0.15));
            S2 = mix(S2, S, smoothstep(0.9, 1.0, m));
        }
        float3 e2 = V - (V - e) * (S2 / S);
        float3 out = fromRec2020 * (sign(e2) * pow(abs(e2), float3(2.4)));
        return pro ? toPro * out : out;
    }

    // Process 5's grading space, per channel: a log of the light with a straight toe through black, as DaVinci
    // Intermediate's (log2(1 + c/k)): 0 is black (so black can be tinted), 1 the tone curve's white (14.2), the stops above
    // a deep shadow evenly spaced. Rec.2020, so the wheels' colours are near the screen's and a camera's colours positive.
    constant float gradeK = 0.0075;
    inline float3 gradeU(float3 c, float R) { return select(c / (gradeK * 0.6931472 * R), log2(1.0 + c / gradeK) / R, c > 0.0); }
    inline float3 gradeC(float3 u, float R) { return select(u * (gradeK * 0.6931472 * R), gradeK * (exp2(u * R) - 1.0), u > 0.0); }
    // A colour push that doesn't change the brightness (Rec.2020's luminance weights add up to 1).
    inline float3 pushOnly(float3 v) { return v - luma2020(v); }
    // From `m` (the grading space) by `d`: light going down nears black without passing it (no negative light to clip).
    inline float3 pushed(float3 m, float3 d) { return select(m * m / max(m - d, 1e-6), m + d, d >= 0.0 || m < 0.0); }
    // The brightness put back to `target`, from about 4 stops under mid grey up (`uY`); under that a tinted black keeps the
    // little light its colour needs.
    inline float3 keepLight(float3 c, float target, float uY) {
        float Y = luma2020(c), k = smoothstep(0.0, 0.1, uY), d = target - Y;
        return d >= 0.0 || Y <= 1e-9 ? c + d * k : c * mix(1.0, target / Y, k);
    }

    // Process 5's colour wheels (Shadows, Midtones, Highlights, Global): each range a weight of the brightness in the grading
    // space (Balance moves the split, Blending widens the overlaps; Midtones is what the other two leave, so it's 0 at black
    // and at white); a wheel's brightness is a gain on the light (black stays black), its colour an even push of the log
    // light in its range (so Shadows tints black too), with the brightness put back.
    inline float3 wheels5(float3 c, constant Grade &g) {
        float3 r = toRec2020 * (fromPro * c);
        float uY = gradeU(float3(luma2020(r)), g.gradeR).x;
        float mid = 4.643856 / g.gradeR - 0.06 * g.balance, h = 0.12 * g.blend;
        float ws = 1.0 - smoothstep(mid - 0.12 - h, mid - 0.12 + h, uY), wh = smoothstep(mid + 0.12 - h, mid + 0.12 + h, uY);
        float wm = max(1.0 - ws - wh, 0.0);
        float3 lit = r * exp2((ws * g.lift.w + wm * g.gamma.w + wh * g.gain.w + g.offset.w) * 1.5);
        // (Shadows' colour grows towards black, where the tone curve's toe would hide a small push.)
        float deep = 1.0 + 3.6 * (1.0 - min(uY / mid, 1.0));
        float3 push = pushOnly(ws * deep * g.lift.rgb + wm * g.gamma.rgb + wh * g.gain.rgb + 0.6 * g.offset.rgb);
        float3 out = gradeC(pushed(gradeU(lit, g.gradeR), push * 0.08), g.gradeR);
        return toPro * (fromRec2020 * keepLight(out, luma2020(lit), uY));
    }

    // Lift, Gamma, Gain and Offset, as DaVinci Resolve's primaries, per channel in the grading space: Lift moves black with
    // white held, Gain white with black held, Gamma the middle with both held, Offset all of it evenly (in stops). Each
    // colour push leaves the brightness as the masters make it.
    inline float3 lggo(float3 u, float3 L, float3 G, float3 P, float3 O) {
        float3 v = u + L * (1.0 - min(u, 1.0));
        v *= G;
        v = select(v, pow(max(v, 1e-12), P), v > 0.0);
        return v + O;
    }
    inline float3 primaries5(float3 c, constant Grade &g) {
        float3 r = toRec2020 * (fromPro * c), u = gradeU(r, g.gradeR);
        float3 masters = lggo(u, float3(g.pLift.w * 0.2), float3(exp2(g.pGain.w * 0.5)), float3(exp2(-g.pGamma.w * 0.8)), float3(g.pOffset.w * 0.15));
        float3 coloured = lggo(u, g.pLift.w * 0.2 + pushOnly(g.pLift.rgb) * 0.4, exp2(g.pGain.w * 0.5 + pushOnly(g.pGain.rgb) * 0.4),
                               exp2(-g.pGamma.w * 0.8 - pushOnly(g.pGamma.rgb) * 0.6), g.pOffset.w * 0.15 + pushOnly(g.pOffset.rgb) * 0.1);
        float3 out = gradeC(pushed(masters, coloured - masters), g.gradeR), m = gradeC(masters, g.gradeR);
        return toPro * (fromRec2020 * keepLight(out, luma2020(m), gradeU(float3(luma2020(m)), g.gradeR).x));
    }

    // Process 5's colour mixer, on the picture as shown (after the tone curve, so a band is the colour seen and picked):
    // OkLCh; each band all of its own hue and none of its neighbours' (raised cosine between centres); the strength by
    // C/L, which doesn't change with exposure; Luminance ±1 stop at full strength, its colourfulness scaled with it (the
    // colour kept), easing into white instead of past it.
    inline float3 mixer5(float3 c, constant Grade &g, float top, bool pro) {
        float3 o = oklab(pro ? fromPro * c : c);
        float C = length(o.yz), L = o.x;
        if (C < 1e-5 || L <= 1e-4) return c;
        float h = atan2(o.z, o.y) * 57.29578;
        if (h < 25.0) h += 360.0;
        const float centres[9] = {25, 60, 105, 145, 195, 255, 300, 345, 385};
        int i = 0;
        for (int k = 1; k < 8; k++) if (h >= centres[k]) i = k;
        float a = cos((h - centres[i]) / (centres[i + 1] - centres[i]) * 1.5707963);
        a *= a;
        int j = (i + 1) % 8;
        float dh = a * g.hue[i] + (1.0 - a) * g.hue[j], ds = a * g.sat[i] + (1.0 - a) * g.sat[j], dl = a * g.lum[i] + (1.0 - a) * g.lum[j];
        float w = min(C / max(L, 0.03) / 0.08, 1.0);
        float hr = (h + dh * 0.3 * w) * 0.01745329;
        float L1 = L * exp2(dl * 0.01 * w / 3.0), room = max(scbrt(top) - L, 0.0);
        if (L1 > L) L1 = L + (L1 - L) * room / (room + L1 - L);
        float C1 = C * max(0.0, 1.0 + ds * 0.01 * w) * (L1 / L);
        float3 out = fromOklab(float3(L1, C1 * cos(hr), C1 * sin(hr)));
        return pro ? toPro * out : out;
    }

    // Process 5's colour points: how much of a point (its hue, C/L, L and Range in `pt`) this colour gets: a soft step
    // down in each of hue (15…60° wide by Range), saturation (in stops of C/L) and lightness; full in the inner third.
    // A grey has no hue to measure, so only its saturation and lightness count.
    inline float pointWeight(float h, float s, float L, float4 pt) {
        float d = fmod(abs(h - pt.x), 360.0);
        if (d > 180.0) d = 360.0 - d;
        float wh = 15.0 + 45.0 * pt.w, ws = 0.4 + 1.6 * pt.w, wl = 0.08 + 0.32 * pt.w;
        float fh = mix(1.0, 1.0 - smoothstep(0.3 * wh, wh, d), smoothstep(0.0, 0.04, min(s, pt.y)));
        float fs = 1.0 - smoothstep(0.3 * ws, ws, abs(log2((s + 0.02) / (pt.y + 0.02))));
        float fl = 1.0 - smoothstep(0.3 * wl, wl, abs(L - pt.z));
        return fh * fs * fl;
    }
    // One of the colour tools' tables (256 steps along an axis, `axis` 0…1), read smoothly between steps.
    inline float4 toolTable(constant float4 *t, float axis) {
        float at = clamp(axis, 0.0, 1.0) * 255.0;
        int i = min(int(at), 254);
        return mix(t[i], t[i + 1], at - float(i));
    }
    // Process 5's colour points and colour curves (PhotoEngine.colourTools: `t`), on the picture as shown (linear sRGB
    // numbers, after the mixer), in OkLCh with C/L as saturation (the same at any exposure). Each point and curve is read
    // from the colour as it came in, so they don't chain; a hue turn and a saturation scale, and a lightness change in stops
    // with the colourfulness scaled with it (its colour kept), easing into white instead of past it. Greys keep their hue
    // (the hue curves fade out under C/L 0.05).
    inline float3 colourTools5(float3 c, constant float4 *t, float top) {
        float3 o = oklab(c);
        float L = o.x, C = length(o.yz);
        if (L <= 1e-4) return c;
        float h = atan2(o.z, o.y) * 57.29578;
        if (h < 0.0) h += 360.0;
        float s = C / max(L, 0.03);
        float dh = 0.0, scale = 1.0, stops = 0.0, marked = 0.0;
        int n = min(int(t[0].y), 8);
        for (int k = 0; k < n; k++) {
            float w = pointWeight(h, s, L, t[513 + 2 * k]);
            float4 shift = t[514 + 2 * k];
            dh += shift.x * w; scale *= max(0.0, 1.0 + shift.y * w); stops += shift.z * w;
            if (k == int(t[0].z)) marked = w;
        }
        if (t[0].x > 0.0) {
            float grey = smoothstep(0.0, 0.05, s);
            float4 byHue = toolTable(t + 1, h / 360.0);
            dh += byHue.x * grey;
            scale *= mix(1.0, byHue.y, grey) * toolTable(t + 1, L).w * toolTable(t + 257, s / 0.6).x;
            stops += byHue.z * grey;
        }
        if (t[0].w > 1.5) {
            // The Colour Warper (72 hues × 16 C/L steps, read smoothly; grey, at C/L 0, is unchanged).
            constant float4 *w = t + 529;
            float hf = h / 5.0, sf = min(s / 0.6, 1.0) * 15.0;
            int h0 = int(hf) % 72, h1 = (h0 + 1) % 72, s0 = min(int(sf), 14);
            float fh = hf - floor(hf), fs = sf - float(s0);
            float2 e = mix(mix(w[h0 * 16 + s0].xy, w[h0 * 16 + s0 + 1].xy, fs), mix(w[h1 * 16 + s0].xy, w[h1 * 16 + s0 + 1].xy, fs), fh);
            dh += e.x; scale *= e.y;
        }
        float L1 = L * exp2(stops / 3.0), room = max(scbrt(top) - L, 0.0);
        if (L1 > L) L1 = L + (L1 - L) * room / (room + L1 - L);
        float C1 = C * max(scale, 0.0) * (L1 / L), hr = (h + dh) * 0.01745329;
        float3 out = fromOklab(float3(L1, C1 * cos(hr), C1 * sin(hr)));
        // (The point being looked at, shown in red as a mask is.)
        return t[0].z >= 0.0 ? mix(out, float3(1.0, 0.12, 0.1), 0.6 * marked) : out;
    }

    // Version 2, after the local tone: grading in scene light (Rec.2020), the mixer, vibrance and
    // saturation (OkLCh), the gamut compression, the tone curve and profile, then the curves.
    // Version 3 (`p.space` 1) does all of it in linear ProPhoto, as Lightroom: colours past sRGB are kept (only what's
    // outside ProPhoto is brought in), the tone curve and the curves keep hue (RGBTone), and the picture goes out still
    // wide, for the gamut mapping to the screen's or the file's colours (PhotoRender.output).
    inline float3 finish(float3 c, constant Params &p, constant Grade &g, constant float4 *curve, constant float4 *hs) {
        bool pro = p.space == 1;
        if (pro) c = toPro * c;
        if (pro && ((p.hueSat == 1 && p.scene == 0) || p.hueSat == 2)) c = hueSatMap(c, hs);
        if (p.shadowTint != 0) c = tintShadows(c, p.shadowTint, pro ? lumaPro(c) : luma(c));
        if (!pro) c = toRec2020 * c;
        if (g.wheels != 0) {
            // Balance moves where shadows end and highlights begin; Blending widens or narrows both ranges.
            float e = log2(max(pro ? lumaPro(c) : luma2020(c), 1e-6) / 0.18) + g.balance;
            float shadow = 1.0 - smoothstep(-2.0 - 2.5 * g.blend, -2.0 + 2.5 * g.blend, e);
            float light = smoothstep(1.5 - 2.0 * g.blend, 1.5 + 2.0 * g.blend, e);
            float3 ev = g.offset.rgb * 0.5 + g.offset.w + shadow * (g.lift.rgb * 0.7 + g.lift.w * 1.5)
                      + light * (g.gain.rgb * 0.7 + g.gain.w * 1.5);
            c *= exp2(ev);
            // Midtones: a power around mid grey, per channel.
            float3 power = exp2(-0.8 * (g.gamma.w + g.gamma.rgb * 0.75));
            c = select(c, 0.18 * pow(max(c, 0.0) / 0.18, power), c > 0.0);
        }
        if (!pro) c = fromRec2020 * c;
        if (g.primaries5 != 0) c = primaries5(c, g);
        if (g.wheels5 != 0) c = wheels5(c, g);
        if (g.mixer != 0 || g.vibrance != 0 || g.saturation != 0) {
            // (OkLab is the same colours whatever the RGB they're written in.)
            float3 o = oklab(pro ? fromPro * c : c);
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
            if (pro) c = toPro * c;
        }
        // A finished picture shown as shot keeps its colours; everything else is brought inside (version 3: inside
        // ProPhoto, which only touches colours no eye sees, such as the decoder's near-black noise).
        bool asShot = p.profile == 5 && p.isRaw == 0;
        // (Process 5: a finished picture keeps its tone and colours under any profile; see pictureTone.)
        bool picture = asShot || (p.v5 == 1 && p.isRaw == 0);
        c = picture ? max(c, 0.0) : pro ? compressGamut(c, float3(0.97), float3(1.15)) : compressGamut(c);
        float3 scene = c;
        if (p.scene == 1) {
            if (p.hueSat == 3) c = float3(lumaPro(c));
            // (The film reads sRGB light: its own space, so version 3's is brought into sRGB for it here.)
            if (pro) c = compressGamut(fromPro * c);
            // The film makes its own curve from this light, so what the tone curve does without film happens here
            // first: Contrast steepens (or flattens) the stops around mid grey, Whites moves the brightest stops and
            // Blacks the darkest (gently enough that the light never turns back down).
            float stops = log2(max(luma(c), 1e-6) / 0.18);
            float shaped = stops * (1.0 + p.contrast * (p.contrast > 0 ? 0.6 : 0.4)) + p.whites * smoothstep(0.5, 3.5, stops)
                         + p.blacks * 1.2 * (1.0 - smoothstep(-8.0, -3.0, stops));
            c *= exp2(shaped - stops);
            return min(c, 64.0);
        }

        float3 outc;
        if (picture) {
            outc = pro ? min(c, p.peak) : clamp(c, 0.0, 1.0);
            if (p.v5 == 1) {
                float3 v = p.mono != 0 ? float3(pro ? lumaPro(outc) : luma(outc)) : outc;
                float mx = max(v.r, max(v.g, v.b)), mn = min(v.r, min(v.g, v.b));
                outc = rgbTone(v, pictureTone(mx, p), pictureTone(mn, p));
                float Y2 = pro ? lumaPro(outc) : luma(outc);
                outc = p.mono != 0 ? float3(Y2) : max(Y2 + (outc - Y2) * p.sat, 0.0);
            }
        } else if (pro && p.tro == 1 && p.mono == 0) {
            // Accurate: the brightness through the curve (Classic's), each colour's chromaticity kept (RGB curves as gains at
            // its brightness); near white the colour fades smoothly to white at its brightness, so whites end white.
            float Y = max(lumaPro(c), 1e-10), t = toneLight(Y * 1.15, p);
            float Yt = t > 1.0 ? t : curveLight(t, 1, curve);
            outc = max(c, 0.0) * (Yt / Y);
            if (p.curves == 1) outc *= float3(curveLight(t, 0, curve), Yt, curveLight(t, 2, curve)) / max(Yt, 1e-10);
            outc = towardsWhite(outc, p);
            // (Process 5: and white once the light is past the curve's white, as the old fade's overflow happened to make it.)
            if (p.v5 == 1) outc = mix(outc, float3(lumaPro(outc)), smoothstep(p.toneHi - 1.0, p.toneHi, log2(Y * 1.15)));
        } else if (pro) {
            // (Each channel first held at the curve's white, as the DNG SDK's RGBTone clamps: a tinted white past it is white.)
            float3 v = min((p.mono != 0 ? float3(lumaPro(c)) : c) * 1.15, exp2(p.toneHi));
            outc = rgbTone(v, toneLight(max(v.r, max(v.g, v.b)), p), toneLight(min(v.r, min(v.g, v.b)), p));
            float Y2 = lumaPro(outc);
            outc = p.mono != 0 ? float3(Y2) : max(Y2 + (outc - Y2) * p.sat, 0.0);
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
            outc = pow(clamp(v, 0.0, pow(p.peak, 1.0 / 2.2)), 2.2);
            float Y2 = luma(outc);
            outc = p.mono != 0 ? float3(Y2) : max(Y2 + (outc - Y2) * p.sat, 0.0);
        }
        // The curves, on the picture (sRGB steps; version 3 on ProPhoto in sRGB steps, as Lightroom's), as in Lightroom.
        // (HDR: what's brighter than white keeps its light; the curves shape up to white.) (Accurate has them already.)
        if (p.tro == 1 && p.mono == 0) {
        } else if (p.curves == 2) {
            // One curve for all three (no red, green or blue curve of its own): through RGBTone, so the hue holds.
            float mx = max(outc.r, max(outc.g, outc.b)), mn = min(outc.r, min(outc.g, outc.b));
            float3 toned = rgbTone(outc, curveLight(mx, 0, curve), curveLight(mn, 0, curve));
            outc = select(toned, outc, float3(mx) > 1.0);
        } else if (p.curves != 0) {
            float3 bright = outc;
            float3 e = select(1.055 * pow(clamp(outc, 0.0, 1.0), 1.0 / 2.4) - 0.055, outc * 12.92, outc <= 0.0031308);
            float3 at = clamp(e, 0.0, 1.0) * 127.0;
            int3 i0 = int3(floor(at)), i1 = min(i0 + 1, 127);
            float3 f = at - float3(i0);
            float3 lo = float3(curve[i0.r].r, curve[i0.g].g, curve[i0.b].b), hi = float3(curve[i1.r].r, curve[i1.g].g, curve[i1.b].b);
            e = mix(lo, hi, f);
            outc = select(pow((e + 0.055) / 1.055, 2.4), e / 12.92, e <= 0.04045);
            outc = select(outc, bright, bright > 1.0);
        }
        // Classic, in the shadows: the light's own colour at the curves' brightness, as Adobe's renderer keeps ratios
        // through its curve. Per channel the toe makes dark colours more colourful (measured on a lifted shadow: red
        // to green 0.42 in the light, 0.29 on screen against Lightroom's 0.48) and turns their noise into coloured specks.
        // Version 3's RGBTone profiles keep each colour's own hue (OkLab) through the curves: RGBTone keeps ProPhoto's HSV hue,
        // which isn't the eye's (bright blues went purple, darkening reds magenta).
        if (p.tro == 2 && p.mono == 0) {
            float3 so = oklab(fromPro * scene), to = oklab(fromPro * outc);
            float Cs = length(so.yz);
            if (Cs > 1e-6) outc = toPro * fromOklab(float3(to.x, so.yz * (length(to.yz) / Cs)));
        }
        // (Process 5: not for Neutral and Flat, which never had it and now keep their hue as tro 2. Kept separate from process
        // 4's line so its pixels stay exactly as they were.)
        if (p.v5 == 1) {
            if ((p.profile == 6 || p.tro == 2) && !picture && p.profile != 0 && p.profile != 3) {
                float Yo = pro ? lumaPro(outc) : luma(outc), Yc = pro ? lumaPro(scene) : luma(scene);
                float3 kept = Yc > 1e-7 ? scene * (Yo / Yc) : float3(Yo);
                outc = mix(outc, kept, 1.0 - smoothstep(0.02, 0.3, Yo));
            }
        } else if ((p.profile == 6 || p.tro == 2) && !asShot) {
            float Yo = pro ? lumaPro(outc) : luma(outc), Yc = pro ? lumaPro(scene) : luma(scene);
            float3 kept = Yc > 1e-7 ? scene * (Yo / Yc) : float3(Yo);
            outc = mix(outc, kept, 1.0 - smoothstep(0.02, 0.3, Yo));
        }
        if (g.mixer5 != 0) outc = mixer5(outc, g, p.peak, pro);
        if (g.hsvSaturation != 0 || g.hsvVibrance != 0) outc = hsvSaturation(outc, g, pro);
        // (Version 3: back in the engine's linear sRGB numbers, colours past sRGB as they are.)
        return pro ? fromPro * clamp(outc, 0.0, p.peak) : clamp(outc, 0.0, p.peak);
    }

    // The picture's colours brought inside the file's or screen's (`g.x` 1: Display P3, else sRGB; `g.y` the brightest it
    // goes), as perceptual rendering does: in OkLCh, the lightness and hue kept, the colourfulness eased from 90% of
    // what fits towards the edge (where it was as far out as ProPhoto reaches, it lands on the edge), nothing clipped.
    inline bool fits(float3 lab, float3x3 to, float top) {
        float3 t = to * fromOklab(lab);
        return all(t >= -1e-4) && all(t <= top + 1e-4);
    }
    inline float reach(float L, float2 dir, float C, float3x3 to, float top) {
        float lo = 0.0, hi = C;
        for (int i = 0; i < 14; i++) { float mid = 0.5 * (lo + hi); if (fits(float3(L, dir * mid), to, top)) lo = mid; else hi = mid; }
        return lo;
    }
    kernel void gamutMap(texture2d<float, access::read> src [[texture(0)]],
                         texture2d<float, access::write> dst [[texture(1)]],
                         constant float2 &g [[buffer(0)]],
                         constant int2 *offsets [[buffer(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 px = src.read(at(gid, offsets[0], uint2(src.get_width(), src.get_height())));
        const float3x3 toP3 = float3x3(float3(0.8225481, 0.0331828, 0.0170010), float3(0.1773356, 0.9669250, 0.0723893),
                                       float3(0.0001162, -0.0001078, 0.9106097));
        float3x3 to = g.x > 0.5 ? toP3 : float3x3(1.0);
        float top = g.y;
        float3 o = oklab(px.rgb);
        float L = clamp(o.x, 0.0, scbrt(top)), C = length(o.yz);
        const float knee = 0.9;
        float3 out = px.rgb;
        if (L <= 0.0) {
            out = float3(0.0);
        } else if (C > 1e-5 && !fits(float3(L, o.yz / knee), to, top)) {
            float2 dir = o.yz / C;
            // How far this hue reaches at this lightness here, and in ProPhoto (the most the engine holds).
            float edge = reach(L, dir, C / knee, to, top), wide = max(reach(L, dir, max(C, 0.5), toPro, top), edge * 1.0001);
            float r = C / max(edge, 1e-6), lim = wide / max(edge, 1e-6);
            if (r > knee && edge > 1e-6) {
                float u = min((r - knee) / max(lim - knee, 1e-6), 1.0), m = (lim - knee) / (1.0 - knee);
                r = knee + (1.0 - knee) * m * u / (1.0 + (m - 1.0) * u);
                out = fromOklab(float3(L, dir * r * edge));
            } else {
                out = fromOklab(float3(L, edge > 1e-6 ? o.yz : float2(0.0)));
            }
        } else if (o.x != L) {
            out = fromOklab(float3(L, o.yz));
        }
        // (What's left over at the edge, from the halving: a hair, into the space exactly.)
        float3 t = clamp(to * out, 0.0, top);
        out = g.x > 0.5 ? float3x3(float3(1.2247995, -0.0420347, -0.0195253), float3(-0.2246165, 1.0419060, -0.0786332),
                                   float3(-0.0001829, 0.0001287, 1.0981585)) * t : t;
        dst.write(float4(out, px.a), gid);
    }

    // A mask's place in the mask layer and what limits it besides its shape.
    struct MaskInfo {
        float4 m0, m1, m2;      // its white balance and exposure, as matrix columns
        float4 lum;             // brightness range: low, high, smooth, on
        float4 col;             // colour range: hue, width, on, invert the whole mask
    };

    // Version 3's Shadows (raising them), as Lightroom's: up to 2.3 stops, all of it from about 2 stops under mid grey down
    // (the lower mid-tones too, not only the darkest), easing to nothing at mid grey; never steep enough to turn the
    // light over. `t`: the large base, in stops from mid grey. (Measured on a RAW against Lightroom's +100.)
    inline float shadowLift(float t, constant Params &p) {
        return p.shadows * 2.3 / (1.0 + exp((t + 0.9) / 0.65));
    }

    // The local tone (shadows, highlights, clarity, texture) as the new log brightness.
    // `Lg`: the brightness the layers follow (see guideColour), `L` the pixel's own.
    // What version 3's Shadows lifts by: the large base, except where it dips under what's around it (a crease, a fold's
    // shadow in something bright), up to a stop: there the place around counts, so the fold keeps its shadow. Never the
    // other way (something bright beside a dark place keeps its own base: no bright halo). The place around: from the
    // edge-following base (a = v/(v+0.03)) the variance is found again and weighed against 1 instead, the rest from the
    // plain mean (`al.z`).
    inline float liftBase(float Lg, float3 al, constant Params &p) {
        float a = clamp(al.x, 0.0, 0.999), v = a * 0.03 / (1.0 - a), a2 = v / (v + 1.0);
        float t = al.x * Lg + al.y + (1.0 - al.x) * p.shift - log2(0.18);
        float around = a2 * Lg + (1.0 - a2) * (al.z + p.shift) - log2(0.18);
        return t + clamp(around - t, 0.0, 1.0);
    }

    inline float tonedLog(float L, float Lg, float3 al, float2 as, constant Params &p) {
        // b moves with the exposure the layers were made without: (1 − a)·shift.
        float baseL = al.x * Lg + al.y + (1.0 - al.x) * p.shift;
        float baseS = as.x * Lg + as.y + (1.0 - as.x) * p.shift;
        float detail = L - baseS, mid = baseS - baseL;
        // Local tone, on the large base, in stops from mid grey. Highlights compress (or stretch)
        // what's above mid grey, shadows what's below: the curve always keeps rising, so nothing
        // turns over into halos or grey skies, however far it goes.
        float t = baseL - log2(0.18);
        // (Version 3 darkens half as much: its −100 is Lightroom's; at 0.62 the upper mid-tones came out 0.3 stop dimmer and
        // the brightest still coloured, a flat shoulder.)
        float kh = p.highlights < 0 ? 1.0 + p.highlights * (p.space == 1 ? 0.31 : 0.62) : 1.0 + p.highlights * 0.45;
        float ks = p.shadows > 0 ? 1.0 - p.shadows * 0.6 : 1.0 - p.shadows * 0.5;
        float above = t - 0.6, below = t + 0.4;
        float softAbove = above > 8.0 ? above : log(1.0 + exp(above));
        float softBelow = below < -8.0 ? below : -log(1.0 + exp(-below));
        float base = baseL + (kh - 1.0) * softAbove + (p.space == 1 && p.shadows > 0 ? shadowLift(liftBase(Lg, al, p), p) : (ks - 1.0) * softBelow);
        // Process 4, lowering Highlights: the stops more than 2¼ over mid grey brought down further (0.6 more at −100, eased in
        // over about a stop), as Lightroom's −100 does with a window: every profile but Neutral is on Adobe's curve, which shows
        // anything over 2.5 stops as white, so a window brought down only by the even compression above stayed white there
        // (Neutral's own shoulder showed it). The detail rides on the base, so the window keeps its texture; the base still
        // always rises; the lawn and the upper mid-tones (Lightroom's mid grey) hardly move.
        if (p.v4 == 1 && p.highlights < 0) { float top = (t - 2.25) * 2.0; base += p.highlights * 0.3 * (top > 16.0 ? top : log(1.0 + exp(top))); }
        float midWeight = 1.0 - abs(smoothstep(-6.0, 3.0, base - log2(0.18)) * 2.0 - 1.0);
        // (Version 2 does clarity itself, on the soft layer: see developModern.)
        float strength = p.process < 2 ? p.clarity : 0.0;
        float clarity = 1.0 + strength * (strength > 0 ? 0.9 : 0.85) * (0.35 + 0.65 * midWeight);
        return base + mid * (clarity + (p.process < 2 ? p.dehaze * 0.6 : 0.0)) + detail * (1.0 + p.texture * 0.9);
    }

    // Process 5's Dehaze, one colour: the haze taken out of its brightness only (no channel goes below zero or flips to the
    // haze's opposite colour), Y' = Y - (1/through - 1)(A - Y) up to the haze's brightness (brighter, a lamp, is left as it is),
    // as a gain on all three channels, never under 0.3 (soft); then a little more colour where there was haze.
    inline float3 dehazed(float3 c, float AY, float through, float boost) {
        float Y = max(luma(c), 1e-4);
        float k = (Y - (1.0 / through - 1.0) * (AY - min(Y, AY))) / Y;
        k = 0.5 * (k + 0.3 + sqrt((k - 0.3) * (k - 0.3) + 0.01));
        c *= k;
        float Yk = luma(c);
        return Yk + (c - Yk) * boost;
    }

    // Process 5's Glow on the picture: `light` the glow's (scene light, see PhotoEngine.glowLight) as the screen would show
    // it, laid on as a compositor's blend modes: Add, Screen and Lighten in display light, Overlay and Soft Light in screen
    // steps with the glow on mid grey (where there's none, nothing changes, and dark parts stay dark).
    inline float3 glowed(float3 c, float3 light, constant Params &p) {
        float3 gl = 1.0 - exp(-max(light, 0.0) * (1.5 * p.glow / (p.isRaw == 1 ? 2.0 : 1.0)));
        float3 a = clamp(c, 0.0, 1.0), over = c - a, r;
        if (p.glowMode == 0) r = a + gl;
        else if (p.glowMode == 1) r = 1.0 - (1.0 - a) * (1.0 - gl);
        else if (p.glowMode == 2) r = max(a, gl);
        else {
            float3 A = pow(a, 1.0 / 2.2), B = 0.5 + 0.5 * pow(gl, 1.0 / 2.2), R;
            if (p.glowMode == 3) R = select(1.0 - 2.0 * (1.0 - A) * (1.0 - B), 2.0 * A * B, A < 0.5);
            else {
                float3 D = select(sqrt(A), ((16.0 * A - 12.0) * A + 4.0) * A, A <= 0.25);
                R = select(A + (2.0 * B - 1.0) * (D - A), A - (1.0 - 2.0 * B) * A * (1.0 - A), B <= 0.5);
            }
            r = pow(R, 2.2);
        }
        return min(r + over, p.peak);
    }

    // Version 2, one pixel: dehaze, local tone, then the rest (finish). `t`: how much light gets
    // through the haze there.
    inline float3 developModern(float3 c, float3 cg, float3 al, float2 as, float t, float3 soft, float3 wide,
                                constant Params &p, constant Grade &g, constant float4 *curve, constant float4 *hs) {
        float L = log2(max(luma(c), 1e-5)), Lg = log2(max(luma(cg), 1e-5));
        // Dehaze: the haze taken out (or added) in scene light, from how much of the light got
        // through (the dark channel prior); the layers then work on what's left.
        if (p.dehaze != 0 && p.v5 == 1) {
            float3 A = float3(p.hazeR, p.hazeG, p.hazeB);
            if (p.dehaze > 0) {
                float through = mix(1.0, max(t, 0.2), p.dehaze * 0.8), boost = 1.0 + 0.35 * p.dehaze * (1.0 - t);
                float AY = max(luma(A), 1e-4);
                c = dehazed(c, AY, through, boost);
                cg = dehazed(cg, AY, through, boost);
            } else {
                // A veil of the haze's (neutral-ish, lamp-free) colour, more where there's already some. (Written as mix so the
                // compiler can't share it with process 4's same line: sharing moved process 4's pixels by one step.)
                float veil = -0.22 * p.dehaze * (1.0 - 0.5 * t);
                c = mix(c, A, veil);
                cg = mix(cg, A, veil);
            }
            float Ld = log2(max(luma(cg), 1e-5));
            al.y += (Ld - Lg) * (1.0 - al.x);
            as.y += (Ld - Lg) * (1.0 - as.x);
            L = log2(max(luma(c), 1e-5)); Lg = Ld;
        } else if (p.dehaze != 0) {
            float3 A = float3(p.hazeR, p.hazeG, p.hazeB);
            if (p.dehaze > 0) {
                float through = mix(1.0, max(t, 0.2), p.dehaze * 0.8);
                c = (c - A) / through + A;
                cg = (cg - A) / through + A;
            } else {
                // More haze where there's already some (far away), less up close.
                float through = 1.0 + 0.22 * p.dehaze * (1.0 - 0.5 * t);
                c = c * through + A * (1.0 - through);
                cg = cg * through + A * (1.0 - through);
            }
            float Ld = log2(max(luma(cg), 1e-5));
            // The layers' base follows the change, so it isn't undone as detail.
            al.y += (Ld - Lg) * (1.0 - al.x);
            as.y += (Ld - Lg) * (1.0 - as.x);
            L = log2(max(luma(c), 1e-5)); Lg = Ld;
        }
        float Lp = tonedLog(L, Lg, al, as, p);
        // Version 3: what Shadows lifts gets less colourful as it comes up, as in Lightroom (a lifted warm floor: blue to
        // green 0.33 there, 0.08 with its colour kept whole), rather than dark colours coming out deep and green.
        // (By hue: warm colours, as that floor, the most; cool ones, as a teal pot in the shade, keep much more: Lightroom's
        // pot red to green 0.16, here 0.44 when all lost alike.)
        if (p.space == 1 && p.shadows > 0) {
            // (The hue of the colour around, and only where there is one: noise in a grey has every hue, and would get a cast.)
            float Y = luma(c);
            float3 o = oklab(cg);
            float C = length(o.yz), warm = C > 1e-7 ? dot(o.yz / C, float2(0.5, 0.866)) : 1.0;
            float k = mix(1.0, mix(0.15, 1.0, smoothstep(-0.2, 0.5, warm)), smoothstep(0.03, 0.08, C / max(o.x, 1e-4)));
            c = Y + (c - Y) * exp2(-0.28 * k * shadowLift(liftBase(Lg, al, p), p));
        }
        // Clarity: the contrast against a soft copy of the photo (about 2% of its size), less only in
        // the extremes; a third of its base follows the edges, so it doesn't halo.
        if (p.clarity != 0) {
            float baseL = al.x * Lg + al.y + (1.0 - al.x) * p.shift;
            float local = L - mix(log2(max(luma(soft), 1e-5)), baseL, 0.35);
            // Full from 2 stops under mid grey to 2 over, easing to half at 7 (deep shadows, light sources): skies and
            // shadows get it too.
            float w = 1.0 - 0.5 * smoothstep(2.0, 7.0, abs(Lp - log2(0.18)));
            Lp += local * p.clarity * (p.clarity > 0 ? 0.7 : 0.4) * w;
        }
        c *= exp2(Lp - L);
        // Below zero, a mist filter as well: a soft veil over the picture and the highlights
        // blooming into what's around them (as a diffusion filter on the lens).
        if (p.clarity < 0) {
            float k = -p.clarity;
            float3 bloom = wide * smoothstep(0.25, 2.5, luma(wide));
            c = mix(c, soft, 0.22 * k) + bloom * 0.45 * k;
        }
        return finish(c, p, g, curve, hs);
    }

    // Process 5, one pixel (developModern's own copy, so the earlier processes' code stays exactly as it was): Dehaze v5,
    // local tone, Texture without noise, Clarity v5, then finish. `t`: how much light gets
    // through the haze there.
    inline float3 developModern5(float3 c, float3 cg, float3 al, float2 as, float t, float3 soft, float3 wide,
                                constant Params &p, constant Grade &g, constant float4 *curve, constant float4 *hs, constant float4 *tools) {
        float L = log2(max(luma(c), 1e-5)), Lg = log2(max(luma(cg), 1e-5));
        // Dehaze: the haze taken out (or added) in scene light, from how much of the light got
        // through (the dark channel prior); the layers then work on what's left.
        if (p.dehaze != 0) {
            float3 A = float3(p.hazeR, p.hazeG, p.hazeB);
            if (p.dehaze > 0) {
                float through = mix(1.0, max(t, 0.2), p.dehaze * 0.8), boost = 1.0 + 0.35 * p.dehaze * (1.0 - t);
                float AY = max(luma(A), 1e-4);
                c = dehazed(c, AY, through, boost);
                cg = dehazed(cg, AY, through, boost);
            } else {
                // A veil of the haze's (neutral-ish, lamp-free) colour, more where there's already some. (Written as mix so the
                // compiler can't share it with process 4's same line: sharing moved process 4's pixels by one step.)
                float veil = -0.22 * p.dehaze * (1.0 - 0.5 * t);
                c = mix(c, A, veil);
                cg = mix(cg, A, veil);
            }
            float Ld = log2(max(luma(cg), 1e-5));
            al.y += (Ld - Lg) * (1.0 - al.x);
            as.y += (Ld - Lg) * (1.0 - as.x);
            wide.y += (Ld - Lg) * (1.0 - wide.x);
            L = log2(max(luma(c), 1e-5)); Lg = Ld;
        }
        float Lp = tonedLog(L, Lg, al, as, p);
        // Process 5's Texture, raising: kept only where the place (5×5, `wide.z`: its spread in stops²) has more going on
        // than the photo's noise there (σ² = a·Y + b): a flat sky's grain stays as it is, a fabric's weave gets it all.
        // (tonedLog raised all of it; what the noise doesn't allow is taken back here, so tonedLog stays as it was.)
        if (p.texture > 0 && p.noiseB > 0) {
            float Ys = max(exp2(Lg) / p.noiseGain, 1e-6), n = (p.noiseA * Ys + p.noiseB) / (Ys * Ys) * 2.0813;
            float keep = smoothstep(1.2, 2.2, wide.z / n), smallBase = fma(as.x, Lg - p.shift, as.y + p.shift);
            Lp -= (1.0 - keep) * 0.9 * p.texture * (L - smallBase);
        }
        // Version 3: what Shadows lifts gets less colourful as it comes up, as in Lightroom (a lifted warm floor: blue to
        // green 0.33 there, 0.08 with its colour kept whole), rather than dark colours coming out deep and green.
        // (By hue: warm colours, as that floor, the most; cool ones, as a teal pot in the shade, keep much more: Lightroom's
        // pot red to green 0.16, here 0.44 when all lost alike.)
        if (p.space == 1 && p.shadows > 0) {
            // (The hue of the colour around, and only where there is one: noise in a grey has every hue, and would get a cast.)
            float Y = luma(c);
            float3 o = oklab(cg);
            float C = length(o.yz), warm = C > 1e-7 ? dot(o.yz / C, float2(0.5, 0.866)) : 1.0;
            float k = mix(1.0, mix(0.15, 1.0, smoothstep(-0.2, 0.5, warm)), smoothstep(0.03, 0.08, C / max(o.x, 1e-4)));
            c = Y + (c - Y) * exp2(-0.28 * k * shadowLift(liftBase(Lg, al, p), p));
        }
        // Clarity: the contrast against a soft copy of the photo (about 2% of its size), less only in
        // the extremes; a third of its base follows the edges, so it doesn't halo.
        // Process 5's Clarity: the place's own contrast against an edge-following base in log brightness (its own guided
        // filter, eps 0.3 stop², in `wide`: across a real edge the base keeps to the pixel, so nothing bright darkens or
        // lights what's beside it), from the 5×5 light (noise is Texture's). Less towards the extremes; lowering it doesn't
        // lift the deepest shadows.
        // (Written apart from the earlier processes' lines, so the compiler can't share them: that moved their pixels.)
        if (p.clarity != 0) {
            float local = Lg - fma(wide.x, Lg - p.shift, wide.y + p.shift);
            float w5 = fma(-0.5, smoothstep(2.0, 7.0, fabs(Lp + 2.4739312)), 1.0);
            if (p.clarity < 0) w5 *= smoothstep(-11.4739312, -7.4739312, Lg);
            Lp = fma(local * p.clarity * (p.clarity > 0 ? 0.8 : 0.6), w5, Lp);
        }
        c *= exp2(Lp - L);
        float3 out = finish(c, p, g, curve, hs);
        // Then the colour points and curves, on the picture as shown (not the film's light: they're off then).
        if (tools[0].w > 0.0) out = fromPro * clamp(toPro * colourTools5(out, tools, p.peak), 0.0, p.peak);
        return out;
    }

    // The colour the local-tone layers follow here: the pixels around (5×5) within about a stop of this one, averaged
    // in linear light. With the pixel alone, its noise is in the gain (darker specks lifted more, and as they're mostly
    // low green, lifted shadows turn into magenta and green blotches); across an edge nothing is mixed in, so no halo.
    inline float3 guideColour(texture2d<float, access::read> image, uint2 gid, int2 offset, float3 c, bool positive) {
        uint2 size = uint2(image.get_width(), image.get_height());
        float box = 0;
        for (int y = -2; y <= 2; y++) for (int x = -2; x <= 2; x++) {
            float3 n = image.read(at(gid, offset + int2(x, y), size)).rgb;
            box += luma(positive ? max(n, 0.0) : n);
        }
        // (A speck at or below black is measured against what's around it, not itself.)
        float ref = log2(max(max(luma(c), box / 25.0 / 16.0), 1e-5));
        float3 sum = 0.0;
        float weights = 0.0;
        for (int y = -2; y <= 2; y++) for (int x = -2; x <= 2; x++) {
            float3 n = image.read(at(gid, offset + int2(x, y), size)).rgb;
            if (positive) n = max(n, 0.0);
            float d = log2(max(luma(n), 1e-5)) - ref;
            float w = exp(-0.5 * d * d);
            sum += w * n; weights += w;
        }
        return weights > 1e-20 ? sum / weights : c;
    }

    kernel void develop(texture2d<float, access::read> image [[texture(0)]],
                        texture2d<float, access::sample> large [[texture(1)]],
                        texture2d<float, access::sample> small [[texture(2)]],
                        texture2d<float, access::sample> haze [[texture(3)]],
                        texture2d<float, access::sample> masks [[texture(4)]],
                        texture2d<float, access::sample> glow [[texture(5)]],
                        texture2d<float, access::write> dst [[texture(6)]],
                        constant Params *ps [[buffer(0)]],
                        constant int2 *offsets [[buffer(1)]],
                        constant float4 *map [[buffer(2)]],
                        constant Grade *gs [[buffer(3)]],
                        constant float4 *curve [[buffer(4)]],
                        constant MaskInfo *info [[buffer(5)]],
                        constant float4 *hs [[buffer(6)]],
                        uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        constant Params &p = ps[0];
        constexpr sampler smooth(coord::normalized, address::clamp_to_edge, filter::linear);
        float3 c = image.read(at(gid, offsets[0], uint2(image.get_width(), image.get_height()))).rgb;
        // Version 1 had no colours past sRGB; version 2 keeps them until the gamut compression.
        if (p.process < 2) c = max(c, 0.0);
        float Y = max(luma(c), 1e-5);
        float L = log2(Y);
        float3 cg = guideColour(image, gid, offsets[0], c, p.process < 2);
        // Where this pixel is in the photo, then in each small layer's texture.
        float2 pos = float2(map[0].x + float(gid.x) + 0.5, map[0].y - float(gid.y) - 0.5);
        float2 t1 = float2(map[1].x * pos.x + map[1].y, map[1].z * pos.y + map[1].w);
        float2 t2 = float2(map[2].x * pos.x + map[2].y, map[2].z * pos.y + map[2].w);
        float2 uv1 = t1 / float2(large.get_width(), large.get_height()), uv2 = t2 / float2(small.get_width(), small.get_height());
        float3 al = large.sample(smooth, uv1).rgb;
        float2 as = small.sample(smooth, uv2).rg;
        if (p.process >= 2) {
            float2 t3 = float2(map[3].x * pos.x + map[3].y, map[3].z * pos.y + map[3].w);
            float through = haze.sample(smooth, t3 / float2(haze.get_width(), haze.get_height())).r;
            // The soft layer here, and wider (around this place) for the mist's bloom.
            float2 t5 = float2(map[5].x * pos.x + map[5].y, map[5].z * pos.y + map[5].w) / float2(glow.get_width(), glow.get_height());
            float3 soft = glow.sample(smooth, t5).rgb * p.glowGain;
            float reach = 0.035;
            float3 wide = soft;
            for (int i = 0; i < 8; i++) {
                float angle = float(i) * 0.785398;
                float2 o = float2(cos(angle), sin(angle)) * reach * float2(1.0, float(glow.get_width()) / float(max(glow.get_height(), 1u)));
                wide += glow.sample(smooth, t5 + o).rgb * p.glowGain;
            }
            wide /= 9.0;
            float3 out = developModern(c, cg, al, as, through, soft, wide, p, gs[0], curve, hs);
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
                    float3x3 change = float3x3(m.m0.xyz, m.m1.xyz, m.m2.xyz);
                    out = mix(out, developModern(change * c, change * cg, al, as, through, change * soft, change * wide, ps[k + 1], gs[k + 1], curve, hs), w);
                }
                // The mask being edited, shown in red.
                if (p.overlay >= 0) out = mix(out, float3(1.0, 0.12, 0.1), 0.5 * marked);
            }
            dst.write(float4(out, 1.0), gid);
            return;
        }
        float Lp = tonedLog(L, log2(max(luma(cg), 1e-5)), al, as, p);
        c *= exp2(Lp - L);
        if (p.dehaze != 0) {
            float haze = 0.03 * p.dehaze;
            c = max((c - haze * 0.18) / (1.0 - haze), 0.0);
        }

        if (p.shadowTint != 0) c = tintShadows(c, p.shadowTint, luma(c));
        // Contrast (around mid grey) and whites (the brightest stops), in scene light (the film's too).
        float flat = p.profile == 3 && p.scene == 0 ? 0.78 : 1.0;
        float contrast = flat * (1.0 + p.contrast * (p.contrast > 0 ? 0.55 : 0.45));
        float Yc = max(luma(c), 1e-6);
        float stops = log2(Yc / 0.18);
        float shaped = stops * contrast + p.whites * 1.2 * smoothstep(0.5, 3.5, stops);
        c *= exp2(shaped - stops);
        if (p.scene == 1) { dst.write(float4(min(c, 64.0), 1.0), gid); return; }

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

    // Process 5's own kernel (develop's copy: a change in develop's code moved earlier processes' pixels): Clarity's
    // guided layer as texture 6, Texture's 5×5 spread, developModern5, Glow.
    kernel void develop5(texture2d<float, access::read> image [[texture(0)]],
                        texture2d<float, access::sample> large [[texture(1)]],
                        texture2d<float, access::sample> small [[texture(2)]],
                        texture2d<float, access::sample> haze [[texture(3)]],
                        texture2d<float, access::sample> masks [[texture(4)]],
                        texture2d<float, access::sample> glow [[texture(5)]],
                        texture2d<float, access::sample> clear [[texture(6)]],
                        texture2d<float, access::write> dst [[texture(7)]],
                        constant Params *ps [[buffer(0)]],
                        constant int2 *offsets [[buffer(1)]],
                        constant float4 *map [[buffer(2)]],
                        constant Grade *gs [[buffer(3)]],
                        constant float4 *curve [[buffer(4)]],
                        constant MaskInfo *info [[buffer(5)]],
                        constant float4 *hs [[buffer(6)]],
                        constant float4 *tools [[buffer(7)]],
                        uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        constant Params &p = ps[0];
        constexpr sampler smooth(coord::normalized, address::clamp_to_edge, filter::linear);
        float3 c = image.read(at(gid, offsets[0], uint2(image.get_width(), image.get_height()))).rgb;
        // Version 1 had no colours past sRGB; version 2 keeps them until the gamut compression.
        if (p.process < 2) c = max(c, 0.0);
        float Y = max(luma(c), 1e-5);
        float L = log2(Y);
        float3 cg = guideColour(image, gid, offsets[0], c, p.process < 2);
        // Where this pixel is in the photo, then in each small layer's texture.
        float2 pos = float2(map[0].x + float(gid.x) + 0.5, map[0].y - float(gid.y) - 0.5);
        float2 t1 = float2(map[1].x * pos.x + map[1].y, map[1].z * pos.y + map[1].w);
        float2 t2 = float2(map[2].x * pos.x + map[2].y, map[2].z * pos.y + map[2].w);
        float2 uv1 = t1 / float2(large.get_width(), large.get_height()), uv2 = t2 / float2(small.get_width(), small.get_height());
        float3 al = large.sample(smooth, uv1).rgb;
        float2 as = small.sample(smooth, uv2).rg;
        if (p.process >= 2) {
            float2 t3 = float2(map[3].x * pos.x + map[3].y, map[3].z * pos.y + map[3].w);
            float through = haze.sample(smooth, t3 / float2(haze.get_width(), haze.get_height())).r;
            // The soft layer here, and wider (around this place) for the mist's bloom.
            float2 t5 = float2(map[5].x * pos.x + map[5].y, map[5].z * pos.y + map[5].w) / float2(glow.get_width(), glow.get_height());
            float3 soft = glow.sample(smooth, t5).rgb * p.glowGain;
            float reach = 0.035;
            float3 wide = soft;
            for (int i = 0; i < 8; i++) {
                float angle = float(i) * 0.785398;
                float2 o = float2(cos(angle), sin(angle)) * reach * float2(1.0, float(glow.get_width()) / float(max(glow.get_height(), 1u)));
                wide += glow.sample(smooth, t5 + o).rgb * p.glowGain;
            }
            wide /= 9.0;
            // Process 5's Clarity base (its own guided filter), carried in `wide`'s place, which only the mist uses.
            {
                float2 t6 = float2(map[6].x * pos.x + map[6].y, map[6].z * pos.y + map[6].w) / float2(clear.get_width(), clear.get_height());
                wide = float3(clear.sample(smooth, t6).rg, 0.0);
                // (With Texture: the spread of the log light over the 5×5 here, for the noise check.)
                if (p.noiseB > 0) {
                    uint2 size = uint2(image.get_width(), image.get_height());
                    float s1 = 0, s2 = 0;
                    for (int y = -2; y <= 2; y++) for (int x = -2; x <= 2; x++) {
                        float l = log2(max(luma(image.read(at(gid, offsets[0] + int2(x, y), size)).rgb), 1e-5));
                        s1 += l; s2 += l * l;
                    }
                    wide.z = max(s2 / 25.0 - (s1 / 25.0) * (s1 / 25.0), 0.0);
                }
            }
            float3 out = developModern5(c, cg, al, as, through, soft, wide, p, gs[0], curve, hs, tools);
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
                    float3x3 change = float3x3(m.m0.xyz, m.m1.xyz, m.m2.xyz);
                    out = mix(out, developModern5(change * c, change * cg, al, as, through, change * soft, wide, ps[k + 1], gs[k + 1], curve, hs, tools), w);
                }
                // The mask being edited, shown in red.
                if (p.overlay >= 0) out = mix(out, float3(1.0, 0.12, 0.1), 0.5 * marked);
            }
            // Process 5's Glow, on the picture the masks made too (the same for each).
            if (p.glow > 0) out = glowed(out, soft, p);
            dst.write(float4(out, 1.0), gid);
            return;
        }
        float Lp = tonedLog(L, log2(max(luma(cg), 1e-5)), al, as, p);
        c *= exp2(Lp - L);
        if (p.dehaze != 0) {
            float haze = 0.03 * p.dehaze;
            c = max((c - haze * 0.18) / (1.0 - haze), 0.0);
        }

        if (p.shadowTint != 0) c = tintShadows(c, p.shadowTint, luma(c));
        // Contrast (around mid grey) and whites (the brightest stops), in scene light (the film's too).
        float flat = p.profile == 3 && p.scene == 0 ? 0.78 : 1.0;
        float contrast = flat * (1.0 + p.contrast * (p.contrast > 0 ? 0.55 : 0.45));
        float Yc = max(luma(c), 1e-6);
        float stops = log2(Yc / 0.18);
        float shaped = stops * contrast + p.whites * 1.2 * smoothstep(0.5, 3.5, stops);
        c *= exp2(shaped - stops);
        if (p.scene == 1) { dst.write(float4(min(c, 64.0), 1.0), gid); return; }

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

    // The vignette's highlights and style, and grain (see PhotoRender.effects).
    struct Effects {
        float highlights, grain, size, rough, scale, ox, oy;
        int paint;
    };

    inline float grainHash(int2 q) {
        uint h = uint(q.x) * 374761393u + uint(q.y) * 668265263u;
        h = (h ^ (h >> 13)) * 1274126177u;
        return float(h ^ (h >> 16)) * (2.0 / 4294967295.0) - 1.0;
    }

    // Value noise: a random number at each corner of a grid, smoothly in between.
    inline float grainNoise(float2 p) {
        float2 i = floor(p), f = p - i;
        f = f * f * (3.0 - 2.0 * f);
        int2 q = int2(i);
        return mix(mix(grainHash(q), grainHash(q + int2(1, 0)), f.x), mix(grainHash(q + int2(0, 1)), grainHash(q + int2(1, 1)), f.x), f.y);
    }

    // One octave of grain `cell` full-size pixels wide, seen at `scale`: grains smaller than a pixel average out.
    inline float grainOctave(float2 p, float cell, float scale) {
        return grainNoise(p / max(cell, 1.0 / scale)) * min(cell * scale, 1.0);
    }

    kernel void effects(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::read> mask [[texture(1)]],
                        texture2d<float, access::write> dst [[texture(2)]],
                        constant Effects &e [[buffer(0)]],
                        constant float2 &origin [[buffer(1)]],
                        constant int2 *offsets [[buffer(2)]],
                        uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 px = src.read(at(gid, offsets[0], uint2(src.get_width(), src.get_height())));
        float m = mask.read(at(gid, offsets[1], uint2(mask.get_width(), mask.get_height()))).r;
        float3 c = px.rgb;
        float v = pow(clamp(luma(c), 0.0, 1.0), 1.0 / 2.2);
        // Highlights: where the vignette darkens, the brightest parts keep (some of) their light.
        if (m < 1.0) m = mix(m, 1.0, e.highlights * smoothstep(0.5, 1.0, v));
        if (e.paint != 0 && m > 1.0) {
            // Paint overlay: lighter edges mix towards white (in picture steps) rather than brightening the light.
            c = pow(mix(pow(max(c, 0.0), 1.0 / 2.2), float3(1.0), 1.0 - 1.0 / m), 2.2);
        } else {
            c *= m;
        }
        if (e.grain > 0) {
            // Where the pixel is on the photo at full size, so the grain keeps its size and place in any render.
            float2 p = (float2(origin.x + gid.x + 0.5, origin.y - gid.y - 0.5) - float2(e.ox, e.oy)) / e.scale;
            float n = grainOctave(p, e.size, e.scale) + e.rough * grainOctave(p + 17.0, e.size * 0.5, e.scale);
            n /= sqrt(1.0 + e.rough * e.rough);
            // Strongest in the midtones, as film grain looks.
            float w = 4.0 * v * (1.0 - v);
            c *= exp2(e.grain * n * w);
        }
        dst.write(float4(c, px.a), gid);
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
            let at = i < offsetsAt ? i : i + 1
            // (Metal takes up to 4 KB as bytes; more, as a buffer: a profile's table.)
            if data.count > 4096 {
                encoder.setBuffer(data.withUnsafeBytes { buffer.device.makeBuffer(bytes: $0.baseAddress!, length: data.count) }, offset: 0, index: at)
            } else {
                data.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: data.count, index: at) }
            }
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

    static func upload(_ input: CIImageProcessorInput, device: MTLDevice) -> MTLTexture? {
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
                                      haze: made.haze.map { (render($0.through), $0.airlight) }, glow: made.glow.map(render),
                                      clarity: made.clarity.map(render))
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
    func render(_ image: CIImage) -> CIImage {
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

/// The vignette's shape and grain (see PhotoRender.effects).
final class EffectsPass: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAh }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect { outputRect }
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        let origin = [Float(output.region.minX), Float(output.region.maxY)].withUnsafeBytes { Data($0) }
        try PhotoEngine.run("effects", inputs: inputs, output: output, bytes: [(arguments?["effects"] as? Data) ?? Data(count: 32), origin])
    }
}

/// The gamut mapping to the file's or screen's colours (see gamutMap in the shaders).
final class GamutPass: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAh }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect { outputRect }
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        try PhotoEngine.run("gamutMap", inputs: inputs, output: output, bytes: [(arguments?["gamut"] as? Data) ?? Data(count: 8)])
    }
}

/// Local tone and the profile.
final class DevelopPass: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAh }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }
    /// The photo where the output is (and 2 pixels around, for guideColour); the two small layers whole.
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        if input == 0 { return outputRect.insetBy(dx: -2, dy: -2) }
        // (As numbers: Core Image moves rectangles it finds among the arguments.)
        guard let sizes = arguments?["layers"] as? [Double], sizes.count == 24 || sizes.count == 28 else { return outputRect }
        let i = Int(input - 1) * 4
        return CGRect(x: sizes[i], y: sizes[i + 1], width: sizes[i + 2], height: sizes[i + 3])
    }
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        // Where each pixel falls in the two layers' textures: texel = (sx·x + bx, sy·y + by) from
        // the photo's coordinates (y up) to the textures' (y down, from the piece handed over).
        guard let inputs, inputs.count == 6 || inputs.count == 7, let sizes = arguments?["layers"] as? [Double], sizes.count == inputs.count * 4 else {
            throw NSError(domain: "Pluck", code: 11)
        }
        let n = sizes.count - 4
        let photo = CGRect(x: sizes[n], y: sizes[n + 1], width: sizes[n + 2], height: sizes[n + 3])
        var map = [SIMD4<Float>(Float(output.region.minX), Float(output.region.maxY), 0, 0)]
        for layer in 0..<(inputs.count - 1) {
            let extent = CGRect(x: sizes[layer * 4], y: sizes[layer * 4 + 1], width: sizes[layer * 4 + 2], height: sizes[layer * 4 + 3])
            let region = inputs[layer + 1].region
            let sx = extent.width / photo.width, sy = extent.height / photo.height
            map.append(SIMD4(Float(sx), Float(extent.minX - photo.minX * sx - region.minX),
                             Float(-sy), Float(region.maxY - extent.minY + photo.minY * sy)))
        }
        let bytes = map.withUnsafeBytes { Data($0) }
        try PhotoEngine.run(inputs.count == 7 ? "develop5" : "develop", inputs: inputs, output: output,
                            bytes: [(arguments?["params"] as? Data) ?? Data(), bytes, (arguments?["grade"] as? Data) ?? Data(),
                                    (arguments?["curves"] as? Data) ?? Data(count: 16), (arguments?["masks"] as? Data) ?? Data(count: 96),
                                    (arguments?["table"] as? Data) ?? Data(count: 16)] + (inputs.count == 7 ? [(arguments?["tools"] as? Data) ?? Data(count: 16)] : []),
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
    /// any channel red, shadows at black in all of them blue. `peak`: the brightest an HDR edit
    /// goes (clipped is at that, not at white).
    static func clipping(_ image: CIImage, peak: Double = 1) -> CIImage {
        let extent = image.extent
        let brightest = image.applyingFilter("CIMaximumComponent")
        let highlights = brightest.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.997 * max(peak, 1)])
        let shadows = brightest.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.0004]).applyingFilter("CIColorInvert")
        let red = CIImage(color: CIColor(red: 1, green: 0.1, blue: 0.1)).cropped(to: extent)
        let blue = CIImage(color: CIColor(red: 0.15, green: 0.35, blue: 1)).cropped(to: extent)
        return blue.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: red.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: highlights]),
            kCIInputMaskImageKey: shadows,
        ]).cropped(to: extent)
    }

    /// A version 3 picture (still wide: ProPhoto's colours in linear sRGB numbers) brought inside Display P3 (`p3`) or sRGB,
    /// up to `peak`, keeping each colour's lightness and hue (gamutMap).
    static func gamutMapped(_ image: CIImage, p3: Bool, peak: Double = 1) -> CIImage {
        let data = [Float(p3 ? 1 : 0), Float(max(peak, 1))].withUnsafeBytes { Data($0) }
        // (An empty picture, say from a file that couldn't be read, crashes the kernel: passed through.)
        guard !image.extent.isInfinite, !image.extent.isEmpty, let mapped = try? apply(GamutPass.self, extent: image.extent, inputs: [image], arguments: ["gamut": data])
        else { return image }
        return mapped
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
