#if STUDIO
import SwiftUI
import Translation

/// Local AI in the Editor's sidebar. The Transcript tab: what's said, to read along, jump with and
/// set the range by. The Local AI tab: the best moments and filler words, found and marked on the
/// timeline (filler words cut out in one go), and Pluck's AI tools for this file.
struct EditorAIPanel: View {
    enum Part { case transcript, ai, subtitles }

    @Bindable var model: EditorModel
    let part: Part
    @Environment(AIStudio.self) private var ai
    @Environment(DownloadManager.self) private var manager
    @State private var transcript: Transcript?
    @State private var cues: [Transcript.Cue] = []
    @State private var search = ""
    @State private var anchor: Transcript.Cue?
    @State private var item: DownloadItem?
    @State private var finding = false
    @State private var problem: String?
    /// The sentence the transcript list is scrolled to.
    @State private var scrolledCue: Double?
    /// A tool's window open over the Editor.
    @State private var open: EditorToolSheet?
    /// Subtitles were asked for before there was a transcript: made once it's there.
    @State private var makeSubtitlesWhenTranscribed = false
    /// The Transcript tab shows the words or local AI's summary.
    @AppStorage("editorTranscriptView") private var transcriptView = "words"
    @State private var renaming: Int?
    @State private var newName = ""
    @State private var findingSpeakers = false
    @State private var speakerProblem: String?
    @State private var findingStory = false
    @State private var storyProgress = 0.0
    @State private var storyProblem: String?
    /// What the story is about, to steer the choice (optional).
    @AppStorage("storyFocus") private var storyFocus = ""
    /// The language the transcript is read in ("" for as spoken): translated on this Mac.
    @AppStorage("transcriptLanguage") private var shownLanguage = ""
    @State private var translating = false
    @State private var translateProblem: String?
    /// Set to start a translation (macOS asks to download the language first if needed).
    @State private var translationRequest: TranslationRequest?

    var body: some View {
        Group {
            switch part {
            case .transcript: transcriptTab
            case .ai: aiTab
            case .subtitles: subtitlesTab
            }
        }
        .task {
            load()
            // Screenshots: -PluckScreenshotFind YES finds the best moments and filler words straight away.
            if part == .subtitles, ScreenshotMode.scene == "editor", UserDefaults.standard.bool(forKey: "PluckScreenshotSubtitles"),
               transcript != nil, model.subtitles.isEmpty {
                makeSubtitles()
            }
            // Screenshots: -PluckScreenshotStory YES finds the story straight away.
            if part == .transcript, ScreenshotMode.scene == "editor", UserDefaults.standard.bool(forKey: "PluckScreenshotStory"),
               transcript != nil, storyBeats.isEmpty {
                findStory()
            }
            if part == .ai, ScreenshotMode.scene == "editor", UserDefaults.standard.bool(forKey: "PluckScreenshotFind"), transcript != nil {
                findMoments()
                findFillers()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: TranscriptStore.didSave)) { _ in load() }
        .modifier(TranslationRunner(request: translationRequest) { session in
            if #available(macOS 26, *), let session = session as? TranslationSession { await translate(with: session) }
        })
        .sheet(item: $open) { EditorToolSheetContent(sheet: $0) }
    }

    private func load() {
        guard let found = TranscriptStore.find(forFile: model.file.path) else { return }
        transcript = found
        if makeSubtitlesWhenTranscribed, model.subtitles.isEmpty {
            makeSubtitlesWhenTranscribed = false
            makeSubtitles()
        }
        cues = found.cues(maxCharacters: 90, maxDuration: 6)
        showStoryOnTimeline()
        translateIfNeeded()
        // Chapters local AI made, when the file has none of its own.
        if let chapters = found.chapters, !chapters.isEmpty, !model.markers.contains(where: { $0.kind == .chapter }) {
            model.replaceMarkers(.chapter, with: chapters.map { EditorMarker(kind: .chapter, start: $0.start, title: $0.title) })
        }
    }

