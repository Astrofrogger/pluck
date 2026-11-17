import CryptoKit
import Foundation
import Network
import UserNotifications

/// Edit Anywhere, on a Mac at home: pairs once with the office Mac, then asks it to
/// render, follows the render and fetches the preview. See OfficeLink for the protection.
@MainActor
@Observable
final class OfficeRenderClient {
    static let shared = OfficeRenderClient(account: "office")
    /// Where its pairing is kept (nil: in memory only, an office Mac of the group or another office Mac asking it).
    let account: String?

    struct Office: Codable {
        /// The address that worked last.
        var address: String
        /// All the office's addresses (its network, a typed one).
        var addresses: [String]?
        /// The office Mac on the private network (joined with an invitation): the way in from home.
        var network: String?
        /// Or, joined with an iroh invitation: the office's node id and relay.
        var iroh: String?
        var irohRelay: String?

        /// Reached from anywhere (either way), not only on the local network.
        var fromAnywhere: Bool { network != nil || iroh != nil }
        var name: String
        var device: UUID
        var secret: Data
    }

    /// One office Mac of the group (OfficeGroup) as this Mac sees it: how it's doing, from its last answer.
    struct MemberState: Equatable {
        var online: Bool
        var busy = false
        var load = 0
    }

    struct Project: Hashable, Identifiable {
        var folder: [String]
        var name: String
        var id: String { (folder + [name]).joined(separator: "/") }
    }

    struct Job: Identifiable, Equatable {
        var id: String
        var project: String
        var timeline: String
        var preset: String
        var device: String
        var started: Date
        var state: String
        var progress: Double
        var remaining: Double?
        var problem: String?
        var file: String?
        var previewSize: Int64?
        var makingPreview: Bool
        /// The office Mac of a group it's on (nil: the paired one).
        var host: UUID?

        init?(_ value: [String: Any]) {
            guard let id = value["id"] as? String else { return nil }
            self.id = id
            project = value["project"] as? String ?? ""
            timeline = value["timeline"] as? String ?? ""
            preset = value["preset"] as? String ?? ""
            device = value["device"] as? String ?? ""
            started = Date(timeIntervalSince1970: value["started"] as? Double ?? 0)
            state = value["state"] as? String ?? ""
            progress = value["progress"] as? Double ?? 0
            remaining = value["remaining"] as? Double
            problem = value["problem"] as? String
            file = value["file"] as? String
            previewSize = (value["previewSize"] as? NSNumber)?.int64Value
            makingPreview = value["makingPreview"] as? Bool ?? false
        }
    }

    private(set) var office: Office?
    /// The iroh link to the office (a test uses its own).
    @ObservationIgnored var irohTunnel = Tunnel.irohHome
    private(set) var jobs: [Job] = []
    /// Renders started from this Mac, to say when they finish.
    @ObservationIgnored private var mine: Set<String> = []
    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private var loaded = false
    /// Connections the office kept open for the next question, newest last (an office from before closes each
    /// after one answer). Reusing one skips the connection set-up and TCP's slow start on every file piece.
    @ObservationIgnored private var idle: [(connection: NWConnection, since: Date)] = []
    /// (Well inside the office's OfficeRenderServer.keptIdle, so it never closes one just as it's reused.)
    static let keptIdle: TimeInterval = 15
    static let keptMost = 12
    /// (Tests: off asks like a Mac from before, one question per connection.)
    @ObservationIgnored var keepsConnections = true
    var keptConnections: Int { idle.count }

    // MARK: - Several office Macs (OfficeGroup)

    /// The office's Macs when it has several (empty: one office Mac, as before), and which of them was paired here.
    private(set) var members: [OfficeGroup.Reach] = []
    private(set) var primary: UUID?
    private(set) var memberStates: [UUID: MemberState] = [:]
    /// The office Mac questions go to first (the least busy one online); nil: the paired one.
    private(set) var active: UUID?
    /// The office Mac the Render pane's projects came from: its renders go there too.
    @ObservationIgnored var renderHost: UUID?
    /// The office Mac that answered the last question asked of the group (a render's job is on that one).
    @ObservationIgnored private var answered: UUID?
    /// Which office Macs have each share (local folders are on one only; the NAS on all that mount it).
    @ObservationIgnored private(set) var shareOwners: [String: Set<UUID>] = [:]
    @ObservationIgnored private var memberClients: [UUID: OfficeRenderClient] = [:]

