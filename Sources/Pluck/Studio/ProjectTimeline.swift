import SwiftUI

/// A project's timeline: a ruler, the clips one after another (drag one to move it, drag its
/// edges to trim, click with the blade to cut), the music under them and the titles over them.
/// Files dropped on it (from Finder or Media) land where they're dropped.
struct ProjectTimeline: View {
    @Bindable var model: ProjectModel
    @Binding var zoom: Double
    /// Extra height, shared by the clips and the music.
    var grow: Double = 0

    private let ruler: CGFloat = 20
    private var clipsHeight: CGFloat { 64 + grow * 0.7 }
    private var musicHeight: CGFloat { 26 + grow * 0.3 }
    private let titlesHeight: CGFloat = 22
    private var height: CGFloat { ruler + 4 + clipsHeight + 4 + musicHeight + 4 + titlesHeight + 4 }
    private var clipsTop: CGFloat { ruler + 4 }
    private var musicTop: CGFloat { clipsTop + clipsHeight + 4 }
    private var titlesTop: CGFloat { musicTop + musicHeight + 4 }

    private enum Grab: Equatable {
        case playhead
        case clip(UUID, offset: Double)
        case clipStart(UUID), clipEnd(UUID)
        case music(UUID, offset: Double), musicStart(UUID), musicEnd(UUID)
        case title(UUID, offset: Double), titleStart(UUID), titleEnd(UUID)
        case click
    }

    @State private var grab: Grab?
    /// The project before a drag, so the whole drag is one step to undo.
    @State private var before: Project?
    /// Where a moved clip would land (an index into the clips), and where the pointer is.
    @State private var dropIndex: Int?
    @State private var dragX: CGFloat?
    @State private var dropTargeted = false
    @State private var inside = false
    @State private var scrollMonitor: Any?
    @State private var zoomAtStart: Double?

    /// Spots along the timeline to scroll to, fine enough to centre on the playhead.
    private static let slots = 400
    private var playheadSlot: Int { min(Int(model.time / max(model.duration, 0.001) * Double(Self.slots)), Self.slots - 1) }
    /// Zoomed all the way in, about two seconds fill the view.
    private var maxZoom: Double { max(1, min(model.duration / 2, 400)) }

