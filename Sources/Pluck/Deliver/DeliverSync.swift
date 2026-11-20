import Foundation

/// Review data on a NAS by default (§13.1): the paired NAS is the data host, this Mac's DeliverStore its working
/// copy. Every local change is a line in `Review/sync/outbox.jsonl` (written in the same main-actor step as the save,
/// so a crash can't lose it); each round flushes the outbox, then takes `changes` and `pull`, and merges them with
/// rule M/MC. It works offline and catches up when the NAS is reachable again.
@MainActor
@Observable
final class DeliverSync {
    static let shared = DeliverSync(store: .shared, publish: .shared)

    struct State: Codable, Equatable {
        var host: UUID?
        var storeSeq = 0
        var logSeq = 0
        var lastSync: Date?
        var migrated: Date?
    }

    let store: DeliverStore
    let publish: ReviewPublish
    private(set) var state = State()
    private(set) var waiting = 0
    private(set) var problem: String?
    private(set) var syncing = false
    /// The host's protocol says only reading is allowed (§13.15: host newer than Pluck).
    private(set) var readOnly = false
    /// Tests: a round never sleeps or schedules.
    @ObservationIgnored var manual = false
    /// Tests: each outbox line waits this long first (a long push in progress).
    @ObservationIgnored var testFlushPause: Duration?
    @ObservationIgnored private var nextLine = 1
    /// Asked for while a round ran: one more right after it.
    @ObservationIgnored private var again = false
    @ObservationIgnored private var soon: Task<Void, Never>?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var poll: Task<Void, Never>?
    /// The light refresh running (changes + pull), its number and when it began; one left hanging is given up after a minute.
    @ObservationIgnored private var refreshing: (task: Task<Void, Never>, number: Int, began: Date)?
    @ObservationIgnored private var refreshes = 0

    init(store: DeliverStore, publish: ReviewPublish) {
        self.store = store
        self.publish = publish
        load()
    }

    var folder: URL { store.root.appendingPathComponent("sync", isDirectory: true) }
    private var stateFile: URL { folder.appendingPathComponent("state.json") }
    var outboxFile: URL { folder.appendingPathComponent("outbox.jsonl") }

    /// The NAS that holds the review data, when one does.
    var dataHost: Deliver.Host? { state.host.flatMap(publish.host) }

    func load() {
        // A corrupt state.json: everything again from 0 (the merge is idempotent).
        if let data = try? Data(contentsOf: stateFile) {
            state = (try? Deliver.decoder.decode(State.self, from: data)) ?? State(host: Self.hostOfCorrupt(stateFile), migrated: .now)
        } else {
            state = State()
        }
        let lines = outbox()
        waiting = lines.count
        nextLine = (lines.compactMap { $0["n"] as? Int }.max() ?? 0) + 1
        store.journal = state.host == nil ? nil : { [weak self] in self?.write($0) }
    }

    /// A state file that doesn't read: the host id if it's still in there.
    private static func hostOfCorrupt(_ url: URL) -> UUID? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let match = text.firstMatch(of: #/"host"\s*:\s*"([0-9A-Fa-f-]{36})"/#) else { return nil }
        return UUID(uuidString: String(match.1))
    }

