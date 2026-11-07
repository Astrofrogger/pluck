import CoreImage
import Foundation
import Metal

/// The film's spatial effects that are on by default, as described in
/// docs/superpowers/specs/2026-11-04-film-behaviour.md: scatter and halation on the linear exposure
/// (§2.3), the coupler diffusion on the coupler correction (§3), and the scan blur and sharpening on
/// the finished colour (§6.1–6.2). Every length follows the scale-consistent rule (§1.2), so a preview
/// looks like the export scaled down. All of them only read per-render settings: none needs new tables.
/// Each stage is a few blurs mixed (FilmBlur.Plan); `chain` runs the whole film with them in one pass.
enum FilmHalation {
    /// Slot A: scatter inside the emulsion, then the light reflected off the film base.
    static func apply(_ raw: CIImage, stock: FilmStock, settings: FilmSettings, geometry: FilmGeometry) -> CIImage {
        [scatter(stock, settings, geometry), halation(stock, settings, geometry)].compactMap { $0 }.reduce(raw) { FilmBlur.mix($0, $1) }
    }

    /// Whether slot A changes anything for these settings.
    static func isOn(stock: FilmStock, settings: FilmSettings, geometry: FilmGeometry) -> Bool {
        scatter(stock, settings, geometry) != nil || halation(stock, settings, geometry) != nil
    }

    /// Slot B: the development inhibitor spreading sideways, as a blur of the coupler correction
    /// (log10-exposure units).
    static func diffuseCouplers(_ corr: CIImage, stock: FilmStock, settings: FilmSettings, geometry: FilmGeometry) -> CIImage {
        couplers(stock, settings, geometry).map { FilmBlur.mix(corr, $0) } ?? corr
    }

    /// Whether slot B changes anything: the film has couplers and some blur is wider than 0.3 px.
    static func couplersOn(stock: FilmStock, settings: FilmSettings, geometry: FilmGeometry) -> Bool {
        couplers(stock, settings, geometry) != nil
    }

    /// Slot E: the scanner's blur, then its sharpening, on the finished linear colour.
    static func scan(_ rgb: CIImage, settings: FilmSettings, geometry: FilmGeometry) -> CIImage {
        scanner(settings, geometry).reduce(rgb) { FilmBlur.mix($0, $1) }
    }

    /// Whether slot E changes anything at this size.
    static func scanOn(settings: FilmSettings, geometry: FilmGeometry) -> Bool { !scanner(settings, geometry).isEmpty }

    /// Lets go of the in-between images kept for previews (call after an export, say).
    static func purge() { FilmBlur.Pool.shared.purge() }

    /// How many of the film's one-pass renders have failed (Core Image only logs a failed pass: callers compare this).
    static var failures: Int { failureLock.withLock { failed } }
    static func noteFailure() { failureLock.withLock { failed += 1 } }
    nonisolated(unsafe) private static var failed = 0
    private static let failureLock = NSLock()

    /// The settings these stages read (they never change a table: a change here is instant).
    static let settings = ["halation_on", "scatter_amount", "scatter_scale", "halation_amount", "halation_scale",
                           "couplers_diffusion_um", "couplers_tail_um", "couplers_tail_weight", "couplers_edge", "film_format_mm",
                           "scan_blur", "scan_usm_sigma", "scan_usm_amount"]

    /// The film as rendered for a photo on `process`. From process 5, Halation off only takes the glow away: the emulsion's
    /// scatter (the film's own softness) stays, so the film doesn't come out crisper (and oversharpened by the scan).
    static func rendered(_ film: FilmSettings, process: Int) -> FilmSettings {
        guard process >= 5, let on = film.number("halation_on"), on <= 0.5 else { return film }
        var kept = film
        kept.changed["halation_on"] = .number(1)
        kept.changed["halation_amount"] = .number(0)
        return kept
    }

    // MARK: - The stages' blurs

    /// Scatter: a narrow core plus a tail (an exponential, as three Gaussians), per channel.
    /// `precise`: float images in between (half floats for the screen).
    static func scatter(_ stock: FilmStock, _ settings: FilmSettings, _ geometry: FilmGeometry, precise: Bool = true) -> FilmBlur.Plan? {
        let amount = value(settings, "scatter_amount", 1, 0...1), scale = value(settings, "scatter_scale", 1, 0.2...4)
        guard value(settings, "halation_on", 1, 0...1) > 0.5, amount > 0, let core = three(stock.spatial["scatter_core_um"]),
              let tail = three(stock.spatial["scatter_tail_um"]), let share = three(stock.spatial["scatter_tail_weight"]) else { return nil }
        let p = pitch(settings, geometry)
        var parts = [FilmBlur.Component(sigma: core * scale / p, wide: true, weight: amount * (1 - share))]
        for g in 0..<3 {
            parts.append(FilmBlur.Component(sigma: tail * (tailRadius[g] * scale / p), wide: true, weight: amount * share * tailShare[g]))
        }
        return FilmBlur.plan(keep: SIMD3(repeating: 1 - amount), parts, precise: precise)
    }

    /// Halation: three bounces off the film base, each √k wider, weighted 1, ½, ¼ (over 1.75), mixed in per channel.
    static func halation(_ stock: FilmStock, _ settings: FilmSettings, _ geometry: FilmGeometry, precise: Bool = true) -> FilmBlur.Plan? {
        let strength = (three(stock.spatial["halation_strength"]) ?? .zero) * value(settings, "halation_amount", 1, 0...8)
        guard value(settings, "halation_on", 1, 0...1) > 0.5, let first = stock.spatial["halation_first_sigma_um"]?.number, first > 0,
              strength.max() > 0 else { return nil }
        let sigma = first * value(settings, "halation_scale", 1, 0.2...4) / pitch(settings, geometry)
        let parts = (1...3).map { k in
            FilmBlur.Component(sigma: SIMD3(repeating: sigma * Double(k).squareRoot()), wide: true,
                               weight: strength * (pow(0.5, Double(k - 1)) / 1.75) / (1 + strength))
        }
        return FilmBlur.plan(keep: 1 / (1 + strength), parts, precise: precise)
    }

    /// The coupler diffusion: a core and an exponential tail. The three numbers come from the settings
    /// (the shipped films all carry the defaults), so they need no new tables. A blur under 0.3 px is the identity.
    /// The couplers' edge effect unless set: a third of spektrafilm's, whose full edges look oversharpened on screen.
    static let defaultCouplerEdge = 0.3

