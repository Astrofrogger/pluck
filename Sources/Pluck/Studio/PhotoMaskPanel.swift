import SwiftUI

/// Masks (version 2): add one, choose it to see it in red and shape it on the photo, then set
/// what changes there. A mask is one or more parts (found by macOS, drawn, or a brightness or
/// colour range), each added, taken away or kept only where it overlaps.
struct PhotoMaskPanel: View {
    let path: String
    let record: PhotoRecord
    @State private var editing = PhotoEditing.shared
    @State private var catalog = PhotoCatalog.shared

    private var masks: [PhotoMask] { record.adjust.masks }
    private var selected: PhotoMask? { masks.first { $0.id == editing.selectedMask } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            picker
            if masks.isEmpty {
                Text("A mask changes part of the photo: pick what to change above.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
            }
            ForEach(Array(masks.enumerated()), id: \.element.id) { index, mask in
                VStack(alignment: .leading, spacing: 4) {
                    row(mask, index: index)
                    if mask.id == editing.selectedMask { details(mask) }
                }
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: Design.Radius.small)
                    .fill(mask.id == editing.selectedMask ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.04)))
                .onHover { inside in editing.hoverMask = inside ? mask.id : (editing.hoverMask == mask.id ? nil : editing.hoverMask) }
            }
            if selected != nil {
                Toggle(isOn: $editing.maskOverlay) { Label("Show in Red (O)", systemImage: "eye") }
                    .toggleStyle(.switch).controlSize(.mini).font(.caption)
                    .padding(.horizontal, 8)
            }
        }
    }

    /// New mask: what macOS finds, what's drawn, and ranges of the photo's own colours.
    private var picker: some View {
        let groups: [[MaskPart.Kind]] = [[.subject, .people, .object].filter(available), [.linear, .radial, .brush], [.luminance, .colour]]
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(groups.indices, id: \.self) { g in
                HStack(spacing: 6) {
                    ForEach(groups[g]) { kind in
                        Button { addMask(kind) } label: {
                            VStack(spacing: 3) {
                                Image(systemName: kind.symbol).font(.system(size: 15)).frame(height: 18)
                                Text(kind.title).font(.system(size: 9.5)).lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(RoundedRectangle(cornerRadius: Design.Radius.small).fill(Color.primary.opacity(0.06)))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(masks.count >= PhotoMasks.limit)
                        .help(masks.count >= PhotoMasks.limit ? "A photo has up to \(PhotoMasks.limit) masks" : "New mask: \(kind.title)")
                    }
                }
            }
        }
        .padding(.horizontal, 8)
    }

    private func available(_ kind: MaskPart.Kind) -> Bool { kind != .object || PhotoMasks.canFindObjects }

    // MARK: - A mask

    private func row(_ mask: PhotoMask, index: Int) -> some View {
        HStack(spacing: 6) {
            Button {
                if editing.selectedMask == mask.id { editing.selectedMask = nil } else { select(mask) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: mask.symbol).frame(width: 18)
                    Text(mask.parts.count > 1 ? "\(mask.title) +\(mask.parts.count - 1)" : mask.title).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .font(.callout.weight(.medium))
            Button { update(mask.id) { $0.invert.toggle() } } label: {
                Image(systemName: mask.invert ? "circle.righthalf.filled.inverse" : "circle.righthalf.filled")
            }
            .buttonStyle(.borderless)
            .help("Turn round: everywhere but here")
            Button {
                change { $0.adjust.masks.removeAll { $0.id == mask.id } }
                if editing.selectedMask == mask.id { editing.selectedMask = nil }
            } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder private func details(_ mask: PhotoMask) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if mask.shape.count == 1, let only = mask.shape.first {
                partControls(only, in: mask)
            } else {
                ForEach(Array(mask.shape.enumerated()), id: \.element.id) { index, part in
                    partRow(part, index: index, in: mask)
                    if part.id == editing.selectedPart { partControls(part, in: mask) }
                }
            }
            Menu {
                ForEach(MaskPart.Kind.allCases.filter(available)) { kind in
                    Button(kind.title, systemImage: kind.symbol) { addPart(kind, to: mask) }
                }
            } label: {
                Label("Add to Mask", systemImage: "plus.square.on.square")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .controlSize(.small)
            .padding(.horizontal, 8)
            Divider().padding(.vertical, 2)
            AdjustSlider(title: "Amount", value: mask.amount, range: 0...2, neutral: 1, label: "\(Int((mask.amount * 100).rounded()))%") { new in
                update(mask.id) { $0.amount = new }
            }
            slider("Exposure", mask, \.exposure, -4...4, "%+.2f")
            slider("Contrast", mask, \.contrast, -100...100, "%+.0f")
            slider("Highlights", mask, \.highlights, -100...100, "%+.0f")
            slider("Shadows", mask, \.shadows, -100...100, "%+.0f")
            slider("Temperature", mask, \.warmth, -100...100, "%+.0f", track: .temperature)
            slider("Tint", mask, \.tint, -100...100, "%+.0f", track: .tint)
            slider("Saturation", mask, \.saturation, -100...100, "%+.0f", track: .saturation)
            slider("Texture", mask, \.texture, -100...100, "%+.0f")
            slider("Clarity", mask, \.clarity, -100...100, "%+.0f")
            slider("Dehaze", mask, \.dehaze, -100...100, "%+.0f")
        }
    }

    // MARK: - Its parts

    private func partRow(_ part: MaskPart, index: Int, in mask: PhotoMask) -> some View {
        HStack(spacing: 6) {
            if index > 0 {
                Picker("How", selection: Binding(get: { part.mode }, set: { mode in updatePart(part.id, in: mask.id) { $0.mode = mode } })) {
                    Image(systemName: "plus").tag(MaskPart.Mode.add).help("Add")
                    Image(systemName: "minus").tag(MaskPart.Mode.subtract).help("Take away")
                    Image(systemName: "square.on.square.intersection.dashed").tag(MaskPart.Mode.intersect).help("Only where they overlap")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 84)
                .disabled(part.kind.isRange)
            }
            Button { editing.selectedPart = part.id } label: {
                Label(part.kind.title, systemImage: part.kind.symbol).lineLimit(1)
                    .fontWeight(part.id == editing.selectedPart ? .semibold : .regular)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            if !part.kind.isRange {
                Button { updatePart(part.id, in: mask.id) { $0.invert.toggle() } } label: {
                    Image(systemName: part.invert ? "circle.righthalf.filled.inverse" : "circle.righthalf.filled")
                }
                .buttonStyle(.borderless)
                .help("Turn this part round")
            }
            if mask.shape.count > 1 {
                Button { update(mask.id) { $0.parts.removeAll { $0.id == part.id } } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 8)
    }

    @ViewBuilder private func partControls(_ part: MaskPart, in mask: PhotoMask) -> some View {
        switch part.kind {
        case .linear:
            hint("Drag the two ends on the photo")
        case .radial:
            hint("Drag the centre and the edge on the photo")
            partSlider("Feather", part, in: mask, \.feather, 0...1)
        case .brush:
            hint("Paint on the photo")
            HStack {
                Toggle("Erase", isOn: $editing.brushErase).toggleStyle(.switch).controlSize(.mini)
                Spacer()
                Button("Clear") { updatePart(part.id, in: mask.id) { $0.strokes = [] } }.buttonStyle(.link)
            }
            .font(.callout)
            .padding(.horizontal, 8)
            plainSlider("Size", value: $editing.brushSize, 0.005...0.3)
            plainSlider("Softness", value: $editing.brushSoftness, 0...1)
        case .object:
            if editing.findingObject {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(editing.objectNote ?? String(localized: "Finding it…")) }
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
            } else if let note = editing.objectNote {
                Text(note).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
            } else {
                hint("Click the object on the photo")
            }
        case .luminance:
            hint("Click the photo to pick a brightness")
            partSlider("From", part, in: mask, \.low, 0...1)
            partSlider("To", part, in: mask, \.high, 0...1)
            partSlider("Smooth", part, in: mask, \.smooth, 0.01...0.5)
        case .colour:
            hint("Click the photo to pick a colour")
            HStack(spacing: 8) {
                Text("Hue").foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
                Slider(value: Binding(get: { part.hue }, set: { value in updatePart(part.id, in: mask.id) { $0.hue = value } }), in: 0...360)
                Circle().fill(Self.swatch(part.hue)).frame(width: 14, height: 14)
            }
            .font(.callout).controlSize(.small).padding(.horizontal, 8)
            partSlider("Range", part, in: mask, \.hueRange, 5...180)
        case .subject, .people:
            EmptyView()
        }
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
    }

    /// The colour at an OkLCh hue, for the colour range's swatch.
    static func swatch(_ hue: Double) -> Color {
        let r = hue * .pi / 180
        let (lr, lg, lb) = OkLab.to(0.7, 0.13 * cos(r), 0.13 * sin(r))
        func e(_ v: Double) -> Double { DevelopLUT.encode(min(max(v, 0), 1)) }
        return Color(red: e(lr), green: e(lg), blue: e(lb))
    }

    // MARK: - Sliders

    private func slider(_ title: LocalizedStringKey, _ mask: PhotoMask, _ path: WritableKeyPath<PhotoMask, Double>,
                        _ range: ClosedRange<Double>, _ format: String, neutral: Double = 0, track: AdjustSlider.Track = .plain) -> some View {
        AdjustSlider(title: title, value: mask[keyPath: path], range: range, neutral: neutral, format: format, track: track) { new in
            update(mask.id) { $0[keyPath: path] = new }
        }
    }

    private func partSlider(_ title: LocalizedStringKey, _ part: MaskPart, in mask: PhotoMask, _ path: WritableKeyPath<MaskPart, Double>,
                            _ range: ClosedRange<Double>) -> some View {
        plainSlider(title, value: Binding(get: { part[keyPath: path] }, set: { new in updatePart(part.id, in: mask.id) { $0[keyPath: path] = new } }), range)
    }

    private func plainSlider(_ title: LocalizedStringKey, value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary).lineLimit(1).frame(width: 84, alignment: .leading)
            Slider(value: value, in: range)
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(minHeight: 24)
    }

    // MARK: - Changes

    private func change(_ body: @escaping (inout PhotoRecord) -> Void) {
        catalog.update([path]) { record in
            body(&record)
            record.edited = .now
        }
    }

    private func update(_ id: UUID, _ body: @escaping (inout PhotoMask) -> Void) {
        change { record in
            guard let i = record.adjust.masks.firstIndex(where: { $0.id == id }) else { return }
            // A first-engine mask gets its part written out before it's changed.
            if record.adjust.masks[i].parts.isEmpty { record.adjust.masks[i].parts = record.adjust.masks[i].shape }
            body(&record.adjust.masks[i])
        }
    }

    private func updatePart(_ id: UUID, in mask: UUID, _ body: @escaping (inout MaskPart) -> Void) {
        update(mask) { mask in
            if let i = mask.parts.firstIndex(where: { $0.id == id }) { body(&mask.parts[i]) }
        }
    }

    private func addMask(_ kind: MaskPart.Kind) {
        let mask = PhotoMask(part: MaskPart(kind: kind))
        change { $0.adjust.masks.append(mask) }
        select(mask)
    }

    private func addPart(_ kind: MaskPart.Kind, to mask: PhotoMask) {
        var part = MaskPart(kind: kind)
        // A range narrows what's there already.
        if kind.isRange { part.mode = .intersect }
        update(mask.id) { $0.parts.append(part) }
        editing.selectedPart = part.id
    }

    private func select(_ mask: PhotoMask) {
        editing.selectedMask = mask.id
        editing.selectedPart = mask.shape.first?.id
        editing.objectNote = nil
    }
}

/// The chosen mask part's handles on the photo: a linear gradient's two ends, a radial's centre
/// and edges, the brush (paint, or rub out), or a click for an object. `frame` is where the
/// whole photo is in the view.
struct PhotoMaskHandles: View {
    let path: String
    let record: PhotoRecord
    let frame: CGRect
    @State private var editing = PhotoEditing.shared
    @State private var catalog = PhotoCatalog.shared
    @State private var start: (a: CGPoint, b: CGPoint)?
    @State private var painting = false
    @State private var hover: CGPoint?

    private var mask: PhotoMask? { record.adjust.masks.first { $0.id == editing.selectedMask } }
    private var part: MaskPart? {
        guard let mask else { return nil }
        return mask.shape.first { $0.id == editing.selectedPart } ?? mask.shape.first { !$0.kind.isRange }
    }

    var body: some View {
        if let mask, let part {
            ZStack {
                switch part.kind {
                case .linear: linear(part, in: mask)
                case .radial: radial(part, in: mask)
                case .brush: brush(part, in: mask)
                case .object: object(part, in: mask)
                case .luminance, .colour: pick(part, in: mask)
                default: EmptyView()
                }
            }
        }
    }

    // MARK: - Where things are

    private func point(_ share: CGPoint) -> CGPoint {
        CGPoint(x: frame.minX + share.x * frame.width, y: frame.minY + share.y * frame.height)
    }

    private func share(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - frame.minX) / max(frame.width, 1), y: (point.y - frame.minY) / max(frame.height, 1))
    }

    private func moveBy(_ p: CGPoint, _ t: CGSize) -> CGPoint {
        CGPoint(x: p.x + t.width / max(frame.width, 1), y: p.y + t.height / max(frame.height, 1))
    }

    // MARK: - Linear

    @ViewBuilder private func linear(_ part: MaskPart, in mask: PhotoMask) -> some View {
        let a = point(part.a), b = point(part.b)
        let dx = b.x - a.x, dy = b.y - a.y, length = max(hypot(dx, dy), 1)
        // Lines across the photo at both ends (where it's full and where it's gone).
        let across = CGPoint(x: -dy / length * 2000, y: dx / length * 2000)
        Path { p in
            for end in [a, b] {
                p.move(to: CGPoint(x: end.x - across.x, y: end.y - across.y))
                p.addLine(to: CGPoint(x: end.x + across.x, y: end.y + across.y))
            }
        }
        .stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        .allowsHitTesting(false)
        .mask(Rectangle().frame(width: frame.width, height: frame.height).position(x: frame.midX, y: frame.midY))
        Path { p in p.move(to: a); p.addLine(to: b) }.stroke(.white, lineWidth: 1.5).allowsHitTesting(false)
        handle(at: a) { t in setPart(part, in: mask) { $0.a = moveBy(start?.a ?? part.a, t) } }
        handle(at: b) { t in setPart(part, in: mask) { $0.b = moveBy(start?.b ?? part.b, t) } }
        handle(at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), small: true) { t in
            setPart(part, in: mask) { $0.a = moveBy(start?.a ?? part.a, t); $0.b = moveBy(start?.b ?? part.b, t) }
        }
    }

    // MARK: - Radial

    @ViewBuilder private func radial(_ part: MaskPart, in mask: PhotoMask) -> some View {
        let c = point(part.a)
        let rx = part.radius.width * frame.width, ry = part.radius.height * frame.height
        Ellipse().stroke(.white, lineWidth: 1.5).frame(width: rx * 2, height: ry * 2).position(c).allowsHitTesting(false)
        Ellipse().stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .frame(width: rx * 2 * (1 - part.feather), height: ry * 2 * (1 - part.feather)).position(c).allowsHitTesting(false)
        handle(at: c) { t in setPart(part, in: mask) { $0.a = moveBy(start?.a ?? part.a, t) } }
        handle(at: CGPoint(x: c.x + rx, y: c.y), small: true) { t in
            setPart(part, in: mask) { $0.radius.width = max(0.01, part.radius.width + t.width / max(frame.width, 1)) }
        }
        handle(at: CGPoint(x: c.x, y: c.y - ry), small: true) { t in
            setPart(part, in: mask) { $0.radius.height = max(0.01, part.radius.height - t.height / max(frame.height, 1)) }
        }
    }

    // MARK: - Brush

    private func brush(_ part: MaskPart, in mask: PhotoMask) -> some View {
        Color.clear
            .contentShape(.rect)
            .overlay {
                if let hover {
                    let size = editing.brushSize * max(frame.width, frame.height)
                    Circle().stroke(editing.brushErase ? .red : .white, lineWidth: 1).frame(width: size, height: size)
                        .position(hover).allowsHitTesting(false)
                }
            }
            .onContinuousHover { phase in
                if case .active(let at) = phase { hover = at } else { hover = nil }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    hover = value.location
                    let at = share(value.location)
                    setPart(part, in: mask) { part in
                        if !painting {
                            part.strokes.append(BrushStroke(points: [at], size: editing.brushSize, softness: editing.brushSoftness, erase: editing.brushErase))
                        } else if !part.strokes.isEmpty {
                            part.strokes[part.strokes.count - 1].points.append(at)
                        }
                    }
                    painting = true
                }
                .onEnded { _ in painting = false })
    }

    // MARK: - Ranges

    /// Click the photo: the range is set around what's there (its brightness, or its colour).
    private func pick(_ part: MaskPart, in mask: PhotoMask) -> some View {
        Color.clear
            .contentShape(.rect)
            .onTapGesture { location in
                let at = share(location), path = self.path, record = self.record
                Task {
                    guard let colour = await Task.detached(priority: .userInitiated, operation: { PhotoRender.sample(path, record: record, at: at) }).value
                    else { return }
                    let seen = PhotoRender.describe(colour)
                    setPart(part, in: mask) { range in
                        if range.kind == .luminance {
                            range.low = max(seen.brightness - 0.15, 0)
                            range.high = min(seen.brightness + 0.15, 1)
                        } else {
                            range.hue = seen.hue
                            range.hueRange = 40
                        }
                    }
                }
            }
            .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
    }

    // MARK: - Object

    private func object(_ part: MaskPart, in mask: PhotoMask) -> some View {
        Color.clear
            .contentShape(.rect)
            .onTapGesture { location in find(share(location), part: part, in: mask) }
            .overlay {
                if part.strokes.isEmpty, part.a != MaskPart(kind: .object).a || PhotoMasks.hasObject(path, at: part.a) {
                    Image(systemName: "plus.circle.fill").foregroundStyle(.white).position(point(part.a)).allowsHitTesting(false)
                }
            }
    }

    private func find(_ at: CGPoint, part: MaskPart, in mask: PhotoMask) {
        guard !editing.findingObject else { return }
        editing.findingObject = true
        editing.objectNote = nil
        let path = self.path, record = self.record
        Task {
            let found = await Task.detached(priority: .userInitiated) { () -> Bool in
                guard let kept = PhotoRender.base(path, maxSize: 1536, record: record) else { return false }
                let picture = PhotoEngine.develop(kept.image, PhotoAdjustments(), isRaw: PhotoRender.isRaw(path))
                return await PhotoMasks.findObject(path, at: at, from: picture, context: PhotoEngine.context) {
                    Task { @MainActor in PhotoEditing.shared.objectNote = String(localized: "macOS is getting its object finder…") }
                }
            }.value
            editing.findingObject = false
            if found {
                editing.objectNote = nil
                setPart(part, in: mask) { $0.a = at }
            } else {
                editing.objectNote = String(localized: "Nothing found there. Try clicking the middle of it.")
            }
        }
    }

    // MARK: - Handles

    private func handle(at p: CGPoint, small: Bool = false, move: @escaping (CGSize) -> Void) -> some View {
        Circle()
            .fill(.white)
            .overlay(Circle().stroke(.black.opacity(0.4), lineWidth: 1))
            .frame(width: small ? 10 : 14, height: small ? 10 : 14)
            .shadow(radius: 2)
            .contentShape(Circle().inset(by: -8))
            .position(p)
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if start == nil, let part { start = (part.a, part.b) }
                    move(value.translation)
                }
                .onEnded { _ in start = nil })
    }

    private func setPart(_ part: MaskPart, in mask: PhotoMask, _ body: @escaping (inout MaskPart) -> Void) {
        catalog.update([path]) { record in
            guard let i = record.adjust.masks.firstIndex(where: { $0.id == mask.id }) else { return }
            if record.adjust.masks[i].parts.isEmpty { record.adjust.masks[i].parts = record.adjust.masks[i].shape }
            if let j = record.adjust.masks[i].parts.firstIndex(where: { $0.id == part.id }) {
                body(&record.adjust.masks[i].parts[j])
            } else if let j = record.adjust.masks[i].parts.firstIndex(where: { $0.kind == part.kind }) {
                body(&record.adjust.masks[i].parts[j])
            }
            record.edited = .now
        }
    }
}
