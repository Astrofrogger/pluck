import SwiftUI

/// Where an original shared from this Mac goes on the NAS (§13.2, the owner's "option 1"): one uploads folder the
/// server may write to (the media folders stay read-only); for each upload the editor picks a folder in it or makes
/// one. Pluck suggests the folder used last for that project on that server.
@MainActor
enum DeliverUploadDestination {
    /// The server and folder ("renders/Client/2026") an upload goes to.
    struct Upload: Hashable, Codable {
        var host: UUID
        var folder: String
    }

    /// Whether sharing these to `host` asks where they go: a file here (not a folder) that isn't already on that NAS.
    static func needed(_ items: [DeliverBrowseItem], host: Deliver.Host?) -> Bool {
        guard let host, host.kind == .nas else { return false }
        return items.contains { item in
            guard case .local(let url) = item.location, !item.folder else { return false }
            return ReviewPublish.reference(url.path, on: host) == nil
        }
    }

    private static func key(host: UUID, project: UUID) -> String { "deliverUploadFolder.\(host.uuidString).\(project.uuidString)" }

    /// The folder used last for this project on this server.
    static func remembered(host: UUID, project: UUID) -> String? { UserDefaults.standard.string(forKey: key(host: host, project: project)) }
    static func remember(_ folder: String, host: UUID, project: UUID) { UserDefaults.standard.set(folder, forKey: key(host: host, project: project)) }

    /// What the step shows: the picker in the uploads root, or (none set up) how to set one and the fallback.
    enum Stage: Equatable { case loading, pick(root: String), noRoot, unreachable(String) }

    static func stage(_ host: Deliver.Host) async -> Stage {
        do {
            let answer = try await ReviewHostClient.ask(host, ["op": "roots"])
            let root = (answer["writable"] as? [String])?.first
            UserDefaults.standard.set(root, forKey: "deliverUploadRoot." + host.id.uuidString)
            return root.map { .pick(root: $0) } ?? .noRoot
        } catch {
            return .unreachable(ReviewHostClient.problem(error))
        }
    }

    /// While the server is away: the folder a share waits for (the one used last for the project, else one for it in
    /// the uploads folder it had when last seen); nil when it never said it had one.
    static func whileAway(_ host: Deliver.Host, project: UUID?, store: DeliverStore = .shared) -> String? {
        guard let root = UserDefaults.standard.string(forKey: "deliverUploadRoot." + host.id.uuidString) else { return nil }
        guard let project else { return root + "/" + "Review" }
        return suggested(host, root: root, project: project, store: store)
    }

    /// Where the picker opens: the remembered folder while it's still there, else the uploads root.
    static func start(_ host: Deliver.Host, root: String, project: UUID?) async -> String {
        guard let project, let last = remembered(host: host.id, project: project), last == root || last.hasPrefix(root + "/"),
              (try? await ReviewHostClient.browse(host, path: last)) != nil else { return root }
        return last
    }

    /// The folder a share without a picker uses (a watched render, "Upload to NAS…"): the remembered one, else one for the project.
    static func suggested(_ host: Deliver.Host, root: String, project: UUID, store: DeliverStore = .shared) -> String {
        if let last = remembered(host: host.id, project: project), last == root || last.hasPrefix(root + "/") { return last }
        return root + "/" + DeliverServer.safeName(store.project(project)?.name ?? "Review")
    }

    /// Move to…: a file in the uploads folder into another folder of it (the helper's `move`, checked inside the root);
    /// versions that point at it point at its new place. Returns the new path.
    @discardableResult
    static func move(_ path: String, to folder: String, host: Deliver.Host, store: DeliverStore = .shared) async throws -> String {
        let moved = try await ReviewHostClient.ask(host, ["op": "move", "path": path, "to": folder])["path"] as? String ?? path
        let old = ReviewPublish.nasPath(host: host.id, path: path), new = ReviewPublish.nasPath(host: host.id, path: moved)
        for project in store.projects {
            for asset in store.content(project.id).assets {
                for version in asset.versions where version.path == old { store.update(version: version.id, of: asset.id) { $0.path = new } }
            }
        }
        return moved
    }

    /// New Folder: `name` inside `parent` (the helper checks every part and stays inside the root).
    static func makeFolder(_ name: String, in parent: String, host: Deliver.Host) async throws -> String {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains(where: { "/\\:".contains($0) }), name.count <= 120 else { throw Deliver.Failure("invalid") }
        let path = parent + "/" + name
        _ = try await ReviewHostClient.ask(host, ["op": "mkdir", "path": path])
        return path
    }
}

