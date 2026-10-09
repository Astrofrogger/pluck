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
    @State private var transcript: Transcript?
    @State private var now: Double = 0
    @State private var filter = ""
    @State private var tab: Tab = .transcript
    @State private var observer: Any?

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

    private var cues: [Transcript.Cue] { transcript?.cues() ?? [] }

    var body: some View {
        HSplitView {
            Group {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    ContentUnavailableView("File moved or deleted", systemImage: "questionmark.folder")
                }
            }
            .frame(minWidth: 420, minHeight: 300)

            sidebar
                .frame(minWidth: 280, idealWidth: 340, maxWidth: 480)
        }
        .navigationTitle(transcript?.title ?? URL(fileURLWithPath: target.filePath).deletingPathExtension().lastPathComponent)
        .onAppear(perform: load)
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
                ScrollViewReader { proxy in
                    List(shown) { cue in
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
                        .id(cue.id)
                    }
                    .listStyle(.plain)
                    .onChange(of: current) { _, id in
                        guard filter.isEmpty, let id else { return }
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
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
