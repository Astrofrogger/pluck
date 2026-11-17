import SwiftUI
import UserNotifications

// People (accounts plan 2026-11-17 §3, §5): the main server's team, everyone on it with their passkeys, open invites,
// requests from review links and the paired devices, in one place. The main does everything (sync ops, role mac);
// this Mac only asks and shows. Invite links are shown once and never kept here.

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
    struct PairedDevice: Codable, Hashable, Identifiable { var id: String; var name: String?; var role: String?; var lastSeen: String? }
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

    func name(_ person: String?) -> String? { people.people?.first { $0.id == person }?.name }

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
        var id: String { link }
        init?(_ answer: [String: Any]?) {
            guard let link = answer?["link"] as? String else { return nil }
            self.link = link
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

    static func roleName(_ role: String?) -> String {
        switch role {
        case "owner": String(localized: "Owner")
        case "editor": String(localized: "people.role.editor", defaultValue: "Editor")
        default: String(localized: "Client")
        }
    }

    /// Screenshots: a stand-in main with two people, a request and two devices.
    static func snapshot() {
        let fingerprint = Array(repeating: "AB", count: 32).joined(separator: ":"), day: TimeInterval = 86_400
        let iso = { (ago: TimeInterval) in ISO8601DateFormatter().string(from: .now.addingTimeInterval(-ago)) }
        ReviewHostClient.fakeFingerprint = fingerprint
        ReviewHostClient.fake = { request, _ in
            switch request["op"] as? String {
            case nil: return ["ok": true, "accounts": 1]
            case "people": return ["team": ["id": "t1", "name": "Northwind Films", "link": "https://pluck.tools/r/#k.p"], "settings": ["editorsInvite": false],
                                   "people": [["id": "p1", "name": "Anna Berg", "role": "editor", "footage": true, "passkeys": [
                                                  ["id": "c1", "label": "Safari on Mac", "added": iso(9 * day), "lastUsed": iso(3600)],
                                                  ["id": "c2", "label": "Chrome on Android", "added": iso(4 * day), "lastUsed": iso(2 * day)]]],
                                              ["id": "p2", "name": "Sam Lee", "role": "client", "passkeys": [["id": "c3", "label": "Safari on iPhone", "added": iso(day), "lastUsed": iso(day)]]],
                                              ["id": "p3", "name": "Jo Park", "role": "editor", "passkeys": []]],
                                   "invites": [["id": "i1", "person": "p3", "kind": "invite", "expires": ISO8601DateFormatter().string(from: .now.addingTimeInterval(6 * day))]],
                                   "requests": [["id": "r1", "name": "Alex Kim", "email": "alex@example.com", "link": "", "at": iso(1800)]], "locked": ["c2"]]
            case "devices": return ["devices": [["id": "d1", "name": "Edit Suite iMac", "role": "mac", "lastSeen": iso(600)],
                                                ["id": "b1", "name": "Backup NAS", "role": "backup", "lastSeen": iso(60)]]]
            default: return ["ok": true]
            }
        }
        if var host = ReviewPublish.shared.addNAS(name: "Studio NAS", address: "studio-nas.test:8790", pairing: "pluck-host:\(DeliverKeys.base64url(DeliverKeys.random(32)))@\(fingerprint)") {
            host.role = "main"
            host.accounts = 1
            ReviewPublish.shared.add(host)
            testMain = host.id
        }
    }
}

// MARK: - The page

