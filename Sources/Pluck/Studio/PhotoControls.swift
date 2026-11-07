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
    /// The Colour Wheels' page chosen per photo (true: Lift, Gamma, Gain and Offset), for this session.
    var wheelsPrimaries: [String: Bool] = [:]
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
    /// Process 5's colour points: the one chosen (nil: the bands), picking one on the photo, and its area shown in red.
    var mixerPoint: Int?
    var pointPicking = false
    var pointOverlay = false
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
    /// The same picture counted for the parade, waveform and vectorscope.
    var scopes: ScopeData?
    /// Photos having their noise taken out (kept here, so it goes on when you look elsewhere).
    private(set) var denoising: Set<String> = []
    private(set) var denoiseProblem: String?
    /// The export running (kept here, so it shows wherever you go and come back).
    var exporting = false
    var exportDone = 0
    var exportTotal = 0
    var exportProblem: String?
    var exportFolder: URL?

    /// Turns Denoise on for these photos with this model (at their Amount; 50, Lightroom's, when it was off), and
    /// works out what's missing.
    func denoise(_ paths: [String], ai: Bool) {
        PhotoCatalog.shared.update(paths) { record in
            if record.denoise == 0 { record.denoise = 50 }
            record.denoiseAI = ai
            record.edited = .now
        }
        analyse(paths)
    }

    /// Works out the clean decode of the denoised photos that don't have one for their model and settings yet
    /// (an edit from before version 2 too), one after the other: once each. The Amount is never worked out.
    func analyse(_ paths: [String]) {
        let catalog = PhotoCatalog.shared
        let waiting = paths.filter { !denoising.contains($0) && catalog.record($0).denoise > 0 && !PhotoRender.hasClean($0, record: catalog.record($0)) }
        guard !waiting.isEmpty else { return }
        denoising.formUnion(waiting)
        denoiseProblem = nil
        Task {
            for path in waiting {
                do {
                    // Again while the model or decoder settings changed during it (the inspector asked while this ran).
                    repeat { try await PhotoRender.denoise(path, record: catalog.record(path), worker: 5) }
                    while catalog.record(path).denoise > 0 && !PhotoRender.hasClean(path, record: catalog.record(path))
                    // (So what shows is developed again, from the clean decode.)
                    catalog.update([path]) { $0.edited = .now }
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
/// One curve for brightness and one per colour; process 5 adds the colour curves (Hue vs Hue, Hue vs Saturation, Hue vs
/// Luminance, Luminance vs Saturation, Saturation vs Saturation), each drawn over its axes' colours, flat in the middle.
struct CurvesEditor: View {
    let curves: PhotoCurves
    /// The colour curves are offered (process 5, without film).
    var colour = false
    let change: (PhotoCurves) -> Void
    @State private var channel: Channel
    @State private var dragging: Int?
    /// A colour curve's point where the drag began (it moves by the drag, so a click doesn't make it jump).
    @State private var origin: CurvePoint?
    /// The Colour Warper shown instead of a curve.
    @State private var warping: Bool

    init(curves: PhotoCurves, colour: Bool = false, start: Channel = .master, warper: Bool = false, change: @escaping (PhotoCurves) -> Void) {
        self.curves = curves
        self.colour = colour
        self.change = change
        _channel = State(initialValue: start)
        _warping = State(initialValue: warper)
    }

    enum Channel: String, CaseIterable, Identifiable {
        case master, red, green, blue, hueHue, hueSat, hueLum, lumSat, satSat
        var id: String { rawValue }
        var color: Color {
            switch self {
            case .red: .red
            case .green: .green
            case .blue: .blue
            default: .primary
            }
        }
        var kind: HueCurves.Kind? { HueCurves.Kind(rawValue: rawValue) }
        var title: Text {
            switch self {
            case .master: Text("Brightness")
            case .red: Text("Red")
            case .green: Text("Green")
            case .blue: Text("Blue")
            case .hueHue: Text("Hue vs Hue")
            case .hueSat: Text("Hue vs Saturation")
            case .hueLum: Text("Hue vs Luminance")
            case .lumSat: Text("Luminance vs Saturation")
            case .satSat: Text("Saturation vs Saturation")
            }
        }
        var path: WritableKeyPath<PhotoCurves, [CurvePoint]> {
            switch self {
            case .red: \.red
            case .green: \.green
            case .blue: \.blue
            default: \.master
            }
        }
    }

    private var shownChannel: Channel { colour || channel.kind == nil ? channel : .master }

    private func stored(_ c: Channel) -> [CurvePoint] {
        if let kind = c.kind { return curves.hue?[keyPath: kind.path] ?? [] }
        return curves[keyPath: c.path]
    }
    private func edited(_ c: Channel) -> Bool { c.kind == nil ? stored(c) != PhotoCurves.straight : !HueCurves.flat(stored(c)) }

    /// The points shown (a flat colour curve shows its starting points).
    private var points: [CurvePoint] {
        let c = shownChannel, list = stored(c)
        return (list.isEmpty ? c.kind?.start ?? list : list).sorted { $0.x < $1.x }
    }

    private func height(_ list: [CurvePoint], _ c: Channel, _ x: Double) -> Double {
        guard let kind = c.kind else { return Curve(list).value(x) }
        return HueCurves.value(list, periodic: kind.periodic, at: x)
    }

    var body: some View {
        let c = shownChannel, warper = warping && colour, warped = !(curves.warp?.isDefault ?? true)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: colour ? 2 : 4) {
                ForEach(Channel.allCases.filter { colour || $0.kind == nil }) { item in
                    Button { channel = item; warping = false } label: {
                        Group {
                            if let kind = item.kind {
                                CurveBackdrop(kind: kind).frame(width: 14, height: 12).clipShape(.rect(cornerRadius: 3))
                            } else {
                                Circle().fill(item == .master ? AnyShapeStyle(.white) : AnyShapeStyle(item.color)).frame(width: 12, height: 12)
                            }
                        }
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.accentColor, lineWidth: 2).padding(-3).opacity(c == item && !warper ? 1 : 0))
                        .overlay(alignment: .bottom) {
                            Circle().fill(Color.accentColor).frame(width: 3, height: 3).offset(y: 6).opacity((item != c || warper) && edited(item) ? 1 : 0)
                        }
                        .padding(4)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(item.title)
                    .accessibilityLabel(item.title)
                    .accessibilityAddTraits(c == item && !warper ? .isSelected : [])
                    if item == .blue, colour { Divider().frame(height: 12) }
                }
                if colour {
                    Button { warping = true } label: {
                        ColourWarper.disc.frame(width: 12, height: 12).clipShape(Circle())
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-3).opacity(warper ? 1 : 0))
                            .overlay(alignment: .bottom) {
                                Circle().fill(Color.accentColor).frame(width: 3, height: 3).offset(y: 6).opacity(!warper && warped ? 1 : 0)
                            }
                            .padding(4)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Colour Warper")
                    .accessibilityLabel(Text("Colour Warper"))
                    .accessibilityAddTraits(warper ? .isSelected : [])
                }
                Spacer()
                if warper ? warped : edited(c) {
                    // (An icon: with the colour curves' swatches the row has no room for the word.)
                    Button { if warper { var new = curves; new.warp = nil; change(new) } else { set(c.kind == nil ? PhotoCurves.straight : [], c) } } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Reset")
                        .accessibilityLabel(Text("Reset"))
                }
            }
            if warper {
                ColourWarper(warp: curves.warp ?? ColourWarp()) { w in var new = curves; new.warp = w.isDefault ? nil : w; change(new) }
            } else {
            GeometryReader { geo in
                let size = geo.size
                ZStack {
                    RoundedRectangle(cornerRadius: Design.Radius.small).fill(.black.opacity(0.25))
                    if let kind = c.kind {
                        CurveBackdrop(kind: kind).opacity(0.55).clipShape(.rect(cornerRadius: Design.Radius.small))
                    }
                    grid(size, flat: c.kind != nil)
                    // The other channels, faintly.
                    if c.kind == nil {
                        ForEach(Channel.allCases.filter { $0.kind == nil && $0 != c && edited($0) }) { other in
                            line(stored(other), other, size).stroke(other.color.opacity(0.35), lineWidth: 1)
                        }
                    }
                    line(points, c, size).stroke(c.kind == nil ? c.color : .white, lineWidth: 1.5)
                    ForEach(points.indices, id: \.self) { index in
                        let p = points[index]
                        Circle()
                            .fill(dragging == index ? Color.accentColor : c.kind == nil ? c.color : .white)
                            .frame(width: 9, height: 9)
                            .shadow(color: .black.opacity(c.kind == nil ? 0 : 0.5), radius: 1)
                            .position(x: p.x * size.width, y: (1 - p.y) * size.height)
                    }
                }
                .contentShape(.rect)
                .gesture(drag(size, c))
                .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in remove(near: tap.location, size, c) })
            }
            .aspectRatio(1, contentMode: .fit)
            }
        }
        .padding(.horizontal, 8)
    }

    private func grid(_ size: CGSize, flat: Bool) -> some View {
        Path { path in
            for i in 1..<4 {
                let x = size.width * Double(i) / 4, y = size.height * Double(i) / 4
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
            }
            if !flat { path.move(to: CGPoint(x: 0, y: size.height)); path.addLine(to: CGPoint(x: size.width, y: 0)) }
        }
        .stroke(.white.opacity(flat ? 0.14 : 0.08), lineWidth: 1)
    }

    private func line(_ points: [CurvePoint], _ c: Channel, _ size: CGSize) -> Path {
        let curve = Curve(points)
        return Path { path in
            for i in 0...128 {
                let x = Double(i) / 128, y = min(max(c.kind == nil ? curve.value(x) : height(points, c, x), 0), 1)
                let point = CGPoint(x: x * size.width, y: (1 - y) * size.height)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }

    private func drag(_ size: CGSize, _ c: Channel) -> some Gesture {
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
                        // (A colour curve's new point goes on the curve, then moves with the drag.)
                        let at = c.kind?.periodic == true ? min(x, 0.999) : x
                        list.append(CurvePoint(x: at, y: c.kind == nil ? y : height(list, c, at)))
                        list.sort { $0.x < $1.x }
                        dragging = list.firstIndex { $0.x == at }
                    }
                    origin = dragging.map { list[$0] }
                }
                guard let index = dragging, list.indices.contains(index) else { return }
                // The ends stay at the ends (a hue curve has none: it goes round); the others stay between their neighbours.
                let round = c.kind?.periodic == true
                let isEnd = !round && (index == 0 || index == list.count - 1)
                let low = index == 0 ? 0 : list[index - 1].x + 0.01, high = index == list.count - 1 ? (round ? 0.999 : 1) : list[index + 1].x - 0.01
                if c.kind != nil, let origin {
                    let moved = CGPoint(x: origin.x + value.translation.width / size.width, y: origin.y - value.translation.height / size.height)
                    list[index] = CurvePoint(x: isEnd ? origin.x : min(max(moved.x, low), high), y: min(max(moved.y, 0), 1))
                } else {
                    list[index] = CurvePoint(x: isEnd ? list[index].x : min(max(x, low), high), y: y)
                }
                set(list, c)
            }
            .onEnded { _ in
                dragging = nil; origin = nil
                // (Colour curves all flat again: none, as before they were touched.)
                if let hue = curves.hue, hue.isDefault { var new = curves; new.hue = nil; change(new) }
            }
    }

    private func remove(near location: CGPoint, _ size: CGSize, _ c: Channel) {
        var list = points
        let round = c.kind?.periodic == true
        guard let index = list.indices.min(by: { distance(list[$0], location, size) < distance(list[$1], location, size) }),
              distance(list[index], location, size) < 12, round || (index != 0 && index != list.count - 1) else { return }
        list.remove(at: index)
        set(list, c)
    }

    private func set(_ list: [CurvePoint], _ c: Channel) {
        var new = curves
        if let kind = c.kind {
            var hue = new.hue ?? HueCurves()
            hue[keyPath: kind.path] = list
            new.hue = hue.isDefault ? nil : hue
        } else {
            new[keyPath: c.path] = list
        }
        change(new)
    }

    private func distance(_ p: CurvePoint, _ location: CGPoint, _ size: CGSize) -> Double {
        hypot(p.x * size.width - location.x, (1 - p.y) * size.height - location.y)
    }
}

