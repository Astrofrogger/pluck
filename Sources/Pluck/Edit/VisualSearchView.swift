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

/// Find Shots: search the Library's videos by what's in them, the shot size and the camera
/// movement, play from the moment, or lay the shots out in DaVinci Resolve.
struct VisualSearchView: View {
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

    private var hits: [VisualIndex.Hit] {
        VisualIndex.search(query, in: indexer.indexes, movement: movement, framing: framing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            results
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            logBar
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 560)
        .onAppear { indexer.reload() }
        .sheet(item: $playing) { hit in ShotPlayer(hit: hit) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(symbol: "sparkle.magnifyingglass", title: Text("Find Shots"),
                        subtitle: Text("Search your videos and footage by what’s in the picture, the shot size and how the camera moves."),
                        subtitleIsName: false)
            HStack(spacing: Design.Spacing.controls) {
                HStack(spacing: Design.Spacing.controls) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Describe a shot: “drone shot of a forest”, “two people talking”, “whip pan”", text: $query)
                        .textFieldStyle(.plain)
                }
                .font(Design.Typography.control)
                .barControl()
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
        }
        .padding(Design.Spacing.window)
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
        if indexer.indexes.isEmpty {
            ContentUnavailableView {
                Label("No Videos Indexed Yet", systemImage: "sparkle.magnifyingglass")
            } description: {
                Text("Pluck looks at every shot in your Library’s videos: what’s in it, the shot size and how the camera moves. Then you can search them in your own words.")
            } actions: {
                Button("Index My Library") { indexer.enqueue(indexer.unindexed) }
                    .buttonStyle(.borderedProminent)
                    .disabled(indexer.working != nil || indexer.unindexed.isEmpty)
            }
        } else if query.isEmpty && movement == nil && framing == nil {
            ContentUnavailableView("Search Your Shots", systemImage: "sparkle.magnifyingglass",
                                   description: Text("\(indexer.indexes.reduce(0) { $0 + $1.shots.count }) shots in \(indexer.indexes.count) videos."))
        } else if hits.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ScrollView {
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
                .padding(Design.Spacing.window)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let working = indexer.working {
                ProgressView(value: indexer.progress).frame(width: 120)
                Text(indexer.queued > 0 ? String(localized: "Looking at “\(working)” (\(indexer.queued) more)…")
                                        : String(localized: "Looking at “\(working)”…"))
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Button("Stop") { indexer.stop() }
            } else {
                Toggle("Index new downloads", isOn: $automatic)
                if !indexer.unindexed.isEmpty, !indexer.indexes.isEmpty {
                    Button("Index \(indexer.unindexed.count) More") { indexer.enqueue(indexer.unindexed) }
                }
            }
            Spacer()
            if let status { Text(status).foregroundStyle(.secondary).lineLimit(1) }
            else if !(query.isEmpty && movement == nil && framing == nil) {
                Text("^[\(hits.count) shot](inflect: true)").foregroundStyle(.secondary).monospacedDigit()
            }
            Button("Log in Resolve…") { confirmLog = true }
                .disabled(!Resolve.isInstalled || logger.isRunning)
                .help("Write shot descriptions, keywords and a marker per shot into the open DaVinci Resolve project")
                .confirmationDialog("Log the clips in DaVinci Resolve?", isPresented: $confirmLog) {
                    Button("Log Clips") { logger.start() }
                } message: {
                    Text("Every video clip in the open project gets a description, keywords (shot size, camera move, what’s in it) and a marker per shot. Clips Pluck hasn’t looked at yet are analysed first, which can take a while. Your own descriptions are kept; running it again replaces only Pluck’s markers.")
                }
            Button("Build Timeline in Resolve", action: buildTimeline)
                .disabled(selected.isEmpty || !Resolve.isInstalled)
                .help("Select shots with ⌘-click")
        }
        .padding(.horizontal, Design.Spacing.window)
        .padding(.vertical, 12)
        .font(.callout)
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
                Button("Stop") { logger.cancel() }
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
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
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
