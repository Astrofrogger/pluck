import CoreImage
import Foundation
import Metal

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

    // MARK: - Developing

    /// The picture from a decoded photo (linear light, white at 1, brighter kept above 1).
    /// `isRaw`: a neutral RAW decode (the profile makes the picture); otherwise a finished
    /// picture (JPEG, HEIC), where As Shot leaves its look alone.
    /// `scene`: stop before the profile and give scene light (for the film engine, which makes
    /// its own picture from it).
    static func develop(_ image: CIImage, _ a: PhotoAdjustments, isRaw: Bool, asShotKelvin: Double = 5500, scene: Bool = false) -> CIImage {
        let extent = image.extent
        var image = image
        // 1. Exposure and white balance: one matrix in linear light.
        let gain = pow(2, a.exposure)
        let m = whiteBalance(a, kelvin: asShotKelvin).map { $0 * gain }
        image = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: m[0], y: m[1], z: m[2], w: 0),
            "inputGVector": CIVector(x: m[3], y: m[4], z: m[5], w: 0),
            "inputBVector": CIVector(x: m[6], y: m[7], z: m[8], w: 0),
        ])
        // No negative light (and a step Core Image always runs on the GPU: a photo straight from
        // memory isn't handed to the passes below otherwise).
        image = image.applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
                                                                   "inputMaxComponents": CIVector(x: 64, y: 64, z: 64, w: 1)])
        // 2–3. Local tone and the profile, in one pass, from two base layers.
        let long = max(extent.width, extent.height)
        let large = guide(image, scale: 640 / long, radius: 16, eps: 0.03)
        let small = guide(image, scale: 1600 / long, radius: 6, eps: 0.02)
        var p = Params()
        p.shadows = Float(a.shadows / 100)
        p.highlights = Float(a.highlights / 100)
        p.whites = Float(a.whites / 100)
        p.blacks = Float(a.blacks / 100)
        p.contrast = Float(a.contrast / 100)
        p.clarity = Float(a.clarity / 100)
        p.texture = Float(a.texture / 100)
        p.dehaze = Float(a.dehaze / 100)
        let profile = a.profile ?? (isRaw ? .neutral : .asShot)
        p.profile = Int32(PhotoEngine.Profile.allCases.firstIndex(of: profile == .asShot && isRaw ? .standard : profile) ?? 0)
        p.isRaw = isRaw ? 1 : 0
        p.scene = scene ? 1 : 0
        let inputs = [image.clampedToExtent(),
                      large.transformed(by: CGAffineTransform(scaleX: long / 640, y: long / 640)).clampedToExtent(),
                      small.transformed(by: CGAffineTransform(scaleX: long / 1600, y: long / 1600)).clampedToExtent()]
        let data = withUnsafeBytes(of: p) { Data($0) }
        guard let developed = try? DevelopPass.apply(withExtent: extent, inputs: inputs, arguments: ["params": data]) else { return image }
        return developed.cropped(to: extent)
    }

    /// The guided filter's coefficients (a, b) for the log brightness, worked out small: the
    /// base layer is a·L + b, which follows edges instead of blurring over them.
    private static func guide(_ image: CIImage, scale: Double, radius: Double, eps: Float) -> CIImage {
        let s = min(scale, 1)
        // Properly filtered: a sampled one would be noisy on a full-size photo.
        let small = s < 0.5 ? image.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": s, "inputAspectRatio": 1])
                            : image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let extent = small.extent.integral
        guard let prepared = try? GuidePrep.apply(withExtent: extent, inputs: [small.clampedToExtent()], arguments: [:]) else { return small }
        let means = prepared.clampedToExtent().applyingFilter("CIBoxBlur", parameters: ["inputRadius": radius]).cropped(to: extent)
        let epsData = withUnsafeBytes(of: eps) { Data($0) }
        guard let coef = try? GuideCoef.apply(withExtent: extent, inputs: [means.clampedToExtent()], arguments: ["eps": epsData]) else { return small }
        return coef.clampedToExtent().applyingFilter("CIBoxBlur", parameters: ["inputRadius": radius]).cropped(to: extent)
    }

    // MARK: - White balance

    /// A Bradford adaptation in linear sRGB that makes what's white under the chosen light white:
    /// for RAW the light is in Kelvin (from the camera's as-shot value), otherwise relative.
    static func whiteBalance(_ a: PhotoAdjustments, kelvin asShot: Double) -> [Double] {
        guard a.temperature != 0 || a.tint != 0 else { return [1, 0, 0, 0, 1, 0, 0, 0, 1] }
        let from = asShot, to = kelvin(a, asShot: asShot)
        let s = lms(chromaticity(kelvin: from, tint: 0)), t = lms(chromaticity(kelvin: to, tint: a.tint))
        let d = [s[0] / t[0], s[1] / t[1], s[2] / t[2]]
        // XYZ → sRGB · Bradford⁻¹ · diag · Bradford · sRGB → XYZ
        let toXYZ = [0.4124, 0.3576, 0.1805, 0.2126, 0.7152, 0.0722, 0.0193, 0.1192, 0.9505]
        let fromXYZ = [3.2406, -1.5372, -0.4986, -0.9689, 1.8758, 0.0415, 0.0557, -0.2040, 1.0570]
        let brad = [0.8951, 0.2664, -0.1614, -0.7502, 1.7135, 0.0367, 0.0389, -0.0685, 1.0296]
        let bradInv = [0.9870, -0.1471, 0.1600, 0.4323, 0.5184, 0.0493, -0.0085, 0.0400, 0.9685]
        let diag = [d[0], 0, 0, 0, d[1], 0, 0, 0, d[2]]
        return multiply(fromXYZ, multiply(bradInv, multiply(diag, multiply(brad, toXYZ))))
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

    private static func lms(_ xy: (Double, Double)) -> [Double] {
        let (x, y) = xy
        let X = x / y, Y = 1.0, Z = (1 - x - y) / y
        return [0.8951 * X + 0.2664 * Y - 0.1614 * Z, -0.7502 * X + 1.7135 * Y + 0.0367 * Z, 0.0389 * X - 0.0685 * Y + 1.0296 * Z]
    }

    private static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        var r = [Double](repeating: 0, count: 9)
        for i in 0..<3 { for j in 0..<3 { r[i * 3 + j] = (0..<3).reduce(0) { $0 + a[i * 3 + $1] * b[$1 * 3 + j] } } }
        return r
    }

    // MARK: - The GPU passes

    struct Params {
        var shadows: Float = 0, highlights: Float = 0, whites: Float = 0, blacks: Float = 0
        var contrast: Float = 0, clarity: Float = 0, texture: Float = 0, dehaze: Float = 0
        var profile: Int32 = 0, isRaw: Int32 = 0, scene: Int32 = 0
    }

    static let shaders = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct Params {
        float shadows, highlights, whites, blacks;
        float contrast, clarity, texture, dehaze;
        int profile, isRaw, scene;
    };

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

    kernel void develop(texture2d<float, access::read> image [[texture(0)]],
                        texture2d<float, access::read> large [[texture(1)]],
                        texture2d<float, access::read> small [[texture(2)]],
                        texture2d<float, access::write> dst [[texture(3)]],
                        constant Params &p [[buffer(0)]],
                        constant int2 *offsets [[buffer(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float3 c = max(image.read(at(gid, offsets[0], uint2(image.get_width(), image.get_height()))).rgb, 0.0);
        float Y = max(luma(c), 1e-5);
        float L = log2(Y);
        float2 al = large.read(at(gid, offsets[1], uint2(large.get_width(), large.get_height()))).rg, as = small.read(at(gid, offsets[2], uint2(small.get_width(), small.get_height()))).rg;
        float baseL = al.x * L + al.y;
        float baseS = as.x * L + as.y;
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
        // Dehaze: deeper local contrast and blacks where it's bright and flat.
        float midWeight = 1.0 - abs(smoothstep(-6.0, 3.0, base - log2(0.18)) * 2.0 - 1.0);
        float clarity = 1.0 + p.clarity * (p.clarity > 0 ? 0.9 : 0.85) * (0.35 + 0.65 * midWeight);
        float Lp = base + mid * (clarity + p.dehaze * 0.6) + detail * (1.0 + p.texture * 0.9);
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

    /// Runs one compute function over the output, with the inputs at the same place.
    static func run(_ name: String, inputs: [CIImageProcessorInput]?, output: CIImageProcessorOutput, bytes: [Data] = []) throws {
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
        for (i, data) in bytes.enumerated() {
            data.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: data.count, index: i) }
        }
        // Each input's offset from the output (in the textures' top-down rows).
        var offsets: [SIMD2<Int32>] = (inputs ?? []).map { input in
            SIMD2(Int32(output.region.minX.rounded(.down) - input.region.minX.rounded(.down)),
                  Int32(input.region.maxY.rounded(.up) - output.region.maxY.rounded(.up)))
        }
        if offsets.isEmpty { offsets = [.zero] }
        encoder.setBytes(&offsets, length: MemoryLayout<SIMD2<Int32>>.stride * offsets.count, index: bytes.count)
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
    override class func formatForInput(at input: Int32) -> CIFormat { input == 0 ? .RGBAh : .RGBAf }
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect { outputRect }
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        try PhotoEngine.run("develop", inputs: inputs, output: output, bytes: [(arguments?["params"] as? Data) ?? Data()])
    }
}

// MARK: - Histogram and Auto

extension PhotoEngine {
    /// Red, green and blue counts in 64 steps, from a developed picture (made small first).
    static func histogram(_ image: CGImage) -> [[Float]] {
        let width = 256, height = max(1, Int(Double(image.height) * 256 / Double(max(image.width, 1))))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var bins = [[Float]](repeating: [Float](repeating: 0, count: 64), count: 3)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            bins[0][Int(pixels[i]) / 4] += 1
            bins[1][Int(pixels[i + 1]) / 4] += 1
            bins[2][Int(pixels[i + 2]) / 4] += 1
        }
        let top = max(bins.flatMap { $0.dropFirst().dropLast() }.max() ?? 1, 1)
        return bins.map { $0.map { min($0 / top, 1) } }
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
