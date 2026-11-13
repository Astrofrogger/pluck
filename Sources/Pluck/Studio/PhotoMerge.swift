import CoreImage
import Foundation
import simd
import Vision

/// Several frames made into one photo: an exposure bracket into one HDR picture, overlapping frames into a panorama, or
/// frames focused at different depths into one sharp throughout. Pure functions on decoded frames (scene-linear light,
/// Core Image's working space); the result is linear too, ready for PhotoDNG.write. The looking (alignment, exposure,
/// overlap) is done on small copies; the picture itself stays a lazy Core Image graph, so a merge of 60 MP frames is only
/// ever drawn a tile (or a DNG strip) at a time.
enum PhotoMerge {
    enum MergeError: LocalizedError {
        case notEnoughFrames, couldNotAlign, sizesDiffer, tooWide

        var errorDescription: String? {
            switch self {
            case .notEnoughFrames: String(localized: "Choose at least two photos to merge.")
            case .couldNotAlign: String(localized: "The photos couldn’t be lined up. Check they overlap and show the same scene.")
            case .sizesDiffer: String(localized: "The photos aren’t the same size. Merge photos from the same camera and setting.")
            case .tooWide: String(localized: "This panorama is too wide to merge. Try fewer photos (up to about half a turn).")
            }
        }
    }

    // MARK: - HDR

    /// An exposure bracket merged into one picture at the middle frame's exposure, with the dark frames' highlights and the
    /// bright frames' shadows. `exposures`: each frame's exposure in stops (log2 of time × ISO / f², any common offset),
    /// from EXIF; nil: worked out from the pictures.
    ///
    /// Each frame is lined up on the reference (Vision, on small copies), brought to its exposure, and weighed per pixel: a
    /// smooth hat in log light, nothing within 0.2 stops of the frame's own clip point and full weight from 1.5 stops under,
    /// times its exposure (a longer exposure has less noise for the same light), fading out in the deep shadows. The
    /// brightest frame keeps its shadows and the darkest its highlights (nothing better has them), so no pixel is left
    /// without a frame. The weights are worked out on a slightly grown (local-maximum) picture and then blurred, so a
    /// clipped pixel never gets weight from a blurred neighbour and the hand-over between frames has no seam.
    /// Deghosting: where a frame, brought to the reference's exposure, differs from it (luminance, lightly blurred) by more
    /// than 0.2 to 0.4 stops and the reference isn't clipped there, its weight goes, so something that moved comes from the
    /// reference alone. (Half a stop let too much through: the brighter frames weigh four times more, so a near match
    /// still won.) Where the reference is clipped it only says "at least this bright", so there a frame goes only if it's
    /// darker than that. The reference keeps a trace of weight everywhere, so a pixel every other frame lost isn't empty.
    nonisolated static func hdr(_ frames: [CIImage], exposures: [Double]?, context: CIContext) throws -> CIImage {
        guard frames.count >= 2 else { throw MergeError.notEnoughFrames }
        guard exposures == nil || exposures!.count == frames.count else { throw MergeError.notEnoughFrames }
        try checkSizes(frames)
        guard let level, let weight, let accumulate, let divide else { throw MergeError.couldNotAlign }
        let smalls = frames.map { small($0, context: context) }
        // Exposures as given, or the frames' average light, to find the order (and the reference: the middle one).
        let stops = exposures ?? smalls.map { log2(max(Double($0.mean), 1e-9)) }
        let order = frames.indices.sorted { stops[$0] < stops[$1] }
        let ref = order[order.count / 2], darkest = order.first!, brightest = order.last!
        let extent = frames[ref].extent

        // Each frame's clip point, per channel (white balance clips the channels at different levels).
        let clips = smalls.map { $0.maximum }
        var gains = [Double](repeating: 1, count: frames.count)
        var maps = [simd_double3x3](repeating: matrix_identity_double3x3, count: frames.count)
        let refPreview = preview(smalls[ref], gain: 0.18 / max(smalls[ref].mean, 1e-6), context: context)
        for i in frames.indices where i != ref {
            // Brought to about the same brightness for Vision, which compares the pictures as they look.
            let rough = exposures.map { pow(2, $0[ref] - $0[i]) } ?? Double(smalls[ref].mean / max(smalls[i].mean, 1e-9))
            let moving = preview(smalls[i], gain: 0.18 / max(smalls[ref].mean, 1e-6) * Float(rough), context: context)
            guard let h = register(moving, onto: refPreview, homographic: true, size: smalls[ref].size, strict: true)
                    ?? register(moving, onto: refPreview, homographic: false, size: smalls[ref].size, strict: true) else { throw MergeError.couldNotAlign }
            maps[i] = h.inverse // reference → frame
            if let exposures {
                gains[i] = pow(2, exposures[ref] - exposures[i])
            } else {
                gains[i] = ratio(smalls[ref], smalls[i], map: h.inverse, clipA: clips[ref], clipB: clips[i]) ?? rough
            }
        }

        let long = max(extent.width, extent.height)
        // The weights' blur (σ) and how far the clipped areas are grown first: three σ, so a blurred weight never reaches
        // a clipped pixel.
        let soften = max(1, long / 2000), grow = (3 * soften).rounded(.up)
        let lowest = stops[darkest]
        let refFrame = frames[ref]
        let refLevel = level.apply(extent: extent, arguments: [refFrame, vector(clips[ref])])!.clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": grow]).cropped(to: extent)
        let refLight = luminance(refFrame).clampedToExtent().applyingGaussianBlur(sigma: soften).cropped(to: extent)
        let noise = Double(dot(clips[ref], SIMD3(0.2126, 0.7152, 0.0722))) / 256

        var sum = CIImage(color: .clear).cropped(to: extent), total = sum
        for i in frames.indices {
            let full = scale(fullMap(maps[i], from: smalls[ref], to: smalls[i]))
            let aligned = i == ref ? frames[i] : warp(frames[i], map: full, cylinder: nil, extent: extent, clamp: true)
            let normal = gain(aligned, gains[i])
            let own = level.apply(extent: extent, arguments: [aligned, vector(clips[i])])!.clampedToExtent()
                .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": grow]).cropped(to: extent)
            let light = luminance(normal).clampedToExtent().applyingGaussianBlur(sigma: soften).cropped(to: extent)
            // Exposure relative to the darkest frame, as the weight for its lower noise.
            let factor = exposures.map { pow(2, $0[i] - lowest) } ?? (gains[darkest] / gains[i])
            let w = weight.apply(extent: extent, arguments: [own, light, refLight, refLevel, factor, i == brightest ? 0 : 1,
                                                             i == darkest ? 0 : 1, i == ref ? 0 : 1, noise])!
                .clampedToExtent().applyingGaussianBlur(sigma: soften).cropped(to: extent)
            sum = accumulate.apply(extent: extent, arguments: [sum, normal, w])!
            total = accumulate.apply(extent: extent, arguments: [total, CIImage(color: .white).cropped(to: extent), w])!
        }
        return divide.apply(extent: extent, arguments: [sum, total])!
    }

