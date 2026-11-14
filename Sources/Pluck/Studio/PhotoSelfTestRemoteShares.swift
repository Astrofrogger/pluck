import Foundation

extension PhotoSelfTest {
    /// The host's shares and proxies (-PluckScreenshotOnly remoteshares): a share in the test home
    /// with small clips made by the bundled ffmpeg, a missing share, and a client paired over this
    /// Mac. Offline shares say so (fast), bookmarks find a moved folder, proxies of a subfolder only,
    /// proxies keep length, channels, timecode and reel, the manifest carries each proxy's SHA-256,
    /// older proxyData originals follow the originals right, and a watched folder gets proxies.
    static func remoteSharesTest() async {
        let fm = FileManager.default
        guard let ffmpeg = OfficeRenderServer.shared.manager?.tool("ffmpeg"), let ffprobe = OfficeRenderServer.shared.manager?.tool("ffprobe") else {
            return check("shares: bundled ffmpeg", false, "no ffmpeg")
        }
        UserDefaults.standard.set(Int.random(in: 47_900...48_900), forKey: "PluckScreenshotPort")
        // (The real path: a bookmark resolves /tmp to /private/tmp.)
        let home = URL(fileURLWithPath: RemoteEditHost.realPath(NSHomeDirectory()) ?? NSHomeDirectory(), isDirectory: true)
        let base = home.appendingPathComponent("RemoteSharesTest-\(UUID().uuidString)", isDirectory: true)
        for folder in OfficeArchive.shared.folders where folder.path.contains("/RemoteSharesTest-") { OfficeArchive.shared.remove(folder) }
        let root = base.appendingPathComponent("Share", isDirectory: true), gone = base.appendingPathComponent("Gone", isDirectory: true)
        try? fm.createDirectory(at: root.appendingPathComponent("Day 1/A"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: root.appendingPathComponent("Day 2"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        func run(_ tool: String, _ arguments: [String]) -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        /// A 2 s ProRes clip with 4 audio channels and a timecode (and a reel when given).
        func clip(_ relative: String, reel: String?) {
            var arguments = ["-nostdin", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=2",
                             "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-map", "0:v", "-map", "1:a", "-ac", "4",
                             "-c:v", "prores_ks", "-profile:v", "0", "-c:a", "pcm_s16le", "-timecode", "01:00:00:00"]
            if let reel { arguments += ["-metadata:s:v:0", "reel_name=" + reel] }
            _ = run(ffmpeg, arguments + [root.appendingPathComponent(relative).path])
        }
        clip("Day 1/A/clip1.mov", reel: "REEL1")
        clip("Day 1/clip2.mov", reel: nil)
        clip("Day 2/clip3.mov", reel: nil)
        guard fm.fileExists(atPath: root.appendingPathComponent("Day 2/clip3.mov").path) else { return check("shares: test clips made", false) }
        func duration(_ file: URL) -> Double { Double(run(ffprobe, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", file.path])) ?? -1 }
        func channels(_ file: URL) -> Int {
            run(ffprobe, ["-v", "error", "-select_streams", "a", "-show_entries", "stream=channels", "-of", "csv=p=0", file.path])
                .split(separator: "\n").compactMap { Int($0) }.reduce(0, +)
        }
        func tags(_ file: URL) -> String { run(ffprobe, ["-v", "error", "-show_entries", "stream_tags=timecode,reel_name:format_tags=timecode", "-of", "json", file.path]) }

        let server = OfficeRenderServer.shared, client = OfficeRenderClient.shared, archive = OfficeArchive.shared
        let shares = RemoteShares.shared, jobs = RemoteProxyJobs.shared, id = OfficeProxies.id(root)
        archive.add(root)
        archive.add(gone)
        archive.stop()

        // Online, offline, and a look that hangs.
        let online = await shares.state(root), offline = await shares.state(gone)
        check("shares: a reachable share is online with its disk", online.online && online.total > 0 && online.free > 0, "\(online)")
        check("shares: a missing share is offline", !offline.online)
        let started = Date.now
        let hung = await RemoteShares.withTimeout("selftest-hang", true, timeout: 0.3) { Thread.sleep(forTimeInterval: 2); return false }
        check("shares: a look that hangs gives up in time", hung == true && Date.now.timeIntervalSince(started) < 1, "\(Date.now.timeIntervalSince(started)) s")

        // A folder that moves (a mount coming back under another name) is found by its bookmark.
        let moving = base.appendingPathComponent("Moving", isDirectory: true), moved = base.appendingPathComponent("Moved", isDirectory: true)
        try? fm.createDirectory(at: moving, withIntermediateDirectories: true)
        archive.add(moving)
        archive.stop()
        await shares.sync()
        check("shares: new shares get a bookmark and volume", shares.share(moving)?.bookmark != nil && shares.share(moving)?.volume != nil)
        let movingID = OfficeProxies.id(moving)
        try? fm.moveItem(at: moving, to: moved)
        await shares.sync()
        archive.stop()
        check("shares: a moved share is found again", archive.folders.contains { $0.path == moved.path } && !archive.folders.contains { $0.path == moving.path }
              && shares.share(moved) != nil, "\(archive.folders.map(\.path)) \(shares.shares.map(\.path)) want \(moved.path)")
        check("shares: a moved share keeps its id", OfficeProxies.id(moved) == movingID && movingID == OfficeProxies.pathID(moving.path),
              "\(OfficeProxies.id(moved)) vs \(movingID)")
        archive.add(moving)
        archive.stop()
        await shares.sync()
        check("shares: a new folder where a moved one was gets its own id", OfficeProxies.id(moving) != movingID)
        archive.remove(moving)
        archive.remove(moved)
        archive.stop()
        await shares.sync()

        server.start()
        for _ in 0..<100 where !server.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        defer {
            client.forget()
            for device in server.devices { server.remove(device) }
            for request in jobs.requests where request.share == id { jobs.remove(request.id) }
            shares.removeWatch(.init(path: "Day 2", format: .light), in: root)
            archive.remove(root)
            archive.remove(gone)
            archive.stop()
            try? fm.removeItem(at: OfficeProxies.shared.proxy("x", folder: id, format: .light).deletingLastPathComponent())
            server.stop()
            RemoteKeepAwake.update()
            UserDefaults.standard.removeObject(forKey: "PluckScreenshotPort")
        }
        server.startPairing()
        guard let code = server.pairing?.code else { return check("shares: pairing code", false, server.problem ?? "") }
        do {
            try await client.pair(.address("127.0.0.1"), code: code)
        } catch {
            return check("shares: paired over this Mac", false, error.localizedDescription)
        }
        guard let device = server.devices.first else { return check("shares: paired over this Mac", false, "no device") }
        func refused(_ work: () async throws -> Void) async -> Bool {
            do { try await work(); return false } catch { return true }
        }

        do {
            let listed = try await client.shares()
            check("shares: paired Macs see online and offline shares", listed.contains { $0.id == id && $0.online }
                  && listed.contains { $0.id == OfficeProxies.id(gone) && !$0.online }, "\(listed)")

            check("shares: proxies of a path out of the share are refused",
                  await refused({ _ = try await client.ask("shareProxyMake", ["share": id, "paths": ["../Gone"], "format": "light"]) }))
            check("shares: proxies as originals are refused",
                  await refused({ _ = try await client.ask("shareProxyMake", ["share": id, "paths": ["Day 1"], "format": "original"]) }))

            let made = try await client.ask("shareProxyMake", ["share": id, "paths": ["Day 1"], "format": "light"])
            guard let request = (made["request"] as? [String: Any])?["id"] as? String else { return check("shares: proxy request made", false, "\(made)") }
            var state = ""
            var answer: [String: Any] = [:]
            for _ in 0..<240 where state != "ready" && state != "failed" {
                try? await Task.sleep(for: .milliseconds(500))
                answer = try await client.ask("shareProxyStatus", ["id": request])["request"] as? [String: Any] ?? [:]
                state = answer["state"] as? String ?? ""
            }
            check("shares: proxies of a subfolder get ready", state == "ready" && answer["total"] as? Int == 2 && answer["done"] as? Int == 2, "\(answer)")
            let proxy1 = OfficeProxies.shared.proxy("Day 1/A/clip1.mov", folder: id, format: .light)
            let proxy2 = OfficeProxies.shared.proxy("Day 1/clip2.mov", folder: id, format: .light)
            let proxy3 = OfficeProxies.shared.proxy("Day 2/clip3.mov", folder: id, format: .light)
            check("shares: only the asked folder got proxies", fm.fileExists(atPath: proxy1.path) && fm.fileExists(atPath: proxy2.path)
                  && !fm.fileExists(atPath: proxy3.path))
            let original1 = root.appendingPathComponent("Day 1/A/clip1.mov")
            check("shares: a proxy keeps the length", abs(duration(proxy1) - duration(original1)) < 0.1, "\(duration(proxy1)) vs \(duration(original1))")
            check("shares: a proxy keeps the audio channels", channels(proxy1) == channels(original1) && channels(proxy1) == 4, "\(channels(proxy1))")
            check("shares: a proxy keeps the timecode", tags(proxy1).contains("01:00:00:00"), tags(proxy1))
            check("shares: a proxy keeps the reel, else the file name", tags(proxy1).contains("REEL1") && tags(proxy2).contains("\"clip2\""),
                  tags(proxy1) + " / " + tags(proxy2))
            let piece = try await client.fileData(share: id, path: "Day 1/A/clip1.mov", kind: .proxy, offset: 0)
            let size = (try? fm.attributesOfItem(atPath: proxy1.path)[.size] as? NSNumber)?.int64Value ?? -1
            check("shares: the proxy is served by fileData", piece.size == size && piece.data.count == Int(min(size, Int64(OfficeLink.fileChunk))))
            check("shares: the Mac stays awake while serving", RemoteKeepAwake.isHolding)

            let manifest = try await client.ask("shareManifest", ["share": id, "path": "Day 1", "format": "light"])
            let entries = try JSONDecoder().decode([RemoteManifestEntry].self,
                                                   from: JSONSerialization.data(withJSONObject: manifest["entries"] ?? []))
            let first = entries.first { $0.path == "Day 1/A/clip1.mov" }
            check("shares: the manifest says nothing is still being made", (manifest["pending"] as? Int) == 0, "\(manifest["pending"] ?? "none")")
            check("shares: the manifest lists the ready proxies", entries.count == 2 && manifest["shareName"] as? String == "Share", "\(entries.map(\.path))")
            check("shares: a manifest entry has the original's details", first?.proxy == "Day 1/A/clip1.mov" && first?.reel == "REEL1"
                  && first?.timecode == "01:00:00:00" && first?.audioChannels == 4 && abs((first?.duration ?? 0) - 2) < 0.1
                  && first?.share == id && first?.size == size, "\(String(describing: first))")
            check("shares: a manifest entry's checksum is the proxy's SHA-256",
                  first?.checksum != nil && first?.checksum == RemoteProxyJobs.checksum(proxy1))
            let whole = try await client.ask("shareManifest", ["share": id, "path": "", "format": "light"])
            check("shares: the manifest of the whole share", (whole["entries"] as? [Any])?.count == 2)
            check("shares: a manifest of a path out of the share is refused",
                  await refused({ _ = try await client.ask("shareManifest", ["share": id, "path": "../Gone", "format": "light"]) }))

            // The older proxyData with originals follows the originals right.
            let original = ["folder": id, "format": "original", "path": "Day 1/clip2.mov", "offset": 0] as [String: Any]
            check("shares: older proxyData originals refused without the right", await refused({ _ = try await client.ask("proxyData", original) }))
            server.setRights(.init(browse: true, proxies: true, originals: true, render: true), for: device.id)
            do {
                check("shares: older proxyData originals with the right", try await client.ask("proxyData", original)["data"] != nil)
            } catch {
                check("shares: older proxyData originals with the right", false, error.localizedDescription)
            }
            server.setRights(.init(browse: true, proxies: false, originals: false, render: true), for: device.id)
            check("shares: proxies refused without the right",
                  await refused({ _ = try await client.ask("shareProxyMake", ["share": id, "paths": ["Day 2"], "format": "light"]) }))
            var older = true
            for (action, arguments) in [("proxyFolders", [:]), ("proxyMake", ["folder": id, "format": "light"]), ("proxyStatus", ["folder": id, "format": "light"]),
                                        ("proxyData", ["folder": id, "format": "light", "path": "Day 1/clip2.mov", "offset": 0])] as [(String, [String: Any])] {
                if !(await refused({ _ = try await client.ask(action, arguments) })) { older = false; print("not refused: \(action)") }
            }
            check("shares: older proxy actions refused without the proxies right", older)
            server.setRights(.init(browse: false, proxies: true, originals: false, render: true), for: device.id)
            let noSearch = await refused({ _ = try await client.ask("archiveSearch", ["query": "x"]) })
            let noClip = await refused({ _ = try await client.ask("archiveClip", ["id": "x"]) })
            let noClipData = await refused({ _ = try await client.ask("archiveClipData", ["token": "x"]) })
            check("shares: shot search and clips refused without the browse right", noSearch && noClip && noClipData)
            server.setRights(.init(), for: device.id)
            let folders = try? await client.ask("proxyFolders"), status = try? await client.ask("proxyStatus", ["folder": id, "format": "light"])
            check("shares: older proxy actions work with the default rights", folders?["folders"] != nil && status?["files"] != nil)

            // A watched folder keeps getting proxies (files older than a minute: done copying).
            try? fm.setAttributes([.modificationDate: Date.now.addingTimeInterval(-300)], ofItemAtPath: root.appendingPathComponent("Day 2/clip3.mov").path)
            _ = try await client.ask("shareWatch", ["share": id, "path": "Day 2", "format": "light", "on": true])
            check("shares: a paired Mac turns keep-proxied on", shares.share(root)?.watch.contains(.init(path: "Day 2", format: .light)) == true)
            for _ in 0..<240 where !fm.fileExists(atPath: proxy3.path) || jobs.working != nil { try? await Task.sleep(for: .milliseconds(500)) }
            check("shares: a watched folder gets proxies", fm.fileExists(atPath: proxy3.path)
                  && jobs.requests.contains { $0.watch && $0.share == id && $0.state == .ready })

            // Same name, other extension: each its own proxy; the rest keep their names.
            try? fm.createDirectory(at: root.appendingPathComponent("Day 3"), withIntermediateDirectories: true)
            for name in ["A001.MXF", "A001.mp4", "B001.mov"] { fm.createFile(atPath: root.appendingPathComponent("Day 3/" + name).path, contents: Data([1])) }
            let names = ["A001.MXF", "A001.mp4", "B001.mov"].map { OfficeProxies.shared.proxyName("Day 3/" + $0, folder: id) }
            check("shares: videos with the same name get proxies of their own", names == ["Day 3/A001.MXF.mov", "Day 3/A001.mp4.mov", "Day 3/B001.mov"]
                  && OfficeProxies.clashing(["a/X.mov", "a/x.MXF", "b/X.mov", "a/Y.mov"]) == ["a/X.mov", "a/x.MXF"], "\(names)")
            // One encode at a time; a proxy the other worker made meanwhile isn't made again.
            let before = try? fm.attributesOfItem(atPath: proxy3.path)[.modificationDate] as? Date
            let skipped = await OfficeProxies.shared.makeOne(root.appendingPathComponent("Day 2/clip3.mov"), to: proxy3, format: .light,
                                                             ffmpeg: ffmpeg, ffprobe: ffprobe) { _ in }
            check("shares: a proxy already there isn't made again", skipped && (try? fm.attributesOfItem(atPath: proxy3.path)[.modificationDate] as? Date) == before)
        } catch {
            check("shares: round trip", false, error.localizedDescription)
        }
    }
}