    static func couplers(_ stock: FilmStock, _ settings: FilmSettings, _ geometry: FilmGeometry) -> FilmBlur.Plan? {
        guard stock.constants.couplers, value(settings, "couplers_amount", 1, 0...1) > 0 else { return nil }
        let core = value(settings, "couplers_diffusion_um", stock.spatial["coupler_core_um"]?.number ?? 20, 0...60)
        var tail = value(settings, "couplers_tail_um", stock.spatial["coupler_tail_um"]?.number ?? 200, 0...400)
        var share = value(settings, "couplers_tail_weight", stock.spatial["coupler_tail_weight"]?.number ?? 0.03, 0...1)
        if !(tail > 0 && share > 0) { tail = 0; share = 0 }
        let p = pitch(settings, geometry)
        // The edge effect (Pluck's own): the share of the couplers' inhibition that spreads. At 1 it all spreads, as in
        // spektrafilm; the rest stays put, keeping the couplers' colour without their edges (which read as sharpening).
        let edge = value(settings, "couplers_edge", defaultCouplerEdge, 0...1)
        func skip(_ sigma: Double) -> Double { sigma < 0.3 ? 0 : sigma }
        var parts = [FilmBlur.Component(sigma: SIMD3(repeating: skip(core / p)), wide: true, weight: SIMD3(repeating: (1 - share) * edge))]
        if share > 0 {
            for g in 0..<3 {
                parts.append(FilmBlur.Component(sigma: SIMD3(repeating: skip(tailRadius[g] * tail / p)), wide: true,
                                                weight: SIMD3(repeating: share * tailShare[g] * edge)))
            }
        }
        return FilmBlur.plan(keep: SIMD3(repeating: 1 - edge), parts)
    }

    /// The scanner: its blur, then its sharpening (an additive unsharp mask, not clamped). Their radii
    /// are in full-size pixels, and each is skipped under 0.3 px.
    static func scanner(_ settings: FilmSettings, _ geometry: FilmGeometry) -> [FilmBlur.Plan] {
        var plans: [FilmBlur.Plan] = []
        let blur = value(settings, "scan_blur", 0, 0...4) * geometry.scale
        if blur >= 0.3, let plan = FilmBlur.plan(keep: .zero, [FilmBlur.Component(sigma: SIMD3(repeating: blur), wide: false, weight: SIMD3(repeating: 1))]) {
            plans.append(plan)
        }
        let sigma = value(settings, "scan_usm_sigma", 0.7, 0...3) * geometry.scale, amount = value(settings, "scan_usm_amount", 0.7, 0...2)
        if amount > 0, sigma >= 0.3, let plan = FilmBlur.plan(keep: SIMD3(repeating: 1 + amount),
                                                             [FilmBlur.Component(sigma: SIMD3(repeating: sigma), wide: false, weight: SIMD3(repeating: -amount))]) {
            plans.append(plan)
        }
        return plans
    }

    // MARK: - The whole film in one pass

    /// What the one-pass chain does, as a pass argument.
    final class Chain: NSObject, @unchecked Sendable {
        let stock: FilmStock
        let params: Data
        let scatter: FilmBlur.Plan?, halation: FilmBlur.Plan?, couplers: FilmBlur.Plan?
        let grain: FilmGrain.Plan?
        let scan: [FilmBlur.Plan]
        /// For the screen: half floats in between and in and out (an export keeps floats, for the deepest shadows and
        /// the brightest lights; the screen's picture moves by under 0.1 ΔE).
        let light: Bool
        /// The photo's extent: its edges are where every stage repeats its edge pixels.
        let extent: CGRect
        /// How far outside its output a tile reads: every blur's reach, added up.
        let margin: Int
        /// Its in-between images are kept for the next render (a preview being redrawn); a full-size film's (worked out
        /// once, a band at a time: an export, or 100 %) go with their render.
        let pooled: Bool
        init(stock: FilmStock, params: Data, scatter: FilmBlur.Plan?, halation: FilmBlur.Plan?, couplers: FilmBlur.Plan?, grain: FilmGrain.Plan?,
             scan: [FilmBlur.Plan], extent: CGRect, light: Bool = false, pooled: Bool = true) {
            self.stock = stock; self.params = params; self.scatter = scatter; self.halation = halation; self.couplers = couplers; self.grain = grain
            self.scan = scan; self.extent = extent; self.light = light; self.pooled = pooled
            margin = ([scatter, halation, couplers].compactMap { $0 } + scan).map(\.margin).reduce(0, +) + (grain?.margin ?? 0)
        }
    }

    /// The film from scene light with its spatial stages (FilmGrain's too), as one Core Image pass (each Core Image pass
    /// at preview size costs more than these blurs themselves). nil when no spatial stage is on:
    /// the fused colour pass is then the whole film. `display`: for the screen, in half floats (an export keeps floats).
    static func chain(_ scene: CIImage, stock: FilmStock, settings: FilmSettings, geometry: FilmGeometry, params: FilmLook.Params,
                      display: Bool = false) -> CIImage? {
        let extent = scene.extent
        let chain = Chain(stock: stock, params: params.data, scatter: scatter(stock, settings, geometry, precise: !display),
                          halation: halation(stock, settings, geometry, precise: !display), couplers: couplers(stock, settings, geometry),
                          grain: FilmGrain.plan(stock, settings, geometry, extent: extent), scan: scanner(settings, geometry), extent: extent, light: display,
                          pooled: geometry.scale < 1)
        guard chain.scatter != nil || chain.halation != nil || chain.couplers != nil || chain.grain != nil || !chain.scan.isEmpty else { return nil }
        guard !extent.isEmpty else { return .empty() }
        guard !extent.isInfinite else { assertionFailure("the film needs a finite extent: crop first"); return .empty() }
        let pass: CIImageProcessorKernel.Type = chain.light ? FilmSpatialPreviewPass.self : FilmSpatialPass.self
        return (try? PhotoEngine.apply(pass, extent: extent, inputs: [scene.clampedToExtent()], arguments: ["chain": chain])) ?? .empty()
    }

