import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// A spot healed or cloned: the circle at `centre` gets the circle at `source` copied in (Heal also takes on the target's
/// own colour and light from around it). Places are shares of the photo as decoded (uncropped, unstraightened), from the
/// top left, so a preview, a thumbnail and the export put it in the same place.
struct PhotoSpot: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case heal, clone, remove, redEye, petEye }
    var id = UUID()
    var kind = Kind.heal
    var centre: CGPoint
    var source: CGPoint
    /// Share of the photo's long side.
    var radius = 0.02
    /// How soft the edge is (0 hard … 1 soft from the middle out) and how much shows (0…1).
    var feather = 0.5
    var opacity = 1.0
    /// Remove: the painted path (shares, as `centre`; each point a circle of `radius`), filled in by AI Remove. Nil: the
    /// circle at `centre` alone.
    var stroke: [CGPoint]?

    /// Remove's points (the circle alone when nothing was painted).
    var points: [CGPoint] { stroke ?? [centre] }
}

/// Spot heal and clone, in Core Image on the decoded photo (linear light, before the develop), see PhotoRender.adjusted.
enum PhotoHeal {
    /// The patch mixed in over a feathered circle: the moved copy, plus (Heal) the target's surroundings' low frequencies
    /// minus the copy's own (both a blur of the ring outside the circle, divided by the blurred ring: a membrane from the edge in).
    private static let kernel = CIColorKernel(source: """
        kernel vec4 spot(__sample base, __sample moved, __sample target, __sample from, __sample weight, vec2 centre,
                         float radius, float feather, float opacity, float heal) {
            float d = length(destCoord() - centre) / radius;
            float w = clamp((1.0 - d) / max(feather, 0.001), 0.0, 1.0) * opacity;
            vec3 mended = moved.rgb + heal * (target.rgb - from.rgb) / max(weight.r, 0.0001);
            return vec4(mix(base.rgb, mended, w), base.a);
        }
        """)

