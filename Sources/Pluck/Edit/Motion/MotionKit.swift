import AppKit
import CoreImage
import CoreText

/// The pieces Brand Pack's motion templates are built from: easing as motion designers use it,
/// text that's measured and laid out, masked reveals, and the style a user sets (fonts, colours,
/// scale, position, timing). Frames are drawn with Core Graphics (y up, origin bottom left), the
/// same for the preview and the export.

/// A colour that can be saved.
struct MotionColor: Codable, Hashable {
    var r: Double, g: Double, b: Double, a: Double = 1

    init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    init(_ color: CGColor) {
        let c = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
        r = c[0]; g = c[min(1, c.count - 1)]; b = c[min(2, c.count - 1)]; a = c.count > 3 ? c[3] : 1
    }

    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    func alpha(_ value: Double) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a * value) }

    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    static let white = MotionColor(r: 1, g: 1, b: 1)
    static let ink = MotionColor(r: 0.07, g: 0.07, b: 0.08)
}

/// What the user sets for their brand (shared by every template), and for each template (its
/// texts, where it sits and how big, how long it runs).
struct MotionStyle: Codable, Hashable {
    var titleFont = "Helvetica Neue"
    var bodyFont = "Helvetica Neue"
    /// 0 light … 1 black, for the titles.
    var titleWeight = 0.75
    var accent = MotionColor(r: 1.0, g: 0.36, b: 0.42)
    /// The accent's partner, for gradients (words, plates, the background's glow).
    var accent2 = MotionColor(r: 0.93, g: 0.13, b: 0.38)
    var secondary = MotionColor(r: 0.09, g: 0.09, b: 0.11)
    var text = MotionColor.white
    /// Behind the full-frame cards (nil: see-through).
    var background: MotionColor? = MotionColor(r: 0.06, g: 0.06, b: 0.07)
    /// Rounded corners on plates and buttons: 0 square … 1 fully round.
    var roundness = 0.25
    /// Behind the cards: a flat colour, or the colours drifting (a glow that moves).
    var moving = true
    /// A soft glow around what's in the brand colour (0 … 1).
    var glow = 0.6
    /// Film grain over the cards.
    var grain = true
}

/// One template's own settings.
struct MotionPlacement: Codable, Hashable {
    /// Where the graphic's anchor is, as shares of the frame from the bottom left.
    var x: Double
    var y: Double
    var scale = 1.0
    var duration: Double
    /// Animations faster (> 1) or slower.
    var speed = 1.0
    var texts: [String: String] = [:]
    /// Text aligned left, centred or right (for templates that can).
    var align = MotionAlign.left
}

enum MotionAlign: String, Codable, CaseIterable, Identifiable {
    case left, center, right
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        }
    }
}

// MARK: - Easing

enum Ease {
    static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }

    /// How far through a stretch of time: 0 before `start`, 1 after `start + length`.
    static func phase(_ t: Double, _ start: Double, _ length: Double) -> Double {
        length <= 0 ? (t >= start ? 1 : 0) : clamp((t - start) / length)
    }

    /// Fast then settling: the curve most motion design leans on (an exponential out).
    static func outExpo(_ x: Double) -> Double { x >= 1 ? 1 : 1 - pow(2, -10 * clamp(x)) }
    static func outCubic(_ x: Double) -> Double { 1 - pow(1 - clamp(x), 3) }
    static func outQuint(_ x: Double) -> Double { 1 - pow(1 - clamp(x), 5) }
    static func inOutCubic(_ x: Double) -> Double {
        let x = clamp(x)
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }
    static func inCubic(_ x: Double) -> Double { pow(clamp(x), 3) }
    /// A small overshoot that settles (no bouncing).
    static func outBack(_ x: Double, _ amount: Double = 1.3) -> Double {
        let x = clamp(x), c3 = amount + 1
        return 1 + c3 * pow(x - 1, 3) + amount * pow(x - 1, 2)
    }
    static func lerp(_ a: Double, _ b: Double, _ p: Double) -> Double { a + (b - a) * p }

    /// A spring from 0 to 1 (it can overshoot and settle), `t` seconds after it lets go, as
    /// Remotion's and After Effects' springs: a mass on a damped spring.
    static func spring(_ t: Double, damping: Double = 14, stiffness: Double = 160, mass: Double = 1) -> Double {
        guard t > 0 else { return 0 }
        let omega = sqrt(stiffness / mass), zeta = damping / (2 * sqrt(stiffness * mass))
        if zeta < 1 {
            let wd = omega * sqrt(1 - zeta * zeta)
            return 1 - exp(-zeta * omega * t) * (cos(wd * t) + zeta * omega / wd * sin(wd * t))
        }
        return 1 - exp(-omega * t) * (1 + omega * t)
    }
}

