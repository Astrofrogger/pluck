import SwiftUI

/// The Deliver page (§8): review projects in a sidebar, shared links, the inbox and the delivery tools,
/// and what's chosen in the main panel.
struct DeliverPage: View {
    @Bindable var nav: StudioNavigator
    @State private var store = DeliverStore.shared

    var body: some View {
        HStack(spacing: Design.Studio.panelGap) {
            DeliverSidebar(nav: nav)
                .frame(width: 244)
                .frame(maxHeight: .infinity)
                .studioPanel()
            main
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .studioPanel()
        }
        .navigationTitle("")
        .onChange(of: nav.deliver) { _, now in ShareBuilder.shared.navigated(to: now, nav: nav) }
    }

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
            case "share", "sharephone":
                nav.deliver = .project(project.id, folder: nil)
                ShareBuilder.shared.new(.project(project.id))
                ShareBuilder.shared.session?.phone = view == "sharephone"
            case "inbox":
                // A few comments and an approval from the last days (once).
                if store.inbox.isEmpty, asset != nil {
                    let assets = store.content(project.id).assets
                    for (n, item) in [("Client", "comment", "Logo comes in too early, can it wait for the beat?", 0.1), ("Producer", "reply", "Agreed, two bars later works.", 3.0),
                                      ("Client", "approval", "approved", 26.0), ("Editor", "comment", "Swapped the last shot for the wider one.", 50.0)].enumerated() {
                        let target = assets[n % assets.count]
                        store.addInbox(.init(project: project.id, asset: target.id, version: target.current.id, kind: item.1, summary: item.2, author: item.0,
                                             created: .now.addingTimeInterval(-item.3 * 3600), read: n > 1))
                    }
                }
                nav.deliver = .inbox
            case "links": nav.deliver = .links(project.id, link: nil)
            case "activity": nav.deliver = .links(project.id, link: store.links.first { $0.project == project.id }?.id)
            case "sharemore", "shareedit", "shareeditphone":
                // A live link open, its watermark and layout changed but not updated yet ("Unsaved changes").
                nav.deliver = .project(project.id, folder: nil)
                if let link = store.links.first(where: { $0.project == project.id && $0.recipient == nil }) {
                    ShareBuilder.shared.open(link.id)
                    if let session = ShareBuilder.shared.session {
                        session.phone = view == "shareeditphone"
                        if view != "shareedit" { session.draft.watermark = .init(); session.draft.layout = "list" }
                    }
                }
            case "delivered", "deliveredphone":
                // wf-deliver: a link marked Delivered (not updated yet), its files grouped as one deliverable, two approved.
                nav.deliver = .project(project.id, folder: nil)
                let assets = store.content(project.id).assets
                for (id, group) in Deliver.suggestedGroups(assets) { store.setGroup(group, of: [id]) }
                for asset in assets.filter({ $0.group != nil }).prefix(2) { store.setStatus(.approved, of: asset.id, by: "Client") }
                if let link = store.links.first(where: { $0.project == project.id && $0.recipient == nil }) {
                    ShareBuilder.shared.open(link.id)
                    ShareBuilder.shared.session?.setDelivered(true)
                    ShareBuilder.shared.session?.phone = view == "deliveredphone"
                }
            case "hostupdate":
                // Update Now on a NAS that didn't move (no TrueNAS API key here): the message and the key field.
                let sample = Deliver.Host(name: "Studio NAS", kind: .nas, address: "192.0.2.10:8790", pin: Array(repeating: "AB", count: 32).joined(separator: ":"), role: "main")
                DeliverHostUpdate.shared.noUpdater.insert(sample.id)
                panelInPage = AnyView(DeliverHostSheet(host: sample))
                nav.deliver = .inbox
            case "browse": nav.deliver = .browse(.local)
            case "browsenas", "uploaddest", "uploaddestnone", "uploaddestshare", "publishnas":
                // Two stand-in review servers (main and backup) answering browse with two media roots.
                let fingerprint = Array(repeating: "AB", count: 32).joined(separator: ":"), key = DeliverKeys.base64url(DeliverKeys.random(32))
                ReviewHostClient.fakeFingerprint = fingerprint
                ReviewHostClient.fake = { request, _ in
                    if request["key"] != nil { return ["ok": true] }
                    // And a backup paired straight with the main (no host record here), copying.
                    if request["op"] as? String == "devices" {
                        return ["devices": [["id": "b1", "name": "Proxmox", "role": "backup", "lastSeen": ISO8601DateFormatter().string(from: .now),
                                             "replica": ["uplinkMbps": 940, "quality": "same", "versions": ["ready": 12, "queued": 2]]]]]
                    }
                    if request["op"] as? String == "roots" { return ["roots": ["nas1", "nas2", "renders"], "writable": ["renders"]] }
                    guard request["op"] as? String == "browse" else { return ["ok": true] }
                    let path = request["path"] as? String ?? ""
                    let names = path.isEmpty ? ["nas1", "nas2", "renders"] : path.hasPrefix("renders") ? ["Client", "Wedding", "Spring campaign"] : ["Day 1", "Day 2", "Hero_30s_v3.mov"]
                    return ["entries": names.map { ["name": $0, "path": path.isEmpty ? $0 : path + "/" + $0, "dir": !$0.hasSuffix(".mov"), "size": 1_000_000] }]
                }
                let publish = ReviewPublish.shared
                for (name, role) in [("Studio NAS", "main"), ("Backup NAS", "backup")] {
                    // (Added each time: the key lives in the test's in-memory keychain only.)
                    if var host = publish.addNAS(name: name, address: name.lowercased().replacingOccurrences(of: " ", with: "-") + ".test:8790",
                                                                                                     pairing: "pluck-host:\(key)@\(fingerprint)") {
                        host.role = role
                        if role == "main" { host.rootNames = ["nas1": "Projects-2026", "nas2": "Archive 2025"] }
                        publish.add(host)
                    }
                }
                guard let main = publish.hosts.first(where: { $0.role == "main" }) else { break }
                if view == "browsenas" { nav.deliver = .browse(.nas(main.id)); break }
                // Publish with the main as the data host (stand-in sync): NAS first, the footage still only here.
                if view == "publishnas" {
                    DeliverSync.shared.manual = true
                    if store.content(project.id).assets.isEmpty { _ = try? store.add(files, to: project.id, folder: nil) }
                    Task { try? await DeliverSync.shared.migrate(to: main) }
                    panelInPage = AnyView(DeliverPublishSheet(scope: .project(project.id)))
                    nav.deliver = .inbox
                    break
                }
                // Share for Review's destination step: the uploads folder, opened at the project's last folder (or, "uploaddestnone", no
                // share here and no uploads folder; "uploaddestshare", a client folder on the NAS's share mounted here).
                DeliverUploadDestination.remember("renders/Spring campaign", host: main.id, project: project.id)
                let client = FileManager.default.temporaryDirectory.appendingPathComponent("Projects-2026/Clients/Spring campaign")
                try? FileManager.default.createDirectory(at: client, withIntermediateDirectories: true)
                let stage: DeliverUploadDestination.Stage = view == "uploaddestnone" ? .noRoot : view == "uploaddestshare" ? .share(start: client.path) : .loading
                panelInPage = AnyView(DeliverUploadPicker(host: main, project: project.id, stage: stage, done: { _ in }, back: {})
                    .padding(Design.Spacing.sheet).background(Design.Studio.panel))
                nav.deliver = .inbox
            case "people": DeliverPeople.snapshot(); nav.deliver = .people
            case "peopletransfer", "peopleinvite":
                // Roles: Transfer Admin… and Invite… over the stand-in team (loaded first).
                DeliverPeople.snapshot()
                Task { await DeliverPeople.shared.load() }
                panelInPage = view == "peopletransfer" ? AnyView(DeliverTransferAdminSheet()) : AnyView(DeliverPersonInviteSheet())
                nav.deliver = .people
            case "server": panelInPage = AnyView(DeliverServerChooser()); nav.deliver = .inbox
            case "serverbackup": panelInPage = AnyView(DeliverServerChooser(role: .backup)); nav.deliver = .inbox
            case "proxmoxmain": panelInPage = AnyView(DeliverProxmoxMainSheet()); nav.deliver = .inbox
            case "truenas": panelInPage = AnyView(ReviewTrueNASSetupSheet()); nav.deliver = .inbox
            case "truenasconfirm":
                // After Install: the server's fingerprint to compare with the app's log.
                let setup = TrueNASSetup()
                setup.address = "192.0.2.10"
                setup.done = Deliver.Host(name: "Studio NAS", kind: .nas, address: "192.0.2.10:8790")
                setup.serverFingerprint = (0..<32).map { String(format: "%02X", ($0 * 37 + 11) % 256) }.joined(separator: ":")
                panelInPage = AnyView(ReviewTrueNASSetupSheet(setup: setup))
                nav.deliver = .inbox
            case "truenasaccess":
                // Media checked after Connect (a stand-in TrueNAS): one the server reads, one whose ACL leaves out the apps user, its steps open.
                let setup = TrueNASSetup()
                setup.address = "192.0.2.10"
                setup.apiKey = "1-stand-in"
                setup.addMedia("media/Projects-2025")
                setup.addMedia("media/Projects-2026")
                TrueNASClient.fake = { (method: String, params: [Any]) -> [String: Any] in
                    let path = params.first as? String ?? ""
                    switch method {
                    case "auth.login_with_api_key": return ["result": true]
                    case "system.version": return ["result": "25.10.0"]
                    case "auth.me": return ["result": ["privilege": ["roles": ["$set": TrueNASClient.roles]]]]
                    case "pool.dataset.query": return ["result": ["tank", "tank/apps", "media", "media/Projects-2026", "media/Projects-2025"].map { ["id": $0] }]
                    case "filesystem.stat": return ["result": ["mode": 0o40755, "uid": 0, "gid": 0, "acl": path.hasSuffix("2026")]]
                    case "filesystem.getacl": return ["result": ["acltype": "NFS4", "uid": 0, "gid": 0, "acl": [
                        ["tag": "owner@", "type": "ALLOW", "perms": ["BASIC": "FULL_CONTROL"], "flags": ["BASIC": "INHERIT"]]]]]
                    case "filesystem.listdir": return ["result": [Any]()]
                    default: return ["result": NSNull()]
                    }
                }
                Task { await setup.connect() }
                panelInPage = AnyView(ReviewTrueNASSetupSheet(setup: setup, expanded: ["media/Projects-2026"]))
                nav.deliver = .inbox
            case "join":
                let invitation = PrivateNetwork.Invitation(way: .reviewHost(node: String(repeating: "a1", count: 32), relay: nil, expires: .now.addingTimeInterval(900),
                                                                       pin: Array(repeating: "AB", count: 32).joined(separator: ":"), lan: "192.0.2.10:8790", role: "mac"), name: "Studio NAS", code: "ABCD-EFGH-JKMN")
                panelInPage = AnyView(DeliverJoinSheet(link: invitation.link?.absoluteString ?? ""))
                nav.deliver = .inbox
            case "truenasedit", "pairagain":
                // A server set up through TrueNAS, its API key kept: Change Folders reads the app back from a stand-in TrueNAS.
                let sample = Deliver.Host(name: "Studio NAS", kind: .nas, address: "192.0.2.10:8790", pin: Array(repeating: "AB", count: 32).joined(separator: ":"), role: "main")
                TrueNASKeychain.save("1-stand-in", for: "192.0.2.10")
                let compose: [String: Any] = ["services": ["pluck-review": [
                    "environment": ["PLUCK_HOST_KEY": DeliverKeys.base64url(DeliverKeys.random(32)), "PLUCK_HOST_NAME": "Studio NAS", "PLUCK_IROH": "1"],
                    "volumes": ["/mnt/tank/apps/pluck-review:/data", "/mnt/media/Projects-2026:/media/nas1:ro", "/mnt/media/Projects-2025:/media/nas2:ro",
                                "/mnt/media/Archive/Clients/Long-running-projects-2019-2024:/media/nas3:ro", "/mnt/tank/renders:/uploads/renders"],
                    "mem_limit": "3g", "cpus": "2.0"] as [String: Any]]]
                TrueNASClient.fake = { (method: String, _: [Any]) -> [String: Any] in
                    switch method {
                    case "auth.login_with_api_key": return ["result": true]
                    case "system.version": return ["result": "25.10.0"]
                    case "auth.me": return ["result": ["privilege": ["roles": ["$set": TrueNASClient.roles]]]]
                    case "pool.dataset.query": return ["result": ["tank", "tank/apps", "tank/apps/pluck-review", "tank/renders", "media", "media/Projects-2026", "media/Projects-2025", "media/Archive/Clients/Long-running-projects-2019-2024"].map { ["id": $0] }]
                    case "app.query": return ["result": [["name": "pluck-review", "state": "RUNNING"]]]
                    case "app.config": return ["result": compose]
                    default: return ["result": NSNull()]
                    }
                }
                panelInPage = view == "pairagain" ? AnyView(DeliverPairAgainSheet(host: sample)) : AnyView(ReviewTrueNASSetupSheet(editing: sample))
                nav.deliver = .inbox
            case "backup", "hostsheet":
                let sample = Deliver.Host(name: "Office NAS", kind: .nas, address: "192.0.2.10:8790", version: "0.3.0", protocol: 3)
                panelInPage = view == "backup" ? AnyView(DeliverBackupSheet(main: sample)) : AnyView(DeliverHostSheet(host: sample))
                nav.deliver = .inbox
            case "invite":
                // Invite a Teammate with two teammates paired (a stand-in server answering invite and devices).
                let fingerprint = Array(repeating: "AB", count: 32).joined(separator: ":"), day: TimeInterval = 86_400
                let iso = { (ago: TimeInterval) in ISO8601DateFormatter().string(from: .now.addingTimeInterval(-ago)) }
                let link = PrivateNetwork.Invitation(way: .reviewHost(node: String(repeating: "a1", count: 32), relay: nil, expires: .now.addingTimeInterval(900),
                                                                     pin: fingerprint, lan: "192.0.2.10:8790", role: "mac"), name: "Studio NAS", code: "ABCD-EFGH-JKMN").link?.absoluteString ?? ""
                ReviewHostClient.fakeFingerprint = fingerprint
                ReviewHostClient.fake = { request, _ in
                    switch request["op"] as? String {
                    case "invite": return ["link": link, "expires": ISO8601DateFormatter().string(from: .now.addingTimeInterval(900)), "code": "ABCD-EFGH-JKMN"]
                    case "devices": return ["devices": [
                        ["id": "d1", "name": "Edit Suite iMac", "role": "mac", "access": "admin", "added": iso(12 * day), "lastSeen": iso(600), "via": "lan"],
                        ["id": "d2", "name": "MacBook Pro (Colour)", "role": "mac", "access": "editor", "added": iso(3 * day), "lastSeen": iso(2 * day), "via": "iroh"],
                        ["id": "b1", "name": "Backup NAS", "role": "backup", "added": iso(20 * day), "lastSeen": iso(60)]]]
                    default: return ["ok": true]
                    }
                }
                if let host = ReviewPublish.shared.addNAS(name: "Studio NAS", address: "studio-nas.test:8790", pairing: "pluck-host:\(DeliverKeys.base64url(DeliverKeys.random(32)))@\(fingerprint)") {
                    var host = host
                    (host.roles, host.access) = (1, "admin")
                    ReviewPublish.shared.add(host)
                    panelInPage = AnyView(DeliverInviteSheet(host: host))
                }
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
        } else if let session = ShareBuilder.shared.session {
            DeliverShareBuilderView(session: session).id(session.id)
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
        case .inbox: DeliverProjects(nav: nav).overlay(alignment: .leading) { DeliverInbox(nav: nav) }
        case .people: DeliverPeopleView()
        case .view(let id): DeliverViewResults(nav: nav, view: id).id(id)
        case .deliveryCheck: DeliveryCheckView().padding(Design.Studio.panelInset)
        case .archiveProject: DeliverProjects(nav: nav)
        case .nas(let id):
            if ReviewPublish.shared.host(id) != nil { DeliverBrowseView(nav: nav, place: .nas(id)).id(id) } else { DeliverProjects(nav: nav) }
        case .browse(let place): DeliverBrowseView(nav: nav, place: place).id(place)
        }
    }
}

