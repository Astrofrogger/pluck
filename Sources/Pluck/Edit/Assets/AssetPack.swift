import Foundation

/// A pack of public-domain (CC0) assets, described by a JSON manifest: each file's address, size,
/// SHA-256, licence and where it came from. Only CC0-1.0 files are ever taken (Pluck's assets go
/// into work for clients: nothing non-commercial, nothing that needs credit).
struct AssetPackManifest: Codable, Sendable {
    var id: String
    var title: String
    var files: [File]

    struct File: Codable, Sendable, Hashable {
        var id: String
        var title: String
        var category: AssetCategory
        var kind: String?
        var tags: [String]?
        var url: URL
        var sha256: String
        var size: Int64
        var licence: String
        /// The page the file was taken from (its licence shown there).
        var source: URL
        var author: String?
        var duration: Double?
        var bpm: Int?
        var key: String?
    }

    static let allowedLicence = "CC0-1.0"

    enum Problem: LocalizedError, Equatable {
        case unreadable, notCC0(String), badFile(String), checksum(String)
        var errorDescription: String? {
            switch self {
            case .unreadable: String(localized: "The pack’s list can’t be read.")
            case .notCC0(let title): String(localized: "\(title) isn’t CC0: the pack wasn’t taken.")
            case .badFile(let title): String(localized: "\(title) has a bad address or name.")
            case .checksum(let title): String(localized: "\(title) didn’t match its checksum.")
            }
        }
    }

    /// Read and checked: every file CC0, a SHA-256, a safe name, and an https address (a file
    /// address only in a manifest that's itself a local file).
    static func parse(_ data: Data, local: Bool) throws -> AssetPackManifest {
        guard let manifest = try? JSONDecoder().decode(AssetPackManifest.self, from: data), !manifest.files.isEmpty,
              safeName(manifest.id) else { throw Problem.unreadable }
        for file in manifest.files {
            guard file.licence == allowedLicence else { throw Problem.notCC0(file.title) }
            let scheme = file.url.scheme?.lowercased()
            guard scheme == "https" || (local && scheme == "file"), file.sha256.count == 64, file.size > 0,
                  file.sha256.allSatisfy(\.isHexDigit), safeName(file.id), safeName(file.url.lastPathComponent) else { throw Problem.badFile(file.title) }
        }
        return manifest
    }

    /// One plain name: no folders, nothing hidden.
    static func safeName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\") && !name.contains(":")
    }

    /// Where a pack's file goes, relative to the asset folder.
    static func relativePath(pack: String, _ file: File) -> String {
        "Packs/\(pack)/\(file.category.folder)/\(file.id)-\(file.url.lastPathComponent)"
    }

    /// The file's size and SHA-256 are the manifest's.
    static func verify(_ local: URL, _ file: File) -> Bool {
        RemotePullManager.size(of: local) == file.size && RemotePullManager.sha256(local)?.lowercased() == file.sha256.lowercased()
    }

    func item(_ file: File) -> AssetItem {
        AssetItem(id: "pack.\(id).\(file.id)", title: file.title, category: file.category, kind: file.kind ?? file.category.rawValue,
                  tags: file.tags ?? [], file: Self.relativePath(pack: id, file), duration: file.duration, bpm: file.bpm, key: file.key,
                  pack: id, licence: file.licence, sourcePage: file.source.absoluteString, author: file.author)
    }
}

/// Getting a pack: the manifest, then each file not already there (checked by size and SHA-256
/// before it counts), with progress.
@MainActor
@Observable
final class AssetPackDownloader {
    static let shared = AssetPackDownloader()
    /// Where the pack's manifest is: empty until there's a pack to offer.
    static let manifestKey = "assetPackManifestURL"

    var share: Double?
    var problem: String?
    private var task: Task<Void, Never>?

    var running: Bool { share != nil }

    func start() {
        guard task == nil, let address = UserDefaults.standard.string(forKey: Self.manifestKey)?.trimmingCharacters(in: .whitespaces),
              let url = URL(string: address), ["https", "file"].contains(url.scheme?.lowercased() ?? "") else { return }
        problem = nil
        share = 0
        task = Task {
            do {
                let items = try await Self.install(from: url, into: AssetStore.root) { value in Task { @MainActor in self.share = value } }
                AssetStore.shared.add(items)
            } catch is CancellationError {
            } catch {
                problem = error.localizedDescription
            }
            share = nil
            task = nil
        }
    }

    func cancel() { task?.cancel() }

    /// Everything in the manifest at `url`, into `root` (testable with a local manifest and files).
    nonisolated static func install(from url: URL, into root: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [AssetItem] {
        let data: Data
        if url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            let (body, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AssetPackManifest.Problem.unreadable }
            data = body
        }
        let manifest = try AssetPackManifest.parse(data, local: url.isFileURL)
        let total = Double(manifest.files.map(\.size).reduce(0, +))
        var done = 0.0, items: [AssetItem] = []
        for file in manifest.files {
            try Task.checkCancellation()
            let target = root.appendingPathComponent(AssetPackManifest.relativePath(pack: manifest.id, file))
            if !AssetPackManifest.verify(target, file) {
                let base = done
                let temp: URL
                if file.url.isFileURL {
                    temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.copyItem(at: file.url, to: temp)
                } else {
                    temp = try await ToolDownloads.download(file.url) { written, _ in progress(min((base + Double(written)) / max(total, 1), 1)) }
                }
                guard AssetPackManifest.verify(temp, file) else {
                    try? FileManager.default.removeItem(at: temp)
                    throw AssetPackManifest.Problem.checksum(file.title)
                }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: temp, to: target)
            }
            done += Double(file.size)
            progress(done / max(total, 1))
            items.append(manifest.item(file))
        }
        return items
    }
}
