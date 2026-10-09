import AVKit
import SwiftUI

/// What the Pluck Player window shows: a file, its transcript, and where to start.
struct PlayerTarget: Codable, Hashable {
    var filePath: String
    var transcriptID: String?
    var start: Double?
    /// "transcript", "summary" or "chapters": the side panel to open on.
    var tab: String?
}

/// Pluck Player: the video (or song) with its local-AI transcript, summary and chapters beside it.
/// Click a line to jump there; the current line follows playback.
struct PlayerView: View {
    let target: PlayerTarget
    @State private var player: AVPlayer?
    @State private var transcript: Transcript? {
        didSet { cues = transcript?.cues() ?? [] }
    }
    @State private var cues: [Transcript.Cue] = []
    @State private var now: Double = 0
    @State private var filter = ""
    @State private var tab: Tab = .transcript
    @State private var observer: Any?
    @State private var findingSpeakers = false
    @State private var speakerProblem: String?
    @State private var renaming: Int?
    @State private var newName = ""
    @Environment(AIStudio.self) private var studio

    /// One colour per speaker, so it's easy to follow who's talking.
    private static let speakerColors: [Color] = [.blue, .orange, .green, .purple]

    private func color(of speaker: Int) -> Color { Self.speakerColors[(speaker - 1) % Self.speakerColors.count] }

    /// Cues where a new speaker starts talking (their name is shown above them).
    private var speakerChanges: Set<Double> {
        var changes: Set<Double> = []
        var previous: Int?
        for cue in cues {
            if let speaker = cue.speaker, speaker != previous { changes.insert(cue.id) }
            previous = cue.speaker ?? previous
        }
        return changes
    }

    enum Tab: String, CaseIterable, Identifiable {
        case transcript, summary, chapters
        var id: String { rawValue }
        var title: String {
            switch self {
            case .transcript: String(localized: "Transcript")
            case .summary: String(localized: "Summary")
            case .chapters: String(localized: "Chapters")
            }
        }
    }

