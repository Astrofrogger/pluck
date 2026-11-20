import AVKit
import SwiftUI

/// The angle viewer: the synced timeline at the playhead through one camera, large, with every camera
/// small under it (a frame each, fresh whenever it stops), to check the sync by switching angles.
/// Keys: Space, J K L, ← →, 1–9 for the angle, , . a frame and < > ten frames for the chosen clip, ⌘Z ⇧⌘Z.
/// "Shown timecode": the frames each timecode on camera was read from, side by side, to confirm at a glance.
struct SyncAngleViewer: View {
    let model: CameraSyncModel
    @State private var transport = SyncTransport()
    @State private var posters: [UUID: CGImage] = [:]
    /// The angle shown, larger (paused).
    @State private var still: CGImage?
    @State private var checking = Self.startChecking
    /// Opens on Shown timecode (screenshot mode).
    @MainActor static var startChecking = false
    @State private var refresh: Task<Void, Never>?
    @FocusState private var focused: Bool

    /// Cameras with a picture (up to nine, one per number key).
    private var angles: [SyncCamera] { Array(model.shown.filter { $0.clips.contains(where: \.hasVideo) }.prefix(9)) }
    private var current: SyncCamera? { angles.first { $0.id == model.angle } ?? angles.first }
    private var shownClip: SyncClip? { current.flatMap { Self.clip(of: $0, at: model.playhead) } }
    private var soundCamera: SyncCamera? { model.shown.first { $0.id == model.soundFrom } }

    static func clip(of camera: SyncCamera, at time: Double) -> SyncClip? {
        camera.clips.first { clip in clip.start.map { time >= $0 && time < clip.end! } ?? false }
    }

