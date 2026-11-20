import CryptoKit
import Foundation
import os

/// Several office Macs as one office for Edit Anywhere ("Add another office Mac"), any number of them.
///
/// - Joining: an office Mac pairs with one of the group with a code (OfficeLink pairing, role "peer") and gets the
///   group's key: one device id and secret every office Mac of the group knows, so each asks each other over the office
///   network (they sit side by side). Removing an office Mac makes a new key, so it can't ask any more.
/// - Every 30 s each office Mac syncs with every other (`groupSync`): the members, the paired home Macs (so a Mac paired
///   with one is let in by all, a Mac removed on one goes on all), and the proxy folder on the NAS. Merging keeps the
///   newest of each, so a change on any Mac reaches all of them, however many.
/// - Shared folders stay per Mac (each mounts the NAS itself), recognised by the NAS share they're on (`nas`): the same
///   NAS folder has the same id on every office Mac (the smallest of theirs), and each Mac answers to all of them.
/// - Proxies are made into the NAS proxy folder by all of them: each job is a file in `.pluck-queue` there, and each
///   clip is taken by one Mac at a time with a claim file next to it (created exclusively; stale after `staleClaim`).
///
/// Removing an office Mac cuts that one Mac off, with no pairing again anywhere (owner, 2026-11-17):
/// - Every office Mac has a key pair of its own (`identity`, X25519; its public half is `Member.key`), and every home
///   Mac gets one too (`Office.identity`, registered once as `Device.key`, sealed with its pairing secret). Each pair of
///   Macs seals its questions with a secret only those two can work out (`link`: their key agreement). So what an office
///   Mac knew (the group's keys, every home Mac's pairing secret) stops counting: an office Mac answers another only as
///   a member (its key, in the members list), and a home Mac with a key only with that key.
/// - Removing one: it goes from the members list (and so from every office Mac's devices) and the group's key is new.
///   The group's key only lets in Macs from before that have no key of their own; it then travels sealed with the link
///   secrets, so the removed Mac can't read it on the network either, and old keys are never accepted.
/// - The removal reaches the other office Macs at their next sync (a merge never takes a removal back), and every home
///   Mac asks all the office Macs it knows ("officeGroup": each tells the removed ones) at every refresh, before its
///   first question: a home Mac away during the removal hears it from any office Mac left, whatever the removed one
///   says (`revoked`: a removal claimed by a Mac that's itself removed by one that isn't doesn't count).
/// - A removed Mac that's turned away by every other office Mac stops taking jobs from the NAS queue.
/// shortcut: a home Mac that never talked to the office since this build (no key yet) is still let in by its pairing
/// secret, which the removed Mac knows too; and an office Mac that was offline during the removal and is reached by the
/// removed Mac before any other can be misled by it. Both need a signed history (or pairing again) to close.
@MainActor
@Observable
final class OfficeGroup {
    static let shared = OfficeGroup()
    nonisolated static let account = "officeGroup"
    /// A claim not renewed for this long is from an office Mac that went away: another one takes the clip over.
    nonisolated static let staleClaim: TimeInterval = 10 * 60
    nonisolated static let claimRenewal: TimeInterval = 2 * 60
    static let syncEvery: TimeInterval = 30

    struct Key: Codable, Hashable {
        var device: UUID
        var secret: Data
        var version: Int
    }

    /// One shared folder of an office Mac: its own id, and the NAS folder it is ("smb://nas/footage/day 1").
    struct ShareKey: Codable, Hashable {
        var id: String
        var nas: String
    }

    struct Member: Codable, Hashable, Identifiable {
        var id: UUID
        var name: String
        /// On the office network (the office Macs ask each other there).
        var addresses: [String]
        /// Its iroh node id and relay, for home Macs.
        var iroh: String?
        var relay: String?
        var shares: [ShareKey] = []
        var updated: Date
        /// Its own public key (`identity`): the others ask it, and it them, with secrets of their own (`link`).
        var key: Data?
        /// Its Pluck version; nil: from before roles (it enforces only each Mac's flags, not folder roles).
        var version: String?
        /// Its wired Ethernet address, so another office Mac can wake it (OfficeWake); nil without one or from before.
        var ethernet: String?
    }

