import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Raw Player's ordinary formats, so it plays everything on a shoot: movies macOS decodes
/// (ProRes, H.264, HEVC…), the rest through ffmpeg (MXF, MKV, DNxHD, AVI, DPX sequences), and
/// image sequences (TIFF, EXR, PNG, JPEG).

/// The ffmpeg and ffprobe Pluck uses, found on the main actor before a clip opens.
enum RawTools {
    /// Finds Pluck's ffmpeg and ffprobe (for the formats macOS doesn't play).
    @MainActor static func prepare() {
        guard let manager = AppDelegate.shared?.manager else { return }
        ffmpeg = manager.tool("ffmpeg")
        ffprobe = manager.tool("ffprobe")
    }

    nonisolated(unsafe) static var ffmpeg: String?
    nonisolated(unsafe) static var ffprobe: String?
}

/// A picture made into a plain 16-bit image (in memory), for drawing and saving.
enum RawPictures {
    private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])

    static func render(_ image: CIImage, exposure: Double?) -> CGImage? {
        var image = image
        if let exposure, exposure != 0 { image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposure]) }
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height), rowBytes = width * 8
        guard width > 0, height > 0 else { return nil }
        var pixels = Data(count: rowBytes * height)
        let space = CGColorSpace(name: CGColorSpace.itur_709)!
        pixels.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: rowBytes, bounds: extent, format: .RGBA16, colorSpace: space)
        }
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: rowBytes, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Exposure, and nothing else, for formats that aren't raw.
    static func exposureInfo(_ info: inout RawClipInfo) {
        info.exposure = 0
        info.exposureRange = -5...5
    }
}

// MARK: - Movies macOS decodes

/// A movie AVFoundation decodes. Frames are read in order while playing (fast even for long-GOP
/// H.264), and from the nearest keyframe when jumping.
final class MovieSource: RawSource, @unchecked Sendable {
    let info: RawClipInfo
    private let url: URL
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var next = -1
    private let lock = NSLock()

    /// Whether macOS can decode this movie's picture.
    static func canDecode(_ url: URL) -> Bool {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first, track.isDecodable else { return false }
        return (try? AVAssetReader(asset: asset)) != nil
    }

    init(url: URL) throws {
        self.url = url
        asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = asset.tracks(withMediaType: .video).first else { throw RawProblem(text: String(localized: "This movie has no picture.")) }
        self.track = track
        let size = track.naturalSize.applying(track.preferredTransform)
        let fps = Double(track.nominalFrameRate > 0 ? track.nominalFrameRate : 25)
        var info = RawClipInfo(format: "movie", width: Int(abs(size.width)), height: Int(abs(size.height)), fps: fps,
                               frames: max(Int((asset.duration.seconds * fps).rounded()), 1))
        if let description = track.formatDescriptions.first {
            let format = description as! CMFormatDescription
            let code = Self.fourCC(CMFormatDescriptionGetMediaSubType(format))
            let stated = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_FormatName) as? String
            // Its codec by name; what the file says only when that's a name, not the encoder's ("Lavc…").
            let name = RawCodecNames.fourCC[code] ?? stated.flatMap { $0.hasPrefix("Lavc") ? nil : $0 } ?? code
            info.meta["Codec"] = name
            info.codecName = name
        }
        info.meta["Container"] = url.pathExtension.uppercased()
        info.timecode = Self.startTimecode(asset)
        info.audioChannels = asset.tracks(withMediaType: .audio).isEmpty ? 0 : 2
        RawPictures.exposureInfo(&info)
        self.info = info
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    /// The movie's own timecode (its timecode track's first frame), as "HH:MM:SS:FF".
    private static func startTimecode(_ asset: AVURLAsset) -> String? {
        guard let track = asset.tracks(withMediaType: .timecode).first, let reader = try? AVAssetReader(asset: asset),
              let description = track.formatDescriptions.first else { return nil }
        let format = description as! CMTimeCodeFormatDescription
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { return nil }
        // The first sample with data (the track can start with an empty one).
        var frame: Int32 = 0, found = false
        for _ in 0..<8 {
            guard let sample = output.copyNextSampleBuffer() else { break }
            if CMSampleBufferGetTotalSampleSize(sample) >= 4, let block = CMSampleBufferGetDataBuffer(sample),
               CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4, destination: &frame) == noErr {
                found = true
                break
            }
        }
        reader.cancelReading()
        guard found else { return nil }
        let rate = Int(CMTimeCodeFormatDescriptionGetFrameQuanta(format))
        let dropFrame = CMTimeCodeFormatDescriptionGetTimeCodeFlags(format) & kCMTimeCodeFlag_DropFrame != 0
        return RawPlayer.timecode(Int(Int32(bigEndian: frame)), rate: max(rate, 1), dropFrame: dropFrame)
    }

    func frame(_ index: Int, scale: Int, settings: RawSettings) throws -> CGImage {
        try lock.withLock {
            if reader == nil || index != next { try start(at: index) }
            while let sample = output?.copyNextSampleBuffer() {
                let at = Int((sample.presentationTimeStamp.seconds * info.fps).rounded())
                guard at >= index, let buffer = sample.imageBuffer else { continue }
                next = at + 1
                var image = CIImage(cvPixelBuffer: buffer).transformed(by: track.preferredTransform)
                image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                if scale > 1 { image = image.transformed(by: CGAffineTransform(scaleX: 1 / CGFloat(scale), y: 1 / CGFloat(scale))) }
                guard let made = RawPictures.render(image, exposure: settings.exposure) else { break }
                return made
            }
            reader = nil
            throw RawProblem(text: String(localized: "The frame couldn’t be decoded."))
        }
    }

    private func start(at index: Int) throws {
        reader?.cancelReading()
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: Double(index) / info.fps, preferredTimescale: 600), duration: .positiveInfinity)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RawProblem(text: String(localized: "The frame couldn’t be decoded.")) }
        self.reader = reader
        self.output = output
        next = index
    }

    func close() { lock.withLock { reader?.cancelReading(); reader = nil } }

    /// The sound: the movie itself plays as audio.
    func audio() throws -> URL? { info.audioChannels > 0 ? url : nil }
}

