import AppKit
import IOKit.pwr_mgt
import Foundation

/// Shrink Folders: old footage (on the NAS) made into checked masters (1080p HEVC 10-bit by
/// default, Archive Project's masters: log kept as log, timecode, reel, frame rate, every sound
/// channel). In place, each master takes its original's place under the same name and the
/// original is moved, on the same drive and never deleted, into one folder at the share's top
/// ("Pluck · Originals to delete/<the same path>"), to delete by hand or put back. Or the masters
/// go to another folder (another NAS) in the same layout, and the originals stay where they are.
enum ShrinkFolders {
    typealias Settings = ProjectArchive.MasterSettings

    static let holdingName = "Pluck · Originals to delete"
    /// Files smaller than this aren't worth it.
    static let minimumSize: Int64 = 200_000_000
    /// A file written to in the last this many seconds is taken as still being written.
    static let quiet: TimeInterval = 600
    /// Codecs worth making a master of even at the same size: intra-frame and raw ones (ffprobe's names).
    static let bigCodecs: Set<String> = ["prores", "prores_raw", "dnxhd", "dnxhr", "cfhd", "rawvideo", "v210", "v410", "r210", "r10k", "ffv1",
                                         "huffyuv", "ffvhuff", "utvideo", "qtrle", "jpeg2000", "mjpeg", "dvvideo", "hqx", "hap", "r3d", "braw"]
    /// A master has to save at least this share of its original.
    static let minimumSaving = 0.3
    /// The tag every master made here carries (so it's never shrunk again).
    static let tag = ["-metadata", "pluck=shrink"]
    /// Caches, proxies and NAS housekeeping, never looked in (lowercased folder names).
    static let skippedFolders: Set<String> = ["#recycle", "@recycle", "@eadir", "#snapshot", "$recycle.bin", ".snapshot", "lost+found"]

    // MARK: Rushes or deliveries

    enum Kind: String, Codable, CaseIterable, Sendable {
        case rushes, deliveries, other
        var label: String {
            switch self {
            case .rushes: String(localized: "Rushes")
            case .deliveries: String(localized: "Deliveries")
            case .other: String(localized: "Other")
            }
        }
    }

    /// Words in folder names (any of Pluck's languages) that say what's inside.
    static let rushWords: Set<String> = ["rushes", "rush", "rushs", "footage", "media", "raw", "camera", "cam", "card", "cards", "dcim", "clip", "clips",
                                         "xdroot", "private", "m4root", "avchd", "acam", "bcam", "ccam", "originals", "beelden", "opnames", "ruw",
                                         "rohmaterial", "aufnahmen", "brutos", "girato", "素材", "撮影素材", "촬영본", "原素材", "brutas"]
    static let deliveryWords: Set<String> = ["export", "exports", "render", "renders", "deliver", "delivery", "deliveries", "deliverable", "deliverables",
                                             "final", "finals", "master", "masters", "output", "outputs", "client", "clients", "upload", "uploads", "social",
                                             "levering", "leveringen", "eindversie", "eindversies", "oplevering", "ausgabe", "lieferung", "finale",
                                             "livraison", "livrables", "entrega", "entregas", "consegna", "書き出し", "納品", "납품", "交付", "成片", "entregáveis"]
    /// Camera file names: A001C003, A001_C003, C0001, DJI_, GoPro, MVI_, IMG_, DSC, PXL_, Panasonic P1000123, CLIP0001.
    static let cameraName = try! NSRegularExpression(pattern: #"^([A-Z]\d{3}_?C\d{3}|C\d{4}|DJI_|G[HXLPS]\d{6}|MVI_|IMG_|DSC|PXL_|P\d{7}$|CLIP\d|MAH\d)"#,
                                                     options: .caseInsensitive)
    /// Programs that make finished films, as they name themselves in a file's tags.
    static let editors = ["davinci resolve", "resolve", "premiere", "media encoder", "adobe", "final cut", "compressor", "com.apple.proapps", "avid", "after effects"]

