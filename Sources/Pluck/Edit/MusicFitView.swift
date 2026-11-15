import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Fit Music to Length: a song in, the same song at an exact length out, cut on phrases with
/// its intro and real ending kept (layout board ToolMusic). The start and end are automatic
/// until dragged; a drag elsewhere on the song marks a part to keep.
struct MusicFitView: View {
    @Environment(AIStudio.self) private var studio
    @State private var song: URL?
    @State private var analysed: MusicFit.Song?
    @State private var target: Double = 60
    /// A video whose length (and frame rate) the target came from.
    @State private var video: (name: String, fps: Double)?
    @State private var start: Double?
    @State private var end: Double?
    @State private var keep: [ClosedRange<Double>] = []
    @State private var snap = true
    @State private var status: String?
    @State private var problem: String?
    @State private var plans: [MusicFit.Plan] = []
    @State private var choice = 0
    @State private var output: URL?
    @State private var task: Task<Void, Never>?
    /// The chosen song's loudness, for the waveforms.
    @State private var envelope: Envelope?
    @State private var player: AVAudioPlayer?
    @State private var playing = false
    @State private var dropping = false
    /// A song to open when the view appears (screenshot mode).
    @MainActor static var openFile: URL?

    private var plan: MusicFit.Plan? { plans.indices.contains(choice) && output != nil ? plans[choice] : nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Fit Music").font(Design.Studio.pageTitle).foregroundStyle(Design.Studio.text)
                songField
                if song == nil {
                    StudioEmptyState(symbol: "music.note.list", title: "Drop a song here",
                                     line: "Set the new length above, then Fit. The intro and the ending stay.",
                                     targeted: dropping, button: "Choose Song…", action: choose)
                        .padding(.vertical, 48)
                        .studioDropZone(targeted: dropping)
                        .onTapGesture(perform: choose)
                }
                if let envelope { waveforms(envelope) }
                if let status, let song {
                    row(tile: AnyView(PlumSpinner()), title: Text(song.lastPathComponent), detail: Text(status)) { EmptyView() }
                }
                if let problem {
                    row(tile: AnyView(StudioTile(symbol: "exclamationmark.triangle", colour: Design.Studio.bad)),
                        title: Text("Couldn’t fit this song"), detail: Text(problem)) { EmptyView() }
                }
                if let plan, let output, status == nil {
                    row(tile: AnyView(StudioTile(symbol: "checkmark", colour: Design.Studio.good)),
                        title: Text(output.lastPathComponent), detail: Text(describe(plan))) {
                        if plans.count > 1 {
                            iconButton("chevron.left", label: "Previous fit") { pick(choice - 1) }
                            Text(verbatim: "\(choice + 1)/\(plans.count)").font(Design.Studio.hint.monospacedDigit()).foregroundStyle(Design.Studio.textQuiet)
                            iconButton("chevron.right", label: "Next fit") { pick(choice + 1) }
                        }
                        iconButton(playing ? "stop.fill" : "play.fill", label: playing ? "Stop" : "Play") { togglePlay(output) }
                        iconButton("folder", label: "Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([output])
                        }
                    }
                }
                StudioFootnote(text: "Runs on this Mac")
            }
            .frame(maxWidth: 960)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .studioPanel()
        .task(id: song) {
            envelope = nil
            analysed = nil
            guard let song else { return }
            let read = await Envelope.read(song)
            guard !Task.isCancelled else { return }
            envelope = read
            guard let ffmpeg = studio.toolPath("ffmpeg") else { return }
            status = String(localized: "Finding the beat and the phrases…")
            do {
                let result = try await MusicFit.analyse(song, ffmpeg: ffmpeg)
                guard !Task.isCancelled else { return }
                analysed = result
            } catch {
                problem = error.localizedDescription
            }
            if task == nil { status = nil }
        }
        .onChange(of: start) { stale() }
        .onChange(of: end) { stale() }
        .onChange(of: keep) { stale() }
        .onChange(of: target) { stale() }
        .onAppear { if let url = Self.openFile { Self.openFile = nil; use(url) } }
        .onDisappear { player?.stop() }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            Task {
                guard task == nil, let url = await providers.first?.load(URL.self),
                      let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .audio) || type.conforms(to: .movie) else { return }
                use(url)
            }
            return true
        }
    }

    private var minutesField: Binding<Int> {
        Binding(get: { Int(target) / 60 }, set: { target = Double(max(0, $0) * 60 + Int(target) % 60); video = nil })
    }

    private var secondsField: Binding<Int> {
        Binding(get: { Int(target) % 60 }, set: { target = Double(Int(target) / 60 * 60 + max(0, $0)); video = nil })
    }

    /// The song, the new length and Fit, in one 48 pt field.
    private var songField: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 14))
                .foregroundStyle(song == nil ? Design.Studio.textFaint : Design.Brand.pink)
                .accessibilityHidden(true)
            Group {
                if let song { Text(song.lastPathComponent).foregroundStyle(Design.Studio.text) }
                else { Text("Choose a song").foregroundStyle(Design.Studio.textQuiet) }
            }
            .font(.system(size: 15)).lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(song == nil ? "Choose…" : "Change…", action: choose)
                .buttonStyle(.plain).font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                .padding(.horizontal, 8).frame(height: 28).contentShape(.rect)
            Rectangle().fill(Design.Studio.line).frame(width: 1, height: 18)
            if let video {
                StudioChip(text: Text(verbatim: "\(exact(target)) · \(video.fps.formatted(.number.precision(.fractionLength(0...2)))) fps"), symbol: "film")
                    .help(video.name)
            }
            HStack(spacing: 2) {
                Image(systemName: "timer").font(.system(size: 13)).foregroundStyle(Design.Studio.textQuiet)
                    .accessibilityHidden(true).padding(.trailing, 4)
                TextField("Minutes", value: minutesField, format: .number)
                    .frame(width: 22).multilineTextAlignment(.trailing)
                Text(verbatim: ":")
                TextField("Seconds", value: secondsField, format: .number.precision(.integerLength(2)))
                    .frame(width: 22)
            }
            .textFieldStyle(.plain)
            .font(.system(size: 15).monospacedDigit())
            .foregroundStyle(Design.Studio.text)
            .labelsHidden()
            .padding(.horizontal, 6)
            .fixedSize()
            .help("The new length, in minutes and seconds")
            iconButton("film", label: "Use a video’s length", action: chooseVideo)
            Button("Fit", systemImage: "scissors", action: fit)
                .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
                .keyboardShortcut(.defaultAction)
                .disabled(song == nil || analysed == nil || target < 3 || task != nil)
        }
        .padding(.leading, 16).padding(.trailing, 8)
        .frame(height: 48)
        .studioBox(outline: song == nil ? Design.Studio.line : Design.rgb(0x8E4C64))
        .disabled(task != nil)
    }

    /// The original with its beat grid, the start and end handles, parts to keep, and (after a
    /// fit) what's skipped; then the new version with its joins (click one to hear it).
    private func waveforms(_ envelope: Envelope) -> some View {
        let newLength = plan.map { $0.length / $0.tempo }
        let scale = max(envelope.duration, newLength ?? 0)
        let autoStart = plan?.pieces.first?.lowerBound ?? analysed?.soundStart ?? 0
        let autoEnd = plan?.pieces.last?.upperBound ?? analysed?.soundEnd ?? envelope.duration
        func time(_ t: Double) -> String { Duration.seconds(t).formatted(.time(pattern: .minuteSecond)) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Original · \(time(envelope.duration))").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                Spacer()
                lockButton("Start", locked: start != nil) { start = start == nil ? autoStart : nil }
                lockButton("End", locked: end != nil) { end = end == nil ? autoEnd : nil }
                Button { snap.toggle() } label: {
                    Image(systemName: "metronome").font(.system(size: 12))
                        .foregroundStyle(snap ? Design.Brand.pink : Design.Studio.textFaint)
                        .frame(width: 28, height: 24).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(snap ? "Snaps to the beat" : "Doesn’t snap to the beat")
                .accessibilityLabel(Text("Snap to the beat"))
                .accessibilityValue(Text(snap ? "On" : "Off"))
            }
            SongEditor(envelope: envelope, song: analysed, scale: scale,
                       pieces: plan?.pieces ?? [(start ?? autoStart)...(end ?? autoEnd)],
                       start: $start, end: $end, keep: $keep, autoStart: autoStart, autoEnd: autoEnd, snap: snap)
            if let plan, let newLength {
                Text("New · \(time(newLength))").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).padding(.top, 8)
                WaveformBars(envelope: envelope, scale: scale, pieces: plan.pieces, tempo: plan.tempo, isNew: true)
                    .overlay {
                        GeometryReader { geometry in
                            ForEach(plan.joins, id: \.self) { join in
                                Button { audition(at: join.output) } label: {
                                    Capsule().fill(Design.Studio.text).frame(width: 2, height: 56)
                                        .frame(width: 14, height: 56).contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .help("Hear this join")
                                .accessibilityLabel(Text("Hear the join at \(time(join.output))"))
                                .position(x: geometry.size.width * join.output / max(scale, 0.001), y: geometry.size.height / 2)
                            }
                        }
                    }
                HStack(spacing: 18) {
                    legend("Kept", Design.Studio.text)
                    legend("Skipped", Design.Studio.textFaint.opacity(0.5))
                    legend("Keep", Design.Studio.good.opacity(0.5))
                }
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .studioBox()
    }

    private func lockButton(_ title: LocalizedStringKey, locked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: locked ? "lock.fill" : "lock.open").font(.system(size: 10))
                Text(title)
            }
            .font(Design.Studio.hint)
            .foregroundStyle(locked ? Design.Brand.pink : Design.Studio.textQuiet)
            .padding(.horizontal, 8).frame(height: 22)
            .background(Design.Studio.raised, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(locked ? "Back to automatic" : "Keep it here")
        .accessibilityValue(Text(locked ? "Locked" : "Automatic"))
    }

    private func legend(_ title: LocalizedStringKey, _ colour: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(colour).frame(width: 10, height: 10)
            Text(title)
        }
        .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
    }

    /// A box row: tile, name and one line, then its buttons.
    private func row<Actions: View>(tile: AnyView, title: Text, detail: Text, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 12) {
            tile.frame(width: 40, height: 40).background(Design.Studio.raised, in: .rect(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                title.font(.system(size: 13)).foregroundStyle(Design.Studio.text).lineLimit(1)
                detail.font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions()
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .studioBox()
    }

    private func iconButton(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Design.Studio.textQuiet)
                .frame(width: 28, height: 28).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(Text(label))
        .accessibilityLabel(Text(label))
    }

    private func exact(_ t: Double) -> String {
        "\(Int(t) / 60):" + String(format: "%05.2f", t.truncatingRemainder(dividingBy: 60))
    }

    private func togglePlay(_ file: URL) {
        if playing { player?.stop(); playing = false; return }
        play(file, from: 0, for: nil)
    }

    /// Three seconds around a join of the new version.
    private func audition(at time: Double) {
        guard let output else { return }
        play(output, from: max(0, time - 1.5), for: 3)
    }

    private func play(_ file: URL, from: Double, for length: Double?) {
        player?.stop()
        player = try? AVAudioPlayer(contentsOf: file)
        player?.currentTime = from
        playing = player?.play() ?? false
        guard let duration = player?.duration else { return }
        let current = player
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(length ?? (duration - from + 0.2)))
            if player === current { player?.stop(); playing = false }
        }
    }

    private func describe(_ plan: MusicFit.Plan) -> String {
        var parts = [String(AttributedString(localized: "^[\(plan.joins.count) join](inflect: true)").characters)]
        switch plan.ending {
        case .real: parts.append(String(localized: "the real ending"))
        case .phrase: parts.append(String(localized: "fades out on a phrase"))
        case .chosen: parts.append(String(localized: "ends where you chose"))
        }
        let change = (plan.tempo - 1) * 100
        if abs(change) >= 0.1 {
            parts.append(String(localized: "tempo \(change > 0 ? "+" : "")\(change.formatted(.number.precision(.fractionLength(1)))) %"))
        }
        return parts.joined(separator: " · ")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        use(url)
    }

    private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { return }
            let fps = (try? await asset.loadTracks(withMediaType: .video).first?.load(.nominalFrameRate)).flatMap { $0 } ?? 25
            target = duration.seconds
            video = (url.lastPathComponent, Double(fps > 0 ? fps : 25))
        }
    }

    private func use(_ url: URL) {
        song = url
        start = nil
        end = nil
        keep = []
        plans = []
        output = nil
        problem = nil
    }

    /// A changed length, start, end or kept part: the last fit no longer applies.
    private func stale() {
        guard task == nil else { return }
        plans = []
        output = nil
    }

    private func fit() {
        guard let analysed, let ffmpeg = studio.toolPath("ffmpeg") else { return }
        problem = nil
        player?.stop(); playing = false
        let request = MusicFit.Request(target: target, start: start, end: end, keep: keep)
        task = Task {
            let found = await Task.detached { MusicFit.plans(for: analysed, request) }.value
            if found.isEmpty {
                problem = MusicFit.problem(song: analysed).localizedDescription
                task = nil
                return
            }
            plans = found
            choice = 0
            await write(found[0], ffmpeg: ffmpeg)
            task = nil
        }
    }

    /// Another of the fits (written over the same file).
    private func pick(_ index: Int) {
        guard task == nil, !plans.isEmpty, let ffmpeg = studio.toolPath("ffmpeg") else { return }
        player?.stop(); playing = false
        let index = (index + plans.count) % plans.count
        task = Task {
            await write(plans[index], ffmpeg: ffmpeg)
            choice = index
            task = nil
        }
    }

    private func write(_ plan: MusicFit.Plan, ffmpeg: String) async {
        guard let song, let analysed else { return }
        status = String(localized: "Writing the new version…")
        defer { status = nil }
        let label = Duration.seconds(plan.target).formatted(.time(pattern: .minuteSecond)).replacingOccurrences(of: ":", with: "m") + "s"
        let ext = ["wav", "aif", "aiff", "flac"].contains(song.pathExtension.lowercased()) ? "wav" : "m4a"
        // (An earlier fit of the same length stays: the new one gets "… 2"; another of these fits replaces it.)
        let folder = song.deletingLastPathComponent()
        let wanted = song.deletingPathExtension().lastPathComponent + " (\(label))." + ext
        let file: URL
        if let output, output.deletingLastPathComponent() == folder, output.lastPathComponent.hasPrefix(song.deletingPathExtension().lastPathComponent + " (\(label))") {
            file = output
        } else {
            let taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() })
            file = folder.appendingPathComponent(taken.contains(wanted.lowercased()) ? FileClash.freeName(wanted, taken: taken) : wanted)
        }
        do {
            try await MusicFit.render(plan, song: analysed, input: song, output: file, ffmpeg: ffmpeg)
            output = file
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// The original song to edit on: its waveform, bar lines (phrase lines brighter), parts to keep,
/// and the start and end handles. Dragging a handle moves (and locks) it; dragging elsewhere
/// marks a part to keep; clicking a kept part removes it.
private struct SongEditor: View {
    let envelope: Envelope
    let song: MusicFit.Song?
    let scale: Double
    let pieces: [ClosedRange<Double>]
    @Binding var start: Double?
    @Binding var end: Double?
    @Binding var keep: [ClosedRange<Double>]
    let autoStart: Double
    let autoEnd: Double
    let snap: Bool
    private enum Drag { case start, end, keep(Double) }
    @State private var drag: Drag?
    @State private var marking: ClosedRange<Double>?

    var body: some View {
        GeometryReader { geometry in editor(width: max(geometry.size.width, 1)) }
        .frame(height: 56)
        .help("Drag the ends to choose where it starts and ends. Drag across a part to keep it; click it to remove.")
        .accessibilityHidden(true)
    }

    private func editor(width: CGFloat) -> some View {
            func x(_ t: Double) -> CGFloat { CGFloat(t / max(scale, 0.001)) * width }
            func time(_ x: CGFloat) -> Double { min(max(Double(x / width) * scale, 0), envelope.duration) }
            func snapped(_ t: Double) -> Double { snap ? song.map { MusicFit.snap(t, in: $0) } ?? t : t }
            return ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    if let song {
                        var bars = Path(), phrases = Path()
                        for (index, t) in song.downbeats.enumerated() {
                            let line = Path(CGRect(x: x(t), y: 0, width: 1, height: size.height))
                            if ((index - song.phraseOffset) % 8 + 8) % 8 == 0 { phrases.addPath(line) } else { bars.addPath(line) }
                        }
                        context.fill(bars, with: .color(Design.Studio.line))
                        context.fill(phrases, with: .color(Design.Studio.textFaint))
                    }
                    for range in keep + (marking.map { [$0] } ?? []) {
                        context.fill(Path(roundedRect: CGRect(x: x(range.lowerBound), y: 0, width: x(range.upperBound) - x(range.lowerBound), height: size.height), cornerRadius: 4),
                                     with: .color(Design.Studio.good.opacity(0.18)))
                    }
                }
                WaveformBars(envelope: envelope, scale: scale, pieces: pieces, tempo: 1, isNew: false)
                handle(at: x(start ?? autoStart), locked: start != nil)
                handle(at: x(end ?? autoEnd), locked: end != nil)
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if drag == nil {
                            let at = value.startLocation.x
                            drag = abs(at - x(start ?? autoStart)) < 8 ? .start : abs(at - x(end ?? autoEnd)) < 8 ? .end : .keep(time(at))
                        }
                        let t = snapped(time(value.location.x))
                        switch drag {
                        case .start: start = min(t, (end ?? autoEnd) - 1)
                        case .end: end = max(t, (start ?? autoStart) + 1)
                        case .keep(let from): marking = min(from, t)...max(from, t)
                        case nil: break
                        }
                    }
                    .onEnded { value in
                        if case .keep(let from) = drag {
                            if abs(value.translation.width) < 3 {
                                keep.removeAll { $0.contains(from) }
                            } else if let marking, marking.upperBound - marking.lowerBound > 0.5 {
                                keep.append(marking)
                            }
                        }
                        drag = nil
                        marking = nil
                    }
            )
    }

    private func handle(at x: CGFloat, locked: Bool) -> some View {
        let colour = locked ? Design.Brand.pink : Design.Studio.textQuiet
        return ZStack(alignment: .top) {
            Rectangle().fill(colour).frame(width: 2)
            Circle().fill(colour).frame(width: 9, height: 9).offset(y: -4)
        }
        .frame(width: 9, height: 56)
        .offset(x: x - 4.5)
        .allowsHitTesting(false)
    }
}

