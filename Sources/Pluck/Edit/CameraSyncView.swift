import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// What Sync Cameras is working on: the cameras and their clips, kept while other pages are open.
@MainActor @Observable
final class CameraSyncModel {
    static let shared = CameraSyncModel()

    var cameras: [SyncCamera] = []
    var share = 0.0
    var status: String?
    var problem: String?
    var done: String?
    var selected: UUID?
    /// Sound before timecode, for a shoot whose timecode can't be trusted.
    var audioFirst = false
    private(set) var task: Task<Void, Never>?
    @ObservationIgnored let cache = SyncCache()

    var running: Bool { task != nil }
    var rate: Double { CameraSyncExport.rate(cameras) }
    var synced: Bool { cameras.contains { $0.clips.contains { $0.start != nil } } }
    var clips: [SyncClip] { cameras.flatMap(\.clips) }

    private var ffmpeg: String? { AppDelegate.shared?.manager.tool("ffmpeg") }
    private var ffprobe: String? { AppDelegate.shared?.manager.tool("ffprobe") }

    /// Reads what was dropped and groups it into cameras (with what's here already: it's grouped again together).
    func add(_ urls: [URL]) {
        guard task == nil, let ffprobe else { problem = Converting.Failure.noFFmpeg.localizedDescription; return }
        problem = nil
        done = nil
        let known = clips
        task = Task {
            status = String(localized: "Reading the clips")
            let found = await Task.detached { CameraSync.files(in: urls) }.value
            var probes: [CameraSync.Probe] = []
            for (number, item) in found.enumerated() where !known.contains(where: { $0.path == item.file.path }) {
                if Task.isCancelled { break }
                share = Double(number) / Double(max(found.count, 1))
                if let probe = await Task.detached(operation: { CameraSync.probe(item.file, root: item.root, ffprobe: ffprobe) }).value { probes.append(probe) }
            }
            guard !Task.isCancelled else { return }
            // New clips join the camera they belong to; the rest make new cameras.
            var cameras = self.cameras
            for camera in CameraSync.group(probes) {
                if let index = cameras.firstIndex(where: { $0.key == camera.key }) { cameras[index].clips += camera.clips } else { cameras.append(camera) }
            }
            self.cameras = cameras
            if found.isEmpty { problem = String(localized: "No clips in what was dropped.") }
            finish()
        }
    }

    /// Syncs everything not locked, or only `only` (everything else stays where it is).
    func sync(only: UUID? = nil) {
        guard task == nil, let ffmpeg else { if ffmpeg == nil { problem = Converting.Failure.noFFmpeg.localizedDescription }; return }
        problem = nil
        done = nil
        var input = cameras
        // One clip: the others held where they are for this run.
        let held = Set(clips.filter { only != nil && $0.id != only && $0.start != nil && !$0.locked }.map(\.id))
        for c in input.indices { for i in input[c].clips.indices where held.contains(input[c].clips[i].id) { input[c].clips[i].locked = true } }
        if let only { for c in input.indices { for i in input[c].clips.indices where input[c].clips[i].id == only { input[c].clips[i].locked = false } } }
        let cache = cache, audioFirst = audioFirst
        task = Task {
            status = String(localized: "Listening")
            var result = await CameraSync.sync(input, options: .init(ffmpeg: ffmpeg, sound: { cache.sound($0) }, cache: cache, audioFirst: audioFirst)) { share, text in
                Task { @MainActor in
                    CameraSyncModel.shared.share = share
                    if !text.isEmpty { CameraSyncModel.shared.status = text }
                }
            }
            for c in result.indices { for i in result[c].clips.indices where held.contains(result[c].clips[i].id) { result[c].clips[i].locked = false } }
            guard !Task.isCancelled else { return }
            cameras = result
            let missed = result.flatMap(\.clips).filter { $0.start == nil }.count
            var problems: [String] = []
            if missed > 0 { problems.append(String(localized: "Not synced: \(missed). Nudge them into place, or check they’re from this event.")) }
            for clip in result.flatMap(\.clips) { if let off = clip.slateOff { problems.append("\(clip.name): " + String(localized: "Slate doesn't match: \(off) frames")) } }
            problem = problems.isEmpty ? nil : problems.joined(separator: "\n")
            // Cameras whose timecode the sound moved.
            let moved = result.compactMap { camera -> String? in
                guard let clip = camera.clips.first(where: { $0.method == .timecodeOffset }), let start = clip.start, let tc = clip.timecode else { return nil }
                return "\(camera.name): " + String(localized: "timecode \(start - tc, format: .number.precision(.fractionLength(2)).sign(strategy: .always())) s from sound")
            }
            if !moved.isEmpty { done = moved.joined(separator: "\n") }
            finish()
        }
    }

