import AppKit

/// The project manager (Edit, nothing open): made, renamed, copied, filed, nested, trashed and
/// put back, the Trash emptied into the Mac's, a dropped file imported, an old project listed,
/// search and sort; in a store folder of its own (the test copy's projects aren't touched).
extension EditSelfTest {
    static func projectManager() async {
        let real = ProjectStore.folder
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-projects-\(UUID().uuidString)", isDirectory: true)
        ProjectStore.folder = base.appendingPathComponent("Projects", isDirectory: true)
        defer {
            ProjectStore.folder = real
            try? FileManager.default.removeItem(at: base)
        }
        let nav = StudioNavigator.shared

        // Made: listed under All Projects.
        var beach = Project(name: "Beach Day")
        beach.created = Date(timeIntervalSince1970: 1_000)
        beach.modified = Date(timeIntervalSince1970: 3_000)
        beach.clips = [ProjectClip(path: "/nowhere/a.mp4", start: 0, end: 30)]
        var city = Project(name: "City Night")
        city.created = Date(timeIntervalSince1970: 2_000)
        city.modified = Date(timeIntervalSince1970: 2_500)
        city.clips = [ProjectClip(path: "/nowhere/b.mp4", start: 0, end: 90)]
        var autumn = Project(name: "autumn beach walk")
        autumn.created = Date(timeIntervalSince1970: 3_000)
        autumn.modified = Date(timeIntervalSince1970: 1_500)
        for project in [beach, city, autumn] { ProjectStore.save(project) }
        var all = ProjectStore.madeProjects(trashed: true)
        check("projects: made ones under All Projects", ProjectStore.shown(all, in: .all).count == 3, "3; got \(ProjectStore.shown(all, in: .all).map(\.name))")

        // Renamed.
        nav.renameProject(city.id, to: "City Lights")
        check("projects: rename", ProjectStore.load(city.id)?.name == "City Lights", "got \(ProjectStore.load(city.id)?.name ?? "nil")")

        // Duplicated: a new id, the same edit, the original as it was.
        try? Data("still".utf8).write(to: ProjectStore.thumbnail(for: beach.id))
        let before = try? Data(contentsOf: ProjectStore.url(for: beach.id))
        let copy = ProjectStore.duplicate(beach.id)
        check("projects: duplicate", copy != nil && copy?.id != beach.id && ProjectStore.load(copy!.id)?.clips.count == 1
              && copy?.name != beach.name && (try? Data(contentsOf: ProjectStore.url(for: beach.id))) == before
              && FileManager.default.fileExists(atPath: ProjectStore.thumbnail(for: copy!.id).path),
              "a new id, 1 clip, its still, the original unchanged; got \(String(describing: copy?.name))")

        // Filed in a folder, and folders in folders.
        let clients = ProjectStore.Folder(name: "Clients")
        let studio = ProjectStore.Folder(name: "Studio A", parent: clients.id)
        ProjectStore.saveFolders([clients, studio])
        nav.fileProject(beach.id, in: studio.id)
        all = ProjectStore.madeProjects(trashed: true)
        check("projects: move to folder", ProjectStore.shown(all, in: .folder(studio.id)).map(\.id) == [beach.id]
              && ProjectStore.shown(all, in: .all).contains { $0.id == beach.id }, "Beach Day in Studio A and still in All")
        let tree = ProjectStore.tree(ProjectStore.folders())
        check("projects: nested folders", tree.map(\.folder.name) == ["Clients", "Studio A"] && tree.map(\.depth) == [0, 1]
              && !ProjectStore.canNest(clients.id, in: studio.id, ProjectStore.folders()) && ProjectStore.canNest(studio.id, in: nil, ProjectStore.folders())
              && ProjectStore.tree(ProjectStore.folders(), closed: [clients.id]).count == 1,
              "Clients ▸ Studio A, no folder in itself; got \(tree.map { "\($0.folder.name)@\($0.depth)" })")
        ProjectStore.deleteFolder(studio.id, projects: all) { nav.fileProject($0, in: $1) }
        check("projects: deleting a folder keeps what's in it", ProjectStore.load(beach.id)?.folder == clients.id
              && ProjectStore.folders().map(\.id) == [clients.id], "Beach Day up into Clients")

        // Trashed and put back.
        nav.trashProject(city.id)
        all = ProjectStore.madeProjects(trashed: true)
        check("projects: move to trash", ProjectStore.shown(all, in: .trash).map(\.id) == [city.id] && !ProjectStore.shown(all, in: .all).contains { $0.id == city.id }
              && FileManager.default.fileExists(atPath: ProjectStore.url(for: city.id).path)
              && !ProjectStore.madeProjects().contains { $0.id == city.id }, "only in Trash, its file still there")
        nav.putBack(city.id)
        all = ProjectStore.madeProjects(trashed: true)
        check("projects: put back", ProjectStore.shown(all, in: .all).contains { $0.id == city.id } && ProjectStore.shown(all, in: .trash).isEmpty)

        // The Trash emptied: into the Mac's Trash, not deleted.
        nav.trashProject(autumn.id)
        let gone = ProjectStore.url(for: autumn.id)
        let emptied = ProjectStore.emptyTrash()
        check("projects: empty trash goes to the Mac's Trash", emptied.count == 1 && !FileManager.default.fileExists(atPath: gone.path)
              && emptied.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } && ProjectStore.load(beach.id) != nil,
              "1 moved, there in the Trash; got \(emptied.map(\.path))")
        // (This test's own file: not left in the Trash.)
        for file in emptied { try? FileManager.default.removeItem(at: file) }

