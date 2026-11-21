import SwiftUI
import UserNotifications

// People (accounts plan 2026-11-17 §3, §5): the main server's team, everyone on it with their passkeys, open invites,
// requests from review links and the paired devices, in one place. The main does everything (sync ops, role mac);
// this Mac only asks and shows. Invite links are shown once and never kept here.
//
// Roles (4.0.5): the team is its Admins and Editors, people and Macs alike. An Admin (stored "owner" for a person,
// devices.json access "admin" for a Mac) does everything; an Editor does the Deliver work and invites for an admin to
// approve. Clients aren't on the team: passkey accounts for review links, shown apart. A server before roles says
// nothing of them, and every Mac is an admin there.

extension Deliver {
    /// The `people` answer, only what the page shows; every field may be missing.
    struct People: Codable, Hashable {
        struct Team: Codable, Hashable { var id: String?; var name: String?; var link: String? }
        struct Settings: Codable, Hashable { var editorsInvite: Bool? }
        var team: Team?
        var settings: Settings?
        var people: [Person]?
        var invites: [PersonInvite]?
        var requests: [AccountRequest]?
        /// Passkey credential ids locked after failed sign-ins (15 min).
        var locked: [String]?
        /// 1: the main approves editors' invites (`invite-approve`); an older main doesn't say.
        var approvals: Int?

        init() {}
        /// Field by field: one the host changed the shape of (as `locked` was a Bool) leaves only that field empty.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            team = try? c.decode(Team.self, forKey: .team)
            settings = try? c.decode(Settings.self, forKey: .settings)
            people = try? c.decode([Person].self, forKey: .people)
            invites = try? c.decode([PersonInvite].self, forKey: .invites)
            requests = try? c.decode([AccountRequest].self, forKey: .requests)
            locked = try? c.decode([String].self, forKey: .locked)
            approvals = try? c.decode(Int.self, forKey: .approvals)
        }
    }

    struct Person: Codable, Hashable, Identifiable {
        var id: String
        var name: String?
        var email: String?
        var role: String?            // client | editor | owner
        var footage: Bool?
        var footageDownload: Bool?
        var lastSeen: String?
        var passkeys: [Passkey]?
        /// A client from a request: the link they asked from.
        var link: String?
        var joined: Bool { !(passkeys ?? []).isEmpty }
    }

    struct Passkey: Codable, Hashable, Identifiable { var id: String; var label: String?; var added: String?; var lastUsed: String? }
    /// `by`: who made it ("mac", or a person id); `approval` "pending": an editor's, waiting for an admin; `waiting`: when
    /// the invitee opened it.
    struct PersonInvite: Codable, Hashable, Identifiable {
        var id: String; var person: String?; var kind: String?; var expires: String?; var by: String?; var approval: String?; var waiting: String?
    }
    /// `invitedBy` (only here, never from the host): an editor's invite waiting for approval, notified like a request.
    struct AccountRequest: Codable, Hashable, Identifiable { var id: String; var name: String?; var email: String?; var link: String?; var at: String?; var invitedBy: String? }
    /// A Mac or backup paired with the server (`devices`, §13.2).
    /// `access` (roles): "admin" | "editor" for a Mac; missing (a server before roles): an admin.
    struct PairedDevice: Codable, Hashable, Identifiable {
        var id: String; var name: String?; var role: String?; var lastSeen: String?; var access: String?
        var isMac: Bool { role != "backup" }
        var isAdmin: Bool { isMac && access != "editor" }
    }
}

@MainActor
@Observable
final class DeliverPeople {
    static let shared = DeliverPeople()

    private(set) var people = Deliver.People()
    private(set) var devices: [Deliver.PairedDevice] = []
    var problem: String?
    /// The main has no team, and one can be put back (the backup's copy, else this Mac's): its name.
    private(set) var restorable: String?

    /// Requests already notified (kept, so a restart doesn't notify them again).
    private static let seenKey = "reviewPeopleSeenRequests"

    /// The main server People belongs to: the one holding the review data, else the first main.
    /// Tests: the main to use (a test home may hold other servers).
    static var testMain: UUID?

    static func main(_ publish: ReviewPublish? = nil) -> Deliver.Host? {
        let publish = publish ?? .shared
        if let id = testMain, let host = publish.host(id) { return host }
        let mains = publish.hosts.filter { $0.kind == .nas && $0.role != "backup" }
        return mains.first { $0.id == DeliverSync.shared.state.host } ?? mains.first
    }

    enum Shown { case hidden, update, on }
    /// No main: no People. A main whose hello doesn't say `accounts: 1` (4.0.3): only the note to update it.
    static func shown(_ main: Deliver.Host?) -> Shown {
        guard let main else { return .hidden }
        return main.accounts == 1 ? .on : .update
    }

    /// A backup that answered here without `accounts` (4.0.3): people can't sign in while the main is offline.
    static func oldBackup(_ publish: ReviewPublish? = nil) -> Bool {
        (publish ?? .shared).hosts.contains { $0.kind == .nas && $0.role == "backup" && $0.version != nil && $0.accounts != 1 }
    }

    nonisolated static func date(_ text: String?) -> Date? { text.flatMap { ISO8601DateFormatter().date(from: $0) } }

