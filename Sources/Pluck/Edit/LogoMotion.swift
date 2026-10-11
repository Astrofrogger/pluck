import CoreGraphics
import Foundation

/// Physics for the expressive styles: springs that overshoot and settle, drops that bounce, and
/// squash and stretch, the way a character animator would move a shape.
enum Physics {
    /// A damped spring from 0 to 1, `t` seconds after it's let go: `frequency` swings a second,
    /// `damping` 0 (bounces for ever) to 1 (no overshoot).
    static func spring(_ t: Double, frequency: Double = 2.2, damping: Double = 0.5) -> Double {
        guard t > 0 else { return 0 }
        let w = 2 * Double.pi * frequency
        let wd = w * sqrt(max(1 - damping * damping, 0.0001))
        return 1 - exp(-damping * w * t) * (cos(wd * t) + damping * w / wd * sin(wd * t))
    }

    /// A shape dropped from height 1 onto the ground (0) that bounces: how high it is `t`
    /// seconds after letting go, how fast it moves (heights a second, down is negative), and the
    /// last impact (seconds since, and how hard: 1 for the first).
    static func drop(_ t: Double, fall: Double, restitution: Double = 0.38) -> (height: Double, velocity: Double, impact: (since: Double, strength: Double)?) {
        guard t > 0 else { return (1, 0, nil) }
        let g = 2 / (fall * fall)
        if t < fall { return (1 - 0.5 * g * t * t, -g * t, nil) }
        var time = fall, speed = g * fall, strength = 1.0
        // Bounces until they're too small to see.
        while true {
            let bounceSpeed = speed * restitution
            let length = 2 * bounceSpeed / g
            // (Small enough not to show even on a big shape: its last hop is a pixel or two.)
            if bounceSpeed < g * fall * 0.03 { return (0, 0, (t - time, strength)) }
            if t < time + length {
                let u = t - time
                return (bounceSpeed * u - 0.5 * g * u * u, bounceSpeed - g * u, (u, strength))
            }
            time += length
            speed = bounceSpeed
            strength *= restitution
        }
    }

    /// The squash after an impact: a quick flattening that wobbles back (positive is flatter).
    static func squash(since: Double, strength: Double) -> Double {
        guard since >= 0, since < 0.6 else { return 0 }
        return 0.28 * strength * exp(-since / 0.07) * cos(2 * Double.pi * since / 0.24)
    }
}

extension LogoAnimation {
    /// The expressive styles, which move the logo's shapes with physics rather than easing.
    static let expressive: Set<Style> = [.lineDraw, .bounce, .stretch]

    /// Order within the expressive styles: plates first, then everything else in reading order,
    /// heroes last.
    var castOrder: (plates: [Int], shapes: [Int], heroes: [Int]) {
        let plates = elements.indices.filter { elements[$0].kind == .plate }
        let heroes = self.heroes
        let shapes = elements.indices.filter { elements[$0].kind != .plate && !elements[$0].hero }
        return (plates, shapes, heroes)
    }

