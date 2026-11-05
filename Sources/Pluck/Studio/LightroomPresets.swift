import Foundation

/// Lightroom's develop settings (the `crs:` namespace), from a preset (`.xmp`, or the older
/// `.lrtemplate`) or a photo's sidecar, as Pluck's own. The engines differ, so a look comes close
/// rather than the same; what Pluck has no setting for is listed, not guessed.
enum LightroomPresets {
    /// Where Lightroom and Camera Raw keep their presets.
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Adobe/CameraRaw/Settings", isDirectory: true)
    }

    /// Settings ▸ Photo ▸ "Use Lightroom edits": a photo Pluck hasn't edited starts from them.
    static let useEditsKey = "photoUseLightroomEdits"

    struct Unreadable: LocalizedError {
        let file: String
        var errorDescription: String? { String(localized: "“\(file)” isn’t a Lightroom preset.") }
    }

    // MARK: - Reading

    /// A preset's settings by their `crs:` name (without the prefix). Lists (tone curves) come as
    /// "x, y" points joined with ";".
    static func read(_ url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        let found = url.pathExtension.lowercased() == "lrtemplate"
            ? settings(fromTemplate: String(decoding: data, as: UTF8.self)) : settings(fromXMP: data)
        guard !found.isEmpty else { throw Unreadable(file: url.lastPathComponent) }
        return found
    }

    /// The `crs:` settings in an XMP packet: attributes of its descriptions, and elements holding
    /// a value or a list.
    static func settings(fromXMP data: Data) -> [String: String] {
        let reader = XMPReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = reader
        parser.parse()
        return reader.found
    }

    private final class XMPReader: NSObject, XMLParserDelegate {
        var found: [String: String] = [:]
        /// The setting being read (its key) and its element.
        private var open: String?
        private var element = ""
        /// Inside the profile (crs:Look, and its crs:Parameters): its settings are kept apart from the
        /// preset's, as "Look.Name", "Look.Parameters.ToneCurvePV2012"…
        private var look: [String] = []
        private var items: [String] = []
        private var text = ""
        /// A list of one text in several languages (a name): only the first (x-default) counts.
        private var alternatives = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            // A colour table (a creative profile's), wherever it's written: by its digest.
            for (key, value) in attributes where key.hasPrefix("crs:Table_") { found[String(key.dropFirst(4))] = value }
            // Only the settings themselves: what's inside one of them isn't a setting.
            guard open == nil else {
                if name == "rdf:Alt" { alternatives = true }
                text = ""
                return
            }
            let scope = look.map { $0 + "." }.joined()
            for (key, value) in attributes where key.hasPrefix("crs:") && !key.hasPrefix("crs:Table_") { found[scope + String(key.dropFirst(4))] = value }
            if name == "crs:Look" && look.isEmpty || name == "crs:Parameters" && look == ["Look"] {
                look.append(String(name.dropFirst(4)))
            } else if name.hasPrefix("crs:") {
                open = scope + String(name.dropFirst(4))
                element = name
                items = []
                alternatives = false
            }
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard let key = open else {
                if let last = look.last, name == "crs:" + last { look.removeLast() }
                return
            }
            if name == "rdf:li" {
                items.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
            } else if name == element {
                let value = items.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines)
                    : alternatives ? items[0] : items.joined(separator: ";")
                if !value.isEmpty { found[key] = value }
                open = nil
                return
            }
            text = ""
        }
    }

    /// The settings in an `.lrtemplate` (a Lua table): `key = value` pairs inside `settings = { … }`.
    /// A list of numbers (a curve: x, y, x, y…) comes as "x, y" points joined with ";".
    static func settings(fromTemplate text: String) -> [String: String] {
        guard let start = text.range(of: #"settings\s*=\s*\{"#, options: .regularExpression) else { return [:] }
        var tokens = Tokens(text[start.upperBound...])
        var found: [String: String] = [:]
        while let token = tokens.next(), token != "}" {
            guard token != ",", tokens.next() == "=" else { continue }
            let key = token.trimmingCharacters(in: CharacterSet(charactersIn: "[]\""))
            guard let value = tokens.next() else { break }
            if value == "{" {
                var numbers: [String] = []
                var depth = 1
                while depth > 0, let inner = tokens.next() {
                    if inner == "{" { depth += 1 } else if inner == "}" { depth -= 1 } else if inner != "," { numbers.append(inner) }
                }
                let pairs = stride(from: 0, to: numbers.count - 1, by: 2).map { "\(numbers[$0]), \(numbers[$0 + 1])" }
                if !pairs.isEmpty { found[key] = pairs.joined(separator: ";") }
            } else {
                found[key] = value.hasPrefix("\"") ? String(value.dropFirst().dropLast()) : value
            }
        }
        return found
    }

    /// Lua's pieces: names, numbers, strings (quotes kept), and single characters.
    private struct Tokens {
        var rest: Substring
        init(_ text: Substring) { rest = text }

        mutating func next() -> String? {
            while let first = rest.first {
                if first.isWhitespace { rest.removeFirst(); continue }
                // Comments to the end of the line.
                if rest.hasPrefix("--") { rest = rest.drop { $0 != "\n" }; continue }
                break
            }
            guard let first = rest.first else { return nil }
            if first == "\"" {
                var index = rest.index(after: rest.startIndex)
                while index < rest.endIndex, rest[index] != "\"" {
                    if rest[index] == "\\" { index = rest.index(after: index) }
                    if index < rest.endIndex { index = rest.index(after: index) }
                }
                let end = index < rest.endIndex ? rest.index(after: index) : index
                defer { rest = rest[end...] }
                return String(rest[..<end])
            }
            if "{}=,[]".contains(first) {
                rest.removeFirst()
                return String(first)
            }
            let word = rest.prefix { !$0.isWhitespace && !"{}=,[]\"".contains($0) }
            rest = rest.dropFirst(word.count)
            return String(word)
        }
    }

    // MARK: - As Pluck's settings

    /// Lightroom's settings on top of `base`, and the names of those Pluck has nothing for (only
    /// those set to something). `asShotKelvin`: a photo's own edit (its sidecar), whose white
    /// balance is measured from the photo's; without it, a preset's.
    static func adjustments(_ crs: [String: String], base: PhotoAdjustments = .init(), asShotKelvin: Double? = nil) -> (PhotoAdjustments, unmapped: [String]) {
        var a = base
        var used: Set<String> = []
        func number(_ key: String) -> Double? {
            guard let text = crs[key] else { return nil }
            used.insert(key)
            return Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "+", with: ""))
        }
        func set(_ key: String, _ path: WritableKeyPath<PhotoAdjustments, Double>, scale: Double = 1, range: ClosedRange<Double> = -100...100) {
            if let value = number(key) { a[keyPath: path] = min(max(value * scale, range.lowerBound), range.upperBound) }
        }
        set("Exposure2012", \.exposure, range: -5...5)
        set("Contrast2012", \.contrast)
        set("Highlights2012", \.highlights)
        set("Shadows2012", \.shadows)
        set("Whites2012", \.whites)
        set("Blacks2012", \.blacks)
        set("Vibrance", \.vibrance)
        set("Saturation", \.saturation)
        set("Clarity2012", \.clarity)
        set("Texture", \.texture)
        set("Dehaze", \.dehaze)
        set("PostCropVignetteAmount", \.vignette)
        // The vignette's shape, only with a vignette (Lightroom writes its defaults into every edit).
        // Roundness as Lightroom's (0 the frame's shape, 100 a circle); squarer than the frame (below 0) as the frame's.
        let shape = [("PostCropVignetteMidpoint", \PhotoAdjustments.vignetteMidpoint), ("PostCropVignetteFeather", \.vignetteFeather),
                     ("PostCropVignetteRoundness", \.vignetteRoundness), ("PostCropVignetteHighlights", \.vignetteHighlights)]
            .map { ($0.1, number($0.0)) }
        let style = number("PostCropVignetteStyle")
        if a.vignette != 0 {
            for (path, value) in shape { if let value { a[keyPath: path] = min(max(value, 0), 100) } }
            if let style { a.vignetteStyle = min(max(Int(style), 1), 3) }
        }
        // Grain (for a photo without film), only with an amount.
        let grain = [("GrainAmount", \PhotoAdjustments.grain), ("GrainSize", \.grainSize), ("GrainFrequency", \.grainRoughness)].map { ($0.1, number($0.0)) }
        if (grain[0].1 ?? 0) > 0 { for (path, value) in grain { if let value { a[keyPath: path] = min(max(value, 0), 100) } } }
        // Process 2010 and older: sliders that meant other things, the nearest of today's. Used only when the
        // preset has none of today's (a later one can still carry them, outdated).
        let legacy = ["Exposure", "Contrast", "Brightness", "FillLight", "HighlightRecovery", "Clarity", "Shadows"]
            .reduce(into: [String: Double]()) { $0[$1] = number($1) }
        let version = Double(crs["ProcessVersion"] ?? "") ?? 0
        if version < 10, !["Exposure2012", "Contrast2012", "Highlights2012", "Shadows2012", "Clarity2012"].contains(where: { crs[$0] != nil }) {
            func put(_ path: WritableKeyPath<PhotoAdjustments, Double>, _ value: Double?, range: ClosedRange<Double> = -100...100) {
                if let value { a[keyPath: path] = min(max(value, range.lowerBound), range.upperBound) }
            }
            // Exposure: the same stops.
            put(\.exposure, legacy["Exposure"], range: -5...5)
            // Brightness (0…150, 50 neutral) lifted the midtones: added to the exposure, half a stop per 50.
            put(\.exposure, legacy["Brightness"].map { a.exposure + ($0 - 50) / 100 }, range: -5...5)
            // Contrast (-50…100) was 25 when untouched.
            put(\.contrast, legacy["Contrast"].map { $0 - 25 })
            // Fill Light (0…100) opened the shadows: Shadows.
            put(\.shadows, legacy["FillLight"])
            // Recovery (0…100) brought the highlights back: Highlights down.
            put(\.highlights, legacy["HighlightRecovery"].map { -$0 })
            // Clarity: the same slider (2010's was a little gentler).
            put(\.clarity, legacy["Clarity"])
            // Blacks (2010's "Shadows", 0…100, 5 when untouched) clipped more of the dark: Blacks down.
            put(\.blacks, legacy["Shadows"].map { -($0 - 5) })
        }
        // Calibration.
        set("RedHue", \.calibration.redHue); set("RedSaturation", \.calibration.redSaturation)
        set("GreenHue", \.calibration.greenHue); set("GreenSaturation", \.calibration.greenSaturation)
        set("BlueHue", \.calibration.blueHue); set("BlueSaturation", \.calibration.blueSaturation)
        set("ShadowTint", \.calibration.shadowTint)
        // Lightroom sharpens every RAW by 40 unless told not to: in a photo's own edit, that's no edit.
        if asShotKelvin != nil, number("Sharpness") == 40 { } else { set("Sharpness", \.sharpen, scale: 1 / 1.5, range: 0...100) }
        set("LuminanceSmoothing", \.noise, range: 0...100)
        set("ColorNoiseReduction", \.colorNoise, range: 0...100)
        // White balance: the slider as it is on JPEGs and the like. On RAW a Kelvin value, only when
        // set by hand ("Custom"; As Shot and Auto are the photo's own): as stops from the photo's
        // as-shot light, or from daylight for a preset (Pluck's scale: each 100 is 1.3 stops).
        let balance = crs["WhiteBalance"]?.lowercased() ?? ""
        _ = number("WhiteBalance")
        if let value = number("IncrementalTemperature") {
            a.temperature = min(max(value, -100), 100)
        } else if let kelvin = number("Temperature"), kelvin > 0, balance == "custom" {
            a.temperature = min(max(log2(kelvin / (asShotKelvin ?? 5500)) / 1.3 * 100, -100), 100)
        }
        if let value = number("IncrementalTint") {
            a.tint = min(max(value, -100), 100)
        } else if let value = number("Tint"), balance == "custom" {
            a.tint = min(max(value / 1.5, -100), 100)
        }
        // The colour mixer's eight bands, as Lightroom's.
        let bands = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]
        for (index, band) in bands.enumerated() {
            if let value = number("HueAdjustment" + band) { a.mixer.hue[index] = min(max(value, -100), 100) }
            if let value = number("SaturationAdjustment" + band) { a.mixer.saturation[index] = min(max(value, -100), 100) }
            if let value = number("LuminanceAdjustment" + band) { a.mixer.luminance[index] = min(max(value, -100), 100) }
        }
        // Tone curves ("x, y" from 0 to 255).
        let curves: [(String, WritableKeyPath<PhotoCurves, [CurvePoint]>)] = [("ToneCurvePV2012", \.master), ("ToneCurvePV2012Red", \.red),
                                                                              ("ToneCurvePV2012Green", \.green), ("ToneCurvePV2012Blue", \.blue)]
        for (key, path) in curves {
            guard let text = crs[key] else { continue }
            used.insert(key)
            let points = text.split(separator: ";").compactMap { pair -> CurvePoint? in
                let parts = pair.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard parts.count == 2 else { return nil }
                return CurvePoint(x: min(max(parts[0] / 255, 0), 1), y: min(max(parts[1] / 255, 0), 1))
            }.sorted { $0.x < $1.x }
            if points.count >= 2 { a.curves[keyPath: path] = points }
        }
        // The parametric curve, applied on top of the point curve as Lightroom does: both baked into the master.
        let zones = ["Shadows", "Darks", "Lights", "Highlights"].map { number("Parametric" + $0) ?? 0 }
        let splits = [("ParametricShadowSplit", 25.0), ("ParametricMidtoneSplit", 50), ("ParametricHighlightSplit", 75)].map { (number($0.0) ?? $0.1) / 100 }
        if zones.contains(where: { $0 != 0 }) {
            let point = Curve(a.curves.master)
            var last = 0.0
            a.curves.master = (0...8).map { i in
                let x = Double(i) / 8
                last = max(last, parametric(point.value(x), zones: zones, splits: splits))
                return CurvePoint(x: x, y: last)
            }
        }
        // Colour grading: hue (degrees) and amount as the wheel's push, lightness as its master.
        func push(_ path: WritableKeyPath<ColorWheels, ColorWheels.Wheel>, hue: Double, amount: Double) {
            guard amount != 0 else { return }
            let reach = min(max(amount, 0), 100) / 100 * 0.4
            a.wheels[keyPath: path].x = reach * cos(hue * .pi / 180)
            a.wheels[keyPath: path].y = reach * sin(hue * .pi / 180)
        }
        let wheels: [(String, WritableKeyPath<ColorWheels, ColorWheels.Wheel>)] = [("Shadow", \.lift), ("Midtone", \.gamma),
                                                                                   ("Highlight", \.gain), ("Global", \.offset)]
        for (name, path) in wheels {
            push(path, hue: number("ColorGrade\(name)Hue") ?? 0, amount: number("ColorGrade\(name)Sat") ?? 0)
            if let light = number("ColorGrade\(name)Lum") { a.wheels[keyPath: path].master = min(max(light / 200, -0.5), 0.5) }
        }
        if let value = number("ColorGradeBlending") { a.wheels.blending = min(max(value, 0), 100) }
        if let value = number("ColorGradeBalance") { a.wheels.balance = min(max(value, -100), 100) }
        // The older Split Toning, when there's no Colour Grading: its shadows and highlights, and its balance.
        let grading = crs.keys.contains { $0.hasPrefix("ColorGrade") }
        for (name, path) in [("Shadow", \ColorWheels.lift), ("Highlight", \.gain)] {
            let hue = number("SplitToning\(name)Hue") ?? 0, amount = number("SplitToning\(name)Saturation") ?? 0
            if !grading { push(path, hue: hue, amount: amount) }
        }
        if let value = number("SplitToningBalance"), !grading { a.wheels.balance = min(max(value, -100), 100) }
        // The profile. Adobe's own (Adobe Color, Standard…) start from Classic (RAW only).
        let params = crs.reduce(into: [String: String]()) { if $1.key.hasPrefix("Look.Parameters.") { $0[String($1.key.dropFirst(16))] = $1.value } }
        let lookName = crs["Look.Name"]
        if [crs["CameraProfile"], lookName, params["CameraProfile"]].contains(where: { $0.map(adobeProfiles.contains) == true }) { a.profile = .adobe }
        // A creative profile: its colour table at its amount (Lightroom's 1 is 100%), and its own settings
        // under the preset's. One whose table can't be read is listed, by its name.
        var profiles: [String] = []
        if let name = lookName, !adobeProfiles.contains(name) {
            let amount = Double(crs["Look.Amount"] ?? "") ?? 1
            if let digest = params["RGBTable"] {
                let share = Double(params["RGBTableAmount"] ?? "") ?? 1
                if LookTable.keep(digest, text: crs["Table_" + digest]) {
                    a.lookName = name; a.lookTable = digest
                    a.lookAmount = min(max((amount > 2 ? amount / 100 : amount) * share * 100, 0), 200)
                } else {
                    profiles.append(name)
                }
            }
            // (Its hue and saturation table, the older kind, Pluck can't read.)
            if params["LookTable"] != nil, !profiles.contains(name) { profiles.append(name) }
            let (own, left) = adjustments(params)
            profiles += left
            if let profile = own.profile { a.profile = profile }
            let plain = PhotoAdjustments()
            for path in [\PhotoAdjustments.exposure, \.contrast, \.highlights, \.shadows, \.whites, \.blacks, \.vibrance, \.saturation, \.clarity,
                         \.texture, \.dehaze] where own[keyPath: path] != plain[keyPath: path] {
                let limit = path == \.exposure ? 5.0 : 100
                a[keyPath: path] = min(max(a[keyPath: path] + own[keyPath: path], -limit), limit)
            }
            for i in 0..<8 {
                a.mixer.hue[i] = min(max(a.mixer.hue[i] + own.mixer.hue[i], -100), 100)
                a.mixer.saturation[i] = min(max(a.mixer.saturation[i] + own.mixer.saturation[i], -100), 100)
                a.mixer.luminance[i] = min(max(a.mixer.luminance[i] + own.mixer.luminance[i], -100), 100)
            }
            // Its curves first, the preset's on top.
            for path in [\PhotoCurves.master, \.red, \.green, \.blue] where own.curves[keyPath: path] != plain.curves[keyPath: path] {
                let under = Curve(own.curves[keyPath: path]), over = Curve(a.curves[keyPath: path])
                a.curves[keyPath: path] = (0...16).map { CurvePoint(x: Double($0) / 16, y: over.value(under.value(Double($0) / 16))) }
            }
        }
        if let gray = crs["ConvertToGrayscale"] {
            used.insert("ConvertToGrayscale")
            if gray.lowercased() == "true" { a.profile = .monochrome }
        }
        // What isn't a look (names, versions, flags) isn't worth listing; the rest only when set.
        // (The profile's own settings and its tables are read above.)
        let unmapped = crs.filter { key, value in
            guard !used.contains(key), !ignored.contains(key), !key.hasPrefix("Has"), !key.hasPrefix("Supports"),
                  !key.hasPrefix("Look."), !key.hasPrefix("Table_") else { return false }
            let plain = value.trimmingCharacters(in: .whitespaces).lowercased()
            return !["", "0", "+0", "0.0", "+0.0", "false", "0, 0;255, 255"].contains(plain)
        }.keys
        return (a, Set(unmapped).union(profiles).sorted())
    }

    /// Lightroom's parametric curve at `x`: each zone (shadows, darks, lights, highlights, split where `splits`
    /// say) lifts or lowers its part of the range, most at its middle and fading smoothly to nothing at the
    /// middles of the zones beside it, so neighbouring zones blend across each split. Black and white stay put.
    static func parametric(_ x: Double, zones: [Double], splits: [Double]) -> Double {
        let s = splits.map { min(max($0, 0.05), 0.95) }.sorted()
        let edges = [0, s[0], s[1], s[2], 1]
        let middles = [0] + (0..<4).map { (edges[$0] + edges[$0 + 1]) / 2 } + [1]
        func smooth(_ t: Double) -> Double { let t = min(max(t, 0), 1); return t * t * (3 - 2 * t) }
        var y = x
        for i in 0..<4 {
            let low = middles[i], middle = middles[i + 1], high = middles[i + 2]
            let w = x <= middle ? smooth((x - low) / max(middle - low, 1e-3)) : smooth((high - x) / max(high - middle, 1e-3))
            // ±100 moves the zone's middle by 0.15 (of black to white).
            y += zones[i] / 100 * 0.15 * w
        }
        return min(max(y, 0), 1)
    }

    /// Keys that describe a preset rather than its look.
    private static let ignored: Set<String> = [
        "Version", "ProcessVersion", "PresetType", "UUID", "Cluster", "Name", "ShortName", "SortName", "Group", "Description",
        "Copyright", "Contact", "ToneCurveName", "ToneCurveName2012", "CameraProfile", "CameraProfileDigest", "Look", "RequiresRGBTables",
        "AlreadyApplied", "WhiteBalance", "ColorGradeMidtoneLum", "OverrideLookVignette", "CompatibleVersion",
        "ToneCurve", "ToneCurveRed", "ToneCurveGreen", "ToneCurveBlue", "ToneMapStrength", "ConvertToGrayscale", "Model", "Amount",
        "RGBTable", "RGBTableAmount", "LookTable",
    ]

    /// Adobe's own profiles (not creative ones): Classic stands in for them.
    static let adobeProfiles: Set<String> = ["Adobe Color", "Adobe Standard", "Adobe Landscape", "Adobe Portrait", "Adobe Vivid",
                                             "Adobe Neutral", "Adobe Monochrome", "Adobe Standard B&W"]

    // MARK: - Importing

    /// Turns the presets in these files (and folders) into Pluck's looks. How many came in, and
    /// what didn't: files that can't be read, and settings Pluck has nothing for (once each).
    @MainActor
    static func importPresets(from urls: [URL], into target: PhotoCatalog? = nil) -> (imported: Int, skipped: [String]) {
        let catalog = target ?? .shared
        var files: [URL] = []
        for url in urls {
            var folder: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &folder)
            if folder.boolValue, let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for case let file as URL in walker where ["xmp", "lrtemplate"].contains(file.pathExtension.lowercased()) { files.append(file) }
            } else {
                files.append(url)
            }
        }
        var imported = 0, unmapped: Set<String> = [], unreadable: [String] = []
        for file in files.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
            guard let crs = try? read(file) else { unreadable.append(file.lastPathComponent); continue }
            let (adjust, left) = adjustments(crs)
            unmapped.formUnion(left)
            let name = crs["Name"].flatMap { $0.isEmpty ? nil : $0 } ?? file.deletingPathExtension().lastPathComponent
            catalog.importPreset(named: name, adjust: adjust, source: file.path, lightroom: crs)
            imported += 1
        }
        return (imported, unreadable + unmapped.sorted())
    }
}
