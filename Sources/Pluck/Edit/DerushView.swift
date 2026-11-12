import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Analyses raw footage clip by clip (sound markers, transcript, the picture shot by shot), then
/// the whole shoot at once for selects.
@MainActor
@Observable
final class DerushSession {
    struct Clip: Identifiable {
        var file: URL
        var state: State = .waiting
        var length: Double = 0
        var events: [SoundTagger.Event] = []
        var highlights: [SoundTagger.Highlight] = []
        var lines: [(time: Double, text: String)] = []
        /// Highlights from the sound and speech (the picks from the shoot plan come on top).
        var soundHighlights: [SoundTagger.Highlight] = []
        var index: VisualIndex.FileIndex?
        var id: URL { file }

        enum State: Equatable { case waiting, working, done }
    }

    private(set) var clips: [Clip] = []
    private(set) var running = false
    private(set) var current: LiveSession?
    /// What the shot analysis of the current clip has done (0…1).
    private(set) var pictureProgress: Double?
    private(set) var plan: ShootPlan.Plan?
    private(set) var planning = false
    /// Screenshot mode: open the shoot overview once the plan is ready, and build the timelines
    /// in Resolve once everything is in.
    var showOverview = false
    var buildWhenReady = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored weak var manager: DownloadManager?

    static let extensions: Set<String> = ["mov", "mp4", "m4v", "mxf", "mts", "m2ts", "avi", "mkv", "webm", "ts",
                                          "wav", "aif", "aiff", "mp3", "m4a", "flac"]

    /// Adds clips (folders are searched); clips derushed before come back with their results.
    func add(_ urls: [URL], kind: ShootPlan.Kind = .corporate) {
        var found: [URL] = []
        for url in urls {
            var isFolder: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
            if isFolder.boolValue {
                let all = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                while var file = all?.nextObject() as? URL {
                    file = file.resolvingSymlinksInPath()
                    if Self.extensions.contains(file.pathExtension.lowercased()), !found.contains(file) { found.append(file) }
                }
            } else if Self.extensions.contains(url.pathExtension.lowercased()) {
                found.append(url)
            }
        }
        for file in found.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
        where !clips.contains(where: { $0.file == file }) {
            clips.append(Clip(file: file))
        }
        restoreSaved(kind: kind)
    }

    @ObservationIgnored private var restoring: Task<Void, Never>?

    /// Results saved by an earlier derush (sound, transcript and shots, kept in Pluck's data):
    /// those clips are done at once, without analysing them again.
    private func restoreSaved(kind: ShootPlan.Kind) {
        let previous = restoring
        restoring = Task {
            await previous?.value
            var restored = 0
            for file in clips.filter({ $0.state == .waiting }).map(\.file) {
                guard let saved = LiveSession.saved(forFootage: file) else { continue }
                let duration = (try? await AVURLAsset(url: file).load(.duration).seconds) ?? 0
                let index = VisualIndex.load(file.path).flatMap { $0.shots.first?.quality != nil ? $0 : nil }
                // The list may have changed meanwhile.
                guard let n = clips.firstIndex(where: { $0.file == file }), clips[n].state == .waiting else { continue }
                clips[n].length = duration.isFinite ? duration : 0
                clips[n].events = saved.events
                clips[n].soundHighlights = saved.highlights
                clips[n].highlights = saved.highlights
                clips[n].lines = LiveSession.lines(from: saved.words)
                clips[n].index = index
                clips[n].state = .done
                restored += 1
            }
            if restored > 0 { await replan(kind: kind) }
        }
    }

    func remove(_ file: URL) {
        guard !running else { return }
        clips.removeAll { $0.file == file }
    }

    func clear() {
        guard !running else { return }
        clips.removeAll()
    }

