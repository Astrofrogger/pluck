import Foundation

/// Only the parts of the originals an edit uses, plus handles. The home Mac reads the used ranges from its Resolve
/// timeline (RemoteResolveScript `ranges`), maps the proxies back to their originals with the manifest and asks the
/// office Mac for one piece per original (`originalPiece`). The office cuts it without re-encoding: intra codecs frame
/// exact, long-GOP from the keyframe at or before the start to the next keyframe after the end (a little longer, never
/// shorter). RAW and anything ffmpeg can't cut comes whole. A piece keeps the original's file name, reel and timecode
/// (start + offset), so Resolve lands on the same frames.
enum RemotePieces {
    /// (A test points it at a name no office knows.)
    nonisolated(unsafe) static var action = "originalPiece"
    static let handlesKey = "editAnywhereHandles"

    /// Handles either side, in seconds (0–10, default 2).
    static var handles: Double {
        min(max(UserDefaults.standard.object(forKey: handlesKey) as? Double ?? 2, 0), 10)
    }

    // MARK: - Home: what to pull

    /// One timeline item's use of a file, as the `ranges` script reads it.
    struct Use: Equatable {
        var file: String
        var first: Int
        var last: Int
        /// Retimed (speed change): the whole clip is taken.
        var retimed = false
    }

    /// One original to pull: its part (frames) or why it's whole.
    struct Item: Identifiable, Equatable {
        var share: String
        var path: String
        var range: ClosedRange<Int>?
        var whole: String?
        var frames: Int?
        var id: String { share + "|" + path }
    }

    /// The `ranges` script's answer as uses, and the files that must come whole (inside compound or multicam clips).
    static func uses(_ answer: [String: Any]) -> (uses: [Use], whole: Set<String>) {
        let uses = (answer["items"] as? [[String: Any]] ?? []).compactMap { item -> Use? in
            guard let file = item["file"] as? String, !file.isEmpty,
                  let start = (item["start"] as? NSNumber)?.intValue, let end = (item["end"] as? NSNumber)?.intValue else { return nil }
            return Use(file: file, first: min(start, end), last: max(start, end), retimed: item["retimed"] as? Bool ?? false)
        }
        return (uses, Set(answer["whole"] as? [String] ?? []))
    }

    /// One span per original: every use merged, handles added either side, clamped to the clip.
    /// shortcut: uses far apart in one clip still make one piece (Resolve relinks a clip to one file), split them per use if that wastes too much.
    static func merge(_ ranges: [ClosedRange<Int>], handles: Int, frames: Int?) -> ClosedRange<Int>? {
        guard let low = ranges.map(\.lowerBound).min(), let high = ranges.map(\.upperBound).max() else { return nil }
        let first = max(0, low - handles), last = frames.map { min($0 - 1, high + handles) } ?? high + handles
        return first <= last ? first...last : nil
    }

    /// RAW: ffmpeg can't cut it (and Resolve's trim has no scripting call).
    static func isRaw(_ path: String) -> Bool {
        ProjectArchive.rawKinds.contains((path as NSString).pathExtension.lowercased()) || path.lowercased().hasSuffix(".rdc")
    }

