import AppKit
import CryptoKit
import Foundation
import Observation

/// The host's proxy actions the browser and the pulls ask for (the host's side is RemoteProxyJobs /
/// RemoteShares). One place, so their names and answers are wired once.
@MainActor
enum RemotePullClient {
    static let proxiesAction = "shareProxyMake", watchAction = "shareWatch"
    /// (A test points it at its own.)
    static var manifestAction = "shareManifest"
    private static var client: OfficeRenderClient { .shared }

    /// {share, paths (share paths: files, or folders for everything in them), format} → started.
    /// The request's id (nil: a host that didn't say).
    @discardableResult
    static func makeProxies(share: String, paths: [String], format: OfficeProxies.Format) async throws -> String? {
        let answer = try await client.ask(proxiesAction, ["share": share, "paths": paths, "format": format.rawValue], timeout: 60)
        return (answer["request"] as? [String: Any])?["id"] as? String
    }

    /// {id} → how a proxy request of this Mac's is going: queued, making (progress 0…1 once the host is on its file), ready, failed.
    static func proxyRequest(_ id: String) async throws -> (state: String, total: Int, progress: Double?, problem: String?) {
        let request = try await client.ask("shareProxyStatus", ["id": id], timeout: 30)["request"] as? [String: Any] ?? [:]
        return (request["state"] as? String ?? "", (request["total"] as? NSNumber)?.intValue ?? 0,
                (request["progress"] as? NSNumber)?.doubleValue, request["problem"] as? String)
    }

    /// {share, path (a folder), format, on}: new files there get proxies by themselves.
    static func keepProxied(share: String, path: String, format: OfficeProxies.Format, on: Bool) async throws {
        _ = try await client.ask(watchAction, ["share": share, "path": path, "format": format.rawValue, "on": on], timeout: 60)
    }

    /// {share, path ("" = all of it), format} → entries [RemoteManifestEntry as JSON] of the proxies made so far,
    /// and pending (how many are still being made). The first manifest of a big share checksums its proxies: a long timeout.
    static func manifest(share: String, path: String = "", format: OfficeProxies.Format) async throws -> (entries: [RemoteManifestEntry], pending: Int) {
        let answer = try await client.ask(manifestAction, ["share": share, "path": path, "format": format.rawValue], timeout: 600)
        let entries = (answer["entries"] as? [[String: Any]] ?? []).compactMap { item in
            (try? JSONSerialization.data(withJSONObject: item)).flatMap { try? JSONDecoder().decode(RemoteManifestEntry.self, from: $0) }
        }
        return (entries, (answer["pending"] as? NSNumber)?.intValue ?? 0)
    }
}

/// Proxies (or single originals) pulled from the host's shares to a folder here: four files at
/// once, each in pieces from where it stopped, checked against the manifest's SHA-256 (fetched
/// again if it doesn't match), past a file that fails (tried again on the next pass), paused and
/// resumed, under a speed limit if one is set, carried on after a restart. Each share's folder
/// gets the share's RemoteManifest for the proxies in it. ProxySync stays for hosts from before.
@MainActor
@Observable
final class RemotePullManager {
    static let shared = RemotePullManager()
    private static let jobsKey = "editAnywherePulls", rootsKey = "editAnywherePullRoots", limitKey = "editAnywherePullLimit"
    /// Files fetched at once (each piece is a connection; the host takes 16 from all Macs).
    static let parallel = 4
    /// Tries per file in a pass before it waits for the next.
    static let tries = 3

    /// What's pulled: a share's proxies under some of its paths ("" for all of it), or originals.
    struct Job: Codable, Identifiable, Equatable, Sendable {
        var share: String
        var shareName: String
        var format: OfficeProxies.Format
        var paths: [String]
        var destination: String
        var paused = false
        /// Originals: the files themselves (no manifest: the host doesn't make anything).
        var originals: [RemoteManifestEntry]?
        var id: String { share + "|" + format.rawValue + "|" + paths.joined(separator: "\n") }
    }

    struct Progress: Equatable {
        var files = 0
        var filesHere = 0
        var totalBytes: Int64 = 0
        var bytesHere: Int64 = 0
        /// Being fetched now.
        var current: Set<String> = []
        /// Proxy path → why it failed (tried again on the next pass).
        var failed: [String: String] = [:]
        /// The host is still making some.
        var waiting = false
        var finished = false
        var problem: String?
    }