/// The destination step of Share for Review: a Finder-style picker in the server's uploads folder, New Folder and
/// Upload; without an uploads folder, how to set one and "Keep It on the Server Only" (today's hidden data folder).
struct DeliverUploadPicker: View {
    let host: Deliver.Host
    let project: UUID?
    /// The folder chosen (a media path in the uploads root), or nil: on the server only.
    let done: (String?) -> Void
    let back: () -> Void
    /// The server away: queue it for this folder ("Waiting for NAS").
    var later: ((String) -> Void)? = nil
    /// Move to… uses the same picker: its own title and button, no "on the server only".
    var title: String? = nil
    var action: String? = nil
    @State private var stage = DeliverUploadDestination.Stage.loading
    @State private var source: NASFinderSource
    @State private var pane: FinderPane
    @State private var naming = false
    @State private var name = ""
    @State private var problem: String?
    @State private var uploads = DeliverUploads.shared

    init(host: Deliver.Host, project: UUID?, stage: DeliverUploadDestination.Stage = .loading, title: String? = nil, action: String? = nil,
         done: @escaping (String?) -> Void, back: @escaping () -> Void, later: ((String) -> Void)? = nil) {
        self.title = title
        self.action = action
        self.host = host
        self.project = project
        self.done = done
        self.back = back
        self.later = later
        let source = NASFinderSource(host: host)
        _source = State(initialValue: source)
        _pane = State(initialValue: FinderPane(url: source.root, base: source.root, source: source))
        _stage = State(initialValue: stage)
    }

    /// The folder Upload puts it in: one folder chosen in the list, else the one shown.
    private var target: String? {
        guard case .pick(let root) = stage else { return nil }
        let chosen = pane.selection.count == 1 ? pane.shown.first { pane.selection.contains($0.url) && $0.isFolder }?.url : nil
        let path = source.path(chosen ?? pane.url)
        return path == root || path.hasPrefix(root + "/") ? path : nil
    }