    func stop() {
        task?.cancel()
        finish()
    }

    private func finish() {
        task = nil
        status = nil
        share = 0
    }

    func clear() {
        stop()
        cameras = []
        selected = nil
        audioFirst = false
        done = nil
        problem = nil
        cache.clear()
    }

    private func edit(_ id: UUID, _ change: (inout SyncClip) -> Void) {
        for c in cameras.indices { for i in cameras[c].clips.indices where cameras[c].clips[i].id == id { change(&cameras[c].clips[i]) } }
    }

    /// Moves a clip by whole timeline frames, and holds it there.
    func nudge(_ id: UUID, frames: Int) {
        let rate = rate
        // Not synced yet: from where it's drawn, after its camera's synced clips.
        let camera = cameras.first { $0.clips.contains { $0.id == id } }
        var from = camera?.clips.compactMap(\.end).max().map { $0 + 2 } ?? clips.compactMap(\.start).min() ?? 0
        for clip in camera?.clips ?? [] where clip.start == nil { if clip.id == id { break }; from += clip.duration + 2 }
        edit(id) { clip in
            clip.start = (clip.start ?? from) + Double(frames) / rate
            clip.method = .manual
            clip.locked = true
        }
    }

    func toggleLock(_ id: UUID) { edit(id) { $0.locked.toggle() } }

    /// Into another camera (nil: a camera of its own).
    func move(_ id: UUID, to camera: UUID?) {
        guard let from = cameras.firstIndex(where: { $0.clips.contains { $0.id == id } }),
              let clip = cameras[from].clips.first(where: { $0.id == id }) else { return }
        cameras[from].clips.removeAll { $0.id == id }
        if let camera, let to = cameras.firstIndex(where: { $0.id == camera }) {
            cameras[to].clips.append(clip)
            cameras[to].clips.sort { ($0.start ?? .infinity) < ($1.start ?? .infinity) }
        } else {
            cameras.append(SyncCamera(name: String(localized: "Camera \(cameras.count + 1)"), key: "own:" + UUID().uuidString, clips: [clip]))
        }
        cameras.removeAll { $0.clips.isEmpty }
    }

    func rename(_ camera: UUID, _ name: String) {
        guard let index = cameras.firstIndex(where: { $0.id == camera }), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        cameras[index].name = name
    }

    // MARK: Out

    private var name: String { String(localized: "Synced Cameras") }

    func sendToResolve() {
        guard task == nil else { return }
        problem = nil
        let cameras = cameras, name = name
        task = Task {
            status = String(localized: "Sending to DaVinci Resolve")
            do {
                let result = try await CameraSyncExport.sendToResolve(cameras, name: name)
                done = String(localized: "In DaVinci Resolve: \(result.timeline), \(result.placed) of \(result.asked) placed")
            } catch {
                problem = error.localizedDescription
            }
            finish()
        }
    }

