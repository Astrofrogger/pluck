import SwiftUI

/// How "before" shows next to "after".
enum BeforeAfter: String, CaseIterable {
    case off, split, sideBySide
    var next: BeforeAfter { self == .off ? .split : self == .split ? .sideBySide : .off }
}

/// What the Photo page is doing right now, shared between the inspector and the picture.
@MainActor
@Observable
final class PhotoEditing {
    static let shared = PhotoEditing()
    /// With several photos selected, a change goes to all of them (on); off, only to the one shown.
    /// Switches back on when the selection changes to a different set.
    var syncAll = true
    /// How many photos Level Exposure would reach (the selection); it needs two.
    var levelCount = 0
    /// The room above white the photo's screen has now (1: none, an SDR screen).
    var headroom = 1.0
    /// The photos a change reaches: all selected while syncing, else only the one shown.
    func targets(_ paths: [String], shown: String?) -> [String] {
        if syncAll || paths.count < 2 { return paths }
        return shown.map { [$0] } ?? Array(paths.prefix(1))
    }
    /// One change to the photos it reaches (one undo step).
    func edit(_ paths: [String], shown: String?, _ body: (inout PhotoRecord) -> Void) {
        PhotoCatalog.shared.update(targets(paths, shown: shown)) { record in
            body(&record)
            record.edited = .now
        }
    }
    /// The crop frame is shown on the picture.
    var cropping = false
    /// The photo is shown as shot while \ is held.
    var asShot = false
    /// Before and after on the loupe: off, one picture split by a line, or two side by side (B cycles).
    var beforeAfter: BeforeAfter = .off
    /// Where the line stands, as a share of the photo that shows (0 left, 1 right).
    var split = 0.5
    /// The snapshot "before" shows; nil is the photo as shot.
    var beforeSnapshot: UUID?
    func cycleBeforeAfter() { beforeAfter = beforeAfter.next }
    /// How far in the photo is shown: nil fits it in the view; 1 is 100% (one photo pixel per
    /// screen pixel). Z toggles fit and 100%, ⌘+ and ⌘− step, pinching goes anywhere between.
    var zoom: Double?
    var zoomed: Bool {
        get { zoom != nil }
        set { zoom = newValue ? (zoom ?? 1) : nil }
    }
    static let zoomSteps: [Double] = [0.25, 0.5, 1, 2, 4]
    /// Where both photos in Compare look (shares of the photo), and the drag in progress.
    var compareCenter = CGPoint(x: 0.5, y: 0.5)
    var compareDrag: CGSize = .zero
    /// Clipped highlights shown red and clipped shadows blue (J).
    var showClipping = false
    /// The Colour Mixer's band shown, and dragging on the photo to change colours.
    var mixerBand = 0
    var mixerTargeting = false
    /// What's typed in the Adjust panel's search (tools whose name matches show).
    var toolQuery = ""
    /// The keyboard shortcuts shown (? or the … menu).
    var showingKeys = false
    /// A look being pointed at in Looks: shown on the big photo until the pointer leaves.
    var previewRecord: PhotoRecord?
    /// The section held to see the photo without it (its eye in the Adjust panel).
    var peek: AdjustSection?
    /// The mask the pointer is over in the list (shown in red, like the chosen one).
    var hoverMask: UUID?
    /// The mask being shaped (its handles on the photo, shown in red), and which of its parts.
    var selectedMask: UUID?
    var selectedPart: UUID?
    var maskOverlay = true
    var brushSize = 0.05
    var brushSoftness = 0.5
    var brushErase = false
    /// Finding an object from a click (macOS 27), and what to say about it.
    var findingObject = false
    var objectNote: String?

    func zoomIn() { zoom = Self.zoomSteps.first { $0 > (zoom ?? 0.2) + 0.001 } ?? Self.zoomSteps.last }
    func zoomOut() {
        guard let current = zoom else { return }
        zoom = Self.zoomSteps.last { $0 < current - 0.001 }
    }
    /// The big picture's histogram (red, green, blue in 64 steps).
    var histogram: [[Float]] = []
    /// Photos having their noise taken out (kept here, so it goes on when you look elsewhere).
    private(set) var denoising: Set<String> = []
    private(set) var denoiseProblem: String?
    /// The export running (kept here, so it shows wherever you go and come back).
    var exporting = false
    var exportDone = 0
    var exportTotal = 0
    var exportProblem: String?
    var exportFolder: URL?

