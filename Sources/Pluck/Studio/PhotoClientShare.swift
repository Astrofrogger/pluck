import Foundation

/// Photo ▸ Share with Client: the selected photos' exports as image assets in a Deliver gallery (a folder of the
/// "Photos" review project), so the link, its versions and approvals are Deliver's own on both servers (nothing new on
/// the wire: older hosts serve it as any folder of pictures). The client's decision comes back onto the photo:
/// approved = Pick, changes asked = red label, a rating (a link featuring Rating) = its stars.
@MainActor
enum PhotoClientShare {
    /// One photo in one gallery: its review asset, and the client's decision last put on the photo (so the owner's own
    /// change afterwards stays until the client decides again).
    struct Entry: Codable, Hashable {
        var asset: UUID
        var seen: String?
    }

    struct Gallery: Hashable {
        var project: UUID, folder: UUID, isNew: Bool
        /// The last photo that couldn't be shared, why (the rest went).
        var problem: String?
    }

    nonisolated static var file: URL { PhotoCatalog.folder.appendingPathComponent("Client Shares.json") }
    /// Where the shared exports live (Deliver keeps a reference to its originals, never a copy).
    nonisolated static var exports: URL { PhotoCatalog.folder.appendingPathComponent("Client Shares", isDirectory: true) }

    /// Photo key → its galleries' assets.
    static var entries: [String: [Entry]] = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: [Entry]].self, from: $0) } ?? [:]

    static func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: file, options: .atomic)
    }

    static var projectName: String { String(localized: "Photos") }

    /// For sharing: sized for screens, sRGB, no location.
    static var exportSettings: PhotoExportSettings {
        var settings = PhotoExportSettings()
        settings.longSide = 3000
        settings.sharpen = .screen
        settings.metadata = .noLocation
        return settings
    }

    /// The decision as it stands on the asset.
    static func state(_ asset: Deliver.Asset) -> String { "\(asset.status.rawValue)|\(asset.fields?.rating ?? 0)" }

    /// What changed since `seen` put on the photo's record.
    static func take(_ asset: Deliver.Asset, seen: String?, into record: inout PhotoRecord) {
        let old = seen?.split(separator: "|", omittingEmptySubsequences: false).map(String.init) ?? []
        if old.first != asset.status.rawValue {
            if asset.status == .approved {
                record.flag = .pick
                if record.label == "red" { record.label = nil }
            } else if asset.status == .needsChanges {
                record.label = "red"
            }
        }
        let rating = asset.fields?.rating ?? 0
        if old.count < 2 || old[1] != "\(rating)", rating > 0 { record.rating = min(rating, 5) }
    }

    /// The clients' new decisions onto the photos, as one step to undo; how many photos changed.
    @discardableResult
    static func pullDecisions(store: DeliverStore? = nil) -> Int {
        let store = store ?? .shared, catalog = PhotoCatalog.shared
        var found: [(key: String, asset: Deliver.Asset, seen: String?)] = []
        for (key, list) in entries {
            for (index, entry) in list.enumerated() {
                guard let asset = store.find(entry.asset)?.asset else { continue }
                let now = state(asset)
                guard now != entry.seen else { continue }
                found.append((key, asset, entry.seen))
                entries[key]?[index].seen = now
            }
        }
        guard !found.isEmpty else { return 0 }
        catalog.group {
            for item in found { catalog.update([item.key]) { take(item.asset, seen: item.seen, into: &$0) } }
        }
        save()
        return Set(found.map(\.key)).count
    }

    /// The gallery any of these photos is already in (shared again: new versions there), else a new one.
    static func gallery(for keys: [String], title: String, store: DeliverStore) throws -> Gallery {
        for key in keys {
            for entry in entries[key] ?? [] {
                if let (project, asset) = store.find(entry.asset), let folder = asset.folder {
                    return Gallery(project: project, folder: folder, isNew: false)
                }
            }
        }
        let project = try store.projects.first { $0.name == projectName } ?? store.newProject(projectName)
        guard let folder = store.newFolder(title, in: project.id, parent: nil) else { throw Deliver.Failure("limit") }
        return Gallery(project: project.id, folder: folder.id, isNew: true)
    }

    /// Exports the photos and puts them in their gallery: a photo already there gets a new version (its approval
    /// starts again on the client's page), the others are added. `exported`: an export for tests to stand in.
    static func share(_ keys: [String], title: String, store: DeliverStore? = nil,
                      progress: @escaping (Int) -> Void = { _ in },
                      exported: ((String, URL) async throws -> URL)? = nil) async throws -> Gallery {
        let store = store ?? .shared, catalog = PhotoCatalog.shared
        let gallery = try gallery(for: keys, title: title, store: store)
        let folder = exports.appendingPathComponent(gallery.folder.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let settings = exportSettings
        var failure: Error?, shared = 0
        for (done, key) in keys.enumerated() {
            progress(done)
            do {
                let record = catalog.record(key)
                let url = if let exported { try await exported(key, folder) } else {
                    try await PhotoRender.export(key, record: record, to: folder, settings: settings)
                }
                if let index = entries[key]?.firstIndex(where: { store.find($0.asset)?.asset.folder == gallery.folder }),
                   let asset = entries[key]?[index].asset {
                    try store.addVersion(url, to: asset)
                    shared += 1
                } else {
                    guard let asset = try store.add([url], to: gallery.project, folder: gallery.folder).first else { continue }
                    entries[key, default: []].append(Entry(asset: asset.id, seen: state(asset)))
                    shared += 1
                }
            } catch {
                failure = error
            }
        }
        progress(keys.count)
        save()
        if let failure, shared == 0 { throw failure }
        var result = gallery
        result.problem = failure?.localizedDescription
        return result
    }
}
