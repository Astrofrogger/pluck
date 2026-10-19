import SwiftUI
import UniformTypeIdentifiers

/// Live Recorder: record a live stream (or open a file), watch markers and the transcript come
/// in, search what was said, and build a marked-up timeline in DaVinci Resolve.
struct LiveRecorderView: View {
    @State private var session = LiveRecorderView.shared
    @State private var link = ""
    @AppStorage("liveFromStart") private var fromStart = false
    @AppStorage("liveTranscribe") private var transcribe = true
    @State private var languages: [Locale] = []
    @State private var language: Locale?
    @State private var search = ""
    @State private var status: String?

    /// One session for the app, so a recording keeps going when the window closes.
    @MainActor static let shared = LiveSession()

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            controls
            HStack(alignment: .top, spacing: Design.Spacing.section) {
                Pane { markerList }.frame(minWidth: 300)
                Pane { transcript }.frame(minWidth: 340)
            }
            footer
        }
        .padding(Design.Spacing.window)
        .frame(minWidth: 820, minHeight: 600)
        .task {
            guard LocalAI.canTranscribe, #available(macOS 26, *) else { return }
            languages = await OnDeviceSpeech.languages()
            language = language ?? languages.first { $0.language.languageCode == Locale.current.language.languageCode }
                ?? languages.first { $0.language.languageCode?.identifier == "en" }
        }
        // The recording time ticks along.
        .background { if session.state == .recording { TimelineView(.periodic(from: .now, by: 1)) { _ in Color.clear } } }
    }

    // MARK: - Parts

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            InputBar(symbol: "dot.radiowaves.left.and.right", prompt: Text("Paste a live stream link (YouTube, Twitch…)"),
                     text: $link, onSubmit: record) {
                if session.isRunning {
                    Button(action: session.stop) { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(BarCapsuleButtonStyle(tint: .red))
                } else {
                    Button(action: record) { Label("Record", systemImage: "record.circle") }
                        .buttonStyle(BarCapsuleButtonStyle())
                        .disabled(Links.validated(link) == nil)
                }
            }
            .help("Records a live stream and marks cheers, music and silence as it goes, with a live transcript and highlights for the edit.")
            HStack(spacing: 16) {
                Toggle("From the start of the stream", isOn: $fromStart)
                    .help("YouTube streams can be recorded from where they began, not just from now")
                if LocalAI.canTranscribe {
                    Toggle("Transcribe", isOn: $transcribe)
                    if transcribe {
                        Picker("Spoken language", selection: $language) {
                            ForEach(languages, id: \.identifier) { locale in
                                Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier).tag(Optional(locale))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                Spacer()
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.callout)
            .padding(.horizontal, 4)
            .disabled(session.isRunning)
        }
    }

    private var markerList: some View {
        List {
            if !session.highlights.isEmpty {
                Section("Highlights") {
                    ForEach(session.highlights) { highlight in
                        HStack {
                            Image(systemName: "star.fill").foregroundStyle(.red).accessibilityHidden(true)
                            Text(time(highlight.start) + " – " + time(highlight.end)).monospacedDigit()
                            Text(highlight.reason).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Markers") {
                if session.events.isEmpty {
                    Text(session.isRunning ? "Listening…" : "No markers yet.").foregroundStyle(.secondary)
                }
                ForEach(session.events.reversed()) { event in
                    HStack {
                        Image(systemName: event.kind.symbol).frame(width: 20).accessibilityHidden(true)
                        Text(time(event.time)).monospacedDigit()
                        Text(event.kind.label)
                        Spacer()
                        if event.kind == .cheer {
                            Text(String(format: "+%.0f dB", event.strength)).foregroundStyle(.secondary).font(.caption)
                        } else if event.duration > 0 {
                            Text(Format.duration(event.duration)).foregroundStyle(.secondary).font(.caption)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var transcript: some View {
        VStack(spacing: 0) {
            PaneSearchField(prompt: "Find what was said", text: $search)
            List {
                if search.isEmpty {
                    ForEach(Array(session.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline) {
                            Text(time(line.time)).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                            Text(line.text).textSelection(.enabled)
                        }
                    }
                } else {
                    let found = session.find(search)
                    if found.isEmpty { Text("Not said yet.").foregroundStyle(.secondary) }
                    ForEach(Array(found.enumerated()), id: \.offset) { _, hit in
                        HStack(alignment: .firstTextBaseline) {
                            Text(time(hit.time)).monospacedDigit().foregroundStyle(.tint).frame(width: 64, alignment: .leading)
                            Text(hit.line).textSelection(.enabled)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .overlay {
                if session.words.isEmpty {
                    Text(transcribe && LocalAI.canTranscribe ? "The transcript appears here as it’s spoken." : "Transcription is off.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            switch session.state {
            case .recording:
                StatusChip(text: Text("Recording \(time(Date.now.timeIntervalSince(session.startedAt ?? .now))) · \(ByteCountFormatter.string(fromByteCount: session.bytes, countStyle: .file))"),
                           colour: .red)
                    .monospacedDigit()
            case .analysing:
                StatusChip(text: Text("Analysing… \(time(session.analysed))"), colour: .orange, busy: true)
                    .monospacedDigit()
            case .finished:
                StatusChip(text: Text(String(AttributedString(localized: "^[\(session.events.count) marker](inflect: true), ^[\(session.highlights.count) highlight](inflect: true)").characters)))
            case .failed(let message):
                ProblemLabel(text: message).lineLimit(2)
            case .idle:
                PageNote(text: Text("Runs on this Mac. Nothing is uploaded."), symbol: "lock.shield")
                    .fixedSize()
            }
            if let problem = session.transcriptionProblem {
                Text(problem).font(.callout).foregroundStyle(.orange).lineLimit(1)
            }
            Spacer()
            if let status { Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
            if let file = session.file, !session.isRunning {
                RowButton(symbol: "magnifyingglass", label: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
            Button("Build in DaVinci", systemImage: "film.stack", action: build)
                .buttonStyle(GlassCapsuleButtonStyle())
                .disabled(session.state != .finished || !Resolve.isInstalled)
        }
    }

    private func time(_ seconds: Double) -> String {
        Duration.seconds(max(0, seconds.rounded())).formatted(.time(pattern: .hourMinuteSecond))
    }

    // MARK: - Actions

    private func record() {
        guard let valid = Links.validated(link) else { return }
        session.manager = LibraryServer.shared.manager
        session.record(valid, fromStart: fromStart, language: transcribe ? language : nil)
    }

    private func build() {
        status = String(localized: "Building the timeline in DaVinci Resolve…")
        Task {
            do {
                let name = try await session.buildInResolve()
                status = String(localized: "Timeline “\(name)” is in DaVinci.")
            } catch {
                status = error.localizedDescription
            }
        }
    }
}
