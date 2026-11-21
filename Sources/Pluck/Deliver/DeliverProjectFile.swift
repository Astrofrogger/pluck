import Foundation

/// `.pluck-project.json` in a Deliver project's NAS folder (plan 407b's Deliver → Archive interface). Deliver writes
/// `delivered`, `approvedFinal` and `reviewArchived`; Archive writes its own keys. Always merged: read, set ours, write
/// atomically, every other key kept.
@MainActor
enum DeliverProjectFile {
    static let name = ".pluck-project.json"

    /// The project's folder on a NAS share, found from its originals as Archive finds projects (ShrinkFolders.detect).
    /// Only when they all agree on one folder on a share; else nil, and nothing is written.
    static func folder(_ project: UUID, store: DeliverStore = .shared) -> URL? {
        place(project, store: store).map { URL(fileURLWithPath: $0.folder, isDirectory: true) }
    }

    /// The project's client as Archive names it (the share's first folder), when its folder is known.
    static func client(_ project: UUID, store: DeliverStore = .shared) -> String? { place(project, store: store)?.client }

    private static func place(_ project: UUID, store: DeliverStore) -> (client: String, folder: String)? {
        let found = Set(store.content(project).assets.flatMap(\.versions).compactMap { version -> [String]? in
            guard let url = store.original(version), onShare(url),
                  let place = ShrinkFolders.detect(url.path, share: ShrinkFolders.shareRoot(of: url.deletingLastPathComponent())) else { return nil }
            return [place.client, place.folder]
        })
        return found.count == 1 ? (found.first![0], found.first![1]) : nil
    }

    /// On a network volume (or a self-test's stand-in for one), never this Mac's own disk.
    static func onShare(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if OfficeGroup.testVolumes.contains(where: { path.hasPrefix($0.prefix + "/") }) { return true }
        return (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == false
    }

    /// Sets `values` (nil removes the key) in the folder's file, keeping every other key. False when it couldn't be written.
    @discardableResult
    nonisolated static func merge(_ values: [String: Any?], into folder: URL) -> Bool {
        let file = folder.appendingPathComponent(name)
        var json = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        for (key, value) in values { json[key] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return false }
        return (try? data.write(to: file, options: .atomic)) != nil
    }

    nonisolated static func read(_ folder: URL) -> [String: Any] {
        (try? Data(contentsOf: folder.appendingPathComponent(name))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    /// One of Deliver's dates for a project, when its folder is known (a key already there is left: the first date counts).
    static func mark(_ key: String, _ date: Date?, project: UUID, store: DeliverStore = .shared, replace: Bool = false) {
        guard let folder = folder(project, store: store) else { return }
        if !replace, date != nil, read(folder)[key] != nil { return }
        merge([key: date.map { DeliverProof.iso($0) }], into: folder)
    }

    /// Every asset of the project approved: `approvedFinal` (once).
    static func approvedIfAll(_ project: UUID, store: DeliverStore = .shared) {
        let assets = store.content(project).assets
        guard !assets.isEmpty, assets.allSatisfy({ $0.status == .approved }) else { return }
        mark("approvedFinal", .now, project: project, store: store)
    }
}