    /// Denoises these photos one after the other, then uses the clean ones to develop them.
    func denoise(_ paths: [String], strength: Int, ai: Bool = false) {
        let waiting = paths.filter { !denoising.contains($0) }
        guard !waiting.isEmpty else { return }
        denoising.formUnion(waiting)
        denoiseProblem = nil
        Task {
            for path in waiting {
                do {
                    try await PhotoRender.denoise(path, strength: ai ? 1000 + strength : strength, worker: 5)
                    PhotoCatalog.shared.update([path]) { $0.denoise = strength; $0.denoiseAI = ai; $0.edited = .now }
                } catch {
                    denoiseProblem = error.localizedDescription
                }
                denoising.remove(path)
            }
        }
    }
}

// MARK: - Curves

/// Tone curves you shape by hand: click to add a point, drag it, double-click to remove it.
/// One curve for brightness and one per colour.
struct CurvesEditor: View {
    let curves: PhotoCurves
    let change: (PhotoCurves) -> Void
    @State private var channel = Channel.master
    @State private var dragging: Int?

    enum Channel: String, CaseIterable, Identifiable {
        case master, red, green, blue
        var id: String { rawValue }
        var color: Color {
            switch self {
            case .master: .primary
            case .red: .red
            case .green: .green
            case .blue: .blue
            }
        }
        var path: WritableKeyPath<PhotoCurves, [CurvePoint]> {
            switch self {
            case .master: \.master
            case .red: \.red
            case .green: \.green
            case .blue: \.blue
            }
        }
    }

    private var points: [CurvePoint] { curves[keyPath: channel.path].sorted { $0.x < $1.x } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Channel.allCases) { item in
                    Button { channel = item } label: {
                        Circle()
                            .fill(item == .master ? AnyShapeStyle(.white) : AnyShapeStyle(item.color))
                            .frame(width: 12, height: 12)
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-3).opacity(channel == item ? 1 : 0))
                            .padding(4)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(item == .master ? Text("Brightness") : Text(item.rawValue.capitalized))
                }
                Spacer()
                if curves[keyPath: channel.path] != PhotoCurves.straight {
                    Button("Reset") {
                        var new = curves
                        new[keyPath: channel.path] = PhotoCurves.straight
                        change(new)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            GeometryReader { geo in
                let size = geo.size
                ZStack {
                    RoundedRectangle(cornerRadius: Design.Radius.small).fill(.black.opacity(0.25))
                    grid(size)
                    // The other channels, faintly.
                    ForEach(Channel.allCases.filter { $0 != channel && curves[keyPath: $0.path] != PhotoCurves.straight }) { other in
                        line(curves[keyPath: other.path], size).stroke(other.color.opacity(0.35), lineWidth: 1)
                    }
                    line(points, size).stroke(channel.color, lineWidth: 1.5)
                    ForEach(points.indices, id: \.self) { index in
                        let p = points[index]
                        Circle()
                            .fill(dragging == index ? Color.accentColor : channel.color)
                            .frame(width: 9, height: 9)
                            .position(x: p.x * size.width, y: (1 - p.y) * size.height)
                    }
                }
                .contentShape(.rect)
                .gesture(drag(size))
                .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in remove(near: tap.location, size) })
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .padding(.horizontal, 8)
    }

    private func grid(_ size: CGSize) -> some View {
        Path { path in
            for i in 1..<4 {
                let x = size.width * Double(i) / 4, y = size.height * Double(i) / 4
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
            }
            path.move(to: CGPoint(x: 0, y: size.height)); path.addLine(to: CGPoint(x: size.width, y: 0))
        }
        .stroke(.white.opacity(0.08), lineWidth: 1)
    }

    private func line(_ points: [CurvePoint], _ size: CGSize) -> Path {
        let curve = Curve(points)
        return Path { path in
            for i in 0...64 {
                let x = Double(i) / 64, y = min(max(curve.value(x), 0), 1)
                let point = CGPoint(x: x * size.width, y: (1 - y) * size.height)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }

    private func drag(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                var list = points
                let x = min(max(value.location.x / size.width, 0), 1), y = min(max(1 - value.location.y / size.height, 0), 1)
                if dragging == nil {
                    let start = value.startLocation
                    if let near = list.indices.min(by: { distance(list[$0], start, size) < distance(list[$1], start, size) }),
                       distance(list[near], start, size) < 12 {
                        dragging = near
                    } else {
                        list.append(CurvePoint(x: x, y: y))
                        list.sort { $0.x < $1.x }
                        dragging = list.firstIndex { $0.x == x }
                    }
                }
                guard let index = dragging, list.indices.contains(index) else { return }
                // The ends stay at the ends; the others stay between their neighbours.
                let isEnd = index == 0 || index == list.count - 1
                let low = index == 0 ? 0 : list[index - 1].x + 0.01, high = index == list.count - 1 ? 1 : list[index + 1].x - 0.01
                list[index] = CurvePoint(x: isEnd ? list[index].x : min(max(x, low), high), y: y)
                set(list)
            }
            .onEnded { _ in dragging = nil }
    }

    private func remove(near location: CGPoint, _ size: CGSize) {
        var list = points
        guard let index = list.indices.min(by: { distance(list[$0], location, size) < distance(list[$1], location, size) }),
              distance(list[index], location, size) < 12, index != 0, index != list.count - 1 else { return }
        list.remove(at: index)
        set(list)
    }

    private func set(_ list: [CurvePoint]) {
        var new = curves
        new[keyPath: channel.path] = list
        change(new)
    }

    private func distance(_ p: CurvePoint, _ location: CGPoint, _ size: CGSize) -> Double {
        hypot(p.x * size.width - location.x, (1 - p.y) * size.height - location.y)
    }
}

