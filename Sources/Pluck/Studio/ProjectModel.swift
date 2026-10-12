import AVFoundation
import CoreImage
import SwiftUI

/// A clip on a project's timeline: a stretch of a video (or song) on this Mac, played in turn
/// with the others.
struct ProjectClip: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    /// Where in the file it starts and ends (seconds).
    var start: Double
    var end: Double
    var volume = 1.0
    var fadeIn = 0.0
    var fadeOut = 0.0
    /// What it is in the story, when the story finder put it there.
    var title: String?
    var role: StoryBeat.Role?
    /// Its picture: size, place, turn, crop, opacity, speed (as DaVinci Resolve's inspector).
    var look: ClipLook?

    var speed: Double { look?.speed ?? 1 }
    /// How long it lasts on the timeline (its part of the file, at its speed).
    var length: Double { max(end - start, 0) / speed }
    var file: URL { URL(fileURLWithPath: path) }
    var name: String { title ?? file.deletingPathExtension().lastPathComponent }
}

/// How a clip's picture sits in the frame, as in DaVinci Resolve's Video inspector.
struct ClipLook: Codable, Hashable {
    enum Scaling: String, Codable, CaseIterable, Identifiable {
        case fit, fill, stretch
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .fit: "Fit"
            case .fill: "Fill"
            case .stretch: "Stretch"
            }
        }
    }

    var scaling = Scaling.fit
    var zoom = 1.0
    /// Where it sits: shares of the frame's width and height from the middle (up is positive).
    var x = 0.0
    var y = 0.0
    /// Degrees, anticlockwise.
    var rotation = 0.0
    var flipH = false
    var flipV = false
    /// Cut from each side, as shares of the picture.
    var cropLeft = 0.0
    var cropRight = 0.0
    var cropTop = 0.0
    var cropBottom = 0.0
    /// Dynamic zoom: from `zoom` at the start to this at the end (nil: none).
    var zoomEnd: Double?
    var opacity = 1.0
    var speed = 1.0
    /// Smooths shaky footage (on export).
    var stabilize = false

    var isDefault: Bool { self == ClipLook() }
    var hasCrop: Bool { cropLeft > 0 || cropRight > 0 || cropTop > 0 || cropBottom > 0 }

    /// The zoom this far (0…1) through the clip, eased in and out.
    func zoom(at progress: Double) -> Double {
        guard let zoomEnd else { return zoom }
        let t = min(max(progress, 0), 1), eased = t * t * (3 - 2 * t)
        return max(zoom, 1) + (max(zoomEnd, 1) - max(zoom, 1)) * eased
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        scaling = value(.scaling, Scaling.fit); zoom = value(.zoom, 1); x = value(.x, 0); y = value(.y, 0); rotation = value(.rotation, 0)
        flipH = value(.flipH, false); flipV = value(.flipV, false)
        cropLeft = value(.cropLeft, 0); cropRight = value(.cropRight, 0); cropTop = value(.cropTop, 0); cropBottom = value(.cropBottom, 0)
        zoomEnd = value(.zoomEnd, nil as Double?); opacity = value(.opacity, 1); speed = value(.speed, 1); stabilize = value(.stabilize, false)
    }
}

