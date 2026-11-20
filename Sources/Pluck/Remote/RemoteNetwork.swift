import AppKit
import CryptoKit
import Foundation

/// Streaming: a Mac away from the host edits in Resolve straight from the host's proxies, nothing downloaded.
/// The proxies come through Pluck's own drive (RemoteDriveNFS): a read-only NFS server inside Pluck on
/// 127.0.0.1, mounted with mount_nfs, its bytes fetched with `fileData` and kept in a disk cache.
/// No macOS File Sharing anywhere.
@MainActor
enum RemoteNetworkHost {
    /// Whether paired Macs may stream from this host (on unless the owner turns it off).
    nonisolated static let streamKey = "remoteStreamAllowed"
    nonisolated static var streamAllowed: Bool { UserDefaults.standard.object(forKey: streamKey) as? Bool ?? true }

    static func register() {
        OfficeActions.register("driveInfo") { _, device in
            try OfficeActions.require(\.proxies, device)
            // (formats: what's made here, so a Mac knows it can ask for the streaming ones.)
            // (write: the drive may write here, RemoteDriveWrite; an office from before doesn't say, so its drives stay read-only.)
            return ["stream": streamAllowed, "formats": OfficeProxies.Format.made.map(\.rawValue), "write": RemoteDriveWriteHost.offered]
        }
    }
}

// MARK: - The drive's contents

/// One share's proxies as the drive shows them: the manifest's proxies in their folders, plus the manifest
/// itself as `.pluck-manifest.json` in the top (so Resolve linking finds it like in a pulled folder).
final class RemoteShareDrive: RemoteDriveBackend, @unchecked Sendable {
    /// (The whole entry: which proxy it is decides which format's file the bytes come from.)
    typealias Fetch = @Sendable (_ entry: RemoteManifestEntry, _ offset: Int64, _ length: Int) async throws -> Data

    struct Tree {
        var nodes: [String: RemoteDriveNode] = [:]
        var children: [String: [String]] = [:]
        var entries: [String: RemoteManifestEntry] = [:]
        var manifest = Data()
    }

    let blocks: RemoteDriveBlocks
    private let lock = NSLock()
    private var tree = Tree()
    /// This Mac's own files on the drive and what waits to go to the office (RemoteDriveWrite; nil: read-only).
    var overlay: RemoteDriveOverlay? {
        didSet { overlay?.known = { [weak self] path in self?.current.nodes[path] != nil } }
    }

    init(cacheKey: String, fetch: @escaping Fetch) {
        blocks = RemoteDriveBlocks(scope: cacheKey, fetch: fetch)
    }

    func update(_ manifest: RemoteManifest) {
        let built = Self.tree(manifest)
        lock.lock(); tree = built; lock.unlock()
    }

    var current: Tree { lock.lock(); defer { lock.unlock() }; return tree }

    /// A date that only changes with the content (NFS clients drop their caches when it does).
    static func stamp(_ text: String) -> Date {
        let hash = SHA256.hash(data: Data(text.utf8)).prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return Date(timeIntervalSince1970: 1_500_000_000 + Double(hash % 300_000_000))
    }

