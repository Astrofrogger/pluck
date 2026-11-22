import SwiftUI
import WebKit

// The Share Builder (Deliver): a link's page as the client will see it, with its settings beside it. Edits stay a draft
// until Update Link, which writes them onto the same link (same id, key and room); the store's linksChanged sends them
// on to the NAS and to open pages (ReviewPublish.sendLinks, DeliverSync, DeliverServer).

// MARK: - Preview manifest

extension DeliverServer {
    /// What the preview page gets (site src/review/preview.ts): the link's settings and lists exactly as a browser gets them,
    /// the project's branding, and each shown version's picture through `pluck-preview:`. Never the link's key, room or
    /// password; internal comments count only on a team link, as on the real page.
    func previewManifest(_ link: Deliver.ShareLink, lang: String? = Bundle.main.preferredLocalizations.first) -> (json: [String: Any], pictures: [String: URL]) {
        let content = store.content(link.project)
        var lists: [String: Any] = ["": (try? list(nil, link)) ?? ["path": [], "folders": [], "assets": []]]
        for folder in content.folders { if let reply = try? list(folder.id.uuidString, link) { lists[folder.id.uuidString] = reply } }
        var pictures: [String: URL] = [:]
        for asset in content.assets where inScope(asset, link) {
            let copies = store.copies(asset.current.id)
            pictures[asset.current.id.uuidString] = copies.appendingPathComponent(asset.kind == .image ? "image.jpg" : asset.kind == .document ? "pages/1.jpg" : "poster.jpg")
        }
        var json: [String: Any] = ["link": Self.linkInfo(link, store: store), "lists": lists,
                                   "images": Dictionary(uniqueKeysWithValues: pictures.keys.map { ($0, "pluck-preview://img/\($0)") }),
                                   "viewer": link.recipient ?? String(localized: "Client")]
        if let branding = store.branding(for: link.project) { json["branding"] = branding.wire }
        if let lang { json["lang"] = lang }
        return (json, pictures)
    }
}

// MARK: - A builder session (one link, or a new one)

@MainActor
@Observable
final class ShareBuilderSession: Identifiable {
    let id = UUID()
    let store: DeliverStore
    /// The server's view of the draft (scope, lists): the app's own one, or the tests' store's.
    let server: DeliverServer
    /// Nil until a new link is made.
    private(set) var linkID: UUID?
    var draft: Deliver.ShareLink
    private(set) var baseline: Deliver.ShareLink
    /// Typed, not saved yet (empty: unchanged).
    var password = ""
    var clearPassword = false
    var phone = false
    var problem: String?
    /// The Deliver view it was opened from: going elsewhere closes it (asking first when there are unsaved changes).
    var origin: Deliver.Selection?

    init(link: Deliver.ShareLink, store: DeliverStore = .shared) {
        self.store = store
        server = store === DeliverStore.shared ? .shared : DeliverServer(store: store)
        linkID = link.id
        draft = link
        baseline = link
    }

    /// A new link: Pluck's defaults or the ones saved with Save as Default, titled after what it shares.
    init(new scope: Deliver.Scope, store: DeliverStore = .shared) {
        self.store = store
        server = store === DeliverStore.shared ? .shared : DeliverServer(store: store)
        var draft = DeliverLinkOptions.draft(scope)
        draft.title = store.name(scope)
        self.draft = draft
        baseline = draft
    }

    var isNew: Bool { linkID == nil }
    var stored: Deliver.ShareLink? { linkID.flatMap { store.link($0) } }

    var dirty: Bool {
        if isNew || !password.isEmpty || clearPassword { return true }
        var edited = baseline
        Self.apply(draft, to: &edited)
        return edited != baseline
    }

    /// The settings the builder edits, from a draft onto a link (never its id, key, room, stamps or pause).
    static func apply(_ draft: Deliver.ShareLink, to link: inout Deliver.ShareLink) {
        let title = Deliver.clean(draft.title, limit: DeliverStore.nameLimit)
        if !title.isEmpty { link.title = title }
        link.scope = draft.scope
        link.mode = draft.mode
        link.allowDownload = draft.allowDownload
        link.latestOnly = draft.latestOnly
        link.expires = draft.expires
        link.order = draft.order
        link.delivered = draft.delivered
        DeliverLinkOptions.apply(draft, to: &link)
    }

    /// Delivered (wf-deliver): masters to download (originals on), comments read only, and an expiry (30 days unless
    /// one is set) whose reminder mail goes 7 days before. Off: back to a review link, as it was.
    func setDelivered(_ on: Bool) {
        draft.delivered = on ? (baseline.delivered ?? .now) : nil
        guard on else { return }
        draft.allowDownload = true
        if draft.watermark?.burned == true { draft.watermark?.burned = false }   // (originals carry no watermark)
        if draft.expires == nil { draft.expires = Calendar.current.startOfDay(for: Date.now.addingTimeInterval(30 * 86400)).addingTimeInterval(17 * 3600) }
    }

