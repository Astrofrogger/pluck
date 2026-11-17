import Foundation

extension PhotoSelfTest {
    /// People in Deliver (accounts plan §9 step 6, -PluckScreenshotOnly reviewpeople): the account token vector, People
    /// only on a main that says `accounts: 1`, the owner seeing every account and device, the ops removing sends, an
    /// invite link that is only ever in the sheet, and editors' invites waiting for approval. A stand-in main answers in this process.
    static func reviewPeopleTest() async {
        // docs/superpowers/plans/accounts-vectors.json: teamId, personId → accountToken.
        let token = DeliverKeys.sha256(Data("pluck-account/1 token VVVVVVVVVVVVVVVVVVVVVQ/8A4C1E2B-0000-4000-8000-000000000001".utf8))
        check("review: account token vector", token == "LMwKfhqVhU_ilnGtpvB0iPcJHHVhqv1hTRhFgMV3kZk", token)

        final class Main {
            var accounts: Int?
            var roles: [String: Any] = [:]
            var team: Any = ["id": "t1", "name": "Northwind Films", "link": "https://pluck.tools/r/#k.p"]
            var ops: [[String: Any]] = []
            var invites: [[String: Any]] = []
            var export = false
            var restored: [String: Any]?
            var more: [[String: Any]] = []
            var requests: [[String: Any]] = [["id": "r1", "name": "Alex Kim", "email": "alex@example.com", "link": "L1", "at": ISO8601DateFormatter().string(from: .now)]]
        }
        let main = Main(), fingerprint = Array(repeating: "CD", count: 32).joined(separator: ":")
        let iso = ISO8601DateFormatter().string(from: .now)
        let saved = (ReviewHostClient.fake, ReviewHostClient.fakeFingerprint)
        ReviewHostClient.fakeFingerprint = fingerprint
        ReviewHostClient.fake = { request, _ in
            guard let op = request["op"] as? String else { return main.accounts.map { ["ok": true, "accounts": $0].merging(main.roles) { $1 } } ?? ["ok": true] }
            main.ops.append(request)
            switch op {
            case "people":
                return ["team": main.team, "settings": ["editorsInvite": false],
                        "people": [["id": "p1", "userId": "u1", "name": "Anna Berg", "role": "editor", "footage": true, "added": iso, "by": "mac",
                                    "passkeys": [["id": "c1", "label": "Safari on Mac", "added": iso, "lastUsed": iso, "count": 0],
                                                 ["id": "c2", "label": "Chrome on Android", "added": iso, "lastUsed": iso, "count": 0]]],
                                   ["id": "p2", "userId": "u2", "name": "Sam Lee", "role": "client", "footage": false, "added": iso, "by": "mac",
                                    "passkeys": [["id": "c3", "label": "Safari on iPhone", "added": iso, "lastUsed": NSNull(), "count": 0]]]] + main.more,
                        "invites": [["id": "i1", "person": "p2", "kind": "device", "by": "p2", "expires": iso]] + main.invites,
                        "used": [], "requests": main.requests, "locked": ["c3"], "approvals": 1]
            case "request-accept", "request-decline": main.requests = []; return ["ok": true] // accepted ones are deleted, declined ones aren't listed
            case "devices": return ["devices": [["id": "d1", "name": "Edit Mac", "role": "mac", "access": "admin", "lastSeen": iso], ["id": "b1", "name": "Backup NAS", "role": "backup", "lastSeen": iso]]]
            case "team-set": main.team = ["id": "t1", "name": "Northwind Films", "link": "https://pluck.tools/r/#k.p"]; return ["ok": true, "link": "https://pluck.tools/r/#k.p"]
            case "team-export" where main.export:
                return main.team is NSNull ? ["error": "notFound"] : ["format": 1, "team": ["id": "t1", "name": "Northwind Films", "room": ["pub": "P1"]], "settings": ["editorsInvite": true]]
            case "team-restore":
                main.restored = request["accounts"] as? [String: Any]
                main.team = ["id": "t1", "name": "Northwind Films", "link": "https://pluck.tools/r/#k.p"]
                return ["ok": true]
            case "person-invite": return ["person": "p9", "link": "https://pluck.tools/r/#k.p/i/ABCDEFGHJKMNPQRS", "expires": iso]
            default: return ["ok": true]
            }
        }
        let publish = ReviewPublish.shared, model = DeliverPeople.shared
        guard let host = publish.addNAS(name: "People NAS", address: "people-nas.test:8790", pairing: "pluck-host:\(DeliverKeys.base64url(DeliverKeys.random(32)))@\(fingerprint)") else {
            return check("review: People host", false, "")
        }
        publish.update(host: host.id) { $0.role = "main" }
        DeliverPeople.testMain = host.id
        defer {
            DeliverPeople.testMain = nil
            publish.removeHost(host.id)
            (ReviewHostClient.fake, ReviewHostClient.fakeFingerprint) = saved
        }

        // A 4.0.3 main: its hello has no `accounts`, so no People (only the note) and `people` is never asked.
        await model.load()
        let old = DeliverPeople.shown(DeliverPeople.main())
        main.accounts = 1
        await model.load()
        let now = DeliverPeople.shown(DeliverPeople.main())
        check("review: People appears only with accounts: 1", old == .update && now == .on && DeliverPeople.shown(nil) == .hidden
              && main.ops.filter { $0["op"] as? String == "people" }.count == 1, "\(old) \(now) \(main.ops.map { $0["op"] ?? "" })")

        // S-1: every person, passkey, open invite, request and device is in the model.
        let people = model.people.people ?? []
        check("review: S-1 the owner sees every account and device", people.map(\.id) == ["p1", "p2"] && people.flatMap { $0.passkeys ?? [] }.map(\.id) == ["c1", "c2", "c3"]
              && model.people.invites?.map(\.id) == ["i1"] && model.people.requests?.first?.email == "alex@example.com" && model.pending == 1
              && model.devices.map(\.id) == ["d1", "b1"] && model.people.locked == ["c3"] && model.people.team?.name == "Northwind Films"
              && people.first?.footage == true && DeliverPeople.roleName(people.first?.role) == DeliverPeople.roleName("editor"),
              "\(people.map(\.id)) \(model.devices.map(\.id))")

        // S-2: removing and answering send the right op with the right ids.
        main.ops = []
        await model.remove("p2")
        await model.removePasskey("c1", of: "p1")
        await model.answer("r1", accept: true)
        await model.update("p1", ["footageDownload": true])
        _ = await model.reset("p1")
        let sent = main.ops.filter { !["people", "devices"].contains($0["op"] as? String ?? "") }.map { op in
            ["op", "id", "person"].compactMap { op[$0] as? String }.joined(separator: " ")
        }
        let reloads = main.ops.compactMap { $0["op"] as? String }.split { $0 != "people" && $0 != "devices" }.count
        let footage = main.ops.first { $0["op"] as? String == "person-update" }
        check("review: S-2 remove sends the right op", sent == ["person-remove p2", "passkey-remove c1 p1", "request-accept r1", "person-update p1", "person-reset p1"]
              && footage?["footageDownload"] as? Bool == true && footage?.count == 3, "\(sent) \(String(describing: footage))")
        // M2/L3: the list is read again after each change (remove and reset delete more on the host); an accepted request goes.
        check("review: People reloads after every change; an accepted request leaves the list", reloads == 5 && model.pending == 0
              && main.ops.last?["op"] as? String == "devices", "\(main.ops.compactMap { $0["op"] as? String })")
        // The old `locked: true` (a Bool) or any odd field can't empty the whole answer.
        let odd = DeliverPeople.decode(Deliver.People.self, ["locked": true, "people": [["id": "p1", "name": "Anna Berg"]], "frozen": false, "requests": "x"])
        check("review: people decodes with a changed field", odd?.people?.first?.name == "Anna Berg" && odd?.locked == nil && odd?.requests == nil, "\(String(describing: odd))")
        // L7: request notifications at most once a minute, several in one.
        let t = Date.now.addingTimeInterval(10_000), before = model.posted.count
        model.announce([.init(id: "q1", name: "Lee Wong")], now: t)
        model.announce([.init(id: "q2", name: "Kai Moss")], now: t.addingTimeInterval(10))
        model.announce([.init(id: "q3", name: "Ana Diaz")], now: t.addingTimeInterval(20))
        let within = model.posted.count - before
        model.flushNotice(t.addingTimeInterval(61))
        let posts = Array(model.posted.suffix(model.posted.count - before))
        check("review: request notifications at most one a minute", within == 1 && posts.count == 2 && posts[0].contains("Lee Wong")
              && posts[1] == String(localized: "\(2) new account requests"), "\(posts)")

        // Invite with no team yet: the team first, then the person; the link comes back once and the model never keeps it.
        main.team = NSNull()
        await model.load()
        main.ops = []
        let link = await model.invite(name: "Jo Park", role: "editor", footage: false)
        let writes = main.ops.compactMap { $0["op"] as? String }.filter { !["people", "devices"].contains($0) }
        let invite = main.ops.first { $0["op"] as? String == "person-invite" }
        let kept = String(decoding: (try? JSONEncoder().encode(model.people)) ?? Data(), as: UTF8.self) + "\(model.devices)" + (model.problem ?? "")
        check("review: invite sheet shows the link once", link?.link.hasSuffix("/i/ABCDEFGHJKMNPQRS") == true && link?.expires != nil
              && writes == ["team-set", "person-invite"] && invite?["name"] as? String == "Jo Park" && invite?["role"] as? String == "editor"
              && invite?["footage"] as? Bool == false && !kept.contains("/i/"), "\(writes) \(String(describing: link))")

        // Editors invite, an admin approves: an editor's invite waits in its own list (who invited, opened or not), Approve
        // and Revoke send their ops, and it notifies once as waiting for approval.
        let pending = "i-\(UUID().uuidString)"
        main.more = [["id": "p3", "userId": "u3", "name": "Jo Park", "role": "editor", "footage": false, "added": iso, "by": "p1", "passkeys": []]]
        main.invites = [["id": pending, "person": "p3", "kind": "invite", "by": "p1", "expires": iso, "approval": "pending", "waiting": iso]]
        let notices = model.posted.count
        await model.load()
        model.flushNotice(Date.now.addingTimeInterval(20_000))
        let waiting = model.awaiting
        main.ops = []
        await model.approveInvite(pending)
        await model.cancelInvite(pending)
        let answered = main.ops.compactMap { op in (op["op"] as? String).flatMap { ["invite-approve", "invite-cancel"].contains($0) ? "\($0) \(op["id"] ?? "")" : nil } }
        check("review: editors' invites wait for approval; Approve and Revoke send their ops", waiting.map(\.id) == [pending] && model.name(waiting.first?.by) == "Anna Berg"
              && waiting.first?.waiting != nil && model.people.approvals == 1 && answered == ["invite-approve \(pending)", "invite-cancel \(pending)"],
              "\(waiting.map(\.id)) \(answered)")
        let posted = Array(model.posted.suffix(model.posted.count - notices))
        check("review: an editor's invite notifies as waiting for approval", posted == [String(localized: "\("Jo Park") is waiting for your approval")], "\(posted)")

        // The team's identity: kept in this Mac's vault while the main has it; a wiped main gets the same team back
        // (restore, not a new team-set) on the next invite or "Restore Team"; "Start a New Team" sends team-reset.
        DeliverKeychain.delete(DeliverPeople.teamAccount, service: DeliverPeople.teamService)
        main.export = true
        model.exported = nil
        main.team = ["id": "t1", "name": "Northwind Films", "link": "https://pluck.tools/r/#k.p"]
        await model.load()
        let keptTeam = DeliverPeople.savedTeam()?["team"] as? [String: Any]
        main.team = NSNull()
        await model.load()
        let offered = model.restorable
        main.ops = []
        _ = await model.invite(name: "Kai Moss", role: "client", footage: false)
        await model.startNewTeam()
        let teamOps = main.ops.compactMap { $0["op"] as? String }.filter { !["people", "devices", "team-export"].contains($0) }
        check("review: the team is kept on this Mac and put back on a wiped main", keptTeam?["id"] as? String == "t1" && keptTeam?["room"] != nil
              && offered == "Northwind Films" && (main.restored?["team"] as? [String: Any])?["id"] as? String == "t1"
              && teamOps == ["team-restore", "person-invite", "team-reset"], "\(String(describing: keptTeam)) \(String(describing: offered)) \(teamOps)")
        DeliverKeychain.delete(DeliverPeople.teamAccount, service: DeliverPeople.teamService)

        // Roles (4.0.5): the team is admins and editors (people and Macs); clients are apart. A server before roles makes
        // every Mac an admin; one with roles says this Mac's access, and an editor Mac isn't one.
        main.team = ["id": "t1", "name": "Northwind Films", "link": "https://pluck.tools/r/#k.p"]
        main.invites = []
        main.more = [["id": "p4", "userId": "u4", "name": "Kai Moss", "role": "owner", "added": iso, "by": "mac", "passkeys": [["id": "c9", "label": "Safari on Mac"]]]]
        await model.load()
        let allAdmin = DeliverPeople.isAdmin(DeliverPeople.main()) && !DeliverPeople.roles(DeliverPeople.main())
        main.roles = ["roles": 1, "access": "editor"]
        await model.load()
        let editorMac = !DeliverPeople.isAdmin(DeliverPeople.main()) && DeliverPeople.roles(DeliverPeople.main())
        main.roles = ["roles": 1, "access": "admin"]
        await model.load()
        check("review: roles: old server all admin, an editor Mac isn’t one", allAdmin && editorMac && DeliverPeople.isAdmin(DeliverPeople.main()), "\(allAdmin) \(editorMac)")
        check("review: roles: the team is admins and editors, clients apart", model.team.map(\.id) == ["p1", "p4"] && model.clients.map(\.id) == ["p2"]
              && model.macs.map(\.id) == ["d1"] && model.adminCount == 2 && DeliverPeople.roleName("owner") == DeliverPeople.roleName("admin")
              && DeliverPeople.roleName("owner") != DeliverPeople.roleName("editor"), "\(model.team.map(\.id)) \(model.clients.map(\.id)) \(model.adminCount)")
        let kai = model.team.first { $0.id == "p4" }!, mac = model.macs[0]
        let guardBefore = !model.lastAdmin(kai) && !model.lastAdmin(mac)
        main.more = []
        await model.load()
        check("review: roles: the last admin can't step down here either", guardBefore && model.adminCount == 1 && model.lastAdmin(mac), "\(model.adminCount)")
        // Transfer Admin: the person up, then this Mac down; a Mac's role is its own op.
        publish.update(host: host.id) { $0.device = "d1" }
        main.ops = []
        let moved = await model.transfer(to: .person("p1"), stepDown: true)
        await model.setRole(device: "d1", "admin")
        await model.transfer(to: .mac("d1"), stepDown: false)
        let roleOps = main.ops.compactMap { op -> String? in
            guard let name = op["op"] as? String, ["person-update", "device-role"].contains(name) else { return nil }
            return "\(name) \(op["id"] ?? "") \(op["role"] ?? op["access"] ?? "")"
        }
        check("review: roles: Transfer Admin makes them admin, then this Mac an editor", moved && roleOps == ["person-update p1 owner", "device-role d1 editor",
              "device-role d1 admin", "device-role d1 admin"], "\(roleOps)")
        check("review: roles: the server's refusals read clearly", ReviewHostClient.problem(Deliver.Failure("lastAdmin")) != ReviewHostClient.problem(Deliver.Failure("x"))
              && ReviewHostClient.problem(Deliver.Failure("admin")) != ReviewHostClient.problem(Deliver.Failure("x")), "")
    }
}
