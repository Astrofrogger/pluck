import CryptoKit
import Foundation

/// TrueNAS's JSON-RPC 2.0 API over `wss://<nas>/api/current` (25.04+, §13.13). Only ever over TLS (TrueNAS revokes
/// an API key used over plain http), with the certificate's SHA-256 pinned per address once the owner confirmed it.
/// Method names and parameters checked against api.truenas.com v25.10.
@MainActor
final class TrueNASClient {
    /// Roles the `pluck` user needs (shown in the guide, checked against `privilege.roles`).
    static let roles = ["APPS_READ", "APPS_WRITE", "DATASET_READ", "DATASET_WRITE", "FILESYSTEM_ATTRS_READ", "FILESYSTEM_ATTRS_WRITE"]
    /// The app's name on TrueNAS: "pluck-backup" for a backup, so one NAS can run a main and a backup side by side.
    var appName = "pluck-review"

    /// Tests: the NAS's side (method and params in, the `result` or an `error` out).
    static var fake: ((String, [Any]) -> [String: Any])?

    struct Failure: LocalizedError, Equatable {
        var message: String
        var errorDescription: String? { message }
    }

    /// A NAS whose certificate isn't confirmed yet: nothing (the key least of all) is sent until it is.
    struct Unconfirmed: Error { var fingerprint: String }

    let address: String
    let pin: String?
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var delegate: PinDelegate?
    private var nextID = 1
    private(set) var version: (major: Int, minor: Int)?

    init(address: String, pin: String?) {
        self.address = address
        self.pin = pin
    }

    // MARK: - Connecting

    func connect() async throws {
        guard Self.fake == nil else { return }
        guard let url = URL(string: "wss://\(address)/api/current") else { throw Failure(message: String(localized: "That isn’t a NAS address.")) }
        let delegate = PinDelegate(pin: pin)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let socket = session.webSocketTask(with: url)
        socket.resume()
        self.delegate = delegate
        self.session = session
        self.socket = socket
        do {
            // Any answer proves the TLS handshake (and its pin) passed; before login TrueNAS answers most methods
            // with ENOTAUTHENTICATED, which is fine here. Only a transport error means the connection failed.
            do { _ = try await call("auth.mechanism_choices") } catch is Failure {}
        } catch {
            if pin == nil, let seen = delegate.seen { throw Unconfirmed(fingerprint: seen) }
            throw error
        }
    }

    func close() {
        socket?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }

