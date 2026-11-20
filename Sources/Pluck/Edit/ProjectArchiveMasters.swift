import CoreGraphics
import Foundation

/// Archive masters: each used original made into a smaller master that can replace it (ProRes
/// 422 HQ, or 10-bit HEVC), log kept as log, with its timecode, reel, sound and frame rate. Every
/// master is checked against its original before it can stand in for it; only then can the
/// original go to the Trash.
extension ProjectArchive {
    /// How a file is kept.
    struct MasterSettings: Hashable, Sendable, Codable {
        enum Codec: String, CaseIterable, Sendable, Codable { case original, prores, hevc }
        enum Size: Int, CaseIterable, Sendable, Codable {
            case native = 0, k8 = 7680, k6 = 6144, k4 = 3840, k27 = 2704, hd = 1920
            /// The landscape box it fits in.
            var box: (Int, Int)? {
                switch self {
                case .native: nil
                case .k8: (7680, 4320)
                case .k6: (6144, 3456)
                case .k4: (3840, 2160)
                case .k27: (2704, 1520)
                case .hd: (1920, 1080)
                }
            }
            var label: String {
                switch self {
                case .native: String(localized: "Native")
                case .k8: "8K"
                case .k6: "6K"
                case .k4: "4K"
                case .k27: "2.7K"
                case .hd: "1080p"
                }
            }
        }
        enum Quality: Int, CaseIterable, Sendable, Codable {
            case high = 72, balanced = 62, small = 50
            var label: String {
                switch self {
                case .high: String(localized: "High")
                case .balanced: String(localized: "Balanced")
                case .small: String(localized: "Small")
                }
            }
            /// libx265's equivalent (when VideoToolbox isn't there).
            var crf: Int { switch self { case .high: 16; case .balanced: 20; case .small: 26 } }
        }
        var codec = Codec.hevc
        var size = Size.native
        var quality = Quality.balanced

        static let original = MasterSettings(codec: .original)
        static let master = MasterSettings(codec: .prores)
        static let compact = MasterSettings()
        static let compact4K = MasterSettings(size: .k4)

        var label: String {
            switch codec {
            case .original: return String(localized: "Original")
            case .prores: return "ProRes 422 HQ" + (size == .native ? "" : " · \(size.label)")
            case .hevc: return "HEVC 10-bit · \(size.label) · \(quality.label)"
            }
        }

        func with(size: Size? = nil, quality: Quality? = nil) -> MasterSettings {
            var copy = self
            copy.size = size ?? copy.size
            copy.quality = quality ?? copy.quality
            return copy
        }

        /// The size a picture is made (even numbers, aspect kept; never larger than it was).
        func fit(_ width: Int, _ height: Int) -> (Int, Int) {
            guard let (w, h) = size.box, width > 0, height > 0 else { return (width, height) }
            let (bw, bh) = width >= height ? (w, h) : (h, w)
            let scale = min(Double(bw) / Double(width), Double(bh) / Double(height), 1)
            return (Int(Double(width) * scale) / 2 * 2, Int(Double(height) * scale) / 2 * 2)
        }
    }

    /// What ffprobe says about a movie, for making a master and checking it.
    struct Streams: Sendable, Equatable {
        var frames = 0
        var duration = 0.0
        var fps = 0.0
        var width = 0
        var height = 0
        var timecode: String?
        var reel: String?
        var channels = 0
        var sampleRate = 0
        var pixelFormat = ""
        var audioCodecs: [String] = []
        /// Primaries, transfer, matrix, range ("unknown" when not stated).
        var colour: [String] = []
        var codec = ""
        /// The display matrix's rotation (degrees), the pixel aspect ratio, the sound's channel layouts.
        var rotation = 0
        var sar = ""
        var layouts: [String] = []
        /// The file's own tags (creation time, camera make and model, QuickTime keys…).
        var tags: [String: String] = [:]
        /// Bits per component, from the pixel format.
        var bits: Int { pixelFormat.contains("16") || pixelFormat.hasPrefix("rgb48") ? 16 : pixelFormat.contains("12") ? 12 : pixelFormat.contains("10") || pixelFormat.hasPrefix("p010") || pixelFormat.hasPrefix("p210") ? 10 : pixelFormat.isEmpty ? 0 : 8 }
    }

