import CoreGraphics
import Foundation

/// Joins a logo file's own vector shapes to the parts the analysis found in a picture of it, so
/// the parts can be drawn sharp at any size. A part whose shapes don't match its picture keeps
/// its picture.
extension LogoAnimation {
    /// How far the art is from the system's own picture of the file: the share of inked pixels
    /// that differ (1 if it can't be drawn). Under 1%, its reading is complete and lines up.
    static func artDifference(_ art: VectorArt, picture pixels: [UInt8], width: Int, height: Int, scale: Double) -> Double {
        guard let drawn = render(art.shapes, width: width, height: height, transform: CGAffineTransform(scaleX: scale, y: scale)) else { return 1 }
        var inked = 0, differ = 0
        for i in 0..<(width * height) {
            let o = i * 4
            guard pixels[o + 3] > 20 || drawn[o + 3] > 20 else { continue }
            inked += 1
            let largest = (0..<4).map { abs(Int(pixels[o + $0]) - Int(drawn[o + $0])) }.max()!
            if largest > 40 { differ += 1 }
        }
        return inked > 0 ? Double(differ) / Double(inked) : 1
    }

    /// Shapes drawn into premultiplied RGBA (row 0 at the top), their coordinates through `transform`.
    static func render(_ shapes: [VectorArt.Shape], width: Int, height: Int, transform: CGAffineTransform) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.concatenate(transform)
            VectorArt(shapes: shapes, size: .zero).draw(in: context)
            return true
        }
        return ok ? bytes : nil
    }

    /// How much of each pixel of a box (logo pixels) a set of shapes covers, 0–255, row 0 at the top.
    private static func coverage(_ shapes: [VectorArt.Shape], x0: Int, y0: Int, width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.translateBy(x: CGFloat(-x0), y: CGFloat(height + y0))
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(gray: 1, alpha: 1)
            for shape in shapes {
                context.addPath(shape.path)
                context.fillPath(using: shape.evenOdd ? .evenOdd : .winding)
            }
        }
        return bytes
    }

    /// A shape's separate pieces: each outline with the outlines inside it (its holes, or what
    /// fills them), so a word drawn as one path becomes its letters.
    static func islands(_ shape: VectorArt.Shape) -> [VectorArt.Shape] {
        var subpaths: [CGMutablePath] = []
        shape.path.applyWithBlock { element in
            let p = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint:
                let path = CGMutablePath()
                path.move(to: p[0])
                subpaths.append(path)
            case .addLineToPoint: subpaths.last?.addLine(to: p[0])
            case .addQuadCurveToPoint: subpaths.last?.addQuadCurve(to: p[1], control: p[0])
            case .addCurveToPoint: subpaths.last?.addCurve(to: p[2], control1: p[0], control2: p[1])
            case .closeSubpath: subpaths.last?.closeSubpath()
            @unknown default: break
            }
        }
        subpaths.removeAll { $0.boundingBoxOfPath.isEmpty && $0.boundingBoxOfPath.width + $0.boundingBoxOfPath.height == 0 }
        guard subpaths.count > 1 else { return [shape] }
        let boxes = subpaths.map(\.boundingBoxOfPath)
        // Each outline joins the outermost outline around it.
        var root = Array(subpaths.indices)
        for i in subpaths.indices {
            var best: Int?
            for j in subpaths.indices where j != i && boxes[j].insetBy(dx: -0.01, dy: -0.01).contains(boxes[i])
                && boxes[j].width * boxes[j].height > boxes[i].width * boxes[i].height
                && subpaths[j].contains(subpaths[i].currentPoint, using: .winding) {
                if best.map({ boxes[j].width * boxes[j].height > boxes[$0].width * boxes[$0].height }) ?? true { best = j }
            }
            if let best { root[i] = best }
        }
        // Outlines that overlap stay together too: where they cross, the fill rule decides
        // what's filled, and apart they'd fill it differently.
        func top(_ i: Int) -> Int { var i = i; while root[i] != i { i = root[i] }; return i }
        let tops = Array(Set(subpaths.indices.map(top))).sorted()
        for (n, a) in tops.enumerated() {
            for b in tops[(n + 1)...] where boxes[a].intersects(boxes[b]) && subpaths[a].intersects(subpaths[b]) {
                let (ra, rb) = (top(a), top(b))
                if ra != rb { root[max(ra, rb)] = min(ra, rb) }
            }
        }
        for i in subpaths.indices { root[i] = top(i) }
        var order: [Int] = []
        var groups: [Int: CGMutablePath] = [:]
        for i in subpaths.indices {
            let key = root[i]
            if groups[key] == nil { groups[key] = CGMutablePath(); order.append(key) }
            groups[key]!.addPath(subpaths[i])
        }
        return order.map { VectorArt.Shape(path: groups[$0]!, colour: shape.colour, evenOdd: shape.evenOdd) }
    }

    /// Gives each element the shapes of `art` that make it up (art in the file's units, drawn at
    /// `scale` and then moved by `offset` into logo pixels). Returns every shape that belongs to
    /// the logo, in drawing order, when all of its elements could be given theirs.
    static func attach(_ art: VectorArt, scale: Double, offset: CGPoint, to elements: inout [Element],
                       logo pixels: [UInt8], width w: Int, height h: Int) -> [VectorArt.Shape]? {
        var place = CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: -offset.x, y: -offset.y))
        let pieces = art.shapes.flatMap { shape -> [VectorArt.Shape] in
            guard let path = shape.path.copy(using: &place) else { return [] }
            return islands(VectorArt.Shape(path: path, colour: shape.colour, evenOdd: shape.evenOdd))
        }
        // Each element's own coverage, from its picture.
        let alphas = elements.map { element -> [UInt8] in
            let iw = element.image.width, ih = element.image.height
            var rgba = [UInt8](repeating: 0, count: iw * ih * 4)
            rgba.withUnsafeMutableBytes { buffer in
                CGContext(data: buffer.baseAddress, width: iw, height: ih, bitsPerComponent: 8, bytesPerRow: iw * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                    .draw(element.image, in: CGRect(x: 0, y: 0, width: iw, height: ih))
            }
            return (0..<(iw * ih)).map { rgba[$0 * 4 + 3] }
        }
        func elementAlpha(_ n: Int, _ x: Int, _ y: Int) -> UInt8 {
            let box = elements[n].box
            let lx = x - Int(box.minX), ly = y - Int(box.minY)
            guard lx >= 0, ly >= 0, lx < elements[n].image.width, ly < elements[n].image.height else { return 0 }
            return alphas[n][ly * elements[n].image.width + lx]
        }

        var owned = [[VectorArt.Shape]](repeating: [], count: elements.count)
        var kept: [VectorArt.Shape] = []
        var lost = false
        for piece in pieces {
            let bounds = piece.path.boundingBoxOfPath.integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
            guard !bounds.isNull, bounds.width >= 1, bounds.height >= 1 else { continue }
            let x0 = Int(bounds.minX), y0 = Int(bounds.minY), bw = Int(bounds.width), bh = Int(bounds.height)
            let cover = coverage([piece], x0: x0, y0: y0, width: bw, height: bh)
            var total = 0, inked = 0
            var overlap = [Int](repeating: 0, count: elements.count)
            let candidates = elements.indices.filter { elements[$0].box.intersects(bounds) }
            for y in 0..<bh {
                for x in 0..<bw where cover[y * bw + x] > 128 {
                    total += 1
                    let lx = x + x0, ly = y + y0
                    if pixels[(ly * w + lx) * 4 + 3] > 128 { inked += 1 }
                    for n in candidates where elementAlpha(n, lx, ly) > 128 { overlap[n] += 1 }
                }
            }
            guard total > 0 else { continue }
            // A shape goes to the part of its own colour it lies on (white letters on a plate are
            // the letters', not the plate's, although the plate's picture runs on under them).
            let mine = piece.colour.components ?? [0, 0, 0, 1]
            func sameColour(_ n: Int) -> Bool {
                let theirs = elements[n].colour.components ?? [0, 0, 0, 1]
                return (0..<3).allSatisfy { abs(mine[min($0, mine.count - 1)] - theirs[min($0, theirs.count - 1)]) < 0.25 }
            }
            func score(_ n: Int) -> Double { Double(overlap[n]) * (sameColour(n) ? 1 : 0.1) }
            if let best = candidates.max(by: { score($0) < score($1) }), overlap[best] * 3 >= total {
                owned[best].append(piece)
                kept.append(piece)
            } else if inked * 2 > total {
                // Ink that no part took: the whole logo can't be drawn from the file's shapes.
                lost = true
            }
            // Otherwise it's a background the analysis took off.
        }

        // Each element keeps its shapes only if they draw what its picture shows: inside its
        // picture nothing missing, outside it nothing extra (except under ink of another colour,
        // as a plate's shape runs on under the letters on it).
        var complete = !lost
        for n in elements.indices {
            guard !owned[n].isEmpty else { complete = false; continue }
            let box = elements[n].box.insetBy(dx: -2, dy: -2).intersection(CGRect(x: 0, y: 0, width: w, height: h))
            let x0 = Int(box.minX), y0 = Int(box.minY), bw = Int(box.width), bh = Int(box.height)
            let cover = coverage(owned[n], x0: x0, y0: y0, width: bw, height: bh)
            let colour = elements[n].colour.components ?? [0, 0, 0]
            var wrong = 0
            for y in 0..<bh {
                for x in 0..<bw {
                    let lx = x + x0, ly = y + y0
                    let mine = elementAlpha(n, lx, ly), shape = cover[y * bw + x]
                    if mine > 200 && shape < 30 { wrong += 1 }
                    if shape > 200 && mine < 30 {
                        let o = (ly * w + lx) * 4
                        let a = Double(pixels[o + 3])
                        let other = a > 200 && (0..<3).contains { abs(Double(pixels[o + $0]) / a - Double(colour[min($0, colour.count - 1)])) > 0.25 }
                        if !other { wrong += 1 }
                    }
                }
            }
            if Double(wrong) <= max(4, elements[n].area * 0.01) {
                elements[n].vector = owned[n]
            } else {
                complete = false
            }
        }
        return complete ? kept : nil
    }
}

