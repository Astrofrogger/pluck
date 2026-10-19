import AVKit
import SwiftUI

/// Indexes Library videos in the background, one at a time.
@MainActor
@Observable
final class VisualIndexer {
    static let shared = VisualIndexer()
    static let autoKey = "visualIndexAutomatically"

    private(set) var indexes: [VisualIndex.FileIndex] = []
    private(set) var working: String?
    private(set) var progress = 0.0
    private(set) var queued = 0
    @ObservationIgnored private var queue: [URL] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored weak var manager: DownloadManager?

    private init() { reload() }

    /// Videos in the Library that still need an index.
    var unindexed: [URL] {
        let library = LibraryStore.shared.entries.filter { $0.kind == .video && FileManager.default.fileExists(atPath: $0.path) }.map(\.path)
        var seen: Set<String> = []
        return (library + FootageFolders.shared.allVideos).filter { seen.insert($0).inserted }
            .map { URL(fileURLWithPath: $0) }.filter { !VisualIndex.isIndexed($0) }
    }

    var videoCount: Int { LibraryStore.shared.entries.filter { $0.kind == .video }.count }

    func reload() {
        // The Library's videos and those in the watched folders.
        let paths = Set(LibraryStore.shared.entries.map(\.path)).union(FootageFolders.shared.allVideos)
        indexes = paths.compactMap(VisualIndex.load)
    }

    /// The same, read off the main thread (a big footage library is many megabytes of index).
    func reloadInBackground() async {
        let paths = Set(LibraryStore.shared.entries.map(\.path)).union(FootageFolders.shared.allVideos)
        indexes = await Task.detached(priority: .userInitiated) { paths.compactMap(VisualIndex.load) }.value
    }

    func enqueue(_ files: [URL]) {
        for file in files where !queue.contains(file) { queue.append(file) }
        queued = queue.count
        run()
    }

    /// A finished download, when indexing new downloads is on.
    func downloaded(_ file: URL) {
        guard UserDefaults.standard.bool(forKey: Self.autoKey), Converting.isVideo(file) else { return }
        enqueue([file])
    }

    func stop() {
        queue.removeAll()
        queued = 0
        task?.cancel()
    }

    private func run() {
        guard task == nil, let ffmpeg = manager?.tool("ffmpeg") else { return }
        task = Task(priority: .utility) {
            while !queue.isEmpty, !Task.isCancelled {
                let file = queue.removeFirst()
                queued = queue.count
                working = LibraryStore.shared.entries.first { $0.path == file.path }?.title ?? file.lastPathComponent
                progress = 0
                _ = try? await VisualIndex.index(file, ffmpeg: ffmpeg) { value in
                    Task { @MainActor in self.progress = value }
                }
                reload()
            }
            working = nil
            task = nil
        }
    }
}

/// What a search in the Library finds: files by their names, and moments inside them by what was
/// said (the transcripts) or what's in the picture (each shot, its size and how the camera
/// moves); play from one, or lay shots out in DaVinci Resolve. Photos by what's in them.
struct VisualSearchView: View {
    /// What's typed in the Library's search field.
    let text: String
    /// Where: "all", "library" (the downloads) or a Library folder's id.
    let scope: String

    /// Where to look: both, what was said, or what's in the picture.
    enum Look: String, CaseIterable, Identifiable {
        case everything, said, seen, files, photos
        var id: String { rawValue }
        var label: String {
            switch self {
            case .everything: String(localized: "Everything")
            case .said: String(localized: "What’s Said")
            case .seen: String(localized: "What’s Seen")
            case .files: String(localized: "File Names")
            case .photos: String(localized: "Photos")
            }
        }
        var symbol: String {
            switch self {
            case .everything: "sparkle.magnifyingglass"
            case .said: "waveform"
            case .seen: "eye"
            case .files: "doc.text.magnifyingglass"
            case .photos: "photo.on.rectangle"
            }
        }
    }

