import CoreGraphics
import Foundation

/// How a photo is developed: light, colour, white balance, curves and colour wheels (all in one
/// colour lookup table, so they're instant and never make halos), then clarity, sharpening,
/// noise reduction, vignette, straightening and the crop. Nothing is written into the photo.
struct PhotoAdjustments: Codable, Hashable {
    var exposure = 0.0       // stops, -4…4
    var contrast = 0.0       // -100…100
    var highlights = 0.0
    var shadows = 0.0
    var whites = 0.0
    var blacks = 0.0
    var temperature = 0.0    // cooler -100 … warmer 100
    var tint = 0.0           // green -100 … magenta 100
    var vibrance = 0.0
    var saturation = 0.0
    var clarity = 0.0        // softer -100 … crisper 100
    var sharpen = 0.0        // 0…100
    var noise = 0.0          // noise reduction, 0…100
    var vignette = 0.0       // darker edges -100 … lighter 100
    var straighten = 0.0     // degrees, -45…45
    var crop = Crop.original
    /// The part kept, as shares of the straightened picture (nil: all of it).
    var cropRect: CropRect?
    var curves = PhotoCurves()
    var wheels = ColorWheels()

    enum Crop: String, Codable, CaseIterable, Identifiable {
        case original, free, square, portrait45, portrait23, landscape32, landscape169
        var id: String { rawValue }
        var title: String {
            switch self {
            case .original: String(localized: "Original")
            case .free: String(localized: "Free")
            case .square: "1:1"
            case .portrait45: "4:5"
            case .portrait23: "2:3"
            case .landscape32: "3:2"
            case .landscape169: "16:9"
            }
        }
        /// Width over height (nil: free, or as shot).
        var ratio: Double? {
            switch self {
            case .original, .free: nil
            case .square: 1
            case .portrait45: 4.0 / 5
            case .portrait23: 2.0 / 3
            case .landscape32: 3.0 / 2
            case .landscape169: 16.0 / 9
            }
        }
    }

    init() {}

    // Settings saved before a field existed keep its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        exposure = value(.exposure, 0); contrast = value(.contrast, 0); highlights = value(.highlights, 0); shadows = value(.shadows, 0)
        whites = value(.whites, 0); blacks = value(.blacks, 0); temperature = value(.temperature, 0); tint = value(.tint, 0)
        vibrance = value(.vibrance, 0); saturation = value(.saturation, 0); clarity = value(.clarity, 0); sharpen = value(.sharpen, 0)
        noise = value(.noise, 0); vignette = value(.vignette, 0); straighten = value(.straighten, 0)
        crop = value(.crop, Crop.original); cropRect = value(.cropRect, nil as CropRect?)
        curves = value(.curves, PhotoCurves()); wheels = value(.wheels, ColorWheels())
    }

    var isDefault: Bool { self == PhotoAdjustments() }

    /// Whether anything that lives in the lookup table is changed.
    var needsLUT: Bool {
        contrast != 0 || highlights != 0 || shadows != 0 || whites != 0 || blacks != 0 || temperature != 0 || tint != 0
            || vibrance != 0 || saturation != 0 || !curves.isDefault || !wheels.isDefault
    }
}

/// A crop, as shares (0…1) of the picture: where its corner is, and how big it is.
struct CropRect: Codable, Hashable {
    var x = 0.0, y = 0.0, width = 1.0, height = 1.0
}

/// Tone curves: the master (all channels) and one per channel. Points are (in, out) in 0…1.
struct PhotoCurves: Codable, Hashable {
    var master: [CurvePoint] = PhotoCurves.straight
    var red: [CurvePoint] = PhotoCurves.straight
    var green: [CurvePoint] = PhotoCurves.straight
    var blue: [CurvePoint] = PhotoCurves.straight

    static let straight = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
    var isDefault: Bool { master == Self.straight && red == Self.straight && green == Self.straight && blue == Self.straight }
}

struct CurvePoint: Codable, Hashable {
    var x: Double
    var y: Double
}

/// Colour wheels, as in DaVinci Resolve: lift (shadows), gamma (midtones), gain (highlights)
/// and offset (everything). Each has a colour push (x, y on the wheel) and a master amount.
struct ColorWheels: Codable, Hashable {
    struct Wheel: Codable, Hashable {
        var x = 0.0
        var y = 0.0
        var master = 0.0
        var isDefault: Bool { x == 0 && y == 0 && master == 0 }