    func start(language: Locale?, lookAtPicture: Bool, kind: ShootPlan.Kind) {
        guard !running else { return }
        running = true
        task = Task {
            // Saved results first, so nothing is analysed twice.
            await restoring?.value
            for index in clips.indices where clips[index].state != .done {
                if Task.isCancelled { break }
                clips[index].state = .working
                let session = LiveSession()
                session.manager = manager
                current = session
                await session.analyseAndWait(clips[index].file, language: language)
                // Clips without sound have nothing analysed: their length comes from the video.
                let duration = (try? await AVURLAsset(url: clips[index].file).load(.duration).seconds) ?? 0
                clips[index].length = max(session.analysed, duration.isFinite ? duration : 0)
                clips[index].events = session.events
                clips[index].soundHighlights = session.highlights
                clips[index].highlights = session.highlights
                clips[index].lines = session.lines
                // The picture, shot by shot (kept from an earlier run when the file hasn't changed).
                let file = clips[index].file
                if lookAtPicture, Converting.isVideo(file), let ffmpeg = manager?.tool("ffmpeg"), !Task.isCancelled {
                    if VisualIndex.isIndexed(file), let saved = VisualIndex.load(file.path), saved.shots.first?.quality != nil {
                        clips[index].index = saved
                    } else {
                        pictureProgress = 0
                        clips[index].index = try? await VisualIndex.index(file, ffmpeg: ffmpeg) { value in
                            Task { @MainActor in self.pictureProgress = value }
                        }
                        pictureProgress = nil
                    }
                }
                clips[index].state = .done
            }
            current = nil
            await replan(kind: kind)
            running = false
            task = nil
        }
    }

    /// The selects for the whole shoot, for this kind of video (no new analysis needed).
    func replan(kind: ShootPlan.Kind) async {
        let indexes = clips.compactMap(\.index)
        guard !indexes.isEmpty else {
            plan = nil
            return
        }
        planning = true
        let plan = await ShootPlan.plan(indexes, kind: kind)
        self.plan = plan
        for index in clips.indices {
            var highlights = clips[index].soundHighlights
            for pick in plan.picks where pick.path == clips[index].file.path {
                // A smooth camera move is kept whole (for a speed ramp), other shots up to ten seconds.
                let end = min(pick.shot.end, pick.shot.start + (pick.shot.smooth == true ? 20 : 10))
                if highlights.contains(where: { pick.shot.start < $0.end && end > $0.start }) { continue }
                highlights.append(SoundTagger.Highlight(start: pick.shot.start, end: end, reason: pick.shot.description,
                                                        score: pick.shot.quality?.score ?? 0.5))
            }
            clips[index].highlights = highlights.sorted { $0.start < $1.start }
        }
        planning = false
    }

    func isPick(_ path: URL, _ shot: VisualIndex.Shot) -> Bool {
        plan?.picks.contains { $0.path == path.path && $0.shot.start == shot.start } ?? false
    }

    /// The shot's score for the chosen kind of video (as the plan saw it).
    func score(_ path: URL, _ shot: VisualIndex.Shot, kind: ShootPlan.Kind) -> (score: Double, problems: [VisualIndex.Problem]) {
        VisualIndex.score(shot, weights: kind.weights)
    }

    func stop() {
        current?.stop()
        task?.cancel()
    }

    /// Moments across all clips where these words are said.
    func find(_ text: String) -> [(clip: URL, time: Double, line: String)] {
        let query = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return clips.flatMap { clip in
            clip.lines.filter { $0.text.lowercased().contains(query) }.map { (clip.file, $0.time, $0.text) }
        }
    }
}

/// Derush Footage: a folder of raw footage in, every clip marked (cheers, music, silence,
/// quotable lines, every shot judged) with a transcript, out as a marked-up timeline and a
/// selects timeline for the kind of video being made.
struct DerushView: View {
    @State private var session = DerushView.shared
    @State private var selection: URL?
    @State private var search = ""
    @State private var tab = Tab.shots
    @AppStorage("derushTranscribe") private var transcribe = true
    @AppStorage("derushPicture") private var lookAtPicture = true
    @AppStorage("derushKind") private var kind: ShootPlan.Kind = .corporate
    @State private var showingOverview = false
    @State private var languages: [Locale] = []
    @State private var language: Locale?
    @State private var status: String?
    @State private var dropTargeted = false

    private enum Tab: Hashable { case shots, highlights, markers, transcript }

    /// One for the app, so analysis keeps going when the window closes.
    @MainActor static let shared = DerushSession()

    private var selected: DerushSession.Clip? { session.clips.first { $0.file == selection } }
    private var done: [DerushSession.Clip] { session.clips.filter { $0.state == .done } }

