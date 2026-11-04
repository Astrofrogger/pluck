import Compression
import Foundation
import Metal

// Loads the film tables Pluck Studio ships (see docs/superpowers/specs/2026-11-04-film-tables-format.md):
// index.json, and one .pft file per film, paper and film-and-paper pair. The GPU film engine
// evaluates the textures built here.

/// A value in a film's `spatial` numbers: a number, a flag or a (nested) list.
enum FilmValue: Sendable, Equatable {
    case number(Double)
    case flag(Bool)
    case list([FilmValue])

    var number: Double? { if case .number(let v) = self { return v } else { return nil } }
    var flag: Bool? { if case .flag(let v) = self { return v } else { return nil } }
    var list: [FilmValue]? { if case .list(let v) = self { return v } else { return nil } }
    /// A list of numbers (three per channel, say).
    var numbers: [Double]? { list?.compactMap(\.number) }
    /// Every number in the value, in order, however deeply nested (a [n][3] list gives n*3 numbers).
    var flat: [Double] {
        switch self {
        case .number(let v): return [v]
        case .flag: return []
        case .list(let items): return items.flatMap(\.flat)
        }
    }
    /// A list of lists of numbers ([n][3]).
    var rows: [[Double]]? { list?.map { $0.flat } }

    init?(json: Any) {
        if let number = json as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .flag(number.boolValue) } else { self = .number(number.doubleValue) }
        } else if let items = json as? [Any] {
            var out: [FilmValue] = []
            for item in items { guard let value = FilmValue(json: item) else { return nil }; out.append(value) }
            self = .list(out)
        } else { return nil }
    }
}

/// The value range of a 3D or per-channel table: node i of axis (or channel) a sits at lo[a] + i·(hi[a] − lo[a])/(n − 1).
struct FilmRange: Sendable, Equatable {
    let lo: SIMD3<Float>
    let hi: SIMD3<Float>
}

/// Every number in the film, paper and pair headers, typed. Fields from a part the stock doesn't use are nil.
struct FilmConstants: Sendable {
    // Film
    /// 9 numbers, row-major: the film's XYZ from the scene's linear sRGB.
    let exposeM: [Float]
    let evScale0: Double
    /// nil when the film file has no `scan`.
    let scanEvScale0: Double?
    let le0: Double
    let leStep: Double
    let couplers: Bool
    /// 9 numbers, row-major: corr[m] = Σ_k couplerM[3m + k] · silver[k].
    let couplerM: [Float]
    // Paper (nil for a film looked at without a print)
    let printLe0: Double?
    let printLeStep: Double?
    let scanRefM: Double?
    let scanRefQ: Double?
    // Pair
    let printLogOffset0: Double?
    let scanBw: Bool?
    let scanBwM: Double?
    let scanBwQ: Double?
    /// A number means the pair was made for that `exposure_ev` only (auto print exposure).
    let bakedExposureEv: Double?
}

/// The tables of one stock as Metal textures, holding the raw node values (interpolate in the shader).
/// 3-channel tables are padded to 4 channels (alpha 0). Index order: the first input runs fastest,
/// so for a 3D texture width = input 0, height = input 1, depth = input 2.
struct FilmTextures: @unchecked Sendable {
    /// `expose_q`: 256×256 RGBA32F, x = u, y = v.
    let exposeQ: MTLTexture
    /// `silver`: 1D RGBA32F, 1021 nodes on (le0, leStep).
    let silver: MTLTexture
    /// `receive`: 1D RGBA32F, 256 nodes, channel c over receiveRange lo[c]…hi[c].
    let receive: MTLTexture
    let receiveRange: FilmRange
    /// `curves`: 1D RGBA32F, 1021 nodes on (le0, leStep).
    let curves: MTLTexture
    /// `print_curves`: 1D RGBA32F, 1021 nodes on (printLe0, printLeStep). nil when scanned.
    let printCurves: MTLTexture?
    /// `print_expose`: 3D RGBA16F over film density. nil when scanned.
    let printExpose: MTLTexture?
    let printExposeRange: FilmRange?
    /// The finished-colour table, 3D RGBA16F: the film's `scan` when scanned (input: film density),
    /// else the pair's `scan` if it has one, else the paper's `scan` (input: paper density; its alpha holds `scan_y`).
    let scan: MTLTexture
    let scanRange: FilmRange
    /// `scan_y`: 3D R16F, over the paper's density (same range as the paper `scan`). nil unless the paper's scan is used.
    let paperScanY: MTLTexture?
    /// `scan_dlog`: 3D RGBA16F, its own N, nil unless the paper's scan is used.
    let paperScanDlog: MTLTexture?
    let paperScanDlogRange: FilmRange?
}

