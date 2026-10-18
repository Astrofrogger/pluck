import Foundation

/// One file being edited, in its own time: what the transcript, subtitle and AI panels work on.
/// Basic Pluck's Editor is one; in Pluck Studio a file in a project is (`FileFocus`), its times
/// carried to and from the timeline.
@MainActor
protocol FileEditing: AnyObject, Observable {
    var file: URL { get }
    /// The file's length, and where the playhead is in it.
    var duration: Double { get }
    var time: Double { get }
    var isPlaying: Bool { get }
    var hasVideo: Bool { get }
    /// One frame's length.
    var frame: Double { get }
    func seek(to seconds: Double)
    func snappedToFrame(_ seconds: Double) -> Double

    // What's kept
    func cutOut(_ spans: [ClosedRange<Double>])
    func toggleOut(_ span: ClosedRange<Double>)
    func resetEdit()
    /// Taken out of the edit at this moment.
    func isOut(_ seconds: Double) -> Bool

    // The in and out points
    var inPoint: Double? { get set }
    var outPoint: Double? { get set }
    var hasRange: Bool { get }
    var rangeStart: Double { get }
    var rangeEnd: Double { get }

    // Marks: chapters, cuts, pauses, best moments, filler words, the story
    var markers: [EditorMarker] { get set }
    var shownKinds: Set<EditorMarker.Kind> { get set }
    var analysing: String? { get }
    func replaceMarkers(_ kind: EditorMarker.Kind, with new: [EditorMarker])
    /// Sets the range to a marker and goes there.
    func select(_ marker: EditorMarker)

    // Subtitles, in the file's time
    var subtitles: [SubtitleCue] { get set }
    var subtitleStyle: SubtitleStyle { get set }
    var showSubtitles: Bool { get set }
    var selectedSubtitle: UUID? { get set }
    func saveSubtitles()

    /// Local AI work running for the file.
    var jobs: FileJobs { get }
}

/// Local AI work running for a file, and what went wrong.
@MainActor
@Observable
final class FileJobs {
    var finding = false
    var problem: String?
    var findingSpeakers = false
    var speakerProblem: String?
    var findingStory = false
    var storyProgress = 0.0
    var storyProblem: String?
    var translating = false
    var translateProblem: String?
}

// MARK: - Subtitle lines (the same for every file being edited)

extension FileEditing {
    /// The subtitle on screen at a time.
    func subtitle(at seconds: Double) -> SubtitleCue? {
        subtitles.first { $0.start <= seconds && seconds < $0.end }
    }

    /// The shortest a line can last.
    static var shortestSubtitle: Double { 0.2 }

    private func neighbours(of id: UUID) -> (previous: SubtitleCue?, next: SubtitleCue?, index: Int)? {
        let sorted = subtitles.sorted { $0.start < $1.start }
        guard let index = sorted.firstIndex(where: { $0.id == id }) else { return nil }
        return (index > 0 ? sorted[index - 1] : nil, index + 1 < sorted.count ? sorted[index + 1] : nil,
                subtitles.firstIndex { $0.id == id } ?? 0)
    }

    /// Moves a line's start, never past the line before it or closer than a moment to its end.
    func setSubtitleStart(_ id: UUID, to seconds: Double) {
        guard let (previous, _, index) = neighbours(of: id) else { return }
        let low = previous?.end ?? 0
        subtitles[index].start = min(max(seconds, low), subtitles[index].end - Self.shortestSubtitle)
    }

    func setSubtitleEnd(_ id: UUID, to seconds: Double) {
        guard let (_, next, index) = neighbours(of: id) else { return }
        let high = next?.start ?? duration
        subtitles[index].end = max(min(seconds, high), subtitles[index].start + Self.shortestSubtitle)
    }

    /// Moves a whole line, keeping its length, between its neighbours.
    func moveSubtitle(_ id: UUID, toStart seconds: Double) {
        guard let (previous, next, index) = neighbours(of: id) else { return }
        let length = subtitles[index].end - subtitles[index].start
        let start = min(max(seconds, previous?.end ?? 0), (next?.start ?? duration) - length)
        subtitles[index].start = max(start, previous?.end ?? 0)
        subtitles[index].end = subtitles[index].start + length
    }

    /// A new line at the playhead, in the gap there (two seconds, or what fits).
    @discardableResult
    func addSubtitle(at seconds: Double) -> UUID? {
        let sorted = subtitles.sorted { $0.start < $1.start }
        if let current = sorted.first(where: { $0.start <= seconds && seconds < $0.end }) { return splitSubtitle(current.id, at: seconds) }
        let next = sorted.first { $0.start >= seconds }?.start ?? duration
        guard next - seconds >= Self.shortestSubtitle else { return nil }
        let cue = SubtitleCue(start: seconds, end: min(seconds + 2, next), text: String(localized: "New line"))
        subtitles.append(cue)
        subtitles.sort { $0.start < $1.start }
        selectedSubtitle = cue.id
        saveSubtitles()
        return cue.id
    }

    /// Splits a line at a time: the words are shared out by where the time falls.
    @discardableResult
    func splitSubtitle(_ id: UUID, at seconds: Double) -> UUID? {
        guard let index = subtitles.firstIndex(where: { $0.id == id }) else { return nil }
        let cue = subtitles[index]
        guard seconds - cue.start >= Self.shortestSubtitle, cue.end - seconds >= Self.shortestSubtitle else { return nil }
        let words = cue.text.replacingOccurrences(of: "\n", with: " ").split(separator: " ")
        let share = (seconds - cue.start) / (cue.end - cue.start)
        let cut = min(max(Int((Double(words.count) * share).rounded()), words.count > 1 ? 1 : 0), max(words.count - 1, 0))
        subtitles[index].end = seconds
        subtitles[index].text = words.count > 1 ? words[..<cut].joined(separator: " ") : cue.text
        let second = SubtitleCue(start: seconds, end: cue.end, text: words.count > 1 ? words[cut...].joined(separator: " ") : cue.text)
        subtitles.insert(second, at: index + 1)
        selectedSubtitle = second.id
        saveSubtitles()
        return second.id
    }

    /// Joins a line with the one after it.
    func mergeSubtitleWithNext(_ id: UUID) {
        guard let (_, next, index) = neighbours(of: id), let next, let nextIndex = subtitles.firstIndex(where: { $0.id == next.id }) else { return }
        subtitles[index].end = next.end
        subtitles[index].text += " " + next.text
        subtitles.remove(at: nextIndex)
        selectedSubtitle = id
        saveSubtitles()
    }

    func deleteSubtitle(_ id: UUID) {
        subtitles.removeAll { $0.id == id }
        if selectedSubtitle == id { selectedSubtitle = nil }
        saveSubtitles()
    }
}
