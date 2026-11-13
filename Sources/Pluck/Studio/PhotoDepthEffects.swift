import CoreImage
import SwiftUI

/// Depth effects (Adjust → Depth): Lens Blur and Fog, from the depth finder's map (PhotoDepth). Nil on a photo until one
/// is changed, so an edit without them keeps the same saved settings and preview key as before they existed.
struct PhotoDepthEffects: Codable, Hashable {
    /// Lens Blur: how strong (as the aperture), 0…100; the distance kept sharp (0 nearest … 1 farthest); how deep the
    /// sharp band is, 0…100; how much the bright highlights light up in the blur (bokeh), 0…100.
    var blur = 0.0, focus = 0.0, range = 10.0, bokeh = 0.0
    /// Fog: how thick, 0…100; where it starts (0 nearest … 100 farthest); its colour.
    var fog = 0.0, fogStart = 30.0
    var fogColour = FogColour.white

    enum FogColour: String, Codable, CaseIterable, Identifiable {
        case white, warm, cool
        var id: String { rawValue }
        var title: String {
            switch self {
            case .white: String(localized: "White")
            case .warm: String(localized: "Warm")
            case .cool: String(localized: "Cool")
            }
        }
        /// sRGB, 0…1.
        var rgb: SIMD3<Double> {
            switch self {
            case .white: SIMD3(0.92, 0.93, 0.95)
            case .warm: SIMD3(0.96, 0.86, 0.72)
            case .cool: SIMD3(0.76, 0.85, 0.96)
            }
        }
    }

    var isDefault: Bool { self == PhotoDepthEffects() }

    /// The largest blur's radius, as a share of the photo's long side (Amount 100).
    static let widest = 0.03
    /// How far past the sharp band (in distance, 0…1) the blur reaches its full size.
    static let falloff = 0.3
    /// The depth is fitted to the picture's edges at most this size (long side), then scaled to it.
    static let guideSize = 2048.0

    /// How sharp a place at this nearness (1 nearest … 0 farthest) stays: 1 in the band, 0 at the full blur.
    func sharpness(near: Double) -> Double {
        1 - min(max((abs((1 - near) - focus) - range / 100 * 0.5) / Self.falloff, 0), 1)
    }
}

// MARK: - Render

extension PhotoDepthEffects {
    /// The effects on the decoded photo (linear light, before the tone), with the key its local-tone layers then go by.
    /// Without the depth finder (or with nothing set) the same photo and key.
    static func applied(_ d: PhotoDepthEffects?, to image: CIImage, key: String?, path: String?, base: CIImage,
                        context: CIContext) -> (image: CIImage, key: String?) {
        guard let d, d.blur > 0 || d.fog > 0, let path, let near = PhotoDepth.nearness(path, from: base, context: context)
        else { return (image, key) }
        return (d.applied(to: image, near: near), key.map { $0 + "|depth \(d.hashValue)" })
    }