/// What a colour curve's axes mean, as colour: the hues across (OkLCh, as the engine's), fading down to grey (Saturation)
/// or dark (Luminance); black to white (Lum vs Sat) or grey to red (Sat vs Sat), colour rising up the curve.
struct CurveBackdrop: View {
    let kind: HueCurves.Kind

    var body: some View {
        let hues = LinearGradient(colors: stride(from: 0.0, through: 360, by: 20).map { PhotoMaskPanel.swatch($0) }, startPoint: .leading, endPoint: .trailing)
        ZStack {
            switch kind {
            case .hueHue: hues
            case .hueSat: hues; LinearGradient(colors: [.clear, Color(white: 0.45)], startPoint: .top, endPoint: .bottom)
            case .hueLum: hues; LinearGradient(colors: [.white.opacity(0.35), .clear, .black], startPoint: .top, endPoint: .bottom)
            case .lumSat:
                LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [PhotoMaskPanel.swatch(40).opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
            case .satSat: LinearGradient(colors: [Color(white: 0.5), PhotoMaskPanel.swatch(29)], startPoint: .leading, endPoint: .trailing)
            }
        }
    }
}

/// Process 5's Colour Warper: the hue–saturation disc (OkLCh hue round, C/L out to the rim at `PhotoEngine.satAxis`) and its
/// grid of dots, each drawn where its colour now goes. Drag a dot to move that colour (round: its hue; in and out: its
/// saturation); double-click it to put it back.
struct ColourWarper: View {
    let warp: ColourWarp
    let change: (ColourWarp) -> Void
    @State private var dragging: Int?
    /// The dot's place where the drag began (it moves by the drag, so a click doesn't make it jump).
    @State private var origin: CGPoint?