    /// How a home Mac reaches one office Mac (no keys).
    struct Reach: Codable, Hashable, Identifiable {
        var id: UUID
        var name: String
        var addresses: [String]
        var iroh: String?
        var relay: String?
        /// Its own public key: a home Mac seals its questions for this office Mac alone.
        var key: Data?
    }

    /// A folder on the NAS by the share it's on, so each office Mac finds it where it mounted it.
    struct Place: Codable, Hashable {
        var remount: String
        var path: String
        var changed: Date
    }

    /// What the office Macs share: after a sync the same on each.
    struct Shared: Codable, Hashable {
        var key: Key
        var members: [Member]
        var removed: [UUID] = []
        var devices: [OfficeRenderServer.Device] = []
        var removedDevices: [UUID] = []
        var proxyFolder: Place?
        /// People's and folders' roles (OfficeAccess); nil from an office Mac before roles, which keeps nothing of it.
        var access: [OfficeAccess.Grant]?
    }

    private struct Saved: Codable {
        var me: UUID
        var shared: Shared?
        /// The key before the last removal: to hand the new one to Macs that haven't got it yet (4.0.4 first builds).
        var previous: Key?
        /// The keys before the last few removals, newest first.
        var previousKeys: [Key]?
        var adoptedFolder: Date?
        /// This Mac's own private key (X25519), kept when it leaves a group: home Macs' questions are sealed for it.
        var identity: Data?
    }

    /// This Mac's own id in a group.
    private(set) var me: UUID
    private(set) var state: Shared?
    /// When each other office Mac last answered a sync.
    private(set) var seen: [UUID: Date] = [:]
    /// Why the NAS proxy folder the group uses isn't used here (not mounted).
    private(set) var problem: String?
    /// The keys before the last few removals, newest first (a Mac that missed two removals is still reached).
    @ObservationIgnored private var previous: [Key] = []
    @ObservationIgnored private var adoptedFolder: Date?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var clients: [UUID: OfficeRenderClient] = [:]
    /// What was last saved (a sync that changed nothing isn't saved again).
    @ObservationIgnored private var savedState: Shared?
    @ObservationIgnored private let identity: Curve25519.KeyAgreement.PrivateKey
    /// Every other office Mac turned this one away at the last sync: it was removed (it takes no more jobs from the NAS).
    private(set) var cutOff = false

    /// This Mac's public key (Member.key, Reach.key).
    var publicKey: Data { identity.publicKey.rawRepresentation }

    /// The secret only this Mac and the one with that public key can work out (a home Mac, another office Mac).
    nonisolated func link(with key: Data) -> Data? { Self.link(identity, key) }

