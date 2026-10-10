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
        VStack(alignment: .leading, spacing: 0) {
            controls
                .padding(Design.Spacing.window)
            Divider()
            HSplitView {
                markerList.frame(minWidth: 300)
                transcript.frame(minWidth: 340)
            }
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 600)
        .task {
            guard LocalAI.canTranscribe, #available(macOS 26, *) else { return }
            languages = await OnDeviceSpeech.languages()
            language = language ?? languages.first { $0.language.languageCode == Locale.current.language.languageCode }
                ?? languages.first { $0.language.languageCode?.identifier == "en" }
        }
    }

    // MARK: - Parts

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(symbol: "record.circle", title: Text("Live Recorder"),
                        subtitle: Text("Records a live stream and marks cheers, music and silence as it goes, with a live transcript and highlights for the edit."),
                        subtitleIsName: false)
            HStack(spacing: Design.Spacing.controls) {
                HStack(spacing: Design.Spacing.controls) {
                    Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Paste a live stream link (YouTube, Twitch…)", text: $link)
                        .textFieldStyle(.plain)
                        .onSubmit(record)
                }
                .font(Design.Typography.control)
                .barControl()
                .disabled(session.isRunning)
                if session.isRunning {
                    Button(action: session.stop) { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(BarCapsuleButtonStyle(tint: .red))
                } else {
                    Button(action: record) { Label("Record", systemImage: "record.circle") }
                        .buttonStyle(BarCapsuleButtonStyle())
                        .disabled(Links.validated(link) == nil)
                }
            }
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
                        .frame(maxWidth: 200)
                    }
                }
                Spacer()
            }
            .font(.callout)
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
        VStack(spacing: 8) {
            TextField("Find what was said", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding([.horizontal, .top], 12)
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
                Image(systemName: "record.circle").foregroundStyle(.red).symbolEffect(.pulse).accessibilityHidden(true)
                Text("Recording \(time(Date.now.timeIntervalSince(session.startedAt ?? .now))) · \(ByteCountFormatter.string(fromByteCount: session.bytes, countStyle: .file))")
                    .monospacedDigit()
            case .analysing:
                ProgressView().controlSize(.small)
                Text("Analysing… \(time(session.analysed))").monospacedDigit()
            case .finished:
                Label {
                    Text(String(AttributedString(localized: "^[\(session.events.count) marker](inflect: true), ^[\(session.highlights.count) highlight](inflect: true)").characters))
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).lineLimit(2)
            case .idle:
                Label("Runs on this Mac. Nothing is uploaded.", systemImage: "lock.shield").noteStyle()
            }
            if let problem = session.transcriptionProblem {
                Text(problem).foregroundStyle(.orange).lineLimit(1)
            }
            Spacer()
            if let status { Text(status).foregroundStyle(.secondary).lineLimit(1) }
            if let file = session.file, !session.isRunning {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
            Button("Build in Resolve", action: build)
                .disabled(session.state != .finished || !Resolve.isInstalled)
        }
        .font(.callout)
        .padding(.horizontal, Design.Spacing.window)
        .padding(.vertical, 12)
        // The recording time ticks along.
        .background { if session.state == .recording { TimelineView(.periodic(from: .now, by: 1)) { _ in Color.clear } } }
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
                status = String(localized: "Timeline “\(name)” is in Resolve.")
            } catch {
                status = error.localizedDescription
            }
        }
    }
}