    /// This file as an item in Pluck's list, which the AI tools work on.
    private func fileItem() -> DownloadItem? {
        if let item { return item }
        let found = manager.items.first { $0.existingFile?.path == model.file.path } ?? manager.addLocalFiles([model.file]).first
        item = found
        return found
    }

    // MARK: - Transcript

    private var shownCues: [Transcript.Cue] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return cues }
        return cues.filter { text(of: $0).localizedStandardContains(query) }
    }

    // MARK: Translation

    /// The language the transcript was spoken in ("fr").
    private var spokenLanguage: String {
        transcript.map { Locale(identifier: $0.language).language.languageCode?.identifier ?? $0.language } ?? ""
    }

    /// The translation being shown, if one is chosen and made.
    private var translation: Transcript.Translation? {
        guard !shownLanguage.isEmpty, shownLanguage != spokenLanguage else { return nil }
        return transcript?.translations?[shownLanguage]
    }

    /// A line as it's shown: translated when a translation is chosen.
    private func text(of cue: Transcript.Cue) -> String {
        guard let lines = translation?.lines, !lines.isEmpty else { return cue.text }
        // The lines are in time order: a binary search, not a scan per line (long interviews).
        var low = 0, high = lines.count - 1
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].s < cue.start - 0.005 { low = middle + 1 } else { high = middle }
        }
        return abs(lines[low].s - cue.start) < 0.01 ? lines[low].t : cue.text
    }

    private static let languages = ["en", "nl", "fr", "de", "es", "it", "pt", "ja", "ko", "zh-Hans"]

    private func name(of code: String) -> String {
        Locale.current.localizedString(forIdentifier: code)?.localizedCapitalized ?? code
    }

    private var languageMenu: some View {
        Menu {
            Button {
                shownLanguage = ""
            } label: {
                Label(String(localized: "As Spoken (\(name(of: spokenLanguage)))"), systemImage: shownLanguage.isEmpty ? "checkmark" : "")
            }
            Divider()
            ForEach(Self.languages.filter { $0 != spokenLanguage }, id: \.self) { code in
                Button {
                    shownLanguage = code
                    translateIfNeeded()
                } label: {
                    Label(name(of: code), systemImage: shownLanguage == code ? "checkmark" : "")
                }
            }
        } label: {
            Image(systemName: "globe")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Read the transcript, summary and story in another language, translated on this Mac")
    }

    /// Translates the transcript (and its summary) into the chosen language, when it isn't yet.
    private func translateIfNeeded() {
        guard #available(macOS 26, *), let transcript, !shownLanguage.isEmpty, shownLanguage != spokenLanguage, !translating else { return }
        let existing = transcript.translations?[shownLanguage]
        let summaryMissing = transcript.summary != nil && existing?.summary == nil
        guard existing == nil || summaryMissing else { return }
        translateProblem = nil
        translationRequest = TranslationRequest(source: transcript.language, target: shownLanguage)
    }

    @available(macOS 26, *)
    private func translate(with session: TranslationSession) async {
        guard let transcript, let target = translationRequest?.target else { return }
        translating = true
        defer { translating = false; translationRequest = nil }
        var requests = cues.enumerated().map { TranslationSession.Request(sourceText: $0.element.text, clientIdentifier: "c\($0.offset)") }
        if let summary = transcript.summary { requests.append(.init(sourceText: summary, clientIdentifier: "s")) }
        for (index, point) in (transcript.keyPoints ?? []).enumerated() { requests.append(.init(sourceText: point, clientIdentifier: "k\(index)")) }
        do {
            try await session.prepareTranslation()
            let responses = try await session.translations(from: requests)
            var lines = cues.map { Transcript.Translation.Line(s: $0.start, e: $0.end, t: $0.text) }
            var summary: String?
            var points = transcript.keyPoints ?? []
            for response in responses {
                guard let id = response.clientIdentifier else { continue }
                if id == "s" { summary = response.targetText }
                else if id.hasPrefix("c"), let index = Int(id.dropFirst()), lines.indices.contains(index) { lines[index].t = response.targetText }
                else if id.hasPrefix("k"), let index = Int(id.dropFirst()), points.indices.contains(index) { points[index] = response.targetText }
            }
            var updated = transcript
            var all = updated.translations ?? [:]
            all[target] = Transcript.Translation(lines: lines, summary: summary, keyPoints: transcript.keyPoints == nil ? nil : points)
            updated.translations = all
            TranscriptStore.save(updated)
            self.transcript = updated
        } catch {
            translateProblem = error.localizedDescription
        }
    }

    private var current: Transcript.Cue? { cues.last { $0.start <= model.time + 0.05 } }

    @ViewBuilder private var transcriptTab: some View {
        if transcript == nil {
            VStack(alignment: .leading, spacing: 10) {
                if let status = item?.aiStatus {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(status).foregroundStyle(.secondary)
                    }
                } else if LocalAI.canTranscribe {
                    Text("Writes down what’s said, on this Mac, so you can cut by the words.").foregroundStyle(.secondary)
                    Button("Transcribe", systemImage: "waveform") {
                        if let item = fileItem() { ai.transcribeInBackground([item]) }
                    }
                    .buttonStyle(GlassCapsuleButtonStyle())
                } else {
                    Text("Transcripts need macOS 26 and Apple Intelligence.").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Picker("Show", selection: $transcriptView) {
                        Text("Words").tag("words")
                        Text("Story").tag("story")
                        Text("Summary").tag("summary")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    languageMenu
                    Menu {
                        ForEach(TranscriptExport.FileType.allCases) { format in
                            Button(format.label) {
                                if let transcript { TranscriptExport.save(transcript, as: format, nextTo: model.file) }
                            }
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Save the transcript, summary and chapters as a document, next to the file")
                }
                .padding(.horizontal, 8)
                .padding(.bottom, translating || translateProblem != nil ? 4 : 8)
                if translating {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Translating into \(name(of: shownLanguage))…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
                } else if let translateProblem {
                    Text(translateProblem).font(.caption).foregroundStyle(.orange).padding(.horizontal, 12).padding(.bottom, 6)
                }
                switch transcriptView {
                case "summary": summaryView
                case "story": storyView
                default: wordsView
                }
            }
            .alert("Rename speaker", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Rename") { renameSpeaker() }
                Button("Cancel", role: .cancel) { renaming = nil }
            } message: {
                Text("Used in this transcript, its subtitles and summaries.")
            }
        }
    }

    private var wordsView: some View {
        VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Find what was said", text: $search).textFieldStyle(.plain)
                }
                .font(.callout)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: Design.Radius.small).fill(.fill.tertiary))
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let changes = speakerChanges
                        ForEach(shownCues) { cue in
                            if let speaker = cue.speaker, changes.contains(cue.id) || !search.isEmpty, let transcript {
                                Button {
                                    newName = transcript.speakerNames?[String(speaker)] ?? ""
                                    renaming = speaker
                                } label: {
                                    Label(transcript.speakerName(speaker), systemImage: "person.wave.2.fill")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(color(of: speaker))
                                }
                                .buttonStyle(.plain)
                                .padding(.leading, 46)
                                .padding(.top, 6)
                                .help("Rename this speaker")
                            }
                            cueRow(cue)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 6)
                }
                .scrollPosition(id: $scrolledCue, anchor: .center)
                .onChange(of: current?.id) { _, id in
                    if model.isPlaying, search.isEmpty, let id { withAnimation { scrolledCue = id } }
                }
                speakerBar
                Text("Click to go there. ⇧-click another line to make the range.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(8)
        }
    }

    // MARK: Speakers

    private static let speakerColors: [Color] = [.blue, .orange, .green, .purple]

    private func color(of speaker: Int) -> Color { Self.speakerColors[(speaker - 1) % Self.speakerColors.count] }

    /// Lines where a new speaker starts talking (their name is shown above them).
    private var speakerChanges: Set<Double> {
        var changes: Set<Double> = []
        var previous: Int?
        for cue in cues {
            if let speaker = cue.speaker, speaker != previous { changes.insert(cue.id) }
            previous = cue.speaker ?? previous
        }
        return changes
    }

    /// Find Speakers, or how it's going.
    @ViewBuilder private var speakerBar: some View {
        if Speakers.isSupported, LocalAI.canTranscribe, let transcript, !transcript.hasSpeakers {
            HStack(spacing: 6) {
                if findingSpeakers {
                    ProgressView().controlSize(.small)
                    Text("Telling speakers apart…").foregroundStyle(.secondary)
                } else if let speakerProblem {
                    Label(speakerProblem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Button("Find Speakers", systemImage: "person.2.wave.2", action: findSpeakers)
                        .buttonStyle(.link)
                        .help("Label who says what, with local AI on this Mac (up to four speakers)")
                }
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.top, 6)
        }
    }

    private func findSpeakers() {
        guard #available(macOS 26, *), var current = transcript else { return }
        findingSpeakers = true
        speakerProblem = nil
        let file = model.file
        Task {
            do {
                try await ai.addSpeakers(to: &current, file: file, item: nil)
                transcript = current
                load()
            } catch {
                speakerProblem = error.localizedDescription
            }
            findingSpeakers = false
        }
    }

    private func renameSpeaker() {
        guard var current = transcript, let speaker = renaming else { return }
        var names = current.speakerNames ?? [:]
        names[String(speaker)] = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        current.speakerNames = names
        TranscriptStore.save(current)
        transcript = current
        renaming = nil
    }

    // MARK: Story

    private var storyBeats: [StoryBeat] { transcript?.storyBeats ?? [] }

    @ViewBuilder private var storyView: some View {
        if storyBeats.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Marks the passages to build a story with: a hook, context, key points, emotion and an ending.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TextField("About (optional): the new building…", text: $storyFocus)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .help("What the story is about: those passages are preferred")
                    if findingStory {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Reading the interview…").font(.caption).foregroundStyle(.secondary)
                            ProgressView(value: storyProgress).controlSize(.small)
                        }
                    } else {
                        Button("Find the Story", systemImage: "text.book.closed", action: findStory)
                            .buttonStyle(BrandButtonStyle(large: false))
                    }
                    if let storyProblem {
                        Text(storyProblem).font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    let kept = storyBeats.filter(\.kept)
                    Text("\(kept.count) of \(storyBeats.count) · \(Format.duration(kept.reduce(0) { $0 + $1.end - $1.start }))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Button("Find Again", action: findStory)
                        Button("Clear", role: .destructive) { saveStory([]) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(findingStory)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                if findingStory {
                    ProgressView(value: storyProgress).controlSize(.small).padding(.horizontal, 12).padding(.bottom, 6)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(storyBeats) { beat in storyRow(beat) }
                    }
                    .padding(.horizontal, 6)
                }
                Button {
                    keepOnlyStory()
                } label: {
                    Label("Keep Only These", systemImage: "scissors").frame(maxWidth: .infinity)
                }
                .buttonStyle(BrandButtonStyle())
                .disabled(!storyBeats.contains(where: \.kept))
                .help("Cut everything else out of the edit, so the ticked passages play one after another (⌘Z undoes it)")
                .padding(12)
            }
        }
    }

    private func storyRow(_ beat: StoryBeat) -> some View {
        let playing = model.time >= beat.start && model.time < beat.end
        return HStack(alignment: .top, spacing: 8) {
            Button { toggle(beat) } label: {
                Image(systemName: beat.kept ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(beat.kept ? beat.role.color : .secondary)
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .help(beat.kept ? "Leave it out of the story" : "Use it in the story")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Label(beat.role.title, systemImage: beat.role.symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(beat.role.color))
                    Spacer(minLength: 4)
                    Text(Format.duration(beat.start)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
                Text(beat.title).font(.callout.weight(.semibold)).lineLimit(2)
                Text(storyQuote(beat)).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .opacity(beat.kept ? 1 : 0.5)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
            .fill(beat.role.color.opacity(playing ? 0.22 : 0.08)))
        .contentShape(.rect)
        .onTapGesture { model.seek(to: beat.start) }
    }

    /// What's said in a passage, to read before choosing it.
    private func storyQuote(_ beat: StoryBeat) -> String {
        let said = cues.filter { $0.start >= beat.start - 0.05 && $0.start < beat.end }.map(text(of:)).joined(separator: " ")
        return "“" + said + "”"
    }

    private func findStory() {
        guard let transcript else { return }
        findingStory = true
        storyProblem = nil
        storyProgress = 0
        let focus = storyFocus
        Task {
            do {
                let beats = try await StoryFinder.find(in: transcript, focus: focus,
                                                       titlesIn: shownLanguage.isEmpty ? nil : shownLanguage) { value in
                    Task { @MainActor in storyProgress = value }
                }
                saveStory(beats)
            } catch {
                storyProblem = error.localizedDescription
            }
            findingStory = false
        }
    }

    private func toggle(_ beat: StoryBeat) {
        var beats = storyBeats
        guard let index = beats.firstIndex(where: { $0.id == beat.id }) else { return }
        beats[index].kept.toggle()
        saveStory(beats)
    }

    private func saveStory(_ beats: [StoryBeat]) {
        guard var current = transcript else { return }
        current.storyBeats = beats.isEmpty ? nil : beats
        TranscriptStore.save(current)
        transcript = current
        showStoryOnTimeline()
    }

    /// The ticked passages as pink bands on the timeline.
    private func showStoryOnTimeline() {
        model.replaceMarkers(.story, with: storyBeats.filter(\.kept).map {
            EditorMarker(kind: .story, start: $0.start, end: $0.end, title: $0.title)
        })
    }

    /// Cuts everything but the ticked passages out of the edit, with a breath around each.
    private func keepOnlyStory() {
        let kept = storyBeats.filter(\.kept).sorted { $0.start < $1.start }
        guard !kept.isEmpty, model.duration > 0 else { return }
        var gaps: [ClosedRange<Double>] = []
        var cursor = 0.0
        for beat in kept {
            let start = max(beat.start - 0.15, 0), end = min(beat.end + 0.25, model.duration)
            if start - cursor > model.frame { gaps.append(cursor...start) }
            cursor = max(cursor, end)
        }
        if model.duration - cursor > model.frame { gaps.append(cursor...model.duration) }
        model.resetEdit()
        model.cutOut(gaps)
        model.seek(to: max(kept[0].start - 0.15, 0))
    }

    // MARK: Summary

    @ViewBuilder private var summaryView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let summary = translation?.summary ?? transcript?.summary {
                    Text(summary)
                        .font(.callout)
                        .textSelection(.enabled)
                    if let points = translation?.keyPoints ?? transcript?.keyPoints, !points.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(points, id: \.self) { point in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Circle().fill(Design.Brand.gradient).frame(width: 5, height: 5)
                                    Text(point).font(.callout).textSelection(.enabled)
                                }
                            }
                        }
                    }
                } else if item?.aiStatus != nil {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(item?.aiStatus ?? String(localized: "Summarizing…")).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                } else {
                    Text("A short summary and the key points, written on this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Summarize", systemImage: "text.badge.star") { run(AIStudio.LanguageAsk.Action.summarize) }
                        .buttonStyle(BrandButtonStyle(large: false))
                }
                if transcript?.chapters?.isEmpty ?? true, item?.aiStatus == nil {
                    Button("Add Chapters", systemImage: "list.number") { run(AIStudio.LanguageAsk.Action.chapters) }
                        .buttonStyle(.link)
                        .font(.callout)
                        .help("Chapters on the timeline, from what's said")
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Summarizing or adding chapters, right here (the transcript reloads when it's saved).
    private func run(_ action: AIStudio.LanguageAsk.Action) {
        guard let item = fileItem() else { return }
        // When the language has to be asked first, a sheet comes up; the transcript reloads when saved.
        ai.start(action, item) { _ in }
    }

    private func cueRow(_ cue: Transcript.Cue) -> some View {
        let inRange = model.hasRange && cue.start >= model.rangeStart - 0.05 && cue.end <= model.rangeEnd + 0.05
        let playing = current?.id == cue.id
        let removed = model.part(at: cue.start + 0.01)?.removed ?? false
        // A passage marked for the story: lit in its role's colour, named where it starts.
        let beat = storyBeats.first { $0.kept && cue.start >= $0.start - 0.05 && cue.start < $0.end - 0.05 }
        return VStack(alignment: .leading, spacing: 2) {
            if let beat, abs(beat.start - cue.start) < 0.3 {
                Label { Text(beat.role.title) + Text(verbatim: " · ") + Text(beat.title) } icon: { Image(systemName: beat.role.symbol) }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(beat.role.color)
                    .lineLimit(1)
                    .padding(.leading, 40)
                    .padding(.top, 4)
            }
            cueLine(cue, playing: playing, removed: removed)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Design.Radius.small)
            .fill(inRange ? Color.yellow.opacity(0.16) : playing ? Color.accentColor.opacity(0.14)
                  : beat.map { $0.role.color.opacity(0.13) } ?? .clear))
        .overlay(alignment: .leading) {
            if let beat { Capsule().fill(beat.role.color).frame(width: 3).padding(.vertical, 2) }
        }
        .contentShape(.rect)
        .onTapGesture {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true, let anchor {
                model.inPoint = model.snappedToFrame(min(anchor.start, cue.start))
                model.outPoint = model.snappedToFrame(max(anchor.end, cue.end))
                model.seek(to: model.rangeStart)
            } else {
                anchor = cue
                model.seek(to: cue.start)
            }
        }
    }

    private func cueLine(_ cue: Transcript.Cue, playing: Bool, removed: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Format.duration(cue.start)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 32, alignment: .leading)
            Text(text(of: cue)).font(.callout)
                .foregroundStyle(playing ? .primary : .secondary)
                .strikethrough(removed, color: .red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Subtitles

    @ViewBuilder private var subtitlesTab: some View {
        if model.subtitles.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Make them from the transcript, or write them line by line.")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if transcript != nil {
                            Button("From the Transcript", systemImage: "captions.bubble") { makeSubtitles() }
                                .buttonStyle(BrandButtonStyle(large: false))
                        }
                        Button("Add a Line", systemImage: "plus") { model.addSubtitle(at: model.time); model.showSubtitles = true }
                            .buttonStyle(GlassCapsuleButtonStyle())
                    }
                    if transcript == nil {
                        Text("Transcribe it first to make them all at once.").font(.caption).foregroundStyle(.secondary)
                    }
                    SidebarSection(title: Text("Names")) { GlossaryEditor() }
                        .padding(.horizontal, -8)
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            EditorSubtitlePanel(model: model, remake: transcript == nil ? nil : { makeSubtitles() })
        }
    }

    private func makeSubtitles() {
        guard let transcript else { return }
        if let translation {
            // In the language the transcript is read in.
            model.subtitles = translation.lines.map {
                SubtitleCue(start: $0.s, end: $0.e, text: Transcript.twoLines(Glossary.correct($0.t, terms: Glossary.shared.terms)))
            }
        } else {
            model.subtitles = transcript.cues(maxCharacters: 84, maxDuration: 6).map {
                // The glossary's names written right.
                SubtitleCue(start: $0.start, end: $0.end, text: Transcript.twoLines(Glossary.correct($0.text, terms: Glossary.shared.terms)))
            }
        }
        model.showSubtitles = true
        model.saveSubtitles()
    }

    // MARK: - Local AI

    private var aiTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SidebarSection(title: Text("Find")) {
                    let moments = model.markers.filter { $0.kind == .moment }
                    let fillers = model.markers.filter { $0.kind == .filler }
                    SidebarRow(symbol: "star", title: Text("Best Moments"), detail: moments.isEmpty ? nil : Text(verbatim: "\(moments.count)")) {
                        Button(moments.isEmpty ? "Find" : "Again") { findMoments() }
                            .buttonStyle(.link)
                            .help("The strongest moments for a short, chosen from what’s said")
                    }
                    SidebarRow(symbol: "text.badge.minus", title: Text("Filler Words"), detail: fillers.isEmpty ? nil : Text(verbatim: "\(fillers.count)")) {
                        if fillers.isEmpty {
                            Button("Find") { findFillers() }
                                .buttonStyle(.link)
                                .help("Every “um”, “uh” and “like”")
                        } else {
                            Button("Cut All") { model.cutOut(fillers.compactMap(\.span)) }
                                .buttonStyle(.link)
                                .help("Cut every filler word out of the edit (⌘Z undoes it)")
                        }
                    }
                    if finding {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Finding the best moments…")
                        }
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                    }
                    if transcript == nil {
                        Text("Needs the transcript first.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                    }
                    if let problem {
                        Text(problem).font(.caption).foregroundStyle(.orange).padding(.horizontal, 8)
                    }
                    ForEach(moments) { moment in
                        SidebarRow(symbol: "star.fill", title: Text(moment.title), detail: Text(Format.duration(moment.start))) { EmptyView() }
                            .onTapGesture { model.select(moment) }
                            .help("Make this the range")
                            .padding(.leading, 14)
                    }
                }
                .disabled(transcript == nil || finding)

                if let status = item?.aiStatus {
                    SidebarSection(title: Text("Working")) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(status).font(.callout)
                            if let progress = item?.aiProgress {
                                ProgressView(value: progress)
                            } else {
                                ProgressView().progressViewStyle(.linear)
                            }
                            Text("The result is saved next to the original.").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 8)
                    }
                }
                SidebarSection(title: Text("Tools")) {
                    ForEach(Tool.allCases.filter(available), id: \.self) { tool in
                        SidebarRow(symbol: symbol(tool), title: Text(title(tool))) {
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .onTapGesture { run(tool) }
                        .opacity(enabled(tool) ? 1 : 0.4)
                        .allowsHitTesting(enabled(tool))
                    }
                    Text("Subtitles and cutting pauses happen in the edit. The other tools save a new file next to the original, on this Mac.")
                        .font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 8).padding(.top, 4)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 12)
        }
    }

    private func findMoments() {
        guard let transcript else { return }
        finding = true
        problem = nil
        Task {
            var options = Shorts.Options()
            options.count = 6
            let moments = await Shorts.moments(in: transcript, options: options)
            model.replaceMarkers(.moment, with: moments.map { EditorMarker(kind: .moment, start: $0.start, end: $0.end, title: $0.title) })
            if moments.isEmpty { problem = String(localized: "No moments found: there’s too little speech in this file.") }
            finding = false
        }
    }

    private func findFillers() {
        guard let transcript else { return }
        let cuts = Tighten.fillerCuts(transcript.words, language: Locale(identifier: transcript.language))
        model.replaceMarkers(.filler, with: cuts.map { EditorMarker(kind: .filler, start: $0.lowerBound, end: $0.upperBound, title: String(localized: "Filler")) })
        problem = cuts.isEmpty ? String(localized: "No filler words found.") : nil
    }

    // MARK: - Tools

    fileprivate enum Tool: CaseIterable {
        case shorts, subtitles, tighten, enhance, background, blur, cleanup, stems
    }

    private func available(_ tool: Tool) -> Bool {
        switch tool {
        case .shorts, .subtitles: LocalAI.canTranscribe
        case .enhance: Enhance.isSupported
        case .cleanup: AudioCleanup.isSupported
        case .stems: Stems.isSupported
        case .tighten, .background, .blur: true
        }
    }

    private func enabled(_ tool: Tool) -> Bool {
        model.hasVideo || ![.shorts, .enhance, .background, .blur].contains(tool)
    }

    private func title(_ tool: Tool) -> LocalizedStringKey {
        switch tool {
        case .shorts: "Make Shorts…"
        case .subtitles: "Subtitles"
        case .tighten: "Cut Pauses & Fillers"
        case .enhance: "Upscale & Smooth…"
        case .background: "New Background…"
        case .blur: "Privacy Blur…"
        case .cleanup: "Clean Up Audio…"
        case .stems: "Separate Stems"
        }
    }

    private func symbol(_ tool: Tool) -> String {
        switch tool {
        case .shorts: "rectangle.portrait.on.rectangle.portrait.angled"
        case .subtitles: "captions.bubble"
        case .tighten: "scissors"
        case .enhance: "sparkles.tv"
        case .background: "person.and.background.dotted"
        case .blur: "eye.slash"
        case .cleanup: "waveform"
        case .stems: "slider.vertical.3"
        }
    }

    /// Subtitles and taking out pauses happen right here in the Editor; the other tools open
    /// their window over the Editor (not the main window) and show their progress here.
    private func run(_ tool: Tool) {
        switch tool {
        case .subtitles:
            UserDefaults.standard.set(EditorSidebar.Tab.subtitles.rawValue, forKey: "editorSidebarTab")
            if transcript != nil {
                if model.subtitles.isEmpty { makeSubtitles() }
            } else if let item = fileItem() {
                makeSubtitlesWhenTranscribed = true
                ai.transcribeInBackground([item])
            }
            return
        case .tighten:
            var spans = model.markers.filter { $0.kind == .silence }.compactMap(\.span)
            if let transcript {
                spans += Tighten.fillerCuts(transcript.words, language: Locale(identifier: transcript.language))
            }
            if spans.isEmpty {
                problem = String(localized: "No pauses or filler words to take out.")
            } else {
                model.cutOut(spans.sorted { $0.lowerBound < $1.lowerBound })
            }
            return
        default:
            break
        }
        guard let item = fileItem() else { return }
        if tool == .stems { ai.separateStems(item); return }
        open = EditorToolSheet(tool: tool, item: item)
    }
}