    /// The hues round as the dots read them (hue counter-clockwise from the right), greying to the centre.
    static var disc: some View {
        ZStack {
            // (An angular gradient runs clockwise on screen.)
            AngularGradient(colors: stride(from: 0.0, through: 360, by: 15).map { PhotoMaskPanel.swatch(360 - $0) }, center: .center)
            EllipticalGradient(colors: [Color(white: 0.5), Color(white: 0.5).opacity(0)], center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
        }
    }

    private func place(_ k: Int, _ r: Double, _ c: CGPoint) -> CGPoint {
        let i = k % ColourWarp.hues, j = k / ColourWarp.hues
        let h = (ColourWarp.hue(i) + warp.turn[k]) * .pi / 180, d = ColourWarp.ring(j) * warp.scale[k] / PhotoEngine.satAxis * r
        return CGPoint(x: c.x + d * cos(h), y: c.y - d * sin(h))
    }

    var body: some View {
        GeometryReader { geo in
            let r = min(geo.size.width, geo.size.height) / 2 - 6, c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let dots = (0..<warp.turn.count).map { place($0, r, c) }
            ZStack {
                Self.disc.opacity(0.6).clipShape(Circle()).frame(width: 2 * r, height: 2 * r).position(c)
                Circle().strokeBorder(.black.opacity(0.3), lineWidth: 1).frame(width: 2 * r, height: 2 * r).position(c)
                // The grid as it's bent: each ring round, each hue's spoke out from grey.
                Path { path in
                    for j in 0..<ColourWarp.rings {
                        path.addLines((0..<ColourWarp.hues).map { dots[ColourWarp.index($0, j)] }); path.closeSubpath()
                    }
                    for i in 0..<ColourWarp.hues { path.addLines([c] + (0..<ColourWarp.rings).map { dots[ColourWarp.index(i, $0)] }) }
                }
                .stroke(.white.opacity(0.4), lineWidth: 1)
                ForEach(dots.indices, id: \.self) { k in
                    let moved = warp.turn[k] != 0 || warp.scale[k] != 1
                    Circle()
                        .fill(dragging == k ? Color.accentColor : moved ? .white : .white.opacity(0.55))
                        .frame(width: 7, height: 7)
                        .shadow(color: .black.opacity(0.5), radius: 1)
                        .position(dots[k])
                }
            }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragging == nil {
                        guard let near = dots.indices.min(by: { hypot(dots[$0].x - value.startLocation.x, dots[$0].y - value.startLocation.y) < hypot(dots[$1].x - value.startLocation.x, dots[$1].y - value.startLocation.y) }),
                              hypot(dots[near].x - value.startLocation.x, dots[near].y - value.startLocation.y) < 10 else { return }
                        dragging = near; origin = dots[near]
                    }
                    // (A click alone, or the first of a double-click, changes nothing.)
                    guard let k = dragging, let origin, value.translation != .zero else { return }
                    let dx = origin.x + value.translation.width - c.x, dy = c.y - (origin.y + value.translation.height)
                    var turn = atan2(dy, dx) * 180 / .pi - ColourWarp.hue(k % ColourWarp.hues)
                    turn -= 360 * (turn / 360).rounded()
                    var new = warp
                    new.turn[k] = turn
                    new.scale[k] = min(hypot(dx, dy), r) / r * PhotoEngine.satAxis / ColourWarp.ring(k / ColourWarp.hues)
                    change(new)
                }
                .onEnded { _ in dragging = nil; origin = nil })
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in
                guard let k = dots.indices.first(where: { hypot(dots[$0].x - tap.location.x, dots[$0].y - tap.location.y) < 10 }) else { return }
                var new = warp; new.turn[k] = 0; new.scale[k] = 1; change(new)
            })
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(Text("Colour Warper"))
    }
}

