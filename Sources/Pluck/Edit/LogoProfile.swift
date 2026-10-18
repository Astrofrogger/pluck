import CoreGraphics
import Foundation

/// A logo read the way a motion designer reads it before animating it: what each part is (the
/// symbol, the name, a tagline, a plate), how they sit, which part is the hero, what each part
/// looks like (a circle, a box, a line, a free shape), its symmetry, what repeats, which way the
/// hero faces, and the character all that suggests.
struct LogoProfile: Sendable {
    enum Role: String, Sendable { case symbol, wordmark, tagline, plate }

    enum Layout: String, Sendable {
        case symbolLeft, symbolRight, symbolAbove, symbolBelow
        /// The name inside the symbol (a ring or a shield around it).
        case inside
        /// The name on a plate, without another symbol.
        case badge
        case nameOnly, symbolOnly
    }

    enum ShapeClass: String, Sendable { case circle, rectangle, stroke, organic }

    enum Facing: String, Sendable { case none, left, right, up, down }

    enum Personality: String, CaseIterable, Codable, Identifiable, Sendable {
        case calm, premium, playful, bold
        var id: String { rawValue }
        var label: String {
            switch self {
            case .calm: String(localized: "Calm")
            case .premium: String(localized: "Premium")
            case .playful: String(localized: "Playful")
            case .bold: String(localized: "Bold")
            }
        }
        var help: String {
            switch self {
            case .calm: String(localized: "Unhurried, a gentle ease-out, no overshoot")
            case .premium: String(localized: "Slow and long, settling with care")
            case .playful: String(localized: "Quick and springy, a little bounce")
            case .bold: String(localized: "Fast and sharp, a firm landing")
            }
        }
    }

    struct Symmetry: Sendable {
        /// How well it matches its mirror image about a vertical axis (1 is perfectly), and about
        /// a horizontal one.
        var mirror = 0.0, flip = 0.0
        /// It looks the same turned by 1/turns of a circle (0: not, or it's round).
        var turns = 0
        var isMirrored: Bool { mirror >= 0.88 }
        var isFlipped: Bool { flip >= 0.88 }
    }

    struct Metrics: Sendable {
        /// The share of the outlines that's curved (rather than straight).
        var roundness = 0.0
        /// Sharp corners per part.
        var angularity = 0.0
        /// How heavy the lines are: their width against the letters' height (or the parts' size).
        var weight = 0.0
        /// How much a line's width varies (thick and thin strokes: a serif face, mostly).
        var contrast = 0.0
        /// How colourful (0 grey … 1 full colour), by area.
        var saturation = 0.0
        var colours = 1
        var serif = false
    }

    /// Per part (as `LogoAnimation.elements`).
    var roles: [Role] = []
    var shapes: [ShapeClass] = []
    var layout = Layout.symbolOnly
    /// The part or group of parts that leads: the symbol, else a plate, else a spark, else the
    /// first letter.
    var hero: [Int] = []
    var heroSymmetry = Symmetry()
    var logoSymmetry = Symmetry()
    /// Groups of parts that are the same shape (bars, dots, petals).
    var repeats: [[Int]] = []
    var facing = Facing.none
    var metrics = Metrics()
    var scores: [Personality: Double] = [:]
    /// Too detailed to take apart (an illustration, a busy picture): only the templates suit it.
    var templateOnly = false

    var hasTagline: Bool { roles.contains(.tagline) }

    /// What the hero looks like, when all its parts are alike.
    var heroShape: ShapeClass? {
        guard let first = hero.first.map({ shapes[$0] }), hero.allSatisfy({ shapes[$0] == first }) else { return nil }
        return first
    }

    /// The character the shapes suggest; the director's mood decides when two are close.
    func personality(mood: LogoDirector.Mood? = nil) -> Personality {
        let ranked = scores.sorted { $0.value > $1.value }
        guard let best = ranked.first?.key else { return .calm }
        if let mood, ranked.count > 1, ranked[0].value - ranked[1].value < 0.06 {
            let suggested: Personality = switch mood {
            case .playful, .friendly: .playful
            case .bold, .technical: .bold
            case .elegant: .premium
            case .organic: .calm
            }
            if ranked.prefix(2).contains(where: { $0.key == suggested }) { return suggested }
        }
        return best
    }

