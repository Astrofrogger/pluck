import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The Library with any file, not only clips: photos, documents and folders copied and checked;
/// a camera's photos a folder (not a clip); new folders and renaming; photos' pictures and the
/// viewer; moving (at once on one drive, checked first to another); splits turned.
extension EditSelfTest {
    static func libraryFiles() async {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-library-files-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let before = Set(OffloadCenter.shared.jobs.map(\.id))
        photoFoldersAreFolders(base)
        await everyFileCopiedAndChecked(base)
        await namingFolders(base)
        await photoPicturesAndViewer(base)
        await moving(base)
        splitsTurn()
        dragOut(base)
        for job in OffloadCenter.shared.jobs where !before.contains(job.id) { OffloadCenter.shared.remove(job.id) }
        try? FileManager.default.removeItem(at: base)
    }

    /// A small JPEG; `camera`: with the camera's name in it, as a camera writes.
    private static func writePhoto(_ url: URL, camera: Bool, width: Int = 64, height: Int = 48) {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        var properties: [CFString: Any] = [:]
        if camera {
            properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "Camera", kCGImagePropertyTIFFModel: "Model One"]
            properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: "2026:11:04 10:00:00"]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    private static func setWritten(_ url: URL, _ date: Date) {
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// A camera's numbered JPEGs, or DNGs taken seconds apart: a folder to go into. Numbered
    /// pictures written together (a render, CinemaDNG frames): still a clip.
    private static func photoFoldersAreFolders(_ base: URL) {
        let fm = FileManager.default
        let photos = base.appendingPathComponent("DCIM/100CANON", isDirectory: true)
        let render = base.appendingPathComponent("Render", isDirectory: true)
        let stills = base.appendingPathComponent("Phone DNG", isDirectory: true)
        let frames = base.appendingPathComponent("A001_C001", isDirectory: true)
        for folder in [photos, render, stills, frames] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        let now = Date()
        for n in 1...12 {
            writePhoto(photos.appendingPathComponent(String(format: "IMG_%04d.JPG", n)), camera: true)
            writePhoto(render.appendingPathComponent(String(format: "shot.%04d.jpg", n)), camera: false)
            setWritten(render.appendingPathComponent(String(format: "shot.%04d.jpg", n)), now)
            let still = stills.appendingPathComponent(String(format: "IMG_%04d.DNG", n)), frame = frames.appendingPathComponent(String(format: "A001_C001_%06d.dng", n))
            try? Data([1, 2, 3]).write(to: still)
            try? Data([1, 2, 3]).write(to: frame)
            setWritten(still, now.addingTimeInterval(Double(n) * 30))
            setWritten(frame, now.addingTimeInterval(Double(n) / 24))
        }
        let read = [photos, render, stills, frames].map { FinderItem.read($0) }
        check("camera photos are a folder, not a clip", read[0].isFolder && !read[0].isClip && read[2].isFolder && !read[2].isClip
              && read[1].isClip && read[3].isClip,
              "photos \(read[0].isClip), render \(read[1].isClip), phone DNG \(read[2].isClip), CinemaDNG \(read[3].isClip)")
    }

    /// Waits for the jobs the Library started; the finished ones.
    private static func finished(_ ids: Set<UUID>) async -> [OffloadJob] {
        for _ in 0..<600 {
            let jobs = OffloadCenter.shared.jobs.filter { ids.contains($0.id) }
            if !jobs.isEmpty, jobs.allSatisfy({ OffloadCenter.shared.state($0) == .done }) { return jobs }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return []
    }

    /// A photo, a document and a folder of photos dropped together: all of it copied, every file
    /// read back and checked (its checksum kept). Something already there: skipped, the rest copied.
    private static func everyFileCopiedAndChecked(_ base: URL) async {
        let fm = FileManager.default
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let into = base.appendingPathComponent("Into", isDirectory: true)
        let album = source.appendingPathComponent("Album", isDirectory: true)
        for folder in [source, into, album] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        writePhoto(source.appendingPathComponent("Photo.jpg"), camera: true)
        try? Data("notes".utf8).write(to: source.appendingPathComponent("Notes.txt"))
        try? Data(repeating: 7, count: 300_000).write(to: source.appendingPathComponent("Sound.wav"))
        for n in 1...3 { writePhoto(album.appendingPathComponent("IMG_000\(n).JPG"), camera: true) }
        let items = ["Photo.jpg", "Notes.txt", "Sound.wav", "Album"].map { source.appendingPathComponent($0) }
        let before = Set(OffloadCenter.shared.jobs.map(\.id))
        let problem = await OffloadCenter.shared.copy(items, into: into)
        let ids = Set(OffloadCenter.shared.jobs.map(\.id)).subtracting(before)
        let jobs = await finished(ids)
        let files = jobs.flatMap(\.files)
        let same = ["Photo.jpg", "Notes.txt", "Sound.wav", "Album/IMG_0001.JPG", "Album/IMG_0003.JPG"].allSatisfy {
            fm.contentsEqual(atPath: source.appendingPathComponent($0).path, andPath: into.appendingPathComponent($0).path)
        }
        check("library copies and checks every kind of file", problem == nil && files.count == 6 && same
              && files.allSatisfy { $0.hash != nil && !$0.done.contains(false) && $0.problem == nil },
              "problem \(problem ?? "none"), \(files.count) files, same \(same), checked \(files.filter { $0.hash != nil }.count)")

        // Again, with one more file: the rest is already there.
        try? Data("more".utf8).write(to: source.appendingPathComponent("More.txt"))
        let again = Set(OffloadCenter.shared.jobs.map(\.id))
        let skipped = await OffloadCenter.shared.copy(items + [source.appendingPathComponent("More.txt")], into: into)
        let more = await finished(Set(OffloadCenter.shared.jobs.map(\.id)).subtracting(again))
        check("library copy skips what's already there", skipped != nil && more.flatMap(\.files).map(\.path) == ["More.txt"]
              && fm.fileExists(atPath: into.appendingPathComponent("More.txt").path),
              "said \(skipped ?? "nothing"), copied \(more.flatMap(\.files).map(\.path))")
    }

    /// New folders (a free name each time, a clash or a bad name refused) and renaming.
    private static func namingFolders(_ base: URL) async {
        let fm = FileManager.default
        let place = base.appendingPathComponent("Naming", isDirectory: true)
        try? fm.createDirectory(at: place, withIntermediateDirectories: true)
        let pane = FinderPane(url: place)
        let first = pane.freeFolderName
        let made = pane.newFolder(named: first)
        let second = pane.freeFolderName
        let clash = pane.newFolder(named: first)
        let slash = pane.newFolder(named: "a/b")
        let named = pane.newFolder(named: "  Selects  ")
        let renamed = pane.rename(place.appendingPathComponent("Selects"), to: "Picks")
        var isFolder: ObjCBool = false
        check("new folder and rename", made == nil && second != first && clash != nil && slash != nil && named == nil && renamed == nil
              && fm.fileExists(atPath: place.appendingPathComponent(first).path, isDirectory: &isFolder) && isFolder.boolValue
              && fm.fileExists(atPath: place.appendingPathComponent("Picks").path)
              && !fm.fileExists(atPath: place.appendingPathComponent("Selects").path)
              && pane.selection.map(\.path) == [place.appendingPathComponent("Picks").path],
              "selection \(pane.selection.map(\.lastPathComponent)), made \(made ?? "ok"), second \(second), clash \(clash ?? "allowed"), slash \(slash ?? "allowed"), named \(named ?? "ok"), renamed \(renamed ?? "ok")")
    }

    /// Photos get their picture; opening one shows it in the pane, the arrows go through the
    /// folder's photos, and the viewer reads it no larger than asked, the right way up.
    private static func photoPicturesAndViewer(_ base: URL) async {
        let place = base.appendingPathComponent("Viewer", isDirectory: true)
        try? FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        for n in 1...3 { writePhoto(place.appendingPathComponent("P\(n).jpg"), camera: true, width: 1200, height: 800) }
        try? Data("x".utf8).write(to: place.appendingPathComponent("Readme.txt"))
        let pane = FinderPane(url: place)
        for _ in 0..<100 where pane.items.count < 4 { try? await Task.sleep(for: .milliseconds(30)) }
        let thumbs = FinderThumbnails.shared
        let photo = place.appendingPathComponent("P1.jpg")
        thumbs.wantPicture(photo)
        for _ in 0..<200 where thumbs.pictures[photo] == nil { try? await Task.sleep(for: .milliseconds(25)) }
        let picture = thumbs.pictures[photo]
        check("photos get a picture", picture != nil && max(picture?.width ?? 0, picture?.height ?? 0) <= Int(FinderThumbnails.pictureSize),
              "picture \(picture.map { "\($0.width)×\($0.height)" } ?? "none")")

        let kinds = pane.shown.map { "\($0.name):\($0.isPhoto)" }
        if let first = pane.shown.first(where: { $0.url.lastPathComponent == "P1.jpg" }) { pane.open(first) }
        let opened = pane.viewing?.lastPathComponent
        pane.view(by: 1)
        let next = pane.viewing?.lastPathComponent
        pane.view(by: 5)
        let last = pane.viewing?.lastPathComponent
        pane.goBack()
        let read = await FinderPhotoCache.shared.load(photo, longest: 512)
        let details = FinderPhotoDetails(photo).line
        check("photo viewer", pane.photos.count == 3 && opened == "P1.jpg" && next == "P2.jpg" && last == "P3.jpg" && pane.viewing == nil
              && read?.width == 512 && abs((read?.height ?? 0) - 341) <= 1 && details.contains("1200×800") && details.contains("Model One"),
              "kinds \(kinds), opened \(opened ?? "-"), next \(next ?? "-"), last \(last ?? "-"), read \(read.map { "\($0.width)×\($0.height)" } ?? "none"), \(details)")
    }

    /// On the same drive a move is immediate (nothing copied). To another drive (a disk image
    /// here) it's copied and checked, and only then are the originals put in the Trash (that
    /// drive's own, so nothing of the test reaches the real one).
    private static func moving(_ base: URL) async {
        let fm = FileManager.default
        let from = base.appendingPathComponent("Move From", isDirectory: true)
        let to = base.appendingPathComponent("Move To", isDirectory: true)
        for folder in [from, to] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        writePhoto(from.appendingPathComponent("Here.jpg"), camera: true)
        let jobsBefore = OffloadCenter.shared.jobs.count
        let here = await OffloadCenter.shared.copy([from.appendingPathComponent("Here.jpg")], into: to, move: true)
        check("move on the same drive is immediate", here == nil && OffloadCenter.shared.jobs.count == jobsBefore
              && fm.fileExists(atPath: to.appendingPathComponent("Here.jpg").path) && !fm.fileExists(atPath: from.appendingPathComponent("Here.jpg").path),
              "said \(here ?? "nothing"), jobs \(OffloadCenter.shared.jobs.count - jobsBefore)")

        let unreadable = await OffloadCenter.shared.copy([from.appendingPathComponent("Gone.jpg")], into: to)
        check("a file that can't be read is said", unreadable?.contains("Gone.jpg") == true, "said \(unreadable ?? "nothing")")

        // Another drive: a small disk image.
        let image = base.appendingPathComponent("Other.dmg")
        let mount = base.appendingPathComponent("Other Drive", isDirectory: true)
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
        guard hdiutil(["create", "-size", "8m", "-fs", "APFS", "-volname", "Pluck Move Test", image.path]),
              hdiutil(["attach", image.path, "-mountpoint", mount.path, "-nobrowse"]) else {
            return check("move to another drive checks first", false, "couldn't make a disk image")
        }
        defer { _ = hdiutil(["detach", mount.path, "-force"]) }
        let album = mount.appendingPathComponent("Album", isDirectory: true)
        try? fm.createDirectory(at: album, withIntermediateDirectories: true)
        for n in 1...3 { writePhoto(album.appendingPathComponent("IMG_000\(n).JPG"), camera: true) }
        try? Data("loose".utf8).write(to: mount.appendingPathComponent("Loose.txt"))
        let before = Set(OffloadCenter.shared.jobs.map(\.id))
        let problem = await OffloadCenter.shared.copy([album, mount.appendingPathComponent("Loose.txt")], into: to, move: true)
        let ids = Set(OffloadCenter.shared.jobs.map(\.id)).subtracting(before)
        let movingSet = OffloadCenter.shared.jobs.filter { ids.contains($0.id) }.allSatisfy { $0.moving != nil }
        let jobs = await finished(ids)
        // (They go to the Trash in the background: waited for.)
        for _ in 0..<100 where fm.fileExists(atPath: album.path) || fm.fileExists(atPath: mount.appendingPathComponent("Loose.txt").path) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let arrived = ["Album/IMG_0001.JPG", "Album/IMG_0003.JPG", "Loose.txt"].allSatisfy { fm.fileExists(atPath: to.appendingPathComponent($0).path) }
        let gone = !fm.fileExists(atPath: album.path) && !fm.fileExists(atPath: mount.appendingPathComponent("Loose.txt").path)
        let checked = jobs.flatMap(\.files).allSatisfy { $0.hash != nil && $0.problem == nil }
        check("move to another drive checks first", problem == nil && ids.count == 2 && movingSet && arrived && gone && checked,
              "problem \(problem ?? "none"), jobs \(ids.count), moving \(movingSet), arrived \(arrived), originals gone \(gone), checked \(checked)")
        await movingKeepsOriginals(mount, to)
    }

    /// A move to another drive whose originals aren't just what was checked keeps them: a file
    /// that couldn't be read, one written into the folder while it copied, a link (not copied).
    /// An empty folder is made on the other side, so it moves. A whole drive is only copied.
    private static func movingKeepsOriginals(_ mount: URL, _ to: URL) async {
        let fm = FileManager.default
        /// Moves these; the jobs once done and whether their originals went to the Trash.
        func move(_ items: [URL], into folder: URL, meanwhile: () -> Void = {}) async -> (problem: String?, jobs: [OffloadJob], trashed: [Bool]) {
            let before = Set(OffloadCenter.shared.jobs.map(\.id))
            let problem = await OffloadCenter.shared.copy(items, into: folder, move: true)
            // (Before the copy can finish: its end is handled on this actor.)
            meanwhile()
            let jobs = await finished(Set(OffloadCenter.shared.jobs.map(\.id)).subtracting(before))
            var trashed: [Bool] = []
            for _ in 0..<200 {
                trashed = jobs.compactMap { OffloadCenter.shared.trashed[$0.id] }
                if trashed.count == jobs.count { break }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return (problem, jobs, trashed)
        }

        // A file that can't be read: one problem, every original kept.
        let locked = mount.appendingPathComponent("Locked.txt"), open = mount.appendingPathComponent("Open.txt")
        try? Data("locked".utf8).write(to: locked)
        try? Data("open".utf8).write(to: open)
        try? fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        let unreadable = await move([locked, open], into: to.appendingPathComponent("Unreadable", isDirectory: true).creating())
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
        check("a move with a file that fails keeps every original",
              unreadable.jobs.flatMap(\.problems).count == 1 && fm.fileExists(atPath: locked.path) && fm.fileExists(atPath: open.path),
              "problems \(unreadable.jobs.flatMap(\.problems).count), locked kept \(fm.fileExists(atPath: locked.path)), open kept \(fm.fileExists(atPath: open.path))")

        // A file written into the folder after the move began.
        let growing = mount.appendingPathComponent("Growing", isDirectory: true)
        try? fm.createDirectory(at: growing, withIntermediateDirectories: true)
        try? Data("first".utf8).write(to: growing.appendingPathComponent("One.txt"))
        let late = growing.appendingPathComponent("Late.txt")
        let grown = await move([growing], into: to.appendingPathComponent("Grown", isDirectory: true).creating()) {
            try? Data("late".utf8).write(to: late)
        }
        check("a file added while moving keeps the originals", grown.jobs.count == 1 && grown.trashed == [false]
              && fm.fileExists(atPath: late.path) && fm.fileExists(atPath: growing.appendingPathComponent("One.txt").path),
              "jobs \(grown.jobs.count), trashed \(grown.trashed), late kept \(fm.fileExists(atPath: late.path))")

        // A link isn't copied, so the originals stay; an empty folder (a camera card's) is made on the other side.
        let linked = mount.appendingPathComponent("Linked", isDirectory: true), empty = mount.appendingPathComponent("Empty", isDirectory: true)
        for folder in [linked, empty.appendingPathComponent("Nothing", isDirectory: true)] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        try? Data("a".utf8).write(to: linked.appendingPathComponent("A.txt"))
        try? fm.createSymbolicLink(atPath: linked.appendingPathComponent("Link.txt").path, withDestinationPath: "A.txt")
        try? Data("b".utf8).write(to: empty.appendingPathComponent("B.txt"))
        let odd = await move([linked], into: to.appendingPathComponent("Odd", isDirectory: true).creating())
        let why = odd.jobs.first.flatMap(OffloadCenter.keepOriginals) ?? ""
        check("a link keeps the originals", odd.jobs.count == 1 && odd.trashed == [false] && why.contains("links")
              && fm.fileExists(atPath: linked.appendingPathComponent("A.txt").path),
              "jobs \(odd.jobs.count), trashed \(odd.trashed), said \(why)")
        let emptied = await move([empty], into: to.appendingPathComponent("Odd", isDirectory: true))
        var isFolder: ObjCBool = false
        check("an empty folder moves too", emptied.jobs.count == 1 && emptied.trashed == [true] && !fm.fileExists(atPath: empty.path)
              && fm.fileExists(atPath: to.appendingPathComponent("Odd/Empty/Nothing").path, isDirectory: &isFolder) && isFolder.boolValue,
              "jobs \(emptied.jobs.count), trashed \(emptied.trashed), original there \(fm.fileExists(atPath: empty.path))")

        // The whole drive: copied, not moved.
        let whole = await move([mount], into: to.appendingPathComponent("Whole", isDirectory: true).creating())
        check("a whole drive is only copied", whole.problem?.contains("whole drive") == true && whole.jobs.count == 1 && whole.jobs.first?.moving == nil
              && fm.fileExists(atPath: open.path),
              "said \(whole.problem ?? "nothing"), jobs \(whole.jobs.count), moving \(whole.jobs.first?.moving != nil)")
    }

    /// Dragging out: every chosen file its own file URL (a folder too), and outside Pluck only
    /// ever a copy; an item not chosen goes alone.
    private static func dragOut(_ base: URL) {
        let files = ["One.mov", "Two.jpg", "Folder"].map { base.appendingPathComponent("Drag/\($0)") }
        try? FileManager.default.createDirectory(at: files[2], withIntermediateDirectories: true)
        for file in files.prefix(2) { try? Data([1]).write(to: file) }
        let pane = FinderPane(url: base.appendingPathComponent("Drag"))
        pane.selection = Set(files)
        let dragged = FinderDrag.urls(files[0], in: pane), alone = FinderDrag.urls(base, in: pane)
        let board = NSPasteboard(name: NSPasteboard.Name("pluck-selftest-\(UUID().uuidString)"))
        board.clearContents()
        board.writeObjects(FinderDrag.items(dragged).compactMap { $0.item as? NSPasteboardWriting })
        let read = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let perItem = board.pasteboardItems?.count == 3 && board.pasteboardItems?.allSatisfy { $0.types.contains(.fileURL) } == true
        board.releaseGlobally()
        let outside = FinderDrag.operations(.outsideApplication), inside = FinderDrag.operations(.withinApplication)
        check("drag out: the whole selection, copy only", read.map(\.path).sorted() == files.map(\.path).sorted() && perItem
              && outside == .copy && inside.contains(.copy) && !inside.contains(.move) && !inside.contains(.delete) && alone == [base],
              "read \(read.map(\.lastPathComponent)), per item \(perItem), outside \(outside.rawValue), inside \(inside.rawValue), alone \(alone)")
    }

    /// Panes split below, turned side by side and back; the bar between them keeps each pane usable.
    private static func splitsTurn() {
        let workspace = FinderWorkspace.shared
        let count = workspace.panes.count
        guard count < FinderWorkspace.maxPanes else { return check("splits turn", false, "already \(count) panes") }
        workspace.split(.vertical)
        let below = workspace.axis(of: workspace.focused)
        workspace.turn()
        let turned = workspace.axis(of: workspace.focused)
        workspace.close()
        check("splits turn", below == .vertical && turned == .horizontal && workspace.panes.count == count,
              "split \(String(describing: below)), turned \(String(describing: turned)), panes \(workspace.panes.count)")
    }
}

private extension URL {
    /// This folder, made if it isn't there.
    func creating() -> URL {
        try? FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
        return self
    }
}