/// The small tables decoded to Float for the CPU (3 values per node unless stated).
struct FilmArrays: Sendable {
    /// 256×256×3, [v][u][c].
    let exposeQ: [Float]
    let silver: [Float]
    let receive: [Float]
    let curves: [Float]
    /// nil when scanned.
    let printCurves: [Float]?
}

/// One film on one paper (or looked at without a print), ready for the evaluator.
final class FilmStock: Sendable {
    let film: String
    /// nil when the film is scanned without a print.
    let paper: String?
    let bw: Bool
    /// True when the finished colour comes from the film's own `scan` (no print).
    let scanned: Bool
    /// True when the pair carries its own `scan` (the paper's scan and fit rescale, step 9, are skipped).
    let hasPairScan: Bool
    let constants: FilmConstants
    let spatial: [String: FilmValue]
    let textures: FilmTextures
    let arrays: FilmArrays

    init(film: String, paper: String?, bw: Bool, scanned: Bool, hasPairScan: Bool, constants: FilmConstants,
         spatial: [String: FilmValue], textures: FilmTextures, arrays: FilmArrays) {
        self.film = film; self.paper = paper; self.bw = bw; self.scanned = scanned; self.hasPairScan = hasPairScan
        self.constants = constants; self.spatial = spatial; self.textures = textures; self.arrays = arrays
    }
}

/// binary16 bits to Float (Float16 isn't available on Intel).
func filmHalfToFloat(_ bits: UInt16) -> Float {
    let sign: UInt32 = UInt32(bits >> 15) << 31
    let exponent = Int((bits >> 10) & 0x1F), fraction = UInt32(bits & 0x3FF)
    if exponent == 0 {
        if fraction == 0 { return Float(bitPattern: sign) }
        let magnitude = Float(fraction) * 5.9604645e-8     // 2^-24
        return sign == 0 ? magnitude : -magnitude
    }
    if exponent == 31 { return Float(bitPattern: sign | 0x7F80_0000 | fraction << 13) }
    return Float(bitPattern: sign | UInt32(exponent + 112) << 23 | fraction << 13)
}

// MARK: - Reading a .pft

/// A decoded blob: raw node values as Float, and its place in the format.
struct FilmBlob {
    let shape: [Int]
    let values: [Float]
    /// The raw binary16 bit patterns, for f16 blobs (uploaded to the GPU as they are).
    let halves: [UInt16]
    let isHalf: Bool
    let range: FilmRange?
    var channels: Int { shape.last ?? 1 }
}