/// When a graphic is coming in, holding, or going out: the intro plays forwards, the outro is the
/// intro played back (sped up), as motion designers mirror them.
struct MotionClock {
    let t: Double
    let duration: Double
    let speed: Double

    /// A spring let go at `start` (seconds at normal speed), mirrored out at the end like `part`.
    func spring(_ start: Double, damping: Double = 14, stiffness: Double = 160) -> Double {
        let s = max(speed, 0.1)
        let inP = Ease.spring(t * s - start, damping: damping, stiffness: stiffness)
        let fromEnd = (duration - t) * s * 1.4
        let outP = Ease.outExpo(Ease.phase(fromEnd, start * 0.6, 0.5))
        return min(inP, outP)
    }

    /// Progress of a part of the intro (its start and length in seconds at normal speed),
    /// with the same part mirrored out at the end.
    func part(_ start: Double, _ length: Double, outro: Bool = true) -> Double {
        let s = max(speed, 0.1)
        let inP = Ease.phase(t * s, start, length)
        guard outro else { return inP }
        // Out: the same, backwards, over the last stretch (quicker than in).
        let fromEnd = (duration - t) * s * 1.4
        let outP = Ease.phase(fromEnd, start * 0.6, length)
        return min(inP, outP)
    }
}

// MARK: - Text

/// One line of text, set and measured (Core Text).
struct MotionText {
    let line: CTLine
    let width: Double
    let ascent: Double
    let descent: Double
    let string: String
    let font: CTFont
    let color: CGColor
    let tracking: Double
    let family: String
    let size: Double
    let weight: Double

    var height: Double { ascent + descent }

    init(_ string: String, family: String, size: Double, weight: Double = 0.5, color: CGColor, tracking: Double = 0, uppercase: Bool = false) {
        let shown = uppercase ? string.uppercased() : string
        self.string = shown
        self.color = color
        self.tracking = tracking
        self.family = family
        self.size = size
        self.weight = weight
        font = Self.font(family: family, size: size, weight: weight)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .kern: tracking * size,
        ]
        line = CTLineCreateWithAttributedString(NSAttributedString(string: shown, attributes: attributes))
        var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
        width = CTLineGetTypographicBounds(line, &a, &d, &l)
        ascent = a
        descent = d
    }

    /// The family at a weight (its nearest face), or the system font when it isn't installed.
    static func font(family: String, size: Double, weight: Double) -> CTFont {
        let w = NSFont.Weight(rawValue: Ease.lerp(-0.6, 0.62, Ease.clamp(weight)))
        let traits: [NSFontDescriptor.TraitKey: Any] = [.weight: w]
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family, .traits: traits])
        if let font = NSFont(descriptor: descriptor, size: size), font.familyName == family { return font as CTFont }
        return NSFont.systemFont(ofSize: size, weight: w) as CTFont
    }

    /// Drawn with its baseline at `point`.
    func draw(at point: CGPoint, in context: CGContext, alpha: Double = 1) {
        guard alpha > 0.001 else { return }
        context.saveGState()
        if alpha < 0.999 { context.setAlpha(alpha) }
        context.textPosition = point
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// The words and letters in the text's own font.
    var words: [(text: MotionText, x: Double)] { words(family: family, size: size, weight: weight) }
    var letters: [(text: MotionText, x: Double)] { letters(family: family, size: size, weight: weight) }

    /// The same text in another colour.
    func colored(_ color: CGColor) -> MotionText {
        MotionText(string, family: family, size: size, weight: weight, color: color, tracking: tracking)
    }

    /// The words, each set on its own (for word-by-word animation), with where each starts.
    func words(family: String, size: Double, weight: Double) -> [(text: MotionText, x: Double)] {
        var x = 0.0
        let space = MotionText(" ", family: family, size: size, weight: weight, color: color, tracking: tracking).width
        return string.split(separator: " ").map { word in
            let piece = MotionText(String(word), family: family, size: size, weight: weight, color: color, tracking: tracking)
            defer { x += piece.width + space }
            return (piece, x)
        }
    }

    /// The letters, each set on its own, with where each starts (kerning kept from the line).
    func letters(family: String, size: Double, weight: Double) -> [(text: MotionText, x: Double)] {
        var result: [(MotionText, Double)] = []
        for (index, character) in string.enumerated() where character != " " {
            let prefix = String(string.prefix(index))
            let x = MotionText(prefix, family: family, size: size, weight: weight, color: color, tracking: tracking).width
            result.append((MotionText(String(character), family: family, size: size, weight: weight, color: color, tracking: tracking), x))
        }
        return result
    }
}

