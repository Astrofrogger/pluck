import Foundation

/// The Resolve timeline a project was sent to, to bring the edit back from, and where each
/// picture went there (as Resolve counts it), so only what changed there comes back.
struct ResolveLink: Codable, Hashable {
    var project: String
    var timeline: String
    var rate: Double
    var sent: [Sent]?
    /// New with each send; a merge keeps it (so undo can tell the two apart). Nil in older projects.
    var id: UUID? = UUID()

    struct Sent: Codable, Hashable {
        /// The clip or track item.
        var id: UUID
        var track: Int
        /// The picture lane it's on (track items).
        var lane: UUID?
        var path: String
        /// Record frames from the timeline's start; source frames at `fps`.
        var start: Int
        var end: Int
        var sourceStart: Double
        var sourceEnd: Double
        var fps: Double
    }
}

/// A Resolve timeline as the bridge reads it: record frames (from the timeline's start frame),
/// source frames in each file's own rate.
struct ResolveTimelineRead: Decodable {
    struct Marker: Decodable {
        var frame: Int
        var color: String
        var name: String
        var note: String?
        var duration: Int?
        var customData: String?
    }

    struct Item: Decodable {
        var track: Int
        var path: String?
        var name: String?
        var start: Int
        var end: Int
        var sourceStart: Double
        var sourceEnd: Double
        var fps: Double?
    }

    struct Sound: Decodable {
        var track: Int
        var start: Int
        var end: Int
    }

    var timeline: String?
    var start: Int
    var rate: Double?
    var markers: [Marker]
    var items: [Item]
    var sounds: [Sound]?
}

/// Bringing an edit back from Resolve: the markers, the main line's order and trims, and the
/// pictures laid over it. Each clip keeps what Resolve can't hold for it (its look, volume, role)
/// when the same part of the same file comes back.
enum ProjectResolveRead {
    struct Summary: Equatable {
        var markers = 0
        var moved = 0
        var trimmed = 0
        var added = 0
        var removed = 0
        /// What didn't come back, one phrase each ("speed changes on 2 clips").
        var skipped: [String] = []
    }

    /// What Pluck put on the timeline itself (story passages, titles): not read back as markers.
    static let ownMarker = "pluck"
    /// A project marker sent to Resolve, followed by its id.
    static let markerPrefix = "pluck-marker:"

