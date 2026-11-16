import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// An asset under review: the player (or picture, or document page) on the left with its timeline of comment markers,
/// the comments on the right (320 pt), as in the web viewer. The owner comments, replies, draws, pins, completes and sets
/// the status; Compare shows another version or asset side by side or with a wipe.
struct DeliverAssetView: View {
    @Bindable var nav: StudioNavigator
    let asset: UUID
    @State var version: UUID?
    var comment: UUID?
    @State private var store = DeliverStore.shared
    @State private var server = DeliverServer.shared
    @State private var playback = DeliverPlayback()
    @State private var other = DeliverPlayback()
    /// Compare: another version of this asset, or another asset's current version.
    @State private var comparing: (asset: UUID, version: UUID)?
    @State private var wipe = false
    @State private var wipeAt = 0.5
    @State private var selected: UUID?
    @State private var drawing = Deliver.Drawing(strokes: [])
    @State private var drawingOn = false
    @State private var markIn: Int?
    @State private var anchor: [Double]?
    @State private var pinning = false
    @State private var page = 1
    @State private var allDrawings = false
    @State private var sharing = false
    @State private var publishing = false
    @State private var markers = false
    /// "Upload to <NAS>…": the server whose uploads folder is being chosen.
    @State private var uploadingTo: Deliver.Host?

    private var found: Deliver.Asset? { store.find(asset)?.asset }
    private var current: Deliver.Version? { found.flatMap { found in found.versions.first { $0.id == version } ?? found.current } }
    private var second: (asset: Deliver.Asset, version: Deliver.Version)? {
        guard let comparing, let other = store.find(comparing.asset)?.asset, let v = other.versions.first(where: { $0.id == comparing.version }) else { return nil }
        return (other, v)
    }

    var body: some View {
        if let found, let current {
            VStack(spacing: 0) {
                header(found, current)
                HStack(spacing: 0) {
                    VStack(spacing: 10) {
                        if let second, wipe {
                            ZStack {
                                picture(second.asset, second.version, other, drawable: false)
                                picture(found, current, playback, drawable: true)
                                    .mask(alignment: .leading) { GeometryReader { g in Rectangle().frame(width: g.size.width * wipeAt) } }
                            }
                            Slider(value: $wipeAt, in: 0...1).controlSize(.small)
                        } else {
                            HStack(spacing: 8) {
                                picture(found, current, playback, drawable: true)
                                if let second { picture(second.asset, second.version, other, drawable: false) }
                            }
                        }
                        if found.kind == .video || found.kind == .audio { DeliverTimeline(playback: playback, version: current, comments: shown(current), selected: $selected) }
                        if found.kind == .document, let pages = current.pages, pages > 1 { pageBar(pages) }
                    }
                    .padding(16)
                    Rectangle().fill(Design.Studio.line).frame(width: 1)
                    DeliverCommentsPanel(asset: found, version: current, playback: playback, selected: $selected, drawing: $drawing, drawingOn: $drawingOn, markIn: $markIn,
                                         anchor: $anchor, pinning: $pinning, page: found.kind == .document ? page : nil)
                        .frame(width: 320)
                }
            }
            .onAppear {
                selected = comment
                if let comment, let at = store.comment(comment) { version = at.version; if let p = at.page { page = p } }
                if let current = self.current { playback.load(found, current) }
                if let comment { store.markRead(comment) }
            }
            .onChange(of: version) { if let current = self.current { playback.load(found, current) } }
            .onChange(of: comparing?.version) {
                if let second { other.load(second.asset, second.version); playback.follower = other } else { playback.follower = nil }
            }
            .onChange(of: selected) {
                guard let selected, let at = store.comment(selected) else { return }
                if let frame = at.frame { playback.seek(frame: frame); playback.player.pause() }
                if let p = at.page { page = p }
            }
            .sheet(isPresented: $sharing) { DeliverShareSheet(scope: .asset(asset, project: store.find(asset)?.project ?? UUID())) }
            .sheet(isPresented: $publishing) { DeliverPublishSheet(scope: .asset(asset, project: store.find(asset)?.project ?? UUID())) }
            .sheet(isPresented: $markers) { DeliverResolveMarkersSheet(asset: found, version: current) }
            .sheet(item: $uploadingTo) { host in
                DeliverUploadPicker(host: host, project: store.find(asset)?.project, done: { folder in
                    uploadingTo = nil
                    if let folder { upload(current, of: found, to: host, folder: folder) }
                }, back: { uploadingTo = nil })
                .padding(Design.Spacing.sheet).frame(minWidth: 900, idealWidth: 1060, maxWidth: .infinity, minHeight: 600, idealHeight: 720, maxHeight: .infinity).background(Design.Studio.panel)
            }
            .onDisappear { playback.player.pause(); other.player.pause() }
        }
    }