extension LogoAnimation.Element {
    /// Draws the shape filling `rect` (canvas points, origin bottom left): from the logo file's
    /// own vectors when it has them, else its picture.
    func draw(in rect: CGRect, _ context: CGContext) {
        guard let vector else {
            context.draw(image, in: rect)
            return
        }
        context.saveGState()
        // Several shapes fade as one (as the picture would), not each on its own.
        if vector.count > 1 { context.beginTransparencyLayer(in: rect.insetBy(dx: -2, dy: -2), auxiliaryInfo: nil) }
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: rect.width / box.width, y: -rect.height / box.height)
        context.translateBy(x: -box.minX, y: -box.minY)
        VectorArt(shapes: vector, size: .zero).draw(in: context)
        if vector.count > 1 { context.endTransparencyLayer() }
        context.restoreGState()
    }
}

extension LogoAnimation {
    /// Draws the finished logo filling `rect` (canvas points, origin bottom left): from the file's
    /// vectors when every part has them, else the picture.
    func drawLogo(in rect: CGRect, _ context: CGContext) {
        guard let vectorLogo else {
            context.draw(logo, in: rect)
            return
        }
        context.saveGState()
        // Faded as one picture, not shape by shape.
        context.beginTransparencyLayer(in: rect.insetBy(dx: -2, dy: -2), auxiliaryInfo: nil)
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: rect.width / size.width, y: -rect.height / size.height)
        VectorArt(shapes: vectorLogo, size: size).draw(in: context)
        context.endTransparencyLayer()
        context.restoreGState()
    }
}
