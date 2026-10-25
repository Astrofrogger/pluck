import Foundation

/// Trims that keep the edit's length: a roll moves a cut between two clips, a slip shows another
/// part of a clip's file in the same place. Times are timeline seconds, moved in whole frames, and
/// never past the media's ends.
enum TrimMath {
    /// The cut after `left` moved by `delta`: the left clip ends later, the right one starts later.
    /// Returns both clips and how far the cut really moved.
    static func roll(left: ProjectClip, right: ProjectClip, by delta: Double, leftFileLength: Double, frame: Double)
        -> (left: ProjectClip, right: ProjectClip, moved: Double) {
        let wanted = frames(delta, frame)
        let later = min((leftFileLength - left.end) / left.speed, right.length - frame)
        let earlier = max(-(left.length - frame), -right.start / right.speed)
        let moved = min(max(wanted, earlier), max(later, 0))
        var left = left, right = right
        left.end += moved * left.speed
        right.start += moved * right.speed
        return (left, right, moved)
    }

    /// The clip showing its file `delta` later (earlier when negative), at the same length.
    static func slip(_ clip: ProjectClip, by delta: Double, fileLength: Double) -> ProjectClip {
        let moved = min(max(delta * clip.speed, -clip.start), max(fileLength - clip.end, 0))
        var clip = clip
        clip.start += moved
        clip.end += moved
        return clip
    }

    /// A time rounded to whole frames.
    static func frames(_ seconds: Double, _ frame: Double) -> Double {
        frame > 0 ? (seconds / frame).rounded() * frame : seconds
    }
}

extension ProjectModel {
    /// Rolls the cut after clip `index` by `delta` from where it was in `before` (a drag's start).
    func roll(cutAfter index: Int, from before: Project, by delta: Double, record: Bool) {
        guard index >= 0, index + 1 < before.clips.count else { return }
        let left = before.clips[index], right = before.clips[index + 1]
        let rolled = TrimMath.roll(left: left, right: right, by: delta, leftFileLength: fileLengths[left.path] ?? left.end, frame: frame)
        replace([rolled.left, rolled.right], record: record)
    }

    /// Slips a clip by `delta` (timeline seconds; later in its file when positive) from where it
    /// was in `before`.
    func slip(_ id: UUID, from before: Project, by delta: Double, record: Bool) {
        guard let clip = before.clips.first(where: { $0.id == id }) else { return }
        let fileLength = fileLengths[clip.path] ?? clip.end
        replace([TrimMath.slip(clip, by: TrimMath.frames(delta, frame), fileLength: fileLength)], record: record)
    }

    /// Cuts the main-line clip under the playhead at the playhead, keeping its end. The clips after
    /// it move up, and the playhead goes to the cut (the clip's new start).
    func trimStartToPlayhead() {
        guard let (index, into) = clip(at: time) else { return }
        let cut = TrimMath.frames(into, frame)
        let old = project.clips[index]
        guard cut >= frame, cut <= old.length - frame else { return }
        let at = offsets[index]
        change { project in var clip = old; clip.start += cut * old.speed; project.setClip(clip) }
        seek(to: at)
    }

    /// Cuts the main-line clip under the playhead at the playhead, keeping its start. The clips
    /// after it move up, and the playhead stays at the cut (the clip's new end).
    func trimEndToPlayhead() {
        guard let (index, into) = clip(at: time) else { return }
        let cut = TrimMath.frames(into, frame)
        let old = project.clips[index]
        guard cut >= frame, cut <= old.length - frame else { return }
        let at = time
        change { project in var clip = old; clip.end = old.start + cut * old.speed; project.setClip(clip) }
        seek(to: at)
    }

    /// Moves the selected track items, songs and titles by whole frames (later when positive),
    /// never before the timeline's start. Main-line clips can't move. Returns false when none of
    /// `ids` is one of those, so the key can do something else.
    @discardableResult
    func nudge(_ ids: Set<UUID>, frames: Int) -> Bool {
        let movable = Set((project.tracks ?? []).flatMap(\.items).map(\.id))
            .union(project.music.map(\.id)).union(project.titles.map(\.id))
        guard !ids.intersection(movable).isEmpty else { return false }
        let shift = Double(frames) * frame
        change { project in
            project.tracks = project.tracks?.map { track in
                // A locked lane stays put, as when dragging.
                guard !track.locked else { return track }
                var track = track
                track.items = track.items.map { item in
                    guard ids.contains(item.id) else { return item }
                    var item = item
                    item.at = max((item.at ?? 0) + shift, 0)
                    // Moved on its own, as dragging it does (else it'd follow its clip back).
                    item.link = nil
                    return item
                }
                return track
            }
            project.music = project.music.map { song in
                guard ids.contains(song.id) else { return song }
                var song = song
                song.at = max(song.at + shift, 0)
                return song
            }
            project.titles = project.titles.map { title in
                guard ids.contains(title.id) else { return title }
                var title = title
                let start = max(title.start + shift, 0)
                title.end += start - title.start
                title.start = start
                return title
            }
        }
        return true
    }
}
