import AppKit
import CoreText

/// More layouts for the Brand Pack's presets: plainer, flatter shapes that take every colour
/// from the brand (no glow or gradient of their own), each kept inside the frame's safe area.
extension MotionScene {
    /// The safe area in the scene's own coordinates (around the anchor, at its scale).
    var localSafe: CGRect {
        let k = max(placement.scale, 0.01)
        return CGRect(x: (safe.minX - anchor.x) / k, y: (safe.minY - anchor.y) / k, width: safe.width / k, height: safe.height / k)
    }

    /// Draws in the frame's own coordinates (origin bottom left, unscaled), for layouts that
    /// divide the whole frame.
    func inFrame(_ body: () -> Void) {
        context.saveGState()
        context.scaleBy(x: 1 / max(placement.scale, 0.01), y: 1 / max(placement.scale, 0.01))
        context.translateBy(x: -anchor.x, y: -anchor.y)
        body()
        context.restoreGState()
    }

    /// A colour the whole logo reads on (light behind a dark logo, dark behind a light one).
    func logoGround(_ logo: LogoAnimation) -> MotionColor {
        MotionColor(BrandPack(logo: logo, font: style.titleFont, lowerThirdStyle: .plate, background: nil).contrasting)
    }

    /// A plate in a colour the logo reads on, under it, when the card is too close to one of the
    /// logo's main colours (an orange logo on an orange card).
    func backLogo(_ logo: LogoAnimation, _ rect: CGRect, alpha: Double = 1) {
        guard let ground = style.background, alpha > 0.001,
              BrandPalette.colours(of: logo).dropFirst().prefix(2).contains(where: { $0.contrast(ground) < 1.5 }) else { return }
        let pad = min(rect.width, rect.height) * 0.22
        MotionDraw.plate(rect.insetBy(dx: -pad, dy: -pad), round: style.roundness * 0.5, color: logoGround(logo).alpha(alpha), in: context)
    }

    /// The logo's size fitted into `box`.
    func fitted(_ logo: LogoAnimation, width: Double, height: Double) -> CGSize {
        let k = min(width / max(logo.size.width, 1), height / max(logo.size.height, 1))
        return CGSize(width: logo.size.width * k, height: logo.size.height * k)
    }

    /// A rectangle (rounded by the style) whose outline draws itself round, `p` 0 … 1.
    func outline(_ rect: CGRect, width: Double, color: CGColor, progress p: Double) {
        guard p > 0.001 else { return }
        let radius = min(rect.width, rect.height) / 2 * Ease.clamp(style.roundness) * 0.6
        let perimeter = (rect.width + rect.height) * 2
        context.saveGState()
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.setLineDash(phase: 0, lengths: [perimeter * p, perimeter * 2])
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.strokePath()
        context.restoreGState()
    }
}

extension MotionTemplate {
    private static let endFields = [MotionField(key: "line", label: String(localized: "Line"), placeholder: "Thanks for watching"),
                                    MotionField(key: "handle", label: String(localized: "Handle"), placeholder: "@yourchannel"),
                                    MotionField(key: "brand", label: String(localized: "Name (without a logo)"), placeholder: "BRAND")]

    // MARK: Lower thirds

    /// An outline in the brand colour draws itself round the name; the role drops in below.
    static let outline = MotionTemplate(id: "outline", name: String(localized: "Outline"), category: .lowerThird, fields: nameFields,
                                        fullFrame: false, placement: MotionPlacement(x: 0.07, y: 0.12, duration: 6), canAlign: true) { s in
        let u = s.u, c = s.clock, cx = s.context
        let name = s.title(s.text("name"), size: 52 * u)
        let role = s.body(s.text("role"), size: 26 * u, alpha: 0.85, tracking: 0.14, uppercase: true)
        let pad = 26 * u
        let box = CGSize(width: name.width + pad * 2, height: name.height + pad * 1.4)
        let x0 = MotionDraw.start(max(box.width, role.width), at: 0, align: s.placement.align)
        let rect = CGRect(x: x0, y: role.height + 18 * u, width: box.width, height: box.height)
        s.outline(rect, width: 3 * u, color: s.style.accent.cg, progress: Ease.outExpo(c.part(0, 1)))
        MotionDraw.rise(name, at: CGPoint(x: rect.minX + pad, y: rect.minY + pad * 0.7 + name.descent), progress: Ease.outExpo(c.part(0.3, 0.6)), in: cx)
        MotionDraw.drop(role, at: CGPoint(x: x0, y: role.descent), progress: Ease.outExpo(c.part(0.5, 0.6)), in: cx)
    }

