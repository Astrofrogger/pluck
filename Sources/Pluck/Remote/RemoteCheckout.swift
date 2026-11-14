import Foundation

/// Resolve projects kept on the host for remote editors, as numbered .drp versions. One Mac at a time
/// has a project checked out (everyone sees which); checking in stores a new version, an earlier one
/// can be restored (copied as the newest), and a render always uses the version it was sent with.
@MainActor
@Observable
final class RemoteCheckout {
    static let shared = RemoteCheckout(folder: RemoteRenderQueue.support.appendingPathComponent("Resolve Projects", isDirectory: true))

    struct Version: Codable, Hashable {
        var number: Int
        var date: Date
        var by: String
        var size: Int64
        var restoredFrom: Int?
    }

    struct Project: Codable, Identifiable, Hashable {
        var id: UUID
        var name: String
        /// The share renders go into (the one it was built from, or the editor's footage).
        var share: String?
        var holder: UUID?
        var holderName: String?
        var since: Date?
        var versions: [Version] = []
        var latest: Int { versions.last?.number ?? 0 }

        func summary(for device: UUID) -> [String: Any] {
            var result: [String: Any] = ["id": id.uuidString, "name": name, "latest": latest, "mine": holder == device,
                                         "versions": versions.map { ["number": $0.number, "date": $0.date.timeIntervalSince1970, "by": $0.by,
                                                                     "size": $0.size, "restoredFrom": $0.restoredFrom ?? 0] }]
            if let holderName { result["holder"] = holderName }
            if let since { result["since"] = since.timeIntervalSince1970 }
            return result
        }
    }

    let folder: URL
    private(set) var projects: [Project] = []
    private var index: URL { folder.appendingPathComponent("projects.json") }

    init(folder: URL) {
        self.folder = folder
        projects = (try? JSONDecoder().decode([Project].self, from: Data(contentsOf: index))) ?? []
    }

    func file(_ id: UUID, version: Int) -> URL {
        folder.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent("v\(version).drp")
    }

    func project(_ id: UUID) throws -> Project { projects[try position(id)] }

    private func position(_ id: UUID) throws -> Int {
        guard let index = projects.firstIndex(where: { $0.id == id }) else {
            throw OfficeLink.Failure.office(String(localized: "That project isn’t on the host Mac any more."))
        }
        return index
    }

    /// Only the Mac that has it (or anyone, when nobody has it) may change a project.
    private func mayChange(_ project: Project, _ device: UUID) throws {
        if let holder = project.holder, holder != device {
            throw OfficeLink.Failure.office(String(localized: "\(project.holderName ?? String(localized: "Another Mac")) has this project checked out."))
        }
    }

    func checkOut(_ id: UUID, by device: UUID, name: String) throws -> Project {
        let at = try position(id)
        try mayChange(projects[at], device)
        projects[at].holder = device
        projects[at].holderName = name
        projects[at].since = .now
        save()
        return projects[at]
    }

    /// Gives a project back without a new version. `device` nil: the host lets go of it for anyone.
    func release(_ id: UUID, by device: UUID?) throws {
        let at = try position(id)
        if let device { try mayChange(projects[at], device) }
        projects[at].holder = nil
        projects[at].holderName = nil
        projects[at].since = nil
        save()
    }

    /// Stores `file` (moved in) as the newest version of `id`, or of a new project `name` when `id` is nil.
    /// `keep`: stays checked out to this Mac (to go on editing, or for a render of this version).
    @discardableResult
    func checkIn(_ id: UUID?, name: String, share: String?, file: URL, by device: UUID, deviceName: String, keep: Bool,
                 newID: UUID = UUID()) throws -> (Project, Version) {
        let at: Int
        if let id {
            at = try position(id)
            try mayChange(projects[at], device)
        } else {
            projects.append(Project(id: newID, name: name, share: share))
            at = projects.count - 1
        }
        if projects[at].share == nil { projects[at].share = share }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        let version = Version(number: projects[at].latest + 1, date: .now, by: deviceName, size: size)
        let target = self.file(projects[at].id, version: version.number)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: file, to: target)
        projects[at].versions.append(version)
        projects[at].holder = keep ? device : nil
        projects[at].holderName = keep ? deviceName : nil
        projects[at].since = keep ? .now : nil
        save()
        return (projects[at], version)
    }

    /// An earlier version copied as the newest one (nothing is lost: the versions after it stay).
    @discardableResult
    func restore(_ id: UUID, version: Int, by device: UUID, deviceName: String) throws -> Version {
        let at = try position(id)
        try mayChange(projects[at], device)
        guard projects[at].versions.contains(where: { $0.number == version }) else {
            throw OfficeLink.Failure.office(String(localized: "That version isn’t on the host Mac any more."))
        }
        let copy = folder.appendingPathComponent(UUID().uuidString + ".drp")
        try FileManager.default.copyItem(at: file(id, version: version), to: copy)
        let keep = projects[at].holder == device
        try checkIn(id, name: projects[at].name, share: nil, file: copy, by: device, deviceName: deviceName, keep: keep)
        projects[at].versions[projects[at].versions.count - 1].restoredFrom = version
        save()
        return projects[at].versions[projects[at].versions.count - 1]
    }

    private func save() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(projects) { try? data.write(to: index, options: .atomic) }
    }
}