    func revert() {
        draft = baseline
        password = ""
        clearPassword = false
        problem = nil
    }

    /// Update Link (Create Link for a new one): the draft onto the same live link. False when it couldn't be made.
    @discardableResult
    func update() -> Bool {
        let before: Deliver.ShareLink
        if let linkID, let current = store.link(linkID) {
            before = current
            store.updateLink(linkID) { Self.apply(draft, to: &$0) }
        } else {
            do {
                let made = try store.newLink(scope: draft.scope, title: draft.title, mode: draft.mode, allowDownload: draft.allowDownload,
                                             latestOnly: draft.latestOnly, expires: draft.expires, password: password.isEmpty ? nil : password)
                before = made
                linkID = made.id
                password = ""
                store.updateLink(made.id) { Self.apply(draft, to: &$0) }
            } catch {
                problem = String(localized: "There are as many live links as Pluck keeps. Turn one off first.")
                return false
            }
        }
        guard let linkID else { return false }
        if !password.isEmpty { store.setPassword(password, link: linkID) } else if clearPassword { store.setPassword(nil, link: linkID) }
        password = ""
        clearPassword = false
        problem = nil
        guard let now = store.link(linkID) else { return false }
        // A changed watermark (or burned-in one over new assets) makes the link's marked copies again.
        if store === DeliverStore.shared, before.watermark != now.watermark || (before.scope != now.scope && now.watermark?.burned == true) {
            DeliverCopies.shared.remark(now)
        }
        // Delivered (wf-deliver): into the project's NAS folder, for Archive (off again: taken out).
        // (Off: only once no other link of the project is delivered.)
        if before.delivered != now.delivered,
           now.delivered != nil || !store.links.contains(where: { $0.id != now.id && $0.project == now.project && $0.delivered != nil && $0.revoked == nil }) {
            DeliverProjectFile.mark("delivered", now.delivered, project: now.project, store: store, replace: true)
        }
        draft = now
        baseline = now
        return true
    }

    /// The preview page's manifest (sorted keys, so an unchanged draft isn't sent again) and the pictures it may load.
    var preview: (manifest: Data, pictures: [String: URL]) {
        let made = server.previewManifest(draft)
        return ((try? JSONSerialization.data(withJSONObject: made.json, options: [.sortedKeys])) ?? Data(), made.pictures)
    }

    // MARK: Content

    /// Assets and folders dropped on the builder (their ids): an asset joins the link, a folder becomes what it shares.
    func drop(_ ids: [String]) -> Bool {
        let project = draft.project, content = store.content(project)
        var changed = false
        for id in ids.compactMap(UUID.init(uuidString:)) {
            if content.folders.contains(where: { $0.id == id }) {
                draft.scope = .folder(id, project: project)
                changed = true
            } else if content.assets.contains(where: { $0.id == id }) {
                add(id)
                changed = true
            }
        }
        return changed
    }

    /// The assets the draft shares, in the link's order.
    var assets: [Deliver.Asset] {
        let content = store.content(draft.project)
        return Deliver.arranged(content.assets.filter { server.inScope($0, draft) },
                                order: draft.order ?? Deliver.folderOrder(content.folders, assets: content.assets))
    }

    func add(_ asset: UUID) {
        let ids = assets.map(\.id)
        guard !ids.contains(asset) else { return }
        draft.scope = .assets(ids + [asset], project: draft.project)
    }

    /// Out of the link (a project or folder link becomes a link to the rest); one asset stays at least.
    func remove(_ asset: UUID) {
        let rest = assets.map(\.id).filter { $0 != asset }
        guard !rest.isEmpty else { return }
        draft.scope = rest.count == 1 ? .asset(rest[0], project: draft.project) : .assets(rest, project: draft.project)
    }

    /// A folder's cards dragged into a new order in the preview: those take their new places among the link's order.
    func reorder(_ moved: [UUID]) {
        draft.order = Self.reorder(assets.map(\.id), moved: moved)
    }

    nonisolated static func reorder(_ all: [UUID], moved: [UUID]) -> [UUID] {
        let set = Set(moved)
        var next = moved.makeIterator()
        return all.map { set.contains($0) ? (next.next() ?? $0) : $0 }
    }
}

