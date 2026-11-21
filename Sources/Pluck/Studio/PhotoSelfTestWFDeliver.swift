import Foundation

extension PhotoSelfTest {
    /// wf-deliver (plan 407b stream 4; part of reviewflow): the Delivered stage, deliverable groups, sign-off sheets and
    /// archiving a share, against a test store and a stand-in NAS share.
    static func wfDeliverTest() async {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("WFDeliver-\(UUID().uuidString)", isDirectory: true)
        let share = base.appendingPathComponent("Share", isDirectory: true)
        let folder = share.appendingPathComponent("Acme/Launch", isDirectory: true)
        try? fm.createDirectory(at: folder.appendingPathComponent("Exports"), withIntermediateDirectories: true)
        let savedVolumes = OfficeGroup.testVolumes
        OfficeGroup.testVolumes = [(prefix: share.standardizedFileURL.path, remount: "smb://nas-selftest/work")]
        defer { OfficeGroup.testVolumes = savedVolumes; try? fm.removeItem(at: base) }
        let store = DeliverStore(root: base.appendingPathComponent("Review", isDirectory: true))
        guard let project = try? store.newProject("Launch") else { return check("deliver: project", false) }
        var files: [(name: String, kind: Deliver.Kind, path: String, size: Int64)] = []
        for name in ["Hero", "Hero_9x16", "Hero_NL", "Teaser"] {
            let file = folder.appendingPathComponent("Exports/\(name).mov")
            fm.createFile(atPath: file.path, contents: Data(name.utf8))
            files.append((name: name, kind: .video, path: file.path, size: Int64(name.utf8.count)))
        }
        let assets = store.addReferences(files, to: project.id)
        guard assets.count == 4, let link = try? store.newLink(scope: .project(project.id), title: "Client") else { return check("deliver: assets", false) }
        await deliveredTest(store: store, project: project.id, link: link, folder: folder, assets: assets)
        groupsTest(store: store, link: link, assets: assets)
        signOffTest(store: store, link: link, assets: assets, base: base)
        archiveTest(store: store, link: link, folder: folder)
    }

    /// 4b: groups suggested from names, set and cleared, on the wire (summary, publish, read back).
    static func groupsTest(store: DeliverStore, link: Deliver.ShareLink, assets: [Deliver.Asset]) {
        check("groups: variant endings", Deliver.variantBase("Hero_9x16") == "Hero" && Deliver.variantBase("Spot 15s NL.mov") == "Spot"
              && Deliver.variantBase("Hero_1x1_cutdown") == "Hero" && Deliver.variantBase("Hero") == nil && Deliver.variantBase("Just do it") == nil
              && Deliver.variantBase("Teaser-v2") == nil, "\(String(describing: Deliver.variantBase("Spot 15s NL.mov")))")
        let suggested = Deliver.suggestedGroups(assets)
        check("groups: the master and its variants, not the teaser", suggested.count == 3 && Set(suggested.values) == ["Hero"] && suggested[assets[3].id] == nil, "\(suggested)")
        for (id, group) in suggested { store.setGroup(group, of: [id]) }
        let server = DeliverServer(store: store)
        let list = (try? server.list(nil, store.link(link.id)!))?["assets"] as? [[String: Any]] ?? []
        check("groups: the page's list says each asset's group", list.filter { $0["group"] as? String == "Hero" }.count == 3
              && list.contains { $0["name"] as? String == "Teaser" && $0["group"] == nil })
        let back = DeliverSync.asset(["id": assets[1].id.uuidString, "name": "Hero_9x16", "kind": "video", "group": "Hero",
                                      "versions": [["id": UUID().uuidString, "number": 1, "size": 1, "original": "originals/x.mov"]]],
                                     host: Deliver.Host(name: "NAS", kind: .nas, address: nil))
        check("groups: read back from a host", back?.group == "Hero")
        check("groups: suggested only for assets without one", Deliver.suggestedGroups(store.content(link.project).assets).isEmpty)
        store.setGroup(nil, of: [assets[2].id])
        check("groups: ungrouped", store.find(assets[2].id)?.asset.group == nil && store.find(assets[1].id)?.asset.group == "Hero")
    }

