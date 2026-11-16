import Foundation
import UserNotifications

/// New versions from a watched render folder (§13.4): a file like "Hero 30s_v4.mov" that's stable for 10 s and
/// matches an asset at a lower number is offered once, as a notification. Nothing happens without OK.
@MainActor
@Observable
final class DeliverWatch {
    static let shared = DeliverWatch(store: .shared)
    static let foundKey = "deliverFound"

    struct Watch: Codable, Identifiable, Hashable {
        var id = UUID()
        var project: UUID
        var folder: UUID?
        var local: String?
        var nas: NASPath?
        var bookmark: Data?
        var seen: [String]?
        struct NASPath: Codable, Hashable { var host: UUID; var path: String }
    }

    /// A file found and offered (by its path), until it's shared or the asset changes.
    struct Found: Codable, Identifiable, Hashable {
        var id: String { path }
        var path: String                 // local path, or "nas:<host>:<media path>"
        var asset: UUID
        var number: Int
        var size: Int64
    }

    let store: DeliverStore
    private(set) var watches: [Watch] = []
    /// Offered and not shared yet: the asset card's chip, "v4 found · Share".
    private(set) var found: [Found] = []
    @ObservationIgnored private var observed: [String: (size: Int64, modified: Date, at: Date)] = [:]
    @ObservationIgnored private var sources: [UUID: DispatchSourceFileSystemObject] = [:]
    @ObservationIgnored private var timer: Task<Void, Never>?
    /// Versions shared from a watch whose copy isn't ready yet: announced to browsers once it is.
    @ObservationIgnored private var announce: Set<UUID> = []
    /// Tests: the notification instead of posting it.
    @ObservationIgnored var posted: ((Found, String, String) -> Void)?

    init(store: DeliverStore) {
        self.store = store
        watches = (try? Data(contentsOf: file)).flatMap { try? Deliver.decoder.decode([Watch].self, from: $0) } ?? []
        found = (try? Data(contentsOf: foundFile)).flatMap { try? Deliver.decoder.decode([Found].self, from: $0) } ?? []
        store.listeners.append { [weak self] event in
            if case .assetChanged(let id) = event { self?.copyMaybeReady(id) }
        }
    }

    private var file: URL { store.root.appendingPathComponent("watches.json") }
    private var foundFile: URL { store.root.appendingPathComponent("watches-found.json") }
    private func save() {
        try? FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try? Deliver.encoder.encode(watches).write(to: file, options: .atomic)
        try? Deliver.encoder.encode(found).write(to: foundFile, options: .atomic)
    }

    // MARK: - Detection (pure: the self-test checks these)