    /// A master and how its check went.
    struct MasterCheck: Sendable, Equatable {
        var original: String
        /// The master, relative to the archive's Media/ (as Item.relative).
        var relative: String
        var settings: MasterSettings
        var originalSize: Int64
        var size: Int64
        var originalHash: String?
        var frames: Int
        var timecode: String?
        var channels: Int
        /// Empty: the master matches its original.
        var problems: [String]
        var ok: Bool { problems.isEmpty }
    }

    /// Camera raw Pluck's raw decoder reads (when built with the makers' SDKs).
    static let rawMasterKinds: Set<String> = ["r3d", "braw"]
    static let videoKinds: Set<String> = trimKinds.union(["avi"])

    static func masterable(_ item: Item) -> Bool {
        let kind = (item.relative as NSString).pathExtension.lowercased()
        return item.kind == .media && (videoKinds.contains(kind) || rawMasterKinds.contains(kind))
    }

    /// `count`: frames counted (reads the whole file); otherwise from the header.
    static func streams(_ path: String, ffprobe: String, count: Bool = true) -> Streams {
        let out = run(ffprobe, ["-v", "error"] + (count ? ["-count_packets"] : []) + ["-show_entries",
                                "format=duration:format_tags:stream=codec_type,codec_name,nb_read_packets,nb_frames,duration,channels,channel_layout,sample_rate,avg_frame_rate,width,height,pix_fmt,sample_aspect_ratio,color_primaries,color_transfer,color_space,color_range:stream_tags=timecode,reel_name:stream_side_data=rotation",
                                "-of", "json", path]).output
        var result = Streams()
        guard let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] else { return result }
        let format = json["format"] as? [String: Any]
        result.tags = (format?["tags"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        result.timecode = result.tags["timecode"]
        var video = false
        for stream in json["streams"] as? [[String: Any]] ?? [] {
            let tags = stream["tags"] as? [String: Any]
            result.timecode = result.timecode ?? tags?["timecode"] as? String
            result.reel = result.reel ?? (tags?["reel_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            switch stream["codec_type"] as? String {
            case "video" where !video:
                video = true
                result.frames = Int(stream[count ? "nb_read_packets" : "nb_frames"] as? String ?? "") ?? 0
                result.duration = (stream["duration"] as? String).flatMap(Double.init) ?? (format?["duration"] as? String).flatMap(Double.init) ?? 0
                if let rate = (stream["avg_frame_rate"] as? String)?.split(separator: "/").compactMap({ Double($0) }), rate.count == 2, rate[1] > 0 { result.fps = rate[0] / rate[1] }
                result.width = stream["width"] as? Int ?? 0
                result.height = stream["height"] as? Int ?? 0
                result.pixelFormat = stream["pix_fmt"] as? String ?? ""
                result.codec = stream["codec_name"] as? String ?? ""
                result.colour = ["color_primaries", "color_transfer", "color_space", "color_range"].map { stream[$0] as? String ?? "unknown" }
                result.sar = stream["sample_aspect_ratio"] as? String ?? ""
                result.rotation = (stream["side_data_list"] as? [[String: Any]] ?? []).compactMap { ($0["rotation"] as? NSNumber)?.intValue }.first ?? 0
            case "audio":
                result.channels += stream["channels"] as? Int ?? 0
                result.sampleRate = result.sampleRate == 0 ? Int(stream["sample_rate"] as? String ?? "") ?? 0 : result.sampleRate
                result.audioCodecs.append(stream["codec_name"] as? String ?? "")
                result.layouts.append(stream["channel_layout"] as? String ?? "")
            default: break
            }
        }
        return result
    }

    // MARK: Encoders

    private static let encoderLock = NSLock()
    nonisolated(unsafe) private static var encoderCache: [String: (names: Set<String>, hevc422: Bool)] = [:]

    /// The encoders this ffmpeg has, and whether VideoToolbox makes 4:2:2 10-bit HEVC on this Mac.
    static func encoders(_ ffmpeg: String) -> (names: Set<String>, hevc422: Bool) {
        if let known = encoderLock.withLock({ encoderCache[ffmpeg] }) { return known }
        let names = Set(run(ffmpeg, ["-hide_banner", "-encoders"]).output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let parts = line.split(separator: " ")
            return parts.count >= 2 && parts[0].count == 6 ? String(parts[1]) : nil
        })
        let probe = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-hevc422-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: probe) }
        let hevc422 = names.contains("hevc_videotoolbox") && run(ffmpeg, ["-nostdin", "-y", "-v", "error", "-f", "lavfi", "-i", "testsrc=size=64x64:rate=25:duration=0.04",
                                                                          "-c:v", "hevc_videotoolbox", "-profile:v", "main42210", "-pix_fmt", "p210le", probe.path]).status == 0
        let found = (names, hevc422)
        encoderLock.withLock { encoderCache[ffmpeg] = found }
        return found
    }

    /// The video encoder's arguments and the pixel format it's given.
    static func videoArguments(_ settings: MasterSettings, source: Streams, ffmpeg: String) -> (arguments: [String], pixelFormat: String) {
        let tools = encoders(ffmpeg)
        let pixel = source.pixelFormat
        let full = pixel.contains("444") || pixel.hasPrefix("rgb") || pixel.hasPrefix("gbr") || pixel.hasPrefix("yuva") || pixel.contains("12")
        let wide = full || pixel.contains("422")
        if settings.codec == .prores {
            // 4:4:4 or 12-bit originals keep that in ProRes 4444.
            if tools.names.contains("prores_videotoolbox") {
                return (["-c:v", "prores_videotoolbox", "-profile:v", full ? "4444" : "hq"], full ? "yuv444p10le" : "yuv422p10le")
            }
            return (["-c:v", "prores_ks", "-profile:v", full ? "4" : "3", "-vendor", "apl0"], full ? "yuv444p10le" : "yuv422p10le")
        }
        // 4:2:0 originals stay 4:2:0 (4:2:2 would only add size).
        let chroma422 = wide && (tools.hevc422 || !tools.names.contains("hevc_videotoolbox"))
        if tools.names.contains("hevc_videotoolbox") {
            return (["-c:v", "hevc_videotoolbox", "-profile:v", chroma422 ? "main42210" : "main10", "-q:v", "\(settings.quality.rawValue)", "-tag:v", "hvc1"],
                    chroma422 ? "p210le" : "p010le")
        }
        return (["-c:v", "libx265", "-preset", "medium", "-crf", "\(settings.quality.crf)", "-profile:v", chroma422 ? "main422-10" : "main10", "-tag:v", "hvc1"],
                chroma422 ? "yuv422p10le" : "yuv420p10le")
    }

    /// ffmpeg's frame rate for a decoder's fps (23.976 → 24000/1001).
    static func rate(_ fps: Double) -> String {
        let ntsc = (fps * 1.001).rounded()
        if abs(fps - fps.rounded()) > 0.001, abs(fps - ntsc / 1.001) < 0.001 { return "\(Int(ntsc) * 1000)/1001" }
        return "\(Int((fps * 1000).rounded()))/1000"
    }

    // MARK: Making them

    /// Writes one master (`sample`: only that many seconds from the middle, for the estimate).
    /// Raw goes through `open` (pluck-raw), in the camera's own log and gamut, no LUT.
    /// `metadata`: more ffmpeg -metadata arguments (Shrink Folders marks its masters).
    static func encode(_ source: String, to output: URL, settings: MasterSettings, ffmpeg: String, ffprobe: String,
                       sample: Double? = nil, metadata: [String] = [], open: (URL) throws -> RawSource = { try RawFormats.open($0) }) throws {
        try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let kind = (source as NSString).pathExtension.lowercased()
        let reel = (source as NSString).lastPathComponent.components(separatedBy: ".").first ?? ""
        if rawMasterKinds.contains(kind) { return try encodeRaw(source, to: output, settings: settings, ffmpeg: ffmpeg, reel: reel, sample: sample, metadata: metadata, open: open) }
        let info = streams(source, ffprobe: ffprobe, count: false)
        guard info.frames > 0 || info.width > 0 else { throw RawProblem(text: String(localized: "No picture to make a master of.")) }
        let (video, pixel) = videoArguments(settings, source: info, ffmpeg: ffmpeg)
        let (width, height) = settings.fit(info.width, info.height)
        var arguments = ["-nostdin", "-y", "-v", "error"]
        if let sample { arguments += ["-ss", String(format: "%.3f", max(info.duration / 2 - sample / 2, 0)), "-t", String(format: "%.3f", sample)] }
        // (The picture as stored with its display matrix kept, never turned; its range never converted.)
        arguments += ["-noautorotate", "-i", source, "-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0", "-fps_mode", "passthrough"]
        let range = info.colour.count == 4 && ["pc", "tv"].contains(info.colour[3]) ? ":in_range=\(info.colour[3]):out_range=\(info.colour[3])" : ""
        let resize = width != info.width || height != info.height
        arguments += ["-vf", (resize || !range.isEmpty ? "scale=\(width):\(height)\(resize ? ":flags=lanczos" : "")\(range)," : "") + "format=\(pixel)"]
        arguments += video
        // Sound as it was: PCM copied, anything else (AAC) to 24-bit PCM, never compressed again.
        arguments += ["-c:a", info.audioCodecs.allSatisfy { $0.hasPrefix("pcm_") } ? "copy" : "pcm_s24le"]
        if let code = info.timecode, sample == nil { arguments += ["-timecode", code] }
        arguments += ["-metadata:s:v:0", "reel_name=\(info.reel ?? reel)"]
        arguments += metadata
        for (flag, value) in zip(["-color_primaries", "-color_trc", "-colorspace", "-color_range"], info.colour) where value != "unknown" && !value.isEmpty {
            arguments += [flag, value]
        }
        arguments += ["-movflags", "+use_metadata_tags", "-f", "mov", output.path]
        if run(ffmpeg, arguments).status != 0 { throw RawProblem(text: String(localized: "The master couldn’t be made.")) }
    }

    private static func encodeRaw(_ source: String, to output: URL, settings: MasterSettings, ffmpeg: String, reel: String, sample: Double?, metadata: [String],
                                  open: (URL) throws -> RawSource) throws {
        let clip = try open(URL(fileURLWithPath: source))
        defer { clip.close() }
        let info = clip.info
        guard info.frames > 0, info.width > 0 else { throw RawProblem(text: String(localized: "No picture to make a master of.")) }
        let (width, height) = settings.fit(info.width, info.height)
        // The decoder's own smaller sizes where they're still at least as big as the master.
        var scale = 1
        while scale < 8, info.width / (scale * 2) >= width, info.height / (scale * 2) >= height { scale *= 2 }
        let count = sample.map { min(max(Int($0 * info.fps), 1), info.frames) } ?? info.frames
        let first = sample == nil ? 0 : max(info.frames / 2 - count / 2, 0)
        let log = RawSettings(look: .log)
        let opening = try clip.frame(first, scale: scale, settings: log)
        let sound = sample == nil ? try clip.audio() : nil
        let streams = Streams(width: info.width, height: info.height, pixelFormat: "rgb48le")
        let (video, pixel) = videoArguments(settings, source: settings.codec == .prores ? Streams(pixelFormat: "yuv422p10le") : streams, ffmpeg: ffmpeg)
        var arguments = ["-nostdin", "-y", "-v", "error", "-f", "rawvideo", "-pix_fmt", "rgba64le", "-s", "\(opening.width)x\(opening.height)",
                         "-framerate", rate(info.fps), "-i", "pipe:0"]
        if let sound { arguments += ["-i", sound.path, "-map", "0:v", "-map", "1:a", "-c:a", "pcm_s24le"] }
        // RGB to YUV by Rec.709's matrix (what's tagged); the log's primaries and curve have no tag
        // of their own, so they're left unstated and named in the comment, never claimed as Rec.709.
        arguments += ["-vf", "scale=\(width):\(height):flags=lanczos:out_color_matrix=bt709:out_range=tv,format=\(pixel)"] + video
        arguments += ["-colorspace", "bt709", "-color_range", "tv"]
        let curve = info.format == "r3d" ? "Log3G10 / REDWideGamutRGB" : "Blackmagic Design Film / Blackmagic Design"
        arguments += ["-metadata", "comment=\(curve)", "-metadata:s:v:0", "reel_name=\(reel)"]
        if let code = info.timecode, sample == nil { arguments += ["-timecode", code] }
        for (key, value) in info.meta where key.range(of: "camera|lens|date|serial|iso|kelvin|shutter|reel", options: [.regularExpression, .caseInsensitive]) != nil
            && value.count < 200 {
            arguments += ["-metadata", "\(key)=\(value)"]
        }
        arguments += metadata
        arguments += ["-movflags", "+use_metadata_tags", "-f", "mov", output.path]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        // shortcut: one decoder, frame by frame; decode several at once (clip.another()) if raw masters are too slow.
        do {
            for index in first..<(first + count) {
                let frame = index == first ? opening : try clip.frame(index, scale: scale, settings: log)
                guard frame.width == opening.width, frame.height == opening.height, frame.bitsPerPixel == 64,
                      let data = frame.dataProvider?.data as Data?, data.count >= frame.width * frame.height * 8 else {
                    throw RawProblem(text: String(localized: "Frame \(index) couldn’t be read, so the export stopped there."))
                }
                try pipe.fileHandleForWriting.write(contentsOf: frame.bytesPerRow == frame.width * 8 ? data
                    : Data((0..<frame.height).flatMap { row in data[(row * frame.bytesPerRow)..<(row * frame.bytesPerRow + frame.width * 8)] }))
            }
        } catch {
            process.terminate()
            process.waitUntilExit()
            throw error
        }
        try? pipe.fileHandleForWriting.close()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw RawProblem(text: String(localized: "The master couldn’t be made.")) }
    }

    /// What the original is: from ffprobe, or (raw) from the raw decoder.
    static func reference(_ path: String, ffprobe: String, count: Bool = true, open: (URL) throws -> RawSource = { try RawFormats.open($0) }) -> Streams? {
        guard rawMasterKinds.contains((path as NSString).pathExtension.lowercased()) else { return streams(path, ffprobe: ffprobe, count: count) }
        guard let clip = try? open(URL(fileURLWithPath: path)) else { return nil }
        defer { clip.close() }
        let info = clip.info
        var result = Streams(frames: info.frames, duration: Double(info.frames) / max(info.fps, 1), fps: info.fps, width: info.width, height: info.height,
                             timecode: info.timecode, channels: info.audioChannels)
        if info.audioChannels == 0, let sound = try? clip.audio() {
            let probe = streams(sound.path, ffprobe: ffprobe)
            result.channels = probe.channels
        }
        return result
    }

    /// What's wrong with a master next to its original (empty: nothing). Frame count, length,
    /// timecode, sound channels and rate, and that it decodes to the end.
    /// Also the file's dates' tags, colour tags, rotation, pixel aspect, bit depth and channel layouts; then, with
    /// `source`, the picture itself (pictureProblems).
    static func verify(_ master: String, against original: Streams, ffmpeg: String, ffprobe: String, source: String? = nil,
                       open: (URL) throws -> RawSource = { try RawFormats.open($0) }) -> [String] {
        let got = streams(master, ffprobe: ffprobe)
        var problems: [String] = []
        if got.frames != original.frames { problems.append(String(localized: "\(got.frames) frames of \(original.frames)")) }
        if abs(got.duration - original.duration) > 1 / max(original.fps, 1) + 0.001 { problems.append(String(localized: "The length differs")) }
        if let code = original.timecode, got.timecode != code { problems.append(String(localized: "The timecode differs")) }
        if got.channels != original.channels || (original.sampleRate > 0 && got.sampleRate != original.sampleRate) {
            problems.append(String(localized: "The sound channels differ"))
        }
        if run(ffmpeg, ["-nostdin", "-v", "error", "-xerror", "-i", master, "-map", "0:v", "-map", "0:a?", "-f", "null", "-"]).status != 0 {
            problems.append(String(localized: "It doesn’t play to the end"))
        }
        problems += metadataProblems(got, original)
        if problems.isEmpty, let source { problems += pictureProblems(master, source: source, original: original, ffmpeg: ffmpeg, ffprobe: ffprobe, open: open) }
        return problems
    }

    /// The camera tags kept: creation time, make, model, reel and tape, Apple's QuickTime keys.
    static func keptTag(_ key: String) -> Bool {
        key.range(of: "creation_time|make|model|reel|tape|com\\.apple\\.quicktime", options: [.regularExpression, .caseInsensitive]) != nil && key != "pluck"
    }

    /// What ffprobe says the master lost: tags, colour tags (range too), rotation, pixel aspect, bit depth, channel layouts.
    static func metadataProblems(_ got: Streams, _ original: Streams) -> [String] {
        var problems: [String] = []
        let lost = original.tags.filter { keptTag($0.key) && got.tags[$0.key] != $0.value }.map(\.key).sorted()
        if !lost.isEmpty { problems.append(String(localized: "Tags lost: \(lost.joined(separator: ", "))")) }
        if original.colour.count == 4, got.colour.count == 4,
           zip(original.colour, got.colour).contains(where: { $0 != "unknown" && !$0.isEmpty && $0 != $1 }) {
            problems.append(String(localized: "The colour tags differ"))
        }
        if got.rotation != original.rotation { problems.append(String(localized: "The rotation differs")) }
        func aspect(_ text: String) -> String { ["", "0:1", "N/A"].contains(text) ? "1:1" : text }
        if !original.sar.isEmpty, aspect(got.sar) != aspect(original.sar) { problems.append(String(localized: "The pixel aspect ratio differs")) }
        if original.bits >= 10, got.bits < 10 { problems.append(String(localized: "Fewer bits than the original")) }
        if !original.layouts.isEmpty, original.layouts.contains(where: { !$0.isEmpty }), got.layouts != original.layouts {
            problems.append(String(localized: "The sound’s channel layout differs"))
        }
        return problems
    }

    /// The picture compared, after the other checks pass: 3 frames spread over the clip from both, small (160 wide,
    /// the master's shape), the original scaled to it with the same colour handling (raw: the RAW helper's log
    /// development the master was made from). Fails on SSIM (luma) under 0.95, a mean ΔE over 2 in display RGB, or a
    /// black master frame: catches full/video range, gamma, rotation, flips and colour-tag mistakes.
    static func pictureProblems(_ master: String, source: String, original: Streams, ffmpeg: String, ffprobe: String,
                                open: (URL) throws -> RawSource = { try RawFormats.open($0) }) -> [String] {
        let info = streams(master, ffprobe: ffprobe, count: false)
        let turned = abs(info.rotation) % 180 == 90
        let (dw, dh) = turned ? (info.height, info.width) : (info.width, info.height)
        guard dw > 0, dh > 0, original.frames > 0, original.fps > 0 else { return [String(localized: "The picture couldn’t be compared")] }
        let w = 160, h = max(Int((Double(w) * Double(dh) / Double(dw) / 2).rounded()) * 2, 2)
        let raw = rawMasterKinds.contains((source as NSString).pathExtension.lowercased())
        let clip = raw ? try? open(URL(fileURLWithPath: source)) : nil
        defer { clip?.close() }
        if raw, clip == nil { return [String(localized: "The picture couldn’t be compared")] }
        func grab(_ path: String, _ seconds: Double) -> [UInt8]? {
            let out = runData(ffmpeg, ["-nostdin", "-v", "error", "-ss", String(format: "%.4f", max(seconds, 0)), "-i", path, "-frames:v", "1",
                                       "-vf", "scale=\(w):\(h):flags=area,format=rgb24", "-f", "rawvideo", "-"])
            return out.status == 0 && out.data.count >= w * h * 3 ? Array(out.data.prefix(w * h * 3)) : nil
        }
        var worst: (ssim: Double, delta: Double) = (1, 0)
        for share in [0.2, 0.5, 0.8] {
            let index = min(Int(Double(original.frames) * share), original.frames - 1)
            // (A seek gives the first frame at or after the time: half a frame early lands on this one.)
            let seconds = (Double(index) - 0.5) / original.fps
            guard let mine = grab(master, seconds) else { return [String(localized: "The picture couldn’t be compared")] }
            let theirs: [UInt8]?
            if let clip {
                var scale = 1
                while scale < 8, clip.info.width / (scale * 2) >= w * 2 { scale *= 2 }
                theirs = (try? clip.frame(index, scale: scale, settings: RawSettings(look: .log))).flatMap { rgb24($0, width: w, height: h) }
            } else {
                theirs = grab(source, seconds)
            }
            guard let theirs else { return [String(localized: "The picture couldn’t be compared")] }
            let (ssim, delta, dark) = compare(theirs, mine, width: w, height: h)
            if dark { return [String(localized: "The master’s picture is black")] }
            worst = (min(worst.ssim, ssim), max(worst.delta, delta))
        }
        if worst.ssim < 0.95 || worst.delta > 2 {
            return [String(localized: "The picture differs (SSIM \(String(format: "%.3f", worst.ssim)), ΔE \(String(format: "%.1f", worst.delta)))")]
        }
        return []
    }

    /// A CGImage drawn into 8-bit RGB at this size, in its own colour space (no colour conversion).
    static func rgb24(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard space.model == .rgb, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                                           bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        return (0..<(width * height)).flatMap { [bytes[$0 * 4], bytes[$0 * 4 + 1], bytes[$0 * 4 + 2]] }
    }

    /// Two RGB frames: SSIM of luma (8×8 blocks), mean ΔE (CIE76, as sRGB), and whether the second is black where the first isn't.
    static func compare(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int) -> (ssim: Double, delta: Double, black: Bool) {
        func luma(_ p: [UInt8], _ i: Int) -> Double { (0.2126 * Double(p[i * 3]) + 0.7152 * Double(p[i * 3 + 1]) + 0.0722 * Double(p[i * 3 + 2])) / 255 }
        func lab(_ p: [UInt8], _ i: Int) -> (Double, Double, Double) {
            func linear(_ v: UInt8) -> Double { let c = Double(v) / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            let (r, g, b) = (linear(p[i * 3]), linear(p[i * 3 + 1]), linear(p[i * 3 + 2]))
            let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047, y = 0.2126 * r + 0.7152 * g + 0.0722 * b, z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
            func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
            return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
        }
        let count = width * height
        var delta = 0.0, meanA = 0.0, meanB = 0.0
        for i in 0..<count {
            let (l1, a1, b1) = lab(a, i), (l2, a2, b2) = lab(b, i)
            delta += sqrt((l1 - l2) * (l1 - l2) + (a1 - a2) * (a1 - a2) + (b1 - b2) * (b1 - b2))
            meanA += luma(a, i); meanB += luma(b, i)
        }
        let (c1, c2) = (0.01 * 0.01, 0.03 * 0.03)
        var ssim = 0.0, blocks = 0
        for by in stride(from: 0, through: height - 8, by: 8) {
            for bx in stride(from: 0, through: width - 8, by: 8) {
                var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
                for y in by..<(by + 8) { for x in bx..<(bx + 8) {
                    let p = luma(a, y * width + x), q = luma(b, y * width + x)
                    sa += p; sb += q; saa += p * p; sbb += q * q; sab += p * q
                } }
                let n = 64.0, ma = sa / n, mb = sb / n
                let va = saa / n - ma * ma, vb = sbb / n - mb * mb, cov = sab / n - ma * mb
                ssim += ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))
                blocks += 1
            }
        }
        return (blocks > 0 ? ssim / Double(blocks) : 0, delta / Double(max(count, 1)), meanB / Double(count) < 0.03 && meanA / Double(count) > 0.1)
    }

    /// The original's creation and modification dates on the master (Finder's sorting and Archive's age filter see the shoot date).
    static func copyDates(from original: String, to master: String, modified: Date? = nil) {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: original)) ?? [:]
        var dates: [FileAttributeKey: Any] = [:]
        dates[.modificationDate] = modified ?? attributes[.modificationDate]
        dates[.creationDate] = attributes[.creationDate]
        try? FileManager.default.setAttributes(dates, ofItemAtPath: master)
    }

    /// The master's place in Media/: the same name as a .mov; when that's taken (by any file, whatever
    /// its extension), the original's extension kept in the name, then a number.
    static func masterRelative(_ relative: String, taken: inout Set<String>) -> String {
        let stem = (relative as NSString).deletingPathExtension
        var name = stem + ".mov", number = 2
        if taken.contains(name.lowercased()) { name = relative + ".mov" }
        while taken.contains(name.lowercased()) { name = stem + " \(number).mov"; number += 1 }
        taken.insert(name.lowercased())
        return name
    }

    /// Makes and checks the masters into `staging` (Media/'s layout). A master that doesn't match
    /// its original isn't used: the original goes as it is. A master made on an earlier run is
    /// checked again and used.
    static func makeMasters(_ items: [Item], settings: [String: MasterSettings], into staging: URL, ffmpeg: String, ffprobe: String,
                            open: @escaping (URL) throws -> RawSource = { try RawFormats.open($0) },
                            progress: (MasterCheck) -> Void = { _ in }) -> (items: [Item], checks: [String: MasterCheck], notes: [String]) {
        var notes: [String] = [], checks: [String: MasterCheck] = [:]
        var taken = Set(items.filter { settings[$0.original].map { $0.codec == .original } ?? true }.map { $0.relative.lowercased() })
        let result = items.map { item -> Item in
            guard let chosen = settings[item.original], chosen.codec != .original, masterable(item) else { return item }
            let name = (item.relative as NSString).lastPathComponent
            let kind = (item.relative as NSString).pathExtension.lowercased()
            if rawMasterKinds.contains(kind), (try? open(URL(fileURLWithPath: item.source)))?.close() == nil {
                notes.append(String(localized: "\(name): this Pluck can’t decode this raw format, so it goes as it is."))
                return item
            }
            guard let original = reference(item.source, ffprobe: ffprobe, open: open), original.frames > 0 else { return item }
            let relative = masterRelative(item.relative, taken: &taken)
            let output = staging.appendingPathComponent(relative)
            let partial = output.deletingLastPathComponent().appendingPathComponent(".mastering-" + output.lastPathComponent)
            // Which original (and settings) a master left by an earlier run was made from: only that one reuses it.
            let madeFrom = output.deletingLastPathComponent().appendingPathComponent(".master-of-" + output.lastPathComponent)
            let source = "\(item.source)\n\(chosen)"
            if FileManager.default.fileExists(atPath: output.path), (try? String(contentsOf: madeFrom, encoding: .utf8)) != source {
                try? FileManager.default.removeItem(at: output)
            }
            if !FileManager.default.fileExists(atPath: output.path) {
                do {
                    try encode(item.source, to: partial, settings: chosen, ffmpeg: ffmpeg, ffprobe: ffprobe, open: open)
                    try FileManager.default.moveItem(at: partial, to: output)
                    try source.write(to: madeFrom, atomically: true, encoding: .utf8)
                } catch {
                    try? FileManager.default.removeItem(at: partial)
                }
            }
            let problems = FileManager.default.fileExists(atPath: output.path)
                ? verify(output.path, against: original, ffmpeg: ffmpeg, ffprobe: ffprobe, source: item.source, open: open) : [String(localized: "The master couldn’t be made.")]
            let size = Int64((try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let check = MasterCheck(original: item.original, relative: relative, settings: chosen, originalSize: item.size, size: size,
                                    originalHash: problems.isEmpty ? MHL.hash(item.source, kind: "xxhash64", progress: { _ in }, stopped: { false }) : nil,
                                    frames: original.frames, timecode: original.timecode, channels: original.channels, problems: problems)
            checks[item.original] = check
            progress(check)
            guard check.ok else {
                try? FileManager.default.removeItem(at: output)
                notes.append(String(localized: "\(name): the master didn’t match (\(problems.joined(separator: ", "))), so the original goes as it is."))
                return item
            }
            var master = item
            master.root = staging.path
            master.relative = relative
            master.size = size
            master.trim = nil
            master.master = chosen
            copyDates(from: item.source, to: output.path, modified: item.modified)
            return master
        }
        return (result, checks, notes)
    }

    /// Master bytes per original byte for each choice, from a short test encode (2 s from the
    /// middle) of up to two of the largest files.
    /// shortcut: one ratio per choice for every file; sample each file if mixed cameras estimate badly.
    static func estimate(_ items: [Item], settings: Set<MasterSettings>, ffmpeg: String, ffprobe: String,
                         open: @escaping (URL) throws -> RawSource = { try RawFormats.open($0) }) -> [MasterSettings: Double] {
        let samples = items.filter(masterable).sorted { $0.size > $1.size }.prefix(2).compactMap { item -> (Item, Double)? in
            guard let info = reference(item.source, ffprobe: ffprobe, count: false, open: open), info.duration > 0 else { return nil }
            return (item, info.duration)
        }
        var ratios: [MasterSettings: Double] = [:]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-estimate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for choice in settings where choice.codec != .original {
            let found = samples.compactMap { item, duration -> Double? in
                let length = min(2, duration), out = folder.appendingPathComponent(UUID().uuidString + ".mov")
                guard (try? encode(item.source, to: out, settings: choice, ffmpeg: ffmpeg, ffprobe: ffprobe, sample: length, open: open)) != nil,
                      let bytes = try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes > 0 else { return nil }
                return Double(bytes) / (Double(item.size) * length / duration)
            }
            if !found.isEmpty { ratios[choice] = found.reduce(0, +) / Double(found.count) }
        }
        return ratios
    }

    /// Relink.csv: which master replaces which original, for DaVinci Resolve (relink by name and
    /// timecode) and anyone else.
    static func writeRelink(_ checks: [MasterCheck], in folder: URL) throws {
        func cell(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var csv = "original,master,settings,timecode,channels,frames,original_size,master_size,verified,original_xxhash64\n"
        for check in checks.sorted(by: { $0.original < $1.original }) where check.ok {
            csv += [cell(check.original), cell(folder.appendingPathComponent("Media").appendingPathComponent(check.relative).path), cell(check.settings.label),
                    check.timecode ?? "", "\(check.channels)", "\(check.frames)", "\(check.originalSize)", "\(check.size)", "yes", check.originalHash ?? ""]
                .joined(separator: ",") + "\n"
        }
        try csv.write(to: folder.appendingPathComponent("Relink.csv"), atomically: true, encoding: .utf8)
    }

    /// An FCPXML with its media pointing at the masters (written beside the original one).
    /// shortcut: plain text replacement of file URLs; parse the XML if an exporter writes paths another way.
    static func masterVersion(ofFCPXML text: String, checks: [MasterCheck], archive: URL) -> String {
        var text = text
        for check in checks where check.ok {
            let master = archive.appendingPathComponent("Media").appendingPathComponent(check.relative)
            text = text.replacingOccurrences(of: URL(fileURLWithPath: check.original).absoluteString, with: master.absoluteString)
        }
        return text
    }
}
