import Foundation

extension PhotoSelfTest {
    /// The host's shares and proxies (-PluckScreenshotOnly remoteshares): a share in the test home
    /// with small clips made by the bundled ffmpeg, a missing share, and a client paired over this
    /// Mac. Offline shares say so (fast), bookmarks find a moved folder, proxies of a subfolder only,
    /// proxies keep length, channels, timecode and reel, the manifest carries each proxy's SHA-256,
    /// older proxyData originals follow the originals right, a watched folder gets proxies, old search messages
    /// are politely refused, and the proxies made are listed per folder and deleted.
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
        await shares.sync()
        check("shares: new shares get a bookmark and volume", shares.share(moving)?.bookmark != nil && shares.share(moving)?.volume != nil)
        let movingID = OfficeProxies.id(moving)
        try? fm.moveItem(at: moving, to: moved)
        await shares.sync()
        check("shares: a moved share is found again", archive.folders.contains { $0.path == moved.path } && !archive.folders.contains { $0.path == moving.path }
              && shares.share(moved) != nil, "\(archive.folders.map(\.path)) \(shares.shares.map(\.path)) want \(moved.path)")
        check("shares: a moved share keeps its id", OfficeProxies.id(moved) == movingID && movingID == OfficeProxies.pathID(moving.path),
              "\(OfficeProxies.id(moved)) vs \(movingID)")
        archive.add(moving)
        await shares.sync()
        check("shares: a new folder where a moved one was gets its own id", OfficeProxies.id(moving) != movingID)
        archive.remove(moving)
        archive.remove(moved)
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
            // Folder roles: No Access on "Day 1/A" hides it from browsing and the manifest, and its files are refused.
            let access = OfficeAccess.shared, lockedKey = OfficeAccess.folderKey(root: root, share: id, relative: "day 1/a")
            access.set(subject: device.id.uuidString, folder: lockedKey, role: OfficeAccess.Role.none)
            let hiddenWhole = try await client.ask("shareManifest", ["share": id, "path": "", "format": "light"])
            let day1 = try await client.browse(share: id, path: "Day 1")
            check("shares: a No Access folder is left out of the manifest", (hiddenWhole["entries"] as? [[String: Any]])?.count == 1
                  && (hiddenWhole["entries"] as? [[String: Any]])?.contains { ($0["path"] as? String)?.hasPrefix("Day 1/A/") == true } == false, "\(hiddenWhole["entries"] ?? "")")
            check("shares: a No Access folder isn't listed when browsing", !day1.contains { $0.name == "A" } && day1.contains { $0.name == "clip2.mov" },
                  "\(day1.map(\.name))")
            let lockedFile = await refused({ _ = try await client.fileData(share: id, path: "Day 1/A/clip1.mov", kind: .proxy, offset: 0) })
            let lockedList = await refused({ _ = try await client.browse(share: id, path: "Day 1/A") })
            check("shares: a No Access folder's files and listing are refused", lockedFile && lockedList)
            access.set(subject: device.id.uuidString, folder: lockedKey, role: nil)
            let shownAgain = try await client.ask("shareManifest", ["share": id, "path": "", "format": "light"])
            check("shares: taking the folder role away shows it again", (shownAgain["entries"] as? [Any])?.count == 2)
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
            server.setRights(.init(), for: device.id)
            // Find Shots is gone: an older Mac asking to search is told so, and the host keeps answering.
            var unsupported = true
            for (action, arguments) in [("archive", [:]), ("archiveSearch", ["query": "x"]), ("archiveClip", ["id": "x"]),
                                        ("archiveClipData", ["token": "x"])] as [(String, [String: Any])] {
                do {
                    _ = try await client.ask(action, arguments)
                    unsupported = false
                } catch {
                    if !error.localizedDescription.contains("search footage") { unsupported = false; print("\(action): \(error.localizedDescription)") }
                }
            }
            check("shares: old archive search messages get a polite not-supported answer", unsupported)
            check("shares: the shares answer has no search flag", (try await client.ask("shares")["shares"] as? [[String: Any]])?.allSatisfy { $0["search"] == nil } == true)
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

