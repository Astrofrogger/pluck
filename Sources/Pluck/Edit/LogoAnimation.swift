import Accelerate
import AppKit
import CoreImage
import CoreGraphics
import Foundation
import Vision

/// The logo animator: a logo is taken apart into the shapes it's made of (each letter, each
/// part of the symbol), and those shapes are animated in, smooth and with a little spring, the
/// way a motion designer would: the symbol draws its outline and fills, letters follow one by one,
/// and a soft focus pull brings it home.
struct LogoAnimation: @unchecked Sendable {
    /// One shape of the logo, cut out on its own.
    struct Element {
        /// A plate is a shape other shapes sit on (a badge, a box with letters on it); an accent
        /// is a letter's dot or mark (the dot on an i), which can move on its own.
        enum Kind { case symbol, letter, plate, accent }
        var kind: Kind
        /// The shape's pixels (premultiplied RGBA), cropped to its box.
        var image: CGImage
        /// Its box in the logo (pixels, origin top left).
        var box: CGRect
        /// Its outlines (logo pixels, origin top left), for drawing it on.
        var outlines: [[CGPoint]]
        var colour: CGColor
        /// Softened copies for focus pulls, lightly to strongly blurred, each with the room the
        /// blur spreads into around the shape (logo pixels).
        var blurred: [(image: CGImage, pad: CGFloat)] = []
        /// The plate this shape sits on (an index into `elements`), drawn before it.
        var plate: Int?
        /// For an accent: the letter it belongs to.
        var base: Int?
        /// A small round or star-like shape that can lead the animation (a dot, a full stop, a
        /// sparkle).
        var hero = false
        /// How much ink (logo pixels).
        var area: Double = 0
        /// While analysing: its id, its plate's and its base letter's.
        fileprivate var id = 0, plateID: Int?, baseID: Int?
    }

    enum Style: String, CaseIterable, Identifiable, Sendable {
        case automatic, assemble, bounce, stretch, liquid, lineDraw, elegant, rise, wipe, build, pop, cascade, reveal
        var id: String { rawValue }

        var label: String {
            switch self {
            case .automatic: String(localized: "Automatic")
            case .elegant: String(localized: "Elegant")
            case .rise: String(localized: "Rise")
            case .wipe: String(localized: "Soft Wipe")
            case .build: String(localized: "Build")
            case .pop: String(localized: "Pop")
            case .cascade: String(localized: "Cascade")
            case .reveal: String(localized: "Reveal")
            case .bounce: String(localized: "Bounce")
            case .lineDraw: String(localized: "Line Draw")
            case .stretch: String(localized: "Stretch")
            case .assemble: String(localized: "Assemble")
            case .liquid: String(localized: "Liquid")
            }
        }

        var detail: String {
            switch self {
            case .automatic: String(localized: "Chosen from the logo’s shapes.")
            case .elegant: String(localized: "Each shape fades up out of a soft focus, one after another. Calm and refined.")
            case .rise: String(localized: "The letters rise from behind an invisible line; the symbol grows into focus.")
            case .wipe: String(localized: "A soft-edged reveal moves across the logo, the shapes easing into place behind it.")
            case .build: String(localized: "The symbol draws its outline and fills, then the letters roll in.")
            case .pop: String(localized: "Every shape springs in, from the middle out.")
            case .cascade: String(localized: "Shapes slide in one after another, left to right.")
            case .reveal: String(localized: "A soft wipe reveals the logo, the letters settle into place.")
            case .bounce: String(localized: "The letters bounce in, stretching and squashing as they land; the dot or sparkle lands last.")
            case .lineDraw: String(localized: "A line in the logo’s accent colour runs round every shape, and each fills in behind it.")
            case .stretch: String(localized: "The letters grow out of a line, stretching tall like rubber and springing back, in a wave.")
            case .assemble: String(localized: "In two acts: the symbol, the dot or a line arrives in the middle first, then the whole logo opens out of it.")
            case .liquid: String(localized: "A blob of colour splits into droplets that flow into the letters and become the logo.")
            }
        }
    }

    let logo: CGImage
    let size: CGSize
    let elements: [Element]

    var symbolCount: Int { elements.filter { $0.kind == .symbol }.count }
    /// Boxes and badges other shapes sit on.
    var plateCount: Int { elements.filter { $0.kind == .plate }.count }
    var letterCount: Int { elements.filter { $0.kind == .letter }.count }
    var heroes: [Int] { elements.indices.filter { elements[$0].hero } }

    /// The colour for lines: the hero's, else the logo's second colour, else its main one.
    var accentColour: CGColor {
        func rgb(_ c: CGColor) -> SIMD3<Double> {
            let v = c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
            return SIMD3(v[0], v[min(1, v.count - 1)], v[min(2, v.count - 1)])
        }
        // The hero's, when it's a colour (a white dot's lines would vanish on white).
        if let hero = heroes.first {
            let c = rgb(elements[hero].colour)
            if c.max() - c.min() > 0.15 { return elements[hero].colour }
        }
        // Ink per colour, the main one first.
        var totals: [(colour: CGColor, rgb: SIMD3<Double>, area: Double)] = []
        for element in elements {
            let c = rgb(element.colour)
            if let n = totals.firstIndex(where: { (($0.rgb - c) * ($0.rgb - c)).sum() < 0.04 }) { totals[n].area += element.area }
            else { totals.append((element.colour, c, element.area)) }
        }
        totals.sort { $0.area > $1.area }
        guard let main = totals.first else { return CGColor(gray: 0, alpha: 1) }
        // A second colour with some presence, preferably a colourful one (white or black lines
        // vanish on a white or black background).
        func chroma(_ c: SIMD3<Double>) -> Double { (c.max() - c.min()) }
        let others = totals.dropFirst().filter { $0.area > main.area * 0.03 }
        if let pick = others.max(by: { $0.area * (0.2 + chroma($0.rgb)) < $1.area * (0.2 + chroma($1.rgb)) }),
           chroma(pick.rgb) > 0.15 || chroma(main.rgb) < 0.15 {
            return pick.colour
        }
        return main.colour
    }

    /// What the director chose for `.automatic` (see LogoDirector), when it has looked.
    var directed: Style?

    /// What `.automatic` plays: the director's choice, else one from the logo's layout.
    var suggestedStyle: Style { directed ?? layoutStyle }

    /// A style from the logo's layout alone: anything Assemble can stage (a symbol beside a name, a
    /// hero, a plate) assembles; a plain name bounces; a symbol alone comes into focus.
    var layoutStyle: Style {
        if case .tracking = assembleMode { return letterCount >= 2 ? .bounce : .elegant }
        return .assemble
    }

    struct Failure: LocalizedError {
        var busyBackground = false
        var errorDescription: String? {
            busyBackground
                ? String(localized: "This logo sits on a photo or a pattern: Pluck can’t lift it off cleanly. A version on a plain background (or a PNG, SVG or PDF without one) works best.")
                : String(localized: "Pluck couldn’t find a logo in this picture. Try a PNG or SVG with a transparent or plain background.")
        }
    }

    // MARK: - Analysis

