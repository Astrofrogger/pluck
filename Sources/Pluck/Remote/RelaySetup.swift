import Darwin
import Foundation

/// The office's own relay (Helpers/PluckRelay: iroh-relay at PluckIroh's iroh version) on a TrueNAS (an app made
/// through its API, like the review host) or on Proxmox (a `docker run` to paste). Only the paired Macs and the office
/// group's Macs may use it (an allowlist of node ids, pushed again to TrueNAS when it changes; Proxmox shows the
/// command again). Pluck never changes router or NAS network settings, and the relay never calls into the LAN.
@MainActor
enum RelaySetup {
    static let appName = "pluck-relay", setupKey = "editAnywhereRelaySetup", dnsService = "tools.pluck.relay.dns"
    /// shortcut: the DNS sidecar only speaks Cloudflare, add providers when an owner needs one.
    static let legoImage = "docker.io/goacme/lego:v4.25.2"

    enum Kind: String, Codable { case truenas, proxmox }
    enum Certificate: String, Codable { case automatic = "acme", dns = "files" }

    /// What was set up, kept so allowlist changes can be pushed (the TrueNAS key and DNS token stay in the Keychain).
    struct Setup: Codable, Equatable {
        var kind: Kind
        var address = ""
        var hostname: String
        var contact: String
        var certificate = Certificate.automatic
        var pushed: [String] = []
        var url: String { "https://" + hostname }
    }

