import AppKit
import CryptoKit
import ImageIO
import PDFKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Review copies (§2): three H.264 renditions per video (1080, 540, and 360 for slow lossy links) as fragmented MP4 through ffmpeg's HLS muxer (so
/// ffmpeg writes the byte-range index), a poster and a hover strip; AAC for sound; a JPEG for a picture.
/// Made one at a time in the background, the newest version first.
@MainActor
@Observable
final class DeliverCopies {
    static let shared = DeliverCopies(store: .shared)

    let store: DeliverStore
    private(set) var queue: [(asset: UUID, version: UUID)] = []
    private(set) var working: UUID?
    /// Per-link burned-in copies to make (after the plain ones).
    private(set) var marks: [(asset: UUID, version: UUID, link: UUID)] = []
    /// Transcripts to make (DeliverTranscripts.swift), only once every copy above is made: one job at a time on this Mac.
    var transcripts: [(asset: UUID, version: UUID)] = []
    private(set) var transcribing: UUID?
    /// Set when burned-in copies couldn't be made (an ffmpeg without drawtext, say).
    var markProblem: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(store: DeliverStore) {
        self.store = store
    }

    /// Copies left from the last run (or deleted from Settings) are made again.
    func resume() {
        store.copyMaker = { [weak self] in self?.enqueue(asset: $0, version: $1) }
        for content in store.contents.values {
            for asset in content.assets {
                for version in asset.versions {
                    switch version.copy {
                    case .pending, .making: enqueue(asset: asset.id, version: version.id)
                    case .ready, .failed: break
                    }
                }
            }
        }
    }

    func enqueue(asset: UUID, version: UUID) {
        guard working != version, !queue.contains(where: { $0.version == version }) else { return }
        queue.insert((asset, version), at: 0)
        next()
    }

    func retry(asset: UUID, version: UUID) {
        store.update(version: version, of: asset) { $0.copy = .pending }
        enqueue(asset: asset, version: version)
    }

    /// The project's 4K copies go (the 1080 ladder stays); the hosts get the shorter list.
    /// shortcut: a NAS keeps the 4K files it was sent until "Delete Review Copies"; they're no longer listed, so never served.
    func deleteUHD(_ project: UUID) {
        for asset in store.content(project).assets {
            var changed = false
            for version in asset.versions {
                guard case .ready(let list) = version.copy, list.contains(where: { $0.hasPrefix("2160") }) else { continue }
                for r in list where r.hasPrefix("2160") { try? FileManager.default.removeItem(at: store.copies(version.id).appendingPathComponent(r)) }
                store.update(version: version.id, of: asset.id) { $0.copy = .ready(list.filter { !$0.hasPrefix("2160") }) }
                changed = true
            }
            if changed { store.tell(.assetChanged(asset.id)); ReviewPublish.shared.resend(asset.id) }
        }
    }

    /// A link's burned-in copies of a version (made once; asked for again when the link's watermark changes).
    func enqueueMark(asset: UUID, version: UUID, link: UUID) {
        guard !marks.contains(where: { $0.version == version && $0.link == link }) else { return }
        marks.append((asset, version, link))
        next()
    }

    /// Every version a burned-in link shows, its marked copies made again (old ones go).
    func remark(_ link: Deliver.ShareLink) {
        let server = DeliverServer(store: store)
        for content in store.contents.values {
            for asset in content.assets where server.inScope(asset, link) {
                for version in asset.versions {
                    try? FileManager.default.removeItem(at: Self.marked(store.copies(version.id), link: link.id))
                    if link.watermark?.burned == true, asset.kind == .video || asset.kind == .image { enqueueMark(asset: asset.id, version: version.id, link: link.id) }
                }
            }
        }
    }

    func next() {
        if task == nil, queue.isEmpty, !marks.isEmpty {
            let job = marks.removeFirst()
            guard let link = store.link(job.link), let mark = link.watermark, mark.burned, let (_, asset) = store.find(job.asset),
                  let version = asset.versions.first(where: { $0.id == job.version }), let source = store.original(version), let probe = version.probe,
                  let ffmpeg = AppDelegate.shared?.manager.tool("ffmpeg") else { return next() }
            let out = Self.marked(store.copies(version.id), link: link.id), text = Self.watermarkText(mark, link: link), kind = asset.kind
            let plain = store.copies(version.id)
            task = Task {
                let ok = await Self.makeMarked(source, kind: kind, probe: probe, plain: plain, into: out, mark: mark, text: text, ffmpeg: ffmpeg)
                markProblem = ok ? nil : await Self.hasDrawtext(ffmpeg) ? String(localized: "The watermarked copy couldn’t be made.")
                    : String(localized: "This ffmpeg can’t burn text into copies.")
                task = nil
                next()
            }
            return
        }
        if task == nil, queue.isEmpty, marks.isEmpty, !transcripts.isEmpty {
            let job = transcripts.removeFirst()
            transcribing = job.version
            task = Task {
                await makeTranscript(asset: job.asset, version: job.version)
                transcribing = nil
                task = nil
                next()
            }
            return
        }
        guard task == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        guard let (_, asset) = store.find(job.asset), let version = asset.versions.first(where: { $0.id == job.version }) else { return next() }
        // (On a NAS host: it makes those copies itself. A data host's version has no original here: nothing to make or stamp.)
        if ReviewPublish.browsed(version.path) != nil || version.path.hasPrefix("host:") { return next() }
        working = job.version
        task = Task {
            await make(asset: asset, version: version)
            working = nil
            task = nil
            next()
        }
    }

