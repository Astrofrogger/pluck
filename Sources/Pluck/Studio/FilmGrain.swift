import CoreImage
import Foundation
import Metal

/// The film's grain, on the developed density (slot C of
/// docs/superpowers/specs/2026-11-04-film-behaviour.md, §4): each colour layer (one layer for a B&W
/// film) is a few sub-layers of silver-halide particles. Per pixel and sub-layer a Poisson number of
/// particles develops, each into a dye cloud of fixed density (blurred to the cloud's size); their sum,
/// less the mean, is the grain. Then the whole density is softened (the grain blur) and given back some
/// bite (a multiplicative unsharp mask). Only per-render settings are read: a change is instant.
///
/// The randomness is a stateless hash of the full-size pixel, the channel and the sub-layer, so a tile,
/// a crop or another exposure draws the same particles at the same place. A preview (render scale s < 1)
/// holds 1/s² more particles per pixel, as §4.2 says, and each sub-layer's deviation is then scaled so
/// its strength is what the export's grain has after a box downscale to the preview's size (the count
/// alone gets that only when the export's grain is uncorrelated between pixels; see `previewGain`).
///
/// On the GPU it is two passes: the draw and the blurs across (a row of pixels shared in threadgroup
/// memory), then the blurs down and the sharpening's ratio (in the one-pass chain, the print as well).
/// When both blurs are skipped (a small preview) it is one: the draw (and the print). The grain blur
/// and the sharpening's blur of the blurred density run as one pair of kernels (G_u ⊛ G_gb is separable
/// too), so at the photo's edges the sharpening sees the grained density repeated, not the blurred one:
/// a difference within the sharpening's radius of the edge only. Films with noticeable dye clouds (the
/// coarse B&W and cine stocks, mostly at full size) first draw those sub-layers onto planes and blur
/// them there.
enum FilmGrain {
    /// Grain, grain blur and grain sharpening on the film density (`FilmLook.develop`'s output), before the print.
    /// Grain off (or `grain_amount` 0) gives the density back untouched.
    static func apply(_ density: CIImage, stock: FilmStock, settings: FilmSettings, geometry: FilmGeometry) -> CIImage {
        let extent = density.extent
        guard let plan = plan(stock, settings, geometry, extent: extent) else { return density }
        guard !extent.isEmpty else { return .empty() }
        guard !extent.isInfinite else { assertionFailure("the film needs a finite extent: crop first"); return .empty() }
        return (try? PhotoEngine.apply(FilmGrainPass.self, extent: extent, inputs: [density.clampedToExtent()], arguments: ["grain": plan])) ?? .empty()
    }

    /// Whether the grain changes anything for these settings.
    static func isOn(settings: FilmSettings) -> Bool {
        value(settings, "grain_on", 1, 0...1) > 0.5 && value(settings, "grain_amount", 1, 0...8) > 0
    }

    /// The settings the grain reads (they never change a table: a change here is instant).
    static let settings = ["grain_on", "grain_amount", "grain_blur", "grain_dye_cloud", "grain_usm_sigma", "grain_usm_amount", "film_format_mm"]

    /// Nodes of the density-to-sub-layers table, per channel.
    static let tableNodes = 2048

    // MARK: - The plan

    /// What the grain does on one render, as a pass argument.
    final class Plan: NSObject, @unchecked Sendable {
        /// `GrainParams`' floats (78 float4, see the shader).
        let floats: [SIMD4<Float>]
        /// The sub-layers, mono, the planes; the taps either side, the table's nodes and pages; where each
        /// sub-layer and channel goes (4 · plane + slot, or −1 in place; 24), and each plane slot's channel (8 planes).
        let info: SIMD4<Int32>
        let radii: SIMD4<Int32>
        let planes: [SIMD4<Int32>]
        /// Per channel and page of four sub-layers: each sub-layer's absolute density at evenly spaced film densities.
        let table: [SIMD4<Float>]
        /// One dye-cloud blur per plane of blurred sub-layers.
        let dye: [FilmBlur.Plan]
        /// The taps either side of the blurs (0 when both are skipped).
        let reach: Int
        /// The photo's extent: the particles are counted from its top-left corner.
        let extent: CGRect
        /// How far outside its output a tile reads.
        let margin: Int
        /// Keeps the table's buffer for the tiles of one render.
        let holder = FilmBlur.Plan(keep: .zero, blurs: [])

        init(floats: [SIMD4<Float>], info: SIMD4<Int32>, radii: SIMD4<Int32>, planes: [SIMD4<Int32>], table: [SIMD4<Float>], dye: [FilmBlur.Plan],
             reach: Int, extent: CGRect) {
            self.floats = floats; self.info = info; self.radii = radii; self.planes = planes; self.table = table
            self.dye = dye; self.reach = reach; self.extent = extent
            margin = (dye.map(\.margin).max() ?? 0) + reach
        }

        /// The shader's parameters: where the area sits on the photo, and where the target sits in the area.
        func params(place: SIMD4<Int32>, frame: SIMD4<Int32>) -> Data {
            var data = floats.withUnsafeBytes { Data($0) }
            for v in [place, frame, info, radii] + planes { withUnsafeBytes(of: v) { data.append(contentsOf: $0) } }
            return data
        }
    }

