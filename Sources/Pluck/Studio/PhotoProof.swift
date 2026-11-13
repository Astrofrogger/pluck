import CoreImage
import CoreImage.CIFilterBuiltins
import ColorSync
import Foundation

/// Soft proofing: the photo on screen as it would look in another colour space, a paper's or a
/// printer's. Only what the loupe shows changes: it is never part of the edit, never saved, and the
/// preview cache keeps the unproofed picture.
///
/// How: the colour conversion (profile, rendering intent, black point compensation) is done by
/// ColorSync on a 33-point colour table, once per setting and off the main thread (about a second
/// for a printer profile). Each frame then only runs that table over the picture on the GPU
/// (CIColorCubeWithColorSpace), so a picture at preview size costs a few milliseconds, like any
/// other tone curve. CIImage's own matchedFromWorkingSpace can't be used: it has no say over the
/// rendering intent, and that is what a proof is about. (Black point compensation is left out: Core
/// Graphics' version of it tints paper white on CMYK profiles, so the relative intent is plain.)
struct PhotoProof: Equatable {
    enum Target: Hashable {
        case srgb, p3, adobe, prophoto
        /// A profile file from the Mac's ColorSync folders.
        case profile(String)
    }
    /// How colours outside the target are brought in (a printer's colours rarely reach a screen's).
    enum Intent: String, CaseIterable { case perceptual, relative }

    var on = false
    var target = Target.srgb
    var intent = Intent.relative
    /// Absolute colorimetric both ways: the paper's white and the ink's black show as they are.
    var paper = false
    /// Mark the colours the target can't hold.
    var gamutWarning = false
    /// Export in the proof profile too (RGB profiles only).
    var useForExport = false

    // MARK: Profiles

    /// An installed profile that can be proofed to.
    struct Installed: Hashable, Identifiable {
        let path: String
        let name: String
        let cmyk: Bool
        var id: String { path }
    }

