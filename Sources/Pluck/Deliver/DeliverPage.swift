import SwiftUI

/// The Deliver page (§8): review projects in a sidebar, shared links, the inbox and the delivery tools,
/// and what's chosen in the main panel.
struct DeliverPage: View {
    @Bindable var nav: StudioNavigator
    @State private var store = DeliverStore.shared

    var body: some View {
        HStack(spacing: Design.Studio.panelGap) {
            DeliverSidebar(nav: nav)
                .frame(width: 220)
                .frame(maxHeight: .infinity)
                .studioPanel()
            main
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .studioPanel()
        }
        .navigationTitle("")
    }

    /// Screenshots: the share sheet drawn in the page (off-screen pictures show the window only).
    @MainActor static var sheetInPage: Deliver.Scope?

    /// Screenshots: a project with comments and a link, made once in the test home, and the view asked for.
    @MainActor static func snapshot(files: [URL], view: String) {
        let store = DeliverStore.shared, nav = StudioNavigator.shared
        if store.projects.isEmpty, let project = try? store.newProject("Spring campaign") {
            _ = try? store.newProject("Wedding film")
            _ = try? store.newProject("Product launch")
            let assets = (try? store.add(files, to: project.id, folder: nil)) ?? []
            store.newFolder("Socials", in: project.id, parent: nil)
            if let first = assets.first {
                store.setStatus(.needsReview, of: first.id, by: "")
                _ = try? store.newLink(scope: .project(project.id), title: "Spring campaign – cuts", password: "test")
            }
        }
        DeliverCopies.shared.resume()
        nav.show(.deliver)
        guard let project = store.projects.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let asset = store.content(project.id).assets.first
            // Comments once the copy (and its probe) is there.
            if let asset, store.comments(asset.id).isEmpty, asset.current.probe != nil {
                let version = asset.current.id
                _ = try? store.addComment(asset: asset.id, version: version, frame: 30, text: "Logo comes in too early, can it wait for the beat?", author: "Client",
                                          token: "t", drawing: .init(strokes: [.init(tool: .arrow, colour: "#E0605E", width: 0.004, points: [[0.30, 0.30], [0.45, 0.42]])]))
                if let first = store.comments(asset.id).first { _ = try? store.reply(to: first.id, text: "Moved it two bars later.", author: DeliverSettings.author) }
                _ = try? store.addComment(asset: asset.id, version: version, frame: 60, endFrame: 80, text: "Colour feels warmer than v1 here. #grade", author: "Producer", token: "u")
                if let made = try? store.addComment(asset: asset.id, version: version, frame: nil, text: "Love the pace overall #music", author: "Client", token: "t") {
                    _ = try? store.react(made.id, emoji: "👍", by: "t", on: true)
                    _ = try? store.react(made.id, emoji: "🔥", by: "owner", on: true)
                }
                _ = try? store.addComment(asset: asset.id, version: version, frame: 45, text: "Check the licence before we send", author: DeliverSettings.author, anchor: [0.6, 0.4], isInternal: true)
                if let link = store.links.first {
                    store.updateLink(link.id) { $0.notifyOpened = true; $0.watermark = .init() }
                    for (n, kind) in ["opened", "viewed", "played", "commented", "downloaded", "approved"].enumerated() {
                        store.log(.init(link: link.id, at: Date.now.addingTimeInterval(Double(-600 + n * 60)), name: n % 2 == 0 ? "Client" : "Producer",
                                        email: n % 2 == 0 ? "client@example.com" : nil, kind: kind, asset: asset.id, version: version,
                                        detail: kind == "played" ? .init(from: 0, to: 60) : kind == "downloaded" ? .init(what: "proxy") : nil))
                    }
                    _ = store.invite(["Client", "Producer"], like: link.id)
                }
            }
            switch view {
            case "project": nav.deliver = .project(project.id, folder: nil)
            case "asset": if let asset { nav.deliver = .asset(asset.id, version: nil, comment: store.comments(asset.id).first?.id) }
            case "share": sheetInPage = .project(project.id); nav.deliver = .project(project.id, folder: nil)
            case "links": nav.deliver = .links(project.id, link: nil)
            case "activity": nav.deliver = .links(project.id, link: store.links.first { $0.project == project.id }?.id)
            case "sharemore": DeliverShareSheet.moreOpen = true; sheetInPage = .project(project.id); nav.deliver = .project(project.id, folder: nil)
            case "browse": nav.deliver = .browse(.local)
            case "truenas": panelInPage = AnyView(ReviewTrueNASSetupSheet()); nav.deliver = .inbox
            case "backup", "hostsheet":
                let sample = Deliver.Host(name: "Office NAS", kind: .nas, address: "192.0.2.10:8790", version: "0.3.0", protocol: 3)
                panelInPage = view == "backup" ? AnyView(DeliverBackupSheet(main: sample)) : AnyView(DeliverHostSheet(host: sample))
                nav.deliver = .inbox
            case "pairing":
                let invitation = PrivateNetwork.Invitation(way: .reviewHost(node: String(repeating: "a1", count: 32), relay: nil, expires: .now.addingTimeInterval(900),
                                                                       pin: Array(repeating: "AB", count: 32).joined(separator: ":"), lan: nil, role: "mac"), name: "Office NAS", code: "ABCD-EFGH-JKMN")
                panelInPage = AnyView(DeliverPairingSheet(preview: invitation))
                nav.deliver = .inbox
            case "message":
                if let link = store.links.first(where: { store.url($0) != nil }) ?? (try? store.newLink(scope: .project(project.id), title: "Spring campaign – cuts", password: "test")),
                   let url = store.url(link) { panelInPage = AnyView(DeliverLinkShare(link: link, url: url).padding(24)) }
                nav.deliver = .inbox
            case "markers":
                if let asset, asset.current.probe != nil { panelInPage = AnyView(DeliverResolveMarkersSheet(asset: asset, version: asset.current)) }
                nav.deliver = .inbox
            case "links-closed":
                if let link = store.links.first { store.updateLink(link.id) { $0.deadline = Date.now.addingTimeInterval(-3600) } }
                nav.deliver = .links(project.id, link: nil)
            default: nav.deliver = .projects
            }
        }
    }

    /// Screenshots: one of §13's sheets drawn in the page.
    @MainActor static var panelInPage: AnyView?

    @ViewBuilder private var main: some View {
        if let panel = Self.panelInPage {
            ScrollView { panel.frame(maxWidth: .infinity) }.clipShape(.rect(cornerRadius: Design.Studio.panelRadius))
        } else if let scope = Self.sheetInPage {
            DeliverShareSheet(scope: scope).clipShape(.rect(cornerRadius: Design.Studio.panelRadius)).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            pageMain
        }
    }

    @ViewBuilder private var pageMain: some View {
        switch nav.deliver {
        case .projects: DeliverProjects(nav: nav)
        case .project(let id, let folder):
            if store.project(id) != nil { DeliverProjectView(nav: nav, project: id, folder: folder) } else { DeliverProjects(nav: nav) }
        case .asset(let id, let version, let comment):
            if store.find(id) != nil { DeliverAssetView(nav: nav, asset: id, version: version, comment: comment).id(id) } else { DeliverProjects(nav: nav) }
        case .links(let project, let link):
            if store.project(project) != nil { DeliverLinksView(nav: nav, project: project, opened: link).id(project) } else { DeliverProjects(nav: nav) }
        case .inbox: DeliverInbox(nav: nav)
        case .deliveryCheck: DeliveryCheckView().padding(Design.Studio.panelInset)
        case .archiveProject: DeliverProjects(nav: nav)
        case .nas(let id):
            if ReviewPublish.shared.host(id) != nil { DeliverBrowseView(nav: nav, place: .nas(id)).id(id) } else { DeliverProjects(nav: nav) }
        case .browse(let place): DeliverBrowseView(nav: nav, place: place).id(place)
        }
    }
}