// MARK: - Drawing

enum MotionDraw {
    /// A rounded rectangle (`round` 0 square … 1 a full capsule).
    static func plate(_ rect: CGRect, round: Double, color: CGColor, in context: CGContext) {
        guard rect.width > 0.5, rect.height > 0.5 else { return }
        let radius = min(rect.height, rect.width) / 2 * Ease.clamp(round)
        context.setFillColor(color)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }

    /// Text rising into view from below an edge it's masked by (`p` 0 hidden … 1 in place).
    static func rise(_ text: MotionText, at point: CGPoint, progress p: Double, in context: CGContext, from: Double = 1.1) {
        guard p > 0.001 else { return }
        context.saveGState()
        let mask = CGRect(x: point.x - text.height, y: point.y - text.descent - 2, width: text.width + text.height * 2, height: text.height + 4)
        context.clip(to: mask)
        text.draw(at: CGPoint(x: point.x, y: point.y - (1 - p) * text.height * from), in: context)
        context.restoreGState()
    }

    /// Text dropping into view from above an edge it's masked by.
    static func drop(_ text: MotionText, at point: CGPoint, progress p: Double, in context: CGContext) {
        guard p > 0.001 else { return }
        context.saveGState()
        let mask = CGRect(x: point.x - text.height, y: point.y - text.descent - 2, width: text.width + text.height * 2, height: text.height + 4)
        context.clip(to: mask)
        text.draw(at: CGPoint(x: point.x, y: point.y + (1 - p) * text.height * 1.1), in: context)
        context.restoreGState()
    }

    /// Words rising one after another (`stagger` seconds apart at normal speed).
    static func risingWords(_ text: MotionText, family: String, size: Double, weight: Double, at point: CGPoint,
                            clock: MotionClock, start: Double, stagger: Double, length: Double, in context: CGContext) {
        for (index, word) in text.words(family: family, size: size, weight: weight).enumerated() {
            let p = Ease.outExpo(clock.part(start + Double(index) * stagger, length))
            rise(word.text, at: CGPoint(x: point.x + word.x, y: point.y), progress: p, in: context)
        }
    }

    /// A line drawn from one end (`p` 0 … 1).
    static func line(from a: CGPoint, to b: CGPoint, width: Double, color: CGColor, progress p: Double, in context: CGContext) {
        guard p > 0.001 else { return }
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.setLineCap(.butt)
        context.move(to: a)
        context.addLine(to: CGPoint(x: a.x + (b.x - a.x) * p, y: a.y + (b.y - a.y) * p))
        context.strokePath()
    }

    /// The x where a block of this width starts, aligned around an anchor.
    static func start(_ width: Double, at x: Double, align: MotionAlign) -> Double {
        switch align {
        case .left: x
        case .center: x - width / 2
        case .right: x - width
        }
    }
}

// MARK: - Light, colour and grain

