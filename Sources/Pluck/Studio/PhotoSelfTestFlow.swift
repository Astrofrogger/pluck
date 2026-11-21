import Foundation

extension PhotoSelfTest {
    /// Deliver workflow (plan 2026-11-20-deliver-workflow-nle; -PluckScreenshotOnly reviewflow, also part of review):
    /// Resolve markers back into Pluck against a fake bridge, assignments, link order, saved views, custom statuses and fields.
    static func reviewFlowTest() async {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("ReviewFlow-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: base)
            DeliverResolveMarkers.bridge = { try await ResolveBridge.run($0) }
        }
        let store = DeliverStore(root: base.appendingPathComponent("Review", isDirectory: true))
        guard let project = try? store.newProject("Flow") else { return check("flow: project", false) }
        let clip = base.appendingPathComponent("hero.mov")
        fm.createFile(atPath: clip.path, contents: Data(repeating: 0, count: 16))
        guard let made = store.addReferences([(name: "Hero", kind: .video, path: clip.path, size: 16)], to: project.id).first else { return check("flow: asset", false) }
        let probe = Deliver.Probe(duration: 4, fpsNum: 25, fpsDen: 1, width: 1920, height: 1080, startTimecode: "00:00:00:00", dropFrame: false, hasAudio: true, frames: 100)
        store.update(version: made.current.id, of: made.id) { $0.probe = probe }
        guard let asset = store.find(made.id)?.asset else { return check("flow: asset", false) }
        await resolvePullTest(store: store, asset: asset, probe: probe)
        flowModelTest(store: store, project: project.id, asset: asset.id)
        await deliverGapTest(store: store, project: project.id, asset: asset.id)
    }

