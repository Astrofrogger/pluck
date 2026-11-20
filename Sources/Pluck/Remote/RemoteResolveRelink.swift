import Foundation
import UserNotifications

/// Which local proxy stands for which original, from the manifests (share + path, never names).
enum RemoteResolveMap {
    nonisolated static func normal(_ path: String) -> String { (path as NSString).standardizingPath }

    /// What Resolve's link step gets for one pulled folder: per clip the original's path on the host
    /// (when the host's share root is known: clips of a host-built project get their proxy linked),
    /// the local proxy, and the bin it goes into (the share, then its folders).
    nonisolated static func links(_ manifest: RemoteManifest, proxyRoot: URL, originalRoot: String?) -> [[String: Any]] {
        // (Pulled originals and their parts aren't proxies.)
        manifest.entries.filter { $0.pieceOf == nil }.map { entry in
            var link: [String: Any] = ["proxy": normal(proxyRoot.appendingPathComponent(entry.proxy).path),
                                       "bin": RemoteResolveProject.bin(entry.path, share: manifest.shareName)]
            if let originalRoot { link["original"] = (originalRoot as NSString).appendingPathComponent(entry.path) }
            return link
        }
    }

    /// The local proxies among `files` (a project's clips) with the originals they stand for.
    nonisolated static func proxies(for files: [String], roots: [(manifest: RemoteManifest, root: URL)]) -> [RemoteRenderQueue.Proxy] {
        var known: [String: RemoteRenderQueue.Proxy] = [:]
        for (manifest, root) in roots {
            for entry in manifest.entries {
                let file = normal(root.appendingPathComponent(entry.proxy).path)
                known[file] = .init(file: file, share: entry.share, path: entry.path, piece: entry.range != nil ? true : nil)
            }
        }
        return files.compactMap { file in known[normal(file)].map { RemoteRenderQueue.Proxy(file: file, share: $0.share, path: $0.path, piece: $0.piece) } }
    }
}

/// The editor's side of the Resolve round trip: start from a project the host built or add the
/// pulled proxies to the open project, check projects out and in, and render on the host.
@MainActor
@Observable
final class RemoteResolve {
    static let shared = RemoteResolve()
    private static let rootsKey = "remoteResolveHostRoots"

    /// Set at launch: links a pulled (or mounted) proxy folder into the project open in Resolve.
    static func install() {
        RemoteHooks.linkInResolve = { root in _ = try await shared.link(root) }
    }

    struct Version: Hashable {
        var number: Int
        var date: Date
        var by: String
        var size: Int64
        var restoredFrom: Int?
    }

    struct HostProject: Identifiable, Hashable {
        var id: String
        var name: String
        var latest: Int
        var versions: [Version]
        var holder: String?
        var mine: Bool

        init?(_ value: [String: Any]) {
            guard let id = value["id"] as? String else { return nil }
            self.id = id
            name = value["name"] as? String ?? ""
            latest = value["latest"] as? Int ?? 0
            holder = value["holder"] as? String
            mine = value["mine"] as? Bool ?? false
            versions = (value["versions"] as? [[String: Any]] ?? []).map {
                let from = $0["restoredFrom"] as? Int ?? 0
                return Version(number: $0["number"] as? Int ?? 0, date: Date(timeIntervalSince1970: $0["date"] as? Double ?? 0),
                               by: $0["by"] as? String ?? "", size: ($0["size"] as? NSNumber)?.int64Value ?? 0, restoredFrom: from > 0 ? from : nil)
            }
        }
    }

    struct QueueItem: Identifiable, Equatable {
        var id: String
        var project: String
        var version: Int
        var timeline: String
        var preset: String
        var device: String
        var mine: Bool
        var state: String
        var progress: Double
        var remaining: Double?
        var problems: [String]
        var file: String?
        var previewSize: Int64?
        var makingPreview: Bool
        var position: Int?

        var open: Bool { ["queued", "preparing", "rendering"].contains(state) }

        init?(_ value: [String: Any]) {
            guard let id = value["id"] as? String else { return nil }
            self.id = id
            project = value["project"] as? String ?? ""
            version = value["version"] as? Int ?? 0
            timeline = value["timeline"] as? String ?? ""
            preset = value["preset"] as? String ?? ""
            device = value["device"] as? String ?? ""
            mine = value["mine"] as? Bool ?? false
            state = value["state"] as? String ?? ""
            progress = value["progress"] as? Double ?? 0
            remaining = value["remaining"] as? Double
            problems = value["problems"] as? [String] ?? []
            file = value["file"] as? String
            previewSize = (value["previewSize"] as? NSNumber)?.int64Value
            makingPreview = value["makingPreview"] as? Bool ?? false
            position = value["position"] as? Int
        }
    }

