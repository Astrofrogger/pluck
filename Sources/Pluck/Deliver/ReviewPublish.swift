import Foundation

// Publishing to an always-on host the owner controls (spec §12): a NAS running `pluck-review --host`, or a
// paired office Mac that runs the helper in host mode. The host registers the same rooms, so links don't change.
// What a host gets is made here and only here, as §12.2's data folder:
//
//   <data>/bundle/manifest.json        §12.3 format 1 (projects with folders, assets, versions; links with reg/auth)
//   <data>/bundle/copies/<versionID>/… pushed versions' review copies as made on this Mac
//   <data>/bundle/originals/<V>.<ext>  originals of pushed versions, only when a link allows downloads
//   <data>/comments.jsonl              §12.4 entries; the host appends what clients write
//
// A version whose original is already on the NAS goes by reference ("source": a media path) and the NAS makes
// its copies. One data folder per host and project: what's published of a project there is one manifest entry.

extension Deliver.Host {
    /// A root as the owner knows it: its known name, else its id (also when another root has that name, or it is
    /// another root's id: names stand for ids in Browse's paths).
    func rootName(_ id: String) -> String {
        let names = rootNames ?? [:]
        guard let name = names[id], !name.isEmpty, !name.contains("/"), name != "..", name != "." else { return id }
        return names.contains { $0.key != id && ($0.value == name || $0.key == name) } ? id : name
    }

    /// Ids to names from where each root is (a dataset or folder): its last path component.
    static func names(_ roots: [(id: String, path: String)]) -> [String: String] {
        var names: [String: String] = [:]
        for root in roots {
            if let last = root.path.split(separator: "/").last.map(String.init), !last.isEmpty { names[root.id] = last }
        }
        return names
    }
}

extension Deliver {
    struct Host: Codable, Identifiable, Hashable {
        var id = UUID()
        var name: String
        var kind: Kind
        var address: String?             // NAS: host:port of its sync endpoint; Mac: the paired device's id
        /// NAS: its TLS certificate's SHA-256 (uppercase hex with colons), from the pairing line, or confirmed by the owner on first connect.
        var pin: String? = nil
        /// NAS: where a media root is mounted on this Mac (/Volumes/Footage ↔ the media path nas1), so
        /// originals already there are published by reference.
        var mounts: [Mount]? = nil
        // §13.2/§13.15: reaching it from anywhere, this Mac's device there, and what it last said it runs.
        var node: String? = nil          // its iroh node id
        var relay: String? = nil
        var device: String? = nil        // this Mac's device id on it (the key is in the Keychain)
        var role: String? = nil          // main | backup
        var version: String? = nil
        var `protocol`: Int? = nil
        /// The highest link level it serves (§13.24); hosts before level 3 (4.0.3) don't say, so nil = level 2.
        var links: Int? = nil
        var lastSeen: Date? = nil
        /// What the owner calls each root ("nas1" → "Projects-2026"): the TrueNAS datasets or Proxmox folders from setup or Change Folders.
        var rootNames: [String: String]? = nil
        /// A main's backup as this Mac reaches it while the main is down (§13.25), when both take outage uploads.
        var outage: OutageRoute? = nil
        /// What its hello said of §13.25 (`"outage": 1`, 4.0.4): it takes a backup's pushes and serves clients' uploads by reference.
        var outageLevel: Int? = nil
        /// What its hello said of accounts (`"accounts": 1`, 4.0.4): People can be managed on it (accounts plan §1.8).
        var accounts: Int? = nil
        /// Roles (4.0.5, `"roles": 1`): its Macs are admins or editors, and `access` is this Mac's ("admin" | "editor").
        /// A server before that says neither: every Mac is an admin there.
        var roles: Int? = nil
        var access: String? = nil
        /// What its hello said of email updates (`"mail": 1`, 4.1.0): Settings can set up its mail.
        var mail: Int? = nil
        enum Kind: String, Codable { case mac, nas }
        struct Mount: Codable, Hashable { var local: String; var remote: String }
    }

    struct Publication: Codable, Identifiable, Hashable {
        var id = UUID()
        var scope: Scope                 // .project or .asset
        var host: UUID
        var published = Date()
        var lastPull: Date?
    }
}

@MainActor
@Observable
final class ReviewPublish {
    static let shared = ReviewPublish(store: .shared)

    let store: DeliverStore
    private(set) var hosts: [Deliver.Host] = []
    private(set) var publications: [Deliver.Publication] = []
    /// Whether each host answered the last time it was asked.
    private(set) var online: [UUID: Bool] = [:] {
        didSet { if self === Self.shared, online.contains(where: { $0.value && oldValue[$0.key] != true }) { ShareRootNames.soon() } }
    }
    private(set) var working: UUID?
    var problem: String?
    /// What each host says about its copies (by publication): making (a share), or live.
    private(set) var hostState: [UUID: (making: Double?, live: Bool)] = [:]
    /// The last comments.jsonl entry seen, per data folder.
    @ObservationIgnored private var seqs: [String: Int] = [:]
    /// The owner's own comment changes still to append on hosts, per data folder.
    @ObservationIgnored private var outbox: [String: [[String: Any]]] = [:]
    @ObservationIgnored private var merging = false
    @ObservationIgnored private var puller: Task<Void, Never>?
    /// Per project, the link state hosts were last sent (see linkState), and the update on its way.
    @ObservationIgnored private var sentLinks: [UUID: String] = [:]
    @ObservationIgnored private var linkUpdate: Task<Void, Never>?
    /// Per project, whether its last full publish carried originals (a live link allowing downloads); one turned on
    /// afterwards publishes it again, so the host has them (sendLinks).
    @ObservationIgnored private var sentOriginals: [UUID: Bool] = [:]
    /// Versions the (not data) hosts were sent, from launch on what's there now; a new one publishes again (newVersions).
    @ObservationIgnored private var sentVersions: Set<UUID> = []
    @ObservationIgnored private var versionUpdate: [UUID: Task<Void, Never>] = [:]

    init(store: DeliverStore) {
        self.store = store
        hosts = (try? Data(contentsOf: hostsFile)).flatMap { try? Deliver.decoder.decode([Deliver.Host].self, from: $0) } ?? []
        shareVolumes.setServers(hosts)
        publications = (try? Data(contentsOf: publishedFile)).flatMap { try? Deliver.decoder.decode([Deliver.Publication].self, from: $0) } ?? []
        seqs = (try? Data(contentsOf: seqsFile)).flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
        store.listeners.append { [weak self] in self?.heard($0) }
        for project in Set(publications.map(\.scope.project)) {
            sentLinks[project] = linkState(project)
            sentOriginals[project] = downloads(project)
            sentVersions.formUnion(store.content(project).assets.flatMap(\.versions).map(\.id))
        }
    }

    /// Whether a live link of the project allows downloads (its originals go to the hosts with it).
    private func downloads(_ project: UUID) -> Bool { store.links.contains { $0.project == project && $0.isLive && $0.allowDownload } }

    /// A version that can go: its review copy made here, or the NAS has the original and makes it.
    private func goes(_ version: Deliver.Version, to host: Deliver.Host) -> Bool {
        if case .ready = version.copy { return true }
        return host.kind == .nas && Self.reference(store.original(version)?.path ?? version.path, on: host) != nil
    }