/// One opened .pft: its header and a way to decode its blobs.
struct FilmFile {
    let header: [String: Any]
    private let data: Data
    private let base: Int
    private let blobs: [String: [String: Any]]

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 8,
              data.prefix(4) == Data("PFT1".utf8) else { return nil }
        let length = data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian) }
        guard length > 0, 8 + length <= data.count,
              let json = try? JSONSerialization.jsonObject(with: data.subdata(in: 8..<8 + length)) as? [String: Any],
              let blobs = json["blobs"] as? [String: [String: Any]] else { return nil }
        self.header = json; self.data = data; self.base = 8 + length; self.blobs = blobs
    }

    var constants: [String: Any] { header["constants"] as? [String: Any] ?? [:] }
    func has(_ name: String) -> Bool { blobs[name] != nil }

    /// Decodes a blob (nil if it is missing, malformed or lies outside the file).
    func blob(_ name: String) -> FilmBlob? {
        guard let entry = blobs[name],
              let offset = Self.integer(entry["offset"]), let size = Self.integer(entry["size"]), let rawSize = Self.integer(entry["raw_size"]),
              let codec = entry["codec"] as? String, let dtype = entry["dtype"] as? String,
              let shapeList = entry["shape"] as? [Any], !shapeList.isEmpty,
              offset >= 0, size >= 0, rawSize > 0, rawSize <= 64 << 20 else { return nil }
        var shape: [Int] = []
        for item in shapeList { guard let n = Self.integer(item), n > 0 else { return nil }; shape.append(n) }
        let (start, o1) = base.addingReportingOverflow(offset)
        let (end, o2) = start.addingReportingOverflow(size)
        guard !o1, !o2, end <= data.count else { return nil }
        let filter = entry["filter"] as? String ?? "none"
        let width = dtype == "f16" ? 2 : dtype == "f32" ? 4 : 0
        guard width > 0, ["lzfse", "none"].contains(codec), ["delta_shuffle", "none"].contains(filter) else { return nil }
        var count = 1
        for n in shape {
            let (next, overflow) = count.multipliedReportingOverflow(by: n)
            guard !overflow, next <= rawSize else { return nil }
            count = next
        }
        guard count * width == rawSize, size > 0, codec != "none" || size == rawSize else { return nil }
        var range: FilmRange?
        if let lo = entry["lo"], let hi = entry["hi"] {
            guard let lo = Self.triple(lo), let hi = Self.triple(hi), zip(lo, hi).allSatisfy({ $0.isFinite && $1.isFinite && $1 > $0 }) else { return nil }
            range = FilmRange(lo: SIMD3(lo[0], lo[1], lo[2]), hi: SIMD3(hi[0], hi[1], hi[2]))
        }
        let stored = data.subdata(in: start..<end)
        var raw = [UInt8](repeating: 0, count: rawSize)
        if codec == "lzfse" {
            let got = stored.withUnsafeBytes { source in
                raw.withUnsafeMutableBytes { target in
                    compression_decode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, rawSize,
                                              source.bindMemory(to: UInt8.self).baseAddress!, size, nil, COMPRESSION_LZFSE)
                }
            }
            guard got == rawSize else { return nil }
        } else { raw = [UInt8](stored) }
        let ch = shape[shape.count - 1]
        var values = [Float](repeating: 0, count: count)
        if width == 2 {
            var words = [UInt16](repeating: 0, count: count)
            if filter == "delta_shuffle" {
                raw.withUnsafeBufferPointer { b in
                    for k in 0..<count {
                        var w = UInt16(b[k]) | UInt16(b[count + k]) << 8
                        if k >= ch { w = w &+ words[k - ch] }
                        words[k] = w
                    }
                }
            } else {
                for k in 0..<count { words[k] = UInt16(raw[2 * k]) | UInt16(raw[2 * k + 1]) << 8 }
            }
            for k in 0..<count { values[k] = filmHalfToFloat(words[k]) }
            return FilmBlob(shape: shape, values: values, halves: words, isHalf: true, range: range)
        } else {
            var words = [UInt32](repeating: 0, count: count)
            if filter == "delta_shuffle" {
                raw.withUnsafeBufferPointer { b in
                    for k in 0..<count {
                        var w = UInt32(b[k]) | UInt32(b[count + k]) << 8 | UInt32(b[2 * count + k]) << 16 | UInt32(b[3 * count + k]) << 24
                        if k >= ch { w = w &+ words[k - ch] }
                        words[k] = w
                    }
                }
            } else {
                for k in 0..<count {
                    words[k] = UInt32(raw[4 * k]) | UInt32(raw[4 * k + 1]) << 8 | UInt32(raw[4 * k + 2]) << 16 | UInt32(raw[4 * k + 3]) << 24
                }
            }
            for k in 0..<count { values[k] = Float(bitPattern: words[k]) }
        }
        return FilmBlob(shape: shape, values: values, halves: [], isHalf: false, range: range)
    }

    /// A whole JSON number (not a boolean).
    private static func integer(_ any: Any?) -> Int? {
        guard let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == n.doubleValue.rounded(),
              abs(n.doubleValue) < 9e15 else { return nil }
        return n.intValue
    }

    private static func triple(_ any: Any) -> [Float]? {
        guard let list = any as? [Any], list.count == 3 else { return nil }
        let numbers = list.compactMap { ($0 as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.floatValue } }
        return numbers.count == 3 ? numbers : nil
    }
}