    /// Rushes, deliveries or other, and why: an editing program's tag, then the nearest folder
    /// whose name says, then a camera's file name, then a camera's tags.
    static func classify(_ path: String, root: String, tags: [String: String]) -> (Kind, String) {
        let tagText = tags.map { "\($0.key) \($0.value)" }.joined(separator: " ").lowercased()
        if let editor = editors.first(where: { tagText.contains($0) }) {
            let value = tags.values.first { $0.lowercased().contains(editor) } ?? editor
            return (.deliveries, String(localized: "Made by \(value)"))
        }
        let below = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : (path as NSString).lastPathComponent
        let folders = [(root as NSString).lastPathComponent] + below.split(separator: "/").dropLast().map(String.init)
        for folder in folders.reversed() {
            let words = folder.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
            let joined = words.joined()
            if words.contains(where: deliveryWords.contains) || deliveryWords.contains(joined) { return (.deliveries, String(localized: "In “\(folder)”")) }
            if words.contains(where: rushWords.contains) || rushWords.contains(joined) { return (.rushes, String(localized: "In “\(folder)”")) }
        }
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        if cameraName.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)) != nil { return (.rushes, String(localized: "Camera file name")) }
        if let camera = tags.first(where: { $0.key.range(of: "make|model|manufacturer|reel_name|camera", options: [.regularExpression, .caseInsensitive]) != nil && !$0.value.isEmpty }) {
            return (.rushes, String(localized: "Camera tag: \(camera.value)"))
        }
        return (.other, String(localized: "Nothing says"))
    }

    /// A file found, and (once in a run) how it went.
    struct File: Codable, Hashable, Identifiable, Sendable {
        /// `elsewhere`: the other Mac of a run on both took it.
        enum State: String, Codable, Sendable { case pending, working, done, skipped, failed, restored, elsewhere }
        var id: String { path }
        var path: String
        /// The chosen folder it was found in.
        var folder: String
        var size: Int64
        var modified: Date
        var seconds = 0.0
        var fps = 0.0
        var width = 0
        var height = 0
        var channels = 0
        var sampleRate = 0
        var kind = Kind.other
        var why = ""
        /// The picture's codec (ffprobe's name; raw: its format).
        var codec = ""
        /// The newest change to any file of its project (the first folder below the chosen one).
        var projectChanged: Date?
        /// Its client, project name and project folder (ShrinkProjects).
        var client = ""
        var projectName = ""
        var project = ""
        /// Why it's left as it is, whatever the settings (nil: it can be shrunk).
        var skip: String?
        /// Other files of the clip that go with it (RED spans, a sidecar).
        var parts: [String] = []
        /// Small files that describe the clip (a camera's XML, XMP, THM, LRF): they stay beside the master, a copy goes with the original.
        var sidecars: [String]?
        /// Its project's own size (Keep 4K), instead of the run's.
        var projectSettings: Settings?
        var state = State.pending
        var note: String?
        var master: String?
        var masterSize: Int64?
        /// Where the original went (nil: it stayed).
        var moved: String?

        /// The master's size, from its length × the settings' bitrate.
        func estimate(_ settings: Settings) -> Int64 {
            let settings = projectSettings ?? settings
            let (w, h) = settings.fit(width, height)
            // Bits per pixel per frame: ProRes 422 HQ is Apple's ~220 Mb/s at 1080p30; HEVC 10-bit by VideoToolbox's quality.
            let bits: Double = settings.codec == .prores ? 3.5 : [Settings.Quality.high: 0.3, .balanced: 0.18, .small: 0.09][settings.quality] ?? 0.3
            let video = Double(w * h) * max(fps, 1) * bits / 8 * seconds
            let audio = Double(channels * max(sampleRate, 48000) * 3) * seconds
            return Int64(video + audio)
        }

        /// Left as it is: a camera's own small codec (H.264, HEVC…) not made smaller in size, or a
        /// master that would save too little.
        func tooSmall(_ settings: Settings) -> Bool {
            let settings = projectSettings ?? settings
            let (w, h) = settings.fit(width, height)
            if !bigCodecs.contains(codec), w == width, h == height { return true }
            return Double(estimate(settings)) > Double(size) * (1 - minimumSaving)
        }

        /// Its project, or itself, changed in the last `months` months (0: any age goes).
        func tooRecent(months: Int, now: Date = .now) -> Bool {
            guard months > 0, let limit = Calendar.current.date(byAdding: .month, value: -months, to: now) else { return false }
            return max(modified, projectChanged ?? modified) > limit
        }
    }

    /// One shrink: its settings, its files, and where the masters went (nil: in place).
    struct Run: Codable, Identifiable, Sendable {
        var id = UUID()
        var date = Date.now
        var settings: Settings
        var files: [File]
        var destination: String?
        var roots: [String] = []
        /// The proxy and cache folders of its projects, by project folder; moved with the originals once a project has masters.
        var proxyFolders: [String: [String]] = [:]
        /// Folders moved: from → to.
        var movedFolders: [String: String] = [:]
        /// Why it stopped by itself (a share nearly full); nil once it carries on.
        var paused: String?
    }

    // MARK: Finding the files

    /// The video files in `folders` (and below; a whole share works too), each probed and sorted
    /// into rushes and deliveries. Hidden files, NAS housekeeping, templates, the originals' folder,
    /// links and packages are left out; links are never followed.
    static func scan(_ folders: [URL], ffprobe: String, minimum: Int64 = minimumSize, quiet: TimeInterval = quiet,
                     raw: Set<String> = ProjectArchive.rawMasterKinds.intersection(RawHelperSource.formats),
                     open: (URL) throws -> RawSource = { try RawFormats.open($0) }, rules: Rules = Rules(),
                     stopped: () -> Bool = { false }, found: (Int) -> Void = { _ in }) -> [File] {
        survey(folders, ffprobe: ffprobe, minimum: minimum, quiet: quiet, raw: raw, open: open, rules: rules, stopped: stopped, found: found).files
    }

    /// The scan with the space report: every file counted into its project (rushes, proxies and
    /// caches, deliveries, other), the videos probed, the big other files listed.
    static func survey(_ folders: [URL], ffprobe: String, minimum: Int64 = minimumSize, quiet: TimeInterval = quiet,
                       raw: Set<String> = ProjectArchive.rawMasterKinds.intersection(RawHelperSource.formats),
                       open: (URL) throws -> RawSource = { try RawFormats.open($0) }, rules: Rules = Rules.load(),
                       stopped: () -> Bool = { false }, found: (Int) -> Void = { _ in }) -> Survey {
        let kinds = ProjectArchive.videoKinds.union(ProjectArchive.rawMasterKinds)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var survey = Survey(folders: folders.map { real($0).path })
        var seen = Set<String>()
        var listed: [String: [String]] = [:]
        func names(_ folder: URL) -> [String] {
            if let known = listed[folder.path] { return known }
            let found = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }
            listed[folder.path] = found
            return found
        }
        func done() -> Survey {
            tally(&survey)
            survey.big = Array(survey.big.sorted { $0.size > $1.size }.prefix(500))
            return survey
        }
        for folder in folders {
            let root = real(folder)
            let share = shareRoot(of: root)
            guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in walk {
                if stopped() { return done() }
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                let name = url.lastPathComponent
                if values.isDirectory == true {
                    let top = url.deletingLastPathComponent().path == share && (name.hasPrefix("_") || name.hasPrefix("#")) && !container(name)
                    if name == holdingName || skippedFolders.contains(name.lowercased()) || template(name) || top { walk.skipDescendants() }
                    continue
                }
                guard values.isSymbolicLink != true, values.isRegularFile == true, seen.insert(url.path).inserted,
                      let place = detect(url.path, share: share, rules: rules) else { continue }
                let size = Int64(values.fileSize ?? 0)
                var project = survey.projects[place.folder] ?? Project(folder: place.folder, client: place.client, name: place.project, share: share)
                defer { survey.projects[place.folder] = project }
                if let date = values.contentModificationDate { project.newest = max(project.newest, date) }
                // Proxies and caches (the first such folder below the project).
                let inside = url.path.hasPrefix(place.folder + "/") ? url.deletingLastPathComponent().path.dropFirst(place.folder.count + 1).split(separator: "/") : []
                if let first = inside.firstIndex(where: { proxyFolder(String($0)) }) {
                    project.proxies += size
                    let proxy = place.folder + "/" + inside[...first].joined(separator: "/")
                    if !project.proxyFolders.contains(proxy) { project.proxyFolders.append(proxy) }
                    continue
                }
                let kind = url.pathExtension.lowercased()
                guard kinds.contains(kind) else {
                    project.loose += size
                    if size >= bigSize { survey.big.append(Big(path: url.path, size: size, project: place.folder, reason: String(localized: "Not video"))) }
                    continue
                }
                // A RED clip is its _001 file (with its other spans and .RMD); the rest go with it.
                let stem = url.deletingPathExtension().lastPathComponent
                if kind == "r3d", stem.range(of: #"_\d{3}$"#, options: .regularExpression) != nil, !stem.hasSuffix("_001") { continue }
                var file = File(path: url.path, folder: root.path, size: size, modified: values.contentModificationDate ?? .distantPast)
                file.client = place.client
                file.projectName = place.project
                file.project = place.folder
                let unit = unit(of: url, names: names(url.deletingLastPathComponent()))
                file.parts = unit.parts
                file.sidecars = unit.sidecars.isEmpty ? nil : unit.sidecars
                file.size += file.parts.reduce(Int64(0)) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1)[.size] as? Int64) ?? 0) }
                var tags: [String: String] = [:]
                if let why = unit.skip {
                    file.skip = why
                    tags = probe(&file, ffprobe: ffprobe, raw: raw.contains(kind), open: open)
                    file.skip = why
                } else if file.size < minimum {
                    file.skip = String(localized: "Small")
                } else if Date.now.timeIntervalSince(file.modified) < quiet {
                    file.skip = String(localized: "Still being written")
                } else if ProjectArchive.rawMasterKinds.contains(kind), !raw.contains(kind) {
                    file.skip = String(localized: "Can’t shrink: this Pluck has no decoder for \(kind.uppercased())")
                    tags = ["camera": "raw"]
                } else {
                    tags = probe(&file, ffprobe: ffprobe, raw: raw.contains(kind), open: open)
                }
                (file.kind, file.why) = classify(file.path, root: root.path, tags: tags)
                survey.files.append(file)
                found(survey.files.count)
            }
        }
        return done()
    }

    /// Small files that describe a clip, by extension.
    static let sidecarKinds: Set<String> = ["xml", "xmp", "thm", "lrf", "rmd", "sidecar", "cif", "cpf", "bim", "ppn", "smi"]
    /// GoPro names: GX01 1234 (chapter 01 of recording 1234), GOPR1234 + GP011234 on older ones.
    static let goPro = try! NSRegularExpression(pattern: #"^(?:G[HXL](\d{2})|GP(\d{2})|GOPR)(\d{4})$"#, options: .caseInsensitive)

    /// A clip that spans files or needs its card's folders: what goes with it (`parts` move with the
    /// original; `sidecars` stay beside the master), or why it's left alone. RED: the _001 file with
    /// its spans (the R3D SDK reads a spanned clip from its first file), the .RDC folder's other files
    /// with it; GoPro chapters, P2 (picture and sound apart), AVCHD and Canon XF clips in several
    /// files are left as they are; Sony XAVC/XDCAM and single-file XF keep their XML beside the master.
    static func unit(of url: URL, names: [String]) -> (skip: String?, parts: [String], sidecars: [String]) {
        let kind = url.pathExtension.lowercased(), stem = url.deletingPathExtension().lastPathComponent, folder = url.deletingLastPathComponent()
        let below = url.path.lowercased().split(separator: "/").map(String.init)
        let videos = names.filter { ProjectArchive.videoKinds.union(ProjectArchive.rawMasterKinds).contains(($0 as NSString).pathExtension.lowercased()) }
        let others = names.filter { $0 != url.lastPathComponent && !videos.contains($0) }.sorted().map { folder.appendingPathComponent($0).path }
        if let contents = below.lastIndex(of: "contents") {
            let inside = below[(contents + 1)...]
            let top = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.deletingLastPathComponent().path)) ?? []).map { $0.lowercased() })
            if inside.count == 2, inside.first == "video" || inside.first == "audio", top.contains("video"), top.contains("audio") {
                return (String(localized: "P2 card: picture and sound are separate files"), [], [])
            }
            if inside.first?.hasPrefix("clips") == true {
                if videos.count > 1 { return (String(localized: "Canon XF clip in \(videos.count) files"), [], []) }
                return (nil, [], others)
            }
        }
        if below.contains("bdmv") || below.contains("avchd") {
            return (String(localized: "AVCHD card: a clip can span files and the card’s index needs them"), [], [])
        }
        let range = NSRange(stem.startIndex..., in: stem)
        if let match = goPro.firstMatch(in: stem, range: range), let number = Range(match.range(at: 3), in: stem) {
            let recording = String(stem[number])
            let chapters = videos.filter { name in
                let base = (name as NSString).deletingPathExtension
                guard let other = goPro.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)), let id = Range(other.range(at: 3), in: base) else { return false }
                return base[id] == recording
            }
            if chapters.count > 1 { return (String(localized: "GoPro recording in \(chapters.count) chapters"), [], []) }
        }
        var parts = parts(of: url, names: names)
        if kind == "r3d", folder.pathExtension.lowercased() == "rdc" {
            // An .RDC folder is one clip: all its files go with it.
            parts = names.filter { $0 != url.lastPathComponent }.sorted().map { folder.appendingPathComponent($0).path }
        }
        if kind == "r3d", stem.hasSuffix("_001") {
            let clip = String(stem.dropLast(4))
            let numbers = names.compactMap { name -> Int? in
                let base = (name as NSString).deletingPathExtension
                guard (name as NSString).pathExtension.lowercased() == "r3d", base.hasPrefix(clip + "_"), base.count == clip.count + 4 else { return nil }
                return Int(base.suffix(3))
            }.sorted()
            if numbers != Array(1...max(numbers.count, 1)) { return (String(localized: "A part of this RED clip is missing"), [], []) }
        }
        let sidecars = names.filter { name in
            guard sidecarKinds.contains((name as NSString).pathExtension.lowercased()), !parts.contains(folder.appendingPathComponent(name).path) else { return false }
            let base = (name as NSString).deletingPathExtension
            if base.lowercased() == stem.lowercased() || (stem.count > 2 && base.uppercased() == "GL" + stem.dropFirst(2).uppercased()) { return true }
            guard base.lowercased().hasPrefix(stem.lowercased()), let next = base.dropFirst(stem.count).first else { return false }
            return next.isLetter || next == "_"
        }.sorted().map { folder.appendingPathComponent($0).path }
        return (nil, parts, sidecars)
    }

    /// A RED clip's other spans and .RMD, a Blackmagic RAW sidecar.
    static func parts(of url: URL, names given: [String]? = nil) -> [String] {
        let kind = url.pathExtension.lowercased(), stem = url.deletingPathExtension().lastPathComponent, folder = url.deletingLastPathComponent()
        guard kind == "r3d" || kind == "braw" else { return [] }
        let names = given ?? (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        if kind == "braw" { return names.filter { $0.lowercased() == stem.lowercased() + ".sidecar" }.map { folder.appendingPathComponent($0).path } }
        guard stem.hasSuffix("_001") else { return [] }
        let clip = String(stem.dropLast(4))
        return names.filter { name in
            let lower = name.lowercased(), base = (name as NSString).deletingPathExtension
            return name != url.lastPathComponent && ((lower.hasSuffix(".r3d") && base.hasPrefix(clip + "_") && base.count == clip.count + 4)
                                                      || lower == clip.lowercased() + ".rmd")
        }.sorted().map { folder.appendingPathComponent($0).path }
    }

    /// Fills in what the file is; returns its tags (file and streams), for sorting it.
    private static func probe(_ file: inout File, ffprobe: String, raw: Bool, open: (URL) throws -> RawSource) -> [String: String] {
        if raw {
            guard let info = ProjectArchive.reference(file.path, ffprobe: ffprobe, count: false, open: open), info.frames > 0 else {
                file.skip = String(localized: "Can’t be read"); return [:]
            }
            (file.seconds, file.fps, file.width, file.height, file.channels) = (info.duration, info.fps, info.width, info.height, info.channels)
            file.codec = (file.path as NSString).pathExtension.lowercased()
            return ["camera": "raw"]
        }
        let out = ProjectArchive.run(ffprobe, ["-v", "error", "-show_entries", "format=duration:format_tags:stream=codec_type,codec_name,width,height,avg_frame_rate,channels,sample_rate:stream_tags",
                                               "-of", "json", file.path]).output
        guard let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] else { file.skip = String(localized: "Can’t be read"); return [:] }
        let format = json["format"] as? [String: Any]
        var tags = (format?["tags"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        if tags["pluck"] == "shrink" { file.skip = String(localized: "Already shrunk") }
        file.seconds = (format?["duration"] as? String).flatMap(Double.init) ?? 0
        for stream in json["streams"] as? [[String: Any]] ?? [] {
            for (key, value) in stream["tags"] as? [String: Any] ?? [:] {
                // (Every stream has a handler name; only the video's says who made it.)
                if let value = value as? String, key != "handler_name" || stream["codec_type"] as? String == "video" { tags[key] = tags[key] ?? value }
            }
            if stream["codec_type"] as? String == "video", file.width == 0 {
                // ProRes RAW goes through ffmpeg's own decoder, when this one can decode it.
                if stream["codec_name"] as? String == "prores_raw" {
                    tags["camera"] = "ProRes RAW"
                    if ProjectArchive.run((ffprobe as NSString).deletingLastPathComponent + "/ffmpeg",
                                          ["-nostdin", "-v", "error", "-i", file.path, "-frames:v", "1", "-f", "null", "-"]).status != 0 {
                        file.skip = String(localized: "Can’t shrink: ProRes RAW can’t be decoded on this Mac")
                    }
                }
                file.codec = stream["codec_name"] as? String ?? ""
                file.width = stream["width"] as? Int ?? 0
                file.height = stream["height"] as? Int ?? 0
                if let rate = (stream["avg_frame_rate"] as? String)?.split(separator: "/").compactMap({ Double($0) }), rate.count == 2, rate[1] > 0 { file.fps = rate[0] / rate[1] }
            } else if stream["codec_type"] as? String == "audio" {
                file.channels += stream["channels"] as? Int ?? 0
                file.sampleRate = max(file.sampleRate, Int(stream["sample_rate"] as? String ?? "") ?? 0)
            }
        }
        if file.skip == nil, file.width == 0 || file.seconds <= 0 { file.skip = String(localized: "No picture") }
        return tags
    }

    // MARK: Where things go

    /// A folder's real path (links resolved, /var as /private/var), as the file system lists what's in it.
    static func real(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    /// The folder the originals of `folder` are moved into: at its share's (drive's) top when
    /// Pluck may write there, else in the chosen folder itself; always on the same drive.
    static func holding(for folder: URL) -> URL {
        let path = folder.path
        if let test = OfficeGroup.testVolumes.first(where: { path == $0.prefix || path.hasPrefix($0.prefix + "/") }) {
            return URL(fileURLWithPath: test.prefix).appendingPathComponent(holdingName, isDirectory: true)
        }
        let volume = (try? folder.resourceValues(forKeys: [.volumeURLKey]))?.volume
        let root = volume.flatMap { $0.path != "/" && FileManager.default.isWritableFile(atPath: $0.path) ? $0 : nil } ?? folder
        return root.appendingPathComponent(holdingName, isDirectory: true)
    }

    /// Where an original goes in the holding folder: its path below the holding folder's parent.
    static func movedPath(_ path: String, holding: URL) -> String {
        let root = holding.deletingLastPathComponent().path
        let relative = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : (path as NSString).lastPathComponent
        return holding.appendingPathComponent(relative).path
    }

    /// In place: the original's own name when it's a .mov, else the same name as a .mov (or,
    /// when that's taken, the whole name with .mov after it).
    static func masterPath(_ path: String) -> String? {
        if (path as NSString).pathExtension.lowercased() == "mov" { return path }
        for name in [(path as NSString).deletingPathExtension + ".mov", path + ".mov"] where !FileManager.default.fileExists(atPath: name) { return name }
        return nil
    }

    /// The top folder each chosen folder gets in a destination: none for one, its own name for
    /// several (numbered when two have the same name).
    static func topFolders(_ roots: [String]) -> [String: String] {
        guard roots.count > 1 else { return Dictionary(uniqueKeysWithValues: roots.map { ($0, "") }) }
        var taken = Set<String>(), result: [String: String] = [:]
        for root in roots {
            let name = (root as NSString).lastPathComponent.isEmpty ? "Share" : (root as NSString).lastPathComponent
            var top = name, number = 2
            while !taken.insert(top.lowercased()).inserted { top = "\(name) \(number)"; number += 1 }
            result[root] = top
        }
        return result
    }

    /// In a destination: the same folders below the chosen one and the same base name, as a .mov.
    static func destinationPath(_ file: File, destination: URL, top: String) -> String {
        let below = file.path.hasPrefix(file.folder + "/") ? String(file.path.dropFirst(file.folder.count + 1)) : (file.path as NSString).lastPathComponent
        let base = top.isEmpty ? destination : destination.appendingPathComponent(top)
        return base.appendingPathComponent((below as NSString).deletingPathExtension + ".mov").path
    }

    /// The master being made, hidden beside where it goes.
    static func temporary(_ master: String) -> String {
        let url = URL(fileURLWithPath: master)
        return url.deletingLastPathComponent().appendingPathComponent(".shrinking-" + url.lastPathComponent).path
    }

    // MARK: Room on the drive

    /// What's kept free on a drive beyond the master: 2 GB or 2% of it, whichever is larger.
    static func headroom(_ capacity: Int64?) -> Int64 { max(2_000_000_000, (capacity ?? 0) / 50) }

    /// Room for this file's master (its estimate × 1.2 and the headroom); a drive that doesn't say has room.
    static func room(for file: File, settings: Settings, free: Int64?, capacity: Int64?) -> Bool {
        guard let free else { return true }
        return free >= Int64(Double(file.estimate(settings)) * 1.2) + headroom(capacity)
    }

    static func capacity(_ url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" { probe.deleteLastPathComponent() }
        return (try? probe.resourceValues(forKeys: [.volumeTotalCapacityKey]))?.volumeTotalCapacity.map(Int64.init)
    }

    /// The bytes in a folder and below (what's waiting in a folder to delete).
    static func bytes(in folder: URL) -> Int64 {
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walk {
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return total
    }

    /// A NAS recycle bin at the share's top (#recycle, .recycle, @Recycle), which keeps deleted files' space.
    static func recycleBin(_ share: String) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: share)) ?? []
        return names.first { ["#recycle", ".recycle", "@recycle"].contains($0.lowercased()) }
    }

    // MARK: Shrinking one file

    /// Is the file as it was when it was found, and not being written?
    static func stillTheSame(_ file: File, quiet: TimeInterval) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else { return String(localized: "Gone") }
        let size = (attributes[.size] as? Int64 ?? 0) + file.parts.reduce(Int64(0)) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1)[.size] as? Int64) ?? 0) }
        if size != file.size || (attributes[.modificationDate] as? Date).map({ abs($0.timeIntervalSince(file.modified)) > 1 }) != false {
            return String(localized: "Changed since it was found")
        }
        if Date.now.timeIntervalSince(file.modified) < quiet { return String(localized: "Still being written") }
        return nil
    }

    /// Open in an app on this Mac (other Macs reading it over the network can't be seen).
    static func openElsewhere(_ path: String) -> Bool {
        ProjectArchive.run("/usr/sbin/lsof", ["-t", "--", path]).output.contains { $0.isNumber }
    }

    /// Makes and checks the master as a hidden file where it goes (`master`: given in a
    /// destination, else beside the original). The file comes back `.working` with where the
    /// master and (in place) the original go, or skipped or failed.
    static func prepare(_ file: File, settings: Settings, holding: URL, master given: String? = nil, ffmpeg: String, ffprobe: String,
                        quiet: TimeInterval = quiet, busy: Set<String> = [], freeSpace: (URL) -> Int64? = { OffloadCenter.freeSpace($0) },
                        capacity: (URL) -> Int64? = { ShrinkFolders.capacity($0) },
                        open: @escaping (URL) throws -> RawSource = { try RawFormats.open($0) }) -> File {
        var file = file
        let settings = file.projectSettings ?? settings
        func skip(_ why: String) -> File { file.state = .skipped; file.note = why; return file }
        func fail(_ why: String) -> File { file.state = .failed; file.note = why; return file }
        if file.kind == .deliveries { return skip(String(localized: "Delivery: never touched")) }
        if let why = stillTheSame(file, quiet: quiet) { return skip(why) }
        if busy.contains(where: { file.path.hasPrefix($0) }) { return skip(String(localized: "Being copied")) }
        if openElsewhere(file.path) { return skip(String(localized: "Open in another app")) }
        guard let master = given ?? masterPath(file.path) else { return fail(String(localized: "A file with the master’s name is already there")) }
        if given != nil, FileManager.default.fileExists(atPath: master) { return skip(String(localized: "Already there")) }
        let folder = URL(fileURLWithPath: master).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: folder.path) else { return fail(String(localized: "Read-only: no permission to write here")) }
        if !room(for: file, settings: settings, free: freeSpace(folder), capacity: capacity(folder)) {
            return fail(String(localized: "Not enough free space for the master"))
        }
        let isRaw = ProjectArchive.rawMasterKinds.contains((file.path as NSString).pathExtension.lowercased())
        guard var original = ProjectArchive.reference(file.path, ffprobe: ffprobe, count: false, open: open) else { return fail(String(localized: "Can’t be read")) }
        // (MXF and the like don't say their frame count in the header: counted then.)
        if original.frames == 0, !isRaw { original = ProjectArchive.streams(file.path, ffprobe: ffprobe) }
        guard original.frames > 0 else { return fail(String(localized: "Can’t be read")) }
        let temp = temporary(master)
        try? FileManager.default.removeItem(atPath: temp)
        do {
            try ProjectArchive.encode(file.path, to: URL(fileURLWithPath: temp), settings: settings, ffmpeg: ffmpeg, ffprobe: ffprobe, metadata: tag, open: open)
        } catch {
            try? FileManager.default.removeItem(atPath: temp)
            return fail(error.localizedDescription)
        }
        let problems = ProjectArchive.verify(temp, against: original, ffmpeg: ffmpeg, ffprobe: ffprobe, source: file.path, open: open)
        let size = Int64((try? FileManager.default.attributesOfItem(atPath: temp)[.size] as? Int64) ?? 0)
        func drop(_ result: File) -> File { try? FileManager.default.removeItem(atPath: temp); return result }
        if !problems.isEmpty { return drop(fail(String(localized: "The master didn’t match: \(problems.joined(separator: ", "))"))) }
        if Double(size) > Double(file.size) * (1 - minimumSaving) { return drop(skip(String(localized: "Would save under 30%"))) }
        if let why = stillTheSame(file, quiet: quiet) { return drop(skip(why)) }
        file.state = .working
        file.masterSize = size
        file.master = master
        file.moved = given == nil ? movedPath(file.path, holding: holding) : nil
        if given == nil, master != file.path { file.note = String(localized: "Now \((master as NSString).lastPathComponent)") }
        return file
    }

    /// Puts a prepared master in place. In place: the original (and its parts) moved into the
    /// holding folder on the same drive, then the master renamed to its name. Also finishes one
    /// stopped halfway (Pluck quit), from what's on the drive.
    static func finish(_ file: File, settings: Settings, inventory: URL? = nil) -> File {
        var file = file
        let fm = FileManager.default
        guard let master = file.master else { file.state = .failed; return file }
        let temp = temporary(master)
        if let moved = file.moved, !fm.fileExists(atPath: moved) {
            guard fm.fileExists(atPath: file.path), fm.fileExists(atPath: temp) else { file.state = .failed; file.note = String(localized: "Gone"); return file }
            if let why = moveOriginal(&file, to: moved) { try? fm.removeItem(atPath: temp); file.state = .failed; file.note = why; return file }
        }
        if fm.fileExists(atPath: temp) {
            do {
                try fm.moveItem(atPath: temp, toPath: master)
                ProjectArchive.copyDates(from: file.moved ?? file.path, to: master, modified: file.modified)
            } catch {
                file.state = .failed; file.note = error.localizedDescription; return file
            }
        }
        guard fm.fileExists(atPath: master) else { file.state = .failed; file.note = String(localized: "The master is gone"); return file }
        // Sidecars: beside the master (copied into a destination), and a copy with the original in the folder to delete.
        let masterFolder = (master as NSString).deletingLastPathComponent
        for sidecar in file.sidecars ?? [] {
            let name = (sidecar as NSString).lastPathComponent
            for folder in [masterFolder, file.moved.map { ($0 as NSString).deletingLastPathComponent }].compactMap({ $0 })
            where folder != (sidecar as NSString).deletingLastPathComponent && !fm.fileExists(atPath: (folder as NSString).appendingPathComponent(name)) {
                try? fm.copyItem(atPath: sidecar, toPath: (folder as NSString).appendingPathComponent(name))
            }
        }
        file.state = .done
        record(file, settings: settings, check: "verified", in: inventory)
        return file
    }

    /// Moves an original (and its parts) to `moved`, a rename on the same drive only: never a
    /// copy and a delete. nil: done; else why not.
    static func moveOriginal(_ file: inout File, to moved: String) -> String? {
        let fm = FileManager.default
        let target = URL(fileURLWithPath: moved).deletingLastPathComponent()
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        guard let here = OffloadCenter.volume(URL(fileURLWithPath: file.path).deletingLastPathComponent()), here.isEqual(OffloadCenter.volume(target)) else {
            return String(localized: "The originals’ folder isn’t on the same drive")
        }
        do { try fm.moveItem(atPath: file.path, toPath: moved) } catch { return error.localizedDescription }
        for part in file.parts { try? fm.moveItem(atPath: part, toPath: (target.path as NSString).appendingPathComponent((part as NSString).lastPathComponent)) }
        file.moved = moved
        return nil
    }

    /// Back as it was: the master to the Trash (or, where the drive has none, into a folder to
    /// delete by hand), the original and its parts moved back if they were moved.
    static func putBack(_ file: File, settings: Settings, inventory: URL? = nil,
                        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> File {
        var file = file
        let fm = FileManager.default
        guard file.state == .done, let master = file.master else { return file }
        if let moved = file.moved, !fm.fileExists(atPath: moved) { file.note = String(localized: "The original isn’t in the originals’ folder"); return file }
        if fm.fileExists(atPath: master) {
            do { try trash(URL(fileURLWithPath: master)) } catch {
                let aside = file.moved.map { URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("Master · " + (master as NSString).lastPathComponent) }
                    ?? URL(fileURLWithPath: master).deletingLastPathComponent().appendingPathComponent(".pluck-removed-" + (master as NSString).lastPathComponent)
                guard (try? fm.moveItem(at: URL(fileURLWithPath: master), to: aside)) != nil else { file.note = error.localizedDescription; return file }
            }
        }
        if let moved = file.moved {
            do {
                try fm.moveItem(atPath: moved, toPath: file.path)
                let folder = (file.path as NSString).deletingLastPathComponent
                for part in file.parts {
                    let from = ((moved as NSString).deletingLastPathComponent as NSString).appendingPathComponent((part as NSString).lastPathComponent)
                    try? fm.moveItem(atPath: from, toPath: (folder as NSString).appendingPathComponent((part as NSString).lastPathComponent))
                }
            } catch { file.note = error.localizedDescription; return file }
        }
        file.state = .restored
        record(file, settings: settings, check: "put back", in: inventory)
        return file
    }

    /// A line in Inventory.csv: the holding folder's (in place) or the destination's.
    static func record(_ file: File, settings: Settings, check: String, in given: URL? = nil) {
        guard let folder = given ?? file.moved.flatMap(holdingFolder(of:)) else { return }
        func cell(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let url = folder.appendingPathComponent("Inventory.csv")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? "date,original,moved_to,master,original_bytes,master_bytes,saved_bytes,settings,size,fps,seconds,channels,kind,check\n".write(to: url, atomically: true, encoding: .utf8)
        }
        let (w, h) = settings.fit(file.width, file.height)
        let line = [ISO8601DateFormatter().string(from: .now), cell(file.path), cell(file.moved ?? ""), cell(file.master ?? ""), "\(file.size)", "\(file.masterSize ?? 0)",
                    "\(file.size - (file.masterSize ?? 0))", cell(settings.label), "\(w)x\(h)", String(format: "%.3f", file.fps), String(format: "%.2f", file.seconds),
                    "\(file.channels)", file.kind.rawValue, check].joined(separator: ",") + "\n"
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    static func holdingFolder(of moved: String) -> URL? {
        var url = URL(fileURLWithPath: moved)
        while url.path != "/" {
            url.deleteLastPathComponent()
            if url.lastPathComponent == holdingName { return url }
        }
        return nil
    }

    /// Stops ffmpeg working on a master (a pause).
    static func stopWork(on master: String) {
        ProjectArchive.run("/usr/bin/pkill", ["-f", NSRegularExpression.escapedPattern(for: temporary(master))])
    }
}


extension ShrinkFolders {
    /// Each project (the first folder below the chosen one) of a run: files, bytes before and after.
    static func projects(_ run: Run) -> [(name: String, files: Int, before: Int64, after: Int64)] {
        var found: [String: (Int, Int64, Int64)] = [:]
        for file in run.files where file.state == .done {
            let name = file.client.isEmpty ? (file.folder as NSString).lastPathComponent : title(client: file.client, project: file.projectName)
            let now = found[name] ?? (0, 0, 0)
            found[name] = (now.0 + 1, now.1 + file.size, now.2 + (file.masterSize ?? 0))
        }
        return found.map { ($0.key, $0.value.0, $0.value.1, $0.value.2) }.sorted { $0.name < $1.name }
    }

    /// Each master made and the original it stands for: old path → new path (the same path when a .mov kept its name).
    static func pathList(_ run: Run) -> [(old: String, new: String)] {
        run.files.compactMap { file in file.state == .done ? file.master.map { (file.path, $0) } : nil }.sorted { $0.old < $1.old }
    }

    /// The run's own inventory, rewritten as it goes: "Shrink <date>.csv" at the top of each folder
    /// its originals went into (or the destination), every file, then the projects' totals.
    static func writeReport(_ run: Run) {
        func cell(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let folders = run.destination.map { [URL(fileURLWithPath: $0)] }
            ?? Array(Set(run.files.compactMap { $0.moved.flatMap(holdingFolder(of:)) }))
        guard !folders.isEmpty else { return }
        let stamp = run.date.formatted(.iso8601.year().month().day().timeSeparator(.omitted).time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
        var csv = "original,moved_to,master,original_bytes,master_bytes,settings,kind,state,note\n"
        for file in run.files where file.state != .pending {
            csv += [cell(file.path), cell(file.moved ?? ""), cell(file.master ?? ""), "\(file.size)", "\(file.masterSize ?? 0)", cell(run.settings.label),
                    file.kind.rawValue, file.state.rawValue, cell(file.note ?? "")].joined(separator: ",") + "\n"
        }
        csv += "\nproject,files,bytes_before,bytes_after,saved\n"
        for project in projects(run) {
            csv += "\(cell(project.name)),\(project.files),\(project.before),\(project.after),\(project.before - project.after)\n"
        }
        // Old path → new path, for relinking (DaVinci Resolve: Relink in Resolve…; anyone else: the list).
        let moves = pathList(run)
        var relink = "old_path,new_path\n"
        for move in moves { relink += "\(cell(move.old)),\(cell(move.new))\n" }
        let json = try? JSONSerialization.data(withJSONObject: moves.map { ["old": $0.old, "new": $0.new] }, options: [.prettyPrinted, .sortedKeys])
        for folder in folders {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? csv.write(to: folder.appendingPathComponent("Shrink \(stamp).csv"), atomically: true, encoding: .utf8)
            guard !moves.isEmpty else { continue }
            try? relink.write(to: folder.appendingPathComponent("Relink \(stamp).csv"), atomically: true, encoding: .utf8)
            try? json?.write(to: folder.appendingPathComponent("Relink \(stamp).json"), options: .atomic)
        }
    }
}

/// The shrinks, kept on disk so a run carries on after Pluck quits: one file at a time. Each file
/// is claimed first (a claim file beside its master, as the office group's proxies do), so two
/// Macs on one run never make the same master.
@MainActor
@Observable
final class ShrinkCenter {
    static let shared = ShrinkCenter()

    private(set) var runs: [ShrinkFolders.Run] = []
    /// The run being worked through, and the master being made now.
    private(set) var active: UUID?
    private(set) var current: String?
    private var stopping = false
    /// Bytes of originals done and seconds spent in this go (for the time left).
    private var pace: (bytes: Int64, seconds: Double) = (0, 0)
    @ObservationIgnored private var awake: IOPMAssertionID?
    let store: URL
    /// This Mac's name in claims.
    let mac: String
    /// Seconds a file must have been left alone (tests: 0).
    var quiet = ShrinkFolders.quiet
    /// Free space where a master goes (tests replace it).
    var freeSpace: @Sendable (URL) -> Int64? = { OffloadCenter.freeSpace($0) }
    /// The size of the drive a master goes on (tests replace it).
    var capacity: @Sendable (URL) -> Int64? = { ShrinkFolders.capacity($0) }
    /// Where a master goes when a run is put back (tests: a folder of their own).
    var trash: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    /// Keep this Mac awake while a run goes (Run overnight).
    var keepAwake = false
    /// Asked after each file of a run that's partly on the always-on Mac (ShrinkRemote fills it).
    var onFile: ((UUID) -> Void)?
    /// Someone is editing from the share a folder is on (tests replace it).
    var editing: @MainActor (String) async -> Bool = { await ShrinkCenter.editingNow($0) }
    /// The Mac that asked (a run shared with it) says someone is editing there.
    var held = false
    /// How long nothing may be edited before a run paused for it carries on, and how often it looks.
    var editQuiet: TimeInterval = 300
    var editCheck: TimeInterval = 20
    /// Run while editing too (until the run stops).
    var runAnyway = false
    /// Waiting because someone is editing.
    private(set) var waitingForEdit = false
    private var interrupted = false

    init(store: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck/Shrink/runs.json"),
         mac: String = Host.current().localizedName ?? "Mac") {
        self.store = store
        self.mac = mac
        load()
    }

    func load() {
        runs = (try? JSONDecoder().decode([ShrinkFolders.Run].self, from: Data(contentsOf: store))) ?? []
    }

    private func save() {
        try? FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(runs).write(to: store, options: .atomic)
    }

    var running: Bool { active != nil }

    func run(_ id: UUID) -> ShrinkFolders.Run? { runs.first { $0.id == id } }

    /// A run with files still to do (paused, or Pluck quit).
    func unfinished(_ run: ShrinkFolders.Run) -> Bool { run.files.contains { $0.state == .pending || $0.state == .working } }

    /// Seconds left for the active run, once one file is done.
    var timeLeft: Double? {
        guard let id = active, let run = run(id), pace.bytes > 0 else { return nil }
        let left = run.files.filter { $0.state == .pending || $0.state == .working }.reduce(Int64(0)) { $0 + $1.size }
        return Double(left) / (Double(pace.bytes) / max(pace.seconds, 1))
    }

    /// Adds a run of these files (`destination`: masters there, originals left; nil: in place).
    @discardableResult
    func add(_ files: [ShrinkFolders.File], settings: ShrinkFolders.Settings, destination: URL? = nil, roots: [String], id: UUID = UUID(),
             proxies: [String: [String]] = [:]) -> UUID {
        var run = ShrinkFolders.Run(settings: settings, files: files.map { var file = $0; file.state = .pending; file.note = nil; return file })
        run.id = id
        run.destination = destination?.path
        run.roots = roots.map { ShrinkFolders.real(URL(fileURLWithPath: $0)).path }
        run.proxyFolders = destination == nil ? proxies : [:]
        runs.insert(run, at: 0)
        save()
        return id
    }

    /// Starts a run and works through it.
    @discardableResult
    func start(_ files: [ShrinkFolders.File], settings: ShrinkFolders.Settings, destination: URL? = nil, roots: [String],
               ffmpeg: String, ffprobe: String) async -> UUID {
        let id = add(files, settings: settings, destination: destination, roots: roots)
        await resume(id, ffmpeg: ffmpeg, ffprobe: ffprobe)
        return id
    }

    /// Works through a run's files still to do, one at a time, until done or paused.
    func resume(_ id: UUID, ffmpeg: String, ffprobe: String) async {
        guard active == nil else { return }
        active = id
        stopping = false
        pace = (0, 0)
        holdAwake(true)
        defer { active = nil; current = nil; holdAwake(false); if let run = run(id) { ShrinkFolders.writeReport(run) } }
        defer { if !stopping { moveProxies(id) } }
        if let r = runs.firstIndex(where: { $0.id == id }), runs[r].paused != nil { runs[r].paused = nil; save() }
        while !stopping, let r = runs.firstIndex(where: { $0.id == id }), let f = next(runs[r]) {
            let run = runs[r], settings = run.settings, quiet = quiet, freeSpace = freeSpace, capacity = capacity, mac = mac
            let destination = run.destination.map { URL(fileURLWithPath: $0) }
            var file = run.files[f]
            let began = Date.now
            let given = destination.map { ShrinkFolders.destinationPath(file, destination: $0, top: ShrinkFolders.topFolders(run.roots)[file.folder] ?? "") }
            let target = file.master ?? given ?? ShrinkFolders.masterPath(file.path) ?? file.path
            if file.state != .working {
                // A drive nearly full: the run pauses (the file stays to do) instead of failing files.
                let folder = existing(URL(fileURLWithPath: target).deletingLastPathComponent())
                if !ShrinkFolders.room(for: file, settings: file.projectSettings ?? settings, free: freeSpace(folder), capacity: capacity(folder)) {
                    let name = destination?.lastPathComponent ?? (ShrinkFolders.shareRoot(of: URL(fileURLWithPath: file.folder)) as NSString).lastPathComponent
                    runs[r].paused = String(localized: "\(name) is nearly full: delete what’s waiting in Originals to delete, or archive to another folder or NAS")
                    save()
                    break
                }
                await waitForQuiet(file.folder)
                if stopping { break }
            }
            let claimed = await Task.detached { () -> (OfficeGroup.Claim?, String?) in
                let url = URL(fileURLWithPath: target)
                if let claim = OfficeGroup.claim(url, mac: mac) { return (claim, nil) }
                guard let holder = OfficeGroup.holder(OfficeGroup.claimURL(url)) else { return (nil, nil) }
                // This Mac's own, left by a quit: taken back.
                if holder.mac == mac { unlink(OfficeGroup.claimURL(url).path); return (OfficeGroup.claim(url, mac: mac), nil) }
                return (nil, holder.mac)
            }.value
            if let other = claimed.1 {
                // The other Mac of this run has it.
                file.state = .elsewhere
                file.note = other
                set(file, in: id)
                continue
            }
            // (No claim and no one else's: the folder can't be written to, which prepare says.)
            let claim = claimed.0
            let renewing = Task.detached {
                while !Task.isCancelled, let claim {
                    try? await Task.sleep(for: .seconds(OfficeGroup.claimRenewal))
                    if !Task.isCancelled { OfficeGroup.renew(claim) }
                }
            }
            defer { renewing.cancel(); if let claim { OfficeGroup.release(claim) } }
            if file.state == .working {
                // Stopped halfway through putting the master in place: finished from what's there.
                file = await Task.detached { ShrinkFolders.finish(file, settings: settings, inventory: destination) }.value
            } else {
                interrupted = false
                let folder = file.folder
                let watch = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(editCheck))
                        if !Task.isCancelled, !runAnyway, await editing(folder) { interrupted = true; ShrinkFolders.stopWork(on: target); return }
                    }
                }
                defer { watch.cancel() }
                let busy = Set(OffloadCenter.shared.jobs.filter { $0.finished == nil && $0.running == true }.map(\.source))
                let holding = ShrinkFolders.holding(for: URL(fileURLWithPath: file.folder))
                current = target
                let made = await Task.detached {
                    ShrinkFolders.prepare(file, settings: settings, holding: holding, master: given, ffmpeg: ffmpeg, ffprobe: ffprobe, quiet: quiet, busy: busy,
                                          freeSpace: freeSpace, capacity: capacity)
                }.value
                watch.cancel()
                if stopping || interrupted {
                    // (Paused for editing: the file is made again once it's quiet.)
                    try? FileManager.default.removeItem(atPath: ShrinkFolders.temporary(target))
                    if stopping { break }
                    continue
                }
                file = made
                if file.state == .working {
                    // Saved before anything moves, so a quit in between is picked up again.
                    set(file, in: id)
                    file = await Task.detached { ShrinkFolders.finish(file, settings: settings, inventory: destination) }.value
                }
            }
            if file.state == .done { pace = (pace.bytes + file.size, pace.seconds + Date.now.timeIntervalSince(began)) }
            set(file, in: id)
            if let r = runs.firstIndex(where: { $0.id == id }) { ShrinkFolders.writeReport(runs[r]) }
            onFile?(id)
        }
    }

    /// The nearest folder that's there (a destination's folders are made as masters go in).
    private nonisolated func existing(_ url: URL) -> URL {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" { probe.deleteLastPathComponent() }
        return probe
    }

    /// The next file: one stopped halfway first; then in order, unless the drive can't hold every master
    /// still to make, when those whose originals are largest next to their master go first (most freed per byte written).
    private func next(_ run: ShrinkFolders.Run) -> Int? {
        if let working = run.files.firstIndex(where: { $0.state == .working }) { return working }
        let pending = run.files.indices.filter { run.files[$0].state == .pending }
        guard let first = pending.first, pending.count > 1 else { return pending.first }
        let folder = existing(URL(fileURLWithPath: run.destination ?? (run.files[first].path as NSString).deletingLastPathComponent))
        guard let free = freeSpace(folder) else { return first }
        func estimate(_ index: Int) -> Double { Double(max(run.files[index].estimate(run.settings), 1)) }
        let need = pending.reduce(0.0) { $0 + estimate($1) * 1.2 } + Double(ShrinkFolders.headroom(capacity(folder)))
        if Double(free) >= need { return first }
        return pending.max { Double(run.files[$0].size) / estimate($0) < Double(run.files[$1].size) / estimate($1) }
    }

    /// Waits while someone edits from the folder's share, then until it's been quiet for `editQuiet`.
    private func waitForQuiet(_ folder: String) async {
        var quietSince: Date?
        while !stopping, !runAnyway {
            if await editing(folder) {
                quietSince = nil
                waitingForEdit = true
            } else if !waitingForEdit {
                return
            } else {
                let since = quietSince ?? .now
                quietSince = since
                if Date.now.timeIntervalSince(since) >= editQuiet { break }
            }
            try? await Task.sleep(for: .seconds(min(5, max(editCheck / 4, 0.2))))
        }
        waitingForEdit = false
    }

    /// DaVinci Resolve in front, or reading files on that share; Edit Anywhere making proxies or
    /// rendering; a copy (Offload, Deliver) going.
    static func editingNow(_ folder: String) async -> Bool {
        if ShrinkCenter.shared.held || OfficeProxies.shared.working != nil || RemoteProxyJobs.shared.working != nil || OfficeRenderServer.shared.isRendering
            || OffloadCenter.shared.jobs.contains(where: { $0.finished == nil && $0.running == true }) { return true }
        guard let resolve = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier?.hasPrefix("com.blackmagic-design.DaVinciResolve") == true })
        else { return false }
        if resolve.isActive { return true }
        let pid = resolve.processIdentifier
        return await Task.detached {
            guard let volume = (try? URL(fileURLWithPath: folder).resourceValues(forKeys: [.volumeURLKey]))?.volume?.path, volume != "/" else { return false }
            return ProjectArchive.run("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-Fn"]).output
                .split(separator: "\n").contains { $0.hasPrefix("n" + volume + "/") }
        }.value
    }

    /// Once a run is through: the proxy and cache folders of each project with a master made moved
    /// into the folder to delete, at their share path (renamed on the same drive).
    private func moveProxies(_ id: UUID) {
        guard let r = runs.firstIndex(where: { $0.id == id }), !unfinished(runs[r]) else { return }
        let projects = Set(runs[r].files.filter { $0.state == .done && $0.moved != nil }.map(\.project))
        for project in projects {
            for folder in runs[r].proxyFolders[project] ?? [] where runs[r].movedFolders[folder] == nil && FileManager.default.fileExists(atPath: folder) {
                guard let file = runs[r].files.first(where: { $0.project == project }) else { continue }
                var holder = ShrinkFolders.File(path: folder, folder: file.folder, size: 0, modified: .now)
                let target = ShrinkFolders.movedPath(folder, holding: ShrinkFolders.holding(for: URL(fileURLWithPath: file.folder)))
                if ShrinkFolders.moveOriginal(&holder, to: target) == nil { runs[r].movedFolders[folder] = target }
            }
        }
        save()
    }

    /// Stops after the file now (the master being made is stopped and dropped).
    func pause() {
        stopping = true
        runAnyway = false
        if let current { ShrinkFolders.stopWork(on: current) }
    }

    private func holdAwake(_ on: Bool) {
        if on, keepAwake, awake == nil {
            var id = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "Pluck is shrinking folders" as CFString, &id) == kIOReturnSuccess { awake = id }
        } else if !on, let id = awake {
            IOPMAssertionRelease(id)
            awake = nil
        }
    }

    /// Whether a run can still be undone: its masters there and (in place) its originals in their folder.
    func canPutBack(_ run: ShrinkFolders.Run) -> Bool {
        run.files.contains { file in
            file.state == .done && (file.moved ?? file.master).map { FileManager.default.fileExists(atPath: $0) } == true
        }
    }

    /// Masters made into another folder whose originals are still where they were.
    func readyToDelete(_ run: ShrinkFolders.Run) -> [ShrinkFolders.File] {
        run.destination == nil ? [] : run.files.filter { $0.state == .done && $0.moved == nil && FileManager.default.fileExists(atPath: $0.path) }
    }

    func putBack(_ id: UUID) async {
        guard active == nil, let run = run(id) else { return }
        active = id
        defer { active = nil; if let run = self.run(id) { ShrinkFolders.writeReport(run) } }
        let settings = run.settings, inventory = run.destination.map { URL(fileURLWithPath: $0) }, trash = trash
        for (from, to) in run.movedFolders where FileManager.default.fileExists(atPath: to) && !FileManager.default.fileExists(atPath: from) {
            if (try? FileManager.default.moveItem(atPath: to, toPath: from)) != nil, let r = runs.firstIndex(where: { $0.id == id }) { runs[r].movedFolders[from] = nil }
        }
        for file in run.files where file.state == .done {
            set(await Task.detached { ShrinkFolders.putBack(file, settings: settings, inventory: inventory, trash: trash) }.value, in: id)
        }
    }

    /// A destination run's checked originals, moved into their share's folder to delete (where Pluck may write).
    @discardableResult
    func moveOriginals(_ id: UUID) async -> [String] {
        guard active == nil, let run = run(id) else { return [] }
        active = id
        defer { active = nil; if let run = self.run(id) { ShrinkFolders.writeReport(run) } }
        var problems: [String] = []
        let settings = run.settings
        for file in readyToDelete(run) {
            let holding = ShrinkFolders.holding(for: URL(fileURLWithPath: file.folder))
            let moved: ShrinkFolders.File = await Task.detached {
                var file = file
                if let why = ShrinkFolders.moveOriginal(&file, to: ShrinkFolders.movedPath(file.path, holding: holding)) { file.note = why }
                else { ShrinkFolders.record(file, settings: settings, check: "original moved") }
                return file
            }.value
            if moved.moved == nil { problems.append("\((file.path as NSString).lastPathComponent): \(moved.note ?? "")") }
            set(moved, in: id)
        }
        return problems
    }

    func remove(_ id: UUID) {
        guard active != id else { return }
        runs.removeAll { $0.id == id }
        save()
    }

    /// Changes a file of a run (the always-on Mac's results come in through here).
    func set(_ file: ShrinkFolders.File, in id: UUID) {
        guard let r = runs.firstIndex(where: { $0.id == id }), let f = runs[r].files.firstIndex(where: { $0.path == file.path }) else { return }
        runs[r].files[f] = file
        save()
    }
}