    /// A new version (dropped on an asset, its copy just made) goes where its asset is published, so every link on it shows
    /// it by itself. The data NAS gets it through sync; this is for the others.
    private func newVersions(_ asset: UUID) {
        guard let (project, found) = store.find(asset) else { return }
        for publication in publications(asset: asset) where !Self.isDataHost(publication.host) {
            guard let host = host(publication.host), found.versions.contains(where: { !sentVersions.contains($0.id) && goes($0, to: host) }) else { continue }
            versionUpdate[project]?.cancel()
            versionUpdate[project] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                for publication in self.publications(asset: asset) where !Self.isDataHost(publication.host) {
                    if let host = self.host(publication.host) { await self.publish(publication.scope, to: host) }
                }
            }
            return
        }
    }

    /// A version's files changed without a new version (a transcript made later): the hosts it's on get them again.
    /// The data NAS gets them through sync (the version's change).
    func resend(_ asset: UUID) {
        for publication in publications(asset: asset) where !Self.isDataHost(publication.host) {
            guard let host = host(publication.host) else { continue }
            Task { await publish(publication.scope, to: host) }
        }
    }

    private var hostsFile: URL { store.root.appendingPathComponent("hosts.json") }
    private var publishedFile: URL { store.root.appendingPathComponent("published.json") }
    private var seqsFile: URL { store.root.appendingPathComponent("published-seq.json") }
    var bundles: URL { store.root.appendingPathComponent("Bundles", isDirectory: true) }

    private func save() {
        DeliverUploadDestination.forgetNASAnswers() // mounts or roots may have changed
        try? FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try? Deliver.encoder.encode(hosts).write(to: hostsFile, options: .atomic)
        shareVolumes.setServers(hosts)
        try? Deliver.encoder.encode(publications).write(to: publishedFile, options: .atomic)
        try? JSONEncoder().encode(seqs).write(to: seqsFile, options: .atomic)
    }

    /// One data folder per host and project.
    static func dataName(host: UUID, project: UUID) -> String { "Pluck Review \(project.uuidString.prefix(8))-\(host.uuidString.prefix(4))" }
    func folder(_ publication: Deliver.Publication) -> URL {
        bundles.appendingPathComponent(Self.dataName(host: publication.host, project: publication.scope.project), isDirectory: true)
    }

    // MARK: - Hosts

    /// The paired office Mac (Edit Anywhere), when there is one, as a host.
    var pairedMac: Deliver.Host? {
        guard let office = OfficeRenderClient.shared.office else { return nil }
        if let known = hosts.first(where: { $0.kind == .mac && $0.address == office.device.uuidString }) { return known }
        // The device's own id, not a new one on every read: a fresh UUID each time made the Publish sheet's row
        // unselectable (the id chosen was gone by the next redraw, so no radio was filled and Publish did nothing).
        return Deliver.Host(id: office.device, name: office.name, kind: .mac, address: office.device.uuidString)
    }

    var choices: [Deliver.Host] { (pairedMac.map { [$0] } ?? []) + hosts.filter { $0.kind == .nas && !Self.isDataHost($0.id) } }

    /// The NAS that holds the review data (§13.1): it gets changes through DeliverSync's merge, never a plain publish
    /// (that replaces its lists, and the tombstones would delete objects on every Mac).
    static func isDataHost(_ id: UUID) -> Bool { id == DeliverSync.shared.state.host }

    /// A NAS by its address and its pairing line (`pluck-host:<key>@<fingerprint>`) or a key Pluck made.
    @discardableResult
    func addNAS(name: String, address: String, pairing: String) -> Deliver.Host? {
        let address = address.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty, let paired = ReviewHostClient.pairing(pairing) else { return nil }
        let clean = Deliver.clean(name, limit: 80)
        let host = Deliver.Host(name: clean.isEmpty ? address : clean, kind: .nas, address: address, pin: paired.pin)
        hosts.removeAll { $0.kind == .nas && $0.address == address }
        hosts.append(host)
        DeliverKeychain.save(Data(paired.key.utf8), as: address, service: DeliverKeychain.hostService)
        save()
        return host
    }

    /// Pair Again: a NAS already here gets a new key (and, when the line has one, a new pin); its record, mounts and
    /// publications stay. A bare key keeps the pin.
    @discardableResult
    func repair(_ id: UUID, pairing: String) -> Bool {
        guard let index = hosts.firstIndex(where: { $0.id == id }), let address = hosts[index].address,
              let paired = ReviewHostClient.pairing(pairing) else { return false }
        DeliverKeychain.save(Data(paired.key.utf8), as: address, service: DeliverKeychain.hostService)
        if let pin = paired.pin { hosts[index].pin = pin }
        online[id] = nil
        save()
        return true
    }

    func removeHost(_ id: UUID) {
        let gone = publications.filter { $0.host == id }.map(\.id)
        Task { for publication in gone { await remove(publication) } }
        if let address = host(id)?.address { DeliverKeychain.delete(address, service: DeliverKeychain.hostService) }
        hosts.removeAll { $0.id == id }
        save()
    }

    func host(_ id: UUID) -> Deliver.Host? { hosts.first { $0.id == id } }

    /// §13.24: the level new links get. A paired host from before level 3 (4.0.3) doesn't serve a level-3 link (it has
    /// no `sign`), which would leave it to this Mac alone; so links stay level 2 until every paired host says it serves 3.
    var linkLevel: Int { Self.linkLevel(hosts) }
    /// (Only NAS hosts count: an office Mac never says links:3, and its links are this Mac's code anyway.)
    nonisolated static func linkLevel(_ hosts: [Deliver.Host]) -> Int { hosts.filter { $0.kind == .nas }.allSatisfy { ($0.links ?? 2) >= 3 } ? 3 : 2 }

    /// A NAS paired from its invitation (§13.2), or one whose details changed.
    func add(_ host: Deliver.Host) {
        hosts.removeAll { $0.id == host.id }
        hosts.append(host)
        save()
    }

    /// What a host said in its auth answer: its version and protocol, and that it answered.
    func seen(_ id: UUID, version: String?, protocol level: Int?, links: Int?, via: ReviewHostTunnel.Via) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        online[id] = true
        let changed = hosts[index].version != version || hosts[index].protocol != level || hosts[index].links != links
        hosts[index].version = version ?? hosts[index].version
        hosts[index].protocol = level ?? hosts[index].protocol
        hosts[index].links = links // an older version again (a restored backup) says nothing: level 2
        // (Saved when something changed, or once an hour for "last seen".)
        if changed || Date.now.timeIntervalSince(hosts[index].lastSeen ?? .distantPast) > 3600 { hosts[index].lastSeen = .now; save() }
    }

    func update(host id: UUID, _ change: (inout Deliver.Host) -> Void) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        change(&hosts[index])
        save()
    }

    func setMounts(_ mounts: [Deliver.Host.Mount], host id: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[index].mounts = mounts
        save()
    }

    /// The certificate the owner confirmed (it matched the NAS's log), kept as the pin: nil when it's kept, else why
    /// not (never silently). The host by id, else by its address. `replace`: confirmed for a server Pluck just
    /// installed, so a pin left from an earlier attempt gives way; otherwise a different pin stays (Pair Again changes it).
    @discardableResult
    func pinned(_ fingerprint: String, host id: UUID, address: String? = nil, replace: Bool = false) -> String? {
        guard let fingerprint = HostSession.normalized(fingerprint) else { return String(localized: "That isn’t a whole certificate fingerprint.") }
        guard let index = hosts.firstIndex(where: { $0.id == id }) ?? address.flatMap({ address in hosts.firstIndex { $0.kind == .nas && $0.address == address } }) else {
            return String(localized: "Pluck can’t find this server in its list any more. Install again.")
        }
        if let pin = hosts[index].pin, HostSession.normalized(pin) != fingerprint, !replace {
            return String(localized: "This server already has another certificate pinned. Use Pair Again to change it.")
        }
        hosts[index].pin = fingerprint
        online[hosts[index].id] = nil
        save()
        return nil
    }

    // MARK: - Media paths (the one place a local path becomes a NAS path)

    /// The version's media path on a NAS host (`<root id>/<relative path>`), when its original is there.
    nonisolated static func reference(_ original: String, on host: Deliver.Host) -> String? {
        guard host.kind == .nas else { return nil }
        if let browsed = browsed(original) { return browsed.host == host.id ? browsed.path : nil }
        let path = URL(fileURLWithPath: original).standardizedFileURL.path
        for mount in host.mounts ?? [] {
            let local = mount.local.hasSuffix("/") ? String(mount.local.dropLast()) : mount.local
            guard !local.isEmpty, path.hasPrefix(local + "/") else { continue }
            let rest = path.dropFirst(local.count + 1)
            let remote = mount.remote.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !remote.isEmpty, !rest.split(separator: "/").contains(".."), !remote.split(separator: "/").contains("..") else { return nil }
            return remote + "/" + rest
        }
        return shareReference(path, on: host)
    }

    /// A file on a share of the NAS mounted here (/Volumes/<anything>), matched by the share as the server names it, not by
    /// the volume's name: the share is one of the host's roots (by its name, or by id on that same server). The backup's
    /// shares carry the main's root names, so they count too. A share that is no known root (or a NAS that hasn't said
    /// its roots yet) is not the NAS's: the file counts as local, and the picker asks where it goes.
    nonisolated static func shareReference(_ path: String, on host: Deliver.Host) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "Volumes", !parts.contains(".."), let share = shareVolumes.share("/Volumes/" + parts[1]) else { return nil }
        let names = host.rootNames ?? [:]
        let address = (host.address ?? "").split(separator: ":").first.map { $0.lowercased() } ?? ""
        let server = share.server.lowercased()
        let sameServer = !address.isEmpty && shareVolumes.matches(server, address)
        // By name only from a paired NAS (this one, or e.g. its backup): another server's "Footage" share isn't this NAS's.
        let root = (sameServer || shareVolumes.paired(server) ? names.first { $0.value.caseInsensitiveCompare(share.name) == .orderedSame }?.key : nil)
            ?? (sameServer && names[share.name] != nil ? share.name : nil)
        guard let root, !root.isEmpty, !root.contains("/") else { return nil }
        return root + "/" + parts.dropFirst(2).joined(separator: "/")
    }

    /// The reverse of `reference`: where a NAS media path is mounted on this Mac, when it is.
    nonisolated static func local(_ media: String, on host: Deliver.Host) -> String? {
        let media = media.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !media.split(separator: "/").contains("..") else { return nil }
        for mount in host.mounts ?? [] {
            let remote = mount.remote.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !remote.isEmpty, media.hasPrefix(remote + "/") else { continue }
            let local = (mount.local.hasSuffix("/") ? String(mount.local.dropLast()) : mount.local) + "/" + media.dropFirst(remote.count + 1)
            return FileManager.default.fileExists(atPath: local) ? local : nil
        }
        return nil
    }

    /// A file chosen in Browse <NAS>, kept as a version's path: "nas:<host>:<media path>".
    nonisolated static func nasPath(host: UUID, path: String) -> String { "nas:\(host.uuidString):\(path)" }

    nonisolated static func browsed(_ path: String) -> (host: UUID, path: String)? {
        let parts = path.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "nas", let host = UUID(uuidString: parts[1]),
              parts[2].split(separator: "/").count >= 2, !parts[2].split(separator: "/").contains("..") else { return nil }
        return (host, parts[2])
    }

    /// A first guess for a NAS's mounts: each network volume mounted from that server, its share name as the media id.
    nonisolated static func guessMounts(server: String) -> [Deliver.Host.Mount] {
        let host = server.split(separator: ":").first.map(String.init)?.lowercased() ?? server.lowercased()
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeURLForRemountingKey], options: [.skipHiddenVolumes]) ?? []
        return volumes.compactMap { volume in
            guard let remote = try? volume.resourceValues(forKeys: [.volumeURLForRemountingKey]).volumeURLForRemounting,
                  remote.host?.lowercased() == host || remote.host?.lowercased().hasPrefix(host + ".") == true else { return nil }
            return Deliver.Host.Mount(local: volume.path, remote: remote.pathComponents.dropFirst().first ?? volume.lastPathComponent)
        }
    }

    /// For the Publish sheet: which versions the NAS reads itself, and which need copies sent.
    func plan(_ scope: Deliver.Scope, host: Deliver.Host) -> (referenced: [String], sent: [String]) {
        var referenced: [String] = [], sent: [String] = []
        for asset in assets(scope) {
            for version in asset.versions {
                let name = asset.versions.count > 1 ? "\(asset.name) v\(version.number)" : asset.name
                if Self.reference(store.original(version)?.path ?? version.path, on: host) != nil { referenced.append(name) } else { sent.append(name) }
            }
        }
        return (referenced, sent)
    }

    func assets(_ scope: Deliver.Scope) -> [Deliver.Asset] {
        switch scope {
        case .project(let p): store.content(p).assets
        case .asset(let a, _): store.find(a).map { [$0.asset] } ?? []
        case .assets(let ids, _): ids.compactMap { store.find($0)?.asset }
        case .folder: []
        }
    }

    /// Where an asset is published (its own publication or its project's).
    func publications(asset: UUID) -> [Deliver.Publication] {
        guard let project = store.find(asset)?.project else { return [] }
        return publications.filter { $0.scope == .asset(asset, project: project) || $0.scope == .project(project) }
    }

    /// What of a project is published on a host: every asset (nil) or these.
    private func published(_ project: UUID, on host: UUID, adding scope: Deliver.Scope? = nil, without: UUID? = nil) -> Set<UUID>? {
        let scopes = publications.filter { $0.host == host && $0.scope.project == project && $0.id != without }.map(\.scope) + (scope.map { [$0] } ?? [])
        if scopes.contains(.project(project)) { return nil }
        return Set(scopes.compactMap { if case .asset(let id, _) = $0 { id } else { nil } })
    }

    // MARK: - The data folder

    /// §12.3's manifest for a project's assets (all, or `only`), and the bundle files to send with it.
    /// `push`: versions sent with their copies even when the NAS has the original (it reported them missing).
    func manifest(project: UUID, only: Set<UUID>?, host: Deliver.Host?, push: Set<UUID> = [], onlyFolders: Set<UUID>? = nil,
                  onlyLinks: Set<UUID>? = nil) -> (json: [String: Any], files: [(path: String, url: URL)]) {
        let content = store.content(project)
        let assets = content.assets.filter { only?.contains($0.id) ?? true }
        let links = store.links.filter { link in
            if let onlyLinks { return link.project == project && onlyLinks.contains(link.id) }
            guard link.isLive, link.project == project else { return false }
            if case .asset(let a, _) = link.scope { return only?.contains(a) ?? true }
            return only == nil
        }
        // (The data host has every link, so its fragments carry originals when any of the project's links allows downloads.)
        let downloads = links.contains { $0.allowDownload }
            || (host.map { Self.isDataHost($0.id) } == true && store.links.contains { $0.project == project && $0.isLive && $0.allowDownload })
        var files: [(String, URL)] = []
        func walk(_ url: URL, as path: String) {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return }
            if !isFolder.boolValue { return files.append((path, url)) }
            for item in (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
                walk(item, as: path + "/" + item.lastPathComponent)
            }
        }
        let wireAssets = assets.map { asset -> [String: Any] in
            let versions = asset.versions.map { version -> [String: Any] in
                let original = store.original(version)
                let ext = original?.pathExtension ?? (version.path as NSString).pathExtension
                var item: [String: Any] = ["id": version.id.uuidString, "number": version.number, "added": DeliverServer.date(version.added),
                                           "originalName": "\(asset.name) v\(version.number)" + (ext.isEmpty ? "" : ".\(ext)")]
                // (A Quick Look preview is made here only: the NAS gets the picture, not the job.)
                if let host, !push.contains(version.id), !(asset.kind == .image && DeliverCopies.isPreviewOnly(original)), let source = Self.reference(original?.path ?? version.path, on: host) {
                    item["source"] = source
                    item["size"] = 0
                    // (The host makes the copies but has no speech engine: Pluck's transcript goes with them.)
                    if version.transcribed != nil {
                        for name in ["transcript.json", "captions.vtt"] {
                            let file = store.copies(version.id).appendingPathComponent(name)
                            if FileManager.default.fileExists(atPath: file.path) { files.append(("copies/\(version.id.uuidString)/\(name)", file)) }
                        }
                    }
                    return item
                }
                let probe = version.probe
                item.merge(["duration": probe?.duration ?? 0, "fpsNum": probe?.fpsNum ?? 25, "fpsDen": probe?.fpsDen ?? 1,
                            "width": probe?.width ?? 0, "height": probe?.height ?? 0, "startTimecode": probe?.startTimecode ?? "00:00:00:00",
                            "dropFrame": probe?.dropFrame ?? false, "frames": probe?.frames ?? 1, "size": version.size]) { $1 }
                if case .ready(let renditions) = version.copy { item["renditions"] = renditions } else { item["renditions"] = [] }
                if let pages = version.pages { item["pages"] = pages }
                if let sha = version.sha256 { item["sha256"] = sha }
                walk(store.copies(version.id), as: "copies/\(version.id.uuidString)")
                if downloads, let original {
                    let name = "originals/\(version.id.uuidString)" + (ext.isEmpty ? "" : ".\(ext)")
                    files.append((name, original))
                    item["original"] = name
                } else if original == nil, let kept = version.hostOriginal, onlyLinks != nil || host.map({ Self.isDataHost($0.id) }) == true {
                    item["original"] = kept   // (the data host's own file, as `changes` gave it; another host doesn't have it)
                }
                return item
            }
            var wire: [String: Any] = ["id": asset.id.uuidString, "name": asset.name, "folder": asset.folder.map { $0.uuidString as Any } ?? NSNull(),
                                       "kind": asset.kind.rawValue, "status": asset.status.rawValue, "versions": versions, "created": DeliverServer.date(asset.created)]
            if let fields = asset.fields, let data = try? Deliver.encoder.encode(fields), let json = try? JSONSerialization.jsonObject(with: data) { wire["fields"] = json }
            // Custom fields ride in `fields` as "cf:<id>": a host passes them on to links that list them, as it does the others.
            if let custom = asset.customFields, !custom.isEmpty {
                wire["fields"] = ((wire["fields"] as? [String: Any]) ?? [:]).merging(Dictionary(uniqueKeysWithValues: custom.map { ("cf:" + $0.key, $0.value as Any) })) { $1 }
            }
            return wire.merging(Self.stamp(asset)) { $1 }
        }
        let wireLinks: [[String: Any]] = links.compactMap { link in
            let keys = store.key(link.id).flatMap { key in store.secret(link.id).map { (key, $0) } }
            // Made on another Mac: only to the data host's merge (onlyLinks), without the secrets; it keeps its own.
            guard keys != nil || (onlyLinks != nil && store.isForeign(link)) else { return nil }
            let (kind, target): (String, UUID) = switch link.scope {
            case .project(let p): ("project", p)
            case .folder(let f, _): ("folder", f)
            case .asset(let a, _): ("asset", a)
            case .assets(_, let p): ("assets", p)
            }
            var root: [String: Any] = ["kind": kind, "id": target.uuidString, "name": store.name(link.scope)]
            if case .assets(let ids, _) = link.scope { root = ["kind": "assets", "id": link.id.uuidString, "name": link.title, "assets": ids.map(\.uuidString)] }
            var wire: [String: Any] = ["id": link.id.uuidString, "roomID": link.roomID,
                                       "title": link.title, "mode": link.mode.rawValue, "allowDownload": link.allowDownload, "latestOnly": link.latestOnly,
                                       "expires": link.expires.map { DeliverServer.date($0) as Any } ?? NSNull(), "revoked": link.revoked.map { DeliverServer.date($0) as Any } ?? NSNull(),
                                       "passwordHash": link.passwordHash.map { $0 as Any } ?? NSNull(), "project": project.uuidString, "root": root,
                                       "paused": link.isPaused]
            // 4.1.0: Email updates go to the host with the mail code (a level-3 link's code), never to browsers.
            if let notify = link.notify, notify.email, let code = store.code(link.id) {
                wire["notify"] = ["email": true, "recipientEmail": notify.recipientEmail.map { $0 as Any } ?? NSNull(), "mailCode": code] as [String: Any]
            }
            // §6.1's link fields, as `ready.link` has them (the header goes as a bundle file with the branding).
            var info = DeliverServer.linkInfo(link, store: store)
            for key in ["title", "mode", "allowDownload", "latestOnly", "expires", "header"] { info[key] = nil }
            wire.merge(info) { a, _ in a }
            // Ask for Files: where the NAS puts the files (only the host hears it, never the page).
            if let into = link.uploads?.into, var uploads = wire["uploads"] as? [String: Any] {
                uploads["into"] = ["root": into.root, "folder": into.folder]
                wire["uploads"] = uploads
            }
            if case let (key, secret)? = keys {
                wire.merge(["reg": DeliverKeys.registerKey(root: secret), "auth": DeliverKeys.base64url(DeliverKeys.authKey(key)), "join": DeliverKeys.joinHash(key)]) { $1 }
                // Level 3 (§13.24) has no room signing key; the host sends a MAC hello for it.
                if store.code(link.id) != nil { wire["level"] = 3 } else { wire["sign"] = DeliverKeys.base64url(DeliverKeys.signSeed(root: secret)) }
            }
            wire["created"] = DeliverServer.date(link.created)
            wire["deadline"] = link.deadline.map { DeliverServer.date($0) as Any } ?? NSNull()
            if let madeOn = link.madeOn { wire["madeOn"] = madeOn }
            if link.customStatuses == true { wire["customStatuses"] = true }
            return wire.merging(Self.stamp(link)) { $1 }
        }
        let folders = content.folders.map { folder -> [String: Any] in
            (["id": folder.id.uuidString, "name": folder.name, "parent": folder.parent.map { $0.uuidString as Any } ?? NSNull()]
             .merging(folder.order.map { ["order": $0.map(\.uuidString)] } ?? [:]) { a, _ in a } as [String: Any])
                .merging(Self.stamp(folder)) { $1 }
        }
        var meta = store.project(project).map(Self.meta) ?? ["id": project.uuidString, "name": ""]
        meta["folders"] = folders.filter { onlyFolders?.contains(UUID(uuidString: $0["id"] as? String ?? "") ?? UUID()) ?? true }
        meta["assets"] = wireAssets
        var json: [String: Any] = ["format": 1, "projects": [meta], "links": wireLinks, "activityDays": DeliverStore.activityDays]
        // The same look on the host: the logos as bundle files.
        if let branding = store.branding(for: project) {
            var wire: [String: Any] = ["name": branding.name, "accent": branding.accent, "bg": branding.bg, "text": branding.text]
            let folder = bundles.appendingPathComponent(".branding-\(project.uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (key, data) in [("logo", branding.logo), ("logoLight", branding.logoLight), ("header", branding.header)] {
                guard let data else { continue }
                let name = key == "logo" ? "logo.png" : key == "header" ? "header.jpg" : "logo-light.png", file = folder.appendingPathComponent(name)
                try? data.write(to: file, options: .atomic)
                files.append(("branding/" + name, file))
                wire[key] = "branding/" + name
            }
            json["branding"] = wire
        }
        return (json, files)
    }

    /// `rev/at/by` as the wire has them (§13.0); nothing for an object from before syncing.
    nonisolated static func stamp(_ object: some DeliverRevised) -> [String: Any] {
        guard let rev = object.rev else { return [:] }
        return ["rev": rev, "at": DeliverServer.date(object.at ?? .now), "by": object.by ?? ""]
    }

    /// A project's own fields (no folders or assets), as `changes` sends them.
    nonisolated static func meta(_ project: Deliver.Project) -> [String: Any] {
        var meta: [String: Any] = ["id": project.id.uuidString, "name": project.name, "created": DeliverServer.date(project.created),
                                   "deadline": project.deadline.map { DeliverServer.date($0) as Any } ?? NSNull()]
        if let order = project.order { meta["order"] = order }
        if let cover = project.cover { meta["cover"] = cover.uuidString }
        if project.hidden == true { meta["hidden"] = true }
        if project.uhd == true { meta["uhd"] = true }   // (a NAS that makes the copies makes 4K too; older hosts ignore it)
        if let language = project.spokenLanguage { meta["spokenLanguage"] = language }
        return meta.merging(stamp(project)) { $1 }
    }

    /// The project's links a host must drop (turned off, expired, or made here and without their key): `remove.links` on every publish.
    func deadLinks(_ project: UUID) -> [String] {
        store.links.filter { $0.project == project && (!$0.isLive || (store.key($0.id) == nil && !store.isForeign($0))) }.map(\.id.uuidString)
    }

    /// What a host knows of a project's links; a change is sent on at once (Turn Off, password, expiry…).
    private func linkState(_ project: UUID) -> String {
        store.links.filter { $0.project == project }.map { link in
            // (Everything a host knows; `opened` stamps and owner-only switches change nothing there.)
            var known = link
            known.lastOpened = nil
            known.muted = nil
            known.notifyOpened = nil
            return "\(link.isLive)|" + ((try? Deliver.encoder.encode(known)).map { String(decoding: $0, as: UTF8.self) } ?? "")
        }.joined(separator: ";")
    }

    /// The owner's comments on these assets as §12.4 entries (for a host's first publish).
    func entries(project: UUID, only: Set<UUID>?) -> [[String: Any]] {
        store.content(project).assets.filter { only?.contains($0.id) ?? true }.flatMap { store.comments($0.id) }.compactMap(Self.entry)
    }

    nonisolated static func entry(_ comment: Deliver.Comment) -> [String: Any]? {
        (try? Deliver.encoder.encode(comment)).flatMap { try? JSONSerialization.jsonObject(with: $0) }.map { ["comment": $0] }
    }

    /// The data folder for a Mac host (§12.2): bundle/ with the manifest and files, and comments.jsonl to start from.
    func makeDataFolder(_ project: UUID, only: Set<UUID>?, into folder: URL) throws {
        let (json, files) = manifest(project: project, only: only, host: nil)
        let bundle = folder.appendingPathComponent("bundle", isDirectory: true)
        try? FileManager.default.removeItem(at: bundle)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        for file in files { try Self.linkTree(file.url, to: bundle.appendingPathComponent(file.path)) }
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: bundle.appendingPathComponent("manifest.json"), options: .atomic)
        let comments = folder.appendingPathComponent("comments.jsonl")
        if !FileManager.default.fileExists(atPath: comments.path) {
            let lines = entries(project: project, only: only).enumerated().compactMap { index, entry in
                (try? JSONSerialization.data(withJSONObject: entry.merging(["seq": index + 1]) { $1 })).map { String(decoding: $0, as: UTF8.self) }
            }
            try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: comments, atomically: true, encoding: .utf8)
        }
    }

    /// Hard links (no space used) where the volume allows, else copies.
    nonisolated static func linkTree(_ source: URL, to target: URL) throws {
        let files = FileManager.default
        var isFolder: ObjCBool = false
        guard files.fileExists(atPath: source.path, isDirectory: &isFolder) else { return }
        try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !isFolder.boolValue {
            try? files.removeItem(at: target)
            if (try? files.linkItem(at: source, to: target)) == nil { try files.copyItem(at: source, to: target) }
            return
        }
        try files.createDirectory(at: target, withIntermediateDirectories: true)
        for item in try files.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            try linkTree(item, to: target.appendingPathComponent(item.lastPathComponent))
        }
    }

    // MARK: - Merging what clients wrote on a host (§12.4)

    /// A host's entries into the store: comments upserted by id (no duplicates), deletions, approvals.
    @discardableResult
    func merge(_ entries: [[String: Any]], project: UUID) -> (added: Int, changed: Int) {
        merging = true
        defer { merging = false }
        var added = 0, changed = 0
        // A comment's last entry is what it is now; one deleted later isn't added again.
        var latest: [UUID: Deliver.Comment] = [:], order: [UUID] = [], gone: Set<UUID> = []
        for entry in entries {
            if let value = entry["comment"], let body = try? JSONSerialization.data(withJSONObject: value),
               let comment = try? Deliver.decoder.decode(Deliver.Comment.self, from: body) {
                if latest[comment.id] == nil { order.append(comment.id) }
                latest[comment.id] = comment
                gone.remove(comment.id)
            } else if let id = ((entry["deleted"] as? [String: Any])?["id"] as? String).flatMap(UUID.init(uuidString:)) {
                gone.insert(id)
            }
        }
        for comment in order.compactMap({ latest[$0] }) where !gone.contains(comment.id) && store.find(comment.asset)?.project == project {
            let before = store.comment(comment.id)
            let merged = store.merge(comment)
            if merged != .same, comment.authorToken != nil || comment.replies.contains(where: { $0.authorToken != nil }) {
                DeliverNotify.mentioned(before: before, after: store.comment(comment.id) ?? comment, store: store)
            }
            switch merged {
            case .added:
                added += 1
                if comment.authorToken != nil {
                    store.addInbox(.init(id: comment.id, project: project, asset: comment.asset, version: comment.version,
                                         kind: "comment", summary: String(comment.text.prefix(120)), author: comment.author))
                }
            case .changed: changed += 1
            case .same: break
            }
        }
        for id in gone {
            if let found = store.comment(id), store.find(found.asset)?.project == project { _ = try? store.deleteComment(id) }
        }
        // Link activity and uploads on the host (§12.10): kept here once by id.
        for entry in entries {
            if let value = entry["activity"], let body = try? JSONSerialization.data(withJSONObject: value),
               let activity = try? Deliver.decoder.decode(Deliver.Activity.self, from: body), store.link(activity.link)?.project == project {
                store.logOnce(activity)
            }
            // A field a client set on the host (rating, keywords…; approvals come as approvals).
            if let field = entry["field"] as? [String: Any], let asset = (field["asset"] as? String).flatMap(UUID.init(uuidString:)),
               store.find(asset)?.project == project, let name = field["field"] as? String, name != "status" {
                try? store.setField(name, field["value"], of: asset, by: field["by"] as? String ?? "")
            }
        }
        for entry in entries {
            guard let value = entry["approval"], let body = try? JSONSerialization.data(withJSONObject: value),
                  let approval = try? Deliver.decoder.decode(Deliver.Approval.self, from: body), store.find(approval.asset)?.project == project,
                  store.record(approval) else { continue }
            store.addInbox(.init(id: approval.id, project: project, asset: approval.asset, version: approval.version, kind: "approval",
                                 summary: approval.decision == .approve ? "approved" : "needsChanges", author: approval.author))
        }
        return (added, changed)
    }

    /// The owner's comment changes on this Mac go to the hosts the asset is published on, on the next exchange.
    private func heard(_ event: DeliverStore.Event) {
        guard !merging else { return }
        let entry: [String: Any]?, asset: UUID
        switch event {
        case .comment(_, let comment): entry = Self.entry(comment); asset = comment.asset
        case .commentDeleted(let comment):
            entry = ["deleted": ["id": comment.id.uuidString, "asset": comment.asset.uuidString, "version": comment.version.uuidString]]
            asset = comment.asset
        case .assetChanged(let asset):
            newVersions(asset)
            return
        case .linkOff, .linksChanged:
            // (A burst of changes is one update; `opened` stamps change nothing a host knows.)
            linkUpdate?.cancel()
            linkUpdate = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                await self?.sendLinks()
            }
            return
        default: return
        }
        guard let entry, let project = store.find(asset)?.project else { return }
        for publication in publications(asset: asset) { outbox[Self.dataName(host: publication.host, project: project), default: []].append(entry) }
    }

    // MARK: - Live links on a host (clients are never served from this Mac while a NAS or always-on Mac exists)

    /// DeliverLink.neverServe's rule: a NAS (main, backup or the data host) or an always-on Mac means clients are only
    /// ever served from those.
    var neverServe: Bool { hosts.contains { $0.kind == .nas || $0.kind == .mac } || pairedMac != nil || DeliverSync.shared.state.host != nil }

    /// Projects of live links being put on a host now, and those where that didn't work (with the host's problem).
    private(set) var placing: Set<UUID> = []
    private(set) var notPlaced: [UUID: String] = [:]

    /// Whether a host that serves clients holds the link: the data NAS syncs every project; another host has the link
    /// when its project is published there whole, or (an asset link) that asset is (the manifest's rule for links).
    func isOnHost(_ link: Deliver.ShareLink) -> Bool {
        if DeliverSync.shared.state.host != nil { return true }
        return publications.contains { $0.scope == .project(link.project) || $0.scope == link.scope }
    }

    /// Where a link no host has goes: the main NAS, else another NAS, else the always-on Mac. Never this Mac.
    var placeHost: Deliver.Host? {
        let nases = hosts.filter { $0.kind == .nas && !Self.isDataHost($0.id) }
        return nases.first { $0.role != "backup" } ?? nases.first ?? pairedMac ?? hosts.first { $0.kind == .mac }
    }

    /// What a link needs published: its asset, else its whole project (a folder or a pick of assets goes with the project).
    nonisolated static func placeScope(_ link: Deliver.ShareLink) -> Deliver.Scope {
        if case .asset = link.scope { return link.scope }
        return .project(link.project)
    }

    /// Live links made here that no serving host holds go on one by themselves (with a data NAS: a sync round, which
    /// carries every project and its copies). A failure stays on the link's row and in the NAS alert; `retry` (the
    /// row's Publish) tries one that failed again. Without a NAS or always-on Mac there's nothing to do: this Mac serves.
    func placeLinks(retry: Bool = false) async {
        guard neverServe else { return }
        if DeliverSync.shared.state.host != nil {
            if DeliverSync.shared.waiting > 0 { await DeliverSync.shared.round() }
            return
        }
        var scopes: [Deliver.Scope] = []
        for link in store.links where link.isLive && store.key(link.id) != nil && !isOnHost(link) {
            let scope = Self.placeScope(link)
            if !scopes.contains(scope), !scopes.contains(.project(link.project)) { scopes.append(scope) }
        }
        for scope in scopes where !placing.contains(scope.project) && (retry || notPlaced[scope.project] == nil) {
            guard let host = placeHost else { return }
            placing.insert(scope.project)
            notPlaced[scope.project] = nil
            await publish(scope, to: host)
            placing.remove(scope.project)
            guard !publications.contains(where: { $0.scope == scope && $0.host == host.id }) else { continue }
            let why = problem ?? String(localized: "The host didn’t answer.")
            notPlaced[scope.project] = why
            DeliverNASAlert.shared.report(.init(title: String(localized: "Pluck can’t reach \(host.name)"), detail: why, project: scope.project))
        }
    }

    // MARK: - Publishing, pulling back, removing

    func publish(_ scope: Deliver.Scope, to host: Deliver.Host) async {
        guard !Self.isDataHost(host.id) else { return }
        if !hosts.contains(where: { $0.id == host.id }) { hosts.append(host) }
        var publication = publications.first { $0.scope == scope && $0.host == host.id } ?? Deliver.Publication(scope: scope, host: host.id)
        let project = scope.project, name = Self.dataName(host: host.id, project: project)
        let only = published(project, on: host.id, adding: scope)
        let first = !publications.contains { $0.host == host.id && $0.scope.project == project }
        working = publication.id
        defer { working = nil }
        problem = nil
        do {
            switch host.kind {
            case .mac:
                let folder = folder(publication)
                try makeDataFolder(project, only: only, into: folder)
                SendSync.shared.send([folder])
                // The office Mac reloads only once every file is there (never a half-copied bundle).
                whenSent(folder) { _ = try? await OfficeRenderClient.shared.ask("reviewHost", ["bundle": name]) }
            case .nas:
                try await ReviewHostClient.session(host) { session in
                    var push: Set<UUID> = []
                    for _ in 0..<2 {
                        let (json, files) = self.manifest(project: project, only: only, host: host, push: push)
                        let there = Dictionary((try await session.ask(["op": "list"])["files"] as? [[String: Any]] ?? []).compactMap { file in
                            (file["path"] as? String).map { ($0, (file["size"] as? NSNumber)?.int64Value ?? -1) }
                        }) { a, _ in a }
                        for file in files {
                            let size = (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                            guard there[file.path] != size else { continue }
                            _ = try await session.put(file.path, file.url)
                        }
                        let answer = try await session.ask(["op": "publish", "manifest": json, "remove": ["projects": [], "links": self.deadLinks(project)]])
                        // Not on the NAS after all: copies made here go instead (when the original is here).
                        let missing = Set((answer["missing"] as? [String] ?? []).compactMap(UUID.init(uuidString:)))
                        guard !missing.isEmpty, push.isEmpty else { break }
                        push = missing
                        let localOnes = missing.filter { id in
                            self.store.content(project).assets.flatMap(\.versions).first { $0.id == id }.map { self.store.original($0) != nil } ?? false
                        }
                        if localOnes.count < missing.count { self.problem = String(localized: "Some files aren’t on the NAS or this Mac.") }
                    }
                    if first {
                        let entries = self.entries(project: project, only: only)
                        if !entries.isEmpty { _ = try await session.ask(["op": "append", "entries": entries]) }
                    }
                }
                hostState[publication.id] = plan(scope, host: host).referenced.isEmpty ? (nil, true) : (0, false)
            }
            online[host.id] = true
            sentLinks[project] = linkState(project)
            sentOriginals[project] = downloads(project)
            sentVersions.formUnion(store.content(project).assets.filter { only?.contains($0.id) ?? true }.flatMap(\.versions).filter { goes($0, to: host) }.map(\.id))
            publication.published = .now
            publications.removeAll { $0.id == publication.id }
            publications.append(publication)
            if first { seqs[name] = host.kind == .mac ? entries(project: project, only: only).count : seqs[name] ?? 0 }
            save()
            pullRegularly()
        } catch {
            online[host.id] = false
            problem = error is ReviewHostClient.Unconfirmed ? String(localized: "Confirm the NAS’s fingerprint first (Set Up…).")
                : (error as? Deliver.Failure).map { _ in String(localized: "The host didn’t answer.") } ?? error.localizedDescription
        }
    }

    /// A whole `pull`: pages of ≤ 5000 while the host says `more` (at most 100), as one answer with the last page's seq.
    static func pages(_ since: Int, _ ask: (Int) async throws -> [String: Any]) async throws -> [String: Any] {
        var entries: [[String: Any]] = [], seq = since, more = true, rounds = 0
        while more, rounds < 100 {
            rounds += 1
            let page = try await ask(seq)
            entries += page["entries"] as? [[String: Any]] ?? []
            more = page["more"] as? Bool ?? false
            guard let next = page["seq"] as? Int else { break }
            if more, next <= seq { break } // a host that doesn't move on
            seq = next
        }
        return ["entries": entries, "seq": seq]
    }

    /// New comments and approvals from every host that answers, and the owner's changes to them.
    func pull() async {
        await sendLinks()
        var done: Set<String> = []
        for publication in publications {
            guard let host = host(publication.host), host.id != DeliverSync.shared.state.host else { continue }
            let project = publication.scope.project, name = Self.dataName(host: host.id, project: project)
            guard done.insert(name).inserted else { continue }
            let since = seqs[name] ?? 0, outgoing = outbox[name] ?? []
            do {
                let answer: [String: Any]
                switch host.kind {
                case .mac:
                    if !outgoing.isEmpty { _ = try await OfficeRenderClient.shared.ask("reviewAppend", ["bundle": name, "entries": outgoing]) }
                    answer = try await Self.pages(since) { try await OfficeRenderClient.shared.ask("reviewPull", ["bundle": name, "since": $0]) }
                case .nas:
                    var pulled: [String: Any] = [:], status: [String: Any] = [:]
                    try await ReviewHostClient.session(host) { session in
                        if !outgoing.isEmpty { _ = try await session.ask(["op": "append", "entries": outgoing]) }
                        pulled = try await Self.pages(since) { try await session.ask(["op": "pull", "since": $0]) }
                        status = try await session.ask(["op": "status"])
                        _ = try? await session.ask(["op": "local-time", "offset": TimeZone.current.secondsFromGMT()]) // the delivery folder's day
                    }
                    await DeliverOutage.note(status: status, host: host)
                    answer = pulled
                    let copies = (status["copies"] as? [String: [String: Any]] ?? [:]).values
                    let making = copies.filter { $0["state"] as? String != "ready" && $0["state"] as? String != "failed" }
                    let share = making.isEmpty ? nil : making.compactMap { ($0["progress"] as? NSNumber)?.doubleValue }.reduce(0, +) / Double(making.count)
                    for item in publications where item.host == host.id && item.scope.project == project { hostState[item.id] = (share, share == nil) }
                }
                outbox[name] = Array((outbox[name] ?? []).dropFirst(outgoing.count))
                merge(answer["entries"] as? [[String: Any]] ?? [], project: project)
                if host.kind == .nas { await importUploads(answer["entries"] as? [[String: Any]] ?? [], project: project, host: host) }
                if let seq = answer["seq"] as? Int { seqs[name] = seq }
                online[host.id] = true
                for index in publications.indices where publications[index].host == host.id && publications[index].scope.project == project {
                    publications[index].lastPull = .now
                }
            } catch {
                online[host.id] = false
            }
        }
        save()
    }

    /// Clients' uploads on a NAS (kept apart there): fetched with `get`, added to the project, then deleted on the host.
    /// shortcut: a Mac host's uploads stay on the office Mac (no file op through Edit Anywhere yet).
    func importUploads(_ entries: [[String: Any]], project: UUID, host: Deliver.Host) async {
        RemoteAskFiles.shared.arrived(entries, host: host)
        // (Ask for Files uploads go to their NAS folder, never into the project: RemoteAskFiles.)
        let uploads = entries.compactMap { $0["upload"] as? [String: Any] }.filter { $0["into"] == nil }
        guard !uploads.isEmpty else { return }
        try? await ReviewHostClient.session(host) { session in
            for upload in uploads where upload["for"] as? String != "attachment" { // (a comment's attachment stays with its comment)
                // A client's file from an outage, now in the server's uploads folder (§13.25): added where it is, by reference.
                if upload["root"] as? Bool == true, let path = upload["path"] as? String, !path.hasPrefix("uploads/"), !path.split(separator: "/").contains(".."),
                   let link = (upload["link"] as? String).flatMap(UUID.init(uuidString:)).flatMap({ self.store.link($0) }), link.project == project {
                    let name = DeliverServer.safeName(upload["name"] as? String ?? "")
                    let file = URL(fileURLWithPath: name)
                    let reference = Self.nasPath(host: host.id, path: path)
                    guard !name.isEmpty, !self.store.content(project).assets.contains(where: { $0.versions.contains { $0.path == reference } }) else { continue }
                    if let made = self.store.addReferences([(name: file.deletingPathExtension().lastPathComponent, kind: DeliverStore.kind(file), path: reference,
                                                             size: (upload["size"] as? NSNumber)?.int64Value ?? 0)], to: project).first {
                        if let folder = link.uploads?.folder { self.store.move(asset: made.id, to: folder) }
                        self.store.addInbox(.init(id: made.current.id, project: project, asset: made.id, version: made.current.id, kind: "upload", summary: name, author: link.recipient ?? link.title))
                    }
                    continue
                }
                guard let path = upload["path"] as? String, path.hasPrefix("uploads/"), !path.split(separator: "/").contains(".."),
                      let link = (upload["link"] as? String).flatMap(UUID.init(uuidString:)).flatMap({ self.store.link($0) }), link.project == project,
                      let raw = upload["name"] as? String else { continue }
                let name = DeliverServer.safeName(raw)
                guard !name.isEmpty else { continue }
                let target = DeliverServer.unique(self.store.root.appendingPathComponent("Uploads/\(link.id.uuidString)/\(name)"))
                try await session.get(path, to: target, expected: (upload["size"] as? NSNumber)?.int64Value ?? 0)
                let folders = self.store.content(project).folders
                var folder: UUID? = link.uploads?.folder.flatMap { id in folders.contains { $0.id == id } ? id : nil }
                if folder == nil, case .folder(let id, _) = link.scope { folder = id }
                if let made = try? self.store.add([target], to: project, folder: folder).first {
                    self.store.addInbox(.init(id: made.current.id, project: project, asset: made.id, version: made.current.id, kind: "upload", summary: name, author: link.recipient ?? link.title))
                }
                _ = try? await session.ask(["op": "delete", "path": path])
            }
        }
    }

    /// A data host's clients' uploads (§13.25; it holds the review data, so nothing comes to this Mac): each becomes an asset
    /// with the upload's own id (every Mac of the team makes the same one) whose original stays on the NAS, which makes its
    /// copies: a file in its quarantine as ".uploads/<link>/<file>", one from an outage where the server put it.
    func referenceUploads(_ entries: [[String: Any]], host: Deliver.Host) {
        RemoteAskFiles.shared.arrived(entries, host: host)
        for entry in entries {
            guard let upload = entry["upload"] as? [String: Any], upload["for"] as? String == "asset", upload["into"] == nil,
                  let id = (upload["id"] as? String).flatMap(UUID.init(uuidString:)), let raw = upload["path"] as? String,
                  !raw.split(separator: "/").contains(".."), raw.hasPrefix("uploads/") || upload["root"] as? Bool == true,
                  let link = (upload["link"] as? String).flatMap(UUID.init(uuidString:)).flatMap({ store.link($0) }) else { continue }
            let name = DeliverServer.safeName(upload["name"] as? String ?? "")
            let media = raw.hasPrefix("uploads/") ? "." + raw : raw
            let folders = store.content(link.project).folders
            var folder: UUID? = link.uploads?.folder.flatMap { id in folders.contains { $0.id == id } ? id : nil }
            if folder == nil, case .folder(let id, _) = link.scope { folder = id }
            guard !name.isEmpty, let made = store.addUpload(id: id, name: name, path: Self.nasPath(host: host.id, path: media),
                                                            size: (upload["size"] as? NSNumber)?.int64Value ?? 0, to: link.project, folder: folder) else { continue }
            store.addInbox(.init(id: made.current.id, project: link.project, asset: made.id, version: made.current.id, kind: "upload", summary: name,
                                 author: upload["by"] as? String ?? link.recipient ?? link.title))
        }
    }

    /// Links that changed since hosts last heard go to every host the project is published on: live ones
    /// upserted, dead ones removed (the host closes their viewers). Not reached: tried again on the next pull.
    func sendLinks() async {
        for project in Set(publications.map(\.scope.project)) {
            let state = linkState(project)
            guard sentLinks[project] != state else { continue }
            // Downloads turned on after publishing: the hosts need the originals too, so it's published again.
            if downloads(project), sentOriginals[project] != true {
                for publication in publications.filter({ $0.scope.project == project && !Self.isDataHost($0.host) }) {
                    if let host = host(publication.host) { await publish(publication.scope, to: host) }
                }
                continue
            }
            var reached = true
            for hostID in Set(publications.filter { $0.scope.project == project }.map(\.host)) {
                guard let host = host(hostID), !Self.isDataHost(hostID) else { continue }
                let only = published(project, on: hostID)
                var links = manifest(project: project, only: only, host: host).json
                links["projects"] = [Any]()
                let op: [String: Any] = ["op": "publish", "manifest": links, "remove": ["projects": [Any](), "links": deadLinks(project)]]
                do {
                    switch host.kind {
                    case .mac:
                        // The data folder too, so the next reload there reads the same links.
                        let name = Self.dataName(host: hostID, project: project)
                        try? makeDataFolder(project, only: only, into: bundles.appendingPathComponent(name, isDirectory: true))
                        _ = try await OfficeRenderClient.shared.ask("reviewLinks", ["bundle": name, "links": links["links"] ?? [Any](), "remove": deadLinks(project)])
                    case .nas:
                        try await ReviewHostClient.session(host) { _ = try await $0.ask(op) }
                    }
                    online[hostID] = true
                } catch {
                    online[hostID] = false
                    reached = false
                }
            }
            if reached { sentLinks[project] = state }
        }
    }

    /// Runs `then` once SendSync has sent every file of the folder as it is now (checked every 10 s, up to 6 hours).
    @ObservationIgnored private var waits: [String: Task<Void, Never>] = [:]
    func whenSent(_ folder: URL, _ then: @escaping @MainActor () async -> Void) {
        waits[folder.path]?.cancel()
        waits[folder.path] = Task {
            for _ in 0..<2160 {
                // (SendSync leaves files changed in the last 10 s for its next pass.)
                try? await Task.sleep(for: .seconds(11))
                if Task.isCancelled { return }
                await SendSync.shared.pass()
                if let sending = SendSync.shared.folders.first(where: { $0.url.standardizedFileURL == folder.standardizedFileURL }),
                   Self.allSent(folder, sent: sending.sent) {
                    await then()
                    break
                }
            }
            waits[folder.path] = nil
        }
    }

    /// Whether every file in the folder (hidden ones aside) was sent as it is now: same size and whole-second modification date.
    nonisolated static func allSent(_ folder: URL, sent: [String: SendSync.Stamp]) -> Bool {
        let root = folder.standardizedFileURL
        let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                                                   options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = items?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]), values.isRegularFile == true else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            let stamp = SendSync.Stamp(size: Int64(values.fileSize ?? 0), modified: (values.contentModificationDate ?? .now).timeIntervalSince1970.rounded())
            if sent[relative] != stamp { return false }
        }
        return true
    }

    func pullRegularly() {
        guard puller == nil, !publications.isEmpty, ScreenshotMode.scene == nil else { return }
        puller = Task {
            while !Task.isCancelled, !publications.isEmpty {
                await pull()
                // (Every few seconds while a NAS makes review copies, to show how far it is; new comments within 30 s while Deliver shows.)
                try? await Task.sleep(for: .seconds(hostState.values.contains { $0.making != nil } ? 5 : StudioNavigator.shared.page == .deliver ? 30 : 60))
            }
            puller = nil
        }
    }

    /// Off the host: what's left of the project there is published again, or the project and its links go.
    func remove(_ id: UUID) async {
        guard let publication = publications.first(where: { $0.id == id }) else { return }
        // Taken off by hand: not put back on by itself in this session (the link's row offers Publish).
        notPlaced[publication.scope.project] = notPlaced[publication.scope.project] ?? ""
        let project = publication.scope.project, name = Self.dataName(host: publication.host, project: project)
        let left = publications.contains { $0.id != id && $0.host == publication.host && $0.scope.project == project }
        let only = published(project, on: publication.host, without: id)
        if let host = host(publication.host), !Self.isDataHost(host.id) {
            switch host.kind {
            case .mac:
                let folder = folder(publication)
                if left {
                    try? makeDataFolder(project, only: only, into: folder)
                    whenSent(folder) { _ = try? await OfficeRenderClient.shared.ask("reviewReload", ["bundle": name]) }
                } else {
                    if let sending = SendSync.shared.folders.first(where: { $0.url.standardizedFileURL == folder.standardizedFileURL }) { SendSync.shared.remove(sending) }
                    _ = try? await OfficeRenderClient.shared.ask("reviewUnhost", ["bundle": name])
                    try? FileManager.default.removeItem(at: folder)
                }
            case .nas:
                try? await ReviewHostClient.session(host) { session in
                    if left {
                        _ = try await session.ask(["op": "publish", "manifest": self.manifest(project: project, only: only, host: host).json,
                                                   "remove": ["projects": [], "links": self.deadLinks(project)]])
                    } else {
                        let links = self.store.links.filter { $0.project == project }.map(\.id.uuidString)
                        _ = try await session.ask(["op": "publish", "manifest": ["format": 1, "projects": [], "links": []],
                                                   "remove": ["projects": [project.uuidString], "links": links]])
                    }
                }
            }
        }
        if !left { seqs[name] = nil; outbox[name] = nil }
        hostState[id] = nil
        publications.removeAll { $0.id == id }
        save()
    }
}