    nonisolated static func link(_ mine: Curve25519.KeyAgreement.PrivateKey, _ theirs: Data) -> Data? {
        guard let other = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirs), other.rawRepresentation != mine.publicKey.rawRepresentation,
              let shared = try? mine.sharedSecretFromKeyAgreement(with: other) else { return nil }
        let keys = [mine.publicKey.rawRepresentation, theirs].sorted { $0.lexicographicallyPrecedes($1) }
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("pluck-group-link-v1".utf8), sharedInfo: keys[0] + keys[1],
                                              outputByteCount: 32).withUnsafeBytes { Data($0) }
    }

    var members: [Member] { state?.members ?? [] }
    /// This build's version, as the other office Macs see it (Member.version).
    nonisolated static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    /// Office Macs from before roles: they enforce each Mac's flags but not folder roles.
    var older: [Member] { others.filter { $0.version == nil } }
    var isGrouped: Bool { members.count > 1 }
    var others: [Member] { members.filter { $0.id != me } }

    private init() {
        let saved = OfficeLink.Keychain.load(Self.account).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        me = saved?.me ?? UUID()
        state = saved?.shared
        previous = saved?.previousKeys ?? (saved?.previous.map { [$0] } ?? [])
        adoptedFolder = saved?.adoptedFolder
        let known = saved?.identity.flatMap { try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0) }
        identity = known ?? Curve25519.KeyAgreement.PrivateKey()
        updateAliases()
        if known == nil { save() }
    }

    private func save() {
        let saved = Saved(me: me, shared: state, previous: previous.first, previousKeys: previous, adoptedFolder: adoptedFolder,
                          identity: identity.rawRepresentation)
        if let data = try? JSONEncoder().encode(saved) { OfficeLink.Keychain.save(data, as: Self.account) }
    }

    // MARK: - Coding

    nonisolated static func encode<T: Encodable>(_ value: T) -> String? {
        (try? JSONEncoder().encode(value))?.base64EncodedString()
    }

    nonisolated static func decode<T: Decodable>(_ type: T.Type) -> (String) -> T? {
        { text in Data(base64Encoded: text).flatMap { try? JSONDecoder().decode(type, from: $0) } }
    }

    // MARK: - Merging

    /// Two Macs' views of the group as one: the newer key, every member and paired Mac either knows (minus removed
    /// ones), the newest rights of each paired Mac, the newest proxy folder. Same result whichever way round.
    nonisolated static func merge(_ a: Shared, _ b: Shared) -> Shared {
        var out = a
        if (b.key.version, b.key.device.uuidString) > (a.key.version, a.key.device.uuidString) { out.key = b.key }
        let removed = Set(a.removed + b.removed), removedDevices = Set(a.removedDevices + b.removedDevices)
        out.removed = removed.sorted { $0.uuidString < $1.uuidString }
        out.removedDevices = removedDevices.sorted { $0.uuidString < $1.uuidString }
        var members = Dictionary(a.members.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for member in b.members where (members[member.id]?.updated ?? .distantPast) < member.updated { members[member.id] = member }
        out.members = members.values.filter { !removed.contains($0.id) }.sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
        var devices = Dictionary(a.devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for device in b.devices {
            guard var have = devices[device.id] else { devices[device.id] = device; continue }
            if (device.changed ?? .distantPast) > (have.changed ?? .distantPast) {
                have.rights = device.rights
                have.role = device.role
                have.person = device.person
                have.changed = device.changed
            }
            let more = Set((have.irohMore ?? []) + (device.irohMore ?? []))
            have.irohMore = more.isEmpty ? nil : more.sorted()
            have.key = Self.firstKey(have.key, device.key)
            devices[device.id] = have
        }
        out.devices = devices.values.filter { !removedDevices.contains($0.id) && !$0.isPeer }
            .sorted { ($0.added, $0.id.uuidString) < ($1.added, $1.id.uuidString) }
        if (b.proxyFolder?.changed ?? .distantPast) > (a.proxyFolder?.changed ?? .distantPast) { out.proxyFolder = b.proxyFolder }
        out.access = OfficeAccess.merge(a.access, b.access)
        return out
    }

    /// A home Mac's key as two office Macs had it: the one set (the same either way round if both were).
    nonisolated static func firstKey(_ a: Data?, _ b: Data?) -> Data? {
        guard let a, let b else { return a ?? b }
        return b.lexicographicallyPrecedes(a) ? b : a
    }

    /// The office Macs a home Mac stops trusting, from what each says was removed (`claims`: who says → which). A
    /// removal counts when the one saying it is trusted: not itself removed by one that is. A removed Mac saying the
    /// others were removed changes nothing once one Mac left says it was; two saying it of each other with no one else
    /// to tell: neither is trusted.
    nonisolated static func revoked(_ claims: [UUID: Set<UUID>]) -> Set<UUID> {
        let all = Set(claims.keys).union(claims.values.flatMap { $0 })
        var trusted = Set<UUID>(), out = Set<UUID>(), changed = true
        while changed {
            changed = false
            for mac in all where !trusted.contains(mac) && !out.contains(mac) {
                let against = claims.filter { $0.value.contains(mac) }.map(\.key)
                if against.allSatisfy(out.contains) { trusted.insert(mac); changed = true }
                else if against.contains(where: trusted.contains) { out.insert(mac); changed = true }
            }
        }
        return all.subtracting(trusted)
    }

    /// This Mac's view now: its own entry fresh, and its paired Macs as they are here.
    func local() -> Shared? {
        guard var shared = state else { return nil }
        let server = OfficeRenderServer.shared
        var mine = shared.members.first { $0.id == me } ?? Member(id: me, name: "", addresses: [], updated: .distantPast)
        let fresh = Member(id: me, name: Host.current().localizedName ?? "Mac", addresses: testAddresses ?? OfficeRenderServer.addresses(),
                           iroh: ownNode,
                           relay: server.network.relay, shares: ownShares(), updated: mine.updated, key: publicKey, version: Self.version, ethernet: OfficeWake.ethernet())
        if fresh != mine { mine = fresh; mine.updated = .now }
        shared.members.removeAll { $0.id == me }
        shared.members.append(mine)
        shared.devices = Self.merge(shared, Shared(key: shared.key, members: [], devices: server.pairedMacs)).devices
        shared.access = OfficeAccess.merge(shared.access, OfficeAccess.shared.grants)
        return shared
    }

    private var ownNode: String? {
        let network = OfficeRenderServer.shared.network
        guard network.transport == .iroh, case .running(_, let node) = network.state, !node.isEmpty else { return nil }
        return node
    }

    /// Tests: the addresses this Mac gives the group (its own test port).
    @ObservationIgnored var testAddresses: [String]?

    private func ownShares() -> [ShareKey] {
        RemoteShares.shared.shares.compactMap { share in
            share.nas.map { ShareKey(id: share.id ?? OfficeProxies.pathID(share.path), nas: $0) }
        }
    }

    // MARK: - Joining and leaving

    /// Another office Mac pairing with this one as a member (OfficeRenderServer.pair): the group, made first if this
    /// Mac had none, with it in.
    func admit(_ member: Member) -> Shared? {
        guard member.id != me else { return nil }
        if state == nil {
            state = Shared(key: Key(device: UUID(), secret: OfficeLink.randomBytes(32), version: 1), members: [])
        }
        guard var shared = local() else { return nil }
        var joining = member
        joining.updated = .now
        shared.removed.removeAll { $0 == member.id }
        shared.members.removeAll { $0.id == member.id }
        shared.members.append(joining)
        state = shared
        apply()
        start()
        return shared
    }

    /// Joins the group of an office Mac on this network with the code it shows (Macs → Add another office Mac).
    func join(_ target: OfficeRenderClient.Target, code: String) async throws {
        let asking = OfficeRenderClient(account: nil)
        // A fresh id, as after leave(): a Mac removed earlier and added again isn't taken out again by the old removal.
        me = UUID()
        let mine = Member(id: me, name: Host.current().localizedName ?? "Mac", addresses: testAddresses ?? OfficeRenderServer.addresses(),
                          shares: ownShares(), updated: .now, key: publicKey)
        guard let encoded = Self.encode(mine) else { throw OfficeLink.Failure.garbled }
        let answer = try await asking.pair(target, code: code, member: encoded)
        guard let theirs = (answer["group"] as? String).flatMap(Self.decode(Shared.self)) else {
            throw OfficeLink.Failure.office(String(localized: "That office Mac can’t make a group yet. Update Pluck on it."))
        }
        // (This Mac's own paired Macs join the group's.)
        state = Self.merge(theirs, Shared(key: theirs.key, members: [mine], devices: OfficeRenderServer.shared.pairedMacs))
        previous = []
        cutOff = false
        apply()
        start()
        await syncAll()
    }

    /// Takes an office Mac out of the group: out of the members (its link goes everywhere), and a new key, so it can't
    /// ask any more (the others get both at their next sync, sealed with their own link secrets).
    func remove(_ member: Member) async {
        guard var shared = local(), member.id != me else { return }
        shared.removed.append(member.id)
        shared.members.removeAll { $0.id == member.id }
        previous = Array(([shared.key] + previous).prefix(3))
        shared.key = Key(device: UUID(), secret: OfficeLink.randomBytes(32), version: shared.key.version + 1)
        state = shared
        apply()
        await syncAll()
    }

    /// This Mac leaves the group (the others are told first); its paired Macs stay paired here.
    func leave() async {
        guard var shared = local() else { return }
        shared.removed.append(me)
        shared.members.removeAll { $0.id == me }
        state = shared
        await syncAll(leaving: true)
        stop()
        state = nil
        previous = []
        cutOff = false
        adoptedFolder = nil
        clients = [:]
        apply()
        me = UUID()
        save()
    }

    /// A paired Mac removed here goes on every office Mac.
    func removed(device: UUID) {
        guard state != nil else { return }
        state?.removedDevices.append(device)
        state?.devices.removeAll { $0.id == device }
        save()
    }

    // MARK: - Syncing

    func start() {
        guard loop == nil, state != nil, ScreenshotMode.scene == nil else { return }
        loop = Task {
            while !Task.isCancelled {
                await syncAll()
                await scanQueue()
                try? await Task.sleep(for: .seconds(Self.syncEvery))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// How this Mac asks one other office Mac: as itself, with their link secret (nil key), or with the group's key (a
    /// Mac from before with no key of its own).
    func client(_ member: Member, key: Key?) -> OfficeRenderClient? {
        guard let way = key.map({ ($0.device, $0.secret) }) ?? member.key.flatMap({ link(with: $0) }).map({ (me, $0) }) else { return nil }
        let client = clients[member.id] ?? OfficeRenderClient(account: nil)
        clients[member.id] = client
        client.use(OfficeRenderClient.Office(address: member.addresses.first ?? "", addresses: member.addresses,
                                             name: member.name, device: way.0, secret: way.1))
        return client
    }

    /// Syncs with every other office Mac in turn (one from before: with the key before the last removal if it missed it).
    func syncAll(leaving: Bool = false) async {
        guard let mine = local(), let encoded = Self.encode(mine) else { return }
        if !leaving { state = mine }
        var refused = 0, others = 0
        for member in mine.members where member.id != me {
            others += 1
            for key in member.key != nil ? [nil] : [mine.key] + previous {
                let answer: [String: Any]
                do {
                    guard let client = client(member, key: key) else { continue }
                    answer = try await client.ask("groupSync", ["state": encoded], timeout: 20)
                } catch {
                    if case OfficeLink.Failure.refused = error, key == nil { refused += 1 }
                    continue
                }
                seen[member.id] = .now
                if !leaving, let theirs = (answer["state"] as? String).flatMap(Self.decode(Shared.self)) { receive(theirs) }
                break
            }
        }
        cutOff = others > 0 && refused == others
        if !leaving { apply() }
    }

    /// Another office Mac's view merged in.
    func receive(_ theirs: Shared) {
        guard let mine = local() else { return }
        let merged = Self.merge(mine, theirs)
        // Taken out of the group on another Mac: on our own from now on.
        if merged.removed.contains(me) {
            stop()
            state = nil
            previous = []
            cutOff = false
            apply()
            save()
            return
        }
        state = merged
        apply()
    }

    /// The group's state put to use here: paired Macs and the key, share ids, the proxy folder.
    func apply() {
        OfficeRenderServer.shared.adoptGroup(state)
        OfficeAccess.shared.adopt(state?.access)
        updateAliases()
        adoptProxyFolder()
        guard state != savedState || state == nil else { return }
        savedState = state
        save()
    }

    static func register() {
        OfficeActions.register("groupSync") { arguments, device in
            guard device.isPeer, let theirs = (arguments["state"] as? String).flatMap(decode(Shared.self)) else { throw OfficeActions.incomplete() }
            shared.receive(theirs)
            return ["state": shared.local().flatMap(encode) ?? ""]
        }
        // (For home Macs: how to reach each office Mac. An office from before doesn't know it: one office Mac.)
        // (Also this Mac's key, and the office Macs removed: a home Mac stops asking those.)
        OfficeActions.register("officeGroup") { _, _ in
            let view = shared.local()
            let reach = (view?.members ?? []).map { Reach(id: $0.id, name: $0.name, addresses: $0.addresses, iroh: $0.iroh, relay: $0.relay, key: $0.key) }
            return ["members": encode(reach) ?? "", "me": shared.me.uuidString, "key": shared.publicKey.base64EncodedString(),
                    "removed": encode(view?.removed ?? []) ?? ""]
        }
        // A home Mac's link to another office Mac of the group (a key of its own): let in by all of them.
        OfficeActions.register("groupNode") { arguments, device in
            let node = try OfficeActions.text(arguments["node"], 64)
            guard PrivateNetwork.isNodeID(node), !device.isPeer else { throw OfficeActions.incomplete() }
            OfficeRenderServer.shared.addNode(node, for: device.id)
            if let state = shared.state {
                let devices = merge(state, Shared(key: state.key, members: [], devices: OfficeRenderServer.shared.pairedMacs)).devices
                shared.state?.devices = devices
                shared.save()
            }
            return ["added": true]
        }
        OfficeWake.register()
    }

    // MARK: - Shares by NAS folder

    /// Own share id → the ids the other office Macs have for the same NAS folder.
    nonisolated static let sameShare = OSAllocatedUnfairLock(initialState: [String: Set<String>]())

    /// The id paired Macs see for a share: the smallest of the group's for the same NAS folder (its own when alone).
    nonisolated static func canonical(_ own: String) -> String {
        sameShare.withLock { $0[own] }.map { $0.union([own]).min() ?? own } ?? own
    }

    /// Own share id → the other office Macs' ids for the same NAS folder.
    nonisolated static func aliases(own: [ShareKey], others: [[ShareKey]]) -> [String: Set<String>] {
        var byNAS: [String: Set<String>] = [:]
        for list in others { for share in list { byNAS[share.nas, default: []].insert(share.id) } }
        var found: [String: Set<String>] = [:]
        for share in own { if let ids = byNAS[share.nas]?.subtracting([share.id]), !ids.isEmpty { found[share.id] = ids } }
        return found
    }

    func updateAliases() {
        let map = isGrouped ? Self.aliases(own: ownShares(), others: others.map(\.shares)) : [:]
        Self.sameShare.withLock { $0 = map }
    }

    /// Tests: folders that count as being on a NAS share (path prefix → remount address).
    nonisolated(unsafe) static var testVolumes: [(prefix: String, remount: String)] = []

    /// The NAS share a folder is on (its remount address, tidied) and the folder's path inside it; nil for a local disk.
    nonisolated static func place(_ folder: URL) -> (remount: String, path: String)? {
        let full = folder.standardizedFileURL.path
        if let test = testVolumes.first(where: { full == $0.prefix || full.hasPrefix($0.prefix + "/") }) {
            return (test.remount, String(full.dropFirst(test.prefix.count)))
        }
        guard let values = try? folder.resourceValues(forKeys: [.volumeURLForRemountingKey, .volumeURLKey, .volumeIsLocalKey]),
              values.volumeIsLocal == false, let remount = values.volumeURLForRemounting, let volume = values.volume else { return nil }
        let base = volume.standardizedFileURL.path
        guard full == base || full.hasPrefix(base + "/") else { return nil }
        return (tidied(remount), String(full.dropFirst(base == "/" ? 0 : base.count)))
    }

    /// "smb://user@NAS._smb._tcp.local/Footage" → "smb://nas/footage": the same NAS share however a Mac named it.
    /// shortcut: a NAS mounted by its IP address on one Mac and by its name on another isn't recognised; mount it the same way on all.
    nonisolated static func tidied(_ remount: URL) -> String {
        var host = (remount.host ?? "").lowercased()
        for suffix in ["._smb._tcp.local", "._afpovertcp._tcp.local", ".local"] where host.hasSuffix(suffix) { host.removeLast(suffix.count) }
        let path = (remount.path.removingPercentEncoding ?? remount.path).lowercased()
        return "\(remount.scheme?.lowercased() ?? "smb")://\(host)\(path)"
    }

    /// The key of a NAS folder (nil: not on a NAS).
    nonisolated static func nasKey(_ folder: URL) -> String? {
        place(folder).map { ($0.remount + $0.path).lowercased() }
    }

    /// Where a NAS folder is on this Mac (nil: its share isn't mounted here).
    nonisolated static func localURL(_ place: Place) -> URL? {
        if let test = testVolumes.first(where: { $0.remount == place.remount }) {
            return URL(fileURLWithPath: test.prefix + place.path, isDirectory: true)
        }
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeURLForRemountingKey], options: [.skipHiddenVolumes]) ?? []
        for volume in volumes {
            guard let remount = try? volume.resourceValues(forKeys: [.volumeURLForRemountingKey]).volumeURLForRemounting,
                  tidied(remount) == place.remount else { continue }
            let url = volume.appendingPathComponent(String(place.path.drop { $0 == "/" }), isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    // MARK: - The proxy folder

    /// The owner chose where proxies go: a NAS folder is the group's from now on (each Mac finds it on its own mount).
    func proxyFolderChosen(_ folder: URL?) {
        guard isGrouped, let folder, let place = Self.place(folder) else { return }
        state?.proxyFolder = Place(remount: place.remount, path: place.path, changed: .now)
        adoptedFolder = state?.proxyFolder?.changed
        problem = nil
        save()
        Task { await syncAll() }
    }

    private func adoptProxyFolder() {
        guard let place = state?.proxyFolder else { problem = nil; return }
        guard let url = Self.localURL(place) else {
            problem = String(localized: "The proxy folder the other office Macs use isn’t mounted on this Mac. Connect to the NAS in Finder.")
            return
        }
        problem = nil
        guard place.changed != adoptedFolder else { return }
        adoptedFolder = place.changed
        save()
        OfficeProxies.shared.adopt(url)
    }

    // MARK: - The proxy queue on the NAS

    /// One proxy request, as the office Macs share it.
    struct Job: Codable, Hashable {
        var id: UUID
        var share: String
        var paths: [String]
        var format: OfficeProxies.Format
        var device: UUID?
        var member: UUID
        var from: String
        var asked: Date
    }

    nonisolated static func queueFolder(_ proxies: URL) -> URL {
        proxies.appendingPathComponent(".pluck-queue", isDirectory: true)
    }

    /// Puts a job in the queue: written under a name of its own, then renamed into place (never seen half written).
    @discardableResult
    nonisolated static func publish(_ job: Job, in proxies: URL) -> Bool {
        let folder = queueFolder(proxies)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(job) else { return false }
        let temporary = folder.appendingPathComponent(".\(job.id.uuidString).\(UUID().uuidString.prefix(8)).tmp")
        guard (try? data.write(to: temporary, options: .withoutOverwriting)) != nil else { return false }
        if rename(temporary.path, folder.appendingPathComponent(job.id.uuidString + ".json").path) != 0 {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
        return true
    }

    nonisolated static func unpublish(_ id: UUID, in proxies: URL) {
        try? FileManager.default.removeItem(at: queueFolder(proxies).appendingPathComponent(id.uuidString + ".json"))
    }

    nonisolated static func queued(in proxies: URL) -> [Job] {
        let folder = queueFolder(proxies)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.compactMap { name in
            (try? Data(contentsOf: folder.appendingPathComponent(name))).flatMap { try? JSONDecoder().decode(Job.self, from: $0) }
        }
    }

    /// A request made here goes in the group's queue, so the other office Macs help with it.
    func publish(_ request: RemoteProxyJobs.Request) {
        guard isGrouped, request.peer == nil, let folder = OfficeProxies.shared.chosenFolder else { return }
        let job = Job(id: request.id, share: request.share, paths: request.paths, format: request.format, device: request.device,
                      member: me, from: Host.current().localizedName ?? "Mac", asked: request.asked)
        Task.detached { Self.publish(job, in: folder) }
    }

    func unpublish(_ id: UUID) {
        guard isGrouped, let folder = OfficeProxies.shared.chosenFolder else { return }
        Task.detached { Self.unpublish(id, in: folder) }
    }

    /// The other office Macs' jobs taken on here (each clip by whoever claims it first).
    func scanQueue() async {
        guard isGrouped, !cutOff, let folder = OfficeProxies.shared.chosenFolder else { return }
        let found = await RemoteShares.withTimeout("officeGroup.queue", nil, timeout: 10) { Self.queued(in: folder) }
        guard let jobs = found ?? nil else { return }
        RemoteProxyJobs.shared.take(jobs.filter { $0.member != me }, all: Set(jobs.map(\.id)))
    }

    // MARK: - Claims

    struct Claim: Sendable {
        var url: URL
        var token: String
        var mac: String
    }

    nonisolated static func claimURL(_ target: URL) -> URL {
        target.deletingLastPathComponent().appendingPathComponent("." + target.lastPathComponent + ".claim")
    }

    /// Who holds a claim and since when (its file's date when it can't be read: just being written).
    nonisolated static func holder(_ url: URL) -> (mac: String, time: Date, token: String)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
            return ("", date, "")
        }
        let lines = text.split(separator: "\n").map(String.init)
        guard lines.count >= 3, let seconds = Double(lines[1]) else {
            let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? .distantPast
            return (lines.first ?? "", date, "")
        }
        return (lines[0], Date(timeIntervalSince1970: seconds), lines[2])
    }

    /// Takes a clip for this Mac: the claim file next to its proxy, created exclusively (O_EXCL, which SMB keeps
    /// atomic). A claim older than `stale` is from a Mac that went away: moved aside (only one Mac's rename works),
    /// then taken. nil: another Mac has it.
    nonisolated static func claim(_ target: URL, mac: String, now: Date = .now, stale: TimeInterval = staleClaim) -> Claim? {
        let url = claimURL(target), token = UUID().uuidString
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        for _ in 0..<2 {
            let handle = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if handle >= 0 {
                let body = Array("\(mac)\n\(now.timeIntervalSince1970)\n\(token)\n".utf8)
                _ = body.withUnsafeBytes { write(handle, $0.baseAddress, $0.count) }
                close(handle)
                return Claim(url: url, token: token, mac: mac)
            }
            guard errno == EEXIST, let held = holder(url), now.timeIntervalSince(held.time) > stale else { return nil }
            let aside = url.path + "." + token + ".stale"
            guard rename(url.path, aside) == 0 else { return nil }
            // Moved a fresh one (another Mac took over in between): it goes back, and that Mac keeps it.
            if let moved = holder(URL(fileURLWithPath: aside)), moved.token != held.token {
                _ = rename(aside, url.path)
                return nil
            }
            unlink(aside)
        }
        return nil
    }

    /// Keeps a claim fresh while its clip is being made.
    nonisolated static func renew(_ claim: Claim, now: Date = .now) {
        guard holder(claim.url)?.token == claim.token else { return }
        try? Data("\(claim.mac)\n\(now.timeIntervalSince1970)\n\(claim.token)\n".utf8).write(to: claim.url)
    }

    /// Lets a clip go (only while the claim is still this Mac's).
    nonisolated static func release(_ claim: Claim) {
        if holder(claim.url)?.token == claim.token { unlink(claim.url.path) }
    }

    // MARK: - Choosing an office Mac (home)

    /// The office Mac to use: online ones only, not rendering first, then the fewest jobs; the one in use stays on a tie.
    nonisolated static func choose(_ candidates: [(UUID, OfficeRenderClient.MemberState)], current: UUID?) -> UUID? {
        let online = candidates.filter { $0.1.online }
        guard let best = order(online, first: nil).first, let top = online.first(where: { $0.0 == best })?.1 else { return nil }
        if let current, let now = online.first(where: { $0.0 == current })?.1, now.busy == top.busy, now.load == top.load { return current }
        return best
    }

    /// Every office Mac in the order to try: `first`, then online ones least busy first, then the offline ones.
    nonisolated static func order(_ candidates: [(UUID, OfficeRenderClient.MemberState)], first: UUID?) -> [UUID] {
        let sorted = candidates.sorted { a, b in
            (a.1.online ? 0 : 1, a.1.busy ? 1 : 0, a.1.load, a.0.uuidString) < (b.1.online ? 0 : 1, b.1.busy ? 1 : 0, b.1.load, b.0.uuidString)
        }.map(\.0)
        guard let first, sorted.contains(first) else { return sorted }
        return [first] + sorted.filter { $0 != first }
    }

    /// Each office Mac's shares as one list (same id: the same NAS folder), with who has each; a share only one Mac
    /// of several has gets that Mac's name after it.
    nonisolated static func mergeShares(_ lists: [(UUID, [OfficeRenderClient.RemoteShare])], names: [UUID: String])
        -> (shares: [OfficeRenderClient.RemoteShare], owners: [String: Set<UUID>]) {
        var shares: [OfficeRenderClient.RemoteShare] = [], owners: [String: Set<UUID>] = [:]
        for (member, list) in lists {
            for share in list {
                owners[share.id, default: []].insert(member)
                if let index = shares.firstIndex(where: { $0.id == share.id }) {
                    if !shares[index].online && share.online { shares[index] = share }
                } else {
                    shares.append(share)
                }
            }
        }
        if lists.count > 1 {
            for index in shares.indices {
                if let only = owners[shares[index].id], only.count == 1, let name = only.first.flatMap({ names[$0] }) {
                    shares[index].name += " · " + name
                }
            }
        }
        return (shares, owners)
    }
}