// MARK: - Colour wheels

/// Lift, gamma, gain and offset, as in DaVinci Resolve: drag the dot towards a colour to push the
/// shadows, midtones, highlights or everything that way; the slider under it is the brightness.
struct ColorWheelsEditor: View {
    let wheels: ColorWheels
    let change: (ColorWheels) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 12) {
            wheel("Shadows", \.lift)
            wheel("Midtones", \.gamma)
            wheel("Highlights", \.gain)
            wheel("Offset", \.offset)
        }
        .padding(.horizontal, 8)
    }

    private func wheel(_ title: LocalizedStringKey, _ path: WritableKeyPath<ColorWheels, ColorWheels.Wheel>) -> some View {
        let value = wheels[keyPath: path]
        return VStack(spacing: 4) {
            Wheel(x: value.x, y: value.y) { x, y in
                var new = wheels
                new[keyPath: path].x = x
                new[keyPath: path].y = y
                change(new)
            }
            .frame(width: 92, height: 92)
            Slider(value: Binding(get: { value.master }, set: { m in var new = wheels; new[keyPath: path].master = m; change(new) }), in: -0.5...0.5)
                .controlSize(.mini)
            HStack(spacing: 4) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                if !value.isDefault {
                    Button { var new = wheels; new[keyPath: path] = .init(); change(new) } label: {
                        Image(systemName: "arrow.counterclockwise").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Reset")
                }
            }
        }
    }

    /// One wheel. The dot's position is the push (the full rim is a strong push).
    private struct Wheel: View {
        let x: Double
        let y: Double
        let change: (Double, Double) -> Void
        static let reach = 0.4

        var body: some View {
            GeometryReader { geo in
                let r = min(geo.size.width, geo.size.height) / 2
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                ZStack {
                    Circle().fill(AngularGradient(colors: [.red, .pink, .blue, .cyan, .green, .yellow, .red], center: .center))
                        .saturation(0.55)
                    Circle().fill(RadialGradient(colors: [.gray, .gray.opacity(0)], center: .center, startRadius: 0, endRadius: r))
                    Circle().strokeBorder(.black.opacity(0.3), lineWidth: 1)
                    Path { p in
                        p.move(to: CGPoint(x: center.x - 4, y: center.y)); p.addLine(to: CGPoint(x: center.x + 4, y: center.y))
                        p.move(to: CGPoint(x: center.x, y: center.y - 4)); p.addLine(to: CGPoint(x: center.x, y: center.y + 4))
                    }
                    .stroke(.white.opacity(0.5), lineWidth: 1)
                    Circle()
                        .strokeBorder(.white, lineWidth: 2)
                        .background(Circle().fill(.black.opacity(0.25)))
                        .frame(width: 12, height: 12)
                        .position(x: center.x + x / Self.reach * r, y: center.y - y / Self.reach * r)
                }
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    var dx = (value.location.x - center.x) / r, dy = -(value.location.y - center.y) / r
                    let length = hypot(dx, dy)
                    if length > 1 { dx /= length; dy /= length }
                    change(dx * Self.reach, dy * Self.reach)
                })
                .onTapGesture(count: 2) { change(0, 0) }
            }
        }
    }
}