    /// A news-style strap: a block with the logo, the name's band and the role's band in the
    /// brand colour wiping out of it.
    static let broadcast = MotionTemplate(id: "broadcast", name: String(localized: "Broadcast"), category: .lowerThird, fields: nameFields,
                                          fullFrame: false, placement: MotionPlacement(x: 0.07, y: 0.1, duration: 6), canAlign: true) { s in
        let u = s.u, c = s.clock, cx = s.context
        let plate = MotionColor(r: s.style.secondary.r, g: s.style.secondary.g, b: s.style.secondary.b)
        let name = s.title(s.text("name"), size: 46 * u, color: s.ink(on: plate))
        let role = s.body(s.text("role"), size: 26 * u, color: s.ink(on: s.style.accent), tracking: 0.08, uppercase: true)
        let padX = 24 * u
        let nameH = name.height + 28 * u, roleH = role.height + 18 * u, block = nameH + roleH
        let bandW = max(name.width, role.width) + padX * 2
        let x0 = MotionDraw.start(block + bandW, at: 0, align: s.placement.align)
        let pBlock = Ease.outExpo(c.part(0, 0.5))
        let ground = s.logo.map(s.logoGround) ?? s.style.accent
        MotionDraw.plate(CGRect(x: x0, y: 0, width: block, height: block * pBlock), round: 0, color: ground.cg, in: cx)
        if let logo = s.logo {
            let size = s.fitted(logo, width: block - 24 * u, height: block - 24 * u)
            s.drawLogo(logo, in: CGRect(x: x0 + (block - size.width) / 2, y: (block - size.height) / 2, width: size.width, height: size.height),
                       alpha: Ease.clamp(c.part(0.3, 0.4)))
        } else if let first = s.text("name").first {
            let letter = s.title(String(first), size: block * 0.55, color: s.ink(on: ground))
            letter.draw(at: CGPoint(x: x0 + (block - letter.width) / 2, y: (block - letter.height) / 2 + letter.descent), in: cx,
                        alpha: Ease.clamp(c.part(0.3, 0.4)))
        }
        let nameRect = CGRect(x: x0 + block, y: roleH, width: bandW * Ease.outExpo(c.part(0.2, 0.6)), height: nameH)
        let roleRect = CGRect(x: x0 + block, y: 0, width: bandW * Ease.outExpo(c.part(0.32, 0.6)), height: roleH)
        MotionDraw.plate(nameRect, round: 0, color: plate.cg, in: cx)
        MotionDraw.plate(roleRect, round: 0, color: s.style.accent.cg, in: cx)
        cx.saveGState(); cx.clip(to: nameRect)
        MotionDraw.rise(name, at: CGPoint(x: nameRect.minX + padX, y: roleH + 14 * u + name.descent), progress: Ease.outExpo(c.part(0.4, 0.6)), in: cx)
        cx.restoreGState()
        cx.saveGState(); cx.clip(to: roleRect)
        MotionDraw.rise(role, at: CGPoint(x: roleRect.minX + padX, y: 9 * u + role.descent), progress: Ease.outExpo(c.part(0.5, 0.6)), in: cx)
        cx.restoreGState()
    }

