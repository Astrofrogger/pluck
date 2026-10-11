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
    @AppStorage("derushTranscribe") private var transcribe = true
    @AppStorage("derushPicture") private var lookAtPicture = true
    @AppStorage("derushKind") private var kind: ShootPlan.Kind = .corporate
    @State private var showingOverview = false
    @State private var languages: [Locale] = []
    @State private var language: Locale?
    @State private var status: String?
    @State private var dropTargeted = false

    /// One for the app, so analysis keeps going when the window closes.
    @MainActor static let shared = DerushSession()

    private var selected: DerushSession.Clip? { session.clips.first { $0.file == selection } }
    private var done: [DerushSession.Clip] { session.clips.filter { $0.state == .done } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                SheetHeader(symbol: "film.stack", title: Text("Derush Footage"),
                            subtitle: Text("Pluck goes through your raw footage: every shot for focus, light, faces, action and its look, plus cheers, music and the most quotable lines. Then it looks at the whole shoot and picks selects for the kind of video you’re making."),
                            subtitleIsName: false)
                HStack(spacing: 12) {
                    Button("Add Files…") { pick(folders: false) }
                    Button("Add Folder…") { pick(folders: true) }
                    if !session.clips.isEmpty, !session.running { Button("Clear") { session.clear(); selection = nil } }
                    Spacer()
                    if session.running {
                        Button(action: session.stop) { Label("Stop", systemImage: "stop.fill") }
                            .buttonStyle(BarCapsuleButtonStyle(tint: .red))
                            .fixedSize()
                    } else {
                        Button { session.start(language: transcribe ? language : nil, lookAtPicture: lookAtPicture, kind: kind) } label: { Label("Analyse", systemImage: "waveform.badge.magnifyingglass") }
                            .buttonStyle(BarCapsuleButtonStyle())
                            .fixedSize()
                            .disabled(!session.clips.contains { $0.state != .done })
                    }
                }
                .font(.callout)
                HStack(spacing: 16) {
                    Picker("Video", selection: $kind) {
                        ForEach(ShootPlan.Kind.allCases) { Text($0.label).tag($0) }
                    }
                    .fixedSize()
                    .help("The selects are picked for this kind of video. Changing it re-picks straight away, without analysing again.")
                    Toggle("Look at the picture", isOn: $lookAtPicture)
                        .help("Judges every shot for focus, light, shake, faces, action and its look. Slower than listening only.")
                        .disabled(session.running)
                    if LocalAI.canTranscribe {
                        Toggle("Transcribe", isOn: $transcribe)
                            .disabled(session.running)
                        if transcribe {
                            Picker("Spoken language", selection: $language) {
                                ForEach(languages, id: \.identifier) { locale in
                                    Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier).tag(Optional(locale))
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 200)
                            .disabled(session.running)
                        }
                    }
                    Spacer()
                }
                .font(.callout)
            }
            .padding(Design.Spacing.window)
            Divider()
            HSplitView {
                clipList.frame(minWidth: 320)
                detail.frame(minWidth: 380)
            }
            Divider()
            footer
        }
        .frame(minWidth: 900, minHeight: 620)
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
        .task {
            session.manager = LibraryServer.shared.manager
            guard LocalAI.canTranscribe, #available(macOS 26, *) else { return }
            languages = await OnDeviceSpeech.languages()
            language = language ?? languages.first { $0.language.languageCode == Locale.current.language.languageCode }
                ?? languages.first { $0.language.languageCode?.identifier == "en" }
        }
    }

    private var clipList: some View {
        List(selection: $selection) {
            ForEach(session.clips) { clip in
                HStack(spacing: 8) {
                    switch clip.state {
                    case .waiting: Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
                    case .working: ProgressView().controlSize(.small)
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(clip.file.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text(summary(clip)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(clip.file)
                .contextMenu {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([clip.file]) }
                    Button("Remove") { session.remove(clip.file) }.disabled(session.running)
                }
            }
        }
        .overlay {
            if session.clips.isEmpty {
                ContentUnavailableView("Add Your Footage", systemImage: "film.stack",
                                       description: Text("Drop clips or a folder here, or use Add Folder…"))
            }
        }
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: Design.Radius.box).strokeBorder(Color.accentColor, lineWidth: 3).padding(4) } }
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

    @ViewBuilder private var detail: some View {
        VStack(spacing: 8) {
            TextField("Find what was said in all clips", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding([.horizontal, .top], 12)
            List {
                if !search.isEmpty {
                    let found = session.find(search)
                    if found.isEmpty { Text("Not found.").foregroundStyle(.secondary) }
                    ForEach(Array(found.enumerated()), id: \.offset) { _, hit in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.clip.lastPathComponent + " · " + time(hit.time)).font(.caption).foregroundStyle(.tint)
                            Text(hit.line).textSelection(.enabled)
                        }
                    }
                } else if let clip = selected {
                    if !clip.highlights.isEmpty {
                        Section("Highlights") {
                            ForEach(clip.highlights, id: \.rowID) { highlight in
                                HStack(alignment: .firstTextBaseline) {
                                    Image(systemName: "star.fill").foregroundStyle(.red).accessibilityHidden(true)
                                    Text(time(highlight.start)).monospacedDigit()
                                    Text(highlight.reason).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                    if let shots = clip.index?.shots, !shots.isEmpty {
                        Section("Shots") {
                            ForEach(shots, id: \.rowID) { shot in shotRow(clip.file, shot) }
                        }
                    }
                    if !clip.events.isEmpty {
                        Section("Markers") {
                            ForEach(clip.events, id: \.rowID) { event in
                                HStack {
                                    Image(systemName: event.kind.symbol).frame(width: 20).accessibilityHidden(true)
                                    Text(time(event.time)).monospacedDigit()
                                    Text(event.kind.label)
                                }
                            }
                        }
                    }
                    if !clip.lines.isEmpty {
                        Section("Transcript") {
                            ForEach(Array(clip.lines.enumerated()), id: \.offset) { _, line in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(time(line.time)).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                                    Text(line.text).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    if clip.state != .done { Text("Not analysed yet.").foregroundStyle(.secondary) }
                } else {
                    Text("Select a clip to see its highlights, shots, markers and transcript.").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func shotRow(_ file: URL, _ shot: VisualIndex.Shot) -> some View {
        let judged = session.score(file, shot, kind: kind)
        let pick = session.isPick(file, shot)
        return HStack(alignment: .top, spacing: 10) {
            ShotThumbnail(url: VisualIndex.thumbnailURL(path: file.path, start: shot.start))
                .frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: Design.Radius.small))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if pick {
                        Image(systemName: "star.fill").foregroundStyle(.red)
                            .accessibilityLabel(Text("Pick"))
                    }
                    Text(time(shot.start)).monospacedDigit().foregroundStyle(.secondary)
                    Text(shot.description).lineLimit(2)
                }
                HStack(spacing: 4) {
                    Chip(text: Text(verbatim: "\(Int((judged.score * 100).rounded()))"), tint: judged.score >= 0.5 ? .green : .secondary)
                        .help("How usable and interesting the shot is for this kind of video")
                    Chip(text: Text(shot.framing.label))
                    if shot.movement != .still { Chip(text: Text(shot.movement.label)) }
                    if shot.smooth == true {
                        Chip(text: Text("Speed ramp"), tint: .teal)
                            .help("A smooth, even camera move: good for a speed ramp")
                    }
                    if let look = shot.quality?.look, !look.isEmpty { Chip(text: Text(verbatim: look), tint: .purple) }
                    if let emotion = shot.quality?.emotion, !emotion.isEmpty { Chip(text: Text(verbatim: emotion), tint: .blue) }
                    ForEach(judged.problems, id: \.self) { Chip(text: Text($0.label), tint: .orange) }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var overviewSheet: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            SheetHeader(symbol: "text.page.badge.magnifyingglass", title: Text("Shoot Overview"),
                        subtitle: Text(kind.label), subtitleIsName: false)
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Spacing.section) {
                    if let overview = session.plan?.overview {
                        if !overview.story.isEmpty {
                            overviewList(Text("The story the footage tells"), overview.story, symbol: "film")
                        }
                        if !overview.missing.isEmpty {
                            overviewList(Text("Missing or thin"), overview.missing, symbol: "exclamationmark.circle")
                        }
                    }
                    if let plan = session.plan {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("What was shot").font(.headline)
                            ForEach(plan.topics) { topic in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(topic.name).lineLimit(1)
                                    Spacer()
                                    Text("^[\(topic.shots.count) shot](inflect: true)").foregroundStyle(.secondary).monospacedDigit()
                                }
                                .font(.callout)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Label("Written by the local AI on this Mac.", systemImage: "lock.shield").noteStyle()
                Spacer()
                Button("Done") { showingOverview = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Design.Spacing.window)
        .frame(width: 520, height: 560)
    }

    private func overviewList(_ title: Text, _ items: [String], symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label { title } icon: { Image(systemName: symbol) }.font(.headline)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "•").foregroundStyle(.secondary)
                    Text(verbatim: item).textSelection(.enabled)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if session.running {
                let finished = done.count
                ProgressView(value: Double(finished), total: Double(max(session.clips.count, 1))).frame(width: 140)
                Text("\(finished) of \(session.clips.count) clips").monospacedDigit().foregroundStyle(.secondary)
            } else {
                Label("Runs on this Mac. Nothing is uploaded.", systemImage: "lock.shield").noteStyle()
            }
            Spacer()
            if let status { Text(status).foregroundStyle(.secondary).lineLimit(1) }
            if session.planning {
                ProgressView().controlSize(.small)
                Text("Looking at the whole shoot…").foregroundStyle(.secondary)
            } else if let plan = session.plan {
                Button {
                    showingOverview = true
                } label: {
                    Text("Shoot Overview (^[\(plan.picks.count) pick](inflect: true))")
                }
            }
            Button("Build Derush in Resolve", action: build)
                .disabled(done.isEmpty || session.running || !Resolve.isInstalled)
        }
        .font(.callout)
        .padding(.horizontal, Design.Spacing.window)
        .padding(.vertical, 12)
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
                status = String(localized: "Timeline “\(made)” is in Resolve.")
            } catch {
                status = error.localizedDescription
            }
        }
    }
}


/// A small coloured label (score, framing, look…).
private struct Chip: View {
    var text: Text
    var tint: Color = .secondary

    var body: some View {
        text
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

/// A shot's thumbnail from the visual index, loaded off the main thread.
private struct ShotThumbnail: View {
    var url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image { Image(nsImage: image).resizable().scaledToFill() }
        }
        .task(id: url) {
            let url = url
            image = await Task.detached { NSImage(contentsOf: url) }.value
        }
    }
}

// Rows from different sections share one List, so their ids must not collide (a highlight and a
// shot at the same second would otherwise show the same row).
private extension SoundTagger.Highlight { var rowID: String { "highlight \(start)" } }
private extension SoundTagger.Event { var rowID: String { "event \(id)" } }
private extension VisualIndex.Shot { var rowID: String { "shot \(start)" } }
