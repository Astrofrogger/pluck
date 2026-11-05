import Compression
import Foundation
import simd

/// A creative profile's own colours (Lightroom's `crs:Look`, its `crs:Table_<digest>`): the DNG SDK's
/// RGB table, a 3D table of 16-bit colours in its own primaries and gamma, kept as text (zlib under a
/// Z85-like code). Kept by its digest, so a photo's settings only name it. Read as the SDK reads it
/// (dng_big_table.cpp, dng_reference.cpp, dng_color_space.cpp; see ThirdPartyLicenses.md).
struct LookTable {
    let divisions: Int
    /// Red, green, blue per point, red slowest and blue fastest (0…65535).
    let samples: [UInt16]
    /// 0 sRGB, 1 Adobe RGB, 2 ProPhoto, 3 Display P3, 4 Rec.2020.
    let primaries: Int
    /// 0 linear, 1 sRGB, 2 1.8, 3 2.2, 4 Rec.709.
    let gamma: Int
    /// Colours outside the table's primaries keep how far out they were (the SDK's "gamut extend").
    let extend: Bool

    /// The table from its text; nil when it isn't one (or is a 1D table, which Pluck doesn't read).
    init?(text: String) {
        // Five characters for four bytes, little-endian; a last, shorter group for what's left.
        var digit = [UInt8](repeating: 255, count: 128)
        for (i, c) in Self.code.enumerated() { digit[Int(c)] = UInt8(i) }
        let powers: [UInt32] = [1, 85, 7225, 614_125, 52_200_625]
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count * 4 / 5 + 4)
        var value: UInt32 = 0, phase = 0
        for c in text.utf8 where c < 128 && digit[Int(c)] < 85 {
            value = value &+ UInt32(digit[Int(c)]) &* powers[phase]
            phase += 1
            if phase == 5 {
                bytes += [UInt8(value & 255), UInt8(value >> 8 & 255), UInt8(value >> 16 & 255), UInt8(value >> 24)]
                value = 0; phase = 0
            }
        }
        for k in 0..<max(phase - 1, 0) { bytes.append(UInt8(value >> (8 * UInt32(k)) & 255)) }
        // The table's own size, then a zlib stream (its two-byte header, then deflate).
        guard bytes.count > 6, bytes[4] & 0x0F == 8, (Int(bytes[4]) << 8 | Int(bytes[5])) % 31 == 0 else { return nil }
        let size = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        guard (16...(8 << 20)).contains(size) else { return nil }
        var raw = [UInt8](repeating: 0, count: size)
        let got = bytes.withUnsafeBufferPointer { source in
            raw.withUnsafeMutableBufferPointer { target in
                compression_decode_buffer(target.baseAddress!, size, source.baseAddress! + 6, bytes.count - 6, nil, COMPRESSION_ZLIB)
            }
        }
        guard got == size else { return nil }
        // dng_rgb_table::GetStream: little-endian, each sample stored as its difference from the identity.
        var at = 0
        func u32() -> UInt32? {
            guard at + 4 <= raw.count else { return nil }
            defer { at += 4 }
            return UInt32(raw[at]) | UInt32(raw[at + 1]) << 8 | UInt32(raw[at + 2]) << 16 | UInt32(raw[at + 3]) << 24
        }
        func f64() -> Double? {
            guard let lo = u32(), let hi = u32() else { return nil }
            return Double(bitPattern: UInt64(hi) << 32 | UInt64(lo))
        }
        guard u32() == 1, u32() == 1, u32() == 3, let d = u32().map(Int.init), (2...32).contains(d), at + d * d * d * 6 <= raw.count else { return nil }
        // (As the SDK does: in 32 bits, kept to 16, so 2 per side wraps its top to 0.)
        let identity = (0..<d).map { UInt16(truncatingIfNeeded: ($0 * 0xFFFF + d / 2) / (d - 1)) }
        var samples = [UInt16](repeating: 0, count: d * d * d * 3)
        for i in 0..<(d * d * d) {
            let index = [i / (d * d), i / d % d, i % d]
            for k in 0..<3 {
                let delta = UInt16(raw[at]) | UInt16(raw[at + 1]) << 8
                samples[i * 3 + k] = delta &+ identity[index[k]]
                at += 2
            }
        }
        guard let p = u32(), p < 5, let g = u32(), g < 5, let gamut = u32(), gamut < 2, let low = f64(), let high = f64(),
              (0...1).contains(low), high >= 1 else { return nil }
        divisions = d; self.samples = samples; primaries = Int(p); gamma = Int(g); extend = gamut == 1
    }

    static let code = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?`'|()[]{}@%$#".utf8)

    /// A colour in the table's own encoding (0…1), read between its points as the SDK does (tetrahedra).
    func lookup(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let d = divisions, scale = Double(d - 1)
        let s = c * scale
        let i = SIMD3<Int>(min(Int(s.x), d - 2), min(Int(s.y), d - 2), min(Int(s.z), d - 2))
        let f = s - SIMD3<Double>(Double(i.x), Double(i.y), Double(i.z))
        func at(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Double> {
            let n = ((i.x + r) * d * d + (i.y + g) * d + (i.z + b)) * 3
            return SIMD3(Double(samples[n]), Double(samples[n + 1]), Double(samples[n + 2])) / 65535
        }
        // The tetrahedron the colour is in: the corners from (0,0,0) to (1,1,1) by the largest fractions first.
        let (c1, c2, f1, f2, f3): (SIMD3<Double>, SIMD3<Double>, Double, Double, Double) =
            f.y >= f.x
            ? (f.z >= f.y ? (at(0, 0, 1), at(0, 1, 1), f.z, f.y, f.x) : f.z >= f.x ? (at(0, 1, 0), at(0, 1, 1), f.y, f.z, f.x) : (at(0, 1, 0), at(1, 1, 0), f.y, f.x, f.z))
            : (f.z >= f.x ? (at(0, 0, 1), at(1, 0, 1), f.z, f.x, f.y) : f.z >= f.y ? (at(1, 0, 0), at(1, 0, 1), f.x, f.z, f.y) : (at(1, 0, 0), at(1, 1, 0), f.x, f.y, f.z))
        return (1 - f1) * at(0, 0, 0) + (f1 - f2) * c1 + (f2 - f3) * c2 + f3 * at(1, 1, 1)
    }

    // MARK: - On the picture

    /// Points per side of the cube Core Image is given.
    static let cubeSize = 33

    /// The table as a Core Image colour cube on sRGB steps, at `amount` (1 as the profile makes it, 0…2):
    /// the picture's colour into the table's primaries and gamma, through the table, and back, as
    /// RefRGBtoRGBTable3D does.
    func cube(amount: Double) -> Data {
        let n = Self.cubeSize
        let encode = Self.toPCS[primaries].inverse * Self.toPCS[0], decode = encode.inverse
        var values = [Float](repeating: 1, count: n * n * n * 4)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let picture = SIMD3(Double(r), Double(g), Double(b)) / Double(n - 1)
                    let wide = encode * picture.map(Self.fromSRGB)
                    let inside = simd_clamp(wide, .zero, .one)
                    let source = inside.map { Self.encode($0, gamma) }
                    let made = simd_clamp(source + amount * (lookup(source) - source), .zero, .one)
                    var back = made.map { Self.decode($0, gamma) }
                    if extend { back += wide - inside }
                    let out = simd_clamp(decode * back, .zero, .one).map(Self.toSRGB)
                    let index = ((b * n + g) * n + r) * 4
                    values[index] = Float(out.x); values[index + 1] = Float(out.y); values[index + 2] = Float(out.z)
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Each space's RGB to the DNG SDK's PCS (XYZ, D50), as dng_color_space.cpp has them: sRGB, Adobe RGB,
    /// ProPhoto, Display P3, Rec.2020, each scaled so its white is the PCS's white exactly.
    static let toPCS: [simd_double3x3] = [
        [0.4361, 0.3851, 0.1431, 0.2225, 0.7169, 0.0606, 0.0139, 0.0971, 0.7141],
        [0.6097, 0.2053, 0.1492, 0.3111, 0.6257, 0.0632, 0.0195, 0.0609, 0.7446],
        [0.7977, 0.1352, 0.0313, 0.2880, 0.7119, 0.0001, 0.0000, 0.0000, 0.8249],
        [0.5151, 0.2920, 0.1571, 0.2412, 0.6922, 0.0666, -0.0010, 0.0419, 0.7843],
        [0.6735, 0.1657, 0.1251, 0.2791, 0.6753, 0.0456, -0.0019, 0.0300, 0.7971],
    ].map { m in
        let rows = [SIMD3(m[0], m[1], m[2]), SIMD3(m[3], m[4], m[5]), SIMD3(m[6], m[7], m[8])]
        let white = SIMD3(0.3457 / 0.3585, 1, (1 - 0.3457 - 0.3585) / 0.3585)
        return simd_double3x3(rows: (0..<3).map { rows[$0] * (white[$0] / (rows[$0].x + rows[$0].y + rows[$0].z)) })
    }

    static func fromSRGB(_ e: Double) -> Double { e <= 0.04045 ? e / 12.92 : pow((e + 0.055) / 1.055, 2.4) }
    static func toSRGB(_ x: Double) -> Double { x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055 }

    /// The table's gamma, from linear (dng_function_GammaEncode_*: 1.8 and 2.2 start with a short spline).
    static func encode(_ x: Double, _ gamma: Int) -> Double {
        func spline(_ x: Double, _ x1: Double, _ y1: Double, _ s0: Double, _ s1: Double) -> Double {
            let b = x / x1, c = (x1 - x) / x1
            return (s0 * x1 * b) * c * c + (y1 * (2 - b + c) - s1 * x1 * c) * b * b
        }
        switch gamma {
        case 1: return toSRGB(x)
        case 2: return x <= 8.2118790552e-4 ? spline(x, 8.2118790552e-4, 0.019310851, 32, 13.064306598) : pow(x, 1 / 1.8)
        case 3: return x <= 0.0034800731 ? spline(x, 0.0034800731, 0.0763027458, 32, 9.9661890075) : pow(x, 1 / 2.2)
        case 4: return x < 0.0180539685108078 ? x * 4.5 : 1.0992968268094429 * pow(x, 0.45) - 0.0992968268094429
        default: return x
        }
    }

    /// Back to linear.
    static func decode(_ y: Double, _ gamma: Int) -> Double {
        switch gamma {
        case 1: return fromSRGB(y)
        case 2, 3:
            // (The spline's few steps by halving; the rest is a power.)
            guard y <= (gamma == 2 ? 0.019310851 : 0.0763027458) else { return pow(y, gamma == 2 ? 1.8 : 2.2) }
            var low = 0.0, high = gamma == 2 ? 8.2118790552e-4 : 0.0034800731
            for _ in 0..<40 { let mid = (low + high) / 2; if encode(mid, gamma) < y { low = mid } else { high = mid } }
            return (low + high) / 2
        case 4: return y < 0.0180539685108078 * 4.5 ? y / 4.5 : pow((y + 0.0992968268094429) / 1.0992968268094429, 1 / 0.45)
        default: return y
        }
    }

    // MARK: - Kept by digest

    nonisolated(unsafe) private static var tables: [String: LookTable] = [:]
    nonisolated(unsafe) private static var cubes: [String: Data] = [:]
    private static let lock = NSLock()

    /// Where tables are kept, by digest (a photo's settings only name them).
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck/Photos/Looks", isDirectory: true)
    }

    /// A digest is a file's name: hex only.
    private static func valid(_ digest: String) -> Bool {
        (1...64).contains(digest.count) && digest.allSatisfy(\.isHexDigit)
    }

    /// Keeps the table with this digest (from its text, when it isn't kept yet). Whether it can be used.
    @discardableResult
    static func keep(_ digest: String, text: String?) -> Bool {
        guard valid(digest) else { return false }
        if named(digest) != nil { return true }
        guard let text, let table = LookTable(text: text) else { return false }
        lock.lock(); tables[digest] = table; lock.unlock()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? text.write(to: folder.appendingPathComponent(digest + ".table"), atomically: true, encoding: .utf8)
        return true
    }

    /// The table with this digest, if it's kept.
    static func named(_ digest: String) -> LookTable? {
        guard valid(digest) else { return nil }
        lock.lock()
        if let table = tables[digest] { lock.unlock(); return table }
        lock.unlock()
        guard let text = try? String(contentsOf: folder.appendingPathComponent(digest + ".table"), encoding: .utf8),
              let table = LookTable(text: text) else { return nil }
        lock.lock(); tables[digest] = table; lock.unlock()
        return table
    }

    /// The cube for this table at this amount (kept: building one takes a moment).
    static func cube(_ digest: String, amount: Double) -> Data? {
        let key = digest + String(format: "|%.3f", amount)
        lock.lock()
        if let data = cubes[key] { lock.unlock(); return data }
        lock.unlock()
        guard let data = named(digest)?.cube(amount: amount) else { return nil }
        lock.lock()
        if cubes.count > 16 { cubes.removeAll() }
        cubes[key] = data
        lock.unlock()
        return data
    }
}

private extension SIMD3 where Scalar == Double {
    func map(_ f: (Double) -> Double) -> SIMD3<Double> { SIMD3(f(x), f(y), f(z)) }
}
