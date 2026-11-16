import AppKit
import PDFKit

/// Suggestions from a brand book PDF, read on this Mac: the logo pictures inside it (from pages
/// about the logo first, then the biggest), colour codes from its text (hex, RGB; CMYK and
/// Pantone kept as text), and what it says about clear space and minimum size. Nothing is
/// saved until the person ticks what's right.
enum BrandBookImport {
    struct Suggestion: Identifiable {
        enum Kind {
            case logo(BrandProfile.Logo)
            case colour(BrandProfile.Swatch)
            case clearSpace(BrandProfile.ClearSpace)
            case minimumWidth(Double)
            /// Said in the book but not something the check can measure (mm, a statement): shown, not applied.
            case note(String)
        }
        let id = UUID()
        var kind: Kind
        /// What it is, and the line it came from.
        var label: String
        var source: String
        var chosen = true
    }

    static func read(_ url: URL) -> [Suggestion] {
        guard let document = PDFDocument(url: url) else { return [] }
        var suggestions: [Suggestion] = []
        var logoPages = Set<Int>()
        var text = ""
        for index in 0..<document.pageCount {
            let page = document.page(at: index)?.string ?? ""
            if page.range(of: "logo", options: .caseInsensitive) != nil { logoPages.insert(index) }
            text += page + "\n"
        }
        suggestions += logos(url, logoPages: logoPages)
        suggestions += colours(in: text)
        suggestions += rules(in: text)
        return suggestions
    }

    /// The profile with the ticked suggestions added.
    static func apply(_ suggestions: [Suggestion], to profile: inout BrandProfile) {
        for suggestion in suggestions where suggestion.chosen {
            switch suggestion.kind {
            case .logo(let logo): profile.logos.append(logo)
            case .colour(let swatch):
                if !profile.palette.contains(where: { $0.hex != nil && $0.hex == swatch.hex || $0.name == swatch.name && swatch.hex == nil }) {
                    profile.palette.append(swatch)
                }
            case .clearSpace(let space): profile.clearSpace = space
            case .minimumWidth(let width): profile.minimumWidth = width
            case .note: break
            }
        }
    }

    // MARK: - Colours