    /// One short line about the logo, for the Video card.
    var summary: String {
        if templateOnly { return String(localized: "A detailed picture: the template styles suit it") }
        var parts: [String] = []
        switch layout {
        case .symbolLeft, .symbolRight: parts.append(String(localized: "Symbol beside a name"))
        case .symbolAbove: parts.append(String(localized: "Symbol over a name"))
        case .symbolBelow: parts.append(String(localized: "Name over a symbol"))
        case .inside: parts.append(String(localized: "Name inside a symbol"))
        case .badge: parts.append(String(localized: "Name on a badge"))
        case .nameOnly: parts.append(String(localized: "Name only"))
        case .symbolOnly: parts.append(String(localized: "Symbol only"))
        }
        if hasTagline { parts.append(String(localized: "tagline")) }
        if heroSymmetry.turns >= 3 {
            parts.append(String(localized: "\(heroSymmetry.turns)-fold"))
        } else if heroSymmetry.isMirrored, layout != .nameOnly, heroShape != .circle {
            parts.append(String(localized: "mirrored"))
        }
        switch facing {
        case .left: parts.append(String(localized: "faces left"))
        case .right: parts.append(String(localized: "faces right"))
        case .up: parts.append(String(localized: "points up"))
        case .down: parts.append(String(localized: "points down"))
        case .none: break
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Reading a logo

extension LogoAnimation {
    /// The profile of this logo (worked out from its parts; takes a moment for a big one).
    func makeProfile() -> LogoProfile {
        var profile = LogoProfile()
        guard !elements.isEmpty else { return profile }
        let masks = elements.map { PartMask($0) }

        // Roles: letters in lines; a line of much smaller letters is a tagline.
        var roles = elements.map { element -> LogoProfile.Role in
            switch element.kind {
            case .plate: .plate
            case .symbol: .symbol
            case .letter, .accent: .wordmark
            }
        }
        let lines = textLines()
        if lines.count > 1 {
            let heights = lines.map { line in line.map { elements[$0].box.height }.sorted()[line.count / 2] }
            let main = heights.indices.max { heights[$0] < heights[$1] }!
            for (n, line) in lines.enumerated() where n != main && heights[n] < heights[main] * 0.72 {
                for i in line { roles[i] = .tagline }
            }
        }
        // Shapes guessed to be letters (unread by the text recogniser) that are plain boxes or
        // circles: bars and dots of a symbol, not a custom typeface.
        let shapeClasses = elements.indices.map { shapeClass($0, mask: masks[$0]) }
        let guessed = elements.indices.filter { elements[$0].guessedLetter }
        if !guessed.isEmpty, guessed.allSatisfy({ [.rectangle, .circle].contains(shapeClasses[$0]) }) {
            for i in guessed { roles[i] = .symbol }
        }
        // What the analysis took for letters but isn't: a ring or shape round the name (it holds
        // letters), and identical shapes that don't sit in a row (petals, a cluster of dots).
        let letterIndices = elements.indices.filter { elements[$0].kind == .letter }
        for i in letterIndices {
            let box = elements[i].box
            let held = letterIndices.filter { $0 != i && box.contains(CGPoint(x: elements[$0].box.midX, y: elements[$0].box.midY)) }
            // (One that hugs the letters is their outline, part of the name.)
            let hugged = union(held)
            let hugs = !held.isEmpty && box.width < hugged.width * 1.25 && box.height < hugged.height * 1.35
            if held.count >= 2, !hugs { roles[i] = .symbol }
        }
        let candidates = letterIndices.filter { roles[$0] == .wordmark }
        if candidates.count >= 3 {
            func alike(_ a: CGRect, _ b: CGRect) -> Bool { abs(a.width - b.width) <= b.width * 0.06 && abs(a.height - b.height) <= b.height * 0.06 }
            let groups = candidates.map { i in candidates.filter { alike(elements[$0].box, elements[i].box) } }
            if let group = groups.max(by: { $0.count < $1.count }), group.count >= 3 {
                let middles = group.map { elements[$0].box.midY }
                let inRow = (middles.max()! - middles.min()!) < elements[group[0]].box.height * 0.5
                let around = union(group)
                let others = candidates.filter { !group.contains($0) }
                if !inRow, others.allSatisfy({ around.contains(CGPoint(x: elements[$0].box.midX, y: elements[$0].box.midY)) }) {
                    for i in candidates { roles[i] = .symbol }
                }
            }
        }
        correctRoles(&roles, lines: lines, shapes: shapeClasses)
        for i in elements.indices where elements[i].kind == .accent {
            if let base = elements[i].base, roles[base] == .symbol { roles[i] = .symbol }
        }
        // An accent over a symbol (an arrow's head) is part of it.
        for i in elements.indices where elements[i].kind == .accent && roles[i] != .symbol {
            if elements.indices.contains(where: { roles[$0] == .symbol && elements[$0].box.insetBy(dx: -4, dy: -4).intersects(elements[i].box) }) { roles[i] = .symbol }
        }
        profile.roles = roles

        // What each part looks like.
        profile.shapes = shapeClasses

        // Layout, from the symbol's main cluster: its biggest part and what touches or nearly
        // touches it (a line under the name or a lone dot isn't the symbol).
        // (Specks such as a ® mark don't count: not as the symbol, not for the layout.)
        let largest = elements.map(\.area).max() ?? 0
        let allSymbols = elements.indices.filter {
            roles[$0] == .symbol && !(elements[$0].area < largest * 0.02 && max(elements[$0].box.width, elements[$0].box.height) < max(size.width, size.height) * 0.06)
        }
        let symbols = mainCluster(allSymbols)
        let names = elements.indices.filter { roles[$0] == .wordmark || roles[$0] == .tagline }
        let plates = elements.indices.filter { roles[$0] == .plate }
        profile.layout = layout(symbols: symbols, names: names, plates: plates)

        // The hero.
        let sparks = self.sparks
        let mainLetters = elements.indices.filter { roles[$0] == .wordmark && elements[$0].kind == .letter }
        if !symbols.isEmpty {
            profile.hero = symbols
        } else if !plates.isEmpty {
            profile.hero = plates
        } else if let spark = sparks.first {
            profile.hero = [spark]
        } else if let first = mainLetters.first {
            profile.hero = [first]
        }

        // Symmetry of the hero and of the whole logo.
        let heroMask = PartMask.union(profile.hero.map { masks[$0] })
        profile.heroSymmetry = heroMask.symmetry()
        if profile.hero.count == 1, profile.shapes[profile.hero[0]] == .circle { profile.heroSymmetry.turns = 0 }
        profile.logoSymmetry = PartMask.union(masks).symmetry(turns: false)

        // What repeats: parts other than letters of the same size and ink.
        var groups: [[Int]] = []
        for i in elements.indices where roles[i] == .symbol || roles[i] == .plate || elements[i].spark {
            let a = elements[i]
            if let g = groups.firstIndex(where: { group in
                let b = elements[group[0]]
                return abs(a.box.width - b.box.width) <= max(b.box.width * 0.06, 2) && abs(a.box.height - b.box.height) <= max(b.box.height * 0.06, 2)
                    && abs(a.area - b.area) <= b.area * 0.08
            }) {
                groups[g].append(i)
            } else {
                groups.append([i])
            }
        }
        profile.repeats = groups.filter { $0.count >= 2 }

        // Which way the hero faces: a pointed tip, on a hero that isn't mirrored or turning.
        if !symbols.isEmpty || !plates.isEmpty { profile.facing = facing(heroMask, symmetry: profile.heroSymmetry) }

        // Character.
        profile.metrics = metrics(masks: masks, roles: roles)
        profile.scores = personalityScores(profile.metrics)

        // An illustration (taken as one part from many) or a busy picture: templates only.
        let detailed = elements.count == 1 && elements[0].outlines.count > 30
        profile.templateOnly = detailed || elements.count > 60 || profile.metrics.colours > 8
        return profile
    }

    /// The cluster of parts with the most ink: parts each within a small gap of the others (a
    /// symbol of many pieces outweighs one big stray letter).
    private func mainCluster(_ parts: [Int]) -> [Int] {
        var left = Set(parts), clusters: [[Int]] = []
        while let seed = left.max(by: { elements[$0].area < elements[$1].area }) {
            var cluster = [seed]
            left.remove(seed)
            var changed = true
            while changed {
                changed = false
                let box = union(cluster)
                let gap = max(box.width, box.height) * 0.12
                for i in left where box.insetBy(dx: -gap, dy: -gap).intersects(elements[i].box) {
                    cluster.append(i)
                    left.remove(i)
                    changed = true
                }
            }
            clusters.append(cluster)
        }
        return (clusters.max { a, b in a.reduce(0) { $0 + elements[$1].area } < b.reduce(0) { $0 + elements[$1].area } } ?? []).sorted()
    }

    /// Fixes the analysis's guesses about what's text, from how the parts sit: a symbol read as a
    /// letter (far taller than its line, or pieces that overlap like no letters do), a lone wide
    /// shape on a line of its own (a swoosh under the name), a plate round a single letter (a
    /// monogram), and stray symbol parts in the name's row (letters the recogniser missed).
    private func correctRoles(_ roles: inout [LogoProfile.Role], lines: [[Int]], shapes: [LogoProfile.ShapeClass]) {
        // Parts these rules find to be symbols stay symbols.
        var found = Set<Int>()
        // At the start or end of a line, a part far taller and far bigger than all the others in
        // it (not just a capital or an ascender).
        for line in lines where line.count >= 2 {
            for i in Set([line.first!, line.last!]) {
                let others = line.filter { $0 != i }
                let tallest = others.map { elements[$0].box.height }.max() ?? 0
                let widest = others.map { elements[$0].box.width }.max() ?? 0
                let biggest = others.map { elements[$0].box.width * elements[$0].box.height }.max() ?? 0
                let b = elements[i].box
                if b.width * b.height >= biggest * 3 && (b.height >= tallest * 1.4 || b.width >= widest * 2) { roles[i] = .symbol; found.insert(i) }
            }
        }
        // Parts taken for letters that overlap each other across (stacked or linked pieces).
        let texty = elements.indices.filter { roles[$0] == .wordmark || roles[$0] == .tagline }
        for i in texty {
            let a = elements[i].box
            for j in texty where j != i && elements[j].kind != .accent && elements[i].kind != .accent {
                let b = elements[j].box
                let across = min(a.maxX, b.maxX) - max(a.minX, b.minX)
                // (Overlapping across and in height: letters on lines above each other don't.)
                guard across > min(a.width, b.width) * 0.3, b.minY < a.maxY, a.minY < b.maxY else { continue }
                if elements[i].guessedLetter || elements[j].guessedLetter {
                    roles[i] = .symbol; roles[j] = .symbol
                    found.formUnion([i, j])
                }
            }
        }
        // A guessed letter that's a plain circle or box at the start or end of its row.
        for line in lines {
            for i in [line.first, line.last].compactMap({ $0 }) where elements[i].guessedLetter && [.circle, .rectangle].contains(shapes[i]) { roles[i] = .symbol; found.insert(i) }
        }
        // A guessed box or circle touching a symbol is a piece of it.
        for i in elements.indices where elements[i].guessedLetter && [.circle, .rectangle].contains(shapes[i]) && roles[i] != .symbol {
            if elements.indices.contains(where: { j in j != i && roles[j] == .symbol && elements[j].box.insetBy(dx: -2, dy: -2).intersects(elements[i].box) }) {
                roles[i] = .symbol; found.insert(i)
            }
        }
        // A line of one wide shape is a symbol, not text.
        for line in lines where line.count == 1 {
            let b = elements[line[0]].box
            if b.width > b.height * 3 || b.height > b.width * 3 { roles[line[0]] = .symbol; found.insert(line[0]) }
        }
        // A box-like part (filling most of its box) that holds most of the name: a plate.
        let named = elements.indices.filter { (roles[$0] == .wordmark || roles[$0] == .tagline) && elements[$0].kind == .letter }
        for i in elements.indices where roles[i] != .plate && !named.isEmpty {
            let b = elements[i].box
            let held = named.filter { $0 != i && b.contains(CGPoint(x: elements[$0].box.midX, y: elements[$0].box.midY)) }
            let fill = elements[i].area / max(b.width * b.height, 1)
            if Double(held.count) >= Double(named.count - (named.contains(i) ? 1 : 0)) * 0.6, held.count >= 2, fill > 0.6 || shapes[i] == .rectangle {
                roles[i] = .plate
            }
        }
        // A plate round one letter (and not round the name) is a monogram: a symbol.
        let letters = elements.indices.filter { roles[$0] == .wordmark && elements[$0].kind == .letter }
        for i in elements.indices where roles[i] == .plate {
            let held = letters.filter { elements[i].box.contains(CGPoint(x: elements[$0].box.midX, y: elements[$0].box.midY)) }
            if !held.isEmpty, Double(held.count) < Double(letters.count) * 0.3 {
                roles[i] = .symbol
                for j in held { roles[j] = .symbol }
                found.insert(i); found.formUnion(held)
            }
        }
        // Symbol parts in the name's row, letter-sized and close to a letter: letters.
        let row = elements.indices.filter { roles[$0] == .wordmark && elements[$0].kind == .letter }
        if row.count >= 2 {
            let heights = row.map { elements[$0].box.height }.sorted()
            let median = heights[heights.count / 2]
            let middle = row.map { elements[$0].box.midY }.sorted()[row.count / 2]
            for i in elements.indices where roles[i] == .symbol && elements[i].kind == .symbol && !found.contains(i) {
                let b = elements[i].box
                // (Up to an ascender's height: an l or a k.)
                guard abs(b.midY - middle) < median * 0.45, b.height < median * 1.5, b.height > median * 0.6 else { continue }
                let gap = row.map { j -> Double in
                    let c = elements[j].box
                    return max(c.minX - b.maxX, b.minX - c.maxX, 0)
                }.min() ?? .infinity
                if gap < median * 0.35 { roles[i] = .wordmark }
            }
        }
    }

    /// Letters (and their dots) in lines, top to bottom, each left to right.
    func textLines() -> [[Int]] {
        let letters = elements.indices.filter { elements[$0].kind == .letter }.sorted { elements[$0].box.midY < elements[$1].box.midY }
        guard !letters.isEmpty else { return [] }
        let typical = letters.map { elements[$0].box.height }.sorted()[letters.count / 2]
        var lines: [[Int]] = [[letters[0]]]
        for i in letters.dropFirst() {
            let line = lines[lines.count - 1]
            let middle = line.map { elements[$0].box.midY }.reduce(0, +) / Double(line.count)
            // A new line when it's well below the last (by the smaller of the two letter sizes).
            let lineHeight = min(typical, line.map { elements[$0].box.height }.max() ?? typical)
            if elements[i].box.midY - middle > max(lineHeight, elements[i].box.height) * 0.8 { lines.append([i]) } else { lines[lines.count - 1].append(i) }
        }
        return lines.map { $0.sorted { elements[$0].box.minX < elements[$1].box.minX } }
    }

    private func layout(symbols: [Int], names: [Int], plates: [Int]) -> LogoProfile.Layout {
        if symbols.isEmpty && names.isEmpty { return .symbolOnly }
        if symbols.isEmpty {
            if !plates.isEmpty {
                let plate = union(plates), name = union(names)
                if plate.intersection(name).width * plate.intersection(name).height > name.width * name.height * 0.6 { return .badge }
            }
            return .nameOnly
        }
        if names.isEmpty { return .symbolOnly }
        let symbol = union(symbols), name = union(names)
        let overlap = symbol.intersection(name)
        if !overlap.isNull, overlap.width * overlap.height > name.width * name.height * 0.5 { return .inside }
        // Which side of the name the symbol is on: the larger gap decides.
        let gaps: [(LogoProfile.Layout, Double)] = [
            (.symbolLeft, name.minX - symbol.maxX), (.symbolRight, symbol.minX - name.maxX),
            (.symbolAbove, name.minY - symbol.maxY), (.symbolBelow, symbol.minY - name.maxY),
        ]
        if let best = gaps.max(by: { $0.1 < $1.1 }), best.1 > -min(symbol.width, symbol.height) * 0.1 { return best.0 }
        return .inside
    }

    // MARK: Shape

    private func shapeClass(_ i: Int, mask: PartMask) -> LogoProfile.ShapeClass {
        let element = elements[i]
        // Drawn as a line in the file.
        if let vector = element.vector, !vector.isEmpty, vector.allSatisfy(\.stroke) { return .stroke }
        let outline = outerOutline(i)
        // A circle: its outline is round (filled or a ring).
        if outline.count >= 8, let fit = Self.circleFit(outline), fit.residual < 0.04, fit.radius > 2 {
            let box = element.box
            if abs(box.width - box.height) < max(box.width, box.height) * 0.08 { return .circle }
        }
        // A box (with square or slightly rounded corners).
        let fill = element.area / max(element.box.width * element.box.height, 1)
        if fill > 0.9 { return .rectangle }
        // A line: of an even width that's thin for its size.
        let widths = mask.lineWidths()
        if widths.count >= 8 {
            let mean = widths.reduce(0, +) / Double(widths.count)
            let spread = (widths.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(widths.count)).squareRoot() / max(mean, 0.001)
            if spread < 0.25, mean < min(element.box.width, element.box.height) * 0.35 { return .stroke }
        }
        return .organic
    }

    /// The outline round the outside of a part (logo pixels): from its vectors when it has them.
    func outerOutline(_ i: Int) -> [CGPoint] {
        let element = elements[i]
        let candidates = element.vector.map { $0.flatMap { Self.polygons($0.path) } } ?? element.outlines
        return candidates.max { a, b in Self.extent(a) < Self.extent(b) } ?? []
    }

    /// All of a part's outlines (outside and holes).
    func allOutlines(_ i: Int) -> [[CGPoint]] {
        elements[i].vector.map { $0.flatMap { Self.polygons($0.path) } } ?? elements[i].outlines
    }

    private static func extent(_ points: [CGPoint]) -> Double {
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return 0 }
        return (maxX - minX) * (maxY - minY)
    }

    /// A path's outlines as polygons (curves cut into short lines).
    static func polygons(_ path: CGPath) -> [[CGPoint]] {
        var result: [[CGPoint]] = []
        var current: [CGPoint] = []
        path.applyWithBlock { element in
            let p = element.pointee.points
            let last = current.last ?? .zero
            switch element.pointee.type {
            case .moveToPoint:
                if current.count > 2 { result.append(current) }
                current = [p[0]]
            case .addLineToPoint:
                current.append(p[0])
            case .addQuadCurveToPoint:
                for k in 1...8 {
                    let t = Double(k) / 8, u = 1 - t
                    current.append(CGPoint(x: u * u * last.x + 2 * u * t * p[0].x + t * t * p[1].x,
                                           y: u * u * last.y + 2 * u * t * p[0].y + t * t * p[1].y))
                }
            case .addCurveToPoint:
                for k in 1...10 {
                    let t = Double(k) / 10, u = 1 - t
                    current.append(CGPoint(x: u * u * u * last.x + 3 * u * u * t * p[0].x + 3 * u * t * t * p[1].x + t * t * t * p[2].x,
                                           y: u * u * u * last.y + 3 * u * u * t * p[0].y + 3 * u * t * t * p[1].y + t * t * t * p[2].y))
                }
            case .closeSubpath:
                if current.count > 2 { result.append(current) }
                current = []
            @unknown default:
                break
            }
        }
        if current.count > 2 { result.append(current) }
        return result
    }

    /// The circle closest to a set of points (least squares), and how far they stray from it
    /// (root mean square, as a share of the radius).
    static func circleFit(_ points: [CGPoint]) -> (centre: CGPoint, radius: Double, residual: Double)? {
        let n = Double(points.count)
        guard n >= 3 else { return nil }
        let mx = points.map(\.x).reduce(0, +) / n, my = points.map(\.y).reduce(0, +) / n
        var suu = 0.0, svv = 0.0, suv = 0.0, suuu = 0.0, svvv = 0.0, suvv = 0.0, svuu = 0.0
        for p in points {
            let u = p.x - mx, v = p.y - my
            suu += u * u; svv += v * v; suv += u * v
            suuu += u * u * u; svvv += v * v * v; suvv += u * v * v; svuu += v * u * u
        }
        let det = suu * svv - suv * suv
        guard abs(det) > 1e-9 else { return nil }
        let a = 0.5 * (suuu + suvv), b = 0.5 * (svvv + svuu)
        let uc = (a * svv - b * suv) / det, vc = (b * suu - a * suv) / det
        let centre = CGPoint(x: mx + uc, y: my + vc)
        let distances = points.map { hypot($0.x - centre.x, $0.y - centre.y) }
        let radius = distances.reduce(0, +) / n
        guard radius > 0 else { return nil }
        let rms = (distances.map { ($0 - radius) * ($0 - radius) }.reduce(0, +) / n).squareRoot()
        return (centre, radius, rms / radius)
    }

    // MARK: Facing

    /// The side that ends in a point while the opposite side is blunt (an arrow's tip, a
    /// triangle's apex, a shield's foot). A mirrored hero can only point up or down; one mirrored
    /// top to bottom only sideways; one that turns into itself (a star, a cross) nowhere.
    private func facing(_ mask: PartMask, symmetry: LogoProfile.Symmetry) -> LogoProfile.Facing {
        guard symmetry.turns < 4 else { return .none }
        let ends = mask.endWidths()
        var options: [(LogoProfile.Facing, Double, Double)] = []
        if !symmetry.isMirrored { options += [(.left, ends.left, ends.right), (.right, ends.right, ends.left)] }
        if !symmetry.isFlipped { options += [(.up, ends.top, ends.bottom), (.down, ends.bottom, ends.top)] }
        // (A shape that turns into itself three times needs a clear point, as a triangle has.)
        let ratio = symmetry.turns == 3 ? 3.0 : 1.6
        let pointed = options.filter { $0.1 < 0.6 && $0.2 >= $0.1 * ratio }
        return pointed.min { $0.1 / max($0.2, 0.01) < $1.1 / max($1.2, 0.01) }?.0 ?? .none
    }

    // MARK: Character

    private func metrics(masks: [PartMask], roles: [LogoProfile.Role]) -> LogoProfile.Metrics {
        var metrics = LogoProfile.Metrics()
        // Roundness and corners, from every part's outlines, walked in steps of a set share of the
        // part's size (so a big part and a small one read alike).
        var curved = 0.0, straight = 0.0, corners = 0
        for i in elements.indices {
            let step = max(3, elements[i].area.squareRoot() * 0.06)
            for outline in allOutlines(i) {
                let (c, s, k) = Self.turning(outline, step: step)
                curved += c; straight += s; corners += k
            }
        }
        metrics.roundness = curved + straight > 0 ? curved / (curved + straight) : 0
        metrics.angularity = Double(corners) / Double(max(elements.count, 1))

        // Line weight and contrast, from the name's letters: their strokes against the height of
        // the tall letters (lowercase letters are short; a stroke is as wide in them).
        let letters = elements.indices.filter { roles[$0] == .wordmark && elements[$0].kind == .letter }
        let heights = letters.map { elements[$0].box.height }.sorted()
        let capHeight = heights.isEmpty ? 1 : heights[heights.count * 9 / 10]
        var weights: [Double] = [], contrasts: [Double] = []
        for i in letters {
            let widths = masks[i].lineWidths()
            guard widths.count >= 4 else { continue }
            let sorted = widths.sorted()
            weights.append(sorted[sorted.count / 2] / max(capHeight, 1))
            // Thick against thin: the wider strokes against the narrower ones.
            let thin = sorted[sorted.count / 4], thick = sorted[sorted.count * 3 / 4]
            contrasts.append(thick > 0 ? (thick - thin) / thick : 0)
        }
        if !weights.isEmpty { metrics.weight = weights.sorted()[weights.count / 2] }
        if !contrasts.isEmpty { metrics.contrast = contrasts.sorted()[contrasts.count / 2] }
        metrics.serif = !letters.isEmpty && metrics.contrast > 0.45

        // Colour: how colourful by area, and how many colours.
        var palette: [SIMD3<Double>] = []
        var chroma = 0.0, area = 0.0
        for element in elements {
            let c = Self.rgb(element.colour)
            chroma += (c.max() - c.min()) * element.area
            area += element.area
            if !palette.contains(where: { (($0 - c) * ($0 - c)).max() < 0.0144 }) { palette.append(c) }
        }
        metrics.saturation = area > 0 ? chroma / area : 0
        metrics.colours = max(palette.count, 1)
        return metrics
    }

    private static func rgb(_ colour: CGColor) -> SIMD3<Double> {
        let v = colour.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
        return SIMD3(v[0], v[min(1, v.count - 1)], v[min(2, v.count - 1)])
    }

    /// Walks an outline in steps: how much of it is curved, how much straight, and its sharp corners.
    private static func turning(_ outline: [CGPoint], step: Double) -> (curved: Double, straight: Double, corners: Int) {
        // Even steps along it.
        var samples: [CGPoint] = []
        let closed = outline + [outline[0]]
        var carry = 0.0
        samples.append(closed[0])
        for (a, b) in zip(closed, closed.dropFirst()) {
            let length = hypot(b.x - a.x, b.y - a.y)
            var at = step - carry
            while at <= length {
                let t = at / max(length, 1e-9)
                samples.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                at += step
            }
            carry = length - (at - step)
        }
        guard samples.count >= 6 else { return (0, 0, 0) }
        var curved = 0.0, straight = 0.0, corners = 0
        var lastCorner = -10
        let count = samples.count
        for i in 0..<count {
            let a = samples[(i - 1 + count) % count], b = samples[i], c = samples[(i + 1) % count]
            let turn = abs(atan2((b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x), (b.x - a.x) * (c.x - b.x) + (b.y - a.y) * (c.y - b.y)))
            let degrees = turn * 180 / .pi
            if degrees > 40 {
                if i - lastCorner > 2 { corners += 1 }
                lastCorner = i
            } else if degrees > 3 {
                curved += step
            } else {
                straight += step
            }
        }
        return (curved, straight, corners)
    }

    /// How well the metrics fit each character (0…1), after the table of brand motion systems:
    /// rounded and colourful is playful, heavy and angular is bold, thin-and-thick or quiet
    /// colour is premium, the rest calm.
    private func personalityScores(_ m: LogoProfile.Metrics) -> [LogoProfile.Personality: Double] {
        func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
        // (No letters, no weight: neither heavy nor light.)
        let heavy = m.weight > 0 ? clamp((m.weight - 0.1) / 0.08) : 0
        let light = m.weight > 0 ? clamp((0.12 - m.weight) / 0.06) : 0
        let colourful = clamp(m.saturation / 0.6)
        let many = clamp(Double(m.colours - 1) / 3)
        let round = clamp((m.roundness - 0.3) / 0.5)
        let angular = clamp(1 - m.roundness / 0.6)
        return [
            .playful: 0.45 * round + 0.35 * colourful + 0.2 * many,
            .bold: 0.5 * heavy + 0.3 * angular + 0.2 * colourful,
            .premium: 0.5 * (m.serif ? 1 : clamp(m.contrast / 0.6)) + 0.3 * (1 - colourful) + 0.2 * light,
            .calm: 0.42,
        ]
    }
}

/// One part's (or a group's) coverage as a small grid of alpha, for symmetry, line widths and tips.
struct PartMask {
    /// Its box in the logo (logo pixels), and the grid's scale (grid cells per logo pixel).
    var box: CGRect
    var scale: Double
    var width: Int
    var height: Int
    var alpha: [UInt8]

    init(box: CGRect, scale: Double, width: Int, height: Int, alpha: [UInt8]) {
        self.box = box; self.scale = scale; self.width = width; self.height = height; self.alpha = alpha
    }

    /// A part's picture at most 160 cells across.
    init(_ element: LogoAnimation.Element) {
        let longest = max(element.box.width, element.box.height)
        scale = min(1, 160 / max(longest, 1))
        box = element.box
        width = max(Int((element.box.width * scale).rounded(.up)), 1)
        height = max(Int((element.box.height * scale).rounded(.up)), 1)
        alpha = PartMask.draw([(element.image, CGRect(x: 0, y: 0, width: Double(width), height: Double(height)))], width: width, height: height)
    }

    private static func draw(_ images: [(CGImage, CGRect)], width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return }
            context.interpolationQuality = .medium
            for (image, rect) in images {
                // Top-left rectangles to the context's bottom-left space.
                context.draw(image, in: CGRect(x: rect.minX, y: Double(height) - rect.maxY, width: rect.width, height: rect.height))
            }
        }
        return bytes
    }

