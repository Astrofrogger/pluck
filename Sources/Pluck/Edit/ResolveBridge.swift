import Foundation

/// The edit engine's hands in DaVinci Resolve (Studio): opens a project, imports footage (Resolve
/// reads RED, BRAW and every camera format), and builds the finished timeline. Each call runs a
/// small script in Resolve's own Python, with its instructions as JSON.
enum ResolveBridge {
    private static let app = URL(fileURLWithPath: "/Applications/DaVinci Resolve/DaVinci Resolve.app")
    private static let python = app.appendingPathComponent("Contents/Applications/ResolvePython")
    private static let library = app.appendingPathComponent("Contents/Libraries/Fusion/fusionscript.so")
    private static let scripting = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting"

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Runs one instruction and returns Resolve's answer.
    /// Makes the empty timeline an edit goes into and returns its real frame rate (Resolve keeps
    /// the project's rate when the asked one can't be set), which the edit is then placed in.
    /// Makes an empty timeline: its frame rate, and its name as Resolve has it (build the edit in
    /// that one; a name in use gets a number).
    static func createTimeline(_ name: String, frameRate: Double) async throws -> (rate: Double, name: String) {
        let answer = try await run(["action": "createTimeline", "name": name, "frameRate": frameRate])
        let rate = (answer["rate"] as? Double) ?? frameRate
        return (rate > 0 ? rate : frameRate, (answer["timeline"] as? String) ?? name)
    }

    static func run(_ instruction: [String: Any]) async throws -> [String: Any] {
        try await run(instruction, script: script)
    }

    /// Runs one instruction with another script (one that starts with `preamble`).
    static func run(_ instruction: [String: Any], script: String) async throws -> [String: Any] {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: instruction), as: UTF8.self)
        let output = await Task.detached { () -> String in
            let process = Process()
            process.executableURL = python
            process.arguments = ["-c", script, scripting + "/Modules", json]
            var environment = ProcessInfo.processInfo.environment
            environment["RESOLVE_SCRIPT_API"] = scripting
            environment["RESOLVE_SCRIPT_LIB"] = library.path
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            guard (try? process.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix("PLUCKJSON:") }),
              let answer = try JSONSerialization.jsonObject(with: Data(line.dropFirst("PLUCKJSON:".count).utf8)) as? [String: Any] else {
            throw Failure(message: output.isEmpty ? Resolve.Failure.notReachable.localizedDescription : String(output.suffix(400)))
        }
        if let error = answer["error"] as? String {
            throw error == "notReachable" ? Failure(message: Resolve.Failure.notReachable.localizedDescription) : Failure(message: error)
        }
        return answer
    }

    // MARK: - The script

    /// The common start of every script: Resolve, the instruction, and how to answer.
    static let preamble = #"""
import sys, json
sys.path.append(sys.argv[1])
import DaVinciResolveScript as dvr

def out(value):
    print("PLUCKJSON:" + json.dumps(value))
    sys.exit(0)

resolve = dvr.scriptapp("Resolve")
if resolve is None:
    out({"error": "notReachable"})
cmd = json.loads(sys.argv[2])
pm = resolve.GetProjectManager()
action = cmd["action"]
"""#

    private static let script = #"""
import sys, json
sys.path.append(sys.argv[1])
import DaVinciResolveScript as dvr

def out(value):
    print("PLUCKJSON:" + json.dumps(value))
    sys.exit(0)

resolve = dvr.scriptapp("Resolve")
if resolve is None:
    out({"error": "notReachable"})
cmd = json.loads(sys.argv[2])
pm = resolve.GetProjectManager()
action = cmd["action"]

def clips_in(folder):
    found = list(folder.GetClipList() or [])
    for sub in folder.GetSubFolderList() or []:
        found += clips_in(sub)
    return found