    init(contentsOf url: URL) throws {
        // Pictures are read straight at the working size (a print-size PNG of 10,000 pixels is
        // slow to decode whole); SVG and PDF are drawn sharp at any size.
        let vector = ["svg", "pdf"].contains(url.pathExtension.lowercased())
        if !vector, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: 1400, kCGImageSourceShouldCacheImmediately: true,
           ] as CFDictionary) {
            try self.init(image: NSImage(cgImage: picture, size: NSSize(width: picture.width, height: picture.height)))
            return
        }
        guard let image = NSImage(contentsOf: url) else { throw Failure() }
        try self.init(image: image)
    }

    init(image: NSImage) throws {
        // Rendered at a working size (SVG and PDF logos are drawn sharp at any size).
        let natural = image.size
        guard natural.width > 0, natural.height > 0 else { throw Failure() }
        let scale = 1400 / max(natural.width, natural.height)
        let width = Int(natural.width * scale), height = Int(natural.height * scale)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        // Row 0 of the context's memory is the top of the picture; the analysis works that way round.
        // A logo on a photo or a pattern can't be lifted off: said so, rather than animating
        // the whole picture as if it were the logo.
        guard Self.keyOutBackground(&pixels, width: width, height: height) else { throw Failure(busyBackground: true) }

        // Trim to the ink, with a small margin.
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 24 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX > minX, maxY > minY else { throw Failure() }
        let pad = 8
        minX = max(0, minX - pad); minY = max(0, minY - pad); maxX = min(width - 1, maxX + pad); maxY = min(height - 1, maxY + pad)
        let w = maxX - minX + 1, h = maxY - minY + 1
        var trimmed = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let from = ((y + minY) * width + minX) * 4
            trimmed.replaceSubrange(y * w * 4..<(y + 1) * w * 4, with: pixels[from..<from + w * 4])
        }
        guard let logo = Self.image(trimmed, width: w, height: h) else { throw Failure() }
        let alpha = (0..<(w * h)).map { trimmed[$0 * 4 + 3] }
        self.logo = logo
        self.size = CGSize(width: w, height: h)
        self.elements = Self.elements(trimmed, alpha: alpha, width: w, height: h, logo: logo)
        guard !elements.isEmpty else { throw Failure() }
    }

    /// Logos without transparency (a JPG on white): the background colour, taken from the
    /// border, becomes transparent.
    /// Logos without transparency (a JPG on a colour): the background becomes transparent.
    /// It's worked out as a smooth surface from the picture's edges, so a plain colour, a
    /// gradient or a vignette all come off cleanly (also where the logo touches an edge). Returns
    /// false when the background isn't smooth (a photo, a pattern): that can't be lifted off.
    @discardableResult
    private static func keyOutBackground(_ pixels: inout [UInt8], width: Int, height: Int) -> Bool {
        let count = width * height
        var transparent = 0
        for index in 0..<count where pixels[index * 4 + 3] < 250 { transparent += 1 }
        guard transparent < count / 50 else { return true }
        // The edges of the picture, a few pixels deep.
        var samples: [(x: Double, y: Double, c: SIMD3<Double>)] = []
        let depth = max(2, min(width, height) / 100)
        func sample(_ x: Int, _ y: Int) {
            let i = (y * width + x) * 4
            samples.append((Double(x) / Double(width) * 2 - 1, Double(y) / Double(height) * 2 - 1,
                            SIMD3(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))))
        }
        for d in stride(from: 0, to: depth, by: 2) {
            for x in stride(from: 0, to: width, by: 3) { sample(x, d); sample(x, height - 1 - d) }
            for y in stride(from: 0, to: height, by: 3) { sample(d, y); sample(width - 1 - d, y) }
        }
        // A smooth surface through them (colour as a quadratic in x and y), fitted twice: the
        // second time without edge pixels that belong to the logo.
        func terms(_ x: Double, _ y: Double) -> [Double] { [1, x, y, x * y, x * x, y * y] }
        func fit(_ points: [(x: Double, y: Double, c: SIMD3<Double>)]) -> [SIMD3<Double>]? {
            var a = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6)
            var b = [SIMD3<Double>](repeating: .zero, count: 6)
            for p in points {
                let t = terms(p.x, p.y)
                for i in 0..<6 {
                    b[i] += p.c * t[i]
                    for j in 0..<6 { a[i][j] += t[i] * t[j] }
                }
            }
            for i in 0..<6 { a[i][i] += 1e-6 }
            // Gaussian elimination.
            for col in 0..<6 {
                guard let pivot = (col..<6).max(by: { abs(a[$0][col]) < abs(a[$1][col]) }), abs(a[pivot][col]) > 1e-12 else { return nil }
                a.swapAt(col, pivot); b.swapAt(col, pivot)
                for row in 0..<6 where row != col {
                    let f = a[row][col] / a[col][col]
                    for k in col..<6 { a[row][k] -= f * a[col][k] }
                    b[row] -= b[col] * f
                }
            }
            return (0..<6).map { b[$0] / a[$0][$0] }
        }
        func value(_ w: [SIMD3<Double>], _ x: Double, _ y: Double) -> SIMD3<Double> {
            zip(w, terms(x, y)).reduce(SIMD3<Double>.zero) { $0 + $1.0 * $1.1 }
        }
        func miss(_ w: [SIMD3<Double>], _ p: (x: Double, y: Double, c: SIMD3<Double>)) -> Double {
            let d = value(w, p.x, p.y) - p.c
            return abs(d.x) + abs(d.y) + abs(d.z)
        }
        guard var surface = fit(samples) else { return false }
        for _ in 0..<2 {
            let misses = samples.map { miss(surface, $0) }.sorted()
            let limit = max(30, misses[misses.count / 2] * 3)
            let kept = samples.filter { miss(surface, $0) < limit }
            guard kept.count > samples.count / 2, let refit = fit(kept) else { break }
            surface = refit
        }
        // Smooth enough to be a background (not a photo or a pattern)?
        let misses = samples.map { miss(surface, $0) }.sorted()
        guard misses[misses.count * 3 / 4] < 30 else { return false }
        // How far each pixel is from the background there.
        var distance = [Float](repeating: 0, count: count)
        var background = [SIMD3<Double>](repeating: .zero, count: count)
        for y in 0..<height {
            let ny = Double(y) / Double(height) * 2 - 1
            for x in 0..<width {
                let index = y * width + x, i = index * 4
                let bg = value(surface, Double(x) / Double(width) * 2 - 1, ny)
                background[index] = bg
                distance[index] = Float(abs(Double(pixels[i]) - bg.x) + abs(Double(pixels[i + 1]) - bg.y) + abs(Double(pixels[i + 2]) - bg.z))
            }
        }
        // The solid logo colour nearby is the farthest from the background within a few pixels:
        // an edge pixel halfway to it is half transparent (anti-aliasing, not a colour of its own).
        let reach = 3
        var rows = distance
        for y in 0..<height {
            for x in 0..<width {
                var m: Float = 0
                for dx in max(0, x - reach)...min(width - 1, x + reach) { m = max(m, distance[y * width + dx]) }
                rows[y * width + x] = m
            }
        }
        var solid = rows
        for y in 0..<height {
            for x in 0..<width {
                var m: Float = 0
                for dy in max(0, y - reach)...min(height - 1, y + reach) { m = max(m, rows[dy * width + x]) }
                solid[y * width + x] = m
            }
        }
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x, i = index * 4
                let bg = background[index]
                let d = Double(distance[index])
                let full = max(Double(solid[index]), 114)
                // A soft edge: anti-aliased pixels become partly transparent.
                let a = min(1, max(0, (d - 24) / (full - 24)))
                if a >= 1 { continue }
                if a <= 0 {
                    pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0
                    continue
                }
                // Take the background out of the mixed colour, then premultiply.
                for c in 0..<3 {
                    let straight = min(255, max(0, (Double(pixels[i + c]) - bg[c] * (1 - a)) / a))
                    pixels[i + c] = UInt8(straight * a)
                }
                pixels[i + 3] = UInt8(a * 255)
            }
        }
        return true
    }

    /// The logo's separate shapes: connected areas of ink. Specks (the dot on an i) join the
    /// nearest shape; shapes inside recognised text are letters, the rest is the symbol.
    private static func elements(_ pixels: [UInt8], alpha: [UInt8], width: Int, height: Int, logo: CGImage) -> [Element] {
        // Connected components, 8-connected, by union–find.
        var parent = [Int32](repeating: -1, count: width * height)
        func find(_ i: Int32) -> Int32 {
            var i = i
            while parent[Int(i)] != i { parent[Int(i)] = parent[Int(parent[Int(i)])]; i = parent[Int(i)] }
            return i
        }
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                guard alpha[i] > 100 else { continue }
                parent[i] = Int32(i)
                for (dx, dy) in [(-1, 0), (-1, -1), (0, -1), (1, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0 else { continue }
                    let j = ny * width + nx
                    if parent[j] >= 0 {
                        let a = find(Int32(i)), b = find(Int32(j))
                        if a != b { parent[Int(max(a, b))] = min(a, b) }
                    }
                }
            }
        }
        var labels = [Int32](repeating: -1, count: width * height)
        var boxes: [Int32: (minX: Int, minY: Int, maxX: Int, maxY: Int, area: Int)] = [:]
        for i in 0..<(width * height) where parent[i] >= 0 {
            let root = find(Int32(i))
            labels[i] = root
            let x = i % width, y = i / width
            if let b = boxes[root] {
                boxes[root] = (min(b.minX, x), min(b.minY, y), max(b.maxX, x), max(b.maxY, y), b.area + 1)
            } else {
                boxes[root] = (x, y, x, y, 1)
            }
        }
        guard !boxes.isEmpty else { return [] }
        let totalInk = boxes.values.reduce(0) { $0 + $1.area }

        // Specks join the nearest bigger shape.
        var owner: [Int32: Int32] = [:]
        // (Relative to the logo's size, not its ink: a big box mustn't turn a line of small text
        // into specks.)
        let speck = max(6.0, Double(width * height) * 0.00012)
        let big = boxes.filter { Double($0.value.area) >= speck }
        for (root, box) in boxes {
            if big[root] != nil || big.isEmpty { owner[root] = root; continue }
            let cx = Double(box.minX + box.maxX) / 2, cy = Double(box.minY + box.maxY) / 2
            let nearest = big.min { a, b in
                func distance(_ v: (minX: Int, minY: Int, maxX: Int, maxY: Int, area: Int)) -> Double {
                    let dx = max(Double(v.minX) - cx, 0, cx - Double(v.maxX)), dy = max(Double(v.minY) - cy, 0, cy - Double(v.maxY))
                    return dx * dx + dy * dy
                }
                return distance(a.value) < distance(b.value)
            }!
            owner[root] = nearest.key
        }
        var groups: [Int32: (minX: Int, minY: Int, maxX: Int, maxY: Int, area: Int)] = [:]
        for (root, box) in boxes {
            let target = owner[root]!
            if let b = groups[target] {
                groups[target] = (min(b.minX, box.minX), min(b.minY, box.minY), max(b.maxX, box.maxX), max(b.maxY, box.maxY), b.area + box.area)
            } else {
                groups[target] = box
            }
        }
        // Dots and accents (the dot on an i, an umlaut) belong to the letter under or over them,
        // but stay shapes of their own: they can lead the animation.
        let areas = groups.values.map(\.area).sorted()
        let typicalArea = areas[areas.count / 2]
        var accentOf: [Int32: Int32] = [:]
        for (key, box) in groups where box.area < typicalArea * 3 / 10 {
            let centre = (box.minX + box.maxX) / 2, height = box.maxY - box.minY + 1
            let base = groups.filter { other in
                other.key != key && other.value.area > box.area && centre >= other.value.minX && centre <= other.value.maxX
                    && min(abs(other.value.minY - box.maxY), abs(box.minY - other.value.maxY)) < height * 3 / 2
            }.min { $0.value.area < $1.value.area }
            if let base { accentOf[key] = base.key }
        }
        // Too many pieces (a detailed illustration): animate it as one.
        let illustration = groups.count > 60
        if illustration {
            let all = groups.values
            groups = [0: (all.map(\.minX).min()!, all.map(\.minY).min()!, all.map(\.maxX).max()!, all.map(\.maxY).max()!, totalInk)]
            for (root, _) in owner { owner[root] = 0 }
        }

        // Text in the logo, from the on-device text recogniser.
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: logo).perform([request])
        let textBoxes = (request.results ?? []).map { observation -> CGRect in
            let b = observation.boundingBox
            return CGRect(x: b.minX * Double(width), y: (1 - b.maxY) * Double(height), width: b.width * Double(width), height: b.height * Double(height))
        }

        var result: [Element] = []
        var nextID = 0
        var idOfGroup: [Int32: Int] = [:]
        for (key, box) in groups.sorted(by: { $0.key < $1.key }) {
            let rect = CGRect(x: box.minX, y: box.minY, width: box.maxX - box.minX + 1, height: box.maxY - box.minY + 1)
            let w = Int(rect.width), h = Int(rect.height)
            var cut = [UInt8](repeating: 0, count: w * h * 4)
            var shape = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    let i = (y + box.minY) * width + x + box.minX
                    let label = labels[i]
                    // Its own pixels, plus the soft edge around them (not another shape's).
                    let mine = label >= 0 ? owner[label] == key : alpha[i] > 0 && nearestOwner(labels, owner, x + box.minX, y + box.minY, width, height) == key
                    guard mine else { continue }
                    let o = (y * w + x) * 4
                    for c in 0..<4 { cut[o + c] = pixels[i * 4 + c] }
                    shape[y * w + x] = alpha[i]
                }
            }
            func inText(_ r: CGRect) -> Bool {
                textBoxes.contains { $0.insetBy(dx: -4, dy: -4).contains(CGPoint(x: r.midX, y: r.midY)) }
            }
            // A shape in several colours is taken apart: a box with letters on it becomes the
            // box (a plate) and its letters; a symbol in several colours (a sun over a mountain)
            // becomes its parts, each moving on its own.
            let pieces = illustration ? [(cut: cut, shape: shape, box: CGRect(x: 0, y: 0, width: w, height: h), isPlate: false, container: Int?.none)]
                : Self.layers(cut, shape: shape, width: w, height: h)
            let firstID = nextID
            for piece in pieces {
                let id = nextID
                nextID += 1
                let pieceBox = piece.box.offsetBy(dx: rect.minX, dy: rect.minY)
                let kind: Element.Kind = piece.isPlate ? .plate : (inText(pieceBox) ? .letter : .symbol)
                guard var element = Self.element(piece.cut, shape: piece.shape, width: w, height: h, origin: rect.origin, kind: kind)
                else { continue }
                element.id = id
                element.plateID = piece.container.map { firstID + $0 }
                result.append(element)
            }
            if pieces.count == 1 { idOfGroup[key] = firstID }
        }
        // Accents point at their letter.
        for (accent, base) in accentOf {
            guard let id = idOfGroup[accent], let baseID = idOfGroup[base],
                  let n = result.firstIndex(where: { $0.id == id }), let b = result.firstIndex(where: { $0.id == baseID }) else { continue }
            if result[b].kind == .letter || result[b].kind == .symbol {
                result[n].kind = .accent
                result[n].baseID = baseID
            }
        }
        // No text found but many similar shapes in a row: probably a wordmark the recogniser
        // couldn't read (a custom font); treat them as letters.
        if textBoxes.isEmpty, result.filter({ $0.kind == .symbol }).count >= 3 {
            let heights = result.filter { $0.kind == .symbol }.map(\.box.height).sorted()
            let typical = heights[heights.count / 2]
            // Shapes about letter height are letters; much taller ones stay the symbol.
            for i in result.indices where result[i].kind == .symbol && result[i].box.height < typical * 1.6 && result[i].box.height > typical * 0.5 {
                result[i].kind = .letter
            }
        }
        // A shape the twin of a symbol (one of three sparkles, near the text) is a symbol too.
        let symbolSizes = result.filter { $0.kind == .symbol }.map { ($0.box.size, $0.area) }
        for i in result.indices where result[i].kind == .letter {
            if symbolSizes.contains(where: { abs($0.0.width - result[i].box.width) <= 2 && abs($0.0.height - result[i].box.height) <= 2
                                            && abs($0.1 - result[i].area) < $0.1 * 0.05 }) {
                result[i].kind = .symbol
            }
        }
        // Order: plates (biggest first), the symbol's shapes (biggest first), then the letters
        // line by line, left to right, each followed by its dot.
        func bySize(_ a: Element, _ b: Element) -> Bool { a.box.width * a.box.height > b.box.width * b.box.height }
        let plates = result.filter { $0.kind == .plate }.sorted(by: bySize)
        let symbols = result.filter { $0.kind == .symbol }.sorted(by: bySize)
        let accents = result.filter { $0.kind == .accent }
        var letters = result.filter { $0.kind == .letter }.sorted { $0.box.midY < $1.box.midY }
        if !letters.isEmpty {
            let typical = letters.map(\.box.height).sorted()[letters.count / 2]
            var lines: [[Element]] = [[letters[0]]]
            for letter in letters.dropFirst() {
                if letter.box.midY - lines[lines.count - 1].map(\.box.midY).reduce(0, +) / Double(lines[lines.count - 1].count) > typical * 0.8 {
                    lines.append([letter])
                } else {
                    lines[lines.count - 1].append(letter)
                }
            }
            letters = lines.flatMap { $0.sorted { $0.box.minX < $1.box.minX } }
        }
        var ordered = plates + symbols
        for letter in letters {
            ordered.append(letter)
            ordered += accents.filter { $0.baseID == letter.id }
        }
        ordered += accents.filter { accent in !ordered.contains { $0.id == accent.id } }
        // Links by position.
        let position = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1.id, $0) })
        for i in ordered.indices {
            ordered[i].plate = ordered[i].plateID.flatMap { position[$0] }
            ordered[i].base = ordered[i].baseID.flatMap { position[$0] }
        }
        markHeroes(&ordered)
        return ordered
    }

    /// Heroes: dots and marks (the dot on an i, a full stop, a sparkle), small next to the
    /// letters and compact (round or star-like). At most three.
    private static func markHeroes(_ elements: inout [Element]) {
        // Compared with the main letters (the tagline's small letters don't count).
        let letters = elements.filter { $0.kind == .letter }
        let tallest = letters.map(\.box.height).max() ?? 0
        let main = letters.filter { $0.box.height > tallest * 0.6 }.map(\.area).sorted()
        let typical = main.isEmpty ? (elements.map(\.area).max() ?? 1) : main[main.count / 2]
        let candidates = elements.indices.filter { i in
            let e = elements[i]
            switch e.kind {
            case .plate: return false
            case .letter:
                // A full stop: small next to the letters of its own line.
                let line = letters.filter { $0.box.minY < e.box.maxY && $0.box.maxY > e.box.minY && $0.box != e.box }.map(\.area).sorted()
                guard !line.isEmpty, e.area < line[line.count / 2] * 0.3 else { return false }
            case .accent, .symbol: guard e.area < typical * 0.9 else { return false }
            }
            let aspect = e.box.width / max(e.box.height, 1)
            let fill = e.area / max(e.box.width * e.box.height, 1)
            return aspect > 0.6 && aspect < 1.65 && fill > 0.2 && e.box.width > 3
        }
        // Dots on letters first, then the rest, smallest last.
        let ranked = candidates.sorted { a, b in
            let accentA = elements[a].kind == .accent, accentB = elements[b].kind == .accent
            return accentA != accentB ? accentA : elements[a].area > elements[b].area
        }
        // Many small dots (a row of i's, a dotted pattern) aren't heroes.
        guard !ranked.isEmpty, ranked.count <= 4 else { return }
        for i in ranked.prefix(3) { elements[i].hero = true }
    }

    /// A shape split into the shapes it's built from: by colour, then into connected pieces.
    /// A piece that encloses others is a plate (its holes filled with its colour, so whatever
    /// sits on it can move away); `container` is the index of the plate a piece sits on.
    private static func layers(_ cut: [UInt8], shape: [UInt8], width w: Int, height h: Int)
        -> [(cut: [UInt8], shape: [UInt8], box: CGRect, isPlate: Bool, container: Int?)] {
        let whole = [(cut: cut, shape: shape, box: CGRect(x: 0, y: 0, width: w, height: h), isPlate: false, container: Int?.none)]
        guard let parts = colourParts(cut, shape: shape, width: w, height: h) else { return whole }
        let total = shape.reduce(0) { $0 + ($1 > 100 ? 1 : 0) }
        // Connected pieces of each colour.
        var pieces: [(cut: [UInt8], shape: [UInt8], mask: [Bool], area: Int, box: (Int, Int, Int, Int))] = []
        for part in parts {
            var label = [Int32](repeating: -1, count: w * h)
            var count: Int32 = 0
            for start in 0..<(w * h) where part.1[start] > 100 && label[start] < 0 {
                var stack = [start]
                label[start] = count
                while let i = stack.popLast() {
                    let x = i % w, y = i / w
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                        let j = ny * w + nx
                        if label[j] < 0, part.1[j] > 100 { label[j] = count; stack.append(j) }
                    }
                }
                count += 1
            }
            guard count > 0 else { continue }
            var made = (0..<Int(count)).map { _ in ([UInt8](repeating: 0, count: w * h * 4), [UInt8](repeating: 0, count: w * h),
                                                    [Bool](repeating: false, count: w * h), 0, (w, h, -1, -1)) }
            for i in 0..<(w * h) where part.1[i] > 0 {
                // Soft edge pixels go to the piece next to them.
                var l = label[i]
                if l < 0 {
                    let x = i % w, y = i / w
                    search: for r in 1...2 {
                        for dy in -r...r { for dx in -r...r {
                            let nx = x + dx, ny = y + dy
                            if nx >= 0, ny >= 0, nx < w, ny < h, label[ny * w + nx] >= 0 { l = label[ny * w + nx]; break search }
                        } }
                    }
                }
                guard l >= 0 else { continue }
                let n = Int(l)
                for c in 0..<4 { made[n].0[i * 4 + c] = part.0[i * 4 + c] }
                made[n].1[i] = part.1[i]
                if label[i] >= 0 {
                    made[n].2[i] = true
                    made[n].3 += 1
                    let x = i % w, y = i / w
                    made[n].4 = (min(made[n].4.0, x), min(made[n].4.1, y), max(made[n].4.2, x), max(made[n].4.3, y))
                }
            }
            pieces += made.map { (cut: $0.0, shape: $0.1, mask: $0.2, area: $0.3, box: $0.4) }
        }
        // Slivers (left over where two colours meet) join the piece around or next to them.
        let minimum = max(12, w * h / 8000)
        var kept = pieces.filter { $0.area >= minimum }
        guard kept.count >= 2 else { return whole }
        for sliver in pieces where sliver.area < minimum {
            let cx = (sliver.box.0 + sliver.box.2) / 2, cy = (sliver.box.1 + sliver.box.3) / 2
            guard let n = kept.indices.min(by: { a, b in
                func d(_ p: (Int, Int, Int, Int)) -> Int { max(p.0 - cx, 0, cx - p.2) + max(p.1 - cy, 0, cy - p.3) }
                return d(kept[a].box) < d(kept[b].box)
            }) else { continue }
            // (Taken out, changed and put back: changing it in place copies it every pixel.)
            // Only around the sliver (with its soft edge), not the whole shape.
            var target = kept[n]
            for y in max(sliver.box.1 - 2, 0)...min(sliver.box.3 + 2, h - 1) {
                for x in max(sliver.box.0 - 2, 0)...min(sliver.box.2 + 2, w - 1) {
                    let i = y * w + x
                    guard sliver.shape[i] > 0, target.shape[i] == 0 else { continue }
                    for c in 0..<4 { target.cut[i * 4 + c] = sliver.cut[i * 4 + c] }
                    target.shape[i] = sliver.shape[i]
                }
            }
            kept[n] = target
        }
        // Each big piece's filled shape: everything inside its outer edge.
        func filled(_ piece: (cut: [UInt8], shape: [UInt8], mask: [Bool], area: Int, box: (Int, Int, Int, Int))) -> [Bool] {
            let (x0, y0, x1, y1) = piece.box
            var outside = [Bool](repeating: false, count: w * h)
            var stack: [Int] = []
            for x in x0...x1 { stack.append(y0 * w + x); stack.append(y1 * w + x) }
            for y in y0...y1 { stack.append(y * w + x0); stack.append(y * w + x1) }
            stack = stack.filter { !piece.mask[$0] }
            for i in stack { outside[i] = true }
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= x0, ny >= y0, nx <= x1, ny <= y1 else { continue }
                    let j = ny * w + nx
                    if !outside[j], !piece.mask[j] { outside[j] = true; stack.append(j) }
                }
            }
            var inside = [Bool](repeating: false, count: w * h)
            for y in y0...y1 { for x in x0...x1 { let i = y * w + x; inside[i] = !outside[i] } }
            return inside
        }
        let insides = kept.map { $0.area >= total / 20 ? filled($0) : [] }
        let filledArea = insides.map { $0.reduce(0) { $0 + ($1 ? 1 : 0) } }
        var container = [Int?](repeating: nil, count: kept.count)
        for (c, piece) in kept.enumerated() {
            let cx = (piece.box.0 + piece.box.2) / 2, cy = (piece.box.1 + piece.box.3) / 2
            container[c] = kept.indices.filter { b in
                b != c && !insides[b].isEmpty && insides[b][cy * w + cx] && filledArea[b] > piece.area * 2
            }.min { filledArea[$0] < filledArea[$1] }
        }
        var isPlate = kept.indices.map { b in container.contains(b) }
        // Pieces inside one letter belong to it (the hole of an R in the plate's colour, a
        // figure cut into an A): pieces on the same plate whose boxes overlap become one.
        func overlap(_ a: (Int, Int, Int, Int), _ b: (Int, Int, Int, Int)) -> Double {
            let ix = max(0, min(a.2, b.2) - max(a.0, b.0) + 1), iy = max(0, min(a.3, b.3) - max(a.1, b.1) + 1)
            let smaller = min((a.2 - a.0 + 1) * (a.3 - a.1 + 1), (b.2 - b.0 + 1) * (b.3 - b.1 + 1))
            return Double(ix * iy) / Double(max(smaller, 1))
        }
        // (The boxes on their own: comparing whole pieces would copy their pixels every time.)
        var boxes = kept.map(\.box)
        var merged = true
        while merged {
            merged = false
            outer: for a in kept.indices where !isPlate[a] {
                for b in kept.indices where b != a && !isPlate[b] && container[a] == container[b] && overlap(boxes[a], boxes[b]) > 0.3 {
                    // b into a (taken out, changed and put back).
                    var into = kept[a]
                    let from = kept[b]
                    for i in 0..<(w * h) where from.shape[i] > 0 {
                        for c in 0..<4 { into.cut[i * 4 + c] = from.cut[i * 4 + c] }
                        into.shape[i] = max(into.shape[i], from.shape[i])
                        if from.mask[i] { into.mask[i] = true }
                    }
                    into.area += from.area
                    into.box = (min(into.box.0, from.box.0), min(into.box.1, from.box.1),
                                max(into.box.2, from.box.2), max(into.box.3, from.box.3))
                    kept[a] = into
                    boxes[a] = kept[a].box
                    kept.remove(at: b)
                    boxes.remove(at: b)
                    container.remove(at: b)
                    isPlate.remove(at: b)
                    container = container.map { $0.map { $0 > b ? $0 - 1 : $0 } }
                    merged = true
                    break outer
                }
            }
        }
        let insidesAfter = kept.indices.map { isPlate[$0] ? filled(kept[$0]) : [] }
        // Nothing sits on anything: a symbol in several colours, each part on its own.
        guard isPlate.contains(true) else {
            return kept.map { piece in
                (cut: piece.cut, shape: piece.shape,
                 box: CGRect(x: piece.box.0, y: piece.box.1, width: piece.box.2 - piece.box.0 + 1, height: piece.box.3 - piece.box.1 + 1),
                 isPlate: false, container: nil)
            }
        }
        return kept.indices.map { n in
            var piece = kept[n]
            if isPlate[n] {
                // The plate whole: its holes filled with its own colour.
                var colour = SIMD4<Double>.zero
                for i in 0..<(w * h) where piece.mask[i] && piece.shape[i] > 200 {
                    colour += SIMD4(Double(piece.cut[i * 4]), Double(piece.cut[i * 4 + 1]), Double(piece.cut[i * 4 + 2]), 1)
                }
                let mean = colour.w > 0 ? colour / colour.w : SIMD4(0, 0, 0, 1)
                // Solid inside; only the outer edge keeps its soft (anti-aliased) pixels.
                let inside = insidesAfter[n]
                for i in 0..<(w * h) where inside[i] {
                    let x = i % w, y = i / w
                    let edge = x == 0 || y == 0 || x == w - 1 || y == h - 1 || !inside[i - 1] || !inside[i + 1] || !inside[i - w] || !inside[i + w]
                    let a = edge ? Double(piece.shape[i]) / 255 : 1
                    piece.cut[i * 4] = UInt8(mean.x * a); piece.cut[i * 4 + 1] = UInt8(mean.y * a); piece.cut[i * 4 + 2] = UInt8(mean.z * a)
                    piece.cut[i * 4 + 3] = UInt8(a * 255)
                    piece.shape[i] = UInt8(a * 255)
                }
            }
            let box = CGRect(x: piece.box.0, y: piece.box.1, width: piece.box.2 - piece.box.0 + 1, height: piece.box.3 - piece.box.1 + 1)
            return (cut: piece.cut, shape: piece.shape, box: box, isPlate: isPlate[n], container: container[n])
        }
    }

    /// One element from a cut-out (logo-sized box at `origin`), cropped to its own pixels.
    private static func element(_ cut: [UInt8], shape: [UInt8], width w: Int, height h: Int, origin: CGPoint, kind: Element.Kind) -> Element? {
        var minX = w, minY = h, maxX = -1, maxY = -1
        // Its colour: the most common one (an average would mix in a second colour).
        var bins: [SIMD3<Int>: (count: Int, sum: SIMD3<Double>)] = [:]
        for y in 0..<h {
            for x in 0..<w where shape[y * w + x] > 0 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                let i = (y * w + x) * 4
                if shape[y * w + x] > 200 {
                    let c = SIMD3(Double(cut[i]), Double(cut[i + 1]), Double(cut[i + 2]))
                    let key = SIMD3(Int(c.x) / 20, Int(c.y) / 20, Int(c.z) / 20)
                    let bin = bins[key] ?? (0, .zero)
                    bins[key] = (bin.count + 1, bin.sum + c)
                }
            }
        }
        let common = bins.values.max { $0.count < $1.count }
        let colour = common.map { SIMD4($0.sum.x, $0.sum.y, $0.sum.z, Double($0.count)) } ?? .zero
        guard maxX >= minX, maxY >= minY else { return nil }
        let cw = maxX - minX + 1, ch = maxY - minY + 1
        var pixels = [UInt8](repeating: 0, count: cw * ch * 4)
        var alpha = [UInt8](repeating: 0, count: cw * ch)
        for y in 0..<ch {
            for x in 0..<cw {
                let from = (y + minY) * w + x + minX
                for c in 0..<4 { pixels[(y * cw + x) * 4 + c] = cut[from * 4 + c] }
                alpha[y * cw + x] = shape[from]
            }
        }
        guard let image = image(pixels, width: cw, height: ch) else { return nil }
        let mean = colour.w > 0 ? colour / colour.w : SIMD4(128, 128, 128, 1)
        let box = CGRect(x: origin.x + Double(minX), y: origin.y + Double(minY), width: Double(cw), height: Double(ch))
        var element = Element(kind: kind, image: image, box: box, outlines: outlines(alpha, width: cw, height: ch, offset: box.origin),
                              colour: CGColor(srgbRed: mean.x / 255, green: mean.y / 255, blue: mean.z / 255, alpha: 1),
                              blurred: softened(image))
        element.area = Double(alpha.reduce(0) { $0 + Int($1) }) / 255
        return element
    }

    private static let imageContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    /// Blurred copies of a shape, for drawing it out of focus.
    private static func softened(_ image: CGImage) -> [(image: CGImage, pad: CGFloat)] {
        let source = CIImage(cgImage: image)
        return [3.0, 8.0, 18.0].compactMap { radius in
            let pad = radius * 3
            let area = source.extent.insetBy(dx: -pad, dy: -pad)
            guard let blurred = imageContext.createCGImage(source.applyingGaussianBlur(sigma: radius).cropped(to: area), from: area)
            else { return nil }
            return (blurred, pad)
        }
    }

    /// Splits a shape by colour when it's clearly made of several (each at least a twentieth of
    /// it and well apart in colour). Nil when it's one colour.
    private static func colourParts(_ cut: [UInt8], shape: [UInt8], width w: Int, height h: Int) -> [([UInt8], [UInt8])]? {
        // The colours inside the shape only: edge pixels are blends (anti-aliasing, a JPG's
        // compression), not colours of their own; they go to the nearest real one below.
        var colours: [SIMD3<Double>] = []
        func solid(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && shape[y * w + x] > 200 }
        for y in 0..<h {
            for x in 0..<w where solid(x, y) && solid(x - 2, y) && solid(x + 2, y) && solid(x, y - 2) && solid(x, y + 2) {
                let i = y * w + x
                let a = Double(cut[i * 4 + 3]) / 255
                colours.append(SIMD3(Double(cut[i * 4]), Double(cut[i * 4 + 1]), Double(cut[i * 4 + 2])) / max(a, 0.01))
            }
        }
        guard colours.count > 400 else { return nil }
        func distance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { ((a - b) * (a - b)).sum().squareRoot() }
        // The main colours: well-filled bins of a coarse colour histogram (edge blends between
        // two colours are too few to count), each well apart from the others.
        var bins: [SIMD3<Int>: (count: Int, sum: SIMD3<Double>)] = [:]
        for c in colours {
            let key = SIMD3(Int(c.x) / 24, Int(c.y) / 24, Int(c.z) / 24)
            let bin = bins[key] ?? (0, .zero)
            bins[key] = (bin.count + 1, bin.sum + c)
        }
        var centres: [SIMD3<Double>] = []
        for bin in bins.values.sorted(by: { $0.count > $1.count }) where bin.count >= max(colours.count / 120, 60) {
            let mean = bin.sum / Double(bin.count)
            if centres.allSatisfy({ distance($0, mean) > 70 }) { centres.append(mean) }
            if centres.count == 6 { break }
        }
        guard centres.count >= 2 else { return nil }
        var parts = centres.map { _ in ([UInt8](repeating: 0, count: w * h * 4), [UInt8](repeating: 0, count: w * h)) }
        for i in 0..<(w * h) where shape[i] > 0 {
            let a = Double(cut[i * 4 + 3]) / 255
            let c = SIMD3(Double(cut[i * 4]), Double(cut[i * 4 + 1]), Double(cut[i * 4 + 2])) / max(a, 0.01)
            let n = centres.indices.min { distance(centres[$0], c) < distance(centres[$1], c) }!
            for ch in 0..<4 { parts[n].0[i * 4 + ch] = cut[i * 4 + ch] }
            parts[n].1[i] = shape[i]
        }
        return parts
    }

    private static func nearestOwner(_ labels: [Int32], _ owner: [Int32: Int32], _ x: Int, _ y: Int, _ width: Int, _ height: Int) -> Int32? {
        for radius in 1...3 {
            for dy in -radius...radius {
                for dx in -radius...radius {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                    let label = labels[ny * width + nx]
                    if label >= 0 { return owner[label] }
                }
            }
        }
        return nil
    }

    /// A shape's outlines (outer edge and holes), from Vision's contour detection.
    private static func outlines(_ shape: [UInt8], width: Int, height: Int, offset: CGPoint) -> [[CGPoint]] {
        guard width > 2, height > 2, let image = greyImage(shape, width: width, height: height) else { return [] }
        let request = VNDetectContoursRequest()
        request.detectsDarkOnLight = false
        request.contrastAdjustment = 1
        request.maximumImageDimension = 512
        try? VNImageRequestHandler(cgImage: image).perform([request])
        guard let observation = request.results?.first else { return [] }
        var result: [[CGPoint]] = []
        func add(_ contour: VNContour) {
            let points = contour.normalizedPoints.map {
                CGPoint(x: offset.x + Double($0.x) * Double(width), y: offset.y + (1 - Double($0.y)) * Double(height))
            }
            if points.count > 4 { result.append(points) }
            for child in contour.childContours { add(child) }
        }
        for contour in observation.topLevelContours { add(contour) }
        return result
    }

    private static func image(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func greyImage(_ values: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(values) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: - Timing

    /// When each element starts and how long its entrance takes (seconds).
    func timing(_ style: Style) -> [(start: Double, length: Double)] {
        let style = style == .automatic ? suggestedStyle : style
        if style == .assemble || style == .liquid { return buildTiming(style) }
        if Self.expressive.contains(style) { return expressiveTiming(style) }
        let symbols = elements.indices.filter { elements[$0].kind == .symbol || elements[$0].kind == .plate }
        let letters = elements.indices.filter { elements[$0].kind == .letter }
        var result = [(start: Double, length: Double)](repeating: (0, 0.7), count: elements.count)
        // Letters together take about half a second to start, however many there are.
        let letterStep = letters.count > 1 ? min(0.07, 0.55 / Double(letters.count - 1)) : 0
        switch style {
        case .elegant:
            for (n, i) in symbols.enumerated() { result[i] = (Double(n) * 0.15, 1.3) }
            let after = symbols.isEmpty ? 0 : 0.4 + Double(symbols.count - 1) * 0.15
            let step = letters.count > 1 ? min(0.05, 0.5 / Double(letters.count - 1)) : 0
            for (n, i) in letters.enumerated() { result[i] = (after + Double(n) * step, 1.1) }
        case .rise:
            for (n, i) in symbols.enumerated() { result[i] = (Double(n) * 0.1, 1.1) }
            let after = symbols.isEmpty ? 0 : 0.35 + Double(symbols.count - 1) * 0.1
            let step = letters.count > 1 ? min(0.045, 0.45 / Double(letters.count - 1)) : 0
            for (n, i) in letters.enumerated() { result[i] = (after + Double(n) * step, 0.85) }
        case .wipe:
            // Each shape settles as the edge passes it.
            for i in elements.indices { result[i] = (elements[i].box.midX / size.width * Self.wipeLength * 0.85 - 0.1, 0.9) }
        case .build, .automatic:
            for (n, i) in symbols.enumerated() { result[i] = (Double(n) * 0.12, 1.1) }
            let after = symbols.isEmpty ? 0 : 0.75 + Double(symbols.count - 1) * 0.12
            for (n, i) in letters.enumerated() { result[i] = (after + Double(n) * letterStep, 0.7) }
        case .pop:
            // From the middle out.
            let centre = size.width / 2
            let order = elements.indices.sorted { abs(elements[$0].box.midX - centre) < abs(elements[$1].box.midX - centre) }
            let step = min(0.08, 0.7 / Double(max(order.count - 1, 1)))
            for (n, i) in order.enumerated() { result[i] = (Double(n) * step, 0.75) }
        case .cascade:
            let order = elements.indices.sorted { elements[$0].box.minX < elements[$1].box.minX }
            let step = min(0.08, 0.7 / Double(max(order.count - 1, 1)))
            for (n, i) in order.enumerated() { result[i] = (Double(n) * step, 0.8) }
        case .reveal:
            for i in elements.indices { result[i] = (elements[i].box.minX / size.width * 0.6, 0.9) }
        case .lineDraw, .bounce, .stretch, .assemble, .liquid:
            break
        }
        // A dot moves with its letter.
        for i in elements.indices { if let base = elements[i].base { result[i] = result[base] } }
        return result
    }

    /// When everything has landed.
    func settled(_ style: Style) -> Double {
        timing(style).map { $0.start + $0.length }.max() ?? 1
    }

    /// The animation with a hold on the finished logo.
    func duration(_ style: Style) -> Double { settled(style) + 1.2 }

    // MARK: - Outro and length

    /// How the logo leaves at the end.
    enum Outro: String, CaseIterable, Identifiable, Sendable {
        case none, reverse, fade
        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: String(localized: "None")
            case .reverse: String(localized: "Reverse of the intro")
            case .fade: String(localized: "Fade out")
            }
        }
    }

    /// The whole video in time: intro, hold and outro. When the chosen length is shorter than
    /// the moves need, intro and outro are sped up together so everything fits.
    struct Plan: Sendable {
        var style: Style
        var outro: Outro
        /// The video's length.
        var total: Double
        /// How much faster than normal the moves play (1 = as designed).
        var speed: Double
        /// The intro as it plays (seconds).
        var intro: Double
        /// The outro as it plays, at the end of the video.
        var outroLength: Double
        var outroStart: Double { total - outroLength }
    }

    /// The outro's natural length: a reversed intro is a little quicker than the intro.
    private func naturalOutro(_ style: Style, _ outro: Outro) -> Double {
        switch outro {
        case .none: 0
        case .reverse: settled(style) * 0.75
        case .fade: 0.7
        }
    }

    /// The plan for a video of `length` seconds (nil: the natural length).
    func plan(_ style: Style, outro: Outro, length: Double? = nil) -> Plan {
        let intro = settled(style), out = naturalOutro(style, outro)
        let hold = outro == .none ? 1.2 : 1.6
        let natural = intro + hold + out
        let total = max(length ?? natural, 1)
        // Keep at least a short hold on the finished logo; squeeze the moves if needed.
        let minimumHold = min(0.5, total * 0.2)
        let speed = max(1, (intro + out) / max(total - minimumHold, 0.3))
        return Plan(style: style, outro: outro, total: total, speed: speed, intro: intro / speed, outroLength: out / speed)
    }

    /// Draws the frame at video time `t` of a plan: the intro (sped up if needed), the hold, and
    /// the outro (the intro played backwards, or a fade).
    func draw(at t: Double, plan: Plan, in context: CGContext, canvas: CGSize) {
        let settledAt = settled(plan.style)
        var moment = min(t * plan.speed, settledAt + 10)
        var alpha = 1.0
        if plan.outroLength > 0, t > plan.outroStart {
            let p = min(max((t - plan.outroStart) / plan.outroLength, 0), 1)
            switch plan.outro {
            case .none: break
            case .reverse:
                // Back through the intro, from the finished logo to nothing, eased at the start.
                moment = settledAt * (1 - Easing.inOutCubic(p))
            case .fade:
                moment = settledAt
                alpha = 1 - Easing.inOutCubic(p)
            }
        } else if t * plan.speed >= settledAt {
            moment = settledAt
        }
        guard alpha > 0.001 else { return }
        // Settled: the logo itself, exactly as in the file (shapes drawn one by one round their
        // soft edges very slightly differently).
        func frame(_ moment: Double) {
            if moment >= settledAt { context.draw(logo, in: logoRect(canvas: canvas)) }
            else { draw(at: moment, style: plan.style, in: context, canvas: canvas) }
        }
        if alpha < 1 {
            context.saveGState()
            context.setAlpha(alpha)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            frame(moment)
            context.endTransparencyLayer()
            context.restoreGState()
        } else {
            frame(moment)
        }
    }

    /// Where the finished logo sits on a canvas (as `draw` places it).
    func logoRect(canvas: CGSize, logoScale: Double = 0.62) -> CGRect {
        let fit = min(canvas.width * logoScale / size.width, canvas.height * 0.5 / size.height)
        let drawn = CGSize(width: size.width * fit, height: size.height * fit)
        return CGRect(x: (canvas.width - drawn.width) / 2, y: (canvas.height - drawn.height) / 2, width: drawn.width, height: drawn.height)
    }

    /// How long the soft wipe takes to cross the logo.
    static let wipeLength = 1.4

    // MARK: - Drawing

    /// Draws the logo at time `t` (seconds), centred in a frame of `canvas`, the logo
    /// `logoWidth` of the frame's width at most. The context's origin is bottom left.
    func draw(at t: Double, style chosen: Style, in context: CGContext, canvas: CGSize, logoScale: Double = 0.62) {
        let style = chosen == .automatic ? suggestedStyle : chosen
        let fit = min(canvas.width * logoScale / size.width, canvas.height * 0.5 / size.height)
        let drawn = CGSize(width: size.width * fit, height: size.height * fit)
        let origin = CGPoint(x: (canvas.width - drawn.width) / 2, y: (canvas.height - drawn.height) / 2)
        // Logo pixels (origin top left) to canvas points (origin bottom left).
        func place(_ r: CGRect) -> CGRect {
            CGRect(x: origin.x + r.minX * fit, y: origin.y + (size.height - r.maxY) * fit, width: r.width * fit, height: r.height * fit)
        }
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * fit, y: origin.y + (size.height - p.y) * fit) }

        let timing = timing(style)
        if style == .assemble {
            drawAssemble(at: t, timing: timing, fit: fit, place: place, in: context)
            return
        }
        if style == .liquid {
            drawLiquid(at: t, timing: timing, fit: fit, place: place, canvas: canvas, in: context)
            return
        }
        if Self.expressive.contains(style) {
            for (index, element) in elements.enumerated() {
                let local = t - timing[index].start
                guard local > 0 else { continue }
                // Its time is up: exactly in place (no leftover wobble frozen into the hold).
                if local >= timing[index].length {
                    context.draw(element.image, in: place(element.box))
                    continue
                }
                drawExpressive(index, local: local, length: timing[index].length, style: style, rect: place(element.box), fit: fit,
                               point: point, in: context)
            }
            return
        }
        let whole = place(CGRect(origin: .zero, size: size))
        if style == .wipe { context.beginTransparencyLayer(auxiliaryInfo: nil) }
        for (index, element) in elements.enumerated() {
            let (start, length) = timing[index]
            let p = min(max((t - start) / length, 0), 1)
            guard p > 0 || style == .wipe else { continue }
            let rect = place(element.box)
            context.saveGState()
            switch style {
            case .elegant:
                // Up a little, out of a soft focus, without any bounce.
                let e = Easing.outQuint(p)
                context.translateBy(x: 0, y: -(1 - e) * drawn.height * 0.09)
                let scale = 1 + (1 - e) * 0.03
                context.translateBy(x: rect.midX, y: rect.midY)
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: -rect.midX, y: -rect.midY)
                drawSoft(element, in: rect, focus: 1 - Easing.outCubic(min(p * 1.15, 1)), alpha: Easing.outCubic(min(p * 1.6, 1)),
                         scale: fit, context: context)
            case .rise:
                let e = Easing.outQuint(p)
                if element.kind == .letter || element.kind == .accent {
                    // From behind the line the letter stands on.
                    context.clip(to: CGRect(x: rect.minX - rect.width, y: rect.minY - 0.5, width: rect.width * 3, height: canvas.height))
                    context.translateBy(x: 0, y: -(1 - e) * rect.height * 1.05)
                    context.setAlpha(min(p * 4, 1))
                    context.draw(element.image, in: rect)
                } else {
                    let scale = 0.86 + 0.14 * Easing.outExpo(p)
                    context.translateBy(x: rect.midX, y: rect.midY)
                    context.scaleBy(x: scale, y: scale)
                    context.translateBy(x: -rect.midX, y: -rect.midY)
                    drawSoft(element, in: rect, focus: 1 - e, alpha: Easing.outCubic(min(p * 1.8, 1)), scale: fit, context: context)
                }
            case .wipe:
                // Behind the edge, a slight drift into place and out of focus.
                let e = Easing.outCubic(p)
                context.translateBy(x: -(1 - e) * drawn.width * 0.025, y: 0)
                drawSoft(element, in: rect, focus: (1 - e) * 0.6, alpha: 1, scale: fit, context: context)
            case .build, .automatic:
                if element.kind == .symbol || element.kind == .plate {
                    // The outline draws itself, then the shape fills in and the line fades.
                    let line = Easing.inOutCubic(min(p / 0.7, 1))
                    let fill = Easing.outCubic(min(max((p - 0.55) / 0.45, 0), 1))
                    let grow = 0.92 + 0.08 * Easing.outBack(min(p / 0.8, 1))
                    context.translateBy(x: rect.midX, y: rect.midY)
                    context.scaleBy(x: grow, y: grow)
                    context.translateBy(x: -rect.midX, y: -rect.midY)
                    if fill < 1 {
                        context.setStrokeColor(element.colour)
                        context.setAlpha(1 - fill)
                        context.setLineWidth(max(1.5, min(drawn.width, drawn.height) * 0.012))
                        context.setLineJoin(.round)
                        context.setLineCap(.round)
                        for outline in element.outlines { strokePart(of: outline.map(point), fraction: line, in: context) }
                    }
                    context.setAlpha(fill)
                    context.draw(element.image, in: rect)
                } else {
                    // Letters roll up into place with a little overshoot.
                    let e = Easing.outBack(p)
                    let lift = (1 - e) * rect.height * 0.7
                    context.setAlpha(Easing.outCubic(min(p * 1.6, 1)))
                    context.translateBy(x: 0, y: -lift)
                    let tilt = (1 - e) * -0.18
                    context.translateBy(x: rect.midX, y: rect.minY)
                    context.rotate(by: tilt)
                    context.translateBy(x: -rect.midX, y: -rect.minY)
                    context.draw(element.image, in: rect)
                }
            case .pop:
                let s = Easing.spring(p)
                context.setAlpha(Easing.outCubic(min(p * 2.5, 1)))
                context.translateBy(x: rect.midX, y: rect.midY)
                context.scaleBy(x: s, y: s)
                context.rotate(by: (1 - Easing.outCubic(p)) * 0.25)
                context.translateBy(x: -rect.midX, y: -rect.midY)
                context.draw(element.image, in: rect)
            case .cascade:
                let e = Easing.outExpo(p)
                context.setAlpha(Easing.outCubic(min(p * 2, 1)))
                context.translateBy(x: (1 - e) * drawn.width * 0.12, y: 0)
                let squash = 1 + (1 - Easing.outCubic(p)) * 0.25
                context.translateBy(x: rect.midX, y: rect.midY)
                context.scaleBy(x: 1 / squash, y: squash)
                context.translateBy(x: -rect.midX, y: -rect.midY)
                context.draw(element.image, in: rect)
            case .lineDraw, .bounce, .stretch, .assemble, .liquid:
                break
            case .reveal:
                let e = Easing.outCubic(p)
                context.setAlpha(e)
                context.translateBy(x: 0, y: (1 - e) * -rect.height * 0.25)
                let blurFree = 0.94 + 0.06 * e
                context.translateBy(x: rect.midX, y: rect.midY)
                context.scaleBy(x: blurFree, y: blurFree)
                context.translateBy(x: -rect.midX, y: -rect.midY)
                context.draw(element.image, in: rect)
            }
            context.restoreGState()
        }

        if style == .wipe {
            // The reveal: everything left of the soft edge shows.
            let w = Easing.inOutCubic(min(max(t / Self.wipeLength, 0), 1))
            let soft = whole.width * 0.28
            let edge = whole.minX - 2 + (whole.width + soft + 4) * w
            let colours = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0)] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours, locations: [0, 1]) {
                context.setBlendMode(.destinationIn)
                context.drawLinearGradient(gradient, start: CGPoint(x: edge - soft, y: 0), end: CGPoint(x: edge, y: 0),
                                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                context.setBlendMode(.normal)
            }
            context.endTransparencyLayer()
        }
    }

    /// Draws a shape out of focus: `focus` 0 is sharp, 1 the softest copy; in between, the two
    /// nearest copies are mixed exactly (added in a layer), so the focus pull is smooth.
    private func drawSoft(_ element: Element, in rect: CGRect, focus: Double, alpha: Double, scale: Double, context: CGContext) {
        let levels = [(image: element.image, pad: CGFloat(0))] + element.blurred
        let position = min(max(focus, 0), 1) * Double(levels.count - 1)
        let lower = Int(position.rounded(.down)), upper = min(lower + 1, levels.count - 1)
        let mix = position - Double(lower)
        func frame(_ level: (image: CGImage, pad: CGFloat)) -> CGRect { rect.insetBy(dx: -level.pad * scale, dy: -level.pad * scale) }
        context.saveGState()
        context.setAlpha(alpha)
        if mix < 0.01 || lower == upper {
            context.draw(levels[lower].image, in: frame(levels[lower]))
        } else {
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.setAlpha(1 - mix)
            context.draw(levels[lower].image, in: frame(levels[lower]))
            context.setBlendMode(.plusLighter)
            context.setAlpha(mix)
            context.draw(levels[upper].image, in: frame(levels[upper]))
            context.endTransparencyLayer()
        }
        context.restoreGState()
    }

    /// Strokes the first `fraction` of a closed outline.
    private func strokePart(of points: [CGPoint], fraction: Double, in context: CGContext) {
        guard points.count > 1, fraction > 0 else { return }
        let closed = points + [points[0]]
        var lengths: [Double] = [0]
        for i in 1..<closed.count { lengths.append(lengths[i - 1] + hypot(closed[i].x - closed[i - 1].x, closed[i].y - closed[i - 1].y)) }
        let target = lengths.last! * fraction
        context.beginPath()
        context.move(to: closed[0])
        for i in 1..<closed.count {
            if lengths[i] <= target {
                context.addLine(to: closed[i])
            } else {
                let part = (target - lengths[i - 1]) / max(lengths[i] - lengths[i - 1], 0.0001)
                context.addLine(to: CGPoint(x: closed[i - 1].x + (closed[i].x - closed[i - 1].x) * part,
                                            y: closed[i - 1].y + (closed[i].y - closed[i - 1].y) * part))
                break
            }
        }
        context.strokePath()
    }

    /// One frame as an image (for the preview).
    func frame(at t: Double, style: Style, size canvas: CGSize, background: CGColor?) -> CGImage? {
        frame(at: t, plan: plan(style, outro: .none), size: canvas, background: background)
    }

    func frame(at t: Double, plan: Plan, size canvas: CGSize, background: CGColor?) -> CGImage? {
        let width = Int(canvas.width), height = Int(canvas.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        if let background {
            context.setFillColor(background)
            context.fill(CGRect(origin: .zero, size: canvas))
        }
        draw(at: t, plan: plan, in: context, canvas: canvas)
        return context.makeImage()
    }

    // MARK: - Export

    /// Renders the animation: ProRes 4444 with transparency (.mov) without a background,
    /// H.264 (.mp4) on one.
    func export(to output: URL, style: Style, size canvas: CGSize, frameRate: Int, background: CGColor?, ffmpeg: String,
                progress: @escaping @Sendable (Double) -> Void) async throws {
        try await export(to: output, plan: plan(style, outro: .none), size: canvas, frameRate: frameRate, background: background,
                         ffmpeg: ffmpeg, progress: progress)
    }

    func export(to output: URL, plan: Plan, size canvas: CGSize, frameRate: Int, background: CGColor?, ffmpeg: String,
                progress: @escaping @Sendable (Double) -> Void) async throws {
        let animation = self
        // Motion blur where shapes fly (the expressive styles and Assemble).
        let samples = Self.expressive.contains(plan.style) || plan.style == .assemble ? 5 : 1
        try await Self.writeVideo(to: output, size: canvas, frameRate: frameRate, length: plan.total, transparent: background == nil,
                                  motionBlur: samples, ffmpeg: ffmpeg, progress: progress) { t, context in
            if let background {
                context.setFillColor(background)
                context.fill(CGRect(origin: .zero, size: canvas))
            }
            animation.draw(at: t, plan: plan, in: context, canvas: canvas)
        }
    }

    /// Renders `length` seconds of frames with `draw` and encodes them: ProRes 4444 with alpha when
    /// `transparent`, otherwise H.264. `motionBlur` moments are averaged per frame where
    /// something moves, as a camera with a half-open shutter sees it.
    static func writeVideo(to output: URL, size canvas: CGSize, frameRate: Int, length: Double, transparent: Bool,
                           motionBlur samples: Int = 1, ffmpeg: String, progress: @escaping @Sendable (Double) -> Void,
                           draw: @escaping @Sendable (Double, CGContext) -> Void) async throws {
        let width = Int(canvas.width), height = Int(canvas.height)
        let frames = Int((length * Double(frameRate)).rounded())
        var args = ["-nostdin", "-y", "-v", "error", "-f", "rawvideo", "-pix_fmt", "rgba", "-s", "\(width)x\(height)",
                    "-r", String(frameRate), "-i", "-"]
        if transparent {
            args += ["-c:v", "prores_ks", "-profile:v", "4444", "-pix_fmt", "yuva444p10le", "-vendor", "apl0"]
        } else {
            args += ["-c:v", "libx264", "-preset", "slow", "-crf", "14", "-pix_fmt", "yuv420p", "-movflags", "+faststart"]
        }
        args.append(output.path)
        // If ffmpeg stops early, writing to it must fail, not end the app.
        signal(SIGPIPE, SIG_IGN)
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = args
            let input = Pipe(), errors = Pipe()
            process.standardInput = input
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let base = context.data else { throw Failure() }
            context.interpolationQuality = .high
            var straight = [UInt8](repeating: 0, count: width * height * 4)
            var sum = [Float](repeating: 0, count: samples > 1 ? width * height * 4 : 0)
            var previous: [UInt8]?
            for frame in 0..<frames {
                try Task.checkCancellation()
                let time = Double(frame) / Double(frameRate)
                func render(_ t: Double) {
                    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
                    context.saveGState()
                    draw(t, context)
                    context.restoreGState()
                }
                render(time)
                if samples > 1 {
                    let bytes = base.assumingMemoryBound(to: UInt8.self)
                    let current = Array(UnsafeBufferPointer(start: bytes, count: width * height * 4))
                    // Nothing moved since the last frame's moment: no blur to add.
                    let moving = previous.map { $0 != current } ?? true
                    previous = current
                    if moving {
                        vDSP.convertElements(of: current, to: &sum)
                        var layer = [Float](repeating: 0, count: width * height * 4)
                        for k in 1..<samples {
                            render(time + 0.5 / Double(frameRate) * (Double(k) / Double(samples - 1) - 0.5))
                            vDSP.convertElements(of: UnsafeBufferPointer(start: bytes, count: width * height * 4), to: &layer)
                            vDSP.add(sum, layer, result: &sum)
                        }
                        vDSP.multiply(1 / Float(samples), sum, result: &sum)
                        sum.withUnsafeBufferPointer { values in
                            for i in 0..<(width * height * 4) { bytes[i] = UInt8(min(max(values[i].rounded(), 0), 255)) }
                        }
                    }
                }
                // ffmpeg wants straight (not premultiplied) alpha.
                var source = vImage_Buffer(data: base, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                straight.withUnsafeMutableBytes { bytes in
                    var destination = vImage_Buffer(data: bytes.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                    _ = vImageUnpremultiplyData_RGBA8888(&source, &destination, vImage_Flags(kvImageNoFlags))
                }
                try input.fileHandleForWriting.write(contentsOf: straight)
                if frame % 10 == 0 { progress(Double(frame) / Double(max(frames, 1))) }
            }
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw FrameRewriter.Failure.writing(message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }.value
        progress(1)
    }
}

/// Easing curves (input and output 0…1).
enum Easing {
    static func outCubic(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    /// A long, gentle settle: the motion designer's default for calm moves.
    static func outQuint(_ x: Double) -> Double { 1 - pow(1 - x, 5) }
    static func inOutCubic(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    static func outExpo(_ x: Double) -> Double { x >= 1 ? 1 : 1 - pow(2, -10 * x) }
    /// Overshoots a little, then settles.
    static func outBack(_ x: Double) -> Double {
        let c1 = 1.4, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }
    /// A damped spring: past the target and back, settling by the end.
    static func spring(_ x: Double) -> Double {
        guard x < 1 else { return 1 }
        return 1 - exp(-6 * x) * cos(11 * x)
    }
}
