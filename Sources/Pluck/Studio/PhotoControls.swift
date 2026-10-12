import SwiftUI

/// What the Photo page is doing right now, shared between the inspector and the picture.
@MainActor
@Observable
final class PhotoEditing {
    static let shared = PhotoEditing()
    /// The crop frame is shown on the picture.
    var cropping = false
    /// The photo is shown as shot while \ is held.
    var asShot = false
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
    func denoise(_ paths: [String], strength: Int) {
        let waiting = paths.filter { !denoising.contains($0) }
        guard !waiting.isEmpty else { return }
        denoising.formUnion(waiting)
        denoiseProblem = nil
        Task {
            for path in waiting {
                do {
                    try await PhotoRender.denoise(path, strength: strength, worker: 5)
                    PhotoCatalog.shared.update([path]) { $0.denoise = strength; $0.edited = .now }
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
    let change: (CropRect) -> Void
    @State private var start: CropRect?

    var body: some View {
        let box = CGRect(x: frame.minX + rect.x * frame.width, y: frame.minY + rect.y * frame.height,
                         width: rect.width * frame.width, height: rect.height * frame.height)
        ZStack {
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
                if let ratio { r = keep(r, ratio: ratio, left: left, top: top, sizingWidth: left || right) }
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
