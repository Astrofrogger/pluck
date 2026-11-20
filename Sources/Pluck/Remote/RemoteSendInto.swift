import CryptoKit
import Darwin
import Foundation

/// "Send Files Here…" (plan 2026-11-20 §4): files from a home Mac straight into a folder of a share (on the NAS), for a
/// Mac that is an Editor in that folder. Instead of a writable drive: a hidden partial file added to at its end (resumed
/// from `have`), checked with SHA-256, then given a name of its own with O_EXCL ("Name 2.mov" when taken). Nothing is
/// ever overwritten or deleted. The inbox stays the default for "Send to Office".
@MainActor
enum RemoteSendInto {
    static func register() {
        // {share, path (folder), name, size, modified} → {have}
        OfficeActions.register("sendIntoState") { arguments, device in
            let (folder, name, size, modified) = try target(arguments, device)
            return ["have": Self.bytes(partial(folder, name: name, size: size, modified: modified)) ?? 0]
        }
        // … plus {offset, data, sha256 (with the last piece)} → {have, name (when placed)}
        OfficeActions.register("sendInto") { arguments, device in
            let (folder, name, size, modified) = try target(arguments, device)
            guard let data = (arguments["data"] as? String).flatMap({ Data(base64Encoded: $0) }), data.count <= OfficeLink.uploadChunk else {
                throw OfficeActions.incomplete()
            }
            let offset = try OfficeActions.number(arguments["offset"])
            let sha = arguments["sha256"] as? String
            return try await Task.detached {
                try receive(into: folder, name: name, size: size, modified: modified, offset: offset, data: data, sha256: sha)
            }.value
        }
    }

    /// The folder (an Editor's, resolved inside the share) and the checked file name.
    private static func target(_ arguments: [String: Any], _ device: OfficeRenderServer.Device) throws -> (URL, String, Int64, Double) {
        let place = try RemoteEditHost.share(arguments["share"])
        let folder = try OfficeActions.require(\.render, device, share: place, path: try OfficeActions.text(arguments["path"], empty: true),
                                               refusal: OfficeActions.sendRefusal)
        guard RemoteEditHost.isDirectory(folder) else { throw OfficeActions.incomplete() }
        let name = try OfficeActions.text(arguments["name"], 120)
        guard nameOK(name) else { throw OfficeInbox.Problem.badPath }
        let size = try OfficeActions.number(arguments["size"])
        guard size <= largest else { throw OfficeInbox.Problem.tooBig }
        return (folder, name, size, seconds(arguments["modified"]))
    }

    /// A modification time from the network: finite and in a sane range (0: none).
    nonisolated static func seconds(_ value: Any?) -> Double {
        guard let time = value as? Double, time.isFinite else { return 0 }
        return min(max(time, -1e12), 1e12).rounded()
    }

    nonisolated static let largest: Int64 = 500_000_000_000
    nonisolated(unsafe) static var freeFloor: Int64 = 20_000_000_000

