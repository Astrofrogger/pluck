import CryptoKit
import Foundation
import Network
import UserNotifications

/// Edit Anywhere, on a Mac at home: pairs once with the office Mac, then asks it to
/// render, follows the render and fetches the preview. See OfficeLink for the protection.
@MainActor
@Observable
final class OfficeRenderClient {
    static let shared = OfficeRenderClient()
    private static let account = "office"

    struct Office: Codable {
        /// The address that worked last.
        var address: String
        /// All the office's addresses (its network, a typed one).
        var addresses: [String]?
        /// The office Mac on the private network (joined with an invitation): the way in from home.
        var network: String?
        var name: String
        var device: UUID
        var secret: Data
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
    private(set) var jobs: [Job] = []
    /// Renders started from this Mac, to say when they finish.
    @ObservationIgnored private var mine: Set<String> = []
    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private var loaded = false

    private init() {}

    func load() {
        guard !loaded else { return }
        loaded = true
        office = OfficeLink.Keychain.load(Self.account).flatMap { try? JSONDecoder().decode(Office.self, from: $0) }
    }

    func forget() {
        OfficeLink.Keychain.delete(Self.account)
        office = nil
        jobs = []
        // Off the private network too: joining again takes a new invitation.
        Tunnel.home.stop()
        try? FileManager.default.removeItem(at: PrivateNetwork.folder.appendingPathComponent("home", isDirectory: true))
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
        try await Tunnel.home.start(key: invitation.key, office: invitation.office)
        guard let listen = Tunnel.home.listen else { throw PrivateNetwork.Failure.timeout }
        try await pair(.address(listen), code: invitation.code, network: invitation.office)
    }

    func pair(_ target: Target, code typed: String, network: String? = nil) async throws {
        guard let code = OfficeLink.normalised(typed) else { throw OfficeLink.Failure.badCode }
        let key = Curve25519.KeyAgreement.PrivateKey()
        let clientKey = key.publicKey.rawRepresentation
        let hello: [String: Any] = ["name": Host.current().localizedName ?? "Mac", "time": Date.now.timeIntervalSince1970]
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
        if network == nil, case .address(let typed) = target {
            let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            if !addresses.contains(typed) { addresses.append(typed) }
        }
        guard let first = network ?? addresses.first else { throw OfficeLink.Failure.garbled }
        let office = Office(address: first, addresses: addresses, network: network, name: answer["office"] as? String ?? "Mac",
                            device: device, secret: secret)
        save(office)
    }

    private func save(_ office: Office) {
        if let data = try? JSONEncoder().encode(office) { OfficeLink.Keychain.save(data, as: Self.account) }
        self.office = office
    }

    // MARK: - Asking

    func ask(_ action: String, _ arguments: [String: Any] = [:], timeout: TimeInterval = 90) async throws -> [String: Any] {
        guard let office else { throw OfficeLink.Failure.refused }
        let keys = OfficeLink.keys(office.secret)
        let nonce = OfficeLink.randomBytes(16)
        let message: [String: Any] = ["action": action, "args": arguments, "time": Date.now.timeIntervalSince1970,
                                      "nonce": nonce.base64EncodedString()]
        let id = OfficeLink.uuidData(office.device)
        let sealed = try ChaChaPoly.seal(try JSONSerialization.data(withJSONObject: message), using: keys.request, authenticating: id)
        let frame = OfficeLink.frame(.request, id + sealed.combined)
        // The private network first (it works from anywhere), then the office network's addresses,
        // the one that worked last first.
        var candidates: [String] = []
        var tunnel: String?
        if let network = office.network {
            try await Tunnel.home.start(office: network)
            tunnel = Tunnel.home.listen
            if let tunnel { candidates.append(tunnel) }
        }
        for address in [office.address] + (office.addresses ?? []) where address != office.network && !candidates.contains(address) {
            candidates.append(address)
        }
        var reply: (kind: OfficeLink.Kind, payload: Data)?
        for address in candidates {
            guard let endpoint = Self.endpoint(address) else { continue }
            let asked = Date.now
            do {
                reply = try await exchange(endpoint, frame, timeout: timeout)
                if address != office.address, address != tunnel {
                    var moved = office
                    moved.address = address
                    save(moved)
                }
                break
            } catch Exchange.noConnection {
                continue
            } catch {
                // Connected, but the office hung up straight away: it doesn't know this Mac (any
                // more), or the message was too old. A long silence is a timeout.
                throw Date.now.timeIntervalSince(asked) < 5 ? OfficeLink.Failure.refused : OfficeLink.Failure.unreachable
            }
        }
        // Only an answer sealed with this Mac's key, to this very question, counts.
        guard let reply else { throw OfficeLink.Failure.unreachable }
        guard reply.kind == .request, let box = try? ChaChaPoly.SealedBox(combined: reply.payload),
              let plain = try? ChaChaPoly.open(box, using: keys.answer, authenticating: nonce),
              let answer = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
              answer["nonce"] as? String == nonce.base64EncodedString() else { throw OfficeLink.Failure.garbled }
        if let error = answer["error"] as? String { throw OfficeLink.Failure.office(error) }
        return answer
    }