            // Proxies made on this Mac: a request asked here isn't a watch; listed per folder, still after the folder
            // stops being shared, and deleted on request.
            let asked = jobs.add(.init(share: id, paths: ["Day 1"], format: .light, device: nil, byHost: true))
            check("shares: a request made on this Mac isn't a watch", !asked.watch && jobs.requests.contains { $0.id == asked.id })
            jobs.remove(asked.id)
            check("shares: a share says what it's on", online.kind != nil && !online.network, "\(online)")
            let madeHere = await OfficeProxies.shared.made() ?? []
            let light = madeHere.first { $0.share == id && $0.format == .light }
            check("shares: made proxies are listed per folder", light?.clips == 3 && light?.name == "Share" && (light?.bytes ?? 0) > 0,
                  "\(madeHere.map { "\($0.name) \($0.format) \($0.clips)" })")
            if let light {
                archive.remove(root)
                let kept = await OfficeProxies.shared.made() ?? []
                check("shares: proxies of a folder no longer shared stay listed", kept.contains { $0.url == light.url && $0.name == "Share" })
                // Only the counted proxies go, to the Trash: anything else there stays, and so does the folder then.
                let other = light.url.appendingPathComponent("notes.txt")
                fm.createFile(atPath: other.path, contents: Data("keep".utf8))
                let trashed = await OfficeProxies.shared.delete(light)
                let gone = await OfficeProxies.shared.made() ?? []
                check("shares: deleting proxies moves only them to the Trash", !fm.fileExists(atPath: proxy3.path) && fm.fileExists(atPath: other.path)
                      && trashed.count == 3 && trashed.allSatisfy { fm.fileExists(atPath: $0.path) } && !gone.contains { $0.url == light.url },
                      "\(trashed.map(\.lastPathComponent))")
                for file in trashed { try? fm.removeItem(at: file) }
                try? fm.removeItem(at: other)
                await OfficeProxies.shared.delete(light, trash: false)
                check("shares: Pluck's own proxies folder goes once empty", !fm.fileExists(atPath: light.url.path))
                archive.add(root)
            }

            // Tidying by last use: any proxy folder in Pluck's own (streaming stand-ins too); one used lately stays.
            let keepDays = UserDefaults.standard.object(forKey: OfficeProxies.keepDaysKey)
            UserDefaults.standard.set(7, forKey: OfficeProxies.keepDaysKey)
            let tag = UUID().uuidString.prefix(6).lowercased()
            let unused = OfficeProxies.root.appendingPathComponent("old\(tag)-stream"), recent = OfficeProxies.root.appendingPathComponent("new\(tag)-stream")
            for folder in [unused, recent] {
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                fm.createFile(atPath: folder.appendingPathComponent("a.mov").path, contents: Data([1]))
                try? fm.setAttributes([.modificationDate: Date.now.addingTimeInterval(-30 * 86_400)], ofItemAtPath: folder.appendingPathComponent("a.mov").path)
            }
            OfficeProxies.shared.used("new\(tag)", format: .stream)
            await OfficeProxies.shared.tidy()
            check("shares: proxies unused for the kept days are tidied, ones used lately stay",
                  !fm.fileExists(atPath: unused.path) && fm.fileExists(atPath: recent.appendingPathComponent("a.mov").path))
            try? fm.removeItem(at: recent)
            UserDefaults.standard.set(keepDays, forKey: OfficeProxies.keepDaysKey)

            // Shares saved for older builds: still with "search", streaming watches apart; and older lists still read.
            struct OldShare: Decodable { var path: String; var search: Bool; var watch: [OldWatch] }
            struct OldWatch: Decodable { var path: String; var format: OldFormat }
            enum OldFormat: String, Decodable { case light, prores, original }
            let saving = [RemoteShares.Share(path: "/a", id: "x", watch: [.init(path: "", format: .light), .init(path: "B", format: .stream)])]
            let stored = RemoteShares.encoded(saving)
            let old = stored.shares.flatMap { try? JSONDecoder().decode([OldShare].self, from: $0) }
            let back = RemoteShares.decoded(stored.shares, stream: stored.stream)
            let olderList = RemoteShares.decoded(Data(#"[{"path":"/b","search":false,"watch":[]},{"path":"/c"}]"#.utf8), stream: nil)
            check("shares: older builds still read the saved shares, and nothing is lost on the way back",
                  old?.first?.search == true && old?.first?.watch.map(\.path) == [""] && back == saving
                  && olderList.map(\.path) == ["/b", "/c"] && olderList.allSatisfy { $0.watch.isEmpty },
                  "\(String(data: stored.shares ?? Data(), encoding: .utf8) ?? "")")
        } catch {
            check("shares: round trip", false, error.localizedDescription)
        }
    }
}