    /// The project open in DaVinci Resolve on this Mac.
    struct Local: Equatable {
        var project: String
        var saved: Bool
        var timelines: [String]
        var timeline: String?
        var files: [String]
    }

    private(set) var projects: [HostProject] = []
    private(set) var queue: [QueueItem] = []
    private(set) var presets: [String] = []
    private(set) var local: Local?
    /// Shares with a local proxy folder (pulled or mounted), and how many clips each has.
    private(set) var linkable: [(share: String, name: String, clips: Int)] = []
    /// What's being done now, for the pane.
    private(set) var step: String?
    private(set) var lastLink: (linked: Int, added: Int)?
    @ObservationIgnored private var following: Task<Void, Never>?

    private var client: OfficeRenderClient { .shared }

    private init() {}

    // MARK: - Local proxy folders

    /// Each share's proxy folder of its current mode; `everyMode` adds the pulled and the mounted one too
    /// (a project cut before switching Download/Stream still has clips in the other).
    private func roots(everyMode: Bool = false) async -> [(manifest: RemoteManifest, root: URL)] {
        let shares = (try? await client.shares()) ?? []
        var found: [(RemoteManifest, URL)] = []
        for share in shares {
            var places = [await RemoteHooks.proxyRoot(share.id)]
            if everyMode {
                places.append(RemoteHooks.pulledProxyRoot?(share.id))
                if case .mounted(let mounted) = RemoteNetwork.shared.state(share.id) { places.append(mounted.root) }
            }
            var seen = Set<String>()
            for case let root? in places where seen.insert(RemoteResolveMap.normal(root.path)).inserted {
                if let manifest = RemoteManifest.load(in: root) { found.append((manifest, root)) }
            }
        }
        return found
    }

    /// Where the host keeps a share's originals (as a project built there has them), remembered for offline use.
    private func hostRoot(_ share: String) async -> String? {
        var known = UserDefaults.standard.dictionary(forKey: Self.rootsKey) as? [String: String] ?? [:]
        if let root = (try? await client.ask("resolveRoot", ["share": share]))?["root"] as? String {
            known[share] = root
            UserDefaults.standard.set(known, forKey: Self.rootsKey)
        }
        return known[share]
    }

    /// Links the proxies of one local folder (with its manifest) into the open Resolve project.
    func link(_ root: URL) async throws -> (linked: Int, added: Int) {
        guard let manifest = RemoteManifest.load(in: root) else {
            throw OfficeLink.Failure.office(String(localized: "Those proxies have no list of their originals. Fetch them again."))
        }
        let answer = try await RemoteResolveScript.run(["action": "link", "entries": RemoteResolveMap.links(manifest, proxyRoot: root, originalRoot: await hostRoot(manifest.share))])
        let result = (answer["linked"] as? Int ?? 0, answer["added"] as? Int ?? 0)
        lastLink = result
        return result
    }

    /// Every share's local proxies into the open project (a bin per share).
    func addFootage() async throws {
        step = String(localized: "Adding footage…")
        defer { step = nil }
        let found = await roots()
        guard !found.isEmpty else { throw OfficeLink.Failure.office(String(localized: "No proxies on this Mac yet. Fetch some first.")) }
        var total = (linked: 0, added: 0)
        for (_, root) in found {
            let one = try await link(root)
            total = (total.linked + one.linked, total.added + one.added)
        }
        lastLink = total
        await readLocal()
    }

    // MARK: - Reading

    func refresh() async throws {
        let answer = try await client.ask("resolveProjects")
        projects = (answer["projects"] as? [[String: Any]] ?? []).compactMap(HostProject.init)
        let fresh = ((try await client.ask("resolveQueue"))["queue"] as? [[String: Any]] ?? []).compactMap(QueueItem.init)
        for item in fresh where item.mine {
            if let before = queue.first(where: { $0.id == item.id }), before.state != item.state || (before.makingPreview && !item.makingPreview) {
                announce(item)
            }
        }
        queue = fresh
        if queue.contains(where: { $0.mine && ($0.open || $0.makingPreview) }) { follow() }
    }

    /// Which shares have local proxies (may mount a network folder: not on every refresh).
    func scanFolders() async {
        linkable = await roots().map { ($0.manifest.share, $0.manifest.shareName, $0.manifest.entries.count) }
    }