if action == "open":
    # Save whatever is open, then switch to (or create) the project. Says what was open before.
    # Only a real, named project is saved: asking Resolve to save the empty placeholder it shows
    # in the Project Manager opens its "Create New Project" dialog and waits there.
    current = pm.GetCurrentProject()
    original = current.GetName() if current else None
    if original not in (pm.GetProjectListInCurrentFolder() or []):
        original = None
    if original:
        pm.SaveProject()
    if original == cmd["name"]:
        out({"original": original, "project": original})
    project = pm.LoadProject(cmd["name"]) or pm.CreateProject(cmd["name"])
    if project is None:
        out({"error": "Couldn't open or create the project " + cmd["name"]})
    for key, value in (cmd.get("settings") or {}).items():
        project.SetSetting(key, str(value))
    out({"original": original, "project": project.GetName()})

if action == "restore":
    # Save the test project (it has a name, so this is safe), then go back to what was open.
    current = pm.GetCurrentProject()
    if current and current.GetName() in (pm.GetProjectListInCurrentFolder() or []):
        pm.SaveProject()
    project = pm.LoadProject(cmd["name"]) if cmd.get("name") else None
    out({"project": project.GetName() if project else None})

project = pm.GetCurrentProject()
if project is None:
    out({"error": "No project is open in DaVinci Resolve."})
pool = project.GetMediaPool()

if action == "import":
    root = pool.GetRootFolder()
    name = cmd.get("bin") or "Pluck"
    folder = next((f for f in root.GetSubFolderList() if f.GetName() == name), None) or pool.AddSubFolder(root, name)
    pool.SetCurrentFolder(folder)
    known = {c.GetClipProperty("File Path"): c for c in clips_in(root)}
    wanted = [p for p in cmd["paths"] if p not in known]
    if wanted:
        pool.ImportMedia(wanted)
    known = {c.GetClipProperty("File Path"): c for c in clips_in(root)}
    clips = []
    for path in cmd["paths"]:
        clip = known.get(path)
        if clip:
            clips.append({"path": path, "name": clip.GetName(), "fps": clip.GetClipProperty("FPS"),
                          "frames": clip.GetClipProperty("Frames"), "startTimecode": clip.GetClipProperty("Start TC"),
                          "resolution": clip.GetClipProperty("Resolution")})
    out({"clips": clips})

def timeline_named(name):
    for index in range(1, project.GetTimelineCount() + 1):
        found = project.GetTimelineByIndex(index)
        if found and found.GetName() == name:
            return found
    return None

def timeline_name(name):
    # Resolve turns a colon in a timeline name into a full stop: ask for that name straight away,
    # so the timeline can be found by it afterwards.
    return name.replace(":", ".")

if action == "createTimeline":
    # An empty timeline at the asked frame rate if Resolve allows it (whole rates only, through
    # scripting); the rate it really has is what the edit is placed in. A name already in use
    # gets a number (an empty timeline of that name, left by an earlier try, is used again).
    base = timeline_name(cmd["name"])
    name, number = base, 2
    while timeline_named(name) is not None and timeline_named(name).GetItemListInTrack("video", 1):
        name = "%s %d" % (base, number)
        number += 1
    timeline = timeline_named(name) or pool.CreateEmptyTimeline(name)
    if timeline is None:
        out({"error": "Couldn't create the timeline " + name})
    rate = cmd.get("frameRate")
    if rate:
        timeline.SetSetting("useCustomSettings", "1")
        text = ("%.3f" % rate).rstrip("0").rstrip(".")
        if not timeline.SetSetting("timelineFrameRate", text):
            timeline.SetSetting("useCustomSettings", "0")
    out({"timeline": timeline.GetName(), "rate": float(timeline.GetSetting("timelineFrameRate") or 0)})

