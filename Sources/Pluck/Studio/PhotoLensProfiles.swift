import CoreImage
import Foundation
import ImageIO
import SwiftUI

/// Lens profiles from the Lensfun database (CC BY-SA 3.0, lensfun.github.io): an optional download (about 5 MB, pinned to
/// one revision), read on this Mac. A photo's lens (from its EXIF) is looked up and the profile at its focal length and
/// aperture is fitted to the Lens section's own sliders (Distortion, Vignetting, Midpoint, Red/Cyan, Blue/Yellow), which the
/// photographer can then fine-tune. Lenses Apple's RAW decoder already corrects don't need it (the panel says so).
@MainActor
@Observable
final class PhotoLensProfiles {
    static let shared = PhotoLensProfiles()

    enum State: Equatable { case notInstalled, downloading(Double), ready, failed(String) }
    private(set) var state = State.notInstalled

    static let downloadMB = 5
    private static let revision = "52cf1a7b0e82e07e0ecaa3391ee5106a6dd1ee54"
    private static let files = ["6x6", "actioncams", "compact-canon", "compact-casio", "compact-fujifilm", "compact-kodak", "compact-konica-minolta",
                                "compact-leica", "compact-nikon", "compact-olympus", "compact-panasonic", "compact-pentax", "compact-ricoh", "compact-samsung",
                                "compact-sigma", "compact-sony", "contax", "generic", "mil-canon", "mil-fujifilm", "mil-hasselblad", "mil-leica", "mil-nikon",
                                "mil-olympus", "mil-panasonic", "mil-pentax", "mil-samsung", "mil-samyang", "mil-sigma", "mil-sony", "mil-tamron", "mil-tokina",
                                "mil-zeiss", "misc", "om-system", "rf-leica", "slr-canon", "slr-hasselblad", "slr-konica-minolta", "slr-leica", "slr-nikon",
                                "slr-olympus", "slr-panasonic", "slr-pentax", "slr-ricoh", "slr-samsung", "slr-samyang", "slr-schneider", "slr-sigma",
                                "slr-soligor", "slr-sony", "slr-tamron", "slr-tokina", "slr-ussr", "slr-vivitar", "slr-zeiss"]