// MARK: - Everything else, through ffmpeg

/// A movie or a DPX sequence ffmpeg decodes: frames streamed in order from where it's asked, at
/// the size asked.
final class FFmpegSource: RawSource, @unchecked Sendable {
    private(set) var info: RawClipInfo
    private let input: [String]
    private let ffmpeg: String
    private var process: Process?
    private var stream: FileHandle?
    private var next = -1
    private var streamScale = 0
    private var audioFile: URL?
    private let lock = NSLock()

    /// `input`: ffmpeg's input arguments (a file, or a sequence's pattern with its rate).
    init(url: URL, input: [String]? = nil) throws {
        guard let ffmpeg = RawTools.ffmpeg, let ffprobe = RawTools.ffprobe else {
            throw RawProblem(text: Converting.Failure.noFFmpeg.localizedDescription)
        }
        self.ffmpeg = ffmpeg
        self.input = input ?? ["-i", url.path]
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: ffprobe)
        probe.arguments = ["-v", "error", "-show_streams", "-show_format", "-of", "json"] + self.input
        let pipe = Pipe()
        probe.standardOutput = pipe
        probe.standardError = FileHandle.nullDevice
        try probe.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let streams = json["streams"] as? [[String: Any]] ?? []
        guard let video = streams.first(where: { $0["codec_type"] as? String == "video" }) else {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if input == nil, size == 0 { throw RawProblem(text: String(localized: "This file is empty.")) }
            if streams.contains(where: { $0["codec_type"] as? String == "audio" }) {
                throw RawProblem(text: String(localized: "There’s no picture in this file, only sound."))
            }
            throw RawProblem(text: streams.isEmpty && input == nil
                ? String(localized: "This file is damaged or incomplete, or it isn’t a movie.")
                : String(localized: "This isn’t a clip Pluck can play."))
        }
        func rate(_ text: String?) -> Double? {
            guard let parts = text?.split(separator: "/").compactMap({ Double($0) }), parts.count == 2, parts[1] > 0, parts[0] > 0 else { return nil }
            return parts[0] / parts[1]
        }
        let fps = rate(video["avg_frame_rate"] as? String) ?? rate(video["r_frame_rate"] as? String) ?? 25
        let format = json["format"] as? [String: Any] ?? [:]
        let duration = Double(format["duration"] as? String ?? "") ?? Double(video["duration"] as? String ?? "") ?? 0
        let frames = Int(video["nb_frames"] as? String ?? "") ?? max(Int((duration * fps).rounded()), 1)
        var info = RawClipInfo(format: "ffmpeg", width: video["width"] as? Int ?? 0, height: video["height"] as? Int ?? 0, fps: fps, frames: frames)
        let codec = RawCodecNames.ffmpeg(video["codec_name"] as? String, profile: video["profile"] as? String,
                                         long: video["codec_long_name"] as? String)
        info.codecName = codec
        info.meta["Codec"] = codec
        info.meta["Container"] = (format["format_long_name"] as? String) ?? url.pathExtension.uppercased()
        let tags = [(video["tags"] as? [String: Any]) ?? [:], (format["tags"] as? [String: Any]) ?? [:]]
        info.timecode = tags.compactMap { $0["timecode"] as? String }.first
        info.audioChannels = streams.first { $0["codec_type"] as? String == "audio" }?["channels"] as? Int ?? 0
        RawPictures.exposureInfo(&info)
        guard info.width > 0, info.height > 0 else { throw RawProblem(text: String(localized: "This isn’t a clip Pluck can play.")) }
        self.info = info
    }

    deinit {
        close()
        if let audioFile { try? FileManager.default.removeItem(at: audioFile) }
    }

    func close() {
        lock.withLock {
            process?.terminate()
            process = nil
            stream = nil
        }
    }

    func frame(_ index: Int, scale: Int, settings: RawSettings) throws -> CGImage {
        try lock.withLock {
            let width = max(info.width / max(scale, 1) / 2 * 2, 2), height = max(info.height / max(scale, 1) / 2 * 2, 2)
            if process == nil || index != next || scale != streamScale { try start(at: index, width: width, height: height, scale: scale) }
            let bytes = width * height * 8
            var data = Data()
            while data.count < bytes, let chunk = try stream?.read(upToCount: bytes - data.count), !chunk.isEmpty { data.append(chunk) }
            guard data.count == bytes, let provider = CGDataProvider(data: data as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: width * 8,
                                      space: CGColorSpace(name: CGColorSpace.itur_709)!,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
                process?.terminate()
                process = nil
                throw RawProblem(text: String(localized: "The frame couldn’t be decoded."))
            }
            next = index + 1
            guard let exposure = settings.exposure, exposure != 0 else { return image }
            return RawPictures.render(CIImage(cgImage: image), exposure: exposure) ?? image
        }
    }

    private func start(at index: Int, width: Int, height: Int, scale: Int) throws {
        process?.terminate()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        let seek = Double(index) / info.fps
        // Seeking before the input is fast and (decoding) exact.
        process.arguments = ["-nostdin", "-v", "error"] + (seek > 0 ? ["-ss", String(format: "%.4f", seek)] : []) + input
            + ["-map", "0:v:0", "-vf", "scale=\(width):\(height):flags=bicubic,format=rgba64le", "-f", "rawvideo", "-"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        stream = pipe.fileHandleForReading
        next = index
        streamScale = scale
    }

    /// The sound, made into a .wav once.
    func audio() throws -> URL? {
        try lock.withLock {
            if let audioFile { return audioFile }
            guard info.audioChannels > 0 else { return nil }
            let to = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-raw-\(UUID().uuidString).wav")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = ["-nostdin", "-v", "error"] + input + ["-vn", "-c:a", "pcm_s24le", "-y", to.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            audioFile = to
            return to
        }
    }

    /// A numbered sequence's ffmpeg input ("A001_%06d.dpx" from its first file), or nil.
    /// A numbered sequence with gaps: every file of it in name order (ffmpeg's numbered input
    /// stops at the first gap).
    static func listInput(_ files: [URL], fps: Double) -> [String]? {
        guard let first = files.first, let stem = ImageSequenceSource.split(first)?.stem else { return nil }
        func escaped(_ text: String) -> String {
            text.reduce(into: "") { result, c in if "*?[]{}\\".contains(c) { result.append("\\") }; result.append(c) }
        }
        let folder = first.deletingLastPathComponent().path
        let pattern = escaped(folder) + "/" + escaped(stem) + "*." + escaped(first.pathExtension)
        return ["-framerate", String(format: "%.3f", fps), "-pattern_type", "glob", "-i", pattern]
    }

    /// Notes the frames missing from a sequence (shown with its metadata).
    func noteMissing(_ frames: String) {
        lock.withLock { info.meta[String(localized: "Missing frames")] = frames }
    }

    static func sequenceInput(_ files: [URL], fps: Double) -> [String]? {
        guard let first = files.first else { return nil }
        let name = first.deletingPathExtension().lastPathComponent
        let digits = name.reversed().prefix(while: \.isNumber).count
        guard digits > 0 else { return nil }
        let stem = String(name.dropLast(digits)), number = Int(name.suffix(digits)) ?? 0
        let pattern = first.deletingLastPathComponent().appendingPathComponent("\(stem)%0\(digits)d.\(first.pathExtension)").path
        return ["-framerate", String(format: "%.3f", fps), "-start_number", "\(number)", "-i", pattern]
    }
}

