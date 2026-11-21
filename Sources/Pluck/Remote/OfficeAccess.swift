import Foundation

/// Edit Anywhere's roles (plan 2026-11-20 §1): Viewer, Downloader, Editor and Admin are names for sets of the per-Mac
/// `Device.Rights` flags, so the host enforces them as it always did. A paired Mac has a role of its own (`Device.role`;
/// none: "Custom", its stored flags), may belong to a person of the Deliver team (`Device.person`, whose role then
/// counts), and folders can give a person or Mac another role from there down (nearest wins, more or fewer rights).
///
/// Grants (people's roles and folder roles) are kept here and travel with the office group (`OfficeGroup.Shared.access`),
/// newest per key; a removed one stays as a dated tombstone so the removal reaches every office Mac.
@MainActor
@Observable
final class OfficeAccess {
    static let shared = OfficeAccess()
    nonisolated static let key = "remoteAccessGrants"
    typealias Rights = OfficeRenderServer.Device.Rights

    enum Role: String, Codable, CaseIterable, Identifiable {
        /// Only for folders: the folder is hidden from that person or Mac.
        case none, viewer, downloader, editor, admin
        var id: String { rawValue }

        /// Its flags: what an office Mac from before roles enforces (Full Trust is the Mac's own, kept apart).
        var rights: Rights {
            switch self {
            case .none: Rights(browse: false, proxies: false, originals: false, render: false)
            case .viewer: Rights(browse: true, proxies: false, originals: false, render: false)
            case .downloader: Rights(browse: true, proxies: true, originals: true, render: false)
            case .editor, .admin: Rights(browse: true, proxies: true, originals: true, render: true)
            }
        }

        var title: String {
            switch self {
            case .none: String(localized: "No Access")
            case .viewer: String(localized: "Viewer")
            case .downloader: String(localized: "Downloader")
            case .editor: String(localized: "Editor")
            case .admin: String(localized: "Admin")
            }
        }

        var help: String {
            switch self {
            case .none: String(localized: "Doesn’t see this folder")
            case .viewer: String(localized: "Browse and look at clips")
            case .downloader: String(localized: "Also fetch and stream proxies and originals")
            case .editor: String(localized: "Also render, send files and ask for files")
            case .admin: String(localized: "Also change who may do what, from a home Mac too")
            }
        }

        /// The roles a Mac or person can have (No Access only on a folder: to cut a Mac off, remove it).
        static let assignable: [Role] = [.viewer, .downloader, .editor, .admin]
    }

    /// A person's role (`folder` nil) or a person's or Mac's role in a folder and below.
    struct Grant: Codable, Hashable, Identifiable {
        /// A paired Mac's id, or "person:" and a Deliver team person's id.
        var subject: String
        /// A folder key (`OfficeAccess.folderKey`): the same NAS folder on every office Mac.
        var folder: String?
        /// A `Role` raw value; nil: taken away (kept so the removal syncs).
        var role: String?
        var changed: Date
        /// For people: the name it was given, shown when they're gone from the team.
        var name: String?

        var id: String { subject + "|" + (folder ?? "") }
        var live: Role? { role.flatMap(Role.init) }
    }

    private(set) var grants: [Grant]