// MARK: - The tables

/// The shipped film tables. Thread-safe; keeps the last 8 stocks and the parts they share.
final class FilmTables: @unchecked Sendable {
    static let shared = FilmTables()

    /// Where the tables are: `-PluckScreenshotFilmTables <dir>` in tests, else the app's FilmTables folder.
    static var folder: URL? {
        if ScreenshotMode.scene != nil, let test = UserDefaults.standard.string(forKey: "PluckScreenshotFilmTables") {
            return URL(fileURLWithPath: test, isDirectory: true)
        }
        return Bundle.main.resourceURL?.appendingPathComponent("FilmTables", isDirectory: true)
    }

    private struct Index: Decodable {
        let films: [FilmEngine.Profile]
        let papers: [FilmEngine.Profile]
        let pairs: [String]
        /// The settings' defaults the tables were made at.
        let defaults: [String: Double]?
        /// The sha256 of the pack's file list the tables were made from.
        let pack_sha256: String?
    }

    private let lock = NSLock()
    /// The index has its own lock, so reading the stock lists never waits for a slow decode.
    private let indexLock = NSLock()
    private let root: URL?
    private var index: Index?
    private var stocks: [(key: String, stock: FilmStock)] = []
    private var filmParts: [String: FilmPartData] = [:]
    private var paperParts: [String: PaperPartData] = [:]
    private var pairParts: [String: PairPartData] = [:]
    private var device: MTLDevice? { PhotoEngine.device }

    /// The tables in `folder`, or the default place.
    init(folder: URL? = FilmTables.folder) { root = folder }

    private func loadIndex() -> Index? {
        indexLock.lock(); defer { indexLock.unlock() }
        if let index { return index }
        guard let root, let data = try? Data(contentsOf: root.appendingPathComponent("index.json")),
              let found = try? JSONDecoder().decode(Index.self, from: data),
              let format = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["format"] as? Int, format == 2 else { return nil }
        index = found
        return found
    }

    /// True when the tables are on disk.
    var isAvailable: Bool { loadIndex() != nil }
    /// The films the pack has (empty without the tables).
    var films: [FilmEngine.Profile] { loadIndex()?.films ?? [] }
    /// The papers the pack has.
    var papers: [FilmEngine.Profile] { loadIndex()?.papers ?? [] }
    /// Every "<film>__<paper>" pair the pack has.
    var pairs: [String] { loadIndex()?.pairs ?? [] }
    /// The sha256 of the film pack's file list the tables were made from.
    var packSHA: String? { loadIndex()?.pack_sha256 }
    /// The settings' defaults the tables were made at (empty when the index doesn't say).
    var defaults: [String: Double] { loadIndex()?.defaults ?? [:] }

    /// The tables for a film printed on a paper, or a film looked at without a print (`paper` nil).
    /// Blocking: reads and decodes what isn't cached. nil if any table is missing or damaged.
    func stock(film: String, paper: String?) -> FilmStock? {
        lock.lock(); defer { lock.unlock() }
        guard let index = loadIndex(), let root else { return nil }
        let key = film + "|" + (paper ?? "")
        if let at = stocks.firstIndex(where: { $0.key == key }) {
            let hit = stocks.remove(at: at)
            stocks.append(hit)
            return hit.stock
        }
        guard index.films.contains(where: { $0.id == film }), let device else { return nil }
        guard let filmPart = filmPart(film, root.appendingPathComponent("film/\(film).pft"), device) else { return nil }
        var made: FilmStock?
        if let paper {
            guard index.papers.contains(where: { $0.id == paper }), index.pairs.contains("\(film)__\(paper)"),
                  let paperPart = paperPart(paper, root.appendingPathComponent("paper/\(paper).pft"), device),
                  let pairPart = pairPart("\(film)__\(paper)", root.appendingPathComponent("pair/\(film)__\(paper).pft"), device) else { return nil }
            made = Self.assemble(film: filmPart, paper: paperPart, pair: pairPart)
        } else {
            made = Self.assemble(film: filmPart, paper: nil, pair: nil)
        }
        guard let made else { return nil }
        stocks.append((key, made))
        if stocks.count > 8 { stocks.removeFirst() }
        return made
    }