    nonisolated static func decode<T: Decodable>(_ type: T.Type, _ value: Any?) -> T? {
        guard let value, JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    var pending: Int { people.requests?.count ?? 0 }

    /// Editors' invites waiting for an admin (this Mac, or an owner on the team page).
    var awaiting: [Deliver.PersonInvite] { (people.invites ?? []).filter { $0.approval == "pending" } }

    /// A person's name, or an editor Mac's for its invites ("mac:<device>").
    func name(_ person: String?) -> String? {
        if let device = person?.split(separator: ":", maxSplits: 1).last.map(String.init), person?.hasPrefix("mac:") == true { return devices.first { $0.id == device }?.name }
        return people.people?.first { $0.id == person }?.name
    }

    // MARK: Roles

    /// The main gives Macs roles (4.0.5).
    static func roles(_ main: Deliver.Host?) -> Bool { main?.roles == 1 }
    /// This Mac may do admin work there (every Mac on a server before roles).
    static func isAdmin(_ main: Deliver.Host?) -> Bool { main?.roles != 1 || main?.access != "editor" }

    /// The team: admins and editors with a passkey or an invite; clients aren't on it.
    var team: [Deliver.Person] { (people.people ?? []).filter { $0.role == "owner" || $0.role == "editor" } }
    var clients: [Deliver.Person] { (people.people ?? []).filter { $0.role != "owner" && $0.role != "editor" } }
    var macs: [Deliver.PairedDevice] { devices.filter(\.isMac) }

    /// Admins who can act: people with a passkey and Macs (as the main counts them for the last-admin guard).
    var adminCount: Int { team.filter { $0.role == "owner" && $0.joined }.count + macs.filter(\.isAdmin).count }
    func lastAdmin(_ person: Deliver.Person) -> Bool { person.role == "owner" && person.joined && adminCount <= 1 }
    func lastAdmin(_ device: Deliver.PairedDevice) -> Bool { device.isAdmin && adminCount <= 1 }

    func setRole(_ person: String, _ role: String) async { await update(person, ["role": role]) }
    func setRole(device: String, _ access: String) async { await run(["op": "device-role", "id": device, "access": access]) }
    func removeDevice(_ id: String) async { await run(["op": "device-remove", "id": id]) }

    enum Member: Hashable { case person(String), mac(String) }

    /// Transfer Admin: the chosen person or Mac becomes an admin; then, if asked, this Mac steps down to editor.
    @discardableResult
    func transfer(to member: Member, stepDown: Bool) async -> Bool {
        let made: [String: Any]?
        switch member {
        case .person(let id): made = await run(["op": "person-update", "id": id, "role": "owner"])
        case .mac(let id): made = await run(["op": "device-role", "id": id, "access": "admin"])
        }
        guard made != nil else { return false }
        if stepDown, let me = Self.main()?.device { return await run(["op": "device-role", "id": me, "access": "editor"]) != nil }
        return true
    }

    /// `people` and `devices` in one session (the hello also records whether the main has accounts).
    func load() async {
        guard let main = Self.main() else { return }
        do {
            var answer: [String: Any] = [:], listed: Any?
            try await ReviewHostClient.session(main) { session in
                guard ReviewPublish.shared.host(main.id)?.accounts == 1 else { return }
                answer = try await session.ask(["op": "people"])
                listed = (try? await session.ask(["op": "devices"]))?["devices"]
            }
            guard Self.shown(ReviewPublish.shared.host(main.id)) == .on else { return }
            heard(answer)
            devices = Self.decode([Deliver.PairedDevice].self, listed) ?? devices
            problem = nil
            await keepTeam(main)
        } catch {
            problem = Self.problem(error)
        }
    }

    /// A `people` answer (here, or from a sync round): the model, and a notification for each request not seen before.
    func heard(_ answer: [String: Any]) {
        guard let decoded = Self.decode(Deliver.People.self, answer) else { return }
        people = decoded
        let seen = Set(UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? [])
        let requests = (decoded.requests ?? []) + awaiting.map { .init(id: $0.id, name: name($0.person), invitedBy: name($0.by) ?? "") }
        announce(requests.filter { !seen.contains($0.id) })
        UserDefaults.standard.set(requests.map(\.id), forKey: Self.seenKey)
    }

    // New requests notify at most once a minute; several in that minute become one "N new account requests".
    @ObservationIgnored private var queued: [Deliver.AccountRequest] = []
    @ObservationIgnored private var lastNotice = Date.distantPast
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Tests: the titles posted (or that would be, in screenshot mode).
    @ObservationIgnored var posted: [String] = []

    func announce(_ new: [Deliver.AccountRequest], now: Date = .now) {
        queued += new
        guard !queued.isEmpty else { return }
        let wait = 60 - now.timeIntervalSince(lastNotice)
        if wait <= 0 { return flushNotice(now) }
        guard noticeTask == nil else { return }
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.flushNotice(.now)
        }
    }