extension Deliver.Scope {
    var project: UUID {
        switch self {
        case .project(let id), .folder(_, let id), .asset(_, let id), .assets(_, let id): id
        }
    }
}

// MARK: - The always-on Mac's side

/// On the always-on Mac: data folders paired Macs published here ("Host published reviews for paired Macs"),
/// each served by its own helper in host mode (§12.1) even while the editor's Mac is gone, kept until removed.
@MainActor
@Observable
final class ReviewHosting {
    static let shared = ReviewHosting()
    static let settingKey = "reviewHostForPaired"

    /// The data folders in the Edit Anywhere inbox.
    private(set) var hosted: [String] = UserDefaults.standard.stringArray(forKey: "reviewHostedBundles") ?? []
    @ObservationIgnored private var helpers: [String: HostHelper] = [:]

    var isOn: Bool { UserDefaults.standard.bool(forKey: Self.settingKey) }

    static func register() {
        OfficeActions.register("reviewHost") { arguments, device in
            guard shared.isOn else { throw OfficeLink.Failure.office(String(localized: "This Mac doesn’t host reviews.")) }
            let folder = try shared.folder(arguments, device)
            if !shared.hosted.contains(folder.path) { shared.hosted.append(folder.path) }
            shared.saved()
            _ = try? await shared.helpers[folder.path]?.ask(["op": "reload"])
            return ["hosting": true]
        }
        OfficeActions.register("reviewReload") { arguments, device in
            let folder = try shared.folder(arguments, device)
            return try await shared.helper(folder).ask(["op": "reload"])
        }
        OfficeActions.register("reviewLinks") { arguments, device in
            let folder = try shared.folder(arguments, device)
            guard let links = arguments["links"] as? [[String: Any]], links.count <= 1000,
                  let remove = arguments["remove"] as? [String], remove.count <= 1000 else { throw OfficeActions.incomplete() }
            // Links only: the projects stay as published.
            return try await shared.helper(folder).ask(["op": "publish", "manifest": ["format": 1, "projects": [Any](), "links": links],
                                                        "remove": ["projects": [Any](), "links": remove]])
        }
        OfficeActions.register("reviewPull") { arguments, device in
            let folder = try shared.folder(arguments, device)
            return try await shared.helper(folder).ask(["op": "pull", "since": arguments["since"] as? Int ?? 0])
        }
        OfficeActions.register("reviewAppend") { arguments, device in
            let folder = try shared.folder(arguments, device)
            guard let entries = arguments["entries"] as? [[String: Any]], entries.count <= 5000 else { throw OfficeActions.incomplete() }
            return try await shared.helper(folder).ask(["op": "append", "entries": entries])
        }
        // 4.1.0 email without a NAS: the editor's Mac sets up mail on this Mac's hosts (every hosted folder's helper
        // sends for its own links, as a NAS does). Reading for any paired Mac; changes for an Admin (or Full Trust).
        OfficeActions.register("reviewMail") { arguments, device in
            guard shared.isOn else { throw OfficeLink.Failure.office(String(localized: "This Mac doesn’t host reviews.")) }
            guard let op = arguments["op"] as? [String: Any], let name = op["op"] as? String, mailOps.contains(name) else { throw OfficeActions.incomplete() }
            if name != "mail-state", !OfficeAccess.shared.isAdmin(device), !OfficeAccess.shared.rights(for: device).fullTrust { throw OfficeActions.refused() }
            return try await shared.mail(op)
        }
        OfficeActions.register("reviewUnhost") { arguments, device in
            let folder = try shared.folder(arguments, device)
            shared.hosted.removeAll { $0 == folder.path }
            shared.saved()
            try? FileManager.default.removeItem(at: folder)
            return ["hosting": false]
        }
    }