    /// Builds a stock from explicit part files (tables made for one photo's advanced settings).
    /// Leave `paper` and `pair` nil to look at the film without a print (the film file needs its `scan`).
    static func stock(at film: URL, paper: URL? = nil, pair: URL? = nil) -> FilmStock? {
        guard let device = PhotoEngine.device, let filmPart = FilmPartData(url: film, device: device) else { return nil }
        if paper == nil && pair == nil { return assemble(film: filmPart, paper: nil, pair: nil) }
        guard let paper, let pair, let paperPart = PaperPartData(url: paper, device: device), let pairPart = PairPartData(url: pair, device: device),
              pairPart.film == filmPart.film, pairPart.paper == paperPart.paper else { return nil }
        return assemble(film: filmPart, paper: paperPart, pair: pairPart)
    }

    /// Whether a stock's files are damaged or unreadable (read on the CPU, no GPU): as opposed to a stock that didn't
    /// load for want of GPU memory, which may load next time.
    func damaged(film: String, paper: String?) -> Bool {
        guard let root else { return true }
        var files = [root.appendingPathComponent("film/\(film).pft")]
        if let paper { files += [root.appendingPathComponent("paper/\(paper).pft"), root.appendingPathComponent("pair/\(film)__\(paper).pft")] }
        return files.contains { url in
            guard let file = FilmFile(url: url), let names = (file.header["blobs"] as? [String: Any])?.keys else { return true }
            return names.contains { file.blob($0) == nil }
        }
    }

    /// Drops everything cached (low memory, or tests).
    func purge() {
        lock.withLock { stocks = []; filmParts = [:]; paperParts = [:]; pairParts = [:] }
    }

    // Part caches: films and papers are shared by many stocks, so they stay a while.
    private func filmPart(_ id: String, _ url: URL, _ device: MTLDevice) -> FilmPartData? {
        if let hit = filmParts[id] { return hit }
        guard let part = FilmPartData(url: url, device: device), part.film == id else { return nil }
        if filmParts.count >= 12 { filmParts = filmParts.filter { kept in stocks.contains { $0.stock.film == kept.key } } }
        filmParts[id] = part
        return part
    }
    private func paperPart(_ id: String, _ url: URL, _ device: MTLDevice) -> PaperPartData? {
        if let hit = paperParts[id] { return hit }
        guard let part = PaperPartData(url: url, device: device), part.paper == id else { return nil }
        if paperParts.count >= 9 { paperParts = paperParts.filter { kept in stocks.contains { $0.stock.paper == kept.key } } }
        paperParts[id] = part
        return part
    }
    private func pairPart(_ id: String, _ url: URL, _ device: MTLDevice) -> PairPartData? {
        if let hit = pairParts[id] { return hit }
        guard let part = PairPartData(url: url, device: device) else { return nil }
        if pairParts.count >= 16 { pairParts = pairParts.filter { kept in stocks.contains { "\($0.stock.film)__\($0.stock.paper ?? "")" == kept.key } } }
        pairParts[id] = part
        return part
    }

