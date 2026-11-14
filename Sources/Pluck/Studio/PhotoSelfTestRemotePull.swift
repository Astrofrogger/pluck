import CryptoKit
import Foundation

extension PhotoSelfTest {
    /// The remote editor's browsing and pulls (-PluckScreenshotOnly remotepull), host and client in
    /// this test copy over this Mac: the Library Finder on a remote source lists the share read only,
    /// a pull fetches four proxies at once, carries on a part fetched before, fetches again a part
    /// whose checksum is wrong, writes the share's manifest, pauses, and originals without the
    /// right are refused in plain words.
    static func remotePullTest() async {
        let fm = FileManager.default
        UserDefaults.standard.set(Int.random(in: 47_900...48_900), forKey: "PluckScreenshotPort")
        let base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("RemotePullTest-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Share", isDirectory: true), local = base.appendingPathComponent("Here", isDirectory: true)
        try? fm.createDirectory(at: root.appendingPathComponent("Day 1"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: local, withIntermediateDirectories: true)
        let id = OfficeProxies.id(root)
        let names = ["A001.mov", "A002.mov", "A003.mov", "A004.mov"]
        var proxies: [String: Data] = [:]
        for (n, name) in names.enumerated() {
            fm.createFile(atPath: root.appendingPathComponent("Day 1/" + name).path, contents: Data(repeating: UInt8(n), count: 1000))
            let proxy = OfficeLink.randomBytes((9 << 20) + n * 7_777)
            let file = OfficeProxies.shared.proxy("Day 1/" + name, folder: id, format: .light)
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: file.path, contents: proxy)
            proxies[name] = proxy
        }
        fm.createFile(atPath: root.appendingPathComponent("notes.txt").path, contents: Data("hi".utf8))

        // The host's real manifest (RemoteProxyJobs) first; a fake one later for a checksum that never matches.
        let entries: [[String: Any]] = names.map { name in
            let data = proxies[name]!
            return ["share": id, "path": "Day 1/" + name, "proxy": "Day 1/" + name, "reel": name, "size": data.count,
                    "checksum": SHA256Hex.of(data)]
        }
        let action = "pullTestManifest"
        PullTestManifest.entries = entries
        let savedAction = RemotePullClient.manifestAction

        let server = OfficeRenderServer.shared, client = OfficeRenderClient.shared, archive = OfficeArchive.shared, pulls = RemotePullManager.shared
        archive.add(root)
        archive.stop()
        server.start()
        for _ in 0..<100 where !server.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        // (After the server registers everyone's actions: registerAll runs only while there are none.)
        OfficeActions.registerAll()
        if OfficeActions.handler(action) == nil {
            OfficeActions.register(action) { _, _ in ["entries": PullTestManifest.entries, "pending": 0] }
        }
        defer {
            for job in pulls.jobs { pulls.remove(job) }
            RemotePullClient.manifestAction = savedAction
            for name in names { try? fm.removeItem(at: OfficeProxies.shared.proxy("Day 1/" + name, folder: id, format: .light)) }
            try? fm.removeItem(at: base)
            client.forget()
            for device in server.devices { server.remove(device) }
            archive.remove(root)
            server.stop()
            UserDefaults.standard.removeObject(forKey: "PluckScreenshotPort")
        }
        server.startPairing()
        guard let code = server.pairing?.code else { return check("pull: pairing code", false, server.problem ?? "") }
        do {
            try await client.pair(.address("127.0.0.1"), code: code)
        } catch {
            return check("pull: paired over this Mac", false, error.localizedDescription)
        }

        let listed: [OfficeRenderClient.RemoteShare]
        do { listed = try await client.shares() } catch { return check("pull: the share is listed", false, error.localizedDescription) }
        guard let share = listed.first(where: { $0.id == id }) else { return check("pull: the share is listed", false, "\(listed)") }

        // Browsing: the Library's Finder pane on the remote source.
        let source = RemoteFinderSource(share: share)
        let pane = FinderPane(url: source.root, base: source.root, source: source)
        for _ in 0..<200 where pane.loading { try? await Task.sleep(for: .milliseconds(20)) }
        check("pull: the Finder pane lists the share, folders first", pane.shown.map(\.name) == ["Day 1", "notes.txt"], "\(pane.shown.map(\.name)) \(source.problem ?? "")")
        check("pull: stand-in paths map back to the share", source.relative(pane.shown[0].url) == "Day 1" && source.relative(source.root).isEmpty)
        if let day = pane.shown.first {
            pane.open(day)
            for _ in 0..<200 where pane.loading || pane.shown.first?.name != "A001.mov" { try? await Task.sleep(for: .milliseconds(20)) }
        }
        check("pull: going into a folder lists it, clips known by the host", pane.shown.map(\.name) == names && pane.shown.allSatisfy(\.isClip),
              "\(pane.shown.map(\.name))")
        check("pull: the path bar runs from the share", pane.pathComponents.map(\.lastPathComponent) == [source.root.lastPathComponent, "Day 1"])
        pane.selection = [pane.shown[0].url]
        pane.beginRename()
        pane.trashSelection()
        check("pull: the remote pane is read only (no rename, no Trash)", pane.naming == nil && pane.trashing.isEmpty)
        pane.goUp()
        pane.goUp()
        check("pull: up stops at the share's top", pane.url == source.root, pane.url.path)
        // Pictures for the source's files come from the host (its thumb), not this Mac's thumbnailer.
        let thumbs = FinderThumbnails.shared, note = source.url("notes.txt")
        let direct = await source.picture(note)
        thumbs.register(source)
        thumbs.wantPicture(note)
        for _ in 0..<200 where thumbs.pictures[note] == nil { try? await Task.sleep(for: .milliseconds(20)) }
        thumbs.forgetPicture(note)
        thumbs.unregister(source)
        check("pull: the Finder's pictures of remote files come from the host", direct != nil && thumbs.pictures[note] != nil)

        // Originals need their right; the refusal is said plainly.
        do {
            try await pulls.pullOriginal(share: share, path: "Day 1/A001.mov", into: local)
            check("pull: originals refused without the right", false)
        } catch {
            check("pull: originals refused without the right, in plain words",
                  RemoteFinderSource.refusal(error) == String(localized: "The host Mac doesn’t let this Mac fetch originals. Its owner can allow it under Share this Mac."),
                  RemoteFinderSource.refusal(error))
        }

        // An original's path out of the folder here never becomes a pull.
        let jobsBefore = pulls.jobs.count
        let escaped = await { do { try await pulls.pullOriginal(share: share, path: "../escape.mov", into: local); return false } catch { return true } }()
        check("pull: an original's path out of the folder is refused", escaped && pulls.jobs.count == jobsBefore)

        // A part fetched before (the first 3 MB, right) and a whole one that's wrong.
        let resumed = 3 << 20
        try? fm.createDirectory(at: local.appendingPathComponent("Day 1"), withIntermediateDirectories: true)
        fm.createFile(atPath: local.appendingPathComponent("Day 1/A002.mov.part").path, contents: proxies["A002.mov"]!.prefix(resumed))
        var damaged = proxies["A003.mov"]!
        damaged[100] ^= 0xFF
        fm.createFile(atPath: local.appendingPathComponent("Day 1/A003.mov.part").path, contents: damaged)

        pulls.setRoot(local, for: id)
        pulls.pull(share: share, paths: ["Day 1"], format: .light, into: local)
        guard let job = pulls.jobs.first(where: { $0.share == id }) else { return check("pull: the pull is kept", false) }

        pulls.setPaused(job, true)
        let before = pulls.fetched
        _ = await pulls.pass(pulls.jobs.first { $0.id == job.id }!)
        check("pull: a paused pull fetches nothing", pulls.fetched == before, "\(pulls.fetched - before)")
        pulls.setPaused(job, false)

        var most = 0
        let watching = Task { @MainActor in
            while !Task.isCancelled {
                most = max(most, pulls.progress[job.id]?.current.count ?? 0)
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        let more = await pulls.pass(pulls.jobs.first { $0.id == job.id }!)
        watching.cancel()
        let sizes = names.map { proxies[$0]!.count }
        // A001, A004 whole; A002 from 3 MB; A003 checked (wrong), then whole again.
        let expected = Int64(sizes[0] + sizes[3] + sizes[1] - resumed + sizes[2])
        check("pull: done in one pass", !more && pulls.progress[job.id]?.finished == true, "\(String(describing: pulls.progress[job.id]))")
        check("pull: files fetched side by side", most >= 2, "at most \(most) at once")
        check("pull: the part fetched before is carried on, the damaged one fetched again", pulls.fetched - before == expected,
              "\(pulls.fetched - before) vs \(expected)")
        let same = names.allSatisfy { (try? Data(contentsOf: local.appendingPathComponent("Day 1/" + $0))) == proxies[$0] }
        check("pull: every proxy equals the host's, no parts left", same
              && !names.contains { fm.fileExists(atPath: local.appendingPathComponent("Day 1/\($0).part").path) })
        let manifest = RemoteManifest.load(in: local)
        check("pull: the share's manifest maps each proxy", manifest?.share == id && manifest?.shareName == "Share"
              && manifest?.entries.map(\.proxy) == names.map { "Day 1/" + $0 } && manifest?.entry(forProxy: "Day 1/A002.mov")?.path == "Day 1/A002.mov",
              "\(String(describing: manifest?.entries.map(\.proxy)))")
        check("pull: the pulled folder is offered to the Resolve round trip", pulls.pulledRoot(for: id) == local)

        // A file whose checksum never matches: the others carry on, it waits for the next pass.
        RemotePullClient.manifestAction = action
        PullTestManifest.entries = entries.map { var entry = $0; if entry["reel"] as? String == "A004.mov" { entry["checksum"] = String(repeating: "0", count: 64) }; return entry }
        try? fm.removeItem(at: local.appendingPathComponent("Day 1/A004.mov"))
        let again = await pulls.pass(pulls.jobs.first { $0.id == job.id }!)
        check("pull: a file that keeps failing is tried again later, not taken", again && pulls.progress[job.id]?.failed["Day 1/A004.mov"] != nil
              && !fm.fileExists(atPath: local.appendingPathComponent("Day 1/A004.mov").path))
    }
}

/// The test host's manifest (changed between passes).
@MainActor
enum PullTestManifest {
    static var entries: [[String: Any]] = []
}

enum SHA256Hex {
    static func of(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
