import CoreImage
import simd
import SwiftUI

/// A scanned film negative made positive (Adjust → Negative). Nil on a photo that isn't one, so an edit without it keeps
/// the same saved settings and preview key as before it existed. Done first, on the decoded photo in linear light, so the
/// rest of the edit (white balance, exposure, the profile) works on the positive.
/// The standard way: divide by the film base (the orange mask), take the density, set each channel's black and white
/// from the frame (which also evens out the dye layers' different contrast), then a print: a gentle S-shaped paper curve
/// with the print's density, the paper's grade and an enlarger's colour filtration.
struct PhotoNegative: Codable, Hashable {
    enum Kind: String, Codable { case colour, blackAndWhite }
    var kind = Kind.colour
    /// The film base (the unexposed rebate) as decoded, linear RGB.
    var base = SIMD3<Double>(1, 1, 1)
    /// Each channel's density above the base at the frame's black and its white (nil: 0 and `defaultWhite`).
    var black: SIMD3<Double>?, white: SIMD3<Double>?
    /// The print: Density (more is a darker print), Contrast (the paper grade) and the filtration (more red, green, blue),
    /// each −100…100.
    var density = 0.0, contrast = 0.0, cyanRed = 0.0, magentaGreen = 0.0, yellowBlue = 0.0

    static let defaultWhite = 1.2
    /// Shares of each side left out when the frame's black and white are measured (sprocket holes, the rebate).
    static let margin = 0.03

    /// The print's settings back to as made (the base and the points stay: they belong to the film).
    var printIsDefault: Bool { density == 0 && contrast == 0 && cyanRed == 0 && magentaGreen == 0 && yellowBlue == 0 }
}

// MARK: - Render

extension PhotoNegative {
    private static let kernel = try? CIColorKernel(source: """
        kernel vec4 negative(__sample s, vec3 base, vec3 lo, vec3 span, vec3 shift, float gain, float bw) {
            vec3 t = max(s.rgb / base, vec3(0.00001));
            t = mix(t, vec3(max(dot(t, vec3(0.2126, 0.7152, 0.0722)), 0.00001)), bw);
            vec3 n = (-0.4342945 * log(t) - lo) / span;
            vec3 x = (n - 0.5) * gain + shift;
            vec3 p = max((1.0 / (1.0 + exp(-4.0 * x)) - 0.1192029) / 0.7615942, vec3(0.0));
            return vec4(pow(p, vec3(2.2)), s.a);
        }
        """)

    /// The negative made positive. None: the same image, untouched.
    static func apply(_ n: PhotoNegative?, to image: CIImage) -> CIImage {
        guard let n, let kernel else { return image }
        let bw = n.kind == .blackAndWhite
        let lo = n.black ?? SIMD3(repeating: 0), hi = n.white ?? SIMD3(repeating: defaultWhite)
        let span = simd_max(hi - lo, SIMD3(repeating: 0.05))
        let filter = bw ? SIMD3<Double>(repeating: 0) : SIMD3(n.cyanRed, n.magentaGreen, n.yellowBlue) / 100 * 0.1
        let shift = filter - n.density / 100 * 0.25
        let base = simd_max(n.base, SIMD3(repeating: 1e-4))
        func v(_ s: SIMD3<Double>) -> CIVector { CIVector(x: s.x, y: s.y, z: s.z) }
        return kernel.apply(extent: image.extent, arguments: [image, v(base), v(lo), v(span), v(shift),
                                                               Float(pow(2, n.contrast / 100)), Float(bw ? 1 : 0)]) ?? image
    }

    /// A kept decode's key with the negative on it (the local-tone layers worked out from it are then its own).
    static func key(_ key: String?, _ n: PhotoNegative?) -> String? {
        guard let n else { return key }
        return key.map { $0 + "|negative \(n.hashValue)" }
    }
}

// MARK: - Measuring

