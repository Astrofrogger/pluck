import CoreImage
import SwiftUI

/// A Liquify stroke: Push moves what's under the brush along the drag; Bloat swells it, Pinch draws it in, the longer the brush
/// stays. Points are shares of the photo as decoded (uncropped, unstraightened), from the top left.
struct LiquifyStroke: Codable, Hashable {
    enum Tool: String, Codable, CaseIterable { case push, bloat, pinch }
    var tool = Tool.push
    var points: [CGPoint]
    /// Share of the photo's long side.
    var radius = 0.06
    /// 0…1.
    var strength = 0.5
}

/// Liquify, on the decoded photo (linear light, before the develop), see PhotoRender.adjusted: every stroke adds to one
/// displacement field (where each place takes its light from), worked out on a small grid and read smoothly, so a preview, a
/// thumbnail and the export move the same.
enum PhotoLiquify {
    /// The field's long side, in grid points.
    static let grid = 256

    static func apply(_ strokes: [LiquifyStroke]?, to image: CIImage) -> CIImage {
        guard let strokes, !strokes.isEmpty, let kernel else { return image }
        let e = image.extent
        guard !e.isInfinite, e.width > 1, e.height > 1 else { return image }
        let (field, w, h) = displacement(strokes, aspect: e.width / e.height)
        // The field as a picture (red, green: where to take the light from, as a share of the long side), stretched over the photo.
        let data = field.withUnsafeBufferPointer { Data(buffer: $0) }
        let map = CIImage(bitmapData: data, bytesPerRow: w * 16, size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: nil)
            .transformed(by: CGAffineTransform(scaleX: e.width / CGFloat(w), y: e.height / CGFloat(h)).concatenating(CGAffineTransform(translationX: e.minX, y: e.minY)))
        let long = Float(max(e.width, e.height))
        // (How far any place moves at most: the region of interest grows by that much.)
        var reach: Float = 0
        for i in stride(from: 0, to: field.count, by: 4) { reach = max(reach, abs(field[i]), abs(field[i + 1])) }
        let margin = CGFloat(reach * long) + 2
        return kernel.apply(extent: e, roiCallback: { index, r in index == 0 ? r.insetBy(dx: -margin, dy: -margin) : r },
                            arguments: [image.clampedToExtent(), map.clampedToExtent(), long])?.cropped(to: e) ?? image
    }

    /// A kept decode's key with Liquify on it (its local-tone layers are then its own). None: unchanged.
    static func key(_ key: String?, _ strokes: [LiquifyStroke]?) -> String? {
        guard let strokes, !strokes.isEmpty else { return key }
        return key.map { $0 + "|liquify \(strokes.hashValue)" }
    }

    /// The displacement field: RGBA floats (dx, dy as shares of the long side, in Core Image's up-is-positive y), rows from the
    /// top as CIImage(bitmapData:) reads them. Each stroke adds to it in turn, a smooth falloff (1 − d²/r²)² under the brush.
    static func displacement(_ strokes: [LiquifyStroke], aspect: Double) -> (field: [Float], width: Int, height: Int) {
        let w = aspect >= 1 ? grid : max(Int(Double(grid) * aspect), 2), h = aspect >= 1 ? max(Int(Double(grid) / aspect), 2) : grid
        let longSide = Double(max(w, h))
        var dx = [Double](repeating: 0, count: w * h), dy = dx
        for stroke in strokes {
            let r = max(stroke.radius * longSide, 1), s = min(max(stroke.strength, 0), 1)
            // Points in grid units, y up.
            let pts = stroke.points.map { CGPoint(x: $0.x * Double(w), y: (1 - $0.y) * Double(h)) }
            func brush(_ c: CGPoint, _ body: (Int, Double, Double, Double) -> Void) {
                let x0 = max(Int(c.x - r), 0), x1 = min(Int(c.x + r) + 1, w - 1), y0 = max(Int(c.y - r), 0), y1 = min(Int(c.y + r) + 1, h - 1)
                guard x0 <= x1, y0 <= y1 else { return }
                for y in y0...y1 { for x in x0...x1 {
                    let ox = Double(x) + 0.5 - c.x, oy = Double(y) + 0.5 - c.y, d2 = (ox * ox + oy * oy) / (r * r)
                    guard d2 < 1 else { continue }
                    let f = (1 - d2) * (1 - d2)
                    body(y * w + x, f, ox, oy)
                } }
            }
            switch stroke.tool {
            case .push:
                // Each step of the drag: what was behind moves forward (each place takes its light from back along the drag).
                // Each step builds on the moves before it (where a place now takes its light from, followed back through the
                // step), so what's pushed travels with the drag instead of tearing.
                func read(_ v: [Double], _ x: Double, _ y: Double) -> Double {
                    let fx = min(max(x - 0.5, 0), Double(w - 1)), fy = min(max(y - 0.5, 0), Double(h - 1))
                    let x0 = Int(fx), y0 = Int(fy), x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1), tx = fx - Double(x0), ty = fy - Double(y0)
                    return (v[y0 * w + x0] * (1 - tx) + v[y0 * w + x1] * tx) * (1 - ty) + (v[y1 * w + x0] * (1 - tx) + v[y1 * w + x1] * tx) * ty
                }
                for (a, b) in zip(pts, pts.dropFirst()) {
                    let mx = (b.x - a.x), my = (b.y - a.y)
                    let oldX = dx, oldY = dy
                    brush(a) { i, f, _, _ in
                        let x = Double(i % w) + 0.5, y = Double(i / w) + 0.5
                        let sx = -mx * f * s, sy = -my * f * s
                        dx[i] = sx / longSide + read(oldX, x + sx, y + sy)
                        dy[i] = sy / longSide + read(oldY, x + sx, y + sy)
                    }
                }
            case .bloat, .pinch:
                // Per point held: places take their light from nearer the centre (swell) or farther out (pinch).
                let sign = stroke.tool == .bloat ? -1.0 : 1.0
                for c in pts {
                    brush(c) { i, f, ox, oy in
                        dx[i] += sign * ox / longSide * f * s * 0.04; dy[i] += sign * oy / longSide * f * s * 0.04
                    }
                }
            }
        }
        var field = [Float](repeating: 0, count: w * h * 4)
        // (Alpha 1: with 0, Core Image takes the numbers as nothing once it scales the field.)
        // (Rows from the top, as CIImage(bitmapData:) reads them: the grid above counts up from the bottom.)
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x, o = ((h - 1 - y) * w + x) * 4
            field[o] = Float(dx[i]); field[o + 1] = Float(dy[i]); field[o + 3] = 1
        } }
        return (field, w, h)
    }

    // (`long` is a reserved word in Core Image's kernel language: the kernel silently didn't compile with it.)
    private static let kernel = CIKernel(source: """
        kernel vec4 liquify(sampler image, sampler field, float size) {
            vec2 p = destCoord();
            vec2 d = sample(field, samplerTransform(field, p)).rg * size;
            return sample(image, samplerTransform(image, p + d));
        }
        """)

    // MARK: - Edits

    @MainActor static func change(_ path: String, _ body: @escaping (inout [LiquifyStroke]) -> Void) {
        PhotoCatalog.shared.update([path]) { record in
            var strokes = record.adjust.liquify ?? []
            body(&strokes)
            record.adjust.liquify = strokes
            record.edited = .now
        }
    }
}

