import CoreImage
import Foundation
import Metal

/// Where a render sits on the photo at full size, so the spatial stages (halation, coupler
/// diffusion, grain, scan sharpening) keep their real size in a smaller preview or a crop.
struct FilmGeometry: Hashable, Sendable {
    /// The photo's long side at full size, in pixels.
    var fullLongEdge: Int
    /// The render's size over the full size (1 at full size, less for a preview).
    var renderScale: Double
    /// This render's top-left pixel on the photo at full size, in full-size pixels from the photo's
    /// top-left corner, rows counted down (for a crop). The grain is keyed to it.
    var fullOrigin: CGPoint

    init(fullLongEdge: Int, renderScale: Double = 1, fullOrigin: CGPoint = .zero) {
        self.fullLongEdge = fullLongEdge; self.renderScale = renderScale; self.fullOrigin = fullOrigin
    }

    /// A render of the whole photo at its own size.
    init(full extent: CGRect) {
        self.init(fullLongEdge: Int(max(extent.width, extent.height).rounded()))
    }

    /// The render scale as the spatial stages use it: never above 1.
    var scale: Double { min(max(renderScale, 1e-6), 1) }
    /// Micrometres of film per full-size pixel, for a film frame `filmFormatMM` long.
    func fullPitchUM(filmFormatMM: Double) -> Double { filmFormatMM * 1000 / Double(max(fullLongEdge, 1)) }
    /// Micrometres of film per pixel of this render.
    func renderPitchUM(filmFormatMM: Double) -> Double { fullPitchUM(filmFormatMM: filmFormatMM) / scale }
    /// A render pixel's position in full-size pixels.
    func fullPosition(_ point: CGPoint) -> CGPoint {
        CGPoint(x: fullOrigin.x + point.x / scale, y: fullOrigin.y + point.y / scale)
    }
}

/// The film's colour on the GPU, from the shipped film tables (FilmTables): scene light in, the
/// finished print or scan out, both linear sRGB. It follows the recipe in
/// docs/superpowers/specs/2026-11-04-film-tables-format.md §5, interpolating the raw table nodes
/// itself (the hardware's filtering is too coarse). The spatial stages slot in between the three
/// stages: halation and coupler diffusion after `expose`, grain after `develop`, scan blur and
/// sharpening after `printStage`.
enum FilmLook {
    /// The whole chain in one pass: the fused colour pass while no spatial stage is on, else
    /// FilmHalation's chain, with halation and scatter after step 2, the coupler diffusion inside
    /// step 4–5, the grain on the density after step 5 and the scan blur and sharpening at the end (it
    /// gives what the stages below give, run one after another: expose, FilmHalation.apply, develop,
    /// FilmGrain.apply, printStage, FilmHalation.scan).
    /// The stock decides scanned or printed: for `scan_film` = 1 (or no paper) the caller passes the stock
    /// made with `paper: nil`. Every stage wants a finite extent (crop first); a failure gives an empty image.
    /// `display`: for the screen (half floats in between in the spatial chain; an export keeps floats).
    static func apply(_ scene: CIImage, stock: FilmStock, settings: FilmSettings, geometry: FilmGeometry, display: Bool = false) -> CIImage {
        let ev = settings.number("exposure_ev") ?? 0
        assert(settings.number("scan_film") != 1 || stock.scanned, "scan_film is on: pass the film's scanned stock (paper nil)")
        assert(stock.constants.bakedExposureEv.map { abs($0 - ev) < 1e-6 } ?? true, "this pair was made for another exposure_ev")
        let params = Params(stock, ev: ev, printEV: settings.number("print_exposure_ev") ?? 0)
        if let filmed = FilmHalation.chain(scene, stock: stock, settings: settings, geometry: geometry, params: params, display: display) { return filmed }
        return run(FilmChainPass.self, scene, stock: stock, params: params)
    }

    /// Steps 1–2: the film's linear exposure (`raw`) from scene light.
    static func expose(_ scene: CIImage, stock: FilmStock, ev: Double) -> CIImage {
        assert(stock.constants.bakedExposureEv.map { abs($0 - ev) < 1e-6 } ?? true, "this pair was made for another exposure_ev")
        return run(FilmExposePass.self, scene, stock: stock, params: Params(stock, ev: ev, printEV: 0))
    }

