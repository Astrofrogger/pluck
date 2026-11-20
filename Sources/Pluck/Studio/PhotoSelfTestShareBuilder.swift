import Foundation

extension PhotoSelfTest {
    /// The Share Builder (-PluckScreenshotOnly sharebuilder): editing keeps the link (id, key, room, address) and
    /// republishes it; unsaved changes and Revert; the preview manifest holds exactly what the link shows (never its key,
    /// internal comments or other assets); All Share Links' rows.
    static func shareBuilderTest() async {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("ShareBuilder-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let store = DeliverStore(root: base.appendingPathComponent("Review", isDirectory: true))
        guard let project = try? store.newProject("Spring"), let other = try? store.newProject("Other") else { return check("builder: projects", false) }
        func asset(_ name: String, in project: UUID) -> Deliver.Asset? {
            let file = base.appendingPathComponent(name + ".mov")
            fm.createFile(atPath: file.path, contents: Data(repeating: 0, count: 8))
            return store.addReferences([(name: name, kind: .video, path: file.path, size: 8)], to: project).first
        }
        guard let hero = asset("Hero 30s", in: project.id), let cut = asset("Cutdown 15s", in: project.id), let social = asset("Social 9x16", in: project.id),
              let elsewhere = asset("Elsewhere", in: other.id), let folder = store.newFolder("Socials", in: project.id, parent: nil) else { return check("builder: assets", false) }
        store.move(asset: social.id, to: folder.id)
        _ = try? store.addComment(asset: hero.id, version: hero.current.id, frame: nil, text: "Client note", author: "Client", token: "t")
        _ = try? store.addComment(asset: hero.id, version: hero.current.id, frame: nil, text: "SECRET-INTERNAL", author: "Editor", isInternal: true)
        guard let link = try? store.newLink(scope: .project(project.id), title: "Spring – cuts", password: "pw") else { return check("builder: link", false) }
        let key = store.key(link.id), url = store.url(link), count = store.links.count, rev = link.rev ?? 0
        var changes = 0
        store.listeners.append { if case .linksChanged = $0 { changes += 1 } }

        // Unsaved changes and Revert.
        let session = ShareBuilderSession(link: link, store: store)
        check("builder: an opened link has no unsaved changes", !session.dirty && !session.isNew)
        session.draft.layout = "reel"
        session.draft.title = "Spring – final"
        check("builder: an edit is unsaved until Update Link", session.dirty && store.link(link.id)?.layout == nil && store.link(link.id)?.title == "Spring – cuts")
        session.revert()
        check("builder: Revert brings back the live settings", !session.dirty && session.draft == link)

        // Update Link: the same link, live.
        session.draft.layout = "reel"
        session.draft.description = "Two cuts"
        session.draft.watermark = .init()
        session.draft.title = "Spring – final"
        session.password = "new"
        let ok = session.update()
        let saved = store.link(link.id)
        check("builder: Update Link edits the same link (id, room, key and address kept; no new link)",
              ok && saved?.layout == "reel" && saved?.description == "Two cuts" && saved?.title == "Spring – final" && saved?.roomID == link.roomID
              && store.key(link.id) == key && key != nil && saved.flatMap { store.url($0) } == url && store.links.count == count,
              "\(String(describing: saved?.layout)) \(store.links.count) vs \(count)")
        check("builder: the update is announced (hosts and open pages get it) and stamped", changes > 0 && (saved?.rev ?? 0) > rev, "changes \(changes) rev \(String(describing: saved?.rev)) vs \(rev)")
        check("builder: a typed password replaces the old one", saved?.passwordHash != nil && saved?.passwordHash != link.passwordHash && session.password.isEmpty)
        check("builder: after updating nothing is unsaved", !session.dirty)
        session.clearPassword = true
        session.update()
        check("builder: Remove takes the password off", store.link(link.id)?.passwordHash == nil)

        // The preview manifest: the draft as the page gets it.
        session.draft.layout = "list"
        let made = session.server.previewManifest(session.draft, lang: "nl")
        let text = String(decoding: (try? JSONSerialization.data(withJSONObject: made.json)) ?? Data(), as: UTF8.self)
        let lists = made.json["lists"] as? [String: Any]
        let root = (lists?[""] as? [String: Any])?["assets"] as? [[String: Any]] ?? []
        let inFolder = (lists?[folder.id.uuidString] as? [String: Any])?["assets"] as? [[String: Any]] ?? []
        let secrets = [key.map(DeliverKeys.base64url), store.code(link.id), url, link.roomID, store.link(link.id)?.passwordHash].compactMap { $0 }
        check("builder: the manifest shows the unsaved settings", (made.json["link"] as? [String: Any])?["layout"] as? String == "list" && store.link(link.id)?.layout == "reel")
        check("builder: the manifest never holds the link's key, address, room or password", !secrets.contains { text.contains($0) } && !secrets.isEmpty,
              secrets.filter { text.contains($0) }.joined(separator: ","))
        check("builder: exactly the link's assets (root and folder lists; nothing from elsewhere)",
              Set(root.compactMap { $0["id"] as? String }) == [hero.id.uuidString, cut.id.uuidString] && inFolder.compactMap { $0["id"] as? String } == [social.id.uuidString]
              && !text.contains(elsewhere.id.uuidString) && !text.contains("Elsewhere") && Set(made.pictures.keys) == Set([hero, cut, social].map { $0.current.id.uuidString }))
        let heroComments = (root.first { $0["id"] as? String == hero.id.uuidString }?["current"] as? [String: Any])?["comments"] as? Int
        check("builder: internal comments stay out of a client link's preview", !text.contains("SECRET-INTERNAL") && heroComments == 1, "\(String(describing: heroComments))")
        session.draft.audience = "team"
        let team = (((session.server.previewManifest(session.draft).json["lists"] as? [String: Any])?[""] as? [String: Any])?["assets"] as? [[String: Any]] ?? [])
            .first { $0["id"] as? String == hero.id.uuidString }.flatMap { ($0["current"] as? [String: Any])?["comments"] as? Int }
        check("builder: a team link's preview counts them", store.comments(hero.id).count == 2 && team == 2, "\(String(describing: team))")
        session.draft.audience = nil
        check("builder: pictures only through pluck-preview:", (made.json["images"] as? [String: String])?.values.allSatisfy { $0.hasPrefix("pluck-preview://img/") } == true
              && made.json["lang"] as? String == "nl")
        session.draft.scope = .folder(folder.id, project: project.id)
        let narrow = session.server.previewManifest(session.draft).json
        let narrowText = String(decoding: (try? JSONSerialization.data(withJSONObject: narrow)) ?? Data(), as: UTF8.self)
        check("builder: a folder link's preview has only that folder", !narrowText.contains(hero.id.uuidString) && narrowText.contains(social.id.uuidString))
        session.revert()

        // Content: remove, add, drop, order.
        session.remove(hero.id)
        let rest: Bool = if case .assets = session.draft.scope { Set(session.assets.map(\.id)) == [cut.id, social.id] } else { false }
        check("builder: removing an asset turns a project link into a link to the rest", rest)
        session.add(hero.id)
        check("builder: adding brings it back", Set(session.assets.map(\.id)) == [hero.id, cut.id, social.id])
        check("builder: a dropped folder becomes what it shares; other projects' ids are ignored",
              session.drop([folder.id.uuidString]) && session.draft.scope == .folder(folder.id, project: project.id) && !session.drop([elsewhere.id.uuidString]))
        let (a, b, c, d) = (UUID(), UUID(), UUID(), UUID())
        check("builder: cards dragged in a folder take their new places in the link's order",
              ShareBuilderSession.reorder([a, b, c, d], moved: [c, a]) == [c, b, a, d] && ShareBuilderSession.reorder([a, b], moved: []) == [a, b])
        session.revert()

        // A new link: nothing is made until Create Link, then it's an ordinary link.
        let fresh = ShareBuilderSession(new: .asset(cut.id, project: project.id), store: store)
        let before = store.links.count
        check("builder: New Link is a draft (titled after what it shares)", fresh.isNew && fresh.dirty && fresh.draft.title == "Cutdown 15s" && store.links.count == before)
        fresh.draft.layout = "reel"
        let created = fresh.update()
        let made2 = fresh.linkID.flatMap { store.link($0) }
        check("builder: Create Link makes one link with the draft's settings", created && store.links.count == before + 1 && made2?.layout == "reel" && !fresh.isNew && !fresh.dirty)
        fresh.draft.layout = nil
        fresh.update()
        check("builder: updating it again keeps that link", store.links.count == before + 1 && store.link(made2?.id ?? UUID())?.layout == nil)

        // All Share Links: rows and what each shares.
        guard let off = try? store.newLink(scope: .assets([hero.id, cut.id], project: project.id), title: "Old") else { return check("builder: table links", false) }
        store.revoke(off.id)
        _ = try? store.newLink(scope: .project(other.id), title: "Not here")
        let rows = DeliverLinkRow.rows(store.links, project: project.id)
        check("builder: the table lists the project's links, live ones first, newest first",
              rows.map(\.id) == [made2?.id, link.id, off.id].compactMap { $0 }, rows.map(\.title).joined(separator: ","))
        check("builder: Shares never repeats the project's name", DeliverLinkRow.shares(link, store: store) == String(localized: "Whole project")
              && DeliverLinkRow.shares(off, store: store) == String(localized: "\(2) assets") && DeliverLinkRow.shares(made2 ?? link, store: store) == "Cutdown 15s")
    }
}
