import Foundation

extension PhotoSelfTest {
    /// gy-photo (gap round 2026-11-23): Share with Client (Deliver gallery, picks back), sidecar failures told and retried,
    /// edits on the picture synced to the selection as one step.
    static func gyPhotoTest() async {
        // (Short retries from the start: a retry already waiting its minute would hold the sidecar test's back.)
        let retry = PhotoCatalog.sidecarRetry
        PhotoCatalog.sidecarRetry = .milliseconds(400)
        defer { PhotoCatalog.sidecarRetry = retry }
        await clientShareTest()
        await sidecarFailureTest()
        pictureSyncTest()
    }

    static func clientShareTest() async {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("GYPhoto-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        let savedEntries = PhotoClientShare.entries
        defer { PhotoClientShare.entries = savedEntries; PhotoClientShare.save(); try? fm.removeItem(at: base) }
        PhotoClientShare.entries = [:]
        let store = DeliverStore(root: base.appendingPathComponent("Review", isDirectory: true))
        let catalog = PhotoCatalog.shared
        let keys = ["a", "b", "c"].map { base.appendingPathComponent("Shoot/\($0).cr3").path }
        // (A stand-in export: a small file named after the photo.)
        let export: (String, URL) async throws -> URL = { key, folder in
            let url = Converting.outputURL(folder: folder.path, name: URL(fileURLWithPath: key).deletingPathExtension().lastPathComponent, fileExtension: "jpg")
            try Data("jpg".utf8).write(to: url)
            return url
        }
        guard let first = try? await PhotoClientShare.share(Array(keys.prefix(2)), title: "Wedding", store: store, exported: export) else {
            return check("client share: first gallery", false)
        }
        let assets = { store.content(first.project).assets.filter { $0.folder == first.folder } }
        check("client share: a new gallery in the Photos project, one image per photo", first.isNew && assets().count == 2
              && assets().allSatisfy { $0.kind == .image } && store.project(first.project)?.name == PhotoClientShare.projectName
              && store.content(first.project).folders.first { $0.id == first.folder }?.name == "Wedding", "\(assets().map(\.name))")
        guard let again = try? await PhotoClientShare.share([keys[0], keys[2]], title: "Other", store: store, exported: export) else {
            return check("client share: shared again", false)
        }
        let a = PhotoClientShare.entries[keys[0]]?.first.flatMap { store.find($0.asset)?.asset }
        check("client share: shared again goes to the same gallery, a new version for a photo already there", !again.isNew
              && again.folder == first.folder && assets().count == 3 && a?.versions.count == 2, "\(assets().count) \(a?.versions.count ?? 0)")
        // The page lists them as pictures (as any folder of pictures: nothing new on the wire for older hosts).
        if let link = try? store.newLink(scope: .folder(first.folder, project: first.project), title: "Wedding") {
            let list = (try? DeliverServer(store: store).list(first.folder.uuidString, link))?["assets"] as? [[String: Any]] ?? []
            check("client share: the link lists the gallery's pictures", list.count == 3 && list.allSatisfy { $0["kind"] as? String == "image" }, "\(list.count)")
        }
        // The client decides; the decisions come back onto the photos as one step.
        for key in keys { catalog.update([key]) { $0 = PhotoRecord() } }
        let ids = keys.map { PhotoClientShare.entries[$0]?.first?.asset }
        guard let id0 = ids[0], let id1 = ids[1], let id2 = ids[2], let asset0 = store.find(id0)?.asset else { return check("client share: entries", false) }
        _ = try? store.approve(asset: id0, version: asset0.current.id, decision: .approve, author: "Client")
        store.setStatus(.needsChanges, of: id1, by: "Client")
        try? store.setField("rating", 4, of: id2, by: "Client")
        let changed = PhotoClientShare.pullDecisions(store: store)
        let records = keys.map(catalog.record)
        check("client share: approved = pick, changes = red label, rating = stars", changed == 3 && records[0].flag == .pick
              && records[1].label == "red" && records[2].rating == 4, "\(changed) \(records.map { "\($0.flag) \($0.label ?? "-") \($0.rating)" })")
        catalog.undo()
        check("client share: the decisions undo as one step", keys.map(catalog.record).allSatisfy { $0 == PhotoRecord() })
        catalog.redo()
        catalog.update([keys[0]]) { $0.flag = .none }
        check("client share: a decision already taken isn't put back over the owner's change",
              PhotoClientShare.pullDecisions(store: store) == 0 && catalog.record(keys[0]).flag == .none)
        store.setStatus(.needsChanges, of: id0, by: "Client")
        _ = PhotoClientShare.pullDecisions(store: store)
        check("client share: a new decision comes back", catalog.record(keys[0]).label == "red")
        // Without the Photo page: a decision comes back through the store's events (as a host's pull brings it), once.
        PhotoClientShare.watch(store)
        catalog.update([keys[1]]) { $0 = PhotoRecord() }
        store.setStatus(.approved, of: id1, by: "Client")
        try? await Task.sleep(for: .seconds(1.2))
        check("client share: a decision comes back without the Photo page", catalog.record(keys[1]).flag == .pick)
        catalog.undo()
        check("client share: ...as one step", catalog.record(keys[1]).flag == .none && PhotoClientShare.pullDecisions(store: store) == 0)
        // An asset deleted in Deliver: its export out of the way, the photo's mapping dropped.
        let savedDiscard = PhotoClientShare.discard
        var discarded: [String] = []
        PhotoClientShare.discard = { discarded.append($0.path); try? fm.removeItem(at: $0) }
        defer { PhotoClientShare.discard = savedDiscard }
        let files = PhotoClientShare.entries[keys[0]]?.first?.files ?? []
        store.remove(asset: id0)
        try? await Task.sleep(for: .seconds(1.2))
        check("client share: a deleted asset's exports go, its mapping too", files.count == 2 && Set(discarded) == Set(files)
              && files.allSatisfy { !fm.fileExists(atPath: $0) } && PhotoClientShare.entries[keys[0]] == nil && PhotoClientShare.entries[keys[2]] != nil,
              "\(files.count) \(discarded.count)")
        store.listeners.removeAll()
        for key in keys { catalog.update([key]) { $0 = PhotoRecord() } }
    }

    static func sidecarFailureTest() async {
        let fm = FileManager.default
        let folder = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("GYSidecar-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let photo = folder.appendingPathComponent("IMG_0001.jpg")
        fm.createFile(atPath: photo.path, contents: Data("x".utf8))
        let defaults = UserDefaults.standard, wrote = defaults.bool(forKey: "photoWriteXMP")
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? fm.removeItem(at: folder)
            defaults.set(wrote, forKey: "photoWriteXMP")
        }
        defaults.set(true, forKey: "photoWriteXMP")
        try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        let catalog = PhotoCatalog.shared
        // (Earlier tests' sidecars written or let go first.)
        try? await Task.sleep(for: .seconds(2))
        catalog.sidecarProblem = nil
        catalog.update([photo.path]) { $0.rating = 3 }
        for _ in 0..<20 where catalog.sidecarProblem != folder.path { try? await Task.sleep(for: .milliseconds(200)) }
        let sidecar = PhotoXMP.sidecars(for: photo.path)[0]
        check("sidecars: a folder that can't be written is told, the edit kept", catalog.sidecarProblem == folder.path
              && catalog.sidecarsFailed.contains(photo.path) && catalog.record(photo.path).rating == 3 && !fm.fileExists(atPath: sidecar.path),
              "\(catalog.sidecarProblem ?? "nil") \(catalog.sidecarsFailed.count)")
        catalog.sidecarProblem = nil
        catalog.update([photo.path]) { $0.rating = 4 }
        try? await Task.sleep(for: .seconds(1.2))
        check("sidecars: told once per folder", catalog.sidecarProblem == nil)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        var written = false
        for _ in 0..<20 where !written {
            try? await Task.sleep(for: .milliseconds(300))
            written = fm.fileExists(atPath: sidecar.path)
        }
        check("sidecars: written once the folder can be", written && catalog.sidecarsFailed.isEmpty && PhotoXMP.read(photo.path)?.rating == 4,
              "\(written) \(catalog.sidecarsFailed.count)")
        catalog.update([photo.path]) { $0 = PhotoRecord() }
    }

    static func pictureSyncTest() {
        let paths = (1...3).map { "/tmp/pluck-selftest/picture-sync-\($0).jpg" }
        let catalog = PhotoCatalog.shared, editing = PhotoEditing.shared
        let saved = (editing.syncAll, editing.selected)
        defer { editing.syncAll = saved.0; editing.selected = saved.1; for p in paths { catalog.update([p]) { $0 = PhotoRecord() } } }
        editing.selected = paths
        editing.syncAll = true
        catalog.endStep()
        editing.editShown(paths[1]) { $0.adjust.straighten = 4 }
        check("picture sync: straighten on the picture reaches the selection", paths.allSatisfy { catalog.record($0).adjust.straighten == 4 })
        catalog.undo()
        check("picture sync: one step to undo", paths.allSatisfy { catalog.record($0).adjust.straighten == 0 })
        editing.syncAll = false
        catalog.endStep()
        editing.editShown(paths[1]) { $0.adjust.straighten = 2 }
        check("picture sync: off, only the photo shown", paths.map { catalog.record($0).adjust.straighten } == [0, 2, 0])
        editing.syncAll = true
        editing.selected = [paths[0]]
        catalog.endStep()
        editing.editShown(paths[2]) { $0.adjust.straighten = 1 }
        check("picture sync: a photo outside the selection alone", paths.map { catalog.record($0).adjust.straighten } == [0, 2, 1])
        // Match Exposure's several photos: one step.
        catalog.endStep()
        catalog.group { for p in paths { catalog.update([p]) { $0.adjust.exposure = 0.5 } } }
        catalog.undo()
        check("picture sync: a group of single-photo changes undoes as one", paths.allSatisfy { catalog.record($0).adjust.exposure == 0 })
    }
}