    /// The spots on a decoded photo, in order (a later one can copy from an earlier one). None: the same image, untouched.
    static func apply(_ spots: [PhotoSpot]?, to image: CIImage) -> CIImage {
        guard let spots, !spots.isEmpty, let kernel else { return image }
        let e = image.extent
        guard !e.isInfinite, e.width > 0, e.height > 0 else { return image }
        let long = max(e.width, e.height)
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: e.minX + p.x * e.width, y: e.maxY - p.y * e.height) }
        var result = image
        for spot in spots {
            if spot.kind == .remove { result = removed(spot, from: result, point: point, long: long); continue }
            if spot.kind == .redEye || spot.kind == .petEye {
                let r = max(spot.radius * long, 1), c = point(spot.centre)
                let area = CGRect(x: c.x - r - 2, y: c.y - r - 2, width: 2 * r + 4, height: 2 * r + 4).integral.intersection(e)
                if !area.isEmpty, let kernel = eyeKernel,
                   let fixed = kernel.apply(extent: area, arguments: [result, CIVector(cgPoint: c), r, spot.kind == .petEye ? 1.0 : 0.0, spot.opacity]) {
                    result = fixed.composited(over: result)
                }
                continue
            }
            let r = max(spot.radius * long, 0.5)
            let t = point(spot.centre), s = point(spot.source)
            let area = CGRect(x: t.x - r - 1, y: t.y - r - 1, width: 2 * r + 2, height: 2 * r + 2).integral.intersection(e)
            guard !area.isEmpty else { continue }
            let whole = result.clampedToExtent()
            let moved = whole.transformed(by: CGAffineTransform(translationX: t.x - s.x, y: t.y - s.y))
            var target = moved, from = moved, weight = CIImage(color: .white), heal = 0.0
            if spot.kind == .heal {
                let ring = CIFilter.radialGradient()
                ring.center = t
                ring.radius0 = Float(r)
                ring.radius1 = Float(r + 1)
                ring.color0 = CIColor(red: 0, green: 0, blue: 0)
                ring.color1 = CIColor(red: 1, green: 1, blue: 1)
                guard let outside = ring.outputImage else { continue }
                let sigma = r / 2
                func blurred(_ i: CIImage) -> CIImage {
                    i.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: outside]).applyingGaussianBlur(sigma: sigma)
                }
                target = blurred(whole)
                from = blurred(moved)
                weight = outside.applyingGaussianBlur(sigma: sigma)
                heal = 1
            }
            guard let patched = kernel.apply(extent: area, arguments: [result, moved, target, from, weight, CIVector(cgPoint: t), r,
                                                                       spot.feather, spot.opacity, heal]) else { continue }
            result = patched.composited(over: result)
        }
        return result.cropped(to: e)
    }

    /// Red eye and pet eye, in the circle (soft at its edge, by Opacity). Red eye: the red the flash put in the pupil taken
    /// down to the pupil's own dark (its red no brighter than its green and blue), so it stays a natural pupil. Pet eye: the
    /// glow (bright, any colour) made a dark pupil, with a small catch-light kept up and to the left so the eye stays alive.
    private static let eyeKernel = CIColorKernel(source: """
        kernel vec4 eyeFix(__sample c, vec2 centre, float radius, float pet, float opacity) {
            vec2 d = (destCoord() - centre) / radius;
            float w = (1.0 - smoothstep(0.75, 1.0, length(d))) * opacity;
            vec3 v = max(c.rgb, 0.0);
            float luma = dot(v, vec3(0.2126, 0.7152, 0.0722));
            vec3 fixedColour;
            if (pet < 0.5) {
                float other = max(v.g, v.b);
                float redness = smoothstep(0.0, 0.08, v.r - other * 1.3);
                vec3 pupil = vec3(other * 0.85, v.g * 0.85, v.b * 0.85);
                fixedColour = mix(v, pupil, redness);
            } else {
                float glow = smoothstep(0.05, 0.25, luma);
                fixedColour = mix(v, vec3(0.012, 0.011, 0.010), glow);
                float catchlight = 1.0 - smoothstep(0.08, 0.16, length(d - vec2(-0.3, 0.3)));
                fixedColour = mix(fixedColour, vec3(max(luma, 0.6)), catchlight * glow);
            }
            return vec4(mix(v, fixedColour, w), c.a);
        }
        """)

    /// A Remove spot: the painted area filled in by AI Remove (none without the model), blended in over a soft edge.
    private static func removed(_ spot: PhotoSpot, from image: CIImage, point: (CGPoint) -> CGPoint, long: CGFloat) -> CIImage {
        let e = image.extent, r = max(spot.radius * long, 1)
        let points = spot.points.map(point)
        // The painted area, a little wider for the model (so the thing's edge goes too).
        func paint(_ grow: CGFloat) -> CIImage {
            points.reduce(CIImage.empty()) { area, p in
                let disc = CIFilter.radialGradient()
                disc.center = p
                disc.radius0 = Float(r * grow)
                disc.radius1 = Float(r * grow + 1)
                disc.color0 = CIColor(red: 1, green: 1, blue: 1)
                disc.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
                return (disc.outputImage ?? .empty()).composited(over: area)
            }
        }
        let xs = points.map(\.x), ys = points.map(\.y)
        let box = CGRect(x: xs.min()! - r, y: ys.min()! - r, width: xs.max()! - xs.min()! + 2 * r, height: ys.max()! - ys.min()! + 2 * r)
        // The model sees a square round the area, with the area about a third of it (enough of the photo to go on).
        let side = min(max(max(box.width, box.height) * 2.6, 96), min(e.width, e.height))
        var square = CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
        square.origin.x = min(max(square.minX, e.minX), e.maxX - side)
        square.origin.y = min(max(square.minY, e.minY), e.maxY - side)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: square)
        guard let fill = PhotoRemove.fill(image, mask: paint(1.15).composited(over: black), square: square, context: PhotoEngine.context) else { return image }
        // Blended in over the painted area with a soft edge (Feather), at Opacity.
        let soft = paint(1.05).composited(over: black).applyingGaussianBlur(sigma: Double(r) * max(spot.feather, 0.05) * 0.3)
            .cropped(to: square)
            .applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: spot.opacity, y: 0, z: 0, w: 0),
                                                          "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0)])
        return fill.cropped(to: square).applyingFilter("CIBlendWithRedMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: soft])
            .cropped(to: e)
    }

    /// A kept decode's key with the spots on it (the local-tone layers worked out from it are then its own). None: unchanged.
    static func key(_ key: String?, _ spots: [PhotoSpot]?) -> String? {
        guard let spots, !spots.isEmpty else { return key }
        return key.map { $0 + "|spots \(spots.hashValue)" }
    }

    /// Where to copy a new spot from: on a small copy, places 1.5 to 3 radii around whose ring of surroundings best matches
    /// the target's (and that are plain inside), kept clear of the photo's edges. Shares from the top left, as `centre`.
    static func findSource(_ image: CIImage, centre: CGPoint, radius: Double) -> CGPoint {
        let e = image.extent
        let long = max(e.width, e.height)
        let fallback = CGPoint(x: min(max(centre.x + (centre.x < 0.5 ? 1 : -1) * 2.5 * radius * long / max(e.width, 1), 0), 1), y: centre.y)
        guard !e.isInfinite, long > 0 else { return fallback }
        let scale = min(1, 384 / long)
        let width = max(Int((e.width * scale).rounded()), 1), height = max(Int((e.height * scale).rounded()), 1)
        let rp = max(radius * long * scale, 1.5)
        let small = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY).concatenating(CGAffineTransform(scaleX: scale, y: scale)))
            .clampedToExtent().applyingGaussianBlur(sigma: max(rp / 4, 0.5))
        var pixels = [Float](repeating: 0, count: width * height * 4)
        // (Rows from the top, as CIImage(bitmapData:) reads them.)
        PhotoEngine.context.render(small, toBitmap: &pixels, rowBytes: width * 16, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                                   format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        func at(_ x: Double, _ y: Double) -> SIMD3<Float> {
            let i = (min(max(Int(y), 0), height - 1) * width + min(max(Int(x), 0), width - 1)) * 4
            // (Square roots: closer to how different two brightnesses look.)
            return SIMD3(pixels[i].squareRoot(), pixels[i + 1].squareRoot(), pixels[i + 2].squareRoot())
        }
        let angles = (0..<16).map { Double($0) / 16 * 2 * .pi }
        func ring(_ x: Double, _ y: Double) -> [SIMD3<Float>] { angles.map { at(x + cos($0) * rp * 1.25, y + sin($0) * rp * 1.25) } }
        let tx = centre.x * Double(width), ty = centre.y * Double(height)
        let wanted = ring(tx, ty)
        let reach = rp * 1.25 + 1
        var best: (cost: Float, x: Double, y: Double)?
        for step in [1.5, 2.0, 2.5, 3.0] {
            for k in 0..<24 {
                let a = Double(k) / 24 * 2 * .pi + step
                let x = tx + cos(a) * rp * step, y = ty + sin(a) * rp * step
                guard x - reach >= 0, y - reach >= 0, x + reach <= Double(width), y + reach <= Double(height) else { continue }
                let around = ring(x, y)
                var cost = zip(wanted, around).reduce(Float(0)) { sum, pair in let d = pair.0 - pair.1; return sum + (d * d).sum() } / 16
                // Plain inside: no other blemish or edge copied in.
                let inside = [at(x, y)] + angles.prefix(8).map { at(x + cos($0 * 2) * rp * 0.6, y + sin($0 * 2) * rp * 0.6) }
                let mean = inside.reduce(SIMD3<Float>(), +) / Float(inside.count)
                cost += inside.reduce(Float(0)) { $0 + (($1 - mean) * ($1 - mean)).sum() } / Float(inside.count) * 0.5
                // A little for distance: the nearest of equals.
                cost += Float(step) * 0.0001
                if best == nil || cost < best!.cost { best = (cost, x, y) }
            }
        }
        guard let best else { return fallback }
        return CGPoint(x: best.x / Double(width), y: best.y / Double(height))
    }

    // MARK: - Edits

    /// The shown photo's spots changed (one photo: spots belong to it).
    @MainActor static func change(_ path: String, _ body: @escaping (inout [PhotoSpot]) -> Void) {
        PhotoCatalog.shared.update([path]) { record in
            var spots = record.adjust.spots ?? []
            body(&spots)
            record.adjust.spots = spots
            record.edited = .now
        }
    }

    /// [ and ]: the chosen spot (or the next one's size) smaller or larger.
    @MainActor static func resize(_ path: String, by factor: Double) {
        let editing = PhotoEditing.shared
        let size = { (r: Double) in min(max(r * factor, 0.005), 0.15) }
        editing.healSize = size(editing.healSize)
        guard let id = editing.selectedSpot else { return }
        change(path) { spots in if let i = spots.firstIndex(where: { $0.id == id }) { spots[i].radius = size(spots[i].radius) } }
    }

    @MainActor static func remove(_ path: String, _ id: UUID) {
        PhotoCatalog.shared.endStep()
        change(path) { $0.removeAll { $0.id == id } }
        PhotoCatalog.shared.endStep()
        if PhotoEditing.shared.selectedSpot == id { PhotoEditing.shared.selectedSpot = nil }
    }
}