    private func make(asset: Deliver.Asset, version: Deliver.Version) async {
        let id = version.id, owner = asset.id
        guard let manager = AppDelegate.shared?.manager, let ffmpeg = manager.tool("ffmpeg"), let ffprobe = manager.tool("ffprobe") else {
            return store.update(version: id, of: owner) { $0.copy = .failed(String(localized: "ffmpeg isn’t installed")) }
        }
        guard let source = store.original(version) else {
            return store.update(version: id, of: owner) { $0.copy = .failed(String(localized: "The original can’t be found")) }
        }
        store.update(version: id, of: owner) { $0.copy = .making(0) }
        let out = store.copies(id)
        let uhd = store.find(owner).flatMap { store.project($0.project)?.uhd } == true
        let result = await Self.make(source, kind: asset.kind, into: out, ffmpeg: ffmpeg, ffprobe: ffprobe, uhd: uhd) { share in
            Task { @MainActor in self.store.update(version: id, of: owner) { $0.copy = .making(share) } }
        }
        let pages = asset.kind == .document ? Self.pageCount(out) : nil
        // (A Quick Look preview makes a download-only file a picture on the review page, by both servers' image path.)
        if asset.kind == .other, result.probe != nil { store.update(asset: owner) { $0.kind = .image } }
        store.update(version: id, of: owner) { version in
            if let probe = result.probe { version.probe = probe }
            if let pages { version.pages = pages }
            version.copy = result.renditions.map { .ready($0) } ?? .failed(String(localized: "The review copy couldn’t be made"))
        }
        store.tell(.assetChanged(owner))
        // The original's SHA-256, for approval proofs (§13.8).
        if result.renditions != nil { DeliverProof.hashSoon(asset: owner, version: id, store: store) }
        if result.renditions != nil, wantsTranscript(owner) { enqueueTranscript(asset: owner, version: id) }
        // Links with a burned-in watermark get their own copies of it too.
        for link in store.links where link.isLive && link.watermark?.burned == true {
            if let found = store.find(owner)?.asset, DeliverServer(store: store).inScope(found, link) { enqueueMark(asset: owner, version: id, link: link.id) }
        }
    }

    // MARK: - Making them (no state: the self-test calls these directly)

    /// Probes `source` and makes its copies in `out`; nil renditions when that failed.
    nonisolated static func make(_ source: URL, kind: Deliver.Kind, into out: URL, ffmpeg: String, ffprobe: String, uhd: Bool = false,
                                 progress: @escaping @Sendable (Double) -> Void) async -> (probe: Deliver.Probe?, renditions: [String]?) {
        try? FileManager.default.removeItem(at: out)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        switch kind {
        case .video:
            guard let probe = await probe(source, ffprobe: ffprobe), probe.width > 0 else { return (nil, nil) }
            let inputs = input(source), tools = await tools(ffmpeg)
            if probe.isHDR && !tools.tonemap { NSLog("Pluck copies: this ffmpeg has no zscale/tonemap, so the SDR copies of an HDR source may look flat") }
            let list = renditions(for: probe, uhd: uhd, hevc: tools.hevc != nil)
            for (index, rendition) in list.enumerated() {
                let share = { @Sendable (done: Double) in progress((Double(index) + done) / (Double(list.count) + 0.2)) }
                guard await encode(source, rendition: rendition, probe: probe, into: out, ffmpeg: ffmpeg, tools: tools, progress: share) else {
                    // (A 4K copy that didn't work leaves the usual ones.)
                    if rendition.hasPrefix("2160") { continue }
                    return (probe, nil)
                }
            }
            let made = list.filter { FileManager.default.fileExists(atPath: out.appendingPathComponent("\($0)/index.json").path) }
            await pictures(source, input: inputs, probe: probe, into: out, ffmpeg: ffmpeg)
            if probe.hasAudio { await waveform(source, into: out, ffmpeg: ffmpeg) }
            captions(for: source, duration: probe.duration, into: out)
            progress(1)
            return (probe, made)
        case .audio:
            guard let probe = await probe(source, ffprobe: ffprobe) else { return (nil, nil) }
            guard await encode(source, rendition: "a", probe: probe, into: out, ffmpeg: ffmpeg, progress: progress) else { return (probe, nil) }
            await waveform(source, into: out, ffmpeg: ffmpeg)
            captions(for: source, duration: probe.duration, into: out)
            return (probe, ["a"])
        case .document:
            guard let size = pages(source, into: out.appendingPathComponent("pages", isDirectory: true)) else { return (nil, nil) }
            return (Deliver.Probe(duration: 0, fpsNum: 25, fpsDen: 1, width: size.0, height: size.1, startTimecode: "00:00:00:00",
                                  dropFrame: false, hasAudio: false, frames: 1), [])
        case .image:
            // (ImageIO can't read every picture type: an Illustrator file gets Quick Look's page 1.)
            let file = out.appendingPathComponent("image.jpg")
            var size = picture(source, into: file)
            if size == nil { size = await quickLook(source, into: file) }
            guard let size else { return (nil, nil) }
            return (Deliver.Probe(duration: 0, fpsNum: 25, fpsDen: 1, width: size.0, height: size.1, startTimecode: "00:00:00:00",
                                  dropFrame: false, hasAudio: false, frames: 1), [])
        case .other:
            // Office, Keynote and the like: Quick Look's first page as a picture, else download only.
            guard let size = await quickLook(source, into: out.appendingPathComponent("image.jpg")) else { return (nil, []) }
            return (Deliver.Probe(duration: 0, fpsNum: 25, fpsDen: 1, width: size.0, height: size.1, startTimecode: "00:00:00:00",
                                  dropFrame: false, hasAudio: false, frames: 1), [])
        }
    }

