import Foundation

extension PhotoSelfTest {
    /// Send Missing Files and Render, without Resolve (-PluckScreenshotOnly remotemissing): sorting a project's files
    /// (proxy, on a NAS share, only here), the office's path map, fonts and effects found or missing, and over a
    /// loopback pairing: sending with resume, no second copy of a file sent before, never overwriting, the Editor
    /// role, and the office's own check. Never reaches Resolve (its effects list is a fake) and never renders.
    static func remoteMissingTest() async {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("RemoteMissingTest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        // Sorting: a proxy, a file on the office's NAS share, one only here, one gone; Fusion files only here.
        let nas = base.appendingPathComponent("NAS", isDirectory: true), home = base.appendingPathComponent("Home", isDirectory: true)
        for folder in [nas.appendingPathComponent("Job/Day 1"), home.appendingPathComponent("Sound")] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        for file in ["NAS/Job/Day 1/A001.mov", "NAS/Job/Logo.png", "Home/Sound/Whoosh.wav", "Home/Title.png", "Home/proxy.mov"] {
            fm.createFile(atPath: base.appendingPathComponent(file).path, contents: Data([1, 2, 3]))
        }
        let savedVolumes = OfficeGroup.testVolumes
        OfficeGroup.testVolumes = [(prefix: nas.path, remount: "smb://nas/footage")]
        defer { OfficeGroup.testVolumes = savedVolumes }
        let sorted = RemoteMissing.classify(
            media: [home.path + "/proxy.mov", nas.path + "/Job/Day 1/A001.mov", home.path + "/Sound/Whoosh.wav", "/Gone/x.mov", ""],
            refs: [["regid": "Loader", "path": home.path + "/Title.png"], ["regid": "Loader", "path": nas.path + "/Job/Logo.png"],
                   ["regid": "", "lut": true, "path": "Sony/SLog3.cube"], ["regid": "Loader", "path": "/Applications/DaVinci Resolve/x.png"],
                   ["regid": "blob", "path": home.path + "/Title.png"], ["regid": "media", "path": home.path + "/Sound/Whoosh.wav"]],
            proxies: [home.path + "/./proxy.mov"], shares: [(id: "s1", nas: "smb://nas/footage")], builtIn: ["/Applications/DaVinci Resolve"]) { path in
                RemoteDriveWriteHost.stamp(of: URL(fileURLWithPath: path))?.size
            }
        check("missing: a file on the office's NAS share goes in the path map by share and path",
              sorted.files.map(\.path) == ["Job/Day 1/A001.mov"] && sorted.files.first?.share == "s1" && sorted.files.first?.file == nas.path + "/Job/Day 1/A001.mov", "\(sorted.files)")
        check("missing: a file only on this Mac is to send (with its size); a proxy and a file gone aren't",
              sorted.send == [.init(path: home.path + "/Sound/Whoosh.wav", size: 3)], "\(sorted.send)")
        check("missing: a Fusion file only here can't be sent (not on the share, Resolve's own, a LUT or a blob)", sorted.stuck == [home.path + "/Title.png"], "\(sorted.stuck)")
        let proxies = [RemoteRenderQueue.Proxy(file: "/p/a.mov", share: "s1", path: "Client/Job/Day 1/A.mxf"),
                       .init(file: "/p/b.mov", share: "s1", path: "Client/Job/Day 2/B.mxf"), .init(file: "/p/c.mov", share: "s2", path: "Other/C.mxf")]
        check("missing: files go into the project's own folder, from this Mac",
              RemoteMissing.target(proxies: proxies, share: nil, mac: "Studio: Mac")! == (share: "s1", folder: "Client/Job/Pluck · From Studio- Mac")
              && RemoteMissing.target(proxies: [], share: "s9", mac: "Mac")! == (share: "s9", folder: "Pluck · From Mac")
              && RemoteMissing.target(proxies: [], share: nil, mac: "Mac") == nil, "\(String(describing: RemoteMissing.target(proxies: proxies, share: nil, mac: "Studio: Mac")))")

        // An office from before: nothing to send with, nothing it would take.
        var plan = RemoteMissing.Plan(send: sorted.send)
        check("missing: an office from before isn't sent files (it refuses with its list)", !plan.canSend && !plan.canRenderAnyway)
        plan.takesFiles = true
        check("missing: a new office is", plan.canSend && !plan.clean)
        let oldItem = Data(#"[{"id":"\#(UUID().uuidString)","project":"\#(UUID().uuidString)","projectName":"P","version":1,"timeline":"T","preset":"H","proxies":[],"device":"Mac","deviceID":"\#(UUID().uuidString)","added":0,"state":"queued","progress":0,"problems":[],"making":false}]"#.utf8)
        let decoded = try? JSONDecoder().decode([RemoteRenderQueue.Item].self, from: oldItem)
        check("missing: renders queued by an older Pluck load (no path map, no Render Anyway)", decoded?.first?.files == nil && decoded?.first?.anyway == nil)

        // The path map is applied on the office's imported copy only: the home Mac reads its project, never swaps in it.
        let script = RemoteResolveScript.script
        func block(_ action: String) -> String {
            guard let start = script.range(of: "if action == \"\(action)\":") else { return "" }
            let rest = script[start.upperBound...]
            return String(rest[..<(rest.range(of: "\nif action == ")?.lowerBound ?? rest.endIndex)])
        }
        check("missing: the home Mac's check only reads its project (an exported copy)",
              !["ReplaceClip", "LinkProxyMedia", "SaveProject", "ImportProject", "SetClipProperty"].contains { block("uses").contains($0) } && block("uses").contains("uses(project"))
        check("missing: the office swaps in its own imported copy", block("render").contains("ReplaceClip") && block("inspect").contains("ImportProject"))

        // Fonts and effects.
        typealias Font = RemoteMissing.Font
        typealias Effect = RemoteMissing.Effect
        let made = "Brand Sans Made Up " + UUID().uuidString.prefix(6)
        check("missing: a font that's there is found (family, style, PostScript name)",
              RemoteMissing.installed(Font(family: "Helvetica", style: "Bold")) && RemoteMissing.installed(Font(family: "helvetica"))
              && RemoteMissing.installed(Font(family: "Helvetica-Bold")) && RemoteMissing.installed(Font(family: "Helvetica", style: "Regular")))
        check("missing: a made-up font or style isn't", !RemoteMissing.installed(Font(family: made, style: "Bold")) && !RemoteMissing.installed(Font(family: "Helvetica", style: "Wobbly Ultra")))
        let ofx = base.appendingPathComponent("OFX/Plugins", isDirectory: true)
        try? fm.createDirectory(at: ofx.appendingPathComponent("NeatVideo5.ofx.bundle"), withIntermediateDirectories: true)
        let wanted = [Effect(id: "com.neatvideo.NeatVideo5.ofx", name: "Reduce Noise v5"), Effect(id: "com.example.Sparkle", name: "Sparkle"),
                      Effect(id: "com.blackmagicdesign.resolvefx.Glow", name: "Glow"), Effect(id: "", name: "Film Look Creator")]
        let unknownList = RemoteMissing.missing(wanted, installed: nil, root: ofx)
        check("missing: an OFX bundle installed is found, Resolve's own count when its list is unknown",
              unknownList.map(\.name) == ["Sparkle", "Film Look Creator"], "\(unknownList)")
        let known = RemoteMissing.missing(wanted, installed: [Effect(id: "com.blackmagicdesign.resolvefx.Glow", name: "Glow"), Effect(id: "x", name: "Film Look Creator")],
                                          root: base.appendingPathComponent("NoOFX"))
        check("missing: Resolve's list by id or name; a plugin in neither is missing", known.map(\.name) == ["Reduce Noise v5", "Sparkle"], "\(known)")
        let found: [String: Any] = ["fonts": [["family": made, "style": "Bold"], ["family": "Helvetica", "style": ""], ["family": made, "style": "Bold"]],
                                    "effects": [["id": "com.example.Sparkle", "name": ""], ["id": "", "name": "Sparkle"], ["id": "com.neatvideo.NeatVideo5.ofx", "name": "NR"]],
                                    "installed": [] as [[String: Any]]]
        let problems = RemoteMissing.problems(found, root: ofx)
        check("missing: the office's check before rendering names each font and effect once",
              problems == ["Font “\(made) Bold” isn’t installed on the office Mac.", "Effect “Sparkle” isn’t installed on the office Mac."], "\(problems)")

        await remoteMissingLoopback(base)
    }

    /// Over a pairing on this Mac: the office's path map, sending (resumed, checked), not sending twice, never
    /// overwriting, the Editor role, and resolveMissing's font and effect answers.
    private static func remoteMissingLoopback(_ base: URL) async {
        let fm = FileManager.default
        UserDefaults.standard.set(Int.random(in: 47_900...48_900), forKey: "PluckScreenshotPort")
        let root = base.appendingPathComponent("Share", isDirectory: true), home = base.appendingPathComponent("Home/Media", isDirectory: true)
        for folder in [root.appendingPathComponent("Client/Job/Day 1"), root.appendingPathComponent("Copies"), home.appendingPathComponent("Sub")] {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        fm.createFile(atPath: root.appendingPathComponent("Copies/Logo.png").path, contents: Data([1]))
        let server = OfficeRenderServer.shared, client = OfficeRenderClient.shared, archive = OfficeArchive.shared
        let floor = RemoteSendInto.freeFloor, effectsBefore = RemoteMissing.resolveEffects, ofxBefore = RemoteMissing.ofxRoot
        archive.add(root)
        server.start()
        for _ in 0..<100 where !server.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        defer {
            client.forget()
            for device in server.devices { server.remove(device) }
            archive.remove(root)
            server.stop()
            RemoteSendInto.freeFloor = floor
            RemoteMissing.resolveEffects = effectsBefore
            RemoteMissing.ofxRoot = ofxBefore
            UserDefaults.standard.removeObject(forKey: "PluckScreenshotPort")
        }
        RemoteSendInto.freeFloor = 0
        server.startPairing()
        guard let code = server.pairing?.code else { return check("missing: pairing code", false, server.problem ?? "") }
        do {
            try await client.pair(.address("127.0.0.1"), code: code)
            let id = OfficeProxies.id(root), real = RemoteEditHost.realPath(root.path) ?? root.path

            // The office's path map: a still sent before (no length check: the same bytes), one out of the share, one not there.
            typealias Clip = RemoteResolveProject.Clip
            let clips = [Clip(id: "1", name: "Logo.png", file: "/home/Logo.png", frames: 125, fps: 25), Clip(id: "2", name: "escape", file: "/home/x.png"),
                         Clip(id: "3", name: "gone", file: "/home/gone.wav")]
            let mapped = await RemoteResolveProject.conform(clips, proxies: [], files: [.init(file: "/home/Logo.png", share: id, path: "Copies/Logo.png"),
                                                                                       .init(file: "/home/x.png", share: id, path: "../outside.png"),
                                                                                       .init(file: "/home/gone.wav", share: id, path: "Copies/gone.wav")])
            check("missing: the office swaps a sent file in by the path map, without comparing it",
                  mapped.swaps == ["1": real + "/Copies/Logo.png"] && mapped.problems.count == 2 && mapped.problems.allSatisfy { $0.contains("offline") }, "\(mapped)")
            check("missing: the office says it takes sent files", (try await client.ask("resolveQueue"))["sendMissing"] as? Bool == true)

            // Sending: the folders made, one file resumed from a partial left by a dropped link.
            let big = home.appendingPathComponent("Sub/clip.bin"), small = home.appendingPathComponent("Whoosh.wav")
            let bytes = OfficeLink.randomBytes(OfficeLink.uploadChunk * 2 + 777)
            try bytes.write(to: big)
            try Data("whoosh".utf8).write(to: small)
            let files = [big, small].map { RemoteMissing.LocalFile(path: $0.path, size: Int64(RemoteDriveWriteHost.stamp(of: $0)?.size ?? 0)) }
            let target = (share: id, folder: "Client/Job/Pluck · From Mac")
            let sub = root.appendingPathComponent(target.folder + "/Sub", isDirectory: true)
            try fm.createDirectory(at: sub, withIntermediateDirectories: true)
            // (As Send Files Here names its partial: the modification time rounded.)
            let modified = ((try? big.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now).timeIntervalSince1970.rounded()
            try bytes.prefix(OfficeLink.uploadChunk).write(to: RemoteSendInto.partial(sub, name: "clip.bin", size: Int64(bytes.count), modified: modified))
            let first = try await RemoteMissing.send(files, to: target, client: client)
            check("missing: sent into the project's folder keeping the folders under their common one (a dropped upload resumed)",
                  first.map(\.path) == [target.folder + "/Sub/clip.bin", target.folder + "/Whoosh.wav"] && first.map(\.file) == [big.path, small.path]
                  && (try? Data(contentsOf: sub.appendingPathComponent("clip.bin"))) == bytes
                  && !fm.fileExists(atPath: RemoteSendInto.partial(sub, name: "clip.bin", size: Int64(bytes.count), modified: modified).path), "\(first)")
            let again = try await RemoteMissing.send(files, to: target, client: client)
            let names = (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(target.folder).path)) ?? []
            check("missing: a file sent before (same size and SHA-256) isn't sent again", again.map(\.path) == first.map(\.path) && names.sorted() == ["Sub", "Whoosh.wav"], "\(names)")
            try Data("other".utf8).write(to: small)
            let changed = try await RemoteMissing.send([.init(path: small.path, size: 5)], to: target, client: client)
            check("missing: a changed file never overwrites the copy there (Name 2)", changed.first?.path == target.folder + "/Whoosh 2.wav"
                  && (try? String(contentsOf: root.appendingPathComponent(target.folder + "/Whoosh.wav"), encoding: .utf8)) == "whoosh", "\(changed)")

            // Fonts and effects as the office has them (its Resolve list is a fake here).
            RemoteMissing.resolveEffects = { [.init(id: "com.blackmagicdesign.resolvefx.Glow", name: "Glow")] }
            RemoteMissing.ofxRoot = base.appendingPathComponent("NoOFX")
            let made = "Brand Sans Made Up " + UUID().uuidString.prefix(6)
            let answer = try await client.ask("resolveMissing", ["fonts": [["family": "Helvetica", "style": "Bold"], ["family": made, "style": ""]],
                                                                 "effects": [["id": "com.blackmagicdesign.resolvefx.Glow", "name": "Glow"], ["id": "com.example.Sparkle", "name": "Sparkle"]]])
            check("missing: the office names the fonts and effects it hasn't got",
                  (answer["fonts"] as? [[String: Any]])?.compactMap { $0["family"] as? String } == [made]
                  && (answer["effects"] as? [[String: Any]])?.compactMap { $0["name"] as? String } == ["Sparkle"], "\(answer)")

            // Without the Editor role nothing is sent, and the editor is told who can change that.
            guard let mac = server.devices.first?.id else { return check("missing: paired device", false) }
            server.setRights(.init(browse: true, proxies: true, originals: false, render: false), for: mac)
            let refusal = await { () -> String in
                do { _ = try await RemoteMissing.send([.init(path: small.path, size: 5)], to: (id, "Client/Job/Day 1/Pluck · From Mac"), client: client); return "" } catch { return error.localizedDescription }
            }()
            check("missing: without the Editor role nothing is sent, with who can give it",
                  refusal.contains("Editor") && refusal.contains("Admin") && !fm.fileExists(atPath: root.appendingPathComponent("Client/Job/Day 1/Pluck · From Mac").path), refusal)
            server.setRights(.init(), for: mac)
        } catch {
            check("missing: round trip", false, error.localizedDescription)
        }
    }
}
