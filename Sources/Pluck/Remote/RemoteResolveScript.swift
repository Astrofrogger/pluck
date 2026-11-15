import Foundation

/// The DaVinci Resolve side of the remote round trip, on both Macs: the host builds a project from
/// the originals with proxies linked, imports an editor's project, swaps proxies for originals and
/// renders; the editor's Mac reads its open project, exports it, imports one from the host and
/// links the local proxies. Runs one call at a time with OfficeResolve's other calls.
///
/// Every Resolve call below was checked in the scripting API stubs (21.2, DaVinciResolveScript.pyi):
/// ProjectManager.CreateProject/LoadProject/DeleteProject/SaveProject/CloseProject/ImportProject/
/// ExportProject(name, path, withStillsAndLUTs)/GotoRootFolder/GetProjectListInCurrentFolder/GetCurrentProject,
/// Project.GetMediaPool/GetTimelineCount/GetTimelineByIndex/GetCurrentTimeline/SetCurrentTimeline/
/// GetRenderPresetList/LoadRenderPreset/SetRenderSettings(TargetDir, CustomName, SelectAllFrames)/AddRenderJob/
/// StartRendering/IsRenderingInProgress, MediaPool.GetRootFolder/AddSubFolder/SetCurrentFolder/ImportMedia([{FilePath}]),
/// Folder.GetClipList/GetSubFolderList/GetName, MediaPoolItem.GetClipProperty("File Path", "Proxy Media Path",
/// "Frames", "FPS", "Audio Ch", "Start TC")/GetUniqueId/GetName/LinkProxyMedia/UnlinkProxyMedia/ReplaceClip.
@MainActor
enum RemoteResolveScript {
    static func run(_ instruction: [String: Any]) async throws -> [String: Any] {
        try await OfficeResolve.run(instruction, script: script)
    }

