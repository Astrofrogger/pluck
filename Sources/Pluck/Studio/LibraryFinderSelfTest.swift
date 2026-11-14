import AppKit
import SwiftUI

/// The Library's Finder ways (-PluckScreenshotOnly finder): folder order and sorting, the list's
/// columns, type-to-jump, and renaming, duplicating, moving and trashing files in a folder of the
/// test's own (never a protected one), the Library's entries following.
extension PhotoSelfTest {
    static func finderTest() async {
        // The Markdown preview: blocks and marks become HTML; HTML in the file and pictures from the internet don't.
        do {
            let md = "# Title\n\nSome **bold** and *italic* with `code` and [a link](https://example.com).\n\n- one\n- two\n\n```\nlet x = 1 < 2\n```\n\n<script>x</script> ![p](https://example.com/p.png) ![q](q.png)\n\n| a | b |\n|---|---|\n| 1 | 2 |"
            let html = Markdown.html(md)
            check("finder: markdown blocks", html.contains("<h1>Title</h1>") && html.contains("<ul><li>one</li><li>two</li></ul>")
                  && html.contains("<pre><code>let x = 1 &lt; 2</code></pre>") && html.contains("<td>1</td>"), html)
            check("finder: markdown marks", html.contains("<strong>bold</strong>") && html.contains("<em>italic</em>")
                  && html.contains("<code>code</code>") && html.contains("<a href=\"https://example.com\">a link</a>"), html)
            check("finder: markdown keeps out HTML and web pictures", !html.contains("<script>") && !html.contains("src=\"https") && html.contains("src=\"q.png\""), html)
            let evil = Markdown.html("![a\"onerror=\"x](q.png \"b\") ![u](HTTPS://e.com/p.png) ![v](//e.com/p.png) [l](x\" style=\"background:url(http://e.com/a))")
            check("finder: markdown can't inject attributes or load remote pictures", !evil.contains("\" onerror") && !evil.contains("\"onerror=\"")
                  && !evil.contains("<img alt=\"u") && !evil.contains("<img alt=\"v") && !evil.contains("\" style=\"") && !evil.contains("src=\"//"), evil)
            check("finder: markdown page blocks remote loads", Markdown.page("").contains("Content-Security-Policy") && Markdown.page("").contains("img-src data: file:"))
            check("finder: contents shown for documents, not films", FilePreview.showsContents(URL(fileURLWithPath: "/a/b.pdf"))
                  && FilePreview.showsContents(URL(fileURLWithPath: "/a/b.md")) && !FilePreview.showsContents(URL(fileURLWithPath: "/a/b.mov")))
        }

        check("offload: AppleDouble files are copied, not skipped", !OffloadCenter.isSystemFile("._C0001.MP4") && OffloadCenter.isSystemFile(".DS_Store"))
        check("offload: AppleDouble files are copied, not skipped", !OffloadCenter.isSystemFile("._C0001.MP4") && OffloadCenter.isSystemFile(".DS_Store"))
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("PluckFinderTest-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: dir) }
        try? fm.createDirectory(at: dir.appendingPathComponent("b folder"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: dir.appendingPathComponent("A folder"), withIntermediateDirectories: true)
        func write(_ name: String, bytes: Int, daysAgo: Double) {
            let url = dir.appendingPathComponent(name)
            try? Data(repeating: 65, count: bytes).write(to: url)
            try? fm.setAttributes([.modificationDate: Date.now.addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: url.path)
        }
        write("beta.txt", bytes: 300, daysAgo: 3)
        write("Alpha.json", bytes: 10, daysAgo: 1)
        write("zeta.html", bytes: 100, daysAgo: 2)

        // Folder listing: folders first, then by name; every column sorts.
        let pane = FinderPane(url: dir)
        await settle(pane)
        let names = { pane.shown.map(\.name) }
        check("finder: folders first, then names", names() == ["A folder", "b folder", "Alpha.json", "beta.txt", "zeta.html"], "\(names())")
        pane.sort = .size
        check("finder: by size", names().suffix(3) == ["Alpha.json", "zeta.html", "beta.txt"], "\(names())")
        pane.sort = .modified
        check("finder: by date modified", names().suffix(3) == ["beta.txt", "zeta.html", "Alpha.json"], "\(names())")
        pane.ascending = false
        check("finder: descending, folders still first", Array(names().prefix(2)).sorted() == ["A folder", "b folder"] && names().suffix(3) == ["Alpha.json", "zeta.html", "beta.txt"], "\(names())")
        pane.ascending = true
        pane.sort = .kind
        let kinds = pane.shown.filter { !$0.isFolder }.map(\.kind)
        check("finder: by kind", kinds == kinds.sorted { $0.localizedStandardCompare($1) == .orderedAscending } && Set(kinds).count == 3, "\(kinds)")
        pane.sort = .name

        // Type-to-jump.
        check("finder: jump matches a start", TypeSelect.match("BE", in: ["Alpha", "beta", "Bèta"]) == 1)
        check("finder: jump ignores accents", TypeSelect.match("bet", in: ["Bèta", "beta"]) == 0)
        check("finder: jump finds nothing", TypeSelect.match("x", in: ["Alpha", "beta"]) == nil)
        var typing = TypeSelect()
        let start = Date.now
        _ = typing.add("b", now: start)
        check("finder: letters typed quickly add up", typing.add("e", now: start.addingTimeInterval(0.4)) == "be")
        check("finder: a pause starts again", typing.add("z", now: start.addingTimeInterval(2)) == "z")
        pane.jump("Z")
        check("finder: typing selects in the folder", pane.selection.map(\.lastPathComponent) == ["zeta.html"], "\(pane.selection)")

        // The list's columns (the collections).
        func entry(_ title: String, size: Int64?, days: Double, length: Double?, ext: String) -> LibraryStore.Entry {
            LibraryStore.Entry(path: "/test/\(title).\(ext)", title: title, uploader: nil, source: nil, duration: length, size: size,
                               thumbnail: nil, added: Date.now.addingTimeInterval(-days * 86_400), transcriptID: nil)
        }
        let rows = [entry("Bravo", size: 50, days: 2, length: 30, ext: "mp4"), entry("alpha", size: nil, days: 1, length: nil, ext: "jpg"),
                    entry("Charlie", size: 900, days: 3, length: 5, ext: "mp3")].map(LibraryRow.init)
        func order(_ comparator: KeyPathComparator<LibraryRow>) -> [String] { rows.sorted(using: [comparator]).map(\.name) }
        check("finder: list by name", order(KeyPathComparator(\.name)) == ["alpha", "Bravo", "Charlie"], "\(order(KeyPathComparator(\.name)))")
        check("finder: list by date added", order(KeyPathComparator(\.added, order: .reverse)) == ["alpha", "Bravo", "Charlie"])
        check("finder: list by size (unknown first)", order(KeyPathComparator(\.size)) == ["alpha", "Bravo", "Charlie"])
        check("finder: list by kind", order(KeyPathComparator(\.kind)) == ["Charlie", "alpha", "Bravo"], "\(order(KeyPathComparator(\.kind)))")
        check("finder: list by duration", order(KeyPathComparator(\.duration, order: .reverse)) == ["Bravo", "Charlie", "alpha"])

        // Files: renamed, duplicated, moved, trashed; the Library follows.
        let library = LibraryStore.shared
        let beta = dir.appendingPathComponent("beta.txt")
        library.insert(LibraryStore.Entry(path: beta.path, title: "beta", uploader: nil, source: nil, duration: nil, size: 300,
                                          thumbnail: nil, added: .now, transcriptID: nil))
        let renamed = try? FinderFiles.rename(beta, to: "gamma.txt")
        check("finder: renamed on disk", renamed.map { fm.fileExists(atPath: $0.path) } == true && !fm.fileExists(atPath: beta.path))
        check("finder: Library follows a rename", library.entries.contains { $0.path == dir.appendingPathComponent("gamma.txt").path }
              && !library.entries.contains { $0.path == beta.path })
        check("finder: a taken name is refused", (try? FinderFiles.rename(dir.appendingPathComponent("gamma.txt"), to: "zeta.html")) == nil)
        check("finder: a slash is refused", (try? FinderFiles.rename(dir.appendingPathComponent("gamma.txt"), to: "a/b")) == nil)

        let gamma = dir.appendingPathComponent("gamma.txt")
        let copy = try? await FinderFiles.duplicate(gamma)
        let copy2 = try? await FinderFiles.duplicate(gamma)
        check("finder: duplicate named as Finder does", copy?.lastPathComponent == "gamma copy.txt" && copy2?.lastPathComponent == "gamma copy 2.txt",
              "\(copy?.lastPathComponent ?? "-") \(copy2?.lastPathComponent ?? "-")")
        check("finder: duplicate's content", copy.flatMap { try? Data(contentsOf: $0) }?.count == 300)
        check("finder: a Library item's copy is in the Library", library.entries.contains { $0.path == copy?.path })
        var folderErr = ""
        let folderCopy: URL? = await { do { return try await FinderFiles.duplicate(dir.appendingPathComponent("A folder", isDirectory: true)) } catch { folderErr = "\(error)"; return nil } }()
        check("finder: a folder's copy", folderCopy?.lastPathComponent == "A folder copy", (folderCopy?.lastPathComponent ?? "-") + folderErr)

        let folderB = dir.appendingPathComponent("b folder", isDirectory: true)
        check("finder: same drive", FinderFiles.sameVolume(gamma, folderB))
        let moveProblem = FinderFiles.move([gamma], into: folderB)
        let moved = folderB.appendingPathComponent("gamma.txt")
        check("finder: moved into a folder", moveProblem == nil && fm.fileExists(atPath: moved.path) && !fm.fileExists(atPath: gamma.path), moveProblem ?? "")
        check("finder: Library follows a move", library.entries.contains { $0.path == moved.path })
        check("finder: a folder can't go into itself", FinderFiles.move([folderB], into: folderB.appendingPathComponent("x")) != nil)
        let folderC = dir.appendingPathComponent("c folder", isDirectory: true)
        _ = try? FinderFiles.rename(folderB, to: "c folder")
        check("finder: Library follows a folder renamed", library.entries.contains { $0.path == folderC.appendingPathComponent("gamma.txt").path })

        // New folder in place, then the trash (the Library forgets what went; nothing is deleted for good).
        pane.reload()
        await settle(pane)
        pane.newFolderInPlace()
        check("finder: new folder named in place", pane.naming == .rename(dir.appendingPathComponent("untitled folder", isDirectory: true))
              && fm.fileExists(atPath: dir.appendingPathComponent("untitled folder").path), "\(String(describing: pane.naming))")
        pane.naming = nil

        let doomed = folderC.appendingPathComponent("gamma.txt")
        let went: [URL: URL] = await withCheckedContinuation { done in
            FinderFiles.trash([doomed]) { done.resume(returning: $0) }
        }
        check("finder: trashed, not deleted", !fm.fileExists(atPath: doomed.path) && went.values.contains { fm.fileExists(atPath: $0.path) }, "\(went)")
        check("finder: Library forgets what was trashed", !library.entries.contains { $0.path == doomed.path })
        // (The test's own file, out of the Trash again.)
        for trashed in went.values { try? fm.removeItem(at: trashed) }

        library.remove(library.entries.filter { $0.path.hasPrefix(dir.path) })
    }

    /// Until the pane has read its folder.
    static func settle(_ pane: FinderPane) async {
        for _ in 0..<200 where pane.loading { try? await Task.sleep(for: .milliseconds(20)) }
    }
}