    /// 4c: sign-off sheet rows, CSV (formula-safe) and PDF, with each row's record hash; per link and per client.
    static func signOffTest(store: DeliverStore, link: Deliver.ShareLink, assets: [Deliver.Asset], base: URL) {
        let approvals = DeliverSignOff.approvals(link: link.id, store: store)
        _ = try? store.addComment(asset: assets[0].id, version: assets[0].current.id, frame: 0, endFrame: nil, text: "=Looks great", author: "Client",
                                  token: nil, link: link.id, drawing: nil, page: nil, anchor: nil, isInternal: false, attachments: [], mentions: nil)
        let rows = DeliverSignOff.rows(approvals, store: store)
        let expected = approvals.first.map { DeliverProof.record(DeliverProof.fields($0, store: store, servedBy: DeliverSignOff.servedBy, generated: $0.created)) }
        check("sign-off: every approval of the link, its record as on the proof", approvals.count == 4 && rows.count == 4 && rows.first?.record == expected
              && rows.allSatisfy { $0.decision == "Approved" && $0.name == "Client" && $0.link == "Client" }, "\(rows.first.map { "\($0)" } ?? "")")
        let csv = DeliverSignOff.csv(rows)
        check("sign-off: CSV with a header, the note, formulas defused", csv.hasPrefix("Project,Asset,Version,Decision,Name") && csv.contains("'=Looks great")
              && csv.components(separatedBy: "\r\n").count == 6, csv)
        let folder = base.appendingPathComponent("Sheets", isDirectory: true)
        let made = (try? DeliverSignOff.write(title: "Client", approvals: approvals, into: folder, store: store)) ?? []
        check("sign-off: a PDF and a CSV", made.count == 2 && made.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
              && (try? Data(contentsOf: made[0]))?.starts(with: Data("%PDF".utf8)) == true)
        check("sign-off: per client (Archive's client of the project)", DeliverProjectFile.client(link.project, store: store) == "Acme"
              && DeliverSignOff.approvals(client: "Acme", store: store).count == 4 && DeliverSignOff.approvals(client: "Other", store: store).isEmpty)
    }

