import Foundation

/// Relink in Resolve: in the DaVinci Resolve projects the owner picks (from Resolve's project
/// manager, or .drp files), each media pool item whose file was archived is pointed at its master
/// with MediaPoolItem.ReplaceClipPreserveSubClip (ReplaceClip on an older Resolve). Resolve's
/// Relink matches by file name with its extension, so an .R3D or .MP4 that became a .mov needs the
/// explicit replace. A .drp is imported as a project of its own and exported again beside the
/// original as "<name> relinked.drp"; the .drp itself isn't changed.
@MainActor
enum ShrinkRelink {
    /// Resolve's side (tests stand in a fake bridge).
    static var bridge: ([String: Any]) async throws -> [String: Any] = { try await ResolveBridge.run($0, script: ResolveBridge.preamble + script) }

    struct Result: Equatable, Sendable { var project: String; var replaced: Int; var failed: [String] }

    /// The projects in Resolve's project manager (its current folder).
    static func projects() async throws -> [String] {
        try await bridge(["action": "projects"])["projects"] as? [String] ?? []
    }

    /// Old path → master for every master of these runs that's there (`back`: master → original, for the
    /// files put back whose master had another name, the original there again).
    static func map(_ runs: [ShrinkFolders.Run], back: Bool = false) -> [String: String] {
        var map: [String: String] = [:]
        for run in runs {
            if back {
                for file in run.files where file.state == .restored {
                    if let master = file.master, master != file.path, FileManager.default.fileExists(atPath: file.path) { map[master] = file.path }
                }
            } else {
                for move in ShrinkFolders.pathList(run) where FileManager.default.fileExists(atPath: move.new) { map[move.old] = move.new }
            }
        }
        return map
    }

    /// Only the chosen projects and files are opened; each is saved after its clips are replaced.
    static func relink(_ runs: [ShrinkFolders.Run], projects: [String], drp: [URL], back: Bool = false) async throws -> [Result] {
        let map = map(runs, back: back)
        guard !map.isEmpty, !(projects.isEmpty && drp.isEmpty) else { return [] }
        let answer = try await bridge(["action": "relink", "projects": projects, "drp": drp.map(\.path), "map": map])
        return (answer["results"] as? [[String: Any]] ?? []).map {
            Result(project: $0["project"] as? String ?? "", replaced: $0["replaced"] as? Int ?? 0, failed: $0["failed"] as? [String] ?? [])
        }
    }

    // needs Resolve: checked against Resolve 21's scripting API stubs, not yet run against a real project.
    static let script = #"""
import os

def clips_in(folder):
    found = list(folder.GetClipList() or [])
    for sub in folder.GetSubFolderList() or []:
        found += clips_in(sub)
    return found

def replace(clip, path):
    try:
        if clip.ReplaceClipPreserveSubClip(path):
            return True
    except Exception:
        pass
    try:
        return bool(clip.ReplaceClip(path))
    except Exception:
        return False

if action == "projects":
    out({"projects": list(pm.GetProjectListInCurrentFolder() or [])})

if action == "relink":
    current = pm.GetCurrentProject()
    before = current.GetName() if current else None
    if before:
        pm.SaveProject()
    mapping = cmd["map"]
    names = list(cmd.get("projects", []))
    results = []
    exported = {}
    for path in cmd.get("drp", []):
        name = os.path.splitext(os.path.basename(path))[0] + " relinked"
        if pm.ImportProject(path, name):
            names.append(name)
            exported[name] = path
        else:
            results.append({"project": os.path.basename(path), "replaced": 0, "failed": ["import"]})
    for name in names:
        project = pm.LoadProject(name)
        if not project:
            results.append({"project": name, "replaced": 0, "failed": ["open"]})
            continue
        replaced = 0
        failed = []
        for clip in clips_in(project.GetMediaPool().GetRootFolder()):
            old = clip.GetClipProperty("File Path")
            if old in mapping:
                if replace(clip, mapping[old]):
                    replaced += 1
                else:
                    failed.append(old)
        pm.SaveProject()
        if name in exported:
            pm.ExportProject(name, os.path.splitext(exported[name])[0] + " relinked.drp")
        results.append({"project": name, "replaced": replaced, "failed": failed})
    if before:
        pm.LoadProject(before)
    out({"results": results})

out({"error": "unknown action"})
"""#
}