// MARK: - Crop

/// The crop frame over the picture: drag inside to move it, drag a corner or edge to size it.
/// With an aspect chosen, the frame keeps it.
struct CropOverlay: View {
    /// Where the picture sits in the view.
    let frame: CGRect
    /// The picture's own width over height.
    let pictureRatio: Double
    let rect: CropRect
    let ratio: Double?
    var angle: Double = 0
    let change: (CropRect) -> Void
    /// Straightening by dragging outside the frame (degrees).
    var rotate: ((Double) -> Void)?
    @State private var start: CropRect?
    @State private var angleStart: Double?

    var body: some View {
        let box = CGRect(x: frame.minX + rect.x * frame.width, y: frame.minY + rect.y * frame.height,
                         width: rect.width * frame.width, height: rect.height * frame.height)
        ZStack {
            // Outside the frame: drag round it to turn the photo.
            Color.clear
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        guard let rotate else { return }
                        if angleStart == nil { angleStart = angle }
                        let c = CGPoint(x: box.midX, y: box.midY)
                        let a0 = atan2(value.startLocation.y - c.y, value.startLocation.x - c.x)
                        let a1 = atan2(value.location.y - c.y, value.location.x - c.x)
                        var delta = (a1 - a0) * 180 / .pi
                        if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
                        rotate(min(max((angleStart ?? 0) - delta, -45), 45))
                    }
                    .onEnded { _ in angleStart = nil })
            // Dim what's cut away.
            Path { p in
                p.addRect(frame)
                p.addRect(box)
            }
            .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            // Thirds.
            Path { p in
                for i in 1..<3 {
                    let x = box.minX + box.width * Double(i) / 3, y = box.minY + box.height * Double(i) / 3
                    p.move(to: CGPoint(x: x, y: box.minY)); p.addLine(to: CGPoint(x: x, y: box.maxY))
                    p.move(to: CGPoint(x: box.minX, y: y)); p.addLine(to: CGPoint(x: box.maxX, y: y))
                }
            }
            .stroke(.white.opacity(0.35), lineWidth: 0.5)
            .allowsHitTesting(false)
            Rectangle().strokeBorder(.white, lineWidth: 1.5)
                .frame(width: box.width, height: box.height)
                .position(x: box.midX, y: box.midY)
                .contentShape(Rectangle().size(width: box.width, height: box.height))
                .gesture(handle(left: true, top: true, right: true, bottom: true))
            ForEach(Handle.allCases, id: \.self) { h in
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white)
                    .frame(width: h.isCorner ? 14 : (h.horizontal ? 22 : 5), height: h.isCorner ? 14 : (h.horizontal ? 5 : 22))
                    .shadow(radius: 2)
                    .padding(8)
                    .contentShape(.rect)
                    .position(h.point(in: box))
                    .gesture(handle(left: h.left, top: h.top, right: h.right, bottom: h.bottom))
            }
        }
    }

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
        var left: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
        var right: Bool { [.topRight, .right, .bottomRight].contains(self) }
        var top: Bool { [.topLeft, .top, .topRight].contains(self) }
        var bottom: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }
        var isCorner: Bool { (left || right) && (top || bottom) }
        var horizontal: Bool { self == .top || self == .bottom }
        func point(in r: CGRect) -> CGPoint {
            CGPoint(x: left ? r.minX : (right ? r.maxX : r.midX), y: top ? r.minY : (bottom ? r.maxY : r.midY))
        }
    }

    /// All four sides at once moves the frame; some of them sizes it.
    private func handle(left: Bool, top: Bool, right: Bool, bottom: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let from = start ?? rect
                if start == nil { start = rect }
                let dx = value.translation.width / frame.width, dy = value.translation.height / frame.height
                var r = from
                if left && right && top && bottom {
                    r.x = min(max(from.x + dx, 0), 1 - from.width)
                    r.y = min(max(from.y + dy, 0), 1 - from.height)
                    change(r)
                    return
                }
                var minX = from.x, minY = from.y, maxX = from.x + from.width, maxY = from.y + from.height
                if left { minX = min(max(from.x + dx, 0), maxX - 0.05) }
                if right { maxX = max(min(from.x + from.width + dx, 1), minX + 0.05) }
                if top { minY = min(max(from.y + dy, 0), maxY - 0.05) }
                if bottom { maxY = max(min(from.y + from.height + dy, 1), minY + 0.05) }
                r = CropRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                // Shift keeps the shape it had (in free crops too).
                let shift = NSEvent.modifierFlags.contains(.shift)
                let locked = ratio ?? (shift ? from.width * pictureRatio / max(from.height, 0.0001) : nil)
                if let locked { r = keep(r, ratio: locked, left: left, top: top, sizingWidth: left || right) }
                change(r)
            }
            .onEnded { _ in start = nil }
    }

    /// Fixes the frame to the aspect (in the picture's own pixels), from the side being dragged.
    private func keep(_ r: CropRect, ratio: Double, left: Bool, top: Bool, sizingWidth: Bool) -> CropRect {
        // Shares to the same unit: width share × picture ratio over height share is the aspect.
        var r = r
        if sizingWidth {
            var height = r.width * pictureRatio / ratio
            if height > 1 { height = 1; r.width = ratio / pictureRatio }
            if top { r.y = r.y + r.height - height }
            r.height = height
        } else {
            var width = r.height * ratio / pictureRatio
            if width > 1 { width = 1; r.height = pictureRatio / ratio }
            if left { r.x = r.x + r.width - width }
            r.width = width
        }
        r.x = min(max(r.x, 0), 1 - r.width)
        r.y = min(max(r.y, 0), 1 - r.height)
        return r
    }

    /// The largest frame of this aspect, centred.
    static func centered(ratio: Double?, pictureRatio: Double) -> CropRect {
        guard let ratio else { return CropRect() }
        if ratio > pictureRatio {
            let height = pictureRatio / ratio
            return CropRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
        }
        let width = ratio / pictureRatio
        return CropRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
    }
}