// MARK: - Sidebar

struct DeliverSidebar: View {
    /// The links the sidebar lists under a project: none unless that project is open (no global list of links).
    /// Under its project the project name is noise: "Spring campaign – cuts · Client" shows as "cuts · Client".
    static func shortTitle(_ title: String, project: String) -> String {
        guard title.hasPrefix(project) else { return title }
        let rest = title.dropFirst(project.count).drop { " –-·:".contains($0) }
        return rest.isEmpty ? title : String(rest)
    }

    static func links(of project: UUID, store: DeliverStore, selection: Deliver.Selection) -> [Deliver.ShareLink] {
        selection.project == project ? store.links.filter { $0.isLive && $0.project == project } : []
    }

    @Bindable var nav: StudioNavigator
    @State private var store = DeliverStore.shared
    @State private var server = DeliverServer.shared
    @State private var renaming: UUID?
    @State private var name = ""
    @State private var deleting: UUID?
    @State private var sharing: Deliver.Scope?
    @State private var naming = false
    @State private var settingUp = false
    @State private var branding: UUID?
    @State private var deadline: UUID?
    @State private var pairing = DeliverPairing.shared
    @State private var sync = DeliverSync.shared
    @State private var request = DeliverShareRequest.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Browse (§13.16): this Mac, each NAS host and the Edit Anywhere host Mac.
            header("Browse") { EmptyView() }
            ForEach(DeliverPlaces.all()) { place in
                let state = DeliverPlaces.state(place.id)
                row(place.name, symbol: place.symbol, on: nav.deliver == .browse(place.id), detail: state) { nav.deliver = .browse(place.id) }
            }
            header("Projects") {
                Button { naming = true; name = "" } label: { Image(systemName: "plus").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(Design.Studio.textQuiet).help("New Project")
            }
            List {
                ForEach(store.projects.filter { $0.hidden != true }) { project in
                    let unread = store.inbox.contains { $0.project == project.id && !$0.read }
                    let open = nav.deliver.project == project.id
                    row(project.name, symbol: "folder", on: open && !nav.deliver.isLinks, dot: unread) {
                        nav.deliver = .project(project.id, folder: nil)
                    }
                    .contextMenu {
                        Button("Rename…") { renaming = project.id; name = project.name }
                        Button("Share Project…") { sharing = .project(project.id) }
                        Button("Branding…") { branding = project.id }
                        Button("Feedback Deadline…") { deadline = project.id }
                        Button("Watch Render Folder…") { watch(project.id) }
                        Divider()
                        Button("Delete Project…", role: .destructive) { deleting = project.id }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    // The open project's links, under it (a link shows in the project it was made from).
                    if open {
                        ForEach(Self.links(of: project.id, store: store, selection: nav.deliver)) { link in
                            row(Self.shortTitle(link.title, project: project.name), symbol: "link", on: nav.deliver == .links(project.id, link: link.id), count: server.viewers(link: link.id), eye: true) {
                                nav.deliver = .links(project.id, link: link.id)
                            }
                            .padding(.leading, 16)
                            .moveDisabled(true)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }
                }
                .onMove { store.moveProjects(from: $0, to: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(maxHeight: .infinity)
            row(String(localized: "Inbox"), symbol: "tray", on: nav.deliver == .inbox, count: store.unread) { nav.deliver = .inbox }
            if !ReviewPublish.shared.hosts.contains(where: { $0.kind == .nas }) {
                row(String(localized: "Set Up a NAS Host…"), symbol: "externaldrive.badge.plus", on: false) { settingUp = true }
            }
            Divider().overlay(Design.Studio.line).padding(.vertical, 8)
            row(String(localized: PluckTool.deliveryCheck.name), symbol: PluckTool.deliveryCheck.symbol, on: nav.deliver == .deliveryCheck) {
                nav.deliver = .deliveryCheck
            }
            // Archive Project shows once that tool exists (hidden, not greyed, until then).
            if let archive = deliverArchiveTool() {
                row(String(localized: archive.name), symbol: archive.symbol, on: nav.deliver == .archiveProject) { nav.open(archive) }
            }
            if let footer = sync.footer {
                Text(verbatim: footer).font(Design.Studio.hint).foregroundStyle(sync.problem == nil ? Design.Studio.textQuiet : Design.Studio.warn)
                    .lineLimit(1).truncationMode(.tail).padding(.horizontal, 8).padding(.top, 6)
            }
            if let notice = DeliverRelay.shared.notice {
                Text(verbatim: notice).font(Design.Studio.hint).foregroundStyle(Design.Studio.warn).lineLimit(2).padding(.horizontal, 8)
            }
        }
        .padding(10)
        .sheet(isPresented: Binding(get: { pairing.pending != nil || pairing.askMove != nil }, set: { if !$0 { pairing.pending = nil; pairing.askMove = nil } })) {
            DeliverPairingSheet()
        }
        .sheet(item: Binding(get: { request.scope.map(DeliverShareTarget.init) }, set: { request.scope = $0?.scope })) { DeliverShareSheet(scope: $0.scope) }
        .sheet(item: Binding(get: { deadline.map(DeliverProjectID.init) }, set: { deadline = $0?.id })) { item in
            DeliverDeadlineSheet(title: "Feedback Deadline", initial: store.project(item.id)?.deadline) { store.setDeadline($0, project: item.id) }
        }
        .alert("New Project", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Create") { if let made = try? store.newProject(name) { nav.deliver = .project(made.id, folder: nil) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $name)
            Button("Rename") { if let renaming { store.rename(project: renaming, to: name) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this project?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Project", role: .destructive) {
                if let deleting { store.deleteProject(deleting); if nav.deliver.project == deleting { nav.deliver = .projects } }
            }
        } message: {
            Text("Its review copies, comments and links go. The original files stay where they are.")
        }
        .sheet(item: Binding(get: { sharing.map(DeliverShareTarget.init) }, set: { sharing = $0?.scope })) { DeliverShareSheet(scope: $0.scope) }
        .sheet(isPresented: $settingUp) { ReviewNASGuideSheet() }
        .sheet(item: Binding(get: { branding.map(DeliverProjectID.init) }, set: { branding = $0?.id })) { DeliverProjectBrandingSheet(project: $0.id) }
    }

    private func header<Trailing: View>(_ title: LocalizedStringKey, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// A folder whose new renders are offered as new versions (§13.4).
    private func watch(_ project: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        DeliverWatch.shared.add(.init(project: project, local: url.path, bookmark: try? url.bookmarkData()))
    }

    private func row(_ title: String, symbol: String, on: Bool, dot: Bool = false, count: Int = 0, eye: Bool = false, detail: String? = nil,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 16).foregroundStyle(on ? Design.Studio.text : Design.Studio.textQuiet)
                Text(verbatim: title).font(Design.Studio.body).lineLimit(1)
                Spacer(minLength: 4)
                if let detail { Text(verbatim: detail).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1) }
                if dot { Circle().fill(Design.Brand.pink).frame(width: 6, height: 6) }
                if count > 0 {
                    HStack(spacing: 3) {
                        if eye { Image(systemName: "eye").font(.system(size: 9)) }
                        Text(verbatim: "\(count)")
                    }
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                }
            }
            .foregroundStyle(Design.Studio.text)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(on ? Design.Studio.raised : .clear, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Archive Project, when this build has the tool (its case is `.archive`); the Deliver sidebar's only tie to it.
func deliverArchiveTool() -> PluckTool? { PluckTool(rawValue: "archive") }

extension Deliver.Selection {
    /// The project this is in (a project, a folder, or an asset of it).
    @MainActor var project: UUID? {
        switch self {
        case .project(let id, _): id
        case .asset(let id, _, _): DeliverStore.shared.find(id)?.project
        case .links(let id, _): id
        default: nil
        }
    }

    var isLinks: Bool { if case .links = self { true } else { false } }
}

/// A project, as a sheet's item.
struct DeliverProjectID: Identifiable { let id: UUID }

/// A scope to share, as a sheet's item.
struct DeliverShareTarget: Identifiable {
    let scope: Deliver.Scope
    var id: String { "\(scope)" }
}

// MARK: - Projects grid

struct DeliverProjects: View {
    @Bindable var nav: StudioNavigator
    @State private var store = DeliverStore.shared
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Projects").font(Design.Studio.pageTitle).foregroundStyle(Design.Studio.text)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(store.projects.filter { $0.hidden != true }) { project in
                        Button { nav.deliver = .project(project.id, folder: nil) } label: { card(project) }.buttonStyle(.plain)
                    }
                    Button { naming = true; name = "" } label: {
                        // (Laid out as a project card, so it lines up with them.)
                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Design.Studio.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .overlay { Image(systemName: "plus").font(.system(size: 18)) }
                            Text("New Project").font(Design.Studio.body)
                            Text(verbatim: " ").font(Design.Studio.hint)
                        }
                        .foregroundStyle(Design.Studio.textQuiet)
                        .padding(10)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
        }
        .alert("New Project", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Create") { if let made = try? store.newProject(name) { nav.deliver = .project(made.id, folder: nil) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func card(_ project: Deliver.Project) -> some View {
        let assets = store.content(project.id).assets
        let cover = assets.first { $0.id == project.cover } ?? assets.first
        return VStack(alignment: .leading, spacing: 8) {
            DeliverPoster(asset: cover)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 8, style: .continuous))
            Text(verbatim: project.name).font(Design.Studio.body).foregroundStyle(Design.Studio.text).lineLimit(1)
            HStack {
                Text("\(assets.count) assets")
                Spacer()
                if let last = store.lastComment[project.id] { Text(last, format: .relative(presentation: .named)) }
            }
            .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
        }
        .padding(10)
        .studioBox()
        .contentShape(.rect)
    }
}

/// An asset's poster (its current version's), or its kind's symbol.
struct DeliverPoster: View {
    let asset: Deliver.Asset?
    var body: some View {
        let folder = asset.map { DeliverStore.shared.copies($0.current.id) }
        let file = asset?.kind == .image ? folder?.appendingPathComponent("image.jpg") : folder?.appendingPathComponent("poster.jpg")
        ZStack {
            Design.Studio.raised
            if let file, let image = NSImage(contentsOf: file) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: asset.map { DeliverPoster.symbol($0.kind) } ?? "film").font(.system(size: 22)).foregroundStyle(Design.Studio.textFaint)
            }
        }
        .clipped()
    }