    /// Several parts as one grid (at most 200 cells across).
    static func union(_ masks: [PartMask]) -> PartMask {
        let box = masks.map(\.box).reduce(CGRect.null) { $0.union($1) }
        guard !box.isNull, box.width > 0, box.height > 0 else { return PartMask(box: .zero, scale: 1, width: 1, height: 1, alpha: [0]) }
        let scale = min(1, 200 / max(box.width, box.height))
        let width = max(Int((box.width * scale).rounded(.up)), 1), height = max(Int((box.height * scale).rounded(.up)), 1)
        var alpha = [UInt8](repeating: 0, count: width * height)
        for mask in masks {
            for y in 0..<height {
                let ly = (box.minY + (Double(y) + 0.5) / scale - mask.box.minY) * mask.scale
                guard ly >= 0, Int(ly) < mask.height else { continue }
                for x in 0..<width {
                    let lx = (box.minX + (Double(x) + 0.5) / scale - mask.box.minX) * mask.scale
                    guard lx >= 0, Int(lx) < mask.width else { continue }
                    alpha[y * width + x] = max(alpha[y * width + x], mask.alpha[Int(ly) * mask.width + Int(lx)])
                }
            }
        }
        return PartMask(box: box, scale: scale, width: width, height: height, alpha: alpha)
    }