    /// Puts the parts together. The scanned rule: no paper means the film's own `scan`.
    private static func assemble(film: FilmPartData, paper: PaperPartData?, pair: PairPartData?) -> FilmStock? {
        let scan: MTLTexture, range: FilmRange
        var paperY: MTLTexture?, dlog: MTLTexture?, dlogRange: FilmRange?
        if let paper, let pair {
            if let own = pair.scan, let ownRange = pair.scanRange { scan = own; range = ownRange }
            else { scan = paper.scan; range = paper.scanRange; paperY = paper.scanY; dlog = paper.scanDlog; dlogRange = paper.scanDlogRange }
        } else {
            guard let own = film.scan, let ownRange = film.scanRange, film.constants.scanEvScale0 != nil else { return nil }
            scan = own; range = ownRange
        }
        let c = film.constants
        let constants = FilmConstants(
            exposeM: c.exposeM, evScale0: c.evScale0, scanEvScale0: c.scanEvScale0, le0: c.le0, leStep: c.leStep,
            couplers: c.couplers, couplerM: c.couplerM,
            printLe0: paper?.printLe0, printLeStep: paper?.printLeStep, scanRefM: paper?.scanRefM, scanRefQ: paper?.scanRefQ,
            printLogOffset0: pair?.printLogOffset0, scanBw: pair?.scanBw, scanBwM: pair?.scanBwM, scanBwQ: pair?.scanBwQ,
            bakedExposureEv: pair?.bakedExposureEv)
        let textures = FilmTextures(
            exposeQ: film.exposeQ, silver: film.silver, receive: film.receive, receiveRange: film.receiveRange, curves: film.curves,
            printCurves: paper?.printCurves, printExpose: pair?.printExpose, printExposeRange: pair?.printExposeRange,
            scan: scan, scanRange: range, paperScanY: paperY, paperScanDlog: dlog, paperScanDlogRange: dlogRange)
        let arrays = FilmArrays(exposeQ: film.exposeQValues, silver: film.silverValues, receive: film.receiveValues,
                                curves: film.curvesValues, printCurves: paper?.printCurvesValues)
        return FilmStock(film: film.film, paper: paper?.paper, bw: film.bw, scanned: paper == nil, hasPairScan: pair?.scan != nil,
                         constants: constants, spatial: film.spatial, textures: textures, arrays: arrays)
    }
}

// MARK: - Parts

private struct FilmHeaderConstants {
    let exposeM: [Float]
    let evScale0: Double
    let scanEvScale0: Double?
    let le0: Double
    let leStep: Double
    let couplers: Bool
    let couplerM: [Float]
}

private func number(_ dict: [String: Any], _ key: String) -> Double? {
    guard let n = dict[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
    let v = n.doubleValue
    return v.isFinite ? v : nil
}
private func flag(_ dict: [String: Any], _ key: String) -> Bool? {
    guard let n = dict[key] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
    return n.boolValue
}
private func floats(_ dict: [String: Any], _ key: String, count: Int) -> [Float]? {
    guard let list = dict[key] as? [NSNumber], list.count == count, list.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() }) else { return nil }
    let out = list.map(\.floatValue)
    return out.allSatisfy(\.isFinite) ? out : nil
}

/// Makes a texture from a decoded blob. 3 channels become 4 (alpha 0, or `alpha`'s one channel); f32 stays RGBA32F,
/// f16 RGBA16F; one f16 channel R16F.
private func makeTexture(_ blob: FilmBlob, dimensions: Int, device: MTLDevice, alpha: FilmBlob? = nil) -> MTLTexture? {
    let ch = blob.channels
    guard (1...3).contains(ch), blob.shape.count == dimensions + 1 else { return nil }
    let sizes = Array(blob.shape.dropLast())          // dimension order: [n2][n1][n0] = depth, height, width
    let width = sizes[sizes.count - 1]
    let height = dimensions >= 2 ? sizes[sizes.count - 2] : 1
    let depth = dimensions >= 3 ? sizes[0] : 1
    let storedCh = ch == 1 ? 1 : 4
    let format: MTLPixelFormat = blob.isHalf ? (storedCh == 1 ? .r16Float : .rgba16Float) : .rgba32Float
    guard !(ch == 1 && !blob.isHalf) else { return nil }
    if let alpha { guard ch == 3, blob.isHalf, alpha.isHalf, alpha.channels == 1, Array(alpha.shape.dropLast()) == sizes else { return nil } }
    let descriptor = MTLTextureDescriptor()
    descriptor.textureType = dimensions == 1 ? .type1D : dimensions == 2 ? .type2D : .type3D
    descriptor.pixelFormat = format
    descriptor.width = width; descriptor.height = height; descriptor.depth = depth
    descriptor.usage = .shaderRead
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
    let nodes = width * height * depth
    let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: width, height: height, depth: depth))
    if blob.isHalf {
        var out = [UInt16](repeating: 0, count: nodes * storedCh)
        for n in 0..<nodes { for c in 0..<ch { out[n * storedCh + c] = blob.halves[n * ch + c] } }
        if let alpha { for n in 0..<nodes { out[n * 4 + 3] = alpha.halves[n] } }
        out.withUnsafeBytes {
            texture.replace(region: region, mipmapLevel: 0, slice: 0, withBytes: $0.baseAddress!,
                            bytesPerRow: width * storedCh * 2, bytesPerImage: width * height * storedCh * 2)
        }
    } else {
        var out = [Float](repeating: 0, count: nodes * 4)
        for n in 0..<nodes { for c in 0..<ch { out[n * 4 + c] = blob.values[n * ch + c] } }
        out.withUnsafeBytes {
            texture.replace(region: region, mipmapLevel: 0, slice: 0, withBytes: $0.baseAddress!,
                            bytesPerRow: width * 16, bytesPerImage: width * height * 16)
        }
    }
    return texture
}

