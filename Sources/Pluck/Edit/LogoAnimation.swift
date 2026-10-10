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
        enum Kind { case symbol, letter }
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
    }

    enum Style: String, CaseIterable, Identifiable, Sendable {
        case automatic, elegant, rise, wipe, build, pop, cascade, reveal
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
            }
        }
    }

    let logo: CGImage
    let size: CGSize
    let elements: [Element]

    var symbolCount: Int { elements.filter { $0.kind == .symbol }.count }
    var letterCount: Int { elements.filter { $0.kind == .letter }.count }

    /// What the analysis chose for `.automatic`.
    var suggestedStyle: Style {
        // The refined styles: letters rising for a wordmark, a focus pull for a symbol alone.
        letterCount >= 2 ? .rise : .elegant
    }

    struct Failure: LocalizedError {
        var errorDescription: String? { String(localized: "Pluck couldn’t find a logo in this picture. Try a PNG or SVG with a transparent or plain background.") }
    }

    // MARK: - Analysis

    init(contentsOf url: URL) throws {
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
        Self.keyOutBackground(&pixels, width: width, height: height)

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
    private static func keyOutBackground(_ pixels: inout [UInt8], width: Int, height: Int) {
        let count = width * height
        var transparent = 0
        for index in 0..<count where pixels[index * 4 + 3] < 250 { transparent += 1 }
        guard transparent < count / 50 else { return }
        var border: [(Int, Int, Int)] = []
        for x in stride(from: 0, to: width, by: 4) {
            for y in [0, height - 1] { let i = (y * width + x) * 4; border.append((Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))) }
        }
        for y in stride(from: 0, to: height, by: 4) {
            for x in [0, width - 1] { let i = (y * width + x) * 4; border.append((Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))) }
        }
        func median(_ v: [Int]) -> Int { v.sorted()[v.count / 2] }
        let bg = (median(border.map(\.0)), median(border.map(\.1)), median(border.map(\.2)))
        for index in 0..<count {
            let i = index * 4
            let d = abs(Int(pixels[i]) - bg.0) + abs(Int(pixels[i + 1]) - bg.1) + abs(Int(pixels[i + 2]) - bg.2)
            // A soft edge: anti-aliased pixels become partly transparent.
            let a = min(1, max(0, Double(d - 24) / 90))
            if a >= 1 { continue }
            if a <= 0 {
                pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0
                continue
            }
            // Take the background out of the mixed colour, then premultiply.
            for c in 0..<3 {
                let bgc = Double([bg.0, bg.1, bg.2][c])
                let straight = min(255, max(0, (Double(pixels[i + c]) - bgc * (1 - a)) / a))
                pixels[i + c] = UInt8(straight * a)
            }
            pixels[i + 3] = UInt8(a * 255)
        }
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
        let big = boxes.filter { Double($0.value.area) >= Double(totalInk) * 0.004 }
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
        // Dots and accents (the dot on an i, an umlaut) belong to the letter under or over them.
        let areas = groups.values.map(\.area).sorted()
        let typicalArea = areas[areas.count / 2]
        for (key, box) in groups where box.area < typicalArea * 3 / 10 {
            let centre = (box.minX + box.maxX) / 2, height = box.maxY - box.minY + 1
            let base = groups.filter { other in
                other.key != key && other.value.area > box.area && centre >= other.value.minX && centre <= other.value.maxX
                    && min(abs(other.value.minY - box.maxY), abs(box.minY - other.value.maxY)) < height * 3 / 2
            }.min { $0.value.area < $1.value.area }
            guard let base, let target = groups[base.key] else { continue }
            groups[base.key] = (min(target.minX, box.minX), min(target.minY, box.minY), max(target.maxX, box.maxX),
                                max(target.maxY, box.maxY), target.area + box.area)
            groups[key] = nil
            for (root, value) in owner where value == key { owner[root] = base.key }
        }
        // Too many pieces (a detailed illustration): animate it as one.
        if groups.count > 60 {
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
        for (key, box) in groups {
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
            let inText = textBoxes.contains { $0.insetBy(dx: -4, dy: -4).contains(CGPoint(x: rect.midX, y: rect.midY)) }
            // A symbol in several colours is several shapes (a sun over a mountain): each moves
            // on its own.
            let parts = inText ? nil : Self.colourParts(cut, shape: shape, width: w, height: h)
            for part in parts ?? [(cut, shape)] {
                if let element = Self.element(part.0, shape: part.1, width: w, height: h, origin: rect.origin, kind: inText ? .letter : .symbol) {
                    result.append(element)
                }
            }
        }
        // No text found but many similar shapes in a row: probably a wordmark the recogniser
        // couldn't read (a custom font); treat them as letters.
        if textBoxes.isEmpty, result.count >= 3 {
            let heights = result.map(\.box.height).sorted()
            let typical = heights[heights.count / 2]
            // Shapes about letter height are letters; much taller ones stay the symbol.
            for i in result.indices where result[i].box.height < typical * 1.6 { result[i].kind = .letter }
        }
        // Order: the symbol's shapes biggest first, then the letters line by line, left to right.
        let symbols = result.filter { $0.kind == .symbol }.sorted { $0.box.width * $0.box.height > $1.box.width * $1.box.height }
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
        return symbols + letters
    }

    /// One element from a cut-out (logo-sized box at `origin`), cropped to its own pixels.
    private static func element(_ cut: [UInt8], shape: [UInt8], width w: Int, height h: Int, origin: CGPoint, kind: Element.Kind) -> Element? {
        var minX = w, minY = h, maxX = -1, maxY = -1
        var colour = SIMD4<Double>.zero
        for y in 0..<h {
            for x in 0..<w where shape[y * w + x] > 0 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                let i = (y * w + x) * 4
                if shape[y * w + x] > 200 { colour += SIMD4(Double(cut[i]), Double(cut[i + 1]), Double(cut[i + 2]), 1) }
            }
        }
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
        return Element(kind: kind, image: image, box: box, outlines: outlines(alpha, width: cw, height: ch, offset: box.origin),
                       colour: CGColor(srgbRed: mean.x / 255, green: mean.y / 255, blue: mean.z / 255, alpha: 1),
                       blurred: softened(image))
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
        var colours: [SIMD3<Double>] = []
        for i in 0..<(w * h) where shape[i] > 200 {
            let a = Double(cut[i * 4 + 3]) / 255
            colours.append(SIMD3(Double(cut[i * 4]), Double(cut[i * 4 + 1]), Double(cut[i * 4 + 2])) / max(a, 0.01))
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
        for bin in bins.values.sorted(by: { $0.count > $1.count }) where bin.count >= colours.count / 25 {
            let mean = bin.sum / Double(bin.count)
            if centres.allSatisfy({ distance($0, mean) > 70 }) { centres.append(mean) }
            if centres.count == 4 { break }
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
        let symbols = elements.indices.filter { elements[$0].kind == .symbol }
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
        }
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
        if alpha < 1 {
            context.saveGState()
            context.setAlpha(alpha)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            draw(at: moment, style: plan.style, in: context, canvas: canvas)
            context.endTransparencyLayer()
            context.restoreGState()
        } else {
            draw(at: moment, style: plan.style, in: context, canvas: canvas)
        }
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
                if element.kind == .letter {
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
                if element.kind == .symbol {
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
        let width = Int(canvas.width), height = Int(canvas.height)
        let frames = Int((plan.total * Double(frameRate)).rounded())
        var args = ["-nostdin", "-y", "-v", "error", "-f", "rawvideo", "-pix_fmt", "rgba", "-s", "\(width)x\(height)",
                    "-r", String(frameRate), "-i", "-"]
        if background == nil {
            args += ["-c:v", "prores_ks", "-profile:v", "4444", "-pix_fmt", "yuva444p10le", "-vendor", "apl0"]
        } else {
            args += ["-c:v", "libx264", "-preset", "slow", "-crf", "14", "-pix_fmt", "yuv420p", "-movflags", "+faststart"]
        }
        args.append(output.path)
        let animation = self
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
            for frame in 0..<frames {
                try Task.checkCancellation()
                context.clear(CGRect(x: 0, y: 0, width: width, height: height))
                if let background {
                    context.setFillColor(background)
                    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                }
                animation.draw(at: Double(frame) / Double(frameRate), plan: plan, in: context, canvas: canvas)
                // ffmpeg wants straight (not premultiplied) alpha.
                var source = vImage_Buffer(data: base, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                straight.withUnsafeMutableBytes { bytes in
                    var destination = vImage_Buffer(data: bytes.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                    _ = vImageUnpremultiplyData_RGBA8888(&source, &destination, vImage_Flags(kvImageNoFlags))
                }
                try input.fileHandleForWriting.write(contentsOf: straight)
                if frame % 10 == 0 { progress(Double(frame) / Double(frames)) }
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