    nonisolated static let mailOps: Set<String> = ["mail-set", "mail-state", "mail-test", "subscriber-set", "subscriber-remove", "hook-set"]

    /// One mail op over the hosted folders: a test from one, a webhook to its project's folder, the state merged, the
    /// rest to every one (an id only one of them has: that one's answer).
    private func mail(_ op: [String: Any]) async throws -> [String: Any] {
        let all = hosted.compactMap { path in helpers[path].map { (path, $0) } }
        guard let first = all.first else { throw OfficeLink.Failure.office(String(localized: "This Mac doesn’t host a review yet.")) }
        switch op["op"] as? String {
        case "mail-test": return try await first.1.ask(op)
        case "hook-set":
            let project = String((op["project"] as? String ?? "").prefix(8))
            guard project.count == 8, let target = all.first(where: { URL(fileURLWithPath: $0.0).lastPathComponent.hasPrefix("Pluck Review \(project)") }) else {
                throw OfficeActions.incomplete()
            }
            return try await target.1.ask(op)
        case "mail-state":
            var merged: [String: Any] = [:], subscribers: [Any] = [], hooks: [String: Any] = [:], queued = 0, sent = 0
            for (_, helper) in all {
                guard let answer = try? await helper.ask(op) else { continue }
                if merged.isEmpty { merged = answer } else if let error = answer["lastError"] as? String { merged["lastError"] = error }
                subscribers += answer["subscribers"] as? [Any] ?? []
                hooks.merge(answer["hooks"] as? [String: Any] ?? [:]) { a, _ in a }
                queued += answer["queued"] as? Int ?? 0
                sent += answer["sentToday"] as? Int ?? 0
            }
            guard !merged.isEmpty else { throw OfficeLink.Failure.office(String(localized: "The review host isn’t running.")) }
            merged["subscribers"] = subscribers
            merged["hooks"] = hooks
            merged["queued"] = queued
            merged["sentToday"] = sent
            return merged
        default:
            var answers: [[String: Any]] = []
            for (_, helper) in all { if let answer = try? await helper.ask(op) { answers.append(answer) } }
            let failed = answers.first { (($0["error"] as? [String: Any])?["code"] as? String).map { $0 != "notFound" } ?? ($0["error"] != nil) }
            guard let answer = failed ?? answers.first(where: { $0["ok"] as? Bool == true }) ?? answers.first else {
                throw OfficeLink.Failure.office(String(localized: "The review host isn’t running."))
            }
            return answer
        }
    }

