import CoreGraphics
import Foundation

/// A logo's own shapes, read from its SVG or PDF: filled paths with their colours, in drawing
/// order. Lines become the filled shapes they paint. Anything this reader doesn't follow (text,
/// pictures, gradients, masks, filters, clipping) makes it give up, and the logo is read from a
/// picture of it as before.
struct VectorArt: @unchecked Sendable {
    struct Shape {
        var path: CGPath
        var colour: CGColor
        var evenOdd: Bool
        /// Painted as a line in the file (now its outline).
        var stroke = false
    }

    /// Top left origin, in the units the system draws the file at (its natural size).
    var shapes: [Shape]
    var size: CGSize

    init?(contentsOf url: URL) {
        switch url.pathExtension.lowercased() {
        case "svg":
            guard let data = try? Data(contentsOf: url), let art = SVGReader.read(data) else { return nil }
            self = art
        case "pdf":
            guard let art = PDFShapeReader.read(url) else { return nil }
            self = art
        default:
            return nil
        }
        guard !shapes.isEmpty, size.width > 0, size.height > 0 else { return nil }
    }

    init(shapes: [Shape], size: CGSize) {
        self.shapes = shapes
        self.size = size
    }

    /// Draws every shape into a context whose user space is this art's (top left origin, y down).
    func draw(in context: CGContext) {
        for shape in shapes {
            context.addPath(shape.path)
            context.setFillColor(shape.colour)
            context.fillPath(using: shape.evenOdd ? .evenOdd : .winding)
        }
    }

    static func srgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
        CGColor(srgbRed: min(max(r, 0), 1), green: min(max(g, 0), 1), blue: min(max(b, 0), 1), alpha: min(max(a, 0), 1))
    }
}

// MARK: - SVG

/// Reads the parts of SVG that logos use: path, rect, circle, ellipse, line, polyline and polygon,
/// groups with transforms, solid fills and strokes (as attributes, inline style or simple class
/// rules), opacity and fill-rule.
private final class SVGReader: NSObject, XMLParserDelegate {
    struct Style {
        var fill: CGColor? = CGColor(gray: 0, alpha: 1)
        var fillOpacity = 1.0
        var stroke: CGColor?
        var strokeOpacity = 1.0
        var strokeWidth = 1.0
        var opacity = 1.0
        var evenOdd = false
        var join = CGLineJoin.miter
        var cap = CGLineCap.butt
        var miter = 4.0
        var hidden = false
    }

    private var shapes: [VectorArt.Shape] = []
    private var size: CGSize?
    private var stack: [(style: Style, transform: CGAffineTransform)] = []
    /// Inside defs, a gradient, a clip path and the like: not drawn.
    private var skipping = 0
    private var failed = false
    private var classes: [String: [String: String]] = [:]
    private var styleText: String?
    private var sawRoot = false