    /// Quick Look's thumbnail of page 1 (≤ 2560 px, in-process: no qlmanage), as JPEG; nil when it has none (never an icon).
    nonisolated static func quickLook(_ source: URL, into file: URL) async -> (Int, Int)? {
        let request = QLThumbnailGenerator.Request(fileAt: source, size: CGSize(width: 2560, height: 2560), scale: 1, representationTypes: .thumbnail)
        guard let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage,
              DeliverExport.jpeg(image, file) else { return nil }
        return (image.width, image.height)
    }

    /// A picture this Mac can only show through Quick Look (Office, Illustrator…): the review page gets a preview of it.
    nonisolated static func isPreviewOnly(_ original: URL?) -> Bool {
        guard let original else { return false }
        let types = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
        return !(UTType(filenameExtension: original.pathExtension).map { type in types.contains { UTType($0).map(type.conforms(to:)) ?? false } } ?? false)
            && DeliverStore.kind(original) != .document
    }

    /// Office files with pages or slides: Quick Look shows only the first, a PDF export gets every page reviewed.
    nonisolated static func isMultiPageOffice(_ original: URL?) -> Bool {
        ["docx", "doc", "pptx", "ppt", "xlsx", "xls", "pages", "key", "numbers"].contains(original?.pathExtension.lowercased() ?? "")
    }

