import SwiftUI

/// The Editor's timeline: a ruler, the filmstrip and the waveform, cut into parts (taken-out parts
/// crossed out), with the range between the in and out points lit and the rest dimmed. With the
/// selection tool a click selects a part and dragging moves the playhead; with the blade a click
/// cuts. The ruler always moves the playhead. Zoom with ⌥ and scrolling, ⌘+ and ⌘−, the slider, or
/// by pinching.
struct EditorTimeline: View {
    @Bindable var model: EditorModel
    @Binding var zoom: Double
    /// Extra height, shared by the pictures and the sound.
    var grow: Double = 0

    private let ruler: CGFloat = 20
    private var filmstrip: CGFloat { model.hasVideo ? 58 + grow * 0.6 : 0 }
    private var wave: CGFloat { model.hasVideo ? 44 + grow * 0.4 : 110 + grow }
    /// A lane for moments and filler words, when there are any.
    private var lane: CGFloat {
        model.visibleMarkers.contains { $0.kind == .moment || $0.kind == .filler || $0.kind == .story } ? 10 : 0
    }
    /// The subtitle track, when there are subtitles.
    private var captions: CGFloat { model.subtitles.isEmpty ? 0 : 24 }
    /// Where the subtitle track starts, from the top.
    private var captionsTop: CGFloat { ruler + 2 + (model.hasVideo ? filmstrip + 2 : 0) + wave + 2 + (lane > 0 ? lane + 2 : 0) }
    private var height: CGFloat { ruler + filmstrip + wave + lane + captions + 6 }

    @State private var dragging: Handle?
    @State private var zoomAtStart: Double?
    /// Where the pointer is over the track, for the blade's line.
    @State private var hover: CGFloat?
    /// The pointer is over the timeline (for ⌥-scroll zooming).
    @State private var inside = false
    @State private var scrollMonitor: Any?

    private enum Handle: Equatable {
        case playhead, inPoint, outPoint, click
        /// A subtitle line: its start, its end, or all of it (grabbed this far into it).
        case cueStart(UUID), cueEnd(UUID), cueMove(UUID, Double), cueClick(UUID)
    }