    /// The effects with this nearness map (1 nearest … 0 farthest, any size: it's fitted to the picture).
    func applied(to image: CIImage, near: CIImage) -> CIImage {
        let e = image.extent
        guard blur > 0 || fog > 0, e.width >= 2, e.height >= 2, !e.isInfinite, near.extent.width >= 1, let k = Self.kernels else { return image }
        let long = max(e.width, e.height)
        let near = depth(near, for: image)
        var out = image
        // Each place's light weighed by how blurred it is itself (alpha): a blur gathers only from what's out of focus,
        // so a sharp subject never smears into the background behind it, and the background never over it.
        if blur > 0, let coc = k.coc.apply(extent: e, arguments: [near, Float(focus), Float(range / 100 * 0.5), Float(Self.falloff)]),
           let weighed = k.weigh.apply(extent: e, arguments: [image, coc, Float(bokeh / 100 * 3)]) {
            let radius = blur / 100 * Self.widest * long
            // Three blurs (a third, two thirds and all of the radius), each made small enough that its disc is under 16 pixels
            // across there: quick at any size, and the same share of the picture in a preview and the export.
            var pyramid = [weighed]
            func level(_ r: Double) -> CIImage {
                var n = 0
                while r / pow(2, Double(n)) > 16 { n += 1 }
                while pyramid.count <= n {
                    // (Kept apart, so Core Image can't fold the halvings into one sparse sampling.)
                    pyramid.append(pyramid[pyramid.count - 1].transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5)).insertingIntermediate())
                }
                let s = pow(2, Double(n))
                return pyramid[n].applyingFilter("CIDiscBlur", parameters: [kCIInputRadiusKey: r / s])
                    .transformed(by: CGAffineTransform(scaleX: s, y: s)).cropped(to: e)
            }
            let levels = [1.0, 2, 3].map { level(radius * $0 / 3) }
            out = k.lens.apply(extent: e, arguments: [image, levels[0], levels[1], levels[2], coc]) ?? image
        }
        if fog > 0 {
            func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            let c = fogColour.rgb
            out = k.fog.apply(extent: e, arguments: [out, near, CIVector(x: linear(c.x), y: linear(c.y), z: linear(c.z)),
                                                     Float(fog / 100), Float(fogStart / 100)]) ?? out
        }
        return out.cropped(to: e)
    }

    /// The nearness made the picture's size, its edges drawn to the picture's (a guided filter, at most `guideSize`) and
    /// kept within what the map has nearby (the filter can't make a depth that isn't there, so no halo of a wrong one).
    private func depth(_ near: CIImage, for image: CIImage) -> CIImage {
        let e = image.extent, m = near.extent
        let g = min(1, Self.guideSize / max(e.width, e.height))
        let gw = max((e.width * g).rounded(), 1), gh = max((e.height * g).rounded(), 1)
        let frame = CGRect(x: 0, y: 0, width: gw, height: gh)
        let toGuide = CGAffineTransform(translationX: -e.minX, y: -e.minY).concatenating(CGAffineTransform(scaleX: gw / e.width, y: gh / e.height))
        let fit = CGAffineTransform(translationX: -m.minX, y: -m.minY).concatenating(CGAffineTransform(scaleX: gw / m.width, y: gh / m.height))
        func fitted(_ map: CIImage) -> CIImage { map.clampedToExtent().transformed(by: fit) }
        let picture = image.clampedToExtent().transformed(by: toGuide)
            .applyingFilter("CILinearToSRGBToneCurve").applyingFilter("CIMaximumComponent")
        let margin = frame.insetBy(dx: -24, dy: -24)
        let guided = fitted(near).cropped(to: margin).applyingFilter("CIGuidedFilter", parameters: [
            "inputGuideImage": picture.cropped(to: margin), "inputRadius": max(gw, gh) / 300, "inputEpsilon": 0.0008,
        ]).cropped(to: frame)
        let low = fitted(near.clampedToExtent().applyingFilter("CIMorphologyMinimum", parameters: ["inputRadius": 2]).cropped(to: m))
        let high = fitted(near.clampedToExtent().applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": 2]).cropped(to: m))
        let held = Self.kernels?.hold.apply(extent: frame, arguments: [guided, low.cropped(to: frame), high.cropped(to: frame)]) ?? guided
        return held.clampedToExtent().transformed(by: toGuide.inverted()).cropped(to: e)
    }

    private struct Kernels { let coc, weigh, lens, fog, hold: CIColorKernel }

    private static let kernels: Kernels? = {
        let w = "vec3(0.2126, 0.7152, 0.0722)"
        func make(_ source: String) -> CIColorKernel? { CIColorKernel(source: source) }
        guard let coc = make("""
                kernel vec4 coc(__sample d, float focus, float band, float falloff) {
                    float r = clamp((abs((1.0 - d.r) - focus) - band) / falloff, 0.0, 1.0); return vec4(r, r, r, 1.0); }
                """),
              let weigh = make("""
                kernel vec4 weigh(__sample c, __sample r, float boost) {
                    float Y = dot(max(c.rgb, 0.0), \(w));
                    return vec4(c.rgb * (1.0 + boost * smoothstep(0.8, 2.0, Y)) * r.r, r.r); }
                """),
              let lens = make("""
                kernel vec4 lens(__sample s, __sample a, __sample b, __sample c, __sample r) {
                    float t = r.r * 3.0;
                    vec3 x = mix(s.rgb, a.rgb / max(a.a, 0.001), clamp(t, 0.0, 1.0));
                    x = mix(x, b.rgb / max(b.a, 0.001), clamp(t - 1.0, 0.0, 1.0));
                    x = mix(x, c.rgb / max(c.a, 0.001), clamp(t - 2.0, 0.0, 1.0));
                    return vec4(x, s.a); }
                """),
              let fog = make("""
                kernel vec4 fog(__sample c, __sample d, vec3 colour, float amount, float start) {
                    float x = max((1.0 - d.r) - start, 0.0) / max(1.0 - start, 0.05);
                    float f = amount * (1.0 - exp(-3.0 * x)) / (1.0 - exp(-3.0));
                    return vec4(mix(c.rgb, colour, f), c.a); }
                """),
              let hold = make("""
                kernel vec4 hold(__sample g, __sample lo, __sample hi) { float v = clamp(g.r, lo.r, hi.r); return vec4(v, v, v, 1.0); }
                """)
        else { return nil }
        return Kernels(coc: coc, weigh: weigh, lens: lens, fog: fog, hold: hold)
    }()

    // MARK: Picking and showing

    /// This photo's nearness map (nil without the depth finder).
    nonisolated static func map(_ path: String, record: PhotoRecord, size: Int) -> CIImage? {
        guard PhotoDepth.isReady, let base = PhotoRender.base(path, maxSize: size, record: record) else { return nil }
        return PhotoDepth.nearness(path, from: base.image, context: PhotoEngine.context)
    }

    /// The distance (0 nearest … 1 farthest) at a point of the photo as decoded (shares from the top left).
    nonisolated static func distance(_ path: String, record: PhotoRecord, size: Int, at point: CGPoint) -> Double? {
        guard let near = map(path, record: record, size: size) else { return nil }
        let e = near.extent
        let spot = CGRect(x: e.minX + point.x * e.width - 2, y: e.maxY - point.y * e.height - 2, width: 5, height: 5).intersection(e)
        guard !spot.isEmpty else { return nil }
        let average = near.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: spot)])
        var pixel = [Float](repeating: 0, count: 4)
        PhotoEngine.context.render(average, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return min(max(1 - Double(pixel[0]), 0), 1)
    }

    /// The depth as a picture: grey, dimmed with distance, plum where it's in focus.
    nonisolated static func depthPicture(_ path: String, record: PhotoRecord, size: Int) -> CGImage? {
        guard let near = map(path, record: record, size: size) else { return nil }
        let d = record.adjust.depth ?? PhotoDepthEffects()
        let e = near.extent, width = Int(e.width), height = Int(e.height)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var values = [Float](repeating: 0, count: width * height)
        PhotoEngine.context.render(near, toBitmap: &values, rowBytes: width * 4, bounds: e, format: .Lf, colorSpace: nil)
        let plum = SIMD3<Double>(0xB5, 0x6C, 0x89) / 255
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            let v = Double(values[i])
            let c = SIMD3(repeating: 0.1 + 0.5 * v) * (1 - d.sharpness(near: v)) + plum * d.sharpness(near: v)
            bytes[i * 4] = UInt8(min(max(c.x, 0), 1) * 255); bytes[i * 4 + 1] = UInt8(min(max(c.y, 0), 1) * 255)
            bytes[i * 4 + 2] = UInt8(min(max(c.z, 0), 1) * 255)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}

