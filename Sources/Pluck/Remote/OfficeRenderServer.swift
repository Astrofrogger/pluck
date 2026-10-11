import CryptoKit
import Foundation
import Network

/// Edit Anywhere, on the office Mac: paired Macs at home ask DaVinci Resolve here to
/// render a timeline (with the originals on the office storage), follow it, and get a small
/// preview back. Off until turned on; see OfficeLink for how it's kept private.
@MainActor
@Observable
final class OfficeRenderServer {
    static let shared = OfficeRenderServer()

    static let enabledKey = "officeRenderEnabled"
    static let folderKey = "officeRenderFolder"
    private static let lastSeenKey = "officeRenderLastSeen"
    private static let devicesAccount = "devices"

    struct Device: Codable, Identifiable, Hashable {
        var id: UUID
        var name: String
        var secret: Data
        var added: Date
    }

    /// A render a paired Mac asked for.
    struct Job: Codable, Identifiable {
        enum State: String, Codable { case rendering, done, failed, cancelled }
        var id: UUID
        var resolveJob: String
        var folder: [String]
        var project: String
        var timeline: String
        var preset: String
        var device: String
        var deviceID: UUID
        var started: Date
        var state = State.rendering
        var progress = 0.0
        var remaining: Double?
        var problem: String?
        var file: String?
        var preview: String?
        var previewSize: Int64?
        var making = false

        /// What a paired Mac is told (file names, never paths on this Mac).
        var summary: [String: Any] {
            var result: [String: Any] = ["id": id.uuidString, "project": project, "timeline": timeline, "preset": preset,
                                         "device": device, "started": started.timeIntervalSince1970, "state": state.rawValue,
                                         "progress": progress, "makingPreview": making]
            if let remaining { result["remaining"] = remaining }
            if let problem { result["problem"] = problem }
            if let file { result["file"] = URL(fileURLWithPath: file).lastPathComponent }
            if let previewSize { result["previewSize"] = previewSize }
            return result
        }
    }

    private(set) var isRunning = false
    private(set) var problem: String?
    private(set) var devices: [Device] = []
    private(set) var jobs: [Job] = []
    /// The code shown while a Mac is being paired, and until when it works.
    private(set) var pairing: (code: String, expires: Date)?
    /// Codes from invitations (a day each), besides the one shown for pairing here.
    @ObservationIgnored private var invitations: [String: Date] = [:]
    /// The private network's state on this Mac (see Tunnel).
    var network: Tunnel { Tunnel.office }
    private(set) var networkProblem: String?
    private(set) var lastSeen: [UUID: Date] = [:]
    /// The paired Mac that just joined (for the window to say so).
    private(set) var justPaired: String?