    var body: some View {
        GeometryReader { outer in
            let width = max(outer.size.width * zoom, outer.size.width)
            ScrollViewReader { scroller in
                ScrollView(.horizontal) {
                    ZStack(alignment: .topLeading) {
                        track(width: width)
                        // Points to scroll to, so the playhead stays in sight while zoomed in.
                        HStack(spacing: 0) {
                            ForEach(0..<Self.slots, id: \.self) { index in
                                Color.clear.frame(width: width / CGFloat(Self.slots), height: 1).id(index)
                            }
                        }
                    }
                    .frame(width: width, height: height)
                }
                .scrollIndicators(zoom > 1 ? .visible : .hidden)
                .onChange(of: playheadSlot / 10) { _, _ in
                    // Following the playhead while it plays (a page at a time).
                    if zoom > 1, model.isPlaying || dragging == nil { withAnimation(.easeOut(duration: 0.2)) { scroller.scrollTo(playheadSlot, anchor: .center) } }
                }
                .onChange(of: zoom) { _, _ in
                    // Zooming keeps the playhead in the middle.
                    scroller.scrollTo(playheadSlot, anchor: .center)
                }
            }
        }
        .frame(height: height + (zoom > 1 ? 12 : 0))
        .onHover { inside = $0 }
        // ⌥ and scrolling zooms, as in editing programs.
        .onAppear {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                guard inside, event.modifierFlags.contains(.option) else { return event }
                let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
                zoom = min(max(zoom * exp(Double(delta) * 0.01), 1), maxZoom)
                return nil
            }
        }
        .onDisappear {
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            scrollMonitor = nil
        }
        .gesture(MagnifyGesture()
            .onChanged { value in
                if zoomAtStart == nil { zoomAtStart = zoom }
                zoom = min(max((zoomAtStart ?? 1) * value.magnification, 1), maxZoom)
            }
            .onEnded { _ in zoomAtStart = nil })
    }

    private var maxZoom: Double { max(1, min(model.duration / 2, 200)) }

    /// Spots along the timeline to scroll to, fine enough to centre on the playhead.
    private static let slots = 400
    private var playheadSlot: Int { min(Int(model.time / max(model.duration, 0.001) * Double(Self.slots)), Self.slots - 1) }

    // MARK: - The track

    private func track(width: CGFloat) -> some View {
        let seconds = max(model.duration, 0.001)
        func x(_ t: Double) -> CGFloat { CGFloat(t / seconds) * width }
        func t(_ x: CGFloat) -> Double { min(max(Double(x / width) * seconds, 0), seconds) }

        return ZStack(alignment: .topLeading) {
            rulerView(width: width)
            VStack(spacing: 2) {
                if model.hasVideo { filmstripView(width: width) }
                waveView(width: width)
                if lane > 0 { laneView(width: width) }
                if captions > 0 { captionsView(width: width) }
            }
            .padding(.top, ruler + 2)
            markersView(width: width)
            partsView(width: width)

            // Outside the range: dimmed.
            if model.hasRange {
                Rectangle().fill(.black.opacity(0.62))
                    .frame(width: x(model.rangeStart), height: height - ruler)
                    .offset(y: ruler)
                    .allowsHitTesting(false)
                Rectangle().fill(.black.opacity(0.62))
                    .frame(width: max(width - x(model.rangeEnd), 0), height: height - ruler)
                    .offset(x: x(model.rangeEnd), y: ruler)
                    .allowsHitTesting(false)
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.yellow, lineWidth: 2)
                    .frame(width: max(x(model.rangeEnd) - x(model.rangeStart), 2), height: height - ruler)
                    .offset(x: x(model.rangeStart), y: ruler)
                    .allowsHitTesting(false)
                handle(at: x(model.rangeStart), edge: .leading)
                handle(at: x(model.rangeEnd), edge: .trailing)
            }

            // The blade's line, where a click would cut.
            if model.tool == .blade, let hover, hover > 0 {
                let at = x(model.snapped(t(hover), tolerance: Double(8 / width) * seconds))
                Rectangle()
                    .fill(Color.red.opacity(0.8))
                    .frame(width: 1, height: height - ruler)
                    .overlay(alignment: .top) {
                        Image(systemName: "scissors").font(.system(size: 10, weight: .bold)).foregroundStyle(.red).offset(y: -12)
                    }
                    .offset(x: at - 0.5, y: ruler)
                    .allowsHitTesting(false)
            }

            // The playhead.
            Rectangle()
                .fill(Color.red)
                .frame(width: 1.5, height: height)
                .overlay(alignment: .top) {
                    Image(systemName: "arrowtriangle.down.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .offset(y: -2)
                }
                .offset(x: x(model.time) - 0.75)
                .allowsHitTesting(false)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .contentShape(.rect)
        .onContinuousHover { phase in
            if case .active(let point) = phase, point.y > ruler { hover = point.x } else { hover = nil }
        }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                let tolerance = Double(8 / width) * seconds
                if dragging == nil {
                    // On the ruler: the playhead. Near a range edge: that edge. Otherwise wait and
                    // see whether it's a click (select or cut) or a drag (move the playhead).
                    let grab: CGFloat = 8
                    if captions > 0, value.startLocation.y >= captionsTop, value.startLocation.y <= captionsTop + captions,
                       let cue = model.subtitles.first(where: { x($0.start) - 4 <= value.startLocation.x && value.startLocation.x <= x($0.end) + 4 }) {
                        // On a subtitle: its edges change when it shows, the middle moves it.
                        let edge = min(6, (x(cue.end) - x(cue.start)) / 3)
                        if abs(value.startLocation.x - x(cue.start)) <= edge { dragging = .cueStart(cue.id) }
                        else if abs(value.startLocation.x - x(cue.end)) <= edge { dragging = .cueEnd(cue.id) }
                        else { dragging = .cueClick(cue.id) }
                        model.selectedSubtitle = cue.id
                    } else if value.startLocation.y <= ruler {
                        dragging = .playhead
                    } else if model.hasRange, abs(value.startLocation.x - x(model.rangeStart)) < grab {
                        dragging = .inPoint
                    } else if model.hasRange, abs(value.startLocation.x - x(model.rangeEnd)) < grab {
                        dragging = .outPoint
                    } else {
                        dragging = .click
                    }
                }
                if dragging == .click, abs(value.translation.width) > 3, model.tool == .select {
                    dragging = .playhead
                }
                if case .cueClick(let id) = dragging, abs(value.translation.width) > 3,
                   let cue = model.subtitles.first(where: { $0.id == id }) {
                    dragging = .cueMove(id, t(value.startLocation.x) - cue.start)
                }
                switch dragging {
                case .inPoint:
                    let point = model.snapped(t(value.location.x), tolerance: tolerance, excluding: model.inPoint)
                    model.inPoint = min(point, model.rangeEnd - model.frame)
                    model.scrub(to: model.rangeStart)
                case .outPoint:
                    let point = model.snapped(t(value.location.x), tolerance: tolerance, excluding: model.outPoint)
                    model.outPoint = max(point, model.rangeStart + model.frame)
                    model.scrub(to: model.rangeEnd)
                case .playhead:
                    model.scrub(to: model.snapped(t(value.location.x), tolerance: tolerance, excluding: model.time))
                case .cueStart(let id):
                    model.setSubtitleStart(id, to: model.snapped(t(value.location.x), tolerance: tolerance))
                case .cueEnd(let id):
                    model.setSubtitleEnd(id, to: model.snapped(t(value.location.x), tolerance: tolerance))
                case .cueMove(let id, let grabbed):
                    model.moveSubtitle(id, toStart: model.snapped(t(value.location.x) - grabbed, tolerance: tolerance))
                default:
                    break
                }
            }
            .onEnded { value in
                let tolerance = Double(8 / width) * seconds
                let at = t(value.location.x)
                switch dragging {
                case .inPoint: model.endScrub(at: model.rangeStart)
                case .outPoint: model.endScrub(at: model.rangeEnd)
                case .cueStart, .cueEnd, .cueMove:
                    model.saveSubtitles()
                case .cueClick(let id):
                    // A click on a line: there, and picked in the sidebar.
                    if let cue = model.subtitles.first(where: { $0.id == id }) { model.seek(to: cue.start + 0.01) }
                case .click:
                    if model.tool == .blade {
                        model.cut(at: model.snapped(at, tolerance: tolerance))
                    } else {
                        let flags = NSApp.currentEvent?.modifierFlags ?? []
                        model.select(at: at, adding: flags.contains(.shift) || flags.contains(.command))
                        model.seek(to: model.snapped(at, tolerance: tolerance, excluding: model.time))
                    }
                default: model.endScrub(at: model.snapped(at, tolerance: tolerance, excluding: model.time))
                }
                dragging = nil
            })
    }

    private func handle(at x: CGFloat, edge: HorizontalEdge) -> some View {
        UnevenRoundedRectangle(topLeadingRadius: edge == .leading ? 4 : 0, bottomLeadingRadius: edge == .leading ? 4 : 0,
                               bottomTrailingRadius: edge == .trailing ? 4 : 0, topTrailingRadius: edge == .trailing ? 4 : 0)
            .fill(Color.yellow)
            .frame(width: 8, height: height - ruler)
            .overlay {
                Capsule().fill(.black.opacity(0.5)).frame(width: 2, height: 16)
            }
            .offset(x: edge == .leading ? x : x - 8, y: ruler)
            .allowsHitTesting(false)
    }

    // MARK: - Layers

    private func rulerView(width: CGFloat) -> some View {
        let seconds = max(model.duration, 0.001)
        let perSecond = width / seconds
        // The smallest step that leaves room for a label.
        let steps: [Double] = [1.0 / max(model.frameRate, 1) * 5, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]
        let step = steps.first { $0 * perSecond >= 80 } ?? 3600
        return Canvas { context, size in
            var t = 0.0
            while t <= seconds {
                let x = CGFloat(t) * perSecond
                context.fill(Path(CGRect(x: x, y: size.height - 6, width: 1, height: 6)), with: .color(.secondary.opacity(0.6)))
                // Smaller ticks in between.
                for quarter in 1..<4 {
                    let minor = x + CGFloat(step) * perSecond * CGFloat(quarter) / 4
                    if minor < size.width { context.fill(Path(CGRect(x: minor, y: size.height - 3, width: 1, height: 3)), with: .color(.secondary.opacity(0.35))) }
                }
                let label = step < 1 ? model.timecode(t) : Format.duration(t)
                context.draw(Text(label).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary),
                             at: CGPoint(x: x + 3, y: 1), anchor: .topLeading)
                t += step
            }
        }
        .frame(width: width, height: ruler)
        .allowsHitTesting(false)
    }

    private func filmstripView(width: CGFloat) -> some View {
        let slotWidth = filmstrip * model.aspect
        let thumbnails = model.thumbnails
        return Canvas { context, size in
            guard !thumbnails.isEmpty, slotWidth > 0 else { return }
            var x: CGFloat = 0
            while x < size.width {
                // The thumbnail nearest the middle of this slot.
                let fraction = Double((x + slotWidth / 2) / size.width)
                let index = min(Int(fraction * Double(thumbnails.count)), thumbnails.count - 1)
                let rect = CGRect(x: x, y: 0, width: slotWidth, height: size.height)
                if let image = thumbnails[index] {
                    context.draw(Image(decorative: image, scale: 1), in: rect)
                } else {
                    context.fill(Path(rect.insetBy(dx: 0.5, dy: 0)), with: .color(.secondary.opacity(0.15)))
                }
                x += slotWidth
            }
        }
        .frame(width: width, height: filmstrip)
        .clipShape(.rect(cornerRadius: 4))
        .allowsHitTesting(false)
    }

    /// Chapters (orange lines with their name), cuts (white ticks on the filmstrip) and pauses
    /// (grey over the waveform).
    private func markersView(width: CGFloat) -> some View {
        let seconds = max(model.duration, 0.001)
        let markers = model.visibleMarkers
        let top = ruler + 2, film = filmstrip, waveTop = ruler + 2 + (filmstrip > 0 ? filmstrip + 2 : 0)
        return Canvas { context, size in
            for marker in markers {
                let x = CGFloat(marker.start / seconds) * width
                switch marker.kind {
                case .cut where film > 0:
                    context.fill(Path(CGRect(x: x - 0.5, y: top, width: 1, height: film)), with: .color(.white.opacity(0.85)))
                case .silence:
                    let end = CGFloat((marker.end ?? marker.start) / seconds) * width
                    context.fill(Path(CGRect(x: x, y: waveTop, width: max(end - x, 1), height: wave)), with: .color(.gray.opacity(0.35)))
                case .chapter:
                    context.fill(Path(CGRect(x: x - 0.5, y: top, width: 1.5, height: size.height - top)), with: .color(.orange))
                    let label = Text(marker.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                    let resolved = context.resolve(label)
                    let labelSize = resolved.measure(in: CGSize(width: 160, height: 14))
                    let box = CGRect(x: x, y: top, width: min(labelSize.width + 8, 168), height: 15)
                    context.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(.orange.opacity(0.9)))
                    context.draw(resolved, in: box.insetBy(dx: 4, dy: 1))
                default:
                    break
                }
            }
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
    }

    /// The parts of the edit: cuts as bright lines, taken-out parts darkened and struck through
    /// in red, selected parts outlined.
    private func partsView(width: CGFloat) -> some View {
        let seconds = max(model.duration, 0.001)
        let parts = model.parts, selected = model.selected, cuts = model.cuts
        let top = ruler + 2, trackHeight = height - ruler - 4
        return Canvas { context, size in
            for part in parts {
                let x = CGFloat(part.start / seconds) * width, w = CGFloat(part.length / seconds) * width
                let rect = CGRect(x: x, y: top, width: w, height: trackHeight)
                if part.removed {
                    context.fill(Path(rect), with: .color(.black.opacity(0.62)))
                    // Red stripes, like a part lifted out of an edit.
                    var stripes = Path()
                    var offset = -trackHeight
                    while offset < w {
                        stripes.move(to: CGPoint(x: x + offset, y: top + trackHeight))
                        stripes.addLine(to: CGPoint(x: x + offset + trackHeight, y: top))
                        offset += 9
                    }
                    var striped = context
                    striped.clip(to: Path(rect))
                    striped.stroke(stripes, with: .color(.red.opacity(0.45)), lineWidth: 1.2)
                }
            }
        }
        .overlay {
            Canvas { context, size in
                for part in parts where selected.contains(part.start) {
                    let x = CGFloat(part.start / seconds) * width, w = CGFloat(part.length / seconds) * width
                    context.stroke(Path(roundedRect: CGRect(x: x + 1, y: top + 1, width: max(w - 2, 2), height: trackHeight - 2), cornerRadius: 3),
                                   with: .color(.accentColor), lineWidth: 2.5)
                }
                for cut in cuts {
                    let x = CGFloat(cut / seconds) * width
                    context.fill(Path(CGRect(x: x - 1, y: top, width: 2, height: trackHeight)), with: .color(.white))
                    context.fill(Path(CGRect(x: x - 0.5, y: top, width: 1, height: trackHeight)), with: .color(.black.opacity(0.6)))
                }
            }
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
    }

    /// The subtitles as blocks with their words, like a subtitle track. The picked one is lit,
    /// with grips at its edges to drag.
    private func captionsView(width: CGFloat) -> some View {
        let seconds = max(model.duration, 0.001)
        let cues = model.subtitles, shown = model.showSubtitles, picked = model.selectedSubtitle
        let brand = Gradient(colors: [Design.Brand.pink, Design.Brand.violet])
        return Canvas { context, size in
            for cue in cues {
                let x = CGFloat(cue.start / seconds) * width, w = max(CGFloat((cue.end - cue.start) / seconds) * width - 1, 2)
                let rect = CGRect(x: x, y: 1, width: w, height: size.height - 2)
                let shape = Path(roundedRect: rect, cornerRadius: 4)
                if cue.id == picked {
                    context.fill(shape, with: .linearGradient(brand, startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
                    context.stroke(shape, with: .color(.white.opacity(0.9)), lineWidth: 1)
                    if w > 14 {
                        for gx in [rect.minX + 3, rect.maxX - 5] {
                            context.fill(Path(roundedRect: CGRect(x: gx, y: rect.midY - 5, width: 2, height: 10), cornerRadius: 1), with: .color(.white.opacity(0.9)))
                        }
                    }
                } else {
                    context.fill(shape, with: .color(Design.Brand.violet.opacity(shown ? 0.5 : 0.2)))
                    context.stroke(shape, with: .color(.white.opacity(0.12)), lineWidth: 1)
                }
                if w > 24 {
                    let label = context.resolve(Text(cue.text.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 10, weight: .medium)).foregroundStyle(.white))
                    var inner = context
                    inner.clip(to: Path(rect.insetBy(dx: 7, dy: 0)))
                    inner.draw(label, at: CGPoint(x: x + 8, y: size.height / 2), anchor: .leading)
                }
            }
        }
        .frame(width: width, height: captions)
        .allowsHitTesting(false)
    }

    /// Moments (green), story passages (pink) and filler words (red).
    private func laneView(width: CGFloat) -> some View {
        let seconds = max(model.duration, 0.001)
        let markers = model.visibleMarkers.filter { $0.kind == .moment || $0.kind == .filler || $0.kind == .story }
        return Canvas { context, size in
            func band(_ start: Double, _ end: Double, _ color: Color) {
                let x = CGFloat(start / seconds) * width, w = max(CGFloat((end - start) / seconds) * width, 2)
                context.fill(Path(roundedRect: CGRect(x: x, y: 2, width: w, height: 6), cornerRadius: 3), with: .color(color))
            }
            for marker in markers {
                band(marker.start, marker.end ?? marker.start + 0.3,
                     marker.kind == .story ? Design.Brand.pink.opacity(0.9) : marker.kind == .moment ? .green.opacity(0.85) : .red.opacity(0.85))
            }
        }
        .frame(width: width, height: lane)
        .allowsHitTesting(false)
    }

    private func waveView(width: CGFloat) -> some View {
        let peaks = model.peaks
        return Canvas { context, size in
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4), with: .color(.secondary.opacity(0.08)))
            guard !peaks.isEmpty else { return }
            let middle = size.height / 2
            var path = Path()
            let columns = Int(size.width)
            for column in stride(from: 0, to: columns, by: 2) {
                let a = Int(Double(column) / Double(columns) * Double(peaks.count))
                let b = max(a + 1, Int(Double(column + 2) / Double(columns) * Double(peaks.count)))
                let peak = peaks[a..<min(b, peaks.count)].max() ?? 0
                let half = max(CGFloat(peak) * (middle - 2), 0.5)
                path.addRect(CGRect(x: CGFloat(column), y: middle - half, width: 1.2, height: half * 2))
            }
            context.fill(path, with: .color(Color.accentColor.opacity(0.8)))
        }
        .frame(width: width, height: wave)
        .allowsHitTesting(false)
    }
}
