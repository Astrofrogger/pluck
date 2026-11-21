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
            return of == dataset || (task["recursive"] as? Bool == true && dataset.hasPrefix(of + "/"))
        }.map { task in (Double((task["lifetime_value"] as? NSNumber)?.intValue ?? 0)) * (units[(task["lifetime_unit"] as? String ?? "").uppercased()] ?? 31) }
        return Int((kept.max() ?? 0).rounded(.up))
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
            for host in ReviewPublish.shared.hosts where host.kind == .nas {
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
    struct Mark: Codable, Equatable { var free: Int64; var waiting: Int64; var date: Date }

    static func marks() -> [String: Mark] {
        (UserDefaults.standard.data(forKey: "archiveFreeMarks")).flatMap { try? JSONDecoder().decode([String: Mark].self, from: $0) } ?? [:]
    }

    /// What deleting gave back so far on a share: the bytes gone from its folder to delete since the mark, and how much its
    /// free space grew. A new mark whenever more is waiting than before (a new run), so only deletions count.
    static func measured(share: String, free: Int64?, waiting: Int64, now: Date = .now, store: inout [String: Mark]) -> (deleted: Int64, freed: Int64)? {
        guard let free else { return nil }
        guard let mark = store[share], waiting <= mark.waiting else {
            if waiting > 0 { store[share] = Mark(free: free, waiting: waiting, date: now) }
            return nil
        }
        let deleted = mark.waiting - waiting
        guard deleted > 0 else { store[share] = Mark(free: free, waiting: waiting, date: now); return nil }
        return (deleted, free - mark.free)
    }

    static func save(_ store: [String: Mark]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(store), forKey: "archiveFreeMarks")
    }
}
