import CryptoKit
import Foundation

/// A file opened on the Edit page is a project of its own: its clips are the parts kept, and
/// everything the Editor did to a file (cuts, the in and out points, the look, subtitles) is
/// done to that project. Such projects aren't listed with the ones made by hand.
extension ProjectStore {
    /// The file's own project, made the first time it's opened.
    static func fileProject(for path: String) -> Project {
        if let found = all().first(where: { $0.origin == path }) { return found }
        let file = URL(fileURLWithPath: path)
        var project = Project(name: file.deletingPathExtension().lastPathComponent)
        project.origin = path
        project.media = [path]
        save(project)
        return project
    }

    /// The projects made by hand (not the files' own).
    static func madeProjects() -> [Project] { all().filter { $0.origin == nil } }
}

extension ProjectModel {
    /// A file's own project, opened for the first time: the whole file as one clip, or what the
    /// Editor kept of it before (its saved edit, look and subtitles, when it's still the same
    /// file). Not undoable: it's where the edit starts.
    func prepareFile() async {
        guard let path = project.origin, project.clips.isEmpty else { return }
        let file = URL(fileURLWithPath: path)
        let length = await self.length(of: file)
        guard length > 0, project.clips.isEmpty else { return }
        let old = OldEdit(file: file)

        var clips: [ProjectClip] = []
        var inPoint: Double?, outPoint: Double?
        if let edit = old.edit {
            let edges = [0] + edit.cuts.filter { $0 > 0 && $0 < length }.sorted() + [length]
            let removed = Set(edit.removed)
            for (start, end) in zip(edges, edges.dropFirst()) where end > start && !removed.contains(start) {
                clips.append(ProjectClip(path: path, start: start, end: end))
            }
            // The in and out points, from the file's time to the edit's.
            inPoint = edit.inPoint.flatMap { Self.timelineTime(of: $0, in: clips) }
            outPoint = edit.outPoint.flatMap { Self.timelineTime(of: $0, in: clips) }
        }
        if clips.isEmpty { clips = [ProjectClip(path: path, start: 0, end: length)] }
        if let look = old.look { for index in clips.indices { clips[index].look = look } }
        let subtitles = old.subtitles
        setUp { project in
            project.clips = clips
            project.inPoint = inPoint
            project.outPoint = outPoint
            if let subtitles {
                project.fileSubtitles = [path: subtitles.cues]
                project.subtitleStyle = subtitles.style
                project.subtitlesOn = subtitles.shown
            }
        }
    }

    /// Where a moment of the file falls on the timeline of these clips (one after another), if
    /// it's in one of them.
    static func timelineTime(of seconds: Double, in clips: [ProjectClip]) -> Double? {
        var at = 0.0
        for clip in clips {
            if seconds >= clip.start, seconds <= clip.end { return at + (seconds - clip.start) / clip.speed }
            at += clip.length
        }
        return nil
    }
}

/// What the Editor saved for a file before it was a project (kept in Pluck's folder by the
/// file's path; read once, when the file is first opened as a project).
private struct OldEdit {
    struct Edit: Codable {
        var size: Int
        var modified: Double
        var cuts: [Double]
        var removed: [Double]
        var inPoint: Double?
        var outPoint: Double?
    }

    struct Subtitles: Codable {
        var cues: [SubtitleCue]
        var style: SubtitleStyle
        var shown: Bool
    }

    var edit: Edit?
    var look: ClipLook?
    var subtitles: Subtitles?

    init(file: URL) {
        let name = SHA256.hash(data: Data(file.path.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck")
        func read<T: Decodable>(_ folder: String, _ type: T.Type) -> T? {
            guard let data = try? Data(contentsOf: base.appendingPathComponent("\(folder)/\(name).json")) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
        // The cuts only while the file is the same one (its size and date).
        if let saved = read("Editor Edits", Edit.self),
           let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
           values.fileSize == saved.size, let date = values.contentModificationDate, abs(date.timeIntervalSince1970 - saved.modified) < 1 {
            edit = saved
        }
        look = read("Editor Looks", ClipLook.self)
        subtitles = read("Editor Subtitles", Subtitles.self)
    }
}

/// The screenshot self-test of editing by the file's time.
@MainActor
enum FileEditsSelfTest {
    static func run(defaults: UserDefaults) async {
        guard let path = defaults.string(forKey: "PluckScreenshotFile"), let log = defaults.string(forKey: "PluckScreenshotLog") else { return }
        var lines: [String] = []
        var project = Project(name: "Test")
        project.origin = path
        let model = ProjectModel(project: project)
        await model.prepareFile()
        func note(_ step: String) {
            let clips = model.project.clips.map { String(format: "%.2f-%.2f", $0.start, $0.end) }.joined(separator: " ")
            lines.append("\(step): \(clips) | length \(String(format: "%.2f", model.duration))")
        }
        note("start")
        model.cutOut(path, [2...4, 6...7])
        note("cut 2-4 6-7")
        model.cutOut(path, [3.5...6.5])
        note("cut 3.5-6.5")
        model.restore(path, 3...4)
        note("restore 3-4")
        model.restore(path, 2...7)
        note("restore 2-7")
        model.keepOnly(path, [8...9, 1...2])
        note("keep 8-9 1-2")
        model.undo()
        note("undo")
        model.markIn(1); model.markOut(5)
        lines.append("range \(model.range)")

        // Held frames, sound taken off, copying.
        model.keepOnly(path, [0...4, 10...14])
        note("two clips")
        model.seek(to: 2)
        try? await Task.sleep(for: .milliseconds(300))
        model.freezeFrame(at: 2, length: 1.5)
        let freezes = model.project.clips.map { $0.freeze.map { String(format: "F%.2f", $0) } ?? "-" }.joined(separator: " ")
        note("freeze at 2 [\(freezes)]")
        let last = model.project.clips.last!.id
        model.detachAudio([last])
        func items() -> String {
            (model.project.tracks ?? []).map { "\($0.kind.rawValue): " + $0.items.map { String(format: "%.2f@%.2f%@", $0.start, $0.at ?? -1, $0.link == nil ? "" : "L") }.joined(separator: " ") }.joined(separator: " | ")
        }
        lines.append("detach last: own \(model.project.clips.last!.ownAudio.map(String.init) ?? "nil") | \(items())")
        model.move(last, to: 0)
        lines.append("move it first: \(items()) | clip0 \(model.project.clips[0].id == last)")
        model.selected = [model.project.clips[1].id]
        _ = model.copySelection()
        model.seek(to: 0)
        try? await Task.sleep(for: .milliseconds(300))
        _ = model.paste()
        note("paste at 0")
        model.attachAudio([last])
        lines.append("attach: \(items().isEmpty ? "no tracks" : items()) own \(model.project.clips.first { $0.id == last }?.ownAudio.map(String.init) ?? "nil")")
        model.undo(); model.undo()
        note("undo twice")
        model.close()
        try? lines.joined(separator: "\n").write(toFile: log, atomically: true, encoding: .utf8)
    }
}
