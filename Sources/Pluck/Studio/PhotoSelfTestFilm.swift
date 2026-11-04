import CoreImage
import Foundation
import Metal

/// The film tables (Task 4): every pair loads with the right shapes, repeat loads are cached, bad input is refused.
extension PhotoSelfTest {
    static func film() async {
        let tables = FilmTables.shared
        guard tables.isAvailable, let root = FilmTables.folder else {
            check("film tables load", false, "no FilmTables folder (looked at \(FilmTables.folder?.path ?? "nil"))")
            return
        }

        // Every film and paper in the index loads, and every pair, with the expected shapes.
        var failed: [String] = []
        var loaded = 0
        for pair in tables.pairs {
            let parts = pair.components(separatedBy: "__")
            guard parts.count == 2, let stock = tables.stock(film: parts[0], paper: parts[1]) else { failed.append(pair); continue }
            let t = stock.textures
            let ok = stock.film == parts[0] && stock.paper == parts[1] && !stock.scanned
                && t.exposeQ.width == 256 && t.exposeQ.height == 256 && t.exposeQ.pixelFormat == .rgba32Float
                && t.silver.width == 1021 && t.curves.width == 1021 && t.receive.width == 256 && t.silver.pixelFormat == .rgba32Float
                && t.printCurves?.width == 1021 && t.printExpose?.width == 33 && t.printExpose?.depth == 33 && t.printExpose?.pixelFormat == .rgba16Float
                && stock.arrays.curves.count == 1021 * 3 && stock.arrays.exposeQ.count == 256 * 256 * 3
                && stock.constants.exposeM.count == 9 && stock.constants.printLogOffset0 != nil && stock.constants.printLe0 != nil
                && (stock.hasPairScan ? t.scan.width == 97 && t.paperScanY == nil : t.scan.width == 81 && t.paperScanY?.pixelFormat == .r16Float && t.paperScanDlog?.width == 33)
                && stock.spatial["grain_sublayers"]?.number != nil && stock.spatial["halation_strength"]?.numbers?.count == 3
                && stock.spatial["grain_total_curve"]?.rows?.count == 256 && stock.spatial["grain_mono"]?.flag != nil
            if ok { loaded += 1 } else { failed.append(pair) }
        }
        // Positive films scanned without a print: the film's own scan.
        for film in tables.films where film.type == "positive" {
            guard let stock = tables.stock(film: film.id, paper: nil), stock.scanned, stock.paper == nil,
                  stock.textures.scan.width == 65, stock.textures.printExpose == nil, stock.constants.scanEvScale0 != nil else { failed.append(film.id + " (scan)"); continue }
            loaded += 1
        }
        check("film tables load", failed.isEmpty && loaded >= tables.pairs.count && !tables.pairs.isEmpty,
              "\(loaded) of \(tables.pairs.count) pairs ok; failed: \(failed.prefix(5))")

        // A second call comes from the cache.
        tables.purge()
        _ = tables.stock(film: "kodak_gold_200", paper: "kodak_2302")
        let t0 = Date()
        let again = tables.stock(film: "kodak_gold_200", paper: "kodak_2302")
        let ms = Date().timeIntervalSince(t0) * 1000
        check("film tables cached", again != nil && again === tables.stock(film: "kodak_gold_200", paper: "kodak_2302") && ms < 20, "second call \(ms) ms")
        check("film tables share parts", tables.stock(film: "kodak_gold_200", paper: "kodak_2383")?.textures.exposeQ === again?.textures.exposeQ,
              "the same film part should serve both papers")

        // Things that aren't there or can't be used.
        check("film unknown stock falls back", tables.stock(film: "no_such", paper: nil) == nil
              && tables.stock(film: "kodak_gold_200", paper: "no_such") == nil
              && tables.stock(film: "kodak_gold_200", paper: nil) == nil,
              "unknown film, unknown paper and a negative without a scan should all be nil")

        // Damaged files are refused without crashing.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-film-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let source = root.appendingPathComponent("film/fujifilm_provia_100f.pft")
        let good = (try? Data(contentsOf: source)) ?? Data()
        func broken(_ name: String, _ data: Data) -> FilmStock? {
            let url = temp.appendingPathComponent(name)
            try? data.write(to: url)
            return FilmTables.stock(at: url)
        }
        check("film tables load from a file", FilmTables.stock(at: source) != nil, "the untouched Provia file should load")
        var badMagic = good; if !badMagic.isEmpty { badMagic[0] = 0x58 }
        var hugeHeader = good; if hugeHeader.count > 8 { hugeHeader[7] = 0x7F }
        // Numbers that would overflow when added or multiplied are refused, not trapped.
        func withBlob(_ name: String, _ change: (inout [String: Any]) -> Void) -> FilmStock? {
            let length = good.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian) }
            guard good.count > 8 + length, var header = (try? JSONSerialization.jsonObject(with: good.subdata(in: 8..<8 + length))) as? [String: Any],
                  var blobs = header["blobs"] as? [String: Any], var entry = blobs["silver"] as? [String: Any] else { return nil }
            change(&entry)
            blobs["silver"] = entry; header["blobs"] = blobs
            guard let json = try? JSONSerialization.data(withJSONObject: header) else { return nil }
            var padded = json
            while (8 + padded.count) % 16 != 0 { padded.append(0x20) }
            var out = Data("PFT1".utf8)
            withUnsafeBytes(of: UInt32(padded.count).littleEndian) { out.append(contentsOf: $0) }
            out.append(padded); out.append(good.suffix(from: 8 + length))
            return broken(name, out)
        }
        check("film tables overflow is refused",
              withBlob("control.pft") { _ in } != nil   // the rewrite itself works, so the nils below mean something
                && withBlob("o1.pft") { $0["offset"] = Int.max } == nil && withBlob("o2.pft") { $0["shape"] = [Int.max, 2] } == nil
                && withBlob("o3.pft") { $0["size"] = 0 } == nil && withBlob("o4.pft") { $0["raw_size"] = 1 << 40 } == nil
                && withBlob("o5.pft") { $0["offset"] = true } == nil,
              "offset Int.max, shape [Int.max, 2], size 0, a huge raw_size and a boolean offset should all give nil")
        check("film tables corrupt file is refused",
              broken("truncated.pft", good.prefix(good.count / 2)) == nil && broken("tiny.pft", good.prefix(6)) == nil
                && broken("empty.pft", Data()) == nil && broken("magic.pft", badMagic) == nil
                && broken("noheader.pft", good.prefix(100)) == nil && broken("header.pft", hugeHeader) == nil,
              "a truncated, tiny, empty, wrong-magic or wrong-header-length file should give nil")

        // The numbers: run the colour chain on the CPU from the textures and check what comes out.
        var chain: [String] = []
        if let print = tables.stock(film: "kodak_gold_200", paper: "kodak_2302") {
            let low = evaluate(print, 0.045), mid = evaluate(print, 0.18), high = evaluate(print, 0.72)
            let neutral = zip(mid, [mid[1], mid[1], mid[1]]).allSatisfy { abs($0 - $1) < 0.12 }
            if !(low[1] < mid[1] && mid[1] < high[1]) { chain.append("not rising: \(low[1]) \(mid[1]) \(high[1])") }
            if !(mid[1] > 0.04 && mid[1] < 0.6) { chain.append("mid grey \(mid)") }
            if !neutral { chain.append("grey not neutral \(mid)") }
        } else { chain.append("no stock") }
        if let slide = tables.stock(film: "fujifilm_provia_100f", paper: nil) {
            let low = evaluate(slide, 0.045), mid = evaluate(slide, 0.18), high = evaluate(slide, 0.72)
            if !(low[1] < mid[1] && mid[1] < high[1]) { chain.append("slide not rising: \(low[1]) \(mid[1]) \(high[1])") }
            if !(mid[1] > 0.05 && mid[1] < 0.6) { chain.append("slide mid grey \(mid)") }
        } else { chain.append("no slide") }
        if let bw = tables.films.first(where: { $0.bw == true }), let paper = tables.papers.first,
           let stock = tables.stock(film: bw.id, paper: paper.id), stock.bw {
            let mid = evaluate(stock, 0.18)
            if !(abs(mid[0] - mid[1]) < 0.02 && abs(mid[2] - mid[1]) < 0.02) { chain.append("bw not neutral \(mid)") }
        } else { chain.append("no bw film") }
        check("film tables evaluate sensibly", chain.isEmpty, chain.joined(separator: "; "))

        await filmLook()
        await filmSpatial()
        await filmGrain()
        await filmInstant()
        await filmAdvanced()
    }

    // MARK: - A small CPU evaluator (steps 1–9 of the format document), for the checks above

    private static func evaluate(_ stock: FilmStock, _ grey: Float) -> [Float] {
        let c = stock.constants
        let m = c.exposeM
        let rgb: [Float] = [grey, grey, grey]
        let X = m[0] * rgb[0] + m[1] * rgb[1] + m[2] * rgb[2], Y = m[3] * rgb[0] + m[4] * rgb[1] + m[5] * rgb[2], Z = m[6] * rgb[0] + m[7] * rgb[1] + m[8] * rgb[2]
        let b = X + Y + Z
        let x = X / max(b, 1e-10), y = Y / max(b, 1e-10)
        let u = min(abs(1 - x), 1), v = min(max(y / max(1 - x, 1e-10), 0), 1)
        let q = bilinear(stock.arrays.exposeQ, 256, 256, u * 255, v * 255)
        let scale = Float(stock.scanned ? c.scanEvScale0 ?? 1 : c.evScale0)
        let le = q.map { log10(max(b * $0 * scale, 0) + 1e-10) }
        func line(_ table: [Float], _ n: Int, _ c: Int, _ at: Float) -> Float {
            let t = min(max(at, 0), Float(n - 1)); let i = min(Int(t), n - 2); let f = t - Float(i)
            return table[i * 3 + c] * (1 - f) + table[(i + 1) * 3 + c] * f
        }
        let step = Float(c.leStep), le0 = Float(c.le0)
        let silver = (0..<3).map { line(stock.arrays.silver, 1021, $0, (le[$0] - le0) / step) }
        let cm = c.couplerM
        let corr = (0..<3).map { cm[3 * $0] * silver[0] + cm[3 * $0 + 1] * silver[1] + cm[3 * $0 + 2] * silver[2] }
        let range = stock.textures.receiveRange
        let d: [Float] = (0..<3).map { ch in
            let lo = range.lo[ch], hi = range.hi[ch]
            let received = line(stock.arrays.receive, 256, ch, (corr[ch] - lo) / (hi - lo) * 255)
            return line(stock.arrays.curves, 1021, ch, (le[ch] - received - le0) / step)
        }
        if stock.scanned { return cube(stock.textures.scan, stock.textures.scanRange, d, 3) }
        let expose = cube(stock.textures.printExpose!, stock.textures.printExposeRange!, d, 3)
        let pe = expose.map { $0 + Float(c.printLogOffset0 ?? 0) }
        let pd = (0..<3).map { line(stock.arrays.printCurves!, 1021, $0, (pe[$0] - Float(c.printLe0 ?? 0)) / Float(c.printLeStep ?? 1)) }
        return cube(stock.textures.scan, stock.textures.scanRange, pd, 3)
    }

    private static func bilinear(_ table: [Float], _ w: Int, _ h: Int, _ fx: Float, _ fy: Float) -> [Float] {
        let tx = min(max(fx, 0), Float(w - 1)), ty = min(max(fy, 0), Float(h - 1))
        let x0 = min(Int(tx), w - 2), y0 = min(Int(ty), h - 2), ax = tx - Float(x0), ay = ty - Float(y0)
        return (0..<3).map { c in
            func at(_ x: Int, _ y: Int) -> Float { table[(y * w + x) * 3 + c] }
            return (at(x0, y0) * (1 - ax) + at(x0 + 1, y0) * ax) * (1 - ay) + (at(x0, y0 + 1) * (1 - ax) + at(x0 + 1, y0 + 1) * ax) * ay
        }
    }

    /// Trilinear lookup in a 3D RGBA16F texture, read back raw.
    private static func cube(_ texture: MTLTexture, _ range: FilmRange, _ input: [Float], _ ch: Int) -> [Float] {
        let n = texture.width
        var raw = [UInt16](repeating: 0, count: n * n * n * 4)
        raw.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: n * 8, bytesPerImage: n * n * 8,
                             from: MTLRegionMake3D(0, 0, 0, n, n, n), mipmapLevel: 0, slice: 0)
        }
        var idx = [Int](repeating: 0, count: 3), frac = [Float](repeating: 0, count: 3)
        for a in 0..<3 {
            let t = min(max((input[a] - range.lo[a]) / (range.hi[a] - range.lo[a]) * Float(n - 1), 0), Float(n - 1))
            idx[a] = min(Int(t), n - 2); frac[a] = t - Float(idx[a])
        }
        return (0..<3).map { c in
            var sum: Float = 0
            for corner in 0..<8 {
                let dx = corner & 1, dy = (corner >> 1) & 1, dz = (corner >> 2) & 1
                let w = (dx == 1 ? frac[0] : 1 - frac[0]) * (dy == 1 ? frac[1] : 1 - frac[1]) * (dz == 1 ? frac[2] : 1 - frac[2])
                let at = (((idx[2] + dz) * n + idx[1] + dy) * n + idx[0] + dx) * 4 + c
                sum += w * filmHalfToFloat(raw[at])
            }
            return sum
        }
    }
}

// MARK: - The film's colour on the GPU (Task 5), against today's helper

extension PhotoSelfTest {
    /// Floats in, floats out, linear sRGB throughout (so both renderers see exactly the same numbers).
    private static let floats: CIContext = {
        let options: [CIContextOption: Any] = [.workingColorSpace: linearSRGB, .workingFormat: CIFormat.RGBAf,
                                               .cacheIntermediates: false, .name: "Pluck Film Test"]
        return PhotoEngine.device.map { CIContext(mtlDevice: $0, options: options) } ?? CIContext(options: options)
    }()
    private static let linearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    /// The settings every colour check uses: the spatial stages off (they come in Tasks 6–7).
    private static let colourOnly: [String: SettingValue] = [
        "grain_on": .number(0), "halation_on": .number(0), "couplers_diffusion_um": .number(0),
        "couplers_tail_weight": .number(0), "scan_usm_amount": .number(0), "scan_blur": .number(0)]