struct DeliverPeopleView: View {
    @State private var model = DeliverPeople.shared
    @State private var publish = ReviewPublish.shared
    @State private var inviting = false
    @State private var shown: DeliverPeople.OneTimeLink?
    @State private var removing: Deliver.Person?
    @State private var resetting: Deliver.Person?
    @State private var teamName = ""
    @State private var copied = false
    @State private var resettingTeam = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(DeliverPeople.title).font(Design.Studio.pageTitle).foregroundStyle(Design.Studio.text)
                    Spacer()
                    if DeliverPeople.shown(DeliverPeople.main(publish)) == .on {
                        if let link = model.people.team?.link {
                            Button { DeliverLinkShare.copy(link); copied = true } label: {
                                Label(copied ? "Copied" : "Copy Team Link", systemImage: copied ? "checkmark" : "link")
                            }.buttonStyle(StudioFlatButtonStyle())
                        }
                        Button { inviting = true } label: { Label("Invite…", systemImage: "person.badge.plus") }.buttonStyle(StudioFlatButtonStyle(prominent: true))
                    }
                }
                .padding(.bottom, 12)
                switch DeliverPeople.shown(DeliverPeople.main(publish)) {
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
        .sheet(item: $shown) { DeliverPersonInviteSheet(shown: $0) }
        .confirmationDialog(Text("Remove \(removing?.name ?? "")?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) { if let id = removing?.id { Task { await model.remove(id) } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Their passkeys and invites go, and they’re signed out at once.") }
        .confirmationDialog(Text("Reset sign-in for \(resetting?.name ?? "")?"), isPresented: Binding(get: { resetting != nil }, set: { if !$0 { resetting = nil } })) {
            Button("Reset Sign-in") { if let id = resetting?.id { Task { shown = await model.reset(id) } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Their passkeys go, and you get a new invite link for them.") }
        .confirmationDialog(Text("Start a new team?"), isPresented: $resettingTeam) {
            Button("Start a New Team", role: .destructive) { Task { await model.startNewTeam() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The team gets a new key and link. Everyone is signed out and needs a new invite.") }
    }

    @ViewBuilder private var content: some View {
        if let problem = model.problem { Text(verbatim: problem).font(Design.Studio.hint).foregroundStyle(Design.Studio.bad) }
        if model.people.team?.id == nil, let name = model.restorable {
            SettingNote(text: Text("This server has no team. Restore “\(name)” so its links and passkeys keep working."), symbol: "arrow.counterclockwise.circle.fill") {
                Button("Restore Team") { Task { await model.restoreTeam() } }.buttonStyle(StudioFlatButtonStyle(prominent: true, height: 26))
            }.studioBox()
        }
        if DeliverPeople.oldBackup(publish) { SettingNote(text: Text("Update the backup server so people can sign in while the main is offline.")).studioBox() }

        let requests = model.people.requests ?? []
        if !requests.isEmpty {
            header("Requests")
            VStack(spacing: 0) { ForEach(requests) { requestRow($0) } }.studioBox()
        }

        let awaiting = model.awaiting
        if !awaiting.isEmpty {
            header("Waiting for approval")
            VStack(spacing: 0) { ForEach(awaiting) { approvalRow($0) } }.studioBox()
        }

        Color.clear.frame(height: requests.isEmpty && awaiting.isEmpty ? 0 : 14)
        VStack(spacing: 0) {
            ForEach(model.people.people ?? []) { person in personRows(person) }
            if (model.people.people ?? []).isEmpty { Text("No one yet").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).padding(10) }
        }
        .studioBox()

        if model.people.team?.id != nil {
            header("Team")
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

        header("Devices")
        VStack(spacing: 0) {
            ForEach(model.devices) { device in
                HStack(spacing: 8) {
                    Image(systemName: device.role == "backup" ? "externaldrive.badge.timemachine" : "laptopcomputer").foregroundStyle(Design.Studio.textQuiet).frame(width: 16)
                    Text(verbatim: device.name ?? "").font(Design.Studio.body).foregroundStyle(Design.Studio.text).lineLimit(1)
                    Spacer()
                    if let seen = DeliverPeople.date(device.lastSeen) {
                        Text("seen \(seen, format: .relative(presentation: .named))").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                    }
                }
                .padding(.horizontal, 12).frame(height: 36)
            }
            if model.devices.isEmpty { Text("None yet").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).padding(10) }
        }
        .studioBox()
    }

    private func header(_ title: LocalizedStringKey) -> some View {
        Text(title).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).padding(.top, 14).padding(.bottom, 2)
    }

    private func requestRow(_ request: Deliver.AccountRequest) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.questionmark").foregroundStyle(Design.Studio.textQuiet).frame(width: 16)
            Text(verbatim: request.name ?? "").font(Design.Studio.body).foregroundStyle(Design.Studio.text).lineLimit(1)
            if let email = request.email { Text(verbatim: email).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1) }
            if let title = DeliverStore.shared.links.first(where: { $0.id.uuidString == request.link })?.title {
                StudioChip(text: Text(verbatim: title), symbol: "link")
            }
            Spacer()
            Button("Decline") { Task { await model.answer(request.id, accept: false) } }.settingButton()
            Button("Accept") { Task { await model.answer(request.id, accept: true) } }.buttonStyle(StudioFlatButtonStyle(prominent: true, height: 26))
        }
        .padding(.horizontal, 12).frame(height: 40)
    }

    private func approvalRow(_ invite: Deliver.PersonInvite) -> some View {
        let person = model.people.people?.first { $0.id == invite.person }
        return HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.clock").foregroundStyle(Design.Studio.textQuiet).frame(width: 16)
            Text(verbatim: person?.name ?? "").font(Design.Studio.body).foregroundStyle(Design.Studio.text).lineLimit(1)
            StudioChip(text: Text(verbatim: DeliverPeople.roleName(person?.role)))
            if let by = model.name(invite.by) { Text("invited by \(by)").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1) }
            if invite.waiting != nil { StudioChip(text: Text("Opened the link"), colour: Design.Studio.warn, tinted: true) }
            Spacer()
            Button("Revoke") { Task { await model.cancelInvite(invite.id) } }.settingButton()
            Button("Approve") { Task { await model.approveInvite(invite.id) } }.buttonStyle(StudioFlatButtonStyle(prominent: true, height: 26))
        }
        .padding(.horizontal, 12).frame(height: 40)
    }

    @ViewBuilder private func personRows(_ person: Deliver.Person) -> some View {
        let invite = model.people.invites?.first { $0.person == person.id }
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle").foregroundStyle(Design.Studio.textQuiet).frame(width: 16)
            Text(verbatim: person.name ?? "").font(Design.Studio.body).foregroundStyle(Design.Studio.text).lineLimit(1)
            StudioChip(text: Text(verbatim: DeliverPeople.roleName(person.role)))
            if person.footage == true {
                Image(systemName: person.footageDownload == true ? "film.stack" : "film").font(.system(size: 11)).foregroundStyle(Design.Studio.textQuiet)
                    .help(person.footageDownload == true ? Text("Download Footage") : Text("Footage Access"))
            }
            if invite != nil { StudioChip(text: Text("Invited"), colour: Design.Studio.warn, tinted: true) }
            Spacer()
            Menu {
                Menu("Change Role") {
                    ForEach(["client", "editor", "owner"], id: \.self) { role in
                        Button { Task { await model.update(person.id, ["role": role]) } } label: {
                            if person.role == role { Label(DeliverPeople.roleName(role), systemImage: "checkmark") } else { Text(verbatim: DeliverPeople.roleName(role)) }
                        }
                    }
                }
                Toggle("Footage Access", isOn: Binding(get: { person.footage == true }, set: { on in Task { await model.update(person.id, ["footage": on]) } }))
                Toggle("Download Footage", isOn: Binding(get: { person.footageDownload == true }, set: { on in Task { await model.update(person.id, ["footageDownload": on]) } }))
                    .disabled(person.footage != true)
                Divider()
                if let invite { Button("Cancel Invite") { Task { await model.cancelInvite(invite.id) } } }
                Button("Reset Sign-in…") { resetting = person }
                Button("Remove…", role: .destructive) { removing = person }
            } label: { Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(Design.Studio.textQuiet).frame(width: 24, height: 24).contentShape(.rect) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 12).frame(height: 36)
        ForEach(person.passkeys ?? []) { key in
            HStack(spacing: 8) {
                Image(systemName: "key").font(.system(size: 11)).foregroundStyle(Design.Studio.textFaint).frame(width: 16)
                Text(verbatim: key.label ?? "").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                if let used = DeliverPeople.date(key.lastUsed) {
                    Text("used \(used, format: .relative(presentation: .named))").font(Design.Studio.hint).foregroundStyle(Design.Studio.textFaint)
                }
                if model.people.locked?.contains(key.id) == true { StudioChip(text: Text("Sign-in locked"), symbol: "lock", colour: Design.Studio.warn, tinted: true) }
                Spacer()
                Button { Task { await model.removePasskey(key.id, of: person.id) } } label: {
                    Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(Design.Studio.textQuiet).frame(width: 24, height: 24).contentShape(.rect)
                }
                .buttonStyle(.plain).help("Remove Passkey")
            }
            .padding(.leading, 36).padding(.trailing, 12).frame(height: 26)
        }
    }
}

