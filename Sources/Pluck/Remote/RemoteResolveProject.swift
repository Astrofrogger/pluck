import Foundation

/// The host's side of the Resolve round trip: builds a project from a share's originals with the
/// proxies linked, keeps editors' projects (RemoteCheckout) and queues their renders
/// (RemoteRenderQueue). Proxies are matched to originals by share + path (the editor's manifest),
/// never by file name, and every path from a paired Mac is checked to stay in its share.
@MainActor
enum RemoteResolveProject {
    static func register() {
        let checkout = RemoteCheckout.shared, queue = RemoteRenderQueue.shared
        Task.detached { tidyUploads() }
        OfficeActions.register("resolveRoot") { arguments, device in
            try OfficeActions.require(\.browse, device)
            // (The originals' place on the host, as Resolve has it in a project built here.)
            return ["root": try RemoteEditHost.share(arguments["share"]).root.path]
        }
        OfficeActions.register("resolvePresets") { _, device in
            try OfficeActions.require(\.render, device)
            return ["presets": try await RemoteResolveScript.run(["action": "presets"])["presets"] ?? []]
        }
        OfficeActions.register("resolveBuild") { arguments, device in
            try OfficeActions.require(\.proxies, device)
            return try await build(arguments, device)
        }
        OfficeActions.register("resolveProjects") { _, device in
            ["projects": checkout.projects.map { $0.summary(for: device.id) }]
        }
        OfficeActions.register("resolveCheckout") { arguments, device in
            try OfficeActions.require(\.render, device)
            return ["project": try checkout.checkOut(try uuid(arguments["id"]), by: device.id, name: device.name).summary(for: device.id)]
        }
        OfficeActions.register("resolveRelease") { arguments, device in
            try OfficeActions.require(\.render, device)
            try checkout.release(try uuid(arguments["id"]), by: device.id)
            return ["released": true]
        }
        OfficeActions.register("resolveUpload") { arguments, device in
            try OfficeActions.require(\.render, device)
            guard let data = (arguments["data"] as? String).flatMap({ Data(base64Encoded: $0) }), data.count <= OfficeLink.uploadChunk else {
                throw OfficeActions.incomplete()
            }
            return ["have": try receive(try uuid(arguments["token"]), offset: try OfficeActions.number(arguments["offset"]), data: data, from: device.id)]
        }
        OfficeActions.register("resolveCheckin") { arguments, device in
            try OfficeActions.require(\.render, device)
            let upload = try uploaded(try uuid(arguments["token"]), from: device.id)
            guard (try? FileManager.default.attributesOfItem(atPath: upload.path)[.size] as? NSNumber)?.int64Value == (try OfficeActions.number(arguments["size"])) else {
                throw OfficeActions.incomplete()
            }
            let id = try (arguments["id"] as? String).map { try uuid($0) }
            let share = try (arguments["share"] as? String).map { try RemoteEditHost.share($0).id }
            let (project, version) = try checkout.checkIn(id, name: try OfficeActions.text(arguments["name"], 200), share: share, file: upload,
                                                          by: device.id, deviceName: device.name, keep: arguments["keep"] as? Bool ?? false)
            return ["project": project.summary(for: device.id), "version": version.number]
        }
        OfficeActions.register("resolveRestore") { arguments, device in
            try OfficeActions.require(\.render, device)
            let made = try checkout.restore(try uuid(arguments["id"]), version: Int(try OfficeActions.number(arguments["version"])),
                                            by: device.id, deviceName: device.name)
            return ["version": made.number]
        }
        OfficeActions.register("resolveVersionData") { arguments, device in
            try OfficeActions.require(\.browse, device)
            let id = try uuid(arguments["id"])
            _ = try checkout.project(id)
            return try await piece(checkout.file(id, version: Int(try OfficeActions.number(arguments["version"]))),
                                   offset: try OfficeActions.number(arguments["offset"] ?? 0))
        }
        OfficeActions.register("resolveRender") { arguments, device in
            try OfficeActions.require(\.render, device)
            let id = try uuid(arguments["id"]), version = Int(try OfficeActions.number(arguments["version"]))
            let project = try checkout.project(id)
            guard project.versions.contains(where: { $0.number == version }) else {
                throw OfficeLink.Failure.office(String(localized: "That version isn’t on the host Mac any more."))
            }
            let proxies = (arguments["proxies"] as? [[String: Any]] ?? []).prefix(20_000).compactMap { value -> RemoteRenderQueue.Proxy? in
                guard let file = value["file"] as? String, let share = value["share"] as? String, let path = value["path"] as? String,
                      file.count < 2000, share.count <= 40, path.count < 2000 else { return nil }
                return .init(file: file, share: share, path: path)
            }
            let item = queue.add(.init(project: id, projectName: project.name, version: version, timeline: try OfficeActions.text(arguments["timeline"], 300),
                                       preset: try OfficeActions.text(arguments["preset"], 300), share: project.share, proxies: Array(proxies),
                                       device: device.name, deviceID: device.id))
            return ["job": item.summary(for: device.id, position: queue.position(item.id))]
        }
        OfficeActions.register("resolveQueue") { _, device in
            ["queue": queue.items.suffix(60).reversed().map { $0.summary(for: device.id, position: queue.position($0.id)) }]
        }
        OfficeActions.register("resolveCancel") { arguments, device in
            try await queue.cancel(try uuid(arguments["id"]), by: device.id)
            return ["cancelled": true]
        }
        OfficeActions.register("resolvePreview") { arguments, device in
            let id = try uuid(arguments["id"])
            guard let path = queue.items.first(where: { $0.id == id && $0.deviceID == device.id })?.preview else {
                throw OfficeLink.Failure.office(String(localized: "There’s no preview for that render (yet)."))
            }
            return try await piece(URL(fileURLWithPath: path), offset: try OfficeActions.number(arguments["offset"] ?? 0))
        }
    }