// MARK: - Sidebar

/// A project's actions (rename, share, branding, deadline, delete, a new one), asked from any row, switcher or card;
/// the sidebar, always on the page, shows their sheets.
@MainActor @Observable final class DeliverProjectActions {
    static let shared = DeliverProjectActions()
    var renaming: UUID?
    var deleting: UUID?
    var sharing: Deliver.Scope?
    var branding: UUID?
    var deadline: UUID?
    var naming = false
    var name = ""

    func newProject() { name = ""; naming = true }
}

/// A project's menu: the same in the sidebar, the recent row and on its card.
struct DeliverProjectMenu: View {
    let project: Deliver.Project
    @State private var actions = DeliverProjectActions.shared

    var body: some View {
        Button("Rename…") { actions.renaming = project.id; actions.name = project.name }
        Button("Share Project…") { actions.sharing = .project(project.id) }
        Button("Branding…") { actions.branding = project.id }
        Button("Feedback Deadline…") { actions.deadline = project.id }
        Button("Watch Render Folder…") { DeliverSidebar.watch(project.id) }
        Divider()
        Button("Delete Project…", role: .destructive) { actions.deleting = project.id }
    }
}

/// A quiet "⋯" opening a menu, on cards and rows.
struct DeliverMoreMenu<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(Design.Studio.textQuiet)
                .frame(width: 24, height: 20).contentShape(.rect)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("More")
    }
}

