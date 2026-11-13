import CoreImage

/// Retouch: Smooth Skin, on the decoded photo (linear light, before the develop), see PhotoRender.adjusted. The faces' skin
/// (PhotoMasks' face landmarks: cheeks, forehead, chin; not eyes, brows or lips) gets an edge-keeping smoothing (a guided filter
/// in screen steps, so pores and blemishes go while the face's shape and its edges stay), with a third of the fine texture
/// kept so it never looks plastic.
enum PhotoRetouch {
    /// Smooth Skin at `amount` (0…100). None (or no face): the same image.
    static func smoothed(_ amount: Double?, to image: CIImage, path: String?, base: CIImage, context: CIContext) -> CIImage {
        guard let amount, amount > 0, let path, !image.extent.isInfinite,
              let skin = PhotoMasks.facePart(.faceSkin, person: nil, path: path, from: base, context: context) else { return image }
        let e = image.extent, m = skin.extent
        guard m.width >= 1, m.height >= 1 else { return image }
        // The skin mask the picture's size, a little soft at its edges, at the amount.
        let mask = skin.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -m.minX, y: -m.minY).concatenating(CGAffineTransform(scaleX: e.width / m.width, y: e.height / m.height))
                .concatenating(CGAffineTransform(translationX: e.minX, y: e.minY)))
            .applyingGaussianBlur(sigma: max(e.width, e.height) * 0.002).cropped(to: e)
            .applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: CGFloat(min(amount, 100) / 100 * 0.85), y: 0, z: 0, w: 0)])
        // Smoothed in screen steps (so dark pores and light skin weigh as the eye sees them), edges kept by the picture itself.
        let screen = image.applyingFilter("CILinearToSRGBToneCurve")
        // An edge-keeping blur, across then down: each place averaged with its neighbours of a like tone only (a bilateral
        // filter), so pores and blemishes go and the face's edges, eyes and lips stay.
        let radius = Float(max(e.width, e.height) * 0.006)
        guard let bilateral else { return image }
        func pass(_ i: CIImage, _ dx: Float, _ dy: Float) -> CIImage {
            bilateral.apply(extent: e, roiCallback: { _, r in r.insetBy(dx: -CGFloat(radius) - 2, dy: -CGFloat(radius) - 2) },
                            arguments: [i.clampedToExtent(), CIVector(x: CGFloat(dx * radius / 6), y: CGFloat(dy * radius / 6)), Float(0.06)])?.cropped(to: e) ?? i
        }
        let smooth = pass(pass(screen, 1, 0), 0, 1)
        // A third of the fine texture back.
        let kept = smooth.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: screen, "inputTime": 0.33])
            .applyingFilter("CISRGBToneCurveToLinear")
        return kept.applyingFilter("CIBlendWithRedMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask]).cropped(to: e)
    }

    private static let bilateral = CIKernel(source: """
        kernel vec4 bilateral(sampler s, vec2 step, float range) {
            vec2 p = destCoord();
            vec4 c = sample(s, samplerTransform(s, p));
            vec3 sum = c.rgb; float w = 1.0;
            for (int i = 1; i <= 6; i++) {
                vec2 o = step * float(i);
                vec3 a = sample(s, samplerTransform(s, p + o)).rgb, b = sample(s, samplerTransform(s, p - o)).rgb;
                float g = exp(-float(i * i) / 18.0);
                float wa = g * exp(-dot(a - c.rgb, a - c.rgb) / (2.0 * range * range));
                float wb = g * exp(-dot(b - c.rgb, b - c.rgb) / (2.0 * range * range));
                sum += a * wa + b * wb; w += wa + wb;
            }
            return vec4(sum / w, c.a);
        }
        """)

    /// A kept decode's key with Smooth Skin on it (its local-tone layers are then its own). None: unchanged.
    static func key(_ key: String?, _ amount: Double?) -> String? {
        guard let amount, amount > 0 else { return key }
        return key.map { $0 + "|skin \(amount)" }
    }
}