/// Wants a blob with exactly this shape (and, for range blobs, a range).
private func expect(_ file: FilmFile, _ name: String, shape: [Int]? = nil, cube channels: Int? = nil, ranged: Bool, optional: Bool = false) -> FilmBlob?? {
    if !file.has(name) { return optional ? .some(nil) : nil }
    guard let blob = file.blob(name) else { return nil }
    if let shape, blob.shape != shape { return nil }
    if let channels {
        guard blob.shape.count == 4, blob.shape[0] == blob.shape[1], blob.shape[1] == blob.shape[2], blob.shape[3] == channels, blob.shape[0] >= 2 else { return nil }
    }
    if ranged != (blob.range != nil) { return nil }
    return .some(blob)
}

private final class FilmPartData {
    let film: String
    let bw: Bool
    let constants: FilmHeaderConstants
    let spatial: [String: FilmValue]
    let exposeQ, silver, receive, curves: MTLTexture
    let receiveRange: FilmRange
    let exposeQValues, silverValues, receiveValues, curvesValues: [Float]
    let scan: MTLTexture?
    let scanRange: FilmRange?

    init?(url: URL, device: MTLDevice) {
        guard let file = FilmFile(url: url), file.header["part"] as? String == "film", let film = file.header["film"] as? String,
              let bw = flag(file.header, "bw") else { return nil }
        let c = file.constants
        guard let exposeM = floats(c, "expose_m", count: 9), let evScale0 = number(c, "ev_scale0"),
              let le0 = number(c, "le0"), let leStep = number(c, "le_step"), let couplerM = floats(c, "coupler_m", count: 9),
              let couplers = flag(c, "couplers") else { return nil }
        let scanEv = number(c, "scan_ev_scale0")
        guard let q = expect(file, "expose_q", shape: [256, 256, 3], ranged: false), let eq = q,
              let s = expect(file, "silver", shape: [1021, 3], ranged: false), let sv = s,
              let r = expect(file, "receive", shape: [256, 3], ranged: true), let rc = r, let rcRange = rc.range,
              let cu = expect(file, "curves", shape: [1021, 3], ranged: false), let cv = cu,
              let sc = expect(file, "scan", cube: 3, ranged: true, optional: true),
              let exposeQ = makeTexture(eq, dimensions: 2, device: device), let silver = makeTexture(sv, dimensions: 1, device: device),
              let receive = makeTexture(rc, dimensions: 1, device: device), let curves = makeTexture(cv, dimensions: 1, device: device) else { return nil }
        var scanTexture: MTLTexture?
        if let scanBlob = sc {
            guard scanEv != nil, let t = makeTexture(scanBlob, dimensions: 3, device: device) else { return nil }
            scanTexture = t
        }
        var spatial: [String: FilmValue] = [:]
        for (key, value) in file.header["spatial"] as? [String: Any] ?? [:] {
            if let parsed = FilmValue(json: value) { spatial[key] = parsed }
        }
        self.film = film; self.bw = bw; self.spatial = spatial
        self.constants = FilmHeaderConstants(exposeM: exposeM, evScale0: evScale0, scanEvScale0: scanEv, le0: le0, leStep: leStep, couplers: couplers, couplerM: couplerM)
        self.exposeQ = exposeQ; self.silver = silver; self.receive = receive; self.curves = curves; self.receiveRange = rcRange
        exposeQValues = eq.values; silverValues = sv.values; receiveValues = rc.values; curvesValues = cv.values
        scan = scanTexture; scanRange = sc?.range
    }
}

