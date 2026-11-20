import CryptoKit
import Foundation

/// 4.1.0 email updates: what this Mac knows of the main host's mail setup (its last `mail-state`), the SMTP password
/// kept in the Keychain and pushed with `mail-set`, and the forwarding of browsers' `subscribe`/`unsubscribe` to the host.
/// The host sends the mail; a Mac only asks. Wire contract: scratchpad mail410-contract.md.
@MainActor
@Observable
final class DeliverMail {
    static let shared = DeliverMail()
    static let service = "tools.pluck.review.mail"

    struct Settings: Hashable {
        var enabled = false
        var server = "", port = 465, security = "tls", user = "", from = "", replyTo = ""
        var digestHour = 8
    }
    struct Subscriber: Identifiable, Hashable {
        var id: String, kind: String, email: String, name: String, mode: String
        var person: String? = nil, mute: [String] = []
    }

    private(set) var settings = Settings()
    private(set) var hasPassword = false
    private(set) var lastError: String?
    private(set) var queued = 0
    private(set) var subscribers: [Subscriber] = []
    private(set) var hooks: [String: String] = [:]
    /// Tests: stands in for the host.
    @ObservationIgnored var fake: (([String: Any]) -> [String: Any])?

    var host: Deliver.Host? { DeliverSync.shared.dataHost }
    /// No NAS but an always-on Mac (T11): its hosted reviews send the mail, set up from here through Edit Anywhere
    /// (`reviewMail`). Never this Mac.
    var office: Deliver.Host? {
        let publish = ReviewPublish.shared
        return host == nil && !publish.hosts.contains { $0.kind == .nas } ? publish.pairedMac : nil
    }
    /// The always-on Mac answered `mail-state` (a Pluck that knows it, hosting on); kept for the share sheet.
    private(set) var officeMail = UserDefaults.standard.bool(forKey: "reviewOfficeMail")
    /// The main host knows mail (its hello said `mail: 1`), or the always-on Mac does.
    var available: Bool { host.map { $0.mail == 1 } ?? (office != nil && officeMail) }
    /// Browsers' links may offer email: the host knows mail and has it switched on.
    var active: Bool { available && settings.enabled }

