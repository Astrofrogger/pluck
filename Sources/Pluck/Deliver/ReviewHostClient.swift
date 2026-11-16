import AppKit
import CryptoKit
import ImageIO
import Network
import SwiftUI
import UniformTypeIdentifiers

/// A NAS host's sync endpoint (spec §12.6), every call in one place: TCP on the LAN, TLS 1.3 with the host's
/// self-signed certificate pinned by its SHA-256, the host key first, then JSON lines, one answer per request.
@MainActor
enum ReviewHostClient {
    struct Entry: Hashable { var name: String; var path: String; var folder: Bool; var size: Int64?; var modified: Date? }

    /// Tests stand in for the NAS here: a request (and a put's bytes) in, the answer out.
    static var fake: (([String: Any], Data?) -> [String: Any]?)?

    /// `pluck-host:<key>@<fingerprint>`, or a bare key (Pluck made it; the certificate is pinned on first connect).
    static func pairing(_ text: String) -> (key: String, pin: String?)? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = text.hasPrefix("pluck-host:") ? String(text.dropFirst("pluck-host:".count)) : text
        let parts = body.split(separator: "@", maxSplits: 1).map(String.init)
        guard let key = parts.first, DeliverKeys.data(base64url: key)?.count == 32 else { return nil }
        let pin = parts.count > 1 ? parts[1].uppercased() : nil
        if let pin, pin.split(separator: ":").count != 32 { return nil }
        return (key, pin)
    }

    static func key(_ host: Deliver.Host) -> String? {
        host.address.flatMap { DeliverKeychain.load($0, service: DeliverKeychain.hostService) }.map { String(decoding: $0, as: UTF8.self) }
    }

    /// This Mac's own key on the host (§13.2 pairing): Keychain account `<hostID>/<deviceID>`.
    static func deviceKey(_ host: Deliver.Host) -> String? {
        guard let device = host.device else { return nil }
        return DeliverKeychain.load("\(host.id.uuidString)/\(device)", service: DeliverKeychain.hostService).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Pluck's protocol level (§13.15), sent in every auth line.
    nonisolated static let protocolLevel = 3
    /// Tests: the certificate a fake host shows (nil: none checked).
    static var fakeFingerprint: String?

    /// A NAS whose certificate isn't confirmed yet: the key isn't sent until the owner has checked this
    /// fingerprint against the one in the NAS's log (ReviewPublish.pinned).
    struct Unconfirmed: Error { var fingerprint: String }

    /// One connection: the certificate must match the pin, the key is checked, then `work` asks what it needs.
    static func session(_ host: Deliver.Host, _ work: (HostSession) async throws -> Void) async throws {
        // The record as it is now (Pair Again may have changed its pin since a caller took its copy).
        let host = ReviewPublish.shared.host(host.id) ?? host
        let legacy = key(host), device = deviceKey(host)
        guard legacy != nil || device != nil else { throw Deliver.Failure("auth") }
        var route = try await ReviewHostTunnel.route(host)
        var session = HostSession(address: route.address, pin: host.pin, fake: fake)
        defer { session.close() }
        do {
            try await session.open()
        } catch {
            // The way that worked last may have gone (a NAS back after an outage, the tunnel reconnecting): once more, routed again.
            session.close()
            ReviewHostTunnel.forgetRoute(host.id)
            try? await Task.sleep(for: .seconds(1))
            route = try await ReviewHostTunnel.route(host)
            session = HostSession(address: route.address, pin: host.pin, fake: fake)
            try await session.open()
        }
        guard host.pin != nil else { throw Unconfirmed(fingerprint: (fake == nil ? session.fingerprint : fakeFingerprint) ?? "") }
        // The legacy host key on the LAN; this Mac's device key over iroh, or when it has no host key.
        var hello: [String: Any] = ["protocol": protocolLevel]
        if let device, let id = host.device, route.via != .lan || legacy == nil { hello["device"] = id; hello["key"] = device } else { hello["key"] = legacy! }
        let answer: [String: Any]
        // A wrong key: the host waits a second and closes without a word (sync.rs `hello`).
        // (TLS is up by now, so a connection closed or reset here is that, not a NAS that's away.)
        // A device key refused: this Mac was removed there (a teammate's Mac needs a new invitation, not Pair Again).
        let refused = Deliver.Failure(hello["device"] != nil ? "removed" : "auth")
        do { answer = try await session.ask(hello) } catch {
            if (error as? Deliver.Failure)?.code == "closed" || error is NWError { throw refused }
            throw error
        }
        guard answer["ok"] as? Bool == true else { throw refused }
        session.protocolLevel = answer["protocol"] as? Int ?? 2
        ReviewPublish.shared.seen(host.id, version: answer["version"] as? String, protocol: answer["protocol"] as? Int, via: route.via)
        try await work(session)
    }

    /// §13.2: pairs with a NAS from its invitation. The TLS certificate must match the link's `fp` before the code
    /// is sent; the host's answer gives this Mac its own device key.
    static func pair(_ invitation: PrivateNetwork.Invitation, publish: ReviewPublish = .shared) async throws -> Deliver.Host {
        guard case .reviewHost(let node, let relay, let expires, let pin, let lan, let role) = invitation.way else { throw Deliver.Failure("invalid") }
        guard expires > .now else { throw PrivateNetwork.Failure.inviteExpired }
        // (No node: a server without iroh, joined on the office network only.)
        var host = Deliver.Host(name: invitation.name, kind: .nas, address: lan, pin: pin, node: node.isEmpty ? nil : node, relay: relay, role: role)
        var session: HostSession?
        defer { session?.close() }
        var line: [String: Any] = ["pair": invitation.code, "name": Host.current().localizedName ?? "Mac", "role": "mac", "protocol": protocolLevel]
        do {
            if host.node != nil { line["node"] = try await ReviewHostTunnel.nodeID(host) }
            let route = try await ReviewHostTunnel.route(host)
            session = HostSession(address: route.address, pin: pin, fake: fake)
            try await session!.open()
        } catch {
            throw (error as? Deliver.Failure)?.code == "pin" ? error : Deliver.Failure("unreachable")
        }
        guard let session, (fake == nil ? session.fingerprint : fakeFingerprint) == pin else { throw Deliver.Failure("pin") }
        let answer: [String: Any]
        // A code the server doesn't know (used, or run out there): it waits a second and closes without a word.
        do { answer = try await session.ask(line) } catch {
            if (error as? Deliver.Failure)?.code == "closed" || error is NWError { throw PrivateNetwork.Failure.inviteUsed }
            throw error
        }
        guard answer["ok"] as? Bool == true, let device = answer["device"] as? String, let key = answer["key"] as? String,
              let info = answer["host"] as? [String: Any], let id = (info["id"] as? String).flatMap(UUID.init(uuidString:)) else { throw Deliver.Failure("auth") }
        // The id is the answering server's claim: it may only name a host already paired here when it's that host
        // (its certificate or iroh node), never take over another one's record, key and data routing.
        if let paired = publish.host(id), paired.pin != pin, paired.node != node { throw Deliver.Failure("taken") }
        ReviewHostTunnel.moved(from: host.id, to: id)
        host.id = id
        host.name = Deliver.clean(info["name"] as? String ?? invitation.name, limit: 80)
        host.role = info["role"] as? String ?? role
        host.device = device
        host.version = answer["version"] as? String
        host.protocol = answer["protocol"] as? Int
        host.lastSeen = .now
        DeliverKeychain.save(Data(key.utf8), as: "\(id.uuidString)/\(device)", service: DeliverKeychain.hostService)
        publish.add(host)
        return host
    }

    /// What went wrong reaching a host, in words: not answering, this Mac's key refused, or a different certificate.
    static func problem(_ error: Error) -> String {
        if error is Unconfirmed { return String(localized: "Its certificate isn’t confirmed yet: Pair Again") }
        switch (error as? Deliver.Failure)?.code {
        case "auth": return String(localized: "The NAS server doesn’t accept this Mac’s key: Pair Again")
        case "removed": return String(localized: "This Mac was removed from the review server. Ask its owner for a new invitation.")
        case "pin": return String(localized: "The NAS server shows a different certificate than the one Pluck pinned. If you reinstalled it, Pair Again with its new pairing line")
        case "incompatible": return String(localized: "The NAS server runs a version this Pluck can’t talk to. Update it")
        case let code? where code.localizedCaseInsensitiveContains("permission denied"):
            return String(localized: "The NAS server may not read this folder. In TrueNAS: Datasets › the dataset › Permissions › Edit, Add Item (User apps, Read, Flags Inherit), tick “Apply permissions recursively” and “to child datasets”, then Save Access Control List.")
        case let code? where code.contains(" "):
            // The server answered with its own reason (a sentence, not one of the short codes above).
            return String(localized: "The NAS server says: \(code)")
        default: return String(localized: "The NAS isn’t answering")
        }
    }

    static func ask(_ host: Deliver.Host, _ request: [String: Any]) async throws -> [String: Any] {
        var answer: [String: Any] = [:]
        try await session(host) { answer = try await $0.ask(request) }
        return answer
    }

    /// The media root ids ("nas1", "nas2").
    static func roots(_ host: Deliver.Host) async throws -> [String] {
        try await ask(host, ["op": "roots"])["roots"] as? [String] ?? []
    }

    /// A folder by media path ("" lists the roots).
    static func browse(_ host: Deliver.Host, path: String) async throws -> [Entry] {
        (try await ask(host, ["op": "browse", "path": path])["entries"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let name = entry["name"] as? String, !name.contains("/"), let path = entry["path"] as? String else { return nil }
            return Entry(name: name, path: path, folder: entry["dir"] as? Bool ?? false, size: (entry["size"] as? NSNumber)?.int64Value,
                         modified: (entry["modified"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) })
        }
    }

    static func thumb(_ host: Deliver.Host, path: String) async throws -> Data? {
        (try await ask(host, ["op": "thumb", "path": path])["jpeg"] as? String).flatMap(DeliverKeys.data(base64url:))
    }
}

/// One TLS connection to a sync endpoint (Network framework). The certificate must match the pin (when set);
/// the one seen is kept in `fingerprint`.
final class HostSession: @unchecked Sendable {
    /// The host's protocol from its auth answer (§13.15; 2 when it doesn't say).
    var protocolLevel = 2
    /// The last answer that was an error (offset errors carry `have`).
    private(set) var lastError: [String: Any]?
    private let connection: NWConnection?
    private let fake: (([String: Any], Data?) -> [String: Any]?)?
    private let queue = DispatchQueue(label: "be.wideopen.pluck.review-host")
    private var buffer = Data()
    private(set) var fingerprint: String?

    private let pin: String?

    init(address: String, pin: String?, fake: (([String: Any], Data?) -> [String: Any]?)?) {
        self.fake = fake
        self.pin = pin
        guard fake == nil else { connection = nil; return }
        let parts = address.split(separator: ":")
        let port = NWEndpoint.Port(rawValue: UInt16(parts.count > 1 ? String(parts.last!) : "") ?? 8790) ?? 8790
        let name = parts.count > 1 ? parts.dropLast().joined(separator: ":") : address
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        let box = FingerprintBox()
        sec_protocol_options_set_verify_block(options, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let leaf = (SecTrustCopyCertificateChain(secTrust) as? [SecCertificate])?.first else { return complete(false) }
            let seen = HostSession.fingerprint(SecCertificateCopyData(leaf) as Data)
            box.value = seen
            complete(pin == nil || pin.flatMap(HostSession.normalized) == seen)
        }, queue)
        connection = NWConnection(host: NWEndpoint.Host(name), port: port, using: NWParameters(tls: tls))
        self.box = box
    }
    private var box: FingerprintBox?
    private final class FingerprintBox: @unchecked Sendable { var value: String? }

    /// Any spelling of a SHA-256 fingerprint (any case; colons, dashes, spaces or none) as Pluck keeps it; nil when it isn't 32 bytes.
    static func normalized(_ text: String) -> String? {
        let hex = text.uppercased().filter { $0.isHexDigit }
        guard hex.count == 64, text.allSatisfy({ $0.isHexDigit || ": -\n\t".contains($0) }) else { return nil }
        return stride(from: 0, to: 64, by: 2).map { i in String(hex.dropFirst(i).prefix(2)) }.joined(separator: ":")
    }

    /// Uppercase hex with colons, as the host prints it.
    static func fingerprint(_ der: Data) -> String { SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":") }

    func open() async throws {
        guard let connection else { return }
        do { try await start(connection) } catch {
            // The certificate was seen and isn't the pinned one: its own failure, not "not answering".
            if let pin, let seen = box?.value, HostSession.normalized(pin) != seen { throw Deliver.Failure("pin") }
            throw error
        }
        fingerprint = box?.value
    }

    private func start(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { continuation.resume() }
                case .failed(let error), .waiting(let error): if once.claim() { continuation.resume(throwing: error) }
                case .cancelled: if once.claim() { continuation.resume(throwing: CancellationError()) }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 10) { if once.claim() { continuation.resume(throwing: Deliver.Failure("internal")) } }
        }
    }

    /// A request line (and a put's bytes), then its answer line; `{"error"}` throws.
    func ask(_ request: [String: Any], payload: Data? = nil) async throws -> [String: Any] {
        if let fake {
            guard let answer = fake(request, payload) else { throw Deliver.Failure("internal") }
            try check(answer)
            return answer
        }
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)
        try await send(data)
        // (In 4 MB pieces as `put` sends: each has its own timeout, so a big part finishes on a slow uplink.)
        if let payload {
            for start in stride(from: payload.startIndex, to: payload.endIndex, by: Self.chunk) {
                try await send(payload.subdata(in: start..<min(start + Self.chunk, payload.endIndex)))
            }
        }
        return try await answer()
    }

    private func answer() async throws -> [String: Any] {
        let line = try await line()
        guard let answer = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw Deliver.Failure("internal") }
        try check(answer)
        return answer
    }

    /// `{"error":"offset"}` or `{"error":{"code":…}}` throws that code (kept in `lastError`).
    private func check(_ answer: [String: Any]) throws {
        guard let error = answer["error"] else { return }
        lastError = answer
        throw Deliver.Failure(error as? String ?? (error as? [String: Any])?["code"] as? String ?? "internal")
    }

    static let chunk = 4 << 20

    /// A bundle file (`copies/<V>/…`, an original), its bytes after the request line, read in 4 MB pieces.
    func put(_ path: String, _ url: URL) async throws -> [String: Any] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let request: [String: Any] = ["op": "put", "path": path, "size": size]
        if fake != nil { return try await ask(request, payload: try handle.readToEnd() ?? Data()) }
        var head = try JSONSerialization.data(withJSONObject: request)
        head.append(0x0A)
        try await send(head)
        var left = size
        while left > 0 {
            let piece = try handle.read(upToCount: Int(min(left, UInt64(Self.chunk)))) ?? Data()
            guard !piece.isEmpty else { throw Deliver.Failure("internal") } // the file got shorter
            try await send(piece)
            left -= UInt64(piece.count)
        }
        return try await answer()
    }

    nonisolated static func fits(_ size: Int64, limit: Int64?, in folder: URL) -> Bool {
        if let limit, size > limit { return false }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage else { return false }
        return free - size >= 10_000_000_000
    }

    /// A host file (`uploads/<link>/<file>`, pB's sync `get`): `{"ok":true,"size":N}` then N raw bytes, written to `url`.
    /// `expected`: the size the upload record gave; a host that announces more (or more than the disk can take with
    /// 10 GB to spare) is refused before a byte is written.
    func get(_ path: String, to url: URL, offset: Int64? = nil, length: Int64? = nil, expected: Int64? = nil) async throws {
        var request: [String: Any] = ["op": "get", "path": path]
        if let offset, let length { request["offset"] = offset; request["length"] = length }
        if let fake {
            guard let answer = fake(request, nil), let bytes = answer["bytes"] as? Data else { throw Deliver.Failure("internal") }
            return try bytes.write(to: url, options: .atomic)
        }
        var head = try JSONSerialization.data(withJSONObject: request)
        head.append(0x0A)
        try await send(head)
        let answer = try await answer()
        guard let size = (answer["size"] as? NSNumber)?.int64Value, size >= 0 else { throw Deliver.Failure("internal") }
        guard Self.fits(size, limit: length ?? expected, in: url.deletingLastPathComponent()) else {
            close() // (the bytes that follow can't be skipped on this connection)
            throw Deliver.Failure("tooLarge")
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var left = size
        while left > 0 {
            if buffer.isEmpty, let connection {
                let chunk: Data = try await timed { done in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, _, error in
                        if let error { return done(.failure(error)) }
                        done(data.flatMap { $0.isEmpty ? nil : $0 }.map { .success($0) } ?? .failure(Deliver.Failure("internal")))
                    }
                }
                buffer.append(chunk)
            }
            let take = Int(min(Int64(buffer.count), left))
            try handle.write(contentsOf: buffer.prefix(take))
            buffer.removeFirst(take)
            left -= Int64(take)
        }
    }

    /// No answer, or no progress sending, for this long: the connection goes and the call throws.
    static let timeout: TimeInterval = 30

    /// One send or receive, answered by `start`'s callback or, after `timeout`, by cancelling the connection.
    private func timed<T>(_ start: @escaping (@escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let once = OnceFlag()
            start { result in if once.claim() { continuation.resume(with: result) } }
            queue.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
                guard once.claim() else { return }
                self?.connection?.cancel()
                continuation.resume(throwing: Deliver.Failure("internal"))
            }
        }
    }

    private func send(_ data: Data) async throws {
        guard let connection else { return }
        try await timed { (done: @escaping (Result<Void, Error>) -> Void) in
            connection.send(content: data, completion: .contentProcessed { error in done(error.map { .failure($0) } ?? .success(())) })
        }
    }

    private func line() async throws -> Data {
        guard let connection else { return Data() }
        while true {
            if let end = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<end])
                buffer.removeSubrange(buffer.startIndex...end)
                return line
            }
            let chunk: Data = try await timed { done in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, _, error in
                    if let error { return done(.failure(error)) }
                    done(data.flatMap { $0.isEmpty ? nil : $0 }.map { .success($0) } ?? .failure(Deliver.Failure("closed")))
                }
            }
            buffer.append(chunk)
            guard buffer.count < 64 << 20 else { throw Deliver.Failure("limit") }
        }
    }

    func close() { connection?.cancel() }
}