    static func filmLook() async {
        let tables = FilmTables.shared
        var notes: [String] = []
        defer { writeNotes(notes) }

        // The formula itself, on a pair from Sharma, Wu and Dalal's published test data.
        let sharma = ciede2000(SIMD3(50, 2.6772, -79.7751), SIMD3(50, 0, -82.7485))
        let sharma2 = ciede2000(SIMD3(50, 2.5, 0), SIMD3(73, 25, -18))
        check("film deltaE2000 formula", abs(sharma - 2.0425) < 1e-4 && abs(sharma2 - 27.1492) < 1e-4, "2.0425 and 27.1492; got \(sharma), \(sharma2)")

        // The extremes stay finite through every stock, fused and in stages.
        let extremes: [Float] = [0, 0, 0, 1, -0.5, -0.5, -0.5, 1, 1e4, 1e4, 1e4, 1, .nan, .nan, .nan, 1,
                                 1e4, -0.5, .nan, 1, 0.18, .infinity, -.infinity, 1, -1e4, 0.5, 2, 1, 1e-30, 0, 1e-30, 1]
        let extreme = image(extremes, width: 8, height: 1)
        var unstable: [String] = []
        for (name, settings, stock) in stocks() {
            let geometry = FilmGeometry(full: extreme.extent)
            let fused = pixels(FilmLook.apply(extreme, stock: stock, settings: settings, geometry: geometry))
            let staged = pixels(FilmLook.printStage(FilmLook.develop(FilmLook.expose(extreme, stock: stock, ev: 0), stock: stock, settings: settings, geometry: geometry, diffuse: false),
                                               stock: stock, printEV: 0))
            if fused.count != extremes.count || staged.count != extremes.count || !(fused + staged).allSatisfy(\.isFinite) { unstable.append(name) }
        }
        // In stages too with the coupler correction split out, and at infinite exposures.
        if let portra = tables.stock(film: "kodak_portra_400", paper: "kodak_portra_endura") {
            for ev in [Double.infinity, -.infinity] {
                let geometry = FilmGeometry(full: extreme.extent)
                let out = pixels(FilmLook.printStage(FilmLook.develop(FilmLook.expose(extreme, stock: portra, ev: ev), stock: portra, settings: FilmSettings(), geometry: geometry, diffuse: true),
                                                stock: portra, printEV: -ev))
                if out.count != extremes.count || !out.allSatisfy(\.isFinite) { unstable.append("staged diffuse ev \(ev)") }
            }
        } else { unstable.append("no Portra stock") }
        check("film extreme light stays finite", unstable.isEmpty, "non-finite or missing output for \(unstable.prefix(8))")

        // Images made first and rendered later keep their stocks (many more than any cache holds).
        let grey = image([Float](repeating: 0.18, count: 4 * 4 * 4), width: 4, height: 4)
        let pending = stocks().prefix(40).map { FilmLook.apply(grey, stock: $0.2, settings: $0.1, geometry: FilmGeometry(full: grey.extent)) }
        tables.purge()
        let blank = pending.enumerated().filter { _, made in
            let out = pixels(made)
            return out.count != 64 || !out.allSatisfy(\.isFinite) || !(out[1] > 0.001)
        }.map(\.offset)
        check("film pending renders keep their stock", pending.count == 40 && blank.isEmpty, "blank or missing: \(blank.prefix(8)) of \(pending.count)")

        guard FilmEngine.helper != nil, FileManager.default.fileExists(atPath: FilmEngine.pack.appendingPathComponent(".complete").path) else {
            check("film colour matches reference", false, "the reference needs the helper and its pack (-PluckScreenshotEngine; looked at \(FilmEngine.pack.path))")
            return
        }
        let (atlas, regions) = testAtlas()

        // The stages one by one give what the fused pass gives (coupler correction split out too).
        var apart: [String] = []
        for (name, settings, stock) in stocks() where ["kodak_portra_400__kodak_portra_endura", "kodak_gold_200__kodak_2302",
                                                         "fujifilm_provia_100f", "kodak_doublex__kodak_2302"].contains(name) {
            let geometry = FilmGeometry(full: atlas.extent)
            let fused = pixels(FilmLook.apply(atlas, stock: stock, settings: settings, geometry: geometry))
            for diffuse in [false, true] {
                let staged = pixels(FilmLook.printStage(FilmLook.develop(FilmLook.expose(atlas, stock: stock, ev: 0), stock: stock, settings: settings, geometry: geometry, diffuse: diffuse),
                                                   stock: stock, printEV: 0))
                let worst = zip(fused, staged).map { abs($0 - $1) }.max() ?? .infinity
                if fused.count != staged.count || !(worst < 1e-4) { apart.append("\(name) diffuse \(diffuse): \(worst)") }
            }
        }
        check("film stages match the fused pass", apart.isEmpty, apart.joined(separator: "; "))

        // Every film on every paper, and each film shown without a print, against the helper.
        var results: [(name: String, part: String, mean: Double, p99: Double)] = []
        var missing: [String] = []
        let started = Date()
        for (name, settings, stock) in stocks() {
            let ours = FilmLook.apply(atlas, stock: stock, settings: settings, geometry: FilmGeometry(full: atlas.extent))
            let theirs = await reference(atlas, film: settings)
            guard theirs.extent == atlas.extent else { missing.append(name); continue }
            for (part, rect) in regions {
                let e = deltaE2000(ours.cropped(to: rect), theirs.cropped(to: rect))
                results.append((name, part, e.mean, e.p99))
            }
        }
        let worst = results.sorted { $0.p99 > $1.p99 }
        func line(_ r: (name: String, part: String, mean: Double, p99: Double)) -> String {
            "\(r.name) \(r.part): mean \(String(format: "%.3f", r.mean)) p99 \(String(format: "%.3f", r.p99))"
        }
        let bad = results.filter { !($0.mean < 1.0 && $0.p99 < 3.0) }
        notes.append("colour: \(results.count / max(regions.count, 1)) stocks × \(regions.count) images in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        notes.append("overall mean \(String(format: "%.4f", results.map(\.mean).reduce(0, +) / Double(max(results.count, 1)))), worst mean \(String(format: "%.4f", results.map(\.mean).max() ?? 0)), worst p99 \(String(format: "%.4f", worst.first?.p99 ?? 0))")
        for part in regions.map(\.0) {
            let of = results.filter { $0.part == part }
            notes.append("  \(part): worst mean \(String(format: "%.3f", of.map(\.mean).max() ?? 0)), worst p99 \(String(format: "%.3f", of.map(\.p99).max() ?? 0))")
        }
        notes.append("worst 10 by p99:")
        notes += worst.prefix(10).map { "  " + line($0) }
        check("film colour matches reference", bad.isEmpty && missing.isEmpty && results.count == stocks().count * regions.count,
              "\(bad.count) over the limits, no reference for \(missing.prefix(5)); worst: " + worst.prefix(10).map(line).joined(separator: "; "))

        // Exposure and print exposure at ±2 stops.
        var exposures: [(name: String, part: String, mean: Double, p99: Double)] = []
        if let stock = tables.stock(film: "kodak_portra_400", paper: "kodak_portra_endura") {
            for (key, ev) in [("exposure_ev", -2.0), ("exposure_ev", 2), ("print_exposure_ev", -2), ("print_exposure_ev", 2)] {
                var settings = FilmSettings()
                settings.film = "kodak_portra_400"; settings.paper = "kodak_portra_endura"
                settings.changed = colourOnly
                settings.changed[key] = .number(ev)
                let ours = FilmLook.apply(atlas, stock: stock, settings: settings, geometry: FilmGeometry(full: atlas.extent))
                let theirs = await reference(atlas, film: settings)
                guard theirs.extent == atlas.extent else { exposures.append(("\(key) \(ev)", "no reference", .infinity, .infinity)); continue }
                for (part, rect) in regions {
                    let e = deltaE2000(ours.cropped(to: rect), theirs.cropped(to: rect))
                    exposures.append(("\(key) \(ev)", part, e.mean, e.p99))
                }
            }
        }
        notes.append("exposure (Portra 400 on Endura):")
        notes += exposures.map { "  " + line($0) }
        check("film exposure matches reference", exposures.count == 16 && exposures.allSatisfy { $0.mean < 1.0 && $0.p99 < 3.0 },
              exposures.filter { !($0.mean < 1.0 && $0.p99 < 3.0) }.map(line).joined(separator: "; ") + " (\(exposures.count) of 16 measured)")

        notes += speed()
        // Today's helper on a 2048-pixel picture, for comparison.
        let big = CIImage(color: CIColor(red: 0.18, green: 0.18, blue: 0.18)).cropped(to: CGRect(x: 0, y: 0, width: 2048, height: 1365))
        var portra = FilmSettings()
        portra.film = "kodak_portra_400"; portra.paper = "kodak_portra_endura"; portra.changed = colourOnly
        let t0 = Date()
        _ = await reference(big, film: portra)
        notes.append("helper 2048×1365 (incl. files): \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000)) ms")
    }

    /// Every stock the tables have: each pair (named "<film>__<paper>"), and each positive film scanned (its id).
    private static func stocks() -> [(String, FilmSettings, FilmStock)] {
        let tables = FilmTables.shared
        var out: [(String, FilmSettings, FilmStock)] = []
        for pair in tables.pairs {
            let parts = pair.components(separatedBy: "__")
            guard parts.count == 2, let stock = tables.stock(film: parts[0], paper: parts[1]) else { continue }
            var settings = FilmSettings()
            settings.film = parts[0]; settings.paper = parts[1]; settings.changed = colourOnly
            out.append((pair, settings, stock))
        }
        for film in tables.films where film.type == "positive" {
            guard let stock = tables.stock(film: film.id, paper: nil) else { continue }
            var settings = FilmSettings()
            settings.film = film.id; settings.paper = film.print ?? settings.paper
            settings.changed = colourOnly; settings.changed["scan_film"] = .number(1)
            out.append((film.id, settings, stock))
        }
        return out
    }

    /// One small image with every test picture on it, and where each is: a 24-patch chart, a grey
    /// ramp from −8 to +6 stops around 0.18, and two real photos.
    private static func testAtlas() -> (CIImage, [(String, CGRect)]) {
        let width = 96
        // Colour-checker-like patches (sRGB 8-bit), made linear.
        let chart: [(Float, Float, Float)] = [
            (115, 82, 68), (194, 150, 130), (98, 122, 157), (87, 108, 67), (133, 128, 177), (103, 189, 170),
            (214, 126, 44), (80, 91, 166), (193, 90, 99), (94, 60, 108), (157, 188, 64), (224, 163, 46),
            (56, 61, 150), (70, 148, 73), (175, 54, 60), (231, 199, 31), (187, 86, 149), (8, 133, 161),
            (243, 243, 242), (200, 200, 200), (160, 160, 160), (122, 122, 121), (85, 85, 85), (52, 52, 52)]
        func linear(_ v: Float) -> Float { let s = v / 255; return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
        var patches = [Float](repeating: 1, count: width * 64 * 4)
        for y in 0..<64 { for x in 0..<width {
            let p = chart[(y / 16) * 6 + x / 16], i = (y * width + x) * 4
            patches[i] = linear(p.0); patches[i + 1] = linear(p.1); patches[i + 2] = linear(p.2)
        } }
        var ramp = [Float](repeating: 1, count: width * 8 * 4)
        for y in 0..<8 { for x in 0..<width {
            let v = 0.18 * pow(2, -8 + 14 * Float(x) / Float(width - 1)), i = (y * width + x) * 4
            ramp[i] = v; ramp[i + 1] = v; ramp[i + 2] = v
        } }
        var parts: [(String, CIImage)] = [("chart", image(patches, width: width, height: 64)), ("ramp", image(ramp, width: width, height: 8))]
        // The photos in the test folder (a closer crop of the first when there's only one).
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: photos)) ?? []).sorted()
            .filter { ["jpg", "jpeg", "png", "tif", "tiff", "heic"].contains(($0 as NSString).pathExtension.lowercased()) }
        let decoded = files.prefix(2).compactMap { CIImage(contentsOf: URL(fileURLWithPath: photos).appendingPathComponent($0)) }
        var shots = decoded.map { photo(fit: $0, zoom: 1, width: width, height: 64) }
        if let first = decoded.first, shots.count < 2 { shots.append(photo(fit: first, zoom: 3, width: width, height: 64)) }
        for (i, shot) in shots.enumerated() { parts.append(("photo \(i + 1)", shot)) }
        // Stacked, the first at the top.
        let height = parts.reduce(0) { $0 + Int($1.1.extent.height) }
        var y = CGFloat(height), atlas = CIImage.empty(), regions: [(String, CGRect)] = []
        for (name, part) in parts {
            y -= part.extent.height
            let placed = part.transformed(by: CGAffineTransform(translationX: 0, y: y))
            regions.append((name, placed.extent))
            atlas = placed.composited(over: atlas)
        }
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        // Fixed as numbers, so the two renderers start from exactly the same pixels.
        return (image(pixels(atlas.cropped(to: extent)), width: width, height: height), regions)
    }

    /// A photo scaled to cover width × height (zoomed in on its middle), as linear floats.
    private static func photo(fit source: CIImage, zoom: CGFloat, width: Int, height: Int) -> CIImage {
        let s = max(CGFloat(width) / source.extent.width, CGFloat(height) / source.extent.height) * zoom
        let scaled = source.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": s, "inputAspectRatio": 1])
        let x = scaled.extent.midX - CGFloat(width) / 2, y = scaled.extent.midY - CGFloat(height) / 2
        let cut = scaled.cropped(to: CGRect(x: x, y: y, width: CGFloat(width), height: CGFloat(height)))
            .transformed(by: CGAffineTransform(translationX: -x, y: -y))
        return image(pixels(cut), width: width, height: height)
    }

    /// RGBA floats to an image (the first row at the top).
    private static func image(_ values: [Float], width: Int, height: Int) -> CIImage {
        CIImage(bitmapData: values.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16, size: CGSize(width: width, height: height),
                format: .RGBAf, colorSpace: linearSRGB)
    }

    /// An image's RGBA floats over its extent (the first row at the top).
    private static func pixels(_ image: CIImage) -> [Float] {
        let extent = image.extent.integral
        guard !extent.isEmpty, !extent.isInfinite else { return [] }
        let width = Int(extent.width), height = Int(extent.height)
        var out = [Float](repeating: 0, count: width * height * 4)
        out.withUnsafeMutableBytes { floats.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: extent, format: .RGBAf, colorSpace: linearSRGB) }
        return out
    }

    /// Today's film: the image through the helper (raw linear floats in and out), at full size.
    static func reference(_ image: CIImage, film: FilmSettings) async -> CIImage {
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-film-test", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = folder.appendingPathComponent("\(UUID().uuidString)-in.raw"), output = folder.appendingPathComponent("\(UUID().uuidString)-out.raw")
        defer { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: output) }
        do {
            try pixels(image).withUnsafeBytes { Data($0) }.write(to: input)
            try await FilmEngine.shared.render(input, to: output, width: width, height: height, film: film, fullLongEdge: max(width, height))
            let developed = try Data(contentsOf: output)
            guard developed.count == width * height * 16 else { return .empty() }
            return CIImage(bitmapData: developed, bytesPerRow: width * 16, size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: linearSRGB)
                .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        } catch {
            return .empty()
        }
    }

    /// CIEDE2000 between two images of the same size, per pixel, in CIELAB (D65) from linear sRGB:
    /// the mean and the 99th percentile. A non-finite pixel counts as 100.
    static func deltaE2000(_ a: CIImage, _ b: CIImage) -> (mean: Double, p99: Double) {
        let pa = pixels(a), pb = pixels(b)
        guard pa.count == pb.count, !pa.isEmpty else { return (.infinity, .infinity) }
        var errors: [Double] = []
        errors.reserveCapacity(pa.count / 4)
        for i in stride(from: 0, to: pa.count, by: 4) {
            let e = ciede2000(lab(pa[i], pa[i + 1], pa[i + 2]), lab(pb[i], pb[i + 1], pb[i + 2]))
            errors.append(e.isFinite ? e : 100)
        }
        errors.sort()
        return (errors.reduce(0, +) / Double(errors.count), errors[Int((Double(errors.count - 1) * 0.99).rounded())])
    }

    /// Linear sRGB to CIELAB, D65 white.
    private static func lab(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Double> {
        let r = Double(r), g = Double(g), b = Double(b)
        let X = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
        let Y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let Z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : t * 24389 / 27 / 116 + 16.0 / 116 }
        let fx = f(X / 0.95047), fy = f(Y), fz = f(Z / 1.08883)
        return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// The CIEDE2000 colour difference (Sharma, Wu and Dalal's formulation), kL = kC = kH = 1.
    private static func ciede2000(_ one: SIMD3<Double>, _ two: SIMD3<Double>) -> Double {
        let (L1, a1, b1) = (one.x, one.y, one.z), (L2, a2, b2) = (two.x, two.y, two.z)
        let degrees = Double.pi / 180
        let seven: Double = 6_103_515_625  // 25^7
        let Cbar = (hypot(a1, b1) + hypot(a2, b2)) / 2
        let G = 0.5 * (1 - sqrt(pow(Cbar, 7) / (pow(Cbar, 7) + seven)))
        let a1p = (1 + G) * a1, a2p = (1 + G) * a2
        let C1p = hypot(a1p, b1), C2p = hypot(a2p, b2)
        func hue(_ b: Double, _ a: Double) -> Double {
            if a == 0 && b == 0 { return 0 }
            let h = atan2(b, a) / degrees
            return h < 0 ? h + 360 : h
        }
        let h1p = hue(b1, a1p), h2p = hue(b2, a2p)
        let dLp = L2 - L1, dCp = C2p - C1p
        var dhp = 0.0
        if C1p * C2p != 0 {
            dhp = h2p - h1p
            if dhp > 180 { dhp -= 360 } else if dhp < -180 { dhp += 360 }
        }
        let dHp = 2 * sqrt(C1p * C2p) * sin(dhp / 2 * degrees)
        let Lbar = (L1 + L2) / 2, Cbarp = (C1p + C2p) / 2
        var hbar = h1p + h2p
        if C1p * C2p != 0 {
            if abs(h1p - h2p) <= 180 { hbar = (h1p + h2p) / 2 } else { hbar = h1p + h2p < 360 ? (h1p + h2p + 360) / 2 : (h1p + h2p - 360) / 2 }
        }
        let T = 1 - 0.17 * cos((hbar - 30) * degrees) + 0.24 * cos(2 * hbar * degrees)
            + 0.32 * cos((3 * hbar + 6) * degrees) - 0.20 * cos((4 * hbar - 63) * degrees)
        let dTheta = 30 * exp(-pow((hbar - 275) / 25, 2))
        let RC = 2 * sqrt(pow(Cbarp, 7) / (pow(Cbarp, 7) + seven))
        let SL = 1 + 0.015 * pow(Lbar - 50, 2) / sqrt(20 + pow(Lbar - 50, 2))
        let SC = 1 + 0.045 * Cbarp, SH = 1 + 0.015 * Cbarp * T
        let RT = -sin(2 * dTheta * degrees) * RC
        let l = dLp / SL, c = dCp / SC, h = dHp / SH
        return sqrt(l * l + c * c + h * h + RT * c * h)
    }

    /// How long the GPU film takes on a preview-sized picture (for the report).
    private static func speed() -> [String] {
        guard let device = PhotoEngine.device, let stock = FilmTables.shared.stock(film: "kodak_portra_400", paper: "kodak_portra_endura"),
              let queue = device.makeCommandQueue() else { return ["speed: no GPU"] }
        var out: [String] = []
        for (width, height) in [(2048, 1365), (3024, 1964), (3840, 2560)] {
            let noise = CIFilter(name: "CIRandomGenerator")?.outputImage ?? CIImage(color: .gray)
            let scene = noise.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
            let geometry = FilmGeometry(full: scene.extent)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderWrite, .shaderRead]
            guard let target = device.makeTexture(descriptor: descriptor) else { continue }
            func time(_ image: CIImage) -> Double {
                var best = Double.infinity
                for _ in 0..<6 {
                    guard let buffer = queue.makeCommandBuffer() else { return .nan }
                    let destination = CIRenderDestination(mtlTexture: target, commandBuffer: buffer)
                    let t0 = Date()
                    _ = try? PhotoEngine.context.startTask(toRender: image, to: destination)
                    buffer.commit(); buffer.waitUntilCompleted()
                    best = min(best, Date().timeIntervalSince(t0) * 1000)
                }
                return best
            }
            var settings = FilmSettings()
            settings.film = "kodak_portra_400"; settings.paper = "kodak_portra_endura"; settings.changed = colourOnly
            let input = time(scene)
            let fused = time(FilmLook.apply(scene, stock: stock, settings: settings, geometry: geometry))
            let staged = time(FilmLook.printStage(FilmLook.develop(FilmLook.expose(scene, stock: stock, ev: 0), stock: stock, settings: settings, geometry: geometry, diffuse: false),
                                             stock: stock, printEV: 0))
            out.append("speed \(width)×\(height) (best of 6, incl. making the input \(String(format: "%.1f", input)) ms): fused \(String(format: "%.1f", fused)) ms, stages \(String(format: "%.1f", staged)) ms")
        }
        return out
    }

    /// The numbers behind the film checks, next to the log (<log>.film.txt).
    private static func writeNotes(_ notes: [String]) {
        guard let log = UserDefaults.standard.string(forKey: "PluckScreenshotLog") else { return }
        try? notes.joined(separator: "\n").write(toFile: log + ".film.txt", atomically: true, encoding: .utf8)
    }
}