    var body: some View {
        GeometryReader { outer in
            let width = max(outer.size.width * zoom, outer.size.width)
            ScrollViewReader { scroller in
                ScrollView(.horizontal) {
                    ZStack(alignment: .topLeading) {
                        track(width: width)
                        HStack(spacing: 0) {
                            ForEach(0..<Self.slots, id: \.self) { index in
                                Color.clear.frame(width: width / CGFloat(Self.slots), height: 1).id(index)
                            }
                        }
                        .allowsHitTesting(false)
                    }
                    .frame(width: width, height: height)
                }
                .scrollIndicators(zoom > 1 ? .visible : .hidden)
                .onChange(of: playheadSlot / 10) { _, _ in
                    // Following the playhead while it plays (a page at a time).
                    if zoom > 1, model.isPlaying { withAnimation(.easeOut(duration: 0.2)) { scroller.scrollTo(playheadSlot, anchor: .center) } }
                }
                .onChange(of: zoom) { _, _ in scroller.scrollTo(playheadSlot, anchor: .center) }
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers, location in
                let seconds = Double(location.x / width) * max(model.duration, 0.001)
                let index = insertionIndex(at: seconds)
                Task { @MainActor in
                    var files: [URL] = []
                    for provider in providers {
                        if let url = await provider.load(URL.self), url.isFileURL { files.append(url) }
                    }
                    await model.add(files, at: index)
                    AppDelegate.shared?.ai.imported(files)
                }
                return true
            }
        }
        .frame(height: height + (zoom > 1 ? 12 : 0))
        .onHover { inside = $0 }
        // ⌥ and scrolling zooms, as in editing programs; so does pinching.
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
        .simultaneousGesture(MagnifyGesture()
            .onChanged { value in
                if zoomAtStart == nil { zoomAtStart = zoom }
                zoom = min(max((zoomAtStart ?? 1) * value.magnification, 1), maxZoom)
            }
            .onEnded { _ in zoomAtStart = nil })
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Design.Radius.control).strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false)
            }
        }
    }

    // MARK: - Drawing

    private func track(width: CGFloat) -> some View {
        let seconds = max(model.duration, 0.001)
        func x(_ t: Double) -> CGFloat { CGFloat(t / seconds) * width }
        func t(_ x: CGFloat) -> Double { min(max(Double(x / width) * seconds, 0), seconds) }
        let offsets = model.offsets

        return ZStack(alignment: .topLeading) {
            rulerView(width: width)
            // Lanes.
            lane(top: clipsTop, height: clipsHeight, width: width)
            lane(top: musicTop, height: musicHeight, width: width, label: "music.note")
            lane(top: titlesTop, height: titlesHeight, width: width, label: "textformat")

            ForEach(Array(model.project.clips.enumerated()), id: \.element.id) { index, clip in
                let left = x(offsets[index]), w = max(x(offsets[index] + clip.length) - left, 2)
                ClipBlock(clip: clip, thumbnails: model.thumbnails[clip.path] ?? [], selected: model.selected.contains(clip.id),
                          moving: grab == .clip(clip.id, offset: grabOffset(clip.id)))
                    .frame(width: w, height: clipsHeight)
                    .offset(x: left, y: clipsTop)
                    .opacity(isMoving(clip.id) ? 0.35 : 1)
            }
            // A moved clip, under the pointer, and where it would land.
            if case .clip(let id, _) = grab, let dragX, let clip = model.project.clips.first(where: { $0.id == id }) {
                let w = max(x(clip.length), 24)
                ClipBlock(clip: clip, thumbnails: model.thumbnails[clip.path] ?? [], selected: true, moving: true)
                    .frame(width: w, height: clipsHeight)
                    .offset(x: dragX - w / 2, y: clipsTop - 6)
                    .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
                    .allowsHitTesting(false)
                if let dropIndex {
                    let at = dropIndex < offsets.count ? x(offsets[dropIndex]) : width
                    Capsule().fill(Design.Brand.gradient).frame(width: 3, height: clipsHeight + 8)
                        .offset(x: at - 1.5, y: clipsTop - 4)
                }
            }
            ForEach(model.project.music) { song in
                let left = x(song.at), w = max(x(min(song.at + song.length, seconds)) - left, 2)
                lengthBlock(song.name, symbol: "music.note", tint: .teal, selected: model.selected.contains(song.id))
                    .frame(width: w, height: musicHeight)
                    .offset(x: left, y: musicTop)
            }
            ForEach(model.project.titles) { title in
                let left = x(title.start), w = max(x(title.end) - left, 2)
                lengthBlock(title.text, symbol: "textformat", tint: Design.Brand.violet, selected: model.selectedTitle == title.id)
                    .frame(width: w, height: titlesHeight)
                    .offset(x: left, y: titlesTop)
            }
            // The playhead.
            Rectangle().fill(Color.red).frame(width: 1.5, height: height)
                .overlay(alignment: .top) {
                    Image(systemName: "arrowtriangle.down.fill").font(.system(size: 11)).foregroundStyle(.red).offset(y: -2)
                }
                .offset(x: x(model.time) - 0.75)
                .allowsHitTesting(false)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .contentShape(.rect)
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in changed(value, width: width, t: t, x: x) }
            .onEnded { value in ended(value, t: t) })
    }

    private func lane(top: CGFloat, height: CGFloat, width: CGFloat, label: String? = nil) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.primary.opacity(0.04))
            .overlay(alignment: .leading) {
                if let label { Image(systemName: label).font(.system(size: 9)).foregroundStyle(.tertiary).padding(.leading, 4) }
            }
            .frame(width: width, height: height)
            .offset(y: top)
            .allowsHitTesting(false)
    }

    private func lengthBlock(_ text: String, symbol: String, tint: Color, selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(tint.opacity(selected ? 0.85 : 0.55))
            .overlay(alignment: .leading) {
                Label(text, systemImage: symbol).labelStyle(.titleAndIcon)
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.white).lineLimit(1).padding(.horizontal, 6)
            }
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(selected ? 0.9 : 0.15)) }
            .clipped()
            .allowsHitTesting(false)
    }

    private func rulerView(width: CGFloat) -> some View {
        let seconds = max(model.duration, 0.001)
        let perSecond = width / seconds
        let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800]
        let step = steps.first { $0 * perSecond >= 80 } ?? 3600
        return Canvas { context, size in
            var t = 0.0
            while t <= seconds {
                let x = CGFloat(t) * perSecond
                context.fill(Path(CGRect(x: x, y: size.height - 6, width: 1, height: 6)), with: .color(.secondary.opacity(0.6)))
                context.draw(Text(Format.duration(t)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary),
                             at: CGPoint(x: x + 3, y: 1), anchor: .topLeading)
                t += step
            }
        }
        .frame(width: width, height: ruler)
        .allowsHitTesting(false)
    }

    // MARK: - Dragging

    private func grabOffset(_ id: UUID) -> Double {
        if case .clip(let grabbed, let offset) = grab, grabbed == id { return offset }
        return -1
    }

    private func isMoving(_ id: UUID) -> Bool {
        if case .clip(let grabbed, _) = grab, grabbed == id, dragX != nil { return true }
        return false
    }

    /// Where a clip dropped at this time goes: before the clip whose middle is after it.
    private func insertionIndex(at seconds: Double) -> Int {
        let offsets = model.offsets
        for (index, clip) in model.project.clips.enumerated() where seconds < offsets[index] + clip.length / 2 { return index }
        return model.project.clips.count
    }

    private func changed(_ value: DragGesture.Value, width: CGFloat, t: (CGFloat) -> Double, x: (Double) -> CGFloat) {
        let seconds = max(model.duration, 0.001)
        let tolerance = Double(8 / width) * seconds
        if grab == nil {
            before = model.project
            grab = grabbed(at: value.startLocation, t: t, x: x)
        }
        let moved = abs(value.translation.width) > 3
        switch grab {
        case .playhead:
            model.seek(to: t(value.location.x))
        case .click:
            if moved, model.tool == .select { grab = .playhead; model.seek(to: t(value.location.x)) }
        case .clip(_, _):
            if moved {
                dragX = value.location.x
                dropIndex = insertionIndex(at: t(value.location.x))
            }
        case .clipStart(let id):
            guard let clip = before?.clips.first(where: { $0.id == id }) else { return }
            let delta = Double(value.translation.width / width) * seconds
            model.trim(id, start: clip.start + delta * clip.speed, record: false)
        case .clipEnd(let id):
            guard let clip = before?.clips.first(where: { $0.id == id }) else { return }
            let delta = Double(value.translation.width / width) * seconds
            model.trim(id, end: clip.end + delta * clip.speed, record: false)
        case .music(let id, let offset):
            let at = max(model.snapped(t(value.location.x) - offset, tolerance: tolerance), 0)
            model.setMusic(id, record: false) { $0.at = at }
        case .musicStart(let id):
            guard let song = before?.music.first(where: { $0.id == id }) else { return }
            let delta = Double(value.translation.width / width) * seconds
            let moved = min(max(delta, -song.start), song.length - 0.5)
            model.setMusic(id, record: false) { $0.at = song.at + moved; $0.start = song.start + moved }
        case .musicEnd(let id):
            guard let song = before?.music.first(where: { $0.id == id }) else { return }
            let delta = Double(value.translation.width / width) * seconds
            model.setMusic(id, record: false) { $0.end = max(song.end + delta, song.start + 0.5) }
        case .title(let id, let offset):
            guard let title = before?.titles.first(where: { $0.id == id }) else { return }
            let length = title.end - title.start
            let start = min(max(model.snapped(t(value.location.x) - offset, tolerance: tolerance), 0), max(seconds - length, 0))
            model.setTitle(id, record: false) { $0.start = start; $0.end = start + length }
        case .titleStart(let id):
            guard let title = before?.titles.first(where: { $0.id == id }) else { return }
            let start = min(model.snapped(t(value.location.x), tolerance: tolerance), title.end - 0.3)
            model.setTitle(id, record: false) { $0.start = max(start, 0) }
        case .titleEnd(let id):
            guard let title = before?.titles.first(where: { $0.id == id }) else { return }
            let end = max(model.snapped(t(value.location.x), tolerance: tolerance), title.start + 0.3)
            model.setTitle(id, record: false) { $0.end = min(end, seconds) }
        default:
            break
        }
    }

    private func ended(_ value: DragGesture.Value, t: (CGFloat) -> Double) {
        defer {
            grab = nil
            before = nil
            dragX = nil
            dropIndex = nil
        }
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        switch grab {
        case .click:
            let at = t(value.location.x)
            if model.tool == .blade { model.split(at: at) } else { model.selected = []; model.selectedTitle = nil; model.seek(to: at) }
        case .clip(let id, _):
            if dragX != nil, let dropIndex {
                model.move(id, to: dropIndex)
            } else if model.tool == .blade {
                model.split(at: t(value.location.x))
            } else {
                if flags.contains(.shift) || flags.contains(.command) {
                    if model.selected.contains(id) { model.selected.remove(id) } else { model.selected.insert(id) }
                } else {
                    model.selected = [id]
                }
                model.selectedTitle = nil
            }
        case .clipStart, .clipEnd, .music, .musicStart, .musicEnd, .title, .titleStart, .titleEnd:
            if let before, before.clips != model.project.clips || before.music != model.project.music || before.titles != model.project.titles {
                model.commit(from: before)
            }
        default:
            break
        }
    }

    /// What's under the pointer where a drag starts.
    private func grabbed(at point: CGPoint, t: (CGFloat) -> Double, x: (Double) -> CGFloat) -> Grab {
        if point.y <= ruler { return .playhead }
        let edge: CGFloat = 6
        if point.y >= clipsTop, point.y <= clipsTop + clipsHeight {
            let offsets = model.offsets
            for (index, clip) in model.project.clips.enumerated() {
                let left = x(offsets[index]), right = x(offsets[index] + clip.length)
                guard point.x >= left - edge, point.x <= right + edge else { continue }
                if model.tool == .select {
                    if abs(point.x - left) <= edge, right - left > edge * 3 { return .clipStart(clip.id) }
                    if abs(point.x - right) <= edge, right - left > edge * 3 { return .clipEnd(clip.id) }
                }
                if point.x >= left, point.x <= right { return .clip(clip.id, offset: t(point.x) - offsets[index]) }
            }
        }
        if point.y >= musicTop, point.y <= musicTop + musicHeight {
            for song in model.project.music {
                let left = x(song.at), right = x(song.at + song.length)
                if abs(point.x - left) <= edge { model.selected = [song.id]; return .musicStart(song.id) }
                if abs(point.x - right) <= edge { model.selected = [song.id]; return .musicEnd(song.id) }
                if point.x > left, point.x < right { model.selected = [song.id]; return .music(song.id, offset: t(point.x) - song.at) }
            }
        }
        if point.y >= titlesTop, point.y <= titlesTop + titlesHeight {
            for title in model.project.titles {
                let left = x(title.start), right = x(title.end)
                if abs(point.x - left) <= edge { model.selectedTitle = title.id; return .titleStart(title.id) }
                if abs(point.x - right) <= edge { model.selectedTitle = title.id; return .titleEnd(title.id) }
                if point.x > left, point.x < right { model.selectedTitle = title.id; return .title(title.id, offset: t(point.x) - title.start) }
            }
        }
        return .click
    }
}

