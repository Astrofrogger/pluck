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
    /// `collection_update` notifications that came in while waiting for an answer.
    private var notifications: [[String: Any]] = []
    /// Tests: the stand-in TrueNAS's port (TrueNAS itself answers on 443).
    static var testPort: Int?
    /// Tests: the log lines the app's container prints.
    static var fakeLog: [String]?
    private(set) var version: (major: Int, minor: Int)?

    init(address: String, pin: String?) {
        self.address = address
        self.pin = pin
    }

    // MARK: - Connecting

    func connect() async throws {
        guard Self.fake == nil else { return }
        guard let url = URL(string: "wss://\(address)\(Self.testPort.map { ":\($0)" } ?? "")/api/current") else { throw Failure(message: String(localized: "That isn’t a NAS address.")) }
        let delegate = PinDelegate(pin: pin)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let socket = session.webSocketTask(with: url)
        socket.resume()
        self.delegate = delegate
        self.session = session
        self.socket = socket
        // The certificate is decided first (resume starts the handshake): refused, nothing is sent at all.
        for _ in 0..<100 where delegate.accepted == nil { try await Task.sleep(for: .milliseconds(100)) }
        if delegate.accepted == false {
            close()
            if pin == nil, let seen = delegate.seen { throw Unconfirmed(fingerprint: seen) }
            throw Failure(message: String(localized: "TrueNAS shows a different certificate than the one you confirmed for \(address)."))
        }
        do {
            // Any answer proves the TLS handshake (and its pin) passed; before login TrueNAS answers most methods
            // with ENOTAUTHENTICATED, which is fine here. Only a transport error means the connection failed.
            do { _ = try await call("auth.mechanism_choices") } catch is Failure {}
        } catch {
            if pin == nil, let seen = delegate.seen { throw Unconfirmed(fingerprint: seen) }
            throw error
        }
    }

    /// One send or receive with a deadline: a task that failed before it opened (a refused certificate) can leave the
    /// async send waiting forever; at the deadline the socket is cancelled and the call throws.
    private static func timed<T>(_ socket: URLSessionWebSocketTask, _ seconds: Double, _ start: (@escaping @Sendable (Result<T, Error>) -> Void) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let once = OnceFlag()
            start { result in if once.claim() { continuation.resume(with: result) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                guard once.claim() else { return }
                socket.cancel(with: .goingAway, reason: nil)
                continuation.resume(throwing: Failure(message: String(localized: "The NAS stopped answering.")))
            }
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
        try await Self.timed(socket, 30) { done in socket.send(.string(String(decoding: (try? JSONSerialization.data(withJSONObject: request)) ?? Data(), as: UTF8.self))) { done($0.map { .failure($0) } ?? .success(())) } }
        while true {
            let message: URLSessionWebSocketTask.Message = try await Self.timed(socket, 120) { done in socket.receive { done($0) } }
            let text: String
            switch message {
            case .string(let string): text = string
            case .data(let data): text = String(decoding: data, as: UTF8.self)
            @unknown default: continue
            }
            guard let answer = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
            // (Event notifications have no id: kept for whoever subscribed.)
            guard answer["id"] as? Int == id else { if answer["method"] as? String == "collection_update" { notifications.append(answer) }; continue }
            if let error = answer["error"] as? [String: Any] {
                let data = error["data"] as? [String: Any]
                throw Failure(message: data?["reason"] as? String ?? error["message"] as? String ?? "error")
            }
            return answer["result"] ?? NSNull()
        }
    }

    /// A job's id from `call`, then its state from `core.get_jobs` until it ends (SUCCESS: its result; FAILED or ABORTED:
    /// its error). `core.job_wait` is itself a job on 25.10 (its call answers with another job's id, not the result), so
    /// it's only the fallback when `core.get_jobs` gives no list. Both checked against api.truenas.com v25.10.
    @discardableResult
    func job(_ method: String, _ params: [Any], poll: Duration = .seconds(1), timeout: TimeInterval = 900) async throws -> Any {
        let id = try await call(method, params)
        guard let number = id as? Int else { return id }
        let end = Date.now.addingTimeInterval(timeout)
        while Date.now < end {
            guard let found = try await call("core.get_jobs", [[["id", "=", number]]]) as? [[String: Any]] else {
                return try await call("core.job_wait", [number])
            }
            if let entry = found.first {
                switch entry["state"] as? String {
                case "SUCCESS": return entry["result"] ?? NSNull()
                case "FAILED", "ABORTED":
                    throw Failure(message: entry["error"] as? String ?? (entry["exc_info"] as? [String: Any])?["repr"] as? String ?? "\(method) failed")
                default: break
                }
            }
            try await Task.sleep(for: poll)
        }
        throw Failure(message: String(localized: "TrueNAS is still busy with \(method). Try again in a few minutes."))
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

    /// The pools: the top-level datasets. (`pool.query` needs POOL_READ, which the pluck user doesn't have;
    /// pool.dataset.query needs DATASET_READ, which it does. Checked against api.truenas.com v25.10.)
    func pools() async throws -> [String] {
        Self.pools(in: try await datasets())
    }

    nonisolated static func pools(in datasets: [String]) -> [String] {
        Array(Set(datasets.filter { !$0.isEmpty && !$0.contains("/") })).sorted()
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

    /// Whether the app (TrueNAS's "apps" user, uid/gid 568) can read a media dataset, its child datasets and the folders
    /// right inside it (only warned about: Pluck never changes a media dataset's permissions). `filesystem.stat`,
    /// `filesystem.listdir` and `filesystem.getacl` (FILESYSTEM_ATTRS_READ) and `pool.dataset.query` with a "^" filter
    /// (DATASET_READ); all checked against api.truenas.com v25.10.
    func readable(_ dataset: String) async throws -> Bool {
        let children = (try await call("pool.dataset.query", [[["id", "^", dataset + "/"]], ["select": ["id"]]]) as? [[String: Any]] ?? [])
            .compactMap { $0["id"] as? String }.filter { $0.hasPrefix(dataset + "/") }
        // Datasets: readable, and passing it on to folders made later (an inherited ACL entry).
        for path in [dataset] + children.sorted() {
            let stat = try await call("filesystem.stat", ["/mnt/\(path)"]) as? [String: Any] ?? [:]
            guard try await entryReadable(stat, path: "/mnt/\(path)", inherit: true) else { return false }
        }
        // shortcut: only the first level of folders (100 at most), not every folder below; enough for the usual mistakes.
        let folders = try await call("filesystem.listdir", ["/mnt/\(dataset)", [["type", "=", "DIRECTORY"]],
                                                            ["select": ["path", "mode", "uid", "gid", "acl"], "limit": 100]]) as? [[String: Any]] ?? []
        for folder in folders {
            guard let path = folder["path"] as? String else { continue }
            guard try await entryReadable(folder, path: path, inherit: false) else { return false }
        }
        return true
    }

    /// One folder's `stat`/`listdir` entry: its mode bits (read and enter), or its ACL when it has one.
    private func entryReadable(_ entry: [String: Any], path: String, inherit: Bool) async throws -> Bool {
        let mode = entry["mode"] as? Int ?? 0, uid = entry["uid"] as? Int ?? -1, gid = entry["gid"] as? Int ?? -1
        guard entry["acl"] as? Bool == true else { return Self.modeReadable(mode, uid: uid, gid: gid) }
        let acl = try await call("filesystem.getacl", [path, false]) as? [String: Any] ?? [:]
        return Self.aclReadable(acl, mode: mode, inherit: inherit)
    }

    nonisolated static let appsID = 568

    nonisolated static func modeReadable(_ mode: Int, uid: Int, gid: Int) -> Bool {
        mode & 0o005 == 0o005 || (uid == appsID && mode & 0o500 == 0o500) || (gid == appsID && mode & 0o050 == 0o050)
    }

    /// `filesystem.getacl`'s answer: an ALLOW entry (NFS4) or access entry (POSIX1E) giving the apps user or group (or
    /// everyone) read; with `inherit`, one that new folders get too (NFS4 inherit flags, a POSIX default entry).
    /// shortcut: DENY entries aren't weighed against it; TrueNAS's own ACL editor rarely makes them.
    nonisolated static func aclReadable(_ acl: [String: Any], mode: Int, inherit: Bool) -> Bool {
        let uid = acl["uid"] as? Int ?? -1, gid = acl["gid"] as? Int ?? -1
        let entries = acl["acl"] as? [[String: Any]] ?? []
        func forApps(_ tag: String, _ id: Int?) -> Bool {
            switch tag {
            case "everyone@", "OTHER": return true
            case "owner@", "USER_OBJ": return uid == appsID
            case "group@", "GROUP_OBJ": return gid == appsID
            case "USER", "GROUP": return id == appsID
            default: return false
            }
        }
        switch acl["acltype"] as? String {
        case "NFS4":
            return entries.contains { entry in
                guard entry["type"] as? String == "ALLOW", forApps(entry["tag"] as? String ?? "", entry["id"] as? Int) else { return false }
                let perms = entry["perms"] as? [String: Any] ?? [:], flags = entry["flags"] as? [String: Any] ?? [:]
                let reads = ["FULL_CONTROL", "MODIFY", "READ"].contains(perms["BASIC"] as? String ?? "")
                    || (perms["READ_DATA"] as? Bool == true && perms["EXECUTE"] as? Bool == true)
                let inherits = flags["BASIC"] as? String == "INHERIT" || flags["DIRECTORY_INHERIT"] as? Bool == true
                return reads && (!inherit || inherits) && flags["INHERIT_ONLY"] as? Bool != true
            }
        case "POSIX1E":
            func grants(_ isDefault: Bool) -> Bool {
                let list = entries.filter { $0["default"] as? Bool == isDefault }
                let mask = list.first { $0["tag"] as? String == "MASK" }?["perms"] as? [String: Any]
                return list.contains { entry in
                    let tag = entry["tag"] as? String ?? ""
                    guard forApps(tag, entry["id"] as? Int), let perms = entry["perms"] as? [String: Any] else { return false }
                    let masked = ["USER", "GROUP", "GROUP_OBJ"].contains(tag) && mask != nil
                    func has(_ key: String) -> Bool { perms[key] as? Bool == true && (!masked || mask?[key] as? Bool == true) }
                    return has("READ") && has("EXECUTE")
                }
            }
            return grants(false) && (!inherit || entries.allSatisfy { $0["default"] as? Bool != true } || grants(true))
        default:
            return modeReadable(mode, uid: uid, gid: gid)
        }
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

    /// `app.config` (APPS_READ, not a job): what TrueNAS keeps of the app. For a custom app that's the compose as
    /// `yaml.safe_load` read it, so an object (`services` › … › `environment`); checked against api.truenas.com v25.10
    /// and middlewared's apps/ix_apps/lifecycle.py `get_current_app_config`.
    func config() async throws -> Any { try await call("app.config", [appName]) }

    /// The values Pluck's template put into an installed app, read back from `app.config`.
    struct Installed: Equatable {
        var key: String
        var name: String?
        var data: String?
        var media: [String] = []          // datasets, in the order of their ids
        var mediaIDs: [String] = []
        var uploads: String?
        var uploadsID: String?
        var secondAddress: String?
        var secondPath: String?
        var secondID: String?
        var cpus: Int?
        var memory: Int?
        var iroh: Bool?
        var mainLink: String?
        var backupMax: Int?
        var quality: String?
        /// Upload links write straight into media1 (the drop1 block: a `--drop` argument and its /drop/ mount).
        var drop = false
    }

    /// nil when there's no usable PLUCK_HOST_KEY (a 32-byte base64url key). The key is looked for anywhere (an
    /// `environment` map or `KEY=value` list, or YAML text); the rest is read from Pluck's own template shape.
    static func installed(_ config: Any) -> Installed? {
        guard let key = hostKey(in: config), DeliverKeys.data(base64url: key)?.count == 32 else { return nil }
        var found = Installed(key: key)
        let root = config as? [String: Any] ?? [:]
        let services = root["services"] as? [String: Any] ?? [:]
        guard let service = (services["pluck-review"] ?? services.values.first) as? [String: Any] else { return found }
        let env = environment(service["environment"])
        found.name = env["PLUCK_HOST_NAME"]
        found.iroh = env["PLUCK_IROH"].map { $0 == "1" }
        found.mainLink = env["PLUCK_MAIN_LINK"].flatMap { $0.isEmpty ? nil : $0 }
        found.backupMax = env["PLUCK_BACKUP_MAX"].flatMap { Int($0.trimmingCharacters(in: .letters)) }
        found.quality = env["PLUCK_BACKUP_QUALITY"].flatMap { $0.isEmpty ? nil : $0 }
        for volume in service["volumes"] as? [Any] ?? [] {
            guard let text = volume as? String else { continue }
            let parts = text.split(separator: ":").map(String.init)
            guard parts.count >= 2 else { continue }
            let dataset = parts[0].hasPrefix("/mnt/") ? String(parts[0].dropFirst(5)) : nil
            if parts[0] == "media2", parts[1].hasPrefix("/media/") { found.secondID = String(parts[1].dropFirst(7)) }
            else if parts[1] == "/data" { found.data = dataset }
            else if parts[1].hasPrefix("/drop/") { found.drop = true }
            else if parts[1].hasPrefix("/uploads/") { found.uploads = dataset; found.uploadsID = String(parts[1].dropFirst(9)) }
            else if parts[1].hasPrefix("/media/"), let dataset { found.media.append(dataset); found.mediaIDs.append(String(parts[1].dropFirst(7))) }
        }
        if let nfs = ((root["volumes"] as? [String: Any])?["media2"] as? [String: Any])?["driver_opts"] as? [String: Any] {
            found.secondAddress = (nfs["o"] as? String)?.firstMatch(of: #/addr=([^,]+)/#).map { String($0.1) }
            found.secondPath = (nfs["device"] as? String).map { $0.hasPrefix(":") ? String($0.dropFirst()) : $0 }
        }
        if (service["command"] as? [Any])?.contains(where: { $0 as? String == "--drop" }) == true { found.drop = true }
        found.cpus = number(service["cpus"]).map { Int($0) }
        found.memory = (service["mem_limit"] as? String).flatMap { Int($0.lowercased().trimmingCharacters(in: .letters)) } ?? number(service["mem_limit"]).map { Int($0) }
        return found
    }

    private static func hostKey(in value: Any) -> String? {
        if let map = value as? [String: Any] {
            if let key = map["PLUCK_HOST_KEY"] as? String { return key }
            return map.values.lazy.compactMap(hostKey).first
        }
        if let list = value as? [Any] { return list.lazy.compactMap(hostKey).first }
        // `PLUCK_HOST_KEY: "…"`, `PLUCK_HOST_KEY=…`, quoted or not, in YAML text or a list item.
        if let text = value as? String, let match = text.firstMatch(of: #/PLUCK_HOST_KEY["']?\s*[:=]\s*["']?([A-Za-z0-9_-]{43})(?![A-Za-z0-9_-])/#) {
            return String(match.1)
        }
        return nil
    }

    private static func environment(_ value: Any?) -> [String: String] {
        if let map = value as? [String: Any] { return map.mapValues { "\($0)" } }
        var out: [String: String] = [:]
        for item in value as? [String] ?? [] {
            let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { out[pair[0]] = pair[1] }
        }
        return out
    }

    private static func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init) }

    /// The sync certificate's fingerprint as the app's own log prints it (the helper's `{"host":{…,"fingerprint":…}}`
    /// line), so the owner needn't compare it by hand: `app.container_ids`, then the `app.container_log_follow` event
    /// through `core.subscribe`, read from its `collection_update` notifications (`params.fields.data`); all APPS_READ,
    /// checked against api.truenas.com v25.10. nil when it can't be read within `timeout`. Closes the connection after.
    func logFingerprint(timeout: TimeInterval = 15) async -> String? {
        defer { close() }
        guard let containers = try? await call("app.container_ids", [appName, ["alive_only": true]]) as? [String: Any] else { return nil }
        let details = containers.values.compactMap { $0 as? [String: Any] }
        guard let container = (details.first { $0["service_name"] as? String == "pluck-review" } ?? details.first)?["id"] as? String,
              let options = try? JSONSerialization.data(withJSONObject: ["app_name": appName, "container_id": container, "tail_lines": 500], options: [.sortedKeys]),
              (try? await call("core.subscribe", ["app.container_log_follow:" + String(decoding: options, as: UTF8.self)])) != nil else { return nil }
        if let fakeLog = Self.fakeLog { return Self.fingerprint(inLog: fakeLog) }
        guard let socket else { return nil }
        // One reader until the line shows up or time's up (closing the socket ends it).
        let reader = Task { @MainActor [weak self] in
            while let message = try? await socket.receive() {
                guard case .string(let text) = message, let note = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
                self?.notifications.append(note)
            }
        }
        defer { reader.cancel() }
        let end = Date.now.addingTimeInterval(timeout)
        while Date.now < end {
            let lines = notifications.compactMap { (($0["params"] as? [String: Any])?["fields"] as? [String: Any])?["data"] as? String }
            if let found = Self.fingerprint(inLog: lines) { return found }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    /// The last `"fingerprint":"AB:…"` (32 bytes) in the log lines.
    nonisolated static func fingerprint(inLog lines: [String]) -> String? {
        lines.reversed().lazy.compactMap { line in
            line.matches(of: #/"fingerprint"\s*:\s*"([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){31})"/#).last.map { String($0.1).uppercased() }
        }.first
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

    /// The template with the media1 block repeated `count` times more, as mediax1, mediax2… (the helper takes any
    /// number of --media; R2's template has one local media block). Each copy stays a media1 block, so a backup drops them all.
    nonisolated static func moreMedia(_ template: String, count: Int) -> String {
        guard count > 0 else { return template }
        var out: [Substring] = [], block: [Substring]?
        for line in template.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "# begin:media1" { block = [line]; continue } else if trimmed == "# end:media1", let lines = block {
                out.append(contentsOf: lines)
                out.append(line)
                for n in 1...count {
                    let copy = lines.dropFirst().map { Substring($0.replacingOccurrences(of: "{{media1_id}}", with: "{{mediax\(n)_id}}").replacingOccurrences(of: "{{media1}}", with: "{{mediax\(n)}}")) }
                    out.append(lines[0])
                    out.append(contentsOf: copy)
                    out.append(line)
                }
                block = nil
                continue
            }
            if block != nil { block!.append(line) } else { out.append(line) }
        }
        return out.joined(separator: "\n")
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
    /// Whether the certificate was taken (nil: not asked yet).
    var accepted: Bool?
    init(pin: String?) { self.pin = pin }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else { return completionHandler(.cancelAuthenticationChallenge, nil) }
        let fingerprint = HostSession.fingerprint(SecCertificateCopyData(leaf) as Data)
        seen = fingerprint
        accepted = pin == fingerprint
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