    /// Assignments, link order, saved views, custom statuses and fields: maths, persistence, wire, old data.
    static func flowModelTest(store: DeliverStore, project: UUID, asset id: UUID) {
        // Assignments: overdue maths, the assignee match, the reminder (once each, through the test hook).
        func with(due: String?, status: Deliver.Status = .inProgress, assignee: String? = "Editor") -> Deliver.Asset {
            var a = Deliver.Asset(name: "Hero 30s", kind: .video, status: status, versions: [.init(number: 1, path: "/x", size: 1)])
            a.fields = .init(assignee: assignee, due: due)
            return a
        }
        check("flow: overdue (before today, not approved; today isn't)", Deliver.isOverdue(with(due: "2026-11-18"), today: "2026-11-20")
              && !Deliver.isOverdue(with(due: "2026-11-20"), today: "2026-11-20") && !Deliver.isOverdue(with(due: "2026-11-18", status: .approved), today: "2026-11-20")
              && !Deliver.isOverdue(with(due: nil), today: "2026-11-20") && Deliver.dayAfter("2026-12-29", 7) == "2027-01-05")
        let team = [Deliver.Person(id: "e1", name: "Editor", email: "e@example.com", role: "editor"), Deliver.Person(id: "c1", name: "Client", email: "c@example.com", role: "client"),
                    Deliver.Person(id: "n1", name: "No Mail", role: "owner"), Deliver.Person(id: "s1", name: "Same", email: "a@example.com", role: "owner"),
                    Deliver.Person(id: "s2", name: "same", email: "b@example.com", role: "editor")]
        check("flow: an assignee maps to one teammate with an email, never a client",
              DeliverMail.teammate(" editor ", in: team) == "e1" && DeliverMail.teammate("Client", in: team) == nil
              && DeliverMail.teammate("No Mail", in: team) == nil && DeliverMail.teammate("Same", in: team) == nil && DeliverMail.teammate("Nobody", in: team) == nil)
        check("flow: assignee match (case, spaces)", Deliver.isAssigned(with(due: nil, assignee: " editor "), to: "Editor")
              && !Deliver.isAssigned(with(due: nil, assignee: "Producer"), to: "Editor") && !Deliver.isAssigned(with(due: nil, assignee: nil), to: "Editor"))
        let savedAuthor = UserDefaults.standard.string(forKey: DeliverSettings.authorKey), savedDue = UserDefaults.standard.stringArray(forKey: DeliverDeadlines.dueKey)
        defer {
            UserDefaults.standard.set(savedAuthor, forKey: DeliverSettings.authorKey)
            UserDefaults.standard.set(savedDue, forKey: DeliverDeadlines.dueKey)
        }
        UserDefaults.standard.set("Sam", forKey: DeliverSettings.authorKey)
        UserDefaults.standard.removeObject(forKey: DeliverDeadlines.dueKey)
        try? store.setField("assignee", "Sam", of: id, by: "Sam")
        try? store.setField("due", "2026-11-20", of: id, by: "Sam")
        let reminders = DeliverDeadlines(store: store, server: DeliverServer(store: store))
        var posted: [String] = [], heard: [Bool] = []
        reminders.posted = { posted.append($0) }
        let listener = NotificationCenter.default.addObserver(forName: .deliverAssignmentDue, object: nil, queue: nil) { note in
            if note.userInfo?["asset"] as? UUID == id { heard.append(note.userInfo?["overdue"] as? Bool ?? false) }
        }
        let day = { (d: Int, h: Int) in Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h))! }
        reminders.checkAssignments(now: day(20, 7))
        let early = posted.count
        reminders.checkAssignments(now: day(20, 10))
        reminders.checkAssignments(now: day(20, 11))
        reminders.checkAssignments(now: day(21, 10))
        reminders.checkAssignments(now: day(22, 10))
        NotificationCenter.default.removeObserver(listener)
        check("flow: due reminders (the morning it's due, once overdue, each once; hook told)", early == 0
              && posted == [DeliverDeadlines.dueText(store.find(id)!.asset, overdue: false), DeliverDeadlines.dueText(store.find(id)!.asset, overdue: true)]
              && posted.first == String(localized: "Hero is due today") && heard == [false, true], "\(posted) \(heard)")

        // Saved views: built-ins, matching, a custom one saved and read back; an old store without a library loads.
        let views = store.views
        let mine = store.assets(in: views[0], me: "sam", today: "2026-11-22"), overdue = store.assets(in: views[1], today: "2026-11-22")
        check("flow: built-in views (assigned to me, overdue, needs changes)", views.count == 3 && mine.map(\.asset.id) == [id] && overdue.map(\.asset.id) == [id]
              && store.assets(in: views[2]).isEmpty && store.assets(in: views[0], me: "Other").isEmpty)
        var custom = Deliver.SavedView(name: "Open, this project", openComments: true, projects: [project])
        let open = store.assets(in: custom).map(\.asset.id)
        custom.projects = [UUID()]
        let elsewhere = store.assets(in: custom).count
        custom.projects = nil
        custom.tag = "hero"
        let tagged = store.assets(in: custom).count
        store.editLibrary { $0.views = [custom] }
        let reread = DeliverStore(root: store.root)
        reread.load()
        let oldRoot = store.root.deletingLastPathComponent().appendingPathComponent("OldStore", isDirectory: true)
        try? FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        try? Data("[]".utf8).write(to: oldRoot.appendingPathComponent("projects.json"))
        let old = DeliverStore(root: oldRoot)
        old.load()
        check("flow: saved view filters and round trip; old store loads without views", open == [id] && elsewhere == 0 && tagged == 0
              && reread.library.views == [custom] && reread.views.count == 4 && old.library == Deliver.Library() && old.views.count == 3, "\(open) \(reread.library)")

        // Custom statuses: old JSON decodes, unknown ids are kept, round trip; the wire only names them when the link says so.
        let oldJSON = #"{"id":"\#(UUID().uuidString)","name":"Old","kind":"video","status":"needsChanges","versions":[],"created":"2026-11-01T10:00:00Z"}"#
        let unknownJSON = oldJSON.replacingOccurrences(of: "needsChanges", with: "c:zz9")
        let decodedOld = try? Deliver.decoder.decode(Deliver.Asset.self, from: Data(oldJSON.utf8))
        let decodedNew = try? Deliver.decoder.decode(Deliver.Asset.self, from: Data(unknownJSON.utf8))
        let again = decodedNew.flatMap { try? Deliver.encoder.encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        check("flow: status ids (old JSON, unknown kept, round trip)", decodedOld?.status == .needsChanges && decodedNew?.status.rawValue == "c:zz9"
              && decodedNew?.status.isBuiltin == false && again?.contains(#""status":"c:zz9""#) == true, again ?? "")
        let status = Deliver.StatusDef(id: "c:" + DeliverStore.shortID(), name: "Picture lock", colour: "violet")
        let field = Deliver.FieldDef(id: DeliverStore.shortID(), name: "Shot", kind: "select", options: ["Wide", "Close"])
        let flag = Deliver.FieldDef(id: DeliverStore.shortID(), name: "Graded", kind: "checkbox")
        store.editLibrary { $0.statuses = [status]; $0.fields = [field, flag] }
        store.setStatus(.init(rawValue: status.id), of: id, by: "Sam")
        var link = Deliver.ShareLink(title: "Cuts", scope: .project(project), roomID: "r")
        let plain = DeliverServer.linkInfo(link, store: store)
        link.customStatuses = true
        link.fields = ["status", field.wireName]
        let stray = UUID()
        link.order = [stray, id]
        let info = DeliverServer.linkInfo(link, store: store)
        let defs = info["statusDefs"] as? [[String: Any]], fieldWire = info["fieldDefs"] as? [[String: Any]]
        check("flow: custom statuses and fields on the wire (only when on, listed fields only; order of the project's ids)",
              plain["statusDefs"] == nil && plain["fieldDefs"] == nil && plain["order"] == nil && store.statusList.count == 6
              && defs?.first?["id"] as? String == status.id && defs?.first?["colour"] as? String == "violet"
              && fieldWire?.count == 1 && fieldWire?.first?["id"] as? String == field.wireName && fieldWire?.first?["options"] as? [String] == ["Wide", "Close"]
              && info["order"] as? [String] == [id.uuidString] && store.find(id)?.asset.status.rawValue == status.id, "\(info)")

        // Custom fields: values by kind, cleared, and back from a host's wire; a link record keeps order and the switch.
        let bad = (try? store.setField(field.wireName, "Medium", of: id, by: "Sam")) == nil
        try? store.setField(field.wireName, "Wide", of: id, by: "Sam")
        try? store.setField(flag.wireName, true, of: id, by: "Sam")
        let set = store.find(id)?.asset.customFields
        try? store.setField(flag.wireName, "", of: id, by: "Sam")
        let unknown = (try? store.setField("cf:nope", "x", of: id, by: "Sam")) == nil
        let number = Deliver.FieldDef(id: "n", name: "Take", kind: "number")
        let numbers = ((try? number.clean("12.5")) ?? nil) == "12.5" && (try? number.clean("twelve")) == nil
        check("flow: custom field values (choice checked, checkbox, cleared, unknown refused, numbers)", bad && unknown && numbers
              && set == [field.id: "Wide", flag.id: "1"] && store.find(id)?.asset.customFields == [field.id: "Wide"], "\(String(describing: set))")
        let host = Deliver.Host(name: "Test NAS", kind: .nas, address: nil)
        let wire: [String: Any] = ["id": UUID().uuidString, "name": "From host", "kind": "video", "status": status.id,
                                   "versions": [["id": UUID().uuidString, "number": 1, "size": 1]], "fields": ["rating": 3, field.wireName: "Close"]]
        let fromHost = DeliverSync.asset(wire, host: host)
        var linkWire = DeliverServer.linkInfo(link, store: store)
        linkWire.merge(["id": link.id.uuidString, "roomID": "r", "project": project.uuidString, "root": ["kind": "project", "id": project.uuidString], "customStatuses": true]) { $1 }
        let pageOnly = DeliverSync.link(linkWire)
        linkWire["ownOrder"] = [id.uuidString]
        let back = DeliverSync.link(linkWire)
        check("flow: from a host (custom field, custom status; link order from ownOrder, never the page's order, and switch)", fromHost?.customFields == [field.id: "Close"] && fromHost?.fields?.rating == 3
              && fromHost?.status.rawValue == status.id && back?.order == [id] && pageOnly?.order == nil && back?.customStatuses == true && back?.fields == ["status", field.wireName],
              "\(String(describing: fromHost)) \(String(describing: back))")

        // "As arranged": the order first, unknown ids ignored, the rest by name.
        let a = Deliver.Asset(name: "b", kind: .video, versions: [.init(number: 1, path: "/x", size: 1)]), b = Deliver.Asset(name: "a", kind: .video, versions: [.init(number: 1, path: "/x", size: 1)])
        let c = Deliver.Asset(name: "c", kind: .video, versions: [.init(number: 1, path: "/x", size: 1)])
        check("flow: as arranged (order first, missing by name, unknown ids ignored)",
              Deliver.arranged([a, b, c], order: [UUID(), c.id]).map(\.name) == ["c", "a", "b"] && Deliver.arranged([a, b, c], order: nil).map(\.name) == ["a", "b", "c"])
        store.setStatus(.inProgress, of: id, by: "Sam")
        store.editLibrary { $0 = .init() }
    }

    /// A green marker completes its comment, a deleted one asks, an editor's own imports once (tagged), re-pull is idempotent.
    static func resolvePullTest(store: DeliverStore, asset: Deliver.Asset, probe: Deliver.Probe) async {
        let version = asset.current
        guard let green = try? store.addComment(asset: asset.id, version: version.id, frame: 10, text: "Logo early", author: "Client"),
              let gone = try? store.addComment(asset: asset.id, version: version.id, frame: 20, text: "Warm", author: "Client"),
              let kept = try? store.addComment(asset: asset.id, version: version.id, frame: 30, text: "Cut", author: "Client"),
              let never = try? store.addComment(asset: asset.id, version: version.id, frame: 40, text: "Never sent", author: "Client")
        else { return check("flow: resolve comments", false) }
        // The timeline at 50 fps: Pluck's markers (one moved 2 frames, one green), one gone, and the editor's own.
        var markers: [[String: Any]] = [
            ["frame": 22, "data": "pluck:\(green.id.uuidString)", "color": "Green", "name": "", "note": ""],
            ["frame": 60, "data": "pluck:\(kept.id.uuidString)", "color": "Red", "name": "", "note": ""],
            ["frame": 100, "data": "", "color": "Blue", "name": "Fix the grade", "note": "too warm"],
            ["frame": 120, "data": "", "color": "Blue", "name": "re: Logo early", "note": ""],
            ["frame": 900, "data": "", "color": "Blue", "name": "Past the end", "note": ""],
        ]
        var tagged: [[String: Any]] = []
        DeliverResolveMarkers.bridge = { instruction in
            switch instruction["action"] as? String {
            case "timelineInfo": return ["timeline": "Hero edit", "rate": 50.0, "start": 0, "end": 200, "markers": markers]
            case "tagMarkers":
                tagged = instruction["tags"] as? [[String: Any]] ?? []
                for tag in tagged { if let i = markers.firstIndex(where: { $0["frame"] as? Int == tag["frame"] as? Int }) { markers[i]["data"] = tag["data"] } }
                return ["tagged": tagged.count]
            default: return [:]
            }
        }
        DeliverResolveMarkers.remember(["pluck:\(green.id.uuidString)", "pluck:\(gone.id.uuidString)", "pluck:\(kept.id.uuidString)"], timeline: "Hero edit")
        check("flow: markers sent to one timeline aren't 'removed' from another", !DeliverResolveMarkers.sent("Other cut").contains("pluck:\(gone.id.uuidString)")
              && DeliverResolveMarkers.sent("Hero edit").contains("pluck:\(gone.id.uuidString)"))
        let first = try? await DeliverResolveMarkers.read(version, comments: store.comments(asset.id, version: version.id))
        check("flow: resolve pull reads (green, removed, own; replies and past the end skipped)", first?.complete == [green.id] && first?.removed == [gone.id]
              && first?.new == [.init(frame: 50, markerFrame: 100, text: "Fix the grade\ntoo warm")] && first?.timeline == "Hero edit"
              && first?.removed.contains(never.id) == false, "\(String(describing: first))")
        // Asked once: removed ones stay open unless the owner says so.
        if let first { _ = try? await DeliverResolveMarkers.apply(first, asset: asset, version: version, markRemoved: false, store: store) }
        let all = store.comments(asset.id, version: version.id)
        let imported = all.first { $0.text == "Fix the grade\ntoo warm" }
        check("flow: resolve pull applies (completed, removed kept open, imported internal and tagged)",
              all.first { $0.id == green.id }?.completed == true && all.first { $0.id == gone.id }?.completed == false
              && imported?.isInternal == true && imported?.frame == 50 && imported?.author == DeliverSettings.author
              && tagged.first?["data"] as? String == imported.map { "pluck:\($0.id.uuidString)" } && tagged.first?["frame"] as? Int == 100,
              "\(all.map { ($0.text, $0.completed) }) \(tagged)")
        let second = try? await DeliverResolveMarkers.read(version, comments: store.comments(asset.id, version: version.id))
        check("flow: resolve re-pull is idempotent", second?.complete == [] && second?.new == [] && second?.removed == [gone.id], "\(String(describing: second))")
        if let second { _ = try? await DeliverResolveMarkers.apply(second, asset: asset, version: version, markRemoved: true, store: store) }
        check("flow: resolve removed marked done when asked", store.comment(gone.id)?.completed == true && store.comment(never.id)?.completed == false)
    }
}