private final class PaperPartData {
    let paper: String
    let printLe0, printLeStep, scanRefM, scanRefQ: Double
    let printCurves: MTLTexture
    let printCurvesValues: [Float]
    let scan: MTLTexture
    let scanRange: FilmRange
    let scanY, scanDlog: MTLTexture
    let scanDlogRange: FilmRange

    init?(url: URL, device: MTLDevice) {
        guard let file = FilmFile(url: url), file.header["part"] as? String == "paper", let paper = file.header["paper"] as? String else { return nil }
        let c = file.constants
        guard let le0 = number(c, "print_le0"), let step = number(c, "print_le_step"), let m = number(c, "scan_ref_m"), let q = number(c, "scan_ref_q"),
              let pc = expect(file, "print_curves", shape: [1021, 3], ranged: false), let curves = pc,
              let sc = expect(file, "scan", cube: 3, ranged: true), let scan = sc, let scanRange = scan.range,
              let sy = expect(file, "scan_y", cube: 1, ranged: true), let scanY = sy,
              scanY.shape == Array(scan.shape.dropLast()) + [1],
              let dl = expect(file, "scan_dlog", cube: 3, ranged: true), let dlog = dl, let dlogRange = dlog.range,
              let curvesTexture = makeTexture(curves, dimensions: 1, device: device),
              // The viewed luminance rides in the scan's alpha, so the shader reads both at once.
              let scanTexture = makeTexture(scan, dimensions: 3, device: device, alpha: scanY),
              let yTexture = makeTexture(scanY, dimensions: 3, device: device),
              let dlogTexture = makeTexture(dlog, dimensions: 3, device: device) else { return nil }
        self.paper = paper; printLe0 = le0; printLeStep = step; scanRefM = m; scanRefQ = q
        printCurves = curvesTexture; printCurvesValues = curves.values
        self.scan = scanTexture; self.scanRange = scanRange; self.scanY = yTexture; scanDlog = dlogTexture; scanDlogRange = dlogRange
    }
}

private final class PairPartData {
    let film, paper: String
    let printLogOffset0: Double
    let scanBw: Bool
    let scanBwM, scanBwQ: Double
    let bakedExposureEv: Double?
    let printExpose: MTLTexture
    let printExposeRange: FilmRange
    let scan: MTLTexture?
    let scanRange: FilmRange?

    init?(url: URL, device: MTLDevice) {
        guard let file = FilmFile(url: url), file.header["part"] as? String == "pair", let film = file.header["film"] as? String,
              let paper = file.header["paper"] as? String else { return nil }
        let c = file.constants
        guard let offset = number(c, "print_log_offset0"), let bw = flag(c, "scan_bw"),
              let m = number(c, "scan_bw_m"), let q = number(c, "scan_bw_q"),
              let pe = expect(file, "print_expose", cube: 3, ranged: true), let expose = pe, let exposeRange = expose.range,
              let sc = expect(file, "scan", cube: 3, ranged: true, optional: true),
              let exposeTexture = makeTexture(expose, dimensions: 3, device: device) else { return nil }
        var scanTexture: MTLTexture?
        if let scanBlob = sc {
            guard let t = makeTexture(scanBlob, dimensions: 3, device: device) else { return nil }
            scanTexture = t
        }
        self.film = film; self.paper = paper; printLogOffset0 = offset; scanBw = bw; scanBwM = m; scanBwQ = q
        bakedExposureEv = number(c, "baked_exposure_ev")
        printExpose = exposeTexture; printExposeRange = exposeRange; scan = scanTexture; scanRange = sc?.range
    }
}
