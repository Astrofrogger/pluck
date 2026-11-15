import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Deliver › Browse (§13.16): the Library Finder on this Mac, on each NAS host (its media roots and uploads root,
/// on the LAN or over iroh, the same to the user), and on the Edit Anywhere host Mac (its shares). Files or folders
/// chosen there are shared for review: by reference where they already are, else uploaded or copied.
@MainActor
enum DeliverPlaces {
    struct Place: Identifiable, Hashable {
        var id: Deliver.PlaceID
        var name: String
        var symbol: String
    }

    static func all(publish: ReviewPublish = .shared) -> [Place] {
        var places = [Place(id: .local, name: String(localized: "This Mac"), symbol: "desktopcomputer")]
        places += publish.hosts.filter { $0.kind == .nas }.map { Place(id: .nas($0.id), name: $0.name, symbol: "externaldrive.connected.to.line.below") }
        if let office = OfficeRenderClient.shared.office {
            places.append(Place(id: .office(office.device.uuidString), name: office.name, symbol: "macmini"))
        }
        return places
    }

    /// "LAN" | "Internet (direct)" | "Relay (slow)" | "Offline: <reason>" | "Needs pairing" (nil: this Mac).
    static func state(_ place: Deliver.PlaceID, problem: String? = nil, publish: ReviewPublish = .shared) -> String? {
        if let problem { return String(localized: "Offline: \(problem)") }
        switch place {
        case .local: return nil
        case .nas(let id):
            guard let host = publish.host(id) else { return String(localized: "Needs pairing") }
            if ReviewHostClient.key(host) == nil, ReviewHostClient.deviceKey(host) == nil { return String(localized: "Needs pairing") }
            if publish.online[id] == false { return String(localized: "Offline: not answering") }
            switch ReviewHostTunnel.via(of: id) {
            case .lan: return String(localized: "LAN")
            case .internet: return String(localized: "Internet (direct)")
            case .relay: return String(localized: "Relay (slow)")
            case nil: return nil
            }
        case .office:
            guard let office = OfficeRenderClient.shared.office else { return String(localized: "Needs pairing") }
            // iroh goes through the tunnel first; a private-network office the same; else the office network's addresses.
            if let node = office.iroh {
                guard let link = OfficeRenderClient.shared.irohTunnel.links[node] else { return nil }
                return link.direct ? String(localized: "Internet (direct)") : String(localized: "Relay (slow)")
            }
            return office.network == nil ? String(localized: "LAN") : String(localized: "Internet (direct)")
        }
    }
}

/// What "Share for review" places: a file or folder here, on a NAS (a media path), or on the host Mac (a share path).
struct DeliverBrowseItem: Hashable {
    enum Where: Hashable { case local(URL), nas(UUID, String), office(String, String) }
    var name: String
    var location: Where
    var folder: Bool
    var size: Int64

    var stem: String { (name as NSString).deletingPathExtension }
    var kind: Deliver.Kind { DeliverStore.kind(URL(fileURLWithPath: name)) }
}

/// Share for review's plan, worked out before anything changes: each file as a new asset or a version of one.
@MainActor
enum DeliverShareForReview {
    /// The asset a file belongs to by the §13.4 key (its stem's, whatever the number).
    static func match(_ stem: String, in assets: [Deliver.Asset]) -> Deliver.Asset? {
        let key = DeliverWatch.parse(stem)?.key ?? DeliverWatch.key(stem)
        return assets.first { asset in
            let current = URL(fileURLWithPath: asset.current.path).deletingPathExtension().lastPathComponent
            return (DeliverWatch.parse(current)?.key ?? DeliverWatch.key(current)) == key
                || (DeliverWatch.parse(asset.name)?.key ?? DeliverWatch.key(asset.name)) == key
        }
    }

    static func plan(_ items: [DeliverBrowseItem], project: UUID?, asVersions: Bool, store: DeliverStore = .shared) -> [(item: DeliverBrowseItem, asset: Deliver.Asset?)] {
        let assets = project.map { store.content($0).assets } ?? []
        return items.map { item in (item, asVersions && !item.folder ? match(item.stem, in: assets) : nil) }
    }

    /// Placing them: by reference on the chosen host where they are, else uploaded to its uploads root, else
    /// copies made here (pushed to the host as for any version). Edit Anywhere files come over first.
    static func place(_ items: [DeliverBrowseItem], into project: UUID, asVersions: Bool, host: Deliver.Host?, store: DeliverStore = .shared) async {
        let uploads = host.flatMap { $0.kind == .nas ? $0 : nil }
        let root = uploads == nil ? nil : await DeliverUploads.writableRoot(uploads!)
        for (item, match) in plan(items, project: project, asVersions: asVersions, store: store) {
            var reference: (path: String, size: Int64)?
            var local: URL?
            switch item.location {
            case .nas(let id, let path):
                reference = (ReviewPublish.nasPath(host: id, path: path), item.size)
            case .local(let url):
                if let uploads, let media = ReviewPublish.reference(url.path, on: uploads) {
                    reference = (ReviewPublish.nasPath(host: uploads.id, path: media), item.size)
                } else if let uploads, let root, !item.folder {
                    let folder = root + "/" + DeliverServer.safeName(store.project(project)?.name ?? "Review")
                    _ = try? await ReviewHostClient.ask(uploads, ["op": "mkdir", "path": folder])
                    if let sent = try? await DeliverUploads.shared.upload(url, to: folder + "/" + url.lastPathComponent, host: uploads) {
                        reference = (ReviewPublish.nasPath(host: uploads.id, path: sent), item.size)
                    } else { local = url }
                } else { local = url }
            case .office(let share, let path):
                local = await pull(share: share, path: path, store: store)
            }
            if let match {
                if let reference { _ = try? store.addVersion(reference: reference.path, size: reference.size, to: match.id) }
                else if let local { _ = try? store.addVersion(local, to: match.id) }
            } else if let reference {
                if item.folder, case .nas(let id, let path) = item.location, let host = ReviewPublish.shared.host(id) {
                    await addNASFolder(host, path: path, name: item.name, into: project, parent: nil, depth: 0, store: store)
                } else {
                    store.addReferences([(name: item.stem, kind: item.kind, path: reference.path, size: reference.size)], to: project)
                }
            } else if let local {
                _ = try? store.add([local], to: project, folder: nil)
            }
        }
        // Another host than the data host: published there as before (§12).
        if let host, host.id != DeliverSync.shared.state.host { await ReviewPublish.shared.publish(.project(project), to: host) }
    }

    /// A NAS folder: a folder of its files by reference (≤ 8 deep, ≤ 2,000 files).
    private static func addNASFolder(_ host: Deliver.Host, path: String, name: String, into project: UUID, parent: UUID?, depth: Int, store: DeliverStore) async {
        guard depth < 8, let made = store.newFolder(name, in: project, parent: parent),
              let entries = try? await ReviewHostClient.browse(host, path: path) else { return }
        let files = entries.filter { !$0.folder && DeliverStore.kind(URL(fileURLWithPath: $0.name)) != .other }.prefix(2000)
        let added = store.addReferences(files.map { (name: ($0.name as NSString).deletingPathExtension, kind: DeliverStore.kind(URL(fileURLWithPath: $0.name)),
                                                     path: ReviewPublish.nasPath(host: host.id, path: $0.path), size: $0.size ?? 0) }, to: project)
        for asset in added { store.move(asset: asset.id, to: made.id) }
        for folder in entries where folder.folder { await addNASFolder(host, path: folder.path, name: folder.name, into: project, parent: made.id, depth: depth + 1, store: store) }
    }

    /// An Edit Anywhere file through the pull manager into Review/Imported/ (waits until it's here, up to 6 hours).
    /// shortcut: polled every 5 s; a pull-done callback if the pull manager gets one.
    private static func pull(share id: String, path: String, store: DeliverStore) async -> URL? {
        guard let share = (try? await OfficeRenderClient.shared.shares())?.first(where: { $0.id == id }) else { return nil }
        let root = store.root.appendingPathComponent("Imported", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard (try? await RemotePullManager.shared.pullOriginal(share: share, path: path, into: root)) != nil else { return nil }
        let file = root.appendingPathComponent(String(localized: "Originals"), isDirectory: true).appendingPathComponent(path)
        for _ in 0..<4320 {
            if !RemotePullManager.shared.jobs.contains(where: { $0.share == id && $0.paths.contains(path) }), FileManager.default.fileExists(atPath: file.path) { return file }
            try? await Task.sleep(for: .seconds(5))
        }
        return nil
    }
}

// MARK: - The pane

struct DeliverBrowseView: View {
    @Bindable var nav: StudioNavigator
    let place: Deliver.PlaceID
    @State private var pane: FinderPane
    @State private var nas: NASFinderSource?
    @State private var shares: [OfficeRenderClient.RemoteShare] = []
    @State private var office: RemoteFinderSource?
    @State private var officeProblem: String?
    @State private var sharing: [DeliverBrowseItem]?
    @State private var preview = false

    init(nav: StudioNavigator, place: Deliver.PlaceID) {
        self.nav = nav
        self.place = place
        switch place {
        case .nas(let id):
            let host = ReviewPublish.shared.host(id) ?? Deliver.Host(name: "", kind: .nas, address: nil)
            let source = NASFinderSource(host: host)
            _nas = State(initialValue: source)
            _pane = State(initialValue: FinderPane(url: source.root, base: source.root, source: source))
        default:
            _pane = State(initialValue: FinderPane(url: Self.localStart()))
        }
    }

    /// Browse › This Mac keeps its own last folder (never the Library's), and never opens in a temp or cache folder.
    static let lastFolderKey = "deliverBrowseFolder"
    static func localStart() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let path = UserDefaults.standard.string(forKey: lastFolderKey), usable(URL(fileURLWithPath: path, isDirectory: true)) else { return home }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    static func usable(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.resolvingSymlinksInPath().path ?? "/nonexistent"
        var folder: ObjCBool = false
        return ![temp, caches, "/private/var/folders", "/private/tmp"].contains { path.hasPrefix($0) }
            && FileManager.default.fileExists(atPath: path, isDirectory: &folder) && folder.boolValue
    }

    private var name: String { DeliverPlaces.all().first { $0.id == place }?.name ?? "" }
    private var problem: String? { nas?.problem ?? officeProblem }

    var body: some View {
        VStack(spacing: 0) {
            header
            if case .office = place, office == nil {
                StudioEmptyState(symbol: "macmini", title: "The host Mac’s shares", line: officeProblem.map { LocalizedStringKey($0) }, button: "Try Again") {
                    Task { await loadShares() }
                }
                .frame(maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    FinderPaneView(pane: pane).coordinateSpace(name: "finder")
                        .opacity(problem == nil ? 1 : 0.5)
                        .allowsHitTesting(problem == nil)
                    if let item = chosen, nas != nil {
                        Divider()
                        DeliverNASPreview(host: nas!.host, path: nas!.path(item.url), name: item.name).frame(width: 260).id(item.url)
                    }
                }
            }
        }
        .onAppear {
            nas?.share = { urls in sharing = items(urls) }
            if let nas { FinderThumbnails.shared.register(nas) }
        }
        .onDisappear { if let nas { FinderThumbnails.shared.unregister(nas) } }
        .onChange(of: pane.url) { _, url in
            if case .local = place, pane.list == nil, Self.usable(url) { UserDefaults.standard.set(url.path, forKey: Self.lastFolderKey) }
        }
        .task(id: place) {
            if case .office = place { await loadShares() }
            // Offline places try again every 30 s while shown.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if problem != nil { if case .office = place { await loadShares() } else { pane.reload() } }
            }
        }
        .sheet(item: Binding(get: { sharing.map(DeliverShareItems.init) }, set: { sharing = $0?.items })) { list in
            DeliverShareForReviewSheet(items: list.items, nav: nav)
        }
        .background { Button("") { share() }.keyboardShortcut("s", modifiers: [.command, .shift]).hidden() }
    }

    private var chosen: FinderItem? {
        guard pane.selection.count == 1, let url = pane.selection.first else { return nil }
        return pane.shown.first { $0.url == url && !$0.isFolder }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(verbatim: name).font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text).lineLimit(1)
            if let state = DeliverPlaces.state(place, problem: problem) {
                StudioChip(text: Text(verbatim: state), colour: problem == nil ? Design.Studio.textQuiet : Design.Studio.warn, tinted: problem != nil)
            }
            if case .local = place, Locations.shared.favorites.filter(\.hasDirectoryPath).count > 1 {
                Menu {
                    ForEach(Locations.shared.favorites.filter(\.hasDirectoryPath), id: \.self) { url in
                        Button(FileManager.default.displayName(atPath: url.path)) { pane.go(to: url, base: url) }
                    }
                } label: { StudioMenuLabel(title: pane.title) }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            if case .office = place, shares.count > 1, let office {
                Menu {
                    ForEach(shares) { share in Button(share.name) { open(share) } }
                } label: { StudioMenuLabel(title: office.share.name) }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            Spacer()
            Button("Share for Review…") { share() }
                .buttonStyle(StudioFlatButtonStyle(prominent: true)).disabled(pane.selection.isEmpty || problem != nil)
                .help("⌘⇧S")
        }
        .padding(.horizontal, 16).frame(height: 48)
    }

    private func share() {
        guard !pane.selection.isEmpty, problem == nil else { return }
        sharing = items(Array(pane.selection))
    }

    private func items(_ urls: [URL]) -> [DeliverBrowseItem] {
        urls.sorted { $0.path < $1.path }.map { url in
            let info = pane.shown.first { $0.url == url }?.info
            let folder = info?.isFolder ?? url.hasDirectoryPath
            let location: DeliverBrowseItem.Where
            switch place {
            case .local: location = .local(url)
            case .nas(let id): location = .nas(id, nas?.path(url) ?? "")
            case .office: location = .office(office?.share.id ?? "", office?.relative(url) ?? "")
            }
            return DeliverBrowseItem(name: url.lastPathComponent, location: location, folder: folder, size: info?.size ?? 0)
        }
    }

    private func loadShares() async {
        do {
            shares = try await OfficeRenderClient.shared.shares()
            officeProblem = nil
            if office == nil, let first = shares.first(where: \.online) ?? shares.first { open(first) }
        } catch {
            officeProblem = error.localizedDescription
        }
    }

    private func open(_ share: OfficeRenderClient.RemoteShare) {
        let source = RemoteFinderSource(share: share)
        office = source
        pane = FinderPane(url: source.root, base: source.root, source: source)
    }
}

/// A list of items as a sheet's item.
struct DeliverShareItems: Identifiable {
    let items: [DeliverBrowseItem]
    var id: Int { items.hashValue }
}

/// A NAS file's picture and media info (`probe`); playback needs a review copy, made only when asked.
private struct DeliverNASPreview: View {
    let host: Deliver.Host
    let path: String
    let name: String
    @State private var image: NSImage?
    @State private var info: [String: Any] = [:]
    @State private var made = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Design.Studio.raised
                if let image { Image(nsImage: image).resizable().scaledToFit() } else { Image(systemName: "film").foregroundStyle(Design.Studio.textFaint) }
            }
            .aspectRatio(16 / 9, contentMode: .fit).clipShape(.rect(cornerRadius: 6))
            Text(verbatim: name).font(Design.Studio.body).foregroundStyle(Design.Studio.text).lineLimit(2)
            ForEach(lines, id: \.self) { Text(verbatim: $0).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet) }
            if DeliverStore.kind(URL(fileURLWithPath: name)) == .video {
                Text("Preview needs a review copy").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                Button(made ? "Making One…" : "Make One") { make() }.buttonStyle(StudioFlatButtonStyle()).disabled(made)
            }
            Spacer()
        }
        .padding(12)
        .task {
            if let data = try? await ReviewHostClient.thumb(host, path: path) { image = NSImage(data: data) }
            info = (try? await ReviewHostClient.ask(host, ["op": "probe", "path": path])) ?? [:]
        }
    }

    private var lines: [String] {
        var lines: [String] = []
        if let width = info["width"] as? Int, let height = info["height"] as? Int { lines.append("\(width) × \(height)") }
        if let duration = info["duration"] as? Double { lines.append(DeliverTimecode.duration(duration)) }
        if let codec = info["codec"] as? String { lines.append(codec) }
        return lines
    }

    /// Published by reference into the hidden "Browse previews" project; the NAS makes the copy.
    private func make() {
        let store = DeliverStore.shared
        let project = store.projects.first { $0.hidden == true }?.id ?? (try? store.newProject(String(localized: "Browse previews"))).map { made in
            store.setHidden(made.id)
            return made.id
        }
        guard let project else { return }
        store.addReferences([(name: (name as NSString).deletingPathExtension, kind: .video, path: ReviewPublish.nasPath(host: host.id, path: path), size: 0)], to: project)
        made = true
        if DeliverSync.shared.state.host != host.id { Task { await ReviewPublish.shared.publish(.project(project), to: host) } }
    }
}

