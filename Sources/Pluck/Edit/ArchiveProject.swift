import Foundation

/// A project's `.pluck-project.json` in its NAS folder, read by every Mac: Deliver writes when it was delivered,
/// approved as final and its review archived; Archive writes Closed, Hold and how long its originals are kept.
/// Each side sets only its own keys, keeps the others (unknown ones too) and writes the file whole (a new file
/// renamed over it). With Hold a project is never touched; a closed one keeps its originals for its client's
/// months after it closed (none set: the age filter, as before).
enum ArchiveProject {
    static let fileName = ".pluck-project.json"

    struct Info: Equatable, Sendable {
        var delivered: Date?
        var approvedFinal: Date?
        var closed: Bool?
        var hold: Bool?
        var keepOriginalsUntil: Date?
        var reviewArchived: Date?

        /// Closed by the owner, or by Deliver's delivery or final approval (never while on hold; the owner can open it again).
        var isClosed: Bool { hold != true && (closed ?? (delivered != nil || approvedFinal != nil)) }
        /// The day Deliver closed it (nil: the owner did, or it's open).
        var closedByDeliver: Date? { closed == nil || closed == true ? (delivered ?? approvedFinal) : nil }
    }

    static func url(_ folder: String) -> URL { URL(fileURLWithPath: folder).appendingPathComponent(fileName) }

    /// "2026-11-20" or a full ISO time.
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let full = ISO8601DateFormatter()
        if let date = full.date(from: text) { return date }
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        return day.date(from: String(text.prefix(10)))
    }

    static func dayText(_ date: Date) -> String {
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        return day.string(from: date)
    }

    static func info(_ json: [String: Any]) -> Info {
        Info(delivered: date(json["delivered"]), approvedFinal: date(json["approvedFinal"]), closed: json["closed"] as? Bool, hold: json["hold"] as? Bool,
             keepOriginalsUntil: date(json["keepOriginalsUntil"]), reviewArchived: date(json["reviewArchived"]))
    }

    static func json(_ folder: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url(folder)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The project's file (nil: there's none, or it can't be read).
    static func read(_ folder: String) -> Info? { json(folder).map(info) }

    /// Archive's keys changed, the rest kept as they are. false: it couldn't be written (read-only, not mounted).
    /// A file there that isn't readable JSON is never written over.
    @discardableResult
    static func write(_ folder: String, _ change: (inout [String: Any]) -> Void) -> Bool {
        let target = url(folder)
        var object: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: target.path) {
            guard let read = json(folder) else { return false }
            object = read
        }
        change(&object)
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return false }
        let saving = URL(fileURLWithPath: folder).appendingPathComponent(".pluck-project.json.\(UUID().uuidString.prefix(8)).saving")
        guard (try? data.write(to: saving)) != nil else { return false }
        if Darwin.rename(saving.path, target.path) != 0 { unlink(saving.path); return false }
        return true
    }

    /// When a closed project's originals may go (nil: not closed, or no months set for its client).
    static func keptUntil(_ info: Info?, months: Int?) -> Date? {
        guard let info, info.isClosed else { return nil }
        if let until = info.keepOriginalsUntil { return until }
        guard let months, months > 0, let closed = info.closedByDeliver else { return nil }
        return Calendar.current.date(byAdding: .month, value: months, to: closed)
    }

    /// Why a project's originals stay as they are now (nil: the age filter decides, or nothing holds them).
    /// `ripe`: its kept-until day has passed (the age filter isn't asked then).
    static func gate(_ info: Info?, months: Int?, now: Date = .now) -> (reason: String?, ripe: Bool) {
        guard let info else { return (nil, false) }
        if info.hold == true { return (String(localized: "On hold"), false) }
        guard let until = keptUntil(info, months: months) else { return (nil, false) }
        if until > now { return (String(localized: "Kept until \(until.formatted(date: .abbreviated, time: .omitted))"), false) }
        return (nil, true)
    }

    /// Closed or open again by the owner; closing with months set for its client keeps its originals that long from now
    /// (or from Deliver's delivery).
    @discardableResult
    static func setClosed(_ folder: String, _ on: Bool, months: Int?, now: Date = .now) -> Bool {
        let before = read(folder)
        return write(folder) { json in
            json["closed"] = on
            if on, let months, months > 0, let until = Calendar.current.date(byAdding: .month, value: months, to: before?.closedByDeliver ?? now) {
                json["keepOriginalsUntil"] = dayText(until)
            } else {
                json.removeValue(forKey: "keepOriginalsUntil")
            }
        }
    }

    @discardableResult
    static func setHold(_ folder: String, _ on: Bool) -> Bool { write(folder) { $0["hold"] = on } }

    /// A client's months changed: each of its closed projects keeps its originals that long after it closed.
    static func retain(_ folders: [String], months: Int?, now: Date = .now) {
        for folder in folders {
            guard let info = read(folder), info.isClosed else { continue }
            write(folder) { json in
                if let months, months > 0, let until = Calendar.current.date(byAdding: .month, value: months, to: info.closedByDeliver ?? now) {
                    json["keepOriginalsUntil"] = dayText(until)
                } else {
                    json.removeValue(forKey: "keepOriginalsUntil")
                }
            }
        }
    }

    /// Its line on a project row: "On hold", "Closed: delivered 3 Nov", "Closed".
    static func label(_ info: Info?) -> String? {
        guard let info else { return nil }
        if info.hold == true { return String(localized: "On hold") }
        guard info.isClosed else { return nil }
        if let day = info.delivered, info.closed != false { return String(localized: "Closed: delivered \(day.formatted(date: .abbreviated, time: .omitted))") }
        if let day = info.approvedFinal, info.closed != false { return String(localized: "Closed: approved \(day.formatted(date: .abbreviated, time: .omitted))") }
        return String(localized: "Closed")
    }
}
