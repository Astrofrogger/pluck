import Accelerate
import Foundation
import Vision

/// Sync Cameras: clips from several cameras (and a separate sound recorder) put on one timeline
/// by timecode (embedded, or a timecode slate shown to the camera) checked against the sound,
/// by sound where there's no usable timecode, and cameras without sound (a drone) by the light
/// flashes the synced cameras saw too. Clock times only hint (narrow the search, a rough place).

/// One clip: what it is, and where it sits once synced (timeline time = start + t · (1 + drift)).
struct SyncClip: Identifiable, Hashable, Sendable, Codable {
    enum Method: String, Sendable, Codable { case audio, timecode, timecodeOffset, slate, flashes, manual }
    enum Quality { case good, fair, poor, rough, none }

    var id = UUID()
    var path: String
    var duration = 0.0
    /// 0 for sound only.
    var fps = 0.0
    var hasAudio = false
    var hasVideo = false
    /// The first frame's timecode, in real seconds (23.976/29.97/59.94 frames 1001/1000 longer, as sound and slates count).
    var timecode: Double?
    /// Its timecode is drop frame (; or . before the frames).
    var dropFrame = false
    /// Where the sound starts after the picture (stream start times).
    var audioOffset = 0.0
    /// When it was recorded by the camera's clock (or the file's dates: `clockFromFile`).
    var created: Date?
    var clockFromFile = false
    /// The time a timecode slate shown to the camera reads at the first frame, once looked for.
    var slate: Double?
    var slateChecked = false
    /// Every timecode read off its picture (to check by eye), and whether it agrees with the slate value.
    var shown: [ShownTimecode] = []
    /// Frames the slate it shows is off from the other cameras' slates where it's synced.
    var slateOff: Int?
    /// Where its clock time alone puts it: shown, never synced.
    var rough: Double?
    var start: Double?
    var drift = 0.0
    var method: Method?
    var confidence = 0.0
    var locked = false
    /// The picture's size and codec ("prores Proxy", "h264"), to tell a proxy from its original.
    var width = 0
    var height = 0
    var codec = ""
    /// A proxy of this clip that was dropped too: played (and listened to) instead, the original synced and sent.
    var proxy: String?
    /// A proxy whose original isn't here: the only copy of that angle.
    var isProxy = false

    var file: URL { URL(fileURLWithPath: path) }
    var name: String { file.lastPathComponent }
    func time(_ local: Double) -> Double? { start.map { $0 + local * (1 + drift) } }
    var end: Double? { time(duration) }
    var quality: Quality {
        guard start != nil else { return rough != nil ? .rough : .none }
        if method == .manual { return .good }
        return confidence >= 0.7 ? .good : confidence >= 0.4 ? .fair : .poor
    }
}

/// A timecode read off a clip's picture: at which frame, what it read.
struct ShownTimecode: Hashable, Sendable, Codable {
    var frame: Int
    var text: String
    var agrees: Bool
}

/// One camera (or sound recorder): its clips in order.
struct SyncCamera: Identifiable, Hashable, Sendable, Codable {
    var id = UUID()
    var name: String
    /// What it was grouped by (a serial, a camera letter, a folder).
    var key: String
    var clips: [SyncClip]

    var hasAudio: Bool { clips.contains { $0.hasAudio } }
    var isSoundRecorder: Bool { !clips.isEmpty && clips.allSatisfy { !$0.hasVideo } }
    var audioLength: Double { clips.filter(\.hasAudio).map(\.duration).reduce(0, +) }
}

