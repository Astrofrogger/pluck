import CoreImage
import SwiftUI
import UniformTypeIdentifiers

/// How a clip's picture sits in the frame, as in DaVinci Resolve's Video inspector: the same for
/// a clip in a project and for a file on its own.
struct ClipLook: Codable, Hashable {
    enum Scaling: String, Codable, CaseIterable, Identifiable {
        case fit, fill, stretch
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .fit: "Fit"
            case .fill: "Fill"
            case .stretch: "Stretch"
            }
        }
    }

    /// The part of the frame shown, for dynamic zoom: its middle (shares of the frame, from the
    /// top left) and its width (a share of the frame; the height follows the frame's shape).
    struct ZoomFrame: Codable, Hashable {
        var x = 0.5
        var y = 0.5
        var size = 1.0

        /// Kept inside the frame.
        func fitted() -> ZoomFrame {
            var f = self
            f.size = min(max(f.size, 0.1), 1)
            f.x = min(max(f.x, f.size / 2), 1 - f.size / 2)
            f.y = min(max(f.y, f.size / 2), 1 - f.size / 2)
            return f
        }
    }

    enum Ease: String, Codable, CaseIterable, Identifiable {
        case linear, easeIn, easeOut, easeInOut
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .linear: "Linear"
            case .easeIn: "Ease In"
            case .easeOut: "Ease Out"
            case .easeInOut: "Ease In and Out"
            }
        }
        func apply(_ t: Double) -> Double {
            let t = min(max(t, 0), 1)
            switch self {
            case .linear: return t
            case .easeIn: return t * t
            case .easeOut: return 1 - (1 - t) * (1 - t)
            case .easeInOut: return t * t * (3 - 2 * t)
            }
        }
    }

    var scaling = Scaling.fit
    var zoom = 1.0
    /// Where it sits: shares of the frame's width and height from the middle (up is positive).
    var x = 0.0
    var y = 0.0
    /// Degrees, anticlockwise.
    var rotation = 0.0
    var flipH = false
    var flipV = false
    /// Cut from each side, as shares of the picture.
    var cropLeft = 0.0
    var cropRight = 0.0
    var cropTop = 0.0
    var cropBottom = 0.0
    /// Dynamic zoom: from this part of the frame to that one over the clip (nil: off).
    var zoomFrom: ZoomFrame?
    var zoomTo: ZoomFrame?
    var zoomEase = Ease.easeInOut
    var opacity = 1.0
    var speed = 1.0
    var stabilize = false
    var color = ClipColor()
    /// Placed by Pluck for the project's frame shape (not by hand).
    var reframed: Bool?

    var isDefault: Bool { self == ClipLook() }
    var hasCrop: Bool { cropLeft > 0 || cropRight > 0 || cropTop > 0 || cropBottom > 0 }
    var hasDynamicZoom: Bool { zoomFrom != nil && zoomTo != nil }

    /// Dynamic zoom's frame this far (0…1) through the clip.
    func zoomFrame(at progress: Double) -> ZoomFrame? {
        guard let from = zoomFrom?.fitted(), let to = zoomTo?.fitted() else { return nil }
        let t = zoomEase.apply(progress)
        return ZoomFrame(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t, size: from.size + (to.size - from.size) * t)
    }

    /// Turns dynamic zoom on: in from the whole frame to the middle, as Resolve starts it.
    mutating func startDynamicZoom() {
        zoomFrom = ZoomFrame()
        zoomTo = ZoomFrame(x: 0.5, y: 0.5, size: 0.8)
    }

    mutating func swapDynamicZoom() { swap(&zoomFrom, &zoomTo) }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        scaling = value(.scaling, Scaling.fit); zoom = value(.zoom, 1); x = value(.x, 0); y = value(.y, 0); rotation = value(.rotation, 0)
        flipH = value(.flipH, false); flipV = value(.flipV, false)
        cropLeft = value(.cropLeft, 0); cropRight = value(.cropRight, 0); cropTop = value(.cropTop, 0); cropBottom = value(.cropBottom, 0)
        zoomFrom = value(.zoomFrom, nil as ZoomFrame?); zoomTo = value(.zoomTo, nil as ZoomFrame?); zoomEase = value(.zoomEase, Ease.easeInOut)
        opacity = value(.opacity, 1); speed = value(.speed, 1); stabilize = value(.stabilize, false)
        color = value(.color, ClipColor())
        reframed = value(.reframed, nil as Bool?)
        // Before start and end frames: a zoom from `zoom` to this, about the middle.
        if zoomFrom == nil, let end = try? c.decodeIfPresent(Double.self, forKey: .legacyZoomEnd) {
            zoomFrom = ZoomFrame(size: 1 / max(zoom, 1))
            zoomTo = ZoomFrame(size: 1 / max(end, 1))
            zoom = 1
        }
    }

    enum CodingKeys: String, CodingKey {
        case scaling, zoom, x, y, rotation, flipH, flipV, cropLeft, cropRight, cropTop, cropBottom
        case zoomFrom, zoomTo, zoomEase, opacity, speed, stabilize, color, reframed
        case legacyZoomEnd = "zoomEnd"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(scaling, forKey: .scaling); try c.encode(zoom, forKey: .zoom); try c.encode(x, forKey: .x); try c.encode(y, forKey: .y)
        try c.encode(rotation, forKey: .rotation); try c.encode(flipH, forKey: .flipH); try c.encode(flipV, forKey: .flipV)
        try c.encode(cropLeft, forKey: .cropLeft); try c.encode(cropRight, forKey: .cropRight)
        try c.encode(cropTop, forKey: .cropTop); try c.encode(cropBottom, forKey: .cropBottom)
        try c.encodeIfPresent(zoomFrom, forKey: .zoomFrom); try c.encodeIfPresent(zoomTo, forKey: .zoomTo); try c.encode(zoomEase, forKey: .zoomEase)
        try c.encode(opacity, forKey: .opacity); try c.encode(speed, forKey: .speed); try c.encode(stabilize, forKey: .stabilize)
        try c.encodeIfPresent(reframed, forKey: .reframed)
        if !color.isDefault { try c.encode(color, forKey: .color) }
    }
}