    static func read(_ data: Data) -> VectorArt? {
        // Class rules can come anywhere; read them first.
        let first = SVGReader()
        first.collectingStyles = true
        let styles = XMLParser(data: data)
        styles.delegate = first
        styles.parse()
        let reader = SVGReader()
        reader.classes = first.classes
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), !reader.failed, let size = reader.size else { return nil }
        return VectorArt(shapes: reader.shapes, size: size)
    }

    private var collectingStyles = false

    private static let notDrawn: Set<String> = [
        "defs", "title", "desc", "metadata", "clipPath", "mask", "linearGradient", "radialGradient", "pattern", "symbol",
        "marker", "filter", "style", "script", "sodipodi:namedview", "namedview",
    ]
    private static let unsupported: Set<String> = ["text", "image", "use", "foreignObject", "switch", "textPath", "tspan"]

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let tag = name.split(separator: ":").last.map(String.init) ?? name
        if collectingStyles {
            if tag == "style" { styleText = "" }
            return
        }
        guard !failed else { return }
        if skipping > 0 || Self.notDrawn.contains(tag) || Self.notDrawn.contains(name) {
            skipping += 1
            return
        }
        if name.contains(":") && !["svg:svg", "svg:g", "svg:path"].contains(name) {
            // Editor-only elements (Inkscape, Illustrator) are skipped.
            skipping += 1
            return
        }
        if Self.unsupported.contains(tag) { return fail() }
        var properties = attributes
        for name in (attributes["class"] ?? "").split(separator: " ") {
            for (key, value) in classes[String(name)] ?? [:] { properties[key] = value }
        }
        for (key, value) in Self.declarations(attributes["style"] ?? "") { properties[key] = value }
        for key in ["clip-path", "mask", "filter"] where properties[key].map({ $0 != "none" }) == true { return fail() }

        let parent = stack.last ?? (Style(), .identity)
        var style = parent.style
        style.opacity = 1
        guard apply(properties, to: &style) else { return fail() }
        style.opacity *= parent.style.opacity
        var transform = parent.transform
        if let list = properties["transform"] {
            guard let local = Self.transform(list) else { return fail() }
            transform = local.concatenating(transform)
        }

        if tag == "svg" {
            if !sawRoot {
                sawRoot = true
                guard let root = rootTransform(attributes) else { return fail() }
                transform = root.concatenating(transform)
            } else {
                return fail()
            }
        }
        stack.append((style, transform))
        if style.hidden { return }
        guard let path = geometry(tag, properties) else {
            if !["svg", "g", "a"].contains(tag) { failedOnUnknown(tag) }
            return
        }
        paint(path, style: style, transform: transform)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let tag = name.split(separator: ":").last.map(String.init) ?? name
        if collectingStyles {
            if tag == "style", let text = styleText { parseRules(text); styleText = nil }
            return
        }
        if skipping > 0 { skipping -= 1; return }
        if !stack.isEmpty { stack.removeLast() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectingStyles, styleText != nil { styleText! += string }
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        if collectingStyles, styleText != nil { styleText! += String(decoding: data, as: UTF8.self) }
    }

    private func fail() { failed = true }

    /// Something unknown that draws nothing is fine; anything else isn't.
    private func failedOnUnknown(_ tag: String) {
        let drawing: Set<String> = ["path", "rect", "circle", "ellipse", "line", "polyline", "polygon"]
        if drawing.contains(tag) { fail() }
    }

    // MARK: Styles

    private func parseRules(_ text: String) {
        var rest = Substring(text.replacingOccurrences(of: "/\\*[\\s\\S]*?\\*/", with: "", options: .regularExpression))
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            let selectors = rest[..<open].split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let body = Self.declarations(String(rest[rest.index(after: open)..<close]))
            for selector in selectors where selector.hasPrefix(".") && !selector.contains(" ") {
                classes[String(selector.dropFirst()), default: [:]].merge(body) { $1 }
            }
            rest = rest[rest.index(after: close)...]
        }
    }

    private static func declarations(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in text.split(separator: ";") {
            let pair = part.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            result[pair[0].trimmingCharacters(in: .whitespaces)] = pair[1].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    /// False when a property asks for something not supported (a gradient fill).
    private func apply(_ p: [String: String], to style: inout Style) -> Bool {
        if let v = p["fill"] {
            guard let colour = Self.paint(v) else { return false }
            style.fill = colour.isNone ? nil : colour.value
        }
        if let v = p["stroke"] {
            guard let colour = Self.paint(v) else { return false }
            style.stroke = colour.isNone ? nil : colour.value
        }
        if let v = p["fill-opacity"].flatMap(Self.number) { style.fillOpacity = v }
        if let v = p["stroke-opacity"].flatMap(Self.number) { style.strokeOpacity = v }
        if let v = p["opacity"].flatMap(Self.number) { style.opacity = v }
        if let v = p["stroke-width"].flatMap(Self.length) { style.strokeWidth = v }
        if let v = p["fill-rule"] { style.evenOdd = v == "evenodd" }
        if let v = p["stroke-linejoin"] { style.join = v == "round" ? .round : v == "bevel" ? .bevel : .miter }
        if let v = p["stroke-linecap"] { style.cap = v == "round" ? .round : v == "square" ? .square : .butt }
        if let v = p["stroke-miterlimit"].flatMap(Self.number) { style.miter = v }
        if p["display"] == "none" || p["visibility"] == "hidden" { style.hidden = true }
        if let dash = p["stroke-dasharray"], dash != "none", style.stroke != nil || p["stroke"] != nil { return false }
        return true
    }

    private static func number(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("%") { return Double(t.dropLast()).map { $0 / 100 } }
        return Double(t)
    }

    private static func length(_ text: String) -> Double? {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("px") { t.removeLast(2) }
        return Double(t)
    }

    private static let names: [String: (Double, Double, Double)] = [
        "black": (0, 0, 0), "white": (1, 1, 1), "red": (1, 0, 0), "lime": (0, 1, 0), "green": (0, 128 / 255, 0),
        "blue": (0, 0, 1), "yellow": (1, 1, 0), "cyan": (0, 1, 1), "aqua": (0, 1, 1), "magenta": (1, 0, 1), "fuchsia": (1, 0, 1),
        "gray": (128 / 255, 128 / 255, 128 / 255), "grey": (128 / 255, 128 / 255, 128 / 255), "silver": (192 / 255, 192 / 255, 192 / 255),
        "maroon": (128 / 255, 0, 0), "olive": (128 / 255, 128 / 255, 0), "navy": (0, 0, 128 / 255), "purple": (128 / 255, 0, 128 / 255),
        "teal": (0, 128 / 255, 128 / 255), "orange": (1, 165 / 255, 0),
    ]

    /// A fill or stroke value: nil when it can't be painted as a solid colour.
    private static func paint(_ text: String) -> (value: CGColor, isNone: Bool)? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t == "none" || t == "transparent" { return (CGColor(gray: 0, alpha: 0), true) }
        if t == "currentcolor" { return (CGColor(gray: 0, alpha: 1), false) }
        if t.hasPrefix("#") {
            var hex = String(t.dropFirst())
            if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
            let v = hex.count == 8 ? value >> 8 : value
            let a = hex.count == 8 ? Double(value & 255) / 255 : 1
            return (VectorArt.srgb(Double(v >> 16 & 255) / 255, Double(v >> 8 & 255) / 255, Double(v & 255) / 255, a), false)
        }
        if t.hasPrefix("rgb") {
            guard let open = t.firstIndex(of: "("), let close = t.firstIndex(of: ")") else { return nil }
            let parts = t[t.index(after: open)..<close].split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            let values = parts.compactMap { part -> Double? in
                part.hasSuffix("%") ? Double(part.dropLast()).map { $0 / 100 } : Double(part).map { $0 / 255 }
            }
            guard values.count >= 3 else { return nil }
            let alpha = parts.count >= 4 ? (parts[3].hasSuffix("%") ? values[3] : Double(parts[3]) ?? 1) : 1
            return (VectorArt.srgb(values[0], values[1], values[2], alpha), false)
        }
        if let (r, g, b) = names[t] { return (VectorArt.srgb(r, g, b), false) }
        return nil
    }

    // MARK: Geometry

    private func rootTransform(_ a: [String: String]) -> CGAffineTransform? {
        let box = (a["viewBox"] ?? a["viewbox"]).map { $0.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) } }
        // Width and height in other units than pixels (mm, %) aren't followed.
        let width = a["width"].map { Self.length($0) }, height = a["height"].map { Self.length($0) }
        if width == .some(nil) || height == .some(nil) { return nil }
        if let box, box.count == 4, box[2] > 0, box[3] > 0 {
            let w = (width ?? nil) ?? box[2], h = (height ?? nil) ?? box[3]
            size = CGSize(width: w, height: h)
            guard (a["preserveAspectRatio"] ?? "xMidYMid meet").hasPrefix("xMidYMid") else { return nil }
            let scale = min(w / box[2], h / box[3])
            let dx = (w - box[2] * scale) / 2, dy = (h - box[3] * scale) / 2
            return CGAffineTransform(translationX: -box[0], y: -box[1])
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: dx, y: dy))
        }
        guard let w = width ?? nil, let h = height ?? nil else { return nil }
        size = CGSize(width: w, height: h)
        return .identity
    }

    private func geometry(_ tag: String, _ a: [String: String]) -> CGPath? {
        func n(_ key: String) -> Double { a[key].flatMap(Self.length) ?? 0 }
        switch tag {
        case "path":
            return a["d"].flatMap(SVGPathData.parse)
        case "rect":
            let w = n("width"), h = n("height")
            guard w > 0, h > 0 else { return CGMutablePath() }
            var rx = a["rx"].flatMap(Self.length), ry = a["ry"].flatMap(Self.length)
            if rx == nil { rx = ry }
            if ry == nil { ry = rx }
            let r = CGRect(x: n("x"), y: n("y"), width: w, height: h)
            let cx = min(rx ?? 0, w / 2), cy = min(ry ?? 0, h / 2)
            return cx > 0 && cy > 0 ? CGPath(roundedRect: r, cornerWidth: cx, cornerHeight: cy, transform: nil) : CGPath(rect: r, transform: nil)
        case "circle":
            let r = n("r")
            return CGPath(ellipseIn: CGRect(x: n("cx") - r, y: n("cy") - r, width: r * 2, height: r * 2), transform: nil)
        case "ellipse":
            let rx = n("rx"), ry = n("ry")
            return CGPath(ellipseIn: CGRect(x: n("cx") - rx, y: n("cy") - ry, width: rx * 2, height: ry * 2), transform: nil)
        case "line":
            let path = CGMutablePath()
            path.move(to: CGPoint(x: n("x1"), y: n("y1")))
            path.addLine(to: CGPoint(x: n("x2"), y: n("y2")))
            return path
        case "polyline", "polygon":
            let values = (a["points"] ?? "").split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" }).compactMap { Double($0) }
            guard values.count >= 4 else { return CGMutablePath() }
            let path = CGMutablePath()
            path.move(to: CGPoint(x: values[0], y: values[1]))
            for i in stride(from: 2, to: values.count - 1, by: 2) { path.addLine(to: CGPoint(x: values[i], y: values[i + 1])) }
            if tag == "polygon" { path.closeSubpath() }
            return path
        default:
            return nil
        }
    }

    private func paint(_ path: CGPath, style: Style, transform: CGAffineTransform) {
        var transform = transform
        if let fill = style.fill, tag(fill, style.fillOpacity * style.opacity) {
            let colour = fill.copy(alpha: fill.alpha * style.fillOpacity * style.opacity) ?? fill
            if let placed = path.copy(using: &transform) { shapes.append(.init(path: placed, colour: colour, evenOdd: style.evenOdd)) }
        }
        if let stroke = style.stroke, style.strokeWidth > 0, tag(stroke, style.strokeOpacity * style.opacity) {
            let outline = path.copy(strokingWithWidth: style.strokeWidth, lineCap: style.cap, lineJoin: style.join, miterLimit: style.miter)
            let colour = stroke.copy(alpha: stroke.alpha * style.strokeOpacity * style.opacity) ?? stroke
            if let placed = outline.copy(using: &transform) { shapes.append(.init(path: placed, colour: colour, evenOdd: false, stroke: true)) }
        }
    }

    /// Whether it shows at all.
    private func tag(_ colour: CGColor, _ opacity: Double) -> Bool { colour.alpha * opacity > 0.001 }

    /// An SVG transform list.
    static func transform(_ text: String) -> CGAffineTransform? {
        var result = CGAffineTransform.identity
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "(") {
            guard let close = rest[open...].firstIndex(of: ")") else { return nil }
            let name = rest[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " ,\n\t"))
            let v = rest[rest.index(after: open)..<close].split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" }).compactMap { Double($0) }
            let t: CGAffineTransform
            switch (name, v.count) {
            case ("matrix", 6): t = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            case ("translate", 1): t = CGAffineTransform(translationX: v[0], y: 0)
            case ("translate", 2): t = CGAffineTransform(translationX: v[0], y: v[1])
            case ("scale", 1): t = CGAffineTransform(scaleX: v[0], y: v[0])
            case ("scale", 2): t = CGAffineTransform(scaleX: v[0], y: v[1])
            case ("rotate", 1): t = CGAffineTransform(rotationAngle: v[0] * .pi / 180)
            case ("rotate", 3):
                t = CGAffineTransform(translationX: -v[1], y: -v[2])
                    .concatenating(CGAffineTransform(rotationAngle: v[0] * .pi / 180))
                    .concatenating(CGAffineTransform(translationX: v[1], y: v[2]))
            case ("skewX", 1): t = CGAffineTransform(a: 1, b: 0, c: tan(v[0] * .pi / 180), d: 1, tx: 0, ty: 0)
            case ("skewY", 1): t = CGAffineTransform(a: 1, b: tan(v[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            default: return nil
            }
            // The first in the list is the outermost.
            result = t.concatenating(result)
            rest = rest[rest.index(after: close)...]
        }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? result : nil
    }
}

