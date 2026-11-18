import AppKit

/// A NAS's root names without its API key: a share of that NAS mounted here (its server resolves to the NAS) whose
/// top level lists the same entries as one of the helper's roots is that root, under the share's name. Names the
/// TrueNAS API set stay. Runs on launch, when a volume mounts and when a NAS comes online.
@MainActor
enum ShareRootNames {
    private static var running = false
    private static var again = false
    private static var observers: [NSObjectProtocol] = []
    private static var timer: Timer?

    /// Once at launch: the first look, then on every mount and every few minutes (addresses change).
    static func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map {
            center.addObserver(forName: $0, object: nil, queue: .main) { _ in MainActor.assumeIsolated { soon() } }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in MainActor.assumeIsolated { soon() } }
        soon()
    }

    static func soon() {
        guard !running else { again = true; return }
        running = true
        Task { await learn() }
    }

    static func learn(publish: ReviewPublish? = nil, timeout: Double = 5) async {
        let publish = publish ?? .shared
        running = true
        defer { running = false; if again { again = false; soon() } }
        await shareVolumes.refresh()
        let shares = shareVolumes.volumes().compactMap { volume in shareVolumes.share(volume).map { (volume: volume, share: $0) } }
        for host in publish.hosts where host.kind == .nas {
            let address = (host.address ?? "").split(separator: ":").first.map { $0.lowercased() } ?? ""
            let names = host.rootNames ?? [:]
            let mine = shares.filter { item in
                !address.isEmpty && shareVolumes.matches(item.share.server, address)
                    && names[item.share.name] == nil && !names.values.contains { $0.caseInsensitiveCompare(item.share.name) == .orderedSame }
            }
            guard !mine.isEmpty, let roots = try? await ReviewHostClient.roots(host) else { continue }
            var listings: [String: Set<String>] = [:]
            for id in roots where names[id] == nil {
                if let entries = try? await ReviewHostClient.browse(host, path: id) { listings[id] = Set(entries.map(\.name)) }
            }
            var found: [(id: String, name: String)] = []
            for item in mine {
                guard let here = await listing(item.volume, timeout: timeout) else { continue }
                let hits = listings.filter { same(helper: $0.value, share: here.names, folders: here.folders) }.map(\.key)
                if hits.count == 1 { found.append((hits[0], item.share.name)) } // (two roots alike: neither)
            }
            // A root two shares look like: neither.
            let learned = Dictionary(grouping: found, by: \.id).compactMapValues { $0.count == 1 ? $0[0].name : nil }
            guard !learned.isEmpty else { continue }
            publish.update(host: host.id) { record in
                var known = record.rootNames ?? [:]
                for (id, name) in learned where known[id] == nil { known[id] = name }
                record.rootNames = known
            }
        }
    }

    /// The helper lists a root's folders and media files (not hidden ones); a share's top shows all its files.
    /// The same root: at least 80% of the helper's names and of the share's folders in common, and 3 names or more
    /// (with fewer, all of them).
    nonisolated static func same(helper: Set<String>, share: Set<String>, folders: Set<String>) -> Bool {
        guard !helper.isEmpty else { return false }
        let common = helper.intersection(share).count, shared = folders.intersection(helper).count
        if helper.count < 3 || common < 3 { return common == helper.count && shared == folders.count }
        return Double(common) >= 0.8 * Double(helper.count) && Double(shared) >= 0.8 * Double(folders.count)
    }

    /// A volume's top-level names and folders, read on a background queue; nil when it doesn't answer in time
    /// (the read is left to finish on its own: a dead share can't hang anything).
    nonisolated static func listing(_ volume: String, timeout: Double) async -> (names: Set<String>, folders: Set<String>)? {
        final class Once: @unchecked Sendable {
            let lock = NSLock(); var done = false
            func first() -> Bool { lock.withLock { defer { done = true }; return !done } }
        }
        let once = Once()
        return await withCheckedContinuation { (result: CheckedContinuation<(names: Set<String>, folders: Set<String>)?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let urls = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: volume, isDirectory: true),
                                                                       includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                let found = urls.map { urls in
                    (names: Set(urls.map(\.lastPathComponent)),
                     folders: Set(urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.map(\.lastPathComponent)))
                }
                if once.first() { result.resume(returning: found) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if once.first() { result.resume(returning: nil) } }
        }
    }
}