extension ClipLook {
    /// The picture's own rectangle in the frame (shares of the frame, before zoom and turning),
    /// for the controls drawn over the viewer.
    static func fittedShare(picture: CGSize, frame: CGSize, scaling: Scaling) -> CGSize {
        let w = max(picture.width, 1), h = max(picture.height, 1)
        switch scaling {
        case .stretch: return CGSize(width: 1, height: 1)
        case .fit:
            let s = min(frame.width / w, frame.height / h)
            return CGSize(width: w * s / frame.width, height: h * s / frame.height)
        case .fill:
            let s = max(frame.width / w, frame.height / h)
            return CGSize(width: w * s / frame.width, height: h * s / frame.height)
        }
    }

    /// The picture placed in a frame of this size, `progress` (0…1) through the clip: fitted,
    /// cropped, flipped, zoomed, turned and moved, on black; then dynamic zoom over the frame.
    /// `onBlack`: on the main line, filling the frame with black around it; else (laid over
    /// another picture) clear around it.
    static func place(_ image: CIImage, look: ClipLook?, progress: Double, in size: CGSize, onBlack: Bool = true) -> CIImage {
        let look = look ?? ClipLook()
        let image = look.color.apply(image)
        let extent = image.extent
        let width = max(extent.width, 1), height = max(extent.height, 1)
        var sx = min(size.width / width, size.height / height), sy = sx
        switch look.scaling {
        case .fit: break
        case .fill: sx = max(size.width / width, size.height / height); sy = sx
        case .stretch: sx = size.width / width; sy = size.height / height
        }
        var picture = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY).concatenating(CGAffineTransform(scaleX: sx, y: sy)))
        let w = width * sx, h = height * sy
        if look.hasCrop {
            picture = picture.cropped(to: CGRect(x: w * look.cropLeft, y: h * look.cropBottom,
                                                 width: max(w * (1 - look.cropLeft - look.cropRight), 1),
                                                 height: max(h * (1 - look.cropTop - look.cropBottom), 1)))
        }
        let transform = CGAffineTransform(translationX: -w / 2, y: -h / 2)
            .concatenating(CGAffineTransform(scaleX: (look.flipH ? -1 : 1) * look.zoom, y: (look.flipV ? -1 : 1) * look.zoom))
            .concatenating(CGAffineTransform(rotationAngle: look.rotation * .pi / 180))
            .concatenating(CGAffineTransform(translationX: size.width / 2 + look.x * size.width, y: size.height / 2 + look.y * size.height))
        picture = picture.transformed(by: transform)
        if look.opacity < 1 {
            let o = CGFloat(max(look.opacity, 0))
            picture = picture.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: o, y: 0, z: 0, w: 0),
                                                                           "inputGVector": CIVector(x: 0, y: o, z: 0, w: 0),
                                                                           "inputBVector": CIVector(x: 0, y: 0, z: o, w: 0)])
        }
        let frame = CGRect(origin: .zero, size: size)
        var placed = (onBlack ? picture.composited(over: CIImage(color: .black).cropped(to: frame)) : picture).cropped(to: frame)
        if let f = look.zoomFrame(at: progress) {
            // The part of the frame shown fills it (y counts from the top in the frame).
            let s = 1 / f.size
            let move = CGAffineTransform(translationX: -f.x * size.width, y: -(1 - f.y) * size.height)
                .concatenating(CGAffineTransform(scaleX: s, y: s))
                .concatenating(CGAffineTransform(translationX: size.width / 2, y: size.height / 2))
            placed = placed.transformed(by: move).cropped(to: frame)
        }
        return placed
    }

    /// The same for ffmpeg: a filter chain from an input's picture to `[v<k>]` (trimmed to the
    /// clip, at its speed), fitted to width × height.
    /// `hold`: one frame (at `start`) kept for this long (a held frame). `clear`: on nothing rather
    /// than black, keeping what's around the picture see-through (laid over another).
    static func ffmpegChain(input: String, start: Double, end: Double, length: Double, look: ClipLook?, k: Int,
                            width: Int, height: Int, rate: String, steadied: Bool = false, finish: [String] = [],
                            hold: Double? = nil, clear: Bool = false) -> [String] {
        func number(_ value: Double) -> String { String(format: "%.4f", value) }
        let look = look ?? ClipLook()
        var steps = ["trim=start=\(number(start)):end=\(number(end))",
                     look.speed != 1 && hold == nil ? "setpts=(PTS-STARTPTS)/\(number(look.speed))" : "setpts=PTS-STARTPTS"]
        if let hold { steps.append("trim=end_frame=1,tpad=stop_mode=clone:stop_duration=\(number(hold))") }
        // Not steadied yet: ffmpeg's own (rougher) stabilizer.
        if look.stabilize, !steadied { steps.append("deshake") }
        if !look.color.isDefault, let cube = look.color.cubeFile() {
            steps.append("format=rgb24,lut3d=file='\(cube.path.replacingOccurrences(of: "'", with: "\\'"))'")
        }
        switch look.scaling {
        case .fit: steps.append("scale=\(width):\(height):force_original_aspect_ratio=decrease")
        case .fill: steps.append("scale=\(width):\(height):force_original_aspect_ratio=increase")
        case .stretch: steps.append("scale=\(width):\(height)")
        }
        steps.append("setsar=1")
        if look.hasCrop {
            // Cut, then put back where it was on black: cropping doesn't move the picture.
            let keepW = max(1 - look.cropLeft - look.cropRight, 0.01), keepH = max(1 - look.cropTop - look.cropBottom, 0.01)
            steps.append("crop=floor(iw*\(number(keepW))/2)*2:floor(ih*\(number(keepH))/2)*2:iw*\(number(look.cropLeft)):ih*\(number(look.cropTop))")
            steps.append("pad=ceil(iw/\(number(keepW))/2)*2:ceil(ih/\(number(keepH))/2)*2:iw/\(number(keepW))*\(number(look.cropLeft)):ih/\(number(keepH))*\(number(look.cropTop)):black")
        }
        if look.flipH { steps.append("hflip") }
        if look.flipV { steps.append("vflip") }
        if look.zoom != 1 { steps.append("scale=ceil(iw*\(number(look.zoom))/2)*2:ceil(ih*\(number(look.zoom))/2)*2") }
        if look.rotation != 0 {
            // ffmpeg turns clockwise; the look anticlockwise.
            let angle = -look.rotation * .pi / 180
            steps.append("rotate=\(number(angle)):ow='ceil(rotw(\(number(angle)))/2)*2':oh='ceil(roth(\(number(angle)))/2)*2':c=black")
        }
        if look.opacity < 1 {
            let o = number(max(look.opacity, 0))
            steps.append("format=rgb24,colorchannelmixer=rr=\(o):gg=\(o):bb=\(o)")
        }
        let dx = number(look.x * Double(width)), dy = number(-look.y * Double(height))
        var after = "fps=\(rate)"
        if let from = look.zoomFrom?.fitted(), let to = look.zoomTo?.fitted() {
            // Dynamic zoom over the composed frame: zoompan makes one frame per frame it gets.
            let frames = max(Int((length * (Double(rate) ?? 30)).rounded()), 1)
            let t = "min(on/\(frames),1)"
            let eased: String = switch look.zoomEase {
            case .linear: t
            case .easeIn: "pow(\(t),2)"
            case .easeOut: "(1-pow(1-\(t),2))"
            case .easeInOut: "(3*pow(\(t),2)-2*pow(\(t),3))"
            }
            func lerp(_ a: Double, _ b: Double) -> String { "(\(number(a))+(\(number(b - a)))*\(eased))" }
            let size = lerp(from.size, to.size), cx = lerp(from.x, to.x), cy = lerp(from.y, to.y)
            after += ",zoompan=z='1/\(size)':x='\(cx)*iw-iw/zoom/2':y='\(cy)*ih-ih/zoom/2':d=1:s=\(width)x\(height):fps=\(rate)"
        }
        if clear { steps.append("format=yuva420p") }
        return [
            clear ? "color=black@0.0:s=\(width)x\(height):r=\(rate),format=yuva420p[bg\(k)]" : "color=black:s=\(width)x\(height):r=\(rate)[bg\(k)]",
            input + steps.joined(separator: ",") + "[fg\(k)]",
            "[bg\(k)][fg\(k)]overlay=x=(W-w)/2+\(dx):y=(H-h)/2+\(dy):shortest=1\(clear ? ":format=auto" : ""),\(([after] + finish).joined(separator: ",")),format=\(clear ? "yuva420p" : "yuv420p")[v\(k)]",
        ]
    }
}