    init(account: String?) {
        self.account = account
    }

    /// Another office Mac or a group's own client: kept in memory only.
    func use(_ office: Office) {
        loaded = true
        if self.office?.device != office.device || self.office?.secret != office.secret { dropKept() }
        self.office = office
    }

    func load() {
        guard !loaded else { return }
        loaded = true
        guard let account else { return }
        office = OfficeLink.Keychain.load(account).flatMap { try? JSONDecoder().decode(Office.self, from: $0) }
        members = OfficeLink.Keychain.load(account + "-members").flatMap { try? JSONDecoder().decode([OfficeGroup.Reach].self, from: $0) } ?? []
        primary = UserDefaults.standard.string(forKey: "editAnywhereOfficePrimary").flatMap(UUID.init(uuidString:))
    }

    func forget() {
        if let account {
            OfficeLink.Keychain.delete(account)
            OfficeLink.Keychain.delete(account + "-members")
        }
        members = []
        primary = nil
        active = nil
        if account != nil {
            UserDefaults.standard.removeObject(forKey: "editAnywhereOfficePrimary")
            UserDefaults.standard.removeObject(forKey: "editAnywhereGroupNodes")
        }
        memberStates = [:]
        memberClients.values.forEach { $0.dropKept(); $0.irohTunnel.stop() }
        memberClients = [:]
        dropKept()
        office = nil
        jobs = []
        // Off the private network too: joining again takes a new invitation.
        Tunnel.home.stop()
        Tunnel.irohHome.stop()
        // (Never from a test copy: the folder belongs to the Pluck that's really running.)
        if ScreenshotMode.scene == nil {
            try? FileManager.default.removeItem(at: PrivateNetwork.folder.appendingPathComponent("home", isDirectory: true))
        }
    }

    // MARK: - Pairing

    /// Where to reach the office Mac when pairing: found on this network, or typed.
    enum Target {
        case found(NWEndpoint)
        case address(String)
    }

    /// An invitation link that arrived (clicked in Messages or Mail), waiting for a yes.
    var pendingInvitation: PrivateNetwork.Invitation?

    /// Joins the office's private network with the invitation, then pairs over it.
    func join(_ invitation: PrivateNetwork.Invitation) async throws {
        let tunnel = irohTunnel
        switch invitation.way {
        case .tailscale(let key, let address):
            try await Tunnel.home.start(key: key, office: address)
            guard let listen = Tunnel.home.listen else { throw PrivateNetwork.Failure.timeout }
            try await pair(.address(listen), code: invitation.code, network: address)
        case .reviewHost:
            // (A NAS review host's link: Deliver pairs with those, URLScheme sends them there.)
            throw PrivateNetwork.Failure.inviteUsed
        case .iroh(let node, let relay, _):
            guard !invitation.expired else { throw PrivateNetwork.Failure.inviteExpired }
            // A helper the office turned away doesn't dial again: a new invitation starts afresh.
            if tunnel.refused { tunnel.stop() }
            try await tunnel.start(office: node, officeRelay: relay)
            guard let listen = tunnel.listen, case .running(_, let mine) = tunnel.state else { throw PrivateNetwork.Failure.timeout }
            do {
                try await pair(.address(listen), code: invitation.code, iroh: (node, relay, mine))
            } catch {
                // Turned away by the office's helper: the link was used (or ran out) there.
                if !tunnel.refused { try? await Task.sleep(for: .milliseconds(500)) }
                throw tunnel.refused ? PrivateNetwork.Failure.inviteUsed : error
            }
        }
    }