    private var rootName: String {
        guard case .pick(let root) = stage else { return "" }
        return source.display(root)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: title ?? String(localized: "Where should it go on \(host.name)?")).font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
            switch stage {
            case .loading:
                HStack { PlumSpinner(); Text("Looking for the uploads folder…").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .noRoot: noRoot
            case .pick(let root): picker(root)
            case .unreachable(let why): away(why)
            }
            if let problem { Text(verbatim: problem).font(Design.Studio.hint).foregroundStyle(Design.Studio.bad) }
            if let progress = uploads.progress.values.first {
                ProgressView(value: progress).tint(Design.Brand.pink)
                Text("Uploading \(Int(progress * 100)) %").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).monospacedDigit()
            }
            HStack {
                if case .pick = stage {
                    Button("New Folder…") { name = ""; naming = true }.buttonStyle(StudioFlatButtonStyle()).disabled(target == nil)
                }
                Spacer()
                Button("Back") { back() }.buttonStyle(StudioFlatButtonStyle())
                if case .pick = stage {
                    if action == nil { Button("Keep It on the Server Only") { done(nil) }.buttonStyle(StudioFlatButtonStyle()) }
                    Button(action ?? String(localized: "Upload")) { if let target { done(target) } }.buttonStyle(StudioFlatButtonStyle(prominent: true)).disabled(target == nil || !uploads.progress.isEmpty)
                } else if stage == .noRoot, action == nil {
                    Button("Keep It on the Server Only") { done(nil) }.buttonStyle(StudioFlatButtonStyle(prominent: true))
                } else if case .unreachable = stage {
                    Button("Try Again") { stage = .loading; Task { stage = await DeliverUploadDestination.stage(host) } }.buttonStyle(StudioFlatButtonStyle())
                    if let later, let folder = DeliverUploadDestination.whileAway(host, project: project) {
                        let backup = DeliverOutage.backup(for: host) != nil
                        Button("Send When It’s Back") { DeliverShareQueue.shared.chooseBackup(host.id, false); later(folder) }
                            .buttonStyle(StudioFlatButtonStyle(prominent: !backup))
                        if backup {
                            Button("Upload to Backup") { DeliverShareQueue.shared.chooseBackup(host.id, true); later(folder) }
                                .buttonStyle(StudioFlatButtonStyle(prominent: true))
                        }
                    }
                }
            }
        }
        .task {
            if stage == .loading {
                let found = await DeliverUploadDestination.stage(host)
                guard !Task.isCancelled else { return }
                stage = found
            }
            guard case .pick(let root) = stage else { return }
            source.uploads = root
            FinderThumbnails.shared.register(source)
            let start = await DeliverUploadDestination.start(host, root: root, project: project)
            pane.go(to: source.url(start), base: source.url(root))
        }
        .onDisappear { FinderThumbnails.shared.unregister(source) }
        .alert("New Folder", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Create") { Task { await makeFolder() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func picker(_ root: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                FinderSidebar(groups: [.init(title: host.name, places: [.init(id: "uploads", symbol: "tray.and.arrow.down", title: rootName)])],
                              selection: "uploads") { _ in pane.go(to: source.url(root), base: source.url(root)) }
                Divider()
                FinderPaneView(pane: pane).coordinateSpace(name: "finder")
            }
            .clipShape(.rect(cornerRadius: Design.Studio.controlRadius))
            .overlay { RoundedRectangle(cornerRadius: Design.Studio.controlRadius).stroke(Design.Studio.line) }
            if let target {
                Text("Saved in \(path(target))").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1).truncationMode(.head)
            }
        }
    }

    /// "Uploads › Client › 2026".
    private func path(_ media: String) -> String {
        let parts = media.split(separator: "/").map(String.init)
        return ([source.display(parts.first ?? "")] + parts.dropFirst()).joined(separator: " › ")
    }

    private var noRoot: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(host.name) has no uploads folder yet, so Pluck can’t save the original there.")
                .font(Design.Studio.body).foregroundStyle(Design.Studio.text).fixedSize(horizontal: false, vertical: true)
            if TrueNASSetup.isTrueNAS(host) {
                Text("To set one: Deliver › Browse, right-click \(host.name) › Change Folders…, then choose an Uploads folder (its own dataset).")
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("To set one, give the server a folder of its own it may write to (PLUCK_UPLOADS, see Set Up Server › the NAS guide).")
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).fixedSize(horizontal: false, vertical: true)
            }
            Text("Or keep it on the server only: Pluck makes the review copies here and sends them to the server’s own data folder, as before.")
                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func away(_ why: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pluck can’t reach \(host.name) right now.").font(Design.Studio.body).foregroundStyle(Design.Studio.text)
            Text(verbatim: why).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).fixedSize(horizontal: false, vertical: true)
            if later != nil, DeliverOutage.backup(for: host) != nil, DeliverUploadDestination.whileAway(host, project: project) != nil {
                Text("The main server is offline. Upload to the backup now? It moves to the main when it’s back.")
                    .font(Design.Studio.body).foregroundStyle(Design.Studio.text).fixedSize(horizontal: false, vertical: true)
            }
            if let folder = DeliverUploadDestination.whileAway(host, project: project) {
                Text("Pluck can keep it waiting and send it to \(path(folder)) as soon as the server is back, even after a restart.")
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func makeFolder() async {
        guard let parent = target else { return }
        do {
            let made = try await DeliverUploadDestination.makeFolder(name, in: parent, host: host)
            problem = nil
            pane.go(to: source.url(made), base: pane.base)
        } catch {
            problem = (error as? Deliver.Failure)?.code == "invalid" ? String(localized: "That name can’t be used for a folder.") : ReviewHostClient.problem(error)
        }
    }
}

/// "Waiting for NAS": shares whose server didn't answer (the file, the folder chosen on it, the project), kept across
/// restarts and sent as soon as that server answers again; each can be cancelled.
@MainActor
@Observable
final class DeliverShareQueue {
    static let shared = DeliverShareQueue(store: .shared, publish: .shared)

    struct Entry: Codable, Identifiable, Hashable {
        var id = UUID()
        var file: String
        var size: Int64
        var project: UUID
        /// A new version of this asset; nil: a new asset.
        var asset: UUID?
        var upload: DeliverUploadDestination.Upload
        /// A server it's published to afterwards (not the one holding the review data, which syncs).
        var publishTo: UUID?
        var added = Date()
        /// "Upload to Backup" (§13.25): sent to the main's backup while the main is down; `onBackup` is the backup's id for
        /// it once there, found on the main (outage-list) when it's back.
        var viaBackup: Bool?
        var onBackup: String?
        /// "Upload to <NAS>…" for a version: that version points at the file once it's there (no new version).
        var version: UUID?
        var name: String { URL(fileURLWithPath: file).lastPathComponent }
    }

