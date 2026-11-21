import AppKit
import Foundation

/// "Send Missing Files and Render" (4.0.7): before a render on the office Mac, the home Mac sorts every file the open
/// project uses into a proxy of a known original, a file already on a NAS share the office has (by NAS key and path),
/// or a file only on this Mac. Media pool files only here are sent with Send Files Here into
/// `<project folder>/Pluck · From <Mac>/…` and passed with the render as a path map (`files`), which the office applies
/// to its imported copy (the proxy swap's ReplaceClip), never to the editor's own project. Fonts (Text+, subtitle
/// styles) and effects (ResolveFX, OFX, audio plugins) are checked on the office before sending and again before it
/// renders; missing ones stop the render unless the editor chose Render Anyway.
///
/// shortcut: files only a Fusion comp or a grade reads (Loader, LUT) aren't sent (the office can't swap them in a comp);
/// the editor is told to copy them into a share. Fonts and effects are those of the whole project, not only the
/// timeline rendered. No "Send Font": fonts and plugins are licensed, the editor installs them on the office Mac.
@MainActor
enum RemoteMissing {
    struct Font: Hashable, Sendable {
        var family: String
        var style: String

        init(family: String, style: String = "") { (self.family, self.style) = (family, style) }

        init?(_ value: [String: Any]) {
            guard let family = value["family"] as? String, !family.isEmpty, family.count < 300 else { return nil }
            self.init(family: family, style: String((value["style"] as? String ?? "").prefix(100)))
        }

        var label: String {
            style.isEmpty || ["regular", "normal", "plain", "roman"].contains(style.lowercased()) ? family : family + " " + style
        }
        var dictionary: [String: Any] { ["family": family, "style": style] }
    }

    struct Effect: Hashable, Sendable {
        var id: String
        var name: String

        init(id: String, name: String) { (self.id, self.name) = (id, name) }

        init?(_ value: [String: Any]) {
            let id = String((value["id"] as? String ?? "").prefix(300)), name = String((value["name"] as? String ?? "").prefix(300))
            guard !id.isEmpty || !name.isEmpty else { return nil }
            self.init(id: id, name: name)
        }

        var label: String { name.isEmpty ? id : name }
        var dictionary: [String: Any] { ["id": id, "name": name] }
    }

    /// The fonts a project uses (as the Resolve script's `uses` reports them), once each.
    nonisolated static func fonts(_ found: [String: Any]) -> [Font] {
        var seen = Set<String>()
        return (found["fonts"] as? [[String: Any]] ?? []).prefix(2000).compactMap(Font.init)
            .filter { seen.insert($0.label.lowercased()).inserted }
    }

    /// Its effects, once each (one known by id and name counts once with a name-only one).
    nonisolated static func effects(_ found: [String: Any]) -> [Effect] {
        var result: [Effect] = []
        for effect in (found["effects"] as? [[String: Any]] ?? []).prefix(2000).compactMap(Effect.init) {
            // (The same one known by id in one place, by name in another: "com.example.Sparkle" and "Sparkle".)
            func last(_ id: String) -> String { key(String(id.split(separator: ".").last ?? "")) }
            if let index = result.firstIndex(where: { (!effect.id.isEmpty && $0.id == effect.id) || (!effect.name.isEmpty && key($0.name) == key(effect.name))
                || ($0.name.isEmpty && !effect.name.isEmpty && last($0.id) == key(effect.name))
                || (effect.name.isEmpty && !$0.name.isEmpty && last(effect.id) == key($0.name)) }) {
                if result[index].id.isEmpty { result[index].id = effect.id }
                if result[index].name.isEmpty { result[index].name = effect.name }
            } else {
                result.append(effect)
            }
        }
        return result
    }

    nonisolated static func key(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }

    // MARK: - On the office Mac: what's installed

    /// Whether this Mac has the font: a family with that style, or a PostScript name.
    static func installed(_ font: Font) -> Bool {
        let manager = NSFontManager.shared
        guard let family = manager.availableFontFamilies.first(where: { $0.caseInsensitiveCompare(font.family) == .orderedSame }) else {
            return NSFont(name: font.family, size: 12) != nil
        }
        guard !font.style.isEmpty else { return true }
        let styles = (manager.availableMembers(ofFontFamily: family) ?? []).compactMap { $0.count > 1 ? $0[1] as? String : nil }
        return styles.contains { $0.caseInsensitiveCompare(font.style) == .orderedSame } || font.label == font.family
    }