// MARK: - Controls

/// The Depth section's controls: Lens Blur (picking the focus on the photo, showing the depth) and Fog. Without the depth
/// finder, one line and the way to get it.
struct PhotoDepthControls: View {
    let adjust: PhotoAdjustments
    let change: (@escaping (inout PhotoDepthEffects) -> Void) -> Void
    @State private var model = PhotoDepth.shared
    @State private var editing = PhotoEditing.shared

    var body: some View {
        switch model.state {
        case .ready: controls
        case .downloading(let share):
            ProgressView(value: share).controlSize(.small).padding(.horizontal, 8)
        case .failed(let problem):
            ProblemLabel(text: problem).padding(.horizontal, 8)
            Button("Try Again") { model.install() }.controlSize(.small).padding(.horizontal, 8)
        case .notInstalled:
            Text("Needs the depth model").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
            Button("Get Depth Finder (\(PhotoDepth.downloadMB) MB)", systemImage: "arrow.down") { model.install() }
                .controlSize(.small).padding(.horizontal, 8)
        }
    }

    @ViewBuilder private var controls: some View {
        let d = adjust.depth ?? PhotoDepthEffects()
        caption("Lens Blur")
        slider("Amount", d.blur) { $0.blur = $1 }
        HStack(spacing: 6) {
            Toggle(isOn: Binding(get: { editing.focusPicking }, set: { editing.focusPicking = $0 })) {
                Label("Pick Focus", systemImage: "scope")
            }
            .help("Click the photo where it should be sharp")
            Toggle(isOn: Binding(get: { editing.showDepth }, set: { editing.showDepth = $0 })) {
                Label("Show Depth", systemImage: "eye")
            }
            .help("See how far each place is: plum is in focus")
            Spacer(minLength: 0)
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .padding(.horizontal, 8)
        slider("Focus", d.focus * 100) { $0.focus = $1 / 100 }
        slider("Focus Range", d.range, neutral: 10) { $0.range = $1 }
        slider("Bokeh Brightness", d.bokeh) { $0.bokeh = $1 }
        caption("Fog")
        slider("Amount", d.fog) { $0.fog = $1 }
        slider("Distance", d.fogStart, neutral: 30) { $0.fogStart = $1 }
        HStack(spacing: 8) {
            Text("Colour").foregroundStyle(.secondary).frame(width: Design.Sidebar.sliderLabel, alignment: .leading)
            ForEach(PhotoDepthEffects.FogColour.allCases) { colour in
                let c = colour.rgb
                Button { change { $0.fogColour = colour } } label: {
                    Circle().fill(Color(red: c.x, green: c.y, blue: c.z)).frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(d.fogColour == colour ? Design.Brand.pink : .clear, lineWidth: 2))
                        .shadow(color: .black.opacity(0.3), radius: 1)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(colour.title)
                .accessibilityLabel(Text(colour.title))
                .accessibilityAddTraits(d.fogColour == colour ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, Design.Sidebar.rowPadding)
        .frame(minHeight: Design.Sidebar.sliderHeight)
    }

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).padding(.horizontal, Design.Sidebar.rowPadding).padding(.top, 4)
    }

    private func slider(_ title: LocalizedStringKey, _ value: Double, neutral: Double = 0,
                        _ set: @escaping (inout PhotoDepthEffects, Double) -> Void) -> some View {
        AdjustSlider(title: title, value: value, range: 0...100, neutral: neutral, format: "%.0f") { v in change { set(&$0, v) } }
    }
}

/// Pick Focus on the photo (shown whole, as decoded): a click makes the distance there the one kept sharp.
struct FocusPicker: View {
    let path: String
    let record: PhotoRecord
    let frame: CGRect
    @State private var editing = PhotoEditing.shared
    @State private var catalog = PhotoCatalog.shared

