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
        var frozen: Bool?
        var locked: Bool?
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
    struct PersonInvite: Codable, Hashable, Identifiable { var id: String; var person: String?; var kind: String?; var expires: String? }
    struct AccountRequest: Codable, Hashable, Identifiable { var id: String; var name: String?; var email: String?; var link: String?; var at: String? }
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
        } catch {
            problem = Self.problem(error)
        }
    }

    /// A `people` answer (here, or from a sync round): the model, and a notification for each request not seen before.
    func heard(_ answer: [String: Any]) {
        guard let decoded = Self.decode(Deliver.People.self, answer) else { return }
        people = decoded
        let seen = Set(UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? [])
        let requests = decoded.requests ?? []
        for request in requests where !seen.contains(request.id) { Self.notify(request) }
        UserDefaults.standard.set(requests.map(\.id), forKey: Self.seenKey)
    }

    private static func notify(_ request: Deliver.AccountRequest) {
        guard ScreenshotMode.scene == nil else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(request.name ?? "") asks for an account")
        content.body = request.email ?? ""
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "review-request-" + request.id, content: content, trigger: nil))
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
        if people.team?.id == nil {
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
                                   "requests": [["id": "r1", "name": "Alex Kim", "email": "alex@example.com", "link": "", "at": iso(1800)]], "frozen": false, "locked": false]
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
    }

    @ViewBuilder private var content: some View {
        if let problem = model.problem { Text(verbatim: problem).font(Design.Studio.hint).foregroundStyle(Design.Studio.bad) }
        if model.people.frozen == true { SettingNote(text: Text("Invites are paused for 15 minutes: too many wrong codes.")).studioBox() }
        if model.people.locked == true { SettingNote(text: Text("Sign-in is locked for 15 minutes: too many failed attempts.")).studioBox() }
        if DeliverPeople.oldBackup(publish) { SettingNote(text: Text("Update the backup server so people can sign in while the main is offline.")).studioBox() }

        let requests = model.people.requests ?? []
        if !requests.isEmpty {
            header("Requests")
            VStack(spacing: 0) { ForEach(requests) { requestRow($0) } }.studioBox()
        }

        Color.clear.frame(height: requests.isEmpty ? 0 : 14)
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
                SettingSwitch("Editors can invite people", isOn: Binding(get: { model.people.settings?.editorsInvite == true },
                                                                         set: { on in Task { await model.setTeam(editorsInvite: on) } }))
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