// MARK: - Sections that fold

/// A sidebar section you can fold away by its title; remembers whether it's open.
struct FoldSection<Content: View>: View {
    let title: LocalizedStringKey
    let key: String
    var open = true
    @ViewBuilder var content: Content
    @AppStorage private var isOpen: Bool

    init(title: LocalizedStringKey, key: String, open: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.key = key
        self.open = open
        self.content = content()
        _isOpen = AppStorage(wrappedValue: open, "fold-" + key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(title).font(.caption2.weight(.semibold)).textCase(.uppercase)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if isOpen { content }
        }
    }
}

// MARK: - Colour mixer

/// Hue, saturation and luminance for eight bands of colour.
struct ColorMixerEditor: View {
    let mixer: ColorMixer
    let change: (ColorMixer) -> Void
    @State private var editing = PhotoEditing.shared

    var body: some View {
        let band = ColorMixer.Band(rawValue: editing.mixerBand) ?? .red
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                ForEach(ColorMixer.Band.allCases) { item in
                    let edited = mixer.hue[item.rawValue] != 0 || mixer.saturation[item.rawValue] != 0 || mixer.luminance[item.rawValue] != 0
                    Button { editing.mixerBand = item.rawValue } label: {
                        VStack(spacing: 3) {
                            Circle().fill(Self.colour(item)).frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(.white, lineWidth: item == band ? 2 : 0))
                                .shadow(color: .black.opacity(0.3), radius: 1)
                            Circle().fill(edited ? Color.accentColor : .clear).frame(width: 4, height: 4)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(item.title)
                    .accessibilityLabel(Text(item.title))
                    .accessibilityAddTraits(item == band ? .isSelected : [])
                }
                Toggle(isOn: $editing.mixerTargeting) { Image(systemName: "scope") }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Drag on the photo: up and down changes the colour under the pointer (saturation; with ⌥ luminance, with ⇧ hue)")
                    .accessibilityLabel(Text("Change a colour by dragging on the photo"))
            }
            .padding(.horizontal, 8)
            AdjustSlider(title: "Hue", value: mixer.hue[band.rawValue], range: -100...100, track: .hues) { set(\.hue, band, $0) }
            AdjustSlider(title: "Saturation", value: mixer.saturation[band.rawValue], range: -100...100, track: .colour(Self.colour(band))) { set(\.saturation, band, $0) }
            AdjustSlider(title: "Luminance", value: mixer.luminance[band.rawValue], range: -100...100) { set(\.luminance, band, $0) }
        }
    }

    private func set(_ aspect: WritableKeyPath<ColorMixer, [Double]>, _ band: ColorMixer.Band, _ value: Double) {
        var new = mixer
        new[keyPath: aspect][band.rawValue] = value
        change(new)
    }

    /// The band's colour (its OkLCh hue, as a swatch).
    static func colour(_ band: ColorMixer.Band) -> Color { PhotoMaskPanel.swatch(band.hue) }
}

