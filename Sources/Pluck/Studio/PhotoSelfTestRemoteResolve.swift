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
        check("resolve: conform reports length, channels, timecode, missing and offline (not the good, kept or empty)",
              plan.problems.count == 5 && zip(plan.problems, named).allSatisfy { $0.hasPrefix($1 + ":") }, "\(plan.problems)")

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
        archive.stop()
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
            let plan = await RemoteResolveProject.conform(clips, proxies: proxies)
            let real = RemoteEditHost.realPath(root.path) ?? root.path
            check("resolve: host swaps each proxy for its own original", plan.swaps["1"] == real + "/Day 1/A001.MXF" && plan.swaps["2"] == real + "/Day 2/A001.MXF", "\(plan.swaps)")
            check("resolve: host refuses a path out of the share and files outside shares",
                  plan.swaps["3"] == nil && plan.problems.count == 2 && plan.problems[0].hasPrefix("escape:") && plan.problems[1].hasPrefix("outside:"), "\(plan.problems)")
        } catch {
            check("resolve: round trip", false, error.localizedDescription)
        }
    }
}
