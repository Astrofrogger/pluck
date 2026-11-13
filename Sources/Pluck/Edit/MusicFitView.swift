import AVFoundation
import SwiftUI

/// Fit Music to Length: a song in, the same song at an exact length out, cut on phrases with
/// its intro and real ending kept (layout board ToolMusic).
struct MusicFitView: View {
    @Environment(AIStudio.self) private var studio
    @State private var song: URL?
    @State private var minutes = 1
    @State private var seconds = 0
    @State private var status: String?
    @State private var problem: String?
    @State private var done: (file: URL, edit: MusicFit.Edit)?
    @State private var task: Task<Void, Never>?
    /// The chosen song's loudness, for the waveforms.
    @State private var envelope: Envelope?
    @State private var player: AVAudioPlayer?
    @State private var playing = false

    private var target: Double { Double(minutes * 60 + seconds) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Fit Music").font(Design.Studio.pageTitle).foregroundStyle(Design.Studio.text)
                songField
                if let envelope { waveforms(envelope) }
                if let status, let song {
                    row(tile: AnyView(ProgressView().controlSize(.small)), title: Text(song.lastPathComponent), detail: Text(status)) { EmptyView() }
                }
                if let problem {
                    row(tile: AnyView(StudioTile(symbol: "exclamationmark.triangle", colour: Design.Studio.bad)),
                        title: Text("Couldn’t fit this song"), detail: Text(problem)) { EmptyView() }
                }
                if let done {
                    row(tile: AnyView(StudioTile(symbol: "checkmark", colour: Design.Studio.good)),
                        title: Text(done.file.lastPathComponent), detail: Text(describe(done.edit))) {
                        iconButton(playing ? "stop.fill" : "play.fill", label: playing ? "Stop" : "Play") { togglePlay(done.file) }
                        iconButton("folder", label: "Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([done.file])
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
            guard let song else { return }
            let read = await Envelope.read(song)
            guard !Task.isCancelled else { return }
            envelope = read
        }
        .onDisappear { player?.stop() }
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
            HStack(spacing: 2) {
                Image(systemName: "timer").font(.system(size: 13)).foregroundStyle(Design.Studio.textQuiet)
                    .accessibilityHidden(true).padding(.trailing, 4)
                TextField("Minutes", value: $minutes, format: .number)
                    .frame(width: 22).multilineTextAlignment(.trailing)
                Text(verbatim: ":")
                TextField("Seconds", value: $seconds, format: .number.precision(.integerLength(2)))
                    .frame(width: 22)
            }
            .textFieldStyle(.plain)
            .font(.system(size: 15).monospacedDigit())
            .foregroundStyle(Design.Studio.text)
            .labelsHidden()
            .padding(.horizontal, 6)
            .fixedSize()
            .help("The new length, in minutes and seconds")
            Button("Fit", systemImage: "scissors", action: fit)
                .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
                .keyboardShortcut(.defaultAction)
                .disabled(song == nil || target < 5 || task != nil)
        }
        .padding(.leading, 16).padding(.trailing, 8)
        .frame(height: 48)
        .studioBox(outline: song == nil ? Design.Studio.line : Design.rgb(0x8E4C64))
        .disabled(task != nil)
    }

    /// The original with its kept parts bright, and the new version in plum. Shown as soon as a
    /// song is chosen (the original alone, all of it kept); the new one once there's a result.
    private func waveforms(_ envelope: Envelope) -> some View {
        let edit = done?.edit
        let newLength = edit.map { $0.length / $0.tempo }
        let scale = max(envelope.duration, newLength ?? 0)
        func time(_ t: Double) -> String { Duration.seconds(t).formatted(.time(pattern: .minuteSecond)) }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Original · \(time(envelope.duration))").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            WaveformBars(envelope: envelope, scale: scale, pieces: edit?.pieces ?? [0...envelope.duration], tempo: 1, isNew: false)
            if let edit, let newLength {
                Text("New · \(time(newLength))").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).padding(.top, 8)
                WaveformBars(envelope: envelope, scale: scale, pieces: edit.pieces, tempo: edit.tempo, isNew: true)
                HStack(spacing: 18) {
                    legend("Kept", Design.Studio.text)
                    legend("Skipped", Design.Studio.textFaint.opacity(0.5))
                }
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .studioBox()
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

    private func togglePlay(_ file: URL) {
        if playing { player?.stop(); playing = false; return }
        player = try? AVAudioPlayer(contentsOf: file)
        playing = player?.play() ?? false
        if let duration = player?.duration {
            let current = player
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(duration + 0.2))
                if player === current { playing = false }
            }
        }
    }

    private func describe(_ edit: MusicFit.Edit) -> String {
        func time(_ t: Double) -> String { Duration.seconds(t).formatted(.time(pattern: .minuteSecond)) }
        var parts: [String] = []
        if let first = edit.pieces.first, first.lowerBound > 0 {
            parts.append(String(localized: "Starts at \(time(first.lowerBound))."))
        }
        if edit.pieces.count > 1, let first = edit.pieces.first, let second = edit.pieces.last {
            if second.lowerBound > first.upperBound {
                parts.append(String(localized: "Skips \(time(first.upperBound))–\(time(second.lowerBound))."))
            } else {
                let times = edit.pieces.count - 1
                parts.append(String(AttributedString(localized: "Repeats \(time(second.lowerBound))–\(time(first.upperBound)) ^[\(times) time](inflect: true).").characters))
            }
        }
        if edit.fadeOut != nil { parts.append(String(localized: "Too short for the real ending, so it fades out.")) }
        let change = (edit.tempo - 1) * 100
        if abs(change) >= 0.1 {
            parts.append(String(localized: "Tempo \(change > 0 ? "+" : "")\(change.formatted(.number.precision(.fractionLength(1)))) % (pitch unchanged)."))
        }
        return parts.joined(separator: " ")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        song = url
        done = nil
        problem = nil
    }

    private func fit() {
        guard let song, let ffmpeg = studio.toolPath("ffmpeg") else { return }
        problem = nil
        done = nil
        player?.stop(); playing = false
        let target = target
        status = String(localized: "Finding the beat and the phrases…")
        task = Task {
            do {
                let features = AudioFeatures(samples: try await AudioFeatures.samples(of: song, ffmpeg: ffmpeg))
                let map = MusicMap(features: features)
                guard let edit = MusicFit.plan(map: map, features: features, duration: features.duration, target: target) else {
                    throw MusicFit.problem(map: map, target: target)
                }
                status = String(localized: "Writing the new version…")
                let label = Duration.seconds(target).formatted(.time(pattern: .minuteSecond)).replacingOccurrences(of: ":", with: "m") + "s"
                let ext = ["wav", "aif", "aiff", "flac"].contains(song.pathExtension.lowercased()) ? "wav" : "m4a"
                let output = song.deletingLastPathComponent()
                    .appendingPathComponent(song.deletingPathExtension().lastPathComponent + " (\(label))")
                    .appendingPathExtension(ext)
                try await MusicFit.render(edit, input: song, output: output, ffmpeg: ffmpeg)
                done = (output, edit)
            } catch {
                problem = error.localizedDescription
            }
            status = nil
            task = nil
        }
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
                let length = CMBlockBufferGetDataLength(block)
                var floats = [Float](repeating: 0, count: length / 4)
                floats.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
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
