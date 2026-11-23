import AVKit
import Network
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
    @State private var publishing = false
    @State private var markers = false
    @State private var pulling = false
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
                Task { await DeliverSync.shared.refresh() }
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
            .sheet(isPresented: $publishing) { DeliverPublishSheet(scope: .asset(asset, project: store.find(asset)?.project ?? UUID())) }
            .sheet(isPresented: $markers) { DeliverResolveMarkersSheet(asset: found, version: current) }
            .sheet(isPresented: $pulling) { DeliverResolvePullSheet(asset: found, version: current) }
            .sheet(item: $uploadingTo) { host in
                DeliverUploadPicker(host: host, project: store.find(asset)?.project, done: { folder in
                    uploadingTo = nil
                    if let folder { upload(current, of: found, to: host, folder: folder) }
                }, back: { uploadingTo = nil }, later: { folder in
                    // The server away: "Waiting for NAS" (or its backup, §13.25), then this version points at the file there.
                    uploadingTo = nil
                    guard let file = store.original(current), let project = store.find(found.id)?.project else { return }
                    let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                    DeliverShareQueue.shared.add(.init(file: file.path, size: size, project: project, asset: found.id,
                                                       upload: .init(host: host.id, folder: folder), version: current.id))
                })
                .padding(Design.Spacing.sheet).background(Design.Studio.panel)
            }
            .onDisappear { playback.player.pause(); other.player.pause(); playback.stop(); other.stop() }
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
                // Project / asset, as a path.
                Button { nav.deliver = .project(project, folder: found.folder) } label: { Text(verbatim: store.project(project)?.name ?? "") }
                    .buttonStyle(.plain).font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                Text(verbatim: "/").font(Design.Studio.body).foregroundStyle(Design.Studio.textFaint)
            }
            Text(verbatim: found.name).font(Design.Studio.body.weight(.medium)).foregroundStyle(Design.Studio.text).lineLimit(1)
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
                ForEach(store.statusList, id: \.self) { status in
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
                if found.kind == .video {
                    Button("Send to Resolve Timeline…") { markers = true }
                    Button("Update from Resolve Timeline…") { pulling = true }
                    if current.hostOriginal == nil, FileManager.default.fileExists(atPath: current.path) {
                        Button("Check Delivery") { DeliveryCheckView.check(URL(fileURLWithPath: current.path), nav: nav) }
                    }
                }
                if let approval = latestApproval(found) { Button("Approval Proof…") { saveProof(approval, found) } }
                ForEach(ReviewPublish.shared.hosts.filter { $0.kind == .nas && $0.role != "backup" }) { host in
                    Button("Upload to \(host.name)…") { uploadingTo = host }
                }
            } label: { Image(systemName: "ellipsis.circle").foregroundStyle(Design.Studio.textQuiet) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            stepper(found)
            Button("Publish…") { publishing = true }.buttonStyle(StudioFlatButtonStyle())
            Button { ShareBuilder.shared.new(.asset(asset, project: store.find(asset)?.project ?? UUID()), nav: nav) } label: { Label("Share", systemImage: "square.and.arrow.up") }.buttonStyle(StudioFlatButtonStyle(prominent: true))
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    /// "‹ 2 of 5 ›": the assets next to this one in its folder.
    @ViewBuilder private func stepper(_ found: Deliver.Asset) -> some View {
        let siblings = store.find(asset).map { store.content($0.project).assets.filter { $0.folder == found.folder } } ?? []
        if siblings.count > 1, let index = siblings.firstIndex(where: { $0.id == found.id }) {
            HStack(spacing: 2) {
                Button { nav.deliver = .asset(siblings[index - 1].id, version: nil, comment: nil) } label: { Image(systemName: "chevron.left").frame(width: 22, height: 24).contentShape(.rect) }
                    .disabled(index == 0).help("Previous")
                Text("\(index + 1) of \(siblings.count)").font(Design.Studio.hint.monospacedDigit()).foregroundStyle(Design.Studio.text).padding(.horizontal, 4)
                Button { nav.deliver = .asset(siblings[index + 1].id, version: nil, comment: nil) } label: { Image(systemName: "chevron.right").frame(width: 22, height: 24).contentShape(.rect) }
                    .disabled(index == siblings.count - 1).help("Next")
            }
            .buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).foregroundStyle(Design.Studio.textQuiet)
            .padding(.horizontal, 2)
            .background(Design.Studio.raised, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
        }
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
                    if DeliverCopies.isPreviewOnly(store.original(version)) {
                        VStack(spacing: 6) {
                            Spacer()
                            StudioChip(text: Text("Preview only · first page"), symbol: "eye")
                            if DeliverCopies.isMultiPageOffice(store.original(version)) {
                                Text("Only the first page shows. Export a PDF to review every page.")
                                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                            }
                        }.padding(Design.Spacing.window)
                    }
                case .document:
                    if let image = NSImage(contentsOf: store.copies(version.id).appendingPathComponent("pages/\(page).jpg")) {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        StudioEmptyState(symbol: "doc.richtext", title: "Making the pages")
                    }
                case .video, .audio:
                    DeliverPlayerSurface(player: playback.player)
                    if let problem = playback.problem {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle").font(.title2)
                            Text(verbatim: problem).font(Design.Studio.hint).multilineTextAlignment(.center)
                        }
                        .foregroundStyle(Design.Studio.textQuiet).padding(Design.Spacing.window)
                    }
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
        return RemoteReview.markerEDL(review, title: title, fps: num / den, start: start, dropFrame: probe?.dropFrame ?? false)
    }
}

