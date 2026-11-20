import AppKit

extension PhotoSelfTest {
    /// Remote editing's protocol (-PluckScreenshotOnly remoteedit): a host and a client in this
    /// test copy (own port and keys) over this Mac, with a share in the test home. Browsing lists
    /// it sorted without hidden or system files, paths out of the share (`..`, symlinks, absolute)
    /// are refused, file pieces equal the file's bytes, originals need their right.
    static func remoteEditTest() async {
        accessRoleChecks()
        remoteClipChecks()
        finderWidthChecks()
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

            // Roles: a role's flags are written into the Mac's rights (older office Macs enforce those).
            server.setRole(.viewer, for: device.id)
            let viewer = server.devices.first { $0.id == device.id }
            check("access: a role writes its flags and is kept", viewer?.role == "viewer" && viewer?.allowed == OfficeAccess.Role.viewer.rights,
                  "\(String(describing: viewer?.role)) \(String(describing: viewer?.allowed))")
            check("access: a Viewer can't fetch originals", await refused({ _ = try await client.fileData(share: id, path: "big.bin", kind: .original, offset: 0) }))
            server.setRole(.editor, for: device.id)
            // Every action that takes a path checks the Mac's role in that folder: with No Access on "B Folder", each is refused there.
            let lockedKey = OfficeAccess.folderKey(root: root, share: id, relative: "B Folder")
            OfficeAccess.shared.set(subject: device.id.uuidString, folder: lockedKey, role: OfficeAccess.Role.none)
            let noPath: Set<String> = ["hello", "projects", "project", "render", "jobs", "cancel", "preview", "archive", "archiveSearch", "archiveClip",
                                       "archiveClipData", "sendState", "send", "proxyFolders", "proxyMake", "proxyStatus", "shares", "status", "driveInfo",
                                       "shareProxyStatus", "resolveRoot", "resolvePresets", "resolveProjects", "resolveCheckout", "resolveRelease",
                                       "resolveUpload", "resolveCheckin", "resolveRestore", "resolveVersionData", "resolveRender", "resolveQueue",
                                       "resolveCancel", "resolvePreview", "reviewComments", "reviewAdd", "reviewResolve", "groupSync", "officeGroup",
                                       "groupNode", "reviewHost", "reviewMail", "reviewReload", "reviewLinks", "reviewPull", "reviewAppend", "reviewUnhost",
                                       "askFilesList", "wake"]
            let probe: [String: Any] = ["share": id, "folder": id, "path": "B Folder/inner.txt", "paths": ["B Folder/inner.txt"], "kind": "original",
                                        "format": "light", "offset": 0, "size": 2, "modified": 0, "data": Data("in".utf8).base64EncodedString(),
                                        "name": "x", "days": 7]
            var unchecked: [String] = []
            for name in OfficeActions.names.sorted() where !noPath.contains(name) {
                var arguments = probe
                if name == "fileData" { for kind in ["proxy", "thumb"] { arguments["kind"] = kind; if !(await refused({ _ = try await client.ask(name, arguments) })) { unchecked.append(name + " " + kind) } }; arguments["kind"] = "original" }
                if !(await refused({ _ = try await client.ask(name, arguments) })) { unchecked.append(name) }
            }
            check("access: every action taking a path checks the role in that folder", unchecked.isEmpty, "\(unchecked)")
            check("access: the list of actions is known (a new one must be sorted into path or no path)",
                  Set(OfficeActions.names).subtracting(noPath).isSuperset(of: ["browse", "fileData", "thumb", "mediaInfo", "shareManifest", "shareProxyMake",
                                                                              "shareWatch", "resolveBuild", "proxyData"]))
            let listed = try await client.browse(share: id, path: "")
            check("access: a No Access folder isn't listed", !listed.contains { $0.name == "B Folder" } && listed.contains { $0.name == "big.bin" }, "\(listed.map(\.name))")
            OfficeAccess.shared.set(subject: device.id.uuidString, folder: lockedKey, role: nil)
            check("access: with the folder role gone it is listed again", try await client.browse(share: id, path: "").contains { $0.name == "B Folder" })
            check("access: a path-aware check still refuses .. and paths out of the share",
                  (try? OfficeActions.require(\.browse, device, share: (root, id), path: "../Outside")) == nil
                  && (try? OfficeActions.require(\.browse, device, share: (root, id), path: "escape")) == nil
                  && (try? OfficeActions.require(\.browse, device, share: (root, id), path: "B Folder")) != nil)

            // Send Files Here: into a folder of the share as an Editor; never over a file; resumed; never out of the share.
            let outgoing = base.appendingPathComponent("Out", isDirectory: true)
            try? fm.createDirectory(at: outgoing, withIntermediateDirectories: true)
            let six = Data("abcdef".utf8), sent = outgoing.appendingPathComponent("inner.txt")
            fm.createFile(atPath: sent.path, contents: six)
            let named = try await RemoteSendInto.send([sent], share: id, path: "B Folder")
            check("send into: a taken name gives Name 2, the file there untouched", named == ["inner 2.txt"]
                  && fm.contents(atPath: root.appendingPathComponent("B Folder/inner 2.txt").path) == six
                  && fm.contents(atPath: root.appendingPathComponent("B Folder/inner.txt").path) == Data("in".utf8), "\(named)")
            let resumed = outgoing.appendingPathComponent("cut.bin")
            fm.createFile(atPath: resumed.path, contents: six)
            let modified = ((try? resumed.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now).timeIntervalSince1970.rounded()
            let firstHalf: [String: Any] = ["share": id, "path": "", "name": "cut.bin", "size": 6, "modified": modified, "offset": 0,
                                        "data": six.prefix(3).base64EncodedString()]
            _ = try await client.ask("sendInto", firstHalf)
            let half = (try await client.ask("sendIntoState", firstHalf)["have"] as? NSNumber)?.int64Value
            let finished = try await RemoteSendInto.send([resumed], share: id, path: "")
            check("send into: a cut send resumes where it got to", half == 3 && finished == ["cut.bin"]
                  && fm.contents(atPath: root.appendingPathComponent("cut.bin").path) == six, "\(String(describing: half)) \(finished)")
            var wrong = firstHalf
            wrong["offset"] = 3
            wrong["data"] = six.suffix(3).base64EncodedString()
            wrong["name"] = "bad.bin"
            _ = try? await client.ask("sendInto", ["share": id, "path": "", "name": "bad.bin", "size": 6, "modified": modified, "offset": 0,
                                                   "data": six.prefix(3).base64EncodedString()])
            wrong["sha256"] = String(repeating: "0", count: 64)
            check("send into: a wrong checksum isn't placed", await refused({ _ = try await client.ask("sendInto", wrong) })
                  && !fm.fileExists(atPath: root.appendingPathComponent("bad.bin").path))
            check("send into: out of the share through a link is refused",
                  await refused({ _ = try await RemoteSendInto.send([sent], share: id, path: "escape") })
                  && !fm.fileExists(atPath: outside.appendingPathComponent("inner.txt").path))
            check("send into: names the NAS couldn't take are refused", !RemoteSendInto.nameOK(".hidden") && !RemoteSendInto.nameOK("a/b")
                  && !RemoteSendInto.nameOK("a:b") && !RemoteSendInto.nameOK(" a") && RemoteSendInto.nameOK("Clip 1.mov"))
            server.setRole(.downloader, for: device.id)
            check("send into: refused without Editor", await refused({ _ = try await RemoteSendInto.send([sent], share: id, path: "B Folder") }))
            // Ask for Files: an Editor's, in a folder of the share, and only where a NAS review server holds the folder.
            let ask: [String: Any] = ["share": id, "path": "B Folder", "name": "Files", "days": 7, "maxBytes": 1000, "types": ["video"]]
            check("ask for files: refused without Editor", await refused({ _ = try await client.ask("askFiles", ask) }))
            server.setRole(.editor, for: device.id)
            var outside = ask
            outside["path"] = "../Outside"
            check("ask for files: a path out of the share is refused", await refused({ _ = try await client.ask("askFiles", outside) }))
            let noServer: String = await { do { _ = try await client.ask("askFiles", ask); return "made" } catch { return error.localizedDescription } }()
            check("ask for files: a folder no NAS review server holds says so", noServer == RemoteAskFiles.needsServer, noServer)
            // An Admin changes roles from a home Mac too; an Editor can't.
            let notAdmin: String = await { do { _ = try await client.ask("accessList"); return "" } catch { return error.localizedDescription } }()
            check("access: only an Admin changes roles from a home Mac", notAdmin == OfficeAccess.adminRefusal, notAdmin)
            server.setRole(.admin, for: device.id)
            _ = try await client.ask("accessSet", ["mac": device.id.uuidString, "share": id, "path": "B Folder", "role": "viewer"])
            let here = try await client.ask("accessList", ["share": id, "path": "B Folder"])
            check("access: an Admin sets a folder role from a home Mac", (here["here"] as? [String: String])?[device.id.uuidString] == "viewer"
                  && (here["macs"] as? [[String: Any]])?.first?["role"] as? String == "admin", "\(here)")
            _ = try await client.ask("accessSet", ["mac": device.id.uuidString, "share": id, "path": "B Folder"])
            let cleared = try await client.ask("accessList", ["share": id, "path": "B Folder"])
            check("access: and takes it away again", (cleared["here"] as? [String: String])?.isEmpty == true)

            server.setRights(.init(browse: false, proxies: true, originals: false, render: true), for: device.id)
            check("remote: browsing refused without the right", await refused({ _ = try await client.browse(share: id, path: "") }))
            check("remote: rights are set on the pairing", server.devices.first?.allowed.browse == false)
            let wakeAnswer: String = await { do { _ = try await client.ask(OfficeWake.action, ["member": UUID().uuidString]); return "" } catch { return error.localizedDescription } }()
            check("access: waking an office Mac needs a role that may use the office", wakeAnswer == OfficeActions.refused().localizedDescription, wakeAnswer)
        } catch {
            check("remote: round trip", false, error.localizedDescription)
        }
    }

