import Foundation
import Observation

/// Files sent from this Mac to the host Mac: folders kept in step (new and changed files go up
/// by themselves) and one-off files. They land in this Mac's folder in the host's inbox; a file
/// that stopped half-way carries on from where it got to.
@MainActor
@Observable
final class SendSync {
    static let shared = SendSync()
    private static let foldersKey = "editAnywhereSendFolders"
    private static let filesKey = "editAnywhereSendFiles"

    /// When a file was sent, so it's only sent again when it changes.
    struct Stamp: Codable, Equatable {
        var size: Int64
        var modified: Double
    }

    struct Folder: Codable, Identifiable, Equatable {
        var path: String
        var sent: [String: Stamp] = [:]
        var id: String { path }
        var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    }

    private(set) var folders: [Folder] = []
    /// One-off files still to send.
    private(set) var files: [String] = []
    /// The file going up now, how far along, and how many wait.
    private(set) var sending: String?
    private(set) var fraction = 0.0
    private(set) var waiting = 0
    private(set) var lastSent: Date?
    private(set) var problem: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var passing = false
    /// What it's doing, step by step (the self-test).
    @ObservationIgnored var trace: ((String) -> Void)?

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.foldersKey), let saved = try? JSONDecoder().decode([Folder].self, from: data) { folders = saved }
        files = defaults.stringArray(forKey: Self.filesKey) ?? []
    }

    private func save() {
        if let data = try? JSONEncoder().encode(folders) { UserDefaults.standard.set(data, forKey: Self.foldersKey) }
        UserDefaults.standard.set(files, forKey: Self.filesKey)
    }

    private var client: OfficeRenderClient { OfficeRenderClient.shared }

    func add(folder: URL) {
        guard !folders.contains(where: { $0.path == folder.path }) else { return }
        folders.append(Folder(path: folder.path))
        save()
        resume()
    }

    func remove(_ folder: Folder) {
        folders.removeAll { $0.id == folder.id }
        save()
    }

    func send(_ urls: [URL]) {
        for url in urls where !files.contains(url.path) {
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
                add(folder: url)
            } else {
                files.append(url.path)
            }
        }
        save()
        resume()
    }

    /// Keeps sending while paired: the one-off files, then whatever changed in the folders, and
    /// a fresh look at the folders every minute.
    func resume() {
        guard task == nil, client.office != nil, !(folders.isEmpty && files.isEmpty),
              ScreenshotMode.scene == nil || ScreenshotMode.scene == "sendtest" else { return }
        task = Task {
            defer { task = nil; sending = nil }
            while !Task.isCancelled, client.office != nil, !(folders.isEmpty && files.isEmpty) {
                await pass()
                try? await Task.sleep(for: .seconds(problem == nil ? 60 : 120))
            }
        }
    }

    /// Sends what's waiting now. Stops at the first problem (the host is away, say) and tries
    /// again on the next pass.
    func pass() async {
        // One pass at a time (a second would send the same files again).
        guard !passing else { return }
        passing = true
        defer { passing = false }
        problem = nil
        // One-off files first, into the top of this Mac's folder.
        while let path = files.first {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { files.removeAll { $0 == path }; save(); continue }
            waiting = files.count - 1
            do {
                try await upload(url, as: url.lastPathComponent)
                files.removeAll { $0 == path }
                save()
            } catch {
                problem = error.localizedDescription
                return
            }
        }
        for folder in folders {
            let changed = await Task.detached { Self.changes(in: folder) }.value
            for (number, change) in changed.enumerated() {
                waiting = changed.count - number - 1
                do {
                    try await upload(folder.url.appendingPathComponent(change.relative), as: folder.url.lastPathComponent + "/" + change.relative)
                    if let index = folders.firstIndex(where: { $0.id == folder.id }) {
                        folders[index].sent[change.relative] = change.stamp
                        save()
                    }
                } catch {
                    problem = error.localizedDescription
                    return
                }
            }
        }
        waiting = 0
    }

    /// Files in a folder that are new or changed since they were sent, leaving out hidden files
    /// and ones still being written (changed in the last few seconds).
    nonisolated private static func changes(in folder: Folder) -> [(relative: String, stamp: Stamp)] {
        let root = folder.url.standardizedFileURL
        let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                                                   options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var found: [(String, Stamp)] = []
        while let url = items?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true, let size = values.fileSize, let date = values.contentModificationDate,
                  Date.now.timeIntervalSince(date) > 10 else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            let stamp = Stamp(size: Int64(size), modified: date.timeIntervalSince1970.rounded())
            if folder.sent[relative] != stamp { found.append((relative, stamp)) }
        }
        return found.sorted { $0.0 < $1.0 }
    }

    /// One file to the host, in pieces, from where the host has got to.
    private func upload(_ url: URL, as path: String) async throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = Int64(values.fileSize ?? 0)
        let modified = (values.contentModificationDate ?? .now).timeIntervalSince1970.rounded()
        let file = ["path": path, "size": size, "modified": modified] as [String: Any]
        sending = url.lastPathComponent
        fraction = 0
        defer { sending = nil }
        trace?("asking about \(path)")
        var have = (try await client.ask("sendState", file)["have"] as? NSNumber)?.int64Value ?? 0
        trace?("host has \(have) of \(size)")
        guard have < size || size == 0 else { lastSent = .now; return }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var restarted = false
        repeat {
            try handle.seek(toOffset: UInt64(have))
            let chunk = try handle.read(upToCount: OfficeLink.uploadChunk) ?? Data()
            var piece = file
            piece["offset"] = have
            piece["data"] = chunk.base64EncodedString()
            do {
                have = (try await client.ask("send", piece, timeout: 120)["have"] as? NSNumber)?.int64Value ?? have
            } catch OfficeLink.Failure.office(_) where !restarted {
                // The host had a different part (an earlier try of a changed file): start over once.
                restarted = true
                have = 0
                continue
            }
            fraction = size > 0 ? Double(have) / Double(size) : 1
            if chunk.isEmpty { break }
        } while have < size
        lastSent = .now
    }
}