extension PhotoNegative {
    /// The photo small (long side `size`, averaged first so grain and stray pixels count less), as linear RGB rows from the top.
    static func pixels(_ image: CIImage, size: Double = 512) -> (p: [Float], w: Int, h: Int)? {
        let e = image.extent
        guard !e.isInfinite, e.width >= 1, e.height >= 1 else { return nil }
        let s = min(1, size / max(e.width, e.height))
        let w = max(Int((e.width * s).rounded()), 1), h = max(Int((e.height * s).rounded()), 1)
        let soft = s < 1 ? image.clampedToExtent().applyingGaussianBlur(sigma: 0.5 / s - 0.5).cropped(to: e) : image
        let small = soft.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)
            .concatenating(CGAffineTransform(scaleX: Double(w) / e.width, y: Double(h) / e.height)))
        var p = [Float](repeating: 0, count: w * h * 4)
        PhotoEngine.context.render(small, toBitmap: &p, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf,
                                   colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        return (p, w, h)
    }

    /// The film base: the brightest robust part of the negative (its least dense), the 99th to 99.8th percentile by brightness.
    static func estimatedBase(_ px: (p: [Float], w: Int, h: Int)) -> SIMD3<Double> {
        let count = px.w * px.h
        let order = (0..<count).sorted { px.p[$0 * 4] + px.p[$0 * 4 + 1] + px.p[$0 * 4 + 2] < px.p[$1 * 4] + px.p[$1 * 4 + 1] + px.p[$1 * 4 + 2] }
        let from = min(Int(Double(count) * 0.99), count - 1), to = max(min(Int(Double(count) * 0.998), count), from + 1)
        var sum = SIMD3<Double>()
        for i in order[from..<to] { sum += SIMD3(Double(px.p[i * 4]), Double(px.p[i * 4 + 1]), Double(px.p[i * 4 + 2])) }
        return simd_max(sum / Double(to - from), SIMD3(repeating: 1e-4))
    }

    /// The base averaged around a point (shares from the top left), about 1% of the long side across.
    static func sampledBase(_ px: (p: [Float], w: Int, h: Int), at point: CGPoint) -> SIMD3<Double> {
        let r = max(Int(Double(max(px.w, px.h)) * 0.01), 1)
        let cx = Int(point.x * Double(px.w)), cy = Int(point.y * Double(px.h))
        var sum = SIMD3<Double>(), n = 0.0
        for y in max(cy - r, 0)...min(cy + r, px.h - 1) { for x in max(cx - r, 0)...min(cx + r, px.w - 1) {
            let i = (y * px.w + x) * 4
            sum += SIMD3(Double(px.p[i]), Double(px.p[i + 1]), Double(px.p[i + 2])); n += 1
        } }
        return simd_max(sum / max(n, 1), SIMD3(repeating: 1e-4))
    }

    /// Each channel's black and white (density above `base`, 0.1% and 99.9% of the frame inside the margin).
    static func points(_ px: (p: [Float], w: Int, h: Int), base: SIMD3<Double>, kind: Kind) -> (black: SIMD3<Double>, white: SIMD3<Double>) {
        let mx = Int(Double(px.w) * margin), my = Int(Double(px.h) * margin)
        var d: [[Double]] = [[], [], []]
        for y in my..<max(px.h - my, my + 1) { for x in mx..<max(px.w - mx, mx + 1) {
            let i = (min(y, px.h - 1) * px.w + min(x, px.w - 1)) * 4
            var t = SIMD3(Double(px.p[i]), Double(px.p[i + 1]), Double(px.p[i + 2])) / base
            if kind == .blackAndWhite { t = SIMD3(repeating: 0.2126 * t.x + 0.7152 * t.y + 0.0722 * t.z) }
            for c in 0..<3 { d[c].append(-log10(max(t[c], 1e-5))) }
        } }
        var black = SIMD3<Double>(), white = SIMD3<Double>(repeating: defaultWhite)
        for c in 0..<3 where !d[c].isEmpty {
            let s = d[c].sorted()
            black[c] = s[Int(Double(s.count - 1) * 0.001)]
            white[c] = max(s[Int(Double(s.count - 1) * 0.999)], black[c] + 0.05)
        }
        return (black, white)
    }

    /// Auto: the base from the negative, then the frame's black and white with it.
    func auto(_ image: CIImage) -> PhotoNegative {
        guard let px = Self.pixels(image) else { return self }
        return measured(px, base: Self.estimatedBase(px))
    }

    /// The base picked at a point (shares from the top left of the photo as decoded), then the frame's black and white.
    func picked(_ image: CIImage, at point: CGPoint) -> PhotoNegative {
        guard let px = Self.pixels(image) else { return self }
        return measured(px, base: Self.sampledBase(px, at: point))
    }

    func measured(_ px: (p: [Float], w: Int, h: Int), base: SIMD3<Double>) -> PhotoNegative {
        var n = self
        n.base = base
        (n.black, n.white) = Self.points(px, base: base, kind: kind)
        return n
    }

    /// Measured on this photo as decoded (off the main thread); nil when it can't be read.
    static func measure(_ path: String, record: PhotoRecord, size: Int, _ body: (CIImage) -> PhotoNegative) -> PhotoNegative? {
        PhotoRender.base(path, maxSize: size, record: record).map { body($0.image) }
    }
}

// MARK: - Controls

/// The Negative section: on or off, colour or black-and-white, the base (picked on the photo or Auto, its swatch) and the print.
struct PhotoNegativeControls: View {
    let path: String?
    let record: PhotoRecord
    let change: (@escaping (inout PhotoRecord) -> Void) -> Void
    @State private var editing = PhotoEditing.shared