    nonisolated private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck/Models/Lensfun", isDirectory: true)
    }

    private init() { if Self.isReady { state = .ready } }

    nonisolated static var isReady: Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent("slr-canon.xml").path) }

    func install() {
        if case .downloading = state { return }
        state = .downloading(0)
        Task {
            do {
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-lensfun-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: temp) }
                for (i, name) in Self.files.enumerated() {
                    let url = URL(string: "https://raw.githubusercontent.com/lensfun/lensfun/\(Self.revision)/data/db/\(name).xml")!
                    let (download, response) = try await URLSession.shared.download(from: url)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw NSError(domain: "Pluck", code: 33, userInfo: [NSLocalizedDescriptionKey: String(localized: "The download didn’t check out. Try again.")])
                    }
                    try FileManager.default.moveItem(at: download, to: temp.appendingPathComponent(name + ".xml"))
                    state = .downloading(Double(i + 1) / Double(Self.files.count))
                }
                try? FileManager.default.removeItem(at: Self.folder)
                try FileManager.default.createDirectory(at: Self.folder.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: temp, to: Self.folder)
                Self.lock.withLock { Self.loaded = nil }
                state = .ready
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - The database

    struct Lens {
        var maker = "", models: [String] = [], crop = 1.0
        var distortion: [(focal: Double, model: String, a: Double, b: Double, c: Double)] = []
        var tca: [(focal: Double, model: String, vr: Double, vb: Double, cr: Double, cb: Double, br: Double, bb: Double)] = []
        var vignetting: [(focal: Double, aperture: Double, distance: Double, k1: Double, k2: Double, k3: Double)] = []
    }

    nonisolated(unsafe) private static var loaded: [Lens]?
    nonisolated private static let lock = NSLock()

    nonisolated static func lenses() -> [Lens] {
        if let known = lock.withLock({ loaded }) { return known }
        var all: [Lens] = []
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "xml" {
            let reader = DatabaseReader()
            let parser = XMLParser(contentsOf: file)
            parser?.delegate = reader
            parser?.parse()
            all += reader.lenses
        }
        lock.withLock { loaded = all }
        return all
    }

    /// Reads the database's <lens> entries (their names, crop factor and calibrations).
    private final class DatabaseReader: NSObject, XMLParserDelegate {
        var lenses: [Lens] = []
        private var lens: Lens?, text = "", inCalibration = false, element = ""
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            text = ""; element = name
            func d(_ k: String, _ fallback: Double = 0) -> Double { Double(a[k] ?? "") ?? fallback }
            switch name {
            case "lens": lens = Lens()
            case "model" where a["lang"] != nil: element = "ignore"
            case "distortion": lens?.distortion.append((d("focal"), a["model"] ?? "", d("a", d("k1")), d("b", d("k2")), d("c")))
            case "tca": lens?.tca.append((d("focal"), a["model"] ?? "", d("vr", d("kr", 1)), d("vb", d("kb", 1)), d("cr"), d("cb"), d("br"), d("bb")))
            case "vignetting": lens?.vignetting.append((d("focal"), d("aperture"), d("distance", 1000), d("k1"), d("k2"), d("k3")))
            default: break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch (name, element) {
            case ("maker", _): if lens?.maker.isEmpty == true { lens?.maker = value }
            case ("model", "model"): lens?.models.append(value)
            case ("cropfactor", _): lens?.crop = Double(value) ?? 1
            case ("lens", _): if let lens, !lens.models.isEmpty { lenses.append(lens) }; lens = nil
            default: break
            }
            element = ""
        }
    }

    // MARK: - Finding a photo's lens

    /// What a photo says about its lens and shot.
    struct Shot { var lens: String; var focal: Double; var aperture: Double; var crop: Double? }

    nonisolated static func shot(_ path: String) -> Shot? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: PhotoCatalog.file(of: path)) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] else { return nil }
        let aux = props[kCGImagePropertyExifAuxDictionary as String] as? [String: Any]
        guard let lens = (exif[kCGImagePropertyExifLensModel as String] as? String) ?? (aux?[kCGImagePropertyExifAuxLensModel as String] as? String),
              !lens.isEmpty, let focal = exif[kCGImagePropertyExifFocalLength as String] as? Double, focal > 0 else { return nil }
        let f35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Double
        return Shot(lens: lens, focal: focal, aperture: exif[kCGImagePropertyExifFNumber as String] as? Double ?? 8,
                    crop: f35.flatMap { $0 > 0 ? $0 / focal : nil })
    }

    /// Words a lens name is matched by: lower case, "f/2.8" as "f2.8", makers' words dropped.
    nonisolated static func words(_ name: String) -> Set<String> {
        // ("EF24-70mm f/2.8L" and "XF35mmF1.4" as "ef 24-70mm 2.8 l", "xf 35mm 1.4": letters and numbers apart, "mm" kept
        // on its number, an aperture's "f" dropped.)
        var lowered = name.lowercased().replacingOccurrences(of: "ƒ", with: "f").replacingOccurrences(of: "f/", with: " f ")
        lowered = lowered.replacingOccurrences(of: #"(\d)mm"#, with: "$1mm ", options: .regularExpression)
        lowered = lowered.replacingOccurrences(of: #"([a-z])(\d)"#, with: "$1 $2", options: .regularExpression)
        lowered = lowered.replacingOccurrences(of: #"(\d)([a-z])"#, with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: #"(\d) mm"#, with: "$1mm", options: .regularExpression)
        let drop: Set<String> = ["lens", "the", "sony", "canon", "nikon", "nikkor", "fujifilm", "fujinon", "sigma", "tamron", "zeiss", "olympus", "panasonic",
                                 "lumix", "leica", "samyang", "tokina", "pentax", "ricoh", "smc", "ef", "rf", "z", "xf", "xc", "f"]
        return Set(lowered.split { !$0.isLetter && !$0.isNumber && $0 != "." && $0 != "-" }.map(String.init)).subtracting(drop)
    }

    /// The database lens this photo's lens is: the most words in common, its focal lengths among them; nil if none is close.
    nonisolated static func find(_ name: String) -> Lens? {
        let wanted = words(name)
        let focals = wanted.filter { $0.hasSuffix("mm") || $0.contains("-") && $0.first?.isNumber == true }
        var best: (score: Double, lens: Lens)?
        for lens in lenses() {
            for model in lens.models {
                let have = words(model)
                // The focal length (or range) must agree.
                guard focals.isEmpty || !focals.isDisjoint(with: have) else { continue }
                let shared = Double(wanted.intersection(have).count), score = shared / Double(max(wanted.union(have).count, 1))
                if shared >= 2, score > (best?.score ?? 0.45) { best = (score, lens) }
            }
        }
        return best?.lens
    }

    // MARK: - Fitting to the sliders

    /// The Lens section's sliders that come nearest this profile for this shot (`width` × `height` the photo as shown).
    nonisolated static func fitted(_ lens: Lens, shot: Shot, width: Double, height: Double) -> PhotoLens {
        var result = PhotoLens()
        let halfDiagonal = hypot(width, height) / 2, halfShort = min(width, height) / 2
        // The database's radius: 1 at half the calibration frame's shorter side; the photo's frame by the crop factors.
        let camCrop = shot.crop ?? lens.crop
        let toProfile = halfDiagonal / halfShort * lens.crop / camCrop
        let samples = (1...40).map { Double($0) / 40 }

        // Distortion: where each place is read from (r · (1 + k1 r² + k2 r⁴) with k2 = k1/5), least squares on the profile's.
        if let d = interpolated(lens.distortion.map { ($0.focal, [$0.a, $0.b, $0.c]) }, at: shot.focal),
           let model = lens.distortion.min(by: { abs($0.focal - shot.focal) < abs($1.focal - shot.focal) })?.model {
            func profile(_ ru: Double) -> Double {
                switch model {
                case "ptlens": return ru * (d[0] * ru * ru * ru + d[1] * ru * ru + d[2] * ru + 1 - d[0] - d[1] - d[2])
                case "poly3": return ru * (1 - d[0] + d[0] * ru * ru)
                case "poly5": return ru * (1 + d[0] * ru * ru + d[1] * ru * ru * ru * ru)
                default: return ru
                }
            }
            // The profile's shape, its overall size left free (Pluck scales to fill the frame anyway): target / r ≈ c0 + c1 r² + c2 r⁴
            // by least squares, then k1 = c1 / c0, k2 = c2 / c0.
            var m = [[Double]](repeating: [0, 0, 0], count: 3), v = [0.0, 0.0, 0.0]
            for r in samples {
                let t = profile(r * toProfile) / toProfile / r, g = [1, r * r, r * r * r * r]
                for i in 0..<3 { v[i] += g[i] * t; for j in 0..<3 { m[i][j] += g[i] * g[j] } }
            }
            if let c = solve3(m, v), c[0] > 0 {
                // (Distortion is k1 as the slider has it, unrounded; k2 the profile's own.)
                result.distortion = min(max(-(c[1] / c[0]) / 0.2 * 100, -100), 100)
                result.profileK2 = c[2] / c[0]
            }
        }

        // Vignetting: the profile's fall-off (radius 1 at the corner) undone: 2^(stops · r^power).
        let near = lens.vignetting.filter { abs($0.focal - shot.focal) == (lens.vignetting.map { abs($0.focal - shot.focal) }.min() ?? 0) }
        if let v = near.min(by: { abs(log2($0.aperture / shot.aperture)) - $0.distance * 1e-6 < abs(log2($1.aperture / shot.aperture)) - $1.distance * 1e-6 }) {
            func stops(_ r: Double) -> Double {
                let fall = 1 + v.k1 * r * r + v.k2 * pow(r, 4) + v.k3 * pow(r, 6)
                return -log2(max(fall, 0.05))
            }
            let corner = stops(1)
            var bestPower = 2.0, bestError = Double.infinity
            for power in stride(from: 1.0, through: 6.0, by: 0.25) {
                let error = samples.reduce(0.0) { $0 + pow(corner * pow($1, power) - stops($1), 2) }
                if error < bestError { bestError = error; bestPower = power }
            }
            result.vignetting = min(max(corner / 2 * 100, -100), 100).rounded()
            result.midpoint = min(max((bestPower - 1) * 20, 0), 100).rounded()
        }

        // Colour fringes: how much larger red and blue are read, on average across the frame.
        if let t = interpolated(lens.tca.map { ($0.focal, [$0.vr, $0.vb, $0.cr, $0.cb, $0.br, $0.bb]) }, at: shot.focal) {
            func scale(_ v: Double, _ c: Double, _ b: Double) -> Double {
                samples.reduce(0.0) { sum, r in let ru = r * toProfile; return sum + (b * ru * ru + c * ru + v - 1) } / Double(samples.count)
            }
            result.redCyan = min(max(-scale(t[0], t[2], t[4]) / PhotoLens.fringeReach * 100, -100), 100).rounded()
            result.blueYellow = min(max(-scale(t[1], t[3], t[5]) / PhotoLens.fringeReach * 100, -100), 100).rounded()
        }
        return result
    }

    /// Three equations, three unknowns (Cramer's rule); nil when they don't decide them.
    nonisolated static func solve3(_ m: [[Double]], _ v: [Double]) -> [Double]? {
        func det(_ a: [[Double]]) -> Double {
            a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0]) + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
        }
        let d = det(m)
        guard abs(d) > 1e-15 else { return nil }
        return (0..<3).map { col in det(m.enumerated().map { i, row in row.enumerated().map { j, x in j == col ? v[i] : x } }) / d }
    }

    /// Values at a focal length, read linearly between the nearest calibrations either side.
    nonisolated static func interpolated(_ points: [(Double, [Double])], at focal: Double) -> [Double]? {
        let sorted = points.sorted { $0.0 < $1.0 }
        guard let first = sorted.first, let last = sorted.last else { return nil }
        if focal <= first.0 { return first.1 }
        if focal >= last.0 { return last.1 }
        for (a, b) in zip(sorted, sorted.dropFirst()) where focal >= a.0 && focal <= b.0 {
            let t = b.0 > a.0 ? (focal - a.0) / (b.0 - a.0) : 0
            return zip(a.1, b.1).map { $0 + ($1 - $0) * t }
        }
        return last.1
    }

    /// Whether Apple's RAW decoder corrects this photo's lens itself.
    nonisolated static func appleCorrects(_ path: String) -> Bool {
        guard PhotoRender.isRaw(path), let raw = CIRAWFilter(imageURL: URL(fileURLWithPath: PhotoCatalog.file(of: path))) else { return false }
        return raw.isLensCorrectionSupported
    }
}