    /// A folder hosted later gets the mail setup the others have (settings and the password file, kept 0600), so its
    /// links' emails go out too.
    nonisolated static func seedMail(into folder: URL, from others: [URL]) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: folder.appendingPathComponent("mail.json").path),
              let source = others.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("mail.json").path) }) else { return }
        for name in ["mail.json", "mail.secret"] {
            let from = source.appendingPathComponent(name), to = folder.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: from) else { continue }
            guard fm.createFile(atPath: to.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                  let handle = try? FileHandle(forWritingTo: to) else { continue }
            try? handle.write(contentsOf: data)
            try? handle.close()
            if name == "mail.json" { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: to.path) }
        }
    }

    /// The data folder in the sending Mac's own inbox folder (only plain names).
    private func folder(_ arguments: [String: Any], _ device: OfficeRenderServer.Device) throws -> URL {
        let name = try OfficeActions.text(arguments["bundle"], 80)
        guard name.hasPrefix("Pluck Review "), !name.contains("/") else { throw OfficeActions.incomplete() }
        return try OfficeInbox.shared.target(name, from: OfficeInbox.folderName(device.name, id: device.id))
    }

    private func helper(_ folder: URL) throws -> HostHelper {
        guard hosted.contains(folder.path), let helper = helpers[folder.path] else { throw OfficeLink.Failure.office(String(localized: "This Mac doesn’t host that review.")) }
        return helper
    }

    private func saved() {
        UserDefaults.standard.set(hosted, forKey: "reviewHostedBundles")
        update()
    }

    /// A helper per hosted folder while hosting is on.
    func update() {
        let wanted = isOn && ScreenshotMode.scene == nil ? Set(hosted) : []
        for (path, helper) in helpers where !wanted.contains(path) { helper.stop(); helpers[path] = nil }
        for path in wanted where helpers[path] == nil {
            Self.seedMail(into: URL(fileURLWithPath: path), from: hosted.filter { $0 != path }.map { URL(fileURLWithPath: $0) })
            helpers[path] = HostHelper(dir: path)
        }
    }
}