// MARK: - Image sequences

/// A folder of numbered images (TIFF, EXR, PNG, JPEG): each frame read by macOS's image reader,
/// at the size asked.
final class ImageSequenceSource: RawSource, @unchecked Sendable {
    let info: RawClipInfo
    /// Each frame's file, by its number: nil where the sequence has a gap.
    private let files: [URL?]

    static let extensions: Set<String> = ["tif", "tiff", "exr", "png", "jpg", "jpeg"]

    init(files: [URL], fps: Double = 24) throws {
        let numbered = Self.numbered(files)
        self.files = numbered.slots
        guard let first = files.first, let source = CGImageSourceCreateWithURL(first as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw RawProblem(text: String(localized: "These images can’t be read."))
        }
        var info = RawClipInfo(format: "sequence", width: width, height: height, fps: fps, frames: numbered.slots.count)
        info.codecName = String(localized: "\(first.pathExtension.uppercased()) sequence")
        info.meta["Frames"] = "\(numbered.slots.count)"
        info.meta["First"] = first.lastPathComponent
        if !numbered.missing.isEmpty { info.meta[String(localized: "Missing frames")] = Self.ranges(numbered.missing) }
        RawPictures.exposureInfo(&info)
        self.info = info
    }

    func frame(_ index: Int, scale: Int, settings: RawSettings) throws -> CGImage {
        if files.indices.contains(index), files[index] == nil {
            return try Self.missingFrame(width: max(info.width / scale, 16), height: max(info.height / scale, 16))
        }
        guard files.indices.contains(index), let file = files[index], let source = CGImageSourceCreateWithURL(file as CFURL, nil) else {
            throw RawProblem(text: String(localized: "The frame couldn’t be decoded."))
        }
        let image: CGImage?
        if scale > 1 {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: max(info.width, info.height) / scale,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image else { throw RawProblem(text: String(localized: "The frame couldn’t be decoded.")) }
        // Through Core Image: EXR's linear light and every bit depth come out ready to watch.
        return RawPictures.render(CIImage(cgImage: image), exposure: settings.exposure) ?? image
    }

    func close() {}

    /// The numbered images in a folder: the most common kind there, in order. When the folder
    /// holds several sequences (shot_v1_0001…, shot_v2_0001…), the one `chosen` belongs to, else
    /// the longest.
    static func files(in folder: URL, chosen: URL? = nil) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let counts = Dictionary(grouping: all, by: { $0.pathExtension.lowercased() })
        let kind = chosen.map { $0.pathExtension.lowercased() }.flatMap { counts[$0] != nil ? $0 : nil }
            ?? counts.max(by: { $0.value.count < $1.value.count })?.key
        guard let kind else { return [] }
        let sequences = Dictionary(grouping: counts[kind] ?? [], by: { split($0)?.stem ?? "" })
        let pick = chosen.flatMap { split($0)?.stem }.flatMap { sequences[$0] } ?? sequences.values.max { $0.count < $1.count } ?? []
        return pick.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// A file name's stem and frame number ("shot_0012.exr": "shot_", 12).
    static func split(_ url: URL) -> (stem: String, number: Int)? {
        let name = url.deletingPathExtension().lastPathComponent
        let digits = name.reversed().prefix(while: \.isNumber).count
        guard digits > 0, let number = Int(name.suffix(digits)) else { return nil }
        return (String(name.dropLast(digits)), number)
    }

    /// The files in frame order with a nil for each number missing between the first and the
    /// last (when the names are numbered, and the gaps aren't most of it).
    static func numbered(_ files: [URL]) -> (slots: [URL?], missing: [Int]) {
        let numbers = files.compactMap { split($0)?.number }
        guard numbers.count == files.count, let low = numbers.min(), let high = numbers.max(),
              high - low + 1 <= files.count * 2, Set(numbers).count == numbers.count else { return (files, []) }
        var slots = [URL?](repeating: nil, count: high - low + 1)
        for (file, number) in zip(files, numbers) { slots[number - low] = file }
        return (slots, (low...high).filter { slots[$0 - low] == nil })
    }

    /// "5, 12–14": frame numbers, runs joined.
    static func ranges(_ numbers: [Int]) -> String {
        var parts: [String] = []
        var start = numbers.first, end = numbers.first
        for number in numbers.dropFirst() + [Int.min] {
            if let e = end, number == e + 1 { end = number; continue }
            if let s = start, let e = end { parts.append(s == e ? "\(s)" : "\(s)–\(e)") }
            start = number; end = number
        }
        return parts.joined(separator: ", ")
    }

    /// What's shown for a frame the sequence doesn't have: dark, with a red line through it.
    static func missingFrame(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw RawProblem(text: String(localized: "The frame couldn’t be decoded.")) }
        context.setFillColor(CGColor(gray: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(CGColor(srgbRed: 0.9, green: 0.2, blue: 0.2, alpha: 1))
        context.setLineWidth(max(CGFloat(min(width, height)) / 120, 1))
        context.strokeLineSegments(between: [CGPoint(x: 0, y: 0), CGPoint(x: width, y: height), CGPoint(x: 0, y: height), CGPoint(x: width, y: 0)])
        guard let image = context.makeImage() else { throw RawProblem(text: String(localized: "The frame couldn’t be decoded.")) }
        return image
    }
}

/// Codecs by the names people know them by.
enum RawCodecNames {
    /// QuickTime's four-letter codes.
    static let fourCC: [String: String] = [
        "apch": "ProRes 422 HQ", "apcn": "ProRes 422", "apcs": "ProRes 422 LT", "apco": "ProRes 422 Proxy",
        "ap4h": "ProRes 4444", "ap4x": "ProRes 4444 XQ", "aprn": "ProRes RAW", "aprh": "ProRes RAW HQ",
        "avc1": "H.264", "avc3": "H.264", "hvc1": "HEVC", "hev1": "HEVC", "dvh1": "Dolby Vision", "dvhe": "Dolby Vision",
        "av01": "AV1", "vp09": "VP9", "mp4v": "MPEG-4", "mp2v": "MPEG-2", "jpeg": "Motion JPEG", "dmb1": "Motion JPEG",
        "mjpa": "Motion JPEG", "AVdn": "DNxHD", "AVdh": "DNxHR", "png ": "PNG", "png": "PNG", "rle ": "Animation",
        "rle": "Animation", "dvc": "DV", "dvcp": "DV", "dvpp": "DVCPRO",
    ]

    /// ffprobe's codec_name (with its profile where that names the flavour).
    static func ffmpeg(_ name: String?, profile: String?, long: String?) -> String {
        let named: [String: String] = [
            "h264": "H.264", "hevc": "HEVC", "av1": "AV1", "vp8": "VP8", "vp9": "VP9", "ffv1": "FFV1", "mpeg2video": "MPEG-2",
            "mpeg4": "MPEG-4", "mjpeg": "Motion JPEG", "dpx": "DPX", "png": "PNG", "tiff": "TIFF", "exr": "OpenEXR",
            "cineform": "CineForm", "dvvideo": "DV", "qtrle": "Animation", "huffyuv": "HuffYUV", "utvideo": "Ut Video",
            "theora": "Theora", "wmv3": "Windows Media", "vc1": "VC-1", "jpeg2000": "JPEG 2000",
        ]
        switch name {
        case "prores": return profile.map { "ProRes \($0)" } ?? "ProRes"
        case "dnxhd": return profile.map { $0.hasPrefix("DNX") ? $0.replacingOccurrences(of: "DNXHR", with: "DNxHR").replacingOccurrences(of: "DNXHD", with: "DNxHD") : "DNxHD \($0)" } ?? "DNxHD"
        case let name? where named[name] != nil: return named[name]!
        default:
            // The long name, unless it's only ffmpeg's own label for it.
            if let long, !long.contains("FFmpeg") { return long }
            return name?.uppercased() ?? ""
        }
    }
}
