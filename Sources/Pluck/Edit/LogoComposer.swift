import CoreGraphics
import Foundation

/// Designs a logo animation for one logo from its profile, the way a motion designer would: one
/// hero move that suits the hero (a ring glides in on an arc, a symmetric mark closes from both
/// sides, a star turns into place, a line icon draws itself), then the rest follows it, the name
/// last. Timing and easing come from the logo's character. A seed gives other ideas.
extension LogoAnimation {
    /// A designed animation and what it is.
    struct Design: Sendable {
        var spec: MotionSpec
        /// A few words: "Arc glide · letters rise".
        var name: String
        /// How well the moves suit the logo (0…1).
        var score: Double
        /// Its last frame is the logo itself (checked); otherwise it isn't offered.
        var valid: Bool
        var seed: Int
    }

    /// The moves a design can lead with.
    enum HeroMove: String, CaseIterable, Codable, Identifiable, Sendable {
        var id: String { rawValue }
        case drawOn, growFromDot, unfoldFromLine, converge, spin, arcGlide, growFromBase, slides, colourBands, pop, enter, letters

        var label: String {
            switch self {
            case .drawOn: String(localized: "Draws itself")
            case .growFromDot: String(localized: "Grows from a dot")
            case .unfoldFromLine: String(localized: "Unfolds from a line")
            case .converge: String(localized: "Halves meet")
            case .spin: String(localized: "Turns into place")
            case .arcGlide: String(localized: "Glides in on an arc")
            case .growFromBase: String(localized: "Grows up")
            case .slides: String(localized: "Blocks slide in")
            case .colourBands: String(localized: "Colour by colour")
            case .pop: String(localized: "Pops in")
            case .enter: String(localized: "Moves in")
            case .letters: String(localized: "Letter by letter")
            }
        }
    }

    enum SupportMove: String, CaseIterable, Sendable {
        case rise, unroll, outward

        var label: String {
            switch self {
            case .rise: String(localized: "letters rise")
            case .unroll: String(localized: "name unrolls")
            case .outward: String(localized: "name opens out")
            }
        }
    }

    /// Timing and easing for a character (after brand motion systems: calm and premium move
    /// longer with a long ease-out, playful springs, bold is quick and sharp).
    struct Tempo {
        var hero: Double, support: Double, stagger: Double, gap: Double
        var ease: MotionSpec.Ease, landing: MotionSpec.Ease

        init(_ personality: LogoProfile.Personality) {
            switch personality {
            case .calm: (hero, support, stagger, gap, ease, landing) = (0.8, 0.7, 0.11, 0.12, .calm, .calm)
            case .premium: (hero, support, stagger, gap, ease, landing) = (1.05, 0.9, 0.17, 0.2, .premium, .premium)
            case .playful: (hero, support, stagger, gap, ease, landing) = (0.62, 0.55, 0.07, 0.06, .outCubic, .spring)
            case .bold: (hero, support, stagger, gap, ease, landing) = (0.45, 0.45, 0.05, 0.06, .bold, .outBack)
            }
        }
    }

    /// The moves that suit this logo's hero, best first, with how well each suits it.
    func heroMoves() -> [(move: HeroMove, score: Double)] {
        let p = profile
        guard !p.hero.isEmpty, !p.templateOnly else { return [] }
        let heroIsText = p.hero.allSatisfy { p.roles[$0] == .wordmark || p.roles[$0] == .tagline }
        if heroIsText && !p.hero.contains(where: { elements[$0].spark }) { return [(.letters, 0.7)] }
        let box = union(p.hero)
        let shapes = p.hero.map { p.shapes[$0] }
        let single = p.hero.count == 1
        var moves: [(HeroMove, Double)] = []
        if shapes.allSatisfy({ $0 == .stroke }) { moves.append((.drawOn, 0.92)) }
        if p.heroSymmetry.turns >= 3 { moves.append((.spin, 0.88)) }
        if single, shapes[0] == .circle || elements[p.hero[0]].spark { moves.append((.arcGlide, shapes[0] == .circle ? 0.86 : 0.72)) }
        if p.facing != .none { moves.append((.enter, p.facing == .up ? 0.7 : 0.8)) }
        if p.facing == .up || (shapes.allSatisfy { $0 == .organic } && box.height > box.width * 0.9) { moves.append((.growFromBase, p.facing == .up ? 0.82 : 0.6)) }
        if p.heroSymmetry.isMirrored, !shapes.contains(.circle), box.width > 8 { moves.append((.converge, 0.78)) }
        if p.hero.count >= 2, shapes.filter({ $0 == .rectangle }).count * 2 >= p.hero.count { moves.append((.slides, 0.8)) }
        let colours = Set(p.hero.map { Self.colourKey(elements[$0].colour) })
        if p.hero.count >= 3, colours.count >= 2 { moves.append((.colourBands, 0.66)) }
        if single, shapes[0] != .stroke { moves.append((.growFromDot, 0.56)) }
        if box.width > box.height * 1.4 { moves.append((.unfoldFromLine, 0.52)) }
        moves.append((.pop, 0.5))
        return moves.sorted { $0.1 > $1.1 }
    }

