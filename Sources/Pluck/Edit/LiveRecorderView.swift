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

    private var canBuild: Bool { session.state == .finished && Resolve.isInstalled }

    var body: some View {
        VStack(spacing: Design.Studio.panelGap) {
            linkPanel
            HStack(spacing: Design.Studio.panelGap) {
                markerPanel
                transcriptPanel
            }
        }
        .font(Design.Studio.body)
        .foregroundStyle(Design.Studio.text)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    if let file = session.file, !session.isRunning {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([file]) } label: {
                            Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(Design.Studio.textQuiet)
                                .frame(width: 28, height: 28).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help("Show in Finder")
                        .accessibilityLabel(Text("Show in Finder"))
                    }
                    Button(action: build) { Label("Build in DaVinci", systemImage: "film").labelStyle(.titleAndIcon) }
                        .buttonStyle(StudioFlatButtonStyle(prominent: canBuild, height: canBuild ? 32 : 28))
                        .disabled(!canBuild)
                }
            }.studioFlat()
        }
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

    private var linkPanel: some View {
        HStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 14))
                .foregroundStyle(session.state == .recording ? Design.Brand.pink : Design.Studio.textQuiet)
                .accessibilityHidden(true)
            TextField(text: $link, prompt: Text("Paste a live stream link (YouTube, Twitch…)").foregroundStyle(Design.Studio.textQuiet)) {
                Text("Live stream link")
            }
            .textFieldStyle(.plain)
            .font(.system(size: 15))
            .onSubmit(record)
            .disabled(session.isRunning)
            stateLine
            if session.isRunning {
                Button(action: session.stop) {
                    Label("Stop", systemImage: "stop").labelStyle(.titleAndIcon)
                        .font(Design.Studio.body)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(Design.Studio.bad, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            } else {
                Button(action: record) { Label("Record", systemImage: "record.circle").labelStyle(.titleAndIcon) }
                    .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
                    .disabled(Links.validated(link) == nil)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 48)
        .studioBox(outline: session.state == .recording ? Self.recordingLine : nil)
        .help("Records a live stream and marks cheers, music and silence as it goes, with a live transcript and highlights for the edit.")
        .studioToolTitle("Live Recorder")
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
        .studioPanel()
    }

    /// The deep plum's first stop: the link field's edge while it records (as on the board).
    private static let recordingLine = Design.rgb(0x8E4C64)

    /// What the session is doing, small, at the end of the link field.
    @ViewBuilder private var stateLine: some View {
        HStack(spacing: 6) {
            switch session.state {
            case .recording:
                Circle().fill(Design.Studio.bad).frame(width: 8, height: 8).accessibilityHidden(true)
                Text("Recording \(time(Date.now.timeIntervalSince(session.startedAt ?? .now))) · \(ByteCountFormatter.string(fromByteCount: session.bytes, countStyle: .file))")
            case .analysing:
                PlumSpinner()
                Text("Analysing… \(time(session.analysed))")
            case .finished:
                Text(String(AttributedString(localized: "^[\(session.events.count) marker](inflect: true), ^[\(session.highlights.count) highlight](inflect: true)").characters))
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Design.Studio.bad).accessibilityHidden(true)
                Text(message).foregroundStyle(Design.Studio.bad).lineLimit(2)
            case .idle:
                Label("Runs on this Mac. Nothing is uploaded.", systemImage: "lock.shield").foregroundStyle(Design.Studio.textFaint)
            }
            if let problem = session.transcriptionProblem {
                Text(verbatim: "·")
                Text(problem).foregroundStyle(Design.Studio.warn).lineLimit(1)
            }
        }
        .font(Design.Studio.hint)
        .foregroundStyle(Design.Studio.textQuiet)
        .monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
    }

    private var markerPanel: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if !session.highlights.isEmpty {
                    heading("Highlights", count: session.highlights.count)
                    ForEach(session.highlights) { highlight in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "star.fill").font(.system(size: 12)).foregroundStyle(Design.Brand.pink).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(time(highlight.start) + " – " + time(highlight.end)).monospacedDigit()
                                Text(highlight.reason).foregroundStyle(Design.Studio.textQuiet)
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 6)
                    }
                }
                heading("Markers", count: session.events.count)
                    .padding(.top, session.highlights.isEmpty ? 0 : 12)
                if session.events.isEmpty {
                    Text(session.isRunning ? "Listening…" : "No markers yet.").foregroundStyle(Design.Studio.textQuiet)
                        .padding(.horizontal, 6)
                }
                ForEach(session.events.reversed()) { event in
                    HStack(spacing: 10) {
                        Image(systemName: event.kind.symbol).font(.system(size: 13)).foregroundStyle(Design.Studio.textQuiet)
                            .frame(width: 16).accessibilityHidden(true)
                        Text(time(event.time)).monospacedDigit().foregroundStyle(Design.Studio.textQuiet).frame(width: 56, alignment: .leading)
                        Text(event.kind.label)
                        Spacer(minLength: 0)
                        Group {
                            if event.kind == .cheer {
                                Text(String(format: "+%.0f dB", event.strength))
                            } else if event.duration > 0 {
                                Text(Format.duration(event.duration))
                            }
                        }
                        .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).monospacedDigit()
                    }
                    .frame(height: 36)
                    .padding(.horizontal, 6)
                }
                if let status {
                    Text(status).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(2)
                        .padding(.horizontal, 6).padding(.top, 12)
                }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 16)
        }
        .frame(width: 380)
        .frame(maxHeight: .infinity)
        .studioPanel()
    }

    private func heading(_ title: LocalizedStringKey, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title).font(Design.Studio.sectionTitle)
            Text(verbatim: "\(count)").foregroundStyle(Design.Studio.textQuiet)
        }
        .padding(.horizontal, 6)
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Text("Transcript").font(Design.Studio.sectionTitle)
                Spacer(minLength: 0)
                HStack(spacing: 14) {
                    QuietSwitch(title: "From the start", isOn: $fromStart)
                        .help("YouTube streams can be recorded from where they began, not just from now")
                    if LocalAI.canTranscribe {
                        HStack(spacing: 0) {
                            QuietSwitch(title: "Transcribe", isOn: $transcribe)
                            if transcribe { languageMenu }
                        }
                    }
                }
                .disabled(session.isRunning)
                SearchBox(prompt: "Find what was said", text: $search).frame(width: 240)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if search.isEmpty {
                        // Newest first, as it comes in.
                        ForEach(Array(session.lines.enumerated().reversed()), id: \.offset) { _, line in
                            lineRow(line.time, line.text, highlighted: false)
                        }
                    } else {
                        let found = session.find(search)
                        if found.isEmpty { Text("Not said yet.").foregroundStyle(Design.Studio.textQuiet) }
                        ForEach(Array(found.enumerated()), id: \.offset) { _, hit in
                            lineRow(hit.time, hit.line, highlighted: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay {
                if session.words.isEmpty, search.isEmpty, session.state == .idle {
                    StudioEmptyState(symbol: "dot.radiowaves.left.and.right", title: "Nothing recorded yet",
                                     line: "Paste a live stream link above, then Record.")
                } else if session.words.isEmpty, search.isEmpty {
                    Text(transcribe && LocalAI.canTranscribe ? "The transcript appears here as it’s spoken." : "Transcription is off.")
                        .foregroundStyle(Design.Studio.textQuiet)
                }
            }
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .studioPanel()
    }

    private func lineRow(_ seconds: Double, _ text: String, highlighted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(time(seconds)).monospacedDigit().foregroundStyle(highlighted ? Design.Brand.pink : Design.Studio.textQuiet)
                .frame(width: 56, alignment: .leading)
            Text(text).textSelection(.enabled).lineSpacing(3)
        }
        .padding(.vertical, 7)
    }

    private var languageMenu: some View {
        Menu {
            Picker("Spoken language", selection: $language) {
                ForEach(languages, id: \.identifier) { locale in
                    Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier).tag(Optional(locale))
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Text(verbatim: language.flatMap { Locale.current.localizedString(forIdentifier: $0.identifier) } ?? "")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Design.Studio.textQuiet)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("Spoken language"))
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

/// A switch with its name in quiet grey on the right (the transcript header's switches).
private struct QuietSwitch: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle(title, isOn: $isOn).toggleStyle(StudioSwitchStyle())
            Text(title).foregroundStyle(Design.Studio.textQuiet)
        }
        .frame(height: 28)
        .contentShape(.rect)
        .onTapGesture { isOn.toggle() }
    }
}

/// A panel's search field: a dark 30 pt box with a magnifier.
private struct SearchBox: View {
    let prompt: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Design.Studio.textQuiet)
            TextField(text: $text, prompt: Text(prompt).foregroundStyle(Design.Studio.textQuiet)) { Text(prompt) }
                .textFieldStyle(.plain)
                .font(Design.Studio.body)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Design.Studio.textQuiet) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Clear"))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Design.Studio.backdrop, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
    }
}