// MARK: - The film's spatial effects (Task 6), against today's helper

extension PhotoSelfTest {
    /// The colour-only settings with some spatial stages back at their defaults (`on`), plus changes.
    private static func spatial(_ film: String, _ paper: String?, on: [String], _ extra: [String: SettingValue] = [:]) -> FilmSettings {
        var settings = FilmSettings()
        settings.film = film
        if let paper { settings.paper = paper } else {
            settings.paper = FilmTables.shared.films.first { $0.id == film }?.print ?? settings.paper
        }
        settings.changed = colourOnly
        if paper == nil { settings.changed["scan_film"] = .number(1) }
        for key in on { settings.changed[key] = nil }
        for (key, value) in extra { settings.changed[key] = value }
        return settings
    }
    private static let halationKeys = ["halation_on"]
    private static let couplerKeys = ["couplers_diffusion_um", "couplers_tail_weight"]
    private static let scanKeys = ["scan_usm_amount"]

    static func filmSpatial() async {
        let tables = FilmTables.shared
        var notes: [String] = []
        defer { appendNotes(notes) }

        // The wide blur's width (§1.3's table).
        let table: [(Double, Double)] = [(3, 3.300), (4, 4.442), (5, 5.556), (6, 6.655), (8, 8.832), (10, 10.993), (12, 13.145), (15, 16.361),
                                         (20, 21.696), (30, 32.277), (40, 42.711), (50, 52.958), (60, 62.978), (80, 82.188), (100, 100.075),
                                         (120, 116.442), (150, 137.880), (200, 186.875), (300, 275.760)]
        let off = table.filter { abs(FilmBlur.effectiveSigma($0.0) - $0.1) > 0.0015 }
        check("film wide blur width", off.isEmpty, off.map { "\($0.0): \(FilmBlur.effectiveSigma($0.0)) not \($0.1)" }.joined(separator: "; "))

        // The blur on the GPU has the width asked for, and unit gain, narrow or halved.
        let size = 1024
        var impulse = [Float](repeating: 0, count: size * size * 4)
        for i in stride(from: 3, to: impulse.count, by: 4) { impulse[i] = 1 }
        let centre = size / 2
        for c in 0..<3 { impulse[(centre * size + centre) * 4 + c] = 1e4 }
        let point = image(impulse, width: size, height: size)
        var widths: [String] = []
        for (sigma, wide) in [(0.7, false), (2.5, true), (4, true), (8, true), (20, true), (50, true)] {
            let out = pixels(FilmBlur.mix(point, keep: .zero, [FilmBlur.Component(sigma: SIMD3(repeating: sigma), wide: wide, weight: SIMD3(repeating: 1))]))
            guard out.count == impulse.count else { widths.append("σ \(sigma): no output"); continue }
            var total = 0.0, across = 0.0, down = 0.0
            for y in 0..<size { for x in 0..<size {
                let v = Double(out[(y * size + x) * 4 + 1])
                total += v; across += v * Double((x - centre) * (x - centre)); down += v * Double((y - centre) * (y - centre))
            } }
            // At full size, the taps' own variance; halved, the asked-for σ_eff².
            let taps = FilmBlur.taps(sigma, wide: wide, factor: 1)
            let r = (taps.count - 1) / 2, width = wide ? FilmBlur.effectiveSigma(sigma) : sigma
            let expected = width / 2 >= FilmBlur.lowSigma ? width * width : taps.enumerated().reduce(0) { $0 + $1.1 * Double(($1.0 - r) * ($1.0 - r)) }
            let ratio = (across / total) / expected, ratioDown = (down / total) / expected
            notes.append("blur σ \(sigma): gain \(String(format: "%.5f", total / 1e4)), variance/expected \(String(format: "%.4f", ratio)) across, \(String(format: "%.4f", ratioDown)) down")
            if !(abs(total / 1e4 - 1) < 0.002 && abs(ratio - 1) < 0.02 && abs(ratioDown - 1) < 0.02) {
                widths.append("σ \(sigma): gain \(total / 1e4), variance ×\(ratio) / ×\(ratioDown)")
            }
        }
        check("film blur has the asked width", widths.isEmpty, widths.joined(separator: "; "))

        // The extremes stay finite with the spatial stages on: NaN, ±inf and 1e4 light, a tiny 8 × 1 image
        // and a 64 × 64 one (wide blurs, as a crop of a big photo at 5 mm), and huge exposures.
        do {
            let extremes: [Float] = [0, 0, 0, 1, -0.5, -0.5, -0.5, 1, 1e4, 1e4, 1e4, 1, .nan, .nan, .nan, 1,
                                     1e4, -0.5, .nan, 1, 0.18, .infinity, -.infinity, 1, -1e4, 0.5, 2, 1, 1e-30, 0, 1e-30, 1]
            let tiny = image(extremes, width: 8, height: 1)
            let tiled = image((0..<(64 * 64)).flatMap { i in Array(extremes[(((i % 64) + i / 64) % 8) * 4..<(((i % 64) + i / 64) % 8) * 4 + 4]) }, width: 64, height: 64)
            var unstable: [String] = []
            for (film, paper) in [("kodak_portra_400", "kodak_portra_endura"), ("fujifilm_provia_100f", nil), ("kodak_doublex", "kodak_2302")] as [(String, String?)] {
                guard let stock = tables.stock(film: film, paper: paper) else { unstable.append("no \(film)"); continue }
                for ev in [0.0, 40, -40, 1000, -1000] {
                    for (name, picture, geometry, format) in [("8×1", tiny, FilmGeometry(full: tiny.extent), 36.0), ("8×1 wide", tiny, FilmGeometry(fullLongEdge: 6000), 5),
                                                              ("64×64 wide", tiled, FilmGeometry(fullLongEdge: 6000), 5)] {
                        let settings = spatial(film, paper, on: halationKeys + couplerKeys + scanKeys + grainKeys,
                                               ["exposure_ev": .number(ev), "film_format_mm": .number(format), "halation_amount": .number(8), "scan_blur": .number(1)])
                        let out = pixels(FilmLook.apply(picture, stock: stock, settings: settings, geometry: geometry))
                        if out.count != Int(picture.extent.width * picture.extent.height) * 4 || !out.allSatisfy(\.isFinite) {
                            unstable.append("\(film) ev \(ev) \(name): \(out.filter { !$0.isFinite }.count) non-finite of \(out.count)")
                        }
                    }
                }
            }
            check("film extreme light stays finite with spatial stages", unstable.isEmpty, unstable.prefix(8).joined(separator: "; "))
        }

        // One cold miss of the recursive taps at the largest realistic σ (the coupler tail, 400 µm, on a 100 MP crop at 5 mm).
        let cold = Date()
        _ = FilmBlur.recursive(2.7684 * 400 / (5000.0 / 12000) * 0.999)
        notes.append("recursive taps, one cold miss at σ ≈ 2660 px: \(String(format: "%.1f", Date().timeIntervalSince(cold) * 1000)) ms")

        // A failed stage gives an empty image, and the stages after it stay empty (no assert).
        if let portra = tables.stock(film: "kodak_portra_400", paper: "kodak_portra_endura") {
            let all = spatial("kodak_portra_400", "kodak_portra_endura", on: halationKeys + couplerKeys + scanKeys)
            let geometry = FilmGeometry(fullLongEdge: 100)
            let chain = [FilmLook.apply(.empty(), stock: portra, settings: all, geometry: geometry),
                         FilmHalation.apply(.empty(), stock: portra, settings: all, geometry: geometry),
                         FilmLook.develop(.empty(), stock: portra, settings: all, geometry: geometry, diffuse: true),
                         FilmHalation.scan(FilmLook.printStage(.empty(), stock: portra, printEV: 0), settings: all, geometry: geometry),
                         FilmBlur.mix(.empty(), keep: SIMD3(repeating: 2), [])]
            check("film stages after a failure stay empty", chain.allSatisfy(\.extent.isEmpty), chain.map { "\($0.extent)" }.joined(separator: ", "))
        }

        // In a preview the halo keeps its size on the photo: a quarter-size render has a quarter-size halo.
        if let gold = tables.stock(film: "kodak_gold_200", paper: "kodak_2302") {
            let settings = spatial("kodak_gold_200", "kodak_2302", on: halationKeys, ["scatter_amount": .number(0), "film_format_mm": .number(5)])
            func halo(_ side: Int, block: Int, scale: Double) -> Double {
                var values = [Float](repeating: 0, count: side * side * 4)
                for i in stride(from: 3, to: values.count, by: 4) { values[i] = 1 }
                let lo = side / 2 - block / 2
                for y in lo..<lo + block { for x in lo..<lo + block { for c in 0..<3 { values[(y * side + x) * 4 + c] = 1000 } } }
                let a = gold.spatial["halation_strength"]?.numbers?.first ?? 0  // the red strength, at halation_amount 1
                let out = pixels(FilmHalation.apply(image(values, width: side, height: side), stock: gold, settings: settings,
                                                    geometry: FilmGeometry(fullLongEdge: 2048, renderScale: scale)))
                guard out.count == values.count else { return .nan }
                var total = 0.0, moment = 0.0
                let mid = Double(side) / 2
                for y in 0..<side { for x in 0..<side {
                    let i = (y * side + x) * 4
                    let h = Double(out[i]) - Double(values[i]) / (1 + a)
                    let dx = Double(x) + 0.5 - mid, dy = Double(y) + 0.5 - mid
                    total += h; moment += h * (dx * dx + dy * dy)
                } }
                return (moment / total).squareRoot()
            }
            let full = halo(512, block: 4, scale: 1), preview = halo(128, block: 1, scale: 0.25)
            let ratio = preview * 4 / full
            notes.append("halo RMS radius: full \(String(format: "%.2f", full)) px, quarter \(String(format: "%.2f", preview)) px, ratio \(String(format: "%.3f", ratio))")
            check("film halation keeps size in previews", abs(ratio - 1) < 0.1, "full \(full) px, quarter \(preview) px (×4 = \(preview * 4))")
        } else { check("film halation keeps size in previews", false, "no Gold 200 stock") }

        let (atlas, regions) = spatialAtlas()

        // A crop (as a tile) gives exactly what the whole render gives there.
        if let portra = tables.stock(film: "kodak_portra_400", paper: "kodak_portra_endura") {
            let settings = spatial("kodak_portra_400", "kodak_portra_endura", on: halationKeys + couplerKeys + scanKeys + grainKeys, ["film_format_mm": .number(5)])
            let out = FilmLook.apply(atlas, stock: portra, settings: settings, geometry: FilmGeometry(full: atlas.extent))
            let whole = pixels(out), width = Int(atlas.extent.width), height = Int(atlas.extent.height)
            var worst: Float = 0
            for tile in [CGRect(x: 37, y: 101, width: 50, height: 61), CGRect(x: 300, y: 500, width: 84, height: 268), CGRect(x: 0, y: 0, width: 128, height: 128),
                         CGRect(x: 128, y: 384, width: 128, height: 128), CGRect(x: 190, y: 250, width: 1, height: 1), CGRect(x: 0, y: 700, width: 384, height: 68)] {
                let part = pixels(out.cropped(to: tile))
                guard part.count == Int(tile.width * tile.height) * 4, whole.count == width * height * 4 else { worst = .infinity; break }
                for y in 0..<Int(tile.height) { for x in 0..<Int(tile.width) { for c in 0..<3 {
                    let row = height - Int(tile.maxY) + y, column = Int(tile.minX) + x
                    worst = max(worst, abs(part[(y * Int(tile.width) + x) * 4 + c] - whole[(row * width + column) * 4 + c]))
                } } }
            }
            notes.append("tiles: worst difference \(worst)")
            check("film spatial tiles match the whole", worst < 1e-4, "worst difference \(worst)")
        }

        // The one-pass chain gives what the stages give one after another (each its own Core Image pass).
        var apart: [String] = []
        for (film, paper) in [("kodak_portra_400", "kodak_portra_endura"), ("fujifilm_provia_100f", nil), ("kodak_doublex", "kodak_2302"),
                              ("kodak_trix", nil)] as [(String, String?)] {
            guard let stock = tables.stock(film: film, paper: paper) else { apart.append("no \(film)"); continue }
            for format in [36.0, 5] {
                let settings = spatial(film, paper, on: halationKeys + couplerKeys + scanKeys + grainKeys, ["film_format_mm": .number(format), "scan_blur": .number(1)])
                let geometry = FilmGeometry(full: atlas.extent)
                let raw = FilmHalation.apply(FilmLook.expose(atlas, stock: stock, ev: 0), stock: stock, settings: settings, geometry: geometry)
                let developed = FilmLook.develop(raw, stock: stock, settings: settings, geometry: geometry,
                                                 diffuse: FilmHalation.couplersOn(stock: stock, settings: settings, geometry: geometry))
                let density = FilmGrain.apply(developed, stock: stock, settings: settings, geometry: geometry)
                let staged = pixels(FilmHalation.scan(FilmLook.printStage(density, stock: stock, printEV: 0), settings: settings, geometry: geometry))
                let one = pixels(FilmLook.apply(atlas, stock: stock, settings: settings, geometry: geometry))
                let errors = zip(one, staged).map { abs($0 - $1) / max(1, abs($1)) }
                let worst = errors.max() ?? .infinity
                if one.count != staged.count || !(worst < 1e-4) {
                    let at = (errors.firstIndex(of: worst) ?? 0) / 4, w = Int(atlas.extent.width)
                    apart.append("\(film) \(format) mm: \(worst) at \(at % w),\(at / w), \(errors.filter { $0 > 1e-4 }.count) over")
                }
            }
        }
        // The grain at its widest settings (the blurs' longest taps, the widest dye clouds) and at its strongest.
        for (film, paper) in [("kodak_trix", nil), ("kodak_vision3_500t", "kodak_2383")] as [(String, String?)] {
            guard let stock = tables.stock(film: film, paper: paper) else { apart.append("no \(film)"); continue }
            let settings = spatial(film, paper, on: grainKeys, ["film_format_mm": .number(5), "grain_blur": .number(4), "grain_usm_sigma": .number(3),
                                                                "grain_dye_cloud": .number(4), "grain_amount": .number(8)])
            let geometry = FilmGeometry(full: atlas.extent)
            let density = FilmGrain.apply(FilmLook.develop(FilmLook.expose(atlas, stock: stock, ev: 0), stock: stock, settings: settings, geometry: geometry,
                                                           diffuse: false), stock: stock, settings: settings, geometry: geometry)
            let staged = pixels(FilmLook.printStage(density, stock: stock, printEV: 0))
            let one = pixels(FilmLook.apply(atlas, stock: stock, settings: settings, geometry: geometry))
            let worst = zip(one, staged).map { abs($0 - $1) / max(1, abs($1)) }.max() ?? .infinity
            if one.count != staged.count || !(worst < 1e-4) || !one.allSatisfy(\.isFinite) { apart.append("\(film) widest grain: \(worst)") }
        }
        check("film one pass matches the stages", apart.isEmpty, apart.joined(separator: "; "))

        notes += spatialSpeed()

        guard FilmEngine.helper != nil, FileManager.default.fileExists(atPath: FilmEngine.pack.appendingPathComponent(".complete").path) else {
            for name in ["halation", "couplers diffusion", "scan sharpening", "spatial defaults"] {
                check("film \(name) matches reference", false, "the reference needs the helper and its pack (looked at \(FilmEngine.pack.path))")
            }
            return
        }

        typealias Result = (name: String, part: String, mean: Double, p99: Double)
        func measure(_ name: String, _ settings: FilmSettings, _ stock: FilmStock?) async -> [Result] {
            guard let stock else { return [(name, "no stock", .infinity, .infinity)] }
            let ours = FilmLook.apply(atlas, stock: stock, settings: settings, geometry: FilmGeometry(full: atlas.extent))
            let theirs = await reference(atlas, film: settings)
            guard theirs.extent == atlas.extent else { return [(name, "no reference", .infinity, .infinity)] }
            return regions.map { part, rect in
                let e = deltaE2000(ours.cropped(to: rect), theirs.cropped(to: rect))
                return (name, part, e.mean, e.p99)
            }
        }
        func line(_ r: Result) -> String { "\(r.name) \(r.part): mean \(String(format: "%.3f", r.mean)) p99 \(String(format: "%.3f", r.p99))" }
        func report(_ title: String, _ results: [Result], count: Int) {
            notes.append(title + ":")
            notes += results.map { "  " + line($0) }
            let bad = results.filter { !($0.mean < 1.0 && $0.p99 < 3.0) }
            check("film \(title) matches reference", bad.isEmpty && results.count == count,
                  "\(bad.count) over the limits (\(results.count) of \(count) measured); " + results.sorted { $0.p99 > $1.p99 }.prefix(6).map(line).joined(separator: "; "))
        }
        let pairs: [(String, String?)] = [("kodak_portra_400", "kodak_portra_endura"), ("kodak_gold_200", "kodak_2302")]
        func stock(_ film: String, _ paper: String?) -> FilmStock? { tables.stock(film: film, paper: paper) }

        var halation: [Result] = []
        for (film, paper) in pairs { for (amount, format) in [(1.0, 36.0), (4, 36), (1, 5), (4, 5)] {
            let settings = spatial(film, paper, on: halationKeys, ["halation_amount": .number(amount), "film_format_mm": .number(format)])
            halation += await measure("\(film) amount \(amount) \(format) mm", settings, stock(film, paper))
        } }
        report("halation", halation, count: 8 * regions.count)

        var couplers: [Result] = []
        for (film, paper) in pairs + [("fujifilm_provia_100f", nil)] { for format in [36.0, 5] {
            couplers += await measure("\(film) \(format) mm", spatial(film, paper, on: couplerKeys, ["film_format_mm": .number(format)]), stock(film, paper))
        } }
        report("couplers diffusion", couplers, count: 6 * regions.count)

        var scan: [Result] = []
        scan += await measure("kodak_portra_400 sharpening", spatial("kodak_portra_400", "kodak_portra_endura", on: scanKeys), stock("kodak_portra_400", "kodak_portra_endura"))
        scan += await measure("fujifilm_provia_100f sharpening", spatial("fujifilm_provia_100f", nil, on: scanKeys), stock("fujifilm_provia_100f", nil))
        scan += await measure("kodak_portra_400 blur 2 + sharpening", spatial("kodak_portra_400", "kodak_portra_endura", on: scanKeys, ["scan_blur": .number(2)]),
                              stock("kodak_portra_400", "kodak_portra_endura"))
        report("scan sharpening", scan, count: 3 * regions.count)

        var all: [Result] = []
        for (film, paper) in pairs + [("fujifilm_provia_100f", nil), ("kodak_doublex", "kodak_2302")] { for format in [36.0, 5] {
            all += await measure("\(film) \(format) mm", spatial(film, paper, on: halationKeys + couplerKeys + scanKeys, ["film_format_mm": .number(format)]),
                                 stock(film, paper))
        } }
        report("spatial defaults", all, count: 8 * regions.count)
    }