    /// The plan for these settings, nil when the grain is off (or the film's grain numbers are missing).
    static func plan(_ stock: FilmStock, _ settings: FilmSettings, _ geometry: FilmGeometry, extent: CGRect) -> Plan? {
        let amount = value(settings, "grain_amount", 1, 0...8)
        guard value(settings, "grain_on", 1, 0...1) > 0.5, amount > 0 else { return nil }
        let sp = stock.spatial
        guard let n = sp["grain_sublayers"]?.number.map({ Int($0) }), (1...8).contains(n),
              let dmax = sp["grain_layer_dmax"]?.rows, let dmin = sp["grain_layer_dmin"]?.rows, let refs = sp["grain_layer_particles_ref"]?.rows,
              dmax.count == n, dmin.count == n, refs.count == n, (dmax + dmin + refs).allSatisfy({ $0.count == 3 }),
              let uniformity = sp["grain_uniformity"]?.numbers, uniformity.count == 3, let floor = sp["grain_floor"]?.numbers, floor.count == 3,
              let total = sp["grain_total_curve"]?.flat, total.count == 256 * 3, let layers = sp["grain_layer_curves"]?.flat, layers.count == n * 256 * 3,
              (total + layers + uniformity + floor + (dmax + dmin + refs).flatMap { $0 }).allSatisfy(\.isFinite) else {
            // A broken pack: say so, rather than quietly showing a film without grain while the grain is on.
            assertionFailure("\(stock.film): its grain numbers are missing or malformed")
            NSLog("Pluck film: %@ has missing or malformed grain numbers; grain is off", stock.film)
            return nil
        }
        let mono = sp["grain_mono"]?.flag ?? stock.bw

        let s = geometry.scale
        let pixel = geometry.fullPitchUM(filmFormatMM: value(settings, "film_format_mm", 36, 5...250))   // µm per full-size pixel
        let pitch = pixel / s                                                                            // µm per render pixel
        let dyeScale = value(settings, "grain_dye_cloud", 1, 0...4)
        let blurSetting = value(settings, "grain_blur", 1, 0.2...4)
        let usmSigma = value(settings, "grain_usm_sigma", 0.7, 0...3), usmAmount = value(settings, "grain_usm_amount", 1.5, 0...2)

        // The grain blur and the sharpening, in render pixels (their radii are full-size pixels), each skipped under 0.3 px.
        func skipped(_ sigma: Double) -> Double { sigma < 0.3 ? 0 : sigma }
        let gbFull = blurSetting >= 0.05 ? skipped(0.8 * blurSetting) : 0, gb = blurSetting >= 0.05 ? skipped(0.8 * blurSetting * s) : 0
        let sharpening = usmSigma > 0 && usmAmount > 0
        let uFull = sharpening ? skipped(usmSigma) : 0, u = sharpening ? skipped(usmSigma * s) : 0

        // Per sub-layer and channel: the particles per render pixel, the dye cloud's σ, the preview's gain.
        var floats = [SIMD4<Float>](repeating: .zero, count: 38 + 40)
        var sigmas: [SIMD3<Double>] = []
        for l in 0..<n {
            var sigma = SIMD3<Double>(), gain = SIMD3<Double>(repeating: 1), count = SIMD3<Double>(), inverse = SIMD3<Double>(), cloudDensity = SIMD3<Double>()
            for c in 0..<3 {
                let m = refs[l][c], top = dmax[l][c]
                let particles = max(m, 0) * pow(pitch / 10, 2)
                // A sub-layer with no particles or no density adds nothing (its count stays 0). As §4.3 says
                // literally: its x is 0, not D_l, so a D_l > 0 there would shift the mean density by −amount·D_l.
                // (No shipped film has one.)
                if particles > 0 && top > 0 { count[c] = particles; inverse[c] = 1 / top; cloudDensity[c] = top / particles }
                let cloud = m > 0 && top > 0 ? 20 * dyeScale * (top / m).squareRoot() : 0     // µm on film (§4.4)
                sigma[c] = cloud / pitch
                if s < 1 {
                    gain[c] = previewGain(dyeFull: cloudSigma(cloud / pixel), dye: cloudSigma(sigma[c]), blurFull: gbFull, blur: gb, sharpenFull: uFull, sharpen: u,
                                          amount: usmAmount, scale: s)
                }
            }
            sigmas.append(sigma)
            floats[4 * l] = SIMD4(SIMD3<Float>(inverse), 0)
            floats[4 * l + 1] = SIMD4(SIMD3<Float>(cloudDensity), 0)
            floats[4 * l + 2] = SIMD4(SIMD3<Float>(count), 0)
            floats[4 * l + 3] = SIMD4(SIMD3<Float>(gain), 0)
        }
        floats[32] = SIMD4(Float(floor[0]), Float(floor[1]), Float(floor[2]), 0)
        floats[33] = SIMD4((0..<3).map { Float(min(max(uniformity[$0], 0), 0.999)) } + [0])
        floats[34] = SIMD4(Float(geometry.fullOrigin.x), Float(geometry.fullOrigin.y), Float(1 / s), Float(amount))
        floats[35] = SIMD4(Float(usmAmount), u > 0 ? 1 : 0, 0, 0)

        // §4.3 step 1–2 as a table: each sub-layer's absolute density at evenly spaced film densities, per channel
        // (over the total curve's range; past it the curve's ends hold).
        let nodes = tableNodes, pages = (n + 3) / 4
        var table = [SIMD4<Float>](repeating: .zero, count: 3 * pages * nodes)
        for c in 0..<3 {
            let curve = (0..<256).map { total[3 * $0 + c] }
            let lo = curve.min() ?? 0, hi = curve.max() ?? 0
            let step = hi > lo ? (hi - lo) / Double(nodes - 1) : 0
            floats[36][c] = Float(lo); floats[37][c] = step > 0 ? Float(1 / step) : 0
            for j in 0..<nodes {
                let (i, f) = node(curve, lo + Double(j) * step)
                for l in 0..<n {
                    let at = (l * 256 + i) * 3 + c
                    table[(c * pages + l / 4) * nodes + j][l % 4] = Float(layers[at] * (1 - f) + layers[at + 3] * f + dmin[l][c])
                }
            }
        }

        // The grain blur, and the sharpening's blur after it, as taps across (and down): x the first, y the pair.
        func kernel(_ sigma: Double) -> [Double] { sigma > 0 ? FilmBlur.taps(sigma, wide: false, factor: 1) : [1] }
        let first = kernel(gb), pair = u > 0 ? convolve(kernel(u), first) : first
        let reach = (pair.count - 1) / 2, offset = reach - (first.count - 1) / 2
        guard 2 * reach + 1 <= 40 else { assertionFailure("the grain's blurs reach too far"); return nil }
        for i in 0..<pair.count {
            floats[38 + i] = SIMD4(i >= offset && i < offset + first.count ? Float(first[i - offset]) : 0, Float(pair[i]), 0, 0)
        }

        // The dye clouds. A cloud whose centre tap holds more than 99.9 % (σ under about 0.26 px: the grain's
        // variance changes by under 0.4 %) is left out, and its sub-layer adds up in place. Each other
        // sub-layer and channel (for B&W, each sub-layer) takes a slot on a plane, three to a plane, each
        // blurred with its own σ.
        var codes = [Int32](repeating: -1, count: 24), slots = [SIMD4<Int32>](repeating: SIMD4(repeating: -1), count: 8)
        var clouds: [(slot: Int, channel: Int32, sigma: Double)] = []
        for l in 0..<n { for c in 0..<(mono ? 1 : 3) {
            let sigma = cloudSigma(sigmas[l][mono ? 1 : c])
            guard sigma > 0 else { continue }
            codes[3 * l + c] = Int32(4 * (clouds.count / 3) + clouds.count % 3)
            clouds.append((clouds.count, mono ? 3 : Int32(c), sigma))
        } }
        var dye: [FilmBlur.Plan] = []
        for start in stride(from: 0, to: clouds.count, by: 3) {
            var sigma = SIMD3<Double>()
            for cloud in clouds[start..<min(start + 3, clouds.count)] {
                sigma[cloud.slot % 3] = cloud.sigma; slots[cloud.slot / 3][cloud.slot % 3] = cloud.channel
            }
            guard let plan = FilmBlur.plan(keep: .zero, [FilmBlur.Component(sigma: sigma, wide: false, weight: SIMD3(repeating: 1))]) else { return nil }
            dye.append(plan)
        }
        let planes = stride(from: 0, to: 24, by: 4).map { SIMD4(codes[$0], codes[$0 + 1], codes[$0 + 2], codes[$0 + 3]) } + slots
        return Plan(floats: floats, info: SIMD4(Int32(n), mono ? 1 : 0, Int32(dye.count), 0), radii: SIMD4(Int32(reach), Int32(nodes), Int32(pages), 0),
                    planes: planes, table: table, dye: dye, reach: reach, extent: extent)
    }

