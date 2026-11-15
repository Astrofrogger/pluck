import Accelerate
import CoreGraphics

/// Finds a logo in a frame to a tenth of a pixel: normalised cross-correlation of the logo's
/// brightness (its alpha shapes it, set on the frame's own background) against the frame's,
/// coarse to fine over a brightness pyramid, then a small search over sizes and a parabola
/// through the best scores for the sub-pixel position and the exact width.
enum BrandLogoLocator {
    /// One brightness picture (0…1, row 0 at the top) and its running sums for window statistics.
    final class Plane {
        let width: Int, height: Int
        let values: [Float]
        init(width: Int, height: Int, values: [Float]) {
            self.width = width; self.height = height; self.values = values
        }

        /// Half the size, each pixel the mean of four.
        func half() -> Plane {
            let w = width / 2, h = height / 2
            var out = [Float](repeating: 0, count: w * h)
            for y in 0..<h {
                let a = 2 * y * width, b = a + width
                for x in 0..<w { out[y * w + x] = (values[a + 2 * x] + values[a + 2 * x + 1] + values[b + 2 * x] + values[b + 2 * x + 1]) * 0.25 }
            }
            return Plane(width: w, height: h, values: out)
        }

        /// Sums of the values and their squares over every top-left rectangle (one row and column of zeros first).
        lazy var sums: (plain: [Double], squared: [Double]) = {
            let w = width + 1
            var plain = [Double](repeating: 0, count: w * (height + 1)), squared = plain
            for y in 0..<height {
                var row = 0.0, rowSquared = 0.0
                for x in 0..<width {
                    let v = Double(values[y * width + x])
                    row += v; rowSquared += v * v
                    plain[(y + 1) * w + x + 1] = plain[y * w + x + 1] + row
                    squared[(y + 1) * w + x + 1] = squared[y * w + x + 1] + rowSquared
                }
            }
            return (plain, squared)
        }()

        func windowStats(x: Int, y: Int, w: Int, h: Int) -> (sum: Double, squared: Double) {
            let s = sums, stride = width + 1
            func at(_ a: [Double], _ x: Int, _ y: Int) -> Double { a[y * stride + x] }
            return (at(s.plain, x + w, y + h) - at(s.plain, x, y + h) - at(s.plain, x + w, y) + at(s.plain, x, y),
                    at(s.squared, x + w, y + h) - at(s.squared, x, y + h) - at(s.squared, x + w, y) + at(s.squared, x, y))
        }
    }

    /// A video frame or still: its sRGB pixels and a brightness pyramid.
    final class Frame {
        let width: Int, height: Int
        /// sRGB, 4 bytes a pixel (alpha ignored).
        let rgba: [UInt8]
        /// levels[0] is full size, each next one half.
        let levels: [Plane]

        init?(_ image: CGImage) {
            width = image.width; height = image.height
            guard width > 8, height > 8 else { return nil }
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            rgba = bytes
            var luma = [Float](repeating: 0, count: width * height)
            for i in 0..<luma.count {
                luma[i] = (0.2126 * Float(bytes[i * 4]) + 0.7152 * Float(bytes[i * 4 + 1]) + 0.0722 * Float(bytes[i * 4 + 2])) / 255
            }
            var levels = [Plane(width: width, height: height, values: luma)]
            while levels.count < 6, levels.last!.width >= 64, levels.last!.height >= 64 { levels.append(levels.last!.half()) }
            self.levels = levels
        }

        func colour(x: Int, y: Int) -> SIMD3<Double> {
            let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
            return SIMD3(Double(rgba[i]), Double(rgba[i + 1]), Double(rgba[i + 2])) / 255
        }

        /// The median brightness of a thin band just outside `rect`: the background a logo sits on.
        func surround(of rect: CGRect) -> Float {
            let plane = levels[0]
            var samples: [Float] = []
            let outer = rect.insetBy(dx: -6, dy: -6), inner = rect.insetBy(dx: -2, dy: -2)
            let x0 = max(Int(outer.minX), 0), x1 = min(Int(outer.maxX), width - 1)
            let y0 = max(Int(outer.minY), 0), y1 = min(Int(outer.maxY), height - 1)
            guard x1 > x0, y1 > y0 else { return 0.5 }
            for y in Swift.stride(from: y0, through: y1, by: 2) {
                for x in Swift.stride(from: x0, through: x1, by: 2) where !inner.contains(CGPoint(x: x, y: y)) {
                    samples.append(plane.values[y * width + x])
                }
            }
            guard !samples.isEmpty else { return 0.5 }
            samples.sort()
            return samples[samples.count / 2]
        }