    var renderFolder: URL? {
        UserDefaults.standard.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    @ObservationIgnored weak var manager: DownloadManager?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private let queue = DispatchQueue(label: "be.wideopen.pluck.office-render")
    @ObservationIgnored private var pairingTriesLeft = 0
    /// Nonces seen in the last few minutes, against replays.
    @ObservationIgnored private var nonces: [Data: Date] = [:]
    /// Addresses that sent garbage, to shut out anyone probing.
    @ObservationIgnored private var strikes: [String: (count: Int, since: Date)] = [:]
    @ObservationIgnored private var open = 0
    @ObservationIgnored private var watching: Task<Void, Never>?
    @ObservationIgnored private var loaded = false

    private init() {
        let seen = UserDefaults.standard.dictionary(forKey: Self.lastSeenKey) as? [String: Date] ?? [:]
        lastSeen = Dictionary(uniqueKeysWithValues: seen.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
        jobs = (try? JSONDecoder().decode([Job].self, from: Data(contentsOf: Self.jobsFile))) ?? []
        for index in jobs.indices where jobs[index].state == .rendering { jobs[index].making = false }
    }

    private static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/Office Render", isDirectory: true)
    }
    private static var jobsFile: URL { support.appendingPathComponent("jobs.json") }
    private static var previews: URL { support.appendingPathComponent("Previews", isDirectory: true) }

    // MARK: - Turning it on

    func startIfEnabled() {
        if UserDefaults.standard.bool(forKey: Self.enabledKey) { start() }
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { start() } else { stop() }
    }

    private func loadDevices() {
        guard !loaded else { return }
        loaded = true
        devices = OfficeLink.Keychain.load(Self.devicesAccount).flatMap { try? JSONDecoder().decode([Device].self, from: $0) } ?? []
    }

    private func saveDevices() {
        if let data = try? JSONEncoder().encode(devices) { OfficeLink.Keychain.save(data, as: Self.devicesAccount) }
    }

    func start() {
        loadDevices()
        guard listener == nil else { return }
        problem = nil
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: OfficeLink.port),
              let listener = try? NWListener(using: parameters, on: port) else {
            problem = String(localized: "Pluck couldn’t open port \(OfficeLink.port) on this Mac.")
            return
        }
        listener.service = NWListener.Service(name: Host.current().localizedName ?? "Mac", type: OfficeLink.service)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.listenerChanged(state) }
        }
        listener.start(queue: queue)
        self.listener = listener
        watch()
        startNetwork()
        OfficeArchive.shared.manager = manager
        OfficeArchive.shared.tidyClips()
        if ScreenshotMode.scene == nil { OfficeArchive.shared.scan() }
    }

    func stop() {
        OfficeArchive.shared.stop()
        listener?.cancel()
        listener = nil
        isRunning = false
        pairing = nil
        network.stop()
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready: isRunning = true
        case .failed(let error):
            // The port taken: another Pluck (another copy, or a second user) is the office Mac already.
            if case .posix(let code) = error, code == .EADDRINUSE {
                problem = String(localized: "Another Pluck on this Mac is already sharing it.")
            } else {
                problem = error.localizedDescription
            }
            stop()
        case .cancelled: isRunning = false
        default: break
        }
    }

    func setRenderFolder(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: Self.folderKey)
    }

    // MARK: - Pairing and paired Macs

    func startPairing() {
        pairing = (OfficeLink.newPairingCode(), Date.now.addingTimeInterval(OfficeLink.pairingLifetime))
        pairingTriesLeft = max(pairingTriesLeft, OfficeLink.pairingTries)
        justPaired = nil
        let code = pairing?.code
        DispatchQueue.main.asyncAfter(deadline: .now() + OfficeLink.pairingLifetime + 0.5) { [weak self] in
            if self?.pairing?.code == code { self?.pairing = nil }
        }
    }

    func cancelPairing() { pairing = nil }

    /// Pairing codes that work right now.
    private var activeCodes: [String] {
        invitations = invitations.filter { $0.value > .now }
        var codes = Array(invitations.keys)
        if let pairing, pairing.expires > .now { codes.insert(pairing.code, at: 0) }
        return codes
    }

    // MARK: - The private network

    /// Puts this Mac on the private network (joining it the first time with a key from the
    /// Tailscale account), so Macs at home reach it.
    func startNetwork() {
        // Never from a test or screenshot run: it would share this Mac's network identity with
        // the Pluck that's really running.
        guard ScreenshotMode.scene == nil || UserDefaults.standard.bool(forKey: "PluckScreenshotNetwork") else { return }
        guard PrivateNetwork.helper != nil, network.hasJoined || PrivateNetwork.Account.token != nil else { return }
        networkProblem = nil
        Task {
            do {
                do {
                    try await network.start()
                } catch PrivateNetwork.Failure.needsInvite {
                    try await network.start(key: PrivateNetwork.Account.joinKey(expiry: 3600))
                }
                await PrivateNetwork.Account.keepPluckMacsConnected()
            } catch {
                networkProblem = error.localizedDescription
            }
        }
    }

    func connectAccount(token: String) {
        PrivateNetwork.Account.save(token: token)
        startNetwork()
    }

    /// A one-time invitation link for a Mac at home: it joins the private network and pairs with
    /// this Mac in one go. Works for a day.
    func invite() async throws -> URL {
        guard case .running(_, let address) = network.state, !address.isEmpty else {
            throw OfficeLink.Failure.office(String(localized: "This Mac isn’t on the private network yet."))
        }
        let key = try await PrivateNetwork.Account.joinKey(expiry: 86_400)
        let code = OfficeLink.newPairingCode()
        invitations[code] = Date.now.addingTimeInterval(86_400)
        pairingTriesLeft = max(pairingTriesLeft, OfficeLink.pairingTries * 2)
        let invitation = PrivateNetwork.Invitation(key: key, office: address, name: Host.current().localizedName ?? "Mac", code: code)
        guard let link = invitation.link else { throw OfficeLink.Failure.office(String(localized: "The invitation couldn’t be made.")) }
        return link
    }

    func remove(_ device: Device) {
        devices.removeAll { $0.id == device.id }
        saveDevices()
        lastSeen[device.id] = nil
        saveLastSeen()
    }

    private func saveLastSeen() {
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: lastSeen.map { ($0.key.uuidString, $0.value) }), forKey: Self.lastSeenKey)
    }

    /// This Mac's addresses a Mac at home can use (Tailscale's first, then the office network).
    static func addresses() -> [String] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        var found: [String] = []
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(item.pointee.ifa_flags)
            guard let addr = item.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            guard let ip = IPv4Address(address), OfficeLink.isPrivate(.ipv4(ip)), !address.hasPrefix("169.254") else { continue }
            found.append(address)
        }
        return found.sorted { $0.hasPrefix("100.") && !$1.hasPrefix("100.") }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        guard case .hostPort(let host, _) = connection.endpoint, OfficeLink.isPrivate(host), open < 16 else {
            connection.cancel()
            return
        }
        let client = "\(host)"
        if let record = strikes[client], record.count >= 10, Date.now.timeIntervalSince(record.since) < 600 {
            connection.cancel()
            return
        }
        open += 1
        connection.start(queue: queue)
        FrameReader.read(from: connection, limit: OfficeLink.maxRequest) { [weak self] frame in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                guard let frame else { return self.drop(connection, strike: client) }
                switch frame.kind {
                case .pair: self.pair(frame.payload, client: client, on: connection)
                case .request: self.request(frame.payload, client: client, on: connection)
                }
            }
        }
    }

    /// Closes without a word (a stranger learns nothing), counting it against the address.
    private func drop(_ connection: NWConnection, strike client: String?) {
        // Everything over the private network arrives from this Mac itself (the helper hands it
        // on): counting those would let one removed Mac lock everyone out. The keys guard it.
        if let client, client != "127.0.0.1", client != "::1" {
            let record = strikes[client]
            strikes[client] = record.map { Date.now.timeIntervalSince($0.since) < 600 ? ($0.count + 1, $0.since) : (1, .now) } ?? (1, .now)
        }
        close(connection)
    }

    private func close(_ connection: NWConnection) {
        open = max(open - 1, 0)
        connection.cancel()
    }

    private func send(_ data: Data, on connection: NWConnection) {
        open = max(open - 1, 0)
        connection.send(content: data, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func pair(_ payload: Data, client: String, on connection: NWConnection) {
        let codes = activeCodes
        guard !codes.isEmpty, pairingTriesLeft > 0, payload.count > 32,
              let clientKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: payload.prefix(32)),
              let box = try? ChaChaPoly.SealedBox(combined: payload.dropFirst(32)) else {
            return drop(connection, strike: client)
        }
        // Whichever open code it was sealed with.
        var opened: (code: String, plain: Data)?
        for code in codes {
            let key = OfficeLink.codeKey(code, clientKey: clientKey.rawRepresentation)
            if let plain = try? ChaChaPoly.open(box, using: key, authenticating: Data("pluck-pair".utf8)) { opened = (code, plain); break }
        }
        guard let opened, let hello = try? JSONSerialization.jsonObject(with: opened.plain) as? [String: Any],
              let time = hello["time"] as? Double, abs(Date.now.timeIntervalSince1970 - time) < OfficeLink.clockWindow else {
            // Too many wrong codes: every open code stops working.
            pairingTriesLeft -= 1
            if pairingTriesLeft <= 0 { self.pairing = nil; invitations.removeAll() }
            return drop(connection, strike: client)
        }
        let code = opened.code
        let name = String((hello["name"] as? String ?? "Mac").prefix(60))
        let officeKey = Curve25519.KeyAgreement.PrivateKey()
        guard let shared = try? officeKey.sharedSecretFromKeyAgreement(with: clientKey) else { return drop(connection, strike: nil) }
        let answerKey = OfficeLink.pairingAnswerKey(shared, code: code, clientKey: clientKey.rawRepresentation,
                                                   officeKey: officeKey.publicKey.rawRepresentation)
        let device = Device(id: UUID(), name: name, secret: OfficeLink.randomBytes(32), added: .now)
        // Its addresses on the office network (at home it goes over the private network).
        let answer: [String: Any] = ["device": device.id.uuidString, "secret": device.secret.base64EncodedString(),
                                     "office": Host.current().localizedName ?? "Mac", "addresses": Self.addresses()]
        guard let body = try? JSONSerialization.data(withJSONObject: answer),
              let sealed = try? ChaChaPoly.seal(body, using: answerKey, authenticating: Data("pluck-pair-answer".utf8)) else {
            return drop(connection, strike: nil)
        }
        // One code, one Mac.
        if self.pairing?.code == code { self.pairing = nil }
        invitations[code] = nil
        Task { await PrivateNetwork.Account.keepPluckMacsConnected() }
        devices.append(device)
        saveDevices()
        lastSeen[device.id] = .now
        saveLastSeen()
        justPaired = name
        send(OfficeLink.frame(.pair, officeKey.publicKey.rawRepresentation + sealed.combined), on: connection)
    }

    private func request(_ payload: Data, client: String, on connection: NWConnection) {
        guard payload.count > 16, let id = OfficeLink.uuid(payload.prefix(16)),
              let device = devices.first(where: { $0.id == id }) else { return drop(connection, strike: client) }
        let keys = OfficeLink.keys(device.secret)
        guard let box = try? ChaChaPoly.SealedBox(combined: payload.dropFirst(16)),
              let plain = try? ChaChaPoly.open(box, using: keys.request, authenticating: payload.prefix(16)),
              let message = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
              let time = message["time"] as? Double, abs(Date.now.timeIntervalSince1970 - time) < OfficeLink.clockWindow,
              let nonce = (message["nonce"] as? String).flatMap({ Data(base64Encoded: $0) }), nonce.count == 16,
              let action = message["action"] as? String else { return drop(connection, strike: client) }
        // Each message works once.
        nonces = nonces.filter { Date.now.timeIntervalSince($0.value) < OfficeLink.clockWindow * 2 + 10 }
        guard nonces[nonce] == nil else { return drop(connection, strike: client) }
        nonces[nonce] = .now
        strikes[client] = nil
        lastSeen[device.id] = .now
        saveLastSeen()
        let arguments = message["args"] as? [String: Any] ?? [:]
        Task {
            var answer: [String: Any]
            do {
                answer = try await perform(action, arguments, from: device)
            } catch {
                answer = ["error": error.localizedDescription]
            }
            answer["nonce"] = nonce.base64EncodedString()
            guard let body = try? JSONSerialization.data(withJSONObject: answer),
                  let sealed = try? ChaChaPoly.seal(body, using: keys.answer, authenticating: nonce) else { return close(connection) }
            send(OfficeLink.frame(.request, sealed.combined), on: connection)
        }
    }

    // MARK: - What a paired Mac can ask

    private func text(_ value: Any?, _ limit: Int = 300) throws -> String {
        guard let text = value as? String, !text.isEmpty, text.count <= limit else { throw OfficeLink.Failure.office(String(localized: "The request wasn’t complete.")) }
        return text
    }

    private func folder(_ value: Any?) throws -> [String] {
        guard let parts = value as? [String], parts.count <= 8, parts.allSatisfy({ $0.count <= 300 }) else {
            throw OfficeLink.Failure.office(String(localized: "The request wasn’t complete."))
        }
        return parts
    }

    private var busyMessage: String {
        String(localized: "The host Mac is rendering. Try again when it’s done.")
    }

    private var rendering: Job? { jobs.last { $0.state == .rendering } }

    private func perform(_ action: String, _ arguments: [String: Any], from device: Device) async throws -> [String: Any] {
        switch action {
        case "hello":
            var answer: [String: Any] = ["office": Host.current().localizedName ?? "Mac", "hasFolder": renderFolder != nil]
            if let hello = try? await OfficeResolve.run(["action": "hello"]) { answer["resolve"] = hello }
            return answer
        case "projects":
            if rendering != nil { throw OfficeLink.Failure.office(busyMessage) }
            let projects = try await OfficeResolve.projects()
            return ["projects": projects.map { ["folder": $0.folder, "name": $0.name] }]
        case "project":
            let name = try text(arguments["name"]), folder = try folder(arguments["folder"])
            if let busy = rendering, busy.project != name { throw OfficeLink.Failure.office(busyMessage) }
            return try await resolve(["action": "project", "folder": folder, "name": name])
        case "render":
            return try await render(arguments, from: device)
        case "jobs":
            return ["jobs": jobs.suffix(30).reversed().map(\.summary)]
        case "cancel":
            let id = try text(arguments["id"])
            guard let index = jobs.firstIndex(where: { $0.id.uuidString == id }) else { throw OfficeLink.Failure.office(String(localized: "That render isn’t on the host Mac any more.")) }
            if jobs[index].state == .rendering {
                _ = try? await OfficeResolve.run(["action": "stop", "name": jobs[index].project, "job": jobs[index].resolveJob])
                jobs[index].state = .cancelled
                jobs[index].problem = String(localized: "Cancelled from \(device.name)")
                saveJobs()
            }
            return ["cancelled": true]
        case "preview":
            let id = try text(arguments["id"])
            let offset = max(0, arguments["offset"] as? Int ?? 0)
            guard let job = jobs.first(where: { $0.id.uuidString == id }), let path = job.preview,
                  let handle = FileHandle(forReadingAtPath: path) else {
                throw OfficeLink.Failure.office(String(localized: "There’s no preview for that render (yet)."))
            }
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            let chunk = try handle.read(upToCount: OfficeLink.previewChunk) ?? Data()
            return ["data": chunk.base64EncodedString(), "size": job.previewSize ?? 0]
        case "archive":
            return ["archive": OfficeArchive.shared.status]
        case "archiveSearch":
            let query = (arguments["query"] as? String ?? "").prefix(200)
            let movement = (arguments["movement"] as? String).map { String($0.prefix(20)) }
            let framing = (arguments["framing"] as? String).map { String($0.prefix(20)) }
            // New footage becomes searchable by itself (a fresh look every few hours).
            OfficeArchive.shared.scanIfDue()
            return ["hits": OfficeArchive.shared.search(String(query), movement: movement, framing: framing)]
        case "archiveClip":
            let clip = try await OfficeArchive.shared.clip(try text(arguments["id"], 40))
            return ["token": clip.token, "size": clip.size, "name": clip.name]
        case "archiveClipData":
            let piece = try OfficeArchive.shared.clipData(try text(arguments["token"], 40), offset: arguments["offset"] as? Int ?? 0)
            return ["data": piece.data.base64EncodedString(), "size": piece.size]
        default:
            throw OfficeLink.Failure.office(String(localized: "The host Mac doesn’t know how to do that."))
        }
    }

    /// Resolve's answer, with "busy" put into words.
    private func resolve(_ instruction: [String: Any]) async throws -> [String: Any] {
        do {
            return try await OfficeResolve.run(instruction)
        } catch let failure as ResolveBridge.Failure where failure.message == "busy" {
            throw OfficeLink.Failure.office(busyMessage)
        }
    }

    private func render(_ arguments: [String: Any], from device: Device) async throws -> [String: Any] {
        let name = try text(arguments["name"]), folder = try folder(arguments["folder"])
        let timeline = try text(arguments["timeline"]), preset = try text(arguments["preset"])
        guard let root = renderFolder else {
            throw OfficeLink.Failure.office(String(localized: "No render folder is set on the host Mac yet. Choose one there in Edit Anywhere."))
        }
        if rendering != nil { throw OfficeLink.Failure.office(busyMessage) }
        // Always inside the render folder: a folder per project, a name from the timeline and the time.
        let target = root.appendingPathComponent(Folders.sanitize(name), isDirectory: true)
        let stamp = Date.now.formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits)",
                                                 timeZone: .current, calendar: .current))
        let output = Folders.sanitize(timeline) + " " + stamp
        let answer = try await resolve(["action": "render", "folder": folder, "name": name, "timeline": timeline,
                                        "preset": preset, "target": target.path, "output": output])
        guard let resolveJob = answer["job"] as? String else { throw OfficeLink.Failure.office(String(localized: "DaVinci Resolve couldn’t start rendering.")) }
        let job = Job(id: UUID(), resolveJob: resolveJob, folder: folder, project: name, timeline: timeline, preset: preset,
                      device: device.name, deviceID: device.id, started: .now)
        jobs.append(job)
        saveJobs()
        watch()
        return ["job": job.summary]
    }

    private func saveJobs() {
        try? FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Array(jobs.suffix(50))) { try? data.write(to: Self.jobsFile, options: .atomic) }
    }

    func clearFinished() {
        for job in jobs where job.state != .rendering {
            if let preview = job.preview { try? FileManager.default.removeItem(atPath: preview) }
        }
        jobs.removeAll { $0.state != .rendering }
        saveJobs()
    }

    // MARK: - Following renders

    /// Asks Resolve how renders are going every few seconds while there are any.
    private func watch() {
        guard watching == nil, jobs.contains(where: { $0.state == .rendering }) else { return }
        watching = Task {
            while !Task.isCancelled, let busy = jobs.last(where: { $0.state == .rendering }) {
                await check(busy.project)
                try? await Task.sleep(for: .seconds(3))
            }
            watching = nil
        }
    }

    private func check(_ project: String) async {
        let ids = jobs.filter { $0.state == .rendering && $0.project == project }.map(\.resolveJob)
        guard let answer = try? await OfficeResolve.run(["action": "status", "name": project, "jobs": ids]) else { return }
        let statuses = answer["status"] as? [String: [String: Any]] ?? [:]
        for index in jobs.indices where jobs[index].state == .rendering && jobs[index].project == project {
            // Resolve on another project, or the job gone from its queue: no way to follow it any more.
            guard answer["elsewhere"] == nil, let status = statuses[jobs[index].resolveJob], status["exists"] as? Bool == true else {
                jobs[index].state = .failed
                jobs[index].problem = String(localized: "The render was removed from DaVinci Resolve on the host Mac.")
                continue
            }
            jobs[index].progress = Double(status["CompletionPercentage"] as? Int ?? 0) / 100
            jobs[index].remaining = (status["EstimatedTimeRemainingInMs"] as? Double).map { $0 / 1000 }
            if let file = status["file"] as? String, !file.isEmpty { jobs[index].file = file }
            switch status["JobStatus"] as? String ?? "" {
            case "Complete":
                jobs[index].state = .done
                jobs[index].progress = 1
                jobs[index].remaining = nil
                makePreview(jobs[index].id)
            case "Failed":
                jobs[index].state = .failed
                jobs[index].problem = status["Error"] as? String ?? String(localized: "DaVinci Resolve couldn’t render it.")
            case "Cancelled", "Background Render Cancelled":
                jobs[index].state = .cancelled
            default:
                break
            }
        }
        saveJobs()
    }

    /// A small copy to send home: 540p H.264, about 1.5 Mbit/s, so it travels over the office's upload.
    private func makePreview(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), let file = jobs[index].file,
              FileManager.default.fileExists(atPath: file), let ffmpeg = manager?.tool("ffmpeg") else { return }
        jobs[index].making = true
        try? FileManager.default.createDirectory(at: Self.previews, withIntermediateDirectories: true)
        let target = Self.previews.appendingPathComponent(id.uuidString + ".mp4")
        Task {
            let ok = await Task.detached { () -> Bool in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ffmpeg)
                process.arguments = ["-nostdin", "-y", "-loglevel", "error", "-i", file, "-map", "0:v:0", "-map", "0:a:0?",
                                     "-vf", "scale=-2:'min(540,ih)'", "-c:v", "h264_videotoolbox", "-b:v", "1400k",
                                     "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart", target.path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return false }
                process.waitUntilExit()
                return process.terminationStatus == 0
            }.value
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            jobs[index].making = false
            if ok, let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value {
                jobs[index].preview = target.path
                jobs[index].previewSize = size
            }
            saveJobs()
        }
    }
}
