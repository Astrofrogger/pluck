import AppKit
import Foundation

extension PhotoSelfTest {
    /// Round 3 end to end with no fakes (PLUCK_E2E_MODE=r3, driven by an outside script with real hosts, signaling and
    /// Chromium): the shared store, DeliverSync and DeliverWatch of this test home against a real `pluck-review` host.
    /// Writes <dir>/links.json, then runs commands from <dir>/cmd ("<n> <verb> [args]", answered with <dir>/done-<n>
    /// after <dir>/state.json is written):
    ///   pair <file>        pair over local iroh from {"link","addrs"} in <file>, then move the review data there
    ///   round              one sync round
    ///   comment <text>     an owner comment on Hero 30s (into the outbox)
    ///   deadline <link> <s>  that link's deadline in s seconds ("none": no deadline); reopen <link>: Reopen with none
    ///   watch <file>       a watched render folder holding <file>: offered after two checks, then shared (uploaded)
    ///   finish
    static func reviewE2E3(_ dir: URL) async {
        let fm = FileManager.default
        let store = DeliverStore.shared, sync = DeliverSync.shared
        guard let manager = AppDelegate.shared?.manager, let ffmpeg = manager.tool("ffmpeg"), let ffprobe = manager.tool("ffprobe") else { return check("e2e3: ffmpeg", false, "") }
        let media = dir.appendingPathComponent("swift-media", isDirectory: true)
        try? fm.removeItem(at: media)
        try? fm.createDirectory(at: media.appendingPathComponent("v2"), withIntermediateDirectories: true)
        func clip(_ url: URL, _ seconds: Int, tone: Int) async {
            _ = await DeliveryCheck.output(ffmpeg, ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=1280x720:r=25:d=\(seconds)", "-f", "lavfi", "-i", "sine=f=\(tone):d=\(seconds)",
                                                    "-c:v", "mpeg4", "-q:v", "3", "-c:a", "aac", "-shortest", "-timecode", "01:00:00:00", url.path])
        }
        let hero1 = media.appendingPathComponent("Hero 30s.mov"), hero2 = media.appendingPathComponent("v2/Hero 30s.mov"), teaser = media.appendingPathComponent("Teaser 15s.mov")
        await clip(hero1, 6, tone: 440)
        await clip(hero2, 6, tone: 660)
        await clip(teaser, 4, tone: 330)
        guard let project = try? store.newProject("Spring campaign"),
              let added = try? store.add([hero1, teaser], to: project.id, folder: nil),
              let hero = added.first(where: { $0.name == "Hero 30s" }), let teaserAsset = added.first(where: { $0.name == "Teaser 15s" }),
              (try? store.addVersion(hero2, to: hero.id)) != nil, let heroNow = store.find(hero.id)?.asset else { return check("e2e3: project", false, "") }
        for (asset, version) in [(heroNow, heroNow.versions[0]), (heroNow, heroNow.versions[1]), (teaserAsset, teaserAsset.current)] {
            let made = await DeliverCopies.make(store.original(version) ?? URL(fileURLWithPath: version.path), kind: asset.kind, into: store.copies(version.id), ffmpeg: ffmpeg, ffprobe: ffprobe) { _ in }
            store.update(version: version.id, of: asset.id) { $0.probe = made.probe; $0.copy = .ready(made.renditions ?? []); $0.sha256 = nil }
        }
        // (Hashes for proofs, as the copy job does.)
        for version in heroNow.versions { if let sha = await DeliverUploads.sha256(URL(fileURLWithPath: version.path)) { store.update(version: version.id, of: hero.id) { $0.sha256 = sha } } }