/// A project's picture: its cover's poster, else a soft plum-to-violet wash of its own (the same every time).
struct DeliverProjectCover: View {
    let project: Deliver.Project
    @State private var store = DeliverStore.shared

    var body: some View {
        let assets = store.content(project.id).assets
        let cover = assets.first { $0.id == project.cover } ?? assets.first
        Color.clear
            .overlay {
                if let file = DeliverPoster.file(cover), let image = NSImage(contentsOf: file) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Self.wash(project.id)
                }
            }
            .clipped()
    }

    static func wash(_ id: UUID) -> some View {
        let seed = Int(id.uuid.0)
        let (from, to) = seed % 2 == 0 ? (Design.Brand.pink, Design.Brand.violet) : (Design.Brand.violet, Design.Brand.pink)
        let left = seed / 2 % 2 == 0
        return GeometryReader { geometry in
            let side = max(geometry.size.width, geometry.size.height)
            ZStack {
                LinearGradient(colors: [from, to], startPoint: left ? .topLeading : .topTrailing, endPoint: left ? .bottomTrailing : .bottomLeading)
                // A soft lighter glow from one top corner.
                RadialGradient(colors: [from.opacity(0.75), from.opacity(0)], center: left ? .topTrailing : .topLeading, startRadius: 0, endRadius: side * 0.95)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

struct DeliverSidebar: View {
    /// The links the sidebar lists under a project: none unless that project is open (no global list of links).
    static func links(of project: UUID, store: DeliverStore, selection: Deliver.Selection) -> [Deliver.ShareLink] {
        selection.project == project ? store.links.filter { $0.isLive && $0.project == project } : []
    }

    @Bindable var nav: StudioNavigator
    @State private var store = DeliverStore.shared
    @State private var server = DeliverServer.shared
    @State private var actions = DeliverProjectActions.shared
    @State private var settingUp = false
    @State private var inviting: Deliver.Host?
    @State private var newView: Deliver.SavedView?
    @State private var pairing = DeliverPairing.shared
    @State private var sync = DeliverSync.shared
    @State private var request = DeliverShareRequest.shared
    /// Tree rows folded or unfolded by hand: the project's root folds, folders unfold.
    @State private var toggled: Set<UUID> = []
    @State private var hovered: UUID?

    private var browsing: Bool {
        switch nav.deliver {
        case .browse, .nas: true
        default: false
        }
    }

    private var openProject: Deliver.Project? { nav.deliver.project.flatMap { store.project($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switcher
            if let project = openProject { tree(project) } else { projectList }
            places
            if let project = openProject { shareLinks(project) }
            let onlyHere = openProject.map { DeliverUploadDestination.onlyHere(.project($0.id)).count } ?? 0
            if let footer = sync.footer(onlyHere: onlyHere, uploading: DeliverUploads.shared.active.count) {
                Text(verbatim: footer).font(Design.Studio.hint).foregroundStyle(sync.problem == nil && onlyHere == 0 ? Design.Studio.textQuiet : Design.Studio.warn)
                    .lineLimit(1).truncationMode(.tail).padding(.horizontal, 8).padding(.top, 6)
            }
            if let notice = DeliverRelay.shared.notice {
                Text(verbatim: notice).font(Design.Studio.hint).foregroundStyle(Design.Studio.warn).lineLimit(2).padding(.horizontal, 8)
            }
        }
        .padding(10)
        .sheet(isPresented: Binding(get: { pairing.showing && !pairing.inline },
                                    set: { if !$0 { pairing.pending = nil; pairing.askMove = nil; pairing.unreadable = false } })) {
            DeliverPairingSheet()
        }
        .onChange(of: request.scope) { _, scope in if let scope { request.scope = nil; ShareBuilder.shared.new(scope, nav: nav) } }
        .sheet(item: Binding(get: { actions.deadline.map(DeliverProjectID.init) }, set: { actions.deadline = $0?.id })) { item in
            DeliverDeadlineSheet(title: "Feedback Deadline", initial: store.project(item.id)?.deadline) { store.setDeadline($0, project: item.id) }
        }
        .alert("New Project", isPresented: $actions.naming) {
            TextField("Name", text: $actions.name)
            Button("Create") { if let made = try? store.newProject(actions.name) { nav.deliver = .project(made.id, folder: nil) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Project", isPresented: Binding(get: { actions.renaming != nil }, set: { if !$0 { actions.renaming = nil } })) {
            TextField("Name", text: $actions.name)
            Button("Rename") { if let renaming = actions.renaming { store.rename(project: renaming, to: actions.name) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this project?", isPresented: Binding(get: { actions.deleting != nil }, set: { if !$0 { actions.deleting = nil } })) {
            Button("Delete Project", role: .destructive) {
                if let deleting = actions.deleting { store.deleteProject(deleting); if nav.deliver.project == deleting { nav.deliver = .projects } }
            }
        } message: {
            Text("Its review copies, comments and links go. The original files stay where they are.")
        }
        .onChange(of: actions.sharing) { _, scope in if let scope { actions.sharing = nil; ShareBuilder.shared.new(scope, nav: nav) } }
        .sheet(isPresented: $settingUp) { DeliverServerChooser() }
        .sheet(item: $newView) { DeliverViewEditor(view: $0, project: $0.projects?.first) }
        .sheet(item: $inviting) { DeliverInviteSheet(host: $0) }
        .sheet(item: Binding(get: { actions.branding.map(DeliverProjectID.init) }, set: { actions.branding = $0?.id })) { DeliverProjectBrandingSheet(project: $0.id) }
    }

    private var hasServer: Bool { ReviewPublish.shared.hosts.contains { $0.kind == .nas } }

    // MARK: Project switcher

    /// The open project (or all of them) with a menu to go to another, as the top of the column.
    private var switcher: some View {
        let shown = store.projects.filter { $0.hidden != true }
        let current = openProject
        return Menu {
            Button("All Projects") { nav.deliver = .projects }
            Divider()
            ForEach(shown) { project in
                Button { nav.deliver = .project(project.id, folder: nil) } label: { Text(verbatim: project.name) }
            }
            Divider()
            Button("New Project…") { actions.newProject() }
        } label: {
            HStack(spacing: 10) {
                Group {
                    if let current { DeliverProjectCover(project: current) } else { StudioMark() }
                }
                .frame(width: 32, height: 32)
                .clipShape(.rect(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: current?.name ?? String(localized: "All Projects")).font(Design.Studio.body.weight(.medium)).foregroundStyle(Design.Studio.text).lineLimit(1)
                    Group {
                        if let current { Text("\(store.content(current.id).assets.count) assets") } else { Text("\(shown.count) projects") }
                    }
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Design.Studio.textQuiet)
            }
            .padding(6)
            .contentShape(.rect)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .padding(.bottom, 8)
    }

    // MARK: Projects (no project open)

    private var projectList: some View {
        List {
            ForEach(store.projects.filter { $0.hidden != true }) { project in
                let unread = store.inbox.contains { $0.project == project.id && !$0.read }
                row(project.name, symbol: "folder", on: false, dot: unread) { nav.deliver = .project(project.id, folder: nil) }
                    .contextMenu { DeliverProjectMenu(project: project) }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .onMove { store.moveProjects(from: $0, to: $1) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(maxHeight: .infinity)
    }

    // MARK: Folder tree (a project open)

    private func tree(_ project: Deliver.Project) -> some View {
        let folders = store.content(project.id).folders
        let current: UUID? = if case .project(_, let folder) = nav.deliver { folder } else { nil }
        // The folder shown is always unfolded down to.
        let path = Set(store.folderPath(current, in: project.id).map(\.id))
        let rootOpen = !toggled.contains(project.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                treeRow(id: project.id, title: String(localized: "Assets"), symbol: "photo.on.rectangle", depth: 0, children: folders.contains { $0.parent == nil },
                        open: rootOpen, on: nav.deliver == .project(project.id, folder: nil)) { nav.deliver = .project(project.id, folder: nil) }
                if rootOpen {
                    ForEach(visible(folders, parent: nil, depth: 1, path: path), id: \.folder.id) { item in
                        let folder = item.folder
                        treeRow(id: folder.id, title: folder.name, symbol: "folder", depth: item.depth, children: folders.contains { $0.parent == folder.id },
                                open: open(folder.id, path: path), on: current == folder.id) { nav.deliver = .project(project.id, folder: folder.id) }
                            .dropDestination(for: String.self) { ids, _ in
                                for id in ids.compactMap(UUID.init(uuidString:)) where store.find(id)?.project == project.id { store.move(asset: id, to: folder.id) }
                                return true
                            }
                            .contextMenu { Button("Share Folder…") { actions.sharing = .folder(folder.id, project: project.id) } }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func open(_ folder: UUID, path: Set<UUID>) -> Bool { toggled.contains(folder) != path.contains(folder) }

    /// The folders under `parent`, by name, each followed by its own when unfolded.
    private func visible(_ folders: [Deliver.Folder], parent: UUID?, depth: Int, path: Set<UUID>) -> [(folder: Deliver.Folder, depth: Int)] {
        folders.filter { $0.parent == parent }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .flatMap { folder in [(folder, depth)] + (open(folder.id, path: path) ? visible(folders, parent: folder.id, depth: depth + 1, path: path) : []) }
    }

    /// A tree row: its fold chevron, symbol and name; a "⋯" while hovered.
    private func treeRow(id: UUID, title: String, symbol: String, depth: Int, children: Bool, open: Bool, on: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Button { if toggled.contains(id) { toggled.remove(id) } else { toggled.insert(id) } } label: {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                    .frame(width: 12, height: 20).contentShape(.rect)
            }
            .buttonStyle(.plain).foregroundStyle(Design.Studio.textQuiet)
            .opacity(children ? 1 : 0).disabled(!children)
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 16).foregroundStyle(on ? Design.Studio.text : Design.Studio.textQuiet)
            Text(verbatim: title).font(Design.Studio.body).foregroundStyle(Design.Studio.text).lineLimit(1)
            Spacer(minLength: 4)
            if depth > 0, hovered == id || on, let project = openProject {
                DeliverMoreMenu { Button("Share Folder…") { actions.sharing = .folder(id, project: project.id) } }
            }
        }
        .padding(.leading, CGFloat(depth) * 14 + 2)
        .padding(.trailing, 4)
        .frame(height: 28)
        .background(on ? Design.Studio.raised : .clear, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
        .contentShape(.rect)
        .onTapGesture(perform: action)
        .onHover { inside in if inside { hovered = id } else if hovered == id { hovered = nil } }
    }

    // MARK: Places (browse, inbox, people, tools)

    @ViewBuilder private var places: some View {
        // Browse (§13.16): one row; the places (this Mac, the review servers, the host Mac) are in the browser's own sidebar.
        HStack(spacing: 0) {
            row(String(localized: "Browse"), symbol: "externaldrive.connected.to.line.below", on: browsing) { if !browsing { nav.deliver = .browse(.local) } }
            if let main = ReviewPublish.shared.hosts.first(where: { $0.kind == .nas && $0.role != "backup" }) {
                Button { inviting = main } label: { Image(systemName: "person.badge.plus").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(Design.Studio.textQuiet).help("Invite a Teammate…").padding(.leading, 6)
            }
            if hasServer {
                Button { settingUp = true } label: { Image(systemName: "plus").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(Design.Studio.textQuiet).help("Set Up Server…").padding(.horizontal, 6)
            }
        }
        row(String(localized: "Inbox"), symbol: "tray", on: nav.deliver == .inbox, count: store.unread) { nav.deliver = nav.deliver == .inbox ? .projects : .inbox }
        views
        // People (accounts plan §5): the main server's team, once there is a main.
        if DeliverPeople.main() != nil {
            row(DeliverPeople.title, symbol: "person.2", on: nav.deliver == .people, dot: DeliverPeople.shared.pending > 0) { nav.deliver = .people }
        }
        if !hasServer {
            row(String(localized: "Set Up Server…"), symbol: "externaldrive.badge.plus", on: false) { settingUp = true }
        }
        row(String(localized: PluckTool.deliveryCheck.name), symbol: PluckTool.deliveryCheck.symbol, on: nav.deliver == .deliveryCheck) {
            nav.deliver = .deliveryCheck
        }
        // Archive Project shows once that tool exists (hidden, not greyed, until then).
        if let archive = deliverArchiveTool() {
            row(String(localized: archive.name), symbol: archive.symbol, on: nav.deliver == .archiveProject) { nav.open(archive) }
        }
    }

    // MARK: Views (workflow plan 4): the built-ins, then the owner's; each with its count.

    @ViewBuilder private var views: some View {
        HStack {
            Text("Views").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            Spacer()
            Button { newView = .init(name: "", projects: nav.deliver.project.map { [$0] }) } label: { Image(systemName: "plus").font(.system(size: 12)) }
                .buttonStyle(.plain).foregroundStyle(Design.Studio.textQuiet).help("New View…")
        }
        .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
        ForEach(store.views) { view in
            let symbol = view.id == Deliver.mineView ? "person.crop.circle" : view.id == Deliver.overdueView ? "exclamationmark.circle" : "line.3.horizontal.decrease.circle"
            row(view.name, symbol: symbol, on: nav.deliver == .view(view.id), dot: view.id == Deliver.overdueView && !store.assets(in: view).isEmpty,
                count: store.assets(in: view).count) { nav.deliver = .view(view.id) }
        }
    }

    // MARK: Share links (a project open)

    private func shareLinks(_ project: Deliver.Project) -> some View {
        let links = Self.links(of: project.id, store: store, selection: nav.deliver)
        let all = store.links.filter { $0.project == project.id }.count
        return VStack(alignment: .leading, spacing: 2) {
            Rectangle().fill(Design.Studio.line).frame(height: 1).padding(.vertical, 8)
            HStack {
                Text("Share Links").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                Spacer()
                Button { actions.sharing = .project(project.id) } label: { Image(systemName: "plus").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(Design.Studio.textQuiet).help("Share Project…")
            }
            .padding(.horizontal, 8).padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 2) {
                    linkRow(Text("All Share Links (\(all))"), thumb: AnyView(linkTile("list.bullet")), on: nav.deliver == .links(project.id, link: nil) && ShareBuilder.shared.session == nil) {
                        ShareBuilder.shared.leave { nav.deliver = .links(project.id, link: nil) }
                    }
                    // (The same title as everywhere else: the link's own, cut at the end only when it must be.)
                    ForEach(links) { link in
                        linkRow(Text(verbatim: link.title), thumb: thumb(link.scope), on: ShareBuilder.shared.session?.linkID == link.id,
                                count: server.viewers(link: link.id)) {
                            ShareBuilder.shared.open(link.id, nav: nav)
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What a link shares, small: the asset's poster, or a folder.
    private func thumb(_ scope: Deliver.Scope) -> AnyView {
        switch scope {
        case .asset(let id, _): AnyView(DeliverPoster(asset: store.find(id)?.asset))
        case .assets(let ids, _): AnyView(DeliverPoster(asset: ids.first.flatMap { store.find($0)?.asset }))
        case .project, .folder: AnyView(linkTile("folder.fill"))
        }
    }

    private func linkTile(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Design.Studio.textQuiet)
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Design.Studio.raised)
    }

    private func linkRow(_ title: Text, thumb: AnyView, on: Bool, count: Int = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                thumb.frame(width: 48, height: 28).clipShape(.rect(cornerRadius: 4, style: .continuous))
                title.font(Design.Studio.body).foregroundStyle(Design.Studio.text).lineLimit(2)
                Spacer(minLength: 4)
                if count > 0 {
                    HStack(spacing: 3) { Image(systemName: "eye").font(.system(size: 9)); Text(verbatim: "\(count)") }
                        .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 38)
            .background(on ? Design.Studio.raised : .clear, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// A folder whose new renders are offered as new versions (§13.4).
    static func watch(_ project: UUID) {
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

// MARK: - Projects

/// All projects: the title row (People, New Project, more), the recent ones as a row of wide cards, then every project as
/// a big card (its cover or a soft wash, the name on it) or a list row.
struct DeliverProjects: View {
    @Bindable var nav: StudioNavigator
    @State private var store = DeliverStore.shared
    @State private var actions = DeliverProjectActions.shared
    @State private var settingUp = false
    @AppStorage("deliverProjectsList") private var list = false
    /// "custom" (the sidebar's order), "name" or "recent".
    @AppStorage("deliverProjectsSort") private var sort = "custom"

    private var shown: [Deliver.Project] { store.projects.filter { $0.hidden != true } }

    private var projects: [Deliver.Project] {
        switch sort {
        case "name": shown.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case "recent": shown.sorted { updated($0) > updated($1) }
        default: shown
        }
    }

    /// Its last change: made, renamed, an asset added, a comment.
    private func updated(_ project: Deliver.Project) -> Date {
        ([project.created, project.at, store.lastComment[project.id]].compactMap { $0 } + store.content(project.id).assets.map(\.created)).max() ?? project.created
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.bottom, 22)
                if shown.count > 1 {
                    Text("Recent").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet).padding(.bottom, 10)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                        ForEach(shown.sorted { updated($0) > updated($1) }.prefix(4)) { pill($0) }
                    }
                    Rectangle().fill(Design.Studio.line).frame(height: 1).padding(.vertical, 20)
                }
                filterBar.padding(.bottom, 16)
                if shown.isEmpty {
                    StudioEmptyState(symbol: "folder.badge.plus", title: "No projects yet", prominent: true, button: "New Project") { actions.newProject() }
                        .frame(minHeight: 280)
                } else if list {
                    VStack(spacing: 4) { ForEach(projects) { listRow($0) } }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 250), spacing: 14)], alignment: .leading, spacing: 14) {
                        ForEach(projects) { card($0) }
                    }
                }
                if !ReviewPublish.shared.hosts.contains(where: { $0.kind == .nas }) {
                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive.badge.plus").font(.system(size: 22)).foregroundStyle(Design.Studio.textQuiet)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Your own review server").font(Design.Studio.body).foregroundStyle(Design.Studio.text)
                            Text("Links stay up when this Mac sleeps.").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                        }
                        Spacer()
                        Button("Set Up Server…") { settingUp = true }.buttonStyle(StudioFlatButtonStyle())
                    }
                    .padding(14)
                    .background(Design.Studio.raised, in: .rect(cornerRadius: 10, style: .continuous))
                    .padding(.top, 24)
                }
            }
            .padding(24)
        }
        .sheet(isPresented: $settingUp) { DeliverServerChooser() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Projects").font(Design.Studio.pageTitle).foregroundStyle(Design.Studio.text)
            Spacer()
            if DeliverPeople.main() != nil {
                Button { nav.deliver = .people } label: { Image(systemName: "person.2.fill").font(.system(size: 11)) }
                    .buttonStyle(StudioFlatButtonStyle()).help(Text(verbatim: DeliverPeople.title))
            }
            Button { actions.newProject() } label: { Label("New Project", systemImage: "plus") }
                .buttonStyle(StudioFlatButtonStyle(prominent: true))
            DeliverMoreMenu {
                Button("Browse") { nav.deliver = .browse(.local) }
                Button("Set Up Server…") { settingUp = true }
                Button(String(localized: PluckTool.deliveryCheck.name)) { nav.deliver = .deliveryCheck }
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 16) {
            StudioSegmented(options: [(false, "Grid"), (true, "List")], selection: $list, symbols: ["square.grid.2x2", "list.bullet"])
            Menu {
                Picker(selection: $sort) {
                    Text("Custom").tag("custom")
                    Text("Name").tag("name")
                    Text("Recent").tag("recent")
                } label: { EmptyView() }.pickerStyle(.inline)
            } label: {
                DeliverToolLabel(symbol: "line.3.horizontal.decrease", title: "Sorted by",
                                 value: sort == "name" ? String(localized: "Name") : sort == "recent" ? String(localized: "Recent") : String(localized: "Custom"))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Spacer()
        }
    }

    private func pill(_ project: Deliver.Project) -> some View {
        Button { nav.deliver = .project(project.id, folder: nil) } label: {
            HStack(spacing: 12) {
                DeliverProjectCover(project: project).frame(width: 44, height: 44).clipShape(.rect(cornerRadius: 6, style: .continuous))
                Text(verbatim: project.name).font(Design.Studio.body.weight(.medium)).foregroundStyle(Design.Studio.text).lineLimit(1)
                Spacer(minLength: 34)
            }
            .padding(8)
            .background(Design.Studio.raised, in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) { DeliverMoreMenu { DeliverProjectMenu(project: project) }.padding(.trailing, 10) }
        .contextMenu { DeliverProjectMenu(project: project) }
    }

    private func card(_ project: Deliver.Project) -> some View {
        let unread = store.inbox.contains { $0.project == project.id && !$0.read }
        return VStack(alignment: .leading, spacing: 0) {
            Button { nav.deliver = .project(project.id, folder: nil) } label: {
                DeliverProjectCover(project: project)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: project.name).font(Design.Studio.sectionTitle).foregroundStyle(.white).lineLimit(1)
                            Text("\(store.content(project.id).assets.count) assets").font(Design.Studio.hint).foregroundStyle(.white.opacity(0.7))
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom))
                    }
                    .clipShape(.rect(cornerRadius: 7, style: .continuous))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .overlay(alignment: .topTrailing) {
                // The project's comments and approvals, in the inbox.
                Button { nav.deliver = .inbox } label: {
                    Image(systemName: unread ? "bell.badge.fill" : "bell").font(.system(size: 10))
                        .foregroundStyle(unread ? Design.Brand.pink : .white)
                        .frame(width: 22, height: 22).background(.black.opacity(0.35), in: .rect(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain).padding(8).help("Inbox")
            }
            HStack(spacing: 4) {
                Text("Updated \(updated(project), format: .relative(presentation: .named))").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                Spacer(minLength: 4)
                DeliverMoreMenu { DeliverProjectMenu(project: project) }
            }
            .padding(.leading, 8).padding(.trailing, 2)
            .frame(height: 30)
        }
        .padding(4)
        .background(Design.Studio.raised, in: .rect(cornerRadius: 10, style: .continuous))
        .contextMenu { DeliverProjectMenu(project: project) }
    }

    private func listRow(_ project: Deliver.Project) -> some View {
        Button { nav.deliver = .project(project.id, folder: nil) } label: {
            HStack(spacing: 12) {
                DeliverProjectCover(project: project).frame(width: 56, height: 32).clipShape(.rect(cornerRadius: 4, style: .continuous))
                Text(verbatim: project.name).font(Design.Studio.body).foregroundStyle(Design.Studio.text).lineLimit(1)
                Spacer()
                Text("\(store.content(project.id).assets.count) assets").frame(width: 80, alignment: .leading)
                Text("Updated \(updated(project), format: .relative(presentation: .named))").frame(width: 150, alignment: .leading)
                Spacer().frame(width: 24)
            }
            .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            .padding(.horizontal, 8)
            .frame(height: 44)
            .background(Design.Studio.raised, in: .rect(cornerRadius: 8, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) { DeliverMoreMenu { DeliverProjectMenu(project: project) }.padding(.trailing, 8) }
        .contextMenu { DeliverProjectMenu(project: project) }
    }
}

/// A header tool as on the boards: its symbol, its name, then the value in grey ("Sorted by  Name").
struct DeliverToolLabel: View {
    let symbol: String
    let title: LocalizedStringKey
    var value: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Design.Studio.textQuiet)
            Text(title).foregroundStyle(Design.Studio.text)
            if let value { Text(verbatim: value).foregroundStyle(Design.Studio.textQuiet) }
        }
        .font(Design.Studio.body)
        .frame(height: 28)
        .contentShape(.rect)
    }
}

/// An asset's poster (its current version's), or its kind's symbol.
struct DeliverPoster: View {
    let asset: Deliver.Asset?
    var body: some View {
        ZStack {
            Design.Studio.raised
            if let file = Self.file(asset), let image = NSImage(contentsOf: file) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: asset.map { DeliverPoster.symbol($0.kind) } ?? "film").font(.system(size: 22)).foregroundStyle(Design.Studio.textFaint)
            }
        }
        .clipped()
    }

    /// The poster's file (the picture itself for an image), if there's an asset.
    @MainActor static func file(_ asset: Deliver.Asset?) -> URL? {
        guard let asset else { return nil }
        let folder = DeliverStore.shared.copies(asset.current.id)
        return folder.appendingPathComponent(asset.kind == .image ? "image.jpg" : "poster.jpg")
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

    /// All Share Links: a table (title, what it shares, people, opened, last viewed, expiry, on/off, Edit / Duplicate / Copy);
    /// a row's activity under it when chosen.
    var body: some View {
        let links = DeliverLinkRow.rows(store.links, project: project)
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(verbatim: store.project(project)?.name ?? "").font(Design.Studio.pageTitle).foregroundStyle(Design.Studio.text)
                    Spacer()
                    Button("New Link") { ShareBuilder.shared.new(.project(project), nav: nav) }.buttonStyle(StudioFlatButtonStyle(prominent: true))
                }
                .padding(.bottom, 12)
                if links.isEmpty {
                    Text("No links yet").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                } else {
                    DeliverLinkRow.header
                    ForEach(links) { link in
                        VStack(spacing: 0) {
                            DeliverLinkRow(link: link, viewers: server.viewers(link: link.id), expanded: open == link.id, nav: nav)
                                .onTapGesture { open = open == link.id ? nil : link.id }
                            if open == link.id { DeliverActivityFeed(link: link).padding(.vertical, 6) }
                        }
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
        .background(Design.Studio.raised, in: .rect(cornerRadius: 10, style: .continuous))
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
        case "approved": return (entry.detail?.what ?? entry.detail?.decision) == "changes" ? String(localized: "asked for changes on \(name)") : String(localized: "approved \(name)")
        default: return entry.kind
        }
    }
}

/// A row of All Share Links: title, what it shares, people, opened, last viewed, expiry, on (pause) or its state, viewers
/// now; Edit (the Share Builder), Duplicate, Copy and a menu (QR code, email, notifications, send an update, turn off).
struct DeliverLinkRow: View {
    let link: Deliver.ShareLink
    var viewers = 0
    var expanded = false
    var nav: StudioNavigator = .shared
    @State private var store = DeliverStore.shared
    @State private var qr = false
    @State private var reopening = false
    @State private var deleting = false
    @State private var renewing = false

    /// The table's rows: a project's links, live ones first, newest first.
    static func rows(_ links: [Deliver.ShareLink], project: UUID) -> [Deliver.ShareLink] {
        links.filter { $0.project == project }.enumerated()
            .sorted { ($0.element.isLive ? 0 : 1, -$0.offset) < ($1.element.isLive ? 0 : 1, -$1.offset) }.map(\.element)
    }

    /// What a link shares, in a word: never the project's name again (every link here is that project's).
    @MainActor static func shares(_ link: Deliver.ShareLink, store: DeliverStore) -> String {
        switch link.scope {
        case .project: String(localized: "Whole project")
        case .folder, .asset: store.name(link.scope)
        case .assets(let ids, _): String(localized: "\(ids.count) assets")
        }
    }

    private static let widths: (shares: CGFloat, number: CGFloat, date: CGFloat, on: CGFloat, actions: CGFloat) = (130, 54, 96, 70, 196)

    static var header: some View {
        HStack(spacing: 10) {
            Text("Title").frame(maxWidth: .infinity, alignment: .leading)
            Text("Shares").frame(width: widths.shares, alignment: .leading)
            Text("People").frame(width: widths.number, alignment: .trailing)
            Text("Opened").frame(width: widths.number, alignment: .trailing)
            Text("Last viewed").frame(width: widths.date, alignment: .leading)
            Text("Expires").frame(width: widths.date, alignment: .leading)
            Text("On").frame(width: widths.on, alignment: .leading)
            Color.clear.frame(width: widths.actions, height: 1)
        }
        .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
        .padding(.horizontal, 12).frame(height: 24)
    }

    /// With a NAS or always-on Mac, a link no host holds yet: it's being put on one, or that didn't work (Publish).
    private var unplaced: (host: String, failed: Bool)? {
        let publish = ReviewPublish.shared
        guard link.isLive, store.key(link.id) != nil, DeliverLink.shared.neverServe else { return nil }
        if let data = DeliverSync.shared.dataHost {
            // The data NAS gets it with the next sync round (its changes still waiting while the room has no host).
            return DeliverServer.shared.rooms[link.roomID] == "nohost" && DeliverSync.shared.waiting > 0 ? (data.name, DeliverSync.shared.problem != nil) : nil
        }
        guard !publish.isOnHost(link), let host = publish.placeHost else { return nil }
        return (host.name, !publish.placing.contains(link.project) && publish.notPlaced[link.project] != nil)
    }

    /// The helper's room state: an always-on host serves it (standby here), this Mac does, or (with a NAS, which this
    /// Mac never stands in for) nobody until the NAS is back.
    private var served: String? {
        if let unplaced { return unplaced.failed ? String(localized: "Not on \(unplaced.host) yet") : String(localized: "Putting it on \(unplaced.host)…") }
        switch DeliverServer.shared.rooms[link.roomID] {
        case "standby":
            let host = ReviewPublish.shared.publications.first { $0.scope.project == link.project }.flatMap { ReviewPublish.shared.host($0.host) }
            return host.map { String(localized: "Served by \($0.name)") } ?? String(localized: "Served by an always-on host")
        case "active", "registered": return String(localized: "Served by this Mac")
        case "nohost": return String(localized: "Waiting for the NAS: clients can’t watch until it’s online")
        default: return nil
        }
    }

    var body: some View {
        let _ = store.activityChanged
        let views = store.views(link.id)
        let w = Self.widths
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: link.recipient != nil ? "person.crop.circle" : link.mode == .review ? "text.bubble" : "play.rectangle")
                        .font(.system(size: 11)).foregroundStyle(Design.Studio.textQuiet).frame(width: 14)
                    Text(verbatim: link.title).font(Design.Studio.body).foregroundStyle(link.isLive ? Design.Studio.text : Design.Studio.textQuiet)
                        .lineLimit(1).truncationMode(.tail)
                    if link.isTeam { StudioChip(text: Text("Team")) }
                    if link.watermark != nil { Image(systemName: "drop.halffull").font(.system(size: 10)).foregroundStyle(Design.Studio.textQuiet).help("Watermarked") }
                    if link.muted == true { Image(systemName: "bell.slash").font(.system(size: 10)).foregroundStyle(Design.Studio.textQuiet) }
                    if viewers > 0 { StudioChip(text: Text(verbatim: "\(viewers)"), symbol: "eye") }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(Text(verbatim: [link.title, link.isLive ? served : nil].compactMap { $0 }.joined(separator: "\n")))
                Group {
                    Text(verbatim: Self.shares(link, store: store)).frame(width: w.shares, alignment: .leading)
                    Text(verbatim: views.people > 0 ? "\(views.people)" : "–").frame(width: w.number, alignment: .trailing)
                    Text(verbatim: views.opened > 0 ? "\(views.opened)" : "–").frame(width: w.number, alignment: .trailing)
                    Text(verbatim: link.lastOpened?.formatted(.relative(presentation: .named)) ?? "–").frame(width: w.date, alignment: .leading)
                    Text(verbatim: link.expires?.formatted(date: .abbreviated, time: .omitted) ?? String(localized: "Never")).frame(width: w.date, alignment: .leading)
                }
                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                on.frame(width: w.on, alignment: .leading)
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    if link.isLive, link.revoked == nil {
                        if unplaced?.failed == true {
                            Button("Publish") {
                                if DeliverSync.shared.dataHost != nil { DeliverNASAlert.shared.retry() } else { Task { await ReviewPublish.shared.placeLinks(retry: true) } }
                            }
                            .buttonStyle(StudioFlatButtonStyle(prominent: true))
                        }
                        if !store.isForeign(link) { Button("Edit") { ShareBuilder.shared.open(link.id, nav: nav) }.buttonStyle(StudioFlatButtonStyle()) }
                    }
                    Button { _ = try? store.duplicate(link.id) } label: { Image(systemName: "plus.square.on.square") }.buttonStyle(StudioFlatButtonStyle()).help("Duplicate")
                    if link.isLive, store.key(link.id) == nil, let device = link.madeOn, device != Host.current().localizedName {
                        StudioChip(text: Text("Made on \(device)"))
                    } else if link.isLive, let url = DeliverServer.shared.shareURL(link) {
                        Button { DeliverLinkShare.copy(url) } label: { Image(systemName: "link") }.buttonStyle(StudioFlatButtonStyle()).help("Copy Link")
                    }
                    if link.isLive, link.revoked == nil { menu }
                }
                .frame(width: w.actions)
            }
            if link.isLive, store.key(link.id) != nil, DeliverServer.shared.shareURL(link) == nil || DeliverServer.shared.isTaken(link) {
                DeliverLinkPending(link: link)
            }
            if qr, let url = DeliverServer.shared.shareURL(link), let image = DeliverLinkShare.qr(url) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 150, height: 150).padding(8).background(.white, in: .rect(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Design.Studio.raised, in: .rect(cornerRadius: 10, style: .continuous))
        .overlay { if expanded { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Design.Studio.textFaint, lineWidth: 1) } }
        .contentShape(.rect)
        .sheet(isPresented: $reopening) {
            DeliverDeadlineSheet(title: "Reopen", initial: link.deadline) { DeliverDeadlines.shared.reopen(link.id, deadline: $0) }
        }
        .confirmationDialog("Make a new, shorter link?", isPresented: $renewing) {
            Button("Make a New Link") { DeliverLink.shared.renew(link.id) }
        } message: { Text("The old link stops working. Send the new one to everyone who should still see this.") }
        .confirmationDialog("Delete this link and its data?", isPresented: $deleting) {
            Button("Delete", role: .destructive) { let id = link.id; Task { await DeliverLink.shared.deleteLink(id) } }
        } message: { Text("The link stops working. Its activity log and what pluck.tools keeps for it are deleted. Comments stay.") }
    }

    /// On (a switch: off pauses it, so it can come back), or why it's not on.
    @ViewBuilder private var on: some View {
        if link.revoked != nil {
            StudioChip(text: Text("Off"))
        } else if !link.isLive {
            StudioChip(text: Text("Expired"))
        } else if DeliverDeadlines.shared.isClosed(link) {
            Button("Reopen…") { reopening = true }.buttonStyle(StudioFlatButtonStyle()).help("Closed: feedback deadline")
        } else {
            Toggle("On", isOn: Binding(get: { !link.isPaused }, set: { on in store.updateLink(link.id) { $0.paused = on ? nil : true } }))
                .toggleStyle(StudioSwitchStyle()).help(link.isPaused ? "Paused" : "On")
        }
    }

    private var menu: some View {
        Menu {
            if store.code(link.id) == nil, store.key(link.id) != nil, ReviewPublish.shared.linkLevel == 3 { Button("Make a New Link…") { renewing = true } }
            Button(qr ? "Hide QR Code" : "QR Code") { qr.toggle() }
            if let url = DeliverServer.shared.shareURL(link) { Button("Email…") { DeliverLinkShare.email(link, url: url) } }
            Button("Send Update…") { DeliverLinkRow.sendUpdate(link) }
            Button("Feedback Deadline…") { reopening = true }
            Divider()
            Toggle("Tell Me When It’s Opened", isOn: Binding(get: { link.notifyOpened == true }, set: { value in store.updateLink(link.id) { $0.notifyOpened = value ? true : nil } }))
            Toggle("Mute Notifications", isOn: Binding(get: { link.muted == true }, set: { value in
                store.updateLink(link.id) { $0.muted = value ? true : nil }
                Task { await DeliverMail.shared.mute(link.id, value) }   // (and this Mac's person's emails about it)
            }))
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
        if let url = server.shareURL(link) { lines += ["", url] }
        return lines.joined(separator: "\n")
    }
}

/// The inbox, as a panel over the projects: All or Unread, Mark All as Read, then by day who commented, replied or
/// approved what, with the asset's poster. (Uploads that came in during an outage first.)
struct DeliverInbox: View {
    @Bindable var nav: StudioNavigator
    @State private var store = DeliverStore.shared
    @State private var unreadOnly = false

    var body: some View {
        let items = store.inbox.filter { !unreadOnly || !$0.read }.sorted { $0.created > $1.created }
        let days = Dictionary(grouping: items) { Calendar.current.startOfDay(for: $0.created) }.sorted { $0.key > $1.key }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Inbox").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
                Spacer()
                Button { nav.deliver = .projects } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22).contentShape(.rect) }
                    .buttonStyle(.plain).foregroundStyle(Design.Studio.textQuiet).help("Close").keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).frame(height: 48)
            HStack(spacing: 16) {
                tab("All", on: !unreadOnly) { unreadOnly = false }
                tab("Unread", on: unreadOnly) { unreadOnly = true }
                Spacer()
                Button("Mark All as Read") { for item in store.inbox where !item.read { store.markRead(item.id) } }
                    .buttonStyle(.plain).font(Design.Studio.body).foregroundStyle(store.unread > 0 ? Design.Studio.text : Design.Studio.textFaint)
                    .disabled(store.unread == 0)
            }
            .padding(.horizontal, 16).frame(height: 32)
            Rectangle().fill(Design.Studio.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DeliverOutageInbox(nav: nav).padding(.horizontal, 16).padding(.top, 12)
                    if items.isEmpty { Text("Nothing new").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet).padding(16) }
                    ForEach(days, id: \.key) { day in
                        Text(verbatim: Self.day(day.key)).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 2)
                        ForEach(day.value) { row($0) }
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .frame(width: 400)
        .frame(maxHeight: .infinity)
        .background(Design.Studio.raised)
        .overlay(alignment: .trailing) { Rectangle().fill(Design.Studio.line).frame(width: 1) }
        .shadow(color: .black.opacity(0.45), radius: 20, x: 8)
    }

    static func day(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return String(localized: "Today") }
        if Calendar.current.isDateInYesterday(date) { return String(localized: "Yesterday") }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// "Client commented on Hero_30s", "Producer approved Hero_30s"…
    @MainActor static func headline(_ item: Deliver.InboxItem, file: String) -> String {
        switch item.kind {
        case "approval": item.summary == "approved" ? String(localized: "\(item.author) approved \(file)") : String(localized: "\(item.author) asked for changes on \(file)")
        case "reply": String(localized: "\(item.author) replied on \(file)")
        default: String(localized: "\(item.author) commented on \(file)")
        }
    }

    private func tab(_ title: LocalizedStringKey, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(Design.Studio.body).foregroundStyle(on ? Design.Studio.text : Design.Studio.textQuiet) }.buttonStyle(.plain)
    }

    private func row(_ item: Deliver.InboxItem) -> some View {
        let asset = store.find(item.asset)?.asset
        return Button {
            store.markRead(item.id)
            nav.showReview(asset: item.asset, version: item.version, comment: item.kind == "approval" ? nil : item.id)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(verbatim: String(item.author.prefix(1)).uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24).background(Design.Brand.deep, in: .circle)
                    .overlay(alignment: .topLeading) { if !item.read { Circle().fill(Design.Brand.pink).frame(width: 7, height: 7).offset(x: -3, y: -3) } }
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: Self.headline(item, file: asset?.name ?? "")).font(Design.Studio.body).foregroundStyle(Design.Studio.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if item.kind != "approval", !item.summary.isEmpty {
                        Text(verbatim: item.summary).font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet).lineLimit(2)
                    }
                    Text(verbatim: "\(store.project(item.project)?.name ?? "") • \(item.created.formatted(date: .omitted, time: .shortened))")
                        .font(Design.Studio.hint).foregroundStyle(Design.Studio.textFaint)
                }
                Spacer(minLength: 8)
                DeliverPoster(asset: asset).frame(width: 60, height: 34).clipShape(.rect(cornerRadius: 4, style: .continuous))
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