    /// Clips whose timecode was read off the picture.
    private var readClips: [SyncClip] { model.shown.flatMap(\.clips).filter { !$0.shown.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !readClips.isEmpty {
                Picker("", selection: $checking) {
                    Text("Angles").tag(false)
                    Text("Shown timecode").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if checking && !readClips.isEmpty {
                ShownTimecodeCheck(model: model, clips: readClips)
            } else {
                picture
                HStack(spacing: 8) {
                    ForEach(Array(angles.enumerated()), id: \.element.id) { number, camera in thumbnail(camera, number: number + 1) }
                    Spacer(minLength: 0)
                }
            }
            transportBar
        }
        .padding(16)
        .studioBox()
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(action: key)
        .onAppear {
            transport.model = model
            focused = true
            onPicture()
            cue()
        }
        .onDisappear { transport.stop() }
        .onChange(of: model.angle) { cue() }
        .onChange(of: model.soundFrom) { if transport.playing { transport.play(rate: transport.rate) } }
        .onChange(of: shownClip?.start) { cue() }
        .onChange(of: model.playhead) { if !transport.playing { cue() } }
        .onChange(of: model.live.count) { onPicture(); freshPosters() }
        // (Once synced the places move, timecode ones far: the playhead goes where there's a picture.)
        .onChange(of: model.running) { onPicture(); cue() }
        .onChange(of: transport.playing) { if transport.playing { still = nil } else { freshPosters() } }
    }

    // MARK: Picture

    private var picture: some View {
        ZStack {
            Color.black
            if let clip = shownClip {
                if transport.loaded == clip.id && transport.playing {
                    SyncPlayerSurface(player: transport.video)
                } else if let still {
                    Image(decorative: still, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else if transport.loaded == clip.id {
                    SyncPlayerSurface(player: transport.video)
                } else if let poster = current.flatMap({ posters[$0.id] }) {
                    Image(decorative: poster, scale: 1).resizable().aspectRatio(contentMode: .fit)
                }
            } else {
                Text("No picture here").font(Design.Studio.hint).foregroundStyle(Design.Studio.textFaint)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: 380 * 16 / 9, maxHeight: 380)
        .clipShape(.rect(cornerRadius: 8))
        .overlay(alignment: .topLeading) {
            if let current {
                HStack(spacing: 6) {
                    Text(current.name)
                    if let clip = shownClip {
                        Text(verbatim: clip.file.deletingPathExtension().lastPathComponent).foregroundStyle(Design.Studio.textQuiet)
                        if clip.proxy != nil { Text("Proxy").foregroundStyle(Design.Studio.textQuiet).help("Playing its proxy; the original is synced and sent") }
                    }
                }
                .font(Design.Studio.hint).foregroundStyle(Design.Studio.text)
                .padding(.horizontal, 8).frame(height: 22)
                .background(.black.opacity(0.55), in: .capsule)
                .padding(10)
            }
        }
        .frame(maxWidth: .infinity)
        .onTapGesture { focused = true }
    }

    private func thumbnail(_ camera: SyncCamera, number: Int) -> some View {
        let chosen = camera.id == current?.id
        let here = Self.clip(of: camera, at: model.playhead)
        return Button { model.angle = camera.id; focused = true } label: {
            ZStack {
                Color.black
                if here != nil, let poster = posters[camera.id] { Image(decorative: poster, scale: 1).resizable().aspectRatio(contentMode: .fit) }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(width: 112)
            .clipShape(.rect(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5).strokeBorder(chosen ? AnyShapeStyle(Design.Brand.pink) : AnyShapeStyle(Design.Studio.line), lineWidth: chosen ? 2 : 1)
            }
            .overlay(alignment: .bottomLeading) {
                Text(verbatim: "\(number) \(camera.name)").font(.system(size: 9)).foregroundStyle(here == nil ? Design.Studio.textFaint : Design.Studio.text)
                    .lineLimit(1).padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.5), in: .rect(cornerRadius: 3)).padding(4)
            }
            .opacity(here == nil ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .help(here == nil ? Text("Not filming at this moment") : Text(verbatim: camera.name))
    }

    // MARK: Transport

    private var transportBar: some View {
        HStack(spacing: 8) {
            Button { step(-1) } label: { Image(systemName: "backward.frame") }.buttonStyle(StudioFlatButtonStyle()).help("A frame back (←)")
            Button { transport.playing ? transport.pause() : transport.play(rate: 1) } label: { Image(systemName: transport.playing ? "pause.fill" : "play.fill") }
                .buttonStyle(StudioFlatButtonStyle(prominent: true)).help("Play (Space, J K L)")
            Button { step(1) } label: { Image(systemName: "forward.frame") }.buttonStyle(StudioFlatButtonStyle()).help("A frame on (→)")
            Text(verbatim: CameraSyncExport.timecode(Int((model.playhead * model.rate).rounded()), rate: model.rate))
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Design.Studio.text)
            Spacer()
            if model.running { Text("Syncing…").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet) }
            Button("Undo", systemImage: "arrow.uturn.backward", action: model.undo)
                .labelStyle(.iconOnly)
                .buttonStyle(StudioFlatButtonStyle()).keyboardShortcut("z").disabled(!model.canUndo)
                .help(model.running ? Text("Syncing…") : Text("Undo the last nudge or move"))
            Button("Redo", systemImage: "arrow.uturn.forward", action: model.redo)
                .labelStyle(.iconOnly)
                .buttonStyle(StudioFlatButtonStyle()).keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.canRedo)
                .help(model.running ? Text("Syncing…") : Text("Redo"))
            Menu {
                Button("The Angle Shown") { model.soundFrom = nil }
                ForEach(model.shown.filter(\.hasAudio)) { camera in Button(camera.name) { model.soundFrom = camera.id } }
            } label: {
                Label { soundCamera.map { Text(verbatim: $0.name) } ?? Text("Sound: Angle") } icon: { Image(systemName: "speaker.wave.2") }.font(Design.Studio.body)
            }
            .menuStyle(.button).buttonStyle(StudioFlatButtonStyle()).fixedSize()
            .help("The sound heard while playing")
        }
    }

    private func step(_ frames: Int) {
        transport.pause()
        model.playhead += Double(frames) / model.rate
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        let text = press.characters
        switch press.key {
        case .space: transport.playing ? transport.pause() : transport.play(rate: 1); return .handled
        case .leftArrow: step(-1); return .handled
        case .rightArrow: step(1); return .handled
        default: break
        }
        if let digit = Int(text), (1...9).contains(digit) {
            if digit <= angles.count { model.angle = angles[digit - 1].id }
            return .handled
        }
        switch text.lowercased() {
        case "j": transport.play(rate: transport.playing && transport.rate < 0 ? max(transport.rate * 2, -4) : -1); return .handled
        case "k": transport.pause(); return .handled
        case "l": transport.play(rate: transport.playing && transport.rate > 0 ? min(transport.rate * 2, 4) : 1); return .handled
        default: break
        }
        // Nudging the clip shown (nothing changes while syncing).
        let frames = [",": -1, ".": 1, "<": -10, ">": 10][text]
        guard let frames else { return .ignored }
        if let clip = shownClip ?? model.selected.flatMap({ id in model.clips.first { $0.id == id } }) {
            model.selected = clip.id
            model.nudge(clip.id, frames: frames)
        }
        return .handled
    }

    /// The playhead where some angle films, if it's where none does.
    private func onPicture() {
        if !transport.playing, angles.allSatisfy({ Self.clip(of: $0, at: model.playhead) == nil }) { model.playhead = busiestMoment() }
    }

    /// The moment the most cameras film at once (the start of a clip, a second in).
    private func busiestMoment() -> Double {
        let starts = model.shown.flatMap(\.clips).compactMap(\.start).map { $0 + 1 }
        return starts.max { a, b in angles.filter { Self.clip(of: $0, at: a) != nil }.count < angles.filter { Self.clip(of: $0, at: b) != nil }.count } ?? 0
    }

    private func cue() {
        still = nil
        transport.show(shownClip, at: model.playhead, sound: soundCamera.flatMap { Self.clip(of: $0, at: model.playhead) }, soundCamera: model.soundFrom)
        freshPosters()
    }

    /// A frame of every angle at the playhead, a moment after it stops moving (the one shown larger first).
    private func freshPosters() {
        refresh?.cancel()
        let wanted = angles.compactMap { camera in Self.clip(of: camera, at: model.playhead).map { (camera.id, $0) } }
        let time = model.playhead, shown = shownClip
        refresh = Task {
            try? await Task.sleep(for: .milliseconds(80))
            if let shown { let image = await SyncTransport.poster(shown, at: time, width: 1280); if Task.isCancelled { return }; still = image } else { still = nil }
            for (camera, clip) in wanted {
                if Task.isCancelled { return }
                if let image = await SyncTransport.poster(clip, at: time) { posters[camera] = image } else { posters[camera] = nil }
            }
        }
    }
}

/// The players behind the angle viewer: the angle shown (its proxy when there is one), and the sound from another camera if chosen.
@MainActor @Observable
final class SyncTransport {
    let video = AVPlayer()
    @ObservationIgnored private let sound = AVPlayer()
    @ObservationIgnored weak var model: CameraSyncModel?
    private(set) var loaded: UUID?
    private(set) var playing = false
    private(set) var rate: Float = 1
    @ObservationIgnored private var clip: SyncClip?
    @ObservationIgnored private var soundClip: SyncClip?
    @ObservationIgnored private var observer: Any?

    init() {
        video.automaticallyWaitsToMinimizeStalling = false
        sound.automaticallyWaitsToMinimizeStalling = false
    }

    /// What plays: the proxy if there is one, else the file (a RAW file without one doesn't).
    static func playable(_ clip: SyncClip) -> URL? {
        if let proxy = clip.proxy { return URL(fileURLWithPath: proxy) }
        return RawFormats.isRawVideo(clip.file) || !clip.hasVideo ? nil : clip.file
    }

    static func local(_ clip: SyncClip, at time: Double) -> CMTime {
        CMTime(seconds: max(0, (time - (clip.start ?? 0)) / (1 + clip.drift)), preferredTimescale: 48000)
    }

    /// The clip at a timeline moment (and the sound, if from another camera), paused there.
    func show(_ clip: SyncClip?, at time: Double, sound soundClip: SyncClip?, soundCamera: UUID?) {
        let changed = self.clip?.id != clip?.id
        if changed { video.replaceCurrentItem(with: clip.flatMap(Self.playable).map { AVPlayerItem(url: $0) }) }
        self.clip = clip
        loaded = clip.flatMap { Self.playable($0) != nil ? $0.id : nil }
        if self.soundClip?.id != soundClip?.id { sound.replaceCurrentItem(with: soundClip.map { AVPlayerItem(url: $0.proxy.map { URL(fileURLWithPath: $0) } ?? $0.file) }) }
        self.soundClip = soundClip
        video.isMuted = soundCamera != nil
        // Switched while playing: on from the same moment.
        if playing { if changed || soundClip != nil && sound.rate == 0 { play(rate: rate) }; return }
        if let clip { video.seek(to: Self.local(clip, at: time), toleranceBefore: .zero, toleranceAfter: .zero) }
        if let soundClip { sound.seek(to: Self.local(soundClip, at: time), toleranceBefore: .zero, toleranceAfter: .zero) }
    }

    func play(rate: Float) {
        guard let clip, let model else { return }
        // (Backwards only where the file allows it.)
        if rate < 0 && video.currentItem?.canPlayReverse != true { return }
        let time = model.playhead
        video.seek(to: Self.local(clip, at: time), toleranceBefore: .zero, toleranceAfter: .zero)
        if let soundClip { sound.seek(to: Self.local(soundClip, at: time), toleranceBefore: .zero, toleranceAfter: .zero) }
        // Both from the same moment on the host clock, so a sync error is heard as it is.
        let when = CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(seconds: 0.2, preferredTimescale: 600)
        video.setRate(rate, time: .invalid, atHostTime: when)
        if soundClip != nil, rate == 1 { sound.setRate(rate, time: .invalid, atHostTime: when) }
        self.rate = rate
        playing = true
        if observer == nil {
            observer = video.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 25), queue: .main) { [weak self] time in
                MainActor.assumeIsolated { self?.tick(time) }
            }
        }
    }

    private func tick(_ time: CMTime) {
        guard playing, let clip, let start = clip.start, let model else { return }
        let local = time.seconds
        model.playhead = start + local * (1 + clip.drift)
        if local >= clip.duration - 0.05 || local <= 0 && rate < 0 { pause() }
    }

    func pause() {
        video.pause()
        sound.pause()
        playing = false
    }

    func stop() {
        pause()
        if let observer { video.removeTimeObserver(observer) }
        observer = nil
    }

    /// One frame of a clip at a timeline moment, small (its proxy if there is one; RAW through the raw decoder).
    static func poster(_ clip: SyncClip, at time: Double, width: Double = 320) async -> CGImage? {
        await frame(clip, local: Self.local(clip, at: time), width: width)
    }

    /// One frame of a clip at its own time.
    static func frame(_ clip: SyncClip, local: CMTime, width: Double) async -> CGImage? {
        if let url = playable(clip) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.maximumSize = CGSize(width: width, height: width * 9 / 16)
            generator.appliesPreferredTrackTransform = true
            // (The very frame: a timecode check shows the frame it was read from.)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            return try? await generator.image(at: local).image
        }
        guard clip.hasVideo, RawFormats.isRawVideo(clip.file) else { return nil }
        let file = clip.file, fps = clip.fps
        return await Task.detached {
            guard let source = try? RawFormats.open(file) else { return nil }
            defer { source.close() }
            return try? source.displayFrame(Int(local.seconds * fps), scale: width > 640 ? 4 : 8, settings: RawSettings())
        }.value
    }
}