/// Dragging on the photo to change the colour under the pointer (the mixer's target): up adds,
/// down takes away; saturation, or luminance with Option, or hue with Shift. The bands near that
/// colour move together, as much as they share it.
struct MixerTarget: View {
    let path: String
    let record: PhotoRecord
    let frame: CGRect
    @State private var editing = PhotoEditing.shared
    @State private var catalog = PhotoCatalog.shared
    @State private var start: (weights: [Double], mixer: ColorMixer, aspect: WritableKeyPath<ColorMixer, [Double]>)?
    @State private var sampling = false
    @State private var travel: CGFloat = 0

    var body: some View {
        Color.clear
            .contentShape(.rect)
            .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    travel = value.translation.height
                    if start == nil, !sampling { begin(at: value.startLocation) }
                    apply()
                }
                .onEnded { _ in start = nil; sampling = false })
    }

    private func begin(at location: CGPoint) {
        sampling = true
        let flags = NSEvent.modifierFlags
        let aspect: WritableKeyPath<ColorMixer, [Double]> = flags.contains(.option) ? \.luminance : flags.contains(.shift) ? \.hue : \.saturation
        let at = CGPoint(x: (location.x - frame.minX) / max(frame.width, 1), y: (location.y - frame.minY) / max(frame.height, 1))
        let path = self.path, record = self.record
        Task {
            guard let colour = await Task.detached(priority: .userInitiated, operation: { PhotoRender.sample(path, record: record, at: at) }).value
            else { return }
            let seen = PhotoRender.describe(colour)
            var weights = ColorMixer.weights(seen.hue)
            let top = max(weights.max() ?? 1, 0.0001)
            weights = weights.map { $0 / top }
            start = (weights, record.adjust.mixer, aspect)
            if let strongest = weights.indices.max(by: { weights[$0] < weights[$1] }) { editing.mixerBand = strongest }
            apply()
        }
    }

    private func apply() {
        guard let start else { return }
        let amount = Double(-travel) * 0.5
        var mixer = start.mixer
        for i in 0..<8 where start.weights[i] > 0.05 {
            mixer[keyPath: start.aspect][i] = min(max(start.mixer[keyPath: start.aspect][i] + amount * start.weights[i], -100), 100)
        }
        catalog.update([path]) { $0.adjust.mixer = mixer; $0.edited = .now }
    }
}

// MARK: - spektrafilm's settings as dials

/// spektrafilm's own settings, named for people and given a sensible range from their defaults.
enum FilmDial {
    /// Plumbing Pluck sets itself (colour spaces, lookup tables, preview sizes): not shown.
    static func isHidden(_ key: String) -> Bool {
        key.hasPrefix("io.") || key.hasPrefix("settings.")
    }

    static func group(of key: String) -> String {
        let parts = key.split(separator: ".")
        return parts.dropLast().joined(separator: ".")
    }

    static func groups(_ keys: some Collection<String>) -> [String] {
        Array(Set(keys.filter { !isHidden($0) }.map(group))).sorted()
    }

    static func title(group: String) -> String {
        let parts = group.split(separator: ".").map(String.init)
        let stage: String = switch parts.first {
        case "camera": String(localized: "Camera")
        case "enlarger": String(localized: "Enlarger")
        case "film_render": String(localized: "Film")
        case "print_render": String(localized: "Paper")
        case "scanner": String(localized: "Scanner")
        default: words(parts.first ?? "")
        }
        return ([stage] + parts.dropFirst().map(words)).joined(separator: " · ")
    }

