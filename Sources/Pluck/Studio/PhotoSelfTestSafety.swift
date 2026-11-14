import Foundation

/// Keeping what's saved safe (-PluckScreenshotOnly safety): an unreadable catalogue is kept aside, not replaced; a record or
/// rule that can't be read costs only itself; History brings back only the edit; changes grouped are one undo step; an
/// empty change keeps the redo steps; a film failing on another thread doesn't fail this one.
extension PhotoSelfTest {
    static func safetyTest() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-safety-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func kept(_ name: String) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(name) && $0.contains("unreadable") }
        }

        // Unreadable: moved aside, nothing read, saving not held back (the file is safe).
        let broken = folder.appendingPathComponent("catalog.json")
        try? Data("{ not json".utf8).write(to: broken)
        let read = PhotoCatalog.testLoad(broken)
        check("safety: unreadable catalogue kept aside", read.records.isEmpty && !read.blocked && !FileManager.default.fileExists(atPath: broken.path)
              && kept("catalog").count == 1, "\(kept("catalog"))")

        // In part: the good records kept (a bad field takes its default), a bad element dropped, a copy kept.
        let partial = folder.appendingPathComponent("partial.json")
        let json = """
        {"records": {"/a.jpg": {"rating": 4, "flag": "pick"}, "/b.jpg": {"rating": 2, "flag": "someday", "adjust": 7}, "/c.jpg": 12},
         "albums": [{"id": "\(UUID().uuidString)", "name": "Kept", "paths": ["/a.jpg"], "created": 0}, {"name": 3}]}
        """
        try? Data(json.utf8).write(to: partial)
        let some = PhotoCatalog.testLoad(partial)
        check("safety: one bad record costs only itself", some.records.count == 2 && some.records["/a.jpg"]?.rating == 4
              && some.records["/a.jpg"]?.flag == .pick && some.records["/b.jpg"]?.rating == 2 && some.records["/b.jpg"]?.flag == PhotoRecord.Flag.none
              && some.albums.map(\.name) == ["Kept"], "\(some.records.keys.sorted()) \(some.albums.map(\.name))")
        check("safety: a catalogue read in part is copied aside", FileManager.default.fileExists(atPath: partial.path) && kept("partial").count == 1)

        // A smart album with a rule of a kind it doesn't know keeps the rest.
        let album = try? JSONDecoder().decode(SmartAlbum.self, from: Data("""
        {"id": "\(UUID().uuidString)", "name": "Best", "matchAll": true,
         "rules": [{"id": "\(UUID().uuidString)", "field": "colourCast", "number": 1, "text": ""}, {"id": "\(UUID().uuidString)", "field": "rating", "number": 4, "text": ""}]}
        """.utf8))
        check("safety: an unknown rule costs only itself", album?.rules.map(\.field) == [.rating] && album?.rules.first?.number == 4, "\(album?.rules.map(\.field) ?? [])")

        // History: going back brings the edit, never the rating or flag given since.
        let catalog = PhotoCatalog.shared
        let path = "/tmp/pluck-safety/test-\(UUID().uuidString).jpg"
        catalog.endStep(); catalog.update([path]) { $0.adjust.exposure = 0.4 }
        catalog.endStep(); catalog.update([path]) { $0.adjust.exposure = 0.8 }
        catalog.endStep(); catalog.update([path]) { $0.rating = 4; $0.flag = .pick }
        catalog.endStep()
        if let first = catalog.history(of: path).first {
            PhotoHistory.restore(first.after, on: path)
            let now = catalog.record(path)
            check("safety: History keeps the rating", now.adjust.exposure == 0.4 && now.rating == 4 && now.flag == .pick,
                  "exposure \(now.adjust.exposure), rating \(now.rating), flag \(now.flag)")
        } else {
            check("safety: History keeps the rating", false, "no steps")
        }

        // Grouped: one undo step for two sets of photos.
        let a = path + "-a", b = path + "-b"
        catalog.group {
            catalog.update([a]) { $0.flag = .pick }
            catalog.update([b]) { $0.flag = .reject }
        }
        catalog.undo()
        check("safety: grouped changes are one undo step", catalog.record(a).flag == .none && catalog.record(b).flag == .none,
              "\(catalog.record(a).flag) \(catalog.record(b).flag)")

        // A change of nothing keeps the redo steps.
        catalog.update([]) { $0.rating = 1 }
        catalog.update([a]) { $0.flag = .none }
        check("safety: an empty change keeps redo", catalog.canRedo)
        catalog.redo()

        // A film failing on another thread doesn't count here.
        let before = FilmHalation.failures
        let done = DispatchSemaphore(value: 0)
        Thread { FilmHalation.Watch.current.note(); done.signal() }.start()
        done.wait()
        check("safety: film failures are per render", FilmHalation.failures == before)
        catalog.saveNow()
    }
}
