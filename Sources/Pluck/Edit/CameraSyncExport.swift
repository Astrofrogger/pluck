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
    }

    /// The timeline's rate: the cameras' most common one.
    static func rate(_ cameras: [SyncCamera]) -> Double {
        let rates = cameras.flatMap(\.clips).filter(\.hasVideo).map { ($0.fps * 1000).rounded() / 1000 }.filter { $0 > 0 }
        return Dictionary(grouping: rates, by: { $0 }).max { $0.value.count < $1.value.count }?.key ?? 25
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
    /// shortcut: non-drop frame; a 29.97 timeline's start reads up to 3.6 s an hour off its drop-frame timecode.
    static func timecode(_ frames: Int, rate: Double) -> String {
        let base = max(Int(rate.rounded()), 1), total = ((frames % (base * 86400)) + base * 86400) % (base * 86400)
        return String(format: "%02d:%02d:%02d:%02d", total / base / 3600, total / base / 60 % 60, total / base % 60, total % base)
    }

    static func placements(_ cameras: [SyncCamera], rate: Double) -> [Placement] {
        let synced = cameras.flatMap(\.clips).compactMap(\.start)
        guard let first = synced.min() else { return [] }
        var placements: [Placement] = []
        var video = 0, audio = 0
        for camera in cameras where camera.clips.contains(where: { $0.start != nil }) {
            let v: Int? = camera.isSoundRecorder ? nil : { video += 1; return video }()
            let a: Int? = camera.hasAudio ? { audio += 1; return audio }() : nil
            for clip in camera.clips {
                guard let start = clip.start else { continue }
                placements.append(Placement(clip: clip, camera: camera.name, videoTrack: v, audioTrack: clip.hasAudio ? a : nil,
                                            record: Int(((start - first) * rate).rounded()),
                                            frames: max(Int((clip.duration * (1 + clip.drift) * rate).rounded()), 1)))
            }
        }
        return placements
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
            let ownRate = clip.fps > 0 ? clip.fps : rate
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
                <sequence format="r0" duration="\(time(total, rate: rate))" tcStart="\(tcStart)" tcFormat="NDF">
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

    /// Imports the footage into the open Resolve project (a "Sync Cameras" bin) and builds the timeline. Returns its name.
    static func sendToResolve(_ cameras: [SyncCamera], name: String) async throws -> (timeline: String, placed: Int, asked: Int) {
        let rate = rate(cameras)
        let placements = placements(cameras, rate: rate)
        guard !placements.isEmpty else { throw ResolveBridge.Failure(message: String(localized: "No clip is synced yet.")) }
        let paths = Array(Set(placements.map(\.clip.path))).sorted()
        let imported = try await ResolveBridge.run(["action": "import", "paths": paths, "bin": String(localized: "Sync Cameras")])
        var rates: [String: Double] = [:]
        for entry in imported["clips"] as? [[String: Any]] ?? [] {
            guard let path = entry["path"] as? String else { continue }
            let text = (entry["fps"] as? String) ?? (entry["fps"] as? NSNumber)?.stringValue ?? ""
            if let fps = Double(text.split(separator: " ").first ?? ""), fps > 0 { rates[path] = fps }
        }
        let made = try await ResolveBridge.createTimeline(name, frameRate: rate)
        // Resolve kept another rate: the places in that one.
        let used = abs(made.rate - rate) > 0.01 ? self.placements(cameras, rate: made.rate) : placements
        let start = startFrame(cameras, rate: made.rate).map { timecode($0, rate: made.rate) }
        var videoNames: [String: Int] = [:], audioNames: [String: Int] = [:]
        for placement in used {
            if let track = placement.videoTrack { videoNames[placement.camera] = track }
            if let track = placement.audioTrack { audioNames[placement.camera] = track }
        }
        let answer = try await ResolveBridge.run(["action": "syncTimeline", "name": made.name,
                                                  "items": resolveItems(used, rate: made.rate, sourceRates: rates),
                                                  "videoTracks": videoNames.values.max() ?? 1, "audioTracks": audioNames.values.max() ?? 1,
                                                  "videoNames": videoNames.map { [$0.value, $0.key] as [Any] },
                                                  "audioNames": audioNames.map { [$0.value, $0.key] as [Any] },
                                                  "startTimecode": start ?? ""],
                                                 script: ResolveBridge.preamble + script)
        return (answer["timeline"] as? String ?? made.name, answer["placed"] as? Int ?? 0, answer["asked"] as? Int ?? 0)
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
    out({"timeline": timeline.GetName(), "placed": len(placed), "asked": len(infos)})

out({"error": "Unknown action " + action})
"""#

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
