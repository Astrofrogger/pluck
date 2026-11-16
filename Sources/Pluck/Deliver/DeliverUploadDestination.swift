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
        if let at = backupChosen[entry.upload.host], Date.now.timeIntervalSince(at) < 60 { entry.viaBackup = true }
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
                store.update(version: version, of: asset) { $0.path = reference }
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