    var body: some View {
        let n = record.adjust.negative
        row("Film Negative") {
            Toggle("Film Negative", isOn: Binding(get: { n != nil }, set: { on in
                if on { measure(PhotoNegative()) { $0.auto($1) } } else { step { $0.adjust.negative = nil }; editing.basePicking = false }
            }))
            .labelsHidden()
            .toggleStyle(StudioSwitchStyle())
        }
        if let n {
            StudioSegmented(ground: Design.Studio.panel, options: [(PhotoNegative.Kind.colour, LocalizedStringKey("Colour")),
                                                                   (PhotoNegative.Kind.blackAndWhite, LocalizedStringKey("B&W"))],
                            selection: Binding(get: { n.kind }, set: { kind in
                                var k = n
                                k.kind = kind
                                // (The base stays: only the black and white are measured again, as the new kind reads them.)
                                measure(k) { k, image in PhotoNegative.pixels(image).map { k.measured($0, base: k.base) } ?? k }
                            }))
                .padding(.horizontal, Design.Sidebar.rowPadding)
            HStack(spacing: 6) {
                let c = n.base
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(.sRGBLinear, red: min(c.x, 1), green: min(c.y, 1), blue: min(c.z, 1)))
                    .frame(width: 18, height: 18)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Design.Studio.line))
                    .help("The film base")
                    .accessibilityLabel(Text("The film base"))
                Toggle(isOn: Binding(get: { editing.basePicking }, set: { editing.basePicking = $0 })) {
                    Label("Pick Base", systemImage: "eyedropper")
                }
                .toggleStyle(.button)
                .help("Click the film's clear edge, outside the picture")
                Button("Auto") { measure(n) { $0.auto($1) } }
                    .buttonStyle(StudioFlatButtonStyle())
                    .help("Find the film base and the picture's black and white")
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            .padding(.horizontal, Design.Sidebar.rowPadding)
            slider("Density", n.density) { $0.density = $1 }
            slider("Contrast", n.contrast) { $0.contrast = $1 }
            if n.kind == .colour {
                slider("Cyan–Red", n.cyanRed, track: .colour(.red)) { $0.cyanRed = $1 }
                slider("Magenta–Green", n.magentaGreen, track: .colour(.green)) { $0.magentaGreen = $1 }
                slider("Yellow–Blue", n.yellowBlue, track: .colour(.blue)) { $0.yellowBlue = $1 }
            }
        }
    }

    private func row<C: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> C) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            content()
        }
        .font(Design.Studio.body)
        .padding(.horizontal, Design.Sidebar.rowPadding)
        .frame(minHeight: Design.Sidebar.sliderHeight)
    }

    private func slider(_ title: LocalizedStringKey, _ value: Double, track: AdjustSlider.Track = .plain,
                        _ set: @escaping (inout PhotoNegative, Double) -> Void) -> some View {
        AdjustSlider(title: title, value: value, range: -100...100, track: track) { v in
            change { if var n = $0.adjust.negative { set(&n, v); $0.adjust.negative = n; $0.edited = .now } }
        }
    }

    /// One undo step of its own.
    private func step(_ body: @escaping (inout PhotoRecord) -> Void) {
        PhotoCatalog.shared.endStep()
        change { body(&$0); $0.edited = .now }
        PhotoCatalog.shared.endStep()
    }

    /// `n` measured on the photo shown, then given (one step).
    private func measure(_ n: PhotoNegative, _ body: @escaping @Sendable (PhotoNegative, CIImage) -> PhotoNegative) {
        guard let path else { step { $0.adjust.negative = n }; return }
        let record = self.record, size = PhotoRender.previewSize
        Task {
            let found = await Task.detached(priority: .userInitiated) { PhotoNegative.measure(path, record: record, size: size) { body(n, $0) } }.value
            step { $0.adjust.negative = found ?? n }
        }
    }
}

/// Pick Base on the photo (shown whole, as decoded): a click samples the film base there.
struct BasePicker: View {
    let path: String
    let record: PhotoRecord
    let frame: CGRect
    @State private var editing = PhotoEditing.shared

    var body: some View {
        Color.clear
            .contentShape(.rect)
            .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
            .gesture(SpatialTapGesture().onEnded { tap in pick(at: tap.location) })
    }

    private func pick(at location: CGPoint) {
        let at = CGPoint(x: (location.x - frame.minX) / max(frame.width, 1), y: (location.y - frame.minY) / max(frame.height, 1))
        guard (0...1).contains(at.x), (0...1).contains(at.y), let n = record.adjust.negative else { return }
        let path = self.path, record = self.record, size = PhotoRender.previewSize
        Task {
            guard let found = await Task.detached(priority: .userInitiated, operation: {
                PhotoNegative.measure(path, record: record, size: size) { n.picked($0, at: at) }
            }).value else { return }
            PhotoCatalog.shared.endStep()
            PhotoCatalog.shared.update([path]) { $0.adjust.negative = found; $0.edited = .now }
            PhotoCatalog.shared.endStep()
            editing.basePicking = false
        }
    }
}
