import CoreImage
import Vision

/// Masks for parts of people (Whole Face, Face Skin, Body Skin, Eyes, Eyebrows, Lips, Teeth, Hair): Vision's
/// face landmarks drawn as soft shapes, its person segmentation, and the photo's own colours for skin, teeth
/// and hair. Worked out once per photo at up to 1024 on the long side (shares of the photo, so the preview
/// and the export match), then fitted to the photo's edges like the other found masks (see `scaled`).
extension PhotoMasks {
    /// One face's landmarks, in pixels of the scan, from the bottom left (as Vision and Core Graphics count).
    struct FoundFace {
        var box: CGRect
        var contour: [CGPoint], leftEye: [CGPoint], rightEye: [CGPoint], leftBrow: [CGPoint], rightBrow: [CGPoint]
        var outerLips: [CGPoint], innerLips: [CGPoint]
        /// This person alone (instance segmentation), 0…1, rows from the top; nil: everyone's is used.
        var person: [Float]?
    }

    /// What was found in one photo, at the size it was looked at. Planes are rows from the top.
    struct FaceScan {
        let width: Int, height: Int
        /// Left to right.
        let faces: [FoundFace]
        /// Everyone (person segmentation), 0…1.
        let people: [Float]
        let luma: [Float], cb: [Float], cr: [Float], saturation: [Float]
    }

    nonisolated(unsafe) private static var faceScans: [String: FaceScan] = [:]
    nonisolated(unsafe) private static var faceMasks: [String: CIImage] = [:]
    private static let faceLock = NSLock()

    /// How many faces are in this photo (0: none found).
    static func faceCount(_ path: String, from image: CIImage, context: CIContext) -> Int {
        faceScan(path, from: image, context: context)?.faces.count ?? 0
    }

    /// One face part (`person`: 0 the leftmost …, nil everyone), grey at the scan's size; black when no face.
    static func facePart(_ kind: MaskPart.Kind, person: Int?, path: String, from image: CIImage, context: CIContext) -> CIImage? {
        guard let scan = faceScan(path, from: image, context: context) else { return nil }
        let key = "\(path)|\(scan.width)x\(scan.height)|\(kind.rawValue)|\(person ?? -1)"
        if let known = faceLock.withLock({ faceMasks[key] }) { return known }
        let made = faceMask(kind, person: person, in: scan, context: context)
        faceLock.withLock {
            faceMasks[key] = made
            if faceMasks.count > 24, let old = faceMasks.keys.first(where: { $0 != key }) { faceMasks.removeValue(forKey: old) }
        }
        return made
    }

    /// The scan kept for this photo; made again only when a bigger picture comes (a thumbnail looked first).
    private static func faceScan(_ path: String, from image: CIImage, context: CIContext) -> FaceScan? {
        let long = Int(min(1024, max(image.extent.width, image.extent.height)).rounded())
        if let known = faceLock.withLock({ faceScans[path] }), max(known.width, known.height) >= long - 1 { return known }
        guard let scan = scanFaces(image, context: context) else { return nil }
        faceLock.withLock {
            faceScans[path] = scan
            // (A scan is a few full-size planes: only the last two photos are kept; their masks stay longer.)
            if faceScans.count > 2, let old = faceScans.keys.first(where: { $0 != path }) { faceScans.removeValue(forKey: old) }
        }
        return scan
    }