    /// The role in a small tag of the brand colour pops in, the name rises large beneath it.
    static let tag = MotionTemplate(id: "tag", name: String(localized: "Tag"), category: .lowerThird, fields: nameFields,
                                    fullFrame: false, placement: MotionPlacement(x: 0.07, y: 0.12, duration: 6), canAlign: true) { s in
        let u = s.u, c = s.clock, cx = s.context
        let name = s.title(s.text("name"), size: 64 * u)
        let role = s.body(s.text("role"), size: 22 * u, color: s.ink(on: s.style.accent), tracking: 0.14, uppercase: true)
        let tagSize = CGSize(width: role.width + 28 * u, height: role.height + 14 * u)
        let x0 = MotionDraw.start(max(name.width, tagSize.width), at: 0, align: s.placement.align)
        let pTag = max(c.spring(0, damping: 16, stiffness: 190), 0)
        let tagRect = CGRect(x: x0, y: name.height + 14 * u, width: tagSize.width * pTag, height: tagSize.height)
        if !s.text("role").isEmpty {
            MotionDraw.plate(tagRect, round: s.style.roundness * 0.5, color: s.style.accent.cg, in: cx)
            cx.saveGState(); cx.clip(to: tagRect)
            role.draw(at: CGPoint(x: x0 + 14 * u, y: tagRect.minY + 7 * u + role.descent), in: cx, alpha: Ease.clamp(c.part(0.2, 0.3)))
            cx.restoreGState()
        }
        MotionDraw.rise(name, at: CGPoint(x: x0, y: name.descent), progress: Ease.outExpo(c.part(0.25, 0.65)), in: cx)
    }

    /// A slanted marker in the brand colour sweeps across, the name set on it; the role below.
    static let highlight = MotionTemplate(id: "highlight", name: String(localized: "Marker"), category: .lowerThird, fields: nameFields,
                                          fullFrame: false, placement: MotionPlacement(x: 0.07, y: 0.12, duration: 6), canAlign: true) { s in
        let u = s.u, c = s.clock, cx = s.context
        let name = s.title(s.text("name"), size: 58 * u, color: s.ink(on: s.style.accent))
        let role = s.body(s.text("role"), size: 28 * u, alpha: 0.9)
        let pad = 22 * u, slant = 16 * u
        let h = name.height + pad
        let w = name.width + pad * 2 + slant
        let x0 = MotionDraw.start(max(w, role.width), at: 0, align: s.placement.align)
        let y0 = role.height + 16 * u
        let p = Ease.outExpo(c.part(0.05, 0.6))
        let marker = CGMutablePath()
        marker.move(to: CGPoint(x: x0, y: y0))
        marker.addLine(to: CGPoint(x: x0 + (w - slant) * p, y: y0))
        marker.addLine(to: CGPoint(x: x0 + slant + (w - slant) * p, y: y0 + h))
        marker.addLine(to: CGPoint(x: x0 + slant, y: y0 + h))
        marker.closeSubpath()
        if p > 0.001 {
            cx.setFillColor(s.style.accent.cg)
            cx.addPath(marker)
            cx.fillPath()
        }
        cx.saveGState(); cx.addPath(marker); cx.clip()
        MotionDraw.rise(name, at: CGPoint(x: x0 + pad + slant / 2, y: y0 + pad / 2 + name.descent), progress: Ease.outExpo(c.part(0.3, 0.6)), in: cx)
        cx.restoreGState()
        cx.saveGState()
        cx.setShadow(offset: CGSize(width: 0, height: -2 * u), blur: 8 * u, color: CGColor(gray: 0, alpha: 0.4))
        MotionDraw.drop(role, at: CGPoint(x: x0 + slant / 2, y: role.descent), progress: Ease.outExpo(c.part(0.5, 0.6)), in: cx)
        cx.restoreGState()
    }

    // MARK: Titles