/// The builder open on the Deliver page (one at a time).
@MainActor
@Observable
final class ShareBuilder {
    static let shared = ShareBuilder()
    var session: ShareBuilderSession?
    /// Leaving with unsaved changes: what happens on Discard, and on Keep Editing.
    var asking: (discard: () -> Void, keep: () -> Void)?

    /// The builder on an existing link (Deliver shows it in place of what was there).
    func open(_ link: UUID, nav: StudioNavigator = .shared) {
        guard let found = DeliverStore.shared.link(link) else { return }
        leave {
            let session = ShareBuilderSession(link: found)
            session.origin = nav.deliver
            self.session = session
        }
    }

    /// New Link: the builder on a draft (nothing is made until Create Link).
    func new(_ scope: Deliver.Scope, nav: StudioNavigator = .shared) {
        leave {
            let session = ShareBuilderSession(new: scope)
            session.origin = nav.deliver
            self.session = session
        }
    }

    /// Closes the builder, asking first when there are unsaved changes; then `then`.
    func leave(then: @escaping () -> Void = {}) {
        guard let session, session.dirty else {
            self.session = nil
            return then()
        }
        asking = (discard: { self.session = nil; then() }, keep: {})
    }

    /// Deliver went to another view: the builder closes (or, with unsaved changes, asks; Keep Editing goes back).
    func navigated(to selection: Deliver.Selection, nav: StudioNavigator) {
        guard let session, let origin = session.origin, origin != selection else { return }
        guard session.dirty else { self.session = nil; return }
        asking = (discard: { self.session = nil }, keep: { nav.deliver = origin })
    }
}

// MARK: - The preview: the real review page in a web view

/// The preview page (pluck-site `npm run build:preview`, kept in Resources/SharePreview).
enum SharePreviewPage {
    static let data: Data? = Bundle.main.url(forResource: "share-preview", withExtension: "html", subdirectory: "SharePreview").flatMap { try? Data(contentsOf: $0) }
}

/// Serves `pluck-preview://app/` (the page) and `pluck-preview://img/<version>` (only the shown versions' pictures).
final class SharePreviewScheme: NSObject, WKURLSchemeHandler {
    var pictures: [String: URL] = [:]

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var data: Data?, type = "image/jpeg"
        if url.host == "app" { data = SharePreviewPage.data; type = "text/html" }
        else if url.host == "img", let file = pictures[url.lastPathComponent] { data = try? Data(contentsOf: file) }
        guard let data else { return task.didFailWithError(URLError(.fileDoesNotExist)) }
        task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: type == "text/html" ? "utf-8" : nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

struct SharePreviewWeb: NSViewRepresentable {
    let manifest: Data
    let pictures: [String: URL]
    var onOrder: ([UUID]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let coordinator = context.coordinator
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(coordinator.scheme, forURLScheme: "pluck-preview")
        config.userContentController.add(coordinator, name: "pluck")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = coordinator
        web.setValue(false, forKey: "drawsBackground")
        web.autoresizingMask = [.width, .height]
        coordinator.web = web
        let box = NSView()
        web.frame = box.bounds
        box.addSubview(web)
        // Off-screen pictures (screenshot mode) can't draw a web view: its snapshot goes on top.
        if ScreenshotMode.scene != nil {
            let still = NSImageView()
            still.imageScaling = .scaleAxesIndependently
            still.autoresizingMask = [.width, .height]
            still.frame = box.bounds
            box.addSubview(still)
            coordinator.still = still
        }
        web.load(URLRequest(url: URL(string: "pluck-preview://app/index.html")!))
        return box
    }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onOrder = onOrder
        coordinator.scheme.pictures = pictures
        coordinator.show(manifest)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.web?.configuration.userContentController.removeScriptMessageHandler(forName: "pluck")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let scheme = SharePreviewScheme()
        weak var web: WKWebView?
        weak var still: NSImageView?
        var onOrder: ([UUID]) -> Void = { _ in }
        private var loaded = false
        private var wanted: Data?
        private var shown: Data?

        func show(_ manifest: Data) {
            wanted = manifest
            guard loaded, manifest != shown, let web else { return }
            shown = manifest
            web.evaluateJavaScript("window.pluckPreview(\(String(decoding: manifest, as: UTF8.self)))") { [weak self] _, _ in self?.snapshot() }
        }

        private func snapshot() {
            guard let still, let web else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                web.takeSnapshot(with: nil) { image, _ in if let image { still.image = image } }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            if let wanted { show(wanted) }
        }

        /// Only the page itself: its links (pluck.tools in the footer) don't open in here.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url?.scheme == "pluck-preview" ? .allow : .cancel)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let order = body["order"] as? [String] else { return }
            onOrder(order.compactMap(UUID.init(uuidString:)))
        }
    }
}