    var body: some View {
        HStack(spacing: Design.Studio.panelGap) {
            clipPanel
            detailPanel
        }
        .font(Design.Studio.body)
        .foregroundStyle(Design.Studio.text)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers { if let url = await provider.load(URL.self), url.isFileURL { urls.append(url) } }
                session.add(urls, kind: kind)
            }
            return true
        }
        .onChange(of: kind) {
            guard !session.running, session.plan != nil else { return }
            Task { await session.replan(kind: kind) }
        }
        .onChange(of: session.plan != nil && session.showOverview) { _, ready in
            if ready { session.showOverview = false; showingOverview = true }
        }
        .onChange(of: session.buildWhenReady && session.plan != nil && !session.planning && !session.running) { _, ready in
            if ready { session.buildWhenReady = false; build() }
        }
        .sheet(isPresented: $showingOverview) { overviewSheet }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    if session.planning {
                        PlumSpinner()
                        Text("Looking at the whole shoot…").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                    } else if let plan = session.plan {
                        Button { showingOverview = true } label: {
                            Text("Shoot overview · ^[\(plan.picks.count) pick](inflect: true)")
                        }
                        .buttonStyle(StudioFlatButtonStyle())
                    }
                    Button(action: build) {
                        Label("Build in DaVinci", systemImage: "film")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
                    .disabled(done.isEmpty || session.running || !Resolve.isInstalled)
                }
            }.studioFlat()
        }
        .task {
            session.manager = LibraryServer.shared.manager
            guard LocalAI.canTranscribe, #available(macOS 26, *) else { return }
            languages = await OnDeviceSpeech.languages()
            language = language ?? languages.first { $0.language.languageCode == Locale.current.language.languageCode }
                ?? languages.first { $0.language.languageCode?.identifier == "en" }
        }
    }

    // MARK: - Clips (left)

    private var clipPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                Text("Derush").font(Design.Studio.pageTitle)
                Spacer()
                Menu {
                    Button("Add Files…") { pick(folders: false) }
                    Button("Add Folder…") { pick(folders: true) }
                } label: {
                    IconLabel(symbol: "plus")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add clips")
                .accessibilityLabel(Text("Add clips"))
                Button { session.clear(); selection = nil } label: { IconLabel(symbol: "trash") }
                    .buttonStyle(.plain)
                    .disabled(session.clips.isEmpty || session.running)
                    .help("Clear")
                    .accessibilityLabel(Text("Clear"))
            }
            .padding(.horizontal, 6)
            Menu {
                Picker("Video", selection: $kind) {
                    ForEach(ShootPlan.Kind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                QuietMenuLabel(symbol: "film", title: kind.label)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 2)
            .help("The selects are picked for this kind of video. Changing it re-picks straight away, without analysing again.")
            clipList
            VStack(alignment: .leading, spacing: 2) {
                StudioSwitchRow(title: "Look at the picture", isOn: $lookAtPicture)
                    .help("Judges every shot for focus, light, shake, faces, action and its look. Slower than listening only.")
                if LocalAI.canTranscribe {
                    HStack(spacing: 0) {
                        StudioSwitchRow(title: "Transcribe", isOn: $transcribe)
                        Spacer()
                        if transcribe { languageMenu }
                    }
                }
            }
            .padding(.horizontal, 6)
            .disabled(session.running)
            if let status {
                Text(status).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(2)
                    .padding(.horizontal, 6)
            }
            if session.running {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        PlumSpinner()
                        Text("\(done.count) of \(session.clips.count) clips").monospacedDigit()
                        Spacer()
                        Button(action: session.stop) {
                            Label("Stop", systemImage: "stop").labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(StudioFlatButtonStyle())
                    }
                    StudioProgress(share: (Double(done.count) + (session.pictureProgress ?? 0)) / Double(max(session.clips.count, 1)))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .studioBox()
            } else {
                Button { session.start(language: transcribe ? language : nil, lookAtPicture: lookAtPicture, kind: kind) } label: {
                    Label("Analyse", systemImage: "waveform.badge.magnifyingglass").labelStyle(.titleAndIcon)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
                .disabled(!session.clips.contains { $0.state != .done })
                StudioFootnote(text: "Runs on this Mac. Nothing is uploaded.")
            }
        }
        .padding(.top, 20)
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
        .frame(width: 340)
        .frame(maxHeight: .infinity)
        .studioPanel()
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
            QuietMenuLabel(title: language.flatMap { Locale.current.localizedString(forIdentifier: $0.identifier) } ?? "")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("Spoken language"))
    }

    private var clipList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(session.clips) { clip in
                    Button { selection = clip.file } label: { clipRow(clip) }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(clip.file == selection ? .isSelected : [])
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([clip.file]) }
                            Button("Remove") { session.remove(clip.file) }.disabled(session.running)
                        }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay {
            if dropTargeted, !session.clips.isEmpty {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Design.Brand.pink, lineWidth: 2)
            }
        }
    }

    private func clipRow(_ clip: DerushSession.Clip) -> some View {
        HStack(spacing: 10) {
            Group {
                switch clip.state {
                case .waiting: Image(systemName: "circle.dotted").foregroundStyle(Design.Studio.textFaint)
                case .working: PlumSpinner()
                case .done: Image(systemName: "checkmark").foregroundStyle(Design.Studio.good)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.file.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(summary(clip)).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(clip.file == selection ? Design.Studio.raised : .clear, in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
    }

    private func summary(_ clip: DerushSession.Clip) -> String {
        switch clip.state {
        case .waiting: return String(localized: "Waiting")
        case .working:
            if let progress = session.pictureProgress {
                return String(localized: "Looking at the picture… \(Int(progress * 100))%")
            }
            return String(localized: "Analysing… \(time(session.current?.analysed ?? 0))")
        case .done:
            let counts = String(AttributedString(localized: "^[\(clip.events.count) marker](inflect: true), ^[\(clip.highlights.count) highlight](inflect: true)").characters)
            return time(clip.length) + " · " + counts
        }
    }

    // MARK: - The clip (right)

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            if session.clips.isEmpty {
                dropArea
            } else {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        if let clip = selected {
                            Text(clip.file.lastPathComponent).font(Design.Studio.sectionTitle).lineLimit(1).truncationMode(.middle)
                            Text(detailSummary(clip)).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).monospacedDigit()
                        }
                    }
                    Spacer(minLength: 0)
                    SearchBox(prompt: "Find what was said in all clips", text: $search).frame(width: 280)
                }
                if !search.isEmpty {
                    ScrollView { searchResults.frame(maxWidth: .infinity, alignment: .leading) }
                } else if let clip = selected {
                    StudioSegmented(options: [(Tab.shots, "Shots"), (Tab.highlights, "Highlights"),
                                              (Tab.markers, "Markers"), (Tab.transcript, "Transcript")],
                                    selection: $tab)
                    ScrollView { tabContent(clip).frame(maxWidth: .infinity, alignment: .leading) }
                } else {
                    quiet("Select a clip to see its highlights, shots, markers and transcript.")
                    Spacer()
                }
            }
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .studioPanel()
    }

    private var dropArea: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack").font(.system(size: 24)).foregroundStyle(dropTargeted ? Design.Brand.pink : Design.Studio.textQuiet)
            Text("Drop clips or a folder here, or use Add Folder…").foregroundStyle(Design.Studio.textQuiet)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(dropTargeted ? Design.Brand.pink : Design.Studio.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .contentShape(.rect)
        .onTapGesture { pick(folders: true) }
        .help("Pluck goes through your raw footage: every shot for focus, light, faces, action and its look, plus cheers, music and the most quotable lines. Then it looks at the whole shoot and picks selects for the kind of video you’re making.")
    }

    private func detailSummary(_ clip: DerushSession.Clip) -> String {
        guard clip.state == .done else { return summary(clip) }
        let counts = String(AttributedString(localized: "^[\(clip.events.count) marker](inflect: true) · ^[\(clip.highlights.count) highlight](inflect: true) · ^[\(clip.index?.shots.count ?? 0) shot](inflect: true)").characters)
        return time(clip.length) + " · " + counts
    }

    private var searchResults: some View {
        let found = session.find(search)
        return LazyVStack(alignment: .leading, spacing: 0) {
            if found.isEmpty { quiet("Not found.") }
            ForEach(Array(found.enumerated()), id: \.offset) { _, hit in
                VStack(alignment: .leading, spacing: 3) {
                    Text(hit.clip.lastPathComponent + " · " + time(hit.time)).font(Design.Studio.hint)
                        .foregroundStyle(Design.Brand.pink).monospacedDigit()
                    Text(hit.line).textSelection(.enabled).lineSpacing(3)
                }
                .padding(.vertical, 7)
            }
        }
    }

    @ViewBuilder private func tabContent(_ clip: DerushSession.Clip) -> some View {
        if clip.state != .done {
            quiet("Not analysed yet.")
        } else {
            switch tab {
            case .shots:
                if let shots = clip.index?.shots, !shots.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 16, alignment: .top), count: 4),
                              alignment: .leading, spacing: 22) {
                        ForEach(shots, id: \.rowID) { shot in shotCard(clip.file, shot) }
                    }
                } else {
                    quiet("Nothing here.")
                }
            case .highlights:
                if clip.highlights.isEmpty { quiet("Nothing here.") }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(clip.highlights, id: \.rowID) { highlight in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "star.fill").font(.system(size: 12)).foregroundStyle(Design.Brand.pink).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(time(highlight.start) + " – " + time(highlight.end)).monospacedDigit()
                                Text(highlight.reason).foregroundStyle(Design.Studio.textQuiet).lineLimit(2)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            case .markers:
                if clip.events.isEmpty { quiet("Nothing here.") }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(clip.events, id: \.rowID) { event in
                        HStack(spacing: 10) {
                            Image(systemName: event.kind.symbol).font(.system(size: 13)).foregroundStyle(Design.Studio.textQuiet)
                                .frame(width: 16).accessibilityHidden(true)
                            Text(time(event.time)).monospacedDigit().foregroundStyle(Design.Studio.textQuiet).frame(width: 56, alignment: .leading)
                            Text(event.kind.label)
                        }
                        .frame(height: 36)
                    }
                }
            case .transcript:
                if clip.lines.isEmpty { quiet("Nothing here.") }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(clip.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(time(line.time)).monospacedDigit().foregroundStyle(Design.Studio.textQuiet).frame(width: 56, alignment: .leading)
                            Text(line.text).textSelection(.enabled).lineSpacing(3)
                        }
                        .padding(.vertical, 7)
                    }
                }
            }
        }
    }

    private func quiet(_ text: LocalizedStringKey) -> some View {
        Text(text).foregroundStyle(Design.Studio.textQuiet)
    }

    private func shotCard(_ file: URL, _ shot: VisualIndex.Shot) -> some View {
        let judged = session.score(file, shot, kind: kind)
        let pick = session.isPick(file, shot)
        return VStack(alignment: .leading, spacing: 8) {
            ShotThumbnail(url: VisualIndex.thumbnailURL(path: file.path, start: shot.start))
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if pick {
                        Image(systemName: "star.fill").font(.system(size: 12)).foregroundStyle(Design.Brand.pink)
                            .padding(8)
                            .accessibilityLabel(Text("Pick"))
                    }
                }
            HStack(spacing: 8) {
                Text(time(shot.start)).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).monospacedDigit()
                Spacer(minLength: 0)
                StudioChip(text: Text(verbatim: "\(Int((judged.score * 100).rounded()))").monospacedDigit(), colour: Design.Studio.text)
                    .help("How usable and interesting the shot is for this kind of video")
            }
            Text(shot.description).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            ChipFlow {
                StudioChip(text: Text(shot.framing.label))
                if shot.movement != .still { StudioChip(text: Text(shot.movement.label)) }
                if shot.smooth == true {
                    StudioChip(text: Text("Speed ramp"))
                        .help("A smooth, even camera move: good for a speed ramp")
                }
                if let look = shot.quality?.look, !look.isEmpty { StudioChip(text: Text(verbatim: look)) }
                if let emotion = shot.quality?.emotion, !emotion.isEmpty { StudioChip(text: Text(verbatim: emotion)) }
                ForEach(judged.problems, id: \.self) { StudioChip(text: Text($0.label), colour: Design.Studio.warn) }
            }
        }
    }

    // MARK: - Shoot overview

    private var overviewSheet: some View {
        VStack(alignment: .leading, spacing: Design.Studio.sectionGap) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Shoot Overview").font(Design.Studio.pageTitle)
                Text(kind.label).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Studio.sectionGap) {
                    if let overview = session.plan?.overview {
                        if !overview.story.isEmpty {
                            overviewList(Text("The story the footage tells"), overview.story)
                        }
                        if !overview.missing.isEmpty {
                            overviewList(Text("Missing or thin"), overview.missing)
                        }
                    }
                    if let plan = session.plan {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("What was shot").font(Design.Studio.sectionTitle)
                            ForEach(plan.topics) { topic in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(topic.name).lineLimit(1)
                                    Spacer()
                                    Text("^[\(topic.shots.count) shot](inflect: true)").foregroundStyle(Design.Studio.textQuiet).monospacedDigit()
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Label("Written by the local AI on this Mac.", systemImage: "lock.shield")
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.textFaint)
                Spacer()
                Button("Done") { showingOverview = false }
                    .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .font(Design.Studio.body)
        .foregroundStyle(Design.Studio.text)
        .padding(Design.Spacing.sheet)
        .frame(width: 520, height: 560)
        .background(Design.Studio.panel)
    }

    private func overviewList(_ title: Text, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            title.font(Design.Studio.sectionTitle)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "•").foregroundStyle(Design.Studio.textQuiet)
                    Text(verbatim: item).textSelection(.enabled)
                }
            }
        }
    }

    private func time(_ seconds: Double) -> String {
        Duration.seconds(max(0, seconds.rounded())).formatted(.time(pattern: .hourMinuteSecond))
    }

    /// A shot as a Resolve marker: what it is, its look and feeling, and anything wrong with it.
    private func note(_ shot: VisualIndex.Shot, in file: URL) -> String {
        let judged = session.score(file, shot, kind: kind)
        var parts = [shot.description, shot.framing.label]
        if shot.movement != .still { parts.append(shot.movement.label) }
        if shot.smooth == true { parts.append(String(localized: "Speed ramp")) }
        if let look = shot.quality?.look, !look.isEmpty { parts.append(look) }
        if let emotion = shot.quality?.emotion, !emotion.isEmpty { parts.append(emotion) }
        parts += judged.problems.map(\.label)
        return (session.isPick(file, shot) ? "★ " : "") + parts.joined(separator: " · ")
    }

    private func pick(folders: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = folders
        panel.canChooseFiles = !folders
        if !folders { panel.allowedContentTypes = [.audiovisualContent] }
        panel.prompt = String(localized: "Add")
        if panel.runModal() == .OK { session.add(panel.urls, kind: kind) }
    }

    /// The derush in Resolve, cut: a stringout of every usable shot (soft, shaky, dark or blown
    /// ones left out unless their look is meant), grouped by subject, the picks coloured green;
    /// speech kept whole and in order. And a timeline of the selects alone.
    private func build() {
        let clips = done
        let byPath = Dictionary(clips.map { ($0.file.path, $0) }, uniquingKeysWith: { a, _ in a })
        let kind = self.kind
        func markers(_ clip: DerushSession.Clip) -> [(time: Double, colour: String, name: String, note: String)] {
            clip.events.map { (time: $0.time, colour: $0.kind.colour, name: $0.kind.label, note: "") }
                + clip.lines.map { (time: $0.time, colour: "Sky", name: $0.text, note: $0.text) }
                + clip.highlights.map { (time: $0.start, colour: "Red", name: String(localized: "Highlight"), note: $0.reason) }
        }
        var cuts: [MarkedTimeline.Cut] = [], sections: [(cut: Int, title: String)] = []
        // Speech whole and in order: cutting it by subject would chop sentences apart.
        let speech = clips.filter { !$0.lines.isEmpty }
        if !speech.isEmpty {
            sections.append((cuts.count, String(localized: "Speech")))
            cuts += speech.map { MarkedTimeline.Cut(file: $0.file, start: 0, end: $0.length, markers: markers($0)) }
        }
        let speaking = Set(speech.map(\.file.path))
        // Every usable shot, by subject (shots of their own together at the end).
        if let plan = session.plan {
            var groups = plan.topics.filter { $0.shots.count > 1 }.map { (title: $0.name, shots: $0.shots) }
            let loose = plan.topics.filter { $0.shots.count == 1 }.flatMap(\.shots)
            if !loose.isEmpty { groups.append((String(localized: "Other shots"), loose)) }
            for group in groups {
                let usable = group.shots.filter { item in
                    guard !speaking.contains(item.path) else { return false }
                    let judged = VisualIndex.score(item.shot, weights: kind.weights)
                    return judged.problems.isEmpty || judged.score >= 0.3
                }.sorted { ($0.path, $0.shot.start) < ($1.path, $1.shot.start) }
                guard !usable.isEmpty else { continue }
                sections.append((cuts.count, group.title))
                for item in usable {
                    let file = URL(fileURLWithPath: item.path)
                    let pick = session.isPick(file, item.shot)
                    // The next piece of the same shot joins it: no cut where nothing changes.
                    if let last = cuts.last, last.file == file, abs(last.end - item.shot.start) < 0.05, (last.colour != nil) == pick {
                        cuts[cuts.count - 1].end = item.shot.end
                        continue
                    }
                    cuts.append(MarkedTimeline.Cut(file: file, start: item.shot.start, end: item.shot.end, colour: pick ? "Green" : nil,
                                                   markers: byPath[item.path].map(markers) ?? []))
                }
            }
        }
        // Clips the picture wasn't looked at (sound only, or analysed without it): whole.
        let unseen = clips.filter { $0.index == nil && $0.lines.isEmpty }
        if !unseen.isEmpty {
            sections.append((cuts.count, String(localized: "Not looked at")))
            cuts += unseen.map { MarkedTimeline.Cut(file: $0.file, start: 0, end: $0.length, markers: markers($0)) }
        }
        // The selects: the highlights alone, in the order they were filmed.
        let selects = clips.flatMap { clip in
            clip.highlights.map { MarkedTimeline.Cut(file: clip.file, start: $0.start, end: $0.end, colour: "Green",
                                                     markers: [(time: $0.start, colour: "Red", name: $0.reason, note: $0.reason)]) }
        }
        let name = String(localized: "Derush") + " " + Date.now.formatted(date: .abbreviated, time: .shortened)
        let bin = String(localized: "Derush")
        status = String(localized: "Building the timeline in DaVinci Resolve…")
        Task {
            do {
                let made = try await MarkedTimeline.buildCuts(name: name, bin: bin, cuts: cuts, sections: sections)
                if !selects.isEmpty {
                    try await MarkedTimeline.buildCuts(name: made + " – " + String(localized: "selects"), bin: bin, cuts: selects)
                }
                status = String(localized: "Timeline “\(made)” is in DaVinci.")
            } catch {
                status = error.localizedDescription
            }
        }
    }
}