    let store: DeliverStore
    let publish: ReviewPublish
    private(set) var entries: [Entry] = []
    @ObservationIgnored private var runner: Task<Void, Never>?

    init(store: DeliverStore, publish: ReviewPublish) {
        self.store = store
        self.publish = publish
        entries = (try? Data(contentsOf: file)).flatMap { try? Deliver.decoder.decode([Entry].self, from: $0) } ?? []
    }

    private var file: URL { store.root.appendingPathComponent("share-queue.json") }

    private func save() {
        try? FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try? Deliver.encoder.encode(entries).write(to: file, options: .atomic)
    }

    func waiting(_ project: UUID) -> [Entry] { entries.filter { $0.project == project } }

    func add(_ entry: Entry) {
        var entry = entry
        if let at = backupChosen.removeValue(forKey: entry.upload.host), Date.now.timeIntervalSince(at) < 60 { entry.viaBackup = true }
        entries.append(entry)
        save()
        resume()
    }

    /// The editor's answer to "Upload to the backup now?" for what's queued for that server next (one Share at a time).
    @ObservationIgnored private var backupChosen: [UUID: Date] = [:]
    func chooseBackup(_ host: UUID, _ yes: Bool) { backupChosen[host] = yes ? .now : nil }

    func cancel(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    /// A failure that waiting can fix (the server away), not one that sending again can't (full, refused, gone).
    nonisolated static func waitable(_ error: Error) -> Bool {
        guard let code = (error as? Deliver.Failure)?.code else { return true }
        return !["checksum", "space", "exists", "limit", "scope", "notFound", "tooLarge", "invalid", "auth", "removed", "pin"].contains(code)
    }

    /// Sends what's waiting for each server that answers now; returns how many went.
    @discardableResult
    func attempt() async -> Int {
        var sent = 0
        for entry in entries {
            guard let host = publish.host(entry.upload.host) else { continue }
            let up = (try? await ReviewHostClient.ask(host, ["op": "roots"])) != nil
            var path: String?
            if let id = entry.onBackup {
                // On the backup: the backup moves it to the main once it's back; the main says where it went.
                guard up, let item = (try? await DeliverOutage.delivered(host))?.first(where: { $0.id == id }) else { continue }
                if item.quarantine {
                    path = await takeIn(item, host: host, entry: entry)
                    if path == nil { continue }
                } else { path = item.path }
            } else if !up {
                guard entry.viaBackup == true, DeliverOutage.backup(for: host) != nil,
                      let id = try? await DeliverOutage.upload(URL(fileURLWithPath: entry.file), folder: entry.upload.folder, main: host),
                      let index = entries.firstIndex(where: { $0.id == entry.id }) else { continue }
                entries[index].onBackup = id
                save()
                continue
            } else {
                path = try? await DeliverUploads.shared.upload(URL(fileURLWithPath: entry.file), to: entry.upload.folder + "/" + entry.name, host: host, attempts: 2)
            }
            guard let path else { continue }
            // (Cancelled while it was on its way: the file stays on the NAS, nothing is added.)
            guard entries.contains(where: { $0.id == entry.id }) else { continue }
            if path.hasPrefix("/") {
                // Taken in here (no uploads folder on the server): a local file, as before; a version keeps its own original.
                let local = URL(fileURLWithPath: path)
                if entry.version == nil, let asset = entry.asset, store.find(asset) != nil { _ = try? store.addVersion(local, to: asset) }
                else if entry.version == nil { _ = try? store.add([local], to: entry.project, folder: nil) }
                entries.removeAll { $0.id == entry.id }
                save()
                sent += 1
                continue
            }
            let reference = ReviewPublish.nasPath(host: host.id, path: path)
            if let version = entry.version, let asset = entry.asset, store.find(asset) != nil {
                store.update(version: version, of: asset) { $0.path = reference; $0.bookmark = nil } // (its local copy no longer stands for it)
            } else if let asset = entry.asset, store.find(asset) != nil {
                _ = try? store.addVersion(reference: reference, size: entry.size, to: asset)
            } else {
                store.addReferences([(name: URL(fileURLWithPath: entry.name).deletingPathExtension().lastPathComponent, kind: DeliverStore.kind(URL(fileURLWithPath: entry.file)),
                                      path: reference, size: entry.size)], to: entry.project)
            }
            entries.removeAll { $0.id == entry.id }
            save()
            sent += 1
            if let other = entry.publishTo.flatMap(publish.host), !ReviewPublish.isDataHost(other.id) { await publish.publish(.project(entry.project), to: other) }
        }
        return sent
    }

    /// The main had no uploads folder any more when the backup's file arrived: it's in the server's own quarantine, so it
    /// comes here (Review/Uploads) as clients' uploads do, and goes there. The local path, nil when that didn't work.
    private func takeIn(_ item: DeliverOutage.Item, host: Deliver.Host, entry: Entry) async -> String? {
        let target = DeliverServer.unique(store.root.appendingPathComponent("Uploads/outage/\(DeliverServer.safeName(item.name))"))
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try await ReviewHostClient.session(host) { session in
                try await session.get(item.path, to: target, expected: entry.size)
                _ = try? await session.ask(["op": "delete", "path": item.path])
                _ = try? await session.ask(["op": "outage-done", "id": item.id])
            }
            return target.path
        } catch { return nil }
    }

