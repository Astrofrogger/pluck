import AppKit

/// Brand Pack templates as Fusion titles for DaVinci Resolve.
enum FusionExport {
    /// Resolve's own folder for title templates (they show under Titles, in a Pluck folder).
    static var resolveTitles: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Templates/Edit/Titles/Pluck")
    }

    /// Whether Resolve is on this Mac (its support folder is there).
    static var hasResolve: Bool {
        FileManager.default.fileExists(atPath: resolveTitles.deletingLastPathComponent().deletingLastPathComponent().path)
    }

    /// The template as a Fusion macro (a .setting), or nil for one it can't be made of.
    static func macro(_ template: MotionTemplate, style: MotionStyle, placement: MotionPlacement,
                      canvas: CGSize = CGSize(width: 1920, height: 1080), fps: Double = 25) -> String? {
        guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scene = MotionScene(context: context, canvas: canvas, t: 0, style: style, placement: placement, logo: nil, logoPlan: nil,
                                defaults: template.defaults)
        let title = FusionTitle(template, style: style, placement: placement, canvas: canvas, fps: fps)
        guard build(template.id, title, scene) else { return nil }
        return title.finish(title: "Pluck " + template.name)
    }

    /// Writes the macro to a file.
    static func write(_ template: MotionTemplate, style: MotionStyle, placement: MotionPlacement,
                      canvas: CGSize = CGSize(width: 1920, height: 1080), fps: Double = 25, to url: URL) throws {
        guard let text = macro(template, style: style, placement: placement, canvas: canvas, fps: fps) else { throw CocoaError(.featureUnsupported) }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Adds the template to Resolve's titles; returns where it went.
    @discardableResult
    static func install(_ template: MotionTemplate, style: MotionStyle, placement: MotionPlacement,
                        canvas: CGSize = CGSize(width: 1920, height: 1080), fps: Double = 25) throws -> URL {
        try FileManager.default.createDirectory(at: resolveTitles, withIntermediateDirectories: true)
        let url = resolveTitles.appendingPathComponent("Pluck \(template.name).setting")
        try write(template, style: style, placement: placement, canvas: canvas, fps: fps, to: url)
        return url
    }

    /// Every template there is a Fusion version of.
    static func supports(_ template: MotionTemplate) -> Bool { supported.contains(template.id) }
    private static let supported: Set<String> = ["slab", "editorial", "pill", "stack", "kinetic", "statement", "headline", "frame", "chapter", "split",
                                                 "sting", "endcard", "typing", "features", "subscribe", "quote", "progress", "caption"]

    /// Icons as characters a Mac font has (Fusion can't draw SF Symbols).
    private static let symbols: [(String, (family: String, face: String))] = [
        ("⚡", ("Apple Symbols", "Regular")), ("✓", ("Menlo", "Regular")), ("✦", ("Menlo", "Regular")),
        ("★", ("Apple Symbols", "Regular")), ("✈", ("Menlo", "Regular")), ("♥", ("Apple Symbols", "Regular")),
    ]

    // MARK: The templates

    private static func build(_ id: String, _ f: FusionTitle, _ s: MotionScene) -> Bool {
        let u = s.u, align = s.placement.align
        switch id {
        case "slab":
            let name = s.title(s.text("name"), size: 56 * u)
            let role = s.body(s.text("role"), size: 30 * u)
            let pad = 28 * u, bar = 10 * u
            let plateW = max(name.width, role.width) + pad * 2, plateH = name.height + role.height + pad * 1.7
            let x0 = MotionDraw.start(plateW + bar, at: 0, align: align)
            f.plate({ c in CGRect(x: x0, y: 0, width: bar, height: plateH * max(c.spring(0, damping: 13, stiffness: 180), 0)) },
                    final: CGRect(x: x0, y: 0, width: bar, height: plateH), round: 0, fill: .gradient, glow: 1)
            let plate = { (c: MotionClock) in CGRect(x: x0 + bar, y: 0, width: plateW * Ease.outExpo(c.part(0.2, 0.65)), height: plateH) }
            let full = CGRect(x: x0 + bar, y: 0, width: plateW, height: plateH)
            let inside = f.clip(f.plate(plate, final: full, round: s.style.roundness * 0.15, fill: .ink(.plate, 0.94),
                                        grow: f.grow(String(localized: "Plate Width"))))
            f.rise("name", name, at: CGPoint(x: x0 + bar + pad, y: plateH - pad * 0.85 - name.ascent), start: 0.38, length: 0.6, inside: inside)
            f.rise("role", role, at: CGPoint(x: x0 + bar + pad, y: pad * 0.85 + role.descent), start: 0.5, length: 0.6, alpha: 0.8, inside: inside, body: true)

        case "editorial":
            let name = s.title(s.text("name"), size: 64 * u)
            let role = s.body(s.text("role"), size: 26 * u, tracking: 0.16, uppercase: true)
            let width = max(name.width, role.width) + 24 * u
            let x0 = MotionDraw.start(width, at: 0, align: align)
            f.plate({ c in
                let p = Ease.outExpo(c.part(0, 0.8))
                return CGRect(x: align == .right ? x0 + width * (1 - p) : x0, y: -1.5 * u, width: width * p, height: 3 * u)
            }, final: CGRect(x: x0, y: -1.5 * u, width: width, height: 3 * u), round: 1, fill: .gradient, glow: 0.7,
                    grow: f.grow(String(localized: "Line Width")), centered: align == .center)
            let nameAt = CGPoint(x: MotionDraw.start(name.width, at: 0, align: align), y: 16 * u + name.descent)
            let wide = s.canvas.width * 4
            let edge = f.mask { _ in CGRect(x: nameAt.x - wide / 2, y: nameAt.y - name.descent - 2, width: wide, height: name.height + 4) }
            f.text("name", name, at: nameAt, align: align, clip: edge, motion: .init(stagger: 0.025) { c in
                let q = Ease.outExpo(c.part(0.25, 0.55))
                return .init(dy: -(1 - q) * name.height * 1.1, alpha: q > 0.001 ? 1 : 0)
            })
            let roleAt = CGPoint(x: MotionDraw.start(role.width, at: 0, align: align), y: -18 * u - role.ascent)
            let roleEdge = f.mask { _ in CGRect(x: roleAt.x - wide / 2, y: roleAt.y - role.descent - 2, width: wide, height: role.height + 4) }
            f.text("role", role, at: roleAt, align: align, ink: .accent, clip: roleEdge, motion: .init { c in
                let q = Ease.outExpo(c.part(0.45, 0.9))
                return .init(dy: (1 - q) * role.height * 1.1, alpha: q > 0.001 ? 1 : 0)
            }, tracking: { c in Ease.lerp(0.45, 0.16, Ease.outExpo(c.part(0.45, 0.9))) }, body: true)

        case "pill":
            let ink = s.ink(on: s.style.accent)
            let name = s.title(s.text("name"), size: 44 * u, color: ink)
            let role = s.body(s.text("role"), size: 30 * u)
            let h = name.height + 32 * u
            let pillW = name.width + h * 1.1
            let pill = { (c: MotionClock) -> CGRect in
                let size = h * max(c.spring(0, damping: 10, stiffness: 200), 0)
                let w = h + (pillW - h) * max(c.spring(0.32, damping: 15, stiffness: 150), 0)
                return CGRect(x: h / 2 - size / 2, y: h / 2 - size / 2, width: max(w - h + size, 0), height: size)
            }
            let full = CGRect(x: 0, y: 0, width: pillW, height: h)
            let wider = f.grow(String(localized: "Pill Width"))
            let shape = f.plate(pill, final: full, round: max(s.style.roundness, 0.6), fill: .gradient, glow: 1, grow: wider)
            f.rise("name", name, at: CGPoint(x: h * 0.55, y: (h - name.height) / 2 + name.descent), start: 0.5, length: 0.6, ink: .fixed(ink),
                   inside: f.clip(shape))
            f.text("role", role, at: CGPoint(x: pillW + 22 * u, y: (h - role.height) / 2 + role.descent), alpha: 0.9, motion: .init { c in
                let q = Ease.outExpo(c.part(0.7, 0.6))
                return .init(dx: -(1 - q) * 40 * u, alpha: q, blur: (1 - q) * 10 * u)
            }, shift: wider, body: true)

        case "stack":
            let nameInk = s.ink(on: s.style.accent), roleInk = s.ink(on: s.style.secondary)
            let name = s.title(s.text("name"), size: 52 * u, color: nameInk)
            let role = s.body(s.text("role"), size: 28 * u, color: roleInk)
            let padX = 24 * u, padY = 15 * u
            let nameBox = CGSize(width: name.width + padX * 2, height: name.height + padY * 2)
            let roleBox = CGSize(width: role.width + padX * 2, height: role.height + padY * 2)
            let offset = 24 * u
            let x0 = MotionDraw.start(max(nameBox.width, roleBox.width + offset), at: 0, align: align)
            let r = s.style.roundness * 0.3
            let nameRect = { (c: MotionClock) in CGRect(x: x0, y: roleBox.height - 4 * u, width: nameBox.width * max(c.spring(0, damping: 16, stiffness: 170), 0), height: nameBox.height) }
            let roleRect = { (c: MotionClock) in CGRect(x: x0 + offset, y: 0, width: roleBox.width * max(c.spring(0.16, damping: 16, stiffness: 170), 0), height: roleBox.height) }
            let roleFull = CGRect(x: x0 + offset, y: 0, width: roleBox.width, height: roleBox.height)
            let nameFull = CGRect(x: x0, y: roleBox.height - 4 * u, width: nameBox.width, height: nameBox.height)
            let rolePlate = f.plate(roleRect, final: roleFull, round: r, fill: .ink(.plate, 1), grow: f.grow(String(localized: "Role Plate Width")))
            let namePlate = f.plate(nameRect, final: nameFull, round: r, fill: .gradient, glow: 0.6, grow: f.grow(String(localized: "Name Plate Width")))
            f.rise("name", name, at: CGPoint(x: x0 + padX, y: roleBox.height - 4 * u + padY + name.descent), start: 0.28, length: 0.6, ink: .fixed(nameInk),
                   inside: f.clip(namePlate))
            f.rise("role", role, at: CGPoint(x: x0 + offset + padX, y: padY + role.descent), start: 0.4, length: 0.6, ink: .fixed(roleInk),
                   inside: f.clip(rolePlate), body: true)

        case "kinetic":
            let name = s.title(s.text("name"), size: 70 * u)
            let x0 = MotionDraw.start(name.width, at: 0, align: align)
            f.text("name", name, at: CGPoint(x: x0, y: 26 * u), align: align, gradient: true, motion: .init(stagger: 0.035) { c in
                let p = c.spring(0, damping: 12, stiffness: 190)
                let shown = Ease.clamp(p)
                return .init(dy: -(1 - p) * 40 * u, alpha: shown, blur: (1 - shown) * 10 * u)
            })
            let role = s.body(s.text("role"), size: 26 * u, tracking: 0.18, uppercase: true)
            f.focus("role", role, at: CGPoint(x: MotionDraw.start(role.width, at: 0, align: align), y: -role.ascent), start: 0.4, length: 1, rise: 0, blur: 8,
                    align: align, alpha: 0.85, tracking: { c in Ease.lerp(0.8, 0.18, Ease.outExpo(c.part(0.4, 1))) }, body: true)

        // MARK: Titles & chapters

        case "statement":
            let size = 140 * u
            let first = s.title(s.text("first"), size: size, tracking: -0.035)
            let second = s.title(s.text("second"), size: size, tracking: -0.035)
            let gap = size * 1.05
            let n = first.words.count
            f.words("first", first, at: CGPoint(x: MotionDraw.start(first.width, at: 0, align: align), y: gap * 0.15), start: 0.05, align: align)
            f.words("second", second, at: CGPoint(x: MotionDraw.start(second.width, at: 0, align: align), y: gap * 0.15 - gap),
                    start: 0.05 + Double(n) * 0.1, align: align, gradient: true)
            let small = s.text("line")
            if !small.isEmpty {
                let line = s.body(small, size: 38 * u)
                f.focus("line", line, at: CGPoint(x: MotionDraw.start(line.width, at: 0, align: align), y: -gap * 1.45), start: 0.7, align: align,
                        alpha: 0.7, body: true)
            }

        case "headline":
            let size = 120 * u
            let lines = s.wrap(s.text("title"), width: s.canvas.width * 0.82 / s.placement.scale) { s.title($0, size: size, tracking: -0.03) }
            guard let first = lines.first else { return false }
            let lineHeight = size * 1.04
            let top = Double(lines.count - 1) * lineHeight / 2 - size * 0.3
            let last = top - Double(lines.count - 1) * lineHeight
            let widest = lines.map(\.width).max() ?? 0
            f.words("title", first, at: CGPoint(x: MotionDraw.start(0, at: 0, align: align), y: last), start: 0.05, align: align, anchored: true,
                    lines: lines.map(\.string), lineHeight: lineHeight)
            let underY = last - size * 0.34
            f.plate({ c in
                let w = widest * 0.28 * Ease.outExpo(c.part(0.5, 0.8))
                return CGRect(x: MotionDraw.start(w, at: 0, align: align), y: underY - 4 * u, width: w, height: 8 * u)
            }, final: CGRect(x: MotionDraw.start(widest * 0.28, at: 0, align: align), y: underY - 4 * u, width: widest * 0.28, height: 8 * u),
                    round: 1, fill: .gradient, glow: 1)
            let subtitle = s.body(s.text("subtitle"), size: 40 * u)
            f.focus("subtitle", subtitle, at: CGPoint(x: MotionDraw.start(subtitle.width, at: 0, align: align), y: underY - 76 * u), start: 0.75,
                    length: 0.7, align: align, alpha: 0.75, body: true)

        case "frame":
            let title = s.title(s.text("title"), size: 96 * u, tracking: 0)
            let pad = 60 * u
            let box = { (c: MotionClock) -> (CGRect, Double) in
                let p = max(c.spring(0, damping: 14, stiffness: 150), 0)
                let bw = (title.width + pad * 2) * (0.7 + 0.3 * p), bh = (title.height + pad * 1.6) * (0.7 + 0.3 * p)
                let rect = CGRect(x: -bw / 2, y: -bh / 2, width: bw, height: bh)
                return (rect, min(64 * u, rect.width / 4) * Ease.clamp(p))
            }
            let line = 5 * u
            let final = CGRect(x: -(title.width + pad * 2) / 2, y: -(title.height + pad * 1.6) / 2, width: title.width + pad * 2, height: title.height + pad * 1.6)
            for (cornerX, cornerY) in [(0, 1), (1, 1), (0, 0), (1, 0)] {
                let corner = { (c: MotionClock) -> (CGPoint, Double) in
                    let (r, arm) = box(c)
                    return (CGPoint(x: cornerX == 0 ? r.minX : r.maxX, y: cornerY == 0 ? r.minY : r.maxY), arm)
                }
                let dx = cornerX == 0 ? 1.0 : -1.0, dy = cornerY == 0 ? 1.0 : -1.0
                f.plate({ c in let (p, arm) = corner(c); return CGRect(x: min(p.x, p.x + dx * arm) - line / 2, y: p.y - line / 2, width: arm + line, height: line) },
                        final: final, round: 0, fill: .ink(.accent, 1), glow: 0.8)
                f.plate({ c in let (p, arm) = corner(c); return CGRect(x: p.x - line / 2, y: min(p.y, p.y + dy * arm) - line / 2, width: line, height: arm + line) },
                        final: final, round: 0, fill: .ink(.accent, 1), glow: 0.8)
            }
            f.group(around: .zero, scale: { c in 1 + (1 - Ease.outExpo(c.part(0.2, 0.9))) * 0.12 }) {
                f.focus("title", title, at: CGPoint(x: 0, y: -title.height / 2 + title.descent), start: 0.2, length: 0.9, byWord: false, rise: 0, blur: 16,
                        align: .center, anchored: true)
            }
            let subtitle = s.body(s.text("subtitle"), size: 30 * u, tracking: 0.14, uppercase: true)
            f.focus("subtitle", subtitle, at: CGPoint(x: 0, y: final.minY - 46 * u - subtitle.ascent), start: 0.55, length: 0.9, byWord: false, rise: 0,
                    blur: 8, align: .center, anchored: true, alpha: 0.7, tracking: { c in Ease.lerp(0.5, 0.14, Ease.outExpo(c.part(0.55, 0.9))) }, body: true)

        case "chapter":
            let number = s.title(s.text("number"), size: 220 * u, tracking: -0.04)
            let title = s.title(s.text("title"), size: 72 * u)
            let line = s.body(s.text("subtitle"), size: 32 * u)
            let gap = 46 * u
            let x0 = -(number.width + gap * 2 + max(title.width, line.width)) / 2
            let h = number.ascent
            let edge = f.mask { _ in CGRect(x: x0 - 20 * u, y: -h / 2 - number.descent, width: number.width + 40 * u, height: number.height + 10 * u) }
            f.text("number", number, at: CGPoint(x: x0, y: -h / 2), gradient: true, clip: edge, motion: .init { c in
                let p = max(c.spring(0, damping: 16, stiffness: 120), 0)
                return .init(dy: -(1 - p) * number.height, alpha: p > 0.001 ? 1 : 0)
            })
            let ruleX = x0 + number.width + gap
            f.plate({ c in
                let p = Ease.outExpo(c.part(0.3, 0.7))
                return CGRect(x: ruleX - 2 * u, y: h / 2 - h * p, width: 4 * u, height: h * p)
            }, final: CGRect(x: ruleX - 2 * u, y: -h / 2, width: 4 * u, height: h), round: 1, fill: .ink(.accent, 1), glow: 0.5)
            f.words("title", title, at: CGPoint(x: ruleX + gap, y: 8 * u), start: 0.4, stagger: 0.08)
            f.rise("subtitle", line, at: CGPoint(x: ruleX + gap, y: -line.ascent - 16 * u), start: 0.65, length: 0.7, alpha: 0.7, drop: true, body: true)

        case "split":
            let w = s.canvas.width, h = s.canvas.height
            let half = w / 2, slant = h * 0.18
            // The panel: a big rectangle turned to the slant, its right edge sweeping across.
            let angle = atan2(slant, h)
            let big = w * 3
            let toAnchor = { (p: CGPoint) in CGPoint(x: p.x - f.anchor.x, y: p.y - f.anchor.y) }
            let panel = f.graphMask(center: { c in
                let edge = (half + slant) * Ease.outExpo(c.part(0, 0.8))
                let mid = CGPoint(x: edge - slant / 2, y: h / 2)
                return toAnchor(CGPoint(x: mid.x - cos(angle) * big / 2, y: mid.y + sin(angle) * big / 2))
            }, size: CGSize(width: big, height: big), angle: -angle * 180 / .pi)
            f.panel(panel, from: toAnchor(CGPoint(x: 0, y: h)), to: toAnchor(CGPoint(x: half, y: 0)))
            let margin = 80 * u
            let left = -f.anchor.x / s.placement.scale + margin
            let ink = s.ink(on: s.style.accent)
            let lines = s.wrap(s.text("title"), width: (half - slant - margin * 1.5) / s.placement.scale) { s.title($0, size: 100 * u, color: ink) }
            guard let first = lines.first else { return false }
            let top = Double(lines.count - 1) * 100 * u / 2 - 30 * u
            f.words("title", first, at: CGPoint(x: left, y: top - Double(lines.count - 1) * 100 * u), start: 0.35, stagger: 0.08,
                    lines: lines.map(\.string), lineHeight: 100 * u, ink: .fixed(ink))
            let subtitle = s.body(s.text("subtitle"), size: 42 * u)
            f.focus("subtitle", subtitle, at: CGPoint(x: (half - f.anchor.x) / s.placement.scale + slant / 2 + margin, y: -subtitle.height / 2 + subtitle.descent),
                    start: 0.65, length: 0.7, rise: 0, slide: 30, alpha: 0.85, body: true)

        // MARK: Logo & end

        case "sting":
            let hit = 0.35
            let ring = { (c: MotionClock) in Ease.phase(c.t * c.speed, hit, 1.2) }
            let live = { (c: MotionClock) -> Double in let p = ring(c); return p > 0 && p < 1 ? 1 - p : 0 }
            f.ellipse({ _ in .zero }, radius: { c in Ease.outExpo(ring(c)) * 520 * u }, line: { c in 16 * u * (1 - ring(c)) + 1 },
                      fill: .gradient, glow: 1, alpha: live)
            for i in 0..<14 {
                let angle = Double(i) / 14 * 2 * .pi + 0.2
                f.ellipse({ c in
                    let d = (180 + Double(i % 3) * 70) * u * Ease.outExpo(ring(c)) + 60 * u
                    return CGPoint(x: cos(angle) * d, y: sin(angle) * d)
                }, radius: { c in 7 * u * (1 - ring(c)) }, fill: i % 2 == 0 ? .ink(.accent, 1) : .gradient, alpha: live)
            }
            let word = s.title(s.text("brand"), size: 160 * u, tracking: 0.02)
            f.text("brand", word, at: CGPoint(x: 0, y: -word.height / 2 + word.descent), align: .center, anchored: true, gradient: true,
                   motion: .init(stagger: 0.045) { c in
                       let p = c.spring(hit - 0.15, damping: 11, stiffness: 180)
                       return .init(alpha: Ease.clamp(p), scale: max(p, 0.001))
                   })

        case "endcard":
            let lift = 110 * u
            let line = s.title(s.text("line"), size: 72 * u, tracking: -0.025)
            f.words("line", line, at: CGPoint(x: 0, y: lift - 10 * u), start: 0.45, align: .center, anchored: true)
            let ink = s.ink(on: s.style.accent)
            let label = s.title(s.text("button"), size: 34 * u, color: ink, tracking: 0)
            let bw = label.width + 80 * u, bh = label.height + 36 * u
            let center = CGPoint(x: 0, y: lift - 130 * u)
            let pop = { (c: MotionClock) in c.spring(0.85, damping: 11, stiffness: 160) }
            f.group(around: center, scale: pop) {
                f.plate({ _ in CGRect(x: center.x - bw / 2, y: center.y - bh / 2, width: bw, height: bh) },
                        final: CGRect(x: center.x - bw / 2, y: center.y - bh / 2, width: bw, height: bh), round: max(s.style.roundness, 0.6), fill: .gradient, glow: 1,
                        grow: f.grow(String(localized: "Button Width")), centered: true)
                f.text("button", label, at: CGPoint(x: center.x, y: center.y - label.height / 2 + label.descent), align: .center, anchored: true,
                       ink: .fixed(ink), motion: .init { c in .init(alpha: Ease.clamp(pop(c))) })
            }
            let handle = s.text("handle")
            let full = s.body(handle, size: 32 * u)
            let count = Double(max(handle.count, 1))
            f.text("handle", full, at: CGPoint(x: -full.width / 2, y: lift - 250 * u), motion: .init { c in .init(alpha: Ease.clamp(c.part(1.2, 0.2))) },
                   writeOn: { c in (Ease.clamp((c.t * c.speed - 1.2) / 0.05 / count) * count).rounded(.down) / count }, body: true)

        // MARK: Social

        case "typing":
            let text = s.text("text")
            let full = s.body(text, size: 40 * u)
            let h = 92 * u, w = max(full.width + 210 * u, 640 * u)
            let count = Double(max(text.count, 1))
            let enter = 0.55 + 0.045 * count
            let time = { (c: MotionClock) in c.t * c.speed }
            let typed = { (c: MotionClock) in (Ease.clamp((time(c) - 0.45) / (0.045 * count)) * count).rounded(.down) }
            let pressed = { (c: MotionClock) in time(c) > enter && time(c) < enter + 0.12 }
            let flash = { (c: MotionClock) in Ease.phase(time(c), enter, 0.5) }
            let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
            f.group(around: .zero, scale: { c in max(c.spring(0, damping: 15, stiffness: 160), 0) * (pressed(c) ? 0.97 : 1) }) {
                f.plate({ _ in rect.insetBy(dx: -4 * u, dy: -4 * u) }, final: rect, round: 1, fill: .ink(.accent, 1), glow: 1.5,
                        alpha: { c in let p = flash(c); return p > 0 && p < 1 ? 1 - p : 0 })
                f.plate({ _ in rect }, final: rect, round: 1, fill: .ink(.plate, 0.92))
                let glass = s.body("⌕", size: 40 * u)
                f.text(nil, glass, at: CGPoint(x: -w / 2 + 34 * u, y: -glass.height / 2 + glass.descent), alpha: 0.55, motion: .init { _ in .init() },
                       font: ("Apple Symbols", "Regular"))
                let x = -w / 2 + 92 * u
                f.text("text", full, at: CGPoint(x: x, y: -full.height / 2 + full.descent), motion: .init { _ in .init() },
                       writeOn: { c in typed(c) / count }, body: true)
                f.plate({ c in
                    let shown = s.body(String(text.prefix(Int(typed(c)))), size: 40 * u)
                    return CGRect(x: x + shown.width + 4 * u, y: -22 * u, width: 3 * u, height: 44 * u)
                }, final: CGRect(x: x, y: -22 * u, width: 3 * u, height: 44 * u), round: 1, fill: .ink(.accent, 1),
                        alpha: { c in Int(time(c) * 2.2) % 2 == 0 || (time(c) > 0.45 && time(c) < enter) ? 1 : 0 })
                let key = s.body("↩", size: 34 * u)
                let keyAt = CGPoint(x: w / 2 - 40 * u - key.width, y: -key.height / 2 + key.descent)
                f.text(nil, key, at: keyAt, alpha: 0.7, motion: .init { _ in .init() }, font: ("Menlo", "Regular"))
                f.text(nil, key, at: keyAt, ink: .accent, alpha: 0.7, motion: .init { c in
                    let p = flash(c)
                    return .init(alpha: pressed(c) || (p > 0 && p < 0.6) ? 1 : 0)
                }, font: ("Menlo", "Regular"))
            }

        case "features":
            let heading = s.title(s.text("heading"), size: 64 * u, tracking: -0.02)
            let items = s.text("items").split(separator: "\n").prefix(6).map { row -> (String, String) in
                let parts = row.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
            }
            let columns = items.count > 4 ? 3 : 2, rows = Int(ceil(Double(items.count) / Double(columns)))
            let cardW = 380 * u, cardH = 170 * u, gap = 24 * u
            let gridW = Double(columns) * cardW + Double(columns - 1) * gap, gridH = Double(rows) * cardH + Double(rows - 1) * gap
            let top = (gridH + 140 * u) / 2
            f.words("heading", heading, at: CGPoint(x: 0, y: top - heading.ascent), start: 0, stagger: 0.07, align: .center, anchored: true)
            for (index, item) in items.enumerated() {
                let row = index / columns, column = index % columns
                let x = -gridW / 2 + Double(column) * (cardW + gap), y = top - 140 * u - Double(row + 1) * cardH - Double(row) * gap
                let rect = CGRect(x: x, y: y, width: cardW, height: cardH)
                let p = { (c: MotionClock) in c.spring(0.45 + Double(index) * 0.12, damping: 14, stiffness: 170) }
                f.group(around: CGPoint(x: rect.midX, y: rect.midY), scale: { c in 0.85 + 0.15 * p(c) }, alpha: p) {
                    f.plate({ _ in rect }, final: rect, round: s.style.roundness * 0.5 + 0.1, fill: .ink(.fixed(.white), 0.06))
                    let (symbol, font) = symbols[index % symbols.count]
                    let icon = s.body(symbol, size: 40 * u)
                    f.text(nil, icon, at: CGPoint(x: rect.minX + 30 * u, y: rect.maxY - 30 * u - 30 * u), gradient: true, motion: .init { _ in .init() }, font: font)
                    let card = String(localized: "Card \(index + 1)")
                    let title = s.title(item.0, size: 36 * u, tracking: -0.01)
                    f.text(nil, title, at: CGPoint(x: rect.minX + 30 * u, y: rect.minY + 62 * u), motion: .init { _ in .init() }, label: card)
                    let line = s.body(item.1, size: 26 * u)
                    f.text(nil, line, at: CGPoint(x: rect.minX + 30 * u, y: rect.minY + 28 * u), alpha: 0.6, motion: .init { _ in .init() },
                           label: String(localized: "Card \(index + 1) line"), body: true)
                }
            }

        case "subscribe":
            let clickAt = 1.55
            let time = { (c: MotionClock) in c.t * c.speed }
            let clicked = { (c: MotionClock) in time(c) > clickAt }
            let before = s.ink(on: s.style.accent), after = s.ink(on: s.style.secondary)
            let label = s.title(s.text("button"), size: 40 * u, color: before, tracking: 0)
            let done = s.title(s.text("done"), size: 40 * u, color: after, tracking: 0)
            let bh = label.height + 42 * u
            let bw = label.width + bh * 1.45, bw2 = done.width + bh * 1.45
            let pIn = { (c: MotionClock) in c.spring(0, damping: 10, stiffness: 190) }
            f.group(around: .zero, scale: { c in max(pIn(c) * (time(c) > 1.4 && time(c) < 1.7 ? 0.92 : 1), 0) }) {
                let rect = CGRect(x: -bw / 2, y: -bh / 2, width: bw, height: bh), rect2 = CGRect(x: -bw2 / 2, y: -bh / 2, width: bw2, height: bh)
                f.plate({ _ in rect }, final: rect, round: max(s.style.roundness, 0.5), fill: .gradient, glow: 1, alpha: { c in clicked(c) ? 0 : 1 })
                f.plate({ _ in rect2 }, final: rect2, round: max(s.style.roundness, 0.5), fill: .ink(.plate, 1), alpha: { c in clicked(c) ? 1 : 0 })
                f.text("button", label, at: CGPoint(x: 0, y: -label.height / 2 + label.descent), align: .center, anchored: true, ink: .fixed(before),
                       motion: .init { c in .init(alpha: clicked(c) ? 0 : Ease.clamp(pIn(c))) })
                f.text("done", done, at: CGPoint(x: 0, y: -done.height / 2 + done.descent), align: .center, anchored: true, ink: .fixed(after),
                       motion: .init { c in .init(alpha: clicked(c) ? 1 : 0) })
            }
            // The pointer: in from the lower right, a click, away.
            let start = CGPoint(x: bw * 0.9, y: -bh * 1.6), target = CGPoint(x: bw * 0.18, y: -bh * 0.05)
            let pointer = s.body("➤", size: 64 * u)
            f.text(nil, pointer, at: target, align: .center, anchored: true, ink: .fixed(.white), motion: .init { c in
                let p = Ease.inOutCubic(Ease.phase(time(c), 0.6, 0.8)), away = Ease.inCubic(Ease.phase(time(c), 2.1, 0.5))
                let at = CGPoint(x: Ease.lerp(start.x, target.x, p) + away * bw * 0.5, y: Ease.lerp(start.y, target.y, p) - away * bh)
                return .init(dx: at.x - target.x, dy: at.y - target.y, alpha: p > 0 ? 1 - away : 0,
                             scale: time(c) > 1.4 && time(c) < 1.6 ? 0.85 : 1)
            }, font: ("Menlo", "Regular"), angle: 135)
            f.ellipse({ _ in target }, radius: { c in 40 * u * Ease.outExpo(Ease.phase(time(c), 1.45, 0.5)) }, line: { _ in 3 * u },
                      fill: .ink(.fixed(.white), 1), alpha: { c in let p = Ease.phase(time(c), 1.45, 0.5); return p > 0 && p < 1 ? 0.6 * (1 - p) : 0 })

        case "quote":
            let size = 68 * u
            let lines = s.wrap(s.text("quote"), width: min(s.canvas.width * 0.75, 1300 * u) / s.placement.scale) { s.title($0, size: size, tracking: -0.02) }
            guard let first = lines.first else { return false }
            let lineHeight = size * 1.22
            let top = Double(lines.count) * lineHeight / 2
            let mark = s.title("“", size: 280 * u)
            let markX = align == .left ? mark.width / 2 : align == .right ? -mark.width / 2 : 0
            let pMark = { (c: MotionClock) in c.spring(0, damping: 11, stiffness: 170) }
            f.group(around: CGPoint(x: markX, y: top + 50 * u), scale: { c in max(pMark(c), 0.001) }, alpha: pMark) {
                f.text(nil, mark, at: CGPoint(x: markX, y: top + 50 * u - mark.ascent * 0.45), align: .center, anchored: true, gradient: true,
                       motion: .init { _ in .init() })
            }
            let anchorX = MotionDraw.start(0, at: 0, align: align)
            f.words("quote", first, at: CGPoint(x: anchorX, y: top - size - Double(lines.count - 1) * lineHeight), start: 0.3, stagger: 0.06, length: 0.5,
                    align: align, anchored: true, lines: lines.map(\.string), lineHeight: lineHeight)
            let count = lines.reduce(0) { $0 + $1.words.count }
            let author = s.body("— " + s.text("author"), size: 34 * u)
            f.focus("author", author, at: CGPoint(x: MotionDraw.start(author.width, at: 0, align: align), y: top - size - Double(lines.count) * lineHeight - 24 * u),
                    start: 0.4 + Double(count) * 0.06, length: 0.7, rise: 0, slide: 24, blur: 10, align: align, ink: .accent, body: true)

        case "progress":
            let width = s.canvas.width * 0.92 / s.placement.scale, height = 10 * u
            let track = CGRect(x: -width / 2, y: 0, width: width, height: height)
            let pIn = { (c: MotionClock) in Ease.outExpo(Ease.phase(c.t, 0, 0.5)) }
            let fill = { (c: MotionClock) in Ease.clamp(c.t / max(c.duration, 0.1)) }
            f.plate({ _ in track }, final: track, round: 1, fill: .ink(.plate, 0.45), alpha: pIn)
            f.plate({ c in CGRect(x: -width / 2, y: 0, width: max(width * fill(c), height), height: height) }, final: track, round: 1, fill: .gradient, glow: 0.6)
            f.ellipse({ c in CGPoint(x: -width / 2 + max(width * fill(c), height) - height / 2, y: height / 2) }, radius: { _ in height * 0.9 },
                      fill: .ink(.fixed(.white), 1), glow: 0.6, alpha: pIn)
            let label = s.text("label")
            if !label.isEmpty {
                let text = s.body(label, size: 26 * u)
                f.text("label", text, at: CGPoint(x: -width / 2, y: height + 16 * u + text.descent), alpha: 0.9, motion: .init { c in .init(alpha: pIn(c)) }, body: true)
            }

        case "caption":
            let size = 58 * u
            let lines = s.wrap(s.text("text"), width: min(s.canvas.width * 0.8, 1100 * u) / s.placement.scale) { s.title($0, size: size, tracking: -0.01) }
            guard !lines.isEmpty else { return false }
            let lineHeight = size * 1.3
            let words = lines.map(\.words)
            let count = max(words.reduce(0) { $0 + $1.count }, 1)
            let per = max(s.placement.duration - 0.6, 0.5) / Double(count)
            let widest = lines.map(\.width).max() ?? 0
            let pad = 28 * u
            let box = CGRect(x: -widest / 2 - pad, y: -Double(lines.count) * lineHeight / 2 - pad * 0.6,
                             width: widest + pad * 2, height: Double(lines.count) * lineHeight + pad * 1.2)
            let ink = s.ink(on: s.style.accent)
            f.group(around: .zero, scale: { c in max(Ease.spring(c.t * c.speed, damping: 13, stiffness: 200), 0) }) {
                f.plate({ _ in box }, final: box, round: s.style.roundness * 0.6, fill: .ink(.plate, 0.88))
                var index = 0
                var y = box.maxY - pad * 0.6 - size
                for (lineIndex, line) in lines.enumerated() {
                    let x = -line.width / 2
                    for word in words[lineIndex] {
                        let start = 0.3 + Double(index) * per
                        let on = { (c: MotionClock) in c.t >= start && c.t < start + per + 0.05 }
                        let rect = CGRect(x: x + word.x - 10 * u, y: y - word.text.descent - 6 * u, width: word.text.width + 20 * u, height: word.text.height + 12 * u)
                        f.group(around: CGPoint(x: rect.midX, y: rect.midY), scale: { c in 0.8 + 0.2 * Ease.spring(c.t - start, damping: 12, stiffness: 260) }) {
                            f.plate({ _ in rect }, final: rect, round: 0.45, fill: .gradient, glow: 0.6, alpha: { c in on(c) ? 1 : 0 })
                        }
                        f.text(nil, word.text, at: CGPoint(x: x + word.x, y: y), motion: .init { c in .init(alpha: on(c) ? 0 : c.t >= start - 0.15 ? 1 : 0.5) })
                        f.text(nil, word.text, at: CGPoint(x: x + word.x, y: y), ink: .fixed(ink), motion: .init { c in .init(alpha: on(c) ? 1 : 0) })
                        index += 1
                    }
                    y -= lineHeight
                }
            }

        default:
            return false
        }
        return true
    }
}

/// The Fusion self-test: each template's macro beside Pluck's own frames of it.
enum FusionSheet {
    static func write(to folder: URL, times: [Double] = [0.4, 0.8, 2.5]) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let canvas = CGSize(width: 1920, height: 1080)
        for template in MotionTemplate.all where FusionExport.supports(template) {
            try? FusionExport.write(template, style: MotionStyle(), placement: template.placement,
                                    to: folder.appendingPathComponent("\(template.id).setting"))
            for time in times {
                guard let context = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                context.setFillColor(CGColor(srgbRed: 0.32, green: 0.36, blue: 0.40, alpha: 1))
                context.fill(CGRect(origin: .zero, size: canvas))
                template.render(t: time, in: context, canvas: canvas, style: MotionStyle(), placement: template.placement)
                guard let image = context.makeImage(),
                      let destination = CGImageDestinationCreateWithURL(folder.appendingPathComponent("\(template.id)-\(Int(time * 25)).png") as CFURL,
                                                                        "public.png" as CFString, 1, nil) else { continue }
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
        }
    }
}