    static func merge(_ read: ResolveTimelineRead, into project: Project, link: ResolveLink) -> (Project, Summary) {
        let rate = read.rate.flatMap { $0 > 0 ? $0 : nil } ?? link.rate
        let sent = link.sent ?? []
        var result = project, summary = Summary()
        func record(_ frame: Int) -> Int { frame - read.start }

        // The markers: all of them but Pluck's own (a copied one gets an id of its own).
        let known = Set((project.markers ?? []).map(\.id))
        var ids: Set<UUID> = []
        let markers: [ProjectMarker] = read.markers.sorted { $0.frame < $1.frame }.compactMap { m in
            if m.customData == ownMarker { return nil }
            var marker = ProjectMarker(time: Double(m.frame) / rate, title: m.name, color: colour(m.color))
            if let data = m.customData, data.hasPrefix(markerPrefix), let id = UUID(uuidString: String(data.dropFirst(markerPrefix.count))),
               known.contains(id), !ids.contains(id) {
                marker.id = id
            }
            ids.insert(marker.id)
            if let duration = m.duration, duration > 1 { marker.length = Double(duration) / rate }
            return marker
        }
        result.markers = markers.isEmpty ? nil : markers
        summary.markers = markers.count

        var speedChanged = 0, generators = 0, gaps = 0
        /// What was sent that this item is, by its place in the file: the same frames, else the most of them.
        func match(_ item: ResolveTimelineRead.Item, among candidates: [ResolveLink.Sent], used: Set<UUID>) -> ResolveLink.Sent? {
            let open = candidates.filter { $0.path == item.path && !used.contains($0.id) }
            if let same = open.first(where: { abs($0.sourceStart - item.sourceStart) < 0.5 && abs($0.sourceEnd - item.sourceEnd) < 0.5 }) { return same }
            return open.map { ($0, min(item.sourceEnd, $0.sourceEnd) - max(item.sourceStart, $0.sourceStart)) }
                .filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
        }
        /// The clip (or item) moved by what changed there since it was sent: nil when nothing did.
        func changed(_ clip: ProjectClip, _ was: ResolveLink.Sent, _ item: ResolveTimelineRead.Item) -> ProjectClip? {
            let moved = (item.sourceStart - was.sourceStart) / was.fps
            let longer = Double((item.end - item.start) - (was.end - was.start)) / rate
            // Sent at normal speed for the clip's length: another speed there was set in Resolve.
            let wasRatio = (was.sourceEnd - was.sourceStart) / was.fps / max(Double(was.end - was.start) / rate, 0.001)
            let ratio = (item.sourceEnd - item.sourceStart) / was.fps / max(Double(item.end - item.start) / rate, 0.001)
            if abs(ratio / max(wasRatio, 0.001) - 1) > 0.03 { speedChanged += 1 }
            guard moved != 0 || longer != 0 else { return nil }
            var clip = clip
            let length = max(clip.length + longer, 1 / rate)
            clip.start = max(clip.start + moved, 0)
            clip.end = clip.start + length * clip.speed
            return clip
        }

        // The main line (V1), in order: each clip sent keeps what Resolve can't hold for it.
        let sentClips = sent.filter { $0.track == 1 }
        let byID = Dictionary(project.clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var used: Set<UUID> = [], line: [ProjectClip] = [], edits: [ProjectClip] = [], order: [Int] = []
        /// Where each clip starts there now (record frames), for what's laid over it.
        var startsThere: [UUID: Int] = [:]
        var lastEnd: Int?
        /// What's there now, by Pluck's ids: the next update measures from this (not from the send again).
        var there: [ResolveLink.Sent] = []
        func note(_ id: UUID, _ item: ResolveTimelineRead.Item, path: String, fps: Double, lane: UUID? = nil) {
            there.append(ResolveLink.Sent(id: id, track: item.track, lane: lane, path: path, start: record(item.start), end: record(item.end),
                                          sourceStart: item.sourceStart, sourceEnd: item.sourceEnd, fps: fps))
        }
        for item in read.items.filter({ $0.track == 1 }).sorted(by: { $0.start < $1.start }) {
            guard let path = item.path, !path.isEmpty, item.end > item.start else { generators += 1; continue }
            if let lastEnd, item.start > lastEnd { gaps += 1 }
            lastEnd = item.end
            if let was = match(item, among: sentClips, used: used), let clip = byID[was.id] {
                used.insert(was.id)
                order.append(project.clips.firstIndex { $0.id == clip.id } ?? 0)
                startsThere[clip.id] = record(item.start)
                line.append(clip)
                note(clip.id, item, path: path, fps: was.fps)
                if let edited = changed(clip, was, item) { edits.append(edited); summary.trimmed += 1 }
            } else {
                // New there, or a clip cut in two: the look, sound and speed of the clip it came from.
                let fps = item.fps.flatMap { $0 > 0 ? $0 : nil } ?? rate
                let length = Double(item.end - item.start) / rate
                var clip = ProjectClip(path: path, start: item.sourceStart / fps, end: item.sourceStart / fps + length)
                func distance(_ entry: ResolveLink.Sent) -> Double { min(abs(entry.sourceEnd - item.sourceStart), abs(entry.sourceStart - item.sourceStart)) }
                if let near = sentClips.filter({ $0.path == path }).min(by: { distance($0) < distance($1) }), let from = byID[near.id] {
                    clip.look = from.look
                    clip.volume = from.volume
                    clip.end = clip.start + length * clip.speed
                }
                startsThere[clip.id] = record(item.start)
                line.append(clip)
                note(clip.id, item, path: path, fps: fps)
                summary.added += 1
            }
        }
        summary.moved = order.count - longestRising(order)
        let sentIDs = Set(sentClips.map(\.id))
        summary.removed = project.clips.filter { sentIDs.contains($0.id) && !used.contains($0.id) }.count
        // Clips that never went there (added since, or not placed) stay after the clip before them.
        var previous: UUID?
        for clip in project.clips {
            if sentIDs.contains(clip.id) {
                if used.contains(clip.id) { previous = clip.id }
                continue
            }
            let place = previous.flatMap { id in line.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
            line.insert(clip, at: min(place, line.count))
            previous = clip.id
        }
        result.clips = line
        // Trims through setClip, so a clip's sound taken off stays in step with it.
        for clip in edits { result.setClip(clip) }

        // The pictures laid over it (V2 and up), back on the lanes they were sent from.
        var tracks = result.tracks ?? []
        let sentItems = sent.filter { $0.track > 1 }
        var laneFor: [Int: Int] = [:]
        for entry in sentItems {
            if let lane = entry.lane, let index = tracks.firstIndex(where: { $0.id == lane }) { laneFor[entry.track] = index }
        }
        let items = Dictionary(tracks.flatMap(\.items).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let sentByID = Dictionary(sent.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let clipOfLink = Dictionary(project.clips.compactMap { clip in clip.link.map { ($0, clip.id) } }, uniquingKeysWith: { a, _ in a })
        var usedItems: Set<UUID> = []
        var placed: [Int: [ProjectClip]] = [:]
        for number in Set(read.items.map(\.track).filter { $0 > 1 }).sorted() {
            let lane: Int
            if let known = laneFor[number] {
                lane = known
            } else {
                tracks.append(ProjectTrack(kind: .video))
                lane = tracks.count - 1
                laneFor[number] = lane
            }
            for item in read.items.filter({ $0.track == number }).sorted(by: { $0.start < $1.start }) {
                guard let path = item.path, !path.isEmpty, item.end > item.start else { generators += 1; continue }
                if let was = match(item, among: sentItems.filter { $0.track == number }, used: usedItems), var kept = items[was.id] {
                    usedItems.insert(was.id)
                    var edited = false
                    if let moved = changed(kept, was, item) { kept = moved; edited = true }
                    let at = record(item.start)
                    // Laid over a clip and still at the same place on it: it follows the clip.
                    let clip = kept.link.flatMap { clipOfLink[$0] }
                    let stillOn = clip.flatMap { id in startsThere[id].flatMap { now in sentByID[id].map { at - now == was.start - $0.start } } } ?? false
                    if !stillOn {
                        if at != was.start { edited = true; kept.at = Double(at) / rate }
                        if clip != nil {
                            kept.at = Double(at) / rate
                            kept.link = nil
                            kept.linkOffset = nil
                        }
                    }
                    if edited { summary.trimmed += 1 }
                    placed[lane, default: []].append(kept)
                    note(kept.id, item, path: path, fps: was.fps, lane: tracks[lane].id)
                } else {
                    let fps = item.fps.flatMap { $0 > 0 ? $0 : nil } ?? rate
                    var clip = ProjectClip(path: path, start: item.sourceStart / fps, end: item.sourceStart / fps + Double(item.end - item.start) / rate)
                    clip.at = Double(record(item.start)) / rate
                    placed[lane, default: []].append(clip)
                    note(clip.id, item, path: path, fps: fps, lane: tracks[lane].id)
                    summary.added += 1
                }
            }
        }
        // Each picture lane: what never went there stays; what went and came back is as it is there.
        let sentItemIDs = Set(sentItems.map(\.id))
        for lane in tracks.indices where tracks[lane].kind == .video {
            summary.removed += tracks[lane].items.filter { sentItemIDs.contains($0.id) && !usedItems.contains($0.id) }.count
            tracks[lane].items = tracks[lane].items.filter { !sentItemIDs.contains($0.id) } + (placed[lane] ?? [])
        }
        result.tracks = tracks.isEmpty ? nil : tracks
        result.resolveTimeline?.sent = there

        // The sound isn't read: edits to it there are said, not lost silently.
        let cuts = Set(read.items.filter { $0.track == 1 }.map { "\($0.start)-\($0.end)" })
        let soundEdited = (read.sounds ?? []).contains { $0.track > 1 || !cuts.contains("\($0.start)-\($0.end)") }
        if speedChanged > 0 { summary.skipped.append(String(localized: "speed changes on ^[\(speedChanged) clip](inflect: true)")) }
        if soundEdited { summary.skipped.append(String(localized: "sound edits")) }
        if generators > 0 { summary.skipped.append(String(localized: "^[\(generators) title or generator](inflect: true)")) }
        if gaps > 0 { summary.skipped.append(String(localized: "^[\(gaps) gap](inflect: true) (closed up)")) }
        return (result, summary)
    }

    /// How many stay in their order (the rest were moved).
    private static func longestRising(_ values: [Int]) -> Int {
        var tails: [Int] = []
        for value in values {
            if let place = tails.firstIndex(where: { $0 >= value }) { tails[place] = value } else { tails.append(value) }
        }
        return tails.count
    }

    /// Resolve's sixteen marker colours as the nearest of Pluck's five.
    static func colour(_ name: String) -> ProjectMarker.Color {
        switch name {
        case "Green", "Mint": .green
        case "Yellow", "Lemon", "Sand", "Cream", "Cocoa": .yellow
        case "Red", "Rose", "Pink", "Fuchsia": .red
        case "Purple": .purple
        default: .blue
        }
    }

    static func resolveColour(_ colour: ProjectMarker.Color) -> String {
        switch colour {
        case .blue: "Blue"
        case .green: "Green"
        case .yellow: "Yellow"
        case .red: "Red"
        case .purple: "Purple"
        }
    }
}

extension ProjectModel {
    /// Brings the edit back from the Resolve timeline it was sent to, as one undo step.
    func updateFromResolve() async throws -> ProjectResolveRead.Summary {
        guard let link = project.resolveTimeline, link.sent?.isEmpty == false else {
            throw ResolveBridge.Failure(message: String(localized: "Send this project to DaVinci first."))
        }
        let answer: [String: Any]
        do {
            answer = try await ResolveBridge.run(["action": "readTimeline", "project": link.project, "timeline": link.timeline])
        } catch let failure as ResolveBridge.Failure where failure.message == "wrongProject" {
            throw ResolveBridge.Failure(message: String(localized: "Open the DaVinci project “\(link.project)” first."))
        } catch let failure as ResolveBridge.Failure where failure.message == "noTimeline" {
            throw ResolveBridge.Failure(message: String(localized: "The timeline “\(link.timeline)” isn’t in DaVinci any more."))
        }
        let read = try JSONDecoder().decode(ResolveTimelineRead.self, from: JSONSerialization.data(withJSONObject: answer))
        return apply(read, link: link)
    }

    /// The merge, as one undo step (the self-test feeds it a timeline by hand).
    @discardableResult
    func apply(_ read: ResolveTimelineRead, link: ResolveLink) -> ProjectResolveRead.Summary {
        let (merged, summary) = ProjectResolveRead.merge(read, into: project, link: link)
        change { $0 = merged }
        return summary
    }
}
