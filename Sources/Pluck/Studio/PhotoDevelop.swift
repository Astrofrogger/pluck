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
    var texture = 0.0        // fine detail, -100…100
    var dehaze = 0.0         // -100…100
    /// The starting point (nil: Neutral for RAW, As Shot for other photos).
    var profile: PhotoEngine.Profile?
    var sharpen = 0.0        // 0…100
    var noise = 0.0          // noise reduction, 0…100
    var moire = 0.0          // moiré reduction (RAW), 0…100
    /// How the photo is developed, as Lightroom's process versions: 1 the first engine (sRGB,
    /// colour after the profile), 2 scene-referred colour (wide gamut, CAT16, grading before the
    /// tone curve, Whites and Blacks on the curve, real dehaze). Old edits keep their look.
    var process = PhotoAdjustments.currentProcess
    static let currentProcess = 2
    /// The version of Apple's RAW decoder the photo was edited with, kept so a macOS update
    /// doesn't change how it looks (nil: not edited yet, the newest).
    var rawDecoder: String?
    var vignette = 0.0       // darker edges -100 … lighter 100
    var straighten = 0.0     // degrees, -45…45
    var crop = Crop.original
    /// The part kept, as shares of the straightened picture (nil: all of it).
    var cropRect: CropRect?
    /// The crop's ratio upright (true) or lying (false); nil: as the photo is.
    var cropPortrait: Bool?
    var curves = PhotoCurves()
    var wheels = ColorWheels()
    var mixer = ColorMixer()
    /// Changes in part of the photo only (the subject, the background).
    var masks: [PhotoMask] = []

    /// The crop's shape. Ratios turn with the photo (or with `cropPortrait`): 2:3 is 3:2 on a
    /// landscape photo.
    enum Crop: String, Codable, CaseIterable, Identifiable {
        case original, free, square, fourFive, fiveSeven, twoThree, sixteenNine
        var id: String { rawValue }
        var title: String {
            switch self {
            case .original: String(localized: "Original")
            case .free: String(localized: "Free")
            case .square: "1:1"
            case .fourFive: "4:5"
            case .fiveSeven: "5:7"
            case .twoThree: "2:3"
            case .sixteenNine: "9:16"
            }
        }
        /// Short side over long side (nil: free, or as shot).
        var shortOverLong: Double? {
            switch self {
            case .original, .free: nil
            case .square: 1
            case .fourFive: 4.0 / 5
            case .fiveSeven: 5.0 / 7
            case .twoThree: 2.0 / 3
            case .sixteenNine: 9.0 / 16
            }
        }
        /// Width over height for a picture that's upright or not.
        func ratio(portrait: Bool) -> Double? {
            shortOverLong.map { portrait ? $0 : 1 / $0 }
        }

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "portrait45": self = .fourFive
            case "portrait23", "landscape32": self = .twoThree
            case "landscape169": self = .sixteenNine
            default: self = Crop(rawValue: raw) ?? .original
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
        texture = value(.texture, 0); dehaze = value(.dehaze, 0); profile = value(.profile, nil as PhotoEngine.Profile?)
        noise = value(.noise, 0); moire = value(.moire, 0); rawDecoder = value(.rawDecoder, nil as String?); vignette = value(.vignette, 0); straighten = value(.straighten, 0)
        crop = value(.crop, Crop.original); cropRect = value(.cropRect, nil as CropRect?); cropPortrait = value(.cropPortrait, nil as Bool?)
        curves = value(.curves, PhotoCurves()); wheels = value(.wheels, ColorWheels()); mixer = value(.mixer, ColorMixer()); masks = value(.masks, [PhotoMask]())
        // Saved before versions: the first engine, unless nothing was changed.
        process = value(.process, 1)
        if process < Self.currentProcess, isDefault { process = Self.currentProcess }
    }

    /// Nothing changed (which decoder made the photo doesn't count).
    var isDefault: Bool {
        var plain = self
        plain.rawDecoder = nil
        plain.process = Self.currentProcess
        return plain == PhotoAdjustments()
    }

    /// These settings for another photo, which keeps its own decoder.
    func keepingDecoder(of other: PhotoAdjustments) -> PhotoAdjustments {
        var copy = self
        copy.rawDecoder = other.rawDecoder
        return copy
    }

    /// The crop's width over height, for a picture of this shape.
    func cropRatio(pictureRatio: Double) -> Double? {
        crop.ratio(portrait: cropPortrait ?? (pictureRatio < 1))
    }

    /// Whether anything that lives in the colour lookup table is changed (version 1: version 2
    /// does all of it in the develop pass).
    var needsLUT: Bool { process < 2 && (vibrance != 0 || saturation != 0 || !curves.isDefault || !wheels.isDefault || !mixer.isDefault) }
}