    func flushNotice(_ now: Date) {
        noticeTask?.cancel()
        noticeTask = nil
        guard !queued.isEmpty else { return }
        let content = UNMutableNotificationContent()
        if queued.count == 1, let by = queued[0].invitedBy {
            content.title = String(localized: "\(queued[0].name ?? "") is waiting for your approval")
            content.body = by.isEmpty ? "" : String(localized: "invited by \(by)")
        } else if queued.count == 1 {
            content.title = String(localized: "\(queued[0].name ?? "") asks for an account")
            content.body = queued[0].email ?? ""
        } else {
            content.title = String(localized: "\(queued.count) new account requests")
        }
        queued = []
        lastNotice = now
        posted.append(content.title)
        guard ScreenshotMode.scene == nil else { return }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "review-requests", content: content, trigger: nil))
    }

    static func problem(_ error: Error) -> String {
        (error as? Deliver.Failure)?.code == "main" ? String(localized: "Try again when the main server is online") : ReviewHostClient.problem(error)
    }

    /// One owner op on the main; its answer (nil: it failed, `problem` says why). The list is read again after it.
    @discardableResult
    func run(_ op: [String: Any]) async -> [String: Any]? {
        guard let main = Self.main() else { return nil }
        do {
            let answer = try await ReviewHostClient.ask(main, op)
            problem = nil
            await load()
            return answer
        } catch {
            problem = Self.problem(error)
            return nil
        }
    }

    // MARK: The team's identity (id, name, key): kept on this Mac, put back on a wiped main

    /// One entry in the vault (DeliverKeychain → PluckVault): `{format, team, settings}` of the last team the main had.
    static let teamService = "tools.pluck.review.team", teamAccount = "team"

    static func savedTeam() -> [String: Any]? {
        DeliverKeychain.load(teamAccount, service: teamService).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// The main has a team: keep a copy when it's new or changed (its link changes with its key). It has none: find
    /// what can restore it, preferring the backup's copy (everyone and their passkeys) to this Mac's (the team only).
    /// The team link last exported this run (tests clear it).
    @ObservationIgnored var exported: String?

    private func keepTeam(_ main: Deliver.Host) async {
        let saved = Self.savedTeam()
        if let link = people.team?.link {
            restorable = nil
            guard (saved?["team"] as? [String: Any])?["link"] as? String != link, exported != link else { return }
            exported = link // asked once per team link and run, even if the main can't answer
            guard let file = try? await ReviewHostClient.ask(main, ["op": "team-export"]), let team = file["team"] as? [String: Any] else { return }
            var copy: [String: Any] = ["format": 1, "team": team.merging(["link": link]) { $1 }]
            copy["settings"] = file["settings"]
            if let data = try? JSONSerialization.data(withJSONObject: copy) { DeliverKeychain.save(data, as: Self.teamAccount, service: Self.teamService) }
        } else {
            let file = await restoreFile()
            restorable = (file?["team"] as? [String: Any])?["name"] as? String
        }
    }

    private func restoreFile() async -> [String: Any]? {
        for backup in ReviewPublish.shared.hosts where backup.kind == .nas && backup.role == "backup" {
            if let file = try? await ReviewHostClient.ask(backup, ["op": "team-export"]), file["format"] as? Int == 1 { return file }
        }
        return Self.savedTeam()
    }

    /// Put the team back on a main that has none (the main refuses when it has one: its own data comes first).
    @discardableResult
    func restoreTeam() async -> Bool {
        guard let file = await restoreFile() else { return false }
        return await run(["op": "team-restore", "accounts": file])?["ok"] as? Bool == true
    }

    /// Start a new team: a new key for the same team; the old key signs the move, so browsers that know the team
    /// follow. Everyone is invited again (their passkeys were for the old key).
    func startNewTeam() async { await run(["op": "team-reset"]) }

    /// A one-time link for a person, shown once (an invite, or Reset sign-in).
    struct OneTimeLink: Identifiable, Hashable {
        var link: String
        var expires: Date
        /// An editor's invite: it works once an admin approves it.
        var pending = false
        var id: String { link }
        init?(_ answer: [String: Any]?) {
            guard let link = answer?["link"] as? String else { return nil }
            self.link = link
            pending = answer?["approval"] as? String == "pending"
            expires = DeliverPeople.date(answer?["expires"] as? String) ?? .now.addingTimeInterval(7 * 86_400)
        }
    }

    /// The team first if there's none yet (named after the branding), then the person and their invite.
    func invite(name: String, role: String, footage: Bool) async -> OneTimeLink? {
        if people.team?.id == nil, restorable != nil, await restoreTeam() {
            // the same team back (a wiped main): no new one
        } else if people.team?.id == nil {
            let brand = DeliverStore.shared.branding?.name.trimmingCharacters(in: .whitespaces) ?? ""
            guard await run(brand.isEmpty ? ["op": "team-set"] : ["op": "team-set", "name": brand]) != nil else { return nil }
        }
        return OneTimeLink(await run(["op": "person-invite", "name": name, "role": role, "footage": footage]))
    }

    func reset(_ person: String) async -> OneTimeLink? { OneTimeLink(await run(["op": "person-reset", "id": person])) }
    func update(_ person: String, _ change: [String: Any]) async { await run(change.merging(["op": "person-update", "id": person]) { $1 }) }
    func remove(_ person: String) async { await run(["op": "person-remove", "id": person]) }
    func removePasskey(_ id: String, of person: String) async { await run(["op": "passkey-remove", "person": person, "id": id]) }
    func cancelInvite(_ id: String) async { await run(["op": "invite-cancel", "id": id]) }
    func approveInvite(_ id: String) async { await run(["op": "invite-approve", "id": id]) }
    func answer(_ request: String, accept: Bool) async { await run(["op": accept ? "request-accept" : "request-decline", "id": request]) }
    func setTeam(name: String? = nil, editorsInvite: Bool? = nil) async {
        var op: [String: Any] = ["op": "team-set"]
        if let name { op["name"] = name }
        if let editorsInvite { op["editorsInvite"] = editorsInvite }
        await run(op)
    }

    /// "People" as a team's list (the photo "People" is faces, translated so in some languages).
    static var title: String { String(localized: "people.title", defaultValue: "People") }

    /// "owner" is shown as Admin (kept as is on the wire and on disk).
    static func roleName(_ role: String?) -> String {
        switch role {
        case "owner", "admin": String(localized: "people.role.admin", defaultValue: "Admin")
        case "editor": String(localized: "people.role.editor", defaultValue: "Editor")
        default: String(localized: "Client")
        }
    }

    /// One line on what a role may do.
    static func roleHelp(_ role: String?) -> String {
        switch role {
        case "owner", "admin": String(localized: "Everything, with roles, approvals, Macs and team settings")
        case "editor": String(localized: "Projects, versions, links and comments; invites wait for an admin")
        default: String(localized: "Only the review links shared with them")
        }
    }

    static func roleSymbol(_ role: String?) -> String {
        switch role {
        case "owner", "admin": "checkmark.shield"
        case "editor": "pencil"
        default: "eye"
        }
    }

    /// Screenshots: a stand-in main with its team (two admins, two editors, three Macs), two clients, a request and a
    /// waiting invite. This Mac is "Edit Suite iMac", an admin.
    static func snapshot() {
        let fingerprint = Array(repeating: "AB", count: 32).joined(separator: ":"), day: TimeInterval = 86_400
        let iso = { (ago: TimeInterval) in ISO8601DateFormatter().string(from: .now.addingTimeInterval(-ago)) }
        let key = { (id: String, label: String, ago: TimeInterval) -> [String: Any] in ["id": id, "label": label, "added": iso(9 * day), "lastUsed": iso(ago)] }
        ReviewHostClient.fakeFingerprint = fingerprint
        ReviewHostClient.fake = { request, _ in
            switch request["op"] as? String {
            case nil: return ["ok": true, "accounts": 1, "approvals": 1, "roles": 1, "access": "admin", "portal": 1]
            case "people": return ["team": ["id": "t1", "name": "Northwind Films", "link": "https://pluck.tools/r/#k.p"], "settings": ["editorsInvite": true], "approvals": 1,
                                   "people": [["id": "p1", "name": "Anna Berg", "role": "owner", "lastSeen": iso(3600), "passkeys": [key("c1", "Safari on Mac", 3600)]],
                                              ["id": "p2", "name": "Sam Lee", "role": "editor", "footage": true, "lastSeen": iso(2 * day), "passkeys": [key("c2", "Chrome on Android", 2 * day)]],
                                              ["id": "p3", "name": "Jo Park", "role": "editor", "passkeys": []],
                                              ["id": "p4", "name": "Alex Kim", "role": "client", "link": "L1", "lastSeen": iso(day), "passkeys": [key("c3", "Safari on iPhone", day)]],
                                              ["id": "p5", "name": "Robin Hale", "role": "client", "lastSeen": iso(5 * day), "passkeys": [key("c4", "Firefox on Windows", 5 * day)]],
                                              ["id": "p6", "name": "Kai Moss", "role": "client", "passkeys": []]],
                                   "invites": [["id": "i1", "person": "p3", "kind": "invite", "by": "mac", "expires": iso(-6 * day)],
                                               ["id": "i2", "person": "p6", "kind": "invite", "by": "p2", "approval": "pending", "waiting": iso(1200), "expires": iso(-6 * day)]],
                                   "requests": [["id": "r1", "name": "Lee Wong", "email": "lee@example.com", "link": "", "at": iso(1800)]], "locked": []]
            case "devices": return ["devices": [["id": "d1", "name": "Edit Suite iMac", "role": "mac", "access": "admin", "lastSeen": iso(60)],
                                                ["id": "d2", "name": "MacBook Pro (Colour)", "role": "mac", "access": "editor", "lastSeen": iso(4 * 3600)],
                                                ["id": "d3", "name": "Assist Mac mini", "role": "mac", "access": "editor", "lastSeen": iso(3 * day)],
                                                ["id": "b1", "name": "Backup NAS", "role": "backup", "lastSeen": iso(60)]]]
            default: return ["ok": true]
            }
        }
        if var host = ReviewPublish.shared.addNAS(name: "Studio NAS", address: "studio-nas.test:8790", pairing: "pluck-host:\(DeliverKeys.base64url(DeliverKeys.random(32)))@\(fingerprint)") {
            host.role = "main"
            host.accounts = 1
            host.roles = 1
            host.access = "admin"
            host.device = "d1"
            host.portal = 1
            ReviewPublish.shared.add(host)
            testMain = host.id
        }
        // Two client pages over the stand-in projects (People › Client Pages).
        let store = DeliverStore.shared, projects = store.projects.map(\.id)
        if !projects.isEmpty, !store.links.contains(where: \.isPortal) {
            _ = try? DeliverClientPage.make(name: "Northwind", projects: Array(projects.prefix(2)), store: store)
            _ = try? DeliverClientPage.make(name: "Harbour Studio", projects: Array(projects.suffix(1)), store: store)
        }
    }
}