    private init() {
        grants = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Grant].self, from: $0) } ?? []
    }

    private func save() {
        if let data = try? JSONEncoder().encode(grants) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    nonisolated static func person(_ id: String) -> String { "person:" + id }

    // MARK: - Working out what a Mac may do

    /// A Mac's rights in one place (nil: no folder, e.g. rendering): its role (or Custom flags), then its person's role,
    /// then the nearest folder grant to it or its person (the Mac's own wins at the same folder). Full Trust stays the Mac's.
    nonisolated static func rights(for device: OfficeRenderServer.Device, grants: [Grant], place: String?) -> Rights {
        var rights = role(for: device, grants: grants)?.rights ?? device.allowed
        let subjects = [device.id.uuidString] + (device.person.map { [person($0)] } ?? [])
        if let place {
            let nearest = grants.filter { grant in
                guard let folder = grant.folder, grant.live != nil, subjects.contains(grant.subject) else { return false }
                return place == folder || place.hasPrefix(folder + "/")
            }
            .max { ($0.folder?.count ?? 0, $0.subject == subjects[0] ? 1 : 0) < ($1.folder?.count ?? 0, $1.subject == subjects[0] ? 1 : 0) }
            if let role = nearest?.live { rights = role.rights }
        }
        rights.fullTrust = device.allowed.fullTrust
        return rights
    }

    /// A Mac's role before folders: its person's, else its own (nil: Custom).
    nonisolated static func role(for device: OfficeRenderServer.Device, grants: [Grant]) -> Role? {
        if let person = device.person,
           let role = grants.first(where: { $0.subject == Self.person(person) && $0.folder == nil })?.live, role != .none { return role }
        return device.role.flatMap(Role.init)
    }

    func rights(for device: OfficeRenderServer.Device, place: String? = nil) -> Rights {
        Self.rights(for: device, grants: grants, place: place)
    }

    func isAdmin(_ device: OfficeRenderServer.Device) -> Bool { !device.isPeer && Self.role(for: device, grants: grants) == .admin }

    /// The key of a folder inside a share: the NAS folder it is (the same on every office Mac however each shared it),
    /// or the share id on a local disk. Lowercased, like the NAS key (SMB doesn't tell case apart).
    static func folderKey(root: URL, share: String, relative: String) -> String {
        let base = RemoteShares.shared.share(root)?.nas ?? ("local:" + share)
        return (relative.isEmpty ? base : base + "/" + relative).lowercased()
    }

    // MARK: - Changing

    /// Sets (or with nil takes away) a person's role, or a person's or Mac's role in a folder.
    func set(subject: String, folder: String?, role: Role?, name: String? = nil) {
        let grant = Grant(subject: subject, folder: folder, role: role?.rawValue, changed: .now, name: name)
        grants.removeAll { $0.id == grant.id }
        grants.append(grant)
        save()
        if folder == nil, subject.hasPrefix("person:") { OfficeRenderServer.shared.personRoleChanged(String(subject.dropFirst("person:".count))) }
        changed()
    }

    /// A share's folder key changed (its NAS found, or mounted another way): its grants copied to the new key, so a No Access
    /// folder stays shut. Copies keep their date (the newer of two wins); the old ones stay for office Macs still on that key.
    func rekey(_ old: String, _ new: String) {
        let merged = Self.rekeyed(grants, old, new)
        guard merged != grants else { return }
        grants = merged
        save()
        changed()
    }

    nonisolated static func rekeyed(_ grants: [Grant], _ old: String, _ new: String) -> [Grant] {
        let old = old.lowercased(), new = new.lowercased()
        guard old != new else { return grants }
        var out = grants
        for grant in grants {
            guard let folder = grant.folder, folder == old || folder.hasPrefix(old + "/") else { continue }
            var copy = grant
            copy.folder = new + folder.dropFirst(old.count)
            if let have = out.first(where: { $0.id == copy.id }), have.changed >= copy.changed { continue }
            out.removeAll { $0.id == copy.id }
            out.append(copy)
        }
        return out
    }

    /// The grants of a group sync (newest per key).
    func adopt(_ theirs: [Grant]?) {
        guard let theirs, let merged = Self.merge(grants, theirs), merged != grants else { return }
        grants = merged
        save()
    }

    /// Two lists as one: the newest of each key, the same whichever way round. Nil (an office Mac from before roles
    /// sent none) keeps the other.
    nonisolated static func merge(_ a: [Grant]?, _ b: [Grant]?) -> [Grant]? {
        guard let a, let b else { return a ?? b }
        var out = Dictionary(a.map { ($0.id, $0) }, uniquingKeysWith: { $0.changed >= $1.changed ? $0 : $1 })
        for grant in b {
            guard let have = out[grant.id] else { out[grant.id] = grant; continue }
            if (grant.changed, grant.role ?? "") > (have.changed, have.role ?? "") { out[grant.id] = grant }
        }
        return out.values.sorted { $0.id < $1.id }
    }

    /// The live grants in one folder.
    func grants(in folder: String) -> [Grant] { grants.filter { $0.folder == folder && $0.live != nil } }

    /// A change counts on the other office Macs from their next request: sync now rather than in up to 30 s.
    func changed() {
        guard OfficeGroup.shared.isGrouped else { return }
        Task { await OfficeGroup.shared.syncAll() }
    }
}

