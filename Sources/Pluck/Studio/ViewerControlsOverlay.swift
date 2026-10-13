import SwiftUI

/// The on-screen controls over the viewer, as in Resolve: in Transform, drag the picture to move
/// it, a corner to size it, the handle above it to turn it; in Dynamic Zoom, drag and size the
/// start (green) and end (red) frames. Works on the clip under the playhead.
struct ViewerControlsOverlay: View {
    /// The clip's look, the picture's size, and how to change the look.
    let look: ClipLook
    let pictureSize: CGSize?
    let frameSize: CGSize
    let change: (Bool, @escaping (inout ClipLook) -> Void) -> Void
    @AppStorage("viewerControls") private var mode = ViewerControls.transform
    @State private var start: ClipLook?

    var body: some View {
        GeometryReader { geo in
            let view = geo.size
            switch mode {
            case .transform: transform(view)
            case .dynamicZoom: if look.hasDynamicZoom { dynamicZoom(view) }
            case .off: EmptyView()
            }
        }
    }

    // MARK: Transform

    private func transform(_ view: CGSize) -> some View {
        let share = ClipLook.fittedShare(picture: pictureSize ?? frameSize, frame: frameSize, scaling: look.scaling)
        let w = share.width * view.width * look.zoom * (1 - look.cropLeft - look.cropRight)
        let h = share.height * view.height * look.zoom * (1 - look.cropTop - look.cropBottom)
        // The crop's own middle, off the picture's middle.
        let cropShift = CGPoint(x: (look.cropLeft - look.cropRight) / 2 * share.width * view.width * look.zoom,
                                y: (look.cropTop - look.cropBottom) / 2 * share.height * view.height * look.zoom)
        let center = CGPoint(x: view.width * (0.5 + look.x) + cropShift.x, y: view.height * (0.5 - look.y) + cropShift.y)
        return ZStack {
            Rectangle()
                .strokeBorder(.white.opacity(0.9), lineWidth: 1)
                .background(Color.white.opacity(0.001))
                .frame(width: max(w, 8), height: max(h, 8))
                .overlay(alignment: .top) {
                    // The handle to turn it.
                    VStack(spacing: 0) {
                        Circle().fill(.white).frame(width: 10, height: 10)
                        Rectangle().fill(.white.opacity(0.8)).frame(width: 1, height: 18)
                    }
                    .offset(y: -28)
                    .gesture(DragGesture(coordinateSpace: .named("viewer")).onChanged { value in
                        let a = atan2(value.location.y - center.y, value.location.x - center.x) * 180 / .pi + 90
                        change(false) { $0.rotation = -((a + 180).truncatingRemainder(dividingBy: 360) - 180) }
                    }.onEnded { _ in change(true) { _ in } })
                }
                .overlay {
                    // Corners size it.
                    ForEach(0..<4, id: \.self) { corner in
                        Rectangle().fill(.white).frame(width: 9, height: 9)
                            .position(x: corner % 2 == 0 ? 0 : max(w, 8), y: corner < 2 ? 0 : max(h, 8))
                            .gesture(DragGesture(coordinateSpace: .named("viewer")).onChanged { value in
                                let s = start ?? look
                                if start == nil { start = look }
                                let d0 = hypot(value.startLocation.x - center.x, value.startLocation.y - center.y)
                                let d1 = hypot(value.location.x - center.x, value.location.y - center.y)
                                guard d0 > 4 else { return }
                                change(false) { $0.zoom = min(max(s.zoom * d1 / d0, 0.1), 8) }
                            }.onEnded { _ in start = nil; change(true) { _ in } })
                    }
                }
                .rotationEffect(.degrees(-look.rotation))
                .position(center)
                .gesture(DragGesture(coordinateSpace: .named("viewer")).onChanged { value in
                    let s = start ?? look
                    if start == nil { start = look }
                    change(false) {
                        $0.x = s.x + value.translation.width / view.width
                        $0.y = s.y - value.translation.height / view.height
                    }
                }.onEnded { _ in start = nil; change(true) { _ in } })
        }
        .coordinateSpace(name: "viewer")
    }

    // MARK: Dynamic zoom

    private func dynamicZoom(_ view: CGSize) -> some View {
        ZStack {
            zoomFrame(\.zoomFrom, colour: .green, label: "Start", view: view)
            zoomFrame(\.zoomTo, colour: .red, label: "End", view: view)
        }
        .coordinateSpace(name: "viewer")
    }

    private func zoomFrame(_ path: WritableKeyPath<ClipLook, ClipLook.ZoomFrame?>, colour: Color, label: LocalizedStringKey, view: CGSize) -> some View {
        let f = (look[keyPath: path] ?? .init()).fitted()
        let w = f.size * view.width, h = f.size * view.height
        return Rectangle()
            .strokeBorder(colour, lineWidth: 2)
            .background(colour.opacity(0.06))
            .frame(width: w, height: h)
            .overlay(alignment: .topLeading) {
                Text(label).font(.caption2.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2).background(colour, in: .rect(cornerRadius: 3)).padding(4)
            }
            .overlay(alignment: .bottomTrailing) {
                // The corner sizes it (the frame keeps the picture's shape).
                Rectangle().fill(colour).frame(width: 10, height: 10)
                    .gesture(DragGesture(coordinateSpace: .named("viewer")).onChanged { value in
                        let s = start ?? look
                        if start == nil { start = look }
                        let from = (s[keyPath: path] ?? .init()).fitted()
                        let centre = CGPoint(x: from.x * view.width, y: from.y * view.height)
                        let half = max(abs(value.location.x - centre.x) / view.width, abs(value.location.y - centre.y) / view.height)
                        change(false) { var g = from; g.size = half * 2; $0[keyPath: path] = g.fitted() }
                    }.onEnded { _ in start = nil; change(true) { _ in } })
            }
            .position(x: f.x * view.width, y: f.y * view.height)
            .gesture(DragGesture(coordinateSpace: .named("viewer")).onChanged { value in
                let s = start ?? look
                if start == nil { start = look }
                let from = (s[keyPath: path] ?? .init()).fitted()
                change(false) {
                    var g = from
                    g.x += value.translation.width / view.width
                    g.y += value.translation.height / view.height
                    $0[keyPath: path] = g.fitted()
                }
            }.onEnded { _ in start = nil; change(true) { _ in } })
    }
}
