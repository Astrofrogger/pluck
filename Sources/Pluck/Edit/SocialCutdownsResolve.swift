import AVFoundation

/// Finishing a cutdown in DaVinci Resolve: per format a timeline at the format's size with the
/// source cut at each shot and its reframe as position keyframes, so the crop stays editable.
/// Resolve's scripting can't set Edit-page keyframes (TimelineItem.SetProperties takes one value),
/// so the timeline is written as FCPXML (adjust-conform + adjust-transform keyframes) and
/// imported with MediaPool.ImportTimelineFromFile.
extension SocialCutdowns {
    /// One shot's position keyframes (FCPXML units: 100 = the frame's height, x to the right),
    /// at frames of the source; one key when the crop holds still.
    static func keyframes(_ plan: ShotPlan, analysis: Analysis, fps: Double) -> [(frame: Int, x: Double)] {
        let sourceWide = Double(analysis.width) / Double(max(analysis.height, 1)) * 100
        let first = Int((plan.start * fps).rounded()), last = max(first, Int((plan.end * fps).rounded()) - 1)
        let points = plan.times.indices.map { i in
            (frame: min(max(Int((plan.times[i] * fps).rounded()), first), last), x: (0.5 - plan.centres[i]) * sourceWide)
        }
        guard let start = points.first else { return [(first, 0)] }
        // Still (under a quarter unit, about 5 px of a 1920 high frame): one key.
        if points.allSatisfy({ abs($0.x - start.x) < 0.25 }) { return [(first, start.x)] }
        // Keys where the path bends; the straight stretches between them are left to Resolve.
        var kept = [start]
        for i in points.indices.dropFirst().dropLast() where points[i].frame > kept.last!.frame {
            let a = points[i - 1].x, b = points[i].x, c = points[i + 1].x
            if abs(b - (a + c) / 2) > 0.08 { kept.append(points[i]) }
        }
        if let end = points.last, end.frame > kept.last!.frame { kept.append(end) }
        return kept
    }

    /// The timeline for one format as FCPXML 1.10.
    static func fcpxml(_ analysis: Analysis, format: Format, plans: [ShotPlan], name: String, hasAudio: Bool) -> String {
        let fps = analysis.fps
        let time = { (frames: Int) in CameraSyncExport.time(frames, rate: fps) }
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let total = Int((analysis.duration * fps).rounded())
        let (w, h) = format.size
        var clips: [String] = []
        for plan in plans {
            let start = Int((plan.start * fps).rounded()), end = min(Int((plan.end * fps).rounded()), total)
            guard end > start else { continue }
            var clip = "        <asset-clip ref=\"a1\" offset=\"\(time(start))\" start=\"\(time(start))\" duration=\"\(time(end - start))\" name=\"\(escaped(analysis.file.lastPathComponent))\">"
            // Cropped shots fill the frame and slide; whole-picture shots fit (bars; a blur fill is left to Resolve).
            if plan.framing == .follow {
                let keys = keyframes(plan, analysis: analysis, fps: fps)
                let value = { (x: Double) in String(format: "%.4f 0", x) }
                clip += "<adjust-conform type=\"fill\"/><adjust-transform position=\"\(value(keys[0].x))\">"
                if keys.count > 1 {
                    clip += "<param name=\"position\"><keyframeAnimation>"
                        + keys.map { "<keyframe time=\"\(time($0.frame))\" value=\"\(value($0.x))\"/>" }.joined()
                        + "</keyframeAnimation></param>"
                }
                clip += "</adjust-transform>"
            } else {
                clip += "<adjust-conform type=\"fit\"/>"
            }
            clips.append(clip + "</asset-clip>")
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.10">
          <resources>
            <format id="r1" frameDuration="\(time(1))" width="\(w)" height="\(h)" name="FFVideoFormatRateUndefined"/>
            <format id="r2" frameDuration="\(time(1))" width="\(analysis.width)" height="\(analysis.height)" name="FFVideoFormatRateUndefined"/>
            <asset id="a1" name="\(escaped(analysis.file.lastPathComponent))" start="0s" duration="\(time(total))" hasVideo="1" hasAudio="\(hasAudio ? 1 : 0)" format="r2"><media-rep kind="original-media" src="\(escaped(analysis.file.absoluteString))"/></asset>
          </resources>
          <library>
            <event name="\(escaped(name))">
              <project name="\(escaped(name))">
                <sequence format="r1" duration="\(time(total))" tcStart="0s" tcFormat="NDF">
                  <spine>
        \(clips.joined(separator: "\n"))
                  </spine>
                </sequence>
              </project>
            </event>
          </library>
        </fcpxml>

        """
    }

    /// Imports each FCPXML file as a timeline in the open Resolve project (a name in use gets a number).
    static let resolveScript = #"""
if action == "importTimelines":
    project = pm.GetCurrentProject()
    if project is None:
        out({"error": "noProject"})
    pool = project.GetMediaPool()
    names = set()
    for index in range(1, project.GetTimelineCount() + 1):
        found = project.GetTimelineByIndex(index)
        if found:
            names.add(found.GetName())
    made = []
    for wanted in cmd["timelines"]:
        name, number = wanted["name"], 2
        while name in names:
            name = wanted["name"] + " " + str(number)
            number += 1
        timeline = pool.ImportTimelineFromFile(wanted["path"], {"timelineName": name, "importSourceClips": True})
        if timeline:
            names.add(timeline.GetName())
            made.append(timeline.GetName())
    if made:
        project.SetCurrentTimeline(timeline)
    out({"timelines": made})
"""#

    /// Writes "<name>_9x16.fcpxml" (one per format) into `folder` and imports them into Resolve.
    /// Returns the timelines' names as Resolve has them. The files stay, for File › Import by hand.
    static func sendToResolve(_ analysis: Analysis, plans: [Format: [ShotPlan]], formats: [Format], folder: URL,
                              run: ([String: Any]) async throws -> [String: Any] = { try await ResolveBridge.run($0, script: ResolveBridge.preamble + resolveScript) }) async throws -> [String] {
        let base = analysis.file.deletingPathExtension().lastPathComponent
        let hasAudio = ((try? await AVURLAsset(url: analysis.file).loadTracks(withMediaType: .audio))?.isEmpty == false)
        var timelines: [[String: Any]] = []
        for format in formats {
            let name = base + " " + format.tag.replacingOccurrences(of: "x", with: ":")
            let url = folder.appendingPathComponent(base + "_" + format.tag + ".fcpxml")
            try fcpxml(analysis, format: format, plans: plans[format] ?? [], name: name, hasAudio: hasAudio)
                .write(to: url, atomically: true, encoding: .utf8)
            timelines.append(["name": name, "path": url.path])
        }
        do {
            let answer = try await run(["action": "importTimelines", "timelines": timelines])
            return answer["timelines"] as? [String] ?? []
        } catch let failure as ResolveBridge.Failure where failure.message == "noProject" {
            throw ResolveBridge.Failure(message: String(localized: "No project is open in DaVinci Resolve."))
        }
    }
}
