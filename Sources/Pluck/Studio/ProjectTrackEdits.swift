import AppKit
import AVFoundation
import Foundation

/// The edits beyond one line of clips: pictures laid over it, sound taken off a clip to a track
/// of its own, held frames, dissolves, and copying clips. All undoable.
extension ProjectModel {
    // MARK: - Tracks

    /// The first track of a kind, made when there's none.
    private static func track(_ kind: ProjectTrack.Kind, in project: inout Project) -> Int {
        var tracks = project.tracks ?? []
        if let index = tracks.firstIndex(where: { $0.kind == kind }) { return index }
        tracks.append(ProjectTrack(kind: kind))
        project.tracks = tracks
        return tracks.count - 1
    }

    /// A file laid over the main line from a moment (the playhead), its whole length.
    func addOverlay(_ file: URL, at seconds: Double? = nil) async {
        let length = await self.length(of: file)
        guard length > 0 else { return }
        let at = seconds ?? time
        let span = Self.fragmentRange(file) ?? 0...length
        change { project in
            let index = Self.track(.video, in: &project)
            var item = ProjectClip(path: file.path, start: span.lowerBound, end: min(span.upperBound, length))
            item.at = at
            project.tracks![index].items.append(item)
        }
    }

    /// A sound beside the main line (a voice-over), from a moment.
    func addAudio(_ file: URL, at seconds: Double? = nil) async {
        let length = await self.length(of: file)
        guard length > 0 else { return }
        let at = seconds ?? time
        change { project in
            let index = Self.track(.audio, in: &project)
            var item = ProjectClip(path: file.path, start: 0, end: length)
            item.at = at
            project.tracks![index].items.append(item)
        }
    }

    /// A clip's sound on an audio track of its own (to move, trim or fade apart from the
    /// picture); it stays linked, so it follows when the clip moves.
    func detachAudio(_ ids: Set<UUID>) {
        let offsets = self.offsets
        change { project in
            for (position, clip) in project.clips.enumerated() where ids.contains(clip.id) && clip.ownAudio != false && clip.freeze == nil {
                let index = Self.track(.audio, in: &project)
                let link = clip.link ?? UUID()
                project.clips[position].link = link
                project.clips[position].ownAudio = false
                var sound = clip
                sound.id = UUID()
                sound.link = link
                sound.ownAudio = nil
                sound.at = offsets[position]
                sound.transitionIn = nil
                sound.dipOut = nil
                project.tracks![index].items.append(sound)
            }
        }
    }

    /// Its sound back in the clip (the linked sound on the audio track goes).
    func attachAudio(_ ids: Set<UUID>) {
        change { project in
            for position in project.clips.indices where ids.contains(project.clips[position].id) {
                guard let link = project.clips[position].link else { continue }
                project.clips[position].ownAudio = nil
                for track in (project.tracks ?? []).indices {
                    project.tracks![track].items.removeAll { $0.link == link }
                }
            }
            project.tracks?.removeAll { $0.items.isEmpty }
        }
    }

    /// Items on the extra tracks follow the main-line clips they're linked to, and the tracks
    /// that are empty go.
    static func followLinks(_ project: inout Project) {
        guard project.tracks != nil else { return }
        var at = 0.0
        var starts: [UUID: Double] = [:]
        for clip in project.clips {
            if let link = clip.link { starts[link] = at }
            at += clip.length
        }
        for track in project.tracks!.indices {
            project.tracks![track].items = project.tracks![track].items.compactMap { item in
                guard let link = item.link else { return item }
                // Its clip was taken out: so is its sound.
                guard let start = starts[link] else { return nil }
                var item = item
                item.at = start
                return item
            }
        }
        project.tracks!.removeAll { $0.items.isEmpty }
        if project.tracks!.isEmpty { project.tracks = nil }
    }

    func trackItem(_ id: UUID) -> (track: Int, item: Int)? {
        guard let tracks = project.tracks else { return nil }
        for (t, track) in tracks.enumerated() {
            if let i = track.items.firstIndex(where: { $0.id == id }) { return (t, i) }
        }
        return nil
    }

    func setItem(_ id: UUID, record: Bool = true, _ body: @escaping (inout ProjectClip) -> Void) {
        guard let (t, i) = trackItem(id) else { return }
        if record {
            change { body(&$0.tracks![t].items[i]) }
        } else {
            changeWhileDragging { body(&$0.tracks![t].items[i]) }
        }
    }

    func removeItems(_ ids: Set<UUID>) {
        guard (project.tracks ?? []).contains(where: { $0.items.contains { ids.contains($0.id) } }) else { return }
        change { project in
            for t in (project.tracks ?? []).indices {
                let gone = project.tracks![t].items.filter { ids.contains($0.id) }
                project.tracks![t].items.removeAll { ids.contains($0.id) }
                // A detached sound taken out: the clip plays its own again.
                for item in gone {
                    if let link = item.link, let index = project.clips.firstIndex(where: { $0.link == link }) { project.clips[index].ownAudio = nil }
                }
            }
            project.tracks?.removeAll { $0.items.isEmpty }
        }
    }

    // MARK: - Held frames

