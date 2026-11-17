import SwiftUI
import UniformTypeIdentifiers

/// A review project: the path to the folder shown, its folders, then its assets. Files and folders
/// dropped anywhere are added; a file dropped on a card stacks a new version; cards drag onto folders.
struct DeliverProjectView: View {
    @Bindable var nav: StudioNavigator
    let project: UUID
    let folder: UUID?
    @State private var store = DeliverStore.shared
    @State private var copies = DeliverCopies.shared
    @State private var targeted = false
    @State private var sharing: Deliver.Scope?
    @State private var publishing: Deliver.Scope?
    @State private var naming = false
    @State private var name = ""
    @State private var stacking: (url: URL, asset: Deliver.Asset)?
    @State private var problem: String?
    @AppStorage("deliverProjectList") private var list = false
    @AppStorage("deliverProjectSort") private var sort = "date"
    /// The first version dropped on a card asks first; after a yes, it doesn't again.
    @AppStorage("deliverStackAsked") private var stackAsked = false
    @State private var search = ""
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    /// ⌘-clicked cards, for Set Status, Move and Share.
    @State private var chosen: Set<UUID> = []
    @State private var info: UUID?

    private var content: Deliver.ProjectContent { store.content(project) }
    private var folders: [Deliver.Folder] { content.folders.filter { $0.parent == folder }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    private var assets: [Deliver.Asset] {
        // A search looks through the whole project (name, keywords, assignee, notes).
        let words = search.lowercased().split(separator: " ").map(String.init)
        let pool = words.isEmpty ? content.assets.filter { $0.folder == folder } : content.assets.filter { asset in
            let fields = asset.fields
            let haystack = ([asset.name, fields?.assignee ?? "", fields?.notes ?? ""] + (fields?.keywords ?? [])).joined(separator: " ").lowercased()
            return words.allSatisfy(haystack.contains)
        }
        return pool.sorted {
            sort == "name" ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.created > $1.created
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    countRow
                    DeliverWaitingRows(project: project)
                    if !folders.isEmpty && search.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 230), spacing: 10)], alignment: .leading, spacing: 10) {
                            ForEach(folders) { folderTile($0) }
                        }
                    }
                    if assets.isEmpty && folders.isEmpty {
                        StudioEmptyState(symbol: "square.and.arrow.down", title: "Drop videos here", targeted: targeted)
                            .frame(minHeight: 360)
                            .studioDropZone(targeted: targeted)
                    } else if list {
                        VStack(spacing: 4) { ForEach(assets) { asset in listRow(asset) } }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 230), spacing: 14)], alignment: .leading, spacing: 14) {
                            ForEach(assets) { asset in
                                DeliverAssetCard(asset: asset, working: copies.working, chosen: chosen.contains(asset.id), choose: { choose(asset) }) { menu(asset) }
                                    .overlay { if chosen.contains(asset.id) { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Design.Brand.pink, lineWidth: 2) } }
                                    .onTapGesture { open(asset) }
                                    .draggable(asset.id.uuidString)
                                    .dropDestination(for: URL.self) { urls, _ in stack(urls, on: asset) }
                                    .contextMenu { menu(asset) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            add(urls.filter(\.isFileURL))
            return true
        } isTargeted: { targeted = $0 }
        .sheet(item: Binding(get: { sharing.map(DeliverShareTarget.init) }, set: { sharing = $0?.scope })) { DeliverShareSheet(scope: $0.scope) }
        .sheet(item: Binding(get: { publishing.map(DeliverShareTarget.init) }, set: { publishing = $0?.scope })) { DeliverPublishSheet(scope: $0.scope) }
        .alert("New Folder", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Create") { store.newFolder(name, in: project, parent: folder) }
            Button("Cancel", role: .cancel) {}
        }
        .alert(Text(verbatim: stacking.map { String(localized: "Add as version \(($0.asset.versions.map(\.number).max() ?? 0) + 1) of \($0.asset.name)?") } ?? ""),
               isPresented: Binding(get: { stacking != nil }, set: { if !$0 { stacking = nil } })) {
            Button("Add Version") {
                if let stacking { stackAsked = true; try? store.addVersion(stacking.url, to: stacking.asset.id) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: Binding(get: { info.map(DeliverProjectID.init) }, set: { info = $0?.id })) { DeliverFieldsSheet(asset: $0.id) }
        .alert(Text(verbatim: problem ?? ""), isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) { Button("OK") {} }
    }

    private func add(_ urls: [URL]) {
        do { try store.add(urls, to: project, folder: folder) } catch { problem = String(localized: "This project is full.") }
    }

    /// Two rows: where this is (Projects / project / folder…) with People, Publish and Share; then the view's tools
    /// (Appearance, Sorted by, search, add).
    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Button { nav.deliver = .projects } label: { Text("Projects") }.buttonStyle(.plain).foregroundStyle(Design.Studio.textQuiet)
                    Text(verbatim: "/").foregroundStyle(Design.Studio.textFaint)
                    Button { nav.deliver = .project(project, folder: nil) } label: { Text(verbatim: store.project(project)?.name ?? "") }
                        .buttonStyle(.plain).foregroundStyle(folder == nil ? Design.Studio.text : Design.Studio.textQuiet)
                    ForEach(store.folderPath(folder, in: project)) { step in
                        Text(verbatim: "/").foregroundStyle(Design.Studio.textFaint)
                        Button { nav.deliver = .project(project, folder: step.id) } label: { Text(verbatim: step.name) }
                            .buttonStyle(.plain).foregroundStyle(step.id == folder ? Design.Studio.text : Design.Studio.textQuiet)
                            .dropDestination(for: String.self) { ids, _ in move(ids, to: step.id) }
                    }
                }
                .font(Design.Studio.body)
                .lineLimit(1)
                Spacer()
                if DeliverPeople.main() != nil {
                    Button { nav.deliver = .people } label: { Image(systemName: "person.2.fill").font(.system(size: 11)) }
                        .buttonStyle(StudioFlatButtonStyle()).help(Text(verbatim: DeliverPeople.title))
                }
                Button("Publish…") { publishing = .project(project) }.buttonStyle(StudioFlatButtonStyle())
                Button { sharing = folder.map { .folder($0, project: project) } ?? .project(project) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                    .buttonStyle(StudioFlatButtonStyle(prominent: true))
            }
            .frame(height: 48)
            HStack(spacing: 18) {
                Menu {
                    Picker(selection: $list) {
                        Label("Grid", systemImage: "square.grid.2x2").tag(false)
                        Label("List", systemImage: "list.bullet").tag(true)
                    } label: { EmptyView() }.pickerStyle(.inline)
                } label: { DeliverToolLabel(symbol: list ? "list.bullet" : "square.grid.2x2", title: "Appearance") }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                Menu {
                    Picker(selection: $sort) {
                        Text("Date Added").tag("date")
                        Text("Name").tag("name")
                    } label: { EmptyView() }.pickerStyle(.inline)
                } label: {
                    DeliverToolLabel(symbol: "line.3.horizontal.decrease", title: "Sorted by", value: sort == "name" ? String(localized: "Name") : String(localized: "Date Added"))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                if searching || !search.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Design.Studio.textQuiet)
                        TextField("Search", text: $search).textFieldStyle(.plain).font(Design.Studio.body).frame(width: 160).focused($searchFocused)
                            .onSubmit { if search.isEmpty { searching = false } }
                            .onExitCommand { search = ""; searching = false }
                    }
                    .padding(.horizontal, 8).frame(height: 26)
                    .background(Design.Studio.backdrop, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
                    .onAppear { searchFocused = true }
                } else {
                    Button { searching = true } label: { Image(systemName: "magnifyingglass").font(.system(size: 13)).frame(width: 22, height: 26).contentShape(.rect) }
                        .buttonStyle(.plain).foregroundStyle(Design.Studio.textQuiet).help("Search")
                }
                Menu {
                    Button("New Folder…") { naming = true; name = "" }
                    Button("Add Files…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = true
                        if panel.runModal() == .OK { add(panel.urls) }
                    }
                } label: { Image(systemName: "plus").font(.system(size: 13)).foregroundStyle(Design.Studio.textQuiet).frame(width: 22, height: 26).contentShape(.rect) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                Spacer()
            }
            .frame(height: 36)
            Rectangle().fill(Design.Studio.line).frame(height: 1).padding(.top, 6)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func folderTile(_ item: Deliver.Folder) -> some View {
        let inside = store.subfolders(item.id, in: project)
        return Button { nav.deliver = .project(project, folder: item.id) } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill").font(.system(size: 15)).foregroundStyle(Design.Studio.textQuiet)
                Text(verbatim: item.name).font(Design.Studio.body).foregroundStyle(Design.Studio.text).lineLimit(1)
                Spacer()
                Text(verbatim: "\(content.assets.filter { $0.folder.map(inside.contains) == true }.count)").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Design.Studio.raised, in: .rect(cornerRadius: 8, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .dropDestination(for: String.self) { ids, _ in move(ids, to: item.id) }
        .contextMenu {
            Button("Share Folder…") { sharing = .folder(item.id, project: project) }
        }
    }

    private func listRow(_ asset: Deliver.Asset) -> some View {
        HStack(spacing: 12) {
            Button { choose(asset) } label: { DeliverCheckbox(on: chosen.contains(asset.id)) }.buttonStyle(.plain)
            DeliverPoster(asset: asset).frame(width: 64, height: 36).clipShape(.rect(cornerRadius: 4))
            Text(verbatim: asset.name).font(Design.Studio.body).foregroundStyle(Design.Studio.text).lineLimit(1)
            Spacer()
            DeliverStatusPill(status: asset.status)
            Text(verbatim: "v\(asset.current.number)").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).frame(width: 30)
            Label { Text(verbatim: "\(store.comments(asset.id).count)") } icon: { Image(systemName: "text.bubble") }
                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).frame(width: 44)
            Text(asset.created, format: .dateTime.day().month()).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).frame(width: 60)
            DeliverMoreMenu { menu(asset) }
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(Design.Studio.raised, in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
        .overlay { if chosen.contains(asset.id) { RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Design.Brand.pink, lineWidth: 2) } }
        .onTapGesture { open(asset) }
        .draggable(asset.id.uuidString)
        .dropDestination(for: URL.self) { urls, _ in stack(urls, on: asset) }
        .contextMenu { menu(asset) }
    }

    /// A click opens the asset; ⌘-click adds it to (or takes it from) the selection.
    private func open(_ asset: Deliver.Asset) {
        if NSEvent.modifierFlags.contains(.command) || !chosen.isEmpty { choose(asset) } else { nav.deliver = .asset(asset.id, version: nil, comment: nil) }
    }

    private func choose(_ asset: Deliver.Asset) {
        if chosen.contains(asset.id) { chosen.remove(asset.id) } else { chosen.insert(asset.id) }
    }

    /// "☐ 3 assets • 1.2 GB": select all or none; with a selection, what can be done to it.
    private var countRow: some View {
        let all = !assets.isEmpty && assets.allSatisfy { chosen.contains($0.id) }
        return HStack(spacing: 10) {
            Button { chosen = all ? [] : Set(assets.map(\.id)) } label: { DeliverCheckbox(on: all, some: !chosen.isEmpty) }
                .buttonStyle(.plain).disabled(assets.isEmpty).help(all ? "Clear the selection" : "Select All")
            if chosen.isEmpty {
                Text("\(assets.count) assets")
                Text(verbatim: "•")
                Text(verbatim: ByteCountFormatter.string(fromByteCount: assets.reduce(0) { $0 + $1.current.size }, countStyle: .file))
                Spacer()
            } else {
                Text("\(chosen.count) selected").foregroundStyle(Design.Studio.text)
                Spacer()
                Menu {
                    ForEach(Deliver.Status.allCases, id: \.self) { status in
                        Button(DeliverStatusPill.title(status)) { for id in chosen { store.setStatus(status, of: id, by: DeliverSettings.author) } }
                    }
                } label: { StudioMenuLabel(title: String(localized: "Set Status")) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                Menu {
                    Button("Top of the Project") { for id in chosen { store.move(asset: id, to: nil) } }
                    ForEach(content.folders) { item in Button { for id in chosen { store.move(asset: id, to: item.id) } } label: { Text(verbatim: item.name) } }
                } label: { StudioMenuLabel(title: String(localized: "Move")) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                Button("Share Selected…") {
                    let ids = content.assets.map(\.id).filter(chosen.contains)
                    sharing = ids.count == 1 ? .asset(ids[0], project: project) : .assets(ids, project: project)
                }.buttonStyle(StudioFlatButtonStyle(prominent: true))
                Button { chosen = [] } label: { Image(systemName: "xmark") }.buttonStyle(StudioFlatButtonStyle()).help("Clear the selection")
            }
        }
        .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
        .frame(height: 30)
    }

    @ViewBuilder private func menu(_ asset: Deliver.Asset) -> some View {
        Button("Share…") { sharing = .asset(asset.id, project: project) }
        Button("Info…") { info = asset.id }
        Button("Publish…") { publishing = .asset(asset.id, project: project) }
        Button("Reveal in Finder") { if let url = store.original(asset.current) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
        Menu("Set Status") {
            ForEach(Deliver.Status.allCases, id: \.self) { status in
                Button(DeliverStatusPill.title(status)) { store.setStatus(status, of: asset.id, by: DeliverSettings.author) }
            }
        }
        if asset.versions.count > 1 {
            Menu("Versions") {
                ForEach(asset.versions.reversed()) { version in
                    Menu(String(localized: "Version \(version.number)")) {
                        Button("Make Current") { store.makeCurrent(version.id, of: asset.id) }
                        Button("Remove from Stack") { store.removeVersion(version.id, of: asset.id) }
                    }
                }
            }
        }
        if case .failed = asset.current.copy { Button("Retry Review Copy") { copies.retry(asset: asset.id, version: asset.current.id) } }
        Divider()
        Button("Remove from Project", role: .destructive) { store.remove(asset: asset.id) }
    }

    private func move(_ ids: [String], to folder: UUID) -> Bool {
        for id in ids.compactMap(UUID.init(uuidString:)) where store.find(id)?.project == project { store.move(asset: id, to: folder) }
        return true
    }

    private func stack(_ urls: [URL], on asset: Deliver.Asset) -> Bool {
        guard let url = urls.first(where: { $0.isFileURL && !$0.hasDirectoryPath }) else { return false }
        if stackAsked { try? store.addVersion(url, to: asset.id) } else { stacking = (url, asset) }
        return true
    }
}

/// A small square tick box (the card's and the count row's): empty, ticked, or a dash for some.
struct DeliverCheckbox: View {
    let on: Bool
    var some = false

    var body: some View {
        Image(systemName: on ? "checkmark.square.fill" : some ? "minus.square.fill" : "square")
            .font(.system(size: 14))
            .foregroundStyle(on || some ? AnyShapeStyle(Design.Brand.pink) : AnyShapeStyle(Design.Studio.textQuiet))
            .frame(width: 18, height: 18)
            .contentShape(.rect)
    }
}

/// An asset's card: the picture on black (hover scrubs the strip) with its length, a tick box while hovered or chosen;
/// the name, version and date with a "⋯" menu; then a status box (set from its menu) with rating and comment count.
/// A ring while its copy is made, a red dot and Retry when that failed.
struct DeliverAssetCard<Actions: View>: View {
    let asset: Deliver.Asset
    var working: UUID?
    var chosen = false
    var choose: () -> Void = {}
    @ViewBuilder var actions: () -> Actions
    @State private var store = DeliverStore.shared
    @State private var scrub: Double?
    @State private var strip: CGImage?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color.black
                GeometryReader { geometry in
                    Group {
                        if let scrub, let tile = tile(scrub) {
                            Image(decorative: tile, scale: 1).resizable().scaledToFill()
                        } else {
                            DeliverPoster(asset: asset)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    .onContinuousHover { phase in
                        if case .active(let point) = phase, asset.kind == .video {
                            scrub = min(max(point.x / max(geometry.size.width, 1), 0), 0.999)
                            if strip == nil { strip = Self.strip(store.copies(asset.current.id)) }
                        } else { scrub = nil }
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .bottomTrailing) {
                if let duration = asset.current.probe?.duration, asset.kind == .video || asset.kind == .audio {
                    Text(verbatim: Format.duration(duration)).font(Design.Studio.hint.monospacedDigit()).foregroundStyle(.white).padding(10)
                }
            }
            .overlay(alignment: .bottomLeading) {
                // A render found in a watched folder and not shared yet (§13.4).
                if let found = DeliverWatch.shared.found.first(where: { $0.asset == asset.id }) {
                    Button { DeliverWatch.shared.accept(found.path) } label: { StudioChip(text: Text("v\(found.number) found · Share"), colour: Design.Brand.pink, tinted: true) }
                        .buttonStyle(.plain).padding(8)
                }
            }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 6) {
                    if hovering || chosen { Button(action: choose) { DeliverCheckbox(on: chosen) }.buttonStyle(.plain) }
                    copyState
                }
                .padding(8)
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 9, topTrailingRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: asset.name).font(Design.Studio.body.weight(.medium)).foregroundStyle(Design.Studio.text).lineLimit(1)
                HStack(spacing: 4) {
                    Text(verbatim: "v\(asset.current.number)")
                    Text(verbatim: "•")
                    Text(asset.created, format: .dateTime.day().month().year())
                    Spacer(minLength: 4)
                    DeliverMoreMenu(content: actions)
                }
                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
            }
            .padding(.leading, 10).padding(.trailing, 4).padding(.top, 8)
            statusBox.padding([.horizontal, .bottom], 8).padding(.top, 4)
        }
        .background(Design.Studio.raised, in: .rect(cornerRadius: 10, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }

    private var statusBox: some View {
        Menu {
            ForEach(Deliver.Status.allCases, id: \.self) { status in
                Button(DeliverStatusPill.title(status)) { store.setStatus(status, of: asset.id, by: DeliverSettings.author) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: asset.status == .none ? "circle.dashed" : "circle.fill").font(.system(size: 9))
                    .foregroundStyle(asset.status == .none ? Design.Studio.textQuiet : DeliverStatusPill.colour(asset.status))
                Text(asset.status == .none ? "Status" : DeliverStatusPill.title(asset.status))
                    .foregroundStyle(asset.status == .none ? Design.Studio.textQuiet : Design.Studio.text)
                Spacer(minLength: 4)
                if let rating = asset.fields?.rating, rating > 0 { Text(verbatim: String(repeating: "★", count: rating)).foregroundStyle(Design.Studio.warn) }
                let count = store.comments(asset.id, version: asset.current.id).count
                if count > 0 {
                    HStack(spacing: 3) { Image(systemName: "text.bubble"); Text(verbatim: "\(count)") }.foregroundStyle(Design.Studio.textQuiet)
                }
            }
            .font(Design.Studio.hint)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(Design.Studio.backdrop.opacity(0.6), in: .rect(cornerRadius: 6, style: .continuous))
            .contentShape(.rect)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
    }

    @ViewBuilder private var copyState: some View {
        switch asset.current.copy {
        case .making(let share):
            ZStack {
                Circle().stroke(Color.black.opacity(0.4), lineWidth: 3)
                Circle().trim(from: 0, to: max(share, 0.03)).stroke(Design.Brand.pink, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
            }
            .frame(width: 18, height: 18)
            .help("Making the review copy")
        case .pending where working != asset.current.id && (asset.kind == .video || asset.kind == .audio):
            PlumSpinner()
        case .failed(let why):
            HStack(spacing: 5) {
                Circle().fill(Design.Studio.bad).frame(width: 8, height: 8)
                Button("Retry") { DeliverCopies.shared.retry(asset: asset.id, version: asset.current.id) }
                    .buttonStyle(.plain).font(Design.Studio.hint).foregroundStyle(.white)
            }
            .padding(.horizontal, 6).padding(.vertical, 3).background(.black.opacity(0.6), in: .capsule)
            .help(Text(verbatim: why))
        default:
            EmptyView()
        }
    }

    /// Tile floor(x × 100) of the 10×10 strip.
    private func tile(_ x: Double) -> CGImage? {
        guard let strip else { return nil }
        let index = Int(x * 100), width = strip.width / 10, height = strip.height / 10
        return strip.cropping(to: CGRect(x: index % 10 * width, y: index / 10 * height, width: width, height: height))
    }

    static func strip(_ folder: URL) -> CGImage? {
        NSImage(contentsOf: folder.appendingPathComponent("strip.jpg"))?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

/// The asset's review status as a small pill (nothing for none).
struct DeliverStatusPill: View {
    let status: Deliver.Status

    var body: some View {
        if status != .none {
            StudioChip(text: Text(Self.title(status)), colour: Self.colour(status), tinted: true)
        }
    }

    static func title(_ status: Deliver.Status) -> LocalizedStringKey {
        switch status {
        case .none: "No Status"
        case .needsReview: "Needs Review"
        case .inProgress: "In Progress"
        case .needsChanges: "Needs Changes"
        case .approved: "Approved"
        }
    }

    static func colour(_ status: Deliver.Status) -> Color {
        switch status {
        case .approved: Design.Studio.good
        case .needsChanges: Design.Studio.bad
        case .inProgress: Design.Studio.warn
        default: Design.Studio.textQuiet
        }
    }
}

/// An asset's fields (§6.1): rating, keywords, assignee, due date and notes.
struct DeliverFieldsSheet: View {
    let asset: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var store = DeliverStore.shared
    @State private var keywords = ""
    @State private var assignee = ""
    @State private var due: Date?
    @State private var notes = ""

    var body: some View {
        let fields = store.find(asset)?.asset.fields ?? .init()
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: store.find(asset)?.asset.name ?? "").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
            VStack(alignment: .leading, spacing: 2) {
                StudioField(label: "Rating") {
                    HStack(spacing: 2) {
                        ForEach(1...5, id: \.self) { n in
                            Button { set("rating", (fields.rating ?? 0) == n ? 0 : n) } label: {
                                Image(systemName: n <= (fields.rating ?? 0) ? "star.fill" : "star").foregroundStyle(n <= (fields.rating ?? 0) ? Design.Studio.warn : Design.Studio.textQuiet)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                StudioField(label: "Keywords") { TextField("hero, final", text: $keywords).settingField(width: 240) }
                StudioField(label: "Assignee") { TextField("Editor", text: $assignee).settingField(width: 240) }
                StudioField(label: "Due") {
                    if let date = due {
                        DatePicker("", selection: Binding(get: { date }, set: { due = $0 }), displayedComponents: .date).labelsHidden().fixedSize()
                        Button("None") { due = nil }.settingButton()
                    } else {
                        Button("Set Date") { due = Date.now.addingTimeInterval(7 * 86400) }.settingButton()
                    }
                }
                StudioField(label: "Notes") { TextField("", text: $notes, axis: .vertical).lineLimit(2...5).settingField(width: 240) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(StudioFlatButtonStyle())
                Button("Save") {
                    set("keywords", keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                    set("assignee", assignee)
                    set("due", due.map { $0.formatted(.iso8601.year().month().day()) })
                    set("notes", notes)
                    dismiss()
                }.buttonStyle(StudioFlatButtonStyle(prominent: true))
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 420)
        .background(Design.Studio.panel)
        .onAppear {
            keywords = (fields.keywords ?? []).joined(separator: ", ")
            assignee = fields.assignee ?? ""
            due = fields.due.flatMap { try? Date($0, strategy: .iso8601.year().month().day()) }
            notes = fields.notes ?? ""
        }
    }

    private func set(_ field: String, _ value: Any?) { try? store.setField(field, value, of: asset, by: DeliverSettings.author) }
}
