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
        var lastSeen: Date? = nil
        /// What the owner calls each root ("nas1" → "Wide-open-2026"): the TrueNAS datasets or Proxmox folders from setup or Change Folders.
        var rootNames: [String: String]? = nil
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
    private(set) var online: [UUID: Bool] = [:]
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

    init(store: DeliverStore) {
        self.store = store
        hosts = (try? Data(contentsOf: hostsFile)).flatMap { try? Deliver.decoder.decode([Deliver.Host].self, from: $0) } ?? []
        publications = (try? Data(contentsOf: publishedFile)).flatMap { try? Deliver.decoder.decode([Deliver.Publication].self, from: $0) } ?? []
        seqs = (try? Data(contentsOf: seqsFile)).flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
        store.listeners.append { [weak self] in self?.heard($0) }
        for project in Set(publications.map(\.scope.project)) { sentLinks[project] = linkState(project) }
    }

    private var hostsFile: URL { store.root.appendingPathComponent("hosts.json") }
    private var publishedFile: URL { store.root.appendingPathComponent("published.json") }
    private var seqsFile: URL { store.root.appendingPathComponent("published-seq.json") }
    var bundles: URL { store.root.appendingPathComponent("Bundles", isDirectory: true) }

    private func save() {
        try? FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try? Deliver.encoder.encode(hosts).write(to: hostsFile, options: .atomic)
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
        return Deliver.Host(name: office.name, kind: .mac, address: office.device.uuidString)
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

    /// A NAS paired from its invitation (§13.2), or one whose details changed.
    func add(_ host: Deliver.Host) {
        hosts.removeAll { $0.id == host.id }
        hosts.append(host)
        save()
    }

    /// What a host said in its auth answer: its version and protocol, and that it answered.
    func seen(_ id: UUID, version: String?, protocol level: Int?, via: ReviewHostTunnel.Via) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        online[id] = true
        let changed = hosts[index].version != version || hosts[index].protocol != level
        hosts[index].version = version ?? hosts[index].version
        hosts[index].protocol = level ?? hosts[index].protocol
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
        return nil
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

    private func assets(_ scope: Deliver.Scope) -> [Deliver.Asset] {
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
        let downloads = links.contains { $0.allowDownload }
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
                if let host, !push.contains(version.id), let source = Self.reference(original?.path ?? version.path, on: host) {
                    item["source"] = source
                    item["size"] = 0
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
            // §6.1's link fields, as `ready.link` has them (the header goes as a bundle file with the branding).
            var info = DeliverServer.linkInfo(link, store: store)
            for key in ["title", "mode", "allowDownload", "latestOnly", "expires", "header"] { info[key] = nil }
            wire.merge(info) { a, _ in a }
            if case let (key, secret)? = keys {
                wire.merge(["reg": DeliverKeys.registerKey(root: secret), "auth": DeliverKeys.base64url(DeliverKeys.authKey(key)), "join": DeliverKeys.joinHash(key)]) { $1 }
                // Level 3 (§13.24) has no room signing key; the host sends a MAC hello for it.
                if store.code(link.id) != nil { wire["level"] = 3 } else { wire["sign"] = DeliverKeys.base64url(DeliverKeys.signSeed(root: secret)) }
            }
            wire["created"] = DeliverServer.date(link.created)
            wire["deadline"] = link.deadline.map { DeliverServer.date($0) as Any } ?? NSNull()
            if let madeOn = link.madeOn { wire["madeOn"] = madeOn }
            return wire.merging(Self.stamp(link)) { $1 }
        }
        let folders = content.folders.map { folder -> [String: Any] in
            (["id": folder.id.uuidString, "name": folder.name, "parent": folder.parent.map { $0.uuidString as Any } ?? NSNull()] as [String: Any])
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
            switch store.merge(comment) {
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
                    }
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
        let uploads = entries.compactMap { $0["upload"] as? [String: Any] }
        guard !uploads.isEmpty else { return }
        try? await ReviewHostClient.session(host) { session in
            for upload in uploads {
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

    /// Links that changed since hosts last heard go to every host the project is published on: live ones
    /// upserted, dead ones removed (the host closes their viewers). Not reached: tried again on the next pull.
    func sendLinks() async {
        for project in Set(publications.map(\.scope.project)) {
            let state = linkState(project)
            guard sentLinks[project] != state else { continue }
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
                // (Every few seconds while a NAS makes review copies, to show how far it is.)
                try? await Task.sleep(for: .seconds(hostState.values.contains { $0.making != nil } ? 5 : 60))
            }
            puller = nil
        }
    }

    /// Off the host: what's left of the project there is published again, or the project and its links go.
    func remove(_ id: UUID) async {
        guard let publication = publications.first(where: { $0.id == id }) else { return }
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
        OfficeActions.register("reviewUnhost") { arguments, device in
            let folder = try shared.folder(arguments, device)
            shared.hosted.removeAll { $0 == folder.path }
            shared.saved()
            try? FileManager.default.removeItem(at: folder)
            return ["hosting": false]
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
        for path in wanted where helpers[path] == nil { helpers[path] = HostHelper(dir: path) }
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
        let settings: [String: Any] = ["signal": DeliverLink.signal, "stun": ["stun.cloudflare.com:3478"], "maxPeers": 20,
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
