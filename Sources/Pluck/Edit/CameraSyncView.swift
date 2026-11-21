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
    /// Timecode shown on camera (a slate, a phone's timecode app, burned-in): looked for through each clip's first and last 10 s.
    var shownTimecode = false {
        didSet {
            guard shownTimecode != oldValue else { return }
            // (Undo and Redo too: a clip they bring back is read again.)
            func unread(_ cameras: inout [SyncCamera]) { for c in cameras.indices { for i in cameras[c].clips.indices { cameras[c].clips[i].slateChecked = false } } }
            unread(&cameras)
            for k in history.indices { unread(&history[k]) }
            for k in future.indices { unread(&future[k]) }
        }
    }
    /// Proxies of clips that are here as originals: not synced, not sent.
    var proxiesLeftOut: [CameraSync.Probe] = []
    /// While syncing: the places found so far (shown as they come), the clips being listened to, and what just happened.
    var live: [UUID: SyncClip] = [:]
    var listening: Set<UUID> = []
    var liveLine: String?
    var stage: Stage?
    enum Stage: Int, CaseIterable { case reading, listening, matching }
    /// The angle viewer: the moment on the timeline, the camera shown, and the camera heard (nil: the one shown).
    var playhead = 0.0
    var angle: UUID?
    var soundFrom: UUID?
    /// How the cameras were before each nudge or move, for Undo, and after each undone, for Redo (none recorded while syncing).
    private(set) var history: [[SyncCamera]] = []
    private(set) var future: [[SyncCamera]] = []
    private(set) var task: Task<Void, Never>?
    /// Dropped while clips were still being read: read right after (a second drop used to report ffmpeg missing).
    @ObservationIgnored private var pending: [URL] = []
    @ObservationIgnored let cache = SyncCache()
    /// The running sync's events (a stopped run's late ones are dropped).
    @ObservationIgnored private var currentBuffer: LiveBuffer?

    var running: Bool { task != nil }
    /// The cameras as drawn: while syncing, with the places found so far.
    var shown: [SyncCamera] {
        guard !live.isEmpty else { return cameras }
        return cameras.map { camera in
            var camera = camera
            for i in camera.clips.indices { if let found = live[camera.clips[i].id] { camera.clips[i] = found } }
            return camera
        }
    }
    var rate: Double { CameraSyncExport.rate(cameras) }
    var synced: Bool { cameras.contains { $0.clips.contains { $0.start != nil } } }
    var clips: [SyncClip] { cameras.flatMap(\.clips) }

    private var ffmpeg: String? { AppDelegate.shared?.manager.tool("ffmpeg") }
    private var ffprobe: String? { AppDelegate.shared?.manager.tool("ffprobe") }

    /// Reads what was dropped and groups it into cameras (with what's here already: it's grouped again together).
    func add(_ urls: [URL]) {
        guard let ffprobe else { problem = Converting.Failure.noFFmpeg.localizedDescription; return }
        guard task == nil else { pending += urls; return }
        problem = nil
        done = nil
        // (Proxies set aside aren't read again either.)
        let known = clips + proxiesLeftOut.map(\.clip)
        task = Task {
            status = String(localized: "Reading the clips")
            stage = .reading
            let found = await Task.detached { CameraSync.files(in: urls) }.value
            var probes: [CameraSync.Probe] = []
            for (number, item) in found.enumerated() where !known.contains(where: { $0.path == item.file.path }) {
                if Task.isCancelled { break }
                share = Double(number) / Double(max(found.count, 1))
                if let probe = await Task.detached(operation: { CameraSync.probe(item.file, root: item.root, ffprobe: ffprobe) }).value { probes.append(probe) }
            }
            guard !Task.isCancelled else { return }
            let before = self.cameras
            probes = leaveOutProxies(probes)
            // New clips join the camera they belong to; the rest make new cameras.
            var cameras = self.cameras
            for camera in CameraSync.group(probes) {
                if let index = cameras.firstIndex(where: { $0.key == camera.key }) { cameras[index].clips += camera.clips } else { cameras.append(camera) }
            }
            // Undo would take the new clips away again (or bring back one just set aside as a proxy).
            if cameras != before { history = []; future = [] }
            self.cameras = cameras
            if found.isEmpty { problem = String(localized: "No clips in what was dropped.") }
            finish()
        }
    }

    /// Proxies whose original is here too are left out (kept aside, played instead of the original); a proxy
    /// alone stays, marked. Clips already here that turn out to be proxies of new ones move aside too.
    private func leaveOutProxies(_ probes: [CameraSync.Probe]) -> [CameraSync.Probe] {
        let all = clips + probes.map(\.clip)
        let pairs = CameraSync.proxies(all)
        let paths = Dictionary(all.map { ($0.id, $0.path) }, uniquingKeysWith: { a, _ in a })
        var proxyOf: [UUID: String] = [:]
        for (proxy, original) in pairs where proxyOf[original] == nil { proxyOf[original] = paths[proxy] }
        for c in cameras.indices {
            for clip in cameras[c].clips where pairs[clip.id] != nil {
                proxiesLeftOut.append(CameraSync.Probe(clip: clip, root: clip.file.deletingLastPathComponent()))
            }
            cameras[c].clips.removeAll { pairs[$0.id] != nil }
            for i in cameras[c].clips.indices { if let proxy = proxyOf[cameras[c].clips[i].id] { cameras[c].clips[i].proxy = proxy } }
        }
        cameras.removeAll { $0.clips.isEmpty }
        proxiesLeftOut += probes.filter { pairs[$0.clip.id] != nil }
        return probes.filter { pairs[$0.clip.id] == nil }.map { probe in
            var probe = probe
            probe.clip.proxy = proxyOf[probe.clip.id]
            probe.clip.isProxy = CameraSync.proxyLook(probe.clip) > 0
            return probe
        }
    }

    /// The proxies left out, back in as cameras of their own.
    func includeProxies() {
        guard task == nil else { return }
        history = []
        future = []
        cameras += CameraSync.group(proxiesLeftOut)
        proxiesLeftOut = []
    }

    /// Syncs everything not locked, or only `only` (everything else stays where it is).
    func sync(only: UUID? = nil) {
        guard task == nil, let ffmpeg else { if ffmpeg == nil { problem = Converting.Failure.noFFmpeg.localizedDescription }; return }
        problem = nil
        done = nil
        live = [:]
        listening = []
        stage = .listening
        var input = cameras
        // One clip: the others held where they are for this run.
        let held = Set(clips.filter { only != nil && $0.id != only && $0.start != nil && !$0.locked }.map(\.id))
        for c in input.indices { for i in input[c].clips.indices where held.contains(input[c].clips[i].id) { input[c].clips[i].locked = true } }
        if let only { for c in input.indices { for i in input[c].clips.indices where input[c].clips[i].id == only { input[c].clips[i].locked = false } } }
        let cache = cache, audioFirst = audioFirst, shownTimecode = shownTimecode
        let buffer = LiveBuffer()
        currentBuffer = buffer
        // What's found is shown about ten times a second, not on every event.
        let flusher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                self?.apply(buffer.take(), from: buffer)
            }
        }
        let slates = String(localized: "Looking for timecode slates")
        task = Task {
            status = String(localized: "Listening")
            var result = await CameraSync.sync(input, options: .init(ffmpeg: ffmpeg, sound: { cache.sound($0) }, cache: cache, audioFirst: audioFirst,
                                                                     shownTimecode: shownTimecode, live: { buffer.add(.event($0)) })) { share, text in
                buffer.add(.progress(share, text == slates ? .reading : share < 0.4 ? .listening : .matching, text))
            }
            flusher.cancel()
            apply(buffer.take(), from: buffer)
            for c in result.indices { for i in result[c].clips.indices where held.contains(result[c].clips[i].id) { result[c].clips[i].locked = false } }
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.5)) { cameras = result }
            history = []
            future = []
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
        pending = []
        task?.cancel()
        finish()
    }

    private func finish() {
        task = nil
        currentBuffer = nil
        status = nil
        share = 0
        live = [:]
        listening = []
        liveLine = nil
        stage = nil
        // What was dropped while busy (reading or syncing) is read now.
        if !pending.isEmpty {
            let next = pending
            pending = []
            add(next)
        }
    }

    /// What a sync reported since the last look.
    private func apply(_ events: [LiveBuffer.Item], from buffer: LiveBuffer) {
        guard task != nil, buffer === currentBuffer, !events.isEmpty else { return }
        for item in events {
            switch item {
            case .progress(let value, let stage, let text):
                share = value
                self.stage = stage
                if !text.isEmpty { status = text }
            case .event(.listening(let id)): listening.insert(id)
            case .event(.heard(let id)): listening.remove(id)
            case .event(.placed(let clip)):
                live[clip.id] = clip
                if let camera = cameras.first(where: { $0.clips.contains { $0.id == clip.id } }),
                   let number = camera.clips.firstIndex(where: { $0.id == clip.id }) {
                    liveLine = "\(camera.name) · " + String(localized: "clip \(number + 1) of \(camera.clips.count) · matched by sound")
                }
            }
        }
    }

    func clear() {
        guard task == nil else { return }
        history = []
        future = []
        angle = nil
        soundFrom = nil
        playhead = 0
        cameras = []
        selected = nil
        proxiesLeftOut = []
        audioFirst = false
        shownTimecode = false
        done = nil
        problem = nil
        cache.clear()
    }

    private func edit(_ id: UUID, _ change: (inout SyncClip) -> Void) {
        for c in cameras.indices { for i in cameras[c].clips.indices where cameras[c].clips[i].id == id { change(&cameras[c].clips[i]) } }
    }

    /// Keeps how things are for Undo. Nothing can be changed while syncing: false then.
    private func record() -> Bool {
        guard task == nil else { return false }
        history.append(cameras)
        if history.count > 100 { history.removeFirst() }
        future = []
        return true
    }

    var canUndo: Bool { task == nil && !history.isEmpty }
    var canRedo: Bool { task == nil && !future.isEmpty }

    func undo() {
        guard task == nil, let last = history.popLast() else { return }
        future.append(cameras)
        cameras = last
    }

    func redo() {
        guard task == nil, let next = future.popLast() else { return }
        history.append(cameras)
        cameras = next
    }

    /// Moves a clip by whole timeline frames, and holds it there.
    func nudge(_ id: UUID, frames: Int) {
        guard record() else { return }
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

    /// Moves a placed clip along the timeline (dragged), to a whole frame, and holds it there.
    func shift(_ id: UUID, by seconds: Double) {
        let frames = Int((seconds * rate).rounded())
        guard frames != 0, clips.contains(where: { $0.id == id && $0.start != nil }) else { return }
        nudge(id, frames: frames)
    }

    func toggleLock(_ id: UUID) {
        guard record() else { return }
        edit(id) { $0.locked.toggle() }
    }

    /// Into another camera (nil: a camera of its own).
    func move(_ id: UUID, to camera: UUID?) {
        guard let from = cameras.firstIndex(where: { $0.clips.contains { $0.id == id } }),
              let clip = cameras[from].clips.first(where: { $0.id == id }), record() else { return }
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
        guard task == nil, let index = cameras.firstIndex(where: { $0.id == camera }), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
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
        guard task == nil else { return }
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
        guard task == nil else { return }
        let project = CameraSyncExport.project(cameras, name: name)
        ProjectStore.save(project)
        StudioNavigator.shared.open(project)
    }
}