enum CameraSync {
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "mxf", "mts", "m2ts", "avi", "mkv", "insv", "r3d", "braw", "crm"]
    static let audioExtensions: Set<String> = ["wav", "bwf", "aif", "aiff", "mp3", "m4a", "flac"]

    // MARK: - Finding and grouping

    /// The clips in what was dropped, each with the folder it was dropped in (proxies, thumbnails
    /// and the later files of a split RED take left out).
    static func files(in urls: [URL]) -> [(file: URL, root: URL)] {
        var found: [(URL, URL)] = []
        func wanted(_ url: URL) -> Bool {
            let kind = url.pathExtension.lowercased()
            guard videoExtensions.contains(kind) || audioExtensions.contains(kind) else { return false }
            // A RED camera's own .wav sits in the take's folder: it's the take's sound, not a recorder.
            if audioExtensions.contains(kind), url.deletingLastPathComponent().pathExtension.lowercased() == "rdc" { return false }
            return RawFormats.spanned(url) == nil
        }
        for url in urls {
            if url.hasDirectoryPath, let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for case let file as URL in walk where wanted(file) { found.append((file, url)) }
            } else if wanted(url) {
                found.append((url, url.deletingLastPathComponent()))
            }
        }
        return found.sorted { $0.0.path.localizedStandardCompare($1.0.path) == .orderedAscending }
    }

    struct Probe: Sendable {
        var clip: SyncClip
        var root: URL
        var serial: String?
        var model: String?
    }

    /// A clip's length, rate, sound, timecode and camera (ffprobe; RED and Blackmagic RAW through the raw decoder).
    static func probe(_ file: URL, root: URL, ffprobe: String) -> Probe? {
        var clip = SyncClip(path: file.path)
        if RawFormats.isRawVideo(file) {
            guard let source = try? RawFormats.open(file) else { return nil }
            defer { source.close() }
            let info = source.info
            clip.fps = info.fps
            clip.width = info.width
            clip.height = info.height
            clip.codec = info.format
            clip.duration = Double(info.frames) / max(info.fps, 1)
            clip.hasVideo = true
            clip.hasAudio = info.audioChannels > 0 || ((try? source.audio()) ?? nil) != nil
            clip.timecode = info.timecode.flatMap { seconds(timecode: $0, fps: info.fps) }
            clip.dropFrame = info.timecode.map(isDropFrame) ?? false
            fileClock(&clip)
            let serial = ["camera_id", "serial_number", "camera_serial_number", "Camera Serial #"].lazy.compactMap { info.meta[$0] }.first { !$0.isEmpty }
            return Probe(clip: clip, root: root, serial: serial, model: info.camera)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobe)
        process.arguments = ["-v", "error", "-show_streams", "-show_format", "-of", "json", file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let streams = json["streams"] as? [[String: Any]] ?? []
        let format = json["format"] as? [String: Any] ?? [:]
        // (Cover art in a sound file is a "video" stream of one picture.)
        let video = streams.first { $0["codec_type"] as? String == "video" && ($0["disposition"] as? [String: Any])?["attached_pic"] as? Int != 1 }
        let audio = streams.first { $0["codec_type"] as? String == "audio" }
        guard video != nil || audio != nil else { return nil }
        func rate(_ text: Any?) -> Double? {
            guard let parts = (text as? String)?.split(separator: "/").compactMap({ Double($0) }), parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
            return parts[0] / parts[1]
        }
        func number(_ value: Any?) -> Double? { (value as? String).flatMap(Double.init) }
        clip.hasVideo = video != nil
        clip.hasAudio = audio != nil
        clip.width = video?["width"] as? Int ?? 0
        clip.height = video?["height"] as? Int ?? 0
        clip.codec = [video?["codec_name"] as? String, video?["profile"] as? String].compactMap { $0 }.joined(separator: " ")
        clip.fps = video.map { rate($0["avg_frame_rate"]) ?? rate($0["r_frame_rate"]) ?? 25 } ?? 0
        clip.duration = number(format["duration"]) ?? number(video?["duration"]) ?? number(audio?["duration"]) ?? 0
        if let video, let audio, let a = number(audio["start_time"]), let v = number(video["start_time"]) { clip.audioOffset = a - v }
        var tags: [String: String] = [:]
        for source in [format["tags"]] + streams.map({ $0["tags"] }) {
            for (key, value) in source as? [String: Any] ?? [:] { if let value = value as? String, tags[key.lowercased()] == nil { tags[key.lowercased()] = value } }
        }
        if let text = tags["timecode"], clip.fps > 0 { clip.timecode = seconds(timecode: text, fps: clip.fps); clip.dropFrame = isDropFrame(text) }
        // A sound recorder's (BWF) timecode: samples since midnight.
        if clip.timecode == nil, !clip.hasVideo, let samples = tags["time_reference"].flatMap(Double.init), let rate = number(audio?["sample_rate"]), rate > 0 {
            clip.timecode = samples / rate
        }
        // The camera's own date (with its time zone) first, then the file's.
        for text in [tags["com.apple.quicktime.creationdate"], tags["creation_time"]].compactMap({ $0 }) where clip.created == nil {
            clip.created = ISO8601DateFormatter.withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text) ?? DateFormatter.zoned.date(from: text)
        }
        if clip.created == nil { fileClock(&clip) }
        let serial = tags.first { $0.key.contains("serial") || $0.key.hasSuffix("camera.identifier") }?.value
        let model = tags["com.apple.quicktime.model"] ?? tags["model"] ?? tags["com.android.model"]
        return Probe(clip: clip, root: root, serial: serial?.trimmingCharacters(in: .whitespaces), model: model)
    }

    // MARK: - Proxies

    /// Folders proxies are kept in: Resolve's ProxyMedia and OptimizedMedia, a camera's Proxy or Sub (Sony XAVC),
    /// Pluck's "… – Proxies (H.265)".
    static func inProxyFolder(_ clip: SyncClip) -> Bool {
        // (The nearest three folders: a drive or a folder far above named "Proxies" doesn't make everything a proxy.)
        clip.file.deletingLastPathComponent().pathComponents.suffix(3).contains { part in
            let name = part.lowercased()
            return ["sub", "proxymedia", "optimizedmedia", "optimised media", "optimized media"].contains(name) || name.hasPrefix("proxy") || name.contains("proxies")
        }
    }

    /// A clip's name without its extension(s) and a proxy's mark: "A001_Proxy.mov", "A001.MXF.mov" (Pluck),
    /// "C0001S03.MP4" (Sony), "…_P.mov" (RED), "…_001.R3D" all give the original's.
    static func baseName(_ clip: SyncClip) -> (name: String, marked: Bool) {
        var name = clip.file.deletingPathExtension().lastPathComponent
        let inner = (name as NSString).pathExtension.lowercased()
        if videoExtensions.contains(inner) { name = (name as NSString).deletingPathExtension }
        if clip.file.pathExtension.lowercased() == "r3d", let mark = name.range(of: "_[0-9]{3}$", options: .regularExpression) { name.removeSubrange(mark) }
        for pattern in ["(?i)[ ._-]?prox(y|ies)$", "_[Pp]$", "(?<=[0-9])S[0-9]{2}$"] {
            if let mark = name.range(of: pattern, options: .regularExpression) { name.removeSubrange(mark); return (name.uppercased(), true) }
        }
        return (name.uppercased(), false)
    }

    /// How much a clip looks like a proxy: in a proxy folder, a proxy's mark in its name, a proxy codec.
    static func proxyLook(_ clip: SyncClip) -> Int {
        let codec = clip.codec.lowercased()
        return (inProxyFolder(clip) ? 1 : 0) + (baseName(clip).marked ? 1 : 0) + (codec.hasPrefix("prores") && (codec.hasSuffix("proxy") || codec.hasSuffix(" lt")) ? 1 : 0)
    }

    /// Proxies whose original is among the clips (proxy → original): the same name (or, in a proxy folder,
    /// the same timecode) and length within a frame, and smaller or more proxy-like than the original.
    /// shortcut: Pluck's proxy manifest isn't read; its proxies match by name and folder like any other.
    static func proxies(_ clips: [SyncClip]) -> [UUID: UUID] {
        var pairs: [UUID: UUID] = [:]
        let videos = clips.filter(\.hasVideo)
        let bases = Dictionary(grouping: videos) { baseName($0).name }
        for proxy in videos {
            let look = proxyLook(proxy)
            let frame = 1.5 / max(proxy.fps, 24)
            let named = bases[baseName(proxy).name] ?? []
            // (Resolve's OptimizedMedia has names of its own: there, the timecode has to match.)
            let timed = inProxyFolder(proxy) && proxy.timecode != nil ? videos.filter { $0.timecode.map { abs($0 - proxy.timecode!) < frame } ?? false } : []
            let original = (named + timed).filter { o in
                guard o.id != proxy.id, abs(o.duration - proxy.duration) < frame else { return false }
                if let a = o.timecode, let b = proxy.timecode, abs(a - b) >= frame { return false }
                if !named.contains(where: { $0.id == o.id }) && proxy.width >= o.width { return false }
                // (Same name, no proxy sign: only in the same folder tree. Two cameras both write C0001.MP4.)
                if look == 0 && !sameTree(o.file, proxy.file) { return false }
                // (Lower resolution alone: at most half the pixels, so two cameras started together aren't taken for one.)
                let area = proxy.width * proxy.height, full = o.width * o.height
                let smaller = area > 0 && full > 0 && (area * 2 <= full || (look > 0 && area < full))
                return (smaller || look > proxyLook(o)) && !(o.width > 0 && proxy.width > o.width)
            }.max { $0.width * $0.height < $1.width * $1.height }
            if let original { pairs[proxy.id] = original.id }
        }
        // A chain (a proxy of a proxy) points at the real original.
        for (proxy, original) in pairs { if let further = pairs[original] { pairs[proxy] = further } }
        return pairs
    }

    /// One file's folder holds the other (or they share one).
    static func sameTree(_ a: URL, _ b: URL) -> Bool {
        let x = a.deletingLastPathComponent().standardizedFileURL.path + "/", y = b.deletingLastPathComponent().standardizedFileURL.path + "/"
        return x.hasPrefix(y) || y.hasPrefix(x)
    }

    /// The file's dates as a last resort: its last change (kept when copied), less its length, else when it was made.
    /// shortcut: RED/BRAW metadata dates aren't read; their file dates are used.
    static func fileClock(_ clip: inout SyncClip) {
        guard let values = try? clip.file.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey]) else { return }
        clip.created = values.contentModificationDate.map { $0.addingTimeInterval(-clip.duration) } ?? values.creationDate
        clip.clockFromFile = clip.created != nil
    }

    /// "01:02:03:04" (or with ; or . for drop frame) in real seconds: at 23.976/29.97/59.94 the label's frames last
    /// 1001/1000 longer (10:00:00:00 non-drop is 36036 s), as sound, BWF and slates count.
    static func seconds(timecode: String, fps: Double) -> Double? {
        let parts = timecode.split(whereSeparator: { ":;.".contains($0) }).compactMap { Int($0) }
        guard parts.count == 4, fps > 0 else { return nil }
        let base = max(fps.rounded(), 1)
        return shownSeconds(parts, drop: isDropFrame(timecode), rate: base, fractional: abs(fps - base) > 0.01)
    }

    static func isDropFrame(_ timecode: String) -> Bool { timecode.contains { ";.".contains($0) } }

    /// Clips into cameras: by serial number in the metadata, else the camera letter in RED and
    /// Blackmagic names, else the card's camera, else the card's folder (split by file name
    /// pattern where one folder holds several cameras). Sound-only files make their own group.
    static func group(_ probes: [Probe]) -> [SyncCamera] {
        var cards: [URL: CameraCard] = [:]
        // The camera's folder: the first folder under what was dropped (a card), else the dropped folder itself.
        func folder(_ probe: Probe) -> URL {
            let parts = probe.clip.file.deletingLastPathComponent().standardizedFileURL.pathComponents
            let root = probe.root.standardizedFileURL.pathComponents
            guard parts.count > root.count, Array(parts.prefix(root.count)) == root else { return probe.root }
            return probe.root.appendingPathComponent(parts[root.count], isDirectory: true)
        }
        func prefix(_ name: String) -> String { String(name.prefix { !$0.isNumber && $0 != "_" && $0 != "-" && $0 != "." }).uppercased() }
        let prefixesByFolder = Dictionary(grouping: probes, by: folder).mapValues { Set($0.map { prefix($0.clip.name) }) }
        var order: [String] = []
        var byKey: [String: SyncCamera] = [:]
        for probe in probes {
            let place = folder(probe)
            let kind = probe.clip.file.pathExtension.lowercased()
            var key: String
            var name: String
            if let serial = probe.serial, !serial.isEmpty {
                key = "serial:" + serial
                name = probe.model ?? serial
            } else if ["r3d", "braw"].contains(kind), let letter = probe.clip.name.first, letter.isLetter,
                      probe.clip.name.dropFirst().prefix(3).allSatisfy(\.isNumber) {
                let brand = kind == "r3d" ? "RED" : "Blackmagic"
                key = "letter:\(brand) \(letter.uppercased())"
                name = "\(brand) \(letter.uppercased())"
            } else {
                // (The card's camera only for a folder of one camera's files.)
                let single = (prefixesByFolder[place]?.count ?? 0) <= 1
                let card = single ? cards[place] ?? CameraCard.read(place) : CameraCard(brand: "Camera")
                cards[place] = card
                if let cardKey = card.key {
                    key = "card:" + cardKey
                    name = card.name
                } else {
                    key = "folder:" + place.path
                    name = place.lastPathComponent
                    if (prefixesByFolder[place]?.count ?? 0) > 1 {
                        let own = prefix(probe.clip.name)
                        key += "/" + own
                        if !own.isEmpty { name += " " + own }
                    }
                }
            }
            if !probe.clip.hasVideo, !key.hasPrefix("serial:") {
                key = "sound:" + place.path
                name = String(localized: "Sound")
            }
            if byKey[key] == nil {
                order.append(key)
                byKey[key] = SyncCamera(name: name, key: key, clips: [])
            }
            byKey[key]?.clips.append(probe.clip)
        }
        var cameras = order.compactMap { byKey[$0] }
        // Two cameras of the same model: "Sony FX3", "Sony FX3 2".
        var seen: [String: Int] = [:]
        for index in cameras.indices {
            let count = (seen[cameras[index].name] ?? 0) + 1
            seen[cameras[index].name] = count
            if count > 1 { cameras[index].name += " \(count)" }
            cameras[index].clips.sort { ($0.timecode ?? 0, $0.created ?? .distantPast, $0.path) < ($1.timecode ?? 0, $1.created ?? .distantPast, $1.path) }
        }
        return cameras
    }

    // MARK: - Sync

    struct Options: Sendable {
        var ffmpeg: String
        /// The sound of a clip as a file ffmpeg reads (RED and BRAW: made by the raw decoder).
        var sound: @Sendable (SyncClip) -> URL? = { $0.file }
        /// Sound already measured, kept between syncs.
        var cache: SyncCache?
        /// Sound before timecode, for a shoot whose timecode can't be trusted.
        var audioFirst = false
        /// Timecode shown on camera (a slate, a timecode app held in frame, burned-in): looked for all through each clip's first and last 10 s.
        var shownTimecode = false
        /// Clips read and matched at once (1: one after the other, the overlap read piece by piece, no proxies: the old way, for checks).
        var width = CameraSync.width
        /// What's happening as it happens, to show it.
        var live: (@Sendable (Live) -> Void)?
    }

    enum Live: Sendable {
        case listening(UUID), heard(UUID)
        /// A clip's place found (by sound; the rest come at the end).
        case placed(SyncClip)
    }

    /// The camera the others are matched to: a sound recorder if there is one, else the camera with the most sound.
    static func master(_ cameras: [SyncCamera]) -> Int? {
        let withSound = cameras.indices.filter { cameras[$0].hasAudio }
        return withSound.first { cameras[$0].isSoundRecorder } ?? withSound.max { cameras[$0].audioLength < cameras[$1].audioLength }
    }

    /// What the sound of each clip is like, every 10 ms: the onset curve and its six bands.
    private struct Heard {
        var channels: [[Float]]
        var count: Int { channels.first?.count ?? 0 }
    }

    /// Syncs every clip that isn't locked: timecode (embedded or a slate) checked by sound, then
    /// sound, then light flashes (sound first with `audioFirst`); clock times give what's left a
    /// rough place. `progress` gets a share (0…1) and what's happening.
    static func sync(_ cameras: [SyncCamera], options: Options, progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) async -> [SyncCamera] {
        var cameras = cameras
        let all = cameras.indices.flatMap { c in cameras[c].clips.indices.map { (c, $0) } }
        for (c, i) in all where !cameras[c].clips[i].locked {
            cameras[c].clips[i].start = nil
            cameras[c].clips[i].method = nil
            cameras[c].clips[i].confidence = 0
            cameras[c].clips[i].drift = 0
            cameras[c].clips[i].rough = nil
        }
        for (c, i) in all { cameras[c].clips[i].slateOff = nil }
        // Timecode slates shown to the cameras (read once).
        let unread = all.filter { !cameras[$0.0].clips[$0.1].slateChecked && cameras[$0.0].clips[$0.1].hasVideo }
        if !unread.isEmpty { progress(0, String(localized: "Looking for timecode slates")) }
        let known = cameras
        let slates = await each(unread, width: options.width) { c, i in
            Task.isCancelled ? nil : await slate(known[c].clips[i], ffmpeg: options.ffmpeg, thorough: options.shownTimecode)
        }
        if Task.isCancelled { return cameras }
        for ((c, i), found) in zip(unread, slates) {
            cameras[c].clips[i].slate = found?.value
            cameras[c].clips[i].shown = found?.shown ?? []
            cameras[c].clips[i].slateChecked = true
        }
        let sound = await bySound(cameras, options: options, progress: progress)
        if Task.isCancelled { return sound }
        if !options.audioFirst, let placed = byTimecode(cameras, sound: sound) {
            cameras = placed
        } else {
            // Sound first: timecode where a camera's timecode agrees with its synced clips.
            cameras = sound
            progress(0.8, String(localized: "Checking timecode"))
            placeByTimecode(&cameras)
        }
        // Cameras without sound (or whose sound didn't match): light flashes.
        if all.contains(where: { cameras[$0.0].clips[$0.1].start == nil && cameras[$0.0].clips[$0.1].hasVideo }) {
            progress(0.85, String(localized: "Looking for flashes"))
            await placeByFlashes(&cameras, options: options)
        }
        joinRollovers(&cameras)
        for (c, i) in all where cameras[c].clips[i].start == nil { cameras[c].clips[i].rough = clockHint(cameras, c, i, shared: true) }
        checkSlates(&cameras)
        progress(1, "")
        return cameras
    }

    /// Every clip with sound placed by its sound alone (the master's frame, or the locked clips').
    private static func bySound(_ cameras: [SyncCamera], options: Options, progress: @escaping @Sendable (Double, String) -> Void) async -> [SyncCamera] {
        var cameras = cameras
        let all = cameras.indices.flatMap { c in cameras[c].clips.indices.map { (c, $0) } }
        // Matching by sound works in each clip's sound time (its sound can start a moment after its picture).
        func shift(_ sign: Double) {
            for (c, i) in all where cameras[c].clips[i].start != nil {
                cameras[c].clips[i].start! += sign * cameras[c].clips[i].audioOffset * (1 + cameras[c].clips[i].drift)
            }
        }
        shift(1)
        // 1. Listen to every clip (several at once; a clip's proxy where there is one: smaller, quicker over a network).
        let sounding = all.filter { cameras[$0.0].clips[$0.1].hasAudio }.map { cameras[$0.0].clips[$0.1] }
        let listened = Counter()
        let heardList = await each(sounding, width: options.width) { clip -> (UUID, Heard)? in
            if Task.isCancelled { return nil }
            // (Kept per file read: a proxy's rough listen isn't reused for its original.)
            let proxy = options.width > 1 ? clip.proxy.map { URL(fileURLWithPath: $0) } : nil
            if let known = options.cache?.heard(proxy?.path ?? clip.path) ?? (proxy != nil ? options.cache?.heard(clip.path) : nil) { return (clip.id, Heard(channels: known)) }
            options.live?(.listening(clip.id))
            defer { options.live?(.heard(clip.id)) }
            let number = listened.next()
            progress(Double(number) / Double(max(sounding.count, 1)) * 0.4, String(localized: "Listening to \(clip.name)"))
            // (The proxy only for this rough listen: the exact match reads the original.)
            var samples: [Float]?, read = clip.path
            if let proxy { samples = try? await AudioFeatures.samples(of: proxy, ffmpeg: options.ffmpeg); if samples != nil { read = proxy.path } }
            if samples == nil, let file = options.sound(clip) { samples = try? await AudioFeatures.samples(of: file, ffmpeg: options.ffmpeg) }
            guard let samples else { return nil }
            let features = AudioFeatures(samples: samples)
            // The first values jump just for the sound starting (nothing before it): left out, or every clip's start "matches".
            let skip = Int(AudioFeatures.latency / AudioFeatures.step) + 3
            let channels = ([features.onset] + features.bands).map { curve in curve.enumerated().map { $0.offset < skip ? 0 : $0.element } }
            options.cache?.keep(read, channels)
            return (clip.id, Heard(channels: channels))
        }
        let heard = Dictionary(heardList.compactMap { $0 }, uniquingKeysWith: { a, _ in a })
        if Task.isCancelled { return cameras }
        // 2. By sound: the master's longest clip first, then whatever matches what's placed, round by round.
        let master = Self.master(cameras)
        if !all.contains(where: { cameras[$0.0].clips[$0.1].start != nil }), let master,
           let anchor = cameras[master].clips.indices.filter({ heard[cameras[master].clips[$0].id] != nil })
            .max(by: { cameras[master].clips[$0].duration < cameras[master].clips[$1].duration }) {
            cameras[master].clips[anchor].start = 0
            cameras[master].clips[anchor].method = .audio
            cameras[master].clips[anchor].confidence = 1
            options.live?(.placed(cameras[master].clips[anchor]))
        }
        for round in 0..<8 {
            if Task.isCancelled { return cameras }
            let placed = all.filter { cameras[$0.0].clips[$0.1].start != nil && heard[cameras[$0.0].clips[$0.1].id] != nil }
            let waiting = all.filter { cameras[$0.0].clips[$0.1].start == nil && heard[cameras[$0.0].clips[$0.1].id] != nil }
            guard !placed.isEmpty, !waiting.isEmpty else { break }
            let composite = Composite(placed.map { (cameras[$0.0].clips[$0.1], heard[cameras[$0.0].clips[$0.1].id]!.channels) })
            let others = placed.map { cameras[$0.0].clips[$0.1] }
            let masterClips = master.map { Set(cameras[$0].clips.map(\.id)) } ?? []
            let known = cameras
            /// The clip at a coarse place, then exact against the placed clip it shares most with
            /// (another camera's; surer ones and the master's first, as a reference's drift carries over).
            @Sendable func refined(_ c: Int, _ clip: SyncClip, _ match: Match, quick: Bool) async -> (SyncClip, Fine?) {
                var clip = clip
                clip.start = match.start
                clip.drift = match.drift
                clip.confidence = match.confidence
                clip.method = .audio
                func worth(_ o: SyncClip) -> Double { overlap(o, clip) * o.confidence * (masterClips.contains(o.id) ? 2 : 1) * (o.drift == 0 ? 1.5 : 1) }
                guard let reference = others.filter({ o in !known[c].clips.contains { $0.id == o.id } && overlap(o, clip) > 10 }).max(by: { worth($0) < worth($1) })
                    ?? others.max(by: { overlap($0, clip) < overlap($1, clip) }),
                      overlap(reference, clip) > 1,
                      let fine = await fine(clip, reference: reference, around: match.at, options: options, windows: quick ? 3 : 24) else { return (clip, nil) }
                clip.start = fine.start
                clip.drift = fine.drift
                clip.confidence = min(1, (clip.confidence + fine.confidence) / 2 + 0.2)
                return (clip, fine)
            }
            // Each waiting clip against what was placed before this round (several at once).
            let matched = Counter()
            let results = await each(waiting, width: options.width) { (c, i) -> SyncClip? in
                if Task.isCancelled { return nil }
                let clip = known[c].clips[i]
                progress(0.4 + 0.35 * Double(matched.next()) / Double(waiting.count) / Double(round + 1), String(localized: "Matching \(clip.name)"))
                // Where the camera's clock puts it (its clock offset known from its placed clips) narrows the search.
                let hint = clip.clockFromFile ? nil : clockHint(known, c, i, shared: false)
                let matches = narrowed(coarse(heard[clip.id]!.channels, composite), hint: hint)
                guard let first = matches.first else { return nil }
                if first.confidence >= 0.35 { return await refined(c, clip, first, quick: false).0 }
                // Not clear from the onsets (a steady beat repeats): the likely places checked on the waveform itself.
                for match in matches {
                    let (found, fine) = await refined(c, clip, match, quick: true)
                    guard let fine, fine.confidence >= 0.5 else { continue }
                    var placed = await refined(c, clip, Match(start: found.start!, confidence: 0.3, at: match.at, drift: found.drift), quick: false).0
                    placed.confidence = max(placed.confidence, 0.5)
                    return placed
                }
                return nil
            }
            var found = 0
            for ((c, i), result) in zip(waiting, results) {
                guard let result else { continue }
                cameras[c].clips[i] = result
                found += 1
                // (Shown in picture time.)
                var shown = result
                shown.start! -= result.audioOffset * (1 + result.drift)
                options.live?(.placed(shown))
            }
            guard found > 0 else { break }
        }
        shift(-1)
        return cameras
    }

    /// How many clips are read at once: half the cores (each ffmpeg uses more than one).
    static let width = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount / 2))

    /// `work` on each item, `width` at a time; the results in the items' order.
    static func each<T: Sendable, R: Sendable>(_ items: [T], width: Int, _ work: @escaping @Sendable (T) async -> R) async -> [R] {
        await withTaskGroup(of: (Int, R).self) { group in
            var results = [R?](repeating: nil, count: items.count), next = 0
            for _ in 0..<min(max(width, 1), items.count) {
                let k = next
                group.addTask { (k, await work(items[k])) }
                next += 1
            }
            for await (k, result) in group {
                results[k] = result
                if next < items.count {
                    let k = next
                    group.addTask { (k, await work(items[k])) }
                    next += 1
                }
            }
            return results.map { $0! }
        }
    }

    /// 0, 1, 2… from any thread.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
    }

    /// How long two placed clips run at the same time.
    static func overlap(_ a: SyncClip, _ b: SyncClip) -> Double {
        guard let a0 = a.start, let a1 = a.end, let b0 = b.start, let b1 = b.end else { return 0 }
        return max(0, min(a1, b1) - max(a0, b0))
    }

    // MARK: Coarse: onset curves against everything placed so far

    /// Everything placed, on one timeline at 100 values a second: each clip's curves averaged where they overlap.
    private struct Composite {
        var origin: Double
        var channels: [[Float]]

        init(_ placed: [(SyncClip, [[Float]])]) {
            let step = AudioFeatures.step
            let first = placed.compactMap(\.0.start).min() ?? 0
            let last = placed.compactMap { $0.0.time(Double($0.1.first?.count ?? 0) * step) }.max() ?? first
            origin = first
            let length = Int(((last - first) / step).rounded()) + 1
            let bands = placed.first?.1.count ?? 0
            var sums = [[Float]](repeating: [Float](repeating: 0, count: length), count: bands)
            var counts = [Float](repeating: 0, count: length)
            for (clip, curves) in placed {
                guard let start = clip.start else { continue }
                for k in 0..<(curves.first?.count ?? 0) {
                    let index = Int(((start + Double(k) * step * (1 + clip.drift) - first) / step).rounded())
                    guard index >= 0, index < length else { continue }
                    counts[index] += 1
                    for b in 0..<bands { sums[b][index] += curves[b][k] }
                }
            }
            for b in 0..<bands { for k in 0..<length where counts[k] > 1 { sums[b][k] /= counts[k] } }
            channels = sums
        }
    }

    struct Match {
        /// Where the clip starts on the timeline.
        var start: Double
        var confidence: Double
        /// The clip-local time the match was measured around.
        var at: Double
        /// From where the pieces of the clip matched, when they don't agree with no drift.
        var drift = 0.0
    }

    /// The best place for a clip's sound: half-minute pieces of it (short, so slow drift doesn't
    /// blur the match) searched at 25 values a second, the best few places checked at 100, the
    /// clearest piece kept.
    /// The best first; then the other likely places of the same piece (a steady beat makes several), unconfirmed.
    private static func coarse(_ curves: [[Float]], _ composite: Composite) -> [Match] {
        let count = curves.first?.count ?? 0, piece = min(count, 3000)
        guard piece >= 300, (composite.channels.first?.count ?? 0) >= 300 else { return [] }
        // Half-minute pieces along the clip (up to eight), so a piece lies inside what's placed even when the clip only partly does.
        let pieces = count > piece ? min(8, Int(ceil(Double(count) / Double(piece) * 1.5))) : 1
        let starts = (0..<pieces).map { pieces == 1 ? 0 : (count - piece) * $0 / (pieces - 1) }
        let wide = composite.channels.map { decimated($0, 4) }
        var best: (lag: Int, from: Int, peak: Float, second: Float, others: [Int])?
        var clear: [(lag: Int, from: Int)] = []
        for from in Set(starts).sorted() {
            let part = curves.map { Array($0[from..<(from + piece)]) }
            let small = part.map { decimated($0, 4) }
            let minOverlap = max(Int(Double(small[0].count) * 0.5), 50)
            guard let scores = normalizedCorrelation(wide, small, minOverlap: minOverlap) else { continue }
            let peaks = topPeaks(scores.values, count: 5, apart: 3)
            guard let top = peaks.first else { continue }
            // The best other place (more than 0.3 s away): close to the peak, the match isn't sure (a loop, a steady beat).
            let second = scores.values.indices.filter { abs($0 - top) > 8 }.map { scores.values[$0] }.max() ?? 0
            // Each candidate at 100 a second, ±6 values around it.
            let refined = peaks.map { candidate -> (lag: Int, value: Float) in
                let centre = (candidate + scores.firstLag) * 4
                return ((centre - 6)...(centre + 6)).map { ($0, correlation(composite.channels, part, lag: $0, minOverlap: minOverlap * 4)) }
                    .max { $0.1 < $1.1 }!
            }
            guard let finest = refined.max(by: { $0.value < $1.value }) else { continue }
            let peak = scores.values[top]
            if peak > 0.1, second < peak * 0.8 { clear.append((finest.lag, from)) }
            if best == nil || peak - second > best!.peak - best!.second {
                best = (finest.lag, from, peak, second, refined.filter { $0.lag != finest.lag && $0.value > 0.05 }.map(\.lag))
            }
        }
        guard let best, best.peak > 0 else { return [] }
        let clarity = Double(1 - max(best.second, 0) / best.peak)
        var confidence = min(1, clarity / 0.4) * min(1, Double(best.peak) / 0.3)
        let step = AudioFeatures.step
        // Pieces that agree on one line: surer, and the line's slope is the drift (to 1/10,000 or so).
        var drift = 0.0
        let agreeing = clear.filter { $0.from != best.from }.compactMap { other -> Double? in
            let slope = Double(other.lag - best.lag) / Double(other.from - best.from) - 1
            return abs(slope) < 0.003 ? slope : nil
        }
        if !agreeing.isEmpty {
            drift = median(agreeing)
            if abs(drift) < 0.0001 { drift = 0 }
            confidence = min(1, confidence + 0.25 * Double(agreeing.count))
        }
        let at = Double(best.from + piece / 2) * step
        return [Match(start: composite.origin + (Double(best.lag) - Double(best.from) * (1 + drift)) * step, confidence: confidence, at: at, drift: drift)]
            + best.others.map { Match(start: composite.origin + Double($0 - best.from) * step, confidence: 0, at: at) }
    }

    /// Every `factor` values as their largest.
    static func decimated(_ values: [Float], _ factor: Int) -> [Float] {
        stride(from: 0, to: values.count, by: factor).map { values[$0..<min($0 + factor, values.count)].max() ?? 0 }
    }

    /// The highest local peaks, at least `apart` values from each other.
    static func topPeaks(_ values: [Float], count: Int, apart: Int) -> [Int] {
        var chosen: [Int] = []
        for index in values.indices.sorted(by: { values[$0] > values[$1] }) {
            if chosen.count == count { break }
            if chosen.allSatisfy({ abs($0 - index) > apart }) { chosen.append(index) }
        }
        return chosen
    }

    /// b laid at each place along a (b[0] at a[lag]), summed over channels, divided by both
    /// sides' energy where they overlap (1 is a perfect match). Places with less than `minOverlap`
    /// values in common are left out: `values[0]` is lag `firstLag`.
    static func normalizedCorrelation(_ a: [[Float]], _ b: [[Float]], minOverlap: Int) -> (firstLag: Int, values: [Float])? {
        let na = a.first?.count ?? 0, nb = b.first?.count ?? 0
        let firstLag = minOverlap - nb, lastLag = na - minOverlap
        guard na > 0, nb > 0, firstLag <= lastLag else { return nil }
        var sum = [Float](repeating: 0, count: lastLag - firstLag + 1)
        var energyA = [Double](repeating: 0, count: na + 1), energyB = [Double](repeating: 0, count: nb + 1)
        for channel in 0..<min(a.count, b.count) {
            let raw = crossCorrelation(a[channel], b[channel])
            let n = raw.count
            for (index, lag) in (firstLag...lastLag).enumerated() { sum[index] += raw[(lag % n + n) % n] }
            for k in 0..<na { energyA[k + 1] += Double(a[channel][k] * a[channel][k]) }
            for k in 0..<nb { energyB[k + 1] += Double(b[channel][k] * b[channel][k]) }
        }
        for k in 0..<na { energyA[k + 1] += energyA[k] }
        for k in 0..<nb { energyB[k + 1] += energyB[k] }
        for (index, lag) in (firstLag...lastLag).enumerated() {
            let i0 = max(0, -lag), i1 = min(nb, na - lag)
            let ea = energyA[lag + i1] - energyA[lag + i0], eb = energyB[i1] - energyB[i0]
            sum[index] = ea > 0 && eb > 0 ? sum[index] / Float(sqrt(ea * eb)) : 0
        }
        return (firstLag, sum)
    }

    /// The same at one lag, worked out directly.
    private static func correlation(_ a: [[Float]], _ b: [[Float]], lag: Int, minOverlap: Int) -> Float {
        let na = a.first?.count ?? 0, nb = b.first?.count ?? 0
        let i0 = max(0, -lag), i1 = min(nb, na - lag)
        guard i1 - i0 >= minOverlap else { return -1 }
        var dot: Float = 0, ea: Float = 0, eb: Float = 0
        for channel in 0..<min(a.count, b.count) {
            a[channel].withUnsafeBufferPointer { pa in
                b[channel].withUnsafeBufferPointer { pb in
                    var d: Float = 0, x: Float = 0, y: Float = 0
                    let length = vDSP_Length(i1 - i0)
                    vDSP_dotpr(pa.baseAddress! + lag + i0, 1, pb.baseAddress! + i0, 1, &d, length)
                    vDSP_svesq(pa.baseAddress! + lag + i0, 1, &x, length)
                    vDSP_svesq(pb.baseAddress! + i0, 1, &y, length)
                    dot += d; ea += x; eb += y
                }
            }
        }
        return ea > 0 && eb > 0 ? dot / sqrt(ea * eb) : 0
    }

    /// r[k] = Σ a[k + i] · b[i], circular over a power-of-two length ≥ both (negative k at the end).
    /// `whiten`: each frequency weighed the same (GCC-PHAT), for a sharp peak at the exact delay.
    static func crossCorrelation(_ a: [Float], _ b: [Float], whiten: ClosedRange<Double>? = nil) -> [Float] {
        let need = a.count + b.count
        var log2n = 1
        while (1 << log2n) < need { log2n += 1 }
        let n = 1 << log2n, half = n / 2
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        func forward(_ x: [Float]) -> ([Float], [Float]) {
            var padded = x + [Float](repeating: 0, count: n - x.count)
            var real = [Float](repeating: 0, count: half), imaginary = [Float](repeating: 0, count: half)
            real.withUnsafeMutableBufferPointer { r in
                imaginary.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    padded.withUnsafeMutableBufferPointer { p in
                        p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
                    }
                    vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
                }
            }
            return (real, imaginary)
        }
        let (ar, ai) = forward(a), (br, bi) = forward(b)
        var real = [Float](repeating: 0, count: half), imaginary = [Float](repeating: 0, count: half)
        // (Packed: bin 0 holds DC in the real part and Nyquist in the imaginary one.)
        real[0] = whiten == nil ? ar[0] * br[0] : 0
        imaginary[0] = whiten == nil ? ai[0] * bi[0] : 0
        for k in 1..<half {
            var r = ar[k] * br[k] + ai[k] * bi[k], i = ai[k] * br[k] - ar[k] * bi[k]
            if let whiten {
                let hz = Double(k) / Double(n) * AudioFeatures.sampleRate
                let size = sqrt(r * r + i * i)
                if whiten.contains(hz), size > 1e-12 { r /= size; i /= size } else { r = 0; i = 0 }
            }
            real[k] = r
            imaginary[k] = i
        }
        var out = [Float](repeating: 0, count: n)
        real.withUnsafeMutableBufferPointer { r in
            imaginary.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(FFT_INVERSE))
                out.withUnsafeMutableBufferPointer { o in
                    o.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half)) }
                }
            }
        }
        var scale = 1 / Float(4 * n)
        vDSP_vsmul(out, 1, &scale, &out, 1, vDSP_Length(n))
        return out
    }

    // MARK: Fine: the waveforms themselves, along the overlap

    struct Fine {
        var start: Double
        var drift: Double
        var confidence: Double
        /// How far the measurements are from the fitted line (seconds).
        var spread: Double
    }

    /// Four-second pieces of the clip's sound matched sample by sample (GCC-PHAT at 8 kHz, to a
    /// fraction of a sample) against the reference, from where the coarse match was outwards,
    /// each one searched close to where the ones before put it. A straight line through them gives
    /// the exact start and the drift between the two clocks.
    static func fine(_ clip: SyncClip, reference: SyncClip, around: Double, options: Options, windows: Int = 24) async -> Fine? {
        // (ffmpeg seeks from the file's start: the picture's, when the sound starts after it.)
        let skipClip = max(0, clip.audioOffset), skipReference = max(0, reference.audioOffset)
        guard let start = clip.start, let refStart = reference.start, let clipSound = options.sound(clip), let refSound = options.sound(reference) else { return nil }
        let rate = AudioFeatures.sampleRate, window = 4.0
        // The overlap in the clip's own time.
        let from = max(0, (refStart - start) / (1 + clip.drift)), to = min(clip.duration, (reference.end! - start) / (1 + clip.drift))
        guard to - from >= window + 0.5 else { return nil }
        let count = min(max(Int((to - from) / 8), 2), 24)
        let centres = (0..<count).map { from + window / 2 + 0.2 + Double($0) * (to - from - window - 0.4) / Double(max(count - 1, 1)) }
            .sorted { abs($0 - around) < abs($1 - around) }.prefix(windows)
        // The overlap read once from each file (not a read per piece), when it isn't long: the pieces are cut from it.
        // shortcut: over 20 minutes of overlap is read piece by piece (memory); a chunked read would suit hour-long takes.
        var clipSpan: (from: Double, samples: [Float])?, refSpan: (from: Double, samples: [Float])?
        if options.width > 1, to - from <= 1200 {
            let e0 = (1 + clip.drift) / (1 + reference.drift) - 1, c0 = (start - refStart) / (1 + reference.drift)
            let y0 = max(0, c0 + from * (1 + e0) - 1), y1 = min(reference.duration, c0 + to * (1 + e0) + 1)
            async let a = try? AudioFeatures.samples(of: clipSound, ffmpeg: options.ffmpeg, from: from + skipClip, duration: to - from)
            async let b = y1 > y0 ? try? AudioFeatures.samples(of: refSound, ffmpeg: options.ffmpeg, from: y0 + skipReference, duration: y1 - y0) : nil
            if let a = await a { clipSpan = (from + skipClip, a) }
            if let b = await b { refSpan = (y0 + skipReference, b) }
        }
        func piece(_ file: URL, _ span: (from: Double, samples: [Float])?, from at: Double, duration: Double) async -> [Float]? {
            if let span {
                let i0 = Int(((at - span.from) * rate).rounded()), n = Int((duration * rate).rounded())
                if i0 >= 0, i0 + n <= span.samples.count { return Array(span.samples[i0..<(i0 + n)]) }
            }
            return try? await AudioFeatures.samples(of: file, ffmpeg: options.ffmpeg, from: at, duration: duration)
        }
        var points: [(x: Double, y: Double, weight: Double)] = []
        // The reference's own time for a clip time, from the points so far (coarse at first).
        func line() -> (c: Double, e: Double) {
            guard points.count >= 2, let lo = points.map(\.x).min(), let hi = points.map(\.x).max(), hi - lo > 8 else {
                let c = points.isEmpty ? (start - refStart) / (1 + reference.drift) : median(points.map { $0.y - $0.x })
                return (c, points.isEmpty ? (1 + clip.drift) / (1 + reference.drift) - 1 : 0)
            }
            return fit(points)
        }
        for centre in centres {
            if Task.isCancelled { return nil }
            let (c, e) = line()
            let nearest = points.map { abs($0.x - centre) }.min()
            let margin = nearest.map { points.count >= 2 ? 0.012 + 0.0004 * $0 : 0.04 + 0.0015 * $0 } ?? 0.06
            let predicted = c + centre * (1 + e)
            // The clip's piece stretched to the reference's clock, so drift doesn't blur the match.
            let x0 = centre - window / 2, span = window * (1 + e), y0 = predicted - span / 2 - margin
            guard y0 >= 0, predicted + span / 2 + margin <= reference.duration,
                  let a = await piece(refSound, refSpan, from: y0 + skipReference, duration: span + 2 * margin),
                  let raw = await piece(clipSound, clipSpan, from: x0 + skipClip, duration: window),
                  raw.count > Int(window * rate * 0.9) else { continue }
            let b = abs(e) < 1e-6 ? raw : (0..<Int(Double(raw.count) * (1 + e))).map { j -> Float in
                let at = Double(j) / (1 + e), i = Int(at), f = Float(at - Double(i))
                return i + 1 < raw.count ? raw[i] * (1 - f) + raw[i + 1] * f : raw[raw.count - 1]
            }
            let r = crossCorrelation(a, b, whiten: 80...3800)
            let range = 0...min(Int(2 * margin * rate), r.count - 2)
            guard let peak = range.max(by: { r[$0] < r[$1] }) else { continue }
            let values = range.map { Double(r[$0]) }
            let mean = values.reduce(0, +) / Double(values.count)
            let deviation = sqrt(values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count))
            let sharpness = deviation > 0 ? (Double(r[peak]) - mean) / deviation : 0
            guard sharpness > 7 else { continue }
            // Between samples: a parabola through the peak and its neighbours.
            var shift = 0.0
            if peak > 0, peak + 1 < r.count {
                let l = Double(r[peak - 1]), m = Double(r[peak]), h = Double(r[peak + 1]), d = l - 2 * m + h
                if d < 0 { shift = max(-0.5, min(0.5, 0.5 * (l - h) / d)) }
            }
            points.append((centre, y0 + (Double(peak) + shift) / rate + span / 2, min(sharpness / 12, 1)))
        }
        guard !points.isEmpty else { return nil }
        // Points far off the line (a wrong peak) out, then the line again.
        var (c, e) = line()
        let kept = points.filter { abs($0.y - (c + $0.x * (1 + e))) < 0.003 }
        if kept.count >= max(2, points.count / 2) { points = kept; (c, e) = line() }
        // Too little to tell drift from noise: none.
        let span = (points.map(\.x).max() ?? 0) - (points.map(\.x).min() ?? 0)
        if abs(e) * span < 0.0008 { e = 0; c = median(points.map { $0.y - $0.x }) }
        let spread = sqrt(points.map { pow($0.y - (c + $0.x * (1 + e)), 2) }.reduce(0, +) / Double(points.count))
        let weight = points.map(\.weight).reduce(0, +) / Double(points.count)
        let confidence = min(1, Double(points.count) / 3) * weight * (spread < 0.002 ? 1 : 0.6)
        // tRef = c + t (1 + e), timeline = refStart + tRef (1 + dRef).
        var drift = (1 + e) * (1 + reference.drift) - 1
        // (A reference's drift measured back out again leaves a trace: under half a millisecond over the clip is none.)
        if abs(drift) * clip.duration < 0.0005 { drift = 0 }
        return Fine(start: refStart + c * (1 + reference.drift), drift: drift, confidence: confidence, spread: spread)
    }

    /// y = c + x (1 + e), weighted least squares.
    private static func fit(_ points: [(x: Double, y: Double, weight: Double)]) -> (c: Double, e: Double) {
        let w = points.map(\.weight).reduce(0, +)
        let mx = points.map { $0.x * $0.weight }.reduce(0, +) / w, my = points.map { $0.y * $0.weight }.reduce(0, +) / w
        let sxx = points.map { $0.weight * ($0.x - mx) * ($0.x - mx) }.reduce(0, +)
        let sxy = points.map { $0.weight * ($0.x - mx) * ($0.y - my) }.reduce(0, +)
        let slope = sxx > 0 ? sxy / sxx : 1
        return (my - slope * mx, slope - 1)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    // MARK: Timecode

    /// A camera whose timecode agrees with where its clips' sound put them (two or more within a
    /// frame, or one) places its other clips by timecode. A camera with no synced clip uses the
    /// others' timecode when they all agree with each other (jam-synced).
    static func placeByTimecode(_ cameras: inout [SyncCamera]) {
        func offsets(_ camera: SyncCamera) -> [Double] {
            camera.clips.filter { $0.method == .audio && $0.confidence >= 0.5 }.compactMap { clip in clip.timecode.flatMap { tc in clip.start.map { $0 - tc } } }
        }
        let shared: Double? = {
            let all = cameras.map(offsets).filter { !$0.isEmpty }.map(median)
            guard all.count >= 2, let lo = all.min(), let hi = all.max(), hi - lo < 0.04 else { return nil }
            return median(all)
        }()
        for c in cameras.indices {
            let own = offsets(cameras[c])
            let fps = cameras[c].clips.first?.fps ?? 0, frame = 1 / (fps > 0 ? fps : 25)
            var offset: Double?, confidence = 0.0
            if own.count >= 2, let lo = own.min(), let hi = own.max(), hi - lo <= frame { offset = median(own); confidence = 0.85 }
            else if own.count == 1 { offset = own[0]; confidence = 0.55 }
            else if own.isEmpty, let shared { offset = shared; confidence = 0.6 }
            guard let offset else { continue }
            for i in cameras[c].clips.indices where cameras[c].clips[i].start == nil && !cameras[c].clips[i].locked {
                guard let tc = cameras[c].clips[i].timecode else { continue }
                cameras[c].clips[i].start = tc + offset
                cameras[c].clips[i].method = .timecode
                cameras[c].clips[i].confidence = confidence
            }
        }
    }

    /// A clip's timecode if it can be used: there, within a day, at a plausible rate.
    static func usableTimecode(_ clip: SyncClip) -> Double? {
        guard let tc = clip.timecode, tc >= 0, tc < 86400 * 1.001, !clip.hasVideo || (1...240).contains(clip.fps) else { return nil }
        return tc
    }

    /// The middle of the largest set of values within `tolerance` of one (ties: the earliest in the list), and which they are.
    static func consensus(_ values: [Double], tolerance: Double) -> (value: Double, members: [Int])? {
        var best: [Int] = []
        for value in values {
            let members = values.indices.filter { abs(values[$0] - value) <= tolerance }
            if members.count > best.count { best = members }
        }
        return best.isEmpty ? nil : (median(best.map { values[$0] }), best)
    }

    /// Timecode first: each camera's clips at their timecode (clips without it but showing a slate
    /// at the slate's), the timeline in timecode. The sound only checks it: a camera whose timecode
    /// is off from the sound by one amount (a clock not jam-synced) moves by that amount, a clip
    /// whose timecode jumped from its camera's goes by its sound. Clips without timecode go by
    /// their sound. Nil when there's no timecode, or it can't be tied to the sound placed.
    static func byTimecode(_ cameras: [SyncCamera], sound: [SyncCamera]) -> [SyncCamera]? {
        struct Source { var c: Int; var i: Int; var value: Double; var check: Double? }
        func heard(_ c: Int, _ i: Int) -> SyncClip? {
            let clip = sound[c].clips[i]
            // (Only sure matches check timecode: a repeating beat can match a clip one bar off.)
            return clip.start != nil && (clip.locked || (clip.method == .audio && clip.confidence >= 0.7)) ? clip : nil
        }
        // A group per camera's timecode, one for the slates (a clock of their own).
        var groups: [Int: [Source]] = [:]
        for c in cameras.indices {
            for (i, clip) in cameras[c].clips.enumerated() {
                let value = usableTimecode(clip), key = value != nil ? c : -1
                guard let value = value ?? clip.slate else { continue }
                groups[key, default: []].append(Source(c: c, i: i, value: value, check: heard(c, i).map { $0.start! - value }))
            }
        }
        guard !groups.isEmpty else { return nil }
        // (A sound recorder, no picture rate: a 25 fps frame.)
        func frame(_ sources: [Source]) -> Double { let fps = cameras[sources[0].c].clips[sources[0].i].fps; return 1 / (fps > 0 ? fps : 25) }
        // Each group's offset from the sound, then the one most groups share: the sound's place in timecode.
        var own: [Int: (value: Double, members: Set<Int>)] = [:]
        for (key, sources) in groups {
            let checks = sources.indices.filter { sources[$0].check != nil }
            guard let agreed = consensus(checks.map { sources[$0].check! }, tolerance: frame(sources)) else { continue }
            own[key] = (agreed.value, Set(agreed.members.map { checks[$0] }))
        }
        let ranked = own.sorted { ($0.value.members.count, -$0.key) > ($1.value.members.count, -$1.key) }
        let shared: Double
        if let agreed = consensus(ranked.map(\.value.value), tolerance: 1.0 / 25) {
            shared = agreed.value
        } else if sound.flatMap(\.clips).contains(where: { $0.method == .audio && !$0.locked }) {
            // shortcut: timecode that no sound ties to the sound placed: sound first; a flash check could tie them.
            return nil
        } else {
            shared = 0
        }
        var cameras = cameras
        var placed = Set<String>()
        for (key, sources) in groups {
            let half = frame(sources) / 2
            var offset = own[key].map { $0.value - shared } ?? 0
            if abs(offset) < half { offset = 0 }
            for (n, source) in sources.enumerated() where !cameras[source.c].clips[source.i].locked {
                placed.insert("\(source.c)/\(source.i)")
                if let check = source.check, let agreed = own[key], !agreed.members.contains(n), abs(check - agreed.value) > half * 2,
                   let by = heard(source.c, source.i) {
                    // Its timecode jumped: by its sound.
                    cameras[source.c].clips[source.i].start = by.start! - shared
                    cameras[source.c].clips[source.i].drift = by.drift
                    cameras[source.c].clips[source.i].method = .audio
                    cameras[source.c].clips[source.i].confidence = by.confidence
                    continue
                }
                cameras[source.c].clips[source.i].start = source.value + offset
                cameras[source.c].clips[source.i].method = key == -1 ? .slate : offset == 0 ? .timecode : .timecodeOffset
                // A slate read once only (no second frame agreeing) and nothing heard to confirm it: to check.
                let once = key == -1 && cameras[source.c].clips[source.i].shown.filter(\.agrees).count < 2
                cameras[source.c].clips[source.i].confidence = source.check != nil || offset != 0 ? 0.95 : once ? 0.5 : 0.8
            }
        }
        for c in cameras.indices {
            for i in cameras[c].clips.indices where !placed.contains("\(c)/\(i)") && !cameras[c].clips[i].locked {
                guard let by = sound[c].clips[i].start else { continue }
                cameras[c].clips[i].start = by - shared
                cameras[c].clips[i].drift = sound[c].clips[i].drift
                cameras[c].clips[i].method = sound[c].clips[i].method
                cameras[c].clips[i].confidence = sound[c].clips[i].confidence
            }
        }
        return cameras
    }

    // MARK: Recorder rollover

    /// A sound recorder's next file continues the take (it split at a size limit): it starts where
    /// the one before ends, by timecode (BWF) or, without, by its date and a name in common.
    static func rollsOver(_ a: SyncClip, _ b: SyncClip) -> Bool {
        guard !a.hasVideo, !b.hasVideo, a.duration > 0, a.file.deletingLastPathComponent() == b.file.deletingLastPathComponent() else { return false }
        if let x = a.timecode, let y = b.timecode { return abs(y - (x + a.duration)) < 0.05 }
        guard let x = a.created, let y = b.created, !a.clockFromFile, !b.clockFromFile else { return false }
        return abs(y.timeIntervalSince(x) - a.duration) < 2 && a.name.prefix(4).uppercased() == b.name.prefix(4).uppercased()
    }

    /// A recorder's split files as one continuous lane: each piece right after the one before, from the
    /// surest placed piece of the take (a piece held by hand stays, the ones after it follow it).
    static func joinRollovers(_ cameras: inout [SyncCamera]) {
        for c in cameras.indices where cameras[c].isSoundRecorder {
            var runs: [[Int]] = []
            for i in cameras[c].clips.indices {
                if let last = runs.last?.last, rollsOver(cameras[c].clips[last], cameras[c].clips[i]) { runs[runs.count - 1].append(i) } else { runs.append([i]) }
            }
            for run in runs where run.count > 1 {
                func sure(_ i: Int) -> Double { let clip = cameras[c].clips[i]; return clip.locked ? 2 : clip.confidence }
                guard let anchor = run.filter({ cameras[c].clips[$0].start != nil }).max(by: { sure($0) < sure($1) }), let at = run.firstIndex(of: anchor) else { continue }
                func follow(_ i: Int, from k: Int, after: Bool) {
                    guard !cameras[c].clips[i].locked, let start = cameras[c].clips[k].start else { return }
                    let from = cameras[c].clips[k], drift = from.drift
                    cameras[c].clips[i].start = after ? start + from.duration * (1 + drift) : start - cameras[c].clips[i].duration * (1 + drift)
                    cameras[c].clips[i].drift = drift
                    cameras[c].clips[i].method = from.method
                    cameras[c].clips[i].confidence = from.confidence
                    cameras[c].clips[i].rough = nil
                }
                for n in run.indices.dropFirst(at + 1) { follow(run[n], from: run[n - 1], after: true) }
                for n in stride(from: at - 1, through: 0, by: -1) { follow(run[n], from: run[n + 1], after: false) }
            }
        }
    }

    // MARK: Clock time

    /// Where a clip's clock time puts it (a hint, never a sync), with its camera's clock offset
    /// from its placed clips (a wrong clock or time zone is one offset), else, if `shared`, the other cameras'.
    /// shortcut: a camera that dates its files at the end of a take has offsets that vary with take length.
    static func clockHint(_ cameras: [SyncCamera], _ c: Int, _ i: Int, shared: Bool) -> Double? {
        let clip = cameras[c].clips[i]
        guard let created = clip.created?.timeIntervalSince1970 else { return nil }
        func offsets(_ camera: SyncCamera) -> [Double] {
            camera.clips.compactMap { k in
                guard let start = k.start, let date = k.created, k.clockFromFile == clip.clockFromFile else { return nil }
                return start - date.timeIntervalSince1970
            }
        }
        let own = offsets(cameras[c])
        if !own.isEmpty { return created + median(own) }
        let others = cameras.map(offsets).filter { !$0.isEmpty }.map(median)
        return shared && !others.isEmpty ? created + median(others) : nil
    }

    /// The sound matches near where the clock puts a clip (all of them if none is near, or there's no clock).
    static func narrowed(_ matches: [Match], hint: Double?, window: Double = 600) -> [Match] {
        guard let hint else { return matches }
        let near = matches.filter { abs($0.start - hint) < window }
        return near.isEmpty ? matches : near
    }

    // MARK: Timecode slates

    /// Timecode shown to the camera (a slate app, a smart slate, burned-in: big HH:MM:SS:FF digits): what it
    /// reads at the clip's first frame (half a shown frame later: a frame shows the one begun before it),
    /// and every reading. Quick: a frame at the start and near the end, a dozen where one shows a timecode,
    /// two readings at least. `thorough`: a frame every 2 s through the first and last 10 s (a few in between
    /// if none), a dozen at the first that shows one; one reading is enough (its confidence is low).
    /// The slate's rate: the clip's, half it, 24, 25, 30 (50/60/120 past those), above the highest frame shown, whichever more readings agree on.
    /// shortcut: 24/30/60 count 1001/1000 longer only on a 23.976/29.97/59.94 camera (a 23.976 slate filmed at 25 reads as 24); RED/BRAW aren't read.
    static func slate(_ clip: SyncClip, ffmpeg: String, thorough: Bool = false) async -> (value: Double, shown: [ShownTimecode])? {
        guard clip.hasVideo, clip.fps > 0, !RawFormats.isRawVideo(clip.file) else { return nil }
        return await Task.detached { () -> (value: Double, shown: [ShownTimecode])? in
            let last = max(0, Int(clip.duration * clip.fps) - 1)
            func at(_ seconds: Double) -> Int { min(last, max(0, Int(seconds * clip.fps))) }
            var spots = thorough ? stride(from: 0.0, to: 10, by: 2).map(at) + stride(from: 10.0, to: 0, by: -2).map { at(clip.duration - $0) }
                : [0, at(clip.duration - 1.5)]
            spots = Array(Set(spots)).sorted()
            var readings: [(frame: Int, tc: [Int], drop: Bool)] = []
            func look(_ spots: [Int]) {
                for spot in spots {
                    // (A quarter frame early: ffmpeg starts at the frame there.)
                    let from = spot == 0 ? 0 : (Double(spot) - 0.25) / clip.fps
                    guard let first = frames(clip.file, from: from, count: 1, ffmpeg: ffmpeg).first, let read = readTimecode(first) else { continue }
                    guard !thorough || readings.isEmpty else { readings.append((spot, read.tc, read.drop)); continue }
                    // A dozen frames where a timecode shows first: its readings, and the slate's rate from its highest frame number.
                    for (k, image) in frames(clip.file, from: from, count: 12, ffmpeg: ffmpeg).enumerated() {
                        if let read = readTimecode(image) { readings.append((spot + k, read.tc, read.drop)) }
                    }
                }
            }
            look(spots)
            if thorough, readings.isEmpty, clip.duration > 25 { look((1...4).map { at(clip.duration * Double($0) / 5) }) }
            guard readings.count >= (thorough ? 1 : 2), let most = readings.map({ $0.tc[3] }).max() else { return nil }
            let own = clip.fps.rounded(), ntsc = abs(clip.fps - own) > 0.01
            // (A 50p camera filming a 25 slate shows each frame twice and never frame 25 or more: at 50 it'd be up to half a second off.)
            var rates: [Double] = []
            for rate in [own, own / 2, 24, 25, 30, 50, 60, 120] where rate == rate.rounded() && Double(most) < rate && !rates.contains(rate) { rates.append(rate) }
            // A slate on a 29.97/59.94 camera counts frames 1001/1000 longer, drop frame or not: whichever more readings agree on
            // (a ; is often read as a :), drop frame on a tie where one showed a ; or .
            let shownDrop = readings.contains(where: \.drop)
            func agreement(_ rate: Double, _ fractional: Bool, _ drop: Bool) -> (value: Double, members: [Int])? {
                var offsets = readings.map { shownSeconds($0.tc, drop: drop, rate: rate, fractional: fractional) - Double($0.frame) / clip.fps }
                // Past midnight.
                if let high = offsets.max() { offsets = offsets.map { high - $0 > 43200 ? $0 + 86400 : $0 } }
                return consensus(offsets, tolerance: 1 / rate)
            }
            // (Ties: the first, the clip's own rate.)
            let tried = rates.flatMap { rate in
                let fractional = ntsc && [24.0, 30, 48, 60, 120].contains(rate)
                return (fractional ? [shownDrop, !shownDrop] : [false]).compactMap { drop in agreement(rate, fractional, drop).map { (rate, fractional, drop, $0) } }
            }
            guard let (rate, fractional, drop, agreed) = tried.max(by: { $0.3.members.count < $1.3.members.count }), agreed.members.count >= (thorough ? 1 : 2) else { return nil }
            let members = Set(agreed.members)
            let shown = readings.enumerated().map { k, reading in
                ShownTimecode(frame: reading.frame, text: timecodeText(reading.tc, drop: drop && fractional), agrees: members.contains(k))
            }
            return (agreed.value + 0.5 / rate, shown)
        }.value
    }

    /// A shown timecode in seconds: whole seconds and frames at an integer `rate`; with `fractional` (29.97,
    /// 59.94) counted in frames of 1001/1000 longer, drop frame skipping the frame numbers drop frame skips.
    static func shownSeconds(_ tc: [Int], drop: Bool, rate: Double, fractional: Bool) -> Double {
        let whole = (tc[0] * 60 + tc[1]) * 60 + tc[2]
        guard fractional else { return Double(whole) + Double(tc[3]) / rate }
        let base = Int(rate)
        var frames = whole * base + tc[3]
        if drop, base % 30 == 0 {
            let minutes = tc[0] * 60 + tc[1]
            frames -= base / 15 * (minutes - minutes / 10)
        }
        return Double(frames) * 1001 / (rate * 1000)
    }

    static func timecodeText(_ tc: [Int], drop: Bool) -> String {
        String(format: "%02d:%02d:%02d", tc[0], tc[1], tc[2]) + (drop ? ";" : ":") + String(format: "%02d", tc[3])
    }

    /// `count` frames from `from` seconds, small and grey.
    static func frames(_ file: URL, from: Double, count: Int, ffmpeg: String) -> [CGImage] {
        let width = 960, height = 540, size = width * height
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-nostdin", "-v", "error", "-ss", String(from), "-i", file.path, "-an", "-map", "0:v:0", "-frames:v", String(count),
                             "-vf", "scale=\(width):\(height),format=gray", "-f", "rawvideo", "-"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return stride(from: 0, to: data.count - size + 1, by: size).compactMap { offset in
            guard let provider = CGDataProvider(data: data.subdata(in: offset..<offset + size) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
    }

    /// The timecode a picture shows in big digits, if any: [hours, minutes, seconds, frames], and whether it's drop frame (; or . before the frames).
    static func readTimecode(_ image: CGImage) -> (tc: [Int], drop: Bool)? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return nil }
        for observation in request.results ?? [] {
            for candidate in observation.topCandidates(3) {
                if let tc = parseTimecode(candidate.string) { return (tc, candidate.string.last { !$0.isNumber && !$0.isWhitespace }.map { ";.".contains($0) } ?? false) }
            }
        }
        return nil
    }

    /// Eight digits and nothing but separators between them ("10:00:51:03", "10 00 51 03") as a valid timecode.
    static func parseTimecode(_ text: String) -> [Int]? {
        guard !text.contains(where: \.isLetter) else { return nil }
        let digits = text.compactMap(\.wholeNumberValue)
        guard digits.count == 8 else { return nil }
        let parts = stride(from: 0, to: 8, by: 2).map { digits[$0] * 10 + digits[$0 + 1] }
        return parts[0] < 24 && parts[1] < 60 && parts[2] < 60 && parts[3] < 120 ? parts : nil
    }

    /// Clips that show a slate, synced: the slate times at their places must agree; the frames off where they don't.
    static func checkSlates(_ cameras: inout [SyncCamera]) {
        let shown = cameras.indices.flatMap { c in cameras[c].clips.indices.filter { cameras[c].clips[$0].slate != nil && cameras[c].clips[$0].start != nil }.map { (c, $0) } }
        let values = shown.map { cameras[$0.0].clips[$0.1].slate! - cameras[$0.0].clips[$0.1].start! }
        guard shown.count >= 2, let agreed = consensus(values, tolerance: 1.0 / 25) else { return }
        for (k, (c, i)) in shown.enumerated() {
            let frames = abs(values[k] - agreed.value) * max(cameras[c].clips[i].fps, 1)
            if frames > 1.5 { cameras[c].clips[i].slateOff = Int(frames.rounded()) }
        }
    }

    // MARK: Flashes

    /// How much brighter each frame is than the one before (only brighter), in units of the
    /// clip's usual change: a flash, a strobe or pyro stands out as a big number.
    static func flashes(_ file: URL, ffmpeg: String) async -> [Float]? {
        await Task.detached { () -> [Float]? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = ["-nostdin", "-v", "error", "-i", file.path, "-an", "-map", "0:v:0", "-fps_mode", "passthrough",
                                 "-vf", "scale=32:18,format=gray", "-f", "rawvideo", "-"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let size = 32 * 18
            guard data.count >= size * 2 else { return nil }
            let luma: [Float] = data.withUnsafeBytes { bytes in
                stride(from: 0, to: data.count - size + 1, by: size).map { offset in
                    var sum = 0
                    for k in 0..<size { sum += Int(bytes[offset + k]) }
                    return Float(sum) / Float(size)
                }
            }
            var rises = [Float](repeating: 0, count: luma.count)
            for k in 1..<luma.count { rises[k] = max(0, luma[k] - luma[k - 1]) }
            let usual = median(luma.indices.dropFirst().map { Double(abs(luma[$0] - luma[$0 - 1])) })
            return rises.map { $0 / Float(usual + 0.5) }
        }.value
    }

    /// Clips with a picture but no place yet, matched on the flashes the synced cameras saw: the
    /// rises in brightness at 100 values a second, the best place, then the median gap between
    /// matching flashes for the last fraction of a frame.
    /// shortcut: only the two synced cameras with the most footage that ffmpeg decodes are looked at (not RED/BRAW); add more if a show needs it.
    static func placeByFlashes(_ cameras: inout [SyncCamera], options: Options) async {
        let step = AudioFeatures.step
        let decodable = { (clip: SyncClip) in clip.hasVideo && !RawFormats.isRawVideo(clip.file) }
        let known = cameras
        let references = known.indices
            .filter { c in known[c].clips.contains { $0.start != nil && $0.method != .flashes && decodable($0) } }
            .sorted { a, b in
                let length = { (c: Int) in known[c].clips.filter { $0.start != nil }.map(\.duration).reduce(0, +) }
                return length(a) > length(b)
            }
            .prefix(2)
        guard !references.isEmpty else { return }
        // Every picture needed, read at once (several at a time).
        let waiting = cameras.flatMap(\.clips).filter { $0.start == nil && $0.hasVideo && !$0.locked && decodable($0) }
        let wanted = references.flatMap { c in known[c].clips.filter { $0.start != nil && decodable($0) } } + waiting
        let read = await each(wanted, width: options.width) { clip in Task.isCancelled ? nil : await flashes(clip.file, ffmpeg: options.ffmpeg) }
        let risesOf = Dictionary(zip(wanted.map(\.id), read).compactMap { id, rises in rises.map { (id, $0) } }, uniquingKeysWith: { a, _ in a })
        var events: [Double] = []
        var placed: [(SyncClip, [Float])] = []
        for c in references {
            for clip in cameras[c].clips where clip.start != nil && decodable(clip) {
                guard let rises = risesOf[clip.id] else { continue }
                placed.append((clip, rises))
                for (k, value) in rises.enumerated() where value > 8 && (k == 0 || rises[k - 1] <= 8) {
                    if let t = clip.time(Double(k) / clip.fps) { events.append(t) }
                }
            }
        }
        guard !placed.isEmpty else { return }
        let origin = placed.compactMap(\.0.start).min()!
        let length = Int(((placed.compactMap(\.0.end).max()! - origin) / step).rounded()) + 1
        var timeline = [Float](repeating: 0, count: length)
        // Each frame over the time it shows (cameras' frames fall at different moments).
        func lay(_ value: Float, from t: Double, frame: Double, into values: inout [Float]) {
            let a = Int((t / step).rounded()), b = max(Int(((t + frame) / step).rounded()), a + 1)
            guard a < values.count, b > 0 else { return }
            for index in max(a, 0)..<min(b, values.count) { values[index] = max(values[index], min(value, 30)) }
        }
        for (clip, rises) in placed {
            for (k, value) in rises.enumerated() where value > 0 {
                guard let t = clip.time(Double(k) / clip.fps) else { continue }
                lay(value, from: t - origin, frame: 1 / clip.fps, into: &timeline)
            }
        }
        events.sort()
        for c in cameras.indices {
            for i in cameras[c].clips.indices where cameras[c].clips[i].start == nil && cameras[c].clips[i].hasVideo && !cameras[c].clips[i].locked {
                let clip = cameras[c].clips[i]
                guard decodable(clip), let rises = risesOf[clip.id] else { continue }
                var own = [Float](repeating: 0, count: Int(clip.duration / step) + 1)
                for (k, value) in rises.enumerated() where value > 0 { lay(value, from: Double(k) / clip.fps, frame: 1 / clip.fps, into: &own) }
                let minOverlap = max(own.count / 3, 300)
                guard let scores = normalizedCorrelation([timeline], [own], minOverlap: minOverlap),
                      let top = topPeaks(scores.values, count: 1, apart: 1).first, scores.values[top] > 0.2 else { continue }
                let second = scores.values.indices.filter { abs($0 - top) > 50 }.map { scores.values[$0] }.max() ?? 0
                var start = origin + Double(top + scores.firstLag) * step
                // Each of its own flashes against the nearest seen by the synced cameras.
                var gaps: [Double] = []
                for (k, value) in rises.enumerated() where value > 8 && (k == 0 || rises[k - 1] <= 8) {
                    let t = start + Double(k) / clip.fps
                    if let nearest = events.min(by: { abs($0 - t) < abs($1 - t) }), abs(nearest - t) < 0.1 { gaps.append(nearest - t) }
                }
                if !gaps.isEmpty { start += median(gaps) }
                let clarity = Double(1 - max(second, 0) / scores.values[top])
                cameras[c].clips[i].start = start
                cameras[c].clips[i].method = .flashes
                cameras[c].clips[i].confidence = min(1, clarity / 0.4) * min(1, Double(gaps.count) / 4)
            }
        }
    }
}

/// What syncing keeps between runs: each file's measured sound, and the raw decoders whose sound files are in use.
final class SyncCache: @unchecked Sendable {
    private let lock = NSLock()
    private var heard: [String: [[Float]]] = [:]
    private var sources: [String: RawSource] = [:]

    func heard(_ path: String) -> [[Float]]? { lock.withLock { heard[path] } }
    func keep(_ path: String, _ curves: [[Float]]) { lock.withLock { heard[path] = curves } }

    /// A clip's sound as a file ffmpeg reads: RED and Blackmagic RAW sound written by the raw decoder (once, kept while syncing).
    func sound(_ clip: SyncClip) -> URL? {
        guard RawFormats.isRawVideo(clip.file) else { return clip.file }
        guard let source = lock.withLock({ sources[clip.path] }) ?? (try? RawFormats.open(clip.file)) else { return nil }
        lock.withLock { sources[clip.path] = source }
        return (try? source.audio()) ?? nil
    }

    func clear() {
        lock.withLock {
            heard = [:]
            sources.values.forEach { $0.close() }
            sources = [:]
        }
    }
}

extension DateFormatter {
    /// "2026-05-01T21:04:05+0200": a camera's own date with its time zone.
    static let zoned: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter
    }()
}

extension ISO8601DateFormatter {
    static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
