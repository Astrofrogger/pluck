import AppKit
import SwiftUI

extension PhotoSelfTest {
    /// A folder of 10,000 files (-PluckScreenshotOnly finderbig): listed, sorted and filtered
    /// quickly enough, selection and type-to-jump right. In a folder of the test's own.
    static func finderBigTest() async {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("PluckBigFolder-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let count = 10_000
        for n in 0..<count { fm.createFile(atPath: dir.appendingPathComponent(String(format: "file %05d.txt", n)).path, contents: nil) }
        func seconds(_ since: Date) -> Double { Date.now.timeIntervalSince(since) }

        var start = Date.now
        let listed = await Task.detached { FinderItem.list(dir, hidden: false, sort: .name, ascending: true) }.value
        let listing = seconds(start)
        check("big: listed and sorted off the main thread in under 5 s", listed.count == count && listing < 5, "\(listed.count) in \(listing) s")

        let pane = FinderPane(url: dir)
        start = .now
        for _ in 0..<1000 where pane.loading { try? await Task.sleep(for: .milliseconds(20)) }
        let loaded = seconds(start)
        check("big: the pane shows them all", pane.shown.count == count && pane.shown.first?.name == "file 00000.txt", "\(pane.shown.count) in \(loaded) s")
        start = .now
        pane.sort = .size
        pane.sort = .kind
        pane.sort = .name
        let sorting = seconds(start)
        check("big: three sorts in under 1.5 s", sorting < 1.5, "\(sorting) s")
        start = .now
        for _ in 0..<1000 { _ = pane.shown.count }
        check("big: what's shown isn't worked out per look", seconds(start) < 0.05, "\(seconds(start)) s")
        start = .now
        pane.filter = "0999"
        let filtering = seconds(start)
        check("big: filtering by name in under 0.3 s", pane.shown.map(\.name) == ["file 00999.txt", "file 09990.txt", "file 09991.txt", "file 09992.txt", "file 09993.txt",
                                                                                  "file 09994.txt", "file 09995.txt", "file 09996.txt", "file 09997.txt", "file 09998.txt", "file 09999.txt"]
              && filtering < 0.3, "\(pane.shown.count) in \(filtering) s")
        note("big: listing \(listing) s, pane \(loaded) s, three sorts \(sorting) s, filter \(filtering) s")
        pane.filter = ""
        for _ in 0..<100 where pane.searching { try? await Task.sleep(for: .milliseconds(20)) }
        let names = { pane.selection.map(\.lastPathComponent) }
        check("big: where an item is, at once", pane.shown.last.flatMap { pane.position(of: $0.url) } == count - 1)
        start = .now
        pane.selection = [pane.shown[5000].url]
        pane.anchor = pane.selection.first
        for _ in 0..<200 { pane.move(by: 1) }
        check("big: 200 arrow presses in under 0.2 s", names() == ["file 05200.txt"] && seconds(start) < 0.2, "\(names()) \(seconds(start)) s")
        start = .now
        pane.jump("file 09")
        check("big: type-to-jump", names() == ["file 09000.txt"] && seconds(start) < 0.2, "\(names()) \(seconds(start)) s")
    }

    /// The Library's Finder extras (-PluckScreenshotOnly finderextras): live refresh, entries
    /// following files moved outside Pluck, search below a folder, colour tags, renaming several,
    /// zips, hidden files, each folder's own view, Markdown read large.
    static func finderExtrasTest() async {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("PluckExtrasTest-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try? fm.createDirectory(at: dir.appendingPathComponent("sub/deep", isDirectory: true), withIntermediateDirectories: true)
        let library = LibraryStore.shared, undo = FileUndo.shared
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
        /// A change made by another program (Pluck's own don't wake the watchers).
        func shell(_ command: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            try? process.run()
            process.waitUntilExit()
        }
        func wait(_ seconds: Double = 8, until done: () -> Bool) async {
            for _ in 0..<Int(seconds * 50) where !done() { try? await Task.sleep(for: .milliseconds(20)) }
        }
        func trashedLast() {
            if case .move(let place, _)? = undo.redoStack.last?.steps.first, FileUndo.inTrash(place.path) { inTrash.append(place) }
        }
        let a = write("a.txt"), b = write("b.txt")
        _ = write("sub/deep/needle notes.txt", "zebracorn")
        let pane = FinderPane(url: dir)
        await wait { !pane.loading }

        // Live: a file made elsewhere shows by itself; one changed is read again.
        shell("echo hi > '\(dir.path)/arrived.txt'")
        await wait { pane.items.contains { $0.name == "arrived.txt" } }
        check("extras: a file made elsewhere shows by itself", pane.items.contains { $0.name == "arrived.txt" })
        shell("echo more >> '\(dir.path)/arrived.txt'")
        await wait { pane.items.first { $0.name == "arrived.txt" }?.size == 8 }
        check("extras: a file changed elsewhere is read again", pane.items.first { $0.name == "arrived.txt" }?.size == 8,
              "\(pane.items.first { $0.name == "arrived.txt" }?.size ?? -1)")
        let shownBefore = pane.version
        shell("echo x > '\(dir.path)/sub/deep/below.txt'")
        try? await Task.sleep(for: .seconds(3.5))
        check("extras: changes below the folder don't reload it", pane.version == shownBefore, "\(shownBefore) → \(pane.version)")

        // A Library file renamed outside Pluck: its entry follows.
        library.insert(LibraryStore.Entry(path: a.path, title: "a", uploader: nil, source: nil, duration: nil, size: nil, thumbnail: nil, added: .now, transcriptID: nil))
        _ = await LibraryIdentity.check(library.entries)
        shell("mv '\(a.path)' '\(dir.path)/sub/a moved.txt'")
        let missing = await LibraryIdentity.check(library.entries)
        let movedA = dir.appendingPathComponent("sub/a moved.txt")
        // (By the real path: the temporary folder is reached through a link.)
        func real(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        let paths = Set(library.entries.map { real($0.path) })
        check("extras: an entry follows its file moved outside Pluck", paths.contains(real(movedA.path)) && !paths.contains(real(a.path)) && !missing.contains { $0.contains("PluckExtras") },
              "\(paths.filter { $0.contains("PluckExtras") }) missing \(missing)")
        shell("mv '\(movedA.path)' '\(a.path)'")
        _ = await LibraryIdentity.check(library.entries)

        // Search: names here and below at once (Spotlight, where it knows the folder, adds text inside).
        pane.filter = "needle"
        await wait { pane.results != nil && !pane.searching }
        check("extras: search finds names below the folder", pane.shown.map(\.name) == ["needle notes.txt"], "\(pane.shown.map(\.name))")
        pane.filter = ""
        check("extras: a cleared search shows the folder again", pane.results == nil && pane.shown.contains { $0.name == "b.txt" })
        let inside = await FinderPane.spotlight("zebracorn", in: dir, hidden: false)
        note("extras: Spotlight found \(inside.count) by text (temporary folders often aren't indexed)")

        // Colour tags: read back as Finder keeps them; the filter.
        try? FinderTags.set(6, on: true, for: [b])
        try? FinderTags.set(4, on: true, for: [b])
        let tags = FinderTags.read(b)
        let names = (try? b.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
        check("extras: tags written with their colours", tags.map(\.color) == [6, 4] && names == [FinderTags.name(6), FinderTags.name(4)], "\(tags) \(names)")
        try? FinderTags.set(6, on: false, for: [b])
        check("extras: a tag taken off", FinderTags.read(b).map(\.color) == [4])
        pane.reload()
        await wait { !pane.loading }
        pane.tagFilter = 4
        check("extras: only the tagged shown", pane.shown.map(\.name) == ["b.txt"], "\(pane.shown.map(\.name))")
        pane.tagFilter = nil
        try? FinderTags.clear([b])
        check("extras: tags cleared", FinderTags.read(b).isEmpty)

        // Renaming several.
        let shots = (1...3).map { write("IMG_\($0).jpg") }
        var rule = BatchRename()
        rule.mode = .format
        rule.base = "Shoot-"
        rule.start = 1
        rule.digits = 3
        check("extras: format names", BatchRename.plan(shots, rule: rule).names == ["Shoot-001.jpg", "Shoot-002.jpg", "Shoot-003.jpg"])
        rule = BatchRename(mode: .replace, find: "IMG", replacement: "Day")
        check("extras: replace text", BatchRename.plan(shots, rule: rule).names == ["Day_1.jpg", "Day_2.jpg", "Day_3.jpg"])
        rule = BatchRename(mode: .add, added: "Trip ", addAfter: false)
        check("extras: add text", BatchRename.plan(shots, rule: rule).names.first == "Trip IMG_1.jpg")
        _ = write("Day_2.jpg")
        rule = BatchRename(mode: .replace, find: "IMG", replacement: "Day")
        check("extras: a name already there is flagged", BatchRename.plan(shots, rule: rule).clashes == [1])
        check("extras: two the same are flagged", BatchRename(mode: .replace, find: "_1", replacement: "_2").name(for: "IMG_1.jpg", index: 0) == "IMG_2.jpg"
              && BatchRename.plan(Array(shots.prefix(2)), rule: BatchRename(mode: .replace, find: "_1", replacement: "_2")).clashes == [0, 1])
        rule = BatchRename(mode: .format, base: "Shoot-", start: 7, digits: 3)
        let failed = BatchRename.apply(shots, rule: rule)
        let renamed = ["Shoot-007.jpg", "Shoot-008.jpg", "Shoot-009.jpg"].map { dir.appendingPathComponent($0) }
        check("extras: renamed several, one undo", failed == nil && renamed.allSatisfy { fm.fileExists(atPath: $0.path) } && undo.undoName == String(localized: "Rename"), failed ?? "")
        undo.undo()
        check("extras: undo renaming several", shots.allSatisfy { fm.fileExists(atPath: $0.path) } && !renamed.contains { fm.fileExists(atPath: $0.path) })

        // Zips: made and opened as Finder does, nothing written over.
        if case .success(let zip) = await FinderArchive.compress([b]) {
            check("extras: compress one", zip.lastPathComponent == "b.txt.zip" && fm.fileExists(atPath: zip.path))
            let opened = await FinderArchive.uncompress(zip)
            if case .success(let placed) = opened {
                check("extras: uncompress beside, not over", placed.map(\.lastPathComponent) == ["b 2.txt"] && (try? String(contentsOf: placed[0], encoding: .utf8)) == "x", "\(placed)")
            } else { check("extras: uncompress beside, not over", false, "\(opened)") }
            undo.undo()
            trashedLast()
            undo.undo()
            trashedLast()
            check("extras: undo uncompress and compress", !fm.fileExists(atPath: zip.path) && !fm.fileExists(atPath: dir.appendingPathComponent("b 2.txt").path))
        } else { check("extras: compress one", false) }
        if case .success(let archive) = await FinderArchive.compress(shots) {
            check("extras: compress several", archive.lastPathComponent == String(localized: "Archive") + ".zip")
            undo.undo()
            trashedLast()
        } else { check("extras: compress several", false) }

        // Hidden files (⇧⌘.).
        _ = write(".secret")
        let hiddenBefore = FinderPane.showsHidden
        if hiddenBefore { FinderPane.toggleHidden() }
        pane.reload()
        await wait { !pane.loading }
        let without = pane.items.contains { $0.name == ".secret" }
        FinderPane.toggleHidden()
        pane.reload()
        await wait { !pane.loading }
        try? await Task.sleep(for: .milliseconds(200))
        check("extras: hidden files shown when asked", !without && pane.items.contains { $0.name == ".secret" })
        FinderPane.toggleHidden()

        // Each folder keeps its own view.
        let sub = dir.appendingPathComponent("sub", isDirectory: true)
        pane.mode = .list
        pane.sort = .size
        pane.go(to: sub)
        pane.mode = .columns
        pane.sort = .name
        pane.go(to: dir)
        check("extras: a folder keeps its view and order", pane.mode == .list && pane.sort == .size, "\(pane.mode) \(pane.sort)")
        pane.go(to: sub)
        check("extras: another keeps its own", pane.mode == .columns && pane.sort == .name)
        pane.go(to: dir)
        await wait { !pane.loading }

        // Space on Markdown: read large (other files: Quick Look).
        let md = write("read me.md", "# Hello")
        pane.reload()
        await wait { !pane.loading }
        pane.selection = [md]
        pane.quickLook()
        check("extras: Space on Markdown reads it large", pane.reading == md)
        pane.reading = nil
        check("extras: Open With knows apps for text", !NSWorkspace.shared.urlsForApplications(toOpen: md).isEmpty)
    }
}