    static func tree(_ manifest: RemoteManifest) -> Tree {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var tree = Tree()
        tree.manifest = (try? encoder.encode(manifest)) ?? Data()
        let folderDate = stamp(String(decoding: tree.manifest, as: UTF8.self))
        tree.nodes[""] = RemoteDriveNode(name: "", folder: true, size: 0, modified: folderDate)
        func add(_ path: String, _ node: RemoteDriveNode) {
            guard tree.nodes[path] == nil else { return }
            let parent = (path as NSString).deletingLastPathComponent
            if tree.nodes[parent] == nil {
                add(parent, RemoteDriveNode(name: (parent as NSString).lastPathComponent, folder: true, size: 0, modified: folderDate))
            }
            tree.nodes[path] = node
            tree.children[parent, default: []].append(path)
        }
        add(RemoteManifest.fileName, RemoteDriveNode(name: RemoteManifest.fileName, folder: false, size: Int64(tree.manifest.count), modified: folderDate))
        for entry in manifest.entries {
            let parts = entry.proxy.split(separator: "/", omittingEmptySubsequences: false)
            guard entry.proxy.count < 1000, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }), tree.nodes[entry.proxy] == nil else { continue }
            add(entry.proxy, RemoteDriveNode(name: String(parts.last!), folder: false, size: entry.size,
                                             modified: stamp(entry.proxy + (entry.checksum ?? "\(entry.size)"))))
            tree.entries[entry.proxy] = entry
        }
        for key in tree.children.keys { tree.children[key]?.sort { $0.localizedStandardCompare($1) == .orderedAscending } }
        return tree
    }

    // MARK: RemoteDriveBackend

    func node(_ path: String) async throws -> RemoteDriveNode {
        guard var node = current.nodes[path] else {
            if let own = overlay?.node(path) { return own }
            throw RemoteDriveError.noEntry
        }
        if node.folder, let overlay, overlay.hostWrites { node.writable = await overlay.canWrite(path) }
        return node
    }

    func list(_ path: String) async throws -> [RemoteDriveNode] {
        let tree = current
        guard let node = try? await self.node(path) else { throw RemoteDriveError.noEntry }
        guard node.folder else { throw RemoteDriveError.notFolder }
        let office = (tree.children[path] ?? []).compactMap { tree.nodes[$0] }, names = Set(office.map(\.name))
        let own = (overlay?.children(path) ?? []).filter { !names.contains($0.name) }
        return office + own.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func read(_ path: String, offset: Int64, count: Int) async throws -> Data {
        let tree = current
        if tree.nodes[path] == nil, let overlay { return try await overlay.read(path, offset: offset, count: count) }
        if path == RemoteManifest.fileName {
            let start = Int(min(offset, Int64(tree.manifest.count)))
            return tree.manifest.subdata(in: start..<min(tree.manifest.count, start + count))
        }
        guard let entry = tree.entries[path] else { throw RemoteDriveError.noEntry }
        return try await blocks.read(entry, offset: offset, count: count)
    }
}