    /// The chain's passes: every in-between image covers the input inside the photo (so at the photo's
    /// own edges each stage repeats its own edge pixels, as the stages do apart; Core Image may hand
    /// over the input already repeated past them).
    static func render(_ chain: Chain, input: CIImageProcessorInput, output: CIImageProcessorOutput) throws {
        guard let buffer = output.metalCommandBuffer, let target = output.metalTexture,
              let source = input.metalTexture ?? PhotoEngine.upload(input, device: buffer.device),
              let passes = FilmBlur.Passes(buffer) else { throw FilmBlur.failed }
        defer { passes.end() }
        passes.pooled = chain.pooled
        let t = chain.stock.textures
        let scene = FilmBlur.Place(source, region: input.region), out = FilmBlur.Place(target, region: output.region)
        let inside = input.region.intersection(chain.extent.integral)
        let area = inside.isEmpty ? input.region : inside
        let planes = try (0..<3).map {
            FilmBlur.Place(try passes.scratch("plane\($0)", Int(area.width.rounded(.up)), Int(area.height.rounded(.up)), float: !chain.light), region: area)
        }
        var raw = planes[0]
        try passes.perPixel("filmExpose", [scene], tables: [t.exposeQ], params: chain.params, onto: raw)
        for plan in [chain.scatter, chain.halation].compactMap({ $0 }) {
            let next = planes.first { $0.texture !== raw.texture }!
            try passes.mix(plan, from: raw, onto: next)
            raw = next
        }
        let spare = planes.filter { $0.texture !== raw.texture }
        let density = spare[0]
        if let couplers = chain.couplers {
            try passes.perPixel("filmCouplers", [raw], tables: [t.silver], params: chain.params, onto: spare[0])
            try passes.mix(couplers, from: spare[0], onto: spare[1])
            try passes.perPixel("filmDevelopCorr", [raw, spare[1]], tables: [t.receive, t.curves], params: chain.params, onto: density)
        } else {
            try passes.perPixel("filmDevelop", [raw], tables: [t.silver, t.receive, t.curves], params: chain.params, onto: density)
        }
        // The print (with the grain on the density first, when it's on, in the grain's last kernel), onto the
        // output or onto a plane that's free now for the scan's blurs.
        var rgb = chain.scan.isEmpty ? out : planes.first { $0.texture !== density.texture }!
        if let grain = chain.grain {
            try FilmGrain.encode(grain, density: density, area: area, onto: rgb, passes: passes, print: (chain.params, FilmLook.printTables(t)))
        } else {
            try passes.perPixel("filmPrint", [density], tables: FilmLook.printTables(t), params: chain.params, onto: rgb)
        }
        guard !chain.scan.isEmpty else { return }
        for (i, plan) in chain.scan.enumerated() {
            let next = i == chain.scan.count - 1 ? out : planes.first { $0.texture !== rgb.texture }!
            try passes.mix(plan, from: rgb, onto: next)
            rgb = next
        }
    }

    // MARK: - Shared numbers

    /// An exponential tail as three Gaussians: their shares and radii (in decay lengths).
    private static let tailShare: [Double] = [0.1633, 0.6496, 0.1870]
    private static let tailRadius: [Double] = [0.5360, 1.5236, 2.7684]

    /// Micrometres of film per pixel of this render.
    private static func pitch(_ settings: FilmSettings, _ geometry: FilmGeometry) -> Double {
        geometry.renderPitchUM(filmFormatMM: value(settings, "film_format_mm", 36, 5...250))
    }

    /// A setting's value, clamped to its range.
    private static func value(_ settings: FilmSettings, _ key: String, _ standard: Double, _ range: ClosedRange<Double>) -> Double {
        let v = settings.number(key) ?? standard
        return v.isFinite ? min(max(v, range.lowerBound), range.upperBound) : standard
    }

    private static func three(_ value: FilmValue?) -> SIMD3<Double>? {
        guard let v = value?.numbers, v.count == 3 else { return nil }
        return SIMD3(v[0], v[1], v[2])
    }
}

/// The Gaussian blurs behind the film's spatial effects (behaviour document §1.3), on the GPU.
/// One plan mixes a few blurs of the same image: `keep·image + Σ weight·(G_σ ⊛ image)`, per
/// channel, with the image repeated past its edges. Narrow blurs run at full size as two passes
/// (across, then down); wide ones on a halved copy (2×, 4×, … up to 64×) with the leftover width,
/// brought back up one doubling at a time. Each halving and doubling is the linear-interpolation
/// filter (1, 3, 3, 1)/8, which keeps a point light where it is (a box would move it to the
/// middle of its block) and widens every pixel alike. The halved copies sit on a fixed grid, so a
/// tile gives what the whole does.
enum FilmBlur {
    /// One blur: its standard deviation per channel (render pixels), its kind (`wide` = kind W,
    /// else the exact kind X) and its share per channel. A channel with σ 0 is the identity.
    struct Component {
        var sigma: SIMD3<Double>
        var wide: Bool
        var weight: SIMD3<Double>
    }

    /// A blur runs at a halved size once that leaves it at least this wide (in halved pixels).
    static let lowSigma: Double = 2.5
    /// The same for a faint blur (its largest share under 5 %).
    static let faintSigma: Double = 1.5

    /// One blur as the passes run it: its weighted taps (per channel), at full size or halved `factor` times over.
    struct Blur {
        var taps: [SIMD4<Float>]
        var radius: Int
        var factor: Int
    }

    /// What one mix does, as a pass argument.
    final class Plan: NSObject, @unchecked Sendable {
        let keep: SIMD4<Float>
        let blurs: [Blur]
        /// The largest halving (1 when every blur is at full size).
        let factor: Int
        /// How far outside its output a tile reads (full-size pixels).
        let margin: Int
        /// Float (not half-float) images in between at full size: for the exposure, whose deep shadows
        /// and highlights past 65 000 a half float would lose.
        let precise: Bool
        /// Tap lists over 4 KB, as buffers (made once per device and pass).
        private var buffers: [String: MTLBuffer] = [:]
        private let lock = NSLock()
        func buffer(_ key: String, device: MTLDevice, taps: [SIMD4<Float>]) -> MTLBuffer? {
            lock.lock(); defer { lock.unlock() }
            let key = "\(device.registryID)-\(key)"
            if let known = buffers[key] { return known }
            let made = taps.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
            buffers[key] = made
            return made
        }
        init(keep: SIMD4<Float>, blurs: [Blur], precise: Bool = false) {
            self.keep = keep; self.blurs = blurs; self.precise = precise
            factor = blurs.map(\.factor).max() ?? 1
            // A halved blur reaches f·r, the halvings and doublings about 3f more.
            margin = blurs.map { $0.factor == 1 ? $0.radius : $0.factor * ($0.radius + 4) }.max() ?? 0
        }
    }