    /// The title one word a line, as big as the safe area allows, every other line in the
    /// brand colour, each rising out of its own edge.
    static let bigType = MotionTemplate(id: "bigtype", name: String(localized: "Big Type"), category: .title, fields: titleFields, fullFrame: true,
                                        placement: MotionPlacement(x: 0.5, y: 0.5, duration: 5, align: .left), canAlign: true) { s in
        let u = s.u, c = s.clock, cx = s.context, safe = s.localSafe
        let words = s.text("title").split(separator: " ").map(String.init)
        guard !words.isEmpty else { return }
        let base = 260 * u
        let widest = words.map { s.title($0, size: base, tracking: -0.03).width }.max() ?? 1
        let size = min(base, base * safe.width * 0.9 / max(widest, 1), safe.height * 0.78 / (Double(words.count) * 0.92 + 0.5))
        let lineH = size * 0.92
        let x = s.placement.align == .left ? safe.minX + safe.width * 0.05 : s.placement.align == .right ? safe.maxX - safe.width * 0.05 : 0
        var y = Double(words.count - 1) * lineH / 2 - size * 0.3 + size * 0.25
        for (index, word) in words.enumerated() {
            let line = s.title(word, size: size, color: index % 2 == 1 ? s.style.accent : nil, tracking: -0.03)
            MotionDraw.rise(line, at: CGPoint(x: MotionDraw.start(line.width, at: x, align: s.placement.align), y: y),
                            progress: Ease.outExpo(c.part(0.05 + Double(index) * 0.09, 0.6)), in: cx, from: 1.0)
            y -= lineH
        }
        let subtitle = s.body(s.text("subtitle"), size: 34 * u, alpha: 0.8, tracking: 0.04)
        MotionDraw.drop(subtitle, at: CGPoint(x: MotionDraw.start(subtitle.width, at: x, align: s.placement.align), y: y + lineH - size * 0.55 - subtitle.ascent),
                        progress: Ease.outExpo(c.part(0.5, 0.6)), in: cx)
    }

    /// A solid box in the brand colour wipes open, the title rising inside; the subtitle below.
    static let boxed = MotionTemplate(id: "boxed", name: String(localized: "Boxed"), category: .title, fields: titleFields, fullFrame: true,
                                      placement: MotionPlacement(x: 0.5, y: 0.5, duration: 5), canAlign: false) { s in
        let u = s.u, c = s.clock, cx = s.context, safe = s.localSafe
        let pad = 48 * u
        let lines = s.wrap(s.text("title"), width: safe.width * 0.82 - pad * 2) { s.title($0, size: 96 * u, color: s.ink(on: s.style.accent)) }
        guard !lines.isEmpty else { return }
        let lineH = 96 * u * 1.05
        let w = (lines.map(\.width).max() ?? 0) + pad * 2, h = Double(lines.count) * lineH + pad * 1.2
        let box = CGRect(x: -w / 2, y: -h / 2 + 30 * u, width: w * Ease.outExpo(c.part(0, 0.6)), height: h)
        MotionDraw.plate(box, round: s.style.roundness * 0.3, color: s.style.accent.cg, in: cx)
        cx.saveGState(); cx.clip(to: box)
        var y = box.maxY - pad * 0.6 - lineH * 0.78
        for (index, line) in lines.enumerated() {
            MotionDraw.rise(line, at: CGPoint(x: -line.width / 2, y: y), progress: Ease.outExpo(c.part(0.35 + Double(index) * 0.08, 0.6)), in: cx)
            y -= lineH
        }
        cx.restoreGState()
        let subtitle = s.body(s.text("subtitle"), size: 36 * u, alpha: 0.85)
        MotionDraw.drop(subtitle, at: CGPoint(x: -subtitle.width / 2, y: box.minY - 40 * u - subtitle.ascent), progress: Ease.outExpo(c.part(0.6, 0.6)), in: cx)
    }