/// One `pluck-review` in host mode on a data folder, with §12.6's ops on its stdin, one at a time.
@MainActor
final class HostHelper {
    private var process: Process?
    private var input: FileHandle?
    private var waiting: [CheckedContinuation<[String: Any], Error>] = []

    init(dir: String) {
        guard FileManager.default.isExecutableFile(atPath: DeliverLink.helper.path) else { return }
        let process = Process()
        process.executableURL = DeliverLink.helper
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        // A helper that died fails the write instead of ending Pluck, and its waiting asks fail.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.terminationHandler = { [weak self] _ in Task { @MainActor in self?.failWaiting() } }
        guard (try? process.run()) != nil else { return }
        self.process = process
        input = stdin.fileHandleForWriting
        // alwaysOn: this Mac ranks below both NAS roles, so it serves a room only while no NAS holds it.
        let settings: [String: Any] = ["signal": DeliverLink.signal, "stun": ["stun.cloudflare.com:3478"], "maxPeers": 20, "alwaysOn": true,
                                       "local": false, "host": ["dir": dir, "media": [], "listen": NSNull(), "admin": NSNull()]]
        write(settings)
        let reader = LineReader()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            for line in reader.add(chunk) {
                guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let answer = json["host"] as? [String: Any] else { continue }
                Task { @MainActor in self?.answered(answer) }
            }
        }
    }

    private func write(_ line: [String: Any]) {
        guard let input, var data = try? JSONSerialization.data(withJSONObject: line) else { return }
        data.append(0x0A)
        try? input.write(contentsOf: data)
    }

    private func answered(_ answer: [String: Any]) {
        guard !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        if let error = answer["error"] as? String { next.resume(throwing: OfficeLink.Failure.office(error)) } else { next.resume(returning: answer) }
    }

    func ask(_ op: [String: Any]) async throws -> [String: Any] {
        guard process?.isRunning == true else { throw OfficeLink.Failure.office(String(localized: "The review host isn’t running.")) }
        return try await withCheckedThrowingContinuation { continuation in
            waiting.append(continuation)
            write(["host": op])
        }
    }

    func stop() {
        try? input?.close()
        process?.terminate()
        failWaiting()
    }

    private func failWaiting() {
        let pending = waiting
        waiting = []
        for continuation in pending { continuation.resume(throwing: CancellationError()) }
    }
}

