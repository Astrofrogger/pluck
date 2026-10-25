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
        private var open: String?
        private var items: [String] = []
        private var text = ""
        /// A list of one text in several languages (a name): only the first (x-default) counts.
        private var alternatives = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            // Only the settings themselves: what's inside one of them (the profile's own crs:Name
            // inside crs:Look) isn't the preset's.
            guard open == nil else {
                if name == "rdf:Alt" { alternatives = true }
                text = ""
                return
            }
            for (key, value) in attributes where key.hasPrefix("crs:") { found[String(key.dropFirst(4))] = value }
            if name.hasPrefix("crs:") {
                open = String(name.dropFirst(4))
                items = []
                alternatives = false
            }
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard let key = open else { return }
            if name == "rdf:li" {
                items.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
            } else if name == "crs:" + key {
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
        // Lightroom sharpens every RAW by 40 unless told not to: in a photo's own edit, that's no edit.
        if asShotKelvin != nil, number("Sharpness") == 40 { } else { set("Sharpness", \.sharpen, scale: 1 / 1.5, range: 0...100) }
        set("LuminanceSmoothing", \.noise, range: 0...100)
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
        // Colour grading: hue (degrees) and amount as the wheel's push, lightness as its master.
        let wheels: [(String, WritableKeyPath<ColorWheels, ColorWheels.Wheel>)] = [("Shadow", \.lift), ("Midtone", \.gamma),
                                                                                   ("Highlight", \.gain), ("Global", \.offset)]
        for (name, path) in wheels {
            let hue = number("ColorGrade\(name)Hue") ?? 0, amount = number("ColorGrade\(name)Sat") ?? 0
            if amount != 0 {
                let reach = min(max(amount, 0), 100) / 100 * 0.4
                a.wheels[keyPath: path].x = reach * cos(hue * .pi / 180)
                a.wheels[keyPath: path].y = reach * sin(hue * .pi / 180)
            }
            if let light = number("ColorGrade\(name)Lum") { a.wheels[keyPath: path].master = min(max(light / 200, -0.5), 0.5) }
        }
        if let gray = crs["ConvertToGrayscale"] {
            used.insert("ConvertToGrayscale")
            if gray.lowercased() == "true" { a.profile = .monochrome }
        }
        // What isn't a look (names, versions, flags) isn't worth listing; the rest only when set.
        let unmapped = crs.filter { key, value in
            guard !used.contains(key), !ignored.contains(key), !key.hasPrefix("Has"), !key.hasPrefix("Supports") else { return false }
            let plain = value.trimmingCharacters(in: .whitespaces).lowercased()
            return !["", "0", "+0", "0.0", "+0.0", "false", "0, 0;255, 255"].contains(plain)
        }.keys.sorted()
        return (a, unmapped)
    }

    /// Keys that describe a preset rather than its look.
    private static let ignored: Set<String> = [
        "Version", "ProcessVersion", "PresetType", "UUID", "Cluster", "Name", "ShortName", "SortName", "Group", "Description",
        "Copyright", "Contact", "ToneCurveName", "ToneCurveName2012", "CameraProfile", "CameraProfileDigest", "Look", "RequiresRGBTables",
        "AlreadyApplied", "WhiteBalance", "ColorGradeBlending", "ColorGradeMidtoneLum", "OverrideLookVignette", "CompatibleVersion",
        "ToneCurve", "ToneCurveRed", "ToneCurveGreen", "ToneCurveBlue", "ToneMapStrength", "ConvertToGrayscale", "Model", "Amount",
    ]

    // MARK: - Importing

    /// Turns the presets in these files (and folders) into Pluck's looks. How many came in, and
    /// what didn't: files that can't be read, and settings Pluck has nothing for (once each).
    @MainActor
    static func importPresets(from urls: [URL], into catalog: PhotoCatalog = .shared) -> (imported: Int, skipped: [String]) {
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