/// "Share for review…": project (new or existing), as new assets or versions (with the matches listed), and the host.
struct DeliverShareForReviewSheet: View {
    let items: [DeliverBrowseItem]
    @Bindable var nav: StudioNavigator
    @Environment(\.dismiss) private var dismiss
    @State private var store = DeliverStore.shared
    @State private var project: UUID?
    @State private var name = ""
    @State private var asVersions = false
    @State private var host: UUID?
    @State private var thenShare = true
    @State private var working = false

    var body: some View {
        let plan = DeliverShareForReview.plan(items, project: project, asVersions: asVersions)
        VStack(alignment: .leading, spacing: 12) {
            Text("Share for Review").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
            StudioField(label: "Project") {
                Picker(selection: $project) {
                    Text("New Project").tag(UUID?.none)
                    ForEach(store.projects.filter { $0.hidden != true }) { Text(verbatim: $0.name).tag(UUID?.some($0.id)) }
                } label: { EmptyView() }.fixedSize()
                if project == nil { TextField("Name", text: $name).settingField(width: 180) }
            }
            StudioField(label: "As") {
                StudioSegmented(options: [(false, LocalizedStringKey("New assets")), (true, LocalizedStringKey("New versions"))], selection: $asVersions).fixedSize()
            }
            if asVersions, project != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(plan, id: \.item) { row in
                            HStack(spacing: 6) {
                                Text(verbatim: row.item.name).lineLimit(1)
                                Image(systemName: "arrow.right").foregroundStyle(Design.Studio.textFaint)
                                if let asset = row.asset { Text(verbatim: "\(asset.name) v\(asset.versions.count + 1)") } else { Text("New asset").foregroundStyle(Design.Studio.textQuiet) }
                            }
                            .font(Design.Studio.hint)
                        }
                    }
                }
                .frame(maxHeight: 140)
            }
            StudioField(label: "Host") {
                Picker(selection: $host) {
                    Text("This Mac").tag(UUID?.none)
                    ForEach(ReviewPublish.shared.choices) { Text(verbatim: $0.name).tag(UUID?.some($0.id)) }
                } label: { EmptyView() }.fixedSize()
            }
            StudioSwitchRow(title: "Then share it", isOn: $thenShare)
            HStack {
                if working { PlumSpinner() }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(StudioFlatButtonStyle())
                Button("Add") { Task { await go() } }.buttonStyle(StudioFlatButtonStyle(prominent: true)).disabled(working || items.isEmpty)
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 460)
        .background(Design.Studio.panel)
        .onAppear {
            host = DeliverSync.shared.state.host
            let first = items.first { $0.folder } ?? items.first
            name = first.map { $0.folder ? $0.name : URL(fileURLWithPath: $0.name).deletingPathExtension().lastPathComponent } ?? ""
        }
    }

    private func go() async {
        working = true
        defer { working = false }
        guard let target = project ?? (try? store.newProject(name))?.id else { return }
        let chosen = ReviewPublish.shared.choices.first { $0.id == host }
        await DeliverShareForReview.place(items, into: target, asVersions: asVersions && project != nil, host: chosen)
        nav.deliver = .project(target, folder: nil)
        if thenShare { DeliverShareRequest.shared.scope = .project(target) }
        dismiss()
    }
}

/// The share sheet asked for from elsewhere (Share for review's last step); the Deliver page shows it.
@MainActor
@Observable
final class DeliverShareRequest {
    static let shared = DeliverShareRequest()
    var scope: Deliver.Scope?
}