/// SVG path data ("M10 10 L20 20 …") as a path.
enum SVGPathData {
    static func parse(_ text: String) -> CGPath? {
        var scanner = Tokens(Array(text.utf8))
        let path = CGMutablePath()
        var current = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint?, lastCommand: UInt8 = 0
        var command: UInt8 = 0
        while true {
            scanner.skipSeparators()
            guard let next = scanner.peek else { break }
            if Tokens.isCommand(next) {
                command = next
                scanner.advance()
            } else if command == 0 {
                return nil
            }
            let relative = command >= UInt8(ascii: "a")
            let base = relative ? current : .zero
            func point() -> CGPoint? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return CGPoint(x: base.x + x, y: base.y + y)
            }
            switch command | 0x20 {
            case UInt8(ascii: "m"):
                guard let p = point() else { return nil }
                path.move(to: p)
                current = p; start = p
                // Further pairs are lines.
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
                lastControl = nil
            case UInt8(ascii: "l"):
                guard let p = point() else { return nil }
                path.addLine(to: p); current = p; lastControl = nil
            case UInt8(ascii: "h"):
                guard let x = scanner.number() else { return nil }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current); lastControl = nil
            case UInt8(ascii: "v"):
                guard let y = scanner.number() else { return nil }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current); lastControl = nil
            case UInt8(ascii: "c"):
                guard let c1 = point(), let c2 = point(), let p = point() else { return nil }
                path.addCurve(to: p, control1: c1, control2: c2)
                lastControl = c2; current = p
            case UInt8(ascii: "s"):
                guard let c2 = point(), let p = point() else { return nil }
                let wasCubic = [UInt8(ascii: "c"), UInt8(ascii: "s")].contains(lastCommand | 0x20)
                let c1 = wasCubic ? CGPoint(x: 2 * current.x - (lastControl ?? current).x, y: 2 * current.y - (lastControl ?? current).y) : current
                path.addCurve(to: p, control1: c1, control2: c2)
                lastControl = c2; current = p
            case UInt8(ascii: "q"):
                guard let c = point(), let p = point() else { return nil }
                path.addQuadCurve(to: p, control: c)
                lastControl = c; current = p
            case UInt8(ascii: "t"):
                guard let p = point() else { return nil }
                let wasQuad = [UInt8(ascii: "q"), UInt8(ascii: "t")].contains(lastCommand | 0x20)
                let c = wasQuad ? CGPoint(x: 2 * current.x - (lastControl ?? current).x, y: 2 * current.y - (lastControl ?? current).y) : current
                path.addQuadCurve(to: p, control: c)
                lastControl = c; current = p
            case UInt8(ascii: "a"):
                guard let rx = scanner.number(), let ry = scanner.number(), let angle = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(), let p = point() else { return nil }
                arc(path, from: current, to: p, rx: rx, ry: ry, angle: angle, large: large, sweep: sweep)
                current = p; lastControl = nil
            case UInt8(ascii: "z"):
                path.closeSubpath()
                current = start; lastControl = nil
                command = 0
                lastCommand = UInt8(ascii: "z")
                continue
            default:
                return nil
            }
            lastCommand = command
        }
        return path
    }

    /// An elliptical arc as Bézier curves (SVG's endpoint form, as in its implementation notes).
    private static func arc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx: Double, ry: Double, angle: Double,
                            large: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
        let phi = angle * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var factor = (max(numerator, 0) / denominator).squareRoot()
        if large == sweep { factor = -factor }
        let cx1 = factor * rx * y1 / ry, cy1 = -factor * ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2
        func angleOf(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let sign: Double = ux * vy - uy * vx < 0 ? -1 : 1
            let dot = (ux * vx + uy * vy) / ((ux * ux + uy * uy).squareRoot() * (vx * vx + vy * vy).squareRoot())
            return sign * acos(min(max(dot, -1), 1))
        }
        let theta = angleOf(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angleOf((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        let segments = Int((abs(delta) / (.pi / 2)).rounded(.up))
        let step = delta / Double(segments)
        let k = 4.0 / 3 * tan(step / 4)
        func at(_ t: Double) -> (point: CGPoint, tangent: CGPoint) {
            let x = rx * cos(t), y = ry * sin(t)
            let tx = -rx * sin(t), ty = ry * cos(t)
            return (CGPoint(x: cx + cosPhi * x - sinPhi * y, y: cy + sinPhi * x + cosPhi * y),
                    CGPoint(x: cosPhi * tx - sinPhi * ty, y: sinPhi * tx + cosPhi * ty))
        }
        for i in 0..<segments {
            let a = at(theta + step * Double(i)), b = at(theta + step * Double(i + 1))
            path.addCurve(to: i == segments - 1 ? p1 : b.point,
                          control1: CGPoint(x: a.point.x + k * a.tangent.x, y: a.point.y + k * a.tangent.y),
                          control2: CGPoint(x: b.point.x - k * b.tangent.x, y: b.point.y - k * b.tangent.y))
        }
    }

    /// Numbers, flags and commands in path data.
    struct Tokens {
        let bytes: [UInt8]
        var i = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        var peek: UInt8? { i < bytes.count ? bytes[i] : nil }
        mutating func advance() { i += 1 }
        static func isCommand(_ c: UInt8) -> Bool { "MmLlHhVvCcSsQqTtAaZz".utf8.contains(c) }
        mutating func skipSeparators() {
            while let c = peek, c == 32 || c == 44 || c == 9 || c == 10 || c == 13 { i += 1 }
        }
        mutating func flag() -> Bool? {
            skipSeparators()
            guard let c = peek, c == UInt8(ascii: "0") || c == UInt8(ascii: "1") else { return nil }
            i += 1
            return c == UInt8(ascii: "1")
        }
        mutating func number() -> Double? {
            skipSeparators()
            let begin = i
            if let c = peek, c == UInt8(ascii: "-") || c == UInt8(ascii: "+") { i += 1 }
            var dot = false, digits = false
            while let c = peek {
                if c >= 48 && c <= 57 { digits = true; i += 1 }
                else if c == UInt8(ascii: "."), !dot { dot = true; i += 1 }
                else { break }
            }
            if digits, let c = peek, c == UInt8(ascii: "e") || c == UInt8(ascii: "E") {
                var j = i + 1
                if j < bytes.count, bytes[j] == UInt8(ascii: "-") || bytes[j] == UInt8(ascii: "+") { j += 1 }
                if j < bytes.count, bytes[j] >= 48, bytes[j] <= 57 {
                    i = j
                    while let c = peek, c >= 48 && c <= 57 { i += 1 }
                }
            }
            guard digits else { i = begin; return nil }
            return Double(String(decoding: bytes[begin..<i], as: UTF8.self))
        }
    }
}

// MARK: - PDF

/// Reads the first page of a PDF's paths and solid fills. Text, pictures, shadings and
/// patterns aren't followed.
private final class PDFShapeReader {
    struct State {
        var ctm = CGAffineTransform.identity
        var fill = CGColor(gray: 0, alpha: 1)
        var stroke = CGColor(gray: 0, alpha: 1)
        var fillComponents = 1, strokeComponents = 1
        var lineWidth = 1.0
        var join = CGLineJoin.miter, cap = CGLineCap.butt, miter = 10.0
    }

    var state = State()
    var saved: [State] = []
    var path = CGMutablePath()
    var shapes: [VectorArt.Shape] = []
    var failed = false

    static func read(_ url: URL) -> VectorArt? {
        guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1), page.rotationAngle % 360 == 0,
              let table = CGPDFOperatorTableCreate() else { return nil }
        let reader = PDFShapeReader()
        Self.install(table)
        let stream = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(reader).toOpaque())
        let scanned = CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        guard scanned, !reader.failed else { return nil }
        // Top left origin, in the crop box.
        let box = page.getBoxRect(.cropBox)
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -box.minX, ty: box.maxY)
        let shapes = reader.shapes.compactMap { shape -> VectorArt.Shape? in
            shape.path.copy(using: &flip).map { .init(path: $0, colour: shape.colour, evenOdd: shape.evenOdd, stroke: shape.stroke) }
        }
        return VectorArt(shapes: shapes, size: box.size)
    }





    func paint(fill: Bool, stroke: Bool, evenOdd: Bool) {
        var ctm = state.ctm
        if fill, state.fill.alpha > 0.001, let placed = path.copy(using: &ctm) {
            shapes.append(.init(path: placed, colour: state.fill, evenOdd: evenOdd))
        }
        if stroke, state.lineWidth > 0 {
            let outline = path.copy(strokingWithWidth: max(state.lineWidth, 0.1), lineCap: state.cap, lineJoin: state.join, miterLimit: state.miter)
            if let placed = outline.copy(using: &ctm) { shapes.append(.init(path: placed, colour: state.stroke, evenOdd: false, stroke: true)) }
        }
        path = CGMutablePath()
    }

    private static func install(_ table: CGPDFOperatorTableRef) {
        func on(_ name: String, _ callback: @escaping CGPDFOperatorCallback) { CGPDFOperatorTableSetCallback(table, name, callback) }
        on("q") { _, info in let r = pdfReader(info); r.saved.append(r.state) }
        on("Q") { _, info in let r = pdfReader(info); if let s = r.saved.popLast() { r.state = s } }
        on("cm") { s, info in
            let r = pdfReader(info)
            guard let v = pdfNumbers(s, 6) else { r.failed = true; return }
            r.state.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(r.state.ctm)
        }
        on("m") { s, info in let r = pdfReader(info); if let v = pdfNumbers(s, 2) { r.path.move(to: CGPoint(x: v[0], y: v[1])) } else { r.failed = true } }
        on("l") { s, info in
            let r = pdfReader(info)
            guard let v = pdfNumbers(s, 2), !r.path.isEmpty else { r.failed = true; return }
            r.path.addLine(to: CGPoint(x: v[0], y: v[1]))
        }
        on("c") { s, info in
            let r = pdfReader(info)
            guard let v = pdfNumbers(s, 6), !r.path.isEmpty else { r.failed = true; return }
            r.path.addCurve(to: CGPoint(x: v[4], y: v[5]), control1: CGPoint(x: v[0], y: v[1]), control2: CGPoint(x: v[2], y: v[3]))
        }
        on("v") { s, info in
            let r = pdfReader(info)
            guard let v = pdfNumbers(s, 4), !r.path.isEmpty else { r.failed = true; return }
            r.path.addCurve(to: CGPoint(x: v[2], y: v[3]), control1: r.path.currentPoint, control2: CGPoint(x: v[0], y: v[1]))
        }
        on("y") { s, info in
            let r = pdfReader(info)
            guard let v = pdfNumbers(s, 4), !r.path.isEmpty else { r.failed = true; return }
            r.path.addCurve(to: CGPoint(x: v[2], y: v[3]), control1: CGPoint(x: v[0], y: v[1]), control2: CGPoint(x: v[2], y: v[3]))
        }
        on("h") { _, info in pdfReader(info).path.closeSubpath() }
        on("re") { s, info in
            let r = pdfReader(info)
            guard let v = pdfNumbers(s, 4) else { r.failed = true; return }
            r.path.addRect(CGRect(x: v[0], y: v[1], width: v[2], height: v[3]))
        }
        on("f") { _, info in pdfReader(info).paint(fill: true, stroke: false, evenOdd: false) }
        on("F") { _, info in pdfReader(info).paint(fill: true, stroke: false, evenOdd: false) }
        on("f*") { _, info in pdfReader(info).paint(fill: true, stroke: false, evenOdd: true) }
        on("B") { _, info in pdfReader(info).paint(fill: true, stroke: true, evenOdd: false) }
        on("B*") { _, info in pdfReader(info).paint(fill: true, stroke: true, evenOdd: true) }
        on("b") { _, info in let r = pdfReader(info); r.path.closeSubpath(); r.paint(fill: true, stroke: true, evenOdd: false) }
        on("b*") { _, info in let r = pdfReader(info); r.path.closeSubpath(); r.paint(fill: true, stroke: true, evenOdd: true) }
        on("S") { _, info in pdfReader(info).paint(fill: false, stroke: true, evenOdd: false) }
        on("s") { _, info in let r = pdfReader(info); r.path.closeSubpath(); r.paint(fill: false, stroke: true, evenOdd: false) }
        // A clip that only trims to the page is common; one that cuts into the art is caught
        // later, when the shapes are checked against a picture of the file.
        on("n") { _, info in pdfReader(info).path = CGMutablePath() }
        on("w") { s, info in if let v = pdfNumbers(s, 1) { pdfReader(info).state.lineWidth = v[0] } }
        on("j") { s, info in if let v = pdfNumbers(s, 1) { pdfReader(info).state.join = CGLineJoin(rawValue: Int32(v[0])) ?? .miter } }
        on("J") { s, info in if let v = pdfNumbers(s, 1) { pdfReader(info).state.cap = CGLineCap(rawValue: Int32(v[0])) ?? .butt } }
        on("M") { s, info in if let v = pdfNumbers(s, 1) { pdfReader(info).state.miter = v[0] } }
        on("g") { s, info in if let v = pdfNumbers(s, 1), let c = pdfColour(v) { pdfReader(info).state.fill = c } }
        on("G") { s, info in if let v = pdfNumbers(s, 1), let c = pdfColour(v) { pdfReader(info).state.stroke = c } }
        on("rg") { s, info in if let v = pdfNumbers(s, 3), let c = pdfColour(v) { pdfReader(info).state.fill = c } }
        on("RG") { s, info in if let v = pdfNumbers(s, 3), let c = pdfColour(v) { pdfReader(info).state.stroke = c } }
        on("k") { s, info in if let v = pdfNumbers(s, 4), let c = pdfColour(v) { pdfReader(info).state.fill = c } }
        on("K") { s, info in if let v = pdfNumbers(s, 4), let c = pdfColour(v) { pdfReader(info).state.stroke = c } }
        for name in ["sc", "scn"] {
            on(name) { s, info in
                let r = pdfReader(info)
                guard let v = pdfAllNumbers(s), let c = pdfColour(v) else { r.failed = true; return }
                r.state.fill = c
            }
        }
        for name in ["SC", "SCN"] {
            on(name) { s, info in
                let r = pdfReader(info)
                guard let v = pdfAllNumbers(s), let c = pdfColour(v) else { r.failed = true; return }
                r.state.stroke = c
            }
        }
        // Text, pictures, shadings, inline images and dashes: not followed.
        for name in ["BT", "Do", "sh", "BI", "d0", "d1"] { on(name) { _, info in pdfReader(info).failed = true } }
        on("d") { s, info in
            var array: CGPDFArrayRef?
            var phase: CGPDFReal = 0
            _ = CGPDFScannerPopNumber(s, &phase)
            if CGPDFScannerPopArray(s, &array), let array, CGPDFArrayGetCount(array) > 0 { pdfReader(info).failed = true }
        }
    }
}

