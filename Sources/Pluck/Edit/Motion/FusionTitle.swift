import AppKit

/// Which of the brand's colours something takes; linked to the title's colour controls in Resolve.
enum FusionInk: Equatable {
    case accent, plate, text
    /// A colour of its own (not linked).
    case fixed(MotionColor)
    /// The node input (on the colours node) that holds it.
    var corner: String {
        switch self {
        case .accent: "TopLeft"
        case .plate: "BottomLeft"
        case .text, .fixed: "BottomRight"
        }
    }
}

/// How a plate is filled.
enum FusionFill {
    case ink(FusionInk, Double)
    /// The brand's gradient, top left to bottom right.
    case gradient
}

/// A Brand Pack template rebuilt from Fusion nodes: Text+ with Followers for the words, plates
/// on masks, glows from blurs, all merged in order. Points are where the template draws them:
/// pixels around the template's anchor, up from the bottom.
final class FusionTitle {
    let graph: FusionGraph
    let template: MotionTemplate
    let style: MotionStyle
    let placement: MotionPlacement
    let canvas: CGSize
    /// One unit: a pixel on a 1080-pixel short side.
    let u: Double
    let anchor: CGPoint
    /// The picture so far.
    private(set) var stack: String
    private let clear: String
    private let colors = "Brand"
    private let gradientNode = "BrandGradient"
    private var fontControls: Set<String> = []
    /// Extra widths for plates sized to their text, each a slider on the colours node.
    private var grows: [(id: String, label: String)] = []

    init(_ template: MotionTemplate, style: MotionStyle, placement: MotionPlacement, canvas: CGSize, fps: Double) {
        self.template = template
        self.style = style
        self.placement = placement
        self.canvas = canvas
        u = min(canvas.width, canvas.height) / 1080
        anchor = CGPoint(x: placement.x * canvas.width, y: placement.y * canvas.height)
        graph = FusionGraph(canvas: canvas, fps: fps, duration: placement.duration, speed: placement.speed)
        clear = graph.add("Background", "Clear", [("TopLeftAlpha", .number(0))], named: true)
        stack = clear
        graph.add("PublishGradient", gradientNode, [("Value", .raw(Self.gradient(style.accent, style.accent2)))], named: true)
    }

    /// A slider (in Resolve) for how much wider than the text typed here a plate is; returns
    /// the expression that reads it.
    func grow(_ label: String) -> String {
        let id = "Grow\(grows.count + 1)"
        grows.append((id, label))
        return "\(colors).\(id)"
    }

    private static func gradient(_ a: MotionColor, _ b: MotionColor) -> String {
        "Gradient { Colors = { [0] = { \(a.r), \(a.g), \(a.b), 1 }, [1] = { \(b.r), \(b.g), \(b.b), 1 } } }"
    }

    // MARK: Pieces

    /// A point the template draws at, in the frame's units.
    func unit(_ p: CGPoint) -> CGPoint { graph.unit(CGPoint(x: anchor.x + p.x, y: anchor.y + p.y)) }

    /// A colour's inputs. Backgrounds take theirs premultiplied (`premultiplied`): the colour
    /// times its alpha.
    private func ink(_ ink: FusionInk, prefix: String, suffix: String = "", alpha: Double = 1, premultiplied: Bool = false) -> [(String, FusionValue)] {
        let color = switch ink {
        case .accent: style.accent
        case .plate: style.secondary
        case .text: style.text
        case .fixed(let c): c
        }
        let k = premultiplied ? alpha : 1
        let channels = [("Red", color.r), ("Green", color.g), ("Blue", color.b)]
        return channels.map { name, value -> (String, FusionValue) in
            if case .fixed = ink { return ("\(prefix)\(name)\(suffix)", .number(value * k)) }
            let linked = "\(colors).\(ink.corner)\(name)"
            return ("\(prefix)\(name)\(suffix)", .expression(k < 1 ? "\(linked) * \(k)" : linked, value * k))
        } + [("\(prefix)Alpha\(suffix)", .number(alpha))]
    }