    /// The roles as flags, a person's role over the Mac's, the nearest folder role (more or fewer rights), and merging.
    static func accessRoleChecks() {
        typealias Role = OfficeAccess.Role
        typealias Grant = OfficeAccess.Grant
        let table = Role.allCases.map { ($0, $0.rights.browse, $0.rights.proxies, $0.rights.originals, $0.rights.render) }
        check("access: the role table", table.map { "\($0.1)\($0.2)\($0.3)\($0.4)" } == [
            "falsefalsefalsefalse", "truefalsefalsefalse", "truetruetruefalse", "truetruetruetrue", "truetruetruetrue"], "\(table)")
        var mac = OfficeRenderServer.Device(id: UUID(), name: "Mac", secret: Data(), added: .now,
                                            rights: .init(browse: true, proxies: false, originals: true, render: false, fullTrust: true))
        check("access: no role is Custom: the Mac's own flags", OfficeAccess.rights(for: mac, grants: [], place: nil) == mac.allowed)
        mac.role = "downloader"
        let now = Date.now
        var grants = [Grant(subject: mac.id.uuidString, folder: "smb://nas/footage/a", role: "none", changed: now),
                      Grant(subject: mac.id.uuidString, folder: "smb://nas/footage/a/b", role: "editor", changed: now)]
        func at(_ place: String?) -> OfficeAccess.Rights { OfficeAccess.rights(for: mac, grants: grants, place: place) }
        check("access: a role counts, Full Trust stays the Mac's", at(nil).originals && !at(nil).render && at(nil).fullTrust)
        check("access: the nearest folder role wins, fewer or more rights",
              !at("smb://nas/footage/a").browse && !at("smb://nas/footage/a/x/y").browse && at("smb://nas/footage/a/b/c").render
              && at("smb://nas/footage/ab").browse && !at("smb://nas/footage/ab").render)
        mac.person = "p1"
        grants.append(Grant(subject: OfficeAccess.person("p1"), folder: nil, role: "viewer", changed: now))
        grants.append(Grant(subject: OfficeAccess.person("p1"), folder: "smb://nas/footage/a/b", role: "viewer", changed: now))
        check("access: the person's role over the Mac's; the Mac's own folder role first at the same folder",
              !at(nil).proxies && at(nil).browse && at("smb://nas/footage/a/b").render && OfficeAccess.role(for: mac, grants: grants) == .viewer)
        let older = Grant(subject: "s", folder: "f", role: "editor", changed: now), newer = Grant(subject: "s", folder: "f", role: nil, changed: now + 1)
        let ab = OfficeAccess.merge([older], [newer]), ba = OfficeAccess.merge([newer], [older])
        check("access: merging keeps the newest of each, a removal too, either way round", ab == ba && ab?.count == 1 && ab?.first?.role == nil)
        check("access: an office Mac from before roles (no list) keeps ours", OfficeAccess.merge([older], nil) == [older] && OfficeAccess.merge(nil, [older]) == [older])
        // Ask for Files on TrueNAS: the media dataset is mounted writable for the helper (drop1) only when ticked, on a main with media.
        let ticked = TrueNASSetup(), plain = TrueNASSetup(), backup = TrueNASSetup()
        for setup in [ticked, plain, backup] { setup.media = [(dataset: "tank/media", id: "nas1")]; setup.dropFiles = setup !== plain }
        backup.role = .backup
        check("ask for files: drop1 only when ticked, on a main with media", ticked.values(hostKey: "k").blocks.contains("drop1")
              && !plain.values(hostKey: "k").blocks.contains("drop1") && !backup.values(hostKey: "k").blocks.contains("drop1"))
    }

