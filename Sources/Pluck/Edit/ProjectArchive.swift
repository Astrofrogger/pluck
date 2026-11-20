import AppKit
import CryptoKit
import Foundation

/// Archive Project: after delivery, only what the edit used (plus renders, extra folders and the
/// project files) goes to the NAS or an archive drive, copied and checked by Offload's engine
/// (xxHash64, several drives, carries on after a stop, an MHL beside each copy), with an
/// inventory (CSV and a page to read). Caches and proxies go to the Trash afterwards, only once
/// everything is checked and only what was listed and confirmed.
enum ProjectArchive {
    /// A stretch of a file a timeline uses (seconds into the file; `end` infinite: all of it).
    struct Use: Hashable, Sendable {
        var start: Double
        var end: Double
        var timeline: String
    }

    /// What a job uses, by file path.
    typealias Uses = [String: [Use]]

    enum Kind: String, Sendable { case media, render, extra, project }

    /// A file to archive: from `root`/`relative`, to `into`/`relative` in the archive folder.
    struct Item: Identifiable, Hashable, Sendable {
        var id: String { archived }
        var root: String
        var relative: String
        var into: String
        var size: Int64
        var modified: Date
        var kind: Kind
        var uses: [Use] = []
        /// The part kept, in the original's seconds, when only that goes (nil: the whole file).
        var trim: ClosedRange<Double>?
        var duration: Double?
        /// The original (a trimmed clip's, not the piece made from it).
        var original: String
        /// A master made from the original and checked against it (what goes instead of it).
        var master: MasterSettings?

        var source: String { (root as NSString).appendingPathComponent(relative) }
        var archived: String { (into as NSString).appendingPathComponent(relative) }
        var timelines: [String] { Array(Set(uses.map(\.timeline))).sorted() }
    }

    /// Something that can go once the archive is checked: a cache or proxy Pluck or Resolve made.
    struct Cleanable: Identifiable, Hashable, Sendable {
        var id: String { path }
        var path: String
        var size: Int64
        /// "Pluck's playable copies", "Resolve's render cache".
        var label: String
        /// Ticked to start with (Pluck's own; Resolve's caches are shared by other projects).
        var suggested: Bool
        /// An original: the checked master in the archive that replaces it.
        var master: String?
    }

    /// Where a job's files come from.
    struct Sources {
        var name: String
        var uses: Uses = [:]
        /// A Pluck project: its file is rewritten to point at the archived copies.
        var pluck: Project?
        /// The offload project's folder: the media keeps its layout below it.
        var projectFolder: String?
        var renders: [String] = []
        var extras: [String] = []
        /// Project files given as they are (.drp, .drt, FCPXML, EDL), to Project/.
        var projectFiles: [String] = []
        /// Resolve's cache folder (its project setting), when read from Resolve.
        var resolveCache: String?
    }

    struct Plan: Sendable {
        var name: String
        var items: [Item]
        /// Used files that aren't there.
        var missing: [String]
        var cleanables: [Cleanable]
        var mediaRoot: String

        /// About the bytes the archive takes (trimmed clips by the share kept).
        var bytes: Int64 {
            items.reduce(0) { sum, item in
                guard let trim = item.trim, let duration = item.duration, duration > 0 else { return sum + item.size }
                return sum + Int64(Double(item.size) * min((trim.upperBound - trim.lowerBound) / duration, 1))
            }
        }
        func bytes(_ kind: Kind) -> Int64 { items.filter { $0.kind == kind }.reduce(0) { $0 + $1.size } }
    }

    /// Raw camera files: always whole (their own formats can't be cut without re-encoding).
    static let rawKinds: Set<String> = ["r3d", "braw", "ari", "arx", "crm", "nev", "dng", "rmf", "cine"]
    /// Containers ffmpeg can cut without re-encoding.
    static let trimKinds: Set<String> = ["mov", "mp4", "m4v", "mxf", "mts", "m2ts", "mkv"]
    static let mediaKinds: Set<String> = trimKinds.union(rawKinds).union(["wav", "aif", "aiff", "mp3", "m4a", "flac", "avi", "png", "jpg", "jpeg", "tif", "tiff", "exr", "psd"])

    // MARK: - What's used

    /// A Pluck project's clips, extra tracks and music, each with the part used.
    static func uses(of project: Project) -> Uses {
        var uses: Uses = [:]
        let clips = project.clips + (project.tracks ?? []).flatMap(\.items)
        for clip in clips where clip.motion == nil {
            // A held frame's start and end aren't the file's time: its frame only.
            let range = clip.freeze.map { ($0, $0) } ?? (clip.start, clip.end)
            uses[clip.path, default: []].append(Use(start: range.0, end: range.1, timeline: project.name))
        }
        for song in project.music { uses[song.path, default: []].append(Use(start: song.start, end: song.end, timeline: project.name)) }
        return uses
    }

    /// Seconds from an FCPXML time ("1001/30000s", "5s").
    static func seconds(_ text: String?) -> Double? {
        guard var text, text.hasSuffix("s") else { return nil }
        text.removeLast()
        let parts = text.split(separator: "/").compactMap { Double($0) }
        if parts.count == 2, parts[1] != 0 { return parts[0] / parts[1] }
        return parts.count == 1 ? parts[0] : nil
    }