    private(set) var jobs: [Job] = []
    private(set) var progress: [Job.ID: Progress] = [:]
    /// The folder here per share id.
    private(set) var roots: [String: String] = [:]
    /// Bytes per second at most (0: as fast as it goes).
    var limit: Int { didSet { UserDefaults.standard.set(limit, forKey: Self.limitKey) } }
    /// Bytes fetched since Pluck opened (every pull).
    private(set) var fetched: Int64 = 0
    /// Bytes per second over the last few seconds.
    private(set) var rate: Double = 0
    @ObservationIgnored private var samples: [(Date, Int64)] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var wake = false
    @ObservationIgnored private var nextFree = ContinuousClock.now
    private var client: OfficeRenderClient { .shared }

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.jobsKey), let saved = try? JSONDecoder().decode([Job].self, from: data) { jobs = saved }
        roots = defaults.dictionary(forKey: Self.rootsKey) as? [String: String] ?? [:]
        limit = defaults.integer(forKey: Self.limitKey)
    }

    /// At launch: the hook for the Resolve round trip, and pulls cut short carry on.
    static func install() {
        RemoteHooks.pulledProxyRoot = { shared.pulledRoot(for: $0) }
        Task { try? await Task.sleep(for: .seconds(10)); shared.resume() }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(jobs) { UserDefaults.standard.set(data, forKey: Self.jobsKey) }
        UserDefaults.standard.set(roots, forKey: Self.rootsKey)
    }

    // MARK: - Folders here

    /// A share's folder here once it holds a manifest.
    func pulledRoot(for share: String) -> URL? {
        guard let path = roots[share] else { return nil }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        return RemoteManifest.load(in: root) == nil ? nil : root
    }

    /// The share's folder here, asked for the first time.
    func root(for share: OfficeRenderClient.RemoteShare) -> URL? {
        if let path = roots[share.id] { return URL(fileURLWithPath: path, isDirectory: true) }
        return chooseRoot(for: share)
    }

    @discardableResult
    func chooseRoot(for share: OfficeRenderClient.RemoteShare) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Where proxies from “\(share.name)” go on this Mac.")
        panel.directoryURL = URL(fileURLWithPath: roots[share.id] ?? ProxySync.defaultDestination.path)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        setRoot(url, for: share.id)
        return url
    }

    func setRoot(_ url: URL, for share: String) {
        roots[share] = url.path
        save()
    }

    // MARK: - Pulls

    func pull(share: OfficeRenderClient.RemoteShare, paths: [String], format: OfficeProxies.Format, into root: URL) {
        add(Job(share: share.id, shareName: share.name, format: format, paths: paths, destination: root.path))
    }

    /// One file's original (into "Originals" in the share's folder). Asks for its first byte now,
    /// so a Mac without the Originals right hears so straight away.
    /// `clipFolder`: a clip that is a folder (a RED .RDC): every file in it, in a folder of that name.
    func pullOriginal(share: OfficeRenderClient.RemoteShare, path: String, into root: URL, clipFolder: Bool = false) async throws {
        // (It becomes a file path here: only one inside the folder.)
        guard ProxySync.isSafe(path) else { throw OfficeLink.Failure.garbled }
        let files = clipFolder ? try await client.browse(share: share.id, path: path).filter { !$0.folder }.map { path + "/" + $0.name } : [path]
        var entries: [RemoteManifestEntry] = []
        for file in files where ProxySync.isSafe(file) {
            let (_, size) = try await client.fileData(share: share.id, path: file, kind: .original, offset: 0, length: 1)
            entries.append(RemoteManifestEntry(share: share.id, path: file, proxy: file, reel: (file as NSString).lastPathComponent, size: size))
        }
        guard !entries.isEmpty else { throw OfficeLink.Failure.office(String(localized: "That file isn’t ready on the host Mac (yet).")) }
        add(Job(share: share.id, shareName: share.name, format: .original, paths: [path],
                destination: root.appendingPathComponent(String(localized: "Originals"), isDirectory: true).path, originals: entries))
    }

    private func add(_ job: Job) {
        jobs.removeAll { $0.id == job.id }
        jobs.append(job)
        progress[job.id] = nil
        save()
        resume()
    }

    func setPaused(_ job: Job, _ paused: Bool) {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[index].paused = paused
        save()
        if !paused { resume() }
    }

    /// Stops a pull; what's here stays.
    func remove(_ job: Job) {
        jobs.removeAll { $0.id == job.id }
        progress[job.id] = nil
        save()
    }

    /// Bytes still to come for the pulls running, at the recent rate.
    var timeLeft: TimeInterval? {
        let left = jobs.filter { !$0.paused }.compactMap { progress[$0.id] }.filter { !$0.finished }
            .reduce(Int64(0)) { $0 + max($1.totalBytes - $1.bytesHere, 0) }
        guard rate > 1, left > 0 else { return nil }
        return Double(left) / rate
    }

    /// Keeps pulling while anything's left: each pull in turn, then again after half a minute
    /// (sooner when a pull is added or resumed) while files fail or the host is still making some.
    func resume() {
        wake = true
        // (A test copy runs its passes itself.)
        guard task == nil, ScreenshotMode.scene == nil, jobs.contains(where: { !$0.paused }) else { return }
        client.load()
        guard client.office != nil else { return }
        task = Task {
            defer { task = nil }
            while !Task.isCancelled {
                wake = false
                var again = false
                for job in jobs where !job.paused && !Task.isCancelled {
                    if await pass(job) { again = true }
                }
                guard again || wake else { return }
                for _ in 0..<30 where !wake && !Task.isCancelled { try? await Task.sleep(for: .seconds(1)) }
            }
        }
    }

    /// Fetches what's ready of one pull. True while there's more to come.
    func pass(_ job: Job) async -> Bool {
        var state = progress[job.id] ?? Progress()
        state.problem = nil
        let entries: [RemoteManifestEntry], pending: Int
        if let originals = job.originals {
            (entries, pending) = (originals.filter { ProxySync.isSafe($0.proxy) }, 0)
        } else {
            do {
                let manifest = try await RemotePullClient.manifest(share: job.share, format: job.format)
                // (The host's paths are trusted only inside the folder here.)
                entries = manifest.entries.filter { entry in
                    ProxySync.isSafe(entry.proxy) && job.paths.contains { $0.isEmpty || entry.path == $0 || entry.path.hasPrefix($0 + "/") }
                }
                pending = manifest.pending
            } catch {
                state.problem = error.localizedDescription
                progress[job.id] = state
                return true
            }
        }
        let root = URL(fileURLWithPath: job.destination, isDirectory: true)
        let todo = entries.filter { !Self.isHere($0, in: root) }
        state.files = entries.count
        state.filesHere = entries.count - todo.count
        state.totalBytes = entries.reduce(0) { $0 + $1.size }
        state.bytesHere = state.totalBytes - todo.reduce(0) { $0 + $1.size }
            + todo.reduce(0) { $0 + min(Self.size(of: root.appendingPathComponent($1.proxy).appendingPathExtension("part")) ?? 0, $1.size) }
        state.waiting = pending > 0
        state.finished = false
        progress[job.id] = state

        await withTaskGroup(of: Void.self) { group in
            var queue = todo[...]
            for _ in 0..<min(Self.parallel, queue.count) {
                let entry = queue.removeFirst()
                group.addTask { await self.fetchFile(entry, of: job, in: root) }
            }
            while await group.next() != nil, let entry = queue.popFirst() {
                group.addTask { await self.fetchFile(entry, of: job, in: root) }
            }
        }

        guard jobs.contains(where: { $0.id == job.id }) else { return false }
        let here = entries.filter { Self.isHere($0, in: root) }
        if job.originals == nil, !here.isEmpty {
            do { try writeManifest(here, of: job, in: root) } catch { progress[job.id]?.problem = error.localizedDescription }
        }
        let done = !entries.isEmpty && here.count == entries.count && pending == 0
        progress[job.id]?.filesHere = here.count
        progress[job.id]?.finished = done
        return !done && isRunning(job)
    }

    private func isRunning(_ job: Job) -> Bool { jobs.first { $0.id == job.id }.map { !$0.paused } ?? false }

    /// One file, tried a few times; a failure is kept to show and the pull goes on.
    private func fetchFile(_ entry: RemoteManifestEntry, of job: Job, in root: URL) async {
        progress[job.id]?.current.insert(entry.proxy)
        defer { progress[job.id]?.current.remove(entry.proxy) }
        for attempt in 1...Self.tries {
            do {
                guard try await fetch(entry, of: job, to: root.appendingPathComponent(entry.proxy)) else { return }
                progress[job.id]?.failed[entry.proxy] = nil
                progress[job.id]?.filesHere += 1
                return
            } catch {
                progress[job.id]?.failed[entry.proxy] = error.localizedDescription
                if attempt == Self.tries || !isRunning(job) { return }
            }
        }
    }

    /// One file in pieces, carrying on from what an earlier try left, checked, then put in place.
    /// False when the pull was paused or removed on the way.
    private func fetch(_ entry: RemoteManifestEntry, of job: Job, to target: URL) async throws -> Bool {
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = target.appendingPathExtension("part")
        if !fm.fileExists(atPath: partial.path) { fm.createFile(atPath: partial.path, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: partial.path) else {
            throw OfficeLink.Failure.office(String(localized: "The proxy couldn’t be saved on this Mac."))
        }
        defer { try? handle.close() }
        var offset = Int64(try handle.seekToEnd())
        // (A part bigger than the file is of another version: started again.)
        if offset > entry.size { try handle.truncate(atOffset: 0); progress[job.id]?.bytesHere -= min(offset, entry.size); offset = 0 }
        let kind: OfficeRenderClient.FileKind = job.format == .original ? .original : .proxy
        while offset < entry.size {
            guard isRunning(job) else { return false }
            let length = chunk
            await throttle(length)
            let piece = try await client.fileData(share: job.share, path: entry.path, kind: kind, format: kind == .proxy ? job.format : .light,
                                                  offset: offset, length: length)
            // The host's file changed since the manifest: started again from the next one.
            guard piece.size == entry.size else {
                try handle.truncate(atOffset: 0)
                progress[job.id]?.bytesHere -= offset
                throw OfficeLink.Failure.office(String(localized: "The file changed on the host Mac."))
            }
            guard !piece.data.isEmpty else { throw OfficeLink.Failure.garbled }
            try handle.write(contentsOf: piece.data)
            offset += Int64(piece.data.count)
            counted(Int64(piece.data.count), for: job)
        }
        try handle.synchronize()
        if let checksum = entry.checksum?.lowercased() {
            let sum = await Task.detached { Self.sha256(partial) }.value
            guard sum == checksum else {
                // (Damaged on the way, or a resumed part that wasn't right: all of it again.)
                try? fm.removeItem(at: partial)
                progress[job.id]?.bytesHere -= entry.size
                throw OfficeLink.Failure.office(String(localized: "A file arrived damaged and is fetched again."))
            }
        }
        if fm.fileExists(atPath: target.path) { _ = try fm.replaceItemAt(target, withItemAt: partial) } else { try fm.moveItem(at: partial, to: target) }
        return true
    }

    /// A piece's size: smaller under a speed limit, so the limit holds second by second.
    private var chunk: Int { limit > 0 ? min(OfficeLink.fileChunk, max(256 << 10, limit)) : OfficeLink.fileChunk }

    /// Waits for this piece's turn under the speed limit (shared by every transfer).
    private func throttle(_ bytes: Int) async {
        guard limit > 0 else { return }
        let now = ContinuousClock.now
        let start = max(now, nextFree)
        nextFree = start + .seconds(Double(bytes) / Double(limit))
        if start > now { try? await Task.sleep(until: start, clock: .continuous) }
    }

    private func counted(_ bytes: Int64, for job: Job) {
        fetched += bytes
        progress[job.id]?.bytesHere += bytes
        let now = Date.now
        samples.append((now, fetched))
        samples.removeAll { now.timeIntervalSince($0.0) > 8 }
        if let first = samples.first, now.timeIntervalSince(first.0) > 0.2 { rate = Double(fetched - first.1) / now.timeIntervalSince(first.0) }
    }

    /// The share's manifest in its folder here: the proxies pulled, by their path in it.
    private func writeManifest(_ here: [RemoteManifestEntry], of job: Job, in root: URL) throws {
        let office = client.office
        var manifest = RemoteManifest.load(in: root).flatMap { $0.share == job.share ? $0 : nil }
            ?? RemoteManifest(host: office?.device.uuidString ?? "", hostName: office?.name ?? "", share: job.share, shareName: job.shareName, entries: [])
        let fresh = Set(here.map(\.proxy))
        manifest.entries = (manifest.entries.filter { !fresh.contains($0.proxy) } + here).sorted { $0.proxy < $1.proxy }
        try manifest.save(in: root)
    }

    nonisolated static func isHere(_ entry: RemoteManifestEntry, in root: URL) -> Bool {
        size(of: root.appendingPathComponent(entry.proxy)) == entry.size
    }

    nonisolated static func size(of file: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
    }

    nonisolated static func sha256(_ file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try? handle.read(upToCount: 4 << 20), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