    func saveFCPXML() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "fcpxml") ?? .xml]
        panel.nameFieldStringValue = name + ".fcpxml"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try CameraSyncExport.fcpxml(cameras, name: name).write(to: url, atomically: true, encoding: .utf8)
            done = String(localized: "Saved \(url.lastPathComponent)")
        } catch {
            problem = error.localizedDescription
        }
    }

    func openInEdit() {
        let project = CameraSyncExport.project(cameras, name: name)
        ProjectStore.save(project)
        StudioNavigator.shared.open(project)
    }

    /// The placed clip of another camera that runs longest beside this one.
    func partner(of clip: SyncClip) -> SyncClip? {
        let own = cameras.first { $0.clips.contains { $0.id == clip.id } }?.id
        return cameras.filter { $0.id != own }.flatMap(\.clips).filter { $0.hasVideo && CameraSync.overlap($0, clip) > 0 }
            .max { CameraSync.overlap($0, clip) < CameraSync.overlap($1, clip) }
    }
}

/// Sync Cameras: every camera's clips on lanes, coloured by how sure the sync is; a clip chosen
/// shows beside another angle at the same moment, to nudge or lock.
struct CameraSyncView: View {
    @State private var model = CameraSyncModel.shared
    @State private var dropping = false
    @State private var zoom = 1.0
    /// Footage to add when the view appears (screenshot mode).
    @MainActor static var openFiles: [URL] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if model.cameras.isEmpty {
                    StudioEmptyState(symbol: "rectangle.stack.badge.play", title: "Drop camera cards or clips here",
                                     line: "Every camera and a sound recorder. Synced by timecode, sound and light flashes.",
                                     targeted: dropping, button: "Add Footage…", action: choose)
                        .padding(.vertical, 56)
                        .studioDropZone(targeted: dropping)
                }
                if let status = model.status {
                    HStack(spacing: 10) {
                        PlumSpinner()
                        Text(status).font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                        Spacer()
                        Button("Stop") { model.stop() }.buttonStyle(StudioFlatButtonStyle())
                    }
                    StudioProgress(share: model.share)
                }
                if let problem = model.problem { notice(problem, symbol: "exclamationmark.triangle", colour: Design.Studio.warn) }
                if let done = model.done { notice(done, symbol: "checkmark", colour: Design.Studio.good) }
                if !model.cameras.isEmpty { lanes }
                if let id = model.selected, let clip = model.clips.first(where: { $0.id == id }) {
                    SyncClipInspector(model: model, clip: clip).id(clip.id)
                }
                StudioFootnote(text: "Runs on this Mac")
            }
            .frame(maxWidth: 1200)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .studioPanel()
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers { if let url = try? await provider.load(URL.self) { urls.append(url) } }
                if !urls.isEmpty { model.add(urls) }
            }
            return true
        }
        .onAppear {
            if !Self.openFiles.isEmpty { model.add(Self.openFiles); Self.openFiles = [] }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Sync Cameras").font(Design.Studio.pageTitle).foregroundStyle(Design.Studio.text)
            Spacer()
            if !model.cameras.isEmpty {
                Button("Add…", systemImage: "plus", action: choose).buttonStyle(StudioFlatButtonStyle())
                Button("Clear", action: model.clear).buttonStyle(StudioFlatButtonStyle())
                HStack(spacing: 6) {
                    Text("Sound first").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                    Toggle("Sound first", isOn: $model.audioFirst).toggleStyle(StudioSwitchStyle())
                }
                .help("For a shoot whose timecode can't be trusted")
                .disabled(model.running)
                Menu {
                    Button("FCPXML File…", systemImage: "doc", action: model.saveFCPXML)
                    Button("Pluck Edit", systemImage: "rectangle.stack", action: model.openInEdit)
                } label: {
                    Label("Send", systemImage: "paperplane").font(Design.Studio.body)
                }
                .menuStyle(.button)
                .buttonStyle(StudioFlatButtonStyle())
                .fixedSize()
                .disabled(!model.synced || model.running)
                Button(model.synced ? "Sync Again" : "Sync", systemImage: "waveform.badge.magnifyingglass") { model.sync() }
                    .buttonStyle(StudioFlatButtonStyle(prominent: !model.synced || !Resolve.isInstalled, height: 32))
                    .disabled(model.running)
                // Synced: the timeline to DaVinci Resolve is what comes next.
                if model.synced && Resolve.isInstalled {
                    Button("Send to DaVinci Resolve", systemImage: "film", action: model.sendToResolve)
                        .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.running)
                }
            }
        }
    }

    private func notice(_ text: String, symbol: String, colour: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(colour)
            Text(text).font(Design.Studio.body).foregroundStyle(Design.Studio.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .studioBox()
    }

    // MARK: Lanes

    /// Where each clip is drawn: its synced place, else after the camera's synced clips in order.
    private var layout: (places: [UUID: Double], from: Double, length: Double) {
        var places: [UUID: Double] = [:]
        let synced = model.clips.compactMap(\.start)
        let from = synced.min() ?? 0
        for camera in model.cameras {
            var next = camera.clips.compactMap(\.end).max().map { $0 + 2 } ?? from
            for clip in camera.clips {
                if let start = clip.start ?? clip.rough { places[clip.id] = start } else { places[clip.id] = next; next += clip.duration + 2 }
            }
        }
        let end = model.clips.map { (places[$0.id] ?? 0) + $0.duration }.max() ?? 1
        return (places, from, max(end - from, 1))
    }

    private var lanes: some View {
        let layout = layout
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(model.cameras.count) cameras · \(model.clips.count) clips").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                Spacer()
                legend("Sure", Design.Studio.good)
                legend("Check", Design.Studio.warn)
                legend("Unsure", Design.Studio.bad)
                legend("Not synced", Design.Studio.textFaint)
                Image(systemName: "minus.magnifyingglass").font(.system(size: 11)).foregroundStyle(Design.Studio.textQuiet)
                Slider(value: $zoom, in: 1...30).frame(width: 110).controlSize(.mini).help("Zoom")
            }
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.cameras) { camera in CameraLabel(model: model, camera: camera).frame(height: 30) }
                }
                .frame(width: 150)
                GeometryReader { geometry in
                    let width = geometry.size.width * zoom
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(model.cameras) { camera in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 6).fill(Design.Studio.panel)
                                    ForEach(camera.clips) { clip in
                                        clipBox(clip, camera: camera)
                                            .frame(width: max(width * clip.duration / layout.length, 3), height: 24)
                                            .offset(x: width * ((layout.places[clip.id] ?? 0) - layout.from) / layout.length)
                                    }
                                }
                                .frame(width: width, height: 30)
                            }
                        }
                    }
                    .scrollIndicators(zoom > 1 ? .visible : .never)
                }
                .frame(height: CGFloat(model.cameras.count) * 36)
            }
        }
        .padding(16)
        .studioBox()
    }

    private func legend(_ title: LocalizedStringKey, _ colour: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(colour).frame(width: 9, height: 9)
            Text(title)
        }
        .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
    }

    static func colour(_ quality: SyncClip.Quality) -> Color {
        switch quality {
        case .good: Design.Studio.good
        case .fair: Design.Studio.warn
        case .poor: Design.Studio.bad
        case .rough: Design.Studio.warn
        case .none: Design.Studio.textFaint
        }
    }

    /// How a clip was placed, in words.
    static func method(_ clip: SyncClip) -> Text {
        switch clip.method {
        case .audio: Text("By sound")
        case .timecode: Text("By timecode")
        case .timecodeOffset: Text("Timecode + sound offset")
        case .slate: Text("By timecode slate")
        case .flashes: Text("By light flashes")
        case .manual: Text("Set by hand")
        case nil: clip.rough != nil ? Text("Rough: from clock time") : Text("Not synced")
        }
    }

    static func symbol(_ clip: SyncClip) -> String? {
        switch clip.method {
        case .audio: "waveform"
        case .timecode, .timecodeOffset: "clock"
        case .slate: "textformat.123"
        case .flashes: "bolt"
        case .manual: "hand.point.up"
        case nil: clip.rough != nil ? "clock.badge.questionmark" : nil
        }
    }

    private func clipBox(_ clip: SyncClip, camera: SyncCamera) -> some View {
        let chosen = model.selected == clip.id
        return RoundedRectangle(cornerRadius: 4)
            .fill(Self.colour(clip.quality).opacity(clip.start == nil ? 0.25 : 0.55))
            .overlay {
                RoundedRectangle(cornerRadius: 4).strokeBorder(chosen ? AnyShapeStyle(Design.Brand.pink) : AnyShapeStyle(Color.clear), lineWidth: 2)
            }
            .overlay(alignment: .leading) {
                HStack(spacing: 3) {
                    if clip.locked { Image(systemName: "lock.fill").font(.system(size: 8)) }
                    if let symbol = Self.symbol(clip) { Image(systemName: symbol).font(.system(size: 8)) }
                    Text(clip.file.deletingPathExtension().lastPathComponent).lineLimit(1)
                }
                .font(.system(size: 10)).foregroundStyle(Design.Studio.text).padding(.horizontal, 5)
            }
            .clipShape(.rect(cornerRadius: 4))
            .contentShape(.rect)
            .onTapGesture { model.selected = chosen ? nil : clip.id }
            .help(Text(verbatim: clip.name + " · ") + Self.method(clip) + (clip.start != nil ? Text(verbatim: " · ") + Text(clip.confidence, format: .percent.precision(.fractionLength(0))) : Text(verbatim: "")))
            .contextMenu {
                Button(clip.locked ? "Unlock" : "Lock") { model.toggleLock(clip.id) }
                Button("Sync This Clip Again") { model.sync(only: clip.id) }.disabled(model.running || !model.synced)
                Menu("Move to Camera") {
                    ForEach(model.cameras.filter { $0.id != camera.id }) { other in
                        Button(other.name) { model.move(clip.id, to: other.id) }
                    }
                    Divider()
                    Button("New Camera") { model.move(clip.id, to: nil) }
                }
            }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        model.add(panel.urls)
    }
}