        var made: [String: Deliver.ShareLink] = [:]
        func link(_ name: String, password: String? = nil, _ change: (inout Deliver.ShareLink) -> Void = { _ in }) {
            guard let l = try? store.newLink(scope: .project(project.id), title: name.capitalized, allowDownload: true, password: password) else { return }
            store.updateLink(l.id, change)
            made[name] = store.link(l.id)
        }
        link("main", password: "test") { $0.fields = ["status", "rating"]; $0.featuredField = "rating" }
        link("client") { $0.fields = ["status", "rating"]; $0.featuredField = "status" }
        link("deadline")
        link("team") { $0.audience = "team" }
        func writeLinks() {
            var json: [String: Any] = [:]
            for (name, l) in made { if let key = store.key(l.id), let secret = store.secret(l.id) { json[name] = ["key": DeliverKeys.base64url(key), "room": l.roomID, "id": l.id.uuidString, "reg": DeliverKeys.registerKey(root: secret), "pub": DeliverKeys.publicKey(root: secret), "join": DeliverKeys.join(key), "url": store.url(l) ?? ""] } }
            let now = store.find(hero.id)?.asset
            json["assets"] = ["hero": hero.id.uuidString, "teaser": teaserAsset.id.uuidString, "project": project.id.uuidString,
                              "heroV1": now?.versions[0].id.uuidString ?? "", "heroV2": now?.versions[1].id.uuidString ?? "",
                              "sha1": now?.versions[0].sha256 ?? "", "sha2": now?.versions[1].sha256 ?? ""] as [String: Any]
            try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent("links.json"))
        }
        var note = ""
        func state() {
            let comments = store.content(project.id).assets.flatMap { store.comments($0.id) }.map { ["id": $0.id.uuidString, "text": $0.text, "author": $0.author] }
            let heroVersions = store.find(hero.id)?.asset.versions.map { ["number": $0.number, "path": $0.path] as [String: Any] } ?? []
            let json: [String: Any] = ["comments": comments, "waiting": sync.waiting, "outbox": sync.outbox().count, "problem": sync.problem ?? "",
                                       "host": sync.dataHost?.id.uuidString ?? "", "lastSync": sync.state.lastSync.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                                       "via": sync.dataHost.flatMap { ReviewHostTunnel.via(of: $0.id)?.rawValue } ?? "", "device": sync.dataHost?.device ?? "",
                                       "heroVersions": heroVersions, "approvals": store.approvals(project.id).count, "note": note,
                                       "links": made.mapValues { l in store.link(l.id).map { ["deadline": $0.deadline.map { ISO8601DateFormatter().string(from: $0) } ?? "", "rev": $0.rev ?? 0] as [String: Any] } ?? [:] }]
            try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent("state.json"))
        }
        writeLinks()
        state()
        try? Data().write(to: dir.appendingPathComponent("ready-r3"))

        let cmd = dir.appendingPathComponent("cmd")
        for _ in 0..<15000 {
            try? await Task.sleep(for: .milliseconds(200))
            guard let text = try? String(contentsOf: cmd, encoding: .utf8), !text.isEmpty else { continue }
            try? fm.removeItem(at: cmd)
            let words = text.split(separator: " ").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard words.count >= 2 else { continue }
            let rest = words.dropFirst(2).joined(separator: " ")
            note = ""
            switch words[1] {
            case "pair":
                do {
                    let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: rest))) as? [String: Any] ?? [:]
                    ReviewHostTunnel.testSettings = ["local": true, "officeAddrs": spec["addrs"] ?? []]
                    guard let invitation = PrivateNetwork.Invitation(link: spec["link"] as? String ?? "") else { throw Deliver.Failure("invalid") }
                    let host = try await ReviewHostClient.pair(invitation)
                    try await sync.migrate(to: host)
                    note = "paired " + host.name
                } catch { note = "pair failed: \(error)" }
            case "round": await sync.round()
            case "comment":
                if let current = store.find(hero.id)?.asset.current {
                    do { _ = try store.addComment(asset: hero.id, version: current.id, frame: nil, text: rest, author: DeliverSettings.author) } catch { note = "\(error)" }
                }
            case "deadline":
                let parts = rest.split(separator: " ").map(String.init)
                if let target = made[parts.first ?? ""] {
                    let deadline = parts.count > 1 ? Double(parts[1]).map { Date().addingTimeInterval($0) } : nil
                    store.updateLink(target.id) { $0.deadline = deadline }
                }
            case "reopen": if let target = made[rest] { DeliverDeadlines.shared.reopen(target.id, deadline: nil) }
            case "watch":
                let file = URL(fileURLWithPath: rest)
                let watcher = DeliverWatch.shared
                var watch = DeliverWatch.Watch(project: project.id)
                watch.local = file.deletingLastPathComponent().path
                watcher.add(watch)
                var offered: [String] = []
                watcher.posted = { item, _, _ in offered.append(item.path) }
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now
                let entry = (path: file.path, name: file.lastPathComponent, size: size, modified: modified)
                watcher.consider([entry], watch: watch, now: .now)
                watcher.consider([entry], watch: watch, now: Date().addingTimeInterval(11))
                var why = "host \(sync.dataHost?.name ?? "none")"
                if let host = sync.dataHost { why += " root \(await DeliverUploads.writableRoot(host) ?? "none")" }
                if offered == [file.path] {
                    let before = store.find(hero.id)?.asset.versions.count ?? 0
                    watcher.accept(file.path)
                    for _ in 0..<600 where (store.find(hero.id)?.asset.versions.count ?? 0) == before { try? await Task.sleep(for: .milliseconds(100)) }
                    note = "shared " + (store.find(hero.id)?.asset.current.path ?? "") + " (\(why); \(DeliverUploads.shared.problem ?? ""))"
                } else { note = "not offered: \(offered)" }
            default: break
            }
            state()
            try? Data().write(to: dir.appendingPathComponent("done-\(words[0])"))
            if words[1] == "finish" { break }
        }
        check("e2e3: finished", true, "")
    }
}
