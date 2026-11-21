import Foundation

extension PhotoSelfTest {
    /// The Resolve round trip without Resolve (-PluckScreenshotOnly remoteresolve): proxy ↔ original by
    /// manifest path (same names in other folders), the conform check, the render queue's order and
    /// what survives a restart, check-out rules and versions, the host's project actions over a
    /// loopback pairing, and that the Resolve script compiles. Never runs anything in Resolve.
    static func remoteResolveTest() async {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("RemoteResolveTest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        // Proxy ↔ original, by share + path.
        let entries = ["Day 1", "Day 2"].map { day in
            RemoteManifestEntry(share: "s1", path: "\(day)/A001.MXF", proxy: "\(day)/A001.mov", reel: "A001.MXF", size: 10)
        }
        let manifest = RemoteManifest(host: "h", hostName: "Host", share: "s1", shareName: "Share", entries: entries)
        let proxyRoot = base.appendingPathComponent("Proxies", isDirectory: true)
        let found = RemoteResolveMap.proxies(for: [proxyRoot.path + "/Day 2/A001.mov", proxyRoot.path + "/Day 1/./A001.mov", base.path + "/Other/A001.mov"],
                                             roots: [(manifest, proxyRoot)])
        check("resolve: proxies map to their own original, same names in other folders apart",
              found.map(\.path) == ["Day 2/A001.MXF", "Day 1/A001.MXF"] && found.allSatisfy { $0.share == "s1" }, "\(found)")
        let links = RemoteResolveMap.links(manifest, proxyRoot: proxyRoot, originalRoot: "/Volumes/NAS/Share")
        check("resolve: links carry the host original, the local proxy and a bin per folder",
              links.first?["original"] as? String == "/Volumes/NAS/Share/Day 1/A001.MXF" && links.first?["proxy"] as? String == proxyRoot.path + "/Day 1/A001.mov"
              && links.last?["bin"] as? [String] == ["Share", "Day 2"], "\(links)")
        check("resolve: no host root, no original to link (only an import)", RemoteResolveMap.links(manifest, proxyRoot: proxyRoot, originalRoot: nil).allSatisfy { $0["original"] == nil })

        // A render never replaces an earlier one with the same name (same version twice in a minute).
        let renders = base.appendingPathComponent("Renders", isDirectory: true)
        try? fm.createDirectory(at: renders, withIntermediateDirectories: true)
        for name in ["Edit v1 2026-11-21 10.00.mov", "Edit v1 2026-11-21 10.00 2.mxf"] { fm.createFile(atPath: renders.appendingPathComponent(name).path, contents: Data([1])) }
        check("resolve: a render's name already taken gets the next number", RemoteRenderQueue.freeName("Edit v1 2026-11-21 10.00", in: renders) == "Edit v1 2026-11-21 10.00 3"
              && RemoteRenderQueue.freeName("Edit v2 2026-11-21 10.00", in: renders) == "Edit v2 2026-11-21 10.00")

        // The conform check (pure).
        typealias Clip = RemoteResolveProject.Clip
        let clips = [Clip(id: "1", name: "good", file: "/p/a.mov", frames: 250, fps: 25, audio: 2, timecode: "01:00:00:00"),
                     Clip(id: "2", name: "short", file: "/p/b.mov", frames: 200, fps: 25),
                     Clip(id: "3", name: "mono", file: "/p/c.mov", frames: 250, fps: 25, audio: 1),
                     Clip(id: "4", name: "tc", file: "/p/d.mov", timecode: "01:00:00:00"),
                     Clip(id: "5", name: "gone", file: "/p/e.mov"),
                     Clip(id: "6", name: "kept", file: "/NAS/x.mov"),
                     Clip(id: "7", name: "stray", file: "/elsewhere/y.mov"),
                     Clip(id: "8", name: "title", file: "")]
        let swaps = ["/p/a.mov": "/NAS/a.mxf", "/p/b.mov": "/NAS/b.mxf", "/p/c.mov": "/NAS/c.mxf", "/p/d.mov": "/NAS/d.mxf", "/p/e.mov": "/NAS/e.mxf"]
        let originals: [String: RemoteResolveProject.Original] = [
            "/NAS/a.mxf": .init(duration: 10.02, audio: 2, timecode: "01:00:00;00"), "/NAS/b.mxf": .init(duration: 10, audio: nil),
            "/NAS/c.mxf": .init(duration: 10, audio: 2), "/NAS/d.mxf": .init(timecode: "02:00:00:00"), "/NAS/x.mov": .init()]
        let plan = RemoteResolveProject.conform(clips, swaps: swaps, originals: originals)
        check("resolve: conform swaps every proxy with an original", plan.swaps == ["1": "/NAS/a.mxf", "2": "/NAS/b.mxf", "3": "/NAS/c.mxf", "4": "/NAS/d.mxf"], "\(plan.swaps)")
        let named = ["short", "mono", "tc", "gone", "stray"]
        check("resolve: conform reports length, channels, timecode, missing and offline (not the good, kept or a clip without a file)",
              plan.problems.count == 5 && zip(plan.problems, named).allSatisfy { $0.hasPrefix($1 + ":") }, "\(plan.problems)")

        // Pulled pieces: their timecode must be the original's (none: 0) plus the piece's first frame.
        let pieceClips = [Clip(id: "p1", name: "right", file: "/p/r.mov", frames: 50, fps: 25, timecode: "01:00:06:00"),
                          Clip(id: "p2", name: "wrong", file: "/p/w.mov", frames: 50, fps: 25, timecode: "01:00:00:00"),
                          Clip(id: "p3", name: "zero", file: "/p/z.mov", frames: 50, fps: 25, timecode: "00:00:06:10")]
        let pieceSwaps = ["/p/r.mov": "/NAS/r.mov", "/p/w.mov": "/NAS/w.mov", "/p/z.mov": "/NAS/z.mov"]
        let pieceOriginals: [String: RemoteResolveProject.Original] = ["/NAS/r.mov": .init(duration: 20, timecode: "01:00:00:00"),
                                                                        "/NAS/w.mov": .init(duration: 20, timecode: "01:00:00:00"), "/NAS/z.mov": .init(duration: 20)]
        let piecePlan = RemoteResolveProject.conform(pieceClips, swaps: pieceSwaps, originals: pieceOriginals, pieces: Set(pieceSwaps.keys),
                                                     starts: ["/p/r.mov": 150, "/p/w.mov": 150, "/p/z.mov": 160])
        check("resolve: conform checks a piece's timecode against the original's plus its start", piecePlan.swaps.count == 3
              && piecePlan.problems.count == 1 && piecePlan.problems.first?.hasPrefix("wrong:") == true, "\(piecePlan.problems)")

        remoteResolveUses(base)

        // The render queue: in order, cancel, and what a restart keeps.
        let queueFile = base.appendingPathComponent("queue.json")
        let queue = RemoteRenderQueue(file: queueFile, automatic: false)
        let device = UUID()
        func item(_ timeline: String) -> RemoteRenderQueue.Item {
            .init(project: UUID(), projectName: "P", version: 1, timeline: timeline, preset: "H.264", proxies: [], device: "Mac", deviceID: device)
        }
        let first = queue.add(item("one")), second = queue.add(item("two")), third = queue.add(item("three"))
        check("resolve: queue in the order they came", queue.next?.id == first.id && queue.position(third.id) == 3)
        try? await queue.cancel(second.id, by: device)
        check("resolve: cancelled ones leave the line", queue.position(third.id) == 2 && queue.items.first { $0.id == second.id }?.state == .cancelled)
        check("resolve: another Mac can't cancel it", await { do { try await queue.cancel(third.id, by: UUID()); return false } catch { return true } }())
        let again = RemoteRenderQueue(file: queueFile, automatic: false)
        check("resolve: queue survives a restart", again.items.map(\.timeline) == ["one", "two", "three"] && again.next?.id == first.id)
        var stored = again.items
        stored[0].state = .preparing
        stored[2].state = .rendering
        stored[2].resolveJob = "job"
        try? JSONEncoder().encode(stored).write(to: queueFile)
        let restarted = RemoteRenderQueue(file: queueFile, automatic: false)
        check("resolve: after a restart a render going is followed first, one getting ready starts again",
              restarted.next?.id == third.id && restarted.items.first?.state == .queued, "\(restarted.items.map(\.state))")

        // Check-out rules and versions.
        let store = RemoteCheckout(folder: base.appendingPathComponent("Projects", isDirectory: true))
        func drp(_ text: String) -> URL {
            let file = base.appendingPathComponent(UUID().uuidString + ".drp")
            fm.createFile(atPath: file.path, contents: Data(text.utf8))
            return file
        }
        func refused(_ work: () throws -> Void) -> Bool { (try? work()) == nil }
        let a = UUID(), b = UUID()
        if let (project, version) = try? store.checkIn(nil, name: "Film", share: "s1", file: drp("v1"), by: a, deviceName: "Mac A", keep: true) {
            check("resolve: a new project is version 1, checked out to its Mac", version.number == 1 && project.holder == a)
            check("resolve: others can't check out, check in or release it",
                  refused { _ = try store.checkOut(project.id, by: b, name: "Mac B") }
                  && refused { try store.checkIn(project.id, name: "Film", share: nil, file: drp("x"), by: b, deviceName: "Mac B", keep: false) }
                  && refused { try store.release(project.id, by: b) }, "\(store.projects)")
            _ = try? store.checkIn(project.id, name: "Film", share: nil, file: drp("v2"), by: a, deviceName: "Mac A", keep: false)
            check("resolve: check-in stores version 2 and frees it", (try? store.project(project.id))?.latest == 2 && (try? store.project(project.id))?.holder == nil)
            _ = try? store.checkOut(project.id, by: b, name: "Mac B")
            let restored = try? store.restore(project.id, version: 1, by: b, deviceName: "Mac B")
            check("resolve: restoring copies an earlier version as the newest",
                  restored?.number == 3 && restored?.restoredFrom == 1 && (try? String(contentsOf: store.file(project.id, version: 3), encoding: .utf8)) == "v1"
                  && (try? String(contentsOf: store.file(project.id, version: 2), encoding: .utf8)) == "v2")
            try? store.release(project.id, by: nil)
            let reloaded = RemoteCheckout(folder: store.folder)
            check("resolve: projects and versions survive a restart; the host frees any",
                  reloaded.projects.first?.versions.map(\.number) == [1, 2, 3] && reloaded.projects.first?.holder == nil)
        } else {
            check("resolve: check-in of a new project", false)
        }

        // The Resolve script compiles (no Resolve needed).
        let pythons = ["/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Applications/ResolvePython", "/Library/Developer/CommandLineTools/usr/bin/python3"]
        if let python = pythons.first(where: { fm.isExecutableFile(atPath: $0) }) {
            let script = base.appendingPathComponent("remote_resolve.py")
            try? RemoteResolveScript.script.write(to: script, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-c", "import py_compile, sys; py_compile.compile(sys.argv[1], doraise=True)", script.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try? process.run()
            process.waitUntilExit()
            check("resolve: the Resolve script compiles", process.terminationStatus == 0, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        } else {
            skip("resolve: the Resolve script compiles", "no Python on this Mac")
        }

        await remoteResolveLoopback(base)
    }

    /// Read only, against the real DaVinci Resolve (-PluckScreenshotOnly resolveuses): what the open project
    /// reaches (media pool files, Fusion and grade files, expressions, scripts, unchecked parts) and what the
    /// host would refuse, with PLUCK_USES_SHARE (a folder) as the only share. Never starts Resolve or renders.
    static func resolveUsesDump() async {
        do {
            let found = try await RemoteResolveScript.run(["action": "uses"])
            let data = (try? JSONSerialization.data(withJSONObject: found, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            note("uses of \(found["project"] as? String ?? "?"):\n" + String(decoding: data, as: UTF8.self))
            let roots = ProcessInfo.processInfo.environment["PLUCK_USES_SHARE"].flatMap { RemoteEditHost.realPath($0) }.map { [$0] } ?? []
            for problem in RemoteResolveProject.uses(found, roots: roots, builtIn: RemoteResolveProject.builtInRoots, readable: { _ in true }) { note("refused: " + problem) }
            check("resolveuses: read the open project", true)
        } catch {
            skip("resolveuses: read the open project", error.localizedDescription)
        }
    }

    /// What Fusion and grades reach, as the Resolve script reports it (mocked): kept in the shares, symlink
    /// and `..` escapes, Resolve's own content, writes, scripts, expressions, full trust, and old rights.
    private static func remoteResolveUses(_ base: URL) {
        let fm = FileManager.default
        let share = base.appendingPathComponent("Share", isDirectory: true), outside = base.appendingPathComponent("Outside", isDirectory: true)
        let builtIn = base.appendingPathComponent("Resolve/Fusion", isDirectory: true)
        for folder in [share, outside, builtIn] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        for file in [share.appendingPathComponent("a.mov"), outside.appendingPathComponent("secret.txt"), builtIn.appendingPathComponent("title.png")] {
            fm.createFile(atPath: file.path, contents: Data([1]))
        }
        try? fm.createSymbolicLink(at: share.appendingPathComponent("link"), withDestinationURL: outside)
        let roots = [RemoteEditHost.realPath(share.path) ?? share.path], resolve = [RemoteEditHost.realPath(builtIn.path) ?? builtIn.path]
        func problems(_ found: [String: Any], trusted: Bool = false) -> [String] {
            RemoteResolveProject.uses(found, roots: roots, builtIn: resolve, trusted: trusted, readable: { _ in true })
        }
        func ref(_ path: String, regid: String = "Loader", lut: Bool = false) -> [String: Any] {
            ["refs": [["item": "Title 1", "tool": lut ? "LUT" : "Loader1", "regid": lut ? "" : regid, "path": path, "lut": lut]]]
        }
        check("uses: a Loader in the share, a new file in it and Resolve's own title pass",
              problems(ref(share.path + "/a.mov")).isEmpty && problems(ref(share.path + "/Renders/new.mov", regid: "Saver")).isEmpty
              && problems(ref(builtIn.path + "/title.png")).isEmpty)
        let unshared = problems(ref(outside.path + "/secret.txt"))
        check("uses: a Loader outside the shares is refused, naming clip, tool and path",
              unshared == ["Title 1 (Loader1) loads \(outside.path)/secret.txt, which isn’t shared with this Mac."], "\(unshared)")
        check("uses: a symlink out of the share is refused", problems(ref(share.path + "/link/secret.txt")).count == 1)
        check("uses: a .. out of the share is refused (also past a missing folder)",
              problems(ref(share.path + "/../Outside/secret.txt")).count == 1 && problems(ref(share.path + "/missing/../../Outside/x")).count == 1)
        check("uses: writing into Resolve's own content is refused", problems(ref(builtIn.path + "/evil.setting", regid: "Saver")).first?.contains(" writes ") == true)
        check("uses: a tool not known to only read can't use Resolve's own content (it may write there)",
              problems(ref(builtIn.path + "/title.png", regid: "KD_TextFromFile")).count == 1 && problems(ref(builtIn.path + "/title.png", regid: "uTexture")).isEmpty)
        check("uses: a file input left relative is refused", problems(ref("footage/a.exr")).count == 1)
        let dangling = share.appendingPathComponent("dangling")
        try? fm.createSymbolicLink(atPath: dangling.path, withDestinationPath: outside.path + "/not-yet.txt")
        check("uses: a dangling symlink in the share is refused", RemoteResolveProject.hostPath(dangling.path) == nil && problems(ref(dangling.path)).count == 1
              && problems(ref(dangling.path + "/deeper.mov")).count == 1)
        check("uses: relative LUTs are Resolve's; one climbing out is refused",
              RemoteResolveProject.uses(ref("Sony/SLog3.cube", lut: true), roots: [], builtIn: RemoteResolveProject.builtInRoots, readable: { _ in true }).isEmpty
              && RemoteResolveProject.uses(ref("../../../../../../etc/hosts", lut: true), roots: [], builtIn: RemoteResolveProject.builtInRoots, readable: { _ in true }).count == 1)
        let unreadable: [String: Any] = ["unchecked": [["item": "Compound Clip 1", "why": "compound"], ["item": "Title 2", "why": "comp"]],
                                         "scripts": [["item": "Title 3", "tool": "Text1"]]]
        check("uses: unreadable parts and a render script are refused", problems(unreadable).count == 3, "\(problems(unreadable))")
        let safe = ["Point(Transform1.Center.X, 0.5)", "iif(time > 10, 1, 0) * math.sin(time / 25)", "Text(\"Day \" .. floor(time))", "Text1.Size * 2"]
        let unsafe = ["io.open(\"/etc/hosts\"):read(\"*a\")", "Text(os.date())", "comp.Execute(comp, \"x\")", "comp:Execute(\"x\")",
                      "_G[\"i\" .. \"o\"]", "(function() return 1 end)()", "Text1.StyledText.Value.rep(\"x\", 2)", "Text1.Execute\"x\"",
                      "loadstring(\"return 1\")()", "Text(Point)(1)", "math.Execute(1)", "require \"x\""]
        check("uses: plain expressions pass", safe.allSatisfy(RemoteResolveProject.safeExpression), "\(safe.filter { !RemoteResolveProject.safeExpression($0) })")
        check("uses: expressions that could reach files or programs are refused", !unsafe.contains(where: RemoteResolveProject.safeExpression),
              "\(unsafe.filter(RemoteResolveProject.safeExpression))")
        let everything = ref(outside.path + "/secret.txt").merging(unreadable) { a, _ in a }
        check("uses: full trust skips the check", problems(everything, trusted: true).isEmpty && problems(everything).count == 4)
        remoteResolveScriptMock(base, share: share)
        let old = Data(#"{"browse":true,"proxies":false,"originals":true,"render":true}"#.utf8)
        let rights = try? JSONDecoder().decode(OfficeRenderServer.Device.Rights.self, from: old)
        check("uses: rights saved before full trust keep theirs, full trust off",
              rights == .init(browse: true, proxies: false, originals: true, render: true, fullTrust: false), "\(String(describing: rights))")
    }

    /// The Resolve script's own "inspect" run on a mock DaVinciResolveScript module (plain Python, no Resolve):
    /// Run Command and UserControls Lua found, file inputs kept as they are, title text and comments not taken
    /// for paths, expressions inside text inputs found, only the presets the host had before, the exported
    /// project read (real comp and grade blobs from Resolve 21.2: a Loader, Run Command, Text+, a MediaIn, a LUT;
    /// paths made neutral), a broken blob refused, and multicam clips flattened in a copy of the timeline.
    private static func remoteResolveScriptMock(_ base: URL, share: URL) {
        let fm = FileManager.default
        // Never Resolve's own Python: its bundled DaVinciResolveScript comes first and would reach a running Resolve.
        // One with compression.zstd (3.14, as Resolve's) reads grades too.
        let pythons = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/Library/Developer/CommandLineTools/usr/bin/python3"]
            .filter { fm.isExecutableFile(atPath: $0) }
        func hasZstd(_ path: String) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            // (And no DaVinciResolveScript of its own, so only the mock can answer.)
            process.arguments = ["-I", "-c", "import compression.zstd, importlib.util, sys; sys.exit(importlib.util.find_spec('DaVinciResolveScript') is not None)"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
        guard let python = pythons.first(where: hasZstd) else {
            return skip("uses: the script on a mock Resolve", "no Python 3.14 here")
        }
        let modules = base.appendingPathComponent("MockModules", isDirectory: true)
        try? fm.createDirectory(at: modules, withIntermediateDirectories: true)
        try? Data(base64Encoded: resolveDrpFixture)?.write(to: modules.appendingPathComponent("exported.drp"))
        let mock = #"""
import os, re, shutil, zipfile
FIXTURE = os.path.join(os.path.dirname(__file__), "exported.drp")
class Comp:
    def GetToolList(self, selected): return {1: "tool"}
    def MapPath(self, path): return path
    def GetPrefs(self, name): return {"Comp": {"Paths": {"Map": {"Temp:": "/tmp"}}}}
    def CopySettings(self, tools):
        return {"Tools": {"Template": {"__ctor": "GroupOperator", "Tools": {
            "Text1": {"__ctor": "TextPlus", "Inputs": {"StyledText": {"Value": "/r/videos", "Expression": "Text(os.date())"}}},
            "Note1": {"__ctor": "Note", "Inputs": {"Comments": {"Value": "Hi"}}, "Comments": "/not/a/file"},
            "Loader2": {"__ctor": "Loader", "Clips": {"1": {"__ctor": "Clip", "Filename": "footage/a.exr"}}},
            "Loader3": {"__ctor": "Loader", "Clips": {"1": {"__ctor": "Clip", "Filename": "/Volumes/Other/x.mov\n"}}},
            "RunCommand1": {"__ctor": "RunCommand", "Inputs": {"FrameCommand": {"Value": "curl evil"}}},
            "Ctl1": {"__ctor": "Transform", "UserControls": {"Go": {"BTNCS_Execute": "io.open('/etc/hosts')"}}}}}}}
class Graph:
    def GetNumNodes(self): return 1
    def GetLUT(self, n): return "Sony/SLog3.cube"
    def GetToolsInNode(self, n): return ["LUT: Sony/SLog3.cube", "OFX: Film Grain", "Primary Balance"]
class OfxEffect:
    def GetInfo(self): return {"id": "com.example.Sparkle", "name": "Sparkle"}
class Clip:
    def __init__(self, kind): self.kind = kind
    def GetClipProperty(self, key): return {"File Path": "" if self.kind == "Multicam" else "/Volumes/Share/a.mov", "Type": self.kind}.get(key, "")
    def GetUniqueId(self): return "id-" + self.kind
    def GetName(self): return self.kind
class Item:
    def __init__(self, name, kind, clip=None): self.name, self.kind, self.clip = name, kind, clip
    def GetName(self): return self.name
    def GetType(self): return self.kind
    def GetFusionCompCount(self): return 0 if self.clip else 1
    def GetFusionCompByIndex(self, i): return Comp()
    def GetEffects(self, kind): return [OfxEffect()] if kind == "ofx" and not self.clip else []
    def GetMediaPoolItem(self): return self.clip
    def GetNodeGraph(self, layer=None): return Graph()
    def FlattenMulticam(self, grade):
        if os.environ.get("MOCK_FLATTEN_FAILS"): return False
        self.clip = Clip("Video")
        return True
class Timeline:
    def __init__(self, name, items): self.name, self.items = name, items
    def GetName(self): return self.name
    def GetMediaPoolItem(self): return None
    def GetNodeGraph(self): return None
    def GetTrackCount(self, kind): return 1
    def GetItemListInTrack(self, kind, n): return [i for i in self.items if (i.kind == "audio") == (kind == "audio")]
    def DuplicateTimeline(self, name):
        copy = Timeline(name, [Item(i.name, i.kind, i.clip and Clip(i.clip.kind)) for i in self.items])
        project.timelines.append(copy)
        return copy
class Folder:
    def GetClipList(self): return [Clip("Video")]
    def GetSubFolderList(self): return []
class Pool:
    def GetRootFolder(self): return Folder()
class Project:
    def __init__(self, name, presets):
        self.name, self.presets = name, presets
        self.timelines = [Timeline("Edit", [Item("Title 1", "video"), Item("Cam", "video", Clip("Multicam")), Item("Cam", "audio", Clip("Multicam"))])]
    def GetName(self): return self.name
    def IsRenderingInProgress(self): return False
    def GetRenderPresetList(self): return self.presets
    def GetTimelineCount(self): return len(self.timelines)
    def GetTimelineByIndex(self, i): return self.timelines[i - 1]
    def GetMediaPool(self): return Pool()
    def GetSetting(self, key): return "1"
    def GetColorGroupsList(self): return []
project = None
class PM:
    # A leftover copy of an editor's project is open: its presets aren't the host's.
    current = Project("Pluck – old – 1234", ["H.264", "Evil"])
    def GetCurrentProject(self): return self.current
    def CreateProject(self, name):
        self.current = Project(name, ["H.264", "ProRes"])
        return self.current
    def DeleteProject(self, name): return True
    def GetProjectListInCurrentFolder(self): return []
    def GotoRootFolder(self): return True
    def SaveProject(self): return True
    def CloseProject(self, p): return True
    def ImportProject(self, path, name): return True
    def ExportProject(self, name, path, stills):
        if os.environ.get("MOCK_BROKEN_BLOB"):
            text = re.sub(r"<CompositionBA>([0-9a-f]{8})78", r"<CompositionBA>\g<1>00", zipfile.ZipFile(FIXTURE).read("SeqContainer/fixture.xml").decode(), count=1)
            with zipfile.ZipFile(path, "w") as z: z.writestr("SeqContainer/fixture.xml", text)
        else:
            shutil.copy(FIXTURE, path)
        return True
    def LoadProject(self, name):
        global project
        project = self.current = Project(name, ["H.264", "Evil"])
        return self.current
class Resolve:
    FLATTEN_MULTICAM_COPY_GRADE = 1
    def GetProjectManager(self): return PM()
def scriptapp(name): return Resolve()
"""#
        try? mock.write(to: modules.appendingPathComponent("DaVinciResolveScript.py"), atomically: true, encoding: .utf8)
        let sent = base.appendingPathComponent("sent.drp").path
        func inspect(_ environment: [String: String] = [:]) -> [String: Any]? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-I", "-c", RemoteResolveScript.script, modules.path]
            process.environment = environment.merging(["PATH": "/usr/bin:/bin"]) { a, _ in a }
            let output = Pipe(), input = Pipe()
            process.standardOutput = output
            process.standardError = output
            process.standardInput = input
            guard (try? process.run()) != nil else { return nil }
            let instruction: [String: Any] = ["action": "inspect", "name": "P", "drp": sent, "timeline": "Edit", "label": "Film"]
            try? input.fileHandleForWriting.write(contentsOf: (try? JSONSerialization.data(withJSONObject: instruction)) ?? Data())
            try? input.fileHandleForWriting.close()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix("PLUCKJSON:") }),
                  let found = try? JSONSerialization.jsonObject(with: Data(line.dropFirst("PLUCKJSON:".count).utf8)) as? [String: Any],
                  found["error"] == nil else {
                note("mock Resolve answered: " + String(text.suffix(400)))
                return nil
            }
            return found
        }
        guard let found = inspect() else { return check("uses: the script on a mock Resolve", false, "no answer") }
        let refs = found["refs"] as? [[String: Any]] ?? []
        let scripts = Set((found["scripts"] as? [[String: Any]] ?? []).map { "\($0["item"] ?? "")/\($0["tool"] ?? "")" })
        let paths = Set(refs.compactMap { $0["path"] as? String })
        check("uses: Run Command and UserControls Lua are found (API and exported project)",
              scripts == ["Title 1/RunCommand1", "Title 1/Ctl1", "Film/RunCommand1"], "\(scripts)")
        check("uses: file inputs are kept as they are (relative, with a newline); title text and comments aren't paths",
              paths.isSuperset(of: ["footage/a.exr", "/Volumes/Other/x.mov\n", "Sony/SLog3.cube"]) && !paths.contains("/r/videos") && !paths.contains("/not/a/file"), "\(paths)")
        check("uses: the exported project's comps, media and grade LUT are read from Resolve's own blobs",
              paths.isSuperset(of: ["/Volumes/Elsewhere/x.png", "/Volumes/Elsewhere/y.png", "/Volumes/Share/a.mov", "/Volumes/Share/d.mov", "ACES/LMT ACES v0.1.1.cube"])
              && (found["unchecked"] as? [Any])?.isEmpty == true, "\(paths) \(found["unchecked"] ?? "")")
        let fonts = RemoteMissing.fonts(found), effects = RemoteMissing.effects(found)
        check("uses: fonts of Text+ in the exported project are found (family and style)",
              fonts.contains(.init(family: "Open Sans", style: "Semibold")), "\(fonts)")
        check("uses: effects on items and in grades are found (OFX by id and name, and as the node shows them)",
              effects.contains(.init(id: "com.example.Sparkle", name: "Sparkle")) && effects.contains { $0.name == "Film Grain" }
              && (found["unchecked"] as? [Any])?.isEmpty == true, "\(effects)")
        check("uses: the sent project's exported copy is removed", !fm.fileExists(atPath: sent + ".check.drp"))
        let problems = RemoteResolveProject.uses(found, roots: [share.path], builtIn: RemoteResolveProject.builtInRoots, readable: { _ in true })
        let expected = ["Music.wav loads /Volumes/Elsewhere/plugin.preset", "Music.wav loads /Volumes/Elsewhere/reverb.ir", "Title 1 (RunCommand1) runs", "Title 1 (Ctl1) runs", "Film (RunCommand1) runs", "Title 1 (Text1) has an expression",
                        "Title 1 (Loader2) loads footage/a.exr", "Title 1 (Loader3) loads /Volumes/Other/x.mov\n", "Film (Loader1) loads /Volumes/Elsewhere/x.png",
                        "Film (Loader1) loads /Volumes/Elsewhere/y.png", "Film (MediaIn1) loads /Volumes/Share/d.mov"]
        check("uses: the host refuses exactly the scripts, the expression and the files outside the shares (a media pool clip and Resolve's LUTs pass)",
              problems.count == expected.count && expected.allSatisfy { start in problems.contains { $0.hasPrefix(start) } }, "\(problems)")
        check("uses: audio-track blobs are searched for paths (inflated UTF-16, and one that doesn't decode); the project's own folders and a clip's folder pass",
              paths.isSuperset(of: ["/Volumes/Elsewhere/plugin.preset", "/Volumes/Elsewhere/reverb.ir"]) && !paths.contains("/Users/editor/Movies/CacheClip")
              && refs.contains { $0["item"] as? String == "Music.wav" }, "\(paths)")
        check("uses: only render presets of an empty host project are offered (not a leftover copy's)", found["presets"] as? [String] == ["H.264"], "\(found["presets"] ?? "")")
        check("uses: a timeline with multicam clips renders from a flattened copy",
              found["render"] as? String == "Edit (Pluck render)" && found["timelines"] as? [String] == ["Edit"], "\(found["render"] ?? "")")
        let broken = inspect(["MOCK_BROKEN_BLOB": "1"])
        check("uses: a comp blob that doesn't decode is refused",
              RemoteResolveProject.uses(broken ?? [:], roots: [share.path], builtIn: [], readable: { _ in true }).contains { $0.hasPrefix("Film: its Fusion composition") },
              "\(broken?["unchecked"] ?? "")")
        check("uses: multicam clips that don't flatten stop the render", inspect(["MOCK_FLATTEN_FAILS": "1"]) == nil)
    }

    /// A project exported by DaVinci Resolve 21.2 (zip), cut down to one SeqContainer with its <CompositionBA>
    /// blobs (Text+, a Loader, Run Command, a Loader with a MediaIn), a grade <Body> with a LUT and a
    /// <MediaFilePath>; the paths in it were made neutral and the comps compressed again in Resolve's layout.
    /// Added by hand: an audio track blob (zlib, UTF-16) and one that doesn't decode, each naming a file outside
    /// the shares, a clip folder blob, and project.xml settings with Resolve's cache folder.
    static let resolveDrpFixture = "UEsDBBQAAAAIAIsMcF3rO74zZgAAALUAAAALAAAAcHJvamVjdC54bWyzCc4NKMrPSk0usbNxy0zNSSl2yslPsjOAAEMDA6M0AwNTUwMDc2MDAzMQbQRhg8RBfDMTILYEioHoNIg8SM4kBco3g8ibmSL0mYDMApptBqItIHJgsWSoWWDLbfSRHGSjj3AoFwBQSwMEFAAAAAgAiwxwXX5ca0w2FgAApiYAABgAAABTZXFDb250YWluZXIvZml4dHVyZS54bWyNmluPXbeRhd/1Y9K8X4CGgDhA3hIEyCDvRbKINEa2JpadIP8+39otGWPAD5HdUp9zdu9NFletC9mvf/V//OHzDz/Z2w/+48cPr3/y82Z/fPvkf7Gf/v7x5W+fP/38vX95+evf7Ud/sd99//mfry+/vubD6x8+f/9/n7+8/fT2+Yfvfv8x6E87t49j7dQcZg0xtx5L9XBHSbZrXCXmXVKy4NV6mqntmEZcMYZQSvQaxuwpDZtrn3hXmrnlnd1Dsxh3SM2sR2+hRBu1jMKzzE7qtcawQgmHb9Iu3VYKbZTeEg+xY8lqMptnxVrXvtZuSMO33zLvPb2fe9fx2/lazGHdm1IYmZuUOMONPZRbSg+jlJL2GGG2aCG32Joz1hlnjCnxb9glhpQZ6c5ljdZSLrZHrim1doc1ppq6xVBDTok5ldLKyislT7uekDu3CHPkc2etwVI7M6aeYsp7UaAZqGzYZ3NTT1S4eFplWp7TCj/XUihn7sKnJ5VUKRovSkyl7RCmhzD6ySNZCydRdMo4Z011pDDzqLEEK75auKmfwgvLced742CYaZRQS648eOc6i1OMPKJR8c1tWe26mdUpcZiPm3NbGUzYTon55zJb4j4hxJ5KOaxNoIg9eQ6AZIGVYB6ocV6xj83TYmaZqGObZYQ8Q/Oj8rEQaXsa686SFqDh0rKmnjVbaDwoxrYb/8c2fKQy0pwjlki11uSpx6anMgcrGBcwXTscUFR6vCevEqjrohjJlgnEuVr2drg2NW+32QrW+cAYauZmi5s0VjK1WABWaWNZGuE0c648PGHWSE3yyiUbNckLZLe8ahrgf+deR6i+Uz27x5ZscG2Lh4lZACNjsvyq4slB9Vss5c5tXpVSK7hG2al43vOUZimWa9y/jD7jcPDhcc9cmM9JQJCf0D3ptagfNoERmNYA4gJlLncwExrH6070hNdLqTIPpilKTha5fMfQVqdzuSZyW0AoAphgIlHy9MDk5sjLpacx71gXi5acl6WOMwLYPK21s6YgkKe4oOVcgDONGKhZmXN6i7BA6mHvA2QOF5162gwxzJRTo4bjMBrmzY+GUXfMa7fFVFdafXZWBv4AAPOcRS0ANqt3qNkZowyACPc0gMPtbQr5I9KIIbOIwJ8uzatpSnV3eph/gUbuzsq0kXeEncq4oD8HbqJWD72He3wMUFq2JkQhAGa+89CWLdEbK9Kw1PnmMUbP03kkd8gbuuRiCKQvplXMy11h9m3D9qpMh75kphE266ftTotMWpQ1hHknb3TvwlesIiyevXRZO2fsPG6Y8ax2LbJS89acDco8gI2xlTzrGGt1FzYX157pi3bkemDMDU63vunNsW+PfdXCbCh3sV4ynXN7Nlurej1jHsg7X4PEZobCdlxHBHP6hlFgze0FEMHAg0fU0gKoozH6rQNOj3d4Z3j1mqd64btlLipiMrHmcwSMWXbzIXKfxS7/rzbFHAiQ7btG7PnM3iFS3zHOO+40v356avV6yJWHgcFeDj1ToC737vMe47sxzgrtdgq35oIiZzrM/8ZEncxuy/356SjFqnSW0y9r5YuuTLomjjR6q6zhyb5PGKsbt4c+8oAxnYaGRs/MLPwMXGdTjbsK6oMuOa01T8zQxjqA+fR5al+BGtPPCNbsy+A4FBXeuK2mCPum2RFDsLe0RDXXmueCUSgiazO8+b1lbRr3pLVK9wUSi0QRtZWmBs+tuHu+Kpf1ADINimUMhmrSgn7bAfXH8zp7MSbgGjrLviE68B+pt126fN0mUYsXkHu3ybyiWAZJQ5tAV0rroqTo+HG0vlH6yeKi/R3KP5m6NNqFKTH3bWdDrMjY2F3strRWB0CeUIHNqfDhDdAnDSC96IXWsYSy8pRTaZZKR0apSS3MnYrQe/XWFW2xlJPO4F2wT0c/fZS4wCa6RiNcnrMuD8nXobg5Lp241SQ71FrvciFAA5s1syzNWlI9OxbAF0vQC2vXW6kMaZaOkqyae96w4Ya/Nw13CoKCdES6Nw/aCUTwowslpT+n773vzEzON/NAN4HnHGfe9dwwmxQkUEOnUXElt03Ken2ElWN2C8xoAM3b+InIvW51x+MsxGcmWuWgKkZPUEcmC+gncHfQkSqPOPgFlzGCrjt1q6wymjigsNpZfC6e3CzebbfSaoFG22Z73ikqS3BBgJdxVzQwjH3K3pOOAkaijQx4ULnR74kAvfso3qrREWM3KWi6cEXmEWgjUMA49IwPsNbHfZR2nwu9aN2wg3ggFoEuYAGTHzMWHVrYkAaDuHtRGCobfVpkrLTqaMgiS94diTCmT190VptPF66EkhjWAbqVW8KiRe4FK21qaVBG7CK06gvZAKpwA+s7ob8MpS1sXcUYMYVQ4RvKxWof8edFDvtO2B0WB5dTcRpTWCqhLPnBiTfR5LGtzH5Sf/wYMh0RjnD89eXXPvw3fTmm96svxyIzz11wetNNY0CWBywbMVDQGOYmwr6rQ3qo5RIQ8AmgcVlRa698OtIB3aBWE+cK5/E+Fx59hPgk2idVuaQ6eN9k1augDb9hO2A/uVpExJhhHOhUpOnxIljAg0tHZ8FPzGEjtKucu3EB3GgWLJwkmKKxSg096e+WHQolQGCW+LNx44h8Y+mVKUAV/2ysVFULMXeSgqwMBUgzhD4GN4cAJfe7ZJwvLhR3Km968QFjNDkbp34Teq2m+GEnAkV8IhYHluOTjS/ALFYHtQWZGy0sZY+GPGzx3s2sfIbKQ+POIMQTGWiRJiDcgIVvuBK0NEEZ9FKT3d4oIUQGNJOhJWmCndR7wilA5bgi1zOJLuIFZlMKjmPc07i3gaOEWca6qA3AEBQ08OuECRNKqQLdgVZWBIU4kEkttDw9h5Ol2dtq+FE8VJu1KVMkhs5i4/kPU8TcN4MhIh4a+2fz6XRAistDDmL1iFll2dfGvKOQBBD0lUwScSAAn6FgEVhgCI1BRBiPKxBPBjzhDda7o9BpTOMKutvIevA5t4Owzt7qrL1yxVVA9l3ghengwMlHLTekLQp0JwMpfD/CQtm4dIVrmQ7GdJD9BsYGlC4wir1GuRDWCq+g8rQjgEGeyWMALKo2WPkNA2S0CYodChsHFwocQMg5RfyPmqI9nbESNAqpTuU32r8G9EwBssvgwUzNUVckiRGDzIWp7U1TZA4dTweZw1RIQ0NnociAZ0AT8FIIGo1woXnUKGVSNZTKAs0+AV0rmBRWvldZeia7gAJmqxAfO5cqgFHTUnljQ0nhkln0QZg2LgCnEoHXkbxFlxfCdyQF4Opx8KZ4e2XzCQgZoUceb0fdMZyIFLe0p8DY40vrwAYgsEChaREUx6I9EkihX1k1CgsF0KdEHOCulgENUwAEXOFpLTIrdoACZu4OmGEthgkPdj0v4TJgcxQb2oQXL2+LN2Z5wh/LhiLiEckO40noxAqeUfA9tU9SAI6E3EkfVj0TvmjyzAUkkhTAe+0AE2Bj2kxLxTCIlJLkPCb2lRlBKlj7xeN4IOb3NrQXGJLUYAKWBSIht/ETDdEqyqaMa5MiYJt7MN9Lwkx6Jh8ZBof2TfkwC6/O57jGE5bvGbprTwX/gngfnD3XnApG6rhoZTcUKTse2ZnWODwdjSsBU8sfRDDSnHfRXY0Fg8hJVSQtqorak2nRMAzLklhkX/hpChm5iTYUSrgFCkEye3DYAYsuXlaC75ix62B4X8e9Y1/7hrWZ1Im6ldqskCJw73igPCTceAyClkFTFWHz6GgDby/yHJkWImSC5BGmyuMCFWK27UarSoy89IML6cwQO+ObPjgy95h3BEF+yOUgCCmQBuhYw5ByslbfTZkd/HLxoFFYClW/Ft6ZGQuBT6QGOeIS8u5E6dMyyEg45ohPrXTjobURvYVrw5JoZ6gQi7DTrB3ttzsBB3DRpFfm5OKNifgY3MsDeBpODqHBMkIe2Ka+EQlzafsmpiEYzOjaxcITr1CmdRiXfBZGlQuaY9LIMkNuVMSuSjDHRU+RZjG7OPDu8chuIOH0H4uFccLRY/2FXIhtsd5IB/JBNAVb6b9zEv0XJ6FYqc5FlS+RHZ+C14f4UVTF6lafbSaGTBzVX70DpiR/j6sl/8Hq1UcFwUvbWgwN5mP4S5czILAIL2p5C3yj5cRJnIGVeDJPx41DV5XG1uaE7BrOZU7tQmrHgeoWxOZuz6Gj16iK0sMRqWKs00T484SyZSFYkqt9P21Y4ZeXphqRPWAag3QBmQt7BBwPjoFwQPAKOwxtAUErkY+gYCzt0N4eOjwbkI68VookYYgABj4WPhyDRqZgNYie97stwsvj4LEtKBQ+Ax4ByZCPYTQCYRf+xJpEPJr2ozATEAJmgkgm+w3/bCLAZJwiSlo0xqUNFeljymC0El2IergIqofNxZopuiZSqbw9WQObB+agMcZ2qFTShiwtn1gvuFdEiTSzRNgzepRSkTZQazKPDRWJUJ3ToXtni1SOAWxohjl5JFvQt5gIJrSGvAT+qjI2vET85iUwNngwemjISwTUpMKICahrbzgoSw2iLcH8YFDgIMdBDKQX1QByNCAZAmVYhh/EdzXYFhDh62VBSRUkALx9OAWiAosLpxC1HyTIMKJyN7wJKbJQrBHI2phcGJDA3o5WBlYIRWIPU2Vtri7HhIJ7FD6kcs8m/lbSCUEB90eTMU5CJq53yVs0QjPaZLgcqods0OJlROYXMRuylQT3qog3H/etXbrKfTBuvRYYpEBHkFO3ugEghbqZtE6wl92A55F57SZakFVsxzzixHkjT9kGFBsPgMu82sgcGFF0W+I+vCRCTUc0MMnoCuWm7HhvaCkV7Bx5y67CCA0DmgEn0NZqkdXGo/hFCgGENkYWY+EYKJAdHZVnGqjTELqzNv0cUJMNiI9d+304r6lOuTRKmLj3HRgTnnVpOujCsxEHq7i2cJc2vS+2E2nGxuDoij7fzzAGHovWTooq0MUEc7SD8IPNKCJQWps5tRIbfY71htVZoZiQs3IolWpBVMZ0zE7eoBIHZ2dyT7A96G3aXCWdJOKn8kSylLJYH7OC26S0aCo1ADhQiMu/gukcMo4RU6FmY/FpZ23wwZA4Te1WZ2FlbAwZFIVykMLCxj6SsqEKpqAdtinXYoQs9KOOnFlD6oilAjAWscPPYQtJ+w6p4BSgr/aZLgkP8FtD9dAp7WuRVG/EkkhRtKDF8QqPwiUk70o7IGVoAwQ45oC1Ry0c/Ryj68CENulEeUHPr8IjfI3JW9ohTkhYxkE1dAeyxK0ojJPsoQoaHCyiPjAPwRviunANxgGDE1Wo06kB9sAdXwcMiCd8wH15OuNzeglBJhoEh24bZZXRk//B51aiqukGeAQWBGl0r9N5ctVOF8mxql+fTVG9QbDeAWsCCnAGl3ljxEm1N3hEhqkE4kY8vgm1tEnJLr4OU0VIp+2AjY52YDDqGVsH08sbP0y0qjVShlvpkHoLXAE4KWFKMA5GJjNONS74H2hVRvJobgBw9m0VrFx6gPdQGyw6SQfJx7ljgFbU9iwE4oANXb0qFBQPiaDo/TAG3BPsACO5tqYW60fEOdr53edBNPFCe53AnyJsZ0TWoC6cxu54BTzzxV2PefqF8JEHKQRjqpVhN23Oe9ZJmrBN2Tc8siQ5hAb6cW4sOm70yhbK8nCbzGOVmNDtewklQekt5f/KdcAt384VgfTCdcAY9NrVPqphEjDn6KujUmebjmouWRvBI6pYawm4QitRko+qQNW4FxxTb9tkasOpEiiiLSoGW8wmEF6CIqLDF3EM2oa4fHp/dlOXYsmQPq4igXJt9WZ9Z9hsndeRNWotG09hzypo93axOtAgvT+G/o44dpSa6FNcp6ERsmCWEQSYzq3w3sTWiML6JDWHhjtPPomOAJIMru29wRTHbmAdUUB4hmdHNOK2jExmRI4gObguEKqwMLQm6TPiO4h2cPRRpCIU3520O0wGxVUl8E3FkfuCb9TxpZwD6ju29Ifuo+14FoGrLlRgPgkVkta5I42ArgJhlBK5hVdpXF4EneYQV5WvwbQy6dIeh+LwwlxPvBkEgkCLAS52jtsi80cbsBDvwHFBZNJR5OzokKXqNIqfxeQTqxulMRYkExfRAm0aBG6mE5b+6KJOQXRuQajWsdNFIljcIONaUUWyGRaKXtRyW2K5O10cprY7UHRt+aH6h2YkxgfcPyPS4ZpvuN9xSyGSRWEJyASV5Bb0XZjQ4lKmMLIR9SaqGJG9MdKmffO6hizEhOqPduUKjZh1EhiQUGwQGKCvUqD/sCCswW1EWMgLN7SgJjwUrcTIUUMCOs6psSgsOeW7/VogIOgskMYlTc5RCW9Xp2SEC23LcNfoLtuG1DusGWDusLTdgZEigGydeJAcSqFDCDDal31cMJNEWmAbA28EAubMk3QiyM/VOCraRCTpS3vhm24KOibA9gZl+Crrp5NTlLLjOYI3bQnjXsPROTkKjjFgLbkhIlYUFAbPwy50DD3LZVpA4N9wY7wToGsUrpval1a58KrOy1IqIathmoI1JpWq6wQCmwdHaOwo+Pv5PZLdqN7WLqTOC6zhFPG+6WgzzYkORhdOsjr0SnuxTJhBAGCsM22EmwbuaA+0bkAZqus1VoM4cWSVUmPKMXKkHaqO7cBDIwDMyzK9RjbhqZvcQfykEnznKCxMGpgMwqKPKgVl0YK2libILllvL5gNt5BbVx+T3rXDg+kEniREB/0lQwja3Eg6RPbEdZjAjJcAPpAUkRNa05HY0lmH9r5XL9twKcrWRCQwMKO0e+uIUW4g6sB9FwV7eIdUTkQnc6Lol1Ylol64GOrga7fkDIy8yo+TWGClR2x4rI4wkAcEyjoE3EWrLYfbH8WTEUZzJSaDXu6NHN2PbdoCsqTA3jvVvojd0gErzSzo5LEUJIt+j6RKfiZKqsMt7d9wa/AEQop2TygDyKlH+iUfBPkEnatoZwaJoaS4UIr1G1r13efz748D3l41YR7gDLwvDUhRgs7+B3TGlzYPo+l0mhdwolLlsyXEh/myIPg4QsEIOiD7+m5+ri3PtTRk7JbKt8/oUVji250Tqxw0hoI1Hjo9TpC6fnsjr+cavlDCCtzy8xpOeKJrfPqc4YfEfYip0hKTx7ao3XbFxow1JNlWYPPLO2RRzJWD3+eL/quN9Md9KjEZb8+9Uk3Q7/MkPUf/hf31SYkou5BO7GYxSvbM4/0XKt6/ZyJD80Kn0vN5et57/zx9/Tzpc+7U1CB5J21vGnLYGUPoDkdCBw2rSsXS68uzVB9e//jmn86X7z59Xu/WIjxHB1RUJwUsfNDWXBcRsD4K7HDL++f6/ZKhMvFeev8s2evL/7vhh9c/2/f+8U8/f3nbv/uX/fP15Xn94fVvbz/+9LN9+v3P5+3z//xo+3+/GRvopo+J82zh+a98/RdI0FhwX0JtC4mP74s2GVBMYiGcNVHbuDAryj5wBdpIRGlkWW2F3iC+wChzReqox0UedEsGPvWLIBsfTAJURkM1sdFFqM1BhzF1v7781og/vD7ffdHgIzWhKIWbAZcLi8vok7/xAYIMCt8xxV3nalXn7enqb7pXr5DJNlXE0F9ffrnph9eXX/9a2n8AUEsBAhQDFAAAAAgAiwxwXes7vjNmAAAAtQAAAAsAAAAAAAAAAAAAAIABAAAAAHByb2plY3QueG1sUEsBAhQDFAAAAAgAiwxwXX5ca0w2FgAApiYAABgAAAAAAAAAAAAAAIABjwAAAFNlcUNvbnRhaW5lci9maXh0dXJlLnhtbFBLBQYAAAAAAgACAH8AAAD7FgAAAAA="

    /// The host's actions over a pairing on this Mac: upload + check-in, versions back byte for byte,
    /// check-out, the share's root, the queue, and the host's conform check on a real share.
    private static func remoteResolveLoopback(_ base: URL) async {
        let fm = FileManager.default
        UserDefaults.standard.set(Int.random(in: 47_900...48_900), forKey: "PluckScreenshotPort")
        let root = base.appendingPathComponent("Share", isDirectory: true)
        for day in ["Day 1", "Day 2"] {
            try? fm.createDirectory(at: root.appendingPathComponent(day), withIntermediateDirectories: true)
            fm.createFile(atPath: root.appendingPathComponent("\(day)/A001.MXF").path, contents: Data(day.utf8))
        }
        fm.createFile(atPath: base.appendingPathComponent("outside.mov").path, contents: Data([1]))
        let server = OfficeRenderServer.shared, client = OfficeRenderClient.shared, archive = OfficeArchive.shared
        let projectsBefore = Set(RemoteCheckout.shared.projects.map(\.id))
        archive.add(root)
        server.start()
        for _ in 0..<100 where !server.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        defer {
            client.forget()
            for device in server.devices { server.remove(device) }
            archive.remove(root)
            server.stop()
            for project in RemoteCheckout.shared.projects where !projectsBefore.contains(project.id) {
                try? fm.removeItem(at: RemoteCheckout.shared.file(project.id, version: 1).deletingLastPathComponent())
            }
            UserDefaults.standard.removeObject(forKey: "PluckScreenshotPort")
        }
        server.startPairing()
        guard let code = server.pairing?.code else { return check("resolve: pairing code", false, server.problem ?? "") }
        do {
            try await client.pair(.address("127.0.0.1"), code: code)
            let id = OfficeProxies.id(root)
            let bytes = OfficeLink.randomBytes(OfficeLink.uploadChunk + 4321)
            let token = UUID().uuidString
            let skipped = try await client.ask("resolveUpload", ["token": token, "offset": 7, "data": Data([1]).base64EncodedString()])
            check("resolve: an upload piece at the wrong place is ignored", (skipped["have"] as? NSNumber)?.intValue == 0)
            var have = 0
            while have < bytes.count {
                let piece = bytes.subdata(in: have..<min(have + OfficeLink.uploadChunk, bytes.count))
                have = (try await client.ask("resolveUpload", ["token": token, "offset": have, "data": piece.base64EncodedString()])["have"] as? NSNumber)?.intValue ?? -1
                if have < 0 { break }
            }
            let checkedIn = try await client.ask("resolveCheckin", ["token": token, "size": bytes.count, "name": "Loop", "share": id, "keep": true])
            guard let project = (checkedIn["project"] as? [String: Any]).flatMap(RemoteResolve.HostProject.init) else {
                return check("resolve: check-in over the link", false, "\(checkedIn)")
            }
            check("resolve: check-in over the link makes v1, mine", project.latest == 1 && project.mine)
            var back = Data()
            while back.count < bytes.count {
                let answer = try await client.ask("resolveVersionData", ["id": project.id, "version": 1, "offset": back.count])
                guard let piece = answer[OfficeActions.bytesKey] as? Data, !piece.isEmpty else { break }
                back.append(piece)
            }
            check("resolve: a version comes back byte for byte", back == bytes, "\(back.count) of \(bytes.count)")
            check("resolve: the project list shows it checked out here",
                  ((try await client.ask("resolveProjects"))["projects"] as? [[String: Any]] ?? []).compactMap(RemoteResolve.HostProject.init).contains { $0.id == project.id && $0.mine })
            check("resolve: the share's root is told (as projects built there have it)", (try await client.ask("resolveRoot", ["share": id]))["root"] as? String == root.path)
            check("resolve: the queue answers", (try await client.ask("resolveQueue"))["queue"] is [Any])
            check("resolve: a version that doesn't exist can't be rendered",
                  await { do { _ = try await client.ask("resolveRender", ["id": project.id, "version": 9, "timeline": "T", "preset": "P"]); return false } catch { return true } }())
            _ = try await client.ask("resolveRelease", ["id": project.id])

            // Host project names carry the project id; uploads are capped per Mac and old ones tidied.
            let one = UUID(), other = UUID()
            check("resolve: host project names carry the project's id",
                  RemoteResolveProject.hostName("Film", id: one) == "Pluck – Film – " + one.uuidString.prefix(8)
                  && RemoteResolveProject.hostName("Film", id: one) != RemoteResolveProject.hostName("Film", id: other))
            guard let mac = server.devices.first?.id else { return check("resolve: paired device", false) }
            let tokens = (0..<4).map { _ in UUID().uuidString }
            for token in tokens {
                _ = try await client.ask("resolveUpload", ["token": token, "offset": 0, "data": Data([1]).base64EncodedString()])
                try? await Task.sleep(for: .milliseconds(20))
            }
            let open = ((try? fm.contentsOfDirectory(atPath: RemoteResolveProject.uploads.path)) ?? []).filter { $0.hasPrefix(mac.uuidString + "-") }
            check("resolve: at most three uploads open per Mac, the oldest goes", open.count == RemoteResolveProject.uploadsPerDevice
                  && !open.contains { $0.contains(tokens[0]) } && open.contains { $0.contains(tokens[3]) }, "\(open)")
            let stale = RemoteResolveProject.uploads.appendingPathComponent(UUID().uuidString + ".drp")
            fm.createFile(atPath: stale.path, contents: Data([1]))
            try? fm.setAttributes([.modificationDate: Date.now.addingTimeInterval(-2 * 86_400)], ofItemAtPath: stale.path)
            RemoteResolveProject.tidyUploads()
            check("resolve: uploads left for a day are tidied", !fm.fileExists(atPath: stale.path)
                  && fm.fileExists(atPath: RemoteResolveProject.uploads.appendingPathComponent(open.first ?? "-").path))
            for name in open { try? fm.removeItem(at: RemoteResolveProject.uploads.appendingPathComponent(name)) }
            server.setRights(.init(browse: true, proxies: true, originals: false, render: false), for: mac)
            var refusedAll = true
            for (action, arguments) in [("resolvePresets", [:]), ("resolveCheckout", ["id": project.id]), ("resolveRelease", ["id": project.id]),
                                        ("resolveUpload", ["token": UUID().uuidString, "offset": 0, "data": Data([1]).base64EncodedString()])] as [(String, [String: Any])] {
                if (try? await client.ask(action, arguments)) != nil { refusedAll = false; print("not refused: \(action)") }
            }
            check("resolve: project actions refused without the render right", refusedAll)
            server.setRights(.init(), for: mac)

            // The host's conform check on this share: same names in two folders, a path out of the share.
            let clips = [RemoteResolveProject.Clip(id: "1", name: "one", file: "/local/Day 1/A001.mov"),
                         .init(id: "2", name: "two", file: "/local/Day 2/A001.mov"),
                         .init(id: "3", name: "escape", file: "/local/x.mov"),
                         .init(id: "4", name: "inShare", file: root.path + "/Day 1/A001.MXF"),
                         .init(id: "5", name: "outside", file: base.path + "/outside.mov")]
            let proxies = [RemoteRenderQueue.Proxy(file: "/local/Day 1/A001.mov", share: id, path: "Day 1/A001.MXF"),
                           .init(file: "/local/Day 2/A001.mov", share: id, path: "Day 2/A001.MXF"),
                           .init(file: "/local/x.mov", share: id, path: "../outside.mov")]
            guard let macDevice = server.devices.first(where: { $0.id == mac }) else { return check("resolve: paired device", false) }
            let plan = await RemoteResolveProject.conform(clips, proxies: proxies, device: macDevice)
            let real = RemoteEditHost.realPath(root.path) ?? root.path
            check("resolve: host swaps each proxy for its own original", plan.swaps["1"] == real + "/Day 1/A001.MXF" && plan.swaps["2"] == real + "/Day 2/A001.MXF", "\(plan.swaps)")
            check("resolve: host refuses a path out of the share and files outside shares",
                  plan.swaps["3"] == nil && plan.problems.count == 2 && plan.problems[0].hasPrefix("escape:") && plan.problems[1].hasPrefix("outside:"), "\(plan.problems)")
        } catch {
            check("resolve: round trip", false, error.localizedDescription)
        }
    }
}