    /// A rectangle (in the template's points) as a mask, rounded by `round` (0 … 1, as plates).
    func mask(_ rect: @escaping (MotionClock) -> CGRect, round: Double = 0, inside: String? = nil) -> String {
        let w = canvas.width, h = canvas.height
        var inputs: [(String, FusionValue)] = [
            ("Center", graph.animatePoint { self.unit(CGPoint(x: rect($0).midX, y: rect($0).midY)) }),
            ("Width", graph.animate { max(rect($0).width, 0) / w }),
            ("Height", graph.animate { max(rect($0).height, 0) / h }),
        ]
        if round > 0 {
            // Fusion's corner radius: a share of the shorter side's half, as the plates' own.
            inputs.append(("CornerRadius", .number(Ease.clamp(round))))
        }
        if let inside {
            inputs += [("EffectMask", .link(inside, "Mask")), ("PaintMode", .id("Minimum"))]
        }
        return graph.add("RectangleMask", "Mask", inputs)
    }

    /// Puts an image over everything so far.
    @discardableResult
    func merge(_ image: String, blend: FusionValue = .number(1)) -> String {
        stack = graph.add("Merge", "Merge", [("Background", .link(stack)), ("Foreground", .link(image)), ("Blend", blend)])
        return stack
    }

    /// A plate (a rounded rectangle), its rectangle moving with the clock; `glow` 0 … 1, `alpha`
    /// fading it.
    /// `grow`: a slider's expression (from `grow(_:)`) widening it, from its left edge (or its
    /// middle when `centered`). Returns the plate's picture (for `clip(_:)`).
    @discardableResult
    func plate(_ rect: @escaping (MotionClock) -> CGRect, final: CGRect, round: Double, fill: FusionFill, glow: Double = 0,
               alpha: ((MotionClock) -> Double)? = nil, grow: String? = nil, centered: Bool = false) -> String {
        let shape = mask(rect, round: round)
        var plate = graph.add("Background", "Plate", [("EffectMask", .link(shape, "Mask"))] + paint(fill, over: final))
        if let grow {
            let pivot = unit(CGPoint(x: centered ? final.midX : final.minX, y: final.midY))
            plate = graph.add("Transform", "Widen", [("Input", .link(plate)), ("UseSizeAndAspect", .number(0)), ("Pivot", .point(pivot.x, pivot.y)),
                                                     ("XSize", .expression("1 + \(grow) / \(max(final.width, 1))", 1)), ("YSize", .number(1))])
        }
        put(plate, glow: glow, alpha: alpha)
        return plate
    }

    /// A mask of a picture's shape (text inside a plate, however wide the plate's been made).
    func clip(_ image: String) -> String {
        graph.add("BitmapMask", "Clip", [("Image", .link(image)), ("Channel", .id("Alpha"))])
    }