    /// The name a remote's project gets in the host's Resolve: its project id in it, so no remote can replace
    /// (or delete) the owner's own project or another editor's by naming one alike.
    static func hostName(_ name: String, id: UUID) -> String {
        "Pluck – " + Folders.sanitize(name) + " – " + id.uuidString.prefix(8)
    }

    private static func uuid(_ value: Any?) throws -> UUID {
        guard let id = UUID(uuidString: try OfficeActions.text(value, 40)) else { throw OfficeActions.incomplete() }
        return id
    }

    /// Up to OfficeLink.fileChunk raw bytes of a file on this Mac, with its size.
    private static func piece(_ file: URL, offset: Int64) async throws -> [String: Any] {
        try await Task.detached { () -> [String: Any] in
            guard let handle = FileHandle(forReadingAtPath: file.path),
                  let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value else {
                throw OfficeLink.Failure.office(String(localized: "That file isn’t ready on the host Mac (yet)."))
            }
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(min(offset, size)))
            return [OfficeActions.bytesKey: try handle.read(upToCount: OfficeLink.fileChunk) ?? Data(), "size": size]
        }.value
    }

    // MARK: - Uploads (a project file, piece by piece)

    /// Project files a Mac is still sending: at most this many per Mac (a new one pushes out its oldest).
    static let uploadsPerDevice = 3

    nonisolated static var uploads: URL { RemoteRenderQueue.support.appendingPathComponent("Resolve Uploads", isDirectory: true) }

    private static func uploaded(_ token: UUID, from device: UUID) throws -> URL {
        uploads.appendingPathComponent("\(device.uuidString)-\(token.uuidString).drp")
    }

    /// Appends a piece at `offset` (the size so far, else it's ignored); answers the size so far.
    static func receive(_ token: UUID, offset: Int64, data: Data, from device: UUID) throws -> Int64 {
        let file = try uploaded(token, from: device)
        try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) {
            let keys: Set<URLResourceKey> = [.contentModificationDateKey]
            let open = ((try? FileManager.default.contentsOfDirectory(at: uploads, includingPropertiesForKeys: Array(keys))) ?? [])
                .filter { $0.lastPathComponent.hasPrefix(device.uuidString + "-") }
                .sorted { ((try? $0.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast)
                        < ((try? $1.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast) }
            for old in open.prefix(max(open.count - uploadsPerDevice + 1, 0)) { try? FileManager.default.removeItem(at: old) }
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: file.path) else { throw OfficeActions.incomplete() }
        defer { try? handle.close() }
        let size = Int64(try handle.seekToEnd())
        guard offset == size else { return size }
        guard size + Int64(data.count) <= 2 << 30 else { throw OfficeLink.Failure.office(String(localized: "That project file is too big.")) }
        try handle.write(contentsOf: data)
        return size + Int64(data.count)
    }

    /// Uploads left unfinished for a day go (at launch).
    nonisolated static func tidyUploads() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        for file in (try? FileManager.default.contentsOfDirectory(at: uploads, includingPropertiesForKeys: Array(keys))) ?? []
        where Date.now.timeIntervalSince((try? file.resourceValues(forKeys: keys).contentModificationDate) ?? .now) > 86_400 {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - A new project from the originals

    /// {share, path ("" = whole share)}: every video under it imported (bins mirror the folders), the
    /// host's proxy linked to each, exported, and kept as version 1 of a new project checked out to the asker.
    private static func build(_ arguments: [String: Any], _ device: OfficeRenderServer.Device) async throws -> [String: Any] {
        let (root, id) = try RemoteEditHost.share(arguments["share"])
        let path = try OfficeActions.text(arguments["path"], empty: true)
        let folder = try RemoteEditHost.resolve(path, in: root)
        let shareName = root.lastPathComponent
        let videos = try await Task.detached { try videos(in: folder, root: root) }.value
        guard !videos.isEmpty else { throw OfficeLink.Failure.office(String(localized: "There are no clips in that folder.")) }
        let files: [[String: Any]] = videos.map { relative in
            var file: [String: Any] = ["path": root.appendingPathComponent(relative).path, "bin": bin(relative, share: shareName)]
            if let proxy = [OfficeProxies.Format.light, .prores].lazy.map({ OfficeProxies.shared.proxy(relative, folder: id, format: $0) })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }) { file["proxy"] = proxy.path }
            return file
        }
        let title = path.isEmpty ? shareName : folder.lastPathComponent
        let drp = uploads.appendingPathComponent(UUID().uuidString + ".drp")
        try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
        let projectID = UUID()
        let answer = try await RemoteResolveScript.run(["action": "build", "name": hostName(title, id: projectID), "files": files, "drp": drp.path])
        let (project, _) = try RemoteCheckout.shared.checkIn(nil, name: title, share: id, file: drp, by: device.id, deviceName: device.name, keep: true,
                                                             newID: projectID)
        return ["project": project.summary(for: device.id), "root": root.path, "imported": answer["imported"] ?? 0,
                "linked": answer["linked"] ?? 0, "clips": videos.count]
    }

    /// The bin a clip goes into: the share, then the folders of its path.
    nonisolated static func bin(_ relative: String, share: String) -> [String] {
        [share] + relative.split(separator: "/").dropLast().map(String.init)
    }

    /// Share-relative paths of the videos under a folder (hidden and NAS system folders left out).
    nonisolated static func videos(in folder: URL, root: URL) throws -> [String] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [String] = []
        for case let url as URL in walker {
            if RemoteEditHost.systemNames.contains(url.lastPathComponent) || OfficeInbox.holds(OfficeInbox.real(url)) { walker.skipDescendants(); continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, Converting.isVideo(url) else { continue }
            found.append(RemoteEditHost.relative(url.resolvingSymlinksInPath(), in: root))
            if found.count >= 5000 { break }
        }
        return found.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Renders go into the share (a "Renders" folder, a folder per project), or the render folder.
    static func renderFolder(share: String?, project: String) throws -> URL {
        if let share, let root = try? RemoteEditHost.share(share).root, FileManager.default.fileExists(atPath: root.path) {
            return root.appendingPathComponent("Renders", isDirectory: true).appendingPathComponent(Folders.sanitize(project), isDirectory: true)
        }
        guard let folder = OfficeRenderServer.shared.renderFolder else {
            throw OfficeLink.Failure.office(String(localized: "No render folder is set on the host Mac yet. Choose one there in Edit Anywhere."))
        }
        return folder.appendingPathComponent(Folders.sanitize(project), isDirectory: true)
    }

    // MARK: - Conform check

    /// A media pool clip as Resolve reports it (strings from GetClipProperty).
    struct Clip: Hashable, Sendable {
        var id: String
        var name: String
        var file: String
        var frames: Double?
        var fps: Double?
        var audio: Int?
        var timecode: String?

        init(id: String, name: String, file: String, frames: Double? = nil, fps: Double? = nil, audio: Int? = nil, timecode: String? = nil) {
            (self.id, self.name, self.file, self.frames, self.fps, self.audio, self.timecode) = (id, name, file, frames, fps, audio, timecode)
        }

        init(_ value: [String: Any]) {
            func text(_ key: String) -> String { value[key] as? String ?? "" }
            self.init(id: text("id"), name: text("name"), file: text("file"), frames: Double(text("frames")), fps: Double(text("fps")),
                      audio: Int(text("audio")), timecode: text("tc").isEmpty ? nil : text("tc"))
        }

        var duration: Double? { frames.flatMap { frames in fps.flatMap { $0 > 0 ? frames / $0 : nil } } }
    }

    /// What the host knows of an original (from mediaInfo); present = the file is there.
    struct Original: Sendable {
        var duration: Double?
        var audio: Int?
        var timecode: String?
    }

    /// Which clips to swap for which original (clip id → original path) and what's wrong.
    /// `swaps`: a clip's file (a proxy on the editor's Mac) → the original's path on the host.
    /// `originals`: files on the host that are there and usable (originals, and files already in a share).
    nonisolated static func conform(_ clips: [Clip], swaps: [String: String], originals: [String: Original]) -> (swaps: [String: String], problems: [String]) {
        var result: [String: String] = [:], problems: [String] = [], told: Set<String> = []
        func tell(_ clip: Clip, _ problem: String) {
            if told.insert(clip.file).inserted { problems.append(problem) }
        }
        for clip in clips {
            // A media pool clip with no file (compound, Fusion, generated): what it reads isn't known, so no render.
            guard !clip.file.isEmpty else {
                problems.append(String(localized: "\(clip.name): a compound, Fusion or generated clip, which the host Mac doesn’t render for other Macs."))
                continue
            }
            guard let original = swaps[clip.file] else {
                if originals[clip.file] == nil { tell(clip, String(localized: "\(clip.name): offline on the host Mac.")) }
                continue
            }
            guard let info = originals[original] else {
                tell(clip, String(localized: "\(clip.name): the original is missing on the host Mac."))
                continue
            }
            if let a = clip.duration, let b = info.duration, abs(a - b) > max(2 / (clip.fps ?? 25), 0.1) {
                tell(clip, String(localized: "\(clip.name): the original has another length."))
            } else if let a = clip.audio, let b = info.audio, a != b {
                tell(clip, String(localized: "\(clip.name): \(a) audio channels, the original has \(b)."))
            } else if let a = clip.timecode, let b = info.timecode, normal(a) != normal(b) {
                tell(clip, String(localized: "\(clip.name): the timecode differs from the original."))
            }
            result[clip.id] = original
        }
        return (result, problems)
    }

    nonisolated private static func normal(_ timecode: String) -> String { timecode.replacingOccurrences(of: ";", with: ":") }

    /// The conform check on this host: each proxy's original looked up in its share (and checked to
    /// stay in it), other files kept only when they are in a share here.
    static func conform(_ clips: [Clip], proxies: [RemoteRenderQueue.Proxy]) async -> (swaps: [String: String], problems: [String]) {
        var swaps: [String: String] = [:], originals: [String: Original] = [:]
        for proxy in proxies {
            guard let root = try? RemoteEditHost.share(proxy.share).root else { swaps[proxy.file] = proxy.path; continue }
            guard let original = try? RemoteEditHost.resolve(proxy.path, in: root) else { swaps[proxy.file] = root.path + "/" + proxy.path; continue }
            swaps[proxy.file] = original.path
            guard originals[original.path] == nil, clips.contains(where: { $0.file == proxy.file }) else { continue }
            let info = (try? await RemoteEditHost.mediaInfo(original)) ?? [:]
            originals[original.path] = Original(duration: info["duration"] as? Double, audio: info["audioChannels"] as? Int, timecode: info["timecode"] as? String)
        }
        let roots = OfficeArchive.shared.folders.compactMap { RemoteEditHost.realPath($0.path) }
        for clip in clips where !clip.file.isEmpty && swaps[clip.file] == nil {
            if let real = RemoteEditHost.realPath(clip.file), roots.contains(where: { real.hasPrefix($0 + "/") }) { originals[clip.file] = Original() }
        }
        return conform(clips, swaps: swaps, originals: originals)
    }
}