    static var saved: Setup? {
        get { UserDefaults.standard.data(forKey: setupKey).flatMap { try? JSONDecoder().decode(Setup.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: setupKey) }
    }

    /// The relay image of this Pluck's release (signed host-release.json); nil until one with a relay is published.
    static var image: String? { DeliverHostUpdate.shared.release?.relayImage }

    /// Who may use the relay: the paired Macs, the office group's Macs and this Mac itself.
    static func allowlist() -> [String] {
        var ids = OfficeRenderServer.shared.allowedNodes + OfficeGroup.shared.members.compactMap(\.iroh)
        if case .running(_, let own) = Tunnel.irohOffice.state { ids.append(own) }
        return Array(Set(ids.map { $0.lowercased() }.filter(PrivateNetwork.isNodeID))).sorted()
    }

    // MARK: - The files

    nonisolated static func isHostname(_ text: String) -> Bool {
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && text.count <= 253 && labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    nonisolated static func isEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && isHostname(String(parts[1])) && !text.contains { "\"\\ '".contains($0) }
    }

    /// The TrueNAS compose (Helpers/PluckRelay/docker/truenas-compose.yml filled in).
    nonisolated static func compose(_ template: String, image: String, setup: Setup, allow: [String], dnsToken: String?) throws -> String {
        guard image.contains("@sha256:"), isHostname(setup.hostname), isEmail(setup.contact), !allow.isEmpty,
              allow.allSatisfy(PrivateNetwork.isNodeID) else { throw TrueNASClient.Failure(message: String(localized: "The relay’s settings aren’t complete.")) }
        var values = ["image": image, "hostname": setup.hostname.lowercased(), "allow": allow.joined(separator: ","), "tls": setup.certificate.rawValue,
                      "contact": setup.contact, "mem": "256m", "cpus": "1"]
        var blocks: Set<String> = []
        if setup.certificate == .dns {
            guard let dnsToken, !dnsToken.isEmpty else { throw TrueNASClient.Failure(message: String(localized: "Paste the DNS token first.")) }
            values["dns_token"] = dnsToken
            values["lego_image"] = legoImage
            blocks.insert("dns")
        }
        return try TrueNASClient.render(template, values, blocks: blocks)
    }

    /// The single-quoted shell form of a value.
    nonisolated static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Proxmox (a Docker-capable LXC or VM there): the same container with the same hardening, as one command. Run again
    /// with a new allowlist, it replaces the container (the certificates' volume stays).
    /// shortcut: automatic certificates only on Proxmox (DNS-challenge needs the sidecar), add it when asked for.
    nonisolated static func proxmoxCommand(image: String, setup: Setup, allow: [String]) -> String {
        "docker rm -f pluck-relay 2>/dev/null; docker run -d --name pluck-relay --restart unless-stopped --user 568:568 --read-only "
            + "--cap-drop ALL --security-opt no-new-privileges:true --tmpfs /tmp:size=8m --pids-limit 128 --memory 256m --cpus 1 "
            + "-p 443:8443/tcp -p 7842:7842/udp -v pluck-relay-certs:/certs "
            + "-e PLUCK_RELAY_HOSTNAME=\(quoted(setup.hostname.lowercased())) -e PLUCK_RELAY_CONTACT=\(quoted(setup.contact)) "
            + "-e PLUCK_RELAY_ALLOW=\(quoted(allow.joined(separator: ","))) -e PLUCK_RELAY_TLS=acme \(quoted(image))"
    }

    static var template: String? {
        Bundle.main.url(forResource: "relay-compose", withExtension: "yml").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    // MARK: - TrueNAS

    /// Makes (or updates) the relay app on the NAS with the current allowlist. `key`: pasted now (kept in the Keychain)
    /// or nil for the one kept. Throws TrueNASClient.Unconfirmed when the NAS's certificate wasn't confirmed yet.
    static func deploy(_ setup: Setup, key: String?, dnsToken: String?) async throws {
        guard let image else { throw TrueNASClient.Failure(message: String(localized: "This Pluck version has no relay image yet.")) }
        guard let template else { throw TrueNASClient.Failure(message: String(localized: "This build of Pluck has no relay template.")) }
        guard let key = key ?? TrueNASKeychain.load(setup.address) else { throw TrueNASClient.Failure(message: String(localized: "Paste the NAS’s API key.")) }
        if let dnsToken, !dnsToken.isEmpty { DeliverKeychain.save(Data(dnsToken.utf8), as: setup.hostname, service: dnsService) }
        let token = DeliverKeychain.load(setup.hostname, service: dnsService).map { String(decoding: $0, as: UTF8.self) }
        let allow = allowlist()
        let compose = try compose(template, image: image, setup: setup, allow: allow, dnsToken: token)
        let client = TrueNASClient(address: setup.address, pin: TrueNASKeychain.pin(setup.address))
        client.appName = appName
        try await client.connect()
        defer { client.close() }
        try await client.login(key)
        _ = try await client.checkVersion()
        try await client.deploy(compose)
        TrueNASKeychain.save(key, for: setup.address)
        var done = setup
        done.pushed = allow
        saved = done
    }

    @ObservationIgnored private static var pushing: Task<Void, Never>?

    /// The office's allowlist changed (Tunnel.setAllow): a TrueNAS relay gets it a little later (several changes, one push).
    static func allowChanged() {
        guard ScreenshotMode.scene == nil, let setup = saved, setup.kind == .truenas, TrueNASKeychain.load(setup.address) != nil else { return }
        pushing?.cancel()
        pushing = Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let setup = saved, allowlist() != setup.pushed else { return }
            try? await deploy(setup, key: nil, dnsToken: nil)
        }
    }

    // MARK: - Test relay

    /// Mbit/s from a helper here to another helper here through the relay only (both with throwaway keys, no direct path).
    static func measure(_ relay: String, bytes: Int = 16 << 20) async throws -> Double {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-relay-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sink = try Sink()
        defer { sink.close() }
        let office = Tunnel(.office, .iroh), home = Tunnel(.home, .iroh)
        defer { office.stop(); home.stop() }
        office.testSettings = ["keyFile": folder.appendingPathComponent("o.key").path, "port": Int(sink.port), "relay": relay, "relayOnly": true]
        home.testSettings = ["keyFile": folder.appendingPathComponent("h.key").path, "relay": relay, "relayOnly": true]
        office.setAllow([])
        try await office.start()
        guard case .running(_, let officeNode) = office.state else { throw PrivateNetwork.Failure.timeout }
        try await home.start(office: officeNode, officeRelay: relay)
        guard case .running(_, let homeNode) = home.state, let listen = home.listen else { throw PrivateNetwork.Failure.timeout }
        office.setAllow([homeNode])
        let started = Date.now
        try await Task.detached { try Sink.send(bytes, to: listen) }.value
        let received = await sink.wait(for: bytes, timeout: 60)
        let seconds = max(Date.now.timeIntervalSince(started), 0.001)
        guard received > 0 else { throw OfficeLink.Failure.office(String(localized: "Nothing came through the relay.")) }
        return Double(received) * 8 / seconds / 1_000_000
    }

    /// A local TCP port that counts what arrives (the office helper's stream target in the test).
    final class Sink: @unchecked Sendable {
        let port: UInt16
        private let socket: Int32
        private let lock = NSLock()
        private var count = 0

        init() throws {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
                                      sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && listen(fd, 4) == 0 && getsockname(fd, $0, &length) == 0 }
            }
            guard fd >= 0, bound else { Darwin.close(fd); throw PrivateNetwork.Failure.timeout }
            socket = fd
            port = UInt16(bigEndian: address.sin_port)
            let listener = socket
            Thread.detachNewThread { [weak self] in
                while true {
                    let client = accept(listener, nil, nil)
                    guard client >= 0 else { return }
                    Thread.detachNewThread {
                        var buffer = [UInt8](repeating: 0, count: 1 << 16)
                        while true {
                            let n = read(client, &buffer, buffer.count)
                            if n <= 0 { break }
                            self?.add(n)
                        }
                        Darwin.close(client)
                    }
                }
            }
        }

        private func add(_ n: Int) { lock.lock(); count += n; lock.unlock() }
        var received: Int { lock.lock(); defer { lock.unlock() }; return count }

        func wait(for bytes: Int, timeout: TimeInterval) async -> Int {
            let end = Date.now.addingTimeInterval(timeout)
            while received < bytes, Date.now < end { try? await Task.sleep(for: .milliseconds(50)) }
            return received
        }

        func close() { Darwin.close(socket) }

        /// Writes `bytes` to "127.0.0.1:port" and closes.
        static func send(_ bytes: Int, to address: String) throws {
            guard let port = address.split(separator: ":").last.flatMap({ UInt16($0) }) else { throw PrivateNetwork.Failure.timeout }
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            defer { Darwin.close(fd) }
            var target = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: port.bigEndian,
                                     sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
            let connected = withUnsafePointer(to: &target) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
            guard connected else { throw PrivateNetwork.Failure.timeout }
            let chunk = [UInt8](repeating: 0x5A, count: 1 << 16)
            var left = bytes
            while left > 0 {
                let n = chunk.withUnsafeBytes { write(fd, $0.baseAddress, min(left, chunk.count)) }
                guard n > 0 else { throw PrivateNetwork.Failure.timeout }
                left -= n
            }
        }
    }
}