    static func words(_ name: String) -> String {
        let replaced = name.split(separator: "_").map { word -> String in
            switch word {
            case "um": "µm"
            case "um2": "µm²"
            case "ev": "EV"
            case "agx": "AgX"
            case "rgb": "RGB"
            case "ir": "IR"
            case "uv": "UV"
            case "dir": "DIR"
            default: String(word)
            }
        }.joined(separator: " ")
        return replaced.prefix(1).uppercased() + replaced.dropFirst()
    }

    /// A range around the default that makes sense for the kind of setting.
    static func range(_ key: String, _ value: Double) -> ClosedRange<Double> {
        let name = key.lowercased()
        if name.hasSuffix("_ev") || name.contains("_ev_") { return -4...4 }
        if name.contains("shift") { return -40...40 }
        if name.contains("warmth") { return -1...1 }
        if name.contains("percent") { return 0...max(0.2, value * 3) }
        if name.contains("neutral") { return 0...200 }
        if value == 0 { return 0...1 }
        if value < 0 { return value * 3...0 }
        return 0...max(value * 2.5, value + 1)
    }

    static func isWhole(_ key: String) -> Bool {
        key.contains("n_bounces") || key.contains("n_sub_layers") || key.contains("neutral")
    }
}

/// One group of spektrafilm's settings (the halation, the grain, the enlarger…), folded away.
struct FilmDialGroup: View {
    let group: String
    let keys: [String]
    let value: (String) -> SettingValue?
    let isChanged: (String) -> Bool
    let set: (String, SettingValue) -> Void
    let reset: (String) -> Void
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { withAnimation(.snappy(duration: 0.2)) { open.toggle() } } label: {
                HStack {
                    Text(FilmDial.title(group: group)).font(.callout.weight(.medium))
                    if keys.contains(where: isChanged) { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if open {
                ForEach(keys.filter { !FilmDial.isHidden($0) }, id: \.self) { key in row(key) }
            }
        }
    }

    @ViewBuilder private func row(_ key: String) -> some View {
        let name = FilmDial.words(String(key.split(separator: ".").last ?? ""))
        switch value(key) {
        case .flag(let on):
            line(name, key: key) {
                Toggle(name, isOn: Binding(get: { on }, set: { set(key, .flag($0)) })).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                Spacer()
            }
        case .number(let number):
            dial(name, key: key, value: number, range: FilmDial.range(key, number)) { set(key, .number($0)) }
        case .numbers(let numbers):
            let labels = numbers.count == 3 ? ["R", "G", "B"] : numbers.indices.map { "\($0 + 1)" }
            ForEach(numbers.indices, id: \.self) { i in
                dial(name + " " + labels[i], key: key, value: numbers[i], range: FilmDial.range(key, numbers[i])) { new in
                    var list = numbers
                    list[i] = new
                    set(key, .numbers(list))
                }
            }
        case .text(let text):
            line(name, key: key) {
                TextField(name, text: Binding(get: { text }, set: { set(key, .text($0)) }))
                    .textFieldStyle(.roundedBorder).controlSize(.mini).labelsHidden()
            }
        case nil:
            EmptyView()
        }
    }

    private func line<Content: View>(_ name: String, key: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.caption).foregroundStyle(isChanged(key) ? .primary : .secondary).lineLimit(1)
                .frame(width: 112, alignment: .leading)
                .help(key)
            content()
        }
        .padding(.leading, 16).padding(.trailing, 8)
        .frame(minHeight: 22)
    }

    private func dial(_ name: String, key: String, value: Double, range: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
        let whole = FilmDial.isWhole(key)
        let low = min(range.lowerBound, value), high = max(range.upperBound, value)
        return line(name, key: key) {
            Slider(value: Binding(get: { value }, set: { set(whole ? $0.rounded() : $0) }), in: low...high)
                .controlSize(.mini)
            Text(whole ? String(format: "%.0f", value) : String(format: abs(value) < 10 ? "%.3g" : "%.0f", value))
                .font(.caption2.monospacedDigit())
                .frame(width: 38, alignment: .trailing)
                .onTapGesture(count: 2) { reset(key) }
                .help("Double-click to reset")
        }
    }
}