    /// Bright point lights and patches on a dark ground, over two photos: 384 × 768, linear floats.
    private static func spatialAtlas() -> (CIImage, [(String, CGRect)]) {
        let width = 384, part = 256
        var lights = [Float](repeating: 1, count: width * part * 4)
        func fill(_ x0: Int, _ y0: Int, _ w: Int, _ h: Int, _ v: (Float, Float, Float)) {
            for y in y0..<min(y0 + h, part) { for x in x0..<min(x0 + w, width) {
                let i = (y * width + x) * 4
                lights[i] = v.0; lights[i + 1] = v.1; lights[i + 2] = v.2
            } }
        }
        fill(0, 0, width, part, (0.01, 0.01, 0.012))
        for (k, value) in [Float(500), 100, 20].enumerated() {
            fill(30 + 120 * k, 30, 1, 1, (value, value, value))
            fill(30 + 120 * k, 70, 3, 3, (value, value * 0.8, value * 0.5))
            fill(30 + 120 * k, 110, 8, 8, (value * 0.5, value * 0.5, value))
        }
        fill(20, 160, 340, 2, (40, 30, 20))
        fill(30, 190, 50, 50, (0.9, 0.9, 0.9)); fill(110, 190, 50, 50, (0.18, 0.18, 0.18)); fill(190, 190, 50, 50, (0.6, 0.1, 0.05))
        fill(270, 190, 50, 50, (0.05, 0.3, 0.7))
        var parts: [(String, CIImage)] = [("lights", image(lights, width: width, height: part))]
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: photos)) ?? []).sorted()
            .filter { ["jpg", "jpeg", "png", "tif", "tiff", "heic"].contains(($0 as NSString).pathExtension.lowercased()) }
        let decoded = files.prefix(2).compactMap { CIImage(contentsOf: URL(fileURLWithPath: photos).appendingPathComponent($0)) }
        var shots = decoded.map { photo(fit: $0, zoom: 1, width: width, height: part) }
        if let first = decoded.first, shots.count < 2 { shots.append(photo(fit: first, zoom: 3, width: width, height: part)) }
        for (i, shot) in shots.enumerated() { parts.append(("photo \(i + 1)", shot)) }
        let height = parts.count * part
        var y = CGFloat(height), atlas = CIImage.empty(), regions: [(String, CGRect)] = []
        for (name, image) in parts {
            y -= CGFloat(part)
            let placed = image.transformed(by: CGAffineTransform(translationX: 0, y: y))
            regions.append((name, placed.extent))
            atlas = placed.composited(over: atlas)
        }
        return (image(pixels(atlas.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))), width: width, height: height), regions)
    }

    /// What each spatial stage adds on a preview of a 6048-pixel photo, and at full size (for the report).
    private static func spatialSpeed() -> [String] {
        guard let device = PhotoEngine.device, let stock = FilmTables.shared.stock(film: "kodak_portra_400", paper: "kodak_portra_endura"),
              let queue = device.makeCommandQueue() else { return ["spatial speed: no GPU"] }
        var out: [String] = []
        for (width, height, scale) in [(2048, 1365, 2048.0 / 6048), (3024, 1964, 3024.0 / 6048), (3024, 1964, 1.0)] {
            let noise = CIFilter(name: "CIRandomGenerator")?.outputImage ?? CIImage(color: .gray)
            let scene = noise.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
            let geometry = FilmGeometry(fullLongEdge: 6048, renderScale: scale)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderWrite, .shaderRead]
            guard let target = device.makeTexture(descriptor: descriptor) else { continue }
            func time(_ image: CIImage) -> Double {
                var best = Double.infinity
                for _ in 0..<6 {
                    guard let buffer = queue.makeCommandBuffer() else { return .nan }
                    let destination = CIRenderDestination(mtlTexture: target, commandBuffer: buffer)
                    let t0 = Date()
                    _ = try? PhotoEngine.context.startTask(toRender: image, to: destination)
                    buffer.commit(); buffer.waitUntilCompleted()
                    best = min(best, Date().timeIntervalSince(t0) * 1000)
                }
                return best
            }
            func run(_ on: [String]) -> Double {
                time(FilmLook.apply(scene, stock: stock, settings: spatial("kodak_portra_400", "kodak_portra_endura", on: on), geometry: geometry))
            }
            let base = spatial("kodak_portra_400", "kodak_portra_endura", on: [])
            let staged = time(FilmLook.printStage(FilmLook.develop(FilmLook.expose(scene, stock: stock, ev: 0), stock: stock, settings: base, geometry: geometry,
                                                              diffuse: false), stock: stock, printEV: 0))
            let f = { (v: Double) in String(format: "%.1f", v) }
            out.append("spatial speed \(width)×\(height) at scale \(String(format: "%.3f", scale)) (best of 6): fused \(f(run([]))) ms, stages \(f(staged)) ms, "
                       + "halation \(f(run(halationKeys))) ms, couplers \(f(run(couplerKeys))) ms, halation + couplers \(f(run(halationKeys + couplerKeys))) ms, "
                       + "scan \(f(run(scanKeys))) ms, all \(f(run(halationKeys + couplerKeys + scanKeys))) ms")
        }
        return out
    }

    /// Adds to the numbers behind the film checks (<log>.film.txt).
    private static func appendNotes(_ notes: [String]) {
        guard let log = UserDefaults.standard.string(forKey: "PluckScreenshotLog") else { return }
        let path = log + ".film.txt"
        let before = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? (before + "\n\n" + notes.joined(separator: "\n")).write(toFile: path, atomically: true, encoding: .utf8)
    }
}

// MARK: - The film's grain (Task 7), against today's helper

extension PhotoSelfTest {
    private static let grainKeys = ["grain_on"]

    /// One flat patch's grain: per channel, the residual's RMS, its normalised autocorrelation at lags 1–3
    /// (across and down averaged) and the mean output.
    private struct GrainStats {
        var rms = SIMD3<Double>(), mean = SIMD3<Double>()
        var rho: [SIMD3<Double>] = []
        /// The width where a Gaussian-shaped autocorrelation with this lag-1 value falls to 0.5 (sub-pixel; §4.9).
        var fitWidth: SIMD3<Double> {
            SIMD3((0..<3).map { c in let r = rho[0][c]; return r > 0 && r < 1 ? (log(2) / -log(r)).squareRoot() : (r >= 1 ? .infinity : 0) })
        }
        /// The lag where the profile falls to 0.5, interpolated between integer lags (lag 0 is 1).
        var lagWidth: SIMD3<Double> {
            SIMD3((0..<3).map { c in
                var before = 1.0
                for (i, r) in rho.enumerated() {
                    if r[c] <= 0.5 { return Double(i) + (before - 0.5) / max(before - r[c], 1e-9) }
                    before = r[c]
                }
                return Double(rho.count)
            })
        }
    }

    /// The grain in a w × h box of `residual` (RGBA, `width` wide, rows from the top) at (x0, y0).
    private static func grainStats(_ residual: [Float], width: Int, x0: Int, y0: Int, w: Int, h: Int, mean: [Float]? = nil) -> GrainStats {
        var stats = GrainStats()
        for c in 0..<3 {
            func at(_ x: Int, _ y: Int) -> Double { Double(residual[((y0 + y) * width + x0 + x) * 4 + c]) }
            var m = 0.0
            for y in 0..<h { for x in 0..<w { m += at(x, y) } }
            m /= Double(w * h)
            var v = 0.0
            for y in 0..<h { for x in 0..<w { v += pow(at(x, y) - m, 2) } }
            stats.rms[c] = (v / Double(w * h)).squareRoot()
            if let mean { var o = 0.0; for y in 0..<h { for x in 0..<w { o += Double(mean[((y0 + y) * width + x0 + x) * 4 + c]) } }; stats.mean[c] = o / Double(w * h) }
            for lag in 1...3 {
                var across = 0.0, down = 0.0, va = 0.0, vd = 0.0
                for y in 0..<h { for x in 0..<w {
                    let a = at(x, y) - m
                    if x + lag < w { across += a * (at(x + lag, y) - m); va += a * a }
                    if y + lag < h { down += a * (at(x, y + lag) - m); vd += a * a }
                } }
                if stats.rho.count < lag { stats.rho.append(.zero) }
                stats.rho[lag - 1][c] = ((va > 0 ? across / va : 0) + (vd > 0 ? down / vd : 0)) / 2
            }
        }
        return stats
    }

    /// Six flat patches side by side (256 × 256 each), scene grey 0.184 × 2^(−4, −2, −1, 0, 1.5, 3), `side` px per patch.
    private static func grainStrip(side: Int = 256) -> CIImage {
        let stops: [Float] = [-4, -2, -1, 0, 1.5, 3]
        var values = [Float](repeating: 1, count: 6 * side * side * 4)
        for y in 0..<side { for x in 0..<(6 * side) {
            let v = 0.184 * pow(2, stops[x / side]), i = (y * 6 * side + x) * 4
            values[i] = v; values[i + 1] = v; values[i + 2] = v
        } }
        return image(values, width: 6 * side, height: side)
    }