extension ClipLook {
    /// The picture placed in a frame of this size, `progress` (0…1) through the clip: fitted,
    /// cropped, flipped, zoomed, turned and moved, on black.
    static func place(_ image: CIImage, look: ClipLook?, progress: Double, in size: CGSize) -> CIImage {
        let look = look ?? ClipLook()
        let extent = image.extent
        let width = max(extent.width, 1), height = max(extent.height, 1)
        var sx = min(size.width / width, size.height / height), sy = sx
        switch look.scaling {
        case .fit: break
        case .fill: sx = max(size.width / width, size.height / height); sy = sx
        case .stretch: sx = size.width / width; sy = size.height / height
        }
        var picture = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY).concatenating(CGAffineTransform(scaleX: sx, y: sy)))
        let w = width * sx, h = height * sy
        if look.hasCrop {
            picture = picture.cropped(to: CGRect(x: w * look.cropLeft, y: h * look.cropBottom,
                                                 width: max(w * (1 - look.cropLeft - look.cropRight), 1),
                                                 height: max(h * (1 - look.cropTop - look.cropBottom), 1)))
        }
        let zoom = look.zoom(at: progress)
        let transform = CGAffineTransform(translationX: -w / 2, y: -h / 2)
            .concatenating(CGAffineTransform(scaleX: (look.flipH ? -1 : 1) * zoom, y: (look.flipV ? -1 : 1) * zoom))
            .concatenating(CGAffineTransform(rotationAngle: look.rotation * .pi / 180))
            .concatenating(CGAffineTransform(translationX: size.width / 2 + look.x * size.width, y: size.height / 2 + look.y * size.height))
        picture = picture.transformed(by: transform)
        if look.opacity < 1 {
            let o = CGFloat(max(look.opacity, 0))
            picture = picture.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: o, y: 0, z: 0, w: 0),
                                                               "inputGVector": CIVector(x: 0, y: o, z: 0, w: 0),
                                                               "inputBVector": CIVector(x: 0, y: 0, z: o, w: 0)])
        }
        let frame = CGRect(origin: .zero, size: size)
        return picture.composited(over: CIImage(color: .black).cropped(to: frame)).cropped(to: frame)
    }
}

/// Music under the clips: a song (or any sound), from a point in the timeline.
struct ProjectMusic: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    /// Where it starts on the timeline, and the part of the song used.
    var at: Double
    var start: Double
    var end: Double
    var volume = 0.35
    var fadeIn = 1.0
    var fadeOut = 2.0

    var length: Double { max(end - start, 0) }
    var name: String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
}

/// Words on the picture for a while: a title, a name, a caption.
struct ProjectTitle: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var start: Double
    var end: Double
}

/// A project: several clips (from one file or many) on a timeline, with music and titles.
struct Project: Codable, Identifiable {
    var id = UUID()
    var name: String
    /// The folder it's filed in on the Edit page (nil: at the top).
    var folder: UUID?
    var created = Date.now
    var modified = Date.now
    var clips: [ProjectClip] = []
    /// Every file added to the project, also those not on the timeline (now or any more).
    var media: [String]?
    var music: [ProjectMusic] = []
    var titles: [ProjectTitle] = []
    /// Subtitles: made from each clip's transcript (so they follow the clips), with the lines
    /// changed by hand kept here by file and time ("" for a line taken out).
    var subtitlesOn: Bool?
    var subtitleEdits: [String: String]?
    var subtitleStyle: SubtitleStyle?
    /// The language they're in ("" or nil: as spoken), when the transcript has a translation.
    var subtitleLanguage: String?
    var titleStyle: SubtitleStyle = {
        var style = SubtitleStyle()
        style.y = 0.5
        style.scale = 1.6
        style.box = false
        style.shadow = 3
        return style
    }()

    var duration: Double { clips.reduce(0) { $0 + $1.length } }

    /// The project's files: those added, and any on the timeline, each once.
    var files: [String] {
        var seen: Set<String> = []
        return ((media ?? []) + clips.map(\.path)).filter { seen.insert($0).inserted }
    }
}

/// A project's subtitle line: where it is on the timeline, and which line of which file it is.
struct ProjectSubtitle: Identifiable, Hashable {
    var id: String { key }
    let key: String
    var start: Double
    var end: Double
    var text: String
    var edited: Bool
}