/// The drive's bytes: fixed blocks fetched from the host (several at once), kept on disk with the least
/// recently used going first past the size cap, and the next blocks fetched ahead while a file is read in order.
actor RemoteDriveBlocks {
    static let blockSize = 4 << 20
    static let capKey = "editAnywhereDriveCacheGB"
    static var capBytes: Int64 { Int64(max(1, UserDefaults.standard.object(forKey: capKey) as? Int ?? 20)) << 30 }
    static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck/Edit Anywhere Drive", isDirectory: true)
    }

    let scope: String
    let fetch: RemoteShareDrive.Fetch
    private var flying: [String: Task<Data, Error>] = [:]
    /// At most this many fetches from the host at once, reads and fetches ahead together (each on a connection the
    /// host keeps open): enough in flight to keep a slow, far link full. (Variables only for the speed test's "before".)
    nonisolated(unsafe) static var maxFetches = 8
    /// Blocks fetched ahead of a file read in order.
    nonisolated(unsafe) static var ahead = 6
    /// The last measured speed from the host, bytes a second (kept between launches: the next mount picks its proxies by it).
    static let speedKey = "editAnywhereLinkSpeed"
    nonisolated static var linkSpeed: Double? { (UserDefaults.standard.object(forKey: speedKey) as? Double).flatMap { $0 > 0 ? $0 : nil } }
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var lastBlock: [String: Int64] = [:]
    private var total: Int64?
    /// Bytes a second of the last fetches from the host (nil: none yet).
    private(set) var speed: Double?
    private(set) var fetched = 0

    init(scope: String, fetch: @escaping RemoteShareDrive.Fetch) {
        self.scope = scope
        self.fetch = fetch
    }

    /// The cache folder of one proxy, by its content (a proxy made again gets a new one).
    private func directory(_ entry: RemoteManifestEntry) -> URL {
        let key = SHA256.hash(data: Data("\(scope)|\(entry.path)|\(entry.checksum ?? String(entry.size))".utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        return Self.folder.appendingPathComponent(key, isDirectory: true)
    }

    func read(_ entry: RemoteManifestEntry, offset: Int64, count: Int) async throws -> Data {
        guard offset < entry.size, count > 0 else { return Data() }
        // A pinned proxy (same size and SHA-256) is read from its copy on this Mac: no network, plays offline.
        if let copy = RemotePins.localCopy(entry) { return try RemotePins.read(copy, offset: offset, count: count) }
        let end = min(entry.size, offset + Int64(count))
        let first = offset / Int64(Self.blockSize), last = (end - 1) / Int64(Self.blockSize)
        // In order (the same or the next block as last time): the next ones come ahead.
        if let previous = lastBlock[entry.path], first == previous || first == previous + 1 {
            for ahead in (last + 1)...(last + Int64(Self.ahead)) where ahead * Int64(Self.blockSize) < entry.size {
                if flying.count < Self.ahead + 2 { _ = start(entry, ahead, urgent: false) }
            }
        }
        lastBlock[entry.path] = last
        var out = Data()
        // All of the read's blocks at once (a big read, like the speed measure's, isn't one block after another).
        let blocks = (first...last).map { ($0, start(entry, $0)) }
        for (index, task) in blocks {
            let block = try await task.value
            let base = index * Int64(Self.blockSize)
            let from = Int(max(offset, base) - base), to = Int(min(end, base + Int64(block.count)) - base)
            guard from < to else { throw RemoteDriveError.io }
            out.append(block.subdata(in: from..<to))
        }
        return out
    }

    /// The block from disk, or its fetch (one per block however many readers want it).
    private func start(_ entry: RemoteManifestEntry, _ index: Int64, urgent: Bool = true) -> Task<Data, Error> {
        let file = directory(entry).appendingPathComponent(String(index))
        let key = file.path
        if let task = flying[key] { return task }
        if let data = try? Data(contentsOf: file) {
            _ = utimes(file.path, nil) // most recently used
            return Task { data }
        }
        let offset = index * Int64(Self.blockSize), length = Int(min(Int64(Self.blockSize), entry.size - offset))
        let fetch = fetch
        let task = Task<Data, Error> {
            await self.slot(urgent: urgent)
            defer { self.freeSlot() }
            var attempt = 0
            while true {
                do {
                    let started = Date.now
                    let data = try await fetch(entry, offset, length)
                    guard data.count == length else { throw RemoteDriveError.io }
                    self.done(key, file: file, data: data, seconds: Date.now.timeIntervalSince(started))
                    return data
                } catch {
                    attempt += 1
                    if attempt >= 2 { self.failed(key); throw error }
                }
            }
        }
        flying[key] = task
        return task
    }

    private func failed(_ key: String) { flying[key] = nil }

    /// Waits for a free fetch slot; what's being read now goes before what's fetched ahead.
    private func slot(urgent: Bool) async {
        guard running >= Self.maxFetches else { running += 1; return }
        await withCheckedContinuation { waiter in
            if urgent { waiting.insert(waiter, at: 0) } else { waiting.append(waiter) }
        }
    }

    /// The slot goes to the next waiting fetch (still counted as running), else it's free.
    private func freeSlot() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }

    private func done(_ key: String, file: URL, data: Data, seconds: Double) {
        flying[key] = nil
        fetched += data.count
        if seconds > 0 {
            // With several fetches at once the host's real rate is about this times how many are going.
            let rate = Double(data.count) / seconds * Double(max(1, running))
            speed = speed.map { $0 * 0.7 + rate * 0.3 } ?? rate
            UserDefaults.standard.set(speed, forKey: Self.speedKey)
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: file, options: .atomic)) != nil else { return }
        if total == nil { total = Self.usage().reduce(0) { $0 + $1.size } }
        total! += Int64(data.count)
        if total! > Self.capBytes { total = Self.trim(to: Self.capBytes * 9 / 10) }
    }

    /// Every cached block with its size and last use.
    nonisolated static func usage() -> [(url: URL, size: Int64, used: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return [] }
        return walker.compactMap { item in
            guard let url = item as? URL, let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
    }

    /// Removes the least recently used blocks until the cache is at most `bytes`; the size left.
    @discardableResult
    nonisolated static func trim(to bytes: Int64) -> Int64 {
        var blocks = usage().sorted { $0.used < $1.used }
        var size = blocks.reduce(0) { $0 + $1.size }
        while size > bytes, !blocks.isEmpty {
            let oldest = blocks.removeFirst()
            if (try? FileManager.default.removeItem(at: oldest.url)) != nil { size -= oldest.size }
        }
        return size
    }

    func clearedTotal() { total = nil }
}

/// One mounted share's lighter proxies: their format once the link proved too slow for the chosen one, and the
/// manifest entries they stand in with (the fetch picks a piece's format by its entry, so a cached block never mixes the two).
final class RemoteStreamChoice: @unchecked Sendable {
    private let lock = NSLock()
    private var _lighter: OfficeProxies.Format?
    private var _standIns: Set<RemoteManifestEntry> = []
    /// Clips read without a lighter proxy, waiting to be asked for one; those the host took; whether a batch is on its way.
    private var _pending: Set<String> = [], _asked: Set<String> = [], flushing = false
    /// How often the host refused each clip on its own (three times: never asked again this mount).
    private var _refusals: [String: Int] = [:]
    var lighter: OfficeProxies.Format? {
        get { lock.withLock { _lighter } }
        set { lock.withLock { _lighter = newValue } }
    }
    var standIns: Set<RemoteManifestEntry> {
        get { lock.withLock { _standIns } }
        set { lock.withLock { _standIns = newValue } }
    }