    private func shown(_ version: Deliver.Version) -> [Deliver.Comment] {
        _ = store.commentsChanged
        return store.comments(asset, version: version.id)
    }

    private func pageBar(_ pages: Int) -> some View {
        HStack(spacing: 14) {
            Button { page = max(1, page - 1) } label: { Image(systemName: "chevron.left") }.disabled(page <= 1).help("Previous page")
            Text("Page \(page) of \(pages)").font(Design.Studio.body.monospacedDigit())
            Button { page = min(pages, page + 1) } label: { Image(systemName: "chevron.right") }.disabled(page >= pages).help("Next page")
        }
        .buttonStyle(.plain).foregroundStyle(Design.Studio.text)
    }

    private func header(_ found: Deliver.Asset, _ current: Deliver.Version) -> some View {
        HStack(spacing: 10) {
            if let project = store.find(asset)?.project {
                Button { nav.deliver = .project(project, folder: found.folder) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(Design.Studio.textQuiet).help("Back to the project")
            }
            Text(verbatim: found.name).font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text).lineLimit(1)
            if found.versions.count > 1 {
                Menu {
                    ForEach(found.versions.reversed()) { item in
                        Button { version = item.id } label: { Text(verbatim: "v\(item.number) · \(item.added.formatted(date: .abbreviated, time: .omitted))") }
                    }
                } label: { StudioMenuLabel(title: "v\(current.number)") }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            compareMenu(found, current)
            Menu {
                ForEach(Deliver.Status.allCases, id: \.self) { status in
                    Button(DeliverStatusPill.title(status)) { store.setStatus(status, of: asset, by: DeliverSettings.author) }
                }
            } label: {
                if found.status == .none { StudioMenuLabel(title: String(localized: "Status")) } else { DeliverStatusPill(status: found.status) }
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Spacer()
            // Who's watching this asset right now.
            HStack(spacing: -6) {
                ForEach(Array(server.viewers(asset: asset).prefix(5).enumerated()), id: \.offset) { _, name in
                    Text(verbatim: String(name.prefix(1)).uppercased()).font(.system(size: 10, weight: .medium)).foregroundStyle(.white)
                        .frame(width: 22, height: 22).background(Design.Brand.deep, in: .circle).overlay(Circle().stroke(Design.Studio.panel, lineWidth: 2))
                        .help(Text(verbatim: name))
                }
            }
            if found.kind != .audio && found.kind != .other {
                Button { allDrawings.toggle() } label: { Image(systemName: allDrawings ? "scribble.variable" : "scribble") }
                    .buttonStyle(StudioFlatButtonStyle()).help("Show every drawing on this frame")
            }
            Menu {
                if found.kind == .video { Button("Send to Resolve Timeline…") { markers = true } }
                if let approval = latestApproval(found) { Button("Approval Proof…") { saveProof(approval, found) } }
                ForEach(ReviewPublish.shared.hosts.filter { $0.kind == .nas && $0.role != "backup" }) { host in
                    Button("Upload to \(host.name)…") { uploadingTo = host }
                }
            } label: { Image(systemName: "ellipsis.circle").foregroundStyle(Design.Studio.textQuiet) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Button("Publish…") { publishing = true }.buttonStyle(StudioFlatButtonStyle())
            Button("Share") { sharing = true }.buttonStyle(StudioFlatButtonStyle(prominent: true))
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private func latestApproval(_ found: Deliver.Asset) -> Deliver.Approval? {
        store.find(found.id).flatMap { store.approvals($0.project).last { $0.asset == found.id } }
    }

    /// "Approval proof…": the PDF saved where the owner says (made now, or a moment later once the hash is there).
    private func saveProof(_ approval: Deliver.Approval, _ found: Deliver.Asset) {
        guard let file = try? DeliverProof.file(for: approval, store: store, servedBy: Host.current().localizedName ?? "Mac") else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = DeliverProof.fileName(approval, asset: found)
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.copyItem(at: file, to: url)
    }

    /// "Upload to <NAS>…": into the folder chosen in its uploads root (remembered for the project), then the version is
    /// known by its NAS path and the NAS makes its copies.
    private func upload(_ version: Deliver.Version, of found: Deliver.Asset, to host: Deliver.Host, folder: String) {
        if let project = store.find(found.id)?.project { DeliverUploadDestination.remember(folder, host: host.id, project: project) }
        Task { await DeliverUploads.shared.uploadVersion(version, of: found.id, folder: folder, host: host) }
    }

    /// Off, another version, or another asset in the project; side by side or a wipe.
    private func compareMenu(_ found: Deliver.Asset, _ current: Deliver.Version) -> some View {
        let project = store.find(asset)?.project
        let others = project.map { store.content($0).assets.filter { $0.id != found.id && $0.kind == found.kind } } ?? []
        return Menu {
            Button("Off") { comparing = nil }
            ForEach(found.versions.reversed().filter { $0.id != current.id }) { item in
                Button { comparing = (found.id, item.id) } label: { Text(verbatim: "v\(item.number)") }
            }
            if !others.isEmpty {
                Menu("Another Asset") {
                    ForEach(others.prefix(50)) { item in Button { comparing = (item.id, item.current.id) } label: { Text(verbatim: item.name) } }
                }
            }
            Divider()
            Toggle("Wipe", isOn: $wipe)
        } label: {
            let title: String = second.map { pair in pair.asset.id == found.id ? String(localized: "Compare v\(pair.version.number)") : String(localized: "Compare \(pair.asset.name)") }
                ?? String(localized: "Compare")
            StudioMenuLabel(title: title)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .opacity(found.versions.count > 1 || !others.isEmpty ? 1 : 0)
    }

    @ViewBuilder
    private func picture(_ found: Deliver.Asset, _ version: Deliver.Version, _ playback: DeliverPlayback, drawable: Bool) -> some View {
        GeometryReader { geometry in
            let aspect = Double(max(version.probe?.width ?? 16, 1)) / Double(max(version.probe?.height ?? 9, 1))
            let fit = min(geometry.size.width, geometry.size.height * aspect)
            let box = CGSize(width: fit, height: fit / aspect)
            ZStack {
                Color.black
                switch found.kind {
                case .image:
                    if let image = NSImage(contentsOf: store.copies(version.id).appendingPathComponent("image.jpg")) ?? store.original(version).flatMap(NSImage.init(contentsOf:)) {
                        Image(nsImage: image).resizable().scaledToFit()
                    }
                case .document:
                    if let image = NSImage(contentsOf: store.copies(version.id).appendingPathComponent("pages/\(page).jpg")) {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        StudioEmptyState(symbol: "doc.richtext", title: "Making the pages")
                    }
                case .video, .audio:
                    DeliverPlayerSurface(player: playback.player)
                case .other:
                    StudioEmptyState(symbol: "doc", title: "Download only")
                }
                if drawable {
                    DeliverDrawingLayer(drawing: $drawing, editing: drawingOn, shown: shownDrawing(found, version))
                        .frame(width: box.width, height: box.height)
                    DeliverPinLayer(pins: pins(found, version), pinning: pinning) { anchor = $0; pinning = false }
                        .frame(width: box.width, height: box.height)
                }
            }
        }
        .clipShape(.rect(cornerRadius: 8, style: .continuous))
    }

    /// The selected comment's drawing, or with "every drawing" on, all of those on this frame (or page).
    private func shownDrawing(_ found: Deliver.Asset, _ version: Deliver.Version) -> Deliver.Drawing? {
        if !allDrawings { return selected.flatMap { store.comment($0)?.drawing } }
        let here = shown(version).filter { comment in
            switch found.kind {
            case .document: (comment.page ?? 1) == page
            case .image: true
            default: comment.frame.map { $0 <= playback.frame && playback.frame <= (comment.endFrame ?? $0) } ?? false
            }
        }
        return Deliver.Drawing(strokes: here.flatMap { $0.drawing?.strokes ?? [] })
    }

    /// The pin being placed, else the selected comment's.
    private func pins(_ found: Deliver.Asset, _ version: Deliver.Version) -> [[Double]] {
        if let anchor { return [anchor] }
        return selected.flatMap { store.comment($0)?.anchor }.map { [$0] } ?? []
    }

    static func markers(_ comments: [Deliver.Comment], probe: Deliver.Probe?, title: String) -> String {
        let num = Double(probe?.fpsNum ?? 25), den = Double(probe?.fpsDen ?? 1)
        let start = Double(DeliverTimecode.frames(probe?.startTimecode ?? "00:00:00:00", fpsNum: Int(num), fpsDen: Int(den), drop: probe?.dropFrame ?? false))
            / DeliverTimecode.rate(Int(num), Int(den)).asDouble
        let review = comments.map { comment in
            ReviewComment(time: Double(comment.frame ?? 0) * den / num, text: comment.text, author: comment.author, resolved: comment.completed,
                          replies: comment.replies.map { ReviewComment.Reply(text: $0.text, author: $0.author) })
        }
        return RemoteReview.markerEDL(review, title: title, fps: num / den, start: start)
    }
}

private extension Int { var asDouble: Double { Double(self) } }

/// An AVPlayer on the original (it's on this Mac), or on the 1080 review copy stitched from init + segments
/// when AVFoundation can't open the original (raw, some MXF). The frame shown, by the probe's frame rate.
@MainActor
@Observable
final class DeliverPlayback {
    let player = AVPlayer()
    private(set) var frame = 0
    private(set) var frames = 1
    private(set) var playing = false
    private(set) var fpsNum = 25
    private(set) var fpsDen = 1
    /// Compare: the second player follows this one's playhead.
    @ObservationIgnored weak var follower: DeliverPlayback?
    @ObservationIgnored private var stream: RemoteStream?
    @ObservationIgnored private var observer: Any?

    func load(_ asset: Deliver.Asset, _ version: Deliver.Version) {
        let store = DeliverStore.shared
        fpsNum = version.probe?.fpsNum ?? 25
        fpsDen = version.probe?.fpsDen ?? 1
        frames = max(version.probe?.frames ?? 1, 1)
        frame = 0
        player.pause()
        if observer == nil {
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
                MainActor.assumeIsolated { self?.ticked(time.seconds) }
            }
        }
        Task {
            var item: AVPlayerItem?
            if let original = store.original(version) {
                let asset = AVURLAsset(url: original)
                if (try? await asset.load(.isPlayable)) == true { item = AVPlayerItem(asset: asset) }
            }
            if item == nil, let stitched = Self.stitched(store.copies(version.id).appendingPathComponent(asset.kind == .audio ? "a" : "1080")) {
                stream = stitched
                item = AVPlayerItem(asset: stitched.asset())
            }
            player.replaceCurrentItem(with: item)
        }
    }

    /// The copy's init piece then every segment, as one fragmented MP4 (read through a resource loader, as RemoteStream does).
    nonisolated static func stitched(_ folder: URL) -> RemoteStream? {
        guard let index = DeliverCopies.index(folder) else { return nil }
        let pieces = [(index.`init`.file, index.`init`.offset, index.`init`.length)] + index.segments.map { ($0.file, $0.offset, $0.length) }
        let total = pieces.reduce(Int64(0)) { $0 + $1.2 }
        return RemoteStream(contentType: UTType.mpeg4Movie.identifier) { offset, length in
            var data = Data(), at = offset, start = Int64(0)
            for piece in pieces where data.count < length {
                let end = start + piece.2
                if at < end {
                    let handle = try FileHandle(forReadingFrom: folder.appendingPathComponent(piece.0))
                    defer { try? handle.close() }
                    try handle.seek(toOffset: UInt64(piece.1 + at - start))
                    let chunk = try handle.read(upToCount: min(length - data.count, Int(end - at))) ?? Data()
                    data += chunk
                    at += Int64(chunk.count)
                }
                start = end
            }
            return (data, total)
        }
    }

    private func ticked(_ seconds: Double) {
        guard seconds.isFinite else { return }
        frame = min(Int((seconds * Double(fpsNum) / Double(fpsDen) + 1e-4).rounded(.down)), frames - 1)
        playing = player.rate != 0
        if let follower, abs(follower.player.currentTime().seconds - seconds) > 0.08 {
            follower.player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// Into the frame (its middle), so the same frame shows here and in the browser.
    func seek(frame target: Int) {
        let target = min(max(target, 0), frames - 1)
        frame = target
        let time = CMTime(seconds: (Double(target) + 0.5) * Double(fpsDen) / Double(fpsNum), preferredTimescale: 600_000)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        follower?.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func toggle() {
        if player.rate == 0 { player.play(); follower?.player.play() } else { player.pause(); follower?.player.pause() }
        playing = player.rate != 0
    }
}

/// The player's picture without AVKit's controls (Deliver has its own under it).
struct DeliverPlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.allowsPictureInPicturePlayback = false
        if #available(macOS 13, *) { view.allowsVideoFrameAnalysis = false }
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// Under the player: play, a frame back and on, the timecode (or frames), and the bar with a dot per
/// comment (a bar for a range); clicking the bar seeks, clicking a marker selects its comment.
struct DeliverTimeline: View {
    let playback: DeliverPlayback
    let version: Deliver.Version
    let comments: [Deliver.Comment]
    @Binding var selected: UUID?
    @AppStorage("deliverShowFrames") private var showFrames = false

    var body: some View {
        let probe = version.probe
        let frames = max(probe?.frames ?? 1, 1)
        VStack(spacing: 8) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Design.Studio.line).frame(height: 4)
                    Capsule().fill(Design.Brand.pink).frame(width: width * Double(playback.frame) / Double(frames), height: 4)
                    ForEach(comments.filter { $0.frame != nil }) { comment in
                        let frame = comment.frame ?? 0
                        let x = width * Double(frame) / Double(frames)
                        let w = comment.endFrame.map { max(width * Double($0 - frame + 1) / Double(frames), 8) } ?? 8
                        Capsule().fill(comment.completed ? Design.Studio.textFaint : comment.authorToken == nil ? Design.Studio.text : Design.Studio.warn)
                            .frame(width: w, height: 8)
                            .overlay { if selected == comment.id { Capsule().stroke(Design.Brand.pink, lineWidth: 2) } }
                            .offset(x: x - 4)
                            .onTapGesture { selected = comment.id }
                    }
                }
                .frame(height: 16)
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    playback.seek(frame: Int(Double(frames) * min(max(value.location.x / max(width, 1), 0), 1)))
                })
            }
            .frame(height: 16)
            HStack(spacing: 14) {
                Button { playback.seek(frame: playback.frame - 1) } label: { Image(systemName: "backward.frame") }.help("One frame back")
                Button { playback.toggle() } label: { Image(systemName: playback.playing ? "pause.fill" : "play.fill") }.help("Play")
                Button { playback.seek(frame: playback.frame + 1) } label: { Image(systemName: "forward.frame") }.help("One frame on")
                Spacer()
                Button { showFrames.toggle() } label: {
                    Text(verbatim: showFrames ? "\(playback.frame)" : DeliverTimecode.string(frame: playback.frame, start: probe?.startTimecode ?? "00:00:00:00",
                                                                                           fpsNum: probe?.fpsNum ?? 25, fpsDen: probe?.fpsDen ?? 1, drop: probe?.dropFrame ?? false))
                        .font(Design.Studio.body.monospacedDigit())
                }
                .help("Timecode or frames")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Design.Studio.text)
        }
    }
}

/// Drawings on the picture: the selected comment's, or the one being made (pen, arrow, rectangle, ellipse).
struct DeliverDrawingLayer: View {
    @Binding var drawing: Deliver.Drawing
    var editing: Bool
    var shown: Deliver.Drawing?
    @AppStorage("deliverDrawTool") private var toolName = Deliver.Drawing.Tool.pen.rawValue
    @AppStorage("deliverDrawColour") private var colour = Deliver.Drawing.palette[0]

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                for stroke in (editing ? drawing : shown ?? .init(strokes: [])).strokes { Self.draw(stroke, in: &context, size: size) }
            }
            .contentShape(.rect)
            .gesture(editing ? DragGesture(minimumDistance: 0).onChanged { value in add(value, geometry.size) } : nil)
            .allowsHitTesting(editing)
        }
    }

    private func add(_ value: DragGesture.Value, _ size: CGSize) {
        let point = [Double(min(max(value.location.x / size.width, 0), 1)), Double(min(max(value.location.y / size.height, 0), 1))]
        let tool = Deliver.Drawing.Tool(rawValue: toolName) ?? .pen
        let starting = value.translation == .zero
        if starting {
            guard drawing.strokes.count < 64 else { return }
            drawing.strokes.append(.init(tool: tool, colour: colour, width: 0.004, points: [point, point]))
        } else if !drawing.strokes.isEmpty {
            let last = drawing.strokes.count - 1
            if tool == .pen {
                if drawing.strokes.reduce(0, { $0 + $1.points.count }) < 2000 { drawing.strokes[last].points.append(point) }
            } else {
                drawing.strokes[last].points[1] = point
            }
        }
    }

    static func draw(_ stroke: Deliver.Drawing.Stroke, in context: inout GraphicsContext, size: CGSize) {
        let points = stroke.points.map { CGPoint(x: $0[0] * size.width, y: $0[1] * size.height) }
        guard let first = points.first else { return }
        let colour = Color(hex: stroke.colour)
        let style = StrokeStyle(lineWidth: max(stroke.width * size.width, 1.5), lineCap: .round, lineJoin: .round)
        var path = Path()
        let last = points.last ?? first
        switch stroke.tool {
        case .pen: path.addLines(points)
        case .line: path.addLines([first, last])
        case .rect: path.addRect(CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y)))
        case .ellipse: path.addEllipse(in: CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y)))
        case .arrow:
            path.move(to: first)
            path.addLine(to: last)
            let angle = atan2(last.y - first.y, last.x - first.x), head = max(style.lineWidth * 4, 10)
            for turn in [Double.pi * 0.8, -Double.pi * 0.8] {
                path.move(to: last)
                path.addLine(to: CGPoint(x: last.x + head * cos(angle + turn), y: last.y + head * sin(angle + turn)))
            }
        }
        context.stroke(path, with: .color(colour), style: style)
    }
}

/// Pins on the picture; while pinning, a click places one (0…1 of the picture).
struct DeliverPinLayer: View {
    let pins: [[Double]]
    let pinning: Bool
    let placed: ([Double]) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(.rect)
                    .onTapGesture(coordinateSpace: .local) { point in
                        placed([min(max(point.x / max(geometry.size.width, 1), 0), 1), min(max(point.y / max(geometry.size.height, 1), 0), 1)])
                    }
                    .allowsHitTesting(pinning)
                ForEach(pins.indices, id: \.self) { index in
                    let pin = pins[index]
                    Image(systemName: "mappin.circle.fill").font(.system(size: 22)).foregroundStyle(.white, Design.Studio.bad)
                        .position(x: pin[0] * geometry.size.width, y: pin[1] * geometry.size.height - 10)
                        .allowsHitTesting(false)
                }
            }
        }
        .onHover { inside in if pinning { (inside ? NSCursor.crosshair : NSCursor.arrow).set() } }
    }
}

extension Color {
    /// "#E0605E".
    init(hex: String) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0xEDEBE6
        self = Design.rgb(value)
    }
}
