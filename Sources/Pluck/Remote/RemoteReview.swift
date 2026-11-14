import Foundation

/// A comment at a moment of a render's preview, with replies; open until someone resolves it.
/// Authors are device labels (the paired Mac's name, or "iPhone" for a phone), never a person.
struct ReviewComment: Codable, Identifiable, Hashable {
    var id = UUID()
    var time: Double
    var text: String
    var author: String
    var added = Date()
    var resolved = false
    var replies: [Reply] = []

    struct Reply: Codable, Identifiable, Hashable {
        var id = UUID()
        var text: String
        var author: String
        var added = Date()
    }

    /// "1:05" or "1:02:05".
    static func clock(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded(.down))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Review of renders made on the host: comments stored here per render, asked for by paired Macs
/// (`review…` actions) and shown to phones through the Library server's /review pages.
@MainActor
enum RemoteReview {
    static let textLimit = 2000
    static let commentLimit = 500

    /// Renders the self-test adds (they aren't real Resolve jobs).
    static var testJobs: [OfficeRenderServer.Job] = []

    /// Renders with a preview to review, newest first.
    static var renders: [OfficeRenderServer.Job] {
        (OfficeRenderServer.shared.jobs + testJobs).filter { $0.preview != nil }.sorted { $0.started > $1.started }
    }

    static func register() {
        OfficeActions.register("reviewComments") { arguments, device in
            ["comments": wire(load(try job(arguments["id"], device).id))]
        }
        OfficeActions.register("reviewAdd") { arguments, device in
            let job = try job(arguments["id"], device)
            let reply = try (arguments["reply"] as? String).map { try UUID(uuidString: OfficeActions.text($0, 40)).orThrow() }
            let time = (arguments["time"] as? NSNumber)?.doubleValue ?? 0
            return ["comments": wire(try add(job.id, time: time, text: try OfficeActions.text(arguments["text"], textLimit), author: device.name, reply: reply))]
        }
        OfficeActions.register("reviewResolve") { arguments, device in
            let job = try job(arguments["id"], device)
            let comment = try UUID(uuidString: OfficeActions.text(arguments["comment"], 40)).orThrow()
            return ["comments": wire(try resolve(job.id, comment: comment, resolved: arguments["resolved"] as? Bool ?? true))]
        }
    }

    /// A render of this Mac's (like the preview action: a paired Mac sees only its own renders).
    private static func job(_ value: Any?, _ device: OfficeRenderServer.Device) throws -> OfficeRenderServer.Job {
        let id = try OfficeActions.text(value, 40)
        guard let job = renders.first(where: { $0.id.uuidString == id && $0.deviceID == device.id }) else {
            throw OfficeLink.Failure.office(String(localized: "There’s no preview for that render (yet)."))
        }
        return job
    }

    private static func wire(_ comments: [ReviewComment]) -> [[String: Any]] {
        guard let data = try? JSONEncoder().encode(comments) else { return [] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }

    // MARK: - Store (one small JSON per render; kept on the main actor so edits never cross)

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/Office Render/Reviews", isDirectory: true)
    }

    static func load(_ job: UUID) -> [ReviewComment] {
        (try? JSONDecoder().decode([ReviewComment].self, from: Data(contentsOf: folder.appendingPathComponent(job.uuidString + ".json")))) ?? []
    }

    private static func save(_ comments: [ReviewComment], _ job: UUID) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(comments).write(to: folder.appendingPathComponent(job.uuidString + ".json"), options: .atomic)
    }