/// The server and share each /Volumes mount comes from (its remount URL), looked up once a minute per volume.
final class ShareVolumes: @unchecked Sendable {
    struct Share: Equatable { var server: String; var name: String }
    private let lock = NSLock()
    private var known: [String: (share: Share?, at: Date)] = [:]
    /// Tests: volumes as if mounted (no real share needed).
    var fake: [String: Share]?
    /// Tests: what a server name resolves to (no network).
    var resolver: (@Sendable (String) -> Set<String>)?
    private var servers: Set<String> = []
    /// Each mount's server and each NAS address → its IPs, looked up off the main thread (refresh); read only from here.
    private var addresses: [String: Set<String>] = [:]

    /// The paired NAS hosts (ReviewPublish keeps this current): whose shares may stand for a root by its name.
    func setServers(_ hosts: [Deliver.Host]) {
        let list = Set(hosts.filter { $0.kind == .nas }.compactMap { $0.address?.split(separator: ":").first.map { $0.lowercased() } })
        lock.lock(); defer { lock.unlock() }
        servers = list
    }

    func paired(_ server: String) -> Bool {
        let list = lock.withLock { servers }
        return list.contains { matches(server, $0) }
    }

    /// One server: the same name, or names that resolved to a common IP (a Bonjour share "WideOpen-2._smb._tcp.local"
    /// and the NAS's "10.0.22.187"). Only the cache: never waits on the network.
    func matches(_ server: String, _ address: String) -> Bool {
        if Self.same(server, address) { return true }
        lock.lock(); defer { lock.unlock() }
        guard let a = addresses[server], let b = addresses[address] else { return false }
        return !a.isDisjoint(with: b)
    }

