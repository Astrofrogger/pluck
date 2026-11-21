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
                known[file] = .init(file: file, share: entry.share, path: entry.path, piece: entry.range != nil ? true : nil, first: entry.range?.first)
            }
        }
        return files.compactMap { file in known[normal(file)].map { RemoteRenderQueue.Proxy(file: file, share: $0.share, path: $0.path, piece: $0.piece, first: $0.first) } }
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
        /// The share it was made for (nil from an older office).
        var share: String?

        init?(_ value: [String: Any]) {
            guard let id = value["id"] as? String else { return nil }
            self.id = id
            share = value["share"] as? String
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
    /// The office takes missing files with a render and checks fonts and effects (RemoteMissing).
    private(set) var takesFiles = false
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
        let queued = try await client.ask("resolveQueue")
        takesFiles = queued["sendMissing"] as? Bool == true
        let fresh = (queued["queue"] as? [[String: Any]] ?? []).compactMap(QueueItem.init)
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

    /// Before a render: which files the office lacks (only on this Mac), which are on a share it has, and which fonts
    /// and effects it hasn't installed (RemoteMissing). Reads the open project only (an exported copy), never changes it.
    func preflight() async throws -> RemoteMissing.Plan {
        step = String(localized: "Checking what the office Mac needs…")
        defer { step = nil }
        await readLocal()
        guard let local else { throw OfficeLink.Failure.office(String(localized: "No project is open in DaVinci Resolve.")) }
        var plan = RemoteMissing.Plan(proxies: RemoteResolveMap.proxies(for: local.files, roots: await roots(everyMode: true)))
        let found = try await RemoteResolveScript.run(["action": "uses"])
        let shares = ((try? await client.shares()) ?? []).compactMap { share in share.nas.map { (id: share.id, nas: $0) } }
        let sorted = RemoteMissing.classify(media: found["files"] as? [String] ?? local.files, refs: found["refs"] as? [[String: Any]] ?? [],
                                            proxies: Set(plan.proxies.map(\.file)), shares: shares, builtIn: RemoteResolveProject.builtInRoots) { path in
            RemoteDriveWriteHost.stamp(of: URL(fileURLWithPath: path))?.size
        }
        (plan.files, plan.send, plan.stuck) = sorted
        try? await refresh()
        plan.takesFiles = takesFiles
        if takesFiles {
            let fonts = RemoteMissing.fonts(found), effects = RemoteMissing.effects(found)
            if !fonts.isEmpty || !effects.isEmpty {
                let answer = try await client.ask("resolveMissing", ["fonts": fonts.map(\.dictionary), "effects": effects.map(\.dictionary)], timeout: 120)
                plan.fonts = (answer["fonts"] as? [[String: Any]] ?? []).compactMap(RemoteMissing.Font.init)
                plan.effects = (answer["effects"] as? [[String: Any]] ?? []).compactMap(RemoteMissing.Effect.init)
            }
        }
        return plan
    }

    /// Sends the open project as a new version of `project` (kept checked out) and queues a render of
    /// exactly that version, with which local proxy stands for which original. With a pre-flight `plan`: its files
    /// only on this Mac are sent first, and its path map goes with the render; `anyway`: missing fonts and effects don't stop it.
    func render(_ project: HostProject?, timeline: String, preset: String, plan: RemoteMissing.Plan? = nil, anyway: Bool = false) async throws {
        await readLocal()
        guard let local else { throw OfficeLink.Failure.office(String(localized: "No project is open in DaVinci Resolve.")) }
        var proxies = plan?.proxies ?? []
        if plan == nil { proxies = RemoteResolveMap.proxies(for: local.files, roots: await roots(everyMode: true)) }
        var files = plan?.files ?? []
        let firstShare = plan?.canSend == true && project?.share == nil ? (try? await client.shares())?.first?.id : nil
        if let plan, plan.canSend {
            let mac = Host.current().localizedName ?? "Mac"
            guard let target = RemoteMissing.target(proxies: proxies, share: project?.share ?? firstShare, mac: mac) else {
                throw OfficeLink.Failure.office(String(localized: "There’s no share on the office Mac to send the files to."))
            }
            defer { step = nil }
            files += try await RemoteMissing.send(plan.send, to: target, client: client) { name, fraction in
                Task { @MainActor in self.step = String(localized: "Sending \(name)… \(Int(fraction * 100))%") }
            }
        }
        let made = try await checkIn(project, keep: true)
        step = String(localized: "Adding to the queue…")
        defer { step = nil }
        var arguments: [String: Any] = ["id": made.id, "version": made.version, "timeline": timeline, "preset": preset,
                                        "proxies": proxies.map { ["file": $0.file, "share": $0.share, "path": $0.path, "piece": $0.piece == true] }]
        // (New fields: an office from before ignores them, and refuses with its list as it did.)
        if !files.isEmpty { arguments["files"] = files.map { ["file": $0.file, "share": $0.share, "path": $0.path] } }
        if anyway { arguments["anyway"] = true }
        _ = try await client.ask("resolveRender", arguments)
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
            if piece.isEmpty { throw OfficeLink.Failure.garbled }  // (cut short: never half a preview)
            data.append(piece)
            progress(Double(data.count) / Double(max(size, 1)))
        }
        try data.write(to: target, options: .atomic)
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