    /// Tries every 30 s while anything waits (started at launch and when something is queued).
    func resume() {
        guard self === Self.shared, runner == nil, !entries.isEmpty else { return }
        runner = Task {
            while !entries.isEmpty, !Task.isCancelled {
                await attempt()
                if entries.isEmpty { break }
                try? await Task.sleep(for: .seconds(30))
            }
            runner = nil
        }
    }
}

/// A project's shares waiting for their server ("Waiting for NAS"), each with where it goes and Cancel.
struct DeliverWaitingRows: View {
    let project: UUID
    @State private var queue = DeliverShareQueue.shared

    var body: some View {
        let waiting = queue.waiting(project)
        if !waiting.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(waiting) { entry in
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(Design.Studio.textQuiet)
                        Text(verbatim: entry.name).font(Design.Studio.body).foregroundStyle(Design.Studio.text).lineLimit(1).truncationMode(.middle)
                        if entry.onBackup != nil {
                            StudioChip(text: Text("On the backup"), colour: Design.Studio.textQuiet)
                        } else {
                            StudioChip(text: entry.viaBackup == true ? Text("Uploading to backup") : Text("Waiting for NAS"), colour: Design.Studio.warn, tinted: true)
                        }
                        Spacer(minLength: 8)
                        Text(verbatim: (queue.publish.host(entry.upload.host)?.name ?? "") + " › " + entry.upload.folder.split(separator: "/").dropFirst().joined(separator: " › "))
                            .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1).truncationMode(.head)
                        Button("Cancel") { queue.cancel(entry.id) }.buttonStyle(StudioFlatButtonStyle())
                    }
                    .padding(.horizontal, 10).frame(height: 36).studioBox()
                }
            }
        }
    }
}

/// NAS first: with a NAS paired, originals belong on it, in a folder the editor picks (never silently only on this Mac).
/// Publish or Share with footage only here asks once, "Upload the originals to <NAS>?"; adding footage goes straight to
/// the picker. Uploads go through DeliverUploads; "Not now" is remembered per project.
extension DeliverUploadDestination {
    struct Offer: Identifiable {
        var id = UUID()
        var host: Deliver.Host
        var scope: Deliver.Scope
        var items: [(asset: UUID, version: Deliver.Version)]
    }

    /// Settings › Review › "Put new footage on the NAS": on unless turned off.
    static let newFootageKey = "deliverNewFootageOnNAS"
    static var newFootageOnNAS: Bool { UserDefaults.standard.object(forKey: newFootageKey) as? Bool ?? true }

    /// The NAS originals go to: the one holding the review data, else one the project is published on, else the first main.
    static func mainNAS(project: UUID?, publish: ReviewPublish = .shared) -> Deliver.Host? {
        let mains = publish.hosts.filter { $0.kind == .nas && $0.role != "backup" }
        if let data = mains.first(where: { ReviewPublish.isDataHost($0.id) }) { return data }
        let published = project.map { project in publish.publications.filter { $0.scope.project == project }.map(\.host) } ?? []
        return mains.first { published.contains($0.id) } ?? mains.first
    }

