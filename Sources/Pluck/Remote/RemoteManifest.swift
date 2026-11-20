import Foundation

/// Which original on the office Mac a proxy stands for. Made by the host when it makes a proxy (B1),
/// kept beside pulled proxies on the remote (B2), read to link Resolve to the originals (B3) and by the
/// network-only mode (B5). Never matched by file name: by share + relative path.
struct RemoteManifestEntry: Codable, Hashable, Sendable {
    /// The shared folder's id on the host (`OfficeProxies.id(folder)`).
    var share: String
    /// The original's path inside that share ("Day 1/A001/A001C002.MXF").
    var path: String
    /// The proxy's path inside the share's proxy folder ("Day 1/A001/A001C002.mov").
    var proxy: String
    /// What Resolve and editors know the clip by (camera file name, no folder).
    var reel: String
    var timecode: String?
    var duration: Double?
    var fps: Double?
    var audioChannels: Int?
    var size: Int64
    /// SHA-256 of the proxy file, hex (verify after a pull).
    var checksum: String?
    /// An original pulled here (in "Originals/"): its path in the share. With `range`, only that part of it (RemotePieces).
    var pieceOf: String?
    /// The piece's first and last frame in the original.
    var range: [Int]?
    /// The viewing look burnt into this proxy ("slog3-709"); nil: none (OfficeLook).
    var look: String?
    /// An original kept on this Mac (RemotePins): its modification date at the office (seconds since 1970), which with its
    /// size tells a change when the manifest has no checksum of originals.
    var modified: Double?
}

/// The manifest of one share as the remote keeps it: written as `RemoteManifest.fileName` in the root of the
/// local folder that holds that share's proxies (a pulled folder or the mounted network volume).
struct RemoteManifest: Codable, Sendable {
    static let fileName = ".pluck-manifest.json"
    /// The paired host (its device id) and its name, for people.
    var host: String
    var hostName: String
    var share: String
    var shareName: String
    var entries: [RemoteManifestEntry]

    func entry(forProxy relative: String) -> RemoteManifestEntry? { entries.first { $0.proxy == relative } }
    func entry(forOriginal relative: String) -> RemoteManifestEntry? { entries.first { $0.path == relative } }

    static func load(in folder: URL) -> RemoteManifest? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(RemoteManifest.self, from: data)
    }

    func save(in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }
}