/// Sync Cameras: every camera's clips on lanes, coloured by how sure the sync is; a clip chosen
/// shows beside another angle at the same moment, to nudge or lock.
struct CameraSyncView: View {
    @State private var model = CameraSyncModel.shared
    @State private var dropping = false
    @State private var zoom = 1.0
    @State private var showingProxies = false
    @State private var dragging: (id: UUID, dx: CGFloat)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                        if let stage = model.stage, stage != .reading || model.cameras.isEmpty == false {
                            stages(stage)
                        }
                        Text(model.liveLine ?? status).font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                            .contentTransition(.opacity)
                        Spacer()
                        Button("Stop") { model.stop() }.buttonStyle(StudioFlatButtonStyle())
                    }
                    StudioProgress(share: stageShare)
                }
                if let problem = model.problem { notice(problem, symbol: "exclamationmark.triangle", colour: Design.Studio.warn) }
                if let done = model.done { notice(done, symbol: "checkmark", colour: Design.Studio.good) }
                if !model.proxiesLeftOut.isEmpty { proxiesLine }
                if model.cameras.contains(where: { $0.clips.contains { $0.hasVideo && $0.start != nil } }) || !model.live.isEmpty {
                    SyncAngleViewer(model: model)
                }
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
                Button("Clear", action: model.clear).buttonStyle(StudioFlatButtonStyle()).disabled(model.running)
                HStack(spacing: 6) {
                    Text("Sound first").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                    Toggle("Sound first", isOn: $model.audioFirst).toggleStyle(StudioSwitchStyle())
                }
                .help("For a shoot whose timecode can't be trusted")
                .disabled(model.running)
                HStack(spacing: 6) {
                    Text("Timecode on camera").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                    Toggle("Timecode on camera", isOn: $model.shownTimecode).toggleStyle(StudioSwitchStyle())
                }
                .help("A slate, a timecode app held in frame, or burned-in timecode: read off the picture")
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

    /// Reading · Listening · Matching, the one under way brighter.
    private func stages(_ stage: CameraSyncModel.Stage) -> some View {
        HStack(spacing: 6) {
            ForEach(CameraSyncModel.Stage.allCases, id: \.self) { each in
                if each != .reading { Text(verbatim: "·").foregroundStyle(Design.Studio.textFaint) }
                Group {
                    switch each {
                    case .reading: Text("Reading")
                    case .listening: Text("Listening")
                    case .matching: Text("Matching")
                    }
                }
                .foregroundStyle(each == stage ? Design.Studio.text : each.rawValue < stage.rawValue ? Design.Studio.textQuiet : Design.Studio.textFaint)
            }
        }
        .font(Design.Studio.hint)
    }

    /// How far the stage under way is.
    private var stageShare: Double {
        switch model.stage {
        case .listening: model.share / 0.4
        case .matching: (model.share - 0.4) / 0.6
        default: model.share
        }
    }

    /// One quiet line for the proxies left out, to see or put back.
    private var proxiesLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.down.right").foregroundStyle(Design.Studio.textQuiet)
            Text("Left out \(model.proxiesLeftOut.count) proxies of clips that are here as originals")
                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            Button("Show") { showingProxies.toggle() }
                .buttonStyle(.link).font(Design.Studio.hint)
                .popover(isPresented: $showingProxies) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.proxiesLeftOut, id: \.clip.id) { probe in
                                Text(verbatim: probe.clip.file.deletingLastPathComponent().lastPathComponent + "/" + probe.clip.name)
                                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.text).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .padding(12)
                    }
                    .frame(width: 320, height: min(CGFloat(model.proxiesLeftOut.count) * 20 + 24, 300))
                }
            Button("Include", action: model.includeProxies)
                .buttonStyle(.link).font(Design.Studio.hint).disabled(model.running)
                .help("Sync the proxies as cameras of their own")
            Spacer(minLength: 0)
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
        let cameras = model.shown, clips = cameras.flatMap(\.clips)
        let synced = clips.compactMap(\.start)
        let from = synced.min() ?? 0
        for camera in cameras {
            var next = camera.clips.compactMap(\.end).max().map { $0 + 2 } ?? from
            for clip in camera.clips {
                if let start = clip.start ?? clip.rough { places[clip.id] = start } else { places[clip.id] = next; next += clip.duration + 2 }
            }
        }
        let end = clips.map { (places[$0.id] ?? 0) + $0.duration }.max() ?? 1
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
                    Color.clear.frame(height: 14)
                    ForEach(model.shown) { camera in CameraLabel(model: model, camera: camera).frame(height: 30) }
                }
                .frame(width: 150)
                GeometryReader { geometry in
                    let width = geometry.size.width * zoom
                    let x = { (time: Double) in width * (time - layout.from) / layout.length }
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 6) {
                            ruler(width: width, layout: layout)
                            ForEach(model.shown) { camera in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 6).fill(Design.Studio.panel)
                                    ForEach(camera.clips) { clip in
                                        let place = layout.places[clip.id] ?? 0
                                        clipBox(clip, camera: camera, secondsPerPoint: layout.length / width)
                                            .frame(width: max(width * clip.duration / layout.length, 3), height: 24)
                                            .offset(x: x(place) + (dragging?.id == clip.id ? dragging!.dx : 0))
                                            .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: place)
                                    }
                                }
                                .frame(width: width, height: 30)
                            }
                        }
                        .overlay(alignment: .topLeading) {
                            // The playhead: the moment the viewer shows.
                            Rectangle().fill(Design.Studio.bad).frame(width: 1.5).offset(x: x(model.playhead)).allowsHitTesting(false)
                        }
                    }
                    .scrollIndicators(zoom > 1 ? .visible : .never)
                }
                .frame(height: CGFloat(model.cameras.count) * 36 + 20)
            }
        }
        .padding(16)
        .studioBox()
    }

    /// A thin strip over the lanes to scrub the playhead along.
    private func ruler(width: CGFloat, layout: (places: [UUID: Double], from: Double, length: Double)) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(Design.Studio.raised)
            .frame(width: width, height: 14)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                model.playhead = layout.from + max(0, min(Double(value.location.x / width), 1)) * layout.length
            })
            .help("Drag to move the playhead")
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

    private func clipBox(_ clip: SyncClip, camera: SyncCamera, secondsPerPoint: Double) -> some View {
        let chosen = model.selected == clip.id
        return RoundedRectangle(cornerRadius: 4)
            .fill(Self.colour(clip.quality).opacity(clip.start == nil ? 0.25 : 0.55))
            .overlay {
                RoundedRectangle(cornerRadius: 4).strokeBorder(chosen ? AnyShapeStyle(Design.Brand.pink) : AnyShapeStyle(Color.clear), lineWidth: 2)
            }
            .overlay(alignment: .leading) {
                HStack(spacing: 3) {
                    if model.listening.contains(clip.id) {
                        Image(systemName: "waveform").font(.system(size: 8)).symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                    }
                    if clip.locked { Image(systemName: "lock.fill").font(.system(size: 8)) }
                    if let symbol = Self.symbol(clip) { Image(systemName: symbol).font(.system(size: 8)) }
                    if clip.isProxy {
                        Text("Proxy").font(.system(size: 8, weight: .medium)).padding(.horizontal, 4).frame(height: 13)
                            .background(Design.Studio.raised, in: .capsule).help("Only a proxy of this clip is here")
                    }
                    Text(clip.file.deletingPathExtension().lastPathComponent).lineLimit(1)
                }
                .font(.system(size: 10)).foregroundStyle(Design.Studio.text).padding(.horizontal, 5)
            }
            .clipShape(.rect(cornerRadius: 4))
            .contentShape(.rect)
            .onTapGesture { model.selected = chosen ? nil : clip.id }
            // Dragged along its lane: moved there (to a frame) and held; not while syncing.
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { value in if !model.running, clip.start != nil { dragging = (clip.id, value.translation.width) } }
                .onEnded { value in
                    if dragging?.id == clip.id { model.shift(clip.id, by: Double(value.translation.width) * secondsPerPoint) }
                    dragging = nil
                })
            .help(Text(verbatim: clip.name + " · ") + Self.method(clip) + (clip.start != nil ? Text(verbatim: " · ") + Text(clip.confidence, format: .percent.precision(.fractionLength(0))) : Text(verbatim: "")))
            .contextMenu {
                Button(clip.locked ? "Unlock" : "Lock") { model.toggleLock(clip.id) }.disabled(model.running)
                Button("Sync This Clip Again") { model.sync(only: clip.id) }.disabled(model.running || !model.synced)
                Menu("Move to Camera") {
                    ForEach(model.cameras.filter { $0.id != camera.id }) { other in
                        Button(other.name) { model.move(clip.id, to: other.id) }
                    }
                    Divider()
                    Button("New Camera") { model.move(clip.id, to: nil) }
                }
                .disabled(model.running)
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
                .onSubmit { model.rename(camera.id, name) }.disabled(model.running)
            Text(verbatim: "\(camera.clips.count)").font(Design.Studio.hint).foregroundStyle(Design.Studio.textFaint)
        }
        .onAppear { name = camera.name }
        .onChange(of: camera.name) { name = camera.name }
    }
}