    /// One call; `{"error":…}` throws its message.
    @discardableResult
    func call(_ method: String, _ params: [Any] = []) async throws -> Any {
        if let fake = Self.fake {
            let answer = fake(method, params)
            if let error = answer["error"] { throw Failure(message: (error as? [String: Any])?["message"] as? String ?? "\(error)") }
            return answer["result"] ?? NSNull()
        }
        guard let socket else { throw Failure(message: String(localized: "Not connected to the NAS.")) }
        let id = nextID
        nextID += 1
        let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        try await socket.send(.string(String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)))
        while true {
            let message = try await socket.receive()
            let text: String
            switch message {
            case .string(let string): text = string
            case .data(let data): text = String(decoding: data, as: UTF8.self)
            @unknown default: continue
            }
            guard let answer = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], answer["id"] as? Int == id else { continue }
            if let error = answer["error"] as? [String: Any] {
                let data = error["data"] as? [String: Any]
                throw Failure(message: data?["reason"] as? String ?? error["message"] as? String ?? "error")
            }
            return answer["result"] ?? NSNull()
        }
    }

    /// A job's id from `call`, then `core.job_wait` until it ends.
    @discardableResult
    func job(_ method: String, _ params: [Any]) async throws -> Any {
        let id = try await call(method, params)
        guard let number = id as? Int else { return id }
        return try await call("core.job_wait", [number])
    }

    // MARK: - The steps

    func login(_ key: String) async throws {
        guard try await call("auth.login_with_api_key", [key]) as? Bool == true else {
            throw Failure(message: String(localized: "The NAS didn’t accept that API key."))
        }
    }

    /// The NAS's version ("25.10.0", "TrueNAS-SCALE-25.04.2"…); below 25.04 is refused.
    func checkVersion() async throws -> String {
        let text = try await call("system.version") as? String ?? ""
        guard let parsed = Self.parse(text) else { throw Failure(message: String(localized: "Pluck can’t read this NAS’s version.")) }
        version = parsed
        guard parsed >= (25, 4) else { throw Failure(message: String(localized: "This needs TrueNAS 25.04 or newer.")) }
        return text
    }

    nonisolated static func parse(_ version: String) -> (major: Int, minor: Int)? {
        guard let match = version.firstMatch(of: #/(\d{2})\.(\d{1,2})/#), let major = Int(match.1), let minor = Int(match.2) else { return nil }
        return (major, minor)
    }

    /// The roles the API key's user lacks (empty: fine).
    func missingRoles() async throws -> [String] {
        let me = try await call("auth.me") as? [String: Any] ?? [:]
        guard let have = Self.roleList((me["privilege"] as? [String: Any])?["roles"]) ?? Self.roleList(me["roles"]) else {
            // Not readable on this TrueNAS: don't block; a missing right fails the next step with TrueNAS's own message.
            return []
        }
        if have.contains("FULL_ADMIN") { return [] }
        return Self.roles.filter { !have.contains($0) }
    }

    /// TrueNAS sends a role set as a plain list, or (Python sets in its JSON) as {"$set": [...]}.
    nonisolated static func roleList(_ value: Any?) -> Set<String>? {
        if let list = value as? [String] { return Set(list) }
        if let wrapped = (value as? [String: Any])?["$set"] as? [String] { return Set(wrapped) }
        return nil
    }

    func pools() async throws -> [String] {
        (try await call("pool.query") as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    func datasets() async throws -> [String] {
        (try await call("pool.dataset.query", [[], ["select": ["id"]]]) as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    /// Made when missing; an existing one is left alone.
    func ensureDataset(_ name: String) async throws {
        let found = try await call("pool.dataset.query", [[["id", "=", name]]]) as? [[String: Any]] ?? []
        guard found.isEmpty else { return }
        try await call("pool.dataset.create", [["name": name, "type": "FILESYSTEM", "create_ancestors": true]])
    }

    /// The app's own datasets (data, uploads) for uid/gid 568. Media datasets are never changed.
    func own(_ dataset: String) async throws {
        try await job("filesystem.setperm", [["path": "/mnt/\(dataset)", "uid": 568, "gid": 568, "mode": "770",
                                             "options": ["recursive": false, "traverse": false, "stripacl": false]]])
    }

    /// Whether uid 568 can read a media dataset (only warned about: Pluck doesn't change it).
    func readable(_ dataset: String) async throws -> Bool {
        let stat = try await call("filesystem.stat", ["/mnt/\(dataset)"]) as? [String: Any] ?? [:]
        let mode = stat["mode"] as? Int ?? 0, uid = stat["uid"] as? Int ?? -1, gid = stat["gid"] as? Int ?? -1
        return mode & 0o004 != 0 || (uid == 568 && mode & 0o400 != 0) || (gid == 568 && mode & 0o040 != 0) || stat["acl"] as? Bool == true
    }

    /// `app.create`, or `app.update` when it's there already; both are jobs.
    func deploy(_ compose: String) async throws {
        if try await app() != nil {
            try await job("app.update", [appName, ["custom_compose_config_string": compose]])
        } else {
            try await job("app.create", [["custom_app": true, "app_name": appName, "custom_compose_config_string": compose]])
        }
    }

    func app() async throws -> [String: Any]? {
        (try await call("app.query", [[["name", "=", appName]]]) as? [[String: Any]])?.first
    }

    /// Until the app is RUNNING (120 s at most).
    func waitRunning(timeout: TimeInterval = 120, poll: Duration = .seconds(3)) async throws {
        let end = Date.now.addingTimeInterval(timeout)
        while Date.now < end {
            if try await app()?["state"] as? String == "RUNNING" { return }
            try await Task.sleep(for: poll)
        }
        throw Failure(message: String(localized: "The app didn’t start on the NAS within 2 minutes."))
    }

    /// §13.15(a): the new compose, and the previous one back when it doesn't come up (the result says which).
    enum UpdateResult: String { case ok, rolledBack, failed }
    func update(to compose: String, previous: String, poll: Duration = .seconds(3), healthy: () async -> Bool) async -> UpdateResult {
        do {
            try await job("app.update", [appName, ["custom_compose_config_string": compose]])
            try await waitRunning(poll: poll)
            if await healthy() { return .ok }
        } catch {}
        do {
            try await job("app.update", [appName, ["custom_compose_config_string": previous]])
            try await waitRunning(poll: poll)
            return .rolledBack
        } catch {
            return .failed
        }
    }

    // MARK: - The compose template (R2's docker/truenas-compose.yml; `{{name}}` placeholders)

    /// R2's template quotes every placeholder itself, so each value is escaped for inside a double-quoted YAML
    /// scalar; a value with a newline is refused, as is a placeholder left over. Optional blocks between
    /// `# begin:<name>` and `# end:<name>` lines stay only when `blocks` has them.
    nonisolated static func render(_ template: String, _ values: [String: String], blocks: Set<String> = []) throws -> String {
        var kept: [Substring] = [], dropping: String?
        for line in template.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let name = trimmed.firstMatch(of: #/^# begin:([a-z0-9_]+)$/#)?.1 { if !blocks.contains(String(name)) { dropping = String(name) }; continue }
            if let name = trimmed.firstMatch(of: #/^# end:([a-z0-9_]+)$/#)?.1 { if dropping == String(name) { dropping = nil }; continue }
            if dropping == nil { kept.append(line) }
        }
        var out = kept.joined(separator: "\n")
        for (name, value) in values {
            guard !value.contains("\n"), !value.contains("\r") else { throw Failure(message: "newline in \(name)") }
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            out = out.replacingOccurrences(of: "{{\(name)}}", with: escaped)
        }
        if out.contains("{{") { throw Failure(message: "unfilled placeholder") }
        return out
    }

    /// The template shipped in the app (Contents/Resources/truenas-compose.yml), when this build has it.
    static var template: String? {
        Bundle.main.url(forResource: "truenas-compose", withExtension: "yml").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}

/// Accepts only the pinned certificate (or, unpinned, remembers what it saw and refuses, so it can be confirmed).
private final class PinDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let pin: String?
    var seen: String?
    init(pin: String?) { self.pin = pin }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else { return completionHandler(.cancelAuthenticationChallenge, nil) }
        let fingerprint = HostSession.fingerprint(SecCertificateCopyData(leaf) as Data)
        seen = fingerprint
        if let pin, pin == fingerprint { completionHandler(.useCredential, URLCredential(trust: trust)) } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
}

/// TrueNAS API keys: Keychain service tools.pluck.review.truenas, account the NAS address; in memory in test copies.
enum TrueNASKeychain {
    static let service = "tools.pluck.review.truenas"
    static func save(_ key: String, for address: String) { DeliverKeychain.save(Data(key.utf8), as: address, service: service) }
    static func load(_ address: String) -> String? { DeliverKeychain.load(address, service: service).map { String(decoding: $0, as: UTF8.self) } }
    static func forget(_ address: String) { DeliverKeychain.delete(address, service: service) }
    /// Pinned certificates per address (the fingerprint the owner confirmed).
    static func pin(_ address: String) -> String? { UserDefaults.standard.string(forKey: "truenasPin." + address) }
    static func setPin(_ fingerprint: String, for address: String) { UserDefaults.standard.set(fingerprint, forKey: "truenasPin." + address) }
}
