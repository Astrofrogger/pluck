import CryptoKit
import Foundation
import Network
import UniformTypeIdentifiers

/// Shares the Pluck Library on the local network: any phone, PC or Mac on the same network
/// opens a web page to browse, play and download what's in it. Off until turned on, behind an
/// access code, read-only, and only answering devices on the local network.
@MainActor
@Observable
final class LibraryServer {
    static let shared = LibraryServer()

    static let enabledKey = "libraryShared"
    static let codeKey = "librarySharedCode"
    /// Whoever has the code may add downloads (links) on this Mac.
    static let allowDownloadsKey = "librarySharedAllowDownloads"
    /// Whoever has the code may send files to this Mac.
    static let allowUploadsKey = "librarySharedAllowUploads"
    static let preferredPort: UInt16 = 47_800

    private(set) var isRunning = false
    private(set) var port: UInt16?
    private(set) var problem: String?
    /// The six-digit code people type to get in.
    private(set) var code: String

    @ObservationIgnored private var listener: NWListener?
    /// Sessions handed out after a correct code (kept until Pluck quits or the code changes).
    @ObservationIgnored private var sessions: Set<String> = []
    /// Wrong codes, to slow down guessing.
    @ObservationIgnored private var lockout = Lockout()
    /// Connections open now (capped, so a flood can't pile them up).
    @ObservationIgnored private var open = 0
    /// Library entries by their id, rebuilt when the Library changes.
    @ObservationIgnored private var idCache: (version: Int, entries: [String: LibraryStore.Entry]) = (-1, [:])
    @ObservationIgnored private let queue = DispatchQueue(label: "be.wideopen.pluck.library-server")
    /// Thumbnails from the web, fetched once.
    @ObservationIgnored private var remoteThumbnails: [String: (data: Data, type: String)] = [:]
    /// One-time links for Send to Phone: token → file and when it stops working.
    @ObservationIgnored private var sendLinks: [String: (path: String, expires: Date)] = [:]
    /// Where links and files from other devices go.
    @ObservationIgnored weak var manager: DownloadManager?