    /// Whether a version's original is on a NAS (its NAS path, or a NAS mount), or isn't this Mac's at all (another
    /// Mac's, kept as copies on the data host). A local path whose drive isn't connected is still only here.
    /// (`host`: a NAS not in the list yet counts too.)
    static func onNAS(_ version: Deliver.Version, host: Deliver.Host? = nil, store: DeliverStore = .shared, publish: ReviewPublish = .shared) -> Bool {
        if ReviewPublish.browsed(version.path) != nil || version.path.hasPrefix("host:") { return true }
        let path = store.original(version)?.path ?? version.path
        return (publish.hosts + (host.map { [$0] } ?? [])).contains { ReviewPublish.reference(path, on: $0) != nil }
    }

    /// The versions in `scope` (all, or `only`) whose original is only on this Mac.
    static func onlyHere(_ scope: Deliver.Scope, only: Set<UUID>? = nil, host: Deliver.Host? = nil, store: DeliverStore = .shared,
                         publish: ReviewPublish = .shared) -> [(asset: UUID, version: Deliver.Version)] {
        publish.assets(scope).flatMap { asset in
            asset.versions.filter { only?.contains($0.id) ?? true }.filter { !onNAS($0, host: host, store: store, publish: publish) }.map { (asset.id, $0) }
        }
    }

    private static func declinedKey(_ project: UUID) -> String { "deliverOriginalsDeclined." + project.uuidString }
    static func declined(_ project: UUID) -> Bool { UserDefaults.standard.bool(forKey: declinedKey(project)) }
    static func decline(_ project: UUID) { UserDefaults.standard.set(true, forKey: declinedKey(project)) }
    static func forgetDeclined(_ project: UUID) { UserDefaults.standard.removeObject(forKey: declinedKey(project)) }

    /// The offer for `scope` (its versions in `only`), or nil: `host` (Publish) must be a NAS; without one it is mainNAS.
    /// Nil too when everything is on the NAS already, or (`asking`, the automatic question) "Not now" was said.
    static func offer(_ scope: Deliver.Scope, host: Deliver.Host?, only: Set<UUID>? = nil, asking: Bool = true,
                      store: DeliverStore = .shared, publish: ReviewPublish = .shared) -> Offer? {
        guard !asking || !declined(scope.project), let nas = host ?? mainNAS(project: scope.project, publish: publish), nas.kind == .nas else { return nil }
        let items = onlyHere(scope, only: only, host: nas, store: store, publish: publish)
        return items.isEmpty ? nil : Offer(host: nas, scope: scope, items: items)
    }

    /// Sends each original to `folder` on the NAS; where the project is published there (not the data host, which syncs),
    /// it is published again afterwards so the NAS makes its review copies from the originals.
    static func upload(_ offer: Offer, folder: String, store: DeliverStore = .shared, publish: ReviewPublish = .shared) async {
        let project = offer.scope.project
        remember(folder, host: offer.host.id, project: project)
        for item in offer.items { await DeliverUploads.shared.uploadVersion(item.version, of: item.asset, folder: folder, host: offer.host, store: store) }
        if let again = publish.publications.first(where: { $0.host == offer.host.id && $0.scope.project == project }) {
            await publish.publish(again.scope, to: offer.host)
        }
    }

    /// The server away: each original waits for it ("Waiting for NAS") and its version points at the file once it's there.
    static func later(_ offer: Offer, folder: String, store: DeliverStore = .shared) {
        remember(folder, host: offer.host.id, project: offer.scope.project)
        for item in offer.items {
            guard let file = store.original(item.version) else { continue }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            DeliverShareQueue.shared.add(.init(file: file.path, size: size, project: offer.scope.project, asset: item.asset,
                                               upload: .init(host: offer.host.id, folder: folder), version: item.version.id))
        }
    }

    // MARK: - Where a scope stands on the NAS

    enum NASState: Equatable {
        case onNAS, sending, onlyHere(Int), waiting(Int), uploading(Int, of: Int), failed(String)
    }

    /// The one rule for the Publish sheet, the project row and the footer: a failure first, then what's on its way, then
    /// what's still only here. `versions`/`onNAS` count the scope's versions; `syncing`: the data host's outbox isn't empty.
    nonisolated static func state(versions: Int, onNAS: Int, uploading: Bool, waiting: Int, failure: String?, syncing: Bool) -> NASState {
        if let failure { return .failed(failure) }
        if uploading { return .uploading(min(onNAS + 1, versions), of: versions) }
        if waiting > 0 { return .waiting(waiting) }
        if onNAS < versions { return .onlyHere(versions - onNAS) }
        return syncing ? .sending : .onNAS
    }