/// A local adjustment: where (one or more parts, combined) and what changes there. Version 2
/// develops each mask's settings in the same pass as the photo (scene light, the same sliders as
/// the whole photo); version 1 used the subject or the rest only, with simpler changes.
struct PhotoMask: Codable, Hashable, Identifiable {
    /// The first engine's masks (still read: a mask without parts is this, as one part).
    enum Kind: String, Codable, CaseIterable { case subject, background
        var title: String { self == .subject ? String(localized: "Subject") : String(localized: "Background") }
        var symbol: String { self == .subject ? "person.crop.rectangle" : "photo" }
    }
    var id = UUID()
    var kind: Kind = .subject
    /// Where: the parts in order, each added, taken away or kept only where it overlaps.
    var parts: [MaskPart] = []
    /// Everywhere but where the parts are.
    var invert = false
    /// How much of its changes (1: as set; 0 none … 2 twice).
    var amount = 1.0
    var exposure = 0.0      // stops
    var contrast = 0.0      // -100…100
    var highlights = 0.0
    var shadows = 0.0
    var saturation = 0.0    // -100…100
    var warmth = 0.0        // -100…100 (Temperature, in the mask)
    var tint = 0.0
    var clarity = 0.0       // -100…100
    var texture = 0.0
    var dehaze = 0.0

    init(kind: Kind) { self.kind = kind }

    init(part: MaskPart) {
        parts = [part]
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        id = value(.id, UUID()); kind = value(.kind, Kind.subject); parts = value(.parts, [MaskPart]()); invert = value(.invert, false)
        amount = value(.amount, 1)
        exposure = value(.exposure, 0); contrast = value(.contrast, 0); highlights = value(.highlights, 0); shadows = value(.shadows, 0)
        saturation = value(.saturation, 0); warmth = value(.warmth, 0); tint = value(.tint, 0)
        clarity = value(.clarity, 0); texture = value(.texture, 0); dehaze = value(.dehaze, 0)
    }

    /// The parts, a first-engine mask read as one.
    var shape: [MaskPart] {
        parts.isEmpty ? [MaskPart(kind: .subject, invert: kind == .background)] : parts
    }

    var title: String { shape.first.map { $0.kind.title } ?? kind.title }
    var symbol: String { shape.first.map { $0.kind.symbol } ?? kind.symbol }
}

