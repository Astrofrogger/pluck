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
        /// The file is there but can't be read (not JSON, no permission): the project is held, as on hold.
        var unreadable = false

        /// On hold, or its file can't be read (what it says isn't known: never touched).
        var held: Bool { hold == true || unreadable }
        /// Closed by the owner, or by Deliver's delivery or final approval (never while held; the owner can open it again).
        var isClosed: Bool { !held && (closed ?? (delivered != nil || approvedFinal != nil)) }
        /// The day Deliver closed it (nil: the owner did, or it's open).
        var closedByDeliver: Date? { closed == nil || closed == true ? (delivered ?? approvedFinal) : nil }
    }

    static func url(_ folder: String) -> URL { URL(fileURLWithPath: folder).appendingPathComponent(fileName) }

    /// Month arithmetic on the file's days, which are UTC days (the same day on every Mac, whatever its time zone).
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        return calendar
    }()

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

    /// What's in a project's folder: no file, one that can't be read (not a JSON object, no permission, a drive error), or its keys.
    enum Contents { case none, unreadable, json([String: Any]) }

    static func load(_ folder: String) -> Contents {
        let data: Data
        do { data = try Data(contentsOf: url(folder)) } catch {
            let error = error as NSError
            return error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError ? .none : .unreadable
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .unreadable }
        return .json(object)
    }

    /// The file's keys (nil: there's none, or it can't be read).
    static func json(_ folder: String) -> [String: Any]? {
        if case .json(let object) = load(folder) { return object }
        return nil
    }

    /// The project's file (nil: there's none; one that can't be read: `unreadable`, so the project is held).
    static func read(_ folder: String) -> Info? {
        switch load(folder) {
        case .none: nil
        case .unreadable: Info(unreadable: true)
        case .json(let object): info(object)
        }
    }

    /// Why a project is held now, read from its folder ("On hold", "Project file can't be read"); nil: it isn't.
    static func heldNow(_ folder: String) -> String? {
        guard let info = read(folder), info.held else { return nil }
        return label(info)
    }

    /// Some keys changed (Archive's, or Deliver's through DeliverProjectFile.merge), the rest kept as they are. false: it
    /// couldn't be written (read-only, not mounted). A file there that can't be read is never written over.
    @discardableResult
    static func write(_ folder: String, _ change: (inout [String: Any]) -> Void) -> Bool {
        let target = url(folder)
        var object: [String: Any] = [:]
        switch load(folder) {
        case .unreadable: return false
        case .json(let read): object = read
        case .none: break
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
        return calendar.date(byAdding: .month, value: months, to: closed)
    }

    /// Why a project's originals stay as they are now (nil: the age filter decides, or nothing holds them).
    /// `ripe`: its kept-until day has passed (the age filter isn't asked then).
    static func gate(_ info: Info?, months: Int?, now: Date = .now) -> (reason: String?, ripe: Bool) {
        guard let info else { return (nil, false) }
        if info.unreadable { return (String(localized: "Project file can’t be read"), false) }
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
            if on, let months, months > 0, let until = calendar.date(byAdding: .month, value: months, to: before?.closedByDeliver ?? now) {
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
                if let months, months > 0, let until = calendar.date(byAdding: .month, value: months, to: info.closedByDeliver ?? now) {
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
        if info.unreadable { return String(localized: "Project file can’t be read") }
        if info.hold == true { return String(localized: "On hold") }
        guard info.isClosed else { return nil }
        if let day = info.delivered, info.closed != false { return String(localized: "Closed: delivered \(day.formatted(date: .abbreviated, time: .omitted))") }
        if let day = info.approvedFinal, info.closed != false { return String(localized: "Closed: approved \(day.formatted(date: .abbreviated, time: .omitted))") }
        return String(localized: "Closed")
    }
}