    /// 4d: archive a share into the project's folder, the calm page, reopen, and the clients' data forgotten later.
    static func archiveTest(store: DeliverStore, link: Deliver.ShareLink, folder: URL) {
        store.log(.init(link: link.id, name: "Client", email: "client@example.com", kind: "opened"))
        let made = try? DeliverShareArchive.archive(link.id, store: store)
        let names = made.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) } ?? []
        check("archive: comments, approval proofs and the sign-off into Pluck · Review/<link>/",
              made?.standardizedFileURL.path == folder.appendingPathComponent("Pluck · Review/Client").standardizedFileURL.path
              && names.contains("Comments.csv") && names.contains("Comments.txt") && names.filter { $0.hasPrefix("Approval") }.count == 4
              && names.contains("Sign-off – Client.pdf") && names.contains("Sign-off – Client.csv"), "\(names)")
        let text = (made.flatMap { try? String(contentsOf: $0.appendingPathComponent("Comments.txt"), encoding: .utf8) }) ?? ""
        check("archive: the comments readable", text.contains("Hero v1") && text.contains("Client: =Looks great"), text)
        check("archive: the link archived, reviewArchived in the project's file", store.link(link.id)?.archived != nil
              && DeliverProjectFile.read(folder)["reviewArchived"] is String && DeliverProjectFile.read(folder)["hold"] as? Bool == true)
        DeliverShareArchive.reopen(link.id, store: store)
        check("archive: reopened", store.link(link.id)?.archived == nil && DeliverProjectFile.read(folder)["reviewArchived"] == nil)
        _ = try? DeliverShareArchive.archive(link.id, store: store, now: Date.now.addingTimeInterval(-400 * 86400))
        DeliverShareArchive.forget(store: store)
        let approvals = DeliverSignOff.approvals(link: link.id, store: store)
        check("archive: after the retention, no activity and no emails; approvals keep name and date",
              store.activity(link.id).isEmpty && approvals.count == 4 && approvals.allSatisfy { $0.email == nil && $0.author == "Client" })
        let wire = ReviewPublish(store: store).manifest(project: link.project, only: nil, host: nil).json
        let wireLink = (wire["links"] as? [[String: Any]])?.first { $0["id"] as? String == link.id.uuidString }
        let wireAsset = ((wire["projects"] as? [[String: Any]])?.first?["assets"] as? [[String: Any]])?.first { $0["name"] as? String == "Hero_9x16" }
        check("archive: the host hears archived, delivered, groups and how long to keep client data", wireLink?["archived"] is String
              && wireLink?["delivered"] is NSNull && wireAsset?["group"] as? String == "Hero"
              && wire["archiveForgetDays"] as? Int == DeliverShareArchive.forgetMonths * 31, "\(String(describing: wireLink))")
    }

    /// 4a: Delivered: originals on, an expiry, read-only comments, no deadline, `delivered` in the project's NAS file.
    static func deliveredTest(store: DeliverStore, project: UUID, link: Deliver.ShareLink, folder: URL, assets: [Deliver.Asset]) async {
        check("delivered: the project's NAS folder from its originals", DeliverProjectFile.folder(project, store: store)?.standardizedFileURL.path == folder.standardizedFileURL.path,
              "\(String(describing: DeliverProjectFile.folder(project, store: store)))")
        DeliverProjectFile.merge(["hold": true, "keepOriginalsUntil": "2027-01-01T00:00:00Z"], into: folder)   // Archive's keys
        store.updateLink(link.id) { $0.deadline = Date.now.addingTimeInterval(-3600) }
        let session = ShareBuilderSession(link: store.link(link.id)!, store: store)
        session.setDelivered(true)
        let saved = session.update()
        let now = store.link(link.id)
        let file = DeliverProjectFile.read(folder)
        check("delivered: originals on, an expiry in about 30 days", saved && now?.delivered != nil && now?.allowDownload == true
              && (now?.expires).map { abs($0.timeIntervalSinceNow - 30 * 86400) < 2 * 86400 } == true, "\(String(describing: now))")
        check("delivered: into .pluck-project.json, Archive's keys kept", file["delivered"] is String && file["hold"] as? Bool == true
              && file["keepOriginalsUntil"] as? String == "2027-01-01T00:00:00Z", "\(file)")
        check("delivered: no feedback deadline any more", now.map { DeliverDeadlines.effective($0, store: store) } == .some(nil))
        let info = now.map { DeliverServer.linkInfo($0, store: store) } ?? [:]
        check("delivered: ready.link says so, without a deadline", info["delivered"] is String && info["deadline"] == nil, "\(info)")

        // The server: reading works, writing is read only, an archived link says so.
        let server = DeliverServer(store: store)
        var out: [[String: Any]] = []
        server.output = { out.append($0) }
        let peer = connectPeer(server, store: store, link: store.link(link.id)!, out: { out }, reset: { out = [] })
        func ask(_ body: [String: Any]) -> [String: Any] {
            out = []
            server.helper(["msg": ["peer": peer, "msg": body.merging(["id": 7]) { $1 }]])
            return sentTo(peer, out).first { $0["re"] as? Int == 7 } ?? [:]
        }
        func code(_ answer: [String: Any]) -> String? { (answer["error"] as? [String: Any])?["code"] as? String }
        let asset = assets[0]
        check("delivered: lists, but comments and approvals are read only", ask(["t": "list", "folder": NSNull()])["assets"] is [[String: Any]]
              && code(ask(["t": "comment-add", "asset": asset.id.uuidString, "version": asset.current.id.uuidString, "frame": 1, "text": "Late"])) == "readonly"
              && code(ask(["t": "approve", "asset": asset.id.uuidString, "version": asset.current.id.uuidString, "decision": "approve"])) == "readonly")
        out = []
        store.updateLink(link.id) { $0.archived = .now }
        let told = sentTo(peer, out).contains { $0["t"] as? String == "bye" && $0["code"] as? String == "paused" && $0["archived"] as? Bool == true }
        let late = connectPeer(server, store: store, link: store.link(link.id)!, out: { out }, reset: { out = [] })
        let refused = sentTo(late, out).contains { ($0["error"] as? [String: Any]).map { $0["code"] as? String == "paused" && $0["archived"] as? Bool == true } == true }
        check("archived: open pages hear it, new ones are refused (as paused + archived, for older pages)", told && refused)
        store.updateLink(link.id) { $0.archived = nil }

        // approvedFinal once every asset is approved; Delivered off takes `delivered` out again.
        for asset in assets { _ = try? store.approve(asset: asset.id, version: asset.current.id, decision: .approve, author: "Client", link: link.id) }
        check("delivered: approvedFinal when every asset is approved", DeliverProjectFile.read(folder)["approvedFinal"] is String)
        session.setDelivered(false)
        _ = session.update()
        check("delivered: off again, out of the file", store.link(link.id)?.delivered == nil && DeliverProjectFile.read(folder)["delivered"] == nil
              && DeliverProjectFile.read(folder)["hold"] as? Bool == true)
        check("delivered: a project on this Mac's own disk has no NAS file", !DeliverProjectFile.onShare(URL(fileURLWithPath: NSTemporaryDirectory())))
    }

    // MARK: Helpers

    static func sentTo(_ peer: String, _ out: [[String: Any]]) -> [[String: Any]] {
        out.compactMap { ($0["send"] as? [String: Any]).flatMap { $0["peer"] as? String == peer ? $0["msg"] as? [String: Any] : nil } }
    }

    /// A browser through the fake helper, authed and ready (as the parity test's `connect`).
    static func connectPeer(_ server: DeliverServer, store: DeliverStore, link: Deliver.ShareLink, name: String = "Anna",
                            out: () -> [[String: Any]], reset: () -> Void) -> String {
        let peer = "p_" + UUID().uuidString.prefix(6)
        let fpMac = Array(repeating: "AA", count: 32).joined(separator: ":"), fpBrowser = Array(repeating: "BB", count: 32).joined(separator: ":")
        reset()
        server.helper(["peer": ["peer": peer, "room": link.roomID, "state": "open", "fpLocal": fpMac, "fpRemote": fpBrowser]])
        guard let hello = sentTo(peer, out()).first, let key = store.key(link.id), let level = store.level(link.id),
              let macNonce = DeliverKeys.browserCheck(hello, level: level, key: key, pub: DeliverKeys.publicKey(root: store.secret(link.id) ?? Data()), fpMac: fpMac, fpBrowser: fpBrowser)
        else { return peer }
        let nonce = DeliverKeys.random(32)
        let proof = DeliverKeys.proof(authKey: DeliverKeys.authKey(key), role: "browser", macNonce: macNonce, browserNonce: nonce, fpMac: fpMac, fpBrowser: fpBrowser)
        server.helper(["msg": ["peer": peer, "msg": ["t": "auth", "id": 1, "v": level, "nonce": DeliverKeys.base64url(nonce), "proof": proof,
                                                     "token": DeliverKeys.base64url(DeliverKeys.random(32)), "name": name] as [String: Any]]])
        return peer
    }
}