// MARK: - Invite

/// Invite…: name, role and the footage switch, then the link once (QR, Copy, expiry). Reset sign-in opens it at the link.
struct DeliverPersonInviteSheet: View {
    @State var shown: DeliverPeople.OneTimeLink?
    @Environment(\.dismiss) private var dismiss
    @State private var model = DeliverPeople.shared
    @State private var name = ""
    @State private var role = "client"
    @State private var footage = false
    @State private var working = false
    @State private var copied = false

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
                        Text("Shown once. It works once, for this person.").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    SettingRow("Name") { TextField(text: $name, prompt: Text(verbatim: "Anna Berg")) { Text("Name") }.settingField(width: 220) }
                    SettingRow("Role") {
                        SettingMenu(title: DeliverPeople.roleName(role), selection: $role) {
                            ForEach(["client", "editor", "owner"], id: \.self) { Text(verbatim: DeliverPeople.roleName($0)).tag($0) }
                        }
                    }
                    SettingSwitch("Can browse footage (read-only)", isOn: $footage)
                }
                .studioBox()
            }
            if let problem = model.problem { Text(verbatim: problem).font(Design.Studio.hint).foregroundStyle(Design.Studio.bad).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                if shown == nil {
                    Button("Cancel") { dismiss() }.buttonStyle(StudioFlatButtonStyle())
                    Button("Invite") {
                        working = true
                        Task { shown = await model.invite(name: name, role: role, footage: footage); working = false }
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
