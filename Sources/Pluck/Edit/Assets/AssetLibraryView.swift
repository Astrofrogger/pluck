import AVFoundation
import SwiftUI

/// The asset library: sound effects, music and graphics to drag onto a timeline. A tab of the Edit
/// page's panel, and a place in the Library.
struct AssetLibraryView: View {
    /// The project to add to (the Edit page's), else the one open.
    var model: ProjectModel?
    /// The Library's toolbar search, when it's shown there (else its own field).
    var librarySearch: String?

    @State private var store = AssetStore.shared
    @State private var player = AssetPreviewPlayer.shared
    @AppStorage("assetCategory") private var category: AssetCategory = .sfx
    @AppStorage("assetCanvas") private var canvas: AssetCanvas = .landscape
    @AppStorage("assetMovie") private var movie: LogoFile = .prores
    @State private var search = ""
    @State private var kind: String?
    @State private var favouritesOnly = false
    @State private var selected: String?
    @State private var licences = false

    private var project: ProjectModel? { model ?? StudioNavigator.shared.current?.project }
    private var inCategory: [AssetItem] { store.items.filter { $0.category == category } }

    private var shown: [AssetItem] {
        let terms = MediaPanel.fold(librarySearch ?? search).split(whereSeparator: \.isWhitespace).map(String.init)
        return inCategory.filter { item in
            (kind == nil || item.kind == kind) && (!favouritesOnly || store.favourites.contains(item.id))
                && terms.allSatisfy { item.words.contains($0) }
        }
        .sorted { ($0.kindName, $0.variation ?? 0, $0.title) < ($1.kindName, $1.variation ?? 0, $1.title) }
    }

    /// The kinds to filter by: every generator of the shelf, and what packs brought.
    private var kinds: [(id: String, name: String)] {
        let made = AssetKind.allCases.filter { $0.category == category }.map { ($0.rawValue, $0.name) }
        let packs = Set(inCategory.filter { $0.pack != nil }.map(\.kind)).subtracting(made.map(\.0)).sorted().map { ($0, $0.capitalized) }
        return made + packs
    }

    var body: some View {
        VStack(spacing: 0) {
            if librarySearch == nil { PaneSearchField(prompt: "Search assets", text: $search) }
            StudioSegmented(options: AssetCategory.allCases.map { ($0, $0.title) }, selection: $category, fill: true)
                .padding(.horizontal, Design.Sidebar.inset)
                .padding(.top, Design.Spacing.controls)
            kindChips
            content
            footer
        }
        .onChange(of: category) { _, _ in kind = nil; selected = nil }
        .task(id: category) {
            // Sounds are quick to make: the first set comes by itself.
            if category != .graphics, !store.items.contains(where: { $0.category == category && $0.pack == nil }) {
                await store.makeStarter(category)
            }
        }
        .sheet(isPresented: $licences) { AssetLicencesView() }
        .onDisappear { player.stop() }
    }