    static func symbol(_ kind: Deliver.Kind) -> String {
        switch kind {
        case .video: "film"
        case .audio: "waveform"
        case .image: "photo"
        case .document: "doc.richtext"
        case .other: "doc"
        }
    }
}

// MARK: - Shared links and the inbox

struct DeliverLinksView: View {
    @Bindable var nav: StudioNavigator
    let project: UUID
    @State private var store = DeliverStore.shared
    @State private var server = DeliverServer.shared
    @State private var open: UUID?

    init(nav: StudioNavigator, project: UUID, opened: UUID?) {
        self.nav = nav
        self.project = project
        _open = State(initialValue: opened)
    }

    var body: some View {
        let links = store.links.filter { $0.project == project }
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: store.project(project)?.name ?? "").font(Design.Studio.pageTitle).foregroundStyle(Design.Studio.text).padding(.bottom, 8)
                if links.isEmpty { Text("No links yet").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet) }
                ForEach(links.reversed()) { link in
                    VStack(spacing: 0) {
                        DeliverLinkRow(link: link, viewers: server.viewers(link: link.id), expanded: open == link.id)
                            .onTapGesture { open = open == link.id ? nil : link.id }
                        if open == link.id { DeliverActivityFeed(link: link).padding(.top, 6) }
                    }
                }
            }
            .padding(24)
        }
        .onChange(of: nav.deliver) { _, now in if case .links(_, let link?) = now { open = link } }
    }
}

