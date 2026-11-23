import Foundation

/// Clients' uploads on an always-on Mac that hosts review links (no NAS): its helper keeps them in the hosted data
/// folder as "uploads/<link>/<file>". The editor's Mac fetches each through Edit Anywhere in pieces, checks it by SHA-256,
/// puts it under a free name (never over a file), and then has it deleted there: what `get` / `delete` do on a NAS.
@MainActor
enum ReviewHostUploads {
    static let action = "reviewUpload"
    /// The file isn't on the office Mac (any more): nothing to fetch.
    struct Gone: Error {}

    /// (A test answers for the office Mac.)
    static var ask: @MainActor (String, [String: Any]) async throws -> [String: Any] = { try await OfficeRenderClient.shared.ask($0, $1, timeout: 120) }

    // MARK: The always-on Mac's side

    static func register() {
        OfficeActions.register(action) { arguments, device in
            try await answer(arguments, in: ReviewHosting.shared.folder(arguments, device))
        }
    }

    /// {path ("uploads/…"), step: info → {size, sha256} or {gone} | data {offset, length} → bytes, size | delete}.
    static func answer(_ arguments: [String: Any], in folder: URL) async throws -> [String: Any] {
        guard let file = file(arguments["path"], in: folder) else {
            if arguments["step"] as? String == "info" { return ["gone": true] }
            throw OfficeLink.Failure.office(String(localized: "That file isn’t in the shared folder."))
        }
        switch arguments["step"] as? String {
        case "info":
            return try await Task.detached { () -> [String: Any] in
                guard let size = RemotePullManager.size(of: file), let sum = RemotePullManager.sha256(file) else { return ["gone": true] }
                return ["size": size, "sha256": sum]
            }.value
        case "data":
            let offset = try OfficeActions.number(arguments["offset"] ?? 0)
            let length = Int(min(try OfficeActions.number(arguments["length"] ?? OfficeLink.fileChunk), Int64(OfficeLink.fileChunk)))
            return try await Task.detached { () -> [String: Any] in
                guard let handle = FileHandle(forReadingAtPath: file.path), let size = RemotePullManager.size(of: file) else { throw Gone() }
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(min(offset, size)))
                return [OfficeActions.bytesKey: try handle.read(upToCount: length) ?? Data(), "size": size]
            }.value
        case "delete":
            try? FileManager.default.removeItem(at: file)
            return ["ok": true]
        default:
            throw OfficeActions.incomplete()
        }
    }

    /// An upload in the data folder's "uploads/" (not its partial ones): `..`, absolute paths and links out refused.
    nonisolated static func file(_ value: Any?, in folder: URL) -> URL? {
        guard let path = value as? String, path.hasPrefix("uploads/"), path.count < 1024, !path.contains("\0"),
              !path.split(separator: "/").contains(".."), let base = RemoteEditHost.realPath(folder.path),
              let full = RemoteEditHost.realPath(base + "/" + path), full.hasPrefix(base + "/uploads/"),
              !full.hasPrefix(base + "/uploads/.partial/") else { return nil }
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: full, isDirectory: &directory) && !directory.boolValue ? URL(fileURLWithPath: full) : nil
    }

    // MARK: The editor's Mac

    /// One upload to `target` (a free name): in pieces, checked, then moved in place. Throws Gone when it isn't there.
    static func fetch(bundle: String, path: String, to target: URL, expected: Int64) async throws {
        let info = try await ask(action, ["bundle": bundle, "path": path, "step": "info"])
        if info["gone"] as? Bool == true { throw Gone() }
        guard let size = (info["size"] as? NSNumber)?.int64Value, let sum = (info["sha256"] as? String)?.lowercased(),
              expected <= 0 || size == expected else { throw OfficeLink.Failure.garbled }
        guard HostSession.fits(size, limit: expected > 0 ? expected : nil, in: target.deletingLastPathComponent()) else { throw Deliver.Failure("tooLarge") }
        let fm = FileManager.default
        let part = target.appendingPathExtension("part")
        guard fm.createFile(atPath: part.path, contents: nil), let handle = FileHandle(forWritingAtPath: part.path) else { throw Deliver.Failure("internal") }
        defer { try? handle.close(); try? fm.removeItem(at: part) }
        var offset: Int64 = 0
        while offset < size {
            let piece = try await ask(action, ["bundle": bundle, "path": path, "step": "data", "offset": offset, "length": OfficeLink.fileChunk])
            guard let data = piece[OfficeActions.bytesKey] as? Data, !data.isEmpty, (piece["size"] as? NSNumber)?.int64Value == size,
                  offset + Int64(data.count) <= size else { throw OfficeLink.Failure.garbled }
            try handle.write(contentsOf: data)
            offset += Int64(data.count)
        }
        try handle.synchronize()
        guard await Task.detached(operation: { RemotePullManager.sha256(part) }).value == sum else { throw OfficeLink.Failure.garbled }
        try fm.moveItem(at: part, to: target) // (fails rather than replace a file that's there)
    }

    static func delete(bundle: String, path: String) async {
        _ = try? await ask(action, ["bundle": bundle, "path": path, "step": "delete"])
    }

    /// An office Mac from before this action: it says it doesn't know it.
    static func needsUpdate(_ error: Error) -> Bool {
        ShrinkRemote.reason(error) == String(localized: "The always-on Mac needs a newer Pluck")
    }
}
