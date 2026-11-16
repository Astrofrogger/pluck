import AppKit

extension PhotoSelfTest {
    /// Remote editing's protocol (-PluckScreenshotOnly remoteedit): a host and a client in this
    /// test copy (own port and keys) over this Mac, with a share in the test home. Browsing lists
    /// it sorted without hidden or system files, paths out of the share (`..`, symlinks, absolute)
    /// are refused, file pieces equal the file's bytes, originals need their right.
    static func remoteEditTest() async {
        let fm = FileManager.default
        UserDefaults.standard.set(Int.random(in: 47_900...48_900), forKey: "PluckScreenshotPort")
        let base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("RemoteEditTest-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Share", isDirectory: true), outside = base.appendingPathComponent("Outside", isDirectory: true)
        try? fm.createDirectory(at: root.appendingPathComponent("B Folder"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: root.appendingPathComponent("@eaDir"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let bytes = OfficeLink.randomBytes((9 << 20) + 12_345)
        fm.createFile(atPath: root.appendingPathComponent("big.bin").path, contents: bytes)
        fm.createFile(atPath: root.appendingPathComponent("a clip.mov").path, contents: Data(repeating: 7, count: 100))
        fm.createFile(atPath: root.appendingPathComponent(".hidden").path, contents: Data([1]))
        fm.createFile(atPath: root.appendingPathComponent("B Folder/inner.txt").path, contents: Data("in".utf8))
        fm.createFile(atPath: outside.appendingPathComponent("secret.txt").path, contents: Data("secret".utf8))
        try? fm.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        try? fm.createSymbolicLink(at: root.appendingPathComponent("escape.txt"), withDestinationURL: outside.appendingPathComponent("secret.txt"))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        fm.createFile(atPath: root.appendingPathComponent("pic.png").path, contents: rep?.representation(using: .png, properties: [:]))

        let server = OfficeRenderServer.shared, client = OfficeRenderClient.shared, archive = OfficeArchive.shared
        archive.add(root)
        server.start()
        for _ in 0..<100 where !server.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        defer {
            client.forget()
            for device in server.devices { server.remove(device) }
            archive.remove(root)
            server.stop()
            UserDefaults.standard.removeObject(forKey: "PluckScreenshotPort")
        }
        server.startPairing()
        guard let code = server.pairing?.code else { return check("remote: pairing code", false, server.problem ?? "") }
        do {
            try await client.pair(.address("127.0.0.1"), code: code)
        } catch {
            return check("remote: paired over this Mac", false, error.localizedDescription)
        }
        guard let device = server.devices.first else { return check("remote: paired over this Mac", false, "no device") }
        check("remote: new Macs get the default rights", device.allowed == .init() && device.allowed.browse && !device.allowed.originals)
        func refused(_ work: () async throws -> Void) async -> Bool {
            do { try await work(); return false } catch { return true }
        }

        do {
            let id = OfficeProxies.id(root)
            let shares = try await client.shares()
            check("remote: shares list the folder, online, with its disk", shares.contains { $0.id == id && $0.name == "Share" && $0.online && $0.totalBytes > 0 },
                  "\(shares)")
            let top = try await client.browse(share: id, path: "")
            check("remote: browse lists folders first, sorted, no hidden/system files or links out", top.map(\.name) == ["B Folder", "a clip.mov", "big.bin", "pic.png"],
                  "\(top.map(\.name))")
            check("remote: entries say folder, size and video", top.first?.folder == true && top.first { $0.name == "big.bin" }?.size == Int64(bytes.count)
                  && top.first { $0.name == "a clip.mov" }?.isVideo == true && top.first { $0.name == "big.bin" }?.isVideo == false)
            check("remote: browse inside a folder", try await client.browse(share: id, path: "B Folder").map(\.name) == ["inner.txt"])
            let escapes = ["../Outside", "escape", "/etc", "B Folder/../../Outside"]
            var leaks: [String] = []
            for path in escapes where !(await refused({ _ = try await client.browse(share: id, path: path) })) { leaks.append(path) }
            check("remote: browsing out of the share is refused", leaks.isEmpty, "\(leaks)")
            check("remote: originals refused without the right",
                  await refused({ _ = try await client.fileData(share: id, path: "big.bin", kind: .original, offset: 0) }))

            server.setRights(.init(browse: true, proxies: true, originals: true, render: true), for: device.id)
            leaks = []
            for path in ["escape.txt", "../Outside/secret.txt", "B Folder/../../Outside/secret.txt", base.appendingPathComponent("Outside/secret.txt").path]
            where !(await refused({ _ = try await client.fileData(share: id, path: path, kind: .original, offset: 0) })) { leaks.append(path) }
            check("remote: file pieces from out of the share are refused", leaks.isEmpty, "\(leaks)")
            // Three pieces at once, each on its own connection.
            async let first = client.fileData(share: id, path: "big.bin", kind: .original, offset: 0)
            async let middle = client.fileData(share: id, path: "big.bin", kind: .original, offset: 1_000_003, length: 1 << 20)
            async let last = client.fileData(share: id, path: "big.bin", kind: .original, offset: 8 << 20)
            let pieces = try await [first, middle, last]
            check("remote: file pieces equal the file's bytes at their offsets",
                  pieces[0].data == bytes.prefix(OfficeLink.fileChunk) && pieces[1].data == bytes.subdata(in: 1_000_003..<1_000_003 + (1 << 20))
                  && pieces[2].data == bytes.suffix(from: 8 << 20) && pieces.allSatisfy { $0.size == Int64(bytes.count) },
                  "\(pieces.map { $0.data.count })")
            check("remote: a missing proxy is refused, not sent",
                  await refused({ _ = try await client.fileData(share: id, path: "a clip.mov", kind: .proxy, offset: 0) }))

            let info = try await client.mediaInfo(share: id, path: "a clip.mov")
            check("remote: media info of an unreadable clip answers empty", info.duration == nil && info.audioChannels == 0, "\(info)")
            let thumb = try await client.thumb(share: id, path: "pic.png")
            check("remote: thumb is a JPEG", thumb.prefix(2) == Data([0xFF, 0xD8]), "\(thumb.prefix(4) as NSData)")

            let status = try await client.status()
            check("remote: status says not busy, with the share", !status.busy && status.shares.contains { $0.id == id } && !status.office.isEmpty)
            check("remote: the existing actions still answer", (try await client.ask("jobs"))["jobs"] != nil)

            server.setRights(.init(browse: false, proxies: true, originals: false, render: true), for: device.id)
            check("remote: browsing refused without the right", await refused({ _ = try await client.browse(share: id, path: "") }))
            check("remote: rights are set on the pairing", server.devices.first?.allowed.browse == false)
        } catch {
            check("remote: round trip", false, error.localizedDescription)
        }
    }
}
