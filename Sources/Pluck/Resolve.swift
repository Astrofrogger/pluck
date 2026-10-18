import AppKit
import Foundation

/// Send to DaVinci Resolve: imports files into a "Pluck" bin of the project open in Resolve,
/// through Resolve's own scripting (its bundled Python, so nothing else needs installing).
enum Resolve {
    private static let app = URL(fileURLWithPath: "/Applications/DaVinci Resolve/DaVinci Resolve.app")
    private static let python = app.appendingPathComponent("Contents/Applications/ResolvePython")
    private static let library = app.appendingPathComponent("Contents/Libraries/Fusion/fusionscript.so")
    private static let scripting = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting"

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: python.path) && FileManager.default.fileExists(atPath: library.path)
    }

    enum Failure: LocalizedError {
        case notReachable, noProject, importFailed, other(String)

        var errorDescription: String? {
            switch self {
            case .notReachable:
                String(localized: "Pluck couldn’t reach DaVinci Resolve. Open DaVinci Resolve Studio and set Preferences › System › General › External scripting using to Local. (The free version of Resolve doesn’t allow this.)")
            case .noProject: String(localized: "Open a project in DaVinci Resolve first.")
            case .importFailed: String(localized: "DaVinci Resolve couldn’t import the file.")
            case .other(let message): message
            }
        }
    }

    /// The script Resolve's Python runs: file paths come in as arguments.
    private static let script = """
    import sys
    sys.path.append(sys.argv[1])
    import DaVinciResolveScript as dvr
    resolve = dvr.scriptapp("Resolve")
    if resolve is None:
        print("PLUCK:notReachable"); sys.exit(0)
    project = resolve.GetProjectManager().GetCurrentProject()
    if project is None:
        print("PLUCK:noProject"); sys.exit(0)
    pool = project.GetMediaPool()
    root = pool.GetRootFolder()
    bin = next((f for f in root.GetSubFolderList() if f.GetName() == "Pluck"), None) or pool.AddSubFolder(root, "Pluck")
    if bin:
        pool.SetCurrentFolder(bin)
    items = pool.ImportMedia(sys.argv[2:]) or []
    print("PLUCK:imported:%d:%s" % (len(items), project.GetName()))
    """

    /// Camera clips with the sound the camera wrote beside them: both imported (each once), and
    /// the sound linked to the clip by timecode (or from their starts, which the camera keeps
    /// together), so the clip plays with it in Resolve.
    private static let clipsScript = """
    import sys, json
    sys.path.append(sys.argv[1])
    import DaVinciResolveScript as dvr
    resolve = dvr.scriptapp("Resolve")
    if resolve is None:
        print("PLUCK:notReachable"); sys.exit(0)
    project = resolve.GetProjectManager().GetCurrentProject()
    if project is None:
        print("PLUCK:noProject"); sys.exit(0)
    pool = project.GetMediaPool()
    root = pool.GetRootFolder()
    bin = next((f for f in root.GetSubFolderList() if f.GetName() == "Pluck"), None) or pool.AddSubFolder(root, "Pluck")
    if bin:
        pool.SetCurrentFolder(bin)
    def find(path):
        for item in (bin.GetClipList() if bin else []) or []:
            if item.GetClipProperty("File Path") == path:
                return item
        return None
    def bring(path):
        item = find(path)
        if item:
            return item
        items = pool.ImportMedia([path]) or []
        return items[0] if items else find(path)
    clips = 0
    linked = 0
    for pair in json.loads(sys.argv[2]):
        video = bring(pair["video"])
        if not video:
            continue
        clips += 1
        if not pair.get("audio"):
            continue
        sound = bring(pair["audio"])
        if not sound:
            continue
        for mode in (resolve.AUDIO_SYNC_TIMECODE, resolve.AUDIO_SYNC_IN):
            if pool.AutoSyncAudio([video, sound], {resolve.AUDIO_SYNC_MODE: mode, resolve.AUDIO_SYNC_RETAIN_EMBEDDED_AUDIO: False,
                                                   resolve.AUDIO_SYNC_RETAIN_VIDEO_METADATA: False}):
                linked += 1
                break
    print("PLUCK:imported:%d:%d:%s" % (clips, linked, project.GetName()))
    """

    /// Camera clips (a RED clip's folder or any of its files, Blackmagic RAW, other video) into
    /// the open project with their sound linked; returns the project name and how many clips got
    /// their sound.
    static func sendClips(_ clips: [URL]) async throws -> (project: String, linked: Int) {
        let pairs: [[String: String]] = clips.map { clip in
            let video = cameraFile(clip)
            var pair = ["video": video.path]
            if let sound = cameraSound(for: video) { pair["audio"] = sound.path }
            return pair
        }
        let data = try JSONSerialization.data(withJSONObject: pairs)
        let output = await run(clipsScript, [String(decoding: data, as: UTF8.self)])
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix("PLUCK:") }) else {
            throw Failure.other(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Failure.notReachable.localizedDescription : String(output.suffix(300)))
        }
        let parts = line.split(separator: ":", maxSplits: 4).map(String.init)
        switch parts.count > 1 ? parts[1] : "" {
        case "notReachable": throw Failure.notReachable
        case "noProject": throw Failure.noProject
        case "imported" where parts.count == 5 && (Int(parts[2]) ?? 0) > 0: return (parts[4], Int(parts[3]) ?? 0)
        default: throw Failure.importFailed
        }
    }

    /// The file Resolve imports for a clip: a RED clip's first file (the whole take), else itself.
    private static func cameraFile(_ clip: URL) -> URL {
        if clip.hasDirectoryPath {
            let files = (try? FileManager.default.contentsOfDirectory(at: clip, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension.lowercased() == "r3d" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.first ?? clip
        }
        let name = clip.deletingPathExtension().lastPathComponent
        if clip.pathExtension.lowercased() == "r3d", let mark = name.range(of: "_[0-9]{3}$", options: .regularExpression) {
            let first = clip.deletingLastPathComponent().appendingPathComponent(name[..<mark.lowerBound] + "_001." + clip.pathExtension)
            if FileManager.default.fileExists(atPath: first.path) { return first }
        }
        return clip
    }

    /// The .wav the camera wrote next to a clip (a RED clip's in its folder), if there is one.
    private static func cameraSound(for video: URL) -> URL? {
        let base = video.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_001", with: "")
        let files = (try? FileManager.default.contentsOfDirectory(at: video.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.pathExtension.lowercased() == "wav" && $0.deletingPathExtension().lastPathComponent.hasPrefix(base) }
    }

    /// Imports the files; returns the project name.
    static func send(_ files: [URL]) async throws -> String {
        let output = await run(script, files.map(\.path))
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix("PLUCK:") }) else {
            throw Failure.other(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Failure.notReachable.localizedDescription : String(output.suffix(300)))
        }
        let parts = line.split(separator: ":", maxSplits: 3).map(String.init)
        switch parts.count > 1 ? parts[1] : "" {
        case "notReachable": throw Failure.notReachable
        case "noProject": throw Failure.noProject
        case "imported" where parts.count == 4 && (Int(parts[2]) ?? 0) > 0: return parts[3]
        default: throw Failure.importFailed
        }
    }

    /// Runs a script in Resolve's Python with these arguments (after the scripting folder).
    private static func run(_ script: String, _ arguments: [String]) async -> String {
        await Task.detached { () -> String in
            let process = Process()
            process.executableURL = python
            process.arguments = ["-c", script, scripting + "/Modules"] + arguments
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
    }

    /// Sends camera clips with their sound and brings Resolve forward.
    @MainActor
    static func sendClipsAndShow(_ clips: [URL]) {
        Task {
            do {
                _ = try await sendClips(clips)
                _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            } catch {
                let alert = NSAlert()
                alert.messageText = String(localized: "Couldn’t send to DaVinci Resolve")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    /// Sends the files and brings Resolve forward; explains what went wrong if it didn't work.
    @MainActor
    static func sendAndShow(_ files: [URL]) {
        Task {
            do {
                _ = try await send(files)
                _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            } catch {
                let alert = NSAlert()
                alert.messageText = String(localized: "Couldn’t send to DaVinci Resolve")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}