    /// `iroh`: the office's node id and relay, and this Mac's node id (sent so the office lets it in).
    /// `member`: this Mac joining the office's group as another office Mac (its own part of the group, encoded); the
    /// answer's "group" is then the group's state. Gives back the office's answer.
    @discardableResult
    func pair(_ target: Target, code typed: String, network: String? = nil,
              iroh: (office: String, relay: String?, mine: String)? = nil, member: String? = nil) async throws -> [String: Any] {
        guard let code = OfficeLink.normalised(typed) else { throw OfficeLink.Failure.badCode }
        let key = Curve25519.KeyAgreement.PrivateKey()
        let clientKey = key.publicKey.rawRepresentation
        var hello: [String: Any] = ["name": Host.current().localizedName ?? "Mac", "time": Date.now.timeIntervalSince1970]
        if let iroh { hello["iroh"] = iroh.mine }
        if let member { hello["role"] = "peer"; hello["member"] = member }
        let sealed = try ChaChaPoly.seal(try JSONSerialization.data(withJSONObject: hello),
                                         using: OfficeLink.codeKey(code, clientKey: clientKey), authenticating: Data("pluck-pair".utf8))
        let endpoint: NWEndpoint
        switch target {
        case .found(let found): endpoint = found
        case .address(let typed):
            guard let typed = Self.endpoint(typed) else { throw OfficeLink.Failure.unreachable }
            endpoint = typed
        }
        let reply: (kind: OfficeLink.Kind, payload: Data)
        do {
            reply = try await exchange(endpoint, OfficeLink.frame(.pair, clientKey + sealed.combined), timeout: 20)
        } catch Exchange.noConnection {
            throw OfficeLink.Failure.unreachable
        } catch {
            // A wrong code gets no answer at all (the office just hangs up).
            throw OfficeLink.Failure.badCode
        }
        guard reply.kind == .pair, reply.payload.count > 32 else { throw OfficeLink.Failure.badCode }
        let officeKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: reply.payload.prefix(32))
        let shared = try key.sharedSecretFromKeyAgreement(with: officeKey)
        let answerKey = OfficeLink.pairingAnswerKey(shared, code: code, clientKey: clientKey, officeKey: officeKey.rawRepresentation)
        guard let box = try? ChaChaPoly.SealedBox(combined: reply.payload.dropFirst(32)),
              let plain = try? ChaChaPoly.open(box, using: answerKey, authenticating: Data("pluck-pair-answer".utf8)),
              let answer = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
              let device = (answer["device"] as? String).flatMap(UUID.init(uuidString:)),
              let secret = (answer["secret"] as? String).flatMap({ Data(base64Encoded: $0) }), secret.count == 32 else {
            throw OfficeLink.Failure.garbled
        }
        // Every address the office has (Tailscale's first), so the pairing done at the office
        // also works from home; a typed address is kept too.
        var addresses = (answer["addresses"] as? [String] ?? []).filter { !$0.isEmpty }
        if network == nil, iroh == nil, case .address(let typed) = target {
            let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            if !addresses.contains(typed) { addresses.append(typed) }
        }
        guard let first = network ?? addresses.first ?? (iroh != nil ? "" : nil) else { throw OfficeLink.Failure.garbled }
        let office = Office(address: first, addresses: addresses, network: network, iroh: iroh?.office, irohRelay: iroh?.relay,
                            name: answer["office"] as? String ?? "Mac", device: device, secret: secret)
        save(office)
        return answer
    }

    /// Tests: asks only at this address (a test's own route to the office).
    func useOnly(_ address: String) {
        guard var office else { return }
        office.address = address
        office.addresses = [address]
        dropKept()
        save(office)
    }

    private func save(_ office: Office) {
        if let account, let data = try? JSONEncoder().encode(office) { OfficeLink.Keychain.save(data, as: account) }
        self.office = office
    }

    // MARK: - Asking

    /// Questions that only read: they may go on a kept connection, and are asked again on a fresh one when it turns out
    /// dead. Any other (render, cancel, proxies made…) always goes on a fresh connection: asked twice, it could run twice.
    /// (Slow reads, a share's first manifest or Resolve's projects, stay out too: they'd be asked twice while still working.)
    nonisolated static let retryable: Set<String> = ["fileData", "proxyData", "thumb", "browse", "mediaInfo", "shares", "status", "jobs",
                                                     "driveInfo", "proxyStatus", "proxyFolders", "shareProxyStatus", "sendState",
                                                     "resolveQueue", "resolvePresets", "resolveVersionData", "reviewLinks", "reviewComments"]
    /// How long a kept connection may take to start its answer: a dead one that still says ready never does.
    nonisolated static let keptFirstAnswer: TimeInterval = 10

    /// No address of the office Mac answered (nothing was asked): another office Mac of the group may be.
    struct NoRoute: Error {}

    func ask(_ action: String, _ arguments: [String: Any] = [:], timeout: TimeInterval = 90) async throws -> [String: Any] {
        guard members.count > 1, account != nil else {
            do { return try await askHere(action, arguments, timeout: timeout) } catch is NoRoute { throw OfficeLink.Failure.unreachable }
        }
        return try await askGroup(action, arguments, timeout: timeout)
    }

    /// Asks this office Mac only (throws NoRoute when none of its addresses answered).
    func askHere(_ action: String, _ arguments: [String: Any] = [:], timeout: TimeInterval = 90) async throws -> [String: Any] {
        guard let office else { throw OfficeLink.Failure.refused }
        let keys = OfficeLink.keys(office.secret)
        // A connection the office kept open goes first (for a question that may be asked again).
        if keepsConnections, Self.retryable.contains(action), let connection = takeKept() {
            let question = try Self.question(action, arguments, office: office, keys: keys, keep: true)
            do {
                return try finish(try await Self.roundTrip(connection, question.frame, timeout: timeout, first: Self.keptFirstAnswer),
                                  nonce: question.nonce, keys: keys, on: connection)
            } catch Exchange.noAnswer {
                // Closed meanwhile, or dead: asked again on a new one (a fresh nonce).
                connection.cancel()
            }
        }
        let question = try Self.question(action, arguments, office: office, keys: keys, keep: keepsConnections)
        // The private network first (it works from anywhere), then the office network's addresses,
        // the one that worked last first.
        var candidates: [String] = []
        var tunnel: String?
        do {
            if let network = office.network {
                try await Tunnel.home.start(office: network)
                tunnel = Tunnel.home.listen
                if let tunnel { candidates.append(tunnel) }
            } else if let node = office.iroh {
                // (A helper the office Mac turned away doesn't dial again: one of the group's links may be let in later.)
                if irohTunnel.refused, account == nil { irohTunnel.stop() }
                try await irohTunnel.start(office: node, officeRelay: office.irohRelay)
                tunnel = irohTunnel.listen
                if let tunnel { candidates.append(tunnel) }
            }
        } catch where account == nil || members.count > 1 {
            // A group's other office Macs: their link not up is no way there (their office network may still be).
        }
        for address in [office.address] + (office.addresses ?? []) where address != office.network && !candidates.contains(address) {
            candidates.append(address)
        }
        for address in candidates {
            guard let endpoint = Self.endpoint(address), let connection = try? await Self.connect(endpoint) else { continue }
            let asked = Date.now
            let reply: Reply
            do {
                reply = try await Self.roundTrip(connection, question.frame, timeout: timeout)
            } catch {
                connection.cancel()
                // Connected, but the office hung up straight away: it doesn't know this Mac (any
                // more), or the message was too old. A long silence is a timeout.
                throw Date.now.timeIntervalSince(asked) < 5 ? OfficeLink.Failure.refused : OfficeLink.Failure.unreachable
            }
            if address != office.address, address != tunnel {
                var moved = office
                moved.address = address
                save(moved)
            }
            return try finish(reply, nonce: question.nonce, keys: keys, on: connection)
        }
        throw NoRoute()
    }

    private typealias Reply = (kind: OfficeLink.Kind, payload: Data)

    /// A question sealed with this Mac's key, with the time and a fresh nonce; `keep` asks the office to keep the connection.
    private static func question(_ action: String, _ arguments: [String: Any], office: Office,
                                 keys: (request: SymmetricKey, answer: SymmetricKey), keep: Bool) throws -> (frame: Data, nonce: Data) {
        let nonce = OfficeLink.randomBytes(16)
        var message: [String: Any] = ["action": action, "args": arguments, "time": Date.now.timeIntervalSince1970,
                                      "nonce": nonce.base64EncodedString()]
        if keep { message["keep"] = true }
        let id = OfficeLink.uuidData(office.device)
        let sealed = try ChaChaPoly.seal(try JSONSerialization.data(withJSONObject: message), using: keys.request, authenticating: id)
        return (OfficeLink.frame(.request, id + sealed.combined), nonce)
    }

    /// Opens the answer; the connection is kept for the next question when the office said it keeps it, else closed.
    private func finish(_ reply: Reply, nonce: Data, keys: (request: SymmetricKey, answer: SymmetricKey), on connection: NWConnection) throws -> [String: Any] {
        // Only an answer sealed with this Mac's key, to this very question, counts.
        // A data answer carries raw bytes after its JSON: given back under OfficeActions.bytesKey.
        guard reply.kind == .request || reply.kind == .data, let box = try? ChaChaPoly.SealedBox(combined: reply.payload),
              let plain = try? ChaChaPoly.open(box, using: keys.answer, authenticating: nonce),
              let parts: (json: Data, bytes: Data?) = reply.kind == .data ? OfficeActions.split(plain).map { ($0.json, $0.bytes) } : (plain, nil),
              var answer = try? JSONSerialization.jsonObject(with: parts.json) as? [String: Any],
              answer["nonce"] as? String == nonce.base64EncodedString() else {
            connection.cancel()
            throw OfficeLink.Failure.garbled
        }
        if answer.removeValue(forKey: "keep") as? Bool == true, keepsConnections, idle.count < Self.keptMost {
            idle.append((connection, .now))
        } else {
            connection.cancel()
        }
        if let error = answer["error"] as? String { throw OfficeLink.Failure.office(error) }
        if let bytes = parts.bytes { answer[OfficeActions.bytesKey] = bytes }
        return answer
    }

    /// The newest kept connection still fresh (older ones go).
    private func takeKept() -> NWConnection? {
        while let last = idle.popLast() {
            if last.connection.state == .ready, Date.now.timeIntervalSince(last.since) < Self.keptIdle { return last.connection }
            last.connection.cancel()
        }
        return nil
    }

    private func dropKept() {
        idle.forEach { $0.connection.cancel() }
        idle = []
    }

    private enum Exchange: Error { case noConnection, noAnswer }

    private static func endpoint(_ address: String) -> NWEndpoint? {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        var host = address, port = OfficeLink.listenPort
        // "name:port" or "[v6]:port"; a bare IPv6 address has several colons and no port.
        if let colon = address.lastIndex(of: ":"), address.filter({ $0 == ":" }).count == 1 || address.hasPrefix("["),
           let typed = UInt16(address[address.index(after: colon)...]) {
            host = String(address[..<colon])
            port = typed
        }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty, let endpointPort = NWEndpoint.Port(rawValue: port) else { return nil }
        return .hostPort(host: NWEndpoint.Host(host), port: endpointPort)
    }

    /// One question, one answer, on a connection of its own (pairing).
    private func exchange(_ endpoint: NWEndpoint, _ frame: Data, timeout: TimeInterval) async throws -> Reply {
        let connection = try await Self.connect(endpoint)
        defer { connection.cancel() }
        return try await Self.roundTrip(connection, frame, timeout: timeout)
    }

    private static func connect(_ endpoint: NWEndpoint) async throws -> NWConnection {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.connectionTimeout = 6
        let connection = NWConnection(to: endpoint, using: parameters)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            let fail: @Sendable () -> Void = {
                if once.claim() { connection.cancel(); continuation.resume(throwing: Exchange.noConnection) }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { continuation.resume() }
                case .failed, .waiting: fail()
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { fail() }
        }
        return connection
    }

    /// Sends one frame and reads one answer frame; the connection stays as it is (the caller keeps or closes it).
    /// `first`: how long until the answer starts (nil: the whole `timeout`).
    private static func roundTrip(_ connection: NWConnection, _ frame: Data, timeout: TimeInterval, first: TimeInterval? = nil) async throws -> Reply {
        try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            let finish: @Sendable (Result<Reply, Error>) -> Void = { result in
                if once.claim() { continuation.resume(with: result) }
            }
            connection.send(content: frame, completion: .contentProcessed { error in
                if error != nil { finish(.failure(Exchange.noAnswer)) }
            })
            FrameReader.read(from: connection, limit: OfficeLink.maxAnswer, timeout: timeout, first: first) { reply in
                finish(reply.map { .success($0) } ?? .failure(Exchange.noAnswer))
            }
        }
    }

    // MARK: - Rendering

    func projects() async throws -> [Project] {
        // Several office Macs: the projects (and so the render) of the least busy one online.
        if members.count > 1 {
            await pickOffice()
            renderHost = active ?? primary
        }
        let answer = try await ask("projects", timeout: 120)
        return (answer["projects"] as? [[String: Any]] ?? []).compactMap {
            guard let name = $0["name"] as? String else { return nil }
            return Project(folder: $0["folder"] as? [String] ?? [], name: name)
        }
    }

    func details(_ project: Project) async throws -> (timelines: [String], presets: [String], current: String?) {
        let answer = try await ask("project", ["folder": project.folder, "name": project.name], timeout: 180)
        return (answer["timelines"] as? [String] ?? [], answer["presets"] as? [String] ?? [], answer["timeline"] as? String)
    }

    func render(_ project: Project, timeline: String, preset: String) async throws {
        let answer = try await ask("render", ["folder": project.folder, "name": project.name, "timeline": timeline, "preset": preset], timeout: 180)
        if var job = (answer["job"] as? [String: Any]).flatMap(Job.init) {
            if members.count > 1 { job.host = answered ?? renderHost ?? active ?? primary }
            mine.insert(job.id)
            jobs.insert(job, at: 0)
        }
        follow()
    }

    func cancel(_ job: Job) async throws {
        _ = try await ask(on: job.host, "cancel", ["id": job.id])
        try await refresh()
    }

    func refresh() async throws {
        var fresh: [Job]
        if members.count > 1 {
            // Each office Mac's renders, together (newest first).
            fresh = []
            for member in members {
                guard let answer = try? await client(member.id).askHere("jobs", timeout: 20) else { continue }
                fresh += (answer["jobs"] as? [[String: Any]] ?? []).compactMap(Job.init).map { var job = $0; job.host = member.id; return job }
            }
            fresh.sort { $0.started > $1.started }
        } else {
            let answer = try await ask("jobs")
            fresh = (answer["jobs"] as? [[String: Any]] ?? []).compactMap(Job.init)
        }
        for job in fresh where mine.contains(job.id) {
            guard let before = jobs.first(where: { $0.id == job.id }) else { continue }
            if job.state != before.state || (before.makingPreview && !job.makingPreview) { announce(job) }
        }
        jobs = fresh
    }

    /// Checks every few seconds while a render from this Mac is going.
    func follow() {
        guard following == nil else { return }
        following = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                try? await refresh()
                let open = jobs.filter { mine.contains($0.id) && ($0.state == "rendering" || $0.makingPreview) }
                if open.isEmpty { break }
            }
            following = nil
        }
    }

    private func announce(_ job: Job) {
        guard UserDefaults.standard.bool(forKey: Prefs.notify), Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        switch job.state {
        case "done" where job.makingPreview: return
        case "done":
            content.title = String(localized: "Rendered on the host Mac")
            content.body = job.previewSize != nil ? String(localized: "\(job.timeline) is ready. The preview can be downloaded in Pluck.") : job.timeline
        case "failed":
            content.title = String(localized: "The render on the host Mac failed")
            content.body = job.problem ?? job.timeline
        case "cancelled":
            content.title = String(localized: "The render on the host Mac was cancelled")
            content.body = job.timeline
        default: return
        }
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Fetches the preview into the Downloads folder, piece by piece; `progress` gets 0…1.
    func downloadPreview(_ job: Job, progress: @escaping (Double) -> Void) async throws -> URL {
        let folder = UserDefaults.standard.string(forKey: Prefs.downloadPath) ?? NSHomeDirectory() + "/Downloads"
        let name = Folders.sanitize(job.timeline) + String(localized: " (preview)")
        let target = Converting.outputURL(folder: folder, name: name, fileExtension: "mp4")
        let partial = target.appendingPathExtension("part")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: partial.path) else { throw OfficeLink.Failure.office(String(localized: "The preview couldn’t be saved.")) }
        var offset = 0
        do {
            while true {
                let answer = try await ask(on: job.host, "preview", ["id": job.id, "offset": offset])
                guard let chunk = (answer["data"] as? String).flatMap({ Data(base64Encoded: $0) }) else { throw OfficeLink.Failure.garbled }
                let size = (answer["size"] as? NSNumber)?.intValue ?? 0
                try handle.write(contentsOf: chunk)
                offset += chunk.count
                progress(size > 0 ? Double(offset) / Double(size) : 1)
                if chunk.isEmpty || offset >= size { break }
            }
            try handle.close()
            try FileManager.default.moveItem(at: partial, to: target)
            return target
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }
}

