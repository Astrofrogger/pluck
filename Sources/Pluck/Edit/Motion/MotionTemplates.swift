import AppKit
import CoreText
import ImageIO

/// A text a template shows, for the user to fill in.
struct MotionField: Identifiable, Hashable {
    let key: String
    let label: String
    let placeholder: String
    var id: String { key }
}

/// Everything a template needs to draw one frame.
struct MotionScene {
    let context: CGContext
    let canvas: CGSize
    let t: Double
    let style: MotionStyle
    let placement: MotionPlacement
    let logo: LogoAnimation?
    let logoPlan: LogoAnimation.Plan?
    let defaults: [String: String]

    /// One unit: a pixel on a 1080-pixel short side.
    var u: Double { min(canvas.width, canvas.height) / 1080 }
    var clock: MotionClock { MotionClock(t: t, duration: placement.duration, speed: placement.speed) }
    /// Seconds into the animation at its speed.
    var time: Double { t * placement.speed }
    var anchor: CGPoint { CGPoint(x: placement.x * canvas.width, y: placement.y * canvas.height) }
    var gradient: (CGColor, CGColor) { (style.accent.cg, style.accent2.cg) }
    var glow: Double { style.glow * 30 * u }

    func text(_ key: String) -> String {
        let typed = placement.texts[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return typed.isEmpty ? (defaults[key] ?? "") : typed
    }

    /// White or near black, whichever reads on a colour.
    func ink(on color: MotionColor) -> MotionColor { color.luminance > 0.55 ? .ink : .white }

    func title(_ string: String, size: Double, color: MotionColor? = nil, tracking: Double = -0.02) -> MotionText {
        MotionText(string, family: style.titleFont, size: size, weight: style.titleWeight, color: (color ?? style.text).cg, tracking: tracking)
    }

    func body(_ string: String, size: Double, color: MotionColor? = nil, alpha: Double = 1, tracking: Double = 0, uppercase: Bool = false) -> MotionText {
        MotionText(string, family: style.bodyFont, size: size, weight: 0.45, color: (color ?? style.text).alpha(alpha), tracking: tracking, uppercase: uppercase)
    }

    /// Words into lines no wider than `width`.
    func wrap(_ string: String, width: Double, make: (String) -> MotionText) -> [MotionText] {
        var lines: [MotionText] = []
        for paragraph in string.split(separator: "\n", omittingEmptySubsequences: false) {
            var current = ""
            for word in paragraph.split(separator: " ") {
                let candidate = current.isEmpty ? String(word) : current + " " + word
                if !current.isEmpty, make(candidate).width > width {
                    lines.append(make(current))
                    current = String(word)
                } else {
                    current = candidate
                }
            }
            if !current.isEmpty { lines.append(make(current)) }
        }
        return lines
    }

    /// Words coming in one after another: rising, sharpening out of a blur and fading up (as the
    /// launch video's headlines). `gradientFrom`: words from this one on in the brand's gradient.
    /// Returns how many words there were.
    @discardableResult
    func wordsIn(_ text: MotionText, at point: CGPoint, start: Double, stagger: Double = 0.1, length: Double = 0.45,
                 gradientFrom: Int? = nil, firstIndex: Int = 0) -> Int {
        let words = text.words
        for (index, word) in words.enumerated() {
            let n = firstIndex + index
            let p = Ease.outExpo(clock.part(start + Double(n) * stagger, length))
            let lit = gradientFrom.map { n >= $0 } ?? false
            MotionDraw.blurredText(word.text, at: CGPoint(x: point.x + word.x, y: point.y - (1 - p) * 50 * u), radius: (1 - p) * 14 * u,
                                   alpha: p, in: context, gradient: lit ? gradient : nil)
        }
        return words.count
    }

    /// A colour between the accent and its partner.
    func accentMix(_ p: Double) -> CGColor {
        let a = style.accent, b = style.accent2
        return CGColor(srgbRed: Ease.lerp(a.r, b.r, p), green: Ease.lerp(a.g, b.g, p), blue: Ease.lerp(a.b, b.b, p), alpha: 1)
    }
}

/// A motion template: what it shows, where it sits by default, and how it moves.
struct MotionTemplate: Identifiable, Hashable {
    enum Category: String, CaseIterable, Identifiable {
        case lowerThird, title, logo, social
        var id: String { rawValue }
        var label: String {
            switch self {
            case .lowerThird: String(localized: "Lower Thirds")
            case .title: String(localized: "Titles & Chapters")
            case .logo: String(localized: "Logo & End")
            case .social: String(localized: "Social")
            }
        }
    }

    let id: String
    let name: String
    let category: Category
    let fields: [MotionField]
    /// Fills the frame (a card on the brand's background); else over the picture.
    let fullFrame: Bool
    let placement: MotionPlacement
    let canAlign: Bool
    let draw: (MotionScene) -> Void

    static func == (a: MotionTemplate, b: MotionTemplate) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var defaults: [String: String] { Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.placeholder) }) }

    /// One frame. Cards: the moving background, a slow camera push, a bloom as it starts, grain
    /// over it all. Then the graphic at its place and size.
    func render(t: Double, in context: CGContext, canvas: CGSize, style: MotionStyle, placement: MotionPlacement,
                logo: LogoAnimation? = nil, logoPlan: LogoAnimation.Plan? = nil) {
        let card = fullFrame && style.background != nil
        if card, let base = style.background {
            MotionBackground.draw(style, base: base, t: t, canvas: canvas, in: context)
        }
        let scene = MotionScene(context: context, canvas: canvas, t: t, style: style, placement: placement, logo: logo,
                                logoPlan: logoPlan, defaults: defaults)
        context.saveGState()
        if fullFrame {
            // The camera pushes in slowly over the whole card.
            let push = 1 + 0.045 * Ease.clamp(t / max(placement.duration, 0.1))
            context.translateBy(x: canvas.width / 2, y: canvas.height / 2)
            context.scaleBy(x: push, y: push)
            context.translateBy(x: -canvas.width / 2, y: -canvas.height / 2)
        }
        // Scaled around its anchor.
        context.translateBy(x: scene.anchor.x, y: scene.anchor.y)
        context.scaleBy(x: placement.scale, y: placement.scale)
        draw(scene)
        context.restoreGState()
        if card {
            // A soft bloom of light as it starts.
            let bloom = 0.22 * (1 - Ease.outCubic(Ease.phase(t * placement.speed, 0, 0.45)))
            if bloom > 0.002, let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                                         colors: [CGColor(srgbRed: 1, green: 0.75, blue: 0.82, alpha: bloom), CGColor(gray: 1, alpha: 0)] as CFArray,
                                                         locations: [0, 1]) {
                let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
                context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: max(canvas.width, canvas.height) * 0.6, options: [])
            }
            if style.grain { MotionBackground.grain(t: t, canvas: canvas, in: context) }
        }
    }
}

// MARK: - The templates

extension MotionTemplate {
    static let all: [MotionTemplate] = [slab, editorial, pill, stack, kinetic,
                                        statement, headline, frame, chapter, split,
                                        sting, endCard,
                                        typing, features, subscribe, quote, progress, caption]

