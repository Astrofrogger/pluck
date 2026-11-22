import Foundation

/// What deleting really gives back on a TrueNAS share: its dataset's periodic snapshot tasks keep deleted files' space
/// until the longest of them expires. Read through the TrueNAS connection Pluck already has (the review server's API key
/// and pinned certificate), never asked for; without one, "snapshots may keep it". And what deleting did give back:
/// the share's free space measured when something was last waiting, next to what's gone from the folder to delete since.
@MainActor
enum ArchiveSnapshots {
    /// Days the space of a deleted file stays in snapshots (0: no snapshot task), from `sharing.smb.query` and
    /// `pool.snapshottask.query` (api.truenas.com v25.10: path, name; dataset, recursive, enabled, lifetime_value, lifetime_unit).
    /// nil: the share isn't one of this NAS's.
    nonisolated static func days(shares: [[String: Any]], tasks: [[String: Any]], share name: String) -> Int? {
        guard let entry = shares.first(where: { ($0["name"] as? String)?.lowercased() == name.lowercased() }), let path = entry["path"] as? String else { return nil }
        let dataset = path.hasPrefix("/mnt/") ? String(path.dropFirst(5)) : path
        let units = ["HOUR": 1.0 / 24, "DAY": 1, "WEEK": 7, "MONTH": 31, "YEAR": 366]
        let kept = tasks.filter { task in
            guard task["enabled"] as? Bool != false, let of = task["dataset"] as? String else { return false }
            // (A share is often a folder below its dataset: a task on the dataset or a parent counts, recursive or not;
            // a parent's non-recursive one may not keep a child dataset's space, so this can only say longer, never shorter.)
            return of == dataset || dataset.hasPrefix(of + "/")
        }.map { task in (Double((task["lifetime_value"] as? NSNumber)?.intValue ?? 0)) * (units[(task["lifetime_unit"] as? String ?? "").uppercased()] ?? 31) }
        return Int((kept.max() ?? 0).rounded(.up))
    }

    /// A NAS address ("192.168.1.5", "nas.local") is the host a share is mounted from ("smb://user@nas.local/Footage").
    nonisolated static func sameNAS(_ address: String, remount: String) -> Bool {
        guard let host = URL(string: remount)?.host?.lowercased(), !host.isEmpty else { return false }
        return host == address.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    /// Self-tests: a share's days of their own.
    static var lookup: ((String) async -> Int?)?
    private static var known: [String: Int?] = [:]

    /// Days for a mounted share (by its path here), asked once per share while Pluck runs. nil: no TrueNAS connection that has it.
    static func days(for share: String) async -> Int? {
        if let lookup { return await lookup(share) }
        if let found = known[share] { return found }
        var result: Int?
        if let remount = OfficeGroup.place(URL(fileURLWithPath: share))?.remount, let name = remount.split(separator: "/").last.map(String.init) {
            // (The NAS the share is mounted from; a single NAS connection when the address doesn't say, e.g. a name vs an IP.)
            let nas = ReviewPublish.shared.hosts.filter { $0.kind == .nas }
            let same = nas.filter { sameNAS(TrueNASSetup.nasAddress($0), remount: remount) }
            for host in same.isEmpty && nas.count == 1 ? nas : same {
                let address = TrueNASSetup.nasAddress(host)
                guard let key = TrueNASKeychain.load(address), let pin = TrueNASKeychain.pin(address) else { continue }
                let client = TrueNASClient(address: address, pin: pin)
                defer { client.close() }
                guard (try? await client.connect()) != nil, (try? await client.login(key)) != nil,
                      let shares = try? await client.call("sharing.smb.query") as? [[String: Any]],
                      let tasks = try? await client.call("pool.snapshottask.query") as? [[String: Any]],
                      let days = days(shares: shares, tasks: tasks, share: name) else { continue }
                result = days
                break
            }
        }
        known[share] = result
        return result
    }

    // MARK: Measured

    /// A share's free space and the bytes waiting in its folder to delete, when last looked at with something waiting.
    /// (`last`: the bytes waiting at the last look, so a new run is seen even after everything was deleted.)
    struct Mark: Codable, Equatable { var free: Int64; var waiting: Int64; var date: Date; var last: Int64? }

    static func marks() -> [String: Mark] {
        (UserDefaults.standard.data(forKey: "archiveFreeMarks")).flatMap { try? JSONDecoder().decode([String: Mark].self, from: $0) } ?? [:]
    }

    /// What deleting gave back so far on a share: the bytes gone from its folder to delete since the mark, and how much its
    /// free space grew. A new mark whenever more is waiting than at the last look (a new run), so only deletions count.
    static func measured(share: String, free: Int64?, waiting: Int64, now: Date = .now, store: inout [String: Mark]) -> (deleted: Int64, freed: Int64)? {
        guard let free else { return nil }
        guard var mark = store[share], waiting <= (mark.last ?? mark.waiting) else {
            store[share] = waiting > 0 ? Mark(free: free, waiting: waiting, date: now, last: waiting) : nil
            return nil
        }
        let deleted = mark.waiting - waiting
        guard deleted > 0 else { store[share] = Mark(free: free, waiting: waiting, date: now, last: waiting); return nil }
        mark.last = waiting
        store[share] = mark
        return (deleted, free - mark.free)
    }

    /// Pluck itself moved originals out of these shares' folders to delete (Put Back, Restore): measured again from now,
    /// so what it moved isn't counted as deleted.
    static func forget(_ shares: [String]) {
        var store = marks()
        shares.forEach { store[$0] = nil }
        save(store)
    }

    static func save(_ store: [String: Mark]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(store), forKey: "archiveFreeMarks")
    }
}