    /// `scope` on `host` (the data host also counts DeliverSync's state).
    static func state(_ scope: Deliver.Scope, host: Deliver.Host, store: DeliverStore = .shared, publish: ReviewPublish = .shared) -> NASState {
        let versions = publish.assets(scope).flatMap(\.versions), ids = Set(versions.map(\.id))
        let uploads = DeliverUploads.shared, sync = DeliverSync.shared, data = ReviewPublish.isDataHost(host.id)
        let waiting = DeliverShareQueue.shared.waiting(scope.project).filter { entry in
            entry.version.map(ids.contains) ?? (scope == .project(scope.project))
        }.count
        let failure = uploads.failures.first { ids.contains($0.version) }?.why ?? (data ? sync.problem : nil)
        return state(versions: versions.count, onNAS: versions.filter { onNAS($0, store: store, publish: publish) }.count,
                     uploading: !uploads.active.isDisjoint(with: ids), waiting: waiting, failure: failure, syncing: data && (sync.waiting > 0 || sync.syncing))
    }
}

/// A scope's state on the NAS, short: "On the NAS", "Uploading 3 of 5…", "Waiting for NAS", "2 only on this Mac", "Failed: …".
struct DeliverNASStateLabel: View {
    let state: DeliverUploadDestination.NASState

    var body: some View {
        HStack(spacing: 6) {
            switch state {
            case .onNAS:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Design.Studio.good)
                Text("On the NAS").foregroundStyle(Design.Studio.textQuiet)
            case .sending:
                PlumSpinner()
                Text("Sending…").foregroundStyle(Design.Studio.textQuiet)
            case .uploading(let n, let total):
                PlumSpinner()
                Text("Uploading \(n) of \(total)…").foregroundStyle(Design.Studio.text).monospacedDigit()
            case .waiting:
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(Design.Studio.warn)
                Text("Waiting for NAS").foregroundStyle(Design.Studio.warn)
            case .onlyHere(let n):
                Image(systemName: "laptopcomputer").foregroundStyle(Design.Studio.warn)
                Text("\(n) only on this Mac").foregroundStyle(Design.Studio.warn)
            case .failed(let why):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Design.Studio.bad)
                Text("Failed: \(why)").foregroundStyle(Design.Studio.bad).lineLimit(1).truncationMode(.tail)
            }
        }
        .font(Design.Studio.hint)
    }
}

/// In a project, when something of it isn't on the NAS: its state and "Upload to <NAS>…" (the folder picker).
struct DeliverNASStatusRow: View {
    let scope: Deliver.Scope
    @State private var offer: DeliverUploadDestination.Offer?
    @State private var uploads = DeliverUploads.shared
    @State private var queue = DeliverShareQueue.shared

    var body: some View {
        if let nas = DeliverUploadDestination.mainNAS(project: scope.project) {
            let state = DeliverUploadDestination.state(scope, host: nas)
            if state != .onNAS, state != .sending {
                HStack(spacing: 8) {
                    DeliverNASStateLabel(state: state)
                    Spacer(minLength: 8)
                    if case .onlyHere = state {
                        Button("Upload to \(nas.name)…") { offer = DeliverUploadDestination.offer(scope, host: nas, asking: false) }
                            .buttonStyle(StudioFlatButtonStyle(prominent: true))
                    } else if case .failed = state {
                        Button("Try Again") { DeliverNASAlert.shared.retry() }.buttonStyle(StudioFlatButtonStyle())
                    }
                }
                .padding(.horizontal, 10).frame(height: 36).studioBox()
                .originalsPicker($offer)
            }
        }
    }
}

/// The question (Publish, Share), then the folder picker; or (`ask` false: footage just added, Upload…) the picker at once.
private struct DeliverOriginalsOffer: ViewModifier {
    @Binding var offer: DeliverUploadDestination.Offer?
    let ask: Bool
    @State private var picking: DeliverUploadDestination.Offer?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(Text("Upload the originals to \(offer?.host.name ?? "")?"), isPresented: Binding(get: { ask && offer != nil }, set: { if !$0, ask { offer = nil } }),
                                titleVisibility: .visible, presenting: offer) { offer in
                Button("Upload…") { picking = offer }
                Button("Not now", role: .cancel) { DeliverUploadDestination.decline(offer.scope.project) }
            }
            .sheet(item: ask ? $picking : $offer) { offer in
                DeliverUploadPicker(host: offer.host, project: offer.scope.project, done: { folder in
                    close()
                    if let folder { Task { await DeliverUploadDestination.upload(offer, folder: folder) } }
                }, back: { close() }, later: { folder in
                    close()
                    DeliverUploadDestination.later(offer, folder: folder)
                })
                .padding(Design.Spacing.sheet).frame(minWidth: 900, idealWidth: 1060, maxWidth: .infinity, minHeight: 600, idealHeight: 720, maxHeight: .infinity)
                .background(Design.Studio.panel)
            }
    }

    private func close() { if ask { picking = nil } else { offer = nil } }
}