/// A chosen clip: its sync, the nudge (a frame, ten frames), Lock and Sync Again (none of it while syncing).
private struct SyncClipInspector: View {
    let model: CameraSyncModel
    let clip: SyncClip

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
                Group {
                    Button { model.nudge(clip.id, frames: -10) } label: { Image(systemName: "chevron.backward.2") }
                        .help(model.running ? Text("Syncing…") : Text("Ten frames earlier (<)"))
                    Button { model.nudge(clip.id, frames: -1) } label: { Image(systemName: "chevron.left") }
                        .help(model.running ? Text("Syncing…") : Text("A frame earlier (,)"))
                    Button { model.nudge(clip.id, frames: 1) } label: { Image(systemName: "chevron.right") }
                        .help(model.running ? Text("Syncing…") : Text("A frame later (.)"))
                    Button { model.nudge(clip.id, frames: 10) } label: { Image(systemName: "chevron.forward.2") }
                        .help(model.running ? Text("Syncing…") : Text("Ten frames later (>)"))
                    Button { model.toggleLock(clip.id) } label: { Image(systemName: clip.locked ? "lock.fill" : "lock.open") }
                        .help(model.running ? Text("Syncing…") : clip.locked ? Text("Unlock: Sync Again may move it") : Text("Lock: stays where it is on Sync Again"))
                    Button("Sync Again") { model.sync(only: clip.id) }
                        .disabled(!model.synced)
                }
                .buttonStyle(StudioFlatButtonStyle())
                .disabled(model.running)
            }
        }
        .padding(16)
        .studioBox(outline: Design.rgb(0x8E4C64))
    }

}

/// Sync's reports gathered from any thread, taken by the page about ten times a second.
final class LiveBuffer: @unchecked Sendable {
    enum Item: Sendable {
        case progress(Double, CameraSyncModel.Stage, String)
        case event(CameraSync.Live)
    }

    private let lock = NSLock()
    private var items: [Item] = []

    func add(_ item: Item) { lock.withLock { items.append(item) } }
    func take() -> [Item] { lock.withLock { defer { items = [] }; return items } }
}