    /// The plan for `keep·image + Σ weight·(G_σ ⊛ image)` (at most four blurs at each size), nil
    /// when that's the image itself.
    static func plan(keep: SIMD3<Double>, _ components: [Component], precise: Bool = false) -> Plan? {
        var keep = keep
        var blurs: [Blur] = []
        for component in components {
            var weight = component.weight
            for c in 0..<3 where !(component.sigma[c] > 0) || !component.sigma[c].isFinite { keep[c] += weight[c]; weight[c] = 0 }
            guard weight != .zero else { continue }
            let active = (0..<3).filter { weight[$0] != 0 }
            let widths = SIMD3((0..<3).map { component.wide ? effectiveSigma(component.sigma[$0]) : component.sigma[$0] })
            var factor = 1
            let narrowest = active.map { widths[$0] }.min() ?? 0
            // A faint blur (a share under 5 %, like the coupler tail's) can go smaller: its error is scaled down with it.
            let low = (active.map { abs(weight[$0]) }.max() ?? 0) < 0.05 ? faintSigma : lowSigma
            while factor < 64 && narrowest / Double(2 * factor) >= low { factor *= 2 }
            var kernels = (0..<3).map { c in weight[c] == 0 ? [0.0] : taps(component.sigma[c], wide: component.wide, factor: factor) }
            // A blur that leaves less than 1e-4 off its centre (a σ under about 0.23 px) is the identity: it would
            // move under 1e-4 of the local contrast.
            for c in 0..<3 where factor == 1 && weight[c] != 0 && kernels[c].count > 1 && 1 - kernels[c][kernels[c].count / 2] < 1e-4 {
                keep[c] += weight[c]; weight[c] = 0; kernels[c] = [0]
            }
            guard weight != .zero else { continue }
            kernels = (0..<3).map { c in kernels[c].map { $0 * weight[c] } }
            let radius = kernels.map { ($0.count - 1) / 2 }.max() ?? 0
            var packed = [SIMD4<Float>](repeating: .zero, count: 2 * radius + 1)
            for c in 0..<3 {
                let r = (kernels[c].count - 1) / 2
                for (i, w) in kernels[c].enumerated() { packed[i - r + radius][c] = Float(w) }
            }
            blurs.append(Blur(taps: packed, radius: radius, factor: factor))
        }
        // The passes have four slots at each size.
        for f in Set(blurs.map(\.factor)) where blurs.filter({ $0.factor == f }).count > 4 {
            assertionFailure("at most four blurs at one size")
            var seen = 0
            blurs.removeAll { $0.factor == f && { seen += 1; return seen > 4 }() }
        }
        if blurs.isEmpty && keep == SIMD3(repeating: 1) { return nil }
        return Plan(keep: SIMD4(SIMD3<Float>(keep), 0), blurs: blurs, precise: precise)
    }

    /// `keep·image + Σ weight·(G_σ ⊛ image)` over the image's extent. An empty image gives an empty
    /// one; an infinite one is refused (crop first).
    static func mix(_ image: CIImage, keep: SIMD3<Double>, _ components: [Component]) -> CIImage {
        guard let plan = plan(keep: keep, components) else { return image.extent.isEmpty ? .empty() : image }
        return mix(image, plan)
    }

    /// One plan as its own Core Image pass.
    static func mix(_ image: CIImage, _ plan: Plan) -> CIImage {
        let extent = image.extent
        guard !extent.isEmpty else { return .empty() }
        guard !extent.isInfinite else { assertionFailure("the film needs a finite extent: crop first"); return .empty() }
        return (try? PhotoEngine.apply(FilmMixPass.self, extent: extent, inputs: [image.clampedToExtent()], arguments: ["plan": plan])) ?? .empty()
    }

    // MARK: - The kernels' weights

    /// A blur's taps, at full size or halved `factor` times over, normalised to 1.
    /// - Kind X, and kind W under 3 px: the sampled Gaussian, out to floor(3σ + 0.5) (1…512).
    /// - Kind W from 3 px: the recursive Gaussian's own response (`recursive`). Its core is σ wide and
    ///   its exponential tail makes it σ_eff wide; a plain Gaussian of σ_eff puts too little light near
    ///   a point and too much at middle distance (that shows round bright lights).
    /// Halved, the halvings' and doublings' own widths ((f² − 1)/4 each) come out of the variance first:
    /// the recursive response of the σ whose σ_eff² is what's left, read every f pixels (or a
    /// Gaussian of what's left, for kind X).
    static func taps(_ sigma: Double, wide: Bool, factor: Int) -> [Double] {
        guard sigma > 0 else { return [1] }
        let f = Double(factor)
        func normalised(_ raw: [Double]) -> [Double] { let total = raw.reduce(0, +); return raw.map { $0 / total } }
        if wide && sigma >= 3 {
            if factor == 1 { return recursive(sigma) }
            let left = pow(effectiveSigma(sigma), 2) - (f * f - 1) / 2
            if left >= pow(effectiveSigma(3), 2) {
                var lo = 3.0, hi = sigma
                for _ in 0..<60 { let mid = (lo + hi) / 2; if pow(effectiveSigma(mid), 2) < left { lo = mid } else { hi = mid } }
                let fine = recursive(hi), c = fine.count / 2, r = c / factor
                return normalised((-r...r).map { fine[c + $0 * factor] })
            }
        }
        var s = sigma, r: Int
        if factor > 1 {
            let width = wide ? effectiveSigma(sigma) : sigma
            s = (max(width * width - (f * f - 1) / 2, 0.01)).squareRoot() / f
            r = max(Int(ceil(4 * s)), 1)
        } else {
            r = min(max(Int(floor(3 * sigma + 0.5)), 1), 512)
        }
        return normalised((-r...r).map { exp(-Double($0 * $0) / (2 * s * s)) })
    }