    func loadPresets() async throws {
        presets = (try await client.ask("resolvePresets", timeout: 120))["presets"] as? [String] ?? []
    }

    func readLocal() async {
        guard let answer = try? await RemoteResolveScript.run(["action": "current"]) else { local = nil; return }
        local = Local(project: answer["project"] as? String ?? "", saved: answer["saved"] as? Bool ?? false,
                      timelines: answer["timelines"] as? [String] ?? [], timeline: answer["timeline"] as? String,
                      files: answer["files"] as? [String] ?? [])
    }

    // MARK: - XML from Premiere Pro or Final Cut Pro

    /// Sends an exported XML to render on the host with `preset`: its proxies mapped to their originals (RemoteXML).
    /// Answers the paths that weren't this Mac's proxies (left as they are). A host from before can't.
    func renderXML(_ text: String, name: String, timeline: String, preset: String) async throws -> [String] {
        let proxies = RemoteResolveMap.proxies(for: RemoteXML.files(text), roots: await roots(everyMode: true))
        let answer: [String: Any]
        do {
            answer = try await client.ask(RemoteXML.action, ["xml": text, "name": name, "timeline": timeline, "preset": preset,
                                                             "proxies": proxies.map { ["file": $0.file, "share": $0.share, "path": $0.path] }], timeout: 300)
        } catch OfficeLink.Failure.office(let message) where message == String(localized: "The host Mac doesn’t know how to do that.") {
            throw OfficeLink.Failure.office(String(localized: "The host Mac’s Pluck is too old to render XML. Update it there."))
        }
        try await refresh()
        follow()
        return answer["unknown"] as? [String] ?? []
    }

    // MARK: - Parts of originals

    /// The originals the timeline open in Resolve uses (through this Mac's proxies), each as its used part plus handles
    /// or whole with why (RemotePieces.plan).
    func usedParts(timeline: String?) async throws -> [RemotePieces.Item] {
        var instruction: [String: Any] = ["action": "ranges"]
        if let timeline, !timeline.isEmpty { instruction["timeline"] = timeline }
        let found = RemotePieces.uses(try await RemoteResolveScript.run(instruction))
        return RemotePieces.plan(found.uses, whole: found.whole, roots: await roots(everyMode: true), handles: RemotePieces.handles)
    }

    // MARK: - Starting

    /// A new project the host builds from a shared folder's originals, opened here with the local proxies.
    func build(share: String, path: String) async throws {
        step = String(localized: "The host Mac is building the project…")
        defer { step = nil }
        let answer = try await client.ask("resolveBuild", ["share": share, "path": path], timeout: 1800)
        guard let project = (answer["project"] as? [String: Any]).flatMap(HostProject.init) else { throw OfficeLink.Failure.garbled }
        try await open(project, version: project.latest)
        try await refresh()
    }

    /// A version of a host project imported into Resolve here, its proxies linked to this Mac's.
    func open(_ project: HostProject, version: Int) async throws {
        step = String(localized: "Opening in DaVinci Resolve…")
        defer { step = nil }
        let file = try await download(project, version: version)
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await RemoteResolveScript.run(["action": "open", "drp": file.path, "name": project.name])
        for (_, root) in await roots() { _ = try await link(root) }
        await readLocal()
    }

