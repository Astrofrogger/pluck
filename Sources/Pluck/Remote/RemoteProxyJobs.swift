import CryptoKit
import Foundation

/// Proxies of a selection on the host Mac: a folder or some files inside a share (not only whole
/// shares), H.265 or ProRes Proxy, made one file at a time into the same place as OfficeProxies'
/// (so `fileData` kind proxy finds them), with the original's name, timecode, reel and audio
/// channels. Watched folders keep getting proxies for new files. Also the manifest of a share's
/// ready proxies, each with its checksum (worked out once and kept).
@MainActor
@Observable
final class RemoteProxyJobs {
    static let shared = RemoteProxyJobs()
    private static let key = "remoteProxyRequests"

    struct Request: Codable, Identifiable, Hashable {
        enum State: String, Codable { case queued, making, ready, failed }
        var id = UUID()
        /// The share's id (OfficeProxies.id).
        var share: String
        /// Folders or files, relative to the share ("" = all of it).
        var paths: [String]
        var format: OfficeProxies.Format
        /// The paired Mac that asked (nil: a watched folder on this Mac, or asked here when `byHost`).
        var device: UUID?
        /// Asked on this Mac (Proxies → Make proxies of a folder). (Optional: requests saved before decode.)
        var byHost: Bool?
        var asked = Date.now
        var state = State.queued
        var total = 0
        var done = 0
        var failed: [String] = []
        var problem: String?
        /// Taken from another office Mac's queue on the NAS (OfficeGroup): that Mac's name.
        var peer: String?

        var watch: Bool { device == nil && byHost != true && peer == nil }
    }

    private(set) var requests: [Request] = []
    /// The request and file being made now, and how far along that file is.
    private(set) var current: UUID?
    private(set) var working: String?
    private(set) var progress = 0.0

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    /// Manifest entries by proxy path, kept while the proxy is unchanged (size + date).
    @ObservationIgnored private var cache: [String: Cached] = [:]
    @ObservationIgnored private var cacheLoaded = false

    private struct Cached: Codable {
        var size: Int64
        var modified: Date
        var entry: RemoteManifestEntry
    }

    private init() {
        // What was under way when Pluck quit starts again.
        requests = OfficeProxies.Format.load(Self.key).map { (request: Request) in
            var request = request
            if request.state == .making { request.state = .queued }
            return request
        }
    }

    private func save() {
        OfficeProxies.Format.save(requests, key: Self.key) { $0.format }
    }

    /// Snapshot scenes only: these requests shown (`current` being made at `progress`), nothing stored or run.
    func showSample(_ sample: [Request], current: UUID?, working: String?, progress: Double) {
        guard ScreenshotMode.scene != nil else { return }
        requests = sample
        self.current = current
        self.working = working
        self.progress = progress
    }

    // MARK: - Actions for paired Macs