// MARK: - The page

/// People: waiting answers on top, then the team (Admins, Editors: people and Macs), then Clients, then the team's
/// settings. Each row: name, role chip (a menu for admins, each role with its one line), last seen.
struct DeliverPeopleView: View {
    @State private var model = DeliverPeople.shared
    @State private var publish = ReviewPublish.shared
    @State private var inviting = false
    @State private var transferring = false
    @State private var shown: DeliverPeople.OneTimeLink?
    @State private var removing: Deliver.Person?
    @State private var removingMac: Deliver.PairedDevice?
    @State private var resetting: Deliver.Person?
    @State private var promoting: Deliver.Person?
    @State private var teamName = ""
    @State private var copied = false
    @State private var resettingTeam = false

    private var main: Deliver.Host? { DeliverPeople.main(publish) }
    private var admin: Bool { DeliverPeople.isAdmin(main) }
    private var roles: Bool { DeliverPeople.roles(main) }
    private var canInvite: Bool { admin || model.people.settings?.editorsInvite == true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(DeliverPeople.title).font(Design.Studio.pageTitle).foregroundStyle(Design.Studio.text)
                    Spacer()
                    if DeliverPeople.shown(main) == .on {
                        if let link = model.people.team?.link {
                            Button { DeliverLinkShare.copy(link); copied = true } label: {
                                Label(copied ? "Copied" : "Copy Team Link", systemImage: copied ? "checkmark" : "link")
                            }.buttonStyle(StudioFlatButtonStyle())
                        }
                        if admin && roles && model.people.team?.id != nil {
                            Button { transferring = true } label: { Label("Transfer Admin…", systemImage: "arrow.left.arrow.right") }.buttonStyle(StudioFlatButtonStyle())
                        }
                        if canInvite {
                            Button { inviting = true } label: { Label("Invite…", systemImage: "person.badge.plus") }.buttonStyle(StudioFlatButtonStyle(prominent: true))
                        }
                    }
                }
                .padding(.bottom, 12)
                switch DeliverPeople.shown(main) {
                case .hidden: EmptyView()
                case .update: SettingNote(text: Text("Update the server to add people")).studioBox()
                case .on: content
                }
            }
            .padding(24)
        }
        .task {
            while !Task.isCancelled {
                await model.load()
                teamName = model.people.team?.name ?? teamName
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .sheet(isPresented: $inviting) { DeliverPersonInviteSheet() }
        .sheet(isPresented: $transferring) { DeliverTransferAdminSheet() }
        .sheet(item: $shown) { DeliverPersonInviteSheet(shown: $0) }
        .confirmationDialog(Text("Remove \(removing?.name ?? "")?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) { if let id = removing?.id { Task { await model.remove(id) } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Their passkeys and invites go, and they’re signed out at once.") }
        .confirmationDialog(Text("Remove \(removingMac?.name ?? "")?"), isPresented: Binding(get: { removingMac != nil }, set: { if !$0 { removingMac = nil } })) {
            Button("Remove", role: .destructive) { if let id = removingMac?.id { Task { await model.removeDevice(id) } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("That Mac can’t reach this server any more. To join again, it needs a new invitation.") }
        .confirmationDialog(Text("Reset sign-in for \(resetting?.name ?? "")?"), isPresented: Binding(get: { resetting != nil }, set: { if !$0 { resetting = nil } })) {
            Button("Reset Sign-in") { if let id = resetting?.id { Task { shown = await model.reset(id) } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Their passkeys go, and you get a new invite link for them.") }
        .confirmationDialog(Text("Invite \(promoting?.name ?? "") to the team?"), isPresented: Binding(get: { promoting != nil }, set: { if !$0 { promoting = nil } })) {
            Button("Make Editor") { if let id = promoting?.id { Task { await model.setRole(id, "editor") } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("They become an editor: projects, versions, links and every comment, also internal ones.") }
        .confirmationDialog(Text("Start a new team?"), isPresented: $resettingTeam) {
            Button("Start a New Team", role: .destructive) { Task { await model.startNewTeam() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The team gets a new key and link. Everyone is signed out and needs a new invite.") }
    }

    @ViewBuilder private var content: some View {
        if let problem = model.problem { Text(verbatim: problem).font(Design.Studio.hint).foregroundStyle(Design.Studio.bad) }
        if admin, model.people.team?.id == nil, let name = model.restorable {
            SettingNote(text: Text("This server has no team. Restore “\(name)” so its links and passkeys keep working."), symbol: "arrow.counterclockwise.circle.fill") {
                Button("Restore Team") { Task { await model.restoreTeam() } }.buttonStyle(StudioFlatButtonStyle(prominent: true, height: 26))
            }.studioBox()
        }
        if DeliverPeople.oldBackup(publish) { SettingNote(text: Text("Update the backup server so people can sign in while the main is offline.")).studioBox() }
        if !admin {
            SettingNote(text: Text("This Mac is an editor. An admin changes roles and approves invites."), symbol: "pencil.circle.fill", colour: Design.Studio.textQuiet).studioBox()
        } else if !roles {
            SettingNote(text: Text("Update the server to give each Mac its own role. Until then every Mac is an admin."), symbol: "info.circle.fill", colour: Design.Studio.textQuiet).studioBox()
        }

        let requests = admin ? model.people.requests ?? [] : []
        let awaiting = admin ? model.awaiting : []
        if !requests.isEmpty || !awaiting.isEmpty {
            header("Waiting for you", count: requests.count + awaiting.count)
            VStack(spacing: 0) {
                ForEach(awaiting) { approvalRow($0) }
                ForEach(requests) { requestRow($0) }
            }.studioBox()
        }

        let team = model.team, macs = model.macs
        header("Team", count: team.count + macs.count)
        VStack(spacing: 0) {
            let admins = team.filter { $0.role == "owner" }, adminMacs = macs.filter(\.isAdmin)
            group("Admins")
            ForEach(admins) { personRows($0) }
            ForEach(adminMacs) { macRow($0) }
            let editors = team.filter { $0.role == "editor" }, editorMacs = macs.filter { !$0.isAdmin }
            group("Editors")
            ForEach(editors) { personRows($0) }
            ForEach(editorMacs) { macRow($0) }
            if editors.isEmpty && editorMacs.isEmpty { empty("No editors yet") }
        }
        .studioBox()

        let clients = model.clients
        header("Clients", count: clients.count)
        VStack(spacing: 0) {
            ForEach(clients) { clientRow($0) }
            if clients.isEmpty { empty("Clients who sign in on a review link show here") }
        }
        .studioBox()

        if DeliverClientPage.available { DeliverClientPagesSection() }

        if admin, model.people.team?.id != nil {
            header("Team settings")
            VStack(spacing: 0) {
                SettingRow("Team name") {
                    TextField("Team name", text: $teamName).settingField(width: 220)
                        .onSubmit { Task { await model.setTeam(name: teamName) } }
                }
                SettingSwitch("Editors can invite people",
                              help: model.people.approvals == 1 ? String(localized: "Each person an editor invites joins only once you approve them.") : nil,
                              isOn: Binding(get: { model.people.settings?.editorsInvite == true },
                                            set: { on in Task { await model.setTeam(editorsInvite: on) } }))
                SettingRow("New team key") {
                    Button("Start a New Team…") { resettingTeam = true }.settingButton()
                }
            }
            .studioBox()
        }

        let backups = model.devices.filter { !$0.isMac }
        if !backups.isEmpty {
            header("Servers")
            VStack(spacing: 0) {
                ForEach(backups) { device in
                    row(symbol: "externaldrive.badge.timemachine", name: device.name ?? "", seen: device.lastSeen) { EmptyView() } trailing: { EmptyView() }
                }
            }.studioBox()
        }
    }

    // MARK: Pieces

    private func header(_ title: LocalizedStringKey, count: Int? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title).font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
            if let count { Text(verbatim: "\(count)").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet) }
        }
        .padding(.top, 18).padding(.bottom, 4)
    }

    private func group(_ title: LocalizedStringKey) -> some View {
        Text(title).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 2)
    }

    private func empty(_ text: LocalizedStringKey) -> some View {
        Text(text).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
    }

    /// A row: symbol, name, its chips, then last seen and the trailing controls.
    private func row<Chips: View, Trailing: View>(symbol: String, name: String, seen: String?, @ViewBuilder chips: () -> Chips, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Design.Studio.textQuiet)
                .frame(width: 26, height: 26).background(Design.Studio.raised, in: .circle)
            Text(verbatim: name).font(Design.Studio.body).foregroundStyle(Design.Studio.text).lineLimit(1)
            chips()
            Spacer(minLength: 8)
            if let seen = DeliverPeople.date(seen) {
                Text("seen \(seen, format: .relative(presentation: .named))").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
            }
            trailing()
        }
        .padding(.horizontal, 12).frame(height: 44)
    }

    /// The role as a chip; for an admin it opens the team roles, each with what it may do.
    @ViewBuilder private func roleMenu(_ role: String, last: Bool, choose: @escaping (String) -> Void, @ViewBuilder more: () -> some View) -> some View {
        let chip = StudioChip(text: Text(verbatim: DeliverPeople.roleName(role)), symbol: DeliverPeople.roleSymbol(role))
        if admin {
            Menu {
                ForEach(["admin", "editor"], id: \.self) { option in
                    Button { choose(option) } label: {
                        Text(verbatim: (DeliverPeople.roleName(option) == DeliverPeople.roleName(role) ? "✓ " : "") + DeliverPeople.roleName(option))
                        Text(verbatim: DeliverPeople.roleHelp(option))
                    }
                    .disabled(last && option != "admin")
                }
                if last { Text("The team needs at least one admin.") }
                Divider()
                more()
            } label: {
                HStack(spacing: 4) {
                    chip
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Design.Studio.textQuiet)
                }.contentShape(.rect)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        } else {
            chip
        }
    }

    private func approvalRow(_ invite: Deliver.PersonInvite) -> some View {
        let person = model.people.people?.first { $0.id == invite.person }
        return row(symbol: "person.crop.circle.badge.clock", name: person?.name ?? "", seen: nil) {
            StudioChip(text: Text(verbatim: DeliverPeople.roleName(person?.role)), symbol: DeliverPeople.roleSymbol(person?.role))
            if let by = model.name(invite.by) { Text("invited by \(by)").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1) }
            if invite.waiting != nil { StudioChip(text: Text("Opened the link"), colour: Design.Studio.warn, tinted: true) }
        } trailing: {
            Button("Revoke") { Task { await model.cancelInvite(invite.id) } }.settingButton()
            Button("Approve") { Task { await model.approveInvite(invite.id) } }.buttonStyle(StudioFlatButtonStyle(prominent: true, height: 26))
        }
    }

    private func requestRow(_ request: Deliver.AccountRequest) -> some View {
        row(symbol: "person.crop.circle.badge.questionmark", name: request.name ?? "", seen: nil) {
            StudioChip(text: Text("Client"), symbol: DeliverPeople.roleSymbol("client"))
            if let email = request.email { Text(verbatim: email).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1) }
            if let title = DeliverStore.shared.links.first(where: { $0.id.uuidString == request.link })?.title { StudioChip(text: Text(verbatim: title), symbol: "link") }
        } trailing: {
            Button("Decline") { Task { await model.answer(request.id, accept: false) } }.settingButton()
            Button("Accept") { Task { await model.answer(request.id, accept: true) } }.buttonStyle(StudioFlatButtonStyle(prominent: true, height: 26))
        }
    }

    @ViewBuilder private func personRows(_ person: Deliver.Person) -> some View {
        let invite = model.people.invites?.first { $0.person == person.id }
        row(symbol: "person.fill", name: person.name ?? "", seen: person.lastSeen) {
            if invite != nil && !person.joined { StudioChip(text: Text("Invited"), colour: Design.Studio.warn, tinted: true) }
            if person.footage == true {
                Image(systemName: person.footageDownload == true ? "film.stack" : "film").font(.system(size: 11)).foregroundStyle(Design.Studio.textQuiet)
                    .help(person.footageDownload == true ? Text("Download Footage") : Text("Footage Access"))
            }
        } trailing: {
            roleMenu(person.role ?? "editor", last: model.lastAdmin(person), choose: { option in
                Task { await model.setRole(person.id, option == "admin" ? "owner" : option) }
            }) { personActions(person, invite: invite) }
        }
        passkeys(person)
    }

    @ViewBuilder private func personActions(_ person: Deliver.Person, invite: Deliver.PersonInvite?) -> some View {
        Toggle("Footage Access", isOn: Binding(get: { person.footage == true }, set: { on in Task { await model.update(person.id, ["footage": on]) } }))
        Toggle("Download Footage", isOn: Binding(get: { person.footageDownload == true }, set: { on in Task { await model.update(person.id, ["footageDownload": on]) } }))
            .disabled(person.footage != true)
        Divider()
        if let invite { Button("Cancel Invite") { Task { await model.cancelInvite(invite.id) } } }
        Button("Reset Sign-in…") { resetting = person }.disabled(model.lastAdmin(person))
        Button(person.role == "client" ? "Remove…" : "Remove from Team…", role: .destructive) { removing = person }.disabled(model.lastAdmin(person))
    }

    private func macRow(_ device: Deliver.PairedDevice) -> some View {
        let mine = device.id == main?.device
        return row(symbol: "desktopcomputer", name: device.name ?? "", seen: device.lastSeen) {
            if mine { StudioChip(text: Text("This Mac")) }
        } trailing: {
            if roles {
                roleMenu(device.isAdmin ? "admin" : "editor", last: model.lastAdmin(device), choose: { option in
                    Task { await model.setRole(device: device.id, option) }
                }) {
                    Button(mine ? "Leave This Server…" : "Remove…", role: .destructive) { removingMac = device }.disabled(model.lastAdmin(device))
                }
            } else {
                StudioChip(text: Text(verbatim: DeliverPeople.roleName("admin")), symbol: DeliverPeople.roleSymbol("admin"))
            }
        }
    }

    @ViewBuilder private func clientRow(_ person: Deliver.Person) -> some View {
        let invite = model.people.invites?.first { $0.person == person.id }
        let link = DeliverStore.shared.links.first { $0.id.uuidString == person.link }?.title
        row(symbol: "person", name: person.name ?? "", seen: person.lastSeen) {
            if let link { StudioChip(text: Text(verbatim: link), symbol: "link") } else { Text("Any link you share with them").font(Design.Studio.hint).foregroundStyle(Design.Studio.textFaint).lineLimit(1) }
            if invite != nil && !person.joined { StudioChip(text: Text("Invited"), colour: Design.Studio.warn, tinted: true) }
        } trailing: {
            if admin {
                Menu {
                    Button("Invite to the Team…") { promoting = person }
                    Divider()
                    if let invite { Button("Cancel Invite") { Task { await model.cancelInvite(invite.id) } } }
                    Button("Reset Sign-in…") { resetting = person }
                    Button("Remove…", role: .destructive) { removing = person }
                } label: { Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(Design.Studio.textQuiet).frame(width: 24, height: 24).contentShape(.rect) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
        }
        passkeys(person)
    }

    @ViewBuilder private func passkeys(_ person: Deliver.Person) -> some View {
        ForEach(person.passkeys ?? []) { key in
            HStack(spacing: 8) {
                Image(systemName: "key").font(.system(size: 10)).foregroundStyle(Design.Studio.textFaint).frame(width: 16)
                Text(verbatim: key.label ?? "").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                if let used = DeliverPeople.date(key.lastUsed) {
                    Text("used \(used, format: .relative(presentation: .named))").font(Design.Studio.hint).foregroundStyle(Design.Studio.textFaint)
                }
                if model.people.locked?.contains(key.id) == true { StudioChip(text: Text("Sign-in locked"), symbol: "lock", colour: Design.Studio.warn, tinted: true) }
                Spacer()
                if admin {
                    Button { Task { await model.removePasskey(key.id, of: person.id) } } label: {
                        Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(Design.Studio.textQuiet).frame(width: 24, height: 24).contentShape(.rect)
                    }
                    .buttonStyle(.plain).help("Remove Passkey").disabled(model.lastAdmin(person) && person.passkeys?.count == 1)
                }
            }
            .padding(.leading, 48).padding(.trailing, 12).frame(height: 24)
        }
    }
}

// MARK: - Choosing a role

/// The roles to choose from, each with its one line (Invite…, Invite a Teammate).
struct DeliverRolePicker: View {
    let options: [String]
    @Binding var selection: String

    var body: some View {
        VStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selection == option ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 13)).foregroundStyle(selection == option ? Design.Studio.text : Design.Studio.textFaint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: DeliverPeople.roleName(option)).font(Design.Studio.body).foregroundStyle(Design.Studio.text)
                            Text(verbatim: DeliverPeople.roleHelp(option)).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).frame(height: 44).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .background(selection == option ? Design.Studio.raised : .clear, in: .rect(cornerRadius: Design.Studio.controlRadius))
            }
        }
        .padding(4)
    }
}