    @Environment(AIStudio.self) private var studio
    @Environment(DownloadManager.self) private var manager
    @Environment(\.openWindow) private var openWindow
    @AppStorage("searchLook") private var look = Look.everything
    @State private var said: [TranscriptSearch.Hit] = []
    @State private var searchingSaid = false
    @State private var transcriptCount = 0
    @State private var allSaid = false
    @State private var indexer = VisualIndexer.shared
    @State private var query = ""
    @State private var movement: VisualIndex.Movement?
    @State private var framing: VisualIndex.Framing?
    @State private var selection: Set<VisualIndex.Hit.ID> = []
    @State private var playing: VisualIndex.Hit?
    @State private var status: String?
    @State private var logger = ResolveLogger.shared
    @State private var confirmLog = false
    @AppStorage(VisualIndexer.autoKey) private var automatic = true
    /// The Library's search field is in use: the filters show.
    @Environment(\.isSearching) private var isSearching
    /// The last searches, newest first, one per line.
    @AppStorage("recentSearches") private var recentText = ""
    @State private var folders = FootageFolders.shared
    @State private var photoIndex = PhotoIndex.shared
    @State private var files: [FileSearch.Hit] = []
    @State private var photoHits: [PhotoIndex.Hit] = []
    /// Files whose every matching shot is shown (otherwise only the best).
    @State private var expandedFiles: Set<String> = []
    /// The question in English, for what's seen (nil until translated, or when it's English).
    @State private var englishQuery: String?

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    /// The files in the chosen scope (nil: everywhere).
    private var scopePaths: Set<String>? {
        switch scope {
        case "all": return nil
        case "library": return Set(LibraryStore.shared.entries.map(\.path))
        default:
            guard let folder = folders.folders.first(where: { $0.id.uuidString == scope }) else { return nil }
            return Set((folders.videos[folder.id] ?? []) + (folders.photos[folder.id] ?? []))
        }
    }

    private var hits: [VisualIndex.Hit] {
        guard look == .everything || look == .seen else { return [] }
        // Shots are described in English: a question in another language is searched translated.
        let question = englishQuery.flatMap { $0.isEmpty ? nil : $0 } ?? query
        let found = VisualIndex.search(question, in: indexer.indexes, movement: movement, framing: framing)
        guard let scope = scopePaths else { return found }
        return found.filter { scope.contains($0.path) }
    }

    private var asking: Bool { !trimmed.isEmpty || ((look == .everything || look == .seen) && (movement != nil || framing != nil)) }

    private var recent: [String] { recentText.split(separator: "\n").map(String.init) }

    /// The last searches, newest first (the Library offers them in its search field).
    static var recentSearches: [String] {
        (UserDefaults.standard.string(forKey: "recentSearches") ?? "").split(separator: "\n").map(String.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isSearching { header.transition(.move(edge: .top).combined(with: .opacity)) }
            results
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            logBar
            // Only while there's something to show: shots to send, or looking at videos.
            if !hits.isEmpty || indexer.working != nil || photoIndex.working != nil || !said.isEmpty { footer }
        }
        .animation(.snappy(duration: 0.2), value: isSearching)
        .onChange(of: text, initial: true) { query = text }
        .onAppear {
            folders.start()
            indexer.reload()
            findFilesAndPhotos()
            // Looked at in the background: every photo Pluck knows, and (when on) the videos.
            PhotoIndex.shared.enqueue(PhotoCatalog.shared.allPhotos)
            if automatic, indexer.working == nil { indexer.enqueue(indexer.unindexed) }
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let english = await studio.search.english(query)
            englishQuery = english == query.trimmingCharacters(in: .whitespacesAndNewlines) ? nil : english
            findFilesAndPhotos()
        }
        .task {
            await studio.search.refresh()
            transcriptCount = studio.search.count
        }
        // Names and photos as you type, from what's already known.
        .onChange(of: query) { findFilesAndPhotos() }
        .onChange(of: scope) { findFilesAndPhotos(); Task { await searchSaid(now: true) } }
        .onChange(of: look) { findFilesAndPhotos() }
        // What was said, a moment after typing stops (the picture is searched as you type).
        .task(id: look == .seen || look == .files || look == .photos ? "" : query) { await searchSaid() }
        .sheet(item: $playing) { hit in ShotPlayer(hit: hit) }
    }