// MARK: - The inspector's picture settings

/// What the viewer's on-screen controls change: the picture's place, dynamic zoom's frames, or
/// nothing (as Resolve's viewer menu).
enum ViewerControls: String, CaseIterable, Identifiable {
    case transform, dynamicZoom, off
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .transform: "arrow.up.and.down.and.arrow.left.and.right"
        case .dynamicZoom: "plus.magnifyingglass"
        case .off: "eye.slash"
        }
    }
    var title: LocalizedStringKey {
        switch self {
        case .transform: "Transform"
        case .dynamicZoom: "Dynamic Zoom"
        case .off: "Off"
        }
    }
}

/// Transform, cropping, dynamic zoom, composite, speed and stabilization, as in DaVinci
/// Resolve's Video inspector: for a clip in a project and for a file on its own.
struct ClipLookEditor: View {
    let look: ClipLook
    /// The file, for stabilizing it.
    var path: String?
    /// Speed belongs to a clip in a project (a file's own timeline keeps its time).
    var showsSpeed = true
    /// Changes the look: `record` false while a slider moves (one undo step for the drag).
    let change: (Bool, @escaping (inout ClipLook) -> Void) -> Void
    @AppStorage("viewerControls") private var viewer = ViewerControls.transform

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("On the Picture", selection: $viewer) {
                ForEach(ViewerControls.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 8)
            .help("What you can drag on the picture")
            FoldSection(title: "Transform", key: "clip-transform") {
                row("Scaling") {
                    Picker("Scaling", selection: binding(\.scaling)) { ForEach(ClipLook.Scaling.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden()
                }
                slider("Zoom", \.zoom, 0.1...5, format: "%.2f×", reset: 1)
                slider("Position X", \.x, -1...1, format: "%+.0f%%", scale: 100)
                slider("Position Y", \.y, -1...1, format: "%+.0f%%", scale: 100)
                slider("Rotation", \.rotation, -180...180, format: "%+.1f°")
                row("Flip") {
                    Toggle(isOn: binding(\.flipH)) { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                        .toggleStyle(.button).help("Flip left to right")
                    Toggle(isOn: binding(\.flipV)) { Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
                        .toggleStyle(.button).help("Flip upside down")
                    Spacer()
                }
            }
            FoldSection(title: "Cropping", key: "clip-crop", open: false) {
                slider("Left", \.cropLeft, 0...0.5, format: "%.0f%%", scale: 100)
                slider("Right", \.cropRight, 0...0.5, format: "%.0f%%", scale: 100)
                slider("Top", \.cropTop, 0...0.5, format: "%.0f%%", scale: 100)
                slider("Bottom", \.cropBottom, 0...0.5, format: "%.0f%%", scale: 100)
            }
            FoldSection(title: "Dynamic Zoom", key: "clip-dynamic", open: false) {
                row("Zoom") {
                    Toggle("Dynamic Zoom", isOn: Binding(get: { look.hasDynamicZoom }, set: { on in
                        change(true) { look in
                            if on { look.startDynamicZoom() } else { look.zoomFrom = nil; look.zoomTo = nil }
                        }
                        if on { viewer = .dynamicZoom }
                    }))
                    .toggleStyle(.switch).labelsHidden()
                    Spacer()
                    if look.hasDynamicZoom {
                        Button { change(true) { $0.swapDynamicZoom() } } label: { Label("Swap", systemImage: "arrow.left.arrow.right") }
                            .help("Zoom the other way: start where it ends")
                    }
                }
                if look.hasDynamicZoom {
                    row("Ease") {
                        Picker("Ease", selection: binding(\.zoomEase)) { ForEach(ClipLook.Ease.allCases) { Text($0.title).tag($0) } }
                            .labelsHidden()
                    }
                    frameSlider("Start", \.zoomFrom)
                    frameSlider("End", \.zoomTo)
                    Text("Drag the green (start) and red (end) frames on the picture.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                }
            }
            FoldSection(title: "Colour", key: "clip-colour", open: false) {
                colourSlider("Exposure", \.exposure, -3...3, "%+.2f")
                colourSlider("Contrast", \.contrast, -100...100, "%+.0f")
                colourSlider("Saturation", \.saturation, -100...100, "%+.0f")
                colourSlider("Temperature", \.temperature, -100...100, "%+.0f")
                colourSlider("Tint", \.tint, -100...100, "%+.0f")
                row("LUT") {
                    Text(look.color.lut.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? String(localized: "None"))
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [UTType(filenameExtension: "cube")].compactMap { $0 }
                        guard panel.runModal() == .OK, let url = panel.url, LUTFile.read(url.path) != nil else { return }
                        change(true) { $0.color.lut = url.path }
                    }
                    if look.color.lut != nil {
                        Button { change(true) { $0.color.lut = nil } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                    }
                }
                if look.color.lut != nil { colourSlider("LUT Amount", \.lutAmount, 0...1, "%.2f", reset: 1) }
            }
            FoldSection(title: "Composite", key: "clip-composite", open: false) {
                slider("Opacity", \.opacity, 0...1, format: "%.0f%%", scale: 100, reset: 1)
            }
            if showsSpeed {
            FoldSection(title: "Speed", key: "clip-speed", open: false) {
                row("Speed") {
                    Picker("Speed", selection: binding(\.speed)) {
                        ForEach([0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                    }
                    .labelsHidden()
                }
            }
            }
            FoldSection(title: "Stabilization", key: "clip-stabilize", open: false) {
                StabilizeRow(look: look, path: path, change: change)
            }
            if !look.isDefault {
                Button("Reset Picture") { change(true) { $0 = ClipLook() } }
                    .buttonStyle(.link)
                    .padding(.horizontal, 8)
            }
        }
    }

    private func binding<T>(_ path: WritableKeyPath<ClipLook, T>) -> Binding<T> {
        Binding(get: { look[keyPath: path] }, set: { value in change(true) { $0[keyPath: path] = value } })
    }

    private func row<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true).frame(width: 96, alignment: .leading)
            HStack(spacing: 6) { content() }.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(minHeight: 28)
    }

    private func slider(_ title: LocalizedStringKey, _ path: WritableKeyPath<ClipLook, Double>, _ range: ClosedRange<Double>,
                        format: String, scale: Double = 1, reset: Double = 0) -> some View {
        let value = look[keyPath: path]
        return row(title) {
            Slider(value: Binding(get: { value }, set: { new in change(false) { $0[keyPath: path] = new } }), in: range) { editing in
                if !editing { change(true) { _ in } }
            }
            Text(String(format: format, value * scale)).font(.caption.monospacedDigit())
                .foregroundStyle(value == reset ? .tertiary : .secondary)
                .frame(minWidth: 46, alignment: .trailing)
                .fixedSize()
                .onTapGesture(count: 2) { change(true) { $0[keyPath: path] = reset } }
                .help("Double-click to reset")
        }
    }

    private func colourSlider(_ title: LocalizedStringKey, _ path: WritableKeyPath<ClipColor, Double>, _ range: ClosedRange<Double>,
                              _ format: String, reset: Double = 0) -> some View {
        let value = look.color[keyPath: path]
        return row(title) {
            Slider(value: Binding(get: { value }, set: { new in change(false) { $0.color[keyPath: path] = new } }), in: range) { editing in
                if !editing { change(true) { _ in } }
            }
            Text(String(format: format, value)).font(.caption.monospacedDigit()).foregroundStyle(value == reset ? .tertiary : .secondary)
                .frame(minWidth: 46, alignment: .trailing)
                .fixedSize()
                .onTapGesture(count: 2) { change(true) { $0.color[keyPath: path] = reset } }
        }
    }

    /// A dynamic zoom frame's size (how far in), as a zoom.
    private func frameSlider(_ title: LocalizedStringKey, _ path: WritableKeyPath<ClipLook, ClipLook.ZoomFrame?>) -> some View {
        let frame = look[keyPath: path] ?? ClipLook.ZoomFrame()
        return row(title) {
            Slider(value: Binding(get: { 1 / frame.size }, set: { z in
                change(false) { var f = $0[keyPath: path] ?? .init(); f.size = 1 / z; $0[keyPath: path] = f.fitted() }
            }), in: 1...4) { editing in if !editing { change(true) { _ in } } }
            Text(String(format: "%.2f×", 1 / frame.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
    }
}

// MARK: - Colour

/// A clip's colour: the basics, and a .cube LUT (a camera's log to normal, a creative look),
/// all in one lookup table, so the viewer and the export (ffmpeg's lut3d) show the same.
struct ClipColor: Codable, Hashable {
    var exposure = 0.0      // stops
    var contrast = 0.0      // -100…100
    var saturation = 0.0    // -100…100
    var temperature = 0.0   // cooler -100 … warmer 100
    var tint = 0.0          // green -100 … magenta 100
    /// A .cube file, and how much of it (0…1).
    var lut: String?
    var lutAmount = 1.0

    var isDefault: Bool { self == ClipColor() }

    static let size = 33

    nonisolated(unsafe) private static var cubes: [ClipColor: Data] = [:]
    private static let lock = NSLock()

    /// The table, as RGBA floats (red fastest), in sRGB-encoded values.
    func cube() -> Data {
        Self.lock.lock()
        if let known = Self.cubes[self] { Self.lock.unlock(); return known }
        Self.lock.unlock()
        let n = Self.size
        let user = lut.flatMap(LUTFile.read)
        var values = [Float](repeating: 0, count: n * n * n * 4)
        let gain = pow(2, exposure), t = temperature / 100, g = tint / 100
        let sat = 1 + saturation / 100, con = 1 + contrast / 100 * 0.6
        var i = 0
        for b in 0..<n {
            for gi in 0..<n {
                for r in 0..<n {
                    var c = [Double(r), Double(gi), Double(b)].map { $0 / Double(n - 1) }
                    if let user {
                        let looked = user.sample(c[0], c[1], c[2])
                        c = zip(c, looked).map { $0 + ($1 - $0) * lutAmount }
                    }
                    // Exposure and white balance in linear light.
                    var lin = c.map(DevelopLUT.decode)
                    lin = [lin[0] * gain * (1 + t * 0.25), lin[1] * gain * (1 - g * 0.15), lin[2] * gain * (1 - t * 0.25)]
                    c = lin.map(DevelopLUT.encode)
                    // Contrast around the middle, saturation around grey.
                    c = c.map { 0.5 + ($0 - 0.5) * con }
                    let y = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
                    c = c.map { min(max(y + ($0 - y) * sat, 0), 1) }
                    values[i] = Float(c[0]); values[i + 1] = Float(c[1]); values[i + 2] = Float(c[2]); values[i + 3] = 1
                    i += 4
                }
            }
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        Self.lock.lock(); Self.cubes[self] = data; if Self.cubes.count > 32 { Self.cubes.removeValue(forKey: Self.cubes.keys.first!) }; Self.lock.unlock()
        return data
    }

    /// The same table as a .cube file, for ffmpeg.
    func cubeFile() -> URL? {
        let data = cube()
        let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var text = "LUT_3D_SIZE \(Self.size)\n"
        for i in stride(from: 0, to: floats.count, by: 4) {
            text += String(format: "%.6f %.6f %.6f\n", floats[i], floats[i + 1], floats[i + 2])
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-colour-\(abs(hashValue)).cube")
        return (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }

    func apply(_ image: CIImage) -> CIImage {
        guard !isDefault else { return image }
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: ["inputCubeDimension": Self.size, "inputCubeData": cube(),
                                                                               "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!])
    }
}

/// A .cube lookup table file (Resolve, Premiere, camera makers' LUTs).
struct LUTFile {
    let size: Int
    let values: [Double]   // r fastest, rgb triples
    let domainMin: [Double], domainMax: [Double]

    nonisolated(unsafe) private static var known: [String: LUTFile] = [:]
    private static let lock = NSLock()

    static func read(_ path: String) -> LUTFile? {
        lock.lock(); if let found = known[path] { lock.unlock(); return found }; lock.unlock()
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var size = 0, values: [Double] = [], low = [0.0, 0, 0], high = [1.0, 1, 1]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = parts.first, !first.hasPrefix("#") else { continue }
            switch first {
            case "LUT_3D_SIZE": size = Int(parts.dropFirst().first ?? "") ?? 0
            case "DOMAIN_MIN": low = parts.dropFirst().compactMap { Double($0) }
            case "DOMAIN_MAX": high = parts.dropFirst().compactMap { Double($0) }
            default:
                let numbers = parts.compactMap { Double($0) }
                if numbers.count == 3 { values += numbers }
            }
        }
        guard size > 1, values.count == size * size * size * 3, low.count == 3, high.count == 3 else { return nil }
        let file = LUTFile(size: size, values: values, domainMin: low, domainMax: high)
        lock.lock(); known[path] = file; lock.unlock()
        return file
    }

    /// The table's colour for this one (trilinear).
    func sample(_ r: Double, _ g: Double, _ b: Double) -> [Double] {
        let n = Double(size - 1)
        func coord(_ v: Double, _ k: Int) -> Double { min(max((v - domainMin[k]) / max(domainMax[k] - domainMin[k], 1e-6), 0), 1) * n }
        let x = coord(r, 0), y = coord(g, 1), z = coord(b, 2)
        let x0 = Int(x), y0 = Int(y), z0 = Int(z)
        let x1 = min(x0 + 1, size - 1), y1 = min(y0 + 1, size - 1), z1 = min(z0 + 1, size - 1)
        let fx = x - Double(x0), fy = y - Double(y0), fz = z - Double(z0)
        func at(_ i: Int, _ j: Int, _ k: Int) -> [Double] {
            let o = ((k * size + j) * size + i) * 3
            return [values[o], values[o + 1], values[o + 2]]
        }
        func mix(_ a: [Double], _ b: [Double], _ t: Double) -> [Double] { zip(a, b).map { $0 + ($1 - $0) * t } }
        let c00 = mix(at(x0, y0, z0), at(x1, y0, z0), fx), c10 = mix(at(x0, y1, z0), at(x1, y1, z0), fx)
        let c01 = mix(at(x0, y0, z1), at(x1, y0, z1), fx), c11 = mix(at(x0, y1, z1), at(x1, y1, z1), fx)
        return mix(mix(c00, c10, fy), mix(c01, c11, fy), fz)
    }
}
