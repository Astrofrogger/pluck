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
        // Favourites in the browser's sidebar: kept per host Mac, added and taken out again.
        let starred = RemoteFinderSource.toggled(RemoteFinderSource.toggled("", share: share.id, path: "Day 1"), share: share.id, path: "Day 1/Cam A")
        check("pull: favourites keep the share and folder", RemoteFinderSource.favourites(starred).map { "\($0.share)|\($0.path)" } == ["\(share.id)|Day 1", "\(share.id)|Day 1/Cam A"], starred)
        check("pull: a favourite is taken out again", RemoteFinderSource.favourites(RemoteFinderSource.toggled(starred, share: share.id, path: "Day 1")).map(\.path) == ["Day 1/Cam A"])
        check("pull: favourites are per host Mac", RemoteFinderSource.favouritesKey.hasSuffix(client.office?.device.uuidString ?? "-"))
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
        await pinChecks(share: share, id: id, names: names, proxies: proxies, entries: entries)
    }

    /// Keep on This Mac: limits stop at the right file, a changed file comes again, a gone one is marked and only goes
    /// (to the Trash) on unpin, originals need their right, and the drive reads a pinned proxy from here.
    private static func pinChecks(share: OfficeRenderClient.RemoteShare, id: String, names: [String], proxies: [String: Data],
                                  entries: [[String: Any]]) async {
        let fm = FileManager.default, pins = RemotePins.shared
        PullTestManifest.entries = entries
        defer { for pin in pins.pins { pins.unpin(pin) } }
        let sizes = names.map { Int64(proxies[$0]!.count) }
        do {
            try await pins.pin(share: share, path: "Day 1", originals: false, limit: sizes[0] + sizes[1] + 100)
        } catch {
            return check("pins: a folder is pinned", false, error.localizedDescription)
        }
        guard var pin = pins.pins.first else { return check("pins: a folder is pinned", false) }
        let root = URL(fileURLWithPath: pin.destination, isDirectory: true)
        check("pins: the limit stops at the right file, nothing past it", pin.full && pin.here.map(\.proxy) == ["Day 1/A001.mov", "Day 1/A002.mov"]
              && pin.waiting == ["Day 1/A003.mov", "Day 1/A004.mov"] && !fm.fileExists(atPath: root.appendingPathComponent("Day 1/A003.mov").path),
              "\(pin.here.map(\.proxy)) \(pin.waiting)")
        pins.setLimit(1_000_000_000, for: pin)
        await pins.pass(pin.id)
        pin = pins.pins.first ?? pin
        check("pins: a raised limit fetches the rest", !pin.full && pin.here.count == 4
              && names.allSatisfy { (try? Data(contentsOf: root.appendingPathComponent("Day 1/" + $0))) == proxies[$0] }, "\(pin.here.count) \(pin.problem ?? "")")
        // A proxy made again on the host: fetched again.
        let changed = OfficeLink.randomBytes(5000), file = OfficeProxies.shared.proxy("Day 1/A001.mov", folder: id, format: .light)
        fm.createFile(atPath: file.path, contents: changed)
        PullTestManifest.entries = entries.map { var entry = $0; if entry["reel"] as? String == "A001.mov" { entry["size"] = changed.count; entry["checksum"] = SHA256Hex.of(changed) }; return entry }
        await pins.pass(pin.id)
        check("pins: a changed file is fetched again", (try? Data(contentsOf: root.appendingPathComponent("Day 1/A001.mov"))) == changed)
        // The drive: a pinned proxy is read from here, with no fetch at all; another checksum goes to the network.
        pin = pins.pins.first ?? pin
        if let kept = pin.here.first(where: { $0.proxy == "Day 1/A003.mov" }) {
            let fetches = FetchCount()
            let blocks = RemoteDriveBlocks(scope: "pin-test-\(UUID().uuidString)") { _, _, length in fetches.add(); return Data(count: length) }
            let read = try? await blocks.read(kept, offset: 10, count: 1000)
            var other = kept
            other.checksum = String(repeating: "0", count: 64)
            check("drive: a pinned file is read from this Mac with no fetch", read == proxies["A003.mov"]!.subdata(in: 10..<1010) && fetches.value == 0,
                  "\(fetches.value)")
            check("drive: a checksum that doesn't match goes to the network", RemotePins.localCopy(other) == nil && RemotePins.localCopy(kept) != nil)
            check("drive: with no office the pinned folder is still listed", pins.offlineManifest(id)?.entries.contains { $0.proxy == "Day 1/A003.mov" } == true)
        } else {
            check("drive: a pinned file is read from this Mac with no fetch", false, "not pinned")
        }
        // Gone from the office: marked, kept until unpinned, then to the Trash.
        PullTestManifest.entries = entries.filter { $0["reel"] as? String != "A002.mov" }
        fm.createFile(atPath: file.path, contents: proxies["A001.mov"])
        await pins.pass(pin.id)
        pin = pins.pins.first ?? pin
        let goneFile = root.appendingPathComponent("Day 1/A002.mov")
        check("pins: a file gone from the office is marked and kept", pin.gone == ["Day 1/A002.mov"] && fm.fileExists(atPath: goneFile.path), "\(pin.gone)")
        // A full volume: nothing more is fetched, and it says so.
        let plan = RemotePins.fit([RemoteManifestEntry(share: id, path: "a", proxy: "a", reel: "a", size: 10)], used: 0, limit: 100, others: 0, total: 1000,
                                  free: 25_000_000_005, floor: 25_000_000_000)
        check("pins: a full volume pauses the pin", plan.full && plan.now.isEmpty && plan.later.count == 1)
        let totalPlan = RemotePins.fit([RemoteManifestEntry(share: id, path: "a", proxy: "a", reel: "a", size: 10)], used: 0, limit: 100, others: 995, total: 1000,
                                       free: Int64.max / 2, floor: 0)
        check("pins: the limit for all pins together counts", totalPlan.full)
        pins.unpin(pin)
        check("pins: unpinning puts its files in the Trash", !fm.fileExists(atPath: goneFile.path) && pins.pins.isEmpty)
        // Originals need the right (not given to this Mac): refused, nothing pinned.
        let refused = await { do { try await pins.pin(share: share, path: "Day 1", originals: true); return false } catch { return true } }()
        check("pins: originals need their right", refused && pins.pins.isEmpty)
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
