import Foundation

/// Edit Anywhere's own private network, so Macs at home reach the office Mac with nothing to
/// install and nothing to change on the router: Tailscale's engine, built into Pluck as a small
/// helper (pluck-tunnel). It only carries Edit Anywhere; it's no system VPN.
///
/// The office Mac is connected to the team's Tailscale network once, with an access token from
/// the account. With that token it makes one-time invitations for Macs at home.
enum PrivateNetwork {
    static var helper: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/pluck-tunnel")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/Edit Anywhere", isDirectory: true)
    }

    /// This Mac's name on the private network ("pluck-lowies-macbook-pro").
    static var hostname: String {
        let name = (Host.current().localizedName ?? "mac").lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        return "pluck-" + String(name.prefix(40))
    }

    enum Failure: LocalizedError {
        case noHelper, token, tokenExpired, account(String), helper(String), needsInvite, timeout
        var errorDescription: String? {
            switch self {
            case .noHelper: String(localized: "This build of Pluck doesn’t have the private network part.")
            case .token: String(localized: "Connect the host Mac to your Tailscale account first.")
            case .tokenExpired: String(localized: "The Tailscale access token has expired or was revoked. Paste a new one on the host Mac.")
            case .account(let detail): String(localized: "Tailscale said: \(detail)")
            case .helper(let detail): String(localized: "The private network couldn’t start: \(detail)")
            case .needsInvite: String(localized: "This Mac isn’t on the host Mac’s private network any more. Ask for a new invitation.")
            case .timeout: String(localized: "The private network didn’t answer in time. Check the internet connection.")
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

        /// A key that lets one Mac join, once, within `expiry` seconds.
        static func joinKey(expiry: Int) async throws -> String {
            let body: [String: Any] = [
                "capabilities": ["devices": ["create": ["reusable": false, "ephemeral": false, "preauthorized": true]]],
                "expirySeconds": expiry,
                "description": "Pluck Edit Anywhere",
            ]
            guard let key = (try await request("tailnet/-/keys", method: "POST", body: body) as? [String: Any])?["key"] as? String else {
                throw Failure.account("no key")
            }
            return key
        }

        /// Pluck's Macs on the network keep their place: Tailscale otherwise asks them to sign
        /// in again after six months, which nobody at home would know how to do.
        static func keepPluckMacsConnected() async {
            guard let list = try? await request("tailnet/-/devices") as? [String: Any],
                  let devices = list["devices"] as? [[String: Any]] else { return }
            for device in devices {
                guard let id = device["id"] as? String, (device["hostname"] as? String ?? "").hasPrefix("pluck-"),
                      device["keyExpiryDisabled"] as? Bool != true else { continue }
                _ = try? await request("device/\(id)/key", method: "POST", body: ["keyExpiryDisabled": true])
            }
        }
    }

    // MARK: - Invitations

    /// What an invitation link carries: a one-time key to join the network, where the office Mac
    /// is on it, and a pairing code.
    struct Invitation: Codable {
        var key: String
        var office: String
        var name: String
        var code: String

        var link: URL? {
            guard let data = try? JSONEncoder().encode(self) else { return nil }
            let text = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return URL(string: "pluck://edit-anywhere/join?i=" + text)
        }

        /// From a link (clicked or pasted).
        init?(link text: String) {
            guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  url.scheme == "pluck", url.host == "edit-anywhere",
                  var value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "i" })?.value
            else { return nil }
            value = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while value.count % 4 != 0 { value += "=" }
            guard let data = Data(base64Encoded: value),
                  let invitation = try? JSONDecoder().decode(Invitation.self, from: data),
                  invitation.key.hasPrefix("tskey-"), OfficeLink.normalised(invitation.code) != nil else { return nil }
            self = invitation
        }

        init(key: String, office: String, name: String, code: String) {
            self.key = key
            self.office = office
            self.name = name
            self.code = code
        }
    }
}

/// The running helper: one per Mac (the office kind on the office Mac, the home kind elsewhere).
@MainActor
@Observable
final class Tunnel {
    enum Mode: String { case office, home }

    enum State: Equatable {
        case off, starting, running(name: String, address: String), failed(String)
    }

    static let office = Tunnel(.office)
    static let home = Tunnel(.home)

    let mode: Mode
    private(set) var state = State.off
    /// Home: the local address that leads to the office Mac.
    private(set) var listen: String?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var pending: Task<Void, Error>?

    private init(_ mode: Mode) { self.mode = mode }

    private var directory: URL { PrivateNetwork.folder.appendingPathComponent(mode.rawValue, isDirectory: true) }

    /// Whether this Mac has joined the network before (it keeps its identity there).
    var hasJoined: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("tailscaled.state").path)
    }

    /// Starts the helper and waits until it carries connections. A first start needs a join key.
    /// Home: `office` is the office Mac's address on the private network.
    func start(key: String? = nil, office: String? = nil) async throws {
        // Already going (or on its way): share that.
        if key == nil {
            if let pending { return try await pending.value }
            if process?.isRunning == true, case .running = state, mode == .office || listen != nil { return }
        }
        let task = Task { try await launch(key: key, office: office) }
        pending = task
        defer { if pending == task { pending = nil } }
        try await task.value
    }

    private func launch(key: String?, office: String?) async throws {
        stop()
        guard let helper = PrivateNetwork.helper else { throw PrivateNetwork.Failure.noHelper }
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
        var settings: [String: Any] = ["mode": mode.rawValue, "dir": directory.path, "hostname": PrivateNetwork.hostname,
                                       "port": Int(OfficeLink.port)]
        if let key { settings["authKey"] = key }
        if let office { settings["office"] = office }
        var line = try JSONSerialization.data(withJSONObject: settings)
        line.append(0x0A)
        try stdin.fileHandleForWriting.write(contentsOf: line)

        // Its reports, until it carries connections (or gives up).
        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            let once = OnceFlag()
            let done: @Sendable (Result<Void, Error>) -> Void = { if once.claim() { continuation.resume(returning: $0) } }
            Task.detached { [weak self] in
                var name = "", address = ""
                do {
                    for try await text in stdout.fileHandleForReading.bytes.lines {
                        guard let report = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
                        if let error = report["error"] as? String {
                            await self?.failed(error)
                            done(.failure(PrivateNetwork.Failure.helper(error)))
                        }
                        switch report["state"] as? String {
                        case "needsKey":
                            done(.failure(PrivateNetwork.Failure.needsInvite))
                        case "running":
                            name = report["name"] as? String ?? ""
                            address = (report["ips"] as? [String])?.first { !$0.contains(":") } ?? ""
                        case "listening":
                            await self?.ready(name: name, address: address, listen: report["listen"] as? String)
                            done(.success(()))
                        default:
                            break
                        }
                    }
                } catch {}
                await self?.ended()
                done(.failure(PrivateNetwork.Failure.timeout))
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(100))
                done(.failure(PrivateNetwork.Failure.timeout))
            }
        }
        try result.get()
    }

    private func ready(name: String, address: String, listen: String?) {
        self.listen = listen
        state = .running(name: name, address: address)
    }

    private func failed(_ message: String) { state = .failed(message) }

    private func ended() {
        if case .running = state { state = .off }
        if case .starting = state { state = .off }
        process = nil
        listen = nil
    }

    func stop() {
        try? input?.close()
        process?.terminate()
        process = nil
        input = nil
        listen = nil
        state = .off
    }
}
