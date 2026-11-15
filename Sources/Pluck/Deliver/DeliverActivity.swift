import Foundation

/// Each link's activity (§6.1): opened, viewed, played, commented, downloaded, uploaded, approved, with the
/// viewer's name and email and the time. `Review/activity/<linkID>.jsonl`, kept `activityDays` (Settings › Review,
/// default 90; 0 = forever) and 20,000 entries a link. NAS hosts get the same days in the manifest (R8).
extension DeliverStore {
    static let activityLimit = 20_000, activityDaysKey = "reviewActivityDays", activityChoices = [30, 90, 180, 0]
    /// Days the activity log keeps an entry; 0 = forever.
    static var activityDays: Int {
        let v = UserDefaults.standard.object(forKey: activityDaysKey) as? Int ?? 90
        return activityChoices.contains(v) ? v : 90
    }

    func activityFile(_ link: UUID) -> URL { root.appendingPathComponent("activity/\(link.uuidString).jsonl") }

    func activity(_ link: UUID) -> [Deliver.Activity] {
        guard let text = try? String(contentsOf: activityFile(link), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? Deliver.decoder.decode(Deliver.Activity.self, from: Data($0.utf8)) }
    }

    /// Appends one entry (a host's come with their own ids: added once). Trims to the limits now and then.
    @discardableResult
    func log(_ entry: Deliver.Activity) -> Bool {
        let file = activityFile(entry.link)
        guard let data = try? Deliver.encoder.encode(entry) else { return false }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: file) else { return false }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data([0x0A]))
        try? handle.close()
        if let json = try? JSONSerialization.jsonObject(with: data) { note(.entries([["activity": json]])) }
        activityChanged += 1
        if activityChanged % 200 == 0 { trimActivity(entry.link) }
        return true
    }

    /// A host's entry, once by id.
    func logOnce(_ entry: Deliver.Activity) -> Bool {
        activity(entry.link).contains { $0.id == entry.id } ? false : log(entry)
    }

    func trimActivity(_ link: UUID) {
        let days = Self.activityDays
        let cutoff = days == 0 ? Date.distantPast : Date.now.addingTimeInterval(-Double(days) * 86400)
        let kept = activity(link).filter { $0.at > cutoff }.suffix(Self.activityLimit)
        let lines = kept.compactMap { (try? Deliver.encoder.encode($0)).map { String(decoding: $0, as: UTF8.self) } }
        try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: activityFile(link), atomically: true, encoding: .utf8)
        activityChanged += 1
    }

    /// Every link's log to the retention setting (at launch and when the setting changes).
    func trimAllActivity() {
        let files = (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("activity"), includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "jsonl" {
            if let link = UUID(uuidString: file.deletingPathExtension().lastPathComponent) { trimActivity(link) }
        }
    }

    /// Times opened, and the people seen, for the links list.
    func views(_ link: UUID) -> (opened: Int, people: Int) {
        let all = activity(link)
        return (all.filter { $0.kind == "opened" }.count, Set(all.compactMap { $0.name?.isEmpty == false ? $0.name : nil }).count)
    }
}
