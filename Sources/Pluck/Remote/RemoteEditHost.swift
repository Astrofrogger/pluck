import AVFoundation
import AppKit
import Foundation
import UniformTypeIdentifiers

/// Remote editing on the host Mac: the shared folders as shares a paired Mac can browse, read the
/// details and a picture of, and fetch pieces of (originals, proxies, thumbnails). Paths from a
/// paired Mac are always relative to a share and checked to stay inside it (see `resolve`).
@MainActor
enum RemoteEditHost {
    static func register() {
        OfficeActions.register("shares") { _, _ in ["shares": await shares()] }
        OfficeActions.register("status") { _, _ in
            ["office": Host.current().localizedName ?? "Mac", "busy": OfficeRenderServer.shared.isRendering, "shares": await shares()]
        }
        OfficeActions.register("browse") { arguments, device in
            try OfficeActions.require(\.browse, device)
            let (root, _) = try share(arguments["share"])
            let folder = try resolve(try OfficeActions.text(arguments["path"], empty: true), in: root)
            return ["entries": try await Task.detached { try list(folder, in: root) }.value]
        }
        OfficeActions.register("mediaInfo") { arguments, device in
            try OfficeActions.require(\.browse, device)
            let (root, _) = try share(arguments["share"])
            return try await mediaInfo(try resolve(try OfficeActions.text(arguments["path"]), in: root))
        }
        OfficeActions.register("thumb") { arguments, device in
            try OfficeActions.require(\.browse, device)
            let (root, _) = try share(arguments["share"])
            return [OfficeActions.bytesKey: try await thumb(try resolve(try OfficeActions.text(arguments["path"]), in: root))]
        }
        OfficeActions.register("fileData") { arguments, device in RemoteKeepAwake.transferred(); return try await fileData(arguments, device) }
    }

    // MARK: - Shares

    /// The shared folders (OfficeArchive.folders); a share's id is OfficeProxies.id (from its path),
    /// the same id the proxy actions use.
    static func share(_ value: Any?) throws -> (root: URL, id: String) {
        let id = try OfficeActions.text(value, 40)
        guard let folder = OfficeArchive.shared.folders.first(where: { OfficeProxies.id($0) == id }) else {
            throw OfficeLink.Failure.office(String(localized: "That folder isn’t shared on the host Mac any more."))
        }
        return (folder, id)
    }

    /// Online state and free space with a timeout per share (RemoteShares).
    static func shares() async -> [[String: Any]] { await RemoteShares.shared.answer() }

    // MARK: - Paths

    nonisolated static func realPath(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }

    /// A path from a paired Mac, relative to the share, as a real path inside it; anything that
    /// isn't (absolute, `..`, a symlink out, missing) is refused.
    nonisolated static func resolve(_ relative: String, in root: URL) throws -> URL {
        let refused = OfficeLink.Failure.office(String(localized: "That file isn’t in the shared folder."))
        guard !relative.hasPrefix("/"), !relative.contains("\0"), !relative.split(separator: "/").contains("..") else { throw refused }
        guard let base = realPath(root.path) else {
            throw OfficeLink.Failure.office(String(localized: "The shared folder isn’t reachable on the host Mac right now."))
        }
        guard let full = realPath(relative.isEmpty ? base : base + "/" + relative), full == base || full.hasPrefix(base + "/") else { throw refused }
        return URL(fileURLWithPath: full)
    }

    /// The path inside the share of a resolved file.
    nonisolated static func relative(_ file: URL, in root: URL) -> String {
        let base = realPath(root.path) ?? root.path
        return String(file.path.dropFirst(base.count + 1))
    }

    // MARK: - Browsing

    /// What NAS and drives keep for themselves (besides dot files).
    nonisolated static let systemNames: Set<String> = ["$RECYCLE.BIN", "System Volume Information", "@eaDir", "#recycle", "#snapshot",
                                                       "Network Trash Folder", "Temporary Items", "lost+found"]

    /// A folder's entries, folders first; symlinks are followed but only kept when they stay in the share.
    nonisolated static func list(_ folder: URL, in root: URL) throws -> [[String: Any]] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        let base = realPath(root.path) ?? root.path
        let items = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        let entries = items.compactMap { url -> (name: String, folder: Bool, entry: [String: Any])? in
            let name = url.lastPathComponent
            guard !name.hasPrefix("."), !systemNames.contains(name), let real = realPath(url.path), real.hasPrefix(base + "/"),
                  let values = try? URL(fileURLWithPath: real).resourceValues(forKeys: Set(keys)) else { return nil }
            let isFolder = values.isDirectory == true && values.isPackage != true
            return (name, isFolder, ["name": name, "folder": isFolder, "size": values.fileSize ?? 0,
                                     "modified": values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                                     "isVideo": !isFolder && Converting.isVideo(url)])
        }
        return entries.sorted { $0.folder != $1.folder ? $0.folder : $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map(\.entry)
    }

