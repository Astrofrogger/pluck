import CoreGraphics
import CoreImage
import Foundation

/// The building styles: Assemble (the symbol's parts come together, then the wordmark slides out
/// from behind it) and Liquid (a blob splits into droplets that flow into the letters).
extension LogoAnimation {
    // MARK: - Layout

    /// A symbol left of a wordmark: the shapes of each, and how far the symbol starts from its
    /// place (logo pixels; it starts in the middle of the logo).
    var symbolAndWordmark: (symbols: [Int], letters: [Int], shift: Double)? {
        let shapes = castOrder.shapes
        let symbols = shapes.filter { elements[$0].kind == .symbol }
        let letters = shapes.filter { elements[$0].kind == .letter || elements[$0].kind == .accent }
        guard !symbols.isEmpty, !letters.isEmpty else { return nil }
        let symbolBox = union(symbols), letterBox = union(letters)
        guard symbolBox.maxX <= letterBox.minX + symbolBox.width * 0.1 else { return nil }
        return (symbols, letters, size.width / 2 - symbolBox.midX)
    }

    func union(_ indices: [Int]) -> CGRect {
        indices.map { elements[$0].box }.reduce(CGRect.null) { $0.union($1) }
    }

    /// Timing of the building styles.
    func buildTiming(_ style: Style) -> [(start: Double, length: Double)] {
        var result = [(start: Double, length: Double)](repeating: (0, 1), count: elements.count)
        let (plates, shapes, heroes) = castOrder
        for (n, i) in plates.enumerated() { result[i] = (Double(n) * 0.12, 0.8) }
        let after = plates.isEmpty ? 0.0 : 0.4
        switch style {
        case .assemble:
            assembleTiming(&result)
        case .liquid:
            let liquid = liquidPlan
            for (i, arrival) in liquid.arrivals { result[i] = (arrival - 0.1, 0.6) }
            for i in elements.indices where liquid.arrivals[i] == nil && elements[i].kind != .plate {
                result[i] = (liquid.settle - 0.2, 0.5)
            }
        default:
            break
        }
        for i in elements.indices where !elements[i].hero { if let base = elements[i].base { result[i] = result[base] } }
        return result
    }

    static let slideLength = 0.85

    /// When the symbol starts sliding to its place.
    private var slideStart: Double {
        let symbols = symbolAndWordmark?.symbols.count ?? 1
        return (castOrder.plates.isEmpty ? 0 : 0.4) + 0.6 + Double(max(symbols - 1, 0)) * 0.08
    }

    // MARK: - Assemble

    /// How Assemble stages a logo, always in two acts: something alone in the middle first, then
    /// the move into the whole logo.
    enum AssembleMode {
        /// A symbol beside a name: the symbol comes together in the middle, then slides home as
        /// the name unrolls from behind it.
        case symbol
        /// A name with a hero (the dot on an i, a sparkle): the hero grows in, in the middle, then
        /// glides home as the name opens from behind it to both sides.
        case hero(Int)
        /// Letters on a plate: the plate opens from a line in the middle, then the letters rise
        /// from their baseline, from the middle out.
        case plate
        /// Just a name: the letters start bunched in the middle and spread out into place.
        case tracking
    }

    var assembleMode: AssembleMode {
        if symbolAndWordmark != nil { return .symbol }
        // The hero nearest the middle leads (the name opens out of it).
        if let hero = heroes.min(by: { abs(elements[$0].box.midX - size.width / 2) < abs(elements[$1].box.midX - size.width / 2) }) {
            return .hero(hero)
        }
        if !castOrder.plates.isEmpty { return .plate }
        return .tracking
    }

    /// When the second act (the move into the whole logo) starts, and how long it takes.
    private var secondAct: (start: Double, length: Double) {
        switch assembleMode {
        case .symbol: return (slideStart, Self.slideLength)
        case .hero: return (Self.heroLands - 0.03, 0.8)
        case .plate: return (0.75, 0.9)
        case .tracking: return (0.1, 1.2)
        }
    }

    /// The hero's beats: it grows in, in the middle, gathers itself, glides onto its place and
    /// settles there. One deliberate move, no bouncing about (that reads as a gimmick).
    static let heroGather = 0.42, heroTakeOff = 0.6, heroLands = 1.08