    /// The NAS helper's file name rule (upload_root.rs `name_ok`): one plain name, no leading dot, no `/ \ :`, no
    /// control characters, at most 120 characters, no spaces around it.
    nonisolated static func nameOK(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 120 && !name.hasPrefix(".") && name.trimmingCharacters(in: .whitespaces) == name
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || "/\\:".unicodeScalars.contains($0) }
    }

    nonisolated static func partial(_ folder: URL, name: String, size: Int64, modified: Double) -> URL {
        folder.appendingPathComponent(".\(name).\(size)-\(Int64(seconds(modified))).pluckpart")
    }

    nonisolated private static func bytes(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// One piece at the end of the partial file; the last one checks the SHA-256 and places the file under a free name.
    /// `publish`: puts the checked partial in place itself (the drive's writes, RemoteDriveWriteHost), instead of `place`.
    nonisolated static func receive(into folder: URL, name: String, size: Int64, modified: Double, offset: Int64, data: Data,
                                    sha256: String?, publish: ((URL) throws -> [String: Any])? = nil) throws -> [String: Any] {
        // (Subtracted, not added: an offset near the largest number can't overflow.)
        guard offset >= 0, size >= 0, offset <= size - Int64(data.count) else { throw OfficeInbox.Problem.tooBig }
        let part = partial(folder, name: name, size: size, modified: modified)
        let fm = FileManager.default
        // (A link put where the partial goes would write outside the folder: refused.)
        if (try? fm.destinationOfSymbolicLink(atPath: part.path)) != nil { throw OfficeInbox.Problem.badPath }
        let here = bytes(part) ?? 0
        // Room for the rest, with 20 GB left free on the volume (unknown: refused).
        guard let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
                ?? (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map(Int64.init),
              free - (size - here) >= freeFloor else { throw OfficeInbox.Problem.noSpace }
        guard here == offset else {
            if here > offset { try? fm.removeItem(at: part) }
            throw OfficeInbox.Problem.mismatch
        }
        if here == 0 {
            let made = open(part.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
            guard made >= 0 || errno == EEXIST else { throw OfficeInbox.Problem.badPath }
            if made >= 0 { close(made) }
        }
        let handle = try FileHandle(forWritingTo: part)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
        let now = offset + Int64(data.count)
        guard now == size else { return ["have": now] }
        // The whole file: its SHA-256 as the sender read it (else it starts again).
        guard let sha256, sha256.lowercased() == (try? hash(part)) else {
            try? fm.removeItem(at: part)
            throw OfficeInbox.Problem.mismatch
        }
        if let publish { return try publish(part).merging(["have": now]) { a, _ in a } }
        let placed = try place(part, in: folder, name: name)
        try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: folder.appendingPathComponent(placed).path)
        return ["have": now, "name": placed]
    }

    nonisolated static func hash(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var sha = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The file under its name, or "Name 2.ext", "Name 3.ext"… : the name is taken with O_EXCL (never a file that's
    /// there, never through a link), then the partial is renamed onto that empty file of our own. Gives the name used.
    nonisolated static func place(_ part: URL, in folder: URL, name: String) throws -> String {
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        for n in 1...1000 {
            let candidate = n == 1 ? name : "\(stem) \(n)" + (ext.isEmpty ? "" : "." + ext)
            let target = folder.appendingPathComponent(candidate)
            let made = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
            if made < 0 {
                if errno == EEXIST { continue }
                throw OfficeInbox.Problem.badPath
            }
            close(made)
            guard rename(part.path, target.path) == 0 else {
                unlink(target.path)
                throw OfficeInbox.Problem.badPath
            }
            return candidate
        }
        throw OfficeInbox.Problem.badPath
    }

    // MARK: - The home Mac's side

    /// Sends these files into a folder of a share, one after the other, each resumed where the host has got to.
    /// `progress`: the file and how far. Gives the names they got there.
    /// `hashes`: SHA-256s already read (by file), not read again.
    static func send(_ files: [URL], share: String, path: String, client: OfficeRenderClient = .shared, hashes: [URL: String] = [:],
                     progress: @escaping (String, Double) -> Void = { _, _ in }) async throws -> [String] {
        var names: [String] = []
        for url in files {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values.fileSize ?? 0)
            let modified = (values.contentModificationDate ?? .now).timeIntervalSince1970.rounded()
            let file: [String: Any] = ["share": share, "path": path, "name": url.lastPathComponent, "size": size, "modified": modified]
            let sha: String
            if let known = hashes[url] { sha = known } else { sha = try await Task.detached { try hash(url) }.value }
            var have = (try await client.ask("sendIntoState", file)["have"] as? NSNumber)?.int64Value ?? 0
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var placed: String?
            repeat {
                try Task.checkCancellation()
                try handle.seek(toOffset: UInt64(have))
                let chunk = try handle.read(upToCount: OfficeLink.uploadChunk) ?? Data()
                var piece = file
                piece["offset"] = have
                piece["data"] = chunk.base64EncodedString()
                if have + Int64(chunk.count) == size { piece["sha256"] = sha }
                let answer = try await client.ask("sendInto", piece, timeout: 120)
                have = (answer["have"] as? NSNumber)?.int64Value ?? have
                placed = answer["name"] as? String
                progress(url.lastPathComponent, size > 0 ? Double(have) / Double(size) : 1)
                if chunk.isEmpty { break }
            } while placed == nil
            names.append(placed ?? url.lastPathComponent)
        }
        return names
    }
}
