import Foundation

/// Edits made with one key from what's chosen in the media panel, at the playhead, as in other
/// editors: append, insert, overwrite, place on top, replace. Each is one step to undo.
extension ProjectModel {
    /// The source as a clip: its chosen part, or the whole file. Nil when it can't be read.
    private func clip(for source: MediaSource) async -> ProjectClip? {
        let file = URL(fileURLWithPath: source.path)
        let length = await self.length(of: file)
        guard length > 0 else { return nil }
        let span = source.span ?? 0...length
        guard span.lowerBound < length else { return nil }
        return ProjectClip(path: source.path, start: span.lowerBound, end: min(span.upperBound, length))
    }

    /// The playhead on a whole frame.
    private var editPoint: Double { TrimMath.frames(time, frame) }

    /// At the end of the main line.
    func append(_ source: MediaSource) async {
        guard let clip = await clip(for: source) else { return }
        change { $0.clips.append(clip) }
    }

    /// At the playhead: the clip there is cut in two and everything after moves up.
    func insert(_ source: MediaSource) async {
        guard let clip = await clip(for: source) else { return }
        let at = editPoint, frame = self.frame
        change { project in
            let index = Self.cut(&project, at: at, frame: frame)
            project.clips.insert(clip, at: index)
        }
    }

    /// From the playhead, over what's there for the source's length; the edit stays as long
    /// (longer only when it runs past the end).
    func overwrite(_ source: MediaSource) async {
        guard let clip = await clip(for: source) else { return }
        let at = editPoint, frame = self.frame
        change { project in
            let first = Self.cut(&project, at: at, frame: frame)
            let last = Self.cut(&project, at: at + clip.length, frame: frame)
            project.clips.replaceSubrange(first..<last, with: [clip])
        }
    }

    /// Over the main line at the playhead, riding with the clip under it.
    func placeOnTop(_ source: MediaSource) async {
        guard var item = await clip(for: source) else { return }
        let at = editPoint
        let under = clip(at: at)
        let offsets = self.offsets
        change { project in
            item.at = at
            if let under, !project.clips.isEmpty {
                let link = project.clips[under.index].link ?? UUID()
                project.clips[under.index].link = link
                item.link = link
                item.linkOffset = at - offsets[under.index]
            }
            let index = Self.track(.video, in: &project)
            project.tracks![index].items.append(item)
        }
    }

    /// The clip under the playhead becomes the source (at the source's length); pictures placed
    /// on it stay with it, its own sound taken off to a track goes.
    func replace(_ source: MediaSource) async {
        guard let (index, _) = clip(at: editPoint) else { return }
        let id = project.clips[index].id
        guard var new = await clip(for: source) else { return }
        change { project in
            guard let index = project.clips.firstIndex(where: { $0.id == id }) else { return }
            let old = project.clips[index]
            new.link = old.link
            if let link = old.link, old.ownAudio == false {
                for t in (project.tracks ?? []).indices where project.tracks![t].kind == .audio {
                    project.tracks![t].items.removeAll { $0.link == link }
                }
            }
            project.clips[index] = new
        }
    }

    /// Cuts the main line at a timeline time and returns the index a clip put there would get.
    /// Nothing is cut within a frame of an edge.
    static func cut(_ project: inout Project, at seconds: Double, frame: Double) -> Int {
        var start = 0.0
        for (index, clip) in project.clips.enumerated() {
            let into = seconds - start
            if into < clip.length {
                if into <= frame / 2 { return index }
                if into >= clip.length - frame / 2 { return index + 1 }
                project.splitClip(index, into: into)
                return index + 1
            }
            start += clip.length
        }
        return project.clips.count
    }
}
