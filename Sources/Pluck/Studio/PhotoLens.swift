import CoreImage
import SwiftUI

/// Manual lens corrections (crop mode → Lens), for lenses Apple's RAW correction doesn't know, JPEGs and adapted lenses.
/// Nil in PhotoAdjustments when untouched, so old edits save and render as before.
/// Vignetting, fringes and the colour fringe removal go on the decoded photo in linear light (after a negative is made
/// positive, before spots: they move nothing, so spots and masks keep their places). Distortion goes with the geometry,
/// before straightening, around the middle of the whole frame, after spots and masks (which are placed on the photo as
/// decoded), scaled so the frame stays filled.
struct PhotoLens: Codable, Hashable {
    /// -100…100: + takes out barrel distortion (lines bowed outward), − pincushion.
    var distortion = 0.0
    /// -100…100: + brightens the corners (undoes the lens's fall-off), − darkens them. Midpoint 0…100: lower reaches
    /// further in towards the middle.
    var vignetting = 0.0, midpoint = 50.0
    /// -100…100: + makes the red (blue) picture a little larger, − smaller, so it lines up with green at the edges.
    var redCyan = 0.0, blueYellow = 0.0
    /// Purple and green fringes along high-contrast edges taken out (desaturated, gently).
    var defringe = false
    /// A lens profile's own outer distortion term (k2), when one was used; nil: tied to k1. Left out when nil, so edits
    /// without a profile save as before.
    var profileK2: Double?
    /// The Lensfun profile the sliders were set from (its lens's name), while it's on; nil: none.
    var profile: String?
    /// Apple's own lens correction (a RAW's, when Apple knows the lens) turned off; nil: on, as it always was.
    var appleOff: Bool?

    var isDefault: Bool { self == PhotoLens() }
    /// Whether anything changes the decoded photo itself (everything but Distortion).
    var shades: Bool { vignetting != 0 || redCyan != 0 || blueYellow != 0 || defringe }

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback }
        distortion = value(.distortion, 0); vignetting = value(.vignetting, 0); midpoint = value(.midpoint, 50)
        redCyan = value(.redCyan, 0); blueYellow = value(.blueYellow, 0); defringe = value(.defringe, false)
        profileK2 = try? c.decodeIfPresent(Double.self, forKey: .profileK2)
        profile = try? c.decodeIfPresent(String.self, forKey: .profile)
        appleOff = try? c.decodeIfPresent(Bool.self, forKey: .appleOff)
    }

    /// The radial model's terms (radius as a share of the half diagonal): r · (1 + k1·r² + k2·r⁴), k2 tied to k1.
    var k1: Double { -min(max(distortion, -100), 100) / 100 * 0.2 }
    var k2: Double { profileK2 ?? k1 * 0.2 }
    /// Each fringe slider at 100: the channel's picture this share of the radius larger (about 7 px at a 24 MP corner).
    static let fringeReach = 0.002

    /// The red and blue channels' scale (from the middle, as samples are read: + reads further out, so the picture is smaller).
    var redScale: Double { -min(max(redCyan, -100), 100) / 100 * Self.fringeReach }
    var blueScale: Double { -min(max(blueYellow, -100), 100) / 100 * Self.fringeReach }
}

// MARK: - Render