    private var centroid: (x: Double, y: Double)? {
        var sx = 0.0, sy = 0.0, total = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let a = Double(alpha[y * width + x])
                sx += a * (Double(x) + 0.5); sy += a * (Double(y) + 0.5); total += a
            }
        }
        return total > 0 ? (sx / total, sy / total) : nil
    }

    /// How alike it is to itself mirrored and turned (intersection over union of the coverage).
    func symmetry(turns: Bool = true) -> LogoProfile.Symmetry {
        var result = LogoProfile.Symmetry()
        guard let c = centroid else { return result }
        func overlap(_ map: (Double, Double) -> (Double, Double)) -> Double {
            var inter = 0.0, union = 0.0
            for y in 0..<height {
                for x in 0..<width {
                    let a = Double(alpha[y * width + x])
                    let (sx, sy) = map(Double(x) + 0.5, Double(y) + 0.5)
                    let ix = Int(sx.rounded(.down)), iy = Int(sy.rounded(.down))
                    let b = ix >= 0 && iy >= 0 && ix < width && iy < height ? Double(alpha[iy * width + ix]) : 0
                    inter += min(a, b); union += max(a, b)
                }
            }
            return union > 0 ? inter / union : 0
        }
        result.mirror = overlap { x, y in (2 * c.x - x, y) }
        result.flip = overlap { x, y in (x, 2 * c.y - y) }
        if turns {
            for n in (3...12).reversed() {
                let angle = 2 * Double.pi / Double(n)
                let score = overlap { x, y in
                    let dx = x - c.x, dy = y - c.y
                    return (c.x + dx * cos(angle) - dy * sin(angle), c.y + dx * sin(angle) + dy * cos(angle))
                }
                if score >= 0.89 {
                    // Also alike half a step round: it's round (a circle, a pill), not n-fold.
                    let half = Double.pi / Double(n)
                    let between = overlap { x, y in
                        let dx = x - c.x, dy = y - c.y
                        return (c.x + dx * cos(half) - dy * sin(half), c.y + dx * sin(half) + dy * cos(half))
                    }
                    result.turns = between >= 0.89 ? 0 : n
                    break
                }
            }
        }
        return result
    }

    /// The widths of its lines: twice the distance from the middle of each line to its edges
    /// (the ridge of a distance transform), in logo pixels.
    func lineWidths() -> [Double] {
        let inf = Double(width + height) * 2
        var d = alpha.map { $0 > 127 ? inf : 0 }
        func at(_ x: Int, _ y: Int) -> Double { x < 0 || y < 0 || x >= width || y >= height ? 0 : d[y * width + x] }
        // Two passes of a chamfer distance (1 and √2).
        for y in 0..<height {
            for x in 0..<width where d[y * width + x] > 0 {
                d[y * width + x] = min(d[y * width + x], at(x - 1, y) + 1, at(x, y - 1) + 1, at(x - 1, y - 1) + 1.414, at(x + 1, y - 1) + 1.414)
            }
        }
        for y in (0..<height).reversed() {
            for x in (0..<width).reversed() where d[y * width + x] > 0 {
                d[y * width + x] = min(d[y * width + x], at(x + 1, y) + 1, at(x, y + 1) + 1, at(x + 1, y + 1) + 1.414, at(x - 1, y + 1) + 1.414)
            }
        }
        var widths: [Double] = []
        for y in 0..<height {
            for x in 0..<width {
                let v = d[y * width + x]
                guard v >= 1 else { continue }
                // A ridge: no neighbour further from the edge.
                if v >= at(x - 1, y), v >= at(x + 1, y), v >= at(x, y - 1), v >= at(x, y + 1) {
                    widths.append((2 * v - 1) / scale)
                }
            }
        }
        return widths
    }

    /// How wide it is near each end (the outer eighth on that side), as a share of its full
    /// width across that way: small at a point, large at a flat or round end.
    func endWidths() -> (left: Double, right: Double, top: Double, bottom: Double) {
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height { for x in 0..<width where alpha[y * width + x] > 127 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
        guard maxX > minX, maxY > minY else { return (1, 1, 1, 1) }
        let bandX = max((maxX - minX) / 8, 1), bandY = max((maxY - minY) / 8, 1)
        func spanRows(_ columns: ClosedRange<Int>) -> Double {
            var low = height, high = -1
            for y in minY...maxY { for x in columns where alpha[y * width + x] > 127 { low = min(low, y); high = max(high, y); break } }
            return high >= low ? Double(high - low + 1) / Double(maxY - minY + 1) : 0
        }
        func spanColumns(_ rows: ClosedRange<Int>) -> Double {
            var low = width, high = -1
            for y in rows { for x in minX...maxX where alpha[y * width + x] > 127 { low = min(low, x); high = max(high, x) } }
            return high >= low ? Double(high - low + 1) / Double(maxX - minX + 1) : 0
        }
        return (spanRows(minX...(minX + bandX)), spanRows((maxX - bandX)...maxX), spanColumns(minY...(minY + bandY)), spanColumns((maxY - bandY)...maxY))
    }

    /// Its most pointed tip: the direction from the middle to the furthest point (y down), and how
    /// much further that is than the outline's average.
    func tip() -> (direction: CGPoint, sharpness: Double)? {
        guard let c = centroid else { return nil }
        var edge: [(x: Double, y: Double)] = []
        for y in 0..<height {
            for x in 0..<width where alpha[y * width + x] > 127 {
                let outside = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)].contains { nx, ny in
                    nx < 0 || ny < 0 || nx >= width || ny >= height || alpha[ny * width + nx] <= 127
                }
                if outside { edge.append((Double(x) + 0.5, Double(y) + 0.5)) }
            }
        }
        guard edge.count >= 8 else { return nil }
        let distances = edge.map { hypot($0.x - c.x, $0.y - c.y) }
        let mean = distances.reduce(0, +) / Double(distances.count)
        guard let far = distances.indices.max(by: { distances[$0] < distances[$1] }), mean > 0 else { return nil }
        let length = distances[far]
        return (CGPoint(x: (edge[far].x - c.x) / length, y: (edge[far].y - c.y) / length), length / mean)
    }
}
