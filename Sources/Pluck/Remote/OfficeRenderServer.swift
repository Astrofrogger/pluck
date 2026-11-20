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
        /// nil (paired before rights existed): the defaults.
        var rights: Rights?
        /// Its iroh node id, when it paired through an iroh invitation: the key it gets in with.
        var iroh: String?
        /// Its tailnet address, when it paired over Tailscale: only these nodes keep their place there.
        var tailnet: String?
        /// The office group's own key (OfficeGroup): the other office Macs ask with it. Never listed as a paired Mac.
        var peer: Bool?
        /// Its other iroh node ids, one per office Mac of the group it reaches (each link has a key of its own).
        var irohMore: [String]?
        /// When its rights were last set, so the office Macs of a group keep the newest.
        var changed: Date?
        /// Its own public key (a home Mac's, registered once; another office Mac's, from the group): from then on only a
        /// question sealed with the secret this Mac and it work out from their keys gets in, never `secret`.
        var key: Data?
        /// Its role (OfficeAccess.Role raw value); nil: "Custom", its `rights` as they are.
        var role: String?
        /// The Deliver team person it belongs to (accounts id): that person's role counts for it.
        var person: String?

        /// What this Mac may do here (Edit Anywhere's remote editing).
        struct Rights: Codable, Hashable {
            var browse = true
            var proxies = true
            var originals = false
            var render = true
            /// Renders skip the check of what Fusion and grades reach (for the owner's own Macs).
            var fullTrust = false
        }

        var allowed: Rights { rights ?? Rights() }
        var isPeer: Bool { peer == true }
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
    /// Codes from Tailscale invitations (a day each), besides the one shown for pairing here.
    @ObservationIgnored private var invitations: [String: Date] = [:]
    /// Codes from iroh invitations (15 minutes each): each holds a pairing slot open in the helper.
    @ObservationIgnored private var irohInvitations: [String: Date] = [:]
    /// The private network's state on this Mac (see Tunnel), for the way chosen.
    var network: Tunnel { PrivateNetwork.transport == .iroh ? Tunnel.irohOffice : Tunnel.office }
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
    /// Wrong codes from each address, or iroh node id (one stranger can’t use up everyone’s tries).
    @ObservationIgnored private var pairingFails: [String: Int] = [:]
    /// Nonces seen in the last few minutes, against replays.
    @ObservationIgnored private var nonces: [Data: Date] = [:]
    /// Addresses that sent garbage, to shut out anyone probing.
    @ObservationIgnored private var strikes: [String: (count: Int, since: Date)] = [:]
    /// Connections still sending their request (a slow sender holds one), and ones being answered.
    @ObservationIgnored private var open = 0
    @ObservationIgnored private var answering = 0
    /// Connections kept open for a Mac's next question (it asked with "keep"), waiting for it. Each question on one is
    /// still sealed, timed and checked on its own; they all close when sharing stops.
    @ObservationIgnored private var kept: [ObjectIdentifier: NWConnection] = [:]
    static let keptMost = 64
    static let keptIdle: TimeInterval = 60
    /// (Tests: off answers like a host from before, one question per connection.)
    @ObservationIgnored var keepsConnections = true
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
        OfficeActions.registerAll()
        guard listener == nil else { return }
        problem = nil
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: OfficeLink.listenPort),
              let listener = try? NWListener(using: parameters, on: port) else {
            problem = String(localized: "Pluck couldn’t open port \(OfficeLink.listenPort) on this Mac.")
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
        OfficeGroup.shared.start()
        watch()
        startNetwork()
        OfficeArchive.removeOldClips()
        OfficeProxies.shared.manager = manager
        if ScreenshotMode.scene == nil {
            OfficeProxies.shared.run()
        }
    }

    func stop() {
        OfficeGroup.shared.stop()
        OfficeProxies.shared.stop()
        listener?.cancel()
        listener = nil
        kept.values.forEach { $0.cancel() }
        kept = [:]
        isRunning = false
        pairing = nil
        Tunnel.office.stop()
        Tunnel.irohOffice.stop()
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

    /// Snapshot scenes only: how sample Macs are connected (by device id).
    @ObservationIgnored private(set) var sampleLinks: [UUID: Tunnel.Link] = [:]

    /// Snapshot scenes only: these Macs and renders shown, nothing stored.
    func showSample(devices: [Device], lastSeen: [UUID: Date], links: [UUID: Tunnel.Link], jobs: [Job]) {
        guard ScreenshotMode.scene != nil else { return }
        loaded = true
        self.devices = devices
        self.lastSeen = lastSeen
        sampleLinks = links
        self.jobs = jobs
    }

    func setRenderFolder(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: Self.folderKey)
    }

    // MARK: - Pairing and paired Macs

    func startPairing() {
        pairing = (OfficeLink.newPairingCode(), Date.now.addingTimeInterval(OfficeLink.pairingLifetime))
        pairingTriesLeft = max(pairingTriesLeft, OfficeLink.pairingTries)
        pairingFails = [:]
        justPaired = nil
        let code = pairing?.code
        DispatchQueue.main.asyncAfter(deadline: .now() + OfficeLink.pairingLifetime + 0.5) { [weak self] in
            if self?.pairing?.code == code { self?.pairing = nil }
        }
    }

    func cancelPairing() { pairing = nil }

    /// (Self-test only) an open Tailscale-style invitation code, without the private network.
    func testInvitation() -> String {
        let code = OfficeLink.newPairingCode()
        invitations[code] = Date.now.addingTimeInterval(60)
        pairingTriesLeft = max(pairingTriesLeft, OfficeLink.pairingTries)
        return code
    }

    /// Pairing codes that work right now.
    private var activeCodes: [String] {
        invitations = invitations.filter { $0.value > .now }
        irohInvitations = irohInvitations.filter { $0.value > .now }
        var codes = Array(invitations.keys) + Array(irohInvitations.keys)
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
        if PrivateNetwork.transport == .iroh {
            guard PrivateNetwork.helper(.iroh) != nil else {
                networkProblem = PrivateNetwork.Failure.noHelper.localizedDescription
                return
            }
            networkProblem = nil
            let network = network
            network.setAllow(allowedNodes)
            Task {
                do {
                    try await network.start()
                    // A new helper knows no invitations: open again the ones still unused.
                    _ = activeCodes
                    for expires in irohInvitations.values { network.openPairing(expires.timeIntervalSinceNow) }
                } catch {
                    networkProblem = error.localizedDescription
                }
            }
            return
        }
        guard PrivateNetwork.helper != nil, network.hasJoined || PrivateNetwork.Account.token != nil else { return }
        networkProblem = nil
        Task {
            do {
                do {
                    try await network.start()
                } catch PrivateNetwork.Failure.needsInvite {
                    let key = try await PrivateNetwork.Account.joinKey(expiry: 3600, tag: PrivateNetwork.Account.officeTag)
                    // Disconnected while waiting for Tailscale: stay off.
                    guard PrivateNetwork.Account.token != nil else { return }
                    try await network.start(key: key)
                }
                await PrivateNetwork.Account.keepPluckMacsConnected(paired: pairedTailnet)
            } catch {
                networkProblem = error.localizedDescription
            }
        }
    }

    /// Takes this Mac off the private network, without needing the Tailscale account (a token
    /// that stopped working, or no internet): stops the connection and forgets the token and this
    /// Mac's identity there. Paired Macs on this network still work; ones from anywhere need a
    /// new invitation after connecting again. (The old entry can be removed in Tailscale's admin.)
    func disconnectNetwork() {
        network.stop()
        PrivateNetwork.Account.forget()
        networkProblem = nil
        if ScreenshotMode.scene == nil {
            try? FileManager.default.removeItem(at: PrivateNetwork.folder.appendingPathComponent("office", isDirectory: true))
        }
    }

    /// Switches the way in from anywhere (Macs invited the other way need a new invitation).
    func setTransport(_ transport: PrivateNetwork.Transport) {
        guard transport != PrivateNetwork.transport else { return }
        network.stop()
        PrivateNetwork.transport = transport
        networkProblem = nil
        if isRunning { startNetwork() }
    }

    /// Restarts the iroh link (after the relay setting changed).
    func restartNetwork() {
        guard PrivateNetwork.transport == .iroh, isRunning else { return }
        network.stop()
        startNetwork()
    }

    /// The node ids of the paired Macs that came in over iroh (and their links to the group's other office Macs).
    var allowedNodes: [String] { devices.flatMap { [$0.iroh].compactMap { $0 } + ($0.irohMore ?? []) } }

    /// The paired Macs people see (not the office group's own key).
    var pairedMacs: [Device] { devices.filter { !$0.isPeer } }

    /// The office group's devices and key (OfficeGroup), after a sync: paired Macs added, removed or with new rights, and
    /// the group's key as the one device the other office Macs ask with (nil: no group, its key goes).
    func adoptGroup(_ shared: OfficeGroup.Shared?) {
        loadDevices()
        var list = devices.filter { !$0.isPeer }
        if let shared {
            let gone = Set(shared.removedDevices)
            list.removeAll { gone.contains($0.id) }
            for device in shared.devices where !gone.contains(device.id) {
                if let index = list.firstIndex(where: { $0.id == device.id }) {
                    if (device.changed ?? .distantPast) > (list[index].changed ?? .distantPast) {
                        list[index].rights = device.rights
                        list[index].role = device.role
                        list[index].person = device.person
                        list[index].changed = device.changed
                    }
                    let more = Set((list[index].irohMore ?? []) + (device.irohMore ?? []))
                    list[index].irohMore = more.isEmpty ? nil : more.sorted()
                    list[index].key = OfficeGroup.firstKey(list[index].key, device.key)
                } else {
                    list.append(device)
                }
            }
            let me = OfficeGroup.shared.me, all = Device.Rights(browse: true, proxies: true, originals: true, render: true)
            // Each other office Mac by its own key: a removed one is no longer among them.
            for member in shared.members where member.id != me {
                guard let key = member.key else { continue }
                list.append(Device(id: member.id, name: member.name, secret: Data(SHA256.hash(data: key)), added: Date(timeIntervalSince1970: 0),
                                   rights: all, peer: true, key: key))
            }
            // The group's key only while an office Mac from before (no key of its own) is in it.
            if shared.members.contains(where: { $0.id != me && $0.key == nil }) {
                list.append(Device(id: shared.key.device, name: "Office group", secret: shared.key.secret, added: Date(timeIntervalSince1970: 0),
                                   rights: all, peer: true))
            }
        }
        guard list != devices else { return }
        devices = list
        saveDevices()
        Tunnel.irohOffice.setAllow(allowedNodes)
    }

    /// A paired Mac's link to another office Mac of the group (OfficeGroup's "groupNode").
    func addNode(_ node: String, for id: UUID) {
        guard let index = devices.firstIndex(where: { $0.id == id }), devices[index].iroh != node,
              !(devices[index].irohMore ?? []).contains(node) else { return }
        devices[index].irohMore = (devices[index].irohMore ?? []) + [node]
        saveDevices()
        Tunnel.irohOffice.setAllow(allowedNodes)
    }

    func connectAccount(token: String) {
        PrivateNetwork.Account.save(token: token)
        startNetwork()
    }

    /// A one-time invitation link for a Mac at home: it joins the private network and pairs with
    /// this Mac in one go. Works for an hour (Tailscale) or 15 minutes (iroh).
    func invite() async throws -> URL {
        guard case .running(_, let address) = network.state, !address.isEmpty else {
            throw OfficeLink.Failure.office(String(localized: "This Mac isn’t on the private network yet."))
        }
        if network.transport == .iroh {
            let lifetime = PrivateNetwork.invitationLifetime
            let code = OfficeLink.newPairingCode()
            irohInvitations[code] = Date.now.addingTimeInterval(lifetime)
            pairingFails = [:]
            pairingTriesLeft = max(pairingTriesLeft, OfficeLink.pairingTries * 2)
            // (Macs that came in on it but never paired are let go by the helper when it ends.)
            network.openPairing(lifetime)
            let invitation = PrivateNetwork.Invitation(way: .iroh(node: address, relay: network.relay, expires: Date.now.addingTimeInterval(lifetime)),
                                                       name: Host.current().localizedName ?? "Mac", code: code)
            guard let link = invitation.link else { throw OfficeLink.Failure.office(String(localized: "The invitation couldn’t be made.")) }
            return link
        }
        let lifetime = PrivateNetwork.tailscaleInvitationLifetime
        let key = try await PrivateNetwork.Account.joinKey(expiry: Int(lifetime), tag: PrivateNetwork.Account.inviteeTag)
        let code = OfficeLink.newPairingCode()
        invitations[code] = Date.now.addingTimeInterval(lifetime)
        pairingFails = [:]
        pairingTriesLeft = max(pairingTriesLeft, OfficeLink.pairingTries * 2)
        let invitation = PrivateNetwork.Invitation(way: .tailscale(key: key, address: address), name: Host.current().localizedName ?? "Mac", code: code)
        guard let link = invitation.link else { throw OfficeLink.Failure.office(String(localized: "The invitation couldn’t be made.")) }
        return link
    }

    /// The tailnet addresses of the Macs paired over Tailscale.
    private var pairedTailnet: Set<String> { Set(devices.compactMap(\.tailnet)) }

    func remove(_ device: Device) {
        devices.removeAll { $0.id == device.id }
        saveDevices()
        if !device.isPeer { OfficeGroup.shared.removed(device: device.id) }
        // Its tailnet node goes too (an invited node no longer paired is deleted there).
        if device.tailnet != nil, PrivateNetwork.Account.token != nil {
            Task { [paired = pairedTailnet, gone = Set(device.tailnet.map { [$0] } ?? [])] in
                await PrivateNetwork.Account.keepPluckMacsConnected(paired: paired, removed: gone)
            }
        }
        Tunnel.irohOffice.setAllow(allowedNodes)
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
        guard case .hostPort(let host, let port) = connection.endpoint, OfficeLink.isPrivate(host), open < 16, open + answering < 64 else {
            connection.cancel()
            return
        }
        let address = "\(host)"
        open += 1
        Task {
            // Over the private network (iroh or Tailscale) every Mac arrives from this Mac itself: which one it really
            // is, by the helper, so strikes, slots and wrong pairing codes count per Mac, not for all of them at once.
            let via = address == "127.0.0.1" || address == "::1" ? await network.peer(port: port.rawValue) : nil
            let iroh = PrivateNetwork.transport == .iroh ? via : nil
            let client = iroh.map { "iroh:" + $0 } ?? via ?? address
            if let record = strikes[client], record.count >= 10, Date.now.timeIntervalSince(record.since) < 600 { return refuse(connection) }
            // One Mac (or address) can't hold every slot with requests it never finishes. (Loopback the helper can't
            // name is this Mac itself: a test copy, the streaming drive's own parallel reads.)
            let local = client == "127.0.0.1" || client == "::1"
            guard local || openBy[client, default: 0] < Self.openPerClient else { return refuse(connection) }
            openBy[client, default: 0] += 1
            read(connection, client: client, iroh: iroh)
        }
    }

    static let openPerClient = 8
    @ObservationIgnored private var openBy: [String: Int] = [:]

    private func refuse(_ connection: NWConnection) {
        open = max(open - 1, 0)
        connection.cancel()
    }

    /// `again`: the next question on a connection kept open after an answer (not counted as a new one).
    private func read(_ connection: NWConnection, client: String, iroh: String?, again: Bool = false) {
        if !again { connection.start(queue: queue) }
        FrameReader.read(from: connection, limit: OfficeLink.maxRequest, timeout: again ? Self.keptIdle : 90) { [weak self] frame in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                if again {
                    // Closed by sharing stopping meanwhile: nothing more on it.
                    guard self.kept.removeValue(forKey: ObjectIdentifier(connection)) != nil else { return connection.cancel() }
                } else {
                    // The request is read: its slot is free for the next one while this one is answered.
                    self.open = max(self.open - 1, 0)
                    self.openBy[client] = self.openBy[client].map { $0 > 1 ? $0 - 1 : nil } ?? nil
                }
                self.answering += 1
                // A kept connection that goes quiet just closes (no strike: the Mac on it proved who it is).
                guard let frame else { return again ? self.close(connection) : self.drop(connection, strike: client) }
                switch frame.kind {
                case .pair where !again: self.pair(frame.payload, client: client, iroh: iroh, on: connection)
                case .request: self.request(frame.payload, client: client, iroh: iroh, on: connection)
                case .pair, .data: self.drop(connection, strike: client)
                }
            }
        }
    }

    /// Closes without a word (a stranger learns nothing), counting it against the address.
    private func drop(_ connection: NWConnection, strike client: String?) {
        // Loopback the helper couldn't name (a test copy, a local process) isn't counted: that would lock out every
        // Mac at once. Tunneled Macs are counted by who they are ("iroh:<node>", "ts:<tailnet address>").
        if let client, client != "127.0.0.1", client != "::1" {
            let record = strikes[client]
            strikes[client] = record.map { Date.now.timeIntervalSince($0.since) < 600 ? ($0.count + 1, $0.since) : (1, .now) } ?? (1, .now)
        }
        close(connection)
    }

    private func close(_ connection: NWConnection) {
        answering = max(answering - 1, 0)
        connection.cancel()
    }

    /// `keep`: the connection stays open for the asker's next question (read straight away: answers go out in order).
    private func send(_ data: Data, on connection: NWConnection, keep: (client: String, iroh: String?)? = nil) {
        answering = max(answering - 1, 0)
        guard let keep, listener != nil else {
            return connection.send(content: data, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
        }
        kept[ObjectIdentifier(connection)] = connection
        connection.send(content: data, completion: .contentProcessed { error in if error != nil { connection.cancel() } })
        read(connection, client: keep.client, iroh: keep.iroh, again: true)
    }

    /// `iroh`: the node id of the Mac it came from over iroh (the helper says), if it did.
    private func pair(_ payload: Data, client: String, iroh: String?, on connection: NWConnection) {
        let codes = activeCodes
        // (client is already the Mac's own identity over iroh or Tailscale.)
        let sender = client
        guard !codes.isEmpty, pairingFails[sender, default: 0] < pairingTriesLeft, payload.count > 32,
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
            // Too many wrong codes from one address: it can't try again (the 12-character codes stay open for the rest).
            pairingFails[sender, default: 0] += 1
            return drop(connection, strike: client)
        }
        let code = opened.code
        let name = String((hello["name"] as? String ?? "Mac").prefix(60))
        let officeKey = Curve25519.KeyAgreement.PrivateKey()
        guard let shared = try? officeKey.sharedSecretFromKeyAgreement(with: clientKey) else { return drop(connection, strike: nil) }
        let answerKey = OfficeLink.pairingAnswerKey(shared, code: code, clientKey: clientKey.rawRepresentation,
                                                   officeKey: officeKey.publicKey.rawRepresentation)
        // Another office Mac joining this one's group ("Add another office Mac"): it gets the group's key and state, sealed
        // like any pairing answer, and joins as a member instead of a paired Mac.
        if hello["role"] as? String == "peer" {
            // Only this Mac's own on-screen code over the office network: a home Mac's invitation code (Tailscale or iroh)
            // must never hand out the group's key and every paired Mac's secret.
            guard code == self.pairing?.code, iroh == nil, !client.hasPrefix("ts:") else { return drop(connection, strike: client) }
            guard let joining = (hello["member"] as? String).flatMap(OfficeGroup.decode(OfficeGroup.Member.self)),
                  let shared = OfficeGroup.shared.admit(joining),
                  let state = OfficeGroup.encode(shared) else { return drop(connection, strike: nil) }
            let answer: [String: Any] = ["device": shared.key.device.uuidString, "secret": shared.key.secret.base64EncodedString(),
                                         "office": Host.current().localizedName ?? "Mac", "addresses": Self.addresses(), "group": state]
            guard let body = try? JSONSerialization.data(withJSONObject: answer),
                  let sealed = try? ChaChaPoly.seal(body, using: answerKey, authenticating: Data("pluck-pair-answer".utf8)) else {
                return drop(connection, strike: nil)
            }
            if self.pairing?.code == code { self.pairing = nil }
            invitations[code] = nil
            irohInvitations[code] = nil
            justPaired = name
            return send(OfficeLink.frame(.pair, officeKey.publicKey.rawRepresentation + sealed.combined), on: connection)
        }
        var device = Device(id: UUID(), name: name, secret: OfficeLink.randomBytes(32), added: .now)
        // Paired over iroh: its node id (as the helper saw it, never just what it claims) is how it
        // gets in from now on. A claim that doesn't match where it came from is turned away.
        let claimed = hello["iroh"] as? String
        guard claimed == nil || claimed == iroh else { return drop(connection, strike: nil) }
        device.iroh = iroh
        // Its addresses on the office network (at home it goes over the private network).
        let answer: [String: Any] = ["device": device.id.uuidString, "secret": device.secret.base64EncodedString(),
                                     "office": Host.current().localizedName ?? "Mac", "addresses": Self.addresses(),
                                     "key": OfficeGroup.shared.publicKey.base64EncodedString()]
        guard let body = try? JSONSerialization.data(withJSONObject: answer),
              let sealed = try? ChaChaPoly.seal(body, using: answerKey, authenticating: Data("pluck-pair-answer".utf8)) else {
            return drop(connection, strike: nil)
        }
        // One code, one Mac.
        if self.pairing?.code == code { self.pairing = nil }
        invitations[code] = nil
        let viaIroh = irohInvitations.removeValue(forKey: code) != nil
        if client.hasPrefix("ts:") { device.tailnet = String(client.dropFirst(3)) }
        Task { [paired = pairedTailnet.union(device.tailnet.map { [$0] } ?? [])] in await PrivateNetwork.Account.keepPluckMacsConnected(paired: paired) }
        devices.append(device)
        saveDevices()
        if let node = device.iroh {
            // Uses up one of the helper's pairing slots only when an iroh invitation's code was used.
            if viaIroh { Tunnel.irohOffice.paired(node) }
            Tunnel.irohOffice.setAllow(allowedNodes)
        }
        lastSeen[device.id] = .now
        saveLastSeen()
        justPaired = name
        send(OfficeLink.frame(.pair, officeKey.publicKey.rawRepresentation + sealed.combined), on: connection)
    }

    private func request(_ payload: Data, client: String, iroh: String?, on connection: NWConnection) {
        guard payload.count > 16, let id = OfficeLink.uuid(payload.prefix(16)),
              let index = devices.firstIndex(where: { $0.id == id }) else { return drop(connection, strike: client) }
        var device = devices[index]
        // A Mac with a key of its own: only the secret the two keys give (what another office Mac knew is no use).
        let secret: Data? = if let key = device.key { OfficeGroup.shared.link(with: key) } else { device.secret }
        guard let secret else { return drop(connection, strike: client) }
        let keys = OfficeLink.keys(secret)
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
        // A home Mac's own key, sent sealed with its pairing secret: registered once (the group gets it at the next sync).
        var registered = false
        if device.key == nil, !device.isPeer, let typed = (message["identity"] as? String).flatMap({ Data(base64Encoded: $0) }),
           OfficeGroup.shared.link(with: typed) != nil {
            device.key = typed
            devices[index] = device
            saveDevices()
            registered = true
        }
        lastSeen[device.id] = .now
        saveLastSeen()
        let arguments = message["args"] as? [String: Any] ?? [:]
        // Asked to keep the connection (a Mac from before never does): the answer says it's kept.
        let keep = message["keep"] as? Bool == true && keepsConnections
        Task {
            var answer: [String: Any]
            do {
                answer = try await perform(action, arguments, from: device)
            } catch {
                answer = ["error": error.localizedDescription]
            }
            answer["nonce"] = nonce.base64EncodedString()
            if registered { answer["identity"] = true }
            let keeping = keep && kept.count < Self.keptMost && listener != nil
            if keeping { answer["keep"] = true }
            let bytes = answer.removeValue(forKey: OfficeActions.bytesKey) as? Data
            guard let body = try? JSONSerialization.data(withJSONObject: answer) else { return close(connection) }
            // (Sealing a file piece is off the main thread.)
            guard let frame = await Task.detached(operation: { OfficeActions.seal(body, bytes: bytes, key: keys.answer, nonce: nonce) }).value else {
                return close(connection)
            }
            send(frame, on: connection, keep: keeping ? (client, iroh) : nil)
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

    private func number(_ value: Any?) throws -> Int64 {
        guard let number = (value as? NSNumber)?.int64Value, number >= 0 else {
            throw OfficeLink.Failure.office(String(localized: "The request wasn’t complete."))
        }
        return number
    }

    private func proxyFormat(_ value: Any?) throws -> OfficeProxies.Format {
        guard let raw = value as? String, let format = OfficeProxies.Format(rawValue: raw) else {
            throw OfficeLink.Failure.office(String(localized: "The request wasn’t complete."))
        }
        return format
    }

    private var busyMessage: String {
        String(localized: "The host Mac is rendering. Try again when it’s done.")
    }

    private var rendering: Job? { jobs.last { $0.state == .rendering } }
    var isRendering: Bool { rendering != nil }

    /// Sets what a paired Mac may do here, kept with its pairing.
    /// Its own flags ("Custom": no role from now on).
    func setRights(_ rights: Device.Rights, for id: UUID) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].rights = rights
        devices[index].role = nil
        devices[index].changed = .now
        saveDevices()
        OfficeAccess.shared.changed()
    }

    /// Gives a paired Mac a role. Its flags become the role's too, so an office Mac from before roles enforces it
    /// (only folder roles are missing there). Full Trust stays as it was.
    func setRole(_ role: OfficeAccess.Role, for id: UUID) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        var rights = role.rights
        rights.fullTrust = devices[index].allowed.fullTrust
        devices[index].rights = rights
        devices[index].role = role.rawValue
        devices[index].changed = .now
        saveDevices()
        OfficeAccess.shared.changed()
    }

    /// Full Trust on or off (the role stays).
    func setFullTrust(_ on: Bool, for id: UUID) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        var rights = devices[index].allowed
        rights.fullTrust = on
        devices[index].rights = rights
        devices[index].changed = .now
        saveDevices()
        OfficeAccess.shared.changed()
    }

    /// Ties a paired Mac to a Deliver team person (nil: to no one).
    func setPerson(_ person: String?, for id: UUID) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].person = person
        devices[index].changed = .now
        saveDevices()
        OfficeAccess.shared.changed()
    }

    /// The actions `perform` answers itself (the others are OfficeActions handlers).
    static let builtInActions = ["hello", "projects", "project", "render", "jobs", "cancel", "preview", "archive", "archiveSearch", "archiveClip",
                                 "archiveClipData", "sendState", "send", "proxyFolders", "proxyMake", "proxyStatus", "proxyData"]

    private func perform(_ action: String, _ arguments: [String: Any], from device: Device) async throws -> [String: Any] {
        switch action {
        case "hello":
            var answer: [String: Any] = ["office": Host.current().localizedName ?? "Mac", "hasFolder": renderFolder != nil,
                                         "group": OfficeGroup.shared.members.count]
            if let hello = try? await OfficeResolve.run(["action": "hello"]) { answer["resolve"] = hello }
            return answer
        case "projects":
            try OfficeActions.require(\.render, device)
            if rendering != nil { throw OfficeLink.Failure.office(busyMessage) }
            let projects = try await OfficeResolve.projects()
            return ["projects": projects.map { ["folder": $0.folder, "name": $0.name] }]
        case "project":
            try OfficeActions.require(\.render, device)
            let name = try text(arguments["name"]), folder = try folder(arguments["folder"])
            if let busy = rendering, busy.project != name { throw OfficeLink.Failure.office(busyMessage) }
            return try await resolve(["action": "project", "folder": folder, "name": name])
        case "render":
            try OfficeActions.require(\.render, device)
            return try await render(arguments, from: device)
        case "jobs":
            // (Each Mac sees and handles only its own renders.)
            return ["jobs": jobs.filter { $0.deviceID == device.id }.suffix(30).reversed().map(\.summary)]
        case "cancel":
            let id = try text(arguments["id"])
            guard let job = jobs.first(where: { $0.id.uuidString == id && $0.deviceID == device.id }) else { throw OfficeLink.Failure.office(String(localized: "That render isn’t on the host Mac any more.")) }
            await cancel(job.id, by: device.name)
            return ["cancelled": true]
        case "preview":
            let id = try text(arguments["id"])
            let offset = max(0, arguments["offset"] as? Int ?? 0)
            guard let job = jobs.first(where: { $0.id.uuidString == id && $0.deviceID == device.id }), let path = job.preview,
                  let handle = FileHandle(forReadingAtPath: path) else {
                throw OfficeLink.Failure.office(String(localized: "There’s no preview for that render (yet)."))
            }
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            let chunk = try handle.read(upToCount: OfficeLink.previewChunk) ?? Data()
            return ["data": chunk.base64EncodedString(), "size": job.previewSize ?? 0]
        case "archive", "archiveSearch", "archiveClip", "archiveClipData":
            // Edit Anywhere no longer looks at or searches footage: an older Mac asking is told so.
            throw OfficeLink.Failure.office(String(localized: "The host Mac doesn’t search footage any more. Update Pluck on this Mac."))
        case "sendState":
            try OfficeActions.require(\.render, device, refusal: OfficeActions.sendRefusal)
            let have = try OfficeInbox.shared.have(try text(arguments["path"], 1000), size: try number(arguments["size"]),
                                                   modified: arguments["modified"] as? Double ?? 0,
                                                   from: OfficeInbox.folderName(device.name, id: device.id))
            return ["have": have]
        case "send":
            try OfficeActions.require(\.render, device, refusal: OfficeActions.sendRefusal)
            guard let data = (arguments["data"] as? String).flatMap({ Data(base64Encoded: $0) }), data.count <= OfficeLink.uploadChunk else {
                throw OfficeLink.Failure.office(String(localized: "The request wasn’t complete."))
            }
            let have = try OfficeInbox.shared.receive(try text(arguments["path"], 1000), size: try number(arguments["size"]),
                                                      modified: arguments["modified"] as? Double ?? 0,
                                                      offset: try number(arguments["offset"]), data: data,
                                                      from: OfficeInbox.folderName(device.name, id: device.id), sender: device.name)
            return ["have": have]
        case "proxyFolders":
            try OfficeActions.require(\.proxies, device)
            return ["folders": await OfficeProxies.shared.sharedFolders()]
        case "proxyMake":
            try OfficeActions.require(\.proxies, device)
            try OfficeProxies.shared.make(try text(arguments["folder"], 40), format: try proxyFormat(arguments["format"]))
            return ["started": true]
        case "proxyStatus":
            try OfficeActions.require(\.proxies, device)
            var status = try await OfficeProxies.shared.status(try text(arguments["folder"], 40), format: try proxyFormat(arguments["format"]))
            // (An older home Mac's folder list: clips in folders it may not have proxies of left out.)
            if let place = try? RemoteEditHost.share(arguments["folder"]), let files = status["files"] as? [[String: Any]] {
                status["files"] = files.filter { OfficeActions.allowed(\.proxies, device, share: place, relative: $0["path"] as? String ?? "") }
            }
            return status
        case "proxyData":
            let right: KeyPath<Device.Rights, Bool> = try proxyFormat(arguments["format"]) == .original ? \.originals : \.proxies
            try OfficeActions.require(right, device)
            guard OfficeActions.allowed(right, device, share: try RemoteEditHost.share(arguments["folder"]), relative: try text(arguments["path"], 1000)) else {
                throw OfficeActions.refused()
            }
            let piece = try await OfficeProxies.shared.data(try text(arguments["folder"], 40), format: try proxyFormat(arguments["format"]),
                                                            path: try text(arguments["path"], 1000), offset: arguments["offset"] as? Int ?? 0)
            return ["data": piece.data.base64EncodedString(), "size": piece.size]
        default:
            // Actions added in their own files (see OfficeActions).
            guard let handler = OfficeActions.handler(action) else {
                throw OfficeLink.Failure.office(String(localized: "The host Mac doesn’t know how to do that."))
            }
            return try await handler(arguments, device)
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
        if rendering != nil || RemoteRenderQueue.shared.isBusy { throw OfficeLink.Failure.office(busyMessage) }
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

    /// Stops a render (from this Mac when `name` is nil, else from that paired Mac).
    func cancel(_ id: UUID, by name: String? = nil) async {
        guard let job = jobs.first(where: { $0.id == id }), job.state == .rendering else { return }
        _ = try? await OfficeResolve.run(["action": "stop", "name": job.project, "job": job.resolveJob])
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = .cancelled
        jobs[index].problem = name.map { String(localized: "Cancelled from \($0)") } ?? String(localized: "Stopped on this Mac")
        saveJobs()
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

extension OfficeRenderServer.Device.Rights {
    /// Rights saved before one existed take its default (a missing key must not drop the pairing).
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self), base = Self()
        browse = try values.decodeIfPresent(Bool.self, forKey: .browse) ?? base.browse
        proxies = try values.decodeIfPresent(Bool.self, forKey: .proxies) ?? base.proxies
        originals = try values.decodeIfPresent(Bool.self, forKey: .originals) ?? base.originals
        render = try values.decodeIfPresent(Bool.self, forKey: .render) ?? base.render
        fullTrust = try values.decodeIfPresent(Bool.self, forKey: .fullTrust) ?? base.fullTrust
    }
}
