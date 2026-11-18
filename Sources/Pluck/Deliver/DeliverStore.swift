import Foundation
import Security
import UniformTypeIdentifiers

/// The Deliver page's projects, comments, approvals, links and inbox, on disk under
/// Application Support/Pluck/Review (§1). Kept on the main actor and written atomically, like RemoteReview.
@MainActor
@Observable
final class DeliverStore {
    static let shared = DeliverStore(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pluck/Review", isDirectory: true))

    static let projectLimit = 200, assetLimit = 5000, versionLimit = 50, commentLimit = 2000, liveLinkLimit = 50
    static let textLimit = 2000, nameLimit = 80, authorLimit = 40

    let root: URL
    private(set) var projects: [Deliver.Project] = []
    private(set) var contents: [UUID: Deliver.ProjectContent] = [:]
    private(set) var links: [Deliver.ShareLink] = []
    private(set) var inbox: [Deliver.InboxItem] = []
    /// Goes up whenever comments or approvals change (views that show them reload).
    private(set) var commentsChanged = 0
    /// Goes up whenever a link's activity log grows.
    var activityChanged = 0
    /// When each project last had a comment.
    private(set) var lastComment: [UUID: Date] = [:]
    @ObservationIgnored private var comments: [UUID: [Deliver.Comment]] = [:]
    @ObservationIgnored private var owner: [UUID: UUID] = [:]

    /// Something browsers looking at the asset should hear about (DeliverServer fans it out).
    enum Event {
        case comment(String, Deliver.Comment)
        case commentDeleted(Deliver.Comment)
        case status(UUID, Deliver.Status, String)
        case assetChanged(UUID)
        case field(UUID, String, String)
        case linkOff(Deliver.ShareLink)
        case linksChanged
    }
    @ObservationIgnored var listeners: [(Event) -> Void] = []
    /// Where new versions' review copies are asked for (DeliverCopies; nothing in tests that make them themselves).
    @ObservationIgnored var copyMaker: ((_ asset: UUID, _ version: UUID) -> Void)?

    /// What changed here, for the data host's outbox (§13.1; DeliverSync). Written in the same step as the save.
    enum Journal {
        case objects(project: UUID?, meta: Bool, folders: [UUID], assets: [UUID], links: [UUID])
        case tombstones([Deliver.Tombstone])
        case entries([[String: Any]])
    }
    @ObservationIgnored var journal: ((Journal) -> Void)?
    /// The approval behind the next status event of an asset (the server adds its id to that event).
    @ObservationIgnored var lastApproval: [UUID: UUID] = [:]
    /// True while a sync round puts in what came from the host: nothing is stamped or journalled again.
    @ObservationIgnored var applying = false
    func note(_ entry: Journal) { if !applying { journal?(entry) } }
    func tombstone(_ kind: String, _ id: UUID, project: UUID?, rev: Int?) -> Deliver.Tombstone {
        Deliver.Tombstone(kind: kind, id: id, project: project, rev: (rev ?? 0) + 1,
                          at: Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded()), by: DeliverMerge.device)
    }

    /// What of an asset syncs: copy progress and this Mac's own paths stay out of the comparison.
    nonisolated static func synced(_ asset: Deliver.Asset) -> Deliver.Asset {
        var asset = asset
        for index in asset.versions.indices {
            if case .making = asset.versions[index].copy { asset.versions[index].copy = .pending }
            asset.versions[index].bookmark = nil
        }
        return asset
    }

    /// Changed folders and assets get their next rev; removed ones a tombstone. Returns what the outbox must hear,
    /// told once the content is stored (the outbox line is made from the store).
    private func stamp(_ project: UUID, before: Deliver.ProjectContent, after content: inout Deliver.ProjectContent) -> [Journal] {
        guard !applying else { return [] }
        let oldAssets = Dictionary(before.assets.map { ($0.id, Self.synced($0)) }) { a, _ in a }
        let oldFolders = Dictionary(before.folders.map { ($0.id, $0) }) { a, _ in a }
        var assets: [UUID] = [], folders: [UUID] = []
        for index in content.assets.indices where oldAssets[content.assets[index].id] != Self.synced(content.assets[index]) {
            DeliverMerge.bump(&content.assets[index])
            assets.append(content.assets[index].id)
        }
        for index in content.folders.indices where oldFolders[content.folders[index].id] != content.folders[index] {
            DeliverMerge.bump(&content.folders[index])
            folders.append(content.folders[index].id)
        }
        let kept = Set(content.assets.map(\.id)), keptFolders = Set(content.folders.map(\.id))
        let gone = before.assets.filter { !kept.contains($0.id) }.map { tombstone("asset", $0.id, project: project, rev: $0.rev) }
            + before.folders.filter { !keptFolders.contains($0.id) }.map { tombstone("folder", $0.id, project: project, rev: $0.rev) }
        var out: [Journal] = []
        if !assets.isEmpty || !folders.isEmpty { out.append(.objects(project: project, meta: false, folders: folders, assets: assets, links: [])) }
        if !gone.isEmpty { out.append(.tombstones(gone)) }
        return out
    }

    private func stampProject(_ index: Int) {
        guard !applying else { return }
        DeliverMerge.bump(&projects[index])
        note(.objects(project: projects[index].id, meta: true, folders: [], assets: [], links: []))
    }

    private func stampLink(_ index: Int) {
        guard !applying else { return }
        DeliverMerge.bump(&links[index])
        note(.objects(project: links[index].project, meta: false, folders: [], assets: [], links: [links[index].id]))
    }

    init(root: URL) {
        self.root = root
        load()
    }

    func tell(_ event: Event) { for listener in listeners { listener(event) } }

    // MARK: - Files

    private var projectsFile: URL { root.appendingPathComponent("projects.json") }
    private var linksFile: URL { root.appendingPathComponent("links.json") }
    private var inboxFile: URL { root.appendingPathComponent("inbox.json") }
    func folder(_ project: UUID) -> URL { root.appendingPathComponent("Projects/\(project.uuidString)", isDirectory: true) }
    private func commentsFile(_ project: UUID, _ asset: UUID) -> URL { folder(project).appendingPathComponent("comments/\(asset.uuidString).json") }
    func copies(_ version: UUID) -> URL { root.appendingPathComponent("Copies/\(version.uuidString)", isDirectory: true) }
    var copiesFolder: URL { root.appendingPathComponent("Copies", isDirectory: true) }

