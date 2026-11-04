import Foundation
import Observation

/// Film tables made for one photo's advanced settings (FilmRoute's `tables`): the settings that change the tables
/// themselves (push, the couplers, the print's filters and contrast, …). `pluck-spektra` makes them once (a fraction of
/// a second, with the film data download), they're kept on disk, and from then on that photo's film is instant again:
/// the same GPU chain as the shipped tables, with these.
///
/// Kept in Caches/Pluck/FilmTables/<key>.pft, one folder per set of tables (its film.pft, and paper.pft and pair.pft
/// when printed), written whole and then moved into place. At most 200 MB; the least recently used go first. A set
/// that won't load is thrown away and made again.
@MainActor
@Observable
final class FilmAdvanced {
    static let shared = FilmAdvanced()

    /// The tables being made, or waiting their turn (their keys).
    private(set) var preparing: Set<String> = []
    /// Goes up when tables are made (or can't be), or the film data arrives: pictures waiting for them are made again.
    private(set) var revision = 0

    private struct Job {
        let key: String
        let film: FilmSettings
    }

    /// Waiting their turn (one is made at a time), the one being made, and who waits for which (exports).
    @ObservationIgnored private var queue: [Job] = []
    @ObservationIgnored private var making: String?
    @ObservationIgnored private var waiting: [String: [CheckedContinuation<FilmStock?, Never>]] = [:]
    /// The work loop is on (set before it starts, so a second ask never starts another).
    @ObservationIgnored private var running = false
    /// The last tables asked for a picture on screen: the ones still worth keeping on disk when made.
    @ObservationIgnored private var latest: String?

    private init() {}

    /// Asks for this film's tables, for a picture on screen. A newer ask replaces the older ones nobody waits for (a
    /// slider moving through its values makes only the tables it stops at); the one being made is finished. True when
    /// they're being made or waiting their turn (false: they can't be made now, say without the film data).
    @discardableResult func prepare(_ film: FilmSettings) -> Bool { ask(film, nil) }

    /// This film's tables, made first if they must be (an export waits for them). nil: they couldn't be made (the
    /// helper develops the photo instead), or the film doesn't need its own.
    func wait(for film: FilmSettings) async -> FilmStock? {
        guard case .tables(let key) = FilmRoute.of(film) else { return nil }
        if let made = await Task.detached(priority: .userInitiated, operation: { Self.made(key) }).value { return made }
        return await withCheckedContinuation { ask(film, $0) }
    }

    /// The film data was downloaded: tables can be made now.
    func packArrived() {
        Self.store.withLock { $0.failed = []; $0.stops = [:] }
        revision += 1
    }

    @discardableResult private func ask(_ film: FilmSettings, _ waiter: CheckedContinuation<FilmStock?, Never>?) -> Bool {
        guard case .tables(let key) = FilmRoute.of(film), !Self.failed(key) else { waiter?.resume(returning: nil); return false }
        // Without the film data nothing can be made: the Film panel offers it (and `packArrived` asks again).
        guard FilmEngine.shared.state == .ready, FilmEngine.helper != nil else { waiter?.resume(returning: nil); return false }
        if let waiter { waiting[key, default: []].append(waiter) } else { latest = key }
        if making == key || queue.contains(where: { $0.key == key }) { return true }
        if waiter == nil { queue.removeAll { waiting[$0.key, default: []].isEmpty } }
        queue.append(Job(key: key, film: film))
        preparing = Set(queue.map(\.key) + [making].compactMap { $0 })
        guard !running else { return true }
        running = true
        Task { await work() }
        return true
    }

    private func work() async {
        defer { running = false }
        while !queue.isEmpty {
            let job = queue.removeFirst()
            making = job.key
            let made = await make(job)
            making = nil
            preparing = Set(queue.map(\.key))
            revision += 1
            // Those waiting for this job's own key (asks that came while it was made joined it).
            for waiter in waiting.removeValue(forKey: job.key) ?? [] { waiter.resume(returning: made) }
        }
    }