    var body: some View {
        Color.clear
            .contentShape(.rect)
            .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
            .gesture(SpatialTapGesture().onEnded { tap in pick(at: tap.location) })
    }

    private func pick(at location: CGPoint) {
        let at = CGPoint(x: (location.x - frame.minX) / max(frame.width, 1), y: (location.y - frame.minY) / max(frame.height, 1))
        guard (0...1).contains(at.x), (0...1).contains(at.y) else { return }
        let path = self.path, record = self.record, size = PhotoRender.previewSize
        Task {
            guard let distance = await Task.detached(priority: .userInitiated, operation: {
                PhotoDepthEffects.distance(path, record: record, size: size, at: at)
            }).value else { return }
            catalog.update([path]) {
                var d = $0.adjust.depth ?? PhotoDepthEffects()
                d.focus = distance
                $0.adjust.depth = d
                $0.edited = .now
            }
            editing.focusPicking = false
        }
    }
}

/// Show Depth: the depth map over the photo (shown whole, as decoded).
struct DepthOverlay: View {
    let path: String
    let record: PhotoRecord
    let frame: CGRect
    @State private var picture: CGImage?

    var body: some View {
        let d = record.adjust.depth ?? PhotoDepthEffects()
        ZStack {
            if let picture {
                Image(decorative: picture, scale: 1).resizable()
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            }
        }
        .allowsHitTesting(false)
        .task(id: "\(path)|\(d.focus)|\(d.range)") {
            let path = self.path, record = self.record, size = PhotoRender.previewSize
            picture = await Task.detached(priority: .userInitiated) { PhotoDepthEffects.depthPicture(path, record: record, size: size) }.value
        }
    }
}