/// A song's loudness: the peak of every 50 ms, 0…1.
private struct Envelope: Sendable {
    static let step = 0.05
    var peaks: [Float]
    var duration: Double

    func level(at time: Double) -> Double {
        let index = Int(time / Self.step)
        return peaks.indices.contains(index) ? Double(peaks[index]) : 0
    }

    /// Reads the song (audio or a movie's sound) off the main thread; nil when it has no sound.
    static func read(_ url: URL) async -> Envelope? {
        await Task.detached(priority: .userInitiated) { () -> Envelope? in
            let asset = AVURLAsset(url: url)
            guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
                  let reader = try? AVAssetReader(asset: asset) else { return nil }
            let rate = 8000.0
            let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: 1, AVSampleRateKey: rate,
            ])
            guard reader.canAdd(output) else { return nil }
            reader.add(output)
            guard reader.startReading() else { return nil }
            let perPeak = Int(rate * step)
            var peaks: [Float] = []
            var current: Float = 0, count = 0
            while !Task.isCancelled, let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
                // Whole samples only (an empty buffer has no address to copy into).
                var floats = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
                guard !floats.isEmpty else { continue }
                floats.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
                for sample in floats {
                    current = max(current, abs(sample))
                    count += 1
                    if count == perPeak { peaks.append(current); current = 0; count = 0 }
                }
            }
            reader.cancelReading()
            guard !peaks.isEmpty else { return nil }
            let loudest = max(peaks.max() ?? 1, 0.0001)
            return Envelope(peaks: peaks.map { $0 / loudest }, duration: Double(peaks.count) * step)
        }.value
    }
}