// MARK: - The Heal tab

/// Heal or clone spots on the photo shown: the kind and size for the next one (or the chosen one), the spots, Clear All.
struct PhotoHealPanel: View {
    let path: String
    let record: PhotoRecord
    /// Several photos selected: spots still go on the one shown only.
    var several = false
    @State private var editing = PhotoEditing.shared
    @State private var model = PhotoRemove.shared

    private var spots: [PhotoSpot] { record.adjust.spots ?? [] }
    private var selected: PhotoSpot? { spots.first { $0.id == editing.selectedSpot } }
    private var kind: PhotoSpot.Kind { selected?.kind ?? editing.healKind }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StudioSegmented(options: [(PhotoSpot.Kind.heal, LocalizedStringKey("Heal")), (PhotoSpot.Kind.clone, LocalizedStringKey("Clone")),
                                      (PhotoSpot.Kind.remove, LocalizedStringKey("Remove"))], selection: Binding(
                get: { kind },
                set: { kind in
                    editing.healKind = kind
                    // (A Remove spot stays one: it has no source to copy from, and Heal and Clone no painted area.)
                    if let selected, (selected.kind == .remove) != (kind == .remove) { editing.selectedSpot = nil } else { update { $0.kind = kind } }
                }))
                .padding(.horizontal, 8)
            if kind == .remove { removeModel }
            VStack(spacing: 0) {
                AdjustSlider(title: "Size", value: (selected?.radius ?? editing.healSize) * 100, range: 0.5...15, neutral: 2, format: "%.1f") { v in
                    editing.healSize = v / 100; update { $0.radius = v / 100 }
                }
                AdjustSlider(title: "Feather", value: (selected?.feather ?? editing.healFeather) * 100, range: 0...100, neutral: 50, format: "%.0f") { v in
                    editing.healFeather = v / 100; update { $0.feather = v / 100 }
                }
                AdjustSlider(title: "Opacity", value: (selected?.opacity ?? editing.healOpacity) * 100, range: 0...100, neutral: 100, format: "%.0f") { v in
                    editing.healOpacity = v / 100; update { $0.opacity = v / 100 }
                }
            }
            Text(kind == .remove ? "Paint over what should go: it's filled in from around it, on this Mac."
                 : several ? "Click the photo to fix a spot. Spots go on the photo shown only." : "Click the photo to fix a spot. [ and ] change the size.")
                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).padding(.horizontal, 8)
            if !spots.isEmpty {
                VStack(spacing: 2) {
                    ForEach(Array(spots.enumerated()), id: \.element.id) { index, spot in row(spot, index: index) }
                }
                Button("Clear All") {
                    PhotoCatalog.shared.endStep()
                    PhotoHeal.change(path) { $0.removeAll() }
                    PhotoCatalog.shared.endStep()
                    editing.selectedSpot = nil
                }
                .buttonStyle(.plain)
                .font(Design.Studio.body)
                .foregroundStyle(Design.Brand.pink)
                .padding(.horizontal, 8)
            }
        }
    }

    /// AI Remove's model: an optional download, run on this Mac.
    @ViewBuilder private var removeModel: some View {
        switch model.state {
        case .ready: EmptyView()
        case .downloading(let share):
            ProgressView(value: share).controlSize(.small).tint(Design.Brand.pink).padding(.horizontal, 8)
        case .failed(let problem):
            ProblemLabel(text: problem).padding(.horizontal, 8)
            Button("Try Again") { model.install() }.buttonStyle(StudioFlatButtonStyle()).padding(.horizontal, 8)
        case .notInstalled:
            Text("Remove needs its AI model, run on this Mac.").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                .padding(.horizontal, 8)
            Button("Get AI Remove (\(PhotoRemove.downloadMB) MB)", systemImage: "arrow.down") { model.install() }
                .buttonStyle(StudioFlatButtonStyle()).padding(.horizontal, 8)
        }
    }

    private func row(_ spot: PhotoSpot, index: Int) -> some View {
        let on = spot.id == editing.selectedSpot
        return HStack(spacing: 8) {
            Image(systemName: spot.kind == .heal ? "bandage" : spot.kind == .clone ? "square.on.square.dashed" : spot.kind == .remove ? "wand.and.stars" : "eye")
                .foregroundStyle(on ? Design.Brand.pink : Design.Studio.textQuiet)
                .frame(width: 18)
            Text("Spot \(index + 1)").font(Design.Studio.body).foregroundStyle(on ? Design.Studio.text : Design.Studio.textQuiet)
            Text(spot.kind == .heal ? "Heal" : spot.kind == .clone ? "Clone" : spot.kind == .remove ? "Remove" : spot.kind == .redEye ? "Red Eye" : "Pet Eye").font(Design.Studio.hint).foregroundStyle(Design.Studio.textFaint)
            Spacer()
            Button { PhotoHeal.remove(path, spot.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(Design.Studio.textQuiet)
                .help("Remove this spot")
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(on ? Design.Studio.raised : .clear, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
        .contentShape(.rect)
        .onTapGesture { editing.selectedSpot = on ? nil : spot.id }
    }

    private func update(_ body: @escaping (inout PhotoSpot) -> Void) {
        guard let id = editing.selectedSpot else { return }
        PhotoHeal.change(path) { spots in if let i = spots.firstIndex(where: { $0.id == id }) { body(&spots[i]) } }
    }
}

// MARK: - On the photo

/// The spots on the photo while the Heal tab is open: click adds one (its source found nearby), drag a target or its
/// dashed source to move it, the circle under the pointer is the size of the next one. `frame` is where the whole photo
/// (uncropped, unstraightened) is in the view.
struct PhotoHealHandles: View {
    let path: String
    let record: PhotoRecord
    let frame: CGRect
    @State private var editing = PhotoEditing.shared
    @State private var hover: CGPoint?
    @State private var start: (centre: CGPoint, source: CGPoint, stroke: [CGPoint]?)?
    /// Remove: the path being painted (shares).
    @State private var painting: [CGPoint] = []

    private var spots: [PhotoSpot] { record.adjust.spots ?? [] }
    private var long: Double { max(frame.width, frame.height) }

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(.rect)
                .onContinuousHover { phase in if case .active(let at) = phase { hover = at } else { hover = nil } }
                .onTapGesture { location in add(at: share(location)) }
                .gesture(editing.healKind == .remove ? paint : nil)
            if !painting.isEmpty {
                line(painting.map(point)).stroke(Design.Brand.pink.opacity(0.45), style: brush(editing.healSize * long * 2)).allowsHitTesting(false)
            }
            if let hover {
                let r = editing.healMode == 1 ? editing.eyeSize : editing.healSize
                Circle().stroke(.white.opacity(0.7), lineWidth: 1)
                    .frame(width: r * long * 2, height: r * long * 2)
                    .position(hover).allowsHitTesting(false)
            }
            ForEach(spots) { spot in marks(spot) }
        }
    }

    /// Remove: drag paints the area; letting go adds it (points kept a third of the brush apart).
    private var paint: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let p = share(value.location)
                let gap = editing.healSize * long / 3
                if let last = painting.last.map(point), hypot(last.x - value.location.x, last.y - value.location.y) < gap { return }
                if painting.isEmpty { painting = [share(value.startLocation)] }
                painting.append(CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1)))
            }
            .onEnded { _ in
                let stroke = painting
                painting = []
                guard let first = stroke.first else { return }
                let spot = PhotoSpot(kind: .remove, centre: first, source: first, radius: editing.healSize, feather: editing.healFeather,
                                     opacity: editing.healOpacity, stroke: stroke)
                PhotoCatalog.shared.endStep()
                PhotoHeal.change(path) { $0.append(spot) }
                PhotoCatalog.shared.endStep()
                editing.selectedSpot = spot.id
            }
    }

    /// A painted path's centre line (drawn with `brush`: its circles joined, one stroke so overlaps don't add up).
    private func line(_ points: [CGPoint]) -> Path {
        var line = Path()
        line.addLines(points)
        if points.count == 1, let p = points.first { line.addLine(to: CGPoint(x: p.x + 0.01, y: p.y)) }
        return line
    }

    private func brush(_ width: Double) -> StrokeStyle { StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round) }

    @ViewBuilder private func marks(_ spot: PhotoSpot) -> some View {
        if spot.kind == .remove { removeMarks(spot) } else if spot.kind == .redEye || spot.kind == .petEye { eyeMarks(spot) } else { spotMarks(spot) }
    }

    @ViewBuilder private func removeMarks(_ spot: PhotoSpot) -> some View {
        let on = spot.id == editing.selectedSpot
        let centre = line(spot.points.map(point)), style = brush(spot.radius * long * 2)
        // (Filled, not outlined: a painted path's outline crosses itself at every turn.)
        centre.stroke(on ? Design.Brand.pink.opacity(0.3) : Color.white.opacity(0.12), style: style)
            .contentShape(centre.strokedPath(style))
            .gesture(drag(spot, source: false))
            .onTapGesture { editing.selectedSpot = spot.id }
            .help("Removed: drag to move")
    }

    /// An eye fixed: its circle (no source).
    @ViewBuilder private func eyeMarks(_ spot: PhotoSpot) -> some View {
        let on = spot.id == editing.selectedSpot, size = spot.radius * long * 2
        Circle().stroke(on ? Design.Brand.pink : Color.white, lineWidth: 1.5)
            .shadow(color: .black.opacity(0.5), radius: 1)
            .frame(width: size, height: size)
            .contentShape(Circle())
            .position(point(spot.centre))
            .gesture(drag(spot, source: false))
            .onTapGesture { editing.selectedSpot = spot.id }
    }

    @ViewBuilder private func spotMarks(_ spot: PhotoSpot) -> some View {
        let on = spot.id == editing.selectedSpot
        let t = point(spot.centre), s = point(spot.source), size = spot.radius * long * 2
        let colour = on ? Design.Brand.pink : Color.white
        // The line between the edges of the two circles.
        let dx = t.x - s.x, dy = t.y - s.y, length = max(hypot(dx, dy), 1), r = size / 2
        if length > size {
            Path { p in
                p.move(to: CGPoint(x: s.x + dx / length * r, y: s.y + dy / length * r))
                p.addLine(to: CGPoint(x: t.x - dx / length * r, y: t.y - dy / length * r))
            }
            .stroke(colour.opacity(0.8), lineWidth: 1).shadow(color: .black.opacity(0.5), radius: 1).allowsHitTesting(false)
        }
        Circle().stroke(colour, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .shadow(color: .black.opacity(0.5), radius: 1)
            .frame(width: size, height: size)
            .contentShape(Circle())
            .position(s)
            .gesture(drag(spot, source: true))
            .help("The source: drag to copy from elsewhere")
        Circle().stroke(colour, lineWidth: 1.5)
            .shadow(color: .black.opacity(0.5), radius: 1)
            .frame(width: size, height: size)
            .contentShape(Circle())
            .position(t)
            .gesture(drag(spot, source: false))
            .onTapGesture { editing.selectedSpot = spot.id }
    }

    private func drag(_ spot: PhotoSpot, source: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if start == nil {
                    start = (spot.centre, spot.source, spot.stroke)
                    editing.selectedSpot = spot.id
                    PhotoCatalog.shared.endStep()
                }
                guard let start else { return }
                let move = CGSize(width: value.translation.width / max(frame.width, 1), height: value.translation.height / max(frame.height, 1))
                let moved = { (p: CGPoint) in CGPoint(x: min(max(p.x + move.width, 0), 1), y: min(max(p.y + move.height, 0), 1)) }
                PhotoHeal.change(path) { spots in
                    guard let i = spots.firstIndex(where: { $0.id == spot.id }) else { return }
                    if source { spots[i].source = moved(start.source) } else {
                        spots[i].centre = moved(start.centre)
                        spots[i].stroke = start.stroke?.map(moved)
                    }
                }
            }
            .onEnded { _ in start = nil; PhotoCatalog.shared.endStep() }
    }

    private func point(_ share: CGPoint) -> CGPoint { CGPoint(x: frame.minX + share.x * frame.width, y: frame.minY + share.y * frame.height) }

    private func share(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - frame.minX) / max(frame.width, 1), y: (point.y - frame.minY) / max(frame.height, 1))
    }

    private func add(at: CGPoint) {
        guard (0...1).contains(at.x), (0...1).contains(at.y) else { return }
        if editing.healMode == 1 {
            // Eyes: the eye under the pointer fixed (no source to find).
            let spot = PhotoSpot(kind: editing.eyeKind, centre: at, source: at, radius: editing.eyeSize, feather: 0.5, opacity: 1)
            PhotoCatalog.shared.endStep()
            PhotoHeal.change(path) { $0.append(spot) }
            PhotoCatalog.shared.endStep()
            editing.selectedSpot = spot.id
            return
        }
        if editing.healKind == .remove {
            // A click: the circle under the pointer goes.
            let spot = PhotoSpot(kind: .remove, centre: at, source: at, radius: editing.healSize, feather: editing.healFeather,
                                 opacity: editing.healOpacity, stroke: [at])
            PhotoCatalog.shared.endStep()
            PhotoHeal.change(path) { $0.append(spot) }
            PhotoCatalog.shared.endStep()
            editing.selectedSpot = spot.id
            return
        }
        let path = self.path, record = self.record, size = PhotoRender.previewSize
        var spot = PhotoSpot(kind: editing.healKind, centre: at, source: at, radius: editing.healSize, feather: editing.healFeather,
                             opacity: editing.healOpacity)
        Task {
            spot.source = await Task.detached(priority: .userInitiated) { () -> CGPoint in
                guard let kept = PhotoRender.base(path, maxSize: size, record: record) else {
                    return CGPoint(x: min(max(at.x + (at.x < 0.5 ? 2.5 : -2.5) * spot.radius, 0), 1), y: at.y)
                }
                return PhotoHeal.findSource(PhotoHeal.apply(record.adjust.spots, to: kept.image), centre: at, radius: spot.radius)
            }.value
            PhotoCatalog.shared.endStep()
            PhotoHeal.change(path) { $0.append(spot) }
            PhotoCatalog.shared.endStep()
            editing.selectedSpot = spot.id
        }
    }
}

