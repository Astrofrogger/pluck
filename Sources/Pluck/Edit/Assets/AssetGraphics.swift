import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Graphics made by Pluck, drawn with Core Graphics on a transparent canvas: overlays that loop
/// (their movement whole cycles of the loop, or new grain every frame), a counter, and stills.
enum AssetGraphics {
    static let frameRate = 25
    /// A still as a movie: one picture a second, this long.
    static let stillLength = 5.0

    static func length(_ kind: AssetKind) -> Double {
        switch kind {
        case .grain, .dust: 2
        case .counter: 3
        default: 4
        }
    }

    static func loops(_ kind: AssetKind) -> Bool { kind.animated && kind != .counter }

    /// ProRes 4444 or HEVC, with alpha (a still: one frame a second).
    static func writeMovie(_ kind: AssetKind, seed: UInt64, size: CGSize, movie: LogoFile = .prores, to url: URL, ffmpeg: String) async throws {
        let animated = kind.animated, total = animated ? length(kind) : stillLength
        try await LogoAnimation.writeVideo(to: url, size: size, frameRate: animated ? frameRate : 1, length: total, transparent: true,
                                           file: movie == .hevc ? .hevc : .prores, ffmpeg: ffmpeg, progress: { _ in }) { t, context in
            draw(kind, seed: seed, t: animated ? t : 0, in: context, size: size)
        }
    }

    static func writePNG(_ kind: AssetKind, seed: UInt64, size: CGSize, to url: URL) throws {
        guard let image = image(kind, seed: seed, t: 0, size: size),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// One moment as a picture (previews, tests).
    static func image(_ kind: AssetKind, seed: UInt64, t: Double, size: CGSize) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(kind, seed: seed, t: t, in: context, size: size)
        return context.makeImage()
    }

    // MARK: - Drawing

    private static let warm: [(Double, Double, Double)] = [(1, 0.45, 0.1), (1, 0.25, 0.35), (1, 0.75, 0.3), (0.95, 0.35, 0.6), (1, 0.6, 0.15)]
    private static let cool: [(Double, Double, Double)] = [(0.4, 0.7, 1), (0.6, 0.5, 1), (0.3, 0.9, 0.9), (1, 0.85, 0.6), (0.95, 0.5, 0.75)]

