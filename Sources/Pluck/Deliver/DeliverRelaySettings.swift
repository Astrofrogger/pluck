import SwiftUI

/// Relays for clients behind strict networks (§13.10): the owner's relay token (Cloudflare TURN for the owner's own
/// rooms), or "My own relay (TURN)" (URLs plus a shared secret). Both live in the Keychain, go into the helper's
/// settings line, and into NAS hosts' environment through the setup sheets. The Worker never sees a TURN secret.
@MainActor
@Observable
final class DeliverRelay {
    static let shared = DeliverRelay()
    static let service = "tools.pluck.review.relay"
    static let urlsKey = "reviewTurnURLs"

    /// Per room, the helper's relay state ("on", "budget", "off").
    private(set) var rooms: [String: String] = [:]

    var token: String? {
        get { DeliverKeychain.load("owner", service: Self.service).map { String(decoding: $0, as: UTF8.self) } }
        set { set(newValue, "owner") }
    }

    var secret: String? {
        get { DeliverKeychain.load("turn", service: Self.service).map { String(decoding: $0, as: UTF8.self) } }
        set { set(newValue, "turn") }
    }

    var urls: [String] {
        get { (UserDefaults.standard.stringArray(forKey: Self.urlsKey) ?? []).filter(Self.validURL) }
        set { UserDefaults.standard.set(Array(newValue.filter(Self.validURL).prefix(4)), forKey: Self.urlsKey) }
    }

    private func set(_ value: String?, _ account: String) {
        let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if clean.isEmpty { DeliverKeychain.delete(account, service: Self.service) } else { DeliverKeychain.save(Data(clean.utf8), as: account, service: Self.service) }
    }

    /// `stun:`, `turn:` or `turns:` and no spaces, as the Worker checks them.
    nonisolated static func validURL(_ text: String) -> Bool { text.wholeMatch(of: #/(stun|turn|turns):[^\s]{1,250}/#) != nil }

    /// Merged into the helper's first line: `relayToken`, and `turn` when both URLs and a secret are set.
    var settings: [String: Any] {
        var line: [String: Any] = [:]
        if let token { line["relayToken"] = token }
        if let secret, !urls.isEmpty { line["turn"] = ["secret": secret, "urls": urls, "ttl": 3600] }
        return line
    }

    /// What a NAS host's environment gets (the setup sheets put it in the compose or the env file).
    var environment: [String: String] {
        var env: [String: String] = [:]
        if let token { env["PLUCK_RELAY_TOKEN"] = token }
        if let secret, !urls.isEmpty { env["PLUCK_TURN_SECRET"] = secret; env["PLUCK_TURN_URLS"] = urls.joined(separator: ",") }
        return env
    }

    /// The helper's stdout `{"relay":{"room","state"}}`.
    func heard(_ report: [String: Any]) {
        guard let relay = report["relay"] as? [String: Any], let room = relay["room"] as? String, let state = relay["state"] as? String else { return }
        rooms[room] = state
    }

    /// "Relay paused until 1 Dec (monthly limit)" while the month's budget is spent.
    var notice: String? {
        guard rooms.values.contains("budget") else { return nil }
        return String(localized: "Relay paused until \(Self.nextMonth().formatted(.dateTime.day().month(.abbreviated))) (monthly limit)")
    }

    /// The first of next month (UTC), when the budget opens again.
    nonisolated static func nextMonth(from now: Date = .now) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        return calendar.date(byAdding: .month, value: 1, to: start)!
    }
}

/// Settings › Review › Relay: the token and "My own relay (TURN)".
struct DeliverRelaySettingsCard: View {
    @State private var relay = DeliverRelay.shared
    @State private var token = ""
    @State private var urls = ""
    @State private var secret = ""

    var body: some View {
        SettingsCard("Relay") {
            SettingRow("Relay token") {
                SecureField(relay.token == nil ? "None" : "Set", text: $token).settingField(width: 200)
                Button("Save") { relay.token = token; token = "" }.settingButton().disabled(token.isEmpty && relay.token == nil)
            }
            SettingRow("My own relay (TURN)") {
                TextField("turns:turn.example.com:443?transport=tcp", text: $urls).settingField(width: 260)
            }
            SettingRow("Shared secret") {
                SecureField(relay.secret == nil ? "None" : "Set", text: $secret).settingField(width: 200)
                Button("Save") {
                    relay.urls = urls.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " }).map(String.init)
                    if !secret.isEmpty || urls.isEmpty { relay.secret = secret }
                    secret = ""
                    urls = relay.urls.joined(separator: ", ")
                }.settingButton()
            }
            if let notice = relay.notice {
                Text(verbatim: notice).font(Design.Studio.hint).foregroundStyle(Design.Studio.warn).padding(.horizontal, 14).padding(.bottom, 8)
            }
        }
        .onAppear { urls = relay.urls.joined(separator: ", ") }
    }
}