/// One part of a mask's shape.
struct MaskPart: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case subject, people, object, linear, radial, brush, luminance, colour
        var id: String { rawValue }
        var title: String {
            switch self {
            case .subject: String(localized: "Subject")
            case .people: String(localized: "People")
            case .object: String(localized: "Object")
            case .linear: String(localized: "Linear Gradient")
            case .radial: String(localized: "Radial Gradient")
            case .brush: String(localized: "Brush")
            case .luminance: String(localized: "Brightness Range")
            case .colour: String(localized: "Colour Range")
            }
        }
        var symbol: String {
            switch self {
            case .subject: "person.crop.rectangle"
            case .people: "person.2"
            case .object: "cursorarrow.click.2"
            case .linear: "rectangle.tophalf.filled"
            case .radial: "circle.dashed"
            case .brush: "paintbrush.pointed"
            case .luminance: "circle.lefthalf.filled"
            case .colour: "eyedropper"
            }
        }
        /// Worked out from the photo's own colours (in the develop pass), not drawn.
        var isRange: Bool { self == .luminance || self == .colour }
        /// Found by macOS (Vision).
        var isAI: Bool { self == .subject || self == .people || self == .object }
    }
    enum Mode: String, Codable, CaseIterable { case add, subtract, intersect }

    var id = UUID()
    var kind: Kind
    var mode = Mode.add
    var invert = false
    /// Linear: full at `a`, none at `b`. Radial: the centre is `a`. Object: `a` is where it was
    /// clicked. Shares of the photo, from the top left.
    var a = CGPoint(x: 0.5, y: 0.25)
    var b = CGPoint(x: 0.5, y: 0.6)
    /// Radial: half the width and height, as shares of the photo's.
    var radius = CGSize(width: 0.25, height: 0.25)
    /// Radial: how soft the edge is (0 hard … 1 soft).
    var feather = 0.5
    var strokes: [BrushStroke] = []
    /// Brightness range (0 black … 1 white) and its soft edge.
    var low = 0.0
    var high = 1.0
    var smooth = 0.1
    /// Colour range: the hue (OkLCh degrees) and how wide.
    var hue = 30.0
    var hueRange = 40.0

    init(kind: Kind, invert: Bool = false) {
        self.kind = kind
        self.invert = invert
        if kind == .radial { a = CGPoint(x: 0.5, y: 0.5) }
        if kind == .luminance { low = 0.6 }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        id = value(.id, UUID()); kind = value(.kind, Kind.subject); mode = value(.mode, Mode.add); invert = value(.invert, false)
        a = value(.a, CGPoint(x: 0.5, y: 0.25)); b = value(.b, CGPoint(x: 0.5, y: 0.6)); radius = value(.radius, CGSize(width: 0.25, height: 0.25))
        feather = value(.feather, 0.5); strokes = value(.strokes, [BrushStroke]())
        low = value(.low, 0); high = value(.high, 1); smooth = value(.smooth, 0.1); hue = value(.hue, 30); hueRange = value(.hueRange, 40)
    }
}

/// A brush stroke: the points (shares of the photo, from the top left), its size (share of the
/// photo's long side) and softness; or rubbing out.
struct BrushStroke: Codable, Hashable {
    var points: [CGPoint]
    var size = 0.05
    var softness = 0.5
    var erase = false
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

/// The colour mixer: hue, saturation and luminance for eight bands of colour, as in Lightroom.
/// Worked out in OkLCh, where a hue keeps its look as it gets lighter or darker.
struct ColorMixer: Codable, Hashable {
    enum Band: Int, CaseIterable, Identifiable {
        case red, orange, yellow, green, aqua, blue, purple, magenta
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .red: String(localized: "Red")
            case .orange: String(localized: "Orange")
            case .yellow: String(localized: "Yellow")
            case .green: String(localized: "Green")
            case .aqua: String(localized: "Aqua")
            case .blue: String(localized: "Blue")
            case .purple: String(localized: "Purple")
            case .magenta: String(localized: "Magenta")
            }
        }
        /// Where the band sits on OkLCh's hue circle (degrees).
        var hue: Double { [25, 60, 105, 145, 195, 255, 300, 345][rawValue] }
    }

    /// -100…100 each, by band.
    var hue = [Double](repeating: 0, count: 8)
    var saturation = [Double](repeating: 0, count: 8)
    var luminance = [Double](repeating: 0, count: 8)

    var isDefault: Bool { hue.allSatisfy { $0 == 0 } && saturation.allSatisfy { $0 == 0 } && luminance.allSatisfy { $0 == 0 } }

    /// The bands' share of a hue: smooth, overlapping bumps that add up to one.
    static func weights(_ h: Double) -> [Double] {
        let raw = Band.allCases.map { band -> Double in
            var d = abs(h - band.hue).truncatingRemainder(dividingBy: 360)
            if d > 180 { d = 360 - d }
            return exp(-(d * d) / (2 * 22 * 22))
        }
        let sum = max(raw.reduce(0, +), 1e-6)
        return raw.map { $0 / sum }
    }
}