    /// Steps 3–5: the developed film density from the linear exposure. With `diffuse`, the
    /// coupler correction is worked out as its own image first and blurred (the coupler
    /// diffusion, as the settings ask; identity when they turn it off).
    static func develop(_ raw: CIImage, stock: FilmStock, settings: FilmSettings, geometry: FilmGeometry, diffuse: Bool) -> CIImage {
        let params = Params(stock, ev: 0, printEV: 0)
        guard diffuse else { return run(FilmDevelopPass.self, raw, stock: stock, params: params) }
        let corr = run(FilmCouplersPass.self, raw, stock: stock, params: params)
        let spread = FilmHalation.diffuseCouplers(corr, stock: stock, settings: settings, geometry: geometry)
        return run(FilmDevelopCorrPass.self, raw, spread, stock: stock, params: params)
    }

    /// Steps 6–9 (or the film's own scan): the finished linear sRGB from the film density.
    static func printStage(_ density: CIImage, stock: FilmStock, printEV: Double) -> CIImage {
        run(FilmPrintPass.self, density, stock: stock, params: Params(stock, ev: 0, printEV: printEV))
    }

    // MARK: - Running the passes

    /// The numbers every pass reads (laid out as `FilmParams` in the shader).
    struct Params {
        var m0 = SIMD4<Float>(), m1 = SIMD4<Float>(), m2 = SIMD4<Float>()
        var k0 = SIMD4<Float>(), k1 = SIMD4<Float>(), k2 = SIMD4<Float>()
        var receiveLo = SIMD4<Float>(), receiveHi = SIMD4<Float>(1, 1, 1, 1)
        var exposeLo = SIMD4<Float>(), exposeHi = SIMD4<Float>(1, 1, 1, 1)
        var scanLo = SIMD4<Float>(), scanHi = SIMD4<Float>(1, 1, 1, 1)
        var dlogLo = SIMD4<Float>(), dlogHi = SIMD4<Float>(1, 1, 1, 1)
        var scale: Float = 1, le0: Float = 0, leStep: Float = 1
        var printLe0: Float = 0, printLeStep: Float = 1, printOffset: Float = 0
        var refM: Float = 1, refQ: Float = 0, bwM: Float = 1, bwQ: Float = 0
        var mode: Int32 = 0, scanBw: Int32 = 0

        init(_ stock: FilmStock, ev: Double, printEV: Double) {
            let c = stock.constants, t = stock.textures
            func row(_ m: [Float], _ r: Int) -> SIMD4<Float> { m.count == 9 ? SIMD4(m[3 * r], m[3 * r + 1], m[3 * r + 2], 0) : SIMD4() }
            func four(_ v: SIMD3<Float>) -> SIMD4<Float> { SIMD4(v, 0) }
            m0 = row(c.exposeM, 0); m1 = row(c.exposeM, 1); m2 = row(c.exposeM, 2)
            k0 = row(c.couplerM, 0); k1 = row(c.couplerM, 1); k2 = row(c.couplerM, 2)
            receiveLo = four(t.receiveRange.lo); receiveHi = four(t.receiveRange.hi)
            scanLo = four(t.scanRange.lo); scanHi = four(t.scanRange.hi)
            if let range = t.printExposeRange { exposeLo = four(range.lo); exposeHi = four(range.hi) }
            if let range = t.paperScanDlogRange { dlogLo = four(range.lo); dlogHi = four(range.hi) }
            let s = stock.scanned ? (c.scanEvScale0 ?? c.evScale0) : c.evScale0
            scale = Float(s * pow(2, ev.isFinite ? ev : 0))
            le0 = Float(c.le0); leStep = Float(c.leStep)
            printLe0 = Float(c.printLe0 ?? 0); printLeStep = Float(c.printLeStep ?? 1)
            printOffset = Float((c.printLogOffset0 ?? 0) + (printEV.isFinite ? printEV : 0) * log10(2.0))
            refM = Float(c.scanRefM ?? 1); refQ = Float(c.scanRefQ ?? 0)
            bwM = Float(c.scanBwM ?? 1); bwQ = Float(c.scanBwQ ?? 0)
            scanBw = c.scanBw == true ? 1 : 0
            mode = stock.scanned ? 0 : stock.hasPairScan ? 1 : 2
        }