    /// The frame at the playhead held for a while, cut into the edit there.
    func freezeFrame(at seconds: Double? = nil, length: Double = 2) {
        let at = seconds ?? time
        guard let (index, into) = clip(at: at) else { return }
        let clip = project.clips[index]
        let held = clip.freeze ?? clip.start + into * clip.speed
        change { project in
            var frame = ProjectClip(path: clip.path, start: 0, end: length)
            frame.freeze = held
            frame.look = clip.look.map { var look = $0; look.speed = 1; return look }
            frame.ownAudio = false
            // Cut there, the held frame between the two halves.
            if into > 0.02, clip.length - into > 0.02 {
                var first = clip, second = clip
                second.id = UUID()
                if clip.freeze == nil {
                    first.end = held
                    second.start = held
                } else {
                    first.end = clip.start + into * clip.speed
                    second.end = clip.end - into * clip.speed
                }
                first.fadeOut = 0; first.dipOut = nil
                second.fadeIn = 0; second.transitionIn = nil
                project.clips.replaceSubrange(index...index, with: [first, frame, second])
            } else {
                project.clips.insert(frame, at: into <= 0.02 ? index : index + 1)
            }
        }
    }

    // MARK: - Dissolves

    /// How clip `index` begins: cut, dissolve or a dip from the clip before.
    /// `record`: a step to undo (else a slider being dragged; its step comes when it's let go).
    func setTransition(into index: Int, _ transition: ProjectTransition?, record: Bool = true) {
        guard index > 0, project.clips.indices.contains(index) else { return }
        let body = { (project: inout Project) in
            project.clips[index].transitionIn = transition?.kind == .dissolve ? transition : nil
            project.clips[index - 1].dipOut = transition.flatMap { $0.kind == .dissolve ? nil : ProjectDip(white: $0.kind == .dipWhite, length: $0.length) }
        }
        if record { change(body) } else { changeWhileDragging(body) }
    }

    /// The transition into clip `index`, as one value (dissolves and dips alike).
    func transition(into index: Int) -> ProjectTransition? {
        guard index > 0, project.clips.indices.contains(index) else { return nil }
        if let dissolve = project.clips[index].transitionIn { return dissolve }
        return project.clips[index - 1].dipOut.map { ProjectTransition(kind: $0.white ? .dipWhite : .dipBlack, length: $0.length) }
    }

    // MARK: - Copy and paste

    /// Pluck's own kind of pasteboard item: clips with everything done to them.
    static let clipsType = NSPasteboard.PasteboardType("be.wideopen.pluck.clips")

    /// The selected clips (and items on the tracks) to the pasteboard.
    func copySelection() -> Bool {
        let clips = project.clips.filter { selected.contains($0.id) }
        let tracks = project.tracks ?? []
        let items = tracks.flatMap(\.items).filter { selected.contains($0.id) }
        let pictures = Set(tracks.filter { $0.kind == .video }.flatMap(\.items).map(\.id))
        let board = Clipboard(clips: clips, items: items, videoItems: Set(items.map(\.id).filter { pictures.contains($0) }))
        guard !(clips.isEmpty && items.isEmpty), let data = try? JSONEncoder().encode(board) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: Self.clipsType)
        // And their names, for anywhere else.
        pasteboard.setString((clips + items).map(\.name).joined(separator: "\n"), forType: .string)
        return true
    }

    func cutSelection() {
        guard copySelection() else { return }
        let ids = selected
        delete(ids)
        removeItems(ids)
    }

    /// Clips copied before, at the playhead: main-line clips into the edit there (at the cut
    /// nearest it), track items at the playhead.
    func paste() -> Bool {
        guard let data = NSPasteboard.general.data(forType: Self.clipsType),
              let board = try? JSONDecoder().decode(Clipboard.self, from: data) else { return false }
        let offsets = self.offsets
        let insertAt = offsets.enumerated().min { abs($0.element - time) < abs($1.element - time) }
            .map { abs($0.element - time) <= abs(duration - time) ? $0.offset : project.clips.count } ?? project.clips.count
        let earliest = board.items.compactMap(\.at).min() ?? 0
        var links: [UUID: UUID] = [:]
        func fresh(_ clip: ProjectClip) -> ProjectClip {
            var clip = clip
            clip.id = UUID()
            if let link = clip.link {
                if links[link] == nil { links[link] = UUID() }
                clip.link = links[link]
            }
            return clip
        }
        let clips = board.clips.map(fresh)
        let items = board.items.map { (fresh($0), board.videoItems.contains($0.id)) }
        change { project in
            project.clips.insert(contentsOf: clips, at: min(insertAt, project.clips.count))
            for (item, picture) in items {
                var item = item
                item.at = time + (item.at ?? 0) - earliest
                let index = Self.track(picture ? .video : .audio, in: &project)
                project.tracks![index].items.append(item)
            }
            project.media = project.files
        }
        selected = Set(clips.map(\.id) + items.map(\.0.id))
        return true
    }

    private struct Clipboard: Codable {
        var clips: [ProjectClip]
        var items: [ProjectClip]
        /// Which items came from a picture track.
        var videoItems: Set<UUID> = []
    }
}

extension ProjectModel {
    /// The frame at the playhead as it's shown (looks, layers, dissolves), as a picture: next to
    /// the file it's from, named for it and the time. `to`: straight there (tests).
    func saveFrame(to file: URL? = nil) {
        player.pause()
        guard let item = player.currentItem else { return }
        let at = CMTime(seconds: time, preferredTimescale: 600)
        let source = fileTime(at: time)
        let base = source.map { URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent } ?? project.name
        let folder = source.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent() }
        let stamp = Format.duration(time).replacingOccurrences(of: ":", with: ".")
        Task {
            let generator = AVAssetImageGenerator(asset: item.asset)
            generator.videoComposition = item.videoComposition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            do {
                let image = try await generator.image(at: at).image
                guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
                if let file { try png.write(to: file, options: .atomic); return }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png]
                if let folder { panel.directoryURL = folder }
                panel.nameFieldStringValue = "\(base) (\(stamp)).png"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try png.write(to: url, options: .atomic)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}
