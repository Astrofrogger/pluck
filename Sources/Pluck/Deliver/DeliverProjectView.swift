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
                VStack(alignment: .leading, spacing: 16) {
                    if !chosen.isEmpty { selectionBar }
                    DeliverWaitingRows(project: project)
                    if !folders.isEmpty && search.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
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
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                            ForEach(assets) { asset in
                                DeliverAssetCard(asset: asset, working: copies.working)
                                    .overlay { if chosen.contains(asset.id) { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Design.Brand.pink, lineWidth: 2) } }
                                    .onTapGesture { open(asset) }
                                    .draggable(asset.id.uuidString)
                                    .dropDestination(for: URL.self) { urls, _ in stack(urls, on: asset) }
                                    .contextMenu { menu(asset) }
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            do { try store.add(urls.filter(\.isFileURL), to: project, folder: folder) } catch { problem = String(localized: "This project is full.") }
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

    private var header: some View {
        HStack(spacing: 10) {
            // Project › Folder › …
            HStack(spacing: 6) {
                Button { nav.deliver = .project(project, folder: nil) } label: {
                    Text(verbatim: store.project(project)?.name ?? "").font(Design.Studio.sectionTitle)
                }
                .buttonStyle(.plain).foregroundStyle(folder == nil ? Design.Studio.text : Design.Studio.textQuiet)
                ForEach(store.folderPath(folder, in: project)) { step in
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Design.Studio.textFaint)
                    Button { nav.deliver = .project(project, folder: step.id) } label: { Text(verbatim: step.name).font(Design.Studio.sectionTitle) }
                        .buttonStyle(.plain).foregroundStyle(step.id == folder ? Design.Studio.text : Design.Studio.textQuiet)
                        .dropDestination(for: String.self) { ids, _ in move(ids, to: step.id) }
                }
            }
            .lineLimit(1)
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Design.Studio.textQuiet)
                TextField("Search", text: $search).textFieldStyle(.plain).font(Design.Studio.body).frame(width: 140)
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(Design.Studio.backdrop, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
            StudioSegmented(options: [(false, "Grid"), (true, "List")], selection: $list, symbols: ["square.grid.2x2", "list.bullet"])
            Menu {
                Picker(selection: $sort) {
                    Text("Date Added").tag("date")
                    Text("Name").tag("name")
                } label: { EmptyView() }.pickerStyle(.inline)
            } label: { StudioMenuLabel(title: sort == "name" ? String(localized: "Name") : String(localized: "Date Added")) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Button { naming = true; name = "" } label: { Image(systemName: "folder.badge.plus") }.buttonStyle(StudioFlatButtonStyle()).help("New Folder")
            Button("Publish…") { publishing = .project(project) }.buttonStyle(StudioFlatButtonStyle())
            Button("Share") { sharing = folder.map { .folder($0, project: project) } ?? .project(project) }.buttonStyle(StudioFlatButtonStyle(prominent: true))
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    private func folderTile(_ item: Deliver.Folder) -> some View {
        let inside = store.subfolders(item.id, in: project)
        return Button { nav.deliver = .project(project, folder: item.id) } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill").font(.system(size: 16)).foregroundStyle(Design.Studio.textQuiet)
                Text(verbatim: item.name).font(Design.Studio.body).foregroundStyle(Design.Studio.text).lineLimit(1)
                Spacer()
                Text(verbatim: "\(content.assets.filter { $0.folder.map(inside.contains) == true }.count)").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .studioBox()
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
            DeliverPoster(asset: asset).frame(width: 64, height: 36).clipShape(.rect(cornerRadius: 4))
            Text(verbatim: asset.name).font(Design.Studio.body).foregroundStyle(Design.Studio.text).lineLimit(1)
            Spacer()
            DeliverStatusPill(status: asset.status)
            Text(verbatim: "v\(asset.current.number)").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).frame(width: 30)
            Label { Text(verbatim: "\(store.comments(asset.id).count)") } icon: { Image(systemName: "text.bubble") }
                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).frame(width: 44)
            Text(asset.created, format: .dateTime.day().month()).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).frame(width: 60)
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .studioBox()
        .contentShape(.rect)
        .overlay { if chosen.contains(asset.id) { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Design.Brand.pink, lineWidth: 2) } }
        .onTapGesture { open(asset) }
        .draggable(asset.id.uuidString)
        .dropDestination(for: URL.self) { urls, _ in stack(urls, on: asset) }
        .contextMenu { menu(asset) }
    }

    /// A click opens the asset; ⌘-click adds it to (or takes it from) the selection.
    private func open(_ asset: Deliver.Asset) {
        if NSEvent.modifierFlags.contains(.command) || !chosen.isEmpty {
            if chosen.contains(asset.id) { chosen.remove(asset.id) } else { chosen.insert(asset.id) }
        } else {
            nav.deliver = .asset(asset.id, version: nil, comment: nil)
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Text("\(chosen.count) selected").font(Design.Studio.body).foregroundStyle(Design.Studio.text)
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
        .padding(.horizontal, 12).frame(height: 44).studioBox()
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

/// An asset's card: poster (hover scrubs the strip), duration, the version, status and comment count;
/// a ring while its copy is made, a red dot and Retry when that failed.
struct DeliverAssetCard: View {
    let asset: Deliver.Asset
    var working: UUID?
    @State private var store = DeliverStore.shared
    @State private var scrub: Double?
    @State private var strip: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .bottomTrailing) {
                    if let scrub, let tile = tile(scrub) {
                        Image(decorative: tile, scale: 1).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    } else {
                        DeliverPoster(asset: asset).frame(width: geometry.size.width, height: geometry.size.height)
                    }
                    if let duration = asset.current.probe?.duration, asset.kind == .video || asset.kind == .audio {
                        Text(verbatim: Format.duration(duration)).font(Design.Studio.hint.monospacedDigit()).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2).background(.black.opacity(0.6), in: .rect(cornerRadius: 4)).padding(6)
                    }
                }
                .overlay(alignment: .topLeading) { copyState.padding(8) }
                .onContinuousHover { phase in
                    if case .active(let point) = phase, asset.kind == .video {
                        scrub = min(max(point.x / max(geometry.size.width, 1), 0), 0.999)
                        if strip == nil { strip = Self.strip(store.copies(asset.current.id)) }
                    } else { scrub = nil }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 8, style: .continuous))
            HStack(spacing: 6) {
                Text(verbatim: asset.name).font(Design.Studio.body).foregroundStyle(Design.Studio.text).lineLimit(1)
                Spacer(minLength: 4)
                if asset.versions.count > 1 { StudioChip(text: Text(verbatim: "v\(asset.current.number)")) }
            }
            HStack(spacing: 8) {
                DeliverStatusPill(status: asset.status)
                if let rating = asset.fields?.rating { Text(verbatim: String(repeating: "★", count: rating)).font(Design.Studio.hint).foregroundStyle(Design.Studio.warn) }
                // A render found in a watched folder and not shared yet (§13.4).
                if let found = DeliverWatch.shared.found.first(where: { $0.asset == asset.id }) {
                    Button { DeliverWatch.shared.accept(found.path) } label: { StudioChip(text: Text("v\(found.number) found · Share"), colour: Design.Brand.pink, tinted: true) }
                        .buttonStyle(.plain)
                }
                Spacer()
                let count = store.comments(asset.id, version: asset.current.id).count
                if count > 0 {
                    Label { Text(verbatim: "\(count)") } icon: { Image(systemName: "text.bubble") }.font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                }
            }
            .frame(height: 20)
        }
        .padding(10)
        .studioBox()
        .contentShape(.rect)
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
