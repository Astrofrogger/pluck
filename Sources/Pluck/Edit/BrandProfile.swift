import AppKit
import Observation

/// A client's brand rules for Delivery Check: their logo files, where the logo sits (to the
/// pixel), when it shows, its clear space and colour, the palette, texts that must or mustn't be
/// there, and the delivery spec. One JSON file per client in Application Support/Pluck/Brand
/// Profiles; the logo files ride inside it as they were given, so an exported profile is complete.
struct BrandProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var logos: [Logo] = []
    var placements: [Placement] = []
    var timing = Timing()
    var clearSpace = ClearSpace()
    /// The colour the logo must be shown in (the white-on-dark version, say); nil: its own colours.
    var logoColour: String?
    /// How far the logo's colour may drift (CIE76 ΔE).
    var colourTolerance = 3.0
    /// Narrowest the logo may be shown, in pixels at the placement's reference size (0: no minimum).
    var minimumWidth = 0.0
    var palette: [Swatch] = []
    /// Large flat colours that aren't in the palette, as notes.
    var checkPalette = false
    var requiredTexts: [RequiredText] = []
    var forbiddenTexts: [String] = []
    /// For reference only.
    var fonts: [String] = []
    /// The name of a delivery spec preset.
    var deliverySpec: String?

    struct Logo: Codable, Identifiable, Hashable {
        var id = UUID()
        /// The original file's name ("logo-white.svg").
        var fileName: String
        /// The original file, untouched.
        var data: Data
    }

    enum Anchor: String, Codable, CaseIterable, Identifiable {
        case topLeft, topRight, bottomLeft, bottomRight, centre
        var id: String { rawValue }
        var label: String {
            switch self {
            case .topLeft: String(localized: "Top left")
            case .topRight: String(localized: "Top right")
            case .bottomLeft: String(localized: "Bottom left")
            case .bottomRight: String(localized: "Bottom right")
            case .centre: String(localized: "Centre")
            }
        }
    }

    /// Where the logo goes in one output size. x and y run from the anchor corner inwards to the
    /// logo's own matching corner (for the centre: from the picture's centre to the logo's,
    /// right and down), in pixels at the reference size.
    struct Placement: Codable, Identifiable, Hashable {
        var id = UUID()
        /// Which logo (nil: the first).
        var logoID: UUID?
        var referenceWidth = 1920
        var referenceHeight = 1080
        var anchor = Anchor.topRight
        var x = 60.0
        var y = 60.0
        var width = 200.0
        /// Pixels the logo may be off (0: exactly).
        var tolerance = 0.0
        /// Percent its width may be off.
        var scaleTolerance = 1.0

        var aspect: Double { Double(referenceWidth) / Double(max(referenceHeight, 1)) }

        /// The logo's rectangle (top left origin) in a picture of `size`, for a logo `aspect` wide ÷ high.
        func rect(in size: CGSize, logoAspect: Double) -> CGRect {
            let k = size.width / CGFloat(max(referenceWidth, 1))
            let w = width * k, h = w / max(logoAspect, 0.01), px = x * k, py = y * k
            switch anchor {
            case .topLeft: return CGRect(x: px, y: py, width: w, height: h)
            case .topRight: return CGRect(x: size.width - px - w, y: py, width: w, height: h)
            case .bottomLeft: return CGRect(x: px, y: size.height - py - h, width: w, height: h)
            case .bottomRight: return CGRect(x: size.width - px - w, y: size.height - py - h, width: w, height: h)
            case .centre: return CGRect(x: size.width / 2 + px - w / 2, y: size.height / 2 + py - h / 2, width: w, height: h)
            }
        }

        /// The x and y a logo at `rect` has from this placement's anchor, in reference pixels.
        func offsets(of rect: CGRect, in size: CGSize) -> (x: Double, y: Double) {
            let k = Double(max(referenceWidth, 1)) / size.width
            switch anchor {
            case .topLeft: return (rect.minX * k, rect.minY * k)
            case .topRight: return ((size.width - rect.maxX) * k, rect.minY * k)
            case .bottomLeft: return (rect.minX * k, (size.height - rect.maxY) * k)
            case .bottomRight: return ((size.width - rect.maxX) * k, (size.height - rect.maxY) * k)
            case .centre: return ((rect.midX - size.width / 2) * k, (rect.midY - size.height / 2) * k)
            }
        }
    }

    /// When the logo must be on screen.
    struct Timing: Codable, Hashable {
        enum Mode: String, Codable, CaseIterable, Identifiable {
            case always, endCard, ranges
            var id: String { rawValue }
            var label: String {
                switch self {
                case .always: String(localized: "Always")
                case .endCard: String(localized: "End card")
                case .ranges: String(localized: "At times")
                }
            }
        }
        var mode = Mode.always
        /// The end card's length (the last seconds).
        var endCard = 3.0
        var ranges: [Span] = []
        /// Seconds at the start the logo must not show (0: no rule).
        var notInFirst = 0.0

        func required(at time: Double, duration: Double) -> Bool {
            switch mode {
            case .always: time >= notInFirst
            case .endCard: time >= duration - endCard - 0.001
            case .ranges: ranges.contains { time >= $0.start && time <= $0.end }
            }
        }

        func forbidden(at time: Double) -> Bool { time < notInFirst }
    }

    struct Span: Codable, Hashable {
        var start: Double
        var end: Double
    }

    struct ClearSpace: Codable, Hashable {
        /// Around the logo, where nothing else may be (0: no rule).
        var amount = 0.0
        /// Percent of the logo's width, else pixels at the reference size.
        var percent = false

        func pixels(logoWidth: Double, scale: Double) -> Double { percent ? amount / 100 * logoWidth : amount * scale }
    }

    struct Swatch: Codable, Hashable, Identifiable {
        var id = UUID()
        /// "#E4002B"; nil for colours kept as text only (Pantone, CMYK).
        var hex: String?
        /// "Pantone 186 C", "CMYK 0 100 80 5", or a name.
        var name = ""
    }

    struct RequiredText: Codable, Hashable, Identifiable {
        enum When: String, Codable, CaseIterable, Identifiable {
            case anytime, endCard, always
            var id: String { rawValue }
            var label: String {
                switch self {
                case .anytime: String(localized: "At some point")
                case .endCard: String(localized: "In the end card")
                case .always: String(localized: "All the time")
                }
            }
        }
        enum Area: String, Codable, CaseIterable, Identifiable {
            case anywhere, top, bottom
            var id: String { rawValue }
            var label: String {
                switch self {
                case .anywhere: String(localized: "Anywhere")
                case .top: String(localized: "Top half")
                case .bottom: String(localized: "Bottom half")
                }
            }
        }
        var id = UUID()
        var text: String
        var when = When.anytime
        var area = Area.anywhere
    }

    init(name: String) { self.name = name }

    func logo(for placement: Placement) -> Logo? {
        logos.first { $0.id == placement.logoID } ?? logos.first
    }

    /// The placement for a picture this size: the same shape (within 1 %), nearest in size.
    func placement(for size: CGSize) -> Placement? {
        let aspect = size.width / max(size.height, 1)
        return placements.filter { abs($0.aspect - aspect) / aspect < 0.01 }
            .min { abs(Double($0.referenceWidth) - size.width) < abs(Double($1.referenceWidth) - size.width) }
    }

    // MARK: - Colours

    /// "#E4002B" or "E4002B" → 0…1 sRGB.
    static func rgb(hex: String) -> SIMD3<Double>? {
        let digits = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return SIMD3(Double(value >> 16 & 0xFF), Double(value >> 8 & 0xFF), Double(value & 0xFF)) / 255
    }

    static func hex(_ rgb: SIMD3<Double>) -> String {
        let c = (rgb.clamped(lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: 1)) * 255).rounded(.toNearestOrEven)
        return String(format: "#%02X%02X%02X", Int(c.x), Int(c.y), Int(c.z))
    }

    /// CIE L*a*b* (D65) of an sRGB colour.
    static func lab(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let r = linear(rgb.x), g = linear(rgb.y), b = linear(rgb.z)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
        return SIMD3(116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    /// shortcut: CIE76 ΔE (plain distance in Lab); switch to CIEDE2000 if tolerances from brand books disagree with it.
    static func deltaE(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let d = lab(a) - lab(b)
        return (d * d).sum().squareRoot()
    }

    // MARK: - Logo pictures

    /// The logo as a picture, trimmed to what's drawn (transparent edges cut off), at least
    /// `width` pixels wide for vector files. PNG/JPEG/TIFF as they are; SVG and PDF drawn.
    static func image(of logo: Logo, width: CGFloat = 1200) -> CGImage? {
        let ext = (logo.fileName as NSString).pathExtension.lowercased()
        var picture: CGImage?
        if ext == "svg" || ext == "pdf" {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("brandlogo-\(UUID().uuidString).\(ext)")
            defer { try? FileManager.default.removeItem(at: temp) }
            guard (try? logo.data.write(to: temp)) != nil else { return nil }
            if let art = VectorArt(contentsOf: temp) {
                let k = width / art.size.width
                picture = draw(CGSize(width: art.size.width * k, height: art.size.height * k)) { context in
                    context.translateBy(x: 0, y: art.size.height * k)
                    context.scaleBy(x: k, y: -k)
                    art.draw(in: context)
                }
            } else if ext == "pdf", let page = CGPDFDocument(temp as CFURL)?.page(at: 1) {
                // Pictures and text inside: the page as the system draws it.
                let box = page.getBoxRect(.cropBox), k = width / max(box.width, 1)
                picture = draw(CGSize(width: box.width * k, height: box.height * k)) { context in
                    context.scaleBy(x: k, y: k)
                    context.translateBy(x: -box.minX, y: -box.minY)
                    context.drawPDFPage(page)
                }
            }
        } else if let source = CGImageSourceCreateWithData(logo.data as CFData, nil) {
            picture = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        return picture.flatMap(trimmed)
    }

    private static func draw(_ size: CGSize, _ body: (CGContext) -> Void) -> CGImage? {
        let w = max(Int(size.width.rounded()), 1), h = max(Int(size.height.rounded()), 1)
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        body(context)
        return context.makeImage()
    }

    /// The picture cut to the pixels that aren't fully transparent.
    static func trimmed(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h { for x in 0..<w where bytes[(y * w + x) * 4 + 3] > 0 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= minX else { return nil }
        return image.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    }
}

/// The saved profiles, one JSON file each.
@MainActor @Observable
final class BrandProfiles {
    static let shared = BrandProfiles()
    private(set) var all: [BrandProfile] = []

    static var folder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/Brand Profiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private init() { reload() }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        all = files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(BrandProfile.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func profile(_ id: UUID?) -> BrandProfile? { all.first { $0.id == id } }

    private static func file(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".json") }

    func save(_ profile: BrandProfile) throws {
        try Self.encoded(profile).write(to: Self.file(profile.id), options: .atomic)
        reload()
    }

    func delete(_ profile: BrandProfile) {
        try? FileManager.default.trashItem(at: Self.file(profile.id), resultingItemURL: nil)
        reload()
    }

    static func encoded(_ profile: BrandProfile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(profile)
    }

    /// A profile file someone sent: saved as a new profile (a copy, if one with its id is here).
    @discardableResult func importFile(_ url: URL) throws -> BrandProfile {
        var profile = try JSONDecoder().decode(BrandProfile.self, from: Data(contentsOf: url))
        if all.contains(where: { $0.id == profile.id }) { profile.id = UUID() }
        try save(profile)
        return profile
    }
}
