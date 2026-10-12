import CryptoKit
import Foundation

/// Proxies for Edit Anywhere, on the host Mac: light copies of a shared footage folder, made one
/// file at a time, that paired Macs fetch to edit with at home and relink to the originals later.
/// They're kept in Pluck's own folder (never next to the footage), with the folder structure and
/// file names of the originals, so Resolve can link them as proxy media.
@MainActor
@Observable
final class OfficeProxies {
    static let shared = OfficeProxies()
    private static let requestsKey = "officeProxyRequests"
    private static let folderKey = "officeProxyFolder"
    /// Proxies nobody fetched from for this long are removed.
    private static let keepFor: TimeInterval = 21 * 86_400

    enum Format: String, Codable, CaseIterable, Identifiable {
        /// H.265 at up to 1080p: small enough to fetch over the internet.
        case light
        /// ProRes Proxy at up to 1080p: bigger, and the smoothest to edit with.
        case prores
        /// The footage itself, unconverted (to finish at full quality, or grade, elsewhere).
        case original

        var id: String { rawValue }

        var label: String {
            switch self {
            case .light: String(localized: "Light (H.265)")
            case .prores: String(localized: "ProRes Proxy")
            case .original: String(localized: "Originals")
            }
        }

        var detail: String {
            switch self {
            case .light: String(localized: "About 3 GB an hour of footage. Best over the internet.")
            case .prores: String(localized: "About 20 GB an hour, and the smoothest to edit with.")
            case .original: String(localized: "The footage itself, at full quality, unconverted.")
            }
        }
    }

    /// A folder a paired Mac asked proxies of.
    struct Request: Codable, Hashable {
        var folder: String
        var format: Format
        var lastUsed: Date
    }

    private(set) var requests: [Request] = []
    /// Where the proxies go on this Mac, chosen here (paired Macs can't choose paths on this
    /// Mac); nil keeps them in Pluck's own folder.
    private(set) var chosenFolder: URL?
    /// The file being made now, how far along, and how many wait.
    private(set) var working: String?
    private(set) var progress = 0.0
    private(set) var queued = 0

    @ObservationIgnored weak var manager: DownloadManager?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The footage in each shared folder, looked up now and then rather than on every question.
    @ObservationIgnored private var listings: [String: (files: [String], at: Date)] = [:]

    private init() {
        chosenFolder = UserDefaults.standard.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let data = UserDefaults.standard.data(forKey: Self.requestsKey),
           let saved = try? JSONDecoder().decode([Request].self, from: data) {
            requests = saved
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(requests) { UserDefaults.standard.set(data, forKey: Self.requestsKey) }
    }

    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/Edit Anywhere/Proxies", isDirectory: true)
    }

    /// A shared folder's id for paired Macs (never its path).
    nonisolated static func id(_ folder: URL) -> String {
        SHA256.hash(data: Data("pluck-proxies:\(folder.path)".utf8)).prefix(9).map { String(format: "%02x", $0) }.joined()
    }

    private func folder(_ id: String) throws -> URL {
        guard let folder = OfficeArchive.shared.folders.first(where: { Self.id($0) == id }) else {
            throw OfficeLink.Failure.office(String(localized: "That folder isn’t shared on the host Mac any more."))
        }
        return folder
    }

    /// The videos in a shared folder, by their path inside it.
    private func files(in id: String) async throws -> [String] {
        if let listing = listings[id], Date.now.timeIntervalSince(listing.at) < 120 { return listing.files }
        let folder = try folder(id)
        let files = await Task.detached {
            OfficeArchive.videoFiles(in: [folder]).map { String($0.path.dropFirst(folder.path.count + 1)) }.sorted()
        }.value
        listings[id] = (files, .now)
        return files
    }

    enum ChoiceProblem: LocalizedError {
        case insideFootage, notWritable
        var errorDescription: String? {
            switch self {
            case .insideFootage: String(localized: "Choose a folder outside the shared footage, so proxies aren’t mixed in with it.")
            case .notWritable: String(localized: "Pluck can’t write to that folder.")
            }
        }
    }

    /// Chooses where proxies go (nil: Pluck's own folder). Proxies made before stay where they
    /// are; the ones still missing are made in the new place.
    func choose(_ folder: URL?) throws {
        if let folder {
            let path = folder.standardizedFileURL.path + "/"
            guard !OfficeArchive.shared.folders.contains(where: { path.hasPrefix($0.standardizedFileURL.path + "/") }) else {
                throw ChoiceProblem.insideFootage
            }
            guard FileManager.default.isWritableFile(atPath: folder.path) else { throw ChoiceProblem.notWritable }
        }
        chosenFolder = folder
        UserDefaults.standard.set(folder?.path, forKey: Self.folderKey)
        // Each proxy's place is worked out when it's made, so the next one goes to the new folder.
        run()
    }