private func pdfReader(_ info: UnsafeMutableRawPointer?) -> PDFShapeReader {
    Unmanaged<PDFShapeReader>.fromOpaque(info!).takeUnretainedValue()
}

private func pdfNumbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [Double]? {
    var values = [Double](repeating: 0, count: count)
    for i in (0..<count).reversed() {
        var v: CGPDFReal = 0
        guard CGPDFScannerPopNumber(scanner, &v) else { return nil }
        values[i] = Double(v)
    }
    return values
}

/// All the numbers on the stack (a colour's components), or nil if there is a name (a pattern).
private func pdfAllNumbers(_ scanner: CGPDFScannerRef) -> [Double]? {
    var values: [Double] = []
    while true {
        var v: CGPDFReal = 0
        if CGPDFScannerPopNumber(scanner, &v) { values.insert(Double(v), at: 0); continue }
        var name: UnsafePointer<CChar>?
        if CGPDFScannerPopName(scanner, &name) { return nil }
        break
    }
    return values
}

private func pdfColour(_ v: [Double]) -> CGColor? {
    switch v.count {
    case 1: return VectorArt.srgb(v[0], v[0], v[0])
    case 3: return VectorArt.srgb(v[0], v[1], v[2])
    case 4: return VectorArt.srgb((1 - v[0]) * (1 - v[3]), (1 - v[1]) * (1 - v[3]), (1 - v[2]) * (1 - v[3]))
    default: return nil
    }
}