if action == "buildTimeline":
    root = pool.GetRootFolder()
    known = {c.GetClipProperty("File Path"): c for c in clips_in(root)}
    name = timeline_name(cmd["name"])
    existing = timeline_named(name)
    timeline = existing if existing and not existing.GetItemListInTrack("video", 1) else pool.CreateEmptyTimeline(name)
    if timeline is None:
        out({"error": "Couldn't create the timeline " + name})
    project.SetCurrentTimeline(timeline)
    while timeline.GetTrackCount("video") < cmd.get("videoTracks", 1):
        timeline.AddTrack("video")
    start = timeline.GetStartFrame()
    infos, wanted = [], []
    for item in cmd.get("items", []):
        clip = known.get(item["path"])
        if clip is None:
            continue
        infos.append({"mediaPoolItem": clip, "startFrame": item["sourceIn"], "endFrame": item["sourceOut"],
                      "trackIndex": item.get("track", 1), "recordFrame": start + item["recordIn"],
                      "mediaType": item.get("mediaType", 1)})
        wanted.append(item)
    placed = pool.AppendToTimeline(infos) or []
    eases = {"in": resolve.DYNAMIC_ZOOM_EASE_IN, "out": resolve.DYNAMIC_ZOOM_EASE_OUT,
             "inOut": resolve.DYNAMIC_ZOOM_EASE_IN_AND_OUT, "linear": resolve.DYNAMIC_ZOOM_EASE_LINEAR}
    groups = {g.GetName(): g for g in (project.GetColorGroupsList() or [])}
    zoomed = graded = grouped = 0
    for timelineItem, item in zip(placed, wanted):
        if timelineItem is None:
            continue
        zoom = item.get("zoom")
        if zoom and timelineItem.SetProperties({"DynamicZoomEnabled": True, "DynamicZoomEase": eases.get(zoom, resolve.DYNAMIC_ZOOM_EASE_IN_AND_OUT)}):
            zoomed += 1
        if item.get("group"):
            group = groups.get(item["group"]) or project.AddColorGroup(item["group"])
            if group:
                groups[item["group"]] = group
                if timelineItem.AssignToColorGroup(group):
                    grouped += 1
        if item.get("cdl") and timelineItem.SetCDL(item["cdl"]):
            graded += 1
        if item.get("clipColor"):
            timelineItem.SetClipColor(item["clipColor"])
    for marker in cmd.get("markers", []):
        timeline.AddMarker(marker["frame"], marker.get("color", "Blue"), marker["name"], marker.get("note", ""), marker.get("duration", 1))
    out({"timeline": timeline.GetName(), "placed": len(placed), "asked": len(infos), "zoomed": zoomed, "graded": graded, "grouped": grouped, "start": start})

if action == "renderAnalysis":
    # Small H.264 copies with sound of clips Pluck can't read itself (RED, BRAW), rendered from a
    # temporary timeline as individual clips. The timeline and job are always removed again.
    import os, time
    target = cmd["folder"]
    if os.path.exists(target) and not os.path.isdir(target):
        out({"error": "The folder for analysis copies is a file: " + target})
    os.makedirs(target, exist_ok=True)
    root = pool.GetRootFolder()
    name = cmd.get("bin") or "Pluck"
    folder = next((f for f in root.GetSubFolderList() if f.GetName() == name), None) or pool.AddSubFolder(root, name)
    pool.SetCurrentFolder(folder)
    known = {c.GetClipProperty("File Path"): c for c in clips_in(root)}
    wanted = [p for p in cmd["paths"] if p not in known]
    if wanted:
        pool.ImportMedia(wanted)
    known = {c.GetClipProperty("File Path"): c for c in clips_in(root)}
    paths = [p for p in cmd["paths"] if p in known]
    clips = [known[p] for p in paths]
    if not clips:
        out({"error": "DaVinci Resolve couldn't import the footage."})
    previous = project.GetCurrentTimeline()
    timeline = pool.CreateTimelineFromClips("Pluck analysis " + str(int(time.time())), clips)
    if timeline is None:
        out({"error": "Couldn't make a timeline for the analysis copies."})
    job = None
    status = {}
    try:
        project.SetCurrentTimeline(timeline)
        codecs = project.GetRenderCodecs("mp4") or {}
        codec = next((v for k, v in codecs.items() if "264" in k or "264" in v), "H264")
        project.SetCurrentRenderFormatAndCodec("mp4", codec)
        project.SetCurrentRenderMode(0)
        project.SetRenderSettings({"SelectAllFrames": True, "TargetDir": target, "ExportVideo": True, "ExportAudio": True,
                                   "FormatWidth": 640, "FormatHeight": 360})
        job = project.AddRenderJob()
        if job:
            project.StartRendering([job])
            while project.IsRenderingInProgress():
                time.sleep(0.5)
            status = project.GetRenderJobStatus(job) or {}
    finally:
        if job:
            project.DeleteRenderJob(job)
        pool.DeleteTimelines([timeline])
        if previous:
            project.SetCurrentTimeline(previous)
    # Which file belongs to which clip: Resolve names each one after its clip.
    files = sorted(os.listdir(target))
    result = {}
    for path, clip in zip(paths, clips):
        stem = os.path.splitext(clip.GetName())[0]
        match = next((f for f in files if f.startswith(stem)), None)
        if match:
            result[path] = os.path.join(target, match)
    out({"copies": result, "status": status.get("JobStatus", "")})

