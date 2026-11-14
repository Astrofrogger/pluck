import Foundation

extension PhotoSelfTest {
    /// Pluck's own drive (-PluckScreenshotOnly remotedrive): XDR and RPC pieces, the drive's tree and block cache,
    /// then a real mount over a loopback pairing (127.0.0.1, under the test home, hidden): list, exact bytes, manifest, unmount.
    static func remoteDriveTest() async {
        // XDR.
        var writer = XDRWriter()
        writer.u32(7); writer.u64(1 << 40 + 5); writer.string("abcde"); writer.bool(true)
        check("drive: XDR pads to 4 bytes", writer.data.count == 4 + 8 + 4 + 8 + 4)
        var reader = XDRReader(writer.data)
        check("drive: XDR reads back", (try? reader.u32()) == 7 && (try? reader.u64()) == 1 << 40 + 5
              && (try? reader.string()) == "abcde" && (try? reader.u32()) == 1)
        check("drive: XDR refuses a short or oversized read", (try? reader.u32()) == nil && {
            var big = XDRWriter(); big.u32(500)
            var r = XDRReader(big.data); return (try? r.opaque(max: 64)) == nil
        }())

        // RPC replies (no network): calls built by hand as mount_nfs sends them.
        let entries = [RemoteManifestEntry(share: "s1", path: "Day 1/A001.MXF", proxy: "Day 1/A001.mov", reel: "A001", size: 9_000_001, checksum: "aa"),
                       RemoteManifestEntry(share: "s1", path: "B002.MXF", proxy: "B002.mov", reel: "B002", size: 10),
                       RemoteManifestEntry(share: "s1", path: "x", proxy: "../escape.mov", reel: "x", size: 1),
                       RemoteManifestEntry(share: "s1", path: "y", proxy: "a/./b.mov", reel: "y", size: 1)]
        let manifest = RemoteManifest(host: "h", hostName: "Host", share: "s1", shareName: "Footage", entries: entries)
        let bytes = Data((0..<9_000_001).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 9) })
        let fetches = FetchCount()
        let drive = RemoteShareDrive(cacheKey: "test-\(UUID().uuidString)") { original, offset, length in
            fetches.add()
            guard original == "Day 1/A001.MXF" else { throw RemoteDriveError.noEntry }
            return bytes.subdata(in: Int(offset)..<Int(offset) + length)
        }
        drive.update(manifest)
        let tree = drive.current
        check("drive: tree holds the safe proxies, folders and the manifest", tree.children[""] == [RemoteManifest.fileName, "B002.mov", "Day 1"]
              && tree.children["Day 1"] == ["Day 1/A001.mov"] && tree.nodes["../escape.mov"] == nil && tree.nodes["a/./b.mov"] == nil, "\(tree.children)")
        check("drive: synthesized manifest decodes", (try? JSONDecoder().decode(RemoteManifest.self, from: tree.manifest))?.entries.count == 4)
        let server = RemoteDriveServer(backend: drive)
        func call(_ program: UInt32, _ version: UInt32, _ procedure: UInt32, flavor: UInt32 = 1, _ args: (inout XDRWriter) -> Void = { _ in }) async -> XDRReader? {
            var out = XDRWriter()
            out.u32(42); out.u32(0); out.u32(2); out.u32(program); out.u32(version); out.u32(procedure)
            out.u32(flavor); out.opaque(Data(count: 8)); out.u32(0); out.u32(0)
            args(&out)
            return await server.reply(to: out.data).map { XDRReader($0) }
        }
        /// The reply's first six words (xid, REPLY, accepted, verifier, accept state) and the rest to read on.
        func parts(_ reply: XDRReader?) -> ([UInt32], XDRReader?) {
            guard var reply else { return ([], nil) }
            return ((0..<6).compactMap { _ in try? reply.u32() }, reply)
        }
        func head(_ reply: XDRReader?) -> [UInt32] { parts(reply).0 }
        check("drive: NFS NULL accepted", head(await call(100003, 3, 0)) == [42, 1, 0, 0, 0, 0])
        check("drive: unknown program", head(await call(100021, 4, 0)) == [42, 1, 0, 0, 0, 1])
        check("drive: NFS v2 is a version mismatch", head(await call(100003, 2, 0)).prefix(6) == [42, 1, 0, 0, 0, 2])
        check("drive: Kerberos and other credentials refused", head(await call(100003, 3, 0, flavor: 6)).prefix(4) == [42, 1, 1, 1])
        var closed = parts(await call(100005, 3, 1) { $0.string("/pluck") }).1
        check("drive: no root handle outside Pluck's own mount", (try? closed?.u32()) == 13)
        server.allowMount(true)
        var mounted = parts(await call(100005, 3, 1) { $0.string("/pluck") }).1
        let rootHandle = (try? mounted?.u32()) == 0 ? try? mounted?.opaque(max: 64) : nil
        check("drive: MNT gives the root handle", rootHandle == server.handle(""))
        var missing = parts(await call(100005, 3, 1) { $0.string("/other") }).1
        check("drive: MNT of another path is refused", (try? missing?.u32()) == 2)
        var stale = parts(await call(100003, 3, 1) { $0.opaque(Data(repeating: 9, count: 16)) }).1
        check("drive: unknown handle is stale", (try? stale?.u32()) == 70)
        var write = parts(await call(100003, 3, 7) { $0.opaque(server.handle("")) }).1
        check("drive: writing is a read-only file system", (try? write?.u32()) == 30)
        check("drive: handles stable per path", server.handle("Day 1/A001.mov") == RemoteDriveServer(backend: drive).handle("Day 1/A001.mov")
              && server.handle("a") != server.handle("b"))

        // Blocks: exact bytes across block edges, fetched once, then from the cache.
        let entry = entries[0]
        let edge = Int64(RemoteDriveBlocks.blockSize)
        let piece = try? await drive.read("Day 1/A001.mov", offset: edge - 100, count: 300)
        check("drive: a read across a block edge is exact", piece == bytes.subdata(in: Int(edge) - 100..<Int(edge) + 200))
        let tail = try? await drive.blocks.read(entry, offset: entry.size - 5, count: 100)
        check("drive: the end of the file is short, not padded", tail == bytes.suffix(5))
        try? await Task.sleep(for: .milliseconds(300)) // read-ahead settles
        let before = fetches.value
        let again = try? await drive.read("Day 1/A001.mov", offset: 10, count: 1000)
        check("drive: cached blocks aren't fetched again", again == bytes.subdata(in: 10..<1010) && fetches.value == before, "\(before) → \(fetches.value)")
        check("drive: the manifest file reads in pieces", (try? await drive.read(RemoteManifest.fileName, offset: 2, count: 5)) == tree.manifest.subdata(in: 2..<7))
        RemoteDriveBlocks.trim(to: 0)
        check("drive: the cache trims to its cap", RemoteDriveBlocks.usage().isEmpty)

        // Reads and fetches ahead share one limit of fetches at the host at once.
        let gauge = FetchCount()
        let slow = RemoteShareDrive(cacheKey: "test-\(UUID().uuidString)") { _, offset, length in
            gauge.enter()
            defer { gauge.leave() }
            try await Task.sleep(for: .milliseconds(60))
            return bytes.subdata(in: Int(offset)..<Int(offset) + length)
        }
        let big = RemoteManifestEntry(share: "s1", path: "Day 1/A001.MXF", proxy: "Day 1/A001.mov", reel: "A001", size: 9_000_001, checksum: "bb")
        slow.update(RemoteManifest(host: "h", hostName: "Host", share: "s1", shareName: "Footage", entries: [big]))
        await withTaskGroup(of: Void.self) { group in
            for block in 0..<3 {
                for reader in 0..<3 {
                    group.addTask { _ = try? await slow.read("Day 1/A001.mov", offset: Int64(block) * edge + Int64(reader), count: 10) }
                }
            }
        }
        check("drive: at most four fetches at the host at once", gauge.most <= RemoteDriveBlocks.maxFetches && gauge.most > 0, "\(gauge.most)")
        RemoteDriveBlocks.trim(to: 0)
        check("drive: mount points carry the share's id", RemoteNetwork.mountPoint(host: "Host", share: "Footage", id: "aaaa1111")
              != RemoteNetwork.mountPoint(host: "Host", share: "Footage", id: "bbbb2222"))

        // Modes, as views read them.
        check("drive: stream modes per share", RemoteProxyMode.of("b", in: "a\nb") == .stream && RemoteProxyMode.of("c", in: "a\nb") == .download
              && RemoteProxyMode.of("a", in: "ab") == .download)
        let defaults = UserDefaults.standard, savedModes = defaults.object(forKey: RemoteProxyMode.key)
        defaults.removeObject(forKey: RemoteProxyMode.key)
        defaults.set(["s1": "stream", "s2": "download"], forKey: "editAnywhereShareModes")
        RemoteProxyMode.migrate()
        check("drive: earlier saved modes carried over", RemoteProxyMode.of("s1") == .stream && RemoteProxyMode.of("s2") == .download
              && defaults.object(forKey: "editAnywhereShareModes") == nil)
        defaults.set(savedModes, forKey: RemoteProxyMode.key)
        check("drive: speed verdicts by format", RemoteNetwork.quality(speed: 10e6, format: "light") == .smooth
              && RemoteNetwork.quality(speed: 10e6, format: "prores") == .usable && RemoteNetwork.quality(speed: 1e6, format: "prores") == .slow)

        await driveLoopback()
    }

    final class FetchCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var now = 0, highest = 0
        func add() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func enter() { lock.lock(); now += 1; highest = max(highest, now); lock.unlock() }
        func leave() { lock.lock(); now -= 1; lock.unlock() }
        var most: Int { lock.lock(); defer { lock.unlock() }; return highest }
    }

    /// A real mount: a paired host on this Mac, a share with one proxy, mounted by RemoteNetwork.
    private static func driveLoopback() async {
        let fm = FileManager.default
        UserDefaults.standard.set(Int.random(in: 47_900...48_900), forKey: "PluckScreenshotPort")
        let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("RemoteDriveShare-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: root.appendingPathComponent("Day 1"), withIntermediateDirectories: true)
        fm.createFile(atPath: root.appendingPathComponent("Day 1/A001.mp4").path, contents: Data(repeating: 1, count: 100))
        let server = OfficeRenderServer.shared, client = OfficeRenderClient.shared, archive = OfficeArchive.shared, network = RemoteNetwork.shared
        archive.add(root)
        archive.stop()
        let id = OfficeProxies.id(root)
        let proxy = OfficeProxies.shared.proxy("Day 1/A001.mp4", folder: id, format: .light)
        try? fm.createDirectory(at: proxy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data((0..<9_437_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 >> 11) })
        fm.createFile(atPath: proxy.path, contents: bytes)
        let proxyTop = proxy.deletingLastPathComponent().deletingLastPathComponent()
        let saved = (UserDefaults.standard.object(forKey: RemoteNetworkHost.streamKey), UserDefaults.standard.object(forKey: "editAnywhereProxyFormat"))
        UserDefaults.standard.set("light", forKey: "editAnywhereProxyFormat")
        server.start()
        for _ in 0..<100 where !server.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        defer {
            client.forget()
            for device in server.devices { server.remove(device) }
            archive.remove(root)
            server.stop()
            try? fm.removeItem(at: root)
            try? fm.removeItem(at: proxyTop)
            try? fm.removeItem(at: RemoteDriveBlocks.folder)
            UserDefaults.standard.set(saved.0, forKey: RemoteNetworkHost.streamKey)
            UserDefaults.standard.set(saved.1, forKey: "editAnywhereProxyFormat")
            UserDefaults.standard.removeObject(forKey: "PluckScreenshotPort")
        }
        server.startPairing()
        guard let code = server.pairing?.code else { return check("drive: pairing code", false) }
        do {
            try await client.pair(.address("127.0.0.1"), code: code)
            UserDefaults.standard.set(false, forKey: RemoteNetworkHost.streamKey)
            var refused = false
            do { try await network.mount(id) } catch { refused = (error as? RemoteNetwork.Failure) == .notAllowed }
            check("drive: streaming off on the host: not mounted", refused && network.hostAllows == false)
            var pieceRefused = false
            do { _ = try await client.ask("fileData", ["share": id, "path": "Day 1/A001.mp4", "kind": "proxy", "offset": 0, "length": 10, "stream": true]) } catch { pieceRefused = true }
            check("drive: streaming off: the host refuses streamed pieces", pieceRefused)
            UserDefaults.standard.set(true, forKey: RemoteNetworkHost.streamKey)

            let point = try await network.mount(id)
            check("drive: mounted under the test home, hidden", RemoteDriveMount.isMounted(point) && point.path.hasPrefix(NSHomeDirectory())
                  && point.path.contains("Edit Anywhere/Drives"), point.path)
            // Reads off the main thread: the drive's fetches need it.
            let seen = await Task.detached { () -> (top: [String], day: [String], manifest: RemoteManifest?, pieces: [Data], whole: Data?) in
                let fm = FileManager.default
                let file = point.appendingPathComponent("Day 1/A001.mov")
                var pieces: [Data] = []
                if let handle = try? FileHandle(forReadingFrom: file) {
                    for (offset, count) in [(0, 64), (4_194_300, 10), (9_436_990, 50), (1_000_000, 3_000_000)] {
                        try? handle.seek(toOffset: UInt64(offset))
                        pieces.append((try? handle.read(upToCount: count)) ?? Data())
                    }
                    try? handle.close()
                }
                return ((try? fm.contentsOfDirectory(atPath: point.path).sorted()) ?? [],
                        (try? fm.contentsOfDirectory(atPath: point.appendingPathComponent("Day 1").path)) ?? [],
                        RemoteManifest.load(in: point), pieces, try? Data(contentsOf: file))
            }.value
            check("drive: lists the share's proxies and the manifest", seen.top == [RemoteManifest.fileName, "Day 1"] && seen.day == ["A001.mov"], "\(seen.top) \(seen.day)")
            check("drive: manifest in the mount names the share", seen.manifest?.share == id && seen.manifest?.entries.first?.proxy == "Day 1/A001.mov")
            check("drive: exact bytes at offsets", seen.pieces == [bytes.subdata(in: 0..<64), bytes.subdata(in: 4_194_300..<4_194_310),
                                                                    bytes.subdata(in: 9_436_990..<9_437_000), bytes.subdata(in: 1_000_000..<4_000_000)])
            check("drive: the whole file reads back", seen.whole == bytes)
            check("drive: writing is refused", await Task.detached { !FileManager.default.createFile(atPath: point.appendingPathComponent("x").path, contents: Data()) }.value)
            check("drive: proxy root through the hook", (try? await RemoteHooks.networkProxyRoot?(id)) == point)
            check("drive: the mount point carries the share's id", point.lastPathComponent.hasSuffix(" " + id.prefix(8)), point.path)
            await network.unmount(id)
            check("drive: unmounted clean", !RemoteDriveMount.isMounted(point) && network.state(id) == .idle)

            // Two asking at once share one mount; Disconnect during a mount leaves nothing behind.
            async let first = network.mount(id)
            async let second = network.mount(id)
            let both = try await [first, second]
            check("drive: two mounts at once share one", both[0] == both[1] && RemoteDriveMount.isMounted(both[0]))
            await network.unmount(id)
            let late = Task { try await network.mount(id) }
            for _ in 0..<200 where network.state(id) != .mounting { await Task.yield() }
            await network.unmount(id)
            _ = try? await late.value
            check("drive: Disconnect during a mount leaves nothing mounted", !RemoteDriveMount.isMounted(point) && network.state(id) == .idle,
                  "\(network.state(id))")
        } catch {
            check("drive: round trip", false, error.localizedDescription)
            await network.unmount(id)
        }
    }
}