    private var isSharing: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    private var allowsDownloads: Bool { UserDefaults.standard.bool(forKey: Self.allowDownloadsKey) }
    private var allowsUploads: Bool { UserDefaults.standard.bool(forKey: Self.allowUploadsKey) }

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.codeKey)
        code = saved ?? Self.newCode()
        if saved == nil { UserDefaults.standard.set(code, forKey: Self.codeKey) }
    }

    /// The address to type in a browser, e.g. "http://annas-macbook.local:47800".
    var address: String? {
        guard isRunning, let port else { return nil }
        let host = (ProcessInfo.processInfo.hostName as NSString).deletingPathExtension
            .replacingOccurrences(of: ".local", with: "")
        return "http://\(host.isEmpty ? "localhost" : host).local:\(port)"
    }

    /// The same, with this Mac's IP address (for devices that don't resolve .local names).
    var numericAddress: String? {
        guard isRunning, let port, let ip = Self.localIPAddress() else { return nil }
        return "http://\(ip):\(port)"
    }

    // MARK: - Starting and stopping

    func startIfEnabled() {
        if UserDefaults.standard.bool(forKey: Self.enabledKey) { start() }
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { start() } else if !hasLiveSendLinks { stop() }
    }

    private var hasLiveSendLinks: Bool { sendLinks.values.contains { $0.expires > .now } }

    // MARK: - Send to Phone

    /// How long a Send to Phone link works.
    static let sendLinkLifetime: TimeInterval = 10 * 60

    /// A link that opens one file on any device on the network, without the code, for ten
    /// minutes. Starts the server for it if sharing is off (and stops it again afterwards).
    func sendLink(for file: URL) async -> URL? {
        start()
        for _ in 0..<40 where !isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        guard isRunning, let port, let ip = Self.localIPAddress() else { return nil }
        let token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        sendLinks[token] = (file.path, Date.now.addingTimeInterval(Self.sendLinkLifetime))
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sendLinkLifetime + 1) { [weak self] in
            guard let self else { return }
            self.sendLinks = self.sendLinks.filter { $0.value.expires > .now }
            if !self.isSharing, !self.hasLiveSendLinks { self.stop() }
        }
        return URL(string: "http://\(ip):\(port)/s/\(token)")
    }

    func start() {
        guard listener == nil else { return }
        problem = nil
        for candidate in [NWEndpoint.Port(rawValue: Self.preferredPort), NWEndpoint.Port.any] {
            guard let candidate else { continue }
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            guard let listener = try? NWListener(using: parameters, on: candidate) else { continue }
            // Other Macs with Pluck can find it by name.
            listener.service = NWListener.Service(name: Host.current().localizedName ?? "Pluck", type: "_pluck._tcp")
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerChanged(state) }
            }
            listener.start(queue: queue)
            self.listener = listener
            return
        }
        problem = String(localized: "Pluck couldn’t start sharing on this network.")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        port = nil
    }

    /// A new code: everyone who got in with the old one has to type the new one.
    func newAccessCode() {
        code = Self.newCode()
        UserDefaults.standard.set(code, forKey: Self.codeKey)
        sessions.removeAll()
    }

    private static func newCode() -> String {
        String(format: "%06d", Int.random(in: 0..<1_000_000))
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
            port = listener?.port?.rawValue
        case .failed(let error):
            problem = error.localizedDescription
            stop()
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    // MARK: - Requests

    private func accept(_ connection: NWConnection) {
        // Only devices on the local network (and this Mac itself).
        guard case .hostPort(let host, _) = connection.endpoint, Self.isLocal(host), open < 32 else {
            connection.cancel()
            return
        }
        open += 1
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed: connection.cancel()
            case .cancelled: Task { @MainActor in self?.open -= 1 }
            default: break
            }
        }
        connection.start(queue: queue)
        // A device that never finishes asking is let go after 30 seconds.
        let headIn = HeadFlag()
        queue.asyncAfter(deadline: .now() + 30) { if !headIn.done { connection.cancel() } }
        receive(on: connection, buffer: Data(), headIn: headIn)
    }

    /// Whether a connection's request head arrived; only touched on `queue`.
    private final class HeadFlag: @unchecked Sendable { var done = false }

    nonisolated private func receive(on connection: NWConnection, buffer: Data, headIn: HeadFlag) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                headIn.done = true
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                var body = buffer[end.upperBound...]
                let length = Int(Self.header("content-length", in: head) ?? "") ?? 0
                // A file being sent: checked as soon as the request line is in, then streamed.
                if head.hasPrefix("POST /api/upload") {
                    let request = Request(head: head, body: Data(body))
                    Task { @MainActor in self.handle(request, on: connection) }
                    return
                }
                if body.count < min(length, 16 * 1024), !complete, error == nil {
                    self.receive(on: connection, buffer: buffer, headIn: headIn)
                    return
                }
                body = body.prefix(16 * 1024)
                let request = Request(head: head, body: Data(body))
                Task { @MainActor in self.handle(request, on: connection) }
            } else if complete || error != nil || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer, headIn: headIn)
            }
        }
    }

    struct Request: Sendable {
        var method = "GET"
        var path = "/"
        var query: [String: String] = [:]
        var headers: [String: String] = [:]
        var body = Data()

        init(head: String, body: Data) {
            let lines = head.components(separatedBy: "\r\n")
            let parts = (lines.first ?? "").split(separator: " ")
            if parts.count >= 2 {
                method = String(parts[0])
                let target = String(parts[1])
                let components = URLComponents(string: target)
                path = components?.percentEncodedPath.removingPercentEncoding ?? target
                for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
            }
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            self.body = body
        }

        var cookies: [String: String] {
            var result: [String: String] = [:]
            for pair in (headers["cookie"] ?? "").split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if kv.count == 2 { result[kv[0]] = kv[1] }
            }
            return result
        }
    }

    private func handle(_ request: Request, on connection: NWConnection) {
        let client = Self.clientKey(connection)
        // Only asked for by address or .local name: a web page elsewhere can't point its own
        // name at this Mac (DNS rebinding) and read the Library through a visitor's browser.
        guard Self.isAllowedHost(request.headers["host"]) else {
            return respond(connection, status: 400, type: "text/plain", body: Data("Bad host".utf8))
        }
        guard request.method == "GET" || request.method == "HEAD" || request.method == "POST" else {
            return respond(connection, status: 405, type: "text/plain", body: Data("Not allowed".utf8))
        }
        if request.method == "POST", request.path == "/login" {
            return login(request, client: client, on: connection)
        }
        if request.path == "/style.css" || request.path == "/favicon.ico" {
            return respond(connection, status: 404, type: "text/plain", body: Data())
        }
        // A Send to Phone link: that one file, no code, until it expires.
        if request.path.hasPrefix("/s/") {
            let parts = request.path.dropFirst(3).split(separator: "/")
            let token = String(parts.first ?? "")
            guard let link = sendLinks[token], link.expires > .now else {
                return respond(connection, status: 410, type: "text/html; charset=utf-8", body: Data(LibraryPage.expired.utf8))
            }
            let file = URL(fileURLWithPath: link.path)
            let entry = LibraryStore.shared.entries.first { $0.path == link.path }
            let title = entry?.title ?? file.deletingPathExtension().lastPathComponent
            if parts.count > 1 {
                return serveFile(path: link.path, title: title, request: request, on: connection)
            }
            // A page that saves the file to the phone straight away (a bare file link would only
            // play it in the browser), with a button in case the browser holds the download back.
            let size = (try? FileManager.default.attributesOfItem(atPath: link.path)[.size] as? NSNumber)?.int64Value
            let page = LibraryPage.send(title: title, kind: entry?.kind.rawValue ?? "other",
                                        size: size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) },
                                        file: "/s/\(token)/file")
            return respond(connection, status: 200, type: "text/html; charset=utf-8", body: Data(page.utf8))
        }
        // With sharing off, the server only runs for Send to Phone links.
        guard isSharing else { return respond(connection, status: 404, type: "text/plain", body: Data("Not shared".utf8)) }
        guard Self.isAuthorised(request, sessions: sessions) else {
            if request.path == "/" { return respond(connection, status: 200, type: "text/html; charset=utf-8", body: Data(LibraryPage.login(error: false).utf8)) }
            return respond(connection, status: 401, type: "text/plain", body: Data("Access code needed".utf8))
        }
        switch request.path {
        case "/":
            respond(connection, status: 200, type: "text/html; charset=utf-8", body: Data(LibraryPage.library.utf8))
        case "/api/library":
            serveLibrary(on: connection)
        case "/api/downloads":
            respond(connection, status: 200, type: "application/json", body: downloadsJSON())
        case "/api/download" where request.method == "POST":
            addDownload(request, on: connection)
        case "/api/upload" where request.method == "POST":
            receiveUpload(request, on: connection)
        default:
            if request.path.hasPrefix("/file/") {
                serveFile(id: String(request.path.dropFirst("/file/".count)), request: request, on: connection)
            } else if request.path.hasPrefix("/thumb/") {
                serveThumbnail(id: String(request.path.dropFirst("/thumb/".count)), on: connection)
            } else {
                respond(connection, status: 404, type: "text/plain", body: Data("Not found".utf8))
            }
        }
    }

    /// Everything but logging in needs a session cookie from logging in (nothing else counts).
    nonisolated static func isAuthorised(_ request: Request, sessions: Set<String>) -> Bool {
        request.cookies["pluck_session"].map(sessions.contains) ?? false
    }

    private func login(_ request: Request, client: String, on connection: NWConnection) {
        if lockout.isLocked(client) {
            return respond(connection, status: 429, type: "text/html; charset=utf-8", body: Data(LibraryPage.login(error: true).utf8))
        }
        let form = String(decoding: request.body, as: UTF8.self)
        let typed = form.split(separator: "&").compactMap { pair -> String? in
            let kv = pair.split(separator: "=", maxSplits: 1)
            return kv.count == 2 && kv[0] == "code" ? String(kv[1]).removingPercentEncoding : nil
        }.first?.filter(\.isNumber) ?? ""
        guard Self.sameCode(typed, code) else {
            lockout.fail(client)
            return respond(connection, status: 200, type: "text/html; charset=utf-8", body: Data(LibraryPage.login(error: true).utf8))
        }
        lockout.succeed(client)
        let token = UUID().uuidString + UUID().uuidString
        sessions.insert(token)
        respond(connection, status: 303, type: "text/plain", body: Data(),
                extra: ["Location": "/", "Set-Cookie": "pluck_session=\(token); Path=/; HttpOnly; SameSite=Strict; Max-Age=2592000"])
    }

    // MARK: - The library

    /// A stable, unguessable id per file (so paths never leave this Mac).
    private static func id(for path: String) -> String {
        SHA256.hash(data: Data(("pluck:" + path).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private var entriesByID: [String: LibraryStore.Entry] {
        let store = LibraryStore.shared
        if idCache.version != store.version {
            idCache = (store.version, Dictionary(store.entries.map { (Self.id(for: $0.path), $0) }, uniquingKeysWith: { first, _ in first }))
        }
        return idCache.entries
    }

    private func entry(for id: String) -> LibraryStore.Entry? { entriesByID[id] }

    /// Built off the main thread: checking every file is there takes a while in a big Library.
    private func serveLibrary(on connection: NWConnection) {
        let entries = entriesByID, canDownload = allowsDownloads, canUpload = allowsUploads
        Task.detached {
            let body = Self.libraryJSON(entries, canDownload: canDownload, canUpload: canUpload)
            self.respond(connection, status: 200, type: "application/json", body: body)
        }
    }

    nonisolated private static func libraryJSON(_ entries: [String: LibraryStore.Entry], canDownload: Bool, canUpload: Bool) -> Data {
        let iso = ISO8601DateFormatter()
        let items: [[String: Any]] = entries
            .map { (id: $0.key, entry: $0.value) }
            .filter { $0.entry.kind != .other && FileManager.default.fileExists(atPath: $0.entry.path) }
            .sorted { $0.entry.added > $1.entry.added }
            .map { id, entry in
                var item: [String: Any] = ["id": id, "title": entry.title, "kind": entry.kind.rawValue,
                                           "added": iso.string(from: entry.added), "tags": entry.tags,
                                           "ext": entry.file.pathExtension.lowercased()]
                if let uploader = entry.uploader { item["uploader"] = uploader }
                if let site = entry.site { item["site"] = site }
                if let size = entry.size { item["size"] = size }
                if let duration = entry.duration { item["duration"] = duration }
                if entry.thumbnail != nil || entry.kind == .photo { item["thumb"] = "/thumb/" + id }
                return item
            }
        let name = Host.current().localizedName ?? "Pluck"
        return (try? JSONSerialization.data(withJSONObject: ["name": name, "items": items, "canDownload": canDownload,
                                                             "canUpload": canUpload])) ?? Data("{}".utf8)
    }

    private func serveThumbnail(id: String, on connection: NWConnection) {
        guard let entry = entry(for: id) else { return respond(connection, status: 404, type: "text/plain", body: Data()) }
        if let thumbnail = entry.thumbnail, !thumbnail.isFileURL {
            // Only pictures on the internet: a site's metadata can't make this Mac fetch from the local network.
            guard Self.isPublicWeb(thumbnail) else { return respond(connection, status: 404, type: "text/plain", body: Data()) }
            // A picture on the web (YouTube's thumbnail): fetched once by this Mac and served from
            // here, so it shows on a network without internet and phones don't contact the site.
            if let cached = remoteThumbnails[id] {
                return respond(connection, status: 200, type: cached.type, body: cached.data, extra: ["Cache-Control": "max-age=86400"])
            }
            Task {
                var request = URLRequest(url: thumbnail, timeoutInterval: 10)
                request.setValue("image/*", forHTTPHeaderField: "Accept")
                if let (data, response) = try? await URLSession.shared.data(for: request),
                   (response as? HTTPURLResponse)?.statusCode == 200, data.count < 5_000_000 {
                    let type = (response as? HTTPURLResponse)?.mimeType ?? "image/jpeg"
                    remoteThumbnails[id] = (data, type)
                    respond(connection, status: 200, type: type, body: data, extra: ["Cache-Control": "max-age=86400"])
                } else {
                    respond(connection, status: 404, type: "text/plain", body: Data())
                }
            }
            return
        }
        let file = entry.thumbnail ?? entry.file
        Task.detached {
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count < 30_000_000 else {
                return self.respond(connection, status: 404, type: "text/plain", body: Data())
            }
            self.respond(connection, status: 200, type: Self.mimeType(file), body: data, extra: ["Cache-Control": "max-age=86400"])
        }
    }

    /// Streams a file, with byte ranges so browsers can seek in video.
    private func serveFile(id: String, request: Request, on connection: NWConnection) {
        guard let entry = entry(for: id) else { return respond(connection, status: 404, type: "text/plain", body: Data("Not found".utf8)) }
        serveFile(path: entry.path, title: entry.title, request: request, on: connection)
    }

    private func serveFile(path: String, title: String, request: Request, on connection: NWConnection) {
        let file = URL(fileURLWithPath: path)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value,
              let handle = FileHandle(forReadingAtPath: path) else {
            return respond(connection, status: 404, type: "text/plain", body: Data("Not found".utf8))
        }
        var start: Int64 = 0, end: Int64 = size - 1, status = 200
        if let range = request.headers["range"], range.hasPrefix("bytes=") {
            let spec = range.dropFirst("bytes=".count).split(separator: ",").first ?? ""
            let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
            if bounds.count == 2 {
                if bounds[0].isEmpty, let suffix = Int64(bounds[1]) {
                    start = max(0, size - suffix)
                } else {
                    start = Int64(bounds[0]) ?? 0
                    if let last = Int64(bounds[1]) { end = min(last, size - 1) }
                }
            }
            guard start <= end, start < size else {
                try? handle.close()
                return respond(connection, status: 416, type: "text/plain", body: Data(), extra: ["Content-Range": "bytes */\(size)"])
            }
            status = 206
        }
        let name = title.replacingOccurrences(of: "\"", with: "'") + "." + file.pathExtension
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "file"
        var headers = ["Accept-Ranges": "bytes",
                       "Content-Disposition": "\(request.query["download"] != nil ? "attachment" : "inline"); filename*=UTF-8''\(encoded)"]
        if status == 206 { headers["Content-Range"] = "bytes \(start)-\(end)/\(size)" }
        let length = end - start + 1
        let head = Self.head(status: status, type: Self.mimeType(file), length: length, extra: headers)
        let isHead = request.method == "HEAD"
        connection.send(content: head, completion: .contentProcessed { [weak self] error in
            guard error == nil, !isHead else { try? handle.close(); connection.cancel(); return }
            try? handle.seek(toOffset: UInt64(start))
            self?.sendChunks(handle, remaining: length, on: connection)
        })
    }

    nonisolated private func sendChunks(_ handle: FileHandle, remaining: Int64, on connection: NWConnection) {
        guard remaining > 0, let chunk = try? handle.read(upToCount: Int(min(remaining, 1 << 20))), !chunk.isEmpty else {
            try? handle.close()
            connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { try? handle.close(); connection.cancel(); return }
            self.sendChunks(handle, remaining: remaining - Int64(chunk.count), on: connection)
        })
    }

    // MARK: - Links and files from other devices

    /// What's downloading on this Mac (and what just finished), for the page's progress list.
    private func downloadsJSON() -> Data {
        let items: [[String: Any]] = (manager?.items ?? []).prefix(30).compactMap { item in
            let state: String
            switch item.state {
            case .queued, .starting: state = "waiting"
            case .downloading, .processing: state = "downloading"
            case .paused: state = "paused"
            case .finished: state = "done"
            case .failed: state = "failed"
            case .cancelled: return nil
            }
            // Finished ones only for a while, so the list stays about now.
            if item.state == .finished, let done = item.finishedAt, Date().timeIntervalSince(done) > 600 { return nil }
            var result: [String: Any] = ["title": item.title, "state": state, "progress": item.progress]
            if let file = item.fileURL, item.state == .finished, LibraryStore.shared.entries.contains(where: { $0.path == file.path }) {
                result["id"] = Self.id(for: file.path)
            }
            return result
        }
        return (try? JSONSerialization.data(withJSONObject: ["items": items])) ?? Data("{}".utf8)
    }

    /// A link to download on this Mac, from the page or another Pluck.
    private func addDownload(_ request: Request, on connection: NWConnection) {
        guard allowsDownloads, let manager else {
            return respond(connection, status: 403, type: "text/plain", body: Data("Adding downloads is off on this Mac".utf8))
        }
        let text = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any])?["url"] as? String
            ?? String(decoding: request.body, as: UTF8.self)
        let links = Links.extract(fromText: text).prefix(50)
        guard !links.isEmpty else { return respond(connection, status: 400, type: "text/plain", body: Data("No link".utf8)) }
        // Into the Downloads folder from Settings, never a save panel nobody is there to answer.
        let folder = UserDefaults.standard.string(forKey: Prefs.downloadPath) ?? NSHomeDirectory() + "/Downloads"
        manager.add(Array(links), folder: folder)
        respond(connection, status: 200, type: "application/json", body: Data("{\"added\":\(links.count)}".utf8))
    }

    /// A file sent from another device, streamed into the Downloads folder and added to the Library.
    private func receiveUpload(_ request: Request, on connection: NWConnection) {
        guard allowsUploads, let manager else {
            return respond(connection, status: 403, type: "text/plain", body: Data("Receiving files is off on this Mac".utf8))
        }
        guard let length = Int64(request.headers["content-length"] ?? ""), length > 0, length < 50_000_000_000 else {
            return respond(connection, status: 411, type: "text/plain", body: Data("Length needed".utf8))
        }
        let raw = (request.query["name"] ?? "").removingPercentEncoding ?? ""
        // Just the name (no folders), and no leading dots that would hide it.
        let original = URL(fileURLWithPath: raw.isEmpty ? "File" : raw).lastPathComponent
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        // (sanitize names an empty string "Playlist", so empty parts get their own fallback.)
        let rawName = URL(fileURLWithPath: original).deletingPathExtension().lastPathComponent
        let rawExt = URL(fileURLWithPath: original).pathExtension
        let name = rawName.isEmpty ? "" : Folders.sanitize(rawName)
        let ext = rawExt.isEmpty ? "" : Folders.sanitize(rawExt).replacingOccurrences(of: " ", with: "")
        let folder = UserDefaults.standard.string(forKey: Prefs.downloadPath) ?? NSHomeDirectory() + "/Downloads"
        // (The "important usage" figure is 0 or missing on servers and some drives: then the plain one,
        // then the file system's; unknown lets it through.)
        let values = try? URL(fileURLWithPath: folder).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        var info = statfs()
        let free: Int64? = if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { important }
            else if let plain = values?.volumeAvailableCapacity, plain > 0 { Int64(plain) }
            else if statfs(folder, &info) == 0 { Int64(info.f_bavail) * Int64(info.f_bsize) }
            else { nil }
        // Room for it, with 1 GB left over for the Mac.
        if let free, length + 1_000_000_000 >= free {
            return respond(connection, status: 507, type: "text/plain", body: Data("Not enough space on this Mac".utf8))
        }
        // Its own partial file (two sends of one name at once don't mix); the name is picked when it's in.
        let partial = URL(fileURLWithPath: folder).appendingPathComponent(".pluck-upload-\(UUID().uuidString).part")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil),
              let handle = FileHandle(forWritingAtPath: partial.path) else {
            return respond(connection, status: 500, type: "text/plain", body: Data("Couldn’t save".utf8))
        }
        try? handle.write(contentsOf: request.body.prefix(Int(length)))
        let received = Int64(min(request.body.count, Int(length)))
        // Some senders wait for a go-ahead before the body.
        if request.headers["expect"]?.lowercased() == "100-continue" {
            connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
        }
        streamUpload(on: connection, into: handle, received: received, length: length) { [weak self] ok in
            Task { @MainActor in
                guard let self else { return }
                let destination = Converting.outputURL(folder: folder, name: name.isEmpty ? "File" : name, fileExtension: ext.isEmpty ? "bin" : ext)
                if ok, (try? FileManager.default.moveItem(at: partial, to: destination)) != nil {
                    _ = manager.addLocalFiles([destination])
                    manager.saveHistory()
                    self.respond(connection, status: 200, type: "application/json", body: Data("{\"saved\":true}".utf8))
                } else {
                    try? FileManager.default.removeItem(at: partial)
                    self.respond(connection, status: 400, type: "text/plain", body: Data("Incomplete".utf8))
                }
            }
        }
    }

    nonisolated private func streamUpload(on connection: NWConnection, into handle: FileHandle, received: Int64, length: Int64,
                                          done: @escaping @Sendable (Bool) -> Void) {
        guard received < length else {
            try? handle.close()
            return done(true)
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            if let data, !data.isEmpty {
                do { try handle.write(contentsOf: data) } catch { try? handle.close(); return done(false) }
            }
            let total = received + Int64(data?.count ?? 0)
            if total >= length {
                try? handle.close()
                done(true)
            } else if complete || error != nil || self == nil {
                try? handle.close()
                done(false)
            } else {
                self?.streamUpload(on: connection, into: handle, received: total, length: length, done: done)
            }
        }
    }

    // MARK: - HTTP

    nonisolated private func respond(_ connection: NWConnection, status: Int, type: String, body: Data, extra: [String: String] = [:]) {
        var data = Self.head(status: status, type: type, length: Int64(body.count), extra: extra)
        data.append(body)
        connection.send(content: data, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    nonisolated private static func head(status: Int, type: String, length: Int64, extra: [String: String]) -> Data {
        let reason = [200: "OK", 206: "Partial Content", 302: "Found", 303: "See Other", 400: "Bad Request", 401: "Unauthorized",
                      403: "Forbidden", 404: "Not Found", 410: "Gone", 411: "Length Required", 500: "Internal Server Error", 507: "Insufficient Storage",
                      405: "Method Not Allowed", 416: "Range Not Satisfiable", 429: "Too Many Requests"][status] ?? "OK"
        var lines = ["HTTP/1.1 \(status) \(reason)", "Content-Type: \(type)", "Content-Length: \(length)", "Connection: close",
                     "X-Content-Type-Options: nosniff", "Referrer-Policy: no-referrer"]
        for (key, value) in extra { lines.append("\(key): \(value)") }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    nonisolated private static func header(_ name: String, in head: String) -> String? {
        for line in head.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == name { return parts[1].trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    nonisolated private static func mimeType(_ file: URL) -> String {
        UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    // MARK: - The local network

    private static func clientKey(_ connection: NWConnection) -> String {
        if case .hostPort(let host, _) = connection.endpoint { return "\(host)" }
        return "?"
    }

    /// Private, link-local and loopback addresses: the devices on this network.
    nonisolated static func isLocal(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address):
            let b = [UInt8](address.rawValue)
            guard b.count == 4 else { return false }
            return b[0] == 10 || b[0] == 127 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
                || (b[0] == 169 && b[1] == 254)
        case .ipv6(let address):
            let b = [UInt8](address.rawValue)
            guard b.count == 16 else { return false }
            if address == .loopback { return true }
            if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 { return true }        // link-local
            if (b[0] & 0xFE) == 0xFC { return true }                         // unique local
            // An IPv4 address carried in IPv6 (::ffff:a.b.c.d).
            if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF,
               let v4 = IPv4Address(Data(b[12..<16])) {
                return isLocal(.ipv4(v4))
            }
            return false
        default:
            return false
        }
    }

    /// A Host header naming this Mac by address, .local name or localhost (never a web site's name).
    nonisolated static func isAllowedHost(_ header: String?) -> Bool {
        guard var host = header?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return false }
            return IPv6Address(String(host[host.index(after: host.startIndex)..<close])) != nil
        }
        if let colon = host.lastIndex(of: ":") { host = String(host[..<colon]) }
        if host.hasSuffix(".") { host.removeLast() }
        return host == "localhost" || (host.hasSuffix(".local") && host.count > 6) || IPv4Address(host) != nil
    }

    /// An http(s) address on the internet: not this Mac, the local network or a .local name.
    /// shortcut: a public name that resolves to a local address still passes; resolve first if that matters.
    nonisolated static func isPublicWeb(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return false }
        // inet_aton also reads the old forms ("2130706433", "0x7f.1") a connection would accept.
        var v4 = in_addr()
        if inet_aton(host, &v4) != 0, let ip = IPv4Address(withUnsafeBytes(of: v4.s_addr) { Data($0) }) {
            return !isLocal(.ipv4(ip)) && ip.rawValue.first != 0
        }
        if let ip = IPv6Address(host) { return !isLocal(.ipv6(ip)) && ip != .any }
        return true
    }

    /// The same code, compared in constant time.
    nonisolated static func sameCode(_ typed: String, _ code: String) -> Bool {
        let a = Array(typed.utf8), b = Array(code.utf8)
        return a.count == b.count && zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Wrong codes: ten from one address in ten minutes locks that address out for the rest of
    /// them; thirty from anywhere locks everyone out (so many addresses can't share the guessing).
    struct Lockout {
        static let window: TimeInterval = 600
        private var perAddress: [String: (count: Int, since: Date)] = [:]
        private var all: (count: Int, since: Date) = (0, .distantPast)

        func isLocked(_ client: String, now: Date = .now) -> Bool {
            if all.count >= 30, now.timeIntervalSince(all.since) < Self.window { return true }
            guard let record = perAddress[client] else { return false }
            return record.count >= 10 && now.timeIntervalSince(record.since) < Self.window
        }

        mutating func fail(_ client: String, now: Date = .now) {
            func counted(_ record: (count: Int, since: Date)?) -> (count: Int, since: Date) {
                guard let record, now.timeIntervalSince(record.since) < Self.window else { return (1, now) }
                return (record.count + 1, record.since)
            }
            perAddress[client] = counted(perAddress[client])
            all = counted(all)
        }

        mutating func succeed(_ client: String) { perAddress[client] = nil }
    }

    /// This Mac's address on the local network (Wi-Fi or Ethernet).
    nonisolated static func localIPAddress() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var candidates: [(name: String, address: String)] = []
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(item.pointee.ifa_flags)
            guard let addr = item.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            guard let ip = IPv4Address(address), isLocal(.ipv4(ip)), !address.hasPrefix("169.254") else { continue }
            candidates.append((String(cString: item.pointee.ifa_name), address))
        }
        // Ethernet and Wi-Fi (en…) before anything else (VPNs, bridges).
        return (candidates.first { $0.name.hasPrefix("en") } ?? candidates.first)?.address
    }
}