    /// A `mail-state` answer: the model.
    func heard(_ answer: [String: Any]) {
        let s = answer["settings"] as? [String: Any] ?? [:]
        settings = Settings(enabled: s["enabled"] as? Bool ?? false, server: s["server"] as? String ?? "", port: s["port"] as? Int ?? 465,
                            security: s["security"] as? String ?? "tls", user: s["user"] as? String ?? "", from: s["from"] as? String ?? "",
                            replyTo: s["replyTo"] as? String ?? "", digestHour: s["digestHour"] as? Int ?? 8)
        hasPassword = answer["hasPassword"] as? Bool ?? false
        // The host's last failure is {code, detail, at}: shown as the same texts as an answer's error.
        lastError = (answer["lastError"] as? [String: Any]).flatMap { Self.errorText(["error": $0]) } ?? answer["lastError"] as? String
        queued = answer["queued"] as? Int ?? 0
        subscribers = (answer["subscribers"] as? [[String: Any]] ?? []).compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return Subscriber(id: id, kind: row["kind"] as? String ?? "client", email: row["email"] as? String ?? "", name: row["name"] as? String ?? "",
                              mode: row["mode"] as? String ?? "instant", person: row["person"] as? String, mute: row["mute"] as? [String] ?? [])
        }
        hooks = (answer["hooks"] as? [String: [String: Any]] ?? [:]).compactMapValues { $0["url"] as? String }
    }

    /// One op on the main host; nil when there is no host or it can't be reached.
    func ask(_ op: [String: Any]) async -> [String: Any]? {
        if let fake { return fake(op) }
        if let host { return try? await ReviewHostClient.ask(host, op) }
        guard office != nil else { return nil }
        let answer = try? await OfficeRenderClient.shared.ask("reviewMail", ["op": op], timeout: 60)
        if op["op"] as? String == "mail-state" {
            officeMail = answer?["mail"] as? Int == 1
            UserDefaults.standard.set(officeMail, forKey: "reviewOfficeMail")
        }
        return answer
    }

    func refresh() async {
        if let answer = await ask(["op": "mail-state"]) { heard(answer) }
    }

    /// The error texts the Mac shows (contract).
    static func errorText(_ answer: [String: Any]?) -> String? {
        guard let answer else { return String(localized: "The mail host isn’t answering.") }
        guard let error = answer["error"] as? [String: Any] else { return nil }
        switch error["code"] as? String {
        case "auth": return String(localized: "The mail server didn’t accept the user name or password.")
        case "connect": return String(localized: "Couldn’t reach the mail server.")
        case "tls": return String(localized: "The secure connection to the mail server failed.")
        case "rejected": return String(localized: "The mail server refused the message.")
        case "off": return String(localized: "Email isn’t set up.")
        default: return error["detail"] as? String ?? String(localized: "Something went wrong.")
        }
    }

    // MARK: The password (this Mac's Keychain; the host keeps its own copy)

    static func savePassword(_ password: String, for host: UUID) {
        DeliverKeychain.save(Data(password.utf8), as: host.uuidString, service: service)
    }
    static func password(for host: UUID) -> String? {
        DeliverKeychain.load(host.uuidString, service: service).map { String(decoding: $0, as: UTF8.self) }
    }

    /// `mail-set`: the settings, and the password when one was typed (nil: the host keeps what it has).
    func push(_ new: Settings, password: String?) async -> String? {
        var wire: [String: Any] = ["enabled": new.enabled, "server": new.server, "port": new.port, "security": new.security, "user": new.user,
                                   "from": new.from, "replyTo": new.replyTo.isEmpty ? NSNull() : new.replyTo,
                                   "tzOffset": TimeZone.current.secondsFromGMT() / 60, "digestHour": new.digestHour,
                                   "lang": Locale.current.language.languageCode?.identifier ?? "en"]
        var op: [String: Any] = ["op": "mail-set", "settings": wire]
        if let password { op["password"] = password }
        let answer = await ask(op)
        if let text = Self.errorText(answer) { return text }
        await refresh()
        return nil
    }

    /// A link's "Mute Notifications" also mutes this Mac's person's emails about it (their team row's `mute`).
    func mute(_ link: UUID, _ on: Bool) async {
        guard available, let me = DeliverNotify.me(), let row = subscribers.first(where: { $0.kind == "team" && $0.person == me }) else { return }
        _ = await ask(Self.muteOp(row, link.uuidString, on))
        await refresh()
    }

    /// `muteLink` + `muted` is the one change the host merges into the row's list (so the web page's mutes stay); the whole
    /// `mute` list is for hosts older than 4.0.7, which replace the list as before.
    nonisolated static func muteOp(_ row: Subscriber, _ link: String, _ on: Bool) -> [String: Any] {
        ["op": "subscriber-set", "id": row.id, "kind": "team", "email": row.email, "mode": row.mode,
         "mute": muted(row.mute, link, on), "muteLink": link, "muted": on]
    }

    nonisolated static func muted(_ list: [String], _ link: String, _ on: Bool) -> [String] {
        list.filter { $0 != link } + (on ? [link] : [])
    }

    // MARK: Mentions

    /// `"a:" + first 16 chars of base64url(SHA-256("pluck-mention:" + authorToken))`.
    nonisolated static func mentionID(_ authorToken: String) -> String {
        "a:" + String(DeliverKeys.base64url(Data(SHA256.hash(data: Data(("pluck-mention:" + authorToken).utf8)))).prefix(16))
    }

    /// The team person (Admin or Editor with an email) an assignee's name is; nil when none or more than one has that name.
    nonisolated static func teammate(_ assignee: String, in people: [Deliver.Person]) -> String? {
        let name = assignee.trimmingCharacters(in: .whitespaces)
        let found = people.filter { person in
            ["owner", "editor"].contains(person.role ?? "") && person.email.map(validEmail) == true
                && person.name?.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame
        }
        return found.count == 1 ? found[0].id : nil
    }

    nonisolated static func validEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        return text.count <= 120 && parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty && !text.contains(where: \.isWhitespace)
    }
}