// MARK: - Colour wheels

/// Drag a wheel's dot towards a colour to push its part of the picture that way; the slider under it is the brightness.
/// Process 5: two pages, chosen per photo: Lightroom's Shadows, Midtones, Highlights and Global (with Blending and Balance
/// once one is pushed), and DaVinci Resolve's Lift, Gamma, Gain and Offset. Before, the four wheels only.
struct ColorWheelsEditor: View {
    let wheels: ColorWheels
    var path: String?
    var process = PhotoAdjustments.currentProcess
    let change: (ColorWheels) -> Void
    @State private var editing = PhotoEditing.shared

    /// The page shown: the one last chosen for this photo, else Primaries when only they are pushed.
    private var primariesShown: Bool {
        process >= 5 && (path.flatMap { editing.wheelsPrimaries[$0] } ?? (wheels.tonesDefault && !wheels.primaries.isDefault))
    }

    var body: some View {
        let primaries = primariesShown
        VStack(spacing: 8) {
            if process >= 5 {
                Picker("Colour Wheels", selection: Binding(get: { primaries }, set: { new in if let path { editing.wheelsPrimaries[path] = new } })) {
                    Image(systemName: "circle.lefthalf.filled").tag(false).help("Colour Grading")
                    Image(systemName: "dial.medium").tag(true).help("Lift, Gamma, Gain")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 12) {
                if primaries {
                    wheel("Lift", \.primaries.lift)
                    wheel("Gamma", \.primaries.gamma)
                    wheel("Gain", \.primaries.gain)
                    wheel("Offset", \.primaries.offset)
                } else {
                    wheel("Shadows", \.lift)
                    wheel("Midtones", \.gamma)
                    wheel("Highlights", \.gain)
                    wheel("Offset", \.offset)
                }
            }
            .padding(.horizontal, 8)
            if process >= 5, !primaries, !wheels.tonesDefault {
                VStack(spacing: 0) {
                    AdjustSlider(title: "Blending", value: wheels.blending, range: 0...100, neutral: 50, format: "%.0f") { v in var new = wheels; new.blending = v; change(new) }
                    AdjustSlider(title: "Balance", value: wheels.balance, range: -100...100) { v in var new = wheels; new.balance = v; change(new) }
                }
            }
        }
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
                // The same header as the Adjust folds: chevron in the gutter, the name Title Case.
                HStack(spacing: 0) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .foregroundStyle(.tertiary)
                        .frame(width: Design.Sidebar.rowPadding)
                    Text(title).font(Design.Sidebar.header).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.trailing, Design.Sidebar.rowPadding)
                .frame(height: Design.Sidebar.foldHeight)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if isOpen { content }
        }
    }
}

