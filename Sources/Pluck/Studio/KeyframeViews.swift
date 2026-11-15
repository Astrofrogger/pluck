import SwiftUI

/// The keyframe controls by a setting: to the one before, a diamond (filled on a keyframe: click
/// to take it away; empty: click to add one at the playhead), to the one after.
struct KeyDiamonds: View {
    let on: Bool
    /// The setting has keyframes.
    let animated: Bool
    let toggle: () -> Void
    var seek: ((Bool) -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            arrow("chevron.left", forward: false)
            Button(action: toggle) {
                Image(systemName: on ? "diamond.fill" : "diamond")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(on ? AnyShapeStyle(Design.Brand.gradient) : AnyShapeStyle(animated ? Design.Studio.text : Design.Studio.textFaint))
                    .frame(width: 16, height: Design.Studio.sliderRow)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(on ? "Remove the keyframe" : "Add a keyframe at the playhead")
            arrow("chevron.right", forward: true)
        }
        .frame(width: 40)
    }

    @ViewBuilder private func arrow(_ symbol: String, forward: Bool) -> some View {
        if animated, let seek {
            Button { seek(forward) } label: {
                Image(systemName: symbol).font(.system(size: 8, weight: .bold)).foregroundStyle(Design.Studio.textQuiet)
                    .frame(width: 12, height: Design.Studio.sliderRow).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(forward ? "Next keyframe" : "Previous keyframe")
        } else {
            Color.clear.frame(width: 12, height: 1)
        }
    }
}

/// A curve drawn small (the ease presets' buttons, the lane's segments).
struct KeyEaseGlyph: Shape {
    let ease: KeyEase
    func path(in rect: CGRect) -> Path {
        Path { p in
            let steps = 24
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let point = CGPoint(x: rect.minX + rect.width * t, y: rect.maxY - rect.height * ease.apply(t))
                if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
            }
        }
    }
}

/// The curve between a keyframe and the next: the value (up) over time (across), with a handle
/// from each end to drag (a custom cubic-Bézier, as CSS and After Effects' speed graph have).
struct KeyCurveEditor: View {
    let ease: KeyEase
    /// A change: `record` false while a handle is dragged.
    let change: (KeyEase, Bool) -> Void

    /// How far past 0…1 the graph shows (for curves that overshoot).
    private let low = -0.3, high = 1.3
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let c = ease.curve
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Design.Studio.controlRadius).fill(Design.Studio.backdrop)
                // 0 and 1 of the value.
                Path { p in
                    for v in [0.0, 1.0] { p.move(to: point(0, v, size)); p.addLine(to: point(1, v, size)) }
                }
                .stroke(Design.Studio.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                if ease.kind != .hold {
                    Path { p in
                        p.move(to: point(0, 0, size)); p.addLine(to: point(c.x1, c.y1, size))
                        p.move(to: point(1, 1, size)); p.addLine(to: point(c.x2, c.y2, size))
                    }
                    .stroke(Design.Studio.textFaint, lineWidth: 1)
                }
                Path { p in
                    let steps = 80
                    for i in 0...steps {
                        let t = Double(i) / Double(steps)
                        let q = point(t, ease.apply(t), size)
                        if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
                    }
                }
                .stroke(Design.Brand.gradient, lineWidth: 2)
                if ease.kind != .hold {
                    handle(first: true, at: point(c.x1, c.y1, size), size: size)
                    handle(first: false, at: point(c.x2, c.y2, size), size: size)
                }
            }
        }
        .frame(height: 120)
        .accessibilityElement()
        .accessibilityLabel(Text("Keyframe curve"))
    }

    private func point(_ t: Double, _ v: Double, _ size: CGSize) -> CGPoint {
        CGPoint(x: 8 + (size.width - 16) * t, y: size.height - (size.height * (v - low) / (high - low)))
    }

    private func handle(first: Bool, at: CGPoint, size: CGSize) -> some View {
        Circle().fill(Design.Studio.text)
            .frame(width: 10, height: 10)
            .overlay { Circle().strokeBorder(Design.Brand.violet, lineWidth: 2) }
            .position(at)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    dragging = true
                    let t = min(max(Double((value.location.x - 8) / max(size.width - 16, 1)), 0), 1)
                    let v = min(max(low + Double((size.height - value.location.y) / max(size.height, 1)) * (high - low), low), high)
                    let c = ease.curve
                    let new = first ? KeyEase(x1: t, y1: v, x2: c.x2, y2: c.y2) : KeyEase(x1: c.x1, y1: c.y1, x2: t, y2: v)
                    change(new, false)
                }
                .onEnded { _ in dragging = false; change(ease, true) })
    }
}