    private static let nameFields = [MotionField(key: "name", label: String(localized: "Name"), placeholder: "Alex Morgan"),
                                     MotionField(key: "role", label: String(localized: "Role"), placeholder: "Director")]

    // MARK: Lower thirds

    /// A bar in the brand's gradient springs up, a plate wipes out of it with a shine passing
    /// over, the name and role rise inside.
    static let slab = MotionTemplate(id: "slab", name: String(localized: "Slab"), category: .lowerThird, fields: nameFields, fullFrame: false,
                                     placement: MotionPlacement(x: 0.07, y: 0.12, duration: 6), canAlign: true) { s in
        let u = s.u, c = s.clock, cx = s.context
        let name = s.title(s.text("name"), size: 56 * u)
        let role = s.body(s.text("role"), size: 30 * u, alpha: 0.8)
        let pad = 28 * u, bar = 10 * u
        let plateW = max(name.width, role.width) + pad * 2, plateH = name.height + role.height + pad * 1.7
        let x0 = MotionDraw.start(plateW + bar, at: 0, align: s.placement.align)
        let pBar = max(c.spring(0, damping: 13, stiffness: 180), 0)
        MotionDraw.glowing(s.style.accent.alpha(0.8), radius: s.glow, in: cx) {
            MotionDraw.gradientPlate(CGRect(x: x0, y: 0, width: bar, height: plateH * pBar), round: 0, from: s.gradient.0, to: s.gradient.1, in: cx)
        }
        let pPlate = Ease.outExpo(c.part(0.2, 0.65))
        let plate = CGRect(x: x0 + bar, y: 0, width: plateW * pPlate, height: plateH)
        MotionDraw.plate(plate, round: s.style.roundness * 0.15, color: s.style.secondary.alpha(0.94), in: cx)
        cx.saveGState()
        cx.clip(to: plate)
        // A shine passing over once it's in.
        let shine = Ease.inOutCubic(Ease.phase(s.time, 0.9, 0.9))
        if shine > 0, shine < 1, let band = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                                        colors: [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 0.12), CGColor(gray: 1, alpha: 0)] as CFArray,
                                                        locations: [0, 0.5, 1]) {
            let x = plate.minX - 120 * u + (plateW + 240 * u) * shine
            cx.drawLinearGradient(band, start: CGPoint(x: x - 60 * u, y: 0), end: CGPoint(x: x + 60 * u, y: plateH * 0.3), options: [])
        }
        MotionDraw.rise(name, at: CGPoint(x: x0 + bar + pad, y: plateH - pad * 0.85 - name.ascent), progress: Ease.outExpo(c.part(0.38, 0.6)), in: cx)
        MotionDraw.rise(role, at: CGPoint(x: x0 + bar + pad, y: pad * 0.85 + role.descent), progress: Ease.outExpo(c.part(0.5, 0.6)), in: cx)
        cx.restoreGState()
    }

    /// A glowing line in the brand's gradient draws across; the name rises over it letter by
    /// letter, the role drops below and tightens.
    static let editorial = MotionTemplate(id: "editorial", name: String(localized: "Editorial"), category: .lowerThird, fields: nameFields,
                                          fullFrame: false, placement: MotionPlacement(x: 0.07, y: 0.16, duration: 6), canAlign: true) { s in
        let u = s.u, c = s.clock, cx = s.context
        let name = s.title(s.text("name"), size: 64 * u)
        let pRole = Ease.outExpo(c.part(0.45, 0.9))
        let role = s.body(s.text("role"), size: 26 * u, color: s.style.accent, tracking: Ease.lerp(0.45, 0.16, pRole), uppercase: true)
        let width = max(name.width, role.width) + 24 * u
        let x0 = MotionDraw.start(width, at: 0, align: s.placement.align)
        let pLine = Ease.outExpo(c.part(0, 0.8))
        let lineRect = CGRect(x: s.placement.align == .right ? x0 + width * (1 - pLine) : x0, y: -1.5 * u, width: width * pLine, height: 3 * u)
        MotionDraw.glowing(s.style.accent.alpha(0.9), radius: s.glow * 0.7, in: cx) {
            MotionDraw.gradientPlate(lineRect, round: 1, from: s.gradient.0, to: s.gradient.1, in: cx)
        }
        let nameX = MotionDraw.start(name.width, at: 0, align: s.placement.align)
        for (index, letter) in name.letters.enumerated() {
            let p = Ease.outExpo(c.part(0.25 + Double(index) * 0.025, 0.55))
            MotionDraw.rise(letter.text, at: CGPoint(x: nameX + letter.x, y: 16 * u + name.descent), progress: p, in: cx)
        }
        MotionDraw.drop(role, at: CGPoint(x: MotionDraw.start(role.width, at: 0, align: s.placement.align), y: -18 * u - role.ascent), progress: pRole, in: cx)
    }

    /// A dot springs in, stretches into a glowing pill with the name; the role slides in beside it.
    static let pill = MotionTemplate(id: "pill", name: String(localized: "Pill"), category: .lowerThird, fields: nameFields, fullFrame: false,
                                     placement: MotionPlacement(x: 0.07, y: 0.12, duration: 6), canAlign: false) { s in
        let u = s.u, c = s.clock, cx = s.context
        let ink = s.ink(on: s.style.accent)
        let name = s.title(s.text("name"), size: 44 * u, color: ink)
        let role = s.body(s.text("role"), size: 30 * u, alpha: 0.9)
        let h = name.height + 32 * u
        let pillW = name.width + h * 1.1
        let pDot = max(c.spring(0, damping: 10, stiffness: 200), 0)
        let pWide = max(c.spring(0.32, damping: 15, stiffness: 150), 0)
        let w = h + (pillW - h) * pWide
        let size = h * pDot
        let rect = CGRect(x: h / 2 - size / 2, y: h / 2 - size / 2, width: max(w - h + size, 0), height: size)
        MotionDraw.glowing(s.style.accent.alpha(0.85), radius: s.glow, in: cx) {
            MotionDraw.gradientPlate(rect, round: max(s.style.roundness, 0.6), from: s.gradient.0, to: s.gradient.1, in: cx)
        }
        cx.saveGState()
        cx.clip(to: rect)
        MotionDraw.rise(name, at: CGPoint(x: h * 0.55, y: (h - name.height) / 2 + name.descent), progress: Ease.outExpo(c.part(0.5, 0.6)), in: cx)
        cx.restoreGState()
        let pRole = Ease.outExpo(c.part(0.7, 0.6))
        MotionDraw.blurredText(role, at: CGPoint(x: pillW + 22 * u - (1 - pRole) * 40 * u, y: (h - role.height) / 2 + role.descent),
                               radius: (1 - pRole) * 10 * u, alpha: pRole, in: cx)
    }

    /// Two blocks spring out of the left: the name on the brand's gradient, the role on a second
    /// colour just below and in.
    static let stack = MotionTemplate(id: "stack", name: String(localized: "Stack"), category: .lowerThird, fields: nameFields, fullFrame: false,
                                      placement: MotionPlacement(x: 0.07, y: 0.12, duration: 6), canAlign: true) { s in
        let u = s.u, c = s.clock, cx = s.context
        let name = s.title(s.text("name"), size: 52 * u, color: s.ink(on: s.style.accent))
        let role = s.body(s.text("role"), size: 28 * u, color: s.ink(on: s.style.secondary))
        let padX = 24 * u, padY = 15 * u
        let nameBox = CGSize(width: name.width + padX * 2, height: name.height + padY * 2)
        let roleBox = CGSize(width: role.width + padX * 2, height: role.height + padY * 2)
        let offset = 24 * u
        let total = max(nameBox.width, roleBox.width + offset)
        let x0 = MotionDraw.start(total, at: 0, align: s.placement.align)
        let r = s.style.roundness * 0.3
        let pName = max(c.spring(0, damping: 16, stiffness: 170), 0), pRole = max(c.spring(0.16, damping: 16, stiffness: 170), 0)
        let nameRect = CGRect(x: x0, y: roleBox.height - 4 * u, width: nameBox.width * pName, height: nameBox.height)
        let roleRect = CGRect(x: x0 + offset, y: 0, width: roleBox.width * pRole, height: roleBox.height)
        MotionDraw.plate(roleRect, round: r, color: s.style.secondary.cg, in: cx)
        MotionDraw.glowing(s.style.accent.alpha(0.6), radius: s.glow * 0.6, in: cx) {
            MotionDraw.gradientPlate(nameRect, round: r, from: s.gradient.0, to: s.gradient.1, in: cx)
        }
        cx.saveGState(); cx.clip(to: nameRect)
        MotionDraw.rise(name, at: CGPoint(x: x0 + padX, y: nameRect.minY + padY + name.descent), progress: Ease.outExpo(c.part(0.28, 0.6)), in: cx)
        cx.restoreGState()
        cx.saveGState(); cx.clip(to: roleRect)
        MotionDraw.rise(role, at: CGPoint(x: x0 + offset + padX, y: padY + role.descent), progress: Ease.outExpo(c.part(0.4, 0.6)), in: cx)
        cx.restoreGState()
    }

    /// The name letter by letter, each springing up out of a blur in the brand's gradient; the
    /// role tightens in from wide spacing.
    static let kinetic = MotionTemplate(id: "kinetic", name: String(localized: "Kinetic"), category: .lowerThird, fields: nameFields,
                                        fullFrame: false, placement: MotionPlacement(x: 0.07, y: 0.14, duration: 6), canAlign: true) { s in
        let u = s.u, c = s.clock, cx = s.context
        let name = s.title(s.text("name"), size: 70 * u)
        let x0 = MotionDraw.start(name.width, at: 0, align: s.placement.align)
        let letters = name.letters
        for (index, letter) in letters.enumerated() {
            let p = c.spring(Double(index) * 0.035, damping: 12, stiffness: 190)
            let lit = Ease.clamp(Double(index) / Double(max(letters.count - 1, 1)))
            let shown = Ease.clamp(p)
            MotionDraw.blurredText(letter.text.colored(s.accentMix(lit)), at: CGPoint(x: x0 + letter.x, y: 26 * u - (1 - p) * 40 * u),
                                   radius: (1 - shown) * 10 * u, alpha: shown, in: cx)
        }
        let pRole = Ease.outExpo(c.part(0.4, 1))
        let role = s.body(s.text("role"), size: 26 * u, alpha: 0.85, tracking: Ease.lerp(0.8, 0.18, pRole), uppercase: true)
        MotionDraw.blurredText(role, at: CGPoint(x: MotionDraw.start(role.width, at: 0, align: s.placement.align), y: -role.ascent),
                               radius: (1 - pRole) * 8 * u, alpha: pRole, in: cx)
    }

    // MARK: Titles & chapters

    private static let titleFields = [MotionField(key: "title", label: String(localized: "Title"), placeholder: "The Long Way Home"),
                                      MotionField(key: "subtitle", label: String(localized: "Subtitle"), placeholder: "A film by Alex Morgan")]

    /// Two lines, the second in the brand's gradient, word by word out of a blur (as the launch
    /// video's "Paste a link. Press Return.").
    static let statement = MotionTemplate(id: "statement", name: String(localized: "Statement"), category: .title,
                                          fields: [MotionField(key: "first", label: String(localized: "First line"), placeholder: "Shot in a day."),
                                                   MotionField(key: "second", label: String(localized: "Second line"), placeholder: "Cut in an hour."),
                                                   MotionField(key: "line", label: String(localized: "Small print"), placeholder: "")],
                                          fullFrame: true, placement: MotionPlacement(x: 0.5, y: 0.5, duration: 4, align: .center), canAlign: true) { s in
        let u = s.u, cx = s.context
        let size = 140 * u
        let first = s.title(s.text("first"), size: size, tracking: -0.035)
        let second = s.title(s.text("second"), size: size, tracking: -0.035)
        let gap = size * 1.05
        let n = s.wordsIn(first, at: CGPoint(x: MotionDraw.start(first.width, at: 0, align: s.placement.align), y: gap * 0.15), start: 0.05)
        s.wordsIn(second, at: CGPoint(x: MotionDraw.start(second.width, at: 0, align: s.placement.align), y: gap * 0.15 - gap), start: 0.05,
                  gradientFrom: n, firstIndex: n)
        let small = s.text("line")
        if !small.isEmpty {
            let line = s.body(small, size: 38 * u, alpha: 0.7)
            let p = Ease.outExpo(s.clock.part(0.7, 0.6))
            MotionDraw.blurredText(line, at: CGPoint(x: MotionDraw.start(line.width, at: 0, align: s.placement.align), y: -gap * 1.45 - (1 - p) * 20 * u),
                                   radius: (1 - p) * 10 * u, alpha: p, in: cx)
        }
    }

    /// Big words out of a blur, the last in the brand's gradient, a glowing line drawing beneath.
    static let headline = MotionTemplate(id: "headline", name: String(localized: "Headline"), category: .title, fields: titleFields, fullFrame: true,
                                         placement: MotionPlacement(x: 0.5, y: 0.52, duration: 5, align: .center), canAlign: true) { s in
        let u = s.u, c = s.clock, cx = s.context
        let size = 120 * u
        let lines = s.wrap(s.text("title"), width: s.canvas.width * 0.82 / s.placement.scale) { s.title($0, size: size, tracking: -0.03) }
        let total = lines.reduce(0) { $0 + $1.words.count }
        let lineHeight = size * 1.04
        var y = Double(lines.count - 1) * lineHeight / 2 - size * 0.3
        var index = 0
        var widest = 0.0
        for line in lines {
            widest = max(widest, line.width)
            index += s.wordsIn(line, at: CGPoint(x: MotionDraw.start(line.width, at: 0, align: s.placement.align), y: y), start: 0.05,
                               gradientFrom: total - 1, firstIndex: index)
            y -= lineHeight
        }
        let underY = y + lineHeight - size * 0.34
        let pLine = Ease.outExpo(c.part(0.5, 0.8))
        let lineW = widest * 0.28 * pLine
        let lineX = MotionDraw.start(lineW, at: 0, align: s.placement.align)
        MotionDraw.glowing(s.style.accent.alpha(0.9), radius: s.glow, in: cx) {
            MotionDraw.gradientPlate(CGRect(x: lineX, y: underY - 4 * u, width: lineW, height: 8 * u), round: 1, from: s.gradient.0, to: s.gradient.1, in: cx)
        }
        let subtitle = s.body(s.text("subtitle"), size: 40 * u, alpha: 0.75)
        let pSub = Ease.outExpo(c.part(0.75, 0.7))
        MotionDraw.blurredText(subtitle, at: CGPoint(x: MotionDraw.start(subtitle.width, at: 0, align: s.placement.align), y: underY - 76 * u - (1 - pSub) * 20 * u),
                               radius: (1 - pSub) * 12 * u, alpha: pSub, in: cx)
    }

    /// Glowing corners spring out around the title, which comes into focus from slightly larger.
    static let frame = MotionTemplate(id: "frame", name: String(localized: "Frame"), category: .title, fields: titleFields, fullFrame: true,
                                      placement: MotionPlacement(x: 0.5, y: 0.5, duration: 5, align: .center), canAlign: false) { s in
        let u = s.u, c = s.clock, cx = s.context
        let title = s.title(s.text("title"), size: 96 * u, tracking: 0)
        let pad = 60 * u
        let pBox = max(c.spring(0, damping: 14, stiffness: 150), 0)
        let bw = (title.width + pad * 2) * (0.7 + 0.3 * pBox), bh = (title.height + pad * 1.6) * (0.7 + 0.3 * pBox)
        let box = CGRect(x: -bw / 2, y: -bh / 2, width: bw, height: bh)
        let arm = min(64 * u, box.width / 4) * Ease.clamp(pBox)
        MotionDraw.glowing(s.style.accent.alpha(0.9), radius: s.glow * 0.8, in: cx) {
            cx.setStrokeColor(s.style.accent.cg)
            cx.setLineWidth(5 * u)
            cx.setLineCap(.square)
            for (corner, dx, dy) in [(CGPoint(x: box.minX, y: box.maxY), 1.0, -1.0), (CGPoint(x: box.maxX, y: box.maxY), -1.0, -1.0),
                                     (CGPoint(x: box.minX, y: box.minY), 1.0, 1.0), (CGPoint(x: box.maxX, y: box.minY), -1.0, 1.0)] {
                cx.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
                cx.addLine(to: corner)
                cx.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
            }
            if arm > 0.1 { cx.strokePath() }
        }
        let pTitle = Ease.outExpo(c.part(0.2, 0.9))
        cx.saveGState()
        let grow = 1 + (1 - pTitle) * 0.12
        cx.scaleBy(x: grow, y: grow)
        MotionDraw.blurredText(title, at: CGPoint(x: -title.width / 2, y: -title.height / 2 + title.descent), radius: (1 - pTitle) * 16 * u,
                               alpha: pTitle, in: cx)
        cx.restoreGState()
        let pSub = Ease.outExpo(c.part(0.55, 0.9))
        let subtitle = s.body(s.text("subtitle"), size: 30 * u, alpha: 0.7, tracking: Ease.lerp(0.5, 0.14, pSub), uppercase: true)
        MotionDraw.blurredText(subtitle, at: CGPoint(x: -subtitle.width / 2, y: -bh / 2 - 46 * u - subtitle.ascent), radius: (1 - pSub) * 8 * u, alpha: pSub, in: cx)
    }

    /// A big number in the brand's gradient rolls up, a glowing rule draws down, the chapter's
    /// name and line beside it.
    static let chapter = MotionTemplate(id: "chapter", name: String(localized: "Chapter"), category: .title,
                                        fields: [MotionField(key: "number", label: String(localized: "Number"), placeholder: "01"),
                                                 MotionField(key: "title", label: String(localized: "Title"), placeholder: "Getting There"),
                                                 MotionField(key: "subtitle", label: String(localized: "Line"), placeholder: "Day one, Lisbon")],
                                        fullFrame: true, placement: MotionPlacement(x: 0.5, y: 0.5, duration: 5, align: .center), canAlign: false) { s in
        let u = s.u, c = s.clock, cx = s.context
        let number = s.title(s.text("number"), size: 220 * u, tracking: -0.04)
        let title = s.title(s.text("title"), size: 72 * u)
        let line = s.body(s.text("subtitle"), size: 32 * u, alpha: 0.7)
        let gap = 46 * u
        let width = number.width + gap * 2 + max(title.width, line.width)
        let x0 = -width / 2
        let h = number.ascent
        // The number rolls up from below its own edge, in the gradient.
        let pNumber = max(c.spring(0, damping: 16, stiffness: 120), 0)
        cx.saveGState()
        cx.clip(to: CGRect(x: x0 - 20 * u, y: -h / 2 - number.descent, width: number.width + 40 * u, height: number.height + 10 * u))
        MotionDraw.gradientText(number, at: CGPoint(x: x0, y: -h / 2 - (1 - pNumber) * number.height), from: s.gradient.0, to: s.gradient.1, in: cx)
        cx.restoreGState()
        let ruleX = x0 + number.width + gap
        let pRule = Ease.outExpo(c.part(0.3, 0.7))
        MotionDraw.glowing(s.style.accent.alpha(0.7), radius: s.glow * 0.5, in: cx) {
            MotionDraw.plate(CGRect(x: ruleX - 2 * u, y: h / 2 - h * pRule, width: 4 * u, height: h * pRule), round: 1, color: s.style.accent.cg, in: cx)
        }
        s.wordsIn(title, at: CGPoint(x: ruleX + gap, y: 8 * u), start: 0.4, stagger: 0.08)
        MotionDraw.drop(line, at: CGPoint(x: ruleX + gap, y: -line.ascent - 16 * u), progress: Ease.outExpo(c.part(0.65, 0.7)), in: cx)
    }

    /// The brand's gradient sweeps across half the frame on a slanted edge; the title rises on
    /// it, the subtitle comes into focus beside it.
    static let split = MotionTemplate(id: "split", name: String(localized: "Split"), category: .title, fields: titleFields, fullFrame: true,
                                      placement: MotionPlacement(x: 0.5, y: 0.5, duration: 5), canAlign: false) { s in
        let u = s.u, c = s.clock, cx = s.context
        cx.saveGState()
        // In the frame's own coordinates (the panel is the frame's half, not the anchor's).
        cx.scaleBy(x: 1 / s.placement.scale, y: 1 / s.placement.scale)
        cx.translateBy(x: -s.anchor.x, y: -s.anchor.y)
        let half = s.canvas.width / 2, slant = s.canvas.height * 0.18
        let p = Ease.outExpo(c.part(0, 0.8))
        let edge = (half + slant) * p
        let panel = CGMutablePath()
        panel.move(to: CGPoint(x: 0, y: 0))
        panel.addLine(to: CGPoint(x: max(edge - slant, 0), y: 0))
        panel.addLine(to: CGPoint(x: edge, y: s.canvas.height))
        panel.addLine(to: CGPoint(x: 0, y: s.canvas.height))
        panel.closeSubpath()
        cx.saveGState()
        cx.addPath(panel)
        cx.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [s.gradient.0, s.gradient.1] as CFArray, locations: [0, 1]) {
            cx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s.canvas.height), end: CGPoint(x: half, y: 0), options: [])
        }
        cx.restoreGState()
        cx.translateBy(x: s.anchor.x, y: s.anchor.y)
        cx.scaleBy(x: s.placement.scale, y: s.placement.scale)
        let margin = 80 * u
        let left = -s.anchor.x / s.placement.scale + margin
        let lines = s.wrap(s.text("title"), width: (half - slant - margin * 1.5) / s.placement.scale) { s.title($0, size: 100 * u, color: s.ink(on: s.style.accent)) }
        var y = Double(lines.count - 1) * 100 * u / 2 - 30 * u
        var index = 0
        for line in lines {
            index += s.wordsIn(line, at: CGPoint(x: left, y: y), start: 0.35, stagger: 0.08, firstIndex: index)
            y -= 100 * u
        }
        let subtitle = s.body(s.text("subtitle"), size: 42 * u, alpha: 0.85)
        let pSub = Ease.outExpo(c.part(0.65, 0.7))
        MotionDraw.blurredText(subtitle, at: CGPoint(x: (half - s.anchor.x) / s.placement.scale + slant / 2 + margin - (1 - pSub) * 30 * u,
                                                     y: -subtitle.height / 2 + subtitle.descent),
                               radius: (1 - pSub) * 12 * u, alpha: pSub, in: cx)
        cx.restoreGState()
    }

    // MARK: Logo & end

    /// A flash, a glowing ring and sparks burst out; the logo's own animation (from the Logo
    /// Animator) lands in the middle. Without a logo, the brand's name springs in letter by letter.
    static let sting = MotionTemplate(id: "sting", name: String(localized: "Logo Sting"), category: .logo,
                                      fields: [MotionField(key: "brand", label: String(localized: "Name (without a logo)"), placeholder: "BRAND")],
                                      fullFrame: true, placement: MotionPlacement(x: 0.5, y: 0.5, duration: 4), canAlign: false) { s in
        let u = s.u, c = s.clock, cx = s.context
        let hit = 0.35
        let pRing = Ease.phase(s.time, hit, 1.2)
        if pRing > 0, pRing < 1 {
            let r = Ease.outExpo(pRing) * 520 * u
            MotionDraw.glowing(s.style.accent.alpha(1 - pRing), radius: s.glow, in: cx) {
                cx.setStrokeColor(s.accentMix(pRing))
                cx.setAlpha(1 - pRing)
                cx.setLineWidth(16 * u * (1 - pRing) + 1)
                cx.strokeEllipse(in: CGRect(x: -r, y: -r, width: r * 2, height: r * 2))
            }
            // Sparks flying out and fading.
            for i in 0..<14 {
                let angle = Double(i) / 14 * 2 * .pi + 0.2
                let distance = (180 + Double(i % 3) * 70) * u * Ease.outExpo(pRing) + 60 * u
                let dot = 7 * u * (1 - pRing)
                cx.setFillColor(s.accentMix(Double(i % 4) / 3))
                cx.setAlpha(1 - pRing)
                cx.fillEllipse(in: CGRect(x: cos(angle) * distance - dot, y: sin(angle) * distance - dot, width: dot * 2, height: dot * 2))
            }
            cx.setAlpha(1)
        }
        if let logo = s.logo, let plan = s.logoPlan {
            cx.saveGState()
            cx.translateBy(x: -s.canvas.width / 2, y: -s.canvas.height / 2)
            logo.draw(at: s.time, plan: plan, in: cx, canvas: s.canvas)
            cx.restoreGState()
        } else {
            let word = s.title(s.text("brand"), size: 160 * u, tracking: 0.02)
            let letters = word.letters
            for (index, letter) in letters.enumerated() {
                let p = c.spring(hit - 0.15 + Double(index) * 0.045, damping: 11, stiffness: 180)
                let shown = Ease.clamp(p)
                cx.saveGState()
                let center = -word.width / 2 + letter.x + letter.text.width / 2
                cx.translateBy(x: center, y: -word.height / 2 + word.descent + letter.text.height / 2)
                cx.scaleBy(x: max(p, 0.001), y: max(p, 0.001))
                MotionDraw.gradientText(letter.text, at: CGPoint(x: -letter.text.width / 2, y: -letter.text.height / 2),
                                        from: s.style.text.cg, to: s.accentMix(Double(index) / Double(max(letters.count - 1, 1))), alpha: shown, in: cx)
                cx.restoreGState()
            }
        }
    }

    /// The logo up top, the line out of a blur, a glowing gradient button springing in, and the
    /// handle typing itself out.
    static let endCard = MotionTemplate(id: "endcard", name: String(localized: "End Card"), category: .logo,
                                        fields: [MotionField(key: "line", label: String(localized: "Line"), placeholder: "Thanks for watching"),
                                                 MotionField(key: "button", label: String(localized: "Button"), placeholder: "Subscribe"),
                                                 MotionField(key: "handle", label: String(localized: "Handle"), placeholder: "@yourchannel")],
                                        fullFrame: true, placement: MotionPlacement(x: 0.5, y: 0.5, duration: 6), canAlign: false) { s in
        let u = s.u, c = s.clock, cx = s.context
        if let logo = s.logo, let plan = s.logoPlan {
            cx.saveGState()
            cx.translateBy(x: 0, y: 170 * u)
            cx.scaleBy(x: 0.6, y: 0.6)
            cx.translateBy(x: -s.canvas.width / 2, y: -s.canvas.height / 2)
            logo.draw(at: s.time, plan: plan, in: cx, canvas: s.canvas)
            cx.restoreGState()
        } else {
            cx.translateBy(x: 0, y: 110 * u)
        }
        let line = s.title(s.text("line"), size: 72 * u, tracking: -0.025)
        s.wordsIn(line, at: CGPoint(x: -line.width / 2, y: -10 * u), start: 0.45)
        let label = s.title(s.text("button"), size: 34 * u, color: s.ink(on: s.style.accent), tracking: 0)
        let bw = label.width + 80 * u, bh = label.height + 36 * u
        let pButton = c.spring(0.85, damping: 11, stiffness: 160)
        cx.saveGState()
        cx.translateBy(x: 0, y: -130 * u)
        cx.scaleBy(x: max(pButton, 0.001), y: max(pButton, 0.001))
        MotionDraw.glowing(s.style.accent.alpha(0.9), radius: s.glow, in: cx) {
            MotionDraw.gradientPlate(CGRect(x: -bw / 2, y: -bh / 2, width: bw, height: bh), round: max(s.style.roundness, 0.6),
                                     from: s.gradient.0, to: s.gradient.1, in: cx)
        }
        label.draw(at: CGPoint(x: -label.width / 2, y: -label.height / 2 + label.descent), in: cx, alpha: Ease.clamp(pButton))
        cx.restoreGState()
        // The handle types itself out.
        let handle = s.text("handle")
        let typed = Int(Ease.clamp((s.time - 1.2) / 0.05 / Double(max(handle.count, 1))) * Double(handle.count))
        if typed > 0 {
            let shown = s.body(String(handle.prefix(typed)), size: 32 * u, alpha: 0.75)
            let full = s.body(handle, size: 32 * u)
            shown.draw(at: CGPoint(x: -full.width / 2, y: -250 * u), in: cx, alpha: Ease.clamp(c.part(1.2, 0.2)))
        }
    }

    // MARK: Social

    /// A search pill springs in, the words type themselves with a blinking caret, Return is
    /// pressed and the pill flashes in the brand colour.
    static let typing = MotionTemplate(id: "typing", name: String(localized: "Typing"), category: .social,
                                       fields: [MotionField(key: "text", label: String(localized: "Typed"), placeholder: "how to colour grade in one click")],
                                       fullFrame: false, placement: MotionPlacement(x: 0.5, y: 0.5, duration: 4), canAlign: false) { s in
        let u = s.u, c = s.clock, cx = s.context, t = s.time
        let text = s.text("text")
        let full = s.body(text, size: 40 * u)
        let h = 92 * u, w = max(full.width + 210 * u, 640 * u)
        let pIn = c.spring(0, damping: 15, stiffness: 160)
        let typedCount = Int(Ease.clamp((t - 0.45) / (0.045 * Double(max(text.count, 1)))) * Double(text.count))
        let enter = 0.55 + 0.045 * Double(text.count)
        let pressed = t > enter && t < enter + 0.12
        let flash = Ease.phase(t, enter, 0.5)
        cx.saveGState()
        let k = max(pIn, 0.001) * (pressed ? 0.97 : 1)
        cx.scaleBy(x: k, y: k)
        let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        if flash > 0, flash < 1 {
            MotionDraw.glowing(s.style.accent.alpha(1 - flash), radius: s.glow * 1.5, in: cx) {
                MotionDraw.plate(rect.insetBy(dx: -4 * u, dy: -4 * u), round: 1, color: s.style.accent.alpha(1 - flash), in: cx)
            }
        }
        MotionDraw.plate(rect, round: 1, color: s.style.secondary.alpha(0.92), in: cx)
        cx.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
        cx.setLineWidth(1.5 * u)
        cx.addPath(CGPath(roundedRect: rect, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
        cx.strokePath()
        // A magnifying glass, the typed words, the caret.
        if let glass = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 30 * u, weight: .semibold))?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let size = 32 * u
            let box = CGRect(x: -w / 2 + 36 * u, y: -size / 2, width: size, height: size)
            cx.saveGState()
            cx.clip(to: box, mask: glass)
            cx.setFillColor(s.style.text.alpha(0.55))
            cx.fill(box)
            cx.restoreGState()
        }
        let x = -w / 2 + 92 * u
        let shown = s.body(String(text.prefix(typedCount)), size: 40 * u)
        shown.draw(at: CGPoint(x: x, y: -shown.height / 2 + shown.descent), in: cx, alpha: Ease.clamp(pIn))
        if Int(t * 2.2) % 2 == 0 || (t > 0.45 && t < enter) {
            MotionDraw.plate(CGRect(x: x + shown.width + 4 * u, y: -22 * u, width: 3 * u, height: 44 * u), round: 1, color: s.style.accent.cg, in: cx)
        }
        // The Return key, lit when pressed.
        let lit = pressed || (flash > 0 && flash < 0.6)
        let key = s.body("↩", size: 34 * u, color: lit ? s.style.accent : s.style.text, alpha: 0.7)
        key.draw(at: CGPoint(x: w / 2 - 40 * u - key.width, y: -key.height / 2 + key.descent), in: cx, alpha: Ease.clamp(pIn))
        cx.restoreGState()
    }

    /// A heading, then cards with icons popping in one after another (as the launch video's
    /// "everything else you'd want").
    static let features = MotionTemplate(id: "features", name: String(localized: "Feature Grid"), category: .social,
                                         fields: [MotionField(key: "heading", label: String(localized: "Heading"), placeholder: "And everything else you need."),
                                                  MotionField(key: "items", label: String(localized: "Cards (one per line: title, line)"),
                                                              placeholder: "Fast, Ready in seconds\nPrivate, Runs on your Mac\nSimple, No settings to learn\nFree, Nothing to pay\nShared, Send it anywhere\nLoved, By people like you")],
                                         fullFrame: true, placement: MotionPlacement(x: 0.5, y: 0.5, duration: 6), canAlign: false) { s in
        let u = s.u, c = s.clock, cx = s.context
        let heading = s.title(s.text("heading"), size: 64 * u, tracking: -0.02)
        let items = s.text("items").split(separator: "\n").prefix(6).map { row -> (String, String) in
            let parts = row.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
        }
        let columns = items.count > 4 ? 3 : 2, rows = Int(ceil(Double(items.count) / Double(columns)))
        let cardW = 380 * u, cardH = 170 * u, gap = 24 * u
        let gridW = Double(columns) * cardW + Double(columns - 1) * gap, gridH = Double(rows) * cardH + Double(rows - 1) * gap
        let top = (gridH + 140 * u) / 2
        s.wordsIn(heading, at: CGPoint(x: -heading.width / 2, y: top - heading.ascent), start: 0, stagger: 0.07)
        let symbols = ["bolt.fill", "lock.fill", "sparkles", "gift.fill", "paperplane.fill", "heart.fill"]
        for (index, item) in items.enumerated() {
            let row = index / columns, column = index % columns
            let x = -gridW / 2 + Double(column) * (cardW + gap), y = top - 140 * u - Double(row + 1) * cardH - Double(row) * gap
            let p = c.spring(0.45 + Double(index) * 0.12, damping: 14, stiffness: 170)
            guard p > 0.001 else { continue }
            cx.saveGState()
            cx.translateBy(x: x + cardW / 2, y: y + cardH / 2)
            cx.scaleBy(x: 0.85 + 0.15 * p, y: 0.85 + 0.15 * p)
            cx.setAlpha(Ease.clamp(p))
            let rect = CGRect(x: -cardW / 2, y: -cardH / 2, width: cardW, height: cardH)
            let round = s.style.roundness * 0.5 + 0.1
            MotionDraw.plate(rect, round: round, color: CGColor(gray: 1, alpha: 0.06), in: cx)
            cx.setStrokeColor(CGColor(gray: 1, alpha: 0.1))
            cx.setLineWidth(1.5 * u)
            let radius = min(rect.height, rect.width) / 2 * Ease.clamp(round)
            cx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            cx.strokePath()
            if let icon = NSImage(systemSymbolName: symbols[index % symbols.count], accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 34 * u, weight: .semibold))?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let size = 36 * u
                let box = CGRect(x: rect.minX + 30 * u, y: rect.maxY - 30 * u - size, width: size, height: size)
                cx.saveGState()
                cx.clip(to: box, mask: icon)
                if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [s.gradient.0, s.gradient.1] as CFArray, locations: [0, 1]) {
                    cx.drawLinearGradient(gradient, start: CGPoint(x: box.minX, y: box.maxY), end: CGPoint(x: box.maxX, y: box.minY), options: [])
                }
                cx.restoreGState()
            }
            let title = s.title(item.0, size: 36 * u, tracking: -0.01)
            title.draw(at: CGPoint(x: rect.minX + 30 * u, y: rect.minY + 62 * u), in: cx)
            let line = s.body(item.1, size: 26 * u, alpha: 0.6)
            line.draw(at: CGPoint(x: rect.minX + 30 * u, y: rect.minY + 28 * u), in: cx)
            cx.restoreGState()
        }
    }

    /// A glowing button springs in, a pointer clicks it, it turns to "Subscribed" and a bell rings.
    static let subscribe = MotionTemplate(id: "subscribe", name: String(localized: "Subscribe"), category: .social,
                                          fields: [MotionField(key: "button", label: String(localized: "Button"), placeholder: "Subscribe"),
                                                   MotionField(key: "done", label: String(localized: "After the click"), placeholder: "Subscribed")],
                                          fullFrame: false, placement: MotionPlacement(x: 0.5, y: 0.16, duration: 4), canAlign: false) { s in
        let u = s.u, c = s.clock, cx = s.context, t = s.time
        let clicked = t > 1.55
        let ink = clicked ? s.ink(on: s.style.secondary) : s.ink(on: s.style.accent)
        let label = s.title(s.text(clicked ? "done" : "button"), size: 40 * u, color: ink, tracking: 0)
        let bh = label.height + 42 * u, bw = label.width + bh * 1.45
        let pIn = c.spring(0, damping: 10, stiffness: 190)
        let press = t > 1.4 && t < 1.7 ? 0.92 : 1
        cx.saveGState()
        cx.scaleBy(x: max(pIn * press, 0.001), y: max(pIn * press, 0.001))
        let rect = CGRect(x: -bw / 2, y: -bh / 2, width: bw, height: bh)
        if clicked {
            MotionDraw.plate(rect, round: max(s.style.roundness, 0.5), color: s.style.secondary.cg, in: cx)
        } else {
            MotionDraw.glowing(s.style.accent.alpha(0.9), radius: s.glow, in: cx) {
                MotionDraw.gradientPlate(rect, round: max(s.style.roundness, 0.5), from: s.gradient.0, to: s.gradient.1, in: cx)
            }
        }
        label.draw(at: CGPoint(x: -label.width / 2 + bh * 0.25, y: -label.height / 2 + label.descent), in: cx, alpha: Ease.clamp(pIn))
        if let bell = NSImage(systemSymbolName: clicked ? "bell.fill" : "bell", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 30 * u, weight: .semibold)),
           let image = bell.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let ring = clicked ? sin((t - 1.55) * 30) * max(0, 1 - (t - 1.55) * 2) * 0.35 : 0
            cx.saveGState()
            cx.translateBy(x: -label.width / 2 - bh * 0.3, y: 0)
            cx.rotate(by: ring)
            let size = CGSize(width: 34 * u, height: 34 * u)
            cx.clip(to: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height), mask: image)
            cx.setFillColor(ink.alpha(Ease.clamp(pIn)))
            cx.fill(CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
            cx.restoreGState()
        }
        cx.restoreGState()
        // The pointer: in from the lower right, a click, away.
        let pPointer = Ease.inOutCubic(Ease.phase(t, 0.6, 0.8))
        let pAway = Ease.inCubic(Ease.phase(t, 2.1, 0.5))
        if pPointer > 0, pAway < 1 {
            let start = CGPoint(x: bw * 0.9, y: -bh * 1.6), target = CGPoint(x: bw * 0.18, y: -bh * 0.05)
            var p = CGPoint(x: Ease.lerp(start.x, target.x, pPointer), y: Ease.lerp(start.y, target.y, pPointer))
            p.x += pAway * bw * 0.5
            p.y -= pAway * bh
            let k = 2.2 * u * (t > 1.4 && t < 1.6 ? 0.85 : 1)
            let arrow = CGMutablePath()
            arrow.move(to: CGPoint(x: 0, y: 0))
            arrow.addLines(between: [CGPoint(x: 0, y: -26 * k), CGPoint(x: 7 * k, y: -19 * k), CGPoint(x: 12 * k, y: -30 * k),
                                     CGPoint(x: 16 * k, y: -28 * k), CGPoint(x: 11 * k, y: -17 * k), CGPoint(x: 20 * k, y: -17 * k)])
            arrow.closeSubpath()
            cx.saveGState()
            cx.translateBy(x: p.x, y: p.y)
            cx.setShadow(offset: CGSize(width: 0, height: -2 * u), blur: 8 * u, color: CGColor(gray: 0, alpha: 0.4))
            cx.addPath(arrow)
            cx.setFillColor(CGColor(gray: 1, alpha: 1 - pAway))
            cx.setStrokeColor(CGColor(gray: 0, alpha: 0.8 * (1 - pAway)))
            cx.setLineWidth(1.5 * k)
            cx.drawPath(using: .fillStroke)
            cx.restoreGState()
            // A ripple where it clicks.
            let ripple = Ease.phase(t, 1.45, 0.5)
            if ripple > 0, ripple < 1 {
                let r = 40 * u * Ease.outExpo(ripple)
                cx.setStrokeColor(CGColor(gray: 1, alpha: 0.6 * (1 - ripple)))
                cx.setLineWidth(3 * u)
                cx.strokeEllipse(in: CGRect(x: target.x - r, y: target.y - r, width: r * 2, height: r * 2))
            }
        }
    }

    /// A big quote mark springs in, the words come into focus one by one, the name after.
    static let quote = MotionTemplate(id: "quote", name: String(localized: "Quote"), category: .social,
                                      fields: [MotionField(key: "quote", label: String(localized: "Quote"), placeholder: "The best stories are the ones you didn’t plan."),
                                               MotionField(key: "author", label: String(localized: "Who said it"), placeholder: "Alex Morgan")],
                                      fullFrame: true, placement: MotionPlacement(x: 0.5, y: 0.5, duration: 7, align: .center), canAlign: true) { s in
        let u = s.u, c = s.clock, cx = s.context
        let size = 68 * u
        let lines = s.wrap(s.text("quote"), width: min(s.canvas.width * 0.75, 1300 * u) / s.placement.scale) { s.title($0, size: size, tracking: -0.02) }
        let lineHeight = size * 1.22
        let top = Double(lines.count) * lineHeight / 2
        let mark = s.title("“", size: 280 * u)
        let pMark = c.spring(0, damping: 11, stiffness: 170)
        cx.saveGState()
        let markX = s.placement.align == .left ? mark.width / 2 : s.placement.align == .right ? -mark.width / 2 : 0
        cx.translateBy(x: markX, y: top + 50 * u)
        cx.scaleBy(x: max(pMark, 0.001), y: max(pMark, 0.001))
        MotionDraw.gradientText(mark, at: CGPoint(x: -mark.width / 2, y: -mark.ascent * 0.45), from: s.gradient.0, to: s.gradient.1, alpha: Ease.clamp(pMark), in: cx)
        cx.restoreGState()
        var y = top - size
        var index = 0
        for line in lines {
            index += s.wordsIn(line, at: CGPoint(x: MotionDraw.start(line.width, at: 0, align: s.placement.align), y: y), start: 0.3, stagger: 0.06,
                               length: 0.5, firstIndex: index)
            y -= lineHeight
        }
        let author = s.body("— " + s.text("author"), size: 34 * u, color: s.style.accent)
        let pAuthor = Ease.outExpo(c.part(0.4 + Double(index) * 0.06, 0.7))
        MotionDraw.blurredText(author, at: CGPoint(x: MotionDraw.start(author.width, at: 0, align: s.placement.align) - (1 - pAuthor) * 24 * u, y: y - 24 * u),
                               radius: (1 - pAuthor) * 10 * u, alpha: pAuthor, in: cx)
    }

    /// A bar along the bottom filling over the whole clip in the brand's gradient, a glowing dot
    /// at its head (set the length to the video's).
    static let progress = MotionTemplate(id: "progress", name: String(localized: "Progress Bar"), category: .social,
                                         fields: [MotionField(key: "label", label: String(localized: "Label"), placeholder: "")],
                                         fullFrame: false, placement: MotionPlacement(x: 0.5, y: 0.03, duration: 30), canAlign: false) { s in
        let u = s.u, cx = s.context
        let width = s.canvas.width * 0.92 / s.placement.scale, height = 10 * u
        let track = CGRect(x: -width / 2, y: 0, width: width, height: height)
        let pIn = Ease.outExpo(Ease.phase(s.t, 0, 0.5))
        MotionDraw.plate(track, round: 1, color: s.style.secondary.alpha(0.45 * pIn), in: cx)
        let fill = Ease.clamp(s.t / max(s.placement.duration, 0.1))
        let filled = CGRect(x: -width / 2, y: 0, width: max(width * fill, height), height: height)
        MotionDraw.glowing(s.style.accent.alpha(0.8), radius: s.glow * 0.6, in: cx) {
            MotionDraw.gradientPlate(filled, round: 1, from: s.gradient.0, to: s.gradient.1, in: cx)
            let dot = height * 1.8
            cx.setFillColor(CGColor(gray: 1, alpha: pIn))
            cx.fillEllipse(in: CGRect(x: filled.maxX - dot / 2 - height / 2, y: height / 2 - dot / 2, width: dot, height: dot))
        }
        let label = s.text("label")
        if !label.isEmpty {
            let text = s.body(label, size: 26 * u, alpha: 0.9)
            text.draw(at: CGPoint(x: -width / 2, y: height + 16 * u + text.descent), in: cx, alpha: pIn)
        }
    }

    /// A caption in a box, each word popping onto a glowing gradient plate as it's said.
    static let caption = MotionTemplate(id: "caption", name: String(localized: "Caption"), category: .social,
                                        fields: [MotionField(key: "text", label: String(localized: "Words"), placeholder: "This is how we made it happen")],
                                        fullFrame: false, placement: MotionPlacement(x: 0.5, y: 0.22, duration: 3, align: .center), canAlign: false) { s in
        let u = s.u, cx = s.context
        let size = 58 * u
        let lines = s.wrap(s.text("text"), width: min(s.canvas.width * 0.8, 1100 * u) / s.placement.scale) { s.title($0, size: size, tracking: -0.01) }
        let lineHeight = size * 1.3
        let words = lines.map(\.words)
        let count = max(words.reduce(0) { $0 + $1.count }, 1)
        let per = max(s.placement.duration - 0.6, 0.5) / Double(count)
        let widest = lines.map(\.width).max() ?? 0
        let pad = 28 * u
        let box = CGRect(x: -widest / 2 - pad, y: -Double(lines.count) * lineHeight / 2 - pad * 0.6,
                         width: widest + pad * 2, height: Double(lines.count) * lineHeight + pad * 1.2)
        let pIn = Ease.spring(s.time, damping: 13, stiffness: 200)
        cx.saveGState()
        cx.scaleBy(x: max(pIn, 0.001), y: max(pIn, 0.001))
        MotionDraw.plate(box, round: s.style.roundness * 0.6, color: s.style.secondary.alpha(0.88), in: cx)
        var index = 0
        var y = box.maxY - pad * 0.6 - size
        for (lineIndex, line) in lines.enumerated() {
            let x = -line.width / 2
            for word in words[lineIndex] {
                let start = 0.3 + Double(index) * per
                let on = s.t >= start && s.t < start + per + 0.05
                if on {
                    let pop = Ease.spring(s.t - start, damping: 12, stiffness: 260)
                    let rect = CGRect(x: x + word.x - 10 * u, y: y - word.text.descent - 6 * u, width: word.text.width + 20 * u, height: word.text.height + 12 * u)
                    cx.saveGState()
                    cx.translateBy(x: rect.midX, y: rect.midY)
                    cx.scaleBy(x: 0.8 + 0.2 * pop, y: 0.8 + 0.2 * pop)
                    cx.translateBy(x: -rect.midX, y: -rect.midY)
                    MotionDraw.glowing(s.style.accent.alpha(0.8), radius: s.glow * 0.6, in: cx) {
                        MotionDraw.gradientPlate(rect, round: 0.45, from: s.gradient.0, to: s.gradient.1, in: cx)
                    }
                    cx.restoreGState()
                }
                let color = on ? s.ink(on: s.style.accent) : s.style.text
                word.text.colored(color.cg).draw(at: CGPoint(x: x + word.x, y: y), in: cx, alpha: s.t >= start - 0.15 ? 1 : 0.5)
                index += 1
            }
            y -= lineHeight
        }
        cx.restoreGState()
    }
}