    /// Made (or found ready after all), loaded and kept; nil when it couldn't be (a real failure is remembered: the
    /// helper then). Tables nobody waits for and no picture wants any more (a slider went on) stay in memory only.
    private func make(_ job: Job) async -> FilmStock? {
        let key = job.key
        if let made = await Task.detached(priority: .userInitiated, operation: { Self.made(key) }).value { return made }
        let folder = Self.folder
        let making = folder.appendingPathComponent(".making-\(UUID().uuidString)", isDirectory: true)
        let started = Date()
        do {
            try FileManager.default.createDirectory(at: making, withIntermediateDirectories: true)
            if FilmEngine.packMatchesTables == false {
                NSLog("Pluck film: making tables for %@ from film data other than the shipped tables' (they may differ a little)", job.film.film)
            }
            try await FilmEngine.shared.tables(film: job.film.film, paper: job.film.paper, settings: job.film.settings, to: making)
            let disk = latest == key || !(waiting[key]?.isEmpty ?? true)
            guard let stock = await Task.detached(priority: .userInitiated, operation: { Self.keep(making, key, disk: disk) }).value else {
                throw NSError(domain: "Pluck", code: 10, userInfo: [NSLocalizedDescriptionKey: "the tables made didn't load"])
            }
            Self.timings.withLock { $0.append((job.film.film, Date().timeIntervalSince(started))) }
            Self.store.withLock { _ = $0.stops.removeValue(forKey: key) }
            return stock
        } catch {
            try? FileManager.default.removeItem(at: making)
            // The helper stopped under it (Pluck stopped the film engine, or it was cancelled): not the tables' fault,
            // they're asked for again next time. A real error (the helper refused, or what it made won't load) is kept.
            let ns = error as NSError
            let stopped = error is CancellationError || (ns.domain == "Pluck" && [2, 3].contains(ns.code))
            NSLog("Pluck film: the tables for %@ couldn't be made (%@)%@", job.film.film, ns.localizedDescription,
                  stopped ? "" : "; the film engine develops that photo instead")
            // (A helper that stops on these very settings twice is a real failure: else the picture would ask again and again.)
            Self.store.withLock { store in
                if stopped { store.stops[key, default: 0] += 1 }
                if !stopped || store.stops[key, default: 0] >= 2 { store.failed.insert(key) }
            }
            return nil
        }
    }

    // MARK: - The tables kept (any thread)

    private struct Store {
        /// The last few in memory, the newest last.
        var memory: [(key: String, stock: FilmStock)] = []
        /// Couldn't be made: the helper develops these.
        var failed: Set<String> = []
        /// When each set on disk was last marked as used (a memory hit marks it at most once a minute).
        var touched: [String: Date] = [:]
        /// How often the helper stopped while making these.
        var stops: [String: Int] = [:]
    }
    nonisolated private static let store = FilmLocked(Store())
    /// How long each set took to make (tests and notes).
    nonisolated static let timings = FilmLocked<[(film: String, seconds: Double)]>([])