    // MARK: - Panorama

    /// Overlapping frames, in shooting order (each overlaps the next), stitched round the middle one.
    ///
    /// Neighbours are lined up on small copies: a correlation search finds where they meet (they must share a quarter of
    /// the picture or more), then Vision's homography is worked out on the shared part alone (on whole frames that only
    /// partly overlap it fails or misplaces them); the pairs are chained to the middle frame. A set taken by
    /// turning the camera is projected on a cylinder (its focal length worked out from the homographies, or taken as the
    /// frame's long side if that fails), so it stays even out to half a turn; a set that's only shifted or turned in the
    /// picture's plane (no perspective between frames) is laid flat. Neighbours' exposure is matched by the median ratio
    /// of their shared light; the frames are blended with weights falling to nothing at each frame's edges, and the
    /// result is cropped to the largest rectangle every part of which is covered (no empty corners).
    /// Fails with `.tooWide` past half a turn, or when a flat set would grow too large.
    nonisolated static func panorama(_ frames: [CIImage], context: CIContext) throws -> CIImage {
        guard frames.count >= 2 else { throw MergeError.notEnoughFrames }
        try checkSizes(frames, tolerance: 0.5)
        guard let accumulate, let divide, let feather else { throw MergeError.couldNotAlign }
        let smalls = frames.map { small($0, context: context) }
        let previews = smalls.map { preview($0, gain: 0.18 / max($0.mean, 1e-6), context: context) }
        let n = frames.count, mid = n / 2

        // Neighbours: next → this one (small copies' pixels).
        var pairs: [simd_double3x3] = []
        for i in 0..<(n - 1) {
            guard let h = overlapRegistration(previews[i + 1], onto: previews[i], smalls: (smalls[i + 1], smalls[i])) else { throw MergeError.couldNotAlign }
            pairs.append(h)
        }
        // Each frame → middle frame, full size.
        var toMid = [simd_double3x3](repeating: matrix_identity_double3x3, count: n)
        for i in stride(from: mid + 1, to: n, by: 1) { toMid[i] = toMid[i - 1] * fullMap(pairs[i - 1], from: smalls[i], to: smalls[i - 1]) }
        for i in stride(from: mid - 1, through: 0, by: -1) { toMid[i] = toMid[i + 1] * fullMap(pairs[i], from: smalls[i + 1], to: smalls[i]).inverse }
        toMid = toMid.map(scale)

        // Exposure: each neighbour's light against this one's where they share the picture, chained to the middle.
        var gains = [Double](repeating: 1, count: n)
        for i in stride(from: mid + 1, to: n, by: 1) {
            gains[i] = gains[i - 1] * (ratio(smalls[i - 1], smalls[i], map: pairs[i - 1].inverse, clipA: smalls[i - 1].maximum, clipB: smalls[i].maximum) ?? 1)
        }
        for i in stride(from: mid - 1, through: 0, by: -1) {
            gains[i] = gains[i + 1] / (ratio(smalls[i], smalls[i + 1], map: pairs[i].inverse, clipA: smalls[i].maximum, clipB: smalls[i + 1].maximum) ?? 1)
        }

        // The projection: a cylinder round the middle frame's centre, unless there's no perspective between the frames.
        let centre = CGPoint(x: frames[mid].extent.midX, y: frames[mid].extent.midY)
        let fullPairs = (0..<(n - 1)).map { scale(fullMap(pairs[$0], from: smalls[$0 + 1], to: smalls[$0])) }
        let focal = focalLength(fullPairs, frames: frames)
        let cylinder: SIMD3<Double>? = focal.map { SIMD3($0, Double(centre.x), Double(centre.y)) }
        let fromMid = toMid.map { $0.inverse }

        // Where each frame lands: its edges, taken into the panorama.
        var bounds = CGRect.null
        for i in 0..<n {
            let e = frames[i].extent
            for k in 0...32 {
                let t = CGFloat(k) / 32
                for p in [CGPoint(x: e.minX + t * e.width, y: e.minY), CGPoint(x: e.minX + t * e.width, y: e.maxY),
                          CGPoint(x: e.minX, y: e.minY + t * e.height), CGPoint(x: e.maxX, y: e.minY + t * e.height)] {
                    guard let q = panoramaPoint(p, toMid: toMid[i], cylinder: cylinder) else { throw MergeError.tooWide }
                    bounds = bounds.union(CGRect(origin: q, size: .zero))
                }
            }
        }
        let area = frames.reduce(0) { $0 + $1.extent.width * $1.extent.height }
        if let focal, bounds.width / focal > .pi { throw MergeError.tooWide }
        guard !bounds.isNull, bounds.width * bounds.height < 6 * area else { throw MergeError.tooWide }

        // The clean rectangle, on a grid of about 1000 cells across.
        let cell = max(bounds.width, bounds.height) / 1000
        let columns = Int(bounds.width / cell) + 1, rows = Int(bounds.height / cell) + 1
        var covered = [Bool](repeating: false, count: columns * rows)
        for r in 0..<rows {
            for c in 0..<columns {
                let d = CGPoint(x: bounds.minX + (CGFloat(c) + 0.5) * cell, y: bounds.minY + (CGFloat(r) + 0.5) * cell)
                covered[r * columns + c] = (0..<n).contains { i in
                    sourcePoint(d, map: fromMid[i], cylinder: cylinder).map { frames[i].extent.insetBy(dx: 1, dy: 1).contains($0) } ?? false
                }
            }
        }
        let best = largestRectangle(covered, columns: columns, rows: rows)
        let crop = CGRect(x: bounds.minX + CGFloat(best.minX + 1) * cell, y: bounds.minY + CGFloat(best.minY + 1) * cell,
                          width: CGFloat(best.width - 2) * cell, height: CGFloat(best.height - 2) * cell).integral
        guard crop.width > 16, crop.height > 16 else { throw MergeError.couldNotAlign }

        var sum = CIImage(color: .clear).cropped(to: crop), total = sum
        for i in 0..<n {
            let picture = warp(gain(frames[i], gains[i]), map: fromMid[i], cylinder: cylinder, extent: crop, clamp: true)
            let e = frames[i].extent
            let edges = feather.apply(extent: e, arguments: [CIVector(cgRect: e)])!
            let w = warp(edges, map: fromMid[i], cylinder: cylinder, extent: crop, clamp: false)
            sum = accumulate.apply(extent: crop, arguments: [sum, picture, w])!
            total = accumulate.apply(extent: crop, arguments: [total, CIImage(color: .white).cropped(to: crop), w])!
        }
        let made = divide.apply(extent: crop, arguments: [sum, total])!
        return made.transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
    }

