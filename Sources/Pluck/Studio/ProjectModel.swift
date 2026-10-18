import AVFoundation
import CoreImage
import SwiftUI
import Vision

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
    /// A dip to black or white at its end (into the next clip).
    var dipOut: ProjectDip?

    var speed: Double { look?.speed ?? 1 }
    /// How long it lasts on the timeline (its part of the file, at its speed).
    var length: Double { max(end - start, 0) / speed }
    var file: URL { URL(fileURLWithPath: path) }
    var name: String { title ?? file.deletingPathExtension().lastPathComponent }
}

extension ProjectClip {
    // Saved before a field existed: it keeps its default (projects never vanish after an update).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        id = value(.id, UUID()); path = try c.decode(String.self, forKey: .path)
        start = value(.start, 0); end = value(.end, 0); volume = value(.volume, 1); fadeIn = value(.fadeIn, 0); fadeOut = value(.fadeOut, 0)
        title = value(.title, nil as String?); role = value(.role, nil as StoryBeat.Role?); look = value(.look, nil as ClipLook?)
        dipOut = value(.dipOut, nil as ProjectDip?)
    }
}

/// A dip at an edit: the picture fades to a colour and back up into the next clip, half on each
/// side (the timing stays as it is).
struct ProjectDip: Codable, Hashable, Sendable {
    var white = false
    var length = 0.8

    /// How far into the colour the picture is (0…1) this far into a clip of this length, given the
    /// dips at its start and end.
    static func amount(at t: Double, length: Double, dipIn: ProjectDip?, dipOut: ProjectDip?) -> (Double, Bool)? {
        if let dipOut {
            let half = min(dipOut.length / 2, length / 2)
            if half > 0, t > length - half { return (min((t - (length - half)) / half, 1), dipOut.white) }
        }
        if let dipIn {
            let half = min(dipIn.length / 2, length / 2)
            if half > 0, t < half { return (max(1 - t / half, 0), dipIn.white) }
        }
        return nil
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

extension ProjectMusic {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        id = value(.id, UUID()); path = try c.decode(String.self, forKey: .path)
        at = value(.at, 0); start = value(.start, 0); end = value(.end, 0)
        volume = value(.volume, 0.35); fadeIn = value(.fadeIn, 1); fadeOut = value(.fadeOut, 2)
    }
}

/// Words on the picture for a while: a title, a name, a caption.
struct ProjectTitle: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var start: Double
    var end: Double
}

extension ProjectTitle {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        start = (try? c.decodeIfPresent(Double.self, forKey: .start)) ?? 0
        end = (try? c.decodeIfPresent(Double.self, forKey: .end)) ?? 0
    }
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
    /// The frame's shape when it isn't the clips' own ("9:16", "1:1", "4:5").
    var aspect: String?
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

extension Project {
    // Saved before a field existed: it keeps its default. A clip or title that can't be read is
    // left out rather than losing the whole project.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        func list<T: Decodable>(_ key: CodingKeys) -> [T] {
            (try? c.decodeIfPresent([Lenient<T>].self, forKey: key))?.compactMap(\.value) ?? []
        }
        id = value(.id, UUID()); name = value(.name, String(localized: "Project")); folder = value(.folder, nil as UUID?)
        created = value(.created, Date.now); modified = value(.modified, Date.now)
        clips = list(.clips); media = value(.media, nil as [String]?); music = list(.music); titles = list(.titles)
        subtitlesOn = value(.subtitlesOn, nil as Bool?); subtitleEdits = value(.subtitleEdits, nil as [String: String]?)
        subtitleStyle = value(.subtitleStyle, nil as SubtitleStyle?); subtitleLanguage = value(.subtitleLanguage, nil as String?)
        aspect = value(.aspect, nil as String?)
        if let style = value(.titleStyle, nil as SubtitleStyle?) { titleStyle = style }
    }
}

/// A fade in and out over a length, never overlapping (shared out when they'd add up to more).
func fades(_ fadeIn: Double, _ fadeOut: Double, over length: Double) -> (in: Double, out: Double) {
    let a = min(max(fadeIn, 0), length), b = min(max(fadeOut, 0), length)
    guard a + b > length, a + b > 0 else { return (a, b) }
    return (length * a / (a + b), length * b / (a + b))
}