/// Office Macs on this network (they announce themselves while Edit Anywhere is on).
@MainActor
@Observable
final class OfficeFinder {
    struct Found: Identifiable, Hashable {
        var name: String
        var endpoint: NWEndpoint
        var id: String { name }
    }

    private(set) var found: [Found] = []
    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: OfficeLink.service, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> Found? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                // Not this Mac itself.
                guard name != Host.current().localizedName else { return nil }
                return Found(name: name, endpoint: result.endpoint)
            }.sorted { $0.name < $1.name }
            Task { @MainActor in self?.found = found }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}

// MARK: - An office of several Macs

/// The home Mac's side of OfficeGroup: the office's Macs (learnt from the paired one), each asked with the same pairing
/// (the group shares it), the least busy one online first and the next one when it goes away.
extension OfficeRenderClient {
    /// Actions about what's kept on one office Mac (its Resolve projects, reviews, what was sent there): asked of the
    /// paired one first, the others only when it can't be reached.
    nonisolated static func pinned(_ action: String) -> Bool {
        action.hasPrefix("resolve") || action.hasPrefix("review") || action.hasPrefix("send") || action == "groupNode"
    }

    /// The client of one office Mac of the group (this one for the paired Mac).
    func client(_ id: UUID) -> OfficeRenderClient {
        guard id != primary, let office, let reach = members.first(where: { $0.id == id }) else { return self }
        let client = memberClients[id] ?? {
            let made = OfficeRenderClient(account: nil)
            // (Its own iroh key: one node id can't be on two links at once. OfficeGroup lets it in, see groupNode.)
            made.irohTunnel = Tunnel(.home, .iroh, keyFile: PrivateNetwork.folder.appendingPathComponent("iroh/home-\(id.uuidString).key"))
            memberClients[id] = made
            return made
        }()
        client.use(Office(address: reach.addresses.first ?? "", addresses: reach.addresses,
                          iroh: office.iroh != nil ? reach.iroh : nil, irohRelay: reach.relay,
                          name: reach.name, device: office.device, secret: office.secret))
        return client
    }