/// The Heal tab's Eyes: red eye or pet eye, how big the circle is; click each eye on the photo. The eyes fixed are listed
/// with the other spots (Spots) and can be moved, resized or removed there too.
struct PhotoEyesPanel: View {
    let path: String
    let record: PhotoRecord
    @State private var editing = PhotoEditing.shared

    private var eyes: [PhotoSpot] { (record.adjust.spots ?? []).filter { $0.kind == .redEye || $0.kind == .petEye } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StudioSegmented(options: [(PhotoSpot.Kind.redEye, LocalizedStringKey("Red Eye")), (PhotoSpot.Kind.petEye, LocalizedStringKey("Pet Eye"))],
                            selection: Binding(get: { editing.eyeKind }, set: { kind in
                                editing.eyeKind = kind
                                if let id = editing.selectedSpot { PhotoHeal.change(path) { s in if let i = s.firstIndex(where: { $0.id == id && ($0.kind == .redEye || $0.kind == .petEye) }) { s[i].kind = kind } } }
                            }))
                .padding(.horizontal, 8)
            AdjustSlider(title: "Size", value: editing.eyeSize * 1000, range: 2...40, neutral: 8, format: "%.0f") { v in
                editing.eyeSize = v / 1000
                if let id = editing.selectedSpot { PhotoHeal.change(path) { s in if let i = s.firstIndex(where: { $0.id == id }) { s[i].radius = v / 1000 } } }
            }
            (editing.eyeKind == .redEye ? Text("Click each red eye. The circle should just cover the pupil.") : Text("Click each glowing eye: it's made a dark pupil with a small catch-light."))
                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).padding(.horizontal, 8)
                .fixedSize(horizontal: false, vertical: true)
            if !eyes.isEmpty {
                HStack {
                    Text("^[\(eyes.count) eye](inflect: true) fixed").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                    Spacer()
                    Button("Clear Eyes") {
                        PhotoCatalog.shared.endStep()
                        PhotoHeal.change(path) { $0.removeAll { $0.kind == .redEye || $0.kind == .petEye } }
                        PhotoCatalog.shared.endStep()
                    }
                    .buttonStyle(.plain).font(Design.Studio.body).foregroundStyle(Design.Brand.pink)
                }
                .padding(.horizontal, 8)
            }
        }
    }
}