    /// The /Volumes mounts that come from a server (the stand-ins while testing).
    func volumes() -> [String] {
        if let fake = lock.withLock({ fake }) { return fake.keys.sorted() }
        return Self.mountTable().keys.filter { $0.hasPrefix("/Volumes/") }.sorted()
    }

    /// Looks up every mount's server and every paired NAS address again, on a background queue.
    func refresh() async {
        lock.withLock { known = [:] } // (a volume just mounted)
        let names = Set(volumes().compactMap { share($0)?.server }).union(lock.withLock { servers })
        let resolve = lock.withLock { resolver } ?? Self.lookup
        let found = await withCheckedContinuation { (done: CheckedContinuation<[String: Set<String>], Never>) in
            DispatchQueue.global(qos: .utility).async {
                done.resume(returning: Dictionary(uniqueKeysWithValues: names.map { ($0, resolve($0)) }))
            }
        }
        lock.withLock { addresses = found }
    }

    /// The name to look up for a mount's server: a Bonjour instance becomes its .local host name.
    static func hostName(_ name: String) -> String {
        guard let service = name.range(of: "._"), name.contains("._tcp.") else { return name }
        return (String(name[..<service.lowerBound]).removingPercentEncoding ?? "").replacingOccurrences(of: " ", with: "-") + ".local"
    }

    /// A name's IPs (getaddrinfo, blocking: never on the main thread). A Bonjour service instance
    /// ("<Instance>._smb._tcp.local") is tried as "<Instance>.local".
    /// shortcut: assumes the instance name is the host name (TrueNAS, macOS and Synology defaults); a renamed service would need a DNS-SD resolve.
    @Sendable static func lookup(_ name: String) -> Set<String> {
        let host = hostName(name)
        var hints = addrinfo(), list: UnsafeMutablePointer<addrinfo>?
        hints.ai_socktype = SOCK_STREAM
        guard !host.isEmpty, getaddrinfo(host, nil, &hints, &list) == 0, let list else { return [] }
        defer { freeaddrinfo(list) }
        var found: Set<String> = []
        for entry in sequence(first: list, next: { $0.pointee.ai_next }) {
            var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 {
                found.insert(String(cString: text))
            }
        }
        return found
    }

    /// One server under two spellings ("nas" and "nas.local").
    static func same(_ a: String, _ b: String) -> Bool { a == b || a.hasPrefix(b + ".") || b.hasPrefix(a + ".") }

    func share(_ volume: String) -> Share? {
        lock.lock(); defer { lock.unlock() }
        if let fake { return fake[volume] }
        if let hit = known[volume], Date.now.timeIntervalSince(hit.at) < 60 { return hit.share }
        let share = Self.mountTable()[volume]
        known[volume] = (share, .now)
        return share
    }

    /// Every network mount's server and share from the kernel's mount table (MNT_NOWAIT): never touches the share
    /// itself, so a NAS that stopped answering can't stall the caller (the remount-URL lookup could, in fsctl).
    static func mountTable() -> [String: Share] {
        var list: UnsafeMutablePointer<statfs>?
        let count = Int(getmntinfo(&list, MNT_NOWAIT))
        guard count > 0, let list else { return [:] }
        var table: [String: Share] = [:]
        for entry in UnsafeBufferPointer(start: list, count: count) {
            var e = entry
            let point = withUnsafeBytes(of: &e.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let from = withUnsafeBytes(of: &e.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            if let share = parse(from: from) { table[point] = share }
        }
        return table
    }

    /// "//user@server/share" (smbfs, afpfs, webdav-less) or "server:/path" (nfs) → server and share; nil for local disks.
    static func parse(from: String) -> Share? {
        if from.hasPrefix("//") {
            let rest = from.dropFirst(2)
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            var server = String(rest[..<slash])
            if let at = server.lastIndex(of: "@") { server = String(server[server.index(after: at)...]) }
            if let colon = server.firstIndex(of: ":") { server = String(server[..<colon]) }
            let name = rest[rest.index(after: slash)...].split(separator: "/").first.map(String.init) ?? ""
            guard !server.isEmpty, !name.isEmpty else { return nil }
            return Share(server: server.lowercased(), name: name.removingPercentEncoding ?? name)
        }
        if let colon = from.firstIndex(of: ":"), from[from.index(after: colon)...].hasPrefix("/") {
            let server = String(from[..<colon])
            let name = from[from.index(after: colon)...].split(separator: "/").last.map(String.init) ?? ""
            guard !server.isEmpty, !name.isEmpty, !server.contains("/") else { return nil }
            return Share(server: server.lowercased(), name: name)
        }
        return nil
    }
}

let shareVolumes = ShareVolumes()