    private func download(_ project: HostProject, version: Int) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Pluck Resolve", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(UUID().uuidString + ".drp")
        var data = Data(), size = Int64.max
        while Int64(data.count) < size {
            let answer = try await client.ask("resolveVersionData", ["id": project.id, "version": version, "offset": data.count])
            guard let piece = answer[OfficeActions.bytesKey] as? Data, let total = (answer["size"] as? NSNumber)?.int64Value else { throw OfficeLink.Failure.garbled }
            size = total
            if piece.isEmpty { break }
            data.append(piece)
        }
        guard Int64(data.count) == size else { throw OfficeLink.Failure.garbled }
        try data.write(to: file)
        return file
    }

    // MARK: - Check-out, check-in, versions

    func checkOut(_ project: HostProject) async throws {
        _ = try await client.ask("resolveCheckout", ["id": project.id])
        try await refresh()
    }

    func release(_ project: HostProject) async throws {
        _ = try await client.ask("resolveRelease", ["id": project.id])
        try await refresh()
    }

    func restore(_ project: HostProject, version: Int) async throws {
        _ = try await client.ask("resolveRestore", ["id": project.id, "version": version])
        try await refresh()
    }

    /// The project open in Resolve here sent as the newest version of `project` (nil: a new project).
    /// `keep`: stays checked out to this Mac. Returns the project's id and the version made.
    @discardableResult
    func checkIn(_ project: HostProject?, keep: Bool) async throws -> (id: String, version: Int) {
        step = String(localized: "Sending the project…")
        defer { step = nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Pluck Resolve", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(UUID().uuidString + ".drp")
        defer { try? FileManager.default.removeItem(at: file) }
        let exported = try await RemoteResolveScript.run(["action": "export", "drp": file.path])
        let data = try Data(contentsOf: file)
        let token = UUID().uuidString
        var have = 0
        while have < data.count {
            let piece = data.subdata(in: have..<min(have + OfficeLink.uploadChunk, data.count))
            let answer = try await client.ask("resolveUpload", ["token": token, "offset": have, "data": piece.base64EncodedString()])
            guard let now = (answer["have"] as? NSNumber)?.intValue, now > have else { throw OfficeLink.Failure.garbled }
            have = now
        }
        var arguments: [String: Any] = ["token": token, "size": data.count, "keep": keep,
                                        "name": project?.name ?? exported["project"] as? String ?? "Project"]
        if let project { arguments["id"] = project.id }
        if project == nil, let share = await roots().first?.manifest.share { arguments["share"] = share }
        let answer = try await client.ask("resolveCheckin", arguments)
        try await refresh()
        guard let id = (answer["project"] as? [String: Any])?["id"] as? String, let version = answer["version"] as? Int else { throw OfficeLink.Failure.garbled }
        return (id, version)
    }

    // MARK: - Rendering on the host

    /// Sends the open project as a new version of `project` (kept checked out) and queues a render of
    /// exactly that version, with which local proxy stands for which original.
    func render(_ project: HostProject?, timeline: String, preset: String) async throws {
        await readLocal()
        guard let local else { throw OfficeLink.Failure.office(String(localized: "No project is open in DaVinci Resolve.")) }
        let proxies = RemoteResolveMap.proxies(for: local.files, roots: await roots(everyMode: true))
        let made = try await checkIn(project, keep: true)
        step = String(localized: "Adding to the queue…")
        defer { step = nil }
        _ = try await client.ask("resolveRender", ["id": made.id, "version": made.version, "timeline": timeline, "preset": preset,
                                                   "proxies": proxies.map { ["file": $0.file, "share": $0.share, "path": $0.path, "piece": $0.piece == true] }])
        try await refresh()
        follow()
    }

    func cancel(_ item: QueueItem) async throws {
        _ = try await client.ask("resolveCancel", ["id": item.id])
        try await refresh()
    }

    /// Fetches a render's preview into the Downloads folder; `progress` gets 0…1.
    func downloadPreview(_ item: QueueItem, progress: @escaping (Double) -> Void) async throws -> URL {
        let folder = UserDefaults.standard.string(forKey: Prefs.downloadPath) ?? NSHomeDirectory() + "/Downloads"
        let target = Converting.outputURL(folder: folder, name: Folders.sanitize(item.timeline) + String(localized: " (preview)"), fileExtension: "mp4")
        var data = Data(), size = Int64.max
        while Int64(data.count) < size {
            let answer = try await client.ask("resolvePreview", ["id": item.id, "offset": data.count])
            guard let piece = answer[OfficeActions.bytesKey] as? Data, let total = (answer["size"] as? NSNumber)?.int64Value else { throw OfficeLink.Failure.garbled }
            size = total
            if piece.isEmpty { break }
            data.append(piece)
            progress(Double(data.count) / Double(max(size, 1)))
        }
        try data.write(to: target)
        return target
    }

    /// Checks every few seconds while a render from this Mac is waiting or going.
    private func follow() {
        guard following == nil else { return }
        following = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                try? await refresh()
                if !queue.contains(where: { $0.mine && ($0.open || $0.makingPreview) }) { break }
            }
            following = nil
        }
    }

    private func announce(_ item: QueueItem) {
        guard UserDefaults.standard.bool(forKey: Prefs.notify), Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        switch item.state {
        case "done" where item.makingPreview: return
        case "done":
            content.title = String(localized: "Rendered on the host Mac")
            content.body = item.previewSize != nil ? String(localized: "\(item.timeline) is ready. The preview can be downloaded in Pluck.") : item.timeline
        case "problems":
            content.title = String(localized: "The host Mac didn’t render: check the footage")
            content.body = item.problems.first ?? item.timeline
        case "failed":
            content.title = String(localized: "The render on the host Mac failed")
            content.body = item.problems.first ?? item.timeline
        default: return
        }
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