    /// A quiet title: small, centred, between two thin rules that draw outwards; no blur, no glow.
    static let minimal = MotionTemplate(id: "minimal", name: String(localized: "Minimal"), category: .title, fields: titleFields, fullFrame: true,
                                        placement: MotionPlacement(x: 0.5, y: 0.5, duration: 5), canAlign: false) { s in
        let u = s.u, c = s.clock, cx = s.context, safe = s.localSafe
        var title = s.title(s.text("title"), size: 76 * u, tracking: 0.02)
        if title.width > safe.width * 0.7 { title = s.title(s.text("title"), size: 76 * u * safe.width * 0.7 / title.width, tracking: 0.02) }
        let pTitle = Ease.outCubic(c.part(0.1, 0.9))
        title.draw(at: CGPoint(x: -title.width / 2, y: -title.height / 2 + title.descent + (1 - pTitle) * -16 * u), in: cx, alpha: pTitle)
        let rule = min(110 * u, (safe.width - title.width) / 2 - 40 * u)
        let pRule = Ease.outExpo(c.part(0.4, 0.8))
        if rule > 4 * u {
            let y = 0.0, gap = 30 * u
            MotionDraw.line(from: CGPoint(x: -title.width / 2 - gap, y: y), to: CGPoint(x: -title.width / 2 - gap - rule, y: y), width: 2 * u,
                            color: s.style.accent.cg, progress: pRule, in: cx)
            MotionDraw.line(from: CGPoint(x: title.width / 2 + gap, y: y), to: CGPoint(x: title.width / 2 + gap + rule, y: y), width: 2 * u,
                            color: s.style.accent.cg, progress: pRule, in: cx)
        }
        let subtitle = s.body(s.text("subtitle"), size: 26 * u, alpha: 0.7, tracking: 0.22, uppercase: true)
        let pSub = Ease.outCubic(c.part(0.6, 0.8))
        subtitle.draw(at: CGPoint(x: -subtitle.width / 2, y: -title.height / 2 - 50 * u - subtitle.ascent), in: cx, alpha: pSub)
    }

    // MARK: Logo & end