    func expressiveTiming(_ style: Style) -> [(start: Double, length: Double)] {
        var result = [(start: Double, length: Double)](repeating: (0, 1), count: elements.count)
        let (plates, shapes, heroes) = castOrder
        let step = shapes.count > 1 ? min(0.07, 0.65 / Double(shapes.count - 1)) : 0
        switch style {
        case .lineDraw:
            for (n, i) in plates.enumerated() { result[i] = (Double(n) * 0.2, 1.5) }
            // Shapes on a plate wait until it has filled in.
            let after = plates.isEmpty ? 0 : 1.05 + Double(max(plates.count - 1, 0)) * 0.2
            for (n, i) in shapes.enumerated() { result[i] = (after + Double(n) * step, 1.25) }
            let end = after + Double(max(shapes.count - 1, 0)) * step + 0.9
            for (n, i) in heroes.enumerated() { result[i] = (end + Double(n) * 0.12, 0.9) }
        case .stretch:
            for (n, i) in plates.enumerated() { result[i] = (Double(n) * 0.15, 1.1) }
            let after = plates.isEmpty ? 0 : 0.4
            // A wave from left to right (both lines together).
            for i in shapes { result[i] = (after + elements[i].box.minX / max(size.width, 1) * 0.5, 2.4) }
            for (n, i) in heroes.enumerated() { result[i] = (after + 0.65 + Double(n) * 0.1, 0.8) }
        case .bounce:
            for (n, i) in plates.enumerated() { result[i] = (Double(n) * 0.15, 0.9) }
            let after = plates.isEmpty ? 0 : 0.45
            // Long enough for the last little bounce and wobble to die out.
            for (n, i) in shapes.enumerated() { result[i] = (after + Double(n) * step, 1.6) }
            // The hero follows straight after the last letter.
            let end = after + Double(max(shapes.count - 1, 0)) * step + 0.22
            for (n, i) in heroes.enumerated() {
                // A dot on a letter lands on it straight after the letter is up, in the wave.
                if let base = elements[i].base { result[i] = (result[base].start + 0.28, 1.6) }
                else { result[i] = (end + Double(n) * 0.12, 1.6) }
            }
        default:
            break
        }
        // A dot that isn't a hero moves with its letter.
        for i in elements.indices where !elements[i].hero { if let base = elements[i].base { result[i] = result[base] } }
        return result
    }

    /// How many lines of shapes the logo has (rows that don't overlap).
    var lineCount: Int {
        let rows = castOrder.shapes.map { elements[$0] }.filter { $0.kind == .letter }.map { ($0.box.minY, $0.box.maxY) }.sorted { $0.0 < $1.0 }
        var count = 0, bottom = -Double.infinity
        let tall = rows.map { $0.1 - $0.0 }.max() ?? 0
        for row in rows where row.1 - row.0 > tall * 0.5 {
            if row.0 > bottom - (row.1 - row.0) * 0.2 { count += 1; bottom = row.1 } else { bottom = max(bottom, row.1) }
        }
        return max(count, 1)
    }

    // MARK: - Drawing

