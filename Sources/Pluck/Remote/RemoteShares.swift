import Foundation
import os

/// The host's shares (OfficeArchive.folders) as the owner picked them: a bookmark each, so a NAS that
/// comes back under another mount name ("/Volumes/Footage-1") is found again; online state and free
/// space read with a timeout (a hung NAS must never hang an answer); search on/off and watched
/// folders ("keep proxied") per share.
@MainActor
@Observable
final class RemoteShares {
    static let shared = RemoteShares()
    nonisolated private static let key = "remoteShares"

    /// A folder inside a share that keeps getting proxies for new files.
    struct Watch: Codable, Hashable {
        var path: String
        var format: OfficeProxies.Format
    }

    struct Share: Codable, Hashable {
        var path: String
        /// Its id for paired Macs, kept when the folder moves (nil only in shares saved before ids were kept).
        var id: String?
        var bookmark: Data?
        /// The volume it sits on, for people ("Footage NAS").
        var volume: String?
        var search = true
        var watch: [Watch] = []
    }

    struct State: Sendable, Hashable {
        var online: Bool
        var free: Int64
        var total: Int64
    }

    private(set) var shares: [Share] = [] {
        didSet { let map = Self.idMap(shares); Self.ids.withLock { $0 = map } }
    }
    /// Share path → id, for OfficeProxies.id from any thread (read from the saved shares before first use).
    nonisolated static let ids = OSAllocatedUnfairLock(initialState: idMap(saved()))
    /// The last read state of each share's folder (by path), for the window.
    private(set) var states: [String: State] = [:]

    private init() {
        // Shares saved before ids were kept keep the id their path gave them.
        shares = Self.saved().map { var share = $0; if share.id == nil { share.id = OfficeProxies.pathID(share.path) }; return share }
        save()
    }