extension MotionDraw {
    /// Text filled with a gradient from one colour to the other (left to right, a little down).
    static func gradientText(_ text: MotionText, at point: CGPoint, from: CGColor, to: CGColor, alpha: Double = 1, in context: CGContext) {
        guard alpha > 0.001 else { return }
        context.saveGState()
        if alpha < 0.999 { context.setAlpha(alpha) }
        context.textPosition = point
        context.setTextDrawingMode(.clip)
        CTLineDraw(text.line, context)
        let colors = [from, to] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: point.x, y: point.y + text.ascent),
                                       end: CGPoint(x: point.x + text.width, y: point.y - text.descent), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        context.restoreGState()
    }

    /// A rounded plate filled with the brand's gradient.
    static func gradientPlate(_ rect: CGRect, round: Double, from: CGColor, to: CGColor, in context: CGContext) {
        guard rect.width > 0.5, rect.height > 0.5 else { return }
        let radius = min(rect.height, rect.width) / 2 * Ease.clamp(round)
        context.saveGState()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [from, to] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
        }
        context.restoreGState()
    }

    /// Whatever `body` draws, with a soft glow of a colour around it.
    static func glowing(_ color: CGColor, radius: Double, in context: CGContext, _ body: () -> Void) {
        guard radius > 0.5 else { body(); return }
        context.saveGState()
        context.setShadow(offset: .zero, blur: radius, color: color)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private static let blurContext = CIContext(options: [.cacheIntermediates: false])

    /// Text coming into focus: drawn blurred by `radius` points (as the launch video's words do).
    static func blurredText(_ text: MotionText, at point: CGPoint, radius: Double, alpha: Double, in context: CGContext,
                            gradient: (CGColor, CGColor)? = nil) {
        guard alpha > 0.001 else { return }
        let device = context.userSpaceToDeviceSpaceTransform
        let deviceScale = max(sqrt(abs(device.a * device.d - device.b * device.c)), 0.0001)
        let pixels = radius * deviceScale
        guard pixels > 0.6 else {
            if let gradient { gradientText(text, at: point, from: gradient.0, to: gradient.1, alpha: alpha, in: context) }
            else { text.draw(at: point, in: context, alpha: alpha) }
            return
        }
        // Drawn on its own, blurred, and put in place.
        let pad = radius * 3
        let bounds = CGRect(x: point.x - pad, y: point.y - text.descent - pad, width: text.width + pad * 2, height: text.height + pad * 2)
        let w = Int(ceil(bounds.width * deviceScale)), h = Int(ceil(bounds.height * deviceScale))
        guard w > 0, h > 0, w * h < 40_000_000,
              let layer = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        layer.scaleBy(x: deviceScale, y: deviceScale)
        layer.translateBy(x: -bounds.minX, y: -bounds.minY)
        if let gradient { gradientText(text, at: point, from: gradient.0, to: gradient.1, in: layer) } else { text.draw(at: point, in: layer) }
        guard let image = layer.makeImage() else { return }
        let blurred = CIImage(cgImage: image).clampedToExtent().applyingGaussianBlur(sigma: pixels / 2).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        guard let result = blurContext.createCGImage(blurred, from: CGRect(x: 0, y: 0, width: w, height: h)) else { return }
        context.saveGState()
        context.setAlpha(alpha)
        context.draw(result, in: bounds)
        context.restoreGState()
    }
}

/// Behind the cards: the brand's colours drifting as soft lights over a deep base, light bands
/// sweeping slowly, a vignette and film grain (the launch video's backdrop, in any colours).
enum MotionBackground {
    static func draw(_ style: MotionStyle, base: MotionColor, t: Double, canvas: CGSize, in context: CGContext) {
        context.setFillColor(base.cg)
        context.fill(CGRect(origin: .zero, size: canvas))
        guard style.moving else { return }
        // Soft lights look the same drawn small and scaled up: a quarter of the size, four times
        // over, is far quicker.
        let small = CGSize(width: max(canvas.width / 4, 2), height: max(canvas.height / 4, 2))
        guard let layer = CGContext(data: nil, width: Int(small.width), height: Int(small.height), bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        layer.setFillColor(base.cg)
        layer.fill(CGRect(origin: .zero, size: small))
        lights(style, t: t, canvas: small, in: layer)
        if let image = layer.makeImage() {
            context.saveGState()
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(origin: .zero, size: canvas))
            context.restoreGState()
        }
    }