/// A link's activity, newest first: who opened it, looked at, played, commented, downloaded, uploaded, approved.
struct DeliverActivityFeed: View {
    let link: Deliver.ShareLink
    @State private var store = DeliverStore.shared

    var body: some View {
        let _ = store.activityChanged
        let entries = Array(store.activity(link.id).reversed().prefix(200))
        VStack(alignment: .leading, spacing: 2) {
            if entries.isEmpty { Text("Nobody has opened it yet").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).padding(10) }
            ForEach(entries) { entry in
                HStack(spacing: 10) {
                    Image(systemName: Self.symbol(entry.kind)).font(.system(size: 11)).foregroundStyle(Design.Studio.textQuiet).frame(width: 16)
                    Text(verbatim: entry.name ?? String(localized: "Guest")).font(Design.Studio.body).foregroundStyle(Design.Studio.text)
                    if let email = entry.email { Text(verbatim: email).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet) }
                    Text(verbatim: Self.what(entry, store: store)).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                    Spacer()
                    Text(entry.at, format: .relative(presentation: .named)).font(Design.Studio.hint).foregroundStyle(Design.Studio.textFaint)
                }
                .padding(.horizontal, 12).frame(height: 26)
            }
        }
        .padding(.vertical, 6)
        .studioBox()
    }

    static func symbol(_ kind: String) -> String {
        switch kind {
        case "opened": "door.left.hand.open"
        case "viewed": "eye"
        case "played": "play"
        case "commented": "text.bubble"
        case "downloaded": "arrow.down.circle"
        case "uploaded": "arrow.up.circle"
        case "approved": "checkmark.seal"
        default: "circle"
        }
    }

    /// "played Hero 30s 0:00–0:12", "downloaded Hero 30s (review copy)"…
    @MainActor static func what(_ entry: Deliver.Activity, store: DeliverStore) -> String {
        let name = entry.asset.flatMap { store.find($0)?.asset.name } ?? ""
        let fps = entry.asset.flatMap { store.find($0)?.asset.current.probe?.fps } ?? 25
        func time(_ frame: Int?) -> String { Format.duration(Double(frame ?? 0) / fps) }
        switch entry.kind {
        case "opened": return String(localized: "opened the link")
        case "viewed": return String(localized: "looked at \(name)")
        case "played": return String(localized: "played \(name) \(time(entry.detail?.from))–\(time(entry.detail?.to))")
        case "commented": return String(localized: "commented on \(name)")
        case "downloaded": return entry.detail?.what == "proxy" ? String(localized: "downloaded \(name) (review copy)") : String(localized: "downloaded \(name)")
        case "uploaded": return String(localized: "uploaded \(entry.detail?.name ?? name)")
        case "approved": return entry.detail?.what == "changes" ? String(localized: "asked for changes on \(name)") : String(localized: "approved \(name)")
        default: return entry.kind
        }
    }
}

