import CryptoKit
import Foundation
import UserNotifications

/// Host versions and updates (§13.15): what a host's protocol means for this Pluck, the signed `host-release.json` of
/// Pluck's own release (never "latest"), and TrueNAS updates at the quiet time, never while the host is busy.
@MainActor
@Observable
final class DeliverHostUpdate {
    static let shared = DeliverHostUpdate()

    enum Compatibility: Equatable { case fine, older, refused, readOnly }

    /// host = Pluck's: fine; one behind: works, newer features hidden; further behind: refused; newer: read only.
    nonisolated static func compatibility(host: Int, pluck: Int = ReviewHostClient.protocolLevel) -> Compatibility {
        if host == pluck { return .fine }
        if host == pluck - 1 { return .older }
        if host < pluck - 1 { return .refused }
        return .readOnly
    }

    @MainActor static func banner(_ host: Deliver.Host) -> String? {
        guard let level = host.protocol else { return nil }
        switch compatibility(host: level) {
        case .fine: return nil
        case .older: return String(localized: "Update \(host.name) for deadlines and backups")
        case .refused: return String(localized: "\(host.name) needs an update")
        case .readOnly: return String(localized: "Update Pluck to use \(host.name)")
        }
    }

    // MARK: - The signed release file

    struct Release: Equatable {
        var version: String
        var level: Int
        var image: String
        var assets: [String: String]
    }

    /// The Ed25519 public key (32 raw bytes, base64) that signs host releases. The owner puts the key from
    /// `Pluck Signing/host-update-ed25519.pem` here; until then no update is ever installed.
    nonisolated static let releaseKey: String? = nil
    /// Tests: another key.
    static var testKey: Curve25519.Signing.PublicKey?