    /// Two panels in the brand's colours wipe across the frame; the logo is there as they pass.
    static let wipe = MotionTemplate(id: "wipe", name: String(localized: "Wipe Sting"), category: .logo,
                                     fields: [MotionField(key: "brand", label: String(localized: "Name (without a logo)"), placeholder: "BRAND")],
                                     fullFrame: true, placement: MotionPlacement(x: 0.5, y: 0.5, duration: 3), canAlign: false) { s in
        let u = s.u, c = s.clock, cx = s.context
        s.inFrame {
            let w = s.canvas.width, h = s.canvas.height
            for (index, color) in [s.style.accent, s.style.accent2].enumerated() {
                let p = Ease.inOutCubic(Ease.phase(s.time, Double(index) * 0.12, 0.85))
                guard p > 0, p < 1 else { continue }
                let x = -w * 1.2 + p * w * 2.4
                let panel = CGMutablePath()
                panel.addLines(between: [CGPoint(x: x, y: 0), CGPoint(x: x + w * 0.7, y: 0), CGPoint(x: x + w * 0.9, y: h), CGPoint(x: x + w * 0.2, y: h)])
                panel.closeSubpath()
                cx.setFillColor(color.cg)
                cx.addPath(panel)
                cx.fillPath()
            }
        }
        let pLogo = Ease.outExpo(c.part(0.45, 0.7))
        let grow = 0.94 + 0.06 * pLogo
        cx.saveGState()
        cx.scaleBy(x: grow, y: grow)
        if let logo = s.logo {
            let size = s.fitted(logo, width: s.localSafe.width * 0.5, height: s.localSafe.height * 0.4)
            s.drawLogo(logo, in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height), alpha: pLogo)
        } else {
            let word = s.title(s.text("brand"), size: 150 * u, tracking: 0.04)
            word.draw(at: CGPoint(x: -word.width / 2, y: -word.height / 2 + word.descent), in: cx, alpha: pLogo)
        }
        cx.restoreGState()
    }

    /// The logo still and centred, a thin rule, the line and the handle: nothing else.
    static let endMinimal = MotionTemplate(id: "endminimal", name: String(localized: "Minimal End"), category: .logo, fields: endFields,
                                           fullFrame: true, placement: MotionPlacement(x: 0.5, y: 0.5, duration: 5), canAlign: false) { s in
        let u = s.u, c = s.clock, cx = s.context, safe = s.localSafe
        let pLogo = Ease.outCubic(c.part(0, 0.8))
        let lift = (1 - pLogo) * -12 * u
        if let logo = s.logo {
            let size = s.fitted(logo, width: safe.width * 0.5, height: safe.height * 0.26)
            s.drawLogo(logo, in: CGRect(x: -size.width / 2, y: 50 * u + lift, width: size.width, height: size.height), alpha: pLogo)
        } else {
            let word = s.title(s.text("brand"), size: 110 * u, tracking: 0.04)
            word.draw(at: CGPoint(x: -word.width / 2, y: 60 * u + word.descent + lift), in: cx, alpha: pLogo)
        }
        let rule = 120 * u * Ease.outExpo(c.part(0.4, 0.7))
        MotionDraw.plate(CGRect(x: -rule / 2, y: 10 * u, width: rule, height: 2 * u), round: 0, color: s.style.accent.cg, in: cx)
        var line = s.title(s.text("line"), size: 50 * u, tracking: -0.01)
        if line.width > safe.width * 0.9 { line = s.title(s.text("line"), size: 50 * u * safe.width * 0.9 / line.width, tracking: -0.01) }
        MotionDraw.rise(line, at: CGPoint(x: -line.width / 2, y: -40 * u - line.ascent), progress: Ease.outExpo(c.part(0.55, 0.6)), in: cx)
        let handle = s.body(s.text("handle"), size: 28 * u, alpha: 0.7)
        handle.draw(at: CGPoint(x: -handle.width / 2, y: -60 * u - line.height - handle.ascent), in: cx, alpha: Ease.clamp(c.part(0.8, 0.5)))
    }

    /// Half the frame (the top half on a vertical video) a panel the logo reads on, sliding in;
    /// the line and handle on the other half.
    static let endSplit = MotionTemplate(id: "endsplit", name: String(localized: "Split End"), category: .logo, fields: endFields,
                                         fullFrame: true, placement: MotionPlacement(x: 0.5, y: 0.5, duration: 5), canAlign: false) { s in
        let u = s.u, c = s.clock, cx = s.context
        s.inFrame {
            let w = s.canvas.width, h = s.canvas.height, safe = s.safe
            let wide = w >= h
            let p = Ease.outExpo(c.part(0, 0.7))
            let panel = wide ? CGRect(x: 0, y: 0, width: w / 2 * p, height: h) : CGRect(x: 0, y: h - h / 2 * p, width: w, height: h / 2)
            let ground = s.logo.map(s.logoGround) ?? s.style.accent
            MotionDraw.plate(panel, round: 0, color: ground.cg, in: cx)
            let half = wide ? CGRect(x: safe.minX, y: safe.minY, width: w / 2 - safe.minX, height: safe.height)
                : CGRect(x: safe.minX, y: h / 2, width: safe.width, height: safe.maxY - h / 2)
            if let logo = s.logo {
                let size = s.fitted(logo, width: half.width * 0.7, height: half.height * 0.5)
                s.drawLogo(logo, in: CGRect(x: half.midX - size.width / 2 - (wide ? w / 2 * (1 - p) : 0), y: half.midY - size.height / 2,
                                            width: size.width, height: size.height), alpha: Ease.clamp(c.part(0.3, 0.5)))
            } else {
                let word = s.title(s.text("brand"), size: 110 * u, color: s.ink(on: ground), tracking: 0.04)
                word.draw(at: CGPoint(x: half.midX - word.width / 2, y: half.midY - word.height / 2 + word.descent), in: cx, alpha: Ease.clamp(c.part(0.3, 0.5)))
            }
            let other = wide ? CGRect(x: w / 2, y: safe.minY, width: safe.maxX - w / 2, height: safe.height)
                : CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: h / 2 - safe.minY)
            let margin = 60 * u
            let lines = s.wrap(s.text("line"), width: other.width - margin * 2) { s.title($0, size: 64 * u, tracking: -0.02) }
            let lineH = 64 * u * 1.08
            var y = other.midY + Double(lines.count) * lineH / 2 - lineH * 0.8
            for (index, line) in lines.enumerated() {
                MotionDraw.rise(line, at: CGPoint(x: other.minX + margin, y: y), progress: Ease.outExpo(c.part(0.45 + Double(index) * 0.08, 0.6)), in: cx)
                y -= lineH
            }
            let rule = 70 * u * Ease.outExpo(c.part(0.6, 0.6))
            MotionDraw.plate(CGRect(x: other.minX + margin, y: y + lineH * 0.45, width: rule, height: 4 * u), round: 0, color: s.style.accent.cg, in: cx)
            let handle = s.body(s.text("handle"), size: 30 * u, alpha: 0.75)
            handle.draw(at: CGPoint(x: other.minX + margin, y: y + lineH * 0.45 - 30 * u - handle.ascent), in: cx, alpha: Ease.clamp(c.part(0.75, 0.5)))
        }
    }

    /// The line big at the top left with a bar beside it, the handle below, the logo small in
    /// the bottom right corner.
    static let endCorner = MotionTemplate(id: "endcorner", name: String(localized: "Corner End"), category: .logo, fields: endFields,
                                          fullFrame: true, placement: MotionPlacement(x: 0.5, y: 0.5, duration: 5), canAlign: false) { s in
        let u = s.u, c = s.clock, cx = s.context
        s.inFrame {
            let safe = s.safe.insetBy(dx: 36 * u, dy: 30 * u)
            let size = min(110 * u, safe.width * 0.12)
            let lines = s.wrap(s.text("line"), width: safe.width * 0.8) { s.title($0, size: size, tracking: -0.03) }
            let lineH = size * 1.0
            let bar = 10 * u
            let top = safe.maxY - size * 0.85
            let pBar = Ease.outExpo(c.part(0, 0.6))
            let block = Double(max(lines.count, 1)) * lineH
            MotionDraw.plate(CGRect(x: safe.minX, y: safe.maxY - block * pBar, width: bar, height: block * pBar), round: 0, color: s.style.accent.cg, in: cx)
            var y = top
            for (index, line) in lines.enumerated() {
                MotionDraw.rise(line, at: CGPoint(x: safe.minX + bar + 30 * u, y: y), progress: Ease.outExpo(c.part(0.2 + Double(index) * 0.08, 0.6)), in: cx)
                y -= lineH
            }
            let handle = s.body(s.text("handle"), size: 32 * u, alpha: 0.75)
            handle.draw(at: CGPoint(x: safe.minX, y: safe.minY + handle.descent), in: cx, alpha: Ease.clamp(c.part(0.6, 0.5)))
            let pLogo = Ease.outCubic(c.part(0.5, 0.7))
            if let logo = s.logo {
                let fit = s.fitted(logo, width: safe.width * 0.3, height: safe.height * 0.16)
                s.drawLogo(logo, in: CGRect(x: safe.maxX - fit.width, y: safe.minY, width: fit.width, height: fit.height), alpha: pLogo)
            } else {
                let word = s.title(s.text("brand"), size: 48 * u, tracking: 0.06)
                word.draw(at: CGPoint(x: safe.maxX - word.width, y: safe.minY + word.descent), in: cx, alpha: pLogo)
            }
        }
    }

    /// The logo small in a corner over the picture (a bug, or watermark), fading in and out.
    static let bug = MotionTemplate(id: "bug", name: String(localized: "Logo Bug"), category: .logo,
                                    fields: [MotionField(key: "brand", label: String(localized: "Name (without a logo)"), placeholder: "BRAND")],
                                    fullFrame: false, placement: MotionPlacement(x: 0.95, y: 0.93, duration: 10), canAlign: false) { s in
        let u = s.u, c = s.clock, cx = s.context
        let p = Ease.outCubic(c.part(0, 0.8)) * 0.9
        if let logo = s.logo {
            let size = s.fitted(logo, width: 240 * u, height: 72 * u)
            s.drawLogo(logo, in: CGRect(x: -size.width, y: -size.height, width: size.width, height: size.height), alpha: p)
        } else {
            let word = s.title(s.text("brand"), size: 40 * u, tracking: 0.06)
            word.draw(at: CGPoint(x: -word.width, y: -word.ascent), in: cx, alpha: p)
        }
    }
}
