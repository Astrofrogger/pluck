import CryptoKit
import Foundation

/// Uploads to a NAS host's write-enabled uploads root (§13.2): the file is hashed first, sent in 16 MiB parts,
/// resumed from the host's `have` after a reconnect, and then added as a version by reference (the NAS makes its copies).
@MainActor
@Observable
final class DeliverUploads {
    static let shared = DeliverUploads()
    nonisolated static let partSize = 16 << 20

    /// Per file being sent: how far (0…1).
    private(set) var progress: [String: Double] = [:]
    var problem: String?

    /// A file's SHA-256 (lowercase hex), read in 16 MiB pieces off the main thread.
    nonisolated static func sha256(_ url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            var hash = SHA256()
            while let piece = try? handle.read(upToCount: partSize), !piece.isEmpty { hash.update(data: piece) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    /// The uploads root's id, when the host has one ("renders").
    static func writableRoot(_ host: Deliver.Host) async -> String? {
        (try? await ReviewHostClient.ask(host, ["op": "roots"]))?["writable"].flatMap { ($0 as? [String])?.first }
    }

    /// Sends `url` to `path` (inside the uploads root) and returns the path the host gave it (" 2" when taken).
    func upload(_ url: URL, to path: String, host: Deliver.Host, attempts: Int = 5) async throws -> String {
        let end = try await send(url, to: path, host: host, attempts: attempts)
        return end["path"] as? String ?? path
    }

    /// The same, with more fields for `upload-begin` (a backup's `folder`, §13.25); the host's `upload-end` answer.
    func send(_ url: URL, to path: String, host: Deliver.Host, extra: [String: Any] = [:], attempts: Int = 5) async throws -> [String: Any] {
        guard let sha = await Self.sha256(url), let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) else {
            throw Deliver.Failure("notFound")
        }
        progress[path] = 0
        defer { progress[path] = nil }
        var lastError: Error = Deliver.Failure("internal")
        for _ in 0..<attempts {
            do {
                var final: [String: Any] = [:]
                try await ReviewHostClient.session(host) { session in
                    let begin = try await session.ask(["op": "upload-begin", "path": path, "size": size, "sha256": sha].merging(extra) { a, _ in a })
                    guard let id = begin["upload"] as? String else { throw Deliver.Failure("internal") }
                    var have = (begin["have"] as? NSNumber)?.int64Value ?? 0
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    while have < size {
                        try handle.seek(toOffset: UInt64(have))
                        let piece = try handle.read(upToCount: Int(min(Int64(Self.partSize), size - have))) ?? Data()
                        guard !piece.isEmpty else { throw Deliver.Failure("internal") }
                        do {
                            let answer = try await session.ask(["op": "upload-part", "upload": id, "offset": have, "size": piece.count], payload: piece)
                            have = (answer["have"] as? NSNumber)?.int64Value ?? have + Int64(piece.count)
                        } catch let failure as Deliver.Failure where failure.code == "offset" {
                            // The host has a different amount: carry on from there.
                            guard let there = (session.lastError?["have"] as? NSNumber)?.int64Value else { throw failure }
                            have = there
                        }
                        self.progress[path] = Double(have) / Double(max(size, 1))
                    }
                    final = try await session.ask(["op": "upload-end", "upload": id])
                }
                return final
            } catch let failure as Deliver.Failure where ["checksum", "space", "exists", "limit", "scope"].contains(failure.code) {
                throw failure
            } catch {
                lastError = error
                try? await Task.sleep(for: .seconds(2))
            }
        }
        throw lastError
    }

    /// Versions whose original is on its way to a NAS now.
    private(set) var active: Set<UUID> = []
    /// Uploads that didn't go and can't wait (refused, full, the file gone): shown, and sent again by Try Again.
    struct Failure: Identifiable, Equatable {
        var id: UUID { version }
        var version: UUID
        var asset: UUID
        var host: UUID
        var folder: String
        var name: String
        var why: String
    }
    private(set) var failures: [Failure] = []

    /// "Upload to <NAS>…" for a version: sent, then the version points at the NAS path (the NAS makes its copies). The NAS
    /// away: it waits in DeliverShareQueue; anything else is a failure, with the alert.
    func uploadVersion(_ version: Deliver.Version, of asset: UUID, folder: String, host: Deliver.Host, store: DeliverStore = .shared) async {
        failures.removeAll { $0.version == version.id }
        let name = store.find(asset).map { $0.asset.versions.count > 1 ? "\($0.asset.name) v\(version.number)" : $0.asset.name } ?? URL(fileURLWithPath: version.path).lastPathComponent
        let project = store.find(asset)?.project
        guard let file = store.original(version) else {
            return fail(.init(version: version.id, asset: asset, host: host.id, folder: folder, name: name, why: String(localized: "The original can’t be found")), project: project, host: host)
        }
        active.insert(version.id)
        defer { active.remove(version.id) }
        do {
            _ = try? await ReviewHostClient.ask(host, ["op": "mkdir", "path": folder])
            let path = try await upload(file, to: folder + "/" + file.lastPathComponent, host: host)
            // (The bookmark goes too: the version is the NAS's file now, not this Mac's.)
            store.update(version: version.id, of: asset) { $0.path = ReviewPublish.nasPath(host: host.id, path: path); $0.bookmark = nil }
            problem = nil
        } catch where DeliverShareQueue.waitable(error) && project != nil {
            problem = String(localized: "The upload to \(host.name) didn’t finish.")
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            DeliverShareQueue.shared.add(.init(file: file.path, size: size, project: project!, asset: asset, upload: .init(host: host.id, folder: folder), version: version.id))
            DeliverNASAlert.shared.report(.init(title: String(localized: "Pluck can’t reach \(host.name)"),
                                                detail: String(localized: "\(name) is waiting and goes up as soon as it’s back."), asset: asset, project: project))
        } catch {
            problem = (error as? Deliver.Failure)?.code == "space" ? String(localized: "There isn’t enough space on the NAS.")
                : String(localized: "The upload to \(host.name) didn’t finish.")
            fail(.init(version: version.id, asset: asset, host: host.id, folder: folder, name: name, why: problem ?? ""), project: project, host: host)
        }
    }

    private func fail(_ failure: Failure, project: UUID?, host: Deliver.Host) {
        failures.append(failure)
        DeliverNASAlert.shared.report(.init(title: String(localized: "\(failure.name) didn’t go to \(host.name)"), detail: failure.why, asset: failure.asset, project: project))
    }

    /// Try Again: every failed upload once more, into the folder it was going to.
    func retry(store: DeliverStore = .shared, publish: ReviewPublish = .shared) {
        for failure in failures {
            guard let host = publish.host(failure.host), let version = store.find(failure.asset)?.asset.versions.first(where: { $0.id == failure.version }) else {
                failures.removeAll { $0.version == failure.version }
                continue
            }
            Task { await uploadVersion(version, of: failure.asset, folder: failure.folder, host: host, store: store) }
        }
    }
}