extension PhotoLens {
    /// Vignetting, fringes and fringe removal on the decoded photo (linear light). None: the same image, untouched.
    static func shaded(_ lens: PhotoLens?, _ image: CIImage) -> CIImage {
        guard let lens, lens.shades else { return image }
        let e = image.extent
        guard !e.isInfinite, e.width > 0, e.height > 0 else { return image }
        let centre = CIVector(x: e.midX, y: e.midY), reach = hypot(e.width, e.height) / 2
        var out = image
        if lens.redCyan != 0 || lens.blueYellow != 0, let kernel = fringeKernel {
            let m = max(abs(lens.redScale), abs(lens.blueScale)) * reach + 2
            out = kernel.apply(extent: e, roiCallback: { _, r in r.insetBy(dx: -m, dy: -m) },
                               arguments: [out.clampedToExtent(), centre, lens.redScale, lens.blueScale])?.cropped(to: e) ?? out
        }
        if lens.defringe, let kernel = defringeKernel {
            // shortcut: the edge test reads neighbours a fixed share of the long edge away (at least a pixel), so a small
            // preview finds a little less fringe than a full-size export; fine while fringes are a few pixels wide.
            let rad = max(1, max(e.width, e.height) / 2000)
            out = kernel.apply(extent: e, roiCallback: { _, r in r.insetBy(dx: -rad - 1, dy: -rad - 1) },
                               arguments: [out.clampedToExtent(), rad])?.cropped(to: e) ?? out
        }
        if lens.vignetting != 0, let kernel = vignetteKernel {
            // At 100 the corners two stops brighter; Midpoint sets how fast it rises (a power of the radius, 1 … 6).
            out = kernel.apply(extent: e, arguments: [out, centre, reach, min(max(lens.vignetting, -100), 100) / 100 * 2,
                                                      1 + min(max(lens.midpoint, 0), 100) / 20]) ?? out
        }
        return out
    }

    /// A kept decode's key with the lens's shading on it (the local-tone layers worked out from it are then its own).
    static func key(_ key: String?, _ lens: PhotoLens?) -> String? {
        guard let lens, lens.shades else { return key }
        return key.map { $0 + "|lens \(lens.vignetting) \(lens.midpoint) \(lens.redCyan) \(lens.blueYellow) \(lens.defringe)" }
    }

    /// How much larger the picture is read so the frame stays filled, for a w × h frame (1: none).
    func fill(width w: Double, height h: Double) -> Double {
        let reach = hypot(w, h) / 2, short = min(w, h) / 2 / reach
        func f(_ r: Double) -> Double { 1 + k1 * r * r + k2 * r * r * r * r }
        // f is monotonic, so the frame's edge reads furthest out at a short side's middle or at a corner; plus a pixel's margin.
        return 1 / max(f(short), f(1)) / (1 + 2 / max(min(w, h), 1))
    }

    /// The picture with this distortion taken out, the same size and filled.
    func warped(_ image: CIImage) -> CIImage {
        guard distortion != 0, let kernel = Self.distortKernel else { return image }
        let e = image.extent
        return kernel.apply(extent: e, roiCallback: { _, _ in e }, image: image.clampedToExtent(),
                            arguments: [CIVector(x: e.midX, y: e.midY), hypot(e.width, e.height) / 2, k1, k2, fill(width: e.width, height: e.height)])?
            .cropped(to: e) ?? image
    }

    /// Fill Edges: the distortion taken out around `frame`'s middle, not zoomed (what's beyond the frame comes from the photo
    /// made larger by PhotoEdgeFill).
    func warped(_ image: CIImage, around frame: CGRect) -> CIImage {
        guard distortion != 0, let kernel = Self.distortKernel else { return image }
        let e = image.extent
        return kernel.apply(extent: e, roiCallback: { _, _ in e }, image: image.clampedToExtent(),
                            arguments: [CIVector(x: frame.midX, y: frame.midY), hypot(frame.width, frame.height) / 2, k1, k2, 1.0])?
            .cropped(to: e) ?? image
    }

    private static let distortKernel = CIWarpKernel(source: """
        kernel vec2 lensDistort(vec2 centre, float reach, float k1, float k2, float s) {
            vec2 p = (destCoord() - centre) / reach;
            float q = dot(p, p);
            return centre + p * reach * s * (1.0 + k1 * q + k2 * q * q);
        }
        """)

    private static let fringeKernel = CIKernel(source: """
        kernel vec4 lensFringe(sampler s, vec2 centre, float kr, float kb) {
            vec2 p = destCoord() - centre;
            vec4 c = sample(s, samplerCoord(s));
            float r = sample(s, samplerTransform(s, centre + p * (1.0 + kr))).r;
            float b = sample(s, samplerTransform(s, centre + p * (1.0 + kb))).b;
            return vec4(r, c.g, b, c.a);
        }
        """)

