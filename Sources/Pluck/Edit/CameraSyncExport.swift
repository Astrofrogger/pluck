import Foundation

/// Synced cameras out: a DaVinci Resolve timeline with a track per camera at the synced places
/// (Resolve's scripting can only make multicam clips by its own syncing, so this is the stacked
/// timeline to cut from or turn into a multicam clip there), the same as an FCPXML file, and a
/// Pluck Edit project with a lane per camera.
enum CameraSyncExport {
    /// One synced clip on the timeline, in whole timeline frames from the first clip.
    struct Placement {
        var clip: SyncClip
        var camera: String
        /// 1-based; nil for a sound recorder's (video) or a silent camera's (audio).
        var videoTrack: Int?
        var audioTrack: Int?
        var record: Int
        var frames: Int
        var recorder = false
    }

    /// The timeline's rate: the cameras' most common one.
    static func rate(_ cameras: [SyncCamera]) -> Double {
        let rates = cameras.flatMap(\.clips).filter(\.hasVideo).map { standard($0.fps) }.filter { $0 > 0 }
        return Dictionary(grouping: rates, by: { $0 }).max { $0.value.count < $1.value.count }?.key ?? 25
    }

    /// The standard rate within 1% of `fps` (a phone's variable 29.98 or 29.87 is 30000/1001, exactly), else to 0.001.
    static func standard(_ fps: Double) -> Double {
        let standards: [Double] = [24000.0 / 1001, 24, 25, 30000.0 / 1001, 30, 48000.0 / 1001, 48, 50, 60000.0 / 1001, 60, 120000.0 / 1001, 120]
        let near = standards.min { abs($0 - fps) < abs($1 - fps) }!
        return abs(near - fps) < fps * 0.01 ? near : (fps * 1000).rounded() / 1000
    }

    /// The timeline's first frame in timecode when the clips sit in timecode (some placed at their
    /// own timecode or slate): the earliest synced place, in frames of `rate`. Nil otherwise.
    static func startFrame(_ cameras: [SyncCamera], rate: Double) -> Int? {
        let clips = cameras.flatMap(\.clips)
        guard clips.contains(where: { ($0.method == .timecode && $0.start == $0.timecode) || ($0.method == .slate && $0.start == $0.slate) }),
              let first = clips.compactMap(\.start).min() else { return nil }
        return Int((first * rate).rounded())
    }

    /// Frames as "HH:MM:SS:FF" (wrapping at a day).
    /// A 29.97/59.94 timeline in drop frame: a clip placed at its own timecode has drop-frame timecode.
    static func dropFrame(_ cameras: [SyncCamera], rate: Double) -> Bool {
        let base = rate.rounded()
        return abs(rate - base) > 0.01 && Int(base) % 30 == 0 && cameras.flatMap(\.clips).contains { $0.dropFrame && $0.method == .timecode }
    }

    /// `drop`: the label drop frame shows for that many frames ("HH:MM:SS;FF", 29.97/59.94 only).
    static func timecode(_ frames: Int, rate: Double, drop: Bool = false) -> String {
        let base = DropFrame.base(rate), drop = drop && base % 30 == 0
        let day = drop ? (base * 600 - base / 15 * 9) * 144 : base * 86400
        return DropFrame.string((frames % day + day) % day, base: base, drop: drop)
    }

    /// `recorderFirst`: a sound recorder's sound on the first audio tracks, the cameras' below it (see `muted`).
    static func placements(_ cameras: [SyncCamera], rate: Double, recorderFirst: Bool = false) -> [Placement] {
        let synced = cameras.flatMap(\.clips).compactMap(\.start)
        guard let first = synced.min() else { return [] }
        let active = cameras.filter { $0.clips.contains { $0.start != nil } }
        let heard = (recorderFirst ? active.filter(\.isSoundRecorder) + active.filter { !$0.isSoundRecorder } : active).filter(\.hasAudio)
        let audioTrack = Dictionary(uniqueKeysWithValues: heard.enumerated().map { ($0.element.id, $0.offset + 1) })
        var placements: [Placement] = []
        var video = 0
        for camera in active {
            let v: Int? = camera.isSoundRecorder ? nil : { video += 1; return video }()
            for clip in camera.clips {
                guard let start = clip.start else { continue }
                placements.append(Placement(clip: clip, camera: camera.name, videoTrack: v, audioTrack: clip.hasAudio ? audioTrack[camera.id] : nil,
                                            record: Int(((start - first) * rate).rounded()),
                                            frames: max(Int((clip.duration * (1 + clip.drift) * rate).rounded()), 1), recorder: camera.isSoundRecorder))
            }
        }
        return placements
    }

