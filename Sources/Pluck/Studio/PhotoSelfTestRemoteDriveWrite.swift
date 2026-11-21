import Foundation

extension PhotoSelfTest {
    /// Writing to the drive (RemoteDriveWrite), without a mount: what stays local, the office's publish, versions,
    /// trash and conflict copies, and an overlay picked up again after a restart.
    static func remoteDriveWriteUnits() {
        check("drive write: macOS and Resolve junk stays on this Mac", [".DS_Store", "Day 1/._A001.mov", ".Spotlight-V100/x", ".fseventsd",
                                                                       ".Trashes", "Proj/CacheClip/a.bin", "Proj/.gallery/s.png", "OptimizedMedia/x.mov",
                                                                       "ProxyMedia/x.mov", "Proj/edit.lck", "a:b.txt", "(A Document Being Saved By Pluck)/x"].allSatisfy(RemoteDriveOverlay.keepsLocal)
              && !["notes.txt", "Day 1/Edit v2.drp", "Renders/final.mov"].contains(where: RemoteDriveOverlay.keepsLocal))
        check("drive write: a conflict copy is named after the Mac", RemoteDriveWriteHost.conflictName("edit.drp", mac: "Studio Mac") == "edit (Studio Mac).drp"
              && RemoteDriveWriteHost.conflictName("README", mac: "M") == "README (M)")

        let fm = FileManager.default
        let made = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("DriveWrite-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: made.appendingPathComponent("Day 1"), withIntermediateDirectories: true)
        // (Real paths, as the office's resolve gives them.)
        let root = URL(fileURLWithPath: RemoteEditHost.realPath(made.path) ?? made.path, isDirectory: true)
        let folder = root.appendingPathComponent("Day 1", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        func part(_ text: String) -> URL {
            let url = folder.appendingPathComponent(".part-\(UUID().uuidString)")
            fm.createFile(atPath: url.path, contents: Data(text.utf8))
            return url
        }
        func text(_ name: String) -> String? { (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) }
        let first = try? RemoteDriveWriteHost.publish(part("one"), root: root, folder: folder, name: "notes.txt", modified: 1_700_000_000, base: nil, mac: "M")
        check("drive write: a new file is placed", first?["name"] as? String == "notes.txt" && first?["conflict"] as? Bool == false && text("notes.txt") == "one")
        let stamp = RemoteDriveWriteHost.stamp(of: folder.appendingPathComponent("notes.txt"))
        _ = try? RemoteDriveWriteHost.publish(part("two"), root: root, folder: folder, name: "notes.txt", modified: 1_700_000_100, base: stamp, mac: "M")
        let versions = fm.enumerator(atPath: root.appendingPathComponent(RemoteDriveWriteHost.versionsName).path)?.allObjects as? [String] ?? []
        let kept = versions.first { $0.hasSuffix(".txt") }.flatMap { try? String(contentsOf: root.appendingPathComponent(RemoteDriveWriteHost.versionsName).appendingPathComponent($0), encoding: .utf8) }
        check("drive write: replacing an unchanged file keeps the old one in versions", text("notes.txt") == "two" && kept == "one", "\(versions)")
        // The office's file changed since (stamp is the first one's): never overwritten.
        let clash = try? RemoteDriveWriteHost.publish(part("three"), root: root, folder: folder, name: "notes.txt", modified: 1_700_000_200, base: stamp, mac: "M")
        check("drive write: a file changed at the office gets this Mac's copy beside it", clash?["name"] as? String == "notes (M).txt"
              && clash?["conflict"] as? Bool == true && text("notes.txt") == "two" && text("notes (M).txt") == "three")
        let newClash = try? RemoteDriveWriteHost.publish(part("four"), root: root, folder: folder, name: "notes.txt", modified: 1_700_000_300, base: nil, mac: "M")
        check("drive write: a new file where the office has one is a conflict too", newClash?["conflict"] as? Bool == true && text("notes.txt") == "two",
              "\(String(describing: newClash))")
        let changedBase = RemoteDriveOverlay.Stamp(size: 99, modified: 1)
        let notTrashed = try? RemoteDriveWriteHost.remove(folder.appendingPathComponent("notes.txt"), root: root, base: changedBase)
        let trashed = try? RemoteDriveWriteHost.remove(folder.appendingPathComponent("notes (M).txt"), root: root, base: nil)
        let trash = fm.enumerator(atPath: root.appendingPathComponent(RemoteDriveWriteHost.trashName).path)?.allObjects as? [String] ?? []
        check("drive write: a delete moves to the trash, never one changed at the office", notTrashed == false && trashed == true && text("notes.txt") == "two"
              && text("notes (M).txt") == nil && trash.contains { $0.hasSuffix("Day 1/notes (M).txt") }, "\(trash)")
        check("drive write: a folder with the office's files in it isn't deleted", (try? RemoteDriveWriteHost.remove(folder, root: root, base: nil)) == nil
              && fm.fileExists(atPath: folder.path))
        let old = root.appendingPathComponent(RemoteDriveWriteHost.trashName).appendingPathComponent("2001-01-01")
        try? fm.createDirectory(at: old, withIntermediateDirectories: true)
        RemoteDriveWriteHost.cleanup(folder: folder, now: Date.now.addingTimeInterval(400 * 86_400))
        check("drive write: versions and trash are never emptied by Pluck (the owner's storage)", fm.fileExists(atPath: old.path) && !trash.isEmpty)
        check("drive write: nobody writes into versions or trash", RemoteDriveWriteHost.inHidden(".pluck-trash/2001-01-01")
              && RemoteDriveWriteHost.inHidden(RemoteDriveWriteHost.versionsName) && !RemoteDriveWriteHost.inHidden("Day 1/.pluck-trash") && !RemoteDriveWriteHost.inHidden(""))
        let stalePart = RemoteSendInto.partial(folder, name: "gone.mov", size: 10, modified: 1), freshPart = RemoteSendInto.partial(folder, name: "going.mov", size: 10, modified: 2)
        fm.createFile(atPath: stalePart.path, contents: Data(count: 4)); fm.createFile(atPath: freshPart.path, contents: Data(count: 4))
        try? fm.setAttributes([.modificationDate: Date.now.addingTimeInterval(-2 * 86_400)], ofItemAtPath: stalePart.path)
        RemoteDriveWriteHost.cleanup(folder: folder)
        check("drive write: uploads left unfinished for a day go, newer ones stay", !fm.fileExists(atPath: stalePart.path) && fm.fileExists(atPath: freshPart.path))

        // Hostile numbers at the boundary: refused, never a crash.
        let odd = [Double.nan, .infinity, -.infinity, 1e300].map { RemoteSendInto.partial(folder, name: "a", size: 1, modified: $0).lastPathComponent }
        check("drive write: odd modification times make a plain partial name", odd.allSatisfy { $0.hasPrefix(".a.1-") && $0.hasSuffix(".pluckpart") }, "\(odd)")
        check("drive write: an offset or size that would overflow is refused",
              (try? RemoteSendInto.receive(into: folder, name: "a", size: 100, modified: 0, offset: Int64.max - 2, data: Data(count: 10), sha256: nil)) == nil
              && (try? RemoteSendInto.receive(into: folder, name: "a", size: -5, modified: 0, offset: 0, data: Data(count: 10), sha256: nil)) == nil)
        let longName = RemoteDriveWriteHost.conflictName("x." + String(repeating: "e", count: 200), mac: String(repeating: "M", count: 60))
        check("drive write: a conflict name for a very long extension doesn't break", longName.contains("(MMMM"))

        // A renamed folder the office gave another name: what's in it follows.
        let units = RemoteDriveOverlay(office: "test-\(UUID().uuidString)", share: "units")
        defer { try? fm.removeItem(at: units.folder) }
        _ = try? units.create("F", folder: true)
        _ = try? units.create("F/x.txt", folder: false)
        units.sent(spool: nil, path: "F", version: 0, remote: "F", base: nil, conflict: false)
        units.sent(spool: units.snapshot.items["F/x.txt"]?.spool, path: "F/x.txt", version: 0, remote: "F/x.txt", base: nil, conflict: false)
        try? units.rename("F", to: "G")
        if let op = units.nextOp() { units.opDone(op, renamed: "G (M)") }
        check("drive write: a folder renamed under another name at the office takes its files' office paths along",
              units.snapshot.items["G"]?.remote == "G (M)" && units.snapshot.items["G/x.txt"]?.remote == "G (M)/x.txt", "\(units.snapshot.items.mapValues { $0.remote })")
        check("drive write: a folder never moves into its own subfolder", (try? units.rename("G", to: "G/inner")) == nil && units.snapshot.items["G"] != nil)
        // Renamed here while its last piece went: placed under the old name, so the office renames it after.
        _ = try? units.create("G/a.txt", folder: false)
        let spoolA = units.snapshot.items["G/a.txt"]?.spool
        try? units.rename("G/a.txt", to: "G/b.txt")
        while let op = units.nextOp() { units.opDone(op) }
        units.sent(spool: spoolA, path: "G/a.txt", version: 0, remote: "G (M)/a.txt", base: nil, conflict: false)
        check("drive write: a rename during the last piece keeps the new name and renames at the office",
              units.snapshot.items["G/b.txt"]?.remote == "G (M)/b.txt" && units.nextOp() == .rename(from: "G (M)/a.txt", to: "G (M)/b.txt", base: nil),
              "\(String(describing: units.snapshot.items["G/b.txt"]?.remote)) \(String(describing: units.nextOp()))")
    }

    /// Over the real mount (`point`, a paired office on this Mac sharing `root`, share `id`).
    static func driveWrites(point: URL, root: URL, id: String, office: String, mac: String) async {
        let fm = FileManager.default
        let network = RemoteNetwork.shared, writes = RemoteDriveWrites.shared
        func onOffice(_ path: String) -> String? { try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
        func wait(_ what: String, _ done: () -> Bool) async -> Bool {
            for _ in 0..<150 where !done() { try? await Task.sleep(for: .milliseconds(100)) }
            return done()
        }
        /// File work on the mount, off the main thread (the drive's own answers need it).
        func onMount<T: Sendable>(_ work: @escaping @Sendable (URL) -> T) async -> T { await Task.detached { work(point) }.value }

        check("drive write: the office takes writes, the drive is read-write", network.hostWrites == true && writes.summary(id).pending == 0)
        // A file written on the drive goes to the office once it's left alone (left in the overlay until then).
        let wrote = await onMount { point in
            guard let handle = FileHandle(forWritingAtPath: point.appendingPathComponent("Day 1/notes.txt").path)
                    ?? (FileManager.default.createFile(atPath: point.appendingPathComponent("Day 1/notes.txt").path, contents: nil)
                        ? FileHandle(forWritingAtPath: point.appendingPathComponent("Day 1/notes.txt").path) : nil) else { return false }
            try? handle.write(contentsOf: Data("first version".utf8))
            try? handle.close()
            return true
        }
        check("drive write: a new file on the drive", wrote)
        check("drive write: it reaches the office whole", await wait("notes") { onOffice("Day 1/notes.txt") == "first version" }, String(describing: onOffice("Day 1/notes.txt")))
        let listed = await onMount { (try? FileManager.default.contentsOfDirectory(atPath: $0.appendingPathComponent("Day 1").path).sorted()) ?? [] }
        check("drive write: listed beside the proxies", listed.contains("A001.mov") && listed.contains("notes.txt"), "\(listed)")
        check("drive write: reads back", await onMount { try? String(contentsOf: $0.appendingPathComponent("Day 1/notes.txt"), encoding: .utf8) } == "first version")

        // Saved again: the office's earlier one goes to versions.
        _ = await onMount { try? Data("second version".utf8).write(to: $0.appendingPathComponent("Day 1/notes.txt")) }
        check("drive write: saved again replaces it at the office", await wait("again") { onOffice("Day 1/notes.txt") == "second version" })
        let versions = fm.enumerator(atPath: root.appendingPathComponent(RemoteDriveWriteHost.versionsName).path)?.allObjects as? [String] ?? []
        check("drive write: the office keeps the replaced version", versions.contains { $0.contains("Day 1/notes ") }, "\(versions)")

        // Junk and Resolve caches stay here.
        _ = await onMount { point in
            let fm = FileManager.default
            fm.createFile(atPath: point.appendingPathComponent(".DS_Store").path, contents: Data("junk".utf8))
            try? fm.createDirectory(at: point.appendingPathComponent("CacheClip"), withIntermediateDirectories: true)
            fm.createFile(atPath: point.appendingPathComponent("CacheClip/render.bin").path, contents: Data(repeating: 3, count: 5000))
            fm.createFile(atPath: point.appendingPathComponent("Day 1/project.lck").path, contents: Data("lock".utf8))
        }
        // An app's save: written under a hidden name, then renamed over the real one.
        _ = await onMount { point in
            FileManager.default.createFile(atPath: point.appendingPathComponent("Day 1/.edit.tmp").path, contents: Data("saved edit".utf8))
            rename(point.appendingPathComponent("Day 1/.edit.tmp").path, point.appendingPathComponent("Day 1/edit.drp").path)
        }
        check("drive write: a save through a hidden name lands under the real one", await wait("edit") { onOffice("Day 1/edit.drp") == "saved edit" })
        try? await Task.sleep(for: .seconds(1))
        await writes.settled()
        check("drive write: junk and caches never reach the office", !fm.fileExists(atPath: root.appendingPathComponent(".DS_Store").path)
              && !fm.fileExists(atPath: root.appendingPathComponent("CacheClip").path) && !fm.fileExists(atPath: root.appendingPathComponent("Day 1/project.lck").path)
              && !fm.fileExists(atPath: root.appendingPathComponent("Day 1/.edit.tmp").path))
        check("drive write: but they're there on the drive", await onMount { FileManager.default.fileExists(atPath: $0.appendingPathComponent("CacheClip/render.bin").path)
            && FileManager.default.fileExists(atPath: $0.appendingPathComponent(".DS_Store").path) })

        // The office's file changed meanwhile: it stays, this Mac's goes beside it, and the user is told.
        try? Data("changed at the office".utf8).write(to: root.appendingPathComponent("Day 1/notes.txt"))
        try? fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: root.appendingPathComponent("Day 1/notes.txt").path)
        _ = await onMount { try? Data("third version".utf8).write(to: $0.appendingPathComponent("Day 1/notes.txt")) }
        let copy = "Day 1/" + RemoteDriveWriteHost.conflictName("notes.txt", mac: mac)
        check("drive write: a conflict keeps the office's file and saves this one beside it", await wait("conflict") { onOffice(copy) == "third version" }
              && onOffice("Day 1/notes.txt") == "changed at the office", copy)
        check("drive write: the conflict is listed", await wait("listed") { writes.summary(id).conflicts.contains { $0.path == "Day 1/notes.txt" } })
        writes.seen(id, "Day 1/notes.txt")

        // Folders, renames and deletes.
        _ = await onMount { point in
            let fm = FileManager.default
            try? fm.createDirectory(at: point.appendingPathComponent("Renders"), withIntermediateDirectories: true)
            fm.createFile(atPath: point.appendingPathComponent("Renders/cut.mov").path, contents: Data(repeating: 9, count: 3_000_000))
        }
        check("drive write: a new folder with a file in it", await wait("renders") {
            (try? Data(contentsOf: root.appendingPathComponent("Renders/cut.mov")))?.count == 3_000_000 })
        _ = await onMount { rename($0.appendingPathComponent("Renders/cut.mov").path, $0.appendingPathComponent("Renders/final cut.mov").path) }
        check("drive write: a rename goes to the office", await wait("rename") { fm.fileExists(atPath: root.appendingPathComponent("Renders/final cut.mov").path)
            && !fm.fileExists(atPath: root.appendingPathComponent("Renders/cut.mov").path) })
        // "New Folder with Selection": a new folder and a sent file moved into it at once (the rename waits for the folder).
        _ = await onMount { point in
            try? FileManager.default.createDirectory(at: point.appendingPathComponent("Renders/Picked"), withIntermediateDirectories: false)
            rename(point.appendingPathComponent("Renders/final cut.mov").path, point.appendingPathComponent("Renders/Picked/final cut.mov").path)
        }
        check("drive write: a sent file moved into a new folder lands there at the office", await wait("picked") {
            fm.fileExists(atPath: root.appendingPathComponent("Renders/Picked/final cut.mov").path) }
            && !fm.fileExists(atPath: root.appendingPathComponent("Renders/final cut.mov").path) && writes.summary(id).problems.isEmpty, "\(writes.summary(id).problems)")
        _ = await onMount { try? FileManager.default.removeItem(at: $0.appendingPathComponent("Day 1/edit.drp")) }
        check("drive write: a delete goes to the office's trash", await wait("delete") { !fm.fileExists(atPath: root.appendingPathComponent("Day 1/edit.drp").path) }
              && (fm.enumerator(atPath: root.appendingPathComponent(RemoteDriveWriteHost.trashName).path)?.allObjects as? [String] ?? []).contains { $0.hasSuffix("Day 1/edit.drp") })

        // The office's proxies and manifest are never written.
        let proxyRefused = await onMount { point -> Bool in
            let file = point.appendingPathComponent("Day 1/A001.mov").path
            return FileHandle(forWritingAtPath: file) == nil && unlink(file) != 0 && unlink(point.appendingPathComponent(RemoteManifest.fileName).path) != 0
                && !FileManager.default.createFile(atPath: file, contents: Data())
        }
        check("drive write: proxies and the manifest can't be changed", proxyRefused)

        // A folder where this Mac is only a Viewer: refused there (EACCES), the rest still writable.
        guard let device = OfficeRenderServer.shared.devices.first(where: { !$0.isPeer }) else { return check("drive write: paired Mac", false) }
        let key = OfficeAccess.folderKey(root: root, share: id, relative: "Day 1")
        OfficeAccess.shared.set(subject: device.id.uuidString, folder: key, role: .viewer)
        RemoteDriveWrites.shared.overlay(office: office, share: id).forgetAccess(answers: true)
        let refusedThere = await onMount { point -> (Bool, Int32, Bool) in
            let made = FileManager.default.createFile(atPath: point.appendingPathComponent("Day 1/viewer.txt").path, contents: Data("x".utf8))
            let fd = open(point.appendingPathComponent("Day 1/viewer2.txt").path, O_WRONLY | O_CREAT, 0o644)
            let code = fd < 0 ? errno : 0
            if fd >= 0 { close(fd) }
            return (made, code, FileManager.default.createFile(atPath: point.appendingPathComponent("Renders/still.txt").path, contents: Data("y".utf8)))
        }
        check("drive write: a Viewer's folder refuses writes (EACCES), others don't", !refusedThere.0 && refusedThere.1 == EACCES && refusedThere.2, "\(refusedThere)")
        OfficeAccess.shared.set(subject: device.id.uuidString, folder: key, role: nil)
        check("drive write: nothing waits at the end", await wait("idle") { writes.summary(id).pending == 0 }, "\(writes.summary(id))")

        // Two offices with a share of the same id: each keeps its own overlay.
        let first = writes.overlay(office: "test-a-\(office)", share: id), second = writes.overlay(office: "test-b-\(office)", share: id)
        check("drive write: overlays go by office and share", writes.overlay(office: "test-a-\(office)", share: id) === first && first !== second
              && writes.overlay(office: office, share: id).office == office)
        try? fm.removeItem(at: first.folder); try? fm.removeItem(at: second.folder)
    }

    // Needs Resolve (written down, not run here: the self-tests never start Resolve). On a home Mac streaming a share from
    // an office where it's an Editor: in Resolve, Project Manager > Export Project to "<drive>/Day 1/Test.drp", then
    // Export again (replace), then Media > Render a short clip to "<drive>/Renders". Expect: Test.drp at the office with
    // the first one in .pluck-versions; the render there whole once Resolve finishes; no CacheClip, .gallery or *.lck at
    // the office; "0 waiting to upload" afterwards. Then edit Test.drp at the office and export again: "Test (<Mac>).drp".

    /// Before the writable mount: an overlay with a file written while the office was away, picked up after a "restart"
    /// (a new overlay from the same folder) and sent then.
    static func driveWritesAfterRestart(root: URL, id: String, office: String) async {
        let before = RemoteDriveOverlay(office: office, share: id)
        before.hostWrites = true
        _ = try? before.create("Day 1/offline.txt", folder: false)
        _ = try? await before.write("Day 1/offline.txt", offset: 0, data: Data("written offline".utf8))
        before.commit("Day 1/offline.txt")
        let after = RemoteDriveOverlay(office: office, share: id)
        let item = after.snapshot.items["Day 1/offline.txt"]
        let back = try? await after.read("Day 1/offline.txt", offset: 0, count: 100)
        check("drive write: unsent writes survive a restart", item?.state == .pending && item?.size == 15 && back == Data("written offline".utf8))
        let sent = await RemoteDriveWrites.pass(after)
        check("drive write: and go once the office answers", sent && (try? String(contentsOf: root.appendingPathComponent("Day 1/offline.txt"), encoding: .utf8)) == "written offline"
              && after.snapshot.items["Day 1/offline.txt"]?.state == .sent)

        // Saved again (to a temporary name, renamed over) while the first save went: the newer one stays waiting and goes.
        _ = try? after.create("Day 1/race.txt", folder: false)
        _ = try? await after.write("Day 1/race.txt", offset: 0, data: Data("old".utf8))
        after.commit("Day 1/race.txt")
        let picked = after.snapshot.items["Day 1/race.txt"]
        _ = try? after.create("Day 1/.race.tmp", folder: false)
        _ = try? await after.write("Day 1/.race.tmp", offset: 0, data: Data("new".utf8))
        after.commit("Day 1/.race.tmp")
        try? after.rename("Day 1/.race.tmp", to: "Day 1/race.txt")
        after.commit("Day 1/race.txt")
        after.sent(spool: picked?.spool, path: "Day 1/race.txt", version: picked?.version ?? 0, remote: "Day 1/race.txt", base: nil, conflict: false)
        let racing = after.snapshot.items["Day 1/race.txt"]
        check("drive write: a save during an upload stays waiting (the office path kept)", racing?.state == .pending && racing?.remote == "Day 1/race.txt"
              && racing?.spool != picked?.spool, "\(String(describing: racing))")
        let raced = await RemoteDriveWrites.pass(after)
        check("drive write: and the newer save is what reaches the office", raced && (try? String(contentsOf: root.appendingPathComponent("Day 1/race.txt"), encoding: .utf8)) == "new"
              && after.snapshot.items["Day 1/race.txt"]?.state == .sent)

        // A sent file written again: fetched back once however many writes wait, which hear "busy" (JUKEBOX) meanwhile.
        after.dropSentSpools()
        let fetches = FetchCount()
        after.fetch = { _, offset, count in
            fetches.add()
            try await Task.sleep(for: .milliseconds(1500))
            return Data("written offline".utf8).subdata(in: Int(offset)..<min(15, Int(offset) + count))
        }
        async let one: Bool = (try? await after.write("Day 1/offline.txt", offset: 0, data: Data("W".utf8))) == nil
        async let two: Bool = (try? await after.write("Day 1/offline.txt", offset: 1, data: Data("R".utf8))) == nil
        let busy = await [one, two]
        try? await Task.sleep(for: .milliseconds(1200))
        let then = try? await after.write("Day 1/offline.txt", offset: 0, data: Data("W".utf8))
        let backAgain = try? await after.read("Day 1/offline.txt", offset: 0, count: 100)
        check("drive write: one fetch back for waiting writes, busy meanwhile, then written", busy == [true, true] && fetches.value == 1 && then != nil
              && backAgain == Data("Written offline".utf8), "\(busy) \(fetches.value) \(String(describing: backAgain.map { String(decoding: $0, as: UTF8.self) }))")
        _ = await RemoteDriveWrites.pass(after)
    }
}
