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
        await remoteMissingLUTs(base)
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
        check("missing: an OFX bundle installed is found, Resolve's own (and name-only ones) count when its list is unknown",
              unknownList.map(\.name) == ["Sparkle"], "\(unknownList)")
        let known = RemoteMissing.missing(wanted, installed: [Effect(id: "com.blackmagicdesign.resolvefx.Glow", name: "Glow"), Effect(id: "x", name: "Film Look Creator")],
                                          root: base.appendingPathComponent("NoOFX"))
        check("missing: Resolve's list by id or name; a plugin in neither is missing", known.map(\.name) == ["Reduce Noise v5", "Sparkle"], "\(known)")
        try? fm.createDirectory(at: ofx.appendingPathComponent("BorisFX Continuum.ofx.bundle"), withIntermediateDirectories: true)
        let vendor = RemoteMissing.missing([Effect(id: "com.borisfx.sapphire.S_Glow", name: "S_Glow")], installed: [], root: ofx)
        check("missing: another plugin of the same vendor doesn't count as this one", vendor.map(\.name) == ["S_Glow"], "\(vendor)")
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
            guard let paired = server.devices.first else { return check("missing: paired device", false) }
            let mapped = await RemoteResolveProject.conform(clips, proxies: [], files: [.init(file: "/home/Logo.png", share: id, path: "Copies/Logo.png"),
                                                                                       .init(file: "/home/x.png", share: id, path: "../outside.png"),
                                                                                       .init(file: "/home/gone.wav", share: id, path: "Copies/gone.wav")], device: paired)
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

            try await remoteMissingPlaced(base, root: root, id: id, client: client)

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

    /// LUTs and comp files sorted and checked on this Mac alone: the LUT folder, paths kept inside it, the office's
    /// states, and an office from before.
    private static func remoteMissingLUTs(_ base: URL) async {
        let fm = FileManager.default
        typealias M = RemoteMissing
        let luts = base.appendingPathComponent("HomeLUT", isDirectory: true)
        try? fm.createDirectory(at: luts.appendingPathComponent("Look"), withIntermediateDirectories: true)
        for name in ["Look/Day.cube", "Film.dctl", "Look/Bad:name.cube"] { fm.createFile(atPath: luts.appendingPathComponent(name).path, contents: Data(name.utf8)) }
        let comp = base.appendingPathComponent("Home/Title.png").path
        let sorted = M.classify(media: [], refs: [["lut": true, "path": "Look/Day.cube"], ["lut": true, "path": luts.path + "/Film.dctl"],
                                                  ["lut": true, "path": "Gone.cube"], ["lut": true, "path": "Look/Day.cube"], ["lut": true, "path": "Look/Bad:name.cube"],
                                                  ["regid": "Loader", "path": comp]],
                                proxies: [], shares: [], builtIn: [luts.path], lutRoot: luts.path) { RemoteDriveWriteHost.stamp(of: URL(fileURLWithPath: $0))?.size }
        check("missing LUTs: a grade's LUT in the LUT folder (relative or not) is checked once with the office; one not here isn't; a bad name can't be sent",
              sorted.luts.map(\.path) == ["Look/Day.cube", "Film.dctl"] && sorted.luts.first?.file.path == luts.path + "/Look/Day.cube"
              && sorted.stuck == [luts.path + "/Look/Bad:name.cube", comp], "\(sorted.luts) \(sorted.stuck)")
        check("missing LUTs: LUT paths are plain names with a LUT ending (a DCTL only compared)",
              M.lutRelative("Sony/SLog3.cube") && M.lutRelative("A.CUBE") && !M.lutRelative("../x.cube") && !M.lutRelative("/x.cube")
              && !M.lutRelative("a/.x.cube") && !M.lutRelative("a//x.cube") && !M.lutRelative("x.png") && !M.lutRelative("x.dctl") && M.lutRelative("x.dctl", code: true))

        // The office's LUT folder: folders made inside it, never through a link out; same, missing, different.
        let office = base.appendingPathComponent("OfficeLUT", isDirectory: true), outside = base.appendingPathComponent("Outside", isDirectory: true)
        try? fm.createDirectory(at: office, withIntermediateDirectories: true)
        try? fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: office.appendingPathComponent("Out"), withDestinationURL: outside)
        let made = try? M.lutTarget("A/B/x.cube", root: office, make: true)
        check("missing LUTs: the office makes a LUT's folders inside its LUT folder", made?.path == (RemoteEditHost.realPath(office.path) ?? "") + "/A/B" && RemoteEditHost.isDirectory(office.appendingPathComponent("A/B")))
        check("missing LUTs: never through a link out of it, nor a DCTL", (try? M.lutTarget("Out/x.cube", root: office, make: true)) == nil
              && (try? M.lutTarget("Out/New/x.cube", root: office, make: true)) == nil && !fm.fileExists(atPath: outside.appendingPathComponent("New").path)
              && (try? M.lutTarget("x.dctl", root: office, make: true)) == nil)
        try? Data("day".utf8).write(to: office.appendingPathComponent("A/B/x.cube"))
        let sha = (try? RemoteSendInto.hash(office.appendingPathComponent("A/B/x.cube"))) ?? ""
        let states = [M.lutState(["path": "A/B/x.cube", "size": 3, "sha256": sha], root: office), M.lutState(["path": "A/B/y.cube", "size": 3, "sha256": sha], root: office),
                      M.lutState(["path": "A/B/x.cube", "size": 3, "sha256": String(repeating: "0", count: 64)], root: office),
                      M.lutState(["path": "Out/x.cube", "size": 3, "sha256": sha], root: office), M.lutState(["path": "../x.cube"], root: office),
                      M.lutState(["path": "New/Film.dctl", "size": 3, "sha256": sha], root: office)]
        check("missing LUTs: the office says same, missing or different (a link out or a bad path: neither)", states == ["same", "missing", "different", "", "", "missing"], "\(states)")

        // Placing at exactly the name: never over another file.
        let part = office.appendingPathComponent("A/B/.part"), target = office.appendingPathComponent("A/B/x.cube")
        try? Data("night".utf8).write(to: part)
        let refused = (try? M.placeExactly(part, at: target)) == nil
        try? Data("day".utf8).write(to: part)
        let same = (try? M.placeExactly(part, at: target)) != nil
        try? Data("new".utf8).write(to: part)
        let placed = (try? M.placeExactly(part, at: office.appendingPathComponent("A/B/z.cube"))) != nil
        check("missing LUTs: a LUT is placed at its name, never over a different one (the same bytes are fine)",
              refused && same && placed && (try? String(contentsOf: target, encoding: .utf8)) == "day"
              && (try? String(contentsOf: office.appendingPathComponent("A/B/z.cube"), encoding: .utf8)) == "new" && !fm.fileExists(atPath: part.path))

        // Comp paths as the office finds them in its shares.
        let share = base.appendingPathComponent("OfficeShare", isDirectory: true)
        try? fm.createDirectory(at: share.appendingPathComponent("Job"), withIntermediateDirectories: true)
        let roots = [(id: "s1", root: RemoteEditHost.realPath(share.path) ?? share.path)]
        let inside = M.officePlace(share.path + "/Job/GFX/Title.png", roots: roots)
        check("missing comps: a comp's path in one of the office's shares is found there; outside, `..` or a hidden name isn't",
              inside?.share == "s1" && inside?.path == "Job/GFX/Title.png" && M.officePlace(outside.path + "/x.png", roots: roots) == nil
              && M.officePlace(share.path + "/Job/../../Outside/x.png", roots: roots) == nil && M.officePlace(share.path + "/.x/y.png", roots: roots) == nil
              && M.officePlace("Job/x.png", roots: roots) == nil, "\(String(describing: inside))")

        // The office's answer on a plan: same dropped, missing sent, different kept there, a DCTL never sent; comp files too.
        let day = M.Placed(file: .init(path: luts.path + "/Look/Day.cube", size: 13), path: "Look/Day.cube")
        let night = M.Placed(file: .init(path: luts.path + "/Look/Night.cube", size: 1), path: "Look/Night.cube")
        let stock = M.Placed(file: .init(path: luts.path + "/Stock.cube", size: 1), path: "Stock.cube")
        let film = M.Placed(file: .init(path: luts.path + "/Film.dctl", size: 9), path: "Film.dctl")
        let lutList = [day, night, stock, film]
        let gone = base.appendingPathComponent("Home/Gone.png").path
        var plan = M.Plan(stuck: [comp, base.appendingPathComponent("Home/proxy.mov").path, gone])
        plan.takesFiles = true
        for path in lutList.map(\.file.path) + plan.stuck { plan.hashes[path] = "aa" }
        plan.hashes[gone] = nil
        let old = plan
        M.apply(["luts": ["missing", "different", "same", "missing"],
                 "comps": [["share": "s1", "path": "Job/GFX/Title.png", "base": "Job", "state": "missing"], ["share": "s1", "path": "Job/Other.mov", "state": "missing"],
                           ["share": "s1", "path": "Job/Gone.png", "state": "missing"]]],
                to: &plan, luts: lutList)
        check("missing: the office's answer: a missing LUT and comp file are sent at their path, a different one kept and said, a DCTL, a comp file under another name there and one gone stay",
              plan.placed.map(\.path) == ["Look/Day.cube", "Job/GFX/Title.png"] && plan.placed.last?.share == "s1" && plan.placed.last?.base == "Job"
              && plan.different == ["Look/Night.cube"] && plan.stuck == [film.file.path, base.appendingPathComponent("Home/proxy.mov").path, gone]
              && !plan.canSend, "\(plan.placed) \(plan.different) \(plan.stuck)")
        var fine = M.Plan(stuck: [comp])
        fine.takesFiles = true
        fine.hashes[comp] = "aa"
        M.apply(["luts": ["different"], "comps": [["share": "s1", "path": "Job/GFX/Title.png", "base": "Job", "state": "missing"]]], to: &fine, luts: [night])
        check("missing: only LUTs or comp files to send: Send Missing Files and Render; a different one shown",
              fine.canSend && !fine.clean && fine.sending.map(\.path) == [comp] && fine.different == ["Look/Night.cube"])
        var differs = M.Plan()
        differs.different = ["Look/Night.cube"]
        check("missing: only a different LUT: Render Anyway", differs.canRenderAnyway && !differs.canSend && !differs.clean)
        var before = old
        M.apply(["fonts": [] as [Any], "effects": [] as [Any], "present": [] as [Any]], to: &before, luts: lutList)
        check("missing: an office from before (no LUT or comp answers): no LUT is sent, comp files stay to copy by hand",
              before.placed.isEmpty && before.different.isEmpty && before.stuck == old.stuck)
    }

    /// Over the pairing: the office's checks of LUTs and comp files, LUTs sent into its LUT folder (resumed) and comp
    /// files to their path in a share, never over another file there, and nothing for a Mac without the right.
    private static func remoteMissingPlaced(_ base: URL, root: URL, id: String, client: OfficeRenderClient) async throws {
        let fm = FileManager.default
        typealias M = RemoteMissing
        let office = base.appendingPathComponent("LoopLUT", isDirectory: true), home = base.appendingPathComponent("LoopHomeLUT", isDirectory: true)
        for folder in [office.appendingPathComponent("Look"), home.appendingPathComponent("Look")] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        let before = M.lutFolder
        M.lutFolder = office
        defer { M.lutFolder = before }
        let day = OfficeLink.randomBytes(OfficeLink.uploadChunk + 4321)
        try day.write(to: home.appendingPathComponent("Look/Day.cube"))
        try Data("night".utf8).write(to: home.appendingPathComponent("Look/Night.cube"))
        try Data("other night".utf8).write(to: office.appendingPathComponent("Look/Night.cube"))
        try Data("stock".utf8).write(to: home.appendingPathComponent("Stock.cube"))
        try Data("stock".utf8).write(to: office.appendingPathComponent("Stock.cube"))
        // A comp file of this Mac at a path in the office's share (as on a Mac whose drive has the same path).
        let gfx = base.appendingPathComponent("LoopGFX/Title.png")
        try? fm.createDirectory(at: gfx.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("title".utf8).write(to: gfx)
        let real = RemoteEditHost.realPath(root.path) ?? root.path
        let sorted = M.classify(media: [], refs: ["Look/Day.cube", "Look/Night.cube", "Stock.cube"].map { ["lut": true, "path": $0] },
                                proxies: [], shares: [], builtIn: [], lutRoot: home.path) { RemoteDriveWriteHost.stamp(of: URL(fileURLWithPath: $0))?.size }
        var plan = M.Plan(stuck: [base.appendingPathComponent("Home/Title.png").path])
        plan.takesFiles = true
        try await M.check(&plan, luts: sorted.luts, fonts: [], effects: [], client: client)
        check("missing over a pairing: the office takes the missing LUT, keeps its different one, has the same; a comp file outside its shares stays",
              plan.placed.map(\.path) == ["Look/Day.cube"] && plan.different == ["Look/Night.cube"] && plan.stuck == [base.appendingPathComponent("Home/Title.png").path],
              "\(plan.placed) \(plan.different) \(plan.stuck)")
        let answer = try await client.ask("resolveMissing", ["comps": [["path": real + "/Client/Job/GFX/Title.png", "size": 5, "sha256": "00"],
                                                                     ["path": base.appendingPathComponent("Home/Title.png").path, "size": 3, "sha256": "00"]]])
        let places = answer["comps"] as? [[String: Any]] ?? []
        check("missing over a pairing: the office finds a comp's path in its share (nearest folder there) and none outside",
              places.count == 2 && places[0]["share"] as? String == id && places[0]["path"] as? String == "Client/Job/GFX/Title.png"
              && places[0]["base"] as? String == "Client/Job" && places[0]["state"] as? String == "missing" && places[1].isEmpty, "\(places)")

        // Sending: the LUT resumed from a partial a dropped link left, the comp file into the folder made for it.
        try day.prefix(OfficeLink.uploadChunk).write(to: RemoteSendInto.partial(office.appendingPathComponent("Look"), name: "Day.cube", size: Int64(day.count), modified: 0))
        let title = M.Placed(file: .init(path: gfx.path, size: 5), share: id, path: "Client/Job/GFX/Title.png", base: "Client/Job")
        try await M.send(plan.placed + [title], hashes: plan.hashes, client: client)
        check("missing over a pairing: the LUT is in the office's LUT folder at its path (resumed), the comp file at the path the comp reads",
              (try? Data(contentsOf: office.appendingPathComponent("Look/Day.cube"))) == day
              && (try? String(contentsOf: office.appendingPathComponent("Look/Night.cube"), encoding: .utf8)) == "other night"
              && (try? String(contentsOf: root.appendingPathComponent("Client/Job/GFX/Title.png"), encoding: .utf8)) == "title"
              && ((try? fm.contentsOfDirectory(atPath: office.appendingPathComponent("Look").path)) ?? []).sorted() == ["Day.cube", "Night.cube"])
        try Data("changed".utf8).write(to: gfx)
        try Data("changed".utf8).write(to: home.appendingPathComponent("Look/Night.cube"))
        let lutRefusal = await { () -> String in
            do { try await M.send([M.Placed(file: .init(path: home.appendingPathComponent("Look/Night.cube").path, size: 7), path: "Look/Night.cube")], hashes: [:], client: client); return "" }
            catch { return error.localizedDescription }
        }()
        let compRefusal = await { () -> String in
            do { try await M.send([M.Placed(file: .init(path: gfx.path, size: 7), share: id, path: "Client/Job/GFX/Title.png", base: "Client/Job/GFX")], hashes: [:], client: client); return "" }
            catch { return error.localizedDescription }
        }()
        check("missing over a pairing: a LUT or comp file the office got meanwhile under that name is never replaced, and said",
              lutRefusal.contains("wasn’t replaced") && compRefusal.contains("wasn’t replaced")
              && (try? String(contentsOf: office.appendingPathComponent("Look/Night.cube"), encoding: .utf8)) == "other night"
              && (try? String(contentsOf: root.appendingPathComponent("Client/Job/GFX/Title.png"), encoding: .utf8)) == "title", lutRefusal + " | " + compRefusal)
        let outRefused = (try? await client.ask("resolveLUT", ["path": "../Out.cube", "size": 1])) == nil
        let dctlRefused = (try? await client.ask("resolveLUT", ["path": "Film.dctl", "size": 1])) == nil
        check("missing over a pairing: a LUT path out of the LUT folder or a DCTL is refused", outRefused && dctlRefused
              && !fm.fileExists(atPath: base.appendingPathComponent("Out.cube").path))

        // A Mac that may not render: no LUT taken, no comp place offered.
        guard let mac = OfficeRenderServer.shared.devices.first?.id else { return check("missing: paired device", false) }
        OfficeRenderServer.shared.setRights(.init(browse: true, proxies: true, originals: false, render: false), for: mac)
        defer { OfficeRenderServer.shared.setRights(.init(), for: mac) }
        let refusedLUT = (try? await client.ask("resolveLUT", ["path": "Look/New.cube", "size": 1])) == nil
        let noPlace = try? await client.ask("resolveMissing", ["comps": [["path": real + "/Client/Job/New.png", "size": 1, "sha256": "00"]]])
        check("missing over a pairing: without the render right no LUT is taken and no comp place offered",
              refusedLUT && noPlace == nil && !fm.fileExists(atPath: office.appendingPathComponent("Look/New.cube").path))
    }
}