if action == "cleanUp":
    # Temporary analysis timelines left behind by an interrupted run.
    leftovers = []
    for index in range(1, project.GetTimelineCount() + 1):
        timeline = project.GetTimelineByIndex(index)
        if timeline and timeline.GetName().startswith("Pluck analysis "):
            leftovers.append(timeline)
    if leftovers:
        pool.DeleteTimelines(leftovers)
    out({"removed": len(leftovers)})

if action == "poolClips":
    # The project's video clips: where their files are, their frame rate and length.
    found = []
    for clip in clips_in(pool.GetRootFolder()):
        kind = clip.GetClipProperty("Type") or ""
        path = clip.GetClipProperty("File Path") or ""
        if path and "Video" in kind:
            found.append({"path": path, "name": clip.GetName(), "fps": clip.GetClipProperty("FPS"),
                          "frames": clip.GetClipProperty("Frames")})
    out({"project": project.GetName(), "clips": found})

if action == "logClips":
    # Pluck's log on each clip: description and keywords (never over someone's own description),
    # and a marker per shot. Markers from an earlier log are replaced, other markers stay.
    by_path = {c.GetClipProperty("File Path"): c for c in clips_in(pool.GetRootFolder())}
    logged = 0
    markers = 0
    for entry in cmd["clips"]:
        clip = by_path.get(entry["path"])
        if clip is None:
            continue
        meta = clip.GetMetadata() or {}
        ours = (clip.GetThirdPartyMetadata() or {}).get("Pluck Log") == "1"
        if entry.get("description") and (ours or not meta.get("Description")):
            clip.SetMetadata({"Description": entry["description"]})
        if entry.get("keywords"):
            have = [k.strip() for k in (meta.get("Keywords") or "").split(",") if k.strip()]
            merged = have + [k for k in entry["keywords"] if k not in have]
            clip.SetMetadata({"Keywords": ", ".join(merged)})
        if entry.get("shotType") and (ours or not meta.get("Shot Type")):
            clip.SetMetadata({"Shot Type": entry["shotType"]})
        clip.SetThirdPartyMetadata({"Pluck Log": "1"})
        # (Each call removes one.)
        for _ in range(5000):
            if not clip.DeleteMarkerByCustomData("pluck"):
                break
        for m in entry.get("markers", []):
            if clip.AddMarker(m["frame"], m["color"], m["name"], m["note"], m["duration"], "pluck"):
                markers += 1
        logged += 1
    out({"logged": logged, "markers": markers})

if action == "readTimeline":
    timeline = project.GetCurrentTimeline()
    if timeline is None:
        out({"error": "No timeline"})
    items = []
    for track in range(1, timeline.GetTrackCount("video") + 1):
        for i in timeline.GetItemListInTrack("video", track) or []:
            props = i.GetProperties() or {}
            group = i.GetColorGroup()
            items.append({"track": track, "name": i.GetName(), "start": i.GetStart(), "end": i.GetEnd(),
                          "sourceStart": i.GetSourceStartFrame(), "dynamicZoom": bool(props.get("DynamicZoomEnabled")),
                          "colorGroup": group.GetName() if group else None})
    audio = [{"track": t, "count": len(timeline.GetItemListInTrack("audio", t) or [])} for t in range(1, timeline.GetTrackCount("audio") + 1)]
    out({"timeline": timeline.GetName(), "start": timeline.GetStartFrame(), "items": items, "audio": audio,
         "markers": len(timeline.GetMarkers() or {})})

out({"error": "Unknown action " + action})
"""#
}