        /// The share of pixels in `outer` but not in `inner` that sit on a clear edge (0…1).
        func edgeShare(outer: CGRect, inner: CGRect) -> Double {
            let plane = levels[0]
            let x0 = max(Int(outer.minX.rounded(.down)), 0), x1 = min(Int(outer.maxX.rounded(.up)), width - 2)
            let y0 = max(Int(outer.minY.rounded(.down)), 0), y1 = min(Int(outer.maxY.rounded(.up)), height - 2)
            guard x1 > x0, y1 > y0 else { return 0 }
            var edges = 0, count = 0
            for y in y0...y1 {
                for x in x0...x1 where !inner.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                    let v = plane.values[y * width + x]
                    count += 1
                    if abs(plane.values[y * width + x + 1] - v) + abs(plane.values[(y + 1) * width + x] - v) > 0.12 { edges += 1 }
                }
            }
            return count > 0 ? Double(edges) / Double(count) : 0
        }
    }

    /// The logo drawn at one size, ready to correlate: brightness made zero-mean and unit-length.
    struct Template {
        let width: Int, height: Int
        let values: [Float]
        /// 0…1 coverage and the logo's own (premultiplied) colour, for the colour check.
        let alpha: [Float]
        let colour: [SIMD3<Float>]

        /// `logo` drawn `logoWidth` wide at (1, 1) on a canvas one pixel bigger all round,
        /// over a background of brightness `background`.
        init?(_ logo: CGImage, logoWidth: Double, background: Float) {
            let logoHeight = logoWidth * Double(logo.height) / Double(logo.width)
            width = Int(logoWidth.rounded(.up)) + 2; height = Int(logoHeight.rounded(.up)) + 2
            guard logoWidth >= 3, logoHeight >= 3 else { return nil }
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(logo, in: CGRect(x: 1, y: Double(height) - 1 - logoHeight, width: logoWidth, height: logoHeight))
            var values = [Float](repeating: 0, count: width * height), alpha = values
            var colour = [SIMD3<Float>](repeating: .zero, count: width * height)
            for i in 0..<values.count {
                let a = Float(bytes[i * 4 + 3]) / 255
                let c = SIMD3(Float(bytes[i * 4]), Float(bytes[i * 4 + 1]), Float(bytes[i * 4 + 2])) / 255
                alpha[i] = a; colour[i] = c
                values[i] = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z + (1 - a) * background
            }
            var mean: Float = 0
            vDSP_meanv(values, 1, &mean, vDSP_Length(values.count))
            values = values.map { $0 - mean }
            var norm: Float = 0
            vDSP_svesq(values, 1, &norm, vDSP_Length(values.count))
            guard norm > 1e-6 else { return nil }
            let scale = 1 / norm.squareRoot()
            self.values = values.map { $0 * scale }
            self.alpha = alpha; self.colour = colour
        }
    }

    /// The best place for a template in a plane, over top-left positions xs × ys, and every score there.
    struct Scores {
        var x = 0, y = 0, score: Float = -2
        var x0 = 0, y0 = 0, columns = 0
        var grid: [Float] = []
        func at(_ x: Int, _ y: Int) -> Float? {
            let i = x - x0, j = y - y0
            guard i >= 0, i < columns, j >= 0, columns > 0, j < grid.count / columns else { return nil }
            return grid[j * columns + i]
        }
    }

    static func scores(_ plane: Plane, _ t: Template, xs: ClosedRange<Int>, ys: ClosedRange<Int>) -> Scores {
        var result = Scores()
        let maxX = plane.width - t.width, maxY = plane.height - t.height
        guard maxX >= 0, maxY >= 0 else { return result }
        let x0 = min(max(xs.lowerBound, 0), maxX), x1 = min(max(xs.upperBound, 0), maxX)
        let y0 = min(max(ys.lowerBound, 0), maxY), y1 = min(max(ys.upperBound, 0), maxY)
        result.x0 = x0; result.y0 = y0; result.columns = x1 - x0 + 1
        result.grid = [Float](repeating: 0, count: result.columns * (y1 - y0 + 1))
        let n = Double(t.width * t.height)
        // A window flatter than this is no logo (and would only show the codec's noise).
        let flattest = n * 0.004 * 0.004
        plane.values.withUnsafeBufferPointer { f in
            t.values.withUnsafeBufferPointer { v in
                for y in y0...y1 {
                    for x in x0...x1 {
                        let stats = plane.windowStats(x: x, y: y, w: t.width, h: t.height)
                        let spread = stats.squared - stats.sum * stats.sum / n
                        var score: Float = 0
                        if spread > flattest {
                            var total: Float = 0
                            for r in 0..<t.height {
                                var d: Float = 0
                                vDSP_dotpr(f.baseAddress! + (y + r) * plane.width + x, 1, v.baseAddress! + r * t.width, 1, &d, vDSP_Length(t.width))
                                total += d
                            }
                            score = total / Float(spread.squareRoot())
                        }
                        result.grid[(y - y0) * result.columns + (x - x0)] = score
                        if score > result.score { result.score = score; result.x = x; result.y = y }
                    }
                }
            }
        }
        return result
    }

    /// Where a parabola through three scores peaks, from the middle one (−0.5…0.5).
    static func peak(_ left: Float, _ middle: Float, _ right: Float) -> Double {
        let curve = Double(left - 2 * middle + right)
        guard curve < -1e-9 else { return 0 }
        return min(max(0.5 * Double(left - right) / curve, -0.5), 0.5)
    }

    struct Match {
        /// The logo's drawn area in the frame, top left origin, to sub-pixel precision.
        var rect: CGRect
        var score: Double
        /// The mean colour of the logo's solid pixels as shown, and as the logo file has it.
        var colour: SIMD3<Double>
        var ownColour: SIMD3<Double>
    }

    /// The pyramid level where the logo is about `target` pixels wide.
    private static func level(for width: Double, in frame: Frame, target: Double = 20) -> Int {
        var level = 0
        while level + 1 < frame.levels.count, width / Double(1 << (level + 1)) >= target { level += 1 }
        return level
    }

    /// The logo near where it should be (`expected`, full-size pixels), else anywhere in the frame;
    /// nil when it isn't there.
    static func locate(_ logo: CGImage, in frame: Frame, expected: CGRect, threshold: Double = 0.8) -> Match? {
        let level = level(for: expected.width, in: frame)
        let k = Double(1 << level), plane = frame.levels[level]
        guard let template = Template(logo, logoWidth: expected.width / k, background: frame.surround(of: expected)) else { return nil }
        let margin = max(24, 0.3 * max(expected.width, expected.height)) / k
        let ex = Int((expected.minX / k).rounded()) - 1, ey = Int((expected.minY / k).rounded()) - 1, m = Int(margin.rounded(.up))
        var coarse = scores(plane, template, xs: (ex - m)...(ex + m), ys: (ey - m)...(ey + m))
        if coarse.score < 0.6 {
            coarse = scores(plane, template, xs: 0...plane.width, ys: 0...plane.height)
            guard coarse.score >= 0.6 else { return nil }
        }
        let guess = CGRect(x: (Double(coarse.x) + 1) * k, y: (Double(coarse.y) + 1) * k, width: expected.width, height: expected.height)
        return refine(logo, in: frame, guess: guess, slack: k, threshold: threshold)
    }

    /// The logo at any size and place (measuring an approved video): 3–60 % of the frame's width.
    static func find(_ logo: CGImage, in frame: Frame, threshold: Double = 0.8) -> Match? {
        let aspect = Double(logo.width) / Double(logo.height)
        let dark: Float = 0, light: Float = 1
        // The coarse look puts it on a background that contrasts with it.
        let own = ownBrightness(logo)
        var best: (width: Double, x: Int, y: Int, level: Int, score: Float)?
        var width = Double(frame.width) * 0.03
        while width <= Double(frame.width) * 0.6, width / aspect <= Double(frame.height) * 0.9 {
            let level = level(for: width, in: frame, target: 16), k = Double(1 << level), plane = frame.levels[level]
            if let template = Template(logo, logoWidth: width / k, background: own > 0.5 ? dark : light) {
                let s = scores(plane, template, xs: 0...plane.width, ys: 0...plane.height)
                if s.score > best?.score ?? 0.5 { best = (width, s.x, s.y, level, s.score) }
            }
            width *= 1.06
        }
        guard let best else { return nil }
        let k = Double(1 << best.level)
        let guess = CGRect(x: (Double(best.x) + 1) * k, y: (Double(best.y) + 1) * k, width: best.width, height: best.width / aspect)
        return refine(logo, in: frame, guess: guess, slack: k, scaleRange: 0.04, threshold: threshold)
    }

    private static func ownBrightness(_ logo: CGImage) -> Float {
        guard let t = Template(logo, logoWidth: min(Double(logo.width), 64), background: 0) else { return 1 }
        var total: Float = 0, coverage: Float = 0
        for i in t.alpha.indices { total += 0.2126 * t.colour[i].x + 0.7152 * t.colour[i].y + 0.0722 * t.colour[i].z; coverage += t.alpha[i] }
        return coverage > 0 ? total / coverage : 1
    }

    /// From a rough place and width (within `slack` pixels): the size, ±`scaleRange`, at half size
    /// in 1 % steps, then at full size in 0.2 % steps, then the sub-pixel position and width.
    private static func refine(_ logo: CGImage, in frame: Frame, guess: CGRect, slack: Double,
                               scaleRange: Double = 0.1, threshold: Double) -> Match? {
        let background = frame.surround(of: guess)
        let centre = CGPoint(x: guess.midX, y: guess.midY)
        let aspect = Double(logo.width) / Double(logo.height)

        /// The best place for the logo `width` wide with its centre within `reach` pixels of `around`, at `level`.
        func search(width: Double, around: CGPoint, reach: Double, level: Int) -> (Scores, Template)? {
            let k = Double(1 << min(level, frame.levels.count - 1)), plane = frame.levels[min(level, frame.levels.count - 1)]
            guard let t = Template(logo, logoWidth: width / k, background: background) else { return nil }
            let x = Int(((around.x - width / 2) / k).rounded()) - 1, y = Int(((around.y - width / aspect / 2) / k).rounded()) - 1
            let r = Int((reach / k).rounded(.up)) + 1
            return (scores(plane, t, xs: (x - r)...(x + r), ys: (y - r)...(y + r)), t)
        }
        func centreOf(_ s: Scores, width: Double, level: Int) -> CGPoint {
            let k = Double(1 << level)
            return CGPoint(x: (Double(s.x) + 1) * k + width / 2, y: (Double(s.y) + 1) * k + width / aspect / 2)
        }

        // Sizes at half size (or full size for tiny logos).
        let coarseLevel = guess.width >= 40 && frame.levels.count > 1 ? 1 : 0
        var scaleScores: [(scale: Double, score: Float, centre: CGPoint)] = []
        let steps = Int((scaleRange / 0.01).rounded())
        for step in -steps...steps {
            let scale = 1 + Double(step) * 0.01, width = guess.width * scale
            let reach = slack + abs(scale - 1) * max(guess.width, guess.height) / 2 + 2
            guard let (s, _) = search(width: width, around: centre, reach: reach, level: coarseLevel) else { continue }
            scaleScores.append((scale, s.score, centreOf(s, width: width, level: coarseLevel)))
        }
        guard let coarse = scaleScores.max(by: { $0.score < $1.score }), Double(coarse.score) >= threshold - 0.15 else { return nil }

        // Full size, finer sizes around the best one.
        var fine: [(width: Double, scores: Scores, template: Template)] = []
        for step in -6...6 {
            let width = guess.width * (coarse.scale + Double(step) * 0.002)
            if let (s, t) = search(width: width, around: coarse.centre, reach: Double(1 << coarseLevel) + 2, level: 0) { fine.append((width, s, t)) }
        }
        guard let bestIndex = fine.indices.max(by: { fine[$0].scores.score < fine[$1].scores.score }) else { return nil }
        let best = fine[bestIndex]
        guard Double(best.scores.score) >= threshold else { return nil }
        var width = best.width
        if bestIndex > 0, bestIndex < fine.count - 1 {
            width += peak(fine[bestIndex - 1].scores.score, best.scores.score, fine[bestIndex + 1].scores.score) * (fine[bestIndex + 1].width - best.width)
        }
        // Sub-pixel position from the scores beside the best one (at the best whole width).
        let s = best.scores
        let middle = s.score
        let dx = peak(s.at(s.x - 1, s.y) ?? middle, middle, s.at(s.x + 1, s.y) ?? middle)
        let dy = peak(s.at(s.x, s.y - 1) ?? middle, middle, s.at(s.x, s.y + 1) ?? middle)
        // The logo was drawn from the template's (1, 1); a wider fitted logo is centred on the same spot.
        let x = Double(s.x) + 1 + dx - (width - best.width) / 2, y = Double(s.y) + 1 + dy - (width - best.width) / aspect / 2
        let rect = CGRect(x: x, y: y, width: width, height: width / aspect)

        // Colour: the logo's solid pixels.
        let t = best.template
        var shown = SIMD3<Double>.zero, own = SIMD3<Double>.zero, count = 0.0
        for cut in [Float(0.99), 0.9, 0.5] where count < 8 {
            shown = .zero; own = .zero; count = 0
            for j in 0..<t.height { for i in 0..<t.width where t.alpha[j * t.width + i] >= cut {
                let a = t.alpha[j * t.width + i], c = t.colour[j * t.width + i] / a
                shown += frame.colour(x: s.x + i, y: s.y + j)
                own += SIMD3(Double(c.x), Double(c.y), Double(c.z))
                count += 1
            } }
        }
        guard count > 0 else { return nil }
        return Match(rect: rect, score: Double(best.scores.score), colour: shown / count, ownColour: own / count)
    }
}
