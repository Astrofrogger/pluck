import SwiftUI
import AppKit
import CryptoKit
import Foundation
import PDFKit

extension PhotoSelfTest {
    /// Review projects on the Deliver page (-PluckScreenshotOnly review), all in a store of its own in the test home and a fake
    /// helper in this process: §3's key vector, passwords, timecode, the model saved and read back, review copies of generated
    /// clips (segments decode, frames land where their timecode says), every data-channel request (scope, latest only,
    /// read only, own-only edits, limits, unknown ids and paths), live fan-out of comments, links' expiry and Turn Off, and
    /// publishing (the bundle, merging a host's comments, removing).
    static func reviewTest() async {
        // A real end-to-end run driven from outside (a browser through local signaling): see reviewE2E.
        if let dir = ProcessInfo.processInfo.environment["PLUCK_E2E_DIR"] {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            return ProcessInfo.processInfo.environment["PLUCK_E2E_MODE"] == "r3" ? await reviewE2E3(url) : await reviewE2E(url)
        }
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("ReviewTest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        // §3's test vector.
        let key = Data((0..<32).map { UInt8($0) })
        let auth = DeliverKeys.authKey(key)
        let fpMac = Array(repeating: "AA", count: 32).joined(separator: ":"), fpBrowser = Array(repeating: "BB", count: 32).joined(separator: ":")
        let ones = Data(repeating: 1, count: 32), twos = Data(repeating: 2, count: 32)
        check("review: key vector", DeliverKeys.base64url(key) == "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
              && DeliverKeys.roomID(key) == "7E1RkYmx_jTN80i5w8xmOg"
              && DeliverKeys.base64url(auth) == "FndhJOuo-7ZZiHHA7b4rC1jnZIGaNtKo1ipv9OAqI5c"
              && DeliverKeys.proof(authKey: auth, role: "browser", macNonce: ones, browserNonce: twos, fpMac: fpMac, fpBrowser: fpBrowser) == "0nRJucbI9oMMyGivqbz2b-6UPmaplHZ9xWxmesvyKgA"
              && DeliverKeys.proof(authKey: auth, role: "mac", macNonce: ones, browserNonce: twos, fpMac: fpMac, fpBrowser: fpBrowser) == "L6anGk8H7cRlDjPG4LDJJA5lJQMzxuhMuZ28789Yj04",
              "\(DeliverKeys.roomID(key)) \(DeliverKeys.base64url(auth))")
        // Level 2 (owner-only R, the room signing key, the join value).
        let rootR = Data((32..<64).map { UInt8($0) })
        let vectorSig = "TJYKK-3bhNymZRPwZjASrwz-HOJ7OKZNO5Ub0oNAYMu8qdGouSU4mIj8M0m4Ts56M25urFTxsWlzfcyR_YidAA", pubR = DeliverKeys.publicKey(root: rootR)
        let ownSig = DeliverKeys.helloSignature(root: rootR, macNonce: ones, fpMac: fpMac, fpBrowser: fpBrowser) ?? ""
        check("review: level 2 vector", DeliverKeys.join(key) == "rRaYJs5-07URNfm3gxhQ2HtP8i4RLTQ_J4wsbiDMdL4" && DeliverKeys.joinHash(key) == "DDk_aLVe7_lpSrn2FJsnpy4x8AsymOK8AZOx9K_7OAo"
              && DeliverKeys.registerKey(root: rootR) == "thuSTJX_ex8_hafj-qs5coPH00wqbknCQ-ON70RP0zQ"
              && DeliverKeys.sha256(DeliverKeys.derive2(rootR, "register")) == "VmzTzijRRc5lZmA19N2AjvkxZCpZfrEn3EiP8ltqTFU"
              && DeliverKeys.base64url(DeliverKeys.signSeed(root: rootR)) == "R85Juszx1tmPSUJlpjYA3DtFmqHJDUUU0Z1HyoU0Mb4" && pubR == "d-VE2PQpTDJ6Rw_vkvYI0nCJ34xkdCgQRSVNa3LdIFw"
              && DeliverKeys.checkHello(pub: pubR, sig: vectorSig, macNonce: ones, fpMac: fpMac, fpBrowser: fpBrowser)
              && DeliverKeys.checkHello(pub: pubR, sig: ownSig, macNonce: ones, fpMac: fpMac, fpBrowser: fpBrowser)
              && !DeliverKeys.checkHello(pub: pubR, sig: ownSig, macNonce: ones, fpMac: fpBrowser, fpBrowser: fpMac)
              && !DeliverKeys.checkHello(pub: pubR, sig: ownSig, macNonce: twos, fpMac: fpMac, fpBrowser: fpBrowser), "\(pubR) \(DeliverKeys.registerKey(root: rootR))")
        // Level 3 (§13.24): the shared vector (docs/superpowers/plans/link-v3-vectors.json).
        let v3Key = DeliverKeys.linkKey(code: "Mt0Rkt98Xy3Q"), v3Auth = DeliverKeys.authKey(v3Key)
        let v3Hello: [String: Any] = ["t": "hello", "v": 3, "nonce": DeliverKeys.base64url(ones), "mac": "YXEZs3zCsfPVrwmdI9JtCvAfg_HGrNpNJDUpQwM_PdM"]
        check("review: level 3 vector", DeliverKeys.base64url(v3Key) == "DbwU1ROJSHL_lN_W9cPWR9FVcz9cTqvMobV9BIzmhWk"
              && DeliverKeys.roomID(v3Key) == "0uVpe4rN0sW6KOGlgQrXdw" && DeliverKeys.base64url(v3Auth) == "lfzrFcPoCa4w2uvvM46h-uytNgbPX4yVznvh4TbbmhA"
              && DeliverKeys.join(v3Key) == "CweSuKvrTSJBDSsGbrBWW2N-1G1v_51fdej4DqMNIlk" && DeliverKeys.joinHash(v3Key) == "7bLzpOxYAG0Wj5DpUJMYWR8dkfVgTYUyVcbw34AulWI"
              && DeliverKeys.helloMAC(authKey: v3Auth, macNonce: ones, fpMac: fpMac, fpBrowser: fpBrowser) == "YXEZs3zCsfPVrwmdI9JtCvAfg_HGrNpNJDUpQwM_PdM"
              && DeliverKeys.proof(authKey: v3Auth, role: "browser", macNonce: ones, browserNonce: twos, fpMac: fpMac, fpBrowser: fpBrowser) == "90OCEhhzHRxjFS7OvPruCMf3ePrEWCURdwk409tvyVY"
              && DeliverKeys.proof(authKey: v3Auth, role: "mac", macNonce: ones, browserNonce: twos, fpMac: fpMac, fpBrowser: fpBrowser) == "n5Zhx44qM18L4ax1zi-4SU1y3xPjJChdg2LrmAjTe0E"
              && DeliverKeys.browserCheck(v3Hello, level: 3, key: v3Key, pub: "", fpMac: fpMac, fpBrowser: fpBrowser) == ones
              && DeliverKeys.browserCheck(v3Hello, level: 3, key: DeliverKeys.linkKey(code: "Mt0Rkt98Xy3R"), pub: "", fpMac: fpMac, fpBrowser: fpBrowser) == nil
              && DeliverKeys.browserCheck(v3Hello, level: 2, key: v3Key, pub: pubR, fpMac: fpMac, fpBrowser: fpBrowser) == nil
              && (0..<50).map { _ in DeliverKeys.newCode() }.allSatisfy { $0.count == 12 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } },
              DeliverKeys.base64url(v3Key))
        // pull pages: Pluck follows `more` (a host returns ≤ 5000 entries and the seq of the last one).
        let log = (1...12).map { ["seq": $0] }
        let pulled = try? await ReviewPublish.pages(0) { since in
            let page = Array(log.filter { $0["seq"]! > since }.prefix(5))
            return ["entries": page, "seq": page.last?["seq"] ?? since, "more": (page.last?["seq"] ?? since) < 12]
        }
        check("review: pull follows more", (pulled?["entries"] as? [[String: Int]])?.map { $0["seq"]! } == Array(1...12) && pulled?["seq"] as? Int == 12, "\(String(describing: pulled))")
        check("review: a host's get can't announce more than its upload or the disk", !HostSession.fits(11, limit: 10, in: base)
              && HostSession.fits(10, limit: 10, in: base) && !HostSession.fits(Int64.max / 2, limit: nil, in: base), "")
        let hash = DeliverKeys.hashPassword("test")
        check("review: password round trip", hash.hasPrefix("pbkdf2-sha256$210000$") && DeliverKeys.checkPassword("test", hash)
              && !DeliverKeys.checkPassword("Test", hash) && !DeliverKeys.checkPassword("test", "garbage"), hash)

        // Timecode: non-drop, 29.97 and 59.94 drop frame.
        let tc = DeliverTimecode.string
        check("review: timecode", tc(26, "01:00:00:00", 25, 1, false) == "01:00:01:01" && tc(0, "01:00:00:00", 25, 1, false) == "01:00:00:00"
              && tc(1800, "00:00:00;00", 30000, 1001, true) == "00:01:00;02" && tc(17982, "00:00:00;00", 30000, 1001, true) == "00:10:00;00"
              && tc(1799, "00:00:00;00", 30000, 1001, true) == "00:00:59;29" && tc(3600, "00:00:00;00", 60000, 1001, true) == "00:01:00;04"
              && DeliverTimecode.frames("00:01:00;02", fpsNum: 30000, fpsDen: 1001, drop: true) == 1800
              && tc(5, "00:59:59;29", 30000, 1001, true) == "01:00:00;04",
              "\(tc(1800, "00:00:00;00", 30000, 1001, true)) \(tc(17982, "00:00:00;00", 30000, 1001, true)) \(tc(3600, "00:00:00;00", 60000, 1001, true))")

        // The parser: init in its own file, and init inside media.m4s with a byte range.
        let own = DeliverCopies.parse("#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:2.0,\n#EXT-X-BYTERANGE:100@0\nmedia.m4s\n#EXTINF:1.5,\n#EXT-X-BYTERANGE:60\nmedia.m4s\n#EXT-X-ENDLIST",
                                      folder: base, codecs: "x", fpsNum: 25, fpsDen: 1, width: 2, height: 2)
        let inside = DeliverCopies.parse("#EXT-X-MAP:URI=\"media.m4s\",BYTERANGE=\"1358@0\"\n#EXTINF:2.002,\n#EXT-X-BYTERANGE:1995444@1358\nmedia.m4s\n",
                                         folder: base, codecs: "x", fpsNum: 25, fpsDen: 1, width: 2, height: 2)
        let escape = DeliverCopies.parse("#EXT-X-MAP:URI=\"../x\"\n#EXTINF:2,\n../etc/passwd\n", folder: base, codecs: "x", fpsNum: 25, fpsDen: 1, width: 2, height: 2)
        check("review: playlist parser", own?.segments.map(\.offset) == [0, 100] && own?.segments[1].length == 60 && own?.segments[1].t == 2 && own?.duration == 3.5
              && inside?.`init` == .init(file: "media.m4s", offset: 0, length: 1358) && inside?.segments.first?.offset == 1358 && escape == nil,
              "\(String(describing: own)) \(String(describing: inside))")
        check("review: sizes", DeliverCopies.fit(3840, 2160, box: 1920) == (1920, 1080) && DeliverCopies.fit(1280, 720, box: 1920) == (1280, 720)
              && DeliverCopies.fit(1081, 1921, box: 960) == (540, 960) && DeliverCopies.fit(1000, 563, box: 960) == (960, 540), "")

        // The store: written, then read back by a fresh one.
        let root = base.appendingPathComponent("Review", isDirectory: true)
        var store = DeliverStore(root: root)
        guard let project = try? store.newProject("Spring campaign"), let other = try? store.newProject("Other") else { return check("review: projects", false, "") }
        guard let manager = AppDelegate.shared?.manager, let ffmpeg = manager.tool("ffmpeg"), let ffprobe = manager.tool("ffprobe") else {
            return check("review: ffmpeg", false, "no ffmpeg")
        }
        let media = base.appendingPathComponent("Media", isDirectory: true)
        try? fm.createDirectory(at: media.appendingPathComponent("Socials"), withIntermediateDirectories: true)
        let clip = media.appendingPathComponent("Hero 30s.mov"), drop = media.appendingPathComponent("Socials/Drop.mov")
        _ = await DeliveryCheck.output(ffmpeg, ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=640x360:r=25:d=3", "-f", "lavfi", "-i", "sine=f=440:d=3",
                                                "-c:v", "mpeg4", "-q:v", "2", "-c:a", "aac", "-shortest", "-timecode", "01:00:00:00", clip.path])
        _ = await DeliveryCheck.output(ffmpeg, ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=320x180:r=30000/1001:d=2",
                                                "-c:v", "mpeg4", "-q:v", "4", "-timecode", "00:59:59;00", drop.path])
        fm.createFile(atPath: media.appendingPathComponent("Socials/notes.txt").path, contents: Data("x".utf8))
        let added = (try? store.add([clip, media.appendingPathComponent("Socials")], to: project.id, folder: nil)) ?? []
        let socials = store.content(project.id).folders.first { $0.name == "Socials" }
        check("review: files and folders added", added.count == 2 && socials != nil && added.contains { $0.folder == socials?.id && $0.name == "Drop" }
              && !added.contains { $0.name == "notes" } && added.first?.versions.first?.path == clip.path, "\(added.map(\.name))")
        guard let hero = added.first(where: { $0.name == "Hero 30s" }), let dropAsset = added.first(where: { $0.name == "Drop" }) else { return }
        let otherAsset = (try? store.add([drop], to: other.id, folder: nil))?.first

        // Review copies of the generated clips.
        let made = await DeliverCopies.make(clip, kind: .video, into: store.copies(hero.current.id), ffmpeg: ffmpeg, ffprobe: ffprobe) { _ in }
        let probe = made.probe
        check("review: probe", probe?.fpsNum == 25 && probe?.fpsDen == 1 && probe?.startTimecode == "01:00:00:00" && probe?.dropFrame == false
              && probe?.frames == 75 && probe?.width == 640 && probe?.hasAudio == true, "\(String(describing: probe))")
        store.update(version: hero.current.id, of: hero.id) { $0.probe = probe; $0.copy = .ready(made.renditions ?? []) }
        let copies = store.copies(hero.current.id)
        let index = DeliverCopies.index(copies.appendingPathComponent("540"))
        let low = DeliverCopies.index(copies.appendingPathComponent("360"))
        check("review: copies made", made.renditions == ["1080", "540", "360"] && low?.codecs == "avc1.64001f,mp4a.40.2" && low?.width == 640 && fm.fileExists(atPath: copies.appendingPathComponent("poster.jpg").path)
              && fm.fileExists(atPath: copies.appendingPathComponent("strip.jpg").path) && index?.codecs == "avc1.640020,mp4a.40.2"
              && index?.segments.count == 2 && index?.width == 640 && DeliverCopies.index(copies.appendingPathComponent("1080"))?.codecs == "avc1.64002a,mp4a.40.2",
              "\(String(describing: made.renditions)) \(String(describing: index))")
        if let index {
            // Each segment decodes after the init piece, with the frames its duration says, starting at its time.
            for (n, segment) in index.segments.enumerated() {
                let file = base.appendingPathComponent("segment\(n).mp4")
                func bytes(_ name: String, _ offset: Int64, _ length: Int64) -> Data {
                    guard let handle = FileHandle(forReadingAtPath: copies.appendingPathComponent("540/" + name).path) else { return Data() }
                    defer { try? handle.close() }
                    try? handle.seek(toOffset: UInt64(offset))
                    return (try? handle.read(upToCount: Int(length))) ?? Data()
                }
                fm.createFile(atPath: file.path, contents: bytes(index.`init`.file, index.`init`.offset, index.`init`.length) + bytes(segment.file, segment.offset, segment.length))
                let counted = await DeliveryCheck.output(ffprobe, ["-v", "error", "-select_streams", "v:0", "-count_frames", "-show_entries", "stream=start_time,nb_read_frames",
                                                                   "-of", "csv=p=0", file.path])
                let numbers = counted.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",").compactMap { Double($0) }
                check("review: segment \(n) decodes", numbers.count == 2 && abs(numbers[0] - segment.t) < 0.001 && Int(numbers[1]) == Int((segment.d * 25).rounded()),
                      "\(counted) t \(segment.t) d \(segment.d)")
            }
            // Frame N of the copy is frame N of the original (tiny grey pictures compared).
            func frames(_ url: URL) async -> [Data] {
                let raw = await Task.detached { () -> Data in
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: ffmpeg)
                    process.arguments = ["-nostdin", "-v", "error", "-i", url.path, "-vf", "scale=32:18,format=gray", "-f", "rawvideo", "pipe:1"]
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = FileHandle.nullDevice
                    try? process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    return data
                }.value
                return stride(from: 0, to: raw.count - 575, by: 576).map { raw.subdata(in: $0..<($0 + 576)) }
            }
            let stitched = base.appendingPathComponent("stitched.mp4")
            if let stream = DeliverPlayback.stitched(copies.appendingPathComponent("540")), let size = try? await stream.size(),
               let data = try? await stream.bytes(0, Int(size)) {
                fm.createFile(atPath: stitched.path, contents: data)
            }
            let original = await frames(clip), copy = await frames(stitched)
            func diff(_ a: Data, _ b: Data) -> Int { zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) } }
            let matched = [0, 13, 37, 50, 74].allSatisfy { n in
                guard copy.indices.contains(n) else { return false }
                return original.indices.min { diff(original[$0], copy[n]) < diff(original[$1], copy[n]) } == n
            }
            check("review: frame-accurate copy", original.count == 75 && copy.count == 75 && matched, "original \(original.count) copy \(copy.count)")
        }
        let dropMade = await DeliverCopies.make(drop, kind: .video, into: store.copies(dropAsset.current.id), ffmpeg: ffmpeg, ffprobe: ffprobe) { _ in }
        check("review: drop-frame clip", dropMade.probe?.fpsNum == 30000 && dropMade.probe?.fpsDen == 1001 && dropMade.probe?.dropFrame == true
              && dropMade.probe?.startTimecode == "00:59:59;00" && dropMade.renditions != nil
              && DeliverCopies.index(store.copies(dropAsset.current.id).appendingPathComponent("1080"))?.codecs == "avc1.64002a", "\(String(describing: dropMade.probe))")
        store.update(version: dropAsset.current.id, of: dropAsset.id) { $0.probe = dropMade.probe; $0.copy = .ready(dropMade.renditions ?? []) }

        // A second version on top of the stack.
        let v2 = try? store.addVersion(clip, to: hero.id)
        if let v2 {
            try? FileManager.default.createDirectory(at: store.copies(v2.id), withIntermediateDirectories: true)
            try? ReviewPublish.linkTree(copies.appendingPathComponent("540"), to: store.copies(v2.id).appendingPathComponent("540"))
            store.update(version: v2.id, of: hero.id) { $0.probe = probe; $0.copy = .ready(["540"]) }
        }
        let markers = DeliverAssetView.markers([Deliver.Comment(asset: hero.id, version: hero.current.id, frame: 25, text: "Logo | early", author: "Guest")],
                                               probe: probe, title: "Hero")
        check("review: marker EDL", markers.contains("01:00:01:00 01:00:01:01") && markers.contains("|M:Guest: Logo / early"), markers)

        // Saved and read back.
        let reread = DeliverStore(root: root)
        let back = reread.find(hero.id)?.asset
        check("review: model saved and read", reread.projects.map(\.name) == ["Spring campaign", "Other"] && back?.versions.count == 2
              && back?.versions.first?.probe == probe && back?.versions.first?.copy == .ready(["1080", "540", "360"]) && reread.content(project.id).folders.count == 1, "")
        store = reread
        guard let heroNow = store.find(hero.id)?.asset, let v1 = heroNow.versions.first, let current = heroNow.versions.last else { return }

        // Links: creation, the key kept apart, expiry and Turn Off. (§13.24: new links are level 2 while a paired host
        // hasn't said it serves level 3; the test home's earlier fake hosts never did, and these checks are about current ones.)
        for host in ReviewPublish.shared.hosts where host.links == nil { ReviewPublish.shared.update(host: host.id) { $0.links = 3 } }
        guard let link = try? store.newLink(scope: .project(project.id), title: "Cuts", password: "test", level: 2),
              let open = try? store.newLink(scope: .asset(hero.id, project: project.id), title: "Hero", latestOnly: true),
              let show = try? store.newLink(scope: .project(project.id), title: "Show", mode: .presentation),
              let folderLink = try? store.newLink(scope: .folder(socials!.id, project: project.id), title: "Socials") else { return check("review: links", false, "") }
        let linkURL = store.url(link) ?? ""
        let saved = (try? String(contentsOf: root.appendingPathComponent("links.json"), encoding: .utf8)) ?? ""
        let fragment = linkURL.split(separator: "#").last.map(String.init) ?? ""
        check("review: link made", linkURL.hasPrefix("https://pluck.tools/r/\(link.roomID)#") && fragment.count == 87
              && fragment.split(separator: ".").map(\.count) == [43, 43] && fragment.hasSuffix(DeliverKeys.publicKey(root: store.secret(link.id) ?? Data()))
              && link.roomID == DeliverKeys.roomID(store.key(link.id) ?? Data()) && !saved.contains(String(linkURL.split(separator: "#").last ?? "x"))
              && link.passwordHash != nil && !saved.contains("\"test\""), linkURL)
        let shortURL = store.url(open) ?? "", openCode = store.code(open.id) ?? ""
        check("review: level 3 link made (new links)", shortURL == "https://pluck.tools/r/#\(openCode)" && shortURL.count == 35 && store.level(open.id) == 3
              && open.roomID == DeliverKeys.roomID(DeliverKeys.linkKey(code: openCode)) && store.key(open.id) == DeliverKeys.linkKey(code: openCode)
              && store.secret(open.id)?.count == 32 && !saved.contains(openCode) && store.level(link.id) == 2, shortURL)

        // A level-1 link (its keychain item only the 32-byte key) gets a new key, R and room when the store loads.
        if let old = try? store.newLink(scope: .project(project.id), title: "Old level") {
            DeliverKeychain.save(DeliverKeys.random(32), as: old.id.uuidString)
            let upgraded = DeliverStore(root: root)
            let after = upgraded.link(old.id)
            check("review: level-1 links regenerated", after != nil && after?.roomID != old.roomID && upgraded.secret(old.id)?.count == 32
                  && after?.roomID == DeliverKeys.roomID(upgraded.key(old.id) ?? Data()) && upgraded.url(after!)?.contains(".") == true, "")
            store = upgraded
            store.revoke(old.id)
        }
        // The server, with a fake helper: what it would send to the helper is kept here.
        let server = DeliverServer(store: store)
        var out: [[String: Any]] = []
        server.output = { out.append($0) }
        var nextID = 100
        func sent(_ peer: String) -> [[String: Any]] {
            out.compactMap { ($0["send"] as? [String: Any]).flatMap { $0["peer"] as? String == peer ? $0["msg"] as? [String: Any] : nil } }
        }
        func closed(_ peer: String) -> Bool { out.contains { ($0["close"] as? [String: Any])?["peer"] as? String == peer } }
        func ask(_ peer: String, _ body: [String: Any]) -> [String: Any] {
            nextID += 1
            let id = nextID
            out = []
            server.helper(["msg": ["peer": peer, "msg": body.merging(["id": id]) { $1 }]])
            return sent(peer).first { $0["re"] as? Int == id } ?? [:]
        }
        func code(_ answer: [String: Any]) -> String? { (answer["error"] as? [String: Any])?["code"] as? String }
        let token = DeliverKeys.random(32)
        func pubOf(_ link: Deliver.ShareLink) -> String { DeliverKeys.publicKey(root: store.secret(link.id) ?? Data()) }
        /// A browser through the link: hello, auth (and the password), ready.
        func connect(_ peer: String, _ link: Deliver.ShareLink, password: String? = nil, token: Data = token, badProof: Bool = false) -> (welcome: [String: Any], ready: [String: Any]) {
            out = []
            server.helper(["peer": ["peer": peer, "room": link.roomID, "state": "open", "fpLocal": fpMac, "fpRemote": fpBrowser, "path": "direct"]])
            guard let hello = sent(peer).first, let key = store.key(link.id), let level = store.level(link.id),
                  let macNonce = DeliverKeys.browserCheck(hello, level: level, key: key, pub: pubOf(link), fpMac: fpMac, fpBrowser: fpBrowser)
            else { return ([:], [:]) } // the browser sends nothing to a server that can't prove the room
            let nonce = DeliverKeys.random(32)
            let proof = DeliverKeys.proof(authKey: DeliverKeys.authKey(badProof ? DeliverKeys.random(32) : key), role: "browser", macNonce: macNonce, browserNonce: nonce, fpMac: fpMac, fpBrowser: fpBrowser)
            let welcome = ask(peer, ["t": "auth", "v": level, "nonce": DeliverKeys.base64url(nonce), "proof": proof, "token": DeliverKeys.base64url(token), "name": "Anna\u{7}"])
            let macProof = DeliverKeys.proof(authKey: DeliverKeys.authKey(key), role: "mac", macNonce: macNonce, browserNonce: nonce, fpMac: fpMac, fpBrowser: fpBrowser)
            guard welcome["proof"] as? String == macProof else { return (welcome, [:]) }
            if let password { return (welcome, ask(peer, ["t": "password", "password": password])) }
            return (welcome, sent(peer).first { $0["t"] as? String == "ready" } ?? [:])
        }

        // A forged hello: a link holder knows authKey (so its welcome proof would pass) but not the room's signing key.
        out = []
        server.helper(["peer": ["peer": "p_sig", "room": link.roomID, "state": "open", "fpLocal": fpMac, "fpRemote": fpBrowser]])
        let realHello = sent("p_sig").first ?? [:]
        let realNonce = (realHello["nonce"] as? String).flatMap(DeliverKeys.data(base64url:)) ?? Data()
        let forged = DeliverKeys.helloSignature(root: DeliverKeys.random(32), macNonce: realNonce, fpMac: fpMac, fpBrowser: fpBrowser) ?? ""
        check("review: a forged hello is refused", realHello["v"] as? Int == 2
              && DeliverKeys.checkHello(pub: pubOf(link), sig: realHello["sig"] as? String ?? "", macNonce: realNonce, fpMac: fpMac, fpBrowser: fpBrowser)
              && !DeliverKeys.checkHello(pub: pubOf(link), sig: forged, macNonce: realNonce, fpMac: fpMac, fpBrowser: fpBrowser)
              && !DeliverKeys.checkHello(pub: pubOf(link), sig: realHello["sig"] as? String ?? "", macNonce: realNonce, fpMac: fpBrowser, fpBrowser: fpMac), "\(realHello)")
        let v1Proof = DeliverKeys.proof(authKey: DeliverKeys.authKey(store.key(link.id) ?? Data()), role: "browser", macNonce: realNonce, browserNonce: twos, fpMac: fpMac, fpBrowser: fpBrowser)
        check("review: level-1 auth refused", code(ask("p_sig", ["t": "auth", "v": 1, "nonce": DeliverKeys.base64url(twos), "proof": v1Proof, "token": DeliverKeys.base64url(token)])) == "auth"
              && closed("p_sig"), "")
        // Level 3 on this server: a MAC hello; a level-2 auth and a wrong code's proof are refused; `/a/<8>` resolves; and
        // "Make a New Link" turns a level-2 link into a level-3 one with a new room.
        out = []
        server.helper(["peer": ["peer": "p_v3", "room": open.roomID, "state": "open", "fpLocal": fpMac, "fpRemote": fpBrowser]])
        let hello3 = sent("p_v3").first ?? [:], openKey = store.key(open.id) ?? Data()
        let nonce3 = DeliverKeys.browserCheck(hello3, level: 3, key: openKey, pub: "", fpMac: fpMac, fpBrowser: fpBrowser) ?? Data()
        let proof3 = DeliverKeys.proof(authKey: DeliverKeys.authKey(openKey), role: "browser", macNonce: nonce3, browserNonce: twos, fpMac: fpMac, fpBrowser: fpBrowser)
        check("review: level 3 hello, level-2 auth refused", nonce3.count == 32 && hello3["sig"] == nil
              && code(ask("p_v3", ["t": "auth", "v": 2, "nonce": DeliverKeys.base64url(twos), "proof": proof3, "token": DeliverKeys.base64url(token)])) == "auth", "\(hello3)")
        out = []
        server.helper(["peer": ["peer": "p_v3w", "room": open.roomID, "state": "open", "fpLocal": fpMac, "fpRemote": fpBrowser]])
        let nonceW = (sent("p_v3w").first?["nonce"] as? String).flatMap(DeliverKeys.data(base64url:)) ?? Data()
        let wrongProof = DeliverKeys.proof(authKey: DeliverKeys.authKey(DeliverKeys.linkKey(code: "Mt0Rkt98Xy3R")), role: "browser", macNonce: nonceW, browserNonce: twos, fpMac: fpMac, fpBrowser: fpBrowser)
        check("review: level 3 wrong code refused", code(ask("p_v3w", ["t": "auth", "v": 3, "nonce": DeliverKeys.base64url(twos), "proof": wrongProof, "token": DeliverKeys.base64url(token)])) == "auth", "")
        let solo3 = connect("p_v3ok", open)
        let short = String(hero.id.uuidString.prefix(8)).lowercased()
        check("review: level 3 connects; short asset id", solo3.ready["t"] as? String == "ready"
              && (ask("p_v3ok", ["t": "asset", "asset": short])["asset"] as? [String: Any])?["id"] as? String == hero.id.uuidString
              && code(ask("p_v3ok", ["t": "asset", "asset": "zzzzzzzz"])) == "notFound", "\(solo3.ready)")
        if let renewing = try? store.newLink(scope: .project(project.id), title: "Renew", level: 2) {
            let before = renewing.roomID
            store.renew(renewing.id)
            let after = store.link(renewing.id)
            check("review: Make a New Link gives level 3", store.level(renewing.id) == 3 && after?.roomID != before
                  && after?.roomID == DeliverKeys.roomID(store.key(renewing.id) ?? Data()) && store.url(after!)?.hasPrefix("https://pluck.tools/r/#") == true, "")
            store.revoke(renewing.id)
        }
        // §13.24 H1: a level-3 link is shown, copied or sent only once one of the owner's servers holds its room; a room
        // someone else holds is the owner's problem, with "Make a New Link".
        if let gated = try? store.newLink(scope: .project(project.id), title: "Gate", level: 3) {
            let before = server.shareURL(gated)
            server.helper(["room": ["room": gated.roomID, "state": "offline"]])
            let offline = server.shareURL(gated)
            server.helper(["room": ["room": gated.roomID, "state": "active"]])
            let held = server.shareURL(gated)
            server.helper(["room": ["room": gated.roomID, "state": "offline"]])
            check("review: a level-3 link waits until its room is held", before == nil && offline == nil && held == store.url(gated) && held != nil
                  && server.shareURL(gated) != nil && !server.isTaken(gated), "\(String(describing: before)) \(String(describing: held))")
            server.helper(["room": ["room": gated.roomID, "state": "taken"]])
            let level2 = try? store.newLink(scope: .project(project.id), title: "Gate 2", level: 2)
            check("review: a taken room is a problem; level 2 needs no wait", server.isTaken(gated) && level2.map { server.shareURL($0) != nil } == true, "")
            let old = Deliver.Host(name: "Old NAS", kind: .nas, address: nil), new = { var h = old; h.links = 3; return h }()
            check("review: links stay level 2 while a paired host can't serve 3", ReviewPublish.linkLevel([]) == 3 && ReviewPublish.linkLevel([new]) == 3
                  && ReviewPublish.linkLevel([new, old]) == 2, "")
            store.revoke(gated.id)
            if let level2 { store.revoke(level2.id) }
        }
        let bad = connect("p_bad", link, badProof: true)
        check("review: bad proof closes", code(bad.welcome) == "auth" && closed("p_bad"), "\(bad.welcome)")
        out = []
        server.helper(["peer": ["peer": "p_early", "room": link.roomID, "state": "open", "fpLocal": fpMac, "fpRemote": fpBrowser]])
        check("review: nothing before auth", code(ask("p_early", ["t": "list", "folder": NSNull()])) == "auth", "")
        let wrong = connect("p_wrong", link, password: "nope")
        check("review: wrong password", wrong.welcome["needPassword"] as? Bool == true && code(wrong.ready) == "password" && !closed("p_wrong"), "\(wrong.ready)")
        let anna = connect("p_anna", link, password: "test")
        let readyLink = anna.ready["link"] as? [String: Any]
        check("review: password and ready", anna.ready["t"] as? String == "ready" && readyLink?["title"] as? String == "Cuts"
              && (anna.ready["root"] as? [String: Any])?["id"] as? String == project.id.uuidString && store.link(link.id)?.lastOpened != nil, "\(anna.ready)")

        // Browsing.
        let top = ask("p_anna", ["t": "list", "folder": NSNull()])
        let topAssets = (top["assets"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        let topFolders = (top["folders"] as? [[String: Any]]) ?? []
        let firstCurrent = (top["assets"] as? [[String: Any]])?.first?["current"] as? [String: Any]
        check("review: list has dates", (firstCurrent?["added"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } != nil, "\(String(describing: firstCurrent))")
        check("review: list", topAssets == [hero.id.uuidString] && topFolders.first?["count"] as? Int == 1 && (top["path"] as? [[String: Any]])?.count == 1, "\(top)")
        let inFolder = ask("p_anna", ["t": "list", "folder": socials!.id.uuidString])
        let dropWire = ask("p_anna", ["t": "asset", "asset": dropAsset.id.uuidString])["asset"] as? [String: Any]
        check("review: asset names its folder", dropWire?["folder"] as? String == socials!.id.uuidString
              && (ask("p_anna", ["t": "asset", "asset": hero.id.uuidString])["asset"] as? [String: Any])?["folder"] is NSNull, "\(String(describing: dropWire))")
        check("review: list a folder", (inFolder["assets"] as? [[String: Any]])?.first?["id"] as? String == dropAsset.id.uuidString
              && (inFolder["path"] as? [[String: Any]])?.count == 2, "\(inFolder)")
        let assetAnswer = ask("p_anna", ["t": "asset", "asset": hero.id.uuidString])["asset"] as? [String: Any]
        let versions = assetAnswer?["versions"] as? [[String: Any]] ?? []
        check("review: asset", versions.count == 2 && versions.first?["frames"] as? Int == 75 && versions.first?["startTimecode"] as? String == "01:00:00:00"
              && versions.first?["canDownload"] as? Bool == false && versions.allSatisfy { $0["path"] == nil }, "\(String(describing: assetAnswer))")
        check("review: unknown and other projects' ids", code(ask("p_anna", ["t": "asset", "asset": UUID().uuidString])) == "notFound"
              && code(ask("p_anna", ["t": "asset", "asset": otherAsset?.id.uuidString ?? ""])) == "scope"
              && code(ask("p_anna", ["t": "asset", "asset": "../../etc"])) == "invalid"
              && code(ask("p_anna", ["t": "list", "folder": UUID().uuidString])) == "notFound"
              && code(ask("p_anna", ["t": "nonsense"])) == "invalid", "")

        // Fetches: the index inline, pieces through `serve` at the index's own offsets, nothing else.
        let indexAnswer = ask("p_anna", ["t": "fetch", "asset": hero.id.uuidString, "version": v1.id.uuidString, "what": "index", "rendition": "540"])
        check("review: fetch index", ((indexAnswer["json"] as? [String: Any])?["segments"] as? [[String: Any]])?.count == 2, "\(indexAnswer)")
        let segment = ask("p_anna", ["t": "fetch", "asset": hero.id.uuidString, "version": v1.id.uuidString, "what": "segment", "rendition": "540", "n": 1])
        let serve = out.compactMap { $0["serve"] as? [String: Any] }.first
        let want = DeliverCopies.index(store.copies(v1.id).appendingPathComponent("540"))?.segments[1]
        check("review: fetch a segment", segment["fetch"] as? Int == segment["re"] as? Int && (segment["size"] as? NSNumber)?.int64Value == want?.length
              && (serve?["path"] as? String)?.hasPrefix(store.copies(v1.id).path) == true && (serve?["offset"] as? NSNumber)?.int64Value == want?.offset
              && serve?["peer"] as? String == "p_anna", "\(segment) \(String(describing: serve))")
        check("review: fetches refused", code(ask("p_anna", ["t": "fetch", "asset": hero.id.uuidString, "version": v1.id.uuidString, "what": "segment", "rendition": "540", "n": 99])) == "invalid"
              && code(ask("p_anna", ["t": "fetch", "asset": hero.id.uuidString, "version": v1.id.uuidString, "what": "../../x"])) == "invalid"
              && code(ask("p_anna", ["t": "fetch", "asset": hero.id.uuidString, "version": v1.id.uuidString, "what": "index", "rendition": "720"])) == "invalid"
              && code(ask("p_anna", ["t": "fetch", "asset": hero.id.uuidString, "version": v1.id.uuidString, "what": "original"])) == "scope"
              && code(ask("p_anna", ["t": "fetch", "asset": hero.id.uuidString, "version": UUID().uuidString, "what": "poster"])) == "notFound", "")
        var limited = false
        for n in 0..<6 where !limited {
            limited = code(ask("p_anna", ["t": "fetch", "asset": hero.id.uuidString, "version": v1.id.uuidString, "what": "poster"])) == "limit"
            if limited { check("review: at most 4 fetches at once", n == 3, "limit at \(n)") }
        }
        if !limited { check("review: at most 4 fetches at once", false, "never limited") }
        for fetch in server.peers["p_anna"]?.fetches ?? [] { server.helper(["served": ["peer": "p_anna", "fetch": fetch, "bytes": 1, "result": "done"]]) }
        check("review: served frees a fetch", code(ask("p_anna", ["t": "fetch", "asset": hero.id.uuidString, "version": v1.id.uuidString, "what": "poster"])) == nil, "")
        for fetch in server.peers["p_anna"]?.fetches ?? [] { server.helper(["served": ["peer": "p_anna", "fetch": fetch, "bytes": 1, "result": "done"]]) }

        // Comments, with a second browser watching.
        let ben = connect("p_ben", link, password: "test", token: DeliverKeys.random(32))
        _ = ask("p_ben", ["t": "name", "name": "Ben"])
        let added1 = ask("p_anna", ["t": "comment-add", "asset": hero.id.uuidString, "version": current.id.uuidString, "frame": 30, "endFrame": NSNull(), "text": "Logo too early",
                                    "drawing": ["strokes": [["tool": "arrow", "colour": "#E0605E", "width": 0.004, "points": [[0.41, 0.30], [0.52, 0.38]]]]]])
        let mineComment = added1["comment"] as? [String: Any]
        let toBen = sent("p_ben").first { $0["t"] as? String == "comment" }
        let commentID = mineComment?["id"] as? String ?? ""
        check("review: comment added and fanned out", mineComment?["mine"] as? Bool == true && mineComment?["author"] as? String == "Anna" && mineComment?["authorToken"] == nil
              && mineComment?["link"] == nil && toBen?["op"] as? String == "add" && (toBen?["comment"] as? [String: Any])?["mine"] as? Bool == false
              && store.comments(hero.id, version: current.id).first?.drawing?.strokes.first?.tool == .arrow && ben.ready["t"] as? String == "ready", "\(added1) \(String(describing: toBen))")
        check("review: comments checked", code(ask("p_anna", ["t": "comment-add", "asset": hero.id.uuidString, "version": current.id.uuidString, "frame": 75, "text": "x"])) == "invalid"
              && code(ask("p_anna", ["t": "comment-add", "asset": hero.id.uuidString, "version": current.id.uuidString, "frame": 3, "endFrame": 2, "text": "x"])) == "invalid"
              && code(ask("p_anna", ["t": "comment-add", "asset": hero.id.uuidString, "version": current.id.uuidString, "frame": 3, "text": "   "])) == "invalid"
              && code(ask("p_anna", ["t": "comment-add", "asset": hero.id.uuidString, "version": current.id.uuidString, "frame": 3, "text": String(repeating: "a", count: 2001)])) == "invalid"
              && code(ask("p_anna", ["t": "comment-add", "asset": hero.id.uuidString, "version": current.id.uuidString, "frame": 3, "text": "x",
                                     "drawing": ["strokes": [["tool": "pen", "colour": "#123456", "width": 0.004, "points": [[0.1, 0.1]]]]]])) == "invalid", "")
        let listed = ask("p_ben", ["t": "comments", "asset": hero.id.uuidString, "version": current.id.uuidString])["comments"] as? [[String: Any]]
        check("review: comments listed", listed?.count == 1 && listed?.first?["mine"] as? Bool == false, "\(String(describing: listed))")
        let replied = ask("p_ben", ["t": "reply-add", "comment": commentID, "text": "Agreed"])["comment"] as? [String: Any]
        let replies = replied?["replies"] as? [[String: Any]]
        check("review: reply", replies?.first?["author"] as? String == "Ben" && replies?.first?["mine"] as? Bool == true
              && store.inbox.contains { $0.kind == "reply" } && store.inbox.contains { $0.kind == "comment" && $0.summary == "Logo too early" }, "\(String(describing: replied))")
        check("review: only your own comments change", code(ask("p_ben", ["t": "comment-edit", "comment": commentID, "text": "mine now"])) == "scope"
              && code(ask("p_ben", ["t": "comment-delete", "comment": commentID])) == "scope"
              && (ask("p_anna", ["t": "comment-edit", "comment": commentID, "text": "Logo far too early"])["comment"] as? [String: Any])?["text"] as? String == "Logo far too early"
              && (ask("p_ben", ["t": "comment-complete", "comment": commentID, "completed": true])["comment"] as? [String: Any])?["completed"] as? Bool == true, "")
        let approved = ask("p_ben", ["t": "approve", "asset": hero.id.uuidString, "version": current.id.uuidString, "decision": "approve"])
        check("review: approve", approved["status"] as? String == "approved" && store.find(hero.id)?.asset.status == .approved
              && sent("p_anna").contains { $0["t"] as? String == "status" && $0["status"] as? String == "approved" && $0["by"] as? String == "Ben" }
              && store.approvals(project.id).count == 1, "\(approved)")
        out = []
        let fromMac = try? store.addComment(asset: hero.id, version: current.id, frame: 10, text: "From the Mac", author: "Studio Mac")
        check("review: the Mac's comments reach browsers", sent("p_anna").contains { ($0["comment"] as? [String: Any])?["id"] as? String == fromMac?.id.uuidString }
              && sent("p_ben").contains { $0["t"] as? String == "comment" }, "")
        let deleted = ask("p_anna", ["t": "comment-delete", "comment": commentID])
        check("review: delete your own", (deleted["comment"] as? [String: Any])?["id"] as? String == commentID && store.comment(UUID(uuidString: commentID)!) == nil
              && sent("p_ben").contains { $0["op"] as? String == "delete" }, "\(deleted)")
        var writes = 0
        while writes < 40, code(ask("p_ben", ["t": "comment-add", "asset": hero.id.uuidString, "version": current.id.uuidString, "frame": 1, "text": "n\(writes)"])) == nil { writes += 1 }
        // (Ben's 5 before count, refused ones too: a reply, an edit and a delete tried, a tick, an approval.)
        check("review: 30 writes a minute", writes == 25, "\(writes)")
        out = []
        _ = ask("p_anna", ["t": "viewing", "asset": hero.id.uuidString])
        check("review: presence", server.viewers(asset: hero.id) == ["Anna"] && sent("p_ben").contains { $0["t"] as? String == "presence" }, "")

        // An asset link with latest only, a folder link, a presentation link.
        let solo = connect("p_solo", open)
        out = []
        let onOld = try? store.addComment(asset: hero.id, version: v1.id, frame: 1, text: "On v1", author: "Studio Mac")
        let soloSawOld = sent("p_solo").contains { $0["t"] as? String == "comment" }
        if let onOld { _ = try? store.deleteComment(onOld.id) }
        check("review: latest only hides older versions' comment events", onOld != nil && !soloSawOld && !sent("p_solo").contains { $0["t"] as? String == "comment" }
              && sent("p_anna").contains { ($0["comment"] as? [String: Any])?["id"] as? String == onOld?.id.uuidString }, "")
        check("review: asset link", solo.welcome["needPassword"] as? Bool == false && solo.ready["t"] as? String == "ready"
              && (ask("p_solo", ["t": "list", "folder": NSNull()])["assets"] as? [[String: Any]])?.count == 1
              && ((ask("p_solo", ["t": "asset", "asset": hero.id.uuidString])["asset"] as? [String: Any])?["versions"] as? [[String: Any]])?.count == 1
              && code(ask("p_solo", ["t": "comments", "asset": hero.id.uuidString, "version": v1.id.uuidString])) == "scope"
              && code(ask("p_solo", ["t": "asset", "asset": dropAsset.id.uuidString])) == "scope", "\(solo)")
        let folderPeer = connect("p_folder", folderLink)
        check("review: folder link", (ask("p_folder", ["t": "list", "folder": NSNull()])["assets"] as? [[String: Any]])?.first?["id"] as? String == dropAsset.id.uuidString
              && code(ask("p_folder", ["t": "asset", "asset": hero.id.uuidString])) == "scope" && folderPeer.ready["t"] as? String == "ready", "")
        _ = connect("p_show", show)
        check("review: presentation is read only", code(ask("p_show", ["t": "comment-add", "asset": hero.id.uuidString, "version": current.id.uuidString, "frame": 1, "text": "x"])) == "readonly"
              && code(ask("p_show", ["t": "approve", "asset": hero.id.uuidString, "version": current.id.uuidString, "decision": "approve"])) == "readonly"
              && ask("p_show", ["t": "list", "folder": NSNull()])["assets"] != nil, "")

        // A password set on a live link ends sessions let in without it (and only those).
        out = []
        store.setPassword("later", link: folderLink.id)
        check("review: a new password ends open sessions", sent("p_folder").contains { $0["t"] as? String == "bye" && $0["code"] as? String == "password" }
              && closed("p_folder") && !closed("p_show") && server.peers["p_folder"] == nil, "")
        // Expiry and Turn Off: checked on every request.
        store.updateLink(open.id) { $0.expires = Date.now.addingTimeInterval(-1) }
        check("review: expired", sent("p_solo").contains { $0["t"] as? String == "bye" && $0["code"] as? String == "expired" } && closed("p_solo")
              && store.links.filter(\.isLive).count == 3, "")
        out = []
        store.revoke(link.id)
        check("review: turned off", sent("p_anna").contains { $0["t"] as? String == "bye" && $0["code"] as? String == "revoked" } && closed("p_anna") && closed("p_ben")
              && store.url(link) == nil && store.key(link.id) == nil && server.peers["p_anna"] == nil, "")
        out = []
        server.helper(["peer": ["peer": "p_late", "room": link.roomID, "state": "open", "fpLocal": fpMac, "fpRemote": fpBrowser]])
        check("review: a turned-off room is refused", closed("p_late") && server.peers["p_late"] == nil, "")

        // Password limits: 5 wrong on a peer closes it; 20 on a link locks it for an hour.
        guard let locked = try? store.newLink(scope: .project(project.id), title: "Locked", password: "right") else { return }
        var tries = 0, closedAfter = 0
        for round in 0..<4 {
            _ = connect("p_try\(round)", locked)
            for _ in 0..<5 {
                tries += 1
                _ = ask("p_try\(round)", ["t": "password", "password": "wrong"])
            }
            if round == 0, closed("p_try0") { closedAfter = 5 }
        }
        let lockedAnswer = connect("p_lockcheck", locked, password: "right")
        check("review: password limits", closedAfter == 5 && tries == 20 && code(lockedAnswer.ready) == "locked", "\(lockedAnswer.ready)")

        // Publishing (§12): the data folder and manifest, by reference on a NAS, merging a host's entries, removing.
        let publish = ReviewPublish(store: store)
        let dataFolder = base.appendingPathComponent("Data", isDirectory: true)
        guard let live = try? store.newLink(scope: .project(project.id), title: "For the host") else { return }
        do {
            try publish.makeDataFolder(project.id, only: nil, into: dataFolder)
            let manifest = (try? JSONSerialization.jsonObject(with: Data(contentsOf: dataFolder.appendingPathComponent("bundle/manifest.json")))) as? [String: Any]
            let projects = manifest?["projects"] as? [[String: Any]] ?? []
            let links = manifest?["links"] as? [[String: Any]] ?? []
            let versionsThere = (projects.first?["assets"] as? [[String: Any]] ?? []).flatMap { $0["versions"] as? [[String: Any]] ?? [] }
            let lines = ((try? String(contentsOf: dataFolder.appendingPathComponent("comments.jsonl"), encoding: .utf8)) ?? "").split(separator: "\n")
            let firstLine = lines.first.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            let liveKey = store.key(live.id) ?? Data()
            let text = String(data: (try? Data(contentsOf: dataFolder.appendingPathComponent("bundle/manifest.json"))) ?? Data(), encoding: .utf8) ?? ""
            check("review: manifest format 1", manifest?["format"] as? Int == 1 && projects.first?["id"] as? String == project.id.uuidString
                  && (projects.first?["assets"] as? [[String: Any]])?.count == 2 && (projects.first?["folders"] as? [[String: Any]])?.count == 1
                  && links.contains { $0["roomID"] as? String == live.roomID && $0["reg"] as? String == DeliverKeys.registerKey(root: store.secret(live.id) ?? Data())
                                      && $0["sign"] == nil && $0["level"] as? Int == 3 && $0["join"] as? String == DeliverKeys.joinHash(liveKey) // level 3 (§13.24)
                                      && $0["auth"] as? String == DeliverKeys.base64url(DeliverKeys.authKey(liveKey)) && ($0["root"] as? [String: Any])?["kind"] as? String == "project" }
                  && !links.contains { $0["roomID"] as? String == link.roomID } && versionsThere.contains { $0["frames"] as? Int == 75 && $0["renditions"] as? [String] == ["1080", "540", "360"] }
                  && versionsThere.allSatisfy { ($0["originalName"] as? String)?.isEmpty == false }
                  && fm.fileExists(atPath: dataFolder.appendingPathComponent("bundle/copies/\(v1.id.uuidString)/540/index.json").path)
                  && !text.contains(clip.path) && !text.contains(DeliverKeys.base64url(liveKey)) && !text.contains(store.code(live.id) ?? "-"), "\(projects.count) projects, \(links.count) links")
            check("review: comments to start from", lines.count == store.comments(hero.id).count && firstLine?["seq"] as? Int == 1 && firstLine?["comment"] != nil, "\(lines.count)")
        } catch {
            check("review: manifest format 1", false, error.localizedDescription)
        }
        // A NAS paired by its line; by reference where its media root is mounted at the media folder.
        let fingerprint = Array(repeating: "AB", count: 32).joined(separator: ":"), hostKey = DeliverKeys.base64url(DeliverKeys.random(32))
        check("review: pairing line", ReviewHostClient.pairing("pluck-host:\(hostKey)@\(fingerprint)")?.pin == fingerprint
              && ReviewHostClient.pairing(hostKey)?.pin == nil && ReviewHostClient.pairing("pluck-host:short@AB") == nil, "")
        guard let nas = publish.addNAS(name: "Office NAS", address: "nas.test:8790", pairing: "pluck-host:\(hostKey)@\(fingerprint)") else { return check("review: NAS added", false, "") }
        publish.setMounts([.init(local: media.path, remote: "nas1")], host: nas.id)
        let nasHost = publish.host(nas.id)!
        check("review: host key kept apart", ReviewHostClient.key(nasHost) == hostKey && nasHost.pin == fingerprint
              && !((try? String(contentsOf: root.appendingPathComponent("hosts.json"), encoding: .utf8)) ?? "x").contains(hostKey), "")
        let byReference = publish.manifest(project: project.id, only: nil, host: nasHost)
        let sources = ((byReference.json["projects"] as? [[String: Any]])?.first?["assets"] as? [[String: Any]] ?? []).flatMap { $0["versions"] as? [[String: Any]] ?? [] }.compactMap { $0["source"] as? String }
        let browsed = ReviewPublish.nasPath(host: nas.id, path: "nas2/Renders/Final.mov")
        check("review: published by reference", sources.contains("nas1/Hero 30s.mov") && sources.contains("nas1/Socials/Drop.mov") && byReference.files.isEmpty
              && ReviewPublish.reference(browsed, on: nasHost) == "nas2/Renders/Final.mov" && ReviewPublish.reference(ReviewPublish.nasPath(host: UUID(), path: "nas1/a.mov"), on: nasHost) == nil
              && ReviewPublish.reference("/elsewhere/a.mov", on: nasHost) == nil && ReviewPublish.reference(media.path + "/../x.mov", on: nasHost) == nil
              && publish.plan(.project(project.id), host: nasHost).sent.isEmpty, "\(sources)")
        // A host's entries back: new comments once, changed ones in place, in frame order, deletions and approvals.
        let before = store.comments(hero.id)
        guard let kept = before.first else { return check("review: merge", false, "no comment") }
        var changedComment = kept
        changedComment.completed.toggle()
        let fresh = Deliver.Comment(asset: hero.id, version: current.id, frame: 2, text: "From a client on the host", author: "Cleo", authorToken: "t")
        func entry(_ comment: Deliver.Comment, _ seq: Int) -> [String: Any] { (ReviewPublish.entry(comment) ?? [:]).merging(["seq": seq]) { $1 } }
        let approval = Deliver.Approval(asset: hero.id, version: current.id, decision: .changes, author: "Cleo")
        let approvalJSON = (try? JSONSerialization.jsonObject(with: Deliver.encoder.encode(approval))) ?? [:]
        let entries: [[String: Any]] = [entry(kept, 1), entry(fresh, 2), entry(fresh, 3), entry(changedComment, 4), ["seq": 5, "approval": approvalJSON]]
        let merged = publish.merge(entries, project: project.id)
        let after = store.comments(hero.id)
        let again = publish.merge(entries, project: project.id)
        check("review: merge from a host", merged.added == 1 && merged.changed == 1 && after.count == before.count + 1 && after.filter { $0.id == fresh.id }.count == 1
              && after.map(\.position) == after.map(\.position).sorted() && again.added == 0 && again.changed == 0 && store.find(hero.id)?.asset.status == .needsChanges
              && store.approvals(project.id).filter { $0.id == approval.id }.count == 1 && store.inbox.contains { $0.id == fresh.id }, "\(merged) \(again)")
        let deletion: [String: Any] = ["seq": 6, "deleted": ["id": fresh.id.uuidString, "asset": hero.id.uuidString, "version": current.id.uuidString]]
        _ = publish.merge([deletion], project: other.id)
        let ignoredElsewhere = store.comment(fresh.id) != nil
        _ = publish.merge([entry(fresh, 2), deletion], project: project.id)
        check("review: merged deletions stay in their project", ignoredElsewhere && store.comment(fresh.id) == nil, "")
        // Publish, pull and remove through a stand-in NAS (§12.6 ops).
        var ops: [String] = [], puts: [String] = [], appended: [[String: Any]] = []
        ReviewHostClient.fake = { request, payload in
            if let key = request["key"] as? String { return key == hostKey ? ["ok": true] : nil }
            let op = request["op"] as? String ?? ""
            ops.append(op)
            switch op {
            case "list": return ["files": []]
            case "put": puts.append(request["path"] as? String ?? ""); return payload?.count == request["size"] as? Int ? ["ok": true] : ["error": "size"]
            case "publish": return ["ok": true, "missing": []]
            case "append": appended += request["entries"] as? [[String: Any]] ?? []; return ["ok": true, "appended": 1, "seq": 9]
            case "pull": return ["entries": [entry(Deliver.Comment(asset: hero.id, version: current.id, frame: 5, text: "Pulled", author: "Dee", authorToken: "u"), 10)], "seq": 10]
            case "status": return ["seq": 10, "viewers": 0, "copies": [current.id.uuidString: ["state": "making", "progress": 0.5]]]
            default: return ["ok": true]
            }
        }
        defer { ReviewHostClient.fake = nil }
        await publish.publish(.project(project.id), to: nasHost)
        let publication = publish.publications.first
        check("review: publish to a NAS", ops == ["list", "publish", "append"] && puts.isEmpty && publication?.host == nas.id && publish.online[nas.id] == true
              && appended.count == store.comments(hero.id).count + store.comments(dropAsset.id).count, "\(ops) \(publish.problem ?? "")")
        ops = []
        _ = try? store.addComment(asset: hero.id, version: current.id, frame: 7, text: "Owner note after publishing", author: "Editor")
        await publish.pull()
        check("review: pull from a NAS", ops == ["append", "pull", "status"] && store.comments(hero.id).contains { $0.text == "Pulled" }
              && (appended.last?["comment"] as? [String: Any])?["text"] as? String == "Owner note after publishing"
              && publication.flatMap { publish.hostState[$0.id]?.making } == 0.5 && publish.publications(asset: hero.id).count == 1, "\(ops)")
        // An invitation whose server claims a paired host's id (another certificate and node) can't take its place.
        do {
            let keyFile = ReviewHostTunnel.keyFile(nasHost), marker = Data("real host key".utf8)
            try? FileManager.default.createDirectory(at: keyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? marker.write(to: keyFile)
            let pairFake = ReviewHostClient.fake
            ReviewHostClient.fake = { request, _ in
                request["pair"] != nil ? ["ok": true, "device": UUID().uuidString, "key": "k", "host": ["id": nas.id.uuidString, "name": "Office NAS"]] : nil
            }
            ReviewHostClient.fakeFingerprint = "EE:EE"
            ReviewHostTunnel.tunnelStart = { _ in ("127.0.0.1:1", "mynode") }
            let forged = PrivateNetwork.Invitation(way: .reviewHost(node: "othernode", relay: nil, expires: .now.addingTimeInterval(600), pin: "EE:EE", lan: "127.0.0.1:1", role: "mac"),
                                                   name: "Office NAS", code: "ABCDEFGHJKMN")
            var refusal = ""
            do { _ = try await ReviewHostClient.pair(forged, publish: publish) } catch { refusal = (error as? Deliver.Failure)?.code ?? "\(error)" }
            check("review: a paired host's id can't be taken over", refusal == "taken" && publish.host(nas.id)?.pin == fingerprint
                  && (try? Data(contentsOf: keyFile)) == marker && publish.hosts.filter { $0.id == nas.id }.count == 1, refusal)
            ReviewHostClient.fake = pairFake
            ReviewHostClient.fakeFingerprint = nil
            ReviewHostTunnel.tunnelStart = nil
            try? FileManager.default.removeItem(at: keyFile)
        }
        // Link changes reach the NAS at once: a new link upserted, a turned-off one removed (projects untouched).
        var linkOps: [[String: Any]] = []
        let beforeLinks = ReviewHostClient.fake
        ReviewHostClient.fake = { request, payload in
            if request["op"] as? String == "publish" { linkOps.append(request) }
            return beforeLinks?(request, payload)
        }
        let extra = try? store.newLink(scope: .project(project.id), title: "Extra")
        await publish.sendLinks()
        if let extra { store.revoke(extra.id) }
        await publish.sendLinks()
        await publish.sendLinks()
        let upserted = (linkOps.first?["manifest"] as? [String: Any])?["links"] as? [[String: Any]] ?? []
        let dropped = (linkOps.last?["remove"] as? [String: Any])?["links"] as? [String] ?? []
        check("review: link changes reach the NAS", linkOps.count == 2 && upserted.contains { $0["id"] as? String == extra?.id.uuidString }
              && dropped.contains(extra?.id.uuidString ?? "-") && ((linkOps.last?["manifest"] as? [String: Any])?["projects"] as? [Any])?.isEmpty == true
              && !((linkOps.last?["manifest"] as? [String: Any])?["links"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == extra?.id.uuidString },
              "\(linkOps.count) \(dropped)")
        ReviewHostClient.fake = beforeLinks
        ops = []
        var removed: [String: Any] = [:]
        let previous = ReviewHostClient.fake
        ReviewHostClient.fake = { request, payload in
            if request["op"] as? String == "publish" { removed = request["remove"] as? [String: Any] ?? [:] }
            return previous?(request, payload)
        }
        if let publication { await publish.remove(publication.id) }
        check("review: remove from host", ops == ["publish"] && (removed["projects"] as? [String]) == [project.id.uuidString] && publish.publications.isEmpty
              && store.comments(hero.id).contains { $0.text == "Pulled" }, "\(ops) \(removed)")

        // Branding: a logo made small enough, colours made readable, in `ready` and in the manifest.
        let logoFile = base.appendingPathComponent("logo.png")
        let big = NSImage(size: NSSize(width: 2400, height: 1200), flipped: false) { rect in
            for x in stride(from: 0, to: 2400, by: 3) { NSColor(calibratedHue: Double(x) / 2400, saturation: 1, brightness: 1, alpha: 1).setFill(); NSRect(x: Double(x), y: 0, width: 3, height: rect.height).fill() }
            return true
        }
        if let tiff = big.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) { try? png.write(to: logoFile) }
        let logo = Deliver.Branding.logo(from: logoFile)
        let logoSize = logo.flatMap { NSBitmapImageRep(data: $0) }.map { ($0.pixelsWide, $0.pixelsHigh) }
        var branding = Deliver.Branding(name: "Studio", logo: logo, accent: "#202020", bg: "#101010", text: "#151515")
        let readable = branding.readable
        check("review: branding logo and contrast", logo != nil && (logo?.count ?? .max) <= Deliver.Branding.logoBytes && (logoSize?.1 ?? 999) <= 512
              && Deliver.Branding.contrast(Deliver.Branding.rgb(readable.text), Deliver.Branding.rgb(readable.bg)) >= 4.5
              && Deliver.Branding.contrast(Deliver.Branding.rgb(readable.accent), Deliver.Branding.rgb(readable.bg)) >= 3, "\(String(describing: logoSize)) \(logo?.count ?? 0) \(readable)")
        branding.text = "#F0F0F0"
        store.branding = branding
        let brandLink = try? store.newLink(scope: .project(project.id), title: "Branded")
        let branded = brandLink.map { connect("p_brand", $0) }
        let wired = branded?.ready["branding"] as? [String: Any]
        let brandManifest = publish.manifest(project: project.id, only: nil, host: nil)
        check("review: branding reaches browsers and hosts", wired?["name"] as? String == "Studio" && (wired?["logo"] as? String).flatMap { Data(base64Encoded: $0) } == logo
              && wired?["text"] as? String == "#F0F0F0" && (brandManifest.json["branding"] as? [String: Any])?["logo"] as? String == "branding/logo.png"
              && brandManifest.files.contains { $0.path == "branding/logo.png" }, "\(String(describing: wired?.keys))")
        store.setProjectBranding(Deliver.Branding(name: "Own", accent: "#E0A15E"), project.id)
        check("review: project branding overrides", store.branding(for: project.id)?.name == "Own" && store.branding(for: other.id)?.name == "Studio", "")
        store.branding = nil
        store.setProjectBranding(nil, project.id)
        // The helper's room states, and the owner's name on comments.
        server.helper(["room": ["room": live.roomID, "state": "standby"]])
        let standby = server.rooms[live.roomID]
        server.helper(["room": ["room": live.roomID, "state": "active"]])
        UserDefaults.standard.removeObject(forKey: DeliverSettings.authorKey)
        check("review: standby and active rooms, and the name on comments", standby == "standby" && server.rooms[live.roomID] == "active" && DeliverSettings.author == "Editor", "")

        // Removing: the asset's copies go, the original stays.
        let heroCopies = store.copies(v1.id)
        store.remove(asset: hero.id)
        check("review: remove asset", store.find(hero.id) == nil && !fm.fileExists(atPath: heroCopies.path) && fm.fileExists(atPath: clip.path), "")
        store.deleteProject(project.id)
        check("review: delete project", store.project(project.id) == nil && store.links.allSatisfy { $0.project != project.id } && fm.fileExists(atPath: drop.path), "")
        await reviewParityTest()
        await reviewRound3Test()
    }

    /// The Frame.io-parity additions (§6.1): parts for big messages, personal and team links, a name first, pausing, internal
    /// comments, reactions, fields, general/page/pinned comments, proxy, still, waveform, captions and page fetches, burned-in
    /// watermarks, the activity log, uploads (limits, names, hashes, attachments), exports, image sequences, the sync wait.
    static func reviewParityTest() async {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("ReviewParity-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        func waitFor(_ condition: () -> Bool) async { for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(25)) } }

        // Old files still read: a link and a comment written before these fields existed; a general comment's null frame.
        let oldLink = #"{"id":"\#(UUID().uuidString)","title":"Old","scope":{"project":{"_0":"\#(UUID().uuidString)"}},"roomID":"r","mode":"review","allowDownload":false,"latestOnly":false,"created":"2026-11-01T10:00:00Z"}"#
        let general = #"{"id":"\#(UUID().uuidString)","asset":"\#(UUID().uuidString)","version":"\#(UUID().uuidString)","frame":null,"text":"General","author":"A","replies":[],"completed":false,"created":"2026-11-01T10:00:00Z"}"#
        let decodedLink = try? Deliver.decoder.decode(Deliver.ShareLink.self, from: Data(oldLink.utf8))
        let decodedComment = try? Deliver.decoder.decode(Deliver.Comment.self, from: Data(general.utf8))
        check("parity: old files and null frames read", decodedLink?.title == "Old" && decodedLink?.isTeam == false && decodedLink?.shownFields == ["status"]
              && decodedComment?.frame == nil && decodedComment?.text == "General", "")
        check("parity: hashtags and subtitles", Deliver.Comment.tags("Fix #Logo and #FF0000, not#this? #ok_2") == ["logo", "ff0000", "this", "ok_2"]
              && DeliverCopies.parseSubtitles("1\n00:00:01,500 --> 00:00:03,000\nHello there\n\n2\n00:00:04.000 --> 00:00:05.250\nSecond").map(\.text) == ["Hello there", "Second"]
              && DeliverCopies.parseSubtitles("1\n00:00:01,500 --> 00:00:03,000\nHello there").first?.start == 1.5, "\(Deliver.Comment.tags("Fix #Logo and #FF0000, not#this? #ok_2"))")

        // A project with a clip (with sound and a subtitle file beside it), a PDF and an image sequence.
        guard let manager = AppDelegate.shared?.manager, let ffmpeg = manager.tool("ffmpeg"), let ffprobe = manager.tool("ffprobe") else { return check("parity: ffmpeg", false, "") }
        let media = base.appendingPathComponent("Media", isDirectory: true)
        try? fm.createDirectory(at: media, withIntermediateDirectories: true)
        let clip = media.appendingPathComponent("Spot.mov")
        _ = await DeliveryCheck.output(ffmpeg, ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=320x180:r=25:d=2", "-f", "lavfi", "-i", "sine=f=440:d=2",
                                                "-c:v", "mpeg4", "-q:v", "4", "-c:a", "aac", "-shortest", clip.path])
        try? "1\n00:00:00,000 --> 00:00:01,000\nHello world\n".write(to: media.appendingPathComponent("Spot.srt"), atomically: true, encoding: .utf8)
        let pdf = media.appendingPathComponent("Script.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        if let context = CGContext(pdf as CFURL, mediaBox: &box, nil) {
            for _ in 0..<2 { context.beginPDFPage(nil); context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 20, y: 20, width: 100, height: 60)); context.endPDFPage() }
            context.closePDF()
        }
        let frames = media.appendingPathComponent("Frames", isDirectory: true)
        try? fm.createDirectory(at: frames, withIntermediateDirectories: true)
        _ = await DeliveryCheck.output(ffmpeg, ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=160x90:r=25:d=1", frames.appendingPathComponent("shot_%04d.png").path])
        let sequence = DeliverCopies.sequence(frames)
        check("parity: image sequence found", sequence?.count == 25 && sequence?.start == 1 && sequence?.pattern.hasSuffix("shot_%04d.png") == true
              && DeliverCopies.sequence(media) == nil, "\(String(describing: sequence))")

        let store = DeliverStore(root: base.appendingPathComponent("Review", isDirectory: true))
        guard let project = try? store.newProject("Parity"), let socials = store.newFolder("Uploads", in: project.id, parent: nil) else { return check("parity: project", false, "") }
        let added = (try? store.add([clip, pdf, frames], to: project.id, folder: nil)) ?? []
        guard let spot = added.first(where: { $0.name == "Spot" }), let script = added.first(where: { $0.name == "Script" }), let seq = added.first(where: { $0.name == "Frames" }) else {
            return check("parity: added", false, "\(added.map(\.name))")
        }
        check("parity: kinds", spot.kind == .video && script.kind == .document && seq.kind == .video, "")
        for asset in [spot, script, seq] {
            let out = store.copies(asset.current.id)
            let made = await DeliverCopies.make(store.original(asset.current) ?? URL(fileURLWithPath: asset.current.path), kind: asset.kind, into: out, ffmpeg: ffmpeg, ffprobe: ffprobe) { _ in }
            store.update(version: asset.current.id, of: asset.id) {
                $0.probe = made.probe
                $0.copy = .ready(made.renditions ?? [])
                if asset.kind == .document { $0.pages = DeliverCopies.pageCount(out) }
            }
        }
        let spotCopies = store.copies(spot.current.id)
        let wave = (try? JSONSerialization.jsonObject(with: Data(contentsOf: spotCopies.appendingPathComponent("waveform.json")))) as? [String: Any]
        let vtt = (try? String(contentsOf: spotCopies.appendingPathComponent("captions.vtt"), encoding: .utf8)) ?? ""
        let words = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: spotCopies.appendingPathComponent("transcript.json")))) as? [String: Any])?["words"] as? [[Any]]
        check("parity: waveform and captions made", wave?["buckets"] as? Int == 2000 && (wave?["peaks"] as? [Int])?.contains { $0 > 10 } == true
              && vtt.hasPrefix("WEBVTT") && vtt.contains("00:00:00.000 --> 00:00:01.000") && words?.count == 2 && words?.last?.last as? String == "world", vtt)
        let scriptNow = store.find(script.id)?.asset
        check("parity: PDF pages", scriptNow?.current.pages == 2 && fm.fileExists(atPath: store.copies(script.id == scriptNow?.id ? script.current.id : UUID()).appendingPathComponent("pages/2.jpg").path)
              && (scriptNow?.current.probe?.width ?? 0) == 2560, "\(String(describing: scriptNow?.current))")
        let seqProbe = store.find(seq.id)?.asset.current.probe
        check("parity: image sequence copies", seqProbe?.frames == 25 && seqProbe?.width == 160 && DeliverCopies.index(store.copies(seq.current.id).appendingPathComponent("540")) != nil,
              "\(String(describing: seqProbe))")
        let peaks = DeliverCopies.peaks(Data([0x00, 0x80, 0xFF, 0x7F, 0x00, 0x00]), buckets: 3)
        check("parity: peaks", peaks["peaks"] as? [Int] == [255, 255, 0], "\(peaks)")

        // The server, with a fake helper.
        let server = DeliverServer(store: store)
        var out: [[String: Any]] = []
        server.output = { out.append($0) }
        server.stillMaker = { _, frame in
            let file = base.appendingPathComponent("still-\(frame).jpg")
            fm.createFile(atPath: file.path, contents: Data(repeating: 1, count: 100))
            return file
        }
        var made: [(UUID, UUID, UUID)] = []
        server.markMaker = { made.append(($0, $1, $2)) }
        let fpMac = Array(repeating: "AA", count: 32).joined(separator: ":"), fpBrowser = Array(repeating: "BB", count: 32).joined(separator: ":")
        var nextID = 1000
        func sent(_ peer: String) -> [[String: Any]] {
            out.compactMap { ($0["send"] as? [String: Any]).flatMap { $0["peer"] as? String == peer ? $0["msg"] as? [String: Any] : nil } }
        }
        func closed(_ peer: String) -> Bool { out.contains { ($0["close"] as? [String: Any])?["peer"] as? String == peer } }
        func ask(_ peer: String, _ body: [String: Any]) -> [String: Any] {
            nextID += 1
            let id = nextID
            out = []
            server.helper(["msg": ["peer": peer, "msg": body.merging(["id": id]) { $1 }]])
            return sent(peer).first { $0["re"] as? Int == id } ?? [:]
        }
        func code(_ answer: [String: Any]) -> String? { (answer["error"] as? [String: Any])?["code"] as? String }
        func connect(_ peer: String, _ link: Deliver.ShareLink, name: String = "Anna", email: String? = nil) -> [String: Any] {
            out = []
            server.helper(["peer": ["peer": peer, "room": link.roomID, "state": "open", "fpLocal": fpMac, "fpRemote": fpBrowser]])
            guard let hello = sent(peer).first, let key = store.key(link.id), let level = store.level(link.id),
                  let macNonce = DeliverKeys.browserCheck(hello, level: level, key: key, pub: DeliverKeys.publicKey(root: store.secret(link.id) ?? Data()), fpMac: fpMac, fpBrowser: fpBrowser)
            else { return [:] }
            let nonce = DeliverKeys.random(32)
            let proof = DeliverKeys.proof(authKey: DeliverKeys.authKey(key), role: "browser", macNonce: macNonce, browserNonce: nonce, fpMac: fpMac, fpBrowser: fpBrowser)
            var auth: [String: Any] = ["t": "auth", "v": level, "nonce": DeliverKeys.base64url(nonce), "proof": proof, "token": DeliverKeys.base64url(DeliverKeys.random(32)), "name": name]
            if let email { auth["email"] = email }
            _ = ask(peer, auth)
            return sent(peer).first { $0["t"] as? String == "ready" } ?? [:]
        }
        guard let client = try? store.newLink(scope: .project(project.id), title: "Client"), let team = try? store.newLink(scope: .project(project.id), title: "Team") else { return }
        store.updateLink(client.id) { $0.allowProxy = true; $0.fields = ["status", "rating"]; $0.featuredField = "rating"; $0.uploads = .init(folder: socials.id, maxBytes: 1000, types: ["video", "image"]) }
        store.updateLink(team.id) { $0.audience = "team" }
        let clientReady = connect("p_c", store.link(client.id)!, email: "anna@example.com")
        let readyInfo = clientReady["link"] as? [String: Any]
        check("parity: ready carries the link's settings", readyInfo?["allowProxy"] as? Bool == true && readyInfo?["featuredField"] as? String == "rating"
              && readyInfo?["fields"] as? [String] == ["status", "rating"] && readyInfo?["watermark"] is NSNull && (readyInfo?["uploads"] as? [String: Any])?["maxBytes"] as? Int64 == 1000
              && readyInfo?["audience"] as? String == "client" && readyInfo?["passwordHash"] == nil, "\(String(describing: readyInfo))")
        _ = connect("p_t", store.link(team.id)!, name: "Producer")

        // Internal comments: the team sees them, clients never (not in lists, events or counts) and can't write them.
        let internalAdd = ask("p_t", ["t": "comment-add", "asset": spot.id.uuidString, "version": spot.current.id.uuidString, "frame": 3, "text": "Ours only", "internal": true])
        let clientSawEvent = sent("p_c").contains { $0["t"] as? String == "comment" }
        let internalID = (internalAdd["comment"] as? [String: Any])?["id"] as? String ?? ""
        let clientList = ask("p_c", ["t": "comments", "asset": spot.id.uuidString, "version": spot.current.id.uuidString])["comments"] as? [[String: Any]]
        let teamList = ask("p_t", ["t": "comments", "asset": spot.id.uuidString, "version": spot.current.id.uuidString])["comments"] as? [[String: Any]]
        let count = ((ask("p_c", ["t": "list", "folder": NSNull()])["assets"] as? [[String: Any]])?.first { $0["id"] as? String == spot.id.uuidString }?["current"] as? [String: Any])?["comments"] as? Int
        check("parity: internal comments stay with the team", (internalAdd["comment"] as? [String: Any])?["internal"] as? Bool == true && !clientSawEvent
              && clientList?.isEmpty == true && teamList?.count == 1 && count == 0
              && code(ask("p_c", ["t": "comment-add", "asset": spot.id.uuidString, "version": spot.current.id.uuidString, "frame": 3, "text": "x", "internal": true])) == "scope"
              && code(ask("p_c", ["t": "react", "comment": internalID, "emoji": "👍", "on": true])) == "notFound", "\(internalAdd)")

        // General, page and pinned comments.
        let generalAdd = ask("p_c", ["t": "comment-add", "asset": spot.id.uuidString, "version": spot.current.id.uuidString, "frame": NSNull(), "text": "Love it overall #music"])
        let wired = generalAdd["comment"] as? [String: Any]
        let pageAdd = ask("p_c", ["t": "comment-add", "asset": script.id.uuidString, "version": script.current.id.uuidString, "page": 2, "text": "Typo", "anchor": [0.4, 0.3]])
        check("parity: general, page and pinned comments", wired?["frame"] is NSNull && wired?["endFrame"] is NSNull
              && (pageAdd["comment"] as? [String: Any])?["page"] as? Int == 2 && ((pageAdd["comment"] as? [String: Any])?["anchor"] as? [Double]) == [0.4, 0.3]
              && code(ask("p_c", ["t": "comment-add", "asset": script.id.uuidString, "version": script.current.id.uuidString, "page": 3, "text": "x"])) == "invalid"
              && code(ask("p_c", ["t": "comment-add", "asset": spot.id.uuidString, "version": spot.current.id.uuidString, "frame": 1, "text": "x", "anchor": [1.5, 0]])) == "invalid"
              && code(ask("p_c", ["t": "comment-add", "asset": spot.id.uuidString, "version": spot.current.id.uuidString, "frame": "x", "text": "x"])) == "invalid", "\(generalAdd)")

        // Reactions.
        let generalID = wired?["id"] as? String ?? ""
        let reacted = (ask("p_c", ["t": "react", "comment": generalID, "emoji": "👍", "on": true])["comment"] as? [String: Any])?["reactions"] as? [[String: Any]]
        let teamSaw = sent("p_t").first { $0["t"] as? String == "comment" && $0["op"] as? String == "edit" }
        let teamReactions = (teamSaw?["comment"] as? [String: Any])?["reactions"] as? [[String: Any]]
        _ = try? store.react(UUID(uuidString: generalID)!, emoji: "🔥", by: "owner", on: true)
        let off = (ask("p_c", ["t": "react", "comment": generalID, "emoji": "👍", "on": false])["comment"] as? [String: Any])?["reactions"] as? [[String: Any]]
        check("parity: reactions", reacted?.first?["emoji"] as? String == "👍" && reacted?.first?["count"] as? Int == 1 && reacted?.first?["mine"] as? Bool == true
              && teamReactions?.first?["mine"] as? Bool == false && off?.count == 1 && off?.first?["emoji"] as? String == "🔥"
              && code(ask("p_c", ["t": "react", "comment": generalID, "emoji": "💩", "on": true])) == "invalid", "\(String(describing: reacted)) \(String(describing: off))")

        // Fields: a client sets only the featured one; status as a field writes an approval; the team sets any.
        let rated = ask("p_c", ["t": "field-set", "asset": spot.id.uuidString, "field": "rating", "value": 4])
        let teamField = sent("p_t").first { $0["t"] as? String == "field" }
        check("parity: fields", (rated["asset"] as? [String: Any]).flatMap { $0["fields"] as? [String: Any] }?["rating"] as? Int == 4 && store.find(spot.id)?.asset.fields?.rating == 4
              && teamField?["value"] as? Int == 4 && teamField?["by"] as? String == "Anna"
              && code(ask("p_c", ["t": "field-set", "asset": spot.id.uuidString, "field": "status", "value": "approved"])) == "scope"
              && code(ask("p_c", ["t": "field-set", "asset": spot.id.uuidString, "field": "rating", "value": 9])) == "invalid"
              && ask("p_t", ["t": "field-set", "asset": spot.id.uuidString, "field": "status", "value": "approved"])["asset"] != nil
              && store.find(spot.id)?.asset.status == .approved && store.approvals(project.id).count == 1
              && ask("p_t", ["t": "field-set", "asset": spot.id.uuidString, "field": "keywords", "value": ["hero", "final"]])["asset"] != nil
              && store.find(spot.id)?.asset.fields?.keywords == ["hero", "final"], "\(rated)")

        check("parity: approve only where status is the featured field", code(ask("p_c", ["t": "approve", "asset": spot.id.uuidString, "version": spot.current.id.uuidString, "decision": "approve"])) == "scope", "")
        // New fetches: proxy (pieces), still, waveform, transcript, captions, page.
        func fetch(_ peer: String, _ body: [String: Any]) -> [String: Any] { ask(peer, ["t": "fetch", "asset": spot.id.uuidString, "version": spot.current.id.uuidString].merging(body) { $1 }) }
        func freeFetches(_ peer: String) { for f in server.peers[peer]?.fetches ?? [] { server.helper(["served": ["peer": peer, "fetch": f, "bytes": 1, "result": "done"]]) } }
        let proxy = fetch("p_c", ["what": "proxy", "rendition": "1080"])
        let serve = out.compactMap { $0["serve"] as? [String: Any] }.first
        let pieces = serve?["pieces"] as? [[String: Any]] ?? (serve.map { [$0] } ?? [])
        let index = DeliverCopies.index(spotCopies.appendingPathComponent("1080"))
        let total = (index.map { $0.`init`.length + $0.segments.reduce(0) { $0 + $1.length } }) ?? -1
        check("parity: proxy download", (proxy["size"] as? NSNumber)?.int64Value == total && pieces.reduce(Int64(0)) { $0 + (($1["length"] as? NSNumber)?.int64Value ?? 0) } == total
              && (proxy["name"] as? String)?.hasSuffix("(review).mp4") == true && code(fetch("p_t", ["what": "proxy"])) == "scope", "\(proxy) \(pieces.count)")
        freeFetches("p_c")
        check("parity: a finished proxy is a download", store.activity(client.id).contains { $0.kind == "downloaded" && $0.detail?.what == "proxy" && $0.email == "anna@example.com" }, "")
        _ = fetch("p_c", ["what": "still", "frame": 10])
        await waitFor { out.contains { $0["serve"] != nil } }
        check("parity: still", out.contains { (($0["serve"] as? [String: Any])?["path"] as? String)?.hasSuffix("still-10.jpg") == true }
              && code(fetch("p_c", ["what": "still", "frame": 999])) == "invalid", "\(out)")
        freeFetches("p_c")
        let waveform = fetch("p_c", ["what": "waveform"])
        let transcript = fetch("p_c", ["what": "transcript"])
        let captions = fetch("p_c", ["what": "captions"])
        freeFetches("p_c")
        let page = ask("p_c", ["t": "fetch", "asset": script.id.uuidString, "version": script.current.id.uuidString, "what": "page", "n": 2])
        freeFetches("p_c")
        check("parity: waveform, transcript, captions and pages", (waveform["json"] as? [String: Any])?["buckets"] as? Int == 2000
              && ((transcript["json"] as? [String: Any])?["words"] as? [Any])?.count == 2 && captions["type"] as? String == "text/vtt" && page["type"] as? String == "image/jpeg"
              && code(ask("p_c", ["t": "fetch", "asset": script.id.uuidString, "version": script.current.id.uuidString, "what": "page", "n": 3])) == "invalid"
              && code(ask("p_c", ["t": "fetch", "asset": seq.id.uuidString, "version": seq.current.id.uuidString, "what": "captions"])) == "notFound", "\(captions) \(page)")
        var stills = 0
        while stills < 70, code(fetch("p_c", ["what": "still", "frame": 1])) == nil { stills += 1; freeFetches("p_c"); await waitFor { server.peers["p_c"]?.fetches.isEmpty == true } ; freeFetches("p_c") }
        check("parity: stills limited", stills == 59, "\(stills)")

        // Activity: opened, viewed, played, commented, approved; a host's entry once.
        _ = ask("p_c", ["t": "viewing", "asset": spot.id.uuidString])
        _ = ask("p_c", ["t": "played", "asset": spot.id.uuidString, "version": spot.current.id.uuidString, "from": 0, "to": 40])
        let kinds = Set(store.activity(client.id).map(\.kind))
        let hostEntry = Deliver.Activity(link: client.id, name: "Host viewer", kind: "opened")
        let once = store.logOnce(hostEntry), twice = store.logOnce(hostEntry)
        check("parity: activity log", kinds.isSuperset(of: ["opened", "viewed", "played", "commented", "downloaded"]) && once && !twice
              && store.activity(client.id).contains { $0.kind == "played" && $0.detail?.to == 40 && $0.name == "Anna" }
              && store.activity(team.id).contains { $0.kind == "approved" } && store.views(client.id).opened == 2, "\(kinds)")
        for n in 0..<30 { store.log(.init(link: team.id, at: n < 10 ? Date.now.addingTimeInterval(-200 * 86400) : .now, kind: "viewed")) }
        store.trimActivity(team.id)
        check("parity: old activity trimmed", store.activity(team.id).allSatisfy { Date.now.timeIntervalSince($0.at) < 181 * 86400 } && store.activity(team.id).count >= 20, "")
        // R8: the retention setting (default 90; 30/90/180/forever), applied to every link's log; the manifest carries it.
        let savedDays = UserDefaults.standard.object(forKey: DeliverStore.activityDaysKey)
        UserDefaults.standard.removeObject(forKey: DeliverStore.activityDaysKey)
        let defaultDays = DeliverStore.activityDays
        store.log(.init(link: team.id, at: Date.now.addingTimeInterval(-60 * 86400), kind: "viewed"))
        UserDefaults.standard.set(30, forKey: DeliverStore.activityDaysKey)
        store.trimAllActivity()
        let after30 = store.activity(team.id).allSatisfy { Date.now.timeIntervalSince($0.at) < 31 * 86400 }
        UserDefaults.standard.set(0, forKey: DeliverStore.activityDaysKey)
        store.log(.init(link: team.id, at: Date.now.addingTimeInterval(-900 * 86400), kind: "viewed"))
        store.trimAllActivity()
        let forever = store.activity(team.id).contains { Date.now.timeIntervalSince($0.at) > 800 * 86400 }
        UserDefaults.standard.set(7, forKey: DeliverStore.activityDaysKey) // not a choice: back to 90
        let bogus = DeliverStore.activityDays
        if let savedDays { UserDefaults.standard.set(savedDays, forKey: DeliverStore.activityDaysKey) } else { UserDefaults.standard.removeObject(forKey: DeliverStore.activityDaysKey) }
        check("parity: activity retention setting", defaultDays == 90 && after30 && forever && bogus == 90, "\(defaultDays) \(after30) \(forever) \(bogus)")
        // R11: "Delete Link and Its Data": gone from the list, a link tombstone for the hosts, its activity file deleted.
        if let doomed = try? store.newLink(scope: .project(project.id), title: "Doomed") {
            store.log(.init(link: doomed.id, kind: "opened"))
            let file = store.activityFile(doomed.id)
            let hadFile = fm.fileExists(atPath: file.path)
            store.deleteLink(doomed.id)
            check("parity: delete link and its data", hadFile && store.link(doomed.id) == nil && !fm.fileExists(atPath: file.path) && store.key(doomed.id) == nil, "")
        }
        // R11 on the Worker: `erase` from Swift is answered `erased` (local cf dev only; wrong keys: signal.test.ts).
        let signal = ProcessInfo.processInfo.environment["PLUCK_E2E_SIGNAL"] ?? "ws://127.0.0.1:8787/signal"
        let devSite = signal.replacingOccurrences(of: "ws://", with: "http://").replacingOccurrences(of: "/signal", with: "")
        if (try? await URLSession.shared.data(from: URL(string: "\(devSite)/robots.txt")!)) == nil {
            skip("parity: erase a room on the Worker", "no local cf dev at \(devSite)")
        } else {
            let room = DeliverKeys.base64url(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
            let reg = DeliverKeys.base64url(DeliverKeys.random(32))
            let erased = await DeliverLink.erase(room: room, reg: reg, signal: signal) // also proves URLSession sends no Origin
            check("parity: erase a room on the Worker", erased == true, "")
        }

        // Uploads: off, too large, wrong type, names made safe, the hash checked, the file filed; attachments.
        check("parity: uploads refused", code(ask("p_t", ["t": "upload-begin", "name": "a.mov", "size": 10, "for": "asset"])) == "scope"
              && code(ask("p_c", ["t": "upload-begin", "name": "a.mov", "size": 5000, "for": "asset"])) == "tooLarge"
              && code(ask("p_c", ["t": "upload-begin", "name": "a.pdf", "size": 10, "for": "asset"])) == "scope"
              && code(ask("p_c", ["t": "upload-begin", "name": "a.png", "size": 60_000_000, "for": "attachment"])) == "tooLarge"
              && DeliverServer.safeName("../../etc/passwd") == "..-etc-passwd".drop(while: { $0 == "." || $0 == "-" }).description
              && !DeliverServer.safeName("a/b\\c:d").contains("/") && DeliverServer.safeName(".hidden") == "hidden", DeliverServer.safeName("../../etc/passwd"))
        let payload = Data(repeating: 7, count: 300)
        let begun = ask("p_c", ["t": "upload-begin", "name": "../Shot 1.png", "size": payload.count, "type": "image/png", "for": "asset"])
        let accept = out.compactMap { $0["accept"] as? [String: Any] }.first
        let partPath = accept?["path"] as? String ?? ""
        check("parity: upload accepted inside Uploads", begun["credit"] as? Int == 8_388_608 && begun["upload"] as? Int == nextID
              && partPath.hasPrefix(server.uploadsFolder.appendingPathComponent(client.id.uuidString).path + "/") && !partPath.contains(".."), "\(begun) \(partPath)")
        fm.createFile(atPath: partPath, contents: payload)
        let uploadID = begun["upload"] as? Int ?? 0
        server.helper(["upload": ["peer": "p_c", "upload": uploadID, "state": "done", "bytes": payload.count]])
        let sha = DeliverServer.sha256(of: URL(fileURLWithPath: partPath)) ?? ""
        nextID += 1
        let endID = nextID
        out = []
        server.helper(["msg": ["peer": "p_c", "msg": ["id": endID, "t": "upload-end", "upload": uploadID, "sha256": sha]]])
        await waitFor { sent("p_c").contains { $0["re"] as? Int == endID } }
        let filed = sent("p_c").first { $0["re"] as? Int == endID }?["asset"] as? [String: Any]
        let uploaded = store.content(project.id).assets.first { $0.id.uuidString == filed?["id"] as? String }
        check("parity: upload filed", uploaded?.folder == socials.id && uploaded?.name == "Shot 1" && uploaded?.kind == .image
              && uploaded.map { $0.current.path.hasPrefix(server.uploadsFolder.path) } == true && !fm.fileExists(atPath: partPath)
              && store.inbox.contains { $0.kind == "upload" } && store.activity(client.id).contains { $0.kind == "uploaded" }, "\(String(describing: filed))")
        // A wrong hash: refused, the part gone.
        let second = ask("p_c", ["t": "upload-begin", "name": "b.png", "size": 3, "for": "attachment"])
        let secondPath = (out.compactMap { $0["accept"] as? [String: Any] }.first?["path"] as? String) ?? ""
        fm.createFile(atPath: secondPath, contents: Data([1, 2, 3]))
        server.helper(["upload": ["peer": "p_c", "upload": second["upload"] as? Int ?? 0, "state": "done", "bytes": 3]])
        nextID += 1
        let badEnd = nextID
        out = []
        server.helper(["msg": ["peer": "p_c", "msg": ["id": badEnd, "t": "upload-end", "upload": second["upload"] as? Int ?? 0, "sha256": "wrong"]]])
        await waitFor { sent("p_c").contains { $0["re"] as? Int == badEnd } }
        check("parity: a wrong hash is refused", code(sent("p_c").first { $0["re"] as? Int == badEnd } ?? [:]) == "invalid" && !fm.fileExists(atPath: secondPath), "")
        // An attachment, then a comment carrying it, then fetched.
        let third = ask("p_c", ["t": "upload-begin", "name": "ref.png", "size": 3, "type": "image/png", "for": "attachment"])
        let thirdPath = (out.compactMap { $0["accept"] as? [String: Any] }.first?["path"] as? String) ?? ""
        fm.createFile(atPath: thirdPath, contents: Data([4, 5, 6]))
        server.helper(["upload": ["peer": "p_c", "upload": third["upload"] as? Int ?? 0, "state": "done", "bytes": 3]])
        nextID += 1
        let attachEnd = nextID
        out = []
        server.helper(["msg": ["peer": "p_c", "msg": ["id": attachEnd, "t": "upload-end", "upload": third["upload"] as? Int ?? 0,
                                                     "sha256": DeliverServer.sha256(of: URL(fileURLWithPath: thirdPath)) ?? ""]]])
        await waitFor { sent("p_c").contains { $0["re"] as? Int == attachEnd } }
        let attachment = (sent("p_c").first { $0["re"] as? Int == attachEnd }?["attachment"] as? [String: Any])?["id"] as? String ?? ""
        let withFile = ask("p_c", ["t": "comment-add", "asset": spot.id.uuidString, "version": spot.current.id.uuidString, "frame": 2, "text": "See ref", "attachments": [attachment]])
        freeFetches("p_c")
        let gotFile = fetch("p_c", ["what": "attachment", "attachment": attachment])
        freeFetches("p_c")
        check("parity: attachments", ((withFile["comment"] as? [String: Any])?["attachments"] as? [[String: Any]])?.first?["name"] as? String == "ref.png"
              && gotFile["name"] as? String == "ref.png" && (gotFile["size"] as? NSNumber)?.intValue == 3
              && code(ask("p_c", ["t": "comment-add", "asset": spot.id.uuidString, "version": spot.current.id.uuidString, "frame": 2, "text": "x", "attachments": [attachment]])) == "invalid",
              "\(gotFile) \(code(ask("p_c", ["t": "comment-add", "asset": spot.id.uuidString, "version": spot.current.id.uuidString, "frame": 2, "text": "x", "attachments": [attachment]])) ?? "-")")
        var inFlight = 0, firstOpen = 0
        while inFlight < 6, code(ask("p_c", ["t": "upload-begin", "name": "c\(inFlight).png", "size": 3, "for": "asset"])) == nil { if inFlight == 0 { firstOpen = nextID }; inFlight += 1 }
        check("parity: 4 uploads at once a link", inFlight == 4, "\(inFlight)")
        server.helper(["upload": ["peer": "p_c", "upload": firstOpen, "state": "cancelled", "bytes": 0]])
        check("parity: a cancelled upload goes", server.peers["p_c"]?.uploads[firstOpen] == nil, "")

        // A name first; personal links; pausing.
        store.updateLink(client.id) { $0.requireName = true }
        _ = connect("p_n", store.link(client.id)!, name: "")
        let before = code(ask("p_n", ["t": "list", "folder": NSNull()]))
        _ = ask("p_n", ["t": "identify", "name": "Ben", "email": "ben@example.com"])
        check("parity: a name first", before == "auth" && !closed("p_n") && ask("p_n", ["t": "list", "folder": NSNull()])["assets"] != nil
              && server.peers["p_n"]?.email == "ben@example.com", "")
        let personal = store.invite(["Cleo", "  ", "Dan"], like: client.id)
        let cleoReady = connect("p_cleo", personal[0], name: "Somebody else")
        _ = ask("p_cleo", ["t": "identify", "name": "Not Cleo"])
        check("parity: personal links", personal.count == 2 && Set(personal.map(\.roomID)).count == 2 && personal[0].roomID != client.roomID
              && personal[0].recipient == "Cleo" && (cleoReady["me"] as? [String: Any])?["name"] as? String == "Cleo" && server.peers["p_cleo"]?.name == "Cleo"
              && (cleoReady["link"] as? [String: Any])?["recipient"] as? String == "Cleo" && personal[0].allowProxy == true, "\(cleoReady)")
        out = []
        store.updateLink(personal[0].id) { $0.paused = true }
        let byePaused = sent("p_cleo").contains { $0["t"] as? String == "bye" && $0["code"] as? String == "paused" }
        _ = connect("p_cleo2", store.link(personal[0].id)!)
        let pausedAnswer = sent("p_cleo2").contains { $0["t"] as? String == "bye" && $0["code"] as? String == "paused" } && closed("p_cleo2")
        check("parity: paused", byePaused && pausedAnswer && server.peers["p_n"] != nil, "")
        let copy = try? store.duplicate(client.id)
        check("parity: duplicate", copy?.roomID != client.roomID && copy?.requireName == true && copy?.uploads == store.link(client.id)?.uploads && copy.map { store.url($0) != nil } == true, "")

        // A share of a few assets.
        let few = try? store.newLink(scope: .assets([spot.id, script.id], project: project.id), title: "Two")
        let fewReady = few.map { connect("p_few", $0) } ?? [:]
        let fewList = ask("p_few", ["t": "list", "folder": NSNull()])["assets"] as? [[String: Any]]
        check("parity: a few assets", (fewReady["root"] as? [String: Any])?["kind"] as? String == "assets" && fewList?.count == 2
              && code(ask("p_few", ["t": "asset", "asset": seq.id.uuidString])) == "scope", "\(String(describing: fewList?.count))")

        // Burned-in watermark: the text filled in, copies made with it, fetches routed to them.
        let mark = Deliver.ShareLink.Watermark(text: "{name} · {email} · {date} · {link}", position: "bottomRight", opacity: 0.4, size: 0.05, burned: true)
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let filled = DeliverCopies.watermarkText(mark, link: personal[1], date: day)
        check("parity: watermark text", filled == "Dan · \(day.formatted(.iso8601.year().month().day())) · \(personal[1].title)"
              && DeliverCopies.drawtext(mark, textFile: "/tmp/x.txt", width: 1000).contains("fontsize=h*0.0500:x=w-tw-w*0.04:y=h-th-h*0.04")
              && DeliverCopies.drawtext(mark, textFile: "/tmp/x.txt", width: 1000).contains("fontcolor=white@0.40:borderw=2:bordercolor=black@0.20")
              && DeliverCopies.watermarkText(.init(text: "{name} · {email}"), link: client) == "Client", filled)
        store.updateLink(personal[1].id) { $0.watermark = mark }
        let dan = connect("p_dan", store.link(personal[1].id)!)
        let notYet = ask("p_dan", ["t": "fetch", "asset": spot.id.uuidString, "version": spot.current.id.uuidString, "what": "poster"])
        let markedFolder = DeliverCopies.marked(spotCopies, link: personal[1].id)
        let ok = await DeliverCopies.makeMarked(clip, kind: .video, probe: store.find(spot.id)!.asset.current.probe!, plain: spotCopies, into: markedFolder, mark: mark, text: filled, ffmpeg: ffmpeg)
        let markedPoster = ask("p_dan", ["t": "fetch", "asset": spot.id.uuidString, "version": spot.current.id.uuidString, "what": "poster"])
        let markedServe = out.compactMap { $0["serve"] as? [String: Any] }.first
        let plainPoster = NSImage(contentsOf: spotCopies.appendingPathComponent("poster.jpg"))?.tiffRepresentation
        let burnedPoster = NSImage(contentsOf: markedFolder.appendingPathComponent("poster.jpg"))?.tiffRepresentation
        check("parity: burned-in copies", code(notYet) == "notReady" && made.contains { $0.2 == personal[1].id } && ok
              && fm.fileExists(atPath: markedFolder.appendingPathComponent("1080/index.json").path) && markedPoster["fetch"] != nil
              && (markedServe?["path"] as? String)?.hasPrefix(markedFolder.path) == true && plainPoster != nil && burnedPoster != nil && plainPoster != burnedPoster
              && ((dan["link"] as? [String: Any])?["watermark"] as? [String: Any])?["burned"] as? Bool == true, "\(notYet)")

        // Exports: CSV quoting, FCPXML and Premiere XML parse, Avid locators, a PDF.
        let list = store.comments(spot.id, version: spot.current.id)
        let exportClip = DeliverExport.Clip(name: "Spot \"A\"", version: 1, probe: store.find(spot.id)?.asset.current.probe)
        let csv = DeliverExport.csv(list + [Deliver.Comment(asset: spot.id, version: spot.current.id, frame: 1, text: "Quote \" and, comma\nline", author: "Q")], clip: exportClip)
        let formula = DeliverExport.csv([Deliver.Comment(asset: spot.id, version: spot.current.id, frame: 1, text: "=HYPERLINK(\"x\",\"y\")", author: "@bob")], clip: exportClip)
        check("parity: CSV formulas stay text", formula.contains(",'@bob,") && formula.contains("\"'=HYPERLINK(") && !formula.contains(",=") && !formula.contains(",@")
              && DeliverExport.csvField("+1") == "'+1" && DeliverExport.csvField("plain") == "plain", formula)
        let fcp = try? XMLDocument(xmlString: DeliverExport.fcpxml(list, clip: exportClip))
        let xmeml = try? XMLDocument(xmlString: DeliverExport.premiere(list, clip: exportClip))
        let timed = list.filter { $0.frame != nil }.count
        let avid = DeliverExport.avid(list, clip: exportClip).split(separator: "\n")
        let pdfFile = base.appendingPathComponent("comments.pdf")
        let pdfMade = await DeliverExport.pdf(list, asset: store.find(spot.id)!.asset, version: spot.current, store: store, into: pdfFile)
        check("parity: exports", csv.contains("\"Quote \"\" and, comma\nline\"") && csv.hasPrefix("#,Timecode")
              && (try? fcp?.nodes(forXPath: "//marker"))?.count == timed && (try? xmeml?.nodes(forXPath: "//marker"))?.count == timed && timed >= 2
              && avid.count == timed && avid.allSatisfy { $0.split(separator: "\t").count == 5 } && DeliverExport.text(list, clip: exportClip).contains("General")
              && pdfMade && (PDFDocument(url: pdfFile)?.pageCount ?? 0) >= 1, csv)
        let filtered = DeliverCommentsPanel.filter(list, completed: false, search: "ref", author: nil, tag: nil, drawings: false, internalOnly: false, sort: "time")
        let tagged = DeliverCommentsPanel.filter(list, completed: nil, search: "", author: nil, tag: "music", drawings: false, internalOnly: false, sort: "author")
        check("parity: filter and search", filtered.map(\.text) == ["See ref"] && tagged.count == 1, "\(filtered.map(\.text))")

        // An update draft lists the owner's news, never internal ones on a client link; manifests carry the new fields.
        let since = Date.now.addingTimeInterval(-60)
        _ = try? store.reply(to: UUID(uuidString: generalID)!, text: "Thanks, will do", author: "Editor")
        _ = try? store.addComment(asset: spot.id, version: spot.current.id, frame: 5, text: "Team note", author: "Editor", isInternal: true)
        DeliverServer.shared.held(store.link(client.id)!.roomID) // a level-3 address goes out only once its room is held (§13.24)
        let update = DeliverLinkRow.updateText(store.link(client.id)!, since: since, store: store)
        check("parity: update draft", update.contains("Thanks, will do") && !update.contains("Team note") && update.contains("https://pluck.tools/r/"), update)
        let publish = ReviewPublish(store: store)
        let manifest = publish.manifest(project: project.id, only: nil, host: nil).json
        let links = manifest["links"] as? [[String: Any]] ?? []
        let clientWire = links.first { $0["id"] as? String == client.id.uuidString }
        let fewWire = links.first { $0["id"] as? String == few?.id.uuidString }
        let versions = ((manifest["projects"] as? [[String: Any]])?.first?["assets"] as? [[String: Any]] ?? [])
        check("parity: manifest fields", clientWire?["requireName"] as? Bool == true && clientWire?["allowProxy"] as? Bool == true && clientWire?["featuredField"] as? String == "rating"
              && (fewWire?["root"] as? [String: Any])?["assets"] as? [String] == [spot.id.uuidString, script.id.uuidString]
              && links.contains { $0["paused"] as? Bool == true } && versions.contains { ($0["versions"] as? [[String: Any]])?.first?["pages"] as? Int == 2 }
              && versions.contains { ($0["fields"] as? [String: Any])?["rating"] as? Int == 4 }, "\(String(describing: clientWire?.keys.sorted()))")
        let activityEntry: [String: Any] = ["seq": 1, "activity": ["id": UUID().uuidString, "link": client.id.uuidString, "at": "2026-11-16T10:02:00Z", "peer": "p_x", "name": "Eve",
                                                                   "kind": "played", "asset": spot.id.uuidString, "detail": ["from": 0, "to": 12]]]
        publish.merge([activityEntry, activityEntry], project: project.id)
        check("parity: a host's activity merged once", store.activity(client.id).filter { $0.name == "Eve" }.count == 1, "")

        // A client's field and upload on a NAS: the field set here, the file fetched, added and deleted there.
        let nasKey = DeliverKeys.base64url(DeliverKeys.random(32))
        guard let nas = publish.addNAS(name: "NAS", address: "nas-parity.test:8790", pairing: "pluck-host:\(nasKey)@\(Array(repeating: "CD", count: 32).joined(separator: ":"))") else {
            return check("parity: NAS", false, "")
        }
        var nasOps: [String] = []
        ReviewHostClient.fake = { request, _ in
            if request["key"] != nil { return ["ok": true] }
            nasOps.append(request["op"] as? String ?? "")
            return request["op"] as? String == "get" ? ["ok": true, "size": 4, "bytes": Data([9, 9, 9, 9])] : ["ok": true]
        }
        defer { ReviewHostClient.fake = nil }
        let fieldEntry: [String: Any] = ["seq": 2, "field": ["id": UUID().uuidString, "asset": seq.id.uuidString, "field": "rating", "value": 2, "by": "Eve", "link": client.id.uuidString]]
        publish.merge([fieldEntry], project: project.id)
        await publish.importUploads([["seq": 3, "upload": ["link": client.id.uuidString, "name": "../From NAS.png", "path": "uploads/\(client.id.uuidString)/x.png", "size": 4]],
                                     ["seq": 4, "upload": ["link": client.id.uuidString, "name": "evil.png", "path": "uploads/../../etc", "size": 4]]],
                                    project: project.id, host: nas)
        let fromNAS = store.content(project.id).assets.first { $0.name == "From NAS" }
        check("parity: a NAS's fields and uploads", store.find(seq.id)?.asset.fields?.rating == 2 && fromNAS?.folder == socials.id
              && nasOps.filter { $0 == "get" }.count == 1 && nasOps.contains("delete") && (fromNAS.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0.current.path)) }) == Data([9, 9, 9, 9]),
              "\(nasOps)")

        // The sync wait: sent only when every file's size and date match what SendSync sent.
        let folder = base.appendingPathComponent("Sync", isDirectory: true)
        try? fm.createDirectory(at: folder.appendingPathComponent("bundle"), withIntermediateDirectories: true)
        fm.createFile(atPath: folder.appendingPathComponent("bundle/manifest.json").path, contents: Data("{}".utf8))
        fm.createFile(atPath: folder.appendingPathComponent("comments.jsonl").path, contents: Data())
        func stamp(_ path: String) -> SendSync.Stamp {
            let values = try? folder.appendingPathComponent(path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return .init(size: Int64(values?.fileSize ?? 0), modified: (values?.contentModificationDate ?? .now).timeIntervalSince1970.rounded())
        }
        let all = ["bundle/manifest.json": stamp("bundle/manifest.json"), "comments.jsonl": stamp("comments.jsonl")]
        check("parity: reload waits for the copy", ReviewPublish.allSent(folder, sent: all) && !ReviewPublish.allSent(folder, sent: ["comments.jsonl": stamp("comments.jsonl")])
              && !ReviewPublish.allSent(folder, sent: all.merging(["comments.jsonl": .init(size: 9, modified: 0)]) { $1 }), "")
    }

    /// End to end with no fakes (PLUCK_E2E_DIR set; driven by an outside script that runs a headless browser):
    /// the real store, copies and links, then either
    /// - PLUCK_E2E_MODE=nas: publish to a real `pluck-review --host … --listen 127.0.0.1:8790` over the TLS sync
    ///   endpoint (pairing from <dir>/data/pairing.txt) and pull back what browsers wrote, or
    /// - PLUCK_E2E_MODE=mac: run the real helper from Contents/Helpers through DeliverLink against local signaling.
    /// It writes <dir>/links.json (name → key, room, id), then runs commands from <dir>/cmd ("<n> <verb> [link]",
    /// answered with <dir>/done-<n>): pull, state, revoke, pause, unpause, expire, finish. `state` writes <dir>/state.json.
    static func reviewE2E(_ dir: URL) async {
        let fm = FileManager.default
        let mode = ProcessInfo.processInfo.environment["PLUCK_E2E_MODE"] ?? "nas"
        let base = dir.appendingPathComponent("swift-\(mode)", isDirectory: true)
        try? fm.removeItem(at: base)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        guard let manager = AppDelegate.shared?.manager, let ffmpeg = manager.tool("ffmpeg"), let ffprobe = manager.tool("ffprobe") else { return check("e2e: ffmpeg", false, "") }
        let media = base.appendingPathComponent("Media", isDirectory: true)
        try? fm.createDirectory(at: media.appendingPathComponent("Socials"), withIntermediateDirectories: true)
        func clip(_ url: URL, _ seconds: Int, _ size: String, tone: Int) async {
            _ = await DeliveryCheck.output(ffmpeg, ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=\(size):r=25:d=\(seconds)", "-f", "lavfi", "-i", "sine=f=\(tone):d=\(seconds)",
                                                    "-c:v", "mpeg4", "-q:v", "3", "-c:a", "aac", "-shortest", "-timecode", "01:00:00:00", url.path])
        }
        let hero1 = media.appendingPathComponent("Hero 30s.mov"), hero2 = media.appendingPathComponent("v2/Hero 30s.mov"), teaser = media.appendingPathComponent("Socials/Teaser 15s.mov")
        try? fm.createDirectory(at: hero2.deletingLastPathComponent(), withIntermediateDirectories: true)
        await clip(hero1, 8, "1280x720", tone: 440)
        await clip(hero2, 8, "1280x720", tone: 660)
        await clip(teaser, 4, "640x360", tone: 330)
        try? "1\n00:00:00,000 --> 00:00:02,000\nHello world\n\n2\n00:00:02,000 --> 00:00:04,000\nSecond line here\n".write(to: hero2.deletingPathExtension().appendingPathExtension("srt"), atomically: true, encoding: .utf8)
        let pdf = media.appendingPathComponent("Script.pdf")
        var box = CGRect(x: 0, y: 0, width: 600, height: 400)
        if let context = CGContext(pdf as CFURL, mediaBox: &box, nil) {
            for page in 0..<2 {
                context.beginPDFPage(nil)
                context.setFillColor(CGColor(red: page == 0 ? 1 : 0, green: 0, blue: page == 0 ? 0 : 1, alpha: 1))
                context.fill(CGRect(x: 40, y: 40, width: 300, height: 200))
                context.endPDFPage()
            }
            context.closePDF()
        }
        let picture = media.appendingPathComponent("Poster.png")
        _ = await DeliveryCheck.output(ffmpeg, ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=800x600:d=1", "-frames:v", "1", picture.path])

        let voice = media.appendingPathComponent("Voiceover.m4a")
        _ = await DeliveryCheck.output(ffmpeg, ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "sine=f=220:d=5", "-af", "volume='if(lt(t,2),0.2,0.9)':eval=frame", "-c:a", "aac", voice.path])
        let store = DeliverStore(root: base.appendingPathComponent("Review", isDirectory: true))
        guard let project = try? store.newProject("Spring campaign"), let inbox = store.newFolder("From clients", in: project.id, parent: nil) else { return check("e2e: project", false, "") }
        let added = (try? store.add([hero1, media.appendingPathComponent("Socials"), pdf, picture, voice], to: project.id, folder: nil)) ?? []
        guard let hero = added.first(where: { $0.name == "Hero 30s" }), let script = added.first(where: { $0.name == "Script" }),
              let teaserAsset = added.first(where: { $0.name == "Teaser 15s" }), let poster = added.first(where: { $0.name == "Poster" }),
              let voiceAsset = added.first(where: { $0.name == "Voiceover" }), (try? store.addVersion(hero2, to: hero.id)) != nil, let heroNow = store.find(hero.id)?.asset else { return check("e2e: assets", false, "\(added.map(\.name))") }
        for (asset, version) in [(heroNow, heroNow.versions[0]), (heroNow, heroNow.versions[1]), (teaserAsset, teaserAsset.current), (script, script.current), (poster, poster.current), (voiceAsset, voiceAsset.current)] {
            let out = store.copies(version.id)
            let made = await DeliverCopies.make(store.original(version) ?? URL(fileURLWithPath: version.path), kind: asset.kind, into: out, ffmpeg: ffmpeg, ffprobe: ffprobe) { _ in }
            store.update(version: version.id, of: asset.id) {
                $0.probe = made.probe
                $0.copy = .ready(made.renditions ?? [])
                if asset.kind == .document { $0.pages = DeliverCopies.pageCount(out) }
            }
        }
        // A transcript bigger than one data-channel message (parts, §6.1).
        let v2 = heroNow.versions[1].id
        let words = (0..<9000).map { i -> [Any] in [Double(i) * 0.0008, Double(i) * 0.0008 + 0.0007, "word\(i)"] }
        if let data = try? JSONSerialization.data(withJSONObject: ["lang": "en", "words": words]) { try? data.write(to: store.copies(v2).appendingPathComponent("transcript.json")) }
        let copiesOK = [heroNow.versions[0].id, v2, teaserAsset.current.id].allSatisfy { fm.fileExists(atPath: store.copies($0).appendingPathComponent("1080/index.json").path) }
            && fm.fileExists(atPath: store.copies(v2).appendingPathComponent("captions.vtt").path) && fm.fileExists(atPath: store.copies(script.current.id).appendingPathComponent("pages/2.jpg").path)
            && fm.fileExists(atPath: store.copies(v2).appendingPathComponent("waveform.json").path)
            && fm.fileExists(atPath: store.copies(voiceAsset.current.id).appendingPathComponent("waveform.json").path)
        check("e2e: real copies (video, versions, captions, waveform, PDF pages, image)", copiesOK, "")

        // The links the browser script uses.
        var made: [String: Deliver.ShareLink] = [:]
        func link(_ name: String, _ scope: Deliver.Scope, mode linkMode: Deliver.ShareLink.Mode = .review, password: String? = nil, _ change: (inout Deliver.ShareLink) -> Void = { _ in }) {
            guard let l = try? store.newLink(scope: scope, title: name.capitalized, mode: linkMode, allowDownload: true, password: password) else { return }
            store.updateLink(l.id, change)
            made[name] = store.link(l.id)
        }
        link("main", .project(project.id), password: "test") {
            $0.allowProxy = true; $0.askEmail = true; $0.fields = ["status", "rating"]; $0.featuredField = "rating"
            $0.uploads = .init(folder: inbox.id, maxBytes: 200 << 20, types: ["video", "audio", "image", "document", "other"])
            $0.watermark = .init(text: "{name} · {email} · {date}", position: "bottomRight", opacity: 0.3, size: 0.03, burned: false)
        }
        link("team", .project(project.id)) { $0.audience = "team"; $0.fields = ["status", "rating"] }
        link("client", .project(project.id)) { $0.fields = ["status", "rating"]; $0.featuredField = "status" }
        link("few", .assets([hero.id, script.id], project: project.id))
        link("paused", .project(project.id)) { $0.paused = true }
        link("show", .project(project.id), mode: .presentation)
        link("revoke", .project(project.id))
        link("expire", .project(project.id))
        link("pausing", .project(project.id))

        func writeLinks() {
            var json: [String: Any] = [:]
            for (name, l) in made { if let key = store.key(l.id), let secret = store.secret(l.id) { json[name] = ["key": DeliverKeys.base64url(key), "room": l.roomID, "id": l.id.uuidString, "reg": DeliverKeys.registerKey(root: secret), "pub": DeliverKeys.publicKey(root: secret), "join": DeliverKeys.join(key), "url": store.url(l) ?? ""] } }
            json["assets"] = ["hero": hero.id.uuidString, "script": script.id.uuidString, "teaser": teaserAsset.id.uuidString, "poster": poster.id.uuidString, "voice": voiceAsset.id.uuidString,
                              "originalV1": heroNow.versions[0].path, "heroV1": heroNow.versions[0].id.uuidString, "heroV2": v2.uuidString, "originalV2": heroNow.versions[1].path] as [String: Any]
            try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent("links.json"))
        }
        func state() {
            let assets = store.content(project.id).assets
            let comments = assets.flatMap { store.comments($0.id) }.compactMap { c -> [String: Any]? in
                guard let data = try? Deliver.encoder.encode(c) else { return nil }
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            let activity = made.values.flatMap { store.activity($0.id) }.map { ["kind": $0.kind, "link": $0.link.uuidString, "name": $0.name ?? ""] }
            let json: [String: Any] = ["comments": comments, "approvals": store.approvals(project.id).count,
                                       "assets": assets.map { ["id": $0.id.uuidString, "name": $0.name, "status": $0.status.rawValue, "folder": $0.folder?.uuidString ?? "",
                                                               "rating": $0.fields?.rating ?? -1, "path": $0.current.path] as [String: Any] },
                                       "activity": activity, "inbox": store.inbox.map { ["kind": $0.kind, "summary": $0.summary] }]
            try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent("state.json"))
        }

        var macLink: DeliverLink?
        var publish: ReviewPublish?
        if mode == "mac" {
            let server = DeliverServer(store: store)
            let running = DeliverLink(server: server)
            running.testSettings = ["signal": ProcessInfo.processInfo.environment["PLUCK_E2E_SIGNAL"] ?? "ws://127.0.0.1:8787/signal", "local": true]
            running.start()
            server.notify = { _, _ in }
            macLink = running
            for _ in 0..<200 where server.rooms.values.filter({ $0 == "active" }).count < made.values.filter(\.isLive).count { try? await Task.sleep(for: .milliseconds(100)) }
            check("e2e mac: the real helper registered every live room", server.rooms.values.filter { $0 == "active" }.count == made.count && running.version != nil, "\(server.rooms)")
        } else {
            let pairing = (try? String(contentsOf: dir.appendingPathComponent("data/pairing.txt"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let p = ReviewPublish(store: store)
            guard let nas = p.addNAS(name: "Test NAS", address: "127.0.0.1:8790", pairing: pairing) else { return check("e2e nas: pairing", false, pairing) }
            await p.publish(.project(project.id), to: nas)
            check("e2e nas: published over the TLS sync endpoint", p.problem == nil && p.online[nas.id] == true, p.problem ?? "")
            publish = p
        }
        writeLinks()
        state()
        try? Data().write(to: dir.appendingPathComponent("ready-\(mode)"))

        // Commands from the browser script, for up to 30 minutes.
        let cmd = dir.appendingPathComponent("cmd")
        for _ in 0..<9000 {
            try? await Task.sleep(for: .milliseconds(200))
            guard let text = try? String(contentsOf: cmd, encoding: .utf8), !text.isEmpty else { continue }
            try? fm.removeItem(at: cmd)
            let words = text.split(separator: " ").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard words.count >= 2 else { continue }
            let target = words.count > 2 ? made[words[2]] : nil
            switch words[1] {
            case "pull": await publish?.pull()
            case "revoke": if let target { store.revoke(target.id) }
            case "pause": if let target { store.updateLink(target.id) { $0.paused = true } }
            case "unpause": if let target { store.updateLink(target.id) { $0.paused = nil } }
            case "expire": if let target { store.updateLink(target.id) { $0.expires = Date().addingTimeInterval(-1) } }
            default: break
            }
            if words[1] != "finish" { try? await Task.sleep(for: .milliseconds(800)) } // (links reach a NAS after 0.5 s)
            if words[1] == "pull" || words[1] == "pause" || words[1] == "revoke" || words[1] == "expire" || words[1] == "unpause" { await publish?.sendLinks() }
            state()
            try? Data().write(to: dir.appendingPathComponent("done-\(words[0])"))
            if words[1] == "finish" { break }
        }
        macLink?.stop()
        check("e2e \(mode): finished", true, "")
    }
}

/// A NAS review host in this process (§13.1/§13.2 ops), for the round-3 tests: rule M on publish, `changes`
/// by seq, appends kept once by (id, rev), the uploads root, pairing.
@MainActor
final class ReviewFakeHost {
    var objects: [String: (wire: [String: Any], seq: Int, tombstone: Bool)] = [:]
    var entries: [[String: Any]] = []
    var accepted: Set<String> = []
    var acceptedCount = 0
    var publishes = 0
    var storeSeq = 0
    var files: [String: Data] = [:]
    var paired: [String] = []
    var offsetOnce = true
    var uploads: [String: Data] = [:]
    /// `changes` in pages of this many objects (oldest first), like the real host.
    var pageLimit: Int?

    private func stamp(_ wire: [String: Any]) -> DeliverMerge.Stamp {
        DeliverMerge.Stamp(rev: wire["rev"] as? Int ?? 0, at: (wire["at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? .distantPast, by: wire["by"] as? String ?? "")
    }

    private func put(_ kind: String, _ wire: [String: Any], tombstone: Bool = false) -> Bool {
        guard let id = wire["id"] as? String else { return false }
        let key = kind + ":" + id
        if let old = objects[key], !DeliverMerge.incomingWins(stored: stamp(old.wire), storedTombstone: old.tombstone, incoming: stamp(wire), incomingTombstone: tombstone) { return false }
        storeSeq += 1
        objects[key] = (wire, storeSeq, tombstone)
        return true
    }

    /// The host's state, for comparing two runs.
    var state: String {
        objects.keys.sorted().map { key in
            let item = objects[key]!
            return key + (try! JSONSerialization.data(withJSONObject: item.wire, options: [.sortedKeys])).base64EncodedString()
        }.joined(separator: ";") + "|\(entries.count)"
    }

    func answer(_ request: [String: Any], _ payload: Data?) -> [String: Any]? {
        if request["op"] == nil, request["key"] != nil || request["device"] != nil {
            return ["ok": true, "version": "0.3.0", "protocol": 3, "links": 3, "host": ["id": UUID().uuidString, "name": "Office NAS", "role": "main"]]
        }
        if let code = request["pair"] as? String {
            paired.append(code)
            return ["ok": true, "version": "0.3.0", "protocol": 3, "links": 3, "host": ["id": "6F1E7C2A-0000-4000-8000-000000000001", "name": "Office NAS", "role": "main"],
                    "device": "D1", "key": DeliverKeys.base64url(Data(repeating: 9, count: 32))]
        }
        switch request["op"] as? String {
        case "list": return ["files": files.map { ["path": $0.key, "size": $0.value.count] }]
        case "put": files[request["path"] as? String ?? ""] = payload ?? Data(); return ["ok": true]
        case "publish":
            publishes += 1
            var stale: [String] = []
            let manifest = request["manifest"] as? [String: Any] ?? [:]
            for project in manifest["projects"] as? [[String: Any]] ?? [] {
                var meta = project
                meta["folders"] = nil
                meta["assets"] = nil
                if !put("project", meta) { stale.append(meta["id"] as? String ?? "") }
                for folder in project["folders"] as? [[String: Any]] ?? [] { _ = put("folder", folder.merging(["project": project["id"] ?? ""]) { $1 }) }
                for asset in project["assets"] as? [[String: Any]] ?? [] where !put("asset", asset.merging(["project": project["id"] ?? ""]) { $1 }) {
                    stale.append(asset["id"] as? String ?? "")
                }
            }
            for link in manifest["links"] as? [[String: Any]] ?? [] { _ = put("link", link) }
            for tombstone in request["tombstones"] as? [[String: Any]] ?? [] {
                _ = put(tombstone["kind"] as? String ?? "", tombstone, tombstone: true)
            }
            return ["ok": true, "missing": [String](), "stale": stale, "storeSeq": storeSeq]
        case "changes" where pageLimit != nil:
            let since = request["since"] as? Int ?? 0
            let all = objects.filter { $0.value.seq > since }.sorted { $0.value.seq < $1.value.seq }
            let page = all.prefix(pageLimit!)
            var answer: [String: Any] = ["more": page.count < all.count, "storeSeq": page.count < all.count ? page.last!.value.seq : storeSeq]
            for (kind, field) in [("project", "projects"), ("folder", "folders"), ("asset", "assets"), ("link", "links")] {
                answer[field] = page.filter { $0.key.hasPrefix(kind + ":") && !$0.value.tombstone }.map { $0.value.wire.merging(["seq": $0.value.seq]) { $1 } }
            }
            answer["removed"] = page.filter(\.value.tombstone).map { $0.value.wire.merging(["seq": $0.value.seq]) { $1 } }
            return answer
        case "changes":
            let since = request["since"] as? Int ?? 0
            var answer: [String: Any] = ["storeSeq": storeSeq, "more": false]
            for (kind, field) in [("project", "projects"), ("folder", "folders"), ("asset", "assets"), ("link", "links")] {
                answer[field] = objects.filter { $0.key.hasPrefix(kind + ":") && $0.value.seq > since && !$0.value.tombstone }.map(\.value.wire)
            }
            answer["removed"] = objects.filter { $0.value.seq > since && $0.value.tombstone }.map(\.value.wire)
            return answer
        case "append":
            for entry in request["entries"] as? [[String: Any]] ?? [] {
                let body = (entry["comment"] ?? entry["approval"] ?? entry["activity"] ?? entry["deleted"]) as? [String: Any] ?? [:]
                let key = "\(entry.keys.sorted().first ?? ""):\(body["id"] as? String ?? ""):\(body["rev"] as? Int ?? 0)"
                guard accepted.insert(key).inserted else { continue }
                acceptedCount += 1
                entries.append(entry.merging(["seq": entries.count + 1]) { $1 })
            }
            return ["ok": true, "seq": entries.count]
        case "pull":
            let since = request["since"] as? Int ?? 0
            return ["entries": entries.filter { ($0["seq"] as? Int ?? 0) > since }, "seq": entries.count]
        case "roots": return ["roots": ["nas1", "renders"], "writable": ["renders"]]
        case "browse":
            let path = request["path"] as? String ?? ""
            if path.isEmpty { return ["entries": [["name": "nas1", "path": "nas1", "dir": true], ["name": "renders", "path": "renders", "dir": true]]] }
            return ["entries": [["name": "Hero 30s_v2.mov", "path": path + "/Hero 30s_v2.mov", "dir": false, "size": 5_000_000],
                                ["name": "Day 1", "path": path + "/Day 1", "dir": true]]]
        case "mkdir": return ["ok": true]
        case "upload-begin": return ["upload": "u1", "path": request["path"] ?? "", "have": uploads["u1"]?.count ?? 0]
        case "upload-part":
            let offset = (request["offset"] as? NSNumber)?.intValue ?? 0
            if offsetOnce, offset > 0 { offsetOnce = false; return ["error": "offset", "have": uploads["u1"]?.count ?? 0] }
            var data = uploads["u1"] ?? Data()
            guard offset == data.count else { return ["error": "offset", "have": data.count] }
            data.append(payload ?? Data())
            uploads["u1"] = data
            return ["ok": true, "have": data.count]
        case "upload-end": return ["ok": true, "path": "renders/Spring/Hero 30s v4 2.mov", "size": uploads["u1"]?.count ?? 0]
        case "status": return ["version": "0.3.0", "protocol": 3, "copies": [String: Any]()]
        default: return ["ok": true]
        }
    }
}

extension PhotoSelfTest {
    /// Regressions for the second bug pass on the data host (sync paging, host versions, foreign links, wire fields…).
    static func reviewFixes2(fake: ReviewFakeHost, store: DeliverStore, publish: ReviewPublish, sync: DeliverSync, host: Deliver.Host, project: UUID, base: URL) async {
        // A host version: no copy job (nothing to stamp or send), and its `original` goes back as it came.
        if let teaser = store.content(project).assets.first(where: { $0.name == "Teaser" }) {
            var wire = fake.objects["asset:" + teaser.id.uuidString]!.wire
            var versions = wire["versions"] as? [[String: Any]] ?? []
            versions[0]["original"] = "originals/\(teaser.current.id.uuidString).mov"
            versions[0]["renditions"] = ["1080", "540"]
            wire["versions"] = versions
            wire["rev"] = (wire["rev"] as? Int ?? 1) + 1
            fake.storeSeq += 1
            fake.objects["asset:" + teaser.id.uuidString] = (wire, fake.storeSeq, false)
            await sync.round()
            let copies = DeliverCopies(store: store)
            let rev = store.find(teaser.id)?.asset.rev, waiting = sync.outbox().count
            copies.enqueue(asset: teaser.id, version: teaser.current.id)
            let state = store.find(teaser.id)?.asset.current.copy
            let item = (publish.manifest(project: project, only: [teaser.id], host: host, onlyLinks: []).json["projects"] as? [[String: Any]])?.first?["assets"] as? [[String: Any]]
            let sent = (item?.first?["versions"] as? [[String: Any]])?.first ?? [:]
            let plain = (publish.manifest(project: project, only: [teaser.id], host: host).json["projects"] as? [[String: Any]])?.first?["assets"] as? [[String: Any]]
            check("fixes2: a plain publish to another host doesn't claim the data host's original",
                  ((plain?.first?["versions"] as? [[String: Any]])?.first ?? [:])["original"] == nil, "")
            check("fixes2: a host version makes no copies and keeps its original and renditions", copies.working == nil && state == .ready(["1080", "540"])
                  && store.find(teaser.id)?.asset.rev == rev && sync.outbox().count == waiting
                  && sent["original"] as? String == "originals/\(teaser.current.id.uuidString).mov" && sent["renditions"] as? [String] == ["1080", "540"],
                  "\(String(describing: rev)) \(waiting) \(sent)")
        }

        // `changes` in pages: an asset on an earlier page than its project's meta still goes in.
        let newProject = UUID(), newAsset = UUID(), stamp = DeliverServer.date(.now)
        fake.storeSeq += 1
        fake.objects["asset:" + newAsset.uuidString] = (["id": newAsset.uuidString, "project": newProject.uuidString, "name": "Paged", "kind": "video", "status": "none",
                                                          "versions": [["id": UUID().uuidString, "number": 1, "size": 1, "renditions": ["1080"]]],
                                                          "rev": 1, "at": stamp, "by": "another"], fake.storeSeq, false)
        fake.storeSeq += 1
        fake.objects["project:" + newProject.uuidString] = (["id": newProject.uuidString, "name": "Paged project", "hidden": true, "rev": 1, "at": stamp, "by": "another"], fake.storeSeq, false)
        fake.pageLimit = 1
        await sync.round()
        fake.pageLimit = nil
        check("fixes2: changes pages apply together (projects first), hidden comes over", store.find(newAsset)?.project == newProject
              && store.project(newProject)?.hidden == true && sync.state.storeSeq == fake.storeSeq, "\(sync.state.storeSeq) \(fake.storeSeq)")
        // A folder whose project never comes (all pages read): storeSeq still moves on, not re-read every round.
        fake.storeSeq += 1
        fake.objects["folder:" + UUID().uuidString] = (["id": UUID().uuidString, "project": UUID().uuidString, "name": "Orphan", "rev": 1, "at": stamp, "by": "another"], fake.storeSeq, false)
        fake.pageLimit = 1
        await sync.round()
        fake.pageLimit = nil
        check("fixes2: an object whose project never comes doesn't hold storeSeq back", sync.state.storeSeq == fake.storeSeq, "\(sync.state.storeSeq) \(fake.storeSeq)")
        if var hidden = store.project(newProject) {
            hidden.hidden = true
            check("fixes2: hidden goes on the wire", ReviewPublish.meta(hidden)["hidden"] as? Bool == true && DeliverSync.project(ReviewPublish.meta(hidden))?.hidden == true, "")
        }

        // A link made on another Mac (no key here) isn't "dead": a publish never asks a host to drop it.
        let foreignID = UUID()
        if let foreign = DeliverSync.link(["id": foreignID.uuidString, "roomID": "room-\(foreignID.uuidString.prefix(8))", "project": project.uuidString,
                                           "root": ["kind": "project", "id": project.uuidString], "madeOn": "Another Mac", "rev": 1, "at": stamp, "by": "another"]) {
            store.applyLink(foreign)
        }
        check("fixes2: another Mac's link isn't removed from hosts", store.link(foreignID).map(store.isForeign) == true && !publish.deadLinks(project).contains(foreignID.uuidString), "")
        // Turning it off here reaches the data host by the merge, without secrets (the host keeps its own).
        store.revoke(foreignID)
        await sync.round()
        let offWire = fake.objects["link:" + foreignID.uuidString]?.wire ?? [:]
        check("fixes2: another Mac's link turned off here reaches the NAS", offWire["revoked"] is String && offWire["reg"] == nil && offWire["sign"] == nil
              && (offWire["rev"] as? Int ?? 0) >= 2, "\(offWire.keys.sorted())")

        // An error answer (not just offline) shows in the footer.
        ReviewHostClient.fake = { request, payload in request["op"] as? String == "changes" ? ["error": "auth"] : fake.answer(request, payload) }
        await sync.round()
        ReviewHostClient.fake = { fake.answer($0, $1) }
        let refused = sync.problem
        await sync.round()
        check("fixes2: a refused sync says so, then clears", refused != nil && sync.problem == nil && sync.footer?.hasPrefix(String(localized: "Synced with")) == true, "\(String(describing: refused))")
        ReviewHostClient.fake = { request, payload in request["op"] as? String == "changes" ? ["error": "disk-full"] : fake.answer(request, payload) }
        await sync.round()
        ReviewHostClient.fake = { fake.answer($0, $1) }
        check("fixes2: an unknown host error reads as a sentence, not its code", sync.problem == String(localized: "the NAS refused the change"), "\(String(describing: sync.problem))")
        await sync.round()

        // Captions: word times in seconds, spread over their cue.
        let clip = base.appendingPathComponent("Words.mov"), out = base.appendingPathComponent("words-copy", isDirectory: true)
        try? "1\n00:00:01,000 --> 00:00:03,000\nhello world\n".write(to: base.appendingPathComponent("Words.srt"), atomically: true, encoding: .utf8)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        DeliverCopies.captions(for: clip, duration: 4, into: out)
        let words = ((try? Data(contentsOf: out.appendingPathComponent("transcript.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["words"] as? [[Any]] ?? []
        let times = words.map { [($0[0] as? NSNumber)?.doubleValue ?? -1, ($0[1] as? NSNumber)?.doubleValue ?? -1] }
        check("fixes2: caption word times", times == [[1, 2], [2, 3]], "\(times)")

        // The proof hashes the highest copy there.
        let copyFolder = base.appendingPathComponent("hash-copy", isDirectory: true)
        try? FileManager.default.createDirectory(at: copyFolder.appendingPathComponent("540"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: copyFolder.appendingPathComponent("540/media.m4s").path, contents: Data([1]))
        let picked = DeliverProof.copyToHash(copyFolder).path.hasSuffix("540/media.m4s")
        try? FileManager.default.removeItem(at: copyFolder.appendingPathComponent("540"))
        FileManager.default.createFile(atPath: copyFolder.appendingPathComponent("image.jpg").path, contents: Data([1]))
        check("fixes2: proof hashes the highest copy or the picture", picked && DeliverProof.copyToHash(copyFolder).lastPathComponent == "image.jpg", "")
    }

    /// Round 3 (§13.18, R1): merge vectors, the outbox and migration against a fake NAS, NAS invitations, the route,
    /// watched folders, Resolve markers, the message, the proof, deadlines, protocol levels, TrueNAS, host release
    /// signatures, and Browse.
    static func reviewRound3Test() async {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Review3-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: base)
            ReviewHostClient.fake = nil
            ReviewHostClient.fakeFingerprint = nil
            ReviewHostTunnel.lanProbe = nil
            ReviewHostTunnel.tunnelStart = nil
            TrueNASClient.fake = nil
            DeliverResolveMarkers.bridge = { try await ResolveBridge.run($0) }
            DeliverHostUpdate.testKey = nil
        }

        // §13.0's shared merge vectors.
        let t0 = Date(timeIntervalSince1970: 1_800_000_000), t1 = t0.addingTimeInterval(60), t2 = t1.addingTimeInterval(60)
        typealias S = DeliverMerge.Stamp
        let wins = DeliverMerge.incomingWins
        let v1 = wins(S(rev: 2, at: t1, by: "A"), false, S(rev: 3, at: t0, by: "B"), false)
        let v2 = wins(S(rev: 2, at: t1, by: "A"), false, S(rev: 2, at: t2, by: "A"), false)
        let v3 = wins(S(rev: 2, at: t1, by: "A"), false, S(rev: 2, at: t1, by: "B"), false)
        let v4 = wins(S(rev: 2, at: t1, by: "A"), false, S(rev: 2, at: t1, by: "A"), true)
        let v5 = !wins(S(rev: 3, at: t1, by: "A"), true, S(rev: 2, at: t2, by: "B"), false)
        let r = (1...4).map { n in Deliver.Comment.Reply(text: "r\(n)", author: "A", created: t0.addingTimeInterval(Double(n))) }
        var stored6 = Deliver.Comment(asset: UUID(), version: UUID(), text: "x", author: "A", replies: [r[0], r[1]])
        stored6.rev = 2; stored6.at = t1; stored6.by = "A"
        var incoming6 = stored6
        incoming6.rev = 3; incoming6.text = "y"; incoming6.replies = [r[0], r[2]]; incoming6.deletedReplies = [r[1].id]
        let m6 = DeliverMerge.comment(stored: stored6, incoming: incoming6)
        var stored7 = stored6
        stored7.rev = 3; stored7.replies = [r[0], r[3]]; stored7.deletedReplies = nil; stored7.text = "kept"
        var incoming7 = stored6
        incoming7.rev = 2; incoming7.replies = [r[0], r[2]]
        let m7 = DeliverMerge.comment(stored: stored7, incoming: incoming7)
        check("round3: merge vectors 1–5", v1 && v2 && v3 && v4 && v5, "\(v1) \(v2) \(v3) \(v4) \(v5)")
        check("round3: merge vectors 6–7 (MC)", m6.text == "y" && m6.replies.map(\.text) == ["r1", "r3"] && m7.text == "kept" && m7.replies.map(\.text) == ["r1", "r3", "r4"],
              "\(m6.replies.map(\.text)) \(m7.replies.map(\.text))")

        // A store, its publisher and sync against the fake NAS.
        let fake = ReviewFakeHost()
        ReviewHostClient.fake = { fake.answer($0, $1) }
        let root = base.appendingPathComponent("Review", isDirectory: true)
        let store = DeliverStore(root: root)
        let publish = ReviewPublish(store: store)
        let fp = Array(repeating: "AB", count: 32).joined(separator: ":")
        guard let host = publish.addNAS(name: "Office NAS", address: "nas.test:8790", pairing: "pluck-host:" + DeliverKeys.base64url(Data(repeating: 7, count: 32)) + "@" + fp),
              let project = try? store.newProject("Spring") else { return check("round3: setup", false, "") }
        let clipFile = base.appendingPathComponent("Hero 30s_v1.mov")
        fm.createFile(atPath: clipFile.path, contents: Data(repeating: 1, count: 2000))
        let hero = (try? store.add([clipFile], to: project.id, folder: nil))?.first
        if let hero { _ = try? store.addComment(asset: hero.id, version: hero.current.id, frame: nil, text: "Nice", author: "Editor") }
        _ = try? store.newLink(scope: .project(project.id), title: "Spring – cuts")
        let sync = DeliverSync(store: store, publish: publish)
        sync.manual = true
        do { try await sync.migrate(to: host) } catch { check("round3: migration runs", false, "\(error)") }
        let first = fake.state, firstAccepted = fake.acceptedCount
        do { try await sync.migrate(to: host) } catch { check("round3: migration runs again", false, "\(error)") }
        check("round3: migration is idempotent (same host state, no duplicate appends)", first == fake.state && fake.acceptedCount == firstAccepted && firstAccepted >= 1
              && fake.objects.keys.contains("project:" + project.id.uuidString) && fake.objects.keys.contains { $0.hasPrefix("link:") }
              && sync.state.migrated != nil, "\(fake.acceptedCount) \(firstAccepted)")

        // Outbox: a change is a line at once; after a "crash" (a new sync object on the same folder) it's flushed once.
        store.rename(project: project.id, to: "Spring campaign")
        let lines = sync.outbox().count
        let reloaded = DeliverSync(store: store, publish: publish)
        reloaded.manual = true
        let publishesBefore = fake.publishes
        await reloaded.round()
        await reloaded.round()
        let hostName = (fake.objects["project:" + project.id.uuidString]?.wire["name"] as? String) ?? ""
        check("round3: outbox survives a crash and flushes once", lines == 1 && reloaded.outbox().isEmpty && fake.publishes == publishesBefore + 1
              && hostName == "Spring campaign" && reloaded.footer?.hasPrefix(String(localized: "Synced with")) == true, "\(lines) \(fake.publishes - publishesBefore) \(hostName)")

        // An asset edit's outbox line carries the edit (it's made after the store has it), so the NAS takes it.
        if let hero {
            let revBefore = (fake.objects["asset:" + hero.id.uuidString]?.wire["rev"] as? Int) ?? 0
            store.rename(asset: hero.id, to: "Hero 30s cut")
            await reloaded.round()
            let wire = fake.objects["asset:" + hero.id.uuidString]?.wire ?? [:]
            check("round3: an asset edit reaches the NAS with its new rev", wire["name"] as? String == "Hero 30s cut" && (wire["rev"] as? Int ?? 0) > revBefore,
                  "\(wire["name"] ?? "") \(wire["rev"] ?? "")")
            store.rename(asset: hero.id, to: hero.name)
            await reloaded.round()
        }

        // Changes from elsewhere come back in: a new asset made on another Mac, merged by rule M.
        var other = (fake.objects["asset:" + (hero?.id.uuidString ?? "")]?.wire) ?? [:]
        other["id"] = UUID().uuidString
        other["name"] = "Teaser"
        other["rev"] = 1
        other["by"] = "another"
        fake.storeSeq += 1
        fake.objects["asset:" + (other["id"] as! String)] = (other, fake.storeSeq, false)
        await reloaded.round()
        let teaser = store.content(project.id).assets.first { $0.name == "Teaser" }
        check("round3: changes from the host merge in", teaser != nil && teaser?.current.path.hasPrefix("host:") == true, "\(store.content(project.id).assets.map(\.name))")
        await reviewFixes2(fake: fake, store: store, publish: publish, sync: reloaded, host: host, project: project.id, base: base)

        // NAS invitations (v3, k:"nas").
        let node = String(repeating: "a1", count: 32)
        let good = PrivateNetwork.Invitation(way: .reviewHost(node: node, relay: nil, expires: Date(timeIntervalSince1970: 2_000_000_000), pin: fp, lan: "192.0.2.10:8790", role: "mac"),
                                             name: "Office NAS", code: "ABCD-EFGH-JKMN")
        func link(_ json: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: json)
            return "pluck://edit-anywhere/join?i=" + data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let back = good.link.flatMap { PrivateNetwork.Invitation(link: $0.absoluteString) }
        let expired = PrivateNetwork.Invitation(link: link(["v": 3, "k": "nas", "o": node, "n": "N", "c": "ABCD-EFGH-JKMN", "e": 1_000_000, "fp": fp, "role": "mac"]))
        let wrongKind = PrivateNetwork.Invitation(link: link(["v": 3, "k": "mac", "o": node, "n": "N", "c": "ABCD-EFGH-JKMN", "e": 2_000_000_000, "fp": fp]))
        let badFP = PrivateNetwork.Invitation(link: link(["v": 3, "k": "nas", "o": node, "n": "N", "c": "ABCD-EFGH-JKMN", "e": 2_000_000_000, "fp": "AB:CD", "role": "mac"]))
        check("round3: invitation v3 round trip, expired, wrong kind, bad fp", back == good && expired?.expired == true && wrongKind == nil && badFP == nil, "\(String(describing: back))")

        // Join a Teammate's Server…: a pasted link (spaces, quotes around it) gives what clicking it gives; garbage says it can't be read.
        let pairing = DeliverPairing.shared, goodLink = good.link?.absoluteString ?? ""
        func taken(_ text: String) -> (pending: PrivateNetwork.Invitation?, unreadable: Bool, other: Bool) {
            pairing.pending = nil; pairing.unreadable = false
            let other = pairing.take(text) != nil
            defer { pairing.pending = nil; pairing.unreadable = false }
            return (pairing.pending, pairing.unreadable, other)
        }
        let clicked = taken(goodLink), pasted = taken("  \u{201C}\(goodLink)\u{201D} \n"), quoted = taken("'\(goodLink)'"), garbage = taken("hello, join my server")
        let editAnywhere = taken(PrivateNetwork.Invitation(way: .iroh(node: node, relay: nil, expires: .now.addingTimeInterval(900)), name: "Mac", code: "ABCD-EFGH-JKMN").link?.absoluteString ?? "")
        check("join: a pasted link (spaces, quotes) is the clicked one; garbage says “Pluck can’t read this invitation”; an Edit Anywhere one goes to its window",
              clicked.pending == good && pasted.pending == good && quoted.pending == good && !pasted.unreadable && garbage.pending == nil && garbage.unreadable
              && editAnywhere.other && editAnywhere.pending == nil && DeliverJoinSheet.isReviewInvitation(" \(goodLink) ") && !DeliverJoinSheet.isReviewInvitation("hello"),
              "\(clicked) \(pasted) \(garbage)")

        // The apps user (568) reading a media folder: mode bits, NFS4 and POSIX ACLs (as filesystem.getacl answers, api.truenas.com v25.10).
        let ace = { (tag: String, id: Int?, perms: [String: Any], flags: [String: Any]) -> [String: Any] in ["tag": tag, "id": id as Any, "type": "ALLOW", "perms": perms, "flags": flags] }
        let nfs = { (entries: [[String: Any]]) -> [String: Any] in ["acltype": "NFS4", "uid": 0, "gid": 0, "acl": entries] }
        let owner = ace("owner@", nil, ["BASIC": "FULL_CONTROL"], ["BASIC": "INHERIT"])
        let fixed = nfs([owner, ace("USER", 568, ["BASIC": "READ"], ["BASIC": "INHERIT"])])
        let noInherit = nfs([owner, ace("USER", 568, ["BASIC": "READ"], ["BASIC": "NOINHERIT"])])
        let advanced = nfs([ace("GROUP", 568, ["READ_DATA": true, "EXECUTE": true], ["DIRECTORY_INHERIT": true, "FILE_INHERIT": true])])
        let traverse = nfs([ace("everyone@", nil, ["BASIC": "TRAVERSE"], ["BASIC": "INHERIT"])])
        let posix: [String: Any] = ["acltype": "POSIX1E", "uid": 0, "gid": 0, "acl": [
            ["tag": "USER_OBJ", "perms": ["READ": true, "WRITE": true, "EXECUTE": true], "default": false],
            ["tag": "USER", "id": 568, "perms": ["READ": true, "WRITE": false, "EXECUTE": true], "default": false],
            ["tag": "MASK", "perms": ["READ": false, "WRITE": false, "EXECUTE": true], "default": false]]]
        check("readable: mode bits; an ACL entry for apps with Read and Inherit; no apps entry, no inherit on a dataset, traverse only or masked are not",
              TrueNASClient.modeReadable(0o40755, uid: 0, gid: 0) && !TrueNASClient.modeReadable(0o40750, uid: 0, gid: 0) && TrueNASClient.modeReadable(0o40750, uid: 0, gid: 568)
              && TrueNASClient.aclReadable(fixed, mode: 0o40770, inherit: true) && !TrueNASClient.aclReadable(nfs([owner]), mode: 0o40770, inherit: true)
              && !TrueNASClient.aclReadable(noInherit, mode: 0, inherit: true) && TrueNASClient.aclReadable(noInherit, mode: 0, inherit: false)
              && TrueNASClient.aclReadable(advanced, mode: 0, inherit: true) && !TrueNASClient.aclReadable(traverse, mode: 0, inherit: false)
              && !TrueNASClient.aclReadable(posix, mode: 0, inherit: false), "")

        // Pairing pins the fingerprint: a different certificate never sees the code.
        ReviewHostTunnel.tunnelStart = { _ in ("127.0.0.1:5555", String(repeating: "b2", count: 32)) }
        ReviewHostClient.fakeFingerprint = Array(repeating: "CD", count: 32).joined(separator: ":")
        let refused = (try? await ReviewHostClient.pair(good, publish: publish)) == nil && fake.paired.isEmpty
        ReviewHostClient.fakeFingerprint = fp
        let pairedHost = try? await ReviewHostClient.pair(good, publish: publish)
        check("round3: pairing checks the fingerprint before the code, then keeps a device key", refused && fake.paired == ["ABCD-EFGH-JKMN"]
              && pairedHost?.device == "D1" && pairedHost.flatMap(ReviewHostClient.deviceKey) != nil && pairedHost?.node == node, "\(fake.paired)")

        // Pairing learns the host's id: this Mac's iroh key (the node the host allowed) moves with it.
        let before = UUID(), after = UUID(), keys = DeliverStore.shared.root.appendingPathComponent("iroh", isDirectory: true)
        try? FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
        try? Data("node-key".utf8).write(to: keys.appendingPathComponent("\(before.uuidString).key"))
        ReviewHostTunnel.moved(from: before, to: after)
        check("round3: the iroh key follows the paired host's id", (try? Data(contentsOf: keys.appendingPathComponent("\(after.uuidString).key"))) == Data("node-key".utf8)
              && !FileManager.default.fileExists(atPath: keys.appendingPathComponent("\(before.uuidString).key").path), "")
        try? FileManager.default.removeItem(at: keys.appendingPathComponent("\(after.uuidString).key"))

        // The route: LAN when it answers within 1.5 s, else the host's own iroh tunnel.
        var nasHost = host
        nasHost.node = node
        ReviewHostTunnel.forget(nasHost.id)
        ReviewHostTunnel.lanProbe = { _, _ in false }
        let viaIroh = try? await ReviewHostTunnel.route(nasHost)
        ReviewHostTunnel.forget(nasHost.id)
        ReviewHostTunnel.lanProbe = { _, timeout in timeout <= 1.5 }
        let viaLAN = try? await ReviewHostTunnel.route(nasHost)
        ReviewHostTunnel.forget(nasHost.id)
        ReviewHostTunnel.lanProbe = nil
        check("round3: route choice (LAN timeout → iroh)", viaIroh?.address == "127.0.0.1:5555" && viaIroh?.via != .lan && viaLAN?.via == .lan && viaLAN?.address == "nas.test:8790",
              "\(String(describing: viaIroh)) \(String(describing: viaLAN))")

        // Uploads to the uploads root: resumed from `have` after an offset answer.
        let big = base.appendingPathComponent("Hero 30s v4.mov")
        fm.createFile(atPath: big.path, contents: Data((0..<(DeliverUploads.partSize + 1000)).map { UInt8($0 % 251) }))
        let uploads = DeliverUploads()
        let sent = try? await uploads.upload(big, to: "renders/Spring/Hero 30s v4.mov", host: host)
        check("round3: upload in parts, resumed from have", sent == "renders/Spring/Hero 30s v4 2.mov" && fake.uploads["u1"] == (try? Data(contentsOf: big)), "\(String(describing: sent))")

        // Watched render folders.
        let parsed = ["Hero 30s_v2", "Hero30s v03", "hero-30s-V4", "Hero v2 final"].map { DeliverWatch.parse($0) }
        check("round3: watch-folder names", parsed[0]?.key == "hero30s" && parsed[0]?.number == 2 && parsed[1]?.key == "hero30s" && parsed[1]?.number == 3
              && parsed[2]?.key == "hero30s" && parsed[2]?.number == 4 && parsed[3] == nil
              && !DeliverWatch.candidate("Hero 30s_v5.mov.part", size: 5_000_000) && !DeliverWatch.candidate(".Hero_v5.mov", size: 5_000_000)
              && !DeliverWatch.candidate("Hero_v5.mov", size: 10), "\(parsed.map { "\(String(describing: $0))" })")
        let watcher = DeliverWatch(store: store)
        var offered: [(String, String)] = []
        watcher.posted = { _, title, body in offered.append((title, body)) }
        let watch = DeliverWatch.Watch(project: project.id, local: base.path)
        watcher.add(watch)
        let file = (path: base.appendingPathComponent("hero-30s-V4.mov").path, name: "hero-30s-V4.mov", size: Int64(5_000_000), modified: t0)
        let partial = (path: base.appendingPathComponent("Hero 30s_v5.mov.part").path, name: "Hero 30s_v5.mov.part", size: Int64(5_000_000), modified: t0)
        watcher.consider([file, partial], watch: watch, now: t0)
        let afterOne = offered.count
        watcher.consider([file, partial], watch: watch, now: t0.addingTimeInterval(11))
        watcher.consider([file], watch: watch, now: t0.addingTimeInterval(30))
        check("round3: a stable render is offered once (two checks 10 s apart), .part ignored", afterOne == 0 && offered.count == 1
              && offered.first?.0 == String(localized: "New version of Hero 30s_v1") && offered.first?.1 == String(localized: "v4 is ready. Share it with the client?")
              && watcher.found.first?.number == 4, "\(offered)")

        // Resolve markers against a fake bridge.
        let probe = Deliver.Probe(duration: 4, fpsNum: 25, fpsDen: 1, width: 1920, height: 1080, startTimecode: "00:00:00:00", dropFrame: false, hasAudio: true, frames: 100)
        let asset = Deliver.Asset(name: "Hero", kind: .video, versions: [.init(number: 1, path: "/x", size: 1, probe: probe)])
        var c1 = Deliver.Comment(asset: asset.id, version: asset.current.id, frame: 10, text: "Logo early", author: "Client")
        c1.replies = [.init(text: "Moved", author: "Editor")]
        let c2 = Deliver.Comment(asset: asset.id, version: asset.current.id, frame: 20, endFrame: 29, text: "Warm", author: "Producer")
        var done = Deliver.Comment(asset: asset.id, version: asset.current.id, frame: 30, text: "Fixed", author: "Client")
        done.completed = true
        let general = Deliver.Comment(asset: asset.id, version: asset.current.id, frame: nil, text: "All good", author: "Client")
        var rate = 25.0, added: [[String: Any]] = []
        DeliverResolveMarkers.bridge = { instruction in
            if instruction["action"] as? String == "timelineInfo" {
                return ["timeline": "Hero edit", "rate": rate, "start": 0, "end": Int(100 * rate / 25), "markers": [["frame": Int(10 * rate / 25), "data": "other"]]]
            }
            added = instruction["markers"] as? [[String: Any]] ?? []
            return ["added": added.count, "moved": [String](), "skipped": [String]()]
        }
        let same = try? await DeliverResolveMarkers.send(asset, asset.current, comments: [c1, c2, done, general], openOnly: true, includeInternal: false) { _ in true }
        let at25 = added
        rate = 50
        _ = try? await DeliverResolveMarkers.send(asset, asset.current, comments: [c1, c2, done, general], openOnly: true, includeInternal: false) { _ in true }
        let at50 = added
        let note = at25.first?["note"] as? String
        check("round3: Resolve markers (25 → 25, 25 → 50, range, occupied frame)", same?.added == 2 && same?.timeline == "Hero edit"
              && at25.map { $0["frame"] as? Int } == [11, 20] && at25.map { $0["duration"] as? Int } == [1, 10] && same?.moved.count == 1
              && at50.map { $0["frame"] as? Int } == [21, 40] && at50.map { $0["duration"] as? Int } == [2, 20]
              && at25.first?["color"] as? String == "Red" && at25.first?["name"] as? String == "Client: Logo early"
              && note == "Logo early\n— Editor: Moved" && at25.first?["data"] as? String == "pluck:\(c1.id.uuidString)", "\(at25) \(at50)")

        // Sending again removes only this asset's (and deleted comments') Pluck markers, not another asset's.
        let otherAsset = UUID(), otherComment = UUID(), gone = UUID(), oldVersion = UUID()
        var removed: [String] = []
        DeliverResolveMarkers.bridge = { instruction in
            if instruction["action"] as? String == "timelineInfo" {
                return ["timeline": "Hero edit", "rate": 25.0, "start": 0, "end": 100,
                        "markers": [["frame": 50, "data": "pluck:\(otherComment.uuidString)"], ["frame": 60, "data": "pluck:\(gone.uuidString)"],
                                    ["frame": 70, "data": "pluck:\(oldVersion.uuidString)"], ["frame": 80, "data": "pluck:\(c1.id.uuidString)"]]]
            }
            removed = instruction["remove"] as? [String] ?? []
            return ["added": 0]
        }
        _ = try? await DeliverResolveMarkers.send(asset, asset.current, comments: [c1, c2], openOnly: true, includeInternal: false,
                                                  owner: { $0 == otherComment ? otherAsset : $0 == oldVersion ? asset.id : nil }) { _ in true }
        check("fixes2: Resolve markers of another asset stay", Set(removed) == Set(["pluck:\(gone.uuidString)", "pluck:\(oldVersion.uuidString)", "pluck:\(c1.id.uuidString)"]), "\(removed)")

        // The message.
        let message = DeliverMessage.render("en", title: "Spring – cuts", link: "https://pluck.tools/r/x#k", password: true, deadline: nil, expires: nil, recipient: nil)
        let german = DeliverMessage.render("de", title: "T", link: "L", password: false, deadline: t0, expires: nil, recipient: "Anna", zone: TimeZone(identifier: "Europe/Brussels")!)
        check("round3: message (no password, empty lines dropped, 10 languages)", message.hasPrefix("Hi,\nHere is \"Spring – cuts\" for review: https://pluck.tools/r/x#k\nThe password follows in a separate message.\nYou can")
              && !message.contains("\n\n") && !message.contains("secret") && german.contains("Guten Tag Anna,") && german.contains("Bitte senden Sie Ihr Feedback bis")
              && DeliverMessage.languages.count == 10 && DeliverMessage.languages.allSatisfy { DeliverMessage.defaults[$0]?.template.contains("{link}") == true }, message + "\n" + german)

        // Browse › This Mac: its own last folder, never a temp or cache folder (else home).
        let browseKey = DeliverBrowseView.lastFolderKey, savedBrowse = UserDefaults.standard.string(forKey: browseKey)
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-keyframe-export-test", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        UserDefaults.standard.set(tempFolder.path, forKey: browseKey)
        let fromTemp = DeliverBrowseView.localStart()
        let movies = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
        try? FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
        UserDefaults.standard.set(movies.path, forKey: browseKey)
        let fromMovies = DeliverBrowseView.localStart()
        UserDefaults.standard.set(savedBrowse, forKey: browseKey)
        try? FileManager.default.removeItem(at: tempFolder)
        check("round3: Browse › This Mac opens where it was left, never in a temp folder", fromTemp == FileManager.default.homeDirectoryForCurrentUser
              && fromMovies.path == movies.path, "\(fromTemp.path) \(fromMovies.path)")

        // Links show only under their own project, and only while it's open (no global Shared Links list).
        if let first = try? store.newProject("Links A"), let second = try? store.newProject("Links B"),
           let made = try? store.newLink(scope: .project(first.id), title: "A cut") {
            let underA = DeliverSidebar.links(of: first.id, store: store, selection: .project(first.id, folder: nil)).map(\.id)
            let onLinks = DeliverSidebar.links(of: first.id, store: store, selection: .links(first.id, link: made.id)).map(\.id)
            let underB = DeliverSidebar.links(of: second.id, store: store, selection: .project(second.id, folder: nil))
            let closed = DeliverSidebar.links(of: first.id, store: store, selection: .projects) + DeliverSidebar.links(of: first.id, store: store, selection: .inbox)
            check("round3: a project's links show under it only while it's open", underA == [made.id] && onLinks == [made.id] && underB.isEmpty && closed.isEmpty,
                  "\(underA) \(underB.count) \(closed.count)")
            store.deleteProject(first.id); store.deleteProject(second.id)
        }

        // The approval proof.
        if let hero = store.find(hero?.id ?? UUID())?.asset {
            store.update(version: hero.current.id, of: hero.id) { $0.sha256 = String(repeating: "ab", count: 32) }
            if let approval = try? store.approve(asset: hero.id, version: hero.current.id, decision: .approve, author: "Anna", email: "anna@example.com"),
               let data = DeliverProof.make(approval, store: store, servedBy: "Studio Mac", generated: t0) {
                let fields = DeliverProof.fields(approval, store: store, servedBy: "Studio Mac", generated: t0)
                let record = DeliverProof.record(fields)
                let text = PDFDocument(data: data)?.string ?? ""
                check("round3: proof PDF opens and carries the record hash", PDFDocument(data: data)?.pageCount == 1 && text.contains(record) && text.contains("Approval")
                      && text.contains("anna@example.com") && record.count == 43, "\(record) \(text.prefix(200))")
            } else { check("round3: proof PDF", false, "") }
        }
        // The same record as the host's proof.rs test vector, so a PDF from either server checks the same way.
        let vector: [(key: String, label: String, value: String)] = [("project", "Spring"), ("asset", "Hero 30s"), ("version", "v3"), ("file", "Hero 30s v3.mov"),
            ("sha256", String(repeating: "ab", count: 32)), ("hashOf", "original"), ("decision", "Approved"), ("name", "Anna"), ("email", "anna@example.com"),
            ("time", "2026-11-16T10:00:00Z"), ("linkTitle", "Spring – cuts"), ("link", "L1"), ("approval", "AP1"), ("servedBy", "Office NAS"),
            ("generated", "2026-11-16T10:05:00Z")].map { (key: $0.0, label: "", value: $0.1) }
        check("round3: proof record matches the host's", DeliverProof.record(vector) == "3zAxWNkwTPPJGJbnroL-p9NIsaUvWaTcgANzF8WEuS8", DeliverProof.record(vector))

        // Approving through a link answers with the approval; its proof is fetched by id alone; `asset` lists approvals.
        let proofServer = DeliverServer(store: store)
        var proofOut: [[String: Any]] = []
        proofServer.output = { proofOut.append($0) }
        func said(_ peer: String) -> [[String: Any]] { proofOut.compactMap { ($0["send"] as? [String: Any]).flatMap { $0["peer"] as? String == peer ? $0["msg"] as? [String: Any] : nil } } }
        var askID = 500
        func askProof(_ peer: String, _ body: [String: Any]) -> [String: Any] {
            askID += 1
            proofOut = []
            proofServer.helper(["msg": ["peer": peer, "msg": body.merging(["id": askID]) { $1 }]])
            return said(peer).first { $0["re"] as? Int == askID } ?? [:]
        }
        if let approving = try? store.newLink(scope: .project(project.id), title: "Approve"), let key = store.key(approving.id),
           let heroNow = store.content(project.id).assets.first(where: { $0.name == "Hero 30s_v1" }) {
            proofServer.helper(["peer": ["peer": "p_a", "room": approving.roomID, "state": "open", "fpLocal": fp, "fpRemote": fp]])
            let macNonce = (said("p_a").first?["nonce"] as? String).flatMap(DeliverKeys.data(base64url:)) ?? Data()
            let nonce = DeliverKeys.random(32)
            let proof = DeliverKeys.proof(authKey: DeliverKeys.authKey(key), role: "browser", macNonce: macNonce, browserNonce: nonce, fpMac: fp, fpBrowser: fp)
            _ = askProof("p_a", ["t": "auth", "v": store.level(approving.id) ?? 0, "nonce": DeliverKeys.base64url(nonce), "proof": proof, "token": DeliverKeys.base64url(DeliverKeys.random(32)), "name": "Anna"])
            let version = heroNow.versions[0]
            store.update(version: version.id, of: heroNow.id) { $0.sha256 = String(repeating: "cd", count: 32) }
            let approved = askProof("p_a", ["t": "approve", "asset": heroNow.id.uuidString, "version": version.id.uuidString, "decision": "approve"])
            let approvalID = (approved["approval"] as? [String: Any])?["id"] as? String ?? ""
            let fetched = askProof("p_a", ["t": "fetch", "what": "proof", "approval": approvalID])
            let listed = askProof("p_a", ["t": "asset", "asset": heroNow.id.uuidString])
            check("round3: approve answers with the approval, the proof fetches by id, asset lists approvals",
                  (approved["approval"] as? [String: Any])?["proof"] as? Bool == true && fetched["type"] as? String == "application/pdf"
                  && (fetched["name"] as? String)?.hasPrefix("Approval – Hero 30s_v1 v1") == true
                  && (listed["approvals"] as? [[String: Any]])?.contains { $0["id"] as? String == approvalID } == true, "\(approved) \(fetched)")
        }

        // Deadlines: closed at T on the server's clock; reminders once at T−3 d, T−1 d and at close.
        let server = DeliverServer(store: store)
        var out: [[String: Any]] = []
        server.output = { out.append($0) }
        let deadline = Date.now.addingTimeInterval(10 * 86400)
        guard let dated = try? store.newLink(scope: .project(project.id), title: "Dated") else { return check("round3: deadline link", false, "") }
        store.updateLink(dated.id) { $0.deadline = deadline }
        server.clock = { deadline.addingTimeInterval(1) }
        server.helper(["peer": ["peer": "p_d", "room": dated.roomID, "state": "open", "fpLocal": fp, "fpRemote": fp]])
        out = []
        server.helper(["msg": ["peer": "p_d", "msg": ["t": "auth", "id": 1, "v": 1]]])
        let sentD = out.compactMap { ($0["send"] as? [String: Any])?["msg"] as? [String: Any] }
        let refusedAuth = sentD.first { $0["re"] as? Int == 1 }
        let deadlineAnswer = (refusedAuth?["error"] as? [String: Any])?["code"] as? String
        let byed = sentD.contains { $0["t"] as? String == "bye" && $0["code"] as? String == "deadline" }
        let reminders = DeliverDeadlines(store: store, server: server)
        var posted: [String] = []
        reminders.posted = { posted.append($0) }
        reminders.check(now: deadline.addingTimeInterval(-3 * 86400 + 3600))
        reminders.check(now: deadline.addingTimeInterval(-3 * 86400 + 7200))
        let afterThree = posted.count
        reminders.check(now: deadline.addingTimeInterval(-86400 + 3600))
        reminders.check(now: deadline.addingTimeInterval(1))
        reminders.check(now: deadline.addingTimeInterval(60))
        check("round3: deadline answers at T, reminders fire once each", deadlineAnswer == "deadline" && byed && afterThree == 1 && posted.count == 3
              && posted[0].contains(String(localized: "3 days")) && posted[1].contains(String(localized: "tomorrow")) && posted[2].contains(String(localized: "closed")),
              "\(String(describing: refusedAuth)) \(posted)")
        DeliverDeadlines.shared.reopen(dated.id, deadline: nil)

        // Protocol levels.
        let levels = [3, 2, 1, 4].map { DeliverHostUpdate.compatibility(host: $0, pluck: 3) }
        check("round3: protocol compatibility table", levels == [.fine, .older, .refused, .readOnly], "\(levels)")

        // TrueNAS against a fake JSON-RPC server.
        var calls: [String] = [], made: [String] = [], failNew = true
        TrueNASClient.fake = { (method: String, params: [Any]) -> [String: Any] in
            calls.append(method)
            var result: Any = NSNull()
            switch method {
            case "auth.login_with_api_key": result = (params.first as? String) == "good-key"
            case "system.version": result = "TrueNAS-SCALE-25.10.0"
            case "pool.dataset.query": result = [Any]()
            case "pool.dataset.create":
                let name = ((params.first as? [String: Any])?["name"] as? String) ?? ""
                made.append(name)
                result = [String: Any]()
            case "app.query":
                let running: [[String: Any]] = [["name": "pluck-review", "state": "RUNNING"]]
                result = made.contains("app") ? running as Any : [Any]() as Any
            case "app.create": made.append("app"); result = 41
            case "app.update":
                let compose = ((params.last as? [String: Any])?["custom_compose_config_string"] as? String) ?? ""
                if compose == "new", failNew { return ["error": ["message": "pull failed"] as [String: Any]] }
                result = 42
            default: break
            }
            return ["result": result]
        }
        let nas = TrueNASClient(address: "192.0.2.10", pin: fp)
        var trueNASOK = true
        do {
            try await nas.connect()
            try await nas.login("good-key")
            _ = try await nas.checkVersion()
            try await nas.ensureDataset("tank/apps/pluck-review")
            try await nas.deploy("compose")
            try await nas.waitRunning(poll: .milliseconds(1))
        } catch { trueNASOK = false }
        let wrongKey = (try? await nas.login("bad")) == nil
        let rolled = await nas.update(to: "new", previous: "old", poll: .milliseconds(1)) { true }
        failNew = false
        let updated = await nas.update(to: "new", previous: "old", poll: .milliseconds(1)) { true }
        // auth.me's roles as TrueNAS sends them: a Python set in its JSON ({"$set": [...]}), or a plain list.
        let allRoles = TrueNASClient.roles
        check("round3: TrueNAS roles as {\"$set\": …} are read",
              TrueNASClient.roleList(["$set": allRoles]) == Set(allRoles) && TrueNASClient.roleList(allRoles) == Set(allRoles)
              && TrueNASClient.roleList(["x": 1]) == nil)
        check("round3: TrueNAS pools come from the top-level datasets (no POOL_READ needed)",
              TrueNASClient.pools(in: ["tank", "tank/apps", "boot-pool", "tank/media/2026"]) == ["boot-pool", "tank"])
        let old = TrueNASClient.parse("24.10.2").map { ($0.major, $0.minor) >= (25, 4) }
        let template = "services:\n  a:\n    image: \"{{image}}\"\n    env: \"{{name}}\"\n    # begin:uploads\n    up: \"{{uploads}}\"\n    # end:uploads\n"
        let rendered = try? TrueNASClient.render(template, ["image": "ghcr.io/x/y@sha256:" + String(repeating: "0", count: 64), "name": "Say \"hi\""])
        let newline = (try? TrueNASClient.render(template, ["image": "a\nb", "name": "x"])) == nil
        check("round3: TrueNAS client (login, dataset, app.create job wait, rollback, template)", trueNASOK && wrongKey && made == ["tank/apps/pluck-review", "app"]
              && calls.contains("core.job_wait") && rolled == .rolledBack && updated == .ok && old == false
              && rendered?.contains("env: \"Say \\\"hi\\\"\"") == true && rendered?.contains("up:") == false && newline, "\(calls) \(String(describing: rendered))")

        // host-release.json's signature.
        let signing = Curve25519.Signing.PrivateKey()
        let json = Data(#"{"version":"v1.0.0","protocol":3,"image":"ghcr.io/x/pluck-review-host@sha256:abc","assets":{"pluck-proxmox.sh":"00"}}"#.utf8)
        let signature = (try? signing.signature(for: json))?.base64EncodedString() ?? ""
        let goodRelease = DeliverHostUpdate.verify(json, signature: signature, key: signing.publicKey)
        let tampered = DeliverHostUpdate.verify(json + Data(" ".utf8), signature: signature, key: signing.publicKey)
        let missing = DeliverHostUpdate.verify(json, signature: "", key: signing.publicKey)
        let otherKey = DeliverHostUpdate.verify(json, signature: signature, key: Curve25519.Signing.PrivateKey().publicKey)
        check("round3: host-release.json signature (good, bad, missing, other key)", goodRelease?.level == 3 && tampered == nil && missing == nil && otherKey == nil
              && DeliverHostUpdate.verify(json, signature: signature, key: nil) == nil, "")
        check("round3: host updates only go forward", DeliverHostUpdate.isUpgrade(from: "0.3.0", to: "v0.3.1") && DeliverHostUpdate.isUpgrade(from: nil, to: "0.3.0")
              && !DeliverHostUpdate.isUpgrade(from: "0.10.0", to: "0.9.0") && !DeliverHostUpdate.isUpgrade(from: "v0.3.0", to: "0.3.0"), "")
        let command = DeliverBackup.command(tag: "v1.0.0", sha256: String(repeating: "a", count: 64), storage: "local-lvm", size: 58, quality: "1080-low", cores: 2,
                                            memory: 2048, bridge: "vmbr0", name: "pluck-backup", ip: nil, link: "pluck://edit-anywhere/join?i=abc_-")
        check("round3: Proxmox command (hash checked before it runs, values validated)", command?.contains("sha256sum -c -") == true && command?.contains("--size 58") == true
              && command?.contains("--pair 'pluck://edit-anywhere/join?i=abc_-'") == true && command?.contains("| bash") == false
              && DeliverBackup.command(tag: "v1.0.0", sha256: "x", storage: "local-lvm", size: 58, quality: "1080-low", cores: 2, memory: 2048, bridge: "vmbr0", name: "pluck-backup", ip: nil, link: "pluck://edit-anywhere/join?i=a") == nil
              && DeliverBackup.command(tag: "v1.0.0", sha256: String(repeating: "a", count: 64), storage: "local-lvm", size: 58, quality: "1080-low", cores: 2, memory: 2048, bridge: "vmbr0", name: "Bad Name", ip: nil, link: "pluck://edit-anywhere/join?i=a") == nil
              && DeliverBackup.hours(50, quality: "1080-low").map { Int($0) } == 36 && DeliverBackup.hours(50, quality: "same") == nil, command ?? "")
        // Either platform in either role: Proxmox as the main host (media mounts, no link), TrueNAS as a backup (its own app and ports).
        let sha = String(repeating: "a", count: 64)
        let mainCommand = DeliverBackup.command(tag: "v1.0.0", sha256: sha, storage: "local-lvm", size: 50, quality: "1080-low", cores: 2, memory: 2048,
                                                bridge: "vmbr0", name: "pluck-review", ip: nil, media: ["/tank/media", "/tank/b-roll"], link: nil)
        let mainBad = ["relative", "/a b", "/a,ro=0", "/tank/../etc", "/x'y"].allSatisfy {
            DeliverBackup.command(tag: "v1.0.0", sha256: sha, storage: "local-lvm", size: 50, quality: "1080-low", cores: 2, memory: 2048,
                                  bridge: "vmbr0", name: "pluck-review", ip: nil, media: [$0], link: nil) == nil }
        let noMedia = DeliverBackup.command(tag: "v1.0.0", sha256: sha, storage: "local-lvm", size: 50, quality: "1080-low", cores: 2, memory: 2048,
                                            bridge: "vmbr0", name: "pluck-review", ip: nil, link: nil) == nil
        let both = DeliverBackup.command(tag: "v1.0.0", sha256: sha, storage: "local-lvm", size: 50, quality: "1080-low", cores: 2, memory: 2048,
                                         bridge: "vmbr0", name: "pluck-review", ip: nil, media: ["/tank/media"], link: "pluck://edit-anywhere/join?i=a") == nil
        let fpLine = Array(repeating: "AB", count: 32).joined(separator: ":")
        let keyLine = DeliverKeys.base64url(Data(repeating: 9, count: 32))
        let line = DeliverBackup.hostLine("192.0.2.50:8790 pluck-host:\(keyLine)@\(fpLine)\n")
        let truenasBackup = TrueNASSetup()
        truenasBackup.role = .backup
        truenasBackup.mainLink = "pluck://edit-anywhere/join?i=a"
        truenasBackup.quality = "same"
        let backupValues = truenasBackup.values(hostKey: "k").values
        let mainWithMedia = TrueNASSetup()
        mainWithMedia.media = [(dataset: "tank/media", id: "nas1")]
        check("roles: a TrueNAS backup (or a main without media) mounts no media, never its data dataset",
              !truenasBackup.values(hostKey: "k").blocks.contains("media1") && !TrueNASSetup().values(hostKey: "k").blocks.contains("media1")
              && mainWithMedia.values(hostKey: "k").blocks.contains("media1") && mainWithMedia.values(hostKey: "k").values["media1"] == "/mnt/tank/media", "")
        let mainValues = TrueNASSetup().values(hostKey: "k").values
        check("roles: Proxmox main command, its pairing line, TrueNAS backup values",
              mainCommand?.contains("--role host ") == true && mainCommand?.contains("--media '/tank/media' --media '/tank/b-roll'") == true
              && mainCommand?.contains("--pair") == false && mainCommand?.contains("--quality") == false && command?.contains("--role") == false
              && mainBad && noMedia && both
              && DeliverBackup.ipOK("192.0.2.50/24,gw=192.0.2.1") && !DeliverBackup.ipOK("192.0.2.50/24") && !DeliverBackup.ipOK("192.0.2.50")
              && DeliverBackup.command(tag: "v1.0.0", sha256: sha, storage: "local-lvm", size: 50, quality: "1080-low", cores: 2, memory: 2048,
                                       bridge: "vmbr0", name: "pluck-review", ip: "192.0.2.50/24", media: ["/tank/media"], link: nil) == nil
              && line?.address == "192.0.2.50:8790" && line.flatMap { ReviewHostClient.pairing($0.pairing)?.pin } == fpLine
              && DeliverBackup.hostLine("192.0.2.50:8790 \(keyLine)") == nil && DeliverBackup.hostLine("pluck-host:\(keyLine)@\(fpLine)") == nil
              && backupValues["role"] == "backup" && backupValues["main_link"] == "pluck://edit-anywhere/join?i=a" && backupValues["backup_quality"] == "same"
              && backupValues["backup_max"] == "50G" && backupValues["sync_port"] == "8792"
              && mainValues["role"] == "main" && mainValues["main_link"] == "" && mainValues["backup_max"] == "" && mainValues["sync_port"] == "8790",
              mainCommand ?? "")

        // Browse: a NAS's places through its Finder source, offline keeps the last listing; Share for review matches by key.
        let source = NASFinderSource(host: host)
        let top = await source.list(source.root)
        let inside = await source.list(source.root.appendingPathComponent("nas1", isDirectory: true))
        ReviewHostClient.fake = { _, _ in nil }
        let offline = await source.list(source.root.appendingPathComponent("nas1", isDirectory: true))
        ReviewHostClient.fake = { fake.answer($0, $1) }
        let places = DeliverPlaces.all(publish: publish)
        check("round3: Browse lists this Mac and the NAS, offline greys the last listing", top.map(\.1.name) == ["nas1", "renders"] && inside.count == 2
              && source.path(inside[0].0) == "nas1/Hero 30s_v2.mov" && offline.count == 2 && source.offline
              && places.first?.id == .local && places.contains { $0.id == .nas(host.id) }, "\(top.map(\.1.name)) \(places.map(\.name))")
        let items = [DeliverBrowseItem(name: "Hero 30s_v2.mov", location: .nas(host.id, "nas1/Hero 30s_v2.mov"), folder: false, size: 5_000_000),
                     DeliverBrowseItem(name: "Outro.mov", location: .local(base.appendingPathComponent("Outro.mov")), folder: false, size: 1)]
        let plan = DeliverShareForReview.plan(items, project: project.id, asVersions: true, store: store)
        check("round3: Share for review matches files to assets by key", plan[0].asset?.name == "Hero 30s_v1" && plan[1].asset == nil, "\(plan.map { $0.asset?.name ?? "-" })")
        await DeliverShareForReview.place([items[0]], into: project.id, asVersions: true, host: nil, store: store)
        let stacked = store.content(project.id).assets.first { $0.name == "Hero 30s_v1" }
        check("round3: a NAS file goes in by reference as the next version", stacked?.versions.count == 2
              && stacked?.current.path == ReviewPublish.nasPath(host: host.id, path: "nas1/Hero 30s_v2.mov"), "\(String(describing: stacked?.versions.map(\.path)))")

        await uploadDestinationTest(fake: fake, store: store, publish: publish, host: host, project: project.id, base: base)

        // A backup paired straight with the main (no host record here): a Backup row under the main, not a browse root.
        let seen = ISO8601DateFormatter().string(from: .now)
        ReviewHostClient.fake = { request, body in
            guard request["op"] as? String == "devices" else { return fake.answer(request, body) }
            return ["devices": [["id": "d-mac", "name": "Edit Mac", "role": "mac", "lastSeen": seen],
                                ["id": "d-backup", "name": "Proxmox Backup", "role": "backup", "node": String(repeating: "c3", count: 32), "lastSeen": seen,
                                 "replica": ["uplinkMbps": 940, "quality": "same", "versions": ["ready": 3, "making": 1]]],
                                ["id": "d-old", "name": "Old Backup", "role": "backup", "lastSeen": "2020-01-01T00:00:00Z"]]]
        }
        // (Every main here gets the same answer; the rows under this one.)
        let backups = await DeliverBackups.load(publish: publish).filter { $0.main.id == host.id }
        ReviewHostClient.fake = { fake.answer($0, $1) }
        let rows = DeliverBrowseView.backupPlaces(backups, show: { _ in }, remove: { _ in })
        await browseSidebarTest(publish: publish, host: host, backups: backups)
        check("backups: a main's backup is a Backup row with its speed and status", rows.count == 2 && rows[0].id == "backup:d-backup" && rows[0].title == "Proxmox Backup"
              && rows[0].detail == "Backup" && rows[0].help == "Copying · 940 Mbit/s up" && !rows[0].dimmed && rows[0].menu != nil
              && rows[1].detail == "Backup" && rows[1].dimmed && rows[1].help == "Offline",
              "\(rows.map { "\($0.id) \($0.detail ?? "-") \($0.help ?? "-")" })")

        await reviewServerRepairTest(publish: publish, host: host, fp: fp, fake: fake)
    }

    /// The owner's TrueNAS case: an install that lost its socket after app.create left the app with key A while Pluck
    /// kept none; installing again must reuse A (read with app.config), check the key really works, and Browse says why not.
    static func reviewServerRepairTest(publish: ReviewPublish, host: Deliver.Host, fp: String, fake: ReviewFakeHost) async {
        defer { ReviewHostClient.fake = { fake.answer($0, $1) }; TrueNASClient.fake = nil }
        let keyA = DeliverKeys.base64url(Data(repeating: 0xA1, count: 32))
        // app.config's result for a custom app: the compose as yaml.safe_load made it (api.truenas.com v25.10 app.config;
        // middlewared apps/ix_apps/lifecycle.py get_current_app_config), as JSON: an object, numbers where YAML had them.
        let installed: [String: Any] = [
            "services": ["pluck-review": [
                "image": "ghcr.io/x/pluck-review-host@sha256:" + String(repeating: "0", count: 64), "restart": "unless-stopped", "network_mode": "host",
                "user": "568:568", "read_only": true, "cap_drop": ["ALL"],
                "environment": ["PLUCK_HOST_KEY": keyA, "PLUCK_HOST_NAME": "Studio NAS", "PLUCK_IROH": "0", "PLUCK_ROLE": "main", "PLUCK_MAIN_LINK": "",
                                "PLUCK_BACKUP_MAX": "", "PLUCK_UPLOADS": "renders=/uploads/renders"],
                "command": ["--media", "nas1=/media/nas1", "--media", "nas2=/media/nas2", "--listen", "192.0.2.10:8790", "--admin", "192.0.2.10:8791"],
                "volumes": ["/mnt/tank/apps/pluck-review:/data", "/mnt/tank/media:/media/nas1:ro", "media2:/media/nas2:ro", "/mnt/tank/renders:/uploads/renders"],
                "pids_limit": 256, "mem_limit": "4g", "cpus": "3.0",
            ] as [String: Any]],
            "volumes": ["media2": ["driver": "local", "driver_opts": ["type": "nfs", "o": "addr=192.0.2.20,ro,nfsvers=4,soft,timeo=150", "device": ":/mnt/pool/footage"]]],
        ]
        let parsed = TrueNASClient.installed(installed)
        check("repair: app.config parses (key, data, media, uploads, second NAS, limits)", parsed?.key == keyA && parsed?.data == "tank/apps/pluck-review"
              && parsed?.media == ["tank/media"] && parsed?.mediaIDs == ["nas1"] && parsed?.uploads == "tank/renders" && parsed?.secondAddress == "192.0.2.20"
              && parsed?.secondPath == "/mnt/pool/footage" && parsed?.cpus == 3 && parsed?.memory == 4 && parsed?.iroh == false && parsed?.name == "Studio NAS"
              && parsed?.mainLink == nil, "\(String(describing: parsed))")
        // The key in other shapes: a KEY=value list, YAML text; a short or missing key isn't one.
        let listForm: [String: Any] = ["services": ["pluck-review": ["environment": ["PLUCK_IROH=1", "PLUCK_HOST_KEY=\(keyA)"]]]]
        let yaml = "services:\n  pluck-review:\n    environment:\n      PLUCK_HOST_KEY: \"\(keyA)\"   # kept\n"
        check("repair: the host key is read from a list, from YAML text, never a broken one",
              TrueNASClient.installed(listForm)?.key == keyA && TrueNASClient.installed(listForm)?.iroh == true && TrueNASClient.installed(yaml)?.key == keyA
              && TrueNASClient.installed(["services": ["pluck-review": ["environment": ["PLUCK_HOST_KEY": "short"]]]]) == nil
              && TrueNASClient.installed(["services": [String: Any]()]) == nil, "")

        // Installing over the app that's there: app.query finds it, app.config gives key A, app.update carries A.
        var exists = true, configFails = false, updated: String?
        let running: [[String: Any]] = [["name": "pluck-review", "state": "RUNNING", "custom_app": true]]
        let denied: [String: Any] = ["code": 13, "message": "Not authorized", "data": ["reason": "Not authorized"] as [String: Any]]
        TrueNASClient.fake = { (method: String, params: [Any]) -> [String: Any] in
            switch method {
            case "app.query": return ["result": exists ? running as Any : [Any]() as Any]
            case "app.config":
                if configFails { return ["error": denied] }
                if params.first as? String == "pluck-review" { return ["result": installed] }
                return ["error": ["message": "no such app"] as [String: Any]]
            case "app.update":
                updated = (params.last as? [String: Any])?["custom_compose_config_string"] as? String
                return ["result": 7]
            default: return ["result": NSNull()]
            }
        }
        let client = TrueNASClient(address: "192.0.2.10", pin: fp)
        let reused = try? await TrueNASSetup.existingKey(client)
        let setup = TrueNASSetup()
        let template = "services:\n  pluck-review:\n    environment:\n      PLUCK_HOST_KEY: \"{{host_key}}\"\n"
        if let reused, let compose = try? TrueNASClient.render(template, ["host_key": reused]) { try? await client.deploy(compose) }
        configFails = true
        var unreadable = ""
        do { _ = try await TrueNASSetup.existingKey(client) } catch { unreadable = error.localizedDescription }
        exists = false
        let fresh = try? await TrueNASSetup.existingKey(client)
        check("repair: an app already there keeps its key (app.config), app.update sends it, an unreadable one stops the install",
              reused == keyA && updated?.contains(keyA) == true && unreadable.contains("Nothing was changed") && unreadable.contains("Not authorized")
              && fresh == nil && setup.values(hostKey: keyA).values["host_key"] == keyA, "\(String(describing: reused)) \(unreadable)")

        // After install, the key is checked on the sync port: a refused key is said as such (not retried), silence is "not answering".
        ReviewHostClient.fake = { request, _ in
            if request["op"] == nil, request["key"] != nil { return ["ok": request["key"] as? String == keyA] }
            return ["ok": true]
        }
        let verifyRefused = TrueNASSetup()
        let fingerprint = await verifyRefused.verify(host, timeout: 0.2, poll: .milliseconds(10))
        let refusedProblem = verifyRefused.problem ?? ""
        let source = NASFinderSource(host: host)
        _ = await source.list(source.root)
        let browseProblem = source.problem ?? ""
        ReviewHostClient.fake = { _, _ in nil }
        let silent = TrueNASSetup()
        _ = await silent.verify(host, timeout: 0.1, poll: .milliseconds(10))
        check("repair: verify after install names a refused key; Browse says Pair Again; silence isn't answering",
              fingerprint == nil && !verifyRefused.verified && refusedProblem.contains(String(localized: "The NAS server rejected Pluck’s key"))
              && browseProblem == String(localized: "The NAS server doesn’t accept this Mac’s key: Pair Again")
              && silent.problem == String(localized: "The NAS isn’t answering")
              && ReviewHostClient.problem(Deliver.Failure("pin")).contains(String(localized: "different certificate")), "\(refusedProblem) | \(browseProblem) | \(silent.problem ?? "-")")

        // Pair Again: the Keychain key (and the pin, from the line) change; the record stays; a broken line changes nothing.
        ReviewHostClient.fake = { request, _ in
            if request["op"] == nil, request["key"] != nil { return ["ok": request["key"] as? String == keyA] }
            return ["ok": true]
        }
        let oldKey = ReviewHostClient.key(host)
        let fp2 = Array(repeating: "CD", count: 32).joined(separator: ":")
        let broken = await DeliverPairAgainSheet.pairAgain(host.id, pairing: "pluck-host:nope", publish: publish)
        let keptAfterBroken = ReviewHostClient.key(host) == oldKey
        let paired = await DeliverPairAgainSheet.pairAgain(host.id, pairing: "pluck-host:\(keyA)@\(fp2)", publish: publish)
        let after = publish.host(host.id)
        check("repair: Pair Again updates the Keychain key and pin and checks it", broken != nil && keptAfterBroken && paired == nil
              && after.flatMap(ReviewHostClient.key) == keyA && after?.pin == fp2 && after?.id == host.id, "\(String(describing: broken)) \(String(describing: paired))")
        if let oldKey { publish.repair(host.id, pairing: "pluck-host:\(oldKey)@\(fp)") }

        // 4.0.3: "Matches the Log" after Install did nothing and the same fingerprint came back. Install leaves a host with
        // no pin; its first session is Unconfirmed; confirming pins it (by id, else address; any spelling) and the next
        // session goes through without asking again. Also when the entry had a pin left from an earlier attempt.
        await reviewConfirmPinTest(publish: publish, fake: fake)

        // Several media datasets: one media1 block each in the compose (any number of --media), new ids after the highest.
        let multi = TrueNASSetup()
        multi.media = [(dataset: "tank/media", id: "nas1"), (dataset: "tank/broll", id: "nas3")]
        multi.addMedia("tank/footage")
        multi.secondAddress = "192.0.2.20"; multi.secondPath = "/mnt/pool/x"
        let blockTemplate = "services:\n  s:\n    command:\n      # begin:media1\n      - \"{{media1_id}}=/media/{{media1_id}}\"\n      # end:media1\n    volumes:\n      # begin:media1\n      - \"{{media1}}:/media/{{media1_id}}:ro\"\n      # end:media1\n      # begin:media2\n      - \"media2:/media/{{media2_id}}:ro\"\n      # end:media2\n"
        let (values, blocks) = multi.values(hostKey: "k")
        let multiCompose = try? TrueNASClient.render(TrueNASClient.moreMedia(blockTemplate, count: 2), values.filter { $0.key.hasPrefix("media") }, blocks: blocks)
        let installedBack = multiCompose.flatMap { _ in TrueNASClient.installed(["services": ["s": ["environment": ["PLUCK_HOST_KEY": DeliverKeys.base64url(Data(repeating: 3, count: 32))],
            "volumes": ["/mnt/tank/media:/media/nas1:ro", "/mnt/tank/broll:/media/nas3:ro", "/mnt/tank/footage:/media/nas4:ro", "media2:/media/nas5:ro"]]]]) }
        let overlapping = TrueNASSetup()
        overlapping.addMedia("tank/media"); overlapping.addMedia("tank/media/2025")
        check("media: several datasets each get a mount and --media, ids never reused, the second NAS after them, overlap warned",
              multi.media.map(\.id) == ["nas1", "nas3", "nas4"] && multi.secondID == "nas2"
              && multiCompose?.contains("\"/mnt/tank/broll:/media/nas3:ro\"") == true && multiCompose?.contains("\"nas4=/media/nas4\"") == true
              && multiCompose?.contains("\"/mnt/tank/media:/media/nas1:ro\"") == true && multiCompose?.contains("{{") == false
              && installedBack?.mediaIDs == ["nas1", "nas3", "nas4"] && installedBack?.secondID == "nas5"
              && overlapping.overlap != nil && TrueNASSetup().overlap == nil
              && TrueNASClient.fingerprint(inLog: ["x", #"{"host":{"listen":"0.0.0.0:8790","fingerprint":"\#(Array(repeating: "ab", count: 32).joined(separator: ":"))"}}"#]) == Array(repeating: "AB", count: 32).joined(separator: ":"),
              multiCompose ?? "nil")
    }

    static func reviewConfirmPinTest(publish: ReviewPublish, fake: ReviewFakeHost) async {
        defer { ReviewHostClient.fake = { fake.answer($0, $1) }; ReviewHostClient.fakeFingerprint = nil }
        let keyB = DeliverKeys.base64url(Data(repeating: 0xB2, count: 32))
        let served = Array(repeating: "5E", count: 31).joined(separator: ":") + ":A0", older = Array(repeating: "0F", count: 32).joined(separator: ":")
        ReviewHostClient.fakeFingerprint = served
        var hellos = 0
        ReviewHostClient.fake = { request, _ in
            if request["op"] == nil, request["key"] != nil { hellos += 1; return ["ok": request["key"] as? String == keyB, "version": "0.3.0", "protocol": 3] }
            return ["ok": true]
        }
        for earlierPin in [false, true] {
            guard let installed = publish.addNAS(name: "Fresh NAS", address: "fresh.test:8790", pairing: keyB) else { return check("confirm: install's host", false, ""); }
            let setup = TrueNASSetup()
            setup.publish = publish
            setup.done = installed
            await setup.check()
            let asked = setup.serverFingerprint
            // (An earlier attempt left a pin on the entry: the owner's confirmation for this install replaces it.)
            if earlierPin { publish.update(host: installed.id) { $0.pin = older } }
            let before = hellos
            await setup.confirmServer()
            let pinnedNow = publish.host(installed.id)?.pin
            await setup.check()
            check("confirm: Install → Unconfirmed → Matches → the session goes through, never asked again (earlier pin: \(earlierPin))",
                  asked == served && pinnedNow == served && setup.verified && setup.serverFingerprint == nil && setup.problem == nil && hellos > before,
                  "\(String(describing: asked)) \(String(describing: pinnedNow)) \(setup.problem ?? "-")")
            publish.removeHost(installed.id)
        }
        // pinned(): any spelling, by address when the id is gone, a different pin refused out loud, garbage refused.
        guard let other = publish.addNAS(name: "Other NAS", address: "other.test:8790", pairing: keyB) else { return }
        let spelled = served.lowercased().replacingOccurrences(of: ":", with: "-")
        let byAddress = publish.pinned(spelled, host: UUID(), address: "other.test:8790")
        let keptSpelling = publish.host(other.id)?.pin == served
        let refused = publish.pinned(older, host: other.id)
        let lost = publish.pinned(served, host: UUID())
        let garbage = publish.pinned("AB:CD", host: other.id)
        let stillServed = publish.host(other.id)?.pin == served
        // The same fingerprint coming back after it was confirmed is said, not asked again.
        let setup = TrueNASSetup()
        setup.publish = publish
        setup.done = other
        publish.update(host: other.id) { $0.pin = nil }
        await setup.check()
        await setup.confirmServer()
        publish.update(host: other.id) { $0.pin = nil }
        await setup.check()
        check("confirm: pins by address and any spelling; another pin, a lost host or a broken fingerprint is said; a repeat isn't asked",
              byAddress == nil && keptSpelling && refused != nil && stillServed && lost != nil && garbage != nil
              && setup.serverFingerprint == nil && setup.problem?.contains(String(localized: "The fingerprint was confirmed")) == true,
              "\(String(describing: byAddress)) kept \(keptSpelling) pin \(stillServed) lost \(lost != nil) garbage \(garbage != nil) fp \(setup.serverFingerprint ?? "-")")
        publish.removeHost(other.id)
    }
}

// MARK: - TrueNAS end to end (the stand-in TrueNAS and the real pluck-review helper; scratchpad truenas-e2e/run.sh)

extension PhotoSelfTest {
    /// Drives the TrueNAS setup as the sheet does against a stand-in TrueNAS 25.10 (wss JSON-RPC, roles, idle close,
    /// jobs) that runs the REAL helper from the compose Pluck sends; Browse then lists the helper's media roots.
    static func trueNASE2ETest() async {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["PLUCK_E2E_PORT"].flatMap(Int.init), let root = env["PLUCK_E2E_ROOT"], let apiKey = env["PLUCK_E2E_KEY"] else {
            return check("e2e: stand-in TrueNAS", false, "PLUCK_E2E_PORT/ROOT/KEY not set")
        }
        let publish = ReviewPublish.shared, nas = "127.0.0.1", sync = "127.0.0.1:8790"
        TrueNASClient.testPort = port
        TrueNASSetup.testImage = "ghcr.io/example/pluck-review-host@sha256:" + String(repeating: "0", count: 64)
        let fm = FileManager.default
        func mnt(_ dataset: String) -> URL { URL(fileURLWithPath: root).appendingPathComponent("mnt/" + dataset, isDirectory: true) }
        for (dataset, file) in [("tank/media", "Hero_v1.mov"), ("tank/broll", "Drone.mov"), ("tank/footage", "Interview.mov"), ("tank/archive", "Old.mov")] {
            try? fm.createDirectory(at: mnt(dataset), withIntermediateDirectories: true)
            fm.createFile(atPath: mnt(dataset).appendingPathComponent(file).path, contents: Data(repeating: 1, count: 1000))
        }
        func clean() { for host in publish.hosts where host.address == sync || host.name.hasPrefix("E2E") { publish.removeHost(host.id) } }
        clean()
        defer {
            clean()
            TrueNASClient.testPort = nil
            TrueNASSetup.testImage = nil
            TrueNASKeychain.forget(nas)
            UserDefaults.standard.removeObject(forKey: "truenasPin." + nas)
        }

        /// Connect as the sheet does: the API's certificate confirmed on first connect.
        func connected(_ setup: TrueNASSetup) async -> Bool {
            await setup.connect()
            note("e2e connect: fingerprint \(setup.fingerprint != nil) connected \(setup.connected) \(setup.problem ?? "-")")
            if setup.fingerprint != nil { await setup.confirm() }
            note("e2e connect after confirm: \(setup.connected) \(setup.problem ?? "-")")
            return setup.connected
        }
        func fresh() -> TrueNASSetup {
            let setup = TrueNASSetup()
            setup.address = nas
            setup.apiKey = apiKey
            setup.iroh = false
            setup.name = "E2E NAS"
            return setup
        }
        func roots(_ host: Deliver.Host) async -> (names: [String], problem: String?) {
            let source = NASFinderSource(host: publish.host(host.id) ?? host)
            let listed = await source.list(source.root)
            return (listed.map(\.1.name).sorted(), source.problem)
        }
        /// The key the running app really has (app.config), through Pluck's own client.
        func runningKey() async -> String? {
            let client = TrueNASClient(address: nas, pin: TrueNASKeychain.pin(nas))
            defer { client.close() }
            guard (try? await client.connect()) != nil, (try? await client.login(apiKey)) != nil else { return nil }
            return (try? await client.config()).flatMap(TrueNASClient.installed)?.key
        }
        func standIn(_ method: String, _ params: [Any]) async {
            let client = TrueNASClient(address: nas, pin: TrueNASKeychain.pin(nas))
            defer { client.close() }
            _ = try? await client.connect()
            _ = try? await client.login(apiKey)
            _ = try? await client.call(method, params)
        }

        // (a) A clean install with three media datasets; an overlapping fourth is warned about.
        let a = fresh()
        let connectedA = await connected(a)
        for dataset in ["tank/media", "tank/broll", "tank/footage", "tank/media/2025"] { a.addMedia(dataset) }
        let overlap = a.overlap
        // Media access as the app (568) has it: broll's ACL leaves the apps user out, and so does a folder inside footage;
        // after the owner's fix (apps: Read, Inherit, recursively) Check Again shows them readable.
        try? fm.createDirectory(at: mnt("tank/footage").appendingPathComponent("Day 1", isDirectory: true), withIntermediateDirectories: true)
        await standIn("standin.acl", ["/mnt/tank/broll", "locked"])
        await standIn("standin.acl", ["/mnt/tank/footage/Day 1", "locked"])
        await a.checkAccess()
        let accessBefore = a.access
        await standIn("standin.acl", ["/mnt/tank/broll", "fixed"])
        await standIn("standin.acl", ["/mnt/tank/footage/Day 1", "fixed"])
        await a.checkAccess()
        let accessAfter = a.access
        check("e2e (a): media access: one readable, one dataset and one subfolder whose ACL leaves out apps; Check Again after the fix",
              accessBefore == ["tank/media": true, "tank/broll": false, "tank/footage": false, "tank/media/2025": true]
              && accessAfter == ["tank/media": true, "tank/broll": true, "tank/footage": true, "tank/media/2025": true],
              "\(accessBefore) \(accessAfter) \(a.problem ?? "-")")
        a.media.removeAll { $0.dataset == "tank/media/2025" }
        // The form takes a while: the stand-in closes a socket idle for 20 s, as the owner's NAS did; Install reconnects.
        try? await Task.sleep(for: .seconds(23))
        note("e2e (a) installing")
        await a.install()
        let installProblem = a.problem
        note("e2e (a) installed: \(installProblem ?? "-")")
        await a.check()
        guard let hostA = a.done.flatMap({ publish.host($0.id) }) else { return check("e2e (a): clean install", false, "\(installProblem ?? "-") \(a.problem ?? "-")") }
        let listedA = await roots(hostA)
        check("e2e (a): clean install: connect, 3 media, 23 s idle (socket closed), install, fingerprint from the app's log, Browse lists the helper's roots by their dataset names",
              connectedA && overlap != nil && installProblem == nil && a.verified && a.serverFingerprint == nil && hostA.pin != nil
              && listedA.names == ["broll", "footage", "media"] && listedA.problem == nil && a.media.map(\.id) == ["nas1", "nas2", "nas3"],
              "\(connectedA) \(installProblem ?? "-") \(a.problem ?? "-") \(listedA)")
        let keyA = ReviewHostClient.key(hostA)
        let pinA = hostA.pin

        // (c) The app is already there with key A (Pluck forgot it): Install reuses A, never a new key.
        publish.removeHost(hostA.id)
        let c = fresh()
        _ = await connected(c)
        for dataset in ["tank/media", "tank/broll", "tank/footage"] { c.addMedia(dataset) }
        await c.install()
        await c.check()
        let hostC = c.done.flatMap { publish.host($0.id) }
        let runningC = await runningKey()
        check("e2e (c): an app already there with key A: Install reuses A and pairs", c.problem == nil && c.verified && hostC.flatMap(ReviewHostClient.key) == keyA
              && runningC == keyA && keyA != nil, "\(c.problem ?? "-") same \(hostC.flatMap(ReviewHostClient.key) == keyA) running \(runningC == keyA)")

        // (b) The socket drops while app.create's job runs (the app is made anyway): Install fails, Install again pairs
        // with the key the running app really has.
        if let hostC { publish.removeHost(hostC.id) }
        await standIn("standin.delete", ["pluck-review"])
        await standIn("standin.scenario", ["drop_next_create"])
        let b = fresh()
        _ = await connected(b)
        for dataset in ["tank/media", "tank/broll", "tank/footage"] { b.addMedia(dataset) }
        await b.install()
        let firstFailed = b.problem != nil && b.done == nil
        try? await Task.sleep(for: .seconds(4)) // the job finishes on the NAS without Pluck
        await b.install()
        await b.check()
        let hostB = b.done.flatMap { publish.host($0.id) }
        let runningB = await runningKey()
        var listedB: (names: [String], problem: String?) = ([], "no host")
        if let hostB { listedB = await roots(hostB) }
        check("e2e (b): socket closed during app.create: the first Install fails, the second pairs with the running app's key",
              firstFailed && b.problem == nil && b.verified && runningB != nil && hostB.flatMap(ReviewHostClient.key) == runningB && listedB.problem == nil,
              "first \(firstFailed) \(b.problem ?? "-") running \(runningB != nil) same \(hostB.flatMap(ReviewHostClient.key) == runningB) \(listedB)")
        guard let host = hostB else { return }

        // (d) The entry left with an old pin: confirming the fingerprint replaces it (the manual step, no API log).
        let d = TrueNASSetup()
        d.done = host
        publish.update(host: host.id) { $0.pin = nil }
        await d.check()
        let asked = d.serverFingerprint
        publish.update(host: host.id) { $0.pin = Array(repeating: "00", count: 32).joined(separator: ":") }
        await d.confirmServer()
        let listedD = await roots(host)
        check("e2e (d): an entry with an old pin: Matches replaces it and the session goes through",
              asked != nil && d.verified && d.problem == nil && publish.host(host.id)?.pin == asked.flatMap(HostSession.normalized) && listedD.problem == nil
              && (pinA == nil || publish.host(host.id)?.pin == pinA), "\(String(describing: asked)) \(d.problem ?? "-") \(listedD)")

        // (e) Change Folders: the API key from the Keychain, the app read back, one dataset out and one in; the helper restarts with them.
        TrueNASKeychain.save(apiKey, for: nas)
        let keyBefore = ReviewHostClient.key(host)
        let e = TrueNASSetup(editing: publish.host(host.id) ?? host)
        let connectedE = await connected(e)
        let read = e.media.map(\.dataset)
        e.media.removeAll { $0.dataset == "tank/broll" }
        e.addMedia("tank/archive")
        await e.install()
        await e.check()
        let listedE = await roots(host)
        check("e2e (e): Change Folders reads the app, removes and adds media; the helper restarts with them; key and record stay",
              connectedE && read == ["tank/media", "tank/broll", "tank/footage"] && e.problem == nil && e.verified
              && listedE.names == ["archive", "footage", "media"] && ReviewHostClient.key(host) == keyBefore && publish.host(host.id) != nil,
              "\(connectedE) \(read) \(e.problem ?? "-") \(listedE)")

        // (g) A wrong key: Browse says the server doesn't accept this Mac's key.
        let goodKey = ReviewHostClient.key(host) ?? ""
        DeliverKeychain.save(Data(DeliverKeys.base64url(DeliverKeys.random(32)).utf8), as: sync, service: DeliverKeychain.hostService)
        let listedG = await roots(host)
        check("e2e (g): a wrong key: Browse says Pair Again", listedG.problem == String(localized: "The NAS server doesn’t accept this Mac’s key: Pair Again"),
              "\(listedG)")

        // (f) Pair Again: the key read from TrueNAS (app.config), and a full pairing line; both checked against the helper.
        let readBack = try? await TrueNASSetup.readKey(publish.host(host.id) ?? host)
        let line = "pluck-host:\(readBack ?? "")@\(publish.host(host.id)?.pin ?? "")"
        let paired = await DeliverPairAgainSheet.pairAgain(host.id, pairing: line)
        let listedF = await roots(host)
        check("e2e (f): Pair Again with the key from TrueNAS and its pairing line", readBack == goodKey && paired == nil && listedF.problem == nil,
              "\(readBack == goodKey) \(paired ?? "-") \(listedF)")

        await inviteTeammateE2E(publish.host(host.id) ?? host, sync: sync, roots: roots)
        await uploadsE2E(publish.host(host.id) ?? host, root: root, connected: connected)
    }

    /// (i) Change Folders sets an uploads folder; a file only on this Mac is shared into a folder made in it
    /// ("Client/2026"): the original lands there on the real helper, which makes the review copy itself.
    static func uploadsE2E(_ host: Deliver.Host, root: String, connected: (TrueNASSetup) async -> Bool) async {
        let publish = ReviewPublish.shared, store = DeliverStore.shared, fm = FileManager.default
        let i = TrueNASSetup(editing: host)
        _ = await connected(i)
        i.uploads = "tank/deliveries"
        await i.install()
        await i.check()
        let named = publish.host(host.id) ?? host
        let stage = await DeliverUploadDestination.stage(named)
        let source = NASFinderSource(host: named)
        source.uploads = "renders"
        let top = await source.list(source.root).map(\.1.name).sorted()
        check("e2e (i): Change Folders sets the uploads folder; the server offers it, by its dataset name", i.problem == nil && stage == .pick(root: "renders")
              && named.rootNames?["renders"] == "deliveries" && top.contains("deliveries"), "\(i.problem ?? "-") \(stage) \(top)")
        guard stage == .pick(root: "renders"), let manager = AppDelegate.shared?.manager, let ffmpeg = manager.tool("ffmpeg") else { return }

        let dir = fm.temporaryDirectory.appendingPathComponent("pluck-e2e-uploads-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let spot = dir.appendingPathComponent("Spot 30s.mov")
        _ = await DeliveryCheck.output(ffmpeg, ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=640x360:r=25:d=3", "-f", "lavfi", "-i", "sine=f=440:d=3",
                                                "-c:v", "mpeg4", "-q:v", "4", "-c:a", "aac", "-shortest", spot.path])
        guard let project = try? store.newProject("E2E uploads") else { return check("e2e (i): project", false, "") }
        defer { store.deleteProject(project.id) }
        let size = (try? spot.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let item = DeliverBrowseItem(name: spot.lastPathComponent, location: .local(spot), folder: false, size: size)
        let asks = DeliverUploadDestination.needed([item], host: named)
        let client = try? await DeliverUploadDestination.makeFolder("Client", in: "renders", host: named)
        let year = try? await DeliverUploadDestination.makeFolder("2026", in: client ?? "renders", host: named)
        let link = try? store.newLink(scope: .project(project.id), title: "E2E uploads")
        await DeliverShareForReview.place([item], into: project.id, asVersions: false, host: named, upload: .init(host: named.id, folder: year ?? ""))
        let landed = URL(fileURLWithPath: root).appendingPathComponent("mnt/tank/deliveries/Client/2026/Spot 30s.mov")
        let asset = store.content(project.id).assets.first { $0.name == "Spot 30s" }
        let same = (try? Data(contentsOf: landed)) == (try? Data(contentsOf: spot))
        check("e2e (i): a Mac-only file asks where; Client/2026 made; the original lands there on the helper; the version points at it",
              asks && year == "renders/Client/2026" && same && asset?.current.path == ReviewPublish.nasPath(host: named.id, path: "renders/Client/2026/Spot 30s.mov")
              && DeliverUploadDestination.remembered(host: named.id, project: project.id) == "renders/Client/2026",
              "asks \(asks) \(year ?? "-") landed \(same) \(asset?.current.path ?? "-")")

        // The helper makes the review copy from that file (by reference: nothing was pushed from here), and the copy plays.
        guard let version = asset?.current.id.uuidString else { return }
        let data = URL(fileURLWithPath: root).appendingPathComponent("mnt/tank/apps/pluck-review", isDirectory: true)
        var ready: URL?
        for _ in 0..<60 {
            ready = (fm.enumerator(at: data, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                .first { $0.lastPathComponent == "ready.json" && $0.deletingLastPathComponent().lastPathComponent == version }
            if ready != nil { break }
            try? await Task.sleep(for: .seconds(2))
        }
        let copies = ready?.deletingLastPathComponent()
        let pushed = (fm.enumerator(at: data, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).contains { $0.path.contains("/originals/") && $0.lastPathComponent.hasPrefix(version) }
        let playlist = copies.flatMap { c in ["1080", "540", "360"].map { c.appendingPathComponent("\($0)/index.m3u8") }.first { fm.fileExists(atPath: $0.path) } }
        var plays = false
        if let playlist, let ffprobe = manager.tool("ffprobe") {
            let out = await DeliveryCheck.output(ffprobe, ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_type", "-of", "csv=p=0", playlist.path])
            plays = out.contains("video")
        }
        check("e2e (i): the helper makes the review copy from the uploaded original (nothing pushed from the Mac) and it plays",
              ready != nil && !pushed && plays && link != nil, "ready \(ready?.path ?? "-") pushed \(pushed) playlist \(playlist?.path ?? "-") plays \(plays)")
    }

    /// (h) Invite a Teammate against the real helper. Mac A (this test, with the host key) makes an invitation; "Mac B" joins
    /// with the link alone. B is a second identity in this process: A's record and host key are set aside while B acts,
    /// so B has only what joining gave it (its record and its own device key), as on a teammate's Mac.
    static func inviteTeammateE2E(_ a: Deliver.Host, sync: String, roots: (Deliver.Host) async -> (names: [String], problem: String?)) async {
        let publish = ReviewPublish.shared, pairing = DeliverPairing.shared
        guard let keyA = ReviewHostClient.key(a) else { return check("e2e (h): Mac A has the host key", false, "") }
        func become(_ who: Deliver.Host?, hostKey: String?) {
            for h in publish.hosts.filter({ $0.address == sync }) { publish.removeHost(h.id) } // (also drops the host key kept by address)
            if let who { publish.add(who) }
            if let hostKey { DeliverKeychain.save(Data(hostKey.utf8), as: sync, service: DeliverKeychain.hostService) }
            ReviewHostTunnel.forgetRoute(a.id)
        }
        func join(_ invitation: PrivateNetwork.Invitation) async -> String? {
            pairing.problem = nil
            await pairing.pair(invitation)
            pairing.askMove = nil
            return pairing.problem
        }
        defer { become(a, hostKey: keyA) }

        // A: one invitation, valid 15 minutes; this stand-in runs no iroh, so it's a LAN link (no node).
        let answer = try? await ReviewHostClient.ask(a, ["op": "invite", "role": "mac"])
        let link = answer?["link"] as? String ?? ""
        guard let invitation = PrivateNetwork.Invitation(link: link), case .reviewHost(let node, let relay, let expires, let pin, let lan, let role) = invitation.way else {
            return check("e2e (h): A makes an invitation", false, "\(answer ?? [:])")
        }
        check("e2e (h): A makes a one-time LAN invitation for 15 minutes", lan == sync && node.isEmpty && role == "mac" && pin == a.pin
              && abs(expires.timeIntervalSinceNow - 900) < 60 && !invitation.expired, "\(link.prefix(60)) lan \(lan ?? "-") \(expires)")

        // An expired link: refused here, before the code is sent.
        let old = PrivateNetwork.Invitation(way: .reviewHost(node: node, relay: relay, expires: .now.addingTimeInterval(-60), pin: pin, lan: lan, role: role),
                                            name: invitation.name, code: invitation.code)
        become(nil, hostKey: nil)
        let expired = await join(old)
        // A server out of reach (nothing listens there), and a link from a newer Pluck.
        let away = PrivateNetwork.Invitation(way: .reviewHost(node: "", relay: nil, expires: expires, pin: pin, lan: "127.0.0.1:1", role: role),
                                             name: invitation.name, code: invitation.code)
        let unreachable = await join(away)
        let newer = PrivateNetwork.Invitation(link: "pluck://edit-anywhere/join?i=" + Data(#"{"v":4,"k":"nas"}"#.utf8).base64EncodedString()) == nil
            && DeliverPairing.problem(Deliver.Failure("incompatible"), name: "") == String(localized: "This invitation needs a newer Pluck. Update Pluck, then open the link again.")
        check("e2e (h): an expired link, a server out of reach and a newer link are each said", expired == String(localized: "This invitation has expired. Ask for a new one.")
              && unreachable == String(localized: "Pluck can’t reach “\(invitation.name)”. Check that this Mac is online, or try again on the office network.")
              && newer && publish.hosts.filter { $0.address == sync || $0.address == "127.0.0.1:1" }.isEmpty, "\(expired ?? "-") | \(unreachable ?? "-")")

        // B pastes the link (Join a Teammate's Server…, quotes and spaces around it), joins, and browses the media roots with its own key only.
        pairing.pending = nil
        _ = pairing.take("  \"\(link)\" \n")
        let pasted = pairing.pending
        let joined = await join(pasted ?? invitation)
        let b = publish.hosts.first { $0.address == sync }
        var listedB: (names: [String], problem: String?) = ([], "not joined")
        if let b { listedB = await roots(b) }
        check("e2e (h): B pastes the link and joins: Browse › Review server lists it, its own device key, the media roots",
              pasted == invitation && joined == nil && b?.device != nil && b.flatMap(ReviewHostClient.deviceKey) != nil && b.flatMap(ReviewHostClient.key) == nil && b?.role == "main"
              && StudioNavigator.shared.deliver == .browse(.nas(b?.id ?? UUID())) && listedB.problem == nil && listedB.names == ["nas1", "nas3", "nas4"],
              "\(joined ?? "-") device \(b?.device ?? "-") \(listedB)")
        guard let b else { return }

        // The same link again ("Mac C"): the server refuses it, and that's said.
        become(nil, hostKey: nil)
        let reused = await join(invitation)
        check("e2e (h): a used link is refused, saying so", reused == String(localized: "This invitation was already used. Ask for a new one.")
              && publish.hosts.filter { $0.address == sync }.isEmpty, reused ?? "-")

        // A sees B among the teammates (name, added, last seen) and removes it.
        become(a, hostKey: keyA)
        let listed = (try? await ReviewHostClient.ask(a, ["op": "devices"]))?["devices"] as? [[String: Any]] ?? []
        let entry = listed.first { $0["id"] as? String == b.device }
        let removed = (try? await ReviewHostClient.ask(a, ["op": "device-remove", "id": b.device ?? ""]))?["ok"] as? Bool == true
        let after = (try? await ReviewHostClient.ask(a, ["op": "devices"]))?["devices"] as? [[String: Any]] ?? []
        check("e2e (h): A lists B (name, added, last seen) and removes it", entry?["name"] as? String == (Host.current().localizedName ?? "Mac")
              && entry?["added"] is String && entry?["lastSeen"] is String && entry?["role"] as? String == "mac" && removed
              && !after.contains { $0["id"] as? String == b.device }, "\(listed) removed \(removed)")

        // B again: the server no longer takes its key, and Browse says to ask for a new invitation.
        become(b, hostKey: nil)
        let listedGone = await roots(b)
        check("e2e (h): after removal B is told it was removed", listedGone.problem == String(localized: "This Mac was removed from the review server. Ask its owner for a new invitation."),
              "\(listedGone)")
        if let device = b.device { DeliverKeychain.delete("\(b.id.uuidString)/\(device)", service: DeliverKeychain.hostService) }
    }
}

extension PhotoSelfTest {
    /// Share for Review's destination step: the folder remembered per project and server, files already on the NAS
    /// skip it, no uploads folder offers the fallback, and an upload lands where chosen (the NAS makes the copies).
    static func uploadDestinationTest(fake: ReviewFakeHost, store: DeliverStore, publish: ReviewPublish, host: Deliver.Host, project: UUID, base: URL) async {
        let fm = FileManager.default, other = UUID(), elsewhere = UUID()
        defer { ReviewHostClient.fake = { fake.answer($0, $1) } }
        DeliverUploadDestination.remember("renders/Client/2026", host: host.id, project: project)
        DeliverUploadDestination.remember("renders/Wedding", host: host.id, project: other)
        let start = await DeliverUploadDestination.start(host, root: "renders", project: project)
        let startOutside = await DeliverUploadDestination.start(host, root: "uploads", project: project)
        check("destination: the folder used last is remembered per project and per server, and the picker opens there",
              DeliverUploadDestination.remembered(host: host.id, project: project) == "renders/Client/2026"
              && DeliverUploadDestination.remembered(host: host.id, project: other) == "renders/Wedding"
              && DeliverUploadDestination.remembered(host: elsewhere, project: project) == nil
              && start == "renders/Client/2026" && startOutside == "uploads"
              && DeliverUploadDestination.suggested(host, root: "renders", project: other, store: store) == "renders/Wedding"
              && DeliverUploadDestination.suggested(host, root: "renders", project: elsewhere, store: store) == "renders/Review", "\(start) \(startOutside)")

        let spot = base.appendingPathComponent("Spot 30s.mov")
        fm.createFile(atPath: spot.path, contents: Data(repeating: 3, count: 3000))
        let here = DeliverBrowseItem(name: "Spot 30s.mov", location: .local(spot), folder: false, size: 3000)
        let onNAS = DeliverBrowseItem(name: "Hero 30s_v2.mov", location: .nas(host.id, "nas1/Hero 30s_v2.mov"), folder: false, size: 1)
        let folder = DeliverBrowseItem(name: "Stills", location: .local(base), folder: true, size: 0)
        var mounted = host
        mounted.mounts = [.init(local: base.path, remote: "nas1")]
        check("destination: files already on the NAS (browsed there, or on its mounted share) skip the step; a file only here asks",
              DeliverUploadDestination.needed([here], host: host) && DeliverUploadDestination.needed([onNAS, here], host: host)
              && !DeliverUploadDestination.needed([onNAS], host: host) && !DeliverUploadDestination.needed([here], host: mounted)
              && !DeliverUploadDestination.needed([folder], host: host) && !DeliverUploadDestination.needed([here], host: nil), "")

        let withRoot = await DeliverUploadDestination.stage(host)
        ReviewHostClient.fake = { request, body in request["op"] as? String == "roots" ? ["roots": ["nas1"], "writable": [String]()] : fake.answer(request, body) }
        let without = await DeliverUploadDestination.stage(host)
        // "Keep It on the Server Only": no upload, the copies made here (today's hidden data folder).
        await DeliverShareForReview.place([here], into: project, asVersions: false, host: nil, upload: nil, store: store, publish: publish)
        let kept = store.content(project).assets.first { $0.name == "Spot 30s" }
        check("destination: without an uploads folder the step offers the fallback, which keeps the original here", withRoot == .pick(root: "renders") && without == .noRoot
              && kept?.current.path == spot.path, "\(withRoot) \(without) \(kept?.current.path ?? "-")")
        if let kept { store.remove(asset: kept.id) }
        ReviewHostClient.fake = { fake.answer($0, $1) }

        // Upload: New Folder (mkdir), then the original to the folder chosen; the version is the NAS path the server gave.
        var made: [String] = []
        ReviewHostClient.fake = { request, body in
            if request["op"] as? String == "mkdir" { made.append(request["path"] as? String ?? "") }
            if request["op"] as? String == "upload-begin" { made.append("begin " + (request["path"] as? String ?? "")) }
            return fake.answer(request, body)
        }
        fake.uploads = [:]
        let newFolder = try? await DeliverUploadDestination.makeFolder("2026", in: "renders/Client", host: host)
        let refused = (try? await DeliverUploadDestination.makeFolder("../x", in: "renders", host: host)) == nil
        await DeliverShareForReview.place([here], into: project, asVersions: false, host: nil, upload: .init(host: host.id, folder: "renders/Client/2026"), store: store, publish: publish)
        let sent = store.content(project).assets.first { $0.name == "Spot 30s" }
        check("destination: New Folder, then Upload sends the original there and the version points at it on the NAS",
              newFolder == "renders/Client/2026" && refused && made.contains("renders/Client/2026") && made.contains("begin renders/Client/2026/Spot 30s.mov")
              && fake.uploads["u1"]?.count == 3000 && sent?.current.path == ReviewPublish.nasPath(host: host.id, path: "renders/Spring/Hero 30s v4 2.mov")
              && DeliverUploadDestination.remembered(host: host.id, project: project) == "renders/Client/2026", "\(made) \(sent?.current.path ?? "-")")

        // Move to… (the helper's `move` in the uploads folder): versions pointing at the file follow it.
        ReviewHostClient.fake = { request, body in
            request["op"] as? String == "move" ? ["ok": true, "path": (request["to"] as? String ?? "") + "/Hero 30s v4 2.mov"] : fake.answer(request, body)
        }
        let moved = try? await DeliverUploadDestination.move("renders/Spring/Hero 30s v4 2.mov", to: "renders/Client/Final", host: host, store: store)
        check("move: Move to… moves the file inside the uploads folder and re-points its version",
              moved == "renders/Client/Final/Hero 30s v4 2.mov" && store.find(sent?.id ?? UUID())?.asset.current.path == ReviewPublish.nasPath(host: host.id, path: "renders/Client/Final/Hero 30s v4 2.mov"),
              "\(moved ?? "-")")
        if let sent { store.remove(asset: sent.id) }

        // "Waiting for NAS": the server away at share time queues it (kept across restarts), sent once it answers; Cancel drops one.
        let queue = DeliverShareQueue(store: store, publish: publish)
        ReviewHostClient.fake = { _, _ in nil }
        await DeliverShareForReview.place([here], into: project, asVersions: false, host: nil, upload: .init(host: host.id, folder: "renders/Client/2026"),
                                          store: store, publish: publish, queue: queue)
        let spare = DeliverShareQueue.Entry(file: spot.path, size: 3000, project: project, upload: .init(host: host.id, folder: "renders/Other"))
        queue.add(spare)
        let reloaded = DeliverShareQueue(store: store, publish: publish).entries
        let whileAway = await queue.attempt()
        let stillWaiting = queue.waiting(project).count
        queue.cancel(spare.id)
        ReviewHostClient.fake = { fake.answer($0, $1) }
        fake.uploads = [:]
        let back = await queue.attempt()
        let arrived = store.content(project).assets.filter { $0.name == "Spot 30s" }
        check("waiting: a share while the NAS is away waits (kept across restarts), goes once it answers; Cancel drops one",
              reloaded.count == 2 && reloaded.first?.upload.folder == "renders/Client/2026" && whileAway == 0 && stillWaiting == 2
              && back == 1 && queue.entries.isEmpty && arrived.count == 1 && arrived.first?.current.path.hasPrefix("nas:") == true
              && DeliverShareQueue.waitable(Deliver.Failure("internal")) && !DeliverShareQueue.waitable(Deliver.Failure("space")),
              "\(reloaded.count) \(whileAway) \(stillWaiting) \(back) \(arrived.map(\.current.path))")
        for asset in arrived { store.remove(asset: asset.id) }
    }

    /// Browse's sidebar: one group per server (its name, a status dot, its menu), its roots by their real names, the
    /// uploads folder, backups at the end; no "Review server" / "On the NAS" groups. And the id → name mapping.
    static func browseSidebarTest(publish: ReviewPublish, host: Deliver.Host, backups: [DeliverBackups.Backup]) async {
        let found = TrueNASClient.installed(["services": ["pluck-review": [
            "environment": ["PLUCK_HOST_KEY": DeliverKeys.base64url(Data(repeating: 4, count: 32))],
            "volumes": ["/mnt/WideOpen-2/Wide-open-2026:/media/nas1:ro", "/mnt/tank/archive:/media/nas3:ro", "/mnt/tank/deliveries:/uploads/renders", "/mnt/tank/apps/pluck:/data"]]]])
        let names = found.map(TrueNASSetup.names) ?? [:]
        let setup = TrueNASSetup()
        setup.media = [("WideOpen-2/Wide-open-2026", "nas1"), ("tank/archive", "nas2")]
        setup.uploads = "tank/deliveries"
        var named = host
        named.rootNames = ["nas1": "Footage", "nas2": "Footage", "nas3": "nas1", "nas4": "Archive"]
        check("names: ids to names from app.config and the form (last part); unknown, clashing or another's id fall back to the id",
              names == ["nas1": "Wide-open-2026", "nas3": "archive", "renders": "deliveries"]
              && setup.rootNames == ["nas1": "Wide-open-2026", "nas2": "archive", "renders": "deliveries"]
              && Deliver.Host.names([("nas1", "/tank/media"), ("nas2", "")]) == ["nas1": "media"]
              && named.rootName("nas4") == "Archive" && named.rootName("nas1") == "nas1" && named.rootName("nas3") == "nas3" && named.rootName("nas9") == "nas9"
              && !setup.uploadsOverlap && { let s = TrueNASSetup(); s.media = [("tank/media", "nas1")]; s.uploads = "tank/media/up"; return s.uploadsOverlap }(), "\(names) \(setup.rootNames)")

        publish.update(host: host.id) { $0.rootNames = ["nas1": "Wide-open-2026"] }
        let current = publish.host(host.id) ?? host
        let roots = [host.id: [ReviewHostClient.Entry(name: "nas1", path: "nas1", folder: true), ReviewHostClient.Entry(name: "renders", path: "renders", folder: true)]]
        let groups = DeliverBrowseView.serverGroups(publish: publish, roots: roots, writable: [host.id: "renders"], backups: backups,
                                                    actions: { _ in AnyView(EmptyView()) }, show: { _ in }, remove: { _ in })
        let group = groups.first { $0.key == "server:" + host.id.uuidString }
        check("sidebar: one group per server, named after it, its roots by real names, Uploads, then its backups",
              group?.title == current.name && group?.menu != nil && group?.dot != nil
              && group?.places.first?.title == "Wide-open-2026" && group?.places.first?.id == "nasroot:\(host.id.uuidString)/nas1"
              && group?.places.dropFirst().first?.title == String(localized: "Uploads")
              && group?.places.suffix(backups.count).allSatisfy { $0.id.hasPrefix("backup:") } == true
              && !groups.contains { $0.title == "Review server" || $0.title == "On the NAS" }
              && !(group?.places.contains { $0.title == "nas1" } ?? true), "\(groups.map { "\($0.title): \($0.places.map(\.title))" })")
        publish.update(host: host.id) { $0.rootNames = nil }
    }
}