// MARK: - From a home Mac (Admins)

extension OfficeAccess {
    static var adminRefusal: String { String(localized: "Only an Admin can change who may do what. Ask the office to make this Mac an Admin.") }

    static func register() {
        // → {macs: [{id, name, role, person}], here: {subject: role}} for a folder ({share, path}, optional).
        OfficeActions.register("accessList") { arguments, device in
            guard shared.isAdmin(device) else { throw OfficeLink.Failure.office(adminRefusal) }
            var here: [String: String] = [:]
            if arguments["share"] != nil {
                let place = try RemoteEditHost.share(arguments["share"])
                let folder = try RemoteEditHost.resolve(try OfficeActions.text(arguments["path"] ?? "", empty: true), in: place.root)
                let key = folderKey(root: place.root, share: place.id, relative: RemoteEditHost.relative(folder, in: place.root))
                for grant in shared.grants(in: key) { here[grant.subject] = grant.role }
            }
            let macs = OfficeRenderServer.shared.pairedMacs.map { mac -> [String: Any] in
                var item: [String: Any] = ["id": mac.id.uuidString, "name": mac.name]
                if let role = role(for: mac, grants: shared.grants) { item["role"] = role.rawValue }
                return item
            }
            return ["macs": macs, "here": here]
        }
        // {mac, role} (a Mac's own role) or {mac, share, path, role or none to take it away} (its role in that folder).
        OfficeActions.register("accessSet") { arguments, device in
            guard shared.isAdmin(device) else { throw OfficeLink.Failure.office(adminRefusal) }
            guard let id = UUID(uuidString: try OfficeActions.text(arguments["mac"], 40)) else { throw OfficeActions.incomplete() }
            guard OfficeRenderServer.shared.pairedMacs.contains(where: { $0.id == id }) else { throw OfficeActions.incomplete() }
            let role = (arguments["role"] as? String).flatMap(Role.init)
            if arguments["share"] != nil {
                let place = try RemoteEditHost.share(arguments["share"])
                let folder = try RemoteEditHost.resolve(try OfficeActions.text(arguments["path"] ?? "", empty: true), in: place.root)
                shared.set(subject: id.uuidString, folder: folderKey(root: place.root, share: place.id, relative: RemoteEditHost.relative(folder, in: place.root)),
                           role: role)
            } else {
                guard let role, Role.assignable.contains(role) else { throw OfficeActions.incomplete() }
                // A Mac of a person with a role: the person's role is the one that counts (as in the host's own menu).
                let mac = OfficeRenderServer.shared.pairedMacs.first { $0.id == id }
                if let person = mac?.person, let grant = shared.grants.first(where: { $0.subject == Self.person(person) && $0.folder == nil && $0.live != nil }) {
                    shared.set(subject: grant.subject, folder: nil, role: role, name: grant.name)
                } else {
                    OfficeRenderServer.shared.setRole(role, for: id)
                }
            }
            return ["set": true]
        }
        // → {url}: a one-time invitation for another Mac.
        OfficeActions.register("accessInvite") { _, device in
            guard shared.isAdmin(device) else { throw OfficeLink.Failure.office(adminRefusal) }
            return ["url": try await OfficeRenderServer.shared.invite().absoluteString]
        }
    }
}
