import SwiftUI

/// A project's timeline: a ruler, the clips one after another (drag one to move it, drag its
/// edges to trim, click with the blade to cut), the music under them and the titles over them.
/// Files dropped on it (from Finder or Media) land where they're dropped.
struct ProjectTimeline: View {
    @Bindable var model: ProjectModel
    @Binding var zoom: Double
    /// Extra height, shared by the clips and the music.
    var grow: Double = 0
    @AppStorage("projectPacing") private var pacing = false
    @AppStorage("projectPacingLong") private var pacingLong = 8.0
    @AppStorage("projectPacingShort") private var pacingShort = 10

    private let ruler: CGFloat = 20
    private var clipsHeight: CGFloat { 64 + grow * 0.7 }
    private var musicHeight: CGFloat { 26 + grow * 0.3 }
    private let titlesHeight: CGFloat = 22
    private let overlayHeight: CGFloat = 40
    private let soundHeight: CGFloat = 30
    /// The tracks laid over the main line (drawn above it, the first nearest), and the sound
    /// tracks beside it (below it).
    private var overlays: [ProjectTrack] { (model.project.tracks ?? []).filter { $0.kind == .video } }
    private var sounds: [ProjectTrack] { (model.project.tracks ?? []).filter { $0.kind == .audio } }
    /// Looks over parts of the timeline: a thin lane on top, once there's one.
    private let looksHeight: CGFloat = 18
    private var looksTop: CGFloat { ruler + 4 }
    private var hasLooks: Bool { !(model.project.adjustments ?? []).isEmpty }
    private var clipsTop: CGFloat { looksTop + (hasLooks ? looksHeight + 4 : 0) + CGFloat(overlays.count) * (overlayHeight + 4) }
    private var soundsTop: CGFloat { clipsTop + clipsHeight + 4 }
    private var musicTop: CGFloat { soundsTop + CGFloat(sounds.count) * (soundHeight + 4) }
    private var titlesTop: CGFloat { musicTop + musicHeight + 4 }
    private var height: CGFloat { titlesTop + titlesHeight + 4 }

    /// Where a track's lane is, and how tall.
    private func laneTop(_ track: ProjectTrack) -> (top: CGFloat, height: CGFloat)? {
        if let index = overlays.firstIndex(where: { $0.id == track.id }) {
            return (clipsTop - CGFloat(index + 1) * (overlayHeight + 4), overlayHeight)
        }
        if let index = sounds.firstIndex(where: { $0.id == track.id }) {
            return (soundsTop + CGFloat(index) * (soundHeight + 4), soundHeight)
        }
        return nil
    }