    private func saveState() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Deliver.encoder.encode(state).write(to: stateFile, options: .atomic)
    }

    // MARK: - The outbox

    func outbox() -> [[String: Any]] {
        guard let text = try? String(contentsOf: outboxFile, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    private func append(_ line: [String: Any]) {
        var line = line
        line["n"] = nextLine
        nextLine += 1
        guard var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: outboxFile.path) { FileManager.default.createFile(atPath: outboxFile.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: outboxFile) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.synchronize()
        try? handle.close()
        waiting += 1
        if waiting == 10_000 { problem = String(localized: "10,000 changes are waiting for the NAS.") }
    }

    /// Lines the host answered `ok` go; the rest stay in order.
    private func drop(through n: Int) {
        let kept = outbox().filter { ($0["n"] as? Int ?? 0) > n }
        let text = kept.compactMap { (try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } }
            .joined(separator: "\n")
        try? (text + (kept.isEmpty ? "" : "\n")).write(to: outboxFile, atomically: true, encoding: .utf8)
        waiting = kept.count
    }

    /// A store change as its outbox line (a merge-publish fragment, tombstones, or entries to append).
    func write(_ change: DeliverStore.Journal) {
        guard let host = dataHost else { return }
        switch change {
        case .objects(let project, let meta, let folders, let assets, let links):
            guard let project else { return }
            var fragment = publish.manifest(project: project, only: Set(assets), host: host, onlyFolders: Set(folders), onlyLinks: Set(links)).json
            if !meta, folders.isEmpty, assets.isEmpty { fragment["projects"] = [Any]() }
            append(["publish": ["project": project.uuidString, "manifest": fragment]])
        case .tombstones(let tombstones):
            let wire = tombstones.compactMap { (try? Deliver.encoder.encode($0)).flatMap { try? JSONSerialization.jsonObject(with: $0) } }
            append(["tombstones": wire])
        case .entries(let entries):
            append(["append": entries])
        }
        scheduleSoon()
    }

    // MARK: - Rounds

    /// At launch, 2 s after each change, every 30 s while Deliver shows and every 2 min otherwise. New comments and
    /// changes come on their own besides (refresh): every 30 s while Deliver shows, at once when it comes to the front,
    /// whatever a round is pushing.
    func start() {
        guard state.host != nil, !manual, ScreenshotMode.scene == nil else { return }
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.round()
                let visible = StudioNavigator.shared.page == .deliver
                try? await Task.sleep(for: .seconds(visible ? 30 : 120))
            }
        }
        poll?.cancel()
        poll = Task { [weak self] in
            var last = Date.now, shown = true
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                let visible = StudioNavigator.shared.page == .deliver
                if (visible && !shown) || Date.now.timeIntervalSince(last) >= (visible ? 30 : 120) {
                    last = .now
                    await self?.refresh()
                }
                shown = visible
            }
        }
    }

    private func scheduleSoon() {
        guard !manual else { return }
        soon?.cancel()
        soon = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.round()
        }
    }

    /// One round: the outbox, then `changes` (all pages), then `pull`, merged into the store.
    func round() async {
        guard let host = dataHost else { return }
        guard !syncing else { again = true; return }
        syncing = true
        if await once(host) { await refresh() }
        syncing = false
        if again {
            again = false
            await round()
        }
    }

    /// The outbox to the host (its files too: pushFiles), then its status; whether the host answered.
    /// (changes and pull come after it, in refresh's own session.)
    private func once(_ host: Deliver.Host) async -> Bool {
        var status: [String: Any] = [:]
        do {
            try await ReviewHostClient.session(host) { session in
                let compatibility = DeliverHostUpdate.compatibility(host: session.protocolLevel)
                guard compatibility != .refused else { throw Deliver.Failure("incompatible") }
                self.readOnly = compatibility == .readOnly
                if !self.readOnly { try await self.flush(session, host: host) }
                status = (try? await session.ask(["op": "status"])) ?? [:]
                // People (accounts plan §5): new requests notify even while People isn't open.
                if ReviewPublish.shared.host(host.id)?.accounts == 1, let people = try? await session.ask(["op": "people"]) { DeliverPeople.shared.heard(people) }
            }
            await DeliverOutage.note(status: status, host: host)
            state.lastSync = .now
            problem = waiting >= 10_000 ? problem : nil
            saveState()
            DeliverNASAlert.shared.syncOK()
            return true
        } catch {
            said(error)
        }
        return false
    }

    /// A round's (or refresh's) failure in the footer.
    private func said(_ error: Error) {
        do { throw error } catch let failure as Deliver.Failure where failure.code == "incompatible" {
            problem = String(localized: "Update the NAS host")
        } catch is ReviewHostClient.Unconfirmed {
            problem = String(localized: "confirm the NAS’s fingerprint")
        } catch let failure as Deliver.Failure where failure.code != "internal" {
            // The NAS answered, but no (a device it doesn't know, a disk it can't write…): not just offline.
            problem = failure.code == "auth" ? String(localized: "the NAS didn’t accept this Mac") : String(localized: "the NAS refused the change")
        } catch {
            problem = nil   // offline: the footer says so
        }
        // Not just the footer: the alert, once until a round goes through (offline only when something waits to go up).
        if !manual, let host = dataHost { DeliverNASAlert.shared.syncFailed(problem, waiting: waiting, host: host.name) }
    }

    /// New changes and comments from the host in a session of their own, so they never wait behind a long push (or a
    /// round stuck on a dead connection). `changes` first: a comment merges only once its asset is here. One at a time;
    /// one still running after a minute is given up (what it got is merged again next time: the merge is idempotent),
    /// and its seqs aren't kept.
    func refresh() async {
        guard let host = dataHost else { return }
        if let running = refreshing, Date.now.timeIntervalSince(running.began) < 60 { return await running.task.value }
        refreshes += 1
        let number = refreshes
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await ReviewHostClient.session(host) { session in
                    guard DeliverHostUpdate.compatibility(host: session.protocolLevel) != .refused else { throw Deliver.Failure("incompatible") }
                    try await self.changes(session, host: host) { self.refreshing?.number == number }
                    try await self.pull(session, host: host) { self.refreshing?.number == number }
                }
                guard self.refreshing?.number == number else { return }
                self.state.lastSync = .now
                self.problem = self.waiting >= 10_000 ? self.problem : nil
                self.saveState()
            } catch {
                if self.refreshing?.number == number { self.said(error) }
            }
        }
        refreshing = (task, number, .now)
        await task.value
        if refreshing?.number == number { refreshing = nil }
    }

    private func flush(_ session: HostSession, host: Deliver.Host) async throws {
        for line in outbox() {
            guard let n = line["n"] as? Int else { continue }
            if let testFlushPause { try await Task.sleep(for: testFlushPause) }
            if let fragment = line["publish"] as? [String: Any], let manifest = fragment["manifest"] as? [String: Any] {
                if let project = (fragment["project"] as? String).flatMap(UUID.init(uuidString:)) {
                    try await pushFiles(session, project: project, manifest: manifest, host: host)
                }
                let answer = try await session.ask(["op": "publish", "merge": true, "manifest": manifest,
                                                    "remove": ["projects": [Any](), "links": [Any]()], "tombstones": [Any]()])
                if let seq = answer["storeSeq"] as? Int { _ = seq } // (changes reads from our own storeSeq)
            } else if let tombstones = line["tombstones"] as? [[String: Any]] {
                _ = try await session.ask(["op": "publish", "merge": true, "manifest": ["format": 1, "projects": [Any](), "links": [Any]()],
                                           "remove": ["projects": [Any](), "links": [Any]()], "tombstones": tombstones])
            } else if let entries = line["append"] as? [[String: Any]] {
                _ = try await session.ask(["op": "append", "entries": entries])
            }
            drop(through: n)
        }
    }

    /// Bundle files a fragment's pushed versions need (their copies, an original for downloads), when not there yet.
    private func pushFiles(_ session: HostSession, project: UUID, manifest: [String: Any], host: Deliver.Host) async throws {
        let assets = ((manifest["projects"] as? [[String: Any]])?.first?["assets"] as? [[String: Any]] ?? []).compactMap { ($0["id"] as? String).flatMap(UUID.init) }
        guard !assets.isEmpty else { return }
        let files = publish.manifest(project: project, only: Set(assets), host: host).files
        guard !files.isEmpty else { return }
        let there = Dictionary((try await session.ask(["op": "list"])["files"] as? [[String: Any]] ?? []).compactMap { file in
            (file["path"] as? String).map { ($0, (file["size"] as? NSNumber)?.int64Value ?? -1) }
        }) { a, _ in a }
        for file in files {
            let size = (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            if there[file.path] != size { _ = try await session.put(file.path, file.url) }
        }
    }

    /// Every page first, then one apply (projects before their folders and assets, whatever page they came on).
    private func changes(_ session: HostSession, host: Deliver.Host, live: () -> Bool = { true }) async throws {
        var all: [String: [[String: Any]]] = [:], seq = state.storeSeq, more = true, pages = 0, early = false
        while more, pages < 10_000 {
            pages += 1
            let answer = try await session.ask(["op": "changes", "since": seq, "limit": 500])
            for key in ["projects", "folders", "assets", "links", "removed"] { all[key, default: []] += answer[key] as? [[String: Any]] ?? [] }
            more = answer["more"] as? Bool ?? false
            guard let next = answer["storeSeq"] as? Int else { early = more; break }
            if more, next <= seq { early = true; break } // a host that doesn't move on
            seq = next
        }
        early = early || more   // the page cap
        // Stopped early: never past an object whose project may still be on a later page; it comes again next round.
        // All pages read: a project that never came won't come by rewinding, so move on (else every round re-reads all).
        guard live() else { return }
        let unapplied = apply(all, host: host)
        state.storeSeq = early ? unapplied.map { min(seq, $0 - 1) } ?? seq : seq
    }

    private func pull(_ session: HostSession, host: Deliver.Host, live: () -> Bool = { true }) async throws {
        let first = state.logSeq == 0 // (never pulled from this host: its whole log is history; once() sets lastSync before this)
        let answer = try await ReviewPublish.pages(state.logSeq) { try await session.ask(["op": "pull", "since": $0]) }
        guard live() else { return }
        let entries = answer["entries"] as? [[String: Any]] ?? []
        if !entries.isEmpty {
            store.applying = true
            for project in store.projects { publish.merge(entries, project: project.id) }
            store.applying = false
            // Clients' uploads become assets on the NAS (§13.25), as they arrive: a Mac reading the log from the start doesn't
            // bring back what was removed since. Only a host that serves them (4.0.4); not while `applying` (they go to the host).
            if !first, publish.host(host.id)?.outageLevel == 1 { publish.referenceUploads(entries, host: host) }
        }
        _ = try? await session.ask(["op": "local-time", "offset": TimeZone.current.secondsFromGMT()]) // the delivery folder's day (§13.25)
        if let seq = answer["seq"] as? Int { state.logSeq = seq }
    }

    /// `changes` into the store, rule M per object; the lowest seq of a folder or asset whose project isn't here.
    @discardableResult
    func apply(_ answer: [String: Any], host: Deliver.Host) -> Int? {
        var unapplied: Int?
        func missing(_ project: UUID, _ wire: [String: Any]) -> Bool {
            guard store.project(project) == nil else { return false }
            unapplied = min(unapplied ?? Int.max, wire["seq"] as? Int ?? 1)
            return true
        }
        for meta in answer["projects"] as? [[String: Any]] ?? [] { if let project = Self.project(meta) { store.applyMeta(project) } }
        for wire in answer["folders"] as? [[String: Any]] ?? [] {
            if let project = (wire["project"] as? String).flatMap(UUID.init(uuidString:)), !missing(project, wire), let folder = Self.folder(wire) { store.applyFolder(folder, project: project) }
        }
        for wire in answer["assets"] as? [[String: Any]] ?? [] {
            if let project = (wire["project"] as? String).flatMap(UUID.init(uuidString:)), !missing(project, wire), let asset = Self.asset(wire, host: host) { store.applyAsset(asset, project: project) }
        }
        for wire in answer["links"] as? [[String: Any]] ?? [] { if let link = Self.link(wire) { store.applyLink(link) } }
        for wire in answer["removed"] as? [[String: Any]] ?? [] {
            guard let data = try? JSONSerialization.data(withJSONObject: wire), let tombstone = try? Deliver.decoder.decode(Deliver.Tombstone.self, from: data) else { continue }
            let project = tombstone.project
            if let name = store.applyTombstone(tombstone), let project {
                store.addInbox(.init(project: project, asset: tombstone.id, version: tombstone.id, kind: "removed",
                                     summary: String(localized: "\(name) was removed on \(Self.deviceName(tombstone.by, host: host))"), author: ""))
            }
        }
        return unapplied
    }

    private static func deviceName(_ by: String, host: Deliver.Host) -> String {
        by == "admin" ? String(localized: "the admin page") : by.hasPrefix("host:") ? host.name : String(localized: "another Mac")
    }

    // MARK: - Wire forms back into the model

    private static func date(_ value: Any?) -> Date? { (value as? String).flatMap { ISO8601DateFormatter().date(from: $0) } }
    private static func uuid(_ value: Any?) -> UUID? { (value as? String).flatMap(UUID.init(uuidString:)) }
    private static func stamp<T: DeliverRevised>(_ object: inout T, _ wire: [String: Any]) {
        object.rev = wire["rev"] as? Int
        object.at = date(wire["at"])
        object.by = wire["by"] as? String
    }

    static func project(_ wire: [String: Any]) -> Deliver.Project? {
        guard let id = uuid(wire["id"]), let name = wire["name"] as? String else { return nil }
        var project = Deliver.Project(id: id, name: name, created: date(wire["created"]) ?? .now, cover: uuid(wire["cover"]),
                                      order: wire["order"] as? Int, deadline: date(wire["deadline"]))
        project.hidden = (wire["hidden"] as? Bool) == true ? true : nil
        stamp(&project, wire)
        return project
    }

    static func folder(_ wire: [String: Any]) -> Deliver.Folder? {
        guard let id = uuid(wire["id"]), let name = wire["name"] as? String else { return nil }
        var folder = Deliver.Folder(id: id, name: name, parent: uuid(wire["parent"]))
        stamp(&folder, wire)
        return folder
    }

    /// A host's asset: a version on a NAS mount here gets that local path; otherwise it's known by the host's path.
    static func asset(_ wire: [String: Any], host: Deliver.Host) -> Deliver.Asset? {
        guard let id = uuid(wire["id"]), let name = wire["name"] as? String, let kind = (wire["kind"] as? String).flatMap(Deliver.Kind.init(rawValue:)) else { return nil }
        let versions = (wire["versions"] as? [[String: Any]] ?? []).compactMap { item -> Deliver.Version? in
            guard let vid = uuid(item["id"]), let number = item["number"] as? Int else { return nil }
            let path: String
            if let source = item["source"] as? String {
                path = ReviewPublish.local(source, on: host) ?? ReviewPublish.nasPath(host: host.id, path: source)
            } else {
                path = "host:\(host.id.uuidString):\(vid.uuidString)"
            }
            var version = Deliver.Version(id: vid, number: number, path: path, size: (item["size"] as? NSNumber)?.int64Value ?? 0, added: date(item["added"]) ?? .now)
            if let duration = item["duration"] as? Double, let num = item["fpsNum"] as? Int, let den = item["fpsDen"] as? Int {
                version.probe = .init(duration: duration, fpsNum: num, fpsDen: den, width: item["width"] as? Int ?? 0, height: item["height"] as? Int ?? 0,
                                      startTimecode: item["startTimecode"] as? String ?? "00:00:00:00", dropFrame: item["dropFrame"] as? Bool ?? false,
                                      hasAudio: true, frames: item["frames"] as? Int ?? 1)
            }
            if let renditions = item["renditions"] as? [String], !renditions.isEmpty { version.copy = .ready(renditions) }
            version.pages = item["pages"] as? Int
            version.sha256 = item["sha256"] as? String
            version.hostOriginal = item["original"] as? String
            return version
        }
        guard !versions.isEmpty else { return nil }
        var fields: Deliver.Fields?
        if let json = wire["fields"], let data = try? JSONSerialization.data(withJSONObject: json) { fields = try? Deliver.decoder.decode(Deliver.Fields.self, from: data) }
        var asset = Deliver.Asset(id: id, name: name, folder: uuid(wire["folder"]), kind: kind,
                                  status: (wire["status"] as? String).map(Deliver.Status.init(rawValue:)) ?? .none, versions: versions,
                                  created: date(wire["created"]) ?? .now, fields: fields)
        let custom = ((wire["fields"] as? [String: Any]) ?? [:]).compactMap { key, value -> (String, String)? in
            guard key.hasPrefix("cf:"), let value = value as? String else { return nil }
            return (String(key.dropFirst(3)), value)
        }
        if !custom.isEmpty { asset.customFields = Dictionary(custom, uniquingKeysWith: { a, _ in a }) }
        if asset.fields?.isEmpty == true { asset.fields = nil }
        stamp(&asset, wire)
        return asset
    }

    /// A host's link (its key stays on the Mac that made it: elsewhere it shows "Made on <device>").
    static func link(_ wire: [String: Any]) -> Deliver.ShareLink? {
        guard let id = uuid(wire["id"]), let room = wire["roomID"] as? String, let project = uuid(wire["project"]),
              let root = wire["root"] as? [String: Any], let kind = root["kind"] as? String else { return nil }
        let scope: Deliver.Scope
        switch kind {
        case "project": scope = .project(project)
        case "folder": guard let folder = uuid(root["id"]) else { return nil }; scope = .folder(folder, project: project)
        case "asset": guard let asset = uuid(root["id"]) else { return nil }; scope = .asset(asset, project: project)
        case "assets": scope = .assets((root["assets"] as? [String] ?? []).compactMap(UUID.init(uuidString:)), project: project)
        default: return nil
        }
        var link = Deliver.ShareLink(id: id, title: wire["title"] as? String ?? "", scope: scope, roomID: room,
                                     mode: (wire["mode"] as? String).flatMap(Deliver.ShareLink.Mode.init(rawValue:)) ?? .review,
                                     allowDownload: wire["allowDownload"] as? Bool ?? false, latestOnly: wire["latestOnly"] as? Bool ?? false,
                                     expires: date(wire["expires"]), passwordHash: wire["passwordHash"] as? String,
                                     created: date(wire["created"]) ?? .now, revoked: date(wire["revoked"]))
        link.description = wire["description"] as? String
        link.layout = (wire["layout"] as? String).flatMap { $0 == "grid" ? nil : $0 }
        link.requireName = (wire["requireName"] as? Bool) == true ? true : nil
        link.askEmail = (wire["askEmail"] as? Bool) == true ? true : nil
        link.allowProxy = (wire["allowProxy"] as? Bool) == true ? true : nil
        link.audience = (wire["audience"] as? String).flatMap { $0 == "client" ? nil : $0 }
        link.recipient = wire["recipient"] as? String
        link.fields = (wire["fields"] as? [String]).flatMap { $0 == ["status"] ? nil : $0 }
        link.featuredField = (wire["featuredField"] as? String).flatMap { $0 == "status" ? nil : $0 } ?? (wire["featuredField"] is NSNull ? "none" : nil)
        if link.mode != .review, link.featuredField == "none" { link.featuredField = nil }
        link.paused = (wire["paused"] as? Bool) == true ? true : nil
        link.deadline = date(wire["deadline"])
        link.madeOn = wire["madeOn"] as? String
        link.order = (wire["order"] as? [String]).map { $0.compactMap(UUID.init(uuidString:)) }
        link.customStatuses = (wire["customStatuses"] as? Bool) == true ? true : nil
        if let mark = wire["watermark"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: mark) {
            link.watermark = try? Deliver.decoder.decode(Deliver.ShareLink.Watermark.self, from: data)
        }
        if let uploads = wire["uploads"] as? [String: Any] {
            link.uploads = .init(folder: uuid(uploads["folder"]), maxBytes: (uploads["maxBytes"] as? NSNumber)?.int64Value ?? 21_474_836_480,
                                 types: uploads["types"] as? [String] ?? ["video", "audio", "image", "document", "other"])
        }
        stamp(&link, wire)
        return link
    }

    // MARK: - Moving the review data to a NAS (and back)

    /// Steps 2–5 of §13.1's migration; each can run again (an interrupted move continues on the next launch).
    func migrate(to host: Deliver.Host) async throws {
        // Another NAS: its seqs start again. The outbox stays and goes to the new one at the end (nothing unsent is lost).
        if state.host != host.id { state = State(host: host.id) }
        saveState()
        store.journal = { [weak self] in self?.write($0) }
        store.stampUnrevised(by: DeliverMerge.device)
        try await ReviewHostClient.session(host) { session in
            for project in self.store.projects {
                let (json, _) = self.publish.manifest(project: project.id, only: nil, host: host)
                try await self.pushFiles(session, project: project.id, manifest: json, host: host)
                // Every link of the project, dead ones too (their state syncs as well).
                let all = Set(self.store.links.filter { $0.project == project.id }.map(\.id))
                let withLinks = self.publish.manifest(project: project.id, only: nil, host: host, onlyLinks: all).json
                _ = try await session.ask(["op": "publish", "merge": true, "manifest": withLinks,
                                           "remove": ["projects": [Any](), "links": [Any]()], "tombstones": [Any]()])
            }
            var entries: [[String: Any]] = []
            for project in self.store.projects {
                entries += self.publish.entries(project: project.id, only: nil)
                for approval in self.store.approvals(project.id) {
                    if let data = try? Deliver.encoder.encode(approval), let json = try? JSONSerialization.jsonObject(with: data) { entries.append(["approval": json]) }
                }
            }
            for link in self.store.links {
                for activity in self.store.activity(link.id) {
                    if let data = try? Deliver.encoder.encode(activity), let json = try? JSONSerialization.jsonObject(with: data) { entries.append(["activity": json]) }
                }
            }
            for start in stride(from: 0, to: entries.count, by: 500) {
                _ = try await session.ask(["op": "append", "entries": Array(entries[start..<min(start + 500, entries.count)])])
            }
            try await self.flush(session, host: host)
        }
        state.migrated = state.migrated ?? .now
        saveState()
        start()
    }

    /// "This Mac": syncing stops; the NAS keeps what it has.
    func stop() {
        loop?.cancel()
        poll?.cancel()
        soon?.cancel()
        refreshing = nil   // an old host's refresh still running can't write its seqs into the next host's state
        store.journal = nil
        state = State()
        saveState()
        try? FileManager.default.removeItem(at: outboxFile)
        waiting = 0
    }

    /// Picked as the data host, but the move didn't finish: it continues (at launch).
    func resume() {
        guard let host = dataHost else { return }
        if state.migrated == nil, !manual { Task { try? await migrate(to: host) } } else { start() }
    }

    // MARK: - The sidebar footer

    var footer: String? { footer(onlyHere: 0, uploading: 0) }

    /// Never "Synced" alone while originals are still only here or on their way: that would say the video is on the NAS.
    func footer(onlyHere: Int, uploading: Int) -> String? {
        guard let host = dataHost else { return nil }
        if let problem { return String(localized: "Can’t sync: \(problem)") }
        if waiting > 0 || state.lastSync == nil { return String(localized: "Offline · \(waiting) changes waiting") }
        if uploading > 0 { return String(localized: "Synced · \(uploading) uploading") }
        if onlyHere > 0 { return String(localized: "Synced · \(onlyHere) only on this Mac") }
        return String(localized: "Synced with \(host.name) · \(state.lastSync!.formatted(.relative(presentation: .named)))")
    }
}