    /// The picture at most 2560 px on its longer side, as JPEG at 0.85; its size.
    nonisolated static func picture(_ source: URL, into file: URL) -> (Int, Int)? {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(image, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                                                         kCGImageSourceThumbnailMaxPixelSize: 2560] as CFDictionary),
              let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, thumb, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? (thumb.width, thumb.height) : nil
    }

    /// The poster at 10 % and the 10×10 hover strip (`filter`: a burned-in watermark after the scaling).
    nonisolated static func pictures(_ source: URL, input: [String], probe: Deliver.Probe, into out: URL, ffmpeg: String, filter: ((Int) -> String)? = nil) async {
        let at = String(format: "%.3f", probe.duration * 0.1)
        let mark = { (width: Int) in filter.map { "," + $0(width) } ?? "" }
        _ = await DeliveryCheck.output(ffmpeg, ["-nostdin", "-v", "error", "-y", "-ss", at] + input + ["-frames:v", "1",
                                                "-vf", "scale=640:-2" + mark(640), "-q:v", "4", out.appendingPathComponent("poster.jpg").path])
        let tiles = min(100, max(probe.frames, 1))
        _ = await DeliveryCheck.output(ffmpeg, ["-nostdin", "-v", "error", "-y"] + input +
                                       ["-vf", "fps=\(tiles)/\(String(format: "%.3f", max(probe.duration, 0.04))),scale=160:-2" + mark(160) + ",tile=10x10",
                                        "-frames:v", "1", "-q:v", "5", out.appendingPathComponent("strip.jpg").path])
    }

    // MARK: - Image sequences (a folder of numbered pictures is one video)

    /// `<prefix><digits>.<ext>`, every file in the folder, at least 24: the ffmpeg pattern and the first number.
    nonisolated static func sequence(_ folder: URL) -> (pattern: String, start: Int, count: Int)? {
        guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path).filter({ !$0.hasPrefix(".") }).sorted(), names.count >= 24 else { return nil }
        var prefix: String?, ext: String?, digits: Int?, numbers: [Int] = []
        for name in names {
            guard let match = name.wholeMatch(of: #/(.*?)(\d+)\.([A-Za-z0-9]+)/#), DeliverStore.kind(URL(fileURLWithPath: name)) == .image else { return nil }
            let (p, d, e) = (String(match.1), String(match.2), String(match.3))
            if prefix == nil { prefix = p; ext = e; digits = d.count }
            guard p == prefix, e == ext, d.count == digits, let n = Int(d) else { return nil }
            numbers.append(n)
        }
        guard let prefix, let ext, let digits, let first = numbers.min() else { return nil }
        return (folder.appendingPathComponent(prefix).path + "%0\(digits)d." + ext, first, numbers.count)
    }

    /// ffmpeg's input arguments for a source (an image sequence at 25 fps, or the file).
    nonisolated static func input(_ source: URL) -> [String] {
        if let sequence = sequence(source) { return ["-framerate", "25", "-start_number", String(sequence.start), "-i", sequence.pattern] }
        return ["-i", source.path]
    }

    // MARK: - Waveform, captions, PDF pages (§6.1's shared recipes)

    /// 2,000 peaks 0…255 of the mono sound at 8 kHz, as waveform.json.
    nonisolated static func waveform(_ source: URL, into out: URL, ffmpeg: String) async {
        let raw = out.appendingPathComponent("waveform.raw")
        defer { try? FileManager.default.removeItem(at: raw) }
        _ = await DeliveryCheck.output(ffmpeg, ["-nostdin", "-v", "error", "-y", "-i", source.path, "-map", "0:a:0", "-ac", "1", "-ar", "8000", "-f", "s16le", raw.path])
        guard let data = try? Data(contentsOf: raw), data.count >= 2 else { return }
        let json = peaks(data)
        try? JSONSerialization.data(withJSONObject: json).write(to: out.appendingPathComponent("waveform.json"), options: .atomic)
    }

    nonisolated static func peaks(_ data: Data, buckets wanted: Int = 2000) -> [String: Any] {
        let samples = data.count / 2, buckets = max(1, min(wanted, samples))
        var peaks = [Int](repeating: 0, count: buckets)
        data.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Int16.self)
            for bucket in 0..<buckets {
                let from = bucket * samples / buckets, to = max(from + 1, (bucket + 1) * samples / buckets)
                var peak = 0
                for i in from..<min(to, samples) { peak = max(peak, abs(Int(Int16(littleEndian: values[i])))) }
                peaks[bucket] = min(255, Int((Double(peak) / 32768 * 255).rounded()))
            }
        }
        return ["buckets": buckets, "peaks": peaks, "channels": 1]
    }

    /// Pluck's local subtitles for the original (a .srt/.vtt beside it, or the Editor's own), as captions.vtt and transcript.json.
    /// shortcut: read when the copy is made; subtitles made later show after "Delete Review Copies" or a new version.
    nonisolated static func captions(for source: URL, duration: Double, into out: URL) {
        guard let cues = cues(for: source), !cues.isEmpty else { return }
        func stamp(_ t: Double) -> String {
            let ms = Int((max(t, 0) * 1000).rounded())
            return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        let vtt = "WEBVTT\n\n" + cues.map { "\(stamp($0.start)) --> \(stamp($0.end))\n\($0.text)\n" }.joined(separator: "\n")
        try? vtt.write(to: out.appendingPathComponent("captions.vtt"), atomically: true, encoding: .utf8)
        // Words spread evenly over their cue (no word times in subtitles).
        var words: [[Any]] = []
        for cue in cues {
            let parts = cue.text.split(whereSeparator: \.isWhitespace)
            let step = (cue.end - cue.start) / Double(max(parts.count, 1))
            for (n, word) in parts.enumerated() {
                words.append([((cue.start + step * Double(n)) * 1000).rounded() / 1000, ((cue.start + step * Double(n + 1)) * 1000).rounded() / 1000, String(word)])
            }
        }
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        try? JSONSerialization.data(withJSONObject: ["lang": lang, "words": words]).write(to: out.appendingPathComponent("transcript.json"), options: .atomic)
    }

    nonisolated static func cues(for source: URL) -> [(start: Double, end: Double, text: String)]? {
        for ext in ["srt", "vtt"] {
            let side = source.deletingPathExtension().appendingPathExtension(ext)
            if let text = try? String(contentsOf: side, encoding: .utf8) { return parseSubtitles(text) }
        }
        // The Editor keeps a file's subtitles by the SHA-256 of its path (EditorSubtitles.swift).
        let name = SHA256.hash(data: Data(source.path.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        let saved = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck/Editor Subtitles/\(name).json")
        guard let data = try? Data(contentsOf: saved), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cues = json["cues"] as? [[String: Any]] else { return nil }
        return cues.compactMap { cue in
            guard let start = (cue["start"] as? NSNumber)?.doubleValue, let end = (cue["end"] as? NSNumber)?.doubleValue, let text = cue["text"] as? String else { return nil }
            return (start, end, text)
        }
    }

    /// SRT or WebVTT cues ("00:00:01,500 --> 00:00:03,000" then the text).
    nonisolated static func parseSubtitles(_ text: String) -> [(start: Double, end: Double, text: String)] {
        func seconds(_ s: Substring) -> Double? {
            let parts = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":").compactMap { Double($0) }
            return parts.count == 3 ? parts[0] * 3600 + parts[1] * 60 + parts[2] : parts.count == 2 ? parts[0] * 60 + parts[1] : nil
        }
        var cues: [(Double, Double, String)] = []
        for block in text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true)
            guard let index = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let times = lines[index].components(separatedBy: "-->")
            guard times.count == 2, let start = seconds(Substring(times[0])), let end = seconds(Substring(times[1].split(separator: " ").first ?? "")) else { continue }
            let words = lines[(index + 1)...].joined(separator: "\n")
            if !words.isEmpty { cues.append((start, end, words)) }
        }
        return cues
    }

    /// Each page of a PDF as pages/<n>.jpg, ≤ 2560 px; page 1's size.
    nonisolated static func pages(_ source: URL, into folder: URL) -> (Int, Int)? {
        guard let document = PDFDocument(url: source), document.pageCount > 0 else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var first: (Int, Int)?
        for n in 0..<min(document.pageCount, 500) {
            guard let page = document.page(at: n) else { continue }
            let bounds = page.bounds(for: .mediaBox), scale = 2560 / max(bounds.width, bounds.height, 1)
            let width = max(1, Int(bounds.width * scale)), height = max(1, Int(bounds.height * scale))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: context)
            guard let image = context.makeImage(), DeliverExport.jpeg(image, folder.appendingPathComponent("\(n + 1).jpg")) else { continue }
            if first == nil { first = (width, height) }
        }
        return first
    }

    nonisolated static func pageCount(_ copies: URL) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: copies.appendingPathComponent("pages").path)) ?? []).filter { $0.hasSuffix(".jpg") }.count
    }

    // MARK: - Burned-in watermark copies (per link, §6.1)

    nonisolated static func marked(_ copies: URL, link: UUID) -> URL { copies.appendingPathComponent("wm-\(link.uuidString)", isDirectory: true) }

    /// {name} = the recipient (else the link's title), {email} left out, {date} today, {link} the title (as pB's host).
    nonisolated static func watermarkText(_ mark: Deliver.ShareLink.Watermark, link: Deliver.ShareLink, date: Date = .now) -> String {
        let day = date.formatted(.iso8601.year().month().day())
        let filled = mark.text.replacingOccurrences(of: "{name}", with: link.recipient ?? link.title).replacingOccurrences(of: "{email}", with: "")
            .replacingOccurrences(of: "{date}", with: day).replacingOccurrences(of: "{link}", with: link.title)
        // (Separators left with nothing between them go.)
        return filled.components(separatedBy: " · ").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " · ")
    }

    /// ffmpeg's drawtext (the text in a file, so nothing needs escaping): fontsize h×size, white at the opacity, the border at half.
    nonisolated static func drawtext(_ mark: Deliver.ShareLink.Watermark, textFile: String, width: Int) -> String {
        let (x, y): (String, String) = switch mark.position {
        case "topLeft": ("w*0.04", "h*0.04")
        case "topRight": ("w-tw-w*0.04", "h*0.04")
        case "bottomLeft": ("w*0.04", "h-th-h*0.04")
        case "bottomRight": ("w-tw-w*0.04", "h-th-h*0.04")
        default: ("(w-tw)/2", "(h-th)/2")
        }
        let alpha = min(max(mark.opacity, 0.05), 1)
        let opacity = String(format: "%.2f", alpha), border = String(format: "%.2f", alpha / 2), size = String(format: "%.4f", min(max(mark.size, 0.005), 0.2))
        return "drawtext=textfile=\(textFile):expansion=none:fontfile=/System/Library/Fonts/Helvetica.ttc:fontcolor=white@\(opacity):borderw=2:bordercolor=black@\(border)"
            + ":fontsize=max(8\\,h*\(size)):x=\(x):y=\(y)"
    }

    /// The link's own renditions, poster and strip (video) or picture (image) with the text burned in; `ready` written last.
    /// Whether this ffmpeg can burn text in (a build without libfreetype can't).
    nonisolated static func hasDrawtext(_ ffmpeg: String) async -> Bool {
        await DeliveryCheck.output(ffmpeg, ["-hide_banner", "-filters"]).contains(" drawtext ")
    }

    nonisolated static func makeMarked(_ source: URL, kind: Deliver.Kind, probe: Deliver.Probe, plain: URL, into out: URL, mark: Deliver.ShareLink.Watermark,
                                       text: String, ffmpeg: String) async -> Bool {
        try? FileManager.default.removeItem(at: out)
        guard await hasDrawtext(ffmpeg) else { return false }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // (A temporary path without spaces or quotes: nothing in the filter needs escaping.)
        let textFile = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-wm-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: textFile) }
        guard (try? text.write(to: textFile, atomically: true, encoding: .utf8)) != nil else { return false }
        switch kind {
        case .video:
            let tools = await tools(ffmpeg)
            for rendition in renditions {
                let (width, _) = fit(probe.width, probe.height, box: spec(rendition, fast: false).box)
                guard await encode(source, rendition: rendition, probe: probe, into: out, ffmpeg: ffmpeg, filter: drawtext(mark, textFile: textFile.path, width: width), tools: tools, progress: { _ in })
                else { return false }
            }
            await pictures(source, input: input(source), probe: probe, into: out, ffmpeg: ffmpeg) { drawtext(mark, textFile: textFile.path, width: $0) }
        case .image:
            let picture = plain.appendingPathComponent("image.jpg")
            let width = probe.width
            _ = await DeliveryCheck.output(ffmpeg, ["-nostdin", "-v", "error", "-y", "-i", picture.path, "-vf", drawtext(mark, textFile: textFile.path, width: max(width, 1)),
                                                    "-q:v", "3", out.appendingPathComponent("image.jpg").path])
            guard FileManager.default.fileExists(atPath: out.appendingPathComponent("image.jpg").path) else { return false }
        default: return false
        }
        return FileManager.default.createFile(atPath: out.appendingPathComponent("ready").path, contents: Data())
    }

    /// The 1080 copy as one MP4: its init piece then every segment, neighbouring ranges of one file joined.
    nonisolated static func proxyPieces(_ index: Deliver.CopyIndex, folder: URL) -> [(path: String, offset: Int64, length: Int64)] {
        var pieces: [(path: String, offset: Int64, length: Int64)] = [(folder.appendingPathComponent(index.`init`.file).path, index.`init`.offset, index.`init`.length)]
        for segment in index.segments {
            let path = folder.appendingPathComponent(segment.file).path
            if let last = pieces.last, last.path == path, last.offset + last.length == segment.offset {
                pieces[pieces.count - 1].length += segment.length
            } else {
                pieces.append((path, segment.offset, segment.length))
            }
        }
        return pieces
    }

    /// ffprobe's facts: frame rate, display size (rotation applied), start timecode, sound.
    nonisolated static func probe(_ source: URL, ffprobe: String) async -> Deliver.Probe? {
        let input = sequence(source).map { ["-f", "image2", "-framerate", "25", "-start_number", String($0.start), $0.pattern] } ?? [source.path]
        let text = await DeliveryCheck.output(ffprobe, ["-v", "error", "-print_format", "json", "-show_streams", "-show_format"] + input)
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        return probe(json)
    }

    nonisolated static func probe(_ json: [String: Any]) -> Deliver.Probe? {
        let streams = json["streams"] as? [[String: Any]] ?? [], format = json["format"] as? [String: Any] ?? [:]
        let video = streams.first { $0["codec_type"] as? String == "video" && ($0["disposition"] as? [String: Any])?["attached_pic"] as? Int != 1 }
        let hasAudio = streams.contains { $0["codec_type"] as? String == "audio" }
        guard video != nil || hasAudio else { return nil }
        let duration = Double(format["duration"] as? String ?? "") ?? Double(video?["duration"] as? String ?? "") ?? 0
        var num = 25, den = 1
        if let rate = video?["r_frame_rate"] as? String {
            let parts = rate.split(separator: "/").compactMap { Int($0) }
            if parts.count == 2, parts[0] > 0, parts[1] > 0 { num = parts[0]; den = parts[1] }
        }
        var width = video?["width"] as? Int ?? 0, height = video?["height"] as? Int ?? 0
        let tags = video?["tags"] as? [String: Any] ?? [:]
        let sideRotation = (video?["side_data_list"] as? [[String: Any]])?.compactMap { $0["rotation"] as? Int }.first
        let rotation = Int(tags["rotate"] as? String ?? "") ?? sideRotation ?? 0
        if abs(rotation) % 180 == 90 { swap(&width, &height) }
        let timecode = tags["timecode"] as? String ?? (format["tags"] as? [String: Any])?["timecode"] as? String ?? "00:00:00:00"
        let fps = Double(num) / Double(den)
        return Deliver.Probe(duration: duration, fpsNum: num, fpsDen: den, width: width, height: height, startTimecode: timecode,
                             dropFrame: timecode.contains(";"), hasAudio: hasAudio, frames: max(1, Int((duration * fps).rounded())),
                             transfer: video?["color_transfer"] as? String, primaries: video?["color_primaries"] as? String)
    }

    /// The display size scaled so its longer side fits `box`, never up, both sides even.
    nonisolated static func fit(_ width: Int, _ height: Int, box: Int) -> (Int, Int) {
        let scale = min(1, Double(box) / Double(max(width, height, 1)))
        func even(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }
        return (even(Double(width) * scale), even(Double(height) * scale))
    }

    /// A video's renditions, highest first: always H.264 SDR (tone-mapped from an HDR source), so every browser plays one.
    nonisolated static let renditions = ["1080", "540", "360"]

    /// With the project's 4K switch on and a source at least 3000 px: HEVC "2160" (SDR) and, from an HDR source, "2160h"
    /// (Main10, PQ or HLG) on top. Never instead of the H.264 ladder.
    nonisolated static func renditions(for probe: Deliver.Probe, uhd: Bool, hevc: Bool) -> [String] {
        guard uhd, hevc, max(probe.width, probe.height) >= 3000 else { return renditions }
        return (probe.isHDR ? ["2160h", "2160"] : ["2160"]) + renditions
    }

    /// What this ffmpeg can do for 4K and HDR: an HEVC encoder (VideoToolbox, else x265) and zscale + tonemap.
    struct Tools: Sendable { var hevc: String?; var tonemap = false }

    nonisolated static func tools(_ ffmpeg: String) async -> Tools {
        let encoders = await DeliveryCheck.output(ffmpeg, ["-hide_banner", "-encoders"]), filters = await DeliveryCheck.output(ffmpeg, ["-hide_banner", "-filters"])
        return Tools(hevc: encoders.contains(" hevc_videotoolbox ") ? "hevc_videotoolbox" : encoders.contains(" libx265 ") ? "libx265" : nil,
                     tonemap: filters.contains(" zscale ") && filters.contains(" tonemap "))
    }

    /// PQ/HLG to BT.709 SDR (Hable, linear light at 100 nits), ending in 8-bit 4:2:0.
    /// No zscale/tonemap: the frames re-tagged BT.709 (the encoder takes the frames' tags over -color_trc); colours may look flat.
    nonisolated static let untoned = "format=yuv420p,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709"
    nonisolated static let toneMap = "zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"

    /// One video rendition's longer side, H.264 level and codec, -b:v/-maxrate/-bufsize and AAC rate.
    /// 360 is ≤ 0.4 Mbit/s in all (mono sound), for slow lossy links (WebRTC goodput there is ~0.2–0.35 Mbit/s).
    nonisolated static func spec(_ rendition: String, fast: Bool) -> (box: Int, level: String, avc: String, rates: [String], audio: String) {
        switch rendition {
        case "2160": (3840, "5.1", "hvc1.1.6.L153.B0", ["18M", "24M", "36M"], "160k")
        case "2160h": (3840, "5.1", "hvc1.2.4.L153.B0", ["18M", "24M", "36M"], "160k")
        case "1080": (1920, "4.2", "avc1.64002a", fast ? ["12M", "15M", "24M"] : ["8M", "10M", "16M"], "160k")
        case "360": (640, "3.1", "avc1.64001f", ["330k", "380k", "660k"], "48k") // any frame rate: the bits matter, not the frames
        default: (960, "3.2", "avc1.640020", fast ? ["3M", "3.75M", "6M"] : ["2M", "2.5M", "4M"], "128k")
        }
    }

    nonisolated static func codecs(_ rendition: String, audio: Bool) -> String {
        if rendition == "a" { return "mp4a.40.2" }
        let avc = spec(rendition, fast: false).avc
        return audio ? avc + ",mp4a.40.2" : avc
    }

    /// ffmpeg's arguments for one rendition (§2), written into `folder`.
    nonisolated static func arguments(_ source: URL, rendition: String, probe: Deliver.Probe, folder: URL, filter: String? = nil, tools: Tools = Tools()) -> [String] {
        var arguments = ["-hide_banner", "-nostdin", "-y", "-v", "error"] + input(source)
        // (§2 says make_zero; that shifts the video by AAC's priming, 21 ms, so frame N no longer starts at N/fps.
        // "disabled" keeps video and sound starting at 0, the priming in the edit list.)
        let hls = ["-avoid_negative_ts", "disabled", "-f", "hls", "-hls_time", "2", "-hls_playlist_type", "vod", "-hls_segment_type", "fmp4",
                   "-hls_flags", "single_file", "-hls_fmp4_init_filename", "init.mp4",
                   "-hls_segment_filename", folder.appendingPathComponent("media.m4s").path,
                   "-progress", "pipe:1", folder.appendingPathComponent("index.m3u8").path]
        if rendition == "a" {
            return arguments + ["-map", "0:a:0", "-vn", "-sn", "-dn", "-map_metadata", "-1", "-c:a", "aac", "-b:a", "192k", "-ac", "2", "-ar", "48000"] + hls
        }
        let video = spec(rendition, fast: probe.fps > 30.5), rates = video.rates
        let (width, height) = fit(probe.width, probe.height, box: video.box)
        let g = String(Int((2 * probe.fps).rounded()))
        let sdr = !probe.isHDR ? "format=yuv420p" : tools.tonemap ? toneMap : untoned
        // An HDR source's SDR copies are tagged BT.709 even when this ffmpeg can't tone-map (else they'd keep the PQ/HLG tag).
        let bt709 = probe.isHDR ? ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"] : []
        if rendition.hasPrefix("2160"), let hevc = tools.hevc {
            // HEVC (hvc1 for Safari); HDR keeps its transfer and BT.2020 tags, Dolby Vision isn't carried (re-encoded without its RPU).
            let hdr = rendition == "2160h"
            let colour = hdr ? ["-color_primaries", "bt2020", "-color_trc", probe.transfer ?? "smpte2084", "-colorspace", "bt2020nc"] : bt709
            let x265 = hevc == "libx265" ? ["-preset", "fast", "-x265-params", "log-level=error" + (hdr ? ":colorprim=bt2020:transfer=\(probe.transfer ?? "smpte2084"):colormatrix=bt2020nc" : "")] : []
            arguments += ["-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn", "-map_metadata", "-1",
                          "-vf", "scale=\(width):\(height):flags=lanczos," + (hdr ? "format=p010le" : sdr),
                          "-fps_mode", "cfr", "-r", "\(probe.fpsNum)/\(probe.fpsDen)",
                          "-c:v", hevc] + x265 + ["-profile:v", hdr ? "main10" : "main", "-tag:v", "hvc1",
                          "-b:v", rates[0], "-maxrate", rates[1], "-bufsize", rates[2], "-g", g, "-keyint_min", g, "-bf", "0"] + colour
                + ["-c:a", "aac", "-b:a", video.audio, "-ac", "2", "-ar", "48000"]
            return arguments + hls
        }
        arguments += ["-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn", "-map_metadata", "-1",
                      "-vf", "scale=\(width):\(height):flags=lanczos," + sdr + (filter.map { "," + $0 } ?? ""),
                      "-fps_mode", "cfr", "-r", "\(probe.fpsNum)/\(probe.fpsDen)",
                      "-c:v", "libx264", "-preset", "medium", "-profile:v", "high", "-level:v", video.level,
                      "-b:v", rates[0], "-maxrate", rates[1], "-bufsize", rates[2],
                      "-g", g, "-keyint_min", g, "-sc_threshold", "0", "-bf", "0",
                      "-c:a", "aac", "-b:a", video.audio, "-ac", rendition == "360" ? "1" : "2", "-ar", "48000"] + bt709
        return arguments + hls
    }

    /// One rendition and its index.json; false when ffmpeg didn't finish it.
    nonisolated static func encode(_ source: URL, rendition: String, probe: Deliver.Probe, into out: URL, ffmpeg: String, filter: String? = nil,
                                   tools: Tools = Tools(), progress: @escaping @Sendable (Double) -> Void) async -> Bool {
        let folder = out.appendingPathComponent(rendition, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let duration = max(probe.duration, 0.001)
        _ = await DeliveryCheck.output(ffmpeg, arguments(source, rendition: rendition, probe: probe, folder: folder, filter: filter, tools: tools)) { line in
            if line.hasPrefix("out_time_ms="), let micro = Double(line.dropFirst(12)) { progress(min(micro / 1_000_000 / duration, 1)) }
        }
        guard let playlist = try? String(contentsOf: folder.appendingPathComponent("index.m3u8"), encoding: .utf8), playlist.contains("#EXT-X-ENDLIST") else { return false }
        let (width, height) = rendition == "a" ? (0, 0) : fit(probe.width, probe.height, box: spec(rendition, fast: false).box)
        guard let index = parse(playlist, folder: folder, codecs: codecs(rendition, audio: probe.hasAudio || rendition == "a"),
                                fpsNum: probe.fpsNum, fpsDen: probe.fpsDen, width: width, height: height),
              let data = try? Deliver.encoder.encode(index) else { return false }
        return (try? data.write(to: folder.appendingPathComponent("index.json"), options: .atomic)) != nil
    }

    /// index.m3u8's init map and byte-range segments, as §2's index.json (whatever the playlist says:
    /// init in its own file, or inside media.m4s with a BYTERANGE).
    nonisolated static func parse(_ playlist: String, folder: URL, codecs: String, fpsNum: Int, fpsDen: Int, width: Int, height: Int) -> Deliver.CopyIndex? {
        func size(_ file: String) -> Int64 { ((try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(file).path))?[.size] as? NSNumber)?.int64Value ?? 0 }
        func range(_ text: Substring) -> (length: Int64, offset: Int64?)? {
            let parts = text.split(separator: "@")
            guard let length = Int64(parts.first ?? "") else { return nil }
            return (length, parts.count > 1 ? Int64(parts[1]) : nil)
        }
        func safe(_ file: String) -> Bool { !file.isEmpty && !file.contains("/") && !file.contains("..") }
        var initPiece: Deliver.CopyIndex.Piece?
        var segments: [Deliver.CopyIndex.Segment] = []
        var duration: Double?, byteRange: (length: Int64, offset: Int64?)?, t = 0.0, end: [String: Int64] = [:]
        for raw in playlist.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-MAP:") {
                guard let uri = line.firstMatch(of: #/URI="([^"]+)"/#)?.1, safe(String(uri)) else { return nil }
                let file = String(uri)
                if let text = line.firstMatch(of: #/BYTERANGE="([0-9@]+)"/#)?.1, let piece = range(text) {
                    initPiece = .init(file: file, offset: piece.offset ?? 0, length: piece.length)
                } else {
                    initPiece = .init(file: file, offset: 0, length: size(file))
                }
            } else if line.hasPrefix("#EXTINF:") {
                duration = Double(line.dropFirst(8).split(separator: ",").first ?? "")
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                byteRange = range(Substring(line.dropFirst(17)))
            } else if !line.hasPrefix("#"), !line.isEmpty, let d = duration {
                guard safe(line) else { return nil }
                let piece = byteRange ?? (size(line), 0)
                let offset = piece.offset ?? end[line] ?? 0
                segments.append(.init(t: (t * 1_000_000).rounded() / 1_000_000, d: d, file: line, offset: offset, length: piece.length))
                end[line] = offset + piece.length
                t += d
                duration = nil
                byteRange = nil
            }
        }
        guard let initPiece, !segments.isEmpty else { return nil }
        return Deliver.CopyIndex(codecs: codecs, duration: (t * 1_000_000).rounded() / 1_000_000, fpsNum: fpsNum, fpsDen: fpsDen,
                                 width: width, height: height, init: initPiece, segments: segments)
    }

    nonisolated static func index(_ folder: URL) -> Deliver.CopyIndex? {
        (try? Data(contentsOf: folder.appendingPathComponent("index.json"))).flatMap { try? Deliver.decoder.decode(Deliver.CopyIndex.self, from: $0) }
    }
}