// MARK: - Colour mixer

/// Hue, saturation and luminance for eight bands of colour. Process 5 (`points`): and colours picked on the photo (the
/// eyedropper), each with its own Hue, Saturation, Luminance and Range; a chip chosen shows its sliders instead of the band's.
struct ColorMixerEditor: View {
    let mixer: ColorMixer
    var points = false
    let change: (ColorMixer) -> Void
    @State private var editing = PhotoEditing.shared

    var body: some View {
        let band = ColorMixer.Band(rawValue: editing.mixerBand) ?? .red
        let list = points ? mixer.points ?? [] : []
        let chosen = editing.mixerPoint.flatMap { $0 < list.count ? $0 : nil }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                ForEach(ColorMixer.Band.allCases) { item in
                    let edited = mixer.hue[item.rawValue] != 0 || mixer.saturation[item.rawValue] != 0 || mixer.luminance[item.rawValue] != 0
                    let on = item == band && chosen == nil
                    Button { editing.mixerBand = item.rawValue; editing.mixerPoint = nil } label: {
                        VStack(spacing: 3) {
                            Circle().fill(Self.colour(item)).frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(.white, lineWidth: on ? 2 : 0))
                                .shadow(color: .black.opacity(0.3), radius: 1)
                            Circle().fill(edited ? Color.accentColor : .clear).frame(width: 4, height: 4)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(item.title)
                    .accessibilityLabel(Text(item.title))
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                Toggle(isOn: Binding(get: { editing.mixerTargeting }, set: { editing.mixerTargeting = $0; if $0 { editing.pointPicking = false } })) {
                    Image(systemName: "scope")
                }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Drag on the photo: up and down changes the colour under the pointer (saturation; with ⌥ luminance, with ⇧ hue)")
                    .accessibilityLabel(Text("Change a colour by dragging on the photo"))
            }
            .padding(.horizontal, 8)
            if points { pointRow(list, chosen) }
            if let chosen {
                let point = list[chosen]
                AdjustSlider(title: "Hue", value: point.hueShift, range: -100...100, track: .hues) { v in setPoint(chosen) { $0.hueShift = v } }
                AdjustSlider(title: "Saturation", value: point.saturation, range: -100...100, track: .colour(Self.colour(point))) { v in setPoint(chosen) { $0.saturation = v } }
                AdjustSlider(title: "Luminance", value: point.luminance, range: -100...100) { v in setPoint(chosen) { $0.luminance = v } }
                AdjustSlider(title: "Range", value: point.range, range: 0...100, neutral: ColourPoint.defaultRange, format: "%.0f") { v in setPoint(chosen) { $0.range = v } }
            } else {
                AdjustSlider(title: "Hue", value: mixer.hue[band.rawValue], range: -100...100, track: .hues) { set(\.hue, band, $0) }
                AdjustSlider(title: "Saturation", value: mixer.saturation[band.rawValue], range: -100...100, track: .colour(Self.colour(band))) { set(\.saturation, band, $0) }
                AdjustSlider(title: "Luminance", value: mixer.luminance[band.rawValue], range: -100...100) { set(\.luminance, band, $0) }
            }
        }
    }