    /// A shared folder's proxies in one format: "<folder> – Proxies (H.265)" in the chosen folder,
    /// or a folder of Pluck's own.
    private func directory(_ id: String, format: Format) -> URL {
        guard let chosenFolder, let footage = try? folder(id) else {
            return Self.root.appendingPathComponent("\(id)-\(format.rawValue)", isDirectory: true)
        }
        let suffix = format == .light ? String(localized: "Proxies (H.265)") : String(localized: "Proxies (ProRes)")
        var name = Folders.sanitize(footage.lastPathComponent) + " – " + suffix
        // Two shared folders with the same name each get their own.
        if OfficeArchive.shared.folders.filter({ $0.lastPathComponent == footage.lastPathComponent }).count > 1 {
            name += " " + id.prefix(6)
        }
        return chosenFolder.appendingPathComponent(name, isDirectory: true)
    }

    private func proxy(_ relative: String, folder: String, format: Format) -> URL {
        // Originals are served as they are, straight from the footage.
        if format == .original, let footage = try? self.folder(folder) { return footage.appendingPathComponent(relative) }
        return directory(folder, format: format).appendingPathComponent((relative as NSString).deletingPathExtension + ".mov")
    }

    // MARK: - For paired Macs

    /// The shared footage folders, with how many videos each has.
    func sharedFolders() async -> [[String: Any]] {
        var answer: [[String: Any]] = []
        for folder in OfficeArchive.shared.folders {
            let id = Self.id(folder)
            let count = (try? await files(in: id).count) ?? 0
            answer.append(["id": id, "name": folder.lastPathComponent, "files": count])
        }
        return answer
    }

    /// Starts making proxies of a folder (if they aren't being made already).
    func make(_ id: String, format: Format) throws {
        _ = try folder(id)
        if let index = requests.firstIndex(where: { $0.folder == id && $0.format == format }) {
            requests[index].lastUsed = .now
        } else {
            requests.append(Request(folder: id, format: format, lastUsed: .now))
        }
        save()
        run()
    }

    /// What's ready of a folder's proxies: each video by its path inside the folder, with its
    /// proxy's size once it's made.
    func status(_ id: String, format: Format) async throws -> [String: Any] {
        let files = try await files(in: id)
        if let index = requests.firstIndex(where: { $0.folder == id && $0.format == format }) {
            requests[index].lastUsed = .now
            save()
        }
        let list: [[String: Any]] = files.map { relative in
            let proxy = proxy(relative, folder: id, format: format)
            let size = (try? FileManager.default.attributesOfItem(atPath: proxy.path)[.size] as? NSNumber)?.int64Value
            var item: [String: Any] = ["path": relative]
            if let size { item["size"] = size }
            return item
        }
        var answer: [String: Any] = ["files": list, "asked": requests.contains { $0.folder == id && $0.format == format }]
        if let working { answer["working"] = working; answer["progress"] = progress }
        return answer
    }