    /// Purple (red and blue over green) and, less, green pixels where the brightness changes sharply (Michelson contrast
    /// of the four neighbours) taken towards their own brightness, at most three quarters of the way.
    private static let defringeKernel = CIKernel(source: """
        kernel vec4 lensDefringe(sampler s, float rad) {
            vec3 w = vec3(0.2126, 0.7152, 0.0722);
            vec2 d = destCoord();
            vec4 c = sample(s, samplerCoord(s));
            float y0 = dot(c.rgb, w);
            float a = dot(sample(s, samplerTransform(s, d + vec2(rad, 0.0))).rgb, w);
            float b = dot(sample(s, samplerTransform(s, d - vec2(rad, 0.0))).rgb, w);
            float e = dot(sample(s, samplerTransform(s, d + vec2(0.0, rad))).rgb, w);
            float f = dot(sample(s, samplerTransform(s, d - vec2(0.0, rad))).rgb, w);
            float hi = max(max(max(a, b), max(e, f)), y0), lo = max(min(min(min(a, b), min(e, f)), y0), 0.0);
            float edge = smoothstep(0.35, 0.75, (hi - lo) / (hi + lo + 0.0001));
            vec3 n = c.rgb / max(y0, 0.00001);
            float purple = smoothstep(0.1, 0.4, min(n.r, n.b) - n.g);
            float green = 0.6 * smoothstep(0.15, 0.5, n.g - max(n.r, n.b));
            float k = 0.75 * edge * max(purple, green);
            return vec4(mix(c.rgb, vec3(y0), k), c.a);
        }
        """)

    private static let vignetteKernel = CIColorKernel(source: """
        kernel vec4 lensShade(__sample s, vec2 centre, float reach, float stops, float power) {
            float r = min(length(destCoord() - centre) / reach, 1.0);
            return vec4(s.rgb * exp2(stops * pow(r, power)), s.a);
        }
        """)
}

// MARK: - Controls

/// The crop's Lens section (under Perspective): Distortion, the lens's vignetting and its colour fringes.
struct PhotoLensPanel: View {
    let path: String
    let record: PhotoRecord
    @State private var catalog = PhotoCatalog.shared

    var body: some View {
        let l = record.adjust.lens ?? PhotoLens()
        AdjustFold(title: "Lens", section: .lens, adjust: record.adjust, reset: { set { $0 = PhotoLens() } }) {
            PhotoLensProfileRow(path: path, lens: l) { change in set(change) }
            slider("Distortion", l.distortion, \.distortion, -100...100)
            slider("Vignetting", l.vignetting, \.vignetting, -100...100)
            slider("Midpoint", l.midpoint, \.midpoint, 0...100, neutral: 50, format: "%.0f")
            slider("Red/Cyan", l.redCyan, \.redCyan, -100...100)
            slider("Blue/Yellow", l.blueYellow, \.blueYellow, -100...100)
            StudioSwitchRow(title: "Remove fringes", isOn: Binding(get: { l.defringe }, set: { on in set { $0.defringe = on } }))
                .padding(.horizontal, Design.Sidebar.rowPadding)
        }
    }

    private func slider(_ title: LocalizedStringKey, _ value: Double, _ key: WritableKeyPath<PhotoLens, Double>,
                        _ range: ClosedRange<Double>, neutral: Double = 0, format: String = "%+.0f") -> some View {
        AdjustSlider(title: title, value: value, range: range, neutral: neutral, format: format) { new in set { $0[keyPath: key] = new } }
    }

    private func set(_ change: (inout PhotoLens) -> Void) {
        catalog.update([path]) { record in
            var l = record.adjust.lens ?? PhotoLens()
            change(&l)
            record.adjust.lens = l
            record.edited = .now
        }
    }
}