    /// The impulse response of kind W's recursive Gaussian at σ ≥ 3 (§1.3: Young and van Vliet's
    /// third-order filter, run forwards then backwards; above 150 px, n passes at σ/√n), cut where
    /// less than 1e-4 is left on each side, normalised. σ is rounded to 1/256 of a stop (0.27 %), and
    /// the last 64 are kept.
    static func recursive(_ sigma: Double) -> [Double] {
        let step = (log2(sigma) * 256).rounded()
        let sigma = exp2(step / 256)
        recursiveLock.lock(); defer { recursiveLock.unlock() }
        if let known = recursiveTaps[step] {
            recursiveOrder.removeAll { $0 == step }; recursiveOrder.append(step)
            return known
        }
        let n = sigma > 150 ? Int(ceil(pow(sigma / 150, 2))) : 1
        let (b1, b2, b3) = coefficients(sigma / Double(n).squareRoot())
        let gain = 1 - b1 - b2 - b3
        let reach = Int(ceil(10 * effectiveSigma(sigma))) + 16
        var y = [Double](repeating: 0, count: 2 * reach + 1)
        y[reach] = 1
        func at(_ i: Int) -> Double { i >= 0 && i < y.count ? y[i] : 0 }
        for _ in 0..<n {
            for i in 0..<y.count { y[i] = gain * y[i] + b1 * at(i - 1) + b2 * at(i - 2) + b3 * at(i - 3) }
            for i in stride(from: y.count - 1, through: 0, by: -1) { y[i] = gain * y[i] + b1 * at(i + 1) + b2 * at(i + 2) + b3 * at(i + 3) }
        }
        var r = reach, tail = 0.0
        while r > 1, tail + y[reach + r] < 1e-4 { tail += y[reach + r]; r -= 1 }
        let raw = (-r...r).map { (y[reach + $0] + y[reach - $0]) / 2 }
        let total = raw.reduce(0, +)
        let taps = raw.map { $0 / total }
        recursiveTaps[step] = taps; recursiveOrder.append(step)
        while recursiveOrder.count > 64 { recursiveTaps[recursiveOrder.removeFirst()] = nil }
        return taps
    }
    nonisolated(unsafe) private static var recursiveTaps: [Double: [Double]] = [:]
    nonisolated(unsafe) private static var recursiveOrder: [Double] = []
    private static let recursiveLock = NSLock()

    /// The recursive filter's feedback coefficients b1, b2, b3 at σ (Young and van Vliet, 1995).
    private static func coefficients(_ s: Double) -> (Double, Double, Double) {
        let q = 0.98711 * s - 0.96330, q2 = q * q, q3 = q2 * q
        let b0 = 1.57825 + 2.44413 * q + 1.4281 * q2 + 0.422205 * q3
        return ((2.44413 * q + 2.85619 * q2 + 1.26661 * q3) / b0, -(1.4281 * q2 + 1.26661 * q3) / b0, 0.422205 * q3 / b0)
    }

    /// The width of a kind W blur asked for σ (§1.3): σ below 3 px, else the width of the
    /// third-order recursive Gaussian of Young and van Vliet (1995), cascaded above 150 px.
    static func effectiveSigma(_ sigma: Double) -> Double {
        guard sigma >= 3 else { return sigma }
        func variance(_ s: Double) -> Double {
            let (b1, b2, b3) = coefficients(s)
            let S = 1 - b1 - b2 - b3, P = b1 + 2 * b2 + 3 * b3, Q = b1 + 4 * b2 + 9 * b3
            return 2 * (P * P / (S * S) + Q / S)
        }
        guard sigma > 150 else { return variance(sigma).squareRoot() }
        let n = ceil(pow(sigma / 150, 2))
        return (n * variance(sigma / n.squareRoot())).squareRoot()
    }

    // MARK: - Running the passes

    static let failed = NSError(domain: "Pluck", code: 10, userInfo: [NSLocalizedDescriptionKey: "The GPU isn't available."])

    /// The numbers the blur passes read (laid out as `BlurParams` in the shader).
    struct Params {
        var keep = SIMD4<Float>()
        var coarser = SIMD4<Float>()
        var origin = SIMD4<Float>()
        var radius: Int32 = 0, temps: Int32 = 0, levels: Int32 = 0, narrow: Int32 = 0
        /// Each blur's own reach in the pass down (the taps are laid out for the largest).
        var radii = SIMD4<Int32>()
    }

    /// A texture and where it sits: its top-left corner (minX, maxY) in its own size's pixels.
    struct Place {
        var texture: MTLTexture
        var minX: Int, maxY: Int
        var width: Int { texture.width }
        var height: Int { texture.height }
        init(_ texture: MTLTexture, minX: Int, maxY: Int) { self.texture = texture; self.minX = minX; self.maxY = maxY }
        init(_ texture: MTLTexture, region: CGRect) { self.init(texture, minX: Int(region.minX.rounded(.down)), maxY: Int(region.maxY.rounded(.up))) }
        /// The offset from a pixel of `target` to the same place in this texture (rows top-down).
        func offset(from target: Place) -> SIMD2<Int32> { SIMD2(Int32(target.minX - minX), Int32(maxY - target.maxY)) }
    }

    /// One pass's worth of dispatches, into one compute encoder (they run one after another).
    final class Passes {
        let encoder: MTLComputeCommandEncoder
        let device: MTLDevice
        private let queue: ObjectIdentifier
        /// Keep the in-between images for the next render (false: they go with this one).
        var pooled = true

        init?(_ buffer: MTLCommandBuffer) {
            guard let encoder = buffer.makeComputeCommandEncoder() else { return nil }
            self.encoder = encoder; device = buffer.device; queue = ObjectIdentifier(buffer.commandQueue)
        }

        func end() { encoder.endEncoding() }

        /// An in-between image (half floats unless `float`), kept for the next render of the same size.
        func scratch(_ role: String, _ width: Int, _ height: Int, float: Bool = false) throws -> MTLTexture {
            guard let texture = Pool.shared.texture(role, width: max(width, 1), height: max(height, 1), format: float ? .rgba32Float : .rgba16Float,
                                                    device: device, queue: queue, keep: pooled) else { throw failed }
            return texture
        }