    static func filmGrain() async {
        let tables = FilmTables.shared
        var notes: [String] = []
        defer { appendNotes(notes) }
        let f = { (v: Double) in String(format: "%.4f", v) }
        func three(_ v: SIMD3<Double>) -> String { "(\(f(v.x)), \(f(v.y)), \(f(v.z)))" }
        func rms(_ v: SIMD3<Double>) -> String { "(" + [v.x, v.y, v.z].map { String(format: "%.4g", $0) }.joined(separator: ", ") + ")" }

        // Off, or at amount 0, is exactly nothing.
        if let portra = tables.stock(film: "kodak_portra_400", paper: "kodak_portra_endura") {
            let strip = grainStrip(side: 32), geometry = FilmGeometry(full: grainStrip(side: 32).extent)
            let density = FilmLook.develop(FilmLook.expose(strip, stock: portra, ev: 0), stock: portra, settings: FilmSettings(), geometry: geometry, diffuse: false)
            let off = spatial("kodak_portra_400", "kodak_portra_endura", on: [])
            let zero = spatial("kodak_portra_400", "kodak_portra_endura", on: grainKeys, ["grain_amount": .number(0)])
            let same = FilmGrain.apply(density, stock: portra, settings: off, geometry: geometry) === density
                && FilmGrain.apply(density, stock: portra, settings: zero, geometry: geometry) === density
                && FilmGrain.plan(portra, zero, geometry, extent: strip.extent) == nil
            let fused = pixels(FilmLook.apply(strip, stock: portra, settings: zero, geometry: geometry)) == pixels(FilmLook.apply(strip, stock: portra, settings: off, geometry: geometry))
            check("film grain off is a no-op", same && fused, "grain off or amount 0 should hand the density back untouched (and the fused pass alike)")
        }

        // The draws at the hash's extremes (0 and 0xFFFFFFFF, and neighbours) stay inside (0, 1) and give a sane
        // count, both below λ 12 (the exact inverse) and above (the normal), on the shader's own code.
        do {
            var bad: [String] = []
            if let device = PhotoEngine.device, let queue = device.makeCommandQueue(),
               let state = FilmLook.Library.shared.pipeline("filmGrainProbe", device: device) {
                let hashes: [UInt32] = [0, 1, 0x1FF, 0x200, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FE00, 0xFFFF_FEFF, 0xFFFF_FF00, 0xFFFF_FFFE, 0xFFFF_FFFF]
                let lambdas: [Float] = [5, 50, 0.01, 11.99, 12]
                let input = lambdas.flatMap { l in hashes.map { SIMD2<Float>(Float(bitPattern: $0), l) } }
                if let inBuffer = device.makeBuffer(bytes: input, length: input.count * 8, options: .storageModeShared),
                   let outBuffer = device.makeBuffer(length: input.count * 8, options: .storageModeShared),
                   let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeComputeCommandEncoder() {
                    encoder.setComputePipelineState(state)
                    encoder.setBuffer(inBuffer, offset: 0, index: 0); encoder.setBuffer(outBuffer, offset: 0, index: 1)
                    encoder.dispatchThreads(MTLSize(width: input.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
                    encoder.endEncoding(); buffer.commit(); buffer.waitUntilCompleted()
                    let out = outBuffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: input.count)
                    for i in 0..<input.count {
                        let (u, k, lambda) = (out[i].x, out[i].y, input[i].y), h = String(format: "%08X", input[i].x.bitPattern)
                        let spread = 10 * lambda.squareRoot() + 10
                        if !(u > 0 && u < 1) { bad.append("u \(u) at \(h)") }
                        if !(k.isFinite && k >= -spread && k <= lambda + spread) { bad.append("k \(k) at \(h), λ \(lambda)") }
                    }
                    notes.append("grain draws at the hash extremes (λ 5): " + (0..<hashes.count).map { String(format: "%08X → u %.9f k %.1f", hashes[$0], out[$0].x, out[$0].y) }.joined(separator: ", "))
                } else { bad.append("no buffers") }
            } else { bad.append("no GPU or no probe kernel") }
            check("film grain draws at the hash extremes", bad.isEmpty, bad.prefix(8).joined(separator: "; "))
        }

        // Stays put: the same particles at the same full-size place, again, at another exposure, and in a crop.
        if let portra = tables.stock(film: "kodak_portra_400", paper: "kodak_portra_endura") {
            let strip = grainStrip(), width = Int(strip.extent.width), height = Int(strip.extent.height)
            let geometry = FilmGeometry(full: strip.extent)
            func residual(_ extra: [String: SettingValue], _ picture: CIImage, _ geometry: FilmGeometry) -> [Float] {
                let with = pixels(FilmLook.apply(picture, stock: portra, settings: spatial("kodak_portra_400", "kodak_portra_endura", on: grainKeys,
                                                                                            extra.merging(["film_format_mm": .number(9.216)]) { a, _ in a }), geometry: geometry))
                let without = pixels(FilmLook.apply(picture, stock: portra, settings: spatial("kodak_portra_400", "kodak_portra_endura", on: [],
                                                                                               extra.merging(["film_format_mm": .number(9.216)]) { a, _ in a }), geometry: geometry))
                return zip(with, without).map { $0 - $1 }
            }
            // The correlation of two residuals inside each patch (per channel; the worst), `b` shifted by dx.
            var perPatch: [String] = []
            func correlation(_ a: [Float], _ b: [Float], bWidth: Int, dx: Int, dy: Int = 0, columns: Range<Int>, rows: Range<Int>? = nil,
                             side: Int = 256, aWidth: Int? = nil, note: Bool = false) -> Double {
                var worst = 1.0
                let width = aWidth ?? width, border = side / 16, rows = rows ?? border..<(side - border)
                for k in 0..<6 { for c in 0..<3 {
                    let lo = max(side * k + border, columns.lowerBound), hi = min(side * (k + 1) - border, columns.upperBound)
                    guard lo < hi else { continue }
                    var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0, n = 0.0
                    for y in rows { for x in lo..<hi {
                        let va = Double(a[(y * width + x) * 4 + c]), vb = Double(b[((y - dy) * bWidth + x - dx) * 4 + c])
                        sa += va; sb += vb; saa += va * va; sbb += vb * vb; sab += va * vb; n += 1
                    } }
                    guard n > 0 else { continue }
                    let cov = sab / n - sa / n * sb / n, r = cov / ((saa / n - pow(sa / n, 2)) * (sbb / n - pow(sb / n, 2))).squareRoot()
                    if note { perPatch.append("p\(k)c\(c) \(f(r))") }
                    worst = min(worst, r.isFinite ? r : 0)
                } }
                return worst
            }
            let one = residual([:], strip, geometry), two = residual([:], strip, geometry), brighter = residual(["exposure_ev": .number(0.5)], strip, geometry)
            // A crop from x = 300 to 1100, rendered on its own with its place on the photo.
            let crop = strip.cropped(to: CGRect(x: 300, y: 0, width: 800, height: height)).transformed(by: CGAffineTransform(translationX: -300, y: 0))
            let cropped = residual([:], image(pixels(crop), width: 800, height: height),
                                   FilmGeometry(fullLongEdge: width, renderScale: 1, fullOrigin: CGPoint(x: 300, y: 0)))
            let again = correlation(one, two, bWidth: width, dx: 0, columns: 0..<width)
            let exposure = correlation(one, brighter, bWidth: width, dx: 0, columns: 0..<width, note: true)
            let place = correlation(one, cropped, bWidth: 800, dx: 300, columns: 320..<1080)
            // A crop of the rows 64 to 256 (counted down), placed 64 rows down.
            let lower = strip.cropped(to: CGRect(x: 0, y: 0, width: width, height: height - 64))
            let below = residual([:], image(pixels(lower), width: width, height: height - 64),
                                 FilmGeometry(fullLongEdge: width, renderScale: 1, fullOrigin: CGPoint(x: 0, y: 64)))
            let down = correlation(one, below, bWidth: width, dx: 0, dy: 64, columns: 0..<width, rows: 84..<240)
            // A quarter-size preview, whole and as a crop (columns 100 to 300, rows 10 to 64 of the preview) at its place.
            let small = grainStrip(side: 64), smallGeometry = FilmGeometry(fullLongEdge: width, renderScale: 0.25)
            let preview = residual([:], small, smallGeometry)
            let part = small.cropped(to: CGRect(x: 100, y: 0, width: 200, height: 54)).transformed(by: CGAffineTransform(translationX: -100, y: 0))
            let previewCrop = residual([:], image(pixels(part), width: 200, height: 54),
                                       FilmGeometry(fullLongEdge: width, renderScale: 0.25, fullOrigin: CGPoint(x: 400, y: 40)))
            let scaled = correlation(preview, previewCrop, bWidth: 200, dx: 100, dy: 10, columns: 106..<294, rows: 16..<60, side: 64, aWidth: 384)
            notes.append("grain stays put (Portra, 6 µm, worst patch and channel): again \(f(again)), exposure +0.5 EV \(f(exposure)), crop at its place \(f(place)), "
                         + "crop lower down \(f(down)), preview crop at its place \(f(scaled))")
            notes.append("  +0.5 EV per patch: " + perPatch.joined(separator: ", "))
            check("film grain stays put", again > 0.9999 && exposure > 0.95 && place > 0.9999 && down > 0.9999 && scaled > 0.9999,
                  "residual correlation: again \(again), +0.5 EV \(exposure), crop \(place), lower crop \(down), preview crop \(scaled)")
        } else { check("film grain stays put", false, "no Portra stock") }

        // Seamless: 512-pixel tiles cropped from the image and stitched give the same bytes as the whole.
        do {
            let (atlas, _) = spatialAtlas()
            // 1280 × 1152: the atlas three times across, one and a half down.
            var big = CIImage.empty()
            for i in 0..<4 { for j in 0..<2 {
                big = atlas.transformed(by: CGAffineTransform(translationX: CGFloat(i * 384), y: CGFloat(j * 768))).composited(over: big)
            } }
            let extent = CGRect(x: 0, y: 0, width: 1280, height: 1152)
            let picture = image(pixels(big.cropped(to: extent)), width: 1280, height: 1152)
            var broken: [String] = []
            for (film, paper, on) in [("kodak_portra_400", "kodak_portra_endura", grainKeys), ("kodak_trix", nil, grainKeys + halationKeys + couplerKeys + scanKeys),
                                      ("kodak_vision3_500t", "kodak_2383", grainKeys + scanKeys)] as [(String, String?, [String])] {
                guard let stock = tables.stock(film: film, paper: paper) else { broken.append("no \(film)"); continue }
                let settings = spatial(film, paper, on: on, ["film_format_mm": .number(9)])
                let geometry = FilmGeometry(full: extent)
                let fused = FilmLook.apply(picture, stock: stock, settings: settings, geometry: geometry)
                let staged = FilmLook.printStage(FilmGrain.apply(FilmLook.develop(FilmLook.expose(picture, stock: stock, ev: 0), stock: stock, settings: settings, geometry: geometry,
                                                                             diffuse: false), stock: stock, settings: settings, geometry: geometry), stock: stock, printEV: 0)
                for (name, out) in [("one pass", fused), ("grain alone", staged)] where name == "one pass" || on == grainKeys {
                    let whole = pixels(out)
                    var differ = 0
                    for ty in stride(from: 0, to: 1152, by: 512) { for tx in stride(from: 0, to: 1280, by: 512) {
                        let tile = CGRect(x: tx, y: ty, width: min(512, 1280 - tx), height: min(512, 1152 - ty))
                        let part = pixels(out.cropped(to: tile)), tw = Int(tile.width)
                        guard part.count == tw * Int(tile.height) * 4 else { differ += 1; continue }
                        for y in 0..<Int(tile.height) { for x in 0..<tw {
                            let row = 1152 - Int(tile.maxY) + y, i = (row * 1280 + tx + x) * 4, j = (y * tw + x) * 4
                            if whole[i] != part[j] || whole[i + 1] != part[j + 1] || whole[i + 2] != part[j + 2] { differ += 1 }
                        } }
                    } }
                    if differ > 0 || whole.count != 1280 * 1152 * 4 { broken.append("\(film) \(name): \(differ) pixels differ") }
                }
            }
            check("film grain seamless across tiles", broken.isEmpty, broken.joined(separator: "; "))
        }

        // A preview at a quarter of the size: as strong as the export box-downscaled by 4.
        do {
            var worst: (Double, String) = (0, "")
            for (film, paper) in [("kodak_portra_400", "kodak_portra_endura"), ("kodak_trix", nil), ("kodak_vision3_500t", "kodak_2383")] as [(String, String?)] {
                guard let stock = tables.stock(film: film, paper: paper) else { worst = (.infinity, "no \(film)"); continue }
                let settings = spatial(film, paper, on: grainKeys, ["film_format_mm": .number(9.216)])
                let plain = spatial(film, paper, on: [], ["film_format_mm": .number(9.216)])
                let full = grainStrip(), small = grainStrip(side: 64)
                let fullGeometry = FilmGeometry(full: full.extent), smallGeometry = FilmGeometry(fullLongEdge: 1536, renderScale: 0.25)
                let export = zip(pixels(FilmLook.apply(full, stock: stock, settings: settings, geometry: fullGeometry)),
                                 pixels(FilmLook.apply(full, stock: stock, settings: plain, geometry: fullGeometry))).map { $0 - $1 }
                let preview = zip(pixels(FilmLook.apply(small, stock: stock, settings: settings, geometry: smallGeometry)),
                                  pixels(FilmLook.apply(small, stock: stock, settings: plain, geometry: smallGeometry))).map { $0 - $1 }
                guard export.count == 1536 * 256 * 4, preview.count == 384 * 64 * 4 else { worst = (.infinity, "\(film): no output"); continue }
                var down = [Float](repeating: 0, count: 384 * 64 * 4)
                for y in 0..<64 { for x in 0..<384 { for c in 0..<3 {
                    var sum: Float = 0
                    for j in 0..<4 { for i in 0..<4 { sum += export[((4 * y + j) * 1536 + 4 * x + i) * 4 + c] } }
                    down[(y * 384 + x) * 4 + c] = sum / 16
                } } }
                // The same at the grain's own output (density), before the print's curves.
                func density(_ picture: CIImage, _ geometry: FilmGeometry, _ settings: FilmSettings) -> [Float] {
                    pixels(FilmGrain.apply(FilmLook.develop(FilmLook.expose(picture, stock: stock, ev: 0), stock: stock, settings: settings, geometry: geometry, diffuse: false),
                                           stock: stock, settings: settings, geometry: geometry))
                }
                let exportD = zip(density(full, fullGeometry, settings), density(full, fullGeometry, plain)).map { $0 - $1 }
                let previewD = zip(density(small, smallGeometry, settings), density(small, smallGeometry, plain)).map { $0 - $1 }
                var downD = [Float](repeating: 0, count: 384 * 64 * 4)
                for y in 0..<64 { for x in 0..<384 { for c in 0..<3 {
                    var sum: Float = 0
                    for j in 0..<4 { for i in 0..<4 { sum += exportD[((4 * y + j) * 1536 + 4 * x + i) * 4 + c] } }
                    downD[(y * 384 + x) * 4 + c] = sum / 16
                } } }
                var line: [String] = []
                for k in 0..<6 {
                    let ad = grainStats(previewD, width: 384, x0: 64 * k + 4, y0: 4, w: 56, h: 56), bd = grainStats(downD, width: 384, x0: 64 * k + 4, y0: 4, w: 56, h: 56)
                    line.append("p\(k) density ×\(three(ad.rms / bd.rms))")
                    for c in 0..<3 where bd.rms[c] > 1e-6 {
                        let off = abs(ad.rms[c] / bd.rms[c] - 1)
                        if off > worst.0 { worst = (off, "\(film) patch \(k) channel \(c) density: preview \(ad.rms[c]), export scaled down \(bd.rms[c])") }
                    }
                    let a = grainStats(preview, width: 384, x0: 64 * k + 4, y0: 4, w: 56, h: 56), b = grainStats(down, width: 384, x0: 64 * k + 4, y0: 4, w: 56, h: 56)
                    let e = grainStats(export, width: 1536, x0: 256 * k + 16, y0: 16, w: 224, h: 224)
                    // In the output, the deepest shadow is left out: there the print's curve bends within the grain's own
                    // spread, so a sparse export grain averaged after the curve isn't a finer grain before it (density is checked above).
                    for c in 0..<3 where b.rms[c] > 1e-6 && k > 0 {
                        let off = abs(a.rms[c] / b.rms[c] - 1)
                        if off > worst.0 { worst = (off, "\(film) patch \(k) channel \(c): preview \(a.rms[c]), export scaled down \(b.rms[c])") }
                    }
                    line.append("output ×\(three(a.rms / b.rms)) (green preview \(f(a.rms.y)) down \(f(b.rms.y)) export \(f(e.rms.y)))")
                }
                notes.append("grain preview ×0.25 \(film), RMS preview / export scaled down: " + line.joined(separator: ", "))
            }
            notes.append("grain preview worst: \(f(worst.0)) \(worst.1)")
            check("film grain preview like export", worst.0 < 0.15, "worst \(worst.0): \(worst.1)")
        }

        notes += grainSpeed()

        guard FilmEngine.helper != nil, FileManager.default.fileExists(atPath: FilmEngine.pack.appendingPathComponent(".complete").path) else {
            check("film grain matches reference", false, "the reference needs the helper and its pack (looked at \(FilmEngine.pack.path))")
            return
        }

        // Against the reference: six flat patches, 6 µm a pixel (and 35 µm), amount 1 and 3, and a wider grain blur.
        let strip = grainStrip(), width = Int(strip.extent.width)
        var failures: [String] = []
        var measured = 0
        var withouts: [String: ([Float], [Float])] = [:]
        let cases: [(String, String?, Double, Double, Double)] = [
            ("kodak_portra_400", "kodak_portra_endura", 1, 9.216, 1), ("kodak_portra_400", "kodak_portra_endura", 3, 9.216, 1),
            ("kodak_trix", nil, 1, 9.216, 1), ("kodak_trix", nil, 3, 9.216, 1),
            ("kodak_vision3_500t", "kodak_2383", 1, 9.216, 1), ("kodak_vision3_500t", "kodak_2383", 3, 9.216, 1),
            ("kodak_portra_400", "kodak_portra_endura", 1, 53.76, 1), ("kodak_trix", nil, 1, 53.76, 1),
            ("kodak_portra_400", "kodak_portra_endura", 1, 9.216, 2), ("kodak_vision3_500t", "kodak_2383", 1, 9.216, 2)]
        for (film, paper, amount, format, blur) in cases {
            guard let stock = tables.stock(film: film, paper: paper) else { failures.append("no \(film)"); continue }
            let geometry = FilmGeometry(full: strip.extent)
            let extra: [String: SettingValue] = ["film_format_mm": .number(format)]
            let settings = spatial(film, paper, on: grainKeys, extra.merging(["grain_amount": .number(amount), "grain_blur": .number(blur)]) { a, _ in a })
            let key = "\(film) \(format)"
            if withouts[key] == nil {
                let plain = spatial(film, paper, on: [], extra)
                withouts[key] = (pixels(FilmLook.apply(strip, stock: stock, settings: plain, geometry: geometry)), pixels(await reference(strip, film: plain)))
            }
            let (oursWithout, theirsWithout) = withouts[key]!
            let ours = zip(pixels(FilmLook.apply(strip, stock: stock, settings: settings, geometry: geometry)), oursWithout).map { $0 - $1 }
            let theirsWith = pixels(await reference(strip, film: settings))
            guard theirsWith.count == ours.count, theirsWithout.count == ours.count, ours.count == width * 256 * 4 else { failures.append("\(key): no reference"); continue }
            let theirs = zip(theirsWith, theirsWithout).map { $0 - $1 }
            // Each patch's mean density on our film (green), for the report.
            let density = pixels(FilmLook.develop(FilmLook.expose(strip, stock: stock, ev: 0), stock: stock, settings: settings, geometry: geometry, diffuse: false))
            let name = "\(film) amount \(amount) \(format) mm\(blur != 1 ? " grain_blur \(blur)" : "")"
            notes.append("grain vs reference, \(name):")
            for k in 0..<6 {
                let a = grainStats(ours, width: width, x0: 256 * k + 16, y0: 16, w: 224, h: 224, mean: oursWithout)
                let b = grainStats(theirs, width: width, x0: 256 * k + 16, y0: 16, w: 224, h: 224)
                let d = Double(density.count == width * 256 * 4 ? density[(128 * width + 256 * k + 128) * 4 + 1] : .nan)
                notes.append("  patch \(k) D \(String(format: "%.3f", d)) out \(f(a.mean.y)): RMS ours \(rms(a.rms)) ref \(rms(b.rms)); "
                             + "ρ1 ours \(three(a.rho[0])) ref \(three(b.rho[0])); width ours \(three(a.fitWidth)) ref \(three(b.fitWidth)); "
                             + "lag width ours \(three(a.lagWidth)) ref \(three(b.lagWidth))")
                for c in 0..<3 where b.rms[c] > 2e-5 {
                    measured += 1
                    let rms = a.rms[c] / b.rms[c], fit = a.fitWidth[c] / b.fitWidth[c], lag = a.lagWidth[c] / b.lagWidth[c]
                    if !(abs(rms - 1) < 0.15) { failures.append("\(name) p\(k) c\(c): RMS ×\(String(format: "%.3f", rms))") }
                    if !(abs(fit - 1) < 0.2) { failures.append("\(name) p\(k) c\(c): width ×\(String(format: "%.3f", fit))") }
                    if blur != 1 && !(abs(lag - 1) < 0.2) { failures.append("\(name) p\(k) c\(c): lag width ×\(String(format: "%.3f", lag))") }
                }
                // A B&W film's grain is one field: its channels move together.
                if stock.bw, a.rms.y > 0 {
                    let one = grainStats(ours.enumerated().map { $0.offset % 4 == 0 ? $0.element - ours[$0.offset + 1] : 0 }, width: width,
                                         x0: 256 * k + 16, y0: 16, w: 224, h: 224)
                    if one.rms.x > 0.05 * a.rms.y + 1e-6 { failures.append("\(name) p\(k): B&W channels differ (\(one.rms.x))") }
                }
            }
        }
        notes.append("grain vs reference: \(measured) measured, \(failures.count) over")
        check("film grain matches reference", failures.isEmpty && measured >= 100, "\(measured) measured; " + failures.prefix(10).joined(separator: "; "))
    }

    /// Stand-ins for Core Image's tiles: a texture and where it sits.
    private final class ChainInput: NSObject, CIImageProcessorInput {
        let region: CGRect
        let metalTexture: MTLTexture?
        init(_ texture: MTLTexture, _ region: CGRect) { metalTexture = texture; self.region = region }
        var bytesPerRow: Int { 0 }
        var format: CIFormat { .RGBAf }
        var baseAddress: UnsafeRawPointer { UnsafeRawPointer(bitPattern: 16)! }
        var pixelBuffer: CVPixelBuffer? { nil }
        var surface: IOSurfaceRef { fatalError("no surface") }
        var digest: UInt64 { 0 }
        var roiTileIndex: Int { 0 }
        var roiTileCount: Int { 1 }
    }
    private final class ChainOutput: NSObject, CIImageProcessorOutput {
        let region: CGRect
        let metalTexture: MTLTexture?
        let metalCommandBuffer: MTLCommandBuffer?
        init(_ texture: MTLTexture, _ region: CGRect, _ buffer: MTLCommandBuffer) { metalTexture = texture; self.region = region; metalCommandBuffer = buffer }
        var bytesPerRow: Int { 0 }
        var format: CIFormat { .RGBAf }
        var baseAddress: UnsafeMutableRawPointer { UnsafeMutableRawPointer(bitPattern: 16)! }
        var pixelBuffer: CVPixelBuffer? { nil }
        var surface: IOSurfaceRef { fatalError("no surface") }
        var digest: UInt64 { 0 }
        func temporarySurface(identifier: String, format: OSType, width: Int, height: Int) -> IOSurface? { nil }
        func temporaryPixelBuffer(identifier: String, format: OSType, width: Int, height: Int, attributes: [AnyHashable: Any]?) -> CVPixelBuffer? { nil }
    }

    /// The one-pass chain's GPU time on its own (no Core Image around it): best of 20, in ms.
    private static func chainGPU(_ stock: FilmStock, _ settings: FilmSettings, width: Int, height: Int, scale: Double) -> Double {
        guard let device = PhotoEngine.device, let queue = device.makeCommandQueue() else { return .nan }
        let geometry = FilmGeometry(fullLongEdge: 6048, renderScale: scale), extent = CGRect(x: 0, y: 0, width: width, height: height)
        let params = FilmLook.Params(stock, ev: 0, printEV: 0)
        let display = geometry.scale < 1
        let chain = FilmHalation.Chain(stock: stock, params: params.data, scatter: FilmHalation.scatter(stock, settings, geometry, precise: !display),
                                       halation: FilmHalation.halation(stock, settings, geometry, precise: !display), couplers: FilmHalation.couplers(stock, settings, geometry),
                                       grain: FilmGrain.plan(stock, settings, geometry, extent: extent), scan: FilmHalation.scanner(settings, geometry), extent: extent,
                                       light: display)
        func texture() -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let input = texture(), let output = texture() else { return .nan }
        // A grey ramp with some texture, so densities vary from pixel to pixel.
        let upload = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        upload.storageMode = .shared
        if let shared = device.makeTexture(descriptor: upload), let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() {
            var values = [Float](repeating: 1, count: width * height * 4)
            for y in 0..<height { for x in 0..<width {
                let v = Float(0.18 * pow(2, -4 + 7 * Double(x) / Double(width))) * (1 + 0.3 * Float((x * 7 + y * 13) % 17) / 17)
                let i = (y * width + x) * 4
                values[i] = v; values[i + 1] = v * 0.9; values[i + 2] = v * 0.8
            } }
            shared.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: values, bytesPerRow: width * 16)
            blit.copy(from: shared, to: input); blit.endEncoding(); buffer.commit(); buffer.waitUntilCompleted()
        }
        var best = Double.infinity
        for _ in 0..<20 {
            guard let buffer = queue.makeCommandBuffer() else { return .nan }
            do { try FilmHalation.render(chain, input: ChainInput(input, extent), output: ChainOutput(output, extent, buffer)) } catch { return .nan }
            buffer.commit(); buffer.waitUntilCompleted()
            best = min(best, (buffer.gpuEndTime - buffer.gpuStartTime) * 1000)
        }
        return best
    }