    private enum Exchange: Error { case noConnection, noAnswer }

    private static func endpoint(_ address: String) -> NWEndpoint? {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        var host = address, port = OfficeLink.port
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

    private func exchange(_ endpoint: NWEndpoint, _ frame: Data, timeout: TimeInterval) async throws -> (kind: OfficeLink.Kind, payload: Data) {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.connectionTimeout = 6
        let connection = NWConnection(to: endpoint, using: parameters)
        return try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            let finish: @Sendable (Result<(kind: OfficeLink.Kind, payload: Data), Error>) -> Void = { result in
                if once.claim() { connection.cancel(); continuation.resume(with: result) }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: frame, completion: .contentProcessed { error in
                        if error != nil { return finish(.failure(Exchange.noAnswer)) }
                        FrameReader.read(from: connection, limit: OfficeLink.maxAnswer, timeout: timeout) { reply in
                            finish(reply.map { .success($0) } ?? .failure(Exchange.noAnswer))
                        }
                    })
                case .failed, .waiting: finish(.failure(Exchange.noConnection))
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                if connection.state != .ready { finish(.failure(Exchange.noConnection)) }
            }
        }
    }

    // MARK: - Rendering

    func projects() async throws -> [Project] {
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
        if let job = (answer["job"] as? [String: Any]).flatMap(Job.init) {
            mine.insert(job.id)
            jobs.insert(job, at: 0)
        }
        follow()
    }

    // MARK: - The office archive

    struct ArchiveHit: Identifiable, Hashable {
        var id: String
        var place: String
        var start: Double
        var end: Double
        var description: String
        var framing: String
        var movement: String
        var thumbnail: Data?
    }

    /// How far the office Mac is with looking at its footage.
    func archiveStatus() async throws -> (folders: Int, files: Int, indexed: Int, working: Bool) {
        let status = (try await ask("archive"))["archive"] as? [String: Any] ?? [:]
        return (status["folders"] as? Int ?? 0, status["files"] as? Int ?? 0, status["indexed"] as? Int ?? 0, status["working"] as? Bool ?? false)
    }

    func searchArchive(_ query: String, movement: VisualIndex.Movement?, framing: VisualIndex.Framing?) async throws -> [ArchiveHit] {
        var arguments: [String: Any] = ["query": query]
        if let movement { arguments["movement"] = movement.rawValue }
        if let framing { arguments["framing"] = framing.rawValue }
        let answer = try await ask("archiveSearch", arguments, timeout: 60)
        return (answer["hits"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return ArchiveHit(id: id, place: item["place"] as? String ?? "", start: item["start"] as? Double ?? 0,
                              end: item["end"] as? Double ?? 0, description: item["description"] as? String ?? "",
                              framing: item["framing"] as? String ?? "", movement: item["movement"] as? String ?? "",
                              thumbnail: (item["thumb"] as? String).flatMap { Data(base64Encoded: $0) })
        }
    }

    /// Has the office Mac make a light copy of the shot (with handles) and fetches it into the
    /// Downloads folder; `progress` gets 0…1 (making it counts as the first tenth).
    func fetchClip(_ hit: ArchiveHit, progress: @escaping (Double) -> Void) async throws -> URL {
        progress(0.02)
        let made = try await ask("archiveClip", ["id": hit.id], timeout: 600)
        guard let token = made["token"] as? String else { throw OfficeLink.Failure.garbled }
        let name = Folders.sanitize(made["name"] as? String ?? "Clip")
        let folder = UserDefaults.standard.string(forKey: Prefs.downloadPath) ?? NSHomeDirectory() + "/Downloads"
        let target = Converting.outputURL(folder: folder, name: name, fileExtension: "mp4")
        let partial = target.appendingPathExtension("part")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: partial.path) else { throw OfficeLink.Failure.office(String(localized: "The clip couldn’t be saved.")) }
        var offset = 0
        do {
            while true {
                let answer = try await ask("archiveClipData", ["token": token, "offset": offset])
                guard let chunk = (answer["data"] as? String).flatMap({ Data(base64Encoded: $0) }) else { throw OfficeLink.Failure.garbled }
                let size = (answer["size"] as? NSNumber)?.intValue ?? 0
                try handle.write(contentsOf: chunk)
                offset += chunk.count
                progress(0.1 + 0.9 * (size > 0 ? Double(offset) / Double(size) : 1))
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

    func cancel(_ job: Job) async throws {
        _ = try await ask("cancel", ["id": job.id])
        try await refresh()
    }

    func refresh() async throws {
        let answer = try await ask("jobs")
        let fresh = (answer["jobs"] as? [[String: Any]] ?? []).compactMap(Job.init)
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
                let answer = try await ask("preview", ["id": job.id, "offset": offset])
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