    /// The eyedropper, the picked colours as chips, and (one chosen) its area in red while held, and taking it away.
    private func pointRow(_ list: [ColourPoint], _ chosen: Int?) -> some View {
        HStack(spacing: 6) {
            Toggle(isOn: Binding(get: { editing.pointPicking }, set: { editing.pointPicking = $0; if $0 { editing.mixerTargeting = false } })) {
                Image(systemName: "eyedropper")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .disabled(list.count >= ColourPoint.limit)
            .help("Pick a colour on the photo")
            .accessibilityLabel(Text("Pick a colour on the photo"))
            ForEach(list.indices, id: \.self) { i in
                Button { editing.mixerPoint = i } label: {
                    Circle().fill(Self.colour(list[i])).frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(.white, lineWidth: chosen == i ? 2 : 0))
                        .shadow(color: .black.opacity(0.3), radius: 1)
                        .overlay(alignment: .bottom) {
                            Circle().fill(Color.accentColor).frame(width: 3, height: 3).offset(y: 5).opacity(list[i].changes ? 1 : 0)
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Picked colour"))
                .accessibilityAddTraits(chosen == i ? .isSelected : [])
            }
            Spacer()
            if let chosen {
                Image(systemName: editing.pointOverlay ? "eye.fill" : "eye")
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(.rect)
                    .onLongPressGesture(minimumDuration: 0, perform: {}, onPressingChanged: { editing.pointOverlay = $0 })
                    .help("Hold to see what this colour reaches")
                    .accessibilityLabel(Text("Hold to see what this colour reaches"))
                Button {
                    var new = mixer
                    new.points?.remove(at: chosen)
                    if new.points?.isEmpty == true { new.points = nil }
                    editing.mixerPoint = nil; editing.pointOverlay = false
                    change(new)
                } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove")
                .accessibilityLabel(Text("Remove"))
            }
        }
        .padding(.horizontal, 8)
    }

    private func set(_ aspect: WritableKeyPath<ColorMixer, [Double]>, _ band: ColorMixer.Band, _ value: Double) {
        var new = mixer
        new[keyPath: aspect][band.rawValue] = value
        change(new)
    }

    private func setPoint(_ index: Int, _ body: (inout ColourPoint) -> Void) {
        var new = mixer
        guard var list = new.points, list.indices.contains(index) else { return }
        body(&list[index])
        new.points = list
        change(new)
    }

    /// The band's colour (its OkLCh hue, as a swatch).
    static func colour(_ band: ColorMixer.Band) -> Color { PhotoMaskPanel.swatch(band.hue) }
    /// A picked colour as it was on the photo.
    static func colour(_ point: ColourPoint) -> Color {
        let L = min(max(point.lum, 0.2), 0.95), C = point.sat * L, r = point.hue * .pi / 180
        let (lr, lg, lb) = OkLab.to(L, C * cos(r), C * sin(r))
        func e(_ v: Double) -> Double { DevelopLUT.encode(min(max(v, 0), 1)) }
        return Color(red: e(lr), green: e(lg), blue: e(lb))
    }
}

/// The eyedropper on the photo (Colour Mixer, process 5): a click picks the colour there as it shows without the colour
/// points and curves (what they read), as a new point, chosen.
struct PointPicker: View {
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
        let path = self.path
        var plain = record
        plain.adjust.mixer.points = nil
        plain.adjust.curves.hue = nil; plain.adjust.curves.warp = nil
        let record = plain
        Task {
            guard let colour = await Task.detached(priority: .userInitiated, operation: { PhotoRender.sample(path, record: record, at: at) }).value
            else { return }
            let point = ColourPoint.picked(colour)
            var count = 0
            catalog.update([path]) {
                var list = $0.adjust.mixer.points ?? []
                if list.count < ColourPoint.limit { list.append(point) }
                count = list.count
                $0.adjust.mixer.points = list
                $0.edited = .now
            }
            editing.mixerPoint = count - 1
            editing.pointPicking = false
        }
    }
}

extension ColourPoint {
    /// A point at this colour (linear sRGB, as shown): its OkLCh hue, C/L and L, as the engine reads them.
    static func picked(_ colour: SIMD3<Double>) -> ColourPoint {
        let c = colour.clamped(lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: 1))
        let (L, a, b) = OkLab.from(c.x, c.y, c.z)
        var hue = atan2(b, a) * 180 / .pi
        if hue < 0 { hue += 360 }
        return ColourPoint(hue: hue, sat: (a * a + b * b).squareRoot() / max(L, 0.03), lum: L)
    }
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
        let path = self.path
        // (Process 5's mixer works on the picture as shown: the colour it reads is the shown one before the mixer.)
        let mixer = self.record.adjust.mixer
        var plain = self.record
        if plain.adjust.process >= 5 { plain.adjust.mixer = ColorMixer(); plain.adjust.curves.hue = nil; plain.adjust.curves.warp = nil }
        let record = plain
        Task {
            guard let colour = await Task.detached(priority: .userInitiated, operation: { PhotoRender.sample(path, record: record, at: at) }).value
            else { return }
            let seen = PhotoRender.describe(colour)
            var weights = record.adjust.process >= 5 ? ColorMixer.weights5(seen.hue) : ColorMixer.weights(seen.hue)
            let top = max(weights.max() ?? 1, 0.0001)
            weights = weights.map { $0 / top }
            start = (weights, mixer, aspect)
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
