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
/// LUTs (grades, project and timeline settings) only here go into the office's LUT folder at the same relative path,
/// so the grade finds them unchanged; files a Fusion comp reads go where the office would find that same path (in one
/// of its shares), so the comp needn't change. A file there that differs (same name) is reported, never replaced.
/// A comp file the office has no share for stays with "copy it into a share".
/// shortcut: DCTLs aren't sent (they're code the office would install for every project); fonts and effects are those
/// of the whole project, not only the timeline rendered. No "Send Font": fonts and plugins are licensed, the editor installs them on the office Mac.
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
            // (luts, comps: an office from before answers neither, and the home Mac sends neither.)
            var luts: [String] = [], comps: [[String: Any]] = []
            for lut in (arguments["luts"] as? [[String: Any]] ?? []).prefix(2000) {
                let root = lutFolder
                luts.append(await Task.detached { lutState(lut, root: root) }.value)
            }
            let roots = OfficeArchive.shared.folders.compactMap { folder in RemoteEditHost.realPath(folder.path).map { (id: OfficeProxies.id(folder), root: $0) } }
            for comp in (arguments["comps"] as? [[String: Any]] ?? []).prefix(2000) {
                comps.append(await compPlace(comp, roots: roots, device: device))
            }
            return ["fonts": fonts.filter { !installed($0) }.map(\.dictionary), "effects": missingEffects.map(\.dictionary), "present": present,
                    "luts": luts, "comps": comps]
        }
        // {path (in the LUT folder), size} → {have}; plus {offset, data, sha256 (last piece)} → {have, placed}
        OfficeActions.register("resolveLUT") { arguments, device in
            try OfficeActions.require(\.render, device)
            let relative = try OfficeActions.text(arguments["path"], 600), size = try OfficeActions.number(arguments["size"])
            guard size <= lutLargest else { throw OfficeInbox.Problem.tooBig }
            let root = lutFolder
            let folder = try await Task.detached { try lutTarget(relative, root: root, make: true) }.value
            let name = (relative as NSString).lastPathComponent
            guard let data = (arguments["data"] as? String).flatMap({ Data(base64Encoded: $0) }), data.count <= OfficeLink.uploadChunk else {
                let part = RemoteSendInto.partial(folder, name: name, size: size, modified: 0)
                return ["have": RemoteDriveWriteHost.stamp(of: part)?.size ?? 0]
            }
            let offset = try OfficeActions.number(arguments["offset"]), sha = arguments["sha256"] as? String
            return try await Task.detached {
                try RemoteSendInto.receive(into: folder, name: name, size: size, modified: 0, offset: offset, data: data, sha256: sha) { part in
                    try placeExactly(part, at: folder.appendingPathComponent(name))
                    return ["placed": true]
                }
            }.value
        }
    }

    // MARK: - On the office Mac: LUTs and comp files

    /// DaVinci Resolve's LUT folder (a variable for the tests).
    nonisolated(unsafe) static var lutFolder = URL(fileURLWithPath: RemoteResolveProject.lutRoot, isDirectory: true)
    nonisolated static let lutLargest: Int64 = 200_000_000
    /// LUT files that are sent (Resolve's list, without DCTLs: those are code).
    nonisolated static let lutEndings = ["cube", "3dl", "ilut", "olut", "lut", "csp", "dat", "vlt", "mga", "m3d", "itx", "look", "clf", "ctf"]

    /// A LUT's path in the LUT folder ("Sony/SLog3.cube"): plain names, a LUT ending (`code`: or a DCTL's), no `..`.
    nonisolated static func lutRelative(_ path: String, code: Bool = false) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init), ending = (path as NSString).pathExtension.lowercased()
        return parts.count <= 12 && parts.allSatisfy(RemoteSendInto.nameOK) && (lutEndings.contains(ending) || (code && ["dctl", "dctle"].contains(ending)))
    }

    /// The folder in `root` a LUT goes in, its folders made if `make` (each checked to stay in `root`: no link out).
    nonisolated static func lutTarget(_ relative: String, root: URL, make: Bool) throws -> URL {
        guard lutRelative(relative, code: !make), let base = RemoteEditHost.realPath(root.path) else { throw OfficeInbox.Problem.badPath }
        var folder = base
        for part in relative.split(separator: "/").dropLast() {
            folder += "/" + part
            if make, mkdir(folder, 0o755) != 0, errno != EEXIST { throw OfficeInbox.Problem.badPath }
            guard let real = RemoteEditHost.realPath(folder) else { if make { throw OfficeInbox.Problem.badPath } else { return URL(fileURLWithPath: folder) } }
            guard real.hasPrefix(base + "/"), RemoteEditHost.isDirectory(URL(fileURLWithPath: real)) else { throw OfficeInbox.Problem.badPath }
            folder = real
        }
        return URL(fileURLWithPath: folder, isDirectory: true)
    }

    /// The office's LUT against the editor's {path, size, sha256}: "same", "missing", "different", or "" (not a LUT path).
    nonisolated static func lutState(_ lut: [String: Any], root: URL) -> String {
        guard let path = lut["path"] as? String, let folder = try? lutTarget(path, root: root, make: false) else { return "" }
        return state(of: folder.appendingPathComponent((path as NSString).lastPathComponent), size: (lut["size"] as? NSNumber)?.int64Value,
                     sha: (lut["sha256"] as? String)?.lowercased())
    }

    /// A file there against a size and SHA-256: "same", "missing" (nothing at all there) or "different".
    nonisolated static func state(of file: URL, size: Int64?, sha: String?) -> String {
        var info = stat()
        guard lstat(file.path, &info) == 0 else { return "missing" }
        guard let stamp = RemoteDriveWriteHost.stamp(of: file), stamp.size == size, let sha, (try? RemoteSendInto.hash(file)) == sha else { return "different" }
        return "same"
    }

    /// Puts a checked partial at exactly `target` (never over a file there: one that's the same bytes is fine).
    nonisolated static func placeExactly(_ part: URL, at target: URL) throws {
        defer { unlink(part.path) }
        guard link(part.path, target.path) != 0 else { return }
        guard errno == EEXIST, (try? RemoteSendInto.hash(target)) == (try? RemoteSendInto.hash(part)) else {
            throw OfficeLink.Failure.office(String(localized: "Another file with that name is on the office Mac. It wasn’t replaced."))
        }
    }

    /// Where a comp's absolute path is in one of the office's shares (`roots`: real paths): the comp reads that
    /// path as it is, so a file sent there is found without changing the comp.
    nonisolated static func officePlace(_ path: String, roots: [(id: String, root: String)]) -> (share: String, path: String)? {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }),
              let real = RemoteResolveProject.hostPath(path) else { return nil }
        for root in roots where real.hasPrefix(root.root + "/") {
            let relative = String(real.dropFirst(root.root.count + 1))
            guard relative.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ RemoteSendInto.nameOK(String($0)) }) else { return nil }
            return (root.id, relative)
        }
        return nil
    }

    /// A comp file {path, size, sha256} on the office: {share, path, base (its nearest folder there), state}, or empty
    /// when it isn't in a share or this Mac can't write there (the editor copies it by hand).
    private static func compPlace(_ comp: [String: Any], roots: [(id: String, root: String)], device: OfficeRenderServer.Device) async -> [String: Any] {
        guard let path = comp["path"] as? String, path.count < 2000, let place = officePlace(path, roots: roots),
              let share = try? RemoteEditHost.share(place.share) else { return [:] }
        var base = (place.path as NSString).deletingLastPathComponent
        while !base.isEmpty, !RemoteEditHost.isDirectory(URL(fileURLWithPath: share.root.path + "/" + base)) { base = (base as NSString).deletingLastPathComponent }
        guard let folder = try? RemoteEditHost.resolve(base, in: share.root), OfficeActions.allowed(\.render, device, share: share, file: folder) else { return [:] }
        let file = URL(fileURLWithPath: (RemoteEditHost.realPath(share.root.path) ?? share.root.path) + "/" + place.path)
        let size = (comp["size"] as? NSNumber)?.int64Value, sha = (comp["sha256"] as? String)?.lowercased()
        let state = await Task.detached { state(of: file, size: size, sha: sha) }.value
        return ["share": share.id, "path": place.path, "base": base, "state": state]
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

    /// A file of this Mac and where it goes on the office: a LUT in its LUT folder (`share` empty), a comp's file in a
    /// share (`base`: its nearest folder there, the folders below it are made).
    struct Placed: Hashable, Sendable {
        var file: LocalFile
        var share = ""
        var path: String
        var base = ""
    }

    /// What the pre-flight found. `files`: the path map (files already on a share; the sent copies are added when sent).
    struct Plan {
        var proxies: [RemoteRenderQueue.Proxy] = []
        var files: [RemoteRenderQueue.Proxy] = []
        /// Media pool files only on this Mac (sent with Send Missing Files and Render).
        var send: [LocalFile] = []
        /// Files only a Fusion comp or a grade reads, only on this Mac (can't be sent).
        var stuck: [String] = []
        /// LUTs and comp files only here that the office takes at their own path (sent too).
        var placed: [Placed] = []
        /// LUTs and comp files the office has another file of that name for (kept there, not sent).
        var different: [String] = []
        /// SHA-256 by path of this Mac, read for the office's check.
        var hashes: [String: String] = [:]
        var fonts: [Font] = []
        var effects: [Effect] = []
        /// The office takes sent files and checks fonts and effects (an office from before: no).
        var takesFiles = false

        /// Everything sent with Send Missing Files and Render.
        var sending: [LocalFile] { send + placed.map(\.file) }
        var total: Int64 { sending.reduce(0) { $0 + $1.size } }
        var clean: Bool { sending.isEmpty && stuck.isEmpty && fonts.isEmpty && effects.isEmpty && different.isEmpty }
        /// What the editor can do: send and render, render anyway, or nothing (fix it first).
        var canSend: Bool { takesFiles && !sending.isEmpty && stuck.isEmpty }
        var canRenderAnyway: Bool { sending.isEmpty && stuck.isEmpty && !clean }
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
    /// to send when only here; files comps and grades read (`refs`) only here are `stuck` (the office may still take
    /// them at their path: `check`). LUTs in Resolve's LUT folder (`lutRoot`; relative ones are in it) that are here
    /// are `luts`, for the office to compare. `size`: a file's size here (nil: not on this Mac either, the office
    /// reports it). Resolve's own other folders (`builtIn`) are left out.
    nonisolated static func classify(media: [String], refs: [[String: Any]], proxies: Set<String>, shares: [(id: String, nas: String)],
                                     builtIn: [String], lutRoot: String = RemoteResolveProject.lutRoot, size: (String) -> Int64?)
        -> (files: [RemoteRenderQueue.Proxy], send: [LocalFile], stuck: [String], luts: [Placed]) {
        var files: [RemoteRenderQueue.Proxy] = [], send: [LocalFile] = [], stuck: [String] = [], luts: [Placed] = []
        let known = Set(proxies.map(RemoteResolveMap.normal))
        for file in Set(media).sorted() where !file.isEmpty && !known.contains(RemoteResolveMap.normal(file)) {
            if let place = onShare(file, shares: shares) {
                files.append(.init(file: file, share: place.share, path: place.path))
            } else if let bytes = size(file) {
                send.append(LocalFile(path: file, size: bytes))
            }
        }
        let media = Set(media)
        let lutBase = RemoteEditHost.realPath(lutRoot) ?? lutRoot
        for ref in refs where !["media", "blob"].contains(ref["regid"] as? String ?? "") {
            if ref["lut"] as? Bool == true, let path = ref["path"] as? String, !path.isEmpty {
                // (Relative: in the LUT folder. Absolute in it: the same relative path on the office, whose folder is the same.)
                var relative: String?
                if !path.hasPrefix("/") { relative = path } else {
                    for base in Set([lutRoot, lutBase]) where path.hasPrefix(base + "/") { relative = String(path.dropFirst(base.count + 1)) }
                }
                if let relative {
                    let full = lutRoot + "/" + relative
                    guard !luts.contains(where: { $0.path == relative }), !stuck.contains(full), let bytes = size(full) else { continue }
                    if lutRelative(relative, code: true) { luts.append(Placed(file: LocalFile(path: full, size: bytes), path: relative)) } else { stuck.append(full) }
                    continue
                }
            }
            guard let path = ref["path"] as? String, path.hasPrefix("/"), !media.contains(path), !stuck.contains(path),
                  !builtIn.contains(where: { path == $0 || path.hasPrefix($0 + "/") }), onShare(path, shares: shares) == nil, size(path) != nil else { continue }
            stuck.append(path)
        }
        return (files, send, stuck, luts)
    }

    /// The office's check of the LUTs (`luts`) and of the comp files only here (`plan.stuck`), with the fonts and
    /// effects: each the office has already is dropped, one it takes at its path goes in `placed`, one it has another
    /// file for in `different`; a comp file it has no share for stays stuck. An office from before answers none of it:
    /// the LUTs aren't sent (as before) and the comp files stay stuck.
    static func check(_ plan: inout Plan, luts: [Placed], fonts: [Font], effects: [Effect], client: OfficeRenderClient = .shared) async throws {
        let comps = plan.stuck
        guard !luts.isEmpty || !comps.isEmpty || !fonts.isEmpty || !effects.isEmpty else { return }
        let paths = luts.map(\.file.path) + comps
        let hashed = await Task.detached { paths.reduce(into: [String: String]()) { $0[$1] = try? RemoteSendInto.hash(URL(fileURLWithPath: $1)) } }.value
        plan.hashes.merge(hashed) { a, _ in a }
        func entry(_ path: String, _ sent: String) -> [String: Any] {
            ["path": sent, "size": RemoteDriveWriteHost.stamp(of: URL(fileURLWithPath: path))?.size ?? 0, "sha256": hashed[path] ?? ""]
        }
        let answer = try await client.ask("resolveMissing", ["fonts": fonts.map(\.dictionary), "effects": effects.map(\.dictionary),
                                                             "luts": luts.map { entry($0.file.path, $0.path) }, "comps": comps.map { entry($0, $0) }], timeout: 600)
        apply(answer, to: &plan, luts: luts)
    }

    /// The office's answer to `check` on the plan (its `stuck` still the comp files asked about).
    static func apply(_ answer: [String: Any], to plan: inout Plan, luts: [Placed]) {
        let comps = plan.stuck, hashed = plan.hashes
        plan.fonts = (answer["fonts"] as? [[String: Any]] ?? []).compactMap(Font.init)
        plan.effects = (answer["effects"] as? [[String: Any]] ?? []).compactMap(Effect.init)
        if let states = answer["luts"] as? [String], states.count == luts.count {
            for (lut, state) in zip(luts, states) {
                switch state {
                case "same": break
                // (A DCTL is compared, never sent: it's code.)
                case "missing" where hashed[lut.file.path] != nil && lutRelative(lut.path): plan.placed.append(lut)
                case "different": plan.different.append(lut.path)
                default: plan.stuck.append(lut.file.path)
                }
            }
        }
        guard let places = answer["comps"] as? [[String: Any]], places.count == comps.count else { return }
        plan.stuck = plan.stuck.filter { !comps.contains($0) }
        for (path, place) in zip(comps, places) {
            // (Sent under its own name: one the office finds under another, through a link, stays.)
            guard let share = place["share"] as? String, let there = place["path"] as? String, hashed[path] != nil,
                  (there as NSString).lastPathComponent == (path as NSString).lastPathComponent,
                  let bytes = RemoteDriveWriteHost.stamp(of: URL(fileURLWithPath: path))?.size else { plan.stuck.append(path); continue }
            switch place["state"] as? String {
            case "same": break
            case "missing": plan.placed.append(Placed(file: LocalFile(path: path, size: bytes), share: share, path: there, base: place["base"] as? String ?? ""))
            case "different": plan.different.append(there)
            default: plan.stuck.append(path)
            }
        }
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

    /// Sends LUTs into the office's LUT folder and comp files to their path in a share, each at exactly that name
    /// (resumed, checked; one the office got meanwhile under that name isn't replaced, and the render stops).
    static func send(_ placed: [Placed], hashes: [String: String], client: OfficeRenderClient = .shared,
                     progress: @escaping (String, Double) -> Void = { _, _ in }) async throws {
        var made = Set<String>()
        for item in placed {
            let url = URL(fileURLWithPath: item.file.path), name = (item.path as NSString).lastPathComponent
            let sha: String
            if let known = hashes[item.file.path] { sha = known } else { sha = try await Task.detached { try RemoteSendInto.hash(url) }.value }
            progress(item.file.name, 0)
            guard item.share.isEmpty else {
                // A comp file: the folders below its nearest one there, then Send Files Here's checked upload.
                let parent = (item.path as NSString).deletingLastPathComponent
                var path = item.base
                for part in String(parent.dropFirst(item.base.isEmpty ? 0 : item.base.count + 1)).split(separator: "/") {
                    path = path.isEmpty ? String(part) : path + "/" + part
                    if made.insert(item.share + "/" + path).inserted { _ = try await client.ask("driveFolder", ["share": item.share, "path": path]) }
                }
                let names = try await RemoteSendInto.send([url], share: item.share, path: parent, client: client, hashes: [url: sha], progress: progress)
                guard names.first == name else {
                    throw OfficeLink.Failure.office(String(localized: "Another file named “\(name)” is on the office Mac. It wasn’t replaced."))
                }
                continue
            }
            let file: [String: Any] = ["path": item.path, "size": item.file.size]
            var have = (try await client.ask("resolveLUT", file)["have"] as? NSNumber)?.int64Value ?? 0
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while true {
                try Task.checkCancellation()
                try handle.seek(toOffset: UInt64(have))
                let chunk = try handle.read(upToCount: OfficeLink.uploadChunk) ?? Data()
                var piece = file
                piece["offset"] = have
                piece["data"] = chunk.base64EncodedString()
                if have + Int64(chunk.count) == item.file.size { piece["sha256"] = sha }
                let answer = try await client.ask("resolveLUT", piece, timeout: 120)
                have = (answer["have"] as? NSNumber)?.int64Value ?? have
                progress(item.file.name, item.file.size > 0 ? Double(have) / Double(item.file.size) : 1)
                if answer["placed"] as? Bool == true { break }
                guard !chunk.isEmpty else { throw OfficeInbox.Problem.mismatch }
            }
        }
    }

    /// "Logo.mov, Whoosh.wav, … · 1.2 GB" for the list before sending.
    static func summary(_ files: [LocalFile]) -> String {
        let names = files.prefix(4).map(\.name).joined(separator: ", ") + (files.count > 4 ? ", …" : "")
        return names + " · " + ByteCountFormatter.string(fromByteCount: files.reduce(0) { $0 + $1.size }, countStyle: .file)
    }
}