private extension Int { var asDouble: Double { Double(self) } }

/// An AVPlayer on the original (it's on this Mac), or on the review copy stitched from init + segments when
/// AVFoundation can't open the original (raw, some MXF), or that copy streamed from a NAS server (a teammate's Mac):
/// segment by segment over one kept session, as HLS on this Mac's loopback, the rendition chosen and changed as the web
/// player does (player.ts). The frame shown, by the probe's frame rate.
@MainActor
@Observable
final class DeliverPlayback {
    let player = AVPlayer()
    private(set) var frame = 0
    private(set) var frames = 1
    private(set) var playing = false
    private(set) var fpsNum = 25
    private(set) var fpsDen = 1
    /// Why nothing plays (no copy anywhere, the server away): said over the picture instead of an endless wait.
    private(set) var problem: String?
    /// Streaming from a server: the rendition chosen ("1080", "540", …), and the one whose segments came last.
    private(set) var rendition: String?
    private(set) var arriving: String?
    /// Compare: the second player follows this one's playhead.
    @ObservationIgnored weak var follower: DeliverPlayback?
    @ObservationIgnored private var stream: RemoteStream?
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private(set) var copy: HostCopy?
    @ObservationIgnored private var server: HostCopyServer?
    /// Each rendition taken, in order (tests).
    @ObservationIgnored private(set) var steps: [String] = []
    @ObservationIgnored private var got: [(Double, Double, Double)] = []   // [start, end, media seconds] per fetch (player.ts `got`)
    @ObservationIgnored private var sizes: [(Double, Double, Double)] = [] // the same in bytes
    @ObservationIgnored private var speeds: [Double] = []
    @ObservationIgnored private var switched = 0.0
    @ObservationIgnored private var played = false
    @ObservationIgnored private var loading = UUID()
    @ObservationIgnored private var watching: [NSKeyValueObservation] = []
    @ObservationIgnored private var ticker: Task<Void, Never>?

