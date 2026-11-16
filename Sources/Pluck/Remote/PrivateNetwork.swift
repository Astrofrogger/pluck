import Foundation

/// Edit Anywhere's own private network, so Macs at home reach the office Mac with nothing to
/// install and nothing to change on the router. It only carries Edit Anywhere; it's no system VPN.
/// Two ways, each a small helper:
/// - iroh (the default, pluck-iroh): no account. Each Mac has a key; the office Mac only lets in
///   the keys of its paired Macs (or one new Mac per invitation, for 15 minutes). Direct when the
///   routers allow it, else through a relay (iroh's free public ones, or the owner's own).
/// - Tailscale (pluck-tunnel): the office Mac is connected to the team's Tailscale network once,
///   with an access token from the account, and makes one-time invitations with it.
/// Pluck's own pairing and encryption (OfficeLink) run on top of either.
enum PrivateNetwork {
    enum Transport: String, CaseIterable { case iroh, tailscale }

    static let transportKey = "editAnywhereTransport"
    static let relayKey = "editAnywhereRelay"
    /// How long an iroh invitation works (the helper's limit too).
    static let invitationLifetime: TimeInterval = 15 * 60
    /// A Tailscale invitation (its tagged join key and its pairing code): an hour.
    static let tailscaleInvitationLifetime: TimeInterval = 3600