    private func read<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        (try? Data(contentsOf: url)).flatMap { try? Deliver.decoder.decode(type, from: $0) }
    }

    private func write<T: Encodable>(_ value: T, _ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Deliver.encoder.encode(value).write(to: url, options: .atomic)
    }

    func load() {
        projects = read([Deliver.Project].self, projectsFile) ?? []
        links = read([Deliver.ShareLink].self, linksFile) ?? []
        upgradeLegacyKeys()
        inbox = read([Deliver.InboxItem].self, inboxFile) ?? []
        contents = [:]
        owner = [:]
        comments = [:]
        for project in projects {
            let content = read(Deliver.ProjectContent.self, folder(project.id).appendingPathComponent("project.json")) ?? .init()
            contents[project.id] = content
            for asset in content.assets { owner[asset.id] = project.id }
            let files = (try? FileManager.default.contentsOfDirectory(at: folder(project.id).appendingPathComponent("comments"),
                                                                       includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            lastComment[project.id] = files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
        }
    }

    private func saveProjects() { write(projects, projectsFile) }
    private func saveLinks() { write(links, linksFile); tell(.linksChanged) }
    private func saveInbox() { write(inbox, inboxFile) }

    // MARK: - Projects

    @discardableResult
    func newProject(_ name: String) throws -> Deliver.Project {
        guard projects.count < Self.projectLimit else { throw Deliver.Failure("limit") }
        let name = Deliver.clean(name, limit: Self.nameLimit)
        let project = Deliver.Project(name: name.isEmpty ? String(localized: "Untitled Project") : name, order: projects.count)
        projects.append(project)
        stampProject(projects.count - 1)
        contents[project.id] = .init()
        saveProjects()
        write(Deliver.ProjectContent(), folder(project.id).appendingPathComponent("project.json"))
        return projects[projects.count - 1]
    }

    func rename(project id: UUID, to name: String) {
        let name = Deliver.clean(name, limit: Self.nameLimit)
        guard !name.isEmpty, let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].name = name
        stampProject(index)
        saveProjects()
    }

    func setHidden(_ id: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].hidden = true
        stampProject(index)
        saveProjects()
    }

    /// A project's feedback deadline (its links' own win); synced like any project change.
    func setDeadline(_ deadline: Date?, project id: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].deadline = deadline
        stampProject(index)
        saveProjects()
        tell(.linksChanged)
    }

    func moveProjects(from source: IndexSet, to destination: Int) {
        projects.move(fromOffsets: source, toOffset: destination)
        for index in projects.indices where projects[index].order != index { projects[index].order = index; stampProject(index) }
        saveProjects()
    }

    /// The project, its review copies and links go; the originals are never touched.
    func deleteProject(_ id: UUID) {
        for asset in contents[id]?.assets ?? [] { for version in asset.versions { try? FileManager.default.removeItem(at: copies(version.id)) } }
        for link in links where link.project == id && link.revoked == nil { revoke(link.id) }
        note(.tombstones([tombstone("project", id, project: id, rev: project(id)?.rev)]
                         + links.filter { $0.project == id }.map { tombstone("link", $0.id, project: id, rev: $0.rev) }))
        links.removeAll { $0.project == id }
        saveLinks()
        projects.removeAll { $0.id == id }
        contents[id]?.assets.forEach { owner[$0.id] = nil; comments[$0.id] = nil }
        contents[id] = nil
        inbox.removeAll { $0.project == id }
        saveInbox()
        Self.flushComments()
        try? FileManager.default.removeItem(at: folder(id))
        saveProjects()
    }

    func project(_ id: UUID) -> Deliver.Project? { projects.first { $0.id == id } }
    func content(_ project: UUID) -> Deliver.ProjectContent { contents[project] ?? .init() }

    /// Changes a project's folders and assets, then saves them.
    func edit(_ project: UUID, _ change: (inout Deliver.ProjectContent) throws -> Void) rethrows {
        guard var content = contents[project] else { return }
        let before = content
        try change(&content)
        let changes = stamp(project, before: before, after: &content)
        contents[project] = content
        for asset in content.assets { owner[asset.id] = project }
        write(content, folder(project).appendingPathComponent("project.json"))
        changes.forEach(note)
    }

    /// The project holding the asset, and the asset.
    func find(_ asset: UUID) -> (project: UUID, asset: Deliver.Asset)? {
        guard let project = owner[asset], let found = contents[project]?.assets.first(where: { $0.id == asset }) else { return nil }
        return (project, found)
    }

    func folderPath(_ folder: UUID?, in project: UUID) -> [Deliver.Folder] {
        let folders = content(project).folders
        var path: [Deliver.Folder] = [], current = folder
        while let id = current, let found = folders.first(where: { $0.id == id }), path.count < 9 {
            path.insert(found, at: 0)
            current = found.parent
        }
        return path
    }

    /// The folder and every folder inside it.
    func subfolders(_ folder: UUID, in project: UUID) -> Set<UUID> {
        let folders = content(project).folders
        var found: Set<UUID> = [folder], grew = true
        while grew {
            let more = folders.filter { $0.parent.map(found.contains) == true && !found.contains($0.id) }.map(\.id)
            grew = !more.isEmpty
            found.formUnion(more)
        }
        return found
    }

    @discardableResult
    func newFolder(_ name: String, in project: UUID, parent: UUID?) -> Deliver.Folder? {
        guard folderPath(parent, in: project).count < 8 else { return nil }
        let name = Deliver.clean(name, limit: Self.nameLimit)
        let folder = Deliver.Folder(name: name.isEmpty ? String(localized: "Untitled Folder") : name, parent: parent)
        edit(project) { $0.folders.append(folder) }
        return folder
    }

    func renameFolder(_ id: UUID, in project: UUID, to name: String) {
        let name = Deliver.clean(name, limit: Self.nameLimit)
        guard !name.isEmpty else { return }
        edit(project) { content in if let index = content.folders.firstIndex(where: { $0.id == id }) { content.folders[index].name = name } }
    }

    // MARK: - Adding files (the originals are never copied)

    nonisolated static func kind(_ url: URL) -> Deliver.Kind {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return .other }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .pdf) { return .document }
        return .other
    }

    private func version(_ url: URL, number: Int) -> Deliver.Version {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return Deliver.Version(number: number, path: url.path, bookmark: try? url.bookmarkData(), size: size)
    }

    /// Files and folders dropped on a project (a folder becomes a folder of its videos, sounds and pictures).
    @discardableResult
    func add(_ urls: [URL], to project: UUID, folder: UUID?) throws -> [Deliver.Asset] {
        var added: [Deliver.Asset] = []
        func walk(_ url: URL, parent: UUID?, depth: Int, dropped: Bool) throws {
            // A folder of numbered pictures is one video (an image sequence).
            if DeliverCopies.sequence(url) != nil {
                guard content(project).assets.count < Self.assetLimit else { throw Deliver.Failure("limit") }
                let asset = Deliver.Asset(name: url.lastPathComponent, folder: parent, kind: .video, versions: [version(url, number: 1)])
                edit(project) { $0.assets.append(asset) }
                added.append(asset)
                return
            }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                guard depth < 8, let made = newFolder(url.lastPathComponent, in: project, parent: parent) else { return }
                let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                                           options: [.skipsHiddenFiles, .skipsPackageDescendants])) ?? []
                for item in items.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                    try walk(item, parent: made.id, depth: depth + 1, dropped: false)
                }
                return
            }
            let kind = Self.kind(url)
            guard dropped || kind != .other else { return }
            guard content(project).assets.count < Self.assetLimit else { throw Deliver.Failure("limit") }
            let asset = Deliver.Asset(name: url.deletingPathExtension().lastPathComponent, folder: parent, kind: kind, versions: [version(url, number: 1)])
            edit(project) { $0.assets.append(asset) }
            added.append(asset)
        }
        for url in urls { try walk(url, parent: folder, depth: folderPath(folder, in: project).count, dropped: true) }
        // The newest first: the queue takes them in the order asked.
        for asset in added.reversed() { copyMaker?(asset.id, asset.current.id) }
        return added
    }

    /// Files chosen on a NAS host (Browse <NAS>): assets whose originals stay there; the NAS makes their copies.
    @discardableResult
    func addReferences(_ items: [(name: String, kind: Deliver.Kind, path: String, size: Int64)], to project: UUID) -> [Deliver.Asset] {
        let made = items.prefix(max(0, Self.assetLimit - content(project).assets.count)).map { item in
            Deliver.Asset(name: Deliver.clean(item.name, limit: Self.nameLimit), kind: item.kind, versions: [Deliver.Version(number: 1, path: item.path, size: item.size)])
        }
        edit(project) { $0.assets += made }
        return made
    }

    /// A client's upload on a data host (§13.25), by reference, under the upload's own id: added once, by whichever Mac.
    @discardableResult
    func addUpload(id: UUID, name: String, path: String, size: Int64, to project: UUID, folder: UUID?) -> Deliver.Asset? {
        guard find(id) == nil, self.project(project) != nil, content(project).assets.count < Self.assetLimit else { return nil }
        var version = Deliver.Version(number: 1, path: path, size: size)
        version.id = UUID(uuid: { var u = id.uuid; u.0 ^= 0xFF; return u }()) // the same on every Mac too
        let file = URL(fileURLWithPath: name)
        let asset = Deliver.Asset(id: id, name: Deliver.clean(file.deletingPathExtension().lastPathComponent, limit: Self.nameLimit), folder: folder,
                                  kind: Self.kind(file), versions: [version])
        edit(project) { $0.assets.append(asset) }
        return asset
    }

    /// A file dropped on an asset's card: the stack's next version.
    @discardableResult
    func addVersion(_ url: URL, to asset: UUID) throws -> Deliver.Version {
        guard let (project, found) = find(asset) else { throw Deliver.Failure("notFound") }
        guard found.versions.count < Self.versionLimit else { throw Deliver.Failure("limit") }
        let made = version(url, number: (found.versions.map(\.number).max() ?? 0) + 1)
        edit(project) { content in if let index = content.assets.firstIndex(where: { $0.id == asset }) { content.assets[index].versions.append(made) } }
        copyMaker?(asset, made.id)
        tell(.assetChanged(asset))
        return made
    }

    /// A file on a NAS host (`nas:<host>:<media path>`) as the stack's next version: the NAS makes its copies.
    @discardableResult
    func addVersion(reference path: String, size: Int64, to asset: UUID) throws -> Deliver.Version {
        guard let (project, found) = find(asset) else { throw Deliver.Failure("notFound") }
        guard found.versions.count < Self.versionLimit else { throw Deliver.Failure("limit") }
        let made = Deliver.Version(number: (found.versions.map(\.number).max() ?? 0) + 1, path: path, size: size)
        edit(project) { content in if let index = content.assets.firstIndex(where: { $0.id == asset }) { content.assets[index].versions.append(made) } }
        tell(.assetChanged(asset))
        return made
    }

    func update(asset id: UUID, _ change: (inout Deliver.Asset) -> Void) {
        guard let (project, _) = find(id) else { return }
        edit(project) { content in if let index = content.assets.firstIndex(where: { $0.id == id }) { change(&content.assets[index]) } }
    }

    /// A version's facts and copy state (DeliverCopies reports here).
    func update(version id: UUID, of asset: UUID, _ change: (inout Deliver.Version) -> Void) {
        update(asset: asset) { found in if let index = found.versions.firstIndex(where: { $0.id == id }) { change(&found.versions[index]) } }
    }

    func rename(asset id: UUID, to name: String) {
        let name = Deliver.clean(name, limit: Self.nameLimit)
        guard !name.isEmpty else { return }
        update(asset: id) { $0.name = name }
        tell(.assetChanged(id))
    }

    func move(asset id: UUID, to folder: UUID?) { update(asset: id) { $0.folder = folder } }

    /// One metadata field (§6.1): rating 0…5, keywords (≤ 20 of ≤ 40 chars), assignee, due (yyyy-MM-dd), notes (≤ 2,000).
    func setField(_ field: String, _ value: Any?, of asset: UUID, by author: String) throws {
        guard find(asset) != nil else { throw Deliver.Failure("notFound") }
        let value = value is NSNull ? nil : value
        var fields = find(asset)?.asset.fields ?? .init()
        switch field {
        case "rating":
            guard let rating = value as? Int ?? (value == nil ? 0 : nil), (0...5).contains(rating) else { throw Deliver.Failure("invalid") }
            fields.rating = rating == 0 ? nil : rating
        case "keywords":
            guard let words = value as? [String] ?? (value == nil ? [] : nil), words.count <= 20 else { throw Deliver.Failure("invalid") }
            let clean = words.map { Deliver.clean($0, limit: 40) }.filter { !$0.isEmpty }
            fields.keywords = clean.isEmpty ? nil : clean
        case "assignee":
            guard value == nil || value is String else { throw Deliver.Failure("invalid") }
            fields.assignee = (value as? String).map { Deliver.clean($0, limit: Self.authorLimit) }.flatMap { $0.isEmpty ? nil : $0 }
        case "due":
            guard value == nil || (value as? String).map({ $0.wholeMatch(of: #/\d{4}-\d{2}-\d{2}/#) != nil }) == true else { throw Deliver.Failure("invalid") }
            fields.due = value as? String
        case "notes":
            guard value == nil || (value as? String).map({ $0.count <= Self.textLimit }) == true else { throw Deliver.Failure("invalid") }
            fields.notes = (value as? String).flatMap { $0.isEmpty ? nil : $0 }
        default: throw Deliver.Failure("invalid")
        }
        update(asset: asset) { $0.fields = fields.isEmpty ? nil : fields }
        tell(.field(asset, field, author))
    }

    func setStatus(_ status: Deliver.Status, of asset: UUID, by author: String) {
        update(asset: asset) { $0.status = status }
        tell(.status(asset, status, author))
    }

    /// Takes a version out of its stack (never the last one); its review copies go.
    func removeVersion(_ version: UUID, of asset: UUID) {
        guard let (_, found) = find(asset), found.versions.count > 1 else { return }
        update(asset: asset) { $0.versions.removeAll { $0.id == version } }
        try? FileManager.default.removeItem(at: copies(version))
        tell(.assetChanged(asset))
    }

    /// A version as the current one (the end of the stack).
    func makeCurrent(_ version: UUID, of asset: UUID) {
        update(asset: asset) { found in
            if let index = found.versions.firstIndex(where: { $0.id == version }) { found.versions.append(found.versions.remove(at: index)) }
        }
        tell(.assetChanged(asset))
    }

    /// Out of the project: its review copies and comments go, the originals stay.
    func remove(asset id: UUID) {
        guard let (project, found) = find(id) else { return }
        for version in found.versions { try? FileManager.default.removeItem(at: copies(version.id)) }
        Self.flushComments()
        try? FileManager.default.removeItem(at: commentsFile(project, id))
        edit(project) { $0.assets.removeAll { $0.id == id } }
        owner[id] = nil
        comments[id] = nil
        tell(.assetChanged(id))
    }

    /// The original, found again through its bookmark if it moved.
    func original(_ version: Deliver.Version) -> URL? {
        if FileManager.default.fileExists(atPath: version.path) { return URL(fileURLWithPath: version.path) }
        var stale = false
        return version.bookmark.flatMap { try? URL(resolvingBookmarkData: $0, bookmarkDataIsStale: &stale) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    // MARK: - Comments

    func comments(_ asset: UUID) -> [Deliver.Comment] {
        if let cached = comments[asset] { return cached }
        guard let project = owner[asset] else { return [] }
        Self.flushComments()
        let loaded = read([Deliver.Comment].self, commentsFile(project, asset)) ?? []
        comments[asset] = loaded
        return loaded
    }

    func comments(_ asset: UUID, version: UUID) -> [Deliver.Comment] { comments(asset).filter { $0.version == version } }

    private func saveComments(_ list: [Deliver.Comment], _ asset: UUID) {
        guard let project = owner[asset] else { return }
        comments[asset] = list
        if let data = try? Deliver.encoder.encode(list) { Self.writeSoon(data, commentsFile(project, asset)) }
        lastComment[project] = .now
        commentsChanged += 1
    }

    /// Comment files are written off the main thread, the latest list per file winning, so a burst of
    /// ticks is one write. Reads and removals flush first.
    nonisolated private static let disk = DispatchQueue(label: "pluck.review.comments")
    nonisolated(unsafe) private static var pending: [URL: Data] = [:] // only touched on `disk`

    nonisolated private static func writeSoon(_ data: Data, _ url: URL) {
        disk.async {
            guard pending.updateValue(data, forKey: url) == nil else { return }
            disk.asyncAfter(deadline: .now() + 0.3) { writePending(url) }
        }
    }

    nonisolated private static func writePending(_ url: URL) {
        guard let data = pending.removeValue(forKey: url) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Every comment change on disk now (before reading files back, removing them, or quitting).
    nonisolated static func flushComments() {
        disk.sync { for url in pending.keys { writePending(url) } }
    }

    func comment(_ id: UUID) -> Deliver.Comment? {
        for project in contents.values { for asset in project.assets { if let found = comments(asset.id).first(where: { $0.id == id }) { return found } } }
        return nil
    }

    static func text(_ text: String) throws -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...textLimit).contains(text.count) else { throw Deliver.Failure("invalid") }
        return text
    }

    /// A new comment on a version, checked against the version's frames and §1's limits.
    @discardableResult
    func addComment(asset: UUID, version: UUID, frame: Int?, endFrame: Int? = nil, text: String, author: String,
                    token: String? = nil, link: UUID? = nil, drawing: Deliver.Drawing? = nil, page: Int? = nil, anchor: [Double]? = nil,
                    isInternal: Bool = false, attachments: [Deliver.Comment.Attachment]? = nil) throws -> Deliver.Comment {
        guard let (_, found) = find(asset), let made = found.versions.first(where: { $0.id == version }) else { throw Deliver.Failure("notFound") }
        let frames = found.kind == .image || found.kind == .document ? 1 : max(made.probe?.frames ?? 1, 1)
        if let frame {
            guard frame >= 0, frame < frames, (endFrame ?? frame) >= frame, (endFrame ?? frame) < frames else { throw Deliver.Failure("invalid") }
        } else if endFrame != nil { throw Deliver.Failure("invalid") }
        if let page { guard found.kind == .document, frame == nil, (1...max(made.pages ?? 1, 1)).contains(page) else { throw Deliver.Failure("invalid") } }
        if let anchor { guard anchor.count == 2, anchor.allSatisfy({ (0...1).contains($0) }) else { throw Deliver.Failure("invalid") } }
        if (attachments?.count ?? 0) > 6 { throw Deliver.Failure("limit") }
        if let drawing, !drawing.isValid { throw Deliver.Failure("invalid") }
        var list = comments(asset)
        guard list.filter({ $0.version == version }).count < Self.commentLimit else { throw Deliver.Failure("limit") }
        let comment = Deliver.Comment(asset: asset, version: version, frame: frame, endFrame: endFrame, text: try Self.text(text),
                                      author: Deliver.clean(author, limit: Self.authorLimit), authorToken: token, link: link, drawing: drawing,
                                      page: page, anchor: anchor, internal: isInternal ? true : nil, attachments: attachments?.isEmpty == false ? attachments : nil)
        var stamped = comment
        if !applying { DeliverMerge.bump(&stamped) }
        list.append(stamped)
        list.sort { ($0.position, $0.created) < ($1.position, $1.created) }
        saveComments(list, asset)
        if let entry = ReviewPublish.entry(stamped) { note(.entries([entry])) }
        tell(.comment("add", stamped))
        return stamped
    }

    /// Changes one comment (`nil` from `change` deletes it).
    @discardableResult
    func change(comment id: UUID, _ change: (inout Deliver.Comment) throws -> Bool) throws -> Deliver.Comment {
        guard let found = comment(id) else { throw Deliver.Failure("notFound") }
        var list = comments(found.asset)
        guard let index = list.firstIndex(where: { $0.id == id }) else { throw Deliver.Failure("notFound") }
        let before = list[index]
        if try change(&list[index]) {
            // A reply that went is remembered, so a merge doesn't bring it back (§13.0 MC).
            let dropped = Set(before.replies.map(\.id)).subtracting(list[index].replies.map(\.id))
            if !dropped.isEmpty { list[index].deletedReplies = Array(Set(list[index].deletedReplies ?? []).union(dropped)) }
            if list[index] != before, !applying { DeliverMerge.bump(&list[index]) }
            let changed = list[index]
            saveComments(list, found.asset)
            if let entry = ReviewPublish.entry(changed) { note(.entries([entry])) }
            tell(.comment("edit", changed))
            return changed
        }
        let gone = list.remove(at: index)
        saveComments(list, found.asset)
        note(.entries([["deleted": ["id": gone.id.uuidString, "asset": gone.asset.uuidString, "version": gone.version.uuidString, "rev": (gone.rev ?? 0) + 1]]]))
        tell(.commentDeleted(gone))
        return gone
    }

    enum Merged { case added, changed, same }

    /// A comment written elsewhere (a host's comments.jsonl): added once by id, or put in place of the one here.
    @discardableResult
    func merge(_ comment: Deliver.Comment) -> Merged {
        guard let found = find(comment.asset), found.asset.versions.contains(where: { $0.id == comment.version }) else { return .same }
        var list = comments(comment.asset)
        if let index = list.firstIndex(where: { $0.id == comment.id }) {
            let merged = DeliverMerge.comment(stored: list[index], incoming: comment)
            // (Compared as written: dates keep whole seconds on disk.)
            guard (try? Deliver.encoder.encode(list[index])) != (try? Deliver.encoder.encode(merged)) else { return .same }
            list[index] = merged
            saveComments(list, comment.asset)
            tell(.comment("edit", merged))
            return .changed
        }
        guard list.filter({ $0.version == comment.version }).count < Self.commentLimit else { return .same }
        list.append(comment)
        list.sort { ($0.position, $0.created) < ($1.position, $1.created) }
        saveComments(list, comment.asset)
        tell(.comment("add", comment))
        return .added
    }

    @discardableResult
    func reply(to comment: UUID, text: String, author: String, token: String? = nil, isInternal: Bool = false) throws -> Deliver.Comment {
        let text = try Self.text(text)
        return try change(comment: comment) { found in
            guard found.replies.count < 100 else { throw Deliver.Failure("limit") }
            found.replies.append(.init(text: text, author: Deliver.clean(author, limit: Self.authorLimit), authorToken: token, internal: isInternal ? true : nil))
            return true
        }
    }

    @discardableResult
    func complete(_ comment: UUID, _ completed: Bool) throws -> Deliver.Comment {
        try change(comment: comment) { $0.completed = completed; return true }
    }

    /// An emoji reaction on or off for one author (a browser's token, or "owner" on the Mac).
    @discardableResult
    func react(_ comment: UUID, emoji: String, by token: String, on: Bool) throws -> Deliver.Comment {
        guard Deliver.Comment.emoji.contains(emoji) else { throw Deliver.Failure("invalid") }
        return try change(comment: comment) { found in
            var all = found.reactions ?? [:], who = all[emoji] ?? []
            who.removeAll { $0 == token }
            if on { who.append(token) }
            all[emoji] = who.isEmpty ? nil : who
            found.reactions = all.isEmpty ? nil : all
            return true
        }
    }

    @discardableResult
    func deleteComment(_ comment: UUID) throws -> Deliver.Comment { try change(comment: comment) { _ in false } }

    // MARK: - Approvals

    private func approvalsFile(_ project: UUID) -> URL { folder(project).appendingPathComponent("approvals.json") }
    func approvals(_ project: UUID) -> [Deliver.Approval] { read([Deliver.Approval].self, approvalsFile(project)) ?? [] }

    @discardableResult
    func approve(asset: UUID, version: UUID, decision: Deliver.Approval.Decision, author: String, link: UUID? = nil, email: String? = nil) throws -> Deliver.Approval {
        guard let (project, found) = find(asset), found.versions.contains(where: { $0.id == version }) else { throw Deliver.Failure("notFound") }
        let made = found.versions.first { $0.id == version }
        let approval = Deliver.Approval(asset: asset, version: version, decision: decision, author: Deliver.clean(author, limit: Self.authorLimit), link: link,
                                        email: email, versionNumber: made?.number, file: made.map { URL(fileURLWithPath: $0.path).lastPathComponent },
                                        sha256: made?.sha256, hashOf: made?.sha256 == nil ? nil : "original")
        write(approvals(project) + [approval], approvalsFile(project))
        lastApproval[asset] = approval.id
        if let data = try? Deliver.encoder.encode(approval), let json = try? JSONSerialization.jsonObject(with: data) { note(.entries([["approval": json]])) }
        setStatus(decision == .approve ? .approved : .needsChanges, of: asset, by: approval.author)
        commentsChanged += 1
        return approval
    }

    /// Fills in an approval's hash once it's known (the proof waits for it).
    func update(approval id: UUID, in project: UUID, _ change: (inout Deliver.Approval) -> Void) {
        var list = approvals(project)
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[index])
        write(list, approvalsFile(project))
    }

    /// An approval written on a host: kept once (by id), and the asset's status follows it.
    @discardableResult
    func record(_ approval: Deliver.Approval) -> Bool {
        guard let (project, found) = find(approval.asset), found.versions.contains(where: { $0.id == approval.version }) else { return false }
        let known = approvals(project)
        guard !known.contains(where: { $0.id == approval.id }) else { return false }
        write(known + [approval], approvalsFile(project))
        setStatus(approval.decision == .approve ? .approved : .needsChanges, of: approval.asset, by: approval.author)
        commentsChanged += 1
        return true
    }

    // MARK: - Share links (the key in the keychain only: without it the link can't be shown again)

    @discardableResult
    func newLink(scope: Deliver.Scope, title: String, mode: Deliver.ShareLink.Mode = .review, allowDownload: Bool = false,
                 latestOnly: Bool = false, expires: Date? = nil, password: String? = nil, level: Int? = nil) throws -> Deliver.ShareLink {
        guard links.filter(\.isLive).count < Self.liveLinkLimit else { throw Deliver.Failure("limit") }
        let item = Self.item(level: level ?? ReviewPublish.shared.linkLevel), key = Self.linkKey(item)!
        let title = Deliver.clean(title, limit: Self.nameLimit)
        var link = Deliver.ShareLink(title: title.isEmpty ? String(localized: "Review") : title, scope: scope, roomID: DeliverKeys.roomID(key),
                                     mode: mode, allowDownload: allowDownload, latestOnly: latestOnly, expires: expires)
        if let password, !password.isEmpty { link.passwordHash = DeliverKeys.hashPassword(password) }
        link.madeOn = Host.current().localizedName
        DeliverKeychain.save(item, as: link.id.uuidString)
        links.append(link)
        stampLink(links.count - 1)
        saveLinks()
        return links[links.count - 1]
    }

    /// The link's settings again, as a new link (its own key; the same password hash).
    @discardableResult
    func duplicate(_ id: UUID, recipient: String? = nil) throws -> Deliver.ShareLink {
        guard let template = link(id) else { throw Deliver.Failure("notFound") }
        guard links.filter(\.isLive).count < Self.liveLinkLimit else { throw Deliver.Failure("limit") }
        let item = Self.item(level: ReviewPublish.shared.linkLevel), key = Self.linkKey(item)!
        var made = template
        made.id = UUID()
        made.roomID = DeliverKeys.roomID(key)
        made.created = .now
        made.revoked = nil
        made.lastOpened = nil
        made.paused = nil
        made.reminded = nil
        made.rev = nil
        made.madeOn = Host.current().localizedName
        if let recipient {
            let name = Deliver.clean(recipient, limit: Self.authorLimit)
            made.recipient = name.isEmpty ? nil : name
            made.title = Deliver.clean("\(template.title) · \(name)", limit: Self.nameLimit)
        }
        DeliverKeychain.save(item, as: made.id.uuidString)
        links.append(made)
        stampLink(links.count - 1)
        saveLinks()
        return links[links.count - 1]
    }

    /// Personal links: one per name, each with its own key (identity = the link).
    func invite(_ names: [String], like template: UUID) -> [Deliver.ShareLink] {
        names.map { Deliver.clean($0, limit: Self.authorLimit) }.filter { !$0.isEmpty }.compactMap { try? duplicate(template, recipient: $0) }
    }

    func link(_ id: UUID) -> Deliver.ShareLink? { links.first { $0.id == id } }
    /// Made on another Mac (its key is in that Mac's Keychain): only that Mac can change it on a host.
    func isForeign(_ link: Deliver.ShareLink) -> Bool { key(link.id) == nil && link.madeOn.map { $0 != Host.current().localizedName } == true }
    /// The keychain item: code ‖ R (level 3, §13.24, 12 + 32 bytes) for new links, key ‖ R (level 2, 64) for older ones.
    private static func item(level: Int) -> Data {
        level == 2 ? DeliverKeys.random(64) : Data(DeliverKeys.newCode().utf8) + DeliverKeys.random(32)
    }
    private static let level3Count = DeliverKeys.codeLength + 32
    /// The 32-byte link key of an item: level 2's key, or level 3's HKDF of the code. A level-1 item (key only) has none.
    private static func linkKey(_ item: Data) -> Data? {
        switch item.count {
        case 64: Data(item.prefix(32))
        case level3Count: DeliverKeys.linkKey(code: String(decoding: item.prefix(DeliverKeys.codeLength), as: UTF8.self))
        default: nil
        }
    }

    /// The link key (what's in, or comes from, the link).
    func key(_ link: UUID) -> Data? { DeliverKeychain.load(link.uuidString).flatMap(Self.linkKey) }
    /// R: the owner-only root of the registration secret and the room signing key (never in the link).
    func secret(_ link: UUID) -> Data? { DeliverKeychain.load(link.uuidString).flatMap { [64, Self.level3Count].contains($0.count) ? Data($0.suffix(32)) : nil } }
    /// A level-3 link's code (the part after `#`); nil for level 2.
    func code(_ link: UUID) -> String? {
        DeliverKeychain.load(link.uuidString).flatMap { $0.count == Self.level3Count ? String(decoding: $0.prefix(DeliverKeys.codeLength), as: UTF8.self) : nil }
    }
    /// 3 or 2 while the key is kept.
    func level(_ link: UUID) -> Int? { code(link) != nil ? 3 : key(link) != nil ? 2 : nil }

    /// `https://pluck.tools/r/#<code>` (level 3) or `https://pluck.tools/r/<roomId>#<key>.<pub>` (level 2), while the key is kept.
    func url(_ link: Deliver.ShareLink) -> String? {
        if let code = code(link.id) { return "https://pluck.tools/r/#\(code)" }
        guard let key = key(link.id), let secret = secret(link.id) else { return nil }
        return "https://pluck.tools/r/\(link.roomID)#\(DeliverKeys.base64url(key)).\(DeliverKeys.publicKey(root: secret))"
    }

    /// "Make a New Link" (§13.24): a new code (level 3, or level 2 while a paired host can't serve 3), R and room. The old
    /// link stops working (its sessions end). DeliverLink.renew erases the old room on pluck.tools with the old reg.
    func renew(_ id: UUID, level: Int? = nil) {
        guard let index = links.firstIndex(where: { $0.id == id }), links[index].revoked == nil, key(id) != nil else { return }
        let old = links[index], item = Self.item(level: level ?? ReviewPublish.shared.linkLevel)
        DeliverKeychain.save(item, as: id.uuidString)
        links[index].roomID = DeliverKeys.roomID(Self.linkKey(item)!)
        stampLink(index)
        saveLinks()
        tell(.linkOff(old))
    }

    /// Level-1 links (a 32-byte keychain item, no R) can't be served any more: they get a new key, R and room. Level 2,
    /// not 3: this runs while the store loads, before the paired hosts are known, and level 2 works with every released
    /// host. (Level-1 items are pre-release data only: every release since 4.0.0 made level-2 links.)
    private func upgradeLegacyKeys() {
        var changed = false
        for index in links.indices where links[index].revoked == nil {
            guard DeliverKeychain.load(links[index].id.uuidString)?.count == 32 else { continue }
            let item = DeliverKeys.random(64)
            links[index].roomID = DeliverKeys.roomID(Data(item.prefix(32)))
            DeliverKeychain.save(item, as: links[index].id.uuidString)
            stampLink(index)
            changed = true
        }
        if changed { write(links, linksFile) }
    }

    func updateLink(_ id: UUID, _ change: (inout Deliver.ShareLink) -> Void) {
        guard let index = links.firstIndex(where: { $0.id == id }) else { return }
        let before = links[index]
        change(&links[index])
        // (`opened` stamps and this Mac's reminders don't sync.)
        var a = before, b = links[index]
        a.lastOpened = nil; b.lastOpened = nil; a.reminded = nil; b.reminded = nil
        if a != b { stampLink(index) }
        saveLinks()
    }

    func setPassword(_ password: String?, link id: UUID) {
        updateLink(id) { $0.passwordHash = password.flatMap { $0.isEmpty ? nil : DeliverKeys.hashPassword($0) } }
    }

    /// Turns the link off at once: its key goes and connected browsers are told and closed.
    func revoke(_ id: UUID) {
        guard let index = links.firstIndex(where: { $0.id == id }), links[index].revoked == nil else { return }
        links[index].revoked = .now
        stampLink(index)
        DeliverKeychain.delete(id.uuidString)
        let link = links[index]
        saveLinks()
        tell(.linkOff(link))
    }

    /// "Delete Link and Its Data" (R11): turned off, removed here and on every host (a tombstone), its activity log
    /// deleted. Comments stay with their assets. The caller erases the room on pluck.tools first (that needs the key).
    func deleteLink(_ id: UUID) {
        guard let link = link(id) else { return }
        revoke(id)
        note(.tombstones([tombstone("link", id, project: link.project, rev: link.rev)]))
        links.removeAll { $0.id == id }
        saveLinks()
        try? FileManager.default.removeItem(at: activityFile(id))
        activityChanged += 1
    }

    func opened(_ link: UUID) { updateLink(link) { $0.lastOpened = .now } }

    /// The name of what a link shares.
    func name(_ scope: Deliver.Scope) -> String {
        switch scope {
        case .project(let id): project(id)?.name ?? ""
        case .folder(let id, let project): content(project).folders.first { $0.id == id }?.name ?? ""
        case .asset(let id, _): find(id)?.asset.name ?? ""
        case .assets(let ids, _): ids.count == 1 ? find(ids[0])?.asset.name ?? "" : String(localized: "\(ids.count) assets")
        }
    }

    // MARK: - Inbox

    var unread: Int { inbox.filter { !$0.read }.count }

    func addInbox(_ item: Deliver.InboxItem) {
        inbox.insert(item, at: 0)
        if inbox.count > 1000 { inbox.removeLast(inbox.count - 1000) }
        saveInbox()
    }

    func markRead(_ id: UUID) {
        guard let index = inbox.firstIndex(where: { $0.id == id }), !inbox[index].read else { return }
        inbox[index].read = true
        saveInbox()
    }

    /// Views showing comments, approvals or branding reload.
    func commentsChangedTick() { commentsChanged += 1 }

    // MARK: - From the data host (§13.1): each copy kept only when it wins under rule M

    private func wins(_ local: (some DeliverRevised)?, _ incoming: some DeliverRevised) -> Bool {
        DeliverMerge.incomingWins(stored: local.map { DeliverMerge.Stamp($0) }, incoming: DeliverMerge.Stamp(incoming))
    }

    @discardableResult
    func applyMeta(_ incoming: Deliver.Project) -> Bool {
        applying = true
        defer { applying = false }
        if let index = projects.firstIndex(where: { $0.id == incoming.id }) {
            guard wins(projects[index], incoming), projects[index] != incoming else { return false }
            projects[index] = incoming
        } else {
            guard projects.count < Self.projectLimit else { return false }
            projects.append(incoming)
            contents[incoming.id] = contents[incoming.id] ?? .init()
            write(contents[incoming.id]!, folder(incoming.id).appendingPathComponent("project.json"))
        }
        projects.sort { ($0.order ?? Int.max, $0.created) < ($1.order ?? Int.max, $1.created) }
        saveProjects()
        return true
    }

    @discardableResult
    func applyFolder(_ incoming: Deliver.Folder, project: UUID) -> Bool {
        guard contents[project] != nil else { return false }
        applying = true
        defer { applying = false }
        var changed = false
        edit(project) { content in
            if let index = content.folders.firstIndex(where: { $0.id == incoming.id }) {
                guard wins(content.folders[index], incoming), content.folders[index] != incoming else { return }
                content.folders[index] = incoming
            } else {
                content.folders.append(incoming)
            }
            changed = true
        }
        return changed
    }

    /// An asset from the host; this Mac's own paths, bookmarks and made copies stay as they are.
    @discardableResult
    func applyAsset(_ incoming: Deliver.Asset, project: UUID) -> Bool {
        guard contents[project] != nil else { return false }
        applying = true
        defer { applying = false }
        var merged = incoming
        let local = find(incoming.id)
        if let local {
            guard wins(local.asset, incoming) else { return false }
            for index in merged.versions.indices {
                guard let mine = local.asset.versions.first(where: { $0.id == merged.versions[index].id }) else { continue }
                merged.versions[index].path = mine.path
                merged.versions[index].bookmark = mine.bookmark
                if case .ready = mine.copy { merged.versions[index].copy = mine.copy }
                merged.versions[index].probe = merged.versions[index].probe ?? mine.probe
            }
            guard merged != local.asset else { return false }
            // (Moved to another project there: out of the old one here.)
            if local.project != project { edit(local.project) { $0.assets.removeAll { $0.id == incoming.id } } }
        }
        edit(project) { content in
            if let index = content.assets.firstIndex(where: { $0.id == incoming.id }) { content.assets[index] = merged } else { content.assets.append(merged) }
        }
        tell(.assetChanged(incoming.id))
        return true
    }

    @discardableResult
    func applyLink(_ incoming: Deliver.ShareLink) -> Bool {
        applying = true
        defer { applying = false }
        var merged = incoming
        if let index = links.firstIndex(where: { $0.id == incoming.id }) {
            guard wins(links[index], incoming) else { return false }
            merged.lastOpened = links[index].lastOpened
            merged.reminded = links[index].reminded
            merged.muted = links[index].muted
            merged.notifyOpened = links[index].notifyOpened
            guard merged != links[index] else { return false }
            links[index] = merged
        } else {
            links.append(merged)
        }
        saveLinks()
        if !merged.isLive { tell(.linkOff(merged)) }
        return true
    }

    /// A removal from the host wins (§13.1): the name of an asset this Mac had changed since, for the inbox.
    @discardableResult
    func applyTombstone(_ tombstone: Deliver.Tombstone) -> String? {
        applying = true
        defer { applying = false }
        switch tombstone.kind {
        case "project":
            guard project(tombstone.id) != nil else { return nil }
            deleteProject(tombstone.id)
        case "folder":
            guard let project = tombstone.project ?? contents.first(where: { $0.value.folders.contains { $0.id == tombstone.id } })?.key else { return nil }
            edit(project) { content in
                content.folders.removeAll { $0.id == tombstone.id }
                for index in content.assets.indices where content.assets[index].folder == tombstone.id { content.assets[index].folder = nil }
            }
        case "asset":
            guard let (_, found) = find(tombstone.id) else { return nil }
            let changedHere = (found.rev ?? 0) > tombstone.rev
            remove(asset: tombstone.id)
            return changedHere ? found.name : nil
        case "link":
            guard links.contains(where: { $0.id == tombstone.id }) else { return nil }
            revoke(tombstone.id)
            links.removeAll { $0.id == tombstone.id }
            saveLinks()
        default: break
        }
        return nil
    }

    /// Before the first move to a data host: every object without a rev gets rev 1 (§13.1 step 2), quietly.
    func stampUnrevised(by device: String) {
        applying = true
        defer { applying = false }
        func first<T: DeliverRevised>(_ object: inout T, _ at: Date) {
            guard object.rev == nil else { return }
            object.rev = 1
            object.at = Date(timeIntervalSince1970: at.timeIntervalSince1970.rounded())
            object.by = device
        }
        for index in projects.indices { first(&projects[index], projects[index].created) }
        for index in links.indices { first(&links[index], links[index].created) }
        for project in projects {
            edit(project.id) { content in
                for index in content.folders.indices { first(&content.folders[index], project.created) }
                for index in content.assets.indices { first(&content.assets[index], content.assets[index].created) }
            }
            for asset in content(project.id).assets {
                var list = comments(asset.id)
                guard list.contains(where: { $0.rev == nil }) else { continue }
                for index in list.indices { first(&list[index], list[index].edited ?? list[index].created) }
                saveComments(list, asset.id)
            }
        }
        saveProjects()
        saveLinks()
    }

    // MARK: - Space

    nonisolated static func size(of folder: URL) -> Int64 {
        let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let url = items?.nextObject() as? URL { total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    /// Every review copy goes (they're made again when asked for).
    func deleteCopies() {
        try? FileManager.default.removeItem(at: copiesFolder)
        for content in contents.values {
            for asset in content.assets {
                for version in asset.versions where version.copy != .pending {
                    update(version: version.id, of: asset.id) { $0.copy = .pending }
                }
            }
        }
    }
}

/// Link keys as generic passwords: service tools.pluck.review, account the link's id; NAS host keys under
/// tools.pluck.review.host, account the host's address. Test copies keep them in memory, so a test never
/// touches the login keychain (as OfficeLink.Keychain).
enum DeliverKeychain {
    static let linkService = "tools.pluck.review", hostService = "tools.pluck.review.host"
    nonisolated(unsafe) private static var memory: [String: Data] = [:]
    private static var inMemory: Bool { ScreenshotMode.scene != nil }

    static func save(_ data: Data, as account: String, service: String = linkService) {
        if inMemory { memory[service + "/" + account] = data; return }
        PluckVault.shared.save(data, as: account, service: service)
    }

    static func load(_ account: String, service: String = linkService) -> Data? {
        if inMemory { return memory[service + "/" + account] }
        return PluckVault.shared.load(account, service: service)
    }

    static func delete(_ account: String, service: String = linkService) {
        if inMemory { memory[service + "/" + account] = nil; return }
        PluckVault.shared.delete(account, service: service)
    }
}