    nonisolated private static func saved() -> [Share] {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([Share].self, from: $0) } ?? []
    }

    nonisolated private static func idMap(_ shares: [Share]) -> [String: String] {
        Dictionary(shares.map { ($0.path, $0.id ?? OfficeProxies.pathID($0.path)) }, uniquingKeysWith: { first, _ in first })
    }

    private func save() {
        if let data = try? JSONEncoder().encode(shares) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    func share(_ folder: URL) -> Share? { shares.first { $0.path == folder.path } }

    func searchable(_ folder: URL) -> Bool { share(folder)?.search ?? true }

    func setSearch(_ on: Bool, for folder: URL) {
        update(folder) { $0.search = on }
        // A fresh look over the folders with search on (it drops the others' shots).
        OfficeArchive.shared.stop()
        OfficeArchive.shared.scan()
    }

    func addWatch(_ path: String, format: OfficeProxies.Format, in folder: URL) {
        update(folder) { share in
            if !share.watch.contains(Watch(path: path, format: format)) { share.watch.append(Watch(path: path, format: format)) }
        }
        RemoteProxyJobs.shared.refreshWatches()
    }

    func removeWatch(_ watch: Watch, in folder: URL) {
        update(folder) { $0.watch.removeAll { $0 == watch } }
        RemoteProxyJobs.shared.dropWatch(share: OfficeProxies.id(folder), watch)
    }

    private func update(_ folder: URL, _ change: (inout Share) -> Void) {
        if share(folder) == nil {
            // A new folder where a moved share used to be must not take that share's id.
            var id = OfficeProxies.pathID(folder.path)
            if shares.contains(where: { $0.id == id }) { id = OfficeProxies.pathID(folder.path + "#" + UUID().uuidString) }
            shares.append(Share(path: folder.path, id: id))
        }
        guard let index = shares.firstIndex(where: { $0.path == folder.path }) else { return }
        change(&shares[index])
        save()
    }

    // MARK: - Bookmarks

    /// Matches the saved shares to OfficeArchive's folders: new folders get a bookmark (while they're
    /// reachable), removed ones go, and a folder no longer at its path is looked up by its bookmark
    /// and moved to where it is now (a renamed mount, a moved folder).
    func sync() async {
        let archive = OfficeArchive.shared
        shares.removeAll { share in !archive.folders.contains { $0.path == share.path } }
        // Every folder gets its kept id now, before anything else is asked.
        for folder in archive.folders where share(folder) == nil { update(folder) { _ in } }
        for folder in archive.folders where share(folder)?.bookmark == nil {
            let made = await Self.withTimeout(folder.path + "#bookmark", nil) { () -> (Data, String?)? in
                guard let bookmark = try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return nil }
                return (bookmark, try? folder.resourceValues(forKeys: [.volumeNameKey]).volumeName)
            }
            guard let made = made ?? nil else { continue }
            update(folder) { $0.bookmark = made.0; $0.volume = made.1 }
        }
        for share in shares {
            guard let bookmark = share.bookmark, !(await state(URL(fileURLWithPath: share.path, isDirectory: true)).online) else { continue }
            let resolved = await Self.withTimeout(share.path + "#resolve", nil) { () -> (URL, Data?)? in
                var stale = false
                // (Never mounts or asks: an unmounted NAS stays offline until the owner mounts it.)
                guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil,
                                         bookmarkDataIsStale: &stale),
                      url.path != share.path, FileManager.default.fileExists(atPath: url.path) else { return nil }
                return (url, stale ? try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) : nil)
            }
            let found = resolved ?? nil
            guard let url = found?.0, !archive.folders.contains(where: { $0.path == url.path }),
                  !OfficeInbox.overlaps(url, OfficeInbox.shared.folder) else { continue }
            let fresh = found?.1
            let old = URL(fileURLWithPath: share.path, isDirectory: true)
            guard let index = shares.firstIndex(where: { $0.path == share.path }) else { continue }
            shares[index].path = url.path
            if let fresh { shares[index].bookmark = fresh }
            save()
            archive.remove(old)
            archive.add(URL(fileURLWithPath: url.path, isDirectory: true))
        }
    }

    // MARK: - Online and free space

    /// Online, free and total space of a folder, given up on after `timeout` seconds (a NAS that
    /// doesn't answer is offline). One look per folder at a time, so a hung mount can't pile them up.
    func state(_ folder: URL, timeout: Double = 2) async -> State {
        let offline = State(online: false, free: 0, total: 0)
        var state: State?
        var waited = 0.0
        // Another look at it under way: wait for it to end (a hung one counts as offline).
        while state == nil {
            state = await Self.withTimeout(folder.path, offline, timeout: timeout - waited) {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
                return State(online: false, free: 0, total: 0)
            }
            let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey])
            // (Network volumes don't always answer "important usage".)
            let free = values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init) ?? 0
            return State(online: true, free: free, total: Int64(values?.volumeTotalCapacity ?? 0))
            }
            if state == nil {
                guard waited < timeout else { state = offline; break }
                try? await Task.sleep(for: .milliseconds(100))
                waited += 0.1
            }
        }
        states[folder.path] = state
        return state ?? offline
    }

    /// Every share for paired Macs, looked at side by side (at most `timeout` for them all).
    func answer() async -> [[String: Any]] {
        let folders = OfficeArchive.shared.folders
        var found: [String: State] = [:]
        await withTaskGroup(of: (String, State).self) { group in
            for folder in folders { group.addTask { await (folder.path, self.state(folder)) } }
            for await (path, state) in group { found[path] = state }
        }
        return folders.map { folder in
            let state = found[folder.path] ?? State(online: false, free: 0, total: 0)
            var item: [String: Any] = ["id": OfficeProxies.id(folder), "name": folder.lastPathComponent, "online": state.online,
                                       "freeBytes": state.free, "totalBytes": state.total, "search": searchable(folder)]
            if let volume = share(folder)?.volume { item["volume"] = volume }
            return item
        }
    }

    /// Looks under way (by key): a second one at the same time gets nil at once.
    nonisolated private static let busy = OSAllocatedUnfairLock(initialState: Set<String>())

    /// `work` on a background thread, or `fallback` if it takes longer than `timeout`. The work isn't
    /// stopped (a blocked file call can't be), it just isn't waited for; until it ends, the same key gets nil.
    nonisolated static func withTimeout<T: Sendable>(_ key: String, _ fallback: T, timeout: Double = 2,
                                                     _ work: @escaping @Sendable () -> T) async -> T? {
        guard busy.withLock({ $0.insert(key).inserted }) else { return nil }
        let done = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { continuation in
            let finish: @Sendable (T) -> Void = { value in
                if done.withLock({ was in defer { was = true }; return !was }) { continuation.resume(returning: value) }
            }
            DispatchQueue.global(qos: .utility).async {
                let value = work()
                busy.withLock { _ = $0.remove(key) }
                finish(value)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(fallback) }
        }
    }
}
