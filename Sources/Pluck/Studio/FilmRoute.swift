import CryptoKit
import Foundation

/// How a photo's film is made, from its settings (docs/superpowers/specs/2026-11-04-film-tables-format.md §6,
/// and the behaviour document §7):
/// - `instant`: the shipped tables hold it and Pluck's own GPU stages do the rest, in the develop chain
///   (as quick as any slider);
/// - `tables`: a setting that changes the tables is changed, so they must be made for this photo first
///   (`key` names them: the stock and those settings, and the exposures when they're baked in too);
/// - `helper`: a spatial effect Pluck doesn't do itself is on, or the stock isn't in the shipped tables:
///   the whole film through `pluck-spektra`.
enum FilmRoute: Equatable {
    case instant, tables(key: String), helper

    static func of(_ record: PhotoRecord) -> FilmRoute { of(record.film) }

    static func of(_ film: FilmSettings) -> FilmRoute {
        let tables = FilmTables.shared
        guard let profile = tables.films.first(where: { $0.id == film.film }) else { return .helper }
        let scanned = film.scanned
        if !scanned, !tables.pairs.contains("\(film.film)__\(film.paper)") { return .helper }
        // A stock whose tables are listed but wouldn't load: the helper, everywhere alike.
        if lock.withLock({ unloadable.contains(stockKey(film)) }) { return .helper }
        // The rare spatial effects Pluck doesn't do itself (off by default), when they're on, and any setting it doesn't know.
        func on(_ key: String, _ standard: Double) -> Bool {
            let value: Double = film.number(key) ?? standard
            return value > (key.hasSuffix("_on") ? 0.5 : 0)
        }
        let diffusion = on("diffusion_on", 0) && on("diffusion_strength", 0.5)
        let printDiffusion = on("print_diffusion_on", 0) && on("print_diffusion_strength", 0.5)
        if on("boost_ev", 0) || diffusion || (!scanned && (on("glare_percent", 0) || printDiffusion)) { return .helper }
        let known = Set(instantKeys + filmKeys + printKeys + offStages + ["scan_film"])
        if film.changed.keys.contains(where: { !known.contains($0) }) { return .helper }
        // The settings that change the tables (a scanned photo has no print, so the print's don't count then).
        var changed = filmKeys.filter { film.differs($0) }
        if !scanned {
            // The pre-flash's colour only matters while there is a pre-flash.
            let flash = film.differs("preflash_exposure")
            changed += printKeys.filter { film.differs($0) && (flash || !["preflash_m_shift", "preflash_y_shift"].contains($0)) }
        }
        // A negative looked at without a print needs its film's scan, which only the slides ship with.
        let ownScan = scanned && profile.type != "positive"
        guard !changed.isEmpty || ownScan else { return .instant }
        var key = "\(film.film)|\(scanned ? "" : film.paper)|scan \(scanned ? 1 : 0)"
        for name in changed.sorted() { key += "|\(name) \(film.number(name) ?? .nan)" }
        // With auto print exposure the exposures are made into the tables too (format document §6).
        if !scanned, film.differs("print_auto_exposure") {
            key += "|exposure_ev \(film.number("exposure_ev") ?? 0)|print_exposure_ev \(film.number("print_exposure_ev") ?? 0)"
        }
        return .tables(key: SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined())
    }

    /// The stock for the GPU: the shipped one for a photo whose film is instant (the film alone when it's scanned), or
    /// the tables made for its advanced settings once they're there (FilmAdvanced); nil otherwise. Blocking: it may
    /// read the tables. A shipped one that won't load is remembered, and its photos go to the helper from then on.
    static func stock(_ film: FilmSettings) -> FilmStock? {
        switch of(film) {
        case .instant:
            let paper = film.scanned ? nil : film.paper
            let key = stockKey(film)
            if let stock = FilmTables.shared.stock(film: film.film, paper: paper) { lock.withLock { _ = misses.removeValue(forKey: key) }; return stock }
            // Damaged files, or a second miss in a row for any other reason: the helper from now on (never a blank picture).
            // A single miss (no GPU memory for it right now) is tried again next time.
            let damaged = FilmTables.shared.damaged(film: film.film, paper: paper)
            lock.withLock {
                misses[key, default: 0] += 1
                if damaged || misses[key, default: 0] >= 2 { unloadable.insert(key) }
            }
            return nil
        case .tables(let key): return FilmAdvanced.made(key)
        case .helper: return nil
        }
    }

    /// The route once the stock has been tried (blocking, like `stock`): what preview and export will do. `instant`: on
    /// the GPU (the advanced settings' tables too, once made); `tables`: they're still to be made; `helper`: the helper,
    /// also when those tables couldn't be made.
    static func resolved(_ film: FilmSettings) -> FilmRoute {
        let route = of(film)
        switch route {
        case .instant: return stock(film) == nil ? .helper : .instant
        case .tables(let key): return FilmAdvanced.made(key) != nil ? .instant : FilmAdvanced.failed(key) ? .helper : route
        case .helper: return .helper
        }
    }