    private var kindChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                Button { favouritesOnly.toggle() } label: {
                    Image(systemName: favouritesOnly ? "star.fill" : "star").font(.system(size: 10))
                        .foregroundStyle(favouritesOnly ? AnyShapeStyle(Design.Brand.pink) : AnyShapeStyle(Design.Studio.textQuiet))
                        .frame(width: 22, height: 22)
                        .background(Design.Studio.raised, in: .circle)
                }
                .buttonStyle(.plain)
                .help("Show only favourites")
                chip(nil, String(localized: "All"))
                ForEach(kinds, id: \.id) { chip($0.id, $0.name) }
            }
            .padding(.horizontal, Design.Sidebar.inset)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
    }

    private func chip(_ id: String?, _ name: String) -> some View {
        let on = kind == id
        return Button { kind = id } label: {
            Text(verbatim: name)
                .font(Design.Studio.hint)
                .foregroundStyle(on ? Design.Studio.text : Design.Studio.textQuiet)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(on ? Design.Studio.line : Design.Studio.raised, in: .capsule)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var content: some View {
        if inCategory.isEmpty, store.making == nil {
            StudioEmptyState(symbol: category == .graphics ? "sparkles" : "waveform", title: "Made by Pluck",
                             button: "Make a set") { Task { await store.makeStarter(category, canvas: canvas, movie: movie) } }
        } else {
            ScrollView {
                if category == .graphics {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: Design.Spacing.controls)], spacing: Design.Spacing.controls) {
                        ForEach(shown) { tile($0) }
                    }
                    .padding(.horizontal, Design.Sidebar.inset + Design.Sidebar.rowPadding)
                    .padding(.vertical, 4)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(shown) { row($0) }
                    }
                    .padding(.horizontal, Design.Sidebar.inset)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let making = store.making {
                PlumSpinner()
                Text(verbatim: making).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                StudioProgress(share: store.share)
            } else {
                Button("Make More") { Task { await store.make(makeKinds, canvas: canvas, movie: movie) } }
                    .buttonStyle(StudioFlatButtonStyle())
                    .help("New variations, made on this Mac")
                if category == .graphics {
                    Menu {
                        Picker("Size", selection: $canvas) {
                            ForEach(AssetCanvas.allCases) { Text(verbatim: $0.label).tag($0) }
                        }
                        .pickerStyle(.inline)
                        Picker("File", selection: $movie) {
                            ForEach([LogoFile.prores, .hevc]) { Text(verbatim: $0.label).help($0.help).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        StudioMenuLabel(title: canvas.label + " · " + movie.label, quiet: true)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize()
                }
                if let problem = store.problem {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Design.Studio.warn).help(problem)
                }
            }
            Spacer(minLength: 0)
            Button { licences = true } label: {
                Image(systemName: "checkmark.seal").foregroundStyle(Design.Studio.textQuiet)
            }
            .buttonStyle(.plain)
            .help("Assets & licences")
        }
        .padding(.horizontal, Design.Sidebar.inset + Design.Sidebar.rowPadding)
        .frame(height: 44)
    }

    /// What Make More makes: the kind chosen, else one of each kind of the shelf.
    private var makeKinds: [AssetKind] {
        if let kind, let one = AssetKind(rawValue: kind) { return [one] }
        return AssetKind.allCases.filter { $0.category == category }
    }

    // MARK: - Rows and tiles

    private func row(_ item: AssetItem) -> some View {
        let playing = player.playing == item.id
        return SidebarRow(symbol: playing ? "stop.fill" : (item.generated?.symbol ?? "waveform"), title: Text(verbatim: item.title),
                          detail: Text(verbatim: item.detail), selected: selected == item.id) {
            star(item)
        }
        .contentShape(.rect)
        .onTapGesture(count: 2) { add(item) }
        .onTapGesture {
            selected = item.id
            player.toggle(item)
        }
        .onDrag { Self.dragPayload(item) }
        .contextMenu { menu(item) }
        .help("Click to listen; drag onto the timeline, or double-click to add it at the playhead")
    }

    private func tile(_ item: AssetItem) -> some View {
        VStack(spacing: 4) {
            AssetGraphicPreview(item: item)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(.rect(cornerRadius: Design.Radius.small))
                .overlay {
                    if selected == item.id {
                        RoundedRectangle(cornerRadius: Design.Radius.small).strokeBorder(Design.Brand.pink, lineWidth: 2)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if store.favourites.contains(item.id) {
                        Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Design.Brand.pink).padding(4)
                    }
                }
            Text(verbatim: item.title).font(.caption).lineLimit(1).truncationMode(.tail)
        }
        .contentShape(.rect)
        .onTapGesture(count: 2) { add(item) }
        .onTapGesture { selected = item.id }
        .onDrag { Self.dragPayload(item) }
        .contextMenu { menu(item) }
        .help(Text(verbatim: item.detail))
    }

    private func star(_ item: AssetItem) -> some View {
        let on = store.favourites.contains(item.id)
        return Button { store.toggleFavourite(item) } label: {
            Image(systemName: on ? "star.fill" : "star").font(.system(size: 10))
                .foregroundStyle(on ? AnyShapeStyle(Design.Brand.pink) : AnyShapeStyle(Design.Studio.textFaint))
        }
        .buttonStyle(.plain)
        .padding(.leading, 6)
    }

    @ViewBuilder private func menu(_ item: AssetItem) -> some View {
        if project != nil {
            Button("Add at the Playhead") { add(item) }
            Divider()
        }
        Button(store.favourites.contains(item.id) ? "Remove from Favourites" : "Add to Favourites") { store.toggleFavourite(item) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Divider()
        Text(verbatim: item.licence)
    }

    /// Sounds go on a sound track, music under the edit, graphics over the picture.
    private func add(_ item: AssetItem) {
        guard let project else { return }
        Task {
            switch item.category {
            case .sfx: await project.addAudio(item.timelineFile)
            case .music: await project.addMusic(item.timelineFile)
            case .graphics: await project.addOverlay(item.timelineFile)
            }
        }
    }

    /// What's dragged: the file's URL (a still's movie), as the media panel drags its files.
    static func dragPayload(_ item: AssetItem) -> NSItemProvider {
        NSItemProvider(object: item.timelineFile as NSURL)
    }

    /// The Library's place for the assets (its sidebar row; the Library shows this view there).
    static var libraryCollection: LibraryView.Collection { .location(AssetStore.root.path) }

    static var librarySidebar: some View {
        Section {
            Label("Assets", systemImage: "square.stack.3d.up").tag(libraryCollection)
        }
    }
}

/// A graphic's tile: on a dark checkerboard (it's see-through); Pluck's own move while the pointer is on them.
struct AssetGraphicPreview: View {
    let item: AssetItem
    @State private var hovering = false
    @State private var poster: CGImage?
    private static let size = CGSize(width: 192, height: 108)

    var body: some View {
        ZStack {
            Canvas { context, size in
                let side: CGFloat = 8
                for x in stride(from: 0, to: size.width, by: side) {
                    for y in stride(from: 0, to: size.height, by: side) where (Int(x / side) + Int(y / side)) % 2 == 0 {
                        context.fill(Path(CGRect(x: x, y: y, width: side, height: side)), with: .color(Design.Studio.raised))
                    }
                }
            }
            .background(Design.Studio.backdrop)
            if let kind = item.generated, let variation = item.variation {
                TimelineView(.animation(minimumInterval: 1.0 / 25, paused: !hovering || !kind.animated)) { timeline in
                    let t = hovering ? timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: AssetGraphics.length(kind)) : AssetGraphics.length(kind) * 0.3
                    if let image = AssetGraphics.image(kind, seed: AssetMaker.seed(kind, variation), t: t, size: previewSize) {
                        Image(decorative: image, scale: 1).resizable().scaledToFit()
                    }
                }
            } else if let poster {
                Image(decorative: poster, scale: 1).resizable().scaledToFit()
            }
        }
        .onHover { hovering = $0 }
        .task(id: item.id) {
            guard item.generated == nil else { return }
            if let image = NSImage(contentsOf: item.url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                poster = image
            } else {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: item.url))
                generator.maximumSize = Self.size
                poster = try? await generator.image(at: .zero).image
            }
        }
    }

    /// Drawn small, in the graphic's own shape (a tall one stays tall).
    private var previewSize: CGSize {
        let canvas = (item.canvas ?? .landscape).size
        return canvas.width >= canvas.height ? Self.size : CGSize(width: 61, height: 108)
    }
}