    // MARK: - Details and pictures

    private static var infoCache: [String: (modified: Date, info: [String: Any])] = [:]

    /// Duration, timecode, fps, size, codec and audio channels: AVFoundation (and pluck-raw) first,
    /// ffprobe for the timecode and what AVFoundation can't read. Kept per path and change date.
    static func mediaInfo(_ file: URL) async throws -> [String: Any] {
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if let cached = infoCache[file.path], cached.modified == modified { return cached.info }
        let details = await OffloadClips.read(file)
        var info: [String: Any] = [:]
        if let duration = details.duration { info["duration"] = duration }
        if let fps = details.fps { info["fps"] = fps }
        if let width = details.width, let height = details.height { info["width"] = width; info["height"] = height }
        if let codec = details.codec { info["codec"] = codec }
        var channels = 0
        for track in (try? await AVURLAsset(url: file).loadTracks(withMediaType: .audio)) ?? [] {
            for format in (try? await track.load(.formatDescriptions)) ?? [] {
                channels += Int(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mChannelsPerFrame ?? 0)
            }
        }
        info["audioChannels"] = channels
        let ffprobe = OfficeRenderServer.shared.manager?.tool("ffprobe")
        let probed = await Task.detached { OfficeProxies.probe(file, ffprobe: ffprobe) }.value
        if let timecode = probed.1 { info["timecode"] = timecode }
        if info["duration"] == nil, let duration = probed.0 { info["duration"] = duration }
        infoCache[file.path] = (modified, info)
        return info
    }

    /// A small JPEG (320 points on the long side).
    static func thumb(_ file: URL) async throws -> Data {
        guard let image = await OffloadClips.thumbnail(file, size: 320) else {
            throw OfficeLink.Failure.office(String(localized: "There’s no picture for that file."))
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw OfficeActions.incomplete() }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw OfficeActions.incomplete() }
        return data as Data
    }

    // MARK: - File pieces

    /// {share, path, kind: original|proxy|thumb, format (proxy: light|prores), offset, length}: up to
    /// OfficeLink.fileChunk raw bytes, with the whole file's size. Each piece is its own request, so
    /// several can run at once.
    static func fileData(_ arguments: [String: Any], _ device: OfficeRenderServer.Device) async throws -> [String: Any] {
        let (root, id) = try share(arguments["share"])
        let original = try resolve(try OfficeActions.text(arguments["path"]), in: root)
        let offset = try OfficeActions.number(arguments["offset"] ?? 0)
        let length = Int(min(try OfficeActions.number(arguments["length"] ?? OfficeLink.fileChunk), Int64(OfficeLink.fileChunk)))
        let file: URL
        switch arguments["kind"] as? String {
        case "original":
            try OfficeActions.require(\.originals, device)
            file = original
        case "proxy":
            try OfficeActions.require(\.proxies, device)
            if arguments["stream"] as? Bool == true, !RemoteNetworkHost.streamAllowed {
                throw OfficeLink.Failure.office(String(localized: "Streaming is turned off on the host Mac."))
            }
            guard let format = OfficeProxies.Format(rawValue: arguments["format"] as? String ?? "light"), format != .original else {
                throw OfficeActions.incomplete()
            }
            file = OfficeProxies.shared.proxy(relative(original, in: root), folder: id, format: format)
            OfficeProxies.shared.used(id, format: format)
        case "thumb":
            try OfficeActions.require(\.browse, device)
            let picture = try await thumb(original)
            let start = Int(min(offset, Int64(picture.count)))
            return [OfficeActions.bytesKey: picture.subdata(in: start..<min(start + length, picture.count)), "size": picture.count]
        default:
            throw OfficeActions.incomplete()
        }
        return try await Task.detached { () -> [String: Any] in
            guard let handle = FileHandle(forReadingAtPath: file.path),
                  let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value else {
                throw OfficeLink.Failure.office(String(localized: "That file isn’t ready on the host Mac (yet)."))
            }
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(min(offset, size)))
            return [OfficeActions.bytesKey: try handle.read(upToCount: length) ?? Data(), "size": size]
        }.value
    }
}