    var body: some View {
        HSplitView {
            Group {
                if let player {
                    PlayerSurface(player: player)
                } else {
                    ContentUnavailableView("File moved or deleted", systemImage: "questionmark.folder")
                }
            }
            .frame(minWidth: 420, minHeight: 300)

            sidebar
                .frame(minWidth: 280, idealWidth: 340, maxWidth: 480)
        }
        .navigationTitle(transcript?.title ?? URL(fileURLWithPath: target.filePath).deletingPathExtension().lastPathComponent)
        .toolbar {
            ToolbarItemGroup {
                Button("Save Frame", systemImage: "camera", action: saveFrame)
                    .help("Save the frame on screen as a full-size picture")
                    .disabled(player == nil)
                Menu("Export Transcript", systemImage: "square.and.arrow.up") {
                    ForEach(TranscriptExport.FileType.allCases) { format in
                        Button(format.label) {
                            if let transcript { TranscriptExport.save(transcript, as: format, nextTo: URL(fileURLWithPath: target.filePath)) }
                        }
                    }
                }
                .help("Save the transcript, summary and chapters as a document")
                .disabled(transcript == nil)
            }
        }
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: TranscriptStore.didSave)) { note in
            guard let id = note.object as? String, id == transcript?.id || transcript == nil,
                  let saved = TranscriptStore.load(id), saved.filePath == target.filePath else { return }
            transcript = saved
        }
        .onDisappear {
            if let observer { player?.removeTimeObserver(observer) }
            player?.pause()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            switch tab {
            case .transcript: transcriptList
            case .summary: summaryView
            case .chapters: chapterList
            }

            Label("Made on this Mac with local AI", systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(8)
        }
    }

    // MARK: - Transcript

    private var transcriptList: some View {
        let shown = filter.isEmpty ? cues : cues.filter { $0.text.localizedStandardContains(filter) }
        let current = cues.last { $0.start <= now + 0.05 }?.id
        return VStack(spacing: 0) {
            TextField("Search in transcript", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            if transcript == nil {
                ContentUnavailableView("No transcript yet", systemImage: "text.bubble",
                                       description: Text("Choose Subtitles & Transcript… from the sparkles menu of the download."))
            } else {
                let changes = speakerChanges
                ScrollViewReader { proxy in
                    List(shown) { cue in
                        if let speaker = cue.speaker, changes.contains(cue.id) || !filter.isEmpty, let transcript {
                            Button {
                                newName = transcript.speakerNames?[String(speaker)] ?? ""
                                renaming = speaker
                            } label: {
                                Label(transcript.speakerName(speaker), systemImage: "person.wave.2.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(color(of: speaker))
                                    .padding(.leading, 52)
                            }
                            .buttonStyle(.plain)
                            .help("Rename this speaker")
                            .listRowSeparator(.hidden)
                        }
                        Button { seek(to: cue.start) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(Format.duration(cue.start))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .trailing)
                                Text(cue.text)
                                    .foregroundStyle(cue.id == current ? Color.accentColor : .primary)
                                    .fontWeight(cue.id == current ? .semibold : .regular)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                        .id(cue.id)
                    }
                    .listStyle(.plain)
                    .onChange(of: current) { _, id in
                        guard filter.isEmpty, let id else { return }
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                speakerBar
            }
        }
        .alert("Rename speaker", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { rename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Used in this transcript, its subtitles and summaries.")
        }
    }

    /// Find Speakers, or how it's going.
    @ViewBuilder
    private var speakerBar: some View {
        if Speakers.isSupported, LocalAI.canTranscribe, let transcript, !transcript.hasSpeakers {
            HStack(spacing: 8) {
                if findingSpeakers {
                    ProgressView().controlSize(.small)
                    Text("Telling speakers apart…").foregroundStyle(.secondary)
                } else if let speakerProblem {
                    Label(speakerProblem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                } else {
                    Button("Find Speakers", systemImage: "person.2.wave.2", action: findSpeakers)
                        .help("Label who says what, with local AI on this Mac (up to four speakers)")
                }
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func findSpeakers() {
        guard #available(macOS 26, *), var current = transcript else { return }
        findingSpeakers = true
        speakerProblem = nil
        let file = URL(fileURLWithPath: target.filePath)
        Task {
            do {
                try await studio.addSpeakers(to: &current, file: file, item: nil)
                transcript = current
            } catch {
                speakerProblem = error.localizedDescription
            }
            findingSpeakers = false
        }
    }

    private func rename() {
        guard var current = transcript, let speaker = renaming else { return }
        var names = current.speakerNames ?? [:]
        names[String(speaker)] = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        current.speakerNames = names
        TranscriptStore.save(current)
        transcript = current
        renaming = nil
    }

    // MARK: - Summary and chapters (filled in by local AI)

    @ViewBuilder
    private var summaryView: some View {
        if let summary = transcript?.summary {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(summary)
                        .textSelection(.enabled)
                    if let points = transcript?.keyPoints, !points.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(points, id: \.self) { point in
                                Label(point, systemImage: "circle.fill")
                                    .labelStyle(BulletLabelStyle())
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("No summary yet", systemImage: "text.badge.star",
                                   description: Text("Choose Summarize from the sparkles menu of the download."))
        }
    }

    @ViewBuilder
    private var chapterList: some View {
        if let chapters = transcript?.chapters, !chapters.isEmpty {
            let current = chapters.last { $0.start <= now + 0.05 }
            List(chapters, id: \.self) { chapter in
                Button { seek(to: chapter.start) } label: {
                    HStack(spacing: 8) {
                        Text(Format.duration(chapter.start))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                        Text(chapter.title)
                            .foregroundStyle(chapter == current ? Color.accentColor : .primary)
                            .fontWeight(chapter == current ? .semibold : .regular)
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        } else {
            ContentUnavailableView("No chapters yet", systemImage: "list.number",
                                   description: Text("Choose Add Chapters from the sparkles menu of the download."))
        }
    }

    // MARK: - Playback

    private func load() {
        if let name = target.tab, let chosen = Tab(rawValue: name) { tab = chosen }
        transcript = target.transcriptID.flatMap(TranscriptStore.load) ?? TranscriptStore.find(forFile: target.filePath)
        let url = URL(fileURLWithPath: target.filePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let player = AVPlayer(url: url)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { time in
            now = time.seconds
        }
        self.player = player
        if let start = target.start { seek(to: start) }
        player.play()
    }

    /// The frame on screen, at full size, saved where the user chooses (next to the video by default).
    private func saveFrame() {
        guard let player else { return }
        player.pause()
        let time = player.currentTime()
        let file = URL(fileURLWithPath: target.filePath)
        Task {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            do {
                let image = try await generator.image(at: time).image
                guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png]
                panel.directoryURL = file.deletingLastPathComponent()
                let stamp = Format.duration(time.seconds).replacingOccurrences(of: ":", with: ".")
                panel.nameFieldStringValue = "\(file.deletingPathExtension().lastPathComponent) (\(stamp)).png"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try png.write(to: url, options: .atomic)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        now = seconds
        player?.play()
    }
}

private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.font(.system(size: 5)).foregroundStyle(.secondary)
            configuration.title
        }
    }
}

/// The video with the standard Mac player controls. AVKit's own view rather than SwiftUI's
/// `VideoPlayer`, which crashes on macOS 27 unless the app links AVKit itself.
private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.allowsPictureInPicturePlayback = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