/// A lane's name (editable), its clip count, and what kind of camera it is.
private struct CameraLabel: View {
    let model: CameraSyncModel
    let camera: SyncCamera
    @State private var name = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: camera.isSoundRecorder ? "waveform" : camera.hasAudio ? "video" : "video.slash")
                .font(.system(size: 11)).foregroundStyle(Design.Studio.textQuiet).frame(width: 16)
                .help(camera.isSoundRecorder ? "Sound recorder" : camera.hasAudio ? "Camera with sound" : "No sound: synced by light flashes")
            TextField("Camera", text: $name)
                .textFieldStyle(.plain).font(Design.Studio.body).foregroundStyle(Design.Studio.text)
                .onSubmit { model.rename(camera.id, name) }
            Text(verbatim: "\(camera.clips.count)").font(Design.Studio.hint).foregroundStyle(Design.Studio.textFaint)
        }
        .onAppear { name = camera.name }
        .onChange(of: camera.name) { name = camera.name }
    }
}

/// A chosen clip: it and another camera side by side at a moment both filmed, its sync, and the nudge.
private struct SyncClipInspector: View {
    let model: CameraSyncModel
    let clip: SyncClip
    @State private var players: [AVPlayer] = []
    @State private var playing = false

    private var partner: SyncClip? { model.partner(of: clip) }