    /// A RED clip folder on the host is one clip with its files' size (raw, so played from a proxy the host
    /// makes), never an empty file; also as a host from before clips sent it; a take's later parts get no proxy of their own.
    static func remoteClipChecks() {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("RemoteClipTest-\(UUID().uuidString)", isDirectory: true)
        let rdc = root.appendingPathComponent("A001_C001.RDC", isDirectory: true)
        try? fm.createDirectory(at: rdc, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        fm.createFile(atPath: rdc.appendingPathComponent("A001_C001_001.R3D").path, contents: Data(repeating: 1, count: 3000))
        fm.createFile(atPath: rdc.appendingPathComponent("A001_C001_002.R3D").path, contents: Data(repeating: 2, count: 1000))
        fm.createFile(atPath: root.appendingPathComponent("B002_C003_001.R3D").path, contents: Data(repeating: 3, count: 500))
        fm.createFile(atPath: root.appendingPathComponent("B002_C003_002.R3D").path, contents: Data(repeating: 4, count: 500))
        fm.createFile(atPath: root.appendingPathComponent("clip.mov").path, contents: Data(repeating: 5, count: 100))
        let listed = (try? RemoteEditHost.list(root, in: root)) ?? []
        let clip = listed.first { $0["name"] as? String == "A001_C001.RDC" } ?? [:]
        check("remote clips: an RDC folder is listed as one clip with its size",
              clip["folder"] as? Bool == false && clip["clip"] as? Bool == true && clip["raw"] as? Bool == true && clip["isVideo"] as? Bool == true
              && (clip["size"] as? NSNumber)?.int64Value == 4000, "\(clip)")
        let entry = OfficeRenderClient.RemoteEntry(clip).map(RemoteFinderSource.info)
        check("remote clips: shown as a raw clip with its size", entry?.info.isClip == true && entry?.info.isFolder == false && entry?.raw == true
              && entry?.info.size == 4000, "\(String(describing: entry))")
        // A host from before clips: the RDC (a package there) as an empty file, or as a folder.
        for older in [["name": "A001_C001.RDC", "folder": false, "size": 0, "isVideo": false],
                      ["name": "A001_C001.RDC", "folder": true, "size": 0, "isVideo": false]] as [[String: Any]] {
            let shown = OfficeRenderClient.RemoteEntry(older).map(RemoteFinderSource.info)
            check("remote clips: an older host's RDC is a raw clip, size unknown (not Zero KB)",
                  shown?.info.isClip == true && shown?.info.isFolder == false && shown?.raw == true && shown?.info.size == nil, "\(older)")
        }
        let movie = listed.first { $0["name"] as? String == "clip.mov" } ?? [:]
        check("remote clips: a movie is a clip, not raw", movie["clip"] as? Bool == true && movie["raw"] as? Bool == false, "\(movie)")
        let proxied = RemoteEditHost.clips(in: root, skipping: OfficeInbox.shared.folder).map(\.lastPathComponent).sorted()
        check("remote clips: proxies of the RDC once and of a take's first part only", proxied == ["A001_C001.RDC", "B002_C003_001.R3D", "clip.mov"],
              "\(proxied)")
        check("remote clips: details and picture read from the RDC's first part",
              RemoteEditHost.clipFile(rdc).lastPathComponent == "A001_C001_001.R3D")
    }

    /// The dragged widths of the sidebar, columns and preview: kept per place, within their limits, the default before any.
    static func finderWidthChecks() {
        guard let defaults = UserDefaults(suiteName: "FinderWidthTest-\(UUID().uuidString)") else { return check("finder widths: test defaults", false) }
        let key = "finderSidebarWidth.editAnywhere", range: ClosedRange<CGFloat> = 140...320
        check("finder widths: the default before any drag", FinderWidth.stored(key, initial: 172, range: range, in: defaults) == 172)
        defaults.set(250.0, forKey: key)
        check("finder widths: a dragged width is kept", FinderWidth.stored(key, initial: 172, range: range, in: defaults) == 250)
        check("finder widths: kept per place", FinderWidth.stored("finderSidebarWidth.deliver", initial: 172, range: range, in: defaults) == 172)
        defaults.set(40.0, forKey: key)
        check("finder widths: never under the minimum", FinderWidth.stored(key, initial: 172, range: range, in: defaults) == 140)
        defaults.set(9000.0, forKey: key)
        check("finder widths: never over the maximum", FinderWidth.stored(key, initial: 172, range: range, in: defaults) == 320)
    }
}
