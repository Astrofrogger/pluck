import CoreImage
import Foundation

/// Cameras' log recordings (flat, grey pictures that keep the most of the scene), turned into a
/// normal picture: the camera's curve back to the scene's light, its colours to Rec.709, then a
/// gentle film-like roll-off into the highlights. Found from the file's own metadata (or a
/// camera's sidecar .XML), or chosen for a clip. One table for the viewer and the export.
enum CameraLog: String, CaseIterable, Identifiable, Sendable {
    case sLog3Cine, sLog3, vLog, canonLog3, logC3, logC4, log3G10, blackmagicFilm, fLog, fLog2, nLog

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sLog3Cine: "Sony S-Log3 Cine"
        case .sLog3: "Sony S-Log3"
        case .vLog: "Panasonic V-Log"
        case .canonLog3: "Canon Log 3"
        case .logC3: "ARRI LogC3"
        case .logC4: "ARRI LogC4"
        case .log3G10: "RED Log3G10"
        case .blackmagicFilm: "Blackmagic Film Gen 5"
        case .fLog: "Fujifilm F-Log"
        case .fLog2: "Fujifilm F-Log2"
        case .nLog: "Nikon N-Log"
        }
    }

    // MARK: - Which, for a clip

    /// What a clip's colour asks for: nil finds it from the file, "none" leaves the picture as
    /// it was recorded.
    static func resolve(_ choice: String?, path: String) -> CameraLog? {
        if let choice { return CameraLog(rawValue: choice) }
        return detect(path)
    }

    nonisolated(unsafe) private static var found: [String: CameraLog?] = [:]
    private static let lock = NSLock()

    /// The log the file was recorded in, as its metadata says (read once per file).
    static func detect(_ path: String) -> CameraLog? {
        if let known = lock.withLock({ found[path] }) { return known }
        let text = metadataText(path)
        // Made by ffmpeg (a download, a conversion, an export): its tags are titles and
        // descriptions, not what a camera wrote (a video about S-Log3 isn't in S-Log3).
        let camera = text.contains("lavf") ? nil : markers.first { marker in marker.words.contains { text.contains($0) } }?.camera
        lock.withLock { found[path] = camera }
        return camera
    }

    /// Words cameras write in their metadata, the more particular first (S-Log3 with the Cine
    /// gamut before plain S-Log3, F-Log2 before F-Log, LogC4 before LogC).
    private static let markers: [(words: [String], camera: CameraLog)] = [
        (["s-gamut3cine", "s-gamut3.cine", "s-log3-cine", "sgamut3cine"], .sLog3Cine),
        (["s-log3", "slog3"], .sLog3),
        (["v-log", "vlog"], .vLog),
        (["canon log 3", "canonlog3", "c-log3", "clog3"], .canonLog3),
        (["logc4", "log-c4", "log c4"], .logC4),
        (["logc3", "logc", "log-c"], .logC3),
        (["log3g10"], .log3G10),
        (["blackmagic design film", "bmd film", "film gen 5", "film gen5"], .blackmagicFilm),
        (["f-log2", "flog2"], .fLog2),
        (["f-log"], .fLog),
        (["n-log"], .nLog),
    ]

    /// The file's metadata as lower-case text: a QuickTime or MP4 file's boxes but its pictures
    /// and sound (so compressed data can't look like a word), an MXF file's header, and the
    /// camera's .XML next to it (Sony's C0001M01.XML, Canon's).
    static func metadataText(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        var chunks: [Data] = []
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            let kind = url.pathExtension.lowercased()
            if ["mov", "mp4", "m4v", "qt"].contains(kind) {
                chunks = boxes(handle)
            } else {
                chunks = [(try? handle.read(upToCount: 1 << 20)) ?? Data()]
            }
        }
        let base = url.deletingPathExtension().lastPathComponent.lowercased()
        let folder = url.deletingLastPathComponent()
        let sidecars = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.lowercased().hasPrefix(base) && $0.lowercased().hasSuffix(".xml") }
        for name in sidecars.prefix(3) {
            if let handle = try? FileHandle(forReadingFrom: folder.appendingPathComponent(name)) {
                chunks.append((try? handle.read(upToCount: 1 << 20)) ?? Data())
                try? handle.close()
            }
        }
        return chunks.map { String(decoding: $0, as: UTF8.self).lowercased() }.joined(separator: "\n")
    }

    /// A QuickTime file's top-level boxes, but the media data (at most 8 MB each).
    private static func boxes(_ handle: FileHandle) -> [Data] {
        let end = (try? handle.seekToEnd()) ?? 0
        var at: UInt64 = 0, found: [Data] = []
        while at + 8 <= end, found.count < 64 {
            try? handle.seek(toOffset: at)
            guard let head = try? handle.read(upToCount: 16), head.count >= 8 else { break }
            var size = UInt64(head.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            let type = String(decoding: head[4..<8], as: UTF8.self)
            var header: UInt64 = 8
            if size == 1, head.count >= 16 {
                size = head[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                header = 16
            } else if size == 0 {
                size = end - at
            }
            guard size >= header else { break }
            if !["mdat", "free", "skip", "wide"].contains(type) {
                try? handle.seek(toOffset: at + header)
                if let body = try? handle.read(upToCount: Int(min(size - header, 8 << 20))) { found.append(body) }
            }
            at += size
        }
        return found
    }

    // MARK: - The curves

    /// The log signal back to the scene's light (0.18 is mid grey). `v` as the camera maker
    /// writes the curve (`codeValues`: a share of the 10-bit code range).
    func linear(_ v: Double) -> Double {
        switch self {
        case .sLog3Cine, .sLog3:
            let cut = 171.2102946929 / 1023
            return v >= cut ? pow(10, (v * 1023 - 420) / 261.5) * 0.19 - 0.01 : (v * 1023 - 95) * 0.01125 / (171.2102946929 - 95)
        case .vLog:
            return v < 0.181 ? (v - 0.125) / 5.6 : pow(10, (v - 0.598206) / 0.241514) - 0.00873
        case .canonLog3:
            let x: Double
            if v < 0.097465473 {
                x = -(pow(10, (0.12783901 - v) / 0.36726845) - 1) / 14.98325
            } else if v <= 0.15277891 {
                x = (v - 0.12512219) / 1.9754798
            } else {
                x = (pow(10, (v - 0.12240537) / 0.36726845) - 1) / 14.98325
            }
            return x * 0.9
        case .logC3:
            return v > 0.1496582 ? (pow(10, (v - 0.385537) / 0.247190) - 0.052272) / 5.555556 : (v - 0.092809) / 5.367655
        case .logC4:
            let a = (pow(2.0, 18.0) - 16) / 117.45, b = (1023 - 95) / 1023.0, c = 95 / 1023.0
            let s = (7 * log(2) * pow(2, 7 - 14 * c / b)) / (a * b), t = (pow(2, 14 * (-c / b) + 6) - 64) / a
            return v >= 0 ? (pow(2, 14 * (v - c) / b + 6) - 64) / a : v * s + t
        case .log3G10:
            return v < 0 ? v / 15.1927 - 0.01 : (pow(10, v / 0.224282) - 1) / 155.975327 - 0.01
        case .blackmagicFilm:
            let a = 0.08692876065, b = 0.005494072432, c = 0.5300133392, d = 8.283605932, e = 0.09246575342
            return v < d * 0.005 + e ? (v - e) / d : exp((v - c) / a) - b
        case .fLog:
            return v >= 0.1005377752 ? (pow(10, (v - 0.790453) / 0.344676) - 0.009468) / 0.555556 : (v - 0.092864) / 8.735631
        case .fLog2:
            return v >= 0.100686685370811 ? (pow(10, (v - 0.384316) / 0.245281) - 0.064829) / 5.555556 : (v - 0.092864) / 8.799461
        case .nLog:
            let code = v * 1023
            return code < 452 ? pow(code / 650, 3) - 0.0075 : exp((code - 619) / 150)
        }
    }

    /// Whether the curve is written as a share of the 10-bit code range (Sony, Panasonic, ARRI,
    /// Fujifilm, Nikon), or of video's black-to-white (Canon, RED, Blackmagic).
    var codeValues: Bool {
        switch self {
        case .canonLog3, .log3G10, .blackmagicFilm: false
        default: true
        }
    }

    /// The camera's colours (red, green, blue, as xy), all with a D65 white.
    var primaries: [(Double, Double)] {
        switch self {
        case .sLog3Cine: [(0.766, 0.275), (0.225, 0.800), (0.089, -0.087)]
        case .sLog3: [(0.730, 0.280), (0.140, 0.855), (0.100, -0.050)]
        case .vLog: [(0.730, 0.280), (0.165, 0.840), (0.100, -0.030)]
        case .canonLog3: [(0.740, 0.270), (0.170, 1.140), (0.080, -0.100)]
        case .logC3: [(0.6840, 0.3130), (0.2210, 0.8480), (0.0861, -0.1020)]
        case .logC4: [(0.7347, 0.2653), (0.1424, 0.8576), (0.0991, -0.0308)]
        case .log3G10: [(0.780308, 0.304253), (0.121595, 1.493994), (0.095612, -0.084589)]
        case .blackmagicFilm: [(0.7177215, 0.3171181), (0.2280410, 0.8615690), (0.1005841, -0.0820452)]
        case .fLog, .fLog2, .nLog: [(0.708, 0.292), (0.170, 0.797), (0.131, 0.046)]
        }
    }

    /// The camera's colours to Rec.709's, in linear light.
    var toRec709: [Double] {
        let rec709 = Self.rgbToXYZ([(0.64, 0.33), (0.30, 0.60), (0.15, 0.06)])
        return Self.multiply(Self.invert(rec709), Self.rgbToXYZ(primaries))
    }

    private static func rgbToXYZ(_ p: [(Double, Double)]) -> [Double] {
        let white = (0.3127, 0.3290)
        func xyz(_ xy: (Double, Double)) -> [Double] { [xy.0 / xy.1, 1, (1 - xy.0 - xy.1) / xy.1] }
        let r = xyz(p[0]), g = xyz(p[1]), b = xyz(p[2]), w = xyz(white)
        let m = [r[0], g[0], b[0], r[1], g[1], b[1], r[2], g[2], b[2]]
        let s = multiply(invert(m), w)
        return [m[0] * s[0], m[1] * s[1], m[2] * s[2], m[3] * s[0], m[4] * s[1], m[5] * s[2], m[6] * s[0], m[7] * s[1], m[8] * s[2]]
    }

    private static func invert(_ m: [Double]) -> [Double] {
        let a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8]
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        return [(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det,
                (f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det,
                (d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]
    }

    /// 3×3 by 3×3, or 3×3 by a column of 3.
    private static func multiply(_ m: [Double], _ n: [Double]) -> [Double] {
        if n.count == 3 { return (0..<3).map { r in m[r * 3] * n[0] + m[r * 3 + 1] * n[1] + m[r * 3 + 2] * n[2] } }
        return (0..<9).map { k in let r = k / 3, c = k % 3; return m[r * 3] * n[c] + m[r * 3 + 1] * n[3 + c] + m[r * 3 + 2] * n[6 + c] }
    }

    // MARK: - The picture

    /// The scene's light shown on a screen: highlights roll off instead of clipping, mid grey
    /// lands a little under half (as camera makers' Rec.709 LUTs put it).
    static func toneMap(_ x: Double) -> Double {
        let x = max(x, 0) * 0.6
        return min(max((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0), 1)
    }

    /// One colour of the picture as the file holds it (video's black to white as 0…1) to the
    /// normal picture's (Rec.709, for a screen's 2.4 gamma).
    func convert(_ rgb: [Double]) -> [Double] {
        let signal = codeValues ? rgb.map { ($0 * 876 + 64) / 1023 } : rgb
        let light = Self.multiply(toRec709, signal.map(linear))
        let shown = light.map { pow(Self.toneMap($0), 1 / 2.4) }
        // A touch more colour, as camera makers' own LUTs give.
        let grey = 0.2126 * shown[0] + 0.7152 * shown[1] + 0.0722 * shown[2]
        return shown.map { min(max(grey + ($0 - grey) * 1.08, 0), 1) }
    }

    static let size = 65

    nonisolated(unsafe) private static var tables: [CameraLog: Data] = [:]

    /// The conversion as a colour cube: RGBA floats, red fastest.
    func cube() -> Data {
        if let known = Self.lock.withLock({ Self.tables[self] }) { return known }
        let n = Self.size
        var values = [Float](repeating: 1, count: n * n * n * 4)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let c = convert([Double(r), Double(g), Double(b)].map { $0 / Double(n - 1) })
            let o = ((b * n + g) * n + r) * 4
            values[o] = Float(c[0]); values[o + 1] = Float(c[1]); values[o + 2] = Float(c[2])
        } } }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        Self.lock.withLock { Self.tables[self] = data }
        return data
    }

    /// The same as a .cube file, for ffmpeg (made once).
    func cubeFile() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-camera-\(rawValue)-2.cube")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let floats = cube().withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var lines = ["LUT_3D_SIZE \(Self.size)"]
        lines.reserveCapacity(floats.count / 4 + 1)
        for i in stride(from: 0, to: floats.count, by: 4) {
            lines.append(String(format: "%.6f %.6f %.6f", floats[i], floats[i + 1], floats[i + 2]))
        }
        let temporary = url.appendingPathExtension("part")
        guard (try? (lines.joined(separator: "\n") + "\n").write(to: temporary, atomically: false, encoding: .utf8)) != nil,
              (try? FileManager.default.moveItem(at: temporary, to: url)) != nil || FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// A still from the file (a thumbnail) as the normal picture.
    func apply(_ still: CGImage) -> CGImage {
        let picture = apply(CIImage(cgImage: still, options: [.colorSpace: NSNull()]))
        return Self.context.createCGImage(picture, from: picture.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) ?? still
    }

    /// The picture as the file holds it (its numbers untouched: made with no colour space) as
    /// the normal picture.
    func apply(_ recorded: CIImage) -> CIImage {
        recorded.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": Self.size, "inputCubeData": cube()])
            .matchedToWorkingSpace(from: CGColorSpace(name: CGColorSpace.itur_709)!) ?? recorded
    }
}
