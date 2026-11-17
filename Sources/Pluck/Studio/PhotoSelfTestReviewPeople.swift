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
            var team: Any = ["id": "t1", "name": "Northwind Films", "link": "https://pluck.tools/r/#k.p"]
            var ops: [[String: Any]] = []
            var invites: [[String: Any]] = []
            var more: [[String: Any]] = []
            var requests: [[String: Any]] = [["id": "r1", "name": "Alex Kim", "email": "alex@example.com", "link": "L1", "at": ISO8601DateFormatter().string(from: .now)]]
        }
        let main = Main(), fingerprint = Array(repeating: "CD", count: 32).joined(separator: ":")
        let iso = ISO8601DateFormatter().string(from: .now)
        let saved = (ReviewHostClient.fake, ReviewHostClient.fakeFingerprint)
        ReviewHostClient.fakeFingerprint = fingerprint
        ReviewHostClient.fake = { request, _ in
            guard let op = request["op"] as? String else { return main.accounts.map { ["ok": true, "accounts": $0] } ?? ["ok": true] }
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
            case "devices": return ["devices": [["id": "d1", "name": "Edit Mac", "role": "mac", "lastSeen": iso], ["id": "b1", "name": "Backup NAS", "role": "backup", "lastSeen": iso]]]
            case "team-set": main.team = ["id": "t1", "name": "Northwind Films", "link": "https://pluck.tools/r/#k.p"]; return ["ok": true, "link": "https://pluck.tools/r/#k.p"]
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
    }
}