    /// What the grain adds on a preview of a 6048-pixel photo, and at full size (for the report).
    private static func grainSpeed() -> [String] {
        guard let device = PhotoEngine.device, let stock = FilmTables.shared.stock(film: "kodak_portra_400", paper: "kodak_portra_endura"),
              let queue = device.makeCommandQueue() else { return ["grain speed: no GPU"] }
        var out: [String] = []
        for (width, height, scale) in [(2048, 1365, 2048.0 / 6048), (3024, 1964, 3024.0 / 6048), (3024, 1964, 1.0)] {
            let noise = CIFilter(name: "CIRandomGenerator")?.outputImage ?? CIImage(color: .gray)
            let scene = noise.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
            let geometry = FilmGeometry(fullLongEdge: 6048, renderScale: scale)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderWrite, .shaderRead]
            guard let target = device.makeTexture(descriptor: descriptor) else { continue }
            func time(_ on: [String], _ extra: [String: SettingValue] = [:]) -> Double {
                let image = FilmLook.apply(scene, stock: stock, settings: spatial("kodak_portra_400", "kodak_portra_endura", on: on, extra), geometry: geometry)
                var best = Double.infinity
                for _ in 0..<20 {
                    guard let buffer = queue.makeCommandBuffer() else { return .nan }
                    let destination = CIRenderDestination(mtlTexture: target, commandBuffer: buffer)
                    let t0 = Date()
                    _ = try? PhotoEngine.context.startTask(toRender: image, to: destination)
                    buffer.commit(); buffer.waitUntilCompleted()
                    best = min(best, Date().timeIntervalSince(t0) * 1000)
                }
                return best
            }
            let all = halationKeys + couplerKeys + scanKeys
            let f = { (v: Double) in String(format: "%.1f", v) }
            func gpu(_ on: [String], _ extra: [String: SettingValue] = [:]) -> String {
                f(chainGPU(stock, spatial("kodak_portra_400", "kodak_portra_endura", on: on, extra), width: width, height: height, scale: scale))
            }
            for (film, paper) in [("kodak_trix", nil), ("kodak_vision3_500t", "kodak_2383")] as [(String, String?)] {
                guard let other = FilmTables.shared.stock(film: film, paper: paper) else { continue }
                out.append("chain GPU time \(width)×\(height) at scale \(String(format: "%.3f", scale)) \(film): all but grain "
                           + f(chainGPU(other, spatial(film, paper, on: all), width: width, height: height, scale: scale)) + " ms, all with grain "
                           + f(chainGPU(other, spatial(film, paper, on: all + grainKeys), width: width, height: height, scale: scale)) + " ms")
            }
            out.append("chain GPU time \(width)×\(height) at scale \(String(format: "%.3f", scale)) (best of 20): grain alone \(gpu(grainKeys)) ms, "
                       + "without sharpening \(gpu(grainKeys, ["grain_usm_amount": .number(0)])) ms, without blurs \(gpu(grainKeys, ["grain_usm_amount": .number(0), "grain_blur": .number(0.2)])) ms, "
                       + "scan only \(gpu(scanKeys)) ms, all but grain \(gpu(all)) ms, all with grain \(gpu(all + grainKeys)) ms")
            out.append("grain speed \(width)×\(height) at scale \(String(format: "%.3f", scale)) (best of 20): fused \(f(time([]))) ms, grain alone \(f(time(grainKeys))) ms, "
                       + "all but grain \(f(time(all))) ms, all with grain \(f(time(all + grainKeys))) ms; grain without sharpening \(f(time(grainKeys, ["grain_usm_amount": .number(0)]))) ms, "
                       + "without blurs \(f(time(grainKeys, ["grain_usm_amount": .number(0), "grain_blur": .number(0.2)]))) ms")
        }
        return out
    }
}

// MARK: - Film in the develop chain (Task 8): the route, and the speed of the whole thing

extension PhotoSelfTest {
    static func filmInstant() async {
        var notes: [String] = ["", "Film in the develop chain:"]
        defer { appendNotes(notes) }
        await FilmEngine.shared.loadProfiles()
        filmRoute(&notes)
        guard let path = filmPhoto24() else {
            for name in ["slider speed", "stock switch speed", "export speed", "batch export memory", "export matches preview"] {
                check("film \(name)", false, "couldn't make the 24 MP test photo")
            }
            return
        }
        defer { try? FileManager.default.removeItem(atPath: path) }
        // (First: its memory measures need a process that hasn't held full-size film yet.)
        await filmFullRapid(path, &notes)
        filmOnScreen(path, &notes)
        await filmSpeed(path, &notes)
        await filmExports(path, &notes)
    }

    /// Which settings take which way.
    private static func filmRoute(_ notes: inout [String]) {
        func film(_ id: String, _ paper: String, _ changed: [String: Double]) -> FilmSettings {
            var settings = FilmSettings()
            settings.film = id; settings.paper = paper
            settings.changed = changed.mapValues { .number($0) }
            return settings
        }
        func kind(_ route: FilmRoute) -> String {
            switch route { case .instant: "instant"; case .tables: "tables"; case .helper: "helper" }
        }
        let provia = "fujifilm_provia_100f", P = "kodak_portra_400", E = "kodak_portra_endura"
        let cases: [(String, FilmSettings, String)] = [
            ("defaults", film(P, E, [:]), "instant"),
            ("as the picker sets it", film(P, E, ["scan_film": 0]), "instant"),
            ("the instant sliders", film(P, E, ["exposure_ev": 1.5, "print_exposure_ev": -0.7, "grain_on": 1, "grain_amount": 2, "halation_on": 1,
                                          "halation_amount": 3, "halation_scale": 2, "scatter_amount": 0.4, "scatter_scale": 1.5]), "instant"),
            ("grain and halation off", film(P, E, ["grain_on": 0, "halation_on": 0]), "instant"),
            ("ported spatial settings", film(P, E, ["couplers_diffusion_um": 30, "couplers_tail_um": 100, "couplers_tail_weight": 0.1, "film_format_mm": 60,
                                              "scan_blur": 1, "scan_usm_sigma": 1, "scan_usm_amount": 1, "grain_blur": 2, "grain_dye_cloud": 2,
                                              "grain_usm_sigma": 1, "grain_usm_amount": 1]), "instant"),
            ("a setting back at its default", film(P, E, ["push_pull_stops": 0, "print_contrast": 1]), "instant"),
            ("off effects' own settings", film(P, E, ["boost_range": 0.5, "protect_ev": 2, "diffusion_strength": 1, "print_diffusion_scale": 2]), "instant"),
            ("pre-flash colour without pre-flash", film(P, E, ["preflash_m_shift": 5]), "instant"),
            ("slide scanned", film(provia, "kodak_portra_endura", ["scan_film": 1]), "instant"),
            ("slide scanned, print settings", film(provia, "kodak_portra_endura", ["scan_film": 1, "print_contrast": 1.4, "glare_percent": 0.3]), "instant"),
            ("slide printed", film(provia, "kodak_2383", ["scan_film": 0]), "instant"),
            ("push", film(P, E, ["push_pull_stops": 1]), "tables"),
            ("grain size", film(P, E, ["grain_granularity": 2]), "tables"),
            ("print contrast", film(P, E, ["print_contrast": 1.4]), "tables"),
            ("pre-flash", film(P, E, ["preflash_exposure": 0.5, "preflash_m_shift": 5]), "tables"),
            ("couplers", film(P, E, ["couplers_amount": 0.5]), "tables"),
            ("auto print exposure", film(P, E, ["print_auto_exposure": 1]), "tables"),
            ("negative scanned", film(P, E, ["scan_film": 1]), "tables"),
            ("highlight boost", film(P, E, ["boost_ev": 1]), "helper"),
            ("diffusion filter", film(P, E, ["diffusion_on": 1]), "helper"),
            ("print diffusion", film(P, E, ["print_diffusion_on": 1]), "helper"),
            ("glare on a print", film(P, E, ["glare_percent": 0.3]), "helper"),
            ("a setting Pluck doesn't know", film(P, E, ["made_up_setting": 1]), "helper"),
            ("unknown film", film("no_such_film", "kodak_portra_endura", [:]), "helper"),
            ("unknown paper", film("kodak_portra_400", "no_such_paper", [:]), "helper"),
        ]
        var wrong = cases.filter { kind(FilmRoute.of($0.1)) != $0.2 }.map { "\($0.0): \(kind(FilmRoute.of($0.1))), not \($0.2)" }
        // The key names the tables: the same for the same settings, another for others, the instant sliders left out
        // (unless the exposures are made into the tables: auto print exposure or a scanned film).
        func key(_ s: FilmSettings) -> String? { if case .tables(let key) = FilmRoute.of(s) { key } else { nil } }
        let push1 = key(film(P, E, ["push_pull_stops": 1])), push2 = key(film(P, E, ["push_pull_stops": 2]))
        let push1Exposed = key(film(P, E, ["push_pull_stops": 1, "exposure_ev": 1, "grain_amount": 2]))
        let auto0 = key(film(P, E, ["print_auto_exposure": 1])), auto1 = key(film(P, E, ["print_auto_exposure": 1, "exposure_ev": 1]))
        let otherPaper = key(film("kodak_portra_400", "kodak_2383", ["push_pull_stops": 1]))
        // Scanned: the exposures stay out of the key (only auto print exposure bakes them in).
        let scan0 = key(film(provia, E, ["scan_film": 1, "push_pull_stops": 1])), scan1 = key(film(provia, E, ["scan_film": 1, "push_pull_stops": 1, "exposure_ev": 1]))
        if scan0 == nil || scan0 != scan1 { wrong.append("scanned tables key changes with exposure: \(scan0 ?? "-") / \(scan1 ?? "-")") }
        // A stock that's listed but won't load: the helper, for the preview and the export alike.
        let broken = film("kodak_gold_200", "kodak_2383", [:])
        let before = FilmRoute.of(broken)
        FilmRoute.markUnloadable(broken)
        let after = FilmRoute.of(broken), resolved = FilmRoute.resolved(broken), stock = FilmRoute.stock(broken)
        FilmRoute.forgetFailures()
        if before != .instant || after != .helper || resolved != .helper || stock != nil || FilmRoute.resolved(broken) != .instant {
            wrong.append("unloadable stock: before \(kind(before)), after \(kind(after)), resolved \(kind(resolved)), stock \(stock == nil ? "none" : "given")")
        }
        if push1 == nil || push1 == push2 || push1 != push1Exposed || auto0 == auto1 || otherPaper == push1 {
            wrong.append("tables keys: push 1 \(push1 ?? "-"), push 2 \(push2 ?? "-"), push 1 exposed \(push1Exposed ?? "-"), auto \(auto0 ?? "-") / \(auto1 ?? "-")")
        }
        // The defaults it assumes before the film engine is installed are the engine's own.
        let schema = FilmEngine.shared.schema
        if schema.isEmpty {
            wrong.append("no schema from the film engine to check the defaults against")
        } else {
            for key in (FilmRoute.filmKeys + FilmRoute.printKeys + ["scan_film"]).sorted() {
                let mine = FilmRoute.builtInDefaults[key], theirs = schema[key]?.value
                notes.append("route default \(key): engine \(theirs.map { "\($0)" } ?? "-"), built in \(mine.map { "\($0)" } ?? "-")")
                if let mine, mine != theirs { wrong.append("\(key) default \(mine), the engine's \(theirs.map { "\($0)" } ?? "none")") }
                let shipped = FilmTables.shared.defaults[key]
                if shipped == nil || shipped != theirs { wrong.append("\(key): the tables' default \(shipped.map { "\($0)" } ?? "missing"), the engine's \(theirs.map { "\($0)" } ?? "none")") }
            }
            let unknown = schema.keys.filter { !Set(FilmRoute.instantKeys + FilmRoute.filmKeys + FilmRoute.printKeys + FilmRoute.offStages + ["scan_film"]).contains($0) }
            if !unknown.isEmpty { notes.append("engine settings FilmRoute sends to the helper: \(unknown.sorted())") }
        }
        check("film route", wrong.isEmpty, wrong.joined(separator: "; "))
    }

