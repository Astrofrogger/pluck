import Foundation

/// Virtual copies (Task 21): their own edit, the same file.
extension PhotoSelfTest {
    static func copies() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-copies-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let source = (try? FileManager.default.contentsOfDirectory(atPath: photos))?.first(where: { $0.lowercased().hasSuffix(".jpg") }) else {
            return check("copy fixture", false, "a JPEG in the photos folder")
        }
        let a = folder.appendingPathComponent("A.jpg").path, b = folder.appendingPathComponent("B.jpg").path
        try? FileManager.default.copyItem(atPath: (photos as NSString).appendingPathComponent(source), toPath: a)
        try? FileManager.default.copyItem(atPath: a, toPath: b)
        let catalog = PhotoCatalog.shared
        let defaults = UserDefaults.standard
        let writing = defaults.bool(forKey: "photoWriteXMP")
        defaults.set(true, forKey: "photoWriteXMP")
        defer { defaults.set(writing, forKey: "photoWriteXMP") }

        catalog.update([a]) { $0.adjust.contrast = 20 }
        let copy = catalog.makeCopy(of: a)
        catalog.update([copy]) { $0.adjust.exposure = 1 }
        check("copy has own edits", catalog.record(a).adjust.exposure == 0 && catalog.record(copy).adjust.exposure == 1
              && catalog.record(copy).adjust.contrast == 20 && PhotoCatalog.file(of: copy) == a,
              "A unchanged, the copy from A's edit; got \(catalog.record(a).adjust.exposure), \(catalog.record(copy).adjust.exposure)")
        check("copies listed after original", catalog.withCopies([a, b]) == [a, copy, b], "A, its copy, B; got \(catalog.withCopies([a, b]))")
        let original = PhotoRender.base(a, maxSize: 256, record: catalog.record(a))?.image.extent.size
        let copied = PhotoRender.base(copy, maxSize: 256, record: catalog.record(copy))?.image.extent.size
        check("copy renders", copied != nil && copied == original, "A's size; got \(String(describing: copied)) and \(String(describing: original))")
        check("copy exports as copy2", PhotoExportSettings().fileName(for: copy, number: 0) == "A-copy2"
              && PhotoCatalog.displayName(copy) == "A.jpg (2)", "A-copy2; got \(PhotoExportSettings().fileName(for: copy, number: 0))")

        // Only the original goes into the file's sidecar (written a moment later).
        try? await Task.sleep(for: .milliseconds(1600))
        let sidecar = PhotoXMP.sidecars(for: a)[0]
        let text = (try? String(contentsOf: sidecar, encoding: .utf8)) ?? ""
        let recipe = PhotoXMP.read(a)?.record
        check("copy not in sidecar", !FileManager.default.fileExists(atPath: sidecar.path + "#copy-2") && !text.contains("#copy-")
              && recipe?.adjust.exposure != 1, "A's own edit only; got exposure \(String(describing: recipe?.adjust.exposure))")

        catalog.removeCopy(copy)
        check("removing copy keeps file", catalog.records[copy] == nil && FileManager.default.fileExists(atPath: a) && catalog.withCopies([a]) == [a])
        catalog.undo()
        check("removing a copy undoes", catalog.records[copy]?.adjust.exposure == 1)
        catalog.removeCopy(copy)

        // Albums hold the files; copies come with them. Several copies go in one step.
        let album = catalog.newAlbum(named: "Self Test Copies", with: [catalog.makeCopy(of: a)])
        check("album of a copy holds its file", album.paths == [a])
        let more = [catalog.makeCopy(of: a), catalog.makeCopy(of: a)]
        check("copy numbers aren't reused", Set(more.compactMap(PhotoCatalog.copyNumber)).isDisjoint(with: [2]), "after 2; got \(more)")
        catalog.removeCopies(more + catalog.copies(of: a))
        catalog.undo()
        check("removing copies is one step", more.allSatisfy { catalog.records[$0] != nil })
        catalog.removeCopies(catalog.copies(of: a))
        catalog.deleteAlbum(album.id)
        check("a file named like a copy isn't one", !PhotoCatalog.isCopy("/x/IMG#copy-1.jpg") && PhotoCatalog.file(of: "/x/IMG#copy-1.jpg") == "/x/IMG#copy-1.jpg")
    }
}