/// The screenshot self-test: every template at a few moments, as PNGs in a folder.
enum MotionSheet {
    static func write(to folder: URL, times: [Double] = [0.35, 2.5]) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let canvas = CGSize(width: 1280, height: 720)
        for template in MotionTemplate.all {
            for time in times {
                guard let context = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8,
                                              bytesPerRow: Int(canvas.width) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                // A picture-like backdrop for the ones over video.
                context.setFillColor(CGColor(srgbRed: 0.32, green: 0.36, blue: 0.40, alpha: 1))
                context.fill(CGRect(origin: .zero, size: canvas))
                template.render(t: time, in: context, canvas: canvas, style: MotionStyle(), placement: template.placement)
                guard let image = context.makeImage(),
                      let destination = CGImageDestinationCreateWithURL(folder.appendingPathComponent("\(template.id)-\(time).png") as CFURL,
                                                                        "public.png" as CFString, 1, nil) else { continue }
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
        }
    }
}

extension MotionSheet {
    /// How long frames take to draw, per template (milliseconds per 1080p frame), for tuning.
    static func timing() -> String {
        let canvas = CGSize(width: 1920, height: 1080)
        var lines: [String] = []
        for template in MotionTemplate.all {
            guard let context = CGContext(data: nil, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            let start = Date.now
            for frame in 0..<40 {
                context.clear(CGRect(origin: .zero, size: canvas))
                template.render(t: Double(frame) / 25, in: context, canvas: canvas, style: MotionStyle(), placement: template.placement)
            }
            lines.append("\(template.id): \(Int(Date.now.timeIntervalSince(start) * 1000 / 40)) ms")
        }
        return lines.joined(separator: "\n")
    }
}