/// The Clip tab's keyframes section: a setting's curves between its keyframes, the presets, and
/// copying keyframes or curves to other clips.
struct KeyframeSection: View {
    @Bindable var model: ProjectModel
    let clip: ProjectClip
    @State private var chosen: KeyProperty?

    var body: some View {
        let look = clip.look ?? ClipLook()
        let keyed = look.keyedProperties
        if !keyed.isEmpty || KeyClipboard.keys != nil {
            FoldSection(title: "Keyframes", key: "clip-keyframes") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        if !keyed.isEmpty {
                            Picker("Keyframes", selection: Binding(get: { property(keyed) }, set: { chosen = $0 })) {
                                ForEach(keyed) { Text(verbatim: $0.label).tag(Optional($0)) }
                            }
                            .labelsHidden()
                        }
                        Spacer()
                        menu(hasKeys: !keyed.isEmpty)
                    }
                    if let property = property(keyed), let segment = segment(look.keyframes(property)) {
                        let key = look.keyframes(property)[segment]
                        KeyCurveEditor(ease: key.ease) { ease, record in
                            model.setEase(ease, keys: targets(key), of: clip.id, record: record)
                        }
                        presets(key)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    /// The setting shown: the chosen one, else the first keyframed.
    private func property(_ keyed: [KeyProperty]) -> KeyProperty? {
        chosen.flatMap { keyed.contains($0) ? $0 : nil } ?? keyed.first
    }

    /// The keyframe whose curve is shown: one chosen on the lane, else the one at or before the playhead (never the last).
    private func segment(_ frames: [Keyframe]) -> Int? {
        guard frames.count > 1 else { return nil }
        if let i = frames.firstIndex(where: { model.selectedKeys.contains($0.id) }) { return min(i, frames.count - 2) }
        let here = model.localTime(clip.id) ?? 0
        return min(frames.lastIndex(where: { $0.time <= here + 0.01 }) ?? 0, frames.count - 2)
    }

    /// The keyframes a curve goes to: those chosen on the lane, or this one.
    private func targets(_ key: Keyframe) -> Set<UUID> {
        model.selectedKeys.contains(key.id) ? model.selectedKeys : [key.id]
    }

    private func presets(_ key: Keyframe) -> some View {
        HStack(spacing: 4) {
            ForEach(KeyEase.Kind.allCases.filter { $0 != .custom }) { kind in
                let on = key.ease.kind == kind
                Button { model.setEase(KeyEase(kind), keys: targets(key), of: clip.id) } label: {
                    KeyEaseGlyph(ease: KeyEase(kind))
                        .stroke(on ? Design.Studio.text : Design.Studio.textQuiet, lineWidth: 1.5)
                        .frame(width: 18, height: 14)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background(on ? Design.Studio.line : Design.Studio.backdrop, in: .rect(cornerRadius: 6, style: .continuous))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(Text(kind.title))
            }
            Button { KeyClipboard.curve = key.ease } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.plain).foregroundStyle(Design.Studio.textQuiet).frame(width: 22).help("Copy the curve")
            Button { if let curve = KeyClipboard.curve { model.setEase(curve, keys: targets(key), of: clip.id) } } label: { Image(systemName: "doc.on.clipboard") }
                .buttonStyle(.plain).foregroundStyle(Design.Studio.textQuiet).frame(width: 22)
                .disabled(KeyClipboard.curve == nil)
                .help("Paste the curve (on the keyframes chosen on the timeline)")
        }
        .font(.system(size: 11))
    }

    private func menu(hasKeys: Bool) -> some View {
        Menu {
            if hasKeys { Button("Copy Keyframes") { model.copyKeys(clip.id) } }
            if KeyClipboard.keys != nil {
                Button("Paste Keyframes") { model.pasteKeys(into: [clip.id], stretch: false) }
                Button("Paste and Stretch to Fit") { model.pasteKeys(into: [clip.id], stretch: true) }
            }
            if hasKeys {
                Divider()
                Button("Remove All Keyframes", role: .destructive) {
                    model.changeKeys(clip.id) { look in
                        // Each setting stays as it is at the playhead.
                        let here = look.resolved(at: model.localTime(clip.id) ?? 0)
                        for property in KeyProperty.picture { if let path = property.path { look[keyPath: path] = here[keyPath: path] } }
                        look.keys = nil
                    }
                }
            }
        } label: { Image(systemName: "ellipsis.circle") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
}

/// The selected clip's keyframes, on a lane under the main line: one row of all of them, or a
/// row per setting when opened. Drag them in time (the chosen ones together), click to choose
/// (⇧ adds), ⌫ takes the chosen ones out.
struct KeyframeLane: View {
    @Bindable var model: ProjectModel
    let clip: ProjectClip
    /// Where the clip starts on the timeline, and the timeline's seconds to points.
    let start: Double
    let x: (Double) -> CGFloat
    let seconds: (CGFloat) -> Double
    let open: Bool

    static let row: CGFloat = 14
    static func height(open: Bool, rows: Int) -> CGFloat { row + 4 + (open ? CGFloat(rows) * row : 0) }

    @State private var dragStart: ClipLook?

    var body: some View {
        let look = clip.look ?? ClipLook()
        let keyed = look.keyedProperties
        let left = x(start), right = x(start + clip.length)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(Design.Studio.raised.opacity(0.6))
                .frame(width: max(right - left, 2), height: Self.height(open: open, rows: keyed.count) - 2)
                .offset(x: left)
                .onTapGesture { model.selectedKeys = [] }
            // All of them: those at the same moment as one diamond.
            ForEach(groups(look, keyed), id: \.[0]) { ids in
                diamond(ids, look: look, y: 2)
            }
            if open {
                ForEach(Array(keyed.enumerated()), id: \.element) { row, property in
                    Text(verbatim: property.label)
                        .font(.system(size: 8)).foregroundStyle(Design.Studio.textFaint)
                        .offset(x: right + 4, y: Self.row * CGFloat(row + 1) + 3)
                        .allowsHitTesting(false)
                    ForEach(look.keyframes(property)) { key in
                        diamond([key.id], look: look, y: Self.row * CGFloat(row + 1) + 2)
                    }
                }
            }
        }
        .contextMenu { menu(look) }
    }

    /// The keyframes of every setting, by the moment they're at (within half a frame).
    private func groups(_ look: ClipLook, _ keyed: [KeyProperty]) -> [[UUID]] {
        let all = keyed.flatMap { look.keyframes($0) }.sorted { $0.time < $1.time }
        var out: [[UUID]] = [], at: Double?
        for key in all {
            if let at, abs(key.time - at) < model.frame / 2 { out[out.count - 1].append(key.id) } else { out.append([key.id]); at = key.time }
        }
        return out
    }

    private func time(of id: UUID, in look: ClipLook) -> Double {
        look.keyedProperties.lazy.compactMap { look.keyframes($0).first { $0.id == id }?.time }.first ?? 0
    }

    private func diamond(_ ids: [UUID], look: ClipLook, y: CGFloat) -> some View {
        let chosen = ids.allSatisfy { model.selectedKeys.contains($0) }
        let at = x(start + time(of: ids[0], in: look))
        return Image(systemName: "diamond.fill")
            .font(.system(size: 9))
            .foregroundStyle(chosen ? AnyShapeStyle(Design.Brand.gradient) : AnyShapeStyle(Design.Studio.text))
            .frame(width: 12, height: Self.row)
            .contentShape(.rect)
            .offset(x: max(at - 6, 0), y: y)   // (one at the timeline's start stays whole)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStart == nil {
                        dragStart = look
                        let adding = NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command)
                        if !chosen { model.selectedKeys = adding ? model.selectedKeys.union(ids) : Set(ids) }
                    }
                    let frame = model.frame
                    let delta = ((seconds(value.location.x) - seconds(value.startLocation.x)) / frame).rounded() * frame
                    if abs(value.translation.width) > 2, let dragStart {
                        model.moveKeys(model.selectedKeys, of: clip.id, by: delta, from: dragStart, record: false)
                    }
                }
                .onEnded { value in
                    if abs(value.translation.width) > 2 {
                        model.changeKeys(clip.id, record: true) { _ in }
                    } else {
                        model.endDrag()
                        // A click: the playhead to it.
                        model.seek(to: start + time(of: ids[0], in: look))
                    }
                    dragStart = nil
                })
            .help(Text("Drag to move, ⇧-click to add to the choice"))
    }

    @ViewBuilder private func menu(_ look: ClipLook) -> some View {
        if look.hasKeys { Button("Copy Keyframes") { model.copyKeys(clip.id) } }
        if KeyClipboard.keys != nil {
            Button("Paste Keyframes") { model.pasteKeys(into: [clip.id], stretch: false) }
            Button("Paste and Stretch to Fit") { model.pasteKeys(into: [clip.id], stretch: true) }
        }
        if !model.selectedKeys.isEmpty {
            Menu("Ease") {
                ForEach(KeyEase.Kind.allCases.filter { $0 != .custom }) { kind in
                    Button { model.setEase(KeyEase(kind), keys: model.selectedKeys, of: clip.id) } label: { Text(kind.title) }
                }
            }
            Divider()
            Button("Delete Keyframes", role: .destructive) { _ = model.deleteSelectedKeys() }
        }
    }
}