    /// With a recorder's sound as the main sound: the cameras' sound tracks, turned off (still there to switch on).
    static func muted(_ placements: [Placement]) -> [Int] {
        guard placements.contains(where: { $0.recorder && $0.audioTrack != nil }) else { return [] }
        return Array(Set(placements.filter { !$0.recorder }.compactMap(\.audioTrack))).sorted()
    }

    // MARK: - Sets

    /// The synced cameras in sets, one timeline each: a new set after a gap over `gap` seconds (3 h). Only the gap
    /// counts, not the clips' dates: a show past midnight, or a camera whose clock has the wrong day, stays one set
    /// (the day only names it, see `setNames`). Clips not synced are left out.
    static func sets(_ cameras: [SyncCamera], gap: Double = 3 * 3600) -> [[SyncCamera]] {
        let placed = cameras.flatMap(\.clips).filter { $0.start != nil }.sorted { $0.start! < $1.start! }
        var groups: [Set<UUID>] = [], end = -Double.infinity
        for clip in placed {
            if groups.isEmpty || clip.start! - end > gap { groups.append([]) }
            groups[groups.count - 1].insert(clip.id)
            end = max(end, clip.end!)
        }
        return groups.map { ids in
            cameras.compactMap { camera in
                var camera = camera
                camera.clips = camera.clips.filter { ids.contains($0.id) }
                return camera.clips.isEmpty ? nil : camera
            }
        }
    }

    /// A set's name: its day ("2026-05-01", a second set that day "2026-05-01 2"), else "Set 2".
    static func setNames(_ sets: [[SyncCamera]]) -> [String] {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        var seen: [String: Int] = [:]
        return sets.enumerated().map { n, set in
            let first = set.flatMap(\.clips).min { $0.start! < $1.start! }
            let base = first?.created.map(format.string) ?? String(localized: "Set \(n + 1)")
            seen[base, default: 0] += 1
            return seen[base]! > 1 ? "\(base) \(seen[base]!)" : base
        }
    }

    // MARK: - FCPXML

    /// A time on a rate's frame grid as FCPXML writes it ("1001/30000s" steps for 29.97).
    static func time(_ frames: Int, rate: Double) -> String {
        guard frames != 0 else { return "0s" }
        let whole = Int(rate.rounded())
        if abs(rate - Double(whole)) > 0.01 { return "\(frames * 1001)/\(whole * 1000)s" }
        return "\(frames)/\(whole)s"
    }