    private static func colour(_ c: (Double, Double, Double), _ alpha: Double) -> CGColor {
        CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: min(max(alpha, 0), 1))
    }

    /// A soft round light: `stops` of (position 0…1, colour, alpha).
    private static func glow(_ context: CGContext, at centre: CGPoint, radius: CGFloat, _ stops: [(CGFloat, (Double, Double, Double), Double)]) {
        let colours = stops.map { colour($0.1, $0.2) } as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours, locations: stops.map(\.0)) else { return }
        context.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: radius, options: [])
    }

    static func draw(_ kind: AssetKind, seed: UInt64, t: Double, in context: CGContext, size: CGSize) {
        var r = AssetRandom(seed)
        let w = size.width, h = size.height, unit = min(w, h) / 1080
        // Whole cycles over the loop: the last frame runs on into the first.
        let cycle = 2 * Double.pi * t / length(kind)
        switch kind {
        case .lightLeak:
            context.setBlendMode(.plusLighter)
            for _ in 0..<r.int(2...4) {
                let c = r.pick(warm), edge = r.chance(0.5) ? r.range(-0.1...0.15) : r.range(0.85...1.1)
                let horizontal = r.chance(0.5), radius = r.range(0.35...0.8) * max(w, h)
                let swing = r.range(0.05...0.2), phase = r.range(0...(2 * .pi)), along = r.range(0.2...0.8)
                let intensity = r.range(0.5...0.9) * (0.65 + 0.35 * sin(cycle * Double(r.int(1...2)) + phase))
                let a = edge + swing * 0.3 * sin(cycle + phase), b = along + swing * cos(cycle + phase)
                let centre = horizontal ? CGPoint(x: a * w, y: b * h) : CGPoint(x: b * w, y: a * h)
                glow(context, at: centre, radius: radius, [(0, c, intensity), (0.45, c, intensity * 0.45), (1, c, 0)])
            }
        case .filmBurn:
            context.setBlendMode(.plusLighter)
            let side = r.int(0...3), along = r.range(0.25...0.75), phase = r.range(0...(2 * .pi))
            let grow = 0.5 - 0.5 * cos(cycle), flicker = 0.85 + 0.15 * sin(cycle * 5 + phase)
            let p = [CGPoint(x: 0, y: along * h), CGPoint(x: w, y: along * h), CGPoint(x: along * w, y: 0), CGPoint(x: along * w, y: h)][side]
            let radius = max(w, h) * (0.35 + 0.5 * grow)
            glow(context, at: p, radius: radius, [(0, (1, 1, 0.9), flicker), (0.2, (1, 0.85, 0.4), 0.9 * flicker), (0.5, (1, 0.4, 0.1), 0.7 * flicker), (0.8, (0.8, 0.1, 0.05), 0.35 * flicker), (1, (0.5, 0, 0), 0)])
        case .grain:
            // New grain every frame (the loop's seam is just another frame).
            var g = AssetRandom(seed ^ UInt64(Int(t * Double(frameRate) + 0.5)) &* 0x9E37_79B9)
            let gw = max(Int(w / 2), 1), gh = max(Int(h / 2), 1), strength = r.range(0.25...0.45)
            var pixels = [UInt8](repeating: 0, count: gw * gh * 4)
            for i in 0..<(gw * gh) {
                let n = (g.unit() + g.unit() - 1)
                let a = min(abs(n) * strength * 2, 1), v = n > 0 ? 1.0 : 0.0
                pixels[i * 4] = UInt8(v * a * 255)
                pixels[i * 4 + 1] = UInt8(v * a * 255)
                pixels[i * 4 + 2] = UInt8(v * a * 255)
                pixels[i * 4 + 3] = UInt8(a * 255)
            }
            let tile = pixels.withUnsafeMutableBytes { bytes in
                CGContext(data: bytes.baseAddress, width: gw, height: gh, bitsPerComponent: 8, bytesPerRow: gw * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
            }
            if let tile {
                context.interpolationQuality = .low
                context.draw(tile, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        case .dust:
            var g = AssetRandom(seed ^ UInt64(Int(t * Double(frameRate) + 0.5)) &* 0x9E37_79B9)
            let scratches = r.int(1...3)
            let lines = (0..<scratches).map { _ in (r.range(0.1...0.9), r.range(0...(2 * .pi))) }
            for _ in 0..<g.int(8...25) {
                let dark = g.chance(0.6), size = g.range(1...4.5) * unit
                context.setFillColor(dark ? CGColor(gray: 0, alpha: g.range(0.3...0.8)) : CGColor(gray: 1, alpha: g.range(0.3...0.7)))
                context.fillEllipse(in: CGRect(x: g.unit() * w, y: g.unit() * h, width: size * g.range(0.6...1.6), height: size))
            }
            if g.chance(0.25) {
                context.setStrokeColor(CGColor(gray: 0, alpha: 0.5))
                context.setLineWidth(1.2 * unit)
                let start = CGPoint(x: g.unit() * w, y: g.unit() * h)
                context.move(to: start)
                context.addCurve(to: CGPoint(x: start.x + g.range(-40...40) * unit, y: start.y + g.range(-40...40) * unit),
                                 control1: CGPoint(x: start.x + g.range(-30...30) * unit, y: start.y + g.range(-30...30) * unit),
                                 control2: CGPoint(x: start.x + g.range(-30...30) * unit, y: start.y + g.range(-30...30) * unit))
                context.strokePath()
            }
            for (x, phase) in lines where g.chance(0.7) {
                let at = (x + 0.01 * sin(cycle + phase)) * w + g.range(-2...2) * unit
                context.setFillColor(CGColor(gray: g.chance(0.5) ? 1 : 0, alpha: g.range(0.15...0.45)))
                context.fill(CGRect(x: at, y: 0, width: g.range(0.8...1.8) * unit, height: h))
            }
        case .bokeh:
            context.setBlendMode(.plusLighter)
            let palette = r.chance(0.5) ? warm : cool
            for _ in 0..<r.int(14...28) {
                let c = r.pick(palette), radius = r.range(0.02...0.08) * w, phase = r.range(0...(2 * .pi))
                let x = r.unit() * w + r.range(0.02...0.06) * w * sin(cycle + phase)
                let y = r.unit() * h + r.range(0.02...0.06) * h * cos(cycle + phase)
                let alpha = r.range(0.15...0.4) * (0.7 + 0.3 * sin(cycle * Double(r.int(1...3)) + phase))
                glow(context, at: CGPoint(x: x, y: y), radius: radius, [(0, c, alpha * 0.6), (0.85, c, alpha * 0.85), (1, c, 0)])
            }
        case .flare:
            context.setBlendMode(.plusLighter)
            let c = r.pick(cool), phase = r.range(0...(2 * .pi))
            let source = CGPoint(x: w * (0.5 + r.range(0.2...0.35) * sin(cycle + phase)), y: h * (0.7 + r.range(0.05...0.12) * cos(cycle + phase)))
            let pulse = 0.85 + 0.15 * sin(cycle * 2 + phase)
            glow(context, at: source, radius: 0.18 * w, [(0, (1, 1, 1), pulse), (0.08, (1, 0.95, 0.85), 0.8 * pulse), (0.4, c, 0.2 * pulse), (1, c, 0)])
            // The streak: a thin band, bright where the light is.
            let streak = CGRect(x: 0, y: source.y - 2 * unit, width: w, height: 4 * unit)
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                         colors: [colour(c, 0), colour(c, 0.7 * pulse), colour(c, 0)] as CFArray,
                                         locations: [0, source.x / w, 1]) {
                context.saveGState()
                context.clip(to: streak)
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: source.y), end: CGPoint(x: w, y: source.y), options: [])
                context.restoreGState()
            }
            // Ghosts along the line through the middle.
            let middle = CGPoint(x: w / 2, y: h / 2)
            for _ in 0..<r.int(4...6) {
                let k = r.range(-1.2...0.8), ghost = r.pick(cool)
                let p = CGPoint(x: middle.x + (middle.x - source.x) * k, y: middle.y + (middle.y - source.y) * k)
                glow(context, at: p, radius: r.range(0.02...0.07) * w, [(0, ghost, 0.05 * pulse), (0.8, ghost, 0.18 * pulse), (1, ghost, 0)])
            }
        case .counter:
            let targets = [100, 1000, 50, 250, 10_000, 99]
            let target = r.pick(targets), percent = target <= 100 && r.chance(0.4)
            let x = min(t / (length(kind) - 0.5), 1)
            let value = Int((Double(target) * Easing.outCubic(x)).rounded())
            let text = value.formatted() + (percent ? "%" : "")
            let font = CTFontCreateWithName("SF Pro Display" as CFString, h * 0.18, nil)
            let figures = CTFontCreateCopyWithAttributes(font, h * 0.18, nil, CTFontDescriptorCreateWithAttributes([
                kCTFontFeatureSettingsAttribute: [[kCTFontFeatureTypeIdentifierKey: kNumberSpacingType, kCTFontFeatureSelectorIdentifierKey: kMonospacedNumbersSelector]],
                kCTFontTraitsAttribute: [kCTFontWeightTrait: 0.4],
            ] as CFDictionary))
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): figures,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            ]))
            let bounds = CTLineGetImageBounds(line, context)
            context.textPosition = CGPoint(x: (w - bounds.width) / 2 - bounds.minX, y: (h - bounds.height) / 2 - bounds.minY)
            CTLineDraw(line, context)
        case .shape:
            let side = min(w, h) * r.range(0.3...0.5), centre = CGPoint(x: w / 2, y: h / 2), filled = r.chance(0.5)
            let path = CGMutablePath(), rect = CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
            switch r.int(0...4) {
            case 0: path.addEllipse(in: rect)
            case 1: path.addRoundedRect(in: rect, cornerWidth: side * 0.18, cornerHeight: side * 0.18)
            case 2:
                path.addLines(between: [CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.minY + side * 0.1), CGPoint(x: rect.minX, y: rect.minY + side * 0.1)])
                path.closeSubpath()
            case 3:
                let points = (0..<10).map { i -> CGPoint in
                    let angle = Double.pi / 2 + Double(i) * .pi / 5, radius = side / 2 * (i % 2 == 0 ? 1 : 0.42)
                    return CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
                }
                path.addLines(between: points)
                path.closeSubpath()
            default:
                path.addLines(between: [CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.midY), CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.minX, y: rect.midY)])
                path.closeSubpath()
            }
            context.addPath(path)
            if filled {
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fillPath()
            } else {
                context.setStrokeColor(CGColor(gray: 1, alpha: 1))
                context.setLineWidth(side * 0.05)
                context.setLineJoin(.round)
                context.strokePath()
            }
        case .frame:
            switch r.int(0...3) {
            case 0, 1:
                // Letterbox bars (2.39:1 or 1.85:1, of the canvas's width).
                let ratio = r.pick([2.39, 2.0, 1.85, 2.76]), picture = min(w / ratio, h), bar = (h - picture) / 2
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: w, height: bar))
                context.fill(CGRect(x: 0, y: h - bar, width: w, height: bar))
            case 2:
                let inset = min(w, h) * r.range(0.03...0.06), line = r.range(3...8) * unit
                context.setStrokeColor(CGColor(gray: 1, alpha: 1))
                context.setLineWidth(line)
                context.stroke(CGRect(x: inset, y: inset, width: w - 2 * inset, height: h - 2 * inset), width: line)
            default:
                // A viewfinder's corners.
                let inset = min(w, h) * 0.06, arm = min(w, h) * 0.08
                context.setStrokeColor(CGColor(gray: 1, alpha: 1))
                context.setLineWidth(4 * unit)
                context.setLineCap(.round)
                for (x, y, dx, dy) in [(inset, inset, 1.0, 1.0), (w - inset, inset, -1.0, 1.0), (inset, h - inset, 1.0, -1.0), (w - inset, h - inset, -1.0, -1.0)] {
                    context.move(to: CGPoint(x: x + dx * arm, y: y))
                    context.addLine(to: CGPoint(x: x, y: y))
                    context.addLine(to: CGPoint(x: x, y: y + dy * arm))
                }
                context.strokePath()
            }
        case .gradient:
            let space = CGColorSpace(name: CGColorSpace.sRGB)
            switch r.int(0...2) {
            case 0:
                // A vignette: dark edges, clear middle.
                if let g = CGGradient(colorsSpace: space, colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: r.range(0.6...0.9))] as CFArray, locations: [0.35, 1]) {
                    context.drawRadialGradient(g, startCenter: CGPoint(x: w / 2, y: h / 2), startRadius: 0, endCenter: CGPoint(x: w / 2, y: h / 2),
                                               endRadius: hypot(w, h) / 2, options: [.drawsAfterEndLocation])
                }
            case 1:
                // From the foot up (behind titles).
                if let g = CGGradient(colorsSpace: space, colors: [CGColor(gray: 0, alpha: r.range(0.7...0.9)), CGColor(gray: 0, alpha: 0)] as CFArray, locations: [0, 1]) {
                    context.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: h * r.range(0.35...0.6)), options: [])
                }
            default:
                let a = r.pick(warm + cool), b = r.pick(warm + cool), angle = r.range(0...(2 * .pi))
                if let g = CGGradient(colorsSpace: space, colors: [colour(a, 0.85), colour(b, 0.0)] as CFArray, locations: [0, 1]) {
                    let d = CGPoint(x: cos(angle) * w / 2, y: sin(angle) * h / 2)
                    context.drawLinearGradient(g, start: CGPoint(x: w / 2 - d.x, y: h / 2 - d.y), end: CGPoint(x: w / 2 + d.x, y: h / 2 + d.y),
                                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                }
            }
        case .lowerThird:
            let dark = r.chance(0.6), x = w * 0.06, y = h * 0.12, width = w * r.range(0.32...0.45), height = h * 0.085
            let radius = height * r.pick([0, 0.15, 0.5]), accent = r.pick(warm + cool)
            let base = CGPath(roundedRect: CGRect(x: x, y: y, width: width, height: height), cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.addPath(base)
            context.setFillColor(dark ? CGColor(gray: 0.08, alpha: 0.78) : CGColor(gray: 1, alpha: 0.92))
            context.fillPath()
            context.setFillColor(colour(accent, 1))
            if radius == 0 { context.fill(CGRect(x: x, y: y, width: height * 0.12, height: height)) }
            else { context.fill(CGRect(x: x + height * 0.4, y: y + height * 0.2, width: height * 0.08, height: height * 0.6)) }
            let sub = CGPath(roundedRect: CGRect(x: x, y: y - height * 0.62, width: width * 0.6, height: height * 0.5),
                             cornerWidth: radius * 0.5, cornerHeight: radius * 0.5, transform: nil)
            context.addPath(sub)
            context.setFillColor(dark ? CGColor(gray: 0.08, alpha: 0.6) : CGColor(gray: 1, alpha: 0.75))
            context.fillPath()
        case .arrow:
            let angle = Double(r.int(0...7)) * .pi / 4, length = min(w, h) * r.range(0.3...0.45), shaft = length * r.range(0.08...0.13)
            context.translateBy(x: w / 2, y: h / 2)
            context.rotate(by: angle)
            let head = shaft * 2.6, path = CGMutablePath()
            path.addLines(between: [CGPoint(x: -length / 2, y: -shaft / 2), CGPoint(x: length / 2 - head, y: -shaft / 2), CGPoint(x: length / 2 - head, y: -head / 2),
                                    CGPoint(x: length / 2, y: 0), CGPoint(x: length / 2 - head, y: head / 2), CGPoint(x: length / 2 - head, y: shaft / 2),
                                    CGPoint(x: -length / 2, y: shaft / 2)])
            path.closeSubpath()
            context.setShadow(offset: CGSize(width: 0, height: -4 * unit), blur: 12 * unit, color: CGColor(gray: 0, alpha: 0.4))
            context.addPath(path)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fillPath()
        default: break
        }
    }
}