    /// What to look for, and for shots how they're filmed (the field is the Library's).
    private var header: some View {
        HStack(spacing: Design.Spacing.controls) {
            Picker("Look For", selection: $look) {
                ForEach(Look.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
            }
            .fixedSize()
            if look == .everything || look == .seen {
                Picker("Movement", selection: $movement) {
                    Text("Any Movement").tag(VisualIndex.Movement?.none)
                    Divider()
                    ForEach(VisualIndex.Movement.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                }
                .fixedSize()
                Picker("Framing", selection: $framing) {
                    Text("Any Framing").tag(VisualIndex.Framing?.none)
                    Divider()
                    ForEach(VisualIndex.Framing.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                }
                .fixedSize()
            }
            Spacer()
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .padding(.horizontal, Design.Spacing.window)
        .padding(.vertical, 10)
    }

    private func searchSaid(now: Bool = false) async {
        let question = query.trimmingCharacters(in: .whitespaces)
        guard look == .everything || look == .said, !question.isEmpty else { said = []; return }
        if !now {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
        }
        searchingSaid = true
        let folder = folders.folders.first { $0.id.uuidString == scope }
        var found = await studio.search.search(question, within: folder.map { [$0.path] } ?? [])
        if scope == "library" {
            let library = Set(LibraryStore.shared.entries.map(\.path))
            found = found.filter { library.contains($0.filePath) }
        }
        // Only if it's still the question asked.
        if question == query.trimmingCharacters(in: .whitespaces) {
            said = found
            allSaid = false
            if !found.isEmpty || !files.isEmpty || !hits.isEmpty { remember(question) }
        }
        searchingSaid = false
    }

    private func findFilesAndPhotos() {
        let question = trimmed
        files = question.isEmpty || !(look == .everything || look == .files) ? [] : FileSearch.find(question, within: scopePaths)
        if question.isEmpty || !(look == .everything || look == .photos) {
            photoHits = []
        } else {
            let words = question.split(separator: " ").map(String.init)
            photoHits = photoIndex.search(words, english: englishQuery, within: scopePaths)
        }
    }

    /// Keeps a search among the recent ones.
    private func remember(_ question: String) {
        let list = [question] + recent.filter { $0.caseInsensitiveCompare(question) != .orderedSame }
        recentText = list.prefix(8).joined(separator: "\n")
    }

    @ViewBuilder private var results: some View {
        if indexer.indexes.isEmpty && transcriptCount == 0 && files.isEmpty && photoHits.isEmpty {
            ToolPage(maxWidth: 680) {
                ToolWelcome(symbol: "sparkle.magnifyingglass", title: Text("Nothing to Search Yet"),
                            subtitle: Text("Pluck looks at every shot in your videos and writes down what’s said in them. Then you can find any moment in your own words."))
                HStack(spacing: Design.Spacing.controls) {
                    Button("Look at My Videos", systemImage: "eye") { indexer.enqueue(indexer.unindexed) }
                        .buttonStyle(BarCapsuleButtonStyle())
                        .disabled(indexer.working != nil || indexer.unindexed.isEmpty)
                    if LocalAI.canTranscribe {
                        Button("Transcribe My Downloads", systemImage: "waveform") { studio.transcribeInBackground(manager.items) }
                            .buttonStyle(GlassCapsuleButtonStyle())
                    }
                }
                .frame(maxWidth: .infinity)
                PageNote(text: Text("Runs on this Mac. Nothing is uploaded."), symbol: "lock.shield")
            }
        } else if said.isEmpty && hits.isEmpty && files.isEmpty && photoHits.isEmpty {
            if searchingSaid {
                ProgressView()
            } else {
                ContentUnavailableView.search(text: query)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if !said.isEmpty { saidSection }
                    if !hits.isEmpty { seenSection }
                    if !files.isEmpty { filesSection }
                    if !photoHits.isEmpty { photosSection }
                }
                .padding(Design.Spacing.window)
            }
        }
    }

    // MARK: - Where to look

    // MARK: - Files and photos

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(Text("Files"), symbol: "doc.text.magnifyingglass", count: files.count)
            ForEach(files.prefix(12)) { hit in
                Button { open(hit) } label: {
                    ItemRow(symbol: hit.isVideo ? "film" : "doc", title: Text(hit.title),
                            subtitle: Text(verbatim: (hit.path as NSString).abbreviatingWithTildeInPath)) {
                        if hit.transcribed { StatusChip(text: Text("Transcribed"), colour: .green) }
                        if !hit.available { StatusChip(text: Text("Drive not connected"), colour: .orange) }
                    } actions: {
                        EmptyView()
                    }
                }
                .buttonStyle(.plain)
                .disabled(!hit.available)
                .contextMenu {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hit.path)]) }
                }
            }
        }
    }

    private func open(_ hit: FileSearch.Hit) {
        let url = URL(fileURLWithPath: hit.path)
        if EditorTarget.canOpen(url) { EditorTarget(path: hit.path).open(openWindow) } else { NSWorkspace.shared.open(url) }
    }

    private var photosSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(Text("Photos"), symbol: "photo.on.rectangle", count: photoHits.count)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)], spacing: 12) {
                ForEach(photoHits) { hit in
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay { FileThumbnail(file: URL(fileURLWithPath: hit.path)) }
                        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.box, style: .continuous))
                        .help(hit.labels.prefix(5).joined(separator: ", "))
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(URL(fileURLWithPath: hit.path)) }
                        .contextMenu {
                            Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: hit.path)) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hit.path)]) }
                        }
                }
            }
        }
    }

    /// "1,204 shots in 38 videos · 52 transcripts".
    private var summary: String {
        var parts: [String] = []
        if !indexer.indexes.isEmpty {
            parts.append(String(AttributedString(localized: "^[\(indexer.indexes.reduce(0) { $0 + $1.shots.count }) shot](inflect: true) in ^[\(indexer.indexes.count) video](inflect: true)").characters))
        }
        if transcriptCount > 0 {
            parts.append(String(AttributedString(localized: "^[\(transcriptCount) transcript](inflect: true)").characters))
        }
        return parts.joined(separator: " · ")
    }

    private func sectionTitle(_ title: Text, symbol: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Label { title } icon: { Image(systemName: symbol) }
                .font(.headline)
            Text(verbatim: "\(count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            if searchingSaid, symbol == "waveform" { ProgressView().controlSize(.small) }
        }
    }

    private var saidSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(Text("Said"), symbol: "waveform", count: said.count)
            ForEach(allSaid ? said : Array(said.prefix(5))) { hit in
                Button { EditorMoment(filePath: hit.filePath, transcriptID: hit.transcriptID, start: hit.start).open(openWindow) } label: {
                    ItemRow(symbol: "waveform", title: Text(hit.title), subtitle: Text(highlighted(hit))) {
                        if !hit.available {
                            StatusChip(text: Text("Drive not connected"), colour: .orange)
                        }
                    } actions: {
                        Label(Format.duration(hit.start), systemImage: "play.fill")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.tint)
                    }
                }
                .buttonStyle(.plain)
                .help("Play from here")
            }
            if said.count > 5 {
                Button(allSaid ? "Show Fewer" : "Show All \(said.count)") { allSaid.toggle() }
                    .buttonStyle(.link)
            }
        }
    }

    /// One shot per file (its best), unless the file is opened up to show all its shots.
    private var shownHits: [(hit: VisualIndex.Hit, more: Int)] {
        var byFile: [String: [VisualIndex.Hit]] = [:], order: [String] = []
        for hit in hits {
            if byFile[hit.path] == nil { order.append(hit.path) }
            byFile[hit.path, default: []].append(hit)
        }
        return order.flatMap { path -> [(hit: VisualIndex.Hit, more: Int)] in
            let list = byFile[path] ?? []
            guard let best = list.first else { return [] }
            if expandedFiles.contains(path) { return [(best, -(list.count - 1))] + list.dropFirst().map { ($0, 0) } }
            return [(best, list.count - 1)]
        }
    }

    private var seenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(Text("Seen"), symbol: "eye", count: Set(hits.map(\.path)).count)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 16)], spacing: 18) {
                ForEach(shownHits, id: \.hit.id) { item in
                    let hit = item.hit
                    ShotCard(hit: hit, selected: selection.contains(hit.id))
                        .overlay(alignment: .topTrailing) {
                            if item.more != 0 {
                                Button {
                                    if expandedFiles.contains(hit.path) { expandedFiles.remove(hit.path) } else { expandedFiles.insert(hit.path) }
                                } label: {
                                    Text(item.more > 0 ? "+\(item.more)" : String(localized: "Fewer"))
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(.black.opacity(0.6), in: .capsule)
                                        .foregroundStyle(.white)
                                }
                                .buttonStyle(.plain)
                                .padding(8)
                                .help(item.more > 0 ? "More shots from this file" : "Show only the best shot")
                            }
                        }
                        .onTapGesture {
                            if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                                if selection.contains(hit.id) { selection.remove(hit.id) } else { selection.insert(hit.id) }
                            } else if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                                playing = hit
                            } else {
                                selection = [hit.id]
                            }
                        }
                        .contextMenu {
                            Button("Play from Here") { playing = hit }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hit.path)]) }
                        }
                }
            }
        }
    }

    /// The words searched for, picked out in the passage.
    private func highlighted(_ hit: TranscriptSearch.Hit) -> AttributedString {
        var text = AttributedString(hit.text)
        for term in hit.terms {
            var range = text.startIndex..<text.endIndex
            while let found = text[range].range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
                text[found].foregroundColor = .primary
                text[found].inlinePresentationIntent = .stronglyEmphasized
                range = found.upperBound..<text.endIndex
            }
        }
        return text
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let working = indexer.working {
                ProgressView(value: indexer.progress).frame(width: 120)
                Text(indexer.queued > 0 ? String(localized: "Looking at “\(working)” (\(indexer.queued) more)…")
                                        : String(localized: "Looking at “\(working)”…"))
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                RowButton(symbol: "stop.fill", label: "Stop") { indexer.stop() }
            } else if let working = photoIndex.working {
                ProgressView().controlSize(.small)
                Text("Looking at “\(working)” (\(photoIndex.queued) more)…").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            }
            Spacer()
            if let status { Text(status).foregroundStyle(.secondary).lineLimit(1) }

            Menu {
                Button("Timeline from Selected Shots", systemImage: "film.stack", action: buildTimeline)
                    .disabled(selected.isEmpty)
                Button("Log the Clips in the Project…", systemImage: "text.badge.star") { confirmLog = true }
                    .disabled(logger.isRunning)
            } label: {
                Label("Send to DaVinci", systemImage: "arrow.up.forward.app")
            }
            .menuStyle(.button)
            .buttonStyle(GlassCapsuleButtonStyle())
            .fixedSize()
            .disabled(!Resolve.isInstalled)
            .help(selected.isEmpty ? "Select shots with ⌘-click for a timeline, or log every clip in the open project with what Pluck saw"
                                   : "A timeline of the selected shots, or a log of every clip in the open project")
            .confirmationDialog("Log the clips in DaVinci Resolve?", isPresented: $confirmLog) {
                    Button("Log Clips") { logger.start() }
                } message: {
                    Text("Every video clip in the open project gets a description, keywords (shot size, camera move, what’s in it) and a marker per shot. Clips Pluck hasn’t looked at yet are analysed first, which can take a while. Your own descriptions are kept; running it again replaces only Pluck’s markers.")
                }
        }
        .padding(.horizontal, Design.Spacing.window)
        .padding(.vertical, 12)
        .font(.callout)
        .background(.bar)
    }

    /// How logging in Resolve is going, above the footer while it runs and after it's done.
    @ViewBuilder private var logBar: some View {
        switch logger.state {
        case .idle:
            EmptyView()
        case .reading, .writing, .analysing:
            HStack(spacing: 12) {
                switch logger.state {
                case .analysing(let file, let done, let total, let progress):
                    ProgressView(value: (Double(done) + progress) / Double(max(total, 1))).frame(width: 120)
                    Text("Looking at “\(file)” (\(done + 1) of \(total)) before logging…")
                        .lineLimit(1).truncationMode(.middle)
                case .writing:
                    ProgressView().controlSize(.small)
                    Text("Writing the log into DaVinci Resolve…")
                default:
                    ProgressView().controlSize(.small)
                    Text("Reading the clips in DaVinci Resolve…")
                }
                Spacer()
                RowButton(symbol: "stop.fill", label: "Stop") { logger.cancel() }
            }
            .logBarStyle()
        case .finished(let clips, let markers, let project):
            HStack(spacing: 12) {
                Label("Logged ^[\(clips) clip](inflect: true) with ^[\(markers) marker](inflect: true) in “\(project)”. In DaVinci, search the media pool or make smart bins on Keywords.",
                      systemImage: "checkmark.circle")
                Spacer()
                Button("Done") { logger.cancel() }
            }
            .logBarStyle()
        case .failed(let message):
            HStack(spacing: 12) {
                ProblemLabel(text: message)
                Spacer()
                Button("OK") { logger.cancel() }
            }
            .logBarStyle()
        }
    }

    private var selected: [VisualIndex.Hit] { hits.filter { selection.contains($0.id) } }

    /// The chosen shots, back to back, in a new Resolve timeline with a marker per shot.
    private func buildTimeline() {
        let shots = selected
        status = String(localized: "Building the timeline in DaVinci Resolve…")
        Task {
            do {
                var name = String(localized: "Pluck shots") + " " + Date.now.formatted(date: .abbreviated, time: .shortened)
                let paths = Array(Set(shots.map(\.path)))
                _ = try await ResolveBridge.run(["action": "import", "paths": paths, "bin": String(localized: "Pluck shots")])
                var rates: [String: Double] = [:]
                for path in paths {
                    let track = try? await AVURLAsset(url: URL(fileURLWithPath: path)).loadTracks(withMediaType: .video).first
                    rates[path] = Double((try? await track?.load(.nominalFrameRate)) ?? 25)
                }
                let created = try await ResolveBridge.createTimeline(name, frameRate: rates[shots[0].path] ?? 25)
                let timelineRate = created.rate
                name = created.name
                var items: [[String: Any]] = [], markers: [[String: Any]] = []
                var record = 0
                for hit in shots {
                    let rate = rates[hit.path].flatMap { $0 > 0 ? $0 : nil } ?? 25
                    let sourceIn = Int((hit.shot.start * rate).rounded()), sourceOut = Int((hit.shot.end * rate).rounded())
                    let frames = Int(((hit.shot.end - hit.shot.start) * timelineRate).rounded())
                    for mediaType in [1, 2] {
                        items.append(["path": hit.path, "track": 1, "recordIn": record, "sourceIn": sourceIn, "sourceOut": sourceOut, "mediaType": mediaType])
                    }
                    markers.append(["frame": record, "color": "Blue", "name": String(hit.shot.description.prefix(60)),
                                    "note": "\(hit.shot.movement.label), \(hit.shot.framing.label)"])
                    record += frames
                }
                _ = try await ResolveBridge.run(["action": "buildTimeline", "name": name, "videoTracks": 1, "items": items, "markers": markers])
                status = String(localized: "Timeline “\(name)” is in DaVinci.")
            } catch {
                status = error.localizedDescription
            }
        }
    }
}