    /// The originals the uses reach through the pulled (or mounted) proxies, with their part or why they come whole.
    /// Files that aren't proxies of the office Mac's shares are left out.
    static func plan(_ uses: [Use], whole: Set<String>, roots: [(manifest: RemoteManifest, root: URL)], handles seconds: Double) -> [Item] {
        var known: [String: RemoteManifestEntry] = [:]
        for (manifest, root) in roots {
            for entry in manifest.entries where entry.pieceOf == nil {
                known[RemoteResolveMap.normal(root.appendingPathComponent(entry.proxy).path)] = entry
            }
        }
        var items: [String: (entry: RemoteManifestEntry, ranges: [ClosedRange<Int>], whole: String?)] = [:]
        func add(_ entry: RemoteManifestEntry, _ range: ClosedRange<Int>?, why: String?) {
            let key = entry.share + "|" + entry.path
            var item = items[key] ?? (entry, [], nil)
            if let range { item.ranges.append(range) }
            if item.whole == nil { item.whole = why }
            items[key] = item
        }
        for use in uses {
            guard let entry = known[RemoteResolveMap.normal(use.file)] else { continue }
            add(entry, use.first...use.last, why: use.retimed ? String(localized: "speed change") : nil)
        }
        for file in whole {
            guard let entry = known[RemoteResolveMap.normal(file)] else { continue }
            add(entry, nil, why: String(localized: "inside a compound or multicam clip"))
        }
        return items.values.map { value in
            let entry = value.entry
            let frames = entry.duration.flatMap { duration in entry.fps.map { Int(($0 * duration).rounded()) } }
            let fps = entry.fps ?? 25
            var why = value.whole
            if why == nil, isRaw(entry.path) { why = String(localized: "RAW can’t be cut") }
            if why == nil, entry.fps == nil { why = String(localized: "its frame rate isn’t known") }
            let range = why == nil ? merge(value.ranges, handles: Int((seconds * fps).rounded()), frames: frames) : nil
            return Item(share: entry.share, path: entry.path, range: range, whole: range == nil ? why ?? String(localized: "no range") : nil, frames: frames)
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// About how big a piece is: its share of the original's frames.
    static func estimate(_ item: Item, size: Int64) -> Int64 {
        guard let range = item.range, let frames = item.frames, frames > 0 else { return size }
        return min(size, Int64(Double(size) * Double(range.count) / Double(frames)) + (1 << 20))
    }

    // MARK: - Office: cutting

    /// What a piece came out as.
    struct Piece: Codable, Equatable {
        var size: Int64
        var checksum: String
        var first: Int
        var last: Int
        var timecode: String?
    }

    static var cache: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/Edit Anywhere/Pieces", isDirectory: true)
    }

    /// Where a piece of an original is kept: a folder per original and range, the file under the original's name.
    static func file(share: String, relative: String, first: Int, last: Int) -> URL {
        cache.appendingPathComponent(OfficeProxies.pathID(share + "/" + relative), isDirectory: true)
            .appendingPathComponent("\(first)-\(last)", isDirectory: true)
            .appendingPathComponent((relative as NSString).lastPathComponent)
    }

    /// Codecs where every frame stands alone: cut on any frame.
    static func isIntra(codec: String, profile: String) -> Bool {
        ["prores", "dnxhd", "dnxhr", "mjpeg", "v210", "v410", "r210", "cfhd", "rawvideo", "ffv1"].contains(codec)
            || profile.localizedCaseInsensitiveContains("intra")
    }

    struct Probe {
        var codec = "", profile = "", container: String?, fps: Double?, start = 0.0, frames: Int?, timecode: String?, reel: String?
    }

    static func probe(_ file: URL, ffprobe: String) -> Probe {
        let data = run(ffprobe, ["-v", "error", "-select_streams", "v:0", "-show_entries",
                                 "stream=codec_name,profile,avg_frame_rate,r_frame_rate,nb_frames,start_time:format=format_name,start_time,duration:format_tags=timecode:stream_tags=timecode,reel_name",
                                 "-of", "json", file.path])
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let format = json["format"] as? [String: Any] ?? [:], stream = (json["streams"] as? [[String: Any]])?.first ?? [:]
        func rate(_ text: String?) -> Double? {
            let parts = (text ?? "").split(separator: "/").compactMap { Double($0) }
            guard parts.count == 2, parts[1] > 0, parts[0] > 0 else { return nil }
            return parts[0] / parts[1]
        }
        var result = Probe()
        result.codec = stream["codec_name"] as? String ?? ""
        result.profile = stream["profile"] as? String ?? ""
        result.container = format["format_name"] as? String
        result.fps = rate(stream["avg_frame_rate"] as? String) ?? rate(stream["r_frame_rate"] as? String)
        result.start = (format["start_time"] as? String).flatMap(Double.init) ?? 0
        let duration = (format["duration"] as? String).flatMap(Double.init)
        result.frames = (stream["nb_frames"] as? String).flatMap(Int.init) ?? duration.flatMap { d in result.fps.map { Int(($0 * d).rounded()) } }
        let tags = stream["tags"] as? [String: Any] ?? [:]
        result.timecode = (format["tags"] as? [String: Any])?["timecode"] as? String ?? tags["timecode"] as? String
        result.reel = (tags["reel_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return result
    }

    /// Keyframe times (seconds from the file's start) between two times.
    static func keyframes(_ file: URL, ffprobe: String, from: Double, to: Double, start: Double) -> [Double] {
        let text = String(decoding: run(ffprobe, ["-v", "error", "-select_streams", "v:0", "-skip_frame", "nokey",
                                                  "-read_intervals", String(format: "%.3f%%%.3f", start + max(0, from), start + to),
                                                  "-show_entries", "frame=best_effort_timestamp_time", "-of", "csv=p=0", file.path]), as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).compactMap { Double($0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ","))) }
            .map { $0 - start }.sorted()
    }

    /// The span to cut for frames first…last: intra frame exact; long-GOP from the keyframe at or before the start to the
    /// next keyframe after the end (nil end: to the file's end). Pure, for the test.
    static func span(first: Int, last: Int, fps: Double, intra: Bool, keys: [Double]) -> (first: Int, end: Int?) {
        guard !intra else { return (first, last + 1) }
        let frames = keys.map { Int(($0 * fps).rounded()) }
        let start = frames.last { $0 <= first } ?? 0
        return (start, frames.first { $0 > last })
    }

    /// Cuts (or finds kept) the piece of `original` for frames first…last. Throws `whole` with why it can't be cut.
    struct Whole: Error { var why: String }

    static func make(_ original: URL, share: String, relative: String, first: Int, last: Int, ffmpeg: String, ffprobe: String) throws -> Piece {
        guard !isRaw(original.path), !RemoteEditHost.isDirectory(original) else { throw Whole(why: String(localized: "RAW can’t be cut")) }
        let probed = probe(original, ffprobe: ffprobe)
        guard let fps = probed.fps, let demuxer = OfficeProxies.demuxer(probed.container) else {
            throw Whole(why: String(localized: "this file can’t be cut"))
        }
        let intra = isIntra(codec: probed.codec, profile: probed.profile)
        let keys = intra ? [] : keyframes(original, ffprobe: ffprobe, from: Double(first) / fps - 30, to: Double(last + 1) / fps + 30, start: probed.start)
        guard intra || !keys.isEmpty else { throw Whole(why: String(localized: "this file can’t be cut")) }
        var (start, end) = span(first: first, last: last, fps: fps, intra: intra, keys: keys)
        if let frames = probed.frames, let stop = end, stop >= frames { end = nil }
        let final = max(end.map { $0 - 1 } ?? (probed.frames.map { $0 - 1 } ?? last), start)
        // (Kept by the range it really has: `fileData` kind piece asks for that one.)
        let target = file(share: share, relative: relative, first: start, last: final)
        let info = target.deletingLastPathComponent().appendingPathComponent(".piece.json")
        if let data = try? Data(contentsOf: info), let kept = try? JSONDecoder().decode(Piece.self, from: data),
           RemotePullManager.size(of: target) == kept.size {
            try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: info.path)
            return kept
        }
        // (A quarter frame early: ffmpeg keeps the packets from that time on, so the first one is the frame itself.)
        var arguments = ["-nostdin", "-y", "-v", "error", "-ss", String(format: "%.4f", max(0, (Double(start) - 0.25) / fps)),
                         "-f", demuxer, "-i", original.path]
        if let end { arguments += ["-t", String(format: "%.4f", Double(end - start) / fps)] }
        arguments += ["-map", "0:v:0", "-map", "0:a?", "-c", "copy", "-map_metadata", "0"]
        var timecode: String?
        if let source = probed.timecode, let base = RawPlayer.frames(in: source, rate: Int(fps.rounded())) {
            timecode = RawPlayer.timecode(base + start, rate: Int(fps.rounded()), dropFrame: source.contains(";"))
            arguments += ["-timecode", timecode!]
        }
        // (QuickTime keeps the reel on the timecode track: read from every stream, as OfficeProxies does.)
        let reel = OfficeProxies.probe(original, ffprobe: ffprobe).3 ?? probed.reel
        arguments += ["-metadata:s:v:0", "reel_name=" + (reel ?? original.deletingPathExtension().lastPathComponent)]
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString.prefix(8)).\(original.pathExtension)")
        defer { try? fm.removeItem(at: partial) }
        guard status(ffmpeg, arguments + [partial.path]) == 0, let size = RemotePullManager.size(of: partial), size > 0,
              let checksum = RemoteProxyJobs.checksum(partial) else { throw Whole(why: String(localized: "this file can’t be cut")) }
        try? fm.removeItem(at: target)
        try fm.moveItem(at: partial, to: target)
        let piece = Piece(size: size, checksum: checksum, first: start, last: final, timecode: timecode)
        try JSONEncoder().encode(piece).write(to: info, options: .atomic)
        return piece
    }

    /// Pieces nobody fetched for the proxies' keep time go (like unused proxies).
    static func tidy(keepDays: Int) {
        guard keepDays > 0, let originals = try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil) else { return }
        let limit = Date.now.addingTimeInterval(-Double(keepDays) * 86_400)
        for folder in originals {
            for range in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                let info = range.appendingPathComponent(".piece.json")
                let used = (try? info.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if used < limit { try? FileManager.default.removeItem(at: range) }
            }
        }
    }

    // MARK: - Office: the action

    @MainActor
    static func register() {
        // {share, path, first, last} → {size, checksum, first, last, timecode} of the piece, or {whole: why}.
        OfficeActions.register(action) { arguments, device in
            try OfficeActions.require(\.originals, device)
            let (root, id) = try RemoteEditHost.share(arguments["share"])
            let original = try RemoteEditHost.resolve(try OfficeActions.text(arguments["path"]), in: root)
            let first = Int(try OfficeActions.number(arguments["first"])), last = Int(try OfficeActions.number(arguments["last"]))
            guard last >= first else { throw OfficeActions.incomplete() }
            guard let ffmpeg = OfficeRenderServer.shared.manager?.tool("ffmpeg"), let ffprobe = OfficeRenderServer.shared.manager?.tool("ffprobe") else {
                return ["whole": String(localized: "ffmpeg isn’t installed on the office Mac")]
            }
            RemoteKeepAwake.transferred()
            let relative = RemoteEditHost.relative(original, in: root)
            do {
                let piece = try await Task.detached { try make(original, share: id, relative: relative, first: first, last: last, ffmpeg: ffmpeg, ffprobe: ffprobe) }.value
                var answer: [String: Any] = ["size": piece.size, "checksum": piece.checksum, "first": piece.first, "last": piece.last]
                if let timecode = piece.timecode { answer["timecode"] = timecode }
                return answer
            } catch let whole as Whole {
                return ["whole": whole.why]
            }
        }
    }

    /// The kept piece `fileData` kind "piece" serves (made by `originalPiece` first).
    @MainActor
    static func served(share: String, relative: String, _ arguments: [String: Any]) throws -> URL {
        let first = Int(try OfficeActions.number(arguments["first"])), last = Int(try OfficeActions.number(arguments["last"]))
        return file(share: share, relative: relative, first: first, last: last)
    }

    // MARK: - Running tools

    private static func run(_ tool: String, _ arguments: [String]) -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return Data() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    private static func status(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