    /// A 24 MP photo (6000 × 4000, a JPEG made from the test photo), for the speed checks.
    private static func filmPhoto24() -> String? {
        guard let first = try? FileManager.default.contentsOfDirectory(atPath: photos).sorted().first(where: { $0.lowercased().hasSuffix(".jpg") }),
              let source = CIImage(contentsOf: URL(fileURLWithPath: photos).appendingPathComponent(first), options: [.applyOrientationProperty: true])
        else { return nil }
        let s = max(6000 / source.extent.width, 4000 / source.extent.height)
        let big = source.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": s, "inputAspectRatio": 1])
        let cut = big.cropped(to: CGRect(x: big.extent.midX - 3000, y: big.extent.midY - 2000, width: 6000, height: 4000))
        let picture = cut.transformed(by: CGAffineTransform(translationX: -cut.extent.minX, y: -cut.extent.minY))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-film-test", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("film24-\(UUID().uuidString).jpg")
        guard (try? PhotoEngine.context.writeJPEGRepresentation(of: picture, to: url, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                              options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.9])) != nil
        else { return nil }
        return url.path
    }

    /// A photo on Portra 400 / Endura as the film picker sets it (every default: grain, halation, couplers, scan sharpening on).
    private static func onFilm(_ changes: [String: Double] = [:], film: String = "kodak_portra_400", paper: String = "kodak_portra_endura") -> PhotoRecord {
        var record = PhotoRecord()
        record.filmOn = true
        record.film.film = film; record.film.paper = paper
        record.film.changed = (["scan_film": 0].merging(changes) { $1 }).mapValues { .number($0) }
        return record
    }

    /// Slider and stock changes on a screen-size preview, as the Photo page draws them: the picture made, then drawn into a texture.
    private static func filmSpeed(_ path: String, _ notes: inout [String]) async {
        let size = PhotoRender.previewSize
        guard let device = PhotoEngine.device, let queue = device.makeCommandQueue(),
              let first = PhotoRender.image(path, record: onFilm(), maxSize: size) else {
            check("film slider speed", false, "no GPU or no preview"); check("film stock switch speed", false, "no GPU or no preview")
            return
        }
        let extent = first.extent.integral
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: Int(extent.width), height: Int(extent.height), mipmapped: false)
        descriptor.usage = [.shaderWrite, .shaderRead, .renderTarget]
        descriptor.storageMode = .private
        guard let target = device.makeTexture(descriptor: descriptor) else { check("film slider speed", false, "no texture"); return }
        /// One redraw: wall time (ms, the picture made and drawn) and the GPU's own time. `drag`: as while a slider is dragged.
        func redraw(_ record: PhotoRecord, drag: Bool = false) -> (wall: Double, gpu: Double) {
            let t0 = Date()
            guard let image = PhotoRender.image(path, record: record, maxSize: size, drag: drag), let buffer = queue.makeCommandBuffer() else { return (.nan, .nan) }
            let destination = CIRenderDestination(mtlTexture: target, commandBuffer: buffer)
            _ = try? PhotoEngine.context.startTask(toRender: image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)),
                                                   to: destination)
            buffer.commit(); buffer.waitUntilCompleted()
            return (Date().timeIntervalSince(t0) * 1000, (buffer.gpuEndTime - buffer.gpuStartTime) * 1000)
        }
        func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? .nan : s[s.count / 2] }
        let f = { (v: Double) in String(format: "%.1f", v) }
        // While the slider is dragged the picture is drawn at `dragScale`; at the full preview size when it rests.
        for i in 0..<4 { _ = redraw(onFilm(["exposure_ev": Double(i) * 0.05])); _ = redraw(onFilm(["exposure_ev": Double(i) * 0.05]), drag: true) }
        var walls: [Double] = [], full: [Double] = []
        for i in 0..<20 {
            walls.append(redraw(onFilm(["exposure_ev": -1 + Double(i) * 0.1]), drag: true).wall)
            full.append(redraw(onFilm(["exposure_ev": -1 + Double(i) * 0.1 + 0.05])).wall)
        }
        let plain = (0..<10).map { i -> Double in var r = onFilm(); r.filmOn = false; r.adjust.exposure = Double(i) * 0.1; return redraw(r).wall }
        let small = PhotoRender.image(path, record: onFilm(), maxSize: size, drag: true)?.extent.integral ?? .zero
        notes.append("slider: preview \(Int(extent.width))×\(Int(extent.height)) of 6000×4000; film exposure redraw while dragged (\(Int(small.width))×\(Int(small.height))) "
                     + "median \(f(median(walls))) ms (min \(f(walls.min() ?? .nan)), max \(f(walls.max() ?? .nan))); at rest (full preview) median \(f(median(full))) ms "
                     + "(min \(f(full.min() ?? .nan)), max \(f(full.max() ?? .nan))); without film \(f(median(plain))) ms")
        check("film slider speed", median(walls) < 16 && median(full) < 33,
              "dragged \(f(median(walls))) ms, at rest \(f(median(full))) ms (medians over 20 redraws)")

        // A stock that isn't loaded: read from its files, then drawn (three times, each from emptied tables, two stocks in turn).
        func switches() -> [Double] {
            (0..<3).map { i in
                FilmTables.shared.purge()
                let stock = i % 2 == 0 ? onFilm(film: "kodak_gold_200", paper: "kodak_2383") : onFilm(film: "kodak_ektar_100", paper: "kodak_portra_endura")
                let t0 = Date()
                let switched = redraw(stock)
                return switched.wall.isFinite ? Date().timeIntervalSince(t0) * 1000 : .infinity
            }
        }
        let firstSwitches = switches()
        let warm = redraw(onFilm(film: "kodak_gold_200", paper: "kodak_2383")).wall
        notes.append("stock switch (tables not loaded), 3 times: \(firstSwitches.map(f).joined(separator: ", ")) ms, redraw after it \(f(warm)) ms")
        check("film stock switch speed", (firstSwitches.max() ?? .infinity) < 100, "\(firstSwitches.map(f).joined(separator: ", ")) ms")

        // Panning at 100 % (the full-size picture, made once, drawn at 10 places into a Retina-sized view).
        let zoomStart = Date()
        let zoomFull = PhotoRender.image(path, record: onFilm(["exposure_ev": 0.33]), maxSize: 0)
        notes.append("100 % picture made (24 MP scene and film, in bands): \(f(Date().timeIntervalSince(zoomStart) * 1000)) ms")
        if let full = zoomFull, let kept = PhotoRender.base(path, maxSize: 0, record: onFilm()),
           let stock = FilmRoute.stock(onFilm().film) {
            let scene = PhotoRender.adjusted(kept.image, onFilm().adjust, path: path, scene: true, cacheKey: kept.key)
            let floats = PhotoRender.filmed(scene, stock: stock, film: onFilm().film, geometry: PhotoRender.filmGeometry(path, source: kept.image.extent, picture: scene.extent, full: true))
            let view = CGSize(width: 1728, height: 1100)
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 3456, height: 2200, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite, .renderTarget]; d.storageMode = .private
            if let screen = device.makeTexture(descriptor: d) {
                func pan(_ picture: CIImage) -> Double {
                    var times: [Double] = []
                    for i in 0..<10 {
                        let frame = CGRect(x: -800 - Double(i) * 37, y: -600 - Double(i) * 23, width: 3000, height: 2000)
                        let drawn = PhotoComposite.compose(after: picture, before: nil, frame: frame, mode: .off, split: 0.5, view: view, scale: 2)
                        guard let buffer = queue.makeCommandBuffer() else { return .nan }
                        let t0 = Date()
                        let destination = CIRenderDestination(width: 3456, height: 2200, pixelFormat: .rgba16Float, commandBuffer: buffer) { screen }
                        _ = try? PhotoEngine.context.startTask(toRender: drawn, to: destination)
                        buffer.commit(); buffer.waitUntilCompleted()
                        times.append(Date().timeIntervalSince(t0) * 1000)
                    }
                    return median(times)
                }
                _ = pan(full)
                notes.append("pan at 100 % (3456×2200 drawn, film at full size): half floats for the screen \(f(pan(full))) ms, floats \(f(pan(floats))) ms (medians of 10)")
            }
        }

        notes.append("stock switch after the 100 % pan (tables not loaded), 3 times: \(switches().map(f).joined(separator: ", ")) ms")
    }

    /// Exports with film: the time of one, the memory of eight at once, and an export against the preview.
    private static func filmExports(_ path: String, _ notes: inout [String]) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-film-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // The GPU failing to work out the film: the export says so and writes nothing (never a black file), and the
        // 100 % picture gives nothing (the loupe keeps what it shows).
        do {
            var failing = PhotoExportSettings()
            failing.naming = .custom; failing.name = "failing"
            FilmHalation.purge()
            FilmBlur.Pool.shared.refuse = true
            var threw = false
            do { _ = try await PhotoRender.export(path, record: onFilm(), to: folder, settings: failing) } catch { threw = true }
            let full = PhotoRender.image(path, record: onFilm(["exposure_ev": 0.77]), maxSize: 0)
            FilmBlur.Pool.shared.refuse = false
            let written = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasPrefix("failing") } ?? []
            check("film failure is reported, not saved black", threw && written.isEmpty && full == nil,
                  "export threw: \(threw), files: \(written), 100 % picture: \(full == nil ? "none" : "given")")
        }
        let f = { (v: Double) in String(format: "%.0f", v) }
        var settings = PhotoExportSettings()
        settings.naming = .custom; settings.name = "film"
        let record = onFilm()
        var times: [Double] = []
        for i in 0..<3 {
            let t0 = Date()
            let made = try? await PhotoRender.export(path, record: record, to: folder, settings: settings, number: i)
            times.append(made == nil ? .infinity : Date().timeIntervalSince(t0) * 1000)
        }
        // (The first also builds the GPU's pipelines and reads the stock.)
        notes.append("export 24 MP JPEG with film: \(times.map(f).joined(separator: ", ")) ms")
        check("film export speed", (times.dropFirst().min() ?? .infinity) < 1000, "\(times.map(f).joined(separator: ", ")) ms")

        // Eight at once: what they add to the app's memory at most.
        FilmHalation.purge()
        let before = footprint()
        let peak = Peak()
        let sampler = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        sampler.schedule(deadline: .now(), repeating: .milliseconds(10))
        sampler.setEventHandler { peak.note(footprint()) }
        sampler.resume()
        let t0 = Date()
        let made = await withTaskGroup(of: Bool.self) { group in
            for i in 0..<8 { group.addTask { (try? await PhotoRender.export(path, record: record, to: folder, settings: settings, number: 10 + i)) != nil } }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        let elapsed = Date().timeIntervalSince(t0) * 1000
        sampler.cancel()
        peak.note(footprint())
        let added = Double(Int64(peak.value) - Int64(before)) / 1_073_741_824
        notes.append("8 exports at once: \(made) made in \(f(elapsed)) ms; footprint \(String(format: "%.2f", Double(before) / 1_073_741_824)) GB before, "
                     + "peak +\(String(format: "%.2f", added)) GB")
        check("film batch export memory", made == 8 && added < 4, "\(made) of 8, +\(String(format: "%.2f", added)) GB at most")
        FilmHalation.purge()

        // The export scaled down to the preview's size looks like the preview (grain off: its pattern differs).
        let calm = onFilm(["grain_on": 0])
        guard let preview = PhotoRender.image(path, record: calm, maxSize: PhotoRender.previewSize), let stock = FilmRoute.stock(calm.film),
              let full = try? await PhotoRender.filmPicture(path, record: calm, stock: stock) else {
            check("film export matches preview", false, "no preview or export"); return
        }
        let e = preview.extent.integral
        let scaled = full.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": e.width / full.extent.width, "inputAspectRatio": 1])
        let w = min(e.width, scaled.extent.width.rounded(.down)), h = min(e.height, scaled.extent.height.rounded(.down))
        let a = preview.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        let b = scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.minX, y: -scaled.extent.minY)).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        let difference = deltaE2000(a, b)
        notes.append("export vs preview (grain off, \(Int(w))×\(Int(h))): mean ΔE \(String(format: "%.3f", difference.mean)), p99 \(String(format: "%.3f", difference.p99))")
        check("film export matches preview", difference.mean < 1.0, "mean ΔE \(String(format: "%.3f", difference.mean)), p99 \(String(format: "%.3f", difference.p99))")
    }

    /// The app's physical footprint (what Activity Monitor shows as its memory), in bytes.
    nonisolated private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// The largest of the numbers noted (from any thread).
    private final class Peak: @unchecked Sendable {
        private var most: UInt64 = 0
        private let lock = NSLock()
        func note(_ v: UInt64) { lock.withLock { most = max(most, v) } }
        var value: UInt64 { lock.withLock { most } }
    }
}

// MARK: - Film drawn on screen (Task 8 fix): a Metal texture, as the loupe draws, against a bitmap

extension PhotoSelfTest {
    /// What the loupe draws, into a private Metal texture through the same kind of destination its view uses
    /// (`mtlTextureProvider`), copied out: RGBA half floats, rows as the texture holds them.
    private static func drawn(_ image: CIImage, width w: Int, height h: Int, device: MTLDevice, queue: MTLCommandQueue) -> [UInt16]? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite, .renderTarget]; d.storageMode = .private
        let shared = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        shared.storageMode = .shared
        guard let target = device.makeTexture(descriptor: d), let out = device.makeTexture(descriptor: shared), let buffer = queue.makeCommandBuffer() else { return nil }
        let destination = CIRenderDestination(width: w, height: h, pixelFormat: .rgba16Float, commandBuffer: buffer) { target }
        destination.colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        _ = try? PhotoEngine.context.startTask(toRender: image, to: destination)
        guard let blit = buffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: target, to: out); blit.endEncoding()
        buffer.commit(); buffer.waitUntilCompleted()
        var halves = [UInt16](repeating: 0, count: w * h * 4)
        out.getBytes(&halves, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return halves
    }

    /// The same, worked out into memory (rows from the top).
    private static func inMemory(_ image: CIImage, _ bounds: CGRect) -> [Float] {
        let w = Int(bounds.width), h = Int(bounds.height)
        var memory = [Float](repeating: 0, count: w * h * 4)
        memory.withUnsafeMutableBytes { PhotoEngine.context.render(image, toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: bounds, format: .RGBAf, colorSpace: linearSRGB) }
        return memory
    }

    /// The loupe's picture (PhotoComposite at 100 %, panned to many places, the photo's edges included; cuts of it
    /// touching every edge; the whole, odd-sized) drawn into a Metal texture, read back, against the same worked out
    /// into memory: the worst pixel, so a tile one row off anywhere would show.
    static func filmOnScreen(_ path: String, _ notes: inout [String]) {
        guard let device = PhotoEngine.device, let queue = device.makeCommandQueue(),
              let stock = FilmTables.shared.stock(film: "kodak_portra_400", paper: "kodak_portra_endura"),
              let first = try? FileManager.default.contentsOfDirectory(atPath: photos).sorted().first(where: { $0.lowercased().hasSuffix(".jpg") }),
              let source = CIImage(contentsOf: URL(fileURLWithPath: photos).appendingPathComponent(first), options: [.applyOrientationProperty: true])
        else { check("film on screen matches memory", false, "no GPU, stock or photo"); return }
        let width = 1536, height = 1023
        let scene = photo(fit: source, zoom: 1, width: width, height: height)
        var film = FilmSettings()
        film.changed = ["scan_film": .number(0)]
        // The 24 MP photo as the loupe shows it at 100 % (the scene's own passes, then the film at full size), a cut of it.
        let zoomed = PhotoRender.image(path, record: onFilm(), maxSize: 0).map { $0.cropped(to: CGRect(x: 2000, y: 1500, width: width, height: height))
            .transformed(by: CGAffineTransform(translationX: -2000, y: -1500)) } ?? .empty()
        let pictures: [(String, CIImage)] = [
            ("plain", scene),
            ("photo on film at 100 %", zoomed),
            ("film full size", PhotoRender.filmed(scene, stock: stock, film: film, geometry: FilmGeometry(full: scene.extent))),
            ("film for the screen", PhotoRender.filmed(scene, stock: stock, film: film, geometry: FilmGeometry(fullLongEdge: 3000, renderScale: 0.512), display: true)),
        ]
        let view = CGSize(width: 700, height: 500)
        // Which way up the texture's rows are, from the plain picture (an orientation, decided once; a shift isn't one).
        var flipped = false
        if let halves = drawn(scene, width: width, height: height, device: device, queue: queue) {
            let memory = inMemory(scene, scene.extent)
            var straight = 0.0, upside = 0.0
            for y in 0..<height { for x in 0..<width {
                straight += abs(Double(filmHalfToFloat(halves[(y * width + x) * 4 + 1]) - memory[(y * width + x) * 4 + 1]))
                upside += abs(Double(filmHalfToFloat(halves[((height - 1 - y) * width + x) * 4 + 1]) - memory[(y * width + x) * 4 + 1]))
            } }
            flipped = upside < straight
        }
        var bad: [String] = []
        for (name, picture) in pictures {
            var tests: [(String, CIImage, CGRect)] = [("whole", picture, picture.extent.integral)]
            for pan in [CGPoint.zero, CGPoint(x: -836, y: -523), CGPoint(x: -300, y: -201), CGPoint(x: -837, y: 0), CGPoint(x: 0, y: -524), CGPoint(x: 120, y: 77)] {
                let frame = CGRect(x: pan.x, y: pan.y, width: CGFloat(width), height: CGFloat(height))
                tests.append(("pan \(pan)", PhotoComposite.compose(after: picture, before: nil, frame: frame, mode: .off, split: 0.5, view: view, scale: 1),
                              CGRect(origin: .zero, size: view)))
            }
            for cut in [CGRect(x: 0, y: 0, width: 700, height: 500), CGRect(x: 836, y: 523, width: 700, height: 500), CGRect(x: 836, y: 0, width: 700, height: 500),
                        CGRect(x: 0, y: 523, width: 700, height: 501), CGRect(x: 401, y: 263, width: 701, height: 499)] {
                tests.append(("cut \(cut)", picture.cropped(to: cut).transformed(by: CGAffineTransform(translationX: -cut.minX, y: -cut.minY)),
                              CGRect(origin: .zero, size: cut.size)))
            }
            var worst = 0.0, worstAt = ""
            for (label, image, bounds) in tests {
                let w = Int(bounds.width), h = Int(bounds.height)
                guard let halves = drawn(image, width: w, height: h, device: device, queue: queue) else { worst = 100; worstAt = "\(label): no texture"; continue }
                let memory = inMemory(image, bounds)
                for y in 0..<h { for x in 0..<w {
                    let t = ((flipped ? h - 1 - y : y) * w + x) * 4, m = (y * w + x) * 4
                    let e = ciede2000(lab(filmHalfToFloat(halves[t]), filmHalfToFloat(halves[t + 1]), filmHalfToFloat(halves[t + 2])), lab(memory[m], memory[m + 1], memory[m + 2]))
                    if !(e <= worst) { worst = e.isFinite ? e : 100; worstAt = "\(label) at (\(x), \(y))" }
                } }
            }
            notes.append("on screen vs memory, \(name) (\(tests.count) draws, texture rows \(flipped ? "bottom-up" : "top-down")): worst ΔE \(String(format: "%.3f", worst)) \(worstAt)")
            if worst > 0.5 { bad.append("\(name): ΔE \(String(format: "%.2f", worst)) \(worstAt)") }
        }
        // The film at 100 % is kept in a texture, worked out a band at a time from a scene worked out first. Against the film
        // on the same scene held in memory, at every band's edge and the photo's top and bottom (a whole row each).
        if let kept = PhotoRender.base(path, maxSize: 0, record: onFilm()), let banded = PhotoRender.image(path, record: onFilm(), maxSize: 0) {
            let scene = PhotoRender.adjusted(kept.image, onFilm().adjust, path: path, scene: true, cacheKey: kept.key)
            let e = scene.extent.integral
            let still = image(inMemory(scene, e), width: Int(e.width), height: Int(e.height)).transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
            let truth = PhotoRender.filmed(still, stock: stock, film: onFilm().film,
                                           geometry: PhotoRender.filmGeometry(path, source: kept.image.extent, picture: e, full: true), display: true)
            let rows = max(256, PhotoRender.filmBandPixels / Int(e.width))
            var edges = [0, Int(e.height) - 12]
            for top in stride(from: rows, to: Int(e.height), by: rows) { edges.append(Int(e.height) - top - 6) }
            var worst = 0.0, worstAt = ""
            for y0 in edges {
                let cut = CGRect(x: e.minX, y: e.minY + CGFloat(y0), width: e.width, height: 12)
                let a = inMemory(banded, cut), b = inMemory(truth, cut)
                for i in stride(from: 0, to: min(a.count, b.count), by: 4) {
                    let d = ciede2000(lab(a[i], a[i + 1], a[i + 2]), lab(b[i], b[i + 1], b[i + 2]))
                    if !(d <= worst) { worst = d.isFinite ? d : 100; worstAt = "rows \(y0)…, pixel \(i / 4)" }
                }
            }
            notes.append("film at 100 %, kept in \(edges.count - 2 + 1) bands, against memory along every band edge: worst ΔE \(String(format: "%.3f", worst)) \(worstAt)")
            if worst > 0.5 { bad.append("100 % bands: ΔE \(String(format: "%.2f", worst)) \(worstAt)") }
        } else { bad.append("no 100 % picture") }
        check("film on screen matches memory", bad.isEmpty, bad.joined(separator: "; "))
    }
}

// MARK: - A film slider at 100 % (Task 8 fix rounds 2–3)