    /// A new comment at `time`, or a reply to `reply`.
    static func add(_ job: UUID, time: Double, text: String, author: String, reply: UUID? = nil) throws -> [ReviewComment] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= textLimit, time.isFinite, time >= 0 else { throw OfficeActions.incomplete() }
        var comments = load(job)
        if let reply {
            guard let index = comments.firstIndex(where: { $0.id == reply }), comments[index].replies.count < 100 else { throw OfficeActions.incomplete() }
            comments[index].replies.append(.init(text: text, author: author))
        } else {
            guard comments.count < commentLimit else { throw OfficeLink.Failure.office(String(localized: "This render has as many comments as it can hold.")) }
            comments.append(ReviewComment(time: time, text: text, author: author))
            comments.sort { $0.time < $1.time }
        }
        try save(comments, job)
        return comments
    }

    static func resolve(_ job: UUID, comment: UUID, resolved: Bool) throws -> [ReviewComment] {
        var comments = load(job)
        guard let index = comments.firstIndex(where: { $0.id == comment }) else { throw OfficeActions.incomplete() }
        comments[index].resolved = resolved
        try save(comments, job)
        return comments
    }

    // MARK: - Resolve markers

    /// The comments as an EDL of timeline markers, the layout DaVinci Resolve writes with Timeline ›
    /// Export › Timeline Markers to EDL and reads back with Timeline › Import › Timeline Markers from EDL.
    /// (The scripting docs don't cover that file; checked: their EDL export subtypes only. Done by
    /// script it would be Timeline.AddMarker(frameId, color, name, note, duration, customData).)
    /// shortcut: non-drop-frame and a whole-number frame rate only; drop-frame 29.97/59.94 timelines need a DF EDL.
    nonisolated static func markerEDL(_ comments: [ReviewComment], title: String, fps: Double, start: Double = 3600) -> String {
        let rate = max(1, Int(fps.rounded()))
        func timecode(_ seconds: Double) -> String {
            let frames = Int((seconds * Double(rate)).rounded())
            return String(format: "%02d:%02d:%02d:%02d", frames / (3600 * rate), frames / (60 * rate) % 60, frames / rate % 60, frames % rate)
        }
        func clean(_ text: String) -> String {
            text.components(separatedBy: .newlines).joined(separator: " ").replacingOccurrences(of: "|", with: "/")
        }
        var lines = ["TITLE: \(clean(title))", "FCM: NON-DROP FRAME", ""]
        for (index, comment) in comments.enumerated() {
            let inPoint = timecode(start + comment.time), outPoint = timecode(start + comment.time + 1 / Double(rate))
            let number = String(format: "%03d", index + 1)
            lines.append("\(number)  001      V     C        \(inPoint) \(outPoint) \(inPoint) \(outPoint)  ")
            let replies = comment.replies.map { " / \($0.author): \($0.text)" }.joined()
            let colour = comment.resolved ? "ResolveColorGreen" : "ResolveColorRed"
            lines.append(" |C:\(colour) |M:\(clean(comment.author + ": " + comment.text + replies)) |D:1")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Phone pages (through the Library server, after its session check)

    enum WebAnswer {
        case page(Int, String, [String: String])
        case file(String, String)
    }

    /// GET /review, /review/<id>, /review/<id>/video; POST /review/<id>/add, /review/<id>/resolve.
    static func web(_ request: LibraryServer.Request) -> WebAnswer {
        let parts = request.path.split(separator: "/").dropFirst().map(String.init)
        guard let id = parts.first else { return .page(200, listPage(), [:]) }
        guard let job = renders.first(where: { $0.id.uuidString == id }), let preview = job.preview else { return .page(404, notFound, [:]) }
        let back = ["Location": "/review/\(job.id.uuidString)"]
        switch (request.method, parts.count > 1 ? parts[1] : "") {
        case ("GET", ""), ("HEAD", ""):
            return .page(200, reviewPage(job), [:])
        case ("GET", "video"), ("HEAD", "video"):
            return .file(preview, job.timeline)
        case ("POST", "add"):
            let form = form(request.body)
            let reply = form["reply"].flatMap(UUID.init(uuidString:))
            _ = try? add(job.id, time: Double(form["time"] ?? "") ?? 0, text: form["text"] ?? "", author: author(request), reply: reply)
            return .page(303, "", back)
        case ("POST", "resolve"):
            if let comment = form(request.body)["comment"].flatMap(UUID.init(uuidString:)) {
                _ = try? resolve(job.id, comment: comment, resolved: form(request.body)["resolved"] == "1")
            }
            return .page(303, "", back)
        default:
            return .page(404, notFound, [:])
        }
    }

    nonisolated static func form(_ body: Data) -> [String: String] {
        var result: [String: String] = [:]
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { $0.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "" }
            if kv.count == 2 { result[kv[0]] = kv[1] }
        }
        return result
    }

    /// The kind of device, from its browser: never a name.
    nonisolated static func author(_ request: LibraryServer.Request) -> String {
        let agent = request.headers["user-agent"] ?? ""
        for kind in ["iPhone", "iPad", "Android", "Mac", "Windows"] where agent.contains(kind == "Mac" ? "Macintosh" : kind) { return kind }
        return String(localized: "Browser")
    }

    private static let e = LibraryPage.escape

    private static func page(_ title: String, _ body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="color-scheme" content="light dark"><title>\(e(title))</title><style>\(LibraryPage.style)
        .review{max-width:760px;margin:0 auto;padding:var(--gap) max(16px,env(safe-area-inset-left));display:flex;flex-direction:column;gap:12px}
        .review video{width:100%;border-radius:var(--radius-thumb);background:#000}
        .review a{color:inherit;text-decoration:none}.row{background:var(--card);border-radius:12px;padding:12px;display:flex;flex-direction:column;gap:6px}
        .row.done{opacity:.55}.top{display:flex;gap:8px;align-items:baseline}.tc{border:0;background:var(--chip);color:var(--text);border-radius:999px;padding:4px 10px;font:600 13px ui-monospace,monospace;cursor:pointer}
        .text{white-space:pre-wrap;word-break:break-word;margin:0}.reply{margin-left:16px;border-left:2px solid var(--line);padding-left:10px}
        .inline{display:flex;gap:8px}.inline input,textarea{flex:1;min-height:var(--control);border-radius:12px;border:1px solid var(--line);background:var(--card);color:var(--text);padding:10px 14px;font:inherit}
        textarea{resize:vertical}</style></head><body>\(body)</body></html>
        """
    }

    private static var notFound: String {
        page(String(localized: "Review"), "<div class=\"review\"><p class=\"empty\">\(e(String(localized: "This render isn’t here any more.")))</p></div>")
    }

    private static func listPage() -> String {
        let rows = renders.map { job in
            let count = load(job.id).filter { !$0.resolved }.count
            return "<a class=\"row\" href=\"/review/\(job.id.uuidString)\"><b>\(e(job.timeline))</b><span class=\"meta\">\(e(job.project)) · \(e(String(localized: "\(count) open")))</span></a>"
        }.joined()
        let empty = "<p class=\"empty\">\(e(String(localized: "No renders to review yet.")))</p>"
        return page(String(localized: "Review"), "<header><h1>\(e(String(localized: "Review")))</h1></header><div class=\"review\">\(rows.isEmpty ? empty : rows)</div>")
    }

    private static func reviewPage(_ job: OfficeRenderServer.Job) -> String {
        let id = job.id.uuidString
        let rows = load(job.id).map { comment in
            let replies = comment.replies.map { reply in
                "<div class=\"reply\"><span class=\"meta\">\(e(reply.author))</span><p class=\"text\">\(e(reply.text))</p></div>"
            }.joined()
            return """
            <div class="row\(comment.resolved ? " done" : "")"><div class="top"><button class="tc" data-t="\(String(format: "%.3f", comment.time))">\(ReviewComment.clock(comment.time))</button>
            <span class="meta">\(e(comment.author))</span></div><p class="text">\(e(comment.text))</p>\(replies)
            <form class="inline" method="post" action="/review/\(id)/add"><input type="hidden" name="reply" value="\(comment.id.uuidString)">
            <input name="text" maxlength="\(textLimit)" required placeholder="\(e(String(localized: "Reply")))" aria-label="\(e(String(localized: "Reply")))"></form>
            <form method="post" action="/review/\(id)/resolve"><input type="hidden" name="comment" value="\(comment.id.uuidString)">
            <input type="hidden" name="resolved" value="\(comment.resolved ? "0" : "1")"><button class="chip">\(e(comment.resolved ? String(localized: "Reopen") : String(localized: "Resolve")))</button></form></div>
            """
        }.joined()
        let body = """
        <header><h1><a href="/review" aria-label="\(e(String(localized: "Back")))">‹</a> \(e(job.timeline)) <small>\(e(job.project))</small></h1></header>
        <div class="review"><video id="v" src="/review/\(id)/video" controls playsinline preload="metadata"></video>
        <form class="inline" method="post" action="/review/\(id)/add" onsubmit="this.time.value=document.getElementById('v').currentTime">
        <input type="hidden" name="time" value="0"><textarea name="text" maxlength="\(textLimit)" required rows="2" placeholder="\(e(String(localized: "Comment at this moment")))" aria-label="\(e(String(localized: "Comment")))"></textarea>
        <button class="button primary">\(e(String(localized: "Add")))</button></form>\(rows)</div>
        <script>document.querySelectorAll('.tc').forEach(function(b){b.onclick=function(){var v=document.getElementById('v');v.currentTime=+b.dataset.t;v.pause()}})</script>
        """
        return page(job.timeline, body)
    }
}

@MainActor private extension Optional {
    func orThrow() throws -> Wrapped {
        guard let self else { throw OfficeActions.incomplete() }
        return self
    }
}

// MARK: - Remote Mac side

extension OfficeRenderClient {
    func reviewComments(_ job: Job) async throws -> [ReviewComment] {
        try Self.comments(try await ask("reviewComments", ["id": job.id], timeout: 30))
    }

    func addComment(_ job: Job, time: Double, text: String, reply: UUID? = nil) async throws -> [ReviewComment] {
        var arguments: [String: Any] = ["id": job.id, "time": time, "text": text]
        if let reply { arguments["reply"] = reply.uuidString }
        return try Self.comments(try await ask("reviewAdd", arguments, timeout: 30))
    }

    func resolveComment(_ job: Job, _ comment: UUID, resolved: Bool) async throws -> [ReviewComment] {
        try Self.comments(try await ask("reviewResolve", ["id": job.id, "comment": comment.uuidString, "resolved": resolved], timeout: 30))
    }

    private static func comments(_ answer: [String: Any]) throws -> [ReviewComment] {
        let data = try JSONSerialization.data(withJSONObject: answer["comments"] ?? [])
        return try JSONDecoder().decode([ReviewComment].self, from: data)
    }
}