    /// Draws one shape of an expressive style at its own progress `local` (seconds since it
    /// started). `rect` is its place on the canvas; `point` maps logo pixels to the canvas.
    func drawExpressive(_ index: Int, local: Double, length: Double, style: Style, rect: CGRect, fit: Double,
                        point: (CGPoint) -> CGPoint, in context: CGContext) {
        let element = elements[index]
        let p = min(max(local / length, 0), 1)
        func plateRect(_ plate: Int) -> CGRect {
            let box = elements[plate].box
            let a = point(CGPoint(x: box.minX, y: box.maxY)), b = point(CGPoint(x: box.maxX, y: box.minY))
            return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        }
        switch style {
        case .stretch:
            if element.hero {
                popIn(element, local: local, rect: rect, in: context)
                return
            }
            context.saveGState()
            defer { context.restoreGState() }
            if element.kind == .plate {
                // The plate stretches open from its middle like rubber.
                let s = Physics.spring(local, frequency: 1.8, damping: 0.4)
                scale(context, around: CGPoint(x: rect.midX, y: rect.midY), x: 1 + (1 - min(s, 1)) * 0.12, y: max(s, 0))
                context.draw(element.image, in: rect)
                return
            }
            if let plate = element.plate { context.clip(to: plateRect(plate)) }
            // Grows out of a line like rubber: past its height, back, and settling. A lower line
            // grows down from its top, so two lines grow out from the gap between them.
            let s = Physics.spring(local, frequency: 1.55, damping: 0.3)
            let frequency = 1.55, damping = 0.3
            let peak = 1 / (2 * frequency * sqrt(1 - damping * damping))
            let sx = local < peak ? 1 : min(max(1 / sqrt(max(s, 0.4)), 0.85), 1.2)
            let downward = lineCount > 1 && element.box.midY > size.height / 2 && element.plate == nil
            let anchor = CGPoint(x: rect.midX, y: downward ? rect.maxY : rect.minY)
            scale(context, around: anchor, x: sx, y: max(s, 0.001))
            context.draw(element.image, in: rect)
        case .lineDraw:
            if element.hero {
                popIn(element, local: local, rect: rect, in: context)
                return
            }
            // Small shapes (a tagline) rise in without a line: it would only look like noise.
            if min(rect.width, rect.height) < 16 {
                let e = Easing.outCubic(min(local / 0.7, 1))
                context.saveGState()
                context.setAlpha(e)
                context.translateBy(x: 0, y: -(1 - e) * rect.height * 0.6)
                context.draw(element.image, in: rect)
                context.restoreGState()
                return
            }
            // A line runs round the shape (head ahead, tail following), then the shape fills in
            // behind it. The line is the accent colour; on a plate (and for the plate itself) it's
            // the shape's own colour, so it shows against the plate.
            let lineColour = element.plate != nil || element.kind == .plate ? element.colour : accentColour
            let head = Easing.inOutCubic(min(p / 0.62, 1))
            let tail = Easing.inOutCubic(min(max((p - 0.28) / 0.62, 0), 1))
            let fill = Easing.outCubic(min(max((p - 0.42) / 0.4, 0), 1))
            if fill > 0 {
                context.saveGState()
                let grow = 0.94 + 0.06 * Physics.spring(max(local - length * 0.42, 0), frequency: 2.6, damping: 0.45)
                scale(context, around: CGPoint(x: rect.midX, y: rect.midY), x: grow, y: grow)
                context.setAlpha(fill)
                context.draw(element.image, in: rect)
                context.restoreGState()
            }
            if head > tail {
                context.saveGState()
                context.setStrokeColor(lineColour)
                context.setLineWidth(max(1.5, min(min(rect.width, rect.height) * 0.05, 4)))
                context.setLineCap(.round)
                context.setLineJoin(.round)
                for outline in element.outlines {
                    strokeSegment(outline.map(point), from: tail, to: head, in: context)
                }
                context.restoreGState()
            }
        case .bounce:
            if element.kind == .plate {
                // The plate springs up from its bottom edge.
                let s = Physics.spring(local, frequency: 1.9, damping: 0.6)
                context.saveGState()
                scale(context, around: CGPoint(x: rect.midX, y: rect.minY), x: 0.6 + 0.4 * s, y: s)
                context.setAlpha(min(local * 6, 1))
                context.draw(element.image, in: rect)
                context.restoreGState()
                return
            }
            // On a plate, a shape rises out of it from behind its own baseline with a gentle
            // spring (a jump would be cut off at the plate's edge).
            if let plate = element.plate, !element.hero {
                let area = plateRect(plate)
                let s = Physics.spring(local, frequency: 2.1, damping: 0.62)
                context.saveGState()
                let floor = max(area.minY, rect.minY - rect.height * 0.04)
                context.clip(to: CGRect(x: area.minX, y: floor, width: area.width, height: area.maxY - floor))
                context.translateBy(x: 0, y: -(1 - s) * rect.height * 1.1)
                let squash = Physics.squash(since: local - 0.32, strength: 0.35)
                scale(context, around: CGPoint(x: rect.midX, y: rect.minY), x: 1 + squash * 0.6, y: 1 - squash)
                context.draw(element.image, in: rect)
                context.restoreGState()
                return
            }
            // Several lines: each shape pops up from its own baseline, stretching up past its
            // height, squashing and settling, without leaving its line.
            if lineCount > 1, !element.hero {
                let frequency = 2.3, damping = 0.42
                let sy = Physics.spring(local, frequency: frequency, damping: damping)
                let peak = 1 / (2 * frequency * sqrt(1 - damping * damping))
                // Growing it's slim; after the first stretch it keeps its volume (wider when squashed).
                let sx = local < peak ? 0.55 + 0.45 * min(sy, 1) : 1 / sqrt(max(sy, 0.3))
                let hop = max(sy - 1, 0) * rect.height * 0.35
                context.saveGState()
                context.translateBy(x: 0, y: hop)
                scale(context, around: CGPoint(x: rect.midX, y: rect.minY), x: sx, y: max(sy, 0))
                context.draw(element.image, in: rect)
                context.restoreGState()
                return
            }
            // One line drops in from above, stretched as it falls and squashed as it lands, over
            // a soft shadow; the hero drops onto its letter from a little above it.
            let base = element.base.map { elements[$0].box.height * fit } ?? rect.height
            let fall = element.hero ? 0.34 : 0.42
            let height = element.hero ? base * 1.6 : rect.height * 2.6
            let drop = Physics.drop(local, fall: fall)
            let speed = abs(drop.velocity) * fall / 2
            let stretch = 1 + min(speed, 1) * 0.22
            let squash = drop.impact.map { Physics.squash(since: $0.since, strength: $0.strength) } ?? 0
            let sy = stretch * (1 - squash), sx = 1 / sqrt(max(stretch * (1 - squash), 0.3))
            if element.kind != .accent, lineCount == 1 {
                let near = 1 - min(drop.height, 1)
                context.saveGState()
                let w = rect.width * (0.55 + 0.45 * near) * sx
                let shadow = CGRect(x: rect.midX - w / 2, y: rect.minY - rect.height * 0.06, width: w, height: rect.height * 0.1)
                // Only while it's off the ground: once it stands on it, the shadow is underneath it.
                drawShadow(shadow, alpha: 0.16 * near * min(drop.height * 6, 1), in: context)
                context.restoreGState()
            }
            context.saveGState()
            context.translateBy(x: 0, y: drop.height * height)
            scale(context, around: CGPoint(x: rect.midX, y: rect.minY), x: sx, y: sy)
            context.draw(element.image, in: rect)
            context.restoreGState()
        default:
            context.draw(element.image, in: rect)
        }
    }