/// Each clip whose timecode was read off its picture: two of the frames it was read from side by side, each
/// with what was read and its frame number, so a wrong reading shows at a glance. Read once only: flagged, to nudge.
private struct ShownTimecodeCheck: View {
    let model: CameraSyncModel
    let clips: [SyncClip]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(clips) { clip in row(clip) }
            }
        }
        .frame(maxHeight: 420)
    }

    /// The first and last readings that agree (the first reading where none do).
    static func pair(_ clip: SyncClip) -> [ShownTimecode] {
        let agreeing = clip.shown.filter(\.agrees)
        guard let first = agreeing.first ?? clip.shown.first else { return [] }
        if let last = agreeing.last, last.frame != first.frame { return [first, last] }
        return [first]
    }

    private func row(_ clip: SyncClip) -> some View {
        let sure = clip.shown.filter(\.agrees).count >= 2
        let chosen = model.selected == clip.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(verbatim: clip.file.deletingPathExtension().lastPathComponent).font(Design.Studio.body).foregroundStyle(Design.Studio.text).lineLimit(1)
                StudioChip(text: sure ? Text("Sure") : Text("Check"), colour: sure ? Design.Studio.good : Design.Studio.warn, tinted: true)
                    .help(sure ? Text("Frames apart read the same timecode") : Text("Read in one frame only: check it, nudge if needed"))
                Spacer()
                if !sure {
                    Button { model.nudge(clip.id, frames: -1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(StudioFlatButtonStyle()).disabled(model.running)
                        .help(model.running ? Text("Syncing…") : Text("A frame earlier (,)"))
                    Button { model.nudge(clip.id, frames: 1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(StudioFlatButtonStyle()).disabled(model.running)
                        .help(model.running ? Text("Syncing…") : Text("A frame later (.)"))
                }
            }
            HStack(spacing: 8) {
                ForEach(Self.pair(clip), id: \.frame) { reading in ShownFrame(clip: clip, reading: reading) }
                Spacer(minLength: 0)
            }
        }
        .padding(8)
        .background(chosen ? Design.Studio.raised : Color.clear, in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .onTapGesture { model.selected = chosen ? nil : clip.id }
    }
}

/// A frame a timecode was read from, with the reading and the frame number over it.
private struct ShownFrame: View {
    let clip: SyncClip
    let reading: ShownTimecode
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.black
            if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit) }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(width: 300)
        .clipShape(.rect(cornerRadius: 6))
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                Text(verbatim: reading.text).font(.system(size: 12, weight: .semibold, design: .monospaced))
                Text("frame \(reading.frame)").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            }
            .foregroundStyle(Design.Studio.text)
            .padding(.horizontal, 8).frame(height: 22)
            .background(.black.opacity(0.6), in: .capsule)
            .padding(6)
        }
        .task(id: reading.frame) {
            image = await SyncTransport.frame(clip, local: CMTime(seconds: (Double(reading.frame) + 0.5) / max(clip.fps, 1), preferredTimescale: 60000), width: 640)
        }
    }
}

/// The picture, without the player's own controls.
struct SyncPlayerSurface: NSViewRepresentable {
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