    private enum Grab: Equatable {
        case playhead
        case clip(UUID, offset: Double)
        case clipStart(UUID), clipEnd(UUID)
        /// The cut after a clip (by index), moved between it and the next; a clip slipped.
        case roll(Int), slip(UUID)
        case music(UUID, offset: Double), musicStart(UUID), musicEnd(UUID)
        case title(UUID, offset: Double), titleStart(UUID), titleEnd(UUID)
        case look(UUID, offset: Double), lookStart(UUID), lookEnd(UUID)
        case item(UUID, offset: Double), itemStart(UUID), itemEnd(UUID)
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
    /// A trim pointer is shown (pushed, to pop when it leaves).
    @State private var trimCursor = false

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
                // Above the main line: laid over it; on a sound track: beside it; else into it.
                let over = location.y < clipsTop && !(hasLooks && location.y < looksTop + looksHeight + 4), sound = location.y >= soundsTop && location.y < musicTop
                Task { @MainActor in
                    var files: [URL] = []
                    for provider in providers {
                        if let url = await provider.load(URL.self), url.isFileURL { files.append(url) }
                    }
                    if over {
                        for file in files { await model.addOverlay(file, at: seconds) }
                    } else if sound {
                        for file in files { await model.addAudio(file, at: seconds) }
                    } else {
                        await model.add(files, at: index)
                    }
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
            if trimCursor { NSCursor.pop(); trimCursor = false }
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
        let flags = pacing ? Pacing.flags(model.project.clips, frameRate: model.frameRate, longAfter: pacingLong, shortUnder: pacingShort) : []

        return ZStack(alignment: .topLeading) {
            rulerView(width: width)
            // Lanes.
            lane(top: clipsTop, height: clipsHeight, width: width)
            lane(top: musicTop, height: musicHeight, width: width, label: "music.note")
            lane(top: titlesTop, height: titlesHeight, width: width, label: "textformat")
            ForEach(model.project.tracks ?? []) { track in
                if let (top, laneHeight) = laneTop(track) {
                    lane(top: top, height: laneHeight, width: width, label: track.kind == .video ? "square.on.square" : "waveform")
                    ForEach(track.items) { item in
                        let left = x(item.at ?? 0), w = max(x((item.at ?? 0) + item.length) - left, 2)
                        Group {
                            if track.kind == .video {
                                ClipBlock(clip: item, thumbnails: model.thumbnails[ProjectModel.thumbnailKey(item)] ?? [],
                                          selected: model.selected.contains(item.id), moving: false,
                                          offline: model.missing.contains(item.path), peaks: [])
                            } else {
                                lengthBlock(item.name, symbol: item.link == nil ? "waveform" : "link", tint: Color(red: 0.16, green: 0.55, blue: 0.33),
                                            selected: model.selected.contains(item.id))
                            }
                        }
                        .frame(width: w, height: laneHeight)
                        .offset(x: left, y: top)
                        .opacity(track.hidden || track.muted ? 0.4 : 1)
                    }
                }
            }

            ForEach(Array(model.project.clips.enumerated()), id: \.element.id) { index, clip in
                let left = x(offsets[index]), w = max(x(offsets[index] + clip.length) - left, 2)
                ClipBlock(clip: clip, thumbnails: model.thumbnails[ProjectModel.thumbnailKey(clip)] ?? [], selected: model.selected.contains(clip.id),
                          moving: grab == .clip(clip.id, offset: grabOffset(clip.id)), offline: model.missing.contains(clip.path),
                          peaks: model.peaks(for: clip))
                    .frame(width: w, height: clipsHeight)
                    .offset(x: left, y: clipsTop)
                    .opacity(isMoving(clip.id) ? 0.35 : 1)
            }
            // Pacing (when on): a tint over long shots, a red tick on very short clips, a mark on each jump cut.
            ForEach(Array(flags.enumerated()), id: \.offset) { _, flag in
                let clip = model.project.clips[flag.index]
                let left = x(offsets[flag.index]), w = max(x(offsets[flag.index] + clip.length) - left, 2)
                switch flag.kind {
                case .long:
                    Rectangle().fill(Color.orange.opacity(0.22))
                        .frame(width: w, height: clipsHeight)
                        .offset(x: left, y: clipsTop)
                case .short:
                    Rectangle().fill(Color.red)
                        .frame(width: 3, height: 10)
                        .offset(x: left + w / 2 - 1.5, y: clipsTop)
                case .jumpCut:
                    VStack(spacing: 1) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(.yellow)
                        Rectangle().fill(Color.yellow).frame(width: 2, height: clipsHeight - 12)
                    }
                    .frame(width: 12, height: clipsHeight, alignment: .top)
                    .offset(x: left - 6, y: clipsTop)
                }
            }
            .allowsHitTesting(false)
            // Dips at the edits: a small black or white mark on the cut.
            ForEach(Array(model.project.clips.enumerated()), id: \.element.id) { index, clip in
                if let dip = clip.dipOut {
                    let at = x(offsets[index] + clip.length)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(dip.white ? Color.white : Color.black)
                        .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(.white.opacity(0.7), lineWidth: 1) }
                        .rotationEffect(.degrees(45))
                        .frame(width: 9, height: 9)
                        .offset(x: at - 4.5, y: clipsTop + clipsHeight - 14)
                        .allowsHitTesting(false)
                }
            }
            // Dissolves at the edits: two pictures blending.
            ForEach(Array(model.project.clips.enumerated()), id: \.element.id) { index, clip in
                if clip.transitionIn != nil {
                    Image(systemName: "square.on.square.intersection.dashed")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Circle().fill(Design.Brand.gradient))
                        .offset(x: x(offsets[index]) - 9, y: clipsTop + clipsHeight - 20)
                        .help(ProjectTransition(kind: .dissolve, length: 1).label)
                        .allowsHitTesting(false)
                }
            }
            // A moved clip, under the pointer, and where it would land.
            if case .clip(let id, _) = grab, let dragX, let clip = model.project.clips.first(where: { $0.id == id }) {
                let w = max(x(clip.length), 24)
                ClipBlock(clip: clip, thumbnails: model.thumbnails[ProjectModel.thumbnailKey(clip)] ?? [], selected: true, moving: true, peaks: model.peaks(for: clip))
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
                lengthBlock(song.name, symbol: model.missing.contains(song.path) ? "exclamationmark.triangle.fill" : "music.note",
                            tint: model.missing.contains(song.path) ? .red : .teal, selected: model.selected.contains(song.id))
                    .overlay { beatGrid(song, left: left, x: x) }
                    .overlay { duckBand(song, left: left, x: x) }
                    .frame(width: w, height: musicHeight)
                    .offset(x: left, y: musicTop)
            }
            if hasLooks { lane(top: looksTop, height: looksHeight, width: width, label: "camera.filters") }
            ForEach(model.project.adjustments ?? []) { look in
                let left = x(look.start), w = max(x(look.end) - left, 2)
                lengthBlock(String(localized: "Look"), symbol: "camera.filters", tint: .orange, selected: model.selected.contains(look.id))
                    .frame(width: w, height: looksHeight)
                    .offset(x: left, y: looksTop)
            }
            ForEach(model.project.titles) { title in
                let left = x(title.start), w = max(x(title.end) - left, 2)
                lengthBlock(title.text, symbol: "textformat", tint: Design.Brand.violet, selected: model.selectedTitle == title.id)
                    .frame(width: w, height: titlesHeight)
                    .offset(x: left, y: titlesTop)
            }
            marks(width: width, x: x)
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
        .onContinuousHover { phase in hovered(phase, x: x) }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in changed(value, width: width, t: t, x: x) }
            .onEnded { value in ended(value, t: t) })
    }

    /// The in and out points (outside them dimmed), the markers on the ruler, and what's found
    /// in the file at the playhead, where it falls in the edit.
    @ViewBuilder private func marks(width: CGFloat, x: @escaping (Double) -> CGFloat) -> some View {
        if model.hasRange {
            let range = model.range
            Color.black.opacity(0.16).frame(width: max(x(range.lowerBound), 0), height: height - ruler).offset(y: ruler).allowsHitTesting(false)
            Color.black.opacity(0.16).frame(width: max(width - x(range.upperBound), 0), height: height - ruler)
                .offset(x: x(range.upperBound), y: ruler).allowsHitTesting(false)
            Capsule().fill(Design.Brand.gradient).frame(width: max(x(range.upperBound) - x(range.lowerBound), 2), height: 4)
                .offset(x: x(range.lowerBound), y: ruler - 4)
                .allowsHitTesting(false)
        }
        if let path = model.focusedPath {
            let focus = model.focus(path)
            Canvas { context, size in
                for marker in focus.markers where focus.shownKinds.contains(marker.kind) {
                    for at in model.timelineTimes(of: marker.start, in: path) {
                        let px = x(at)
                        context.fill(Path(CGRect(x: px - 0.5, y: 0, width: 1, height: size.height)), with: .color(marker.kind.tint.opacity(0.9)))
                    }
                }
            }
            .frame(width: width, height: 5)
            .offset(y: clipsTop - 5)
            .allowsHitTesting(false)
        }
        ForEach(model.project.markers ?? []) { marker in
            Image(systemName: "bookmark.fill")
                .font(.system(size: 11))
                .foregroundStyle(marker.color.swiftUI)
                .shadow(color: .black.opacity(0.35), radius: 1)
                .help(marker.title.isEmpty ? String(localized: "Marker") : marker.title)
                .offset(x: x(marker.time) - 5, y: 2)
                .allowsHitTesting(false)
        }
    }

    /// The song's beats as ticks, bars taller (when they're far enough apart to see).
    private func beatGrid(_ song: ProjectMusic, left: CGFloat, x: @escaping (Double) -> CGFloat) -> some View {
        let map = model.beatMaps[song.path]
        return Canvas { context, size in
            guard let map, map.beats.count > 1 else { return }
            let spacing = x(map.beats[1]) - x(map.beats[0])
            let bars = Set(map.bars.map { ($0.start * 100).rounded() })
            for beat in map.beats where beat >= song.start && beat <= song.end {
                let isBar = bars.contains((beat * 100).rounded())
                // Beats only when there's room; bars from a little further out.
                guard spacing >= 5 || (isBar && spacing * 4 >= 6) else { continue }
                let px = x(song.at + beat - song.start) - left
                guard px >= 0, px <= size.width else { continue }
                let height = isBar ? size.height : size.height * 0.35
                context.fill(Path(CGRect(x: px - 0.5, y: size.height - height, width: 1, height: height)),
                             with: .color(.white.opacity(isBar ? 0.55 : 0.3)))
            }
        }
        .allowsHitTesting(false)
    }

    /// Where the song is lowered under speech: a darker band from the top, as deep as the drop.
    @ViewBuilder private func duckBand(_ song: ProjectMusic, left: CGFloat, x: @escaping (Double) -> CGFloat) -> some View {
        if let duck = song.duck {
            let env = Ducking.envelope(model.speech, amountDB: duck)
            Canvas { context, size in
                guard env.count > 1 else { return }
                var path = Path()
                for index in 1..<env.count where env[index - 1].gain < 1 || env[index].gain < 1 {
                    let a = env[index - 1], b = env[index]
                    let x0 = x(a.time) - left, x1 = x(b.time) - left
                    guard x1 >= 0, x0 <= size.width else { continue }
                    path.move(to: CGPoint(x: x0, y: 0))
                    path.addLine(to: CGPoint(x: x1, y: 0))
                    path.addLine(to: CGPoint(x: x1, y: size.height * (1 - b.gain)))
                    path.addLine(to: CGPoint(x: x0, y: size.height * (1 - a.gain)))
                    path.closeSubpath()
                }
                context.fill(path, with: .color(.black.opacity(0.35)))
            }
            .allowsHitTesting(false)
        }
    }

    private func lane(top: CGFloat, height: CGFloat, width: CGFloat, label: String? = nil) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.primary.opacity(0.04))
            .overlay(alignment: .leading) {
                if let label { Image(systemName: label).font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 4) }
            }
            .frame(width: width, height: height)
            .offset(y: top)
            .allowsHitTesting(false)
    }

    private func lengthBlock(_ text: String, symbol: String, tint: Color, selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(tint.opacity(selected ? 1 : 0.8))
            .overlay(alignment: .leading) {
                Label(text, systemImage: symbol).labelStyle(.titleAndIcon)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.white).lineLimit(1).padding(.horizontal, 6)
            }
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(selected ? 0.9 : 0.15)) }
            .clipped()
            .allowsHitTesting(false)
    }

    private func rulerView(width: CGFloat) -> some View {
        let seconds = max(model.duration, 0.001)
        let perSecond = width / seconds
        // Down to single frames when zoomed in far.
        let frame = 1 / max(model.frameRate, 1)
        let steps: [Double] = [frame, frame * 2, frame * 5, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800]
        let step = steps.first { $0 * perSecond >= 80 } ?? 3600
        return Canvas { context, size in
            var t = 0.0
            while t <= seconds {
                let x = CGFloat(t) * perSecond
                context.fill(Path(CGRect(x: x, y: size.height - 6, width: 1, height: 6)), with: .color(.secondary.opacity(0.6)))
                context.draw(Text(step < 0.5 ? model.timecode(t) : Format.duration(t)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary),
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
            guard let before, let index = before.clips.firstIndex(where: { $0.id == id }) else { return }
            let clip = before.clips[index]
            let delta = Double(value.translation.width / width) * seconds
            // The cut snaps (to edges, the playhead, the music's beats).
            let at = before.clips[..<index].reduce(0) { $0 + $1.length }
            let cut = model.snappedToBeat(at + clip.length + delta, tolerance: tolerance)
            model.trim(id, end: clip.start + (cut - at) * clip.speed, record: false)
        case .roll(let index):
            guard let before, index + 1 < before.clips.count else { return }
            let delta = Double(value.translation.width / width) * seconds
            let at = before.clips[...index].reduce(0) { $0 + $1.length }
            let cut = model.snappedToBeat(at + delta, tolerance: tolerance)
            model.roll(cutAfter: index, from: before, by: cut - at, record: false)
            // The viewer shows the first frame after the cut.
            let offsets = model.offsets
            if index + 1 < offsets.count { model.seek(to: offsets[index + 1]) }
        case .slip(let id):
            guard let before, let index = before.clips.firstIndex(where: { $0.id == id }) else { return }
            // Dragged right, the clip shows an earlier part of its file (as in other editors).
            model.slip(id, from: before, by: -Double(value.translation.width / width) * seconds, record: false)
            let offsets = model.offsets
            if index < offsets.count { model.seek(to: offsets[index]) }
        case .music(let id, let offset):
            let at = max(model.snapped(t(value.location.x) - offset, tolerance: tolerance), 0)
            model.setMusic(id, record: false) { $0.at = at }
        case .musicStart(let id):
            guard let song = before?.music.first(where: { $0.id == id }) else { return }
            let delta = Double(value.translation.width / width) * seconds
            // Not before the start of the song, nor before the start of the edit.
            let moved = min(max(delta, -song.start, -song.at), song.length - 0.5)
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
        case .look(let id, let offset):
            guard let look = before?.adjustments?.first(where: { $0.id == id }) else { return }
            let length = look.end - look.start
            let start = min(max(model.snapped(t(value.location.x) - offset, tolerance: tolerance), 0), max(seconds - length, 0))
            model.setAdjustment(id, record: false) { $0.start = start; $0.end = start + length }
        case .lookStart(let id):
            guard let look = before?.adjustments?.first(where: { $0.id == id }) else { return }
            let start = min(model.snapped(t(value.location.x), tolerance: tolerance), look.end - 0.3)
            model.setAdjustment(id, record: false) { $0.start = max(start, 0) }
        case .lookEnd(let id):
            guard let look = before?.adjustments?.first(where: { $0.id == id }) else { return }
            let end = max(model.snapped(t(value.location.x), tolerance: tolerance), look.start + 0.3)
            // Never before its start (a look left past the end of a shortened edit).
            model.setAdjustment(id, record: false) { $0.end = min(end, max(seconds, look.start + 0.3)) }
        case .item(let id, let offset):
            let at = max(model.snapped(t(value.location.x) - offset, tolerance: tolerance), 0)
            model.setItem(id, record: false) { $0.at = at; $0.link = nil }
        case .itemStart(let id):
            guard let item = before.flatMap({ Self.item(id, in: $0) }) else { return }
            let delta = Double(value.translation.width / width) * seconds
            let moved = min(max(delta, -item.start / item.speed, -(item.at ?? 0)), item.length - 0.2)
            model.setItem(id, record: false) { $0.at = (item.at ?? 0) + moved; $0.start = item.start + moved * item.speed }
        case .itemEnd(let id):
            guard let item = before.flatMap({ Self.item(id, in: $0) }) else { return }
            let delta = Double(value.translation.width / width) * seconds
            let end = model.snapped((item.at ?? 0) + item.length + delta, tolerance: tolerance)
            model.setItem(id, record: false) { $0.end = max(item.start + (end - (item.at ?? 0)) * item.speed, item.start + 0.2) }
        default:
            break
        }
    }

    private static func item(_ id: UUID, in project: Project) -> ProjectClip? {
        (project.tracks ?? []).flatMap(\.items).first { $0.id == id }
    }

    private func ended(_ value: DragGesture.Value, t: (CGFloat) -> Double) {
        defer {
            // Clicked, or dragged back where it was: no undo step waiting.
            model.endDrag()
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
        case .item(let id, _) where abs(value.translation.width) <= 3:
            // A click: chosen (with ⇧ or ⌘, one more).
            if flags.contains(.shift) || flags.contains(.command) {
                if model.selected.contains(id) { model.selected.remove(id) } else { model.selected.insert(id) }
            } else {
                model.selected = [id]
            }
            model.selectedTitle = nil
            if let before, before.tracks != model.project.tracks { model.commit(from: before) }
        case .clipStart, .clipEnd, .roll, .slip, .music, .musicStart, .musicEnd, .title, .titleStart, .titleEnd, .item, .itemStart, .itemEnd,
             .look, .lookStart, .lookEnd:
            if let before, before.clips != model.project.clips || before.music != model.project.music || before.titles != model.project.titles
                || before.tracks != model.project.tracks || before.adjustments != model.project.adjustments {
                model.commit(from: before)
            }
        default:
            break
        }
    }

    /// The cut (by the index of the clip before it) a drag here would roll: with the Trim tool,
    /// or the Selection tool and ⌥, close to where two clips meet.
    private func rollCut(_ index: Int, at pointX: CGFloat, left: CGFloat, right: CGFloat, edge: CGFloat) -> Int? {
        guard model.tool == .trim || (model.tool == .select && NSEvent.modifierFlags.contains(.option)) else { return nil }
        if index > 0, abs(pointX - left) <= edge { return index - 1 }
        if index + 1 < model.project.clips.count, abs(pointX - right) <= edge { return index }
        return nil
    }

    /// The pointer shows the trim a drag would make.
    private func hovered(_ phase: HoverPhase, x: (Double) -> CGFloat) {
        guard case .active(let point) = phase, model.tool == .trim || (model.tool == .select && NSEvent.modifierFlags.contains(.option)),
              point.y >= clipsTop, point.y <= clipsTop + clipsHeight else {
            if trimCursor { NSCursor.pop(); trimCursor = false }
            return
        }
        let offsets = model.offsets
        let atCut = offsets.dropFirst().contains { abs(x($0) - point.x) <= 6 }
        let cursor: NSCursor = atCut ? .resizeLeftRight : (model.tool == .trim ? .openHand : .arrow)
        if trimCursor { NSCursor.pop() }
        cursor.push()
        trimCursor = true
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
                if let cut = rollCut(index, at: point.x, left: left, right: right, edge: edge) { return .roll(cut) }
                if model.tool == .trim, point.x >= left, point.x <= right { return .slip(clip.id) }
                if model.tool == .select {
                    if abs(point.x - left) <= edge, right - left > edge * 3 { return .clipStart(clip.id) }
                    if abs(point.x - right) <= edge, right - left > edge * 3 { return .clipEnd(clip.id) }
                }
                if point.x >= left, point.x <= right { return .clip(clip.id, offset: t(point.x) - offsets[index]) }
            }
        }
        for track in model.project.tracks ?? [] where !track.locked {
            guard let (top, laneHeight) = laneTop(track), point.y >= top, point.y <= top + laneHeight else { continue }
            for item in track.items {
                let left = x(item.at ?? 0), right = x((item.at ?? 0) + item.length)
                if model.tool == .select, right - left > edge * 3 {
                    if abs(point.x - left) <= edge { return .itemStart(item.id) }
                    if abs(point.x - right) <= edge { return .itemEnd(item.id) }
                }
                if point.x >= left, point.x <= right { return .item(item.id, offset: t(point.x) - (item.at ?? 0)) }
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
        if hasLooks, point.y >= looksTop, point.y <= looksTop + looksHeight {
            for look in (model.project.adjustments ?? []).reversed() {
                let left = x(look.start), right = x(look.end)
                if abs(point.x - left) <= edge { model.selected = [look.id]; return .lookStart(look.id) }
                if abs(point.x - right) <= edge { model.selected = [look.id]; return .lookEnd(look.id) }
                if point.x > left, point.x < right { model.selected = [look.id]; return .look(look.id, offset: t(point.x) - look.start) }
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
    /// Its file isn't there.
    var offline = false
    /// Its sound, across the clip.
    var peaks: ArraySlice<Float> = []

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.6)
                if offline {
                    Color.red.opacity(0.45)
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !thumbnails.isEmpty {
                    HStack(spacing: 0) {
                        let count = max(Int(geometry.size.width / 70), 1)
                        ForEach(0..<count, id: \.self) { slot in
                            Image(nsImage: thumbnails[min(slot * thumbnails.count / count, thumbnails.count - 1)])
                                .resizable().scaledToFill()
                                .frame(width: geometry.size.width / CGFloat(count), height: geometry.size.height)
                                .clipped()
                        }
                    }
                } else if peaks.isEmpty {
                    Image(systemName: "waveform").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // Its sound: along the bottom under pictures, the whole block for sound only.
                if !offline, !peaks.isEmpty {
                    let strip = thumbnails.isEmpty ? geometry.size.height - 16 : min(18, geometry.size.height * 0.28)
                    Canvas { context, size in
                        let columns = max(Int(size.width / 2), 1)
                        let values = Array(peaks)
                        var path = Path()
                        for column in 0..<columns {
                            let a = column * values.count / columns, b = max(a + 1, (column + 1) * values.count / columns)
                            let peak = CGFloat(values[a..<min(b, values.count)].max() ?? 0)
                            let h = max(peak * size.height, 0.5)
                            path.addRect(CGRect(x: CGFloat(column) * 2, y: (size.height - h) / 2, width: 1.2, height: h))
                        }
                        context.fill(path, with: .color(Color.cyan.opacity(0.85)))
                    }
                    .frame(height: strip)
                    .background(thumbnails.isEmpty ? Color.clear : Color.black.opacity(0.55))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
                LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .center)
                VStack(alignment: .leading, spacing: 1) {
                    if let role = clip.role {
                        Capsule().fill(role.color).frame(height: 3)
                    }
                    Text(clip.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
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