    /// A circle (or a ring `line` points wide) around a moving centre.
    func ellipse(_ center: @escaping (MotionClock) -> CGPoint, radius: @escaping (MotionClock) -> Double, line: ((MotionClock) -> Double)? = nil,
                 fill: FusionFill, glow: Double = 0, alpha: ((MotionClock) -> Double)? = nil) {
        let w = canvas.width
        var inputs: [(String, FusionValue)] = [
            ("Center", graph.animatePoint { self.unit(center($0)) }),
            ("Width", graph.animate { max(radius($0), 0) * 2 / w }),
            // An ellipse's height is against the frame's width too.
            ("Height", graph.animate { max(radius($0), 0) * 2 / w }),
        ]
        if let line {
            inputs += [("Solid", .number(0)), ("BorderWidth", graph.animate { line($0) / w })]
        }
        let shape = graph.add("EllipseMask", "Circle", inputs)
        let r = radius(MotionClock(t: placement.duration / 2, duration: placement.duration, speed: placement.speed))
        let c = center(MotionClock(t: placement.duration / 2, duration: placement.duration, speed: placement.speed))
        let disc = graph.add("Background", "Circle", [("EffectMask", .link(shape, "Mask"))]
                             + paint(fill, over: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)))
        put(disc, glow: glow, alpha: alpha)
    }

    private func paint(_ fill: FusionFill, over rect: CGRect) -> [(String, FusionValue)] {
        switch fill {
        case .ink(let i, let alpha):
            return ink(i, prefix: "TopLeft", alpha: alpha, premultiplied: true)
        case .gradient:
            let start = unit(CGPoint(x: rect.minX, y: rect.maxY)), end = unit(CGPoint(x: rect.maxX, y: rect.minY))
            return [("Type", .id("Gradient")), ("GradientType", .id("Linear")),
                    ("Start", .point(start.x, start.y)), ("End", .point(end.x, end.y)),
                    ("Gradient", .link(gradientNode, "Value"))]
        }
    }

    /// Merges a shape in, with its glow (the shape blurred behind itself) when it has one.
    private func put(_ image: String, glow: Double, alpha: ((MotionClock) -> Double)?) {
        let blend = alpha.map { a in graph.animate { Ease.clamp(a($0)) } } ?? .number(1)
        if glow > 0, style.glow > 0 {
            let size = style.glow * 30 * u * glow
            let blur = graph.add("Blur", "Glow", [("Input", .link(image)), ("XBlurSize", .number(size / 2.2))])
            let bright = graph.add("BrightnessContrast", "Glow", [("Input", .link(blur)), ("Gain", .number(1.6))])
            merge(bright, blend: blend)
        }
        merge(image, blend: blend)
    }

    /// A rectangle mask turned by `angle` degrees, its centre moving (points around the anchor).
    func graphMask(center: @escaping (MotionClock) -> CGPoint, size: CGSize, angle: Double) -> String {
        graph.add("RectangleMask", "Mask", [("Center", graph.animatePoint { self.unit(center($0)) }),
                                            ("Width", .number(size.width / canvas.width)), ("Height", .number(size.height / canvas.height)),
                                            ("Angle", .number(angle))])
    }

    /// The brand's gradient from one point to another, inside a mask.
    func panel(_ mask: String, from a: CGPoint, to b: CGPoint) {
        let start = unit(a), end = unit(b)
        merge(graph.add("Background", "Panel", [("EffectMask", .link(mask, "Mask")), ("Type", .id("Gradient")), ("GradientType", .id("Linear")),
                                                 ("Start", .point(start.x, start.y)), ("End", .point(end.x, end.y)),
                                                 ("Gradient", .link(gradientNode, "Value"))]))
    }

    /// Builds what `body` adds as a picture of its own, then puts it in scaled around `point`
    /// (and faded by `alpha`).
    func group(around point: CGPoint, scale: @escaping (MotionClock) -> Double, alpha: ((MotionClock) -> Double)? = nil, _ body: () -> Void) {
        let outer = stack
        stack = clear
        body()
        let pivot = unit(point)
        let scaled = graph.add("Transform", "Group", [("Input", .link(stack)), ("Pivot", .point(pivot.x, pivot.y)),
                                                      ("Size", graph.animate { max(scale($0), 0.0001) })])
        stack = outer
        merge(scaled, blend: alpha.map { a in graph.animate { Ease.clamp(a($0)) } } ?? .number(1))
    }

    /// Where a letter (or word) is, from its own start: moved (points), opacity, blur, size.
    struct Pose {
        var dx = 0.0, dy = 0.0, alpha = 1.0, blur = 0.0, scale = 1.0
    }

    /// How each letter (or word) comes in.
    struct Motion {
        /// Seconds (at normal speed) between letters, or words when `byWord`.
        var stagger = 0.0
        var byWord = false
        var move: (MotionClock) -> Pose
    }

    /// Text with its (last line's) baseline at `at`, starting there (`anchored`: aligned around
    /// it as `align` says), filled with a brand colour or the gradient, moving as `motion` says.
    /// `field`: the template's text it shows, which gets a control of its own (`label` names
    /// one that isn't a field). `lines`: more than one line, `lineHeight` apart. `writeOn`: how
    /// much of it shows (0 … 1). `body`: in the body font (else the titles').
    @discardableResult
    func text(_ field: String?, _ t: MotionText, at p: CGPoint, align: MotionAlign = .left, anchored: Bool = false, ink inkColor: FusionInk = .text,
              alpha: Double = 1, gradient: Bool = false, clip: String? = nil, motion: Motion, tracking: ((MotionClock) -> Double)? = nil,
              lines: [String]? = nil, lineHeight: Double? = nil, writeOn: ((MotionClock) -> Double)? = nil, label: String? = nil,
              font fontName: (family: String, face: String)? = nil, angle: Double = 0, shift: String? = nil, body: Bool = false) -> String {
        let font = t.font
        let family = fontName?.family ?? CTFontCopyFamilyName(font) as String
        let face = fontName?.face ?? (CTFontCopyName(font, kCTFontStyleNameKey) as String?) ?? "Regular"
        // Fusion sizes text by its line (ascent, descent and gap), against the frame's width.
        let line = (CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)) / t.size
        let size = t.size * 1.225 * line / canvas.width
        let spacing = { (tracking: Double) in 1 + tracking / (1.225 * line) }
        let w = canvas.width
        let speed = max(placement.speed, 0.1)
        let string = lines?.joined(separator: "\n") ?? t.string
        var perLetter = motion.stagger
        if motion.byWord {
            let words = max(string.split(whereSeparator: { $0 == " " || $0 == "\n" }).count, 1)
            perLetter = motion.stagger * Double(words) / Double(max(string.count, 1))
        }
        var follow: [(String, FusionValue)] = [
            ("Text", .text(string)),
            ("Order", .number(0)),
            ("Delay", .number(perLetter * graph.fps / speed)),
            ("CharacterOffset", graph.animatePoint { let m = motion.move($0); return CGPoint(x: m.dx / w, y: m.dy / w) }),
            ("Opacity1", graph.animate { motion.move($0).alpha }),
            ("SoftnessX1", graph.animate { motion.move($0).blur / w * 100 }),
            ("SoftnessY1", graph.animate { motion.move($0).blur / w * 100 }),
        ]
        let scale = graph.animate { motion.move($0).scale }
        if case .keys = scale { follow += [("CharacterSizeX", scale), ("CharacterSizeY", scale)] }
        let follower = graph.add("StyledTextFollower", "Letters", follow)
        let lead = switch align {
        case .left: 0.0
        case .center: t.width / 2
        case .right: t.width
        }
        let x = anchored ? p.x : p.x + lead
        // One line: on its baseline. More: Fusion centres the block, the middle between the first
        // and last baselines half the ascent less the descent below its centre.
        let count = Double(lines?.count ?? 1)
        let y = count > 1 ? p.y + (count - 1) * (lineHeight ?? t.size) / 2 + (CTFontGetAscent(font) - CTFontGetDescent(font)) / 2 : p.y
        let center = unit(CGPoint(x: x, y: y))
        var inputs: [(String, FusionValue)] = [
            ("StyledText", .link(follower, "StyledText")),
            ("Font", .text(family)), ("Style", .text(face)),
            ("Size", .number(size)),
            ("Center", shift.map { FusionValue.pointExpression("Point(\(center.x) + \($0) / \(canvas.width), \(center.y))", center.x, center.y) } ?? .point(center.x, center.y)),
            ("CenterOnBaseOfFirstLine", .number(count > 1 ? 0 : 1)),
            ("HorizontalLeftCenterRight", .number(align == .left ? -1 : align == .right ? 1 : 0)),
            ("CharacterSpacing", tracking.map { f in graph.animate { spacing(f($0)) } } ?? .number(spacing(t.tracking))),
            ("SoftnessOnFillColorToo1", .number(1)),
        ]
        if let lineHeight { inputs.append(("LineSpacing", .number(lineHeight / (t.size * line)))) }
        if angle != 0 { inputs.append(("AngleZ", .number(angle))) }
        if let writeOn { inputs.append(("End", graph.animate { Ease.clamp(writeOn($0)) })) }
        if gradient {
            inputs += [("Type1", .number(2)), ("ShadingGradient1", .link(gradientNode, "Value")), ("ShadingMapping1", .number(2)),
                       ("ShadingMappingAngle1", .number(-20)), ("Alpha1", .number(alpha))]
        } else {
            inputs += ink(inkColor, prefix: "", suffix: "1", alpha: alpha)
        }
        if let clip { inputs.append(("EffectMask", .link(clip, "Mask"))) }
        let node = graph.add("TextPlus", "Text", inputs)
        if let name = label ?? field.flatMap({ key in template.fields.first(where: { $0.key == key })?.label }) {
            graph.control(follower, "Text", name)
        }
        if fontName == nil {
            let role = body ? String(localized: "Body Font") : String(localized: "Title Font")
            if !fontControls.contains(role) {
                fontControls.insert(role)
                graph.control(node, "Font", role, group: body ? 21 : 20)
                graph.control(node, "Style", nil, group: body ? 21 : 20)
            }
        }
        merge(node)
        return node
    }

    // MARK: The usual motions

    /// Rising into view from below an edge it's masked by (as `MotionDraw.rise`).
    func rise(_ field: String?, _ t: MotionText, at p: CGPoint, start: Double, length: Double, align: MotionAlign = .left, ink: FusionInk = .text,
              alpha: Double = 1, inside: String? = nil, drop: Bool = false, gradient: Bool = false, body: Bool = false) {
        // Only its top and bottom edges matter: wide, for text longer than what was typed here.
        let edge = mask({ _ in CGRect(x: p.x - self.canvas.width * 2, y: p.y - t.descent - 2, width: self.canvas.width * 4, height: t.height + 4) }, inside: inside)
        text(field, t, at: p, align: align, ink: ink, alpha: alpha, gradient: gradient, clip: edge, motion: Motion { c in
            let q = Ease.outExpo(c.part(start, length))
            return Pose(dy: (drop ? 1 : -1) * (1 - q) * t.height * 1.1, alpha: q > 0.001 ? 1 : 0)
        }, body: body)
    }

    /// Coming into focus: out of a blur, up a little and fading in (as `MotionDraw.blurredText`).
    func focus(_ field: String?, _ t: MotionText, at p: CGPoint, start: Double, length: Double = 0.6, stagger: Double = 0, byWord: Bool = true,
               rise: Double = 20, slide: Double = 0, blur: Double = 12, align: MotionAlign = .left, anchored: Bool = false, ink: FusionInk = .text,
               alpha: Double = 1, gradient: Bool = false, tracking: ((MotionClock) -> Double)? = nil, lines: [String]? = nil, lineHeight: Double? = nil,
               body: Bool = false) {
        text(field, t, at: p, align: align, anchored: anchored, ink: ink, alpha: alpha, gradient: gradient, motion: Motion(stagger: stagger, byWord: byWord) { c in
            let q = Ease.outExpo(c.part(start, length))
            return Pose(dx: -(1 - q) * slide * self.u, dy: -(1 - q) * rise * self.u, alpha: q, blur: (1 - q) * blur * self.u)
        }, tracking: tracking, lines: lines, lineHeight: lineHeight, body: body)
    }

    /// Words coming in one after another out of a blur, rising (as `MotionScene.wordsIn`).
    func words(_ field: String?, _ t: MotionText, at p: CGPoint, start: Double, stagger: Double = 0.1, length: Double = 0.45, align: MotionAlign = .left,
               anchored: Bool = false, gradient: Bool = false, lines: [String]? = nil, lineHeight: Double? = nil, ink: FusionInk = .text) {
        text(field, t, at: p, align: align, anchored: anchored, ink: ink, gradient: gradient, motion: Motion(stagger: stagger, byWord: true) { c in
            let q = Ease.outExpo(c.part(start, length))
            return Pose(dy: -(1 - q) * 50 * self.u, alpha: q, blur: (1 - q) * 14 * self.u)
        }, lines: lines, lineHeight: lineHeight)
    }

    // MARK: Finishing

    /// The finished macro: the graphic placed and sized (with controls for both), over the
    /// brand's moving background on the full-frame cards.
    func finish(title: String) -> String {
        // The brand's colours (and the plates' sliders), on a node of their own every other one links to.
        var inputs: [(String, FusionValue)] = []
        for (ink, color) in [(FusionInk.accent, style.accent), (.plate, style.secondary), (.text, style.text)] {
            inputs += [("\(ink.corner)Red", .number(color.r)), ("\(ink.corner)Green", .number(color.g)), ("\(ink.corner)Blue", .number(color.b))]
        }
        graph.add("Background", colors, inputs + grows.map { ($0.id, .number(0)) }, named: true, sliders: grows)
        let pivot = graph.unit(anchor)
        var out = graph.add("Transform", "Place", [("Input", .link(stack)), ("Pivot", .point(pivot.x, pivot.y)), ("Size", .number(placement.scale))])
        graph.control(out, "Center", String(localized: "Position"))
        graph.control(out, "Size", String(localized: "Size"))
        if template.fullFrame {
            // The camera pushes in slowly over the whole card.
            out = graph.add("Transform", "Push", [("Input", .link(out)), ("Size", graph.animate { c in 1 + 0.045 * Ease.clamp(c.t / max(self.placement.duration, 0.1)) })])
            if let base = style.background {
                out = card(over: base, graphic: out)
            }
        }
        for (ink, label) in [(FusionInk.accent, String(localized: "Accent")), (.plate, String(localized: "Plate")), (.text, String(localized: "Text"))] {
            let group = ink == .accent ? 10 : ink == .plate ? 11 : 12
            graph.control(colors, "\(ink.corner)Red", label, group: group)
            graph.control(colors, "\(ink.corner)Green", nil, group: group)
            graph.control(colors, "\(ink.corner)Blue", nil, group: group)
        }
        graph.control(gradientNode, "Value", String(localized: "Gradient"))
        for slider in grows { graph.control(colors, slider.id, slider.label) }
        return graph.macro(title: title, output: out)
    }

    /// The card's backdrop: the base colour with the brand's lights drifting, a vignette, a bloom
    /// as it starts and grain, the graphic over it.
    private func card(over base: MotionColor, graphic: String) -> String {
        let w = canvas.width, h = canvas.height
        stack = graph.add("Background", "Card", [("TopLeftRed", .number(base.r)), ("TopLeftGreen", .number(base.g)), ("TopLeftBlue", .number(base.b))])
        graph.control(stack, "TopLeftRed", String(localized: "Background"), group: 13)
        graph.control(stack, "TopLeftGreen", nil, group: 13)
        graph.control(stack, "TopLeftBlue", nil, group: 13)
        if style.moving {
            let deep = MotionColor(r: style.accent2.r * 0.45 + 0.08, g: style.accent2.g * 0.2, b: style.accent2.b * 0.5 + 0.25)
            let lights: [(MotionColor, Double, Double, (Double) -> CGPoint)] = [
                (style.accent2, 2000, 0.31, { f in CGPoint(x: w * 0.78 + sin(f / 70) * w * 0.11, y: h * 0.77 + cos(f / 90) * h * 0.13) }),
                (deep, 2200, 0.4, { f in CGPoint(x: w * 0.18 + cos(f / 85) * w * 0.12, y: h * 0.21 + sin(f / 60) * h * 0.11) }),
                (MotionColor(r: 0.23, g: 0.17, b: 0.85), 1800, 0.24, { f in CGPoint(x: w * 0.47 + sin(f / 110) * w * 0.18, y: h * -0.06 + cos(f / 75) * h * 0.08) }),
                (style.accent, 1300, 0.17, { f in CGPoint(x: w * 0.16 + sin(f / 95) * w * 0.1, y: h * 0.9 + sin(f / 50) * h * 0.05) }),
            ]
            for (color, size, alpha, at) in lights {
                let r = size * min(w, h) / 1080 / 2
                let light = graph.add("EllipseMask", "Light", [
                    ("Center", graph.animatePoint { c in let p = at(c.t * 18); return CGPoint(x: p.x / w, y: p.y / h) }),
                    ("Width", .number(r * 0.9 / w)), ("Height", .number(r * 0.9 / w)), ("SoftEdge", .number(r * 0.55 / w)),
                ])
                let glow = graph.add("Background", "Light", [("TopLeftRed", .number(color.r)), ("TopLeftGreen", .number(color.g)),
                                                             ("TopLeftBlue", .number(color.b)), ("EffectMask", .link(light, "Mask"))])
                merge(glow, blend: .number(alpha))
            }
            let edge = graph.add("EllipseMask", "Vignette", [("Width", .number(1.2)), ("Height", .number(1.2)), ("SoftEdge", .number(0.35)), ("Invert", .number(1))])
            let dark = graph.add("Background", "Vignette", [("TopLeftRed", .number(0)), ("TopLeftGreen", .number(0)), ("TopLeftBlue", .number(0)),
                                                             ("EffectMask", .link(edge, "Mask"))])
            merge(dark, blend: .number(0.45))
        }
        merge(graphic)
        // A soft bloom of light as it starts.
        let bloomShape = graph.add("EllipseMask", "Bloom", [("Width", .number(0.5)), ("Height", .number(0.5)), ("SoftEdge", .number(0.5))])
        let bloom = graph.add("Background", "Bloom", [("TopLeftRed", .number(1)), ("TopLeftGreen", .number(0.75)), ("TopLeftBlue", .number(0.82)),
                                                       ("EffectMask", .link(bloomShape, "Mask"))])
        merge(bloom, blend: graph.animate { c in 0.22 * (1 - Ease.outCubic(Ease.phase(c.t * self.placement.speed, 0, 0.45))) })
        if style.grain {
            stack = graph.add("FilmGrain", "Grain", [("Input", .link(stack)), ("Strength", .number(0.06)), ("Size", .number(1.2))])
        }
        return stack
    }
}