    /// The host Mac's way in from anywhere. New setups use iroh; a Mac already on Tailscale keeps
    /// it until it's switched (decided once, then saved). A build without pluck-iroh uses
    /// Tailscale without saving that, so a later build with it still picks iroh.
    static var transport: Transport {
        get {
            let defaults = UserDefaults.standard
            if let saved = defaults.string(forKey: transportKey).flatMap(Transport.init) { return saved }
            guard helper(.iroh) != nil else { return .tailscale }
            let chosen = transport(saved: nil, onTailscale: Account.token != nil
                || FileManager.default.fileExists(atPath: folder.appendingPathComponent("office/tailscaled.state").path))
            defaults.set(chosen.rawValue, forKey: transportKey)
            return chosen
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: transportKey) }
    }

    static func transport(saved: String?, onTailscale: Bool) -> Transport {
        saved.flatMap(Transport.init) ?? (onTailscale ? .tailscale : .iroh)
    }

    /// "Use my own relay": its address, or nil for iroh's public relays.
    static var ownRelay: String? {
        UserDefaults.standard.string(forKey: relayKey).flatMap(relayAddress)
    }

    /// A relay address that can be used (https with a host; http only on this Mac or a .test
    /// name, for testing), tidied; nil otherwise.
    static func relayAddress(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let local = ["localhost", "127.0.0.1", "::1"].contains(host) || host.hasSuffix(".localhost") || host.hasSuffix(".test")
        guard scheme == "https" || (scheme == "http" && local) else { return nil }
        return text
    }

    /// An iroh node id: 64 hex characters.
    static func isNodeID(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy(\.isHexDigit)
    }

    static var helper: URL? { helper(.tailscale) }

    static func helper(_ transport: Transport) -> URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/" + (transport == .iroh ? "pluck-iroh" : "pluck-tunnel"))
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/Edit Anywhere", isDirectory: true)
    }

    /// This Mac's name on the private network ("pluck-annas-macbook-pro").
    static var hostname: String {
        let name = (Host.current().localizedName ?? "mac").lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        return "pluck-" + String(name.prefix(40))
    }

    enum Failure: LocalizedError {
        case noHelper, token, tokenExpired, account(String), helper(String), needsInvite, timeout, inviteExpired, inviteUsed
        var errorDescription: String? {
            switch self {
            case .noHelper: String(localized: "This build of Pluck doesn’t have the private network part.")
            case .token: String(localized: "Connect the host Mac to your Tailscale account first.")
            case .tokenExpired: String(localized: "The Tailscale access token has expired or was revoked. Paste a new one on the host Mac.")
            case .account(let detail): String(localized: "Tailscale said: \(detail)")
            case .helper(let detail): String(localized: "The private network couldn’t start: \(detail)")
            case .needsInvite: String(localized: "This Mac isn’t on the host Mac’s private network any more. Ask for a new invitation.")
            case .timeout: String(localized: "The private network didn’t answer in time. Check the internet connection.")
            case .inviteExpired: String(localized: "This invitation has expired. Ask the host Mac for a new one.")
            case .inviteUsed: String(localized: "This invitation was already used or has expired. Ask the host Mac for a new one.")
            }
        }
    }

    // MARK: - The Tailscale account (office Mac only)

    enum Account {
        private static let tokenAccount = "tailscale-token"

        static var token: String? {
            OfficeLink.Keychain.load(tokenAccount).map { String(decoding: $0, as: UTF8.self) }
        }

        static func save(token: String) {
            OfficeLink.Keychain.save(Data(token.trimmingCharacters(in: .whitespacesAndNewlines).utf8), as: tokenAccount)
        }

        static func forget() { OfficeLink.Keychain.delete(tokenAccount) }

        private static func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Any {
            guard let token else { throw Failure.token }
            guard let url = URL(string: "https://api.tailscale.com/api/v2/" + path) else { throw Failure.account("bad request") }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 { throw Failure.tokenExpired }
            let json = try? JSONSerialization.jsonObject(with: data)
            guard (200..<300).contains(status) else {
                throw Failure.account((json as? [String: Any])?["message"] as? String ?? "HTTP \(status)")
            }
            return json ?? [:]
        }

        /// Tags Pluck's nodes join with, so the tailnet's access rules can confine them (`aclSnippet`).
        static let officeTag = "tag:pluck-office", inviteeTag = "tag:pluck-invitee"

        /// What the owner pastes into the tailnet policy (Access controls): invited Macs reach only this Mac's
        /// Edit Anywhere port. A policy that still allows "*" → "*:*" must narrow that rule's src to autogroup:member.
        static let aclSnippet = """
        "tagOwners": {
          "tag:pluck-office":  ["autogroup:admin"],
          "tag:pluck-invitee": ["autogroup:admin"]
        },
        "acls": [
          {"action": "accept", "src": ["tag:pluck-invitee"], "dst": ["tag:pluck-office:\(OfficeLink.port)"]}
        ]
        """

        /// A tagged key that lets one Mac join, once, within `expiry` seconds.
        static func joinKey(expiry: Int, tag: String) async throws -> String {
            let body: [String: Any] = [
                "capabilities": ["devices": ["create": ["reusable": false, "ephemeral": false, "preauthorized": true, "tags": [tag]]]],
                "expirySeconds": expiry,
                "description": "Pluck Edit Anywhere",
            ]
            guard let key = (try await request("tailnet/-/keys", method: "POST", body: body) as? [String: Any])?["key"] as? String else {
                throw Failure.account("no key")
            }
            return key
        }

        /// Pluck's Macs on the network keep their place (no sign-in again after six months), but only the ones that
        /// paired: by the tailnet addresses recorded at pairing (`paired`), never by a name a device picks. An invited
        /// node that never paired (a forwarded or leaked invitation), or was removed in Pluck, is deleted once its
        /// invitation has run out.
        static func keepPluckMacsConnected(paired: Set<String>, removed: Set<String> = []) async {
            guard let list = try? await request("tailnet/-/devices") as? [String: Any],
                  let devices = list["devices"] as? [[String: Any]] else { return }
            for (id, action) in plan(devices, paired: paired, removed: removed, now: .now, lifetime: PrivateNetwork.tailscaleInvitationLifetime) {
                switch action {
                case .keep: _ = try? await request("device/\(id)/key", method: "POST", body: ["keyExpiryDisabled": true])
                case .delete: _ = try? await request("device/\(id)", method: "DELETE")
                }
            }
        }

        enum NodeAction: Equatable { case keep, delete }

        /// What to do with each invited node (only `inviteeTag` nodes are ever touched).
        static func plan(_ devices: [[String: Any]], paired: Set<String>, removed: Set<String> = [], now: Date, lifetime: TimeInterval) -> [(String, NodeAction)] {
            devices.compactMap { device in
                guard let id = device["id"] as? String, (device["tags"] as? [String] ?? []).contains(inviteeTag) else { return nil }
                let addresses = device["addresses"] as? [String] ?? []
                if !removed.isDisjoint(with: addresses) { return (id, .delete) }
                if !paired.isDisjoint(with: addresses) {
                    return device["keyExpiryDisabled"] as? Bool == true ? nil : (id, .keep)
                }
                let created = (device["created"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? .distantPast
                return now.timeIntervalSince(created) > lifetime ? (id, .delete) : nil
            }
        }
    }

    // MARK: - Invitations

    /// What an invitation link carries: how to reach the office Mac from anywhere, its name and a
    /// pairing code. v1 (Tailscale): a one-time key to join the network and the office's address
    /// there. v2 (iroh): the office's node id and relay, and until when it works.
    struct Invitation: Equatable {
        enum Way: Equatable {
            case tailscale(key: String, address: String)
            case iroh(node: String, relay: String?, expires: Date)
            /// v3, `k:"nas"` (§13.2): a NAS review host; `pin` is its certificate's SHA-256 (hex with colons).
            case reviewHost(node: String, relay: String?, expires: Date, pin: String, lan: String?, role: String)
        }
        var way: Way
        var name: String
        var code: String

        var expired: Bool {
            if case .iroh(_, _, let expires) = way { return expires <= .now }
            if case .reviewHost(_, _, let expires, _, _, _) = way { return expires <= .now }
            return false
        }

        var link: URL? {
            var json: [String: Any]
            switch way {
            case .tailscale(let key, let address): json = ["key": key, "office": address, "name": name, "code": code]
            case .iroh(let node, let relay, let expires):
                json = ["v": 2, "o": node, "n": name, "c": code, "e": Int(expires.timeIntervalSince1970)]
                if let relay { json["r"] = relay }
            case .reviewHost(let node, let relay, let expires, let pin, let lan, let role):
                json = ["v": 3, "k": "nas", "o": node, "n": name, "c": code, "e": Int(expires.timeIntervalSince1970), "fp": pin, "role": role]
                if let relay { json["r"] = relay }
                if let lan { json["lan"] = lan }
            }
            guard let data = try? JSONSerialization.data(withJSONObject: json, options: .sortedKeys) else { return nil }
            let text = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return URL(string: "pluck://edit-anywhere/join?i=" + text)
        }

        /// From a link (clicked or pasted, also with spaces, quotes or <> around it). An expired one still reads, so joining can say so.
        init?(link text: String) {
            guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”‘’«»<>`")))),
                  url.scheme == "pluck", url.host == "edit-anywhere",
                  var value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "i" })?.value
            else { return nil }
            value = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while value.count % 4 != 0 { value += "=" }
            guard let data = Data(base64Encoded: value),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            if json["v"] as? Int == 3 {
                // Only the NAS kind (other v3 kinds aren't Pluck's to read yet).
                // (No node: a server without iroh, reached on the office network only; then the link must carry its LAN address.)
                let node = json["o"] as? String ?? ""
                guard json["k"] as? String == "nas", PrivateNetwork.isNodeID(node) || (node.isEmpty && json["lan"] is String),
                      let code = json["c"] as? String, OfficeLink.normalised(code) != nil, let expires = json["e"] as? Double,
                      let pin = (json["fp"] as? String)?.uppercased(), pin.split(separator: ":").count == 32,
                      pin.split(separator: ":").allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else { return nil }
                let relay = json["r"] as? String, role = json["role"] as? String ?? "mac"
                if let relay, PrivateNetwork.relayAddress(relay) == nil { return nil }
                guard ["mac", "backup"].contains(role) else { return nil }
                let lan = (json["lan"] as? String).flatMap { $0.count <= 255 && !$0.contains("/") ? $0 : nil }
                self.init(way: .reviewHost(node: node, relay: relay, expires: Date(timeIntervalSince1970: expires), pin: pin, lan: lan, role: role),
                          name: String((json["n"] as? String ?? "NAS").prefix(60)), code: code)
            } else if json["v"] as? Int == 2 {
                guard let node = json["o"] as? String, PrivateNetwork.isNodeID(node),
                      let code = json["c"] as? String, OfficeLink.normalised(code) != nil,
                      let expires = json["e"] as? Double else { return nil }
                let relay = json["r"] as? String
                if let relay, PrivateNetwork.relayAddress(relay) == nil { return nil }
                self.init(way: .iroh(node: node, relay: relay, expires: Date(timeIntervalSince1970: expires)),
                          name: String((json["n"] as? String ?? "Mac").prefix(60)), code: code)
            } else {
                guard let key = json["key"] as? String, key.hasPrefix("tskey-"), let office = json["office"] as? String,
                      let code = json["code"] as? String, OfficeLink.normalised(code) != nil else { return nil }
                self.init(way: .tailscale(key: key, address: office), name: json["name"] as? String ?? "Mac", code: code)
            }
        }

        init(way: Way, name: String, code: String) {
            self.way = way
            self.name = name
            self.code = code
        }
    }
}

/// The running helper: one per Mac and way (the office kind on the office Mac, the home kind
/// elsewhere).
@MainActor
@Observable
final class Tunnel {
    enum Mode: String { case office, home }

    enum State: Equatable {
        /// iroh: `address` is this Mac's node id and `name` is empty.
        case off, starting, running(name: String, address: String), failed(String)
    }

    /// How a connected Mac is reached (iroh): straight, or through a relay (slow).
    struct Link: Equatable {
        var direct: Bool
        var rtt: Double?
    }

    static let office = Tunnel(.office, .tailscale)
    static let home = Tunnel(.home, .tailscale)
    static let irohOffice = Tunnel(.office, .iroh)
    static let irohHome = Tunnel(.home, .iroh)

    let mode: Mode
    let transport: PrivateNetwork.Transport
    private(set) var state = State.off
    /// Home: the local address that leads to the office Mac.
    private(set) var listen: String?
    /// iroh: this Mac's relay, and how each connected Mac is reached (by node id).
    private(set) var relay: String?
    private(set) var links: [String: Link] = [:]
    /// iroh, home: the office turned this Mac away (invitation used or expired, or removed there).
    private(set) var refused = false
    /// iroh: what the helper last said went wrong while it kept running (no relay, office not reachable).
    private(set) var warning: String?
    /// iroh: the helper's own sockets ("0.0.0.0:52304"), for tests that dial it directly.
    @ObservationIgnored private(set) var bound: [String] = []
    /// iroh, office: the node ids that may connect (the paired Macs').
    @ObservationIgnored private(set) var allow: [String] = []
    /// iroh, office: which Mac each local connection from the helper carries, by its port here.
    @ObservationIgnored private var streams: [UInt16: (peer: String, at: Date)] = [:]
    /// Tests: extra settings for the helper ("local", "keyFile", "officeAddrs", "port").
    @ObservationIgnored var testSettings: [String: Any]?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var pending: Task<Void, Error>?
    /// iroh, home: the office (and relay) the running helper leads to.
    @ObservationIgnored private var target: [String?] = []

    /// iroh: a key of its own (a NAS review host's tunnel, §13.2), instead of Edit Anywhere's.
    let keyFile: URL?

    init(_ mode: Mode, _ transport: PrivateNetwork.Transport, keyFile: URL? = nil) {
        self.mode = mode
        self.transport = transport
        self.keyFile = keyFile
    }

    private var directory: URL {
        transport == .iroh ? PrivateNetwork.folder.appendingPathComponent("iroh", isDirectory: true)
            : PrivateNetwork.folder.appendingPathComponent(mode.rawValue, isDirectory: true)
    }

    /// Whether this Mac has joined the network before (it keeps its identity there). iroh needs no joining.
    var hasJoined: Bool {
        transport == .iroh || FileManager.default.fileExists(atPath: directory.appendingPathComponent("tailscaled.state").path)
    }

    /// Starts the helper and waits until it carries connections. A first Tailscale start needs a
    /// join key. Home: `office` is the office Mac's address on the private network (Tailscale) or
    /// its node id (iroh, with its relay).
    func start(key: String? = nil, office: String? = nil, officeRelay: String? = nil) async throws {
        // Already going (or on its way) to the same place: share that.
        if key == nil, transport == .tailscale || target == [office, officeRelay] {
            if let pending { return try await pending.value }
            if process?.isRunning == true, case .running = state, mode == .office || listen != nil { return }
        }
        let task = Task { try await launch(key: key, office: office, officeRelay: officeRelay) }
        pending = task
        defer { if pending == task { pending = nil } }
        try await task.value
    }

    /// iroh, office: who may connect, now and on the next start.
    func setAllow(_ ids: [String]) {
        allow = ids
        send(["allow": ids])
    }

    /// iroh, office: lets one new Mac in within `seconds` (an invitation).
    func openPairing(_ seconds: TimeInterval) {
        send(["pair": Int(min(seconds, PrivateNetwork.invitationLifetime))])
    }

    /// iroh, office: `node` paired with an invitation's code: it's let in, and one invitation is used.
    func paired(_ node: String) {
        send(["paired": node])
    }

    /// iroh, office: the Mac (node id) a local connection from the helper carries, by the port it
    /// came from here. Waits a moment for the helper's report (it's read separately).
    func peer(port: UInt16) async -> String? {
        guard mode == .office, process?.isRunning == true else { return nil }
        for _ in 0..<40 {
            if let found = streams.removeValue(forKey: port) { return found.peer }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    private func send(_ command: [String: Any]) {
        guard transport == .iroh, process?.isRunning == true, var line = try? JSONSerialization.data(withJSONObject: command) else { return }
        line.append(0x0A)
        try? input?.write(contentsOf: line)
    }

    private func launch(key: String?, office: String?, officeRelay: String?) async throws {
        // Never from a test copy (screenshot mode): it would share this Mac's identity on the
        // private network with the Pluck that's really running. Every start comes through here.
        // (A test's own local iroh helpers, with their own keys and no relays, are fine.)
        if ScreenshotMode.scene != nil, !UserDefaults.standard.bool(forKey: "PluckScreenshotNetwork"),
           testSettings?["local"] as? Bool != true {
            if let log = UserDefaults.standard.string(forKey: "PluckScreenshotTunnelLog") {
                let trace = "\(mode.rawValue) start refused\n" + Thread.callStackSymbols.joined(separator: "\n")
                try? trace.write(toFile: log, atomically: true, encoding: .utf8)
            }
            throw PrivateNetwork.Failure.noHelper
        }
        stop()
        guard let helper = PrivateNetwork.helper(transport) else { throw PrivateNetwork.Failure.noHelper }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        state = .starting
        let process = Process()
        process.executableURL = helper
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
        target = [office, officeRelay]
        var settings: [String: Any]
        switch transport {
        case .tailscale:
            settings = ["mode": mode.rawValue, "dir": directory.path, "hostname": PrivateNetwork.hostname, "port": Int(OfficeLink.port)]
            if let key { settings["authKey"] = key }
            if let office { settings["office"] = office }
        case .iroh:
            settings = ["mode": mode.rawValue, "keyFile": (keyFile ?? directory.appendingPathComponent("\(mode.rawValue).key")).path,
                        "port": Int(OfficeLink.listenPort), "allow": allow]
            if let relay = PrivateNetwork.ownRelay { settings["relay"] = relay }
            if let office { settings["office"] = office }
            if let officeRelay { settings["officeRelay"] = officeRelay }
            settings.merge(testSettings ?? [:]) { $1 }
        }
        var line = try JSONSerialization.data(withJSONObject: settings)
        line.append(0x0A)
        try stdin.fileHandleForWriting.write(contentsOf: line)

        // Its reports, until it carries connections (or gives up), then for as long as it runs.
        let iroh = transport == .iroh
        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            let once = OnceFlag()
            let done: @Sendable (Result<Void, Error>) -> Void = { if once.claim() { continuation.resume(returning: $0) } }
            // Every report is about this process: one that was stopped (and replaced) changes nothing.
            Task.detached { [weak self] in
                var name = "", address = "", lastError: String?
                do {
                    for try await text in Self.lines(stdout.fileHandleForReading) {
                        guard let report = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                              let self, await self.process === process else { continue }
                        if let error = report["error"] as? String {
                            // iroh keeps going after these (it retries); Tailscale's end the start.
                            lastError = error
                            if iroh {
                                await self.warn(error)
                            } else {
                                await self.failed(error)
                                done(.failure(PrivateNetwork.Failure.helper(error)))
                            }
                        }
                        if let stream = report["stream"] as? [String: Any], let peer = stream["peer"] as? String,
                           let port = (stream["port"] as? Int).flatMap(UInt16.init(exactly:)) {
                            await self.carries(port, peer)
                        }
                        if let conn = report["conn"] as? [String: Any], let peer = conn["peer"] as? String {
                            let kind = conn["type"] as? String
                            await self.linked(peer, kind == "none" ? nil : Link(direct: kind == "direct", rtt: conn["rtt"] as? Double))
                        }
                        if let peer = report["closed"] as? String { await self.linked(peer, nil) }
                        if report["refused"] != nil { await self.wasRefused() }
                        switch report["state"] as? String {
                        case "needsKey":
                            done(.failure(PrivateNetwork.Failure.needsInvite))
                        case "running":
                            name = report["name"] as? String ?? ""
                            address = report["id"] as? String ?? (report["ips"] as? [String])?.first { !$0.contains(":") } ?? ""
                            await self.running(relay: report["relay"] as? String, bound: report["addrs"] as? [String] ?? [])
                        case "listening":
                            await self.ready(name: name, address: address, listen: report["listen"] as? String)
                            done(.success(()))
                        default:
                            break
                        }
                    }
                } catch {}
                await self?.ended(process)
                // Quit before carrying anything: what it said last is why (a timeout if nothing).
                done(.failure(lastError.map { PrivateNetwork.Failure.helper($0) } ?? PrivateNetwork.Failure.timeout))
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(100))
                done(.failure(PrivateNetwork.Failure.timeout))
            }
        }
        try result.get()
    }

    /// The helper's report lines. (Not `FileHandle.bytes`: its reads wait on a shared thread, and
    /// with three helpers running, as in the iroh test, a report could sit unread.)
    private nonisolated static func lines(_ handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            let buffer = LineBuffer()
            handle.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    handle.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                for line in buffer.add(chunk) { continuation.yield(line) }
            }
        }
    }

    private final class LineBuffer: @unchecked Sendable {
        private var data = Data()

        /// Called on the handle's own queue only, one chunk at a time.
        func add(_ chunk: Data) -> [String] {
            data.append(chunk)
            var lines: [String] = []
            while let end = data.firstIndex(of: 0x0A) {
                lines.append(String(decoding: data[data.startIndex..<end], as: UTF8.self))
                data.removeSubrange(data.startIndex...end)
            }
            return lines
        }
    }

    private func running(relay: String?, bound: [String]) {
        self.relay = relay
        self.bound = bound
    }

    private func ready(name: String, address: String, listen: String?) {
        self.listen = listen
        state = .running(name: name, address: address)
    }

    private func failed(_ message: String) { state = .failed(message) }

    private func warn(_ message: String) { warning = message }

    private func wasRefused() { refused = true }

    private func carries(_ port: UInt16, _ peer: String) {
        streams = streams.filter { Date.now.timeIntervalSince($0.value.at) < 60 }
        streams[port] = (peer, .now)
    }

    private func linked(_ peer: String, _ link: Link?) {
        links[peer] = link
        if link != nil {
            warning = nil
            refused = false
        }
    }

    private func ended(_ ended: Process) {
        guard process === ended else { return }
        if case .running = state { state = .off }
        if case .starting = state { state = .off }
        process = nil
        listen = nil
        links = [:]
    }

    func stop() {
        try? input?.close()
        process?.terminate()
        process = nil
        input = nil
        listen = nil
        links = [:]
        streams = [:]
        refused = false
        warning = nil
        target = []
        state = .off
    }
}