// MARK: - Transfer Admin

/// Transfer Admin…: pick a teammate (a person with a passkey, or a Mac) to become an admin, and whether this Mac then
/// steps down to editor. The main keeps at least one admin either way.
struct DeliverTransferAdminSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = DeliverPeople.shared
    @State private var chosen: DeliverPeople.Member?
    @State private var stepDown = true
    @State private var working = false

    private var people: [Deliver.Person] { model.team.filter { $0.role != "owner" && $0.joined } }
    private var macs: [Deliver.PairedDevice] { model.macs.filter { !$0.isAdmin } }
    /// The one picked, else the first who can be.
    private var pick: DeliverPeople.Member? { chosen ?? people.first.map { .person($0.id) } ?? macs.first.map { .mac($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transfer Admin").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
            Text(verbatim: DeliverPeople.roleHelp("admin")).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            VStack(spacing: 0) {
                ForEach(people) { option(.person($0.id), symbol: "person.fill", name: $0.name ?? "", seen: $0.lastSeen) }
                ForEach(macs) { option(.mac($0.id), symbol: "desktopcomputer", name: $0.name ?? "", seen: $0.lastSeen) }
                if people.isEmpty && macs.isEmpty {
                    Text("Everyone on the team is an admin already. Invite an editor or a Mac first.").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).padding(12)
                }
            }
            .padding(4)
            .studioBox()
            SettingSwitch("Make this Mac an editor afterwards", isOn: $stepDown).studioBox()
            if let problem = model.problem { Text(verbatim: problem).font(Design.Studio.hint).foregroundStyle(Design.Studio.bad).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(StudioFlatButtonStyle())
                Button("Transfer") {
                    guard let chosen = pick else { return }
                    working = true
                    Task {
                        if await model.transfer(to: chosen, stepDown: stepDown) { dismiss() }
                        working = false
                    }
                }
                .buttonStyle(StudioFlatButtonStyle(prominent: true)).keyboardShortcut(.defaultAction).disabled(pick == nil || working)
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 480)
        .background(Design.Studio.panel)
    }

    private func option(_ member: DeliverPeople.Member, symbol: String, name: String, seen: String?) -> some View {
        Button { chosen = member } label: {
            HStack(spacing: 10) {
                Image(systemName: pick == member ? "largecircle.fill.circle" : "circle").font(.system(size: 13))
                    .foregroundStyle(pick == member ? Design.Studio.text : Design.Studio.textFaint)
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Design.Studio.textQuiet)
                    .frame(width: 24, height: 24).background(Design.Studio.raised, in: .circle)
                Text(verbatim: name).font(Design.Studio.body).foregroundStyle(Design.Studio.text).lineLimit(1)
                StudioChip(text: Text(verbatim: DeliverPeople.roleName("editor")), symbol: DeliverPeople.roleSymbol("editor"))
                Spacer()
                if let seen = DeliverPeople.date(seen) {
                    Text("seen \(seen, format: .relative(presentation: .named))").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                }
            }
            .padding(.horizontal, 10).frame(height: 40).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(pick == member ? Design.Studio.raised : .clear, in: .rect(cornerRadius: Design.Studio.controlRadius))
    }
}