        func dispatch(_ name: String, _ textures: [MTLTexture], params: Data, taps: [SIMD4<Float>], offsets: [SIMD2<Int32>], size: (Int, Int),
                      held: (Plan, String)? = nil) throws {
            guard let state = FilmLook.Library.shared.pipeline(name, device: device) else { throw failed }
            encoder.setComputePipelineState(state)
            for (i, texture) in textures.enumerated() { encoder.setTexture(texture, index: i) }
            params.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: params.count, index: 0) }
            let taps = taps.isEmpty ? [SIMD4<Float>.zero] : taps
            // Small tap lists go inline; a very wide blur's need a buffer (setBytes stops at 4 KB), kept with its plan.
            let length = MemoryLayout<SIMD4<Float>>.stride * taps.count
            if length <= 4096 {
                taps.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: length, index: 1) }
            } else if let buffer = held.map({ $0.0.buffer($0.1, device: device, taps: taps) }) ?? taps.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: length) }) {
                encoder.setBuffer(buffer, offset: 0, index: 1)
            } else { throw failed }
            var offsets = offsets + [SIMD2<Int32>](repeating: .zero, count: max(0, 5 - offsets.count))
            encoder.setBytes(&offsets, length: MemoryLayout<SIMD2<Int32>>.stride * offsets.count, index: 2)
            let width = state.threadExecutionWidth, height = max(state.maxTotalThreadsPerThreadgroup / width, 1)
            encoder.dispatchThreads(MTLSize(width: size.0, height: size.1, depth: 1), threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
        }

        private func dispatch(_ name: String, _ textures: [MTLTexture], params: Params, taps: [SIMD4<Float>], offsets: [SIMD2<Int32>], size: (Int, Int),
                              held: (Plan, String)? = nil) throws {
            try dispatch(name, textures, params: withUnsafeBytes(of: params) { Data($0) }, taps: taps, offsets: offsets, size: size, held: held)
        }

        /// One of the film's per-pixel passes (FilmLook's shaders): the inputs, the stock's tables, the output.
        func perPixel(_ name: String, _ inputs: [Place], tables: [MTLTexture], params: Data, onto target: Place) throws {
            guard let state = FilmLook.Library.shared.pipeline(name, device: device) else { throw failed }
            encoder.setComputePipelineState(state)
            var index = 0
            for texture in inputs.map(\.texture) + tables { encoder.setTexture(texture, index: index); index += 1 }
            encoder.setTexture(target.texture, index: index)
            var params = params
            if params.count < MemoryLayout<FilmLook.Params>.stride { params.append(Data(count: MemoryLayout<FilmLook.Params>.stride - params.count)) }
            params.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: params.count, index: 0) }
            var offsets = inputs.map { $0.offset(from: target) }
            encoder.setBytes(&offsets, length: MemoryLayout<SIMD2<Int32>>.stride * offsets.count, index: 1)
            let width = state.threadExecutionWidth, height = max(state.maxTotalThreadsPerThreadgroup / width, 1)
            encoder.dispatchThreads(MTLSize(width: target.width, height: target.height, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
        }

        /// The blurs' passes across, all at once (one read of each source pixel), onto up to four images.
        private func across(_ blurs: [Blur], from: MTLTexture, offset: SIMD2<Int32>, size: (Int, Int), role: String, plan: Plan, precise: Bool) throws
            -> (images: [MTLTexture], radius: Int, radii: [Int], down: [SIMD4<Float>]) {
            let radius = blurs.map(\.radius).max() ?? 0
            var taps = [SIMD4<Float>](repeating: .zero, count: 4 * (2 * radius + 1)), down = taps
            for (k, blur) in blurs.enumerated() {
                // The pass down uses the same (symmetric) taps without the weight, which the pass across has.
                let total = blur.taps.reduce(SIMD4<Float>.zero, +)
                for (i, t) in blur.taps.enumerated() {
                    let at = (i - blur.radius + radius) * 4 + k
                    taps[at] = t
                    down[at] = SIMD4((0..<4).map { total[$0] != 0 ? t[$0] / total[$0] : 0 })
                }
            }
            let images = try (0..<blurs.count).map { try scratch("\(role).\($0)", size.0, size.1, float: precise) }
            guard !images.isEmpty else { return ([], 0, [], down) }
            var params = Params()
            params.radius = Int32(radius); params.temps = Int32(images.count); params.narrow = precise ? 0 : 1
            try dispatch("filmBlurH", [from] + (0..<4).map { images[min($0, images.count - 1)] }, params: params, taps: taps, offsets: [offset], size: size,
                         held: (plan, "\(role)-across"))
            return (images, radius, blurs.map(\.radius), down)
        }

        /// The pass down onto `target`: keep · source + the blurs across + the smaller sum (doubled).
        private func down(_ temps: (images: [MTLTexture], radius: Int, radii: [Int], down: [SIMD4<Float>]), source: Place, tempOffset: SIMD2<Int32>,
                          coarser: Place?, keep: SIMD4<Float>, onto target: Place, narrow: Bool, held: (Plan, String)) throws {
            var params = Params()
            params.keep = keep; params.radius = Int32(temps.radius); params.temps = Int32(temps.images.count); params.narrow = narrow ? 1 : 0
            for (k, r) in temps.radii.prefix(4).enumerated() { params.radii[k] = Int32(r) }
            params.origin = SIMD4(Float(target.minX), Float(target.maxY), 0, 0)
            if let coarser { params.levels = 1; params.coarser = SIMD4(2, Float(coarser.minX), Float(coarser.maxY), 0) }
            let slots = (0..<4).map { temps.images.isEmpty ? source.texture : temps.images[min($0, temps.images.count - 1)] }
            try dispatch("filmBlurV", [source.texture] + slots + [coarser?.texture ?? source.texture, target.texture], params: params, taps: temps.down,
                         offsets: [source.offset(from: target)] + [SIMD2<Int32>](repeating: tempOffset, count: 4), size: (target.width, target.height), held: held)
        }

        /// `plan` from `source` onto `target` (any place inside it, the same or smaller).
        func mix(_ plan: Plan, from source: Place, onto target: Place) throws {
            // The halved copies: pixel j of each sits between pixels 2j and 2j + 1 of the one before.
            // Each reaches a little past the one before (its blur's reach), so that past the photo's
            // edge a halved blur reads the edge repeated at full size, not its own edge repeated.
            var copies: [Int: Place] = [1: source]
            var f = 1
            let beyond = (plan.blurs.filter { $0.factor > 1 }.map(\.radius).max() ?? 0) + 2
            while f < plan.factor {
                let from = copies[f]!
                let minX = Int(floor(Double(from.minX) / 2)) - beyond, maxX = Int(ceil(Double(from.minX + from.width) / 2)) + beyond
                let maxY = Int(ceil(Double(from.maxY) / 2)) + beyond, minY = Int(floor(Double(from.maxY - from.height) / 2)) - beyond
                let next = Place(try scratch("half\(2 * f)", maxX - minX, maxY - minY), minX: minX, maxY: maxY)
                var params = Params(); params.narrow = 1
                try dispatch("filmHalve", [from.texture, next.texture], params: params, taps: [],
                             offsets: [SIMD2(Int32(2 * next.minX - from.minX), Int32(from.maxY - 2 * next.maxY))], size: (next.width, next.height))
                f *= 2
                copies[f] = next
            }
            // From the smallest copy up: each size's own blurs, plus the size below's sum, doubled.
            var coarser: Place?
            while f > 1 {
                let copy = copies[f]!
                let temps = try across(plan.blurs.filter { $0.factor == f }, from: copy.texture, offset: .zero, size: (copy.width, copy.height), role: "across\(f)",
                                       plan: plan, precise: false)
                let sum = Place(try scratch("sum\(f)", copy.width, copy.height), minX: copy.minX, maxY: copy.maxY)
                try down(temps, source: copy, tempOffset: .zero, coarser: coarser, keep: .zero, onto: sum, narrow: true, held: (plan, "down\(f)"))
                coarser = sum
                f /= 2
            }
            // Full size: the narrow blurs' passes across cover the output and their reach above and below.
            let full = plan.blurs.filter { $0.factor == 1 }, reach = full.map(\.radius).max() ?? 0
            let offset = source.offset(from: target)
            let temps = try across(full, from: source.texture, offset: SIMD2(offset.x, offset.y - Int32(reach)), size: (target.width, target.height + 2 * reach),
                                   role: "across1", plan: plan, precise: plan.precise)
            try down(temps, source: source, tempOffset: SIMD2(0, Int32(reach)), coarser: coarser, keep: plan.keep, onto: target,
                     narrow: target.texture.pixelFormat == .rgba16Float, held: (plan, "down1"))
        }
    }

    /// The passes' in-between images, kept for the next render of the same size (a preview being
    /// redrawn) instead of being made each time. Kept per command queue: a queue runs its work in
    /// order, so the next user of a texture waits for the last. The oldest go first, past a budget of
    /// 1/8 of what the GPU should hold (at most 1.5 GB). Images bigger than a preview's (an export's)
    /// aren't kept: they go with their render. Memory pressure empties it.
    final class Pool: @unchecked Sendable {
        static let shared = Pool()
        private struct Key: Hashable {
            let queue: ObjectIdentifier, device: UInt64, role: String, width: Int, height: Int, format: UInt
        }
        private var textures: [Key: MTLTexture] = [:]
        private var order: [Key] = []
        private var bytes = 0
        private let lock = NSLock()
        private var pressure: DispatchSourceMemoryPressure?

        /// Images with more pixels than this (a 4096 × 2800 preview: the largest screen size) aren't kept.
        static let largest = 4096 * 2800

        private init() {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
            source.setEventHandler { [weak self] in self?.purge() }
            source.resume()
            pressure = source
        }

        func texture(_ role: String, width: Int, height: Int, format: MTLPixelFormat, device: MTLDevice, queue: ObjectIdentifier,
                     keep: Bool = true) -> MTLTexture? {
            let key = Key(queue: queue, device: device.registryID, role: role, width: width, height: height, format: format.rawValue)
            lock.lock(); defer { lock.unlock() }
            if refusing { return nil }
            if let known = textures[key] {
                order.removeAll { $0 == key }; order.append(key)
                return known
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            guard let made = device.makeTexture(descriptor: descriptor) else { return nil }
            let size = Self.size(made)
            let budget = min(Int(min(device.recommendedMaxWorkingSetSize / 8, UInt64(Int.max))), 1_500_000_000)
            guard keep, width * height <= Self.largest, size <= budget else { return made }
            textures[key] = made; order.append(key); bytes += size
            while order.count > 64 || bytes > budget, !order.isEmpty {
                let old = order.removeFirst()
                if let gone = textures.removeValue(forKey: old) { bytes -= Self.size(gone) }
            }
            return made
        }

        private static func size(_ t: MTLTexture) -> Int { t.width * t.height * (t.pixelFormat == .rgba32Float ? 16 : 8) }

        /// Drops every kept image (a texture still in use stays alive until its render is done).
        func purge() { lock.lock(); textures = [:]; order = []; bytes = 0; lock.unlock() }

        /// Tests: every new image is refused, as when the GPU is out of memory.
        var refuse: Bool {
            get { lock.withLock { refusing } }
            set { lock.withLock { refusing = newValue } }
        }
        private var refusing = false
    }

    // MARK: - The shaders (compiled with FilmLook's)

    static let shaders = #"""

    struct BlurParams {
        float4 keep;                // the source's share, per channel
        float4 coarser;             // the smaller sum to double: 2, its texture's minX and maxY
        float4 origin;              // the output's minX and maxY
        int radius;                 // taps either side
        int temps;                  // images across (pass across: made; pass down: summed)
        int levels;                 // 1 when there's a smaller sum to add
        int narrow;                 // the output is half floats: keep it in range
        int4 radii;                 // each blur's own reach in the pass down
    };

    typedef texture2d<float, access::read> Plane;
    typedef texture2d<float, access::write> Out;

    // A pixel, the edge repeated past the texture; NaN read as 0 and ±inf as ±1e30, so a zero tap
    // never meets an infinity (0 · inf would be NaN) and an extreme light stays an extreme light.
    inline float4 clamped(Plane t, int2 p) {
        float4 v = t.read(uint2(clamp(p, int2(0), int2(t.get_width(), t.get_height()) - 1)));
        return clamp(select(v, float4(0.0), isnan(v)), -1e30, 1e30);
    }

    // For a half-float output: in range, and rounded to nearest here (the texture write may round towards 0,
    // which would darken every pass by up to 0.05 %).
    inline float3 toHalf(float3 v) { return float3(half3(clamp(v, -65000.0, 65000.0))); }
    inline float3 inRange(float3 v, constant BlurParams &p) { return p.narrow != 0 ? toHalf(v) : v; }

    // One pixel of the next halved copy: (1, 3, 3, 1)/8 both ways around its two-by-two block
    // (the block's top-left texel is 2 · gid + offset).
    kernel void filmHalve(Plane src [[texture(0)]], Out dst [[texture(1)]],
                          constant BlurParams &p [[buffer(0)]], constant float4 *w [[buffer(1)]],
                          constant int2 *offsets [[buffer(2)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        int2 b = 2 * int2(gid) + offsets[0];
        const float k[4] = {0.125, 0.375, 0.375, 0.125};
        float3 s = float3(0.0);
        for (int j = 0; j < 4; j++) {
            float3 row = float3(0.0);
            for (int i = 0; i < 4; i++) row += k[i] * clamped(src, b + int2(i - 1, j - 1)).rgb;
            s += k[j] * row;
        }
        dst.write(float4(toHalf(s), 1.0), gid);
    }

    // Up to four blurs across the rows at once (their weights included), from one read of each pixel.
    kernel void filmBlurH(Plane src [[texture(0)]], Out d0 [[texture(1)]], Out d1 [[texture(2)]], Out d2 [[texture(3)]], Out d3 [[texture(4)]],
                          constant BlurParams &p [[buffer(0)]], constant float4 *w [[buffer(1)]],
                          constant int2 *offsets [[buffer(2)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= d0.get_width() || gid.y >= d0.get_height()) return;
        int2 q = int2(gid) + offsets[0];
        float3 s0 = float3(0.0), s1 = float3(0.0), s2 = float3(0.0), s3 = float3(0.0);
        for (int i = -p.radius; i <= p.radius; i++) {
            float3 v = clamped(src, q + int2(i, 0)).rgb;
            constant float4 *t = w + (i + p.radius) * 4;
            s0 += t[0].rgb * v; s1 += t[1].rgb * v; s2 += t[2].rgb * v; s3 += t[3].rgb * v;
        }
        d0.write(float4(inRange(s0, p), 1.0), gid);
        if (p.temps > 1) d1.write(float4(inRange(s1, p), 1.0), gid);
        if (p.temps > 2) d2.write(float4(inRange(s2, p), 1.0), gid);
        if (p.temps > 3) d3.write(float4(inRange(s3, p), 1.0), gid);
    }

    // Blur k of the pass down, from its pass across.
    inline float3 column(Plane t, int2 q, int k, constant BlurParams &p, constant float4 *w) {
        float3 sum = float3(0.0);
        int r = p.radii[k];
        for (int i = -r; i <= r; i++) sum += w[(i + p.radius) * 4 + k].rgb * clamped(t, q + int2(0, i)).rgb;
        return sum;
    }

    // The smaller sum at this pixel: bilinear between its pixel centres (a quarter and three quarters of the way).
    inline float3 doubled(Plane t, uint2 gid, constant BlurParams &p) {
        float f = p.coarser.x;
        float x = (p.origin.x + float(gid.x) + 0.5) / f - 0.5 - p.coarser.y;
        float y = p.coarser.z - 0.5 - (p.origin.y - float(gid.y) - 0.5) / f;
        float2 a = floor(float2(x, y)), t2 = float2(x, y) - a;
        int2 i = int2(a);
        float3 top = mix(clamped(t, i).rgb, clamped(t, i + int2(1, 0)).rgb, t2.x);
        float3 bottom = mix(clamped(t, i + int2(0, 1)).rgb, clamped(t, i + int2(1, 1)).rgb, t2.x);
        return mix(top, bottom, t2.y);
    }

    // The pass down: keep · source + every blur + the smaller sum.
    kernel void filmBlurV(Plane src [[texture(0)]],
                          Plane t0 [[texture(1)]], Plane t1 [[texture(2)]], Plane t2 [[texture(3)]], Plane t3 [[texture(4)]],
                          Plane small [[texture(5)]], Out dst [[texture(6)]],
                          constant BlurParams &p [[buffer(0)]], constant float4 *w [[buffer(1)]],
                          constant int2 *offsets [[buffer(2)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 s = clamped(src, int2(gid) + offsets[0]);
        float3 out = p.keep.rgb * s.rgb;
        if (p.temps > 0) out += column(t0, int2(gid) + offsets[1], 0, p, w);
        if (p.temps > 1) out += column(t1, int2(gid) + offsets[2], 1, p, w);
        if (p.temps > 2) out += column(t2, int2(gid) + offsets[3], 2, p, w);
        if (p.temps > 3) out += column(t3, int2(gid) + offsets[4], 3, p, w);
        if (p.levels > 0) out += doubled(small, gid, p);
        dst.write(float4(inRange(out, p), s.a), gid);
    }
    """#
}

/// One mix of blurs (FilmBlur): float in and out, the in-between images half floats. A tile reads
/// its plan's margin around itself; past the image's edge the input repeats its edge pixels.
final class FilmMixPass: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAf }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        let margin = CGFloat((arguments?["plan"] as? FilmBlur.Plan)?.margin ?? 0)
        return outputRect.insetBy(dx: -margin, dy: -margin)
    }
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let plan = arguments?["plan"] as? FilmBlur.Plan, let input = inputs?.first, let buffer = output.metalCommandBuffer,
              let target = output.metalTexture, let source = input.metalTexture ?? PhotoEngine.upload(input, device: buffer.device),
              let passes = FilmBlur.Passes(buffer) else { throw FilmBlur.failed }
        defer { passes.end() }
        try passes.mix(plan, from: FilmBlur.Place(source, region: input.region), onto: FilmBlur.Place(target, region: output.region))
    }
}

/// The whole film with its spatial stages (FilmHalation.chain): scene light in, linear sRGB out.
class FilmSpatialPass: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAf }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        guard let chain = arguments?["chain"] as? FilmHalation.Chain else { return outputRect }
        // Only the photo itself: past its edges every stage repeats the edge pixels on its own. (Asking for the
        // stages' whole reach around the photo would have Core Image work out the scene there too, and split a
        // screen-size preview in two, each half with that reach.)
        let wanted = outputRect.insetBy(dx: -CGFloat(chain.margin), dy: -CGFloat(chain.margin))
        let inside = wanted.intersection(chain.extent.integral)
        return inside.isEmpty ? wanted : inside
    }
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let chain = arguments?["chain"] as? FilmHalation.Chain, let input = inputs?.first else { FilmHalation.noteFailure(); throw FilmBlur.failed }
        do { try FilmHalation.render(chain, input: input, output: output) } catch { FilmHalation.noteFailure(); throw error }
    }
}

/// The same for the screen: half floats in and out.
final class FilmSpatialPreviewPass: FilmSpatialPass {
    override class var outputFormat: CIFormat { .RGBAh }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }
}
