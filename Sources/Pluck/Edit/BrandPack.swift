import AppKit
import CoreText

/// A brand pack from a logo: lower thirds, a title card and an end card in the logo's own colours,
/// animated the way a motion designer would (wipes and masked reveals that settle, nothing
/// bouncing), as video files with transparency for the edit.
struct BrandPack {
    let logo: LogoAnimation
    /// The font family for the text ("Helvetica Neue", "Avenir Next"…).
    var font: String
    var lowerThirdStyle: LowerThirdStyle
    /// Behind the title and end cards (nil: transparent). Lower thirds are always transparent.
    var background: CGColor?

    enum LowerThirdStyle: String, CaseIterable, Identifiable {
        case plate, line
        var id: String { rawValue }
        var label: String {
            switch self {
            case .plate: String(localized: "Plates in the brand colour")
            case .line: String(localized: "A line and the text over the picture")
            }
        }
    }

    enum Graphic: Hashable {
        case lowerThird(name: String, role: String)
        case title(title: String, subtitle: String)
        case endCard(line: String)

        var fileName: String {
            switch self {
            case .lowerThird(let name, _): String(localized: "Lower third – \(name)")
            case .title: String(localized: "Title card")
            case .endCard: String(localized: "End card")
            }
        }
    }

    // MARK: - Colours

    /// The logo's colours by how much of it they cover, the main one first.
    var palette: [CGColor] {
        var totals: [(colour: CGColor, rgb: SIMD3<Double>, area: Double)] = []
        for element in logo.elements {
            let c = Self.rgb(element.colour)
            if let n = totals.firstIndex(where: { (($0.rgb - c) * ($0.rgb - c)).sum() < 0.04 }) { totals[n].area += element.area }
            else { totals.append((element.colour, c, element.area)) }
        }
        return totals.sorted { $0.area > $1.area }.map(\.colour)
    }

    /// The colour the graphics are built on: the logo's colourful one (its accent), or its main colour.
    var brand: CGColor { logo.accentColour }

    /// A background the whole logo reads on: white behind a dark logo, near black behind a light one.
    var contrasting: CGColor {
        let main = palette.first ?? CGColor(gray: 0, alpha: 1)
        return Self.luminance(main) > 0.6 ? CGColor(srgbRed: 0.06, green: 0.06, blue: 0.07, alpha: 1) : CGColor(gray: 1, alpha: 1)
    }