    /// RGB and CMYK output and monitor profiles in the ColorSync folders, by their description. (Looked up once.)
    static let installed: [Installed] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var found: [Installed] = []
        var seen = Set<String>()
        for folder in ["/System/Library/ColorSync/Profiles", "/Library/ColorSync/Profiles", "/Library/ColorSync/Profiles/Recommended",
                       home + "/Library/ColorSync/Profiles"] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for file in names where file.lowercased().hasSuffix(".icc") || file.lowercased().hasSuffix(".icm") {
                let path = folder + "/" + file
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count > 128,
                      let kind = header(data), kind.rgb || kind.cmyk, kind.output,
                      let profile = ColorSyncProfileCreate(data as CFData, nil)?.takeRetainedValue(),
                      let name = ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() as String?,
                      seen.insert(name).inserted else { continue }
                found.append(Installed(path: path, name: name, cmyk: kind.cmyk))
            }
        }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    /// The profile's class and colour space, from its 128-byte header (printer and monitor profiles,
    /// not the "effect" ones like Sepia Tone).
    private static func header(_ data: Data) -> (output: Bool, rgb: Bool, cmyk: Bool)? {
        func tag(_ at: Int) -> String { String(decoding: data[data.startIndex + at ..< data.startIndex + at + 4], as: UTF8.self) }
        let kind = tag(12), space = tag(16)
        return (kind == "prtr" || kind == "mntr", space == "RGB ", space == "CMYK")
    }

    var title: String {
        switch target {
        case .srgb: "sRGB"
        case .p3: "Display P3"
        case .adobe: "Adobe RGB"
        case .prophoto: "ProPhoto RGB"
        case .profile(let path): Self.installed.first { $0.path == path }?.name ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
    }

    /// Whether a photo can be saved in the target (CMYK files can't come out of the RGB pipeline).
    var canExport: Bool {
        if case .profile(let path) = target { return Self.installed.first { $0.path == path }?.cmyk == false }
        return true
    }

    // MARK: Conversion

    nonisolated(unsafe) private static var spaces: [String: CGColorSpace] = [:]
    nonisolated(unsafe) private static var tables: [String: Data] = [:]
    private static let lock = NSLock()

    var space: CGColorSpace? {
        switch target {
        case .srgb: return CGColorSpace(name: CGColorSpace.sRGB)
        case .p3: return CGColorSpace(name: CGColorSpace.displayP3)
        case .adobe: return CGColorSpace(name: CGColorSpace.adobeRGB1998)
        case .prophoto: return CGColorSpace(name: CGColorSpace.rommrgb)
        case .profile(let path):
            Self.lock.lock(); defer { Self.lock.unlock() }
            if let cached = Self.spaces[path] { return cached }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let made = CGColorSpace(iccData: data as CFData) else { return nil }
            Self.spaces[path] = made
            return made
        }
    }

    /// What decides the colour table (the gamut warning and the switch don't).
    var tableKey: String { "\(target)|\(intent.rawValue)|\(paper)" }

    static let dimension = 33

    /// The table for a setting if it has been made (what each frame uses); never waits.
    func cachedTable() -> Data? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return Self.tables[tableKey]
    }

    /// Makes (or finds) the table: every colour of a 33-point grid over Display P3 (the widest a
    /// screen shows) goes into the target and back, with the chosen intent. Slow: not for the main thread.
    @discardableResult
    func makeTable() -> Data? {
        if let done = cachedTable() { return done }
        guard let target = space, let p3 = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
        let there: CGColorRenderingIntent = paper ? .absoluteColorimetric : (intent == .perceptual ? .perceptual : .relativeColorimetric)
        let back: CGColorRenderingIntent = paper ? .absoluteColorimetric : .relativeColorimetric
        let n = Self.dimension
        let count = n * n * n * 4
        nonisolated(unsafe) let out = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { out.deallocate() }
        // One blue slice per task: the grid is red-fastest, then green, then blue (Core Image's order).
        DispatchQueue.concurrentPerform(iterations: n) { b in
            for g in 0..<n {
                for r in 0..<n {
                    let i = ((b * n + g) * n + r) * 4
                    var rgb: [CGFloat] = [CGFloat(r) / CGFloat(n - 1), CGFloat(g) / CGFloat(n - 1), CGFloat(b) / CGFloat(n - 1)]
                    if let c = CGColor(colorSpace: p3, components: rgb + [1]),
                       let printed = c.converted(to: target, intent: there, options: nil),
                       let shown = printed.converted(to: p3, intent: back, options: nil),
                       let parts = shown.components, parts.count >= 3 {
                        rgb = Array(parts[0..<3])
                    }
                    out[i] = Float(rgb[0]); out[i + 1] = Float(rgb[1]); out[i + 2] = Float(rgb[2]); out[i + 3] = 1
                }
            }
        }
        let data = Data(bytes: out, count: count * MemoryLayout<Float>.size)
        Self.lock.lock(); Self.tables[tableKey] = data; Self.lock.unlock()
        return data
    }

    // MARK: Picture

    /// The colour the gamut warning paints.
    static let warning = CIColor(red: 1, green: 0.1, blue: 0.75)

    /// The picture as it looks in the target (and, with the gamut warning, with the colours the
    /// target can't hold painted over). The picture itself when proofing is off or the table isn't ready yet.
    func apply(_ image: CIImage, gamut: Bool? = nil) -> CIImage {
        guard on, let data = cachedTable() else { return image }
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty else { return image }
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = image
        filter.cubeDimension = Float(Self.dimension)
        filter.cubeData = data
        filter.colorSpace = CGColorSpace(name: CGColorSpace.displayP3)
        guard let proofed = filter.outputImage?.cropped(to: extent) else { return image }
        guard gamut ?? gamutWarning else { return proofed }
        // Out of gamut = the round trip moved the colour by more than about 10/255 (judged in Display P3's
        // curve, as the screen shows it, so dark colours count as much as light ones, and P3's colours past sRGB stay).
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        func encoded(_ i: CIImage) -> CIImage { i.matchedFromWorkingSpace(to: p3) ?? i }
        let moved = encoded(proofed).applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: encoded(image)])
            .applyingFilter("CIMaximumComponent")
            .applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.04])
        let flat = CIImage(color: Self.warning).cropped(to: extent)
        return flat.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: proofed, kCIInputMaskImageKey: moved]).cropped(to: extent)
    }
}