    /// A clip read through the drive with no lighter proxy yet: noted for the host (only clips that are used, never the
    /// whole share). True when nothing is on its way, so the caller starts a batch.
    func wants(_ path: String) -> Bool {
        lock.withLock {
            guard !_asked.contains(path) else { return false }
            _pending.insert(path)
            guard !flushing else { return false }
            flushing = true
            return true
        }
    }

    /// The next paths to ask for, at most `most` (none: the batch is over).
    func take(_ most: Int) -> [String] {
        lock.withLock {
            let batch = Array(_pending.prefix(most))
            _pending.subtract(batch)
            if batch.isEmpty { flushing = false }
            return batch
        }
    }

    /// The host took these (`ok`), or didn't: then they wait again, and the next read starts another try.
    func asked(_ paths: [String], ok: Bool) {
        lock.withLock {
            if ok { _asked.formUnion(paths) } else { _pending.formUnion(paths); flushing = false }
        }
    }

    /// Clips the host refused one by one: tried again with a later batch, dropped after the third time.
    func refused(_ paths: [String]) {
        lock.withLock {
            for path in paths {
                _refusals[path, default: 0] += 1
                if _refusals[path, default: 0] >= 3 { _asked.insert(path) } else { _pending.insert(path) }
            }
        }
    }
}

// MARK: - The remote side

/// On a Mac away from the host: one drive per streamed share, mounted (hidden from Finder) under
/// Application Support, its manifest kept fresh, its read speed shown; gone on Disconnect, on quit and when the host goes away.
@MainActor
@Observable
final class RemoteNetwork {
    static let shared = RemoteNetwork()

    struct Mounted: Equatable {
        var root: URL
        var port: UInt16
        /// Measured read speed from the host, bytes a second.
        var speed: Double?
    }

    enum State: Equatable {
        case idle, mounting, mounted(Mounted), failed(String), offline
    }

    enum Quality { case smooth, usable, slow }

    /// Whether the host lets this Mac stream (nil: not asked yet or the host didn't answer).
    private(set) var hostAllows: Bool?
    /// Whether the host takes writes from the drive (false: an office from before; nil: not asked yet).
    private(set) var hostWrites: Bool?
    /// The proxy formats the host makes (a host from before doesn't say: no streaming proxies there).
    @ObservationIgnored private var hostFormats: Set<String> = []
    /// Per mounted share: the lighter proxies standing in, and how big its chosen-format proxies are (to download).
    @ObservationIgnored private var choices: [String: RemoteStreamChoice] = [:]
    @ObservationIgnored private var chosenBytes: [String: Int64] = [:]
    private(set) var states: [String: State] = [:]
    /// Shares the editor connected (mounted again after a drop, until disconnected).
    @ObservationIgnored private var wanted: Set<String> = []
    @ObservationIgnored private var drives: [String: (server: RemoteDriveServer, drive: RemoteShareDrive)] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var watcher: Task<Void, Never>?
    /// The mount under way per share (everyone asking waits for that one), and manifest refreshes failed in a row.
    @ObservationIgnored private var mounting: [String: Task<URL, Error>] = [:]
    @ObservationIgnored private var refreshFailures: [String: Int] = [:]

    private init() {}