        // A dropped file: copied in with a new id, the file left as it was.
        let outside = base.appendingPathComponent("Shared.pluckproject")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var shared = Project(name: "From Another Mac")
        shared.folder = UUID()
        shared.clips = [ProjectClip(path: "/nowhere/c.mp4", start: 0, end: 12)]
        try? encoder.encode(shared).write(to: outside)
        let original = try? Data(contentsOf: outside)
        let first = ProjectStore.importProject(outside), second = ProjectStore.importProject(outside)
        check("projects: import a dropped file", first != nil && second != nil && first?.id != shared.id && first?.id != second?.id
              && ProjectStore.load(first!.id)?.clips.count == 1 && first?.folder == nil
              && (try? Data(contentsOf: outside)) == original, "two copies, new ids, the file untouched")

        // An old project (no folder, no Trash) and an old folders file.
        let old = UUID()
        try? Data(#"{"id":"\#(old.uuidString)","name":"Old One","clips":[],"music":[],"titles":[],"modified":"2024-05-01T10:00:00Z"}"#.utf8)
            .write(to: ProjectStore.url(for: old))
        try? Data(#"[{"id":"\#(clients.id.uuidString)","name":"Clients"}]"#.utf8).write(to: ProjectStore.folder.appendingPathComponent("folders.json"))
        all = ProjectStore.madeProjects(trashed: true)
        check("projects: an old project shows under All Projects", ProjectStore.shown(all, in: .all).contains { $0.id == old && $0.folder == nil && $0.trashed == nil }
              && ProjectStore.folders().first?.parent == nil && ProjectStore.folders().count == 1)

        // Search and sort.
        all = ProjectStore.madeProjects(trashed: true).filter { [beach.id, city.id].contains($0.id) || $0.name.contains("Beach") }
        let found = ProjectStore.shown(all, in: .all, search: "BEACH")
        check("projects: search", found.count == 2 && found.allSatisfy { $0.name.lowercased().contains("beach") }, "2 beaches; got \(found.map(\.name))")
        let byName = ProjectStore.shown([beach, city, autumn], in: .all, sort: .name, ascending: true).map(\.name)
        let byChanged = ProjectStore.shown([beach, city, autumn], in: .all, sort: .changed).map(\.name)
        let byCreated = ProjectStore.shown([beach, city, autumn], in: .all, sort: .created).map(\.name)
        let byLength = ProjectStore.shown([beach, city, autumn], in: .all, sort: .length).map(\.name)
        check("projects: sort", byName == ["autumn beach walk", "Beach Day", "City Night"] && byChanged == ["Beach Day", "City Night", "autumn beach walk"]
              && byCreated == ["autumn beach walk", "City Night", "Beach Day"] && byLength == ["City Night", "Beach Day", "autumn beach walk"],
              "got \(byName) \(byChanged) \(byCreated) \(byLength)")
        let recent = ProjectStore.shown([beach, city, autumn], in: .recent, recent: [city.id, autumn.id, UUID()])
        check("projects: recent in the order opened", recent.map(\.id) == [city.id, autumn.id])

        // The still: the frame at the playhead, written off the main thread on closing.
        let model = await project(["a.mp4"])
        for _ in 0..<40 where model.player.currentItem?.videoComposition == nil { try? await Task.sleep(for: .milliseconds(250)) }
        model.seek(to: 2)
        model.close()
        let still = ProjectStore.thumbnail(for: model.project.id)
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: still.path) { try? await Task.sleep(for: .milliseconds(100)) }
        check("projects: a still on closing", FileManager.default.fileExists(atPath: still.path) && NSImage(contentsOf: still) != nil, "no \(still.lastPathComponent) (built: \(model.player.currentItem?.videoComposition != nil))")
    }
}
