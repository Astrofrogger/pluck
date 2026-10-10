import Foundation
import Network
import Security

/// Other Macs sharing their Pluck Library on this network (see `LibraryServer`): found by
/// Bonjour, opened with their access code (kept in the keychain), browsed, played, copied here,
/// and sent links to download there.
@MainActor
@Observable
final class NetworkLibraries {
    static let shared = NetworkLibraries()

    struct Peer: Identifiable, Hashable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    struct Item: Identifiable, Decodable, Hashable {
        let id: String
        let title: String
        let kind: String
        var uploader: String?
        var site: String?
        var size: Int64?
        var duration: Double?
        var thumb: String?
        var ext: String?
    }

    struct Library: Decodable {
        var name: String
        var items: [Item]
        var canDownload: Bool?
        var canUpload: Bool?
    }

    enum Failure: LocalizedError {
        case notFound, wrongCode, unreachable, refused(String)

        var errorDescription: String? {
            switch self {
            case .notFound: String(localized: "That Mac isn’t sharing its Library any more.")
            case .wrongCode: String(localized: "That code isn’t right.")
            case .unreachable: String(localized: "Pluck couldn’t reach that Mac.")
            case .refused(let reason): reason
            }
        }
    }

    private(set) var peers: [Peer] = []
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var addresses: [String: URL] = [:]

    // MARK: - Finding them

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_pluck._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> Peer? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return Peer(name: name, endpoint: result.endpoint)
            }
            Task { @MainActor in self?.update(found) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        peers = []
    }

    private func update(_ found: [Peer]) {
        // Not this Mac's own Library.
        let me = Host.current().localizedName
        peers = Array(Set(found)).filter { $0.name != me }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The Mac's web address, by connecting to its service once (IPv4, so it fits in a URL).
    private func baseURL(for peer: Peer) async throws -> URL {
        if let known = addresses[peer.name] { return known }
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: peer.endpoint, using: parameters)
        let url: URL = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.claim() else { return }
                    if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint,
                       case .ipv4(let ip) = host, let url = URL(string: "http://\(ip):\(port.rawValue)") {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(throwing: Failure.unreachable)
                    }
                    connection.cancel()
                case .failed, .cancelled:
                    guard once.claim() else { return }
                    continuation.resume(throwing: Failure.unreachable)
                default:
                    break
                }
            }
            connection.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                if once.claim() { connection.cancel(); continuation.resume(throwing: Failure.unreachable) }
            }
        }
        addresses[peer.name] = url
        return url
    }

    // MARK: - Opening a Library

    /// The Library, logging in with the saved code when needed.
    func library(of peer: Peer, code typed: String? = nil) async throws -> (url: URL, library: Library) {
        let base = try await baseURL(for: peer)
        if let typed {
            try await login(base, code: typed)
            Keychain.save(typed, for: peer.name)
        }
        var (data, response) = try await get(base.appendingPathComponent("api/library"))
        if response.statusCode == 401, let saved = Keychain.code(for: peer.name) {
            try await login(base, code: saved)
            (data, response) = try await get(base.appendingPathComponent("api/library"))
        }
        if response.statusCode == 401 { throw Failure.wrongCode }
        if response.statusCode == 404 { throw Failure.notFound }
        guard response.statusCode == 200 else { throw Failure.unreachable }
        return (base, try JSONDecoder().decode(Library.self, from: data))
    }

    private func login(_ base: URL, code: String) async throws {
        var request = URLRequest(url: base.appendingPathComponent("login"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("code=\(code.filter(\.isNumber))".utf8)
        // The session cookie lands in the shared cookie store, which images and players use too.
        let (data, _) = try await URLSession.shared.data(for: request)
        if String(decoding: data, as: UTF8.self).contains("class=\"error\"") { throw Failure.wrongCode }
    }

    private func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }
        return (data, http)
    }

    /// Cookies for that Mac, for the player.
    func cookies(for base: URL) -> [HTTPCookie] {
        HTTPCookieStorage.shared.cookies(for: base) ?? []
    }

    // MARK: - Doing things there

    /// Sends a link to download on that Mac.
    func send(link: String, to base: URL) async throws {
        var request = URLRequest(url: base.appendingPathComponent("api/download"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["url": link])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure.refused(String(decoding: data, as: UTF8.self))
        }
    }

    /// Copies a file from that Mac into this Mac's Downloads folder and Library.
    func copy(_ item: Item, from base: URL, manager: DownloadManager?) async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(from: base.appendingPathComponent("file/\(item.id)"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.unreachable }
        let folder = UserDefaults.standard.string(forKey: Prefs.downloadPath) ?? NSHomeDirectory() + "/Downloads"
        let destination = Converting.outputURL(folder: folder, name: Folders.sanitize(item.title), fileExtension: item.ext ?? "mp4")
        try FileManager.default.moveItem(at: temporary, to: destination)
        if let manager {
            _ = manager.addLocalFiles([destination])
            manager.saveHistory()
        }
        return destination
    }
}

/// Access codes for other Macs' Libraries, in the login keychain.
private enum Keychain {
    private static func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Pluck Library", kSecAttrAccount as String: name]
    }

    static func save(_ code: String, for name: String) {
        SecItemDelete(query(name) as CFDictionary)
        var item = query(name)
        item[kSecValueData as String] = Data(code.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    static func code(for name: String) -> String? {
        var item = query(name)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Lets exactly one of several callbacks finish a continuation.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
