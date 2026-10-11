import AppKit
import CryptoKit
import Foundation

/// Archive search for Edit Anywhere: the office footage (on the office storage), looked at on the
/// office Mac with Find Shots' engine, so a paired Mac at home can search it by what's in the
/// picture and fetch just the shots it needs as light copies. Paths never leave the office Mac.
@MainActor
@Observable
final class OfficeArchive {
    static let shared = OfficeArchive()
    static let foldersKey = "officeArchiveFolders"

    private(set) var folders: [URL] = []
    private(set) var indexes: [VisualIndex.FileIndex] = []
    /// Video files found in the folders.
    private(set) var fileCount = 0
    /// The file being looked at now, how far along, and how many wait.
    private(set) var working: String?
    private(set) var progress = 0.0
    private(set) var queued = 0

    @ObservationIgnored weak var manager: DownloadManager?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastScan = Date.distantPast
    /// Clips made for paired Macs: an unguessable id → the file.
    @ObservationIgnored private var clips: [String: URL] = [:]

    private init() {
        folders = (UserDefaults.standard.stringArray(forKey: Self.foldersKey) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private static var clipFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/Office Render/Clips", isDirectory: true)
    }

    func add(_ folder: URL) {
        guard !folders.contains(folder) else { return }
        folders.append(folder)
        save()
        scan()
    }

    func remove(_ folder: URL) {
        folders.removeAll { $0 == folder }
        save()
        reload(files: videoFiles())
    }

    private func save() {
        UserDefaults.standard.set(folders.map(\.path), forKey: Self.foldersKey)
    }

    /// Looks for footage not looked at yet (and changed files) and works through it, one file at a
    /// time. Runs when Edit Anywhere starts and every few hours.
    func scan() {
        guard task == nil, !folders.isEmpty else { return }
        lastScan = .now
        task = Task {
            let files = await Task.detached { [folders] in Self.videoFiles(in: folders) }.value
            fileCount = files.count
            reload(files: files)
            let missing = files.filter { !VisualIndex.isIndexed($0) }
            if let ffmpeg = manager?.tool("ffmpeg") {
                for (n, file) in missing.enumerated() where !Task.isCancelled {
                    working = file.lastPathComponent
                    queued = missing.count - n - 1
                    progress = 0
                    _ = try? await VisualIndex.index(file, ffmpeg: ffmpeg) { value in
                        Task { @MainActor in self.progress = value }
                    }
                    if n % 10 == 9 { reload(files: files) }
                }
            }
            reload(files: files)
            working = nil
            queued = 0
            task = nil
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        working = nil
    }

    /// Every few hours while Edit Anywhere runs, so new shoots become searchable by themselves.
    func scanIfDue() {
        if Date.now.timeIntervalSince(lastScan) > 4 * 3600 { scan() }
    }

    private func reload(files: [URL]) {
        indexes = files.compactMap { VisualIndex.load($0.path) }
    }

    private func videoFiles() -> [URL] { Self.videoFiles(in: folders) }

    nonisolated private static func videoFiles(in folders: [URL]) -> [URL] {
        var found: [URL] = []
        for folder in folders {
            let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = items?.nextObject() as? URL {
                if Converting.isVideo(url) { found.append(url) }
            }
        }
        return found
    }

    // MARK: - For paired Macs

    /// The id a paired Mac uses for a shot (never the path).
    private static func id(path: String, start: Double) -> String {
        SHA256.hash(data: Data("pluck-archive:\(path)@\(Int(start * 100))".utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Where a file sits, for people: its folder within the archive folder, and its name.
    private func place(_ path: String) -> String {
        for folder in folders where path.hasPrefix(folder.path + "/") {
            return folder.lastPathComponent + "/" + String(path.dropFirst(folder.path.count + 1))
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    var status: [String: Any] {
        ["folders": folders.count, "files": fileCount, "indexed": indexes.count, "working": working != nil]
    }

    /// The best shots for a search, with a small picture of each.
    func search(_ query: String, movement: String?, framing: String?) -> [[String: Any]] {
        let hits = VisualIndex.search(query, in: indexes, movement: movement.flatMap(VisualIndex.Movement.init(rawValue:)),
                                      framing: framing.flatMap(VisualIndex.Framing.init(rawValue:)), limit: 60)
        return hits.map { hit in
            var item: [String: Any] = ["id": Self.id(path: hit.path, start: hit.shot.start), "place": place(hit.path),
                                       "start": hit.shot.start, "end": hit.shot.end, "description": hit.shot.description,
                                       "framing": hit.shot.framing.rawValue, "movement": hit.shot.movement.rawValue]
            if let data = Self.thumbnail(path: hit.path, start: hit.shot.start) { item["thumb"] = data.base64EncodedString() }
            return item
        }
    }

    /// The shot's thumbnail, made smaller to travel well (about 10 kB).
    private static func thumbnail(path: String, start: Double) -> Data? {
        let url = VisualIndex.thumbnailURL(path: path, start: start)
        guard let image = NSImage(contentsOf: url), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = 240.0, height = width * Double(cg.height) / Double(max(cg.width, 1))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: cg, size: .zero).draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }

    /// A light 1080p copy of one shot with a second of handles each side, made once and kept
    /// for a while. Returns its id for fetching and its size.
    func clip(_ id: String) async throws -> (token: String, size: Int64, name: String) {
        guard let (path, shot) = shotFor(id) else {
            throw OfficeLink.Failure.office(String(localized: "That shot isn’t in the host Mac’s footage any more."))
        }
        guard let ffmpeg = manager?.tool("ffmpeg") else { throw Converting.Failure.noFFmpeg }
        try FileManager.default.createDirectory(at: Self.clipFolder, withIntermediateDirectories: true)
        let target = Self.clipFolder.appendingPathComponent(id + ".mp4")
        if !FileManager.default.fileExists(atPath: target.path) {
            let start = max(shot.start - 1, 0), length = shot.end - shot.start + 2
            let ok = await Task.detached { () -> Bool in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ffmpeg)
                process.arguments = ["-nostdin", "-y", "-loglevel", "error", "-ss", String(start), "-i", path, "-t", String(length),
                                     "-map", "0:v:0", "-map", "0:a:0?", "-vf", "scale=-2:'min(1080,ih)'",
                                     "-c:v", "h264_videotoolbox", "-b:v", "12M", "-c:a", "aac", "-b:a", "192k",
                                     "-movflags", "+faststart", target.path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return false }
                process.waitUntilExit()
                return process.terminationStatus == 0
            }.value
            guard ok else {
                try? FileManager.default.removeItem(at: target)
                throw OfficeLink.Failure.office(String(localized: "The host Mac couldn’t make that clip."))
            }
        }
        let token = OfficeLink.randomBytes(12).map { String(format: "%02x", $0) }.joined()
        clips[token] = target
        let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? 0
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            + String(format: " (%.0f–%.0f s)", shot.start, shot.end)
        return (token, size, name)
    }

    /// A piece of a clip made above (for fetching in pieces).
    func clipData(_ token: String, offset: Int) throws -> (data: Data, size: Int64) {
        guard let url = clips[token], let handle = FileHandle(forReadingAtPath: url.path) else {
            throw OfficeLink.Failure.office(String(localized: "That clip isn’t ready on the host Mac."))
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(offset, 0)))
        let data = try handle.read(upToCount: OfficeLink.previewChunk) ?? Data()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return (data, size)
    }

    private func shotFor(_ id: String) -> (String, VisualIndex.Shot)? {
        for index in indexes {
            for shot in index.shots where Self.id(path: index.path, start: shot.start) == id { return (index.path, shot) }
        }
        return nil
    }

    /// Clips nobody fetched for a week go.
    func tidyClips() {
        let old = Date.now.addingTimeInterval(-7 * 86_400)
        for url in (try? FileManager.default.contentsOfDirectory(at: Self.clipFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < old {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
