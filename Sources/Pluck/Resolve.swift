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

    /// The open project's bins and the bins in each, as JSON (for choosing where clips go).
    private static let binsScript = """
    import sys, json
    sys.path.append(sys.argv[1])
    import DaVinciResolveScript as dvr
    resolve = dvr.scriptapp("Resolve")
    project = resolve.GetProjectManager().GetCurrentProject() if resolve else None
    if project is None:
        print("PLUCK:bins:{}"); sys.exit(0)
    root = project.GetMediaPool().GetRootFolder()
    tree = {f.GetName(): sorted(s.GetName() for s in (f.GetSubFolderList() or []) if s.GetName() != "Audio")
            for f in (root.GetSubFolderList() or [])}
    print("PLUCK:bins:" + json.dumps(tree))
    """

    /// The bins of the project open in Resolve, each with the bins in it (empty when Resolve
    /// isn't reachable).
    static func bins() async -> [String: [String]] {
        let output = await run(binsScript, [])
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix("PLUCK:bins:") }),
              let tree = try? JSONSerialization.jsonObject(with: Data(line.dropFirst("PLUCK:bins:".count).utf8)) as? [String: [String]] else { return [:] }
        return tree
    }

    /// Camera clips with the sound the camera wrote beside them: both imported (each once), and
    /// the sound linked to the clip by timecode (or from their starts, which the camera keeps
    /// together), so the clip plays with it in Resolve. Several files for one clip are all linked,
    /// each adding its channels, and the clip's own sound stays. The sound files go in an "Audio"
    /// bin in the Pluck bin (the link needs them in the project), out of the way of the clips.
    private static let clipsScript = """
    import sys, json, time
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
    # The bin asked for, and the bin in it (when there's one), made where they aren't there yet.
    bin = root
    for name in [n.strip() for n in json.loads(sys.argv[3]) if n.strip()] or ["Pluck"]:
        bin = next((f for f in bin.GetSubFolderList() if f.GetName() == name), None) or pool.AddSubFolder(bin, name) or bin
    pool.SetCurrentFolder(bin)
    audio = next((f for f in bin.GetSubFolderList() if f.GetName() == "Audio"), None)
    # Every file in the project already, wherever it is.
    known = {}
    def look(folder):
        for item in folder.GetClipList() or []:
            path = item.GetClipProperty("File Path")
            if path:
                known[path] = item
        for sub in folder.GetSubFolderList() or []:
            look(sub)
    look(root)
    def bring(path, into):
        if path in known:
            return known[path], False
        pool.SetCurrentFolder(into)
        items = pool.ImportMedia([path]) or []
        pool.SetCurrentFolder(bin)
        if items:
            known[path] = items[0]
            return items[0], True
        return None, False
    def rate(value):
        try:
            number = float(str(value).strip())
        except ValueError:
            return None
        return number if number > 0 else None
    def label(number):
        return ("%.3f" % number).rstrip("0").rstrip(".")
    def note_rate(video):
        # The rate it was shot at, where the Inspector shows it (Comments), when the camera wrote it.
        # (Read a moment after importing: Resolve fills the camera's metadata in by then.)
        camera = (video.GetClipProperty("File Path") or "").lower().endswith((".r3d", ".braw", ".crm", ".mxf"))
        meta = video.GetMetadata() or {}
        for _ in range(15 if camera else 0):
            if meta.get("Camera FPS"):
                break
            time.sleep(0.2)
            meta = video.GetMetadata() or {}
        shot = rate(meta.get("Camera FPS"))
        plays = rate(video.GetClipProperty("FPS"))
        if not shot:
            return
        text = "Shot at %s fps" % label(shot)
        if plays and abs(shot / plays - 1) > 0.01:
            factor = shot / plays
            kind = "slow motion" if factor > 1 else "fast motion"
            text += " · plays at %s · %s× %s" % (label(plays), label(round(max(factor, 1 / factor), 2)), kind)
        comments = (video.GetMetadata("Comments") or "").strip()
        if text not in comments:
            video.SetMetadata("Comments", (comments + "\n" + text).strip())
    clips = 0
    skipped = 0
    linked = 0
    imported = []
    for pair in json.loads(sys.argv[2]):
        video, new = bring(pair["video"], bin)
        if not video:
            continue
        if not new:
            # In the project already (with whatever was done to it there): left as it is.
            skipped += 1
            continue
        clips += 1
        imported.append(video)
        paths = pair.get("audio", [])
        if paths and not audio:
            audio = pool.AddSubFolder(bin, "Audio") or bin
        sounds = [s for s in (bring(path, audio or bin)[0] for path in paths) if s]
        done = False
        for sound in sounds:
            for mode in (resolve.AUDIO_SYNC_TIMECODE, resolve.AUDIO_SYNC_IN):
                # Kept: the clip's own sound and what was linked before it.
                if pool.AutoSyncAudio([video, sound], {resolve.AUDIO_SYNC_MODE: mode, resolve.AUDIO_SYNC_RETAIN_EMBEDDED_AUDIO: True,
                                                       resolve.AUDIO_SYNC_RETAIN_VIDEO_METADATA: False}):
                    done = True
                    break
        linked += 1 if done else 0
    for video in imported:
        note_rate(video)
    pool.SetCurrentFolder(bin)
    print("PLUCK:imported:%d:%d:%d:%s" % (clips, skipped, linked, project.GetName()))
    """

    /// Camera clips (a RED clip's folder or any of its files, Blackmagic RAW, other video) into a
    /// bin of the open project (and a bin in it) with their sound linked; files
    /// already in the project are left out. The rate each was shot at goes in its Comments (shown
    /// in the Inspector), with slow or fast motion. Returns the project name and how many came
    /// in, were there already, and got their sound.
    static func sendClips(_ clips: [URL], bin: [String]) async throws -> (project: String, imported: Int, skipped: Int, linked: Int) {
        let pairs: [[String: Any]] = clips.map { clip in
            let video = cameraFile(clip)
            return ["video": video.path, "audio": cameraSounds(for: clip, video: video).map(\.path)]
        }
        let data = try JSONSerialization.data(withJSONObject: pairs)
        let path = String(decoding: try JSONSerialization.data(withJSONObject: bin), as: UTF8.self)
        let output = await run(clipsScript, [String(decoding: data, as: UTF8.self), path])
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix("PLUCK:") }) else {
            throw Failure.other(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Failure.notReachable.localizedDescription : String(output.suffix(300)))
        }
        let parts = line.split(separator: ":", maxSplits: 5).map(String.init)
        switch parts.count > 1 ? parts[1] : "" {
        case "notReachable": throw Failure.notReachable
        case "noProject": throw Failure.noProject
        case "imported" where parts.count == 6 && (Int(parts[2]) ?? 0) + (Int(parts[3]) ?? 0) > 0:
            return (parts[5], Int(parts[2]) ?? 0, Int(parts[3]) ?? 0, Int(parts[4]) ?? 0)
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

    /// The bin and the bin in it that camera clips went in last.
    static let binKey = "resolveClipsBin"
    static let subBinKey = "resolveClipsSubBin"

    /// Asks which bin (and bin in it), sends camera clips there with their sound and brings
    /// Resolve forward (or says they were all in the project already).
    @MainActor
    static func sendClipsAndShow(_ clips: [URL]) {
        Task {
            let tree = await bins()
            guard let bin = BinChooser(tree: tree).ask(count: clips.count) else { return }
            do {
                let sent = try await sendClips(clips, bin: bin)
                if sent.imported == 0 {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Already in DaVinci Resolve")
                    alert.informativeText = String(localized: "Every clip is in the project “\(sent.project)” already, so nothing was imported again.")
                    alert.runModal()
                    return
                }
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

/// Where camera clips go in Resolve: a bin (one of the project's, or a new one) and, if wanted,
/// a bin in it, each picked from what's there or typed.
@MainActor
private final class BinChooser: NSObject, NSComboBoxDelegate {
    private let tree: [String: [String]]
    private let bin = NSComboBox()
    private let subBin = NSComboBox()

    init(tree: [String: [String]]) { self.tree = tree }

    /// The bin and the bin in it (when one's given); nil when cancelled.
    func ask(count: Int) -> [String]? {
        let alert = NSAlert()
        alert.messageText = String(AttributedString(localized: "Send ^[\(count) clip](inflect: true) to DaVinci Resolve").characters)
        alert.informativeText = String(localized: "Pick a bin of the open project or type a new name, and a sub-bin in it if you like. Clips already in the project are left out.")
        for box in [bin, subBin] {
            box.completes = true
            box.numberOfVisibleItems = 12
            box.translatesAutoresizingMaskIntoConstraints = false
            box.widthAnchor.constraint(equalToConstant: 240).isActive = true
        }
        bin.addItems(withObjectValues: tree.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        bin.stringValue = UserDefaults.standard.string(forKey: Resolve.binKey) ?? "Pluck"
        bin.delegate = self
        subBin.placeholderString = String(localized: "None")
        subBin.stringValue = UserDefaults.standard.string(forKey: Resolve.subBinKey) ?? ""
        fillSubBins()
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: String(localized: "Bin")), bin],
            [NSTextField(labelWithString: String(localized: "Sub-bin")), subBin],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.frame = NSRect(x: 0, y: 0, width: 320, height: 60)
        alert.accessoryView = grid
        alert.addButton(withTitle: String(localized: "Send"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = bin
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        // (Resolve's bin names can't hold a slash.)
        func clean(_ text: String) -> String { text.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces) }
        let chosen = clean(bin.stringValue).isEmpty ? "Pluck" : clean(bin.stringValue)
        let inside = clean(subBin.stringValue)
        UserDefaults.standard.set(chosen, forKey: Resolve.binKey)
        UserDefaults.standard.set(inside, forKey: Resolve.subBinKey)
        return inside.isEmpty ? [chosen] : [chosen, inside]
    }

    /// The bins in the bin chosen.
    private func fillSubBins() {
        subBin.removeAllItems()
        subBin.addItems(withObjectValues: tree[bin.stringValue.trimmingCharacters(in: .whitespaces)] ?? [])
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        // (The new choice is in the list's selection, not yet in its text.)
        if bin.indexOfSelectedItem >= 0, let name = bin.itemObjectValue(at: bin.indexOfSelectedItem) as? String { bin.stringValue = name }
        fillSubBins()
    }

    func controlTextDidChange(_ obj: Notification) { fillSubBins() }
}
