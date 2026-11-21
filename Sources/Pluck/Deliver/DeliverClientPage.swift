import CryptoKit
import SwiftUI

/// Client pages (4.0.7): one stable address per client listing that client's live links (title, last update, approvals).
/// A client page is a share link of its own (its own code, room, password and expiry rules, held and served like any link)
/// whose scope is an empty pick of files, so a server that doesn't know client pages shows nothing through it. The
/// addresses of the listed links travel in a box sealed with a key only the page's own link key gives
/// (HKDF "portal"): the NAS host holds the box but can't open it, as it never holds link codes. Both servers send
/// `ready.portal = {links: [{id, title, updated, assets, approved, changes}], box}` (host.rs `portal`).
@MainActor
enum DeliverClientPage {
    /// The links a client page may list: live, in its projects, for clients (never team, personal or other client pages).
    static func members(_ page: Deliver.ShareLink, store: DeliverStore, now: Date = .now) -> [Deliver.ShareLink] {
        guard let portal = page.portal else { return [] }
        return store.links.filter { link in
            portal.projects.contains(link.project) && link.isLive && !link.isPaused && !link.isTeam && (link.recipient ?? "").isEmpty
                && !link.isPortal && (DeliverDeadlines.effective(link, store: store).map { $0 > now } ?? true)
        }
    }

    /// One listed link: its title, its newest version's date (else when it was made) and its files' approvals.
    static func row(_ link: Deliver.ShareLink, store: DeliverStore) -> [String: Any] {
        var count = 0, approved = 0, changes = 0, updated = DeliverServer.date(link.created)
        for asset in store.content(link.project).assets where DeliverServer.inScope(asset, link, store: store) {
            count += 1
            if asset.status == .approved { approved += 1 } else if asset.status == .needsChanges { changes += 1 }
            for version in asset.versions { updated = max(updated, DeliverServer.date(version.added)) }
        }
        return ["id": link.id.uuidString, "title": link.title, "updated": updated, "assets": count, "approved": approved, "changes": changes]
    }

    /// The addresses this Mac can give (id → URL): a link made on another Mac (its key is there) is left out.
    static func addresses(_ page: Deliver.ShareLink, store: DeliverStore, url: (Deliver.ShareLink) -> String?) -> [String: String] {
        members(page, store: store).reduce(into: [:]) { all, link in all[link.id.uuidString] = url(link) }
    }

    /// `ready.portal` from this Mac: the rows of the links in the box, newest first (as the host sorts them).
    static func wire(_ page: Deliver.ShareLink, store: DeliverStore, url: (Deliver.ShareLink) -> String?) -> [String: Any] {
        let urls = addresses(page, store: store, url: url)
        let rows = members(page, store: store).filter { urls[$0.id.uuidString] != nil }.map { row($0, store: store) }.sorted { a, b in
            let (ua, ub) = (a["updated"] as? String ?? "", b["updated"] as? String ?? "")
            let (ta, tb) = (a["title"] as? String ?? "", b["title"] as? String ?? "")
            return ua != ub ? ua > ub : ta != tb ? ta < tb : (a["id"] as? String ?? "") < (b["id"] as? String ?? "")
        }
        return ["links": rows, "box": store.key(page.id).flatMap { seal(urls, key: $0) } ?? NSNull()]
    }

    /// What a host keeps of a client page (its manifest link's `portal`): without the page's key, only the projects (the
    /// host keeps its box).
    static func manifest(_ page: Deliver.ShareLink, store: DeliverStore, url: (Deliver.ShareLink) -> String? = DeliverServer.shared.shareURL) -> [String: Any]? {
        guard let portal = page.portal else { return nil }
        var wire: [String: Any] = ["projects": portal.projects.map(\.uuidString)]
        if let key = store.key(page.id) {
            let urls = addresses(page, store: store, url: url)
            wire["links"] = urls.keys.sorted()
            wire["box"] = seal(urls, key: key) ?? NSNull()
        }
        return wire
    }