/// A 28 pt icon button's face (+, trash), quiet grey as on the boards.
private struct IconLabel: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13))
            .foregroundStyle(Design.Studio.textQuiet)
            .frame(width: 28, height: 28)
            .contentShape(.rect)
    }
}

/// A quiet menu's face: optional symbol, the choice, a small chevron, no button behind it.
private struct QuietMenuLabel: View {
    var symbol: String?
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 12)) }
            Text(verbatim: title)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
        }
        .font(Design.Studio.body)
        .foregroundStyle(Design.Studio.textQuiet)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .contentShape(.rect)
    }
}

/// A small plum arc going round: a clip or a run at work.
private struct PlumSpinner: View {
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle().stroke(Design.Studio.line, lineWidth: 2)
            Circle().trim(from: 0, to: 0.25).stroke(Design.Brand.pink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(turning ? 360 : 0))
        }
        .frame(width: 11, height: 11)
        .onAppear { withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { turning = true } }
        .accessibilityLabel(Text("Working"))
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

/// Chips in rows that wrap, 4 pt apart.
private struct ChipFlow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + 4
            }
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [(items: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] = []
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if var last = rows.last, last.width + 4 + size.width <= width {
                last.items.append(index)
                last.width += 4 + size.width
                last.height = max(last.height, size.height)
                rows[rows.count - 1] = last
            } else {
                let y = rows.last.map { $0.y + $0.height + 4 } ?? 0
                rows.append(([index], y, size.width, size.height))
            }
        }
        return rows
    }
}

/// A shot's thumbnail from the visual index, loaded off the main thread.
private struct ShotThumbnail: View {
    var url: URL
    @State private var image: NSImage?

    var body: some View {
        Rectangle().fill(Design.Studio.raised)
            .overlay { if let image { Image(nsImage: image).resizable().scaledToFill() } }
            .clipped()
            .task(id: url) {
                let url = url
                image = await Task.detached { NSImage(contentsOf: url) }.value
            }
    }
}

// Rows from different lists share id styles, so keep them distinct.
private extension SoundTagger.Highlight { var rowID: String { "highlight \(start)" } }
private extension SoundTagger.Event { var rowID: String { "event \(id)" } }
private extension VisualIndex.Shot { var rowID: String { "shot \(start)" } }
