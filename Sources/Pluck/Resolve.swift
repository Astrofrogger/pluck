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
    /// together), so the clip plays with it in Resolve. Several files for one clip are all linked,
    /// each adding its channels, and the clip's own sound stays. The sound files go in an "Audio"
    /// bin in the Pluck bin (the link needs them in the project), out of the way of the clips.
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
    audio = None
    if bin:
        audio = next((f for f in bin.GetSubFolderList() if f.GetName() == "Audio"), None)
        pool.SetCurrentFolder(bin)
    def find(path, folders):
        for folder in folders:
            for item in (folder.GetClipList() if folder else []) or []:
                if item.GetClipProperty("File Path") == path:
                    return item
        return None
    def bring(path):
        item = find(path, [bin])
        if item:
            return item
        items = pool.ImportMedia([path]) or []
        return items[0] if items else find(path, [bin])
    def bring_sound(path):
        global audio
        if bin and not audio:
            audio = pool.AddSubFolder(bin, "Audio")
        item = find(path, [audio, bin])
        if item:
            # Brought in before, among the clips: moved to the Audio bin.
            if audio and find(path, [bin]):
                pool.MoveClips([item], audio)
            return item
        if audio:
            pool.SetCurrentFolder(audio)
        items = pool.ImportMedia([path]) or []
        if bin:
            pool.SetCurrentFolder(bin)
        return items[0] if items else find(path, [audio, bin])
    clips = 0
    linked = 0
    for pair in json.loads(sys.argv[2]):
        video = bring(pair["video"])
        if not video:
            continue
        clips += 1
        sounds = [s for s in (bring_sound(path) for path in pair.get("audio", [])) if s]
        # Sent before and linked then: as it is (linking again would add the sound twice).
        if not sounds or video.GetClipProperty("Synced Audio"):
            continue
        done = False
        for sound in sounds:
            for mode in (resolve.AUDIO_SYNC_TIMECODE, resolve.AUDIO_SYNC_IN):
                # Kept: the clip's own sound and what was linked before it.
                if pool.AutoSyncAudio([video, sound], {resolve.AUDIO_SYNC_MODE: mode, resolve.AUDIO_SYNC_RETAIN_EMBEDDED_AUDIO: True,
                                                       resolve.AUDIO_SYNC_RETAIN_VIDEO_METADATA: False}):
                    done = True
                    break
        linked += 1 if done else 0
    if bin:
        pool.SetCurrentFolder(bin)
    print("PLUCK:imported:%d:%d:%s" % (clips, linked, project.GetName()))
    """

    /// Camera clips (a RED clip's folder or any of its files, Blackmagic RAW, other video) into
    /// the open project with their sound linked; returns the project name and how many clips got
    /// their sound.
    static func sendClips(_ clips: [URL]) async throws -> (project: String, linked: Int) {
        let pairs: [[String: Any]] = clips.map { clip in
            let video = cameraFile(clip)
            return ["video": video.path, "audio": cameraSounds(for: clip, video: video).map(\.path)]
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

    /// The .wav files the camera wrote for a clip: in a clip's folder (a RED .RDC, a CinemaDNG
    /// folder) all of them, else those next to it named after it.
    private static func cameraSounds(for clip: URL, video: URL) -> [URL] {
        func wavs(in folder: URL) -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "wav" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        if clip.hasDirectoryPath { return wavs(in: clip) }
        let folder = video.deletingLastPathComponent()
        if folder.pathExtension.lowercased() == "rdc" { return wavs(in: folder) }
        let base = video.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_001", with: "")
        return wavs(in: folder).filter { $0.deletingPathExtension().lastPathComponent.hasPrefix(base) }
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