/// In the Lens section: the switch for this photo's lens correction. A lens Apple corrects: Apple's correction, on or off. Another
/// with a Lensfun profile: the profile, which sets the sliders (off clears what it set). Or the download, or why there's none.
struct PhotoLensProfileRow: View {
    let path: String
    let lens: PhotoLens
    let set: ((inout PhotoLens) -> Void) -> Void
    @State private var profiles = PhotoLensProfiles.shared
    @State private var found: (name: String, lens: PhotoLens)?
    @State private var apple = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if apple {
                StudioSwitchRow(title: "Lens Correction", isOn: Binding(get: { lens.appleOff != true }, set: { on in set { $0.appleOff = on ? nil : true } }))
                    .help("Apple's own correction for this lens (distortion and vignetting)")
            }
            switch profiles.state {
            case .notInstalled:
                if !apple {
                    Text("Lens profiles for lenses Apple doesn’t correct, from the Lensfun database.").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                    Button("Get Lens Profiles (\(PhotoLensProfiles.downloadMB) MB)", systemImage: "arrow.down") { profiles.install() }.buttonStyle(StudioFlatButtonStyle())
                }
            case .downloading(let share):
                ProgressView(value: share).controlSize(.small).tint(Design.Brand.pink)
            case .failed(let problem):
                ProblemLabel(text: problem)
                Button("Try Again") { profiles.install() }.buttonStyle(StudioFlatButtonStyle())
            case .ready:
                if let found {
                    StudioSwitchRow(title: "Lens Profile", isOn: Binding(get: { lens.profile != nil }, set: { on in
                        set { l in
                            if on {
                                l.distortion = found.lens.distortion; l.vignetting = found.lens.vignetting; l.midpoint = found.lens.midpoint
                                l.redCyan = found.lens.redCyan; l.blueYellow = found.lens.blueYellow; l.profileK2 = found.lens.profileK2
                                l.profile = found.name
                            } else {
                                l.distortion = 0; l.vignetting = 0; l.midpoint = 50; l.redCyan = 0; l.blueYellow = 0; l.profileK2 = nil; l.profile = nil
                            }
                        }
                    }))
                    Text(verbatim: found.name).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                }
                if let note { Text(note).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet) }
                if found != nil || !apple { Text("Profiles: Lensfun, CC BY-SA 3.0").font(Design.Studio.hint).foregroundStyle(Design.Studio.textFaint) }
            }
        }
        .padding(.horizontal, Design.Sidebar.rowPadding)
        .task(id: "\(path)|\(profiles.state == .ready)") {
            found = nil; note = nil
            let path = path
            apple = await Task.detached { PhotoLensProfiles.appleCorrects(path) }.value
            // (A lens Apple corrects gets no profile: on top of Apple's it corrected twice and washed the photo out.)
            guard profiles.state == .ready, !apple else { return }
            let result = await Task.detached(priority: .userInitiated) { () -> (name: String, lens: PhotoLens)?? in
                guard let shot = PhotoLensProfiles.shot(path) else { return .some(nil) }
                guard let lens = PhotoLensProfiles.find(shot.lens), let size = CullCache.pixelSize(of: path) else { return nil }
                return (lens.models.first ?? shot.lens, PhotoLensProfiles.fitted(lens, shot: shot, width: size.width, height: size.height))
            }.value
            switch result {
            case .some(.some(let hit)): found = hit
            case .some(.none): note = String(localized: "This photo doesn’t say which lens took it.")
            case .none: note = String(localized: "No profile for this lens.")
            }
        }
    }
}