/// A NAS host's media roots as a Library Finder source (read only). Stand-in URLs: /.pluck-nas/<host>/<media path>.
@MainActor
@Observable
final class NASFinderSource: FinderSource {
    let host: Deliver.Host
    let root: URL
    var problem: String?
    /// Offline: the last listing of each folder, shown greyed and read only (§13.16).
    var offline: Bool { problem != nil }
    @ObservationIgnored private var last: [String: [(URL, FinderInfo)]] = [:]
    /// "Share for review…" from the right-click menu (Deliver › Browse sets it).
    @ObservationIgnored var share: (([URL]) -> Void)?

    var rootName: String? { host.name }

    init(host: Deliver.Host) {
        self.host = host
        root = URL(fileURLWithPath: "/.pluck-nas", isDirectory: true).appendingPathComponent(host.id.uuidString, isDirectory: true)
    }

    /// The media path a stand-in URL stands for ("" for the top, where the roots are). Its first part is the root's
    /// shown name (see `display`), taken back to the id.
    func path(_ url: URL) -> String {
        let path = url.standardizedFileURL.path, base = root.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return "" }
        let parts = path.dropFirst(base.count + 1).split(separator: "/", maxSplits: 1).map(String.init)
        guard let first = parts.first else { return "" }
        let id = ((Array(names.keys) + [uploads].compactMap { $0 }).first { display($0) == first && $0 != first }) ?? first
        return ([id] + parts.dropFirst()).joined(separator: "/")
    }

    /// The stand-in URL of a media path ("nas1/Clients" → …/Wide-open-2026/Clients).
    func url(_ media: String, folder: Bool = true) -> URL {
        let parts = media.split(separator: "/", maxSplits: 1).map(String.init)
        guard let first = parts.first else { return root }
        return root.appendingPathComponent(([display(first)] + parts.dropFirst()).joined(separator: "/"), isDirectory: folder)
    }

    /// The names the owner knows the roots by (the record as it is now: Change Folders may have named them since).
    private var names: [String: String] { current.rootNames ?? [:] }
    private var current: Deliver.Host { ReviewPublish.shared.host(host.id) ?? host }

    /// The uploads root's id, once known: "Uploads" when the owner hasn't named it.
    @ObservationIgnored var uploads: String?

    /// A root as the browser shows it (Deliver.Host.rootName).
    func display(_ id: String) -> String {
        if id == uploads, names[id] == nil, !names.values.contains(Self.uploadsName) { return Self.uploadsName }
        return current.rootName(id)
    }
    static var uploadsName: String { String(localized: "Uploads") }

    func list(_ folder: URL) async -> [(URL, FinderInfo)] {
        do {
            let entries = try await ReviewHostClient.browse(host, path: path(folder))
            problem = nil
            let top = path(folder).isEmpty
            let listed: [(URL, FinderInfo)] = entries.map { entry in
                let type = UTType(filenameExtension: (entry.name as NSString).pathExtension)
                return (url(entry.path, folder: entry.folder),
                        FinderInfo(name: top ? display(entry.name) : entry.name, isFolder: entry.folder, isClip: !entry.folder && type?.conforms(to: .movie) == true,
                                   isPhoto: !entry.folder && type?.conforms(to: .image) == true, size: entry.size, modified: entry.modified,
                                   kind: entry.folder ? String(localized: "Folder") : type?.localizedDescription ?? "", tags: []))
            }
            last[path(folder)] = listed
            return listed
        } catch {
            problem = ReviewHostClient.problem(error)
            return last[path(folder)] ?? []
        }
    }

    func open(_ url: URL) {}

    func picture(_ url: URL) async -> CGImage? {
        let media = path(url)
        guard media.contains("/"), let data = try? await ReviewHostClient.thumb(host, path: media),
              let image = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(image, 0, nil)
    }

    /// "Move to…" for files in the uploads folder (Deliver › Browse sets it).
    @ObservationIgnored var move: (([String]) -> Void)?

    func menu(_ urls: [URL]) -> AnyView {
        guard !offline else { return AnyView(EmptyView()) }
        let inUploads = urls.map(path).filter { p in uploads.map { p.hasPrefix($0 + "/") } ?? false }
        return AnyView(Group {
            if let share { Button("Share for Review…") { share(urls) } }
            if let move, !inUploads.isEmpty, inUploads.count == urls.count { Button("Move to…") { move(inUploads) } }
        })
    }
}