    /// Asks the office Mac a render (or other thing) is on (nil: wherever).
    func ask(on host: UUID?, _ action: String, _ arguments: [String: Any] = [:], timeout: TimeInterval = 90) async throws -> [String: Any] {
        guard let host, members.count > 1 else { return try await ask(action, arguments, timeout: timeout) }
        do { return try await client(host).askHere(action, arguments, timeout: timeout) } catch is NoRoute { throw OfficeLink.Failure.unreachable }
    }

    /// Tests: these office Macs, without asking.
    func useMembers(_ found: [OfficeGroup.Reach], primary: UUID, active: UUID?) {
        members = found
        self.primary = primary
        self.active = active
        memberStates = [:]
    }

    /// Which office Macs to try, in turn.
    func route(_ action: String, _ arguments: [String: Any]) -> [UUID] {
        let ids = members.map(\.id)
        let first: UUID? = Self.pinned(action) ? primary
            : ["projects", "project", "render"].contains(action) ? (renderHost ?? active ?? primary) : (active ?? primary)
        var order = OfficeGroup.order(ids.map { id in (id, memberStates[id] ?? MemberState(online: true)) }, first: first)
        if let share = (arguments["share"] ?? arguments["folder"]) as? String, let owners = shareOwners[share] {
            order = order.filter(owners.contains) + order.filter { !owners.contains($0) }
        }
        return order
    }