    // MARK: - Focus stack

    /// Frames focused at different distances, merged so each part comes from the frame where it's sharpest.
    /// Lined up on the middle frame with a homography, which takes in the small change of scale as the focus moves
    /// ("breathing"). Sharpness is the absolute Laplacian of the square root of luminance (so shadows count, not only
    /// bright edges), blurred over about a thousandth of the picture; each frame's weight is its sharpness over the
    /// sharpest frame's at that pixel, to the fourth power: the sharpest frame dominates, but the hand-over is soft.
    nonisolated static func focusStack(_ frames: [CIImage], context: CIContext) throws -> CIImage {
        guard frames.count >= 2 else { throw MergeError.notEnoughFrames }
        try checkSizes(frames)
        guard let accumulate, let divide, let root, let magnitude, let share else { throw MergeError.couldNotAlign }
        let smalls = frames.map { small($0, context: context) }
        let ref = frames.count / 2
        let extent = frames[ref].extent
        let refPreview = preview(smalls[ref], gain: 0.18 / max(smalls[ref].mean, 1e-6), context: context)
        let long = max(extent.width, extent.height)
        let soften = max(2, long / 1000)

        var aligned: [CIImage] = []
        var sharpness: [CIImage] = []
        for i in frames.indices {
            var picture = frames[i]
            if i != ref {
                let moving = preview(smalls[i], gain: 0.18 / max(smalls[ref].mean, 1e-6), context: context)
                guard let h = register(moving, onto: refPreview, homographic: true, size: smalls[ref].size, strict: true)
                        ?? register(moving, onto: refPreview, homographic: false, size: smalls[ref].size, strict: true) else { throw MergeError.couldNotAlign }
                picture = warp(frames[i], map: scale(fullMap(h.inverse, from: smalls[ref], to: smalls[i])), cylinder: nil, extent: extent, clamp: true)
            }
            aligned.append(picture)
            let laplacian = root.apply(extent: extent, arguments: [picture])!.clampedToExtent()
                .applyingFilter("CIConvolution3X3", parameters: ["inputWeights": CIVector(values: [0, 1, 0, 1, -4, 1, 0, 1, 0], count: 9), "inputBias": 0])
            sharpness.append(magnitude.apply(extent: extent, arguments: [laplacian])!.clampedToExtent().applyingGaussianBlur(sigma: soften).cropped(to: extent))
        }
        // The sharpest at each pixel, so each weight is a share of it (never too small or large for half floats).
        let top = sharpness.dropFirst().reduce(sharpness[0]) { $0.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: $1]) }
        var sum = CIImage(color: .clear).cropped(to: extent), total = sum
        for i in frames.indices {
            let w = share.apply(extent: extent, arguments: [sharpness[i], top])!
            sum = accumulate.apply(extent: extent, arguments: [sum, aligned[i], w])!
            total = accumulate.apply(extent: extent, arguments: [total, CIImage(color: .white).cropped(to: extent), w])!
        }
        return divide.apply(extent: extent, arguments: [sum, total])!
    }

    // MARK: - Small copies

    /// A frame made small for looking at: linear light, long side about 1600, from (0, 0).
    private struct Small {
        let image: CIImage
        let pixels: [Float] // RGBA
        let width: Int, height: Int
        /// Small pixels per full pixel, and the full frame's corner.
        let scale: CGFloat, origin: CGPoint
        var size: CGSize { CGSize(width: width, height: height) }
        /// Average luminance, and the brightest value per channel (the clip point).
        let mean: Float
        let maximum: SIMD3<Float>

        func luminance(_ x: Int, _ y: Int) -> Float {
            let p = 4 * (y * width + x)
            return 0.2126 * pixels[p] + 0.7152 * pixels[p + 1] + 0.0722 * pixels[p + 2]
        }
    }

    private static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    nonisolated private static func small(_ image: CIImage, side: CGFloat = 1600, context: CIContext) -> Small {
        let e = image.extent
        let s = min(1, side / max(e.width, e.height))
        let moved = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        let scaled = s < 1 ? moved.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1]) : moved
        let w = max(1, Int(scaled.extent.width)), h = max(1, Int(scaled.extent.height))
        var pixels = [Float](repeating: 0, count: w * h * 4)
        context.render(scaled, toBitmap: &pixels, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: linear)
        var sum: Float = 0
        for p in stride(from: 0, to: pixels.count, by: 4) {
            let c = SIMD3(pixels[p], pixels[p + 1], pixels[p + 2])
            if c.x.isNaN || c.y.isNaN || c.z.isNaN { pixels[p] = 0; pixels[p + 1] = 0; pixels[p + 2] = 0; continue }
            sum += 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
        }
        // The clip point from the full frame: the small copy's resampling rings past it at the edge of a clipped area
        // (measured: up to about a fifth over), which then left clipped pixels some weight.
        var top = [Float](repeating: 0, count: 4)
        context.render(image.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: e)]), toBitmap: &top, rowBytes: 16,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: linear)
        // (The bitmap's first row is the top; as a CIImage it's the right way up again.)
        let made = CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: w * 16, size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: linear)
        return Small(image: made, pixels: pixels, width: w, height: h, scale: s, origin: e.origin, mean: sum / Float(w * h), maximum: simd_max(SIMD3(top[0], top[1], top[2]), SIMD3(repeating: 1e-6)))
    }

    /// A small copy as Vision sees it: brightened by `gain`, sRGB, 8 bits.
    nonisolated private static func preview(_ s: Small, gain k: Float, context: CIContext) -> CGImage {
        context.createCGImage(gain(s.image, Double(k)), from: CGRect(origin: .zero, size: s.size), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
    }

    /// Small-copy pixels in the `bitmap` (rows from the top) as Core Image counts them (from the bottom).
    nonisolated private static func flip(_ y: Int, _ s: Small) -> Int { s.height - 1 - y }

    // MARK: - Lining up

    /// `moving` taken onto `reference` (small copies' pixels, Core Image's way up): Vision's homography, or its translation.
    /// Nil if Vision can't, or what it finds is implausible (`strict`: a bracket or stack, which barely moves).
    nonisolated private static func register(_ moving: CGImage, onto reference: CGImage, homographic: Bool, size: CGSize, strict: Bool) -> simd_double3x3? {
        let handler = VNImageRequestHandler(cgImage: reference)
        var h: simd_double3x3?
        if homographic {
            let request = VNHomographicImageRegistrationRequest(targetedCGImage: moving)
            if (try? handler.perform([request])) != nil, let o = request.results?.first as? VNImageHomographicAlignmentObservation {
                let m = o.warpTransform
                h = simd_double3x3(columns: (SIMD3<Double>(m.columns.0), SIMD3<Double>(m.columns.1), SIMD3<Double>(m.columns.2)))
            }
        } else {
            let request = VNTranslationalImageRegistrationRequest(targetedCGImage: moving)
            if (try? handler.perform([request])) != nil, let o = request.results?.first as? VNImageTranslationAlignmentObservation {
                let t = o.alignmentTransform
                h = simd_double3x3(rows: [SIMD3(1, 0, Double(t.tx)), SIMD3(0, 1, Double(t.ty)), SIMD3(0, 0, 1)])
            }
        }
        guard var h, abs(h[2][2]) > 1e-9 else { return nil }
        h = h * (1 / h[2][2])
        let det = h[0][0] * h[1][1] - h[1][0] * h[0][1]
        let shift = hypot(h[2][0] / Double(size.width), h[2][1] / Double(size.height))
        let tilt = abs(h[0][2]) * Double(size.width) + abs(h[1][2]) * Double(size.height)
        if strict { guard det > 0.8, det < 1.25, shift < 0.15, tilt < 0.05 else { return nil } }
        else { guard det > 0.5, det < 2, tilt < 0.8 else { return nil } }
        return h
    }

    /// Neighbours in a panorama: a search for where they meet (`offset`), then Vision's homography worked out on the shared
    /// part alone (Vision gives up on, or misplaces, pictures that only partly overlap).
    nonisolated private static func overlapRegistration(_ moving: CGImage, onto reference: CGImage, smalls: (Small, Small)) -> simd_double3x3? {
        let sizes = (smalls.0.size, smalls.1.size)
        guard let t = offset(smalls.0, onto: smalls.1) else { return nil }
        let shift = CGPoint(x: t[2][0], y: t[2][1])
        let shared = CGRect(origin: .zero, size: sizes.1).intersection(CGRect(origin: shift, size: sizes.0)).integral
        guard shared.width > 0.1 * sizes.1.width || shared.height > 0.1 * sizes.1.height, shared.width > 32, shared.height > 32 else { return nil }
        // Crops in CGImage terms count rows from the top.
        func crop(_ image: CGImage, _ r: CGRect) -> CGImage? {
            image.cropping(to: CGRect(x: r.minX, y: CGFloat(image.height) - r.maxY, width: r.width, height: r.height))
        }
        let inMoving = shared.offsetBy(dx: -shift.x, dy: -shift.y).integral
        guard let a = crop(reference, shared), let b = crop(moving, CGRect(origin: inMoving.origin, size: shared.size)),
              let local = register(b, onto: a, homographic: true, size: shared.size, strict: false) else { return t }
        let into = simd_double3x3(rows: [SIMD3(1, 0, Double(shared.minX)), SIMD3(0, 1, Double(shared.minY)), SIMD3(0, 0, 1)])
        let outOf = simd_double3x3(rows: [SIMD3(1, 0, -Double(inMoving.minX)), SIMD3(0, 1, -Double(inMoving.minY)), SIMD3(0, 0, 1)])
        let h = into * local * outOf
        // Trust the homography only if it agrees with the translation about where the middle of the shared part goes.
        let c = SIMD3(Double(inMoving.midX), Double(inMoving.midY), 1)
        let a1 = h * c, a2 = t * c
        return hypot(a1.x / a1.z - a2.x, a1.y / a1.z - a2.y) < 0.05 * Double(max(shared.width, shared.height)) ? h : t
    }

    /// Where `moving` sits on `reference` (a translation, small pixels, Core Image's way up), for pictures that overlap by a
    /// quarter or more: normalised cross-correlation of log luminance (so a difference in exposure doesn't matter), every
    /// placement tried on copies about 96 pixels across, then refined ±2 pixels at each size up. Nil if nothing fits well.
    nonisolated private static func offset(_ moving: Small, onto reference: Small) -> simd_double3x3? {
        struct Grey { var w: Int, h: Int, v: [Float] }
        func grey(_ s: Small) -> Grey {
            Grey(w: s.width, h: s.height, v: (0..<(s.width * s.height)).map { log(max(s.luminance($0 % s.width, $0 / s.width), 0) + 1e-4) })
        }
        func half(_ g: Grey) -> Grey {
            let w = g.w / 2, h = g.h / 2
            var v = [Float](repeating: 0, count: w * h)
            for y in 0..<h { for x in 0..<w {
                v[y * w + x] = 0.25 * (g.v[2 * y * g.w + 2 * x] + g.v[2 * y * g.w + 2 * x + 1] + g.v[(2 * y + 1) * g.w + 2 * x] + g.v[(2 * y + 1) * g.w + 2 * x + 1])
            } }
            return Grey(w: w, h: h, v: v)
        }
        var a = [grey(moving)], b = [grey(reference)]
        while max(a.last!.w, a.last!.h, b.last!.w, b.last!.h) > 96 { a.append(half(a.last!)); b.append(half(b.last!)) }
        /// Correlation with moving's (x, y) on reference's (x + dx, y + dy), rows from the top; nil under a quarter shared.
        func score(_ a: Grey, _ b: Grey, _ dx: Int, _ dy: Int) -> Float? {
            let x0 = max(0, -dx), x1 = min(a.w, b.w - dx), y0 = max(0, -dy), y1 = min(a.h, b.h - dy)
            guard x1 > x0, y1 > y0, (x1 - x0) * (y1 - y0) * 4 >= min(a.w * a.h, b.w * b.h) else { return nil }
            var sa: Float = 0, sb: Float = 0, saa: Float = 0, sbb: Float = 0, sab: Float = 0
            for y in y0..<y1 {
                let ra = y * a.w, rb = (y + dy) * b.w + dx
                for x in x0..<x1 { let p = a.v[ra + x], q = b.v[rb + x]; sa += p; sb += q; saa += p * p; sbb += q * q; sab += p * q }
            }
            let n = Float((x1 - x0) * (y1 - y0))
            let va = saa - sa * sa / n, vb = sbb - sb * sb / n
            return va > 0 && vb > 0 ? (sab - sa * sb / n) / sqrt(va * vb) : nil
        }
        var best: (Float, Int, Int) = (-2, 0, 0)
        let top = a.count - 1
        for dy in -a[top].h...b[top].h { for dx in -a[top].w...b[top].w {
            if let c = score(a[top], b[top], dx, dy), c > best.0 { best = (c, dx, dy) }
        } }
        for level in stride(from: top - 1, through: 0, by: -1) {
            let (cx, cy) = (2 * best.1, 2 * best.2)
            best.0 = -2
            for dy in (cy - 2)...(cy + 2) { for dx in (cx - 2)...(cx + 2) {
                if let c = score(a[level], b[level], dx, dy), c > best.0 { best = (c, dx, dy) }
            } }
        }
        guard best.0 > 0.3 else { return nil }
        // Rows from the top → Core Image's y, up from the bottom.
        let ty = Double(reference.height - moving.height - best.2)
        return simd_double3x3(rows: [SIMD3(1, 0, Double(best.1)), SIMD3(0, 1, ty), SIMD3(0, 0, 1)])
    }

    /// A small-copy map (`from` pixels → `to` pixels) as a full-size one.
    nonisolated private static func fullMap(_ h: simd_double3x3, from: Small, to: Small) -> simd_double3x3 {
        func frame(_ s: Small) -> simd_double3x3 {
            simd_double3x3(rows: [SIMD3(1 / Double(s.scale), 0, Double(s.origin.x)), SIMD3(0, 1 / Double(s.scale), Double(s.origin.y)), SIMD3(0, 0, 1)])
        }
        return frame(to) * h * frame(from).inverse
    }

    nonisolated private static func scale(_ h: simd_double3x3) -> simd_double3x3 { abs(h[2][2]) > 1e-12 ? h * (1 / h[2][2]) : h }

    /// How much brighter `a` is than `b` (median ratio of their light where both are well exposed); `map`: a's small pixels
    /// → b's. Nil with too little shared, well-exposed picture.
    nonisolated private static func ratio(_ a: Small, _ b: Small, map: simd_double3x3, clipA: SIMD3<Float>, clipB: SIMD3<Float>) -> Double? {
        var ratios: [Float] = []
        let step = max(1, Int(sqrt(Double(a.width * a.height) / 200_000)))
        let ca = 0.2126 * clipA.x + 0.7152 * clipA.y + 0.0722 * clipA.z, cb = 0.2126 * clipB.x + 0.7152 * clipB.y + 0.0722 * clipB.z
        for y in stride(from: 0, to: a.height, by: step) {
            for x in stride(from: 0, to: a.width, by: step) {
                let ciY = Double(flip(y, a)) + 0.5
                let q = map * SIMD3(Double(x) + 0.5, ciY, 1)
                guard q.z > 0 else { continue }
                let bx = Int(q.x / q.z), by = flip(Int(q.y / q.z), b)
                guard bx >= 0, bx < b.width, by >= 0, by < b.height else { continue }
                let la = a.luminance(x, y), lb = b.luminance(bx, by)
                let ma = maxShare(a, x, y, clipA), mb = maxShare(b, bx, by, clipB)
                guard ma < 0.7, mb < 0.7, la > ca / 128, lb > cb / 128 else { continue }
                ratios.append(la / lb)
            }
        }
        guard ratios.count > 200 else { return nil }
        ratios.sort()
        return Double(ratios[ratios.count / 2])
    }

    nonisolated private static func maxShare(_ s: Small, _ x: Int, _ y: Int, _ clip: SIMD3<Float>) -> Float {
        let p = 4 * (y * s.width + x)
        return max(s.pixels[p] / clip.x, s.pixels[p + 1] / clip.y, s.pixels[p + 2] / clip.z)
    }

    /// Frames from one camera are the same size; a few pixels' difference (a crop) is let through.
    nonisolated private static func checkSizes(_ frames: [CIImage], tolerance: CGFloat = 0.05) throws {
        let first = frames[0].extent
        for f in frames {
            guard !f.extent.isInfinite, f.extent.width >= 64, f.extent.height >= 64,
                  abs(f.extent.width / first.width - 1) <= tolerance, abs(f.extent.height / first.height - 1) <= tolerance else { throw MergeError.sizesDiffer }
        }
    }

    // MARK: - Panorama geometry

    /// Focal length (pixels) from neighbours' homographies (a camera turning about its centre: H = K R K⁻¹, solved for
    /// K's focal length as in Szeliski and Shum's formulas, on centred pixels). Nil when there's no perspective between
    /// the frames (a flat set); the frame's long side when the formulas don't give a usable answer.
    nonisolated private static func focalLength(_ pairs: [simd_double3x3], frames: [CIImage]) -> Double? {
        var found: [Double] = []
        var flat = true
        for (i, h) in pairs.enumerated() {
            let a = frames[i].extent, b = frames[i + 1].extent
            let toA = simd_double3x3(rows: [SIMD3(1, 0, -Double(a.midX)), SIMD3(0, 1, -Double(a.midY)), SIMD3(0, 0, 1)])
            let fromB = simd_double3x3(rows: [SIMD3(1, 0, Double(b.midX)), SIMD3(0, 1, Double(b.midY)), SIMD3(0, 0, 1)])
            let c = scale(toA * h * fromB) // centred b → centred a
            if abs(c[0][2]) * Double(b.width) + abs(c[1][2]) * Double(b.height) > 0.01 { flat = false }
            // Row-major entries, as the formulas are written (simd is column-major).
            let m = [c[0][0], c[1][0], c[2][0], c[0][1], c[1][1], c[2][1], c[0][2], c[1][2], c[2][2]]
            func solve(_ d1: Double, _ d2: Double, _ v1: Double, _ v2: Double) -> Double? {
                let (hi, lo) = (max(v1, v2), min(v1, v2))
                if hi > 0, lo > 0 { return sqrt(abs(d1) > abs(d2) ? v1 : v2) }
                return hi > 0 ? sqrt(hi) : nil
            }
            var d1 = m[6] * m[7], d2 = (m[7] - m[6]) * (m[7] + m[6])
            let f1 = solve(d1, d2, -(m[0] * m[1] + m[3] * m[4]) / d1, (m[0] * m[0] + m[3] * m[3] - m[1] * m[1] - m[4] * m[4]) / d2)
            d1 = m[0] * m[3] + m[1] * m[4]; d2 = m[0] * m[0] + m[1] * m[1] - m[3] * m[3] - m[4] * m[4]
            let f0 = solve(d1, d2, -m[2] * m[5] / d1, (m[5] * m[5] - m[2] * m[2]) / d2)
            if let f0, let f1, f0.isFinite, f1.isFinite { found.append(sqrt(f0 * f1)) }
        }
        if flat { return nil }
        let long = Double(max(frames[0].extent.width, frames[0].extent.height))
        found = found.filter { $0 > 0.3 * long && $0 < 20 * long }.sorted()
        return found.isEmpty ? long : found[found.count / 2]
    }

    /// A frame's pixel in the panorama (nil if it's behind the middle frame's camera, on a flat set).
    nonisolated private static func panoramaPoint(_ p: CGPoint, toMid: simd_double3x3, cylinder: SIMD3<Double>?) -> CGPoint? {
        let q = toMid * SIMD3(Double(p.x), Double(p.y), 1)
        guard let cyl = cylinder else {
            guard q.z > 1e-9 else { return nil }
            return CGPoint(x: q.x / q.z, y: q.y / q.z)
        }
        // The ray through the middle frame's pixel, as an angle round the cylinder and a height on it.
        let f = cyl.x, x = (q.x - cyl.y * q.z) / f, y = (q.y - cyl.z * q.z) / f, z = q.z
        let angle = atan2(x, z), height = y / hypot(x, z)
        return CGPoint(x: cyl.y + f * angle, y: cyl.z + f * height)
    }

    /// Where a panorama (or reference) pixel comes from in a frame: the Swift twin of `warpKernel`.
    nonisolated private static func sourcePoint(_ d: CGPoint, map: simd_double3x3, cylinder: SIMD3<Double>?) -> CGPoint? {
        var p = SIMD3(Double(d.x), Double(d.y), 1)
        if let c = cylinder {
            let a = (p.x - c.y) / c.x
            p = SIMD3(c.x * sin(a) + c.y * cos(a), p.y - c.z + c.z * cos(a), cos(a))
        }
        let q = map * p
        guard q.z > 1e-6 else { return nil }
        return CGPoint(x: q.x / q.z, y: q.y / q.z)
    }

    /// The largest rectangle of covered cells (rows and columns of the grid).
    nonisolated private static func largestRectangle(_ covered: [Bool], columns: Int, rows: Int) -> (minX: Int, minY: Int, width: Int, height: Int) {
        var heights = [Int](repeating: 0, count: columns)
        var best = (minX: 0, minY: 0, width: 0, height: 0)
        for r in 0..<rows {
            for c in 0..<columns { heights[c] = covered[r * columns + c] ? heights[c] + 1 : 0 }
            var stack: [Int] = []
            for c in 0...columns {
                let h = c < columns ? heights[c] : 0
                while let last = stack.last, heights[last] >= h {
                    stack.removeLast()
                    let left = stack.last.map { $0 + 1 } ?? 0
                    if heights[last] * (c - left) > best.width * best.height {
                        best = (left, r - heights[last] + 1, c - left, heights[last])
                    }
                }
                stack.append(c)
            }
        }
        return best
    }

    // MARK: - Drawing

    /// `image` drawn into `extent` through `map` (output pixel → the image's pixel; on a cylinder, see `sourcePoint`).
    /// `clamp`: the edge pixels carry on outside the frame (for colour); otherwise it's transparent there (for a weight,
    /// which must stop at the edge). Every place a tile reads is inside its region of interest: Core Image's samples
    /// outside it are undefined, and a weight leaking past its frame showed as haze along the panorama's edges.
    nonisolated private static func warp(_ image: CIImage, map: simd_double3x3, cylinder: SIMD3<Double>?, extent: CGRect, clamp: Bool) -> CIImage {
        let frame = image.extent
        let rows = [map.transpose[0], map.transpose[1], map.transpose[2]].map { CIVector(x: $0.x, y: $0.y, z: $0.z) }
        let cyl = cylinder.map { CIVector(x: $0.x, y: $0.y, z: $0.z, w: 0) } ?? CIVector(x: 0, y: 0, z: 0, w: 0)
        // Where a ray behind the frame's camera reads: just outside the frame.
        let away = CGPoint(x: frame.minX - 16, y: frame.minY - 16)
        let source = clamp ? image.clampedToExtent() : image.composited(over: CIImage(color: .clear))
        return warpKernel!.apply(extent: extent, roiCallback: { _, rect in
            // The part of the frame a tile needs: its corners, sides and middle taken across, with a margin.
            var need = CGRect.null
            for u in [0, 0.5, 1.0] { for v in [0, 0.5, 1.0] {
                let p = sourcePoint(CGPoint(x: rect.minX + u * rect.width, y: rect.minY + v * rect.height), map: map, cylinder: cylinder) ?? away
                need = need.union(CGRect(origin: p, size: .zero))
            } }
            return need.insetBy(dx: -4 - 0.05 * need.width, dy: -4 - 0.05 * need.height)
        }, image: source, arguments: rows + [cyl, CIVector(cgPoint: away)]) ?? image
    }

    nonisolated private static func gain(_ image: CIImage, _ k: Double) -> CIImage {
        k == 1 ? image : image.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
                                                                             "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                                                                             "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0)])
    }

    nonisolated private static func luminance(_ image: CIImage) -> CIImage {
        let w = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        return image.applyingFilter("CIColorMatrix", parameters: ["inputRVector": w, "inputGVector": w, "inputBVector": w])
    }

    nonisolated private static func vector(_ v: SIMD3<Float>) -> CIVector { CIVector(x: CGFloat(v.x), y: CGFloat(v.y), z: CGFloat(v.z)) }

    /// Output pixel → frame pixel: a homography, after (with cyl.x, the focal length, above 0) the angle and height on a
    /// cylinder round the middle frame's centre (cyl.y, cyl.z) are turned into that frame's pixel. Behind the frame: `away`.
    private static let warpKernel = CIWarpKernel(source: """
        kernel vec2 warp(vec3 r0, vec3 r1, vec3 r2, vec4 cyl, vec2 away) {
            vec2 d = destCoord();
            vec3 p = vec3(d, 1.0);
            if (cyl.x > 0.0) {
                float a = (d.x - cyl.y) / cyl.x;
                p = vec3(cyl.x * sin(a) + cyl.y * cos(a), d.y - cyl.z + cyl.z * cos(a), cos(a));
            }
            vec3 q = vec3(dot(r0, p), dot(r1, p), dot(r2, p));
            return q.z > 0.000001 ? q.xy / q.z : away;
        }
        """)

    /// How near a pixel is to clipping: its highest channel as a share of that channel's clip point.
    private static let level = CIColorKernel(source: """
        kernel vec4 level(__sample c, vec3 clip) { vec3 v = max(c.rgb, 0.0) / clip; float m = max(max(v.r, v.g), v.b); return vec4(m, m, m, 1.0); }
        """)

    /// An HDR frame's weight (see `hdr`): the hat on its (grown) level, its exposure, the deghosting against the reference.
    private static let weight = CIColorKernel(source: """
        kernel vec4 weight(__sample own, __sample light, __sample refLight, __sample refLevel, float factor, float lowCut,
                           float highCut, float ghost, float noise) {
            float t = log2(max(own.r, 1.0e-8));
            float w = mix(1.0, 1.0 - smoothstep(-1.5, -0.2, t), highCut) * mix(1.0, smoothstep(-12.0, -8.0, t), lowCut) * factor;
            float apart = log2((max(light.r, 0.0) + noise) / (max(refLight.r, 0.0) + noise));
            float usable = 1.0 - smoothstep(-0.6, -0.3, log2(max(refLevel.r, 1.0e-8)));
            float moved = mix(smoothstep(0.2, 0.4, -apart), smoothstep(0.2, 0.4, abs(apart)), usable);
            w *= 1.0 - ghost * moved;
            return vec4(w + (1.0 - ghost) * 0.001, 0.0, 0.0, 1.0);
        }
        """)

    /// Running sums: colour times weight, and (with a white `c`) the weights.
    private static let accumulate = CIColorKernel(source: """
        kernel vec4 accumulate(__sample sum, __sample c, __sample w) { return vec4(sum.rgb + c.rgb * w.r, 1.0); }
        """)

    private static let divide = CIColorKernel(source: """
        kernel vec4 divide(__sample sum, __sample total) { return vec4(sum.rgb / max(total.r, 1.0e-6), 1.0); }
        """)

    /// A panorama frame's weight: 1 in the middle, falling towards 0 at its edges (`e`: the frame), never quite there
    /// inside it (where only frames' edges cover the panorama, its outer rows, nothing would leave 0 / 0), and nothing
    /// outside it: Core Image runs a generator past its extent when something reads there.
    private static let feather = CIColorKernel(source: """
        kernel vec4 feather(vec4 e) {
            vec2 d = destCoord();
            float x = min(d.x - e.x, e.x + e.z - d.x) / (0.5 * e.z);
            float y = min(d.y - e.y, e.y + e.w - d.y) / (0.5 * e.w);
            float w = x > 0.0 && y > 0.0 ? max(min(x, 1.0) * min(y, 1.0), 0.002) : 0.0;
            return vec4(w, 0.0, 0.0, 1.0);
        }
        """)

    /// Focus: the square root of luminance (what the Laplacian is taken of), and the Laplacian's size.
    private static let root = CIColorKernel(source: """
        kernel vec4 root(__sample c) { float y = sqrt(max(dot(c.rgb, vec3(0.2126, 0.7152, 0.0722)), 0.0)); return vec4(y, y, y, 1.0); }
        """)
    private static let magnitude = CIColorKernel(source: """
        kernel vec4 magnitude(__sample c) { float y = abs(c.r); return vec4(y, y, y, 1.0); }
        """)

    /// Focus: a frame's weight, its sharpness over the sharpest frame's, to the fourth power.
    private static let share = CIColorKernel(source: """
        kernel vec4 share(__sample s, __sample top) { float r = s.r / max(top.r, 1.0e-9); r *= r; return vec4(r * r, 0.0, 0.0, 1.0); }
        """)
}