    /// Where OFX plugins are installed (a variable for the tests).
    nonisolated(unsafe) static var ofxRoot = URL(fileURLWithPath: "/Library/OFX/Plugins", isDirectory: true)

    /// The effects the office's Resolve has (nil: Resolve couldn't be asked). A variable for the tests, which never reach Resolve.
    static var resolveEffects: () async -> [Effect]? = {
        (try? await RemoteResolveScript.run(["action": "effects"]))
            .map { ($0["effects"] as? [[String: Any]] ?? []).compactMap(Effect.init) }
    }

    /// The effects not installed: not in Resolve's own list (by id or name), nor a plugin bundle in `root` named like
    /// them ("NeatVideo5.ofx.bundle" for com.neatvideo.NeatVideo5). Resolve's own count as there when its list is unknown.
    nonisolated static func missing(_ effects: [Effect], installed: [Effect]?, root: URL) -> [Effect] {
        let bundles = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasSuffix(".ofx.bundle") }.map { key(String($0.dropLast(".ofx.bundle".count))) }.filter { $0.count >= 4 }
        let ids = Set((installed ?? []).map { $0.id.lowercased() }.filter { !$0.isEmpty })
        let names = Set((installed ?? []).map { key($0.name) }.filter { !$0.isEmpty })
        return effects.filter { effect in
            if !effect.id.isEmpty, ids.contains(effect.id.lowercased()) { return false }
            if !effect.name.isEmpty, names.contains(key(effect.name)) { return false }
            // (Resolve's list unknown: its own effects, and one known only by name (it may be Resolve's), can't be told missing.)
            if installed == nil, effect.id.isEmpty || effect.id.lowercased().hasPrefix("com.blackmagicdesign.") { return false }
            // (The id's own parts, not its "com.vendor." start: one vendor's other plugin isn't this one.)
            let id = effect.id.split(separator: ".").map(String.init)
            let parts = ([effect.name] + (id.count >= 3 ? Array(id.dropFirst(2)) : Array(id.suffix(1)))).map(key).filter { $0.count >= 4 && $0 != "resolvefx" }
            return !bundles.contains { bundle in parts.contains { $0.contains(bundle) || bundle.contains($0) } }
        }
    }

    static func problem(_ font: Font) -> String { String(localized: "Font “\(font.label)” isn’t installed on the office Mac.") }
    static func problem(_ effect: Effect) -> String { String(localized: "Effect “\(effect.label)” isn’t installed on the office Mac.") }

    /// The office's check just before it renders, on what its `inspect` found (with Resolve's effects as `installed`).
    static func problems(_ found: [String: Any], root: URL = ofxRoot) -> [String] {
        let resolve = (found["installed"] as? [[String: Any]]).map { $0.compactMap(Effect.init) }
        return fonts(found).filter { !installed($0) }.map(problem) + missing(effects(found), installed: resolve, root: root).map(problem)
    }

    /// Up to this many "Name 2", "Name 3"… are looked at for a copy sent before.
    nonisolated static let copies = 20

    static func register() {
        // {fonts, effects, files: [{share, path, size, sha256}]} → {fonts, effects (missing here), present: [path or ""]}
        OfficeActions.register("resolveMissing") { arguments, device in
            try OfficeActions.require(\.render, device)
            let fonts = (arguments["fonts"] as? [[String: Any]] ?? []).prefix(2000).compactMap(Font.init)
            let effects = (arguments["effects"] as? [[String: Any]] ?? []).prefix(2000).compactMap(Effect.init)
            var missingEffects: [Effect] = []
            if !effects.isEmpty { missingEffects = missing(effects, installed: await resolveEffects(), root: ofxRoot) }
            var present: [String] = []
            // Hashing stops before the home Mac's 600 s wait runs out; a file not checked is sent again (as "Name 2", never over it).
            let deadline = Date.now.addingTimeInterval(400)
            for file in (arguments["files"] as? [[String: Any]] ?? []).prefix(5000) {
                present.append(await sentBefore(file, device, until: deadline) ?? "")
            }
            return ["fonts": fonts.filter { !installed($0) }.map(\.dictionary), "effects": missingEffects.map(\.dictionary), "present": present]
        }
    }

    /// A copy sent earlier at the target ("Name", else "Name 2"… up to `copies`) with the same size and SHA-256: its path in the share.
    private static func sentBefore(_ file: [String: Any], _ device: OfficeRenderServer.Device, until deadline: Date) async -> String? {
        guard let path = file["path"] as? String, path.count < 2000, let sha = (file["sha256"] as? String)?.lowercased(),
              let size = (file["size"] as? NSNumber)?.int64Value, let place = try? RemoteEditHost.share(file["share"]) else { return nil }
        let parent = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
        guard let folder = try? OfficeActions.require(\.browse, device, share: place, path: parent) else { return nil }
        return await Task.detached { () -> String? in
            let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            for n in 1...copies {
                let candidate = n == 1 ? name : "\(stem) \(n)" + (ext.isEmpty ? "" : "." + ext)
                let url = folder.appendingPathComponent(candidate)
                guard let stamp = RemoteDriveWriteHost.stamp(of: url) else { if n > 1 { break } else { continue } }
                // (A NAS reads ~100 MB/s: a hash that would end past the deadline isn't started.)
                if stamp.size == size, Date.now.addingTimeInterval(Double(size) / 100_000_000) < deadline, (try? RemoteSendInto.hash(url)) == sha {
                    return (parent.isEmpty ? "" : parent + "/") + candidate
                }
            }
            return nil
        }.value
    }

    // MARK: - On the home Mac: sorting the files

    struct LocalFile: Hashable, Sendable {
        var path: String
        var size: Int64
        var name: String { (path as NSString).lastPathComponent }
    }

    /// What the pre-flight found. `files`: the path map (files already on a share; the sent copies are added when sent).
    struct Plan {
        var proxies: [RemoteRenderQueue.Proxy] = []
        var files: [RemoteRenderQueue.Proxy] = []
        /// Media pool files only on this Mac (sent with Send Missing Files and Render).
        var send: [LocalFile] = []
        /// Files only a Fusion comp or a grade reads, only on this Mac (can't be sent).
        var stuck: [String] = []
        var fonts: [Font] = []
        var effects: [Effect] = []
        /// The office takes sent files and checks fonts and effects (an office from before: no).
        var takesFiles = false

        var total: Int64 { send.reduce(0) { $0 + $1.size } }
        var clean: Bool { send.isEmpty && stuck.isEmpty && fonts.isEmpty && effects.isEmpty }
        /// What the editor can do: send and render, render anyway, or nothing (fix it first).
        var canSend: Bool { takesFiles && !send.isEmpty && stuck.isEmpty }
        var canRenderAnyway: Bool { send.isEmpty && stuck.isEmpty && !clean }
    }

    /// A file's share and path there when it's on a NAS share the office has (its NAS key under the share's).
    nonisolated static func onShare(_ path: String, shares: [(id: String, nas: String)]) -> (share: String, path: String)? {
        guard let place = OfficeGroup.place(URL(fileURLWithPath: path)) else { return nil }
        let full = place.remount + place.path, lower = full.lowercased()
        for share in shares where !share.nas.isEmpty && lower.hasPrefix(share.nas + "/") {
            return (share.id, String(full.dropFirst(share.nas.count + 1)))
        }
        return nil
    }

    /// Sorts the project's files: media pool files (`media`) that aren't proxies go in the path map when on a share,
    /// to send when only here; files comps and grades read (`refs`) only here are `stuck`. `size`: a file's size here
    /// (nil: not on this Mac either, the office reports it). Resolve's own folders (`builtIn`) and relative LUTs are left out.
    nonisolated static func classify(media: [String], refs: [[String: Any]], proxies: Set<String>, shares: [(id: String, nas: String)],
                                     builtIn: [String], size: (String) -> Int64?) -> (files: [RemoteRenderQueue.Proxy], send: [LocalFile], stuck: [String]) {
        var files: [RemoteRenderQueue.Proxy] = [], send: [LocalFile] = [], stuck: [String] = []
        let known = Set(proxies.map(RemoteResolveMap.normal))
        for file in Set(media).sorted() where !file.isEmpty && !known.contains(RemoteResolveMap.normal(file)) {
            if let place = onShare(file, shares: shares) {
                files.append(.init(file: file, share: place.share, path: place.path))
            } else if let bytes = size(file) {
                send.append(LocalFile(path: file, size: bytes))
            }
        }
        let media = Set(media)
        for ref in refs where !["media", "blob"].contains(ref["regid"] as? String ?? "") {
            guard let path = ref["path"] as? String, path.hasPrefix("/"), !media.contains(path), !stuck.contains(path),
                  !builtIn.contains(where: { path == $0 || path.hasPrefix($0 + "/") }), onShare(path, shares: shares) == nil, size(path) != nil else { continue }
            stuck.append(path)
        }
        return (files, send, stuck)
    }

    /// The deepest folder all these paths are in ("" for none in common).
    nonisolated static func common(_ folders: [String]) -> String {
        guard var parts = folders.first?.split(separator: "/").map(String.init) else { return "" }
        for folder in folders.dropFirst() {
            let other = folder.split(separator: "/").map(String.init)
            parts = Array(zip(parts, other).prefix { $0 == $1 }.map(\.0))
        }
        return parts.joined(separator: "/")
    }

    /// Where a project's sent files go: the folder its originals are in (in the share most of them are), from `mac`.
    nonisolated static func target(proxies: [RemoteRenderQueue.Proxy], share fallback: String?, mac: String) -> (share: String, folder: String)? {
        let counts = Dictionary(grouping: proxies, by: \.share)
        guard let share = counts.max(by: { $0.value.count < $1.value.count })?.key ?? fallback else { return nil }
        let base = common((counts[share] ?? []).map { ($0.path as NSString).deletingLastPathComponent })
        let own = "Pluck · From " + String(Folders.sanitize(mac, fallback: "Mac").prefix(60))
        return (share, base.isEmpty ? own : base + "/" + own)
    }

    // MARK: - On the home Mac: sending

    /// Sends the files into `target` (keeping their folders under their common one), each resumed, checked and never
    /// overwriting; one sent before (same size and SHA-256) isn't sent again. Gives the path map for them.
    static func send(_ files: [LocalFile], to target: (share: String, folder: String), client: OfficeRenderClient = .shared,
                     progress: @escaping (String, Double) -> Void = { _, _ in }) async throws -> [RemoteRenderQueue.Proxy] {
        guard !files.isEmpty else { return [] }
        let parent = (target.folder as NSString).deletingLastPathComponent
        let can = (try? await client.ask("driveCanWrite", ["share": target.share, "path": parent], timeout: 20))?["can"] as? Bool
        guard can == true else {
            throw OfficeLink.Failure.office(String(localized: "Sending the missing files needs the Editor role in that folder on the office Mac. An Admin there can give it in Edit Anywhere."))
        }
        let depth = common(files.map { ($0.path as NSString).deletingLastPathComponent }).split(separator: "/").count
        func folder(_ file: LocalFile) -> String {
            let below = (file.path as NSString).deletingLastPathComponent.split(separator: "/").dropFirst(depth).joined(separator: "/")
            return below.isEmpty ? target.folder : target.folder + "/" + below
        }
        var hashes: [URL: String] = [:]
        for file in files {
            progress(file.name, 0)
            let url = URL(fileURLWithPath: file.path)
            hashes[url] = try await Task.detached { try RemoteSendInto.hash(url) }.value
        }
        let asked = files.map { file -> [String: Any] in
            ["share": target.share, "path": folder(file) + "/" + file.name, "size": file.size, "sha256": hashes[URL(fileURLWithPath: file.path)] ?? ""]
        }
        let present = (try await client.ask("resolveMissing", ["files": asked], timeout: 600))["present"] as? [String] ?? []
        var made = Set<String>(), map: [RemoteRenderQueue.Proxy] = []
        for (index, file) in files.enumerated() {
            if index < present.count, !present[index].isEmpty {
                map.append(.init(file: file.path, share: target.share, path: present[index]))
                continue
            }
            let into = folder(file)
            // Each folder on the way, from the one the Editor role is checked in.
            var path = parent
            for part in String(into.dropFirst(parent.isEmpty ? 0 : parent.count + 1)).split(separator: "/") {
                path = path.isEmpty ? String(part) : path + "/" + part
                if made.insert(path).inserted { _ = try await client.ask("driveFolder", ["share": target.share, "path": path]) }
            }
            let url = URL(fileURLWithPath: file.path)
            let names = try await RemoteSendInto.send([url], share: target.share, path: into, client: client, hashes: hashes, progress: progress)
            map.append(.init(file: file.path, share: target.share, path: into + "/" + (names.first ?? file.name)))
        }
        return map
    }

    /// "Logo.mov, Whoosh.wav, … · 1.2 GB" for the list before sending.
    static func summary(_ files: [LocalFile]) -> String {
        let names = files.prefix(4).map(\.name).joined(separator: ", ") + (files.count > 4 ? ", …" : "")
        return names + " · " + ByteCountFormatter.string(fromByteCount: files.reduce(0) { $0 + $1.size }, countStyle: .file)
    }
}
