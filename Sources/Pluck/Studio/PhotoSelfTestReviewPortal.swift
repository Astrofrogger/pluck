import CryptoKit
import Foundation

extension PhotoSelfTest {
    /// Client pages (4.0.7, -PluckScreenshotOnly reviewportal): only that client's live client links, a box only the page's
    /// key opens (the web page's vector), nothing else answered through the page, the box kept current, and the host's
    /// manifest record without a box when the page's key is elsewhere.
    static func reviewPortalTest() async {
        // The sealed box, as the web page opens it (pluck-site src/review/portal.test.ts has the same vector).
        let vector = DeliverClientPage.seal(["X": "https://pluck.tools/r/#abc"], key: Data(repeating: 1, count: 32), nonce: try! AES.GCM.Nonce(data: Data(repeating: 2, count: 12)))
        check("portal: box vector", vector == "AgICAgICAgICAgICYkr5ZQ9tOThDwKmsgsH3gh_9f-0mpXkgCQlHPISA26A4vYwAEExVyv27iJLmiU4c7imG6aCJ", vector ?? "nil")

        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("ReviewPortal-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let store = DeliverStore(root: base.appendingPathComponent("Review", isDirectory: true))
        guard let mine = try? store.newProject("Spring campaign"), let other = try? store.newProject("Other client") else { return check("portal: projects", false) }
        let clip = base.appendingPathComponent("brief.txt")
        fm.createFile(atPath: clip.path, contents: Data(repeating: 7, count: 100))
        let assets = (try? store.add([clip], to: mine.id, folder: nil)) ?? []
        if let asset = assets.first { store.setStatus(.approved, of: asset.id, by: "Owner") }
        func make(_ title: String, _ project: UUID, _ change: (inout Deliver.ShareLink) -> Void = { _ in }) -> Deliver.ShareLink {
            let link = try! store.newLink(scope: .project(project), title: title)
            store.updateLink(link.id, change)
            return store.link(link.id)!
        }
        let open = make("Cuts <b>&", mine.id)
        let team = make("Team", mine.id) { $0.audience = "team" }
        let personal = make("For Sam", mine.id) { $0.recipient = "Sam" }
        let paused = make("Paused", mine.id) { $0.paused = true }
        let off = make("Off", mine.id)
        store.revoke(off.id)
        let elsewhere = make("Theirs", other.id)
        guard let page = try? DeliverClientPage.make(name: "Northwind", projects: [mine.id], store: store) else { return check("portal: make", false) }
        DeliverClientPage.refresh(store: store, url: store.url)
        let listed = store.link(page.id)?.portal?.links ?? []
        check("portal: only the client's live client links", listed == [open.id] && page.scope == .assets([], project: mine.id),
              "\(listed) team \(team.id) personal \(personal.id) paused \(paused.id) other \(elsewhere.id)")

        // Through the page on this Mac's server.
        let server = DeliverServer(store: store)
        var out: [[String: Any]] = []
        server.output = { out.append($0) }
        for link in store.links { server.held(link.roomID) }
        let fpMac = Array(repeating: "AA", count: 32).joined(separator: ":"), fpBrowser = Array(repeating: "BB", count: 32).joined(separator: ":")
        func sent(_ peer: String) -> [[String: Any]] {
            out.compactMap { ($0["send"] as? [String: Any]).flatMap { $0["peer"] as? String == peer ? $0["msg"] as? [String: Any] : nil } }
        }
        var nextID = 0
        func ask(_ peer: String, _ body: [String: Any]) -> [String: Any] {
            nextID += 1
            let id = nextID
            out = []
            server.helper(["msg": ["peer": peer, "msg": body.merging(["id": id]) { $1 }]])
            return sent(peer).first { $0["re"] as? Int == id } ?? [:]
        }
        out = []
        server.helper(["peer": ["peer": "c1", "room": page.roomID, "state": "open", "fpLocal": fpMac, "fpRemote": fpBrowser, "path": "direct"]])
        guard let hello = sent("c1").first, let key = store.key(page.id), let level = store.level(page.id),
              let macNonce = DeliverKeys.browserCheck(hello, level: level, key: key, pub: DeliverKeys.publicKey(root: store.secret(page.id) ?? Data()), fpMac: fpMac, fpBrowser: fpBrowser)
        else { return check("portal: hello", false, "\(out)") }
        let nonce = DeliverKeys.random(32)
        let proof = DeliverKeys.proof(authKey: DeliverKeys.authKey(key), role: "browser", macNonce: macNonce, browserNonce: nonce, fpMac: fpMac, fpBrowser: fpBrowser)
        _ = ask("c1", ["t": "auth", "v": level, "nonce": DeliverKeys.base64url(nonce), "proof": proof, "token": DeliverKeys.base64url(DeliverKeys.random(32))])
        let ready = sent("c1").first { $0["t"] as? String == "ready" } ?? [:]
        let portal = ready["portal"] as? [String: Any] ?? [:], rows = portal["links"] as? [[String: Any]] ?? []
        let box = (portal["box"] as? String).flatMap { DeliverClientPage.open($0, key: key) }
        // (Its newest version, or when the link was made if that's later: the host's rule.)
        let added = max(DeliverServer.date(assets.first?.current.added ?? .distantPast), DeliverServer.date(open.created))
        check("portal: ready lists the link with its approvals and newest version", rows.count == 1 && rows.first?["id"] as? String == open.id.uuidString
              && rows.first?["title"] as? String == "Cuts <b>&" && rows.first?["assets"] as? Int == 1 && rows.first?["approved"] as? Int == 1
              && rows.first?["changes"] as? Int == 0 && rows.first?["updated"] as? String == added, "\(portal)")
        check("portal: the box opens with the page's key only", box == [open.id.uuidString: server.shareURL(open) ?? "-"]
              && (portal["box"] as? String).flatMap { DeliverClientPage.open($0, key: DeliverKeys.random(32)) } == nil, "\(String(describing: box))")
        let refused = ["list", "asset", "fetch", "comments", "comment-add", "mentionable", "subscribe"].allSatisfy { type in
            ((ask("c1", ["t": type, "asset": open.id.uuidString])["error"] as? [String: Any])?["code"] as? String) == "scope"
        }
        check("portal: nothing but the list through it", refused && ask("c1", ["t": "identify", "name": "Kim"])["error"] == nil)

        // A new link appears on the page (stamped again, so the hosts get the new box); the host record carries it.
        let rev = store.link(page.id)?.rev
        let later = make("Second cut", mine.id)
        DeliverClientPage.refresh(store: store, url: store.url)
        let now = store.link(page.id)
        check("portal: a new link re-stamps the page", Set(now?.portal?.links ?? []) == [open.id, later.id] && now?.rev != rev, "\(String(describing: now?.portal))")
        let wire = DeliverClientPage.manifest(now!, store: store, url: store.url) ?? [:]
        check("portal: host record", wire["projects"] as? [String] == [mine.id.uuidString] && (wire["box"] as? String)?.isEmpty == false
              && Set(wire["links"] as? [String] ?? []) == [open.id.uuidString, later.id.uuidString], "\(wire)")
        // A Mac before client pages reads the page as an ordinary (empty) pick of files.
        struct Old: Decodable { var title: String; var scope: Deliver.Scope }
        let old = (try? Deliver.encoder.encode(now!)).flatMap { try? Deliver.decoder.decode(Old.self, from: $0) }
        check("portal: an older Mac decodes it", old?.title == "Northwind" && old?.scope == .assets([], project: mine.id))
        // An archived link leaves the page (as the host's `live` refuses it).
        store.updateLink(open.id) { $0.archived = .now }
        check("portal: an archived link isn't listed", DeliverClientPage.members(store.link(page.id)!, store: store).map(\.id) == [later.id])
        // The page outlives the project it was made in: it moves to the client's other project, and goes with the last one.
        store.updateLink(page.id) { $0.portal?.projects = [mine.id, other.id] }
        store.deleteProject(mine.id)
        let moved = store.link(page.id)
        check("portal: deleting its first project keeps the page", moved?.revoked == nil && moved?.project == other.id && moved?.portal?.projects == [other.id],
              "\(String(describing: moved))")
        store.deleteProject(other.id)
        check("portal: with its last project it goes", store.link(page.id) == nil || store.link(page.id)?.revoked != nil)
        for link in store.links { store.revoke(link.id) }
        await hostWatchChecks()
    }

    /// A NAS that stops answering (4.0.7): told once after 10 minutes, never while this Mac is offline, then once it's back.
    static func hostWatchChecks() async {
        let watch = DeliverHostWatch(), nas = Deliver.Host(name: "Studio NAS", kind: .nas), office = Deliver.Host(name: "Office Mac", kind: .mac)
        var answers = false, online = true, told: [String] = []
        watch.probe = { _ in answers }
        watch.online = { online }
        watch.tell = { host, back, _ in told.append("\(host.name) \(back ? "back" : "down")") }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for minutes in [0.0, 5, 9] { await watch.check([nas, office], now: t0 + minutes * 60) }
        let early = told
        await watch.check([nas, office], now: t0 + 600)
        await watch.check([nas, office], now: t0 + 900)
        check("host watch: told once after 10 minutes", early.isEmpty && told == ["Studio NAS down"], "\(told)")
        online = false
        await watch.check([nas], now: t0 + 960)
        online = true
        answers = true
        await watch.check([nas], now: t0 + 1020)
        answers = false
        for minutes in [18.0, 25] { await watch.check([nas], now: t0 + minutes * 60) }
        check("host watch: back once; a new outage starts its own 10 minutes", told == ["Studio NAS down", "Studio NAS back"], "\(told)")
        let quiet = DeliverHostWatch()
        quiet.probe = { _ in false }
        quiet.online = { false }
        var none: [String] = []
        quiet.tell = { host, _, _ in none.append(host.name) }
        for minutes in [0.0, 11, 30] { await quiet.check([nas], now: t0 + minutes * 60) }
        check("host watch: this Mac offline says nothing", none.isEmpty && quiet.since.isEmpty)
        check("host watch: only no connection is down (not a refused key or a certificate to confirm)", DeliverHostWatch.unreachable(Deliver.Failure("internal"))
              && DeliverHostWatch.unreachable(POSIXError(.ECONNREFUSED)) && !DeliverHostWatch.unreachable(Deliver.Failure("auth"))
              && !DeliverHostWatch.unreachable(Deliver.Failure("removed")) && !DeliverHostWatch.unreachable(ReviewHostClient.Unconfirmed(fingerprint: "")))
        let seen = DeliverServer.date(t0 - 3600), old = DeliverServer.date(t0 - 9 * 86400)
        let devices: [[String: Any]] = [["id": "a", "role": "mac", "access": "admin", "lastSeen": old], ["id": "b", "role": "mac", "access": "admin", "lastSeen": seen],
                                        ["id": "0", "role": "mac", "access": "editor", "lastSeen": seen], ["id": "c", "role": "mac", "access": "admin", "lastSeen": seen],
                                        ["id": "00", "role": "backup", "lastSeen": seen]]
        check("host watch: one admin Mac posts (the lowest id seen lately)", DeliverHostWatch.poster(devices, now: t0) == "b"
              && DeliverHostWatch.poster(Array(devices.prefix(1)), now: t0) == "a")
    }
}
