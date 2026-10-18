import Foundation

/// Editing by the file's own time: what the transcript, the AI tools and the Editor's cutting
/// speak in. A span of a file taken out comes out of every clip of that file that holds it (the
/// clips split around it); one put back goes in beside the part it continues. All undoable.
extension ProjectModel {
    /// The parts of a file on the timeline now (its own time), in order and joined up.
    func coverage(_ path: String) -> [ClosedRange<Double>] {
        let spans = project.clips.filter { $0.path == path && $0.freeze == nil }.map { $0.start...$0.end }.sorted { $0.lowerBound < $1.lowerBound }
        var joined: [ClosedRange<Double>] = []
        for span in spans {
            if let last = joined.last, span.lowerBound <= last.upperBound + 0.001 {
                joined[joined.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else {
                joined.append(span)
            }
        }
        return joined
    }

    /// Whether this moment of the file is on the timeline.
    func covers(_ path: String, _ seconds: Double) -> Bool {
        project.clips.contains { $0.path == path && $0.freeze == nil && $0.start <= seconds && seconds < $0.end }
    }

    /// Takes these stretches of the file out of the edit (filler words, pauses, words struck
    /// through).
    func cutOut(_ path: String, _ spans: [ClosedRange<Double>]) {
        let spans = spans.filter { $0.upperBound > $0.lowerBound }
        guard !spans.isEmpty else { return }
        change { project in
            project.clips = project.clips.flatMap { clip -> [ProjectClip] in
                guard clip.path == path, clip.freeze == nil else { return [clip] }
                let pieces = Self.subtract(spans, from: clip.start...clip.end).filter { $0.upperBound - $0.lowerBound >= 1.0 / 60 }
                return pieces.enumerated().map { index, piece in
                    var part = clip
                    if index > 0 { part.id = UUID() }
                    part.start = piece.lowerBound
                    part.end = piece.upperBound
                    // The fades stay at the ends of what was the clip.
                    if piece.lowerBound > clip.start { part.fadeIn = 0 }
                    if piece.upperBound < clip.end { part.fadeOut = 0; part.dipOut = nil }
                    return part
                }
            }
        }
    }

    /// Puts a stretch of the file back: beside the clip of the file it continues (or before the
    /// one it leads into), joined with it.
    func restore(_ path: String, _ span: ClosedRange<Double>) {
        let missing = Self.subtract(coverage(path), from: span)
        guard !missing.isEmpty else { return }
        change { project in
            for piece in missing {
                let clips = project.clips
                if let before = clips.firstIndex(where: { $0.path == path && $0.freeze == nil && abs($0.end - piece.lowerBound) < 0.002 }) {
                    project.clips[before].end = piece.upperBound
                } else if let after = clips.firstIndex(where: { $0.path == path && $0.freeze == nil && abs($0.start - piece.upperBound) < 0.002 }) {
                    project.clips[after].start = piece.lowerBound
                } else {
                    // After the last clip of the file that comes before it in the file.
                    let earlier = clips.lastIndex { $0.path == path && $0.end <= piece.lowerBound }
                    var clip = ProjectClip(path: path, start: piece.lowerBound, end: piece.upperBound)
                    if let template = clips.first(where: { $0.path == path }) { clip.look = template.look; clip.volume = template.volume }
                    project.clips.insert(clip, at: earlier.map { $0 + 1 } ?? (clips.firstIndex { $0.path == path } ?? clips.count))
                }
                // Clips of the file that now meet become one.
                var index = 0
                while index + 1 < project.clips.count {
                    let a = project.clips[index], b = project.clips[index + 1]
                    if a.path == path, b.path == path, a.freeze == nil, b.freeze == nil, abs(a.end - b.start) < 0.002, a.look == b.look, a.volume == b.volume {
                        project.clips[index].end = b.end
                        project.clips[index].fadeOut = b.fadeOut
                        project.clips[index].dipOut = b.dipOut
                        project.clips.remove(at: index + 1)
                    } else {
                        index += 1
                    }
                }
            }
        }
    }

    /// Takes a stretch out when it's in, puts it back when it's out.
    func toggle(_ path: String, _ span: ClosedRange<Double>) {
        if covers(path, (span.lowerBound + span.upperBound) / 2) { cutOut(path, [span]) } else { restore(path, span) }
    }

    /// Only these stretches of the file, in this order, where the file's clips were (the
    /// story, the best moments).
    func keepOnly(_ path: String, _ spans: [ClosedRange<Double>]) {
        let spans = spans.filter { $0.upperBound > $0.lowerBound }
        guard !spans.isEmpty else { return }
        change { project in
            let first = project.clips.firstIndex { $0.path == path } ?? project.clips.count
            let template = project.clips.first { $0.path == path }
            let before = project.clips[..<first].filter { $0.path != path }
            let after = project.clips[first...].filter { $0.path != path }
            let kept = spans.map { span -> ProjectClip in
                var clip = ProjectClip(path: path, start: span.lowerBound, end: span.upperBound)
                clip.look = template?.look
                clip.volume = template?.volume ?? 1
                return clip
            }
            project.clips = before + kept + after
        }
    }

    /// The whole file again, as one clip where its clips were.
    func resetFile(_ path: String) async {
        let length = await self.length(of: URL(fileURLWithPath: path))
        guard length > 0 else { return }
        keepOnly(path, [0...length])
    }

    /// Stretches of `range` not in `spans`.
    nonisolated static func subtract(_ spans: [ClosedRange<Double>], from range: ClosedRange<Double>) -> [ClosedRange<Double>] {
        var pieces = [range]
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            pieces = pieces.flatMap { piece -> [ClosedRange<Double>] in
                guard span.upperBound > piece.lowerBound, span.lowerBound < piece.upperBound else { return [piece] }
                var rest: [ClosedRange<Double>] = []
                if span.lowerBound > piece.lowerBound { rest.append(piece.lowerBound...span.lowerBound) }
                if span.upperBound < piece.upperBound { rest.append(span.upperBound...piece.upperBound) }
                return rest
            }
        }
        return pieces
    }

    /// Where a moment of a file is on the timeline: every place it's used (a file can be in
    /// several clips).
    func timelineTimes(of seconds: Double, in path: String) -> [Double] {
        let offsets = self.offsets
        return project.clips.indices.compactMap { index in
            let clip = project.clips[index]
            guard clip.path == path, clip.freeze == nil, seconds >= clip.start, seconds < clip.end else { return nil }
            return offsets[index] + (seconds - clip.start) / clip.speed
        }
    }

    /// The file and its time at a moment of the timeline.
    func fileTime(at seconds: Double) -> (path: String, time: Double)? {
        guard let (index, into) = clip(at: seconds) else { return nil }
        let clip = project.clips[index]
        return (clip.path, clip.freeze ?? clip.start + into * clip.speed)
    }

    // MARK: - In and out, markers

    func markIn(_ seconds: Double? = nil) {
        let at = seconds ?? time
        change { project in
            project.inPoint = at
            if let out = project.outPoint, out <= at { project.outPoint = nil }
        }
    }

    func markOut(_ seconds: Double? = nil) {
        let at = seconds ?? time
        change { project in
            project.outPoint = at
            if let start = project.inPoint, start >= at { project.inPoint = nil }
        }
    }

    func clearIn() { change { $0.inPoint = nil } }
    func clearOut() { change { $0.outPoint = nil } }
    func clearRange() { change { $0.inPoint = nil; $0.outPoint = nil } }

    var hasRange: Bool { project.inPoint != nil || project.outPoint != nil }
    /// The part to play, loop or export: the in to the out point, or the whole edit.
    var range: ClosedRange<Double> {
        let start = min(max(project.inPoint ?? 0, 0), duration), end = max(min(project.outPoint ?? duration, duration), start)
        return start...end
    }

    @discardableResult
    func addMarker(at seconds: Double? = nil, title: String = "") -> UUID {
        let marker = ProjectMarker(time: seconds ?? time, title: title)
        change { $0.markers = ($0.markers ?? []) + [marker] }
        return marker.id
    }

    func setMarker(_ id: UUID, _ body: @escaping (inout ProjectMarker) -> Void) {
        change { project in
            guard let index = project.markers?.firstIndex(where: { $0.id == id }) else { return }
            body(&project.markers![index])
        }
    }

    func removeMarker(_ id: UUID) { change { $0.markers?.removeAll { $0.id == id } } }

    /// The marker next to the playhead, ahead or behind.
    func jumpToMarker(forward: Bool) {
        let times = (project.markers ?? []).map(\.time).sorted()
        if let next = forward ? times.first(where: { $0 > time + 0.01 }) : times.last(where: { $0 < time - 0.01 }) { seek(to: next) }
    }
}

extension Project {
    /// Only this stretch of the timeline: the clips cut to it, the music and titles moved and cut
    /// with it (what an export of the in to the out point is made from).
    func cut(to range: ClosedRange<Double>) -> Project {
        var copy = self
        var at = 0.0
        copy.clips = clips.compactMap { clip in
            defer { at += clip.length }
            let from = max(range.lowerBound, at), to = min(range.upperBound, at + clip.length)
            guard to - from > 0.001 else { return nil }
            var part = clip
            if clip.freeze == nil {
                part.start = clip.start + (from - at) * clip.speed
                part.end = clip.start + (to - at) * clip.speed
            } else {
                part.end = part.start + (to - from) * clip.speed
            }
            if from > at { part.fadeIn = 0; part.transitionIn = nil }
            if to < at + clip.length { part.fadeOut = 0; part.dipOut = nil }
            return part
        }
        copy.music = music.compactMap { song in
            let from = max(range.lowerBound, song.at), to = min(range.upperBound, song.at + song.length)
            guard to - from > 0.05 else { return nil }
            var part = song
            part.start = song.start + (from - song.at)
            part.end = part.start + (to - from)
            part.at = from - range.lowerBound
            return part
        }
        copy.titles = titles.compactMap { title in
            let from = max(range.lowerBound, title.start), to = min(range.upperBound, title.end)
            guard to - from > 0.05 else { return nil }
            var part = title
            part.start = from - range.lowerBound
            part.end = to - range.lowerBound
            return part
        }
        copy.inPoint = nil
        copy.outPoint = nil
        copy.markers = nil
        return copy
    }
}