extension Project {
    /// The subtitles as they fall on the timeline now: each clip's transcript lines, cut to the
    /// part used, at its speed, with the changes made by hand.
    @MainActor func subtitles(includingRemoved: Bool = false) -> [ProjectSubtitle] {
        var result: [ProjectSubtitle] = []
        var at = 0.0
        var transcripts: [String: Transcript] = [:]
        let edits = subtitleEdits ?? [:]
        for clip in clips {
            defer { at += clip.length }
            let transcript = transcripts[clip.path] ?? TranscriptStore.find(forFile: clip.path)
            guard let transcript else { continue }
            transcripts[clip.path] = transcript
            var lines: [(start: Double, end: Double, text: String)]
            if let language = subtitleLanguage, !language.isEmpty, let translation = transcript.translations?[language] {
                lines = translation.lines.map { ($0.s, $0.e, Transcript.twoLines($0.t)) }
            } else {
                lines = transcript.cues(maxCharacters: 84, maxDuration: 6).map { ($0.start, $0.end, Transcript.twoLines($0.text)) }
            }
            lines = lines.filter { $0.end > clip.start + 0.05 && $0.start < clip.end - 0.05 }
            for line in lines {
                let key = "\(clip.path)|\(String(format: "%.2f", line.start))"
                let start = at + (max(line.start, clip.start) - clip.start) / clip.speed
                let end = at + (min(line.end, clip.end) - clip.start) / clip.speed
                guard end - start > 0.15 else { continue }
                let edit = edits[key]
                if edit == "", !includingRemoved { continue }
                result.append(ProjectSubtitle(key: key, start: start, end: end,
                                              text: edit ?? Glossary.correct(line.text, terms: Glossary.shared.terms), edited: edit != nil))
            }
        }
        return result
    }

    @MainActor var subtitleCues: [SubtitleCue] { subtitles().map { SubtitleCue(start: $0.start, end: $0.end, text: $0.text) } }

    var subtitleLook: SubtitleStyle { subtitleStyle ?? SubtitleStyle() }
}

/// Where projects are kept: one file each, in Pluck's folder.
enum ProjectStore {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck/Projects", isDirectory: true)
    }

    static func url(for id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).pluckproject") }

    static func load(_ id: UUID) -> Project? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Project.self, from: data)
    }

    static func save(_ project: Project) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(project).write(to: url(for: project.id), options: .atomic)
    }

    /// Folders to keep projects in order.
    struct Folder: Codable, Identifiable, Hashable {
        var id = UUID()
        var name: String
    }

    private static var foldersFile: URL { folder.appendingPathComponent("folders.json") }

    static func folders() -> [Folder] {
        guard let data = try? Data(contentsOf: foldersFile) else { return [] }
        return (try? JSONDecoder().decode([Folder].self, from: data)) ?? []
    }

    static func saveFolders(_ folders: [Folder]) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(folders).write(to: foldersFile, options: .atomic)
    }

    /// Changes a project that isn't open (an open one changes through its model).
    static func update(_ id: UUID, _ body: (inout Project) -> Void) {
        guard var project = load(id) else { return }
        body(&project)
        save(project)
    }

    /// Moves the project's file to the Trash.
    static func trash(_ id: UUID) {
        try? FileManager.default.trashItem(at: url(for: id), resultingItemURL: nil)
    }

    static func all() -> [Project] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "pluckproject" }
            .compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent).flatMap(load) }
            .sorted { $0.modified > $1.modified }
    }
}

/// A project being edited: the timeline, a player for it (an AVFoundation composition of the
/// clips, music and their volumes, rebuilt after every change), what's selected, and undo.
@MainActor
@Observable
final class ProjectModel {
    /// The story being laid out (kept here, so leaving the project and coming back shows it).
    var storyFinding = false
    var storyProgress = 0.0
    var storyProblem: String?
    var storyPassages: [ProjectStory.Passage] = []
    var sendingToResolve = false

    private(set) var project: Project
    let player = AVPlayer()
    let exports = ProjectExports()