/// One clip on the timeline: pictures from it, its name, and (from the story finder) its part
/// in the story as a coloured band.
private struct ClipBlock: View {
    let clip: ProjectClip
    let thumbnails: [NSImage]
    let selected: Bool
    let moving: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.6)
                if !thumbnails.isEmpty {
                    HStack(spacing: 0) {
                        let count = max(Int(geometry.size.width / 70), 1)
                        ForEach(0..<count, id: \.self) { slot in
                            Image(nsImage: thumbnails[min(slot * thumbnails.count / count, thumbnails.count - 1)])
                                .resizable().scaledToFill()
                                .frame(width: geometry.size.width / CGFloat(count), height: geometry.size.height)
                                .clipped()
                        }
                    }
                } else {
                    Image(systemName: "waveform").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .center)
                VStack(alignment: .leading, spacing: 1) {
                    if let role = clip.role {
                        Capsule().fill(role.color).frame(height: 3)
                    }
                    Text(clip.name).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.top, clip.role == nil ? 3 : 1)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(selected ? AnyShapeStyle(Design.Brand.gradient) : AnyShapeStyle(Color.white.opacity(0.18)), lineWidth: selected ? 2 : 1)
        }
        .padding(.horizontal, 0.5)
        .allowsHitTesting(false)
    }
}