/// A local-AI tool's window, shown over the Editor.
private struct EditorToolSheet: Identifiable {
    let tool: EditorAIPanel.Tool
    let item: DownloadItem
    var id: String { "\(tool)" }
}

/// Presents a tool's window over the Editor, with what it needs.
private struct EditorToolSheetContent: View {
    let sheet: EditorToolSheet
    @Environment(AIStudio.self) private var ai

    var body: some View {
        switch sheet.tool {
        case .shorts: ShortsSheet(item: sheet.item).environment(ai)
        case .subtitles:
            if #available(macOS 26, *) { SubtitleSheet(items: [sheet.item]).environment(ai) }
        case .tighten: TightenSheet(items: [sheet.item]).environment(ai)
        case .enhance: EnhanceSheet(item: sheet.item).environment(ai)
        case .background: BackgroundSheet(item: sheet.item).environment(ai)
        case .blur: PrivacyBlurSheet(item: sheet.item).environment(ai)
        case .cleanup: AudioCleanupSheet(items: [sheet.item]).environment(ai)
        case .stems: EmptyView()
        }
    }
}
/// A translation to make: from the spoken language into the one chosen.
struct TranslationRequest: Equatable {
    let source: String
    let target: String
}

/// Runs a translation when one is asked for. macOS shows its own prompt to download the
/// language first when it isn't on this Mac yet.
private struct TranslationRunner: ViewModifier {
    let request: TranslationRequest?
    /// Given the TranslationSession (typed loosely: it only exists on newer macOS).
    let run: (AnyObject) async -> Void

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.translationTask(request.map {
                TranslationSession.Configuration(source: Locale.Language(identifier: $0.source), target: Locale.Language(identifier: $0.target))
            }) { session in
                await run(session)
            }
        } else {
            content
        }
    }
}
#endif