/// Listening to a sound before using it: one at a time.
@MainActor
@Observable
final class AssetPreviewPlayer {
    static let shared = AssetPreviewPlayer()
    private(set) var playing: String?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ending: Task<Void, Never>?

    func toggle(_ item: AssetItem) {
        if playing == item.id { stop(); return }
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: item.url) else { return }
        self.player = player
        player.play()
        playing = item.id
        let length = player.duration
        ending = Task {
            try? await Task.sleep(for: .seconds(length + 0.05))
            if !Task.isCancelled, playing == item.id { stop() }
        }
    }

    func stop() {
        ending?.cancel()
        player?.stop()
        player = nil
        playing = nil
    }
}

/// Every asset and its licence, and the CC0 pack to fetch.
struct AssetLicencesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = AssetStore.shared
    @State private var downloader = AssetPackDownloader.shared
    @AppStorage(AssetPackDownloader.manifestKey) private var manifest = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            Text("Assets & licences").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
            List {
                Section {
                    ForEach(store.items) { item in
                        HStack(spacing: 8) {
                            Text(verbatim: item.title).lineLimit(1)
                            if let author = item.author { Text(verbatim: author).foregroundStyle(Design.Studio.textQuiet).lineLimit(1) }
                            Spacer(minLength: 4)
                            if let page = item.sourcePage.flatMap(URL.init(string:)) {
                                Link(destination: page) { Image(systemName: "arrow.up.right.square") }.help(Text(verbatim: page.absoluteString))
                            }
                            StudioChip(text: Text(verbatim: item.licence), colour: item.pack == nil ? Design.Studio.textQuiet : Design.Studio.good, tinted: item.pack != nil)
                        }
                        .font(Design.Studio.body)
                    }
                } footer: {
                    Text("Made by Pluck: free for any work, no credit needed. Packs: CC0 (public domain) only.")
                        .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                }
            }
            .frame(minHeight: 260)
            HStack(spacing: 8) {
                TextField("Pack address", text: $manifest, prompt: Text(verbatim: "https://…/manifest.json"))
                    .textFieldStyle(.roundedBorder)
                if downloader.running {
                    StudioProgress(share: downloader.share ?? 0).frame(width: 80)
                    Button("Stop") { downloader.cancel() }.buttonStyle(StudioFlatButtonStyle())
                } else {
                    Button("Get Pack") { downloader.start() }
                        .buttonStyle(StudioFlatButtonStyle())
                        .disabled(manifest.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let problem = downloader.problem { ProblemLabel(text: problem) }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(StudioFlatButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 520, height: 480)
    }
}
