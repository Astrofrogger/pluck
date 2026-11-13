import CoreImage

/// Fill Edges (Crop › Fill Edges): straightening, perspective and lens distortion keep the whole frame instead of zooming in
/// to hide the empty corners; what they'd leave empty is filled in from the photo by AI Remove (PhotoRemove). The photo is
/// made larger once (its border filled, square by square, from what's next to it), in scene light before the develop, so a
/// slider moved doesn't fill it again (AI Remove keeps each fill by what went in); the border is developed with the same
/// settings as the photo and the geometry then works around the photo's own frame (PhotoRender.geometry's `frame`).
enum PhotoEdgeFill {
    /// Whether this edit fills its edges: on, AI Remove's model here, and some geometry that would leave edges empty.
    static func wanted(_ a: PhotoAdjustments) -> Bool {
        a.fillEdges == true && PhotoRemove.isReady && (a.straighten != 0 || a.perspective != nil || (a.lens?.distortion ?? 0) != 0)
    }

    /// How far beyond the frame (pixels) the geometry reaches: the frame's corners followed back through the rotation, the
    /// perspective and the lens's warp, plus a little.
    static func margin(_ a: PhotoAdjustments, frame: CGRect) -> CGFloat {
        let w = Double(frame.width), h = Double(frame.height)
        var need = 0.0
        let t = abs(a.straighten) * .pi / 180
        if t > 0 { need = max(need, w / 2 * cos(t) + h / 2 * sin(t) - w / 2, w / 2 * sin(t) + h / 2 * cos(t) - h / 2) }
        if let p = a.perspective {
            let frameCorners = [SIMD2(-w / 2, h / 2), SIMD2(w / 2, h / 2), SIMD2(w / 2, -h / 2), SIMD2(-w / 2, -h / 2)]
            let back = PhotoPerspective.homography(p.corners(width: w, height: h, fill: false), frameCorners)
            for c in frameCorners {
                let q = PhotoPerspective.apply(back, c)
                need = max(need, abs(q.x) - w / 2, abs(q.y) - h / 2)
            }
        }
        if let lens = a.lens, lens.distortion != 0 {
            let reach = hypot(w, h) / 2, f = 1 + lens.k1 + lens.k2
            need = max(need, reach * (f - 1))
        }
        return CGFloat(min(need * 1.15 + 8, max(w, h) * 0.25)).rounded(.up)
    }

    /// The photo with `margin` more on every side, filled in from the photo; nil without the model or when the fill fails.
    /// The model fills the whole photo's border in one go (seen whole, made 800 px across: no seams between pieces); its fill
    /// gives the colours and shapes, and the photo mirrored at its edge gives the fine detail (and leads into the fill, so the
    /// photo's edge doesn't show).
    static func extended(_ image: CIImage, margin m: CGFloat, context: CIContext) -> CIImage? {
        let e = image.extent
        guard m >= 1, !e.isInfinite, m < min(e.width, e.height), let blend = blendKernel else { return nil }
        let big = e.insetBy(dx: -m, dy: -m)
        let mirror = mirrored(image).cropped(to: big)
        let side = max(big.width, big.height)
        let square = CGRect(x: big.midX - side / 2, y: big.midY - side / 2, width: side, height: side)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: square)
        let holes = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: e).composited(over: white)
        guard let fill = PhotoRemove.fill(mirror, mask: holes, square: square, context: context)?.cropped(to: big) else { return nil }
        // The mirror's fine detail (what a blur the size of the model's pixels takes away) on the model's fill.
        let radius = Double(side / 800 * 1.5)
        let detail = mirror.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: big)
            .applyingFilter("CISubtractBlendMode", parameters: [kCIInputBackgroundImageKey: mirror])
        let made = detail.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: fill]).cropped(to: big)
        // Mirror at the photo's edge, the fill a little way out.
        let ramp = max(m * 0.5, 4)
        return blend.apply(extent: big, roiCallback: { _, r in r }, arguments: [mirror, made, CIVector(cgRect: e), ramp])
    }

    /// The photo mirrored at each edge (out to a photo's width or height beyond it).
    static func mirrored(_ image: CIImage) -> CIImage {
        let e = image.extent
        // (Over the photo's edge pixels drawn outward, so no see-through seam between the pieces.)
        var out = image.clampedToExtent()
        for dx in -1...1 {
            for dy in -1...1 where dx != 0 || dy != 0 {
                let t = CGAffineTransform(translationX: -e.midX, y: -e.midY)
                    .concatenating(CGAffineTransform(scaleX: dx == 0 ? 1 : -1, y: dy == 0 ? 1 : -1))
                    .concatenating(CGAffineTransform(translationX: e.midX + CGFloat(dx) * e.width, y: e.midY + CGFloat(dy) * e.height))
                out = image.transformed(by: t).composited(over: out)
            }
        }
        return out
    }

    /// Mirror at the photo, the made border from `ramp` beyond it.
    private static let blendKernel = CIKernel(source: """
    kernel vec4 edgeBlend(sampler mirror, sampler made, vec4 photo, float ramp) {
        vec2 p = destCoord();
        vec2 d = max(max(photo.xy - p, p - (photo.xy + photo.zw)), vec2(0.0));
        float w = smoothstep(0.0, ramp, length(d));
        return mix(sample(mirror, samplerCoord(mirror)), sample(made, samplerCoord(made)), w);
    }
    """)
}