    /// Where the hero is at time `t` (its centre on the canvas) and how it's squashed or
    /// stretched (x and y scale, on top of its size).
    private func heroPose(_ t: Double, centre: CGPoint, home: CGRect, size: Double, rise: Double)
        -> (centre: CGPoint, sx: Double, sy: Double, lift: Double) {
        if t < Self.heroTakeOff {
            // Grows in with one soft overshoot, then sinks a touch into itself before it moves.
            let grow = Physics.spring(t, frequency: 2.4, damping: 0.72)
            let gather = t > Self.heroGather
                ? sin(Double.pi * min((t - Self.heroGather) / (Self.heroTakeOff - Self.heroGather), 1) / 2) * 0.06 : 0
            return (centre, grow * (1 + gather), grow * (1 - gather), 0)
        }
        if t < Self.heroLands {
            // The glide: eased, along a shallow curve, never a lob.
            let u = Easing.inOutCubic((t - Self.heroTakeOff) / (Self.heroLands - Self.heroTakeOff))
            let arc = abs(home.midY - centre.y) / 2 + rise * 0.05
            let x = centre.x + (home.midX - centre.x) * u
            let y = centre.y + (home.midY - centre.y) * u + 4 * u * (1 - u) * arc
            return (CGPoint(x: x, y: y), 1, 1, 0)
        }
        // Arrived: a small settle, gone within a quarter of a second.
        let squash = Physics.squash(since: t - Self.heroLands, strength: 0.3)
        return (CGPoint(x: home.midX, y: home.midY), 1 + squash * 0.6, 1 - squash, 0)
    }

    /// How far a shape is from the middle of the logo (0 in the middle, 1 at the far edge).
    private func fromMiddle(_ i: Int, of box: CGRect) -> Double {
        min(abs(elements[i].box.midX - box.midX) / max(box.width / 2, 1), 1)
    }

    private func assembleTiming(_ result: inout [(start: Double, length: Double)]) {
        let (plates, shapes, heroes) = castOrder
        let act = secondAct
        let whole = CGRect(origin: .zero, size: size)
        switch assembleMode {
        case .symbol:
            guard let layout = symbolAndWordmark else { return }
            let after = plates.isEmpty ? 0.0 : 0.4
            for (n, i) in layout.symbols.enumerated() { result[i] = (after + Double(n) * 0.08, 0.9) }
            let letterBox = union(layout.letters)
            for i in layout.letters {
                result[i] = (act.start + (elements[i].box.minX - letterBox.minX) / max(letterBox.width, 1) * act.length * 0.8, 0.8)
            }
            for (n, i) in heroes.enumerated() { result[i] = (act.start + act.length * 0.9 + Double(n) * 0.1, 0.7) }
            for i in shapes where result[i].start == 0 && !layout.symbols.contains(i) && !layout.letters.contains(i) {
                result[i] = (act.start, 0.8)
            }
        case .hero(let lead):
            result[lead] = (0, act.start + act.length + 0.6)
            let home = elements[lead].box
            let reach = shapes.map { abs(elements[$0].box.midX - home.midX) }.max() ?? 1
            for i in shapes {
                result[i] = (act.start + abs(elements[i].box.midX - home.midX) / max(reach, 1) * act.length * 0.55, 0.9)
            }
            for (n, i) in heroes.filter({ $0 != lead }).enumerated() { result[i] = (act.start + act.length * 0.85 + Double(n) * 0.12, 0.8) }
        case .plate:
            for (n, i) in plates.enumerated() { result[i] = (Double(n) * 0.18, 1.0) }
            for i in shapes {
                if let plate = elements[i].plate {
                    let opens = result[plate].start
                    result[i] = (opens + act.start + fromMiddle(i, of: elements[plate].box) * 0.45, 0.9)
                } else {
                    // Shapes off the plate (a line of text under it) follow, spreading out.
                    result[i] = (act.start + 0.5 + fromMiddle(i, of: whole) * 0.3, 1.0)
                }
            }
            let end = (shapes.map { result[$0].start }.max() ?? act.start) + 0.4
            for (n, i) in heroes.enumerated() { result[i] = (end + Double(n) * 0.1, 0.7) }
        case .tracking:
            for i in shapes { result[i] = (act.start + fromMiddle(i, of: whole) * 0.2, act.length) }
            let end = act.start + act.length * 0.7
            for (n, i) in heroes.enumerated() { result[i] = (end + Double(n) * 0.1, 0.7) }
        }
    }