    static func colours(in text: String) -> [Suggestion] {
        var found: [Suggestion] = []
        var seen = Set<String>()
        func add(_ swatch: BrandProfile.Swatch, _ source: String) {
            let key = swatch.hex ?? swatch.name.lowercased()
            guard seen.insert(key).inserted else { return }
            found.append(Suggestion(kind: .colour(swatch), label: swatch.hex.map { swatch.name.isEmpty ? $0 : "\($0) · \(swatch.name)" } ?? swatch.name,
                                    source: source))
        }
        for line in text.components(separatedBy: .newlines) {
            let source = line.trimmingCharacters(in: .whitespaces)
            for m in matches(#"#([0-9A-Fa-f]{6})\b"#, in: line) { add(.init(hex: "#" + m[1].uppercased()), source) }
            for m in matches(#"(?i)\bR(?:GB)?\s*:?\s*(\d{1,3})[\s,/]+(?:G\s*:?\s*)?(\d{1,3})[\s,/]+(?:B\s*:?\s*)?(\d{1,3})\b"#, in: line) {
                let values = m[1...3].compactMap { Double($0) }
                if values.count == 3, values.allSatisfy({ $0 <= 255 }) {
                    add(.init(hex: BrandProfile.hex(SIMD3(values[0], values[1], values[2]) / 255)), source)
                }
            }
            for m in matches(#"(?i)\bC(?:MYK)?\s*:?\s*(\d{1,3})[\s,/%]+(?:M\s*:?\s*)?(\d{1,3})[\s,/%]+(?:Y\s*:?\s*)?(\d{1,3})[\s,/%]+(?:K\s*:?\s*)?(\d{1,3})\b"#, in: line) {
                add(.init(name: "CMYK \(m[1]) \(m[2]) \(m[3]) \(m[4])"), source)
            }
            for m in matches(#"(?i)\b(?:Pantone|PMS)\s+([0-9A-Za-z\- ]{1,20}?(?:\s(?:C|U|CP|UP|TCX|TPX))?)\b(?=$|[\s,;.)])"#, in: line) {
                add(.init(name: "Pantone " + m[1].trimmingCharacters(in: .whitespaces).uppercased()), source)
            }
        }
        return found
    }

    // MARK: - Clear space and minimum size

    static func rules(in text: String) -> [Suggestion] {
        var found: [Suggestion] = []
        // Lines joined with the next one: "Clear space" is often a heading over the number.
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for (i, line) in lines.enumerated() {
            let lower = line.lowercased()
            let context = i + 1 < lines.count ? line + " " + lines[i + 1] : line
            let number = matches(#"(\d+(?:[.,]\d+)?)\s*((?:px|pixels?|mm|pt|x)\b|%)"#, in: context.lowercased()).first
            if ["clear space", "clearspace", "clear zone", "exclusion zone", "protection zone", "safe zone"].contains(where: lower.contains) {
                if let number, let value = Double(number[1].replacingOccurrences(of: ",", with: ".")), number[2].hasPrefix("p") || number[2] == "%" {
                    let space = BrandProfile.ClearSpace(amount: value, percent: number[2] == "%")
                    found.append(Suggestion(kind: .clearSpace(space), label: String(localized: "Clear space \(number[1]) \(number[2])"), source: context))
                } else {
                    found.append(Suggestion(kind: .note(context), label: String(localized: "Clear space"), source: context, chosen: false))
                }
            }
            if ["minimum size", "minimum width", "min. size", "min size", "smallest size"].contains(where: lower.contains) {
                if let number, let value = Double(number[1].replacingOccurrences(of: ",", with: ".")), number[2].hasPrefix("p") && number[2] != "pt" {
                    found.append(Suggestion(kind: .minimumWidth(value), label: String(localized: "Minimum width \(number[1]) px"), source: context))
                } else {
                    found.append(Suggestion(kind: .note(context), label: String(localized: "Minimum size"), source: context, chosen: false))
                }
            }
        }
        return found
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
        }
    }

    // MARK: - Logo pictures

    /// The pictures inside the PDF (PNG data), those on pages about the logo first, then the biggest; six at most.
    static func logos(_ url: URL, logoPages: Set<Int>) -> [Suggestion] {
        guard let document = CGPDFDocument(url as CFURL) else { return [] }
        var found: [(image: CGImage, page: Int)] = []
        for number in 1...max(document.numberOfPages, 1) {
            guard let page = document.page(at: number), let dictionary = page.dictionary else { continue }
            var resources: CGPDFDictionaryRef?, objects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
                  CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { continue }
            var streams: [CGPDFStreamRef] = []
            CGPDFDictionaryApplyBlock(objects, { _, value, _ in
                var stream: CGPDFStreamRef?
                if CGPDFObjectGetValue(value, .stream, &stream), let stream { streams.append(stream) }
                return true
            }, nil)
            for stream in streams { if let image = image(stream) { found.append((image, number - 1)) } }
        }
        let ranked = found.filter { $0.image.width >= 32 && $0.image.height >= 16 }
            .sorted { a, b in
                let la = logoPages.contains(a.page), lb = logoPages.contains(b.page)
                return la != lb ? la : a.image.width * a.image.height > b.image.width * b.image.height
            }
        return ranked.prefix(6).enumerated().compactMap { n, item in
            guard let data = NSBitmapImageRep(cgImage: item.image).representation(using: .png, properties: [:]) else { return nil }
            let logo = BrandProfile.Logo(fileName: "Brand book picture \(n + 1).png", data: data)
            return Suggestion(kind: .logo(logo), label: String(localized: "Picture from page \(item.page + 1)"),
                              source: "\(item.image.width)×\(item.image.height)", chosen: n == 0)
        }
    }

    /// An image XObject as a picture: JPEG and JPEG 2000 as they are, else the decoded samples
    /// (gray, RGB or CMYK, 8 bits), with its soft mask as alpha when it has one.
    private static func image(_ stream: CGPDFStreamRef) -> CGImage? {
        guard let dictionary = CGPDFStreamGetDictionary(stream) else { return nil }
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype, String(cString: subtype) == "Image" else { return nil }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data? else { return nil }
        if format == .jpegEncoded || format == .JPEG2000 {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        var w = 0, h = 0, bits = 0
        guard CGPDFDictionaryGetInteger(dictionary, "Width", &w), CGPDFDictionaryGetInteger(dictionary, "Height", &h), w > 0, h > 0 else { return nil }
        if !CGPDFDictionaryGetInteger(dictionary, "BitsPerComponent", &bits) { bits = 8 }
        guard bits == 8 else { return nil }
        var spaceName: UnsafePointer<CChar>?
        var components = 3
        if CGPDFDictionaryGetName(dictionary, "ColorSpace", &spaceName), let spaceName {
            switch String(cString: spaceName) {
            case "DeviceGray": components = 1
            case "DeviceCMYK": components = 4
            default: components = 3
            }
        } else {
            // An ICC-based or indexed space: guess from the data's size.
            components = data.count / (w * h)
            guard [1, 3, 4].contains(components) else { return nil }
        }
        guard data.count >= w * h * components else { return nil }
        var alpha: [UInt8]?
        var mask: CGPDFStreamRef?
        if CGPDFDictionaryGetStream(dictionary, "SMask", &mask), let mask {
            var maskFormat = CGPDFDataFormat.raw
            if let maskData = CGPDFStreamCopyData(mask, &maskFormat) as Data?, maskFormat == .raw, maskData.count >= w * h { alpha = [UInt8](maskData.prefix(w * h)) }
        }
        let bytes = [UInt8](data)
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            let p = i * components
            switch components {
            case 1: rgba[i * 4] = bytes[p]; rgba[i * 4 + 1] = bytes[p]; rgba[i * 4 + 2] = bytes[p]
            case 4:
                let k = 255 - Int(bytes[p + 3])
                rgba[i * 4] = UInt8((255 - Int(bytes[p])) * k / 255)
                rgba[i * 4 + 1] = UInt8((255 - Int(bytes[p + 1])) * k / 255)
                rgba[i * 4 + 2] = UInt8((255 - Int(bytes[p + 2])) * k / 255)
            default: rgba[i * 4] = bytes[p]; rgba[i * 4 + 1] = bytes[p + 1]; rgba[i * 4 + 2] = bytes[p + 2]
            }
            if let alpha {
                let a = Int(alpha[i])
                rgba[i * 4 + 3] = alpha[i]
                for c in 0..<3 { rgba[i * 4 + c] = UInt8(Int(rgba[i * 4 + c]) * a / 255) }
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: (alpha == nil ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