    /// The files an FCPXML (from Resolve, Final Cut or Premiere) uses, with the part of each.
    static func uses(fcpxml data: Data, timeline fallback: String) -> Uses {
        final class Reader: NSObject, XMLParserDelegate {
            var assets: [String: (src: String, start: Double)] = [:]
            var asset: (id: String, start: Double)?
            var stack: [[String: String]] = []
            var project: String?
            var found: [(ref: String, start: Double, duration: Double, timeline: String?)] = []
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
                switch name {
                case "asset":
                    let id = attributes["id"] ?? ""
                    asset = (id, ProjectArchive.seconds(attributes["start"]) ?? 0)
                    if let src = attributes["src"] { assets[id] = (src, asset!.start) }
                case "media-rep":
                    if let asset, let src = attributes["src"], assets[asset.id] == nil || attributes["kind"] == "original-media" {
                        assets[asset.id] = (src, asset.start)
                    }
                case "project":
                    project = attributes["name"]
                default:
                    if let ref = attributes["ref"], name == "asset-clip" || name == "video" || name == "audio" || name == "clip" {
                        // A child without its own times takes its parent's.
                        let start = ProjectArchive.seconds(attributes["start"]) ?? stack.last.flatMap { ProjectArchive.seconds($0["start"]) } ?? 0
                        let duration = ProjectArchive.seconds(attributes["duration"]) ?? stack.last.flatMap { ProjectArchive.seconds($0["duration"]) } ?? 0
                        found.append((ref, start, duration, project))
                    }
                }
                stack.append(attributes)
            }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
                stack.removeLast()
                if name == "asset" { asset = nil }
            }
        }
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        var uses: Uses = [:]
        for item in reader.found {
            guard let asset = reader.assets[item.ref], let url = URL(string: asset.src), url.isFileURL else { continue }
            let start = max(item.start - asset.start, 0)
            uses[url.path, default: []].append(Use(start: start, end: start + item.duration, timeline: item.timeline ?? fallback))
        }
        return uses
    }

    /// A file an EDL names: where it is, its frame rate and the timecode it starts at (seconds).
    struct Found: Sendable {
        var path: String
        var fps: Double
        var timecode: Double
    }

    /// The files a CMX 3600 EDL uses: each event's source in and out, by its clip name (or reel),
    /// found with `find`. Names it can't find are in `missing`.
    static func uses(edl text: String, timeline: String, find: (String) -> Found?) -> (uses: Uses, missing: [String]) {
        var uses: Uses = [:], missing: [String] = []
        var event: (reel: String, source: [String])?
        func close() {
            guard let current = event else { return }
            event = nil
            let name = current.reel
            guard let file = find(name) else { if !missing.contains(name) { missing.append(name) }; return }
            guard let a = frames(current.source[0], fps: file.fps), let b = frames(current.source[1], fps: file.fps) else { return }
            let fps = max(file.fps, 1)
            uses[file.path, default: []].append(Use(start: max(a / fps - file.timecode, 0), end: max(b / fps - file.timecode, 0), timeline: timeline))
        }
        var title = timeline
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("TITLE:") { title = line.dropFirst(6).trimmingCharacters(in: .whitespaces); continue }
            if line.hasPrefix("*") {
                for key in ["* FROM CLIP NAME:", "* SOURCE FILE:"] where line.uppercased().hasPrefix(key) {
                    event?.reel = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            let tokens = line.split(separator: " ").map(String.init)
            let codes = tokens.filter { $0.range(of: #"^\d\d:\d\d:\d\d[:;]\d\d$"#, options: .regularExpression) != nil }
            if tokens.count >= 6, Int(tokens[0]) != nil, codes.count >= 4 {
                close()
                event = (tokens[1], Array(codes.prefix(2)))
            }
        }
        close()
        // (Each use is under the EDL's own title when it has one.)
        if title != timeline { for key in uses.keys { uses[key] = uses[key]!.map { Use(start: $0.start, end: $0.end, timeline: title) } } }
        return (uses, missing)
    }

    /// Frames from "01:00:02:12" at a rate (drop-frame counted as non-drop: shortcut, a few frames off an hour in).
    static func frames(_ code: String, fps: Double) -> Double? {
        let parts = code.split(whereSeparator: { $0 == ":" || $0 == ";" }).compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        let base = max(fps.rounded(), 1)
        return ((parts[0] * 60 + parts[1]) * 60 + parts[2]) * base + parts[3]
    }

    /// A Resolve project or timeline file (.drp, .drt: zip files of XML): the media paths in it
    /// that are on this Mac, each whole (the parts used aren't read from these files).
    static func uses(resolveFile url: URL, timeline: String) -> Uses {
        let text = run("/usr/bin/unzip", ["-p", url.path]).output
        guard let pattern = try? NSRegularExpression(pattern: #"/(?:Volumes|Users)/[^<>"\r\n\t]+?\.(?:"# + mediaKinds.sorted().joined(separator: "|") + #")\b"#,
                                                     options: [.caseInsensitive]) else { return [:] }
        var uses: Uses = [:]
        let range = NSRange(text.startIndex..., in: text)
        for match in pattern.matches(in: text, range: range) {
            guard let found = Range(match.range, in: text) else { continue }
            let path = String(text[found])
            if uses[path] == nil, FileManager.default.fileExists(atPath: path) { uses[path] = [Use(start: 0, end: .infinity, timeline: timeline)] }
        }
        return uses
    }

    /// The files a timeline or project file uses, by its kind. EDL names are looked for in `search`.
    static func uses(file url: URL, search: [String], ffprobe: String?) -> (uses: Uses, missing: [String]) {
        let name = url.deletingPathExtension().lastPathComponent
        switch url.pathExtension.lowercased() {
        case "fcpxml", "xml":
            return (uses(fcpxml: (try? Data(contentsOf: url)) ?? Data(), timeline: name), [])
        case "fcpxmld":
            return (uses(fcpxml: (try? Data(contentsOf: url.appendingPathComponent("Info.fcpxml"))) ?? Data(), timeline: name), [])
        case "edl":
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
            var index: [String: String] = [:]
            for folder in search {
                for file in OffloadCenter.files(in: URL(fileURLWithPath: folder)) {
                    let full = (folder as NSString).appendingPathComponent(file.path)
                    let last = (file.path as NSString).lastPathComponent.lowercased()
                    index[last] = index[last] ?? full
                    index[(last as NSString).deletingPathExtension] = index[(last as NSString).deletingPathExtension] ?? full
                }
            }
            return uses(edl: text, timeline: name) { clip in
                let key = clip.lowercased()
                guard let path = index[key] ?? index[(key as NSString).deletingPathExtension] else { return nil }
                let info = ffprobe.map { probe(path, ffprobe: $0) }
                return Found(path: path, fps: info?.fps ?? 25, timecode: info?.timecode ?? 0)
            }
        case "drp", "drt":
            return (uses(resolveFile: url, timeline: name), [])
        default:
            return ([:], [])
        }
    }

    /// The project open in DaVinci Resolve (which must already be running: it's never started):
    /// every timeline's media with the part used, and, into `folder`, the project exported (.drp)
    /// and each timeline as FCPXML, for the archive.
    static func readResolve(into folder: URL) async throws -> Sources {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let answer = try await ResolveBridge.run(["action": "archive", "folder": folder.path], script: ResolveBridge.preamble + resolveScript)
        var sources = Sources(name: answer["project"] as? String ?? "Resolve")
        for item in answer["items"] as? [[String: Any]] ?? [] {
            guard let path = item["path"] as? String, !path.isEmpty else { continue }
            let timeline = item["timeline"] as? String ?? sources.name
            let fps = item["fps"] as? Double ?? 0
            if fps > 0, let a = item["sourceStart"] as? Double, let b = item["sourceEnd"] as? Double {
                sources.uses[path, default: []].append(Use(start: a / fps, end: b / fps, timeline: timeline))
            } else {
                sources.uses[path, default: []].append(Use(start: 0, end: .infinity, timeline: timeline))
            }
        }
        sources.projectFiles = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted().map { (folder.path as NSString).appendingPathComponent($0) }
        sources.resolveCache = (answer["cache"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return sources
    }

    private static let resolveScript = #"""
import os

def safe(name):
    return "".join("-" if c in "/\\:" else c for c in name).strip() or "Timeline"

if action == "archive":
    project = pm.GetCurrentProject()
    if project is None:
        out({"error": "No project is open in DaVinci Resolve."})
    name = project.GetName()
    folder = cmd["folder"]
    items = []
    for index in range(1, project.GetTimelineCount() + 1):
        timeline = project.GetTimelineByIndex(index)
        if timeline is None:
            continue
        tname = timeline.GetName()
        for kind in ("video", "audio"):
            for track in range(1, timeline.GetTrackCount(kind) + 1):
                for i in timeline.GetItemListInTrack(kind, track) or []:
                    clip = i.GetMediaPoolItem()
                    if clip is None:
                        continue
                    path = clip.GetClipProperty("File Path")
                    if not path:
                        continue
                    try:
                        fps = float(str(clip.GetClipProperty("FPS")).split()[0])
                    except Exception:
                        fps = 0.0
                    try:
                        start, end = i.GetSourceStartFrame(), i.GetSourceEndFrame()
                    except Exception:
                        start, end = None, None
                    items.append({"timeline": tname, "path": path, "fps": fps, "sourceStart": start, "sourceEnd": end})
        timeline.Export(os.path.join(folder, safe(tname) + ".fcpxml"), resolve.EXPORT_FCPXML_1_10, resolve.EXPORT_NONE)
    pm.SaveProject()
    pm.ExportProject(name, os.path.join(folder, safe(name) + ".drp"), True)
    settings = project.GetSettings() or {}
    out({"project": name, "items": items, "cache": settings.get("perfCacheClipsLocation", "")})

out({"error": "Unknown action " + action})
"""#

    // MARK: - The plan

    /// Folder all the paths are in.
    static func commonFolder(_ paths: [String]) -> String {
        var parts: [Substring]?
        for path in paths {
            let folder = (path as NSString).deletingLastPathComponent.split(separator: "/")
            guard let current = parts else { parts = folder; continue }
            var n = 0
            while n < current.count, n < folder.count, current[n] == folder[n] { n += 1 }
            parts = Array(current.prefix(n))
        }
        return "/" + (parts ?? []).joined(separator: "/")
    }

    static func relative(_ path: String, to root: String) -> String {
        root == "/" ? String(path.dropFirst()) : String(path.dropFirst(root.count + 1))
    }

    /// What will be archived and what can be cleaned afterwards. Reads the disk: off the main thread.
    /// `trimmed`: long clips only by the part used plus `handles` seconds each side (clips shorter
    /// than `minimumLength`, raw files and ones whose use covers most of them stay whole).
    static func plan(_ sources: Sources, trimmed: Bool, handles: Double = 2, minimumLength: Double = 60, ffprobe: String?) -> Plan {
        let fm = FileManager.default
        func info(_ path: String) -> (size: Int64, modified: Date)? {
            guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { return nil }
            return (Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        let used = sources.uses.keys.sorted()
        let present = used.filter { info($0) != nil }
        let missing = used.filter { info($0) == nil }
        let root = commonFolder(present + (sources.projectFolder.map { [($0 as NSString).appendingPathComponent("x")] } ?? []))
        var items: [Item] = []
        for path in present {
            let (size, modified) = info(path)!
            let uses = sources.uses[path] ?? []
            var item = Item(root: root, relative: relative(path, to: root), into: "Media", size: size, modified: modified, kind: .media,
                            uses: uses, original: path)
            let kind = (path as NSString).pathExtension.lowercased()
            if let ffprobe, trimKinds.contains(kind) || rawKinds.contains(kind) { item.duration = probe(path, ffprobe: ffprobe).duration }
            if trimmed, trimKinds.contains(kind), let duration = item.duration, duration >= minimumLength,
               uses.allSatisfy({ $0.end.isFinite }), let first = uses.map(\.start).min(), let last = uses.map(\.end).max() {
                // shortcut: one piece per file, from the first part used to the last; split into pieces if long gaps waste space.
                let span = max(first - handles, 0)...min(last + handles, duration)
                if span.upperBound - span.lowerBound < duration * 0.8 { item.trim = span }
            }
            items.append(item)
        }
        func folders(_ list: [String], into base: String, kind: Kind) {
            var taken: Set<String> = []
            for folder in list {
                var name = (folder as NSString).lastPathComponent, n = 2
                while !taken.insert(name.lowercased()).inserted { name = "\((folder as NSString).lastPathComponent) \(n)"; n += 1 }
                for file in OffloadCenter.files(in: URL(fileURLWithPath: folder)) {
                    items.append(Item(root: folder, relative: file.path, into: "\(base)/\(name)", size: file.size, modified: file.modified, kind: kind,
                                      original: (folder as NSString).appendingPathComponent(file.path)))
                }
            }
        }
        folders(sources.renders, into: "Renders", kind: .render)
        folders(sources.extras, into: "Extras", kind: .extra)
        for path in sources.projectFiles {
            guard let (size, modified) = info(path) else { continue }
            items.append(Item(root: (path as NSString).deletingLastPathComponent, relative: (path as NSString).lastPathComponent, into: "Project",
                              size: size, modified: modified, kind: .project, original: path))
        }
        // The same file twice (a render folder inside the media's): once, as media.
        var seen: Set<String> = []
        items = items.filter { seen.insert($0.source).inserted }

        var cleanables: [Cleanable] = []
        func size(_ path: String) -> Int64 {
            var isFolder: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isFolder) else { return 0 }
            guard isFolder.boolValue else { return info(path)?.size ?? 0 }
            return OffloadCenter.files(in: URL(fileURLWithPath: path)).reduce(0) { $0 + $1.size }
        }
        for path in present {
            for (cache, label) in [(Stabilizer.copyURL(for: path).path, String(localized: "Steadied copy")),
                                   (playableCopy(of: path, video: true).path, String(localized: "Playable copy")),
                                   (playableCopy(of: path, video: false).path, String(localized: "Playable copy"))]
            where fm.fileExists(atPath: cache) {
                cleanables.append(Cleanable(path: cache, size: size(cache), label: label, suggested: true))
            }
        }
        if let cache = sources.resolveCache {
            for (name, label) in [("CacheClip", String(localized: "Resolve render cache")), ("OptimizedMedia", String(localized: "Resolve optimized media")),
                                  ("ProxyMedia", String(localized: "Resolve proxies"))] {
                let path = (cache as NSString).appendingPathComponent(name)
                if fm.fileExists(atPath: path) { cleanables.append(Cleanable(path: path, size: size(path), label: label, suggested: false)) }
            }
        }
        return Plan(name: FolderTemplate.safe(sources.name).isEmpty ? "Archive" : FolderTemplate.safe(sources.name),
                    items: items, missing: missing, cleanables: cleanables, mediaRoot: root)
    }

    /// Where MediaTools.playableCopy keeps a file's copy (the same name, worked out the same way).
    static func playableCopy(of path: String, video: Bool) -> URL {
        let file = URL(fileURLWithPath: path)
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck/Editor", isDirectory: true)
        let stamp = (try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])).map {
            "\($0.fileSize ?? 0)-\(Int($0.contentModificationDate?.timeIntervalSince1970 ?? 0))"
        } ?? ""
        let name = SHA256.hash(data: Data((file.path + stamp).utf8)).prefix(10).map { String(format: "%02x", $0) }.joined() + (video ? ".mov" : ".m4a")
        return folder.appendingPathComponent(name)
    }

    // MARK: - Getting it ready

    struct Probe: Sendable { var duration: Double?; var fps: Double?; var timecode: Double? }

    /// A file's length, frame rate and starting timecode (seconds), from ffprobe.
    static func probe(_ path: String, ffprobe: String) -> Probe {
        let out = run(ffprobe, ["-v", "error", "-show_entries", "format=duration:format_tags=timecode:stream=codec_type,avg_frame_rate:stream_tags=timecode",
                                "-of", "json", path]).output
        guard let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] else { return Probe() }
        let format = json["format"] as? [String: Any]
        var result = Probe(duration: (format?["duration"] as? String).flatMap(Double.init))
        var code = (format?["tags"] as? [String: Any])?["timecode"] as? String
        for stream in json["streams"] as? [[String: Any]] ?? [] {
            code = code ?? (stream["tags"] as? [String: Any])?["timecode"] as? String
            if stream["codec_type"] as? String == "video", result.fps == nil,
               let rate = (stream["avg_frame_rate"] as? String)?.split(separator: "/").compactMap({ Double($0) }), rate.count == 2, rate[1] > 0 {
                result.fps = rate[0] / rate[1]
            }
        }
        if let code, let frames = frames(code, fps: result.fps ?? 25) { result.timecode = frames / max((result.fps ?? 25).rounded(), 1) }
        return result
    }

    /// Cuts the trimmed clips into `staging` (same layout as Media/), without re-encoding: from the
    /// keyframe at or before the part wanted, with the timecode moved on to match. A clip that
    /// can't be cut that way goes whole. Returns the items, now pointing at the pieces, and notes.
    static func cut(_ items: [Item], into staging: URL, ffmpeg: String, ffprobe: String) -> (items: [Item], notes: [String]) {
        var notes: [String] = []
        let result = items.map { item -> Item in
            guard let trim = item.trim else { return item }
            var piece = item
            let output = staging.appendingPathComponent(item.relative)
            try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let partial = output.deletingLastPathComponent().appendingPathComponent(".cutting-" + output.lastPathComponent)
            // The keyframe at or before the start (ffmpeg cuts stream copies there).
            let keys = run(ffprobe, ["-v", "error", "-select_streams", "v:0", "-skip_frame", "nokey", "-show_entries", "frame=pts_time", "-of", "csv=p=0",
                                     "-read_intervals", "\(max(trim.lowerBound - 30, 0))%\(trim.lowerBound + 0.001)", item.source]).output
            let start = keys.split(whereSeparator: \.isNewline).compactMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: ", \t"))) }
                .filter { $0 <= trim.lowerBound + 0.001 }.max() ?? 0
            let info = probe(item.source, ffprobe: ffprobe)
            var arguments = ["-nostdin", "-y", "-v", "error", "-ss", String(format: "%.6f", start), "-i", item.source,
                             "-t", String(format: "%.6f", trim.upperBound - start), "-map", "0:v?", "-map", "0:a?", "-c", "copy"]
            // (Picture and sound only: the old timecode track would keep the original start; -timecode writes a new one.)
            if let code = info.timecode, let fps = info.fps {
                let total = Int(((code + start) * fps.rounded()).rounded()), rate = Int(max(fps.rounded(), 1))
                arguments += ["-timecode", String(format: "%02d:%02d:%02d:%02d", total / rate / 3600, total / rate / 60 % 60, total / rate % 60, total % rate)]
            }
            // A piece cut on an earlier run is used again (cut anew it might differ, and the copy already
            // archived would then not match it).
            // ...but only if it was cut from the same source and range (a sidecar remembers which).
            let sidecar = output.deletingLastPathComponent().appendingPathComponent(".cut-" + output.lastPathComponent)
            let signature = (arguments + ["\(item.size)", "\(item.modified.timeIntervalSince1970)"]).joined(separator: "\u{1}")
            if (try? String(contentsOf: sidecar, encoding: .utf8)) != signature {
                try? FileManager.default.removeItem(at: output)
                try? FileManager.default.removeItem(at: sidecar)
            }
            if !FileManager.default.fileExists(atPath: output.path) {
                if run(ffmpeg, arguments + ["-f", kind(of: output), partial.path]).status == 0 {
                    try? FileManager.default.moveItem(at: partial, to: output)
                    try? signature.write(to: sidecar, atomically: true, encoding: .utf8)
                }
                try? FileManager.default.removeItem(at: partial)
            }
            guard let values = try? output.resourceValues(forKeys: [.fileSizeKey]), (values.fileSize ?? 0) > 0 else {
                try? FileManager.default.removeItem(at: output)
                notes.append(String(localized: "\((item.relative as NSString).lastPathComponent) couldn’t be cut without re-encoding, so it goes whole."))
                piece.trim = nil
                return piece
            }
            piece.root = staging.path
            piece.size = Int64(values.fileSize ?? 0)
            piece.modified = item.modified
            piece.trim = start...trim.upperBound
            try? FileManager.default.setAttributes([.modificationDate: item.modified], ofItemAtPath: output.path)
            return piece
        }
        return (result, notes)
    }

    /// ffmpeg's name for a file's container (the part file's own name doesn't say).
    private static func kind(of url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mov": "mov"
        case "mp4", "m4v": "mp4"
        case "mxf": "mxf"
        case "mkv": "matroska"
        default: "mpegts"
        }
    }

    /// The Pluck project, pointing at the archived copies (a trimmed clip's times moved to its
    /// piece), as a new project of its own (so it never replaces the original when opened).
    @MainActor static func relinked(_ project: Project, items: [Item], archive: URL) -> Project {
        var copy = project
        // Its own ID, the same on every run (so a run carried on writes the same file).
        let digest = Array(SHA256.hash(data: Data("archive \(project.id.uuidString)".utf8)))
        copy.id = UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                              digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
        let byOriginal = Dictionary(items.filter { $0.kind == .media }.map { ($0.original, $0) }, uniquingKeysWith: { a, _ in a })
        func move(_ clip: inout ProjectClip) {
            guard let item = byOriginal[clip.path] else { return }
            clip.path = archive.appendingPathComponent(item.archived).path
            if let trim = item.trim {
                clip.start -= trim.lowerBound
                clip.end -= trim.lowerBound
                clip.freeze = clip.freeze.map { $0 - trim.lowerBound }
            }
        }
        // Subtitles are kept by file path (and a line's start in that file): follow the clip to its
        // archived copy, with a transcript made for the original written out as lines, times minus the trim.
        var cues: [String: [SubtitleCue]] = [:], rekey: [String: String] = [:]
        for clip in project.clips + (project.tracks ?? []).flatMap(\.items) where cues[clip.path] == nil {
            guard let item = byOriginal[clip.path], clip.freeze == nil else { continue }
            let found = project.fileSubtitles?[clip.path]
                ?? TranscriptStore.find(forFile: clip.path).map { Project.transcriptLines($0, language: project.subtitleLanguage).map { SubtitleCue(start: $0.start, end: $0.end, text: $0.text) } }
            guard let found else { continue }
            let by = item.trim?.lowerBound ?? 0, path = archive.appendingPathComponent(item.archived).path
            cues[clip.path] = found
            // A line's key is its start rounded to 2 places, so map each key rather than re-rounding a shifted one.
            for cue in found { rekey["\(clip.path)|\(String(format: "%.2f", cue.start))"] = "\(path)|\(String(format: "%.2f", cue.start - by))" }
            copy.fileSubtitles = (copy.fileSubtitles ?? [:]).merging([path: found.map { var cue = $0; cue.start -= by; cue.end -= by; return cue }]) { $1 }
        }
        if let edits = project.subtitleEdits {
            copy.subtitleEdits = Dictionary(edits.map { (rekey[$0.key] ?? $0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        }
        for index in copy.clips.indices { move(&copy.clips[index]) }
        for track in (copy.tracks ?? []).indices { for index in copy.tracks![track].items.indices { move(&copy.tracks![track].items[index]) } }
        for index in copy.music.indices {
            guard let item = byOriginal[copy.music[index].path] else { continue }
            copy.music[index].path = archive.appendingPathComponent(item.archived).path
            if let trim = item.trim { copy.music[index].start -= trim.lowerBound; copy.music[index].end -= trim.lowerBound }
        }
        copy.media = copy.media?.map { path in byOriginal[path].map { archive.appendingPathComponent($0.archived).path } ?? path }
        copy.origin = nil
        copy.resolveTimeline = nil
        return copy
    }

    static func writeProject(_ project: Project, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(project).write(to: url, options: .atomic)
    }

    // MARK: - Copying

    /// Offload jobs for the items: one per place they come from and folder they go to, into
    /// `<target>/<name>/…` on every target. `tag` marks them as this archive's.
    static func jobs(_ items: [Item], name: String, targets: [URL], tag: UUID) -> [OffloadJob] {
        let groups = Dictionary(grouping: items) { "\($0.root)\u{0}\($0.into)" }
        return groups.keys.sorted().map { key in
            let group = groups[key]!
            let root = URL(fileURLWithPath: group[0].root)
            var job = OffloadJob(name: "\(name)/\(group[0].into)", source: root.path, sourceVolume: OffloadCenter.volumeName(root),
                                 roots: targets.map(\.path), rootVolumes: targets.map(OffloadCenter.volumeName),
                                 files: group.map { OffloadFile(path: $0.relative, size: $0.size, modified: $0.modified, done: targets.map { _ in false }) })
            job.title = "\(name) · " + group[0].into.replacingOccurrences(of: "/", with: " · ")
            job.backup = tag
            return job
        }
    }

    /// Every file of every job copied and read back the same on every target.
    /// Every one of the `expected` copy jobs is there, finished, and checked (one gone from the queue isn't).
    static func verified(_ jobs: [OffloadJob], expected: Int) -> Bool {
        !jobs.isEmpty && jobs.count == expected && jobs.allSatisfy { job in
            job.finished != nil && job.problems.isEmpty && job.files.allSatisfy { $0.hash != nil && !$0.done.contains(false) }
        }
    }

    // MARK: - The inventory

    struct Entry: Sendable {
        var item: Item
        var hash: String
        var size: Int64
    }

    static func entries(_ items: [Item], jobs: [OffloadJob]) -> [Entry] {
        var hashes: [String: (String, Int64)] = [:]
        for job in jobs {
            for file in job.files { if let hash = file.hash { hashes[(job.source as NSString).appendingPathComponent(file.path)] = (hash, file.size) } }
        }
        return items.compactMap { item in hashes[item.source].map { Entry(item: item, hash: $0.0, size: $0.1) } }
    }

    /// Inventory.csv and Inventory.html in the archive folder.
    static func writeInventory(_ entries: [Entry], name: String, missing: [String], masters: [String: MasterCheck] = [:], in folder: URL) throws {
        func cell(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        func time(_ t: Double?) -> String { t.map { String(format: "%.3f", $0) } ?? "" }
        var csv = "file,kind,size,xxhash64,duration,used_by,kept_from,kept_to,original,master,master_check,original_size,original_xxhash64\n"
        for entry in entries {
            let item = entry.item
            let check = item.master == nil ? nil : masters[item.original]
            csv += [cell(item.archived), item.kind.rawValue, "\(entry.size)", entry.hash, time(item.duration), cell(item.timelines.joined(separator: "; ")),
                    time(item.trim?.lowerBound), time(item.trim?.upperBound), cell(item.original), cell(item.master?.label ?? ""),
                    check.map { cell($0.ok ? "frames, timecode, sound, plays" : $0.problems.joined(separator: "; ")) } ?? "",
                    check.map { "\($0.originalSize)" } ?? "", check?.originalHash ?? ""].joined(separator: ",") + "\n"
        }
        try csv.write(to: folder.appendingPathComponent("Inventory.csv"), atomically: true, encoding: .utf8)

        func html(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let bytes = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        let total = entries.reduce(Int64(0)) { $0 + $1.size }
        var rows = ""
        for entry in entries {
            let item = entry.item
            let length = item.duration.map { Duration.seconds($0).formatted(.time(pattern: .hourMinuteSecond)) } ?? ""
            let kept = item.trim.map { "\(Duration.seconds($0.lowerBound).formatted(.time(pattern: .hourMinuteSecond)))–\(Duration.seconds($0.upperBound).formatted(.time(pattern: .hourMinuteSecond)))" } ?? ""
            rows += "<tr><td>\(html(item.archived))</td><td>\(bytes(entry.size))</td><td>\(length)</td><td>\(kept)</td><td>\(html(item.timelines.joined(separator: ", ")))</td><td><code>\(entry.hash)</code></td></tr>\n"
        }
        let made = masters.values.filter(\.ok)
        let before = made.reduce(Int64(0)) { $0 + $1.originalSize }, after = made.reduce(Int64(0)) { $0 + $1.size }
        let saved = made.isEmpty ? "" : "<p>\(html(String(localized: "Masters: \(made.count) · \(bytes(before)) → \(bytes(after)) · saves \(bytes(before - after)) (\(Int((Double(before - after) / Double(max(before, 1)) * 100).rounded()))%)")))</p>"
        let gone = missing.isEmpty ? "" : "<h2>\(html(String(localized: "Not found")))</h2><ul>" + missing.map { "<li>\(html($0))</li>" }.joined() + "</ul>"
        let page = """
        <!doctype html><html><head><meta charset="utf-8"><title>\(html(name))</title>
        <style>body{font:13px -apple-system,sans-serif;margin:32px;color:#222}h1{font-weight:500}table{border-collapse:collapse;width:100%}
        td,th{text-align:left;padding:4px 8px;border-bottom:1px solid #ddd;vertical-align:top}code{font-size:11px;color:#555}</style></head><body>
        <h1>\(html(name))</h1>
        <p>\(entries.count) · \(bytes(total)) · \(Date.now.formatted(date: .long, time: .shortened)) · xxHash64</p>\(saved)
        <table><tr><th>\(html(String(localized: "File")))</th><th>\(html(String(localized: "Size")))</th><th>\(html(String(localized: "Length")))</th><th>\(html(String(localized: "Kept")))</th><th>\(html(String(localized: "Used in")))</th><th>xxHash64</th></tr>
        \(rows)</table>\(gone)</body></html>
        """
        try page.write(to: folder.appendingPathComponent("Inventory.html"), atomically: true, encoding: .utf8)
    }

    // MARK: - Cleaning up

    /// Moves the chosen caches to the Trash: only after a checked archive, never anything that is
    /// (or holds) a file that was archived. What went, and what didn't and why.
    /// `masters`: originals whose master was checked and archived (original → the master in the
    /// archive); only those originals can go, and only while their master is there.
    static func clean(_ chosen: [Cleanable], plan: Plan, verified: Bool, masters: [String: String] = [:],
                      trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> (moved: [String], kept: [String]) {
        guard verified else { return ([], chosen.map(\.path)) }
        let listed = Set(plan.cleanables.map(\.path))
        let originals = plan.items.map(\.original)
        var moved: [String] = [], kept: [String] = []
        for item in chosen {
            let path = item.path
            let replaced = masters[path].map { FileManager.default.fileExists(atPath: $0) } == true
            guard replaced || listed.contains(path),
                  !originals.contains(where: { ($0 == path && !replaced) || $0.hasPrefix(path + "/") }) else { kept.append(path); continue }
            do { try trash(URL(fileURLWithPath: path)); moved.append(path) } catch { kept.append(path) }
        }
        return (moved, kept)
    }

    // MARK: -

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let result = runData(tool, arguments)
        return (result.status, String(decoding: result.data, as: UTF8.self))
    }

    static func runData(_ tool: String, _ arguments: [String]) -> (status: Int32, data: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (-1, Data()) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}

/// One archive being made: getting the pieces ready, the copies (as Offload jobs, shown on
/// Offload's page too), the check, then the inventory.
@MainActor
@Observable
final class ArchiveRun {
    enum Phase: Equatable { case idle, preparing, copying, paused, done, failed(String) }

    private(set) var phase = Phase.idle
    private(set) var plan: ProjectArchive.Plan?
    private(set) var jobIDs: [UUID] = []
    private(set) var verified = false
    private(set) var notes: [String] = []
    private(set) var folders: [URL] = []
    private(set) var cleaned: [String] = []
    /// Each master made, by its original, and how its check went (as they finish).
    private(set) var masters: [String: ProjectArchive.MasterCheck] = [:]
    /// Masters done of those to make, while making them.
    private(set) var mastering: (done: Int, total: Int)?

    /// Originals that can go: their master checked and archived (only once the whole archive is).
    var replacedOriginals: [ProjectArchive.Cleanable] {
        guard verified, let folder = folders.first else { return [] }
        return masters.values.filter(\.ok).sorted { $0.original < $1.original }.map {
            ProjectArchive.Cleanable(path: $0.original, size: $0.originalSize, label: String(localized: "Original"), suggested: false,
                                     master: folder.appendingPathComponent("Media").appendingPathComponent($0.relative).path)
        }
    }

    var jobs: [OffloadJob] { jobIDs.compactMap { id in OffloadCenter.shared.jobs.first { $0.id == id } } }

    /// 0…1 over every job's work.
    var share: Double {
        let all = jobs
        let work = all.reduce(Int64(0)) { $0 + $1.work }
        guard work > 0 else { return 0 }
        let done = all.reduce(Int64(0)) { $0 + (OffloadCenter.shared.live[$1.id]?.bytes ?? $1.workDone) }
        return Double(done) / Double(work)
    }

    /// Makes the archive of `plan` on every target. `pluck`: the Pluck project, rewritten into Project/.
    /// `settings`: a master for these originals (by path) instead of the original.
    func start(_ plan: ProjectArchive.Plan, pluck: Project?, targets: [URL], ffmpeg: String?, ffprobe: String?,
               settings: [String: ProjectArchive.MasterSettings] = [:],
               open: @escaping @Sendable (URL) throws -> RawSource = { try RawFormats.open($0) }) async {
        phase = .preparing
        verified = false
        notes = []
        cleaned = []
        masters = [:]
        folders = targets.map { $0.appendingPathComponent(plan.name, isDirectory: true) }
        let staging = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/Archive/\(plan.name)", isDirectory: true)
        let settings = settings.filter { $0.value.codec != .original }
        // The masters are made on the first target and then copied, so they take room there twice
        // (their size is about the original's).
        let staged = plan.items.filter { settings[$0.original] != nil && ProjectArchive.masterable($0) }.reduce(Int64(0)) { $0 + $1.size }
        for target in targets {
            if let problem = OffloadCenter.problem(source: URL(fileURLWithPath: plan.mediaRoot), roots: [target], quick: true), plan.items.contains(where: { $0.kind == .media }) {
                phase = .failed(problem); return
            }
            if let free = OffloadCenter.freeSpace(target), free < plan.bytes + (target == targets.first ? staged : 0) {
                phase = .failed(String(localized: "There isn’t enough room on \(OffloadCenter.volumeName(target)).")); return
            }
        }
        // A master replaces the whole original (it isn't trimmed).
        var items = plan.items.map { item in
            var item = item
            if settings[item.original] != nil, ProjectArchive.masterable(item) { item.trim = nil }
            return item
        }
        if !settings.isEmpty, let first = folders.first {
            guard let ffmpeg, let ffprobe else { phase = .failed(String(localized: "Masters need ffmpeg.")); return }
            // On the archive drive, not this Mac's disk (masters of a whole shoot are big).
            let into = first.appendingPathComponent(".Masters", isDirectory: true), pending = items
            mastering = (0, pending.filter { settings[$0.original] != nil && ProjectArchive.masterable($0) }.count)
            let result = await Task.detached(priority: .userInitiated) {
                ProjectArchive.makeMasters(pending, settings: settings, into: into, ffmpeg: ffmpeg, ffprobe: ffprobe, open: open) { check in
                    Task { @MainActor in
                        self.masters[check.original] = check
                        self.mastering = self.mastering.map { ($0.done + 1, $0.total) }
                    }
                }
            }.value
            mastering = nil
            items = result.items
            masters = result.checks
            notes += result.notes
        }
        if items.contains(where: { $0.trim != nil }) {
            guard let ffmpeg, let ffprobe else { phase = .failed(String(localized: "Trimming needs ffmpeg.")); return }
            let media = staging.appendingPathComponent("Media", isDirectory: true), pending = items
            let cut = await Task.detached(priority: .userInitiated) { ProjectArchive.cut(pending, into: media, ffmpeg: ffmpeg, ffprobe: ffprobe) }.value
            items = cut.items
            notes += cut.notes
        }
        if let pluck, let first = folders.first {
            let file = staging.appendingPathComponent("Project/\(FolderTemplate.safe(pluck.name)).pluckproject")
            do {
                try ProjectArchive.writeProject(ProjectArchive.relinked(pluck, items: items, archive: first), to: file)
                let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                items.append(.init(root: file.deletingLastPathComponent().path, relative: file.lastPathComponent, into: "Project",
                                   size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .now, kind: .project, original: file.path))
            } catch {
                phase = .failed(error.localizedDescription); return
            }
        }
        // Each FCPXML again, pointing at the masters (for DaVinci Resolve).
        let checked = masters.values.filter(\.ok)
        if !checked.isEmpty, let first = folders.first {
            for item in items where item.kind == .project && (item.relative as NSString).pathExtension.lowercased() == "fcpxml" {
                guard let text = try? String(contentsOfFile: item.source, encoding: .utf8) else { continue }
                let file = staging.appendingPathComponent("Project/\((item.relative as NSString).deletingPathExtension) (masters).fcpxml")
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard (try? ProjectArchive.masterVersion(ofFCPXML: text, checks: checked, archive: first).write(to: file, atomically: true, encoding: .utf8)) != nil,
                      let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
                items.append(.init(root: file.deletingLastPathComponent().path, relative: file.lastPathComponent, into: "Project",
                                   size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .now, kind: .project, original: file.path))
            }
        }
        var finalPlan = plan
        finalPlan.items = items
        self.plan = finalPlan

        // An earlier run of the same archive that didn't finish: replaced (its copies stay and are
        // checked, not written again; a file cut short carries on).
        let center = OffloadCenter.shared
        let made = ProjectArchive.jobs(items, name: plan.name, targets: targets, tag: UUID())
        for job in made {
            for old in center.jobs where old.backup != nil && old.finished == nil && old.source == job.source && old.targets == job.targets {
                center.remove(old.id)
            }
        }
        jobIDs = made.map(\.id)
        phase = .copying
        for job in made { center.enqueue(job) }
        await wait()
        let jobs = self.jobs
        verified = ProjectArchive.verified(jobs, expected: jobIDs.count)
        if !verified {
            if case .paused = phase { return }
            let problems = jobs.flatMap(\.problems)
            phase = .failed(jobs.count < jobIDs.count ? String(localized: "A copy was removed from the queue before it was checked. Archive again.")
                            : problems.first.map { "\($0.path): \($0.problem ?? "")" } ?? String(localized: "Not every file could be checked."))
            return
        }
        do {
            let entries = ProjectArchive.entries(items, jobs: jobs)
            for folder in folders {
                try ProjectArchive.writeInventory(entries, name: plan.name, missing: plan.missing, masters: masters, in: folder)
                if !checked.isEmpty { try ProjectArchive.writeRelink(Array(checked), in: folder) }
            }
        } catch {
            phase = .failed(error.localizedDescription); return
        }
        try? FileManager.default.removeItem(at: staging)
        if let first = folders.first { try? FileManager.default.removeItem(at: first.appendingPathComponent(".Masters")) }
        phase = .done
    }

    private func wait() async {
        while true {
            let states = jobs.map { OffloadCenter.shared.state($0) }
            if states.count < jobIDs.count { return }
            if states.allSatisfy({ if case .done = $0 { true } else if case .stopped = $0 { true } else { false } }) { return }
            if states.contains(.paused) { phase = .paused; return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    func pause() { for id in jobIDs { OffloadCenter.shared.pause(id) } }

    /// The chosen caches to the Trash (see ProjectArchive.clean).
    func clean(_ chosen: [ProjectArchive.Cleanable], trash: ((URL) throws -> Void)? = nil) -> [String] {
        guard let plan else { return chosen.map(\.path) }
        let replaced = Dictionary(uniqueKeysWithValues: replacedOriginals.compactMap { item in item.master.map { (item.path, $0) } })
        let result = trash.map { ProjectArchive.clean(chosen, plan: plan, verified: verified, masters: replaced, trash: $0) }
            ?? ProjectArchive.clean(chosen, plan: plan, verified: verified, masters: replaced)
        cleaned += result.moved
        return result.kept
    }
}