    /// One question, to the office Macs in turn: the next one only when this one can't be reached (for a question that
    /// may be asked twice, also when it stopped answering).
    func askGroup(_ action: String, _ arguments: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        var last: Error = OfficeLink.Failure.unreachable
        answered = nil
        for id in route(action, arguments) {
            do {
                let answer = try await client(id).askHere(action, arguments, timeout: timeout)
                answered = id
                memberStates[id, default: MemberState(online: true)].online = true
                if !Self.pinned(action), memberStates[active ?? primary ?? id]?.online == false { active = id }
                return answer
            } catch is NoRoute {
                memberStates[id, default: MemberState(online: false)].online = false
            } catch OfficeLink.Failure.unreachable where Self.retryable.contains(action) {
                memberStates[id, default: MemberState(online: false)].online = false
                last = OfficeLink.Failure.unreachable
            }
        }
        throw last
    }

    /// Learns the office's Macs from any it reaches (an office from before, or a single Mac, says none), lets this Mac's
    /// link to each in (groupNode), then picks the one to use.
    func refreshGroup() async {
        guard let office, account != nil else { return }
        var answer: [String: Any]?
        for id in [primary].compactMap({ $0 }) + members.map(\.id) where answer == nil {
            answer = try? await client(id).askHere("officeGroup", timeout: 15)
        }
        if answer == nil, members.isEmpty { answer = try? await askHere("officeGroup", timeout: 15) }
        guard let answer else { return }
        let found = (answer["members"] as? String).flatMap(OfficeGroup.decode([OfficeGroup.Reach].self)) ?? []
        let me = (answer["me"] as? String).flatMap(UUID.init(uuidString:))
        if members.isEmpty || primary == nil, let me { primary = me }
        if let primary { UserDefaults.standard.set(primary.uuidString, forKey: "editAnywhereOfficePrimary") }
        if found != members {
            members = found.count > 1 ? found : []
            if let account, let data = try? JSONEncoder().encode(members) { OfficeLink.Keychain.save(data, as: account + "-members") }
            memberClients = memberClients.filter { id, client in
                if members.contains(where: { $0.id == id }) { return true }
                client.irohTunnel.stop()
                return false
            }
        }
        guard members.count > 1 else { return }
        if office.iroh != nil {
            let registered = Set(UserDefaults.standard.stringArray(forKey: "editAnywhereGroupNodes") ?? [])
            for member in members where member.id != primary && member.iroh != nil {
                let link = client(member.id)
                try? await link.irohTunnel.start(office: member.iroh, officeRelay: member.relay)
                guard case .running(_, let node) = link.irohTunnel.state, !node.isEmpty, !registered.contains(node) else { continue }
                if (try? await ask("groupNode", ["node": node], timeout: 20)) != nil {
                    UserDefaults.standard.set(Array(registered.union([node])), forKey: "editAnywhereGroupNodes")
                }
            }
        }
        await pickOffice()
    }