extension View {
    func originalsOffer(_ offer: Binding<DeliverUploadDestination.Offer?>) -> some View { modifier(DeliverOriginalsOffer(offer: offer, ask: true)) }
    func originalsPicker(_ offer: Binding<DeliverUploadDestination.Offer?>) -> some View { modifier(DeliverOriginalsOffer(offer: offer, ask: false)) }
    /// The NAS failure alert, once for the whole window.
    func deliverNASAlert() -> some View { modifier(DeliverNASAlertModifier()) }
}

/// "Sending to the NAS didn't work": one alert per burst of failures (an upload, or sync's push), with Try Again and Show.
@MainActor
@Observable
final class DeliverNASAlert {
    static let shared = DeliverNASAlert()

    struct Problem: Equatable {
        var title: String
        var detail: String
        /// Show: the asset, else the project, else the Deliver page.
        var asset: UUID?
        var project: UUID?
    }

    private(set) var shown: Problem?
    /// Failures after the shown one, in the same burst.
    private(set) var more = 0
    /// After OK, a minute without another alert (what failed stays flagged in the project).
    @ObservationIgnored private var quietUntil = Date.distantPast
    /// Sync alerts once until a round goes through again.
    @ObservationIgnored private(set) var syncAlerted = false

    /// Whether it was shown (else it joins the shown one, or the quiet minute).
    @discardableResult
    func report(_ problem: Problem, now: Date = .now) -> Bool {
        if shown != nil { more += 1; return false }
        guard now >= quietUntil else { return false }
        shown = problem
        return true
    }

    func dismiss(now: Date = .now) {
        guard shown != nil else { return }
        shown = nil
        more = 0
        quietUntil = now.addingTimeInterval(60)
    }

    /// A sync round that didn't go through: refused (`problem`), or the NAS away with changes waiting.
    func syncFailed(_ problem: String?, waiting: Int, host: String, now: Date = .now) {
        guard !syncAlerted, problem != nil || waiting > 0 else { return }
        syncAlerted = true
        report(problem.map { Problem(title: String(localized: "Pluck can’t send to \(host)"), detail: String(localized: "Can’t sync: \($0)")) }
               ?? Problem(title: String(localized: "Pluck can’t reach \(host)"), detail: String(localized: "\(waiting) changes are waiting. They go up as soon as it’s back.")),
               now: now)
    }

    func syncOK() { syncAlerted = false }

    /// Try Again: every failed upload, what waits for the NAS, and a sync round.
    func retry() {
        DeliverUploads.shared.retry()
        Task { await DeliverShareQueue.shared.attempt() }
        Task { await DeliverSync.shared.round() }
    }
}

private struct DeliverNASAlertModifier: ViewModifier {
    @State private var alerts = DeliverNASAlert.shared

    func body(content: Content) -> some View {
        content.alert(Text(verbatim: alerts.shown?.title ?? ""), isPresented: Binding(get: { alerts.shown != nil }, set: { if !$0 { alerts.dismiss() } }),
                      presenting: alerts.shown) { problem in
            Button("Try Again") { alerts.dismiss(); alerts.retry() }
            Button("Show") {
                alerts.dismiss()
                let nav = StudioNavigator.shared
                nav.show(.deliver)
                if let asset = problem.asset, DeliverStore.shared.find(asset) != nil { nav.deliver = .asset(asset, version: nil, comment: nil) }
                else if let project = problem.project { nav.deliver = .project(project, folder: nil) }
            }
            Button("OK", role: .cancel) { alerts.dismiss() }
        } message: { problem in
            Text(verbatim: problem.detail + (alerts.more > 0 ? "\n" + String(localized: "And \(alerts.more) more.") : ""))
        }
    }
}