// MARK: - Histogram

/// The photo's red, green and blue, as in Lightroom, over the Adjust panel.
/// The histogram. Drag on it to move the tone slider for that part (blacks, shadows, exposure,
/// highlights, whites), as in Lightroom; the part under the pointer is named. The triangles in
/// the corners show the clipping on the photo.
struct HistogramView: View {
    let bins: [[Float]]
    /// A drag on a part: the slider's key path and how far (shares of the width).
    var drag: ((WritableKeyPath<PhotoAdjustments, Double>, Double) -> Void)?
    @State private var hover: Int?
    @State private var dragging: Int?
    @State private var last: CGFloat = 0
    @State private var editing = PhotoEditing.shared

    /// The parts, left to right: where they end (shares of the width), name, slider.
    private static let parts: [(Double, LocalizedStringKey, WritableKeyPath<PhotoAdjustments, Double>)] = [
        (0.12, "Blacks", \.blacks), (0.36, "Shadows", \.shadows), (0.64, "Exposure", \.exposure), (0.88, "Highlights", \.highlights), (1, "Whites", \.whites),
    ]

    private static func part(_ share: Double) -> Int { parts.firstIndex { share <= $0.0 } ?? parts.count - 1 }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    if let shade = dragging ?? hover {
                        let from = shade == 0 ? 0 : Self.parts[shade - 1].0, to = Self.parts[shade].0
                        context.fill(Path(CGRect(x: size.width * from, y: 0, width: size.width * (to - from), height: size.height)), with: .color(.white.opacity(0.07)))
                    }
                    guard bins.count == 3 else { return }
                    let colours: [Color] = [.red, .green, .blue]
                    for (channel, values) in bins.enumerated() {
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: size.height))
                        for (i, v) in values.enumerated() {
                            path.addLine(to: CGPoint(x: size.width * CGFloat(i) / CGFloat(values.count - 1), y: size.height * (1 - CGFloat(v))))
                        }
                        path.addLine(to: CGPoint(x: size.width, y: size.height))
                        path.closeSubpath()
                        context.fill(path, with: .color(colours[channel].opacity(0.45)))
                    }
                }
                .blendMode(.plusLighter)
                if let shown = dragging ?? hover {
                    Text(Self.parts[shown].1).font(.caption2.weight(.medium)).foregroundStyle(.white.opacity(0.8)).padding(5)
                }
                HStack {
                    clipTriangle(left: true)
                    Spacer()
                    clipTriangle(left: false)
                }
                .padding(4)
            }
            .contentShape(.rect)
            .onContinuousHover { phase in
                if case .active(let at) = phase { hover = Self.part(at.x / max(geo.size.width, 1)) } else { hover = nil }
            }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    guard let drag else { return }
                    if dragging == nil { dragging = Self.part(value.startLocation.x / max(geo.size.width, 1)); last = value.startLocation.x }
                    let moved = (value.location.x - last) / max(geo.size.width, 1)
                    last = value.location.x
                    if let part = dragging { drag(Self.parts[part].2, moved) }
                }
                .onEnded { _ in dragging = nil })
        }
        .frame(height: 64)
        .background(RoundedRectangle(cornerRadius: Design.Radius.small).fill(.black.opacity(0.35)))
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.small))
        .padding(.horizontal, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Histogram"))
        .help("Drag to change that part of the tones")
    }

    /// Clipping in the shadows (left) or highlights (right): lit when the photo has some; click
    /// to show it on the photo.
    private func clipTriangle(left: Bool) -> some View {
        let values = bins.count == 3 ? bins.map { left ? $0.first ?? 0 : $0.last ?? 0 } : []
        let clipped = values.contains { $0 > 0.02 }
        return Button { editing.showClipping.toggle() } label: {
            Image(systemName: left ? "arrowtriangle.left.fill" : "arrowtriangle.right.fill")
                .font(.system(size: 8))
                .foregroundStyle(clipped ? (left ? Color.blue : Color.red) : .white.opacity(0.35))
                .padding(2)
                .background(editing.showClipping ? Color.white.opacity(0.2) : .clear, in: .rect(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .help("Show clipping (J)")
        .accessibilityLabel(Text(left ? "Shadow clipping" : "Highlight clipping"))
    }
}
