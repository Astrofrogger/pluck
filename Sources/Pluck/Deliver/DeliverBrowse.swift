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

    /// Placing them: by reference on the chosen host where they are, else (with `upload`) the original uploaded to
    /// the folder chosen in that server's uploads root and referenced there (the server makes its copies), else copies
    /// made here (pushed to the host as for any version). Edit Anywhere files come over first.
    static func place(_ items: [DeliverBrowseItem], into project: UUID, asVersions: Bool, host: Deliver.Host?,
                      upload: DeliverUploadDestination.Upload? = nil, later: Bool = false, store: DeliverStore = .shared, publish: ReviewPublish = .shared,
                      queue: DeliverShareQueue = .shared) async {
        let target = upload.flatMap { publish.host($0.host) }
        if let upload { DeliverUploadDestination.remember(upload.folder, host: upload.host, project: project) }
        for (item, match) in plan(items, project: project, asVersions: asVersions, store: store) {
            var reference: (path: String, size: Int64)?
            var local: URL?
            switch item.location {
            case .nas(let id, let path):
                reference = (ReviewPublish.nasPath(host: id, path: path), item.size)
            case .local(let url):
                if let nas = target ?? host.flatMap({ $0.kind == .nas ? $0 : nil }), let media = ReviewPublish.reference(url.path, on: nas) {
                    reference = (ReviewPublish.nasPath(host: nas.id, path: media), item.size)
                } else if let target, let upload, !item.folder {
                    // The server away (or `later`: it was away when asked): "Waiting for NAS", sent once it answers.
                    let wait = DeliverShareQueue.Entry(file: url.path, size: item.size, project: project, asset: match?.id, upload: upload,
                                                       publishTo: host.flatMap { $0.id == target.id || ReviewPublish.isDataHost($0.id) ? nil : $0.id })
                    if later { queue.add(wait); continue }
                    do {
                        let sent = try await DeliverUploads.shared.upload(url, to: upload.folder + "/" + url.lastPathComponent, host: target)
                        reference = (ReviewPublish.nasPath(host: target.id, path: sent), item.size)
                    } catch where DeliverShareQueue.waitable(error) {
                        queue.add(wait)
                        continue
                    } catch { local = url }
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
    /// Move to…: files in the uploads folder (media paths) whose new folder is being chosen.
    @State private var moving: [String]?
    @State private var preview = false
    /// Each review server's roots (its top level) and its uploads root's id, for the sidebar.
    @State private var serverRoots: [UUID: [ReviewHostClient.Entry]] = [:]
    @State private var writable: [UUID: String] = [:]
    /// A server's menu item chosen (Change Folders…, Pair Again…, Remove…).
    @State private var managing: DeliverHostAction?
    /// The main servers' backups (not browse roots: a backup has no media of its own), the one shown, the one being removed.
    @State private var backups: [DeliverBackups.Backup] = []
    @State private var backupShown: DeliverBackups.Backup?
    @State private var backupRemoving: DeliverBackups.Backup?
    /// A sidebar place on another Browse page, opened once that page shows (each page is its own view).
    @MainActor static var pending: String?

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
        // As in Finder: the sidebar runs the panel's full height; the header sits right of it, above the toolbar.
        HStack(spacing: 0) {
            if case .office = place, office == nil {
                VStack(spacing: 0) {
                    header
                    StudioEmptyState(symbol: "macmini", title: "The host Mac’s shares", line: officeProblem.map { LocalizedStringKey($0) }, button: "Try Again") {
                        Task { await loadShares() }
                    }
                    .frame(maxHeight: .infinity)
                }
            } else {
                FinderSidebar(groups: places, selection: selected) { go($0.id) }
                Divider()
                VStack(spacing: 0) {
                    header
                    Divider()
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
        }
        .onAppear {
            nas?.share = { urls in sharing = items(urls) }
            nas?.move = { paths in moving = paths }
            if let nas { FinderThumbnails.shared.register(nas) }
            if let pending = Self.pending {
                Self.pending = nil
                go(pending)
            }
        }
        .task {
            await loadServers()
            backups = await DeliverBackups.load()
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
        .sheet(isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } })) {
            if let nas, let files = moving {
                DeliverUploadPicker(host: nas.host, project: nil, title: String(localized: "Move to…"), action: String(localized: "Move"), done: { folder in
                    moving = nil
                    guard let folder else { return }
                    Task {
                        for file in files { _ = try? await DeliverUploadDestination.move(file, to: folder, host: nas.host) }
                        pane.reload()
                    }
                }, back: { moving = nil })
                .padding(Design.Spacing.sheet).frame(minWidth: 900, idealWidth: 1060, maxWidth: .infinity, minHeight: 600, idealHeight: 720, maxHeight: .infinity).background(Design.Studio.panel)
            }
        }
        .background { Button("") { share() }.keyboardShortcut("s", modifiers: [.command, .shift]).hidden() }
        .deliverHostAction($managing) { id in if place == .nas(id) { nav.deliver = .browse(.local) } }
        .sheet(item: $backupShown) { DeliverBackupDetailsSheet(backup: $0) }
        .confirmationDialog(Text("Remove \(backupRemoving?.name ?? "")?"), isPresented: Binding(get: { backupRemoving != nil }, set: { if !$0 { backupRemoving = nil } })) {
            Button("Remove Backup", role: .destructive) {
                guard let removing = backupRemoving else { return }
                Task { await DeliverBackups.remove(removing); backups = await DeliverBackups.load() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(backupRemoving?.main.name ?? "") stops sending it copies and it can no longer connect. The app on it keeps running.")
        }
        // Paired again or changed: the listing tries at once.
        .onChange(of: managing == nil) { _, closed in if closed, nas != nil { pane.reload() } }
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
            Spacer()
            Button("Share for Review…") { share() }
                .buttonStyle(StudioFlatButtonStyle(prominent: true)).disabled(pane.selection.isEmpty || problem != nil)
                .help("⌘⇧S")
        }
        .padding(.horizontal, 12).frame(height: FinderPaneView.toolbarHeight)
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

    // MARK: The sidebar

    /// Each server's roots and uploads root (servers set up before names were kept read theirs from TrueNAS once).
    private func loadServers() async {
        for host in ReviewPublish.shared.hosts where host.kind == .nas && host.role != "backup" {
            if TrueNASSetup.isTrueNAS(host) { await TrueNASSetup.readNames(host) }
            if let entries = try? await ReviewHostClient.browse(host, path: "") { serverRoots[host.id] = entries.filter(\.folder) }
            if let root = await DeliverUploads.writableRoot(host) {
                writable[host.id] = root
                if nas?.host.id == host.id { nas?.uploads = root; pane.reload() }
            }
        }
    }

    private static var movies: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true) }

    private var places: [FinderSidebar.Places] {
        var groups = Self.serverGroups(publish: ReviewPublish.shared, roots: serverRoots, writable: writable, backups: backups,
                                       actions: { host in AnyView(DeliverHostActions(host: host) { managing = $0 }) },
                                       show: { backupShown = $0 }, remove: { backupRemoving = $0 })
        // Movies, then the folders the user added to the Library's Favourites (not the usual home folders).
        let home = FileManager.default.homeDirectoryForCurrentUser
        let usual = Set((["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"].map { home.appendingPathComponent($0).path } + [home.path]
                         + [Locations.downloadFolder?.path].compactMap { $0 }).map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let here = [Self.movies] + Locations.shared.favorites.filter { $0.hasDirectoryPath && !usual.contains($0.standardizedFileURL.path) }
        groups.append(.init(title: String(localized: "This Mac"), places: here.map {
            .init(id: "local:" + $0.standardizedFileURL.path, symbol: $0 == Self.movies ? "film" : "folder", title: FileManager.default.displayName(atPath: $0.path))
        }))
        if let mac = OfficeRenderClient.shared.office {
            let rows: [FinderSidebar.Place] = office == nil ? [.init(id: "office", symbol: "macmini", title: mac.name)]
                : shares.map { .init(id: "share:" + $0.id, symbol: "externaldrive", title: $0.name, dimmed: !$0.online) }
            groups.append(.init(title: mac.name, places: rows))
        }
        return groups
    }

    /// One group per review server: its name as the heading (a status dot, its menu on a right-click), its roots by the
    /// names the owner knows them by, the uploads folder, then its backups, quiet. Before its roots are known: the server itself.
    static func serverGroups(publish: ReviewPublish, roots: [UUID: [ReviewHostClient.Entry]], writable: [UUID: String], backups: [DeliverBackups.Backup],
                             actions: (Deliver.Host) -> AnyView, show: @escaping (DeliverBackups.Backup) -> Void,
                             remove: @escaping (DeliverBackups.Backup) -> Void) -> [FinderSidebar.Places] {
        let mains = publish.hosts.filter { $0.kind == .nas && $0.role != "backup" }
        // A backup paired here as a server of its own: a quiet row under the first main (its own group without one).
        let paired = publish.hosts.filter { $0.kind == .nas && $0.role == "backup" }.map { host in
            FinderSidebar.Place(id: "nas:" + host.id.uuidString, symbol: "externaldrive.badge.timemachine", title: host.name, detail: String(localized: "Backup"),
                                dimmed: true, help: DeliverPlaces.state(.nas(host.id), publish: publish), menu: actions(host))
        }
        if mains.isEmpty { return paired.map { FinderSidebar.Places(title: $0.title, places: [$0], key: $0.id) } }
        return mains.map { host in
            let id = host.id.uuidString, up = writable[host.id]
            let known = roots[host.id] ?? []
            var rows: [FinderSidebar.Place] = known.filter { $0.name != up }.map {
                .init(id: "nasroot:\(id)/\($0.path)", symbol: "externaldrive.connected.to.line.below", title: host.rootName($0.name))
            }
            if let up, known.contains(where: { $0.name == up }) {
                rows.append(.init(id: "nasroot:\(id)/\(up)", symbol: "tray.and.arrow.down", title: host.rootNames?[up] != nil ? host.rootName(up) : NASFinderSource.uploadsName))
            }
            if rows.isEmpty { rows = [.init(id: "nas:" + id, symbol: "server.rack", title: host.name, dimmed: publish.online[host.id] == false)] }
            rows += backupPlaces(backups.filter { $0.main.id == host.id }, show: show, remove: remove) + (host.id == mains[0].id ? paired : [])
            let state = DeliverPlaces.state(.nas(host.id), publish: publish)
            let dot: Color = switch publish.online[host.id] { case true?: Design.Studio.good; case false?: Design.Studio.warn; case nil: Design.Studio.textFaint }
            return FinderSidebar.Places(title: host.name, places: rows, dot: dot, help: state, menu: actions(host), key: "server:" + id)
        }
    }

    /// A main's backups under it: "Backup", its status in the symbol (offline dimmed) and, with its upload speed, the
    /// tooltip (the 172 pt sidebar leaves no room for the speed beside a name).
    static func backupPlaces(_ backups: [DeliverBackups.Backup], show: @escaping (DeliverBackups.Backup) -> Void, remove: @escaping (DeliverBackups.Backup) -> Void) -> [FinderSidebar.Place] {
        backups.map { backup in
            FinderSidebar.Place(id: "backup:" + backup.id, symbol: backup.status == .copying ? "arrow.triangle.2.circlepath" : "externaldrive.badge.timemachine",
                                title: backup.name, detail: String(localized: "Backup"), dimmed: backup.status == .offline,
                                help: ([DeliverBackups.text(backup.status)] + [backup.uplink.map { String(localized: "\($0) Mbit/s up") }].compactMap { $0 }).joined(separator: " · "),
                                menu: AnyView(Group {
                                    Button("Details…") { show(backup) }
                                    Divider()
                                    Button("Remove Backup…", role: .destructive) { remove(backup) }
                                }))
        }
    }

    /// The sidebar place whose root the browser shows.
    private var selected: String? {
        let base = pane.base.standardizedFileURL
        switch place {
        case .local: return "local:" + base.path
        case .nas(let id):
            guard let nas else { return nil }
            let path = nas.path(base)
            return path.isEmpty ? "nas:" + id.uuidString : "nasroot:" + id.uuidString + "/" + path
        case .office: return office.map { "share:" + $0.share.id } ?? "office"
        }
    }

    /// A sidebar place chosen: the browser starts there (another place's page first, if it's elsewhere).
    private func go(_ id: String) {
        let kind = id.prefix { $0 != ":" }, value = String(id.dropFirst(kind.count + 1))
        switch kind {
        case "nas":
            guard let host = UUID(uuidString: value) else { return }
            if place == .nas(host), let nas { pane.go(to: nas.root, base: nas.root) } else { nav.deliver = .browse(.nas(host)) }
        case "nasroot":
            guard let slash = value.firstIndex(of: "/"), let host = UUID(uuidString: String(value[..<slash])) else { return }
            if place == .nas(host), let nas {
                let url = nas.url(String(value[value.index(after: slash)...]))
                pane.go(to: url, base: url)
            } else { Self.pending = id; nav.deliver = .browse(.nas(host)) }
        case "local":
            let url = URL(fileURLWithPath: value, isDirectory: true)
            if place == .local { pane.go(to: url, base: url) } else { Self.pending = id; nav.deliver = .browse(.local) }
        case "backup":
            backupShown = backups.first { $0.id == value }
        case "share":
            if case .office = place, let share = shares.first(where: { $0.id == value }) { open(share) }
        default:
            if let mac = OfficeRenderClient.shared.office { nav.deliver = .browse(.office(mac.device.uuidString)) }
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
    /// The destination step: where the originals from this Mac go on the NAS.
    @State private var destination = false

    /// The NAS an original from this Mac would be uploaded to: the server chosen, else the one holding the review data.
    private var uploadHost: Deliver.Host? {
        if let chosen = ReviewPublish.shared.choices.first(where: { $0.id == host }) { return chosen.kind == .nas ? chosen : nil }
        return host == DeliverSync.shared.state.host ? DeliverSync.shared.dataHost : nil
    }

    var body: some View {
        Group { if destination, let target = uploadHost { picker(target) } else { form } }
            .onAppear {
                host = DeliverSync.shared.state.host
                let first = items.first { $0.folder } ?? items.first
                name = first.map { $0.folder ? $0.name : URL(fileURLWithPath: $0.name).deletingPathExtension().lastPathComponent } ?? ""
            }
    }

    private func picker(_ target: Deliver.Host) -> some View {
            DeliverUploadPicker(host: target, project: project, done: { folder in
                Task { await go(upload: folder.map { .init(host: target.id, folder: $0) }) }
            }, back: { destination = false }, later: { folder in
                Task { await go(upload: .init(host: target.id, folder: folder), later: true) }
            })
            .disabled(working)
            .padding(Design.Spacing.sheet)
            .frame(minWidth: 900, idealWidth: 1060, maxWidth: .infinity, minHeight: 600, idealHeight: 720, maxHeight: .infinity)
            .background(Design.Studio.panel)
    }

    private var form: some View {
        let plan = DeliverShareForReview.plan(items, project: project, asVersions: asVersions)
        return VStack(alignment: .leading, spacing: 12) {
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
                Button(DeliverUploadDestination.needed(items, host: uploadHost) ? "Next…" : "Add") {
                    if DeliverUploadDestination.needed(items, host: uploadHost) { destination = true } else { Task { await go() } }
                }.buttonStyle(StudioFlatButtonStyle(prominent: true)).disabled(working || items.isEmpty)
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 460)
        .background(Design.Studio.panel)
    }

    private func go(upload: DeliverUploadDestination.Upload? = nil, later: Bool = false) async {
        working = true
        defer { working = false }
        guard let target = project ?? (try? store.newProject(name))?.id else { return }
        let chosen = ReviewPublish.shared.choices.first { $0.id == host }
        await DeliverShareForReview.place(items, into: target, asVersions: asVersions && project != nil, host: chosen, upload: upload, later: later)
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