    func drawAssemble(at t: Double, timing: [(start: Double, length: Double)], fit: Double, place: (CGRect) -> CGRect,
                      in context: CGContext) {
        let mode = assembleMode
        let act = secondAct
        let move = Easing.inOutCubic(min(max((t - act.start) / act.length, 0), 1))
        let whole = place(CGRect(origin: .zero, size: size))
        let layout = symbolAndWordmark
        let shift = (layout?.shift ?? 0) * fit * (1 - move)
        let symbolBox = layout.map { place(union($0.symbols)) }
        let letterBox = layout.map { place(union($0.letters)) }
        // Where the hero lands, the name opens out of it.
        var heroCentre = CGPoint.zero
        if case .hero(let lead) = mode {
            let home = place(elements[lead].box)
            heroCentre = CGPoint(x: home.midX, y: home.midY)
        }
        for (index, element) in elements.enumerated() {
            let local = t - timing[index].start
            guard local > 0 else { continue }
            let rect = place(element.box)
            context.saveGState()
            defer { context.restoreGState() }
            switch mode {
            case .symbol:
                guard let layout, let symbolBox, let letterBox else { break }
                if element.kind == .plate {
                    let s = Physics.spring(local, frequency: 1.9, damping: 0.6)
                    scaleContext(context, around: CGPoint(x: rect.midX, y: rect.midY), x: 0.7 + 0.3 * s, y: 0.7 + 0.3 * s)
                    context.setAlpha(min(local * 5, 1))
                    context.draw(element.image, in: rect)
                } else if element.hero {
                    popIn(element, local: local, rect: rect, in: context)
                } else if layout.symbols.contains(index) {
                    // The symbol's parts come together in the middle, then the symbol slides home.
                    context.translateBy(x: shift, y: 0)
                    drawGathering(element, local: local, rect: rect, centre: CGPoint(x: symbolBox.midX, y: symbolBox.midY),
                                  reach: max(symbolBox.width, symbolBox.height) * 0.9, in: context)
                } else {
                    // The name unrolls from behind the symbol as it slides away.
                    let edge = symbolBox.maxX + shift + (letterBox.minX - symbolBox.maxX) * 0.35
                    // Fully closed until the symbol moves (a sliver of window would let pieces of
                    // letters flicker through), and the letters glide out without swinging back.
                    let open = move * (letterBox.maxX - edge + 4)
                    guard open > 0.5 else { break }
                    context.clip(to: CGRect(x: edge, y: letterBox.minY - letterBox.height, width: open, height: letterBox.height * 3))
                    // The letters ride with the symbol: what has appeared stays put, only the
                    // window opens wider.
                    context.translateBy(x: shift, y: 0)
                    context.draw(element.image, in: rect)
                }
            case .hero(let lead):
                if index == lead {
                    // Grows in, in the middle of the frame (a little bigger than it will be), then
                    // glides onto its place, easing to its size on the way, and settles there.
                    let boost = min(max(mainLetterHeight * fit * 0.3 / max(rect.height, 1), 1), 1.5)
                    let hop = min(max((local - Self.heroTakeOff) / (Self.heroLands - Self.heroTakeOff), 0), 1)
                    let size = 1 + (boost - 1) * (1 - Easing.inOutCubic(hop))
                    let rise = max(mainLetterHeight * fit * 0.9, rect.height * 4)
                    let pose = heroPose(local, centre: CGPoint(x: whole.midX, y: whole.midY), home: rect, size: size, rise: rise)
                    context.translateBy(x: pose.centre.x - rect.midX, y: pose.centre.y - rect.midY + pose.lift)
                    scaleContext(context, around: CGPoint(x: rect.midX, y: rect.midY - rect.height / 2), x: size * pose.sx, y: size * pose.sy)
                    context.draw(element.image, in: rect)
                } else if element.hero {
                    popIn(element, local: local, rect: rect, in: context)
                } else if element.kind == .plate {
                    let s = Physics.spring(local, frequency: 1.9, damping: 0.65)
                    scaleContext(context, around: CGPoint(x: rect.midX, y: rect.midY), x: s, y: s)
                    context.draw(element.image, in: rect)
                } else {
                    // The landing pushes the name out of the hero's place to both sides.
                    let reach = max(heroCentre.x - whole.minX, whole.maxX - heroCentre.x) + 8
                    let open = Easing.outQuint(min(max(t - act.start, 0) / (act.length * 0.9), 1)) * reach
                    guard open > 0.5 else { break }
                    context.clip(to: CGRect(x: heroCentre.x - open, y: whole.minY - whole.height, width: open * 2, height: whole.height * 3))
                    // They slide out a little way behind the opening edge, never so far that
                    // they pile up on each other.
                    let s = Physics.spring(local, frequency: 1.9, damping: 0.9)
                    let gap = min(abs(heroCentre.x - rect.midX) * 0.12, rect.width * 0.6)
                    context.translateBy(x: (heroCentre.x < rect.midX ? -gap : gap) * (1 - s), y: 0)
                    context.draw(element.image, in: rect)
                }
            case .plate:
                if element.kind == .plate {
                    // A line opens across the middle, then the plate opens up from it.
                    let width = Easing.outQuint(min(local / 0.45, 1))
                    let height = local < 0.4 ? 0 : Physics.spring(local - 0.4, frequency: 2.0, damping: 0.68)
                    let line = min(3 / max(rect.height, 1), 1)
                    scaleContext(context, around: CGPoint(x: rect.midX, y: rect.midY), x: width, y: line + (1 - line) * height)
                    context.draw(element.image, in: rect)
                } else if element.hero {
                    popIn(element, local: local, rect: rect, in: context)
                } else if let plate = element.plate {
                    // Rises from behind its own baseline, within the plate.
                    let area = place(elements[plate].box)
                    let floor = max(area.minY, rect.minY - rect.height * 0.04)
                    context.clip(to: CGRect(x: area.minX, y: floor, width: area.width, height: area.maxY - floor))
                    let s = Physics.spring(local, frequency: 1.9, damping: 0.66)
                    context.translateBy(x: 0, y: -(1 - s) * rect.height * 1.1)
                    context.draw(element.image, in: rect)
                } else {
                    drawSpreading(element, local: local, length: timing[index].length, rect: rect, centreX: whole.midX, in: context)
                }
            case .tracking:
                if element.hero {
                    popIn(element, local: local, rect: rect, in: context)
                } else if element.kind == .plate {
                    context.setAlpha(min(local * 4, 1))
                    context.draw(element.image, in: rect)
                } else {
                    // A window opens from the middle; the letters spread out from behind it.
                    let open = Easing.outQuint(min(max(t - act.start, 0) / (act.length * 0.85), 1)) * (whole.width / 2 + 8)
                    guard open > 0.5 else { break }
                    context.clip(to: CGRect(x: whole.midX - open, y: whole.minY - whole.height, width: open * 2, height: whole.height * 3))
                    let s = Physics.spring(local, frequency: 1.6, damping: 0.88)
                    context.translateBy(x: (whole.midX - rect.midX) * (1 - s) * 0.22, y: 0)
                    context.draw(element.image, in: rect)
                }
            }
        }
    }