    static func register() {
        OfficeActions.register("shareProxyMake") { arguments, device in
            // (No base-role check: each path is checked in its folder below, where a folder role may give more.)
            let (root, id) = try RemoteEditHost.share(arguments["share"])
            let format = try format(arguments["format"])
            guard let asked = arguments["paths"] as? [Any], !asked.isEmpty, asked.count <= 5000 else { throw OfficeActions.incomplete() }
            let paths = try asked.map { try OfficeActions.text($0, empty: true) }
            // Each must be in the share (the checks of RemoteEditHost.resolve), kept by its share path, and allowed there.
            let checked = try await Task.detached {
                try paths.map { path in
                    RemoteEditHost.relative(try RemoteEditHost.resolve(path, in: root), in: root)
                }
            }.value
            guard checked.allSatisfy({ OfficeActions.allowed(\.proxies, device, share: (root, id), relative: $0) }) else { throw OfficeActions.refused() }
            let request = shared.add(Request(share: id, paths: checked, format: format, device: device.id))
            return ["request": summary(request)]
        }
        OfficeActions.register("shareProxyStatus") { arguments, device in
            let mine = shared.requests.filter { $0.device == device.id }
            if let id = arguments["id"] as? String {
                guard let request = mine.first(where: { $0.id.uuidString == id }) else {
                    throw OfficeLink.Failure.office(String(localized: "That proxy request isn’t on the host Mac any more."))
                }
                return ["request": summary(request)]
            }
            return ["requests": mine.suffix(50).map(summary)]
        }
        OfficeActions.register("shareManifest") { arguments, device in
            let (root, id) = try RemoteEditHost.share(arguments["share"])
            let folder = try OfficeActions.require(\.proxies, device, share: (root, id), path: try OfficeActions.text(arguments["path"] ?? "", empty: true))
            // (Clips in folders this Mac may not have proxies of are left out: OfficeAccess folder roles.)
            let entries = try await shared.manifest(root: root, share: id, under: folder, format: try format(arguments["format"]))
                .filter { OfficeActions.allowed(\.proxies, device, share: (root, id), relative: $0.path) }
            OfficeProxies.shared.used(id, format: try format(arguments["format"]))
            let list = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entries))
            return ["share": id, "shareName": root.lastPathComponent, "office": Host.current().localizedName ?? "Mac", "entries": list,
                    "pending": shared.pending(share: id, format: try format(arguments["format"]))]
        }
        OfficeActions.register("shareWatch") { arguments, device in
            let place = try RemoteEditHost.share(arguments["share"]), root = place.root
            let format = try format(arguments["format"])
            let path = try OfficeActions.text(arguments["path"] ?? "", empty: true)
            let checked = RemoteEditHost.relative(try OfficeActions.require(\.proxies, device, share: place, path: path), in: root)
            let watch = RemoteShares.Watch(path: checked, format: format)
            if arguments["on"] as? Bool ?? true { RemoteShares.shared.addWatch(watch.path, format: format, in: root) }
            else { RemoteShares.shared.removeWatch(watch, in: root) }
            return ["on": RemoteShares.shared.share(root)?.watch.contains(watch) ?? false]
        }
        RemotePieces.register()
        RemoteKeepAwake.start()
        shared.startWatching()
        Task { await RemoteShares.shared.sync() }
    }

    private static func format(_ value: Any?) throws -> OfficeProxies.Format {
        guard let format = OfficeProxies.Format(rawValue: value as? String ?? "light"), format != .original else { throw OfficeActions.incomplete() }
        return format
    }

    static func summary(_ request: Request) -> [String: Any] {
        var item: [String: Any] = ["id": request.id.uuidString, "share": request.share, "paths": request.paths, "format": request.format.rawValue,
                                   "state": request.state.rawValue, "total": request.total, "done": request.done, "failed": request.failed,
                                   "asked": request.asked.timeIntervalSince1970]
        if let problem = request.problem { item["problem"] = problem }
        if shared.current == request.id {
            if let working = shared.working { item["working"] = working }
            item["progress"] = shared.progress
        }
        return item
    }

    // MARK: - Requests

    @discardableResult
    func add(_ request: Request) -> Request {
        // The same selection asked again joins the one already there.
        if let index = requests.firstIndex(where: { $0.share == request.share && $0.paths == request.paths && $0.format == request.format
                                                    && $0.device == request.device && $0.byHost == request.byHost }) {
            if requests[index].state != .making { requests[index].state = .queued }
            requests[index].asked = .now
            save()
            run()
            return requests[index]
        }
        requests.append(request)
        OfficeGroup.shared.publish(request)
        // Old finished requests go (watched folders stay).
        let finished = requests.filter { !$0.watch && ($0.state == .ready || $0.state == .failed) }
        if finished.count > 100 { requests.removeAll { finished.prefix(finished.count - 100).contains($0) } }
        save()
        run()
        return request
    }

    /// Proxies of a share still to be made in this format (a queued request not looked through yet counts one).
    func pending(share: String, format: OfficeProxies.Format) -> Int {
        requests.filter { $0.share == share && $0.format == format && ($0.state == .queued || $0.state == .making) }
            .reduce(0) { $0 + ($1.state == .queued && $1.total == 0 ? 1 : max($1.total - $1.done - $1.failed.count, 0)) }
    }

    /// Removes a request; one being made stops before its next file.
    /// shortcut: the file being encoded finishes first (ffmpeg isn't cancelled), cancel the encode if that's too slow.
    func remove(_ id: UUID) {
        requests.removeAll { $0.id == id }
        OfficeGroup.shared.unpublish(id)
        save()
    }

    /// The group's queue on the NAS (OfficeGroup.scanQueue): other office Macs' jobs taken on here, copies of jobs gone
    /// from it dropped (unless being made), and jobs finished here taken off it. `all`: every job in the queue.
    func take(_ jobs: [OfficeGroup.Job], all: Set<UUID>) {
        var changed = false
        let before = requests.count
        requests.removeAll { $0.peer != nil && !all.contains($0.id) && $0.state != .making }
        changed = requests.count != before
        for request in requests where (request.state == .ready || request.state == .failed) && all.contains(request.id) {
            OfficeGroup.shared.unpublish(request.id)
        }
        for job in jobs where !requests.contains(where: { $0.id == job.id }) {
            // (Only shares this Mac has too, paths checked again when it's made: RemoteEditHost.resolve.)
            guard let share = try? RemoteEditHost.share(job.share).id else { continue }
            requests.append(Request(id: job.id, share: share, paths: job.paths, format: job.format, device: job.device,
                                    asked: job.asked, peer: job.from))
            changed = true
        }
        guard changed else { return }
        save()
        run()
    }

    /// Every watched folder of every share as a request, looked through again: new files get proxies.
    func refreshWatches() {
        for folder in OfficeArchive.shared.folders {
            for watch in RemoteShares.shared.share(folder)?.watch ?? [] {
                add(Request(share: OfficeProxies.id(folder), paths: [watch.path], format: watch.format, device: nil))
            }
        }
    }

    func dropWatch(share: String, _ watch: RemoteShares.Watch) {
        for request in requests where request.watch && request.share == share && request.paths == [watch.path] && request.format == watch.format
            && request.state != .making { OfficeGroup.shared.unpublish(request.id) }
        requests.removeAll { $0.watch && $0.share == share && $0.paths == [watch.path] && $0.format == watch.format && $0.state != .making }
        save()
    }

    /// Watched folders looked through every few minutes while the host shares.
    private func startWatching() {
        guard watcher == nil else { return }
        watcher = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                if OfficeRenderServer.shared.isRunning, ScreenshotMode.scene == nil { refreshWatches() }
            }
        }
    }

    // MARK: - Making them

    func run() {
        guard task == nil, requests.contains(where: { $0.state == .queued }) else { return }
        task = Task {
            defer { task = nil; current = nil; working = nil }
            while let next = requests.first(where: { $0.state == .queued }), !Task.isCancelled {
                await make(next.id)
            }
        }
    }

    private func set(_ id: UUID, _ change: (inout Request) -> Void) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        change(&requests[index])
    }

    private func make(_ id: UUID) async {
        guard let request = requests.first(where: { $0.id == id }) else { return }
        current = id
        progress = 0
        set(id) { $0.state = .making; $0.failed = []; $0.problem = nil }
        func fail(_ problem: String) {
            set(id) { $0.state = .failed; $0.problem = problem }
            save()
        }
        guard let ffmpeg = OfficeRenderServer.shared.manager?.tool("ffmpeg") else { return fail(Converting.Failure.noFFmpeg.localizedDescription) }
        guard let ffprobe = OfficeRenderServer.shared.manager?.tool("ffprobe") else {
            return fail(String(localized: "ffmpeg isn’t fully installed on the host Mac, so proxies can’t be made."))
        }
        guard let root = try? RemoteEditHost.share(request.share).root else {
            return fail(String(localized: "That folder isn’t shared on the host Mac any more."))
        }
        guard await RemoteShares.shared.state(root).online else {
            return fail(String(localized: "The shared folder isn’t reachable on the host Mac right now."))
        }
        let inbox = OfficeInbox.shared.folder, watch = request.watch
        // The videos in the selection, by share path; a watched folder leaves out files still being copied.
        let files = await Task.detached { () -> [String] in
            var found: [String] = []
            for path in request.paths {
                guard let item = try? RemoteEditHost.resolve(path, in: root) else { continue }
                for video in RemoteEditHost.clips(in: item, skipping: inbox) {
                    if watch, let date = try? video.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                       Date.now.timeIntervalSince(date) < 60 { continue }
                    found.append(RemoteEditHost.relative(URL(fileURLWithPath: RemoteEditHost.realPath(video.path) ?? video.path), in: root))
                }
            }
            return Array(Set(found)).sorted()
        }.value
        let target = { (relative: String) in OfficeProxies.shared.proxy(relative, folder: request.share, format: request.format) }
        let missing = files.filter { !FileManager.default.fileExists(atPath: target($0).path) }
        set(id) { $0.total = files.count; $0.done = files.count - missing.count }
        save()
        // Clips another office Mac is making come again at the end (and again, until made or let go).
        var waiting = missing, round = 0
        while !waiting.isEmpty, !Task.isCancelled {
          let pass = waiting
          waiting = []
          if round > 0 {
              try? await Task.sleep(for: .seconds(15))
              guard requests.contains(where: { $0.id == id }) else { return }
          }
          round += 1
          for relative in pass where !Task.isCancelled {
            // A render has the Mac to itself; the whole-folder proxies go one at a time with these.
            while OfficeRenderServer.shared.isRendering, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
            }
            guard requests.contains(where: { $0.id == id }) else { return }
            working = (relative as NSString).lastPathComponent
            progress = 0
            // (One encode at a time with OfficeProxies' own: makeClaimed waits its turn.)
            guard let made = await OfficeProxies.shared.makeClaimed(root.appendingPathComponent(relative), to: target(relative), format: request.format,
                                                                    ffmpeg: ffmpeg, ffprobe: ffprobe, look: OfficeLook.setting(request.share), progress: { value in
                Task { @MainActor in RemoteProxyJobs.shared.progress = value }
            }) else {
                waiting.append(relative)
                continue
            }
            if made {
                set(id) { $0.done += 1 }
                _ = await entry(root: root, share: request.share, relative: relative, format: request.format)
                saveCache()
            } else {
                let mismatch = OfficeProxies.mismatches.withLock { $0.removeValue(forKey: target(relative).path) }
                set(id) { $0.failed.append(relative); if let mismatch { $0.problem = mismatch } }
            }
            save()
          }
        }
        working = nil
        set(id) { request in
            request.state = request.failed.isEmpty ? .ready : .failed
            if !request.failed.isEmpty, request.problem == nil { request.problem = String(localized: "Some files couldn’t be made into proxies.") }
        }
        save()
    }

    // MARK: - Manifest

    /// The ready proxies of the videos under `folder` (a folder or one file in the share).
    func manifest(root: URL, share: String, under folder: URL, format: OfficeProxies.Format) async throws -> [RemoteManifestEntry] {
        let inbox = OfficeInbox.shared.folder
        let files = await Task.detached { () -> [String] in
            let videos = RemoteEditHost.isDirectory(folder) ? RemoteEditHost.clips(in: folder, skipping: inbox) : [folder]
            return videos.map { RemoteEditHost.relative(URL(fileURLWithPath: RemoteEditHost.realPath($0.path) ?? $0.path), in: root) }.sorted()
        }.value
        var entries: [RemoteManifestEntry] = []
        for relative in files {
            if let entry = await entry(root: root, share: share, relative: relative, format: format) { entries.append(entry) }
        }
        saveCache()
        return entries
    }

    /// One ready proxy's entry, from the cache while the proxy is unchanged, else worked out
    /// (details of the original, SHA-256 of the proxy). nil when the proxy isn't made.
    func entry(root: URL, share: String, relative: String, format: OfficeProxies.Format) async -> RemoteManifestEntry? {
        loadCache()
        let proxy = OfficeProxies.shared.proxy(relative, folder: share, format: format)
        guard let values = try? proxy.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
        if let cached = cache[proxy.path], cached.size == Int64(size), cached.modified == modified,
           cached.entry.share == share, cached.entry.path == relative { return cached.entry }
        let original = root.appendingPathComponent(relative)
        let info = (try? await RemoteEditHost.mediaInfo(original)) ?? [:]
        let ffprobe = OfficeRenderServer.shared.manager?.tool("ffprobe")
        let (reel, checksum, look) = await Task.detached {
            (OfficeProxies.probe(original, ffprobe: ffprobe).3, Self.checksum(proxy), OfficeLook.tagged(proxy, ffprobe: ffprobe))
        }.value
        let entry = RemoteManifestEntry(share: share, path: relative, proxy: OfficeProxies.shared.proxyName(relative, folder: share),
                                        reel: reel ?? original.deletingPathExtension().lastPathComponent,
                                        timecode: info["timecode"] as? String, duration: info["duration"] as? Double,
                                        fps: info["fps"] as? Double, audioChannels: info["audioChannels"] as? Int,
                                        size: Int64(size), checksum: checksum, look: look)
        cache[proxy.path] = Cached(size: Int64(size), modified: modified, entry: entry)
        return entry
    }

    /// SHA-256 of a file, hex, read in pieces.
    nonisolated static func checksum(_ file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hash = SHA256()
        while let piece = try? handle.read(upToCount: 4 << 20), !piece.isEmpty { hash.update(data: piece) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static var cacheFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/Edit Anywhere/Manifest.json")
    }

    private func loadCache() {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        cache = (try? JSONDecoder().decode([String: Cached].self, from: Data(contentsOf: Self.cacheFile))) ?? [:]
    }

    private func saveCache() {
        // Entries of proxies that are gone (tidied, removed) go too.
        cache = cache.filter { FileManager.default.fileExists(atPath: $0.key) }
        try? FileManager.default.createDirectory(at: Self.cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: Self.cacheFile, options: .atomic) }
    }
}
