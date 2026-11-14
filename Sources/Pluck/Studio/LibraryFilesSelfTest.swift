import AppKit
import SwiftUI

/// The Library's file actions (-PluckScreenshotOnly finderfiles): undo and redo of each, names
/// already taken (Keep Both, Replace, Skip), a checked copy's undo and the Library following a
/// move to another drive, and a cancelled copy leaving no part file. In a folder of the test's own.
extension PhotoSelfTest {
    static func finderFilesTest() async {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("PluckFilesTest-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let undo = FileUndo.shared, library = LibraryStore.shared
        // (The test's own files, out of the Trash again at the end.)
        var inTrash: [URL] = []
        defer {
            for url in inTrash { try? fm.removeItem(at: url) }
            try? fm.removeItem(at: dir)
            library.remove(library.entries.filter { $0.path.hasPrefix(dir.path) })
        }
        func write(_ name: String, _ text: String = "x") -> URL {
            let url = dir.appendingPathComponent(name)
            try? text.data(using: .utf8)!.write(to: url)
            return url
        }
        func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
        func entry(_ url: URL) -> Bool { library.entries.contains { $0.path == url.path } }
        func add(_ url: URL) {
            library.insert(LibraryStore.Entry(path: url.path, title: url.lastPathComponent, uploader: nil, source: nil, duration: nil,
                                              size: nil, thumbnail: nil, added: .now, transcriptID: nil))
        }
        func lastRedoPlace() -> URL? {
            if case .move(let place, _)? = undo.redoStack.last?.steps.first(where: { if case .move = $0 { return true }; return false }),
               FileUndo.inTrash(place.path) { return place }
            return nil
        }
        func lastTrashed() -> URL? {
            if case .move(let place, _)? = undo.undoStack.last?.steps.first { return place }
            return nil
        }

        // Rename: undone and redone, the Library following.
        let a = write("a.txt")
        add(a)
        let b = try? FinderFiles.rename(a, to: "b.txt")
        check("files: rename is an undo", undo.undoName == String(localized: "Rename"), undo.undoName ?? "-")
        check("files: undo rename", undo.undo() == nil && exists(a) && b.map { !exists($0) } == true && entry(a))
        check("files: redo rename", undo.redo() == nil && b.map(exists) == true && !exists(a) && b.map(entry) == true)

        // Move into a folder (same drive), several at once: one undo.
        let folder = dir.appendingPathComponent("into", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let c = write("c.txt")
        let before = undo.undoStack.count
        _ = FinderFiles.move([b!, c], into: folder)
        check("files: a move of two is one undo", undo.undoStack.count == before + 1 && exists(folder.appendingPathComponent("b.txt")))
        check("files: Library follows the move", entry(folder.appendingPathComponent("b.txt")))
        undo.undo()
        check("files: undo move", exists(b!) && exists(c) && !exists(folder.appendingPathComponent("c.txt")) && entry(b!))
        undo.redo()
        check("files: redo move", exists(folder.appendingPathComponent("c.txt")) && !exists(c))
        undo.undo()

        // Duplicate: undo sends the copy to the Trash (its Library entry waits there), redo puts it back.
        let copy = try? await FinderFiles.duplicate(b!)
        check("files: duplicate in the Library", copy.map(entry) == true)
        undo.undo()
        check("files: undo duplicate (to the Trash)", copy.map { !exists($0) && !entry($0) } == true)
        undo.redo()
        check("files: redo duplicate", copy.map { exists($0) && entry($0) } == true)

        // New folder.
        let pane = FinderPane(url: dir)
        await settle(pane)
        pane.newFolderInPlace()
        pane.naming = nil
        let untitled = dir.appendingPathComponent(String(localized: "untitled folder"))
        check("files: new folder is an undo", undo.undoName == String(localized: "New Folder") && exists(untitled))
        undo.undo()
        if let place = lastRedoPlace() { inTrash.append(place) }
        check("files: undo new folder", !exists(untitled))

        // Trash: put back from where it went; the Library entry back with it.
        var went: [URL: URL] = [:]
        FinderFiles.trash([b!]) { went = $0 }
        check("files: trashed, not deleted", !exists(b!) && went[b!].map { fm.fileExists(atPath: $0.path) } == true && !entry(b!))
        undo.undo()
        check("files: put back from the Trash", exists(b!) && entry(b!))
        undo.redo()
        if let place = lastTrashed() { inTrash.append(place) }
        check("files: redo trash", !exists(b!) && !entry(b!))
        undo.undo()

        // Names taken: Keep Both, Replace (the one there to the Trash), Skip; Apply to All.
        let x = write("x.txt", "new"), thereX = write("into/x.txt", "old")
        let y = write("y.txt", "new"), thereY = write("into/y.txt", "old")
        let realAsk = FileClash.ask
        var asked = 0
        FileClash.ask = { _, _, more in asked += 1; return (.keepBoth, more) }
        var plan = FileClash.plan([x, y], into: folder)
        check("files: keep both names", plan.names[x] == "x 2.txt" && plan.names[y] == "y 2.txt" && asked == 1, "\(plan.names) asked \(asked)")
        FileClash.ask = { _, _, _ in (.skip, false) }
        plan = FileClash.plan([x], into: folder)
        check("files: skip", plan.items.isEmpty)
        FileClash.ask = { _, _, _ in (.replace, false) }
        undo.grouped(String(localized: "Move")) {
            plan = FileClash.plan([x], into: folder)
            _ = FinderFiles.move(plan.items, into: folder, names: plan.names)
        }
        let readX = { (try? String(contentsOf: thereX, encoding: .utf8)) ?? "" }
        check("files: replace", readX() == "new" && !exists(x), readX())
        undo.undo()
        check("files: undo replace (both back)", readX() == "old" && exists(x))
        FileClash.ask = { _, _, _ in (.keepBoth, false) }
        undo.grouped(String(localized: "Move")) {
            plan = FileClash.plan([y], into: folder)
            _ = FinderFiles.move(plan.items, into: folder, names: plan.names)
        }
        check("files: kept both", exists(folder.appendingPathComponent("y 2.txt")) && exists(thereY))
        check("files: free name", FileClash.freeName("a.txt", taken: ["a.txt", "a 2.txt"]) == "a 3.txt" && FileClash.freeName("f", taken: []) == "f 2")

        // A checked copy into a folder: one undo once it's done.
        let big = dir.appendingPathComponent("big.bin")
        try? Data(repeating: 7, count: 2_000_000).write(to: big)
        let target = dir.appendingPathComponent("copies", isDirectory: true)
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        _ = await OffloadCenter.shared.copy([big], into: target)
        for _ in 0..<300 where OffloadCenter.shared.jobs.first(where: { $0.roots == [target.path] })?.finished == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let copied = target.appendingPathComponent("big.bin")
        check("files: checked copy done", exists(copied))
        check("files: checked copy is an undo", undo.undoName == String(localized: "Copy"), undo.undoName ?? "-")
        undo.undo()
        if let place = lastRedoPlace() { inTrash.append(place) }
        check("files: undo copy (to the Trash)", !exists(copied) && exists(big))
        for job in OffloadCenter.shared.jobs where job.roots == [target.path] { OffloadCenter.shared.remove(job.id) }

        // A move to another drive, as its end sees it: the Library follows, undo brings the original back.
        let original = write("clip.mov", "film"), moved = target.appendingPathComponent("clip.mov")
        try? fm.copyItem(at: original, to: moved)
        add(original)
        var place: NSURL?
        try? fm.trashItem(at: original, resultingItemURL: &place)
        var job = OffloadJob(name: "", source: dir.path, sourceVolume: "", roots: [target.path], rootVolumes: [""],
                             files: [OffloadFile(path: "clip.mov", size: 4, modified: .now, done: [true])])
        job.quick = true
        undo.copyFinished(job, trashed: [original.path: place! as URL])
        check("files: Library follows a move to another drive", entry(moved) && !entry(original))
        undo.undo()
        if let place = lastRedoPlace() { inTrash.append(place) }
        check("files: undo a move to another drive", exists(original) && !exists(moved) && entry(original), "\(library.entries.filter { $0.path.hasPrefix(dir.path) }.map(\.path))")

        // A real move to another drive (a small disk image, kept out of Finder): checked, the
        // originals to the Trash, the Library following (a whole folder too); undo brings it back.
        await movedAcrossDrives(dir, into: target, add: add)

        // A copy cancelled: no part file left, the job gone.
        let huge = dir.appendingPathComponent("huge.bin")
        fm.createFile(atPath: huge.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: huge) {
            for _ in 0..<64 { handle.write(Data(repeating: 1, count: 8_000_000)) }
            try? handle.close()
        }
        let into2 = dir.appendingPathComponent("cancelled", isDirectory: true)
        try? fm.createDirectory(at: into2, withIntermediateDirectories: true)
        _ = await OffloadCenter.shared.copy([huge], into: into2)
        try? await Task.sleep(for: .milliseconds(30))
        if let running = OffloadCenter.shared.jobs.first(where: { $0.roots == [into2.path] }) { OffloadCenter.shared.cancel(running.id) }
        for _ in 0..<300 where OffloadCenter.shared.jobs.contains(where: { $0.roots == [into2.path] }) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let left = (try? fm.contentsOfDirectory(atPath: into2.path)) ?? []
        check("files: cancelled copy leaves no part file", !left.contains { $0.hasSuffix(".pluckpart") } && !OffloadCenter.shared.jobs.contains { $0.roots == [into2.path] }, "\(left)")
        check("files: cancelled copy leaves the original", exists(huge))

        await dataLossGuards(dir, inTrash: &inTrash)

        // (Whatever undo put in the Trash during the test.)
        for action in undo.redoStack + undo.undoStack {
            for step in action.steps { if case .move(let from, _) = step, FileUndo.inTrash(from.path) { inTrash.append(from) } }
        }
        FileClash.ask = realAsk
    }

    /// What must never lose a file: a Replace whose copy never started keeps its undo, the inbox
    /// never deletes a folder or adds to a part of another version, a colour tag leaves the
    /// user's own tags, and an entry moved onto another one is one entry.
    private static func dataLossGuards(_ dir: URL, inTrash: inout [URL]) async {
        let fm = FileManager.default, undo = FileUndo.shared, library = LibraryStore.shared
        let realAsk = FileClash.ask
        defer { FileClash.ask = realAsk }

        // Replace, then the copy never starts: the one replaced can still come back.
        let into = dir.appendingPathComponent("replace-into", isDirectory: true)
        try? fm.createDirectory(at: into, withIntermediateDirectories: true)
        let there = into.appendingPathComponent("r.txt"), new = dir.appendingPathComponent("r.txt")
        try? Data("old".utf8).write(to: there)
        try? Data("new".utf8).write(to: new)
        FileClash.ask = { _, _, _ in (.replace, false) }
        let plan = FileClash.plan([new], into: into, deferred: true)
        check("guards: replace sent the old one to the Trash", plan.items == [new] && !fm.fileExists(atPath: there.path))
        undo.copyStarted([there.standardizedFileURL.path])
        check("guards: a copy that never started keeps Replace's undo", undo.undoName == String(localized: "Replace"), undo.undoName ?? "-")
        undo.undo()
        check("guards: undo brings the replaced one back", (try? String(contentsOf: there, encoding: .utf8)) == "old")
        if let place = undo.redoStack.last?.steps.compactMap({ step -> URL? in if case .move(let from, _) = step { return from }; return nil }).first { inTrash.append(place) }

        // The inbox: a folder of that name is never replaced; a part of an earlier version isn't added to.
        let inbox = OfficeInbox.shared
        let box = dir.appendingPathComponent("inbox", isDirectory: true)
        try? inbox.choose(box)
        defer { try? inbox.choose(nil) }
        let mac = OfficeInbox.folderName("Mac", id: UUID())
        let kept = (try? inbox.target("Footage/a.mov", from: mac))
        if let kept {
            try? fm.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("clip".utf8).write(to: kept)
        }
        let refused = (try? inbox.receive("Footage", size: 1, modified: 0, offset: 0, data: Data("x".utf8), from: mac)) == nil
        check("guards: inbox never replaces a folder", refused && kept.map { fm.fileExists(atPath: $0.path) } == true)
        _ = try? inbox.receive("b.txt", size: 4, modified: 100, offset: 0, data: Data("ab".utf8), from: mac)
        check("guards: inbox resumes only the same version", (try? inbox.have("b.txt", size: 4, modified: 100, from: mac)) == 2
              && (try? inbox.have("b.txt", size: 4, modified: 200, from: mac)) == 0)
        _ = try? inbox.receive("b.txt", size: 4, modified: 100, offset: 2, data: Data("cd".utf8), from: mac)
        _ = try? inbox.receive("b.txt", size: 2, modified: 300, offset: 0, data: Data("ef".utf8), from: mac)
        let b = try? inbox.target("b.txt", from: mac)
        check("guards: inbox replaces a file with its new version", b.flatMap { try? String(contentsOf: $0, encoding: .utf8) } == "ef")
        check("guards: two Macs of one name get their own folders", OfficeInbox.folderName("Mac", id: UUID()) != OfficeInbox.folderName("Mac", id: UUID()))

        // A colour tag off and on: the user's own tag of that colour stays.
        let tagged = dir.appendingPathComponent("tagged.txt")
        try? Data("t".utf8).write(to: tagged)
        try? FinderTags.write([FinderTagMark(name: "Client", color: 6), FinderTagMark(name: FinderTags.name(6), color: 6)], to: tagged)
        try? FinderTags.set(6, on: false, for: [tagged])
        let afterOff = FinderTags.read(tagged).map(\.name)
        try? FinderTags.set(6, on: true, for: [tagged])
        let afterOn = FinderTags.read(tagged).map(\.name)
        check("guards: colour tag off keeps the user's tag", afterOff == ["Client"], "\(afterOff)")
        check("guards: colour tag on adds it once", afterOn.sorted() == ["Client", FinderTags.name(6)].sorted(), "\(afterOn)")

        // An entry moved onto a path that has one already: one entry, and the Library still reads.
        func entry(_ path: String) -> LibraryStore.Entry {
            LibraryStore.Entry(path: path, title: "e", uploader: nil, source: nil, duration: nil, size: nil, thumbnail: nil, added: .now, transcriptID: nil)
        }
        let one = dir.appendingPathComponent("one.mov").path, two = dir.appendingPathComponent("two.mov").path
        library.insert(entry(one))
        library.insert(entry(two))
        library.relocate(from: one, to: two)
        library.record([])
        check("guards: relocate onto an entry leaves one", library.entries.filter { $0.path == two }.count == 1 && !library.entries.contains { $0.path == one })
    }

    private static func movedAcrossDrives(_ dir: URL, into target: URL, add: (URL) -> Void) async {
        let fm = FileManager.default, undo = FileUndo.shared, library = LibraryStore.shared
        func hdiutil(_ arguments: [String]) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
        let image = dir.appendingPathComponent("Other.dmg"), mount = dir.appendingPathComponent("Other Drive", isDirectory: true)
        guard hdiutil(["create", "-size", "8m", "-fs", "APFS", "-volname", "Pluck Undo Test", image.path]),
              hdiutil(["attach", image.path, "-mountpoint", mount.path, "-nobrowse"]) else {
            return check("files: move to another drive", false, "couldn't make a disk image")
        }
        defer { _ = hdiutil(["detach", mount.path, "-force"]) }
        func entry(_ url: URL) -> Bool { library.entries.contains { $0.path == url.path } }
        /// Moved with the Library's checked copy; once its originals have gone to the Trash.
        func move(_ item: URL) async {
            let before = Set(OffloadCenter.shared.jobs.map(\.id))
            _ = await OffloadCenter.shared.copy([item], into: target, move: true)
            let ids = Set(OffloadCenter.shared.jobs.map(\.id)).subtracting(before)
            for _ in 0..<400 where !ids.allSatisfy({ OffloadCenter.shared.trashed[$0] != nil }) { try? await Task.sleep(for: .milliseconds(25)) }
            // (Its undo is recorded on the main actor right after.)
            try? await Task.sleep(for: .milliseconds(100))
        }
        let take = mount.appendingPathComponent("take.mov")
        try? Data("film".utf8).write(to: take)
        add(take)
        await move(take)
        let arrived = target.appendingPathComponent("take.mov")
        check("files: moved to another drive, the Library follows", fm.fileExists(atPath: arrived.path) && !fm.fileExists(atPath: take.path) && entry(arrived) && !entry(take),
              "arrived \(fm.fileExists(atPath: arrived.path)), original gone \(!fm.fileExists(atPath: take.path)), entry \(entry(arrived))")
        check("files: a move to another drive is an undo", undo.undoName == String(localized: "Move"), undo.undoName ?? "-")
        undo.undo()
        check("files: undo a move to another drive", fm.fileExists(atPath: take.path) && !fm.fileExists(atPath: arrived.path) && entry(take))

        let card = mount.appendingPathComponent("Card", isDirectory: true)
        try? fm.createDirectory(at: card, withIntermediateDirectories: true)
        let inner = card.appendingPathComponent("A001.mov")
        try? Data("clip".utf8).write(to: inner)
        add(inner)
        await move(card)
        let innerThere = target.appendingPathComponent("Card/A001.mov")
        check("files: a folder moved to another drive keeps its entries", fm.fileExists(atPath: innerThere.path) && entry(innerThere) && !entry(inner))
        undo.undo()
        check("files: undo a folder's move to another drive", fm.fileExists(atPath: inner.path) && entry(inner))
    }
}