    /// White or near black, whichever reads on `colour`.
    static func ink(on colour: CGColor) -> CGColor {
        luminance(colour) > 0.55 ? CGColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1) : CGColor(gray: 1, alpha: 1)
    }

    static func luminance(_ colour: CGColor) -> Double {
        let c = rgb(colour)
        return 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
    }

    static func rgb(_ colour: CGColor) -> SIMD3<Double> {
        let v = colour.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
        return SIMD3(v[0], v[min(1, v.count - 1)], v[min(2, v.count - 1)])
    }

    // MARK: - Timing

    func length(_ graphic: Graphic) -> Double {
        switch graphic {
        case .lowerThird: 6
        case .title: 5
        case .endCard: endPlan.intro + 3
        }
    }

    /// The end card's logo animation: the logo's own style, settled and held.
    private var endPlan: LogoAnimation.Plan { logo.plan(logo.suggestedStyle, outro: .none) }

    // MARK: - Drawing

    func draw(_ graphic: Graphic, at t: Double, in context: CGContext, canvas: CGSize) {
        switch graphic {
        case .lowerThird(let name, let role):
            switch lowerThirdStyle {
            case .plate: drawPlateLowerThird(name: name, role: role, t: t, length: length(graphic), context: context, canvas: canvas)
            case .line: drawLineLowerThird(name: name, role: role, t: t, length: length(graphic), context: context, canvas: canvas)
            }
        case .title(let title, let subtitle):
            fill(context, canvas)
            drawTitle(title: title, subtitle: subtitle, t: t, length: length(graphic), context: context, canvas: canvas)
        case .endCard(let line):
            fill(context, canvas)
            drawEndCard(line: line, t: t, context: context, canvas: canvas)
        }
    }

    private func fill(_ context: CGContext, _ canvas: CGSize) {
        guard let background else { return }
        context.setFillColor(background)
        context.fill(CGRect(origin: .zero, size: canvas))
    }

    /// Size unit: 1 on a 1080-pixel short side.
    private func unit(_ canvas: CGSize) -> Double { min(canvas.width, canvas.height) / 1080 }

    /// 0…1 over `[start, start + duration]`, eased.
    private func phase(_ t: Double, _ start: Double, _ duration: Double, _ ease: (Double) -> Double = Easing.outQuint) -> Double {
        ease(min(max((t - start) / duration, 0), 1))
    }

    /// How far in (1) or out (0) the graphic is at `t`: in at the start, out over the last 0.6 s.
    private func out(_ t: Double, _ length: Double) -> Double {
        1 - phase(t, length - 0.6, 0.6, Easing.inOutCubic)
    }

    // MARK: Lower thirds

    private func lowerThirdOrigin(_ canvas: CGSize) -> CGPoint {
        let vertical = canvas.height > canvas.width
        // Inside the title-safe area; on a vertical video above the platform's captions.
        return CGPoint(x: canvas.width * (vertical ? 0.08 : 0.07), y: canvas.height * (vertical ? 0.27 : 0.13))
    }

    private func drawPlateLowerThird(name: String, role: String, t: Double, length: Double, context: CGContext, canvas: CGSize) {
        let u = unit(canvas)
        let origin = lowerThirdOrigin(canvas)
        let nameText = Self.line(name, family: font, size: 54 * u, weight: .bold, colour: Self.ink(on: brand))
        let roleColour = CGColor(gray: 0.08, alpha: 0.88)
        let roleText = Self.line(role, family: font, size: 34 * u, weight: .regular, colour: Self.ink(on: roleColour))
        let padX = 28 * u, padY = 16 * u
        let nameBox = CGSize(width: nameText.width + padX * 2, height: nameText.height + padY * 2)
        let roleBox = CGSize(width: roleText.width + padX * 2, height: roleText.height + padY * 1.4)
        let leaving = out(t, length)

        // A small logo beside it, when the logo is compact enough to sit there.
        var x = origin.x
        let mark = nameBox.height
        if logo.size.width / logo.size.height < 2.4 {
            let width = mark * logo.size.width / logo.size.height
            let grow = Physics.spring(t, frequency: 2.2, damping: 0.75) * leaving
            context.saveGState()
            context.setAlpha(min(t * 4, 1) * leaving)
            let rect = CGRect(x: x, y: origin.y + (role.isEmpty ? 0 : roleBox.height), width: width, height: mark)
            context.translateBy(x: rect.midX, y: rect.midY)
            context.scaleBy(x: grow, y: grow)
            context.draw(logo.logo, in: CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height))
            context.restoreGState()
            x += width + 16 * u
        }

        // The name's plate wipes open from the left, then the name rises into it.
        let nameRect = CGRect(x: x, y: origin.y + (role.isEmpty ? 0 : roleBox.height), width: nameBox.width, height: nameBox.height)
        let open = phase(t, 0.1, 0.55) * (1 - phase(t, length - 0.45, 0.45, Easing.inOutCubic))
        context.setFillColor(brand)
        context.fill(CGRect(x: nameRect.minX, y: nameRect.minY, width: nameRect.width * open, height: nameRect.height))
        // (Seen only inside the open part of the plate, so nothing shows beside it as it closes.)
        drawRising(nameText, at: CGPoint(x: nameRect.minX + padX, y: nameRect.minY + padY),
                   within: CGRect(x: nameRect.minX, y: nameRect.minY, width: nameRect.width * open, height: nameRect.height),
                   progress: phase(t, 0.3, 0.6) * leaving, context: context)

        // The role underneath, a beat later.
        guard !role.isEmpty else { return }
        let roleRect = CGRect(x: x, y: origin.y, width: roleBox.width, height: roleBox.height)
        let roleOpen = phase(t, 0.3, 0.55) * (1 - phase(t, length - 0.55, 0.45, Easing.inOutCubic))
        context.setFillColor(roleColour)
        context.fill(CGRect(x: roleRect.minX, y: roleRect.minY, width: roleRect.width * roleOpen, height: roleRect.height))
        drawRising(roleText, at: CGPoint(x: roleRect.minX + padX, y: roleRect.minY + padY * 0.7),
                   within: CGRect(x: roleRect.minX, y: roleRect.minY, width: roleRect.width * roleOpen, height: roleRect.height),
                   progress: phase(t, 0.45, 0.6) * leaving, context: context)
    }

    private func drawLineLowerThird(name: String, role: String, t: Double, length: Double, context: CGContext, canvas: CGSize) {
        let u = unit(canvas)
        let origin = lowerThirdOrigin(canvas)
        let white = CGColor(gray: 1, alpha: 1)
        let nameText = Self.line(name, family: font, size: 56 * u, weight: .semibold, colour: white)
        let roleText = Self.line(role, family: font, size: 34 * u, weight: .regular, colour: CGColor(gray: 1, alpha: 0.85))
        let gap = 10 * u
        let block = nameText.height + (role.isEmpty ? 0 : roleText.height + gap)
        let leaving = out(t, length)

        // The line grows up in the brand colour…
        let lineWidth = 6 * u
        let grow = phase(t, 0, 0.5) * (1 - phase(t, length - 0.35, 0.35, Easing.inOutCubic))
        context.setFillColor(brand)
        context.fill(CGRect(x: origin.x, y: origin.y, width: lineWidth, height: block * grow))

        // …and the text slides out from behind it, over the picture with a soft shadow.
        let textX = origin.x + lineWidth + 22 * u
        let window = CGRect(x: textX, y: origin.y - 20 * u, width: canvas.width, height: block + 40 * u)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2 * u), blur: 10 * u, color: CGColor(gray: 0, alpha: 0.45))
        drawSliding(nameText, at: CGPoint(x: textX, y: origin.y + (role.isEmpty ? 0 : roleText.height + gap)), within: window,
                    progress: phase(t, 0.25, 0.7) * leaving, context: context)
        if !role.isEmpty {
            drawSliding(roleText, at: CGPoint(x: textX, y: origin.y), within: window,
                        progress: phase(t, 0.4, 0.7) * leaving, context: context)
        }
        context.restoreGState()
    }

    // MARK: Title and end cards

    private func drawTitle(title: String, subtitle: String, t: Double, length: Double, context: CGContext, canvas: CGSize) {
        let u = unit(canvas)
        let ink = background.map(Self.ink(on:)) ?? CGColor(gray: 1, alpha: 1)
        let accent = background.map { Self.differs($0, brand) ? brand : ink } ?? brand
        var size = 118 * u
        var titleText = Self.line(title, family: font, size: size, weight: .bold, colour: ink)
        // Long titles shrink to fit the safe area.
        if titleText.width > canvas.width * 0.84 {
            size *= canvas.width * 0.84 / titleText.width
            titleText = Self.line(title, family: font, size: size, weight: .bold, colour: ink)
        }
        let subtitleText = Self.line(subtitle, family: font, size: 44 * u, weight: .regular, colour: ink.copy(alpha: 0.8) ?? ink)
        let leaving = out(t, length)
        context.setAlpha(leaving)

        let titleY = canvas.height * 0.52
        let titleRect = CGRect(x: (canvas.width - titleText.width) / 2, y: titleY, width: titleText.width, height: titleText.height)
        drawRising(titleText, at: titleRect.origin, within: titleRect.insetBy(dx: -40 * u, dy: 0), progress: phase(t, 0.1, 0.8), context: context)

        // A short line in the brand colour draws out from the middle.
        let lineWidth = min(titleText.width * 0.3, 260 * u) * phase(t, 0.45, 0.6)
        context.setFillColor(accent)
        context.fill(CGRect(x: canvas.width / 2 - lineWidth / 2, y: titleY - 34 * u, width: lineWidth, height: 5 * u))

        if !subtitle.isEmpty {
            let p = phase(t, 0.7, 0.7)
            context.saveGState()
            context.setAlpha(p * leaving)
            subtitleText.draw(at: CGPoint(x: (canvas.width - subtitleText.width) / 2, y: titleY - 34 * u - 30 * u - subtitleText.height - (1 - p) * 14 * u),
                              in: context)
            context.restoreGState()
        }

        // The logo, small, at the bottom.
        let markHeight = 64 * u
        let markWidth = min(markHeight * logo.size.width / logo.size.height, canvas.width * 0.3)
        let markRect = CGRect(x: (canvas.width - markWidth) / 2, y: canvas.height * 0.09,
                              width: markWidth, height: markWidth * logo.size.height / logo.size.width)
        context.saveGState()
        context.setAlpha(phase(t, 0.9, 0.6) * leaving)
        context.draw(logo.logo, in: markRect)
        context.restoreGState()
    }

    private func drawEndCard(line: String, t: Double, context: CGContext, canvas: CGSize) {
        let u = unit(canvas)
        let plan = endPlan
        // The logo's own animation, a little smaller and above the middle to leave room for the line.
        context.saveGState()
        context.translateBy(x: canvas.width * 0.5, y: canvas.height * 0.56)
        context.scaleBy(x: 0.82, y: 0.82)
        context.translateBy(x: -canvas.width * 0.5, y: -canvas.height * 0.5)
        logo.draw(at: t, plan: plan, in: context, canvas: canvas)
        context.restoreGState()

        guard !line.isEmpty else { return }
        let ink = background.map(Self.ink(on:)) ?? CGColor(gray: 1, alpha: 1)
        let text = Self.line(line, family: font, size: 46 * u, weight: .medium, colour: ink)
        let p = phase(t, plan.intro - 0.2, 0.8)
        context.saveGState()
        context.setAlpha(p)
        text.draw(at: CGPoint(x: (canvas.width - text.width) / 2, y: canvas.height * 0.2 - (1 - p) * 16 * u), in: context)
        context.restoreGState()
    }

    /// Whether two colours are far enough apart to see one on the other.
    private static func differs(_ a: CGColor, _ b: CGColor) -> Bool {
        let d = rgb(a) - rgb(b)
        return (d * d).sum() > 0.08
    }

    // MARK: Text

    /// One line of text, measured.
    struct Line {
        let ctLine: CTLine
        let width: Double
        let height: Double
        let descent: Double

        func draw(at point: CGPoint, in context: CGContext) {
            context.saveGState()
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: point.x, y: point.y + descent)
            CTLineDraw(ctLine, context)
            context.restoreGState()
        }
    }

    static func line(_ text: String, family: String, size: Double, weight: NSFont.Weight, colour: CGColor) -> Line {
        let font = Self.font(family: family, size: size, weight: weight)
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(cgColor: colour) ?? .white])
        let ctLine = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading)
        return Line(ctLine: ctLine, width: width, height: ascent + descent, descent: descent)
    }

    static func font(family: String, size: Double, weight: NSFont.Weight) -> NSFont {
        let traits: [NSFontDescriptor.TraitKey: Any] = [.weight: weight.rawValue]
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family, .traits: traits])
        return NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// Text rising into place from under `window`'s bottom edge (it's only seen inside the window).
    private func drawRising(_ text: Line, at point: CGPoint, within window: CGRect, progress: Double, context: CGContext) {
        guard progress > 0.001 else { return }
        context.saveGState()
        context.clip(to: window)
        text.draw(at: CGPoint(x: point.x, y: point.y - (1 - progress) * (text.height + 12)), in: context)
        context.restoreGState()
    }

    /// Text sliding out to the right from behind `window`'s left edge.
    private func drawSliding(_ text: Line, at point: CGPoint, within window: CGRect, progress: Double, context: CGContext) {
        guard progress > 0.001 else { return }
        context.saveGState()
        context.clip(to: window)
        text.draw(at: CGPoint(x: point.x - (1 - progress) * (text.width + 30), y: point.y), in: context)
        context.restoreGState()
    }

    // MARK: - Exporting

    /// Writes every graphic into `folder` (transparent ones as ProRes 4444).
    func export(_ graphics: [Graphic], to folder: URL, size canvas: CGSize, frameRate: Int, ffmpeg: String,
                progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written: [URL] = []
        for (n, graphic) in graphics.enumerated() {
            let transparent: Bool
            switch graphic {
            case .lowerThird: transparent = true
            default: transparent = background == nil
            }
            let name = Folders.sanitize(graphic.fileName)
            let url = Converting.outputURL(folder: folder.path, name: name, fileExtension: transparent ? "mov" : "mp4")
            let pack = self
            // Motion blur for the end card's logo animation; the rest moves in clean wipes.
            var blur = 1
            if case .endCard = graphic { blur = 5 }
            try await LogoAnimation.writeVideo(to: url, size: canvas, frameRate: frameRate, length: length(graphic), transparent: transparent,
                                               motionBlur: blur, ffmpeg: ffmpeg, progress: { value in
                progress((Double(n) + value) / Double(graphics.count))
            }) { t, context in
                pack.draw(graphic, at: t, in: context, canvas: canvas)
            }
            written.append(url)
        }
        return written
    }
}