    /// `(key, n)` of a file stem: "Hero 30s_v2" → ("hero30s", 2); nil when it carries no version at its end.
    nonisolated static func parse(_ stem: String) -> (key: String, number: Int)? {
        guard let match = stem.wholeMatch(of: #/(?i)^(.*?)[ _.\-]*v(\d{1,3})$/#), let number = Int(match.2) else { return nil }
        let key = key(String(match.1))
        return key.isEmpty ? nil : (key, number)
    }

    nonisolated static func key(_ text: String) -> String {
        text.lowercased().filter { ![" ", "_", "-", "."].contains($0) }
    }

    /// Hidden, partial and tiny files (under 1 MB) are never offered.
    nonisolated static func candidate(_ name: String, size: Int64) -> Bool {
        let lower = name.lowercased()
        return !name.hasPrefix(".") && !lower.hasSuffix(".part") && !lower.hasSuffix(".tmp") && !lower.hasSuffix(".download") && size >= 1_000_000
    }

    /// The asset a file is the next version of: same key, and a lower number than the file's.
    nonisolated static func match(_ stem: String, in assets: [Deliver.Asset]) -> (asset: Deliver.Asset, number: Int)? {
        guard let (key, number) = parse(stem) else { return nil }
        for asset in assets {
            let currentStem = URL(fileURLWithPath: asset.current.path).deletingPathExtension().lastPathComponent
            if let current = parse(currentStem), current.key == key, current.number < number { return (asset, number) }
            if Self.key(parse(asset.name)?.key ?? asset.name) == key, asset.current.number < number { return (asset, number) }
        }
        return nil
    }

    /// Stable: the same size and modified time as an observation at least 10 s earlier.
    func stable(_ path: String, size: Int64, modified: Date, now: Date = .now) -> Bool {
        if let before = observed[path], before.size == size, before.modified == modified {
            return now.timeIntervalSince(before.at) >= 10
        }
        observed[path] = (size, modified, now)
        return false
    }

    // MARK: - Watching

    func add(_ watch: Watch) {
        watches.removeAll { $0.local != nil && $0.local == watch.local && $0.project == watch.project }
        watches.append(watch)
        save()
        start()
    }

    func remove(_ id: UUID) {
        watches.removeAll { $0.id == id }
        sources.removeValue(forKey: id)?.cancel()
        save()
    }

    /// Local folders (SMB mounts too) by file-system events and a 10 s check; NAS paths by `browse` every 2 min.
    func start() {
        guard ScreenshotMode.scene == nil else { return }
        for watch in watches where watch.local != nil && sources[watch.id] == nil {
            let fd = open(watch.local!, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: .main)
            let id = watch.id
            source.setEventHandler { [weak self] in Task { @MainActor in await self?.scan(id) } }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources[watch.id] = source
        }
        guard timer == nil else { return }
        timer = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                tick += 1
                guard let self else { return }
                for watch in self.watches where watch.local != nil || tick % 12 == 0 { await self.scan(watch.id) }
            }
        }
    }

    func scan(_ id: UUID) async {
        guard let watch = watches.first(where: { $0.id == id }) else { return }
        var files: [(path: String, name: String, size: Int64, modified: Date)] = []
        if let local = watch.local {
            let items = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: local), includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])) ?? []
            for item in items {
                guard let values = try? item.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
                files.append((item.path, item.lastPathComponent, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast))
            }
        } else if let nas = watch.nas, let host = ReviewPublish.shared.host(nas.host) {
            for entry in (try? await ReviewHostClient.browse(host, path: nas.path)) ?? [] where !entry.folder {
                files.append((ReviewPublish.nasPath(host: host.id, path: entry.path), entry.name, entry.size ?? 0, entry.modified ?? .distantPast))
            }
        }
        consider(files, watch: watch)
    }

    /// Files listed in a watched folder: each stable, matching one is offered once.
    func consider(_ files: [(path: String, name: String, size: Int64, modified: Date)], watch: Watch, now: Date = .now) {
        guard let index = watches.firstIndex(where: { $0.id == watch.id }) else { return }
        var seen = Set(watches[index].seen ?? [])
        let assets = store.content(watch.project).assets.filter { watch.folder == nil || $0.folder == watch.folder }
        for file in files where !seen.contains(file.path) && Self.candidate(file.name, size: file.size) {
            let stem = (file.name as NSString).deletingPathExtension
            guard let (asset, number) = Self.match(stem, in: assets), stable(file.path, size: file.size, modified: file.modified, now: now) else { continue }
            seen.insert(file.path)
            let item = Found(path: file.path, asset: asset.id, number: number, size: file.size)
            found.removeAll { $0.asset == asset.id }
            found.append(item)
            offer(item, name: asset.name)
        }
        watches[index].seen = Array(seen.suffix(5000))
        save()
    }

    private func offer(_ item: Found, name: String) {
        let title = String(localized: "New version of \(name)"), body = String(localized: "v\(item.number) is ready. Share it with the client?")
        if let posted { return posted(item, title, body) }
        guard ScreenshotMode.scene == nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Notifications.newVersionCategory
        content.userInfo = [Self.foundKey: item.path]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "review-found-" + item.asset.uuidString, content: content, trigger: nil))
    }

    // MARK: - OK and Not now

    /// "Not now": the chip on the asset card stays.
    func later(_ path: String) {}

    /// "Share with client": the next version; by reference on a NAS, uploaded to its uploads root when the data
    /// host is a NAS and the file isn't there, else its copies are made here and pushed.
    func accept(_ path: String) {
        guard let item = found.first(where: { $0.path == path }), let (_, asset) = store.find(item.asset) else { return }
        found.removeAll { $0.path == path }
        save()
        Task {
            let made: Deliver.Version?
            if ReviewPublish.browsed(path) != nil {
                made = try? store.addVersion(reference: path, size: item.size, to: asset.id)
            } else if let host = DeliverSync.shared.dataHost, ReviewPublish.reference(path, on: host) == nil,
                      let root = await DeliverUploads.writableRoot(host) {
                let folder = DeliverUploadDestination.suggested(host, root: root, project: store.find(asset.id)?.project ?? UUID(), store: store)
                _ = try? await ReviewHostClient.ask(host, ["op": "mkdir", "path": folder])
                let sent = try? await DeliverUploads.shared.upload(URL(fileURLWithPath: path), to: folder + "/" + URL(fileURLWithPath: path).lastPathComponent, host: host)
                made = sent.flatMap { try? store.addVersion(reference: ReviewPublish.nasPath(host: host.id, path: $0), size: item.size, to: asset.id) }
                    ?? (try? store.addVersion(URL(fileURLWithPath: path), to: asset.id))
            } else {
                made = try? store.addVersion(URL(fileURLWithPath: path), to: asset.id)
            }
            guard let made, let found = store.find(asset.id) else { return }
            store.addInbox(.init(project: found.project, asset: asset.id, version: made.id, kind: "shared",
                                 summary: String(localized: "Shared v\(made.number) of \(asset.name)"), author: DeliverSettings.author, read: true))
            // (A NAS makes a reference's copy and tells its browsers itself.)
            if ReviewPublish.browsed(made.path) == nil { announce.insert(made.id); copyMaybeReady(asset.id) }
        }
    }

    /// Once the shared version's copy is ready, browsers in scope hear `version-added`.
    private func copyMaybeReady(_ asset: UUID) {
        guard !announce.isEmpty, let found = store.find(asset)?.asset else { return }
        for version in found.versions where announce.contains(version.id) {
            guard case .ready = version.copy else { continue }
            announce.remove(version.id)
            DeliverServer.shared.versionAdded(found, version)
        }
    }
}
