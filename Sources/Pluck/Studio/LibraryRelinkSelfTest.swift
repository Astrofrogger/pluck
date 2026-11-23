import Foundation

/// Missing Library files found again (-PluckScreenshotOnly libraryrelink): the name-and-size
/// matching (never a guess between two), and the entry, its tags and its transcript following the
/// file, and the one undo.
extension PhotoSelfTest {
    static func libraryRelinkTest() async {
        typealias R = LibraryRelink
        let found: [(path: String, size: Int64)] = [("/new/a/A.MOV", 10), ("/new/b/b.mov", 20), ("/new/c/b.mov", 20), ("/new/d/c.mov", 30), ("/new/e/d.mov", 41)]
        let plan = R.plan(missing: [("/old/a.mov", 10), ("/old/b.mov", 20), ("/old/c.mov", nil), ("/old/c2.mov", 30), ("/old/d.mov", 40), ("/old/zz.mov", 1)],
                          found: found, taken: [])
        check("relink: same name (any case) and size matches", plan.matches.contains { $0.from == "/old/a.mov" && $0.to == "/new/a/A.MOV" }, "\(plan.matches)")
        check("relink: two files fit is asked, not guessed", plan.ambiguous.contains { $0.from == "/old/b.mov" && $0.options.count == 2 }, "\(plan.ambiguous)")
        check("relink: unknown size, one name fits", plan.matches.contains { $0.from == "/old/c.mov" && $0.to == "/new/d/c.mov" })
        check("relink: a different size or name isn't a match", plan.notFound == 3 && !plan.matches.contains { $0.from == "/old/d.mov" }, "\(plan.notFound)")
        let twice = R.plan(missing: [("/x/c.mov", nil), ("/y/c.mov", nil)], found: [("/new/c.mov", 5)], taken: [])
        check("relink: one file for two entries is asked", twice.matches.isEmpty && twice.ambiguous.count == 2)
        let taken = R.plan(missing: [("/old/c.mov", nil)], found: [("/new/c.mov", 5)], taken: ["/new/c.mov"])
        check("relink: a file another entry has isn't offered", taken.matches.isEmpty && taken.notFound == 1)

        // The folder search finds by name and size, hidden files left out.
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("PluckRelink-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        let sub = dir.appendingPathComponent("sub/deeper", isDirectory: true)
        try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
        let library = LibraryStore.shared, undo = FileUndo.shared
        let old = dir.appendingPathComponent("gone/clip.mov").path
        let now = sub.appendingPathComponent("clip.mov")
        try? Data(count: 1234).write(to: now)
        defer {
            try? fm.removeItem(at: dir)
            AppDelegate.shared?.manager.items.removeAll { $0.title == "clip" && $0.isLocalFile }
            library.remove(library.entries.filter { $0.path == old || $0.path == now.path })
            if let t = TranscriptStore.find(forFile: now.path) ?? TranscriptStore.find(forFile: old) { try? fm.removeItem(at: TranscriptStore.url(for: t.id)) }
        }
        let scanned = R.scan(dir, names: ["clip.mov"])
        check("relink: folder search goes all the way down", scanned.count == 1 && URL(fileURLWithPath: scanned[0].path).resolvingSymlinksInPath().path == now.path && scanned[0].size == 1234, "\(scanned)")

        // The entry, its tags and its transcript follow; one undo turns it back.
        library.insert(LibraryStore.Entry(path: old, title: "Clip", uploader: nil, source: nil, duration: nil, size: 1234, thumbnail: nil,
                                          added: .now, tags: ["keep"], transcriptID: nil))
        let transcript = Transcript(id: UUID().uuidString, title: "Clip", filePath: old, sourceURL: nil, language: "en-US", duration: 1,
                                    created: .now, words: [])
        TranscriptStore.save(transcript)
        let row = AppDelegate.shared?.manager.addLocalFiles([now])  // a Downloads row for the file's old place
        row?.first?.fileURL = URL(fileURLWithPath: old)
        let before = undo.undoStack.count
        R.apply([(old, now.path)])
        let moved = library.entries.first { $0.path == now.path }
        check("relink: entry and tags follow the file", moved?.tags == ["keep"] && !library.entries.contains { $0.path == old })
        check("relink: transcript follows the file", TranscriptStore.find(forFile: now.path)?.id == transcript.id && TranscriptStore.find(forFile: old) == nil)
        check("relink: one undo", undo.undoStack.count == before + 1 && undo.undoName == String(localized: "Locate Files"))
        check("relink: Downloads row follows the file", row?.first?.fileURL?.path == now.path, row?.first?.fileURL?.path ?? "nil")
        _ = undo.undo()
        check("relink: undo puts the Downloads row back", row?.first?.fileURL?.path == old)
        check("relink: undo puts entry and transcript back", library.entries.contains { $0.path == old && $0.tags == ["keep"] }
              && TranscriptStore.find(forFile: old)?.id == transcript.id && TranscriptStore.find(forFile: now.path) == nil)
    }
}
