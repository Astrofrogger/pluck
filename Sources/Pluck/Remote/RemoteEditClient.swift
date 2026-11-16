import Foundation

/// Remote editing, on a Mac away from the host: the host's shares, their folders and files, a
/// file's details and picture, and file pieces (see RemoteEditHost for the host's side).
extension OfficeRenderClient {
    struct RemoteShare: Identifiable, Hashable {
        var id: String
        var name: String
        var online: Bool
        var freeBytes: Int64
        var totalBytes: Int64

        init?(_ value: [String: Any]) {
            guard let id = value["id"] as? String else { return nil }
            self.id = id
            name = value["name"] as? String ?? ""
            online = value["online"] as? Bool ?? false
            freeBytes = (value["freeBytes"] as? NSNumber)?.int64Value ?? 0
            totalBytes = (value["totalBytes"] as? NSNumber)?.int64Value ?? 0
        }
    }

    struct RemoteEntry: Hashable {
        var name: String
        var folder: Bool
        var size: Int64
        var modified: Date
        var isVideo: Bool
        /// A clip (a movie, a raw file, a clip folder) and one only pluck-raw reads; nil from a host from before them.
        var clip: Bool?
        var raw: Bool?

        init?(_ value: [String: Any]) {
            guard let name = value["name"] as? String else { return nil }
            self.name = name
            folder = value["folder"] as? Bool ?? false
            size = (value["size"] as? NSNumber)?.int64Value ?? 0
            modified = Date(timeIntervalSince1970: value["modified"] as? Double ?? 0)
            isVideo = value["isVideo"] as? Bool ?? false
            clip = value["clip"] as? Bool
            raw = value["raw"] as? Bool
        }
    }

    struct RemoteMediaInfo: Hashable {
        var duration: Double?
        var timecode: String?
        var fps: Double?
        var width: Int?
        var height: Int?
        var codec: String?
        var audioChannels: Int
    }

    enum FileKind: String { case original, proxy, thumb }

    func shares() async throws -> [RemoteShare] {
        if members.count > 1, account != nil { return try await groupShares() }
        return (try await ask("shares", timeout: 30)["shares"] as? [[String: Any]] ?? []).compactMap(RemoteShare.init)
    }

    /// The folder's entries, folders first; `path` is relative to the share ("" for its top).
    func browse(share: String, path: String) async throws -> [RemoteEntry] {
        (try await ask("browse", ["share": share, "path": path], timeout: 60)["entries"] as? [[String: Any]] ?? []).compactMap(RemoteEntry.init)
    }

    func mediaInfo(share: String, path: String) async throws -> RemoteMediaInfo {
        let answer = try await ask("mediaInfo", ["share": share, "path": path], timeout: 60)
        return RemoteMediaInfo(duration: answer["duration"] as? Double, timecode: answer["timecode"] as? String, fps: answer["fps"] as? Double,
                               width: answer["width"] as? Int, height: answer["height"] as? Int, codec: answer["codec"] as? String,
                               audioChannels: answer["audioChannels"] as? Int ?? 0)
    }

    /// A small JPEG of the file.
    func thumb(share: String, path: String) async throws -> Data {
        guard let data = try await ask("thumb", ["share": share, "path": path], timeout: 60)[OfficeActions.bytesKey] as? Data else {
            throw OfficeLink.Failure.garbled
        }
        return data
    }

    /// One piece of a file (at most OfficeLink.fileChunk bytes) and the whole file's size. Pieces
    /// can be asked for at once, each on its own connection.
    func fileData(share: String, path: String, kind: FileKind, format: OfficeProxies.Format = .light,
                  offset: Int64, length: Int = OfficeLink.fileChunk) async throws -> (data: Data, size: Int64) {
        let answer = try await ask("fileData", ["share": share, "path": path, "kind": kind.rawValue, "format": format.rawValue,
                                                "offset": offset, "length": length], timeout: 120)
        guard let data = answer[OfficeActions.bytesKey] as? Data, let size = (answer["size"] as? NSNumber)?.int64Value else {
            throw OfficeLink.Failure.garbled
        }
        return (data, size)
    }

    /// The host's name, whether it's rendering, and its shares.
    func status() async throws -> (office: String, busy: Bool, shares: [RemoteShare]) {
        let answer = try await ask("status", timeout: 30)
        // (Several office Macs: all their shares.)
        let shares = members.count > 1 && account != nil ? try await groupShares()
            : (answer["shares"] as? [[String: Any]] ?? []).compactMap(RemoteShare.init)
        return (answer["office"] as? String ?? "", answer["busy"] as? Bool ?? false, shares)
    }
}
