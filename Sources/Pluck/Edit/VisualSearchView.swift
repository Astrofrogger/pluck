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
        task = Task {
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

/// Search: find a moment in your videos by what was said (the transcripts) or what's in the
/// picture (each shot, its size and how the camera moves); play from it, or lay shots out in
/// DaVinci Resolve.
struct VisualSearchView: View {
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
    /// A search to start with (screenshots).
    @MainActor static var startQuery = ""
    @State private var said: [TranscriptSearch.Hit] = []
    @State private var searchingSaid = false
    @State private var transcriptCount = 0
    @State private var allSaid = false
    @State private var indexer = VisualIndexer.shared
    @State private var query = VisualSearchView.startQuery
    @State private var movement: VisualIndex.Movement?
    @State private var framing: VisualIndex.Framing?
    @State private var selection: Set<VisualIndex.Hit.ID> = []
    @State private var playing: VisualIndex.Hit?
    @State private var status: String?
    @State private var logger = ResolveLogger.shared
    @State private var confirmLog = false
    @AppStorage(VisualIndexer.autoKey) private var automatic = true
    /// Where to look: "all", "library" or a watched folder's id.
    @AppStorage("searchScope") private var scopeID = "all"
    /// The last searches, newest first, one per line.
    @AppStorage("recentSearches") private var recentText = ""
    @State private var folders = FootageFolders.shared
    @State private var photoIndex = PhotoIndex.shared
    @State private var files: [FileSearch.Hit] = []
    @State private var photoHits: [PhotoIndex.Hit] = []
    /// The question in English, for what's seen (nil until translated, or when it's English).
    @State private var englishQuery: String?

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    /// The files in the chosen scope (nil: everywhere).
    private var scopePaths: Set<String>? {
        switch scopeID {
        case "all": return nil
        case "library": return Set(LibraryStore.shared.entries.map(\.path))
        default:
            guard let folder = folders.folders.first(where: { $0.id.uuidString == scopeID }) else { return nil }
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

    var body: some View {
        HStack(spacing: 0) {
            scopeList
                .frame(width: 220)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                header
                results
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                logBar
                footer
            }
        }
        .frame(minWidth: 860, idealWidth: 960, minHeight: 600, idealHeight: 680)
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
        .onChange(of: scopeID) { findFilesAndPhotos(); Task { await searchSaid(now: true) } }
        .onChange(of: look) { findFilesAndPhotos() }
        // What was said, a moment after typing stops (the picture is searched as you type).
        .task(id: look == .seen || look == .files || look == .photos ? "" : query) { await searchSaid() }
        .sheet(item: $playing) { hit in ShotPlayer(hit: hit) }
    }

    private var header: some View {
        InputBar(symbol: "magnifyingglass", prompt: prompt, text: $query, onSubmit: { Task { await searchSaid(now: true) } }) {
            BarPicker(symbol: look.symbol, label: Text("Look in"), selection: $look, current: Text(look.label)) {
                ForEach(Look.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
            }
            if look == .everything || look == .seen { shotFilters }
        }
        .help("Find a moment by what was said or what’s in the picture.")
        .padding(Design.Spacing.window)
    }

    private var prompt: Text {
        switch look {
        case .everything: Text("What was said or seen: “the part about lighting”, “drone over a forest”")
        case .said: Text("What was said: “the part about lighting”")
        case .seen: Text("Describe a shot: “drone shot of a forest”, “two people talking”, “whip pan”")
        case .files: Text("A file’s name or title")
        case .photos: Text("What’s in the photo: “beach at sunset”, “a menu”")
        }
    }

    @ViewBuilder private var shotFilters: some View {
            filter(movement?.label ?? String(localized: "Any Movement"), symbol: "video", active: movement != nil) {
                Button("Any Movement") { movement = nil }
                Divider()
                ForEach(VisualIndex.Movement.allCases, id: \.self) { m in Button(m.label) { movement = m } }
            }
            filter(framing?.label ?? String(localized: "Any Framing"), symbol: "viewfinder", active: framing != nil) {
                Button("Any Framing") { framing = nil }
                Divider()
                ForEach(VisualIndex.Framing.allCases, id: \.self) { f in Button(f.label) { framing = f } }
            }
    }

    private func searchSaid(now: Bool = false) async {
        let question = query.trimmingCharacters(in: .whitespaces)
        guard look == .everything || look == .said, !question.isEmpty else { said = []; return }
        if !now {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
        }
        searchingSaid = true
        let folder = folders.folders.first { $0.id.uuidString == scopeID }
        var found = await studio.search.search(question, within: folder.map { [$0.path] } ?? [])
        if scopeID == "library" {
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

    /// A filter menu with the search field's height and look.
    private func filter<Items: View>(_ title: String, symbol: String, active: Bool, @ViewBuilder items: () -> Items) -> some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 6) {
                Label(title, systemImage: symbol)
                Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .font(Design.Typography.control)
            .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .focusEffectDisabled()
        .fixedSize()
        .barControl()
    }

    @ViewBuilder private var results: some View {
        if indexer.indexes.isEmpty && transcriptCount == 0 {
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
        } else if !asking {
            dashboard
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

    private var scopeList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SidebarSection(title: Text("Look In")) {
                        scopeRow(id: "all", symbol: "square.stack.3d.up", title: Text("Everything"), detail: nil)
                        scopeRow(id: "library", symbol: "books.vertical", title: Text("Library"),
                                 detail: Text(verbatim: "\(LibraryStore.shared.entries.count)"))
                    }
                    SidebarSection(title: Text("Folders")) {
                        ForEach(folders.folders) { folder in
                            let count = (folders.videos[folder.id]?.count ?? 0) + (folders.photos[folder.id]?.count ?? 0)
                            scopeRow(id: folder.id.uuidString, symbol: folder.isThere ? "folder" : "externaldrive.badge.xmark",
                                     title: Text(folder.name), detail: folders.scanning.contains(folder.id) ? nil : Text(verbatim: "\(count)"),
                                     busy: folders.scanning.contains(folder.id))
                                .help(folder.path)
                                .contextMenu {
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
                                    Button("Look Through Again") { folders.scan(folder) }
                                    Divider()
                                    Button("Stop Watching", role: .destructive) {
                                        if scopeID == folder.id.uuidString { scopeID = "all" }
                                        folders.remove(folder.id)
                                    }
                                }
                        }
                        Button(action: addFolder) {
                            Label("Add Folder…", systemImage: "plus")
                                .font(.callout)
                                .padding(.horizontal, 8)
                                .frame(minHeight: 26)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Pluck indexes every video and photo in it, and keeps watching it for new ones")
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 12)
            }
            indexingStatus
        }
        .background(.background.secondary)
    }

    private func scopeRow(id: String, symbol: String, title: Text, detail: Text?, busy: Bool = false) -> some View {
        SidebarRow(symbol: symbol, title: title, detail: detail, selected: scopeID == id) {
            if busy { ProgressView().controlSize(.mini) }
        }
        .onTapGesture { scopeID = id }
    }

    /// What's being indexed right now, at the foot of the list.
    @ViewBuilder private var indexingStatus: some View {
        if indexer.working != nil || photoIndex.working != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let working = indexer.working {
                    Text("Shots: \(working)").lineLimit(1).truncationMode(.middle)
                    ProgressView(value: indexer.progress).controlSize(.small)
                }
                if let working = photoIndex.working {
                    Text("Photos: \(working) (\(photoIndex.queued) more)").lineLimit(1).truncationMode(.middle)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(12)
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Watch")
        panel.message = String(localized: "Pluck indexes every video and photo in the folders you choose, and keeps watching them for new ones.")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { folders.add(url) }
        if let last = panel.urls.last, let folder = folders.folders.first(where: { $0.path == last.standardizedFileURL.path }) {
            scopeID = folder.id.uuidString
        }
    }

    // MARK: - Before searching

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    stat(Text("Videos looked at"), value: indexer.indexes.count, symbol: "eye", tint: .blue)
                    stat(Text("Shots"), value: indexer.indexes.reduce(0) { $0 + $1.shots.count }, symbol: "film.stack", tint: .purple)
                    stat(Text("Transcripts"), value: transcriptCount, symbol: "waveform", tint: Design.Brand.pink)
                    stat(Text("Photos"), value: photoIndex.count, symbol: "photo.on.rectangle", tint: .orange)
                }
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recent").font(.headline)
                        FlowLayout(spacing: 8) {
                            ForEach(recent, id: \.self) { search in suggestion(search, symbol: "clock.arrow.circlepath") }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Try").font(.headline)
                    FlowLayout(spacing: 8) {
                        ForEach([String(localized: "someone laughing"), String(localized: "drone shot over water"),
                                 String(localized: "the part about the budget"), String(localized: "close-up of hands"),
                                 String(localized: "people outside at night")], id: \.self) { suggestion($0, symbol: "sparkles") }
                    }
                }
                if folders.folders.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.badge.plus").font(.title2).foregroundStyle(Design.Brand.gradient)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Search a whole drive or project").font(.callout.weight(.semibold))
                            Text("Add a folder and Pluck indexes all its footage and photos.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Add Folder…", action: addFolder).buttonStyle(BrandButtonStyle(large: false))
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous).fill(Color.primary.opacity(0.05)))
                }
            }
            .padding(Design.Spacing.window)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func stat(_ title: Text, value: Int, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(tint.gradient, in: .rect(cornerRadius: 9))
            Text(value, format: .number).font(.title2.weight(.semibold)).monospacedDigit()
            title.font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous).fill(tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous).strokeBorder(tint.opacity(0.18)))
    }

    private func suggestion(_ text: String, symbol: String) -> some View {
        Button {
            query = text
            Task { await searchSaid(now: true) }
        } label: {
            Label(text, systemImage: symbol)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }

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
                Button { PlayerTarget(filePath: hit.filePath, transcriptID: hit.transcriptID, start: hit.start).open(openWindow) } label: {
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

    private var seenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(Text("Seen"), symbol: "eye", count: hits.count)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 16)], spacing: 18) {
                ForEach(hits) { hit in
                    ShotCard(hit: hit, selected: selection.contains(hit.id))
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
            } else {
                Toggle("Index new downloads", isOn: $automatic)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                if !indexer.unindexed.isEmpty, !indexer.indexes.isEmpty {
                    Button("Index \(indexer.unindexed.count) More") { indexer.enqueue(indexer.unindexed) }
                        .buttonStyle(.link)
                }
            }
            Spacer()
            if let status { Text(status).foregroundStyle(.secondary).lineLimit(1) }

            Button("Log in Resolve…") { confirmLog = true }
                .buttonStyle(GlassCapsuleButtonStyle())
                .disabled(!Resolve.isInstalled || logger.isRunning)
                .help("Write shot descriptions, keywords and a marker per shot into the open DaVinci Resolve project")
                .confirmationDialog("Log the clips in DaVinci Resolve?", isPresented: $confirmLog) {
                    Button("Log Clips") { logger.start() }
                } message: {
                    Text("Every video clip in the open project gets a description, keywords (shot size, camera move, what’s in it) and a marker per shot. Clips Pluck hasn’t looked at yet are analysed first, which can take a while. Your own descriptions are kept; running it again replaces only Pluck’s markers.")
                }
            Button("Build Timeline in Resolve", systemImage: "film.stack", action: buildTimeline)
                .buttonStyle(BarCapsuleButtonStyle())
                .disabled(selected.isEmpty || !Resolve.isInstalled)
                .help("Select shots with ⌘-click")
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
                Label("Logged ^[\(clips) clip](inflect: true) with ^[\(markers) marker](inflect: true) in “\(project)”. In Resolve, search the media pool or make smart bins on Keywords.",
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
                status = String(localized: "Timeline “\(name)” is in Resolve.")
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