    /// The stock for the GPU, waiting for the advanced settings' tables to be made when they must be (exports: never
    /// without the film). nil: the helper develops it.
    static func stockWaiting(_ film: FilmSettings) async -> FilmStock? {
        if let stock = stock(film) { return stock }
        guard case .tables = of(film) else { return nil }
        return await FilmAdvanced.shared.wait(for: film)
    }

    /// Whether the GPU can do this film now without waiting (what's in memory only: for view properties).
    static func ready(_ film: FilmSettings) -> Bool {
        switch of(film) {
        case .instant: return true
        case .tables(let key): return FilmAdvanced.inMemory(key)
        case .helper: return false
        }
    }

    nonisolated(unsafe) private static var unloadable: Set<String> = []
    /// Loads that gave nothing, in a row, per stock.
    nonisolated(unsafe) private static var misses: [String: Int] = [:]
    private static func stockKey(_ film: FilmSettings) -> String { film.film + "|" + (film.scanned ? "" : film.paper) }

    /// Forgets the stocks that wouldn't load (tests).
    static func forgetFailures() { lock.withLock { unloadable = []; misses = [:] } }

    /// Marks a stock as one that won't load (tests).
    static func markUnloadable(_ film: FilmSettings) { lock.withLock { _ = unloadable.insert(stockKey(film)) } }

    // MARK: - The settings, by what they change

    /// Never change a table: the two exposures (offsets in the recipe) and what Pluck's own stages read.
    static let instantKeys = ["exposure_ev", "print_exposure_ev"] + FilmHalation.settings + FilmGrain.settings

    /// Change the film's part (so they count scanned or printed). `grain_granularity` is exact for Pluck too
    /// (it only divides the particle counts), but the grain doesn't read it yet.
    static let filmKeys = ["push_pull_stops", "film_gamma_factor", "film_gamma_factor_fast", "film_gamma_factor_slow",
                           "film_developer_exhaustion", "couplers_amount", "couplers_inhibition_same", "couplers_inhibition_inter",
                           "grain_granularity", "grain_uniformity", "grain_sublayer_scale", "grain_density_min", "development_min",
                           "adaptation_bandwidth", "adaptation_surface", "output_luminance_boost", "output_scale", "gamut_compress"]

    /// Change only the paper's or the pair's part (no print, no change).
    static let printKeys = ["print_auto_exposure", "print_development_min", "filter_m", "filter_y", "preflash_exposure",
                            "preflash_m_shift", "preflash_y_shift", "print_contrast", "print_gamma_r", "print_gamma_g", "print_gamma_b"]

    /// The rare spatial effects' settings: they matter only while their effect is on (see `of`).
    static let offStages = ["boost_ev", "boost_range", "protect_ev", "glare_percent"]
        + ["on", "filter_family", "strength", "scale", "warmth"].flatMap { ["diffusion_\($0)", "print_diffusion_\($0)"] }

    /// The defaults of the settings that change tables (a setting at its default changes nothing): those the shipped
    /// tables were made at (their index), else these, the film engine's own (the self-tests check both against it).
    static let builtInDefaults: [String: Double] = [
        "push_pull_stops": 0, "film_gamma_factor": 1, "film_gamma_factor_fast": 1, "film_gamma_factor_slow": 1, "film_developer_exhaustion": 0,
        "couplers_amount": 1, "couplers_inhibition_same": 1, "couplers_inhibition_inter": 1, "grain_granularity": 1, "grain_uniformity": 1,
        "grain_sublayer_scale": 1, "grain_density_min": 1, "development_min": 0, "adaptation_bandwidth": 1, "adaptation_surface": 0,
        "output_luminance_boost": 1, "output_scale": 1, "gamut_compress": 1, "print_auto_exposure": 0, "print_development_min": 0,
        "filter_m": 0, "filter_y": 0, "preflash_exposure": 0, "preflash_m_shift": 0, "preflash_y_shift": 0, "print_contrast": 1,
        "print_gamma_r": 1, "print_gamma_g": 1, "print_gamma_b": 1, "scan_film": 0, "couplers_edge": FilmHalation.defaultCouplerEdge,
    ]
    private static let lock = NSLock()

    /// A setting's default, when known.
    static func standard(_ key: String) -> Double? { FilmTables.shared.defaults[key] ?? builtInDefaults[key] }
}

extension FilmSettings {
    /// Looked at without a print: `scan_film` on.
    var scanned: Bool { (number("scan_film") ?? 0) > 0.5 }

    /// Whether a setting is away from its default (one with no known default counts as changed while it's set).
    func differs(_ key: String) -> Bool {
        guard let value = number(key) else { return changed[key] != nil }
        guard let standard = FilmRoute.standard(key) else { return true }
        return abs(value - standard) > 1e-9
    }
}