    private(set) var time: Double = 0
    private(set) var rate: Float = 0
    var isPlaying: Bool { rate != 0 }
    var selected: Set<UUID> = []
    var selectedTitle: UUID?
    var tool: EditorModel.Tool = .select
    var snapping = true
    /// The picture's size (from the first clip).
    private(set) var renderSize = CGSize(width: 1920, height: 1080)
    private(set) var frameRate: Double = 25
    /// Small pictures of each clip's file, by path, for the timeline.
    private(set) var thumbnails: [String: [NSImage]] = [:]
    /// How long each file is (for trimming).
    private(set) var fileLengths: [String: Double] = [:]
    private(set) var preparing: String?

    @ObservationIgnored private var history: [Project] = []
    @ObservationIgnored private var future: [Project] = []
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var playable: [String: URL] = [:]

    init(project: Project) {
        self.project = project
        player.actionAtItemEnd = .pause
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = min(max(time.seconds, 0), self.duration)
                self.rate = self.player.rate
            }
        }
        rebuild()
    }

    var duration: Double { project.duration }
    var frame: Double { 1 / max(frameRate, 1) }
    var canUndo: Bool { !history.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    /// Where each clip starts on the timeline.
    var offsets: [Double] {
        var at = 0.0
        return project.clips.map { clip in defer { at += clip.length }; return at }
    }

    /// The clip at a time on the timeline, and how far into it.
    func clip(at seconds: Double) -> (index: Int, into: Double)? {
        var at = 0.0
        for (index, clip) in project.clips.enumerated() {
            if seconds < at + clip.length || index == project.clips.count - 1 { return (index, min(max(seconds - at, 0), clip.length)) }
            at += clip.length
        }
        return nil
    }

    func close() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
    }

    // MARK: - Changing (all undoable)

    /// Every change goes through here: remembered for undo, saved, and played back.
    func change(_ body: (inout Project) -> Void) {
        history.append(project)
        if history.count > 100 { history.removeFirst() }
        future = []
        body(&project)
        project.modified = .now
        ProjectStore.save(project)
        rebuild()
    }

    func undo() {
        guard let last = history.popLast() else { return }
        future.append(project)
        project = last
        ProjectStore.save(project)
        rebuild()
    }

    func redo() {
        guard let next = future.popLast() else { return }
        history.append(project)
        project = next
        ProjectStore.save(project)
        rebuild()
    }

    func rename(_ name: String) {
        project.name = name
        ProjectStore.save(project)
    }

    func file(in folder: UUID?) {
        project.folder = folder
        ProjectStore.save(project)
    }

    /// Adds whole files at the end (or at a place in the line of clips).
    func add(_ files: [URL], at index: Int? = nil) async {
        var clips: [ProjectClip] = []
        for file in files where EditorTarget.canOpen(file) {
            let length = await self.length(of: file)
            guard length > 0 else { continue }
            clips.append(ProjectClip(path: file.path, start: 0, end: length))
        }
        guard !clips.isEmpty else { return }
        change { project in
            let at = min(index ?? project.clips.count, project.clips.count)
            project.clips.insert(contentsOf: clips, at: at)
            project.media = project.files
        }
    }

    /// Replaces the timeline with these clips (a story laid out).
    func lay(_ clips: [ProjectClip]) {
        change { project in
            project.media = project.files
            project.clips = clips
        }
        selected = []
        seek(to: 0)
    }

    func move(_ id: UUID, to index: Int) {
        guard let from = project.clips.firstIndex(where: { $0.id == id }) else { return }
        change { project in
            let clip = project.clips.remove(at: from)
            project.clips.insert(clip, at: min(max(from < index ? index - 1 : index, 0), project.clips.count))
        }
    }

    /// Splits the clip under a time in two.
    func split(at seconds: Double) {
        guard let (index, into) = clip(at: seconds), into > frame, into < project.clips[index].length - frame else { return }
        change { project in
            var first = project.clips[index], second = project.clips[index]
            first.end = first.start + into * first.speed
            first.fadeOut = 0
            second.id = UUID()
            second.start = first.end
            second.fadeIn = 0
            project.clips[index] = first
            project.clips.insert(second, at: index + 1)
        }
    }

    /// Takes clips out; the ones after move up (nothing is left empty).
    func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        change { $0.clips.removeAll { ids.contains($0.id) } }
        selected = []
    }

    func duplicate(_ ids: Set<UUID>) {
        change { project in
            var result: [ProjectClip] = []
            for clip in project.clips {
                result.append(clip)
                if ids.contains(clip.id) { var copy = clip; copy.id = UUID(); result.append(copy) }
            }
            project.clips = result
        }
    }

    /// Moves a clip's start or end within its file (trimming), keeping it at least a frame long.
    func trim(_ id: UUID, start: Double? = nil, end: Double? = nil, record: Bool) {
        guard let index = project.clips.firstIndex(where: { $0.id == id }) else { return }
        let apply: (inout Project) -> Void = { project in
            var clip = project.clips[index]
            let fileLength = self.fileLengths[clip.path] ?? clip.end
            if let start { clip.start = min(max(start, 0), clip.end - self.frame) }
            if let end { clip.end = max(min(end, fileLength), clip.start + self.frame) }
            project.clips[index] = clip
        }
        if record { change(apply) } else { apply(&project); rebuildSoon() }
    }

    /// Sets something on a clip (volume, fades); `record` false while a slider moves.
    func set(_ id: UUID, record: Bool = true, _ body: @escaping (inout ProjectClip) -> Void) {
        guard let index = project.clips.firstIndex(where: { $0.id == id }) else { return }
        let old = project.clips[index]
        var new = old
        body(&new)
        // Only the picture changed: shown straight away, without building the edit again.
        var same = new
        same.look = old.look
        if same == old, new.speed == old.speed {
            if record { history.append(project); future = [] }
            project.clips[index] = new
            project.modified = .now
            if record { ProjectStore.save(project) }
            looks.set(index, new.look)
            redraw()
            return
        }
        if record { change { body(&$0.clips[index]) } } else { body(&project.clips[index]); rebuildSoon() }
    }

    /// The looks the picture is drawn with, read while it plays (so a change shows at once).
    final class Looks: @unchecked Sendable {
        private var entries: [(start: Double, end: Double, look: ClipLook?)] = []
        private let lock = NSLock()

        func replace(_ new: [(start: Double, end: Double, look: ClipLook?)]) {
            lock.lock(); entries = new; lock.unlock()
        }

        func set(_ index: Int, _ look: ClipLook?) {
            lock.lock()
            if entries.indices.contains(index) { entries[index].look = look }
            lock.unlock()
        }

        func at(_ seconds: Double) -> (look: ClipLook?, progress: Double) {
            lock.lock(); defer { lock.unlock() }
            guard let entry = entries.last(where: { $0.start <= seconds + 0.0005 }) ?? entries.first else { return (nil, 0) }
            return (entry.look, (seconds - entry.start) / max(entry.end - entry.start, 0.001))
        }
    }

    @ObservationIgnored let looks = Looks()

    /// Draws the frame again (when paused, the player keeps the last one otherwise).
    private func redraw() {
        guard let item = player.currentItem, let composition = item.videoComposition?.mutableCopy() as? AVMutableVideoComposition else { return }
        item.videoComposition = composition
    }

    func addMusic(_ file: URL) async {
        let length = await self.length(of: file)
        guard length > 0 else { return }
        change { $0.music.append(ProjectMusic(path: file.path, at: 0, start: 0, end: min(length, max($0.duration, 1)))) }
    }

    func setMusic(_ id: UUID, record: Bool = true, _ body: @escaping (inout ProjectMusic) -> Void) {
        guard let index = project.music.firstIndex(where: { $0.id == id }) else { return }
        if record { change { body(&$0.music[index]) } } else { body(&project.music[index]); rebuildSoon() }
    }

    func removeMusic(_ id: UUID) { change { $0.music.removeAll { $0.id == id } } }

    @discardableResult
    func addTitle(at seconds: Double) -> UUID {
        let title = ProjectTitle(text: String(localized: "Title"), start: seconds, end: min(seconds + 3, max(duration, seconds + 3)))
        change { $0.titles.append(title) }
        selectedTitle = title.id
        return title.id
    }

    func setTitle(_ id: UUID, record: Bool = true, _ body: @escaping (inout ProjectTitle) -> Void) {
        guard let index = project.titles.firstIndex(where: { $0.id == id }) else { return }
        if record { change { body(&$0.titles[index]) } } else { body(&project.titles[index]); ProjectStore.save(project) }
    }

    func removeTitle(_ id: UUID) {
        change { $0.titles.removeAll { $0.id == id } }
        if selectedTitle == id { selectedTitle = nil }
    }

    // MARK: - Subtitles

    /// The subtitles now (kept until the project changes: the transcripts are read once).
    @ObservationIgnored private var subtitleCache: (project: Project, lines: [ProjectSubtitle])?

    var subtitles: [ProjectSubtitle] {
        if let cache = subtitleCache, cache.project.clips == project.clips, cache.project.subtitleEdits == project.subtitleEdits,
           cache.project.subtitleLanguage == project.subtitleLanguage {
            return cache.lines
        }
        let lines = project.subtitles()
        subtitleCache = (project, lines)
        return lines
    }

    func subtitle(at seconds: Double) -> ProjectSubtitle? {
        subtitles.first { $0.start <= seconds && seconds < $0.end }
    }

    /// Transcripts changed (made, renamed speakers, fixed names): read again.
    func transcriptsChanged() { subtitleCache = nil }

    func setSubtitles(on: Bool) { change { $0.subtitlesOn = on } }

    func editSubtitle(_ key: String, text: String?) {
        change { project in
            var edits = project.subtitleEdits ?? [:]
            edits[key] = text
            project.subtitleEdits = edits.isEmpty ? nil : edits
        }
    }

    func setSubtitleStyle(_ style: SubtitleStyle) {
        project.subtitleStyle = style
        ProjectStore.save(project)
    }

    func setSubtitleLanguage(_ language: String) {
        change { $0.subtitleLanguage = language.isEmpty ? nil : language }
    }

    func setTitleStyle(_ style: SubtitleStyle) {
        project.titleStyle = style
        ProjectStore.save(project)
    }

    /// Saves changes made a little at a time (a drag), as one step to undo.
    func commit(from before: Project) {
        history.append(before)
        future = []
        project.modified = .now
        ProjectStore.save(project)
        rebuild()
    }

    func title(at seconds: Double) -> ProjectTitle? {
        project.titles.first { $0.start <= seconds && seconds < $0.end }
    }

    // MARK: - Playing

    func togglePlay() {
        if isPlaying { player.pause() } else {
            if time >= duration - 0.05 { seek(to: 0) }
            player.play()
        }
        rate = player.rate
    }

    func seek(to seconds: Double) {
        let target = min(max(seconds, 0), duration)
        time = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(frames: Int) {
        player.pause()
        seek(to: time + Double(frames) * frame)
    }

    func timecode(_ seconds: Double) -> String {
        let fps = max(Int(frameRate.rounded()), 1)
        let total = Int((seconds * Double(fps)).rounded())
        let f = total % fps, s = total / fps % 60, m = total / fps / 60 % 60, h = total / fps / 3600
        return h > 0 ? String(format: "%d:%02d:%02d:%02d", h, m, s, f) : String(format: "%02d:%02d:%02d", m, s, f)
    }

    /// Snaps to clip edges and the playhead when close.
    func snapped(_ seconds: Double, tolerance: Double) -> Double {
        guard snapping else { return seconds }
        let edges = offsets + [duration, time]
        return edges.min { abs($0 - seconds) < abs($1 - seconds) }.flatMap { abs($0 - seconds) <= tolerance ? $0 : nil } ?? seconds
    }

    // MARK: - The composition

    private func rebuildSoon() {
        rebuildTask?.cancel()
        rebuildTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await build()
        }
    }

    private func rebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { await build() }
    }

    private func build() async {
        let clips = project.clips, music = project.music
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }
        let voice = AVMutableAudioMixInputParameters(track: audio)
        var cursor = CMTime.zero
        var firstSize: CGSize?
        // Where each clip is on the timeline, and how it looks.
        var looks: [(start: Double, end: Double, look: ClipLook?)] = []
        for clip in clips {
            let asset = AVURLAsset(url: await playableURL(for: clip.file))
            let source = CMTimeRange(start: CMTime(seconds: clip.start, preferredTimescale: 600),
                                     duration: CMTime(seconds: max(clip.end - clip.start, 0), preferredTimescale: 600))
            let range = CMTimeRange(start: source.start, duration: CMTime(seconds: clip.length, preferredTimescale: 600))
            looks.append((cursor.seconds, cursor.seconds + clip.length, clip.look))
            if let track = try? await asset.loadTracks(withMediaType: .video).first {
                try? video.insertTimeRange(source, of: track, at: cursor)
                if clip.speed != 1 { video.scaleTimeRange(CMTimeRange(start: cursor, duration: source.duration), toDuration: range.duration) }
                if firstSize == nil, let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
                    let turned = size.applying(transform)
                    firstSize = CGSize(width: abs(turned.width), height: abs(turned.height))
                    if let fps = try? await track.load(.nominalFrameRate), fps > 0 { frameRate = Double(fps) }
                }
            } else {
                video.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: range.duration))
            }
            if let track = try? await asset.loadTracks(withMediaType: .audio).first {
                try? audio.insertTimeRange(source, of: track, at: cursor)
                if clip.speed != 1 { audio.scaleTimeRange(CMTimeRange(start: cursor, duration: source.duration), toDuration: range.duration) }
            } else if clip.speed != 1 {
                audio.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: range.duration))
            }
            // The clip's volume, faded in and out.
            let end = cursor + range.duration
            if clip.fadeIn > 0 {
                voice.setVolumeRamp(fromStartVolume: 0, toEndVolume: Float(clip.volume),
                                    timeRange: CMTimeRange(start: cursor, duration: CMTime(seconds: min(clip.fadeIn, clip.length), preferredTimescale: 600)))
            } else {
                voice.setVolume(Float(clip.volume), at: cursor)
            }
            if clip.fadeOut > 0 {
                let fade = CMTime(seconds: min(clip.fadeOut, clip.length), preferredTimescale: 600)
                voice.setVolumeRamp(fromStartVolume: Float(clip.volume), toEndVolume: 0, timeRange: CMTimeRange(start: end - fade, duration: fade))
            }
            cursor = end
        }
        var mixes = [voice]
        for song in music {
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let source = try? await AVURLAsset(url: await playableURL(for: URL(fileURLWithPath: song.path))).loadTracks(withMediaType: .audio).first else { continue }
            let length = min(song.length, max(project.duration - song.at, 0))
            guard length > 0 else { continue }
            let at = CMTime(seconds: song.at, preferredTimescale: 600)
            try? track.insertTimeRange(CMTimeRange(start: CMTime(seconds: song.start, preferredTimescale: 600), duration: CMTime(seconds: length, preferredTimescale: 600)), of: source, at: at)
            let params = AVMutableAudioMixInputParameters(track: track)
            params.setVolumeRamp(fromStartVolume: 0, toEndVolume: Float(song.volume),
                                 timeRange: CMTimeRange(start: at, duration: CMTime(seconds: max(min(song.fadeIn, length), 0.01), preferredTimescale: 600)))
            let fade = CMTime(seconds: max(min(song.fadeOut, length), 0.01), preferredTimescale: 600)
            params.setVolumeRamp(fromStartVolume: Float(song.volume), toEndVolume: 0,
                                 timeRange: CMTimeRange(start: at + CMTime(seconds: length, preferredTimescale: 600) - fade, duration: fade))
            mixes.append(params)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = mixes
        let size = firstSize ?? CGSize(width: 1920, height: 1080)
        renderSize = size

        let item = AVPlayerItem(asset: composition)
        item.audioMix = mix
        // Faster or slower clips keep their voices' pitch.
        item.audioTimePitchAlgorithm = .spectral
        if !clips.isEmpty, (try? await composition.loadTracks(withMediaType: .video).first) != nil {
            // Every clip fits the first one's frame, centred on black (different sizes and turned phones).
            // Each clip is placed as its look says (by default, fitted and centred).
            self.looks.replace(looks)
            let box = self.looks
            let videoComposition = try? await AVMutableVideoComposition.videoComposition(with: composition) { request in
                let (look, progress) = box.at(request.compositionTime.seconds)
                request.finish(with: ClipLook.place(request.sourceImage, look: look, progress: progress, in: size), context: nil)
            }
            if let videoComposition {
                videoComposition.renderSize = size
                videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(frameRate.rounded(), 1)))
                item.videoComposition = videoComposition
            }
        }
        guard !Task.isCancelled else { return }
        let keep = time, wasPlaying = isPlaying
        player.replaceCurrentItem(with: item)
        await player.seek(to: CMTime(seconds: min(keep, project.duration), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if wasPlaying { player.play() }
        await loadThumbnails()
    }

    /// The file itself, or a copy macOS can play (WebM, MKV), made once like the Editor does.
    private func playableURL(for file: URL) async -> URL {
        if let known = playable[file.path] { return known }
        var url = file
        let asset = AVURLAsset(url: file)
        if (try? await asset.load(.isPlayable)) != true, let manager = AppDelegate.shared?.manager,
           let ffmpeg = manager.tool("ffmpeg") {
            preparing = String(localized: "Making a copy Pluck can play…")
            let hasVideo = ((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty == false || Converting.isVideo(file)
            if let copy = await EditorModel.playableCopy(of: file, video: hasVideo, ffmpeg: ffmpeg) { url = copy }
            preparing = nil
        }
        playable[file.path] = url
        return url
    }

    func length(of file: URL) async -> Double {
        if let known = fileLengths[file.path] { return known }
        var seconds = (try? await AVURLAsset(url: file).load(.duration).seconds) ?? 0
        if !(seconds > 0), let ffprobe = AppDelegate.shared?.manager.tool("ffprobe"),
           let probe = await EditorModel.probe(file, ffprobe: ffprobe) {
            seconds = probe.duration
        }
        let value = seconds.isFinite ? max(seconds, 0) : 0
        fileLengths[file.path] = value
        return value
    }

    /// A few pictures per file, for the clips on the timeline.
    private func loadThumbnails() async {
        for clip in project.clips where thumbnails[clip.path] == nil {
            let file = await playableURL(for: clip.file)
            let length = await self.length(of: clip.file)
            let hasPicture = ((try? await AVURLAsset(url: file).loadTracks(withMediaType: .video)) ?? []).isEmpty == false
            guard length > 0, hasPicture else {
                thumbnails[clip.path] = []
                continue
            }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 200, height: 120)
            var images: [NSImage] = []
            for step in 0..<12 {
                let at = CMTime(seconds: length * (Double(step) + 0.5) / 12, preferredTimescale: 600)
                if let image = try? await generator.image(at: at).image { images.append(NSImage(cgImage: image, size: .zero)) }
            }
            thumbnails[clip.path] = images
        }
    }
}