    /// A dye cloud's σ as the render uses it: 0 (no blur) when its centre tap holds more than 99.9 %.
    static func cloudSigma(_ sigma: Double) -> Double {
        guard sigma > 0 else { return 0 }
        let taps = FilmBlur.taps(sigma, wide: false, factor: 1)
        return 1 - taps[taps.count / 2] >= 1e-3 ? sigma : 0
    }

    /// §4.3 step 1: where density D sits on a total curve: the node below (0…254) and the fraction.
    /// Rising (C[255] ≥ C[0]): the last node with C[i] ≤ D; falling: the last with C[i] ≥ D; node 0 if none.
    static func node(_ curve: [Double], _ D: Double) -> (Int, Double) {
        let rising = curve[255] >= curve[0]
        var lo = -1, hi = 255                      // the last node passing the test is in (lo, hi)
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if rising ? curve[mid] <= D : curve[mid] >= D { lo = mid } else { hi = mid }
        }
        let i = max(lo, 0), a = curve[i], b = curve[i + 1]
        if b != a { return (i, min(max((D - a) / (b - a), 0), 1)) }
        return (i, i == 254 && (rising ? D > b : D < b) ? 1 : 0)   // past a flat end: the last node
    }

    private static func convolve(_ a: [Double], _ b: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: a.count + b.count - 1)
        for (i, x) in a.enumerated() { for (j, y) in b.enumerated() { out[i + j] += x * y } }
        return out
    }

    /// A preview's gain on one sub-layer's deviation, so its grain is as strong as the export's after a
    /// box downscale to the preview's size.
    ///
    /// The export's grain from one sub-layer is its per-pixel draws (variance V) through the linear filter
    /// h = (1 + α)·(K_gb ⊛ K_dye) − α·(G_u ⊛ K_gb ⊛ K_dye) (§4.8). Averaged over boxes of 1/s × 1/s pixels it
    /// has the variance V·s²·Σ C(Δ)·(1 − |Δx|·s)₊(1 − |Δy|·s)₊, with C the autocorrelation of h. A preview pixel
    /// holds 1/s² more particles, so its draws have the variance V·s², through the preview's own (narrower,
    /// often skipped) filter h′: V·s²·‖h′‖². The gain is the square root of the ratio, 1 at full size.
    /// Both filters are two separable terms, so every sum here is a product of one-dimensional ones.
    static func previewGain(dyeFull: Double, dye: Double, blurFull: Double, blur: Double, sharpenFull: Double, sharpen: Double,
                            amount: Double, scale s: Double) -> Double {
        func kernel(_ sigma: Double) -> [Double] { sigma > 0 ? FilmBlur.taps(sigma, wide: false, factor: 1) : [1] }
        // Σ_Δ (a ⋆ b)(Δ)·w(Δ), for centred, symmetric a and b.
        func weighted(_ a: [Double], _ b: [Double], _ w: (Int) -> Double) -> Double {
            let ca = a.count / 2, cb = b.count / 2
            var sum = 0.0
            for (i, x) in a.enumerated() { for (j, y) in b.enumerated() { sum += x * y * w((i - ca) - (j - cb)) } }
            return sum
        }
        // Σ C·w over both axes, for h = a1·(p ⊗ p) + a2·(q ⊗ q).
        func strength(dye: Double, blur: Double, sharpen: Double, _ w: (Int) -> Double) -> Double {
            let p = convolve(kernel(blur), kernel(dye))
            guard sharpen > 0, amount > 0 else { return pow(weighted(p, p, w), 2) }
            let q = convolve(kernel(sharpen), p), a1 = 1 + amount, a2 = -amount
            return a1 * a1 * pow(weighted(p, p, w), 2) + 2 * a1 * a2 * pow(weighted(p, q, w), 2) + a2 * a2 * pow(weighted(q, q, w), 2)
        }
        guard s < 1 else { return 1 }
        let target = strength(dye: dyeFull, blur: blurFull, sharpen: sharpenFull) { max(1 - Double(abs($0)) * s, 0) }
        let own = strength(dye: dye, blur: blur, sharpen: sharpen) { $0 == 0 ? 1 : 0 }
        guard target > 0, own > 0, target.isFinite, own.isFinite else { return 1 }
        return (target / own).squareRoot()
    }

    // MARK: - On the GPU

    /// The grain from `density` onto `target`. `area` is the part of the photo the pass reads: every image
    /// in between covers it, and past its edges each blur repeats the edge pixels. With `print` (FilmLook's
    /// parameters and print tables), the last kernel also prints: the target gets the finished colour.
    static func encode(_ plan: Plan, density: FilmBlur.Place, area: CGRect, onto target: FilmBlur.Place, passes: FilmBlur.Passes,
                       print: (params: Data, tables: [MTLTexture])? = nil) throws {
        let width = Int(area.width.rounded(.up)), height = Int(area.height.rounded(.up))
        let region = FilmBlur.Place(density.texture, minX: Int(area.minX.rounded(.down)), maxY: Int(area.maxY.rounded(.up)))
        let photo = plan.extent.integral
        // The area's (0, 0) on the photo (rows down) and its size; the target's (0, 0) in the area.
        let place = SIMD4<Int32>(Int32(region.minX) - Int32(photo.minX), Int32(photo.maxY) - Int32(region.maxY), Int32(width), Int32(height))
        func frame(_ p: FilmBlur.Place, rows: Int = 0) -> SIMD4<Int32> {
            SIMD4(Int32(p.minX - region.minX), Int32(region.maxY - p.maxY - rows), Int32(p.width), Int32(p.height + 2 * rows))
        }
        func plane(_ role: String, float: Bool = true) throws -> FilmBlur.Place {
            FilmBlur.Place(try passes.scratch(role, width, height, float: float), minX: region.minX, maxY: region.maxY)
        }
        func slots(_ images: [FilmBlur.Place], or spare: MTLTexture) -> [MTLTexture] { (0..<8).map { $0 < images.count ? images[$0].texture : spare } }
        let toArea = density.offset(from: region)

        // Films with dye clouds: those sub-layers' particles onto their planes (half floats, rounded to
        // nearest: a sub-layer's density is under 1), each blurred onto a float plane. The passes below
        // draw the other sub-layers themselves and add these.
        var clouds: [FilmBlur.Place] = []
        if !plan.dye.isEmpty {
            let layers = try (0..<plan.dye.count).map { try plane("grain.layer\($0)", float: false) }
            try dispatch("filmGrainDraw", [density.texture] + slots(layers, or: layers[0].texture), plan: plan,
                         params: plan.params(place: place, frame: frame(layers[0])), offsets: [toArea], size: (width, height), passes: passes)
            clouds = try layers.enumerated().map { k, layer in
                let out = try plane("grain.cloud\(k)")
                try passes.mix(plan.dye[k], from: layer, onto: out)
                return out
            }
        }
        let offsets = [toArea, .zero]
        let inputs = [density.texture] + slots(clouds, or: density.texture)
        let printing = print?.tables ?? []
        let suffix = print == nil ? "" : "Print"
        guard plan.reach > 0 else {
            try dispatch("filmGrainDirect" + suffix, inputs + printing + [target.texture], plan: plan,
                         params: plan.params(place: place, frame: frame(target)), film: print?.params, offsets: offsets,
                         size: (target.width, target.height), passes: passes)
            return
        }
        // The blurs across (with the draw), over the target's columns and its reach above and below; then down.
        // In between, half floats holding each blur less the pixel's own (ungrained) density: small numbers, so they keep their precision.
        let r = plan.reach, rows = frame(target, rows: r)
        let across = try passes.scratch("grain.across", target.width, target.height + 2 * r)
        let pair = try passes.scratch("grain.pair", target.width, target.height + 2 * r)
        try dispatch("filmGrainAcross", inputs + [across, pair], plan: plan, params: plan.params(place: place, frame: rows),
                     offsets: offsets, size: (target.width, target.height + 2 * r), row: true, passes: passes)
        try dispatch("filmGrainDown" + suffix, [across, pair, density.texture] + printing + [target.texture], plan: plan,
                     params: plan.params(place: place, frame: rows), film: print?.params, offsets: offsets,
                     size: (target.width, target.height), passes: passes)
    }

    /// One of the grain's kernels. `row`: threadgroups of 256 along a row, sharing their pixels (each
    /// writes 256 − 2·reach of them).
    private static func dispatch(_ name: String, _ textures: [MTLTexture], plan: Plan, params: Data, film: Data? = nil, offsets: [SIMD2<Int32>],
                                 size: (Int, Int), row: Bool = false, passes: FilmBlur.Passes) throws {
        let device = passes.device, encoder = passes.encoder
        guard let state = FilmLook.Library.shared.pipeline(name, device: device),
              let table = plan.holder.buffer("grain-table", device: device, taps: plan.table) else { throw FilmBlur.failed }
        encoder.setComputePipelineState(state)
        for (i, texture) in textures.enumerated() { encoder.setTexture(texture, index: i) }
        params.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: params.count, index: 0) }
        encoder.setBuffer(table, offset: 0, index: 1)
        if var film {
            if film.count < MemoryLayout<FilmLook.Params>.stride { film.append(Data(count: MemoryLayout<FilmLook.Params>.stride - film.count)) }
            film.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: film.count, index: 3) }
        }
        var offsets = offsets + [SIMD2<Int32>](repeating: .zero, count: max(0, 2 - offsets.count))
        encoder.setBytes(&offsets, length: MemoryLayout<SIMD2<Int32>>.stride * offsets.count, index: 2)
        if row {
            let span = 256 - 2 * plan.reach
            guard state.maxTotalThreadsPerThreadgroup >= 256, span > 0 else { throw FilmBlur.failed }
            encoder.dispatchThreadgroups(MTLSize(width: (size.0 + span - 1) / span, height: size.1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        } else {
            let width = state.threadExecutionWidth, height = max(state.maxTotalThreadsPerThreadgroup / width, 1)
            encoder.dispatchThreads(MTLSize(width: size.0, height: size.1, depth: 1), threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
        }
    }

    /// A setting's value, clamped to its range.
    private static func value(_ settings: FilmSettings, _ key: String, _ standard: Double, _ range: ClosedRange<Double>) -> Double {
        let v = settings.number(key) ?? standard
        return v.isFinite ? min(max(v, range.lowerBound), range.upperBound) : standard
    }

    // MARK: - The shaders (compiled with FilmLook's and FilmBlur's)

    static let shaders = #"""

    struct GrainParams {
        float4 layer[32];       // sub-layer l: [4l] 1/Dmax, [4l + 1] one dye cloud's density Dmax/N, [4l + 2] particles per render pixel N
                                // (0: the sub-layer adds nothing), [4l + 3] the preview's gain
        float4 floorF;          // the fog floor F per channel
        float4 uniformity;      // u per channel
        float4 key;             // the render's (0, 0) in full-size pixels (x, y), 1/s, grain_amount
        float4 sharpen;         // grain_usm_amount, whether the sharpening is on
        float4 tableLo;         // per channel: the table's first density,
        float4 tableScale;      // and its nodes per unit of density
        float4 taps[40];        // −reach…reach: x the grain blur, y the grain blur then the sharpening's blur
        int4 place;             // the area's (0, 0) from the photo's top-left corner (render pixels, rows down), its width and height
        int4 frame;             // the output's (0, 0) in the area, its width and height
        int4 info;              // the sub-layers, mono, the planes
        int4 radii;             // the taps either side, the table's nodes and pages
        int4 codes[6];          // where sub-layer l's channel c goes ([3l + c]; B&W c = 0): 4 · plane + slot, −1 when it adds up in place
        int4 slots[8];          // each plane slot's channel (3: all three, −1: unused)
    };

    // A counter-based hash (Jarzynski and Olano's pcg4d): nothing kept between pixels or renders.
    inline uint4 grainHash(uint4 v) {
        v = v * 1664525u + 1013904223u;
        v.x += v.y * v.w; v.y += v.z * v.x; v.z += v.x * v.y; v.w += v.y * v.z;
        v ^= v >> 16u;
        v.x += v.y * v.w; v.y += v.z * v.x; v.z += v.x * v.y; v.w += v.y * v.z;
        return v;
    }

    // A uniform strictly inside (0, 1) from a hash: 23 bits, so (k + 0.5)/2^23 is exact in a float and
    // never rounds to 0 or 1 (24 bits would: 16777215.5 isn't a float, it rounds to 2^24, giving 1).
    inline float grainUniform(uint h) { return (float(h >> 9) + 0.5) * (1.0 / 8388608.0); }

    // The standard normal's inverse (Acklam's rational approximation, relative error about 1e-9). The draws
    // use the fast forms of division, roots and logarithms: they're random numbers, and this is most of the grain's time.
    inline float normalInverse(float p) {
        p = clamp(p, 5.9604645e-8, 1.0 - 5.9604645e-8);   // never 0 or 1 (log(0) would be NaN or infinite)
        const float a0 = -3.969683028665376e+01, a1 = 2.209460984245205e+02, a2 = -2.759285104469687e+02,
                    a3 = 1.383577518672690e+02, a4 = -3.066479806614716e+01, a5 = 2.506628277459239e+00;
        const float b0 = -5.447609879822406e+01, b1 = 1.615858368580409e+02, b2 = -1.556989798598866e+02,
                    b3 = 6.680131188771972e+01, b4 = -1.328068155288572e+01;
        const float c0 = -7.784894002430293e-03, c1 = -3.223964580411365e-01, c2 = -2.400758277161838e+00,
                    c3 = -2.549732539343734e+00, c4 = 4.374664141464968e+00, c5 = 2.938163982698783e+00;
        const float d0 = 7.784695709041462e-03, d1 = 3.224671290700398e-01, d2 = 2.445134137142996e+00, d3 = 3.754408661907416e+00;
        if (p < 0.02425 || p > 0.97575) {
            float q = fast::sqrt(-2.0 * fast::log(min(p, 1.0 - p)));
            float x = fast::divide((((((c0 * q + c1) * q + c2) * q + c3) * q + c4) * q + c5), ((((d0 * q + d1) * q + d2) * q + d3) * q + 1.0));
            return p < 0.5 ? x : -x;
        }
        float q = p - 0.5, r = q * q;
        return fast::divide((((((a0 * r + a1) * r + a2) * r + a3) * r + a4) * r + a5) * q, (((((b0 * r + b1) * r + b2) * r + b3) * r + b4) * r + 1.0));
    }

    // A Poisson deviate with mean λ from one uniform u: the exact inverse below 12, λ + √λ·z above. Both
    // grow with u, so another exposure (another λ) draws nearly the same grain at the same place.
    inline float poisson(float lambda, float u) {
        if (!(lambda > 0.0)) return 0.0;
        if (lambda >= 12.0) return lambda + fast::sqrt(lambda) * normalInverse(u);
        float p = fast::exp(-lambda), total = p;
        int k = 0;
        // Past the mean, stop once the terms are negligible: at u within a float's step of 1 the sum may never reach u.
        while (u > total && k < 63) {
            k++; p *= fast::divide(lambda, float(k)); total += p;
            if (float(k) > lambda && p < 1e-7) break;
        }
        return float(k);
    }

    // §4.3: the particles of the sub-layers at one full-size pixel, for film density d. Returns the
    // grained density d + amount · (Σ x − F − D) over the sub-layers that add up in place (with `planes`,
    // instead, only the others are drawn, onto `onPlanes`).
    inline float3 grainDraw(float3 d, uint X, uint Y, constant GrainParams &g, device const float4 *table, bool planes, thread float4 *onPlanes) {
        int layers = g.info.x, nodes = g.radii.y, pages = g.radii.z;
        bool mono = g.info.y != 0;
        float3 out = d;
        for (int c = 0; c < (mono ? 1 : 3); c++) {
            int k = mono ? 1 : c;                    // B&W: the channel-1 numbers
            float D = mono ? (d.r + d.g + d.b) / 3.0 : d[c];
            if (!isfinite(D)) D = 0.0;
            float t = clamp((D - g.tableLo[k]) * g.tableScale[k], 0.0, float(nodes - 1));
            int j = min(int(t), nodes - 2);
            float f = t - float(j);
            float u = g.uniformity[k], here = 0.0;
            uint4 h = uint4(0);
            float4 Ds = float4(0.0);
            for (int l = 0; l < layers; l++) {
                if (l % 4 == 0) {
                    h = grainHash(uint4(X, Y, uint(c * 2 + l / 4), 0x9E3779B9u));
                    device const float4 *row = table + (k * pages + l / 4) * nodes + j;
                    Ds = mix(row[0], row[1], f);
                }
                int code = g.codes[(3 * l + c) / 4][(3 * l + c) % 4];
                if ((code >= 0) != planes) continue;
                float n = g.layer[4 * l + 2][k], x = 0.0;
                if (n > 0.0) {
                    float Dl = Ds[l % 4];
                    float q = clamp(Dl * g.layer[4 * l][k], 1e-6, 1.0 - 1e-6);
                    float saturation = 1.0 - u * q;
                    x = poisson(fast::divide(n * q, saturation), grainUniform(h[l % 4])) * g.layer[4 * l + 1][k] * saturation;
                    x = Dl + g.layer[4 * l + 3][k] * (x - Dl);   // the preview's gain (1 at full size)
                }
                if (planes) onPlanes[code / 4][code % 4] = x; else here += x;
            }
            float delta = g.key.w * (here - g.floorF[k] - D);
            if (mono) out += delta; else out[c] += delta;
        }
        return out;
    }

    // Area pixel a (inside the area): its grained density, the sub-layers in place drawn here, the dye clouds from their planes.
    inline float4 grained(int2 a, Plane src, array<texture2d<float, access::read>, 8> clouds, constant GrainParams &g,
                          device const float4 *table, constant int2 *offsets) {
        float4 s = src.read(uint2(clamp(a + offsets[0], int2(0), int2(src.get_width(), src.get_height()) - 1)));
        int2 at = g.place.xy + a;                    // the pixel's place on the photo, counted from its top-left corner
        uint X = uint(int(floor(g.key.x + float(at.x) * g.key.z))), Y = uint(int(floor(g.key.y + float(at.y) * g.key.z)));
        float4 none[1];
        float3 d = grainDraw(s.rgb, X, Y, g, table, false, none);
        if (g.info.z > 0) {
            float3 sum = float3(0.0);
            for (int p = 0; p < g.info.z; p++) {
                float3 v = clouds[p].read(uint2(a)).rgb;
                for (int k = 0; k < 3; k++) {
                    int c = g.slots[p][k];
                    if (c == 3) sum += v[k]; else if (c >= 0) sum[c] += v[k];
                }
            }
            d += g.key.w * sum;
        }
        return float4(d, s.a);
    }

    inline int2 inArea(int2 p, constant GrainParams &g) { return clamp(g.frame.xy + p, int2(0), g.place.zw - 1); }

    // §4.7: the multiplicative unsharp mask on the absolute density (the ratio kept within 1/4…4).
    inline float3 grainSharpen(float3 d, float3 around, constant GrainParams &g) {
        if (g.sharpen.y == 0.0) return d;
        float3 F = g.floorF.rgb;
        float3 A = max(d + F, 0.0), B = max(around + F, 1e-10);
        float3 rho = clamp(A / B, 0.25, 4.0);
        return max(A * pow(rho, g.sharpen.x) - F, 0.0);
    }

    // For the self-test: the uniform and the Poisson deviate the draws make from hash h at mean λ.
    kernel void filmGrainProbe(device const float2 *in [[buffer(0)]], device float2 *out [[buffer(1)]], uint i [[thread_position_in_grid]]) {
        float u = grainUniform(as_type<uint>(in[i].x));
        out[i] = float2(u, poisson(in[i].y, u));
    }

    // Films with dye clouds: the sub-layers and channels with a cloud, onto their planes (area pixels).
    kernel void filmGrainDraw(Plane src [[texture(0)]], array<texture2d<float, access::write>, 8> planes [[texture(1)]],
                              constant GrainParams &g [[buffer(0)]], device const float4 *table [[buffer(1)]],
                              constant int2 *offsets [[buffer(2)]], uint2 gid [[thread_position_in_grid]]) {
        if (int(gid.x) >= g.place.z || int(gid.y) >= g.place.w) return;
        int2 a = int2(gid);
        float4 s = src.read(uint2(clamp(a + offsets[0], int2(0), int2(src.get_width(), src.get_height()) - 1)));
        int2 at = g.place.xy + a;
        uint X = uint(int(floor(g.key.x + float(at.x) * g.key.z))), Y = uint(int(floor(g.key.y + float(at.y) * g.key.z)));
        float4 onPlanes[8];
        for (int p = 0; p < 8; p++) onPlanes[p] = float4(0.0);
        grainDraw(s.rgb, X, Y, g, table, true, onPlanes);
        for (int p = 0; p < g.info.z; p++) planes[p].write(float4(toHalf(onPlanes[p].rgb), 1.0), gid);
    }

    // No blur at this size: the grained density straight onto the output (or printed).
    kernel void filmGrainDirect(Plane src [[texture(0)]], array<texture2d<float, access::read>, 8> clouds [[texture(1)]],
                                Out dst [[texture(9)]],
                                constant GrainParams &g [[buffer(0)]], device const float4 *table [[buffer(1)]],
                                constant int2 *offsets [[buffer(2)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        dst.write(grained(inArea(int2(gid), g), src, clouds, g, table, offsets), gid);
    }

    kernel void filmGrainDirectPrint(Plane src [[texture(0)]], array<texture2d<float, access::read>, 8> clouds [[texture(1)]],
                                     Cube expose [[texture(9)]], Line paper [[texture(10)]], Cube scan [[texture(11)]], Cube dlog [[texture(12)]],
                                     Out dst [[texture(13)]],
                                     constant GrainParams &g [[buffer(0)]], device const float4 *table [[buffer(1)]],
                                     constant int2 *offsets [[buffer(2)]], constant FilmParams &p [[buffer(3)]],
                                     uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 d = grained(inArea(int2(gid), g), src, clouds, g, table, offsets);
        dst.write(float4(printed(d.rgb, p, expose, paper, scan, dlog), d.a), gid);
    }

    // The ungrained density (or the in-place sum) at area pixel a: what the images in between are counted from.
    inline float3 reference(int2 a, Plane src, constant int2 *offsets) {
        return src.read(uint2(clamp(a + offsets[0], int2(0), int2(src.get_width(), src.get_height()) - 1))).rgb;
    }

    // The grained density along a row (256 pixels shared), then the two blurs across it, less the pixel's own reference.
    kernel void filmGrainAcross(Plane src [[texture(0)]], array<texture2d<float, access::read>, 8> clouds [[texture(1)]],
                                Out first [[texture(9)]], Out pair [[texture(10)]],
                                constant GrainParams &g [[buffer(0)]], device const float4 *table [[buffer(1)]],
                                constant int2 *offsets [[buffer(2)]],
                                uint2 group [[threadgroup_position_in_grid]], uint lane [[thread_index_in_threadgroup]]) {
        threadgroup float4 line[256];
        int R = g.radii.x;
        int x = int(group.x) * (256 - 2 * R) + int(lane) - R, y = int(group.y);
        int2 a = inArea(int2(x, y), g);
        float4 v = grained(a, src, clouds, g, table, offsets);
        line[lane] = v;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (int(lane) < R || int(lane) >= 256 - R || x >= g.frame.z || y >= g.frame.w) return;
        float3 s1 = float3(0.0), s2 = float3(0.0);
        for (int i = -R; i <= R; i++) {
            float3 w = line[int(lane) + i].rgb;
            s1 += g.taps[i + R].x * w; s2 += g.taps[i + R].y * w;
        }
        float3 own = reference(a, src, offsets);
        first.write(float4(toHalf(s1 - own), v.a), uint2(x, y));
        pair.write(float4(toHalf(s2 - own), 1.0), uint2(x, y));
    }

    // The two blurs down (their images cover the output and its reach above and below), then the sharpening.
    inline float4 grainDown(uint2 gid, Plane first, Plane pair, Plane src, constant GrainParams &g, constant int2 *offsets) {
        int R = g.radii.x;
        float3 d = float3(0.0), around = float3(0.0);
        for (int i = -R; i <= R; i++) {
            uint2 p = uint2(gid.x, gid.y + uint(R + i));
            float3 own = reference(inArea(int2(p), g), src, offsets);
            d += g.taps[i + R].x * (first.read(p).rgb + own); around += g.taps[i + R].y * (pair.read(p).rgb + own);
        }
        return float4(grainSharpen(d, around, g), first.read(uint2(gid.x, gid.y + uint(R))).a);
    }

    kernel void filmGrainDown(Plane first [[texture(0)]], Plane pair [[texture(1)]], Plane src [[texture(2)]], Out dst [[texture(3)]],
                              constant GrainParams &g [[buffer(0)]], device const float4 *table [[buffer(1)]],
                              constant int2 *offsets [[buffer(2)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        dst.write(grainDown(gid, first, pair, src, g, offsets), gid);
    }

    kernel void filmGrainDownPrint(Plane first [[texture(0)]], Plane pair [[texture(1)]], Plane src [[texture(2)]],
                                   Cube expose [[texture(3)]], Line paper [[texture(4)]], Cube scan [[texture(5)]], Cube dlog [[texture(6)]],
                                   Out dst [[texture(7)]],
                                   constant GrainParams &g [[buffer(0)]], device const float4 *table [[buffer(1)]],
                                   constant int2 *offsets [[buffer(2)]], constant FilmParams &p [[buffer(3)]],
                                   uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 d = grainDown(gid, first, pair, src, g, offsets);
        dst.write(float4(printed(d.rgb, p, expose, paper, scan, dlog), d.a), gid);
    }
    """#
}

/// The grain on its own (FilmGrain.apply): density in, density out, float. A tile reads the grain's
/// margin around itself; the in-between images stop at the photo's edges, as in the one-pass chain.
final class FilmGrainPass: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAf }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        let margin = CGFloat((arguments?["grain"] as? FilmGrain.Plan)?.margin ?? 0)
        return outputRect.insetBy(dx: -margin, dy: -margin)
    }
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let plan = arguments?["grain"] as? FilmGrain.Plan, let input = inputs?.first, let buffer = output.metalCommandBuffer,
              let target = output.metalTexture, let source = input.metalTexture ?? PhotoEngine.upload(input, device: buffer.device),
              let passes = FilmBlur.Passes(buffer) else { throw FilmBlur.failed }
        defer { passes.end() }
        let inside = input.region.intersection(plan.extent.integral)
        try FilmGrain.encode(plan, density: FilmBlur.Place(source, region: input.region), area: inside.isEmpty ? input.region : inside,
                             onto: FilmBlur.Place(target, region: output.region), passes: passes)
    }
}
