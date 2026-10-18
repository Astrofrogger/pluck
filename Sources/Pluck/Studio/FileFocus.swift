import AVFoundation
import Foundation

/// One file of a project, seen in its own time, for the transcript, subtitle and AI panels: the
/// playhead, cuts, the in and out points and subtitles carried to and from the timeline. Its
/// marks (chapters, cuts between shots, pauses, and what the AI finds) are found once per file.
@MainActor
@Observable
final class FileFocus: FileEditing {
    let file: URL
    @ObservationIgnored private weak var model: ProjectModel?
    private(set) var duration: Double
    private(set) var hasVideo: Bool
    var markers: [EditorMarker] = []
    var shownKinds: Set<EditorMarker.Kind> = [.chapter, .cut, .silence, .moment, .filler, .story]
    private(set) var analysing: String?
    var selectedSubtitle: UUID?
    let jobs = FileJobs()
    /// The last time in this file the playhead was at (it can be in another file's clip).
    @ObservationIgnored private var lastTime = 0.0

    private var path: String { file.path }

    init(path: String, model: ProjectModel) {
        file = URL(fileURLWithPath: path)
        self.model = model
        duration = model.project.clips.filter { $0.path == path }.map(\.end).max() ?? 0
        hasVideo = Converting.isVideo(URL(fileURLWithPath: path))
        Task { await load() }
    }

    private func load() async {
        if let model { duration = max(await model.length(of: file), duration) }
        let asset = AVURLAsset(url: file)
        if let tracks = try? await asset.loadTracks(withMediaType: .video) { hasVideo = !tracks.isEmpty }
        // Chapters, then pauses, then the cuts between shots (the slowest), each as it's found.
        let manager = AppDelegate.shared?.manager
        if let ffprobe = manager?.tool("ffprobe") { markers += await EditorAnalysis.chapters(in: file, ffprobe: ffprobe) }
        guard let ffmpeg = manager?.tool("ffmpeg") else { return }
        analysing = String(localized: "Finding pauses…")
        markers += await EditorAnalysis.silences(in: file, ffmpeg: ffmpeg)
        if hasVideo {
            analysing = String(localized: "Finding cuts…")
            markers += await EditorAnalysis.cuts(in: file, ffmpeg: ffmpeg)
        }
        analysing = nil
    }

    // MARK: - Time

    var time: Double {
        guard let model, let here = model.fileTime(at: model.time), here.path == path else { return lastTime }
        lastTime = here.time
        return here.time
    }

    var isPlaying: Bool { model?.isPlaying ?? false }
    var frame: Double { 1 / max(model?.frameRate ?? 25, 1) }

    func snappedToFrame(_ seconds: Double) -> Double { (seconds / frame).rounded() * frame }

    /// To that moment of the file on the timeline, or where the edit goes on from it when that
    /// part was taken out.
    func seek(to seconds: Double) {
        guard let model else { return }
        lastTime = seconds
        if let at = timeline(seconds) { model.seek(to: at) }
    }

    /// Where a moment of the file is on the timeline (the first place it's used), or where the
    /// next part of the file that's kept starts.
    private func timeline(_ seconds: Double) -> Double? {
        guard let model else { return nil }
        if let at = model.timelineTimes(of: seconds, in: path).first { return at }
        let next = model.coverage(path).first { $0.lowerBound >= seconds }
        return next.flatMap { model.timelineTimes(of: $0.lowerBound, in: path).first }
    }

    // MARK: - What's kept

    func cutOut(_ spans: [ClosedRange<Double>]) { model?.cutOut(path, spans) }
    func toggleOut(_ span: ClosedRange<Double>) { model?.toggle(path, span) }
    func resetEdit() {
        guard let model else { return }
        model.keepOnly(path, [0...max(duration, 0.1)])
    }
    func isOut(_ seconds: Double) -> Bool { !(model?.covers(path, seconds) ?? true) }

    // MARK: - In and out, in the file's time

    var inPoint: Double? {
        get { model?.project.inPoint.flatMap { model?.fileTime(at: $0) }.flatMap { $0.path == path ? $0.time : nil } }
        set {
            guard let model else { return }
            if let newValue, let at = timeline(newValue) { model.markIn(at) } else if newValue == nil { model.clearIn() }
        }
    }

    var outPoint: Double? {
        get { model?.project.outPoint.flatMap { model?.fileTime(at: max($0 - 0.0001, 0)) }.flatMap { $0.path == path ? $0.time : nil } }
        set {
            guard let model else { return }
            if let newValue, let at = model.timelineTimes(of: max(newValue - 0.0001, 0), in: path).first { model.markOut(at + 0.0001) } else if newValue == nil { model.clearOut() }
        }
    }

    var hasRange: Bool { inPoint != nil || outPoint != nil }
    var rangeStart: Double { inPoint ?? 0 }
    var rangeEnd: Double { outPoint ?? duration }

    // MARK: - Marks

    func replaceMarkers(_ kind: EditorMarker.Kind, with new: [EditorMarker]) {
        markers.removeAll { $0.kind == kind }
        markers += new
        shownKinds.insert(kind)
    }

    func select(_ marker: EditorMarker) {
        let end = marker.end ?? markers.filter { $0.kind == marker.kind && $0.start > marker.start }.map(\.start).min() ?? duration
        inPoint = snappedToFrame(marker.start)
        outPoint = snappedToFrame(end)
        seek(to: marker.start)
    }

    // MARK: - Subtitles

    /// The file's lines: those written or timed by hand, else none yet (the panel makes them
    /// from the transcript).
    var subtitles: [SubtitleCue] {
        get { model?.project.fileSubtitles?[path] ?? [] }
        set { model?.setFileSubtitles(path, newValue, record: false) }
    }

    func saveSubtitles() {
        guard let model else { return }
        model.setFileSubtitles(path, subtitles, record: true)
    }

    var subtitleStyle: SubtitleStyle {
        get { model?.project.subtitleLook ?? SubtitleStyle() }
        set { model?.setSubtitleStyle(newValue) }
    }

    var showSubtitles: Bool {
        get { model?.project.subtitlesOn == true }
        set { model?.setSubtitles(on: newValue) }
    }
}

extension ProjectModel {
    /// The file a panel works on: the clip at the playhead's, or the project's own file.
    var focusedPath: String? {
        if let id = selected.first, let clip = project.clips.first(where: { $0.id == id }) { return clip.path }
        return fileTime(at: time)?.path ?? project.origin ?? project.clips.first?.path
    }
}