    // MARK: - The sealed box

    static func boxKey(_ linkKey: Data) -> SymmetricKey { SymmetricKey(data: DeliverKeys.derive(linkKey, "portal", 32)) }

    /// AES-GCM over the id → URL JSON: base64url(nonce ‖ ciphertext ‖ tag), as WebCrypto opens it (review page portal.ts).
    static func seal(_ urls: [String: String], key: Data, nonce: AES.GCM.Nonce = AES.GCM.Nonce()) -> String? {
        guard let json = try? JSONSerialization.data(withJSONObject: urls, options: [.sortedKeys]),
              let box = try? AES.GCM.seal(json, using: boxKey(key), nonce: nonce).combined else { return nil }
        return DeliverKeys.base64url(box)
    }

    /// Tests: what a browser holding the page's key reads.
    static func open(_ box: String, key: Data) -> [String: String]? {
        guard let data = DeliverKeys.data(base64url: box), let sealed = try? AES.GCM.SealedBox(combined: data),
              let json = try? AES.GCM.open(sealed, using: boxKey(key)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: json)) as? [String: String]
    }

    // MARK: - Keeping the hosts' box current

    /// A client page whose listed addresses changed (a new link, one turned off, a new code) is stamped again, so its new
    /// box reaches the hosts like any changed link. Runs after link changes.
    static func refresh(store: DeliverStore = .shared, url: (Deliver.ShareLink) -> String? = DeliverServer.shared.shareURL) {
        for page in store.links where page.isPortal && page.isLive && store.key(page.id) != nil {
            let urls = addresses(page, store: store, url: url)
            let seal = DeliverKeys.sha256(Data(urls.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n").utf8))
            guard page.portal?.seal != seal else { continue }
            store.updateLink(page.id) { $0.portal?.links = urls.keys.sorted().compactMap(UUID.init(uuidString:)); $0.portal?.seal = seal }
        }
    }

    private static var pending: Task<Void, Never>?
    /// From launch: refresh a moment after links change (and when a room becomes the owner's).
    static func watch(store: DeliverStore = .shared) {
        store.listeners.append { event in
            guard case .linksChanged = event else { return }
            soon()
        }
        soon()
    }
    static func soon() {
        pending?.cancel()
        pending = Task { try? await Task.sleep(for: .seconds(1)); if !Task.isCancelled { refresh() } }
    }

    /// The main server can serve client pages (its hello said `portal: 1`); older ones don't, and no page is offered.
    static var available: Bool { DeliverPeople.main()?.portal == 1 }

    /// A new client page for these projects (off until made: "Client page: off per client until turned on").
    static func make(name: String, projects: [UUID], store: DeliverStore = .shared) throws -> Deliver.ShareLink {
        guard let first = projects.first else { throw Deliver.Failure("invalid") }
        let page = try store.newLink(scope: .assets([], project: first), title: name)
        store.updateLink(page.id) { $0.portal = .init(projects: projects) }
        refresh(store: store)
        return store.link(page.id) ?? page
    }
}

// MARK: - People › Client pages

struct DeliverClientPagesSection: View {
    @State private var store = DeliverStore.shared
    @State private var server = DeliverServer.shared
    @State private var editing: Deliver.ShareLink?
    @State private var making = false
    @State private var copied: UUID?
    @State private var turningOff: Deliver.ShareLink?

    var body: some View {
        let pages = store.links.filter { $0.isPortal && $0.isLive }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        HStack(spacing: 6) {
            Text("Client Pages").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
            Text(verbatim: "\(pages.count)").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
            Spacer()
            Button { making = true } label: { Label("New Client Page…", systemImage: "plus") }.buttonStyle(StudioFlatButtonStyle())
        }
        .padding(.top, 18).padding(.bottom, 4)
        VStack(spacing: 0) {
            ForEach(pages) { page in row(page) }
            if pages.isEmpty {
                Text("One page per client with all their live links").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
            }
        }
        .studioBox()
        .sheet(isPresented: $making) { DeliverClientPageSheet(page: nil) }
        .sheet(item: $editing) { DeliverClientPageSheet(page: $0) }
        .confirmationDialog(Text("Turn off \(turningOff?.title ?? "")?"), isPresented: Binding(get: { turningOff != nil }, set: { if !$0 { turningOff = nil } })) {
            Button("Turn Off", role: .destructive) { if let id = turningOff?.id { store.revoke(id) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Its address stops working. The links on it keep working.") }
    }

    private func row(_ page: Deliver.ShareLink) -> some View {
        let count = DeliverClientPage.members(page, store: store).count, url = server.shareURL(page)
        return HStack(spacing: 10) {
            Image(systemName: "person.crop.rectangle.stack").font(.system(size: 13)).foregroundStyle(Design.Studio.textQuiet)
                .frame(width: 26, height: 26).background(Design.Studio.raised, in: .circle)
            Text(verbatim: page.title).font(Design.Studio.body).foregroundStyle(Design.Studio.text).lineLimit(1)
            StudioChip(text: Text("\(count) links"), symbol: "link")
            Spacer(minLength: 8)
            if let url {
                Button { DeliverLinkShare.copy(url); copied = page.id } label: {
                    Label(copied == page.id ? "Copied" : "Copy Link", systemImage: copied == page.id ? "checkmark" : "doc.on.doc")
                }.settingButton().fixedSize()
            } else {
                Text("Getting the link ready…").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
            }
            Menu {
                Button("Edit…") { editing = page }
                Button("Turn Off…", role: .destructive) { turningOff = page }
            } label: { Image(systemName: "ellipsis").foregroundStyle(Design.Studio.textQuiet).frame(width: 22, height: 22).contentShape(.rect) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 12).frame(height: 44)
    }
}

/// A client page's name and projects.
struct DeliverClientPageSheet: View {
    let page: Deliver.ShareLink?
    @Environment(\.dismiss) private var dismiss
    @State private var store = DeliverStore.shared
    @State private var name = ""
    @State private var picked: [UUID] = []
    @State private var problem: String?

    var body: some View {
        let projects = store.projects.filter { $0.hidden != true }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        VStack(alignment: .leading, spacing: 12) {
            Text(page == nil ? "New Client Page" : "Client Page").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
            VStack(spacing: 0) {
                SettingRow("Client") { TextField(text: $name, prompt: Text(verbatim: "Northwind")) { Text("Client") }.settingField(width: 240) }
            }
            .studioBox()
            Text("Their projects").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(projects) { project in
                        SettingSwitch(text: Text(verbatim: project.name), isOn: Binding(get: { picked.contains(project.id) }, set: { on in
                            if on { picked.append(project.id) } else { picked.removeAll { $0 == project.id } }
                        }))
                    }
                    if projects.isEmpty { Text("No projects yet").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).padding(10) }
                }
            }
            .frame(maxHeight: 280)
            .studioBox()
            Text("Clients see only live client links of these projects: never team or personal links.")
                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).fixedSize(horizontal: false, vertical: true)
            if let problem { Text(verbatim: problem).font(Design.Studio.hint).foregroundStyle(Design.Studio.bad) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(StudioFlatButtonStyle())
                Button(page == nil ? "Create" : "Save") { save() }
                    .buttonStyle(StudioFlatButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || picked.isEmpty)
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 460)
        .background(Design.Studio.panel)
        .onAppear {
            name = page?.title ?? ""
            picked = page?.portal?.projects ?? []
        }
    }

    private func save() {
        if let page {
            store.updateLink(page.id) { $0.title = Deliver.clean(name, limit: DeliverStore.nameLimit); $0.portal?.projects = picked }
            DeliverClientPage.refresh(store: store)
            return dismiss()
        }
        do {
            _ = try DeliverClientPage.make(name: name, projects: picked, store: store)
            dismiss()
        } catch {
            problem = String(localized: "Turn off a link first: \(DeliverStore.liveLinkLimit) are live.")
        }
    }
}