    /// `host-release.json` checked against its `.sig` (base64 of 64 raw bytes); nil when either is wrong.
    nonisolated static func verify(_ json: Data, signature: String, key: Curve25519.Signing.PublicKey?) -> Release? {
        guard let key, let raw = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)), raw.count == 64,
              key.isValidSignature(raw, for: json),
              let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let version = object["version"] as? String, let level = object["protocol"] as? Int,
              let image = object["image"] as? String, image.contains("@sha256:"),
              let assets = object["assets"] as? [String: String] else { return nil }
        return Release(version: version, level: level, image: image, assets: assets)
    }

    static var key: Curve25519.Signing.PublicKey? {
        testKey ?? releaseKey.flatMap { Data(base64Encoded: $0) }.flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
    }

    static var pluckVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static func releaseURL(_ file: String, version: String? = nil) -> URL? {
        URL(string: "https://github.com/Astrofrogger/pluck/releases/download/v\(version ?? pluckVersion)/\(file)")
    }

    private(set) var release: Release?
    private(set) var checked: Date?
    /// Per host: the last update's result and its error in full.
    private(set) var results: [UUID: (result: String, at: Date, error: String?)] = [:]
    private(set) var updating: UUID?
    @ObservationIgnored private var timer: Task<Void, Never>?

    /// Pluck's own release's host files, once a day and at launch (test copies never fetch).
    func check() async {
        guard ScreenshotMode.scene == nil, let jsonURL = Self.releaseURL("host-release.json"), let sigURL = Self.releaseURL("host-release.json.sig"),
              let (json, a) = try? await URLSession.shared.data(from: jsonURL), (a as? HTTPURLResponse)?.statusCode == 200,
              let (sig, b) = try? await URLSession.shared.data(from: sigURL), (b as? HTTPURLResponse)?.statusCode == 200 else { return }
        release = Self.verify(json, signature: String(decoding: sig, as: UTF8.self), key: Self.key)
        checked = .now
    }

    func start() {
        guard ScreenshotMode.scene == nil, timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                await self?.updateDue()
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }
    }

    // MARK: - When

    nonisolated static let timeKey = "reviewHostUpdateTime."
    /// "Update hosts at" per host, as HH:mm (04:00 by default).
    static func quietTime(_ host: UUID) -> String { UserDefaults.standard.string(forKey: timeKey + host.uuidString) ?? "04:00" }

    /// Due now: at the quiet time (within its 15-minute check), or at once when the host is too old for this Pluck.
    nonisolated static func due(now: Date, quiet: String, hostLevel: Int?, calendar: Calendar = .current) -> Bool {
        if let hostLevel, compatibility(host: hostLevel) == .refused { return true }
        let parts = quiet.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return false }
        let minutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        return (0..<15).contains(minutes - (parts[0] * 60 + parts[1]))
    }

    private func updateDue() async {
        guard let release else { return }
        for host in ReviewPublish.shared.hosts where host.kind == .nas && Self.isUpgrade(from: host.version, to: release.version) {
            guard Self.due(now: .now, quiet: Self.quietTime(host.id), hostLevel: host.protocol) else { continue }
            await update(host, to: release, forced: host.protocol.map { Self.compatibility(host: $0) == .refused } ?? false)
        }
    }

    // MARK: - Updating a TrueNAS host (§13.15 a)

    /// Never mid-work: `prepare-update` until it says not busy (every 5 min, an hour at most; a forced update goes ahead then).
    func prepare(_ host: Deliver.Host, forced: Bool, wait: Duration = .seconds(300)) async -> Bool {
        for _ in 0..<13 {
            if let answer = try? await ReviewHostClient.ask(host, ["op": "prepare-update"]), answer["busy"] as? Bool == false { return true }
            try? await Task.sleep(for: wait)
        }
        if !forced { _ = try? await ReviewHostClient.ask(host, ["op": "cancel-update"]) }
        return forced
    }

    /// Only ever forward: an older Pluck never moves a newer host back to its own (older) signed release.
    nonisolated static func isUpgrade(from host: String?, to release: String) -> Bool {
        guard let host else { return true }
        let plain = { (v: String) in v.hasPrefix("v") ? String(v.dropFirst()) : v }
        return plain(release).compare(plain(host), options: .numeric) == .orderedDescending
    }

    func update(_ host: Deliver.Host, to release: Release, forced: Bool = false) async {
        guard Self.isUpgrade(from: host.version, to: release.version) else {
            results[host.id] = ("skipped: not newer", .now, nil)
            return
        }
        guard updating == nil, let address = host.address?.split(separator: ":").first.map(String.init) else { return }
        guard let key = TrueNASKeychain.load(address) else {
            return notify(String(localized: "Update available: paste the API key to update"), host: host)
        }
        updating = host.id
        defer { updating = nil }
        guard await prepare(host, forced: forced) else {
            results[host.id] = ("skipped: busy", .now, nil)
            return
        }
        let folder = DeliverStore.shared.root.appendingPathComponent("hosts/\(host.id.uuidString)", isDirectory: true)
        let current = folder.appendingPathComponent("compose.yml"), previous = folder.appendingPathComponent("compose.previous.yml")
        guard let old = try? String(contentsOf: current, encoding: .utf8) else {
            results[host.id] = ("failed", .now, String(localized: "This host’s compose file isn’t on this Mac."))
            return
        }
        let new = old.replacingOccurrences(of: #"ghcr\.io/[^\s"']+@sha256:[0-9a-f]{64}"#, with: release.image, options: .regularExpression)
        let client = TrueNASClient(address: address, pin: TrueNASKeychain.pin(address))
        defer { client.close() }
        do {
            try await client.connect()
            try await client.login(key)
            try? old.write(to: previous, atomically: true, encoding: .utf8)
            let result = await client.update(to: new, previous: old) {
                for _ in 0..<24 {
                    if let status = try? await ReviewHostClient.ask(host, ["op": "status"]), status["version"] as? String == release.version { return true }
                    try? await Task.sleep(for: .seconds(5))
                }
                return false
            }
            if result == .ok { try? new.write(to: current, atomically: true, encoding: .utf8) }
            results[host.id] = (result.rawValue, .now, nil)
        } catch {
            results[host.id] = ("failed", .now, error.localizedDescription)
        }
    }

    private func notify(_ text: String, host: Deliver.Host) {
        guard ScreenshotMode.scene == nil else { return }
        let content = UNMutableNotificationContent()
        content.title = host.name
        content.body = text
        content.categoryIdentifier = Notifications.hostUpdateCategory
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "review-update-" + host.id.uuidString, content: content, trigger: nil))
    }
}