    /// A small shape popping in: a spring with a little turn (a sparkle twinkling in).
    private func popIn(_ element: Element, local: Double, rect: CGRect, in context: CGContext) {
        let s = Physics.spring(local, frequency: 2.6, damping: 0.38)
        context.saveGState()
        context.setAlpha(min(local * 8, 1))
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: (1 - Easing.outCubic(min(local / 0.6, 1))) * -0.9)
        context.scaleBy(x: s, y: s)
        context.translateBy(x: -rect.midX, y: -rect.midY)
        context.draw(element.image, in: rect)
        context.restoreGState()
    }

    private func scale(_ context: CGContext, around anchor: CGPoint, x: Double, y: Double) {
        context.translateBy(x: anchor.x, y: anchor.y)
        context.scaleBy(x: x, y: y)
        context.translateBy(x: -anchor.x, y: -anchor.y)
    }

    /// Strokes the part of a closed outline between `from` and `to` (0…1 of its length).
    private func strokeSegment(_ points: [CGPoint], from: Double, to: Double, in context: CGContext) {
        guard points.count > 1, to > from else { return }
        let closed = points + [points[0]]
        var lengths: [Double] = [0]
        for i in 1..<closed.count { lengths.append(lengths[i - 1] + hypot(closed[i].x - closed[i - 1].x, closed[i].y - closed[i - 1].y)) }
        let total = lengths.last!
        guard total > 0 else { return }
        func at(_ d: Double) -> CGPoint {
            var i = 1
            while i < closed.count - 1, lengths[i] < d { i += 1 }
            let part = (d - lengths[i - 1]) / max(lengths[i] - lengths[i - 1], 0.0001)
            return CGPoint(x: closed[i - 1].x + (closed[i].x - closed[i - 1].x) * part, y: closed[i - 1].y + (closed[i].y - closed[i - 1].y) * part)
        }
        let a = total * from, b = total * to
        context.beginPath()
        context.move(to: at(a))
        for i in 1..<closed.count where lengths[i] > a && lengths[i] < b { context.addLine(to: closed[i]) }
        context.addLine(to: at(b))
        context.strokePath()
    }

    private func drawShadow(_ rect: CGRect, alpha: Double, in context: CGContext) {
        guard alpha > 0.005, rect.width > 1,
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: [CGColor(gray: 0, alpha: alpha), CGColor(gray: 0, alpha: 0)] as CFArray, locations: [0, 1])
        else { return }
        context.translateBy(x: rect.midX, y: rect.midY)
        context.scaleBy(x: rect.width / 2, y: rect.height / 2)
        context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
    }
}