    /// A moment both filmed: the middle of the time they share.
    private var moment: Double? {
        guard let partner, let a = clip.start, let b = partner.start, let ae = clip.end, let be = partner.end else { return nil }
        return (max(a, b) + min(ae, be)) / 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text(clip.name).font(.system(size: 13)).foregroundStyle(Design.Studio.text).lineLimit(1).truncationMode(.middle)
                if clip.method != nil || clip.rough != nil { StudioChip(text: CameraSyncView.method(clip)) }
                if clip.method == .timecodeOffset, let start = clip.start, let tc = clip.timecode {
                    StudioChip(text: Text("Timecode \(start - tc, format: .number.precision(.fractionLength(2)).sign(strategy: .always())) s"), symbol: "clock",
                               colour: Design.Studio.warn, tinted: true)
                }
                if let off = clip.slateOff {
                    StudioChip(text: Text("Slate doesn't match: \(off) frames"), symbol: "exclamationmark.triangle", colour: Design.Studio.bad, tinted: true)
                }
                if clip.start != nil {
                    StudioChip(text: Text(clip.confidence, format: .percent.precision(.fractionLength(0))),
                               colour: CameraSyncView.colour(clip.quality), tinted: true)
                        .help("How sure the sync is")
                }
                if clip.drift != 0 {
                    let perHour = clip.drift * 3600 * model.rate
                    StudioChip(text: Text("Drifts \(perHour, format: .number.precision(.fractionLength(1))) frames an hour"), symbol: "clock.arrow.2.circlepath",
                               colour: Design.Studio.warn, tinted: true)
                }
                Spacer()
                Button { model.nudge(clip.id, frames: -Int(model.rate.rounded())) } label: { Image(systemName: "chevron.backward.2") }
                    .buttonStyle(StudioFlatButtonStyle()).help("A second earlier")
                Button { model.nudge(clip.id, frames: -1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(StudioFlatButtonStyle()).help("A frame earlier")
                Button { model.nudge(clip.id, frames: 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(StudioFlatButtonStyle()).help("A frame later")
                Button { model.nudge(clip.id, frames: Int(model.rate.rounded())) } label: { Image(systemName: "chevron.forward.2") }
                    .buttonStyle(StudioFlatButtonStyle()).help("A second later")
                Button { model.toggleLock(clip.id) } label: { Image(systemName: clip.locked ? "lock.fill" : "lock.open") }
                    .buttonStyle(StudioFlatButtonStyle()).help(clip.locked ? "Unlock" : "Lock")
                Button("Sync Again") { model.sync(only: clip.id) }
                    .buttonStyle(StudioFlatButtonStyle()).disabled(model.running || !model.synced)
            }
            if let partner, moment != nil {
                HStack(spacing: 10) {
                    angle(clip, index: 0)
                    angle(partner, index: 1)
                }
                .frame(height: 220)
                HStack(spacing: 10) {
                    Button(playing ? "Stop" : "Play Both", systemImage: playing ? "stop.fill" : "play.fill", action: togglePlay)
                        .buttonStyle(StudioFlatButtonStyle())
                    Text("With \(partner.name), both at the same moment. Listen for an echo.")
                        .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                }
            }
        }
        .padding(16)
        .studioBox(outline: Design.rgb(0x8E4C64))
        .onAppear(perform: load)
        .onChange(of: clip.start) { cue() }
        .onDisappear { players.forEach { $0.pause() } }
    }

    @ViewBuilder private func angle(_ clip: SyncClip, index: Int) -> some View {
        if index < players.count, !RawFormats.isRawVideo(clip.file) {
            SyncPlayerSurface(player: players[index]).clipShape(.rect(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8).fill(Design.Studio.panel)
                .overlay { Text(clip.name).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet) }
        }
    }

    private func load() {
        guard let partner else { return }
        players = [clip, partner].map { AVPlayer(url: $0.file) }
        cue()
    }

    /// Both at the shared moment, in each clip's own time.
    private func cue() {
        guard let moment, let partner, players.count == 2 else { return }
        for (player, own) in zip(players, [clip, partner]) {
            guard let start = own.start else { continue }
            player.seek(to: CMTime(seconds: (moment - start) / (1 + own.drift), preferredTimescale: 48000), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func togglePlay() {
        if playing { players.forEach { $0.pause() }; playing = false; cue(); return }
        cue()
        // Both from the same moment on the host clock, so a sync error is heard as it is.
        let when = CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(seconds: 0.3, preferredTimescale: 600)
        for player in players {
            player.automaticallyWaitsToMinimizeStalling = false
            player.setRate(1, time: .invalid, atHostTime: when)
        }
        playing = true
    }
}

/// The picture, without the player's own controls.
private struct SyncPlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