// MARK: - Invite

/// Invite…: name, role (each with its one line) and the footage switch, then the link once (QR, Copy, expiry). Reset
/// sign-in opens it at the link. An editor Mac invites clients and editors, for an admin to approve.
struct DeliverPersonInviteSheet: View {
    @State var shown: DeliverPeople.OneTimeLink?
    @Environment(\.dismiss) private var dismiss
    @State private var model = DeliverPeople.shared
    @State private var name = ""
    @State private var role = "client"
    @State private var footage = false
    @State private var working = false
    @State private var copied = false

    private var admin: Bool { DeliverPeople.isAdmin(DeliverPeople.main()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Invite").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
            if let shown {
                HStack(alignment: .top, spacing: 16) {
                    if let image = DeliverLinkShare.qr(shown.link) {
                        Image(nsImage: image).interpolation(.none).resizable().frame(width: 140, height: 140)
                            .padding(8).background(.white, in: .rect(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: shown.link).font(Design.Studio.hint.monospaced()).foregroundStyle(Design.Studio.text).lineLimit(2).truncationMode(.middle)
                        Button { DeliverLinkShare.copy(shown.link); copied = true } label: {
                            Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }.buttonStyle(StudioFlatButtonStyle(prominent: true))
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            if shown.expires <= context.date {
                                Text("This invitation has expired. Make another.").font(Design.Studio.hint).foregroundStyle(Design.Studio.warn)
                            } else {
                                Text("Valid until \(shown.expires.formatted(date: .abbreviated, time: .shortened)) (\(shown.expires, format: .relative(presentation: .named)))")
                                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                            }
                        }
                        Text(shown.pending ? "It works once an admin approves it." : "Shown once. It works once, for this person.").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    SettingRow("Name") { TextField(text: $name, prompt: Text(verbatim: "Anna Berg")) { Text("Name") }.settingField(width: 220) }
                }
                .studioBox()
                DeliverRolePicker(options: admin ? ["client", "editor", "owner"] : ["client", "editor"], selection: $role).studioBox()
                if admin { SettingSwitch("Can browse footage (read-only)", isOn: $footage).studioBox() }
            }
            if let problem = model.problem { Text(verbatim: problem).font(Design.Studio.hint).foregroundStyle(Design.Studio.bad).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                if shown == nil {
                    Button("Cancel") { dismiss() }.buttonStyle(StudioFlatButtonStyle())
                    Button("Invite") {
                        working = true
                        Task { shown = await model.invite(name: name, role: role, footage: footage && admin); working = false }
                    }
                    .buttonStyle(StudioFlatButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    Button("Done") { dismiss() }.buttonStyle(StudioFlatButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 480)
        .background(Design.Studio.panel)
    }
}