    private static func lights(_ style: MotionStyle, t: Double, canvas: CGSize, in context: CGContext) {
        let w = canvas.width, h = canvas.height, f = t * 18
        func blob(_ color: MotionColor, _ size: Double, _ x: Double, _ y: Double, _ alpha: Double) {
            let r = size * min(w, h) / 1080 / 2
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                            colors: [color.alpha(alpha), color.alpha(alpha * 0.55), color.alpha(alpha * 0.18), color.alpha(0)] as CFArray,
                                            locations: [0, 0.35, 0.68, 1]) else { return }
            context.drawRadialGradient(gradient, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: r, options: [])
        }
        let deep = MotionColor(r: style.accent2.r * 0.45 + 0.08, g: style.accent2.g * 0.2, b: style.accent2.b * 0.5 + 0.25)
        blob(style.accent2, 2000, w * 0.78 + sin(f / 70) * w * 0.11, h * 0.77 + cos(f / 90) * h * 0.13, 0.31)
        blob(deep, 2200, w * 0.18 + cos(f / 85) * w * 0.12, h * 0.21 + sin(f / 60) * h * 0.11, 0.4)
        blob(MotionColor(r: 0.23, g: 0.17, b: 0.85), 1800, w * 0.47 + sin(f / 110) * w * 0.18, h * -0.06 + cos(f / 75) * h * 0.08, 0.24)
        blob(style.accent, 1300, w * 0.16 + sin(f / 95) * w * 0.1, h * 0.9 + sin(f / 50) * h * 0.05, 0.17)
        // Light bands drifting across.
        for (offset, speed, alpha) in [(0.0, 3.2, 0.05), (1500.0, 2.1, 0.035)] {
            let x = -600 + (offset + f * speed * 3).truncatingRemainder(dividingBy: 3400)
            context.saveGState()
            context.translateBy(x: x * w / 1920, y: h / 2)
            context.rotate(by: -28 * .pi / 180)
            let bw = 520 * w / 1920
            if let band = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                     colors: [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: alpha), CGColor(gray: 1, alpha: 0)] as CFArray,
                                     locations: [0, 0.5, 1]) {
                context.drawLinearGradient(band, start: CGPoint(x: -bw / 2, y: 0), end: CGPoint(x: bw / 2, y: 0), options: [])
                context.clip(to: CGRect(x: -bw / 2, y: -h * 1.5, width: bw, height: h * 3))
            }
            context.restoreGState()
        }
        // The corners darker.
        if let vignette = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                     colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.2), CGColor(gray: 0, alpha: 0.5)] as CFArray,
                                     locations: [0.4, 0.7, 1]) {
            context.drawRadialGradient(vignette, startCenter: CGPoint(x: w / 2, y: h / 2), startRadius: 0,
                                       endCenter: CGPoint(x: w / 2, y: h / 2), endRadius: hypot(w, h) / 2, options: [.drawsAfterEndLocation])
        }
    }

    /// Film grain over everything, a new pattern each frame.
    static func grain(t: Double, canvas: CGSize, in context: CGContext) {
        guard let noise = noise else { return }
        let frame = Int(t * 24) % 24
        context.saveGState()
        // (Plain blending at a low strength: an overlay blend over the whole frame is slow.)
        context.setAlpha(0.045)
        context.interpolationQuality = .none
        let tile = 512.0 * min(canvas.width, canvas.height) / 1080
        let shift = Double(frame) * 37
        var y = -shift.truncatingRemainder(dividingBy: tile)
        while y < canvas.height {
            var x = -(shift * 1.7).truncatingRemainder(dividingBy: tile)
            while x < canvas.width {
                context.draw(noise, in: CGRect(x: x, y: y, width: tile, height: tile))
                x += tile
            }
            y += tile
        }
        context.restoreGState()
    }

    private static let noise: CGImage? = {
        let size = 256
        var pixels = [UInt8](repeating: 0, count: size * size)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for i in pixels.indices {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            pixels[i] = UInt8(truncatingIfNeeded: seed >> 56)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }()
}