extension PhotoSelfTest {
    /// Full-size film at 100 %, asked for as the loupe asks (`FullBuilds`, one serial queue, a channel per loupe):
    /// - one build alone from emptied caches: its footprint B1;
    /// - ten quick film changes from the same emptied state: only the last is worked out to the end, never more than one
    ///   at once, at most 1.2·B1 + 100 MB, and the picture is a fresh render's;
    /// - a request cancelled before its turn gives nothing;
    /// - two loupes (Compare) asking in turn: both get their picture.
    static func filmFullRapid(_ path: String, _ notes: inout [String]) async {
        let builds = FullBuilds.shared
        let f = { (v: Double) in String(format: "%.0f", v) }
        let gb = { (v: Double) in String(format: "%.2f", v) }
        func record(_ i: Int) -> PhotoRecord { onFilm(["exposure_ev": 0.1 * Double(i) - 0.45]) }
        func emptied() {
            BaseCache.shared.removeAll(); SceneCache.shared.removeAll(); FilmHalation.purge(); PhotoEngine.context.clearCaches()
        }
        /// The most the footprint grows above where it starts while `work` runs, in GB.
        func peakGrowth(_ work: () async -> Void) async -> Double {
            let before = footprint(), peak = Peak()
            let sampler = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
            sampler.schedule(deadline: .now(), repeating: .milliseconds(5))
            sampler.setEventHandler { peak.note(footprint()) }
            sampler.resume()
            await work()
            sampler.cancel()
            peak.note(footprint())
            return Double(Int64(peak.value) - Int64(before)) / 1_073_741_824
        }
        func ask(_ channel: UUID, _ shown: PhotoRecord) -> Task<CIImage?, Never> {
            let ticket = builds.ticket(channel)
            return Task { await builds.build(channel, ticket, film: true) { cancelled in PhotoRender.image(path, record: shown, maxSize: 0, cancelled: cancelled) } }
        }
        func worst(_ picture: CIImage?, _ shown: PhotoRecord) -> Double {
            guard let picture, let fresh = PhotoRender.image(path, record: shown, maxSize: 0) else { return .infinity }
            var worst = 0.0
            let e = fresh.extent.integral
            for y0 in [0, 1000, 2000, 3000, Int(e.height) - 8] {
                let cut = CGRect(x: e.minX, y: e.minY + CGFloat(y0), width: e.width, height: 8)
                let a = inMemory(picture, cut), b = inMemory(fresh, cut)
                guard a.count == b.count, !a.isEmpty else { return .infinity }
                for i in stride(from: 0, to: a.count, by: 4) {
                    let d = ciede2000(lab(a[i], a[i + 1], a[i + 2]), lab(b[i], b[i + 1], b[i + 2]))
                    worst = max(worst, d.isFinite ? d : 100)
                }
            }
            return worst
        }
        var problems: [String] = []

        // One build alone.
        emptied()
        let one = UUID()
        var single: CIImage?
        let b1 = await peakGrowth { single = await ask(one, record(0)).value }
        if single == nil { problems.append("a single build gave nothing") }
        single = nil

        // Ten quick changes.
        emptied()
        builds.resetMost()
        let finishedBefore = builds.finished
        let burst = UUID()
        var results: [CIImage?] = []
        let t0 = Date()
        let growth = await peakGrowth {
            var asked: [Task<CIImage?, Never>] = []
            for i in 0..<10 {
                asked.append(ask(burst, record(i)))
                try? await Task.sleep(for: .milliseconds(40))
            }
            for one in asked { results.append(await one.value) }
        }
        let elapsed = Date().timeIntervalSince(t0) * 1000
        let completed = builds.finished - finishedBefore, made = results.compactMap { $0 }.count, most = builds.mostAtOnce
        let last = worst(results.last ?? nil, record(9))
        results = []
        let bound = 1.2 * b1 + 0.1
        notes.append("100 %: one build alone +\(gb(b1)) GB; 10 film changes 40 ms apart: \(completed) worked out to the end, \(made) pictures given, "
                     + "at most \(most) at once, done in \(f(elapsed)) ms, footprint +\(gb(growth)) GB at most (bound \(gb(bound))), last vs fresh worst ΔE \(String(format: "%.4f", last))")
        if !(completed == 1 && made == 1 && results.isEmpty && most == 1 && growth <= bound && last < 0.01) {
            problems.append("burst: \(completed) finished, \(made) pictures, \(most) at once, +\(gb(growth)) GB (bound \(gb(bound))), ΔE \(last)")
        }

        // Cancelled before its turn: nothing.
        let gone = UUID(), ticket = builds.ticket(gone)
        builds.cancel(gone, ticket)
        let cancelled = await builds.build(gone, ticket) { _ in CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4)) }
        if cancelled != nil { problems.append("a cancelled request still gave a picture") }

        // Compare: two loupes asking in turn, each with its own settings; both get theirs.
        let left = UUID(), right = UUID()
        var leftAsks: [Task<CIImage?, Never>] = [], rightAsks: [Task<CIImage?, Never>] = []
        for i in 0..<4 {
            leftAsks.append(ask(left, record(i)))
            rightAsks.append(ask(right, record(9 - i)))
            try? await Task.sleep(for: .milliseconds(30))
        }
        var leftLast: CIImage?, rightLast: CIImage?
        for (k, one) in leftAsks.enumerated() { let v = await one.value; if k == 3 { leftLast = v } }
        for (k, one) in rightAsks.enumerated() { let v = await one.value; if k == 3 { rightLast = v } }
        let leftWorst = worst(leftLast, record(3)), rightWorst = worst(rightLast, record(6))
        notes.append("100 %, two loupes asking in turn: left ΔE \(String(format: "%.4f", leftWorst)), right ΔE \(String(format: "%.4f", rightWorst))")
        if !(leftWorst < 0.01 && rightWorst < 0.01) { problems.append("Compare: left \(leftLast == nil ? "nothing" : "ΔE \(leftWorst)"), right \(rightLast == nil ? "nothing" : "ΔE \(rightWorst)")") }
        emptied()
        check("film at 100 % follows the last change", problems.isEmpty, problems.joined(separator: "; "))
    }
}

// MARK: - Advanced settings (Task 9): tables made for one photo, then instant; the helper for the rest

extension PhotoSelfTest {
    static func filmAdvanced() async {
        var notes: [String] = ["", "Advanced settings:"]
        defer { appendNotes(notes) }
        guard FilmEngine.helper != nil, FilmEngine.shared.state == .ready else {
            for name in ["matches reference", "then instant", "cache"] { check("film advanced \(name)", false, "needs the helper and its pack (looked at \(FilmEngine.pack.path))") }
            check("film helper fallback", false, "needs the helper and its pack")
            return
        }
        // From nothing: none kept, on disk or in memory.
        try? FileManager.default.removeItem(at: FilmAdvanced.folder)
        FilmAdvanced.forget()
        notes.append("kept in \(FilmAdvanced.folder.path)")
        func film(_ id: String, _ paper: String, _ changed: [String: Double], colour: Bool = true) -> FilmSettings {
            var settings = FilmSettings()
            settings.film = id; settings.paper = paper
            settings.changed = (colour ? colourOnly : [:]).merging(changed.mapValues { .number($0) }) { $1 }
            return settings
        }
        let P = "kodak_portra_400", E = "kodak_portra_endura"

        // Against the helper, once the tables are made: the brief's two, and a few more stocks (made one after the other, timed).
        let (atlas, regions) = testAtlas()
        let cases: [(String, FilmSettings, Bool)] = [
            ("couplers 0.5", film(P, E, ["couplers_amount": 0.5]), true),
            ("magenta filter +20", film(P, E, ["filter_m": 20]), true),
            ("push 1, Gold 200 on 2302", film("kodak_gold_200", "kodak_2302", ["push_pull_stops": 1]), false),
            ("print contrast 1.4, Double-X on 2302", film("kodak_doublex", "kodak_2302", ["print_contrast": 1.4]), false),
            ("Portra scanned", film(P, E, ["scan_film": 1]), false),
            ("Provia scanned, boost 1.5", film("fujifilm_provia_100f", E, ["scan_film": 1, "output_luminance_boost": 1.5]), false),
            ("auto print exposure, exposure +1", film(P, E, ["print_auto_exposure": 1, "exposure_ev": 1]), false),
        ]
        var bad: [String] = [], all: [String] = []
        for (name, settings, brief) in cases {
            let started = Date()
            guard case .tables = FilmRoute.of(settings) else { bad.append("\(name): not a tables route"); continue }
            guard let stock = await FilmAdvanced.shared.wait(for: settings) else { bad.append("\(name): no tables made"); continue }
            let made = Date().timeIntervalSince(started)
            let ours = FilmLook.apply(atlas, stock: stock, settings: settings, geometry: FilmGeometry(full: atlas.extent))
            let theirs = await reference(atlas, film: settings)
            guard theirs.extent == atlas.extent else { bad.append("\(name): no reference"); continue }
            var worst = (mean: 0.0, p99: 0.0)
            for (_, rect) in regions {
                let e = deltaE2000(ours.cropped(to: rect), theirs.cropped(to: rect))
                worst = (max(worst.mean, e.mean), max(worst.p99, e.p99))
            }
            let line = "\(name): made in \(String(format: "%.0f", made * 1000)) ms, worst mean \(String(format: "%.3f", worst.mean)), worst p99 \(String(format: "%.3f", worst.p99))"
            notes.append("  " + line)
            all.append(line)
            if !(worst.mean < 1.0 && worst.p99 < 3.0) { bad.append(line + (brief ? "" : " (extra)")) }
        }
        check("film advanced matches reference", bad.isEmpty, bad.joined(separator: "; "))

        // After the tables are made, the exposure is instant again: no job for the helper.
        let jpeg = (try? FileManager.default.contentsOfDirectory(atPath: photos))?.sorted().first { $0.lowercased().hasSuffix(".jpg") }
        let photo = jpeg.map { URL(fileURLWithPath: photos).appendingPathComponent($0).path }
        if let photo {
            var record = PhotoRecord()
            record.filmOn = true
            record.film = film(P, E, ["couplers_amount": 0.6], colour: false)
            let first = await FilmRoute.stockWaiting(record.film)
            FilmWorker.asked = 0
            var drawn = 0, routes: [String] = []
            for i in 0..<10 {
                record.film.changed["exposure_ev"] = .number(Double(i) * 0.25 - 1)
                if FilmRoute.resolved(record.film) != .instant { routes.append("change \(i): not instant") }
                if let image = PhotoRender.image(photo, record: record, maxSize: 1024),
                   PhotoEngine.context.createCGImage(image, from: image.extent) != nil { drawn += 1 }
            }
            let jobs = FilmWorker.asked
            notes.append("  advanced then instant: \(drawn) of 10 drawn, \(jobs) helper jobs")
            check("film advanced then instant", first != nil && drawn == 10 && jobs == 0 && routes.isEmpty,
                  "tables \(first == nil ? "not made" : "made"), \(drawn) of 10 drawn, \(jobs) helper jobs; \(routes.joined(separator: ", "))")
        } else { check("film advanced then instant", false, "no test photo in \(photos)") }

        // A setting Pluck doesn't do itself goes to the helper, and comes out as the helper makes it.
        if let photo {
            var record = PhotoRecord()
            record.filmOn = true
            record.film = film(P, E, ["diffusion_on": 1], colour: false)
            let route = FilmRoute.resolved(record.film)
            let before = FilmWorker.asked
            let developed = try? await PhotoRender.develop(photo, record: record, maxSize: 0)
            let jobs = FilmWorker.asked - before
            // The same scene, through the helper directly.
            var expected: CGImage?, control: CGImage?
            if let source = PhotoRender.source(photo, maxSize: 0) {
                // Worked out as the photo page does (its own context, in floats), then handed to the helper.
                let worked = PhotoRender.adjusted(source, record.adjust, path: photo, scene: true)
                let e = worked.extent.integral, w = Int(e.width), h = Int(e.height)
                var light = Data(count: w * h * 16)
                light.withUnsafeMutableBytes { PhotoEngine.context.render(worked, toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: e, format: .RGBAf, colorSpace: linearSRGB) }
                let scene = CIImage(bitmapData: light, bytesPerRow: w * 16, size: e.size, format: .RGBAf, colorSpace: linearSRGB)
                for i in 0..<2 {
                    let theirs = await reference(scene, film: record.film)
                    let made = PhotoEngine.context.createCGImage(theirs, from: theirs.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                    if i == 0 { expected = made } else { control = made }
                }
            }
            func compare(_ one: CGImage?, _ two: CGImage?) -> (differing: Int, most: Int, count: Int)? {
                guard let one, let two, one.width == two.width, one.height == two.height,
                      let a = one.dataProvider?.data as Data?, let b = two.dataProvider?.data as Data?, a.count == b.count else { return nil }
                var differing = 0, most = 0
                for (x, y) in zip(a, b) where x != y { differing += 1; most = max(most, abs(Int(x) - Int(y))) }
                return (differing, most, a.count)
            }
            var detail = "route \(route == .helper ? "helper" : "\(route)"), \(jobs) helper jobs"
            var same = false
            if let ours = compare(developed, expected) {
                // The helper's own run-to-run difference, for scale.
                let own = compare(expected, control)
                same = ours.differing == 0
                detail += ", \(ours.differing) of \(ours.count) bytes differ (by at most \(ours.most)); helper against itself: "
                    + (own.map { "\($0.differing) differ (by at most \($0.most))" } ?? "-")
            } else { detail += ", no picture (\(developed == nil ? "develop" : "reference"))" }
            notes.append("  helper fallback: " + detail)
            check("film helper fallback", route == .helper && jobs >= 1 && same, detail)
        } else { check("film helper fallback", false, "no test photo in \(photos)") }

        // Two exports at once on different tables (a batch's lanes): each gets its own, nothing hangs.
        let one = film(P, E, ["couplers_amount": 0.45]), two = film("kodak_gold_200", "kodak_2302", ["push_pull_stops": 0.5])
        let both = FilmLocked<(FilmStock?, FilmStock?)?>(nil)
        let started = Date()
        Task { @MainActor in
            async let a = FilmAdvanced.shared.wait(for: one)
            async let b = FilmAdvanced.shared.wait(for: two)
            let pair = await (a, b)
            both.withLock { $0 = pair }
        }
        while both.withLock({ $0 == nil }), Date().timeIntervalSince(started) < 30 { try? await Task.sleep(for: .milliseconds(50)) }
        var lanes: [String] = []
        if case let (a, b)? = both.withLock({ $0 }) {
            if a?.film != one.film || a?.paper != one.paper { lanes.append("first got \(a.map { "\($0.film)/\($0.paper ?? "-")" } ?? "nothing")") }
            if b?.film != two.film || b?.paper != two.paper { lanes.append("second got \(b.map { "\($0.film)/\($0.paper ?? "-")" } ?? "nothing")") }
            if case .tables(let k1) = FilmRoute.of(one), case .tables(let k2) = FilmRoute.of(two) {
                if a == nil || FilmAdvanced.made(k1) !== a { lanes.append("first isn't its key's tables") }
                if b == nil || FilmAdvanced.made(k2) !== b { lanes.append("second isn't its key's tables") }
            }
        } else { lanes.append("still waiting after 30 s") }
        notes.append("  two waits at once: \(lanes.isEmpty ? "both right" : lanes.joined(separator: ", ")) in \(String(format: "%.0f", Date().timeIntervalSince(started) * 1000)) ms")
        check("film advanced waits at once", lanes.isEmpty, lanes.joined(separator: "; "))

        // The cache: a damaged set is thrown away and made again; the least recently used go first.
        var cache: [String] = []
        let couplers = film(P, E, ["couplers_amount": 0.5])
        if case .tables(let key) = FilmRoute.of(couplers) {
            let entry = FilmAdvanced.folder.appendingPathComponent("\(key).pft")
            let filmFile = entry.appendingPathComponent("film.pft")
            if let data = try? Data(contentsOf: filmFile) { try? data.prefix(data.count / 3).write(to: filmFile) } else { cache.append("no kept film.pft") }
            FilmAdvanced.forget()
            if FilmAdvanced.made(key) != nil { cache.append("damaged set loaded") }
            if FileManager.default.fileExists(atPath: entry.path) { cache.append("damaged set not removed") }
            if FilmRoute.resolved(couplers) == .helper { cache.append("damaged set counted as failed") }
            let again = await FilmAdvanced.shared.wait(for: couplers)
            if again == nil || !FileManager.default.fileExists(atPath: filmFile.path) { cache.append("not made again") }
        } else { cache.append("couplers not a tables route") }
        let trial = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-film-lru-\(UUID().uuidString)", isDirectory: true)
        let mb = Data(count: 1 << 20)
        for (i, name) in ["a", "b", "c", "d"].enumerated() {
            let entry = trial.appendingPathComponent("\(name).pft", isDirectory: true)
            try? FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
            try? mb.write(to: entry.appendingPathComponent("film.pft"))
            // a is the oldest; b was used last.
            let used = Date(timeIntervalSinceNow: name == "b" ? -10 : Double(-1000 + i * 100))
            try? FileManager.default.setAttributes([.modificationDate: used], ofItemAtPath: entry.path)
        }
        FilmAdvanced.evict(keeping: "a", limit: (5 << 20) / 2, in: trial)
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: trial.path)) ?? []).sorted()
        if left != ["a.pft", "b.pft"] { cache.append("after eviction \(left), not [a, b] (a kept on purpose, b the newest)") }
        try? FileManager.default.removeItem(at: trial)
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: FilmAdvanced.folder.path)) ?? []
        notes.append("  cache: \(kept.count) sets kept; \(cache.isEmpty ? "damaged set made again, eviction by last use" : cache.joined(separator: ", "))")
        check("film advanced cache", cache.isEmpty, cache.joined(separator: "; "))
    }
}