        var data: Data { withUnsafeBytes(of: self) { Data($0) } }
    }

    /// One pass over the first input's extent. The stock travels in the arguments, so it lives as long as the image.
    private static func run(_ kernel: CIImageProcessorKernel.Type, _ inputs: CIImage..., stock: FilmStock, params: Params) -> CIImage {
        guard let first = inputs.first, !first.extent.isEmpty else { return .empty() }
        guard !first.extent.isInfinite else { assertionFailure("the film needs a finite extent: crop first"); return .empty() }
        let arguments: [String: Any] = ["stock": StockBox(stock), "params": params.data]
        return (try? PhotoEngine.apply(kernel, extent: first.extent, inputs: inputs, arguments: arguments)) ?? .empty()
    }

    /// A stock as a pass argument (Core Image keeps the arguments with the image).
    final class StockBox: NSObject, @unchecked Sendable {
        let stock: FilmStock
        init(_ stock: FilmStock) { self.stock = stock }
    }

    /// The compiled passes (the film's and its blurs), without fast math: the recipe relies on NaN tests and exact clamps.
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
                let options = MTLCompileOptions()
                if #available(macOS 15, *) { options.mathMode = .safe } else { options.fastMathEnabled = false }
                library = try? device.makeLibrary(source: FilmLook.shaders + FilmBlur.shaders + FilmGrain.shaders, options: options)
            }
            guard let function = library?.makeFunction(name: name),
                  let state = try? device.makeComputePipelineState(function: function) else { return nil }
            pipelines[key] = state
            return state
        }
    }

    /// One pass over the output: the inputs (at the same place), then the stock's tables, then the output.
    static func encode(_ name: String, inputs: [CIImageProcessorInput]?, tables: (FilmTextures) -> [MTLTexture],
                       arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let buffer = output.metalCommandBuffer, let target = output.metalTexture,
              let stock = (arguments?["stock"] as? StockBox)?.stock, var params = arguments?["params"] as? Data,
              let state = Library.shared.pipeline(name, device: buffer.device),
              let encoder = buffer.makeComputeCommandEncoder() else {
            throw NSError(domain: "Pluck", code: 10, userInfo: [NSLocalizedDescriptionKey: "The GPU isn't available."])
        }
        encoder.setComputePipelineState(state)
        var index = 0, uploads: [MTLTexture] = []
        for input in inputs ?? [] {
            if let texture = input.metalTexture ?? PhotoEngine.upload(input, device: buffer.device) {
                if input.metalTexture == nil { uploads.append(texture) }
                encoder.setTexture(texture, index: index)
            }
            index += 1
        }
        for texture in tables(stock.textures) { encoder.setTexture(texture, index: index); index += 1 }
        encoder.setTexture(target, index: index)
        if params.count < MemoryLayout<Params>.stride { params.append(Data(count: MemoryLayout<Params>.stride - params.count)) }
        params.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: params.count, index: 0) }
        // Each input's offset from the output (in the textures' top-down rows).
        var offsets: [SIMD2<Int32>] = (inputs ?? []).map { input in
            SIMD2(Int32(output.region.minX.rounded(.down) - input.region.minX.rounded(.down)),
                  Int32(input.region.maxY.rounded(.up) - output.region.maxY.rounded(.up)))
        }
        if offsets.isEmpty { offsets = [.zero] }
        encoder.setBytes(&offsets, length: MemoryLayout<SIMD2<Int32>>.stride * offsets.count, index: 1)
        let width = state.threadExecutionWidth, height = max(state.maxTotalThreadsPerThreadgroup / width, 1)
        encoder.dispatchThreads(MTLSize(width: target.width, height: target.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
        encoder.endEncoding()
        _ = uploads
    }

    /// The print's tables, standing in with tables of the same kind when the film is scanned
    /// (every texture a pass declares is bound; the scanned path never reads these).
    static func printTables(_ t: FilmTextures) -> [MTLTexture] {
        [t.printExpose ?? t.scan, t.printCurves ?? t.curves, t.scan, t.paperScanDlog ?? t.scan]
    }

    // MARK: - The shaders

    static let shaders = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct FilmParams {
        float4 m0, m1, m2;          // expose_m, row by row
        float4 k0, k1, k2;          // coupler_m, row by row
        float4 receiveLo, receiveHi;
        float4 exposeLo, exposeHi;  // print_expose's range (film density)
        float4 scanLo, scanHi;      // the finished-colour table's range
        float4 dlogLo, dlogHi;      // scan_dlog's range
        float scale;                // S · 2^exposure_ev
        float le0, leStep;
        float printLe0, printLeStep;
        float printOffset;          // print_log_offset0 + print_exposure_ev · log10(2)
        float refM, refQ, bwM, bwQ;
        int mode;                   // 0 the film's scan, 1 the pair's scan, 2 the paper's scan rescaled
        int scanBw;
    };

    typedef texture1d<float, access::read> Line;
    typedef texture3d<float, access::read> Cube;

    inline uint2 at(uint2 gid, int2 offset, uint2 size) {
        int2 p = clamp(int2(gid) + offset, int2(0), int2(size) - 1);
        return uint2(p);
    }

    // A fractional index into n nodes: the node below (0…n−2) and the fraction. NaN is node 0.
    inline float2 node(float t, int n) {
        if (isnan(t)) t = 0.0;
        t = clamp(t, 0.0, float(n - 1));
        float i = min(floor(t), float(n - 2));
        return float2(i, t - i);
    }

    inline float lerp1(float a, float b, float f) { return a * (1.0 - f) + b * f; }
    inline float4 lerp4(float4 a, float4 b, float f) { return a * (1.0 - f) + b * f; }

    // Channel c of a 1D table at fractional index t.
    inline float line(Line table, float t, int c) {
        float2 k = node(t, int(table.get_width()));
        uint i = uint(k.x);
        return lerp1(table.read(i)[c], table.read(i + 1)[c], k.y);
    }

    // A 3D table at a density triple, trilinear over the raw nodes.
    inline float4 cube(Cube table, float3 d, float3 lo, float3 hi) {
        int n = int(table.get_width());
        float3 t = (d - lo) / (hi - lo) * float(n - 1);
        float2 x = node(t.x, n), y = node(t.y, n), z = node(t.z, n);
        uint3 p = uint3(uint(x.x), uint(y.x), uint(z.x));
        float4 c00 = lerp4(table.read(p), table.read(p + uint3(1, 0, 0)), x.y);
        float4 c10 = lerp4(table.read(p + uint3(0, 1, 0)), table.read(p + uint3(1, 1, 0)), x.y);
        float4 c01 = lerp4(table.read(p + uint3(0, 0, 1)), table.read(p + uint3(1, 0, 1)), x.y);
        float4 c11 = lerp4(table.read(p + uint3(0, 1, 1)), table.read(p + uint3(1, 1, 1)), x.y);
        return lerp4(lerp4(c00, c10, y.y), lerp4(c01, c11, y.y), z.y);
    }

    // Steps 1–2: scene light to the film's linear exposure.
    inline float3 exposeRaw(float3 rgb, constant FilmParams &p, texture2d<float, access::read> q) {
        float X = dot(p.m0.xyz, rgb), Y = dot(p.m1.xyz, rgb), Z = dot(p.m2.xyz, rgb);
        float b = X + Y + Z;
        float x = X / max(b, 1e-10), y = Y / max(b, 1e-10);
        float u = min(abs(1.0 - x), 1.0), v = clamp(y / max(1.0 - x, 1e-10), 0.0, 1.0);
        int n = int(q.get_width());
        float2 a = node(u * float(n - 1), n), c = node(v * float(int(q.get_height()) - 1), int(q.get_height()));
        uint2 i = uint2(uint(a.x), uint(c.x));
        float4 e = lerp4(lerp4(q.read(i), q.read(i + uint2(1, 0)), a.y),
                         lerp4(q.read(i + uint2(0, 1)), q.read(i + uint2(1, 1)), a.y), c.y);
        float bf = isfinite(b) ? b : 0.0;
        return bf * e.rgb * p.scale;
    }

    inline float3 logExposure(float3 raw) { return log10(max(raw, 0.0) + 1e-10); }

    // Step 4: the coupler correction, from the developed silver.
    inline float3 couplers(float3 le, constant FilmParams &p, Line silver) {
        float3 s;
        for (int c = 0; c < 3; c++) s[c] = line(silver, (le[c] - p.le0) / p.leStep, c);
        return float3(dot(p.k0.xyz, s), dot(p.k1.xyz, s), dot(p.k2.xyz, s));
    }

    // Step 5: the film density, after the inhibitor each channel receives.
    inline float3 density(float3 le, float3 corr, constant FilmParams &p, Line receive, Line curves) {
        float3 d;
        int n = int(receive.get_width());
        for (int c = 0; c < 3; c++) {
            float got = line(receive, (corr[c] - p.receiveLo[c]) / (p.receiveHi[c] - p.receiveLo[c]) * float(n - 1), c);
            d[c] = line(curves, (le[c] - got - p.le0) / p.leStep, c);
        }
        return d;
    }

    // Steps 6–9, or the film's own scan: density to the finished linear sRGB.
    inline float3 printed(float3 d, constant FilmParams &p, Cube expose, Line paper, Cube scan, Cube dlog) {
        if (p.mode == 0) return cube(scan, d, p.scanLo.xyz, p.scanHi.xyz).rgb;
        float3 pe = cube(expose, d, p.exposeLo.xyz, p.exposeHi.xyz).rgb + p.printOffset;
        float3 pd;
        for (int c = 0; c < 3; c++) pd[c] = line(paper, (pe[c] - p.printLe0) / p.printLeStep, c);
        float4 scanned = cube(scan, pd, p.scanLo.xyz, p.scanHi.xyz);
        float3 rgb0 = scanned.rgb;
        if (p.mode == 1) return rgb0;
        // The paper's scan was made under its reference fit: rescale it to this pair's fit
        // (the viewed luminance `scan_y` is in the paper scan's alpha).
        float Yv = scanned.a;
        float ref = clamp(p.refM * Yv + p.refQ, 0.0, 1.0);
        float fit = p.scanBw != 0 ? clamp(p.bwM * Yv + p.bwQ, 0.0, 1.0) : Yv;
        if (!(ref > 0.0) || !(fit > 0.0)) return float3(0.0);
        float rho = fit / ref;
        return rho * rgb0 + log(rho) * cube(dlog, pd, p.dlogLo.xyz, p.dlogHi.xyz).rgb;
    }

    inline float4 pixel(texture2d<float, access::read> src, uint2 gid, int2 offset) {
        return src.read(at(gid, offset, uint2(src.get_width(), src.get_height())));
    }

    // The whole chain in one pass.
    kernel void filmChain(texture2d<float, access::read> src [[texture(0)]],
                          texture2d<float, access::read> q [[texture(1)]],
                          Line silver [[texture(2)]], Line receive [[texture(3)]], Line curves [[texture(4)]],
                          Cube expose [[texture(5)]], Line paper [[texture(6)]], Cube scan [[texture(7)]],
                          Cube dlog [[texture(8)]],
                          texture2d<float, access::write> dst [[texture(9)]],
                          constant FilmParams &p [[buffer(0)]], constant int2 *offsets [[buffer(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 s = pixel(src, gid, offsets[0]);
        float3 le = logExposure(exposeRaw(s.rgb, p, q));
        float3 d = density(le, couplers(le, p, silver), p, receive, curves);
        dst.write(float4(printed(d, p, expose, paper, scan, dlog), s.a), gid);
    }

    kernel void filmExpose(texture2d<float, access::read> src [[texture(0)]],
                           texture2d<float, access::read> q [[texture(1)]],
                           texture2d<float, access::write> dst [[texture(2)]],
                           constant FilmParams &p [[buffer(0)]], constant int2 *offsets [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 s = pixel(src, gid, offsets[0]);
        dst.write(float4(exposeRaw(s.rgb, p, q), s.a), gid);
    }

    kernel void filmDevelop(texture2d<float, access::read> src [[texture(0)]],
                            Line silver [[texture(1)]], Line receive [[texture(2)]], Line curves [[texture(3)]],
                            texture2d<float, access::write> dst [[texture(4)]],
                            constant FilmParams &p [[buffer(0)]], constant int2 *offsets [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 s = pixel(src, gid, offsets[0]);
        float3 le = logExposure(s.rgb);
        dst.write(float4(density(le, couplers(le, p, silver), p, receive, curves), s.a), gid);
    }

    // The coupler correction alone (for the coupler diffusion to blur).
    kernel void filmCouplers(texture2d<float, access::read> src [[texture(0)]],
                             Line silver [[texture(1)]],
                             texture2d<float, access::write> dst [[texture(2)]],
                             constant FilmParams &p [[buffer(0)]], constant int2 *offsets [[buffer(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 s = pixel(src, gid, offsets[0]);
        dst.write(float4(couplers(logExposure(s.rgb), p, silver), 1.0), gid);
    }

    // Step 5 from the exposure and a (blurred) coupler correction.
    kernel void filmDevelopCorr(texture2d<float, access::read> src [[texture(0)]],
                                texture2d<float, access::read> corr [[texture(1)]],
                                Line receive [[texture(2)]], Line curves [[texture(3)]],
                                texture2d<float, access::write> dst [[texture(4)]],
                                constant FilmParams &p [[buffer(0)]], constant int2 *offsets [[buffer(1)]],
                                uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 s = pixel(src, gid, offsets[0]);
        float3 c = pixel(corr, gid, offsets[1]).rgb;
        dst.write(float4(density(logExposure(s.rgb), c, p, receive, curves), s.a), gid);
    }

    kernel void filmPrint(texture2d<float, access::read> src [[texture(0)]],
                          Cube expose [[texture(1)]], Line paper [[texture(2)]], Cube scan [[texture(3)]],
                          Cube dlog [[texture(4)]],
                          texture2d<float, access::write> dst [[texture(5)]],
                          constant FilmParams &p [[buffer(0)]], constant int2 *offsets [[buffer(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 s = pixel(src, gid, offsets[0]);
        dst.write(float4(printed(s.rgb, p, expose, paper, scan, dlog), s.a), gid);
    }
    """#
}

extension FilmSettings {
    /// A changed setting's number (flags as 0 or 1), nil when it's at its default.
    func number(_ key: String) -> Double? {
        switch changed[key] {
        case .number(let value)?: value
        case .flag(let on)?: on ? 1 : 0
        default: nil
        }
    }
}

// MARK: - The passes (Core Image hands each its piece; float in, float out)

class FilmPass: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAf }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect { outputRect }
}

final class FilmChainPass: FilmPass {
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        try FilmLook.encode("filmChain", inputs: inputs, tables: { [$0.exposeQ, $0.silver, $0.receive, $0.curves] + FilmLook.printTables($0) },
                            arguments: arguments, output: output)
    }
}

final class FilmExposePass: FilmPass {
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        try FilmLook.encode("filmExpose", inputs: inputs, tables: { [$0.exposeQ] }, arguments: arguments, output: output)
    }
}

final class FilmDevelopPass: FilmPass {
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        try FilmLook.encode("filmDevelop", inputs: inputs, tables: { [$0.silver, $0.receive, $0.curves] }, arguments: arguments, output: output)
    }
}

final class FilmCouplersPass: FilmPass {
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        try FilmLook.encode("filmCouplers", inputs: inputs, tables: { [$0.silver] }, arguments: arguments, output: output)
    }
}

final class FilmDevelopCorrPass: FilmPass {
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        try FilmLook.encode("filmDevelopCorr", inputs: inputs, tables: { [$0.receive, $0.curves] }, arguments: arguments, output: output)
    }
}

final class FilmPrintPass: FilmPass {
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        try FilmLook.encode("filmPrint", inputs: inputs, tables: FilmLook.printTables, arguments: arguments, output: output)
    }
}