    /// Asks every office Mac how it's doing (at once), and uses the least busy one online.
    func pickOffice() async {
        guard members.count > 1 else { return }
        let asked = await withTaskGroup(of: (UUID, [String: Any]?).self) { group in
            for member in members {
                let link = client(member.id)
                group.addTask { @MainActor in (member.id, try? await link.askHere("status", timeout: 10)) }
            }
            var found: [(UUID, [String: Any]?)] = []
            for await item in group { found.append(item) }
            return found
        }
        for (id, answer) in asked {
            memberStates[id] = MemberState(online: answer != nil, busy: answer?["busy"] as? Bool ?? false,
                                           load: (answer?["load"] as? NSNumber)?.intValue ?? 0)
        }
        active = OfficeGroup.choose(members.map { ($0.id, memberStates[$0.id] ?? MemberState(online: false)) }, current: active)
    }

    /// Every office Mac's shares as one list: the same NAS folder (one id on all of them, OfficeGroup) once, a folder only
    /// one Mac has with its name after it.
    func groupShares() async throws -> [RemoteShare] {
        var lists: [(UUID, [RemoteShare])] = []
        for member in members {
            guard let answer = try? await client(member.id).askHere("shares", timeout: 30) else {
                memberStates[member.id, default: MemberState(online: false)].online = false
                continue
            }
            lists.append((member.id, (answer["shares"] as? [[String: Any]] ?? []).compactMap(RemoteShare.init)))
        }
        guard !lists.isEmpty else { throw OfficeLink.Failure.unreachable }
        let merged = OfficeGroup.mergeShares(lists, names: Dictionary(members.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }))
        shareOwners = merged.owners
        return merged.shares
    }
}