    /// The main letters' height (logo pixels).
    private var mainLetterHeight: Double {
        let heights = castOrder.shapes.map { elements[$0].box.height }
        let tallest = heights.max() ?? size.height
        let main = heights.filter { $0 > tallest * 0.6 }.sorted()
        return main.isEmpty ? tallest : main[main.count / 2]
    }

    /// A shape starting bunched towards the middle and spreading out into place, the way
    /// tracking opens up.
    private func drawSpreading(_ element: Element, local: Double, length: Double, rect: CGRect, centreX: Double, in context: CGContext) {
        let s = Physics.spring(local, frequency: 1.5, damping: 0.72)
        context.setAlpha(min(local / 0.3, 1))
        context.translateBy(x: (centreX - rect.midX) * (1 - s) * 0.42, y: 0)
        scaleContext(context, around: CGPoint(x: rect.midX, y: rect.midY), x: 0.9 + 0.1 * s, y: 0.9 + 0.1 * s)
        context.draw(element.image, in: rect)
    }

    /// A small shape popping in: a spring with a little turn (a sparkle twinkling in).
    private func popIn(_ element: Element, local: Double, rect: CGRect, in context: CGContext) {
        let s = Physics.spring(local, frequency: 2.6, damping: 0.4)
        context.setAlpha(min(local * 8, 1))
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: (1 - Easing.outCubic(min(local / 0.6, 1))) * -0.9)
        context.scaleBy(x: s, y: s)
        context.translateBy(x: -rect.midX, y: -rect.midY)
        context.draw(element.image, in: rect)
    }

    /// A shape flying in from away from `centre` (turned and smaller) and springing into place.
    private func drawGathering(_ element: Element, local: Double, rect: CGRect, centre: CGPoint, reach: Double, in context: CGContext) {
        let s = Physics.spring(local, frequency: 1.7, damping: 0.55)
        var dx = rect.midX - centre.x, dy = rect.midY - centre.y
        let length = hypot(dx, dy)
        if length < 1 { dx = 0; dy = 1 } else { dx /= length; dy /= length }
        let away = (1 - s) * reach
        let turn = (1 - s) * (dx >= 0 ? 0.5 : -0.5)
        let scale = 0.55 + 0.45 * s
        context.setAlpha(min(local * 6, 1))
        context.translateBy(x: dx * away, y: dy * away)
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: turn)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.midX, y: -rect.midY)
        context.draw(element.image, in: rect)
    }

    private func scaleContext(_ context: CGContext, around anchor: CGPoint, x: Double, y: Double) {
        context.translateBy(x: anchor.x, y: anchor.y)
        context.scaleBy(x: x, y: y)
        context.translateBy(x: -anchor.x, y: -anchor.y)
    }

    // MARK: - Liquid

    /// The liquid's plan: when each main shape's droplet arrives, and when it all settles into
    /// the logo itself. The main shapes are grouped by colour (one liquid per colour).
    var liquidPlan: (arrivals: [Int: Double], groups: [[Int]], settle: Double) {
        let (plates, shapes, heroes) = castOrder
        let tallest = shapes.map { elements[$0].box.height }.max() ?? 0
        let main = (shapes.filter { elements[$0].box.height > tallest * 0.45 && elements[$0].kind != .accent } + heroes)
        let start = plates.isEmpty ? 0.0 : 0.4
        // Nearest first: droplets reach the shapes close to the middle soonest.
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let ordered = main.sorted { hypot(elements[$0].box.midX - centre.x, elements[$0].box.midY - centre.y)
            < hypot(elements[$1].box.midX - centre.x, elements[$1].box.midY - centre.y) }
        var arrivals: [Int: Double] = [:]
        for (n, i) in ordered.enumerated() { arrivals[i] = start + Self.splitAt + Self.flight + Double(n) * 0.035 }
        // One liquid per colour.
        func rgb(_ c: CGColor) -> SIMD3<Double> {
            let v = c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
            return SIMD3(v[0], v[min(1, v.count - 1)], v[min(2, v.count - 1)])
        }
        var groups: [[Int]] = []
        for i in main {
            let c = rgb(elements[i].colour)
            if let g = groups.firstIndex(where: { group in ((rgb(elements[group[0]].colour) - c) * (rgb(elements[group[0]].colour) - c)).sum() < 0.05 }) {
                groups[g].append(i)
            } else {
                groups.append([i])
            }
        }
        let settle = (arrivals.values.max() ?? start + 1.2) + 0.45
        return (arrivals, groups, settle)
    }

    static let splitAt = 0.62
    static let flight = 0.62

    private static let gooContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    func drawLiquid(at t: Double, timing: [(start: Double, length: Double)], fit: Double, place: (CGRect) -> CGRect,
                    canvas: CGSize, in context: CGContext) {
        let plan = liquidPlan
        let start = castOrder.plates.isEmpty ? 0.0 : 0.4
        // Plates first, growing in; then the liquid on top; then the logo itself as it settles.
        for i in castOrder.plates {
            let local = t - timing[i].start
            guard local > 0 else { continue }
            let rect = place(elements[i].box)
            context.saveGState()
            let s = Physics.spring(local, frequency: 1.9, damping: 0.6)
            scaleContext(context, around: CGPoint(x: rect.midX, y: rect.midY), x: 0.7 + 0.3 * s, y: 0.7 + 0.3 * s)
            context.setAlpha(min(local * 5, 1))
            context.draw(elements[i].image, in: rect)
            context.restoreGState()
        }
        let reveal = Easing.inOutCubic(min(max((t - plan.settle + 0.3) / 0.3, 0), 1))
        let whole = place(CGRect(origin: .zero, size: size))
        let centre = CGPoint(x: whole.midX, y: whole.midY)
        let total = plan.groups.flatMap { $0 }.reduce(0.0) { $0 + elements[$1].area }
        let mainHeight = plan.groups.flatMap { $0 }.map { elements[$0].box.height }.sorted().last ?? size.height
        if reveal < 1 {
            for group in plan.groups {
                let share = group.reduce(0.0) { $0 + elements[$1].area } / max(total, 1)
                // The blob: grows, stretches wide (getting ready), and splits into droplets.
                let blobRadius = sqrt(share) * mainHeight * fit * 0.55
                let grow = Physics.spring(t - start, frequency: 2.0, damping: 0.5)
                let stretch = Easing.inOutCubic(min(max((t - start - 0.3) / 0.32, 0), 1))
                let parting = min(max((t - start - Self.splitAt) / Self.flight, 0), 1)
                guard let layer = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { continue }
                layer.setFillColor(CGColor(gray: 1, alpha: 1))
                if parting < 1 {
                    let w = blobRadius * 2 * grow * (1 + 0.35 * stretch * (1 - parting)), h = blobRadius * 2 * grow * (1 - 0.2 * stretch * (1 - parting))
                    let fade = 1 - Easing.inOutCubic(parting)
                    layer.fillEllipse(in: CGRect(x: centre.x - w / 2 * fade, y: centre.y - h / 2 * fade, width: w * fade, height: h * fade))
                }
                for i in group {
                    let rect = place(elements[i].box)
                    let arrival = plan.arrivals[i] ?? plan.settle
                    let leave = arrival - Self.flight
                    let p = Easing.inOutCubic(min(max((t - leave) / Self.flight, 0), 1))
                    guard t > leave else { continue }
                    // The droplet travels from the middle and shrinks as it becomes the shape.
                    let morph = Easing.inOutCubic(min(max((t - arrival + 0.15) / 0.35, 0), 1))
                    let r = sqrt(elements[i].area / Double.pi) * fit * 0.9 * (1 - morph)
                    let x = centre.x + (rect.midX - centre.x) * p, y = centre.y + (rect.midY - centre.y) * p
                    if r > 0.5 { layer.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)) }
                    if morph > 0 {
                        let s = 0.5 + 0.5 * Physics.spring(t - arrival + 0.15, frequency: 2.2, damping: 0.55)
                        layer.saveGState()
                        layer.translateBy(x: rect.midX, y: rect.midY)
                        layer.scaleBy(x: s, y: s)
                        layer.translateBy(x: -rect.midX, y: -rect.midY)
                        // The shape's silhouette, in white.
                        layer.beginTransparencyLayer(auxiliaryInfo: nil)
                        layer.draw(elements[i].image, in: rect)
                        layer.setBlendMode(.sourceIn)
                        layer.fill(rect.insetBy(dx: -2, dy: -2))
                        layer.endTransparencyLayer()
                        layer.restoreGState()
                    }
                }
                guard let shapes = layer.makeImage() else { continue }
                // Goo: blurred together, then cut back to a sharp edge, so drops that come close melt
                // into each other.
                // The melt softens as the drops become shapes, so they sharpen into the logo.
                let firstArrival = plan.arrivals.values.min() ?? plan.settle
                let sharpen = Easing.inOutCubic(min(max((t - firstArrival + 0.2) / max(plan.settle - firstArrival, 0.3), 0), 1))
                let blur = max(1, min(mainHeight * fit * 0.07, 28) * (1 - 0.9 * sharpen))
                let c = rgb(elements[group[0]].colour)
                let image = CIImage(cgImage: shapes).clampedToExtent().applyingGaussianBlur(sigma: blur)
                    .applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 18),
                        "inputBiasVector": CIVector(x: c.x, y: c.y, z: c.z, w: -8.5),
                    ])
                    .applyingFilter("CIColorClamp")
                    .cropped(to: CGRect(origin: .zero, size: canvas))
                guard let goo = Self.gooContext.createCGImage(image, from: CGRect(origin: .zero, size: canvas)) else { continue }
                // Solid underneath while the sharp logo fades in on top (two half-faded layers
                // would let the background show through).
                context.draw(goo, in: CGRect(origin: .zero, size: canvas))
            }
        }
        // The logo itself: everything as it settles (small shapes rise in with it).
        for (index, element) in elements.enumerated() where element.kind != .plate {
            let rect = place(element.box)
            let small = plan.arrivals[index] == nil
            let a = small ? Easing.outCubic(min(max((t - timing[index].start) / 0.4, 0), 1)) : reveal
            guard a > 0 else { continue }
            context.saveGState()
            context.setAlpha(a)
            if small { context.translateBy(x: 0, y: -(1 - a) * rect.height * 0.5) }
            context.draw(element.image, in: rect)
            context.restoreGState()
        }
    }

    private func rgb(_ c: CGColor) -> SIMD3<Double> {
        let v = c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
        return SIMD3(v[0], v[min(1, v.count - 1)], v[min(2, v.count - 1)])
    }
}
