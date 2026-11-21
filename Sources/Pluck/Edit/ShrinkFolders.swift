import AppKit
import CryptoKit
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
        /// The hidden master being made (its name has this Mac's claim in it, so no other Mac's is ever touched).
        var temp: String?
        /// The original's frames and length, the original's first and last MB (SHA-256), and the master's
        /// xxHash64 read back from the drive once it's checked: what Check Before Deleting compares.
        var frames: Int?
        var duration: Double?
        var originalHead: String?
        var masterHash: String?
        /// Check Before Deleting: when, and what it found (empty: its original is safe to delete).
        var checked: Date?
        var checkProblems: [String]?
        /// Put Back couldn't finish: why (shown in the history).
        var problem: String?
        /// The master as it was when it was checked (size, date, file number): "safe" holds only while it still is.
        var masterStamp: Stamp?

        /// The check passed (as it was then; `safeNow` looks at the master now).
        var safeToDelete: Bool { state == .done && checked != nil && checkProblems?.isEmpty == true }

        /// Safe to delete its original now: checked in the last week, passed, and the master is still the one checked.
        func safeNow(_ now: Date = .now) -> Bool { notSafe(now) == nil && safeToDelete && now.timeIntervalSince(checked ?? .distantPast) < ShrinkFolders.checkValid }

        /// Why its original isn't safe to delete (nil: safe, or not checked yet).
        func notSafe(_ now: Date = .now) -> String? {
            if state == .working, let problem { return problem }
            guard state == .done, checked != nil else { return nil }
            if let found = checkProblems, !found.isEmpty { return found.joined(separator: ", ") }
            if checkProblems == nil { return nil }
            guard let master, let stamp = masterStamp, ShrinkFolders.stamp(master) == stamp else {
                return String(localized: "Not safe: the master changed since it was checked")
            }
            return nil
        }

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
        /// Why it stopped by itself (a share nearly full, a share not mounted); nil once it carries on.
        var paused: String?
        /// Each share it touches (by its path here) as a NAS place ("remount\npath", empty on a disk of this Mac's own),
        /// so a share mounted elsewhere next time is found there.
        var shares: [String: String]?
        /// Proxy folders left where they are, and why (and a share that couldn't be marked).
        var proxyNotes: [String: String]?
        /// Each share's identity when the run began (its .pluck-share-id, or the drive's volume UUID).
        var shareIDs: [String: String]?
        /// When Relink in Resolve pointed projects at its masters (Put Back then offers the way back).
        var relinked: Date?
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
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        var survey = Survey(folders: folders.map { real($0).path })
        var seen = Set<String>()
        var listed: [String: [String]] = [:]
        func all(_ folder: URL) -> [String] {
            if let known = listed[folder.path] { return known }
            let found = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            listed[folder.path] = found
            return found
        }
        func names(_ folder: URL) -> [String] { all(folder).filter { !$0.hasPrefix(".") } }
        func done() -> Survey {
            tally(&survey)
            survey.big = Array(survey.big.sorted { $0.size > $1.size }.prefix(500))
            return survey
        }
        for folder in folders {
            let root = real(folder)
            let share = shareRoot(of: root)
            if pluckOutput(all(root)) { continue }
            guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                            options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in walk {
                if stopped() { return done() }
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                let name = url.lastPathComponent
                if values.isDirectory == true {
                    let top = url.deletingLastPathComponent().path == share && (name.hasPrefix("_") || name.hasPrefix("#")) && !container(name)
                    // Packages aren't looked in, except RED's .RDC clip folders (a package when Finder shows them as one item).
                    let package = values.isPackage == true && url.pathExtension.lowercased() != "rdc"
                    if name == holdingName || name.lowercased().contains("to delete") || skippedFolders.contains(name.lowercased()) || template(name) || top || package
                        || pluckOutput(all(url)) { walk.skipDescendants() }
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

    /// A folder Pluck made of masters (Archive Project's archive and its Media, a destination of Shrink
    /// Folders): its inventories, relink lists or master notes say so. Never looked in.
    static func pluckOutput(_ names: [String]) -> Bool {
        names.contains { name in
            ["Relink.csv", "Inventory.csv"].contains(name) || name.hasPrefix(".master-of-") || report(name)
        }
    }

    /// One of Pluck's own lists: "Shrink|Relink|Pluck Inventory <date>….csv|json".
    static func report(_ name: String) -> Bool {
        name.range(of: #"^(Shrink|Relink|Pluck Inventory) \d[^/]*\.(csv|json)$"#, options: .regularExpression) != nil
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
        if tags["pluck"] == "master" { file.skip = String(localized: "Already a master") }
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

    /// In place: the original's own name when it's a .mov, else the same name as a .mov (nil: that's taken).
    static func masterPath(_ path: String) -> String? {
        if (path as NSString).pathExtension.lowercased() == "mov" { return path }
        // (Never a made-up name: a clip there already means the file is left as it is.)
        let name = (path as NSString).deletingPathExtension + ".mov"
        return FileManager.default.fileExists(atPath: name) ? nil : name
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

    /// The master being made, hidden beside where it goes (`token`: this Mac's claim, so it's never another Mac's).
    static func temporary(_ master: String, token: String? = nil) -> String {
        let url = URL(fileURLWithPath: master)
        return url.deletingLastPathComponent().appendingPathComponent(".shrinking-" + (token.map { $0 + "-" } ?? "") + url.lastPathComponent).path
    }

    // MARK: Moving, never copying

    /// Renamed on the same drive, never over anything that's there and never as a copy and a delete. nil: done; else why.
    static func rename(_ from: String, _ to: String) -> String? {
        try? FileManager.default.createDirectory(atPath: (to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var before = stat()
        let known = lstat(from, &before) == 0
        if exclusiveRename(from, to) == 0 { return nil }
        var code = errno
        // (A server can say a rename failed that it did: both ends looked at before anything is undone.)
        var gone = stat(), there = stat()
        if known, code != EEXIST, lstat(from, &gone) != 0, lstat(to, &there) == 0, there.st_ino == before.st_ino { return nil }
        if code == ENOTSUP || code == EINVAL {
            // (A drive without an exclusive rename, as some SMB servers: the name taken first with an exclusive
            // create, which only one Mac can win, then renamed over; only that placeholder is ever removed.)
            var info = stat()
            let folder = lstat(from, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
            let made: Bool
            if folder { made = mkdir(to, 0o700) == 0 } else {
                let handle = Darwin.open(to, O_CREAT | O_EXCL | O_WRONLY, 0o600)
                made = handle >= 0
                if made { close(handle) }
            }
            // (Marked as Pluck's own placeholder, so one left by a quit is known and removed.)
            if made { setxattr(to, placeholderMark, "1", 1, 0, 0) }
            if !made { code = errno } else {
                var mine = stat()
                _ = lstat(to, &mine)
                if Darwin.rename(from, to) == 0 { return nil }
                code = errno
                var now = stat()
                if lstat(to, &now) == 0, now.st_ino == mine.st_ino { if folder { rmdir(to) } else { unlink(to) } }
            }
        }
        return "\((from as NSString).lastPathComponent): " + NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription
    }

    static let placeholderMark = "com.pluck.placeholder"

    /// An empty placeholder Pluck made for a rename (and never got to rename over).
    static func placeholder(_ path: String) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64) == 0 && getxattr(path, placeholderMark, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// The exclusive rename (self-tests stand in a drive without one).
    nonisolated(unsafe) static var exclusiveRename: (String, String) -> Int32 = { renamex_np($0, $1, UInt32(RENAME_EXCL)) }

    /// Several files moved as one: all or none (the ones that moved go back when one can't). nil: done; else why.
    static func moveAll(_ moves: [(String, String)]) -> String? { (try? movingAll(moves, between: {})) ?? nil }

    static func movingAll(_ moves: [(String, String)], between: () throws -> Void) throws -> String? {
        var moved: [(String, String)] = []
        for (from, to) in moves {
            if !moved.isEmpty { try between() }
            if let why = rename(from, to) {
                let stuck = moved.reversed().filter { rename($0.1, $0.0) != nil }.map { ($0.1 as NSString).lastPathComponent }
                return stuck.isEmpty ? why : why + " · " + String(localized: "Couldn’t move back: \(stuck.joined(separator: ", "))")
            }
            moved.append((from, to))
        }
        return nil
    }

    /// Written to the drive for good: F_FULLFSYNC, or fsync where the drive hasn't it. false: neither worked.
    static func flushNow(_ path: String) -> Bool {
        let handle = Darwin.open(path, O_RDONLY)
        guard handle >= 0 else { return false }
        defer { close(handle) }
        return fcntl(handle, F_FULLFSYNC) == 0 || fsync(handle) == 0
    }

    /// (Self-tests stand in a drive that can't.)
    nonisolated(unsafe) static var flush: (String) -> Bool = { flushNow($0) }

    /// This Mac's cached pages of a file dropped (mapped and msync'd with MS_INVALIDATE), so the next read comes from the drive.
    @discardableResult
    static func dropCache(_ path: String) -> Bool {
        let handle = Darwin.open(path, O_RDONLY)
        guard handle >= 0 else { return false }
        defer { close(handle) }
        var info = stat()
        guard fstat(handle, &info) == 0 else { return false }
        let length = Int(info.st_size)
        guard length > 0 else { return true }
        guard let map = mmap(nil, length, PROT_READ, MAP_SHARED, handle, 0), map != MAP_FAILED else { return false }
        defer { munmap(map, length) }
        guard msync(map, length, MS_INVALIDATE) == 0 else { return false }
        // On a network share: none of its pages may still be held here.
        guard (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == false else { return true }
        let page = Int(getpagesize())
        var resident = [CChar](repeating: 0, count: (length + page - 1) / page)
        guard mincore(map, length, &resident) == 0 else { return true }
        return !resident.contains { $0 & CChar(MINCORE_INCORE) != 0 }
    }

    /// xxHash64 of a file (`cached` false: read around this Mac's cache, no read-ahead).
    static func xxhash(_ path: String, cached: Bool) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        if !cached {
            _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
            _ = fcntl(handle.fileDescriptor, F_RDAHEAD, 0)
        }
        var xxh = XXH64()
        while true {
            let data: Data?
            do { data = try handle.read(upToCount: 8 << 20) } catch { return nil }
            guard let data, !data.isEmpty else { break }
            data.withUnsafeBytes { xxh.update($0) }
        }
        return String(format: "%016llx", xxh.digest())
    }

    /// Dropping a file's cache (self-tests stand in one that can't).
    nonisolated(unsafe) static var dropping: (String) -> Bool = { dropCache($0) }

    /// The two reads of a master's checksum (self-tests stand in readers that disagree).
    nonisolated(unsafe) static var readers: [(String) -> String?] = [{ xxhash($0, cached: true) }, { xxhash($0, cached: false) }]

    /// A file's checksum from the bytes on the drive: the cache dropped, then read twice (through the cache
    /// and around it), and only when both agree. A decode alone can't see a flipped byte; this can.
    static func readBack(_ path: String, readers: [(String) -> String?] = readers) -> (hash: String?, problem: String?) {
        var hashes: [String?] = []
        for reader in readers {
            // (Dropped before each read: what's read is what's on the drive.)
            guard dropping(path) else { return (nil, String(localized: "Couldn’t read the master back from the drive")) }
            hashes.append(reader(path))
        }
        guard let first = hashes.first ?? nil, hashes.allSatisfy({ $0 == first }) else {
            return (nil, String(localized: "The master reads back differently each time"))
        }
        return (first, nil)
    }

    /// A file's size, date and file number now.
    struct Stamp: Codable, Hashable, Sendable {
        var size: Int64
        var modified: Double
        var inode: UInt64
    }

    static func stamp(_ path: String) -> Stamp? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Stamp(size: Int64(info.st_size), modified: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9, inode: UInt64(info.st_ino))
    }

    /// How long a passed check counts before it's done again.
    static let checkValid: TimeInterval = 7 * 86400

    /// SHA-256 of a file's first and last MB, read from the drive (not a cache).
    static func headHash(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
        let mb: UInt64 = 1_048_576
        guard let end = try? handle.seekToEnd(), (try? handle.seek(toOffset: 0)) != nil else { return nil }
        var hasher = SHA256()
        hasher.update(data: (try? handle.read(upToCount: Int(mb))) ?? Data())
        if end > mb, (try? handle.seek(toOffset: end - mb)) != nil { hasher.update(data: (try? handle.read(upToCount: Int(mb))) ?? Data()) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Self-tests: a step where Pluck is "killed" (nothing after it runs or is saved), to check what Resume finds.
    nonisolated(unsafe) static var kill: ((String, File) -> Bool)?
    nonisolated(unsafe) static var killed = false
    struct Killed: Error {}
    static func step(_ name: String, _ file: File) throws {
        if let kill, kill(name, file) { killed = true; throw Killed() }
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
    /// destination, else beside the original; `temp`: the hidden name, with this Mac's claim in it).
    /// The file comes back `.working` with where the master and (in place) the original go, or
    /// skipped or failed. Nothing but its own hidden file is written; the original isn't touched.
    static func prepare(_ file: File, settings: Settings, holding: URL, master given: String? = nil, temp chosen: String? = nil, ffmpeg: String, ffprobe: String,
                        quiet: TimeInterval = quiet, busy: Set<String> = [], freeSpace: (URL) -> Int64? = { OffloadCenter.freeSpace($0) },
                        capacity: (URL) -> Int64? = { ShrinkFolders.capacity($0) },
                        open: @escaping (URL) throws -> RawSource = { try RawFormats.open($0) }) -> File {
        do {
            return try preparing(file, settings: settings, holding: holding, master: given, temp: chosen, ffmpeg: ffmpeg, ffprobe: ffprobe, quiet: quiet,
                                 busy: busy, freeSpace: freeSpace, capacity: capacity, open: open)
        } catch { return file }
    }

    private static func preparing(_ file: File, settings: Settings, holding: URL, master given: String?, temp chosen: String?, ffmpeg: String, ffprobe: String,
                                  quiet: TimeInterval, busy: Set<String>, freeSpace: (URL) -> Int64?, capacity: (URL) -> Int64?,
                                  open: @escaping (URL) throws -> RawSource) throws -> File {
        var file = file
        let settings = file.projectSettings ?? settings
        func skip(_ why: String) -> File { file.state = .skipped; file.note = why; return file }
        func fail(_ why: String) -> File { file.state = .failed; file.note = why; return file }
        if file.kind == .deliveries { return skip(String(localized: "Delivery: never touched")) }
        if let why = stillTheSame(file, quiet: quiet) { return skip(why) }
        if busy.contains(where: { file.path.hasPrefix($0) }) { return skip(String(localized: "Being copied")) }
        if openElsewhere(file.path) { return skip(String(localized: "Open in another app")) }
        guard let master = given ?? masterPath(file.path) else { return skip(String(localized: "A clip with the master’s name is already there")) }
        if given != nil, FileManager.default.fileExists(atPath: master) { return skip(String(localized: "Already there")) }
        let folder = URL(fileURLWithPath: master).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: folder.path) else { return fail(String(localized: "Read-only: no permission to write here")) }
        if !room(for: file, settings: settings, free: freeSpace(folder), capacity: capacity(folder)) {
            return fail(String(localized: "Not enough free space for the master"))
        }
        let isRaw = ProjectArchive.rawMasterKinds.contains((file.path as NSString).pathExtension.lowercased())
        // Every track goes with the master, or the clip stays as it is.
        let extra: (kept: [Int], unkept: String?) = isRaw ? ([], nil) : ProjectArchive.extraTracks(file.path, ffprobe: ffprobe)
        if let why = extra.unkept { return skip(why) }
        guard var original = ProjectArchive.reference(file.path, ffprobe: ffprobe, count: false, open: open) else { return fail(String(localized: "Can’t be read")) }
        // (MXF and the like don't say their frame count in the header: counted then.)
        if original.frames == 0, !isRaw { original = ProjectArchive.streams(file.path, ffprobe: ffprobe) }
        guard original.frames > 0 else { return fail(String(localized: "Can’t be read")) }
        file.originalHead = headHash(file.path)
        let temp = chosen ?? temporary(master)
        file.temp = temp
        // (Its own hidden file: this Mac's claim is in its name.)
        try? FileManager.default.removeItem(atPath: temp)
        func drop(_ result: File) -> File { try? FileManager.default.removeItem(atPath: temp); return result }
        do {
            try ProjectArchive.encode(file.path, to: URL(fileURLWithPath: temp), settings: settings, ffmpeg: ffmpeg, ffprobe: ffprobe, metadata: tag, open: open)
        } catch {
            try step("encoded", file)
            if !extra.kept.isEmpty { return drop(skip(String(localized: "Has extra tracks Pluck can’t keep"))) }
            return drop(fail(error.localizedDescription))
        }
        try step("encoded", file)
        // On the drive for good, and this Mac's cached copy dropped, before it's read back and checked.
        guard flush(temp) else { return drop(fail(String(localized: "The master couldn’t be written to the drive"))) }
        dropCache(temp)
        let problems = ProjectArchive.verify(temp, against: original, ffmpeg: ffmpeg, ffprobe: ffprobe, source: file.path, open: open)
        let size = Int64((try? FileManager.default.attributesOfItem(atPath: temp)[.size] as? Int64) ?? 0)
        if problems.contains(String(localized: "Has extra tracks Pluck can’t keep")) { return drop(skip(problems.joined(separator: ", "))) }
        if !problems.isEmpty { return drop(fail(String(localized: "The master didn’t match: \(problems.joined(separator: ", "))"))) }
        if Double(size) > Double(file.size) * (1 - minimumSaving) { return drop(skip(String(localized: "Would save under 30%"))) }
        if let why = stillTheSame(file, quiet: quiet) { return drop(skip(why)) }
        // Its checksum, read back from the drive (not a cache): what Check Before Deleting compares.
        let read = readBack(temp)
        guard let hash = read.hash else { return drop(fail(read.problem ?? String(localized: "The master couldn’t be read back"))) }
        try step("verified", file)
        file.state = .working
        file.masterSize = size
        file.masterHash = hash
        file.frames = original.frames
        file.duration = original.duration
        file.master = master
        file.moved = given == nil ? movedPath(file.path, holding: holding) : nil
        if given == nil, master != file.path { file.note = String(localized: "Now \((master as NSString).lastPathComponent)") }
        return file
    }

    /// Puts a prepared master in place, and finishes one stopped halfway (Pluck quit) from what's on the
    /// drive. Under the original's name there's always the original or the checked master: a master with
    /// a new name (.mp4 → .mov) goes in before the original moves; one with the same name right after.
    /// The folder to delete only gets an original whose master is checked and goes in; when anything
    /// fails after the original moved, it's moved back. `stillOurs`: this Mac's claim is still its own
    /// (no: nothing is touched).
    static func finish(_ file: File, settings: Settings, inventory: URL? = nil, stillOurs: () -> Bool = { true }) -> File {
        do { return try finishing(file, settings: settings, inventory: inventory, stillOurs: stillOurs) } catch { return file }
    }

    private static func finishing(_ file: File, settings: Settings, inventory: URL?, stillOurs: () -> Bool) throws -> File {
        var file = file
        let fm = FileManager.default
        guard let master = file.master else { file.state = .failed; file.note = String(localized: "The master is gone"); return file }
        let temp = file.temp ?? temporary(master)
        func size(_ path: String) -> Int64? { (try? fm.attributesOfItem(atPath: path))?[.size] as? Int64 }
        func ready(_ path: String) -> Bool { size(path).map { file.masterSize == nil ? $0 > 0 : $0 == file.masterSize } ?? false }
        func drop() { try? fm.removeItem(atPath: temp) }
        func fail(_ why: String) -> File { file.state = .failed; file.note = why; file.moved = nil; return file }
        /// Made again from the start (the hidden master isn't there whole).
        func again() -> File { drop(); file.state = .pending; file.master = nil; file.masterSize = nil; file.moved = nil; file.note = nil; return file }
        // (Its own hidden master dropped: the Mac that has the file now makes its own.)
        // (Only while the original is still at its name: a hidden master standing for an original that moved stays.)
        guard stillOurs() else {
            if fm.fileExists(atPath: file.path), file.moved.map({ !fm.fileExists(atPath: $0) }) ?? true, file.master != file.path || file.moved == nil { drop() }
            file.note = String(localized: "Another Mac took this file over")
            return file
        }
        guard let moved = file.moved else {
            // In a destination: the master renamed into its place; the original isn't touched.
            if !ready(master) {
                guard ready(temp) else { return again() }
                if let why = rename(temp, master) { drop(); return fail(why) }
            }
            try step("master in", file)
            return done(&file, master: master, settings: settings, inventory: inventory)
        }
        let target = (moved as NSString).deletingLastPathComponent
        let parts = file.parts.map { ($0, (target as NSString).appendingPathComponent(($0 as NSString).lastPathComponent)) }
        /// Something failed after the original moved: it (and its parts) back under its name.
        func restore(_ why: String) -> File {
            let back = ([(file.path, moved)] + parts).map { ($0.1, $0.0) }.filter { fm.fileExists(atPath: $0.0) }
            if let problem = moveAll(back) {
                // (The original is whole in the folder to delete; nothing's lost. Resume tries again.)
                file.state = .working
                file.note = String(localized: "Couldn’t put the original back (\(why); \(problem)). It’s safe in “Pluck · Originals to delete”; Resume tries again.")
                file.problem = file.note
                return file
            }
            file.problem = nil
            return fail(why + " · " + String(localized: "The original is back in its place"))
        }
        // The original counts as moved only when all of it is there; an empty placeholder of Pluck's own left by a quit goes.
        let movedBytes = ([moved] + parts.map(\.1)).compactMap(size).reduce(0, +)
        if fm.fileExists(atPath: moved), movedBytes != file.size, fm.fileExists(atPath: file.path) {
            guard placeholder(moved) else {
                file.note = String(localized: "Something else is where the original goes in the folder to delete")
                return file
            }
            unlink(moved)
        }
        if !fm.fileExists(atPath: moved) {
            guard fm.fileExists(atPath: file.path) else {
                // Neither here nor in the folder to delete: its share isn't mounted (nothing's failed or forgotten).
                file.note = String(localized: "Neither the original nor its moved copy is there: is its share mounted?")
                return file
            }
            let current = file
            if master != file.path {
                // (Pluck stopped right after the master went in: it's this master, so it isn't made again.)
                let placed = !ready(temp) && ready(master) && file.masterHash != nil && readBack(master).hash == file.masterHash
                if !placed {
                    guard ready(temp) else { return again() }
                    if let why = rename(temp, master) { drop(); return fail(why) }
                }
                try step("master in", file)
                if let why = try movingOriginal(&file, to: moved, between: { try step("moving", current) }) {
                    // (The master only goes once the original is back at its name.)
                    guard fm.fileExists(atPath: file.path) else { file.note = why; file.problem = why; return file }
                    if rename(master, temp) == nil { drop() }
                    return fail(why)
                }
                try step("original out", file)
            } else {
                guard ready(temp) else { return again() }
                if let why = try movingOriginal(&file, to: moved, between: { try step("moving", current) }) { drop(); return fail(why) }
                try step("original out", file)
                if let why = rename(temp, master) { return restore(why) }
                try step("master in", file)
            }
        } else {
            // Pluck stopped halfway: finished from what's on the drive.
            let left = parts.filter { fm.fileExists(atPath: $0.0) && !fm.fileExists(atPath: $0.1) }
            if let why = moveAll(left) { return restore(why) }
            if !ready(master) {
                guard ready(temp) else { return restore(String(localized: "The master is gone")) }
                if let why = rename(temp, master) { return restore(why) }
            }
            try step("master in", file)
        }
        guard ready(master) else { return restore(String(localized: "The master is gone")) }
        return done(&file, master: master, settings: settings, inventory: inventory)
    }

    /// The master's in place: its sidecars beside it (copied into a destination) and a copy with the original in the folder to delete.
    private static func done(_ file: inout File, master: String, settings: Settings, inventory: URL?) -> File {
        let fm = FileManager.default
        ProjectArchive.copyDates(from: file.moved ?? file.path, to: master, modified: file.modified)
        let masterFolder = (master as NSString).deletingLastPathComponent
        for sidecar in file.sidecars ?? [] {
            let name = (sidecar as NSString).lastPathComponent
            for folder in [masterFolder, file.moved.map { ($0 as NSString).deletingLastPathComponent }].compactMap({ $0 })
            where folder != (sidecar as NSString).deletingLastPathComponent && !fm.fileExists(atPath: (folder as NSString).appendingPathComponent(name)) {
                try? fm.copyItem(atPath: sidecar, toPath: (folder as NSString).appendingPathComponent(name))
            }
        }
        file.state = .done
        file.problem = nil
        record(file, settings: settings, check: "verified", in: inventory)
        return file
    }

    /// Moves an original (and its parts) to `moved`, renamed on the same drive only (never a copy and
    /// a delete), all or none: when a part can't move, the ones that did go back. nil: done; else why.
    static func moveOriginal(_ file: inout File, to moved: String) -> String? { (try? movingOriginal(&file, to: moved, between: {})) ?? nil }

    static func movingOriginal(_ file: inout File, to moved: String, between: () throws -> Void) throws -> String? {
        let target = URL(fileURLWithPath: moved).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        guard let here = OffloadCenter.volume(URL(fileURLWithPath: file.path).deletingLastPathComponent()), here.isEqual(OffloadCenter.volume(target)) else {
            return String(localized: "The originals’ folder isn’t on the same drive")
        }
        let moves = [(file.path, moved)] + file.parts.map { ($0, target.appendingPathComponent(($0 as NSString).lastPathComponent).path) }
        if let why = try movingAll(moves, between: between) { return why }
        file.moved = moved
        return nil
    }

    /// Back as it was. In place: the master set aside (hidden beside it, never into the folder to delete),
    /// the original and its parts moved back, then the master to the Trash (or left hidden, said). When the
    /// original can't go back, the master goes back to its name and the file says why. In a destination:
    /// the master to the Trash (or hidden beside it).
    static func putBack(_ file: File, settings: Settings, inventory: URL? = nil,
                        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> File {
        var file = file
        let fm = FileManager.default
        guard file.state == .done, let master = file.master else { return file }
        let folder = (master as NSString).deletingLastPathComponent, name = (master as NSString).lastPathComponent
        let hidden = (folder as NSString).appendingPathComponent(".pluck-removed-" + name)
        func setAside() -> (String?, String?) {
            guard fm.fileExists(atPath: master) else { return (fm.fileExists(atPath: hidden) ? hidden : nil, nil) }
            // Only this master ever goes: whatever else is at its name is left as it is.
            let size = (try? fm.attributesOfItem(atPath: master))?[.size] as? Int64
            guard size == file.masterSize, file.masterHash == nil || readBack(master).hash == file.masterHash else {
                return (nil, String(localized: "The file at the master’s name isn’t this master: left as it is"))
            }
            let aside = fm.fileExists(atPath: hidden) ? (folder as NSString).appendingPathComponent(".pluck-removed-\(UUID().uuidString.prefix(8))-" + name) : hidden
            if let why = rename(master, aside) { return (nil, why) }
            return (aside, nil)
        }
        func toTrash(_ aside: String?) {
            guard let aside else { return }
            if (try? trash(URL(fileURLWithPath: aside))) == nil {
                file.note = String(localized: "The master is hidden next to it as \((aside as NSString).lastPathComponent)")
            }
        }
        if let moved = file.moved {
            guard fm.fileExists(atPath: moved) else { file.note = String(localized: "The original isn’t in the originals’ folder"); return file }
            let (aside, problem) = setAside()
            if let problem { file.problem = problem; return file }
            let target = (moved as NSString).deletingLastPathComponent
            let back = [(moved, file.path)] + file.parts.map { ((target as NSString).appendingPathComponent(($0 as NSString).lastPathComponent), $0) }
                .filter { fm.fileExists(atPath: $0.0) }
            if let why = moveAll(back) {
                if let aside, rename(aside, master) != nil {
                    file.problem = String(localized: "Couldn’t put the original back: \(why). The master is hidden next to it as \((aside as NSString).lastPathComponent)")
                } else {
                    file.problem = String(localized: "Couldn’t put the original back: \(why)")
                }
                return file
            }
            file.state = .restored
            file.problem = nil
            toTrash(aside)
        } else {
            let (aside, problem) = setAside()
            if let problem { file.problem = problem; return file }
            file.state = .restored
            file.problem = nil
            toTrash(aside)
        }
        record(file, settings: settings, check: "put back", in: inventory)
        return file
    }

    // MARK: Check Before Deleting

    /// What Check Before Deleting found: problems (empty: safe), the master's checksum read from the drive, and the master as it was.
    struct Checked: Sendable { var problems: [String]; var hash: String?; var stamp: Stamp? }

    /// One file whose master is in place, read again from the drive: the master there under its name with
    /// Pluck's tag and its size; its checksum read back from the drive (cache dropped, read twice) and the same
    /// as when it was made, or, made by an older Pluck without one, the master checked against its original
    /// in full; decoding to the end (nice'd), the original's frame count and length within a frame; and the
    /// original whole where it waits (its size, its first and last MB).
    static func check(_ file: File, ffmpeg: String, ffprobe: String, open: @escaping (URL) throws -> RawSource = { try RawFormats.open($0) }) -> Checked {
        let fm = FileManager.default
        func size(_ path: String) -> Int64? { (try? fm.attributesOfItem(atPath: path))?[.size] as? Int64 }
        guard file.state == .done, let master = file.master, let got = size(master) else { return Checked(problems: [String(localized: "The master is gone")]) }
        var problems: [String] = []
        let original = file.moved ?? file.path
        if let expected = file.masterSize, got != expected { problems.append(String(localized: "The master’s size changed")) }
        let tag = ProjectArchive.run(ffprobe, ["-v", "error", "-show_entries", "format_tags=pluck", "-of", "default=nw=1:nk=1", master]).output
        if !tag.contains("shrink") { problems.append(String(localized: "The master isn’t Pluck’s")) }
        let read = readBack(master)
        if let problem = read.problem { problems.append(problem) }
        if let stored = file.masterHash {
            if read.hash != nil, read.hash != stored { problems.append(String(localized: "The master’s checksum differs")) }
        } else if let reference = ProjectArchive.reference(original, ffprobe: ffprobe, open: open), reference.frames > 0 {
            // (Made before checksums: the master checked against its original again, in full.)
            problems += ProjectArchive.verify(master, against: reference, ffmpeg: ffmpeg, ffprobe: ffprobe, source: original, open: open)
        } else {
            problems.append(String(localized: "Not safe: checked without a checksum"))
        }
        if ProjectArchive.run("/usr/bin/nice", ["-n", "15", ffmpeg, "-nostdin", "-v", "error", "-xerror", "-i", master, "-map", "0:v", "-map", "0:a?", "-f", "null", "-"]).status != 0 {
            problems.append(String(localized: "It doesn’t play to the end"))
        }
        // (An older run kept no frame count: the original's own, counted.)
        let reference = file.frames == nil ? ProjectArchive.reference(original, ffprobe: ffprobe, open: open) : nil
        let frames = file.frames ?? reference?.frames ?? 0, length = file.duration ?? reference?.duration ?? 0
        let made = ProjectArchive.streams(master, ffprobe: ffprobe)
        if made.frames != frames { problems.append(String(localized: "\(made.frames) frames of \(frames)")) }
        if abs(made.duration - length) > 1 / max(made.fps > 0 ? made.fps : file.fps, 1) + 0.001 { problems.append(String(localized: "The length differs")) }
        let folder = (original as NSString).deletingLastPathComponent
        let sizes = ([original] + file.parts.map { (folder as NSString).appendingPathComponent(($0 as NSString).lastPathComponent) }).map(size)
        if sizes.contains(where: { $0 == nil }) {
            problems.append(String(localized: "The original isn’t all there"))
        } else if sizes.reduce(Int64(0), { $0 + ($1 ?? 0) }) != file.size || file.originalHead.map({ headHash(original) != $0 }) == true {
            problems.append(String(localized: "The original changed"))
        }
        return Checked(problems: Array(NSOrderedSet(array: problems)) as? [String] ?? problems, hash: read.hash, stamp: stamp(master))
    }

    /// A line in Inventory.csv: the holding folder's (in place) or the destination's.
    static func record(_ file: File, settings: Settings, check: String, in given: URL? = nil) {
        guard let folder = given ?? file.moved.flatMap(holdingFolder(of:)) else { return }
        func cell(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        // (Pluck's own name: a user's Inventory.csv in a destination is never written to.)
        let url = folder.appendingPathComponent("Pluck Inventory \(Date.now.formatted(.iso8601.year().month().day())).csv")
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

    /// Stops ffmpeg working on a master (a pause), by the hidden file it writes.
    static func stopWork(temp: String) {
        ProjectArchive.run("/usr/bin/pkill", ["-f", NSRegularExpression.escapedPattern(for: temp)])
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
        let iso = ISO8601DateFormatter()
        var csv = "original,moved_to,master,original_bytes,master_bytes,settings,kind,state,note,master_xxhash64,original_head_sha256,frames,seconds,checked_at,check_passed,check_problems\n"
        for file in run.files where file.state != .pending {
            csv += [cell(file.path), cell(file.moved ?? ""), cell(file.master ?? ""), "\(file.size)", "\(file.masterSize ?? 0)", cell(run.settings.label),
                    file.kind.rawValue, file.state.rawValue, cell(file.note ?? ""), file.masterHash ?? "", file.originalHead ?? "", file.frames.map { "\($0)" } ?? "",
                    file.duration.map { String(format: "%.3f", $0) } ?? "", file.checked.map(iso.string) ?? "", file.safeToDelete ? "yes" : "no",
                    cell((file.checkProblems ?? []).joined(separator: "; "))].joined(separator: ",") + "\n"
        }
        // The same as JSON, for anyone checking by hand or by script.
        let records: [[String: Any]] = run.files.filter { $0.state != .pending }.map { file in
            var record: [String: Any] = ["original": file.path, "original_bytes": file.size, "state": file.state.rawValue, "check_passed": file.safeToDelete]
            record["moved_to"] = file.moved
            record["master"] = file.master
            record["master_bytes"] = file.masterSize
            record["master_xxhash64"] = file.masterHash
            record["original_head_sha256"] = file.originalHead
            record["frames"] = file.frames
            record["seconds"] = file.duration
            record["checked_at"] = file.checked.map(iso.string)
            record["check_problems"] = file.checkProblems
            return record
        }
        let inventory = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
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
            try? inventory?.write(to: folder.appendingPathComponent("Shrink \(stamp).json"), options: .atomic)
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
    /// The run whose masters are being checked (Check Before Deleting).
    private(set) var checking: UUID?
    private var currentTemp: String?
    private var stopping = false
    /// Bytes of originals done and seconds spent in this go (for the time left).
    private var pace: (bytes: Int64, seconds: Double) = (0, 0)
    @ObservationIgnored private var awake: IOPMAssertionID?
    let store: URL
    /// This Mac's name in claims.
    let mac: String
    /// This Mac's hardware id (IOPlatformUUID).
    static let hardwareID: String = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        return (IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String) ?? ""
    }()

    /// This install of Pluck (kept beside runs.json): two Macs with the same computer name are never mistaken for one.
    let install: String
    /// Who this is in claims: the computer name (shown) and this install.
    var claimName: String { mac + "#" + install + "-" + ShrinkCenter.hardwareID }
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
        let idFile = store.deletingLastPathComponent().appendingPathComponent("install-id")
        if let kept = (try? String(contentsOf: idFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines), !kept.isEmpty {
            install = kept
        } else {
            install = UUID().uuidString
            try? FileManager.default.createDirectory(at: idFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? install.write(to: idFile, atomically: true, encoding: .utf8)
        }
        load()
    }

    /// The runs kept. A runs.json that can't be read (all or part) is kept aside as runs.json.unreadable-<date>
    /// before anything is saved over it; one not read at all falls back to runs.json.bak.
    func load() {
        let backup = store.appendingPathExtension("bak")
        guard let data = try? Data(contentsOf: store) else { runs = (try? Data(contentsOf: backup)).flatMap(ShrinkFolders.decodeRuns)?.runs ?? []; return }
        let stamp = Date.now.formatted(.iso8601.year().month().day().timeSeparator(.omitted).time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
        let aside = store.path + ".unreadable-" + stamp
        if let read = ShrinkFolders.decodeRuns(data) {
            runs = read.runs
            if !read.complete { try? FileManager.default.copyItem(atPath: store.path, toPath: aside) }
        } else {
            _ = rename(store.path, aside)
            runs = (try? Data(contentsOf: backup)).flatMap(ShrinkFolders.decodeRuns)?.runs ?? []
        }
    }

    /// Written to a new file and renamed over runs.json (never half written); the one before stays as runs.json.bak.
    private func save() {
        try? FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(runs) else { return }
        let saving = store.path + ".saving", backup = store.path + ".bak"
        guard (try? data.write(to: URL(fileURLWithPath: saving))) != nil else { return }
        if FileManager.default.fileExists(atPath: store.path) {
            unlink(backup)
            if link(store.path, backup) != 0 { try? FileManager.default.copyItem(atPath: store.path, toPath: backup) }
        }
        _ = rename(saving, store.path)
    }

    var running: Bool { active != nil }

    func run(_ id: UUID) -> ShrinkFolders.Run? { runs.first { $0.id == id } }

    /// A run with files still to do (paused, or Pluck quit), here or on the always-on Mac.
    func unfinished(_ run: ShrinkFolders.Run) -> Bool { run.files.contains { $0.state == .pending || $0.state == .working || $0.state == .elsewhere } }

    /// A run done here and on the always-on Mac: its proxies moved, unless it's working.
    func wrapUp(_ id: UUID) { if active != id { moveProxies(id) } }

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
        // Each share it touches as a NAS place, to find it again when it's mounted elsewhere.
        // (A destination's folders are made as masters go in: its share is the nearest folder there now.)
        let touched = Set((run.roots + [run.destination].compactMap { $0 }).map { ShrinkFolders.shareRoot(of: existing(URL(fileURLWithPath: $0))) })
        run.shares = Dictionary(uniqueKeysWithValues: touched.map { ($0, ShrinkRemote.place($0) ?? "") })
        run.shareIDs = Dictionary(uniqueKeysWithValues: (run.shares ?? [:]).compactMap { share, place in ShrinkFolders.shareID(share, place: place, create: true).map { (share, $0) } })
        for (share, place) in run.shares ?? [:] where !place.isEmpty && run.shareIDs?[share]?.hasPrefix("place:") == true {
            run.proxyNotes = (run.proxyNotes ?? [:]).merging([share: String(localized: "\((share as NSString).lastPathComponent) couldn’t be marked (read-only): another drive with its name can’t be told apart")]) { $1 }
        }
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

    /// Works through a run's files still to do, one at a time, until done or paused; once every file is
    /// through, Check Before Deleting on the masters not checked yet.
    func resume(_ id: UUID, ffmpeg: String, ffprobe: String) async {
        guard active == nil else { return }
        guard mounted(id) else { return }
        await work(id, ffmpeg: ffmpeg, ffprobe: ffprobe)
        if !stopping, !ShrinkFolders.killed, let run = run(id), !run.files.contains(where: { $0.state == .pending || $0.state == .working }) {
            await check(id, onlyNew: true, ffmpeg: ffmpeg, ffprobe: ffprobe)
            // (Proxies only once their clips' masters are checked.)
            moveProxies(id)
        }
    }

    /// Every share a run touches is mounted, and is the same share: one mounted at another path is found there
    /// (every path of the run moved to it); one not mounted pauses the run saying so (nothing fails or is forgotten).
    func mounted(_ id: UUID) -> Bool {
        guard let r = runs.firstIndex(where: { $0.id == id }) else { return false }
        func same(_ path: String, _ share: String, _ place: String) -> Bool {
            guard let kept = runs[r].shareIDs?[share] else { return true }
            return ShrinkFolders.shareID(path, place: place, create: false) == kept
        }
        for (share, place) in runs[r].shares ?? [:] {
            let here = FileManager.default.fileExists(atPath: share) && (place.isEmpty || ShrinkRemote.place(share) == place)
            if here {
                guard same(share, share, place) else {
                    runs[r].paused = String(localized: "This isn’t the drive the run started on (\((share as NSString).lastPathComponent)): nothing was moved")
                    save()
                    return false
                }
                continue
            }
            let parts = place.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if parts.count == 2, let now = OfficeGroup.localURL(OfficeGroup.Place(remount: parts[0], path: parts[1], changed: .now))?.path,
               now != share, FileManager.default.fileExists(atPath: now), same(now, share, place) {
                runs[r] = ShrinkFolders.relocated(runs[r], from: share, to: now)
                continue
            }
            runs[r].paused = String(localized: "\((share as NSString).lastPathComponent) isn’t at \(share): mount it")
            save()
            return false
        }
        save()
        return true
    }

    private func work(_ id: UUID, ffmpeg: String, ffprobe: String) async {
        active = id
        stopping = false
        pace = (0, 0)
        holdAwake(true)
        defer { active = nil; current = nil; currentTemp = nil; holdAwake(false); if let run = run(id) { ShrinkFolders.writeReport(run) } }
        if let r = runs.firstIndex(where: { $0.id == id }), runs[r].paused != nil { runs[r].paused = nil; save() }
        while !stopping, let r = runs.firstIndex(where: { $0.id == id }), let f = next(runs[r]) {
            let run = runs[r], settings = run.settings, quiet = quiet, freeSpace = freeSpace, capacity = capacity, mac = claimName
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
                    runs[r].paused = String(localized: "\(name) is nearly full: delete what’s waiting in “Pluck · Originals to delete”, or archive to another folder or NAS")
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
                // (A file halfway through stays this Mac's: the run waits rather than hand it over.)
                if file.state == .working {
                    runs[r].paused = String(localized: "Another Mac holds the claim of a file this Mac is halfway through: waiting")
                    save()
                    break
                }
                // The other Mac of this run has it.
                file.state = .elsewhere
                file.note = other.components(separatedBy: "#").first ?? other
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
            // Right before anything moves: the claim is still this Mac's (another Mac took a stale one over: hands off).
            let stillOurs: @Sendable () -> Bool = { claim.map { OfficeGroup.holder($0.url)?.token == $0.token } ?? true }
            ShrinkFolders.killed = false
            if file.state == .working {
                // Stopped halfway through putting the master in place: finished from what's there.
                file = await Task.detached { ShrinkFolders.finish(file, settings: settings, inventory: destination, stillOurs: stillOurs) }.value
            } else {
                // The hidden master's name has this claim in it: saved first, so only this Mac ever removes it.
                let temp = ShrinkFolders.temporary(target, token: String((claim?.token ?? UUID().uuidString).prefix(8)))
                if let left = file.temp, left != temp { try? FileManager.default.removeItem(atPath: left) }
                file.temp = temp
                set(file, in: id)
                interrupted = false
                let folder = file.folder
                let watch = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(editCheck))
                        if !Task.isCancelled, !runAnyway, await editing(folder) { interrupted = true; ShrinkFolders.stopWork(temp: temp); return }
                    }
                }
                defer { watch.cancel() }
                let busy = Set(OffloadCenter.shared.jobs.filter { $0.finished == nil && $0.running == true }.map(\.source))
                let holding = ShrinkFolders.holding(for: URL(fileURLWithPath: file.folder))
                current = target
                currentTemp = temp
                let made = await Task.detached {
                    ShrinkFolders.prepare(file, settings: settings, holding: holding, master: given, temp: temp, ffmpeg: ffmpeg, ffprobe: ffprobe, quiet: quiet,
                                          busy: busy, freeSpace: freeSpace, capacity: capacity)
                }.value
                watch.cancel()
                if ShrinkFolders.killed { stopping = true; break }
                if stopping || interrupted {
                    // (Paused for editing: the file is made again once it's quiet.)
                    try? FileManager.default.removeItem(atPath: temp)
                    if stopping { break }
                    continue
                }
                file = made
                if file.state == .working {
                    // Saved before anything moves, so a quit in between is picked up again.
                    set(file, in: id)
                    file = await Task.detached { ShrinkFolders.finish(file, settings: settings, inventory: destination, stillOurs: stillOurs) }.value
                }
            }
            if ShrinkFolders.killed { stopping = true; break }
            if file.state == .working {
                // It couldn't be finished (its original is safe in the folder to delete, or another Mac has it now): the run waits, saying why.
                set(file, in: id)
                if let r = runs.firstIndex(where: { $0.id == id }) { runs[r].paused = file.note; save() }
                break
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

    /// Once a run is through and checked: the proxy and cache folders of each project with a master made moved
    /// into the folder to delete, at their share path (renamed on the same drive) — only a folder whose every
    /// clip is a proxy of a clip whose master passed Check Before Deleting; any other stays, saying why.
    private func moveProxies(_ id: UUID) {
        guard let r = runs.firstIndex(where: { $0.id == id }), !unfinished(runs[r]) else { return }
        let projects = Set(runs[r].files.filter { $0.state == .done && $0.moved != nil }.map(\.project))
        let kinds = ProjectArchive.videoKinds.union(ProjectArchive.rawMasterKinds)
        for project in projects {
            let clips = runs[r].files.filter { $0.project == project }
            for folder in runs[r].proxyFolders[project] ?? [] where runs[r].movedFolders[folder] == nil && FileManager.default.fileExists(atPath: folder) {
                guard let file = clips.first else { continue }
                let inside = (FileManager.default.enumerator(atPath: folder)?.allObjects as? [String] ?? []).filter { name in
                        var isFolder: ObjCBool = false
                        let last = (name as NSString).lastPathComponent
                        return FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(name), isDirectory: &isFolder) && !isFolder.boolValue
                            && last != ".DS_Store" && !last.hasPrefix("._")
                    }
                // Every file: a proxy of a checked master, or a cache Resolve makes again (CacheClip, .gallery, OptimizedMedia).
                let unkept = inside.first { proxy in
                    let places = ((folder as NSString).lastPathComponent + "/" + proxy).lowercased().split(separator: "/")
                    if places.contains(where: { ["cacheclip", ".gallery", "optimizedmedia", "optimized media"].contains($0) }) { return false }
                    guard kinds.contains((proxy as NSString).pathExtension.lowercased()) else { return true }
                    let stem = (((proxy as NSString).lastPathComponent as NSString).deletingPathExtension).lowercased()
                    let of = clips.filter { clip in
                        let name = (((clip.path as NSString).lastPathComponent as NSString).deletingPathExtension).lowercased()
                        return stem == name || stem.hasPrefix(name + "_") || stem.hasPrefix(name + " ") || stem.hasPrefix(name + ".")
                    }
                    return of.isEmpty || !of.allSatisfy { $0.safeNow() }
                }
                if let unkept {
                    runs[r].proxyNotes = (runs[r].proxyNotes ?? [:]).merging([folder: String(localized: "Left: \((unkept as NSString).lastPathComponent) isn’t a proxy of a checked master or a cache")]) { $1 }
                    continue
                }
                var holder = ShrinkFolders.File(path: folder, folder: file.folder, size: 0, modified: .now)
                let target = ShrinkFolders.movedPath(folder, holding: ShrinkFolders.holding(for: URL(fileURLWithPath: file.folder)))
                if ShrinkFolders.moveOriginal(&holder, to: target) == nil { runs[r].movedFolders[folder] = target; runs[r].proxyNotes?[folder] = nil }
            }
        }
        save()
    }

    /// Stops after the file now (the master being made is stopped and dropped).
    func pause() {
        stopping = true
        runAnyway = false
        if let currentTemp { ShrinkFolders.stopWork(temp: currentTemp) }
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

    /// A destination run's originals, moved into their share's folder to delete (where Pluck may write), each only
    /// once its master is there and passes Check Before Deleting.
    @discardableResult
    func moveOriginals(_ id: UUID, ffmpeg: String, ffprobe: String) async -> [String] {
        guard active == nil, let run = run(id) else { return [] }
        active = id
        defer { active = nil; if let run = self.run(id) { ShrinkFolders.writeReport(run) } }
        var problems: [String] = []
        let settings = run.settings
        for file in readyToDelete(run) {
            let holding = ShrinkFolders.holding(for: URL(fileURLWithPath: file.folder))
            let moved: ShrinkFolders.File = await Task.detached {
                var file = file
                let checked = ShrinkFolders.check(file, ffmpeg: ffmpeg, ffprobe: ffprobe), found = checked.problems
                file.checked = .now
                file.checkProblems = found
                file.masterStamp = checked.stamp
                if file.masterHash == nil, found.isEmpty { file.masterHash = checked.hash }
                guard found.isEmpty else { file.note = found.joined(separator: ", "); return file }
                if let why = ShrinkFolders.moveOriginal(&file, to: ShrinkFolders.movedPath(file.path, holding: holding)) { file.note = why }
                else { ShrinkFolders.record(file, settings: settings, check: "checked, original moved") }
                return file
            }.value
            if moved.moved == nil { problems.append("\((file.path as NSString).lastPathComponent): \(moved.note ?? "")") }
            set(moved, in: id)
        }
        return problems
    }

    /// Check Before Deleting: each master of a run (`holding`: only those whose originals wait in that folder;
    /// `onlyNew`: only those not checked yet) read again from the drive (ShrinkFolders.check), the result kept
    /// per file and written into the run's inventory. Nothing is moved or deleted.
    /// (`onlyNew`: also those checked over a week ago or whose master changed since.) Gives what stopped it (nil: done).
    @discardableResult
    func check(_ id: UUID, holding: URL? = nil, onlyNew: Bool = false, ffmpeg: String, ffprobe: String) async -> String? {
        guard checking == nil, run(id) != nil else { return nil }
        guard mounted(id), let run = run(id) else { return self.run(id)?.paused }
        checking = id
        defer { checking = nil; if let run = self.run(id) { ShrinkFolders.writeReport(run) } }
        let folder = holding.map { ShrinkFolders.real($0).path }
        for file in run.files where file.state == .done && (!onlyNew || !file.safeNow())
            && (folder == nil || file.moved.flatMap(ShrinkFolders.holdingFolder(of:)).map { ShrinkFolders.real($0).path } == folder) {
            let found = await Task.detached(priority: .utility) { ShrinkFolders.check(file, ffmpeg: ffmpeg, ffprobe: ffprobe) }.value
            guard var now = self.run(id)?.files.first(where: { $0.path == file.path }), now.state == .done else { continue }
            now.checked = .now
            now.checkProblems = found.problems
            now.masterStamp = found.stamp
            // (A master made before checksums: its checksum kept once it passed against its original.)
            if now.masterHash == nil, found.problems.isEmpty { now.masterHash = found.hash }
            set(now, in: id)
        }
        return nil
    }

    /// Check Before Deleting for everything waiting in one folder to delete. Gives why nothing was checked (nil: checked).
    @discardableResult
    func check(holding: URL, ffmpeg: String, ffprobe: String) async -> String? {
        let folder = ShrinkFolders.real(holding).path
        let mine = runs.filter { $0.files.contains { $0.moved.flatMap(ShrinkFolders.holdingFolder(of:)).map { ShrinkFolders.real($0).path } == folder } }
        guard !mine.isEmpty else { return String(localized: "No runs for this share found at \(holding.path)") }
        var stopped: String?
        for run in mine { if let why = await check(run.id, holding: holding, ffmpeg: ffmpeg, ffprobe: ffprobe) { stopped = why } }
        return stopped
    }

    /// Relink in Resolve pointed projects at a run's masters (Put Back then says how to point them back).
    func markRelinked(_ id: UUID, _ on: Bool = true) {
        guard let r = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[r].relinked = on ? .now : nil
        save()
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

extension ShrinkFolders {
    /// A share's identity: a NAS share's own .pluck-share-id at its top (made once, never written over; a
    /// read-only share: its server and share name), a disk's volume UUID. nil: can't be told.
    static func shareID(_ share: String, place: String, create: Bool) -> String? {
        if !place.isEmpty {
            let marker = (share as NSString).appendingPathComponent(".pluck-share-id")
            func read() -> String? {
                guard let text = (try? String(contentsOfFile: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                return "marker:" + text
            }
            if let known = read() { return known }
            if create {
                let handle = Darwin.open(marker, O_CREAT | O_EXCL | O_WRONLY, 0o644)
                if handle >= 0 {
                    let id = Array(UUID().uuidString.utf8)
                    _ = id.withUnsafeBytes { write(handle, $0.baseAddress, $0.count) }
                    close(handle)
                }
                if let known = read() { return known }
            }
            return FileManager.default.fileExists(atPath: marker) ? nil : "place:" + place
        }
        return (try? URL(fileURLWithPath: share).resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString.map { "volume:" + $0 }
    }

    /// A run with every path on one share moved to where that share is mounted now.
    static func relocated(_ run: Run, from old: String, to new: String) -> Run {
        func map(_ path: String) -> String { path == old || path.hasPrefix(old + "/") ? new + path.dropFirst(old.count) : path }
        var run = run
        run.files = run.files.map { file in
            var file = ShrinkRemote.translated(file) { map($0) } ?? file
            file.project = map(file.project)
            return file
        }
        run.roots = run.roots.map(map)
        run.destination = run.destination.map(map)
        run.proxyFolders = Dictionary(run.proxyFolders.map { (map($0.key), $0.value.map(map)) }) { $1 }
        run.movedFolders = Dictionary(run.movedFolders.map { (map($0.key), map($0.value)) }) { $1 }
        run.shares = run.shares.map { Dictionary($0.map { (map($0.key), $0.value) }) { $1 } }
        run.shareIDs = run.shareIDs.map { Dictionary($0.map { (map($0.key), $0.value) }) { $1 } }
        return run
    }
}

// MARK: Reading what's kept, whatever Pluck wrote it

/// Every field read on its own: a key missing (an older Pluck) or one this Pluck can't read takes its
/// default, so a run is never lost to a field. Only a file without its path can't be read.
extension ShrinkFolders.File {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys) -> T? { (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil }
        path = try c.decode(String.self, forKey: .path)
        folder = v(.folder) ?? (path as NSString).deletingLastPathComponent
        size = v(.size) ?? 0
        modified = v(.modified) ?? .distantPast
        seconds = v(.seconds) ?? 0
        fps = v(.fps) ?? 0
        width = v(.width) ?? 0
        height = v(.height) ?? 0
        channels = v(.channels) ?? 0
        sampleRate = v(.sampleRate) ?? 0
        // (A kind this Pluck doesn't know is taken as a delivery: never touched.)
        kind = v(.kind) ?? (c.contains(.kind) ? .deliveries : .other)
        why = v(.why) ?? ""
        codec = v(.codec) ?? ""
        projectChanged = v(.projectChanged)
        client = v(.client) ?? ""
        projectName = v(.projectName) ?? ""
        project = v(.project) ?? ""
        skip = v(.skip)
        parts = v(.parts) ?? []
        sidecars = v(.sidecars)
        projectSettings = v(.projectSettings)
        note = v(.note)
        // (A state this Pluck doesn't know: failed, so nothing is done to it.)
        if let known: State = v(.state) { state = known } else if c.contains(.state) { state = .failed; note = note ?? String(localized: "Written by a newer Pluck") }
        master = v(.master)
        masterSize = v(.masterSize)
        moved = v(.moved)
        temp = v(.temp)
        frames = v(.frames)
        duration = v(.duration)
        originalHead = v(.originalHead)
        masterHash = v(.masterHash)
        checked = v(.checked)
        checkProblems = v(.checkProblems)
        problem = v(.problem)
        masterStamp = v(.masterStamp)
    }
}

extension ShrinkFolders.Run {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys) -> T? { (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil }
        id = v(.id) ?? UUID()
        date = v(.date) ?? .distantPast
        // (A run without its settings can't carry on: it's kept aside, never guessed.)
        settings = try c.decode(ShrinkFolders.Settings.self, forKey: .settings)
        files = try c.decode([LossyFile].self, forKey: .files).compactMap(\.file)
        destination = v(.destination)
        roots = v(.roots) ?? []
        proxyFolders = v(.proxyFolders) ?? [:]
        movedFolders = v(.movedFolders) ?? [:]
        paused = v(.paused)
        relinked = v(.relinked)
        shares = v(.shares)
        proxyNotes = v(.proxyNotes)
        shareIDs = v(.shareIDs)
    }
}

/// A file of a run that may not be readable.
struct LossyFile: Decodable {
    var file: ShrinkFolders.File?
    init(from decoder: Decoder) throws { file = try? ShrinkFolders.File(from: decoder) }
}

extension ShrinkFolders {
    /// Runs read one by one: the readable ones, and whether anything couldn't be (a run, or a file of one);
    /// nil: not a list of runs at all.
    static func decodeRuns(_ data: Data) -> (runs: [Run], complete: Bool)? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        var runs: [Run] = [], complete = true
        for item in list {
            guard let one = try? JSONSerialization.data(withJSONObject: item), let run = try? JSONDecoder().decode(Run.self, from: one) else { complete = false; continue }
            if ((item as? [String: Any])?["files"] as? [Any])?.count != run.files.count { complete = false }
            runs.append(run)
        }
        return (runs, complete)
    }

    /// Files sent as JSON (the always-on Mac's): the readable ones.
    static func decodeFiles(_ json: Any) -> [File]? {
        guard let data = try? JSONSerialization.data(withJSONObject: json), let list = try? JSONDecoder().decode([LossyFile].self, from: data) else { return nil }
        return list.compactMap(\.file)
    }
}