    /// At launch: provides RemoteHooks.networkProxyRoot, clears drives a crash left behind, follows wakes.
    func install() {
        RemoteHooks.networkProxyRoot = { share in try await RemoteNetwork.shared.root(for: share) }
        RemoteProxyMode.migrate()
        RemoteDriveWrites.shared.install()
        guard observers.isEmpty else { return }
        Tunnel.followNetwork()
        Task.detached { Self.unmountLeftovers() }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await RemoteNetwork.shared.check() }
        })
    }

    func state(_ share: String) -> State { states[share] ?? .idle }

    /// Where drives are mounted: ~/Library/Application Support/Pluck/Edit Anywhere/Drives/<host>/<share> <id>.
    nonisolated static var drivesFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/Edit Anywhere/Drives", isDirectory: true)
    }

    /// (The share's id in the name: two shares called alike never share a mount point.)
    nonisolated static func mountPoint(host: String, share: String, id: String) -> URL {
        drivesFolder.appendingPathComponent(Folders.sanitize(host, fallback: "Mac"), isDirectory: true)
            .appendingPathComponent(Folders.sanitize(share, fallback: "Share") + " " + id.prefix(8), isDirectory: true)
    }

    /// The proxy format this Mac works with (the browser's choice).
    static var format: OfficeProxies.Format {
        let chosen = OfficeProxies.Format(rawValue: UserDefaults.standard.string(forKey: "editAnywhereProxyFormat") ?? "") ?? .light
        return chosen == .original ? .light : chosen
    }

    // MARK: Asking the host

    func refresh() async {
        let answer = try? await OfficeRenderClient.shared.ask("driveInfo", timeout: 20)
        hostAllows = answer.map { $0["stream"] as? Bool ?? false }
        if let answer { hostWrites = answer["write"] as? Bool == true }
        if let answer { hostFormats = Set(answer["formats"] as? [String] ?? []) }
    }

    // MARK: Mounting

    /// The mounted proxies folder of a share, mounting it first if needed (RemoteHooks.networkProxyRoot).
    func root(for share: String) async throws -> URL {
        if case .mounted(let mounted) = state(share), RemoteDriveMount.isMounted(mounted.root) {
            try? await updateManifest(share)
            return mounted.root
        }
        return try await mount(share)
    }

    @discardableResult
    func mount(_ id: String) async throws -> URL {
        if case .mounted(let mounted) = state(id), RemoteDriveMount.isMounted(mounted.root) { return mounted.root }
        wanted.insert(id)
        if let flying = mounting[id] {
            guard flying.isCancelled else { return try await flying.value }
            // A mount cancelled by Disconnect finishes cleaning up before the next one starts.
            _ = try? await flying.value
            if let again = mounting[id], again != flying { return try await again.value }
        }
        guard wanted.contains(id) else { throw CancellationError() }
        let task = Task { try await attach(id) }
        mounting[id] = task
        defer { if mounting[id] == task { mounting[id] = nil } }
        return try await task.value
    }

    /// One mount attempt; it stops (cleaning up only its own drive) when Disconnect cancels it.
    private func attach(_ id: String) async throws -> URL {
        states[id] = .mounting
        var mine: RemoteDriveServer?
        func stillWanted() throws {
            guard !Task.isCancelled, wanted.contains(id) else { throw CancellationError() }
        }
        do {
            guard let office = OfficeRenderClient.shared.office else { throw Failure.offline }
            let format = Self.format, choice = RemoteStreamChoice()
            let share: OfficeRenderClient.RemoteShare, manifest: RemoteManifest
            do {
                await refresh()
                guard let allows = hostAllows else { throw Failure.offline }
                guard allows else { throw Failure.notAllowed }
                let shares = try await OfficeRenderClient.shared.shares()
                guard let found = shares.first(where: { $0.id == id }), found.online else { throw Failure.offline }
                let made = try await self.manifest(share: found, office: office, format: format, choice: choice, standingIn: nil)
                (share, manifest) = (found, made)
            } catch {
                // No office to ask: the folders kept on this Mac (RemotePins) alone, played from their copies here.
                guard (error as? Failure) != .notAllowed, let kept = RemotePins.shared.offlineManifest(id),
                      let offline = OfficeRenderClient.RemoteShare(["id": id, "name": kept.shareName, "online": false]) else { throw error }
                (share, manifest) = (offline, kept)
            }
            guard !manifest.entries.isEmpty else { throw Failure.noProxies }
            try stillWanted()
            await stopDrive(id)
            let drive = RemoteShareDrive(cacheKey: "\(office.device.uuidString)|\(id)|\(format.rawValue)",
                                         fetch: Self.fetcher(share: id, format: format, choice: choice))
            choices[id] = choice
            drive.update(manifest)
            // This Mac's writes (kept since the last time, even across restarts); read-only where the office doesn't take them.
            let overlay = RemoteDriveWrites.shared.overlay(office: office.device.uuidString, share: id)
            if let hostWrites { overlay.hostWrites = hostWrites }
            overlay.shareName = share.name
            overlay.forgetAccess()
            drive.overlay = overlay
            let server = RemoteDriveServer(backend: drive)
            mine = server
            let port = try await server.start()
            try stillWanted()
            drives[id] = (server, drive)
            let point = Self.mountPoint(host: office.name, share: share.name, id: id)
            await RemoteDriveMount.unmount(point)
            do { try await RemoteDriveMount.mount(server, at: point) } catch {
                throw Failure.mount(error.localizedDescription)
            }
            do { try stillWanted() } catch {
                await RemoteDriveMount.unmount(point)
                throw error
            }
            refreshFailures[id] = nil
            states[id] = .mounted(Mounted(root: point, port: port, speed: nil))
            watch()
            Task { await measure(id) }
            return point
        } catch {
            // Only this attempt's own server goes (never one another attempt set up).
            if let mine {
                if drives[id]?.server === mine { drives[id] = nil }
                mine.stop()
            }
            // (Disconnected meanwhile: it stays as Disconnect left it.)
            if !(error is CancellationError), !Task.isCancelled, wanted.contains(id) {
                states[id] = (error as? Failure) == .offline ? .offline : .failed(error.localizedDescription)
            }
            throw error
        }
    }

    func unmount(_ id: String) async {
        wanted.remove(id)
        mounting[id]?.cancel()
        refreshFailures[id] = nil
        let overlay = drives[id]?.drive.overlay
        await stopDrive(id)
        overlay?.dropSentSpools()
        states[id] = .idle
    }

    /// Unmounts the drive, then stops its server (that order: nothing left hanging on a dead server).
    private func stopDrive(_ id: String) async {
        if case .mounted(let mounted) = state(id) { await RemoteDriveMount.unmount(mounted.root) }
        drives.removeValue(forKey: id)?.server.stop()
        choices[id] = nil
    }

    /// When Pluck quits: every drive unmounted before its server goes with Pluck.
    func unmountAllNow() {
        for case .mounted(let mounted) in states.values {
            for arguments in [[mounted.root.path], ["-f", mounted.root.path]] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/sbin/umount")
                process.arguments = arguments
                guard (try? process.run()) != nil else { break }
                process.waitUntilExit()
                if process.terminationStatus == 0 { break }
            }
        }
        drives.values.forEach { $0.server.stop() }
        drives = [:]
    }

    /// Drives a crash or a force quit left mounted (their server died with that Pluck).
    nonisolated static func unmountLeftovers() {
        let base = (RemoteEditHost.realPath(drivesFolder.path) ?? drivesFolder.path) + "/"
        for volume in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? [] {
            let point = volume.path
            guard point.hasPrefix(base) || point.hasPrefix(drivesFolder.path + "/") else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/sbin/umount")
            process.arguments = ["-f", point]
            try? process.run()
            process.waitUntilExit()
        }
        // Empty mount points left behind (older ones were named by the share alone) go; rmdir never touches a full folder.
        let fm = FileManager.default
        for host in (try? fm.contentsOfDirectory(at: drivesFolder, includingPropertiesForKeys: nil)) ?? [] {
            for point in (try? fm.contentsOfDirectory(at: host, includingPropertiesForKeys: nil)) ?? [] { rmdir(point.path) }
            rmdir(host.path)
        }
    }

    /// While a drive is mounted: every two minutes the manifest again (new proxies show), the speed, and a
    /// host that's gone takes its drives with it (mounted again when it's back).
    private func watch() {
        guard watcher == nil else { return }
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                guard let self, !self.wanted.isEmpty else { break }
                await self.check()
            }
            self?.watcher = nil
        }
    }

    /// Each wanted share: manifest refreshed, or unmounted when the host doesn't answer; mounted again when it does.
    func check() async {
        for id in wanted {
            if case .mounted(let mounted) = state(id), RemoteDriveMount.isMounted(mounted.root) {
                do {
                    try await updateManifest(id)
                    refreshFailures[id] = nil
                    if let speed = await drives[id]?.drive.blocks.speed, case .mounted(var now) = state(id) {
                        now.speed = speed
                        states[id] = .mounted(now)
                    }
                } catch {
                    // One failed refresh keeps the drive and its last contents; the host gone (or three misses in a row) takes it down.
                    let failures = refreshFailures[id, default: 0] + 1
                    refreshFailures[id] = failures
                    // (Kept folders stay: their files play from this Mac.)
                    if ((error as? Failure) == .offline || failures >= 3) && !RemotePins.shared.hasPins(id) {
                        refreshFailures[id] = nil
                        await stopDrive(id)
                        states[id] = .offline
                    }
                }
            } else if state(id) != .mounting {
                _ = try? await mount(id)
            }
        }
    }

    private func updateManifest(_ id: String) async throws {
        guard let office = OfficeRenderClient.shared.office, let drive = drives[id]?.drive else { throw Failure.offline }
        guard let share = try await OfficeRenderClient.shared.shares().first(where: { $0.id == id }), share.online else { throw Failure.offline }
        let choice = choices[id] ?? RemoteStreamChoice()
        drive.update(try await manifest(share: share, office: office, format: Self.format, choice: choice,
                                        standingIn: Set(choice.standIns.map(\.path))))
    }

    /// The share's proxies in the chosen format. At mount (`standingIn` nil), when the last measured link is too slow for
    /// Light, the lighter streaming proxies stand in for every one the host has made already (the host is asked for the
    /// rest only as clips are read, see `askLighter`, for the next mount). A refresh (`standingIn`: the stand-ins' paths) never changes the format of a path.
    private func manifest(share: OfficeRenderClient.RemoteShare, office: OfficeRenderClient.Office, format: OfficeProxies.Format,
                          choice: RemoteStreamChoice, standingIn: Set<String>?) async throws -> RemoteManifest {
        var entries = try await RemotePullClient.manifest(share: share.id, format: format).entries
        chosenBytes[share.id] = entries.reduce(0) { $0 + $1.size }
        if standingIn == nil, choice.lighter == nil {
            let pick = Self.streamFormat(chosen: format, speed: RemoteDriveBlocks.linkSpeed, hostMakes: hostFormats.contains(OfficeProxies.Format.stream.rawValue))
            if pick != format { choice.lighter = pick }
        }
        if let lighter = choice.lighter {
            // (At a refresh a failed list keeps the drive as it was: stand-ins never fall back to the chosen format mid-edit.)
            let made = standingIn == nil ? ((try? await RemotePullClient.manifest(share: share.id, format: lighter).entries) ?? [])
                : try await RemotePullClient.manifest(share: share.id, format: lighter).entries
            let picked = Self.standIns(chosen: entries, lighter: made, standingIn: standingIn)
            entries = picked.entries
            choice.standIns = picked.standIns
        }
        return RemoteManifest(host: office.device.uuidString, hostName: office.name, share: share.id, shareName: share.name, entries: entries)
    }

    /// The drive's entries, and which of them are lighter stand-ins. At mount (`standingIn` nil) every path with a lighter
    /// proxy made takes it; after, only the paths standing in already do (a file Resolve has open never changes format).
    nonisolated static func standIns(chosen: [RemoteManifestEntry], lighter: [RemoteManifestEntry],
                                     standingIn: Set<String>?) -> (entries: [RemoteManifestEntry], standIns: Set<RemoteManifestEntry>) {
        let byPath = Dictionary(lighter.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let entries = chosen.map { entry in
            guard standingIn?.contains(entry.path) ?? true, let light = byPath[entry.path] else { return entry }
            return light
        }
        return (entries, Set(entries.filter { byPath[$0.path] == $0 }))
    }

    /// The format to stream: Light, or the lighter streaming proxies when the measured link gives less than about one and a
    /// half times what Light plays at (and the host makes those). Any other choice (ProRes) stays: too slow, it says so and
    /// offers Download Instead.
    nonisolated static func streamFormat(chosen: OfficeProxies.Format, speed: Double?, hostMakes: Bool) -> OfficeProxies.Format {
        guard let speed, hostMakes, chosen == .light, chosen.bytesPerSecond * 1.5 > speed else { return chosen }
        return .stream
    }

    /// What a mounted share streams now: its stand-ins' format once every proxy has one, else the chosen one.
    func streaming(_ id: String) -> OfficeProxies.Format {
        guard let choice = choices[id], let lighter = choice.lighter, let entries = drives[id]?.drive.current.entries.values,
              !entries.isEmpty, entries.allSatisfy(choice.standIns.contains) else { return Self.format }
        return lighter
    }

    /// When the link is too slow for what a mounted share streams: what to tell (nil when it's fine or not measured yet).
    func tooSlow(_ id: String) -> String? {
        guard case .mounted(let mounted) = state(id), let speed = mounted.speed else { return nil }
        return Self.tooSlow(speed: speed, format: streaming(id), downloadBytes: chosenBytes[id] ?? 0)
    }

    /// "This connection gives about 2 MB/s, too slow …: they're ready in about 10 minutes" (nil when the speed plays the format).
    nonisolated static func tooSlow(speed: Double, format: OfficeProxies.Format, downloadBytes: Int64) -> String? {
        guard speed > 0, quality(speed: speed, format: format.rawValue) == .slow else { return nil }
        let rate = ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file)
        let time = DateComponentsFormatter()
        time.unitsStyle = .full
        time.allowedUnits = [.hour, .minute]
        time.maximumUnitCount = 1
        // (Rounded up to whole minutes: never "about 0 minutes".)
        let wait = time.string(from: max(60, (Double(downloadBytes) / speed / 60).rounded(.up) * 60)) ?? ""
        return String(localized: "This connection gives about \(rate)/s, too slow to stream this smoothly. Download the proxies first: they’re ready in about \(wait).")
    }

    /// Proxy pieces from the host, marked as streaming (the host may have it turned off); a stand-in's from the lighter proxies.
    private static func fetcher(share: String, format: OfficeProxies.Format, choice: RemoteStreamChoice) -> RemoteShareDrive.Fetch {
        { entry, offset, length in
            let from = choice.lighter.map { choice.standIns.contains(entry) ? $0 : format } ?? format
            if from != choice.lighter, choice.lighter != nil, choice.wants(entry.path) {
                Task { @MainActor in await askLighter(share: share, choice: choice) }
            }
            // (Several pieces share a slow link at once: each gets longer than one alone would.)
            let answer = try await OfficeRenderClient.shared.ask("fileData", ["share": share, "path": entry.path, "kind": "proxy", "format": from.rawValue,
                                                                              "offset": offset, "length": length, "stream": true], timeout: 60)
            guard let data = answer[OfficeActions.bytesKey] as? Data else { throw RemoteDriveError.io }
            return data
        }
    }

    /// Asks the host for lighter proxies of the clips read meanwhile: collected for two seconds, a few hundred a question.
    /// A batch the host refuses (one bad path refuses it all) is split in halves down to single clips; a host out of
    /// reach puts the clips back. Either way the next read tries again. (Nothing else is ever asked for by itself.)
    static func askLighter(share: String, choice: RemoteStreamChoice, wait: Duration = .seconds(2),
                           make: (@MainActor ([String], OfficeProxies.Format) async throws -> Void)? = nil) async {
        try? await Task.sleep(for: wait)
        var refused: [String] = []
        defer { choice.refused(refused) }
        /// False when the host couldn't be reached (the clips are back in the list).
        func send(_ paths: [String], _ format: OfficeProxies.Format) async -> Bool {
            do {
                if let make { try await make(paths, format) } else { try await RemotePullClient.makeProxies(share: share, paths: paths, format: format) }
                choice.asked(paths, ok: true)
                return true
            } catch OfficeLink.Failure.office(_) {
                guard paths.count > 1 else { refused += paths; return true }
                let half = paths.count / 2
                guard await send(Array(paths[..<half]), format) else { choice.asked(Array(paths[half...]), ok: false); return false }
                return await send(Array(paths[half...]), format)
            } catch {
                choice.asked(paths, ok: false)
                return false
            }
        }
        while true {
            let batch = choice.take(200)
            guard !batch.isEmpty else { return }
            guard let lighter = choice.lighter else { return choice.asked(batch, ok: false) }
            guard await send(batch, lighter) else { return }
        }
    }

    enum Failure: LocalizedError, Equatable {
        case offline, notAllowed, noProxies, mount(String)
        var errorDescription: String? {
            switch self {
            case .offline: String(localized: "The host Mac or this share is offline.")
            case .notAllowed: String(localized: "Streaming is turned off on the host Mac.")
            case .noProxies: String(localized: "No proxies in this share yet.")
            case .mount(let message): String(localized: "The drive couldn’t be mounted (\(message)).")
            }
        }
    }

    /// Whether a read speed plays this proxy format: several streams' worth is smooth, one and a half usable.
    nonisolated static func quality(speed: Double, format: String?) -> Quality {
        let rate = (format.flatMap(OfficeProxies.Format.init(rawValue:)) ?? .light).bytesPerSecond
        return speed >= rate * 4 ? .smooth : speed >= rate * 1.5 ? .usable : .slow
    }

    // MARK: Speed

    /// Fetches the start of the biggest proxy through the drive (two blocks at once, kept in the cache) and keeps the speed.
    func measure(_ id: String) async {
        guard let drive = drives[id]?.drive, let biggest = drive.current.entries.values.max(by: { $0.size < $1.size }) else { return }
        let started = Date.now, before = await drive.blocks.fetched
        let length = Int(min(biggest.size, Int64(2 * RemoteDriveBlocks.blockSize)))
        guard (try? await drive.blocks.read(biggest, offset: 0, count: length)) != nil else { return }
        // Already in the cache: no fetch to time (the speed comes with the next real reads).
        let bytes = await drive.blocks.fetched - before, seconds = Date.now.timeIntervalSince(started)
        if case .mounted(var now) = state(id), bytes > 0, seconds > 0 {
            now.speed = Double(bytes) / seconds
            states[id] = .mounted(now)
            // (Kept for the next mount, which picks stand-ins by it: this one's files stay as they are under Resolve.)
            UserDefaults.standard.set(now.speed, forKey: RemoteDriveBlocks.speedKey)
            // Too slow for Light: from now on clips read get a lighter proxy made, for the next mount (no stand-ins now).
            if let choice = choices[id], choice.lighter == nil, Self.streamFormat(chosen: Self.format, speed: now.speed,
                                                                                hostMakes: hostFormats.contains(OfficeProxies.Format.stream.rawValue)) != Self.format {
                choice.lighter = .stream
            }
        }
    }
}