    /// A piece of a made proxy (for fetching in pieces). Only proxies of videos in the folder.
    func data(_ id: String, format: Format, path relative: String, offset: Int) async throws -> (data: Data, size: Int64) {
        guard try await files(in: id).contains(relative) else {
            throw OfficeLink.Failure.office(String(localized: "That video isn’t in the folder on the host Mac."))
        }
        let proxy = proxy(relative, folder: id, format: format)
        guard let handle = FileHandle(forReadingAtPath: proxy.path) else {
            throw OfficeLink.Failure.office(String(localized: "That proxy isn’t ready on the host Mac yet."))
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(offset, 0)))
        let data = try handle.read(upToCount: OfficeLink.proxyChunk) ?? Data()
        let size = (try? FileManager.default.attributesOfItem(atPath: proxy.path)[.size] as? NSNumber)?.int64Value ?? 0
        return (data, size)
    }

    // MARK: - Making them

    /// Works through every asked folder, one video at a time, skipping what's made. Waits while
    /// the host renders, so a render always has the Mac to itself.
    func run() {
        guard task == nil, !requests.isEmpty else { return }
        task = Task {
            defer { task = nil; working = nil; queued = 0 }
            tidy()
            guard let ffmpeg = manager?.tool("ffmpeg") else { return }
            let ffprobe = manager?.tool("ffprobe")
            var made = true
            // Again from the top after each pass, for footage added while it worked.
            while made, !Task.isCancelled {
                made = false
                for request in requests {
                    guard let folder = try? folder(request.folder), let files = try? await files(in: request.folder) else { continue }
                    let missing = files.filter { !FileManager.default.fileExists(atPath: proxy($0, folder: request.folder, format: request.format).path) }
                    for (number, relative) in missing.enumerated() where !Task.isCancelled {
                        while OfficeRenderServer.shared.jobs.contains(where: { $0.state == .rendering }), !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(20))
                        }
                        working = (relative as NSString).lastPathComponent
                        queued = missing.count - number - 1
                        progress = 0
                        let source = folder.appendingPathComponent(relative)
                        let target = proxy(relative, folder: request.folder, format: request.format)
                        if await Self.encode(source, to: target, format: request.format, ffmpeg: ffmpeg, ffprobe: ffprobe, progress: { value in
                            Task { @MainActor in OfficeProxies.shared.progress = value }
                        }) {
                            made = true
                        }
                    }
                }
            }
        }
    }

    func stop() {
        task?.cancel()
    }

    /// Proxies nobody asked about for three weeks go, with their request.
    private func tidy() {
        let old = requests.filter { Date.now.timeIntervalSince($0.lastUsed) > Self.keepFor }
        // Only Pluck's own folder is tidied; a chosen folder is the owner's to keep.
        for request in old {
            try? FileManager.default.removeItem(at: Self.root.appendingPathComponent("\(request.folder)-\(request.format.rawValue)"))
        }
        requests.removeAll { old.contains($0) }
        save()
    }

    /// One proxy: same frame rate, length and timecode as the original, at up to 1080p, written
    /// next to its final name and moved there when it's complete.
    nonisolated private static func encode(_ source: URL, to target: URL, format: Format, ffmpeg: String, ffprobe: String?,
                                           progress: @escaping @Sendable (Double) -> Void) async -> Bool {
        await Task.detached {
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let partial = target.deletingPathExtension().appendingPathExtension("part.mov")
            let (duration, timecode) = probe(source, ffprobe: ffprobe)
            var common = ["-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-i", source.path,
                          "-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0",
                          "-vf", "scale=-2:'min(1080,ih)'"]
            if let timecode { common += ["-timecode", timecode] }
            let attempts: [[String]] = switch format {
            case .light:
                [["-c:v", "hevc_videotoolbox", "-b:v", "8M", "-tag:v", "hvc1", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"],
                 ["-c:v", "h264_videotoolbox", "-b:v", "10M", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"]]
            case .original: []
            case .prores:
                [["-c:v", "prores_videotoolbox", "-profile:v", "proxy", "-c:a", "pcm_s16le"],
                 ["-c:v", "prores_ks", "-profile:v", "0", "-pix_fmt", "yuv422p10le", "-c:a", "pcm_s16le"]]
            }
            for attempt in attempts {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ffmpeg)
                process.arguments = common + attempt + ["-f", "mov", partial.path]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    guard let duration, duration > 0, let text = String(data: handle.availableData, encoding: .utf8) else { return }
                    for line in text.split(separator: "\n") where line.hasPrefix("out_time_us=") {
                        if let micro = Double(line.dropFirst("out_time_us=".count)) { progress(min(1, micro / 1_000_000 / duration)) }
                    }
                }
                guard (try? process.run()) != nil else { continue }
                process.waitUntilExit()
                pipe.fileHandleForReading.readabilityHandler = nil
                if process.terminationStatus == 0 {
                    try? FileManager.default.removeItem(at: target)
                    if (try? FileManager.default.moveItem(at: partial, to: target)) != nil { return true }
                }
                try? FileManager.default.removeItem(at: partial)
            }
            return false
        }.value
    }

    /// The original's length, and its starting timecode if it has one.
    nonisolated private static func probe(_ file: URL, ffprobe: String?) -> (Double?, String?) {
        guard let ffprobe else { return (nil, nil) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobe)
        process.arguments = ["-v", "error", "-show_entries", "format=duration:format_tags=timecode:stream_tags=timecode", "-of", "json", file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (nil, nil) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil) }
        let format = json["format"] as? [String: Any]
        let duration = (format?["duration"] as? String).flatMap(Double.init)
        let streams = json["streams"] as? [[String: Any]] ?? []
        let timecode = ((format?["tags"] as? [String: Any])?["timecode"] as? String)
            ?? streams.lazy.compactMap { ($0["tags"] as? [String: Any])?["timecode"] as? String }.first
        return (duration, timecode)
    }
}
