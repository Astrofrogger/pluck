import Foundation
import Network

/// The phone page (Task 6): it serves the status with the secret, refuses everything else, only
/// answers private addresses, can't be written to and stops when turned off. Requests go to this
/// Mac (127.0.0.1) over a plain connection.
extension EditSelfTest {
    static func offloadPhone() async {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-offload-phone-\(UUID().uuidString)", isDirectory: true)
        let before = Set(OffloadCenter.shared.jobs.map(\.id))
        let phone = OffloadPhone.shared
        let wasOn = phone.on

        // A small finished offload, so there's a job to list.
        let card = base.appendingPathComponent("Card", isDirectory: true), drive = base.appendingPathComponent("Drive", isDirectory: true)
        try? FileManager.default.createDirectory(at: card.appendingPathComponent("DCIM"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        try? Data(repeating: 7, count: 64 * 1024).write(to: card.appendingPathComponent("DCIM/C0001.MP4"))
        let name = "Self Test Phone \(UUID().uuidString.prefix(6))"
        let problem = await OffloadCenter.shared.add(source: card, roots: [drive], name: name)
        var finished = false
        for _ in 0..<300 {
            if let job = OffloadCenter.shared.jobs.first(where: { $0.name == name }), OffloadCenter.shared.state(job) == .done { finished = true; break }
            try? await Task.sleep(for: .milliseconds(100))
        }

        phone.on = false
        phone.on = true
        let port = await phonePort()
        let path = phone.path ?? "/"

        // Serves the status (and the page, with nothing from elsewhere).
        if let port {
            let status = await phoneRequest(port, "GET \(path)status.json HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
            let decoded = status.flatMap { try? JSONDecoder().decode(OffloadPhone.Status.self, from: $0.body) }
            let listed = decoded?.jobs.first { $0.name == name }
            let page = await phoneRequest(port, "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
            let html = page.map { String(decoding: $0.body, as: UTF8.self) } ?? ""
            check("phone page serves status",
                  problem == nil && finished && status?.status == 200 && listed != nil && listed?.finished == true
                      && listed.map { near($0.progress, 1) } == true && page?.status == 200
                      && html.contains("status.json") && !html.contains("://") && !html.contains("{{"),
                  "problem \(problem ?? "none"), finished \(finished), status \(status?.status ?? -1), listed \(listed != nil), progress \(listed?.progress ?? -1), page \(page?.status ?? -1)")
        } else {
            check("phone page serves status", false, "it didn't start listening: \(phone.problem ?? "no port")")
        }

        // Needs the secret: a wrong one, a near miss, none at all, and the old one after a new link.
        if let port {
            let secret = String(path.dropFirst().dropLast())
            let wrong = await phoneRequest(port, "GET /\(OffloadPhone.newToken())/status.json HTTP/1.1\r\n\r\n")
            let nearMiss = await phoneRequest(port, "GET /\(secret.dropLast())x/status.json HTTP/1.1\r\n\r\n")
            let root = await phoneRequest(port, "GET / HTTP/1.1\r\n\r\n")
            let other = await phoneRequest(port, "GET \(path)secret.txt HTTP/1.1\r\n\r\n")
            phone.on = false
            phone.on = true
            let newPort = await phonePort()
            let old = await newPort.asyncMap { await phoneRequest($0, "GET /\(secret)/status.json HTTP/1.1\r\n\r\n") } ?? nil
            func refused(_ answer: PhoneAnswer?, _ codes: Set<Int>) -> Bool { answer.map { codes.contains($0.status) } ?? true }
            check("phone page needs the token",
                  refused(wrong, [403]) && refused(nearMiss, [403]) && refused(root, [403, 404]) && refused(other, [404])
                      && refused(old, [403]) && phone.path != path && secret.count == 43,
                  "wrong \(wrong?.status ?? -1), near \(nearMiss?.status ?? -1), root \(root?.status ?? -1), other \(other?.status ?? -1), old \(old?.status ?? -1)")
        } else {
            check("phone page needs the token", false, "not listening")
        }

        // Private addresses only (Edit Anywhere's rule, which keeps Tailscale's 100.64.0.0/10).
        func allows(_ text: String) -> Bool {
            if let v4 = IPv4Address(text) { return OffloadPhone.allows(.ipv4(v4)) }
            if let v6 = IPv6Address(text) { return OffloadPhone.allows(.ipv6(v6)) }
            return OffloadPhone.allows(.name(text, nil))
        }
        let accepted = ["192.168.1.5", "10.0.0.2", "172.16.3.4", "127.0.0.1", "100.64.0.1", "::1", "fd00::1", "::ffff:192.168.1.5"]
        let refusedPeers = ["8.8.8.8", "172.32.0.1", "1.1.1.1", "100.128.0.1", "2001:4860:4860::8888", "::ffff:8.8.8.8", "example.com"]
        check("phone page refuses public peers",
              accepted.allSatisfy(allows) && !refusedPeers.contains(where: allows),
              "accepted wrongly \(refusedPeers.filter(allows)), refused wrongly \(accepted.filter { !allows($0) })")

        // Read only: anything but GET is refused, even with the secret.
        if let port = phone.port, let path = phone.path {
            var codes: [String: Int] = [:]
            for method in ["POST", "PUT", "DELETE", "PATCH", "HEAD"] {
                let answer = await phoneRequest(port, "\(method) \(path)status.json HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}")
                codes[method] = answer?.status ?? -1
            }
            check("phone page is read only", codes.values.allSatisfy { $0 == 405 || $0 == 403 || $0 == -1 } && codes["POST"] == 405,
                  "\(codes)")
            // Too big a request is hung up on, unanswered.
            let big = await phoneRequest(port, "GET \(path) HTTP/1.1\r\nX-Pad: \(String(repeating: "a", count: 9 * 1024))\r\n\r\n")
            check("phone page drops oversized requests", big == nil || big?.status == 0, "status \(big?.status ?? -1)")
        } else {
            check("phone page is read only", false, "not listening")
            check("phone page drops oversized requests", false, "not listening")
        }

        // Turned off: nothing listens on that port any more.
        let lastPort = phone.port
        phone.on = false
        try? await Task.sleep(for: .milliseconds(300))
        let stillThere = await lastPort.asyncMap { await phoneConnects($0) } ?? true
        check("phone page stops", lastPort != nil && !stillThere && phone.link == nil && phone.path == nil && !phone.on,
              "port \(lastPort.map(String.init) ?? "none"), still answers \(stillThere)")

        phone.on = wasOn
        for job in OffloadCenter.shared.jobs where !before.contains(job.id) { OffloadCenter.shared.remove(job.id) }
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - A plain HTTP client

    struct PhoneAnswer: Sendable {
        /// 0: something came back that isn't HTTP.
        var status: Int
        var body: Data
    }

    /// The port, once the page listens (nil after 5 s).
    private static func phonePort() async -> UInt16? {
        for _ in 0..<50 {
            if let port = OffloadPhone.shared.port { return port }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// One request to this Mac; nil when the connection was refused or closed without an answer.
    nonisolated private static func phoneRequest(_ port: UInt16, _ text: String) async -> PhoneAnswer? {
        await withCheckedContinuation { continuation in
            let once = OnceFlag()
            guard let target = NWEndpoint.Port(rawValue: port) else { return continuation.resume(returning: nil) }
            let connection = NWConnection(host: "127.0.0.1", port: target, using: .tcp)
            let finish: @Sendable (PhoneAnswer?) -> Void = { answer in
                if once.claim() { continuation.resume(returning: answer) }
                connection.cancel()
            }
            connection.stateUpdateHandler = { @Sendable state in
                switch state {
                case .ready:
                    connection.send(content: Data(text.utf8), completion: .contentProcessed { @Sendable _ in })
                    phoneCollect(connection, Data(), finish)
                case .failed, .waiting:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { finish(nil) }
        }
    }

    nonisolated private static func phoneCollect(_ connection: NWConnection, _ buffer: Data, _ finish: @escaping @Sendable (PhoneAnswer?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { @Sendable data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            guard complete || error != nil else { return phoneCollect(connection, buffer, finish) }
            guard !buffer.isEmpty else { return finish(nil) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return finish(PhoneAnswer(status: 0, body: buffer)) }
            let line = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).split(separator: " ")
            let status = line.count > 1 && line[0].hasPrefix("HTTP/") ? Int(line[1]) ?? 0 : 0
            finish(PhoneAnswer(status: status, body: Data(buffer[end.upperBound...])))
        }
    }

    /// Whether anything accepts a connection on the port within 2 s.
    nonisolated private static func phoneConnects(_ port: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
            let once = OnceFlag()
            guard let target = NWEndpoint.Port(rawValue: port) else { return continuation.resume(returning: false) }
            let connection = NWConnection(host: "127.0.0.1", port: target, using: .tcp)
            let finish: @Sendable (Bool) -> Void = { result in
                if once.claim() { continuation.resume(returning: result) }
                connection.cancel()
            }
            connection.stateUpdateHandler = { @Sendable state in
                switch state {
                case .ready: finish(true)
                case .failed, .waiting: finish(false)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finish(false) }
        }
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}