        /// The push as red, green and blue amounts that add up to zero (hue from the angle).
        var rgb: (Double, Double, Double) {
            let r = x * 0.866 - y * 0.0, g = -x * 0.433 + y * 0.75, b = -x * 0.433 - y * 0.75
            return (r, g, b)
        }
    }

    var lift = Wheel()
    var gamma = Wheel()
    var gain = Wheel()
    var offset = Wheel()
    var isDefault: Bool { lift.isDefault && gamma.isDefault && gain.isDefault && offset.isDefault }
}

/// Builds the colour lookup table for the adjustments: sRGB-encoded in and out, `size`³ entries.
enum DevelopLUT {
    /// How far over white the table reaches (linear), for pulling detail back out of bright
    /// skies in RAW files: the picture is scaled down by this before the table, which then
    /// rolls the highlights off instead of clipping them.
    static func headroom(_ a: PhotoAdjustments) -> Double {
        a.highlights < 0 ? 1 + 3 * (-a.highlights / 100) : 1
    }

    static func build(_ a: PhotoAdjustments, size: Int = 40) -> Data {
        let headroom = headroom(a), recovery = max(-a.highlights / 100, 0)
        let master = Curve(a.curves.master), red = Curve(a.curves.red), green = Curve(a.curves.green), blue = Curve(a.curves.blue)
        // White balance as channel gains in linear light.
        let t = a.temperature / 100, n = a.tint / 100
        let gainR = 1 + t * 0.28, gainB = 1 - t * 0.28, gainG = 1 - n * 0.18
        let tone = ToneCurve(a)
        let hasTone = a.contrast != 0 || a.highlights != 0 || a.shadows != 0 || a.whites != 0 || a.blacks != 0
        let saturation = 1 + a.saturation / 100, vibrance = a.vibrance / 100
        let w = a.wheels
        let lift = w.lift.rgb, gamma = w.gamma.rgb, gain = w.gain.rgb, offset = w.offset.rgb

        var values = [Float](repeating: 0, count: size * size * size * 4)
        let step = 1.0 / Double(size - 1)
        var index = 0
        for bi in 0..<size {
            for gi in 0..<size {
                for ri in 0..<size {
                    var r = Double(ri) * step, g = Double(gi) * step, b = Double(bi) * step
                    if headroom > 1 {
                        // Back to full brightness, the part over white rolled off gently.
                        func roll(_ v: Double) -> Double {
                            let x = decode(v) * headroom, knee = 0.75
                            let soft = x <= knee ? x : knee + (1 - knee) * (1 - exp(-(x - knee) / (1 - knee)))
                            return encode(min(x, 1) * (1 - recovery) + soft * recovery)
                        }
                        r = roll(r); g = roll(g); b = roll(b)
                    }
                    // White balance (in linear light).
                    if t != 0 || n != 0 {
                        r = encode(decode(r) * gainR); g = encode(decode(g) * gainG); b = encode(decode(b) * gainB)
                    }
                    // Light: on the brightness, keeping the colour.
                    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    if hasTone {
                        let l = tone.value(min(max(luma, 0), 1))
                        if luma > 0.002 {
                            // Colour follows the brightness, but gentler, so lifted shadows don't go garish.
                            let k = min(max((l / luma).squareRoot(), 0.6), 1.6)
                            r = l + (r - luma) * k; g = l + (g - luma) * k; b = l + (b - luma) * k
                        } else {
                            r = l; g = l; b = l
                        }
                    }
                    // Colour wheels (lift, gamma, gain, offset), per channel.
                    if !w.isDefault {
                        func grade(_ v: Double, _ lc: Double, _ gc: Double, _ kc: Double, _ oc: Double) -> Double {
                            let liftAmount = (w.lift.master + lc) * 0.25
                            let gainAmount = 1 + (w.gain.master + kc) * 0.5
                            let gammaPower = pow(2, -(w.gamma.master + gc) * 0.8)
                            var x = v * gainAmount + liftAmount * (1 - v)
                            x = x > 0 ? pow(x, gammaPower) : x
                            return x + (w.offset.master + oc) * 0.15
                        }
                        r = grade(r, lift.0, gamma.0, gain.0, offset.0)
                        g = grade(g, lift.1, gamma.1, gain.1, offset.1)
                        b = grade(b, lift.2, gamma.2, gain.2, offset.2)
                    }
                    // Curves: per channel, then the master.
                    r = master.value(red.value(r)); g = master.value(green.value(g)); b = master.value(blue.value(b))
                    // Saturation and vibrance (vibrance lifts dull colours more than strong ones).
                    if saturation != 1 || vibrance != 0 {
                        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
                        let chroma = max(r, g, b) - min(r, g, b)
                        let amount = saturation * (1 + vibrance * (1 - min(chroma * 1.6, 1)) * 0.9)
                        r = y + (r - y) * amount; g = y + (g - y) * amount; b = y + (b - y) * amount
                    }
                    values[index] = Float(clamp(r)); values[index + 1] = Float(clamp(g)); values[index + 2] = Float(clamp(b)); values[index + 3] = 1
                    index += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
    static func decode(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    static func encode(_ v: Double) -> Double {
        let v = max(v, 0)
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }
}

/// Contrast, highlights, shadows, whites and blacks as one brightness curve: each a smooth
/// bump over its own range, gentle enough never to fold back (the curve only ever rises).
struct ToneCurve {
    private var table = [Double](repeating: 0, count: 1025)

    init(_ a: PhotoAdjustments) {
        let c = a.contrast / 100, h = a.highlights / 100, s = a.shadows / 100, w = a.whites / 100, k = a.blacks / 100
        var last = 0.0
        for i in 0...1024 {
            let x = Double(i) / 1024
            var y = x
            if c != 0 {
                let curve = x < 0.5 ? 2 * x * x : 1 - 2 * (1 - x) * (1 - x)
                y += c * (curve - x) * 0.7
            }
            // Shadows peak a quarter of the way up; highlights three quarters.
            let shadow = x * pow(1 - x, 3) / 0.1055, highlight = pow(x, 3) * (1 - x) / 0.1055
            if s != 0 { y += s * shadow * (s > 0 ? 0.17 : 0.09) }
            if h != 0 { y += h * highlight * (h > 0 ? 0.09 : 0.19) }
            if w != 0 { y += w * pow(x, 4) * 0.12 }
            if k != 0 { y += k * pow(1 - x, 4) * 0.07 }
            y = min(max(y, last), 1)
            table[i] = y
            last = y
        }
    }

    func value(_ x: Double) -> Double {
        let p = min(max(x, 0), 1) * 1024, i = min(Int(p), 1023), t = p - Double(i)
        return table[i] + (table[i + 1] - table[i]) * t
    }
}

/// A smooth curve through points that never overshoots (monotone cubic, Fritsch–Carlson).
struct Curve {
    private let xs: [Double]
    private let ys: [Double]
    private let slopes: [Double]
    let isStraight: Bool

    init(_ points: [CurvePoint]) {
        let sorted = points.sorted { $0.x < $1.x }
        xs = sorted.map(\.x)
        ys = sorted.map(\.y)
        isStraight = sorted == PhotoCurves.straight
        let n = sorted.count
        guard n >= 2 else { slopes = []; return }
        var delta = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { delta[i] = (ys[i + 1] - ys[i]) / max(xs[i + 1] - xs[i], 1e-6) }
        var m = [Double](repeating: 0, count: n)
        m[0] = delta[0]
        m[n - 1] = delta[n - 2]
        if n > 2 { for i in 1..<(n - 1) { m[i] = delta[i - 1] * delta[i] <= 0 ? 0 : (delta[i - 1] + delta[i]) / 2 } }
        for i in 0..<(n - 1) where delta[i] != 0 {
            let a = m[i] / delta[i], b = m[i + 1] / delta[i]
            let h = a * a + b * b
            if h > 9 { let t = 3 / h.squareRoot(); m[i] = t * a * delta[i]; m[i + 1] = t * b * delta[i] }
        }
        slopes = m
    }

    func value(_ x: Double) -> Double {
        guard !isStraight, xs.count >= 2 else { return x }
        if x <= xs[0] { return ys[0] }
        if x >= xs[xs.count - 1] { return ys[ys.count - 1] }
        var i = 0
        while i < xs.count - 2 && x > xs[i + 1] { i += 1 }
        let h = xs[i + 1] - xs[i], t = (x - xs[i]) / h
        let t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * ys[i] + (t3 - 2 * t2 + t) * h * slopes[i] + (-2 * t3 + 3 * t2) * ys[i + 1] + (t3 - t2) * h * slopes[i + 1]
    }
}
