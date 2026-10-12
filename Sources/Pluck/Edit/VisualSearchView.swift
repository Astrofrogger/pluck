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
        LibraryStore.shared.entries.filter { $0.kind == .video && FileManager.default.fileExists(atPath: $0.path) }
            .map(\.file).filter { !VisualIndex.isIndexed($0) }
    }

    var videoCount: Int { LibraryStore.shared.entries.filter { $0.kind == .video }.count }

    func reload() {
        let paths = Set(LibraryStore.shared.entries.map(\.path))
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
        case everything, said, seen
        var id: String { rawValue }
        var label: String {
            switch self {
            case .everything: String(localized: "Said and Seen")
            case .said: String(localized: "What’s Said")
            case .seen: String(localized: "What’s Seen")
            }
        }
        var symbol: String {
            switch self {
            case .everything: "sparkle.magnifyingglass"
            case .said: "waveform"
            case .seen: "eye"
            }
        }
    }

    @Environment(AIStudio.self) private var studio
    @Environment(DownloadManager.self) private var manager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
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

    private var hits: [VisualIndex.Hit] {
        guard look != .said else { return [] }
        return VisualIndex.search(query, in: indexer.indexes, movement: movement, framing: framing)
    }

    private var asking: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty || (look != .said && (movement != nil || framing != nil)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            results
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            logBar
            footer
        }
        .frame(minWidth: 860, idealWidth: 960, minHeight: 600, idealHeight: 680)
        .onAppear { indexer.reload() }
        .task {
            await studio.search.refresh()
            transcriptCount = studio.search.count
        }
        // What was said, a moment after typing stops (the picture is searched as you type).
        .task(id: look == .seen ? "" : query) { await searchSaid() }
        .sheet(item: $playing) { hit in ShotPlayer(hit: hit) }
    }

    private var header: some View {
        InputBar(symbol: "magnifyingglass", prompt: prompt, text: $query, onSubmit: { Task { await searchSaid(now: true) } }) {
            BarPicker(symbol: look.symbol, label: Text("Look in"), selection: $look, current: Text(look.label)) {
                ForEach(Look.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
            }
            if look != .said { shotFilters }
        }
        .help("Find a moment by what was said or what’s in the picture.")
        .padding(Design.Spacing.window)
    }

    private var prompt: Text {
        switch look {
        case .everything: Text("What was said or seen: “the part about lighting”, “drone over a forest”")
        case .said: Text("What was said: “the part about lighting”")
        case .seen: Text("Describe a shot: “drone shot of a forest”, “two people talking”, “whip pan”")
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
        guard look != .seen, !question.isEmpty else { said = []; return }
        if !now {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
        }
        searchingSaid = true
        let found = await studio.search.search(question)
        // Only if it's still the question asked.
        if question == query.trimmingCharacters(in: .whitespaces) {
            said = found
            allSaid = false
        }
        searchingSaid = false
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
            ToolPage(maxWidth: 680) {
                ToolWelcome(symbol: "sparkle.magnifyingglass", title: Text("Search Your Videos"),
                            subtitle: Text(summary))
            }
        } else if said.isEmpty && hits.isEmpty {
            if searchingSaid {
                ProgressView()
            } else {
                ContentUnavailableView.search(text: query)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Spacing.section) {
                    if !said.isEmpty { saidSection }
                    if !hits.isEmpty { seenSection }
                }
                .padding(Design.Spacing.window)
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
                Button { openWindow(value: PlayerTarget(filePath: hit.filePath, transcriptID: hit.transcriptID, start: hit.start)) } label: {
                    ItemRow(symbol: "waveform", title: Text(hit.title), subtitle: Text(highlighted(hit))) {
                        EmptyView()
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
            Button("Done") { dismiss() }
                .buttonStyle(GlassCapsuleButtonStyle())
                .keyboardShortcut(.cancelAction)
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
