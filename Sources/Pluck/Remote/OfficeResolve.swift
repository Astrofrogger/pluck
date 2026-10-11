import Foundation

/// What the office Mac does in DaVinci Resolve for a Mac at home: list the projects in the
/// project library Resolve has open (the Blackmagic Cloud library), a project's timelines and
/// render presets, and render one timeline with one preset into the render folder. Calls run
/// one at a time, so a status check never lands in the middle of opening a project.
@MainActor
enum OfficeResolve {
    private static var tail: Task<Void, Never> = Task {}

    static func run(_ instruction: [String: Any]) async throws -> [String: Any] {
        let previous = tail
        let task = Task { () async throws -> [String: Any] in
            await previous.value
            return try await ResolveBridge.run(instruction, script: script)
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    /// Projects with the folders they're in (paths are lists of folder names from the top).
    static func projects() async throws -> [(folder: [String], name: String)] {
        let answer = try await run(["action": "projects"])
        return (answer["projects"] as? [[String: Any]] ?? []).compactMap {
            guard let name = $0["name"] as? String else { return nil }
            return ($0["folder"] as? [String] ?? [], name)
        }
    }

    private static let script = ResolveBridge.preamble + "\n" + #"""
import os

def walk(path):
    found = [{"folder": path, "name": n} for n in (pm.GetProjectListInCurrentFolder() or [])]
    if len(path) < 8:
        for sub in pm.GetFolderListInCurrentFolder() or []:
            if pm.OpenFolder(sub):
                found += walk(path + [sub])
                pm.GotoParentFolder()
    return found

def rendering(project):
    return bool(project and project.IsRenderingInProgress())

def open_project(folder, name):
    # The project asked for, opened in Resolve. Whatever was open is saved first (only a real,
    # named project: saving the empty placeholder opens a dialog that waits for someone).
    current = pm.GetCurrentProject()
    if current and current.GetName() == name:
        return current
    if rendering(current):
        out({"error": "busy"})
    if current and current.GetName() in (pm.GetProjectListInCurrentFolder() or []):
        pm.SaveProject()
    pm.GotoRootFolder()
    for part in folder:
        if not pm.OpenFolder(part):
            out({"error": "The folder " + part + " isn't in the project library on the host Mac."})
    project = pm.LoadProject(name)
    if project is None:
        out({"error": "DaVinci Resolve on the host Mac couldn't open the project " + name + "."})
    return project

if action == "hello":
    db = pm.GetCurrentDatabase() or {}
    current = pm.GetCurrentProject()
    out({"database": db.get("DbName", ""), "type": db.get("DbType", ""),
         "project": current.GetName() if current else None, "rendering": rendering(current)})

if action == "projects":
    current = pm.GetCurrentProject()
    pm.GotoRootFolder()
    found = walk([])
    # Back to the folder of the open project, as the Project Manager was.
    pm.GotoRootFolder()
    home = next((p["folder"] for p in found if current and p["name"] == current.GetName()), [])
    for part in home:
        pm.OpenFolder(part)
    out({"projects": found})

if action == "project":
    project = open_project(cmd["folder"], cmd["name"])
    timelines = []
    for i in range(1, project.GetTimelineCount() + 1):
        t = project.GetTimelineByIndex(i)
        if t:
            timelines.append(t.GetName())
    current = project.GetCurrentTimeline()
    out({"timelines": timelines, "presets": list(project.GetRenderPresetList() or []),
         "timeline": current.GetName() if current else None})

if action == "render":
    project = open_project(cmd["folder"], cmd["name"])
    if rendering(project):
        out({"error": "busy"})
    timeline = None
    for i in range(1, project.GetTimelineCount() + 1):
        t = project.GetTimelineByIndex(i)
        if t and t.GetName() == cmd["timeline"]:
            timeline = t
    if timeline is None:
        out({"error": "The timeline " + cmd["timeline"] + " isn't in this project any more."})
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

if action == "status":
    project = pm.GetCurrentProject()
    if project is None or project.GetName() != cmd["name"]:
        out({"status": {}, "elsewhere": True})
    result = {}
    jobs = {j.get("JobId"): j for j in (project.GetRenderJobList() or [])}
    for job in cmd["jobs"]:
        status = project.GetRenderJobStatus(job) or {}
        info = jobs.get(job) or {}
        files = info.get("OutputFilename") or ""
        status["file"] = os.path.join(info.get("TargetDir", ""), files) if files else ""
        status["exists"] = job in jobs
        result[job] = status
    out({"status": result, "rendering": rendering(project)})

if action == "stop":
    project = pm.GetCurrentProject()
    if project is None or project.GetName() != cmd["name"]:
        out({"stopped": False})
    status = project.GetRenderJobStatus(cmd["job"]) or {}
    if status.get("JobStatus") == "Rendering":
        project.StopRendering()
    out({"stopped": True})

out({"error": "Unknown action " + action})
"""#
}