    /// Where they're kept (inside the test copy's own home in tests).
    nonisolated static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck/FilmTables", isDirectory: true)
    }
    /// At most this much on disk.
    nonisolated static let limit = 200 << 20

    /// The tables for this key when they're made: from memory, else from disk (blocking). A set on disk that won't
    /// load is thrown away (nil: it's made again).
    nonisolated static func made(_ key: String) -> FilmStock? {
        let entry = folder.appendingPathComponent("\(key).pft", isDirectory: true)
        if let (hit, due) = store.withLock({ store -> (FilmStock, Bool)? in
            guard let at = store.memory.firstIndex(where: { $0.key == key }) else { return nil }
            let hit = store.memory.remove(at: at)
            store.memory.append(hit)
            let due = (store.touched[key] ?? .distantPast) < Date(timeIntervalSinceNow: -60)
            if due { store.touched[key] = Date() }
            return (hit.stock, due)
        }) {
            // In use: so the eviction keeps it (a set kept in memory only has nothing on disk to mark).
            if due { touch(entry) }
            return hit
        }
        guard FileManager.default.fileExists(atPath: entry.path) else { return nil }
        guard let stock = load(entry) else {
            NSLog("Pluck film: kept tables %@ wouldn't load; they'll be made again", key)
            try? FileManager.default.removeItem(at: entry)
            return nil
        }
        touch(entry)
        remember(key, stock)
        store.withLock { $0.touched[key] = Date() }
        return stock
    }

    /// Whether this key's tables are made and kept on disk.
    nonisolated static func onDisk(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(key).pft/film.pft").path)
    }

    /// Whether this key's tables are in memory (no waiting at all).
    nonisolated static func inMemory(_ key: String) -> Bool { store.withLock { $0.memory.contains { $0.key == key } } }

    /// Whether this key's tables couldn't be made.
    nonisolated static func failed(_ key: String) -> Bool { store.withLock { $0.failed.contains(key) } }

    /// Lets go of the tables kept in memory (the Mac is short of it); what's on disk stays.
    nonisolated static func dropMemory() { store.withLock { $0.memory = [] } }

    /// Forgets what's in memory and which couldn't be made (tests); what's on disk stays.
    nonisolated static func forget() { store.withLock { $0 = Store() } }

    private nonisolated static func load(_ entry: URL) -> FilmStock? {
        let film = entry.appendingPathComponent("film.pft"), paper = entry.appendingPathComponent("paper.pft"), pair = entry.appendingPathComponent("pair.pft")
        guard FileManager.default.fileExists(atPath: film.path) else { return nil }
        let printed = FileManager.default.fileExists(atPath: paper.path) || FileManager.default.fileExists(atPath: pair.path)
        return printed ? FilmTables.stock(at: film, paper: paper, pair: pair) : FilmTables.stock(at: film)
    }

    /// Moves a set just made into place (replacing any older one of the same key), loads it, and keeps the cache in bounds.
    /// `disk` false: loaded into memory only, and the files go.
    private nonisolated static func keep(_ making: URL, _ key: String, disk: Bool) -> FilmStock? {
        guard disk else {
            defer { try? FileManager.default.removeItem(at: making) }
            guard let stock = load(making) else { return nil }
            remember(key, stock)
            return stock
        }
        let entry = folder.appendingPathComponent("\(key).pft", isDirectory: true)
        try? FileManager.default.removeItem(at: entry)
        guard (try? FileManager.default.moveItem(at: making, to: entry)) != nil else { return nil }
        guard let stock = load(entry) else { try? FileManager.default.removeItem(at: entry); return nil }
        remember(key, stock)
        evict(keeping: key)
        return stock
    }

    private nonisolated static func remember(_ key: String, _ stock: FilmStock) {
        store.withLock { store in
            store.memory.removeAll { $0.key == key }
            store.memory.append((key, stock))
            if store.memory.count > 4 { store.memory.removeFirst() }
        }
    }

    /// Marks a set as just used (the eviction goes by this).
    private nonisolated static func touch(_ entry: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: entry.path)
    }

    /// Removes the least recently used sets until the rest fit in `limit` (never `keeping`), and any half-made
    /// leftovers older than an hour.
    nonisolated static func evict(keeping: String? = nil, limit: Int = FilmAdvanced.limit, in folder: URL = FilmAdvanced.folder) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        var sets: [(url: URL, used: Date, size: Int)] = []
        for entry in entries {
            let used = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if entry.lastPathComponent.hasPrefix(".making-") {
                if used < Date(timeIntervalSinceNow: -3600) { try? manager.removeItem(at: entry) }
                continue
            }
            guard entry.pathExtension == "pft" else { continue }
            let files = (try? manager.contentsOfDirectory(at: entry, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let size = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            sets.append((entry, used, size))
        }
        var total = sets.reduce(0) { $0 + $1.size }
        for set in sets.sorted(by: { $0.used < $1.used }) where total > limit {
            if set.url.deletingPathExtension().lastPathComponent == keeping { continue }
            try? manager.removeItem(at: set.url)
            total -= set.size
        }
    }
}

/// A value behind a lock.
final class FilmLocked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body(&value)
    }
}