/// OkLab (Björn Ottosson's perceptual colour space), from and to linear sRGB.
enum OkLab {
    static func from(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    static func to(_ L: Double, _ a: Double, _ b: Double) -> (Double, Double, Double) {
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }
}

/// The colour lookup table (curves, colour wheels, saturation, vibrance): sRGB-encoded in and
/// out, `size`³ entries. Light and white balance happen before it, in the photo engine.
enum DevelopLUT {
    static func build(_ a: PhotoAdjustments, size: Int = 40) -> Data {
        let master = Curve(a.curves.master), red = Curve(a.curves.red), green = Curve(a.curves.green), blue = Curve(a.curves.blue)
        let saturation = 1 + a.saturation / 100, vibrance = a.vibrance / 100
        let w = a.wheels
        let lift = w.lift.rgb, gamma = w.gamma.rgb, gain = w.gain.rgb, offset = w.offset.rgb

        var values = [Float](repeating: 0, count: size * size * size * 4)
        let step = 1.0 / Double(size - 1)
        // One blue slice per core at a time: the table follows a slider.
        values.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: size) { bi in
                var index = bi * size * size * 4
                for gi in 0..<size {
                    for ri in 0..<size {
                        var r = Double(ri) * step, g = Double(gi) * step, b = Double(bi) * step
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
                        // The colour mixer, saturation and vibrance, in OkLCh (so hues hold). Vibrance lifts
                        // dull colours more than strong ones, and leaves skin tones mostly alone.
                        if saturation != 1 || vibrance != 0 || !a.mixer.isDefault {
                            let (L0, A0, B0) = OkLab.from(decode(clamp(r)), decode(clamp(g)), decode(clamp(b)))
                            var L = L0, C = (A0 * A0 + B0 * B0).squareRoot()
                            var h = atan2(B0, A0) * 180 / .pi
                            if h < 0 { h += 360 }
                            if !a.mixer.isDefault, C > 0.002 {
                                let w = ColorMixer.weights(h)
                                var dh = 0.0, ds = 0.0, dl = 0.0
                                for i in 0..<8 { dh += w[i] * a.mixer.hue[i]; ds += w[i] * a.mixer.saturation[i]; dl += w[i] * a.mixer.luminance[i] }
                                // Grey stays grey: the mixer works in proportion to how colourful it is.
                                let colourful = min(C / 0.08, 1)
                                h += dh / 100 * 30 * colourful
                                C *= max(0, 1 + ds / 100 * colourful)
                                L *= 1 + dl / 100 * 0.35 * colourful
                            }
                            var amount = saturation
                            if vibrance != 0 {
                                var skin = abs(h - 55)
                                if skin > 180 { skin = 360 - skin }
                                let protect = exp(-(skin * skin) / (2 * 18 * 18)) * 0.7
                                amount *= 1 + vibrance * (1 - min(C / 0.22, 1)) * (1 - protect)
                            }
                            C *= max(amount, 0)
                            let rad = h * .pi / 180
                            let (lr, lg, lb) = OkLab.to(L, C * cos(rad), C * sin(rad))
                            r = encode(lr); g = encode(lg); b = encode(lb)
                        }
                        buffer[index] = Float(clamp(r)); buffer[index + 1] = Float(clamp(g)); buffer[index + 2] = Float(clamp(b)); buffer[index + 3] = 1
                        index += 4
                    }
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