    static func fcpxml(_ cameras: [SyncCamera], name: String) -> String {
        let rate = rate(cameras)
        let placements = placements(cameras, rate: rate)
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let total = placements.map { $0.record + $0.frames }.max() ?? 0
        // The sequence starts at the earliest clip's timecode when the clips sit in timecode.
        let tcStart = time(startFrame(cameras, rate: rate) ?? 0, rate: rate)
        var resources = ["    <format id=\"r0\" frameDuration=\"\(time(1, rate: rate))\" name=\"FFVideoFormat\"/>"]
        var clips: [String] = []
        for (number, placement) in placements.enumerated() {
            let clip = placement.clip, id = "a\(number + 1)"
            // The clip's own timecode is where its media starts (as Resolve reads it).
            let ownRate = clip.fps > 0 ? standard(clip.fps) : rate
            let start = time(Int(((clip.timecode ?? 0) * ownRate).rounded()), rate: ownRate)
            resources.append("    <asset id=\"\(id)\" name=\"\(escaped(clip.name))\" start=\"\(start)\" duration=\"\(time(placement.frames, rate: rate))\" "
                             + "hasVideo=\"\(clip.hasVideo ? 1 : 0)\" hasAudio=\"\(clip.hasAudio ? 1 : 0)\"\(clip.hasVideo ? " format=\"r0\"" : "")>"
                             + "<media-rep kind=\"original-media\" src=\"\(escaped(clip.file.absoluteString))\"/></asset>")
            // Cameras on lanes above, a sound recorder below.
            let lane = placement.videoTrack ?? -(placement.audioTrack ?? 1)
            clips.append("            <asset-clip ref=\"\(id)\" lane=\"\(lane)\" offset=\"\(time(placement.record, rate: rate))\" start=\"\(start)\" "
                         + "duration=\"\(time(placement.frames, rate: rate))\" name=\"\(escaped(placement.camera + " · " + clip.name))\"/>")
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.10">
          <resources>
        \(resources.joined(separator: "\n"))
          </resources>
          <library>
            <event name="\(escaped(name))">
              <project name="\(escaped(name))">
                <sequence format="r0" duration="\(time(total, rate: rate))" tcStart="\(tcStart)" tcFormat="\(dropFrame(cameras, rate: rate) ? "DF" : "NDF")">
                  <spine>
                    <gap name="Gap" offset="\(tcStart)" start="0s" duration="\(time(total, rate: rate))">
        \(clips.joined(separator: "\n"))
                    </gap>
                  </spine>
                </sequence>
              </project>
            </event>
          </library>
        </fcpxml>

        """
    }

    // MARK: - DaVinci Resolve

    /// What the Resolve script places: a video item and a sound item per clip, at whole frames;
    /// source frames in each clip's own rate (`sourceRates`, as Resolve counts them).
    static func resolveItems(_ placements: [Placement], rate: Double, sourceRates: [String: Double] = [:]) -> [[String: Any]] {
        var items: [[String: Any]] = []
        for placement in placements {
            let clip = placement.clip
            // shortcut: a sound-only file's frames are counted at the timeline's rate; check on a real recorder file in Resolve.
            let own = sourceRates[clip.path] ?? (clip.fps > 0 ? clip.fps : rate)
            let length = Int((clip.duration * own).rounded())
            for (track, kind) in [(placement.videoTrack, 1), (placement.audioTrack, 2)] {
                guard let track else { continue }
                items.append(["path": clip.path, "track": track, "mediaType": kind, "recordIn": placement.record, "sourceIn": 0, "sourceOut": length])
            }
        }
        return items
    }

    /// What each clip is told in Resolve: its camera and angle (Resolve's multicam angle detection by Camera # or Angle).
    /// shortcut: "Camera #" and "Angle" as written by SetMetadata; check in real Resolve that Create Multicam Clip picks them up.
    static func angles(_ placements: [Placement]) -> [[Any]] {
        // (A recorder's sound isn't an angle: its name only.)
        placements.map { placement in
            var meta = ["Camera #": placement.camera]
            if let track = placement.videoTrack { meta["Angle"] = String(track) }
            return [placement.clip.path, meta] as [Any]
        }
    }

    /// A marker for each clip the sync isn't sure of (to check by eye): its place, its name, how it was placed.
    static func markers(_ placements: [Placement]) -> [[Any]] {
        placements.filter { $0.clip.quality != .good }.map { placement in
            let clip = placement.clip
            return [placement.record, placement.camera + " · " + clip.name,
                    methodName(clip) + " · " + clip.confidence.formatted(.percent.precision(.fractionLength(0)))] as [Any]
        }
    }

    /// Imports the footage into the open Resolve project (bins "Sync Cameras" / day / camera) and builds a
    /// timeline per set (see `sets`). Returns their names.
    static func sendToResolve(_ cameras: [SyncCamera], name: String, recorderFirst: Bool = true, gap: Double = 3 * 3600) async throws -> (timelines: [String], placed: Int, asked: Int) {
        let sets = sets(cameras, gap: gap)
        guard !sets.isEmpty else { throw ResolveBridge.Failure(message: String(localized: "No clip is synced yet.")) }
        let bin = String(localized: "Sync Cameras")
        let paths = Array(Set(sets.flatMap { $0.flatMap(\.clips).map(\.path) })).sorted()
        let imported = try await ResolveBridge.run(["action": "import", "paths": paths, "bin": bin])
        var rates: [String: Double] = [:]
        for entry in imported["clips"] as? [[String: Any]] ?? [] {
            guard let path = entry["path"] as? String else { continue }
            let text = (entry["fps"] as? String) ?? (entry["fps"] as? NSNumber)?.stringValue ?? ""
            if let fps = Double(text.split(separator: " ").first ?? ""), fps > 0 { rates[path] = fps }
        }
        let labels = setNames(sets)
        var timelines: [String] = [], placed = 0, asked = 0
        for (set, label) in zip(sets, labels) {
            let rate = rate(set)
            let made = try await ResolveBridge.createTimeline(sets.count == 1 ? name : name + " " + label, frameRate: rate)
            // Resolve kept another rate: the places in that one. (Its 29.97 is 30000/1001.)
            let timelineRate = abs(made.rate - rate) > 0.01 ? standard(made.rate) : rate
            let used = placements(set, rate: timelineRate, recorderFirst: recorderFirst)
            let start = startFrame(set, rate: timelineRate).map { timecode($0, rate: timelineRate, drop: dropFrame(set, rate: timelineRate)) }
            var videoNames: [String: Int] = [:], audioNames: [String: Int] = [:]
            for placement in used {
                if let track = placement.videoTrack { videoNames[placement.camera] = track }
                if let track = placement.audioTrack { audioNames[placement.camera] = track }
            }
            let answer = try await ResolveBridge.run(["action": "syncTimeline", "name": made.name,
                                                      "items": resolveItems(used, rate: timelineRate, sourceRates: rates),
                                                      "videoTracks": videoNames.values.max() ?? 1, "audioTracks": audioNames.values.max() ?? 1,
                                                      "videoNames": videoNames.map { [$0.value, $0.key] as [Any] },
                                                      "audioNames": audioNames.map { [$0.value, $0.key] as [Any] },
                                                      "startTimecode": start ?? "", "bin": bin,
                                                      "bins": used.map { [$0.clip.path, label, $0.camera] as [Any] },
                                                      "metadata": angles(used), "markers": markers(used), "muted": recorderFirst ? muted(used) : []],
                                                     script: ResolveBridge.preamble + script)
            timelines.append(answer["timeline"] as? String ?? made.name)
            placed += answer["placed"] as? Int ?? 0
            asked += answer["asked"] as? Int ?? 0
        }
        return (timelines, placed, asked)
    }

    private static let script = #"""
def clips_in(folder):
    found = list(folder.GetClipList() or [])
    for sub in folder.GetSubFolderList() or []:
        found += clips_in(sub)
    return found

project = pm.GetCurrentProject()
if project is None:
    out({"error": "No project is open in DaVinci Resolve."})
pool = project.GetMediaPool()

if action == "syncTimeline":
    timeline = None
    for index in range(1, project.GetTimelineCount() + 1):
        found = project.GetTimelineByIndex(index)
        if found and found.GetName() == cmd["name"]:
            timeline = found
    if timeline is None:
        out({"error": "Couldn't find the timeline " + cmd["name"]})
    project.SetCurrentTimeline(timeline)
    while timeline.GetTrackCount("video") < cmd["videoTracks"]:
        timeline.AddTrack("video")
    while timeline.GetTrackCount("audio") < cmd["audioTracks"]:
        timeline.AddTrack("audio", "stereo")
    for index, name in cmd.get("videoNames", []):
        timeline.SetTrackName("video", index, name)
    for index, name in cmd.get("audioNames", []):
        timeline.SetTrackName("audio", index, name)
    known = {c.GetClipProperty("File Path"): c for c in clips_in(pool.GetRootFolder())}
    # The timeline starts at the earliest clip's timecode (the places are counted from its start frame).
    if cmd.get("startTimecode"):
        timeline.SetStartTimecode(cmd["startTimecode"])
    start = timeline.GetStartFrame()
    infos = []
    for item in cmd["items"]:
        clip = known.get(item["path"])
        if clip is None:
            continue
        infos.append({"mediaPoolItem": clip, "startFrame": item["sourceIn"], "endFrame": item["sourceOut"],
                      "trackIndex": item["track"], "recordFrame": start + item["recordIn"], "mediaType": item["mediaType"]})
    placed = [p for p in (pool.AppendToTimeline(infos) or []) if p]
    # Bins per day and camera under the import's bin; each clip's camera and angle for multicam (older Resolve: skipped).
    def sub(parent, name):
        return next((f for f in parent.GetSubFolderList() or [] if f.GetName() == name), None) or pool.AddSubFolder(parent, name)
    top = next((f for f in pool.GetRootFolder().GetSubFolderList() or [] if f.GetName() == cmd.get("bin")), None)
    # Only clips in the sync's own bin (what it imported): the editor's own clips of the same files stay where they're sorted.
    mine = {c.GetClipProperty("File Path"): c for c in clips_in(top)} if top else {}
    moves = {}
    for path, day, camera in cmd.get("bins", []):
        if path in mine:
            moves.setdefault((day, camera), []).append(mine[path])
    for (day, camera), clips in moves.items():
        try:
            pool.MoveClips(clips, sub(sub(top, day), camera))
        except Exception:
            pass
    for path, meta in cmd.get("metadata", []):
        try:
            if path in known:
                known[path].SetMetadata(meta)
        except Exception:
            pass
    # shortcut: markers by frame from the timeline's start, tracks turned off as "muted"; check both in real Resolve.
    for frame, name, note in cmd.get("markers", []):
        try:
            timeline.AddMarker(frame, "Yellow", name, note, 1)
        except Exception:
            pass
    for index in cmd.get("muted", []):
        try:
            timeline.SetTrackEnable("audio", index, False)
        except Exception:
            pass
    out({"timeline": timeline.GetName(), "placed": len(placed), "asked": len(cmd["items"])})

out({"error": "Unknown action " + action})
"""#

    // MARK: - Report

    static func methodName(_ clip: SyncClip) -> String {
        switch clip.method {
        case .audio: String(localized: "By sound")
        case .timecode: String(localized: "By timecode")
        case .timecodeOffset: String(localized: "Timecode + sound offset")
        case .slate: String(localized: "By timecode slate")
        case .flashes: String(localized: "By light flashes")
        case .manual: String(localized: "Set by hand")
        case nil: clip.rough != nil ? String(localized: "Rough: from clock time") : String(localized: "Not synced")
        }
    }

    /// The sync report (HTML, saved beside the export): per angle, every clip with how it was placed, how sure, its drift; the ones not synced.
    static func report(_ cameras: [SyncCamera], name: String) -> String {
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let rate = rate(cameras)
        var html = "<!doctype html><html><head><meta charset=\"utf-8\"><title>\(escaped(name))</title><style>"
            + "body{font:14px -apple-system,sans-serif;margin:32px;color:#222}h2{margin-top:28px;font-size:16px}"
            + "table{border-collapse:collapse;width:100%}td,th{text-align:left;padding:4px 10px;border-bottom:1px solid #ddd}"
            + ".check{color:#a15c00}.none{color:#999}</style></head><body><h1>\(escaped(name))</h1>"
        for camera in cameras {
            let synced = camera.clips.filter { $0.start != nil }.count
            html += "<h2>\(escaped(camera.name))</h2><p>\(escaped(String(localized: "\(synced) of \(camera.clips.count) synced")))</p><table><tr>"
                + [String(localized: "Clip"), String(localized: "Method"), String(localized: "Confidence"), String(localized: "Drift")].map { "<th>\(escaped($0))</th>" }.joined() + "</tr>"
            for clip in camera.clips {
                let kind = clip.start == nil ? " class=\"none\"" : clip.quality != .good ? " class=\"check\"" : ""
                let sure = clip.start == nil ? "" : clip.confidence.formatted(.percent.precision(.fractionLength(0)))
                let drift = clip.drift == 0 ? "" : String(localized: "Drifts \((clip.drift * 3600 * rate).formatted(.number.precision(.fractionLength(1)))) frames an hour")
                html += "<tr\(kind)><td>\(escaped(clip.name))</td><td>\(escaped(methodName(clip)))</td><td>\(sure)</td><td>\(escaped(drift))</td></tr>"
            }
            html += "</table>"
        }
        return html + "</body></html>\n"
    }

    // MARK: - Pluck Edit

    /// A project with a picture lane per camera at the synced places (sound recorders on sound lanes).
    static func project(_ cameras: [SyncCamera], name: String) -> Project {
        var project = Project(name: name)
        let first = cameras.flatMap(\.clips).compactMap(\.start).min() ?? 0
        project.tracks = cameras.compactMap { camera in
            let items = camera.clips.compactMap { clip -> ProjectClip? in
                guard let start = clip.start else { return nil }
                var item = ProjectClip(path: clip.path, start: 0, end: clip.duration)
                item.at = start - first
                return item
            }
            guard !items.isEmpty else { return nil }
            var track = ProjectTrack(kind: camera.isSoundRecorder ? .audio : .video, name: camera.name)
            track.items = items
            return track
        }
        return project
    }
}