private struct ShotCard: View {
    let hit: VisualIndex.Hit
    let selected: Bool

    private var title: String {
        LibraryStore.shared.entries.first { $0.path == hit.path }?.title ?? URL(fileURLWithPath: hit.path).deletingPathExtension().lastPathComponent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle()
                .fill(.quaternary)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    if let image = NSImage(contentsOf: VisualIndex.thumbnailURL(path: hit.path, start: hit.shot.start)) {
                        Image(nsImage: image).resizable().scaledToFill()
                    }
                }
                .clipShape(.rect(cornerRadius: Design.Radius.thumbnail, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    Text(Format.duration(hit.shot.start) + " – " + Format.duration(hit.shot.end))
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.65), in: .rect(cornerRadius: Design.Radius.badge))
                        .foregroundStyle(.white)
                        .padding(6)
                }
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: Design.Radius.thumbnail, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
            Text(hit.shot.description).font(.callout).lineLimit(2)
            HStack(spacing: 6) {
                Text(hit.shot.movement.label)
                if hit.shot.smooth == true {
                    Text("·")
                    Text("Speed ramp").foregroundStyle(.teal)
                }
                Text("·")
                Text(hit.shot.framing.label)
                Text("·")
                Text(title).lineLimit(1).truncationMode(.middle)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Plays a shot from its start.
private struct ShotPlayer: View {
    let hit: VisualIndex.Hit
    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()

    var body: some View {
        VStack(spacing: 0) {
            VideoPlayer(player: player).frame(minWidth: 720, minHeight: 405)
            HStack {
                Text(hit.shot.description).lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .onAppear {
            player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: hit.path)))
            player.seek(to: CMTime(seconds: hit.shot.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
        }
        .onDisappear { player.pause() }
    }
}

private extension View {
    func logBarStyle() -> some View {
        font(.callout)
            .padding(.horizontal, Design.Spacing.window)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4))
    }
}