// MARK: - In the Heal tab

/// Liquify's controls: the tool, its size and strength, undo the last stroke, clear.
struct PhotoLiquifyPanel: View {
    let path: String
    let record: PhotoRecord
    @State private var editing = PhotoEditing.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StudioSegmented(options: [(LiquifyStroke.Tool.push, LocalizedStringKey("Push")), (LiquifyStroke.Tool.bloat, LocalizedStringKey("Bloat")),
                                      (LiquifyStroke.Tool.pinch, LocalizedStringKey("Pinch"))], selection: $editing.liquifyTool)
                .padding(.horizontal, 8)
            VStack(spacing: 0) {
                AdjustSlider(title: "Size", value: editing.liquifySize * 100, range: 1...30, neutral: 6, format: "%.0f") { editing.liquifySize = $0 / 100 }
                AdjustSlider(title: "Strength", value: editing.liquifyStrength * 100, range: 1...100, neutral: 50, format: "%.0f") { editing.liquifyStrength = $0 / 100 }
            }
            Text(editing.liquifyTool == .push ? "Drag on the photo to push it along." : "Hold the mouse down on the photo; drag to move the brush.")
                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).padding(.horizontal, 8)
            if let strokes = record.adjust.liquify, !strokes.isEmpty {
                HStack(spacing: 12) {
                    Button("Undo Stroke") {
                        PhotoCatalog.shared.endStep(); PhotoLiquify.change(path) { _ = $0.popLast() }; PhotoCatalog.shared.endStep()
                    }
                    Button("Clear All") {
                        PhotoCatalog.shared.endStep(); PhotoLiquify.change(path) { $0.removeAll() }; PhotoCatalog.shared.endStep()
                    }
                    .foregroundStyle(Design.Brand.pink)
                }
                .buttonStyle(.plain)
                .font(Design.Studio.body)
                .padding(.horizontal, 8)
            }
        }
    }
}

/// On the photo while Liquify is chosen: the brush under the pointer; a drag (or a hold, for Bloat and Pinch) is one stroke,
/// added when the mouse lets go. `frame` is where the whole photo (uncropped, unstraightened) is in the view.
struct PhotoLiquifyHandles: View {
    let path: String
    let frame: CGRect
    @State private var editing = PhotoEditing.shared
    @State private var hover: CGPoint?
    @State private var points: [CGPoint] = []
    @State private var holding: Timer?

    private var long: Double { max(frame.width, frame.height) }

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(.rect)
                .onContinuousHover { phase in if case .active(let at) = phase { hover = at } else { hover = nil } }
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        hover = value.location
                        let p = share(value.location)
                        if points.isEmpty {
                            points = [p]
                            // Bloat and Pinch grow while held still: the place is added again every tenth of a second.
                            if editing.liquifyTool != .push {
                                holding = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                                    Task { @MainActor in if let last = points.last { points.append(last) } }
                                }
                            }
                        } else if let last = points.last, hypot((p.x - last.x) * frame.width, (p.y - last.y) * frame.height) > 2 {
                            points.append(p)
                        }
                    }
                    .onEnded { _ in
                        holding?.invalidate(); holding = nil
                        let stroke = LiquifyStroke(tool: editing.liquifyTool, points: points, radius: editing.liquifySize, strength: editing.liquifyStrength)
                        points = []
                        guard stroke.points.count > 1 || stroke.tool != .push else { return }
                        PhotoCatalog.shared.endStep()
                        PhotoLiquify.change(path) { $0.append(stroke) }
                        PhotoCatalog.shared.endStep()
                    })
            if let hover {
                Circle().stroke(.white.opacity(0.8), lineWidth: 1).shadow(color: .black.opacity(0.5), radius: 1)
                    .frame(width: editing.liquifySize * long * 2, height: editing.liquifySize * long * 2)
                    .position(hover).allowsHitTesting(false)
            }
        }
    }

    private func share(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - frame.minX) / max(frame.width, 1), y: (point.y - frame.minY) / max(frame.height, 1))
    }
}
