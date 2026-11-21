import Foundation

extension PhotoSelfTest {
    /// The 4.1.0 Deliver gaps (part of reviewflow): transcript language, mentions of this Mac's person, the shared
    /// library, folder order, mail through the always-on Mac.
    static func deliverGapTest(store: DeliverStore, project: UUID, asset: UUID) async {
        func base(_ store: DeliverStore) -> URL { store.root.deletingLastPathComponent() }
        // Transcripts: the project's spoken language wins over the name's guess; without one the guess stays.
        let chosen = DeliverCopies.spokenLanguage(project: "nl-BE", file: "/nowhere/Interview.mov", name: "The weather report today")
        let guessed = DeliverCopies.spokenLanguage(project: nil, file: "/nowhere/x.mov", name: "Le bulletin météo de ce soir à Paris")
        check("gap: transcript language (project first, guess as fallback)", chosen.identifier == "nl-BE" && guessed.language.languageCode?.identifier == "fr",
              "\(chosen.identifier) \(guessed.identifier)")

        // "You were mentioned": this Mac's person by the comment name; only what's new mentions it.
        let team = [Deliver.Person(id: "p1", name: "Sam", role: "owner"), Deliver.Person(id: "p2", name: "Alex", role: "editor")]
        var comment = Deliver.Comment(asset: asset, version: UUID(), text: "Look @Sam", author: "Client")
        comment.mentions = ["p1"]
        var replied = comment
        replied.replies.append(.init(text: "@Alex too", author: "Client", mentions: ["p2"]))
        var again = replied
        again.replies.append(.init(text: "and @Sam", author: "Client 2", mentions: ["p1"]))
        check("gap: mention of this Mac's person", DeliverNotify.me(team: team, name: " sam ".trimmingCharacters(in: .whitespaces)) == "p1"
              && DeliverNotify.me(team: team, name: "Editor") == nil
              && DeliverNotify.newMention(of: "p1", before: nil, after: comment)?.text == "Look @Sam"
              && DeliverNotify.newMention(of: "p1", before: comment, after: comment) == nil
              && DeliverNotify.newMention(of: "p1", before: comment, after: replied) == nil
              && DeliverNotify.newMention(of: "p2", before: comment, after: replied)?.author == "Client"
              && DeliverNotify.newMention(of: "p1", before: replied, after: again)?.author == "Client 2")

        // The team's library through the main host: newest wins, an untouched one never goes up, the wire round trip.
        let t0 = Date(timeIntervalSince1970: 1_800_000_000), t1 = t0.addingTimeInterval(60)
        var older = Deliver.Library(), newer = Deliver.Library()
        older.at = t0
        newer.at = t1
        newer.statuses = [.init(id: "c:graded", name: "Graded", colour: "good")]
        let wire = (try? Deliver.encoder.encode(newer)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        check("gap: library sync (newest wins)", DeliverSync.libraryStep(mine: older, theirs: newer) == .adopt
              && DeliverSync.libraryStep(mine: newer, theirs: older) == .push && DeliverSync.libraryStep(mine: newer, theirs: nil) == .push
              && DeliverSync.libraryStep(mine: Deliver.Library(), theirs: nil) == .none && DeliverSync.libraryStep(mine: newer, theirs: newer) == .none
              && DeliverSync.library(wire) == newer && DeliverSync.library(nil) == nil && DeliverSync.library(NSNull()) == nil)
        store.editLibrary { $0.views = [] }
        // Mail through the always-on Mac: a folder hosted later gets the others' mail setup, the password file kept private.
        let fm = FileManager.default
        let hostedA = base(store).appendingPathComponent("Pluck Review AAAAAAAA-0001", isDirectory: true)
        let hostedB = base(store).appendingPathComponent("Pluck Review BBBBBBBB-0001", isDirectory: true)
        for folder in [hostedA, hostedB] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        try? Data(#"{"enabled":true}"#.utf8).write(to: hostedA.appendingPathComponent("mail.json"))
        try? Data("app-password".utf8).write(to: hostedA.appendingPathComponent("mail.secret"))
        ReviewHosting.seedMail(into: hostedB, from: [hostedA])
        let mode = (try? fm.attributesOfItem(atPath: hostedB.appendingPathComponent("mail.secret").path)[.posixPermissions] as? Int) ?? 0
        try? Data(#"{"enabled":false}"#.utf8).write(to: hostedB.appendingPathComponent("mail.json"))
        ReviewHosting.seedMail(into: hostedB, from: [hostedA])
        check("gap: always-on Mac seeds mail into a new hosted folder", (try? String(contentsOf: hostedB.appendingPathComponent("mail.secret"), encoding: .utf8)) == "app-password"
              && mode == 0o600 && (try? String(contentsOf: hostedB.appendingPathComponent("mail.json"), encoding: .utf8)) == #"{"enabled":false}"#
              && ReviewHosting.mailOps.contains("mail-set") && ReviewHosting.mailOps.isSuperset(of: ["unsubscribe", "subscribe-confirm"]), "mode \(String(mode, radix: 8))")
        check("gap: link mute list for this Mac's person's emails", DeliverMail.muted(["a"], "b", true) == ["a", "b"] && DeliverMail.muted(["a", "b"], "a", false) == ["b"]
              && DeliverMail.muted(["a"], "a", true) == ["a"])
        let muteRow = DeliverMail.Subscriber(id: "r1", kind: "team", email: "a@example.com", name: "", mode: "daily", mute: ["web"])
        let muteOp = DeliverMail.muteOp(muteRow, "mac", true)
        check("gap: a link's mute goes as one change (old hosts get the list)", muteOp["muteLink"] as? String == "mac" && muteOp["muted"] as? Bool == true
              && muteOp["mute"] as? [String] == ["web", "mac"] && DeliverMail.muteOp(muteRow, "web", false)["muted"] as? Bool == false && muteOp["mode"] == nil)
        // Folder order: a folder's own order for links without one (folders by name, ids still in that folder only),
        // carried by the folder's wire form; the share link's info gets it.
        let f1 = UUID(), f2 = UUID(), a1 = UUID(), a2 = UUID(), a3 = UUID(), gone = UUID()
        func file(_ id: UUID, _ folder: UUID?) -> Deliver.Asset { Deliver.Asset(id: id, name: "x", folder: folder, kind: .video, versions: [.init(number: 1, path: "/x", size: 1)]) }
        let folders = [Deliver.Folder(id: f2, name: "B", order: [a3]), Deliver.Folder(id: f1, name: "A", order: [a2, gone, a1]), Deliver.Folder(name: "C")]
        let files = [file(a1, f1), file(a2, f1), file(a3, f2)]
        check("gap: folder order for links without their own", Deliver.folderOrder(folders, assets: files) == [a2, a1, a3]
              && Deliver.folderOrder([Deliver.Folder(name: "C")], assets: files) == nil
              && DeliverSync.folder(["id": f1.uuidString, "name": "A", "order": [a2.uuidString, "junk"]])?.order == [a2])
        if let folder = store.newFolder("Cuts", in: project, parent: nil) {
            store.edit(project) { content in if let i = content.assets.firstIndex(where: { $0.id == asset }) { content.assets[i].folder = folder.id } }
            store.setFolderOrder(folder.id, in: project, [asset])
            let link = Deliver.ShareLink(title: "Cuts", scope: .project(project), roomID: "r")
            let info = DeliverServer.linkInfo(link, store: store)
            check("gap: a link shows its folder's order", info["order"] as? [String] == [asset.uuidString]
                  && store.content(project).folders.first { $0.id == folder.id }?.order == [asset], "\(info["order"] ?? "-")")
            // Another Mac reading the published link back never takes the folder's order as the link's own (it would freeze).
            if let made = try? store.newLink(scope: .project(project), title: "Folder order") {
                let wire = (ReviewPublish(store: store).manifest(project: project, only: nil, host: nil).json["links"] as? [[String: Any]] ?? []).first { $0["id"] as? String == made.id.uuidString }
                let back = wire.flatMap { DeliverSync.link($0) }
                check("gap: the folder's order isn't read back as the link's", wire?["order"] as? [String] == [asset.uuidString] && wire?["ownOrder"] is NSNull
                      && back != nil && back?.order == nil, "\(wire?["ownOrder"] ?? "-")")
                store.deleteLink(made.id)
            }
        } else { check("gap: folder made", false) }
        check("gap: library edits are stamped in whole seconds", store.library.at.map { $0.timeIntervalSince1970.rounded(.down) == $0.timeIntervalSince1970 && abs($0.timeIntervalSinceNow) < 5 } == true)
    }
}