    func load(_ asset: Deliver.Asset, _ version: Deliver.Version) {
        let store = DeliverStore.shared
        fpsNum = version.probe?.fpsNum ?? 25
        fpsDen = version.probe?.fpsDen ?? 1
        frames = max(version.probe?.frames ?? 1, 1)
        frame = 0
        player.pause()
        stop()
        if observer == nil {
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
                MainActor.assumeIsolated { self?.ticked(time.seconds) }
            }
            watching.append(player.observe(\.timeControlStatus) { [weak self] player, _ in
                let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate && player.reasonForWaitingToPlay == .toMinimizeStalls
                Task { @MainActor in if waiting { self?.stalled() } else if player.timeControlStatus == .playing { self?.played = true } }
            })
        }
        let token = UUID()
        loading = token
        Task {
            var item: AVPlayerItem?
            if let original = store.original(version) {
                let asset = AVURLAsset(url: original)
                if (try? await asset.load(.isPlayable)) == true { item = AVPlayerItem(asset: asset) }
            }
            let rendition = asset.kind == .audio ? "a" : "1080"
            if item == nil, let stitched = Self.stitched(store.copies(version.id).appendingPathComponent(rendition)) {
                stream = stitched
                item = AVPlayerItem(asset: stitched.asset())
            }
            // A teammate's Mac (or the file moved): the review copy streamed from a NAS server.
            if item == nil {
                switch await Self.fromHost(asset.id, version.id, audio: asset.kind == .audio) {
                case .copy(let found):
                    guard loading == token else { return found.ranges.close() }
                    copy = found
                    found.ranges.measured = { [weak self] path, bytes, start, end in
                        Task { @MainActor in self?.measured(path, bytes, start, end) }
                    }
                    found.ranges.failed = { [weak self, ranges = found.ranges] in
                        Task { @MainActor in
                            // (a stale version's failover never shows its error over the one open now)
                            guard let self, self.copy?.ranges === ranges else { return }
                            self.problem = String(localized: "The server stopped answering, so this version can’t play. Check the connection, then open it again.")
                        }
                    }
                    self.rendition = found.start
                    steps = [found.start]
                    item = await streamItem(found, token: token)
                    guard loading == token else { return }
                    ticker = Task { [weak self] in
                        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(250)); self?.tick() }
                    }
                case .missing:
                    guard loading == token else { return }
                    problem = String(localized: "The review copy isn’t on this Mac or on a server it can reach.")
                case .offline:
                    guard loading == token else { return }
                    problem = String(localized: "The server stopped answering, so this version can’t play. Check the connection, then open it again.")
                }
            }
            guard loading == token else { return }
            replace(with: item)
        }
    }

    /// The player goes (or shows another version): the server's session closes.
    func stop() {
        ticker?.cancel()
        ticker = nil
        copy?.ranges.close()
        copy = nil
        server?.stop()
        server = nil
        stream = nil
        arriving = nil
        problem = nil
        rendition = nil
        steps = []
        got = []; sizes = []; speeds = []
        played = false
    }

    private func replace(with item: AVPlayerItem?) {
        player.replaceCurrentItem(with: item)
        watching.removeSubrange(min(1, watching.count)...)
        guard let item else { return }
        watching.append(item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in
                guard let self, self.problem == nil else { return }
                self.problem = self.copy?.ranges.failure != nil
                    ? String(localized: "The server stopped answering, so this version can’t play. Check the connection, then open it again.")
                    : String(localized: "This review copy can’t be played.")
            }
        })
    }

    /// The streamed copy as HLS (a fragmented MP4 through a resource loader made AVFoundation hop through every
    /// fragment, the whole file, before it played): AVPlayer asks for one segment at a time; the rendition chosen here
    /// caps its own choice (preferredPeakBitRate).
    private func streamItem(_ copy: HostCopy, token: UUID) async -> AVPlayerItem? {
        guard let server = await HostCopyServer.start(copy) else { return nil }
        // Another version was opened meanwhile: this server (and the copy's session) go now instead of leaking.
        guard loading == token else { server.stop(); copy.ranges.close(); return nil }
        server.requested = { [weak self] rendition in Task { @MainActor in self?.arriving = rendition } }
        self.server = server
        return item(server, copy.start)
    }

    private func item(_ server: HostCopyServer, _ first: String) -> AVPlayerItem {
        let item = AVPlayerItem(url: server.url(first: first))
        item.preferredPeakBitRate = cap(first)
        item.preferredForwardBufferDuration = 30 // (player.ts AHEAD: what's further on comes later, maybe sharper)
        return item
    }

    /// AVPlayer stays below the rendition chosen though the link carries it (its own estimate lags, and it only goes up
    /// by itself): a new item at the playhead with that rendition listed first, which AVPlayer starts on.
    private func catchUp() {
        guard let copy, let server, let rendition, let arriving, let have = copy.renditions.firstIndex(of: arriving),
              let want = copy.renditions.firstIndex(of: rendition), want < have, ProcessInfo.processInfo.systemUptime - switched > 6,
              let rate = copy.rates[rendition], rate > 0 else { return }
        let bps = Self.linkRate(Array(sizes.suffix(3)))
        guard bps >= 2 * rate || (sizes.count >= 3 && bps >= 1.5 * rate) else { return }
        switched = ProcessInfo.processInfo.systemUptime
        steps.append(rendition)
        let at = player.currentTime(), going = player.rate != 0
        replace(with: item(server, rendition))
        player.seek(to: at, toleranceBefore: .zero, toleranceAfter: .zero)
        if going { player.play() }
    }

    /// The cap for a rendition: none for the highest, else just over its peak.
    private func cap(_ rendition: String) -> Double {
        guard let copy, rendition != copy.renditions.first, let index = copy.indexes[rendition] else { return 0 }
        return Double(HostCopyServer.peak(index) + 1)
    }

    // MARK: - Auto quality (player.ts: startRendition, autoStep, the step down on a stall)

    /// A segment in: the link's speed, remembered for the next start; then autoStep.
    private func measured(_ path: String, _ bytes: Int, _ start: Double, _ end: Double) {
        // (The init piece and other small reads are mostly the round trip: not counted.)
        guard let copy, let rendition, path.hasPrefix(copy.base), !path.hasSuffix(".json"), bytes >= 32 << 10, end > start else { return }
        let rate = copy.rates[String(path.dropFirst(copy.base.count).prefix { $0 != "/" })] ?? 0
        got = Array((got + [(start, end, rate > 0 ? Double(bytes) / rate : 0)]).suffix(8))
        sizes = Array((sizes + [(start, end, Double(bytes))]).suffix(8))
        let bps = Self.linkRate(Array(sizes.suffix(3)))
        Self.saveSeen(copy.serving ?? copy.host, bps)
        speeds = Array((speeds + [Self.linkRate(Array(got.suffix(3)))]).suffix(3))
        let to = Self.autoStep(copy.renditions, rendition, speeds, bps, copy.rates, lan: copy.lan)
        if to != rendition { take(to) } else { catchUp() }
    }

    /// player.ts tick: a first visit started at the top; a first fetch slower than real time steps down before it's in
    /// (not on the office network). (Small fetches, as the init piece, are mostly the round trip: not counted.)
    private func tick() {
        guard let copy, let rendition, got.isEmpty, !copy.lan, let busy = copy.ranges.busy, busy.path.hasPrefix(copy.base + rendition + "/"),
              busy.length >= 32 << 10, let rate = copy.rates[rendition], rate > 0, let i = copy.renditions.firstIndex(of: rendition),
              i < copy.renditions.count - 1 else { return }
        if Self.firstTooSlow(ProcessInfo.processInfo.systemUptime - busy.since, Double(busy.length) / rate) { take(copy.renditions[i + 1]) }
    }

    nonisolated static func firstTooSlow(_ elapsed: Double, _ d: Double) -> Bool { elapsed > d / 1.1 }

    /// Playback waits for data: on a link slower than the video, the smallest copy now (measure climbs back). AVPlayer
    /// itself holds until enough is buffered (player.ts's hold).
    private func stalled() {
        guard let copy, let rendition, played, player.rate != 0, ProcessInfo.processInfo.systemUptime - switched > 3, !got.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let busy = copy.ranges.busy.map { [($0.since, now, 0.0)] } ?? []
        guard Self.linkRate(Array(got.suffix(3)) + busy) < 1, let low = copy.renditions.last, low != rendition else { return }
        take(low)
    }

    /// Another rendition: AVPlayer moves to it from the next segment (no new item, no seek).
    private func take(_ to: String) {
        rendition = to
        steps.append(to)
        speeds = []
        switched = ProcessInfo.processInfo.systemUptime
        player.currentItem?.preferredPeakBitRate = cap(to)
    }

    /// Highest first by number; names that aren't numbers go last, in name order.
    nonisolated static func sortRenditions(_ list: [String]) -> [String] {
        let n = { (r: String) in Int(r) ?? -1 }
        return Array(Set(list)).sorted { n($0) != n($1) ? n($0) > n($1) : $0 < $1 }
    }

    /// A rendition's bytes per second, from its index's segment lengths (0 when it has none).
    nonisolated static func bitrate(_ index: Deliver.CopyIndex) -> Double {
        let d = index.segments.reduce(0) { $0 + $1.d }, b = index.segments.reduce(Int64(0)) { $0 + $1.length }
        return d > 0 ? Double(b) / d : 0
    }

    /// player.ts startRendition: the highest, unless the link speed remembered for this server (under 3 days old) says
    /// less (the highest it carried 1.5× over; the lowest when none). On the office network always the highest. A
    /// first visit is measured on its first fetch (tick).
    nonisolated static func startRendition(_ renditions: [String], rates: [String: Double], seen: Double?, lan: Bool) -> String {
        guard let top = renditions.first, let low = renditions.last else { return "1080" }
        if !lan, let seen, seen > 0, renditions.contains(where: { (rates[$0] ?? 0) > 0 }) {
            return renditions.first { (rates[$0] ?? 0) > 0 && seen >= 1.5 * rates[$0]! } ?? low
        }
        return top
    }

    /// player.ts autoStep: one down when the last fetch came in under 1.1× real time (never for speed on the office
    /// network: only a real stall steps down there); one up when the link carries the next rendition 1.5× over after 3
    /// fetches, at once when twice over; without bitrates, up after 3 over 1.5×.
    nonisolated static func autoStep(_ renditions: [String], _ current: String, _ speeds: [Double], _ bps: Double, _ rates: [String: Double], lan: Bool = false) -> String {
        guard let i = renditions.firstIndex(of: current) else { return current }
        if !lan, i < renditions.count - 1, let last = speeds.last, last < 1.1 { return renditions[i + 1] }
        guard i > 0 else { return current }
        let up = renditions[i - 1], three = speeds.count == 3 && speeds.allSatisfy { $0 > 1.5 }
        guard let rate = rates[up], rate > 0 else { return three ? up : current }
        return bps >= 2 * rate || (three && bps >= 1.5 * rate) ? up : current
    }

    /// player.ts linkRate: everything fetched over the time at least one fetch ran ([start, end, amount] in seconds).
    nonisolated static func linkRate(_ got: [(Double, Double, Double)]) -> Double {
        var busy = 0.0, from = 0.0, to = -Double.infinity
        for (a, b, _) in got.sorted(by: { $0.0 < $1.0 }) {
            if a > to { if to > from { busy += to - from }; from = a; to = b } else { to = max(to, b) }
        }
        if to > from { busy += to - from }
        return got.reduce(0) { $0 + $1.2 } / max(0.001, busy)
    }

    /// The link speed (bytes/s) measured to each server, kept 3 days.
    private static let seenKey = "deliverHostRate"
    static func seen(_ host: UUID) -> Double? {
        guard let entry = (UserDefaults.standard.dictionary(forKey: seenKey)?[host.uuidString] as? [Double]), entry.count == 2,
              Date.now.timeIntervalSince1970 - entry[1] < 3 * 86_400 else { return nil }
        return entry[0]
    }
    static func saveSeen(_ host: UUID, _ bps: Double) {
        guard bps > 0 else { return }
        var all = UserDefaults.standard.dictionary(forKey: seenKey) ?? [:]
        all[host.uuidString] = [bps.rounded(), Date.now.timeIntervalSince1970]
        UserDefaults.standard.set(all, forKey: seenKey)
    }

    // MARK: - The copy and where it comes from

    /// The copy's init piece then every segment, as one fragmented MP4 (read through a resource loader, as RemoteStream does).
    nonisolated static func stitched(_ folder: URL) -> RemoteStream? {
        guard let index = DeliverCopies.index(folder) else { return nil }
        return stitched(index) { file, offset, length in
            let handle = try FileHandle(forReadingFrom: folder.appendingPathComponent(file))
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: length) ?? Data()
        }
    }

    /// The same, each piece read by `read(file, offset, length)`; pieces back to back in one file are one read.
    nonisolated static func stitched(_ index: Deliver.CopyIndex, read: @escaping @Sendable (String, Int64, Int) async throws -> Data) -> RemoteStream {
        var pieces: [(String, Int64, Int64)] = []
        for piece in [(index.`init`.file, index.`init`.offset, index.`init`.length)] + index.segments.map({ ($0.file, $0.offset, $0.length) }) {
            if let last = pieces.last, last.0 == piece.0, last.1 + last.2 == piece.1 { pieces[pieces.count - 1].2 += piece.2 } else { pieces.append(piece) }
        }
        let total = pieces.reduce(Int64(0)) { $0 + $1.2 }
        return RemoteStream(contentType: UTType.mpeg4Movie.identifier) { [pieces] offset, length in
            var data = Data(), at = offset, start = Int64(0)
            for piece in pieces where data.count < length {
                let end = start + piece.2
                if at < end {
                    let chunk = try await read(piece.0, piece.1 + at - start, min(length - data.count, Int(end - at)))
                    guard !chunk.isEmpty else { break }
                    data += chunk
                    at += Int64(chunk.count)
                }
                start = end
            }
            return (data, total)
        }
    }

    /// A copy on a server: its renditions (highest first) with their indexes and bitrates, the one to start on.
    struct HostCopy {
        var ranges: HostRanges
        var host: UUID
        var base: String
        var renditions: [String]
        var indexes: [String: Deliver.CopyIndex]
        var rates: [String: Double]
        var start: String
        var lan: Bool
        /// The server answering now (another after a failover).
        var serving: UUID? { ranges.serving }
    }
    enum Found { case copy(HostCopy), missing, offline }

    /// Tests: these servers, in this order, instead of the ones paired here.
    static var testHosts: [Deliver.Host]?

    /// The review copy on a server this project is published on (or any paired NAS, or a main's backup): one on the
    /// office network first (played from there, at the highest rendition), else the one clients are served from.
    static func fromHost(_ asset: UUID, _ version: UUID, audio: Bool) async -> Found {
        let publish = ReviewPublish.shared
        var hosts: [Deliver.Host] = []
        for host in testHosts ?? (publish.publications(asset: asset).compactMap({ publish.host($0.host) }) + publish.hosts)
        where host.kind == .nas && !hosts.contains(where: { $0.id == host.id }) { hosts.append(host) }
        if testHosts == nil {
            for main in hosts where main.role != "backup" {
                if let backup = DeliverOutage.backup(for: main), !hosts.contains(where: { $0.id == backup.id }) { hosts.append(backup) }
            }
        }
        guard !hosts.isEmpty else { return .missing }
        // On the office network: straight to its address, never through the tunnel (a route kept from before is dropped).
        var lan: Set<UUID> = []
        for host in hosts {
            guard let address = host.address, await (ReviewHostTunnel.lanProbe ?? ReviewHostTunnel.reachable)(address, 1.5) else { continue }
            lan.insert(host.id)
            ReviewHostTunnel.forgetRoute(host.id)
        }
        if lan.isEmpty { hosts = await fastestFirst(hosts) } else { hosts = hosts.filter { lan.contains($0.id) } + hosts.filter { !lan.contains($0.id) } }

        let base = "copies/\(version.uuidString)/"
        var offline = false
        for start in hosts.indices {
            let ranges = HostRanges(hosts: Array(hosts[start...] + hosts[..<start]))
            do {
                let ready = try await ranges.read(base + "ready.json", 0, 1 << 20)
                let listed = (try? JSONSerialization.jsonObject(with: ready) as? [String: Any])?["renditions"] as? [String] ?? []
                let renditions = sortRenditions(listed.filter { audio ? $0 == "a" : (Int($0) ?? .max) <= 1080 })   // (4K is HEVC: the browser's choice only)
                var indexes: [String: Deliver.CopyIndex] = [:], rates: [String: Double] = [:]
                for r in renditions {
                    guard let data = try? await ranges.read(base + r + "/index.json", 0, 8 << 20),
                          let index = try? Deliver.decoder.decode(Deliver.CopyIndex.self, from: data) else { continue }
                    indexes[r] = index
                    rates[r] = bitrate(index)
                }
                let usable = renditions.filter { indexes[$0] != nil }
                guard !usable.isEmpty else { ranges.close(); continue }
                let host = hosts[start].id
                let first = startRendition(usable, rates: rates, seen: seen(ranges.serving ?? host), lan: lan.contains(ranges.serving ?? host))
                return .copy(HostCopy(ranges: ranges, host: host, base: base, renditions: usable, indexes: indexes, rates: rates, start: first,
                                      lan: lan.contains(ranges.serving ?? host)))
            } catch {
                ranges.close()
                // Not there: the next server. Away (every server tried): said.
                if (error as? Deliver.Failure)?.code != "not found" { offline = true; break }
            }
        }
        return offline ? .offline : .missing
    }

    /// The Room's rule (rules.ts `pick`, as Server settings shows it): a backup uploading over 1.2 × the main's speed
    /// whose copies are the main's own quality (or any, with Prefer fastest) first; else the main.
    private static func fastestFirst(_ hosts: [Deliver.Host]) async -> [Deliver.Host] {
        guard hosts.contains(where: { $0.role == "backup" }), let main = hosts.first(where: { $0.role != "backup" }),
              let status = try? await ReviewHostClient.ask(main, ["op": "status"]), let up = status["uplinkMbps"] as? Int else { return hosts }
        let prefer = status["preferFastest"] as? Bool ?? true // on unless the owner turned it off
        let fast = (status["backups"] as? [[String: Any]] ?? []).filter { backup in
            let replica = backup["replica"] as? [String: Any]
            return Double(replica?["uplinkMbps"] as? Int ?? 0) > Double(up) * 1.2 && (replica?["quality"] as? String == "same" || prefer)
        }.max { ($0["replica"] as? [String: Any])?["uplinkMbps"] as? Int ?? 0 < ($1["replica"] as? [String: Any])?["uplinkMbps"] as? Int ?? 0 }
        guard let name = fast?["name"] as? String, let backup = hosts.first(where: { $0.role == "backup" && $0.name == name }) else { return hosts }
        return [backup] + hosts.filter { $0.id != backup.id }
    }

    /// Byte ranges of a server's files over ONE kept session, one request at a time (a new connection per range was far
    /// too slow over a VPN). A dropped session is opened again once; then the next server. Nothing is kept on disk
    /// (each range passes through a temporary file, as `get` writes one).
    final class HostRanges: @unchecked Sendable {
        private struct Job { var path: String; var offset: Int64; var length: Int; var done: CheckedContinuation<Data, Error> }
        private let feed: AsyncStream<Job>.Continuation
        private let lock = NSLock()
        private var _failure: Error?, _serving: UUID?, _via: ReviewHostTunnel.Via?, _fetched = 0
        private var _busy: (since: Double, length: Int, path: String)?
        private var drop: (() -> Void)?
        /// Each fetch: its path, bytes, start and end (system uptime).
        var measured: (@Sendable (String, Int, Double, Double) -> Void)?
        /// Every server failed.
        var failed: (@Sendable () -> Void)?
        /// Tests: the link's speed (bytes/s) and a round trip added to each range.
        nonisolated(unsafe) static var testRate: Double?
        nonisolated(unsafe) static var testDelay: Double = 0

        var failure: Error? { lock.withLock { _failure } }
        var serving: UUID? { lock.withLock { _serving } }
        var via: ReviewHostTunnel.Via? { lock.withLock { _via } }
        /// The range being fetched: since when, its length and path.
        var busy: (since: Double, length: Int, path: String)? { lock.withLock { _busy } }
        var fetched: Int { lock.withLock { _fetched } }

        @MainActor
        init(hosts: [Deliver.Host]) {
            let (jobs, feed) = AsyncStream.makeStream(of: Job.self)
            self.feed = feed
            Task { @MainActor [weak self] in
                var iterator = jobs.makeAsyncIterator()
                var pending: Job?, at = 0, retried = false
                while at < hosts.count {
                    var served = false
                    do {
                        try await ReviewHostClient.session(hosts[at]) { session in
                            let via = try? await ReviewHostTunnel.route(hosts[at]).via
                            self?.lock.withLock { self?._serving = hosts[at].id; self?._via = via; self?.drop = { session.close() } }
                            while true {
                                if pending == nil { pending = await iterator.next() }
                                guard let job = pending else { return }
                                do {
                                    let data = try await Self.fetch(job, session: session, owner: self)
                                    pending = nil; served = true; retried = false
                                    job.done.resume(returning: data)
                                } catch let failure as Deliver.Failure where failure.code == "not found" {
                                    pending = nil; job.done.resume(throwing: failure)
                                }
                            }
                        }
                        break // closed
                    } catch {
                        self?.lock.withLock { self?._busy = nil; self?.drop = nil }
                        // Dropped after serving: once more on the same server. Didn't open, or dropped again: the next one.
                        if served, !retried { retried = true } else { at += 1; retried = false }
                        if at < hosts.count { ReviewHostTunnel.forgetRoute(hosts[at].id) }
                    }
                }
                guard at >= hosts.count else { return }
                let failure = Deliver.Failure("offline")
                self?.lock.withLock { self?._failure = failure }
                self?.failed?()
                feed.finish()
                pending?.done.resume(throwing: failure)
                while let job = await iterator.next() { job.done.resume(throwing: failure) }
            }
        }

        deinit { feed.finish() }

        /// The session closes (once what's being fetched is done); reads after it fail.
        func close() { feed.finish() }

        /// Tests: the connection breaks, as when a server goes away mid-play.
        func dropConnection() { lock.withLock { drop }?() }

        func read(_ path: String, _ offset: Int64, _ length: Int) async throws -> Data {
            if let failure { throw failure }
            return try await withCheckedThrowingContinuation { done in
                if case .terminated = feed.yield(Job(path: path, offset: offset, length: length, done: done)) {
                    done.resume(throwing: failure ?? CancellationError())
                }
            }
        }

        private static func fetch(_ job: Job, session: HostSession, owner: HostRanges?) async throws -> Data {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-range-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: file) }
            let start = ProcessInfo.processInfo.systemUptime
            owner?.lock.withLock { owner?._busy = (start, job.length, job.path) }
            if testDelay > 0 { try? await Task.sleep(for: .seconds(testDelay)) }
            try await session.get(job.path, to: file, offset: job.offset, length: Int64(job.length), expected: Int64(job.length))
            let data = try Data(contentsOf: file)
            if let rate = testRate {
                let left = Double(data.count) / rate - (ProcessInfo.processInfo.systemUptime - start)
                if left > 0 { try? await Task.sleep(for: .seconds(left)) }
            }
            let end = ProcessInfo.processInfo.systemUptime
            owner?.lock.withLock { owner?._busy = nil; owner?._fetched += data.count }
            owner?.measured?(job.path, data.count, start, end)
            return data
        }
    }

    /// The streamed copy as HLS on 127.0.0.1 for AVPlayer, under a random path: a master playlist (the start rendition
    /// first), a media playlist per rendition (byte ranges of its file, the init as EXT-X-MAP, made here from its index)
    /// and those byte ranges, each asked of the server over the copy's HostRanges. One request per connection.
    final class HostCopyServer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "be.wideopen.pluck.copy-server")
        private let token = UUID().uuidString
        private let playlists: [String: Data]
        private let variants: [(String, String)] // rendition, its STREAM-INF line
        private let sizes: [String: Int64]
        private let ranges: HostRanges
        private let base: String
        private var port: UInt16 = 0
        /// The master playlist with `first` listed first (AVPlayer starts on the first).
        func url(first: String) -> URL { URL(string: "http://127.0.0.1:\(port)/\(token)/master.m3u8?first=\(first)&n=\(UUID().uuidString.prefix(8))")! }
        /// Each segment asked for: its rendition.
        var requested: (@Sendable (String) -> Void)?

        private init(_ copy: HostCopy, listener: NWListener) {
            self.listener = listener
            ranges = copy.ranges
            base = copy.base
            var playlists: [String: Data] = [:], sizes: [String: Int64] = [:]
            var variants: [(String, String)] = []
            for r in copy.renditions {
                guard let index = copy.indexes[r] else { continue }
                var info = "#EXT-X-STREAM-INF:BANDWIDTH=\(Self.peak(index)),AVERAGE-BANDWIDTH=\(Int((copy.rates[r] ?? 0) * 8)),CODECS=\"\(index.codecs)\""
                if index.width > 0, index.height > 0, r != "a" { info += ",RESOLUTION=\(index.width)x\(index.height)" }
                variants.append((r, info))
                playlists["\(r)/index.m3u8"] = Data(Self.media(index).utf8)
                for (file, size) in Self.files(index) { sizes["\(r)/\(file)"] = size }
            }
            self.variants = variants
            self.playlists = playlists
            self.sizes = sizes
        }

        /// Listening on a free loopback port, or nil.
        @MainActor
        static func start(_ copy: HostCopy) async -> HostCopyServer? {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            guard let listener = try? NWListener(using: parameters) else { return nil }
            let server = HostCopyServer(copy, listener: listener)
            listener.newConnectionHandler = { [weak server] connection in
                guard let server else { return connection.cancel() }
                connection.start(queue: server.queue)
                server.receive(connection, Data())
            }
            let port: UInt16? = await withCheckedContinuation { done in
                let once = OnceFlag()
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: if once.claim() { done.resume(returning: listener.port?.rawValue) }
                    case .failed, .cancelled: if once.claim() { done.resume(returning: nil) }
                    default: break
                    }
                }
                listener.start(queue: server.queue)
            }
            guard let port else { listener.cancel(); return nil }
            server.port = port
            return server
        }

        func stop() { listener.cancel() }

        /// A media playlist: every segment as a byte range of its file, the init piece as the map.
        static func media(_ index: Deliver.CopyIndex) -> String {
            var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(Int((index.segments.map(\.d).max() ?? 2).rounded(.up)))",
                         "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-INDEPENDENT-SEGMENTS",
                         "#EXT-X-MAP:URI=\"\(index.`init`.file)\",BYTERANGE=\"\(index.`init`.length)@\(index.`init`.offset)\""]
            for segment in index.segments {
                lines += [String(format: "#EXTINF:%.6f,", segment.d), "#EXT-X-BYTERANGE:\(segment.length)@\(segment.offset)", segment.file]
            }
            return (lines + ["#EXT-X-ENDLIST"]).joined(separator: "\n") + "\n"
        }

        /// The highest bits per second of any segment (HLS BANDWIDTH).
        static func peak(_ index: Deliver.CopyIndex) -> Int {
            Int(index.segments.map { Double($0.length) * 8 / max($0.d, 0.001) }.max() ?? 0)
        }

        /// Each file's size: its last piece's end.
        static func files(_ index: Deliver.CopyIndex) -> [String: Int64] {
            var sizes: [String: Int64] = [:]
            for (file, end) in [(index.`init`.file, index.`init`.offset + index.`init`.length)] + index.segments.map({ ($0.file, $0.offset + $0.length) }) {
                sizes[file] = max(sizes[file] ?? 0, end)
            }
            return sizes
        }

        private func receive(_ connection: NWConnection, _ head: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 << 10) { [weak self] data, _, done, error in
                guard let self, error == nil else { return connection.cancel() }
                let head = head + (data ?? Data())
                if let end = head.range(of: Data("\r\n\r\n".utf8)) { return self.answer(String(decoding: head[..<end.lowerBound], as: UTF8.self), connection) }
                if done || head.count > 64 << 10 { return connection.cancel() }
                self.receive(connection, head)
            }
        }

        private func answer(_ head: String, _ connection: NWConnection) {
            let lines = head.components(separatedBy: "\r\n"), request = lines.first?.split(separator: " ") ?? []
            let prefix = "/\(token)/"
            guard request.count >= 2, request[0] == "GET", request[1].hasPrefix(prefix) else { return send(connection, 404, [:], Data()) }
            let name = String(request[1].dropFirst(prefix.count).prefix { $0 != "?" })
            if name == "master.m3u8" {
                let first = request[1].split(separator: "?").dropFirst().first?.split(separator: "&").first { $0.hasPrefix("first=") }.map { String($0.dropFirst(6)) }
                let ordered = variants.filter { $0.0 == first } + variants.filter { $0.0 != first }
                let master = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"] + ordered.flatMap { [$0.1, "\($0.0)/index.m3u8"] }
                return send(connection, 200, ["Content-Type": "application/vnd.apple.mpegurl"], Data((master.joined(separator: "\n") + "\n").utf8))
            }
            if let playlist = playlists[name] { return send(connection, 200, ["Content-Type": "application/vnd.apple.mpegurl"], playlist) }
            guard let size = sizes[name] else { return send(connection, 404, [:], Data()) }
            var start: Int64 = 0, end = size - 1, status = 200
            let range = lines.first { $0.lowercased().hasPrefix("range:") }.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            if let range, range.hasPrefix("bytes=") {
                let bounds = range.dropFirst(6).split(separator: ",").first?.split(separator: "-", omittingEmptySubsequences: false) ?? []
                if bounds.count == 2, let first = Int64(bounds[0]) { start = first; if let last = Int64(bounds[1]) { end = min(last, size - 1) } }
                guard start <= end else { return send(connection, 416, ["Content-Range": "bytes */\(size)"], Data()) }
                status = 206
            }
            if let rendition = name.split(separator: "/").first { requested?(String(rendition)) }
            let path = base + name, ranges = ranges
            Task {
                do {
                    let data = try await ranges.read(path, start, Int(end - start + 1))
                    self.send(connection, status, ["Content-Type": "video/mp4", "Accept-Ranges": "bytes", "Content-Range": "bytes \(start)-\(start + Int64(data.count) - 1)/\(size)"], data)
                } catch {
                    self.send(connection, 503, [:], Data())
                }
            }
        }

        private func send(_ connection: NWConnection, _ status: Int, _ headers: [String: String], _ body: Data) {
            let reason = [200: "OK", 206: "Partial Content", 404: "Not Found", 416: "Range Not Satisfiable", 503: "Service Unavailable"][status] ?? "OK"
            var lines = ["HTTP/1.1 \(status) \(reason)", "Content-Length: \(body.count)", "Connection: close"]
            for (key, value) in headers { lines.append("\(key): \(value)") }
            connection.send(content: Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) + body, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
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