/// One item of a list that may not read (it's then nil, and the rest still do).
private struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
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

    /// The project, or nil. A file that can't be read at all is put aside (".broken") rather than
    /// left to vanish from the list without a trace.
    static func load(_ id: UUID) -> Project? {
        let file = url(for: id)
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Project.self, from: data)
        } catch {
            let aside = file.appendingPathExtension("broken")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: file, to: aside)
            return nil
        }
    }

    /// Writes the project (atomic: the last good file stays until the new one is complete).
    static func write(_ project: Project) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(project).write(to: url(for: project.id), options: .atomic)
    }

    static func save(_ project: Project) { try? write(project) }

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
    /// Each file's picture size (turned upright), for the viewer's on-screen controls.
    var pictureSizes: [String: CGSize] = [:]

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
    /// The files the project uses that aren't there (moved, or on a drive that isn't connected).
    private(set) var missing: Set<String> = []
    /// Each file's sound as peaks across the whole file (by path), for the clips' waveforms.
    private(set) var peaks: [String: [Float]] = [:]
    @ObservationIgnored private var loadingPeaks: Set<String> = []
    /// Each song's beats and bars (by path), found in the background.
    private(set) var beatMaps: [String: MusicMap] = [:]
    @ObservationIgnored private var findingBeats: Set<String> = []

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
        // A drive connected or gone, or back from another app: look for the files again.
        let center = NSWorkspace.shared.notificationCenter
        driveObservers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkMissing() }
            }
        }
        driveObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMissing() }
        })
        // Whatever's waiting is written when Pluck quits.
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    @ObservationIgnored private var quitObserver: Any?
    @ObservationIgnored private var driveObservers: [Any] = []

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
        flush()
        if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
        quitObserver = nil
        for observer in driveObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        driveObservers = []
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
        save()
        rebuild()
    }

    func undo() {
        guard let last = history.popLast() else { return }
        future.append(project)
        project = last
        save()
        rebuild()
    }

    func redo() {
        guard let next = future.popLast() else { return }
        history.append(project)
        project = next
        save()
        rebuild()
    }

    func rename(_ name: String) {
        project.name = name
        save()
    }

    func file(in folder: UUID?) {
        project.folder = folder
        save()
    }

    // MARK: - Saving

    /// Why the last save didn't work (shown in the project), nil when it did.
    private(set) var saveProblem: String?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Saves a moment later (a drag is one write), or straight away with `now`.
    func save(now: Bool = false) {
        saveTask?.cancel()
        guard !now else { flush(); return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Writes what's waiting now (on closing, and when Pluck quits).
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        do {
            try ProjectStore.write(project)
            saveProblem = nil
        } catch {
            saveProblem = String(localized: "The project couldn’t be saved: \(error.localizedDescription)")
        }
    }

    /// Adds whole files at the end (or at a place in the line of clips).
    func add(_ files: [URL], at index: Int? = nil) async {
        var clips: [ProjectClip] = []
        for file in files where EditorTarget.canOpen(file) {
            let length = await self.length(of: file)
            guard length > 0 else { continue }
            // A moment (a search hit): "#t=start,end" on the file's URL, as media fragments do.
            if let span = Self.fragmentRange(file), span.lowerBound < length {
                clips.append(ProjectClip(path: file.path, start: span.lowerBound, end: min(span.upperBound, length)))
            } else {
                clips.append(ProjectClip(path: file.path, start: 0, end: length))
            }
        }
        guard !clips.isEmpty else { return }
        change { project in
            let at = min(index ?? project.clips.count, project.clips.count)
            project.clips.insert(contentsOf: clips, at: at)
            project.media = project.files
        }
    }

    /// The stretch a URL points at ("…/file.mov#t=12.5,18"), if it does.
    nonisolated static func fragmentRange(_ url: URL) -> ClosedRange<Double>? {
        guard let fragment = url.fragment, fragment.hasPrefix("t=") else { return nil }
        let times = fragment.dropFirst(2).split(separator: ",").compactMap { Double($0) }
        guard times.count == 2, times[1] > times[0], times[0] >= 0 else { return nil }
        return times[0]...times[1]
    }

    /// A file's URL pointing at a stretch of it, to drag onto a project.
    nonisolated static func moment(_ path: String, _ span: ClosedRange<Double>) -> URL {
        let file = URL(fileURLWithPath: path)
        return URL(string: file.absoluteString + String(format: "#t=%.3f,%.3f", span.lowerBound, span.upperBound)) ?? file
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
            if record { save() }
            looks.set(index, new.look)
            redraw()
            return
        }
        if record { change { body(&$0.clips[index]) } } else { body(&project.clips[index]); rebuildSoon() }
    }

    /// The looks the picture is drawn with, read while it plays (so a change shows at once).
    final class Looks: @unchecked Sendable {
        private var entries: [(start: Double, end: Double, look: ClipLook?)] = []
        /// Each clip's dips: from the clip before it, and its own.
        private var dips: [(in: ProjectDip?, out: ProjectDip?)] = []
        private let lock = NSLock()

        func replace(_ new: [(start: Double, end: Double, look: ClipLook?)], dips: [(in: ProjectDip?, out: ProjectDip?)] = []) {
            lock.lock(); entries = new; self.dips = dips; lock.unlock()
        }

        /// How far into a dip's colour the picture is at a time, if it's in one.
        func dip(_ seconds: Double) -> (amount: Double, white: Bool)? {
            lock.lock(); defer { lock.unlock() }
            guard let index = entries.lastIndex(where: { $0.start <= seconds + 0.0005 }), dips.indices.contains(index) else { return nil }
            let entry = entries[index]
            return ProjectDip.amount(at: seconds - entry.start, length: entry.end - entry.start, dipIn: dips[index].in, dipOut: dips[index].out)
                .map { ($0.0, $0.1) }
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
        if record { change { body(&$0.titles[index]) } } else { body(&project.titles[index]); save() }
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
        save()
    }

    func setSubtitleLanguage(_ language: String) {
        change { $0.subtitleLanguage = language.isEmpty ? nil : language }
    }

    func setTitleStyle(_ style: SubtitleStyle) {
        project.titleStyle = style
        save()
    }

    /// Saves changes made a little at a time (a drag), as one step to undo.
    func commit(from before: Project) {
        history.append(before)
        future = []
        project.modified = .now
        save()
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

    /// J K L, as in the Editor: faster each press, K stops.
    func shuttle(_ direction: Int) {
        guard direction != 0 else { player.pause(); rate = 0; return }
        let current = player.rate
        let next: Float = direction > 0 ? (current > 0 ? min(current * 2, 8) : 1) : (current < 0 ? max(current * 2, -8) : -1)
        // Not every composition plays backwards: then a second back at a time.
        if next < 0, player.currentItem?.canPlayReverse != true {
            player.pause()
            seek(to: time - 1)
            rate = 0
            return
        }
        player.rate = next
        rate = next
    }

    /// The edit (a cut between clips) before or after the playhead.
    func jumpToEdit(forward: Bool) {
        player.pause()
        let edits = offsets + [duration]
        let target = forward ? edits.first { $0 > time + frame / 2 } : edits.last { $0 < time - frame / 2 }
        seek(to: target ?? (forward ? duration : 0))
    }

    func timecode(_ seconds: Double) -> String {
        // Frames counted at the real rate (29.97 has 29.97 a second), labelled in whole seconds
        // of the nominal rate, as non-drop timecode is.
        let fps = max(Int(frameRate.rounded()), 1)
        let total = Int((seconds * max(frameRate, 1)).rounded())
        let f = total % fps, s = total / fps % 60, m = total / fps / 60 % 60, h = total / fps / 3600
        return h > 0 ? String(format: "%d:%02d:%02d:%02d", h, m, s, f) : String(format: "%02d:%02d:%02d", m, s, f)
    }

    /// Snaps to clip edges, the playhead and the music's beats when close.
    func snapped(_ seconds: Double, tolerance: Double) -> Double {
        guard snapping else { return seconds }
        let edges = offsets + [duration, time] + timelineBeats.map(\.time)
        return edges.min { abs($0 - seconds) < abs($1 - seconds) }.flatMap { abs($0 - seconds) <= tolerance ? $0 : nil } ?? seconds
    }

    /// Snaps a moving cut to the music's beats and the playhead (not to clip edges, which move
    /// with it).
    func snappedToBeat(_ seconds: Double, tolerance: Double) -> Double {
        guard snapping else { return seconds }
        let marks = timelineBeats.map(\.time) + [time]
        return marks.min { abs($0 - seconds) < abs($1 - seconds) }.flatMap { abs($0 - seconds) <= tolerance ? $0 : nil } ?? seconds
    }

    // MARK: - Frame shape

    /// The shapes a project can have besides its clips' own.
    static let aspects = ["9:16", "1:1", "4:5"]

    /// The frame for a shape: as sharp as the clips' short side allows (1080 × 1920 from HD).
    nonisolated static func frame(_ source: CGSize, aspect: String?) -> CGSize {
        let parts = (aspect ?? "").split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return source }
        let short = Double(min(source.width, source.height))
        let width = parts[0] <= parts[1] ? short : short * parts[0] / parts[1]
        let height = parts[0] <= parts[1] ? short * parts[1] / parts[0] : short
        return CGSize(width: (width / 2).rounded() * 2, height: (height / 2).rounded() * 2)
    }

    /// Changes the frame's shape and frames every clip for it (filled, on its face, person or main
    /// subject); one undo step. Clips placed by hand keep their place.
    func setAspect(_ aspect: String?) async {
        let source = pictureSizes[project.clips.first?.path ?? ""] ?? renderSize
        let size = Self.frame(source, aspect: aspect)
        var placed: [UUID: ClipLook] = [:]
        if aspect != nil {
            for clip in project.clips where clip.look == nil || clip.look?.reframed == true || clip.look == ClipLook() {
                guard let picture = pictureSizes[clip.path], picture.width > 0 else { continue }
                let subject = await Self.subject(in: clip)
                var look = clip.look ?? ClipLook()
                look.scaling = .fill
                // The subject (0…1 across the picture) in the middle of the frame, never past an edge.
                let scale = max(size.width / picture.width, size.height / picture.height)
                let shown = picture.width * scale
                let room = max((shown - size.width) / 2 / size.width, 0)
                look.x = min(max(-(subject - 0.5) * shown / size.width, -room), room)
                look.reframed = true
                placed[clip.id] = look
            }
        }
        change { project in
            project.aspect = aspect
            for index in project.clips.indices {
                if let look = placed[project.clips[index].id] {
                    project.clips[index].look = look
                } else if aspect == nil, project.clips[index].look?.reframed == true {
                    // Back to the clips' own shape: as it was before.
                    project.clips[index].look = nil
                }
            }
        }
    }

    /// Where the clip's subject is across the picture (0 left … 1 right): faces, then people, then
    /// what draws the eye, at three moments of the clip.
    nonisolated private static func subject(in clip: ProjectClip) async -> Double {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip.file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        var found: [Double] = []
        for share in [0.2, 0.5, 0.8] {
            let at = CMTime(seconds: clip.start + (clip.end - clip.start) * share, preferredTimescale: 600)
            guard let image = try? await generator.image(at: at).image else { continue }
            let handler = VNImageRequestHandler(cgImage: image)
            let faces = VNDetectFaceRectanglesRequest(), people = VNDetectHumanRectanglesRequest()
            let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
            try? handler.perform([faces, people, saliency])
            if let face = faces.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
                found.append(face.boundingBox.midX)
            } else if let person = people.results?.filter({ $0.confidence > 0.5 }).max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
                found.append(person.boundingBox.midX)
            } else if let object = (saliency.results?.first)?.salientObjects?.first {
                found.append(object.boundingBox.midX)
            }
        }
        return found.isEmpty ? 0.5 : found.sorted()[found.count / 2]
    }

    // MARK: - Beats

    /// The songs' beats where they fall on the timeline (bars marked), in order.
    var timelineBeats: [(time: Double, bar: Bool)] {
        var all: [(time: Double, bar: Bool)] = []
        for song in project.music {
            guard let map = beatMaps[song.path] else { continue }
            let bars = Set(map.bars.map { ($0.start * 100).rounded() })
            for beat in map.beats where beat >= song.start && beat <= song.end {
                let time = song.at + beat - song.start
                if time >= 0, time <= duration { all.append((time, bars.contains((beat * 100).rounded()))) }
            }
        }
        return all.sorted { $0.time < $1.time }
    }

    /// Finds the beats of songs not looked at yet.
    private func findBeats() {
        guard let ffmpeg = AppDelegate.shared?.manager.tool("ffmpeg") else { return }
        for path in Set(project.music.map(\.path)) where beatMaps[path] == nil && !findingBeats.contains(path) && !missing.contains(path) {
            findingBeats.insert(path)
            Task {
                let map = await Task.detached(priority: .utility) { () -> MusicMap? in
                    guard let samples = try? await AudioFeatures.samples(of: URL(fileURLWithPath: path), ffmpeg: ffmpeg) else { return nil }
                    let features = AudioFeatures(samples: samples)
                    // Most music, not only dance tempos.
                    let map = MusicMap(features: features, tempoRange: 70...180)
                    return map.beats.count >= 8 ? map : nil
                }.value
                findingBeats.remove(path)
                if let map { beatMaps[path] = map }
            }
        }
    }

    /// Moves every cut between clips onto the nearest bar (or beat) of the music, trimming the clip
    /// before it; one undo step. How many cuts moved.
    @discardableResult
    func fitToBeat() -> Int {
        let beats = timelineBeats
        guard beats.count >= 4, project.clips.count >= 2 else { return 0 }
        let gaps = zip(beats.dropFirst(), beats).map { $0.time - $1.time }.sorted()
        let period = gaps[gaps.count / 2]
        var moved = 0
        change { project in
            var at = 0.0
            for index in project.clips.indices.dropLast() {
                let clip = project.clips[index]
                let cut = at + clip.length
                // A bar within a beat, or else the nearest beat within half a beat.
                let bar = beats.filter { $0.bar && abs($0.time - cut) <= period }.min { abs($0.time - cut) < abs($1.time - cut) }
                let beat = beats.filter { abs($0.time - cut) <= period / 2 }.min { abs($0.time - cut) < abs($1.time - cut) }
                var target = (bar ?? beat)?.time ?? cut
                // Not longer than the file has, not shorter than half a second.
                let available = (fileLengths[clip.path] ?? clip.end)
                if clip.start + (target - at) * clip.speed > available + 0.001 || target - at < 0.5 { target = cut }
                if abs(target - cut) > 0.001 {
                    project.clips[index].end = clip.start + (target - at) * clip.speed
                    moved += 1
                }
                at = target
            }
        }
        return moved
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

    /// A file's asset and what's in it, loaded once (the picture is built again on every change).
    private struct Media {
        var asset: AVURLAsset
        var video: AVAssetTrack?
        var audio: AVAssetTrack?
        /// Upright.
        var size: CGSize?
        var fps: Double?
    }

    @ObservationIgnored private var media: [String: Media] = [:]

    private func loaded(_ url: URL) async -> Media {
        if let known = media[url.path] { return known }
        let asset = AVURLAsset(url: url)
        var found = Media(asset: asset)
        found.video = try? await asset.loadTracks(withMediaType: .video).first
        found.audio = try? await asset.loadTracks(withMediaType: .audio).first
        if let track = found.video, let natural = try? await track.load(.naturalSize), let turn = try? await track.load(.preferredTransform) {
            let turned = natural.applying(turn)
            found.size = CGSize(width: abs(turned.width), height: abs(turned.height))
            if let fps = try? await track.load(.nominalFrameRate), fps > 0 { found.fps = Double(fps) }
        }
        // Not kept while the file isn't there (it can come back).
        if FileManager.default.fileExists(atPath: url.path) { media[url.path] = found }
        return found
    }

    /// Builds the picture again (a steadied copy is ready, transcripts changed…), reading the
    /// files afresh.
    func refresh() {
        media = [:]
        rebuild()
    }

    private func rebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { await build() }
    }

    private func build() async {
        let clips = project.clips, music = project.music
        missing = Self.missingFiles(in: project)
        findBeats()
        loadPeaks()
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }
        let voice = AVMutableAudioMixInputParameters(track: audio)
        var cursor = CMTime.zero
        var firstSize: CGSize?
        // Where each clip is on the timeline, and how it looks.
        var looks: [(start: Double, end: Double, look: ClipLook?)] = []
        for clip in clips {
            // A newer change is building already.
            if Task.isCancelled { return }
            let main = await loaded(await playableURL(for: clip.file))
            // Stabilized: the picture from the steadied copy (same times), the sound as it was.
            var pictures = main
            if clip.look?.stabilize == true, let steadied = Stabilizer.copy(for: clip.path) { pictures = await loaded(steadied) }
            let source = CMTimeRange(start: CMTime(seconds: clip.start, preferredTimescale: 600),
                                     duration: CMTime(seconds: max(clip.end - clip.start, 0), preferredTimescale: 600))
            let range = CMTimeRange(start: source.start, duration: CMTime(seconds: clip.length, preferredTimescale: 600))
            looks.append((cursor.seconds, cursor.seconds + clip.length, clip.look))
            if let track = pictures.video {
                try? video.insertTimeRange(source, of: track, at: cursor)
                if let size = pictures.size { pictureSizes[clip.path] = size }
                if clip.speed != 1 { video.scaleTimeRange(CMTimeRange(start: cursor, duration: source.duration), toDuration: range.duration) }
                if firstSize == nil, let size = pictures.size {
                    firstSize = size
                    if let fps = pictures.fps { frameRate = fps }
                }
            } else {
                video.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: range.duration))
            }
            if let track = main.audio {
                try? audio.insertTimeRange(source, of: track, at: cursor)
                if clip.speed != 1 { audio.scaleTimeRange(CMTimeRange(start: cursor, duration: source.duration), toDuration: range.duration) }
            } else if clip.speed != 1 {
                audio.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: range.duration))
            }
            // The clip's volume, faded in and out.
            let end = cursor + range.duration
            let fade = fades(clip.fadeIn, clip.fadeOut, over: clip.length)
            if fade.in > 0 {
                voice.setVolumeRamp(fromStartVolume: 0, toEndVolume: Float(clip.volume),
                                    timeRange: CMTimeRange(start: cursor, duration: CMTime(seconds: fade.in, preferredTimescale: 600)))
            } else {
                voice.setVolume(Float(clip.volume), at: cursor)
            }
            if fade.out > 0 {
                let fade = CMTime(seconds: fade.out, preferredTimescale: 600)
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
            let songFade = fades(max(song.fadeIn, 0.01), max(song.fadeOut, 0.01), over: length)
            params.setVolumeRamp(fromStartVolume: 0, toEndVolume: Float(song.volume),
                                 timeRange: CMTimeRange(start: at, duration: CMTime(seconds: songFade.in, preferredTimescale: 600)))
            let fade = CMTime(seconds: songFade.out, preferredTimescale: 600)
            params.setVolumeRamp(fromStartVolume: Float(song.volume), toEndVolume: 0,
                                 timeRange: CMTimeRange(start: at + CMTime(seconds: length, preferredTimescale: 600) - fade, duration: fade))
            mixes.append(params)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = mixes
        let size = Self.frame(firstSize ?? CGSize(width: 1920, height: 1080), aspect: project.aspect)
        renderSize = size

        let item = AVPlayerItem(asset: composition)
        item.audioMix = mix
        // Faster or slower clips keep their voices' pitch.
        item.audioTimePitchAlgorithm = .spectral
        if !clips.isEmpty, (try? await composition.loadTracks(withMediaType: .video).first) != nil {
            // Every clip fits the first one's frame, centred on black (different sizes and turned phones).
            // Each clip is placed as its look says (by default, fitted and centred).
            let dips = clips.indices.map { (index: Int) -> (in: ProjectDip?, out: ProjectDip?) in
                (index > 0 ? clips[index - 1].dipOut : nil, clips[index].dipOut)
            }
            self.looks.replace(looks, dips: dips)
            let box = self.looks
            let videoComposition = try? await AVMutableVideoComposition.videoComposition(with: composition) { request in
                let seconds = request.compositionTime.seconds
                let (look, progress) = box.at(seconds)
                var picture = ClipLook.place(request.sourceImage, look: look, progress: progress, in: size)
                if let dip = box.dip(seconds) {
                    let colour = CIImage(color: dip.white ? .white : .black).cropped(to: picture.extent)
                    picture = picture.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: colour, kCIInputTimeKey: dip.amount])
                }
                request.finish(with: picture, context: nil)
            }
            if let videoComposition {
                videoComposition.renderSize = size
                videoComposition.frameDuration = EditorModel.frameDuration(frameRate)
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
        guard FileManager.default.fileExists(atPath: file.path) else { return file }
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
        // Not known while it's missing (not 0 for good).
        guard FileManager.default.fileExists(atPath: file.path) else { return 0 }
        var seconds = (try? await AVURLAsset(url: file).load(.duration).seconds) ?? 0
        if !(seconds > 0), let ffprobe = AppDelegate.shared?.manager.tool("ffprobe"),
           let probe = await EditorModel.probe(file, ffprobe: ffprobe) {
            seconds = probe.duration
        }
        let value = seconds.isFinite ? max(seconds, 0) : 0
        fileLengths[file.path] = value
        return value
    }

    // MARK: - Missing files

    nonisolated static func missingFiles(in project: Project) -> Set<String> {
        Set((project.clips.map(\.path) + project.music.map(\.path)).filter { !FileManager.default.fileExists(atPath: $0) })
    }

    /// Looks again for the missing files (a drive connected); plays them once they're back.
    func checkMissing() {
        let now = Self.missingFiles(in: project)
        guard now != missing else { return }
        missing = now
        rebuild()
    }

    /// Finds the missing files in a folder (and the folders in it): the same name, at least as long
    /// as the clips need. Undoable. How many were found.
    func relink(in folder: URL) async -> Int {
        let wanted = missing
        guard !wanted.isEmpty else { return 0 }
        let names = Set(wanted.map { ($0 as NSString).lastPathComponent.lowercased() })
        let candidates: [String: [URL]] = await Task.detached(priority: .userInitiated) {
            var found: [String: [URL]] = [:]
            let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = walker?.nextObject() as? URL {
                let name = url.lastPathComponent.lowercased()
                if names.contains(name) { found[name, default: []].append(url) }
            }
            return found
        }.value
        var moves: [String: String] = [:]
        for old in wanted {
            let need = (project.clips.filter { $0.path == old }.map(\.end) + project.music.filter { $0.path == old }.map(\.end)).max() ?? 0
            for url in candidates[(old as NSString).lastPathComponent.lowercased()] ?? [] {
                if await length(of: url) >= need - 0.1 {
                    moves[old] = url.path
                    break
                }
            }
        }
        guard !moves.isEmpty else { return 0 }
        change { project in
            for i in project.clips.indices { if let new = moves[project.clips[i].path] { project.clips[i].path = new } }
            for i in project.music.indices { if let new = moves[project.music[i].path] { project.music[i].path = new } }
        }
        return moves.count
    }

    /// Reads the sound of files not read yet.
    private func loadPeaks() {
        guard let ffmpeg = AppDelegate.shared?.manager.tool("ffmpeg") else { return }
        for path in Set(project.clips.map(\.path)) where peaks[path] == nil && !loadingPeaks.contains(path) && !missing.contains(path) {
            loadingPeaks.insert(path)
            Task {
                let length = await self.length(of: URL(fileURLWithPath: path))
                let found = await EditorModel.peaks(of: URL(fileURLWithPath: path), duration: length, ffmpeg: ffmpeg)
                loadingPeaks.remove(path)
                peaks[path] = found
            }
        }
    }

    /// A clip's part of its file's peaks.
    func peaks(for clip: ProjectClip) -> ArraySlice<Float> {
        guard let all = peaks[clip.path], !all.isEmpty, let length = fileLengths[clip.path], length > 0 else { return [] }
        let a = min(max(Int(clip.start / length * Double(all.count)), 0), all.count - 1)
        let b = min(max(Int((clip.end / length * Double(all.count)).rounded(.up)), a + 1), all.count)
        return all[a..<b]
    }

    /// The pictures for a clip: from its own part of the file (in steps of 2 seconds, so trimming
    /// doesn't make them again on every move).
    nonisolated static func thumbnailKey(_ clip: ProjectClip) -> String {
        let a = (clip.start / 2).rounded(.down) * 2, b = (clip.end / 2).rounded(.up) * 2
        return "\(clip.path)@\(a)-\(b)"
    }

    /// A few pictures per clip, for the timeline.
    private func loadThumbnails() async {
        for clip in project.clips where thumbnails[Self.thumbnailKey(clip)] == nil && !missing.contains(clip.path) {
            let key = Self.thumbnailKey(clip)
            let file = await playableURL(for: clip.file)
            let length = await self.length(of: clip.file)
            let hasPicture = ((try? await AVURLAsset(url: file).loadTracks(withMediaType: .video)) ?? []).isEmpty == false
            guard length > 0, hasPicture else {
                thumbnails[key] = []
                continue
            }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 200, height: 120)
            let from = max((clip.start / 2).rounded(.down) * 2, 0), to = min((clip.end / 2).rounded(.up) * 2, length)
            let count = min(max(Int((to - from) / 0.5), 1), 12)
            var images: [NSImage] = []
            for step in 0..<count {
                let at = CMTime(seconds: from + (to - from) * (Double(step) + 0.5) / Double(count), preferredTimescale: 600)
                if let image = try? await generator.image(at: at).image { images.append(NSImage(cgImage: image, size: .zero)) }
            }
            thumbnails[key] = images
        }
    }
}