/// Bars of a waveform, 3 pt wide with 2 pt between, on a time scale shared by both rows.
/// The original dims what the plan skips; the new one plays the pieces in order, in plum.
private struct WaveformBars: View {
    let envelope: Envelope
    let scale: Double
    let pieces: [ClosedRange<Double>]
    let tempo: Double
    let isNew: Bool

    var body: some View {
        Canvas { context, size in
            let pitch: CGFloat = 5
            let length = isNew ? pieces.reduce(0) { $0 + $1.upperBound - $1.lowerBound } / tempo : envelope.duration
            let width = size.width * min(length / max(scale, 0.001), 1)
            var kept = Path(), skipped = Path()
            var x: CGFloat = 0
            while x + 3 <= width {
                let t = Double(x + 1.5) / Double(size.width) * scale
                let source: Double, on: Bool
                if isNew {
                    source = Self.source(of: t * tempo, in: pieces)
                    on = true
                } else {
                    source = t
                    on = pieces.contains { $0.contains(t) }
                }
                let h = max(0.12, envelope.level(at: source)) * size.height
                let bar = Path(roundedRect: CGRect(x: x, y: (size.height - h) / 2, width: 3, height: h), cornerRadius: 1)
                if on { kept.addPath(bar) } else { skipped.addPath(bar) }
                x += pitch
            }
            if isNew {
                context.fill(kept, with: .linearGradient(Gradient(colors: [Design.Brand.pink, Design.Brand.violet]),
                                                         startPoint: .zero, endPoint: CGPoint(x: max(width, 1), y: 0)))
            } else {
                context.fill(kept, with: .color(Design.Studio.text))
                context.fill(skipped, with: .color(Design.Studio.textFaint.opacity(0.35)))
            }
        }
        .frame(height: 56)
        .accessibilityHidden(true)
    }

    /// Where in the song a moment of the new version comes from.
    static func source(of time: Double, in pieces: [ClosedRange<Double>]) -> Double {
        var left = time
        for piece in pieces {
            let length = piece.upperBound - piece.lowerBound
            if left <= length { return piece.lowerBound + left }
            left -= length
        }
        return pieces.last?.upperBound ?? time
    }
}