    private static func colourKey(_ colour: CGColor) -> Int {
        let c = colour.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0]
        return (0..<3).reduce(0) { $0 * 8 + Int(min(max(c[min($1, c.count - 1)], 0), 1) * 7.99) }
    }

    /// The support moves that suit the layout.
    private func supportMoves() -> [SupportMove] {
        switch profile.layout {
        case .symbolLeft, .symbolRight: [.unroll, .rise]
        case .symbolAbove, .symbolBelow: [.rise, .outward]
        case .inside, .badge: [.outward, .rise]
        case .nameOnly, .symbolOnly: [.rise, .outward]
        }
    }

    /// A design for this logo: seed 0 is the best fit, others are other ideas (the same seed
    /// always gives the same design). Nil when the logo is too detailed to take apart.
    /// `pace` stretches or tightens the whole concept (a Reveal unhurried, a Sting brief).
    func design(seed: Int = 0, personality: LogoProfile.Personality? = nil, hero chosenMove: HeroMove? = nil, pace: Double = 1) -> Design? {
        let moves = heroMoves()
        guard !moves.isEmpty else { return nil }
        var random = SeededRandom(seed: UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 &+ 1)
        // Seed 0: the best; then the others among the best few, in turn.
        let choices = Array(moves.prefix(3))
        // A move someone chose for the hero (if it suits it), else the idea's.
        let hero = chosenMove.flatMap { move in moves.first { $0.move == move } } ?? (seed == 0 ? choices[0] : choices[seed % choices.count])
        let supports = supportMoves()
        let support = seed == 0 ? supports[0] : supports[(seed / choices.count + seed) % supports.count]
        var tempo = Tempo(personality ?? profile.personality())
        tempo.hero *= pace; tempo.support *= pace; tempo.stagger *= pace; tempo.gap *= pace
        let jitter = seed == 0 ? 1.0 : 0.9 + 0.2 * random.next()

        var tracks: [Int: [MotionSpec.Track]] = [:]
        let heroEnd = compose(hero.move, tempo: tempo, jitter: jitter, random: &random, into: &tracks)
        let end = composeSupport(support, after: heroEnd + tempo.gap - tempo.support * 0.35, tempo: tempo, into: &tracks)
        // Parts no move took (a line under the name, a second symbol): they slide into view.
        composeRest(after: min(heroEnd, end), tempo: tempo, into: &tracks)

        var spec = MotionSpec(tracks: elements.indices.flatMap { tracks[$0] ?? [] })
        spec = settle(spec)
        let valid = finalFrameMatches(spec)
        let name = hero.move == .letters ? hero.move.label : "\(hero.move.label) · \(support.label)"
        return Design(spec: spec, name: name, score: hero.score, valid: valid, seed: seed)
    }

    // MARK: Hero

    /// Adds the hero's tracks; returns when it has landed.
    private func compose(_ move: HeroMove, tempo: Tempo, jitter: Double, random: inout SeededRandom,
                         into tracks: inout [Int: [MotionSpec.Track]]) -> Double {
        let p = profile
        let hero = p.hero
        let box = union(hero)
        let length = tempo.hero * jitter
        let centre = CGPoint(x: box.midX, y: box.midY)
        func track(_ i: Int, appears: Double? = 0) -> MotionSpec.Track {
            MotionSpec.Track(part: .init(index: i), appears: appears)
        }
        /// An anchor at a point of the logo, in a part's own box (it can be outside it).
        func anchor(_ point: CGPoint, of i: Int) -> CGPoint {
            let b = elements[i].box
            return CGPoint(x: (point.x - b.minX) / max(b.width, 1), y: (point.y - b.minY) / max(b.height, 1))
        }
        func fadeIn(_ t: inout MotionSpec.Track, from start: Double, length: Double) {
            t.move(.opacity, from: 0, to: 1, start: start, end: start + length, ease: .outCubic)
        }
        switch move {
        case .drawOn:
            for (n, i) in hero.enumerated() {
                let start = Double(n) * tempo.stagger
                var t = track(i)
                t.stroked = true
                t.move(.strokeTrim, from: 0, to: 1, start: start, end: start + length * 0.75, ease: .inOutCubic)
                t.move(.strokeOpacity, from: 1, to: 0, start: start + length * 0.6, end: start + length * 1.1, ease: .outCubic)
                t.move(.opacity, from: 0, to: 1, start: start + length * 0.55, end: start + length * 1.1, ease: .outCubic)
                tracks[i, default: []].append(t)
            }
            return Double(hero.count - 1) * tempo.stagger + length * 1.1
        case .spin:
            // The whole hero turns one step of its symmetry round its middle as it grows.
            let step = 2 * Double.pi / Double(max(p.heroSymmetry.turns, 3))
            let direction: Double = random.next() < 0.5 && jitter != 1 ? -1 : 1
            for i in hero {
                var t = track(i)
                t.anchor = anchor(centre, of: i)
                t.move(.rotation, from: step * direction, to: 0, start: 0, end: length * 1.2, ease: tempo.ease)
                t.move(.scale, from: 0.45, to: 1, start: 0, end: length * 1.2, ease: tempo.landing)
                fadeIn(&t, from: 0, length: length * 0.4)
                tracks[i, default: []].append(t)
            }
            return length * 1.2
        case .arcGlide:
            // From the side away from the name, over an arc, a little squash as it lands.
            let i = hero[0]
            let fromRight = p.layout == .symbolRight
            let dx = (fromRight ? 1 : -1) * max(box.width * 1.6, size.width * 0.18)
            var t = track(i)
            t.move(.translateX, from: dx, to: 0, start: 0, end: length * 1.1, ease: .outCubic)
            t.keys[.translateY] = [.init(time: 0, value: -box.height * 0.9), .init(time: length * 1.1, value: 0, ease: .inOutCubic)]
            t.anchor = CGPoint(x: 0.5, y: 1)
            t.keys[.stretch] = [.init(time: length * 0.95, value: 1), .init(time: length * 1.12, value: 0.88, ease: .outCubic),
                                .init(time: length * 1.4, value: 1, ease: .outBack)]
            fadeIn(&t, from: 0, length: length * 0.3)
            tracks[i, default: []].append(t)
            return length * 1.3
        case .enter:
            // Moving the way it faces, out of a soft focus.
            let distance = max(box.width, box.height) * 0.45
            let (dx, dy): (Double, Double) = switch p.facing {
            case .right: (-distance, 0)
            case .left: (distance, 0)
            case .up: (0, distance)
            case .down: (0, -distance)
            case .none: (0, 0)
            }
            for (n, i) in hero.enumerated() {
                let start = Double(n) * tempo.stagger * 0.5
                var t = track(i)
                t.move(.translateX, from: dx, to: 0, start: start, end: start + length, ease: tempo.ease)
                t.move(.translateY, from: dy, to: 0, start: start, end: start + length, ease: tempo.ease)
                t.move(.focus, from: 0.7, to: 0, start: start, end: start + length * 0.8, ease: .outCubic)
                fadeIn(&t, from: start, length: length * 0.45)
                tracks[i, default: []].append(t)
            }
            return Double(hero.count - 1) * tempo.stagger * 0.5 + length
        case .growFromBase:
            for (n, i) in hero.enumerated() {
                let start = Double(n) * tempo.stagger
                var t = track(i)
                t.anchor = anchor(CGPoint(x: elements[i].box.midX, y: box.maxY), of: i)
                t.move(.scaleY, from: 0.02, to: 1, start: start, end: start + length, ease: tempo.landing)
                t.move(.scaleX, from: 0.8, to: 1, start: start, end: start + length, ease: tempo.ease)
                fadeIn(&t, from: start, length: length * 0.25)
                tracks[i, default: []].append(t)
            }
            return Double(hero.count - 1) * tempo.stagger + length
        case .converge:
            // Each half from its own side, meeting on the axis (the halves overlap a hair, so no
            // seam shows).
            let axis = box.midX, offset = box.width * 0.35
            let pad = max(box.width, box.height)
            let left = CGRect(x: box.minX - pad, y: box.minY - pad, width: axis - box.minX + pad + 0.5, height: box.height + pad * 2)
            let right = CGRect(x: axis - 0.5, y: box.minY - pad, width: box.maxX - axis + pad + 0.5, height: box.height + pad * 2)
            for i in hero {
                for (region, from) in [(left, -offset), (right, offset)] where region.intersects(elements[i].box) {
                    var t = track(i)
                    t.clip = .piece(region)
                    t.move(.translateX, from: from, to: 0, start: 0, end: length, ease: tempo.ease)
                    fadeIn(&t, from: 0, length: length * 0.5)
                    tracks[i, default: []].append(t)
                }
            }
            return length
        case .slides:
            // Each block slides up or down into its own place, one after another.
            let order = hero.sorted { elements[$0].box.minX < elements[$1].box.minX }
            for (n, i) in order.enumerated() {
                let b = elements[i].box, start = Double(n) * tempo.stagger
                var t = track(i, appears: start)
                t.clip = .region(b.insetBy(dx: -1, dy: -0.5))
                t.move(.translateY, from: (n % 2 == 0 ? 1 : -1) * b.height, to: 0, start: start, end: start + length, ease: tempo.ease)
                tracks[i, default: []].append(t)
            }
            return Double(order.count - 1) * tempo.stagger + length
        case .colourBands:
            // One colour after another, each popping into place.
            var groups: [Int: [Int]] = [:]
            for i in hero { groups[Self.colourKey(elements[i].colour), default: []].append(i) }
            let ordered = groups.values.sorted { union($0).minX < union($1).minX }
            for (n, group) in ordered.enumerated() {
                let start = Double(n) * max(tempo.stagger * 2, 0.12)
                for i in group {
                    var t = track(i, appears: start)
                    t.move(.scale, from: 0.6, to: 1, start: start, end: start + length, ease: tempo.landing)
                    fadeIn(&t, from: start, length: length * 0.35)
                    tracks[i, default: []].append(t)
                }
            }
            return Double(ordered.count - 1) * max(tempo.stagger * 2, 0.12) + length
        case .growFromDot:
            let i = hero[0]
            var t = track(i)
            t.move(.scale, from: 0.04, to: 1, start: 0, end: length * 1.1, ease: tempo.landing)
            t.move(.focus, from: 1, to: 0, start: 0, end: length * 0.9, ease: .outCubic)
            fadeIn(&t, from: 0, length: length * 0.3)
            tracks[i, default: []].append(t)
            return length * 1.1
        case .unfoldFromLine:
            for i in hero {
                var t = track(i)
                t.anchor = anchor(centre, of: i)
                t.keys[.scaleX] = [.init(time: 0, value: 0.02), .init(time: length * 0.5, value: 1, ease: tempo.ease)]
                t.keys[.scaleY] = [.init(time: length * 0.35, value: 0.03), .init(time: length * 1.1, value: 1, ease: tempo.landing)]
                fadeIn(&t, from: 0, length: length * 0.2)
                tracks[i, default: []].append(t)
            }
            return length * 1.1
        case .pop:
            for (n, i) in hero.enumerated() {
                let start = Double(n) * tempo.stagger * 0.6
                var t = track(i)
                t.anchor = anchor(centre, of: i)
                t.move(.scale, from: 0.5, to: 1, start: start, end: start + length, ease: tempo.landing == .calm || tempo.landing == .premium ? .outBack : tempo.landing)
                fadeIn(&t, from: start, length: length * 0.35)
                tracks[i, default: []].append(t)
            }
            return Double(hero.count - 1) * tempo.stagger * 0.6 + length
        case .letters:
            return 0
        }
    }

    // MARK: Support

    /// The name (and tagline, plates, dots) after the hero; returns when it has landed.
    private func composeSupport(_ move: SupportMove, after start: Double, tempo: Tempo, into tracks: inout [Int: [MotionSpec.Track]]) -> Double {
        let p = profile
        let start = max(start, 0)
        let symbolBox = p.hero.isEmpty ? CGRect.null : union(p.hero)
        let lines = textLines()
        let taglineLines = lines.filter { $0.allSatisfy { p.roles[$0] == .tagline } }
        let nameLines = lines.filter { line in !taglineLines.contains(line) }
        var end = start

        // Plates that aren't the hero come first (the letters sit on them).
        var at = start
        for i in elements.indices where p.roles[i] == .plate && tracks[i] == nil {
            var t = MotionSpec.Track(part: .init(index: i), appears: at)
            t.anchor = CGPoint(x: 0.5, y: 0.5)
            t.move(.scaleX, from: 0.9, to: 1, start: at, end: at + tempo.support, ease: tempo.ease)
            t.move(.opacity, from: 0, to: 1, start: at, end: at + tempo.support * 0.5, ease: .outCubic)
            tracks[i, default: []].append(t)
            at += tempo.stagger
            end = max(end, at + tempo.support)
        }

        // The name's letters, in order from the hero's side.
        let letters = nameLines.flatMap { $0 }.filter { tracks[$0] == nil }
        let fromRight = p.layout == .symbolRight
        let order: [Int]
        switch move {
        case .outward:
            let middle = symbolBox.isNull ? union(letters).midX : symbolBox.midX
            order = letters.sorted { abs(elements[$0].box.midX - middle) < abs(elements[$1].box.midX - middle) }
        default:
            order = fromRight ? letters.reversed() : letters
        }
        let stagger = order.count > 1 ? min(tempo.stagger, 0.6 / Double(order.count - 1)) : 0
        let nameBox = union(letters)
        for (n, i) in order.enumerated() {
            let b = elements[i].box
            // (Unrolling, the name moves as one: letters a hair apart would overlap.)
            let begin = at + Double(n) * (move == .unroll ? 0 : stagger)
            var t = MotionSpec.Track(part: .init(index: i), appears: begin)
            switch move {
            case .rise:
                t.clip = .aboveBaseline
                t.move(.translateY, from: b.height * 0.9, to: 0, start: begin, end: begin + tempo.support, ease: tempo.ease)
                t.move(.opacity, from: 0, to: 1, start: begin, end: begin + tempo.support * 0.3, ease: .linear)
            case .unroll:
                // Out from behind the symbol's edge, the whole name as one.
                let edge = fromRight ? symbolBox.minX : symbolBox.maxX
                let pad = max(nameBox.height, 1) * 2
                t.clip = .region(fromRight
                    ? CGRect(x: nameBox.minX - pad, y: nameBox.minY - pad, width: edge - nameBox.minX + pad, height: nameBox.height + pad * 2)
                    : CGRect(x: edge, y: nameBox.minY - pad, width: nameBox.maxX - edge + pad, height: nameBox.height + pad * 2))
                // Starting tucked behind the edge, all of it.
                let travel = fromRight ? (edge - nameBox.minX) + 4 : -((nameBox.maxX - edge) + 4)
                t.move(.translateX, from: travel, to: 0, start: begin, end: begin + tempo.support * 1.2, ease: tempo.ease)
                t.move(.opacity, from: 0, to: 1, start: begin, end: begin + tempo.support * 0.4, ease: .outCubic)
            case .outward:
                let centre = symbolBox.isNull ? CGPoint(x: nameBox.midX, y: nameBox.midY) : CGPoint(x: symbolBox.midX, y: symbolBox.midY)
                t.move(.translateX, from: (centre.x - b.midX) * 0.2, to: 0, start: begin, end: begin + tempo.support, ease: tempo.ease)
                t.move(.scale, from: 0.85, to: 1, start: begin, end: begin + tempo.support, ease: tempo.ease)
                t.move(.opacity, from: 0, to: 1, start: begin, end: begin + tempo.support * 0.5, ease: .outCubic)
            }
            tracks[i, default: []].append(t)
            end = max(end, begin + tempo.support * (move == .unroll ? 1.2 : 1))
        }

        // Dots and accents land last on their letters, with a small pop.
        for i in elements.indices where elements[i].kind == .accent && tracks[i] == nil {
            let base = elements[i].base.flatMap { tracks[$0]?.first?.end } ?? end
            var t = MotionSpec.Track(part: .init(index: i), appears: base - 0.05)
            t.move(.scale, from: 0, to: 1, start: base - 0.05, end: base + 0.35, ease: .outBack)
            tracks[i, default: []].append(t)
            end = max(end, base + 0.35)
        }

        // The tagline, last and quiet.
        let tagline = taglineLines.flatMap { $0 }.filter { tracks[$0] == nil }
        if !tagline.isEmpty {
            let begin = end - tempo.support * 0.3
            for i in tagline {
                var t = MotionSpec.Track(part: .init(index: i), appears: begin)
                t.move(.translateY, from: elements[i].box.height * 0.6, to: 0, start: begin, end: begin + tempo.support, ease: tempo.ease)
                t.move(.opacity, from: 0, to: 1, start: begin, end: begin + tempo.support * 0.8, ease: .outCubic)
                tracks[i, default: []].append(t)
            }
            end = begin + tempo.support
        }
        return end
    }

    /// Whatever no move took: slides into view from its left, after the hero.
    private func composeRest(after start: Double, tempo: Tempo, into tracks: inout [Int: [MotionSpec.Track]]) {
        var at = start
        for i in elements.indices where tracks[i] == nil {
            let b = elements[i].box
            var t = MotionSpec.Track(part: .init(index: i), appears: at)
            t.clip = .region(b.insetBy(dx: -1, dy: -1))
            t.move(.translateX, from: -b.width, to: 0, start: at, end: at + tempo.support, ease: tempo.ease)
            tracks[i, default: []].append(t)
            at += tempo.stagger
        }
    }

    // MARK: The last frame

    /// Every move ends exactly at rest (a design's last frame must be the logo).
    func settle(_ spec: MotionSpec) -> MotionSpec {
        var spec = spec
        let end = spec.duration
        for n in spec.tracks.indices {
            for (property, keys) in spec.tracks[n].keys {
                guard let last = keys.last, abs(last.value - property.rest) > 1e-9 else { continue }
                spec.tracks[n].keys[property]!.append(.init(time: max(end, last.time + 0.05), value: property.rest, ease: .outCubic))
            }
        }
        return spec
    }

    /// Whether a spec's last frame is the logo: drawn at the end, it matches every part drawn in
    /// its place (fewer than 0.3% of the pixels differ visibly). (For a logo read from a picture,
    /// parts drawn one by one differ from the picture a little at their soft edges; the finished
    /// logo is shown from the picture itself once the animation settles.)
    func finalFrameMatches(_ spec: MotionSpec) -> Bool {
        let canvas = CGSize(width: 480, height: 270)
        func render(_ draw: (CGContext) -> Void) -> [UInt8]? {
            var bytes = [UInt8](repeating: 0, count: 480 * 270 * 4)
            let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: 480, height: 270, bitsPerComponent: 8, bytesPerRow: 480 * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.interpolationQuality = .high
                draw(context)
                return true
            }
            return ok ? bytes : nil
        }
        guard let designed = render({ draw(at: spec.duration + 0.001, spec: spec, in: $0, canvas: canvas) }),
              let logo = render({ draw(at: 0, spec: MotionSpec(tracks: elements.indices.map { .init(part: .init(index: $0)) }), in: $0, canvas: canvas) })
        else { return false }
        var off = 0
        for i in stride(from: 0, to: designed.count, by: 4) {
            if (0..<4).contains(where: { abs(Int(designed[i + $0]) - Int(logo[i + $0])) > 40 }) { off += 1 }
        }
        return Double(off) < Double(480 * 270) * 0.003
    }
}

/// Numbers from a seed, the same every time (SplitMix64).
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    /// 0 ..< 1.
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