    /// Faces (landmarks), people (segmentation, and each person alone) and the photo's colours, at up to 1024.
    static func scanFaces(_ image: CIImage, context: CIContext) -> FaceScan? {
        let scale = min(1, 1024 / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = context.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: srgb) else { return nil }
        let w = cg.width, h = cg.height, n = w * h
        var rgba = [UInt8](repeating: 0, count: n * 4)
        let drawn = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let c = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var luma = [Float](repeating: 0, count: n), cb = luma, cr = luma, saturation = luma
        for i in 0..<n {
            let r = Float(rgba[i * 4]) / 255, g = Float(rgba[i * 4 + 1]) / 255, b = Float(rgba[i * 4 + 2]) / 255
            let y = 0.299 * r + 0.587 * g + 0.114 * b
            luma[i] = y; cb[i] = b - y; cr[i] = r - y
            let top = max(r, g, b)
            saturation[i] = top > 0 ? (top - min(r, g, b)) / top : 0
        }

        let handler = VNImageRequestHandler(cgImage: cg)
        let landmarks = VNDetectFaceLandmarksRequest()
        try? handler.perform([landmarks])
        let size = CGSize(width: w, height: h)
        var faces = (landmarks.results ?? []).sorted { $0.boundingBox.midX < $1.boundingBox.midX }.map { face -> FoundFace in
            func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] { region?.pointsInImage(imageSize: size) ?? [] }
            let l = face.landmarks
            return FoundFace(box: VNImageRectForNormalizedRect(face.boundingBox, w, h), contour: points(l?.faceContour),
                             leftEye: points(l?.leftEye), rightEye: points(l?.rightEye), leftBrow: points(l?.leftEyebrow),
                             rightBrow: points(l?.rightEyebrow), outerLips: points(l?.outerLips), innerLips: points(l?.innerLips))
        }
        var people = [Float](repeating: 0, count: n)
        if !faces.isEmpty {
            let segmentation = VNGeneratePersonSegmentationRequest()
            segmentation.qualityLevel = .accurate
            segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
            let instances = VNGeneratePersonInstanceMaskRequest()
            try? handler.perform([segmentation, instances])
            if let buffer = segmentation.results?.first?.pixelBuffer {
                let mask = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
                let fitted = mask.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / mask.extent.width, y: CGFloat(h) / mask.extent.height))
                context.render(fitted, toBitmap: &people, rowBytes: w * 4, bounds: CGRect(origin: .zero, size: size), format: .Lf, colorSpace: nil)
            }
            // Each face's own person: the instance under the middle of the face.
            if let found = instances.results?.first {
                let labels = found.instanceMask
                CVPixelBufferLockBaseAddress(labels, .readOnly)
                let lw = CVPixelBufferGetWidth(labels), lh = CVPixelBufferGetHeight(labels), row = CVPixelBufferGetBytesPerRow(labels)
                if let base = CVPixelBufferGetBaseAddress(labels)?.assumingMemoryBound(to: UInt8.self) {
                    for k in faces.indices {
                        let x = min(max(Int(faces[k].box.midX / CGFloat(w) * CGFloat(lw)), 0), lw - 1)
                        let y = min(max(Int((1 - faces[k].box.midY / CGFloat(h)) * CGFloat(lh)), 0), lh - 1)
                        let label = Int(base[y * row + x])
                        guard label > 0, let alone = try? found.generateScaledMaskForImage(forInstances: IndexSet(integer: label), from: handler)
                        else { continue }
                        faces[k].person = plane(alone, w, h)
                    }
                }
                CVPixelBufferUnlockBaseAddress(labels, .readOnly)
            }
        }
        return FaceScan(width: w, height: h, faces: faces, people: people, luma: luma, cb: cb, cr: cr, saturation: saturation)
    }

    /// A float mask from Vision, as a plane (nil when it isn't the scan's size).
    private static func plane(_ buffer: CVPixelBuffer, _ w: Int, _ h: Int) -> [Float]? {
        guard CVPixelBufferGetWidth(buffer) == w, CVPixelBufferGetHeight(buffer) == h else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let line = base.advanced(by: y * row).assumingMemoryBound(to: Float32.self)
            for x in 0..<w { out[y * w + x] = min(max(line[x], 0), 1) }
        }
        return out
    }

    /// One part for the chosen faces (each softened by its own size), grey at the scan's size.
    static func faceMask(_ kind: MaskPart.Kind, person: Int?, in scan: FaceScan, context: CIContext) -> CIImage {
        let w = scan.width, h = scan.height, frame = CGRect(x: 0, y: 0, width: w, height: h)
        var result = CIImage(color: .black).cropped(to: frame)
        let chosen = person.map { scan.faces.indices.contains($0) ? [$0] : [] } ?? Array(scan.faces.indices)
        for k in chosen {
            let (values, soft) = facePlane(kind, face: scan.faces[k], in: scan)
            let one = picture(values, w, h).clampedToExtent().applyingGaussianBlur(sigma: max(soft, 0.5)).cropped(to: frame)
            result = one.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: result]).cropped(to: frame)
        }
        var bytes = [UInt8](repeating: 0, count: w * h)
        context.render(result, toBitmap: &bytes, rowBytes: w, bounds: frame, format: .L8, colorSpace: nil)
        return CIImage(bitmapData: Data(bytes), bytesPerRow: w, size: frame.size, format: .L8, colorSpace: nil)
    }

    private static func picture(_ values: [Float], _ w: Int, _ h: Int) -> CIImage {
        CIImage(bitmapData: values.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: w * 4, size: CGSize(width: w, height: h),
                format: .Lf, colorSpace: nil)
    }

    /// One face's part, unsoftened, and how soft to make it (pixels).
    private static func facePlane(_ kind: MaskPart.Kind, face f: FoundFace, in scan: FaceScan) -> ([Float], CGFloat) {
        let w = scan.width, h = scan.height, n = w * h
        let shape = outline(f), s = shape.size
        func fill(_ shapes: [[CGPoint]], line: CGFloat = 0) -> [Float] { PhotoMasks.fill(shapes, w, h, line: line) }
        let eyes = [f.leftEye, f.rightEye], brows = [f.leftBrow, f.rightBrow]
        /// The face's skin without the eyes, brows and lips (before its colours are looked at).
        func bare() -> [Float] {
            let whole = fill([shape.polygon])
            let features = fill(eyes.map { grown($0, 1.35) } + brows.map { grown($0, 1.25) } + [grown(f.outerLips, 1.1)], line: s * 0.04)
            return zip(whole, features).map { $0 * (1 - $1) }
        }
        switch kind {
        case .face:
            return (fill([shape.polygon]), s * 0.012)
        case .eyes:
            return (fill(eyes), s * 0.004)
        case .brows:
            return (fill(brows, line: s * 0.035), s * 0.008)
        case .lips:
            let outer = fill([f.outerLips]), inner = fill([f.innerLips])
            return (zip(outer, inner).map { $0 * (1 - $1) }, s * 0.004)
        case .teeth:
            return (teeth(f, in: scan).plane, s * 0.003)
        case .faceSkin:
            let core = bare()
            let like = skinLikeness(skinModel(core, scan), scan, spread: 3, strict: false)
            return (zip(core, like).map { $0 * $1 }, s * 0.01)
        case .bodySkin:
            // shortcut: skin is told from clothes by the face's own skin (chroma, chroma for its lightness, and lightness);
            // skin-coloured clothes, wood or blond hair can be taken too, and nothing checks it joins the neck or arms.
            // Upgrade with a clothes/skin segmenter if one comes to Vision.
            let like = skinLikeness(skinModel(bare(), scan), scan, spread: 2.5, strict: true)
            let face = fill([grown(shape.polygon, 1.08)]), body = f.person ?? scan.people
            return ((0..<n).map { body[$0] * like[$0] * (1 - face[$0]) }, s * 0.006)
        case .hair:
            // The person around and above this face, whatever its colour (dark hair on a dark ground is still the
            // person), less the face skin, the face below the brows, and skin like the face's (ears).
            // shortcut: hair below the cheeks (long hair over the shoulders) is left out, so clothes aren't taken.
            let core = bare(), model = skinModel(core, scan)
            let faceSkin = skinLikeness(model, scan, spread: 3, strict: false), ears = skinLikeness(model, scan, spread: 2.5, strict: true)
            let region = fill([shape.hairRegion])
            let lower = fill([f.contour] + eyes.map { grown($0, 1.4) } + brows.map { grown($0, 1.4) }, line: s * 0.06)
            let body = f.person ?? scan.people
            return ((0..<n).map { i in body[i] * region[i] * (1 - max(core[i] * faceSkin[i], lower[i], ears[i])) }, s * 0.006)
        default:
            return ([Float](repeating: 0, count: n), 1)
        }
    }

    /// What the teeth were found from (for the self-test's notes).
    struct TeethStats {
        /// The inner-lips polygon's area as a share of the outer lips'.
        var openingShare: Float
        /// Vision's inner lips were nearly closed, so the opening was looked for in the picture.
        var fromImage: Bool
        var lipLuma: Float, lipSat: Float
        /// The lightest pixel where teeth were looked for.
        var maxLuma: Float
    }

    /// Teeth: where the mouth opens, what's clearly lighter and less saturated than the lips' outer band (both
    /// measured against the lips under the same light, so coloured light doesn't hide them). On smiles Vision's
    /// inner-lips polygon is often nearly closed over visible teeth: then the whole inside of the lips is looked at,
    /// and the picture decides. Tiny finds (a lip gloss glint) are dropped, so a closed mouth stays empty.
    static func teeth(_ f: FoundFace, in scan: FaceScan) -> (plane: [Float], stats: TeethStats) {
        let w = scan.width, h = scan.height, n = w * h
        let outer = fill([f.outerLips], w, h), inner = fill([grown(f.innerLips, 1.1)], w, h)
        // The lips' outer band (lips for sure, even with the mouth wide open).
        let middle = fill([grown(f.outerLips, 0.7)], w, h)
        var mouth: Float = 0, opening: Float = 0, lipLuma: Float = 0, lipSat: Float = 0, count: Float = 0
        for i in 0..<n {
            mouth += outer[i]; opening += inner[i]
            if outer[i] > 0.5 && middle[i] < 0.5 { lipLuma += scan.luma[i]; lipSat += scan.saturation[i]; count += 1 }
        }
        let share = mouth > 0 ? opening / mouth : 0
        let fromImage = share < 0.12
        let area = fromImage ? outer : inner
        var maxLuma: Float = 0
        for i in 0..<n where area[i] > 0.5 { maxLuma = max(maxLuma, scan.luma[i]) }
        guard count > 0 else { return ([Float](repeating: 0, count: n), TeethStats(openingShare: share, fromImage: fromImage, lipLuma: 0, lipSat: 0, maxLuma: maxLuma)) }
        lipLuma /= count; lipSat /= count
        let stats = TeethStats(openingShare: share, fromImage: fromImage, lipLuma: lipLuma, lipSat: lipSat, maxLuma: maxLuma)
        let plane: [Float]
        if lipSat > 0.6 {
            // Strongly coloured light: the teeth are that colour too, so lightness alone: clearly lighter than the lips
            // and in the light part of the mouth (Otsu's split of the lightness there).
            let limit = max(2 * lipLuma, otsu(scan.luma, where: area))
            plane = (0..<n).map { i in area[i] == 0 ? 0 : area[i] * step(limit * 0.9, limit * 1.1, scan.luma[i]) }
        } else {
            plane = (0..<n).map { i -> Float in
                area[i] == 0 ? 0 : area[i] * step(lipLuma * 1.05, lipLuma * 1.3 + 0.01, scan.luma[i])
                    * (1 - step(max(lipSat * 0.9, 0.25), max(lipSat * 1.1, 0.4) + 0.03, scan.saturation[i]))
            }
        }
        guard plane.reduce(0, +) > max(mouth * 0.03, 6) else { return ([Float](repeating: 0, count: n), stats) }
        return (plane, stats)
    }

    /// Otsu's threshold of `values` where `mask` is over a half: the split that best parts dark from light.
    private static func otsu(_ values: [Float], where mask: [Float]) -> Float {
        var histogram = [Float](repeating: 0, count: 256), total: Float = 0
        for i in values.indices where mask[i] > 0.5 { histogram[min(max(Int(values[i] * 255), 0), 255)] += 1; total += 1 }
        guard total > 0 else { return 1 }
        let sum = histogram.indices.reduce(Float(0)) { $0 + Float($1) * histogram[$1] }
        var below: Float = 0, belowSum: Float = 0, best: Float = -1, split = 0
        for t in 0..<256 {
            below += histogram[t]; belowSum += Float(t) * histogram[t]
            let above = total - below
            guard below > 0, above > 0 else { continue }
            let d = belowSum / below - (sum - belowSum) / above
            let between = below * above * d * d
            if between > best { best = between; split = t }
        }
        return (Float(split) + 0.5) / 255
    }

    // MARK: - Shapes

    private struct Outline {
        /// The face: the jaw line (landmarks) closed over the forehead.
        var polygon: [CGPoint]
        /// Around and above the face, where hair is.
        var hairRegion: [CGPoint]
        /// The face's width, pixels.
        var size: CGFloat
    }

    /// The face's outline, upright to the face (a tilted head's forehead follows it). Vision's contour runs
    /// along the jaw from one temple to the other; the forehead is added as an arch above the brows, about
    /// two fifths of the brow-to-chin height (to the hairline, on most faces).
    private static func outline(_ f: FoundFace) -> Outline {
        func centre(_ p: [CGPoint]) -> CGPoint? {
            p.isEmpty ? nil : CGPoint(x: p.reduce(0) { $0 + $1.x } / CGFloat(p.count), y: p.reduce(0) { $0 + $1.y } / CGFloat(p.count))
        }
        func dot(_ p: CGPoint, _ c: CGPoint, _ v: CGVector) -> CGFloat { (p.x - c.x) * v.dx + (p.y - c.y) * v.dy }
        let size = max(f.box.width, 1)
        var across = CGVector(dx: 1, dy: 0)
        if let l = centre(f.leftEye), let r = centre(f.rightEye) {
            let d = hypot(r.x - l.x, r.y - l.y)
            if d > 1 { across = CGVector(dx: (r.x - l.x) / d, dy: (r.y - l.y) / d) }
        }
        var up = CGVector(dx: -across.dy, dy: across.dx)
        let eyes = centre(f.leftEye + f.rightEye) ?? CGPoint(x: f.box.midX, y: f.box.minY + f.box.height * 0.6)
        // Up is away from the chin (the jaw point farthest from the eyes).
        let jaw = f.contour.count >= 5 ? f.contour : [CGPoint(x: f.box.minX, y: f.box.midY), CGPoint(x: f.box.midX, y: f.box.minY),
                                                       CGPoint(x: f.box.maxX, y: f.box.midY)]
        let chinPoint = jaw.max { hypot($0.x - eyes.x, $0.y - eyes.y) < hypot($1.x - eyes.x, $1.y - eyes.y) } ?? eyes
        if dot(chinPoint, eyes, up) > 0 { up = CGVector(dx: -up.dx, dy: -up.dy) }

        let first = jaw[0], last = jaw[jaw.count - 1]
        let c = CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2)
        let a = CGVector(dx: last.x - c.x, dy: last.y - c.y)
        let chin = jaw.map { dot($0, c, up) }.min() ?? -size / 2
        let browTop = (f.leftBrow + f.rightBrow).map { dot($0, c, up) }.max() ?? size * 0.15
        let top = max(browTop + 0.4 * (browTop - chin), size * 0.2)
        // The arch from the last jaw point over the forehead back to the first.
        let arch = (0...16).map { i -> CGPoint in
            let t = CGFloat.pi * CGFloat(i) / 16
            return CGPoint(x: c.x + a.dx * cos(t) + up.dx * top * sin(t), y: c.y + a.dy * cos(t) + up.dy * top * sin(t))
        }
        let half = max(hypot(a.dx, a.dy), size / 2) * 2.2
        let low = chin * 0.5, high = top + 2.5 * (top - chin)
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: c.x + across.dx * x + up.dx * y, y: c.y + across.dy * x + up.dy * y)
        }
        return Outline(polygon: jaw + arch, hairRegion: [at(-half, low), at(half, low), at(half, high), at(-half, high)], size: size)
    }

    /// Points made bigger (or smaller) about their middle.
    private static func grown(_ points: [CGPoint], _ k: CGFloat) -> [CGPoint] {
        guard !points.isEmpty else { return points }
        let cx = points.reduce(0) { $0 + $1.x } / CGFloat(points.count), cy = points.reduce(0) { $0 + $1.y } / CGFloat(points.count)
        return points.map { CGPoint(x: cx + ($0.x - cx) * k, y: cy + ($0.y - cy) * k) }
    }

    /// Shapes filled (and their outlines drawn `line` wide), 0…1 at this size, rows from the top.
    private static func fill(_ shapes: [[CGPoint]], _ w: Int, _ h: Int, line: CGFloat = 0) -> [Float] {
        var bytes = [UInt8](repeating: 0, count: w * h)
        bytes.withUnsafeMutableBytes { raw in
            guard let c = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            c.setFillColor(gray: 1, alpha: 1)
            c.setStrokeColor(gray: 1, alpha: 1)
            c.setLineWidth(line)
            c.setLineCap(.round)
            c.setLineJoin(.round)
            for shape in shapes where shape.count >= 2 {
                if shape.count >= 3 {
                    c.beginPath(); c.addLines(between: shape); c.closePath(); c.fillPath()
                }
                if line > 0 { c.beginPath(); c.addLines(between: shape); c.strokePath() }
            }
        }
        return bytes.map { Float($0) / 255 }
    }

    // MARK: - Colours

    private struct SkinModel {
        var cb: Float, cr: Float, spreadCb: Float, spreadCr: Float
        /// Chroma for its lightness (cb/y, cr/y): stays put as the light dims, so a dark shirt under coloured light
        /// (little lightness, a lot of the light's colour) is told from skin.
        var rcb: Float, rcr: Float, spreadRcb: Float, spreadRcr: Float
        var luma: Float, spreadLuma: Float
    }

    /// The skin's colour (means and spreads) where `core` is, leaving out the near-black and near-white.
    private static func skinModel(_ core: [Float], _ scan: FaceScan) -> SkinModel? {
        var n: Float = 0
        var sums = [Float](repeating: 0, count: 5), squares = sums
        for i in core.indices where core[i] > 0.5 && scan.luma[i] > 0.06 && scan.luma[i] < 0.97 {
            let y = scan.luma[i], v = [scan.cb[i], scan.cr[i], scan.cb[i] / y, scan.cr[i] / y, y]
            n += 1
            for k in 0..<5 { sums[k] += v[k]; squares[k] += v[k] * v[k] }
        }
        guard n >= 20 else { return nil }
        let mean = sums.map { $0 / n }
        let spread = (0..<5).map { sqrt(max(squares[$0] / n - mean[$0] * mean[$0], 0)) }
        return SkinModel(cb: mean[0], cr: mean[1], spreadCb: max(spread[0], 0.012), spreadCr: max(spread[1], 0.012),
                         rcb: mean[2], rcr: mean[3], spreadRcb: max(spread[2], 0.04), spreadRcr: max(spread[3], 0.04),
                         luma: mean[4], spreadLuma: max(spread[4], 0.03))
    }

    /// How skin-like each pixel is (1 within `spread` − 1 spreads of the face's skin, 0 past `spread` + 1), by chroma.
    /// `strict` (skin away from the face): also its chroma for its lightness, and a lightness near the face's, so a much
    /// darker shirt or hair isn't skin. Without a model: all 1, or all 0 when strict (no skin known to match).
    private static func skinLikeness(_ model: SkinModel?, _ scan: FaceScan, spread: Float, strict: Bool) -> [Float] {
        guard let m = model else { return [Float](repeating: strict ? 0 : 1, count: scan.luma.count) }
        return scan.luma.indices.map { i in
            let a = (scan.cb[i] - m.cb) / m.spreadCb, b = (scan.cr[i] - m.cr) / m.spreadCr
            let like = 1 - step(spread - 1, spread + 1, sqrt(a * a + b * b))
            guard strict, like > 0 else { return like }
            let y = max(scan.luma[i], 0.02)
            let ra = (scan.cb[i] / y - m.rcb) / m.spreadRcb, rb = (scan.cr[i] / y - m.rcr) / m.spreadRcr
            let ratio = 1 - step(spread - 1, spread + 1, sqrt(ra * ra + rb * rb))
            let light = 1 - step(spread - 1, spread + 1, abs(scan.luma[i] - m.luma) / m.spreadLuma)
            return like * ratio * light
        }
    }

    private static func step(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / max(b - a, 1e-5), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