    static let script = ResolveBridge.preamble + "\n" + #"""
import os

def clips_in(folder):
    found = list(folder.GetClipList() or [])
    for sub in folder.GetSubFolderList() or []:
        found += clips_in(sub)
    return found

def saved_name(project):
    # Only a real, named project is saved: saving Resolve's empty placeholder opens a dialog that waits.
    return bool(project) and project.GetName() in (pm.GetProjectListInCurrentFolder() or [])

def leave_current(name):
    # Saves what's open, or closes our own copy that is about to be replaced; then the top of the library.
    current = pm.GetCurrentProject()
    if current and current.IsRenderingInProgress():
        out({"error": "busy"})
    if current and current.GetName() == name:
        pm.CloseProject(current)
    elif saved_name(current):
        pm.SaveProject()
    pm.GotoRootFolder()

def fresh(name):
    leave_current(name)
    if name in (pm.GetProjectListInCurrentFolder() or []) and not pm.DeleteProject(name):
        out({"error": "DaVinci Resolve couldn't replace the project " + name + "."})

def binner(pool):
    bins = {(): pool.GetRootFolder()}
    def bin_for(parts):
        key = tuple(parts)
        if key not in bins:
            parent = bin_for(parts[:-1])
            found = next((f for f in (parent.GetSubFolderList() or []) if f.GetName() == parts[-1]), None)
            bins[key] = found or pool.AddSubFolder(parent, parts[-1]) or parent
        return bins[key]
    return bin_for

def timeline_names(project):
    names = []
    for i in range(1, project.GetTimelineCount() + 1):
        t = project.GetTimelineByIndex(i)
        if t:
            names.append(t.GetName())
    return names

def prop(clip, key):
    value = clip.GetClipProperty(key)
    return "" if value is None else str(value)

# --- On the host -------------------------------------------------------------------------------

if action == "build":
    # A new project from the originals (bins mirror the folders), each proxy linked, exported as .drp.
    name = cmd["name"]
    fresh(name)
    project = pm.CreateProject(name)
    if project is None:
        out({"error": "DaVinci Resolve on the host Mac couldn't make the project " + name + "."})
    pool = project.GetMediaPool()
    bin_for = binner(pool)
    groups = {}
    for f in cmd["files"]:
        groups.setdefault(tuple(f["bin"]), []).append(f)
    imported, linked, failed = 0, 0, 0
    for key, files in groups.items():
        pool.SetCurrentFolder(bin_for(list(key)))
        items = pool.ImportMedia([{"FilePath": f["path"]} for f in files]) or []
        imported += len(items)
        by_path = {i.GetClipProperty("File Path"): i for i in items}
        for f in files:
            item = by_path.get(f["path"])
            if item is None:
                failed += 1
            elif f.get("proxy") and item.LinkProxyMedia(f["proxy"]):
                linked += 1
    pm.SaveProject()
    if not pm.ExportProject(name, cmd["drp"], False):
        out({"error": "DaVinci Resolve on the host Mac couldn't export the project."})
    out({"imported": imported, "linked": linked, "failed": failed})

if action == "inspect":
    # An editor's project imported under our name: its clips, timelines and the render presets.
    name = cmd["name"]
    fresh(name)
    if not pm.ImportProject(cmd["drp"], name):
        out({"error": "DaVinci Resolve on the host Mac couldn't import the project."})
    project = pm.LoadProject(name)
    if project is None:
        out({"error": "DaVinci Resolve on the host Mac couldn't open the project."})
    names = timeline_names(project)
    items = []
    for c in clips_in(project.GetMediaPool().GetRootFolder()):
        if prop(c, "File Path") == "" and c.GetName() in names:
            continue  # a timeline (its own items are looked at below)
        items.append({"id": c.GetUniqueId(), "name": c.GetName(), "file": prop(c, "File Path"), "frames": prop(c, "Frames"),
                      "fps": prop(c, "FPS"), "audio": prop(c, "Audio Ch"), "tc": prop(c, "Start TC")})
    # Fusion compositions and effects, generators and clips without a file of their own (compound clips) can reach
    # files the media pool doesn't list (a Loader's path, a script). The scripting API can't list those safely, so
    # the host refuses such projects. Transitions and subtitle text are fine.
    unsafe = []
    for i in range(1, project.GetTimelineCount() + 1):
        t = project.GetTimelineByIndex(i)
        if not t:
            continue
        for kind in ("video", "audio"):
            for n in range(1, (t.GetTrackCount(kind) or 0) + 1):
                for it in t.GetItemListInTrack(kind, n) or []:
                    try:
                        if it.GetType() == "transition":
                            continue
                        mp = it.GetMediaPoolItem()
                        bad = it.GetType() == "generator" or (it.GetFusionCompCount() or 0) > 0 or bool(it.GetEffects("fusion")) \
                            or mp is None or (prop(mp, "File Path") == "" and mp.GetName() not in names)
                    except Exception:
                        bad = True
                    if bad and len(unsafe) < 50:
                        unsafe.append(it.GetName() or "?")
    out({"items": items, "timelines": names, "presets": list(project.GetRenderPresetList() or []), "unsafe": unsafe})

if action == "render":
    # Proxies swapped for their originals (by media pool id), then one render with the preset.
    name = cmd["name"]
    project = pm.GetCurrentProject()
    if project is None or project.GetName() != name:
        leave_current("")
        project = pm.LoadProject(name)
        if project is None:
            out({"error": "DaVinci Resolve on the host Mac couldn't open the project."})
    if project.IsRenderingInProgress():
        out({"error": "busy"})
    swaps = cmd["swaps"]
    failed = []
    for c in clips_in(project.GetMediaPool().GetRootFolder()):
        target = swaps.get(c.GetUniqueId())
        if target:
            c.UnlinkProxyMedia()
            if not c.ReplaceClip(target):
                failed.append(c.GetName())
    if failed:
        out({"error": "DaVinci Resolve couldn't switch to the originals of: " + ", ".join(failed[:5])})
    pm.SaveProject()
    timeline = None
    for i in range(1, project.GetTimelineCount() + 1):
        t = project.GetTimelineByIndex(i)
        if t and t.GetName() == cmd["timeline"]:
            timeline = t
    if timeline is None:
        out({"error": "The timeline " + cmd["timeline"] + " isn't in this project."})
    project.SetCurrentTimeline(timeline)
    if not project.LoadRenderPreset(cmd["preset"]):
        out({"error": "The render preset " + cmd["preset"] + " couldn't be loaded on the host Mac."})
    os.makedirs(cmd["target"], exist_ok=True)
    project.SetRenderSettings({"SelectAllFrames": True, "TargetDir": cmd["target"], "CustomName": cmd["output"]})
    job = project.AddRenderJob()
    if not job:
        out({"error": "DaVinci Resolve couldn't add the render job (check the preset's settings)."})
    if not project.StartRendering([job], False):
        project.DeleteRenderJob(job)
        out({"error": "DaVinci Resolve couldn't start rendering."})
    out({"job": job})

if action == "presets":
    project = pm.GetCurrentProject()
    out({"presets": list(project.GetRenderPresetList() or []) if project else []})

# --- On the editor's Mac -----------------------------------------------------------------------

if action == "current":
    project = pm.GetCurrentProject()
    if project is None:
        out({"error": "No project is open in DaVinci Resolve."})
    current = project.GetCurrentTimeline()
    files = sorted(set(prop(c, "File Path") for c in clips_in(project.GetMediaPool().GetRootFolder())) - {""})
    out({"project": project.GetName(), "saved": saved_name(project), "timelines": timeline_names(project),
         "timeline": current.GetName() if current else None, "files": files})

if action == "export":
    project = pm.GetCurrentProject()
    if not saved_name(project):
        out({"error": "Save the project in DaVinci Resolve first."})
    pm.SaveProject()
    if not pm.ExportProject(project.GetName(), cmd["drp"], False):
        out({"error": "DaVinci Resolve couldn't export the project."})
    out({"project": project.GetName()})

if action == "open":
    # A project from the host, imported under a free name and opened.
    current = pm.GetCurrentProject()
    if saved_name(current):
        pm.SaveProject()
    names = pm.GetProjectListInCurrentFolder() or []
    name, n = cmd["name"], 2
    while name in names:
        name, n = cmd["name"] + " " + str(n), n + 1
    if not pm.ImportProject(cmd["drp"], name):
        out({"error": "DaVinci Resolve couldn't import the project."})
    if pm.LoadProject(name) is None:
        out({"error": "DaVinci Resolve couldn't open the project."})
    out({"project": name})

if action == "link":
    # Clips of the host's originals get their local proxy linked; proxies not in the project yet are
    # imported into a bin per shared folder. Matched by full path, never by name.
    project = pm.GetCurrentProject()
    if project is None:
        out({"error": "No project is open in DaVinci Resolve."})
    pool = project.GetMediaPool()
    by_file = {}
    for c in clips_in(pool.GetRootFolder()):
        by_file.setdefault(prop(c, "File Path"), []).append(c)
    linked, added, present, failed = 0, 0, 0, 0
    pending = {}
    for e in cmd["entries"]:
        originals = by_file.get(e.get("original") or "", [])
        if originals:
            for c in originals:
                if prop(c, "Proxy Media Path") == e["proxy"] or c.LinkProxyMedia(e["proxy"]):
                    linked += 1
                else:
                    failed += 1
        elif e["proxy"] in by_file:
            present += 1
        else:
            pending.setdefault(tuple(e["bin"]), []).append(e["proxy"])
    bin_for = binner(pool)
    for key, files in pending.items():
        pool.SetCurrentFolder(bin_for(list(key)))
        items = pool.ImportMedia([{"FilePath": f} for f in files]) or []
        added += len(items)
        failed += len(files) - len(items)
    if saved_name(project):
        pm.SaveProject()
    out({"linked": linked, "added": added, "present": present, "failed": failed})

out({"error": "Unknown action " + action})
"""#
}
