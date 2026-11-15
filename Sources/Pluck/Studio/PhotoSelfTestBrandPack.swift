import AppKit
import ImageIO

/// Brand Pack's presets (-PluckScreenshotOnly brandpack): every preset, for every kind of graphic
/// and every frame shape, with a dark and a light test logo: something drawn, text that reads on
/// what it's on, the logo inside the safe area, and none of the app's own colours in another
/// brand's graphics. Contact sheets of them all go beside the log.
extension PhotoSelfTest {
    static func brandPackTest() async {
        let out = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "PluckScreenshotLog") ?? NSTemporaryDirectory()).deletingLastPathComponent()
        let logos: [(name: String, colours: [NSColor])] = [
            ("dark", [NSColor(srgbRed: 0.05, green: 0.27, blue: 0.17, alpha: 1), NSColor(srgbRed: 0.97, green: 0.58, blue: 0.1, alpha: 1)]),
            ("light", [NSColor(srgbRed: 0.98, green: 0.89, blue: 0.45, alpha: 1), NSColor(white: 1, alpha: 1)]),
        ]
        check("brandpack: default style isn't the app's pink", !BrandKit.isLegacyPink(MotionStyle().accent) && !BrandKit.isLegacyPink(MotionStyle().accent2))
        check("brandpack: 24+ presets, every layout used",
              MotionPreset.all.count >= 24 && Set(MotionPreset.all.flatMap { p in MotionTemplate.Category.allCases.map { p.layout($0).id } }) == Set(MotionTemplate.all.map(\.id)),
              "\(MotionPreset.all.count) presets")
        check("brandpack: preset ids unique", Set(MotionPreset.all.map(\.id)).count == MotionPreset.all.count)
        for item in logos {
            guard let logo = testLogo(item.colours) else { check("brandpack: \(item.name) test logo", false, "couldn't be made"); continue }
            if let png = NSBitmapImageRep(cgImage: logo.logo).representation(using: .png, properties: [:]) {
                try? png.write(to: out.appendingPathComponent("brandpack-logo-\(item.name).png"))
            }
            let palette = BrandPalette(logo: logo)
            let plan = logo.plan(logo.suggestedStyle, outro: .none)
            check("brandpack: \(item.name) palette is the logo's", !leaks(palette.primary) && !leaks(palette.secondary),
                  "\(palette.primary) \(palette.secondary)")
            var problems: [String] = []
            for preset in MotionPreset.all {
                let style = preset.style(palette)
                problems += contrastProblems(preset, style).map { "\(preset.id) \($0)" }
                for category in MotionTemplate.Category.allCases {
                    let template = preset.layout(category)
                    for format in Deliverables.Format.allCases {
                        let canvas = CGSize(width: Double(format.size.width), height: Double(format.size.height))
                        MotionTemplate.loggedLogos = []
                        guard let context = still(template, style: style, canvas: canvas, scale: 0.25, logo: logo, plan: plan) else { continue }
                        let logged = MotionTemplate.loggedLogos ?? []
                        MotionTemplate.loggedLogos = nil
                        let where_ = "\(preset.id)/\(template.id)/\(format.tag)"
                        let (drawn, leaked) = measure(context, card: template.fullFrame && style.background != nil ? style.background : nil)
                        if drawn < 0.002 { problems.append("\(where_) empty (\(drawn))") }
                        if leaked > 0.001 { problems.append("\(where_) app colour \(leaked)") }
                        let safe = MotionTemplate.safeArea(canvas).applying(CGAffineTransform(scaleX: 0.25, y: 0.25)).insetBy(dx: -2, dy: -2)
                        if category == .logo, logged.isEmpty { problems.append("\(where_) no logo drawn") }
                        for rect in logged where !safe.contains(rect) { problems.append("\(where_) logo \(rect.integral) outside \(safe.integral)") }
                    }
                }
            }
            check("brandpack: \(item.name) logo, \(MotionPreset.all.count) presets × 4 kinds × 4 shapes", problems.isEmpty,
                  "\(problems.count): " + problems.prefix(12).joined(separator: "; "))
            sheet(logo: logo, plan: plan, palette: palette, format: item.name == "dark" ? .landscape : .vertical,
                  to: out.appendingPathComponent("brandpack-sheet-\(item.name).png"))
        }
        // A palette that changed: thumbnails and styles follow it.
        let a = MotionPreset.all[0].style(BrandPalette(colours: [MotionColor(r: 0.8, g: 0.1, b: 0.1)]))
        let b = MotionPreset.all[0].style(BrandPalette(colours: [MotionColor(r: 0.1, g: 0.6, b: 0.2)]))
        check("brandpack: presets follow the palette", a.accent != b.accent)
        note("brandpack sheets: \(out.appendingPathComponent("brandpack-sheet-dark.png").path)")
    }

    /// A test logo: a disc and two bars in the given colours.
    private static func testLogo(_ colours: [NSColor]) -> LogoAnimation? {
        let image = NSImage(size: NSSize(width: 600, height: 300), flipped: false) { _ in
            colours[0].setFill()
            NSBezierPath(ovalIn: NSRect(x: 20, y: 40, width: 220, height: 220)).fill()
            colours[1].setFill()
            NSBezierPath(roundedRect: NSRect(x: 280, y: 150, width: 300, height: 70), xRadius: 12, yRadius: 12).fill()
            colours[0].setFill()
            NSBezierPath(rect: NSRect(x: 280, y: 70, width: 210, height: 50)).fill()
            return true
        }
        return try? LogoAnimation(image: image)
    }

    /// The colours that are the app's own (Studio's plum and violet, basic Pluck's pink and
    /// violet, and the pinks and light the templates used to have built in).
    private static let appColours: [SIMD3<Double>] = [
        SIMD3(0.710, 0.424, 0.537), SIMD3(0.486, 0.373, 0.753), SIMD3(0.557, 0.298, 0.392), SIMD3(0.325, 0.235, 0.533),
        SIMD3(0.99, 0.37, 0.48), SIMD3(0.56, 0.33, 0.96), SIMD3(1.0, 0.36, 0.42), SIMD3(0.93, 0.13, 0.38), SIMD3(0.23, 0.17, 0.85),
        SIMD3(1.0, 0.75, 0.82),
    ]

    private static func leaks(_ c: MotionColor) -> Bool { leaks(SIMD3(c.r, c.g, c.b)) }
    private static func leaks(_ c: SIMD3<Double>) -> Bool { appColours.contains { (($0 - c) * ($0 - c)).sum() < 0.07 * 0.07 } }

    /// Which pairs of text and ground don't read (WCAG 4.5:1 text, 3:1 big words and shapes).
    private static func contrastProblems(_ preset: MotionPreset, _ style: MotionStyle) -> [String] {
        var problems: [String] = []
        func need(_ name: String, _ a: MotionColor, _ b: MotionColor, _ ratio: Double) {
            let value = a.contrast(b)
            if value < ratio { problems.append("\(name) \(String(format: "%.2f", value)) < \(ratio)") }
        }
        if let background = style.background {
            need("text/background", style.text, background, 4.5)
            need("accent/background", style.accent, background, 3)
            need("accent2/background", style.accent2, background, 3)
        }
        if style.secondary.a > 0.01 {
            need("text/plate", style.text, style.secondary.over(style.background ?? MotionTemplate.pictureStandIn), 4.5)
            need("text/plate over picture", style.text, style.secondary.over(MotionTemplate.pictureStandIn), 4.5)
        }
        need("ink/accent", style.accent.ink, style.accent, 4.5)
        need("ink/accent2", style.accent.ink, style.accent2, 3)
        // (Over the picture the words turn white when the brand's text is dark: see MotionTemplate.render.)
        if MotionTemplate.overPicture.contains(preset.layouts.lowerThird) {
            need("text/picture", style.text.contrast(MotionTemplate.pictureStandIn) < 4.5 ? .white : style.text, MotionTemplate.pictureStandIn, 4.5)
        }
        return problems
    }

    /// The graphic settled, drawn at `scale` (over a dim picture when it goes over video).
    private static func still(_ template: MotionTemplate, style: MotionStyle, canvas: CGSize, scale: Double,
                              logo: LogoAnimation?, plan: LogoAnimation.Plan?) -> CGContext? {
        guard let context = CGContext(data: nil, width: Int(canvas.width * scale), height: Int(canvas.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        template.render(t: MotionPreset.stillTime(template, placement: template.placement, logoPlan: plan), in: context, canvas: canvas,
                        style: style, placement: template.placement, logo: logo, logoPlan: plan)
        return context
    }

    /// How much of the frame has something drawn (on a card: unlike its background), and how much
    /// is one of the app's colours.
    private static func measure(_ context: CGContext, card: MotionColor?) -> (drawn: Double, leaked: Double) {
        guard let data = context.data else { return (0, 0) }
        let w = context.width, h = context.height, row = context.bytesPerRow
        let pixels = data.bindMemory(to: UInt8.self, capacity: row * h)
        var drawn = 0, leaked = 0
        for y in 0..<h {
            for x in 0..<w {
                let i = y * row + x * 4
                let a = Double(pixels[i + 3]) / 255
                guard a > 0.05 else { continue }
                let c = SIMD3(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2])) / 255 / a
                if let card {
                    if abs(c.x - card.r) + abs(c.y - card.g) + abs(c.z - card.b) > 0.15 { drawn += 1 }
                } else if a > 0.1 { drawn += 1 }
                if a > 0.5, leaks(c) { leaked += 1 }
            }
        }
        return (Double(drawn) / Double(w * h), Double(leaked) / Double(w * h))
    }

    /// Every preset (rows) for every kind of graphic (columns), named, as one picture.
    private static func sheet(logo: LogoAnimation, plan: LogoAnimation.Plan, palette: BrandPalette, format: Deliverables.Format, to url: URL) {
        let canvas = CGSize(width: Double(format.size.width), height: Double(format.size.height))
        let scale = format == .landscape ? 1.0 / 6 : 1.0 / 8
        let cell = CGSize(width: canvas.width * scale, height: canvas.height * scale)
        let label = 170.0, gap = 8.0, rows = MotionPreset.all.count, columns = MotionTemplate.Category.allCases.count
        let size = CGSize(width: label + Double(columns) * (cell.width + gap) + gap, height: Double(rows) * (cell.height + gap) + gap)
        guard let sheet = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        sheet.setFillColor(CGColor(gray: 0.1, alpha: 1))
        sheet.fill(CGRect(origin: .zero, size: size))
        for (row, preset) in MotionPreset.all.enumerated() {
            let y = size.height - Double(row + 1) * (cell.height + gap)
            let style = preset.style(palette)
            let name = MotionText(preset.name + " · " + preset.group.label, family: "Helvetica Neue", size: 15, weight: 0.5, color: CGColor(gray: 0.9, alpha: 1))
            name.draw(at: CGPoint(x: gap, y: y + cell.height / 2), in: sheet)
            for (column, category) in MotionTemplate.Category.allCases.enumerated() {
                let template = preset.layout(category)
                guard let context = CGContext(data: nil, width: Int(cell.width), height: Int(cell.height), bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                context.setFillColor(MotionTemplate.pictureStandIn.cg)
                context.fill(CGRect(origin: .zero, size: cell))
                context.scaleBy(x: scale, y: scale)
                template.render(t: MotionPreset.stillTime(template, placement: template.placement, logoPlan: plan), in: context, canvas: canvas,
                                style: style, placement: MotionPreset.stillPlacement(template, template.placement), logo: logo, logoPlan: plan)
                if let image = context.makeImage() {
                    sheet.draw(image, in: CGRect(x: label + gap + Double(column) * (cell.width + gap), y: y, width: cell.width, height: cell.height))
                }
            }
        }
        guard let image = sheet.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