/// A link: its title, what it shares, mode, expiry, opens and people, who serves it, viewers now; Copy, Turn Off and a menu
/// (pause, duplicate, QR code, email, notifications, send an update).
struct DeliverLinkRow: View {
    let link: Deliver.ShareLink
    var viewers = 0
    var expanded = false
    @State private var store = DeliverStore.shared
    @State private var qr = false
    @State private var reopening = false
    @State private var deleting = false

    /// The helper's room state: an always-on host serves it (standby here), or this Mac does.
    private var served: String? {
        switch DeliverServer.shared.rooms[link.roomID] {
        case "standby":
            let host = ReviewPublish.shared.publications.first { $0.scope.project == link.project }.flatMap { ReviewPublish.shared.host($0.host) }
            return host.map { String(localized: "Served by \($0.name)") } ?? String(localized: "Served by an always-on host")
        case "active", "registered": return String(localized: "Served by this Mac")
        default: return nil
        }
    }

    var body: some View {
        let _ = store.activityChanged
        let views = store.views(link.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                StudioTile(symbol: link.recipient != nil ? "person.crop.circle" : link.mode == .review ? "text.bubble" : "play.rectangle",
                           colour: link.isLive && !link.isPaused ? Design.Studio.text : Design.Studio.textFaint, size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(verbatim: link.title).font(Design.Studio.body).foregroundStyle(Design.Studio.text).lineLimit(1)
                        if link.isTeam { StudioChip(text: Text("Team")) }
                        if link.watermark != nil { Image(systemName: "drop.halffull").font(.system(size: 10)).foregroundStyle(Design.Studio.textQuiet).help("Watermarked") }
                        if link.muted == true { Image(systemName: "bell.slash").font(.system(size: 10)).foregroundStyle(Design.Studio.textQuiet) }
                    }
                    HStack(spacing: 6) {
                        Text(verbatim: store.name(link.scope))
                        Text(verbatim: "·")
                        Text(link.mode == .review ? "Review" : "Presentation")
                        if let expires = link.expires { Text(verbatim: "·"); Text("Until \(expires.formatted(date: .abbreviated, time: .shortened))") }
                        if views.opened > 0 { Text(verbatim: "·"); Text("Opened \(views.opened)×") }
                        if views.people > 0 { Text(verbatim: "·"); Text("\(views.people) people") }
                        if let opened = link.lastOpened { Text(verbatim: "·"); Text("Last \(opened.formatted(.relative(presentation: .named)))") }
                        if link.isLive, let served = served { Text(verbatim: "·"); Text(verbatim: served) }
                        if let deadline = DeliverDeadlines.effective(link, store: store), deadline > .now {
                            Text(verbatim: "·"); Text("Feedback by \(deadline.formatted(date: .abbreviated, time: .shortened))")
                        }
                    }
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                }
                Spacer()
                if viewers > 0 { StudioChip(text: Text(verbatim: "\(viewers)"), symbol: "eye") }
                if link.revoked != nil {
                    StudioChip(text: Text("Off"))
                } else if link.isLive, DeliverDeadlines.shared.isClosed(link) {
                    StudioChip(text: Text("Closed: feedback deadline"), colour: Design.Studio.warn, tinted: true)
                    Button("Reopen…") { reopening = true }.buttonStyle(StudioFlatButtonStyle())
                } else if !link.isLive {
                    StudioChip(text: Text("Expired"))
                } else {
                    if link.isPaused { StudioChip(text: Text("Paused"), colour: Design.Studio.warn, tinted: true) }
                    if store.key(link.id) == nil, let device = link.madeOn, device != Host.current().localizedName {
                        StudioChip(text: Text("Made on \(device)"))
                    } else {
                        Button("Copy") { if let url = store.url(link) { DeliverLinkShare.copy(url) } }.buttonStyle(StudioFlatButtonStyle())
                    }
                    menu
                }
            }
            if qr, let url = store.url(link), let image = DeliverLinkShare.qr(url) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 150, height: 150).padding(8).background(.white, in: .rect(cornerRadius: 8))
            }
        }
        .padding(12)
        .studioBox(outline: expanded ? Design.Studio.line : nil)
        .contentShape(.rect)
        .sheet(isPresented: $reopening) {
            DeliverDeadlineSheet(title: "Reopen", initial: link.deadline) { DeliverDeadlines.shared.reopen(link.id, deadline: $0) }
        }
        .confirmationDialog("Delete this link and its data?", isPresented: $deleting) {
            Button("Delete", role: .destructive) { let id = link.id; Task { await DeliverLink.shared.deleteLink(id) } }
        } message: { Text("The link stops working. Its activity log and what pluck.tools keeps for it are deleted. Comments stay.") }
    }

    private var menu: some View {
        Menu {
            Button(link.isPaused ? "Resume" : "Pause") { store.updateLink(link.id) { $0.paused = $0.isPaused ? nil : true } }
            Button("Duplicate") { _ = try? store.duplicate(link.id) }
            Button(qr ? "Hide QR Code" : "QR Code") { qr.toggle() }
            if let url = store.url(link) { Button("Email…") { DeliverLinkShare.email(link, url: url) } }
            Button("Send Update…") { DeliverLinkRow.sendUpdate(link) }
            Button("Feedback Deadline…") { reopening = true }
            Divider()
            Toggle("Tell Me When It’s Opened", isOn: Binding(get: { link.notifyOpened == true }, set: { value in store.updateLink(link.id) { $0.notifyOpened = value ? true : nil } }))
            Toggle("Mute Notifications", isOn: Binding(get: { link.muted == true }, set: { value in store.updateLink(link.id) { $0.muted = value ? true : nil } }))
            Divider()
            Button("Turn Off", role: .destructive) { store.revoke(link.id) }
            Button("Delete Link and Its Data…", role: .destructive) { deleting = true }
        } label: { Image(systemName: "ellipsis.circle").foregroundStyle(Design.Studio.textQuiet) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    static let updateKey = "reviewUpdateSent"

    /// A draft in Mail listing the owner's comments and replies on the link's assets since the last update (or 7 days).
    @MainActor static func sendUpdate(_ link: Deliver.ShareLink) {
        let key = updateKey + link.id.uuidString
        let since = (UserDefaults.standard.object(forKey: key) as? Date) ?? Date.now.addingTimeInterval(-7 * 86400)
        let body = updateText(link, since: since, store: .shared)
        guard let mail = DeliverLinkShare.mailto(subject: String(localized: "Update: \(link.title)"), body: body) else { return }
        NSWorkspace.shared.open(mail)
        UserDefaults.standard.set(Date.now, forKey: key)
    }

    @MainActor static func updateText(_ link: Deliver.ShareLink, since: Date, store: DeliverStore) -> String {
        let server = DeliverServer(store: store)
        var lines: [String] = []
        for asset in store.content(link.project).assets where server.inScope(asset, link) {
            let clip = DeliverExport.Clip(name: asset.name, version: asset.current.number, probe: asset.current.probe)
            var here: [String] = []
            for comment in store.comments(asset.id) where server.visible(comment, link) {
                if comment.authorToken == nil, comment.created > since { here.append("• \(clip.place(comment)) \(comment.text)") }
                for reply in comment.replies where reply.authorToken == nil && reply.created > since {
                    here.append("• \(String(localized: "Reply to")) “\(comment.text.prefix(40))”: \(reply.text)")
                }
            }
            if !here.isEmpty { lines.append(asset.name); lines += here; lines.append("") }
        }
        if lines.isEmpty { lines = [String(localized: "Nothing new since \(since.formatted(date: .abbreviated, time: .omitted)).")] }
        if let url = store.url(link) { lines += ["", url] }
        return lines.joined(separator: "\n")
    }
}

struct DeliverInbox: View {
    @Bindable var nav: StudioNavigator
    @State private var store = DeliverStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Inbox").font(Design.Studio.pageTitle).foregroundStyle(Design.Studio.text).padding(.bottom, 12)
                if store.inbox.isEmpty { Text("Nothing new").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet) }
                ForEach(store.inbox) { item in
                    Button {
                        store.markRead(item.id)
                        nav.showReview(asset: item.asset, version: item.version, comment: item.kind == "approval" ? nil : item.id)
                    } label: {
                        HStack(spacing: 10) {
                            Circle().fill(item.read ? Color.clear : Design.Brand.pink).frame(width: 6, height: 6)
                            Image(systemName: item.kind == "approval" ? "checkmark.seal" : item.kind == "reply" ? "arrowshape.turn.up.left" : "text.bubble")
                                .font(.system(size: 12)).foregroundStyle(Design.Studio.textQuiet).frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(verbatim: item.author).foregroundStyle(Design.Studio.text)
                                    Text(verbatim: store.find(item.asset)?.asset.name ?? "").foregroundStyle(Design.Studio.textQuiet)
                                }
                                .font(Design.Studio.body)
                                Text(verbatim: item.kind == "approval" ? (item.summary == "approved" ? String(localized: "Approved") : String(localized: "Needs changes")) : item.summary)
                                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                            }
                            Spacer()
                            Text(item.created, format: .relative(presentation: .named)).font(Design.Studio.hint).foregroundStyle(Design.Studio.textFaint)
                        }
                        .padding(10)
                        .studioBox()
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
        }
    }
}
